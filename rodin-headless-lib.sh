#!/usr/bin/env bash

# Single definition of the native install location, shared by the
# installer (write side) and the rodin wrapper (detect side). With
# neither RODIN_PREFIX nor HOME set (cron, launchd, su, some CI), there
# is no sane default — fail instead of fabricating an unwritable
# /-rooted path.
default_rodin_prefix() {
    if [ -z "${RODIN_PREFIX:-}" ] && [ -z "${HOME:-}" ]; then
        echo "ERROR: cannot derive the rodin-headless prefix: set RODIN_PREFIX or HOME" >&2
        return 1
    fi
    printf '%s\n' "${RODIN_PREFIX:-$HOME/.local/share/rodin-headless}"
}

# JDK 23+ ships restrictive JAXP defaults that choke on the large
# entities in Eclipse XML (update-site metadata, registries); 0 means
# unlimited, and the properties are recognized since JDK 8. Spliced
# into every equinox JVM launch (p2 director and the build engine).
JDK_XML_RELAXED_OPTS=(
    -Djdk.xml.maxGeneralEntitySizeLimit=0
    -Djdk.xml.totalEntitySizeLimit=0
)

# Locate the directory holding rodin.ini under an install root. Linux
# tarballs keep the Eclipse layout at the root; macOS builds wrap it in
# an app bundle under Contents/Eclipse. Detection is layout-driven, not
# uname-driven, so either layout works on any host.
resolve_rodin_home() {
    local root="$1" candidate

    for candidate in "$root" "$root/Contents/Eclipse" "$root/rodin.app/Contents/Eclipse"; do
        if [ -f "$candidate/rodin.ini" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# Lenient variant: an unresolvable install degrades to the root, so
# callers reach the friendlier downstream error (the ProB plugin
# precheck) instead of failing on layout grounds.
resolve_rodin_home_or_root() {
    resolve_rodin_home "$1" || printf '%s\n' "$1"
}

# Resolve the de.prob.core plugin directory under a Rodin install;
# prints nothing when the plugin (or the install) is absent. The single
# definition of "this install can run the headless builder" — used by
# the wrapper's auto-detection, the engine's precheck, and the
# installer's idempotency check. Idempotent over already-resolved
# homes (rodin.ini sits at the home root).
find_prob_plugin() {
    local home

    home="$(resolve_rodin_home_or_root "$1")"
    [ -d "$home/plugins" ] || return 0
    resolve_latest_dir "$home/plugins" de.prob.core
}

# All directories under an unpacked archive that look like Event-B
# project roots (sources or .project metadata), one per line. macOS
# Finder zips carry AppleDouble copies (__MACOSX/…/._M1.bum) that must
# not count as roots — or worse, win the sort and become the
# repackaging target.
find_archive_project_roots() {
    local archive_root="$1"

    find "$archive_root" -name __MACOSX -prune -o \
        \( \( -name "*.bum" -o -name "*.buc" -o -name ".project" \) \
            ! -name "._*" \) \
        -exec dirname {} \; | sort -u
}

# The toolchain processes one project per archive; this picks the
# canonical one. Extraction warns when an archive holds more.
find_archive_project_root() {
    find_archive_project_roots "$1" | head -1
}

run_with_filtered_output() {
    local output_file status had_errexit
    output_file="$(mktemp)"
    had_errexit=0

    case $- in
        *e*)
            had_errexit=1
            set +e
            ;;
    esac

    "$@" >"$output_file" 2>&1
    status=$?

    if [ "$had_errexit" -eq 1 ]; then
        set -e
    fi

    sed '/^[[:space:]]*at /d;/^\.\.\./d;/^$/d' "$output_file" || true
    rm -f "$output_file"
    return "$status"
}

# GNU timeout durations: integer or fractional, with an optional
# s/m/h/d suffix. Converted to whole seconds (fractions rounded up)
# for the watchdog fallback.
timeout_duration_to_seconds() {
    local duration="$1" number multiplier

    number="${duration%[smhd]}"
    case "$number" in
        "" | . | *[!0-9.]* | *.*.*)
            echo "ERROR: invalid timeout duration '$duration' (expected N[.N][s|m|h|d])" >&2
            return 1
            ;;
    esac

    case "${duration#"$number"}" in
        "" | s) multiplier=1 ;;
        m)      multiplier=60 ;;
        h)      multiplier=3600 ;;
        d)      multiplier=86400 ;;
    esac
    awk -v n="$number" -v m="$multiplier" \
        'BEGIN { v = n * m; printf "%d\n", (v == int(v)) ? v : int(v) + 1 }'
}

# Pure-shell stand-in for GNU timeout on systems without it (stock
# macOS): TERM after $duration, KILL after a further $kill_after, exit
# 124 on timeout. Mirrors GNU semantics: a zero duration disables the
# timeout, and signals go to the command's whole process group — job
# control gives the command and the watchdog their own groups, so
# children (probcli under java, the watchdog's sleeps) die with their
# parent instead of being orphaned.
run_with_watchdog_timeout() {
    local duration_s kill_after_s flag_file cmd_pid watchdog_pid status

    duration_s="$(timeout_duration_to_seconds "$1")" || return 125
    kill_after_s="$(timeout_duration_to_seconds "$2")" || return 125
    shift 2

    if [ "$duration_s" -eq 0 ]; then
        "$@"
        return
    fi

    # A non-empty flag file marks "the watchdog fired", which beats
    # inspecting wait's status: the command may trap TERM or exit 143
    # on its own.
    flag_file="$(mktemp)"

    set -m
    "$@" &
    cmd_pid=$!
    (
        sleep "$duration_s"
        printf 'timeout\n' > "$flag_file"
        kill -TERM -- "-$cmd_pid" 2>/dev/null
        sleep "$kill_after_s"
        kill -KILL -- "-$cmd_pid" 2>/dev/null
    ) &
    watchdog_pid=$!
    set +m

    # The command no longer shares our process group, so a Ctrl-C/TERM
    # aimed at this script must be forwarded or the command outlives
    # its caller.
    trap 'kill -TERM -- "-$cmd_pid" 2>/dev/null' TERM INT

    # wait's stderr is silenced to drop bash's "Terminated" job notice
    # on a timeout; the command's own stderr is untouched.
    status=0
    wait "$cmd_pid" 2>/dev/null || status=$?
    trap - TERM INT
    kill -KILL -- "-$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    if [ -s "$flag_file" ]; then
        status=124
    fi
    rm -f "$flag_file"
    return "$status"
}

run_with_optional_timeout() {
    local duration="$1"
    local kill_after="$2"
    shift 2

    case "$duration" in
        "" | 0 | none | off)
            "$@"
            return
            ;;
    esac

    if command -v timeout >/dev/null 2>&1; then
        timeout --kill-after="$kill_after" "$duration" "$@"
        return
    fi
    # Homebrew coreutils installs GNU timeout under a g prefix.
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout --kill-after="$kill_after" "$duration" "$@"
        return
    fi
    run_with_watchdog_timeout "$duration" "$kill_after" "$@"
}

# Serialize Rodin launches against a shared install. Linux prefers
# flock (kernel-backed, released on crash); macOS always uses the
# mkdir spinlock — keying the choice on the per-process PATH would let
# a run that sees a Homebrew flock and one that doesn't lock different
# objects and miss each other. Like flock, a live owner is waited on
# indefinitely; only stale locks are reclaimed. release_rodin_lock is
# idempotent and safe from an EXIT trap.
RODIN_LOCK_KIND=""
RODIN_LOCK_PATH=""

# kill -0 cannot tell a dead process from another user's (EPERM), so
# fall back to ps before declaring a lock owner dead and stealing its
# lock. Without ps (minimal containers) the kill verdict stands.
lock_owner_alive() {
    kill -0 "$1" 2>/dev/null && return 0
    command -v ps >/dev/null 2>&1 || return 1
    ps -p "$1" >/dev/null 2>&1
}

acquire_rodin_lock() {
    local lock_file="$1" lock_dir stale_dir pid stale_pid no_pid_since

    if [ "$(host_os)" != Darwin ] && command -v flock >/dev/null 2>&1; then
        # Fixed descriptor: bash 3.2 has no {var}> auto-allocation.
        exec 9> "$lock_file"
        flock 9
        RODIN_LOCK_KIND=flock
        return 0
    fi

    lock_dir="$lock_file.d"
    no_pid_since=""
    until mkdir "$lock_dir" 2>/dev/null; do
        pid=""
        read -r pid 2>/dev/null < "$lock_dir/pid" || pid=""

        if [ -n "$pid" ]; then
            no_pid_since=""
            if lock_owner_alive "$pid"; then
                sleep 1
                continue
            fi
        else
            # Grace for the owner's mkdir-to-pid-write window; only a
            # lock that stays ownerless for 30s is considered stale.
            if [ -z "$no_pid_since" ]; then
                no_pid_since=$SECONDS
            fi
            if [ $(( SECONDS - no_pid_since )) -lt 30 ]; then
                sleep 1
                continue
            fi
        fi

        # Steal the stale lock via rename: exactly one contender wins
        # the mv, so a lock freshly re-acquired by another waiter
        # cannot be deleted out from under it by a racer still holding
        # the old owner's pid in hand.
        stale_dir="$lock_dir.stale.$$"
        if mv "$lock_dir" "$stale_dir" 2>/dev/null; then
            # Re-acquired between our liveness check and the mv? Hand
            # it back instead of destroying a live lock.
            stale_pid=""
            read -r stale_pid 2>/dev/null < "$stale_dir/pid" || stale_pid=""
            if [ -n "$stale_pid" ] && [ "$stale_pid" != "$pid" ] \
                && lock_owner_alive "$stale_pid"; then
                mv "$stale_dir" "$lock_dir" 2>/dev/null || rm -rf "$stale_dir"
            else
                rm -rf "$stale_dir"
            fi
        fi
        no_pid_since=""
    done
    printf '%s\n' "$$" > "$lock_dir/pid"
    RODIN_LOCK_KIND=dir
    RODIN_LOCK_PATH="$lock_dir"
}

release_rodin_lock() {
    case "$RODIN_LOCK_KIND" in
        flock)
            # Closing the descriptor releases the kernel lock.
            exec 9>&-
            ;;
        dir)
            rm -rf "$RODIN_LOCK_PATH"
            ;;
    esac
    RODIN_LOCK_KIND=""
    RODIN_LOCK_PATH=""
}

# SWT's Cocoa port talks to WindowServer, which only a logged-in
# graphical (Aqua) session provides; without one the Rodin launch
# blocks until the build timeout fires. launchctl reports the session
# kind as the manager name: Aqua on a desktop, Background over
# ssh/cron. RODIN_SKIP_GUI_CHECK=1 bypasses the probe in case it ever
# misdetects a launchable session.
darwin_gui_session_ok() {
    [ "$(host_os)" = Darwin ] || return 0
    if [ "${RODIN_SKIP_GUI_CHECK:-}" = 1 ]; then
        return 0
    fi
    [ "$(launchctl managername 2>/dev/null)" = Aqua ]
}

# uname-guarded so dependency reporting keeps working on the minimal
# PATHs the test suite constructs.
host_os() {
    if command -v uname >/dev/null 2>&1; then
        uname -s
    else
        printf 'Linux\n'
    fi
}

host_arch() {
    if command -v uname >/dev/null 2>&1; then
        uname -m
    else
        printf 'x86_64\n'
    fi
}

# Canonical platform token for artifact selection — the one place that
# knows which platforms Rodin/ProB publish artifacts for, consumed by
# the version scripts and the installer's gate. RODIN_PLATFORM
# overrides detection (tests, cross-platform resolution); unknown
# overrides and unsupported hosts are rejected so nothing silently
# selects another platform's artifacts.
rodin_platform() {
    case "${RODIN_PLATFORM:-}" in
        "")
            case "$(host_os)/$(host_arch)" in
                Darwin/arm64 | Darwin/aarch64) printf 'macos-aarch64\n' ;;
                Darwin/*)                      printf 'macos-x86_64\n' ;;
                Linux/x86_64)                  printf 'linux-x86_64\n' ;;
                *)
                    echo "ERROR: unsupported platform $(host_os) $(host_arch) — Rodin and ProB publish Linux x86_64 and macOS artifacts only" >&2
                    return 1
                    ;;
            esac
            ;;
        linux-x86_64 | macos-x86_64 | macos-aarch64)
            printf '%s\n' "$RODIN_PLATFORM"
            ;;
        *)
            echo "ERROR: RODIN_PLATFORM must be linux-x86_64, macos-x86_64, or macos-aarch64 (got '$RODIN_PLATFORM')" >&2
            return 1
            ;;
    esac
}

# Path of the native launcher binary for an install root; mirrors
# resolve_rodin_home's layout handling (binary at the root on Linux,
# Contents/MacOS inside the app bundle).
resolve_rodin_launcher() {
    local home

    home="$(resolve_rodin_home "$1")" || return 1
    case "$home" in
        */Contents/Eclipse) printf '%s\n' "${home%/Eclipse}/MacOS/rodin" ;;
        *)                  printf '%s\n' "$home/rodin" ;;
    esac
}

remove_exact_line() {
    local file_path="$1"
    local line_to_remove="$2"
    local temp_file

    temp_file="$(mktemp)"
    grep -Fvx -- "$line_to_remove" "$file_path" >"$temp_file" || true
    mv "$temp_file" "$file_path"
}

resolve_latest_path() {
    local search_dir="$1"
    local bundle_name="$2"
    local path_type="$3"
    local name_pattern
    local find_type

    case "$path_type" in
        file)
            name_pattern="${bundle_name}_*.jar"
            find_type=f
            ;;
        dir)
            name_pattern="${bundle_name}_*"
            find_type=d
            ;;
        *)
            return 1
            ;;
    esac

    find "$search_dir" -maxdepth 1 -type "$find_type" -name "$name_pattern" -print \
        | while IFS= read -r path; do
            name="${path##*/}"
            version="${name#"$bundle_name"_}"
            version="${version%.jar}"
            printf '%s\t%s\n' "$version" "$path"
        done \
        | awk -F '\t' '{ key = $1; gsub(/[^0-9]+/, ".", key); print key "\t" $2 }' \
        | sort -t . -k1,1n -k2,2n -k3,3n -k4,4n \
        | tail -1 \
        | cut -f2-
}

resolve_latest_jar() {
    local search_dir="$1"
    local bundle_name="$2"

    resolve_latest_path "$search_dir" "$bundle_name" file
}

resolve_latest_dir() {
    local search_dir="$1"
    local bundle_name="$2"

    resolve_latest_path "$search_dir" "$bundle_name" dir
}
