# Contributing to Ferrite Homebrew Tap

Thank you for your interest in contributing! This repository contains the Homebrew formula for installing Ferrite on macOS and Linux.

## Getting Started

- Familiarize yourself with the [main Ferrite contributing guide](https://github.com/ferritelabs/ferrite/blob/main/CONTRIBUTING.md) for general project standards
- Read the [Homebrew Formula Cookbook](https://docs.brew.sh/Formula-Cookbook)

## How to Contribute

### Reporting Issues

- Use [GitHub Issues](https://github.com/ferritelabs/homebrew-tap/issues) for formula bugs or installation problems
- Include your macOS/Linux version and Homebrew version (`brew --version`)

### Submitting Changes

1. Fork the repository
2. Create a feature branch (`git checkout -b fix/my-change`)
3. Make your changes to `ferrite.rb`
4. Test locally: `brew install --build-from-source ./ferrite.rb`
5. Run audit: `brew audit --strict ferrite.rb`
6. Commit with a clear message and open a Pull Request

## Formula Guidelines

- Pin dependency versions when possible
- Include a `test` block that verifies the binary works
- Support both Intel and Apple Silicon
- Keep the formula self-contained (avoid external scripts during install)

## Commit Message Format

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>: <description>

Types: feat, fix, docs, chore
```

## Code of Conduct

Please be respectful, inclusive, and constructive in all interactions. See the [main project Code of Conduct](https://github.com/ferritelabs/ferrite/blob/main/CONTRIBUTING.md#code-of-conduct).

## License

By contributing, you agree that your contributions will be licensed under Apache-2.0.
