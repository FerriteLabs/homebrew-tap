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
#   * the version input is validated as a stable X.Y.Z release before use
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
  RELEASE_VERSION = FerriteTap::ROOT + "scripts" + "release_version.rb"
  BOTTLE_VALIDATOR = FerriteTap::ROOT + "scripts" + "validate_bottle_artifact.rb"

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

  def test_update_formula_validates_stable_release_version
    assert_has_stable_release_validation(UPDATE_FORMULA)
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
    assert_has_stable_release_validation(BUILD_BOTTLES)
  end

  def test_workflows_derive_branches_and_release_tags_from_validated_outputs
    update_source = UPDATE_FORMULA.read
    assert_match(/echo "release_tag=v\$\{VERSION\}"/, update_source)
    assert_match(/echo "formula_branch=update-ferrite-\$\{VERSION\}"/, update_source)

    update_doc = load_yaml(UPDATE_FORMULA)
    update_steps = update_doc.dig("jobs", "update", "steps")
    update_pr = update_steps.find { |step| step["uses"].to_s.include?("create-pull-request") }
    assert_equal "${{ steps.release.outputs.formula_branch }}", update_pr.dig("with", "branch")

    build_source = BUILD_BOTTLES.read
    assert_match(/echo "release_tag=v\$\{VERSION\}"/, build_source)
    assert_match(/echo "bottle_branch=update-ferrite-bottles-\$\{VERSION\}"/, build_source)
    assert_match(%r{echo "bottle_release_url=https://github\.com/ferritelabs/homebrew-tap/releases/download/v\$\{VERSION\}"},
                 build_source)

    build_doc = load_yaml(BUILD_BOTTLES)
    validate_outputs = build_doc.dig("jobs", "validate", "outputs")
    assert_equal "${{ steps.release.outputs.release_tag }}", validate_outputs["release_tag"]
    assert_equal "${{ steps.release.outputs.bottle_branch }}", validate_outputs["bottle_branch"]

    collect_steps = build_doc.dig("jobs", "collect", "steps")
    bottle_pr = collect_steps.find { |step| step["uses"].to_s.include?("create-pull-request") }
    release = collect_steps.find { |step| step["uses"].to_s.include?("action-gh-release") }
    assert_equal "${{ needs.validate.outputs.bottle_branch }}", bottle_pr.dig("with", "branch")
    assert_equal "${{ needs.validate.outputs.release_tag }}", release.dig("with", "tag_name")
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
    assert_match(/must describe exactly one bottle tag/, BOTTLE_VALIDATOR.read,
                 "each bottle JSON must be validated before the complete set is merged")
    assert_match(/actual == expected/, source,
                 "the written formula bottle block must exactly match the validated JSON set")
    assert_match(/unexpectedly contains rebuild metadata/, source,
                 "the new bottle block must reject stale rebuild suffix metadata")
    assert_match(/TAPPED_FORMULA="\$\(brew formula ferritelabs\/ci\/ferrite\)"/, source,
                 "collect must locate the formula in Homebrew's cloned local tap")
    # `brew bottle --merge --write` resolves each bottle JSON's
    # `formula.path` against HOMEBREW_REPOSITORY and writes the new
    # bottle block there - i.e. into TAPPED_FORMULA, not the checkout's
    # ferrite.rb directly (see test_collect_normalizes_bottle_json_formula_path
    # in this file and formula_json_path_normalization_test.rb for the
    # normalization that makes that resolution deterministic). The
    # merged result must then be copied *from* the tapped formula *back
    # into* the checkout, never the other way around: copying the
    # (still-unmerged) checkout formula over the tapped one would
    # silently discard whatever `brew bottle --merge` wrote.
    assert_match(/cp\s+"\$\{TAPPED_FORMULA\}"\s+ferrite\.rb/, source,
                 "collect must copy the merged tapped formula back into the Actions checkout, " \
                 "not the reverse")
    refute_match(/cp\s+ferrite\.rb\s+"\$\{TAPPED_FORMULA\}"/, source,
                 "collect must never copy the (unmerged) checkout formula over the merged tapped " \
                 "formula - that would silently discard the merge result")
  end

  def test_build_bottles_verifies_each_tarball_against_its_json_checksum
    source = BUILD_BOTTLES.read
    validator_index = source.index(/ruby scripts\/validate_bottle_artifact\.rb/)
    merge_index = source.index(/brew bottle --merge --write --no-commit/)

    refute_nil validator_index,
               "collect must validate every downloaded bottle JSON/tarball pair"
    refute_nil merge_index
    validator = BOTTLE_VALIDATOR.read
    assert_match(/Digest::SHA256\.file\(tarball_path\)\.hexdigest/, validator,
                 "the validator must recompute the downloaded bottle tarball checksum")
    assert_match(/sha256 == actual_sha256/, validator,
                 "the generated bottle JSON checksum must match the downloaded tarball")
    assert_match(/Zlib::GzipReader\.open\(tarball_path\)/, validator,
                 "the validator must reject files that are not readable gzip archives")
    assert_match(%r{/bin/ferrite}, validator,
                 "the validator must require the Ferrite server binary")
    assert_match(/INSTALL_RECEIPT\.json/, validator,
                 "the validator must require the Homebrew installation receipt")
    assert validator_index < merge_index,
           "bottle artifacts must be checksum-verified before metadata is merged into the formula"
  end

  def test_bottle_job_reinstalls_and_tests_the_generated_artifact
    doc = load_yaml(BUILD_BOTTLES)
    bottle_steps = doc.dig("jobs", "bottle", "steps") || []
    reinstall_index = bottle_steps.index { |step| step["name"] == "Reinstall and test generated bottle" }
    upload_index = bottle_steps.index { |step| step["name"] == "Upload bottle artifacts" }

    refute_nil reinstall_index
    refute_nil upload_index
    script = bottle_steps.fetch(reinstall_index).fetch("run")
    assert_match(/brew uninstall --force ferritelabs\/ci\/ferrite/, script)
    assert_match(%r{brew install --force-bottle "\./\$\{BOTTLE_TARBALL\}"}, script)
    assert_match(/brew test ferritelabs\/ci\/ferrite/, script)
    assert reinstall_index < upload_index,
           "the locally generated bottle must install and pass its formula test before upload"
  end

  # The bottle-build matrix must never install/bottle a bare path
  # formula (`./ferrite.rb`): a path-based formula has no tap identity,
  # so `brew bottle --json`'s embedded `formula.path` is a raw,
  # runner-specific filesystem path instead of a stable tap-relative
  # one, which is exactly what makes the collect job's JSON
  # normalization necessary in the first place. Every bottle-job
  # Homebrew invocation must instead be tap-qualified under the same
  # deterministic `ferritelabs/ci` name used everywhere else in this
  # workflow and in ci.yml.
  def test_build_bottles_bottle_job_uses_tap_qualified_formula_never_a_path
    doc = load_yaml(BUILD_BOTTLES)
    bottle_steps = doc.dig("jobs", "bottle", "steps") || []
    run_scripts = bottle_steps.select { |step| step.is_a?(Hash) && step["run"] }.map { |step| step["run"] }

    tap_step = bottle_steps.find { |step| step.is_a?(Hash) && step["run"].to_s.include?("brew tap ferritelabs/ci") }
    refute_nil tap_step, "bottle job must tap the checkout under the deterministic ferritelabs/ci name"

    build_step = run_scripts.find { |run| run.include?("brew install --build-bottle") }
    refute_nil build_step, "bottle job must build a bottle with brew install --build-bottle"
    assert_match(/brew install --build-bottle ferritelabs\/ci\/ferrite\b/, build_step,
                 "bottle job must install the tap-qualified formula, never a path formula")
    refute_match(%r{brew install --build-bottle \./?ferrite\.rb}, build_step,
                 "bottle job must never install a path formula (./ferrite.rb)")

    assert_match(/brew bottle --json.*ferritelabs\/ci\/ferrite\b/, build_step,
                 "bottle job must run brew bottle --json against the tap-qualified formula")
    refute_match(%r{brew bottle --json[^
]*\./?ferrite\.rb}, build_step,
                 "bottle job must never run brew bottle --json against a path formula (./ferrite.rb)")

    tap_step_index = bottle_steps.index(tap_step)
    build_step_index = bottle_steps.index { |step| step.is_a?(Hash) && step["run"] == build_step }
    assert tap_step_index < build_step_index,
           "the checkout must be tapped before it is installed/bottled"
  end

  # After creating its own deterministic local tap, the collect job must
  # rewrite every downloaded bottle JSON's `formula.path` to this
  # runner's own TAPPED_FORMULA (expressed the same relative-to-
  # HOMEBREW_REPOSITORY way Homebrew itself generates it) *before*
  # `brew bottle --merge --write --no-commit` runs - otherwise the merge
  # resolves a foreign runner's embedded path instead of this runner's
  # tapped formula clone.
  def test_collect_normalizes_bottle_json_formula_path_before_merging
    source = BUILD_BOTTLES.read

    tap_index = source.index(/brew tap ferritelabs\/ci "\$\(pwd\)"/)
    tapped_formula_index = source.index(/TAPPED_FORMULA="\$\(brew formula ferritelabs\/ci\/ferrite\)"/)
    normalize_index = source.index(/formula_hash\.fetch\("formula"\)\["path"\]\s*=\s*relative_path/)
    merge_index = source.index(/brew bottle --merge --write --no-commit/)
    confirm_index = source.index(/grep -q "\^\[\[:space:\]\]\*bottle do" "\$\{TAPPED_FORMULA\}"/)
    copy_back_index = source.index(/cp\s+"\$\{TAPPED_FORMULA\}"\s+ferrite\.rb/)

    refute_nil tap_index, "collect must tap the checkout"
    refute_nil tapped_formula_index, "collect must resolve TAPPED_FORMULA"
    refute_nil normalize_index, "collect must normalize each JSON's formula.path to TAPPED_FORMULA"
    refute_nil merge_index, "collect must run the canonical brew bottle --merge --write --no-commit"
    refute_nil confirm_index, "collect must confirm the merge actually wrote into TAPPED_FORMULA"
    refute_nil copy_back_index, "collect must copy the merged tapped formula back to the checkout"

    assert tap_index < tapped_formula_index, "must tap before resolving TAPPED_FORMULA"
    assert tapped_formula_index < normalize_index, "must resolve TAPPED_FORMULA before normalizing JSON paths"
    assert normalize_index < merge_index, "must normalize JSON paths before merging"
    assert merge_index < confirm_index, "must merge before confirming the tapped formula was written"
    assert confirm_index < copy_back_index, "must confirm the merge succeeded before copying it back"
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
    assert_match(/ReleaseVersion\.validate!\(metadata\["version"\]\)/, source,
                 "must apply the shared strict stable-release validator to release metadata")
    assert_match(/ReleaseVersion\.validate!\(formula_version\)/, source,
                 "must apply the shared strict stable-release validator to ferrite.rb's url version")
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

  def assert_has_stable_release_validation(path)
    source = path.read
    assert_match(/ruby scripts\/release_version\.rb "\$\{VERSION\}"/, source,
                 "#{path.basename} must use the shared stable-release validator")
    refute_match(/SEMVER_REGEX=/, source,
                 "#{path.basename} must not drift to a workflow-local version grammar")

    validator_index = source.index(/ruby scripts\/release_version\.rb/)
    output_index = source.index(/echo "version=\$\{VERSION\}"/)
    download_index = source.index(/\bcurl\b/)
    build_index = source.index(/brew install --build-bottle/)

    refute_nil validator_index
    refute_nil output_index
    assert validator_index < output_index,
           "#{path.basename} must validate before exposing the version as a workflow output"
    assert validator_index < download_index,
           "#{path.basename} must reject invalid versions before any download"
    assert validator_index < build_index, "#{path.basename} must reject invalid versions before any build" if build_index

    validator = RELEASE_VERSION.read
    assert_match(/STABLE_PATTERN/, validator)
    assert_match(/no leading zeroes, prerelease, or build metadata/, validator)
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
