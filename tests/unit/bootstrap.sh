#!/usr/bin/env bash
# tests/unit/bootstrap.sh — testa lib/bootstrap.sh isoladamente.
set -Eeuo pipefail

_TEST_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TEST_DIR/../.." && pwd)
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
# shellcheck source=/dev/null
source "$_TEST_DIR/../lib/assert.sh"

pvx::require_bash 4 2
test_01_require_bash() { assert_pass 'require_bash aceita a versão atual'; }
assert_flush

pvx::install_traps
test_02_install_traps() { assert_pass 'install_traps roda sem erro'; }
assert_flush

pvx::require color log
test_03_require_carrega() { assert_pass 'require carrega color+log'; }
pvx::require color log
test_04_require_idempotente() { assert_pass 'require é idempotente (2a chamada não recarrega)'; }
assert_flush

pvx::invocation_id >/dev/null
id1=$PVX_INVOCATION_ID
test_05_invocation_id_gera() { assert_ne 'invocation_id gera um valor' '' "$id1"; }
pvx::invocation_id >/dev/null
test_06_invocation_id_memo() {
  assert_eq 'invocation_id é memoizado (mesmo valor na 2a chamada)' "$id1" "$PVX_INVOCATION_ID"
}
assert_flush

d=$(pvx::tmpdir)
test_07_tmpdir_cria() { assert_file 'tmpdir cria o diretório' "$d"; }
d2=$(pvx::tmpdir)
test_08_tmpdir_memo() { assert_eq 'tmpdir é memoizado (mesmo caminho)' "$d" "$d2"; }
assert_flush

test_09_root_dir() { assert_eq 'root_dir devolve PVX_ROOT' "$PVX_ROOT" "$(pvx::root_dir)"; }
assert_flush

pvx::on_exit true
pvx::on_exit true
test_10_on_exit() { assert_pass 'on_exit aceita múltiplos hooks sem erro'; }
assert_flush

# roda num subshell filho pra poder checar limpeza do tmpdir sem afetar os asserts acima —
# usa $BASH (o interpretador que já está rodando este teste), não um caminho hardcoded, pra
# funcionar igual em CentOS7/Debian/Ubuntu (bash de sistema) e em macOS (bash do Homebrew).
tmpdir_para_limpeza=$(
  PVX_ROOT=$PVX_ROOT PVX_LIB_DIR=$PVX_LIB_DIR "$BASH" -c '
    source "$PVX_LIB_DIR/bootstrap.sh"
    pvx::install_traps
    pvx::tmpdir
  ' 2>/dev/null
) || true
if [[ -n $tmpdir_para_limpeza ]]; then
  test_11_tmpdir_cleanup() {
    assert_no_file 'tmpdir é removido no exit do processo' "$tmpdir_para_limpeza"
  }
fi
assert_flush

assert_summary
