# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "rubygems/package"
require "zlib"

module FerriteTap
  module BottleArtifactValidator
    module_function

    def validate(json_path:, tarball_path:, version:, expected_tag:, expected_root_url:)
      data = JSON.parse(File.read(json_path))
      raise "#{json_path} must describe exactly one formula" unless data.length == 1

      formula = data.values.first
      bottle = formula.fetch("bottle")
      tags = bottle.fetch("tags")
      raise "#{json_path} must describe exactly one bottle tag" unless tags.keys == [expected_tag]
      unless bottle["root_url"] == expected_root_url
        raise "#{json_path} has root_url #{bottle["root_url"].inspect}, expected #{expected_root_url}"
      end

      sha256 = tags.fetch(expected_tag).fetch("sha256")
      unless sha256.match?(/\A[0-9a-f]{64}\z/)
        raise "#{json_path} has an invalid bottle checksum"
      end

      actual_sha256 = Digest::SHA256.file(tarball_path).hexdigest
      unless sha256 == actual_sha256
        raise "#{json_path} checksum #{sha256} does not match bottle artifact " \
              "#{tarball_path} checksum #{actual_sha256}"
      end

      entries = []
      Zlib::GzipReader.open(tarball_path) do |gzip|
        Gem::Package::TarReader.new(gzip) do |archive|
          archive.each do |entry|
            path = Pathname.new(entry.full_name)
            if path.absolute? || path.each_filename.any? { |component| component == ".." }
              raise "#{tarball_path} contains an unsafe archive path: #{entry.full_name}"
            end
            entries << entry.full_name
          end
        end
      end
      unless entries.any? { |entry| entry.end_with?("/bin/ferrite") }
        raise "#{tarball_path} does not contain the Ferrite server binary"
      end
      unless entries.any? { |entry| entry.end_with?("/INSTALL_RECEIPT.json") }
        raise "#{tarball_path} does not contain a Homebrew installation receipt"
      end

      pkg_version = formula.fetch("formula").fetch("pkg_version")
      unless pkg_version == version
        raise "#{json_path} has package version #{pkg_version.inspect}, expected #{version}"
      end

      true
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    json_path, tarball_path, version, expected_tag, expected_root_url = ARGV
    FerriteTap::BottleArtifactValidator.validate(
      json_path: json_path,
      tarball_path: tarball_path,
      version: version,
      expected_tag: expected_tag,
      expected_root_url: expected_root_url,
    )
  rescue Gem::Package::TarInvalidError, KeyError, Errno::ENOENT, JSON::ParserError,
         RuntimeError, TypeError, Zlib::GzipFile::Error => e
    warn "::error::#{e.message}"
    exit 1
  end
end
