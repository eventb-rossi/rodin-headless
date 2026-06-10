#!/usr/bin/env bash

# Single definition of the native install location, shared by the
# installer (write side) and the rodin wrapper (detect side).
default_rodin_prefix() {
    printf '%s\n' "${RODIN_PREFIX:-${HOME:-}/.local/share/rodin-headless}"
}

# JDK 23+ ships restrictive JAXP defaults that choke on the large
# entities in Eclipse XML (update-site metadata, registries); 0 means
# unlimited, and the properties are recognized since JDK 8. Spliced
# into every equinox JVM launch (p2 director and the build engine).
JDK_XML_RELAXED_OPTS=(
    -Djdk.xml.maxGeneralEntitySizeLimit=0
    -Djdk.xml.totalEntitySizeLimit=0
)

# Resolve the de.prob.core plugin directory under a Rodin install;
# prints nothing when the plugin (or the install) is absent. The single
# definition of "this install can run the headless builder" — used by
# the wrapper's auto-detection, the engine's precheck, and the
# installer's idempotency check.
find_prob_plugin() {
    [ -d "$1/plugins" ] || return 0
    resolve_latest_dir "$1/plugins" de.prob.core
}

find_archive_project_root() {
    local archive_root="$1"

    find "$archive_root" \
        \( -name "*.bum" -o -name "*.buc" -o -name ".project" \) \
        -exec dirname {} \; | sort -u | head -1
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

# GNU timeout durations restricted to the forms the toolchain uses:
# plain seconds or N{s,m,h,d}. Fractions are rejected — the watchdog
# fallback sleeps in whole seconds.
timeout_duration_to_seconds() {
    local duration="$1" number unit

    number="${duration%[smhd]}"
    unit="${duration#"$number"}"
    case "$number" in
        "" | *[!0-9]*)
            echo "ERROR: invalid timeout duration '$duration' (expected N, Ns, Nm, Nh, or Nd)" >&2
            return 1
            ;;
    esac

    case "$unit" in
        "" | s) printf '%s\n' "$number" ;;
        m)      printf '%s\n' "$(( number * 60 ))" ;;
        h)      printf '%s\n' "$(( number * 3600 ))" ;;
        d)      printf '%s\n' "$(( number * 86400 ))" ;;
    esac
}

# Pure-shell stand-in for GNU timeout on systems without it (stock
# macOS): TERM after $duration, KILL after a further $kill_after, exit
# 124 on timeout. The killed watchdog may leave an orphaned sleep
# behind; it exits on its own and holds no resources.
run_with_watchdog_timeout() {
    local duration_s kill_after_s flag_file cmd_pid watchdog_pid status

    duration_s="$(timeout_duration_to_seconds "$1")" || return 125
    kill_after_s="$(timeout_duration_to_seconds "$2")" || return 125
    shift 2

    # A non-empty flag file marks "the watchdog fired", which beats
    # inspecting wait's status: the command may trap TERM or exit 143
    # on its own.
    flag_file="$(mktemp)"

    "$@" &
    cmd_pid=$!
    (
        sleep "$duration_s"
        printf 'timeout\n' > "$flag_file"
        kill -TERM "$cmd_pid" 2>/dev/null
        sleep "$kill_after_s"
        kill -KILL "$cmd_pid" 2>/dev/null
    ) &
    watchdog_pid=$!

    # wait's stderr is silenced to drop bash's "Terminated" job notice
    # on a timeout; the command's own stderr is untouched.
    status=0
    wait "$cmd_pid" 2>/dev/null || status=$?
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    if [ -s "$flag_file" ]; then
        rm -f "$flag_file"
        return 124
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

# Serialize Rodin launches against a shared install. flock when
# available (Linux, the container); a mkdir spinlock elsewhere — stock
# macOS ships no flock. Stale spinlocks are reclaimed when the recorded
# owner PID is gone. release_rodin_lock is idempotent and safe from an
# EXIT trap.
RODIN_LOCK_KIND=""
RODIN_LOCK_PATH=""

acquire_rodin_lock() {
    local lock_file="$1" lock_dir deadline pid

    if command -v flock >/dev/null 2>&1; then
        # Fixed descriptor: bash 3.2 has no {var}> auto-allocation.
        exec 9> "$lock_file"
        flock 9
        RODIN_LOCK_KIND=flock
        RODIN_LOCK_PATH="$lock_file"
        return 0
    fi

    lock_dir="$lock_file.d"
    deadline=$(( $(date +%s) + 600 ))
    while ! mkdir "$lock_dir" 2>/dev/null; do
        pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            rm -rf "$lock_dir"
            continue
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "ERROR: timed out waiting for lock $lock_dir (held by pid ${pid:-unknown})" >&2
            return 1
        fi
        sleep 1
    done
    printf '%s\n' "$$" > "$lock_dir/pid"
    RODIN_LOCK_KIND=dir
    RODIN_LOCK_PATH="$lock_dir"
}

release_rodin_lock() {
    case "$RODIN_LOCK_KIND" in
        flock)
            flock -u 9 2>/dev/null || true
            exec 9>&-
            ;;
        dir)
            rm -rf "$RODIN_LOCK_PATH"
            ;;
    esac
    RODIN_LOCK_KIND=""
    RODIN_LOCK_PATH=""
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
