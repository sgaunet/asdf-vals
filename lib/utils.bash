#!/usr/bin/env bash

# Exit on error, undefined variable, or pipe failure
set -euo pipefail

# ============================================================================
# Configuration Constants
# ============================================================================

# GitHub repository for helmfile/vals
readonly GH_REPO="https://github.com/helmfile/vals"
readonly TOOL_NAME="vals"
readonly TOOL_TEST="vals version"

# Retry configuration for network operations
readonly MAX_RETRIES="${ASDF_VALS_MAX_RETRIES:-3}"
readonly RETRY_DELAY="${ASDF_VALS_RETRY_DELAY:-2}"

# Debug mode - set ASDF_VALS_DEBUG=1 to enable verbose logging
readonly DEBUG="${ASDF_VALS_DEBUG:-0}"

# ============================================================================
# Logging Functions
# ============================================================================

# Print debug messages when debug mode is enabled
# Arguments:
#   $@ - Message to print
debug_log() {
	if [[ "$DEBUG" == "1" ]]; then
		echo "[DEBUG] $*" >&2
	fi
}

# Print error message and exit with status 1
# Arguments:
#   $@ - Error message to display
fail() {
	echo -e "asdf-$TOOL_NAME: ERROR: $*" >&2
	exit 1
}

# Print warning message to stderr
# Arguments:
#   $@ - Warning message to display
warn() {
	echo -e "asdf-$TOOL_NAME: WARNING: $*" >&2
}

# Print info message to stderr
# Arguments:
#   $@ - Info message to display
info() {
	echo -e "asdf-$TOOL_NAME: $*" >&2
}

# ============================================================================
# Network Operations
# ============================================================================

# Build curl options array with authentication if available
# Returns:
#   Array of curl options via global curl_opts variable
build_curl_opts() {
	curl_opts=(-fsSL)

	# Add GitHub API token if available for higher rate limits
	if [[ -n "${GITHUB_API_TOKEN:-}" ]]; then
		debug_log "Using GitHub API token for authentication"
		curl_opts+=(-H "Authorization: token $GITHUB_API_TOKEN")
	fi

	# Add GitHub API version header for stability
	curl_opts+=(-H "Accept: application/vnd.github.v3+json")
}

# Execute curl with retry logic for network resilience
# Arguments:
#   $@ - Arguments to pass to curl
# Returns:
#   0 on success, 1 on failure after all retries
curl_with_retry() {
	local attempt=1
	local exit_code=0

	while [[ $attempt -le $MAX_RETRIES ]]; do
		debug_log "Attempt $attempt of $MAX_RETRIES: curl $*"

		if curl "$@"; then
			return 0
		fi

		exit_code=$?
		warn "Network request failed (attempt $attempt/$MAX_RETRIES)"

		if [[ $attempt -lt $MAX_RETRIES ]]; then
			info "Retrying in ${RETRY_DELAY} seconds..."
			sleep "$RETRY_DELAY"
		fi

		((attempt++))
	done

	return $exit_code
}

# ============================================================================
# Version Management Functions
# ============================================================================

# Sort versions using semantic versioning rules
# Handles versions with pre-release tags (alpha, beta, rc)
# Input: List of versions via stdin
# Output: Sorted versions to stdout
sort_versions() {
	# Transform versions for sorting:
	# - Replace pre-release separators with dots
	# - Add .z prefix to ensure proper ordering
	# - Append original version for final output
	sed 'h; s/[+-]/./g; s/.p\([[:digit:]]\)/.z\1/; s/$/.z/; G; s/\n/ /' |
		LC_ALL=C sort -t. -k 1,1 -k 2,2n -k 3,3n -k 4,4n -k 5,5n |
		awk '{print $2}'
}

# Fetch all available versions from GitHub tags
# Filters out 'v' prefix from version tags
# Output: List of versions to stdout
list_github_tags() {
	local repo_url="$GH_REPO"

	debug_log "Fetching tags from $repo_url"

	if ! git ls-remote --tags --refs "$repo_url" 2>/dev/null; then
		fail "Failed to fetch tags from GitHub. Check your internet connection and GitHub API limits."
	fi | grep -o 'refs/tags/.*' | cut -d/ -f3- | sed 's/^v//'
}

# List all available versions of the tool
# This is the main entry point for version listing
# Output: List of versions to stdout
list_all_versions() {
	list_github_tags
}

# Validate semantic version format
# Arguments:
#   $1 - Version string to validate
# Returns:
#   0 if valid, 1 if invalid
validate_version() {
	local version="$1"

	# Check basic semantic version pattern
	if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?(\+[a-zA-Z0-9.]+)?$ ]]; then
		return 1
	fi

	return 0
}

# ============================================================================
# Platform Detection Functions
# ============================================================================

# Detect the operating system
# Normalizes OS names to lowercase
# Output: OS name (linux, darwin, windows, freebsd, etc.)
get_os() {
	local os
	os="$(uname -s | tr '[:upper:]' '[:lower:]')"

	case "$os" in
	linux*)
		echo "linux"
		;;
	darwin*)
		echo "darwin"
		;;
	msys* | mingw* | cygwin*)
		echo "windows"
		;;
	freebsd*)
		echo "freebsd"
		;;
	openbsd*)
		echo "openbsd"
		;;
	netbsd*)
		echo "netbsd"
		;;
	*)
		echo "$os"
		;;
	esac
}

# Detect the CPU architecture
# Normalizes architecture names to match vals naming conventions
# Output: Architecture name (amd64, arm64, 386, arm, etc.)
get_arch() {
	local arch
	arch="$(uname -m)"

	case "$arch" in
	x86_64 | x64 | amd64)
		echo "amd64"
		;;
	i?86 | x86 | i386)
		echo "386"
		;;
	aarch64 | arm64)
		echo "arm64"
		;;
	armv7* | armv6*)
		echo "arm"
		;;
	arm*)
		# Generic ARM fallback
		echo "arm"
		;;
	ppc64le)
		echo "ppc64le"
		;;
	ppc64)
		echo "ppc64"
		;;
	s390x)
		echo "s390x"
		;;
	riscv64)
		echo "riscv64"
		;;
	*)
		warn "Unknown architecture: $arch"
		echo "$arch"
		;;
	esac
}

# ============================================================================
# Download Functions
# ============================================================================

# Calculate expected checksum filename
# Arguments:
#   $1 - Version
# Returns:
#   Checksum filename
get_checksum_filename() {
	local version="$1"
	echo "vals_${version}_checksums.txt"
}

# Download and verify checksum for a release
# Arguments:
#   $1 - Version
#   $2 - Downloaded file path
# Returns:
#   0 if checksum is valid or unavailable, 1 if invalid
verify_checksum() {
	local version="$1"
	local file_path="$2"
	local checksum_url="$GH_REPO/releases/download/v${version}/vals_${version}_checksums.txt"
	local checksum_file="${file_path}.checksums"
	local filename
	filename="$(basename "$file_path")"

	info "Verifying checksum for $filename..."

	# Download checksum file
	build_curl_opts
	if ! curl_with_retry "${curl_opts[@]}" -o "$checksum_file" "$checksum_url" 2>/dev/null; then
		warn "Checksum file not available for version $version. Skipping verification."
		rm -f "$checksum_file"
		return 0
	fi

	# Extract relevant checksum line
	local expected_checksum
	expected_checksum=$(grep "$filename" "$checksum_file" 2>/dev/null | awk '{print $1}')

	if [[ -z "$expected_checksum" ]]; then
		warn "No checksum found for $filename. Skipping verification."
		rm -f "$checksum_file"
		return 0
	fi

	# Calculate actual checksum
	local actual_checksum
	if command -v sha256sum >/dev/null 2>&1; then
		actual_checksum=$(sha256sum "$file_path" | awk '{print $1}')
	elif command -v shasum >/dev/null 2>&1; then
		actual_checksum=$(shasum -a 256 "$file_path" | awk '{print $1}')
	else
		warn "No SHA256 tool available. Skipping checksum verification."
		rm -f "$checksum_file"
		return 0
	fi

	# Compare checksums
	if [[ "$expected_checksum" != "$actual_checksum" ]]; then
		rm -f "$checksum_file"
		fail "Checksum verification failed for $filename"
	fi

	info "Checksum verified successfully"
	rm -f "$checksum_file"
	return 0
}

# Download a specific release of the tool
# Arguments:
#   $1 - Version to download
#   $2 - Output filename path
# Returns:
#   0 on success, exits on failure
download_release() {
	local version="$1"
	local filename="$2"
	local os arch url

	# Validate version format
	if ! validate_version "$version"; then
		fail "Invalid version format: $version"
	fi

	os="$(get_os)"
	arch="$(get_arch)"

	# Construct download URL
	url="$GH_REPO/releases/download/v${version}/${TOOL_NAME}_${version}_${os}_${arch}.tar.gz"

	info "Downloading $TOOL_NAME release $version for ${os}/${arch}..."
	debug_log "Download URL: $url"

	# Build curl options
	build_curl_opts

	# Add progress bar if not in debug mode
	if [[ "$DEBUG" != "1" ]] && [[ -t 2 ]]; then
		curl_opts+=(--progress-bar)
	fi

	# Download with resume support
	if ! curl_with_retry "${curl_opts[@]}" -C - -o "$filename" "$url"; then
		fail "Could not download $url"
	fi

	# Verify checksum if possible
	verify_checksum "$version" "$filename"

	info "Download completed successfully"
}

# ============================================================================
# Installation Functions
# ============================================================================

# Install a specific version of the tool
# Arguments:
#   $1 - Install type (version, ref, etc.)
#   $2 - Version to install
#   $3 - Installation path
# Returns:
#   0 on success, exits on failure
install_version() {
	local install_type="$1"
	local version="$2"
	local install_path="${3%/bin}/bin"

	# Validate installation type
	if [[ "$install_type" != "version" ]]; then
		fail "asdf-$TOOL_NAME supports release installs only (got: $install_type)"
	fi

	# Validate version
	if ! validate_version "$version"; then
		fail "Invalid version format: $version"
	fi

	debug_log "Installing $TOOL_NAME $version to $install_path"

	(
		# Create installation directory
		mkdir -p "$install_path"

		# Copy downloaded files to installation path
		if [[ ! -d "$ASDF_DOWNLOAD_PATH" ]]; then
			fail "Download directory not found: $ASDF_DOWNLOAD_PATH"
		fi

		cp -r "$ASDF_DOWNLOAD_PATH"/* "$install_path"

		# Verify the tool is executable
		local tool_cmd
		tool_cmd="$(echo "$TOOL_TEST" | cut -d' ' -f1)"

		if [[ ! -f "$install_path/$tool_cmd" ]]; then
			fail "Expected binary not found: $install_path/$tool_cmd"
		fi

		if [[ ! -x "$install_path/$tool_cmd" ]]; then
			debug_log "Setting execute permission on $tool_cmd"
			chmod +x "$install_path/$tool_cmd"
		fi

		# Test the installation
		if ! "$install_path/$tool_cmd" version >/dev/null 2>&1; then
			fail "Installation verification failed. Binary may be incompatible with your system."
		fi

		info "$TOOL_NAME $version installation was successful!"
	) || (
		# Cleanup on failure
		rm -rf "$install_path"
		fail "An error occurred while installing $TOOL_NAME $version."
	)
}

# ============================================================================
# Cleanup Functions
# ============================================================================

# Register cleanup function to run on exit
# This ensures temporary files are removed even on failure
cleanup_on_exit() {
	local exit_code=$?

	if [[ $exit_code -ne 0 ]]; then
		debug_log "Cleaning up after error (exit code: $exit_code)"
		# Add any cleanup operations here
	fi

	return $exit_code
}

# Set up exit trap for cleanup
trap cleanup_on_exit EXIT

# ============================================================================
# Initialization
# ============================================================================

# Validate environment on sourcing
if [[ -z "${BASH_VERSION:-}" ]]; then
	fail "This plugin requires bash. Please ensure bash is available."
fi

# Log environment information in debug mode
if [[ "$DEBUG" == "1" ]]; then
	debug_log "asdf-$TOOL_NAME initialized"
	debug_log "OS: $(get_os)"
	debug_log "Architecture: $(get_arch)"
	debug_log "Max retries: $MAX_RETRIES"
	debug_log "Retry delay: ${RETRY_DELAY}s"
fi
