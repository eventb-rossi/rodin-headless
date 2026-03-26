#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: docker run rodin-headless <command> [args...]

Commands:
  build [zips...]                Build Event-B models with Rodin (default)
  check [zips...]                Build + model-check with ProB (1000 states)
  prove [zips...]                Build + CBC invariant checking with ProB
  validate [zips...]             Build + full ProB validation (invariants + deadlock + assertions)
  autoprove [zips...]            Build + auto-prove POs with SMT/Atelier B tactics
  probcli [args...]              Run probcli directly
  help                           Show this help

Examples:
  docker run --rm -v .:/models rodin-headless model.zip
  docker run --rm -v .:/models rodin-headless build model.zip
  docker run --rm -v .:/models rodin-headless check model.zip
  docker run --rm -v .:/models rodin-headless prove model.zip
  docker run --rm -v .:/models rodin-headless validate model.zip
  docker run --rm -v .:/models rodin-headless autoprove model.zip
  docker run --rm -v .:/models rodin-headless probcli model.eventb -mc 500
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
