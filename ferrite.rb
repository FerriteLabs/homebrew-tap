# typed: false
# frozen_string_literal: true

class Ferrite < Formula
  desc "High-performance, tiered-storage key-value store - drop-in Redis replacement with agent memory, WASM functions, and verifiable audit"
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

  depends_on "rust" => :build
  depends_on "pkg-config" => :build
  depends_on "cmake" => :build
  # Runtime dependency for TLS support on every supported platform.
  # On macOS, prefer the Homebrew-installed OpenSSL over system LibreSSL.
  depends_on "openssl@3"
  uses_from_macos "curl"

  option "with-forge", "Enable Forge WASM in-DB function runtime (ADR-019)"

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
    if File.exist?("ferrite.example.toml")
      (etc/"ferrite").install "ferrite.example.toml" => "ferrite.toml"
    end

    # Install shell completions
    generate_completions_from_executable(bin/"ferrite", "completions")
  end

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

    # Wait for server to be ready (retry up to 10 times)
    10.times do
      break if shell_output("#{bin}/ferrite-cli -p #{port} PING 2>&1", 0).include?("PONG")

      sleep 1
    end

    begin
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
      Process.kill("TERM", server_pid)
      Process.wait(server_pid)
    end
  end
end
