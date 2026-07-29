#!/usr/bin/env bash
# tests/unit/registry.sh — testa lib/registry.sh: version::cmp/satisfies, estado local
# (installed.db) e validação de module.json. Roda contra PVX_ROOT_PREFIX apontando pra uma
# árvore fixture (nunca toca em /var/lib/pvx de verdade).
set -Eeuo pipefail

_TEST_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TEST_DIR/../.." && pwd)
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require color log os paths exec json registry
color::init
export PVX_LOG_DIR="$(pvx::tmpdir)/logtest"
log::init
# shellcheck source=/dev/null
source "$_TEST_DIR/../lib/assert.sh"

# --- version::cmp -----------------------------------------------------------------------------
test_01_cmp_versoes_iguais() { assert_eq 'cmp: versões iguais' 0 "$(version::cmp 1.2.3 1.2.3)"; }
test_02_cmp_major_maior() { assert_eq 'cmp: major maior' 1 "$(version::cmp 2.0.0 1.9.9)"; }
test_03_cmp_minor_maior() { assert_eq 'cmp: minor maior' 1 "$(version::cmp 1.2.0 1.1.9)"; }
test_04_cmp_patch_maior() { assert_eq 'cmp: patch maior' 1 "$(version::cmp 1.2.3 1.2.2)"; }
test_05_cmp_menor_major() { assert_eq 'cmp: menor (major)' 2 "$(version::cmp 1.0.0 2.0.0)"; }
test_06_cmp_segmentos_diferentes() {
  assert_eq 'cmp: número de segmentos diferente (1.2 vs 1.2.0)' 0 "$(version::cmp 1.2 1.2.0)"
}
test_07_cmp_prerelease_menor() {
  assert_eq 'cmp: pré-release é menor que release' 2 "$(version::cmp 1.0.0-beta 1.0.0)"
}
test_08_cmp_release_maior() {
  assert_eq 'cmp: release é maior que pré-release' 1 "$(version::cmp 1.0.0 1.0.0-beta)"
}
test_09_cmp_dummy_real() {
  assert_eq 'cmp: duas versões 0.1.0 e 0.1.1 (caso real do dummy)' 2 "$(version::cmp 0.1.0 0.1.1)"
}
assert_flush

# --- version::satisfies ------------------------------------------------------------------------
test_10_satisfies_asterisco() { assert_true 'satisfies: * aceita qualquer versão' version::satisfies 0.0.1 '*'; }
test_11_satisfies_ge_igual() { assert_true 'satisfies: >= verdadeiro (igual)' version::satisfies 1.0.0 '>=1.0.0'; }
test_12_satisfies_ge_maior() { assert_true 'satisfies: >= verdadeiro (maior)' version::satisfies 1.0.1 '>=1.0.0'; }
test_13_satisfies_ge_falso() { assert_false 'satisfies: >= falso' version::satisfies 0.9.0 '>=1.0.0'; }
test_14_satisfies_gt_verdadeiro() { assert_true 'satisfies: > verdadeiro' version::satisfies 1.0.1 '>1.0.0'; }
test_15_satisfies_gt_falso() {
  assert_false 'satisfies: > falso (igual não conta)' version::satisfies 1.0.0 '>1.0.0'
}
test_16_satisfies_eq_verdadeiro() { assert_true 'satisfies: = verdadeiro' version::satisfies 1.0.0 '=1.0.0'; }
test_17_satisfies_eq_falso() { assert_false 'satisfies: = falso' version::satisfies 1.0.1 '=1.0.0'; }
test_18_satisfies_le_verdadeiro() { assert_true 'satisfies: <= verdadeiro' version::satisfies 1.0.0 '<=1.0.0'; }
test_19_satisfies_lt_verdadeiro() { assert_true 'satisfies: < verdadeiro' version::satisfies 0.9.0 '<1.0.0'; }
assert_flush

# --- estado local (installed.db) — isolado numa árvore fixture --------------------------------
# registry.sh usa PVX_STATE_DIR diretamente (mesma variável que bin/pvx exporta e usa pro
# despacho via symlinks), não path::get — ver comentário no topo de lib/registry.sh.
export PVX_STATE_DIR="$(pvx::tmpdir)/fixture_registry/var/lib/pvx"
mkdir -p "$PVX_STATE_DIR"

test_20_state_is_installed_falso_sem_db() {
  assert_false 'state_is_installed: falso quando installed.db nem existe ainda' \
    registry::state_is_installed dummy
}
assert_flush

registry::state_add_record dummy 0.1.0 dummy file /tmp/pvx-mod-dummy-0.1.0.tar.gz \
  abc123 manifest 0.1.0 5
test_21_state_is_installed_apos_add() {
  assert_true 'state_is_installed: verdadeiro após add_record' registry::state_is_installed dummy
}
test_22_state_get_version() { assert_eq 'state_get: version' 0.1.0 "$(registry::state_get dummy version)"; }
test_23_state_get_command() { assert_eq 'state_get: command' dummy "$(registry::state_get dummy command)"; }
test_24_state_get_origin() { assert_eq 'state_get: origin' file "$(registry::state_get dummy origin)"; }
test_25_state_get_verified() { assert_eq 'state_get: verified' manifest "$(registry::state_get dummy verified)"; }
test_26_state_get_files_count() { assert_eq 'state_get: files_count' 5 "$(registry::state_get dummy files_count)"; }

registry::state_add_record outro 2.0.0 outro registry file://x.tar.gz def456 index 0.1.0 3
test_27_state_list_2_registros() {
  assert_eq 'state_list: 2 registros após add de um segundo módulo' 2 \
    "$(registry::state_list | wc -l | tr -d ' ')"
}
assert_flush

# re-adicionar "dummy" com versão nova substitui o registro (não duplica)
registry::state_add_record dummy 0.1.1 dummy registry file://y.tar.gz ghi789 index 0.1.0 5
test_28_state_add_record_substitui() {
  assert_eq 'state_add_record: substitui em vez de duplicar' 0.1.1 "$(registry::state_get dummy version)"
}
test_29_state_list_ainda_2_apos_update() {
  assert_eq 'state_list: ainda 2 registros após update (não duplicou)' 2 \
    "$(registry::state_list | wc -l | tr -d ' ')"
}
assert_flush

registry::state_del_record dummy
test_30_state_is_installed_falso_apos_del() {
  assert_false 'state_is_installed: falso após del_record' registry::state_is_installed dummy
}
test_31_state_is_installed_outro_continua() {
  assert_true 'state_is_installed: "outro" continua instalado' registry::state_is_installed outro
}
test_32_state_list_1_registro_apos_remover() {
  assert_eq 'state_list: 1 registro após remover "dummy"' 1 \
    "$(registry::state_list | wc -l | tr -d ' ')"
}
assert_flush

unset PVX_STATE_DIR

# --- validação de module.json -------------------------------------------------------------
test_33_validate_aceita_dummy_real() {
  assert_rc 'validate_module_json: aceita o module.json real do dummy' 0 \
    -- registry::validate_module_json "$PVX_ROOT/modules/dummy/module.json"
}

invalid_dir="$(pvx::tmpdir)/invalid_modules"
mkdir -p "$invalid_dir"

write_invalid() { # <nome-do-caso> <conteúdo-json>
  printf '%s' "$2" >"$invalid_dir/$1.json"
}

write_invalid schema_errada '{"schema_version":2,"name":"x","command":"x","version":"1.0.0","entrypoint":"bin/x"}'
write_invalid nome_invalido '{"schema_version":1,"name":"X_Y","command":"x","version":"1.0.0","entrypoint":"bin/x"}'
write_invalid comando_reservado \
  '{"schema_version":1,"name":"meumod","command":"modules","version":"1.0.0","entrypoint":"bin/x"}'
write_invalid versao_invalida '{"schema_version":1,"name":"x","command":"x","version":"v1","entrypoint":"bin/x"}'
write_invalid sem_entrypoint '{"schema_version":1,"name":"x","command":"x","version":"1.0.0"}'
write_invalid entrypoint_absoluto \
  '{"schema_version":1,"name":"x","command":"x","version":"1.0.0","entrypoint":"/etc/passwd"}'
write_invalid entrypoint_path_traversal \
  '{"schema_version":1,"name":"x","command":"x","version":"1.0.0","entrypoint":"../../etc/passwd"}'
write_invalid json_quebrado '{"schema_version":1,'

test_34_validate_rejeita_schema_errada() {
  assert_rc "validate_module_json: rejeita caso 'schema_errada'" 6 \
    -- registry::validate_module_json "$invalid_dir/schema_errada.json"
}
test_35_validate_rejeita_nome_invalido() {
  assert_rc "validate_module_json: rejeita caso 'nome_invalido'" 6 \
    -- registry::validate_module_json "$invalid_dir/nome_invalido.json"
}
test_36_validate_rejeita_comando_reservado() {
  assert_rc "validate_module_json: rejeita caso 'comando_reservado'" 6 \
    -- registry::validate_module_json "$invalid_dir/comando_reservado.json"
}
test_37_validate_rejeita_versao_invalida() {
  assert_rc "validate_module_json: rejeita caso 'versao_invalida'" 6 \
    -- registry::validate_module_json "$invalid_dir/versao_invalida.json"
}
test_38_validate_rejeita_sem_entrypoint() {
  assert_rc "validate_module_json: rejeita caso 'sem_entrypoint'" 6 \
    -- registry::validate_module_json "$invalid_dir/sem_entrypoint.json"
}
test_39_validate_rejeita_entrypoint_absoluto() {
  assert_rc "validate_module_json: rejeita caso 'entrypoint_absoluto'" 6 \
    -- registry::validate_module_json "$invalid_dir/entrypoint_absoluto.json"
}
test_40_validate_rejeita_entrypoint_path_traversal() {
  assert_rc "validate_module_json: rejeita caso 'entrypoint_path_traversal'" 6 \
    -- registry::validate_module_json "$invalid_dir/entrypoint_path_traversal.json"
}
test_41_validate_rejeita_json_quebrado() {
  assert_rc "validate_module_json: rejeita caso 'json_quebrado'" 6 \
    -- registry::validate_module_json "$invalid_dir/json_quebrado.json"
}

test_42_validate_rejeita_arquivo_inexistente() {
  assert_rc 'validate_module_json: rejeita arquivo inexistente' 6 \
    -- registry::validate_module_json "$invalid_dir/nao_existe.json"
}
assert_flush

# --- registry::module_field ---
test_43_module_field_name() {
  assert_eq 'module_field: lê o name do dummy real' dummy \
    "$(registry::module_field "$PVX_ROOT/modules/dummy/module.json" .name)"
}
test_44_module_field_version() {
  assert_eq 'module_field: lê a version do dummy real' 0.1.0 \
    "$(registry::module_field "$PVX_ROOT/modules/dummy/module.json" .version)"
}
assert_flush

# --- lock::acquire/release: não trava, mesmo sem `flock` disponível (ex: macOS) ---
export PVX_ROOT_PREFIX="$(pvx::tmpdir)/fixture_lock"
mkdir -p "$PVX_ROOT_PREFIX$(dirname "$(path::get pvx_lock)")"
test_45_lock_acquire_funciona() {
  assert_rc 'lock::acquire funciona (com ou sem flock disponível)' 0 -- lock::acquire 2
}
lock::release
test_46_lock_release_nao_quebra() { assert_pass 'lock::release não quebra'; }
unset PVX_ROOT_PREFIX
assert_flush

assert_summary
