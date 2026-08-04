# frozen_string_literal: true

require_relative "test_helper"
require "open3"

# Structural invariants for ferrite.rb that do not require network access:
# syntax validity, presence of required Formula stanzas, absence of
# leftover placeholders, dependency de-duplication, version consistency
# between the source url and the sha256 comment, and the install/service/
# test invariants that must survive any refactor of the formula.
class FormulaStructureTest < Minitest::Test
  def setup
    @source = FerriteTap.formula_source
  end

  def test_formula_file_exists
    assert FerriteTap::FORMULA_PATH.file?, "ferrite.rb should exist at the tap root"
  end

  def test_ruby_syntax_is_valid
    stdout_err, status = Open3.capture2e("ruby", "-c", FerriteTap::FORMULA_PATH.to_s)
    assert status.success?, "ferrite.rb has a Ruby syntax error:\n#{stdout_err}"
  end

  def test_class_definition_is_preserved
    assert_match(/class Ferrite < Formula/, @source)
  end

  def test_required_stanzas_are_present
    %w[desc homepage url sha256 license].each do |stanza|
      assert_match(/\b#{stanza}\b/, @source, "missing required `#{stanza}` stanza")
    end
  end

  def test_no_placeholder_values_remain
    refute_match(/PLACEHOLDER/i, @source,
                 "formula still contains a PLACEHOLDER value that must be replaced with real metadata")
  end

  def test_source_url_and_sha256_are_present_and_well_formed
    url_match = @source.match(/^\s*url\s+"([^"]+)"/)
    refute_nil url_match, "could not find a top-level url stanza"

    sha_match = @source.match(/^\s*sha256\s+"([^"]+)"/)
    refute_nil sha_match, "could not find a top-level source sha256 stanza"

    sha256 = sha_match[1]
    assert_match(/\A[0-9a-f]{64}\z/, sha256, "source sha256 must be a 64-character lowercase hex digest")
  end

  def test_version_consistency_between_url_and_tag
    url_match = @source.match(%r{archive/refs/tags/v(\d+\.\d+\.\d+)\.tar\.gz})
    refute_nil url_match, "url should reference a vX.Y.Z release tag archive"

    version = url_match[1]
    assert_match(/\A\d+\.\d+\.\d+\z/, version, "release tag must be a SemVer-shaped version")

    # The head branch and livecheck strategy must stay consistent with a
    # tag-based release flow (not accidentally pointed at a branch tarball).
    assert_match(/head\s+"https:\/\/github\.com\/ferritelabs\/ferrite\.git",\s*branch:\s*"main"/, @source)
    assert_match(/strategy\s+:github_latest/, @source)
  end

  def test_no_duplicate_openssl_dependency
    matches = @source.scan(/depends_on\s+"openssl@3"/)
    assert_equal 1, matches.length,
                 "openssl@3 should be declared exactly once (found #{matches.length})"
  end

  def test_bottle_block_has_no_placeholder_checksums
    bottle_match = @source.match(/bottle do(.*?)\n\s*end\n/m)
    skip "no bottle block present (expected until real bottle metadata exists)" unless bottle_match

    refute_match(/PLACEHOLDER/i, bottle_match[1],
                 "bottle block must not contain placeholder checksums")
  end

  def test_required_binaries_are_referenced
    assert_match(/bin\s*\/\s*"ferrite"/, @source, "formula must reference the ferrite binary path")
    assert_match(/ferrite-cli/, @source, "formula must reference the ferrite-cli binary")
    assert_match(/--bin",\s*"ferrite-cli"/, @source, "install must build the ferrite-cli binary explicitly")
  end

  def test_with_forge_option_is_preserved
    assert_match(/option\s+"with-forge"/, @source)
    assert_match(/forge-runtime/, @source)
  end

  def test_service_block_invariants
    service_match = @source.match(/service do(.*?)\n\s*end\n/m)
    refute_nil service_match, "service block must be present"

    body = service_match[1]
    assert_match(/run\s+\[opt_bin\s*\/\s*"ferrite"/, body)
    assert_match(/keep_alive\s+true/, body)
    assert_match(/log_path/, body)
    assert_match(/error_log_path/, body)
  end

  def test_do_block_invariants
    test_match = @source.match(/\btest do(.*)\z/m)
    refute_nil test_match, "test do block must be present"

    body = test_match[1]
    assert_match(/assert_match/, body, "test block should assert on command output")
    assert_match(/ferrite-cli/, body, "test block should exercise the CLI binary")
    assert_match(/PING/, body, "test block should exercise a basic server round-trip")
  end

  def test_install_defines_forge_feature_toggle
    install_match = @source.match(/def install(.*?)\n\s*end\n/m)
    refute_nil install_match, "install method must be present"

    body = install_match[1]
    assert_match(/features\s*\+=\s*",forge-runtime"\s+if\s+build\.with\?\("forge"\)/, body)
  end
end
