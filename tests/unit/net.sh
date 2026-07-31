#!/usr/bin/env bash
# tests/unit/net.sh — testa lib/net.sh: net::fetch precisa reportar o motivo real da falha
# (rc do curl), não um "falha ao baixar" mudo. Usa falhas locais determinísticas (DNS
# inválido, porta fechada em localhost) — não depende da internet estar instável pra passar.
set -Eeuo pipefail

_TEST_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TEST_DIR/../.." && pwd)
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require color log net
color::init
export PVX_LOG_DIR="$(pvx::tmpdir)/logtest"
log::init
# shellcheck source=/dev/null
source "$_TEST_DIR/../lib/assert.sh"

dest="$(pvx::tmpdir)/net-fetch-test.out"

test_01_fetch_dns_invalido_reporta_motivo() {
  local out rc=0
  out=$(net::fetch 'https://host-que-nao-existe-de-jeito-nenhum.invalid/x' "$dest" teste 5 2>&1) || rc=$?
  assert_ne 'net::fetch com DNS inválido retorna rc != 0' 0 "$rc"
  assert_true 'mensagem de erro cita "DNS" (não um "falha ao baixar" mudo)' \
    bash -c "[[ \"\$1\" == *DNS* ]]" -- "$out"
}

test_02_fetch_conexao_recusada_reporta_motivo() {
  local out rc=0
  # porta baixa (<1024) e tipicamente fechada em qualquer host — conexão recusada, não timeout
  out=$(net::fetch 'http://127.0.0.1:9/x' "$dest" teste 5 2>&1) || rc=$?
  assert_ne 'net::fetch com conexão recusada retorna rc != 0' 0 "$rc"
  assert_true 'mensagem de erro cita "recusada" (não um "falha ao baixar" mudo)' \
    bash -c "[[ \"\$1\" == *recusada* ]]" -- "$out"
}

test_03_fetch_offline_nao_tenta_rede() {
  local rc=0
  PVX_OFFLINE=1
  net::fetch 'https://example.com/x' "$dest" teste 5 >/dev/null 2>&1 || rc=$?
  PVX_OFFLINE=0
  assert_eq 'PVX_OFFLINE=1 falha sem tentar rede (mesmo pra host válido)' 4 "$rc"
}
assert_flush

assert_summary
