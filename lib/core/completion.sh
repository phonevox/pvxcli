#!/usr/bin/env bash
# lib/core/completion.sh — `pvx completion <shell>`: imprime o script de autocomplete pra
# stdout (o usuário decide onde instalar — não escrevemos em /etc sozinhos).
core::cmd_completion() {
  local shell=${1:-}
  case $shell in
    bash)
      core::_completion_print_bash
      ;;
    '')
      if [[ -t 0 && -t 1 ]]; then
        core::_completion_interactive_menu
      else
        core::_completion_usage
      fi
      ;;
    -h | --help)
      core::_completion_usage
      ;;
    *)
      log::error 'completion: shell não suportado: %s (só "bash" por enquanto)' "$shell"
      return "$PVX_EXIT_USAGE"
      ;;
  esac
}

core::_completion_usage() {
  cat <<'EOF'
uso: pvx completion <shell>

shells suportados:
  bash

instalação (escolha uma):
  eval "$(pvx completion bash)"                                                       # só na sessão atual
  pvx completion bash | sudo tee /usr/share/bash-completion/completions/pvx >/dev/null # persistente, carrega sob demanda

sem shell nenhum, num terminal interativo, "pvx completion" pergunta se quer instalar
automaticamente (padrão, já ativa na sessão atual) ou só ver o script.
EOF
}

core::_completion_print_bash() {
  local script="$PVX_ROOT/completions/pvx.bash"
  if [[ ! -r $script ]]; then
    log::error 'script de completion não encontrado: %s (instalação quebrada?)' "$script"
    return 1
  fi
  cat "$script"
}

# --- submenu interativo (`pvx completion` sem shell, com TTY) --------------------------------
core::_completion_interactive_menu() {
  pvx::require tui

  # "instalar automaticamente" primeiro de propósito: cursor começa aqui, então enter sozinho
  # já dispara a instalação — é o comportamento default pedido.
  local -a options=(
    'instalar automaticamente   grava o completion no local padrão do sistema (requer root)'
    'mostrar o script           imprime pro terminal, você decide onde instalar'
  )
  local -a keys=(auto show)

  if ! tui::select 'pvx completion — o que você quer fazer?' "${options[@]}"; then
    return 0
  fi
  local i chosen=''
  for ((i = 0; i < ${#options[@]}; i++)); do
    if [[ ${options[i]} == "$TUI_CHOICE" ]]; then
      chosen=${keys[i]}
      break
    fi
  done

  printf '\n'
  # "|| true" nos dois ramos: sem isso, uma falha aqui (ex: auto-install sem root) vazaria como
  # comando solto sob `set -e` e derrubaria o pvx inteiro — mesmo achado de lib/cmd_modules.sh
  # e lib/core/registry.sh, testado de verdade no container.
  case $chosen in
    auto) core::_completion_auto_install || true ;;
    show) core::_completion_print_bash || true ;;
  esac

  # picker de tiro único (não tem "mesmo submenu" pra redesenhar depois) — a pausa é só pra
  # dar tempo de ler a saída antes de voltar pro menu principal; TUI_BACK não muda esse fato,
  # então nem precisa ser checado aqui. IMPORTANTE: return 0 explícito por último — sem isso,
  # esta função (chamada como último comando de core::cmd_completion, por sua vez chamada como
  # comando solto em core::_run_owned_submenu) herdaria o rc do último teste `[[ ... ]]`
  # rodado, e sob `set -e` um rc≠0 nesse ponto derruba o pvx inteiro (bug real, pego testando
  # no container: `[[ $resp == q ]] && return 0` como ÚLTIMA linha da função, com a condição
  # falsa, deixa a função inteira retornando 1 mesmo sem nada ter dado errado).
  tui::pause 'pressione enter pra continuar'
  return 0
}

# core::_completion_auto_install — grava completions/pvx.bash em
# /usr/share/bash-completion/completions/pvx: é o diretório de CARREGAMENTO SOB DEMANDA do
# bash-completion >= 2.0 (via _completion_loader), não o /etc/bash_completion.d/ clássico
# (esse sim exige sessão nova, porque só é lido uma vez no login via /etc/profile.d). Com o
# arquivo aqui, o bash carrega e registra o completion sozinho na primeira vez que o técnico
# der <tab> depois de "pvx " — inclusive no MESMO shell que já está aberto agora. Não existe
# jeito de um processo filho (este script) empurrar `complete -F ...` pro shell pai de
# verdade (isso é limite de processo, não escolha de design) — carregar sob demanda é o único
# caminho real pra "já funcionar" sem pedir pro cliente abrir um shell novo ou dar source em
# nada. Mesmo diretório em Debian/Ubuntu e RHEL-like/Rocky (pacote bash-completion >= 2.0
# usa esse layout nas duas famílias) — não precisa branch por os::family aqui.
#
# Requer root, igual ao resto do pvx (`registry set`, etc.): sem privilégio, avisa e volta —
# não tenta escalar sozinho via sudo.
core::_completion_auto_install() {
  if ! os::is_root; then
    log::error 'completion (instalação automática) requer privilégios de root (rodando como uid %d)' "$EUID"
    log::hint 'tente: sudo pvx completion'
    return 0
  fi

  local dest=/usr/share/bash-completion/completions/pvx
  mkdir -p "$(dirname "$dest")"
  if ! core::_completion_print_bash >"$dest"; then
    return 1
  fi
  printf 'completion instalado em %s\n' "$dest"

  if [[ -r /usr/share/bash-completion/bash_completion || -r /etc/profile.d/bash_completion.sh ]]; then
    printf 'já ativo — o bash carrega esse arquivo sozinho na hora que você der <tab> depois de "pvx ", '
    printf 'sem precisar abrir um shell novo nem dar source em nada.\n'
  else
    local mgr
    mgr=$(os::pkg_manager 2>/dev/null) || mgr='<gerenciador de pacotes>'
    log::warn 'pacote bash-completion não encontrado nesta central — sem ele, o carregamento sob demanda não funciona'
    log::hint 'instale com: %s install bash-completion (uma vez só; depois disso o completion do pvx já funciona sozinho)' "$mgr"
  fi
  return 0
}
