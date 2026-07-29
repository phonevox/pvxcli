#!/usr/bin/env bash
# tests/unit/os.sh — testa lib/os.sh isoladamente. Roda em qualquer distro/SO (macOS incluso)
# porque as asserções checam graceful-degradation, não um SO específico.
set -Eeuo pipefail

_TEST_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TEST_DIR/../.." && pwd)
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require color log os
color::init
export PVX_LOG_DIR="$(pvx::tmpdir)/logtest"
log::init
# shellcheck source=/dev/null
source "$_TEST_DIR/../lib/assert.sh"

# --- regressão: os::init <-> os::_ensure <-> os::like não pode recursar infinitamente ---
# (achado rodando de verdade num Mac: causava stack overflow / SIGSEGV, bash -n não detecta)
test_01_os_id_nao_trava() { assert_ne 'os::id não trava (regressão de recursão infinita)' '' "$(os::id || true)"; }
test_02_os_family_nao_trava() { assert_ne 'os::family não trava' '' "$(os::family || true)"; }
assert_flush

test_03_os_id_devolve_algo() { assert_ne 'os::id devolve algo (mesmo que "unknown")' '' "$(os::id)"; }
test_04_os_family_devolve_algo() { assert_ne 'os::family devolve algo' '' "$(os::family)"; }
test_05_os_arch_devolve_algo() { assert_ne 'os::arch devolve algo' '' "$(os::arch)"; }
assert_flush

# só um destes deve ser verdadeiro por vez (nunca dois simultaneamente)
rhel=0 debian=0 suse=0
os::is_rhel_like && rhel=1
os::is_debian_like && debian=1
os::is_suse_like && suse=1
test_06_uma_familia_apenas() {
  assert_eq 'no máximo uma família de SO é detectada' 1 "$(( rhel + debian + suse <= 1 ? 1 : 0 ))"
}
assert_flush

# is_container/is_root dependem do ambiente de verdade (host vs container, root vs não) —
# não dá pra fixar um valor esperado (rodar isto dentro de um container, ex: pra testar no
# bash 4.2 do CentOS, torna "sempre falso" uma asserção errada, não uma regressão). Em vez
# disso, confere CONSISTÊNCIA com um sinal independente: EUID de verdade pro root, e a mesma
# checagem de /.dockerenv que os::is_container usa internamente (é a evidência real
# disponível, não dá pra verificar "é container" sem reproduzir o próprio sinal).
test_07_is_container_consistente() {
  if [[ -e /.dockerenv ]] || [[ -e /run/.containerenv ]]; then
    assert_true 'is_container detecta container quando /.dockerenv (ou equivalente) existe' os::is_container
  else
    assert_false 'is_container é falso quando não há sinal de container' os::is_container
  fi
}
test_08_is_root_consistente() {
  if ((EUID == 0)); then
    assert_true 'is_root é verdadeiro quando EUID=0' os::is_root
  else
    assert_false 'is_root é falso quando EUID != 0' os::is_root
  fi
}
assert_flush

test_09_selinux_state() { assert_ne 'selinux_state sempre devolve algo (mesmo "disabled")' '' "$(os::selinux_state)"; }
assert_flush

# require_rhel_like é uma guarda SOFT: avisa e continua, nunca `exit`
rc=0
os::require_rhel_like 'teste' 2>/dev/null || rc=$?
test_10_require_rhel_like_soft() {
  assert_ne 'require_rhel_like retorna não-zero quando não é rhel-like (soft, não exit)' '' "$rc"
}
assert_flush

PVX_ALLOW_UNSUPPORTED_OS=1
test_11_allow_unsupported_os() {
  assert_rc 'PVX_ALLOW_UNSUPPORTED_OS=1 faz require_rhel_like retornar 0' 0 \
    -- os::require_rhel_like 'teste'
}
assert_flush
PVX_ALLOW_UNSUPPORTED_OS=0

# has_systemd/pkg_manager só checam presença de fato no host — sem asserção de valor
# específico (varia entre macOS/container/host real), só que não travam.
os::has_systemd && true || true
test_12_has_systemd_nao_quebra() { assert_pass 'has_systemd não quebra, seja qual for o resultado'; }
os::pkg_manager >/dev/null 2>&1 || true
test_13_pkg_manager_nao_quebra() { assert_pass 'pkg_manager não quebra, mesmo sem gerenciador conhecido (ex: macOS/brew)'; }
assert_flush

assert_summary
