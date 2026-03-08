# Changelog

All notable changes to homebrew-tap will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/ferritelabs/homebrew-tap/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/ferritelabs/homebrew-tap/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ferritelabs/homebrew-tap/releases/tag/v0.1.0

