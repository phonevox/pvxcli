#!/usr/bin/env bash
# lib/cmd_modules.sh — subsistema `pvx modules`. Nesta passada: list (só instalados, sem
# índice remoto ainda), install --file (local, sem rede), remove, help. `install <nome>` via
# registry remoto e `update` chegam quando registry/index.json existir de verdade (Task #9).

PVX_MODULES_DIR=${PVX_MODULES_DIR:-${PVX_ROOT_PREFIX:-}/opt/pvx/modules}

modules::_usage() {
  cat <<'EOF'
uso: pvx modules <subcomando> [args...]

subcomandos:
  list                          lista módulos instalados
  install --file <tarball>      instala um módulo a partir de um tarball local (sem rede)
  install [--sha256 H] --file F idem, com verificação de checksum explícita
  install <nome>[,<nome>...]    instala via registry remoto (ainda não disponível nesta versão)
  remove <nome> [--purge]       remove um módulo (--purge também apaga o state próprio dele)
  help <nome>                   mostra a ajuda do módulo (--help do próprio entrypoint)
EOF
}

core::cmd_modules() {
  local sub=${1:-}
  (($#)) && shift
  case $sub in
    list) modules::cmd_list "$@" ;;
    install) modules::cmd_install "$@" ;;
    remove | uninstall) modules::cmd_remove "$@" ;;
    help) modules::cmd_help "$@" ;;
    '' | -h | --help) modules::_usage ;;
    *)
      log::error 'modules: subcomando desconhecido: %s' "$sub"
      modules::_usage >&2
      return "$PVX_EXIT_USAGE"
      ;;
  esac
}

# --- list ---------------------------------------------------------------------------------
modules::cmd_list() {
  pvx::require registry
  local rows
  rows=$(registry::state_list)
  if [[ -z $rows ]]; then
    printf 'nenhum módulo instalado.\n'
    printf '(sem cache de índice remoto ainda nesta versão — use "pvx modules install --file <tarball>")\n'
    return 0
  fi
  printf '%-16s %-10s %-10s %s\n' NAME VERSION STATUS COMMAND
  local name version command _rest
  while IFS='|' read -r name version command _rest; do
    [[ -z $name ]] && continue
    printf '%-16s %-10s %-10s %s\n' "$name" "$version" installed "$command"
  done <<<"$rows"
  return 0
}

# --- install --------------------------------------------------------------------------------
modules::cmd_install() {
  pvx::require registry json exec
  local file='' force=0 expected_sha=''
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
        PVX_ASSUME_YES=1
        shift
        ;;
      --sha256)
        expected_sha=${2:?--sha256 requer um valor}
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
        names+=("$1")
        shift
        ;;
    esac
  done

  if [[ -n $file ]]; then
    modules::install_from_file "$file" "$force" "$expected_sha"
    return $?
  fi

  if ((${#names[@]} == 0)); then
    log::error 'install: informe --file <tarball> ou um nome de módulo'
    modules::_usage >&2
    return "$PVX_EXIT_USAGE"
  fi

  log::error 'install <nome> via registry remoto ainda não disponível nesta versão (use --file)'
  return "$PVX_EXIT_UNAVAILABLE"
}

# Pré-scan de segurança do tar: rejeita caminho absoluto e travessia de diretório ("..").
modules::_tar_safety_scan() {
  local tarball=$1 line seg
  local -a segs
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    if [[ $line == /* ]]; then
      log::error 'tarball inseguro: entrada com caminho absoluto: %s' "$line"
      return 11
    fi
    IFS='/' read -ra segs <<<"$line"
    for seg in "${segs[@]}"; do
      if [[ $seg == '..' ]]; then
        log::error 'tarball inseguro: travessia de diretório: %s' "$line"
        return 11
      fi
    done
  done < <(tar -tzf "$tarball" 2>/dev/null)
  return 0
}

modules::_tar_top_dir() {
  tar -tzf "$1" 2>/dev/null | awk -F/ '{print $1}' | sort -u
}

# modules::install_from_file <tarball> [force] [sha256_esperado]
modules::install_from_file() {
  local tarball=$1 force=${2:-0} expected_sha=${3:-}

  if [[ ! -r $tarball ]]; then
    log::error 'arquivo não encontrado ou sem permissão de leitura: %s' "$tarball"
    return 1
  fi

  local actual_sha verified=manifest
  actual_sha=$(registry::sha256_file "$tarball") || return 1

  if [[ -n $expected_sha ]]; then
    if [[ $actual_sha != "$expected_sha" ]]; then
      log::error 'checksum não confere: esperado %s, obtido %s' "$expected_sha" "$actual_sha"
      return 5
    fi
    verified=pinned
  else
    log::warn 'sem --sha256 explícito; verificação limitada ao manifesto interno do tarball (sha256=%s)' \
      "$actual_sha"
  fi

  modules::_tar_safety_scan "$tarball" || return $?

  local top_dirs top_count
  top_dirs=$(modules::_tar_top_dir "$tarball")
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

  local module_json="$staging/module.json"
  registry::validate_module_json "$module_json" || return 6

  if [[ -r "$staging/SHA256SUMS" ]]; then
    local sums_ok=0
    (
      cd "$staging" || exit 1
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c SHA256SUMS
      else
        shasum -a 256 -c SHA256SUMS
      fi
    ) >/dev/null 2>&1 && sums_ok=1
    if ((!sums_ok)); then
      log::error 'SHA256SUMS interno do módulo não confere após extração'
      return 5
    fi
  else
    log::warn 'tarball não tem SHA256SUMS interno — pulando verificação pós-extração'
  fi

  local flat name command version entrypoint state_dir_flag
  flat=$(pvx::tmpdir)/install.$$.flat
  json::flatten_file "$module_json" >"$flat"
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
    if [[ -x $hook_path ]]; then
      PVX_ROOT="$PVX_ROOT" PVX_LIB_DIR="$PVX_LIB_DIR" PVX_MODULE_NAME="$name" \
        PVX_MODULE_VERSION="$version" PVX_MODULE_DIR="$PVX_MODULES_DIR/$name" \
        PVX_STATE_DIR="$PVX_STATE_DIR" PVX_MODULE_STATE_DIR="$module_state_dir" \
        PVX_HOOK=install PVX_DRY_RUN="${PVX_DRY_RUN:-0}" \
        "$hook_path" || hook_rc=$?
    else
      log::warn 'hook install declarado mas não executável: %s' "$hook_install"
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
  printf 'file\n%s\n' "$tarball" >"$meta_dir/origin"

  local files_count
  files_count=$(wc -l <"$meta_dir/files.list" | tr -d ' ')

  registry::state_add_record "$name" "$version" "$command" file "$tarball" "$actual_sha" \
    "$verified" "$PVX_VERSION" "$files_count"

  log::info 'módulo %s (%s) instalado com sucesso — comando: pvx %s' "$name" "$version" "$command"
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
  if [[ -n $hook_uninstall && -x "$module_dir/$hook_uninstall" ]]; then
    PVX_ROOT="$PVX_ROOT" PVX_LIB_DIR="$PVX_LIB_DIR" PVX_MODULE_NAME="$name" \
      PVX_MODULE_VERSION="$version" PVX_MODULE_DIR="$module_dir" \
      PVX_STATE_DIR="$PVX_STATE_DIR" PVX_MODULE_STATE_DIR="$module_state_dir" \
      PVX_HOOK=uninstall PVX_DRY_RUN="${PVX_DRY_RUN:-0}" \
      "$module_dir/$hook_uninstall" || hook_rc=$?
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
  pvx::require registry
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
  log::error 'módulo não instalado: %s (registry remoto ainda não disponível nesta versão)' "$name"
  return 3
}
