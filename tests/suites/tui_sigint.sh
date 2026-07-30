#!/usr/bin/env bash
# tests/suites/tui_sigint.sh — regressão: Ctrl-C (SIGINT) bloqueado no `read` raw de
# lib/tui.sh precisa cancelar de verdade (a função retorna, o terminal sai do estado
# travado), não ficar preso pra sempre. Bug real encontrado testando o menu interativo de
# verdade: o trap de INT/TERM chamava só a função que restaura a stty e dava `return` DE
# DENTRO DELA — isso só retorna da função-filha, não do loop que estava bloqueado no `read`;
# o `read` reinicia sozinho depois (restart de syscall do bash) e, com a stty já restaurada
# (echo ligado de novo) mas o loop ainda rodando, toda tecla seguinte (inclusive mais Ctrl-C)
# só aparece como texto puro na tela sem fazer nada — travado pra sempre.
#
# tui::pause tem a MESMA forma de fix que tui::_select_tty/tui::_checklist_tty (copiada do
# mesmo padrão) — cobrir as duas aqui já dá confiança alta sobre as três; tui::pause fica de
# fora só porque ela não separa um "_tty" chamável direto (todo o corpo já checa TTY logo no
# início), então testá-la exigiria um pty de verdade em vez do truque de fifo usado aqui.
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

# tui_sigint::_write_helper <arquivo> — escreve um script standalone que chama
# tui::_select_tty ou tui::_checklist_tty direto (bypassa o dispatch por TTY de
# tui::select/tui::checklist) e grava o resultado num arquivo assim que a chamada retornar.
tui_sigint::_write_helper() {
  local file=$1
  cat >"$file" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
fn=$1
result_file=$2
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::require color tui
color::init

rc=0
case $fn in
  select)
    tui::_select_tty 'sigint-test' item1 item2 || rc=$?
    printf 'rc=%d choice=%s\n' "$rc" "${TUI_CHOICE:-}" >"$result_file"
    ;;
  checklist)
    tui::_checklist_tty 'sigint-test' item1 item2 || rc=$?
    printf 'rc=%d result=%s\n' "$rc" "${TUI_RESULT[*]:-}" >"$result_file"
    ;;
esac
HELPER
  chmod +x "$file"
}

# tui_sigint::_run <select|checklist> <arquivo-de-resultado> — sobe o helper acima como
# subprocesso, com stdin preso numa fifo aberta em leitura+escrita por ELE MESMO (então o
# `open` não bloqueia — só o `read` bloqueia, igual a um terminal esperando a próxima tecla).
# Manda SIGINT depois de um instante; só devolve rc=0 se o subprocesso terminou sozinho
# DENTRO do prazo (ou seja, não travou pra sempre).
tui_sigint::_run() {
  local fn=$1 result_file=$2
  local dir helper_file fifo child waited

  dir=$(pvx::tmpdir)/tui-sigint.$$.$RANDOM
  mkdir -p "$dir"
  helper_file="$dir/helper.sh"
  fifo="$dir/stdin.fifo"
  tui_sigint::_write_helper "$helper_file"
  mkfifo "$fifo"
  : >"$result_file"

  (
    exec 9<>"$fifo" # leitura+escrita não bloqueia no open (ao contrário de só-leitura sem
                     # escritor); dá um stdin que só bloqueia no `read`, nunca chega a EOF.
    exec 0<&9
    PVX_ROOT=$PVX_ROOT PVX_LIB_DIR=$PVX_LIB_DIR exec "$BASH" "$helper_file" "$fn" "$result_file"
  ) &
  child=$!

  sleep 0.3 # tempo do helper carregar as libs e chegar no `read` bloqueado

  kill -INT "$child" 2>/dev/null || true

  waited=0
  while kill -0 "$child" 2>/dev/null; do
    sleep 0.2
    waited=$((waited + 1))
    if ((waited > 15)); then # ~3s — se ainda tá vivo aqui, o bug voltou (hang de verdade)
      kill -9 "$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
      rm -rf "$dir"
      return 1
    fi
  done
  wait "$child" 2>/dev/null || true
  rm -rf "$dir"
  return 0
}

result_select=$(pvx::tmpdir)/tui_sigint_result_select
test_01_select_sigint_nao_trava() {
  assert_true 'tui::_select_tty termina sozinho após SIGINT (não trava mais)' \
    tui_sigint::_run select "$result_select"
}
assert_flush

test_02_select_sigint_cancela() {
  local content
  content=$(cat "$result_select" 2>/dev/null || true)
  assert_contains 'SIGINT em tui::select é tratado como cancelar (rc=1)' "$content" 'rc=1'
}
assert_flush

result_checklist=$(pvx::tmpdir)/tui_sigint_result_checklist
test_03_checklist_sigint_nao_trava() {
  assert_true 'tui::_checklist_tty termina sozinho após SIGINT (não trava mais)' \
    tui_sigint::_run checklist "$result_checklist"
}
assert_flush

test_04_checklist_sigint_cancela() {
  local content
  content=$(cat "$result_checklist" 2>/dev/null || true)
  assert_contains 'SIGINT em tui::checklist é tratado como cancelar (rc=1)' "$content" 'rc=1'
}
assert_flush

assert_summary
