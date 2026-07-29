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

assert_eq 'get de chave conhecida devolve o caminho' /opt/pvx "$(path::get pvx_root)"
assert_true 'has detecta chave existente' path::has pvx_root
assert_false 'has não detecta chave inexistente' path::has chave_bobagem

assert_false 'exists é falso pra caminho que não existe no filesystem' path::exists pvx_root

path::set minha_chave /tmp/pvx-teste-paths
assert_eq 'set adiciona uma nova chave' /tmp/pvx-teste-paths "$(path::get minha_chave)"

assert_eq 'join normaliza barras duplicadas' /a/b/c "$(path::join /a/ /b/ /c)"
assert_eq 'join com um único componente' /a "$(path::join /a)"

rc=0
path::require chave_totalmente_inexistente_xyz 2>/dev/null || rc=$?
assert_eq 'require falha com PVX_EXIT_PRECONDITION pra chave ausente/inexistente' \
  "$PVX_EXIT_PRECONDITION" "$rc"

# PVX_ROOT_PREFIX prefixa get/exists — é o que torna a lib testável contra uma árvore fixture
fixture=$(pvx::tmpdir)/fixture
mkdir -p "$fixture/opt/pvx"
export PVX_ROOT_PREFIX=$fixture
assert_true 'com ROOT_PREFIX apontando pra fixture, exists funciona' path::exists pvx_root
assert_eq 'get aplica o ROOT_PREFIX no caminho devolvido' "$fixture/opt/pvx" "$(path::get pvx_root)"
unset PVX_ROOT_PREFIX

# load_overrides — parseado (nunca sourced), só aceita chaves "path.*"
conf_file=$(pvx::tmpdir)/pvx.conf
cat >"$conf_file" <<'EOF'
# comentário deve ser ignorado
path.pvx_root = /caminho/customizado
log_level = debug
EOF
path::load_overrides "$conf_file"
assert_eq 'load_overrides aplica chave path.*' /caminho/customizado "$(path::get pvx_root)"

assert_summary
