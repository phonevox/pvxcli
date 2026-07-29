#!/usr/bin/env bash
# uninstall.sh [--purge] — remove o pvx-core deste sistema.
#
# Por padrão preserva state/config/cache (/etc/pvx, /var/lib/pvx, /var/cache/pvx,
# /var/log/pvx) — mesma convenção do `pvx modules remove` (sem --purge, o histórico
# sobrevive). --purge também apaga isso.
#
# Variáveis (as mesmas do install.sh, pra desinstalar uma instalação isolada de teste):
#   PVX_INSTALL_PREFIX / PVX_INSTALL_BIN
set -Eeuo pipefail

PREFIX=${PVX_INSTALL_PREFIX:-/opt/pvx}
BIN_LINK=${PVX_INSTALL_BIN:-/usr/local/bin/pvx}
purge=0
[[ ${1:-} == --purge ]] && purge=1

if [[ -z ${PVX_INSTALL_PREFIX:-} ]] && ((EUID != 0)); then
  printf 'pvx: uninstall.sh precisa rodar como root (ou defina PVX_INSTALL_PREFIX)\n' >&2
  exit 1
fi

_pvx_sys_dir() {
  if [[ -n ${PVX_INSTALL_PREFIX:-} ]]; then
    printf '%s%s\n' "$PREFIX" "$1"
  else
    printf '%s\n' "$1"
  fi
}

[[ -L $BIN_LINK ]] && rm -f "$BIN_LINK"
rm -rf "$PREFIX"
rm -f "$(_pvx_sys_dir /etc/bash_completion.d)/pvx" \
  "$(_pvx_sys_dir /usr/share/bash-completion/completions)/pvx" 2>/dev/null || true

if ((purge)); then
  rm -rf "$(_pvx_sys_dir /etc/pvx)" "$(_pvx_sys_dir /var/lib/pvx)" \
    "$(_pvx_sys_dir /var/cache/pvx)" "$(_pvx_sys_dir /var/log/pvx)"
  printf 'pvx-core removido, incluindo state/config/cache (--purge).\n'
else
  printf 'pvx-core removido. state/config/cache preservados em %s, %s, %s, %s (use --purge pra apagar também).\n' \
    "$(_pvx_sys_dir /etc/pvx)" "$(_pvx_sys_dir /var/lib/pvx)" \
    "$(_pvx_sys_dir /var/cache/pvx)" "$(_pvx_sys_dir /var/log/pvx)"
fi
