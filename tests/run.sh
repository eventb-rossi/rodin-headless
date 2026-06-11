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

# Run a lib function in a fresh subshell (the common unit-test shape).
lib_call() {
    (
        . "$ROOT_DIR/rodin-headless-lib.sh"
        "$@"
    )
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

# Stub uname so platform detection sees the given OS and architecture;
# INSTALLER_TEST_OS/INSTALLER_TEST_ARCH override the baked-in defaults
# per invocation.
make_uname_stub() {
    local tmpbin="$1" os="$2" arch="$3"

    cat > "$tmpbin/uname" <<EOF
#!/usr/bin/env bash
set -euo pipefail

case "\${1:-}" in
    -s) printf '%s\n' "\${INSTALLER_TEST_OS:-$os}" ;;
    -m) printf '%s\n' "\${INSTALLER_TEST_ARCH:-$arch}" ;;
    *)  /usr/bin/uname "\$@" ;;
esac
EOF
    chmod +x "$tmpbin/uname"
}

# Stub launchctl so the GUI-session probe sees the given manager name
# (Aqua = desktop session, Background = ssh/cron).
make_launchctl_stub() {
    local tmpbin="$1" managername="$2"

    cat > "$tmpbin/launchctl" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
    managername) printf '%s\n' "$managername" ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$tmpbin/launchctl"
}

test_rodin_help_skips_runtime() {
    local tmpbin output marker
    tmpbin="$(new_tmpdir)"
    marker="$tmpbin/runtime-called"

    make_runtime_tripwire_stubs "$tmpbin" "$marker"

    output="$(PATH="$tmpbin:$PATH" "$ROOT_DIR/rodin" help)"

    assert_contains "$output" "Usage: ./rodin <command> [args...]" \
        "rodin help should print usage text"
    assert_contains "$output" "--strict" \
        "rodin help should document the strict flag"
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

    # Pinned to the Linux platform: the stub listings carry Linux
    # tarball names, while host detection would pick the macOS suffix
    # when the suite runs on a mac.
    stable_output="$(RODIN_PLATFORM=linux-x86_64 PATH="$tmpbin:$PATH" "$ROOT_DIR/rodin-version.sh")"
    rc_output="$(RODIN_PLATFORM=linux-x86_64 PATH="$tmpbin:$PATH" "$ROOT_DIR/rodin-version.sh" latest-rc)"
    pinned_output="$(RODIN_PLATFORM=linux-x86_64 PATH="$tmpbin:$PATH" "$ROOT_DIR/rodin-version.sh" 3.9 rodin-pinned.tar.gz)"

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

test_rodin_version_selects_platform_tarballs() {
    local tmpbin aarch64_output x86_64_output
    tmpbin="$(new_tmpdir)"

    cat > "$tmpbin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url="${@: -1}"

case "$url" in
    */Core_Rodin_Platform/3.10-RC2/)
        cat <<'OUT'
rodin-3.10.0-RC2-linux.gtk.x86_64.tar.gz
rodin-3.10.0-RC2-macosx.cocoa.aarch64.tar.gz
rodin-3.10.0-RC2-macosx.cocoa.x86_64.tar.gz
OUT
        ;;
    */Core_Rodin_Platform/3.9/)
        cat <<'OUT'
rodin-3.9.0-linux.gtk.x86_64.tar.gz
rodin-3.9.0-macosx.cocoa.x86_64.tar.gz
OUT
        ;;
    *)
        printf 'unexpected url: %s\n' "$url" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$tmpbin/curl"

    aarch64_output="$(RODIN_PLATFORM=macos-aarch64 PATH="$tmpbin:$PATH" \
        "$ROOT_DIR/rodin-version.sh" 3.10-RC2)"
    assert_contains "$aarch64_output" \
        "export RODIN_TARBALL='rodin-3.10.0-RC2-macosx.cocoa.aarch64.tar.gz'" \
        "rodin-version should select the arm64 mac tarball on macos-aarch64"

    x86_64_output="$(RODIN_PLATFORM=macos-x86_64 PATH="$tmpbin:$PATH" \
        "$ROOT_DIR/rodin-version.sh" 3.9)"
    assert_contains "$x86_64_output" \
        "export RODIN_TARBALL='rodin-3.9.0-macosx.cocoa.x86_64.tar.gz'" \
        "rodin-version should select the intel mac tarball on macos-x86_64"

    # 3.9 ships no arm64 mac build: never fall back to x86_64 (no Rosetta)
    assert_fails_with "macOS arm64 build" \
        env RODIN_PLATFORM=macos-aarch64 PATH="$tmpbin:$PATH" \
        "$ROOT_DIR/rodin-version.sh" 3.9
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

    output="$(RODIN_PLATFORM=linux-x86_64 PATH="$tmpbin:$PATH" "$ROOT_DIR/prob-version.sh")"

    assert_contains "$output" "export PROB_VERSION='1.15.10'" \
        "prob-version should select the highest stable release"
    assert_contains "$output" "export PROB_URL='https://stups.hhu-hosting.de/downloads/prob/tcltk/releases/1.15.10/ProB.linux64.tar.gz'" \
        "prob-version should emit the selected release download URL"

    output="$(RODIN_PLATFORM=macos-aarch64 PATH="$tmpbin:$PATH" "$ROOT_DIR/prob-version.sh")"
    assert_contains "$output" "export PROB_URL='https://stups.hhu-hosting.de/downloads/prob/tcltk/releases/1.15.10/ProB.macos.zip'" \
        "prob-version should emit the universal macOS archive on Darwin platforms"

    # A typo must fail loudly, not silently select the Linux archive
    assert_fails_with "RODIN_PLATFORM must be" \
        env RODIN_PLATFORM=macos PATH="$tmpbin:$PATH" "$ROOT_DIR/prob-version.sh"
    assert_fails_with "RODIN_PLATFORM must be" \
        env RODIN_PLATFORM=darwin-arm64 PATH="$tmpbin:$PATH" "$ROOT_DIR/rodin-version.sh" 3.9
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

    # RODIN_SKIP_GUI_CHECK keeps native selection deterministic when
    # the suite itself runs without a desktop session (ssh, CI).
    set +e
    output="$(
        cd "$models_dir" \
            && RODIN_DIR="$rodin_dir" DISPLAY=:0 RODIN_SKIP_GUI_CHECK=1 \
                PATH="$tmpbin:$PATH" \
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

test_darwin_gui_session_probe() {
    local tmpbin
    tmpbin="$(new_tmpdir)"
    make_uname_stub "$tmpbin" Darwin arm64
    make_launchctl_stub "$tmpbin" Background

    if PATH="$tmpbin:$PATH" lib_call darwin_gui_session_ok; then
        fail "a Background session manager should fail the GUI probe"
    fi
    PATH="$tmpbin:$PATH" RODIN_SKIP_GUI_CHECK=1 lib_call darwin_gui_session_ok \
        || fail "RODIN_SKIP_GUI_CHECK=1 should bypass the GUI probe"

    make_launchctl_stub "$tmpbin" Aqua
    PATH="$tmpbin:$PATH" lib_call darwin_gui_session_ok \
        || fail "an Aqua session should pass the GUI probe"

    make_uname_stub "$tmpbin" Linux x86_64
    PATH="$tmpbin:$PATH" lib_call darwin_gui_session_ok \
        || fail "non-Darwin hosts should always pass the GUI probe"
}

test_rodin_wrapper_falls_back_without_gui_session() {
    local tmpbin rodin_dir args_file args output
    tmpbin="$(new_tmpdir)"
    rodin_dir="$(new_tmpdir)/rodin"
    args_file="$tmpbin/docker.args"

    mkdir -p "$rodin_dir"
    : > "$rodin_dir/rodin.ini"
    make_docker_args_stub "$tmpbin"
    make_uname_stub "$tmpbin" Darwin arm64
    make_launchctl_stub "$tmpbin" Background

    output="$(
        RODIN_TEST_ARGS="$args_file" \
        RODIN_DIR="$rodin_dir" \
        PATH="$tmpbin:$PATH" \
            "$ROOT_DIR/rodin" build model.zip 2>&1
    )"

    assert_contains "$output" "no graphical session" \
        "the wrapper should say why the native install is skipped"
    args="$(cat "$args_file")"
    assert_contains "$args" "<run>" \
        "a GUI-less macOS host should fall back to the container runtime"
}

test_rodin_headless_fast_fails_without_gui_session() {
    local tmpbin tmpdir rodin_dir models_dir
    tmpbin="$(new_tmpdir)"
    tmpdir="$(new_tmpdir)"
    rodin_dir="$tmpdir/rodin"
    models_dir="$tmpdir/models"
    mkdir -p "$rodin_dir/plugins/de.prob.core_1.0.0" "$models_dir"
    : > "$models_dir/model.zip"

    make_uname_stub "$tmpbin" Darwin arm64
    make_launchctl_stub "$tmpbin" Background

    assert_fails_with "needs a logged-in graphical (Aqua) session" \
        env DISPLAY=:0 RODIN_DIR="$rodin_dir" MODELS_DIR="$models_dir" \
            PATH="$tmpbin:$PATH" \
            "$ROOT_DIR/rodin-headless.sh" model.zip
}

test_rodin_podman_mac_requires_shared_cwd() {
    local tmpbin models_dir args_file args output status
    tmpbin="$(new_tmpdir)"
    models_dir="$(new_tmpdir)"
    args_file="$tmpbin/podman.args"

    make_uname_stub "$tmpbin" Darwin arm64

    # machine inspect reports $RODIN_TEST_MOUNTS as the shared sources
    # via the podman 4.x .Mounts template, or — when that is unset, like
    # podman 5.x — points the config-file fallback at
    # $RODIN_TEST_MACHINE_CONFIG; image inspect pretends an amd64 image
    # exists; everything else records its args like the docker stubs.
    cat > "$tmpbin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1 ${2:-}" in
    "machine inspect")
        case "${4:-}" in
            *.Mounts*)
                [ -n "${RODIN_TEST_MOUNTS:-}" ] || exit 125
                printf '%s\n' "$RODIN_TEST_MOUNTS"
                ;;
            *ConfigDir*)
                printf '%s\n' "${RODIN_TEST_MACHINE_CONFIG:-}"
                ;;
        esac
        exit 0
        ;;
    "image inspect")
        if [ "${3:-}" = "--format" ]; then
            printf '%s\n' amd64
        fi
        exit 0
        ;;
esac

printf '<%s>\n' "$@" > "$RODIN_TEST_ARGS"
EOF
    chmod +x "$tmpbin/podman"

    # cwd outside every shared prefix: an actionable error, no run
    set +e
    output="$(
        cd "$models_dir" \
            && RODIN_TEST_MOUNTS='/nonexistent-prefix' RODIN_TEST_ARGS="$args_file" \
                RODIN_RUNTIME=podman RODIN_DIR="" \
                PATH="$tmpbin:$PATH" "$ROOT_DIR/rodin" build model.zip 2>&1
    )"
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        fail "podman on macOS should refuse a cwd the VM does not share"
    fi
    assert_contains "$output" "does not share" \
        "the unshared-cwd error should explain the problem"
    assert_contains "$output" "podman machine set --volume" \
        "the unshared-cwd error should show the sharing command"
    if [ -e "$args_file" ]; then
        fail "an unshared cwd should fail before any podman build/run"
    fi

    # podman 5.x: no .Mounts in machine inspect; the machine config
    # file carries the shared sources instead. Real configs are
    # single-line JSON, so several mounts share one line.
    printf '{"Mounts":[{"Source":"/nonexistent-prefix","Target":"/nonexistent-prefix","Type":"virtiofs"},{"Source":"/other-prefix","Target":"/other-prefix","Type":"virtiofs"}]}\n' \
        > "$tmpbin/machine-config.json"
    set +e
    output="$(
        cd "$models_dir" \
            && RODIN_TEST_MACHINE_CONFIG="$tmpbin/machine-config.json" \
                RODIN_TEST_ARGS="$args_file" \
                RODIN_RUNTIME=podman RODIN_DIR="" \
                PATH="$tmpbin:$PATH" "$ROOT_DIR/rodin" build model.zip 2>&1
    )"
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        fail "the config-file mount fallback should also refuse an unshared cwd"
    fi
    assert_contains "$output" "does not share" \
        "the config-file mount fallback should produce the same error"

    # The shared mount sits first on the single line: extraction must
    # see every Source, not just the line's last one
    printf '{"Mounts":[{"Source":"%s","Target":"%s","Type":"virtiofs"},{"Source":"/other-prefix","Target":"/other-prefix","Type":"virtiofs"}]}\n' \
        "$models_dir" "$models_dir" > "$tmpbin/machine-config.json"
    (
        cd "$models_dir" \
            && RODIN_TEST_MACHINE_CONFIG="$tmpbin/machine-config.json" \
                RODIN_TEST_ARGS="$args_file" \
                RODIN_RUNTIME=podman RODIN_DIR="" \
                PATH="$tmpbin:$PATH" "$ROOT_DIR/rodin" build model.zip
    )
    args="$(cat "$args_file")"
    assert_contains "$args" "<run>" \
        "a shared cwd from the config-file fallback should proceed to the run"
    rm -f "$args_file"

    # cwd under a shared prefix: dispatches to podman run as usual
    (
        cd "$models_dir" \
            && RODIN_TEST_MOUNTS="$models_dir" RODIN_TEST_ARGS="$args_file" \
                RODIN_RUNTIME=podman RODIN_DIR="" \
                PATH="$tmpbin:$PATH" "$ROOT_DIR/rodin" build model.zip
    )
    args="$(cat "$args_file")"
    assert_contains "$args" "<run>" \
        "a shared cwd should proceed to the container run"
}

test_default_rodin_prefix_requires_home_or_rodin_prefix() {
    assert_fails_with "set RODIN_PREFIX or HOME" \
        env RODIN_PREFIX= HOME= \
            bash -c ". '$ROOT_DIR/rodin-headless-lib.sh'; default_rodin_prefix"

    assert_eq "/custom/prefix" \
        "$(RODIN_PREFIX=/custom/prefix HOME='' lib_call default_rodin_prefix)" \
        "an explicit RODIN_PREFIX should not need HOME"
    assert_eq "/home/u/.local/share/rodin-headless" \
        "$(RODIN_PREFIX='' HOME=/home/u lib_call default_rodin_prefix)" \
        "the default prefix should live under HOME"
}

test_rodin_wrapper_survives_underivable_prefix() {
    local tmpbin args_file args output
    tmpbin="$(new_tmpdir)"
    args_file="$tmpbin/docker.args"

    make_docker_args_stub "$tmpbin"

    # No RODIN_PREFIX and no HOME: native detection must quietly find
    # nothing and hand over to the container runtime.
    output="$(
        RODIN_TEST_ARGS="$args_file" \
        RODIN_DIR="" RODIN_PREFIX="" HOME="" \
        PATH="$tmpbin:$PATH" \
            "$ROOT_DIR/rodin" build model.zip 2>&1
    )"

    args="$(cat "$args_file")"
    assert_contains "$args" "<run>" \
        "an underivable prefix should fall back to the container runtime"
    assert_not_contains "$output" "ERROR" \
        "the wrapper's detect side should not surface the prefix error"
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

test_resolve_rodin_home_handles_layouts() {
    local tmpdir
    tmpdir="$(new_tmpdir)"

    mkdir -p "$tmpdir/linux"
    : > "$tmpdir/linux/rodin.ini"
    mkdir -p "$tmpdir/mac/Contents/Eclipse"
    : > "$tmpdir/mac/Contents/Eclipse/rodin.ini"
    mkdir -p "$tmpdir/bundle/rodin.app/Contents/Eclipse"
    : > "$tmpdir/bundle/rodin.app/Contents/Eclipse/rodin.ini"
    mkdir -p "$tmpdir/empty"

    assert_eq "$tmpdir/linux" "$(lib_call resolve_rodin_home "$tmpdir/linux")" \
        "rodin home resolution should accept the Linux tarball layout"
    assert_eq "$tmpdir/mac/Contents/Eclipse" "$(lib_call resolve_rodin_home "$tmpdir/mac")" \
        "rodin home resolution should accept the unpacked macOS app layout"
    assert_eq "$tmpdir/bundle/rodin.app/Contents/Eclipse" \
        "$(lib_call resolve_rodin_home "$tmpdir/bundle")" \
        "rodin home resolution should accept a directory containing an app bundle"

    if lib_call resolve_rodin_home "$tmpdir/empty" >/dev/null; then
        fail "rodin home resolution should fail when no rodin.ini exists"
    fi

    # The launcher path must track the same layout knowledge
    assert_eq "$tmpdir/linux/rodin" "$(lib_call resolve_rodin_launcher "$tmpdir/linux")" \
        "launcher resolution should use the root binary on Linux layouts"
    assert_eq "$tmpdir/bundle/rodin.app/Contents/MacOS/rodin" \
        "$(lib_call resolve_rodin_launcher "$tmpdir/bundle")" \
        "launcher resolution should use the bundle binary on macOS layouts"
}

test_rodin_wrapper_detects_mac_app_bundle_install() {
    local tmpbin rodin_dir models_dir marker output status
    tmpbin="$(new_tmpdir)"
    rodin_dir="$(new_tmpdir)/rodin"
    models_dir="$(new_tmpdir)"
    marker="$tmpbin/runtime-called"

    mkdir -p "$rodin_dir/Contents/Eclipse"
    : > "$rodin_dir/Contents/Eclipse/rodin.ini"
    make_runtime_tripwire_stubs "$tmpbin" "$marker"

    set +e
    output="$(
        cd "$models_dir" \
            && RODIN_DIR="$rodin_dir" DISPLAY=:0 RODIN_SKIP_GUI_CHECK=1 \
                PATH="$tmpbin:$PATH" \
                "$ROOT_DIR/rodin" build 2>&1
    )"
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        fail "native build in an empty directory should fail"
    fi
    assert_contains "$output" "Using native Rodin at $rodin_dir" \
        "rodin wrapper should select a macOS app-bundle install"
    assert_contains "$output" "ERROR: No .zip archives found in $models_dir" \
        "rodin wrapper should dispatch the app-bundle install to the engine"
    if [ -e "$marker" ]; then
        fail "rodin wrapper should not invoke docker when an app-bundle install exists"
    fi
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

test_find_archive_project_roots_lists_every_project() {
    local tmpdir roots
    tmpdir="$(new_tmpdir)"
    mkdir -p "$tmpdir/alpha" "$tmpdir/beta"
    : > "$tmpdir/alpha/M1.bum"
    : > "$tmpdir/beta/.project"

    roots="$(lib_call find_archive_project_roots "$tmpdir")"

    assert_contains "$roots" "$tmpdir/alpha" \
        "project root listing should include source-based roots"
    assert_contains "$roots" "$tmpdir/beta" \
        "project root listing should include metadata-based roots"
    assert_eq "$tmpdir/alpha" "$(lib_call find_archive_project_root "$tmpdir")" \
        "the canonical project root should stay the first listed one"

    # Finder zips carry AppleDouble copies under __MACOSX, which sorts
    # before real project dirs and must never become the canonical root
    mkdir -p "$tmpdir/__MACOSX/alpha"
    : > "$tmpdir/__MACOSX/alpha/._M1.bum"
    roots="$(lib_call find_archive_project_roots "$tmpdir")"
    assert_not_contains "$roots" "__MACOSX" \
        "AppleDouble resource forks must not count as project roots"
    assert_eq "$tmpdir/alpha" "$(lib_call find_archive_project_root "$tmpdir")" \
        "the canonical root must not shift to the AppleDouble directory"
}

test_rodin_headless_extracts_the_project_root_dir() {
    local tmpdir rodin_dir models_dir staging output
    tmpdir="$(new_tmpdir)"
    rodin_dir="$tmpdir/rodin"
    models_dir="$tmpdir/models"
    staging="$tmpdir/staging"
    mkdir -p "$rodin_dir/plugins/de.prob.core_1.0.0" "$models_dir" \
        "$staging/docs" "$staging/proj"
    : > "$staging/docs/readme.txt"
    : > "$staging/proj/M1.bum"
    (cd "$staging" && zip -q -r "$models_dir/twin.zip" .)

    # The run dies later (no real Rodin install) — only step 1 matters.
    set +e
    output="$(
        env DISPLAY=:0 RODIN_SKIP_GUI_CHECK=1 \
            RODIN_DIR="$rodin_dir" MODELS_DIR="$models_dir" \
            "$ROOT_DIR/rodin-headless.sh" twin.zip 2>&1
    )"
    set -e

    assert_contains "$output" "twin → proj" \
        "extraction should pick the directory holding Event-B sources, not the first top-level dir"
    assert_not_contains "$output" "WARNING: twin.zip contains" \
        "a single project root must not trigger the multi-project warning"
}

test_rodin_headless_warns_on_multi_project_archives() {
    local script
    script="$(cat "$ROOT_DIR/rodin-headless.sh")"

    assert_contains "$script" "project roots; only" \
        "extraction should warn when an archive holds more than one project"
    assert_contains "$script" 'find_archive_project_roots "$tmpdir"' \
        "the warning should count roots with the shared lib helper"
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
    assert_eq "3600" "$(lib_call timeout_duration_to_seconds 60m)" \
        "duration parsing should convert minutes"
    assert_eq "30" "$(lib_call timeout_duration_to_seconds 30s)" \
        "duration parsing should convert seconds"
    assert_eq "7" "$(lib_call timeout_duration_to_seconds 7)" \
        "duration parsing should accept plain seconds"
    assert_eq "7200" "$(lib_call timeout_duration_to_seconds 2h)" \
        "duration parsing should convert hours"

    # GNU timeout accepts fractional durations; the fallback rounds up
    assert_eq "5400" "$(lib_call timeout_duration_to_seconds 1.5h)" \
        "duration parsing should convert fractional hours"
    assert_eq "1" "$(lib_call timeout_duration_to_seconds 0.5s)" \
        "duration parsing should round fractional seconds up"

    assert_fails_with "invalid timeout duration" \
        lib_call timeout_duration_to_seconds 5x
    assert_fails_with "invalid timeout duration" \
        lib_call timeout_duration_to_seconds m
    assert_fails_with "invalid timeout duration" \
        lib_call timeout_duration_to_seconds 1.2.3s
}

test_watchdog_timeout_preserves_command_status() {
    local tmpdir command status
    tmpdir="$(new_tmpdir)"
    command="$tmpdir/fail-command.sh"

    printf '#!/bin/sh\nexit 6\n' > "$command"
    chmod +x "$command"

    set +e
    lib_call run_with_watchdog_timeout 5s 1s "$command"
    status=$?
    set -e

    assert_eq "6" "$status" \
        "watchdog timeout should preserve the command's exit status"
}

test_watchdog_timeout_kills_overrunning_command() {
    local status

    set +e
    lib_call run_with_watchdog_timeout 1s 1s sleep 10
    status=$?
    set -e

    assert_eq "124" "$status" \
        "watchdog timeout should report 124 when the command overruns"
}

test_watchdog_timeout_zero_duration_disables() {
    local status

    # GNU timeout semantics: a zero duration means no timeout at all
    set +e
    lib_call run_with_watchdog_timeout 0s 1s bash -c 'exit 5'
    status=$?
    set -e

    assert_eq "5" "$status" \
        "a zero watchdog duration should run the command untimed"
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

test_seed_equinox_config_area_builds_throwaway_configuration() {
    local home config_area seeded
    home="$(new_tmpdir)"
    config_area="$(new_tmpdir)/config"

    mkdir -p "$home/configuration/org.eclipse.equinox.simpleconfigurator"
    cat > "$home/configuration/config.ini" <<'EOF'
eclipse.p2.data.area=@config.dir/../p2/
osgi.bundles.defaultStartLevel=4
EOF
    cat > "$home/configuration/org.eclipse.equinox.simpleconfigurator/bundles.info" <<'EOF'
org.eclipse.osgi,3.18.0,plugins/org.eclipse.osgi_3.18.0.jar,-1,true
de.prob.core,9.0.0,plugins/de.prob.core_9.0.0/,4,false
EOF

    mkdir -p "$config_area"
    lib_call seed_equinox_config_area "$home" "$config_area" \
        "rodinbuilder.run1,1.0.0,file:/tmp/plug/rodinbuilder_run1.jar,4,false" \
        || fail "seeding a configuration area from a complete install should succeed"

    assert_contains "$(cat "$config_area/config.ini")" \
        "eclipse.p2.data.area=file:$home/p2/" \
        "the p2 data area must stay pinned to the install, not the temp area"
    assert_contains "$(cat "$config_area/config.ini")" \
        "osgi.bundles.defaultStartLevel=4" \
        "other config.ini properties should be preserved"
    seeded="$(cat "$config_area/org.eclipse.equinox.simpleconfigurator/bundles.info")"
    assert_contains "$seeded" "org.eclipse.osgi,3.18.0" \
        "the install's bundle registrations should be copied"
    assert_contains "$seeded" \
        "rodinbuilder.run1,1.0.0,file:/tmp/plug/rodinbuilder_run1.jar,4,false" \
        "the builder bundle should be registered by absolute URI"
    assert_not_contains \
        "$(cat "$home/configuration/org.eclipse.equinox.simpleconfigurator/bundles.info")" \
        "rodinbuilder" \
        "the install's own bundles.info must stay untouched"

    # A config.ini without the key must still get the pinned data area
    # (unpinned it would resolve against the temp config area)
    printf 'osgi.bundles.defaultStartLevel=4\n' > "$home/configuration/config.ini"
    rm -rf "$config_area"
    mkdir -p "$config_area"
    lib_call seed_equinox_config_area "$home" "$config_area" \
        "x,1.0.0,file:/x.jar,4,false" \
        || fail "seeding should succeed when config.ini lacks the p2 data area key"
    assert_contains "$(cat "$config_area/config.ini")" \
        "eclipse.p2.data.area=file:$home/p2/" \
        "a missing p2 data area key should still be pinned to the install"

    assert_fails_with "not a simpleconfigurator-based" \
        lib_call seed_equinox_config_area "$(new_tmpdir)" "$config_area" \
            "x,1.0.0,file:/x.jar,4,false"
}

test_rodin_headless_uses_throwaway_configuration_area() {
    local script
    script="$(cat "$ROOT_DIR/rodin-headless.sh")"

    assert_contains "$script" 'seed_equinox_config_area "$RODIN_HOME" "$CONFIG_AREA"' \
        "the engine should seed a private configuration area"
    assert_contains "$script" '-configuration "$CONFIG_AREA"' \
        "the launch should point Equinox at the private configuration area"
    assert_not_contains "$script" "acquire_rodin_lock" \
        "a read-only install needs no launch serialization"
    assert_not_contains "$script" '-nosplash -clean' \
        "a fresh configuration area has no caches to clean"
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
    assert_contains "$script" "could not enforce RODIN_BUILD_TIMEOUT" \
        "headless script should not repackage when the timeout tool itself failed"
}

# Layout handling itself is covered behaviorally by
# test_rodin_wrapper_detects_mac_app_bundle_install; this only guards
# the SWT cocoa flag, which no test can exercise without a real JVM.
test_rodin_headless_supports_macos_layout() {
    local script
    script="$(cat "$ROOT_DIR/rodin-headless.sh")"

    assert_contains "$script" '-XstartOnFirstThread' \
        "headless script should pass SWT's cocoa first-thread flag"
    assert_contains "$script" 'if [ "$(host_os)" = Darwin ]; then' \
        "the cocoa first-thread flag must stay Darwin-conditional"
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

test_rodin_headless_reports_static_check_accuracy() {
    local script
    script="$(cat "$ROOT_DIR/rodin-headless.sh")"

    assert_contains "$script" "getSCMachineRoot()" \
        "the builder should inspect machine static-check roots"
    assert_contains "$script" "getSCContextRoot()" \
        "the builder should inspect context static-check roots"
    assert_contains "$script" "isAccurate()" \
        "the builder should read the static checker's accuracy verdict"
    assert_contains "$script" '"-Drodinbuilder.strict=$STRICT_MODE"' \
        "the launch should thread the strict flag into the JVM"
    assert_contains "$script" '--launcher.appendVmargs' \
        "the native-binary launch should append vmargs instead of replacing rodin.ini's"
    # The trailing ')' pins the RODIN_VMARGS array specifically: the
    # native-binary branch must keep passing the mode property (it was
    # silently dropped before this assertion existed).
    assert_contains "$script" '"-Drodinbuilder.mode=$BUILD_MODE" "-Drodinbuilder.strict=$STRICT_MODE")' \
        "the native-binary vmargs must carry the mode property too"
}

test_rodin_headless_parses_strict_flag() {
    local tmpdir rodin_dir models_dir
    tmpdir="$(new_tmpdir)"
    rodin_dir="$tmpdir/rodin"
    models_dir="$tmpdir/models"
    mkdir -p "$rodin_dir" "$models_dir"

    # Both flags are consumed in either order, reaching the
    # archive-selection error rather than tripping path resolution.
    assert_fails_with "ERROR: No .zip archives found in $models_dir" \
        env DISPLAY=:0 RODIN_DIR="$rodin_dir" MODELS_DIR="$models_dir" \
            "$ROOT_DIR/rodin-headless.sh" --strict --mode check
    assert_fails_with "ERROR: No .zip archives found in $models_dir" \
        env DISPLAY=:0 RODIN_DIR="$rodin_dir" MODELS_DIR="$models_dir" \
            "$ROOT_DIR/rodin-headless.sh" --mode check --strict

    # Flags may also follow archive names, and unknown options fail by
    # name instead of falling through to basename as a bogus archive.
    assert_fails_with "ERROR: None of the requested archives were found in $models_dir" \
        env DISPLAY=:0 RODIN_DIR="$rodin_dir" MODELS_DIR="$models_dir" \
            "$ROOT_DIR/rodin-headless.sh" missing.zip --strict
    assert_fails_with "unknown option '--bogus'" \
        env DISPLAY=:0 RODIN_DIR="$rodin_dir" MODELS_DIR="$models_dir" \
            "$ROOT_DIR/rodin-headless.sh" --bogus model.zip
}

test_rodin_headless_strict_rejects_multi_project_archives() {
    local tmpdir rodin_dir models_dir staging output
    tmpdir="$(new_tmpdir)"
    rodin_dir="$tmpdir/rodin"
    models_dir="$tmpdir/models"
    staging="$tmpdir/staging"
    mkdir -p "$rodin_dir/plugins/de.prob.core_1.0.0" "$models_dir" \
        "$staging/alpha" "$staging/beta"
    : > "$staging/alpha/M1.bum"
    : > "$staging/beta/M2.bum"
    (cd "$staging" && zip -q -r "$models_dir/multi.zip" .)

    # Strict promises a non-zero exit for anything never checked;
    # silently dropped projects are exactly that.
    assert_fails_with "strict mode refuses to drop" \
        env DISPLAY=:0 RODIN_SKIP_GUI_CHECK=1 \
            RODIN_DIR="$rodin_dir" MODELS_DIR="$models_dir" \
            "$ROOT_DIR/rodin-headless.sh" --strict multi.zip

    # Without strict the drop is loud but not fatal (the run dies later
    # for unrelated reasons — no real Rodin install).
    set +e
    output="$(
        env DISPLAY=:0 RODIN_SKIP_GUI_CHECK=1 \
            RODIN_DIR="$rodin_dir" MODELS_DIR="$models_dir" \
            "$ROOT_DIR/rodin-headless.sh" multi.zip 2>&1
    )"
    set -e
    assert_contains "$output" "WARNING: multi.zip contains 2 project roots" \
        "non-strict runs should warn about dropped projects"
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

# Shared Eclipse-layout content for the Rodin fixtures: the values
# feed install_prob's release arithmetic (.eclipseproduct) and the
# launcher-jar resolution, so both platform fixtures must agree.
populate_rodin_eclipse_layout() {
    local dir="$1"

    mkdir -p "$dir/plugins"
    printf -- '-startup\nplugins/launcher.jar\n' > "$dir/rodin.ini"
    printf 'name=Rodin Platform\nversion=4.34.0\n' > "$dir/.eclipseproduct"
    : > "$dir/plugins/org.eclipse.equinox.launcher_1.6.400.jar"
}

make_rodin_fixture_tarball() {
    local destination="$1"
    local staging

    staging="$(new_tmpdir)"
    mkdir -p "$staging/rodin"
    populate_rodin_eclipse_layout "$staging/rodin"
    printf '#!/bin/sh\nexit 0\n' > "$staging/rodin/rodin"
    chmod +x "$staging/rodin/rodin"
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

# The macOS Rodin tarball wraps the Eclipse layout in an app bundle.
make_rodin_mac_fixture_tarball() {
    local destination="$1"
    local staging

    staging="$(new_tmpdir)"
    mkdir -p "$staging/rodin.app/Contents/MacOS"
    populate_rodin_eclipse_layout "$staging/rodin.app/Contents/Eclipse"
    printf '#!/bin/sh\nexit 0\n' > "$staging/rodin.app/Contents/MacOS/rodin"
    chmod +x "$staging/rodin.app/Contents/MacOS/rodin"
    tar czf "$destination" -C "$staging" rodin.app
}

# The macOS ProB archive is a flat zip: probcli sits at the root.
make_prob_mac_fixture_zip() {
    local destination="$1"
    local staging

    staging="$(new_tmpdir)"
    mkdir -p "$staging/lib"
    printf '#!/bin/sh\nexit 0\n' > "$staging/probcli"
    chmod +x "$staging/probcli"
    : > "$staging/lib/probcliparser.jar"
    (cd "$staging" && zip -q -r "$destination" .)
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
    make_uname_stub "$tmpbin" Linux x86_64
    chmod +x "$tmpbin/curl" "$tmpbin/java"
}

# The fixtures and stubs are immutable, so they are built once for the
# whole suite; per test only the prefix and the stub logs are fresh.
INSTALLER_SUITE_BIN=""
setup_installer_fixture() {
    if [ -z "$INSTALLER_SUITE_BIN" ]; then
        INSTALLER_SUITE_BIN="$(new_tmpdir)"
        export INSTALLER_TEST_RODIN_TARBALL="$INSTALLER_SUITE_BIN/rodin-fixture.tar.gz"
        export INSTALLER_TEST_PROB_TARBALL="$INSTALLER_SUITE_BIN/prob-fixture.tar.gz"
        export INSTALLER_TEST_RODIN_MAC_TARBALL="$INSTALLER_SUITE_BIN/rodin-mac-fixture.tar.gz"
        export INSTALLER_TEST_PROB_MAC_ZIP="$INSTALLER_SUITE_BIN/prob-mac-fixture.zip"
        make_rodin_fixture_tarball "$INSTALLER_TEST_RODIN_TARBALL"
        make_prob_fixture_tarball "$INSTALLER_TEST_PROB_TARBALL"
        make_rodin_mac_fixture_tarball "$INSTALLER_TEST_RODIN_MAC_TARBALL"
        make_prob_mac_fixture_zip "$INSTALLER_TEST_PROB_MAC_ZIP"
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

install_darwin_rodin_fixture() {
    INSTALLER_TEST_OS=Darwin INSTALLER_TEST_ARCH=arm64 \
    INSTALLER_TEST_RODIN_TARBALL="$INSTALLER_TEST_RODIN_MAC_TARBALL" \
        run_installer --prefix "$INSTALLER_PREFIX" --only rodin \
            --rodin-version 3.10-RC2 \
            --rodin-tarball rodin-3.10.0-RC2-macosx.cocoa.aarch64.tar.gz "$@"
}

test_installer_check_deps_works_without_home() {
    local output

    # Purely diagnostic: must report even where the default prefix is
    # underivable, with only the probcli line degraded.
    set +e
    output="$(HOME='' RODIN_PREFIX='' "$ROOT_DIR/rodin-install.sh" --check-deps 2>&1)"
    set -e

    assert_contains "$output" "Runtime dependencies" \
        "check-deps should print the report when the prefix is underivable"
    assert_contains "$output" "set RODIN_PREFIX or HOME to locate an install" \
        "check-deps should degrade the probcli line, not die"
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

test_installer_darwin_installs_rodin_app_bundle() {
    setup_installer_fixture

    install_darwin_rodin_fixture > /dev/null

    if [ ! -x "$INSTALLER_PREFIX/rodin/Contents/MacOS/rodin" ]; then
        fail "darwin install should unpack an executable app-bundle launcher"
    fi
    assert_eq "-vm" "$(head -1 "$INSTALLER_PREFIX/rodin/Contents/Eclipse/rodin.ini")" \
        "darwin install should prepend the -vm directive inside the app bundle"

    local output
    output="$(install_darwin_rodin_fixture)"
    assert_contains "$output" "already installed" \
        "a second darwin install run should recognize the app-bundle layout"
}

test_installer_darwin_prob_phase_unpacks_flat_zip() {
    setup_installer_fixture

    install_darwin_rodin_fixture > /dev/null

    INSTALLER_TEST_OS=Darwin INSTALLER_TEST_ARCH=arm64 \
    INSTALLER_TEST_PROB_TARBALL="$INSTALLER_TEST_PROB_MAC_ZIP" \
        run_installer --prefix "$INSTALLER_PREFIX" --only prob --prob-version 1.15.1 \
            > /dev/null

    if [ ! -x "$INSTALLER_PREFIX/prob/probcli" ]; then
        fail "darwin prob phase should unpack probcli from the flat macOS zip"
    fi

    assert_contains "$(cat "$INSTALLER_TEST_CURL_LOG")" "ProB.macos.zip" \
        "darwin prob phase should download the universal macOS archive"

    local args
    args="$(cat "$INSTALLER_TEST_JAVA_ARGS")"
    assert_contains "$args" "<-destination>
<$INSTALLER_PREFIX/rodin/Contents/Eclipse>" \
        "darwin prob phase should aim the p2 director at the bundle's Eclipse root"
}

test_installer_records_resolved_versions() {
    setup_installer_fixture

    install_rodin_fixture > /dev/null
    assert_contains "$(cat "$INSTALLER_PREFIX/.rodin-headless-versions")" \
        "rodin=3.9" \
        "the rodin phase should record its resolved version"
    assert_contains "$(cat "$INSTALLER_PREFIX/.rodin-headless-versions")" \
        "rodin-tarball=rodin-3.9-linux.gtk.x86_64.tar.gz" \
        "the rodin phase should record the exact tarball"

    run_installer --prefix "$INSTALLER_PREFIX" --only prob --prob-version 1.15.1 \
        > /dev/null
    local manifest
    manifest="$(cat "$INSTALLER_PREFIX/.rodin-headless-versions")"
    assert_contains "$manifest" "rodin=3.9" \
        "the prob phase should preserve the rodin entry"
    assert_contains "$manifest" "prob=1.15.1" \
        "the prob phase should record its resolved version"
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
    assert_contains "$dockerfile" 'LABEL rodin.version.requested="$RODIN_VERSION"' \
        "Dockerfile should label the requested Rodin version"
    assert_contains "$dockerfile" 'rodin.tarball.requested="$RODIN_TARBALL"' \
        "Dockerfile should label any pinned tarball"
    assert_contains "$dockerfile" 'prob.version.requested="$PROB_VERSION"' \
        "Dockerfile should label the requested ProB version"
}

main() {
    local tool
    for tool in zip unzip; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            fail "$tool is required to run the test suite (used by the macOS archive fixtures)"
        fi
    done

    test_rodin_help_skips_runtime
    test_rodin_version_uses_highest_release
    test_rodin_version_selects_platform_tarballs
    test_prob_version_uses_highest_release
    test_rodin_build_forces_amd64_on_apple_silicon
    test_rodin_build_omits_platform_on_x86_64
    test_rodin_forwards_timeout_environment
    test_rodin_wrapper_prefers_native_install
    test_rodin_wrapper_detects_mac_app_bundle_install
    test_rodin_runtime_docker_overrides_native
    test_darwin_gui_session_probe
    test_rodin_wrapper_falls_back_without_gui_session
    test_rodin_headless_fast_fails_without_gui_session
    test_rodin_podman_mac_requires_shared_cwd
    test_default_rodin_prefix_requires_home_or_rodin_prefix
    test_rodin_wrapper_survives_underivable_prefix
    test_rodin_headless_rejects_missing_archives
    test_rodin_headless_requires_prob_plugin
    test_resolve_rodin_home_handles_layouts
    test_find_archive_project_root_supports_context_only_models
    test_find_archive_project_root_falls_back_to_project_metadata
    test_find_archive_project_roots_lists_every_project
    test_rodin_headless_extracts_the_project_root_dir
    test_rodin_headless_warns_on_multi_project_archives
    test_run_with_filtered_output_preserves_failure_status
    test_run_with_filtered_output_preserves_success_status
    test_run_with_optional_timeout_preserves_success_status
    test_run_with_optional_timeout_can_be_disabled
    test_run_with_optional_timeout_reports_timeout
    test_timeout_duration_parsing
    test_watchdog_timeout_preserves_command_status
    test_watchdog_timeout_kills_overrunning_command
    test_watchdog_timeout_zero_duration_disables
    test_run_with_optional_timeout_falls_back_to_gtimeout
    test_seed_equinox_config_area_builds_throwaway_configuration
    test_rodin_headless_uses_throwaway_configuration_area
    test_rodin_headless_wraps_launch_with_timeout
    test_rodin_headless_supports_macos_layout
    test_resolve_latest_plugin_paths_use_version_sorting
    test_prob_core_dependency_glob_uses_resolved_directory
    test_rodin_headless_reports_static_check_accuracy
    test_rodin_headless_parses_strict_flag
    test_rodin_headless_strict_rejects_multi_project_archives
    test_validate_deadlock_check_uses_eventb_true_ast
    test_installer_check_deps_works_without_home
    test_installer_check_deps_reports_missing_tools
    test_installer_rejects_tarball_without_version
    test_installer_installs_rodin_phase
    test_installer_rodin_phase_is_idempotent
    test_installer_refuses_foreign_target_dir
    test_installer_prob_phase_runs_p2_director
    test_installer_plugin_completeness_and_force
    test_installer_darwin_installs_rodin_app_bundle
    test_installer_darwin_prob_phase_unpacks_flat_zip
    test_installer_records_resolved_versions
    test_dockerfile_installs_headless_helper
    printf 'PASS: %s\n' "tests/run.sh"
}

main "$@"
