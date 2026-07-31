#!/usr/bin/env bash
# install.sh — instala o pvx-core neste sistema a partir deste checkout (uso local ou via
# `curl ... | bash`, desde que o script já esteja no disco ao lado do resto do repo — não
# funciona "solto" via pipe, precisa do checkout completo).
#
# Idempotente: rodar de novo (mesma versão ou outra) atualiza a release e o symlink
# "current" sem tocar em state/config/cache existentes.
#
# Variáveis (opcionais, sobretudo pra teste/CI sem root):
#   PVX_INSTALL_PREFIX   raiz das releases (default /opt/pvx) — define pra instalar sem root
#   PVX_INSTALL_BIN      caminho do symlink de entrada (default /usr/local/bin/pvx)
set -Eeuo pipefail

# no macOS, evita os arquivos-sidecar "._nome" (AppleDouble) que o `tar` embutiria de outra
# forma — ver o mesmo comentário em tools/pack-module.sh. Não-op no Linux.
export COPYFILE_DISABLE=1

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2))); then
  printf 'pvx: requer bash >= 4.2 (detectado %s)\n' "$BASH_VERSION" >&2
  exit 78
fi

SRC_ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX=${PVX_INSTALL_PREFIX:-/opt/pvx}
BIN_LINK=${PVX_INSTALL_BIN:-/usr/local/bin/pvx}

if [[ -z ${PVX_INSTALL_PREFIX:-} ]] && ((EUID != 0)); then
  printf 'pvx: install.sh precisa rodar como root pra instalar em %s\n' "$PREFIX" >&2
  printf '(ou defina PVX_INSTALL_PREFIX=<dir> pra instalar em outro lugar sem privilégio)\n' >&2
  exit 1
fi

version=$(cat "$SRC_ROOT/VERSION" 2>/dev/null) || version='0.0.0-dev'
release_dir="$PREFIX/releases/$version"

printf 'instalando pvx-core %s em %s ...\n' "$version" "$release_dir"
mkdir -p "$PREFIX/releases"
rm -rf "$release_dir"
mkdir -p "$release_dir"

# copia o checkout excluindo só o que não faz sentido num sistema instalado: .git (histórico,
# não runtime), dist/ (build output regenerável) e learning-materials/ (repos de referência só
# de dev). tests/ e modules/ VÃO junto de propósito: `pvx tests` precisa continuar funcionando
# numa central com o pvx já instalado (é ferramenta de diagnóstico da própria central, não só
# de desenvolvimento do pvx-core) — e boa parte de tests/ (suites/smoke, parte de
# units/registry) depende do fixture "dummy" em modules/dummy pra rodar; excluir um sem o
# outro deixaria "pvx tests" instalado, mas falhando.
tar -C "$SRC_ROOT" -cf - \
  --exclude=.git --exclude=dist --exclude=learning-materials \
  . | tar -C "$release_dir" -xf -

ln -sfn "$release_dir" "$PREFIX/current"
mkdir -p "$(dirname "$BIN_LINK")"
ln -sfn "$PREFIX/current/bin/pvx" "$BIN_LINK"

# state/config/cache/log sempre em caminho absoluto real (/etc/pvx, /var/lib/pvx, ...) — a
# menos que PVX_INSTALL_PREFIX esteja definido (instalação isolada de teste), caso em que
# tudo fica dentro do prefix pra não vazar pro sistema real.
_pvx_sys_dir() {
  if [[ -n ${PVX_INSTALL_PREFIX:-} ]]; then
    printf '%s%s\n' "$PREFIX" "$1"
  else
    printf '%s\n' "$1"
  fi
}
mkdir -p "$(_pvx_sys_dir /etc/pvx)" "$(_pvx_sys_dir /var/lib/pvx)" \
  "$(_pvx_sys_dir /var/cache/pvx)" "$(_pvx_sys_dir /var/log/pvx)"

# completion do bash — melhor esforço, nunca falha a instalação por causa disso.
comp_src="$release_dir/completions/pvx.bash"
if [[ -r $comp_src ]]; then
  if [[ -d $(_pvx_sys_dir /etc/bash_completion.d) ]]; then
    cp "$comp_src" "$(_pvx_sys_dir /etc/bash_completion.d)/pvx" 2>/dev/null || true
  elif [[ -d $(_pvx_sys_dir /usr/share/bash-completion/completions) ]]; then
    cp "$comp_src" "$(_pvx_sys_dir /usr/share/bash-completion/completions)/pvx" 2>/dev/null || true
  fi
fi

# --- garante que o diretório de $BIN_LINK está no PATH -------------------------------------
# achado rodando de verdade numa VPS Rocky recém-provisionada via kickstart: o PATH de root
# vinha sem /usr/local/bin (só /sbin:/bin:/usr/sbin:/usr/bin) — o symlink ficava certinho, mas
# "pvx" dava "command not found" pra qualquer sessão nova, só funcionando via caminho completo.
bin_dir=$(dirname "$BIN_LINK")
if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
  profile_dir=$(_pvx_sys_dir /etc/profile.d)
  if [[ -d $profile_dir ]]; then
    printf 'export PATH="%s:$PATH"\n' "$bin_dir" >"$profile_dir/pvx-path.sh"
    chmod 0644 "$profile_dir/pvx-path.sh"
    printf 'aviso: %s não estava no PATH — %s/pvx-path.sh criado (sessões novas já funcionam).\n' \
      "$bin_dir" "$profile_dir" >&2
    printf 'nesta sessão, rode:\n' >&2
    printf '  export PATH="%s:$PATH"\n' "$bin_dir" >&2
  else
    printf 'aviso: %s não está no PATH e %s não existe pra corrigir sozinho — adicione manualmente:\n' \
      "$bin_dir" "$profile_dir" >&2
    printf '  export PATH="%s:$PATH"\n' "$bin_dir" >&2
  fi
fi

printf 'pvx-core %s instalado (%s -> %s).\n' "$version" "$BIN_LINK" "$release_dir"
printf "rode 'pvx help' pra começar.\n"
