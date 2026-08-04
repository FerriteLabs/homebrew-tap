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
    url_match = @source.match(%r{archive/refs/tags/v([^/]+)\.tar\.gz})
    refute_nil url_match, "url should reference a vX.Y.Z release tag archive"

    version = url_match[1]
    assert_equal version, FerriteTap::ReleaseVersion.validate!(version)

    # The head branch and livecheck strategy must stay consistent with a
    # tag-based release flow (not accidentally pointed at a branch tarball).
    assert_match(/head\s+"https:\/\/github\.com\/ferritelabs\/ferrite\.git",\s*branch:\s*"main"/, @source)
    assert_match(/strategy\s+:github_latest/, @source)
  end

  def test_livecheck_accepts_only_stable_release_tags
    livecheck = @source.match(/livecheck do.*?regex\(\/(.+?)\/i\).*?end/m)
    refute_nil livecheck, "livecheck must define a case-insensitive release tag regex"

    regex = Regexp.new(livecheck[1], Regexp::IGNORECASE)
    %w[v0.4.0 1.2.3 v10.20.30].each { |tag| assert_match regex, tag }
    %w[v01.2.3 v1.02.3 v1.2.03 v1.2.3-rc.1 v1.2.3+build.5 v1.2.3.4].each do |tag|
      refute_match regex, tag
    end
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

  # Structural invariants for the server-readiness retry/cleanup pattern:
  # the readiness poll and every assertion that depends on the running
  # server must live inside a single begin/ensure so the forked
  # server_pid is always terminated and reaped, and the poll itself must
  # not use an assertion (shell_output's default 0-exit check) against a
  # command that is *expected* to fail on early retries.
  def test_do_block_readiness_polling_is_inside_begin_ensure
    test_match = @source.match(/\btest do(.*)\z/m)
    refute_nil test_match, "test do block must be present"

    body = test_match[1]

    fork_index = body.index(/server_pid\s*=\s*fork\s+do/)
    refute_nil fork_index, "test block must fork the server into server_pid"

    begin_index = body.index(/^\s*begin\s*$/)
    refute_nil begin_index, "test block must open a begin block around the server lifecycle"

    ensure_index = body.index(/^\s*ensure\s*$/)
    refute_nil ensure_index, "test block must have an ensure clause to clean up the server"

    retry_index = body.index(/\d+\.times do/)
    refute_nil retry_index, "test block must retry the readiness check"

    readiness_assert_index = body.index(/assert\s+ready\b/)
    refute_nil readiness_assert_index, "test block must require readiness before continuing"

    assert fork_index < begin_index,
           "the server must be forked before the begin block so ensure can always see server_pid"
    assert begin_index < retry_index,
           "the readiness retry loop must be inside the begin block (so cleanup always runs)"
    assert retry_index < ensure_index,
           "the readiness retry loop must complete before the ensure clause"
    assert begin_index < readiness_assert_index && readiness_assert_index < ensure_index,
           "the readiness requirement must be asserted inside begin/ensure, not after it"
  end

  def test_readiness_poll_does_not_assert_on_transient_nonzero_exit
    test_match = @source.match(/\btest do(.*)\z/m)
    refute_nil test_match, "test do block must be present"

    body = test_match[1]

    retry_match = body.match(/(\d+)\.times do(.*?)\n\s*end\n/m)
    refute_nil retry_match, "test block must retry the readiness check in a Ruby retry loop"

    retry_body = retry_match[2]
    refute_match(/shell_output\(/, retry_body,
                 "the readiness poll must not use shell_output, which raises on the transient " \
                 "non-zero exit every ferrite-cli call returns before the server is listening")
    assert_match(/Kernel\.system\(/, retry_body,
                 "the readiness poll should use a quiet Kernel.system(...) call that returns a " \
                 "boolean instead of raising on a not-yet-ready server")
    assert_match(/out:\s*File::NULL/, retry_body, "the readiness poll should discard command output")
    assert_match(/err:\s*File::NULL/, retry_body, "the readiness poll should discard command error output")
  end

  # `system(...)` called bare inside a Formula's `test do` block resolves
  # to `Formula#system` (instance method lookup finds it before
  # `Kernel#system`), which raises `BuildError` on a non-zero exit and
  # does not accept `out:`/`err:` redirection keywords - either of which
  # would break the retry loop above outright. The readiness poll must
  # call `Kernel.system` explicitly (bypassing that method-resolution
  # order) and must pass a real String command (`.to_s`), not a bare
  # Pathname, matching `Kernel.system`'s documented argument handling.
  def test_readiness_poll_uses_kernel_system_not_formula_system
    test_match = @source.match(/\btest do(.*)\z/m)
    refute_nil test_match, "test do block must be present"

    body = test_match[1]
    retry_match = body.match(/(\d+)\.times do(.*?)\n\s*end\n/m)
    refute_nil retry_match, "test block must retry the readiness check in a Ruby retry loop"

    retry_body = retry_match[2]
    refute_match(/[^.\w]system\(\s*bin/, retry_body,
                 "the readiness poll must not call bare system(...), which resolves to " \
                 "Formula#system (raises BuildError, no out:/err: support) inside a test do block")
    assert_match(/Kernel\.system\(\s*\(bin\s*\/\s*"ferrite-cli"\)\.to_s/, retry_body,
                 "the readiness poll must call Kernel.system((bin/\"ferrite-cli\").to_s, ...) " \
                 "explicitly so it is Kernel#system (boolean, non-raising, redirection-capable), " \
                 "not Formula#system")
  end

  def test_ensure_clause_always_terminates_and_reaps_server_pid
    test_match = @source.match(/\btest do(.*)\z/m)
    refute_nil test_match, "test do block must be present"

    body = test_match[1]
    ensure_index = body.index(/^\s*ensure\s*$/)
    refute_nil ensure_index, "test block must have an ensure clause"
    ensure_body = body[ensure_index..]

    assert_match(/Process\.kill\("TERM",\s*server_pid\)/, ensure_body,
                 "ensure clause must terminate the exact forked server_pid")
    assert_match(/Process\.wait\(server_pid\)/, ensure_body,
                 "ensure clause must reap the exact forked server_pid to avoid a zombie process")
    assert_match(/rescue\s+Errno::ESRCH/, ensure_body,
                 "cleanup must tolerate a server that exited before TERM is sent")
    assert_match(/rescue\s+Errno::ESRCH.*?ensure.*?Process\.wait\(server_pid\)/m, ensure_body,
                 "reaping must run from an inner ensure even when terminating the child raises")
  end

  def test_install_defines_forge_feature_toggle
    install_match = @source.match(/def install(.*?)\n\s*end\n/m)
    refute_nil install_match, "install method must be present"

    body = install_match[1]
    assert_match(/features\s*\+=\s*",forge-runtime"\s+if\s+build\.with\?\("forge"\)/, body)
  end
end
