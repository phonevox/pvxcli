# completions/pvx.bash — autocomplete do bash pro comando `pvx`.
#
# Instalação (escolha uma):
#   eval "$(pvx completion bash)"                                               # só na sessão atual
#   pvx completion bash | sudo tee /etc/bash_completion.d/pvx >/dev/null        # rhel-like
#   pvx completion bash | sudo tee /usr/share/bash-completion/completions/pvx >/dev/null  # debian-like
#
# Não depende do pacote `bash-completion` estar instalado (usa `_init_completion` se existir,
# senão monta cur/prev na mão) — o piso é só bash >= 4.2, igual ao resto do pvx-core.
#
# shellcheck disable=SC2207 # `COMPREPLY=($(compgen -W ...))` é o idioma padrão de completion
# script (compgen já emite um candidato por linha, de propósito, pra isso) — não é o bug de
# word-splitting que o SC2207 normalmente pega, é assim que todo completion script faz.

_pvx_completions() {
  local cur prev
  if declare -F _init_completion >/dev/null 2>&1; then
    _init_completion -n : || true
  fi
  cur=${cur:-${COMP_WORDS[COMP_CWORD]}}
  prev=${prev:-${COMP_WORDS[COMP_CWORD - 1]:-}}

  local core_cmds='modules sysinfo completion help version'
  local global_opts='-h --help -V --version -v --verbose -q --quiet --debug --trace
    --log-level= --color= --no-color -n --dry-run -y --yes --offline --config'

  # comandos de módulo instalado: um symlink por comando em $PVX_STATE_DIR/commands/
  local module_cmds=''
  if [[ -n ${PVX_STATE_DIR:-} && -d $PVX_STATE_DIR/commands ]]; then
    module_cmds=$(command ls "$PVX_STATE_DIR/commands" 2>/dev/null)
  fi

  # comandos "snippet" embutidos: um arquivo <cmd>.sh por comando
  local snippet_cmds=''
  if [[ -n ${PVX_ROOT:-} && -d $PVX_ROOT/share/pvx/snippets ]]; then
    local f
    for f in "$PVX_ROOT"/share/pvx/snippets/*.sh; do
      [[ -e $f ]] || continue
      f=${f##*/}
      snippet_cmds+="${f%.sh} "
    done
  fi

  if ((COMP_CWORD == 1)); then
    COMPREPLY=($(compgen -W "$core_cmds $module_cmds $snippet_cmds $global_opts" -- "$cur"))
    return 0
  fi

  # nomes de módulo instalados, pra `modules remove/update/help <nome>`
  local installed_names=''
  if [[ -n ${PVX_STATE_DIR:-} && -r $PVX_STATE_DIR/installed.db ]]; then
    installed_names=$(awk -F'|' '{print $1}' "$PVX_STATE_DIR/installed.db" 2>/dev/null)
  fi

  case ${COMP_WORDS[1]} in
    modules)
      case ${COMP_WORDS[2]:-} in
        '')
          COMPREPLY=($(compgen -W 'list install update remove uninstall help' -- "$cur"))
          ;;
        install)
          if [[ $prev == --file ]]; then
            COMPREPLY=($(compgen -f -- "$cur"))
          else
            COMPREPLY=($(compgen -W '--file --force -y --yes --sha256' -- "$cur"))
          fi
          ;;
        update)
          COMPREPLY=($(compgen -W "--all $installed_names" -- "$cur"))
          ;;
        remove | uninstall)
          COMPREPLY=($(compgen -W "--purge $installed_names" -- "$cur"))
          ;;
        help)
          COMPREPLY=($(compgen -W "$installed_names" -- "$cur"))
          ;;
        *) ;;
      esac
      ;;
    completion)
      COMPREPLY=($(compgen -W 'bash' -- "$cur"))
      ;;
    help)
      COMPREPLY=($(compgen -W "$core_cmds $module_cmds $snippet_cmds" -- "$cur"))
      ;;
    *)
      # comando de módulo/snippet desconhecido do completion script — não tenta adivinhar
      # as ações dele (isso vive no entrypoint do próprio módulo, fora do nosso alcance aqui).
      ;;
  esac
}

complete -F _pvx_completions pvx
