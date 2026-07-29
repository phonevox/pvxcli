#!/usr/bin/env bash
# tools/make-bootstrap.sh [saída] — empacota o checkout inteiro (mesmo conjunto de arquivos
# que install.sh instalaria) num único script auto-contido, com o tarball embutido em
# base64. É o 3o nível de resiliência de distribuição do pvx-core (depois do `curl | bash`
# normal e do install --file offline): pensado pro cenário "só dá pra colar texto num
# terminal SSH da central, sem git/curl/rede de saída disponível".
#
# Uso: cole o conteúdo do arquivo gerado direto num terminal, ou copie o arquivo pro host de
# destino e rode `bash pvx-bootstrap.sh` — ele se extrai num diretório temporário e roda o
# install.sh de dentro dele.
set -Eeuo pipefail

_TOOLS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TOOLS_DIR/.." && pwd)

out=${1:-$PVX_ROOT/dist/pvx-bootstrap.sh}
mkdir -p "$(dirname "$out")"

version=$(cat "$PVX_ROOT/VERSION" 2>/dev/null) || version='0.0.0-dev'

tarball=$(mktemp)
trap 'rm -f "$tarball"' EXIT

tar -C "$PVX_ROOT" -czf "$tarball" \
  --exclude=.git --exclude=dist --exclude=learning-materials --exclude=tests --exclude=modules \
  .

{
  cat <<HEADER
#!/usr/bin/env bash
# pvx-bootstrap.sh — instalador auto-contido do pvx-core $version, gerado por
# tools/make-bootstrap.sh em $(date -u +%Y-%m-%d 2>/dev/null || printf '?').
# Cole isto inteiro num terminal, ou salve como arquivo e rode "bash pvx-bootstrap.sh".
set -Eeuo pipefail

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2))); then
  printf 'pvx-bootstrap: requer bash >= 4.2 (detectado %s)\n' "\$BASH_VERSION" >&2
  exit 78
fi

_pvx_bootstrap_tmp=\$(mktemp -d)
trap 'rm -rf "\$_pvx_bootstrap_tmp"' EXIT

# base64 do GNU coreutils usa "-d"; o do macOS/BSD usa "-D" — detecta qual existe.
_pvx_b64_decode() {
  if base64 --help 2>&1 | grep -q -- '--decode'; then
    base64 -d
  else
    base64 -D
  fi
}

_pvx_b64_decode <<'PVX_PAYLOAD_B64' | tar -xzf - -C "\$_pvx_bootstrap_tmp"
HEADER
  base64 <"$tarball" # via stdin, não como argumento posicional: base64 do BSD/macOS não aceita
  cat <<'FOOTER'
PVX_PAYLOAD_B64

exec bash "$_pvx_bootstrap_tmp/install.sh" "$@"
FOOTER
} >"$out"
chmod +x "$out"

size=$(du -h "$out" 2>/dev/null | awk '{print $1}')
printf 'bootstrap gerado: %s (%s)\n' "$out" "${size:-?}"
printf '%s\n' "$out"
