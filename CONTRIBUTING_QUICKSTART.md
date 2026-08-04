# Contributing Quickstart — homebrew-tap

Get up and running in 5 minutes.

## Prerequisites

- [Homebrew](https://brew.sh/) (macOS or Linux)
- [Ruby](https://www.ruby-lang.org/) (comes with macOS, or install via Homebrew)

## Fork & Clone

```bash
gh repo fork ferritelabs/homebrew-tap --clone
cd homebrew-tap
```

## Test the Formula Locally

```bash
# Tap this checkout under the same deterministic name CI uses
brew tap ferritelabs/ci "$(pwd)"

# Audit and style the tap-qualified formula
brew audit --strict --online ferritelabs/ci/ferrite
brew style ferritelabs/ci/ferrite

# Install from the local tap
brew install --build-from-source ferritelabs/ci/ferrite

# Run the built-in test
brew test ferritelabs/ci/ferrite

# Uninstall and remove the local tap
brew uninstall ferritelabs/ci/ferrite
brew untap ferritelabs/ci
```

## What to Work On

- Look for [good first issues](https://github.com/ferritelabs/homebrew-tap/labels/good%20first%20issue)
- Update the formula for new Ferrite releases
- Add new dependencies or build options
- Improve the test block in `ferrite.rb`

## Formula Structure

The formula in `ferrite.rb` handles:
- **Dependencies**: Rust 1.80+, pkg-config, cmake, OpenSSL
- **Build**: `cargo install` with `tls` and `cli` features
- **Install**: Server binary + CLI + shell completions
- **Service**: Homebrew service integration (`brew services start ferrite`)
- **Test**: PING, SET/GET, DBSIZE verification

## Submitting Changes

1. Create a feature branch: `git checkout -b my-change`
2. Make your changes to `ferrite.rb`
3. Tap the checkout and run the audit/style/install commands above
4. Commit using [Conventional Commits](https://www.conventionalcommits.org/)
5. Push and open a PR

See [CONTRIBUTING.md](CONTRIBUTING.md) for full guidelines.

---

**Part of [FerriteLabs](https://github.com/ferritelabs)** — see the [core engine](https://github.com/ferritelabs/ferrite) for the full project.
