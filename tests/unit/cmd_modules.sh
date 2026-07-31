#!/usr/bin/env bash
# tests/unit/cmd_modules.sh — testa a heurística de reconhecimento/expansão de alvo git em
# `pvx modules install` (lib/cmd_modules.sh): URL completa, atalho "org/repo" do GitHub, o
# prefixo de convenção "pvx-mod-" inserido automaticamente, e o cache do aviso de atualização
# disponível. Tudo aqui é lógica pura (string/arquivo local) — nada de rede real (isso é
# smoke/manual, não unit): modules::_git_remote_head_sha/_updates_scan não são testados aqui.
set -Eeuo pipefail

_TEST_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TEST_DIR/../.." && pwd)
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require color log cmd_modules
color::init
export PVX_LOG_DIR="$(pvx::tmpdir)/logtest"
log::init
export PVX_CACHE_DIR="$(pvx::tmpdir)/fixture_cmd_modules/cache"
mkdir -p "$PVX_CACHE_DIR"
# isola de /var/lib/pvx de verdade — modules::cmd_update lê registry::state_list, e sem isso
# este teste bateria no installed.db real de qualquer máquina que rodar a suíte.
export PVX_STATE_DIR="$(pvx::tmpdir)/fixture_cmd_modules/var/lib/pvx"
mkdir -p "$PVX_STATE_DIR"
# shellcheck source=/dev/null
source "$_TEST_DIR/../lib/assert.sh"

# --- modules::_is_git_url -----------------------------------------------------------------------
test_01_is_git_url_ssh_git() {
  assert_true 'reconhece git@host:org/repo.git' modules::_is_git_url 'git@github.com:org/repo.git'
}
test_02_is_git_url_ssh_sem_dotgit() {
  assert_true 'reconhece git@host:org/repo sem sufixo .git' modules::_is_git_url 'git@github.com:org/repo'
}
test_03_is_git_url_https_com_dotgit() {
  assert_true 'reconhece https://.../repo.git' modules::_is_git_url 'https://github.com/org/repo.git'
}
test_04_is_git_url_https_sem_dotgit() {
  assert_true 'reconhece https://.../repo sem sufixo .git (achado real: caía pro registry antes)' \
    modules::_is_git_url 'https://github.com/org/repo'
}
test_05_is_git_url_http_puro() {
  assert_true 'reconhece http:// (não só https)' modules::_is_git_url 'http://example.com/org/repo'
}
test_06_is_git_url_git_scheme() {
  assert_true 'reconhece git://' modules::_is_git_url 'git://example.com/org/repo.git'
}
test_07_is_git_url_nao_confunde_nome_simples() {
  assert_false 'nome de módulo simples (sem "/") não é URL' modules::_is_git_url 'dummy'
}
assert_flush

# --- modules::_git_shorthand_expand ---------------------------------------------------------
test_08_shorthand_expand_ja_com_prefixo() {
  assert_eq 'org/pvx-mod-nome não duplica o prefixo' \
    'https://github.com/phonevox/pvx-mod-netinstall.git' \
    "$(modules::_git_shorthand_expand 'phonevox/pvx-mod-netinstall')"
}
test_09_shorthand_expand_sem_prefixo() {
  assert_eq 'org/nome ganha o prefixo pvx-mod- automaticamente' \
    'https://github.com/phonevox/pvx-mod-netinstall.git' \
    "$(modules::_git_shorthand_expand 'phonevox/netinstall')"
}
test_10_shorthand_expand_base_configuravel() {
  PVX_MODULE_GIT_SHORTHAND_BASE='git@gitlab.example.com:%s.git'
  assert_eq 'module_git_shorthand_base troca o host/protocolo' \
    'git@gitlab.example.com:phonevox/pvx-mod-netinstall.git' \
    "$(modules::_git_shorthand_expand 'phonevox/netinstall')"
  unset PVX_MODULE_GIT_SHORTHAND_BASE
}
assert_flush

# --- modules::_resolve_git_target (o que o dispatch de install realmente chama) -------------
test_11_resolve_url_completa_passa_direto() {
  assert_eq 'URL completa não é reescrita' \
    'https://github.com/phonevox/pvx-mod-netinstall.git' \
    "$(modules::_resolve_git_target 'https://github.com/phonevox/pvx-mod-netinstall.git')"
}
test_12_resolve_shorthand_expande() {
  assert_eq 'atalho "org/repo" expande pra URL completa' \
    'https://github.com/phonevox/pvx-mod-netinstall.git' \
    "$(modules::_resolve_git_target 'phonevox/netinstall')"
}
test_13_resolve_nome_simples_nao_e_git() {
  local rc=0
  modules::_resolve_git_target 'dummy' >/dev/null 2>&1 || rc=$?
  assert_ne 'nome de módulo simples (sem "/") não vira alvo git — segue pro registry' 0 "$rc"
}
assert_flush

# --- cache do aviso de atualização disponível (modules::_updates_notify) -------------------
test_14_updates_cache_vazio_sem_arquivo() {
  modules::_updates_cache_read
  assert_eq 'updates_cache_read: pending vazio sem cache ainda' '' "$_MU_CACHE_PENDING"
}
test_15_updates_cache_write_depois_read() {
  modules::_updates_cache_write 'netinstall,outromodulo'
  modules::_updates_cache_read
  assert_eq 'updates_cache_write/read: pending bate' 'netinstall,outromodulo' "$_MU_CACHE_PENDING"
}
assert_flush

# regressão: depois de um `pvx modules update`, o cache de "atualização disponível" ficava
# preso em "outdated" por até 1 dia mesmo já atualizado — achado de verdade (usuário reportou
# list/update contradizendo um ao outro). cmd_update precisa invalidar o cache sempre, mesmo
# quando o alvo não existe (não precisa de um módulo de verdade instalado pra testar isso).
test_16_cmd_update_invalida_cache_sempre() {
  modules::_updates_cache_write 'algum-modulo-qualquer'
  modules::cmd_update 'modulo-que-nao-existe-de-jeito-nenhum' >/dev/null 2>&1 || true
  assert_false 'cmd_update apaga o arquivo de cache (mesmo alvo não existindo)' \
    bash -c '[[ -e "$1" ]]' -- "$(modules::_updates_cache_file)"
}
assert_flush

assert_summary
