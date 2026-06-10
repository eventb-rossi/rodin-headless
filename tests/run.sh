#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMPDIRS=()

cleanup() {
    local dir
    # ${arr[@]+...} keeps the empty-array case alive under bash 3.2's
    # set -u (stock macOS), where "${arr[@]:-}" yields a bogus empty word.
    for dir in ${TEST_TMPDIRS[@]+"${TEST_TMPDIRS[@]}"}; do
        rm -rf "$dir"
    done
}
trap cleanup EXIT

new_tmpdir() {
    local dir
    dir="$(mktemp -d)"
    TEST_TMPDIRS+=("$dir")
    printf '%s\n' "$dir"
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    if [ "$expected" != "$actual" ]; then
        fail "$message (expected '$expected', got '$actual')"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        fail "$message (missing '$needle')"
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        fail "$message (unexpected '$needle')"
    fi
}

assert_fails_with() {
    local expected_substring="$1"
    shift

    local output status
    set +e
    output="$("$@" 2>&1)"
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        fail "expected command to fail: $*"
    fi
    assert_contains "$output" "$expected_substring" \
        "failing command should report the expected error"
}

# Stub docker+podman so any container-runtime invocation trips a marker.
make_runtime_tripwire_stubs() {
    local tmpbin="$1" marker="$2" engine

    for engine in docker podman; do
        cat > "$tmpbin/$engine" <<EOF
#!/usr/bin/env bash
touch "$marker"
exit 99
EOF
        chmod +x "$tmpbin/$engine"
    done
}

# Stub docker so `image inspect` reports an existing amd64 image and any
# other invocation records its args to $RODIN_TEST_ARGS.
make_docker_args_stub() {
    local tmpbin="$1"

    cat > "$tmpbin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1 $2" in
    "image inspect")
        if [ "${3:-}" = "--format" ]; then
            printf '%s\n' amd64
        fi
        exit 0
        ;;
esac

printf '<%s>\n' "$@" > "$RODIN_TEST_ARGS"
EOF
    chmod +x "$tmpbin/docker"
}

# Stub docker so `image inspect` reports no image and build/run record
# their args to $RODIN_TEST_BUILD_ARGS / $RODIN_TEST_RUN_ARGS.
make_docker_buildrun_stub() {
    local tmpbin="$1"

    cat > "$tmpbin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1 $2" in
    "image inspect")
        exit 1
        ;;
esac

case "$1" in
    build)
        printf '<%s>\n' "$@" > "$RODIN_TEST_BUILD_ARGS"
        exit 0
        ;;
    run)
        printf '<%s>\n' "$@" > "$RODIN_TEST_RUN_ARGS"
        exit 0
        ;;
    *)
        printf 'unexpected docker args: %s\n' "$*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$tmpbin/docker"
}

# Stub uname so platform detection sees the given OS and architecture.
make_uname_stub() {
    local tmpbin="$1" os="$2" arch="$3"

    cat > "$tmpbin/uname" <<EOF
#!/usr/bin/env bash
set -euo pipefail

case "\${1:-}" in
    -s) printf '%s\n' "$os" ;;
    -m) printf '%s\n' "$arch" ;;
    *)  /usr/bin/uname "\$@" ;;
esac
EOF
    chmod +x "$tmpbin/uname"
}

test_rodin_help_skips_runtime() {
    local tmpbin output marker
    tmpbin="$(new_tmpdir)"
    marker="$tmpbin/runtime-called"

    make_runtime_tripwire_stubs "$tmpbin" "$marker"

    output="$(PATH="$tmpbin:$PATH" "$ROOT_DIR/rodin" help)"

    assert_contains "$output" "Usage: ./rodin <command> [args...]" \
        "rodin help should print usage text"
    if [ -e "$marker" ]; then
        fail "rodin help should not invoke docker or podman"
    fi
}

test_rodin_version_uses_highest_release() {
    local tmpbin stable_output rc_output pinned_output
    tmpbin="$(new_tmpdir)"

    cat > "$tmpbin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url="${@: -1}"

case "$url" in
    */Core_Rodin_Platform/)
        cat <<'OUT'
{"name":"3.8"}
{"name":"3.10-RC1"}
{"name":"3.9"}
{"name":"3.11-RC2"}
{"name":"3.10"}
OUT
        ;;
    */Core_Rodin_Platform/3.10/)
        printf '%s\n' 'rodin-3.10.0-linux.gtk.x86_64.tar.gz'
        ;;
    */Core_Rodin_Platform/3.11-RC2/)
        printf '%s\n' 'rodin-3.11-RC2-linux.gtk.x86_64.tar.gz'
        ;;
    *)
        printf 'unexpected url: %s\n' "$url" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$tmpbin/curl"

    stable_output="$(PATH="$tmpbin:$PATH" "$ROOT_DIR/rodin-version.sh")"
    rc_output="$(PATH="$tmpbin:$PATH" "$ROOT_DIR/rodin-version.sh" latest-rc)"
    pinned_output="$(PATH="$tmpbin:$PATH" "$ROOT_DIR/rodin-version.sh" 3.9 rodin-pinned.tar.gz)"

    assert_contains "$pinned_output" \
        "export RODIN_URL='https://sourceforge.net/projects/rodin-b-sharp/files/Core_Rodin_Platform/3.9/rodin-pinned.tar.gz/download'" \
        "rodin-version should emit the download URL for a pinned tarball without scraping"

    assert_contains "$stable_output" "export RODIN_VERSION='3.10'" \
        "rodin-version should select the highest stable release"
    assert_contains "$stable_output" "export RODIN_TARBALL='rodin-3.10.0-linux.gtk.x86_64.tar.gz'" \
        "rodin-version should fetch the tarball for the selected stable release"
    assert_contains "$rc_output" "export RODIN_VERSION='3.11-RC2'" \
        "rodin-version should select the highest release candidate"
    assert_contains "$rc_output" "export RODIN_TARBALL='rodin-3.11-RC2-linux.gtk.x86_64.tar.gz'" \
        "rodin-version should fetch the tarball for the selected release candidate"
}

test_prob_version_uses_highest_release() {
    local tmpbin output
    tmpbin="$(new_tmpdir)"

    cat > "$tmpbin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url="${@: -1}"

case "$url" in
    */downloads/prob/tcltk/releases/)
        cat <<'OUT'
<a href="1.15.9/">1.15.9/</a>
<a href="1.15.10/">1.15.10/</a>
<a href="1.16.0-beta/">1.16.0-beta/</a>
OUT
        ;;
    *)
        printf 'unexpected url: %s\n' "$url" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$tmpbin/curl"

    output="$(PATH="$tmpbin:$PATH" "$ROOT_DIR/prob-version.sh")"

    assert_contains "$output" "export PROB_VERSION='1.15.10'" \
        "prob-version should select the highest stable release"
    assert_contains "$output" "export PROB_URL='https://stups.hhu-hosting.de/downloads/prob/tcltk/releases/1.15.10/ProB.linux64.tar.gz'" \
        "prob-version should emit the selected release download URL"
}

test_rodin_build_forces_amd64_on_apple_silicon() {
    local tmpbin build_args_file run_args_file build_args run_args
    tmpbin="$(new_tmpdir)"
    build_args_file="$tmpbin/docker.build.args"
    run_args_file="$tmpbin/docker.run.args"

    make_docker_buildrun_stub "$tmpbin"
    make_uname_stub "$tmpbin" Darwin arm64

    RODIN_TEST_BUILD_ARGS="$build_args_file" \
    RODIN_TEST_RUN_ARGS="$run_args_file" \
    RODIN_DIR="" \
    RODIN_PREFIX="$tmpbin" \
    PATH="$tmpbin:$PATH" \
        "$ROOT_DIR/rodin" build model.zip

    build_args="$(cat "$build_args_file")"
    run_args="$(cat "$run_args_file")"
    assert_contains "$build_args" "<--platform>
<linux/amd64>" \
        "rodin wrapper should force amd64 image builds on Apple Silicon"
    assert_contains "$run_args" "<--platform>
<linux/amd64>" \
        "rodin wrapper should force amd64 container runs on Apple Silicon"
}

test_rodin_build_omits_platform_on_x86_64() {
    local tmpbin build_args_file run_args_file build_args run_args
    tmpbin="$(new_tmpdir)"
    build_args_file="$tmpbin/docker.build.args"
    run_args_file="$tmpbin/docker.run.args"

    make_docker_buildrun_stub "$tmpbin"
    make_uname_stub "$tmpbin" Linux x86_64

    # Regression test: with no platform override the wrapper must expand
    # an empty array, which is fatal on bash 3.2 with set -u when unguarded.
    RODIN_TEST_BUILD_ARGS="$build_args_file" \
    RODIN_TEST_RUN_ARGS="$run_args_file" \
    RODIN_DIR="" \
    RODIN_PREFIX="$tmpbin" \
    PATH="$tmpbin:$PATH" \
        "$ROOT_DIR/rodin" build model.zip

    build_args="$(cat "$build_args_file")"
    run_args="$(cat "$run_args_file")"
    assert_not_contains "$build_args" "<--platform>" \
        "rodin wrapper should not force a platform on x86_64 hosts"
    assert_not_contains "$run_args" "<--platform>" \
        "rodin wrapper should not force a platform on x86_64 hosts"
}

test_rodin_forwards_timeout_environment() {
    local tmpbin args_file args
    tmpbin="$(new_tmpdir)"
    args_file="$tmpbin/docker.args"

    make_docker_args_stub "$tmpbin"

    RODIN_TEST_ARGS="$args_file" \
    RODIN_BUILD_TIMEOUT=2m \
    RODIN_BUILD_TIMEOUT_KILL_AFTER=5s \
    RODIN_DIR="" \
    RODIN_PREFIX="$tmpbin" \
    PATH="$tmpbin:$PATH" \
        "$ROOT_DIR/rodin" build model.zip

    args="$(cat "$args_file")"
    assert_contains "$args" "<-e>
<RODIN_BUILD_TIMEOUT>" \
        "rodin wrapper should forward the build timeout environment"
    assert_contains "$args" "<-e>
<RODIN_BUILD_TIMEOUT_KILL_AFTER>" \
        "rodin wrapper should forward the timeout kill-after environment"
}

test_rodin_wrapper_prefers_native_install() {
    local tmpbin rodin_dir models_dir marker output status
    tmpbin="$(new_tmpdir)"
    rodin_dir="$(new_tmpdir)/rodin"
    models_dir="$(new_tmpdir)"
    marker="$tmpbin/runtime-called"

    mkdir -p "$rodin_dir"
    : > "$rodin_dir/rodin.ini"
    make_runtime_tripwire_stubs "$tmpbin" "$marker"

    set +e
    output="$(
        cd "$models_dir" \
            && RODIN_DIR="$rodin_dir" DISPLAY=:0 PATH="$tmpbin:$PATH" \
                "$ROOT_DIR/rodin" build 2>&1
    )"
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        fail "native build in an empty directory should fail"
    fi
    assert_contains "$output" "Using native Rodin at $rodin_dir" \
        "rodin wrapper should announce the native install it selected"
    assert_contains "$output" "ERROR: No .zip archives found in $models_dir" \
        "rodin wrapper should dispatch to the headless engine natively"
    if [ -e "$marker" ]; then
        fail "rodin wrapper should not invoke docker when a native install exists"
    fi
}

test_rodin_runtime_docker_overrides_native() {
    local tmpbin rodin_dir args_file args
    tmpbin="$(new_tmpdir)"
    rodin_dir="$(new_tmpdir)/rodin"
    args_file="$tmpbin/docker.args"

    mkdir -p "$rodin_dir"
    : > "$rodin_dir/rodin.ini"
    make_docker_args_stub "$tmpbin"

    RODIN_TEST_ARGS="$args_file" \
    RODIN_RUNTIME=docker \
    RODIN_DIR="$rodin_dir" \
    PATH="$tmpbin:$PATH" \
        "$ROOT_DIR/rodin" build model.zip

    args="$(cat "$args_file")"
    assert_contains "$args" "<run>" \
        "RODIN_RUNTIME=docker should dispatch to the container runtime"
    assert_contains "$args" "<rodin-headless>" \
        "container dispatch should use the rodin-headless image"
}

test_rodin_headless_rejects_missing_archives() {
    local tmpdir rodin_dir models_dir
    tmpdir="$(new_tmpdir)"
    rodin_dir="$tmpdir/rodin"
    models_dir="$tmpdir/models"
    mkdir -p "$rodin_dir" "$models_dir"

    assert_fails_with "ERROR: No .zip archives found in $models_dir" \
        env DISPLAY=:0 RODIN_DIR="$rodin_dir" MODELS_DIR="$models_dir" \
        "$ROOT_DIR/rodin-headless.sh"

    assert_fails_with "ERROR: None of the requested archives were found in $models_dir" \
        env DISPLAY=:0 RODIN_DIR="$rodin_dir" MODELS_DIR="$models_dir" \
        "$ROOT_DIR/rodin-headless.sh" missing.zip
}

test_rodin_headless_requires_prob_plugin() {
    local tmpdir rodin_dir models_dir
    tmpdir="$(new_tmpdir)"
    rodin_dir="$tmpdir/rodin"
    models_dir="$tmpdir/models"
    mkdir -p "$rodin_dir/plugins" "$models_dir"
    : > "$models_dir/model.zip"

    assert_fails_with "ERROR: ProB Rodin plugin not installed in $rodin_dir" \
        env DISPLAY=:0 RODIN_DIR="$rodin_dir" MODELS_DIR="$models_dir" \
        "$ROOT_DIR/rodin-headless.sh" model.zip
}

test_find_archive_project_root_supports_context_only_models() {
    local tmpdir actual
    tmpdir="$(new_tmpdir)"
    mkdir -p "$tmpdir/project"
    : > "$tmpdir/project/C1.buc"

    actual="$(
        . "$ROOT_DIR/rodin-headless-lib.sh"
        find_archive_project_root "$tmpdir"
    )"

    assert_eq "$tmpdir/project" "$actual" \
        "archive root detection should support context-only Event-B archives"
}

test_find_archive_project_root_falls_back_to_project_metadata() {
    local tmpdir actual
    tmpdir="$(new_tmpdir)"
    mkdir -p "$tmpdir/project"
    : > "$tmpdir/project/.project"

    actual="$(
        . "$ROOT_DIR/rodin-headless-lib.sh"
        find_archive_project_root "$tmpdir"
    )"

    assert_eq "$tmpdir/project" "$actual" \
        "archive root detection should fall back to .project when sources are absent"
}

test_run_with_filtered_output_preserves_failure_status() {
    local tmpdir command output status
    tmpdir="$(new_tmpdir)"
    command="$tmpdir/fail-command.sh"

    cat > "$command" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'kept line'
printf '%s\n' '    at hidden frame'
printf '%s\n' '...'
printf '\n'
exit 7
EOF
    chmod +x "$command"

    set +e
    output="$(
        . "$ROOT_DIR/rodin-headless-lib.sh"
        run_with_filtered_output "$command"
    )"
    status=$?
    set -e

    assert_eq "7" "$status" \
        "filtered launcher output should preserve failure exit codes"
    assert_contains "$output" "kept line" \
        "filtered launcher output should keep relevant lines"
    assert_not_contains "$output" "hidden frame" \
        "filtered launcher output should drop stack trace lines"
    assert_not_contains "$output" "..." \
        "filtered launcher output should drop folded stack trace markers"
}

test_run_with_filtered_output_preserves_success_status() {
    local tmpdir command output status
    tmpdir="$(new_tmpdir)"
    command="$tmpdir/success-command.sh"

    cat > "$command" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'success line'
exit 0
EOF
    chmod +x "$command"

    set +e
    output="$(
        . "$ROOT_DIR/rodin-headless-lib.sh"
        run_with_filtered_output "$command"
    )"
    status=$?
    set -e

    assert_eq "0" "$status" \
        "filtered launcher output should preserve success exit codes"
    assert_contains "$output" "success line" \
        "filtered launcher output should keep successful output"
}

test_run_with_optional_timeout_preserves_success_status() {
    local tmpdir tmpbin command status
    tmpdir="$(new_tmpdir)"
    tmpbin="$(new_tmpdir)"
    command="$tmpdir/success-command.sh"

    cat > "$command" <<'EOF'
#!/usr/bin/env bash
exit 3
EOF
    cat > "$tmpbin/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

while [[ "${1:-}" == --* ]]; do
    shift
done
shift
exec "$@"
EOF
    chmod +x "$command"
    chmod +x "$tmpbin/timeout"

    set +e
    (
        PATH="$tmpbin:$PATH"
        . "$ROOT_DIR/rodin-headless-lib.sh"
        run_with_optional_timeout 5s 1s "$command"
    )
    status=$?
    set -e

    assert_eq "3" "$status" \
        "timeout wrapper should preserve non-timeout command status"
}

test_run_with_optional_timeout_can_be_disabled() {
    local tmpdir command status
    tmpdir="$(new_tmpdir)"
    command="$tmpdir/disabled-command.sh"

    cat > "$command" <<'EOF'
#!/usr/bin/env bash
exit 9
EOF
    chmod +x "$command"

    set +e
    (
        . "$ROOT_DIR/rodin-headless-lib.sh"
        run_with_optional_timeout off 1s "$command"
    )
    status=$?
    set -e

    assert_eq "9" "$status" \
        "disabled timeout wrapper should run the command directly"
}

test_run_with_optional_timeout_reports_timeout() {
    local tmpbin status
    tmpbin="$(new_tmpdir)"

    cat > "$tmpbin/timeout" <<'EOF'
#!/usr/bin/env bash
exit 124
EOF
    chmod +x "$tmpbin/timeout"

    set +e
    (
        PATH="$tmpbin:$PATH"
        . "$ROOT_DIR/rodin-headless-lib.sh"
        run_with_optional_timeout 1s 1s sleep 2
    )
    status=$?
    set -e

    assert_eq "124" "$status" \
        "timeout wrapper should return GNU timeout's timeout status"
}

test_timeout_duration_parsing() {
    local seconds

    seconds="$(
        . "$ROOT_DIR/rodin-headless-lib.sh"
        timeout_duration_to_seconds 60m
    )"
    assert_eq "3600" "$seconds" "duration parsing should convert minutes"

    seconds="$(
        . "$ROOT_DIR/rodin-headless-lib.sh"
        timeout_duration_to_seconds 30s
    )"
    assert_eq "30" "$seconds" "duration parsing should convert seconds"

    seconds="$(
        . "$ROOT_DIR/rodin-headless-lib.sh"
        timeout_duration_to_seconds 7
    )"
    assert_eq "7" "$seconds" "duration parsing should accept plain seconds"

    seconds="$(
        . "$ROOT_DIR/rodin-headless-lib.sh"
        timeout_duration_to_seconds 2h
    )"
    assert_eq "7200" "$seconds" "duration parsing should convert hours"

    assert_fails_with "invalid timeout duration" \
        bash -c ". '$ROOT_DIR/rodin-headless-lib.sh'; timeout_duration_to_seconds 5x"
    assert_fails_with "invalid timeout duration" \
        bash -c ". '$ROOT_DIR/rodin-headless-lib.sh'; timeout_duration_to_seconds m"
}

test_watchdog_timeout_preserves_command_status() {
    local tmpdir command status
    tmpdir="$(new_tmpdir)"
    command="$tmpdir/fail-command.sh"

    printf '#!/bin/sh\nexit 6\n' > "$command"
    chmod +x "$command"

    set +e
    (
        . "$ROOT_DIR/rodin-headless-lib.sh"
        run_with_watchdog_timeout 5s 1s "$command"
    )
    status=$?
    set -e

    assert_eq "6" "$status" \
        "watchdog timeout should preserve the command's exit status"
}

test_watchdog_timeout_kills_overrunning_command() {
    local status

    set +e
    (
        . "$ROOT_DIR/rodin-headless-lib.sh"
        run_with_watchdog_timeout 1s 1s sleep 10
    )
    status=$?
    set -e

    assert_eq "124" "$status" \
        "watchdog timeout should report 124 when the command overruns"
}

test_run_with_optional_timeout_falls_back_to_gtimeout() {
    local tmpbin args_file args
    tmpbin="$(new_tmpdir)"
    args_file="$tmpbin/gtimeout.args"

    cat > "$tmpbin/gtimeout" <<'EOF'
#!/bin/sh
printf '<%s>\n' "$@" > "$RODIN_TEST_ARGS"
EOF
    chmod +x "$tmpbin/gtimeout"

    # PATH holds only the stub, so no real `timeout` can win; the
    # builtins the lib needs (command, printf) survive an empty PATH.
    (
        export RODIN_TEST_ARGS="$args_file"
        PATH="$tmpbin"
        . "$ROOT_DIR/rodin-headless-lib.sh"
        run_with_optional_timeout 5s 1s true
    )

    args="$(cat "$args_file")"
    assert_contains "$args" "<--kill-after=1s>" \
        "gtimeout fallback should forward the kill-after grace period"
    assert_contains "$args" "<5s>" \
        "gtimeout fallback should forward the timeout duration"
}

test_lock_helpers_acquire_and_release() {
    local tmpdir lock_file
    tmpdir="$(new_tmpdir)"
    lock_file="$tmpdir/test.lock"

    (
        . "$ROOT_DIR/rodin-headless-lib.sh"
        acquire_rodin_lock "$lock_file"
        release_rodin_lock
        acquire_rodin_lock "$lock_file"
        release_rodin_lock
    ) || fail "lock helpers should support repeated acquire/release cycles"
}

# Restrict PATH to the external tools the mkdir spinlock needs, so
# flock is never found and the fallback branch runs on any host.
make_spinlock_path() {
    local tmpbin="$1" tool

    for tool in mkdir rm cat date sleep; do
        ln -s "$(command -v "$tool")" "$tmpbin/$tool"
    done
}

test_lock_helpers_mkdir_fallback_without_flock() {
    local tmpdir tmpbin lock_file
    tmpdir="$(new_tmpdir)"
    tmpbin="$(new_tmpdir)"
    lock_file="$tmpdir/test.lock"

    make_spinlock_path "$tmpbin"

    (
        PATH="$tmpbin"
        . "$ROOT_DIR/rodin-headless-lib.sh"
        acquire_rodin_lock "$lock_file"
        [ "$RODIN_LOCK_KIND" = dir ] || exit 1
        [ -f "$lock_file.d/pid" ] || exit 1
        release_rodin_lock
        [ ! -e "$lock_file.d" ] || exit 1
    ) || fail "mkdir spinlock should acquire and release without flock"
}

test_lock_helpers_reclaim_stale_lock() {
    local tmpdir tmpbin lock_file
    tmpdir="$(new_tmpdir)"
    tmpbin="$(new_tmpdir)"
    lock_file="$tmpdir/test.lock"

    make_spinlock_path "$tmpbin"

    # A held lock whose recorded owner is long dead (out-of-range PID)
    mkdir -p "$lock_file.d"
    printf '%s\n' 4194304 > "$lock_file.d/pid"

    (
        PATH="$tmpbin"
        . "$ROOT_DIR/rodin-headless-lib.sh"
        acquire_rodin_lock "$lock_file"
        [ "$RODIN_LOCK_KIND" = dir ] || exit 1
        read -r owner < "$lock_file.d/pid"
        [ "$owner" != 4194304 ] || exit 1
        release_rodin_lock
    ) || fail "a stale mkdir spinlock should be reclaimed when its owner is dead"
}

test_rodin_headless_wraps_launch_with_timeout() {
    local script
    script="$(cat "$ROOT_DIR/rodin-headless.sh")"

    assert_contains "$script" 'RODIN_BUILD_TIMEOUT="${RODIN_BUILD_TIMEOUT:-60m}"' \
        "headless script should define a default Rodin build timeout"
    assert_contains "$script" 'run_with_optional_timeout "$RODIN_BUILD_TIMEOUT" "$RODIN_BUILD_TIMEOUT_KILL_AFTER"' \
        "headless script should wrap the Rodin launch with the timeout helper"
    assert_contains "$script" "skipping archive repackaging" \
        "headless script should avoid repackaging partial timeout results"
}

test_remove_exact_line_only_removes_matching_bundle_registration() {
    local tmpdir bundles_file
    tmpdir="$(new_tmpdir)"
    bundles_file="$tmpdir/bundles.info"

    cat > "$bundles_file" <<'EOF'
rodinbuilder.other,1.0.0,plugins/rodinbuilder_other.jar,4,false
rodinbuilder.run123,1.0.0,plugins/rodinbuilder_run123.jar,4,false
EOF

    . "$ROOT_DIR/rodin-headless-lib.sh"
    remove_exact_line "$bundles_file" \
        "rodinbuilder.run123,1.0.0,plugins/rodinbuilder_run123.jar,4,false"

    assert_contains "$(cat "$bundles_file")" \
        "rodinbuilder.other,1.0.0,plugins/rodinbuilder_other.jar,4,false" \
        "bundle cleanup should preserve unrelated registrations"
    assert_not_contains "$(cat "$bundles_file")" \
        "rodinbuilder.run123,1.0.0,plugins/rodinbuilder_run123.jar,4,false" \
        "bundle cleanup should remove only the matching registration"
}

test_resolve_latest_plugin_paths_use_version_sorting() {
    local tmpdir jar_path dir_path
    tmpdir="$(new_tmpdir)"

    : > "$tmpdir/org.eclipse.core.runtime_3.8.0.jar"
    : > "$tmpdir/org.eclipse.core.runtime_3.10.0.jar"
    : > "$tmpdir/org.eclipse.core.runtime_3.9.0.jar"
    mkdir -p "$tmpdir/de.prob.core_2.9.0" "$tmpdir/de.prob.core_10.0.0"

    jar_path="$(
        . "$ROOT_DIR/rodin-headless-lib.sh"
        resolve_latest_jar "$tmpdir" org.eclipse.core.runtime
    )"
    dir_path="$(
        . "$ROOT_DIR/rodin-headless-lib.sh"
        resolve_latest_dir "$tmpdir" de.prob.core
    )"

    assert_eq "$tmpdir/org.eclipse.core.runtime_3.10.0.jar" "$jar_path" \
        "plugin jar resolution should use version ordering"
    assert_eq "$tmpdir/de.prob.core_10.0.0" "$dir_path" \
        "plugin directory resolution should use version ordering"
}

test_prob_core_dependency_glob_uses_resolved_directory() {
    local tmpdir actual
    tmpdir="$(new_tmpdir)"
    mkdir -p "$tmpdir/de.prob.core_10.0.0/lib/dependencies"
    : > "$tmpdir/de.prob.core_10.0.0/lib/dependencies/prologlib.jar"

    actual="$(
        . "$ROOT_DIR/rodin-headless-lib.sh"
        prob_core_dir="$(resolve_latest_dir "$tmpdir" de.prob.core)"
        for jar in "$prob_core_dir"/lib/dependencies/*.jar; do
            [ -f "$jar" ] && printf '%s\n' "$jar"
        done
    )"

    assert_eq "$tmpdir/de.prob.core_10.0.0/lib/dependencies/prologlib.jar" "$actual" \
        "ProB dependency discovery should join the resolved directory with /lib/dependencies"
}

test_validate_deadlock_check_uses_eventb_true_ast() {
    local script
    script="$(cat "$ROOT_DIR/rodin-headless.sh")"

    assert_contains "$script" "FormulaUtils.printPredicate" \
        "validate should translate an Event-B predicate into a raw Prolog AST"
    assert_contains "$script" "Formula.BTRUE" \
        "validate should build the Event-B TRUE predicate for deadlock checking"
    assert_contains "$script" 'resolve_latest_jar "$RODIN_PLUGINS" org.eventb.core.ast' \
        "validate should compile against the Event-B AST bundle"
    assert_contains "$script" "new ConstraintBasedDeadlockCheckCommand(makeTruePredicateTerm())" \
        "validate should pass the translated TRUE predicate into deadlock checking"
    assert_not_contains "$script" "new CompoundPrologTerm(\"truth\")" \
        "validate should not pass the unsupported truth atom to ProB"
    assert_not_contains "$script" "grep -oP" \
        "headless script should avoid GNU-only grep -P"
}

make_rodin_fixture_tarball() {
    local destination="$1"
    local staging

    staging="$(new_tmpdir)"
    mkdir -p "$staging/rodin/plugins"
    printf '#!/bin/sh\nexit 0\n' > "$staging/rodin/rodin"
    chmod +x "$staging/rodin/rodin"
    printf -- '-startup\nplugins/launcher.jar\n' > "$staging/rodin/rodin.ini"
    printf 'name=Rodin Platform\nversion=4.34.0\n' > "$staging/rodin/.eclipseproduct"
    : > "$staging/rodin/plugins/org.eclipse.equinox.launcher_1.6.400.jar"
    tar czf "$destination" -C "$staging" rodin
}

make_prob_fixture_tarball() {
    local destination="$1"
    local staging

    staging="$(new_tmpdir)"
    mkdir -p "$staging/prob"
    printf '#!/bin/sh\nexit 0\n' > "$staging/prob/probcli"
    chmod +x "$staging/prob/probcli"
    tar czf "$destination" -C "$staging" prob
}

make_installer_stubs() {
    local tmpbin="$1"

    cat > "$tmpbin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) target="$2"; shift 2 ;;
        -*) shift ;;
        *)  url="$1"; shift ;;
    esac
done

printf '%s\n' "$url" >> "$INSTALLER_TEST_CURL_LOG"

case "$url" in
    *rodin*) cp "$INSTALLER_TEST_RODIN_TARBALL" "$target" ;;
    *ProB*)  cp "$INSTALLER_TEST_PROB_TARBALL" "$target" ;;
    *)
        printf 'unexpected url: %s\n' "$url" >&2
        exit 1
        ;;
esac
EOF
    cat > "$tmpbin/java" <<'EOF'
#!/usr/bin/env bash
printf '<%s>\n' "$@" >> "$INSTALLER_TEST_JAVA_ARGS"
exit 0
EOF
    # Pin the platform the installer sees, so the suite runs on any
    # host; tests override via INSTALLER_TEST_OS/INSTALLER_TEST_ARCH.
    cat > "$tmpbin/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -s) printf '%s\n' "${INSTALLER_TEST_OS:-Linux}" ;;
    -m) printf '%s\n' "${INSTALLER_TEST_ARCH:-x86_64}" ;;
    *)  /usr/bin/uname "$@" ;;
esac
EOF
    chmod +x "$tmpbin/curl" "$tmpbin/java" "$tmpbin/uname"
}

# The fixtures and stubs are immutable, so they are built once for the
# whole suite; per test only the prefix and the stub logs are fresh.
INSTALLER_SUITE_BIN=""
setup_installer_fixture() {
    if [ -z "$INSTALLER_SUITE_BIN" ]; then
        INSTALLER_SUITE_BIN="$(new_tmpdir)"
        export INSTALLER_TEST_RODIN_TARBALL="$INSTALLER_SUITE_BIN/rodin-fixture.tar.gz"
        export INSTALLER_TEST_PROB_TARBALL="$INSTALLER_SUITE_BIN/prob-fixture.tar.gz"
        make_rodin_fixture_tarball "$INSTALLER_TEST_RODIN_TARBALL"
        make_prob_fixture_tarball "$INSTALLER_TEST_PROB_TARBALL"
        make_installer_stubs "$INSTALLER_SUITE_BIN"
    fi
    INSTALLER_TMPBIN="$INSTALLER_SUITE_BIN"
    INSTALLER_PREFIX="$(new_tmpdir)/install"
    export INSTALLER_TEST_CURL_LOG="$INSTALLER_TMPBIN/curl.log"
    export INSTALLER_TEST_JAVA_ARGS="$INSTALLER_TMPBIN/java.args"
    : > "$INSTALLER_TEST_CURL_LOG"
    : > "$INSTALLER_TEST_JAVA_ARGS"
}

run_installer() {
    PATH="$INSTALLER_TMPBIN:$PATH" "$ROOT_DIR/rodin-install.sh" "$@"
}

install_rodin_fixture() {
    run_installer --prefix "$INSTALLER_PREFIX" --only rodin \
        --rodin-version 3.9 --rodin-tarball rodin-3.9-linux.gtk.x86_64.tar.gz "$@"
}

test_installer_check_deps_reports_missing_tools() {
    local minbin output status
    minbin="$(new_tmpdir)"

    ln -s "$(command -v bash)" "$minbin/bash"
    ln -s "$(command -v dirname)" "$minbin/dirname"
    ln -s "$(command -v grep)" "$minbin/grep"

    set +e
    output="$(
        unset DISPLAY
        PATH="$minbin" "$ROOT_DIR/rodin-install.sh" --check-deps 2>&1
    )"
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        fail "check-deps should exit non-zero when required tools are missing"
    fi
    assert_contains "$output" "MISSING  javac" \
        "check-deps should report a missing JDK compiler"
    assert_contains "$output" "MISSING  zip" \
        "check-deps should report missing archive tools"
    assert_contains "$output" "MISSING  Xvfb" \
        "check-deps should require Xvfb when DISPLAY is unset"
    assert_contains "$output" "probcli" \
        "check-deps should report the ProB CLI install status"
}

test_installer_rejects_tarball_without_version() {
    assert_fails_with "requires a specific --rodin-version" \
        "$ROOT_DIR/rodin-install.sh" --rodin-tarball rodin-3.9-linux.gtk.x86_64.tar.gz
}

test_installer_installs_rodin_phase() {
    setup_installer_fixture

    install_rodin_fixture > /dev/null

    if [ ! -x "$INSTALLER_PREFIX/rodin/rodin" ]; then
        fail "installer should unpack an executable rodin binary"
    fi
    if [ ! -f "$INSTALLER_PREFIX/rodin/plugins/org.eclipse.equinox.launcher_1.6.400.jar" ]; then
        fail "installer should preserve the tarball plugin layout"
    fi
    assert_eq "-vm" "$(head -1 "$INSTALLER_PREFIX/rodin/rodin.ini")" \
        "installer should prepend a -vm directive to rodin.ini"
    assert_contains "$(cat "$INSTALLER_PREFIX/rodin/rodin.ini")" "$INSTALLER_TMPBIN" \
        "installer should point rodin.ini at the java directory on PATH"
    assert_contains "$(cat "$INSTALLER_TEST_CURL_LOG")" \
        "Core_Rodin_Platform/3.9/rodin-3.9-linux.gtk.x86_64.tar.gz" \
        "installer should download the pinned tarball without version detection"
}

test_installer_rodin_phase_is_idempotent() {
    setup_installer_fixture

    install_rodin_fixture > /dev/null
    local output
    output="$(install_rodin_fixture)"

    assert_contains "$output" "already installed" \
        "second install run should skip an existing Rodin install"
    # BSD wc pads its count with leading spaces
    assert_eq "1" "$(wc -l < "$INSTALLER_TEST_CURL_LOG" | tr -d ' ')" \
        "second install run should not re-download the tarball"

    install_rodin_fixture --force > /dev/null
    assert_eq "2" "$(wc -l < "$INSTALLER_TEST_CURL_LOG" | tr -d ' ')" \
        "--force should re-download and reinstall"
}

test_installer_refuses_foreign_target_dir() {
    setup_installer_fixture

    mkdir -p "$INSTALLER_PREFIX/rodin"
    : > "$INSTALLER_PREFIX/rodin/precious.txt"

    assert_fails_with "Refusing to overwrite" \
        env PATH="$INSTALLER_TMPBIN:$PATH" "$ROOT_DIR/rodin-install.sh" \
            --prefix "$INSTALLER_PREFIX" --only rodin \
            --rodin-version 3.9 --rodin-tarball rodin-3.9-linux.gtk.x86_64.tar.gz
    if [ ! -f "$INSTALLER_PREFIX/rodin/precious.txt" ]; then
        fail "installer must not delete a directory that is not a Rodin install"
    fi
}

test_installer_prob_phase_runs_p2_director() {
    setup_installer_fixture

    install_rodin_fixture > /dev/null
    run_installer --prefix "$INSTALLER_PREFIX" --only prob --prob-version 1.15.1 \
        > /dev/null

    if [ ! -x "$INSTALLER_PREFIX/prob/probcli" ]; then
        fail "prob phase should unpack the ProB CLI"
    fi

    local args
    args="$(cat "$INSTALLER_TEST_JAVA_ARGS")"
    assert_contains "$args" "<org.eclipse.equinox.p2.director>" \
        "prob phase should run the p2 director"
    assert_contains "$args" "<-Djdk.xml.maxGeneralEntitySizeLimit=0>" \
        "prob phase should lift the JDK 23+ JAXP entity limits for the director"
    assert_contains "$args" "org.eclipse.equinox.launcher_1.6.400.jar" \
        "prob phase should launch the resolved equinox launcher"
    assert_contains "$args" "releases/2024-12" \
        "prob phase should compute the Eclipse release from .eclipseproduct"
    assert_contains "$args" "org.eventb.smt.feature.group,com.clearsy.atelierb.provers.feature.group,de.prob2.feature.feature.group,de.prob2.disprover.feature.feature.group,de.prob2.symbolic.feature.feature.group" \
        "prob phase should install the ProB, SMT, and Atelier B features"
    assert_not_contains "$args" "<-uninstallIU>" \
        "a fresh plugin install should not run an uninstall pass"
}

test_installer_plugin_completeness_and_force() {
    setup_installer_fixture

    install_rodin_fixture > /dev/null
    local plugins="$INSTALLER_PREFIX/rodin/plugins"
    mkdir -p "$plugins/de.prob.core_9.0.0"
    : > "$plugins/org.eventb.smt.core_1.0.0.jar"
    : > "$plugins/com.clearsy.atelierb.provers.core_1.0.0.jar"

    local output
    output="$(run_installer --prefix "$INSTALLER_PREFIX" --only prob --prob-version 1.15.1)"
    assert_contains "$output" "plugins already installed" \
        "a complete plugin set should skip the director"
    assert_not_contains "$(cat "$INSTALLER_TEST_JAVA_ARGS")" "p2.director" \
        "a complete plugin set should not invoke the p2 director"

    run_installer --prefix "$INSTALLER_PREFIX" --only prob --prob-version 1.15.1 \
        --force > /dev/null
    local args
    args="$(cat "$INSTALLER_TEST_JAVA_ARGS")"
    assert_contains "$args" "<-uninstallIU>" \
        "--force should uninstall the existing features before reinstalling"
    assert_contains "$args" "<-installIU>" \
        "--force should reinstall the features after the uninstall pass"
}

test_dockerfile_installs_headless_helper() {
    local dockerfile
    dockerfile="$(cat "$ROOT_DIR/Dockerfile")"

    assert_contains "$dockerfile" \
        "COPY --chmod=755 rodin-headless.sh rodin-headless-lib.sh entrypoint.sh" \
        "Dockerfile should copy the headless helper into the image"
    assert_contains "$dockerfile" "/usr/local/bin/" \
        "Dockerfile should install the headless scripts in /usr/local/bin"
    assert_contains "$dockerfile" \
        "COPY --chmod=755 rodin-install.sh rodin-version.sh rodin-headless-lib.sh" \
        "Dockerfile should copy the installer before the Rodin phase"
    assert_contains "$dockerfile" \
        "COPY --chmod=755 prob-version.sh /tmp/install/" \
        "Dockerfile should copy the ProB version helper in its own layer"
    assert_contains "$dockerfile" '--prefix /opt --only rodin' \
        "Dockerfile should install Rodin via the shared installer"
    assert_contains "$dockerfile" '--rodin-version "$RODIN_VERSION"' \
        "Dockerfile should forward the Rodin version build argument"
    assert_contains "$dockerfile" '${RODIN_TARBALL:+--rodin-tarball "$RODIN_TARBALL"}' \
        "Dockerfile should forward the optional tarball override"
    assert_contains "$dockerfile" '--prefix /opt --only prob' \
        "Dockerfile should install ProB via the shared installer"
    assert_contains "$dockerfile" '--prob-version "$PROB_VERSION"' \
        "Dockerfile should forward the ProB version build argument"
    assert_contains "$dockerfile" "ln -s /opt/prob/probcli /usr/local/bin/probcli" \
        "Dockerfile should expose probcli on the container PATH"
}

main() {
    test_rodin_help_skips_runtime
    test_rodin_version_uses_highest_release
    test_prob_version_uses_highest_release
    test_rodin_build_forces_amd64_on_apple_silicon
    test_rodin_build_omits_platform_on_x86_64
    test_rodin_forwards_timeout_environment
    test_rodin_wrapper_prefers_native_install
    test_rodin_runtime_docker_overrides_native
    test_rodin_headless_rejects_missing_archives
    test_rodin_headless_requires_prob_plugin
    test_find_archive_project_root_supports_context_only_models
    test_find_archive_project_root_falls_back_to_project_metadata
    test_run_with_filtered_output_preserves_failure_status
    test_run_with_filtered_output_preserves_success_status
    test_run_with_optional_timeout_preserves_success_status
    test_run_with_optional_timeout_can_be_disabled
    test_run_with_optional_timeout_reports_timeout
    test_timeout_duration_parsing
    test_watchdog_timeout_preserves_command_status
    test_watchdog_timeout_kills_overrunning_command
    test_run_with_optional_timeout_falls_back_to_gtimeout
    test_lock_helpers_acquire_and_release
    test_lock_helpers_mkdir_fallback_without_flock
    test_lock_helpers_reclaim_stale_lock
    test_rodin_headless_wraps_launch_with_timeout
    test_remove_exact_line_only_removes_matching_bundle_registration
    test_resolve_latest_plugin_paths_use_version_sorting
    test_prob_core_dependency_glob_uses_resolved_directory
    test_validate_deadlock_check_uses_eventb_true_ast
    test_installer_check_deps_reports_missing_tools
    test_installer_rejects_tarball_without_version
    test_installer_installs_rodin_phase
    test_installer_rodin_phase_is_idempotent
    test_installer_refuses_foreign_target_dir
    test_installer_prob_phase_runs_p2_director
    test_installer_plugin_completeness_and_force
    test_dockerfile_installs_headless_helper
    printf 'PASS: %s\n' "tests/run.sh"
}

main "$@"
