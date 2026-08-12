import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import path from "node:path";
import * as workflowVerifier from "./verify-workflows.mjs";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);

const reviewedCaddy =
  "caddy:2-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648";
const reviewedNode =
  "node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43";
const unreviewedNode =
  "node:24-alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const validDockerfile = `FROM ${reviewedNode}\n`;
const validCompose = `services:\n  caddy:\n    image: ${reviewedCaddy}\n`;
function verifierDeployScript(healthImage, smokeImage) {
  return `#!/usr/bin/env bash
docker compose config
if ! rendered="$(CLICK_BRIDGE_RELEASE="$1" CLICK_BRIDGE_SECRETS_FILE="$SHARED_ENV" docker compose \\
  -p "\${COMPOSE_PROJECT_NAME}-compat-check" \\
  --env-file "$SHARED_ENV" \\
  -f "$directory/deploy/oci/compose.yaml" \\
  config relay 2>/dev/null)"; then
  return 1
fi
docker rm candidate
CLICK_BRIDGE_RELEASE="$release" docker run --detach \\
  --name "$CANDIDATE_CONTAINER_NAME" \\
  --publish 127.0.0.1:18080:8080 \\
  --env-file "$SHARED_ENV" \\
  --volume "$AUTH_DIRECTORY:/var/lib/click-bridge/auth" \\
  --env PORT=8080 \\
  --env HOST=0.0.0.0 \\
  "click-bridge-relay:$release" >/dev/null
docker exec candidate true
docker logs candidate
CLICK_BRIDGE_RELEASE="$release" docker run --rm --network host \\
  --add-host "$CLICK_BRIDGE_DOMAIN:127.0.0.1" \\
  --env "CLICK_BRIDGE_DOMAIN=$CLICK_BRIDGE_DOMAIN" \\
  ${healthImage} node -e \\
  'fetch(\`https://\${process.env.CLICK_BRIDGE_DOMAIN}/healthz\`).then(async response=>{if(!response.ok||(await response.text())!=="ok")process.exit(1)}).catch(()=>process.exit(1))'
CLICK_BRIDGE_RELEASE="$release" PHONE_TOKEN="$PHONE_TOKEN" MAC_TOKEN="$MAC_TOKEN" \\
  docker run --rm --network host \\
  --add-host "$CLICK_BRIDGE_DOMAIN:127.0.0.1" \\
  --env "CLICK_BRIDGE_DOMAIN=$CLICK_BRIDGE_DOMAIN" \\
  --env PHONE_TOKEN \\
  --env MAC_TOKEN \\
  --volume "$directory/relay:/workspace:ro" \\
  --workdir /tmp/smoke \\
  ${smokeImage} sh -euc \\
  'cp -R /workspace/. .; npm ci --omit=dev --ignore-scripts >/dev/null; node scripts/smoke-relay.mjs "wss://\${CLICK_BRIDGE_DOMAIN}/ws"'
`;
}
const validDeployScript = verifierDeployScript(reviewedNode, reviewedNode);
const { validateDeploymentImages } = workflowVerifier;
assert.equal(
  typeof validateDeploymentImages,
  "function",
  "workflow verification must expose deployment image validation",
);

assert.throws(
  () =>
    validateDeploymentImages({
      dockerfile: "FROM node:24-alpine\n",
      compose: validCompose,
      deployScript: validDeployScript,
    }),
  /tag-only|reviewed digest/,
  "deployment image validation must reject tag-only references",
);
assert.throws(
  () =>
    validateDeploymentImages({
      dockerfile: validDockerfile,
      compose:
        "services:\n  caddy:\n    image: caddy:2-alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
      deployScript: validDeployScript,
    }),
  /reviewed digest/,
  "deployment image validation must reject unreviewed digests",
);
assert.throws(
  () =>
    validateDeploymentImages({
      dockerfile: `# FROM ${reviewedNode}\nFROM node:latest\n`,
      compose: validCompose,
      deployScript: validDeployScript,
    }),
  /relay base image|reviewed digest/,
  "a reviewed Dockerfile reference in a comment must not hide a mutable FROM",
);
assert.throws(
  () =>
    validateDeploymentImages({
      dockerfile: `FROM ${unreviewedNode}\n`,
      compose: validCompose,
      deployScript: validDeployScript,
    }),
  /relay base image|reviewed digest/,
  "an unreviewed Dockerfile FROM digest must be rejected",
);
assert.throws(
  () =>
    validateDeploymentImages({
      dockerfile: validDockerfile,
      compose: `services:\n  caddy:\n    # image: ${reviewedCaddy}\n    image: caddy:2-alpine\n`,
      deployScript: validDeployScript,
    }),
  /Caddy|reviewed digest/,
  "a reviewed Compose reference in a comment must not hide a mutable service image",
);
assert.throws(
  () =>
    validateDeploymentImages({
      dockerfile: validDockerfile,
      compose: validCompose,
      deployScript: `# ${reviewedNode}\n# ${reviewedNode}\n${verifierDeployScript("node:24-alpine", "node:24-alpine")}`,
    }),
  /verifier containers|reviewed Node digest/,
  "reviewed references in comments must not hide mutable verifier operands",
);
assert.throws(
  () =>
    validateDeploymentImages({
      dockerfile: `ARG NODE_IMAGE=${reviewedNode}\nFROM \${NODE_IMAGE}\n`,
      compose: validCompose,
      deployScript: validDeployScript,
    }),
  /relay base image|reviewed digest/,
  "an interpolated Dockerfile FROM must not satisfy the reviewed image contract",
);
assert.throws(
  () =>
    validateDeploymentImages({
      dockerfile: `${validDockerfile}FROM node:latest \\\n  AS bypass\n`,
      compose: validCompose,
      deployScript: validDeployScript,
    }),
  /relay base image|reviewed digest/,
  "a continued mutable Dockerfile FROM must not evade image validation",
);
assert.throws(
  () =>
    validateDeploymentImages({
      dockerfile: `# escape=\u0060\n${validDockerfile}FROM node:latest \u0060\n  AS bypass\n`,
      compose: validCompose,
      deployScript: validDeployScript,
    }),
  /Dockerfile|relay base image|reviewed digest/,
  "an alternate Dockerfile escape directive must fail closed",
);
assert.throws(
  () =>
    validateDeploymentImages({
      dockerfile:
        "# escape=`\n" +
        validDockerfile +
        "RUN printf ignored \\\nFROM node:latest\n",
      compose: validCompose,
      deployScript: validDeployScript,
    }),
  /Dockerfile|escape directive/,
  "an alternate escape directive must not hide a mutable FROM after a backslash",
);
assert.throws(
  () =>
    validateDeploymentImages({
      dockerfile: validDockerfile,
      compose: `x-reviewed: ${reviewedCaddy}\nservices:\n  caddy:\n    image: \${CADDY_IMAGE}\n`,
      deployScript: validDeployScript,
    }),
  /Caddy|reviewed digest/,
  "an interpolated Compose image must not satisfy the reviewed image contract",
);
assert.throws(
  () =>
    validateDeploymentImages({
      dockerfile: validDockerfile,
      compose: `${validCompose}services:\n  relay:\n    image: click-bridge-relay:test\n`,
      deployScript: validDeployScript,
    }),
  /Compose|services|Caddy/,
  "a duplicate services key must not shadow the reviewed Caddy service",
);
assert.throws(
  () =>
    validateDeploymentImages({
      dockerfile: validDockerfile,
      compose: `${validCompose}  caddy:\n    command: ["caddy"]\n`,
      deployScript: validDeployScript,
    }),
  /Compose|caddy|Caddy/,
  "a duplicate caddy key must not shadow the reviewed service image",
);
for (const [shape, compose] of [
  [
    "inline services",
    `${validCompose}services: {caddy: {image: caddy:latest}}\n`,
  ],
  [
    "quoted services",
    `${validCompose}"services":\n  caddy:\n    image: caddy:latest\n`,
  ],
  [
    "inline caddy",
    `${validCompose}  caddy: {image: caddy:latest}\n`,
  ],
  [
    "quoted caddy",
    `${validCompose}  "caddy":\n    image: caddy:latest\n`,
  ],
  [
    "quoted image",
    `${validCompose}    "image": caddy:latest\n`,
  ],
  [
    "spaced services",
    `${validCompose}services : {caddy: {image: caddy:latest}}\n`,
  ],
  [
    "spaced quoted caddy",
    `${validCompose}  "caddy" :\n    image: caddy:latest\n`,
  ],
  [
    "spaced image",
    `${validCompose}    image : caddy:latest\n`,
  ],
  [
    "anchor-decorated image",
    `${validCompose}    &dup image: caddy:latest\n`,
  ],
  [
    "explicit services",
    `${validCompose}? services\n: {caddy: {image: caddy:latest}}\n`,
  ],
]) {
  assert.throws(
    () =>
      validateDeploymentImages({
        dockerfile: validDockerfile,
        compose,
        deployScript: validDeployScript,
      }),
    /Compose|services|caddy|Caddy|image/,
    `a duplicate ${shape} key must not shadow the reviewed Caddy image`,
  );
}
assert.throws(
  () =>
    validateDeploymentImages({
      dockerfile: validDockerfile,
      compose: validCompose,
      deployScript: `# ${reviewedNode}\n${verifierDeployScript("$NODE_IMAGE", reviewedNode)}`,
    }),
  /verifier containers|reviewed Node digest/,
  "an interpolated health verifier image must not satisfy the reviewed image contract",
);
assert.throws(
  () =>
    validateDeploymentImages({
      dockerfile: validDockerfile,
      compose: validCompose,
      deployScript: verifierDeployScript(unreviewedNode, reviewedNode),
    }),
  /verifier containers|reviewed Node digest/,
  "an unreviewed health verifier digest must be rejected",
);
assert.throws(
  () =>
    validateDeploymentImages({
      dockerfile: validDockerfile,
      compose: validCompose,
      deployScript: verifierDeployScript(reviewedNode, unreviewedNode),
    }),
  /verifier containers|reviewed Node digest/,
  "an unreviewed smoke verifier digest must be rejected",
);
assert.throws(
  () =>
    validateDeploymentImages({
      dockerfile: validDockerfile,
      compose: validCompose,
      deployScript: validDeployScript.replace(
        "click-bridge-relay:$release",
        "click-bridge-relay:latest",
      ),
    }),
  /docker run/,
  "the candidate docker run must keep the exact release-scoped local image",
);
for (const [shape, option] of [
  ["privileged", "--privileged=true"],
  [
    "secret-file mount",
    "--mount=type=bind,source=/opt/click-bridge/shared/secrets.env,target=/stolen",
  ],
  ["entrypoint", "--entrypoint=/bin/sh"],
]) {
  assert.throws(
    () =>
      validateDeploymentImages({
        dockerfile: validDockerfile,
        compose: validCompose,
        deployScript: validDeployScript.replace(
          "docker run --rm --network host \\\n",
          `docker run --rm --network host ${option} \\\n`,
        ),
      }),
    /unsupported docker run option/,
    `an inline ${shape} option must be rejected`,
  );
}
for (const [shape, from, to] of [
  ["health network", "--network host", "--network none"],
  [
    "health add-host",
    '"$CLICK_BRIDGE_DOMAIN:127.0.0.1"',
    '"other.invalid:127.0.0.1"',
  ],
  [
    "smoke token forwarding",
    "  --env PHONE_TOKEN \\\n  --env MAC_TOKEN \\\n",
    "",
  ],
  [
    "smoke relay mount",
    '"$directory/relay:/workspace:ro"',
    '"$directory/other:/workspace:rw"',
  ],
]) {
  assert.throws(
    () =>
      validateDeploymentImages({
        dockerfile: validDockerfile,
        compose: validCompose,
        deployScript: validDeployScript.replace(from, to),
      }),
    /docker run|contract|verifier containers|reviewed Node digest/,
    `a changed ${shape} must be rejected`,
  );
}
for (const [shape, deployScript] of [
  [
    "dollar variable",
    validDeployScript.replace("docker run --detach", "$DOCKER run --detach"),
  ],
  [
    "braced variable",
    validDeployScript.replace("docker run --detach", '"${DOCKER}" run --detach'),
  ],
  [
    "absolute executable",
    validDeployScript.replace("docker run --detach", "/usr/bin/docker run --detach"),
  ],
  [
    "command-wrapped variable",
    validDeployScript.replace("docker run --detach", 'command "$DOCKER" run --detach'),
  ],
  [
    "env-wrapped variable",
    validDeployScript.replace(
      "docker run --detach",
      'env DOCKER=docker "$DOCKER" run --detach',
    ),
  ],
  [
    "interpreter-wrapped variable",
    `${validDeployScript}bash -c '$DOCKER run --rm node:latest true'\n`,
  ],
  [
    "eval command string",
    `${validDeployScript}eval 'docker run --rm node:latest true'\n`,
  ],
  [
    "PATH-prefixed executable",
    validDeployScript.replace(
      "docker run --detach",
      "PATH=/tmp:$PATH docker run --detach",
    ),
  ],
  [
    "globally replaced PATH",
    `PATH=/tmp:$PATH\n${validDeployScript}`,
  ],
]) {
  assert.throws(
    () =>
      validateDeploymentImages({
        dockerfile: validDockerfile,
        compose: validCompose,
        deployScript,
      }),
    /Docker|docker run|literal executable|indirect executable|dynamic shell execution|compute|command-resolution|unreviewed executable/,
    `a ${shape} docker executable must be rejected`,
  );
}
for (const dockerPath of ["/tmp/docker", "/usr/local/bin/docker"]) {
  for (const subcommand of ["compose", "rm", "run", "exec", "logs"]) {
    assert.throws(
      () =>
        validateDeploymentImages({
          dockerfile: validDockerfile,
          compose: validCompose,
          deployScript: validDeployScript.replace(
            `docker ${subcommand}`,
            `${dockerPath} ${subcommand}`,
          ),
        }),
      /Docker|docker|executable|invocation|command|arguments/,
      `${dockerPath} must not replace the literal Docker executable for ${subcommand}`,
    );
  }
}
for (const [shape, suffix] of [
  ["semicolon", "; docker run --rm node:latest true"],
  ["and-list", "&& docker run --rm node:latest true"],
  ["or-list", "|| docker run --rm node:latest true"],
  [
    "subshell",
    `; ( docker run --rm ${reviewedNode} node -e 'process.exit(0)'; docker run --rm node:latest true )`,
  ],
  [
    "function",
    `; decoy() { docker run --rm ${reviewedNode} node -e 'process.exit(0)'; docker run --rm node:latest true; }`,
  ],
]) {
  assert.throws(
    () =>
      validateDeploymentImages({
        dockerfile: validDockerfile,
        compose: validCompose,
        deployScript: `${validDeployScript.trimEnd()} ${suffix}\n`,
      }),
    /docker run|Docker command sequence|verifier containers|reviewed Node digest|unreviewed executable/,
    `an extra mutable docker run in a ${shape} must be rejected`,
  );
}
for (const [shape, suffix] of [
  ["command substitution", "$(printf docker) run --rm node:latest true"],
  ["backtick substitution", "`printf docker` run --rm node:latest true"],
  ["IFS executable", "docker${IFS}run --rm node:latest true"],
  ["dynamic subcommand", "R=run; docker ${R} --rm node:latest true"],
  ["function forwarder", 'd(){ docker "$@"; }; d run --rm node:latest true'],
  ["long Docker global option", "docker --host unix:///tmp/docker.sock run --rm node:latest true"],
  ["short Docker global option", "docker -H unix:///tmp/docker.sock run --rm node:latest true"],
  ["env split-string", 'env -S "docker run --rm node:latest true"'],
  [
    "quoted argument command substitution",
    'printf %s "$(docker run --rm node:latest true)"',
  ],
  [
    "assignment command substitution",
    'RESULT="$(docker run --rm node:latest true)"',
  ],
  [
    "Python launcher",
    "python3 -c 'import os; os.system(\"docker run --rm node:latest true\")'",
  ],
  ["Node launcher", "node -e 'process.exit(0) // docker run node:latest'"],
  ["Make launcher", "make deploy-docker"],
  ["Curl pipeline launcher", "curl https://example.invalid/script | sh"],
  ["Awk launcher", "awk 'BEGIN { system(\"docker run node:latest\") }'"],
]) {
  assert.throws(
    () =>
      validateDeploymentImages({
        dockerfile: validDockerfile,
        compose: validCompose,
        deployScript: `${validDeployScript}${suffix}\n`,
      }),
    /computed|docker|Docker|dynamic|executable|subcommand|sequence/,
    `a Docker invocation synthesized through ${shape} must be rejected`,
  );
}
for (const [shape, suffix] of [
  [
    "literal trap payload",
    "trap 'docker run --rm node:latest true' ']]'",
  ],
  [
    "dynamic executable ending in a condition token",
    "$DOCKER run --rm node:latest true ']]'",
  ],
]) {
  assert.throws(
    () =>
      validateDeploymentImages({
        dockerfile: validDockerfile,
        compose: validCompose,
        deployScript: `${validDeployScript}${suffix}\n`,
      }),
    /docker|Docker|trap|executable|command/,
    `a ${shape} must not hide an executable Docker invocation`,
  );
}
assert.doesNotThrow(() =>
  validateDeploymentImages({
    dockerfile: `# node:latest\n${validDockerfile}`,
    compose: `# caddy:latest\n${validCompose}`,
    deployScript: `# $DOCKER run --rm node:latest true\nprintf '%s\\n' 'docker run --rm node:latest true'\n${validDeployScript}`,
  }),
);

for (const [shape, mutation] of [
  [
    "PHONE_TOKEN printf",
    `${validDeployScript}printf '%s\\n' "$PHONE_TOKEN"\n`,
  ],
  [
    "MAC_TOKEN grep input",
    `${validDeployScript}grep -F token <<< "$MAC_TOKEN"\n`,
  ],
  [
    "PHONE_TOKEN sed input",
    `${validDeployScript}sed -n p <<< "$PHONE_TOKEN"\n`,
  ],
  [
    "missing Compose stderr suppression",
    validDeployScript.replace("config relay 2>/dev/null", "config relay"),
  ],
  [
    "removed Compose output capture",
    validDeployScript.replace(
      'if ! rendered="$(CLICK_BRIDGE_RELEASE="$1" CLICK_BRIDGE_SECRETS_FILE="$SHARED_ENV" docker compose',
      'if ! CLICK_BRIDGE_RELEASE="$1" CLICK_BRIDGE_SECRETS_FILE="$SHARED_ENV" docker compose',
    ).replace('config relay 2>/dev/null)"; then', "config relay 2>/dev/null; then"),
  ],
]) {
  assert.throws(
    () =>
      validateDeploymentImages({
        dockerfile: validDockerfile,
        compose: validCompose,
        deployScript: mutation,
      }),
    /secret|PHONE_TOKEN|MAC_TOKEN|Compose|capture|stderr|output|command sequence/,
    `deployment validation must reject ${shape}`,
  );
}

function readRequired(relativePath) {
  const absolutePath = path.join(repositoryRoot, relativePath);
  assert.ok(existsSync(absolutePath), `${relativePath} must exist`);
  return readFileSync(absolutePath, "utf8");
}

function assertIncludes(source, expected, message) {
  assert.ok(source.includes(expected), message ?? `missing ${expected}`);
}

const workflowRunnerTemp = path.join(tmpdir(), "click-bridge-workflow-runner");
const recordingStub = [
  "#!/bin/bash",
  "set -u",
  'command_name="${0##*/}"',
  "{",
  "  printf '%s' \"$command_name\"",
  "  if (( $# > 0 )); then",
  "    printf '\\t%s' \"$@\"",
  "  fi",
  "  printf '\\n'",
  '} >> "$WORKFLOW_COMMAND_LOG"',
  'if [[ "${WORKFLOW_FAIL_COMMAND:-}" == "$command_name" ]] &&',
  '  { [[ -z "${WORKFLOW_FAIL_FIRST_ARGUMENT:-}" ]] || [[ "${1:-}" == "$WORKFLOW_FAIL_FIRST_ARGUMENT" ]]; }; then',
  '  exit "${WORKFLOW_FAIL_STATUS:-97}"',
  "fi",
  "exit 0",
  "",
].join("\n");

function runRecordedWorkflowScript(
  script,
  { failCommand = "", failFirstArgument = "" } = {},
) {
  const fixtureDirectory = mkdtempSync(
    path.join(tmpdir(), "click-bridge-workflow-command-"),
  );
  const binDirectory = path.join(fixtureDirectory, "bin");
  const commandLog = path.join(fixtureDirectory, "commands.tsv");
  mkdirSync(binDirectory);
  writeFileSync(commandLog, "");
  for (const command of ["bash", "node", "ruby", "xcodebuild"]) {
    const stubPath = path.join(binDirectory, command);
    writeFileSync(stubPath, recordingStub);
    chmodSync(stubPath, 0o755);
  }

  try {
    const result = spawnSync(
      "/bin/bash",
      ["-e", "-o", "pipefail", "-c", script],
      {
        cwd: repositoryRoot,
        encoding: "utf8",
        env: {
          ...process.env,
          PATH: `${binDirectory}:${process.env.PATH ?? ""}`,
          RUNNER_TEMP: workflowRunnerTemp,
          WORKFLOW_COMMAND_LOG: commandLog,
          WORKFLOW_FAIL_COMMAND: failCommand,
          WORKFLOW_FAIL_FIRST_ARGUMENT: failFirstArgument,
          WORKFLOW_FAIL_STATUS: "97",
        },
      },
    );
    const loggedCommands = readFileSync(commandLog, "utf8").trimEnd();
    return {
      result,
      invocations: loggedCommands.length === 0
        ? []
        : loggedCommands.split("\n").map((line) => line.split("\t")),
    };
  } finally {
    rmSync(fixtureDirectory, { recursive: true, force: true });
  }
}

function assertExecutesExactCommand(script, expectedInvocation, message) {
  const success = runRecordedWorkflowScript(script);
  assert.equal(
    success.result.status,
    0,
    `${message}; script failed:\n${success.result.stdout}${success.result.stderr}`,
  );
  const matchingInvocations = success.invocations.filter(
    ([command, firstArgument]) => command === expectedInvocation[0]
      && firstArgument === expectedInvocation[1],
  );
  assert.deepEqual(matchingInvocations, [expectedInvocation], message);

  const failure = runRecordedWorkflowScript(script, {
    failCommand: expectedInvocation[0],
    failFirstArgument: expectedInvocation[1],
  });
  assert.equal(
    failure.result.status,
    97,
    `${message}; command failure must propagate from the workflow step`,
  );
}

function readYamlDocument(relativePath) {
  const result = spawnSync(
    "ruby",
    [
      "-ryaml",
      "-rjson",
      "-e",
      "puts JSON.generate(YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true))",
      relativePath,
    ],
    { cwd: repositoryRoot, encoding: "utf8" },
  );
  assert.equal(
    result.status,
    0,
    `${relativePath} YAML parsing failed:\n${result.stdout}${result.stderr}`,
  );
  return JSON.parse(result.stdout);
}

const ci = readRequired(".github/workflows/ci.yml");
const ciDocument = readYamlDocument(".github/workflows/ci.yml");

assertIncludes(ci, "name: CI");
assertIncludes(ci, "pull_request:");
assertIncludes(ci, "push:");
assertIncludes(ci, "workflow_dispatch:");
assertIncludes(ci, "contents: read");
assertIncludes(ci, "cancel-in-progress: true");
assertIncludes(ci, "relay-container:");
assertIncludes(ci, "apple-clients:");
assertIncludes(ci, "runs-on: ubuntu-24.04");
assertIncludes(ci, "runs-on: macos-15");
assertIncludes(ci, 'node-version: "24"');
assertIncludes(ci, "npm run check");
assertIncludes(ci, "bash .github/scripts/test-deploy-oci.sh");
assertIncludes(ci, "docker build");
assertIncludes(ci, "ClickBridgeMac");
assertIncludes(ci, "hashFiles('ios/project.yml')");
assertIncludes(ci, "ClickBridgePhone");
assert.ok(!ci.includes("brew install xcodegen"), "CI must not install mutable Homebrew XcodeGen");

const relaySteps = ciDocument.jobs["relay-container"].steps;
const workflowContractStep = relaySteps.find(
  (step) => step.name === "Verify workflow contracts",
);
assert.ok(workflowContractStep, "CI must contain the workflow contract step");
const validatorInvocation = [
  "ruby",
  ".github/scripts/validate-release-workflows.rb",
];
const validatorCommand = validatorInvocation.join(" ");
assertExecutesExactCommand(
  workflowContractStep.run,
  validatorInvocation,
  "CI must directly run the release workflow validator",
);
const acceptedValidatorMutations = [
  [
    "commented validator",
    workflowContractStep.run.replace(validatorCommand, `# ${validatorCommand}`),
  ],
  [
    "validator in an uncalled function",
    workflowContractStep.run.replace(
      validatorCommand,
      `unused_validator() {\n  ${validatorCommand}\n}`,
    ),
  ],
  [
    "validator in a heredoc",
    workflowContractStep.run.replace(
      validatorCommand,
      `cat <<'VALIDATOR_COMMAND'\n${validatorCommand}\nVALIDATOR_COMMAND`,
    ),
  ],
].filter(([, mutatedRun]) => {
  try {
    assertExecutesExactCommand(
      mutatedRun,
      validatorInvocation,
      "CI must directly run the release workflow validator",
    );
    return true;
  } catch {
    return false;
  }
}).map(([name]) => name);
const appleSteps = ciDocument.jobs["apple-clients"].steps;
const appleStepNames = appleSteps.map((step) => step.name);
for (const preservedStep of [
  "Generate iOS project",
  "Verify generated project parity",
  "Select iPhone simulator",
  "Test iOS client",
  "Build iOS with strict Swift concurrency",
  "Build iOS simulator Release",
]) {
  assert.ok(
    appleStepNames.includes(preservedStep),
    `CI must preserve the ${preservedStep} step`,
  );
}
const genericDeviceStep = appleSteps.find(
  (step) => step.name === "Build unsigned iOS generic-device Release",
);
assert.ok(genericDeviceStep, "CI must build an unsigned generic-device iOS Release");
assert.equal(
  genericDeviceStep.if,
  "${{ hashFiles('ios/project.yml') != '' }}",
  "generic-device build must use the same optional iOS project guard",
);
const genericDeviceInvocation = [
  "xcodebuild",
  "-project",
  "ios/ClickBridgePhone.xcodeproj",
  "-scheme",
  "ClickBridgePhone",
  "-configuration",
  "Release",
  "-destination",
  "generic/platform=iOS",
  "-derivedDataPath",
  path.join(workflowRunnerTemp, "click-bridge-ios-device-build"),
  "CODE_SIGNING_ALLOWED=NO",
  "CODE_SIGNING_REQUIRED=NO",
  "build",
];
function assertGenericDeviceCommand(script) {
  assertExecutesExactCommand(
    script,
    genericDeviceInvocation,
    "CI must execute the exact unsigned generic-device Release command",
  );
}

assertGenericDeviceCommand(genericDeviceStep.run);
const acceptedGenericDeviceMutations = [
  [
    "missing terminal build",
    genericDeviceStep.run.replace(/\n\s+build\s*$/, ""),
  ],
  [
    "interrupted continuation",
    genericDeviceStep.run.replace(
      "-scheme ClickBridgePhone \\",
      "# interrupted continuation\n  -scheme ClickBridgePhone \\",
    ),
  ],
  [
    "contradictory code-signing argument",
    genericDeviceStep.run.replace(
      "CODE_SIGNING_ALLOWED=NO \\",
      "CODE_SIGNING_ALLOWED=NO \\\n  CODE_SIGNING_ALLOWED=YES \\",
    ),
  ],
  [
    "backslash with trailing spaces",
    genericDeviceStep.run.replace("xcodebuild \\", "xcodebuild \\  "),
  ],
].filter(([, mutatedRun]) => {
  try {
    assertGenericDeviceCommand(mutatedRun);
    return true;
  } catch {
    return false;
  }
}).map(([name]) => name);
assert.deepEqual(
  {
    validator: acceptedValidatorMutations,
    genericDevice: acceptedGenericDeviceMutations,
  },
  { validator: [], genericDevice: [] },
  `workflow command contracts accepted inert mutations: ${JSON.stringify({
    validator: acceptedValidatorMutations,
    genericDevice: acceptedGenericDeviceMutations,
  })}`,
);
assert.ok(
  appleStepNames.indexOf("Verify generated project parity")
    < appleStepNames.indexOf("Build unsigned iOS generic-device Release"),
  "generic-device build must consume the parity-checked generated project",
);
assert.ok(
  appleStepNames.indexOf("Build unsigned iOS generic-device Release")
    < appleStepNames.indexOf("Select iPhone simulator"),
  "generic-device build must not depend on simulator discovery",
);

const xcodegenVersion = "2.46.0";
const xcodegenSha256 = "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806";
const xcodegenUrl = `https://github.com/yonaskolb/XcodeGen/releases/download/${xcodegenVersion}/xcodegen.zip`;
const xcodegenWorkflows = [
  ["CI", ci, [
    "mac/ClickBridgeMac.xcodeproj/project.pbxproj",
    "mac/ClickBridgeMac/Info.plist",
    "ios/ClickBridgePhone.xcodeproj/project.pbxproj",
    "ios/ClickBridgePhone/Info.plist",
  ]],
  ["TestFlight", readRequired(".github/workflows/testflight.yml"), [
    "mac/ClickBridgeMac.xcodeproj/project.pbxproj",
    "mac/ClickBridgeMac/Info.plist",
    "ios/ClickBridgePhone.xcodeproj/project.pbxproj",
    "ios/ClickBridgePhone/Info.plist",
  ]],
  ["macOS notarized release", readRequired(".github/workflows/macos-notarized-release.yml"), [
    "mac/ClickBridgeMac.xcodeproj/project.pbxproj",
    "mac/ClickBridgeMac/Info.plist",
  ]],
];

for (const [name, workflow, generatedPaths] of xcodegenWorkflows) {
  assertIncludes(workflow, xcodegenUrl, `${name} must download pinned XcodeGen`);
  assertIncludes(workflow, xcodegenSha256, `${name} must verify pinned XcodeGen`);
  assertIncludes(workflow, 'mkdir -p "$install_root"', `${name} must create the install prefix`);
  assertIncludes(
    workflow,
    'test -f "$install_root/share/xcodegen/SettingPresets/base.yml"',
    `${name} must verify XcodeGen setting presets`,
  );
  assertIncludes(workflow, `Version: ${xcodegenVersion}`, `${name} must verify XcodeGen version`);
  assertIncludes(workflow, "set -Eeuo pipefail", `${name} generation must enable pipefail`);
  assertIncludes(workflow, "2>&1 | tee", `${name} must inspect XcodeGen output`);
  assertIncludes(
    workflow,
    "No \"[^\"]+\" settings found",
    `${name} must reject missing XcodeGen settings warnings`,
  );
  assertIncludes(workflow, "git diff --exit-code --", `${name} must reject generated project drift`);
  for (const generatedPath of generatedPaths) {
    assertIncludes(workflow, generatedPath, `${name} must check generated drift for ${generatedPath}`);
  }
}
assertIncludes(
  ci,
  "git ls-files --others --exclude-standard --",
  "CI must reject untracked generated project drift",
);
assertIncludes(ci, "Build iOS with strict Swift concurrency");
assertIncludes(ci, "SWIFT_STRICT_CONCURRENCY=complete");
assertIncludes(ci, "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES");

const xcodeCloudScriptPath = path.join(
  repositoryRoot,
  "ios/ci_scripts/ci_post_clone.sh",
);
const xcodeCloudScript = readRequired("ios/ci_scripts/ci_post_clone.sh");
assert.notEqual(
  statSync(xcodeCloudScriptPath).mode & 0o111,
  0,
  "Xcode Cloud post-clone script must be executable",
);
assertIncludes(xcodeCloudScript, "set -eu");
assertIncludes(xcodeCloudScript, "xcodegen_version='2.46.0'");
assertIncludes(xcodeCloudScript, 'mkdir -p "$install_root"');
assert.ok(
  !xcodeCloudScript.includes("CDPATH= cd"),
  "Xcode Cloud post-clone script must not trigger ShellCheck SC1007",
);
assertIncludes(
  xcodeCloudScript,
  "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806",
);
assertIncludes(xcodeCloudScript, '"$xcodegen_binary" generate');

const gitignore = readRequired(".gitignore");
for (const signingPattern of [
  "AuthKey_*.p8",
  "*.p12",
  "*.cer",
  "*.mobileprovision",
  "*.provisionprofile",
  "*.certSigningRequest",
]) {
  assertIncludes(gitignore, signingPattern);
}

const xcodeCloudRunbook = readRequired("docs/xcode-cloud.md");
assertIncludes(xcodeCloudRunbook, "PR - iOS checks");
assertIncludes(xcodeCloudRunbook, "Weekly - iOS confidence");
assertIncludes(xcodeCloudRunbook, "Release - TestFlight");
assertIncludes(xcodeCloudRunbook, "Do not enable both TestFlight upload paths");

const iosProjectSpec = readRequired("ios/project.yml");
assertIncludes(iosProjectSpec, 'CFBundleShortVersionString: "$(MARKETING_VERSION)"');
assertIncludes(iosProjectSpec, 'CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"');
assertIncludes(iosProjectSpec, "fileGroups:");
assertIncludes(iosProjectSpec, "  - TestFlight");

const iosBaseConfiguration = readRequired("ios/Config/Base.xcconfig");
assertIncludes(iosBaseConfiguration, "CODE_SIGN_STYLE = Automatic");
assertIncludes(iosBaseConfiguration, "DEVELOPMENT_TEAM = EC3R6XQ226");

const iosInfoPlist = readRequired("ios/ClickBridgePhone/Info.plist");
assertIncludes(iosInfoPlist, "<string>$(MARKETING_VERSION)</string>");
assertIncludes(iosInfoPlist, "<string>$(CURRENT_PROJECT_VERSION)</string>");

const testFlightNotes = readRequired("ios/TestFlight/WhatToTest.en-US.txt");
assertIncludes(testFlightNotes, "Trigger 3 Clicks");
assertIncludes(testFlightNotes, "exactly three independent clicks");
assertIncludes(testFlightNotes, "Accessibility");

const macTestFlightNotes = readRequired("mac/TestFlight/WhatToTest.en-US.txt");

const actionReferences = [...ci.matchAll(/^\s*uses:\s*([^\s#]+).*$/gm)].map(
  (match) => match[1],
);
assert.ok(actionReferences.length >= 2, "CI must use checkout and setup-node");
for (const reference of actionReferences) {
  assert.match(
    reference,
    /^[^/\s]+\/[^@\s]+@[0-9a-f]{40}$/,
    `${reference} must use a full commit SHA`,
  );
}

assertIncludes(
  ci,
  "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
);
assertIncludes(
  ci,
  "actions/setup-node@820762786026740c76f36085b0efc47a31fe5020",
);

readRequired(".github/scripts/verify-workflows.mjs");

const testflight = readRequired(".github/workflows/testflight.yml");
for (const contract of [
  'security find-identity -v -p basic "$keychain"',
  "3rd Party Mac Developer Installer|Mac Installer Distribution",
  "MAC_INSTALLER_CERTIFICATE_NAME",
]) {
  assertIncludes(testflight, contract, `TestFlight signing must include ${contract}`);
}

const fastfile = readRequired("fastlane/Fastfile");
assertIncludes(
  fastfile,
  'mac_installer_certificate_name = ENV.fetch("MAC_INSTALLER_CERTIFICATE_NAME")',
  "Fastfile must require the resolved Mac installer certificate name",
);
assert.equal(
  fastfile.match(/mac_installer_certificate_name/g)?.length,
  3,
  "Fastfile must use the resolved installer identity for both package selectors",
);
assert.ok(
  !fastfile.includes('installer_cert_name: "Mac Installer Distribution"'),
  "Fastfile must not use the generic installer certificate selector",
);
assert.ok(
  !fastfile.includes('installerSigningCertificate: "Mac Installer Distribution"'),
  "Fastfile must not export with the generic installer certificate selector",
);

const releaseValidation = spawnSync(
  "ruby",
  [".github/scripts/validate-release-workflows.rb"],
  { cwd: repositoryRoot, encoding: "utf8" },
);
assert.equal(
  releaseValidation.status,
  0,
  `release workflow validation failed:\n${releaseValidation.stdout}${releaseValidation.stderr}`,
);

const rubyResolution = spawnSync(
  "ruby",
  ["-rrbconfig", "-e", "print RbConfig.ruby"],
  { encoding: "utf8" },
);
assert.equal(rubyResolution.status, 0, rubyResolution.stderr);
const rubyExecutable = rubyResolution.stdout;
const macNotesFixtureDirectory = mkdtempSync(
  path.join(tmpdir(), "click-bridge-mac-testflight-notes-"),
);
const macNotesValidator = ".github/scripts/validate-release-workflows.rb";
const runMacNotesValidation = (notes) => {
  const fixturePath = path.join(macNotesFixtureDirectory, "WhatToTest.en-US.txt");
  writeFileSync(fixturePath, notes);
  return spawnSync(
    rubyExecutable,
    [macNotesValidator, "--validate-mac-testflight-notes", fixturePath],
    { cwd: repositoryRoot, encoding: "utf8" },
  );
};
const validMacNotes = `Please test the complete iPhone-to-Mac click path:

Setup and action paths:
1. Manually configure both clients with the same relay URL: use PHONE_TOKEN on the iPhone and MAC_TOKEN on the Mac.
2. Set Mac Remote control ON. In System Settings, grant Accessibility permission to Click Bridge and verify that it remains enabled.
3. Before testing actions, confirm the Mac status is Connected and the iPhone status is Ready.
4. With the pointer over a safe target, tap the on-screen Trigger 3 Clicks control.
5. Physical iPhone acceptance: NOT RUN unless actually performed. On a physical iPhone, make a real system output-volume change with the hardware volume button and confirm that normal system volume still changes. AVAudioSession observes the output-volume delta; it does not intercept the control and cannot identify the physical source.
6. AirPods, headset controls, and Control Center acceptance: NOT RUN unless each source was actually exercised. Apply the same source-agnostic output-volume observation rule.
7. Trigger an action with the App Shortcut.
8. For each accepted success from steps 4-7, verify exactly three clicks at the current pointer location plus a terminal Succeeded result and success haptic. Octo +3 authoritative target evidence: NOT RUN unless that exact counter or receiver check was actually executed.

Outcome contract:
- Relay forwarding acknowledgement: This is not a terminal result and produces no haptic.
- Ignored before send: Expect no terminal result, no haptic, and no clicks.
- Forwarded, then rejected before event posting: Expect terminal Rejected, an error haptic, and zero clicks. This includes remote control disabled, missing Accessibility permission, or event creation failure before posting.
- Post-execution result loss: Expect Unknown and no haptic. Exactly three clicks may already have completed; inspect authoritative counter or receiver evidence. Never blindly retry or reuse the action ID (actionId).

Recovery:
- Fault injection: Exercise a relay disconnect, invalid credential or revocation, clock mismatch, and taken-over state. Each condition must close the readiness gate. Require a terminal result only if the action was actually sent or forwarded.
- Taken-over state: Verify the terminal taken-over state and that the client does not auto-reconnect. Recovery requires the user to explicitly re-save or reconnect.
- Return to ready: Restore, reconnect, or reconfigure as appropriate; confirm the Mac is Connected and the iPhone is Ready, then confirm a newly accepted action produces exactly three clicks with a terminal Succeeded result and success haptic.
`;
const noteCases = [
  ["complete structured notes", validMacNotes, true],
  ["repository notes", macTestFlightNotes, true],
  [
    "paired-state claim",
    validMacNotes.replace("Mac status is Connected", "Mac status is paired"),
    false,
  ],
  [
    "missing manual phone token",
    validMacNotes.replace("PHONE_TOKEN", "phone credential"),
    false,
  ],
  [
    "physical iPhone evidence claimed",
    validMacNotes.replace("Physical iPhone acceptance: NOT RUN", "Physical iPhone acceptance: PASS"),
    false,
  ],
  [
    "pre-post rejection mislabeled unknown",
    validMacNotes.replace("Expect terminal Rejected", "Expect Unknown"),
    false,
  ],
  [
    "post-execution loss haptic claimed",
    validMacNotes.replace("Expect Unknown and no haptic", "Expect Unknown and a success haptic"),
    false,
  ],
  [
    "post-execution retry encouraged",
    validMacNotes.replace(
      "Never blindly retry or reuse the action ID (actionId)",
      "Retry the same action ID (actionId)",
    ),
    false,
  ],
  [
    "taken-over auto-reconnect allowed",
    validMacNotes.replace("does not auto-reconnect", "may auto-reconnect"),
    false,
  ],
];

try {
  for (const [name, notes, expectedSuccess] of noteCases) {
    const result = runMacNotesValidation(notes);
    const output = `${result.stdout}${result.stderr}`;
    assert.equal(
      result.status === 0,
      expectedSuccess,
      `Mac TestFlight notes fixture ${name} was mishandled:\n${output}`,
    );
  }
} finally {
  rmSync(macNotesFixtureDirectory, { recursive: true, force: true });
}
const pathWithoutPlutil = (process.env.PATH ?? "")
  .split(path.delimiter)
  .filter((entry) => !existsSync(path.join(entry, "plutil")))
  .join(path.delimiter);
const plistFixtureDirectory = mkdtempSync(
  path.join(tmpdir(), "click-bridge-plist-contract-"),
);
const macCategoryValidator = ".github/scripts/validate-release-workflows.rb";
const runMacCategoryValidation = (projectFixturePath, plistFixturePath) =>
  spawnSync(
    rubyExecutable,
    [
      macCategoryValidator,
      "--validate-mac-app-store-category",
      projectFixturePath,
      plistFixturePath,
    ],
    {
      cwd: repositoryRoot,
      encoding: "utf8",
      env: { ...process.env, PATH: pathWithoutPlutil },
    },
  );
const plistFixture = (category) => `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
${category === null ? "" : `  <key>LSApplicationCategoryType</key>\n  <string>${category}</string>\n`}</dict>
</plist>
`;
const projectFixture = (category) => `targets:
  ClickBridgeMac:
    info:
      path: ClickBridgeMac/Info.plist
      properties:
${category === null ? "" : `        LSApplicationCategoryType: ${category}\n`}`;

try {
  const fixtureCases = [
    ["utilities", "public.app-category.utilities", "public.app-category.utilities", null],
    ["project-missing", null, "public.app-category.utilities", "Mac project category must be utilities"],
    ["project-wrong", "public.app-category.productivity", "public.app-category.utilities", "Mac project category must be utilities"],
    ["plist-missing", "public.app-category.utilities", null, "Mac Info.plist category must match"],
    ["plist-wrong", "public.app-category.utilities", "public.app-category.productivity", "Mac Info.plist category must match"],
  ];
  for (const [name, projectCategory, plistCategory, expectedError] of fixtureCases) {
    const projectFixturePath = path.join(plistFixtureDirectory, `${name}.yml`);
    const plistFixturePath = path.join(plistFixtureDirectory, `${name}.plist`);
    writeFileSync(projectFixturePath, projectFixture(projectCategory));
    writeFileSync(plistFixturePath, plistFixture(plistCategory));
    const result = runMacCategoryValidation(projectFixturePath, plistFixturePath);
    const output = `${result.stdout}${result.stderr}`;
    if (expectedError === null) {
      assert.equal(result.status, 0, `Mac category fixture ${name} was mishandled:\n${output}`);
      assertIncludes(result.stdout, "Validated Mac App Store category contract.");
    } else {
      assert.notEqual(result.status, 0, `Mac category fixture ${name} unexpectedly passed`);
      assertIncludes(result.stderr, expectedError);
    }
  }
} finally {
  rmSync(plistFixtureDirectory, { recursive: true, force: true });
}

const deploy = readRequired(".github/workflows/deploy-oci.yml");
assertIncludes(deploy, "name: Deploy OCI");
assertIncludes(deploy, "workflow_run:");
assertIncludes(deploy, 'workflows: ["CI"]');
assertIncludes(deploy, "github.event.workflow_run.conclusion == 'success'");
assertIncludes(deploy, "github.event.workflow_run.event == 'push'");
assertIncludes(deploy, "github.event.workflow_run.head_branch == 'main'");
assertIncludes(deploy, "github.event.workflow_run.head_repository.full_name == github.repository");
assertIncludes(deploy, "cancel-in-progress: false");
assertIncludes(deploy, "environment:");
assertIncludes(deploy, "name: production");
assertIncludes(deploy, "github.event.workflow_run.head_sha");
assertIncludes(deploy, "secrets.OCI_DEPLOY_SSH_KEY");
assertIncludes(deploy, "vars.OCI_DEPLOY_KNOWN_HOSTS");
assertIncludes(deploy, "StrictHostKeyChecking=yes");
assertIncludes(deploy, "rsync");
assertIncludes(deploy, ".github/scripts/deploy-oci.sh");
assert.ok(!deploy.includes("PHONE_TOKEN"), "workflow must not receive relay tokens");
assert.ok(!deploy.includes("MAC_TOKEN"), "workflow must not receive relay tokens");
assert.ok(!deploy.includes("ghcr.io"), "workflow must not use a public image registry");

const deployScript = readRequired(".github/scripts/deploy-oci.sh");
assertIncludes(deployScript, "set -Eeuo pipefail");
assertIncludes(deployScript, "${CLICK_BRIDGE_ROOT:-/opt/click-bridge}");
assertIncludes(deployScript, "shared/secrets.env");
assertIncludes(deployScript, "click-bridge-relay-candidate");
assertIncludes(deployScript, "scripts/smoke-relay.mjs");
assertIncludes(deployScript, "automatic rollback verification failed");

const dependabot = readRequired(".github/dependabot.yml");
assertIncludes(dependabot, "package-ecosystem: npm");
assertIncludes(dependabot, "package-ecosystem: docker");
assertIncludes(dependabot, "package-ecosystem: github-actions");
assertIncludes(dependabot, "open-pull-requests-limit: 3");

console.log("workflow contract tests passed");
