#!/usr/bin/env bash
# Install Rodin and ProB for headless Event-B builds.
#
# Works natively on Linux x86_64 and macOS (Intel and Apple Silicon —
# the latter needs Rodin 3.10+, the first release with arm64 mac
# builds) and inside the Docker image build — the Dockerfile calls
# this same script, so install logic lives in one place.
# Run with --help for the option list.
#
# Examples:
#   ./rodin-install.sh                         # full install to ~/.local/share
#   ./rodin-install.sh --prefix /opt           # what the Docker image does
#   ./rodin-install.sh --only rodin --rodin-version 3.9

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

# Resolved after option parsing: the default needs RODIN_PREFIX or
# HOME, and an explicit --prefix must work without either.
PREFIX=""
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
                     ~/.local/share/rodin-headless). Layout:
                       <prefix>/rodin  — Rodin IDE (use as RODIN_DIR)
                       <prefix>/prob   — ProB CLI (contains probcli)
  --only rodin|prob  Run a single install phase
  --force            Reinstall even if already present
  --rodin-version V  "latest" (default), "latest-rc", or e.g. "3.9"
  --rodin-tarball F  Pin the exact tarball filename (skips detection;
                     requires --rodin-version to be a specific version)
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
        --version|-V)    printf 'rodin-headless-install %s\n' "$(rodin_headless_version)"; exit 0 ;;
        -h|--help)       usage; exit 0 ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ -z "$PREFIX" ]; then
    if ! PREFIX="$(default_rodin_prefix)"; then
        # --check-deps is purely diagnostic and must keep working where
        # the default prefix is underivable (no HOME: cron, CI, su) —
        # it only uses the prefix for the advisory probcli line.
        [ "$CHECK_DEPS" -eq 1 ] || exit 1
        PREFIX=""
    fi
fi

case "$ONLY" in
    ""|rodin|prob) ;;
    *)
        echo "ERROR: --only must be 'rodin' or 'prob', got '$ONLY'" >&2
        exit 1
        ;;
esac

if [ -n "$RODIN_TARBALL_ARG" ]; then
    case "$RODIN_VERSION_ARG" in
        latest|latest-rc)
            echo "ERROR: --rodin-tarball requires a specific --rodin-version (the version is part of the download URL)" >&2
            exit 1
            ;;
    esac
fi

RODIN_INSTALL_DIR="$PREFIX/rodin"
PROB_INSTALL_DIR="$PREFIX/prob"

# Temp files/dirs are tracked here and removed on exit, so failed
# downloads or interrupted unpacks do not leak into /tmp or the prefix.
TMP_PATHS=()
cleanup_tmp() {
    if [ "${#TMP_PATHS[@]}" -gt 0 ]; then
        rm -rf "${TMP_PATHS[@]}"
    fi
    return 0
}
trap cleanup_tmp EXIT

fetch_and_unpack() {
    local url="$1" dest="$2" archive

    archive="$(mktemp /tmp/rodin-headless-dl.XXXXXX)"
    TMP_PATHS+=("$archive")
    # Stall-based timeout instead of a tight --max-time cap: the
    # tarballs are >100 MB and a slow mirror must not abort a transfer
    # that is still making progress. The generous --max-time still
    # bounds a pathological trickle (above the stall floor but going
    # nowhere) so unattended builds fail instead of hanging for hours.
    curl -fSL --retry 3 --retry-delay 5 --connect-timeout 30 \
        --speed-limit 1024 --speed-time 60 --max-time 3600 \
        -o "$archive" "$url"
    mkdir -p "$dest"
    case "$url" in
        *.zip)
            # The ProB macOS archive is flat (probcli at the root), so
            # there is no wrapping directory to strip.
            unzip -q "$archive" -d "$dest"
            ;;
        *)
            tar xzf "$archive" -C "$dest" --strip-components=1
            ;;
    esac
    rm -f "$archive"
}

# Resolved-version manifest: one key=value per component, merged across
# phases, so a prefix (or image) built from "latest" stays auditable
# after the fact.
record_installed_version() {
    local key="$1" value="$2" manifest tmp

    manifest="$PREFIX/.rodin-headless-versions"
    tmp="$(mktemp)"
    if [ -f "$manifest" ]; then
        grep -v "^$key=" "$manifest" > "$tmp" || true
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$manifest"
}

# Refuse to touch a non-empty target directory that doesn't carry the
# expected marker file — it is probably not ours to delete.
refuse_foreign_dir() {
    local dir="$1" marker="$2"

    if [ -e "$dir" ] && [ ! -e "$dir/$marker" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
        echo "ERROR: $dir exists but does not look like a previous install (no $marker)" >&2
        echo "Refusing to overwrite it — remove it manually and re-run" >&2
        exit 1
    fi
}

# ── Dependency checks ───────────────────────────────────────────────

check_dep() {
    local kind="$1" name="$2" hint="$3"

    if command -v "$name" >/dev/null 2>&1; then
        printf 'ok       %s\n' "$name"
        return 0
    fi
    if [ "$kind" = required ]; then
        printf 'MISSING  %s — %s\n' "$name" "$hint"
        return 1
    fi
    printf 'missing  %s (optional) — %s\n' "$name" "$hint"
}

# Returns 0 if GTK3 is present, 1 if absent, 2 if undeterminable.
# ldconfig lives in /sbin on some distros, which non-root PATHs may lack.
gtk3_status() {
    local lc
    for lc in ldconfig /sbin/ldconfig /usr/sbin/ldconfig; do
        if command -v "$lc" >/dev/null 2>&1; then
            if "$lc" -p 2>/dev/null | grep -q 'libgtk-3\.so\.0'; then
                return 0
            fi
            return 1
        fi
    done
    return 2
}

check_deps_report() {
    local missing=0 os
    os="$(host_os)"

    echo "Runtime dependencies for headless Rodin builds:"
    check_dep required javac "JDK 21+ compiles the headless builder plugin (apt: openjdk-21-jdk-headless, dnf: java-21-openjdk-devel, brew: temurin@21)" || missing=1
    check_dep required jar "part of the JDK (see javac)" || missing=1
    check_dep required zip "repackages model archives (apt/dnf: zip)" || missing=1
    check_dep required unzip "extracts model archives (apt/dnf: unzip)" || missing=1

    if [ "$os" = Darwin ]; then
        # SWT uses Cocoa on macOS, and the timeout helper has a
        # pure-shell fallback.
        check_dep optional timeout "enforces the build timeout; built-in fallback (brew: coreutils, as gtimeout)"
        printf 'ok       Xvfb not needed on macOS (SWT uses Cocoa)\n'
        printf 'ok       GTK3 not needed on macOS (SWT uses Cocoa)\n'
    else
        # The lib has a pure-shell fallback, so a missing GNU timeout
        # does not block an install — it is just the better tool.
        check_dep optional timeout "enforces the build timeout; built-in fallback (part of coreutils)"

        if [ -z "${DISPLAY:-}" ]; then
            check_dep required Xvfb "virtual display for SWT; needed when DISPLAY is unset (apt: xvfb, dnf: xorg-x11-server-Xvfb)" || missing=1
        else
            printf 'ok       Xvfb not needed (DISPLAY=%s is set)\n' "$DISPLAY"
        fi

        local gtk3_rc=0
        gtk3_status || gtk3_rc=$?
        case "$gtk3_rc" in
            0) printf 'ok       GTK3 (libgtk-3.so.0)\n' ;;
            1)
                printf 'MISSING  GTK3 — SWT needs it even headless (apt: libgtk-3-0, dnf: gtk3)\n'
                missing=1
                ;;
            *) printf 'unknown  GTK3 — ldconfig not found, cannot check\n' ;;
        esac
    fi

    check_dep optional z3 "extra SMT solver for probcli (apt/dnf: z3)"
    check_dep optional cvc5 "extra SMT solver for probcli (apt: cvc5)"

    if [ -z "$PREFIX" ]; then
        printf 'unknown  probcli — set RODIN_PREFIX or HOME to locate an install\n'
    elif [ -x "$PROB_INSTALL_DIR/probcli" ]; then
        printf 'ok       probcli (%s)\n' "$PROB_INSTALL_DIR/probcli"
    else
        printf 'missing  probcli — not installed under %s (run %s --only prob)\n' \
            "$PROB_INSTALL_DIR" "$0"
    fi

    return "$missing"
}

require_install_deps() {
    local tool missing=0 java_major
    # unzip unpacks the macOS ProB archive at install time and model
    # archives at runtime, so it is required everywhere.
    for tool in curl tar java unzip; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "ERROR: $tool is required to run the installer" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || exit 1

    # Rodin/Eclipse and the p2 director need a modern JVM; catch a stale
    # default java up front instead of mid-install. Skip silently when
    # the version string is unparsable (exotic JVMs).
    java_major="$(java -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -1)"
    if [ -n "$java_major" ] && [ "$java_major" -lt 17 ]; then
        echo "ERROR: java $java_major is too old — Rodin needs a JDK 17+ (21+ recommended)" >&2
        exit 1
    fi
}

require_supported_platform() {
    # rodin_platform owns the supported-platform matrix and rejects
    # unsupported hosts and bad RODIN_PLATFORM overrides alike.
    if ! rodin_platform >/dev/null; then
        echo "Use an amd64 container instead (the ./rodin wrapper sets --platform linux/amd64 on arm64 hosts)." >&2
        exit 1
    fi
}

if [ "$CHECK_DEPS" -eq 1 ]; then
    if check_deps_report; then
        exit 0
    fi
    exit 1
fi

# ── Phase: rodin ────────────────────────────────────────────────────
# Download the Rodin tarball, unpack it into a staging directory, and
# only then replace the previous install — a failed download or unpack
# never destroys a working setup.

install_rodin() {
    if resolve_rodin_home "$RODIN_INSTALL_DIR" >/dev/null && [ "$FORCE" -eq 0 ]; then
        echo "Rodin already installed at $RODIN_INSTALL_DIR (use --force to reinstall)"
        return 0
    fi
    # resolve_rodin_home is the layout authority: any install it
    # recognizes is ours to replace (--force lands here too); anything
    # else non-empty is refused.
    if ! resolve_rodin_home "$RODIN_INSTALL_DIR" >/dev/null; then
        refuse_foreign_dir "$RODIN_INSTALL_DIR" rodin.ini
    fi

    local rodin_env staging staging_home java_bin_dir ini_tmp
    rodin_env="$("$SCRIPT_DIR/rodin-version.sh" "$RODIN_VERSION_ARG" \
        ${RODIN_TARBALL_ARG:+"$RODIN_TARBALL_ARG"})"
    eval "$rodin_env"

    echo "Installing Rodin $RODIN_VERSION: $RODIN_TARBALL"
    mkdir -p "$PREFIX"
    staging="$(mktemp -d "$PREFIX/.rodin-staging.XXXXXX")"
    TMP_PATHS+=("$staging")
    fetch_and_unpack "$RODIN_URL" "$staging"
    if ! staging_home="$(resolve_rodin_home "$staging")"; then
        echo "ERROR: unpacked Rodin archive has no rodin.ini" >&2
        exit 1
    fi
    # Fails loudly when the archive carries no launcher binary where
    # its layout says one belongs.
    chmod +x "$(resolve_rodin_launcher "$staging")"

    # Point Rodin at the JVM that will run it. Use the PATH entry's
    # directory without resolving symlinks — alternatives-style links
    # stay valid across JDK package upgrades, a resolved versioned
    # directory does not. Prepend via a temp file and write back with
    # cat: BSD sed has no GNU -i/1i semantics, and an mv would replace
    # rodin.ini's mode with mktemp's 0600.
    java_bin_dir="$(dirname "$(command -v java)")"
    if [ "$(head -1 "$staging_home/rodin.ini")" != "-vm" ]; then
        ini_tmp="$(mktemp)"
        printf -- '-vm\n%s\n' "$java_bin_dir" | cat - "$staging_home/rodin.ini" > "$ini_tmp"
        cat "$ini_tmp" > "$staging_home/rodin.ini"
        rm -f "$ini_tmp"
    fi

    rm -rf "$RODIN_INSTALL_DIR"
    mv "$staging" "$RODIN_INSTALL_DIR"
    record_installed_version rodin "$RODIN_VERSION"
    record_installed_version rodin-tarball "$RODIN_TARBALL"

    echo "Rodin $RODIN_VERSION installed at $RODIN_INSTALL_DIR"
}

# ── Phase: prob ─────────────────────────────────────────────────────
# Download the ProB CLI and install the ProB/SMT/Atelier B Rodin plugins
# via the p2 director.

FEATURE_IUS="org.eventb.smt.feature.group,com.clearsy.atelierb.provers.feature.group,de.prob2.feature.feature.group,de.prob2.disprover.feature.feature.group,de.prob2.symbolic.feature.feature.group"

# One marker plugin per installed feature family; all present means the
# director run completed, so an interrupted install is retried. Takes
# the already-resolved Rodin home.
plugins_complete() {
    local home="$1"
    [ -n "$(find_prob_plugin "$home")" ] \
        && [ -n "$(resolve_latest_jar "$home/plugins" org.eventb.smt.core)" ] \
        && [ -n "$(resolve_latest_jar "$home/plugins" com.clearsy.atelierb.provers.core)" ]
}

run_p2_director() {
    local destination="$1" launcher_jar="$2"
    shift 2
    java "${JDK_XML_RELAXED_OPTS[@]}" \
        -jar "$launcher_jar" \
        -nosplash \
        -application org.eclipse.equinox.p2.director \
        -destination "$destination" \
        "$@"
}

install_prob() {
    local rodin_home
    if ! rodin_home="$(resolve_rodin_home "$RODIN_INSTALL_DIR")"; then
        echo "ERROR: Rodin not found at $RODIN_INSTALL_DIR — run the rodin phase first" >&2
        exit 1
    fi

    local prob_env staging
    if [ -x "$PROB_INSTALL_DIR/probcli" ] && [ "$FORCE" -eq 0 ]; then
        echo "ProB CLI already installed at $PROB_INSTALL_DIR (use --force to reinstall)"
    else
        refuse_foreign_dir "$PROB_INSTALL_DIR" probcli
        prob_env="$("$SCRIPT_DIR/prob-version.sh" "$PROB_VERSION_ARG")"
        eval "$prob_env"
        echo "Installing ProB $PROB_VERSION"
        mkdir -p "$PREFIX"
        staging="$(mktemp -d "$PREFIX/.prob-staging.XXXXXX")"
        TMP_PATHS+=("$staging")
        fetch_and_unpack "$PROB_URL" "$staging"
        rm -rf "$PROB_INSTALL_DIR"
        mv "$staging" "$PROB_INSTALL_DIR"
        record_installed_version prob "$PROB_VERSION"
        echo "ProB CLI installed at $PROB_INSTALL_DIR"
    fi

    if [ "$FORCE" -eq 0 ] && plugins_complete "$rodin_home"; then
        echo "ProB Rodin plugins already installed in $RODIN_INSTALL_DIR (use --force to reinstall)"
        return 0
    fi

    # The ProB plugin requires org.eclipse.gef, which is not in Rodin's base
    # install. The matching Eclipse release site provides version-compatible
    # GEF. Eclipse version is read from Rodin's .eclipseproduct and mapped to
    # a release name using the quarterly cadence: 4.24=2022-06, each +1 minor
    # = +3 months.
    local eclipse_minor offset total_months eclipse_release launcher_jar
    eclipse_minor="$(grep '^version=' "$rodin_home/.eclipseproduct" | cut -d. -f2)"
    offset=$(( eclipse_minor - 24 ))
    total_months=$(( 5 + offset * 3 ))
    eclipse_release="$(( 2022 + total_months / 12 ))-$(printf '%02d' $(( total_months % 12 + 1 )))"
    echo "Using Eclipse release $eclipse_release for dependencies (platform 4.$eclipse_minor)"

    launcher_jar="$(resolve_latest_jar "$rodin_home/plugins" org.eclipse.equinox.launcher)"
    if [ -z "$launcher_jar" ]; then
        echo "ERROR: equinox launcher JAR not found in $rodin_home/plugins" >&2
        exit 1
    fi

    # The director cannot install IUs over themselves; on --force (or a
    # partial previous run) remove what is there first, best-effort.
    if [ -n "$(find_prob_plugin "$rodin_home")" ]; then
        run_p2_director "$rodin_home" "$launcher_jar" -uninstallIU "$FEATURE_IUS" || true
    fi

    run_p2_director "$rodin_home" "$launcher_jar" \
        -repository "https://rodin-b-sharp.sourceforge.net/updates/,https://www.atelierb.eu/update_site/atelierb_provers,https://stups.hhu-hosting.de/rodin/prob1/release/,https://download.eclipse.org/releases/$eclipse_release/" \
        -installIU "$FEATURE_IUS"

    echo "ProB Rodin plugins installed in $RODIN_INSTALL_DIR"
}

require_install_deps
require_supported_platform

case "$ONLY" in
    rodin) install_rodin ;;
    prob)  install_prob ;;
    "")    install_rodin; install_prob ;;
esac

if [ "$ONLY" != rodin ]; then
    echo
    echo "Done. Next steps:"
    echo "  ./rodin build model.zip                # wrapper auto-detects this install"
    echo "  $0 --check-deps                        # verify system dependencies"
fi
