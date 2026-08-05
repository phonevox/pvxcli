#!/usr/bin/env bash
# tests/suites/exec_spinner_label.sh — regressão: exec::spinner_update troca o texto de um
# spinner JÁ ATIVO sem reiniciar o subprocesso (nem o cronômetro) — ao contrário de parar e
# chamar exec::spinner_start de novo. Precisa de um pty de verdade (mesma técnica de
# exec_confirm_prompt.sh via `script`, util-linux): exec::spinner_active exige `[[ -t 2 ]]`, que
# um fifo/pipe comum nunca satisfaz.
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
    assert_pass 'exec::spinner_update sob pty: pulado — comando "script" indisponível neste host'
  }
  assert_flush
  assert_summary
fi

# script (util-linux) exige "bash <arquivo>", não o arquivo direto — mesmo achado de sempre
# (pvx::tmpdir() pode estar montado noexec).
_HELPER=$(pvx::tmpdir)/spinner_label_helper.sh
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

exec::spinner_start 'processando arquivo-a.txt'
sleep 0.3
printf 'PID_AFTER_START=%s\n' "\$_PVX_SPINNER_PID"
exec::spinner_update 'processando arquivo-b.txt'
sleep 0.3
printf 'PID_AFTER_UPDATE=%s\n' "\$_PVX_SPINNER_PID"
exec::spinner_stop
HELPER

_OUT=$(pvx::tmpdir)/spinner_label_out.log
printf '' | script -qc "bash $_HELPER" "$_OUT" >/dev/null 2>&1 || true
out=$(cat "$_OUT" 2>/dev/null) || out=''

test_01_label_inicial_aparece() {
  assert_contains 'exec::spinner_start: o rótulo inicial aparece de verdade na pty' \
    "$out" 'processando arquivo-a.txt'
}
test_02_label_atualizado_aparece() {
  assert_contains 'exec::spinner_update: o rótulo novo aparece de verdade na pty, sem parar o spinner' \
    "$out" 'processando arquivo-b.txt'
}
assert_flush

pid_start=$(printf '%s\n' "$out" | grep -oE 'PID_AFTER_START=[0-9]+' | head -1 | cut -d= -f2) || pid_start=''
pid_update=$(printf '%s\n' "$out" | grep -oE 'PID_AFTER_UPDATE=[0-9]+' | head -1 | cut -d= -f2) || pid_update=''

test_03_pid_capturado_apos_start() {
  assert_true 'exec::spinner_start: PID do subprocesso foi capturado' \
    test -n "$pid_start"
}
test_04_pid_nao_muda_apos_update() {
  # a prova de que spinner_update NÃO reinicia o spinner: é o MESMO subprocesso rodando antes e
  # depois do update, não um novo fork (que aconteceria se update fosse "stop + start de novo").
  assert_eq 'exec::spinner_update: o PID do subprocesso continua o mesmo (não reiniciou)' \
    "$pid_start" "$pid_update"
}
assert_flush

assert_summary
