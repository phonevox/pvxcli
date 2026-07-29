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
assert_pass 'init roda sem erro'
color::init
assert_pass 'init é idempotente (2a chamada não quebra)'

for m in auto always never; do
  color::set_mode "$m"
  assert_pass "set_mode $m roda sem erro"
done

color::set_mode never
assert_false 'stdout sem cor em modo never' color::enabled stdout
assert_false 'stderr sem cor em modo never' color::enabled stderr

color::set_mode always
assert_true 'stdout colorido em modo always' color::enabled stdout
assert_true 'stderr colorido em modo always' color::enabled stderr

assert_ne 'get de chave existente devolve algo' '' "$(color::get error)"
assert_eq 'get de chave inexistente usa fallback' 'FALLBACK' "$(color::get chave_inexistente FALLBACK)"
assert_eq 'get de chave inexistente sem fallback devolve vazio' '' "$(color::get chave_inexistente)"

assert_eq 'strip de string vazia' '' "$(color::strip '')"
assert_eq 'strip de texto sem cor não muda nada' 'texto puro' "$(color::strip 'texto puro')"

s="${PVX_C[error]}ERR${PVX_C[reset]}"
assert_eq 'strip remove sequências ANSI' 'ERR' "$(color::strip "$s")"

color::set_mode never
assert_summary
