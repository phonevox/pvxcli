#!/usr/bin/env bash
# lib/core/reserved.sh — comandos core reservados para fases futuras (doctor/config/cache/
# paths/log/self-update). Existem só para bloquear o namespace (um módulo não pode se chamar
# "doctor") e dar um erro claro, em vez de deixar meia-implementação.
core::cmd_reserved() {
  printf 'pvx: comando "%s" reservado para uma fase futura (ainda não implementado nesta versão)\n' \
    "$PVX_CURRENT_CMD" >&2
  return 69
}
