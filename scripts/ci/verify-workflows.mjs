import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

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
assert.match(dockerfile, /^FROM node:24-alpine$/m);

console.log(`verified ${workflowFiles.length} workflow file(s)`);
