#!/usr/bin/env bash
# tests/unit/completion.sh — testa completions/pvx.bash isoladamente + guarda de regressão de
# lib/core/completion.sh (texto de ativação do bash-completion).
set -Eeuo pipefail

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

# isola de módulos/snippets reais que possam estar instalados na máquina rodando o teste —
# module_cmds fica vazio, snippet_cmds continua vindo do checkout de verdade (sysinfo etc.),
# o que é esperado e não afeta as asserções abaixo (elas checam ausência de flag e presença de
# palavras-chave específicas, não uma lista exata).
PVX_STATE_DIR=$(pvx::tmpdir)/state-vazio
export PVX_STATE_DIR

# shellcheck source=/dev/null
source "$PVX_ROOT/completions/pvx.bash"

# completion::_run <word0> [word1 ...] — simula "pvx word1 word2 <TAB>" (cursor sempre na
# palavra vazia logo depois da última passada, igual o bash faz de verdade — COMP_WORDS
# SEMPRE tem um elemento no índice COMP_CWORD, mesmo vazio; por isso o "" explícito aqui, não
# só um array "um a menos" com o índice ausente) e chama _pvx_completions de verdade;
# resultado fica em COMPREPLY.
completion::_run() {
  COMP_WORDS=("$@" '')
  COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
  COMPREPLY=()
  _pvx_completions
}

# completion::_has_flag — verdadeiro se algum item de COMPREPLY começa com "-" (uma flag).
completion::_has_flag() {
  local w
  for w in ${COMPREPLY[@]+"${COMPREPLY[@]}"}; do
    [[ $w == -* ]] && return 0
  done
  return 1
}

# --- "pvx <TAB>" -----------------------------------------------------------------------------
completion::_run pvx
test_01_topo_sem_flags() {
  assert_false 'completion de topo não sugere nenhuma flag (só comandos)' completion::_has_flag
}
test_02_topo_tem_modules() {
  assert_contains 'completion de topo inclui "modules"' "${COMPREPLY[*]}" 'modules'
}
test_03_topo_tem_tests() {
  assert_contains 'completion de topo inclui "tests"' "${COMPREPLY[*]}" 'tests'
}
assert_flush

# --- "pvx modules <TAB>" ----------------------------------------------------------------------
completion::_run pvx modules
test_04_modules_sem_flags() {
  assert_false 'modules (sem subcomando) não sugere flags' completion::_has_flag
}
test_05_modules_tem_list() {
  assert_contains 'modules sugere "list"' "${COMPREPLY[*]}" 'list'
}
assert_flush

# --- "pvx modules install <TAB>" — sem --file antes, não sugere nada (nem flag) ---------------
completion::_run pvx modules install
test_06_modules_install_sem_flags() {
  assert_false 'modules install não sugere flags (--file/--force/etc. removidos de propósito)' \
    completion::_has_flag
}
assert_flush

# --- "pvx modules install --file <TAB>" — aqui sim completa CAMINHO de arquivo (funcional,
# não é sugestão de flag) ----------------------------------------------------------------------
completion::_run pvx modules install --file
test_07_modules_install_apos_file_nao_sugere_flag() {
  assert_false 'modules install depois de --file não sugere flag (só completa arquivo)' \
    completion::_has_flag
}
assert_flush

# --- "pvx modules update <TAB>" / "pvx modules remove <TAB>" — sem --all/--purge --------------
completion::_run pvx modules update
test_08_modules_update_sem_flags() {
  assert_false 'modules update não sugere flags (--all removido de propósito)' completion::_has_flag
}
assert_flush

completion::_run pvx modules remove
test_09_modules_remove_sem_flags() {
  assert_false 'modules remove não sugere flags (--purge removido de propósito)' completion::_has_flag
}
assert_flush

# --- "pvx registry <TAB>" — sem --force em refresh, só as chaves ------------------------------
# assert_flush logo depois de cada completion::_run, ANTES da próxima chamada: COMPREPLY é
# global, e o cursor "chamado" de completion::_run sobrescreve na hora — se a próxima chamada
# rodar antes do assert_flush processar os test_*() da anterior, eles leriam o COMPREPLY
# errado (achado de verdade escrevendo este teste).
completion::_run pvx registry
test_10_registry_sem_flags() {
  assert_false 'registry (sem subcomando) não sugere flags' completion::_has_flag
}
test_11_registry_tem_set() {
  assert_contains 'registry sugere "set"' "${COMPREPLY[*]}" 'set'
}
assert_flush

completion::_run pvx registry refresh
test_12_registry_refresh_sem_flags() {
  assert_false 'registry refresh não sugere --force (removido de propósito)' completion::_has_flag
}
assert_flush

# --- guarda de regressão: lib/core/completion.sh não deve voltar a sugerir "source ~/.bashrc"
# (não ativa nada — /etc/bashrc em RHEL-like tem a guarda BASHRCSOURCED de "só roda uma vez
# por sessão", então re-sourcear .bashrc numa sessão que já estava aberta ANTES do
# bash-completion ser instalado não recarrega /etc/profile.d/bash_completion.sh; achado de
# verdade testando no container). O comando que ativa de verdade na sessão atual é sourcear o
# arquivo do bash-completion direto. ------------------------------------------------------------
completion_src=$(cat "$PVX_ROOT/lib/core/completion.sh")
test_13_nao_sugere_source_bashrc() {
  assert_not_contains 'completion.sh não sugere mais "source ~/.bashrc" (não funciona, ver comentário)' \
    "$completion_src" 'source ~/.bashrc'
}
test_14_sugere_comando_certo_de_ativacao() {
  assert_contains 'completion.sh sugere sourcear o bash_completion direto' \
    "$completion_src" 'source /usr/share/bash-completion/bash_completion'
}
assert_flush

assert_summary
