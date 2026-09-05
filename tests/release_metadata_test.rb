# frozen_string_literal: true

require_relative "test_helper"

class ReleaseMetadataTest < Minitest::Test
  def setup
    @metadata = FerriteTap.release_metadata
    @formula = FerriteTap.formula_source
  end

  def test_metadata_file_exists_and_has_required_release_fields
    assert FerriteTap::RELEASE_METADATA_PATH.file?
    %w[version sha256 url updated_at updated_by].each do |key|
      assert @metadata.key?(key), "release-metadata.json is missing #{key.inspect}"
    end
  end

  def test_live_metadata_uses_a_valid_release_version
    assert_equal @metadata["version"], FerriteTap::ReleaseVersion.validate!(@metadata["version"])
  end

  def test_optional_planned_release_does_not_fabricate_release_artifacts
    planned = @metadata["next_release"]
    return if planned.nil?

    planned_version = FerriteTap::ReleaseVersion.validate!(planned.fetch("version"))
    assert_equal "v#{planned_version}", planned["upstream_tag"]
    assert_equal "awaiting_upstream_tag", planned["status"]
    assert_equal "update-formula.yml", planned["formula_update_workflow"]
    assert_equal "build-bottles.yml", planned["bottle_workflow"]
    assert_equal 1, planned_version.split(".").map(&:to_i) <=> @metadata["version"].split(".").map(&:to_i)
    assert_kind_of Array, planned.fetch("blockers", [])
    refute planned.key?("sha256"), "planned release metadata must not fabricate a source checksum"
    refute planned.key?("bottles"), "planned release metadata must not fabricate bottle hashes"
  end

  def test_metadata_url_is_derived_from_the_strictly_validated_version
    assert_equal FerriteTap::ReleaseVersion.archive_url(@metadata["version"]), @metadata["url"]
  end

  def test_formula_and_release_metadata_stay_in_sync
    formula_url = @formula[/^\s*url\s+"([^"]+)"/, 1]
    formula_sha256 = @formula[/^\s*sha256\s+"([0-9a-f]{64})"/, 1]

    assert_equal @metadata["url"], formula_url
    assert_equal @metadata["sha256"], formula_sha256
  end
end
