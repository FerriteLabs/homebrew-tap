# typed: false
# frozen_string_literal: true

# Formula for Ferrite: a Redis-compatible, tiered-storage key-value store
# with agent memory and an optional WASM in-DB function runtime (Forge).
class Ferrite < Formula
  desc "Redis-compatible tiered-storage key-value store with agent memory and WASM"
  homepage "https://ferrite.rs"
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
    regex(/v?(\d+(?:\.\d+)+)/i)
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

    # Install example configuration as default config
    (etc/"ferrite").install "ferrite.example.toml" => "ferrite.toml" if File.exist?("ferrite.example.toml")

    # Install shell completions
    generate_completions_from_executable(bin/"ferrite", "completions")
  end

  # NOTE: brew style flags this as removable (services are assumed to
  # create their own directories), but brew services does not create the
  # parent directory for log_path/error_log_path, so removing this would
  # risk brew services start ferrite failing on a fresh install before
  # var/log/ferrite exists. Kept intentionally; see AUDIT.md.
  def post_install
    # Create data directory
    (var/"lib/ferrite").mkpath

    # Create log directory
    (var/"log/ferrite").mkpath
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

      To start ferrite as a background service:
        brew services start ferrite

      To enable TLS for production deployments:
        ferrite --tls-cert-file /path/to/cert.pem --tls-key-file /path/to/key.pem

      For more information:
        https://ferrite.rs
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

    # Start server in background
    port = free_port
    server_pid = fork do
      exec bin/"ferrite", "--port", port.to_s
    end

    # Readiness polling and every assertion that depends on the server
    # live inside this single begin/ensure so the forked server_pid is
    # *always* terminated and reaped, whether the server never becomes
    # ready, a functional assertion fails, or everything succeeds.
    begin
      # Wait for the server to be ready (retry up to 10 times). Polling
      # uses a quiet `system` call instead of `shell_output`: ferrite-cli
      # exits non-zero on every attempt before the server has bound its
      # port, and shell_output(cmd) asserts a zero exit status by
      # default, so using it here would raise (and fail the test) on the
      # very first retry instead of giving the server a chance to start.
      ready = false
      10.times do
        ready = system(bin/"ferrite-cli", "-p", port.to_s, "PING", out: File::NULL, err: File::NULL)
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
