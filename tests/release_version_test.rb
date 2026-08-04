# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class ReleaseVersionTest < Minitest::Test
  VALID_VERSIONS = %w[
    0.0.0
    0.4.0
    1.2.3
    10.20.30
    999.0.1
  ].freeze

  INVALID_VERSIONS = [
    "",
    "v1.2.3",
    "01.2.3",
    "1.02.3",
    "1.2.03",
    "1.2",
    "1.2.3.4",
    "1.2.3-alpha",
    "1.2.3-rc.1",
    "1.2.3+build.5",
    "1.2.3-alpha+build.5",
    " 1.2.3",
    "1.2.3 ",
  ].freeze

  def test_accepts_only_stable_three_component_versions
    VALID_VERSIONS.each do |version|
      assert_equal version, FerriteTap::ReleaseVersion.validate!(version)
    end
  end

  def test_rejects_leading_zeroes_prereleases_and_build_metadata_clearly
    INVALID_VERSIONS.each do |version|
      error = assert_raises(ArgumentError) do
        FerriteTap::ReleaseVersion.validate!(version)
      end

      assert_includes error.message, "stable release version exactly X.Y.Z"
      assert_includes error.message, "no leading zeroes, prerelease, or build metadata"
    end
  end

  def test_release_urls_branches_and_tags_are_derived_from_validated_version
    version = "1.2.3"

    assert_equal "v1.2.3", FerriteTap::ReleaseVersion.release_tag(version)
    assert_equal "update-ferrite-1.2.3", FerriteTap::ReleaseVersion.formula_branch(version)
    assert_equal "update-ferrite-bottles-1.2.3", FerriteTap::ReleaseVersion.bottle_branch(version)
    assert_equal "https://github.com/ferritelabs/ferrite/archive/refs/tags/v1.2.3.tar.gz",
                 FerriteTap::ReleaseVersion.archive_url(version)
    assert_equal "https://github.com/ferritelabs/homebrew-tap/releases/download/v1.2.3",
                 FerriteTap::ReleaseVersion.bottle_release_url(version)
  end

  def test_naming_helpers_reject_non_stable_versions
    %i[release_tag formula_branch bottle_branch archive_url bottle_release_url].each do |method|
      assert_raises(ArgumentError) do
        FerriteTap::ReleaseVersion.public_send(method, "1.2.3-rc.1")
      end
    end
  end

  def test_cli_accepts_stable_version_and_rejects_prerelease_with_clear_error
    script = (FerriteTap::ROOT + "scripts" + "release_version.rb").to_s

    output, status = Open3.capture2e("ruby", script, "1.2.3")
    assert status.success?, output
    assert_equal "1.2.3\n", output

    output, status = Open3.capture2e("ruby", script, "1.2.3+build.5")
    refute status.success?
    assert_includes output, "::error::"
    assert_includes output, "stable release version exactly X.Y.Z"
  end
end
