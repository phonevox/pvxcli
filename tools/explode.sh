#!/usr/bin/env bash
# tools/explode.sh <diretório-do-módulo|tarball> [saída] — converte um módulo pvx num único
# script de texto com o tarball embutido em base64, pra colar direto num terminal SSH do
# servidor de destino sem precisar de scp/sftp (nem de rede de saída lá). Mesmo truque do
# tools/make-bootstrap.sh (que faz isso pro pvx-core inteiro), aqui só pra um módulo.
#
# Se o argumento for um diretório, empacota primeiro via tools/pack-module.sh; se já for um
# tarball (.tar.gz/.tgz), usa ele direto.
#
# No servidor de destino: cole o conteúdo do arquivo gerado num terminal (ou copie o arquivo
# pra lá e rode `bash pvx-mod-<nome>-<versão>.explode.sh`) — ele recria o tarball e já chama
# `pvx modules install --file <tarball>` direto, sem passo intermediário. Args extras dados
# ao explode.sh são repassados pro install (ex: `bash *.explode.sh --force`).
set -Eeuo pipefail

# no macOS, evita os arquivos-sidecar "._nome" (AppleDouble) que o `tar` embutiria de outra
# forma — ver o mesmo comentário em tools/pack-module.sh. Não-op no Linux.
export COPYFILE_DISABLE=1

_TOOLS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TOOLS_DIR/.." && pwd)
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require color log integrity
color::init
log::init

if [[ $# -lt 1 ]]; then
  printf 'uso: %s <diretório-do-módulo|tarball> [saída]\n' "$0" >&2
  exit 2
fi
input=$1

if [[ -d $input ]]; then
  log::info 'entrada é um diretório — empacotando via tools/pack-module.sh...'
  tarball=$("$_TOOLS_DIR/pack-module.sh" "$input") || exit $?
elif [[ -f $input ]]; then
  case $input in
    *.tar.gz | *.tgz) tarball=$input ;;
    *)
      log::error 'arquivo não parece ser um tarball (.tar.gz/.tgz): %s' "$input"
      exit 2
      ;;
  esac
else
  log::error 'caminho não encontrado: %s' "$input"
  exit 1
fi

base=$(basename "$tarball")
base=${base%.tar.gz} base=${base%.tgz}
out=${2:-$PVX_ROOT/dist/$base.explode.sh}
mkdir -p "$(dirname "$out")"

hash=$(integrity::sha256_file "$tarball")

{
  cat <<HEADER
#!/usr/bin/env bash
# $base.explode.sh — módulo pvx empacotado num blob auto-contido (base64), gerado por
# tools/explode.sh em $(date -u +%Y-%m-%d 2>/dev/null || printf '?').
# Cole isto inteiro num terminal (ou salve e rode "bash $base.explode.sh") — recria
# "$base.tar.gz" e já roda "pvx modules install --file ..." direto. Args extras (ex:
# --force, -y) são repassados pro install.
set -Eeuo pipefail

_pvx_out=$base.tar.gz
# base64 do GNU coreutils usa "-d"; o do macOS/BSD usa "-D" — o errado falha antes de ler
# stdin, então tentar os dois em sequência é seguro.
(base64 -d 2>/dev/null || base64 -D) <<'PVX_PAYLOAD_B64' >"\$_pvx_out"
HEADER
  base64 <"$tarball" # via stdin, não como argumento posicional: base64 do BSD/macOS não aceita
  cat <<FOOTER
PVX_PAYLOAD_B64

_pvx_sha=\$(command -v sha256sum >/dev/null 2>&1 && sha256sum "\$_pvx_out" | awk '{print \$1}' || shasum -a 256 "\$_pvx_out" | awk '{print \$1}')
if [[ \$_pvx_sha != "$hash" ]]; then
  printf 'sha256 não confere (esperado $hash, obtido %s) — abortando.\n' "\$_pvx_sha" >&2
  exit 1
fi
command -v pvx >/dev/null 2>&1 || { printf 'pvx não encontrado no PATH.\n' >&2; exit 127; }
exec pvx modules install --file "\$_pvx_out" --sha256 "$hash" "\$@"
FOOTER
} >"$out"
chmod +x "$out"

out_size=$(du -h "$out" 2>/dev/null | awk '{print $1}')
log::info 'explodido: %s (%s) — payload original sha256=%s' "$out" "${out_size:-?}" "$hash"
printf '%s\n' "$out"
