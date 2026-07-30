#!/usr/bin/env bash
# lib/core/registry.sh — `pvx registry`: consulta e configura o índice remoto de módulos
# (o mesmo mecanismo que `pvx modules install <nome>` usa por baixo).
core::cmd_registry() {
  pvx::require registry json net os

  local sub=${1:-}
  (($#)) && shift

  case $sub in
    status) core::_registry_status ;;
    list) core::_registry_list ;;
    refresh) core::_registry_refresh "$@" ;;
    set) core::_registry_set "$@" ;;
    '')
      if [[ -t 0 && -t 1 ]]; then
        core::_registry_interactive_menu
      else
        core::_registry_usage
      fi
      ;;
    -h | --help) core::_registry_usage ;;
    *)
      log::error 'registry: subcomando desconhecido: %s' "$sub"
      core::_registry_usage >&2
      return "$PVX_EXIT_USAGE"
      ;;
  esac
}

# --- submenu interativo (`pvx registry` sem subcomando, com TTY) -----------------------------
core::_registry_interactive_menu() {
  pvx::require tui exec

  local -a options=(
    'status           mostra URL do registry, estado do cache e contagem de módulos'
    'list             lista os módulos publicados no registry'
    'refresh          busca o índice remoto de novo (respeita o TTL do cache)'
    'refresh --force  busca o índice remoto de novo, ignorando o TTL'
    'set              define uma nova URL de registry (requer root)'
  )
  local -a keys=(status list refresh refresh-force set)

  local i chosen sub_rc
  while true; do
    if ! tui::select "$(tui::breadcrumb registry)" "${options[@]}"; then
      return 0
    fi
    chosen=''
    for ((i = 0; i < ${#options[@]}; i++)); do
      if [[ ${options[i]} == "$TUI_CHOICE" ]]; then
        chosen=${keys[i]}
        break
      fi
    done
    [[ -z $chosen ]] && continue

    printf '\n'
    # "|| sub_rc=$?" em cada ramo: essas funções já logam seu próprio erro antes de retornar
    # rc≠0 (ex: refresh sem rede/cache) — sem isso, o rc vazaria como comando solto sob `set -e`
    # e derrubaria o pvx inteiro em vez de só mostrar o erro e voltar pro mesmo submenu (mesmo
    # achado de lib/cmd_modules.sh, testado de verdade no container). rc=90 é o sentinel
    # interno "cancelei sem fazer/mostrar nada de útil" (ver core::_registry_interactive_set) —
    # nesse caso pula a pausa embaixo, igual list/status/refresh.
    sub_rc=0
    case $chosen in
      status) core::_registry_status || true ;;
      list) core::_registry_list || true ;;
      refresh) core::_registry_refresh || true ;;
      refresh-force)
        if exec::confirm 'forçar o refresh, ignorando o cache ainda válido? [y/N]' n; then
          core::_registry_refresh --force || true
        else
          printf 'cancelado.\n'
        fi
        ;;
      set) core::_registry_interactive_set || sub_rc=$? ;;
    esac

    # status/list/refresh(--force) são só leitura/rápidos — voltam direto, sem pausa (mesma
    # lógica de sysinfo/help/version no menu principal e de "modules list"). "set" cancelado
    # sem fazer/mostrar nada de útil (rc=90) também volta direto; só um "set" bem-sucedido (ou
    # o erro de "precisa de root") pausa pra dar tempo de ler.
    if [[ $chosen != set ]] || ((sub_rc == 90)); then
      printf '\n'
      continue
    fi

    tui::pause 'pressione enter pra continuar (q/esc volta)'
    ((TUI_BACK)) && return 0
  done
}

# core::_registry_interactive_set — checa root ANTES de pedir a URL (em vez de deixar
# core::_registry_set/os::require_root derrubar o pvx inteiro com `exit`): sem privilégio,
# só avisa e volta pro submenu, do jeito que faz sentido dentro de um menu interativo.
core::_registry_interactive_set() {
  pvx::require tui
  if ! os::is_root; then
    log::error 'registry set requer privilégios de root (rodando como uid %d)' "$EUID"
    log::hint 'tente: sudo pvx registry set <url>'
    return 0
  fi
  # loop: URL inválida reprompta na hora (core::_registry_set já logou o erro) em vez de
  # devolver pro submenu e obrigar escolher "set" de novo só pra corrigir um typo. Ctrl-C no
  # tui::input cancela e volta pro submenu normalmente (ver o trap em lib/tui.sh). rc=90 (sem
  # ter feito/mostrado nada de útil) faz o chamador pular a pausa — ver
  # core::_registry_interactive_menu.
  while true; do
    if ! tui::input 'nova URL do registry (file:// ou http(s)://)'; then
      printf 'cancelado.\n'
      return 90
    fi
    core::_registry_set "$TUI_INPUT" && return 0
  done
}

core::_registry_usage() {
  cat <<'EOF'
uso: pvx registry <subcomando> [args...]

subcomandos:
  status             mostra a URL do registry, estado do cache local e quantos módulos há
  list               lista os módulos publicados no registry (nome, versão, resumo)
  refresh [--force]  busca o índice remoto de novo agora (--force ignora o cache ainda válido)
  set <url>          define a URL do registry em /etc/pvx/pvx.conf — aceita file:// e
                     http(s):// (requer root; só vale a partir da próxima chamada do pvx)
EOF
}

core::_registry_status() {
  printf 'URL:           %s\n' "$PVX_REGISTRY_URL"
  printf 'TTL do cache:  %ss\n' "$PVX_REGISTRY_TTL"

  local idx age
  idx=$(registry::index_path)
  if [[ -r $idx ]]; then
    age=$(registry::_file_age_seconds "$idx" 2>/dev/null) || age=''
    if [[ -n $age ]]; then
      printf 'cache local:   %s (buscado há %ss)\n' "$idx" "$age"
      if ((age < PVX_REGISTRY_TTL)); then
        printf 'estado:        fresco (dentro do TTL)\n'
      else
        printf 'estado:        desatualizado (fora do TTL — próximo uso vai buscar de novo)\n'
      fi
    else
      printf 'cache local:   %s (idade desconhecida)\n' "$idx"
    fi
  else
    printf 'cache local:   (ainda não buscado)\n'
    printf 'estado:        sem cache\n'
  fi

  local names count=0
  names=$(registry::list_names 2>/dev/null) || names=''
  [[ -n $names ]] && count=$(printf '%s\n' "$names" | grep -c .)
  printf 'módulos:       %d disponível(is)\n' "$count"
  return 0
}

core::_registry_list() {
  registry::refresh 2>/dev/null || true
  local names
  names=$(registry::list_names 2>/dev/null) || names=''
  if [[ -z $names ]]; then
    printf 'nenhum módulo disponível no registry (sem rede/cache ainda?).\n'
    return 0
  fi
  printf '%-16s %-10s %s\n' NAME VERSION SUMMARY
  local n ver summary
  while IFS= read -r n; do
    [[ -z $n ]] && continue
    ver=$(registry::field "$n" version 2>/dev/null) || ver='?'
    summary=$(registry::field "$n" summary 2>/dev/null) || summary=''
    printf '%-16s %-10s %s\n' "$n" "$ver" "$summary"
  done <<<"$names"
  return 0
}

core::_registry_refresh() {
  local force=()
  [[ ${1:-} == --force ]] && force=(--force)
  if ! registry::refresh "${force[@]+"${force[@]}"}"; then
    return 4
  fi
  local count=0 names
  names=$(registry::list_names 2>/dev/null) || names=''
  [[ -n $names ]] && count=$(printf '%s\n' "$names" | grep -c .)
  printf 'índice atualizado: %d módulo(s) disponível(is).\n' "$count"
  return 0
}

core::_registry_set() {
  local url=${1:-}
  if [[ -z $url ]]; then
    log::error 'registry set: informe a URL (file:// ou http(s)://)'
    return "$PVX_EXIT_USAGE"
  fi
  case $url in
    file://* | http://* | https://*) ;;
    *)
      log::error 'registry set: URL precisa começar com file://, http:// ou https:// (recebido: %s)' "$url"
      return "$PVX_EXIT_USAGE"
      ;;
  esac

  os::require_root 'pvx registry set'

  local conf="$PVX_ETC_DIR/pvx.conf"
  mkdir -p "$(dirname "$conf")"
  touch "$conf"
  if grep -q '^registry_url[[:space:]]*=' "$conf" 2>/dev/null; then
    sed -i.bak "s|^registry_url[[:space:]]*=.*|registry_url = $url|" "$conf" && rm -f "$conf.bak"
  else
    printf 'registry_url = %s\n' "$url" >>"$conf"
  fi
  printf 'registry_url definido em %s: %s\n' "$conf" "$url"
  printf '(vale a partir da próxima chamada do pvx — nada nesta sessão muda)\n'
  return 0
}
