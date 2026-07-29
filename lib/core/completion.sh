#!/usr/bin/env bash
# lib/core/completion.sh — `pvx completion <shell>`: imprime o script de autocomplete pra
# stdout (o usuário decide onde instalar — não escrevemos em /etc sozinhos).
core::cmd_completion() {
  local shell=${1:-}
  case $shell in
    bash)
      local script="$PVX_ROOT/completions/pvx.bash"
      if [[ ! -r $script ]]; then
        log::error 'script de completion não encontrado: %s (instalação quebrada?)' "$script"
        return 1
      fi
      cat "$script"
      ;;
    '' | -h | --help)
      cat <<'EOF'
uso: pvx completion <shell>

shells suportados:
  bash

instalação (escolha uma):
  eval "$(pvx completion bash)"                                               # só na sessão atual
  pvx completion bash | sudo tee /etc/bash_completion.d/pvx >/dev/null        # rhel-like, persistente
  pvx completion bash | sudo tee /usr/share/bash-completion/completions/pvx >/dev/null  # debian-like
EOF
      ;;
    *)
      log::error 'completion: shell não suportado: %s (só "bash" por enquanto)' "$shell"
      return "$PVX_EXIT_USAGE"
      ;;
  esac
}
