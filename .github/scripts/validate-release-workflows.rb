require "yaml"

ROOT = File.expand_path("../..", __dir__)
WORKFLOW_DIR = File.join(ROOT, ".github", "workflows")

WORKFLOWS = {
  "testflight.yml" => { environment: "testflight", concurrency: "apple-store-release" },
  "app-store-submit.yml" => { environment: "app-store", concurrency: "apple-store-release" },
  "macos-notarized-release.yml" => { environment: "macos-release", concurrency: "macos-notarized-release" },
  "ghcr-relay.yml" => { environment: "ghcr-private", concurrency: "ghcr-relay-release" }
}.freeze

PINS = {
  "actions/checkout" => "3d3c42e5aac5ba805825da76410c181273ba90b1",
  "ruby/setup-ruby" => "95ef2b042f9d7a56d8268cba8559e2842e2ad01b",
  "actions/upload-artifact" => "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
  "docker/login-action" => "dbcb813823bdd20940b903addbd779551569679f",
  "docker/setup-buildx-action" => "bb05f3f5519dd87d3ba754cc423b652a5edd6d2c",
  "docker/build-push-action" => "53b7df96c91f9c12dcc8a07bcb9ccacbed38856a",
  "docker/metadata-action" => "dc802804100637a589fabce1cb79ff13a1411302"
}.freeze

XCODEGEN_VERSION = "2.46.0"
XCODEGEN_SHA256 = "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
XCODEGEN_URL = "https://github.com/yonaskolb/XcodeGen/releases/download/#{XCODEGEN_VERSION}/xcodegen.zip"

def fail_contract(message)
  warn("release workflow contract failed: #{message}")
  exit(1)
end

def workflow_trigger(document)
  document["on"] || document[true]
end

WORKFLOWS.each do |filename, expected|
  path = File.join(WORKFLOW_DIR, filename)
  text = File.read(path)
  document = YAML.safe_load(text, aliases: true)
  trigger = workflow_trigger(document)
  fail_contract("#{filename} must be workflow_dispatch-only") unless trigger.is_a?(Hash) && trigger.keys == ["workflow_dispatch"]

  concurrency = document.fetch("concurrency")
  fail_contract("#{filename} has the wrong concurrency group") unless concurrency["group"] == expected[:concurrency]
  fail_contract("#{filename} must not cancel an in-flight release") unless concurrency["cancel-in-progress"] == false

  jobs = document.fetch("jobs")
  fail_contract("#{filename} must contain exactly one release job") unless jobs.size == 1
  job = jobs.values.first
  fail_contract("#{filename} has the wrong protected environment") unless job.dig("environment", "name") == expected[:environment]

  checkout = job.fetch("steps").find { |step| step["uses"]&.start_with?("actions/checkout@") }
  fail_contract("#{filename} is missing checkout") unless checkout
  fail_contract("#{filename} checkout must use github.sha") unless checkout.dig("with", "ref") == "${{ github.sha }}"
  fail_contract("#{filename} checkout must disable persisted credentials") unless checkout.dig("with", "persist-credentials") == false
  fail_contract("#{filename} checkout must fetch tags for the v* guard") unless checkout.dig("with", "fetch-depth") == 0
  fail_contract("#{filename} must require dispatch from its release tag") unless text.include?('test "$EVENT_REF" = "refs/tags/$RELEASE_TAG"')
  fail_contract("#{filename} must verify a vX.Y.Z tag resolves to EVENT_SHA") unless text.include?("refs/tags/${RELEASE_TAG}^{commit}") && text.include?("EVENT_SHA")

  job.fetch("steps").filter_map { |step| step["uses"] }.each do |uses|
    action, sha = uses.split("@", 2)
    fail_contract("#{filename} uses unexpected action #{action}") unless PINS.key?(action)
    fail_contract("#{filename} has the wrong pin for #{action}") unless sha == PINS.fetch(action)
  end
end

testflight = File.read(File.join(WORKFLOW_DIR, "testflight.yml"))
fail_contract("TestFlight must not upload an IPA artifact") if testflight.include?("actions/upload-artifact")
fail_contract("TestFlight must skip submission/distribution") unless File.read(File.join(ROOT, "fastlane", "Fastfile")).include?("skip_submission: true")
fail_contract("TestFlight must not distribute to testers") unless File.read(File.join(ROOT, "fastlane", "Fastfile")).include?("distribute_external: false")

%w[testflight.yml macos-notarized-release.yml].each do |filename|
  workflow = File.read(File.join(WORKFLOW_DIR, filename))
  fail_contract("#{filename} must not install XcodeGen with Homebrew") if workflow.include?("brew install xcodegen")
  fail_contract("#{filename} must download the pinned XcodeGen release") unless workflow.include?(XCODEGEN_URL)
  fail_contract("#{filename} must verify the pinned XcodeGen checksum") unless workflow.include?(XCODEGEN_SHA256) && workflow.include?("shasum -a 256 -c")
  fail_contract("#{filename} must verify the installed XcodeGen version") unless workflow.include?("Version: #{XCODEGEN_VERSION}")
end

fastfile = File.read(File.join(ROOT, "fastlane", "Fastfile"))
%w[skip_binary_upload submit_for_review automatic_release].each do |setting|
  fail_contract("Fastfile is missing #{setting}") unless fastfile.include?(setting)
end
fail_contract("App Store submission must skip binary upload") unless fastfile.include?("skip_binary_upload: true")
fail_contract("App Store submission must require review") unless fastfile.include?("submit_for_review: true")
fail_contract("App Store submission must disable automatic release") unless fastfile.include?("automatic_release: false")

macos = File.read(File.join(WORKFLOW_DIR, "macos-notarized-release.yml"))
%w[ENABLE_HARDENED_RUNTIME=YES --timestamp "notarytool submit" "stapler staple" "spctl --assess" "--draft" "retention-days: 7"].each do |contract|
  fail_contract("macOS workflow is missing #{contract}") unless macos.include?(contract.delete_prefix('"').delete_suffix('"'))
end
fail_contract("macOS release-existence guard must use an explicit conditional") if macos.include?('! gh release view "$RELEASE_TAG"')
fail_contract("macOS release-existence guard is missing") unless macos.include?('if gh release view "$RELEASE_TAG"')
fail_contract("macOS environment writes must be grouped") if macos.match?(/echo .* >> "\$GITHUB_ENV"\n\s+echo .* >> "\$GITHUB_ENV"/)
fail_contract("macOS notary log must be validated as JSON") unless macos.include?('jq empty "$notary_log"')
fail_contract("macOS notary log must not be parsed as a plist") if macos.include?('plutil -lint "$notary_log"')
fail_contract("macOS notarization audit artifact must retain result and log") unless macos.include?("ClickBridgeMac-notary-result.json") && macos.include?("ClickBridgeMac-notary-log.json") && macos.include?("Retain notarization audit for seven days")
macos_steps = YAML.safe_load(macos, aliases: true).fetch("jobs").fetch("release").fetch("steps")
audit_step = macos_steps.find { |step| step["name"] == "Retain notarization audit for seven days" }
fail_contract("macOS notarization audit artifact must run after failures") unless audit_step && audit_step["if"] == "${{ always() }}"
audit_options = audit_step.fetch("with")
fail_contract("macOS notarization audit artifact has incomplete paths") unless audit_options.fetch("path").include?("ClickBridgeMac-notary-result.json") && audit_options.fetch("path").include?("ClickBridgeMac-notary-log.json")
fail_contract("macOS notarization audit artifact must retain seven days") unless audit_options["retention-days"] == 7
fail_contract("macOS checksum must contain only the archive basename") unless macos.include?('shasum -a 256 "$archive_name" > "$archive_name.sha256"')
fail_contract("macOS checksum must not contain the runner's absolute archive path") if macos.include?('shasum -a 256 "$archive"')

ghcr = File.read(File.join(WORKFLOW_DIR, "ghcr-relay.yml"))
fail_contract("GHCR workflow must use the job token") unless ghcr.include?("password: ${{ github.token }}")
fail_contract("GHCR workflow must preserve the private-package approval gate") unless ghcr.include?("visibility is Private") && ghcr.include?("never changes package visibility")
fail_contract("GHCR workflow must suppress latest") unless ghcr.include?("latest=false")
fail_contract("GHCR workflow must publish version and SHA tags") unless ghcr.include?("value=${{ env.RELEASE_VERSION }}") && ghcr.include?("value=sha-${{ github.sha }}")
fail_contract("GHCR workflow must report the digest") unless ghcr.include?("steps.build.outputs.digest")
fail_contract("GHCR owner must enter shell through the environment") unless ghcr.include?('REPOSITORY_OWNER: ${{ github.repository_owner }}') && ghcr.include?('"$REPOSITORY_OWNER"')
fail_contract("GHCR shell must not single-quote a GitHub expression") if ghcr.include?(%q('${{ github.repository_owner }}'))
fail_contract("GHCR summary writes must be grouped") if ghcr.match?(/^\s+echo .* >> "\$GITHUB_STEP_SUMMARY"$/)
fail_contract("GHCR workflow must check both immutable tags before pushing") unless ghcr.include?('assert_tag_absent "$RELEASE_VERSION"') && ghcr.include?('assert_tag_absent "sha-$EVENT_SHA"')
fail_contract("GHCR workflow must fail when either tag already exists") unless ghcr.include?('200)') && ghcr.include?("already exists; refusing to overwrite")
fail_contract("GHCR workflow must distinguish an absent tag from registry errors") unless ghcr.include?('404)') && ghcr.include?("registry returned HTTP")
ghcr_steps = YAML.safe_load(ghcr, aliases: true).fetch("jobs").fetch("publish").fetch("steps")
tag_guard_index = ghcr_steps.index { |step| step["name"] == "Refuse to overwrite immutable image tags" }
push_index = ghcr_steps.index { |step| step["name"] == "Build and push the relay image" }
fail_contract("GHCR immutable-tag guard must run before the push step") unless tag_guard_index && push_index && tag_guard_index < push_index
fail_contract("GHCR release step must push the validated tags") unless ghcr_steps.fetch(push_index).dig("with", "push") == true

gemfile = File.read(File.join(ROOT, "Gemfile"))
fail_contract("Fastlane must be exactly 2.237.0") unless gemfile.match?(/gem ["']fastlane["'], ["']2\.237\.0["']/)

dockerfile = File.read(File.join(ROOT, "deploy", "oci", "Dockerfile"))
expected_base = "FROM node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43"
fail_contract("relay base image must use the reviewed Node 24 Alpine index digest") unless dockerfile.lines.map(&:strip).include?(expected_base)

puts("Validated #{WORKFLOWS.size} manual release workflows and Fastlane 2.237.0 contracts.")
