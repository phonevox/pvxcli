#!/usr/bin/env bash
# lib/flags.sh — parser de flags declarativo. Sem `eval` em nenhum ponto: metadados e valores
# ficam em arrays associativos paralelos indexados pelo nome canônico (longo) do flag.

declare -gA PVX_FLAG_TYPE=() PVX_FLAG_SHORT=() PVX_FLAG_DEFAULT=() PVX_FLAG_HELP=()
declare -gA PVX_FLAG_REQUIRED=() PVX_FLAG_ENUM=() PVX_FLAG_REPEAT=() PVX_FLAG_META=()
declare -gA PVX_FLAG_ENV=() PVX_FLAG_MIN=() PVX_FLAG_MAX=() PVX_FLAG_GROUP=() PVX_FLAG_HIDDEN=()
declare -gA PVX_FLAG_SECRET_FILE_FLAG=() PVX_FLAG_CUSTOM_VALIDATORS=()
declare -ga PVX_FLAG_ORDER=()
declare -gA PVX_SHORT2LONG=()

declare -gA PVX_FLAG_VALUE=() PVX_FLAG_SET=() PVX_FLAG_MULTI=()
declare -ga PVX_ARGS=() PVX_UNKNOWN=()

declare -ga PVX_FLAG_SUBCOMMANDS=() PVX_FLAG_EXAMPLES=()
PVX_FLAG_ALLOW_UNKNOWN=0
PVX_FLAG_PROG=pvx
PVX_FLAG_SUMMARY=''
PVX_FLAG_USAGE_LINE=''
PVX_FLAG_EPILOG=''

flag::reset() {
  PVX_FLAG_TYPE=(); PVX_FLAG_SHORT=(); PVX_FLAG_DEFAULT=(); PVX_FLAG_HELP=()
  PVX_FLAG_REQUIRED=(); PVX_FLAG_ENUM=(); PVX_FLAG_REPEAT=(); PVX_FLAG_META=()
  PVX_FLAG_ENV=(); PVX_FLAG_MIN=(); PVX_FLAG_MAX=(); PVX_FLAG_GROUP=(); PVX_FLAG_HIDDEN=()
  PVX_FLAG_SECRET_FILE_FLAG=()
  PVX_FLAG_ORDER=(); PVX_SHORT2LONG=()
  PVX_FLAG_VALUE=(); PVX_FLAG_SET=(); PVX_FLAG_MULTI=()
  PVX_ARGS=(); PVX_UNKNOWN=()
  PVX_FLAG_SUBCOMMANDS=(); PVX_FLAG_EXAMPLES=()
  PVX_FLAG_ALLOW_UNKNOWN=0
  PVX_FLAG_PROG=pvx
  PVX_FLAG_SUMMARY=''
  PVX_FLAG_USAGE_LINE=''
  PVX_FLAG_EPILOG=''
}

flag::allow_unknown() { PVX_FLAG_ALLOW_UNKNOWN=${1:-1}; }
flag::type_register() { PVX_FLAG_CUSTOM_VALIDATORS[$1]=$2; }

flag::_default_meta() {
  local type=$1 long=$2
  case $type in
    bool) printf '' ;;
    *) printf '%s' "${long^^}" ;;
  esac
}

# --- declaração -------------------------------------------------------------------------------
flag::add() {
  local long=$1
  shift
  local short='' type=string default='' help='' meta='' required=0 repeat=0
  local enum='' env='' min='' max='' group=geral hidden=0
  while (( $# )); do
    case $1 in
      --short) short=$2; shift 2 ;;
      --type) type=$2; shift 2 ;;
      --default) default=$2; shift 2 ;;
      --help) help=$2; shift 2 ;;
      --meta) meta=$2; shift 2 ;;
      --required) required=1; shift ;;
      --repeat) repeat=1; shift ;;
      --enum) enum=$2; shift 2 ;;
      --env) env=$2; shift 2 ;;
      --min) min=$2; shift 2 ;;
      --max) max=$2; shift 2 ;;
      --hidden) hidden=1; shift ;;
      --group) group=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -z ${PVX_FLAG_TYPE[$long]:-} ]] && PVX_FLAG_ORDER+=("$long")
  [[ -z $meta ]] && meta=$(flag::_default_meta "$type" "$long")
  PVX_FLAG_TYPE[$long]=$type
  PVX_FLAG_SHORT[$long]=$short
  PVX_FLAG_DEFAULT[$long]=$default
  PVX_FLAG_HELP[$long]=$help
  PVX_FLAG_META[$long]=$meta
  PVX_FLAG_REQUIRED[$long]=$required
  PVX_FLAG_REPEAT[$long]=$repeat
  PVX_FLAG_ENUM[$long]=$enum
  PVX_FLAG_ENV[$long]=$env
  PVX_FLAG_MIN[$long]=$min
  PVX_FLAG_MAX[$long]=$max
  PVX_FLAG_GROUP[$long]=$group
  PVX_FLAG_HIDDEN[$long]=$hidden
  [[ -n $short ]] && PVX_SHORT2LONG[$short]=$long
  return 0
}

flag::add_standard() {
  flag::add help --short h --type bool --help 'mostra esta ajuda'
  flag::add verbose --short v --type bool --help 'aumenta verbosidade (equivale a --log-level=debug)'
  flag::add quiet --short q --type bool --help 'reduz verbosidade (equivale a --log-level=error)'
  flag::add dry-run --short n --type bool --help 'não executa ações que mutam estado'
  flag::add yes --short y --type bool --help 'assume "sim" em confirmações interativas'
  flag::add debug --type bool --help 'equivalente a --log-level=debug'
  flag::add log-level --type enum --enum 'trace|debug|info|warn|error' \
    --help 'nível de log do console'
  flag::add color --type enum --enum 'auto|always|never' --default auto --help 'controle de cor'
  flag::add offline --type bool --help 'nunca tenta acesso de rede'
}

flag::add_secret() {
  local long=$1
  shift
  local env='' file_flag='' prompt=''
  while (( $# )); do
    case $1 in
      --env) env=$2; shift 2 ;;
      --file-flag) file_flag=$2; shift 2 ;;
      --prompt) prompt=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -z $file_flag ]] && file_flag="$long-file"
  flag::add "$long" --type secret --env "$env" --help "${prompt:-valor sensível}"
  PVX_FLAG_SECRET_FILE_FLAG[$long]=$file_flag
  flag::add "$file_flag" --type existing-path \
    --help "lê $long de um arquivo (preferido — evita expor o valor via 'ps')"
}

flag::add_subcommand() { PVX_FLAG_SUBCOMMANDS+=("$1"$'\t'"$2"); }
flag::add_example() { PVX_FLAG_EXAMPLES+=("$1"); }
flag::set_usage() {
  PVX_FLAG_PROG=$1
  PVX_FLAG_SUMMARY=${2:-}
  PVX_FLAG_USAGE_LINE=${3:-}
  PVX_FLAG_EPILOG=${4:-}
}

# --- validação de tipos, sem fork ---------------------------------------------------------------
flag::_is_int() { [[ $1 =~ ^-?[0-9]+$ ]]; }

flag::_valid_ipv4() {
  local ip=$1 o
  local -a parts
  IFS=. read -ra parts <<<"$ip"
  (( ${#parts[@]} == 4 )) || return 1
  for o in "${parts[@]}"; do
    [[ $o =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$o <= 255 )) || return 1
  done
  return 0
}

flag::_valid_ipv6() {
  [[ $1 == *:* && $1 =~ ^[0-9A-Fa-f:]+$ ]]
}

flag::_valid_port() {
  flag::_is_int "$1" && (( $1 >= 1 && $1 <= 65535 ))
}

flag::_valid_cidr() {
  [[ $1 == */* ]] || return 1
  local ip=${1%/*} mask=${1#*/}
  { flag::_valid_ipv4 "$ip" || flag::_valid_ipv6 "$ip"; } || return 1
  flag::_is_int "$mask" && (( mask >= 0 && mask <= 128 ))
}

flag::_valid_duration() {
  [[ $1 =~ ^[0-9]+(s|m|h|d)?$ ]]
}

flag::_duration_seconds() {
  local v=$1 u=${1: -1} n
  if [[ $u =~ [smhd] ]]; then
    n=${v%[smhd]}
  else
    n=$v
    u=''
  fi
  case $u in
    m) printf '%d' "$((n * 60))" ;;
    h) printf '%d' "$((n * 3600))" ;;
    d) printf '%d' "$((n * 86400))" ;;
    *) printf '%d' "$n" ;;
  esac
}

flag::_validate() {
  local type=$1 value=$2 long=$3
  case $type in
    bool) [[ $value == 0 || $value == 1 ]] ;;
    int)
      flag::_is_int "$value" || return 1
      local min=${PVX_FLAG_MIN[$long]:-} max=${PVX_FLAG_MAX[$long]:-}
      [[ -n $min ]] && (( value < min )) && return 1
      [[ -n $max ]] && (( value > max )) && return 1
      return 0
      ;;
    string | secret | path | csv) return 0 ;;
    existing-path) [[ -e $value ]] ;;
    ipv4) flag::_valid_ipv4 "$value" ;;
    ipv6) flag::_valid_ipv6 "$value" ;;
    ip) flag::_valid_ipv4 "$value" || flag::_valid_ipv6 "$value" ;;
    cidr) flag::_valid_cidr "$value" ;;
    port) flag::_valid_port "$value" ;;
    duration) flag::_valid_duration "$value" ;;
    enum)
      local enum=${PVX_FLAG_ENUM[$long]:-} opt
      local -a opts
      IFS='|' read -ra opts <<<"$enum"
      for opt in ${opts[@]+"${opts[@]}"}; do
        [[ $value == "$opt" ]] && return 0
      done
      return 1
      ;;
    *)
      local fn=${PVX_FLAG_CUSTOM_VALIDATORS[$type]:-}
      [[ -n $fn ]] && "$fn" "$value"
      ;;
  esac
}

# --- parsing -------------------------------------------------------------------------------------
flag::_usage_error() {
  local msg=$1
  if declare -F log::error >/dev/null 2>&1; then
    log::error '%s' "$msg"
  else
    printf 'pvx: %s\n' "$msg" >&2
  fi
}

flag::_unknown_or_die() {
  local tok=$1
  if (( PVX_FLAG_ALLOW_UNKNOWN )); then
    PVX_UNKNOWN+=("$tok")
  else
    flag::_usage_error "opção desconhecida: $tok"
    exit "$PVX_EXIT_USAGE"
  fi
}

flag::_set_value() {
  PVX_FLAG_VALUE[$1]=$2
  PVX_FLAG_SET[$1]=1
}

flag::_consume_value() {
  local long=$1 value=$2
  local type=${PVX_FLAG_TYPE[$long]}
  if ! flag::_validate "$type" "$value" "$long"; then
    flag::_usage_error "valor inválido para --$long: '$value'"
    return 1
  fi
  [[ $type == duration ]] && value=$(flag::_duration_seconds "$value")
  if [[ ${PVX_FLAG_REPEAT[$long]:-0} == 1 ]]; then
    if [[ -n ${PVX_FLAG_MULTI[$long]:-} ]]; then
      PVX_FLAG_MULTI[$long]+=$'\x1f'"$value"
    else
      PVX_FLAG_MULTI[$long]=$value
    fi
  fi
  flag::_set_value "$long" "$value"
  if [[ $type == secret ]]; then
    log::add_secret "$value"
    log::warn "valor de --%s na linha de comando é visível via 'ps' — prefira --%s-file ou %s" \
      "$long" "$long" "${PVX_FLAG_ENV[$long]:-uma variável de ambiente}"
  fi
  return 0
}

flag::parse() {
  local -a argv=("$@")
  local i=0 tok val long rest c
  PVX_ARGS=(); PVX_UNKNOWN=()
  PVX_FLAG_VALUE=(); PVX_FLAG_SET=(); PVX_FLAG_MULTI=()

  while (( i < ${#argv[@]} )); do
    tok=${argv[i]}
    if [[ $tok == -- ]]; then
      i=$((i + 1))
      while (( i < ${#argv[@]} )); do
        PVX_ARGS+=("${argv[i]}")
        i=$((i + 1))
      done
      break
    elif [[ $tok == --no-* ]]; then
      long=${tok#--no-}
      if [[ ${PVX_FLAG_TYPE[$long]:-} == bool ]]; then
        flag::_set_value "$long" 0
      else
        flag::_unknown_or_die "$tok"
      fi
    elif [[ $tok == --*=* ]]; then
      long=${tok#--}
      long=${long%%=*}
      val=${tok#*=}
      if [[ -n ${PVX_FLAG_TYPE[$long]:-} ]]; then
        flag::_consume_value "$long" "$val" || return "$PVX_EXIT_USAGE"
      else
        flag::_unknown_or_die "$tok"
      fi
    elif [[ $tok == --* ]]; then
      long=${tok#--}
      if [[ -n ${PVX_FLAG_TYPE[$long]:-} ]]; then
        if [[ ${PVX_FLAG_TYPE[$long]} == bool ]]; then
          flag::_set_value "$long" 1
        else
          i=$((i + 1))
          if (( i >= ${#argv[@]} )); then
            flag::_usage_error "opção --$long requer um valor"
            return "$PVX_EXIT_USAGE"
          fi
          flag::_consume_value "$long" "${argv[i]}" || return "$PVX_EXIT_USAGE"
        fi
      else
        flag::_unknown_or_die "$tok"
      fi
    elif [[ $tok == -?* ]]; then
      rest=${tok#-}
      while [[ -n $rest ]]; do
        c=${rest:0:1}
        rest=${rest:1}
        long=${PVX_SHORT2LONG[$c]:-}
        if [[ -z $long ]]; then
          flag::_unknown_or_die "-$c"
          break
        fi
        if [[ ${PVX_FLAG_TYPE[$long]} == bool ]]; then
          flag::_set_value "$long" 1
        else
          if [[ -n $rest ]]; then
            flag::_consume_value "$long" "$rest" || return "$PVX_EXIT_USAGE"
          else
            i=$((i + 1))
            if (( i >= ${#argv[@]} )); then
              flag::_usage_error "opção -$c requer um valor"
              return "$PVX_EXIT_USAGE"
            fi
            flag::_consume_value "$long" "${argv[i]}" || return "$PVX_EXIT_USAGE"
          fi
          break
        fi
      done
    else
      PVX_ARGS+=("$tok")
    fi
    i=$((i + 1))
  done

  if [[ -z ${PVX_FLAG_NO_AUTO_HELP:-} && ${PVX_FLAG_VALUE[help]:-0} == 1 ]]; then
    flag::usage
    exit "$PVX_EXIT_OK"
  fi

  flag::apply_standard
  flag::_check_required || return "$PVX_EXIT_USAGE"
  return 0
}

flag::apply_standard() {
  [[ -n ${PVX_FLAG_VALUE[log-level]:-} ]] && log::set_level "${PVX_FLAG_VALUE[log-level]}"
  [[ ${PVX_FLAG_VALUE[debug]:-0} == 1 ]] && log::set_level debug
  [[ ${PVX_FLAG_VALUE[verbose]:-0} == 1 ]] && log::set_level debug
  [[ ${PVX_FLAG_VALUE[quiet]:-0} == 1 ]] && log::set_level error
  [[ -n ${PVX_FLAG_VALUE[color]:-} ]] && color::set_mode "${PVX_FLAG_VALUE[color]}"
  [[ ${PVX_FLAG_VALUE[dry-run]:-0} == 1 ]] && PVX_DRY_RUN=1
  [[ ${PVX_FLAG_VALUE[offline]:-0} == 1 ]] && PVX_OFFLINE=1
  [[ ${PVX_FLAG_VALUE[yes]:-0} == 1 ]] && PVX_ASSUME_YES=1
  return 0
}

flag::_check_required() {
  local long
  local -a missing=()
  for long in ${PVX_FLAG_ORDER[@]+"${PVX_FLAG_ORDER[@]}"}; do
    if [[ ${PVX_FLAG_REQUIRED[$long]:-0} == 1 && -z ${PVX_FLAG_SET[$long]:-} ]]; then
      missing+=("--$long")
    fi
  done
  if (( ${#missing[@]} )); then
    flag::_usage_error "opções obrigatórias faltando: ${missing[*]}"
    return 1
  fi
  return 0
}

flag::require() {
  local long
  local -a missing=()
  for long in "$@"; do
    [[ -z ${PVX_FLAG_SET[$long]:-} ]] && missing+=("--$long")
  done
  if (( ${#missing[@]} )); then
    flag::_usage_error "opções obrigatórias faltando: ${missing[*]}"
    exit "$PVX_EXIT_USAGE"
  fi
}

# --- leitura ---------------------------------------------------------------------------------
flag::has() { [[ -n ${PVX_FLAG_SET[$1]:-} ]]; }

flag::_resolve_secret() {
  local long=$1 fallback=${2:-}
  if [[ -n ${PVX_FLAG_SET[$long]:-} ]]; then
    printf '%s' "${PVX_FLAG_VALUE[$long]}"
    return 0
  fi
  local file_flag=${PVX_FLAG_SECRET_FILE_FLAG[$long]:-$long-file}
  if [[ -n ${PVX_FLAG_SET[$file_flag]:-} ]]; then
    local f=${PVX_FLAG_VALUE[$file_flag]} v=''
    # `read` retorna rc=1 quando o arquivo não termina em newline mesmo lendo o valor com
    # sucesso — não usar isso pra decidir se o valor é válido, só se o arquivo era legível.
    if [[ -r $f ]]; then
      read -r v <"$f" || true
    fi
    log::add_secret "$v"
    printf '%s' "$v"
    return 0
  fi
  local env=${PVX_FLAG_ENV[$long]:-}
  if [[ -n $env && -n ${!env:-} ]]; then
    log::add_secret "${!env}"
    printf '%s' "${!env}"
    return 0
  fi
  if [[ -t 0 && -t 2 ]]; then
    local v=''
    read -rsp "valor para --$long: " v </dev/tty 2>/dev/null || true
    printf '\n' >&2
    log::add_secret "$v"
    printf '%s' "$v"
    return 0
  fi
  printf '%s' "$fallback"
}

flag::get() {
  local long=$1 fallback=${2:-}
  if [[ ${PVX_FLAG_TYPE[$long]:-} == secret ]]; then
    flag::_resolve_secret "$long" "$fallback"
    return 0
  fi
  if [[ -n ${PVX_FLAG_SET[$long]:-} ]]; then
    printf '%s' "${PVX_FLAG_VALUE[$long]}"
    return 0
  fi
  local env=${PVX_FLAG_ENV[$long]:-}
  if [[ -n $env && -n ${!env:-} ]]; then
    printf '%s' "${!env}"
    return 0
  fi
  local def=${PVX_FLAG_DEFAULT[$long]:-}
  if [[ -n $def ]]; then
    printf '%s' "$def"
  else
    printf '%s' "$fallback"
  fi
}

flag::get_all() {
  local long=$1
  [[ -n ${PVX_FLAG_MULTI[$long]:-} ]] || return 0
  local -a vals
  IFS=$'\x1f' read -ra vals <<<"${PVX_FLAG_MULTI[$long]}"
  printf '%s\n' "${vals[@]}"
}

flag::bool() {
  local v
  v=$(flag::get "$1" 0)
  [[ $v == 1 || $v == true || $v == yes || $v == on ]]
}

flag::args() {
  (( ${#PVX_ARGS[@]} )) || return 0
  printf '%s\n' "${PVX_ARGS[@]}"
}

flag::arg() {
  local n=$1 fallback=${2:-}
  if (( n < ${#PVX_ARGS[@]} )); then
    printf '%s' "${PVX_ARGS[$n]}"
  else
    printf '%s' "$fallback"
  fi
}

# --- --help autogerado -------------------------------------------------------------------------
flag::_render_label() {
  local long=$1
  local short=${PVX_FLAG_SHORT[$long]:-} meta=${PVX_FLAG_META[$long]:-}
  local out=''
  [[ -n $short ]] && out="-$short, "
  out+="--$long"
  [[ -n $meta ]] && out+=" $meta"
  printf '%s' "$out"
}

flag::_wrap() {
  local text=$1 width=${2:-80} indent=${3:-0} pad
  printf -v pad '%*s' "$indent" ''
  local -a words
  read -ra words <<<"$text"
  local w line='' out=''
  for w in ${words[@]+"${words[@]}"}; do
    if [[ -z $line ]]; then
      line=$w
    elif (( ${#line} + 1 + ${#w} <= width - indent )); then
      line+=" $w"
    else
      out+="${pad}${line}"$'\n'
      line=$w
    fi
  done
  [[ -n $line ]] && out+="${pad}${line}"$'\n'
  printf '%s' "$out"
}

flag::usage() {
  local prog=${PVX_FLAG_PROG:-pvx}
  [[ -n ${PVX_FLAG_SUMMARY:-} ]] && printf '%s\n\n' "$PVX_FLAG_SUMMARY"
  printf 'uso: %s\n\n' "${PVX_FLAG_USAGE_LINE:-$prog [opções]}"

  if (( ${#PVX_FLAG_SUBCOMMANDS[@]} )); then
    printf 'subcomandos:\n'
    local entry name summary
    for entry in "${PVX_FLAG_SUBCOMMANDS[@]}"; do
      name=${entry%%$'\t'*}
      summary=${entry#*$'\t'}
      printf '  %-16s %s\n' "$name" "$summary"
    done
    printf '\n'
  fi

  local long width=0 label
  for long in ${PVX_FLAG_ORDER[@]+"${PVX_FLAG_ORDER[@]}"}; do
    [[ ${PVX_FLAG_HIDDEN[$long]:-0} == 1 ]] && continue
    label=$(flag::_render_label "$long")
    (( ${#label} > width )) && width=${#label}
  done
  (( width > 26 )) && width=26

  local -A seen_groups=()
  local -a group_order=()
  local g
  for long in ${PVX_FLAG_ORDER[@]+"${PVX_FLAG_ORDER[@]}"}; do
    [[ ${PVX_FLAG_HIDDEN[$long]:-0} == 1 ]] && continue
    g=${PVX_FLAG_GROUP[$long]:-geral}
    if [[ -z ${seen_groups[$g]:-} ]]; then
      seen_groups[$g]=1
      group_order+=("$g")
    fi
  done

  if (( ${#group_order[@]} )); then
    printf 'opções:\n'
  fi
  for g in ${group_order[@]+"${group_order[@]}"}; do
    for long in ${PVX_FLAG_ORDER[@]+"${PVX_FLAG_ORDER[@]}"}; do
      [[ ${PVX_FLAG_HIDDEN[$long]:-0} == 1 ]] && continue
      [[ ${PVX_FLAG_GROUP[$long]:-geral} == "$g" ]] || continue
      label=$(flag::_render_label "$long")
      if (( ${#label} <= width )); then
        printf '  %-*s  %s\n' "$width" "$label" "${PVX_FLAG_HELP[$long]:-}"
      else
        printf '  %s\n' "$label"
        flag::_wrap "${PVX_FLAG_HELP[$long]:-}" "${COLUMNS:-80}" $((width + 4))
      fi
    done
  done
  (( ${#group_order[@]} )) && printf '\n'

  if (( ${#PVX_FLAG_EXAMPLES[@]} )); then
    printf 'exemplos:\n'
    local ex
    for ex in "${PVX_FLAG_EXAMPLES[@]}"; do
      printf '  %s\n' "$ex"
    done
    printf '\n'
  fi

  [[ -n ${PVX_FLAG_EPILOG:-} ]] && printf '%s\n' "$PVX_FLAG_EPILOG"
  return 0
}

# --- aliases de compatibilidade com a nomenclatura do enunciado original ----------------------
add_flag() { flag::add "$@"; }
parse_flags() { flag::parse "$@"; }
hasFlag() { flag::has "$@"; }
getFlag() { flag::get "$@"; }
