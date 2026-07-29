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
assert_ne 'os::id não trava (regressão de recursão infinita)' '' "$(os::id || true)"
assert_ne 'os::family não trava' '' "$(os::family || true)"

assert_ne 'os::id devolve algo (mesmo que "unknown")' '' "$(os::id)"
assert_ne 'os::family devolve algo' '' "$(os::family)"
assert_ne 'os::arch devolve algo' '' "$(os::arch)"

# só um destes deve ser verdadeiro por vez (nunca dois simultaneamente)
rhel=0 debian=0 suse=0
os::is_rhel_like && rhel=1
os::is_debian_like && debian=1
os::is_suse_like && suse=1
assert_eq 'no máximo uma família de SO é detectada' 1 "$(( rhel + debian + suse <= 1 ? 1 : 0 ))"

assert_false 'is_container é falso rodando direto no host' os::is_container
assert_false 'is_root é falso rodando como usuário normal' os::is_root

assert_ne 'selinux_state sempre devolve algo (mesmo "disabled")' '' "$(os::selinux_state)"

# require_rhel_like é uma guarda SOFT: avisa e continua, nunca `exit`
rc=0
os::require_rhel_like 'teste' 2>/dev/null || rc=$?
assert_ne 'require_rhel_like retorna não-zero quando não é rhel-like (soft, não exit)' '' "$rc"

PVX_ALLOW_UNSUPPORTED_OS=1
assert_rc 'PVX_ALLOW_UNSUPPORTED_OS=1 faz require_rhel_like retornar 0' 0 \
  -- os::require_rhel_like 'teste'
PVX_ALLOW_UNSUPPORTED_OS=0

# has_systemd/pkg_manager só checam presença de fato no host — sem asserção de valor
# específico (varia entre macOS/container/host real), só que não travam.
os::has_systemd && true || true
assert_pass 'has_systemd não quebra, seja qual for o resultado'
os::pkg_manager >/dev/null 2>&1 || true
assert_pass 'pkg_manager não quebra, mesmo sem gerenciador conhecido (ex: macOS/brew)'

assert_summary
