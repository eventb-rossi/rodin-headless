#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

run_probcli() {
    if ! command -v probcli >/dev/null 2>&1; then
        echo "Error: probcli not found on PATH." >&2
        echo "Run ./rodin-install.sh to install ProB, or add <prefix>/prob to PATH." >&2
        exit 1
    fi
    exec probcli "$@"
}

usage() {
    cat <<'EOF'
Usage: ./rodin <command> [args...]

Commands:
  build [zips...]                Build Event-B models with Rodin (default)
  check [zips...]                Build + model-check with ProB (1000 states)
  prove [zips...]                Build + CBC invariant checking with ProB
  validate [zips...]             Build + full ProB validation (invariants + deadlock + assertions)
  autoprove [zips...]            Build + auto-prove POs with SMT/Atelier B tactics
  probcli [args...]              Run probcli directly
  help                           Show this help

Options (anywhere after the command word):
  --strict                       Exit non-zero when any component fails
                                 Rodin's static check or was never checked
                                 (multi-project archives are rejected)

Environment:
  RODIN_BUILD_TIMEOUT            Rodin build timeout (default: 60m; off disables)
  RODIN_BUILD_TIMEOUT_KILL_AFTER Grace period after timeout (default: 30s)

Examples:
  ./rodin model.zip
  ./rodin build model.zip
  ./rodin build --strict model.zip
  ./rodin check model.zip
  ./rodin prove model.zip
  ./rodin validate model.zip
  ./rodin autoprove model.zip
  ./rodin probcli model.eventb -mc 500
EOF
}

case "${1:-}" in
    build)    shift; exec "$SCRIPT_DIR/rodin-headless.sh" "$@" ;;
    check)    shift; exec "$SCRIPT_DIR/rodin-headless.sh" --mode check "$@" ;;
    prove)    shift; exec "$SCRIPT_DIR/rodin-headless.sh" --mode prove "$@" ;;
    validate)  shift; exec "$SCRIPT_DIR/rodin-headless.sh" --mode validate "$@" ;;
    autoprove) shift; exec "$SCRIPT_DIR/rodin-headless.sh" --mode autoprove "$@" ;;
    probcli)   shift; run_probcli "$@" ;;
    help|--help|-h) usage; exit 0 ;;
    *)        exec "$SCRIPT_DIR/rodin-headless.sh" "$@" ;;
esac
