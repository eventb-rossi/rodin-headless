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

main() {
    test_rodin_help_skips_runtime
    printf 'PASS: %s\n' "tests/run.sh"
}

main "$@"
