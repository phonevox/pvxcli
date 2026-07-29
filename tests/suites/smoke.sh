#!/usr/bin/env bash
# tests/suites/smoke.sh — teste de ponta a ponta do subsistema `pvx modules`, através do
# dispatcher REAL (bin/pvx), não chamando as funções de lib diretamente. Roda isolado num
# PVX_ROOT_PREFIX temporário — nunca toca em /var/lib/pvx ou /opt/pvx de verdade.
#
# No macOS: o entrypoint do módulo (`#!/usr/bin/env bash`) é executado como processo filho
# de verdade (não uma função) e resolve o "bash" do PATH do sistema — que no macOS é o 3.2
# antigo, insuficiente. Isso independe de qual bash rodou ESTE script: resolução de shebang
# via `env` usa o PATH do processo filho no momento do fork, não herda "qual bash" do pai.
# Por isso o bloco logo abaixo garante o bash do Homebrew na frente do PATH sozinho — não
# depende de quem chamou este arquivo já ter feito isso. No alvo real (CentOS/Debian/Ubuntu)
# isso não é um problema (o "bash" padrão já é >=4.2), o bloco simplesmente não faz nada lá.
set -Eeuo pipefail

for _pvx_brew_bin in /opt/homebrew/bin /usr/local/bin; do
  if [[ -x "$_pvx_brew_bin/bash" ]] && [[ ":$PATH:" != *":$_pvx_brew_bin:"* ]]; then
    export PATH="$_pvx_brew_bin:$PATH"
  fi
done
unset _pvx_brew_bin

# o bloco acima só ajuda processos FILHOS (módulos despachados via shebang) — se este
# script em si já começou rodando sob o bash 3.2 do macOS (ex: alguém chamou `bash
# tests/suites/smoke.sh` com o PATH padrão do sistema), ele nem consegue chegar no
# `source bootstrap.sh` abaixo (que usa `declare -g`, sintaxe que o 3.2 não tem). Re-executa
# a si mesmo sob um bash >=4 antes de prosseguir, se necessário.
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
# Nota: os `assert_fail` + `assert_summary` abaixo (aqui e nos outros pontos de bootstrap de
# fixture, tests 19 e 22) são guardas de SETUP, não testes — se o setup em si falhar, não faz
# sentido descobrir/rodar nenhuma test_*(), então aborta direto (assert_summary já sai com
# rc=1 mesmo com 0 testes descobertos, de propósito — ver tests/lib/assert.sh).
dist_dir="$(pvx::tmpdir)/dist"
mkdir -p "$dist_dir"
pack_log="$(pvx::tmpdir)/pack.log"
# limpa tarballs do dummy que possam ter sobrado de uma execução anterior desta suite —
# $PVX_ROOT/dist é build output real (não isolado por teste), então sem isso um
# pvx-mod-dummy-0.1.1.tar.gz de uma rodada passada (test 22 gera um de propósito) fica lá, e
# o glob+`head -1` logo abaixo pode pegar essa versão errada em vez da 0.1.0 fresca.
rm -f "$PVX_ROOT"/dist/pvx-mod-dummy-*.tar.gz*
if ! (cd "$PVX_ROOT" && "$BASH" tools/pack-module.sh modules/dummy) >"$pack_log" 2>&1; then
  assert_fail "tools/pack-module.sh falhou ao empacotar modules/dummy: $(cat "$pack_log")"
  assert_summary
fi
cp "$PVX_ROOT"/dist/pvx-mod-dummy-*.tar.gz "$dist_dir"/
tarball=$(find "$dist_dir" -maxdepth 1 -name 'pvx-mod-dummy-*.tar.gz' | head -1)
test_01_pack_gera_tarball() { assert_file 'pack-module.sh gerou o tarball do dummy' "$tarball"; }
assert_flush

# --- 1. list vazio ---
out=$(pvx modules list)
test_02_list_vazio() { assert_contains '1. modules list (vazio) avisa que não há módulos' "$out" 'nenhum módulo instalado'; }
assert_flush

# --- 2. install --file rejeita sha256 errado ---
rc=0
pvx modules install --file "$tarball" --sha256 '0000000000000000000000000000000000000000000000000000000000000000' \
  >/dev/null 2>&1 || rc=$?
test_03_install_sha256_errado() { assert_eq '2. install --file com sha256 errado retorna rc=5' 5 "$rc"; }
assert_flush

# --- 3. install --file rejeita arquivo inexistente ---
rc=0
pvx modules install --file "$(pvx::tmpdir)/nao-existe-$$.tar.gz" >/dev/null 2>&1 || rc=$?
test_04_install_arquivo_inexistente() { assert_eq '3. install --file de arquivo inexistente retorna rc=1' 1 "$rc"; }
assert_flush

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
  test_05_install_rejeita_travessia() { assert_eq '4. install --file rejeita travessia de diretório (rc=11)' 11 "$rc"; }
else
  test_05_install_rejeita_travessia() { assert_pass '4. pulado: python3 indisponível pra montar o tarball malicioso de teste'; }
fi
assert_flush

# --- 5. install --file de verdade (sem --sha256, cai no modo "manifest") ---
rc=0
pvx modules install --file "$tarball" >/dev/null 2>&1 || rc=$?
test_06_install_manifest_sucede() { assert_eq '5. install --file (manifest) sucede' 0 "$rc"; }
assert_flush

# --- 6. list mostra o módulo instalado ---
out=$(pvx modules list)
test_07_list_mostra_instalado() { assert_contains '6. modules list mostra dummy instalado' "$out" 'dummy'; }
test_08_list_mostra_versao() { assert_contains '6. modules list mostra a versão 0.1.0' "$out" '0.1.0'; }
assert_flush

# --- 7. hooks.log mostra a chamada de install, com versão certa ---
hooks_log="$PVX_ROOT_PREFIX/var/lib/pvx/state/dummy/hooks.log"
test_09_hooks_log_criado() { assert_file '7. hooks.log foi criado pelo hook install' "$hooks_log"; }
test_10_hooks_log_install() {
  assert_contains '7. hooks.log registra "install 0.1.0"' "$(cat "$hooks_log")" 'install 0.1.0'
}
assert_flush

# --- 8. pvx dummy hello via despacho real (symlink + shebang do entrypoint) ---
out=$(pvx dummy hello)
test_11_dummy_hello() { assert_contains '8. pvx dummy hello funciona via despacho real' "$out" 'dummy 0.1.0: hello'; }
assert_flush

# --- 9. pvx dummy status: contrato de env do módulo populado ---
out=$(pvx dummy status)
test_12_status_module_name() { assert_contains '9. status: PVX_MODULE_NAME correto' "$out" 'PVX_MODULE_NAME=dummy'; }
test_13_status_module_version() {
  assert_contains '9. status: PVX_MODULE_VERSION correto' "$out" 'PVX_MODULE_VERSION=0.1.0'
}
test_14_status_module_dir() {
  assert_contains '9. status: PVX_MODULE_DIR aponta pro diretório certo' "$out" \
    "PVX_MODULE_DIR=$PVX_ROOT_PREFIX/opt/pvx/modules/dummy"
}
test_15_status_module_state_dir() {
  assert_contains '9. status: PVX_MODULE_STATE_DIR aponta pro state dedicado' "$out" \
    "PVX_MODULE_STATE_DIR=$PVX_ROOT_PREFIX/var/lib/pvx/state/dummy"
}
assert_flush

# --- 10. ação inválida cai no usage com rc=2 ---
rc=0
pvx dummy bogus >/dev/null 2>&1 || rc=$?
test_16_acao_invalida() { assert_eq '10. pvx dummy <ação inválida> retorna rc=2' 2 "$rc"; }
assert_flush

# --- 11. modules help dummy delega pro --help do entrypoint ---
out=$(pvx modules help dummy)
test_17_modules_help() { assert_contains '11. modules help dummy mostra o uso do módulo' "$out" 'uso: pvx dummy'; }
assert_flush

# --- 12. reinstalar mesma versão sem --force não faz nada (mas não é erro) ---
out=$(pvx modules install --file "$tarball" 2>&1)
rc=0
pvx modules install --file "$tarball" >/dev/null 2>&1 || rc=$?
test_18_reinstalar_sem_force_rc() { assert_eq '12. reinstalar mesma versão sem --force retorna rc=0' 0 "$rc"; }
test_19_reinstalar_sem_force_avisa() {
  assert_contains '12. reinstalar sem --force avisa "já está instalado"' "$out" 'já está instalado'
}
assert_flush

# --- 13. --force reinstala de verdade (novo registro de "install" no hooks.log) ---
before_count=$(grep -c '^install ' "$hooks_log")
pvx modules install --file "$tarball" --force >/dev/null 2>&1
after_count=$(grep -c '^install ' "$hooks_log")
test_20_force_reinstala() { assert_eq '13. --force chama o hook install de novo' "$((before_count + 1))" "$after_count"; }
assert_flush

# --- 14. remove (sem --purge): hooks.log preserva histórico, state dir sobrevive ---
pvx modules remove dummy >/dev/null 2>&1
test_21_remove_hooks_log_uninstall() {
  assert_contains '14. hooks.log registra "uninstall" após remove' "$(cat "$hooks_log")" 'uninstall'
}
test_22_remove_state_dir_sobrevive() {
  assert_file '14. state dir do módulo sobrevive ao remove (sem --purge)' "$hooks_log"
}
assert_flush

# --- 15. comando do módulo removido não resolve mais ---
rc=0
pvx dummy hello >/dev/null 2>&1 || rc=$?
test_23_comando_some_apos_remove() { assert_eq '15. pvx dummy some do dispatcher após remove' 127 "$rc"; }
assert_flush

# --- 16. list volta a mostrar vazio ---
out=$(pvx modules list)
test_24_list_volta_vazio() { assert_contains '16. modules list volta a mostrar vazio após remove' "$out" 'nenhum módulo instalado'; }
assert_flush

# --- 17. reinstala e remove --purge: agora o state dir é apagado de verdade ---
pvx modules install --file "$tarball" >/dev/null 2>&1
pvx modules remove dummy --purge >/dev/null 2>&1
test_25_purge_apaga_state_dir() { assert_no_file '17. remove --purge apaga o state dir do módulo' "$hooks_log"; }
assert_flush

# --- 18. install <nome> sem --file e sem PVX_REGISTRY_URL alcançável: falha "limpo" (rc=4) ---
rc=0
pvx modules install nome-qualquer >/dev/null 2>&1 || rc=$?
test_26_install_sem_registry() {
  assert_eq '18. install <nome> sem registry alcançável retorna rc=4 (falha ao atualizar índice)' 4 "$rc"
}
assert_flush

# ============================================================================================
# 19+. fluxo remoto de verdade: gera um registry/index.json local (via tools/make-index.sh)
# apontando pro tarball do dummy (via file://), e exercita install/update por nome através
# do dispatcher real, sem --file.
# ============================================================================================
registry_dir="$(pvx::tmpdir)/registry-fixture"
mkdir -p "$registry_dir/tarballs"
cp "$tarball" "$registry_dir/tarballs/"
index_file="$registry_dir/index.json"

make_index_log="$(pvx::tmpdir)/make-index.log"
if ! (cd "$PVX_ROOT" && "$BASH" tools/make-index.sh "$registry_dir/tarballs" "$index_file") \
  >"$make_index_log" 2>&1; then
  assert_fail "tools/make-index.sh falhou: $(cat "$make_index_log")"
  assert_summary
fi
test_27_make_index_gera_arquivo() { assert_file '19. make-index.sh gerou o index.json de teste' "$index_file"; }
assert_flush

export PVX_REGISTRY_URL="file://$index_file"

# --- 20. install <nome> via registry de verdade sucede ---
rc=0
pvx modules install dummy >/dev/null 2>&1 || rc=$?
test_28_install_via_registry_sucede() { assert_eq '20. install dummy via registry (sem --file) sucede' 0 "$rc"; }

out=$(pvx modules list)
test_29_list_mostra_via_registry() { assert_contains '20. modules list mostra dummy instalado via registry' "$out" 'dummy'; }

hooks_log="$PVX_ROOT_PREFIX/var/lib/pvx/state/dummy/hooks.log"
test_30_hooks_log_install_via_registry() {
  assert_contains '20. hooks.log registra install após install via registry' "$(cat "$hooks_log")" 'install 0.1.0'
}
assert_flush

# --- 21. install de nome que não existe no índice retorna erro "não encontrado" ---
rc=0
pvx modules install nao-existe-no-indice >/dev/null 2>&1 || rc=$?
test_31_install_nome_inexistente_no_indice() {
  assert_ne '21. install <nome inexistente no índice> não retorna rc=0' 0 "$rc"
}
assert_flush

# --- 22. update: empacota uma versão nova do dummy (0.1.1) e atualiza o índice ---
dummy_bump_dir="$(pvx::tmpdir)/dummy-0.1.1"
rm -rf "$dummy_bump_dir"
cp -R "$PVX_ROOT/modules/dummy" "$dummy_bump_dir"
sed -i.bak 's/"version": *"0\.1\.0"/"version": "0.1.1"/' "$dummy_bump_dir/module.json"
rm -f "$dummy_bump_dir/module.json.bak"

bump_pack_log="$(pvx::tmpdir)/pack-bump.log"
if ! (cd "$PVX_ROOT" && "$BASH" tools/pack-module.sh "$dummy_bump_dir") >"$bump_pack_log" 2>&1; then
  assert_fail "pack-module.sh (bump) falhou: $(cat "$bump_pack_log")"
  assert_summary
fi
bump_tarball=$(find "$PVX_ROOT/dist" -maxdepth 1 -name 'pvx-mod-dummy-0.1.1.tar.gz' | head -1)
test_32_pack_bump_gera_tarball() { assert_file '22. pack-module.sh gerou o tarball do dummy 0.1.1' "$bump_tarball"; }
cp "$bump_tarball" "$registry_dir/tarballs/"

if ! (cd "$PVX_ROOT" && "$BASH" tools/make-index.sh "$registry_dir/tarballs" "$index_file") \
  >"$make_index_log" 2>&1; then
  assert_fail "tools/make-index.sh (bump) falhou: $(cat "$make_index_log")"
  assert_summary
fi
out=$(cat "$index_file")
test_33_index_regenerado_versao_nova() { assert_contains '22. index.json regenerado aponta a versão mais nova (0.1.1)' "$out" '0.1.1'; }
assert_flush

# --- 23. modules update dummy pega a versão nova, chama o hook update com old/new version ---
rc=0
PVX_REGISTRY_TTL=0 pvx modules update dummy >/dev/null 2>&1 || rc=$?
test_34_update_sucede() { assert_eq '23. modules update dummy sucede' 0 "$rc"; }

out=$(pvx modules list)
test_35_list_mostra_versao_atualizada() { assert_contains '23. modules list mostra a versão nova (0.1.1) após update' "$out" '0.1.1'; }
test_36_hooks_log_chamou_update() {
  assert_contains '23. hooks.log registra a chamada do hook update' "$(cat "$hooks_log")" 'update'
}
test_37_hooks_log_versao_antiga() {
  assert_contains '23. hooks.log registra a versão antiga (0.1.0) no hook update' "$(cat "$hooks_log")" '0.1.0->0.1.1'
}
assert_flush

# ============================================================================================
# 24+. regressão: dispatch de comando SEM nenhum argumento extra (cmd_args vazio) não pode
# travar. Bash < 4.4 trata `"${arr[@]}"` sob `set -u` como "variável não associada" quando arr
# tem ZERO elementos (corrigido só no bash 4.4+) — bin/pvx's main() despachava com
# `"$fn" "${cmd_args[@]}"` sem o guard `${cmd_args[@]+"${cmd_args[@]}"}`, então QUALQUER
# comando core/módulo/snippet chamado sem argumento nenhum crashava no bash 4.2 (CentOS 7),
# mas passava despercebido aqui porque o bash do macOS (Homebrew, >=5.3) já corrigiu isso —
# reproduzido de verdade só rodando num container bash 4.2 de verdade (ver tools/, task de
# rodar a suíte na matriz de containers). Testes abaixo cobrem o CENÁRIO relatado
# ("pvx help"/"pvx sysinfo" sem argumento não rodavam, "pvx sysinfo a" rodava, "pvx help
# sysinfo" acabava executando o sysinfo em vez de mostrar a ajuda dele).
# ============================================================================================
rc=0
out=$(pvx help 2>&1) || rc=$?
test_38_help_sem_args_rc() { assert_eq '24. pvx help (sem argumento) retorna rc=0' 0 "$rc"; }
test_39_help_sem_args_conteudo() { assert_contains '24. pvx help (sem argumento) mostra a ajuda geral' "$out" 'uso: pvx'; }
assert_flush

rc=0
out=$(pvx sysinfo 2>&1) || rc=$?
test_40_sysinfo_sem_args_rc() { assert_eq '24. pvx sysinfo (sem argumento) retorna rc=0' 0 "$rc"; }
test_41_sysinfo_sem_args_conteudo() { assert_contains '24. pvx sysinfo (sem argumento) roda de verdade' "$out" 'pvx-core'; }
assert_flush

rc=0
out=$(pvx sysinfo qualquer-coisa 2>&1) || rc=$?
test_42_sysinfo_com_arg_rc() { assert_eq '24. pvx sysinfo <arg extra> continua retornando rc=0' 0 "$rc"; }
assert_flush

rc=0
out=$(pvx help sysinfo 2>&1) || rc=$?
test_43_help_sysinfo_rc() { assert_eq '24. pvx help sysinfo retorna rc=0' 0 "$rc"; }
test_44_help_sysinfo_mostra_ajuda() {
  assert_contains '24. pvx help sysinfo mostra a ajuda do sysinfo (não o dump completo)' "$out" 'uso: pvx sysinfo'
}
test_45_help_sysinfo_nao_roda_dump() {
  assert_not_contains '24. pvx help sysinfo NÃO roda o dump de verdade' "$out" '== pvx-core =='
}
assert_flush

rc=0
out=$(pvx modules 2>&1) || rc=$?
test_46_modules_sem_args_rc() { assert_eq '24. pvx modules (sem subcomando) retorna rc=0' 0 "$rc"; }
test_47_modules_sem_args_conteudo() { assert_contains '24. pvx modules (sem subcomando) mostra o uso' "$out" 'uso: pvx modules'; }
assert_flush

# --- 25. `pvx help <core-cmd>` mostra a ajuda do comando, não roda ele de verdade — cada
# core::cmd_* precisa tratar -h/--help, senão core::cmd_help's `exec "$0" "$1" --help` só faz
# o comando ignorar o --help e rodar normal (achado de verdade: "pvx help version" imprimia
# a versão em vez de mostrar a ajuda dela). ---
core_version=$(cat "$PVX_ROOT/VERSION" 2>/dev/null) || core_version='0.0.0-dev'
rc=0
out=$(pvx help version 2>&1) || rc=$?
test_48_help_version_rc() { assert_eq '25. pvx help version retorna rc=0' 0 "$rc"; }
test_49_help_version_mostra_ajuda() { assert_contains '25. pvx help version mostra a ajuda' "$out" 'uso: pvx version'; }
test_50_help_version_nao_roda() {
  assert_not_contains '25. pvx help version NÃO só imprime a versão' "$out" "pvx $core_version"
}
assert_flush

assert_summary
