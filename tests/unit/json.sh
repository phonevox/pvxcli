#!/usr/bin/env bash
# tests/unit/json.sh — testa lib/json.sh: diferencial contra `jq` (quando disponível, só pra
# strings/bool/null — números são testados à parte porque meu parser preserva a forma léxica
# original do número-fonte, enquanto o `tostring` do jq normaliza o valor double internamente
# e pode divergir mesmo estando ambos "corretos"), containers vazios, escapes, rejeição de
# JSON malformado, e a API de consulta (get/len/keys/find_idx) sobre um fixture real.
set -Eeuo pipefail

_TEST_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PVX_ROOT=$(cd -P "$_TEST_DIR/../.." && pwd)
PVX_LIB_DIR="$PVX_ROOT/lib"
export PVX_ROOT PVX_LIB_DIR

# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require color log json
color::init
export PVX_LOG_DIR="$(pvx::tmpdir)/logtest"
log::init
# shellcheck source=/dev/null
source "$_TEST_DIR/../lib/assert.sh"

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# --- diferencial contra jq (só strings/bool/null — ver nota no topo) --------------------------
json_diff_check() {
  local desc=$1 json=$2
  (( HAVE_JQ )) || { assert_pass "$desc (pulado, jq não disponível)"; return; }
  local myflat mine_leaves jqout
  if ! myflat=$(json::flatten "$json"); then
    assert_fail "$desc (meu parser rejeitou um JSON válido)"
    return
  fi
  mine_leaves=$(printf '%s\n' "$myflat" | awk -F'\t' '$2=="s" || $2=="l" {print $1"\t"$3}' | sort)
  jqout=$(printf '%s' "$json" | jq -r '
    paths as $p | getpath($p) as $v
    | select(($v|type)!="object" and ($v|type)!="array")
    | ($p|map(if type=="number" then "["+tostring+"]" else "."+. end)|join("")) + "\t" + ($v|tostring)
  ' | sort)
  assert_eq "$desc" "$jqout" "$mine_leaves"
}

test_01_json_diff_objeto_simples() {
  json_diff_check 'objeto simples' '{"a":"x","b":true,"c":false,"d":null}'
}
test_02_json_diff_aninhamento() {
  json_diff_check 'aninhamento de objetos' '{"a":{"b":{"c":"fundo"}}}'
}
# nota: array como valor RAIZ (não aninhado num objeto) tem convenção de path diferente entre
# jq ("[0]", sem ponto) e este parser (".[0]", já que "." é sempre o path da raiz) — diferença
# só nesse caso de borda, que não ocorre nos JSONs reais do projeto (registry/module.json são
# sempre objetos na raiz). Por isso os fixtures de array aqui vêm aninhados num objeto.
test_03_json_diff_array_strings() {
  json_diff_check 'array de strings' '{"lista":["um","dois","tres"]}'
}
test_04_json_diff_array_objetos() {
  json_diff_check 'array de objetos (formato de índice de módulos)' \
    '{"modules":[{"name":"dummy","summary":"teste"},{"name":"outro","summary":"outro teste"}]}'
}
test_05_json_diff_mistura_tipos() {
  json_diff_check 'mistura de tipos em array' '{"lista":[true,false,null,"str",{"k":"v"}]}'
}
test_06_json_diff_espacos_brancos() {
  json_diff_check 'espaços em branco entre tokens' '{ "a" : "x" ,  "b" : true }'
}
assert_flush

# --- números: testados direto (não contra jq — ver nota no topo) ------------------------------
num_check() {
  local desc=$1 json=$2 path=$3 expected=$4 flat
  flat=$(json::flatten "$json") || { assert_fail "$desc (parser rejeitou)"; return; }
  assert_eq "$desc" "$expected" "$(json::get_def <(printf '%s' "$flat") "$path" '<ausente>')"
}
test_07_num_inteiro_positivo() { num_check 'inteiro positivo' '{"n":42}' .n 42; }
test_08_num_inteiro_negativo() { num_check 'inteiro negativo' '{"n":-42}' .n -42; }
test_09_num_zero() { num_check 'zero' '{"n":0}' .n 0; }
test_10_num_decimal() { num_check 'decimal' '{"n":3.14}' .n 3.14; }
test_11_num_expoente_positivo() { num_check 'expoente positivo com sinal' '{"n":1e+10}' .n 1e+10; }
test_12_num_expoente_negativo() { num_check 'expoente negativo' '{"n":1.5e-3}' .n 1.5e-3; }
test_13_num_expoente_maiusculo() { num_check 'expoente maiúsculo' '{"n":2E5}' .n 2E5; }
assert_flush

# --- containers vazios (preservados, não confundidos com "ausente") ---------------------------
flat_empty=$(json::flatten '{"vazio_obj":{},"vazio_arr":[],"cheio":[1]}')
test_14_containers_objeto_vazio() {
  assert_eq 'objeto vazio: contagem 0' 0 "$(json::len <(printf '%s' "$flat_empty") .vazio_obj)"
}
test_15_containers_array_vazio() {
  assert_eq 'array vazio: contagem 0' 0 "$(json::len <(printf '%s' "$flat_empty") .vazio_arr)"
}
test_16_containers_array_nao_vazio() {
  assert_eq 'array não-vazio: contagem correta' 1 "$(json::len <(printf '%s' "$flat_empty") .cheio)"
}
assert_flush

# --- escapes: \", \\, \/, \b \f \n \r \t, \uXXXX ---
flat_esc=$(json::flatten '{"s":"aspas:\" barra-invertida:\\ barra:\/ tab:\t nova-linha:\n retorno:\r euro:€"}')
esc_val=$(json::get <(printf '%s' "$flat_esc") .s)
# meu formato re-escapa \t e \n como texto literal "\t"/"\n" (2 chars) pra manter 1 linha por
# registro no flat — então o valor RECUPERADO por json::get já vem com esses 2-chars literais,
# não o byte de controle real. É o comportamento documentado, não um bug.
test_17_escape_aspas() {
  assert_contains 'escape de aspas decodificado' "$esc_val" 'aspas:" '
}
# o valor decodificado (barra invertida real) é re-escapado pra "\\" no flat, de propósito,
# pra não ficar ambíguo com os marcadores "\t"/"\n" também inseridos por json::_emit.
test_18_escape_barra_invertida() {
  assert_contains 'escape de barra invertida decodificado' "$esc_val" 'barra-invertida:\\ '
}
test_19_escape_barra() {
  assert_contains 'escape de barra decodificado' "$esc_val" 'barra:/ '
}
test_20_escape_tab() {
  assert_contains 'escape de tab fica como \t literal no flat (por design)' "$esc_val" 'tab:\t '
}
test_21_escape_nova_linha() {
  assert_contains 'escape de nova-linha fica como \n literal no flat (por design)' "$esc_val" 'nova-linha:\n '
}
test_22_escape_unicode_euro() {
  assert_contains 'escape \u decodifica pra utf-8 (euro sign)' "$esc_val" $'euro:€'
}
assert_flush

# --- rejeição de JSON malformado ---
test_23_malformado_virgula_objeto() {
  assert_rc 'objeto com vírgula sobrando é rejeitado' 1 -- json::flatten '{"a":1,}'
}
test_24_malformado_virgula_array() {
  assert_rc 'array com vírgula sobrando é rejeitado' 1 -- json::flatten '[1,2,]'
}
test_25_malformado_string_nao_terminada() {
  assert_rc 'string não terminada é rejeitada' 1 -- json::flatten '{"a":"sem fechar}'
}
test_26_malformado_token_invalido() {
  assert_rc 'token inválido é rejeitado' 1 -- json::flatten '{"a":verdadeiro}'
}
test_27_malformado_sem_dois_pontos() {
  assert_rc 'objeto sem dois-pontos é rejeitado' 1 -- json::flatten '{"a" 1}'
}
test_28_malformado_lixo_apos_valor() {
  assert_rc 'lixo depois do valor raiz é rejeitado' 1 -- json::flatten '{"a":1} lixo'
}
test_29_malformado_entrada_vazia() {
  assert_rc 'entrada vazia é rejeitada' 1 -- json::flatten ''
}
assert_flush

# --- flatten_file ---
fixture_dir=$(pvx::tmpdir)/json_fixture
mkdir -p "$fixture_dir"
fixture_json="$fixture_dir/dummy.json"
cat >"$fixture_json" <<'EOF'
{
  "schema_version": 1,
  "modules": [
    {"name": "dummy", "version": "0.1.0", "summary": "módulo de teste"},
    {"name": "firewall", "version": "2.0.0", "summary": "outro módulo"}
  ]
}
EOF
flat_file="$fixture_dir/dummy.flat"
json::flatten_file "$fixture_json" >"$flat_file"

test_30_flatten_file_schema_version() {
  assert_eq 'get: schema_version' 1 "$(json::get "$flat_file" .schema_version)"
}
test_31_flatten_file_len_modules() {
  assert_eq 'len: contagem de modules' 2 "$(json::len "$flat_file" .modules)"
}
test_32_flatten_file_get_nome_mod0() {
  assert_eq 'get: nome do 1o módulo' dummy "$(json::get "$flat_file" '.modules[0].name')"
}
test_33_flatten_file_get_versao_mod1() {
  assert_eq 'get: versão do 2o módulo' 2.0.0 "$(json::get "$flat_file" '.modules[1].version')"
}
test_34_flatten_file_get_def_default() {
  assert_eq 'get_def: chave ausente usa default' padrao \
    "$(json::get_def "$flat_file" .chave_inexistente padrao)"
}
get_rc=0
json::get "$flat_file" .chave_inexistente >/dev/null 2>&1 || get_rc=$?
test_35_flatten_file_get_ausente_rc() {
  assert_eq 'get: chave ausente retorna rc=1' 1 "$get_rc"
}

idx=$(json::find_idx "$flat_file" .modules name firewall)
test_36_flatten_file_find_idx_acha() {
  assert_eq 'find_idx: acha o índice certo pelo campo name' 1 "$idx"
}
find_rc=0
json::find_idx "$flat_file" .modules name nao_existe >/dev/null 2>&1 || find_rc=$?
test_37_flatten_file_find_idx_rc_nao_encontra() {
  assert_eq 'find_idx: rc=3 quando não encontra' 3 "$find_rc"
}

keys_root=$(json::keys "$flat_file" .)
test_38_flatten_file_keys_raiz_schema_version() {
  assert_contains 'keys: lista chaves do objeto raiz' "$keys_root" 'schema_version'
}
test_39_flatten_file_keys_raiz_modules() {
  assert_contains 'keys: lista chaves do objeto raiz (modules)' "$keys_root" 'modules'
}
keys_mod0=$(json::keys "$flat_file" '.modules[0]')
test_40_flatten_file_keys_elemento_array() {
  assert_contains 'keys: lista chaves de um elemento de array' "$keys_mod0" 'name'
}
assert_flush

# --- flatten_cached: só regenera quando o arquivo fonte muda ---
cache_flat="$fixture_dir/cached.flat"
json::flatten_cached "$fixture_json" "$cache_flat"
test_41_flatten_cached_cria_arquivo() {
  assert_file 'flatten_cached cria o arquivo flat' "$cache_flat"
}
mtime1=$(stat -f '%m' "$cache_flat" 2>/dev/null || stat -c '%Y' "$cache_flat" 2>/dev/null)
sleep 1
json::flatten_cached "$fixture_json" "$cache_flat"
mtime2=$(stat -f '%m' "$cache_flat" 2>/dev/null || stat -c '%Y' "$cache_flat" 2>/dev/null)
test_42_flatten_cached_nao_regenera() {
  assert_eq 'flatten_cached não regenera se o fonte não mudou' "$mtime1" "$mtime2"
}

printf '{"schema_version":2,"modules":[]}' >"$fixture_json"
json::flatten_cached "$fixture_json" "$cache_flat"
test_43_flatten_cached_regenera_apos_mudanca() {
  assert_eq 'flatten_cached regenera quando o fonte muda' 2 "$(json::get "$cache_flat" .schema_version)"
}
assert_flush

# --- json::escape (usado por tools/ pra gerar JSON) ---
escaped=$(json::escape 'linha "com aspas" e \barra\ e	tab')
test_44_escape_aspas_viram() {
  assert_contains 'escape: aspas viram \"' "$escaped" '\"com aspas\"'
}
test_45_escape_barra_invertida_vira() {
  assert_contains 'escape: barra invertida vira \\' "$escaped" '\\barra\\'
}
test_46_escape_tab_vira() {
  assert_contains 'escape: tab vira \t' "$escaped" '\t'
}
assert_flush

assert_summary
