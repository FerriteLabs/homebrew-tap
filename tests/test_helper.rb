# frozen_string_literal: true

# Shared setup for the dependency-free repo test suite.
#
# Only Ruby standard library is used (minitest, yaml, net/http, digest,
# open3) so these tests run with the system Ruby and require no Bundler,
# gems, or Homebrew installation.

require "minitest/autorun"
require "pathname"
require "json"
require "fileutils"
require "tmpdir"
require_relative "../scripts/release_version"

module FerriteTap
  ROOT = Pathname.new(File.expand_path("..", __dir__))
  FORMULA_PATH = ROOT + "ferrite.rb"
  RELEASE_METADATA_PATH = ROOT + "release-metadata.json"
  WORKFLOWS_DIR = ROOT + ".github" + "workflows"

  # Network-bound assertions (e.g. downloading the release tarball to
  # verify its checksum) can be skipped for a fast, offline test run.
  #
  #   tests/run.sh --fast
  #   FERRITE_TAP_SKIP_NETWORK=1 tests/run.sh
  def self.skip_network?
    value = ENV["FERRITE_TAP_SKIP_NETWORK"].to_s.strip.downcase
    %w[1 true yes].include?(value)
  end

  def self.formula_source
    FORMULA_PATH.read
  end

  def self.release_metadata
    metadata = JSON.parse(RELEASE_METADATA_PATH.read)
    ReleaseVersion.validate!(metadata.fetch("version"))
    metadata
  end

  def self.with_temp_dir(prefix = "fixture-")
    workspace = ROOT + ".test-workspaces"
    workspace.mkpath
    Dir.mktmpdir(prefix, workspace.to_s) { |directory| yield directory }
  ensure
    FileUtils.rmdir(workspace) if workspace&.directory? && workspace.children.empty?
  end
end
