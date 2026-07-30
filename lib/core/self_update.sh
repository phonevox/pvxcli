#!/usr/bin/env bash
# lib/core/self_update.sh — `pvx self-update`: atualiza o próprio pvx-core (não módulos, ver
# lib/cmd_modules.sh pra isso).
#
# Modelo de distribuição: install.sh empacota o checkout via tar (excluindo .git) em
# <prefix>/releases/<versão>/, com <prefix>/current apontando (symlink) pra release ativa —
# NÃO é um checkout git em produção. Por isso self-update busca um tarball de release remoto
# (igual a um módulo: manifesto JSON com version/changelog/tarball.url/tarball.sha256) e
# reaplica o mesmo padrão release-dir + troca atômica de symlink que o install.sh já usa, em
# vez de tentar `git pull` (que não teria .git pra operar num site instalado).
#
# Notificação: pvx::_self_update_notify (chamado só ao entrar no menu interativo, ver bin/pvx)
# respeita um cache com TTL (PVX_SELF_UPDATE_TTL) — nunca bate na rede em toda invocação de
# comando, só quando o cache expira e ainda assim de forma best-effort (nunca bloqueia/quebra
# o menu se a rede falhar). `pvx version` só LÊ esse cache (core::_self_update_print_cached_hint),
# nunca dispara fetch — mantém `pvx version` instantâneo mesmo scriptado.

# Ao contrário de PVX_REGISTRY_URL (que aponta pro fixture local por padrão — cada site pode
# ter seu próprio índice de módulos), o canal de update do PRÓPRIO pvx-core é o mesmo pra
# qualquer instalação: os releases publicados pelo workflow .github/workflows/release.yml em
# github.com/phonevox/pvxcli. "latest/download/self-update.json" é um alias estável do GitHub
# que sempre resolve pro manifesto do release mais recente (não-prerelease) — o manifesto em si
# já aponta pro tarball versionado certo. Uma central pode sobrescrever via /etc/pvx/pvx.conf
# (chave self_update_url) se precisar apontar pra um mirror/fork próprio.
PVX_SELF_UPDATE_URL=${PVX_SELF_UPDATE_URL:-https://github.com/phonevox/pvxcli/releases/latest/download/self-update.json}
PVX_SELF_UPDATE_TTL=${PVX_SELF_UPDATE_TTL:-86400}
PVX_SELF_UPDATE_KEEP=${PVX_SELF_UPDATE_KEEP:-3}

core::_self_update_usage() {
  cat <<'EOF'
uso: pvx self-update [check]

sem argumento: verifica se há uma versão nova (manifesto remoto), mostra o changelog e, se
encontrada, pergunta antes de baixar/instalar (respeita -y/--yes/PVX_ASSUME_YES; sem TTY, só
reporta e não aplica nada).

  check   só verifica e reporta — nunca baixa/instala nada, mesmo com -y

só aplicável em instalações feitas via install.sh (layout <prefix>/releases/<versão> +
<prefix>/current) — checkouts de desenvolvimento não são suportados por este comando.
EOF
}

# --- cache de notificação (usado tanto pelo check ao vivo quanto pelo aviso do menu) ---------
core::_self_update_cache_file() { printf '%s/self-update.cache\n' "$PVX_CACHE_DIR"; }

# Preenche _SU_CACHE_CHECKED_AT (epoch, 0 se nunca) e _SU_CACHE_LATEST (vazio se sem cache).
core::_self_update_cache_read() {
  _SU_CACHE_CHECKED_AT=0
  _SU_CACHE_LATEST=''
  local f
  f=$(core::_self_update_cache_file)
  [[ -r $f ]] || return 0
  { read -r _SU_CACHE_CHECKED_AT; read -r _SU_CACHE_LATEST; } <"$f" 2>/dev/null
  [[ $_SU_CACHE_CHECKED_AT =~ ^[0-9]+$ ]] || _SU_CACHE_CHECKED_AT=0
  return 0
}

core::_self_update_cache_write() {
  local latest=$1 f now
  f=$(core::_self_update_cache_file)
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  printf -v now '%(%s)T' -1
  printf '%s\n%s\n' "$now" "$latest" >"$f.tmp" && mv -f "$f.tmp" "$f"
  return 0
}

# core::_self_update_fetch_manifest — baixa+valida o manifesto remoto; imprime o caminho do
# .flat (json::get) no stdout. rc=4 em qualquer falha de rede/parse (mesma convenção de
# registry::refresh).
core::_self_update_fetch_manifest() {
  pvx::require json net
  if net::is_offline; then
    log::error 'self-update: sem rede (offline ou curl ausente) — não é possível verificar'
    return 4
  fi
  local tmp flat
  tmp=$(pvx::tmpdir)/self-update-manifest.json
  net::fetch "$PVX_SELF_UPDATE_URL" "$tmp" 'manifesto de atualização do pvx-core' 15 || return 4
  flat=$(pvx::tmpdir)/self-update-manifest.flat
  if ! json::flatten_file "$tmp" >"$flat" 2>/dev/null; then
    log::error 'manifesto de atualização retornou um JSON inválido: %s' "$PVX_SELF_UPDATE_URL"
    return 4
  fi
  printf '%s\n' "$flat"
  return 0
}

# core::_self_update_check_and_report — fetch AO VIVO (ignora TTL do cache — é uma ação
# explícita do usuário), imprime status e changelog, e atualiza o cache de notificação de
# passagem. Preenche _SU_AVAILABLE (0/1), _SU_LATEST, _SU_TARBALL_URL, _SU_TARBALL_SHA.
core::_self_update_check_and_report() {
  pvx::require registry json
  _SU_AVAILABLE=0
  _SU_LATEST=''
  _SU_TARBALL_URL=''
  _SU_TARBALL_SHA=''

  local flat
  flat=$(core::_self_update_fetch_manifest) || return $?

  _SU_LATEST=$(json::get "$flat" .version 2>/dev/null) || _SU_LATEST=''
  if [[ -z $_SU_LATEST ]]; then
    log::error 'self-update: manifesto não informa "version": %s' "$PVX_SELF_UPDATE_URL"
    return 4
  fi
  _SU_TARBALL_URL=$(json::get_def "$flat" .tarball.url '')
  _SU_TARBALL_SHA=$(json::get_def "$flat" .tarball.sha256 '')
  local changelog
  changelog=$(json::get_def "$flat" .changelog '')

  core::_self_update_cache_write "$_SU_LATEST"

  printf 'versão instalada:  %s\n' "$PVX_VERSION"
  printf 'versão disponível: %s\n' "$_SU_LATEST"
  if [[ $(version::cmp "$_SU_LATEST" "$PVX_VERSION") == 1 ]]; then
    _SU_AVAILABLE=1
    [[ -n $changelog ]] && printf '\nnovidades:\n%s\n' "$changelog"
  else
    printf 'já está na versão mais recente disponível.\n'
  fi
  return 0
}

# core::_self_update_notify — chamado só ao entrar no menu interativo (ver bin/pvx). Só bate
# na rede se o cache expirou (PVX_SELF_UPDATE_TTL) e SEMPRE em melhor esforço: qualquer falha
# de rede é silenciosa (nunca atrapalha quem só queria abrir o menu). Nunca aplica nada — só
# imprime um aviso de uma linha se achar algo mais novo que PVX_VERSION.
core::_self_update_notify() {
  [[ ${PVX_OFFLINE:-0} == 1 ]] && return 0
  pvx::require registry

  core::_self_update_cache_read
  local now age
  printf -v now '%(%s)T' -1
  age=$((now - _SU_CACHE_CHECKED_AT))

  if ((age >= PVX_SELF_UPDATE_TTL)); then
    local flat latest
    if flat=$(core::_self_update_fetch_manifest 2>/dev/null); then
      pvx::require json
      latest=$(json::get "$flat" .version 2>/dev/null) || latest=''
      [[ -n $latest ]] && core::_self_update_cache_write "$latest"
    fi
    core::_self_update_cache_read
  fi

  [[ -n $_SU_CACHE_LATEST ]] || return 0
  [[ $(version::cmp "$_SU_CACHE_LATEST" "$PVX_VERSION") == 1 ]] || return 0
  log::warn 'atualização disponível: pvx-core %s (instalado: %s)' "$_SU_CACHE_LATEST" "$PVX_VERSION"
  log::hint "rode 'pvx self-update' pra atualizar"
  return 0
}

# core::_self_update_print_cached_hint — usado por `pvx version`: só LÊ o cache (nunca faz
# fetch), pra manter `pvx version` instantâneo/scriptável mesmo com self-update configurado.
core::_self_update_print_cached_hint() {
  pvx::require registry
  core::_self_update_cache_read
  [[ -n $_SU_CACHE_LATEST ]] || return 0
  [[ $(version::cmp "$_SU_CACHE_LATEST" "$PVX_VERSION") == 1 ]] || return 0
  printf 'atualização disponível: %s (rode "pvx self-update")\n' "$_SU_CACHE_LATEST"
  return 0
}

# --- apply: download, verifica, extrai, publica como nova release, troca o symlink current --

# core::_self_update_prune_releases <prefix> — mantém as PVX_SELF_UPDATE_KEEP releases mais
# recentes (por ordem de versão) além da que "current" aponta agora (sempre preservada,
# nunca conta contra o limite) — best-effort, nunca falha a atualização por causa disso.
core::_self_update_prune_releases() {
  local prefix=$1 cur_target
  cur_target=$(readlink "$prefix/current" 2>/dev/null) || cur_target=''
  local -a dirs=()
  mapfile -t dirs < <(find "$prefix/releases" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -rV)
  local d kept=0
  for d in ${dirs[@]+"${dirs[@]}"}; do
    [[ $d == "$cur_target" ]] && continue
    ((kept++))
    ((kept > PVX_SELF_UPDATE_KEEP)) && rm -rf "$d"
  done
  return 0
}

# core::_self_update_apply — precondição: _SU_LATEST/_SU_TARBALL_URL/_SU_TARBALL_SHA já
# preenchidos por core::_self_update_check_and_report.
core::_self_update_apply() {
  pvx::require integrity net os

  local su_prefix=${PVX_ROOT%/releases/*}
  if [[ $su_prefix == "$PVX_ROOT" || ! -d "$su_prefix/releases" ]]; then
    log::error 'self-update: esta instalação não usa o layout releases/current (PVX_ROOT=%s) — não aplicável (checkout de desenvolvimento?)' "$PVX_ROOT"
    return "$PVX_EXIT_UNSUPPORTED"
  fi
  if [[ -z $_SU_TARBALL_URL ]]; then
    log::error 'self-update: manifesto não informa a URL do pacote (tarball.url)'
    return 4
  fi

  os::require_root 'pvx self-update'

  local dl_file
  dl_file=$(net::fetch_to_cache "$_SU_TARBALL_URL" "$PVX_CACHE_DIR/downloads" 'pacote de atualização do pvx-core') || return 4

  local actual_sha
  actual_sha=$(integrity::sha256_file "$dl_file") || return 1
  if [[ -n $_SU_TARBALL_SHA ]]; then
    if [[ $actual_sha != "$_SU_TARBALL_SHA" ]]; then
      log::error 'self-update: checksum não confere: esperado %s, obtido %s' "$_SU_TARBALL_SHA" "$actual_sha"
      return 5
    fi
  else
    log::warn 'self-update: manifesto sem sha256 — verificação limitada à segurança do tar'
  fi

  integrity::tar_safety_scan "$dl_file" || return $?
  local top_dirs top_count
  top_dirs=$(integrity::tar_top_dir "$dl_file")
  top_count=$(printf '%s\n' "$top_dirs" | grep -c .)
  if ((top_count != 1)); then
    log::error 'self-update: pacote deve ter exatamente 1 diretório de topo (encontrado %d)' "$top_count"
    return 11
  fi

  local staging_root staging
  staging_root=$(pvx::tmpdir)/self-update-staging
  mkdir -p "$staging_root"
  staging="$staging_root/$top_dirs"
  rm -rf "$staging"
  if ! tar -xzf "$dl_file" -C "$staging_root" 2>/dev/null; then
    log::error 'self-update: falha ao extrair o pacote de atualização'
    return 1
  fi

  # "-r", não "-x": o staging vive debaixo de pvx::tmpdir() (normalmente /tmp), que em sistemas
  # endurecidos pode estar montado noexec — nesse caso o próprio kernel responde "-x" como falso
  # mesmo com o bit +x correto no arquivo (mesmo achado de modules::_publish_staging, testado de
  # verdade num container com /tmp noexec). O chmod abaixo garante o bit certo de qualquer jeito
  # depois que o release for copiado pro destino final (que não é noexec).
  if [[ ! -r "$staging/bin/pvx" || ! -r "$staging/VERSION" ]]; then
    log::error 'self-update: pacote não parece um release válido do pvx-core (bin/pvx ou VERSION ausente)'
    return 6
  fi
  chmod +x "$staging/bin/pvx" 2>/dev/null || true
  local staged_version
  read -r staged_version <"$staging/VERSION"
  if [[ $staged_version != "$_SU_LATEST" ]]; then
    log::error 'self-update: versão dentro do pacote (%s) não bate com a anunciada no manifesto (%s)' \
      "$staged_version" "$_SU_LATEST"
    return 6
  fi

  local release_dir="$su_prefix/releases/$staged_version"
  rm -rf "$release_dir"
  mkdir -p "$release_dir"
  # copia (não move) o staging pro destino final: staging vive debaixo de pvx::tmpdir(),
  # possivelmente noutro filesystem — `mv` entre filesystems falharia/copiaria devagar do
  # mesmo jeito, então usa tar (preserva permissões) igual ao install.sh.
  tar -C "$staging" -cf - . | tar -C "$release_dir" -xf -

  if ! ln -sfn "$release_dir" "$su_prefix/current"; then
    log::error 'self-update: falha ao apontar "current" pra nova release — mantendo %s' "$PVX_VERSION"
    rm -rf "$release_dir"
    return 1
  fi

  core::_self_update_cache_write "$staged_version"
  core::_self_update_prune_releases "$su_prefix"

  log::info 'pvx-core atualizado: %s -> %s (%s)' "$PVX_VERSION" "$staged_version" "$release_dir"
  printf 'pvx-core atualizado: %s -> %s\n' "$PVX_VERSION" "$staged_version"
  printf '(releases antigas mantidas em %s/releases pra rollback manual — troque o symlink "current" de volta se precisar)\n' "$su_prefix"
  return 0
}

core::cmd_self_update() {
  pvx::require registry json net integrity exec os

  case ${1:-} in
    -h | --help)
      core::_self_update_usage
      return 0
      ;;
    check)
      core::_self_update_check_and_report
      return $?
      ;;
    '') ;;
    *)
      log::error 'self-update: subcomando desconhecido: %s' "$1"
      core::_self_update_usage >&2
      return "$PVX_EXIT_USAGE"
      ;;
  esac

  core::_self_update_check_and_report || return $?
  ((_SU_AVAILABLE)) || return 0

  printf '\n'
  if ! exec::confirm 'atualizar agora? [y/N]' n; then
    printf 'cancelado.\n'
    return 0
  fi

  core::_self_update_apply
}
