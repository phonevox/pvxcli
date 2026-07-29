#!/usr/bin/env bash
# tools/make-index.sh <diretório-com-tarballs> <arquivo-de-saída.json> [base-url]
#
# Gera um registry/index.json de teste a partir de tarballs já empacotados (via
# tools/pack-module.sh), inspecionando o module.json DE DENTRO de cada tarball (não confia no
# nome do arquivo, que é ambíguo já que nomes de módulo podem ter hífen). Se dois tarballs do
# mesmo módulo existirem no diretório (ex: pra testar `pvx modules update`), usa a versão mais
# alta como a disponível no índice.
#
# base-url (opcional, default file://<diretório>) define o prefixo usado nas URLs dos tarballs
# no índice gerado — permite apontar pra um servidor http(s) real, se for o caso.
set -Eeuo pipefail

_TOOLS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TOOLS_DIR/.." && pwd)
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require color log json registry integrity
color::init
log::init

if [[ $# -lt 2 ]]; then
  printf 'uso: %s <diretório-com-tarballs> <arquivo-de-saída.json> [base-url]\n' "$0" >&2
  exit 2
fi
tarballs_dir=$1
out_file=$2
base_url=${3:-file://$(cd -P "$tarballs_dir" && pwd)}

declare -A best_version=() best_file=() best_summary=() best_command=()

for f in "$tarballs_dir"/pvx-mod-*.tar.gz; do
  [[ -e $f ]] || continue
  mj_tmp=$(pvx::tmpdir)/make-index-module.$$.json
  if ! tar -xzf "$f" -O --wildcards '*/module.json' >"$mj_tmp" 2>/dev/null; then
    # bsdtar (macOS) não aceita --wildcards; tenta sem a flag (o glob já funciona por padrão)
    tar -xzf "$f" -O '*/module.json' >"$mj_tmp" 2>/dev/null || {
      log::warn 'não consegui extrair module.json de %s — pulando' "$f"
      continue
    }
  fi

  flat=$(pvx::tmpdir)/make-index-module.$$.flat
  if ! json::flatten_file "$mj_tmp" >"$flat" 2>/dev/null; then
    log::warn 'module.json de %s não é JSON válido — pulando' "$f"
    continue
  fi

  name=$(json::get "$flat" .name 2>/dev/null) || continue
  version=$(json::get "$flat" .version 2>/dev/null) || continue
  summary=$(json::get_def "$flat" .summary '')
  command=$(json::get "$flat" .command 2>/dev/null) || command=$name

  if [[ -z ${best_version[$name]:-} ]] || [[ $(version::cmp "$version" "${best_version[$name]}") == 1 ]]; then
    best_version[$name]=$version
    best_file[$name]=$f
    best_summary[$name]=$summary
    best_command[$name]=$command
  fi
done

if ((${#best_version[@]} == 0)); then
  log::error 'nenhum tarball de módulo válido encontrado em %s' "$tarballs_dir"
  exit 1
fi

{
  printf '{\n  "schema_version": 1,\n  "registry_name": "pvx-fixture",\n  "modules": [\n'
  first=1
  for name in "${!best_version[@]}"; do
    f=${best_file[$name]}
    version=${best_version[$name]}
    sha=$(integrity::sha256_file "$f")
    size=$(wc -c <"$f" | tr -d ' ')
    ((first)) || printf ',\n'
    first=0
    printf '    {\n'
    printf '      "name": "%s",\n' "$(json::escape "$name")"
    printf '      "command": "%s",\n' "$(json::escape "${best_command[$name]}")"
    printf '      "version": "%s",\n' "$(json::escape "$version")"
    printf '      "summary": "%s",\n' "$(json::escape "${best_summary[$name]}")"
    printf '      "tarball": { "url": "%s/%s", "sha256": "%s", "size": %s }\n' \
      "$base_url" "$(basename "$f")" "$sha" "$size"
    printf '    }'
  done
  printf '\n  ]\n}\n'
} >"$out_file"

log::info 'índice gerado: %s (%d módulo(s))' "$out_file" "${#best_version[@]}"
printf '%s\n' "$out_file"
