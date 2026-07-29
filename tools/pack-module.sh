#!/usr/bin/env bash
# tools/pack-module.sh <diretório-do-módulo> — empacota um módulo em tarball de release,
# gerando SHA256SUMS na raiz do pacote. Uso: tools/pack-module.sh modules/dummy
#
# Gera dist/pvx-mod-<nome>-<versão>.tar.gz + dist/pvx-mod-<nome>-<versão>.tar.gz.sha256,
# com o diretório de topo dentro do tarball sendo "<nome>-<versão>/".
set -Eeuo pipefail

_TOOLS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TOOLS_DIR/.." && pwd)
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require color log json registry
color::init
log::init

if [[ $# -lt 1 ]]; then
  printf 'uso: %s <diretório-do-módulo>\n' "$0" >&2
  exit 2
fi
module_dir=$1

if [[ ! -d $module_dir ]]; then
  log::error 'diretório não encontrado: %s' "$module_dir"
  exit 1
fi
module_json="$module_dir/module.json"
if [[ ! -r $module_json ]]; then
  log::error 'module.json não encontrado em %s' "$module_dir"
  exit 1
fi

registry::validate_module_json "$module_json" || exit 6

name=$(registry::module_field "$module_json" .name)
version=$(registry::module_field "$module_json" .version)
log::info 'empacotando módulo %s versão %s' "$name" "$version"

stage_root=$(pvx::tmpdir)/pack-stage
rm -rf "$stage_root"
stage="$stage_root/$name-$version"
mkdir -p "$stage"
cp -R "$module_dir"/. "$stage"/
rm -rf "$stage/.git"

(
  cd "$stage"
  while IFS= read -r -d '' f; do
    printf '%s  %s\n' "$(registry::sha256_file "$f")" "$f"
  done < <(find . -type f ! -name SHA256SUMS -print0 | sort -z)
) >"$stage/SHA256SUMS"

dist_dir="$PVX_ROOT/dist"
mkdir -p "$dist_dir"
tarball="$dist_dir/pvx-mod-$name-$version.tar.gz"
(cd "$stage_root" && tar -czf "$tarball" "$name-$version")

hash=$(registry::sha256_file "$tarball")
printf '%s  %s\n' "$hash" "$(basename "$tarball")" >"$tarball.sha256"

log::info 'gerado: %s (sha256=%s)' "$tarball" "$hash"
printf '%s\n' "$tarball"
