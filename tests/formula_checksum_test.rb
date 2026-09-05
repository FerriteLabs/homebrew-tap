# frozen_string_literal: true

require_relative "test_helper"
require "net/http"
require "digest"
require "uri"

# Verifies that the sha256 recorded in ferrite.rb actually matches the
# real release tarball at the recorded url. This is the single most
# important invariant for a Homebrew formula (it is what protects users
# from a tampered or mismatched download) so it is exercised against the
# real network by default.
#
# This test intentionally does NOT rescue network errors into a skip.
# A network failure during a full/default run (e.g. the CI `audit` job
# in ci.yml, which runs on a network-enabled runner specifically to
# exercise this check) must FAIL the suite, not silently pass as a
# skip - otherwise a flaky or blocked network would let a real checksum
# mismatch slip through undetected. The ONLY sanctioned way to skip
# this test is the explicit fast/offline opt-in below; there is no
# implicit "environment looked offline, so skip" fallback.
#
# Skippable ONLY for explicit fast/offline runs via:
#   tests/run.sh --fast
#   FERRITE_TAP_SKIP_NETWORK=1 ruby tests/formula_checksum_test.rb
class FormulaChecksumTest < Minitest::Test
  MAX_REDIRECTS = 5
  NETWORK_TIMEOUT = 20

  def setup
    @source = FerriteTap.formula_source
  end

  def test_source_sha256_matches_downloaded_tarball
    skip "network-bound checksum test skipped (fast mode)" if FerriteTap.skip_network?

    url_match = @source.match(/^\s*url\s+"([^"]+)"/)
    refute_nil url_match, "could not find a top-level url stanza"
    url = url_match[1]

    sha_match = @source.match(/^\s*sha256\s+"([^"]+)"/)
    refute_nil sha_match, "could not find a top-level source sha256 stanza"
    expected_sha256 = sha_match[1]

    digest = download_and_digest(url)
    assert_equal expected_sha256, digest,
                 "sha256 in ferrite.rb does not match the downloaded tarball at #{url}"
  end

  private

  # Follows redirects manually (GitHub archive urls redirect to
  # codeload.github.com) and streams the body straight into a SHA256
  # digest instead of buffering the whole tarball in memory.
  def download_and_digest(url, redirects_left = MAX_REDIRECTS)
    raise "too many redirects while downloading #{url}" if redirects_left.negative?

    uri = URI.parse(url)
    digest = Digest::SHA256.new

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                         open_timeout: NETWORK_TIMEOUT, read_timeout: NETWORK_TIMEOUT) do |http|
      request = Net::HTTP::Get.new(uri)
      http.request(request) do |response|
        case response
        when Net::HTTPRedirection
          location = response["location"]
          return download_and_digest(location, redirects_left - 1)
        when Net::HTTPSuccess
          response.read_body { |chunk| digest << chunk }
        else
          raise "unexpected HTTP response #{response.code} downloading #{url}"
        end
      end
    end

    digest.hexdigest
  end
end
