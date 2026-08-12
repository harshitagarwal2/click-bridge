require "json"
require "fileutils"
require "open3"
require "rexml/document"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("../..", __dir__)
WORKFLOW_DIR = File.join(ROOT, ".github", "workflows")

WORKFLOWS = {
  "testflight.yml" => { environment: "testflight", concurrency: "apple-store-release", release_job: "upload" },
  "app-store-submit.yml" => { environment: "app-store", concurrency: "apple-store-release", release_job: "submit" },
  "macos-notarized-release.yml" => { environment: "macos-release", concurrency: "macos-notarized-release", release_job: "release" },
  "ghcr-relay.yml" => { environment: "ghcr-private", concurrency: "ghcr-relay-release", release_job: "publish" }
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

def validate_mac_app_store_category(path)
  document = REXML::Document.new(File.read(path))
  dictionary = document.elements["plist/dict"]
  elements = dictionary&.elements&.to_a || []
  category_key_index = elements.index do |element|
    element.name == "key" && element.text == "LSApplicationCategoryType"
  end
  category = elements[category_key_index + 1]&.text if category_key_index
  fail_contract("Mac App Store category must be utilities") unless category == "public.app-category.utilities"
rescue Errno::ENOENT => error
  fail_contract("Mac App Store Info.plist is unavailable: #{error.message}")
rescue REXML::ParseException => error
  fail_contract("Mac App Store Info.plist is invalid XML: #{error.message}")
end

def workflow_trigger(document)
  document["on"] || document[true]
end

def verify_guard_fixtures(filename, guard_script, environment_name)
  reviewer_rule = {
    "type" => "required_reviewers",
    "prevent_self_review" => true,
    "reviewers" => [{ "type" => "User", "reviewer" => { "login" => "independent-reviewer" } }]
  }
  valid = {
    "name" => environment_name,
    "can_admins_bypass" => false,
    "protection_rules" => [reviewer_rule]
  }
  cases = {
    "valid protected environment" => [valid, true],
    "administrator bypass enabled" => [valid.merge("can_admins_bypass" => true), false],
    "administrator bypass null" => [valid.merge("can_admins_bypass" => nil), false],
    "administrator bypass missing" => [valid.reject { |key, _| key == "can_admins_bypass" }, false],
    "required reviewer rule missing" => [valid.merge("protection_rules" => []), false],
    "self-review enabled" => [valid.merge("protection_rules" => [reviewer_rule.merge("prevent_self_review" => false)]), false],
    "reviewer list empty" => [valid.merge("protection_rules" => [reviewer_rule.merge("reviewers" => [])]), false]
  }

  Dir.mktmpdir("release-environment-guard") do |directory|
    fake_curl = File.join(directory, "curl")
    File.write(fake_curl, "#!/bin/sh\nset -eu\nprintf '%s\\n' \"${MOCK_ENVIRONMENT_JSON:?}\"\n")
    File.chmod(0o755, fake_curl)

    cases.each do |case_name, (fixture, expected_success)|
      environment = {
        "GH_TOKEN" => "synthetic-job-token",
        "GITHUB_REPOSITORY" => "example/click-bridge",
        "RELEASE_ENVIRONMENT" => environment_name,
        "MOCK_ENVIRONMENT_JSON" => JSON.generate(fixture),
        "PATH" => "#{directory}:#{ENV.fetch("PATH")}"
      }
      stdout, stderr, status = Open3.capture3(environment, "bash", "-c", guard_script)
      next if status.success? == expected_success

      fail_contract("#{filename} environment guard mishandled #{case_name}: #{stdout}#{stderr}")
    end
  end
end

def require_script_order(script, earlier, later, message)
  earlier_index = script.index(earlier)
  later_index = script.index(later)
  fail_contract(message) unless earlier_index && later_index && earlier_index < later_index
end

def verify_testflight_cleanup(cleanup_script)
  Dir.mktmpdir("testflight-cleanup") do |runner_temp|
    home = File.join(runner_temp, "home")
    fake_bin = File.join(runner_temp, "fake-bin")
    installed_profiles = [
      File.join(home, "Library", "MobileDevice", "Provisioning Profiles", "fixture-ios.mobileprovision"),
      File.join(home, "Library", "MobileDevice", "Provisioning Profiles", "fixture-mac.provisionprofile")
    ]
    secret_files = %w[
      click-bridge-signing.keychain-db
      ios-apple-distribution.p12
      click-bridge-ios.mobileprovision
      click-bridge-ios-profile.plist
      mac-apple-distribution.p12
      mac-installer-distribution.p12
      click-bridge-mac.provisionprofile
      click-bridge-mac-profile.plist
      click-bridge-app-store-connect-key.p8
      ClickBridgePhone.ipa
      ClickBridgePhone.app.dSYM.zip
      ClickBridgeMac.pkg
      ClickBridgeMac.app.dSYM.zip
    ].map { |name| File.join(runner_temp, name) }
    archive_directories = %w[
      ClickBridgePhone.xcarchive
      ClickBridgeMac.xcarchive
      ClickBridgeMac.app
    ].map { |name| File.join(runner_temp, name) }
    cleanup_paths = secret_files + archive_directories + installed_profiles

    FileUtils.mkdir_p(fake_bin)
    fake_security = File.join(fake_bin, "security")
    File.write(fake_security, <<~SH)
      #!/bin/sh
      set -eu
      if [ "${FAKE_SECURITY_FAIL:-0}" = "1" ]; then
        exit 42
      fi
      test "$1" = "delete-keychain"
      rm -f -- "$2"
    SH
    File.chmod(0o755, fake_security)

    materialize = lambda do
      (secret_files + installed_profiles).each do |path|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "fixture")
      end
      archive_directories.each do |path|
        FileUtils.mkdir_p(path)
        File.write(File.join(path, "fixture"), "archive")
      end
    end
    environment = {
      "HOME" => home,
      "RUNNER_TEMP" => runner_temp,
      "IOS_SIGNING_PROFILE_PATH" => installed_profiles.fetch(0),
      "MAC_SIGNING_PROFILE_PATH" => installed_profiles.fetch(1),
      "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}"
    }
    run_cleanup = lambda do |extra_environment = {}|
      Open3.capture3(environment.merge(extra_environment), "bash", "-c", cleanup_script)
    end

    materialize.call
    stdout, stderr, status = run_cleanup.call
    fail_contract("TestFlight cleanup failed for materialized fixtures: #{stdout}#{stderr}") unless status.success?
    leftovers = cleanup_paths.select { |path| File.exist?(path) }
    fail_contract("TestFlight cleanup retained #{leftovers.join(", ")}") unless leftovers.empty?

    stdout, stderr, status = run_cleanup.call
    fail_contract("TestFlight cleanup must be idempotent: #{stdout}#{stderr}") unless status.success?

    deterministic_paths = secret_files + archive_directories
    deterministic_paths.each do |path|
      if File.extname(path).empty? || path.end_with?(".app", ".xcarchive")
        FileUtils.mkdir_p(path)
        File.write(File.join(path, "fixture"), "output")
      else
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "fixture")
      end
    end
    partial_environment = environment.reject { |key, _| %w[IOS_SIGNING_PROFILE_PATH MAC_SIGNING_PROFILE_PATH].include?(key) }
    stdout, stderr, status = Open3.capture3(partial_environment, "bash", "-c", cleanup_script)
    fail_contract("TestFlight cleanup failed before profile-path publication: #{stdout}#{stderr}") unless status.success?
    leftovers = deterministic_paths.select { |path| File.exist?(path) }
    fail_contract("TestFlight partial cleanup retained #{leftovers.join(", ")}") unless leftovers.empty?

    materialize.call
    stdout, stderr, status = run_cleanup.call("FAKE_SECURITY_FAIL" => "1")
    fail_contract("TestFlight cleanup must report keychain deletion failure") if status.success?
    leftovers = cleanup_paths.select { |path| File.exist?(path) }
    fail_contract("TestFlight cleanup failure retained #{leftovers.join(", ")}: #{stdout}#{stderr}") unless leftovers.empty?
  end
end

if ARGV.first == "--validate-mac-app-store-category"
  fail_contract("Mac App Store category validation requires one plist path") unless ARGV.length == 2
  validate_mac_app_store_category(ARGV.fetch(1))
  puts("Validated Mac App Store category contract.")
  exit(0)
end

WORKFLOWS.each do |filename, expected|
  path = File.join(WORKFLOW_DIR, filename)
  text = File.read(path)
  document = YAML.safe_load(text, aliases: true)
  trigger = workflow_trigger(document)
  fail_contract("#{filename} must be workflow_dispatch-only") unless trigger.is_a?(Hash) && trigger.keys == ["workflow_dispatch"]
  fail_contract("#{filename} must grant Actions read access for runtime environment checks") unless document.dig("permissions", "actions") == "read"

  concurrency = document.fetch("concurrency")
  fail_contract("#{filename} has the wrong concurrency group") unless concurrency["group"] == expected[:concurrency]
  fail_contract("#{filename} must not cancel an in-flight release") unless concurrency["cancel-in-progress"] == false

  jobs = document.fetch("jobs")
  fail_contract("#{filename} must contain one preflight and one release job") unless jobs.keys.sort == [expected[:release_job], "verify-environment"].sort
  preflight = jobs.fetch("verify-environment")
  fail_contract("#{filename} preflight must not declare an environment") if preflight.key?("environment")
  fail_contract("#{filename} preflight must have only Actions read permission") unless preflight["permissions"] == { "actions" => "read" }
  fail_contract("#{filename} preflight must run on Ubuntu 24.04") unless preflight["runs-on"] == "ubuntu-24.04"

  preflight_steps = preflight.fetch("steps")
  fail_contract("#{filename} preflight must contain exactly one guard step") unless preflight_steps.size == 1
  guard = preflight_steps.first
  fail_contract("#{filename} is missing the fail-closed environment guard") unless guard["name"] == "Require independent release approval"
  fail_contract("#{filename} environment guard must use the job token") unless guard.dig("env", "GH_TOKEN") == "${{ github.token }}"
  fail_contract("#{filename} environment guard must verify the named environment") unless guard.dig("env", "RELEASE_ENVIRONMENT") == expected[:environment]
  guard_script = guard.fetch("run")
  fail_contract("#{filename} environment guard must GET the documented environment endpoint") unless guard_script.include?("/repos/${GITHUB_REPOSITORY}/environments/${encoded_environment}")
  fail_contract("#{filename} environment guard must fail on missing or unreadable environments") unless guard_script.include?("curl --fail-with-body")
  fail_contract("#{filename} environment guard must require reviewers") unless guard_script.include?('.type == "required_reviewers"') && guard_script.include?("length >= 1")
  fail_contract("#{filename} environment guard must prevent self-review") unless guard_script.include?(".prevent_self_review == true")
  fail_contract("#{filename} environment guard must reject administrator bypass or a missing field") unless guard_script.include?(".can_admins_bypass == false")
  verify_guard_fixtures(filename, guard_script, expected[:environment])

  job = jobs.fetch(expected[:release_job])
  fail_contract("#{filename} has the wrong protected environment") unless job.dig("environment", "name") == expected[:environment]
  fail_contract("#{filename} release job must depend on the environment preflight") unless job["needs"] == "verify-environment"

  steps = job.fetch("steps")
  release_guard = steps.first
  fail_contract("#{filename} release job must revalidate the environment before any other step") unless release_guard["name"] == "Revalidate protected release environment"
  fail_contract("#{filename} release revalidation must use the job token") unless release_guard.dig("env", "GH_TOKEN") == "${{ github.token }}"
  fail_contract("#{filename} release revalidation must verify the named environment") unless release_guard.dig("env", "RELEASE_ENVIRONMENT") == expected[:environment]
  release_guard_script = release_guard.fetch("run")
  fail_contract("#{filename} preflight and release revalidation must use the exact same guard") unless release_guard_script == guard_script
  verify_guard_fixtures("#{filename} release revalidation", release_guard_script, expected[:environment])

  checkout_index = steps.index { |step| step["uses"]&.start_with?("actions/checkout@") }
  checkout = checkout_index && steps.fetch(checkout_index)
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
testflight_steps = YAML.safe_load(testflight, aliases: true).fetch("jobs").fetch("upload").fetch("steps")
signing_step = testflight_steps.find { |step| step["name"] == "Configure ephemeral App Store signing" }
cleanup_step = testflight_steps.find { |step| step["name"] == "Remove ephemeral signing material" }
fail_contract("TestFlight is missing signing setup") unless signing_step
fail_contract("TestFlight is missing signing cleanup") unless cleanup_step
fail_contract("TestFlight signing cleanup must run after failures") unless cleanup_step["if"] == "${{ always() }}"
signing_script = signing_step.fetch("run")
cleanup_script = cleanup_step.fetch("run")
first_secret_write = %(printf '%s' "$IOS_CERTIFICATE_BASE64")
require_script_order(signing_script, "umask 077", first_secret_write, "TestFlight signing setup must set a restrictive umask before materializing secrets")
%w[
  APP_STORE_CONNECT_KEY_PATH
  SIGNING_KEYCHAIN
  IOS_SIGNING_CERTIFICATE_PATH
  IOS_SIGNING_INPUT_PROFILE_PATH
  IOS_SIGNING_PROFILE_PLIST_PATH
  MAC_DISTRIBUTION_CERTIFICATE_PATH
  MAC_INSTALLER_CERTIFICATE_PATH
  MAC_SIGNING_INPUT_PROFILE_PATH
  MAC_SIGNING_PROFILE_PLIST_PATH
].each do |variable|
  require_script_order(
    signing_script,
    "#{variable}=%s",
    first_secret_write,
    "TestFlight signing setup must publish #{variable} before materializing secrets"
  )
end
require_script_order(
  signing_script,
  "IOS_SIGNING_PROFILE_PATH=%s",
  %(cp "$ios_profile" "$ios_installed_profile"),
  "TestFlight signing setup must publish the installed iOS profile path before copying it"
)
require_script_order(
  signing_script,
  "MAC_SIGNING_PROFILE_PATH=%s",
  %(cp "$mac_profile" "$mac_installed_profile"),
  "TestFlight signing setup must publish the installed Mac profile path before copying it"
)
verify_testflight_cleanup(cleanup_script)
fail_contract("TestFlight must not upload an IPA artifact") if testflight.include?("actions/upload-artifact")
fail_contract("TestFlight must skip submission/distribution") unless File.read(File.join(ROOT, "fastlane", "Fastfile")).include?("skip_submission: true")
fail_contract("TestFlight must not distribute to testers") unless File.read(File.join(ROOT, "fastlane", "Fastfile")).include?("distribute_external: false")
%w[ios/ClickBridgePhone/Info.plist mac/ClickBridgeMac/Info.plist].each do |relative_path|
  info_plist = File.read(File.join(ROOT, relative_path))
  fail_contract("#{relative_path} must consume MARKETING_VERSION") unless info_plist.include?("$(MARKETING_VERSION)")
  fail_contract("#{relative_path} must consume CURRENT_PROJECT_VERSION") unless info_plist.include?("$(CURRENT_PROJECT_VERSION)")
end
%w[
  MAC_DISTRIBUTION_CERTIFICATE_BASE64
  MAC_DISTRIBUTION_CERTIFICATE_PASSWORD
  MAC_INSTALLER_CERTIFICATE_BASE64
  MAC_INSTALLER_CERTIFICATE_PASSWORD
  MAC_PROVISIONING_PROFILE_BASE64
  MAC_PROVISIONING_PROFILE_NAME
  ClickBridgeMac.pkg
].each do |contract|
  fail_contract("TestFlight workflow is missing #{contract}") unless testflight.include?(contract)
end
fail_contract("TestFlight workflow must invoke the Mac upload lane") unless testflight.include?("fastlane mac upload_testflight")

mac_entitlements_path = File.join(ROOT, "mac", "ClickBridgeMac", "ClickBridgeMac-AppStore.entitlements")
fail_contract("Mac TestFlight entitlements file is missing") unless File.file?(mac_entitlements_path)
mac_entitlements = File.read(mac_entitlements_path)
%w[com.apple.security.app-sandbox com.apple.security.network.client].each do |entitlement|
  fail_contract("Mac TestFlight entitlements are missing #{entitlement}") unless mac_entitlements.include?(entitlement)
end

mac_info_plist_path = File.join(ROOT, "mac", "ClickBridgeMac", "Info.plist")
validate_mac_app_store_category(mac_info_plist_path)

%w[testflight.yml macos-notarized-release.yml].each do |filename|
  workflow = File.read(File.join(WORKFLOW_DIR, filename))
  fail_contract("#{filename} must not install XcodeGen with Homebrew") if workflow.include?("brew install xcodegen")
  fail_contract("#{filename} must download the pinned XcodeGen release") unless workflow.include?(XCODEGEN_URL)
  fail_contract("#{filename} must verify the pinned XcodeGen checksum") unless workflow.include?(XCODEGEN_SHA256) && workflow.include?("shasum -a 256 -c")
  fail_contract("#{filename} must verify the installed XcodeGen version") unless workflow.include?("Version: #{XCODEGEN_VERSION}")
end

fastfile = File.read(File.join(ROOT, "fastlane", "Fastfile"))
fail_contract("Fastfile is missing the macOS TestFlight platform") unless fastfile.include?("platform :mac do")
ios_lane = fastfile[/platform :ios do.*?(?=platform :mac do)/m]
mac_lane = fastfile[/platform :mac do.*\z/m]
fail_contract("Fastfile is missing the iOS TestFlight lane") unless ios_lane
fail_contract("Fastfile is missing the macOS TestFlight lane") unless mac_lane
fail_contract("Mac TestFlight upload must select macOS") unless fastfile.include?('app_platform: "osx"')
fail_contract("Mac TestFlight upload must use a pkg") unless fastfile.include?("pkg: output_path")
mac_output_name = mac_lane[/output_name:\s*"([^"]+)"/, 1]
fail_contract("Mac TestFlight package output_name must be a literal") unless mac_output_name
fail_contract("Mac TestFlight package output_name must resolve to ClickBridgeMac.pkg") unless "#{mac_output_name}.pkg" == "ClickBridgeMac.pkg"
fail_contract("Mac TestFlight upload must use the package path returned by build_mac_app") unless mac_lane.include?("output_path = build_mac_app(")
{
  "iOS" => [ios_lane, "ClickBridgePhone.xcarchive"],
  "Mac" => [mac_lane, "ClickBridgeMac.xcarchive"]
}.each do |platform, (lane, archive_name)|
  expected_path = %(archive_path = File.join(output_directory, "#{archive_name}"))
  fail_contract("#{platform} TestFlight archive must live under RUNNER_TEMP") unless lane.include?(expected_path)
  fail_contract("#{platform} TestFlight build must use its explicit archive path") unless lane.scan("archive_path: archive_path").one?
end
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
digest_guard_index = ghcr_steps.index { |step| step["name"] == "Verify published tags resolve to the pushed digest" }
fail_contract("GHCR immutable-tag guard must run before the push step") unless tag_guard_index && push_index && tag_guard_index < push_index
fail_contract("GHCR release step must push the validated tags") unless ghcr_steps.fetch(push_index).dig("with", "push") == true
fail_contract("GHCR must verify both published tags after the push") unless digest_guard_index && push_index < digest_guard_index
digest_guard = ghcr_steps.fetch(digest_guard_index).fetch("run")
fail_contract("GHCR post-push verification must compare with the action digest") unless digest_guard.include?('"$actual_digest" != "$IMAGE_DIGEST"')
fail_contract("GHCR post-push verification must check both tags") unless digest_guard.include?('assert_tag_digest "$RELEASE_VERSION"') && digest_guard.include?('assert_tag_digest "sha-$EVENT_SHA"')

gemfile = File.read(File.join(ROOT, "Gemfile"))
fail_contract("Fastlane must be exactly 2.237.0") unless gemfile.match?(/gem ["']fastlane["'], ["']2\.237\.0["']/)

dockerfile = File.read(File.join(ROOT, "deploy", "oci", "Dockerfile"))
expected_base = "FROM node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43"
fail_contract("relay base image must use the reviewed Node 24 Alpine index digest") unless dockerfile.lines.map(&:strip).include?(expected_base)

puts("Validated #{WORKFLOWS.size} manual release workflows and Fastlane 2.237.0 contracts.")
