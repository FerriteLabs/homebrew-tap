# frozen_string_literal: true

require_relative "test_helper"
require_relative "../scripts/validate_bottle_artifact"
require "digest"
require "rubygems/package"
require "zlib"

class BottleArtifactIntegrityTest < Minitest::Test
  VERSION = "0.5.0"
  TAG = "arm64_sequoia"
  ROOT_URL = "https://github.com/ferritelabs/homebrew-tap/releases/download/v0.5.0"

  def test_accepts_json_checksum_matching_real_bottle_bytes
    FerriteTap.with_temp_dir("bottle-integrity-") do |directory|
      json_path, tarball_path = write_artifacts(directory, "real bottle bytes")

      assert FerriteTap::BottleArtifactValidator.validate(
        json_path: json_path,
        tarball_path: tarball_path,
        version: VERSION,
        expected_tag: TAG,
        expected_root_url: ROOT_URL,
      )
    end
  end

  def test_rejects_json_checksum_not_matching_bottle_bytes
    FerriteTap.with_temp_dir("bottle-integrity-") do |directory|
      json_path, tarball_path = write_artifacts(directory, "real bottle bytes")
      File.write(tarball_path, "tampered bottle bytes")

      error = assert_raises(RuntimeError) do
        FerriteTap::BottleArtifactValidator.validate(
          json_path: json_path,
          tarball_path: tarball_path,
          version: VERSION,
          expected_tag: TAG,
          expected_root_url: ROOT_URL,
        )
      end

      assert_match(/does not match bottle artifact/, error.message)
    end
  end

  def test_rejects_matching_checksum_for_non_archive_bytes
    FerriteTap.with_temp_dir("bottle-integrity-") do |directory|
      json_path, tarball_path = write_artifacts(directory, "not a bottle archive", archive: false)

      assert_raises(Zlib::GzipFile::Error) do
        validate(json_path, tarball_path)
      end
    end
  end

  def test_rejects_archive_without_required_bottle_contents
    FerriteTap.with_temp_dir("bottle-integrity-") do |directory|
      json_path, tarball_path = write_artifacts(
        directory,
        "placeholder",
        entries: {"ferrite/#{VERSION}/README.md" => "not installable"},
      )

      error = assert_raises(RuntimeError) do
        validate(json_path, tarball_path)
      end
      assert_match(/does not contain the Ferrite server binary/, error.message)
    end
  end

  private

  def validate(json_path, tarball_path)
    FerriteTap::BottleArtifactValidator.validate(
      json_path: json_path,
      tarball_path: tarball_path,
      version: VERSION,
      expected_tag: TAG,
      expected_root_url: ROOT_URL,
    )
  end

  def write_artifacts(directory, contents, archive: true, entries: nil)
    tarball_path = File.join(directory, "ferrite--#{VERSION}.#{TAG}.bottle.tar.gz")
    json_path = File.join(directory, "ferrite--#{VERSION}.#{TAG}.bottle.json")
    if archive
      bottle_entries = entries || {
        "ferrite/#{VERSION}/bin/ferrite" => contents,
        "ferrite/#{VERSION}/INSTALL_RECEIPT.json" => "{}",
      }
      write_tar_gzip(tarball_path, bottle_entries)
    else
      File.write(tarball_path, contents)
    end
    sha256 = Digest::SHA256.file(tarball_path).hexdigest
    File.write(json_path, JSON.pretty_generate(
      "ferrite" => {
        "formula" => {
          "pkg_version" => VERSION,
          "path" => "Library/Taps/ferritelabs/homebrew-ci/ferrite.rb",
        },
        "bottle" => {
          "root_url" => ROOT_URL,
          "tags" => {
            TAG => {
              "cellar" => ":any_skip_relocation",
              "sha256" => sha256,
            },
          },
        },
      },
    ))
    [json_path, tarball_path]
  end

  def write_tar_gzip(path, entries)
    Zlib::GzipWriter.open(path) do |gzip|
      Gem::Package::TarWriter.new(gzip) do |archive|
        entries.each do |name, contents|
          archive.add_file_simple(name, 0o755, contents.bytesize) do |file|
            file.write(contents)
          end
        end
      end
    end
  end
end
