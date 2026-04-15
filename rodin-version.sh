#!/usr/bin/env bash
# Resolve Rodin version and Linux tarball name from SourceForge.
#
# Usage:
#   ./rodin-version.sh              # latest stable
#   ./rodin-version.sh latest       # same
#   ./rodin-version.sh latest-rc    # latest release candidate
#   ./rodin-version.sh 3.8          # specific version
#
# Output (eval-friendly):
#   export RODIN_VERSION='3.9'
#   export RODIN_TARBALL='rodin-3.9.0...-linux.gtk.x86_64.tar.gz'
#   export RODIN_URL='https://sourceforge.net/.../download'

set -euo pipefail

SF_BASE="https://sourceforge.net/projects/rodin-b-sharp/files/Core_Rodin_Platform"
SAFE_PATTERN='^[a-zA-Z0-9._-]+$'

MODE="${1:-latest}"

case "$MODE" in
    latest)
        versions=$(curl -fsSL --retry 2 --max-time 30 "$SF_BASE/" \
            | grep -oP '"name":"\K[^"]+')
        VERSION=$(echo "$versions" | grep -xP '[0-9]+(\.[0-9]+)*' | sort -V | tail -1)
        ;;
    latest-rc)
        versions=$(curl -fsSL --retry 2 --max-time 30 "$SF_BASE/" \
            | grep -oP '"name":"\K[^"]+')
        VERSION=$(echo "$versions" | grep -xP '[0-9]+(\.[0-9]+)*-RC[0-9]*' | sort -V | tail -1)
        ;;
    *)
        VERSION="$MODE"
        ;;
esac

if [ -z "$VERSION" ]; then
    echo "ERROR: Could not detect Rodin $MODE version from SourceForge" >&2
    exit 1
fi

# Resolve the Linux x86_64 tarball filename
TARBALL=$(curl -fsSL --retry 2 --max-time 30 "$SF_BASE/$VERSION/" \
    | grep -oP 'rodin-[^"]*-linux\.gtk\.x86_64\.tar\.gz' | head -1)

if [ -z "$TARBALL" ]; then
    echo "ERROR: Could not find Linux tarball for Rodin $VERSION" >&2
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
