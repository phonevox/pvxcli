#!/usr/bin/env bash
# lib/registry.sh — estado local de módulos instalados (installed.db) e validação de
# module.json. A leitura/escrita do índice REMOTO (registry/index.json, registry::refresh)
# fica pra quando o registry de teste existir de verdade — ver Task #9.
#
# installed.db: uma linha por módulo instalado, campos separados por "|":
#   name|version|command|installed_at|origin|source_ref|tarball_sha256|verified|core_version|files_count
# Formato de linha (não JSON) de propósito: ler JSON em bash é aceitável, ESCREVER é a parte
# perigosa (escaping, atomicidade) pro arquivo que é a fonte da verdade do que está instalado.
# Um formato de linha se atualiza com `grep -v` + `mv` atômico e é legível a olho nu no console
# por um técnico.

# PVX_STATE_DIR/PVX_CACHE_DIR já vêm exportados por bin/pvx (é o mesmo valor que o dispatcher
# usa pra resolver symlinks em commands/) — usar essa variável diretamente aqui, em vez de
# path::get pvx_state, garante que cmd_modules.sh (que cria os symlinks) e bin/pvx (que os lê
# pra despachar) nunca divirjam sobre onde fica o estado. Defaults próprios aqui só pra esta
# lib funcionar de forma standalone (testes, dev de módulo fora do bin/pvx).
PVX_STATE_DIR=${PVX_STATE_DIR:-${PVX_ROOT_PREFIX:-}/var/lib/pvx}
PVX_CACHE_DIR=${PVX_CACHE_DIR:-${PVX_ROOT_PREFIX:-}/var/cache/pvx}

_PVX_LOCK_FD=''

# registry::sha256_file <arquivo> — hash criptográfico real (sem fallback não-criptográfico:
# isto é usado pra VERIFICAÇÃO DE INTEGRIDADE de tarball, ao contrário de json::_hash_file que
# só invalida cache). Compartilhado por tools/pack-module.sh e lib/cmd_modules.sh.
registry::sha256_file() {
  local file=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    log::error 'nem sha256sum nem shasum disponíveis — não é possível verificar integridade'
    return 1
  fi
}

# --- lock exclusivo (best-effort se `flock` não existir, ex. macOS) ---------------------------
lock::acquire() {
  local timeout=${1:-10} lockfile
  lockfile=$(path::get pvx_lock)
  mkdir -p "$(dirname "$lockfile")" 2>/dev/null || true
  if ! command -v flock >/dev/null 2>&1; then
    log::warn 'comando flock não encontrado — prosseguindo sem lock exclusivo (best-effort)'
    return 0
  fi
  exec {_PVX_LOCK_FD}>>"$lockfile" || return 1
  if ! flock -w "$timeout" "$_PVX_LOCK_FD"; then
    exec {_PVX_LOCK_FD}>&-
    _PVX_LOCK_FD=''
    log::error 'não foi possível obter o lock de %s em %ss (outro pvx rodando?)' "$lockfile" "$timeout"
    return 10
  fi
  return 0
}

lock::release() {
  if [[ -n $_PVX_LOCK_FD ]]; then
    exec {_PVX_LOCK_FD}>&-
    _PVX_LOCK_FD=''
  fi
  return 0
}

# --- comparação de versão (semver-ish, com sufixo de pré-release) -----------------------------
# version::cmp <a> <b> -> imprime 0 (iguais) / 1 (a>b) / 2 (a<b)
version::cmp() {
  local a=$1 b=$2
  local a_core=$a a_pre='' b_core=$b b_pre=''
  [[ $a == *-* ]] && { a_core=${a%%-*}; a_pre=${a#*-}; }
  [[ $b == *-* ]] && { b_core=${b%%-*}; b_pre=${b#*-}; }
  local -a pa pb
  IFS='.' read -ra pa <<<"$a_core"
  IFS='.' read -ra pb <<<"$b_core"
  local i n=${#pa[@]} na nb
  ((${#pb[@]} > n)) && n=${#pb[@]}
  for ((i = 0; i < n; i++)); do
    na=${pa[i]:-0}
    nb=${pb[i]:-0}
    [[ $na =~ ^[0-9]+$ ]] || na=0
    [[ $nb =~ ^[0-9]+$ ]] || nb=0
    if ((10#$na > 10#$nb)); then
      printf '1'
      return 0
    fi
    if ((10#$na < 10#$nb)); then
      printf '2'
      return 0
    fi
  done
  # partes numéricas iguais — um sufixo de pré-release conta como "menor" que a versão release
  if [[ -z $a_pre && -n $b_pre ]]; then
    printf '1'
    return 0
  fi
  if [[ -n $a_pre && -z $b_pre ]]; then
    printf '2'
    return 0
  fi
  if [[ -n $a_pre && -n $b_pre ]]; then
    if [[ $a_pre > $b_pre ]]; then
      printf '1'
      return 0
    elif [[ $a_pre < $b_pre ]]; then
      printf '2'
      return 0
    fi
  fi
  printf '0'
  return 0
}

# version::satisfies <versão> <restrição> — restrição no formato ">=X", "<=X", ">X", "<X",
# "=X" ou "*" (qualquer versão).
version::satisfies() {
  local ver=$1 constraint=$2 op rest cmp
  if [[ -z $constraint || $constraint == '*' ]]; then
    return 0
  fi
  case $constraint in
    '>='*)
      op='>='
      rest=${constraint#>=}
      ;;
    '<='*)
      op='<='
      rest=${constraint#<=}
      ;;
    '>'*)
      op='>'
      rest=${constraint#>}
      ;;
    '<'*)
      op='<'
      rest=${constraint#<}
      ;;
    '='*)
      op='='
      rest=${constraint#=}
      ;;
    *)
      op='='
      rest=$constraint
      ;;
  esac
  cmp=$(version::cmp "$ver" "$rest")
  case $op in
    '>=') [[ $cmp == 0 || $cmp == 1 ]] ;;
    '<=') [[ $cmp == 0 || $cmp == 2 ]] ;;
    '>') [[ $cmp == 1 ]] ;;
    '<') [[ $cmp == 2 ]] ;;
    '=') [[ $cmp == 0 ]] ;;
    *) return 2 ;;
  esac
}

# --- estado local (installed.db) ---------------------------------------------------------------
registry::state_db_path() {
  printf '%s/installed.db' "$PVX_STATE_DIR"
}

registry::_state_ensure_dir() {
  mkdir -p "$PVX_STATE_DIR" 2>/dev/null || true
  return 0
}

registry::state_is_installed() {
  local name=$1 db
  db=$(registry::state_db_path)
  [[ -r $db ]] || return 1
  awk -F'|' -v n="$name" '$1 == n { found=1; exit } END { exit !found }' "$db"
}

registry::state_get() {
  local name=$1 field=$2 db idx
  db=$(registry::state_db_path)
  [[ -r $db ]] || return 1
  case $field in
    name) idx=1 ;;
    version) idx=2 ;;
    command) idx=3 ;;
    installed_at) idx=4 ;;
    origin) idx=5 ;;
    source_ref) idx=6 ;;
    tarball_sha256) idx=7 ;;
    verified) idx=8 ;;
    core_version) idx=9 ;;
    files_count) idx=10 ;;
    *)
      log::error 'registry::state_get: campo desconhecido: %s' "$field"
      return 2
      ;;
  esac
  awk -F'|' -v n="$name" -v i="$idx" '$1 == n { print $i; found=1; exit } END { exit !found }' "$db"
}

# registry::state_add_record <name> <version> <command> <origin> <source_ref> <tarball_sha256>
#                             <verified> <core_version> <files_count>
# Substitui o registro existente (se houver) — escrita atômica via arquivo temporário + mv.
registry::state_add_record() {
  local name=$1 version=$2 command=$3 origin=$4 source_ref=$5
  local sha=$6 verified=$7 core_ver=$8 files_count=$9
  local db installed_at
  registry::_state_ensure_dir
  db=$(registry::state_db_path)
  printf -v installed_at '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  lock::acquire || return 1
  {
    [[ -f $db ]] && grep -v -E -- "^${name}\|" "$db"
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$name" "$version" "$command" "$installed_at" "$origin" "$source_ref" "$sha" "$verified" "$core_ver" "$files_count"
  } >"$db.tmp"
  mv -f "$db.tmp" "$db"
  lock::release
  return 0
}

registry::state_del_record() {
  local name=$1 db
  db=$(registry::state_db_path)
  lock::acquire || return 1
  if [[ -f $db ]]; then
    grep -v -E -- "^${name}\|" "$db" >"$db.tmp" 2>/dev/null || true
    mv -f "$db.tmp" "$db"
  fi
  lock::release
  return 0
}

# registry::state_list — uma linha crua (formato installed.db) por módulo instalado.
registry::state_list() {
  local db
  db=$(registry::state_db_path)
  [[ -r $db ]] || return 0
  cat "$db"
  return 0
}

# --- validação de module.json --------------------------------------------------------------
# Nomes reservados pro core — um módulo não pode se chamar assim (ficaria inalcançável, já que
# o dispatcher sempre resolve comandos core primeiro).
declare -ga PVX_RESERVED_COMMAND_NAMES=(
  modules completion help version doctor config cache paths log self-update
)

registry::_is_reserved_command() {
  local cmd=$1 r
  for r in "${PVX_RESERVED_COMMAND_NAMES[@]}"; do
    [[ $cmd == "$r" ]] && return 0
  done
  return 1
}

# registry::validate_module_json <caminho-do-module.json> — valida schema/campos. Não checa
# nada de filesystem além da leitura do próprio arquivo (entrypoint existir/ser executável é
# responsabilidade de quem instala, que já tem o diretório extraído em mãos).
registry::validate_module_json() {
  local file=$1 flat name command version entrypoint schema_version
  if [[ ! -r $file ]]; then
    log::error 'module.json não encontrado ou sem permissão de leitura: %s' "$file"
    return 6
  fi
  flat=$(pvx::tmpdir)/module_validate.$$.flat
  if ! json::flatten_file "$file" >"$flat" 2>/dev/null; then
    log::error 'module.json não é um JSON válido: %s' "$file"
    return 6
  fi

  schema_version=$(json::get "$flat" .schema_version 2>/dev/null) || schema_version=''
  if [[ $schema_version != 1 ]]; then
    log::error 'module.json: "schema_version" deve ser 1 (obtido: %s)' "${schema_version:-<ausente>}"
    return 6
  fi

  name=$(json::get "$flat" .name 2>/dev/null) || name=''
  if [[ ! $name =~ ^[a-z][a-z0-9-]{1,31}$ ]]; then
    log::error 'module.json: "name" ausente ou fora do padrão ^[a-z][a-z0-9-]{1,31}$: %s' "${name:-<ausente>}"
    return 6
  fi

  command=$(json::get "$flat" .command 2>/dev/null) || command=''
  if [[ ! $command =~ ^[a-z][a-z0-9-]{1,31}$ ]]; then
    log::error 'module.json: "command" ausente ou fora do padrão: %s' "${command:-<ausente>}"
    return 6
  fi
  if registry::_is_reserved_command "$command"; then
    log::error 'module.json: "command" colide com um comando core reservado: %s' "$command"
    return 6
  fi

  version=$(json::get "$flat" .version 2>/dev/null) || version=''
  if [[ ! $version =~ ^[0-9]+(\.[0-9]+){0,2}(-[0-9A-Za-z.-]+)?$ ]]; then
    log::error 'module.json: "version" ausente ou mal formada: %s' "${version:-<ausente>}"
    return 6
  fi

  entrypoint=$(json::get "$flat" .entrypoint 2>/dev/null) || entrypoint=''
  if [[ -z $entrypoint ]]; then
    log::error 'module.json: "entrypoint" ausente'
    return 6
  fi
  if [[ $entrypoint == /* || $entrypoint == *..* ]]; then
    log::error 'module.json: "entrypoint" não pode ser absoluto nem conter ".." (%s)' "$entrypoint"
    return 6
  fi

  rm -f "$flat"
  return 0
}

# registry::module_field <module.json> <campo-dotted> — atalho pra ler um campo específico
# sem o chamador precisar gerenciar o arquivo .flat intermediário.
registry::module_field() {
  local file=$1 field=$2 flat
  flat=$(pvx::tmpdir)/module_field.$$.flat
  json::flatten_file "$file" >"$flat" 2>/dev/null || return 1
  json::get "$flat" "$field"
}
