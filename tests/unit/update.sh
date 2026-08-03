#!/usr/bin/env bash
# tests/unit/update.sh — testa lib/core/update.sh: só o DISPATCH de `pvx update` (escopo
# core/self/modules/default/desconhecido) — a lógica de cada metade já é testada em
# tests/unit/self_update.sh e tests/unit/cmd_modules.sh, então aqui core::cmd_self_update e
# core::cmd_modules são mockadas (funções, não `exec` — override direto funciona).
set -Eeuo pipefail

_TEST_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TEST_DIR/../.." && pwd)
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require color log os paths exec core/update
color::init
export PVX_LOG_DIR="$(pvx::tmpdir)/logtest"
log::init
# shellcheck source=/dev/null
source "$_TEST_DIR/../lib/assert.sh"

_calls_file="$(pvx::tmpdir)/update-calls.txt"

# core::cmd_update chama `pvx::require core/self_update cmd_modules` antes de delegar — sem
# marcar essas libs como já carregadas, pvx::require sourcia os arquivos DE VERDADE na primeira
# chamada, sobrescrevendo os mocks abaixo com as implementações reais. Marca como carregado
# igual ao que pvx::require faria sozinho depois do primeiro source de verdade.
declare -g _PVX_LIB_LOADED_core_self_update=1
declare -g _PVX_LIB_LOADED_cmd_modules=1

_reset_mocks() {
  : >"$_calls_file"
  core::cmd_self_update() { printf 'self_update:%s\n' "$*" >>"$_calls_file"; return "${_MOCK_SELF_UPDATE_RC:-0}"; }
  core::cmd_modules() { printf 'modules:%s\n' "$*" >>"$_calls_file"; return "${_MOCK_MODULES_RC:-0}"; }
}

# --- "core"/"self" só chama o self-update, nunca módulos --------------------------------------
_reset_mocks
core::cmd_update core >/dev/null 2>&1
test_01_scope_core_chama_so_self_update() {
  assert_eq 'update core: chama só core::cmd_self_update' 'self_update:' "$(cat "$_calls_file")"
}
assert_flush

_reset_mocks
core::cmd_update self check >/dev/null 2>&1
test_02_scope_self_repassa_args() {
  assert_eq 'update self check: repassa os args extras pro self_update' 'self_update:check' "$(cat "$_calls_file")"
}
assert_flush

# --- "modules" só chama módulos, nunca self-update ---------------------------------------------
_reset_mocks
core::cmd_update modules netinstall >/dev/null 2>&1
test_03_scope_modules_chama_so_modules() {
  assert_eq 'update modules netinstall: chama só core::cmd_modules, repassando "update netinstall"' \
    'modules:update netinstall' "$(cat "$_calls_file")"
}
assert_flush

# --- sem escopo: atualiza os DOIS, core primeiro ------------------------------------------------
_reset_mocks
core::cmd_update >/dev/null 2>&1
test_04_sem_escopo_chama_os_dois() {
  assert_eq 'update sem escopo: chama self_update E modules, nessa ordem' \
    "$(printf 'self_update:\nmodules:update\n')" "$(cat "$_calls_file")"
}
assert_flush

# --- sem escopo, core falha: modules ainda roda, rc reportado é o do core (mais grave) ---------
_reset_mocks
_MOCK_SELF_UPDATE_RC=4
update_rc=0
core::cmd_update >/dev/null 2>&1 || update_rc=$?
unset _MOCK_SELF_UPDATE_RC
test_05_core_falho_ainda_roda_modules() {
  assert_eq 'update sem escopo: core falhando não impede modules de rodar' \
    "$(printf 'self_update:\nmodules:update\n')" "$(cat "$_calls_file")"
}
test_06_core_falho_propaga_rc_do_core() {
  assert_eq 'update sem escopo: rc final é o do core quando ele falha' 4 "$update_rc"
}
assert_flush

# --- escopo desconhecido: erro de uso, nem self_update nem modules chamados --------------------
_reset_mocks
unknown_rc=0
core::cmd_update bogus >/dev/null 2>&1 || unknown_rc=$?
test_07_escopo_desconhecido_nao_chama_nada() {
  assert_eq 'update com escopo desconhecido: não chama nem self_update nem modules' '' "$(cat "$_calls_file")"
}
test_08_escopo_desconhecido_rc_usage() {
  assert_eq 'update com escopo desconhecido: sai com PVX_EXIT_USAGE' "$PVX_EXIT_USAGE" "$unknown_rc"
}
assert_flush

assert_summary
