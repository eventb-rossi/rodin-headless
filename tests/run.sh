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
    cat > "$tmpbin/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    -s)
        printf '%s\n' Darwin
        ;;
    -m)
        printf '%s\n' arm64
        ;;
    *)
        /usr/bin/uname "$@"
        ;;
esac
EOF
    chmod +x "$tmpbin/docker" "$tmpbin/uname"

    RODIN_TEST_BUILD_ARGS="$build_args_file" \
    RODIN_TEST_RUN_ARGS="$run_args_file" \
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

test_rodin_forwards_timeout_environment() {
    local tmpbin args_file args
    tmpbin="$(new_tmpdir)"
    args_file="$tmpbin/docker.args"

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

    RODIN_TEST_ARGS="$args_file" \
    RODIN_BUILD_TIMEOUT=2m \
    RODIN_BUILD_TIMEOUT_KILL_AFTER=5s \
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
printf '<%s>\n' "$@" > "$INSTALLER_TEST_JAVA_ARGS"
exit 0
EOF
    chmod +x "$tmpbin/curl" "$tmpbin/java"
}

run_installer() {
    local tmpbin="$1"
    shift
    INSTALLER_TEST_CURL_LOG="${INSTALLER_TEST_CURL_LOG:-/dev/null}" \
    INSTALLER_TEST_JAVA_ARGS="${INSTALLER_TEST_JAVA_ARGS:-/dev/null}" \
    PATH="$tmpbin:$PATH" \
        "$ROOT_DIR/rodin-install.sh" "$@"
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
    assert_contains "$output" "MISSING  GTK3" \
        "check-deps should report missing GTK3 libraries"
    assert_contains "$output" "probcli" \
        "check-deps should report the ProB CLI install status"
}

test_installer_installs_rodin_phase() {
    local tmpbin prefix curl_log rodin_tarball prob_tarball ini
    tmpbin="$(new_tmpdir)"
    prefix="$(new_tmpdir)/install"
    curl_log="$tmpbin/curl.log"
    rodin_tarball="$tmpbin/rodin-fixture.tar.gz"
    prob_tarball="$tmpbin/prob-fixture.tar.gz"

    make_rodin_fixture_tarball "$rodin_tarball"
    make_prob_fixture_tarball "$prob_tarball"
    make_installer_stubs "$tmpbin"

    INSTALLER_TEST_CURL_LOG="$curl_log" \
    INSTALLER_TEST_RODIN_TARBALL="$rodin_tarball" \
    INSTALLER_TEST_PROB_TARBALL="$prob_tarball" \
        run_installer "$tmpbin" --prefix "$prefix" --only rodin \
            --rodin-version 3.9 --rodin-tarball rodin-3.9-linux.gtk.x86_64.tar.gz \
            > /dev/null

    if [ ! -x "$prefix/rodin/rodin" ]; then
        fail "installer should unpack an executable rodin binary"
    fi
    if [ ! -f "$prefix/rodin/plugins/org.eclipse.equinox.launcher_1.6.400.jar" ]; then
        fail "installer should preserve the tarball plugin layout"
    fi
    ini="$(cat "$prefix/rodin/rodin.ini")"
    assert_eq "-vm" "$(head -1 "$prefix/rodin/rodin.ini")" \
        "installer should prepend a -vm directive to rodin.ini"
    assert_contains "$ini" "$tmpbin" \
        "installer should point rodin.ini at the resolved java directory"
    assert_contains "$(cat "$curl_log")" "Core_Rodin_Platform/3.9/rodin-3.9-linux.gtk.x86_64.tar.gz" \
        "installer should download the pinned tarball without version detection"
}

test_installer_rodin_phase_is_idempotent() {
    local tmpbin prefix curl_log rodin_tarball prob_tarball output
    tmpbin="$(new_tmpdir)"
    prefix="$(new_tmpdir)/install"
    curl_log="$tmpbin/curl.log"
    rodin_tarball="$tmpbin/rodin-fixture.tar.gz"
    prob_tarball="$tmpbin/prob-fixture.tar.gz"

    make_rodin_fixture_tarball "$rodin_tarball"
    make_prob_fixture_tarball "$prob_tarball"
    make_installer_stubs "$tmpbin"

    export INSTALLER_TEST_CURL_LOG="$curl_log"
    export INSTALLER_TEST_RODIN_TARBALL="$rodin_tarball"
    export INSTALLER_TEST_PROB_TARBALL="$prob_tarball"

    run_installer "$tmpbin" --prefix "$prefix" --only rodin \
        --rodin-version 3.9 --rodin-tarball rodin-3.9-linux.gtk.x86_64.tar.gz \
        > /dev/null
    output="$(run_installer "$tmpbin" --prefix "$prefix" --only rodin \
        --rodin-version 3.9 --rodin-tarball rodin-3.9-linux.gtk.x86_64.tar.gz)"

    assert_contains "$output" "already installed" \
        "second install run should skip an existing Rodin install"
    assert_eq "1" "$(wc -l < "$curl_log")" \
        "second install run should not re-download the tarball"

    run_installer "$tmpbin" --prefix "$prefix" --only rodin --force \
        --rodin-version 3.9 --rodin-tarball rodin-3.9-linux.gtk.x86_64.tar.gz \
        > /dev/null
    assert_eq "2" "$(wc -l < "$curl_log")" \
        "--force should re-download and reinstall"

    unset INSTALLER_TEST_CURL_LOG INSTALLER_TEST_RODIN_TARBALL INSTALLER_TEST_PROB_TARBALL
}

test_installer_prob_phase_runs_p2_director() {
    local tmpbin prefix curl_log java_args rodin_tarball prob_tarball args
    tmpbin="$(new_tmpdir)"
    prefix="$(new_tmpdir)/install"
    curl_log="$tmpbin/curl.log"
    java_args="$tmpbin/java.args"
    rodin_tarball="$tmpbin/rodin-fixture.tar.gz"
    prob_tarball="$tmpbin/prob-fixture.tar.gz"

    make_rodin_fixture_tarball "$rodin_tarball"
    make_prob_fixture_tarball "$prob_tarball"
    make_installer_stubs "$tmpbin"

    export INSTALLER_TEST_CURL_LOG="$curl_log"
    export INSTALLER_TEST_RODIN_TARBALL="$rodin_tarball"
    export INSTALLER_TEST_PROB_TARBALL="$prob_tarball"
    export INSTALLER_TEST_JAVA_ARGS="$java_args"

    run_installer "$tmpbin" --prefix "$prefix" --only rodin \
        --rodin-version 3.9 --rodin-tarball rodin-3.9-linux.gtk.x86_64.tar.gz \
        > /dev/null
    run_installer "$tmpbin" --prefix "$prefix" --only prob --prob-version 1.15.1 \
        > /dev/null

    if [ ! -x "$prefix/prob/probcli" ]; then
        fail "prob phase should unpack the ProB CLI"
    fi

    args="$(cat "$java_args")"
    assert_contains "$args" "<org.eclipse.equinox.p2.director>" \
        "prob phase should run the p2 director"
    assert_contains "$args" "org.eclipse.equinox.launcher_1.6.400.jar" \
        "prob phase should launch the resolved equinox launcher"
    assert_contains "$args" "releases/2024-12" \
        "prob phase should compute the Eclipse release from .eclipseproduct"
    assert_contains "$args" "org.eventb.smt.feature.group,com.clearsy.atelierb.provers.feature.group,de.prob2.feature.feature.group,de.prob2.disprover.feature.feature.group,de.prob2.symbolic.feature.feature.group" \
        "prob phase should install the ProB, SMT, and Atelier B features"

    unset INSTALLER_TEST_CURL_LOG INSTALLER_TEST_RODIN_TARBALL \
        INSTALLER_TEST_PROB_TARBALL INSTALLER_TEST_JAVA_ARGS
}

test_dockerfile_installs_headless_helper() {
    local dockerfile
    dockerfile="$(cat "$ROOT_DIR/Dockerfile")"

    assert_contains "$dockerfile" \
        "COPY --chmod=755 rodin-headless.sh rodin-headless-lib.sh entrypoint.sh" \
        "Dockerfile should copy the headless helper into the image"
    assert_contains "$dockerfile" "/usr/local/bin/" \
        "Dockerfile should install the headless scripts in /usr/local/bin"
    assert_contains "$dockerfile" 'rodin_env="$(/tmp/rodin-version.sh "$RODIN_VERSION")"' \
        "Dockerfile should preserve Rodin version helper failures"
    assert_contains "$dockerfile" 'prob_env="$(/tmp/prob-version.sh "$PROB_VERSION")"' \
        "Dockerfile should preserve ProB version helper failures"
}

main() {
    test_rodin_help_skips_runtime
    test_rodin_version_uses_highest_release
    test_prob_version_uses_highest_release
    test_rodin_build_forces_amd64_on_apple_silicon
    test_rodin_forwards_timeout_environment
    test_rodin_headless_rejects_missing_archives
    test_find_archive_project_root_supports_context_only_models
    test_find_archive_project_root_falls_back_to_project_metadata
    test_run_with_filtered_output_preserves_failure_status
    test_run_with_filtered_output_preserves_success_status
    test_run_with_optional_timeout_preserves_success_status
    test_run_with_optional_timeout_can_be_disabled
    test_run_with_optional_timeout_reports_timeout
    test_rodin_headless_wraps_launch_with_timeout
    test_remove_exact_line_only_removes_matching_bundle_registration
    test_resolve_latest_plugin_paths_use_version_sorting
    test_prob_core_dependency_glob_uses_resolved_directory
    test_validate_deadlock_check_uses_eventb_true_ast
    test_installer_check_deps_reports_missing_tools
    test_installer_installs_rodin_phase
    test_installer_rodin_phase_is_idempotent
    test_installer_prob_phase_runs_p2_director
    test_dockerfile_installs_headless_helper
    printf 'PASS: %s\n' "tests/run.sh"
}

main "$@"
