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

  def test_metadata_uses_current_stable_release_0_4_0
    assert_equal "0.4.0", @metadata["version"]
    assert_equal @metadata["version"], FerriteTap::ReleaseVersion.validate!(@metadata["version"])
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
