#!/usr/bin/env bash
# lib/log.sh — logging por nível, rotação diária, fallback gracioso, redação de segredos.
# Depende de lib/color.sh (color::init deve já ter rodado) e lib/bootstrap.sh (pvx::invocation_id).

declare -gA PVX_LOG_LEVELS=([trace]=10 [debug]=20 [info]=30 [warn]=40 [error]=50 [fatal]=60 [silent]=99)

PVX_LOG_LEVEL=${PVX_LOG_LEVEL:-30}            # threshold do console
PVX_LOG_FILE_LEVEL=${PVX_LOG_FILE_LEVEL:-20}  # threshold do arquivo — sempre mais verboso
PVX_LOG_DIR=${PVX_LOG_DIR:-}
PVX_LOG_FILE=${PVX_LOG_FILE:-}
PVX_LOG_TO_FILE=${PVX_LOG_TO_FILE:-1}
PVX_LOG_RETENTION_DAYS=${PVX_LOG_RETENTION_DAYS:-30}
PVX_LOG_MAX_LINE=${PVX_LOG_MAX_LINE:-3800}    # abaixo de PIPE_BUF, mantém O_APPEND atômico
PVX_LOG_CONTEXT=${PVX_LOG_CONTEXT:-pvx}
PVX_LOG_TIMESTAMPS=${PVX_LOG_TIMESTAMPS:-0}

_PVX_LOG_FD=''
_PVX_LOG_DAY=''
_PVX_LOG_FALLBACK_WARNED=0
_PVX_SECRETS=()

log::level_num() {
  local name=$1
  if [[ -n ${PVX_LOG_LEVELS[$name]:-} ]]; then
    printf '%s' "${PVX_LOG_LEVELS[$name]}"
  elif [[ $name =~ ^[0-9]+$ ]]; then
    printf '%s' "$name"
  else
    printf '%s' 30
  fi
}

log::set_level() {
  local lvl
  lvl=$(log::level_num "$1")
  if [[ ${2:-} == --file ]]; then
    PVX_LOG_FILE_LEVEL=$lvl
  else
    PVX_LOG_LEVEL=$lvl
    (( lvl <= 20 )) && PVX_LOG_TIMESTAMPS=1
  fi
  return 0
}

log::is_enabled() {
  local lvl
  lvl=$(log::level_num "$1")
  (( lvl >= PVX_LOG_LEVEL )) && return 0
  (( PVX_LOG_TO_FILE )) && (( lvl >= PVX_LOG_FILE_LEVEL )) && return 0
  return 1
}

# --- fallback ladder e rotação --------------------------------------------------------------
log::_close_fd() {
  if [[ -n $_PVX_LOG_FD ]]; then
    # NUNCA encadear `2>/dev/null` no mesmo `exec {var}>&-` que fecha um fd por número
    # dinâmico — bash (confirmado em 5.3.15) fecha o fd 2 do processo nessa combinação
    # específica, mesmo $var apontando pra outro descritor. Sem o `2>/dev/null` funciona.
    exec {_PVX_LOG_FD}>&- || true
    _PVX_LOG_FD=''
  fi
}

log::_prune() {
  (( PVX_LOG_RETENTION_DAYS > 0 )) || return 0
  local dir=$PVX_LOG_DIR f
  [[ -d $dir ]] || return 0
  for f in "$dir"/pvx-*.log; do
    [[ -e $f ]] || continue
    if find "$f" -mtime "+$PVX_LOG_RETENTION_DAYS" -print -quit 2>/dev/null | grep -q .; then
      rm -f -- "$f"
    fi
  done
  return 0
}

log::_open_fd() {
  log::_close_fd
  local dir candidates=(
    "${PVX_LOG_DIR:-/var/log/pvx}"
    "${XDG_STATE_HOME:-$HOME/.local/state}/pvx"
    "${TMPDIR:-/tmp}/pvx-$EUID"
  )
  for dir in "${candidates[@]}"; do
    [[ -n $dir ]] || continue
    if mkdir -p "$dir" 2>/dev/null; then
      local today file
      printf -v today '%(%Y-%m-%d)T' -1
      file="$dir/pvx-$today.log"
      if { exec {_PVX_LOG_FD}>>"$file"; } 2>/dev/null; then
        PVX_LOG_DIR=$dir
        PVX_LOG_FILE=$file
        _PVX_LOG_DAY=$today
        ln -sfn "$(basename "$file")" "$dir/pvx.log" 2>/dev/null || true
        return 0
      fi
    fi
  done
  PVX_LOG_TO_FILE=0
  if (( ! _PVX_LOG_FALLBACK_WARNED )); then
    _PVX_LOG_FALLBACK_WARNED=1
    printf '%s[WARN]%s pvx: sem diretório de log gravável; logando só em stderr\n' \
      "${PVX_CE[warn]:-}" "${PVX_CE[reset]:-}" >&2
  fi
  return 1
}

log::_maybe_roll() {
  (( PVX_LOG_TO_FILE )) || return 1
  local today
  printf -v today '%(%Y-%m-%d)T' -1
  if [[ $today == "$_PVX_LOG_DAY" && -n $_PVX_LOG_FD ]]; then
    return 0
  fi
  log::_open_fd && log::_prune
}

log::init() {
  local dir=${1:-}
  [[ -n $dir ]] && PVX_LOG_DIR=$dir
  if (( PVX_LOG_TO_FILE )); then
    log::_maybe_roll || true
  fi
  return 0
}

log::rotate() {
  _PVX_LOG_DAY=''
  log::_maybe_roll || true
  return 0
}

log::file_path() {
  (( PVX_LOG_TO_FILE )) || return 1
  log::_maybe_roll || true
  [[ -n $PVX_LOG_FILE ]] || return 1
  printf '%s\n' "$PVX_LOG_FILE"
}

log::enable_xtrace() {
  (( PVX_LOG_TO_FILE )) || return 1
  log::_maybe_roll || return 1
  [[ -n $_PVX_LOG_FD ]] || return 1
  BASH_XTRACEFD=$_PVX_LOG_FD
  set -x
}

# --- redação de segredos ---------------------------------------------------------------------
log::add_secret() {
  local v=$1
  [[ -n $v ]] && _PVX_SECRETS+=("$v")
  return 0
}

log::_redact_shapes() {
  local s=$1 out='' words=() i w prev=''
  read -ra words <<<"$s"
  for ((i = 0; i < ${#words[@]}; i++)); do
    w=${words[i]}
    case $prev in
      --password | --token | -p | Bearer) w='***' ;;
    esac
    case $w in
      password=* | Password=* | PASSWORD=* | MYSQL_PWD=* | mysql_pwd=* | --password=* | --token=*)
        w="${w%%=*}=***" ;;
      -p?*) w='-p***' ;;
    esac
    out+="${out:+ }$w"
    prev=${words[i]}
  done
  printf '%s' "$out"
}

log::redact() {
  local s=$1 secret
  for secret in ${_PVX_SECRETS[@]+"${_PVX_SECRETS[@]}"}; do
    [[ -n $secret ]] && s=${s//"$secret"/***}
  done
  log::_redact_shapes "$s"
}

# --- emissão ----------------------------------------------------------------------------------
log::_emit() {
  local level=$1
  shift
  local lvl_num
  lvl_num=$(log::level_num "$level")
  local to_console=0 to_file=0
  (( lvl_num >= PVX_LOG_LEVEL )) && to_console=1
  (( PVX_LOG_TO_FILE )) && (( lvl_num >= PVX_LOG_FILE_LEVEL )) && to_file=1
  (( to_console || to_file )) || return 0

  local msg
  # shellcheck disable=SC2059
  printf -v msg -- "$@"
  msg=$(log::redact "$msg")
  (( ${#msg} > PVX_LOG_MAX_LINE )) && msg="${msg:0:PVX_LOG_MAX_LINE}...[truncado]"

  local upper=${level^^}

  if (( to_console )); then
    local ts=''
    (( PVX_LOG_TIMESTAMPS )) && printf -v ts '%(%H:%M:%S)T ' -1
    printf '%s%s[%s]%s %s\n' "$ts" "${PVX_CE[$level]:-}" "$upper" "${PVX_CE[reset]:-}" "$msg" >&2
  fi

  if (( to_file )); then
    log::_maybe_roll || true
    if [[ -n $_PVX_LOG_FD ]]; then
      local iso clean
      printf -v iso '%(%Y-%m-%dT%H:%M:%S%z)T' -1
      clean=$(color::strip "$msg")
      pvx::invocation_id >/dev/null   # memoiza PVX_INVOCATION_ID no shell atual (não num subshell)
      printf '%s [%s] pvx[%d] %s %s: %s\n' \
        "$iso" "$upper" "$$" "$PVX_INVOCATION_ID" "$PVX_LOG_CONTEXT" "$clean" >&"$_PVX_LOG_FD"
    fi
  fi
  return 0
}

log::trace() { log::_emit trace "$@"; }
log::debug() { log::_emit debug "$@"; }
log::info() { log::_emit info "$@"; }
log::warn() { log::_emit warn "$@"; }
log::error() { log::_emit error "$@"; }

log::fatal() {
  local msg=$1 code=${2:-1}
  log::_emit fatal '%s' "$msg"
  exit "$code"
}

log::raw() {
  local text=$1
  (( PVX_LOG_TO_FILE )) || return 0
  log::_maybe_roll || return 0
  [[ -n $_PVX_LOG_FD ]] || return 0
  local clean
  clean=$(color::strip "$(log::redact "$text")")
  printf '%s\n' "$clean" >&"$_PVX_LOG_FD"
}

log::hint() {
  local msg
  # shellcheck disable=SC2059
  printf -v msg -- "$@"
  printf '%s%s%s\n' "${PVX_CE[hint]:-}" "$msg" "${PVX_CE[reset]:-}" >&2
}

# --- ação `logs` universal: tail em tempo real filtrado por componente -----------------------
log::tail() {
  local component=$1
  shift
  local n=50
  while (( $# )); do
    case $1 in
      -n)
        n=$2
        shift 2
        ;;
      *) shift ;;
    esac
  done
  local file
  if ! file=$(log::file_path); then
    printf 'pvx: log em arquivo desabilitado neste host; não é possível acompanhar logs\n' >&2
    return 69
  fi
  local pattern
  printf -v pattern '^[^ ]+ \[[A-Z]+\] pvx\[[0-9]+\] [0-9a-f]+ %s: ' "$component"
  tail -n "$n" -F "$file" | grep -E --line-buffered "$pattern"
}
