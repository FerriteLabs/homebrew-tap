# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"

# Runtime proof for the server-readiness polling fix.
#
# Inside a Formula's `test do` block, `self` is the Formula instance, so
# a bare `system(...)` call resolves to `Formula#system` - not
# `Kernel#system` - because Ruby's method lookup finds the instance
# method before falling back to a module mixed into Object. That matters
# here because `Formula#system`:
#   * does not accept `out:`/`err:` redirection keywords (it has its own
#     fixed signature and forking/logging behavior), and
#   * raises `BuildError` on any non-zero exit instead of returning
#     `false`,
# either of which would break the readiness retry loop outright: the very
# first not-yet-ready attempt would blow up instead of retrying.
#
# These tests do not merely assert on source text (see
# FormulaStructureTest); they actually `instance_eval` the exact retry
# loop extracted from ferrite.rb inside a harness object whose own
# `system` method raises (mimicking `Formula#system`), against a real
# forked helper script that fails a few times before succeeding. If
# ferrite.rb ever regresses to a bare `system(...)` call, this test
# raises instead of retrying and fails loudly.
class FormulaReadinessPollingTest < Minitest::Test
  # A stand-in for the Formula instance the real `test do` block runs
  # inside of: it defines its own raising, kwarg-incompatible `system`
  # method (mimicking Formula#system) so that a regression back to a
  # bare `system(...)` call in the extracted loop is caught by this
  # method being invoked (and raising) instead of silently succeeding.
  class FakeFormulaTestContext
    attr_reader :sleep_calls

    def initialize(cli_path)
      @cli_path = cli_path
      @sleep_calls = 0
    end

    def bin
      Pathname.new(File.dirname(@cli_path))
    end

    def port
      0
    end

    # Mimics Formula#system: fixed positional signature (no out:/err:
    # keyword support) and raises instead of returning a boolean.
    def system(*)
      raise "Formula#system-shaped method must never be invoked by the readiness poll " \
            "(expected Kernel.system to be called explicitly instead)"
    end

    # Stubbed out so the extracted retry loop's `sleep 1` does not
    # actually slow this test down; still records that it was reached.
    def sleep(_seconds)
      @sleep_calls += 1
    end
  end

  def setup
    @source = FerriteTap.formula_source
  end

  def extracted_retry_loop_source
    test_match = @source.match(/\btest do(.*)\z/m)
    refute_nil test_match, "test do block must be present"

    retry_match = test_match[1].match(/(\d+)\.times do(.*?)\n\s*end\n/m)
    refute_nil retry_match, "test block must retry the readiness check in a Ruby retry loop"

    times = Integer(retry_match[1])
    body = retry_match[2]
    [times, body]
  end

  # Builds a fake `ferrite-cli` that fails `fail_count` times (exit 1)
  # before succeeding (exit 0), tracking its own invocation count in a
  # sibling file so no arguments need to be threaded through the exact
  # `Kernel.system(..., "-p", port.to_s, "PING", ...)` call shape.
  def write_fake_cli(dir, fail_count)
    cli_path = File.join(dir, "ferrite-cli")
    counter_path = File.join(dir, "attempts.count")
    File.write(cli_path, <<~SH)
      #!/bin/sh
      counter="#{counter_path}"
      count=0
      if [ -f "${counter}" ]; then count=$(cat "${counter}"); fi
      count=$((count + 1))
      echo "${count}" > "${counter}"
      if [ "${count}" -le #{fail_count} ]; then
        exit 1
      fi
      exit 0
    SH
    FileUtils.chmod(0o755, cli_path)
    [cli_path, counter_path]
  end

  def test_extracted_retry_loop_becomes_ready_after_transient_failures_without_raising
    FerriteTap.with_temp_dir("readiness-") do |dir|
      cli_path, counter_path = write_fake_cli(dir, 2)
      times, retry_body = extracted_retry_loop_source

      context = FakeFormulaTestContext.new(cli_path)
      # `instance_eval` runs inside `context`, so a regression to a bare
      # `system(...)` call in ferrite.rb resolves to
      # FakeFormulaTestContext#system above and raises here. `ready` is
      # a local variable inside this single eval'd string (mirroring
      # ferrite.rb's own `ready = false` initialization before the
      # loop), so it is captured into an ivar in the same eval to read
      # back afterwards.
      context.instance_eval(<<~RUBY, __FILE__, __LINE__ + 1)
        ready = false
        #{times}.times do
          #{retry_body}
        end
        @__last_ready = ready
      RUBY
      ready = context.instance_variable_get(:@__last_ready)

      assert_equal 3, File.read(counter_path).to_i,
                   "fake ferrite-cli should have been invoked exactly 3 times (2 failures + 1 success)"
      assert ready, "the retry loop should report ready once the underlying command succeeds"
      assert_operator context.sleep_calls, :>=, 2,
                       "the loop should have slept between the two failed attempts"
    end
  end

  def test_extracted_retry_loop_exhausts_retries_when_command_never_succeeds
    FerriteTap.with_temp_dir("readiness-") do |dir|
      cli_path, counter_path = write_fake_cli(dir, 999)
      times, retry_body = extracted_retry_loop_source

      context = FakeFormulaTestContext.new(cli_path)
      context.instance_eval(<<~RUBY, __FILE__, __LINE__ + 1)
        ready = false
        #{times}.times do
          #{retry_body}
        end
        @__last_ready = ready
      RUBY
      ready = context.instance_variable_get(:@__last_ready)

      assert_equal times, File.read(counter_path).to_i,
                   "a permanently failing command should be retried exactly #{times} times"
      refute ready, "the retry loop must not report ready when the command never succeeds"
    end
  end

  # Confirms the underlying Ruby semantics the whole fix relies on:
  # `Kernel.system` is unaffected by an instance `system` override,
  # returns a boolean instead of raising on a non-zero exit, and honors
  # `out:`/`err:` redirection - none of which hold for a bare `system`
  # call resolved against an object that defines its own `system` method.
  def test_kernel_system_bypasses_instance_system_override_and_does_not_raise
    context = FakeFormulaTestContext.new("/nonexistent/does-not-matter")

    assert_raises(RuntimeError) { context.instance_eval { system("false") } }

    result = context.instance_eval { Kernel.system("false", out: File::NULL, err: File::NULL) }
    assert_equal false, result, "Kernel.system must return false (not raise) on a non-zero exit"

    result = context.instance_eval { Kernel.system("true", out: File::NULL, err: File::NULL) }
    assert_equal true, result, "Kernel.system must return true on success"
  end
end
