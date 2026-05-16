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

# Resolve the Linux x86_64 tarball filename
listing=$(curl -fsSL --retry 2 --max-time 30 "$SF_BASE/$VERSION/")
TARBALL=$(printf '%s\n' "$listing" \
    | grep -Eo 'rodin-[^"]*-linux\.gtk\.x86_64\.tar\.gz' | head -1 || true)

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
