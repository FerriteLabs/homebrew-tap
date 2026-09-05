# frozen_string_literal: true

require_relative "test_helper"
require_relative "../scripts/update_formula"
require "json"
require "open3"

class FormulaUpdateTest < Minitest::Test
  OLD_SHA256 = "1" * 64
  NEW_SHA256 = "2" * 64
  NEW_VERSION = "1.2.3"
  NEW_URL = "https://github.com/ferritelabs/ferrite/archive/refs/tags/v#{NEW_VERSION}.tar.gz"

  def test_version_update_removes_all_prior_bottle_metadata
    formula = <<~RUBY
      class Ferrite < Formula
        desc "Ferrite"
        url "https://github.com/ferritelabs/ferrite/archive/refs/tags/v1.2.2.tar.gz"
        sha256 "#{OLD_SHA256}"

        bottle do
          root_url "https://github.com/ferritelabs/homebrew-tap/releases/download/v1.2.2"
          rebuild 7
          sha256 cellar: :any_skip_relocation, arm64_sequoia: "#{"3" * 64}"
          sha256 cellar: :any_skip_relocation, x86_64_linux: "#{"4" * 64}"
        end

        def install
          bin.install "ferrite"
        end
      end
    RUBY

    updated = FerriteTap::FormulaUpdater.update(
      formula: formula,
      version: NEW_VERSION,
      sha256: NEW_SHA256,
      archive_url: NEW_URL,
    )

    assert_includes updated, %(  url "#{NEW_URL}")
    assert_includes updated, %(  sha256 "#{NEW_SHA256}")
    refute_includes updated, "bottle do"
    refute_includes updated, "rebuild 7"
    refute_includes updated, "releases/download/v1.2.2"
    refute_includes updated, "3" * 64
    refute_includes updated, "4" * 64
  end

  def test_update_rejects_multiple_bottle_blocks
    formula = <<~RUBY
      class Ferrite < Formula
        url "https://github.com/ferritelabs/ferrite/archive/refs/tags/v1.2.2.tar.gz"
        sha256 "#{OLD_SHA256}"
        bottle do
          sha256 cellar: :any_skip_relocation, arm64_sequoia: "#{"3" * 64}"
        end
        bottle do
          sha256 cellar: :any_skip_relocation, x86_64_linux: "#{"4" * 64}"
        end
      end
    RUBY

    error = assert_raises(RuntimeError) do
      FerriteTap::FormulaUpdater.update(
        formula: formula,
        version: NEW_VERSION,
        sha256: NEW_SHA256,
        archive_url: NEW_URL,
      )
    end

    assert_match(/more than one bottle block/, error.message)
  end

  def test_update_rejects_url_that_does_not_match_version
    error = assert_raises(RuntimeError) do
      FerriteTap::FormulaUpdater.update(
        formula: FerriteTap.formula_source,
        version: NEW_VERSION,
        sha256: NEW_SHA256,
        archive_url: "https://example.com/ferrite.tar.gz",
      )
    end

    assert_match(/archive url does not match version/, error.message)
  end

  def test_update_rejects_non_stable_versions_before_updating_formula
    %w[01.2.3 1.2.3-rc.1 1.2.3+build.5].each do |version|
      error = assert_raises(ArgumentError) do
        FerriteTap::FormulaUpdater.update(
          formula: FerriteTap.formula_source,
          version: version,
          sha256: NEW_SHA256,
          archive_url: "https://github.com/ferritelabs/ferrite/archive/refs/tags/v#{version}.tar.gz",
        )
      end

      assert_includes error.message, "stable release version exactly X.Y.Z"
    end
  end

  def test_metadata_rejects_non_stable_versions
    error = assert_raises(ArgumentError) do
      FerriteTap::FormulaUpdater.metadata(
        version: "1.2.3-alpha",
        sha256: NEW_SHA256,
        archive_url: "https://github.com/ferritelabs/ferrite/archive/refs/tags/v1.2.3-alpha.tar.gz",
      )
    end

    assert_includes error.message, "no leading zeroes, prerelease, or build metadata"
  end

  def test_workflow_updater_replaces_formula_and_metadata_files
    FerriteTap.with_temp_dir("formula-update-") do |directory|
      formula_path = File.join(directory, "ferrite.rb")
      metadata_path = File.join(directory, "release-metadata.json")
      File.write(formula_path, <<~RUBY)
        class Ferrite < Formula
          url "https://github.com/ferritelabs/ferrite/archive/refs/tags/v1.2.2.tar.gz"
          sha256 "#{OLD_SHA256}"
          bottle do
            root_url "https://old.example/v1.2.2"
            rebuild 9
            sha256 cellar: :any_skip_relocation, arm64_sequoia: "#{"3" * 64}"
          end
        end
      RUBY
      File.write(metadata_path, JSON.generate("version" => "1.2.2"))

      environment = {
        "VERSION" => NEW_VERSION,
        "SHA256" => NEW_SHA256,
        "ARCHIVE_URL" => NEW_URL,
      }
      output, status = Open3.capture2e(
        environment,
        "ruby",
        (FerriteTap::ROOT + "scripts" + "update_formula.rb").to_s,
        formula_path,
        metadata_path,
      )

      assert status.success?, output
      updated_formula = File.read(formula_path)
      refute_match(/bottle do|root_url|rebuild\s+9|#{Regexp.escape("3" * 64)}/, updated_formula)
      assert_includes updated_formula, %(url "#{NEW_URL}")
      assert_includes updated_formula, %(sha256 "#{NEW_SHA256}")

      metadata = JSON.parse(File.read(metadata_path))
      assert_equal NEW_VERSION, metadata["version"]
      assert_equal NEW_SHA256, metadata["sha256"]
      assert_equal NEW_URL, metadata["url"]
    end
  end
end
