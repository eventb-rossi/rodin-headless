#!/usr/bin/env bash
# Resolve Rodin version and platform tarball name from SourceForge.
#
# Usage:
#   ./rodin-version.sh                     # latest stable
#   ./rodin-version.sh latest              # same
#   ./rodin-version.sh latest-rc           # latest release candidate
#   ./rodin-version.sh 3.8                 # specific version
#   ./rodin-version.sh 3.9 <tarball>       # pinned tarball, no scraping
#
# The tarball matches the host platform; RODIN_PLATFORM (linux-x86_64,
# macos-x86_64, macos-aarch64) overrides the detection.
#
# Output (eval-friendly):
#   export RODIN_VERSION='3.10'
#   export RODIN_TARBALL='rodin-3.10.0...-linux.gtk.x86_64.tar.gz'
#   export RODIN_URL='https://sourceforge.net/.../download'

set -euo pipefail

# Resolve the directory holding the shared library and helper scripts.
# Order: a RODIN_HEADLESS_LIBEXEC override; the build-time sentinel that
# `make install` rewrites to $libexecdir/rodin-headless; otherwise the
# script's own directory — the flat checkout and the Docker image keep
# every script beside the library. A sentinel left literal (source tree)
# or pointing nowhere falls back to dirname "$0".
: "${RODIN_HEADLESS_LIBEXEC:=__RODIN_HEADLESS_LIBEXEC__}"
if [ ! -f "$RODIN_HEADLESS_LIBEXEC/rodin-headless-lib.sh" ]; then
    RODIN_HEADLESS_LIBEXEC="$(cd "$(dirname "$0")" && pwd)"
fi
if [ ! -f "$RODIN_HEADLESS_LIBEXEC/rodin-headless-lib.sh" ]; then
    echo "ERROR: cannot find rodin-headless-lib.sh in $RODIN_HEADLESS_LIBEXEC" >&2
    echo "       Set RODIN_HEADLESS_LIBEXEC to the directory that holds it (the package's libexec/rodin-headless)." >&2
    exit 1
fi
# shellcheck source=rodin-headless-lib.sh
. "$RODIN_HEADLESS_LIBEXEC/rodin-headless-lib.sh"

SF_BASE="https://sourceforge.net/projects/rodin-b-sharp/files/Core_Rodin_Platform"
SAFE_PATTERN='^[a-zA-Z0-9._-]+$'

MODE="${1:-latest}"
TARBALL_OVERRIDE="${2:-}"

PLATFORM="$(rodin_platform)"
case "$PLATFORM" in
    linux-x86_64)  TARBALL_SUFFIX='linux\.gtk\.x86_64' ;;
    macos-x86_64)  TARBALL_SUFFIX='macosx\.cocoa\.x86_64' ;;
    macos-aarch64) TARBALL_SUFFIX='macosx\.cocoa\.aarch64' ;;
esac

latest_by_numbers() {
    awk '{ key = $0; gsub(/[^0-9]+/, ".", key); print key "\t" $0 }' \
        | sort -t . -k1,1n -k2,2n -k3,3n -k4,4n \
        | tail -1 \
        | cut -f2-
}

case "$MODE" in
    latest)
        listing=$(curl -fsSL --retry 2 --max-time 30 "$SF_BASE/")
        versions=$(printf '%s\n' "$listing" \
            | grep -Eo '"name":"[^"]+"' \
            | cut -d'"' -f4 || true)
        candidates=$(printf '%s\n' "$versions" | grep -E '^[0-9]+(\.[0-9]+)*$' || true)
        VERSION=$(printf '%s\n' "$candidates" | latest_by_numbers)
        ;;
    latest-rc)
        listing=$(curl -fsSL --retry 2 --max-time 30 "$SF_BASE/")
        versions=$(printf '%s\n' "$listing" \
            | grep -Eo '"name":"[^"]+"' \
            | cut -d'"' -f4 || true)
        candidates=$(printf '%s\n' "$versions" | grep -E '^[0-9]+(\.[0-9]+)*-RC[0-9]*$' || true)
        VERSION=$(printf '%s\n' "$candidates" | latest_by_numbers)
        ;;
    *)
        VERSION="$MODE"
        ;;
esac

if [ -z "$VERSION" ]; then
    echo "ERROR: Could not detect Rodin $MODE version from SourceForge" >&2
    exit 1
fi

# Resolve the platform tarball filename (skipped when pinned)
if [ -n "$TARBALL_OVERRIDE" ]; then
    TARBALL="$TARBALL_OVERRIDE"
else
    listing=$(curl -fsSL --retry 2 --max-time 30 "$SF_BASE/$VERSION/")
    TARBALL=$(printf '%s\n' "$listing" \
        | grep -Eo "rodin-[^\"]*-$TARBALL_SUFFIX\\.tar\\.gz" | head -1 || true)
fi

if [ -z "$TARBALL" ]; then
    echo "ERROR: Could not find $PLATFORM tarball for Rodin $VERSION" >&2
    if [ "$PLATFORM" = macos-aarch64 ]; then
        echo "Rodin ships macOS arm64 builds from 3.10 on (3.9 is x86_64-only); use --rodin-version latest or 3.10+" >&2
    fi
    exit 1
fi

# Validate scraped values before emitting for eval safety
if ! [[ "$VERSION" =~ $SAFE_PATTERN ]] || ! [[ "$TARBALL" =~ $SAFE_PATTERN ]]; then
    echo "ERROR: Unexpected characters in version='$VERSION' or tarball='$TARBALL'" >&2
    exit 1
fi

echo "export RODIN_VERSION='$VERSION'"
echo "export RODIN_TARBALL='$TARBALL'"
echo "export RODIN_URL='$SF_BASE/$VERSION/$TARBALL/download'"
