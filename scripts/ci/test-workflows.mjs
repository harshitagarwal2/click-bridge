import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);

function readRequired(relativePath) {
  const absolutePath = path.join(repositoryRoot, relativePath);
  assert.ok(existsSync(absolutePath), `${relativePath} must exist`);
  return readFileSync(absolutePath, "utf8");
}

function assertIncludes(source, expected, message) {
  assert.ok(source.includes(expected), message ?? `missing ${expected}`);
}

const ci = readRequired(".github/workflows/ci.yml");

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
assertIncludes(ci, "docker build");
assertIncludes(ci, "ClickBridgeMac");
assertIncludes(ci, "hashFiles('ios/project.yml')");
assertIncludes(ci, "ClickBridgePhone");

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

readRequired("scripts/ci/verify-workflows.mjs");

console.log("workflow contract tests passed");
