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
  "actions/attest" => "1e69f48acb82d1966a394da916b4c1698aa569d6",
  "actions/checkout" => "3d3c42e5aac5ba805825da76410c181273ba90b1",
  "ruby/setup-ruby" => "95ef2b042f9d7a56d8268cba8559e2842e2ad01b",
  "actions/upload-artifact" => "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
  "docker/login-action" => "dbcb813823bdd20940b903addbd779551569679f",
  "docker/setup-qemu-action" => "96fe6ef7f33517b61c61be40b68a1882f3264fb8",
  "docker/setup-buildx-action" => "bb05f3f5519dd87d3ba754cc423b652a5edd6d2c",
  "docker/build-push-action" => "53b7df96c91f9c12dcc8a07bcb9ccacbed38856a",
  "docker/metadata-action" => "dc802804100637a589fabce1cb79ff13a1411302"
}.freeze

QEMU_IMAGE = "docker.io/tonistiigi/binfmt@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0"

XCODEGEN_VERSION = "2.46.0"
XCODEGEN_SHA256 = "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
XCODEGEN_URL = "https://github.com/yonaskolb/XcodeGen/releases/download/#{XCODEGEN_VERSION}/xcodegen.zip"
VERSION_FILE = File.join(ROOT, "Config", "Version.xcconfig")
VERSION_READER = File.join(ROOT, ".github", "scripts", "read-apple-version.sh")

def fail_contract(message)
  warn("release workflow contract failed: #{message}")
  exit(1)
end

def read_version_setting(name)
  matches = File.readlines(VERSION_FILE).filter_map do |line|
    next if line.lstrip.start_with?("//")

    match = line.sub(%r{//.*$}, "").match(/^\s*#{Regexp.escape(name)}\s*=\s*(\S.*?)\s*$/)
    match && match[1]
  end
  fail_contract("#{name} must appear exactly once in Config/Version.xcconfig") unless matches.length == 1
  matches.first
rescue Errno::ENOENT => error
  fail_contract("shared Apple version contract is unavailable: #{error.message}")
end

def validate_shared_version_contract
  marketing_version = read_version_setting("MARKETING_VERSION")
  build_number = read_version_setting("CURRENT_PROJECT_VERSION")
  marketing_pattern = /\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*))?\z/
  build_pattern = /\A[1-9][0-9]*(?:\.[0-9]+){0,2}\z/
  fail_contract("shared MARKETING_VERSION must be X.Y or X.Y.Z") unless marketing_pattern.match?(marketing_version)
  fail_contract("shared CURRENT_PROJECT_VERSION must be an Apple build string") unless build_pattern.match?(build_number)
  fail_contract("Apple version reader must be executable") unless File.executable?(VERSION_READER)

  { "marketing" => marketing_version, "build" => build_number }.each do |selector, expected|
    output, error, status = Open3.capture3(VERSION_READER, selector)
    fail_contract("Apple version reader failed for #{selector}: #{error}") unless status.success?
    fail_contract("Apple version reader disagrees for #{selector}") unless output.strip == expected
  end

  %w[ios mac].each do |platform|
    base_path = File.join(ROOT, platform, "Config", "Base.xcconfig")
    base = File.read(base_path)
    include_line = '#include "../../Config/Version.xcconfig"'
    fail_contract("#{platform} Base.xcconfig must include the shared version contract exactly once") unless base.scan(include_line).one?
    local_index = base.index('#include? "Local.xcconfig"')
    version_index = base.index(include_line)
    fail_contract("#{platform} local signing config must not override app versions") unless local_index && version_index && local_index < version_index

    project = YAML.safe_load(File.read(File.join(ROOT, platform, "project.yml")), aliases: true)
    settings = project.dig("settings", "base") || {}
    fail_contract("#{platform}/project.yml must not duplicate MARKETING_VERSION") if settings.key?("MARKETING_VERSION")
    fail_contract("#{platform}/project.yml must not duplicate CURRENT_PROJECT_VERSION") if settings.key?("CURRENT_PROJECT_VERSION")
  end
end

def validate_mac_app_store_category(project_path, plist_path)
  project = YAML.safe_load(File.read(project_path), aliases: true)
  project_category = project.dig("targets", "ClickBridgeMac", "info", "properties", "LSApplicationCategoryType")
  fail_contract("Mac project category must be utilities") unless project_category == "public.app-category.utilities"

  document = REXML::Document.new(File.read(plist_path))
  dictionary = document.elements["plist/dict"]
  elements = dictionary&.elements&.to_a || []
  category_key_index = elements.index do |element|
    element.name == "key" && element.text == "LSApplicationCategoryType"
  end
  category = elements[category_key_index + 1]&.text if category_key_index
  fail_contract("Mac Info.plist category must match the Mac project category") unless category == project_category
rescue Errno::ENOENT => error
  fail_contract("Mac App Store category source is unavailable: #{error.message}")
rescue Psych::SyntaxError => error
  fail_contract("Mac project.yml is invalid YAML: #{error.message}")
rescue REXML::ParseException => error
  fail_contract("Mac App Store Info.plist is invalid XML: #{error.message}")
end

def validate_mac_testflight_notes(notes_path)
  title = "Please test the complete iPhone-to-Mac click path:"
  contracts = {
    "Setup and action paths:" => [
      /\A1\. Use an operator-bootstrapped Mac that is already connected to the relay\. Normal testers do not enter a relay URL, PHONE_TOKEN, or MAC_TOKEN\. Never put PHONE_TOKEN or MAC_TOKEN in a URL, log, screenshot, or Git\.\z/,
      /\A2\. In Mac Settings, choose Pair Phone\. If a phone is enrolled, choose Replace Phone… and confirm\.\z/,
      /\A3\. Scan the nearby QR code, or choose Share Secure Setup Link… to send the HTTPS link to a phone anywhere on the internet\. The link is single-use and expires after five minutes\. Without the native app, use Other Ways to Connect > Copy Browser Invitation Link for the \/pair\/web browser fallback\.\z/,
      /\A4\. Confirm that both devices show the same six-digit code, then have the Mac owner approve it\. The internet link never bypasses code comparison and approval; do not approve a mismatch\.\z/,
      /\A5\. Set Mac Remote control ON\. In System Settings, grant Accessibility permission to Click Bridge and verify that it remains enabled\.\z/,
      /\A6\. Before testing actions, confirm the Mac status is Connected and the iPhone status is Ready\.\z/,
      /\A7\. With the pointer over a safe target, tap the on-screen Trigger 3 Clicks control\.\z/,
      /\A8\. Physical iPhone acceptance: NOT RUN unless actually performed\. On a physical iPhone, make a real system output-volume change with the hardware volume button and confirm that normal system volume still changes\. AVAudioSession observes the output-volume delta; it does not intercept the control and cannot identify the physical source\.\z/,
      /\A9\. AirPods, headset controls, and Control Center acceptance: NOT RUN unless each source was actually exercised\. Apply the same source-agnostic output-volume observation rule\.\z/,
      /\A10\. Trigger an action with the App Shortcut\.\z/,
      /\A11\. For each accepted success from steps 7-10, verify exactly three clicks at the current pointer location plus a terminal Succeeded result and success haptic\. Octo \+3 authoritative target evidence: NOT RUN unless that exact counter or receiver check was actually executed\.\z/
    ],
    "Outcome contract:" => [
      /\A- Relay forwarding acknowledgement: This is not a terminal result and produces no haptic\.\z/,
      /\A- Ignored before send: Expect no terminal result, no haptic, and no clicks\.\z/,
      /\A- Forwarded, then rejected before event posting: Expect terminal Rejected, an error haptic, and zero clicks\. This includes remote control disabled, missing Accessibility permission, or event creation failure before posting\.\z/,
      /\A- Post-execution result loss: Expect Unknown and no haptic\. Exactly three clicks may already have completed; inspect authoritative counter or receiver evidence\. Never blindly retry or reuse the action ID \(actionId\)\.\z/
    ],
    "Recovery:" => [
      /\A- Fault injection: Exercise a relay disconnect, invalid credential or revocation, clock mismatch, and taken-over state\. Each condition must close the readiness gate\. Require a terminal result only if the action was actually sent or forwarded\.\z/,
      /\A- Taken-over state: Verify the terminal taken-over state and that the client does not auto-reconnect\. Recovery requires the user to explicitly choose Save & Reconnect or reconnect\.\z/,
      /\A- Return to ready: Restore, reconnect, or reconfigure as appropriate; confirm the Mac is Connected and the iPhone is Ready, then confirm a newly accepted action produces exactly three clicks with a terminal Succeeded result and success haptic\.\z/
    ]
  }.freeze

  lines = File.readlines(notes_path, chomp: true).map(&:strip).reject(&:empty?)
  fail_contract("Mac TestFlight notes must start with the receiver test title") unless lines.shift == title

  sections = {}
  current_heading = nil
  lines.each do |line|
    if contracts.key?(line)
      fail_contract("Mac TestFlight notes repeat #{line}") if sections.key?(line)

      current_heading = line
      sections[current_heading] = []
    else
      fail_contract("Mac TestFlight notes have content outside a required section") unless current_heading

      sections.fetch(current_heading) << line
    end
  end

  fail_contract("Mac TestFlight notes must contain the required sections in order") unless sections.keys == contracts.keys
  contracts.each do |heading, patterns|
    actual_lines = sections.fetch(heading)
    fail_contract("Mac TestFlight notes #{heading} has the wrong number of contract entries") unless actual_lines.length == patterns.length

    patterns.zip(actual_lines).each_with_index do |(pattern, actual), index|
      next if pattern.match?(actual)

      fail_contract("Mac TestFlight notes #{heading} entry #{index + 1} violates the release evidence contract")
    end
  end
rescue Errno::ENOENT => error
  fail_contract("Mac TestFlight notes are unavailable: #{error.message}")
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

def verify_mac_installer_identity_fixtures(signing_script)
  selection_script = signing_script[/# BEGIN Mac installer identity selection\n(.*?)# END Mac installer identity selection/m, 1]
  fail_contract("TestFlight signing setup is missing the testable Mac installer identity selection block") unless selection_script

  fixtures = {
    "legacy installer identity" => [
      '  1) 80CF878753058CD605E3955D5AAD7DD205A4CA7D "3rd Party Mac Developer Installer: Pulkit Agarwal (EC3R6XQ226)"',
      true,
      "3rd Party Mac Developer Installer: Pulkit Agarwal (EC3R6XQ226)"
    ],
    "modern installer identity" => [
      '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Mac Installer Distribution: Example Developer (ABCDE12345)"',
      true,
      "Mac Installer Distribution: Example Developer (ABCDE12345)"
    ],
    "missing installer identity" => [
      '  1) ABCDEF0123456789ABCDEF0123456789ABCDEF01 "Apple Distribution: Example Developer (ABCDE12345)"',
      false,
      nil
    ],
    "ambiguous installer identities" => [
      <<~OUTPUT.chomp,
          1) 80CF878753058CD605E3955D5AAD7DD205A4CA7D "3rd Party Mac Developer Installer: Pulkit Agarwal (EC3R6XQ226)"
          2) 0123456789ABCDEF0123456789ABCDEF01234567 "Mac Installer Distribution: Example Developer (ABCDE12345)"
      OUTPUT
      false,
      nil
    ]
  }

  Dir.mktmpdir("mac-installer-identity") do |directory|
    fake_security = File.join(directory, "security")
    File.write(fake_security, <<~SH)
      #!/bin/sh
      set -eu
      test "$1" = "find-identity"
      printf '%s\n' "${MOCK_IDENTITIES:?}"
    SH
    File.chmod(0o755, fake_security)

    fixtures.each do |case_name, (identity_output, expected_success, expected_name)|
      github_env = File.join(directory, "github-env")
      FileUtils.rm_f(github_env)
      environment = {
        "GITHUB_ENV" => github_env,
        "MOCK_IDENTITIES" => identity_output,
        "PATH" => "#{directory}:#{ENV.fetch("PATH")}",
        "keychain" => File.join(directory, "fixture.keychain-db")
      }
      stdout, stderr, status = Open3.capture3(environment, "bash", "-c", selection_script)
      if status.success? != expected_success
        fail_contract("TestFlight Mac installer identity selection mishandled #{case_name}: #{stdout}#{stderr}")
      end
      next unless expected_success

      published = File.read(github_env)
      expected_line = "MAC_INSTALLER_CERTIFICATE_NAME=#{expected_name}\n"
      fail_contract("TestFlight Mac installer identity selection published the wrong name for #{case_name}") unless published == expected_line
    end
  end
end

def verify_xcodegen_generation_guard(filename, step_name, script)
  Dir.mktmpdir("xcodegen-generation-guard") do |directory|
    fake_bin = File.join(directory, "bin")
    FileUtils.mkdir_p(fake_bin)
    fake_xcodegen = File.join(fake_bin, "xcodegen")
    File.write(fake_xcodegen, <<~SH)
      #!/bin/sh
      set -eu
      printf '%s\n' "${XCODEGEN_FIXTURE_OUTPUT:-Created project}"
      exit "${XCODEGEN_FIXTURE_STATUS:-0}"
    SH
    File.chmod(0o755, fake_xcodegen)
    environment = {
      "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}",
      "RUNNER_TEMP" => directory
    }
    cases = {
      "valid output" => [{}, true],
      "missing settings warning" => [{ "XCODEGEN_FIXTURE_OUTPUT" => 'No "base" settings found' }, false],
      "generation command failure" => [{ "XCODEGEN_FIXTURE_STATUS" => "42" }, false]
    }

    cases.each do |case_name, (extra_environment, expected_success)|
      stdout, stderr, status = Open3.capture3(environment.merge(extra_environment), "bash", "-c", script, chdir: directory)
      next if status.success? == expected_success

      fail_contract("#{filename} #{step_name} mishandled #{case_name}: #{stdout}#{stderr}")
    end
  end
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
  fail_contract("Mac App Store category validation requires project and plist paths") unless ARGV.length == 3
  validate_mac_app_store_category(ARGV.fetch(1), ARGV.fetch(2))
  puts("Validated Mac App Store category contract.")
  exit(0)
end

if ARGV.first == "--validate-mac-testflight-notes"
  fail_contract("Mac TestFlight notes validation requires one notes path") unless ARGV.length == 2
  validate_mac_testflight_notes(ARGV.fetch(1))
  puts("Validated Mac TestFlight notes contract.")
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
  source_guard_index = steps.index { |step| step["run"]&.include?('refs/tags/${RELEASE_TAG}^{commit}') }
  source_guard = source_guard_index && steps.fetch(source_guard_index)
  fail_contract("#{filename} is missing its release source guard") unless source_guard
  fail_contract("#{filename} release source guard must run after checkout") unless checkout_index < source_guard_index
  fail_contract("#{filename} release source guard must use the job token") unless source_guard.dig("env", "GH_TOKEN") == "${{ github.token }}"
  source_guard_script = source_guard.fetch("run")
  fail_contract("#{filename} must require dispatch from its release tag") unless source_guard_script.include?('test "$EVENT_REF" = "refs/tags/$RELEASE_TAG"')
  fail_contract("#{filename} must verify its version tag resolves to EVENT_SHA") unless source_guard_script.include?("refs/tags/${RELEASE_TAG}^{commit}") && source_guard_script.include?("EVENT_SHA")
  fail_contract("#{filename} must require EVENT_SHA to be reachable from origin/main") unless source_guard_script.include?('git merge-base --is-ancestor "$EVENT_SHA" refs/remotes/origin/main')
  fail_contract("#{filename} must query CI runs for the exact release SHA") unless source_guard_script.include?("actions/workflows/ci.yml/runs") && source_guard_script.include?('head_sha=${EVENT_SHA}')
  fail_contract("#{filename} must restrict the release CI proof to main push runs") unless source_guard_script.include?('branch=main') && source_guard_script.include?('event=push')
  fail_contract("#{filename} must require a completed successful CI run") unless source_guard_script.include?('.status == "completed"') && source_guard_script.include?('.conclusion == "success"')

  job.fetch("steps").filter_map { |step| step["uses"] }.each do |uses|
    action, sha = uses.split("@", 2)
    fail_contract("#{filename} uses unexpected action #{action}") unless PINS.key?(action)
    fail_contract("#{filename} has the wrong pin for #{action}") unless sha == PINS.fetch(action)
  end
end

validate_shared_version_contract

testflight = File.read(File.join(WORKFLOW_DIR, "testflight.yml"))
testflight_steps = YAML.safe_load(testflight, aliases: true).fetch("jobs").fetch("upload").fetch("steps")
signing_step = testflight_steps.find { |step| step["name"] == "Configure ephemeral App Store signing" }
cleanup_step = testflight_steps.find { |step| step["name"] == "Remove ephemeral signing material" }
fail_contract("TestFlight is missing signing setup") unless signing_step
fail_contract("TestFlight is missing signing cleanup") unless cleanup_step
fail_contract("TestFlight signing cleanup must run after failures") unless cleanup_step["if"] == "${{ always() }}"
signing_script = signing_step.fetch("run")
cleanup_script = cleanup_step.fetch("run")
verify_mac_installer_identity_fixtures(signing_script)
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
  "https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer",
  %(security import "$wwdr_g3" -k "$keychain" -t cert),
  "TestFlight signing setup must download WWDR G3 from Apple before importing it"
)
fail_contract("TestFlight signing setup must pin WWDR G3") unless signing_script.include?("dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f")
require_script_order(
  signing_script,
  %q(printf '%s  %s\n' "$wwdr_g3_sha256" "$wwdr_g3" | shasum -a 256 -c -),
  %(security verify-cert -q -l -p basic),
  "TestFlight signing setup must verify the pinned WWDR G3 before checking its Apple trust chain"
)
require_script_order(
  signing_script,
  %(security verify-cert -q -l -p basic),
  %(security import "$wwdr_g3" -k "$keychain" -t cert),
  "TestFlight signing setup must verify WWDR G3 against Apple roots before importing it"
)
require_script_order(
  signing_script,
  %(security import "$wwdr_g3" -k "$keychain" -t cert),
  %(security list-keychains -d user -s "$keychain"),
  "TestFlight signing setup must import WWDR G3 before isolating the keychain search list"
)
fail_contract("TestFlight cleanup must remove the downloaded WWDR G3 certificate") unless cleanup_script.include?(%(remove_file "$RUNNER_TEMP/AppleWWDRCAG3.cer"))
require_script_order(
  signing_script,
  %(security import "$mac_installer_certificate"),
  %(security find-identity -v -p basic "$keychain"),
  "TestFlight signing setup must import the Mac installer identity before resolving its exact name"
)
require_script_order(
  signing_script,
  %(security find-identity -v -p basic "$keychain"),
  %(MAC_INSTALLER_CERTIFICATE_NAME=%s),
  "TestFlight signing setup must resolve the Mac installer identity before publishing its exact name"
)
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
fail_contract("TestFlight must read the shared marketing version") unless testflight.include?("read-apple-version.sh marketing")
fail_contract("TestFlight must reject a tag/version mismatch") unless testflight.include?('test "$release_version" = "$repository_version"')
fail_contract("TestFlight must accept Apple dotted build strings") unless testflight.include?('^[1-9][0-9]*(\.[0-9]+){0,2}$')

app_store = File.read(File.join(WORKFLOW_DIR, "app-store-submit.yml"))
fail_contract("App Store submission must read the shared marketing version") unless app_store.include?("read-apple-version.sh marketing")
fail_contract("App Store submission must reject a tag/version mismatch") unless app_store.include?('test "$release_version" = "$repository_version"')
fail_contract("App Store submission must accept Apple dotted build strings") unless app_store.include?('^[1-9][0-9]*(\.[0-9]+){0,2}$')
fail_contract("App Store workflow must submit the iOS build") unless app_store.include?("fastlane ios submit_app_store")
fail_contract("App Store workflow must submit the macOS build") unless app_store.include?("fastlane mac submit_app_store")

mac_entitlements_path = File.join(ROOT, "mac", "ClickBridgeMac", "ClickBridgeMac-AppStore.entitlements")
fail_contract("Mac TestFlight entitlements file is missing") unless File.file?(mac_entitlements_path)
mac_entitlements = File.read(mac_entitlements_path)
%w[com.apple.security.app-sandbox com.apple.security.network.client].each do |entitlement|
  fail_contract("Mac TestFlight entitlements are missing #{entitlement}") unless mac_entitlements.include?(entitlement)
end

mac_project_path = File.join(ROOT, "mac", "project.yml")
mac_info_plist_path = File.join(ROOT, "mac", "ClickBridgeMac", "Info.plist")
validate_mac_app_store_category(mac_project_path, mac_info_plist_path)

xcodegen_workflows = {
  "ci.yml" => {
    job: "apple-clients",
    generated_paths: %w[
      mac/ClickBridgeMac.xcodeproj/project.pbxproj
      mac/ClickBridgeMac/Info.plist
      ios/ClickBridgePhone.xcodeproj/project.pbxproj
      ios/ClickBridgePhone/Info.plist
    ]
  },
  "testflight.yml" => {
    job: "upload",
    generated_paths: %w[
      mac/ClickBridgeMac.xcodeproj/project.pbxproj
      mac/ClickBridgeMac/Info.plist
      ios/ClickBridgePhone.xcodeproj/project.pbxproj
      ios/ClickBridgePhone/Info.plist
    ]
  },
  "macos-notarized-release.yml" => {
    job: "release",
    generated_paths: %w[
      mac/ClickBridgeMac.xcodeproj/project.pbxproj
      mac/ClickBridgeMac/Info.plist
    ]
  }
}.freeze

xcodegen_workflows.each do |filename, contract|
  workflow_path = File.join(WORKFLOW_DIR, filename)
  workflow = File.read(workflow_path)
  document = YAML.safe_load(workflow, aliases: true)
  steps = document.fetch("jobs").fetch(contract.fetch(:job)).fetch("steps")
  install_index = steps.index { |step| step["name"] == "Install XcodeGen" }
  install_step = install_index && steps.fetch(install_index)
  fail_contract("#{filename} is missing the pinned XcodeGen installer") unless install_step
  install_script = install_step.fetch("run")
  fail_contract("#{filename} must not install XcodeGen with Homebrew") if workflow.include?("brew install xcodegen")
  fail_contract("#{filename} must download the pinned XcodeGen release") unless install_script.include?(XCODEGEN_URL)
  fail_contract("#{filename} must verify the pinned XcodeGen checksum") unless install_script.include?(XCODEGEN_SHA256) && install_script.include?("shasum -a 256 -c")
  fail_contract("#{filename} must verify the installed XcodeGen version") unless install_script.include?("Version: #{XCODEGEN_VERSION}")
  require_script_order(
    install_script,
    %(install_root="$RUNNER_TEMP/xcodegen-${version}"),
    %(mkdir -p "$install_root"),
    "#{filename} must create its XcodeGen install prefix after selecting it"
  )
  require_script_order(
    install_script,
    %(mkdir -p "$install_root"),
    %(PREFIX="$install_root" "$extracted/xcodegen/install.sh"),
    "#{filename} must create its XcodeGen install prefix before installing"
  )
  require_script_order(
    install_script,
    %(PREFIX="$install_root" "$extracted/xcodegen/install.sh"),
    %(test -f "$install_root/share/xcodegen/SettingPresets/base.yml"),
    "#{filename} must verify XcodeGen setting presets after installing"
  )

  generation_indices = steps.each_index.select { |index| steps.fetch(index)["name"]&.start_with?("Generate ") }
  fail_contract("#{filename} is missing XcodeGen generation steps") if generation_indices.empty?
  generation_indices.each do |index|
    step = steps.fetch(index)
    script = step.fetch("run")
    fail_contract("#{filename} #{step.fetch("name")} must enable strict pipe failures") unless script.include?("set -Eeuo pipefail")
    fail_contract("#{filename} #{step.fetch("name")} must capture XcodeGen output") unless script.include?("xcodegen generate 2>&1 | tee")
    fail_contract("#{filename} #{step.fetch("name")} must reject missing setting presets") unless script.include?(%q{grep -Eq 'No "[^"]+" settings found'})
    verify_xcodegen_generation_guard(filename, step.fetch("name"), script)
  end

  parity_index = steps.index { |step| step["name"] == "Verify generated project parity" }
  parity_step = parity_index && steps.fetch(parity_index)
  fail_contract("#{filename} is missing generated project parity verification") unless parity_step
  fail_contract("#{filename} must verify project parity after generation") unless parity_index > generation_indices.max
  parity_script = parity_step.fetch("run")
  fail_contract("#{filename} must fail on generated project drift") unless parity_script.include?("git diff --exit-code --")
  contract.fetch(:generated_paths).each do |generated_path|
    fail_contract("#{filename} must verify generated drift for #{generated_path}") unless parity_script.include?(generated_path)
  end
end

fastfile = File.read(File.join(ROOT, "fastlane", "Fastfile"))
fail_contract("Fastfile is missing the macOS TestFlight platform") unless fastfile.include?("platform :mac do")
ios_lane = fastfile[/platform :ios do.*?(?=platform :mac do)/m]
mac_lane = fastfile[/platform :mac do.*\z/m]
fail_contract("Fastfile is missing the iOS TestFlight lane") unless ios_lane
fail_contract("Fastfile is missing the macOS TestFlight lane") unless mac_lane
ios_changelog_path = ios_lane[/changelog:\s*File\.read\("([^"]+)"\)\.strip/, 1]
mac_changelog_path = mac_lane[/changelog:\s*File\.read\("([^"]+)"\)\.strip/, 1]
fail_contract("iOS TestFlight lane must consume its release notes") unless ios_changelog_path == "fastlane/metadata/en-US/release_notes.txt"
fail_contract("Mac TestFlight lane must consume mac/TestFlight/WhatToTest.en-US.txt") unless mac_changelog_path == "mac/TestFlight/WhatToTest.en-US.txt"
validate_mac_testflight_notes(File.join(ROOT, mac_changelog_path))
fail_contract("Mac TestFlight lane must require the resolved installer identity") unless mac_lane.include?('mac_installer_certificate_name = ENV.fetch("MAC_INSTALLER_CERTIFICATE_NAME")')
fail_contract("Mac TestFlight package must use the resolved installer identity") unless mac_lane.scan("installer_cert_name: mac_installer_certificate_name").one?
fail_contract("Mac TestFlight export must use the resolved installer identity") unless mac_lane.scan("installerSigningCertificate: mac_installer_certificate_name").one?
fail_contract("Mac TestFlight lane must not use the generic installer identity") if mac_lane.include?('installer_cert_name: "Mac Installer Distribution"') || mac_lane.include?('installerSigningCertificate: "Mac Installer Distribution"')
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
  fail_contract("#{platform} TestFlight build and verification must use the explicit archive path") unless lane.scan("archive_path: archive_path").length == 2
  fail_contract("#{platform} TestFlight build must receive the selected marketing version") unless lane.include?('"MARKETING_VERSION=#{Shellwords.escape(release_version)}"')
  fail_contract("#{platform} TestFlight build must receive the selected build number") unless lane.include?('"CURRENT_PROJECT_VERSION=#{Shellwords.escape(build_number)}"')
  fail_contract("#{platform} TestFlight lane must verify archive metadata before upload") unless lane.include?("verify_archive_version(")
end
fail_contract("Fastfile must not mutate generated project version fields") if fastfile.include?("increment_version_number") || fastfile.include?("increment_build_number")
verify_lane = fastfile[/private_lane :verify_archive_version do.*?(?=platform :ios do)/m]
fail_contract("Fastfile is missing archive version verification") unless verify_lane
%w[ApplicationProperties CFBundleShortVersionString CFBundleVersion UI.user_error!].each do |contract|
  fail_contract("Fastfile archive version verification is missing #{contract}") unless verify_lane.include?(contract)
end
fail_contract("Fastfile must define one submission lane per Apple platform") unless fastfile.scan("lane :submit_app_store do").length == 2
fail_contract("iOS App Store submission must select the iOS platform") unless ios_lane.include?('platform: "ios"')
fail_contract("Mac App Store submission must select the macOS platform") unless mac_lane.include?('platform: "osx"')
%w[skip_binary_upload submit_for_review automatic_release].each do |setting|
  fail_contract("Fastfile is missing #{setting}") unless fastfile.include?(setting)
end
fail_contract("App Store submission must skip binary upload") unless fastfile.include?("skip_binary_upload: true")
fail_contract("App Store submission must require review") unless fastfile.include?("submit_for_review: true")
fail_contract("App Store submission must disable automatic release") unless fastfile.include?("automatic_release: false")

macos = File.read(File.join(WORKFLOW_DIR, "macos-notarized-release.yml"))
macos_document = YAML.safe_load(macos, aliases: true)
%w[ENABLE_HARDENED_RUNTIME=YES --timestamp "notarytool submit" "stapler staple" "spctl --assess" "--draft" "retention-days: 7"].each do |contract|
  fail_contract("macOS workflow is missing #{contract}") unless macos.include?(contract.delete_prefix('"').delete_suffix('"'))
end
fail_contract("macOS release-existence guard must use an explicit conditional") if macos.include?('! gh release view "$RELEASE_TAG"')
fail_contract("macOS release-existence guard is missing") unless macos.include?('if gh release view "$RELEASE_TAG"')
fail_contract("macOS environment writes must be grouped") if macos.match?(/echo .* >> "\$GITHUB_ENV"\n\s+echo .* >> "\$GITHUB_ENV"/)
fail_contract("macOS notary log must be validated as JSON") unless macos.include?('jq empty "$notary_log"')
fail_contract("macOS notary log must not be parsed as a plist") if macos.include?('plutil -lint "$notary_log"')
fail_contract("macOS notarization audit artifact must retain result and log") unless macos.include?("ClickBridgeMac-notary-result.json") && macos.include?("ClickBridgeMac-notary-log.json") && macos.include?("Retain notarization audit for seven days")
%w[id-token attestations].each do |permission|
  fail_contract("macOS workflow must grant #{permission} write permission for archive attestation") unless macos_document.dig("permissions", permission) == "write"
end
macos_steps = macos_document.fetch("jobs").fetch("release").fetch("steps")
audit_step = macos_steps.find { |step| step["name"] == "Retain notarization audit for seven days" }
fail_contract("macOS notarization audit artifact must run after failures") unless audit_step && audit_step["if"] == "${{ always() }}"
audit_options = audit_step.fetch("with")
fail_contract("macOS notarization audit artifact has incomplete paths") unless audit_options.fetch("path").include?("ClickBridgeMac-notary-result.json") && audit_options.fetch("path").include?("ClickBridgeMac-notary-log.json")
fail_contract("macOS notarization audit artifact must retain seven days") unless audit_options["retention-days"] == 7
fail_contract("macOS checksum must contain only the archive basename") unless macos.include?('shasum -a 256 "$archive_name" > "$archive_name.sha256"')
fail_contract("macOS checksum must not contain the runner's absolute archive path") if macos.include?('shasum -a 256 "$archive"')
fail_contract("macOS notarized release must read the shared marketing version") unless macos.include?("read-apple-version.sh marketing")
fail_contract("macOS notarized release must use the shared baseline build") unless macos.include?("read-apple-version.sh build")
fail_contract("macOS notarized archive must receive MARKETING_VERSION") unless macos.include?('MARKETING_VERSION="$RELEASE_VERSION"')
fail_contract("macOS notarized archive must receive CURRENT_PROJECT_VERSION") unless macos.include?('CURRENT_PROJECT_VERSION="$BUILD_NUMBER"')
fail_contract("macOS notarized release must verify the archived marketing version") unless macos.include?("plutil -extract CFBundleShortVersionString")
fail_contract("macOS notarized release must verify the archived build number") unless macos.include?("plutil -extract CFBundleVersion")
mac_attest_index = macos_steps.index { |step| step["name"] == "Attest notarized macOS archive" }
draft_release_index = macos_steps.index { |step| step["name"] == "Create draft GitHub release only" }
fail_contract("macOS workflow must attest the notarized archive before draft creation") unless mac_attest_index && draft_release_index && mac_attest_index < draft_release_index
mac_attest = macos_steps.fetch(mac_attest_index)
fail_contract("macOS archive attestation must use the pinned GitHub action") unless mac_attest["uses"] == "actions/attest@#{PINS.fetch("actions/attest")}"
fail_contract("macOS archive attestation must target the final notarized ZIP") unless mac_attest.dig("with", "subject-path") == "${{ env.MAC_RELEASE_ARCHIVE }}"
draft_release_script = macos_steps.fetch(draft_release_index).fetch("run")
fail_contract("macOS draft release must generate repository release notes") unless draft_release_script.include?("--generate-notes")
fail_contract("macOS draft release must prepend its notarization review notice") unless draft_release_script.include?("--notes") && draft_release_script.include?("notarized")
fail_contract("macOS draft release must refuse an empty subsequent release") unless draft_release_script.include?("--fail-on-no-commits")

ghcr = File.read(File.join(WORKFLOW_DIR, "ghcr-relay.yml"))
ghcr_document = YAML.safe_load(ghcr, aliases: true)
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
%w[id-token attestations].each do |permission|
  fail_contract("GHCR workflow must grant #{permission} write permission for image attestation") unless ghcr_document.dig("permissions", permission) == "write"
end
ghcr_steps = ghcr_document.fetch("jobs").fetch("publish").fetch("steps")
tag_guard_index = ghcr_steps.index { |step| step["name"] == "Refuse to overwrite immutable image tags" }
qemu_index = ghcr_steps.index { |step| step["name"] == "Set up QEMU for Arm64" }
buildx_index = ghcr_steps.index { |step| step["name"] == "Set up Buildx" }
metadata_index = ghcr_steps.index { |step| step["name"] == "Define version and SHA tags" }
push_index = ghcr_steps.index { |step| step["name"] == "Build and push the relay image" }
attest_index = ghcr_steps.index { |step| step["name"] == "Attest the published image digest" }
digest_guard_index = ghcr_steps.index { |step| step["name"] == "Verify published tags resolve to the pushed digest" }
fail_contract("GHCR immutable-tag guard must run before the push step") unless tag_guard_index && push_index && tag_guard_index < push_index
fail_contract("GHCR workflow must set up QEMU before Buildx and image publication") unless qemu_index && buildx_index && push_index && qemu_index < buildx_index && buildx_index < push_index
qemu_step = ghcr_steps.fetch(qemu_index)
fail_contract("GHCR workflow must use the pinned QEMU action") unless qemu_step["uses"] == "docker/setup-qemu-action@#{PINS.fetch("docker/setup-qemu-action")}"
fail_contract("GHCR workflow must pin the QEMU binary image by digest") unless qemu_step.dig("with", "image") == QEMU_IMAGE
fail_contract("GHCR workflow must install only the required Arm64 emulator") unless qemu_step.dig("with", "platforms") == "arm64"
metadata_step = ghcr_steps.fetch(metadata_index)
metadata_options = metadata_step.fetch("with")
source_annotation = 'org.opencontainers.image.source=https://github.com/${{ github.repository }}'
description_annotation = "org.opencontainers.image.description=Private Click Bridge relay and PWA runtime"
fail_contract("GHCR metadata must link the package to its source repository") unless metadata_options.fetch("labels").include?(source_annotation) && metadata_options.fetch("annotations").include?(source_annotation)
fail_contract("GHCR metadata must describe the relay package") unless metadata_options.fetch("labels").include?(description_annotation) && metadata_options.fetch("annotations").include?(description_annotation)
fail_contract("GHCR metadata must annotate both manifests and the multi-architecture index") unless metadata_step.dig("env", "DOCKER_METADATA_ANNOTATIONS_LEVELS") == "manifest,index"
push_options = ghcr_steps.fetch(push_index).fetch("with")
fail_contract("GHCR release step must push the validated tags") unless push_options["push"] == true
fail_contract("GHCR workflow must publish the supported AMD64 and Arm64 images") unless push_options["platforms"] == "linux/amd64,linux/arm64"
fail_contract("GHCR workflow must apply manifest and index annotations") unless push_options["annotations"] == "${{ steps.metadata.outputs.annotations }}"
fail_contract("GHCR workflow must preserve BuildKit provenance") unless push_options["provenance"] == true
fail_contract("GHCR workflow must preserve the image SBOM") unless push_options["sbom"] == true
fail_contract("GHCR workflow must attest the pushed digest before post-push verification") unless attest_index && push_index < attest_index && attest_index < digest_guard_index
attest_step = ghcr_steps.fetch(attest_index)
attest_options = attest_step.fetch("with")
fail_contract("GHCR image attestation must use the pinned GitHub action") unless attest_step["uses"] == "actions/attest@#{PINS.fetch("actions/attest")}"
fail_contract("GHCR image attestation must name the canonical image") unless attest_options["subject-name"] == "${{ env.RELAY_IMAGE }}"
fail_contract("GHCR image attestation must bind the pushed digest") unless attest_options["subject-digest"] == "${{ steps.build.outputs.digest }}"
fail_contract("GHCR image attestation must record the release version") unless attest_options["subject-version"] == "${{ env.RELEASE_VERSION }}"
fail_contract("GHCR image attestation must be published with the OCI image") unless attest_options["push-to-registry"] == true
fail_contract("GHCR image attestation must not request an organization-only storage record") unless attest_options["create-storage-record"] == false
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
