#!/usr/bin/env bash
# lib/color.sh — cores ANSI via arrays associativos pré-computados. Sem `eval` em nenhum ponto.

declare -gA PVX_C=()          # mapa ativo para stdout (sequência real, ou "" se cor desligada)
declare -gA PVX_CE=()         # mapa ativo para stderr — separado porque stdout/stderr podem
                               # ter TTY-ness diferente (ex: `pvx audit > relatorio.txt`)
declare -gA _PVX_ANSI=()      # paleta imutável
declare -gA _PVX_SEMANTIC=()  # indireção semântica -> chave da paleta

PVX_COLOR_MODE=${PVX_COLOR_MODE:-}   # auto|always|never — vazio até color::init rodar

color::init() {
  _PVX_ANSI=(
    [reset]=$'\e[0m'    [bold]=$'\e[1m'    [dim]=$'\e[2m'     [underline]=$'\e[4m'
    [red]=$'\e[31m'     [green]=$'\e[32m'  [yellow]=$'\e[33m' [blue]=$'\e[34m'
    [magenta]=$'\e[35m' [cyan]=$'\e[36m'   [white]=$'\e[37m'  [gray]=$'\e[90m'
    [bred]=$'\e[91m'    [bgreen]=$'\e[92m' [byellow]=$'\e[93m'
  )
  _PVX_SEMANTIC=(
    [error]=bred [warn]=byellow [ok]=green [info]=cyan [trace]=gray [debug]=gray
    [fatal]=bred [path]=cyan    [cmd]=bold [num]=byellow [head]=bold [hint]=gray
  )
  if [[ -z $PVX_COLOR_MODE ]]; then
    case ${PVX_COLOR:-auto} in
      always | never | auto) PVX_COLOR_MODE=${PVX_COLOR:-auto} ;;
      *) PVX_COLOR_MODE=auto ;;
    esac
  fi
  color::_recompute
}

# Precedência (maior primeiro): modo explícito (always/never via flag/env) > NO_COLOR presente
# (por especificação, a presença da variável importa, não o valor) > TERM ausente/dumb >
# CLICOLOR_FORCE > TTY por stream.
color::_decide() {
  local fd=$1
  case $PVX_COLOR_MODE in
    always) return 0 ;;
    never) return 1 ;;
  esac
  [[ -n ${NO_COLOR+x} ]] && return 1
  [[ -z ${TERM:-} || $TERM == dumb ]] && return 1
  [[ -n ${CLICOLOR_FORCE:-} && $CLICOLOR_FORCE != 0 ]] && return 0
  [[ -t $fd ]]
}

color::_fill_map() {
  local enabled=$1 name seq target
  for name in "${!_PVX_ANSI[@]}"; do
    seq=${_PVX_ANSI[$name]}
    if (( enabled )); then printf '%s\t%s\n' "$name" "$seq"; else printf '%s\t\n' "$name"; fi
  done
  for name in "${!_PVX_SEMANTIC[@]}"; do
    target=${_PVX_SEMANTIC[$name]}
    seq=${_PVX_ANSI[$target]:-}
    if (( enabled )); then printf '%s\t%s\n' "$name" "$seq"; else printf '%s\t\n' "$name"; fi
  done
}

color::_recompute() {
  local enabled_out enabled_err k v
  color::_decide 1 && enabled_out=1 || enabled_out=0
  color::_decide 2 && enabled_err=1 || enabled_err=0

  PVX_C=()
  while IFS=$'\t' read -r k v; do PVX_C[$k]=$v; done < <(color::_fill_map "$enabled_out")
  PVX_CE=()
  while IFS=$'\t' read -r k v; do PVX_CE[$k]=$v; done < <(color::_fill_map "$enabled_err")
}

color::set_mode() {
  case $1 in
    auto | always | never) PVX_COLOR_MODE=$1 ;;
    *) return 2 ;;
  esac
  color::_recompute
}

color::enabled() {
  case ${1:-stdout} in
    stdout) [[ -n ${PVX_C[reset]:-} ]] ;;
    stderr) [[ -n ${PVX_CE[reset]:-} ]] ;;
    *) return 2 ;;
  esac
}

color::get() {
  local name=$1 fallback=${2:-}
  if [[ -n ${PVX_C[$name]+x} ]]; then
    printf '%s' "${PVX_C[$name]}"
  else
    printf '%s' "$fallback"
  fi
}

# Remoção pure-bash de sequências CSI (ESC [ ... letra-final). Usado antes de gravar em log.
color::strip() {
  local s=$1 esc=$'\e' pre rest i c
  while [[ $s == *"${esc}["* ]]; do
    pre=${s%%"${esc}["*}
    rest=${s#*"${esc}["}
    i=0
    while ((i < ${#rest})); do
      c=${rest:i:1}
      case $c in
        [A-Za-z]) break ;;
      esac
      i=$((i + 1))
    done
    s=$pre${rest:i+1}
  done
  printf '%s' "$s"
}

color::supports_unicode() {
  local loc=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
  [[ $loc == *UTF-8* || $loc == *utf8* || $loc == *UTF8* ]]
}
