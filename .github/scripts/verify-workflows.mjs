import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const reviewedCaddy =
  "caddy:2-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648";
const reviewedNode =
  "node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43";

function dockerfileBaseReferences(source) {
  assert.equal(
    source.split(/\r?\n/).some((line) => /^\s*#\s*escape\s*=/i.test(line)),
    false,
    "Dockerfile escape directives are unsupported",
  );
  const instructions = [];
  let logicalInstruction = "";

  for (const rawLine of source.split(/\r?\n/)) {
    if (!logicalInstruction && (!rawLine.trim() || /^\s*#/.test(rawLine))) {
      continue;
    }
    const line = rawLine.trimEnd();
    const continued = line.endsWith("\\");
    const fragment = continued ? line.slice(0, -1) : line;
    logicalInstruction += `${logicalInstruction ? " " : ""}${fragment.trim()}`;
    if (continued) continue;
    if (logicalInstruction) instructions.push(logicalInstruction);
    logicalInstruction = "";
  }
  assert.equal(
    logicalInstruction,
    "",
    "Dockerfile must not end inside a continued instruction",
  );

  return instructions.flatMap((instruction) => {
    if (!/^FROM\b/i.test(instruction)) return [];
    const match = instruction.match(
      /^FROM\s+(?:(?:--platform=\S+)\s+)?([^\s#]+)(?:\s+AS\s+[^\s#]+)?\s*$/i,
    );
    assert.ok(match, `Dockerfile contains an unsupported FROM instruction: ${instruction}`);
    return [match[1]];
  });
}

function stripYamlComment(line) {
  let quote = "";
  let escaped = false;
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (quote === '"' && character === "\\") {
      escaped = true;
      continue;
    }
    if (quote) {
      if (character === quote) quote = "";
      continue;
    }
    if (character === '"' || character === "'") {
      quote = character;
      continue;
    }
    if (character === "#" && (index === 0 || /\s/.test(line[index - 1]))) {
      return line.slice(0, index);
    }
  }
  return line;
}

function yamlScalar(value) {
  const trimmed = value.trim();
  if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return JSON.parse(trimmed);
  }
  if (trimmed.startsWith("'") && trimmed.endsWith("'")) {
    return trimmed.slice(1, -1).replaceAll("''", "'");
  }
  return trimmed;
}

function yamlUsesNodeProperties(line) {
  let quote = "";
  let escaped = false;
  let plainSyntax = "";
  for (const character of line) {
    if (escaped) {
      escaped = false;
      plainSyntax += " ";
      continue;
    }
    if (quote === '"' && character === "\\") {
      escaped = true;
      plainSyntax += " ";
      continue;
    }
    if (quote) {
      if (character === quote) quote = "";
      plainSyntax += " ";
      continue;
    }
    if (character === '"' || character === "'") {
      quote = character;
      plainSyntax += " ";
      continue;
    }
    plainSyntax += character;
  }
  return /(?:^|[\s[{,:?-])[&*!](?=\S)/.test(plainSyntax);
}

function yamlMapping(line) {
  const mapping = line.match(
    /^("(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[A-Za-z0-9_.-]+)\s*:(?:\s*(.*))?$/,
  );
  if (!mapping) return null;
  return { key: yamlScalar(mapping[1]), value: mapping[2] ?? "" };
}

function composeCaddyImageReferences(source) {
  const stack = [];
  const references = [];
  let servicesCount = 0;
  let caddyCount = 0;

  for (const rawLine of source.split(/\r?\n/)) {
    const line = stripYamlComment(rawLine);
    if (!line.trim()) continue;
    assert.equal(
      yamlUsesNodeProperties(line),
      false,
      "Compose must not use YAML anchors, aliases, or tags",
    );
    assert.ok(
      !/^\s*[?:](?:\s|$)/.test(line),
      "Compose must not use explicit YAML mapping keys",
    );
    const indent = line.match(/^\s*/)[0].length;
    const mapping = yamlMapping(line.slice(indent));
    if (!mapping) continue;

    while (stack.length && stack.at(-1).indent >= indent) stack.pop();
    const pathParts = [...stack.map(({ key }) => key), mapping.key];
    const { value } = mapping;
    if (pathParts.length === 1 && pathParts[0] === "services") {
      servicesCount += 1;
      assert.equal(value, "", "Compose services must use a block mapping");
    }
    if (
      pathParts.length === 2 &&
      pathParts[0] === "services" &&
      pathParts[1] === "caddy"
    ) {
      caddyCount += 1;
      assert.equal(value, "", "Compose caddy must use a block mapping");
    }
    if (
      pathParts.length === 3 &&
      pathParts[0] === "services" &&
      pathParts[1] === "caddy" &&
      pathParts[2] === "image" &&
      value
    ) {
      references.push(yamlScalar(value));
    }
    if (!value) stack.push({ indent, key: mapping.key });
  }

  assert.equal(servicesCount, 1, "Compose must define services exactly once");
  assert.equal(caddyCount, 1, "Compose must define the caddy service exactly once");
  return references;
}

function shellCommandSegments(source) {
  const segments = [];
  let words = [];
  let word = "";
  let wordDynamic = false;
  let quote = "";
  let escaped = false;
  let comment = false;

  const finishWord = () => {
    if (word) words.push({ dynamic: wordDynamic, value: word });
    word = "";
    wordDynamic = false;
  };
  const finishSegment = () => {
    finishWord();
    if (words.length) segments.push(words);
    words = [];
  };

  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    if (comment) {
      if (character === "\n") {
        comment = false;
        finishSegment();
      }
      continue;
    }
    if (escaped) {
      if (character !== "\n") word += character;
      escaped = false;
      continue;
    }
    if (quote !== "'" && character === "$" && source[index + 1] === "(") {
      word += "$";
      wordDynamic = true;
      index = shellCommandSubstitutionEnd(source, index + 2);
      continue;
    }
    if (quote === '"' && character === "\\") {
      escaped = true;
      continue;
    }
    if (quote) {
      if (character === quote) quote = "";
      else {
        if (quote === '"' && (character === "$" || character === "`")) {
          wordDynamic = true;
        }
        word += character;
      }
      continue;
    }
    if (character === "\\") {
      escaped = true;
      continue;
    }
    if (character === '"' || character === "'") {
      quote = character;
      continue;
    }
    if (character === "#" && !word) {
      comment = true;
      continue;
    }
    if (/\s/.test(character)) {
      finishWord();
      if (character === "\n") finishSegment();
      continue;
    }
    if (";&|(){}".includes(character)) {
      finishSegment();
      if (
        (character === "&" || character === "|") &&
        source[index + 1] === character
      ) {
        index += 1;
      }
      continue;
    }
    if (character === "$" || character === "`" || /[*?]/.test(character)) {
      wordDynamic = true;
    }
    word += character;
  }
  assert.equal(quote, "", "deployment script contains an unterminated quote");
  assert.equal(escaped, false, "deployment script ends inside an escape sequence");
  finishSegment();
  return segments;
}

function shellCommandSubstitutionEnd(source, startIndex) {
  let depth = 1;
  let quote = "";
  let escaped = false;
  let comment = false;
  for (let index = startIndex; index < source.length; index += 1) {
    const character = source[index];
    if (comment) {
      if (character === "\n") comment = false;
      continue;
    }
    if (escaped) {
      escaped = false;
      continue;
    }
    if (character === "\\") {
      escaped = true;
      continue;
    }
    if (quote) {
      if (character === quote) quote = "";
      continue;
    }
    if (character === '"' || character === "'") {
      quote = character;
      continue;
    }
    if (character === "#" && (index === startIndex || /[\s;&|(){}]/.test(source[index - 1]))) {
      comment = true;
      continue;
    }
    if (character === "(") depth += 1;
    if (character !== ")") continue;
    depth -= 1;
    if (depth === 0) return index;
  }
  assert.fail("deployment script contains an unterminated command substitution");
}

function shellCommandSubstitutionBodies(source) {
  const bodies = [];
  let quote = "";
  let escaped = false;
  let comment = false;
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    if (comment) {
      if (character === "\n") comment = false;
      continue;
    }
    if (escaped) {
      escaped = false;
      continue;
    }
    if (quote === "'") {
      if (character === "'") quote = "";
      continue;
    }
    if (character === "\\") {
      escaped = true;
      continue;
    }
    if (character === "$" && source[index + 1] === "(") {
      const bodyStart = index + 2;
      const bodyEnd = shellCommandSubstitutionEnd(source, bodyStart);
      bodies.push(source.slice(bodyStart, bodyEnd));
      index = bodyEnd;
      continue;
    }
    assert.notEqual(
      character,
      "`",
      "deployment script must not use backtick dynamic shell execution",
    );
    if (quote === '"') {
      if (character === '"') quote = "";
      continue;
    }
    if (character === '"' || character === "'") {
      quote = character;
      continue;
    }
    if (character === "#" && (index === 0 || /[\s;&|(){}]/.test(source[index - 1]))) {
      comment = true;
    }
  }
  return bodies;
}

function shellSecretParameterExpansions(source) {
  const secretNames = new Set(["PHONE_TOKEN", "MAC_TOKEN"]);
  const expansions = [];
  for (let index = 0; index < source.length; index += 1) {
    if (source[index] !== "$") continue;

    if (source[index + 1] === "{") {
      let nameStart = index + 2;
      if (source[nameStart] === "#" || source[nameStart] === "!") {
        nameStart += 1;
      }
      const name = source.slice(nameStart).match(/^[A-Za-z_][A-Za-z0-9_]*/)?.[0];
      if (secretNames.has(name)) {
        expansions.push({ name, syntax: "braced" });
      }
      continue;
    }

    const name = source.slice(index + 1).match(/^[A-Za-z_][A-Za-z0-9_]*/)?.[0];
    if (secretNames.has(name)) {
      expansions.push({ name, syntax: "unbraced" });
    }
  }
  return expansions;
}

function validateDeploymentSecretFlow(source) {
  const secretExpansions = shellSecretParameterExpansions(source);
  for (const secretName of ["PHONE_TOKEN", "MAC_TOKEN"]) {
    const references = secretExpansions.filter(({ name }) => name === secretName);
    assert.equal(
      references.length,
      1,
      `deploy script must use ${secretName} only in the reviewed smoke-container environment assignment`,
    );
    assert.equal(
      references[0].syntax,
      "unbraced",
      `deploy script must use ${secretName} only as the exact reviewed unbraced parameter expansion`,
    );
  }
  const credentialSegments = shellCommandSegments(source).filter((segment) => {
    const values = segment.map(({ value }) => value);
    return values.includes("PHONE_TOKEN=$PHONE_TOKEN") ||
      values.includes("MAC_TOKEN=$MAC_TOKEN");
  });
  assert.equal(
    credentialSegments.length,
    1,
    "deploy script must keep credential values in one reviewed command",
  );
  const credentialValues = credentialSegments[0].map(({ value }) => value);
  const credentialCommandIndex = shellCommandInvocationIndex(credentialSegments[0]);
  assert.deepEqual(
    credentialValues.slice(0, credentialCommandIndex + 2),
    [
      "CLICK_BRIDGE_RELEASE=$release",
      "PHONE_TOKEN=$PHONE_TOKEN",
      "MAC_TOKEN=$MAC_TOKEN",
      "docker",
      "run",
    ],
    "deploy script must keep credential values confined to the reviewed smoke-container environment assignment",
  );
  assert.equal(
    source.includes(".compose-compat."),
    false,
    "deploy script must not persist credential-resolved Compose output",
  );

  const composeSubstitutions = shellCommandSubstitutionBodies(source)
    .map((body) => shellCommandSegments(body))
    .flat()
    .filter((segment) => {
      const commandIndex = shellCommandInvocationIndex(segment);
      return commandIndex >= 0 &&
        segment[commandIndex].value === "docker" &&
        segment[commandIndex + 1]?.value === "compose";
    });
  assert.equal(
    composeSubstitutions.length,
    1,
    "deploy script must capture exactly one Compose compatibility render in memory",
  );
  assert.deepEqual(
    composeSubstitutions[0].map(({ value }) => value),
    [
      "CLICK_BRIDGE_RELEASE=$1",
      "CLICK_BRIDGE_SECRETS_FILE=$SHARED_ENV",
      "docker",
      "compose",
      "-p",
      "${COMPOSE_PROJECT_NAME}-compat-check",
      "--env-file",
      "$SHARED_ENV",
      "-f",
      "$directory/deploy/oci/compose.yaml",
      "config",
      "relay",
      "2>/dev/null",
    ],
    "Compose compatibility render must use exact argv and suppress stderr while stdout is captured",
  );
  assert.equal(
    source.match(/if ! rendered="\$\(/g)?.length,
    1,
    "Compose compatibility output must be captured directly into rendered",
  );
  assert.ok(
    source.includes('config relay 2>/dev/null)"; then'),
    "Compose compatibility capture must fail closed without emitting stderr",
  );
}

const dockerRunOptionsWithValues = new Set([
  "--add-host",
  "--env",
  "--env-file",
  "--label",
  "--name",
  "--network",
  "--publish",
  "--volume",
  "--workdir",
]);
const dockerRunBooleanOptions = new Set(["--detach", "--rm"]);

function dockerRunImageAndCommand(tokens) {
  const args = shellCommandBeforeRedirect(tokens);
  let index = 0;
  while (index < args.length) {
    const token = args[index];
    if (token === "--") {
      return { args, image: args[index + 1] };
    }
    if (!token.startsWith("-")) {
      return { args, image: token };
    }
    if (dockerRunBooleanOptions.has(token)) {
      index += 1;
      continue;
    }
    if (token.includes("=")) {
      const optionName = token.slice(0, token.indexOf("="));
      assert.ok(
        dockerRunOptionsWithValues.has(optionName),
        `unsupported docker run option in deploy script: ${optionName}`,
      );
      index += 1;
      continue;
    }
    assert.ok(
      dockerRunOptionsWithValues.has(token),
      `unsupported docker run option in deploy script: ${token}`,
    );
    index += 2;
  }
  return { args, image: undefined };
}

function shellCommandBeforeRedirect(tokens) {
  const redirectIndex = tokens.findIndex((token) => /^(?:\d*(?:>|<)|&>)/.test(token));
  return redirectIndex < 0 ? tokens : tokens.slice(0, redirectIndex);
}

function shellCommandInvocationIndex(tokens) {
  let index = 0;
  const shellPrefixes = new Set([
    "!",
    "do",
    "elif",
    "if",
    "then",
    "time",
    "until",
    "while",
  ]);
  while (shellPrefixes.has(tokens[index]?.value)) index += 1;
  while (/^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[index]?.value ?? "")) index += 1;
  return index < tokens.length ? index : -1;
}

function isLiteralDockerExecutable(token) {
  return token === "docker";
}

const unsafeShellAssignments = new Set([
  "BASH_ENV",
  "BASHOPTS",
  "CDPATH",
  "DOCKER_CONFIG",
  "DOCKER_CONTEXT",
  "DOCKER_HOST",
  "DYLD_INSERT_LIBRARIES",
  "ENV",
  "IFS",
  "LD_PRELOAD",
  "PATH",
  "SHELLOPTS",
]);
const reviewedShellExecutables = new Set([
  ":",
  "-d",
  "-e",
  "-f",
  "-L",
  "=",
  "[[",
  "APPLE_TEAM_ID",
  "CLICK_BRIDGE_DOMAIN",
  "MAC_TOKEN",
  "PAIRING_ENABLED",
  "PHONE_AUTH_RECORD",
  "PHONE_TOKEN",
  "break",
  "case",
  "cd",
  "chmod",
  "cleanup_candidate",
  "compose_release",
  "continue",
  "die",
  "docker",
  "done",
  "else",
  "esac",
  "exit",
  "export",
  "fi",
  "for",
  "grep",
  "domain_count",
  "line_number",
  "local",
  "mac_token_count",
  "mkdir",
  "mv",
  "path_mode",
  "pairing_count",
  "phone_auth_record_is_rotated_or_uncertain",
  "phone_token_count",
  "printf",
  "pwd",
  "read",
  "read_pointer",
  "release_directory",
  "release_supports_phone_auth_record",
  "required_key",
  "return",
  "record_count",
  "rm",
  "secret_file_mode",
  "sed",
  "seq",
  "set",
  "shift",
  "sleep",
  "start_release",
  "stat",
  "team_count",
  "tr",
  "trap",
  "true",
  "umask",
  "validate_git_release",
  "validate_pointer_release",
  "validate_secret_schema",
  "verify_candidate",
  "verify_public_release",
  "write_pointer",
]);

function assertSafeShellAssignments(segment) {
  for (const { value } of segment) {
    const assignment = value.match(/^([A-Za-z_][A-Za-z0-9_]*)(?:\+?=)/);
    if (!assignment) continue;
    const emptyIfsRead =
      assignment[1] === "IFS" &&
      segment.map(({ value: token }) => token).join(" ") ===
        "while IFS= read -r line";
    assert.ok(
      (!unsafeShellAssignments.has(assignment[1]) || emptyIfsRead) &&
        !assignment[1].startsWith("BASH_FUNC_"),
      `deploy script must not replace command-resolution environment: ${assignment[1]}`,
    );
  }
}

function deployDockerRuns(source) {
  const runs = [];
  const invocations = [];
  const subcommands = [];
  for (const substitution of shellCommandSubstitutionBodies(source)) {
    const nestedDocker = deployDockerRuns(substitution);
    runs.push(...nestedDocker.runs);
    invocations.push(...nestedDocker.invocations);
    subcommands.push(...nestedDocker.subcommands);
  }
  for (const segment of shellCommandSegments(source)) {
    assertSafeShellAssignments(segment);
    if (
      segment.every(({ value }) =>
        /^(?:\d+(?:,\d+)*|\d?>.*|&>.*|\]\])$/.test(value),
      )
    ) {
      continue;
    }
    const commandIndex = shellCommandInvocationIndex(segment);
    if (commandIndex < 0) continue;
    const executableToken = segment[commandIndex];
    const subcommandToken = segment[commandIndex + 1];
    const executable = executableToken.value;
    const subcommand = subcommandToken?.value;
    const executableName = executable.split("/").at(-1);

    if (executableName === "awk") {
      const awkInvocation = segment.map(({ value }) => value).join(" ");
      assert.ok(
        awkInvocation.includes("-v expected_source=$AUTH_DIRECTORY") &&
          awkInvocation.includes("function reset_mount()") &&
          awkInvocation.includes("exit exact_matches == 1 ? 0 : 1") &&
          !awkInvocation.includes("system("),
        "deploy script contains an unreviewed Awk executable command",
      );
      continue;
    }

    if (executableToken.dynamic) {
      if (
        segment.length === 1 &&
        ["*", "[A-Z][A-Z0-9_]*", "[^[:space:]]*"].includes(executable)
      ) {
        continue;
      }
      const quotedConditionSubstitutionTail =
        (segment.length === 2 &&
          executable === "$" &&
          subcommand === "]]" &&
          subcommandToken.dynamic === false) ||
        (segment.length === 4 &&
          executable.startsWith("$") &&
          subcommand === "=~" &&
          subcommandToken.dynamic === false &&
          segment[3].value === "]]" &&
          segment[3].dynamic === false) ||
        (segment.length === 4 &&
          executable.startsWith("$") &&
          ["=", "!="].includes(subcommand) &&
          segment.slice(1).every(({ dynamic }) => dynamic === false) &&
          segment[3].value === "]]" ) ||
        (segment.length === 4 &&
          /^= \$[A-Za-z_][A-Za-z0-9_]*\)$/.test(executable) &&
          subcommand === "=" &&
          segment[2].value === "1" &&
          segment[3].value === "]]" &&
          segment.slice(1).every(({ dynamic }) => dynamic === false));
      if (quotedConditionSubstitutionTail) continue;
      assert.fail(
        `deploy script must not compute an executable command: ${JSON.stringify(segment)}`,
      );
    }

    assert.ok(
      reviewedShellExecutables.has(executableName),
      `deploy script contains an unreviewed executable command: ${executableName}: ${JSON.stringify(segment)}`,
    );
    if (executableName === "docker") {
      assert.equal(
        executable,
        "docker",
        "deploy script must invoke Docker through the exact literal executable",
      );
    }

    if (executableName === "trap") {
      const trapCommand = segment.map(({ value }) => value);
      assert.ok(
        [
          ["trap", "cleanup_candidate", "EXIT", "INT", "TERM"],
          ["trap", "-", "EXIT", "INT", "TERM"],
        ].some((expected) =>
          expected.length === trapCommand.length &&
          expected.every((value, index) => value === trapCommand[index])
        ),
        `deploy script contains an unreviewed trap command: ${JSON.stringify(trapCommand)}`,
      );
    }

    for (let index = 0; index < segment.length - 1; index += 1) {
      if (
        !isLiteralDockerExecutable(segment[index].value) ||
        segment[index + 1].value !== "run"
      ) {
        continue;
      }
      assert.ok(
        index === commandIndex,
        "deploy script contains docker run outside a structurally validated command position",
      );
    }

    if (!isLiteralDockerExecutable(executable)) {
      assert.notEqual(
        subcommand,
        "run",
        "deploy script must not invoke docker run through an indirect executable",
      );
      continue;
    }
    assert.ok(subcommandToken, "docker invocation must include a literal subcommand");
    assert.equal(
      subcommandToken.dynamic,
      false,
      "docker subcommand must not be computed",
    );
    assert.ok(
      ["compose", "exec", "logs", "rm", "run"].includes(subcommand),
      `deploy script uses an unsupported docker subcommand: ${subcommand}`,
    );
    subcommands.push(subcommand);
    invocations.push({ executable, subcommand });
    if (subcommand !== "run") continue;
    const { args, image } = dockerRunImageAndCommand(
      segment.slice(commandIndex + 2).map(({ value }) => value),
    );
    runs.push({
      args,
      executable,
      image,
    });
  }
  return { invocations, runs, subcommands };
}

export function validateDeploymentImages({ dockerfile, compose, deployScript }) {
  const baseReferences = dockerfileBaseReferences(dockerfile);
  assert.deepEqual(
    baseReferences,
    [reviewedNode],
    "relay base image must use the reviewed digest; tag-only references are forbidden",
  );

  const caddyReferences = composeCaddyImageReferences(compose);
  assert.deepEqual(
    caddyReferences,
    [reviewedCaddy],
    "Caddy must use exactly the reviewed digest; tag-only references are forbidden",
  );

  validateDeploymentSecretFlow(deployScript);

  const {
    invocations: dockerInvocations,
    runs: deployRuns,
    subcommands: dockerSubcommands,
  } =
    deployDockerRuns(deployScript);
  assert.deepEqual(
    dockerSubcommands,
    ["compose", "compose", "rm", "run", "exec", "logs", "run", "run"],
    "deploy script must contain exactly the reviewed Docker command sequence",
  );
  assert.deepEqual(
    dockerInvocations.map(({ executable, subcommand }) => ({
      executable,
      subcommand,
    })),
    ["compose", "compose", "rm", "run", "exec", "logs", "run", "run"].map(
      (subcommand) => ({ executable: "docker", subcommand }),
    ),
    "every deployment Docker invocation must use the exact literal executable",
  );
  assert.deepEqual(
    deployRuns,
    [
      {
        args: [
          "--detach",
          "--name",
          "$CANDIDATE_CONTAINER_NAME",
          "--publish",
          "127.0.0.1:18080:8080",
          "--env-file",
          "$SHARED_ENV",
          "--volume",
          "$AUTH_DIRECTORY:/var/lib/click-bridge/auth",
          "--env",
          "PORT=8080",
          "--env",
          "HOST=0.0.0.0",
          "click-bridge-relay:$release",
        ],
        executable: "docker",
        image: "click-bridge-relay:$release",
      },
      {
        args: [
          "--rm",
          "--network",
          "host",
          "--add-host",
          "$CLICK_BRIDGE_DOMAIN:127.0.0.1",
          "--env",
          "CLICK_BRIDGE_DOMAIN=$CLICK_BRIDGE_DOMAIN",
          reviewedNode,
          "node",
          "-e",
          'fetch(`https://${process.env.CLICK_BRIDGE_DOMAIN}/healthz`).then(async response=>{if(!response.ok||(await response.text())!=="ok")process.exit(1)}).catch(()=>process.exit(1))',
        ],
        executable: "docker",
        image: reviewedNode,
      },
      {
        args: [
          "--rm",
          "--network",
          "host",
          "--add-host",
          "$CLICK_BRIDGE_DOMAIN:127.0.0.1",
          "--env",
          "CLICK_BRIDGE_DOMAIN=$CLICK_BRIDGE_DOMAIN",
          "--env",
          "PHONE_TOKEN",
          "--env",
          "MAC_TOKEN",
          "--volume",
          "$directory/relay:/workspace:ro",
          "--workdir",
          "/tmp/smoke",
          reviewedNode,
          "sh",
          "-euc",
          'cp -R /workspace/. .; npm ci --omit=dev --ignore-scripts >/dev/null; node scripts/smoke-relay.mjs "wss://${CLICK_BRIDGE_DOMAIN}/ws"',
        ],
        executable: "docker",
        image: reviewedNode,
      },
    ],
    "deploy script docker run arguments must match the exact candidate and verifier containers with the reviewed Node digest",
  );
}

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const workflowDirectory = path.join(repositoryRoot, ".github/workflows");
const workflowFiles = readdirSync(workflowDirectory)
  .filter((name) => name.endsWith(".yml") || name.endsWith(".yaml"))
  .sort();

assert.ok(workflowFiles.length > 0, "at least one workflow must exist");

for (const workflowFile of workflowFiles) {
  const source = readFileSync(path.join(workflowDirectory, workflowFile), "utf8");
  assert.ok(
    !source.includes("pull_request_target:"),
    `${workflowFile} must not use pull_request_target`,
  );

  for (const match of source.matchAll(/^\s*uses:\s*([^\s#]+).*$/gm)) {
    assert.match(
      match[1],
      /^[^/\s]+\/[^@\s]+@[0-9a-f]{40}$/,
      `${workflowFile}: ${match[1]} must use a full commit SHA`,
    );
  }
}

const dockerfile = readFileSync(
  path.join(repositoryRoot, "deploy/oci/Dockerfile"),
  "utf8",
);
const compose = readFileSync(
  path.join(repositoryRoot, "deploy/oci/compose.yaml"),
  "utf8",
);
const deployScript = readFileSync(
  path.join(repositoryRoot, ".github/scripts/deploy-oci.sh"),
  "utf8",
);
validateDeploymentImages({ dockerfile, compose, deployScript });

console.log(`verified ${workflowFiles.length} workflow file(s)`);
