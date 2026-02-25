# Homebrew Tap for Ferrite

[![CI](https://github.com/ferritelabs/homebrew-tap/actions/workflows/ci.yml/badge.svg)](https://github.com/ferritelabs/homebrew-tap/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

This directory contains the Homebrew formula for installing Ferrite on macOS and Linux.

## Installation

### From Official Tap (Recommended)

Once published, you can install Ferrite using:

```bash
# Add the tap
brew tap ferritelabs/ferrite

# Install Ferrite
brew install ferrite
```

### Prebuilt Release Script

For CI or local installs without Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/ferritelabs/ferrite/main/scripts/install.sh | bash
```

Set `FERRITE_INSTALL_DIR` to customize the install location.

### From Local Formula

For development or testing, install directly from this formula:

```bash
brew install --build-from-source ./homebrew/ferrite.rb
```

## Usage

After installation:

```bash
# Start the server
ferrite

# Start with custom config
ferrite --config /usr/local/etc/ferrite/ferrite.toml

# Connect with CLI
ferrite-cli

# Start as background service
brew services start ferrite
```

## First-time Setup

If this is your first time installing Ferrite, note the following caveats:

1. **Default port**: Ferrite listens on port 6379 by default, the same as Redis. If you have Redis running, stop it first or configure Ferrite to use a different port.
2. **Data directory**: Ferrite stores its data in `$(brew --prefix)/var/lib/ferrite/`. Ensure this directory has adequate disk space for your workload.
3. **Configuration**: A default configuration file is placed at `$(brew --prefix)/etc/ferrite/ferrite.toml`. Review and customize it before running in production.

## Service Management

```bash
# Start Ferrite service
brew services start ferrite

# Stop Ferrite service
brew services stop ferrite

# Restart Ferrite service
brew services restart ferrite

# Check service status
brew services list
```

## Directories

- **Binary**: `/usr/local/bin/ferrite` (Intel) or `/opt/homebrew/bin/ferrite` (Apple Silicon)
- **Config**: `/usr/local/etc/ferrite/` or `/opt/homebrew/etc/ferrite/`
- **Data**: `/usr/local/var/lib/ferrite/` or `/opt/homebrew/var/lib/ferrite/`
- **Logs**: `/usr/local/var/log/ferrite/` or `/opt/homebrew/var/log/ferrite/`

## Publishing to a Tap

To create your own tap:

1. Create a new GitHub repository named `homebrew-ferrite`
2. Add the formula: `Formula/ferrite.rb`
3. Update the SHA256 hash for the release tarball:
   ```bash
   curl -sL https://github.com/ferritelabs/ferrite/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256
   ```

## Updating the Formula

When releasing a new version:

1. Update the `url` with the new version tag
2. Update the `sha256` hash
3. Test the formula: `brew install --build-from-source ferrite.rb`
4. Submit a PR or push to your tap

## Submitting to homebrew-core

For wider distribution, submit to the official homebrew-core repository:

1. Ensure the project meets [Homebrew's criteria](https://docs.brew.sh/Acceptable-Formulae)
2. Fork [homebrew-core](https://github.com/Homebrew/homebrew-core)
3. Add the formula to `Formula/f/ferrite.rb`
4. Run `brew audit --new ferrite`
5. Submit a pull request

## Troubleshooting

### Build failures

If Rust is not found:
```bash
brew install rust
```

### Permission issues

Ensure Homebrew directories are writable:
```bash
sudo chown -R $(whoami) $(brew --prefix)/*
```

### Service not starting

Check logs:
```bash
cat /usr/local/var/log/ferrite/ferrite.log
cat /usr/local/var/log/ferrite/ferrite.error.log
```

### Port already in use

If port 6379 is already occupied (e.g., by Redis):
```bash
# Check what is using the port
lsof -i :6379

# Start Ferrite on an alternate port
ferrite --port 6380
```

### Apple Silicon (M1/M2/M3) issues

Ensure you are using a native ARM build:
```bash
brew reinstall ferrite
file $(which ferrite)   # Should show "arm64"
```

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

Apache-2.0
