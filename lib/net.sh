#!/usr/bin/env bash
# lib/net.sh — acesso de rede do pvx-core: download de URLs (curl, aceita file:// e
# http(s)://), respeitando PVX_OFFLINE. Usado por lib/registry.sh (índice remoto) e
# lib/cmd_modules.sh (download de tarball de módulo).

# net::is_offline — verdadeiro se PVX_OFFLINE=1 OU curl não está disponível (as duas razões
# pelas quais qualquer fetch vai falhar, então os chamadores checam isso uma vez só).
net::is_offline() {
  [[ ${PVX_OFFLINE:-0} == 1 ]] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  return 1
}

# net::fetch <url> <destino> [rótulo] [max_time=120] — baixa <url> pra <destino> (arquivo),
# sempre via um "<destino>.part" temporário promovido só no sucesso (nunca deixa um download
# parcial "válido" no destino final). rc=4 em qualquer falha (offline, sem curl, ou o fetch
# em si). max_time menor faz sentido pra um índice pequeno (registry::refresh usa 30).
net::fetch() {
  local url=$1 dest=$2 max_time=${4:-120}
  local label=${3:-$url}
  if net::is_offline; then
    if [[ ${PVX_OFFLINE:-0} == 1 ]]; then
      log::error 'offline (PVX_OFFLINE=1) — não é possível baixar %s' "$label"
    else
      log::error 'curl não encontrado — não é possível baixar %s' "$label"
    fi
    return 4
  fi
  mkdir -p "$(dirname "$dest")" 2>/dev/null || true
  local rc=0
  # --connect-timeout 10 (não 5) e --retry 2: achado de verdade numa VPS de rede lenta/instável
  # onde um curl com timeout curto dava rc=28 (parecia bloqueio de firewall) mas o MESMO host,
  # sem timeout customizado (curl puro, ou git clone), funcionava — a conexão só demorava mais
  # pra fechar, não estava bloqueada. --retry cobre também uma falha isolada/transitória.
  curl -fsSL --connect-timeout 10 --max-time "$max_time" \
    --retry 2 --retry-delay 2 --retry-connrefused \
    -o "$dest.part" "$url" 2>/dev/null || rc=$?
  if ((rc != 0)); then
    rm -f "$dest.part"
    # traduz o rc do curl em vez de um "falha ao baixar" mudo — não afirma categoricamente
    # "bloqueado por firewall" pro rc=28: pode ser isso, mas também pode ser só uma rede com
    # latência alta pro timeout configurado (mesmo achado acima) — reporta as duas hipóteses.
    local motivo='motivo desconhecido'
    case $rc in
      6) motivo='DNS não resolveu o host' ;;
      7) motivo='conexão recusada — nada escutando ou bloqueado antes de chegar no host' ;;
      28)
        motivo="timeout de conexão mesmo após retry — pode ser porta bloqueada por firewall OU rede lenta/instável; tente 'curl -v $url' manualmente pra comparar"
        ;;
      22 | 35 | 60) motivo='servidor respondeu, mas com erro HTTP/TLS' ;;
    esac
    log::error 'falha ao baixar %s: %s (curl rc=%d: %s)' "$label" "$url" "$rc" "$motivo"
    return 4
  fi
  mv -f "$dest.part" "$dest"
  return 0
}

# net::fetch_to_cache <url> <diretório-cache> [rótulo] — variante de net::fetch que deriva o
# nome do arquivo de destino do basename da URL, e imprime o caminho final no sucesso.
net::fetch_to_cache() {
  local url=$1 cache_dir=$2 label=${3:-download} dest
  dest="$cache_dir/$(basename "$url")"
  net::fetch "$url" "$dest" "$label" || return $?
  printf '%s\n' "$dest"
}
