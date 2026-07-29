#!/usr/bin/env bash
# tests/unit/color.sh — testa lib/color.sh isoladamente.
set -Eeuo pipefail

_TEST_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TEST_DIR/../.." && pwd)
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::require color
# shellcheck source=/dev/null
source "$_TEST_DIR/../lib/assert.sh"

color::init
test_01_init() { assert_pass 'init roda sem erro'; }
color::init
test_02_init_idempotente() { assert_pass 'init é idempotente (2a chamada não quebra)'; }
assert_flush

color::set_mode auto
test_03_set_mode_auto() { assert_pass 'set_mode auto roda sem erro'; }
color::set_mode always
test_04_set_mode_always() { assert_pass 'set_mode always roda sem erro'; }
color::set_mode never
test_05_set_mode_never() { assert_pass 'set_mode never roda sem erro'; }
assert_flush

color::set_mode never
test_06_stdout_sem_cor_never() { assert_false 'stdout sem cor em modo never' color::enabled stdout; }
test_07_stderr_sem_cor_never() { assert_false 'stderr sem cor em modo never' color::enabled stderr; }
assert_flush

color::set_mode always
test_08_stdout_colorido_always() { assert_true 'stdout colorido em modo always' color::enabled stdout; }
test_09_stderr_colorido_always() { assert_true 'stderr colorido em modo always' color::enabled stderr; }
assert_flush

test_10_get_existente() { assert_ne 'get de chave existente devolve algo' '' "$(color::get error)"; }
test_11_get_inexistente_fallback() {
  assert_eq 'get de chave inexistente usa fallback' 'FALLBACK' "$(color::get chave_inexistente FALLBACK)"
}
test_12_get_inexistente_sem_fallback() {
  assert_eq 'get de chave inexistente sem fallback devolve vazio' '' "$(color::get chave_inexistente)"
}
assert_flush

test_13_strip_vazio() { assert_eq 'strip de string vazia' '' "$(color::strip '')"; }
test_14_strip_sem_cor() {
  assert_eq 'strip de texto sem cor não muda nada' 'texto puro' "$(color::strip 'texto puro')"
}
assert_flush

s="${PVX_C[error]}ERR${PVX_C[reset]}"
test_15_strip_remove_ansi() { assert_eq 'strip remove sequências ANSI' 'ERR' "$(color::strip "$s")"; }
assert_flush

color::set_mode never
assert_summary
