import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
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
assertIncludes(ci, "bash .github/scripts/test-deploy-oci.sh");
assertIncludes(ci, "docker build");
assertIncludes(ci, "ClickBridgeMac");
assertIncludes(ci, "hashFiles('ios/project.yml')");
assertIncludes(ci, "ClickBridgePhone");
assert.ok(!ci.includes("brew install xcodegen"), "CI must not install mutable Homebrew XcodeGen");

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
