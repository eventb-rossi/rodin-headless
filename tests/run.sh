#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMPDIRS=()

cleanup() {
    local dir
    for dir in "${TEST_TMPDIRS[@]:-}"; do
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

test_rodin_help_skips_runtime() {
    local tmpbin output marker
    tmpbin="$(new_tmpdir)"
    marker="$tmpbin/runtime-called"

    cat > "$tmpbin/docker" <<EOF
#!/usr/bin/env bash
touch "$marker"
exit 99
EOF
    cat > "$tmpbin/podman" <<EOF
#!/usr/bin/env bash
touch "$marker"
exit 99
EOF
    chmod +x "$tmpbin/docker" "$tmpbin/podman"

    output="$(PATH="$tmpbin:$PATH" "$ROOT_DIR/rodin" help)"

    assert_contains "$output" "Usage: ./rodin <command> [args...]" \
        "rodin help should print usage text"
    if [ -e "$marker" ]; then
        fail "rodin help should not invoke docker or podman"
    fi
}

test_rodin_version_uses_highest_release() {
    local tmpbin stable_output rc_output
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

    assert_contains "$stable_output" "export RODIN_VERSION='3.10'" \
        "rodin-version should select the highest stable release"
    assert_contains "$stable_output" "export RODIN_TARBALL='rodin-3.10.0-linux.gtk.x86_64.tar.gz'" \
        "rodin-version should fetch the tarball for the selected stable release"
    assert_contains "$rc_output" "export RODIN_VERSION='3.11-RC2'" \
        "rodin-version should select the highest release candidate"
    assert_contains "$rc_output" "export RODIN_TARBALL='rodin-3.11-RC2-linux.gtk.x86_64.tar.gz'" \
        "rodin-version should fetch the tarball for the selected release candidate"
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

main() {
    test_rodin_help_skips_runtime
    test_rodin_version_uses_highest_release
    test_rodin_headless_rejects_missing_archives
    printf 'PASS: %s\n' "tests/run.sh"
}

main "$@"
