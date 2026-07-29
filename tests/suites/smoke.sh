#!/usr/bin/env bash
# tests/suites/smoke.sh — teste de ponta a ponta do subsistema `pvx modules`, através do
# dispatcher REAL (bin/pvx), não chamando as funções de lib diretamente. Roda isolado num
# PVX_ROOT_PREFIX temporário — nunca toca em /var/lib/pvx ou /opt/pvx de verdade.
#
# No macOS: o entrypoint do módulo (`#!/usr/bin/env bash`) é executado como processo filho
# de verdade (não uma função) e resolve o "bash" do PATH do sistema — que no macOS é o 3.2
# antigo, insuficiente. Rode com o Homebrew bash primeiro no PATH, ex:
#   PATH="/opt/homebrew/bin:$PATH" bash tests/suites/smoke.sh
# No alvo real (CentOS/Debian/Ubuntu) isso não é um problema — o "bash" padrão já é >=4.2.
set -Eeuo pipefail

_TEST_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TEST_DIR/../.." && pwd)
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require color log
color::init
export PVX_LOG_DIR="$(pvx::tmpdir)/logtest"
log::init
# shellcheck source=/dev/null
source "$_TEST_DIR/../lib/assert.sh"

# --- sandbox isolado: todo o estado do pvx (installed.db, symlinks, módulos) vive aqui ---
export PVX_ROOT_PREFIX="$(pvx::tmpdir)/sandbox"
mkdir -p "$PVX_ROOT_PREFIX"

pvx() {
  # invoca o dispatcher real como um processo novo (não uma função) — é isso que exercita
  # de fato o `#!/usr/bin/env bash` do entrypoint do módulo, o symlink de despacho, etc.
  "$BASH" "$PVX_ROOT/bin/pvx" "$@"
}

# --- empacota o dummy fresquinho (dist/ é build output, não confiar em artefato antigo) ---
# pack-module.sh sempre escreve em $PVX_ROOT/dist — copia o resultado pra um dist_dir isolado
# do teste depois (dist/ real fica intocado além disso, é só build output regenerável).
dist_dir="$(pvx::tmpdir)/dist"
mkdir -p "$dist_dir"
pack_log="$(pvx::tmpdir)/pack.log"
if ! (cd "$PVX_ROOT" && "$BASH" tools/pack-module.sh modules/dummy) >"$pack_log" 2>&1; then
  assert_fail "tools/pack-module.sh falhou ao empacotar modules/dummy: $(cat "$pack_log")"
  assert_summary
fi
cp "$PVX_ROOT"/dist/pvx-mod-dummy-*.tar.gz "$dist_dir"/
tarball=$(find "$dist_dir" -maxdepth 1 -name 'pvx-mod-dummy-*.tar.gz' | head -1)
assert_file 'pack-module.sh gerou o tarball do dummy' "$tarball"

# --- 1. list vazio ---
out=$(pvx modules list)
assert_contains '1. modules list (vazio) avisa que não há módulos' "$out" 'nenhum módulo instalado'

# --- 2. install --file rejeita sha256 errado ---
rc=0
pvx modules install --file "$tarball" --sha256 '0000000000000000000000000000000000000000000000000000000000000000' \
  >/dev/null 2>&1 || rc=$?
assert_eq '2. install --file com sha256 errado retorna rc=5' 5 "$rc"

# --- 3. install --file rejeita arquivo inexistente ---
rc=0
pvx modules install --file "$(pvx::tmpdir)/nao-existe-$$.tar.gz" >/dev/null 2>&1 || rc=$?
assert_eq '3. install --file de arquivo inexistente retorna rc=1' 1 "$rc"

# --- 4. install --file rejeita tarball com travessia de diretório (se der pra montar um) ---
if command -v python3 >/dev/null 2>&1; then
  evil_tarball="$(pvx::tmpdir)/evil.tar.gz"
  python3 - "$PVX_ROOT/modules/dummy/module.json" "$evil_tarball" <<'PYEOF'
import sys, tarfile
src, dst = sys.argv[1], sys.argv[2]
with tarfile.open(dst, "w:gz") as t:
    t.add(src, arcname="evil-1.0.0/../../../tmp/pwned.json")
PYEOF
  rc=0
  pvx modules install --file "$evil_tarball" >/dev/null 2>&1 || rc=$?
  assert_eq '4. install --file rejeita travessia de diretório (rc=11)' 11 "$rc"
else
  assert_pass '4. pulado: python3 indisponível pra montar o tarball malicioso de teste'
fi

# --- 5. install --file de verdade (sem --sha256, cai no modo "manifest") ---
rc=0
pvx modules install --file "$tarball" >/dev/null 2>&1 || rc=$?
assert_eq '5. install --file (manifest) sucede' 0 "$rc"

# --- 6. list mostra o módulo instalado ---
out=$(pvx modules list)
assert_contains '6. modules list mostra dummy instalado' "$out" 'dummy'
assert_contains '6. modules list mostra a versão 0.1.0' "$out" '0.1.0'

# --- 7. hooks.log mostra a chamada de install, com versão certa ---
hooks_log="$PVX_ROOT_PREFIX/var/lib/pvx/state/dummy/hooks.log"
assert_file '7. hooks.log foi criado pelo hook install' "$hooks_log"
assert_contains '7. hooks.log registra "install 0.1.0"' "$(cat "$hooks_log")" 'install 0.1.0'

# --- 8. pvx dummy hello via despacho real (symlink + shebang do entrypoint) ---
out=$(pvx dummy hello)
assert_contains '8. pvx dummy hello funciona via despacho real' "$out" 'dummy 0.1.0: hello'

# --- 9. pvx dummy status: contrato de env do módulo populado ---
out=$(pvx dummy status)
assert_contains '9. status: PVX_MODULE_NAME correto' "$out" 'PVX_MODULE_NAME=dummy'
assert_contains '9. status: PVX_MODULE_VERSION correto' "$out" 'PVX_MODULE_VERSION=0.1.0'
assert_contains '9. status: PVX_MODULE_DIR aponta pro diretório certo' "$out" \
  "PVX_MODULE_DIR=$PVX_ROOT_PREFIX/opt/pvx/modules/dummy"
assert_contains '9. status: PVX_MODULE_STATE_DIR aponta pro state dedicado' "$out" \
  "PVX_MODULE_STATE_DIR=$PVX_ROOT_PREFIX/var/lib/pvx/state/dummy"

# --- 10. ação inválida cai no usage com rc=2 ---
rc=0
pvx dummy bogus >/dev/null 2>&1 || rc=$?
assert_eq '10. pvx dummy <ação inválida> retorna rc=2' 2 "$rc"

# --- 11. modules help dummy delega pro --help do entrypoint ---
out=$(pvx modules help dummy)
assert_contains '11. modules help dummy mostra o uso do módulo' "$out" 'uso: pvx dummy'

# --- 12. reinstalar mesma versão sem --force não faz nada (mas não é erro) ---
out=$(pvx modules install --file "$tarball" 2>&1)
rc=0
pvx modules install --file "$tarball" >/dev/null 2>&1 || rc=$?
assert_eq '12. reinstalar mesma versão sem --force retorna rc=0' 0 "$rc"
assert_contains '12. reinstalar sem --force avisa "já está instalado"' "$out" 'já está instalado'

# --- 13. --force reinstala de verdade (novo registro de "install" no hooks.log) ---
before_count=$(grep -c '^install ' "$hooks_log")
pvx modules install --file "$tarball" --force >/dev/null 2>&1
after_count=$(grep -c '^install ' "$hooks_log")
assert_eq '13. --force chama o hook install de novo' "$((before_count + 1))" "$after_count"

# --- 14. remove (sem --purge): hooks.log preserva histórico, state dir sobrevive ---
pvx modules remove dummy >/dev/null 2>&1
assert_contains '14. hooks.log registra "uninstall" após remove' "$(cat "$hooks_log")" 'uninstall'
assert_file '14. state dir do módulo sobrevive ao remove (sem --purge)' "$hooks_log"

# --- 15. comando do módulo removido não resolve mais ---
rc=0
pvx dummy hello >/dev/null 2>&1 || rc=$?
assert_eq '15. pvx dummy some do dispatcher após remove' 127 "$rc"

# --- 16. list volta a mostrar vazio ---
out=$(pvx modules list)
assert_contains '16. modules list volta a mostrar vazio após remove' "$out" 'nenhum módulo instalado'

# --- 17. reinstala e remove --purge: agora o state dir é apagado de verdade ---
pvx modules install --file "$tarball" >/dev/null 2>&1
pvx modules remove dummy --purge >/dev/null 2>&1
assert_no_file '17. remove --purge apaga o state dir do módulo' "$hooks_log"

# --- 18. instalar módulo inexistente/nome desconhecido via registry (ainda não disponível) ---
rc=0
pvx modules install nome-qualquer >/dev/null 2>&1 || rc=$?
assert_eq '18. install <nome> (sem --file) retorna "indisponível" nesta versão' \
  "$PVX_EXIT_UNAVAILABLE" "$rc"

assert_summary
