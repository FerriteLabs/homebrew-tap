# typed: false
# frozen_string_literal: true

class Ferrite < Formula
  desc "High-performance, tiered-storage key-value store - drop-in Redis replacement with agent memory, WASM functions, and verifiable audit"
  homepage "https://ferrite.rs"
  url "https://github.com/ferritelabs/ferrite/archive/refs/tags/v0.3.0.tar.gz"
  # SHA256 is automatically updated by the update-formula workflow when a new
  # tag is pushed to ferritelabs/ferrite. To compute manually:
  #   curl -sL <url> | shasum -a 256
  # Verify checksum after download: brew fetch --verify-sha ferrite
  #
  # To update: run the update-formula workflow with the new version and SHA256,
  # or trigger a repository_dispatch event from the ferrite release workflow.
  # Placeholder below is replaced by CI on release.
  sha256 "PLACEHOLDER_SOURCE_SHA256_REPLACE_VIA_CI_RELEASE_WORKFLOW_000000000000"
  license "Apache-2.0"

  depends_on "openssl@3"

  head "https://github.com/ferritelabs/ferrite.git", branch: "main"

  livecheck do
    url :stable
    strategy :github_latest
    regex(/v?(\d+(?:\.\d+)+)/i)
  end

  bottle do
    root_url "https://github.com/ferritelabs/homebrew-tap/releases/download/v#{version}"
    # Bottles are built and uploaded by the build-bottles workflow.
    # After a release, run: brew fetch --force ferrite
    # Bottle checksums are updated by the build-bottles CI workflow.
    #
    # ⚠️  Values below are PLACEHOLDERS — CI replaces them when bottles are built.
    # If you see these exact values, bottles have not been built for this version yet.
    # Install from source instead: brew install --build-from-source ferrite
    sha256 cellar: :any_skip_relocation, arm64_sonoma:  "PLACEHOLDER_SHA256_ARM64_SONOMA_REPLACE_VIA_CI_WORKFLOW"
    sha256 cellar: :any_skip_relocation, arm64_ventura: "PLACEHOLDER_SHA256_ARM64_VENTURA_REPLACE_VIA_CI_WORKFLOW"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "PLACEHOLDER_SHA256_ARM64_SEQUOIA_REPLACE_VIA_CI_WORKFLOW"
    sha256 cellar: :any_skip_relocation, sonoma:        "PLACEHOLDER_SHA256_SONOMA_REPLACE_VIA_CI_WORKFLOW_00000"
    sha256 cellar: :any_skip_relocation, ventura:       "PLACEHOLDER_SHA256_VENTURA_REPLACE_VIA_CI_WORKFLOW_0000"
    sha256 cellar: :any_skip_relocation, x86_64_linux:  "PLACEHOLDER_SHA256_X86_64_LINUX_REPLACE_VIA_CI_WORKFLOW"
  end

  depends_on "rust" => :build
  depends_on "pkg-config" => :build
  depends_on "cmake" => :build
  # Runtime dependency for TLS support
  # On macOS, prefer the Homebrew-installed OpenSSL over system LibreSSL
  depends_on "openssl@3" if OS.mac?
  depends_on "openssl@3" if OS.linux?
  uses_from_macos "curl"

  option "with-forge", "Enable Forge WASM in-DB function runtime (ADR-019)"

  # Minimum Rust version: 1.88 (required for async trait and io_uring support)
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
