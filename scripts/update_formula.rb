# frozen_string_literal: true

require "json"
require "tempfile"
require "time"
require_relative "release_version"

module FerriteTap
  module FormulaUpdater
    BOTTLE_BLOCK = /^  bottle do\n.*?^  end\n/m
    SOURCE_URL = /^(\s{2}url\s+)"[^"]+"/
    SOURCE_SHA256 = /^(\s{2}sha256\s+)"[^"]+"/

    module_function

    def update(formula:, version:, sha256:, archive_url:)
      validate_inputs!(version, sha256, archive_url)

      updated = formula.sub(BOTTLE_BLOCK, "")
      if updated.match?(BOTTLE_BLOCK)
        raise "formula contains more than one bottle block"
      end

      updated_url = updated.sub(SOURCE_URL) { "#{Regexp.last_match(1)}\"#{archive_url}\"" }
      raise "failed to update source url" if updated_url == updated

      updated_sha256 = updated_url.sub(SOURCE_SHA256) do
        "#{Regexp.last_match(1)}\"#{sha256}\""
      end
      raise "failed to update source sha256" if updated_sha256 == updated_url
      raise "bottle metadata survived formula update" if updated_sha256.match?(BOTTLE_BLOCK)

      updated_sha256
    end

    def metadata(version:, sha256:, archive_url:)
      validate_inputs!(version, sha256, archive_url)

      {
        "version" => version,
        "sha256" => sha256,
        "url" => archive_url,
        "updated_at" => Time.now.utc.iso8601,
        "updated_by" => "update-formula.yml",
      }
    end

    def write(path, content)
      path = File.expand_path(path)
      directory = File.dirname(path)
      mode = File.stat(path).mode & 0o7777

      Tempfile.create([".#{File.basename(path)}", ".tmp"], directory) do |file|
        file.write(content)
        file.flush
        file.fsync
        File.chmod(mode, file.path)
        File.rename(file.path, path)
      end
    end

    def validate_inputs!(version, sha256, archive_url)
      ReleaseVersion.validate!(version)
      expected_url = ReleaseVersion.archive_url(version)
      raise "archive url does not match version #{version}" unless archive_url == expected_url
      raise "sha256 must be 64 lowercase hexadecimal characters" unless sha256.match?(/\A[0-9a-f]{64}\z/)
    end
    private_class_method :validate_inputs!
  end
end

if $PROGRAM_NAME == __FILE__
  version = ENV.fetch("VERSION")
  sha256 = ENV.fetch("SHA256")
  archive_url = ENV.fetch("ARCHIVE_URL")
  formula_path = ARGV.fetch(0, "ferrite.rb")
  metadata_path = ARGV.fetch(1, "release-metadata.json")

  formula = File.read(formula_path)
  updated_formula = FerriteTap::FormulaUpdater.update(
    formula: formula,
    version: version,
    sha256: sha256,
    archive_url: archive_url,
  )
  updated_metadata = FerriteTap::FormulaUpdater.metadata(
    version: version,
    sha256: sha256,
    archive_url: archive_url,
  )

  FerriteTap::FormulaUpdater.write(formula_path, updated_formula)
  FerriteTap::FormulaUpdater.write(metadata_path, JSON.pretty_generate(updated_metadata) + "\n")
  puts "Updated #{formula_path} and #{metadata_path} to v#{version} (#{sha256})"
end
