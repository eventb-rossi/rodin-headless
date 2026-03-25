#!/usr/bin/env bash
# Resolve latest ProB CLI version from the download server.
#
# Usage:
#   ./prob-version.sh          # latest stable
#   ./prob-version.sh latest   # same
#   ./prob-version.sh 1.15.1   # specific version
#
# Output (eval-friendly):
#   export PROB_VERSION='1.15.1'
#   export PROB_URL='https://stups.hhu-hosting.de/downloads/prob/...'

set -euo pipefail

PROB_BASE="https://stups.hhu-hosting.de/downloads/prob/tcltk/releases"
SAFE_PATTERN='^[a-zA-Z0-9._-]+$'

MODE="${1:-latest}"

case "$MODE" in
    latest)
        # Directory listing has href="VERSION/" entries; pick latest stable
        # (digits and dots only, no beta/RC suffixes). sort -V for version sort.
        VERSION=$(curl -fsSL --retry 2 --max-time 30 "$PROB_BASE/" \
            | grep -oP 'href="\K[0-9][^/"]*' \
            | grep -xP '[0-9]+(\.[0-9]+)*' \
            | sort -V | tail -1)
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
echo "export PROB_URL='$PROB_BASE/$VERSION/ProB.linux64.tar.gz'"
