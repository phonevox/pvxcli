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
assert_eq 'qrun roda mesmo em dry-run' consulta "$PVX_OUT"

# --- run NÃO roda em --dry-run ---
run -- touch "$work/nao_deveria_existir"
assert_no_file 'run não cria arquivo em dry-run' "$work/nao_deveria_existir"

# --- run roda normalmente sem dry-run ---
PVX_DRY_RUN=0
run -- touch "$work/deveria_existir"
assert_file 'run cria arquivo fora de dry-run' "$work/deveria_existir"

# --- captura de stdout/stderr, --ok aceita rc customizado ---
# `run` sempre retorna o rc BRUTO do processo (mesmo "aceitável" via --ok não vira 0) — por
# contrato, então toda chamada precisa de guarda quando o rc não é 0.
run --capture --ok 3 -- bash -c 'echo saida; echo erro >&2; exit 3' || true
assert_eq 'captura: PVX_RC reflete o rc real' 3 "$PVX_RC"
assert_eq 'captura: PVX_OUT tem o stdout do comando' saida "$PVX_OUT"
assert_eq 'captura: PVX_ERR tem o stderr do comando' erro "$PVX_ERR"

# --- srun com rc inaceitável aborta o processo (por isso roda num subshell) --- o `(...)`
# isola o `exit` (só termina o subshell), mas NÃO isola o `set -e` do script pai — o subshell
# retornando não-zero ainda é "um comando que falhou" pro pai, então precisa do `|| srun_rc=$?`.
srun_rc=0
(srun -- bash -c 'exit 7') >/dev/null 2>&1 || srun_rc=$?
assert_eq 'srun com rc inaceitável sai com o rc do comando' 7 "$srun_rc"

# --- máscara de segredo no comando renderizado ---
run --mask 1 -- echo "valor-secreto" >/dev/null
assert_contains 'mask oculta o argumento no comando renderizado' "$PVX_CMD" '***'
assert_not_contains 'mask não deixa o valor real vazar pro comando renderizado' "$PVX_CMD" 'valor-secreto'

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
assert_rc 'exec::retry eventualmente sucede' 0 -- exec::retry 5 0 flaky
assert_eq 'exec::retry parou assim que teve sucesso (3 tentativas)' 3 "$(cat "$attempt_file")"

# --- require_cmd / has_cmd ---
assert_true 'has_cmd detecta bash' exec::has_cmd bash
assert_false 'has_cmd não detecta comando inexistente' exec::has_cmd comando_xyz_inexistente
assert_rc 'require_cmd falha com PVX_EXIT_UNAVAILABLE pra comando ausente' \
  "$PVX_EXIT_UNAVAILABLE" -- exec::require_cmd comando_xyz_inexistente

# --- mysql_defaults_file: nunca expõe a senha via argv, arquivo fica 0600 ---
f=$(exec::mysql_defaults_file root 'senha123')
assert_file 'mysql_defaults_file cria o arquivo' "$f"
perm=$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null)
assert_eq 'mysql_defaults_file cria com permissão 600' 600 "$perm"
conteudo_mysql=$(cat "$f")
assert_contains 'arquivo de defaults tem o usuário' "$conteudo_mysql" 'user=root'
assert_contains 'arquivo de defaults tem a senha' "$conteudo_mysql" 'password=senha123'

# --- confirm nunca trava sob non-TTY ---
assert_false 'confirm sem TTY usa o default (n)' exec::confirm 'confirma?' n < /dev/null
PVX_ASSUME_YES=1
assert_true 'PVX_ASSUME_YES força confirm a aceitar' exec::confirm 'confirma?' n < /dev/null
PVX_ASSUME_YES=0

assert_summary
