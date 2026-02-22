# typed: false
# frozen_string_literal: true

class Ferrite < Formula
  desc "High-performance, tiered-storage key-value store - drop-in Redis replacement"
  homepage "https://github.com/ferritelabs/ferrite"
  url "https://github.com/ferritelabs/ferrite/archive/refs/tags/v0.2.0.tar.gz"
  # SHA256 is automatically updated by the update-formula workflow when a new
  # tag is pushed to ferritelabs/ferrite. To compute manually:
  #   curl -sL <url> | shasum -a 256
  # The placeholder below is replaced by CI on first release.
  sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  license "Apache-2.0"
  head "https://github.com/ferritelabs/ferrite.git", branch: "main"

  livecheck do
    url :stable
    strategy :github_latest
  end

  bottle do
    root_url "https://github.com/ferritelabs/homebrew-tap/releases/download/v#{version}"
    # Bottles are built and uploaded by the build-bottles workflow.
    # After a release, run: brew fetch --force ferrite
    # sha256 cellar: :any_skip_relocation, arm64_sonoma: "PLACEHOLDER"
    # sha256 cellar: :any_skip_relocation, sonoma:       "PLACEHOLDER"
    # sha256 cellar: :any_skip_relocation, x86_64_linux: "PLACEHOLDER"
  end

  depends_on "rust" => :build
  depends_on "pkg-config" => :build
  on_linux do
    depends_on "openssl@3"
  end

  def install
    system "cargo", "install", *std_cargo_args

    # Install CLI tools
    system "cargo", "install", *std_cargo_args(path: "."), "--bin", "ferrite-cli"

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
