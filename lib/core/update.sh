#!/usr/bin/env bash
# lib/core/update.sh — `pvx update`: ponto de entrada único que unifica atualizar o próprio
# pvx-core (lib/core/self_update.sh) e os módulos instalados (lib/cmd_modules.sh) — antes eram
# dois comandos sem relação nenhuma na CLI ("pvx self-update" e "pvx modules update"), obrigando
# quem administra a central a lembrar dos dois separadamente. Este arquivo só dispacha; a lógica
# de cada metade continua inteira nos arquivos originais (nada duplicado).

core::_update_usage() {
  cat <<'EOF'
uso: pvx update [core|self|modules] [args...]

sem argumento: atualiza o pvx-core (se houver versão nova) e, na sequência, todos os módulos
instalados — nessa ordem, porque um módulo pode exigir uma versão nova do core (ver
"requires.pvx_core" no module.json de cada um) que acabou de ser aplicada.

  core, self          atualiza só o pvx-core (equivalente ao antigo "pvx self-update")
  core check          só verifica se há uma versão nova do pvx-core, sem aplicar nada
  modules [<nome>...] atualiza só módulo(s) instalado(s) — mesma sintaxe de "pvx modules update"
EOF
}

core::cmd_update() {
  local scope=${1:-}
  case $scope in
    -h | --help)
      core::_update_usage
      return 0
      ;;
    core | self)
      pvx::require core/self_update
      core::cmd_self_update "${@:2}"
      return $?
      ;;
    modules)
      pvx::require cmd_modules
      core::cmd_modules update "${@:2}"
      return $?
      ;;
    '')
      pvx::require core/self_update cmd_modules
      local core_rc=0 modules_rc=0
      core::cmd_self_update || core_rc=$?
      log::info 'update: atualizando módulos instalados...'
      core::cmd_modules update || modules_rc=$?
      ((core_rc != 0)) && return "$core_rc"
      return "$modules_rc"
      ;;
    *)
      log::error 'update: escopo desconhecido: %s (use core, self ou modules)' "$scope"
      core::_update_usage >&2
      return "$PVX_EXIT_USAGE"
      ;;
  esac
}
