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
    assert_match(/\^\[0-9\]\+\\?\.\[0-9\]\+\\?\.\[0-9\]\+|semver/i, source,
                 "workflow must validate the version input as strict SemVer")
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
