#!/usr/bin/env bash
# tests/suites/exec_confirm_prompt.sh — regressão: exec::confirm precisa MOSTRAR o prompt de
# verdade, não só decidir certo. Bug real (achado testando `pvx modules remove`): a linha era
# `read -rp "$prompt " ans 2>/dev/null </dev/tty` — bash escreve o prompt de "read -p" em
# STDERR, não stdout (ver `man bash`), e aquele "2>/dev/null" (pensado só como blindagem pro
# caso de /dev/tty falhar) apagava o prompt JUNTO. A confirmação ficava invisível: o usuário
# via a tela de antes, apertava enter (respondendo "" a uma pergunta que nunca viu) e caía no
# default 'n' — parecia "cancelar sozinho".
#
# Precisa de um pty de verdade pra testar isso (um fifo, como tui_sigint.sh usa, não basta:
# `[[ -t 0 ]]` é falso pra fifo, então exec::confirm nem chegaria na linha do bug) — usa
# `script` (util-linux), que já provou dar conta disso quando reproduzindo o bug de verdade.
set -Eeuo pipefail

for _pvx_brew_bin in /opt/homebrew/bin /usr/local/bin; do
  if [[ -x "$_pvx_brew_bin/bash" ]] && [[ ":$PATH:" != *":$_pvx_brew_bin:"* ]]; then
    export PATH="$_pvx_brew_bin:$PATH"
  fi
done
unset _pvx_brew_bin

if ((BASH_VERSINFO[0] < 4)); then
  if command -v bash >/dev/null 2>&1; then
    exec "$(command -v bash)" "$0" "$@"
  fi
  printf 'bash >= 4.2 é necessário (achado: %s); instale via "brew install bash"\n' \
    "${BASH_VERSION:-desconhecido}" >&2
  exit 1
fi

_TEST_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TEST_DIR/../.." && pwd)
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require color
color::init
# shellcheck source=/dev/null
source "$_TEST_DIR/../lib/assert.sh"

if ! command -v script >/dev/null 2>&1; then
  test_01_pulado_sem_script() {
    assert_pass 'exec::confirm sob pty: pulado — comando "script" indisponível neste host'
  }
  assert_flush
  assert_summary
fi

# script (util-linux) exige "bash <arquivo>", não o arquivo direto: ele vive debaixo de
# pvx::tmpdir() (normalmente /tmp), que pode estar montado noexec (mesmo achado documentado em
# modules::_publish_staging e em core::_self_update_apply).
_HELPER=$(pvx::tmpdir)/confirm_helper.sh
cat >"$_HELPER" <<HELPER
#!/usr/bin/env bash
set -Eeuo pipefail
export PVX_ROOT="$PVX_ROOT" PVX_LIB_DIR="$PVX_LIB_DIR"
source "\$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require color log os paths exec
color::init
export PVX_LOG_DIR=\$(pvx::tmpdir)/logtest
log::init
if exec::confirm 'confirma ISTO_AQUI? [y/N]' n; then
  printf 'RC=0\n'
else
  printf 'RC=1\n'
fi
HELPER

# exec_confirm_prompt::_run <entrada-de-stdin> <arquivo-de-saída> — roda o helper dentro de um
# pty de verdade (script), alimentando <entrada-de-stdin> como se fosse digitado.
exec_confirm_prompt::_run() {
  local input=$1 out=$2
  printf '%s' "$input" | script -qc "bash $_HELPER" "$out" >/dev/null 2>&1 || true
}

_TS_BLANK=$(pvx::tmpdir)/ts_blank.log
exec_confirm_prompt::_run $'\n' "$_TS_BLANK"

test_01_prompt_aparece_na_pty() {
  assert_contains 'exec::confirm: o prompt aparece de verdade na pty (não fica preso em stderr descartado)' \
    "$(cat "$_TS_BLANK" 2>/dev/null)" 'confirma ISTO_AQUI? [y/N]'
}
test_02_enter_em_branco_usa_o_default() {
  assert_contains 'exec::confirm: enter em branco usa o default (n) -> RC=1' \
    "$(cat "$_TS_BLANK" 2>/dev/null)" 'RC=1'
}
assert_flush

_TS_YES=$(pvx::tmpdir)/ts_yes.log
exec_confirm_prompt::_run $'y\n' "$_TS_YES"
test_03_responder_y_confirma() {
  assert_contains 'exec::confirm: responder "y" confirma -> RC=0' \
    "$(cat "$_TS_YES" 2>/dev/null)" 'RC=0'
}
assert_flush

assert_summary
