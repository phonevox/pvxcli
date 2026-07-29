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
    '' | -h | --help) core::_registry_usage ;;
    *)
      log::error 'registry: subcomando desconhecido: %s' "$sub"
      core::_registry_usage >&2
      return "$PVX_EXIT_USAGE"
      ;;
  esac
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
