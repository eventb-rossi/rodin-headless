#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: docker run rodin-headless <command> [args...]

Commands:
  build [zips...]          Build Event-B models with Rodin (default)
  check <file> [opts...]   Model-check with ProB (probcli -mc 1000)
  probcli [args...]        Run probcli directly
  help                     Show this help

Examples:
  docker run --rm -v .:/models rodin-headless model.zip
  docker run --rm -v .:/models rodin-headless build model.zip
  docker run --rm -v .:/models rodin-headless check base-model/M1.bum
  docker run --rm -v .:/models rodin-headless probcli base-model/M1.bum -mc 500
EOF
}

case "${1:-}" in
    build)   shift; exec rodin-headless-build.sh "$@" ;;
    check)   shift; exec probcli -mc 1000 "$@" ;;
    probcli) shift; exec probcli "$@" ;;
    help|--help|-h) usage; exit 0 ;;
    *)       exec rodin-headless-build.sh "$@" ;;
esac
