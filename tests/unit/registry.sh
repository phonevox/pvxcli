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
assert_eq 'cmp: versões iguais' 0 "$(version::cmp 1.2.3 1.2.3)"
assert_eq 'cmp: major maior' 1 "$(version::cmp 2.0.0 1.9.9)"
assert_eq 'cmp: minor maior' 1 "$(version::cmp 1.2.0 1.1.9)"
assert_eq 'cmp: patch maior' 1 "$(version::cmp 1.2.3 1.2.2)"
assert_eq 'cmp: menor (major)' 2 "$(version::cmp 1.0.0 2.0.0)"
assert_eq 'cmp: número de segmentos diferente (1.2 vs 1.2.0)' 0 "$(version::cmp 1.2 1.2.0)"
assert_eq 'cmp: pré-release é menor que release' 2 "$(version::cmp 1.0.0-beta 1.0.0)"
assert_eq 'cmp: release é maior que pré-release' 1 "$(version::cmp 1.0.0 1.0.0-beta)"
assert_eq 'cmp: duas versões 0.1.0 e 0.1.1 (caso real do dummy)' 2 "$(version::cmp 0.1.0 0.1.1)"

# --- version::satisfies ------------------------------------------------------------------------
assert_true 'satisfies: * aceita qualquer versão' version::satisfies 0.0.1 '*'
assert_true 'satisfies: >= verdadeiro (igual)' version::satisfies 1.0.0 '>=1.0.0'
assert_true 'satisfies: >= verdadeiro (maior)' version::satisfies 1.0.1 '>=1.0.0'
assert_false 'satisfies: >= falso' version::satisfies 0.9.0 '>=1.0.0'
assert_true 'satisfies: > verdadeiro' version::satisfies 1.0.1 '>1.0.0'
assert_false 'satisfies: > falso (igual não conta)' version::satisfies 1.0.0 '>1.0.0'
assert_true 'satisfies: = verdadeiro' version::satisfies 1.0.0 '=1.0.0'
assert_false 'satisfies: = falso' version::satisfies 1.0.1 '=1.0.0'
assert_true 'satisfies: <= verdadeiro' version::satisfies 1.0.0 '<=1.0.0'
assert_true 'satisfies: < verdadeiro' version::satisfies 0.9.0 '<1.0.0'

# --- estado local (installed.db) — isolado numa árvore fixture --------------------------------
# registry.sh usa PVX_STATE_DIR diretamente (mesma variável que bin/pvx exporta e usa pro
# despacho via symlinks), não path::get — ver comentário no topo de lib/registry.sh.
export PVX_STATE_DIR="$(pvx::tmpdir)/fixture_registry/var/lib/pvx"
mkdir -p "$PVX_STATE_DIR"

assert_false 'state_is_installed: falso quando installed.db nem existe ainda' \
  registry::state_is_installed dummy

registry::state_add_record dummy 0.1.0 dummy file /tmp/pvx-mod-dummy-0.1.0.tar.gz \
  abc123 manifest 0.1.0 5
assert_true 'state_is_installed: verdadeiro após add_record' registry::state_is_installed dummy
assert_eq 'state_get: version' 0.1.0 "$(registry::state_get dummy version)"
assert_eq 'state_get: command' dummy "$(registry::state_get dummy command)"
assert_eq 'state_get: origin' file "$(registry::state_get dummy origin)"
assert_eq 'state_get: verified' manifest "$(registry::state_get dummy verified)"
assert_eq 'state_get: files_count' 5 "$(registry::state_get dummy files_count)"

registry::state_add_record outro 2.0.0 outro registry file://x.tar.gz def456 index 0.1.0 3
assert_eq 'state_list: 2 registros após add de um segundo módulo' 2 \
  "$(registry::state_list | wc -l | tr -d ' ')"

# re-adicionar "dummy" com versão nova substitui o registro (não duplica)
registry::state_add_record dummy 0.1.1 dummy registry file://y.tar.gz ghi789 index 0.1.0 5
assert_eq 'state_add_record: substitui em vez de duplicar' 0.1.1 "$(registry::state_get dummy version)"
assert_eq 'state_list: ainda 2 registros após update (não duplicou)' 2 \
  "$(registry::state_list | wc -l | tr -d ' ')"

registry::state_del_record dummy
assert_false 'state_is_installed: falso após del_record' registry::state_is_installed dummy
assert_true 'state_is_installed: "outro" continua instalado' registry::state_is_installed outro
assert_eq 'state_list: 1 registro após remover "dummy"' 1 \
  "$(registry::state_list | wc -l | tr -d ' ')"

unset PVX_STATE_DIR

# --- validação de module.json -------------------------------------------------------------
assert_rc 'validate_module_json: aceita o module.json real do dummy' 0 \
  -- registry::validate_module_json "$PVX_ROOT/modules/dummy/module.json"

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

for caso in schema_errada nome_invalido comando_reservado versao_invalida sem_entrypoint \
  entrypoint_absoluto entrypoint_path_traversal json_quebrado; do
  assert_rc "validate_module_json: rejeita caso '$caso'" 6 \
    -- registry::validate_module_json "$invalid_dir/$caso.json"
done

assert_rc 'validate_module_json: rejeita arquivo inexistente' 6 \
  -- registry::validate_module_json "$invalid_dir/nao_existe.json"

# --- registry::module_field ---
assert_eq 'module_field: lê o name do dummy real' dummy \
  "$(registry::module_field "$PVX_ROOT/modules/dummy/module.json" .name)"
assert_eq 'module_field: lê a version do dummy real' 0.1.0 \
  "$(registry::module_field "$PVX_ROOT/modules/dummy/module.json" .version)"

# --- lock::acquire/release: não trava, mesmo sem `flock` disponível (ex: macOS) ---
export PVX_ROOT_PREFIX="$(pvx::tmpdir)/fixture_lock"
mkdir -p "$PVX_ROOT_PREFIX$(dirname "$(path::get pvx_lock)")"
assert_rc 'lock::acquire funciona (com ou sem flock disponível)' 0 -- lock::acquire 2
lock::release
assert_pass 'lock::release não quebra'
unset PVX_ROOT_PREFIX

assert_summary
