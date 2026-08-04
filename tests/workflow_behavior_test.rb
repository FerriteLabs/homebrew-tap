# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

# Behavioral invariants for the release-automation workflows
# (update-formula.yml, build-bottles.yml). These assert the *hardening*
# properties the workflows must have, independent of exact wording:
#
#   * untrusted event inputs are passed through `env:` rather than
#     interpolated directly into `run:` shell scripts (script-injection
#     hardening)
#   * the version input is validated as strict SemVer before use
#   * the canonical tarball/bottle checksum is always (re)computed by the
#     workflow itself rather than trusting a caller-supplied value
#   * updates land via pull request (no direct unreviewed push to main)
#   * tests/audit run before a PR is opened
class WorkflowBehaviorTest < Minitest::Test
  UPDATE_FORMULA = FerriteTap::WORKFLOWS_DIR + "update-formula.yml"
  BUILD_BOTTLES = FerriteTap::WORKFLOWS_DIR + "build-bottles.yml"
  CI_WORKFLOW = FerriteTap::WORKFLOWS_DIR + "ci.yml"
  CHECKSUM_TEST = FerriteTap::ROOT + "tests" + "formula_checksum_test.rb"
  FORMULA_UPDATER = FerriteTap::ROOT + "scripts" + "update_formula.rb"

  def test_workflow_files_exist
    assert UPDATE_FORMULA.file?
    assert BUILD_BOTTLES.file?
  end

  def test_all_workflow_yaml_parses
    Dir.glob("#{FerriteTap::WORKFLOWS_DIR}/*.yml").each do |path|
      YAML.safe_load(File.read(path), permitted_classes: [Symbol], aliases: true)
    rescue Psych::SyntaxError => e
      flunk "#{path} is not valid YAML: #{e.message}"
    end
  end

  def test_update_formula_handles_both_trigger_types
    doc = load_yaml(UPDATE_FORMULA)
    on = doc["on"] || doc[true] # YAML may parse bare `on:` as boolean true key
    assert on, "update-formula.yml must declare triggers"
    assert on.key?("repository_dispatch"), "must handle repository_dispatch"
    assert on.key?("workflow_dispatch"), "must handle workflow_dispatch"
    assert on["workflow_dispatch"]["inputs"].key?("version")
    assert on["workflow_dispatch"]["inputs"].key?("sha256")
  end

  def test_update_formula_does_not_interpolate_expressions_directly_in_run
    refute_run_steps_interpolate_expressions(UPDATE_FORMULA)
  end

  def test_update_formula_validates_strict_semver
    assert_has_semver_validation(UPDATE_FORMULA)
  end

  def test_update_formula_always_recomputes_canonical_checksum
    source = UPDATE_FORMULA.read
    assert_match(/sha256sum|shasum\s+-a\s+256/, source,
                 "workflow must (re)compute a checksum from the real tarball")
    assert_match(/curl/, source, "workflow must download the tagged archive to hash it")
  end

  def test_update_formula_compares_rather_than_trusts_supplied_checksum
    source = UPDATE_FORMULA.read
    assert_match(/!=|-ne\b|mismatch/i, source,
                 "workflow must compare the computed checksum against the supplied one")
    assert_match(/exit\s+1/, source, "workflow must fail the run on a checksum mismatch")
  end

  def test_update_formula_runs_tests_before_opening_a_pr
    assert_tests_run_before_pr(UPDATE_FORMULA)
  end

  def test_update_formula_uses_pull_request_flow
    assert_match(/create-pull-request/, UPDATE_FORMULA.read)
  end

  def test_update_formula_removes_prior_bottle_metadata_before_source_update
    source = UPDATE_FORMULA.read
    assert_match(/ruby scripts\/update_formula\.rb/, source,
                 "workflow must use the behavior-tested formula updater")

    updater = FORMULA_UPDATER.read
    bottle_removal_index = updater.index(/sub\(BOTTLE_BLOCK/)
    url_update_index = updater.index(/sub\(SOURCE_URL/)
    sha_update_index = updater.index(/sub\(SOURCE_SHA256/)
    refute_nil bottle_removal_index, "updater must remove the prior bottle block"
    refute_nil url_update_index, "updater must update the source url"
    refute_nil sha_update_index, "updater must update the source sha256"
    assert bottle_removal_index < url_update_index,
           "the old bottle block must be removed before the source url changes"
    assert bottle_removal_index < sha_update_index,
           "the old bottle block must be removed before the source sha256 changes"
  end

  def test_build_bottles_validates_version_input
    assert_has_semver_validation(BUILD_BOTTLES)
  end

  def test_build_bottles_uses_canonical_brew_bottle_merge
    source = BUILD_BOTTLES.read
    assert_match(/brew\s+bottle/, source, "must invoke the canonical `brew bottle` command")
    assert_match(/--merge/, source, "must use `brew bottle --merge` to insert bottle metadata")
    refute_match(/PLACEHOLDER_SHA256/i, source,
                 "must not reintroduce placeholder-regex substitution for bottle checksums")
  end

  def test_build_bottles_replaces_prior_metadata_with_complete_new_set
    source = BUILD_BOTTLES.read
    assert_match(/--merge/, source)
    assert_match(/--write/, source)
    refute_match(/brew\s+bottle[^\n]*--keep-old/, source,
                 "a new source version must not preserve bottle metadata from the prior version")
    assert_match(/still contains bottle metadata from a prior release/, source,
                 "collect must fail closed if the version-update PR did not remove the old bottle block")
    assert_match(/ACTUAL_JSON_COUNT/, source)
    assert_match(/ACTUAL_TARBALL_COUNT/, source)
    assert_match(/must describe exactly one bottle tag/, source,
                 "each bottle JSON must be validated before the complete set is merged")
    assert_match(/actual == expected/, source,
                 "the written formula bottle block must exactly match the validated JSON set")
    assert_match(/unexpectedly contains rebuild metadata/, source,
                 "the new bottle block must reject stale rebuild suffix metadata")
  end

  # The matrix must build genuinely distinct, currently-supported bottle
  # platforms - not duplicate/retired runner+arch combinations that
  # silently produce the same (or a wrong) `brew bottle` tag.
  def test_build_bottles_matrix_targets_distinct_supported_platforms
    doc = load_yaml(BUILD_BOTTLES)
    matrix = doc.dig("jobs", "bottle", "strategy", "matrix", "include")
    refute_nil matrix, "bottle job must declare a matrix"
    refute_empty matrix, "bottle job matrix must not be empty"

    expected_tags = matrix.map { |entry| entry["expected_tag"] }
    assert(expected_tags.all? { |tag| !tag.nil? && !tag.empty? },
           "every matrix entry must declare an expected_tag")
    duplicate_tags = expected_tags.group_by { |tag| tag }.select { |_, group| group.length > 1 }.keys
    assert_equal expected_tags.uniq.length, expected_tags.length,
                 "matrix entries must target distinct bottle tags (found duplicates: #{duplicate_tags})"

    oses = matrix.map { |entry| entry["os"] }
    refute(oses.any? { |os| os.to_s.include?("macos-13") },
           "macos-13 is fully retired by GitHub; it must not appear in the bottle matrix")
  end

  def test_build_bottles_validates_generated_bottle_json_tag_and_filename
    source = BUILD_BOTTLES.read
    assert_match(/expected_tag/, source, "must compare the actual brew bottle tag against an expected value")
    assert_match(/does not match/i, source,
                 "must fail with a clear message when the produced tag does not match expectations")
    assert_match(/bottle\.tar\.gz/, source, "must validate the produced bottle tarball filename")
  end

  def test_build_bottles_collect_job_count_matches_matrix_size
    doc = load_yaml(BUILD_BOTTLES)
    matrix = doc.dig("jobs", "bottle", "strategy", "matrix", "include")
    matrix_size = matrix.length

    source = BUILD_BOTTLES.read
    expected_count_match = source.match(/EXPECTED_COUNT=(\d+)/)
    refute_nil expected_count_match, "collect job must declare EXPECTED_COUNT"
    assert_equal matrix_size, expected_count_match[1].to_i,
                 "collect job's EXPECTED_COUNT (#{expected_count_match[1]}) must match the matrix size " \
                 "(#{matrix_size}), or a shrinking/growing matrix will silently desync from the gate"
  end

  # Bottles must never be built for a formula that has not actually been
  # updated to the requested release: ferrite.rb's url version/sha256,
  # release-metadata.json's version/sha256/url, and the requested
  # version must all be cross-checked, and the canonical archive
  # checksum must be independently recomputed and compared - failing
  # closed on any mismatch - before a single bottle is built.
  def test_build_bottles_validates_formula_metadata_and_requested_version_agree
    source = BUILD_BOTTLES.read
    assert_match(/release-metadata\.json/, source,
                 "must cross-check release-metadata.json against the formula and requested version")
    assert_match(/formula_version == version|formula_url\.match/, source,
                 "must compare the formula's url version against the requested version")
    assert_match(/metadata\["sha256"\]\s*==\s*formula_sha256/, source,
                 "must compare release-metadata.json's sha256 against ferrite.rb's sha256")
  end

  def test_build_bottles_recomputes_canonical_checksum_before_building
    source = BUILD_BOTTLES.read
    assert_match(/sha256sum|shasum\s+-a\s+256/, source,
                 "must (re)compute a checksum from the real tagged archive before building bottles")
    assert_match(/curl/, source, "must download the tagged archive to hash it")
    assert_match(/COMPUTED_SHA256.*!=.*FORMULA_SHA256|FORMULA_SHA256.*!=.*COMPUTED_SHA256/, source,
                 "must compare the recomputed checksum against the formula's committed sha256")
  end

  # These pre-build validation steps run in the `validate` job, which
  # every other job (including `collect`) transitively depends on -
  # so they gate the collect/release path as well as each build.
  def test_build_bottles_validate_job_gates_bottle_and_collect_jobs
    doc = load_yaml(BUILD_BOTTLES)
    bottle_needs = Array(doc.dig("jobs", "bottle", "needs"))
    collect_needs = Array(doc.dig("jobs", "collect", "needs"))
    assert_includes bottle_needs, "validate", "bottle job must depend on validate"
    assert_includes collect_needs, "validate", "collect job must (transitively) depend on validate"
  end

  def test_build_bottles_does_not_push_directly_to_main
    doc = load_yaml(BUILD_BOTTLES)
    each_run_step(doc) do |run_script, job_name|
      refute_match(/\bgit\s+push\b/, run_script,
                   "#{job_name}: must not push directly to main; open a pull request instead")
    end
    assert_match(/create-pull-request/, BUILD_BOTTLES.read,
                 "build-bottles.yml must land formula updates via pull request")
  end

  def test_build_bottles_runs_tests_before_opening_a_pr
    assert_tests_run_before_pr(BUILD_BOTTLES)
  end

  # The ci.yml `audit` job is the one job that runs on a network-enabled
  # runner specifically to exercise the real tarball checksum check; it
  # must run the *full* suite (no --fast / FERRITE_TAP_SKIP_NETWORK=1),
  # or the checksum test would never actually execute anywhere in CI.
  def test_ci_audit_job_runs_the_full_network_enabled_test_suite
    doc = load_yaml(CI_WORKFLOW)
    audit_job = doc.dig("jobs", "audit")
    refute_nil audit_job, "ci.yml must define an audit job"

    full_suite_step = (audit_job["steps"] || []).find do |step|
      step.is_a?(Hash) && step["run"].to_s.include?("tests/run.sh")
    end
    refute_nil full_suite_step, "audit job must run tests/run.sh"

    run_script = full_suite_step["run"].to_s
    refute_match(/tests\/run\.sh\s+--fast/, run_script,
                 "the audit job must run the full suite, not --fast, or the network-bound checksum test never actually runs in CI")
    refute_match(/FERRITE_TAP_SKIP_NETWORK/, run_script,
                 "the audit job must not opt out of the network-bound checksum test")
  end

  def test_homebrew_checks_use_a_deterministic_tap_qualified_formula
    [CI_WORKFLOW, BUILD_BOTTLES].each do |path|
      source = path.read
      assert_match(/brew tap ferritelabs\/ci "\$\(pwd\)"/, source,
                   "#{path.basename} must tap the checkout under the deterministic ferritelabs/ci name")
      assert_match(/brew audit --strict --online ferritelabs\/ci\/ferrite/, source,
                   "#{path.basename} must audit the tap-qualified formula")
      assert_match(/brew style ferritelabs\/ci\/ferrite/, source,
                   "#{path.basename} must style the tap-qualified formula")
      refute_match(/brew audit[^\n]*(?:\.\/)?ferrite\.rb/, source,
                   "#{path.basename} must never use path-based brew audit")
    end
  end

  # Guards against reintroducing a broad rescue that silently turns a
  # real network failure into a passing skip during a full/default run.
  # The only sanctioned skip path is the explicit FERRITE_TAP_SKIP_NETWORK
  # / --fast opt-in checked at the very top of the test method.
  def test_checksum_test_only_skips_via_explicit_fast_offline_opt_in
    source = CHECKSUM_TEST.read
    refute_match(/rescue\s+.*\n\s*skip\b/, source,
                 "the checksum test must not rescue network errors into a skip; a network failure during a full/default run must fail the test, not pass silently")
    assert_match(/skip\b.*if\s+FerriteTap\.skip_network\?/, source,
                 "the only sanctioned skip must be gated behind the explicit fast/offline opt-in")
  end

  private

  def load_yaml(path)
    YAML.safe_load(path.read, permitted_classes: [Symbol], aliases: true)
  end

  def each_run_step(doc)
    (doc["jobs"] || {}).each do |job_name, job|
      (job["steps"] || []).each do |step|
        next unless step.is_a?(Hash) && step["run"]

        yield step["run"], job_name
      end
    end
  end

  def refute_run_steps_interpolate_expressions(path)
    doc = load_yaml(path)
    each_run_step(doc) do |run_script, job_name|
      refute_match(/\$\{\{/, run_script,
                   "#{job_name}: run steps must receive event data via `env:`, not `${{ }}` interpolation")
    end
  end

  def assert_has_semver_validation(path)
    source = path.read
    regex_match = source.match(/SEMVER_REGEX="([^"]+)"/)
    refute_nil regex_match, "workflow must define a SemVer validation regex"

    semver = Regexp.new(regex_match[1])
    %w[
      0.0.0
      1.2.3
      1.2.3-alpha
      1.2.3-alpha.1
      1.2.3-0.3.7
      1.2.3-x.7.z.92
      1.2.3+build.5
      1.2.3-alpha+build.5
    ].each do |version|
      assert_match semver, version, "#{path.basename} should accept valid SemVer #{version.inspect}"
    end

    %w[
      v1.2.3
      01.2.3
      1.02.3
      1.2.03
      1.2
      1.2.3-01
      1.2.3-alpha..1
      1.2.3-alpha.
      1.2.3+
      1.2.3+build..1
    ].each do |version|
      refute_match semver, version, "#{path.basename} should reject invalid SemVer #{version.inspect}"
    end
  end

  def assert_tests_run_before_pr(path)
    source = path.read
    test_index = source.index(%r{tests/run\.sh}) || source.index(/ruby -c/)
    refute_nil test_index, "workflow must run the repo test suite (or ruby -c) before opening a PR"

    pr_index = source.index("create-pull-request")
    refute_nil pr_index, "workflow must open a pull request"

    assert test_index < pr_index, "tests must run before the pull request step"
  end
end
