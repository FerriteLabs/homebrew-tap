# frozen_string_literal: true

require_relative "test_helper"

class DocumentationContractTest < Minitest::Test
  README = FerriteTap::ROOT + "README.md"
  SUPPORT = FerriteTap::ROOT + "SUPPORT.md"
  CHANGELOG = FerriteTap::ROOT + "CHANGELOG.md"

  def test_public_install_command_uses_official_formula_name
    source = README.read

    assert_match(/^brew install ferritelabs\/tap\/ferrite$/, source)
    assert_match(/^brew install --build-from-source ferritelabs\/tap\/ferrite$/, source)
    refute_match(/^brew tap ferritelabs\/ferrite$/, source)
    refute_match(/^brew install ferrite$/, source)
  end

  def test_public_documentation_urls_use_stable_github_fallback
    [README, SUPPORT].each do |path|
      source = path.read
      refute_match(%r{https?://(?:www\.)?ferrite\.(?:dev|rs)}, source,
                   "#{path.basename} must not link to an unavailable or parked domain")
      refute_match(/[A-Za-z0-9._%+-]+@ferrite\.(?:dev|rs)/, source,
                   "#{path.basename} must not publish an unverified email domain")
    end

    assert_match(%r{https://github\.com/ferritelabs/ferrite-docs}, SUPPORT.read)
  end

  def test_release_checklist_preserves_docs_domain_blocker
    source = README.read

    assert_match(/Release blocker:/, source)
    assert_match(/- \[ \] Deploy and verify the GitHub Pages documentation fallback/, source)
  end

  def test_0_5_0_is_documented_as_planned_not_released
    source = CHANGELOG.read

    assert_match(/^## \[Unreleased\] - Planned for Ferrite 0\.5\.0$/, source)
    refute_match(/^## \[0\.5\.0\] - \d{4}-\d{2}-\d{2}$/, source)
  end
end
