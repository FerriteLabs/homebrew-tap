# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "json"
require "tmpdir"
require "yaml"

# Runtime proof for the collect job's bottle-JSON `formula.path`
# normalization and merged-formula copy-back direction (build-bottles.yml).
#
# These tests do not merely assert on workflow YAML text (see
# WorkflowBehaviorTest for that); they extract the *actual* embedded
# Ruby normalization script and Bash confirm/copy-back snippet from
# build-bottles.yml and execute them for real, against fixture bottle
# JSON files shaped like what a macOS bottle-job runner and a Linux
# bottle-job runner would actually produce (different HOMEBREW_REPOSITORY
# prefixes, different absolute tap-clone paths), so a regression in the
# embedded script itself - not just its surrounding shell wiring - is
# caught here.
class BottleJsonNormalizationTest < Minitest::Test
  BUILD_BOTTLES = FerriteTap::WORKFLOWS_DIR + "build-bottles.yml"

  # Fixtures approximating the real, distinct `formula.tap_path`-derived
  # `formula.path` strings each bottle-job runner in the matrix embeds:
  # a macOS Homebrew install (arm64 Apple Silicon: /opt/homebrew) and a
  # Linux Homebrew install (Homebrew/actions/setup-homebrew on Ubuntu:
  # /home/linuxbrew/.linuxbrew), each with its own tap-relative suffix.
  MACOS_RUNNER = {
    homebrew_repository: "/opt/homebrew",
    formula_path:         "Library/Taps/ferritelabs/homebrew-ci/ferrite.rb",
  }.freeze

  LINUX_RUNNER = {
    homebrew_repository: "/home/linuxbrew/.linuxbrew",
    formula_path:         "Library/Taps/ferritelabs/homebrew-ci/ferrite.rb",
  }.freeze

  # A deliberately *foreign* raw absolute path, standing in for what a
  # naive (non-tap-qualified) bottle build would embed - the exact bug
  # this normalization step exists to correct. Used to prove the
  # normalization script overwrites whatever was there before, not just
  # a value that happens to already look right.
  FOREIGN_MACOS_CHECKOUT_PATH = "/Users/runner/work/homebrew-tap/homebrew-tap/ferrite.rb"
  FOREIGN_LINUX_CHECKOUT_PATH = "/home/runner/work/homebrew-tap/homebrew-tap/ferrite.rb"

  def setup
    @workflow_source = BUILD_BOTTLES.read
  end

  def extract_normalization_script
    match = @workflow_source.match(
      /ruby -rjson -rpathname -e '\n(.*?)\n\s*' "\$\{HOMEBREW_REPOSITORY_PATH\}" "\$\{TAPPED_FORMULA\}"/m,
    )
    refute_nil match, "collect job must embed the formula.path normalization Ruby script"
    match[1]
  end

  def write_fixture_json(dir, filename, formula_path)
    path = File.join(dir, filename)
    File.write(path, JSON.pretty_generate(
      "ferrite" => {
        "formula" => { "pkg_version" => "0.4.0", "path" => formula_path },
        "bottle"  => { "root_url" => "https://example.com", "tags" => {} },
      },
    ))
    path
  end

  def run_normalization_script(dir, homebrew_repository, tapped_formula)
    script = extract_normalization_script
    stdout, stderr, status = Open3.capture3(
      "ruby", "-rjson", "-rpathname", "-e", script, homebrew_repository, tapped_formula,
      chdir: dir,
    )
    assert status.success?, "normalization script failed: #{stdout}\n#{stderr}"
  end

  def test_normalizes_macos_runner_bottle_json_formula_path_to_tapped_formula
    Dir.mktmpdir do |dir|
      json_path = write_fixture_json(dir, "ferrite--0.4.0.arm64_sequoia.bottle.json", FOREIGN_MACOS_CHECKOUT_PATH)

      tapped_formula = File.join(MACOS_RUNNER[:homebrew_repository], MACOS_RUNNER[:formula_path])
      run_normalization_script(dir, MACOS_RUNNER[:homebrew_repository], tapped_formula)

      data = JSON.parse(File.read(json_path))
      assert_equal MACOS_RUNNER[:formula_path], data["ferrite"]["formula"]["path"],
                   "a macOS bottle-job runner's foreign checkout path must be normalized to this " \
                   "collect runner's tap-relative TAPPED_FORMULA path"
    end
  end

  def test_normalizes_linux_runner_bottle_json_formula_path_to_tapped_formula
    Dir.mktmpdir do |dir|
      json_path = write_fixture_json(dir, "ferrite--0.4.0.x86_64_linux.bottle.json", FOREIGN_LINUX_CHECKOUT_PATH)

      tapped_formula = File.join(LINUX_RUNNER[:homebrew_repository], LINUX_RUNNER[:formula_path])
      run_normalization_script(dir, LINUX_RUNNER[:homebrew_repository], tapped_formula)

      data = JSON.parse(File.read(json_path))
      assert_equal LINUX_RUNNER[:formula_path], data["ferrite"]["formula"]["path"],
                   "a Linux bottle-job runner's foreign checkout path must be normalized to this " \
                   "collect runner's tap-relative TAPPED_FORMULA path"
    end
  end

  # Proves normalization converges every platform's JSON onto the exact
  # same `formula.path` (this collect runner's TAPPED_FORMULA, relative
  # to its own HOMEBREW_REPOSITORY) regardless of whether the JSON came
  # from a macOS or a Linux bottle-job runner - which is what makes
  # `brew bottle --merge`'s file resolution deterministic no matter
  # which of the four per-platform JSON files is processed.
  def test_normalizes_mixed_macos_and_linux_fixtures_to_the_same_path_on_one_collect_runner
    Dir.mktmpdir do |dir|
      macos_json = write_fixture_json(dir, "ferrite--0.4.0.arm64_sequoia.bottle.json", FOREIGN_MACOS_CHECKOUT_PATH)
      linux_json = write_fixture_json(dir, "ferrite--0.4.0.x86_64_linux.bottle.json", FOREIGN_LINUX_CHECKOUT_PATH)

      # The collect job itself always runs on a single (ubuntu-latest)
      # runner, so both fixtures are normalized against the *same*
      # collect-runner HOMEBREW_REPOSITORY/TAPPED_FORMULA here.
      collect_homebrew_repository = "/home/linuxbrew/.linuxbrew"
      tapped_formula = "#{collect_homebrew_repository}/Library/Taps/ferritelabs/homebrew-ci/ferrite.rb"
      run_normalization_script(dir, collect_homebrew_repository, tapped_formula)

      macos_path = JSON.parse(File.read(macos_json))["ferrite"]["formula"]["path"]
      linux_path = JSON.parse(File.read(linux_json))["ferrite"]["formula"]["path"]

      assert_equal "Library/Taps/ferritelabs/homebrew-ci/ferrite.rb", macos_path
      assert_equal "Library/Taps/ferritelabs/homebrew-ci/ferrite.rb", linux_path
      assert_equal macos_path, linux_path,
                   "both platforms' JSON must normalize to the identical tap-relative path"
    end
  end

  def extract_confirm_and_copy_back_snippet
    match = @workflow_source.match(
      /(if ! grep -q "\^\[\[:space:\]\]\*bottle do" "\$\{TAPPED_FORMULA\}".*?\n\s*fi\n\s*cp "\$\{TAPPED_FORMULA\}" ferrite\.rb\n)/m,
    )
    refute_nil match, "collect job must embed the confirm-then-copy-back snippet"
    match[1]
  end

  def run_confirm_and_copy_back(dir, tapped_formula_content:)
    tapped_formula_path = File.join(dir, "tapped_ferrite.rb")
    File.write(tapped_formula_path, tapped_formula_content)
    File.write(File.join(dir, "ferrite.rb"), "class Ferrite < Formula\nend\n")

    snippet = extract_confirm_and_copy_back_snippet
    Open3.capture3(
      { "TAPPED_FORMULA" => tapped_formula_path },
      "bash", "-c", "set -euo pipefail\n#{snippet}",
      chdir: dir,
    )
  end

  def test_copy_back_succeeds_when_tapped_formula_has_a_merged_bottle_block
    Dir.mktmpdir do |dir|
      merged_content = "class Ferrite < Formula\n  bottle do\n    sha256 x: \"#{"a" * 64}\"\n  end\nend\n"
      _stdout, _stderr, status = run_confirm_and_copy_back(dir, tapped_formula_content: merged_content)

      assert status.success?, "confirm-and-copy-back must succeed when the tapped formula has a bottle block"
      assert_equal merged_content, File.read(File.join(dir, "ferrite.rb")),
                   "ferrite.rb in the checkout must end up with the tapped formula's merged content"
    end
  end

  def test_copy_back_refuses_when_tapped_formula_has_no_bottle_block
    Dir.mktmpdir do |dir|
      unmerged_content = "class Ferrite < Formula\nend\n"
      stdout, _stderr, status = run_confirm_and_copy_back(dir, tapped_formula_content: unmerged_content)

      refute status.success?, "confirm-and-copy-back must fail closed when the merge did not write a bottle block"
      assert_match(/did not write a bottle block/, stdout,
                   "must emit a ::error:: annotation (GitHub Actions writes these to stdout via echo) " \
                   "explaining why the copy-back was refused")
      # The checkout's ferrite.rb (written by run_confirm_and_copy_back before the snippet runs)
      # must be left untouched rather than being overwritten with unmerged content.
      checkout_content = File.read(File.join(dir, "ferrite.rb"))
      refute_includes checkout_content, "bottle do"
    end
  end
end
