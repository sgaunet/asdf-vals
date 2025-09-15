# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview
This is an asdf plugin for Vals (helmfile/vals), a tool for managing configuration values and secrets from multiple sources. The plugin follows asdf plugin conventions to manage Vals installations.

## Architecture
The plugin consists of three main components:
1. **bin/** - Entry points for asdf operations (list-all, download, install, latest-stable)
2. **lib/utils.bash** - Core functionality shared across scripts including GitHub API interactions, version management, and platform detection
3. **scripts/** - Development tools for linting and formatting

Key architectural patterns:
- All bin scripts source `lib/utils.bash` for shared functionality
- Downloads are fetched from GitHub releases at `helmfile/vals`
- Platform detection handles Linux/macOS and various architectures (amd64, arm64, 386, arm)
- Version tags are fetched directly from GitHub and stripped of 'v' prefix

## Development Commands

### Testing
```bash
# Test the plugin locally
asdf plugin test vals https://github.com/sgaunet/asdf-vals "vals version"
```

### Linting
```bash
# Run shellcheck and shfmt checks
./scripts/lint.bash
```

### Formatting
```bash
# Auto-format bash scripts
./scripts/format.bash
```

## Key Implementation Details
- The plugin only supports version installs (not ref or path installs)
- Downloads are extracted to a temporary directory first, then only the `vals` binary is moved to the install path
- GitHub API token can be provided via `GITHUB_API_TOKEN` environment variable for rate limiting
- Version sorting handles semantic versioning with special characters
- Comprehensive error handling with retry logic for network operations
- Checksum verification for downloaded files when available
- Debug mode available via `ASDF_VALS_DEBUG=1` for troubleshooting
- Optional scripts provide environment setup (`exec-env`) and help documentation
- Support for multiple platforms including Linux, macOS, Windows (WSL), and BSD variants