# Changelog

All notable changes to homebrew-tap will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - Planned for Ferrite 0.5.0

### Changed

- Use the stable core GitHub repository as the formula homepage and the `ferrite-docs` GitHub repository for documentation until a hosted documentation endpoint is deployed and verified.
- Generate the first Homebrew configuration with the installed `ferrite init` command, preserving existing user configuration on upgrades.
- Generate configuration through a same-directory temporary file, replace stale embedded documentation URLs, and atomically rename only after successful validation.
- Standardized public installation instructions on `brew install ferritelabs/tap/ferrite`.
- Prepared the release workflows and metadata for Ferrite 0.5.0 while keeping the live formula on 0.4.0 until the upstream `v0.5.0` tag and canonical checksum exist.
- Documented and strengthened the tag, source-checksum, and bottle-artifact gates used before real bottle metadata can be published.
- Validate bottle archives and required contents, then reinstall and test each locally produced bottle before upload.

### Fixed

- Replaced the placeholder source `url`/`sha256` in `ferrite.rb` with the
  real v0.4.0 tarball location and verified checksum (the previous
  0.4.0 entry below updated the description and `--with-forge` option,
  but left the source stanza pointed at v0.3.0 with a placeholder
  checksum, so installs were broken until this fix).
- Removed the placeholder `bottle do` block entirely; no real bottle
  metadata exists yet, so `brew install ferrite` now builds from source
  instead of attempting to fetch an unresolvable bottle artifact.
- Removed the duplicate unconditional `depends_on "openssl@3"` that
  preceded the OS-guarded declarations.

## [0.4.0] - 2026-04-20

### Changed

- Bumped formula to Ferrite v0.4.0
- Updated description to mention agent memory, WASM functions, and verifiable audit
- Added `--with-forge` option to enable Forge WASM in-DB function runtime (`forge-runtime` feature)
- Extended install logic to conditionally include `forge-runtime` feature when `--with-forge` is passed

## [0.3.0] - 2026-03-09

### Changed
- Bumped formula to Ferrite v0.3.0

## [0.2.0] - 2026-02-28

### Changed
- Bumped formula to Ferrite v0.2.0
- Added openssl@3 as runtime dependency on all platforms
- Enabled TLS and CLI cargo features by default

### Fixed
- Corrected sha256 checksum for release tarball
- Updated bottle hashes for macOS Sonoma arm64

## [0.1.0] - 2025-01-23

### Added
- Initial Homebrew formula for Ferrite v0.1.0
- Automated bottle building workflow for macOS (arm64, x86_64) and Linux
- Formula update workflow triggered by upstream releases
- CI workflow for formula validation
- GitHub issue and PR templates
- EditorConfig for consistent formatting
- Gitleaks secret scanning in CI workflow

[Unreleased]: https://github.com/ferritelabs/homebrew-tap/compare/v0.4.1...HEAD
[0.4.0]: https://github.com/ferritelabs/homebrew-tap/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/ferritelabs/homebrew-tap/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/ferritelabs/homebrew-tap/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ferritelabs/homebrew-tap/releases/tag/v0.1.0
