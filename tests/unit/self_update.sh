#!/usr/bin/env bash
# tests/unit/self_update.sh — testa lib/core/self_update.sh: cache de notificação, parse do
# manifesto remoto (via file://) e o fluxo de apply (download+verify+extract+troca de symlink
# current) contra uma árvore fixture releases/current — nunca toca em /opt/pvx real.
#
# Cada test_*() roda isolada num subshell próprio (ver tests/lib/assert.sh) — por isso
# reatribuições de PVX_ROOT/PVX_VERSION/_SU_* DENTRO de uma test_*() nunca vazam pras
# seguintes, mesmo sem restaurar o valor original no fim do bloco.
set -Eeuo pipefail

_TEST_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TEST_DIR/../.." && pwd)
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require color log os paths exec json net integrity registry core/self_update
color::init
export PVX_LOG_DIR="$(pvx::tmpdir)/logtest"
log::init
# shellcheck source=/dev/null
source "$_TEST_DIR/../lib/assert.sh"

# isola o cache de notificação numa árvore fixture — nunca em /var/cache/pvx de verdade
export PVX_CACHE_DIR="$(pvx::tmpdir)/fixture_self_update/cache"
mkdir -p "$PVX_CACHE_DIR"

# --- cache de notificação: read/write -------------------------------------------------------
test_01_cache_read_vazio_sem_arquivo() {
  core::_self_update_cache_read
  assert_eq 'cache_read: latest vazio sem cache ainda' '' "$_SU_CACHE_LATEST"
}
test_02_cache_write_depois_read() {
  core::_self_update_cache_write 9.9.9
  core::_self_update_cache_read
  assert_eq 'cache_write/read: latest bate' 9.9.9 "$_SU_CACHE_LATEST"
}
assert_flush

# --- fixtures: manifesto (file://) + tarball de release -------------------------------------
_FIX_DIR="$(pvx::tmpdir)/fixture_self_update/src"
mkdir -p "$_FIX_DIR"

# monta um tarball de "release" fixture: <versão>/bin/pvx (executável) + <versão>/VERSION —
# nome do diretório de topo imita o padrão de archive do GitHub (pvxcli-<versão>/).
_build_release_tarball() { # <versão> <arquivo-de-saída.tar.gz>
  local ver=$1 out=$2 stage
  stage="$(pvx::tmpdir)/fixture_self_update/stage-$ver"
  rm -rf "$stage"
  mkdir -p "$stage/pvxcli-$ver/bin"
  printf '%s\n' "$ver" >"$stage/pvxcli-$ver/VERSION"
  printf '#!/usr/bin/env bash\nprintf "pvx %s\\n" "%s"\n' "$ver" "$ver" >"$stage/pvxcli-$ver/bin/pvx"
  chmod +x "$stage/pvxcli-$ver/bin/pvx"
  (cd "$stage" && tar -czf "$out" "pvxcli-$ver")
}

_build_release_tarball 0.2.0 "$_FIX_DIR/pvx-core-0.2.0.tar.gz"
_SHA_0_2_0=$(integrity::sha256_file "$_FIX_DIR/pvx-core-0.2.0.tar.gz")

cat >"$_FIX_DIR/self-update.json" <<EOF
{"version":"0.2.0","changelog":"corrige X, adiciona Y","tarball":{"url":"file://$_FIX_DIR/pvx-core-0.2.0.tar.gz","sha256":"$_SHA_0_2_0"}}
EOF

export PVX_SELF_UPDATE_URL="file://$_FIX_DIR/self-update.json"

test_10_fetch_manifest_ok() {
  local flat
  flat=$(core::_self_update_fetch_manifest)
  assert_eq 'fetch_manifest: version do manifesto remoto' 0.2.0 "$(json::get "$flat" .version)"
}
assert_flush

# --- check_and_report: gate por version::cmp ------------------------------------------------
test_20_check_report_versao_mais_nova_disponivel() {
  PVX_VERSION=0.1.0
  core::_self_update_check_and_report >/dev/null
  assert_eq 'check_and_report: acha 0.2.0 disponível (instalado 0.1.0)' 1 "$_SU_AVAILABLE"
}
test_21_check_report_ja_atualizado() {
  PVX_VERSION=0.2.0
  core::_self_update_check_and_report >/dev/null
  assert_eq 'check_and_report: nenhuma disponível (instalado == remoto)' 0 "$_SU_AVAILABLE"
}
test_22_check_report_versao_instalada_maior() {
  PVX_VERSION=9.0.0
  core::_self_update_check_and_report >/dev/null
  assert_eq 'check_and_report: nenhuma disponível (instalado é mais novo que o remoto)' 0 "$_SU_AVAILABLE"
}
assert_flush

# --- notify: respeita o TTL do cache (não bate na rede se ainda fresco) ---------------------
test_30_notify_usa_cache_fresco_sem_rede() {
  core::_self_update_cache_write 5.5.5
  PVX_SELF_UPDATE_TTL=999999 PVX_VERSION=0.1.0 \
    PVX_SELF_UPDATE_URL='file:///caminho/que/nao/existe/self-update.json' \
    core::_self_update_notify >/dev/null 2>&1
  core::_self_update_cache_read
  assert_eq 'notify: cache fresco não é sobrescrito (TTL não expirou, URL quebrada nem chega a ser tentada)' \
    5.5.5 "$_SU_CACHE_LATEST"
}
assert_flush

# --- apply: fluxo completo contra uma árvore fixture releases/current -----------------------
_FIX_PREFIX="$(pvx::tmpdir)/fixture_self_update/opt/pvx"
mkdir -p "$_FIX_PREFIX/releases/0.1.0/bin"
printf '0.1.0\n' >"$_FIX_PREFIX/releases/0.1.0/VERSION"
printf '#!/usr/bin/env bash\ntrue\n' >"$_FIX_PREFIX/releases/0.1.0/bin/pvx"
chmod +x "$_FIX_PREFIX/releases/0.1.0/bin/pvx"
ln -sfn "$_FIX_PREFIX/releases/0.1.0" "$_FIX_PREFIX/current"

test_40_apply_recusa_fora_do_layout_releases() {
  PVX_ROOT="$(pvx::tmpdir)/fixture_self_update/checkout_dev"
  mkdir -p "$PVX_ROOT"
  _SU_LATEST=0.2.0
  _SU_TARBALL_URL="file://$_FIX_DIR/pvx-core-0.2.0.tar.gz"
  _SU_TARBALL_SHA=$_SHA_0_2_0
  assert_rc 'apply: recusa instalação sem layout releases/current (checkout de dev)' \
    "$PVX_EXIT_UNSUPPORTED" -- core::_self_update_apply
}

# fluxo completo (download/verify/extract/publish/symlink) precisa de root de verdade — ver
# feedback do projeto: validação funcional roda só no container testrocky, nunca no Mac.
if ((EUID == 0)); then
  test_41_apply_publica_nova_release_e_troca_symlink() {
    PVX_ROOT="$_FIX_PREFIX/releases/0.1.0"
    PVX_VERSION=0.1.0
    _SU_LATEST=0.2.0
    _SU_TARBALL_URL="file://$_FIX_DIR/pvx-core-0.2.0.tar.gz"
    _SU_TARBALL_SHA=$_SHA_0_2_0
    core::_self_update_apply >/dev/null
    assert_eq 'apply: "current" agora aponta pra release 0.2.0' \
      "$_FIX_PREFIX/releases/0.2.0" "$(readlink "$_FIX_PREFIX/current")"
  }
  test_42_apply_checksum_errado_recusa() {
    PVX_ROOT="$_FIX_PREFIX/releases/0.1.0"
    PVX_VERSION=0.1.0
    _SU_LATEST=0.2.0
    _SU_TARBALL_URL="file://$_FIX_DIR/pvx-core-0.2.0.tar.gz"
    _SU_TARBALL_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef
    assert_rc 'apply: checksum não confere -> rc=5' 5 -- core::_self_update_apply
  }
else
  test_41_apply_pulado_sem_root() {
    assert_pass 'apply (fluxo completo download/publish/symlink): pulado fora de root — validar no container'
  }
fi
assert_flush

# --- prune_releases: mantém current + as N mais recentes ------------------------------------
_FIX_PRUNE="$(pvx::tmpdir)/fixture_self_update/prune/opt/pvx"
mkdir -p "$_FIX_PRUNE/releases"/{0.1.0,0.2.0,0.3.0,0.4.0}
ln -sfn "$_FIX_PRUNE/releases/0.4.0" "$_FIX_PRUNE/current"

test_50_prune_mantem_current_e_as_n_mais_recentes() {
  PVX_SELF_UPDATE_KEEP=1 core::_self_update_prune_releases "$_FIX_PRUNE"
  local remaining
  remaining=$(find "$_FIX_PRUNE/releases" -mindepth 1 -maxdepth 1 -type d | sort | tr '\n' ' ')
  assert_eq 'prune: mantém current (0.4.0) + 1 mais recente (0.3.0), remove o resto' \
    "$_FIX_PRUNE/releases/0.3.0 $_FIX_PRUNE/releases/0.4.0 " "$remaining"
}
assert_flush

assert_summary
