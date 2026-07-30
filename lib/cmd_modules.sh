#!/usr/bin/env bash
# lib/cmd_modules.sh — subsistema `pvx modules`: list, install (--file local e <nome> via
# registry remoto), update, remove, help.

PVX_MODULES_DIR=${PVX_MODULES_DIR:-${PVX_ROOT_PREFIX:-}/opt/pvx/modules}

modules::_usage() {
  cat <<'EOF'
uso: pvx modules <subcomando> [args...]

subcomandos:
  list                          lista módulos instalados e disponíveis no registry
  install --file <tarball>      instala um módulo a partir de um tarball local (sem rede)
  install [--sha256 H] --file F idem, com verificação de checksum explícita
  install <nome>[,<nome>...]    instala via registry remoto (baixa e verifica o tarball)
  install <url-git> [--ref R]   instala direto de um repositório git, sem passar pelo registry
  update [<nome>|--all]         atualiza módulo(s) instalado(s) pra versão mais nova do registry
  remove <nome> [--purge]       remove um módulo (--purge também apaga o state próprio dele)
  help <nome>                   mostra a ajuda do módulo (--help do próprio entrypoint)
EOF
}

# modules::_is_git_url <string> — heurística: termina em .git (cobre https://.../repo.git e
# o atalho scp-like git@host:org/repo.git), ou usa esquema git://.
modules::_is_git_url() {
  case $1 in
    *.git | git://*) return 0 ;;
  esac
  return 1
}

core::cmd_modules() {
  local sub=${1:-}
  (($#)) && shift
  case $sub in
    list) modules::cmd_list "$@" ;;
    install) modules::cmd_install "$@" ;;
    update) modules::cmd_update "$@" ;;
    remove | uninstall) modules::cmd_remove "$@" ;;
    help) modules::cmd_help "$@" ;;
    '')
      # sem subcomando: com TTY de verdade dos dois lados, abre o submenu; senão (script/CI),
      # mantém o help estático de sempre — nunca fica esperando teclado num ambiente não-interativo.
      if [[ -t 0 && -t 1 ]]; then
        modules::_interactive_menu
      else
        modules::_usage
      fi
      ;;
    -h | --help) modules::_usage ;;
    *)
      log::error 'modules: subcomando desconhecido: %s' "$sub"
      modules::_usage >&2
      return "$PVX_EXIT_USAGE"
      ;;
  esac
}

# --- submenu interativo (`pvx modules` sem subcomando, com TTY) ------------------------------
# Cada ação roda e pausa antes de redesenhar o mesmo submenu; 'q'/ESC no seletor de ações
# devolve o controle pra quem chamou (o menu principal do pvx, ou o shell se for `pvx modules`
# direto no terminal).
modules::_interactive_menu() {
  pvx::require tui registry

  local -a options=(
    'list      lista módulos instalados e disponíveis no registry'
    'install   instala um módulo (registry, arquivo local ou url git)'
    'remove    remove um módulo instalado'
    'update    atualiza módulo(s) instalado(s)'
    'help      mostra a ajuda de um módulo instalado'
  )
  local -a keys=(list install remove update help)

  local i chosen
  while true; do
    if ! tui::select 'pvx modules — o que você quer fazer?' "${options[@]}"; then
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
    # "|| true" em cada ramo de propósito: essas funções já imprimem seu próprio log::error
    # antes de retornar rc≠0 (ex: update sem registry alcançável) — sem o "|| true", esse rc
    # vazaria como comando solto sob `set -e` e derrubaria o pvx inteiro no meio do menu, em
    # vez de só mostrar o erro e voltar pro mesmo submenu (achado testando de verdade no
    # container: `modules update` com registry indisponível crashava a sessão inteira).
    case $chosen in
      list) modules::cmd_list || true ;;
      install) modules::_interactive_install || true ;;
      remove) modules::_interactive_remove || true ;;
      update) modules::_interactive_update || true ;;
      help) modules::_interactive_help || true ;;
    esac

    tui::pause 'pressione enter pra continuar (q/esc volta)'
    ((TUI_BACK)) && return 0
  done
}

# modules::_installed_names — imprime (um por linha) o nome de cada módulo instalado.
modules::_installed_names() {
  local rows name _rest
  rows=$(registry::state_list)
  while IFS='|' read -r name _rest; do
    [[ -z $name ]] && continue
    printf '%s\n' "$name"
  done <<<"$rows"
}

modules::_interactive_install() {
  pvx::require tui

  local -a options=(
    'from registry   escolhe módulo(s) do índice remoto configurado'
    'from file       instala a partir de um tarball local (sem rede)'
    'from url        instala direto de um repositório git'
  )
  local -a keys=(registry file url)

  if ! tui::select 'modules install — de onde?' "${options[@]}"; then
    return 0
  fi
  local i chosen=''
  for ((i = 0; i < ${#options[@]}; i++)); do
    if [[ ${options[i]} == "$TUI_CHOICE" ]]; then
      chosen=${keys[i]}
      break
    fi
  done

  case $chosen in
    registry)
      # sem nomes, modules::cmd_install já mostra o checklist do que ainda não está instalado.
      modules::cmd_install || true
      ;;
    file)
      if ! tui::input 'caminho do tarball'; then
        printf 'cancelado.\n'
        return 0
      fi
      modules::cmd_install --file "$TUI_INPUT" || true
      ;;
    url)
      if ! tui::input 'URL do repositório git (ex: https://.../repo.git)'; then
        printf 'cancelado.\n'
        return 0
      fi
      local url=$TUI_INPUT ref=''
      tui::input 'ref — tag/branch/commit (opcional, enter pra pular)' && ref=$TUI_INPUT
      if [[ -n $ref ]]; then
        modules::cmd_install "$url" --ref "$ref" || true
      else
        modules::cmd_install "$url" || true
      fi
      ;;
  esac
  return 0
}

modules::_interactive_remove() {
  pvx::require tui exec

  local -a names=()
  mapfile -t names < <(modules::_installed_names)
  if ((${#names[@]} == 0)); then
    printf 'nenhum módulo instalado.\n'
    return 0
  fi

  if ! tui::select 'remover qual módulo?' "${names[@]}"; then
    return 0
  fi
  local name=$TUI_CHOICE

  if ! exec::confirm "remover '$name'? [y/N]" n; then
    printf 'cancelado.\n'
    return 0
  fi
  modules::cmd_remove "$name" || true
  return 0
}

modules::_interactive_update() {
  pvx::require tui

  local -a picks=('todos (--all)')
  local -a names=()
  mapfile -t names < <(modules::_installed_names)
  picks+=("${names[@]}")

  if ((${#names[@]} == 0)); then
    printf 'nenhum módulo instalado — nada pra atualizar.\n'
    return 0
  fi

  if ! tui::select 'atualizar qual módulo?' "${picks[@]}"; then
    return 0
  fi
  if [[ $TUI_CHOICE == 'todos (--all)' ]]; then
    modules::cmd_update --all || true
  else
    modules::cmd_update "$TUI_CHOICE" || true
  fi
  return 0
}

modules::_interactive_help() {
  pvx::require tui

  local -a names=()
  mapfile -t names < <(modules::_installed_names)
  if ((${#names[@]} == 0)); then
    printf 'nenhum módulo instalado.\n'
    return 0
  fi

  if ! tui::select 'ajuda de qual módulo?' "${names[@]}"; then
    return 0
  fi
  modules::cmd_help "$TUI_CHOICE" || true
  return 0
}

# --- list -------------------------------------------------------------------------------------
modules::cmd_list() {
  pvx::require registry json net

  local -A installed_version=() installed_command=()
  local rows name version command _rest
  rows=$(registry::state_list)
  while IFS='|' read -r name version command _rest; do
    [[ -z $name ]] && continue
    installed_version[$name]=$version
    installed_command[$name]=$command
  done <<<"$rows"

  registry::refresh 2>/dev/null || true
  local names_from_registry=''
  names_from_registry=$(registry::list_names 2>/dev/null) || names_from_registry=''

  if [[ -z $names_from_registry && ${#installed_version[@]} -eq 0 ]]; then
    printf 'nenhum módulo instalado, e o índice remoto está indisponível (sem rede/cache ainda).\n'
    return 0
  fi

  printf '%-16s %-10s %-10s %-14s %s\n' NAME INSTALLED AVAILABLE STATUS COMMAND
  local -A seen=()
  local n
  if [[ -n $names_from_registry ]]; then
    while IFS= read -r n; do
      [[ -z $n ]] && continue
      seen[$n]=1
      local avail status cmd
      avail=$(registry::field "$n" version 2>/dev/null) || avail='?'
      cmd=${installed_command[$n]:-$(registry::field "$n" command 2>/dev/null)}
      if [[ -n ${installed_version[$n]:-} ]]; then
        if [[ ${installed_version[$n]} == "$avail" ]]; then
          status=installed
        else
          status=outdated
        fi
        printf '%-16s %-10s %-10s %-14s %s\n' "$n" "${installed_version[$n]}" "$avail" "$status" "$cmd"
      else
        printf '%-16s %-10s %-10s %-14s %s\n' "$n" '-' "$avail" not-installed "$cmd"
      fi
    done <<<"$names_from_registry"
  fi
  for n in "${!installed_version[@]}"; do
    [[ -n ${seen[$n]:-} ]] && continue
    printf '%-16s %-10s %-10s %-14s %s\n' "$n" "${installed_version[$n]}" '-' local "${installed_command[$n]}"
  done
  return 0
}

# --- install ------------------------------------------------------------------------------
modules::cmd_install() {
  pvx::require registry json exec os net integrity
  local file='' force=0 expected_sha='' ref=''
  local -a names=()
  while (($#)); do
    case $1 in
      --file)
        file=${2:?--file requer um caminho}
        shift 2
        ;;
      --force)
        force=1
        shift
        ;;
      -y | --yes)
        # shellcheck disable=SC2034 # lido por lib/exec.sh (exec::confirm) mais adiante
        PVX_ASSUME_YES=1
        shift
        ;;
      --sha256)
        expected_sha=${2:?--sha256 requer um valor}
        shift 2
        ;;
      --ref)
        ref=${2:?--ref requer um valor (tag, branch ou commit)}
        shift 2
        ;;
      --)
        shift
        names+=("$@")
        break
        ;;
      -*)
        log::error 'install: opção desconhecida: %s' "$1"
        return "$PVX_EXIT_USAGE"
        ;;
      *)
        local IFS=,
        local -a split
        read -ra split <<<"$1"
        names+=(${split[@]+"${split[@]}"})
        shift
        ;;
    esac
  done

  if [[ -n $file ]]; then
    modules::install_from_file "$file" "$force" "$expected_sha"
    return $?
  fi

  # instalação direta via URL git, sem passar pelo registry — só faz sentido com um único
  # alvo (misturar isso com uma lista de nomes de registry seria ambíguo).
  if ((${#names[@]} == 1)) && modules::_is_git_url "${names[0]}"; then
    modules::_install_from_git "${names[0]}" "$ref" "$force"
    return $?
  fi
  if [[ -n $ref ]]; then
    log::error 'install: --ref só faz sentido junto de uma URL git'
    return "$PVX_EXIT_USAGE"
  fi

  if ((${#names[@]} == 0)); then
    # sem nome nem --file: só faz sentido perguntar interativamente se tem um TTY de verdade
    # dos dois lados (senão um script/CI ficaria esperando teclado pra sempre) — nesse caso,
    # mantém o erro de uso de sempre.
    if [[ ! -t 0 || ! -t 1 ]]; then
      log::error 'install: informe --file <tarball> ou um nome de módulo'
      modules::_usage >&2
      return "$PVX_EXIT_USAGE"
    fi

    pvx::require tui
    registry::refresh || return 4
    local -a available=() installed_names=()
    mapfile -t available < <(registry::list_names 2>/dev/null)
    if ((${#available[@]} == 0)); then
      log::error 'install: nenhum módulo disponível no registry (e nenhum nome foi informado)'
      return 4
    fi
    mapfile -t installed_names < <(registry::state_list | awk -F'|' '{print $1}')
    local -a pickable=() n
    for n in "${available[@]}"; do
      if ! printf '%s\n' "${installed_names[@]:-}" | grep -qx "$n"; then
        pickable+=("$n")
      fi
    done
    if ((${#pickable[@]} == 0)); then
      printf 'todos os módulos do registry já estão instalados.\n'
      return 0
    fi
    if ! tui::checklist 'quais módulos instalar?' "${pickable[@]}"; then
      printf 'cancelado.\n'
      return 0
    fi
    names=(${TUI_RESULT[@]+"${TUI_RESULT[@]}"})
    ((${#names[@]} == 0)) && return 0
  fi

  registry::refresh || return 4

  local name rc=0 any_failed=0
  for name in "${names[@]}"; do
    modules::_install_one_from_registry "$name" "$force" || {
      rc=$?
      any_failed=1
    }
  done
  ((any_failed)) && return "$rc"
  return 0
}

modules::_install_one_from_registry() {
  local name=$1 force=${2:-0} idx flat
  flat=$(registry::index_flat_path)
  if ! idx=$(registry::lookup "$name"); then
    log::error 'módulo não encontrado no registry: %s' "$name"
    return 3
  fi

  # compatibilidade de SO: por capacidade DECLARADA pelo módulo, não allowlist fechada do core.
  # Lista de famílias vazia = o módulo não se restringe a nenhuma família específica.
  local n_fam i fam ok_os=1
  n_fam=$(json::len "$flat" ".modules[$idx].os.families" 2>/dev/null) || n_fam=0
  if ((n_fam > 0)); then
    ok_os=0
    local cur_family
    cur_family=$(os::family)
    for ((i = 0; i < n_fam; i++)); do
      fam=$(json::get "$flat" ".modules[$idx].os.families[$i]")
      [[ $fam == "$cur_family" ]] && {
        ok_os=1
        break
      }
    done
  fi
  if ((!ok_os)) && ((!force)); then
    log::error 'módulo %s não declara suporte à família de SO desta central (%s) — use --force pra instalar mesmo assim' \
      "$name" "$(os::family)"
    return 8
  fi

  local requires_core
  requires_core=$(json::get_def "$flat" ".modules[$idx].requires.pvx_core" '*')
  if ! version::satisfies "$PVX_VERSION" "$requires_core"; then
    log::error 'módulo %s requer pvx-core %s (instalado aqui: %s)' "$name" "$requires_core" "$PVX_VERSION"
    return 8
  fi

  local n_pkg pkg
  local -a missing_pkgs=()
  n_pkg=$(json::len "$flat" ".modules[$idx].requires.packages" 2>/dev/null) || n_pkg=0
  for ((i = 0; i < n_pkg; i++)); do
    pkg=$(json::get "$flat" ".modules[$idx].requires.packages[$i]")
    command -v "$pkg" >/dev/null 2>&1 || missing_pkgs+=("$pkg")
  done
  if ((${#missing_pkgs[@]})); then
    local mgr
    mgr=$(os::pkg_manager 2>/dev/null) || mgr='<gerenciador de pacotes>'
    log::error 'módulo %s precisa de pacotes ausentes: %s (tente: %s install %s)' \
      "$name" "${missing_pkgs[*]}" "$mgr" "${missing_pkgs[*]}"
    return 8
  fi

  if json::get "$flat" ".modules[$idx].git.url" >/dev/null 2>&1; then
    local git_url git_ref
    git_url=$(json::get "$flat" ".modules[$idx].git.url")
    git_ref=$(json::get_def "$flat" ".modules[$idx].git.ref" '')
    modules::_install_from_git "$git_url" "$git_ref" "$force" registry
    return $?
  fi

  local url sha dl_file
  url=$(json::get "$flat" ".modules[$idx].tarball.url")
  sha=$(json::get "$flat" ".modules[$idx].tarball.sha256")
  dl_file=$(net::fetch_to_cache "$url" "$PVX_CACHE_DIR/downloads" "$name") || return 4

  modules::install_from_file "$dl_file" "$force" "$sha" registry "$url"
}

# modules::_git_clone_staging <url> [ref] — clona (shallow) e valida; deixa o resultado em
# $_MODULES_STAGING, o commit resolvido (se disponível) em $_MODULES_GIT_SHA, e a tier de
# verificação em $_MODULES_GIT_VERIFIED ("pinned" se <ref> já é um commit SHA completo de 40
# hex — imutável por natureza —, "ref" caso contrário, já que tag/branch podem ser movidos
# sem aviso pelo mantenedor do módulo, ao contrário de um sha256 de tarball).
modules::_git_clone_staging() {
  local url=$1 ref=${2:-}

  if ! command -v git >/dev/null 2>&1; then
    local mgr
    mgr=$(os::pkg_manager 2>/dev/null) || mgr='<gerenciador de pacotes>'
    log::error 'git não encontrado — não é possível instalar/atualizar módulos via git (tente: %s install git)' "$mgr"
    return 4
  fi

  local staging_root staging
  staging_root=$(pvx::tmpdir)/modules-staging
  mkdir -p "$staging_root"
  staging="$staging_root/git.$$"
  rm -rf "$staging"

  local -a clone_args=(--depth 1 --quiet)
  [[ -n $ref ]] && clone_args+=(--branch "$ref")
  if ! git clone "${clone_args[@]}" "$url" "$staging" >/dev/null 2>&1; then
    log::error 'falha ao clonar %s%s' "$url" "${ref:+ (ref: $ref)}"
    return 4
  fi

  _MODULES_GIT_SHA=$(git -C "$staging" rev-parse HEAD 2>/dev/null) || _MODULES_GIT_SHA=''
  rm -rf "$staging/.git"

  if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
    _MODULES_GIT_VERIFIED=pinned
  else
    _MODULES_GIT_VERIFIED=ref
  fi

  registry::validate_module_json "$staging/module.json" || return 6
  integrity::verify_sha256sums_dir "$staging" || return $?

  _MODULES_STAGING=$staging
  return 0
}

# modules::_install_from_git <url> [ref] [force] [origin=git] — instala direto de um
# repositório git (clonado via modules::_git_clone_staging), reaproveitando o mesmo caminho
# de publicação de modules::install_from_file (modules::_publish_staging).
modules::_install_from_git() {
  local url=$1 ref=${2:-} force=${3:-0} origin=${4:-git}
  modules::_git_clone_staging "$url" "$ref" || return $?
  local source_ref=$url
  [[ -n $_MODULES_GIT_SHA ]] && source_ref="$url#$_MODULES_GIT_SHA"
  modules::_publish_staging "$_MODULES_STAGING" "$force" "$origin" "$source_ref" \
    "$_MODULES_GIT_VERIFIED" "$_MODULES_GIT_SHA"
}

# modules::_extract_and_validate <tarball> — pré-scan de segurança + exige 1 único diretório
# de topo + extrai em staging + valida module.json + confere SHA256SUMS interno (se houver).
# Caminho do staging extraído fica em $_MODULES_STAGING no sucesso.
modules::_extract_and_validate() {
  local tarball=$1
  integrity::tar_safety_scan "$tarball" || return $?

  local top_dirs top_count
  top_dirs=$(integrity::tar_top_dir "$tarball")
  top_count=$(printf '%s\n' "$top_dirs" | grep -c .)
  if ((top_count != 1)); then
    log::error 'tarball deve ter exatamente 1 diretório de topo (encontrado %d)' "$top_count"
    return 11
  fi

  local staging_root staging
  staging_root=$(pvx::tmpdir)/modules-staging
  mkdir -p "$staging_root"
  staging="$staging_root/$top_dirs"
  rm -rf "$staging"
  if ! tar -xzf "$tarball" -C "$staging_root" 2>/dev/null; then
    log::error 'falha ao extrair o tarball: %s' "$tarball"
    return 1
  fi

  registry::validate_module_json "$staging/module.json" || return 6
  integrity::verify_sha256sums_dir "$staging" || return $?

  _MODULES_STAGING=$staging
  return 0
}

# modules::install_from_file <tarball> [force] [sha256_esperado] [origin] [source_ref]
modules::install_from_file() {
  local tarball=$1 force=${2:-0} expected_sha=${3:-} origin=${4:-file}
  local source_ref=${5:-$tarball}

  if [[ ! -r $tarball ]]; then
    log::error 'arquivo não encontrado ou sem permissão de leitura: %s' "$tarball"
    return 1
  fi

  local actual_sha verified=manifest
  actual_sha=$(integrity::sha256_file "$tarball") || return 1

  if [[ -n $expected_sha ]]; then
    if [[ $actual_sha != "$expected_sha" ]]; then
      log::error 'checksum não confere: esperado %s, obtido %s' "$expected_sha" "$actual_sha"
      return 5
    fi
    verified=$([[ $origin == registry ]] && printf 'index' || printf 'pinned')
  else
    log::warn 'sem checksum esperado; verificação limitada ao manifesto interno do tarball (sha256=%s)' \
      "$actual_sha"
  fi

  modules::_extract_and_validate "$tarball" || return $?
  modules::_publish_staging "$_MODULES_STAGING" "$force" "$origin" "$source_ref" "$verified" "$actual_sha"
}

# modules::_publish_staging <staging> <force> <origin> <source_ref> <verified> <content_sha>
# Publica um diretório de staging já validado (extraído de tarball OU clonado do git) como
# módulo instalado: copia config_files, roda o hook install, move pro destino final, cria o
# symlink de despacho, grava o registro em installed.db. Compartilhado entre
# modules::install_from_file e modules::_install_from_git — nenhuma das duas etapas daqui
# pra frente é específica de tarball ou de git.
modules::_publish_staging() {
  local staging=$1 force=${2:-0} origin=$3 source_ref=$4 verified=$5 content_sha=${6:-}

  local flat name command version entrypoint state_dir_flag
  flat=$(pvx::tmpdir)/install.$$.flat
  json::flatten_file "$staging/module.json" >"$flat"
  name=$(json::get "$flat" .name)
  command=$(json::get "$flat" .command)
  version=$(json::get "$flat" .version)
  entrypoint=$(json::get "$flat" .entrypoint)
  state_dir_flag=$(json::get_def "$flat" .state_dir false)

  local entry_abs="$staging/$entrypoint" entry_real staging_real
  if [[ ! -f $entry_abs ]]; then
    log::error 'entrypoint declarado não existe no pacote: %s' "$entrypoint"
    return 6
  fi
  staging_real=$(cd -P "$staging" && pwd)
  entry_real=$(cd -P "$(dirname "$entry_abs")" && pwd)/$(basename "$entry_abs")
  if [[ $entry_real != "$staging_real"/* ]]; then
    log::error 'entrypoint aponta pra fora do diretório do módulo: %s' "$entrypoint"
    return 6
  fi
  chmod +x "$entry_abs" 2>/dev/null || true

  if registry::state_is_installed "$name" && ((!force)); then
    local cur_ver
    cur_ver=$(registry::state_get "$name" version)
    if [[ $cur_ver == "$version" ]]; then
      log::info 'módulo %s já está instalado na versão %s (use --force para reinstalar)' "$name" "$version"
      return 0
    fi
  fi

  local existing_link="$PVX_STATE_DIR/commands/$command"
  if [[ -L $existing_link ]]; then
    local existing_target
    existing_target=$(readlink "$existing_link" 2>/dev/null) || existing_target=''
    if [[ $existing_target != "$PVX_MODULES_DIR/$name/"* ]]; then
      log::error 'comando "%s" já está em uso por outro módulo instalado' "$command"
      return 6
    fi
  fi

  local module_state_dir="$PVX_STATE_DIR/state/$name"
  if [[ $state_dir_flag == true ]]; then
    mkdir -p "$module_state_dir"
  fi

  local n_conf i cf src dst
  n_conf=$(json::len "$flat" .config_files 2>/dev/null) || n_conf=0
  for ((i = 0; i < n_conf; i++)); do
    cf=$(json::get "$flat" ".config_files[$i]")
    src="$staging/$cf"
    dst="$PVX_ETC_DIR/modules.d/$name/$cf"
    if [[ -r $src && ! -e $dst ]]; then
      mkdir -p "$(dirname "$dst")"
      cp "$src" "$dst"
    fi
  done

  local hook_install hook_rc=0
  hook_install=$(json::get_def "$flat" .hooks.install '')
  if [[ -n $hook_install ]]; then
    local hook_path="$staging/$hook_install"
    if [[ -r $hook_path ]]; then
      # roda via "bash <script>", não "$hook_path" direto: o staging vive debaixo de
      # pvx::tmpdir() (normalmente /tmp), que em sistemas endurecidos pode estar montado
      # noexec — nesse caso o kernel recusa executar o ARQUIVO diretamente (mesmo com +x),
      # mas nada impede um interpretador já executável (bash, num filesystem normal) de LER
      # o script como argumento. Achado de verdade testando num host com /tmp noexec.
      PVX_ROOT="$PVX_ROOT" PVX_LIB_DIR="$PVX_LIB_DIR" PVX_MODULE_NAME="$name" \
        PVX_MODULE_VERSION="$version" PVX_MODULE_DIR="$PVX_MODULES_DIR/$name" \
        PVX_STATE_DIR="$PVX_STATE_DIR" PVX_MODULE_STATE_DIR="$module_state_dir" \
        PVX_HOOK=install PVX_DRY_RUN="${PVX_DRY_RUN:-0}" \
        bash "$hook_path" || hook_rc=$?
    else
      log::warn 'hook install declarado mas não encontrado/legível: %s' "$hook_install"
    fi
  fi
  if ((hook_rc != 0)); then
    log::error 'hook install falhou (rc=%d) — abortando instalação de %s' "$hook_rc" "$name"
    return 7
  fi

  mkdir -p "$PVX_MODULES_DIR"
  local final_dir="$PVX_MODULES_DIR/$name"
  rm -rf "$final_dir"
  mv -T "$staging" "$final_dir" 2>/dev/null || mv "$staging" "$final_dir"

  mkdir -p "$PVX_STATE_DIR/commands"
  ln -sfn "$final_dir/$entrypoint" "$PVX_STATE_DIR/commands/$command"

  local meta_dir="$PVX_STATE_DIR/modules/$name"
  mkdir -p "$meta_dir"
  cp "$final_dir/module.json" "$meta_dir/module.json"
  (cd "$final_dir" && find . -type f) >"$meta_dir/files.list"
  [[ -r "$final_dir/SHA256SUMS" ]] && cp "$final_dir/SHA256SUMS" "$meta_dir/SHA256SUMS"
  printf '%s\n%s\n' "$origin" "$source_ref" >"$meta_dir/origin"

  local files_count
  files_count=$(wc -l <"$meta_dir/files.list" | tr -d ' ')

  registry::state_add_record "$name" "$version" "$command" "$origin" "$source_ref" "$content_sha" \
    "$verified" "$PVX_VERSION" "$files_count"

  log::info 'módulo %s (%s) instalado com sucesso — comando: pvx %s' "$name" "$version" "$command"
  return 0
}

# --- update -------------------------------------------------------------------------------
modules::cmd_update() {
  pvx::require registry json exec os net integrity
  local target=${1:-}

  registry::refresh || return 4

  local -a to_update=()
  if [[ -z $target || $target == --all ]]; then
    local rows name
    rows=$(registry::state_list)
    while IFS='|' read -r name _rest; do
      [[ -z $name ]] && continue
      to_update+=("$name")
    done <<<"$rows"
    if ((${#to_update[@]} == 0)); then
      log::info 'nenhum módulo instalado — nada pra atualizar'
      return 0
    fi
  else
    to_update=("$target")
  fi

  local name rc=0 any_failed=0
  for name in "${to_update[@]}"; do
    modules::_update_one "$name" || {
      rc=$?
      any_failed=1
    }
  done
  ((any_failed)) && return "$rc"
  return 0
}

modules::_update_one() {
  local name=$1
  if ! registry::state_is_installed "$name"; then
    log::error 'módulo não instalado: %s' "$name"
    return 1
  fi

  local idx
  if ! idx=$(registry::lookup "$name"); then
    log::warn 'módulo %s instalado localmente, mas ausente do registry — pulando update' "$name"
    return 0
  fi

  local flat cur_ver new_ver cmp
  flat=$(registry::index_flat_path)
  cur_ver=$(registry::state_get "$name" version)
  new_ver=$(json::get "$flat" ".modules[$idx].version")
  cmp=$(version::cmp "$new_ver" "$cur_ver")
  if [[ $cmp != 1 ]]; then
    log::info 'módulo %s já está na versão mais recente disponível (%s)' "$name" "$cur_ver"
    return 0
  fi

  local command
  command=$(registry::state_get "$name" command)

  if json::get "$flat" ".modules[$idx].git.url" >/dev/null 2>&1; then
    local git_url git_ref
    git_url=$(json::get "$flat" ".modules[$idx].git.url")
    git_ref=$(json::get_def "$flat" ".modules[$idx].git.ref" '')
    modules::_apply_update_git "$name" "$command" "$cur_ver" "$new_ver" "$git_url" "$git_ref"
    return $?
  fi

  local url sha
  url=$(json::get "$flat" ".modules[$idx].tarball.url")
  sha=$(json::get "$flat" ".modules[$idx].tarball.sha256")

  local dl_file
  dl_file=$(net::fetch_to_cache "$url" "$PVX_CACHE_DIR/downloads" "atualização de $name") || return 4

  modules::_apply_update "$name" "$command" "$cur_ver" "$new_ver" "$dl_file" "$sha"
}

# modules::_apply_update <nome> <comando> <versão-atual> <versão-nova> <tarball> <sha256-esperado>
modules::_apply_update() {
  local name=$1 command=$2 old_ver=$3 new_ver=$4 tarball=$5 expected_sha=${6:-}

  local actual_sha
  actual_sha=$(integrity::sha256_file "$tarball") || return 1
  if [[ -n $expected_sha && $actual_sha != "$expected_sha" ]]; then
    log::error 'checksum não confere pro update de %s: esperado %s, obtido %s' \
      "$name" "$expected_sha" "$actual_sha"
    return 5
  fi

  modules::_extract_and_validate "$tarball" || return $?
  modules::_apply_update_from_staging "$name" "$command" "$old_ver" "$new_ver" "$_MODULES_STAGING" \
    registry "$tarball" index "$actual_sha"
}

# modules::_apply_update_git <nome> <comando> <versão-atual> <versão-nova> <url-git> [ref]
modules::_apply_update_git() {
  local name=$1 command=$2 old_ver=$3 new_ver=$4 url=$5 ref=${6:-}

  modules::_git_clone_staging "$url" "$ref" || return $?
  local source_ref=$url
  [[ -n $_MODULES_GIT_SHA ]] && source_ref="$url#$_MODULES_GIT_SHA"

  modules::_apply_update_from_staging "$name" "$command" "$old_ver" "$new_ver" "$_MODULES_STAGING" \
    git "$source_ref" "$_MODULES_GIT_VERIFIED" "$_MODULES_GIT_SHA"
}

# modules::_apply_update_from_staging <nome> <comando> <ver-antiga> <ver-nova> <staging>
#   <origin> <source_ref> <verified> <content_sha>
# Publica com staging + rollback: se qualquer etapa falhar depois de mover o diretório antigo
# pra um caminho de rollback, o antigo é restaurado — nunca fica sem nenhuma versão publicada.
# Compartilhado entre modules::_apply_update (tarball) e modules::_apply_update_git.
modules::_apply_update_from_staging() {
  local name=$1 command=$2 old_ver=$3 new_ver=$4 staging=$5
  local origin=$6 source_ref=$7 verified=$8 content_sha=${9:-}

  local flat entrypoint hook_update
  flat=$(pvx::tmpdir)/update.$$.flat
  json::flatten_file "$staging/module.json" >"$flat"
  entrypoint=$(json::get "$flat" .entrypoint)
  hook_update=$(json::get_def "$flat" .hooks.update '')
  chmod +x "$staging/$entrypoint" 2>/dev/null || true

  local module_dir="$PVX_MODULES_DIR/$name"
  local module_state_dir="$PVX_STATE_DIR/state/$name"
  local hook_rc=0
  if [[ -n $hook_update && -r "$staging/$hook_update" ]]; then
    # via "bash <script>", não direto — ver o comentário equivalente em
    # modules::_publish_staging (staging vive debaixo de pvx::tmpdir(), que pode estar
    # montado noexec num sistema endurecido).
    PVX_ROOT="$PVX_ROOT" PVX_LIB_DIR="$PVX_LIB_DIR" PVX_MODULE_NAME="$name" \
      PVX_MODULE_VERSION="$new_ver" PVX_MODULE_OLD_VERSION="$old_ver" \
      PVX_MODULE_DIR="$module_dir" PVX_STATE_DIR="$PVX_STATE_DIR" \
      PVX_MODULE_STATE_DIR="$module_state_dir" PVX_HOOK=update \
      PVX_DRY_RUN="${PVX_DRY_RUN:-0}" \
      bash "$staging/$hook_update" || hook_rc=$?
  fi
  if ((hook_rc != 0)); then
    log::error 'hook update falhou (rc=%d) — mantendo %s na versão %s' "$hook_rc" "$name" "$old_ver"
    return 7
  fi

  local rollback_dir="$module_dir.rollback.$$"
  [[ -d $module_dir ]] && mv "$module_dir" "$rollback_dir"
  if ! { mv -T "$staging" "$module_dir" 2>/dev/null || mv "$staging" "$module_dir"; }; then
    log::error 'falha ao publicar a nova versão de %s — restaurando %s' "$name" "$old_ver"
    [[ -d $rollback_dir ]] && mv "$rollback_dir" "$module_dir"
    return 1
  fi
  rm -rf "$rollback_dir"

  mkdir -p "$PVX_STATE_DIR/commands"
  ln -sfn "$module_dir/$entrypoint" "$PVX_STATE_DIR/commands/$command"

  local meta_dir="$PVX_STATE_DIR/modules/$name"
  mkdir -p "$meta_dir"
  cp "$module_dir/module.json" "$meta_dir/module.json"
  (cd "$module_dir" && find . -type f) >"$meta_dir/files.list"
  [[ -r "$module_dir/SHA256SUMS" ]] && cp "$module_dir/SHA256SUMS" "$meta_dir/SHA256SUMS"
  printf '%s\n%s\n' "$origin" "$source_ref" >"$meta_dir/origin"

  local files_count
  files_count=$(wc -l <"$meta_dir/files.list" | tr -d ' ')
  registry::state_add_record "$name" "$new_ver" "$command" "$origin" "$source_ref" "$content_sha" \
    "$verified" "$PVX_VERSION" "$files_count"

  log::info 'módulo %s atualizado: %s -> %s' "$name" "$old_ver" "$new_ver"
  return 0
}

# --- remove ---------------------------------------------------------------------------------
modules::cmd_remove() {
  pvx::require registry json
  local name='' purge=0
  while (($#)); do
    case $1 in
      --purge)
        purge=1
        shift
        ;;
      -*)
        log::error 'remove: opção desconhecida: %s' "$1"
        return "$PVX_EXIT_USAGE"
        ;;
      *)
        name=$1
        shift
        ;;
    esac
  done
  if [[ -z $name ]]; then
    log::error 'remove: informe o nome do módulo'
    return "$PVX_EXIT_USAGE"
  fi
  if ! registry::state_is_installed "$name"; then
    log::error 'módulo não está instalado: %s' "$name"
    return 1
  fi

  local version command
  version=$(registry::state_get "$name" version)
  command=$(registry::state_get "$name" command)

  local module_dir="$PVX_MODULES_DIR/$name"
  local module_state_dir="$PVX_STATE_DIR/state/$name"
  local meta_dir="$PVX_STATE_DIR/modules/$name"

  local hook_uninstall hook_rc=0
  if [[ -r "$meta_dir/module.json" ]]; then
    local flat
    flat=$(pvx::tmpdir)/remove.$$.flat
    json::flatten_file "$meta_dir/module.json" >"$flat" 2>/dev/null || true
    hook_uninstall=$(json::get_def "$flat" .hooks.uninstall '' 2>/dev/null) || hook_uninstall=''
  fi
  if [[ -n $hook_uninstall && -r "$module_dir/$hook_uninstall" ]]; then
    # via "bash <script>" — ver o comentário em modules::_publish_staging.
    PVX_ROOT="$PVX_ROOT" PVX_LIB_DIR="$PVX_LIB_DIR" PVX_MODULE_NAME="$name" \
      PVX_MODULE_VERSION="$version" PVX_MODULE_DIR="$module_dir" \
      PVX_STATE_DIR="$PVX_STATE_DIR" PVX_MODULE_STATE_DIR="$module_state_dir" \
      PVX_HOOK=uninstall PVX_DRY_RUN="${PVX_DRY_RUN:-0}" \
      bash "$module_dir/$hook_uninstall" || hook_rc=$?
    if ((hook_rc != 0)); then
      log::warn 'hook uninstall retornou rc=%d (removendo mesmo assim)' "$hook_rc"
    fi
  fi

  rm -f "$PVX_STATE_DIR/commands/$command"
  rm -rf "$module_dir"
  rm -rf "$meta_dir"
  registry::state_del_record "$name"

  if ((purge)); then
    rm -rf "$module_state_dir"
    rm -rf "$PVX_ETC_DIR/modules.d/$name"
  fi

  local purge_note=''
  ((purge)) && purge_note=' (--purge)'
  log::info 'módulo %s removido%s' "$name" "$purge_note"
  return 0
}

# --- help -----------------------------------------------------------------------------------
modules::cmd_help() {
  pvx::require registry net
  local name=${1:-}
  if [[ -z $name ]]; then
    modules::_usage
    return 0
  fi
  if registry::state_is_installed "$name"; then
    local command
    command=$(registry::state_get "$name" command)
    local link="$PVX_STATE_DIR/commands/$command"
    if [[ -x $link ]]; then
      "$link" --help
      return $?
    fi
    log::error 'módulo %s instalado, mas o entrypoint não é executável: %s' "$name" "$link"
    return 1
  fi
  registry::refresh 2>/dev/null || true
  local summary
  if summary=$(registry::field "$name" summary 2>/dev/null); then
    printf '%s: %s\n(não instalado — rode "pvx modules install %s" primeiro)\n' "$name" "$summary" "$name"
    return 0
  fi
  log::error 'módulo desconhecido: %s' "$name"
  return 3
}
