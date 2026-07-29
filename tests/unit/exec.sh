#!/usr/bin/env bash
# tests/unit/exec.sh — testa lib/exec.sh isoladamente (qrun/run/srun, secrets, retry, confirm).
set -Eeuo pipefail

_TEST_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TEST_DIR/../.." && pwd)
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require color log os paths exec
color::init
export PVX_LOG_DIR="$(pvx::tmpdir)/logtest"
log::init
log::set_level debug
# shellcheck source=/dev/null
source "$_TEST_DIR/../lib/assert.sh"

work=$(pvx::tmpdir)/exec_work
mkdir -p "$work"

# --- qrun roda mesmo em --dry-run (é consulta) ---
PVX_DRY_RUN=1
qrun --capture -- echo consulta >/dev/null
test_01_qrun_dry_run() { assert_eq 'qrun roda mesmo em dry-run' consulta "$PVX_OUT"; }
assert_flush

# --- run NÃO roda em --dry-run ---
run -- touch "$work/nao_deveria_existir"
test_02_run_dry_run_nao_cria() { assert_no_file 'run não cria arquivo em dry-run' "$work/nao_deveria_existir"; }
assert_flush

# --- run roda normalmente sem dry-run ---
PVX_DRY_RUN=0
run -- touch "$work/deveria_existir"
test_03_run_fora_dry_run_cria() { assert_file 'run cria arquivo fora de dry-run' "$work/deveria_existir"; }
assert_flush

# --- captura de stdout/stderr, --ok aceita rc customizado ---
# `run` sempre retorna o rc BRUTO do processo (mesmo "aceitável" via --ok não vira 0) — por
# contrato, então toda chamada precisa de guarda quando o rc não é 0.
run --capture --ok 3 -- bash -c 'echo saida; echo erro >&2; exit 3' || true
test_04_captura_rc() { assert_eq 'captura: PVX_RC reflete o rc real' 3 "$PVX_RC"; }
test_05_captura_stdout() { assert_eq 'captura: PVX_OUT tem o stdout do comando' saida "$PVX_OUT"; }
test_06_captura_stderr() { assert_eq 'captura: PVX_ERR tem o stderr do comando' erro "$PVX_ERR"; }
assert_flush

# --- srun com rc inaceitável aborta o processo (por isso roda num subshell) --- o `(...)`
# isola o `exit` (só termina o subshell), mas NÃO isola o `set -e` do script pai — o subshell
# retornando não-zero ainda é "um comando que falhou" pro pai, então precisa do `|| srun_rc=$?`.
srun_rc=0
(srun -- bash -c 'exit 7') >/dev/null 2>&1 || srun_rc=$?
test_07_srun_rc_inaceitavel() { assert_eq 'srun com rc inaceitável sai com o rc do comando' 7 "$srun_rc"; }
assert_flush

# --- máscara de segredo no comando renderizado ---
run --mask 1 -- echo "valor-secreto" >/dev/null
test_08_mask_oculta_argumento() { assert_contains 'mask oculta o argumento no comando renderizado' "$PVX_CMD" '***'; }
test_09_mask_nao_vaza_valor() {
  assert_not_contains 'mask não deixa o valor real vazar pro comando renderizado' "$PVX_CMD" 'valor-secreto'
}
assert_flush

# --- retry: sucede na 3a tentativa ---
attempt_file="$work/attempts"
: >"$attempt_file"
flaky() {
  local n=0
  [[ -s $attempt_file ]] && n=$(cat "$attempt_file")
  n=$((n + 1))
  printf '%s' "$n" >"$attempt_file"
  (( n >= 3 ))
}
test_10_retry_sucede() { assert_rc 'exec::retry eventualmente sucede' 0 -- exec::retry 5 0 flaky; }
test_11_retry_parou_com_sucesso() {
  assert_eq 'exec::retry parou assim que teve sucesso (3 tentativas)' 3 "$(cat "$attempt_file")"
}
assert_flush

# --- require_cmd / has_cmd ---
test_12_has_cmd_detecta() { assert_true 'has_cmd detecta bash' exec::has_cmd bash; }
test_13_has_cmd_nao_detecta() { assert_false 'has_cmd não detecta comando inexistente' exec::has_cmd comando_xyz_inexistente; }
test_14_require_cmd_falha() {
  assert_rc 'require_cmd falha com PVX_EXIT_UNAVAILABLE pra comando ausente' \
    "$PVX_EXIT_UNAVAILABLE" -- exec::require_cmd comando_xyz_inexistente
}
assert_flush

# --- mysql_defaults_file: nunca expõe a senha via argv, arquivo fica 0600 ---
f=$(exec::mysql_defaults_file root 'senha123')
test_15_mysql_defaults_cria() { assert_file 'mysql_defaults_file cria o arquivo' "$f"; }
# -c (GNU/Linux) primeiro — na ordem invertida, o "stat -f" do GNU não dá erro de opção
# desconhecida, e sim vaza uma info de filesystem (lixo) pro stdout antes de falhar, que
# fica misturado com o valor certo do fallback dentro do mesmo $(...).
perm=$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null)
test_16_mysql_defaults_permissao() { assert_eq 'mysql_defaults_file cria com permissão 600' 600 "$perm"; }
conteudo_mysql=$(cat "$f")
test_17_mysql_defaults_usuario() { assert_contains 'arquivo de defaults tem o usuário' "$conteudo_mysql" 'user=root'; }
test_18_mysql_defaults_senha() { assert_contains 'arquivo de defaults tem a senha' "$conteudo_mysql" 'password=senha123'; }
assert_flush

# --- confirm nunca trava sob non-TTY ---
test_19_confirm_default() { assert_false 'confirm sem TTY usa o default (n)' exec::confirm 'confirma?' n < /dev/null; }
assert_flush
PVX_ASSUME_YES=1
test_20_confirm_assume_yes() { assert_true 'PVX_ASSUME_YES força confirm a aceitar' exec::confirm 'confirma?' n < /dev/null; }
assert_flush
PVX_ASSUME_YES=0

assert_summary
