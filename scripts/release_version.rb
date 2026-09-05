# frozen_string_literal: true

module FerriteTap
  module ReleaseVersion
    STABLE_PATTERN = /\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z/
    EXPECTATION = "a stable release version exactly X.Y.Z (no leading zeroes, prerelease, or build metadata)"

    module_function

    def validate!(version)
      return version if version.is_a?(String) && version.match?(STABLE_PATTERN)

      raise ArgumentError, "#{version.inspect} is not #{EXPECTATION}"
    end

    def archive_url(version)
      "https://github.com/ferritelabs/ferrite/archive/refs/tags/v#{validate!(version)}.tar.gz"
    end

    def release_tag(version)
      "v#{validate!(version)}"
    end

    def formula_branch(version)
      "update-ferrite-#{validate!(version)}"
    end

    def bottle_branch(version)
      "update-ferrite-bottles-#{validate!(version)}"
    end

    def bottle_release_url(version)
      "https://github.com/ferritelabs/homebrew-tap/releases/download/#{release_tag(version)}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    puts FerriteTap::ReleaseVersion.validate!(ARGV.fetch(0))
  rescue ArgumentError, IndexError => e
    warn "::error::#{e.message}"
    exit 1
  end
end
