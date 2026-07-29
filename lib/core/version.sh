#!/usr/bin/env bash
# lib/core/version.sh — `pvx version` / `pvx --version`
core::cmd_version() {
  case ${1:-} in
    -h | --help)
      printf 'uso: pvx version\n\nmostra a versão instalada do pvx-core.\n'
      return 0
      ;;
  esac
  printf 'pvx %s\n' "$PVX_VERSION"
}
