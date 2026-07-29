#!/usr/bin/env bash
# tools/add-git-module.sh <git-url> [ref] <index.json> — adiciona/atualiza no índice a
# entrada de um módulo hospedado no próprio repositório git dele (sem tarball nenhum
# envolvido). Clona (shallow, no <ref> dado ou branch padrão do repo), lê o module.json de
# dentro pra tirar name/command/version/summary — a versão é sempre a que o autor do módulo
# commitou lá, esta ferramenta nunca define isso na mão — e escreve/atualiza a entrada
# correspondente em <index.json>, preservando as outras entradas já presentes (sejam elas
# git ou tarball).
#
# <ref> pode ser uma tag, branch ou commit SHA. Se for um SHA completo (40 hex), a instalação
# a partir dessa entrada é tratada como "pinned" (imutável); senão, como "ref" (tag/branch
# podem ser movidos pelo mantenedor do módulo sem aviso — ver lib/cmd_modules.sh).
set -Eeuo pipefail

# no macOS, evita os arquivos-sidecar "._nome" (AppleDouble) que ferramentas de arquivo
# embutiriam de outra forma — não afeta git clone diretamente, mas mantém o padrão do resto
# das tools/ deste projeto. Não-op no Linux.
export COPYFILE_DISABLE=1

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

if [[ $# -lt 2 ]]; then
  printf 'uso: %s <git-url> [ref] <index.json>\n' "$0" >&2
  exit 2
fi

git_url=$1
if [[ $# -eq 2 ]]; then
  ref=''
  out_file=$2
else
  ref=$2
  out_file=$3
fi

if ! command -v git >/dev/null 2>&1; then
  log::error 'git não encontrado'
  exit 4
fi

clone_dir=$(pvx::tmpdir)/add-git-module-clone
rm -rf "$clone_dir"
declare -a clone_args=(--depth 1 --quiet)
[[ -n $ref ]] && clone_args+=(--branch "$ref")
log::info 'clonando %s%s ...' "$git_url" "${ref:+ (ref: $ref)}"
if ! git clone "${clone_args[@]}" "$git_url" "$clone_dir" >/dev/null 2>&1; then
  log::error 'falha ao clonar %s%s' "$git_url" "${ref:+ (ref: $ref)}"
  exit 4
fi

module_json="$clone_dir/module.json"
if [[ ! -r $module_json ]]; then
  log::error 'module.json não encontrado na raiz do repositório: %s' "$git_url"
  exit 6
fi
registry::validate_module_json "$module_json" || exit 6

name=$(registry::module_field "$module_json" .name)
command=$(registry::module_field "$module_json" .command)
version=$(registry::module_field "$module_json" .version)
summary=$(registry::module_field "$module_json" .summary 2>/dev/null) || summary=''

log::info 'módulo %s versão %s (git, ref=%s)' "$name" "$version" "${ref:-<branch padrão>}"

# --- lê o índice existente (se houver) pra não perder as outras entradas já publicadas ---
declare -A existing_command=() existing_version=() existing_summary=() existing_kind=()
declare -A existing_tarball_url=() existing_tarball_sha=() existing_tarball_size=()
declare -A existing_git_url=() existing_git_ref=()
declare -a existing_order=()

if [[ -r $out_file ]]; then
  existing_flat=$(pvx::tmpdir)/add-git-module.existing.flat
  if json::flatten_file "$out_file" >"$existing_flat" 2>/dev/null; then
    n=$(json::len "$existing_flat" .modules 2>/dev/null) || n=0
    for ((i = 0; i < n; i++)); do
      nm=$(json::get "$existing_flat" ".modules[$i].name" 2>/dev/null) || continue
      [[ $nm == "$name" ]] && continue # a entrada deste módulo é reescrita do zero abaixo
      existing_order+=("$nm")
      existing_command[$nm]=$(json::get_def "$existing_flat" ".modules[$i].command" "$nm")
      existing_version[$nm]=$(json::get_def "$existing_flat" ".modules[$i].version" '')
      existing_summary[$nm]=$(json::get_def "$existing_flat" ".modules[$i].summary" '')
      if json::get "$existing_flat" ".modules[$i].git.url" >/dev/null 2>&1; then
        existing_kind[$nm]=git
        existing_git_url[$nm]=$(json::get "$existing_flat" ".modules[$i].git.url")
        existing_git_ref[$nm]=$(json::get_def "$existing_flat" ".modules[$i].git.ref" '')
      else
        existing_kind[$nm]=tarball
        existing_tarball_url[$nm]=$(json::get_def "$existing_flat" ".modules[$i].tarball.url" '')
        existing_tarball_sha[$nm]=$(json::get_def "$existing_flat" ".modules[$i].tarball.sha256" '')
        existing_tarball_size[$nm]=$(json::get_def "$existing_flat" ".modules[$i].tarball.size" 0)
      fi
    done
  fi
fi

existing_order+=("$name")
existing_kind[$name]=git
existing_command[$name]=$command
existing_version[$name]=$version
existing_summary[$name]=$summary
existing_git_url[$name]=$git_url
existing_git_ref[$name]=$ref

# --- regenera o índice inteiro (mesmo padrão do tools/make-index.sh: sempre do zero, nunca
# um patch incremental do arquivo) ---
{
  printf '{\n  "schema_version": 1,\n  "registry_name": "pvx-registry",\n  "modules": [\n'
  first=1
  for nm in "${existing_order[@]}"; do
    ((first)) || printf ',\n'
    first=0
    printf '    {\n'
    printf '      "name": "%s",\n' "$(json::escape "$nm")"
    printf '      "command": "%s",\n' "$(json::escape "${existing_command[$nm]}")"
    printf '      "version": "%s",\n' "$(json::escape "${existing_version[$nm]}")"
    printf '      "summary": "%s",\n' "$(json::escape "${existing_summary[$nm]}")"
    if [[ ${existing_kind[$nm]} == git ]]; then
      if [[ -n ${existing_git_ref[$nm]} ]]; then
        printf '      "git": { "url": "%s", "ref": "%s" }\n' \
          "$(json::escape "${existing_git_url[$nm]}")" "$(json::escape "${existing_git_ref[$nm]}")"
      else
        printf '      "git": { "url": "%s" }\n' "$(json::escape "${existing_git_url[$nm]}")"
      fi
    else
      printf '      "tarball": { "url": "%s", "sha256": "%s", "size": %s }\n' \
        "$(json::escape "${existing_tarball_url[$nm]}")" "${existing_tarball_sha[$nm]}" \
        "${existing_tarball_size[$nm]}"
    fi
    printf '    }'
  done
  printf '\n  ]\n}\n'
} >"$out_file"

log::info 'índice atualizado: %s (%d módulo(s), %s agora em %s)' \
  "$out_file" "${#existing_order[@]}" "$name" "$version"
printf '%s\n' "$out_file"
