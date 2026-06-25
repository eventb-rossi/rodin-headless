#!/usr/bin/env bash
# Resolve latest ProB CLI version from the download server.
#
# Usage:
#   ./prob-version.sh          # latest stable
#   ./prob-version.sh latest   # same
#   ./prob-version.sh 1.15.1   # specific version
#
# The archive matches the host platform (the macOS one is universal);
# RODIN_PLATFORM (linux-x86_64, macos-x86_64, macos-aarch64) overrides
# the detection.
#
# Output (eval-friendly):
#   export PROB_VERSION='1.15.1'
#   export PROB_URL='https://stups.hhu-hosting.de/downloads/prob/...'

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
# Existing sibling lookups use $SCRIPT_DIR; keep it on the libexec dir.
SCRIPT_DIR="$RODIN_HEADLESS_LIBEXEC"
# shellcheck source=rodin-headless-lib.sh
. "$RODIN_HEADLESS_LIBEXEC/rodin-headless-lib.sh"

PROB_BASE="https://stups.hhu-hosting.de/downloads/prob/tcltk/releases"
SAFE_PATTERN='^[a-zA-Z0-9._-]+$'

MODE="${1:-latest}"

PLATFORM="$(rodin_platform)"
case "$PLATFORM" in
    # One universal archive covers both macOS architectures.
    macos-*) PROB_ARCHIVE='ProB.macos.zip' ;;
    *)       PROB_ARCHIVE='ProB.linux64.tar.gz' ;;
esac

latest_by_numbers() {
    awk '{ key = $0; gsub(/[^0-9]+/, ".", key); print key "\t" $0 }' \
        | sort -t . -k1,1n -k2,2n -k3,3n -k4,4n \
        | tail -1 \
        | cut -f2-
}

case "$MODE" in
    latest)
        # Directory listing has href="VERSION/" entries; pick latest stable
        # (digits and dots only, no beta/RC suffixes).
        listing=$(curl -fsSL --retry 2 --max-time 30 "$PROB_BASE/")
        versions=$(printf '%s\n' "$listing" \
            | grep -Eo 'href="[0-9][^/"]*/"' \
            | sed 's/^href="//;s|/"$||' || true)
        candidates=$(printf '%s\n' "$versions" | grep -E '^[0-9]+(\.[0-9]+)*$' || true)
        VERSION=$(printf '%s\n' "$candidates" | latest_by_numbers)
        ;;
    *)
        VERSION="$MODE"
        ;;
esac

if [ -z "$VERSION" ]; then
    echo "ERROR: Could not detect ProB $MODE version" >&2
    exit 1
fi

if ! [[ "$VERSION" =~ $SAFE_PATTERN ]]; then
    echo "ERROR: Unexpected characters in version='$VERSION'" >&2
    exit 1
fi

echo "export PROB_VERSION='$VERSION'"
echo "export PROB_URL='$PROB_BASE/$VERSION/$PROB_ARCHIVE'"
