#!/usr/bin/env bash
# Install Rodin and ProB for headless Event-B builds.
#
# Works natively on Linux x86_64 and inside the Docker image build —
# the Dockerfile calls this same script, so install logic lives in one place.
#
# Usage:
#   ./rodin-install.sh [options]
#
# Options:
#   --prefix DIR       Install prefix (default: $RODIN_PREFIX or
#                      ~/.local/share/rodin-headless). Layout:
#                        <prefix>/rodin  — Rodin IDE (use as RODIN_DIR)
#                        <prefix>/prob   — ProB CLI (contains probcli)
#   --only rodin|prob  Run a single install phase
#   --force            Reinstall even if already present
#   --rodin-version V  "latest" (default), "latest-rc", or e.g. "3.9"
#   --rodin-tarball F  Pin the exact tarball filename (skips detection;
#                      requires --rodin-version to be a specific version)
#   --prob-version V   "latest" (default) or e.g. "1.15.1"
#   --check-deps       Report status of system dependencies and exit
#
# Examples:
#   ./rodin-install.sh                         # full install to ~/.local/share
#   ./rodin-install.sh --prefix /opt           # what the Docker image does
#   ./rodin-install.sh --only rodin --rodin-version 3.9

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=rodin-headless-lib.sh
. "$SCRIPT_DIR/rodin-headless-lib.sh"

PREFIX="${RODIN_PREFIX:-$HOME/.local/share/rodin-headless}"
ONLY=""
FORCE=0
RODIN_VERSION_ARG="latest"
RODIN_TARBALL_ARG=""
PROB_VERSION_ARG="latest"
CHECK_DEPS=0

usage() {
    cat <<'EOF'
Usage: ./rodin-install.sh [options]

Options:
  --prefix DIR       Install prefix (default: $RODIN_PREFIX or
                     ~/.local/share/rodin-headless)
  --only rodin|prob  Run a single install phase
  --force            Reinstall even if already present
  --rodin-version V  "latest" (default), "latest-rc", or e.g. "3.9"
  --rodin-tarball F  Pin the exact tarball filename (skips detection)
  --prob-version V   "latest" (default) or e.g. "1.15.1"
  --check-deps       Report status of system dependencies and exit
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)        PREFIX="$2"; shift 2 ;;
        --only)          ONLY="$2"; shift 2 ;;
        --force)         FORCE=1; shift ;;
        --rodin-version) RODIN_VERSION_ARG="$2"; shift 2 ;;
        --rodin-tarball) RODIN_TARBALL_ARG="$2"; shift 2 ;;
        --prob-version)  PROB_VERSION_ARG="$2"; shift 2 ;;
        --check-deps)    CHECK_DEPS=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

case "$ONLY" in
    ""|rodin|prob) ;;
    *)
        echo "ERROR: --only must be 'rodin' or 'prob', got '$ONLY'" >&2
        exit 1
        ;;
esac

RODIN_INSTALL_DIR="$PREFIX/rodin"
PROB_INSTALL_DIR="$PREFIX/prob"

# ── Dependency checks ───────────────────────────────────────────────

check_dep() {
    local kind="$1" name="$2" hint="$3"

    if command -v "$name" >/dev/null 2>&1; then
        printf 'ok       %s\n' "$name"
        return 0
    fi
    case "$kind" in
        required) printf 'MISSING  %s — %s\n' "$name" "$hint" ;;
        optional) printf 'missing  %s (optional) — %s\n' "$name" "$hint" ;;
    esac
    [ "$kind" != required ]
}

check_deps_report() {
    local missing=0

    echo "Runtime dependencies for headless Rodin builds:"
    check_dep required javac "JDK 21+ compiles the headless builder plugin (apt: openjdk-21-jdk-headless, dnf: java-21-openjdk-devel)" || missing=1
    check_dep required jar "part of the JDK (see javac)" || missing=1
    check_dep required zip "repackages model archives (apt/dnf: zip)" || missing=1
    check_dep required unzip "extracts model archives (apt/dnf: unzip)" || missing=1
    check_dep required flock "serializes Rodin launches (part of util-linux)" || missing=1
    check_dep required timeout "enforces the build timeout (part of coreutils)" || missing=1

    if [ -z "${DISPLAY:-}" ]; then
        check_dep required Xvfb "virtual display for SWT; needed when DISPLAY is unset (apt: xvfb, dnf: xorg-x11-server-Xvfb)" || missing=1
    else
        printf 'ok       Xvfb not needed (DISPLAY=%s is set)\n' "$DISPLAY"
    fi

    if ldconfig -p 2>/dev/null | grep -q 'libgtk-3\.so\.0'; then
        printf 'ok       GTK3 (libgtk-3.so.0)\n'
    else
        printf 'MISSING  GTK3 — SWT needs it even headless (apt: libgtk-3-0, dnf: gtk3)\n'
        missing=1
    fi

    check_dep optional z3 "extra SMT solver for probcli (apt/dnf: z3)" || true
    check_dep optional cvc5 "extra SMT solver for probcli (apt: cvc5)" || true

    if [ -x "$PROB_INSTALL_DIR/probcli" ]; then
        printf 'ok       probcli (%s)\n' "$PROB_INSTALL_DIR/probcli"
    else
        printf 'missing  probcli — not installed under %s (run %s --only prob)\n' \
            "$PROB_INSTALL_DIR" "$0"
    fi

    return "$missing"
}

require_install_deps() {
    local tool missing=0
    for tool in curl tar java; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "ERROR: $tool is required to run the installer" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ]
}

require_supported_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    if [ "$os" != "Linux" ] || [ "$arch" != "x86_64" ]; then
        echo "ERROR: Native install supports Linux x86_64 only (got $os $arch)." >&2
        echo "Rodin and ProB publish Linux x86_64 artifacts; use Docker mode instead: ./rodin build ..." >&2
        exit 1
    fi
}

if [ "$CHECK_DEPS" -eq 1 ]; then
    check_deps_report
    exit $?
fi

# ── Phase: rodin ────────────────────────────────────────────────────
# Download the Rodin tarball, unpack it, and point rodin.ini at the JVM.

install_rodin() {
    if [ -e "$RODIN_INSTALL_DIR/rodin.ini" ] && [ "$FORCE" -eq 0 ]; then
        echo "Rodin already installed at $RODIN_INSTALL_DIR (use --force to reinstall)"
        return 0
    fi
    rm -rf "$RODIN_INSTALL_DIR"

    local rodin_env tarball_tmp java_bin_dir
    if [ -n "$RODIN_TARBALL_ARG" ]; then
        RODIN_VERSION="$RODIN_VERSION_ARG"
        RODIN_TARBALL="$RODIN_TARBALL_ARG"
        RODIN_URL="https://sourceforge.net/projects/rodin-b-sharp/files/Core_Rodin_Platform/${RODIN_VERSION}/${RODIN_TARBALL}/download"
    else
        rodin_env="$("$SCRIPT_DIR/rodin-version.sh" "$RODIN_VERSION_ARG")"
        eval "$rodin_env"
    fi

    echo "Installing Rodin $RODIN_VERSION: $RODIN_TARBALL"
    tarball_tmp="$(mktemp /tmp/rodin-tarball.XXXXXX)"
    curl -fSL --retry 3 --retry-delay 5 --max-time 300 \
        -o "$tarball_tmp" "$RODIN_URL"
    mkdir -p "$RODIN_INSTALL_DIR"
    tar xzf "$tarball_tmp" -C "$RODIN_INSTALL_DIR" --strip-components=1
    rm -f "$tarball_tmp"
    chmod +x "$RODIN_INSTALL_DIR/rodin"

    # Point Rodin at the JVM that will run it; resolve symlinks so the
    # path survives alternatives-style indirection.
    java_bin_dir="$(dirname "$(readlink -f "$(command -v java)")")"
    if [ "$(head -1 "$RODIN_INSTALL_DIR/rodin.ini")" != "-vm" ]; then
        sed -i "1i -vm\n$java_bin_dir" "$RODIN_INSTALL_DIR/rodin.ini"
    fi

    echo "Rodin $RODIN_VERSION installed at $RODIN_INSTALL_DIR"
}

# ── Phase: prob ─────────────────────────────────────────────────────
# Download the ProB CLI and install the ProB/SMT/Atelier B Rodin plugins
# via the p2 director.

install_prob() {
    if [ ! -e "$RODIN_INSTALL_DIR/rodin.ini" ]; then
        echo "ERROR: Rodin not found at $RODIN_INSTALL_DIR — run the rodin phase first" >&2
        exit 1
    fi

    local prob_env prob_tmp
    if [ -x "$PROB_INSTALL_DIR/probcli" ] && [ "$FORCE" -eq 0 ]; then
        echo "ProB CLI already installed at $PROB_INSTALL_DIR (use --force to reinstall)"
    else
        rm -rf "$PROB_INSTALL_DIR"
        prob_env="$("$SCRIPT_DIR/prob-version.sh" "$PROB_VERSION_ARG")"
        eval "$prob_env"
        echo "Installing ProB $PROB_VERSION"
        prob_tmp="$(mktemp /tmp/prob-tarball.XXXXXX)"
        curl -fSL --retry 3 --retry-delay 5 --max-time 300 \
            -o "$prob_tmp" "$PROB_URL"
        mkdir -p "$PROB_INSTALL_DIR"
        tar xzf "$prob_tmp" -C "$PROB_INSTALL_DIR" --strip-components=1
        rm -f "$prob_tmp"
        echo "ProB CLI installed at $PROB_INSTALL_DIR"
    fi

    if [ -n "$(resolve_latest_dir "$RODIN_INSTALL_DIR/plugins" de.prob.core)" ] && [ "$FORCE" -eq 0 ]; then
        echo "ProB Rodin plugins already installed in $RODIN_INSTALL_DIR (use --force to reinstall)"
        return 0
    fi

    # The ProB plugin requires org.eclipse.gef, which is not in Rodin's base
    # install. The matching Eclipse release site provides version-compatible
    # GEF. Eclipse version is read from Rodin's .eclipseproduct and mapped to
    # a release name using the quarterly cadence: 4.24=2022-06, each +1 minor
    # = +3 months.
    local eclipse_minor offset total_months eclipse_release launcher_jar
    eclipse_minor="$(grep '^version=' "$RODIN_INSTALL_DIR/.eclipseproduct" | cut -d. -f2)"
    offset=$(( eclipse_minor - 24 ))
    total_months=$(( 5 + offset * 3 ))
    eclipse_release="$(( 2022 + total_months / 12 ))-$(printf '%02d' $(( total_months % 12 + 1 )))"
    echo "Using Eclipse release $eclipse_release for dependencies (platform 4.$eclipse_minor)"

    launcher_jar="$(resolve_latest_jar "$RODIN_INSTALL_DIR/plugins" org.eclipse.equinox.launcher)"
    if [ -z "$launcher_jar" ]; then
        echo "ERROR: equinox launcher JAR not found in $RODIN_INSTALL_DIR/plugins" >&2
        exit 1
    fi

    java -jar "$launcher_jar" \
        -nosplash \
        -application org.eclipse.equinox.p2.director \
        -repository "https://rodin-b-sharp.sourceforge.net/updates/,https://www.atelierb.eu/update_site/atelierb_provers,https://stups.hhu-hosting.de/rodin/prob1/release/,https://download.eclipse.org/releases/$eclipse_release/" \
        -installIU org.eventb.smt.feature.group,com.clearsy.atelierb.provers.feature.group,de.prob2.feature.feature.group,de.prob2.disprover.feature.feature.group,de.prob2.symbolic.feature.feature.group \
        -destination "$RODIN_INSTALL_DIR"

    echo "ProB Rodin plugins installed in $RODIN_INSTALL_DIR"
}

require_install_deps
require_supported_platform

case "$ONLY" in
    rodin) install_rodin ;;
    prob)  install_prob ;;
    "")    install_rodin; install_prob ;;
esac

if [ -z "$ONLY" ] || [ "$ONLY" = "prob" ]; then
    echo
    echo "Done. Next steps:"
    echo "  ./rodin build model.zip                # wrapper auto-detects this install"
    echo "  $0 --check-deps                        # verify system dependencies"
fi
