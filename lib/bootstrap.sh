#!/usr/bin/env bash
# lib/bootstrap.sh — ponto de entrada único para bin/pvx e para módulos standalone.
#
# Precondição: o chamador já definiu PVX_ROOT e PVX_LIB_DIR antes de dar `source` neste
# arquivo (bin/pvx resolve isso de forma symlink-safe; share/pvx/module-template.sh faz o
# mesmo para um módulo rodando fora do dispatcher, ex. durante desenvolvimento).

if [[ -n ${_PVX_BOOTSTRAP_LOADED:-} ]]; then
  return 0 2>/dev/null || exit 0
fi
_PVX_BOOTSTRAP_LOADED=1

# --- piso de compatibilidade -------------------------------------------------------------
# Chamado antes de qualquer outra coisa. Usa só construções de bash muito antigas (BASH_VERSINFO
# existe desde bash 2.x) para poder reportar corretamente uma versão de bash baixa demais.
pvx::require_bash() {
  local maj=$1 min=$2
  if (( BASH_VERSINFO[0] < maj || (BASH_VERSINFO[0] == maj && BASH_VERSINFO[1] < min) )); then
    printf 'pvx: requer bash >= %d.%d (detectado %s)\n' "$maj" "$min" "$BASH_VERSION" >&2
    exit 78
  fi
}

# --- tabela de exit codes compartilhada --------------------------------------------------
# 0 ok · 1 e 3-63 livres para módulo/comando · códigos abaixo são "reservados" pelo framework
# e não devem ser reaproveitados com outro significado por módulos.
declare -gr PVX_EXIT_OK=0
declare -gr PVX_EXIT_FAILURE=1
declare -gr PVX_EXIT_USAGE=2
declare -gr PVX_EXIT_UNAVAILABLE=69
declare -gr PVX_EXIT_NOPERM=77
declare -gr PVX_EXIT_CONFIG=78
declare -gr PVX_EXIT_UNSUPPORTED=79
declare -gr PVX_EXIT_PRECONDITION=80
declare -gr PVX_EXIT_TIMEOUT=124
declare -gr PVX_EXIT_NOTFOUND=127
declare -gr PVX_EXIT_ABORTED=130

# --- source idempotente de libs -----------------------------------------------------------
pvx::require() {
  local lib f varname
  for lib in "$@"; do
    varname="_PVX_LIB_LOADED_${lib//[^a-zA-Z0-9_]/_}"
    [[ -n ${!varname:-} ]] && continue
    f="$PVX_LIB_DIR/${lib}.sh"
    if [[ ! -r $f ]]; then
      printf 'pvx: lib ausente: %s\n' "$f" >&2
      exit 78
    fi
    # shellcheck source=/dev/null
    source "$f"
    declare -g "$varname=1"
  done
}

# pvx::require_init <lib...> — pvx::require + chama <lib>::init logo depois de cada source
# (só se a função existir; a maioria das libs não tem init nenhum — só color/log/os têm hoje,
# e os::init já é lazy sozinho via os::_ensure). Pensado pro caso comum de um entrypoint de
# módulo, que não tem mais nada acontecendo entre "carregar a lib" e "inicializar ela".
#
# bin/pvx de propósito NÃO usa isto — continua chamando pvx::require puro + color::init/
# log::init manuais, porque ele precisa controlar a ORDEM entre isso e o carregamento de
# /etc/pvx/pvx.conf: color::init roda antes do config (pra existir algo pra color::set_mode
# recomputar em cima, se o config setar "color = ..."), mas log::init roda DEPOIS do config
# (pra um "log_dir = ..." do config já valer no primeiro arquivo de log aberto, não só a
# partir da próxima rotação). Auto-init aqui pra QUALQUER chamador quebraria essa ordem
# especificamente pro dispatcher — um módulo comum não tem esse problema (não lê pvx.conf
# global), por isso o atalho é seguro pra ele mas não pro bin/pvx.
pvx::require_init() {
  pvx::require "$@"
  local lib fn
  for lib in "$@"; do
    fn="${lib}::init"
    declare -F "$fn" >/dev/null 2>&1 && "$fn"
  done
}

# --- exit hooks: pilha LIFO, nunca sobrescreve `trap EXIT` de outro código -----------------
_PVX_EXIT_HOOKS=()

pvx::on_exit() {
  _PVX_EXIT_HOOKS+=("$1")
}

pvx::_run_exit_hooks() {
  local i hook
  for ((i = ${#_PVX_EXIT_HOOKS[@]} - 1; i >= 0; i--)); do
    hook=${_PVX_EXIT_HOOKS[i]}
    "$hook" || true
  done
  _PVX_EXIT_HOOKS=()
}

pvx::on_err() {
  local rc=$1 line=$2 src=$3 fn=$4
  if declare -F log::is_enabled >/dev/null 2>&1 && log::is_enabled debug; then
    log::error 'internal error (rc=%d) at %s:%d in %s' "$rc" "$src" "$line" "$fn"
    local i
    for ((i = 1; i < ${#FUNCNAME[@]} - 1; i++)); do
      log::error '  called from %s:%d in %s' \
        "${BASH_SOURCE[i+1]:-?}" "${BASH_LINENO[i]:-0}" "${FUNCNAME[i+1]:-main}"
    done
  fi
}

pvx::install_traps() {
  trap 'pvx::_run_exit_hooks' EXIT
  trap 'pvx::on_err $? "$LINENO" "${BASH_SOURCE[0]:-?}" "${FUNCNAME[0]:-main}"' ERR
  trap 'exit "$PVX_EXIT_ABORTED"' INT
  trap 'exit 143' TERM
  # pvx::invocation_id e pvx::tmpdir memoizam em globais na primeira chamada — se essa primeira
  # chamada acontecer dentro de um $(...) (comum, já que ambas "retornam" via stdout), o subshell
  # da substituição de comando perde o efeito colateral e a memoização nunca alcança o shell
  # principal. Pré-aquecer aqui, como chamada solta (não capturada), garante que toda chamada
  # posterior via $(...) já encontre o valor memoizado e seja inofensiva.
  pvx::invocation_id >/dev/null
  pvx::tmpdir >/dev/null
}

# --- erro fatal padronizado -----------------------------------------------------------------
pvx::die() {
  local code=$1
  shift
  if declare -F log::error >/dev/null 2>&1; then
    log::error '%s' "$*"
  else
    printf 'pvx: %s\n' "$*" >&2
  fi
  exit "$code"
}

# --- diretório temporário por execução, 0700, limpo automaticamente no exit ------------------
_PVX_TMPDIR=''

pvx::_cleanup_tmpdir() {
  [[ -n $_PVX_TMPDIR && -d $_PVX_TMPDIR ]] && rm -rf -- "$_PVX_TMPDIR"
  return 0
}

pvx::tmpdir() {
  if [[ -z $_PVX_TMPDIR ]]; then
    _PVX_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/pvx.XXXXXXXX") || pvx::die "$PVX_EXIT_CONFIG" \
      'não foi possível criar diretório temporário'
    chmod 0700 "$_PVX_TMPDIR"
    pvx::on_exit pvx::_cleanup_tmpdir
  fi
  printf '%s\n' "$_PVX_TMPDIR"
}

# --- id de invocação: correlaciona linhas de log do dispatcher com as do processo filho -----
PVX_INVOCATION_ID=''

pvx::invocation_id() {
  if [[ -z $PVX_INVOCATION_ID ]]; then
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
      read -r PVX_INVOCATION_ID </proc/sys/kernel/random/uuid
      PVX_INVOCATION_ID=${PVX_INVOCATION_ID//-/}
      PVX_INVOCATION_ID=${PVX_INVOCATION_ID:0:12}
    else
      PVX_INVOCATION_ID=$(printf '%x%x' "$$" "$RANDOM")
    fi
  fi
  printf '%s\n' "$PVX_INVOCATION_ID"
}

# --- raiz resolvida do pvx-core ------------------------------------------------------------
pvx::root_dir() {
  if [[ -z ${PVX_ROOT:-} ]]; then
    pvx::die "$PVX_EXIT_CONFIG" 'PVX_ROOT não definido antes de lib/bootstrap.sh ser carregado'
  fi
  printf '%s\n' "$PVX_ROOT"
}
