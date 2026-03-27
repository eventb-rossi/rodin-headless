#!/usr/bin/env bash
set -euo pipefail

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

Examples:
  ./rodin model.zip
  ./rodin build model.zip
  ./rodin check model.zip
  ./rodin prove model.zip
  ./rodin validate model.zip
  ./rodin autoprove model.zip
  ./rodin probcli model.eventb -mc 500
EOF
}

case "${1:-}" in
    build)    shift; exec rodin-headless.sh "$@" ;;
    check)    shift; exec rodin-headless.sh --mode check "$@" ;;
    prove)    shift; exec rodin-headless.sh --mode prove "$@" ;;
    validate)  shift; exec rodin-headless.sh --mode validate "$@" ;;
    autoprove) shift; exec rodin-headless.sh --mode autoprove "$@" ;;
    probcli)   shift; exec probcli "$@" ;;
    help|--help|-h) usage; exit 0 ;;
    *)        exec rodin-headless.sh "$@" ;;
esac
