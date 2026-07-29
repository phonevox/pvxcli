#!/usr/bin/env bash
# tests/unit/flags.sh — testa lib/flags.sh isoladamente.
set -Eeuo pipefail

_TEST_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TEST_DIR/../.." && pwd)
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require color log flags
color::init
export PVX_LOG_DIR="$(pvx::tmpdir)/logtest"
log::init
# shellcheck source=/dev/null
source "$_TEST_DIR/../lib/assert.sh"

# --- bool + valores + bundle de shorts ---
flag::reset
flag::add verbose --short v --type bool
flag::add name --short n --type string --default anon
flag::add count --short c --type int --min 1 --max 10
flag::parse -vc5 --name=fulano arquivo1 arquivo2
test_01_bundle_verbose() { assert_eq 'bundle -vc5 seta verbose' 1 "$(flag::get verbose)"; }
test_02_bundle_count() { assert_eq 'bundle -vc5 seta count=5 (valor colado)' 5 "$(flag::get count)"; }
test_03_name_eq() { assert_eq '--name=valor funciona' fulano "$(flag::get name)"; }
test_04_positional1() { assert_eq 'positional 1' arquivo1 "$(flag::arg 0)"; }
test_05_positional2() { assert_eq 'positional 2' arquivo2 "$(flag::arg 1)"; }
assert_flush

# --- --no-x ---
flag::reset
flag::add strict --type bool --default 1
flag::parse --no-strict
test_06_no_x_zera_bool() { assert_eq '--no-x zera um bool' 0 "$(flag::get strict)"; }
assert_flush

# --- enum inválido falha ---
flag::reset
flag::add nivel --type enum --enum 'baixo|medio|alto'
test_07_enum_invalido() { assert_rc 'enum inválido retorna erro de uso' "$PVX_EXIT_USAGE" -- flag::parse --nivel=extremo; }
assert_flush

# --- ipv4/porta/duration ---
flag::reset
flag::add ip --type ipv4
flag::add porta --type port
flag::add ttl --type duration
test_08_ipv4_octeto_invalido() { assert_rc 'ipv4 com octeto > 255 é rejeitado' "$PVX_EXIT_USAGE" -- flag::parse --ip=192.168.1.500; }
test_09_porta_invalida() { assert_rc 'porta > 65535 é rejeitada' "$PVX_EXIT_USAGE" -- flag::parse --ip=1.2.3.4 --porta=70000; }
flag::parse --ip=192.168.1.10 --porta=5060 --ttl=2h
test_10_ipv4_valido() { assert_eq 'ipv4 válido aceito' 192.168.1.10 "$(flag::get ip)"; }
test_11_porta_valida() { assert_eq 'porta válida aceita' 5060 "$(flag::get porta)"; }
test_12_duration_2h() { assert_eq 'duration 2h vira 7200 segundos' 7200 "$(flag::get ttl)"; }
assert_flush

# --- secret: 3 formas de entrada ---
flag::reset
flag::add_secret dbpass --env PVX_DBPASS
flag::parse --dbpass hunter2 2>/dev/null
test_13_secret_literal() { assert_eq 'secret via literal --dbpass funciona' hunter2 "$(flag::get dbpass)"; }
assert_flush

secret_file="$(pvx::tmpdir)/secret.txt"
printf 's3cr3t-file' >"$secret_file" # sem newline final de propósito (regressão do `read`)
flag::reset
flag::add_secret dbpass --env PVX_DBPASS
flag::parse --dbpass-file "$secret_file"
test_14_secret_file() { assert_eq 'secret via --dbpass-file funciona (mesmo sem newline final)' 's3cr3t-file' "$(flag::get dbpass)"; }
assert_flush

flag::reset
flag::add_secret dbpass --env PVX_DBPASS
export PVX_DBPASS=via-env
flag::parse
test_15_secret_env() { assert_eq 'secret via variável de ambiente funciona' via-env "$(flag::get dbpass)"; }
assert_flush
unset PVX_DBPASS

# --- repeat ---
flag::reset
flag::add exclude --repeat --type string
flag::parse --exclude a --exclude b --exclude c
test_16_repeat_acumula() { assert_eq 'flag --repeat acumula valores' "$(printf 'a\nb\nc')" "$(flag::get_all exclude)"; }
assert_flush

# --- -- encerra parsing de opções ---
flag::reset
flag::add verbose --short v --type bool
flag::parse -- -v --nao-e-flag
test_17_dashdash_impede_v() { assert_eq '-- impede que -v seja parseado como flag' 0 "$(flag::get verbose 0)"; }
test_18_dashdash_positional() { assert_eq '-- move tudo depois pra positional' "$(printf -- '-v\n--nao-e-flag')" "$(flag::args)"; }
assert_flush

# --- allow_unknown ---
flag::reset
flag::allow_unknown 1
flag::add x --type bool
flag::parse --x --desconhecida valor
test_19_allow_unknown() { assert_eq 'flag desconhecida vai pra PVX_UNKNOWN' '--desconhecida' "${PVX_UNKNOWN[0]}"; }
assert_flush

# --- --help autogerado (roda em subshell pq flag::parse --help faz exit) ---
help_out=$(
  flag::reset
  flag::set_usage pvx-teste 'Comando de teste' 'pvx-teste [opções] <arquivo>' 'rodapé de teste'
  flag::add_standard
  flag::add out --short o --type path --help 'arquivo de saída' --group saida
  flag::add_example 'pvx-teste -v -o /tmp/x arquivo.txt'
  flag::parse --help
)
test_20_help_summary() { assert_contains '--help mostra o summary' "$help_out" 'Comando de teste'; }
test_21_help_uso() { assert_contains '--help mostra a linha de uso' "$help_out" 'pvx-teste [opções] <arquivo>'; }
test_22_help_flags_padrao() { assert_contains '--help mostra flags padrão' "$help_out" '--dry-run'; }
test_23_help_flag_short() { assert_contains '--help mostra flag customizado com short' "$help_out" '-o, --out'; }
test_24_help_exemplo() { assert_contains '--help mostra exemplo' "$help_out" 'pvx-teste -v -o /tmp/x arquivo.txt'; }
test_25_help_rodape() { assert_contains '--help mostra o rodapé' "$help_out" 'rodapé de teste'; }
assert_flush

assert_summary
