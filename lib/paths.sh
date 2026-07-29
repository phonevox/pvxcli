#!/usr/bin/env bash
# lib/paths.sh — um único array associativo de caminhos conhecidos (Issabel/Asterisk + pvx),
# em vez de 40 constantes soltas. Iterável, sobrescrevível por /etc/pvx/pvx.conf por site, e
# testável (PVX_ROOT_PREFIX prefixa tudo, permitindo apontar pra uma árvore fixture em testes).

declare -gA PVX_PATH=(
  [asterisk_etc]=/etc/asterisk               [asterisk_lib]=/var/lib/asterisk
  [asterisk_spool]=/var/spool/asterisk        [asterisk_monitor]=/var/spool/asterisk/monitor
  [asterisk_log]=/var/log/asterisk            [asterisk_agi]=/var/lib/asterisk/agi-bin
  [asterisk_sounds]=/var/lib/asterisk/sounds  [asterisk_run]=/var/run/asterisk
  [issabel_root]=/opt/issabel                 [issabel_dialer]=/opt/issabel/dialer
  [issabel_conf]=/etc/issabel.conf            [issabel_web]=/var/www/html
  [issabel_backup]=/var/www/backup            [issabel_menu_db]=/var/www/db/menu.db
  [mysql_data]=/var/lib/mysql                 [mysql_cnf]=/etc/my.cnf
  [httpd_conf]=/etc/httpd/conf/httpd.conf     [httpd_confd]=/etc/httpd/conf.d
  [fail2ban_etc]=/etc/fail2ban                [cron_d]=/etc/cron.d
  [pvx_root]=/opt/pvx                         [pvx_current]=/opt/pvx/current
  [pvx_modules]=/opt/pvx/modules              [pvx_snippets]=/opt/pvx/current/share/pvx/snippets
  [pvx_etc]=/etc/pvx                          [pvx_conf]=/etc/pvx/pvx.conf
  [pvx_state]=/var/lib/pvx                    [pvx_cache]=/var/cache/pvx
  [pvx_log]=/var/log/pvx                      [pvx_baselines]=/var/lib/pvx/baselines
  [pvx_lock]=/var/lock/pvx.lock
)

declare -gA PVX_PATH_CANDIDATES=(
  [issabel_web]='/var/www/html/issabel|/var/www/html'
  [mysql_cnf]='/etc/my.cnf|/etc/mysql/my.cnf|/etc/my.cnf.d/server.cnf'
)

path::get() {
  local key=$1 fallback=${2:-}
  if [[ -n ${PVX_PATH[$key]+x} ]]; then
    printf '%s%s' "${PVX_ROOT_PREFIX:-}" "${PVX_PATH[$key]}"
    return 0
  fi
  if [[ -n $fallback ]]; then
    printf '%s' "$fallback"
    return 0
  fi
  pvx::die "$PVX_EXIT_CONFIG" "chave de caminho desconhecida: $key"
}

path::has() { [[ -n ${PVX_PATH[$1]+x} ]]; }

path::exists() {
  local p
  p=$(path::get "$1" '') || return 1
  [[ -n $p && -e $p ]]
}

path::set() {
  PVX_PATH[$1]=$2
  return 0
}

path::keys() {
  (( ${#PVX_PATH[@]} )) || return 0
  printf '%s\n' "${!PVX_PATH[@]}" | sort
}

path::detect() {
  local key=$1
  local candidates=${PVX_PATH_CANDIDATES[$key]:-}
  if [[ -z $candidates ]]; then
    path::get "$key"
    return
  fi
  local -a opts
  IFS='|' read -ra opts <<<"$candidates"
  local c
  for c in ${opts[@]+"${opts[@]}"}; do
    if [[ -e "${PVX_ROOT_PREFIX:-}$c" ]]; then
      PVX_PATH[$key]=$c
      printf '%s%s' "${PVX_ROOT_PREFIX:-}" "$c"
      return 0
    fi
  done
  path::get "$key"
}

path::join() {
  local result=$1
  shift
  local part
  for part in "$@"; do
    result=${result%/}/${part#/}
  done
  while [[ $result == *//* ]]; do
    result=${result//\/\//\/}
  done
  printf '%s' "$result"
}

path::require() {
  local key
  local -a missing=()
  for key in "$@"; do
    path::exists "$key" || missing+=("$key (${PVX_PATH[$key]:-?})")
  done
  if (( ${#missing[@]} )); then
    log::error 'caminhos obrigatórios ausentes: %s' "${missing[*]}"
    return "$PVX_EXIT_PRECONDITION"
  fi
  return 0
}

path::ensure_dir() {
  local key=$1 mode=${2:-0755} p
  p=$(path::get "$key")
  run -- mkdir -p "$p"
  run -- chmod "$mode" "$p"
  return 0
}

path::asterisk_conf() {
  local file=$1
  printf '%s/%s' "$(path::get asterisk_etc)" "$file"
}

# Parseado (nunca sourced) — só aceita chaves no formato `path.<nome> = <valor>`.
path::load_overrides() {
  local file=${1:-}
  [[ -z $file ]] && file=$(path::get pvx_conf)
  [[ -r $file ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    k=${k%%#*}
    k=${k//[[:space:]]/}
    [[ $k == path.* ]] || continue
    v=${v%%#*}
    v=${v#"${v%%[![:space:]]*}"}
    v=${v%"${v##*[![:space:]]}"}
    PVX_PATH[${k#path.}]=$v
  done <"$file"
  return 0
}
