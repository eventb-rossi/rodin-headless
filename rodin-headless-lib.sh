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

    grep -v "^\s*at " "$output_file" | grep -v "^\.\.\." | grep -v "^$" || true
    rm -f "$output_file"
    return "$status"
}
