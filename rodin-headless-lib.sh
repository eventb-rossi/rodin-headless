#!/usr/bin/env bash

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

    if ! command -v timeout >/dev/null 2>&1; then
        echo "ERROR: timeout command is required when RODIN_BUILD_TIMEOUT is set" >&2
        return 127
    fi

    timeout --kill-after="$kill_after" "$duration" "$@"
}

remove_exact_line() {
    local file_path="$1"
    local line_to_remove="$2"
    local temp_file

    temp_file="$(mktemp)"
    grep -Fvx -- "$line_to_remove" "$file_path" >"$temp_file" || true
    mv "$temp_file" "$file_path"
}

resolve_latest_jar() {
    local search_dir="$1"
    local bundle_name="$2"

    find "$search_dir" -maxdepth 1 -type f -name "${bundle_name}_*.jar" -print \
        | sort -V | tail -1
}

resolve_latest_dir() {
    local search_dir="$1"
    local bundle_name="$2"

    find "$search_dir" -maxdepth 1 -type d -name "${bundle_name}_*" -print \
        | sort -V | tail -1
}
