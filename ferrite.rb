# typed: false
# frozen_string_literal: true

# Formula for Ferrite: a Redis-compatible, tiered-storage key-value store
# with agent memory and an optional WASM in-DB function runtime (Forge).
class Ferrite < Formula
  desc "Redis-compatible tiered-storage key-value store with agent memory and WASM"
  homepage "https://github.com/ferritelabs/ferrite"
  url "https://github.com/ferritelabs/ferrite/archive/refs/tags/v0.4.0.tar.gz"
  # SHA256 of the v0.4.0 release tarball, verified against the upstream
  # GitHub archive. To recompute manually: curl -sL <url> | shasum -a 256
  # This value is kept in sync by the update-formula workflow, which
  # recomputes the canonical checksum itself rather than trusting inputs.
  sha256 "b4db8cc8eb0d3c2cef4a019a47d550c347df69fb8a4f77550c814fae463005cf"
  license "Apache-2.0"

  head "https://github.com/ferritelabs/ferrite.git", branch: "main"

  livecheck do
    url :stable
    strategy :github_latest
    regex(/^v?((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))$/i)
  end

  option "with-forge", "Enable Forge WASM in-DB function runtime (ADR-019)"

  depends_on "cmake" => :build
  depends_on "pkg-config" => :build
  depends_on "rust" => :build
  # Runtime dependency for TLS support on every supported platform.
  # On macOS, prefer the Homebrew-installed OpenSSL over system LibreSSL.
  depends_on "openssl@3"
  uses_from_macos "curl"

  # Minimum Rust version is declared upstream via Cargo.toml rust-version;
  # see https://github.com/ferritelabs/ferrite/blob/v0.4.0/Cargo.toml
  def install
    features = "tls,cli"
    features += ",forge-runtime" if build.with?("forge")

    # Build with TLS and CLI features enabled (optionally with Forge)
    system "cargo", "install", *std_cargo_args, "--features", features

    # Install CLI tools
    system "cargo", "install", *std_cargo_args(path: "."), "--features", features, "--bin", "ferrite-cli"

    # Install man pages if they exist
    man1.install Dir["docs/man/*.1"] if Dir.exist?("docs/man")

    # Install shell completions
    generate_completions_from_executable(bin/"ferrite", "completions")
  end

  def post_install
    config_dir = etc/"ferrite"
    config_file = config_dir/"ferrite.toml"
    return if config_file.exist?

    write_generated_config(config_file, var/"lib/ferrite")
  end

  def write_generated_config(config_file, data_dir)
    config_file.dirname.mkpath
    temporary = config_file.dirname/".ferrite.toml.tmp-#{Process.pid}"
    temporary.unlink if temporary.exist?

    system bin/"ferrite", "init",
           "--output", temporary,
           "--data-dir", data_dir

    content = temporary.read
    raise "ferrite init produced an empty configuration" if content.empty?

    unavailable_docs_domain = %w[ferrite dev].join(".")
    unavailable_docs_url = "https://#{unavailable_docs_domain}/docs/reference/configuration"
    content = content.gsub(
      unavailable_docs_url,
      "https://github.com/ferritelabs/ferrite-docs",
    )
    unavailable_url = content.match?(%r{https?://(?:www\.)?ferrite\.(?:dev|rs)})
    if unavailable_url
      raise "generated configuration contains an unavailable documentation URL"
    end

    temporary.write(content)
    temporary.rename(config_file)
  ensure
    temporary&.unlink if temporary&.exist?
  end

  def caveats
    <<~EOS
      Ferrite is installed! To get started:

        # Start the server with default configuration
        ferrite

        # Or with a custom config file
        ferrite --config #{etc}/ferrite/ferrite.toml

        # Connect with the CLI client
        ferrite-cli

      Data directory: #{var}/lib/ferrite
      Logs directory: #{var}/log/ferrite
      Configuration: #{etc}/ferrite/ferrite.toml

      A version-compatible configuration is generated on first install.
      Existing configuration is preserved during upgrades.

      To start ferrite as a background service:
        brew services start ferrite

      To enable TLS for production deployments:
        ferrite --tls-cert-file /path/to/cert.pem --tls-key-file /path/to/key.pem

      Documentation:
        https://github.com/ferritelabs/ferrite-docs
    EOS
  end

  service do
    run [opt_bin/"ferrite", "--config", etc/"ferrite/ferrite.toml"]
    keep_alive true
    working_dir var/"lib/ferrite"
    log_path var/"log/ferrite/ferrite.log"
    error_log_path var/"log/ferrite/ferrite.error.log"
    environment_variables RUST_LOG: "ferrite=info"
  end

  test do
    # Verify the binary runs and reports its version
    assert_match version.to_s, shell_output("#{bin}/ferrite --version")

    # Generate configuration with the installed binary so the test tracks
    # the exact configuration schema supported by this Ferrite version.
    config = testpath/"ferrite.toml"
    write_generated_config(config, testpath/"data")
    assert_path_exists config
    refute_match %r{https?://(?:www\.)?ferrite\.(?:dev|rs)}, config.read

    # Start server in background
    port = free_port
    server_pid = fork do
      exec bin/"ferrite", "--config", config, "--port", port.to_s
    end

    # Readiness polling and every assertion that depends on the server
    # live inside this single begin/ensure so the forked server_pid is
    # *always* terminated and reaped, whether the server never becomes
    # ready, a functional assertion fails, or everything succeeds.
    begin
      # Wait for the server to be ready (retry up to 10 times). Polling
      # uses a quiet `Kernel.system` call instead of `shell_output`:
      # ferrite-cli exits non-zero on every attempt before the server has
      # bound its port, and shell_output(cmd) asserts a zero exit status
      # by default, so using it here would raise (and fail the test) on
      # the very first retry instead of giving the server a chance to
      # start.
      #
      # This must call `Kernel.system` explicitly rather than a bare
      # `system(...)`: inside a Formula's `test do` block, `self` is the
      # Formula instance, so an unqualified `system` call resolves to
      # `Formula#system` (method lookup finds it before `Kernel#system`)
      # - which does not accept `out:`/`err:` redirection keywords and,
      # more importantly, raises `BuildError` on a non-zero exit instead
      # of returning `false`. Either of those would break this retry
      # loop outright: it would either fail with an argument/type error
      # or raise (and fail the test) on the very first not-yet-ready
      # attempt. `Kernel.system` is the real, non-raising boolean
      # `system(2)` wrapper with proper redirection support.
      ready = false
      10.times do
        ready = Kernel.system((bin/"ferrite-cli").to_s, "-p", port.to_s, "PING", out: File::NULL, err: File::NULL)
        break if ready

        sleep 1
      end
      assert ready, "ferrite server did not become ready on port #{port} within 10 seconds"

      # Test ping command
      output = shell_output("#{bin}/ferrite-cli -p #{port} PING")
      assert_match "PONG", output

      # Test basic operations
      shell_output("#{bin}/ferrite-cli -p #{port} SET test_key test_value")
      output = shell_output("#{bin}/ferrite-cli -p #{port} GET test_key")
      assert_match "test_value", output

      # Test database size
      output = shell_output("#{bin}/ferrite-cli -p #{port} DBSIZE")
      assert_match "1", output
    ensure
      begin
        Process.kill("TERM", server_pid)
      rescue Errno::ESRCH
        # The child already exited; it still needs to be reaped below.
      ensure
        Process.wait(server_pid)
      end
    end
  end
end
