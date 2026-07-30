#!/usr/bin/env bash
# tests/unit/paths.sh — testa lib/paths.sh isoladamente.
set -Eeuo pipefail

_TEST_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TEST_DIR/../.." && pwd)
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require color log paths
color::init
export PVX_LOG_DIR="$(pvx::tmpdir)/logtest"
log::init
# shellcheck source=/dev/null
source "$_TEST_DIR/../lib/assert.sh"

test_01_get_chave_conhecida() { assert_eq 'get de chave conhecida devolve o caminho' /opt/pvx "$(path::get pvx_root)"; }
test_02_has_detecta_existente() { assert_true 'has detecta chave existente' path::has pvx_root; }
test_03_has_nao_detecta_inexistente() { assert_false 'has não detecta chave inexistente' path::has chave_bobagem; }
assert_flush

# chave própria do teste, não "pvx_root": /opt/pvx é o caminho real de instalação do pvx e
# PODE existir de verdade na máquina rodando este teste (ex: já rodou install.sh) — usar a
# chave real aqui faria o teste depender de um estado externo do filesystem que nem sempre é
# verdade, em vez de testar path::exists isoladamente.
path::set _chave_teste_caminho_ausente /pvx-teste-caminho-que-definitivamente-nao-existe
test_04_exists_falso_sem_filesystem() {
  assert_false 'exists é falso pra caminho que não existe no filesystem' path::exists _chave_teste_caminho_ausente
}
assert_flush

path::set minha_chave /tmp/pvx-teste-paths
test_05_set_adiciona_nova_chave() { assert_eq 'set adiciona uma nova chave' /tmp/pvx-teste-paths "$(path::get minha_chave)"; }
assert_flush

test_06_join_normaliza_barras() { assert_eq 'join normaliza barras duplicadas' /a/b/c "$(path::join /a/ /b/ /c)"; }
test_07_join_um_componente() { assert_eq 'join com um único componente' /a "$(path::join /a)"; }
assert_flush

require_rc=0
path::require chave_totalmente_inexistente_xyz 2>/dev/null || require_rc=$?
test_08_require_falha_precondition() {
  assert_eq 'require falha com PVX_EXIT_PRECONDITION pra chave ausente/inexistente' \
    "$PVX_EXIT_PRECONDITION" "$require_rc"
}
assert_flush

# PVX_ROOT_PREFIX prefixa get/exists — é o que torna a lib testável contra uma árvore fixture
fixture=$(pvx::tmpdir)/fixture
mkdir -p "$fixture/opt/pvx"
export PVX_ROOT_PREFIX=$fixture
test_09_root_prefix_exists_funciona() { assert_true 'com ROOT_PREFIX apontando pra fixture, exists funciona' path::exists pvx_root; }
test_10_root_prefix_get_aplica() { assert_eq 'get aplica o ROOT_PREFIX no caminho devolvido' "$fixture/opt/pvx" "$(path::get pvx_root)"; }
assert_flush
unset PVX_ROOT_PREFIX

# load_overrides — parseado (nunca sourced), só aceita chaves "path.*"
conf_file=$(pvx::tmpdir)/pvx.conf
cat >"$conf_file" <<'EOF'
# comentário deve ser ignorado
path.pvx_root = /caminho/customizado
log_level = debug
EOF
path::load_overrides "$conf_file"
test_11_load_overrides_aplica_chave() { assert_eq 'load_overrides aplica chave path.*' /caminho/customizado "$(path::get pvx_root)"; }
assert_flush

assert_summary
