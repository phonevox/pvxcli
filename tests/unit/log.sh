#!/usr/bin/env bash
# tests/unit/log.sh — testa lib/log.sh isoladamente, incluindo os níveis que historicamente
# quebraram (info/warn/error) e a filtragem por componente da ação `logs` universal.
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
# shellcheck source=/dev/null
source "$_TEST_DIR/../lib/assert.sh"

LOGDIR=$(pvx::tmpdir)/logtest
export PVX_LOG_DIR=$LOGDIR
log::init
log::set_level trace

for lvl in trace debug info warn error fatal silent 5 99; do
  log::set_level "$lvl"
  assert_eq "set_level $lvl não quebra o script (regressão: fórmula com && no fim)" \
    0 0
done
log::set_level info

for lvl in trace debug info warn error; do
  log::set_level "$lvl" --file
done
assert_pass 'set_level --file para todos os níveis não quebra'

# o loop anterior deixou PVX_LOG_FILE_LEVEL em 'error' (última iteração) — resetar os dois
# níveis explicitamente, senão info/warn não alcançam o arquivo e os asserts abaixo falham.
log::set_level trace
log::set_level trace --file
export PVX_LOG_CONTEXT=testctx
log::info 'linha de info'
log::warn 'linha de warn'
log::error 'linha de error'
file=$(log::file_path)
assert_file 'arquivo de log foi criado' "$file"
conteudo=$(cat "$file")
assert_contains 'arquivo contém a linha de info' "$conteudo" 'linha de info'
assert_contains 'arquivo contém a linha de warn' "$conteudo" 'linha de warn'
assert_contains 'arquivo contém a linha de error' "$conteudo" 'linha de error'
assert_contains 'linhas do arquivo têm o contexto testctx' "$conteudo" 'testctx: linha de info'

log::add_secret ''
assert_pass 'add_secret com string vazia não quebra (regressão)'
log::add_secret 's3nh4'
log::error 'senha=s3nh4 --token abcXYZ falhou -p123456 também'
conteudo2=$(cat "$file")
assert_not_contains 'segredo registrado é redigido no arquivo' "$conteudo2" 's3nh4'
assert_contains 'padrão --token <valor> (separado por espaço) é redigido' "$conteudo2" '--token ***'
assert_contains 'padrão -p<valor> é redigido' "$conteudo2" '-p***'

log::rotate
assert_pass 'rotate não quebra'

log::raw ''
log::raw 'linha crua'
assert_pass 'raw com vazio e não-vazio não quebra'

log::hint 'dica de teste'
assert_pass 'hint não quebra'


# is_enabled é um OR entre console e arquivo — pra testar "debug desabilitado" de verdade,
# os dois thresholds (não só o do console) precisam estar acima de debug.
log::set_level info
log::set_level error --file

assert_false 'is_enabled debug é falso com nível info (console)' log::is_enabled debug
assert_true 'is_enabled error é verdadeiro' log::is_enabled error

log::set_level trace --file # baixa o threshold do arquivo de novo pro teste de log::tail abaixo

# --- log::tail: filtra por componente, ignora linhas de outro contexto ---
export PVX_LOG_CONTEXT=dummy
log::info 'primeira linha do dummy'
export PVX_LOG_CONTEXT=modules
log::warn 'linha do subsistema modules'
export PVX_LOG_CONTEXT=dummy
log::info 'segunda linha do dummy'

# `log::tail` segue o arquivo pra sempre (tail -F) — sem `timeout`/`gtimeout` garantido no
# ambiente (não vem por padrão no macOS), roda em background, dá um tempo pra ele imprimir o
# que já existe no arquivo, mata o processo e faz uma limpeza best-effort de qualquer
# tail/grep remanescente specific deste diretório de log de teste.
tail_out_file=$(pvx::tmpdir)/tail_out.txt
: >"$tail_out_file"
"$BASH" -c '
  source "$1/bootstrap.sh"
  pvx::require color log
  color::init
  PVX_LOG_DIR=$2
  log::init
  log::tail dummy -n 20
' _ "$PVX_LIB_DIR" "$LOGDIR" >"$tail_out_file" 2>/dev/null &
tail_pid=$!
sleep 1
kill "$tail_pid" 2>/dev/null || true
wait "$tail_pid" 2>/dev/null || true
pkill -f "tail -n 20 -F $LOGDIR" 2>/dev/null || true
tail_out=$(cat "$tail_out_file")
assert_contains 'log::tail mostra linha do componente dummy' "$tail_out" 'primeira linha do dummy'
assert_contains 'log::tail mostra a segunda linha do dummy' "$tail_out" 'segunda linha do dummy'
assert_not_contains 'log::tail NÃO mostra linha de outro componente' "$tail_out" 'subsistema modules'

assert_summary
