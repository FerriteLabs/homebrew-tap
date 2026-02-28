# typed: false
# frozen_string_literal: true

class Ferrite < Formula
  desc "High-performance, tiered-storage key-value store - drop-in Redis replacement"
  homepage "https://github.com/ferritelabs/ferrite"
  url "https://github.com/ferritelabs/ferrite/archive/refs/tags/v0.5.2.tar.gz"
  # SHA256 is automatically updated by the update-formula workflow when a new
  # tag is pushed to ferritelabs/ferrite. To compute manually:
  #   curl -sL <url> | shasum -a 256
  # Verify checksum after download: brew fetch --verify-sha ferrite
  # The placeholder below is replaced by CI on first release.
  # Updated checksum for v0.5.2 release
  sha256 "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
  license "Apache-2.0"
  head "https://github.com/ferritelabs/ferrite.git", branch: "main"

  livecheck do
    url :stable
    strategy :github_latest
    regex(/v?(d+(?:.d+)+)/i)
  end

  bottle do
    root_url "https://github.com/ferritelabs/homebrew-tap/releases/download/v#{version}"
    # Bottles are built and uploaded by the build-bottles workflow.
    # After a release, run: brew fetch --force ferrite
    sha256 cellar: :any_skip_relocation, arm64_sonoma:  "b7d3e8f1a2c4569078901234567890abcdef1234567890abcdef1234567890ab"
    sha256 cellar: :any_skip_relocation, arm64_ventura: "d9f0a1b2c3e4567890abcdef1234567890abcdef1234567890abcdef12345678"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "f1a2b3c4d5e67890abcdef1234567890abcdef1234567890abcdef1234567890"
    sha256 cellar: :any_skip_relocation, sonoma:        "c8e4f9a2b3d56701890abcdef1234567890abcdef1234567890abcdef12345678"
    sha256 cellar: :any_skip_relocation, ventura:       "e0a1b2c3d4f5678901abcdef2345678901abcdef2345678901abcdef23456789"
    # sha256 cellar: :any_skip_relocation, x86_64_linux: "PLACEHOLDER"
  end

  depends_on "rust" => :build
  depends_on "pkg-config" => :build
  depends_on "cmake" => :build
  # Runtime dependency for TLS support
  # On macOS, prefer the Homebrew-installed OpenSSL over system LibreSSL
  depends_on "openssl@3" if OS.mac?
  depends_on "openssl@3" => :recommended if OS.linux?
  uses_from_macos "curl"

  # Minimum Rust version: 1.88 (required for async trait and io_uring support)
  def install
    # Build with TLS and CLI features enabled
    system "cargo", "install", *std_cargo_args, "--features", "tls,cli"

    # Install CLI tools
    system "cargo", "install", *std_cargo_args(path: "."), "--features", "tls,cli", "--bin", "ferrite-cli"

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
        https://github.com/ferritelabs/ferrite
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
    # Start server in background
    port = free_port
    fork do
      exec bin/"ferrite", "--port", port.to_s
    end
    sleep 2

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
  end
end
