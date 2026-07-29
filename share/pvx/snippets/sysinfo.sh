#!/usr/bin/env bash
# share/pvx/snippets/sysinfo.sh — `pvx sysinfo`: dump read-only de informações do sistema,
# ponto de partida de debugging (não muda nada, só relata). Sourced in-process pelo
# dispatcher (não é um processo filho) — ver bin/pvx's branch `kind=snippet`.
#
# Nunca `exit`/`return` != 0 por causa de um dado individual ausente (ex: asterisk não
# instalado): cada seção é isolada e reporta "n/a" pro que não se aplica, em vez de abortar o
# resto do relatório.

snippet::sysinfo::main() {
  pvx::require os paths registry snippets

  snippets::header 'pvx-core'
  snippets::kv versão "$PVX_VERSION"
  snippets::kv raiz "$PVX_ROOT"
  snippets::kv 'state dir' "$PVX_STATE_DIR"
  snippets::kv 'cache dir' "$PVX_CACHE_DIR"

  snippets::header 'sistema operacional'
  snippets::kv id "$(os::id 2>/dev/null || printf unknown)"
  snippets::kv família "$(os::family 2>/dev/null || printf unknown)"
  snippets::kv arquitetura "$(os::arch 2>/dev/null || printf unknown)"
  snippets::kv 'gerenciador de pacotes' "$(os::pkg_manager 2>/dev/null || printf 'nenhum conhecido')"
  if os::is_container 2>/dev/null; then
    snippets::kv container sim
  else
    snippets::kv container não
  fi
  if os::has_systemd 2>/dev/null; then
    snippets::kv systemd sim
  else
    snippets::kv systemd 'não (ou indisponível)'
  fi
  snippets::kv selinux "$(os::selinux_state 2>/dev/null || printf 'n/a')"
  if os::is_root 2>/dev/null; then
    snippets::kv 'rodando como' "root"
  else
    snippets::kv 'rodando como' "uid $EUID (não-root)"
  fi

  snippets::header 'caminhos conhecidos (Issabel/Asterisk)'
  local key
  for key in asterisk_etc asterisk_spool asterisk_log issabel_root issabel_web mysql_data httpd_conf; do
    if path::exists "$key" 2>/dev/null; then
      snippets::ok "$key -> $(path::get "$key")"
    else
      snippets::bad "$key -> $(path::get "$key" '?') (não encontrado)"
    fi
  done

  snippets::header 'processos'
  if command -v pgrep >/dev/null 2>&1 && pgrep -x asterisk >/dev/null 2>&1; then
    snippets::ok 'asterisk está rodando'
  else
    snippets::warn 'asterisk não está rodando (ou pgrep indisponível)'
  fi

  snippets::header 'módulos pvx instalados'
  local rows name version command _rest count=0
  rows=$(registry::state_list 2>/dev/null) || rows=''
  if [[ -n $rows ]]; then
    while IFS='|' read -r name version command _rest; do
      [[ -z $name ]] && continue
      snippets::kv "$name" "$version ($command)"
      count=$((count + 1))
    done <<<"$rows"
  fi
  ((count == 0)) && printf '  (nenhum módulo instalado)\n'

  snippets::header 'disco (state/cache do pvx)'
  local d
  for d in "$PVX_STATE_DIR" "$PVX_CACHE_DIR"; do
    if [[ -d $d ]] && command -v du >/dev/null 2>&1; then
      snippets::kv "$d" "$(du -sh "$d" 2>/dev/null | awk '{print $1}')"
    else
      snippets::kv "$d" '(não existe ainda)'
    fi
  done

  printf '\n'
  return 0
}
