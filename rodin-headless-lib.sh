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
