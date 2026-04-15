#!/usr/bin/env bash

find_archive_project_root() {
    local archive_root="$1"

    find "$archive_root" \
        \( -name "*.bum" -o -name "*.buc" -o -name ".project" \) \
        -exec dirname {} \; | sort -u | head -1
}
