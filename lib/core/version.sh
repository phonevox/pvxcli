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

  # só lê o cache de self-update (ver lib/core/self_update.sh) — nunca dispara fetch de rede
  # aqui, pra "pvx version" continuar instantâneo/scriptável mesmo com self-update configurado.
  pvx::require core/self_update
  core::_self_update_print_cached_hint
}
