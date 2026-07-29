#!/usr/bin/env bash
# tests/lib/assert.sh — helper de asserções + runner de testes do pvx-core.
#
# Convenção (shunit2-style): cada teste é uma função test_<algo>() que faz EXATAMENTE UMA
# chamada assert_* (arrange, se precisar, dentro da própria função ou herdado do escopo de
# cima). Depois de definir um bloco de test_*(), chame `assert_flush` — ela descobre (via
# `declare -F`) as funções test_* ainda não rodadas e roda cada uma isolada, num subshell
# próprio. Isso é o que garante a contagem certa mesmo se um teste crashar de verdade (`set -u`,
# sinal, etc.): o crash mata só o subshell daquele teste, não o processo do arquivo inteiro, e
# o total nunca é "quantas linhas eu consegui capturar antes do processo morrer" — é
# literalmente quantas funções test_* existem, sempre.
#
# No final do arquivo, chame `assert_summary` (dá `exit 1` se algo falhou ou crashou).
#
# Uso:
#   test_version_cmp_iguais() { assert_eq "cmp versões iguais" 0 "$(version::cmp 1.2.3 1.2.3)"; }
#   assert_flush
#   ...
#   assert_summary

# Garante que PVX_C/PVX_CE existem como arrays associativos mesmo que lib/color.sh nunca
# tenha sido carregada por quem chamou este arquivo — sem isso, `${PVX_C[green]}` num `PVX_C`
# não-declarado é tratado como expansão aritmética (trata "green" como nome de variável, o
# que quebra sob `set -u`). `declare -gA` num array já existente não apaga o conteúdo.
declare -gA PVX_C 2>/dev/null
declare -gA PVX_CE 2>/dev/null

# Idempotente: se o arquivo de teste já chamou color::init (ou color::set_mode), respeita o
# modo já escolhido; senão inicializa com o padrão (auto).
declare -F color::init >/dev/null 2>&1 && color::init

declare -gA _ASSERT_RAN=()
declare -gi _ASSERT_PASS_N=0 _ASSERT_FAIL_N=0 _ASSERT_CRASH_N=0

# --- primitivas: cada uma devolve 0 (passou) ou 1 (falhou) de propósito — é esse código de
# saída que vira o retorno da função test_*() que a chamou por último, sem precisar de
# nenhuma variável global pra "vazar" o resultado de dentro do subshell isolado de volta. ---

assert_pass() {
  printf '  %sok%s - %s\n' "${PVX_C[green]:-}" "${PVX_C[reset]:-}" "$1"
  [[ -n ${_ASSERT_RESULT_FILE:-} ]] && printf 'ok\n' >"$_ASSERT_RESULT_FILE"
  return 0
}

assert_fail() {
  printf '  %sFALHOU%s - %s\n' "${PVX_CE[bred]:-}" "${PVX_CE[reset]:-}" "$1" >&2
  [[ -n ${_ASSERT_RESULT_FILE:-} ]] && printf 'fail\n' >"$_ASSERT_RESULT_FILE"
  return 1
}

assert_eq() {
  local desc=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc (esperado=[$expected] obtido=[$actual])"
  fi
}

assert_ne() {
  local desc=$1 not_expected=$2 actual=$3
  if [[ $not_expected != "$actual" ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc (não deveria ser [$actual])"
  fi
}

# assert_rc <descrição> <rc esperado> -- <comando...>
assert_rc() {
  local desc=$1 expected=$2
  shift 2
  [[ ${1:-} == -- ]] && shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "$desc" "$expected" "$rc"
}

assert_contains() {
  local desc=$1 haystack=$2 needle=$3
  if [[ $haystack == *"$needle"* ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc (esperava conter '$needle', obteve '$haystack')"
  fi
}

assert_not_contains() {
  local desc=$1 haystack=$2 needle=$3
  if [[ $haystack != *"$needle"* ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc (não deveria conter '$needle')"
  fi
}

assert_file() {
  local desc=$1 file=$2
  if [[ -e $file ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc (arquivo não existe: $file)"
  fi
}

assert_no_file() {
  local desc=$1 file=$2
  if [[ ! -e $file ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc (arquivo não deveria existir: $file)"
  fi
}

# assert_true/assert_false — recebem uma descrição e um COMANDO (não uma string), ex:
#   assert_true "os é rhel-like" os::is_rhel_like
assert_true() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then
    assert_pass "$desc"
  else
    assert_fail "$desc (comando retornou falso: $*)"
  fi
}

assert_false() {
  local desc=$1
  shift
  if ! "$@" >/dev/null 2>&1; then
    assert_pass "$desc"
  else
    assert_fail "$desc (deveria ter retornado falso: $*)"
  fi
}

# --- runner: descoberta + execução isolada -----------------------------------------------

# assert_flush — roda (isolado, em subshell) qualquer test_*() definida desde o último
# flush. Chame depois de cada bloco de test_*() — mantém a ordem de execução igual à ordem
# em que os blocos aparecem no arquivo (a descoberta em si é alfabética dentro de um mesmo
# flush, por isso os nomes de teste usam prefixo numérico com zero-padding, ex: test_09_*).
_ASSERT_RESULT_DIR=${_ASSERT_RESULT_DIR:-}
_assert_result_dir() {
  if [[ -z $_ASSERT_RESULT_DIR ]]; then
    if declare -F pvx::tmpdir >/dev/null 2>&1; then
      _ASSERT_RESULT_DIR=$(pvx::tmpdir)/assert-flush
    else
      _ASSERT_RESULT_DIR=${TMPDIR:-/tmp}/pvx-assert-flush.$$
    fi
    mkdir -p "$_ASSERT_RESULT_DIR"
  fi
  printf '%s\n' "$_ASSERT_RESULT_DIR"
}

# assert_flush roda cada test_*() ainda não processada isolada num subshell. Usa um arquivo
# sentinela (não o exit code do subshell) pra saber se a função passou/falhou de verdade —
# o exit code sozinho não dá pra confiar: um `set -u`/`set -e` disparado ANTES da função
# chegar no assert_* também sai com código 1, igual a um assert_fail deliberado. Se o
# arquivo sentinela não existir depois do subshell rodar, a função nunca chegou no assert —
# ou seja, crashou por outro motivo (variável não associada, sinal, etc.), não é uma falha
# de asserção normal.
#
# IMPORTANTE: as variáveis locais daqui usam prefixo `_af_` de propósito. `"$fn"` é chamado
# DENTRO do frame desta função (o `(...)` só isola o processo, não desfaz o escopo léxico já
# ativo) — então qualquer `local` sem prefixo aqui (ex: `local rc`) sombreia uma variável de
# mesmo nome no arquivo de teste (ex: o padrão comuníssimo `rc=0; cmd || rc=$?`), fazendo a
# test_*() ler o `rc` INTERNO desta função em vez do `$rc` do arquivo. Já mordeu de verdade
# (todo `assert_eq ... "$rc"` lia sempre 0) — daí o prefixo em toda variável local abaixo.
assert_flush() {
  local _af_fn _af_rc _af_result _af_result_file _af_dir
  _af_dir=$(_assert_result_dir)
  while IFS= read -r _af_fn; do
    [[ -z $_af_fn ]] && continue
    [[ -n ${_ASSERT_RAN[$_af_fn]:-} ]] && continue
    _ASSERT_RAN[$_af_fn]=1
    _af_result_file="$_af_dir/$_af_fn.$$"
    rm -f "$_af_result_file"
    _af_rc=0
    ( _ASSERT_RESULT_FILE=$_af_result_file; "$_af_fn" ) || _af_rc=$?
    _af_result=$(cat "$_af_result_file" 2>/dev/null || true)
    rm -f "$_af_result_file"
    case $_af_result in
      ok) _ASSERT_PASS_N=$((_ASSERT_PASS_N + 1)) ;;
      fail) _ASSERT_FAIL_N=$((_ASSERT_FAIL_N + 1)) ;;
      *)
        _ASSERT_CRASH_N=$((_ASSERT_CRASH_N + 1))
        printf '  %sCRASH%s - %s() saiu com código %d antes de terminar a asserção\n' \
          "${PVX_CE[bred]:-}" "${PVX_CE[reset]:-}" "$_af_fn" "$_af_rc" >&2
        ;;
    esac
  done < <(declare -F | awk '{print $3}' | grep '^test_' | sort)
  return 0
}

assert_summary() {
  assert_flush
  local total=$((_ASSERT_PASS_N + _ASSERT_FAIL_N + _ASSERT_CRASH_N))
  if (( total == 0 )); then
    # nenhuma test_*() foi descoberta — ou o arquivo ainda não foi convertido pro modelo
    # novo (só tem assert_* soltos no nível principal, sem nenhuma test_*() nem
    # assert_flush), ou um erro de nomenclatura fez a descoberta não achar nada. De
    # propósito NÃO reporta "0/0 passaram" como sucesso — isso mascararia um arquivo que na
    # prática não testou nada.
    printf '\n%s0 testes descobertos — arquivo não usa test_*()+assert_flush, ou nenhuma foi achada%s\n' \
      "${PVX_C[bred]:-}" "${PVX_C[reset]:-}"
    exit 1
  fi
  if (( _ASSERT_FAIL_N > 0 || _ASSERT_CRASH_N > 0 )); then
    printf '\n%s%d/%d passaram (%d falharam, %d crasharam)%s\n' \
      "${PVX_C[bred]:-}" "$_ASSERT_PASS_N" "$total" "$_ASSERT_FAIL_N" "$_ASSERT_CRASH_N" \
      "${PVX_C[reset]:-}"
    exit 1
  fi
  printf '\n%s%d/%d passaram%s\n' "${PVX_C[green]:-}" "$_ASSERT_PASS_N" "$total" "${PVX_C[reset]:-}"
  exit 0
}
