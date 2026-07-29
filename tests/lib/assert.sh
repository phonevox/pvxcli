#!/usr/bin/env bash
# tests/lib/assert.sh — helper de asserções pros testes de unidade do pvx-core.
# Uso: `source` este arquivo depois de já ter as libs carregadas, chame as funções assert_*,
# e no final do arquivo de teste chame `assert_summary` (ela dá `exit 1` se algo falhou).

_ASSERT_PASS=0
_ASSERT_FAIL=0

# Garante que PVX_C/PVX_CE existem como arrays associativos mesmo que lib/color.sh nunca
# tenha sido carregada por quem chamou este arquivo — sem isso, `${PVX_C[green]}` num `PVX_C`
# não-declarado é tratado como expansão aritmética (trata "green" como nome de variável, o
# que quebra sob `set -u`). `declare -gA` num array já existente não apaga o conteúdo.
declare -gA PVX_C 2>/dev/null
declare -gA PVX_CE 2>/dev/null

# Idempotente: se o arquivo de teste já chamou color::init (ou color::set_mode), respeita o
# modo já escolhido; senão inicializa com o padrão (auto).
declare -F color::init >/dev/null 2>&1 && color::init

assert_pass() {
  _ASSERT_PASS=$((_ASSERT_PASS + 1))
  printf '  %sok%s - %s\n' "${PVX_C[green]:-}" "${PVX_C[reset]:-}" "$1"
  return 0
}

assert_fail() {
  _ASSERT_FAIL=$((_ASSERT_FAIL + 1))
  printf '  %sFALHOU%s - %s\n' "${PVX_CE[bred]:-}" "${PVX_CE[reset]:-}" "$1" >&2
  return 0
}

assert_eq() {
  local desc=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc (esperado=[$expected] obtido=[$actual])"
  fi
  return 0
}

assert_ne() {
  local desc=$1 not_expected=$2 actual=$3
  if [[ $not_expected != "$actual" ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc (não deveria ser [$actual])"
  fi
  return 0
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
  return 0
}

assert_not_contains() {
  local desc=$1 haystack=$2 needle=$3
  if [[ $haystack != *"$needle"* ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc (não deveria conter '$needle')"
  fi
  return 0
}

assert_file() {
  local desc=$1 file=$2
  if [[ -e $file ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc (arquivo não existe: $file)"
  fi
  return 0
}

assert_no_file() {
  local desc=$1 file=$2
  if [[ ! -e $file ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc (arquivo não deveria existir: $file)"
  fi
  return 0
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
  return 0
}

assert_false() {
  local desc=$1
  shift
  if ! "$@" >/dev/null 2>&1; then
    assert_pass "$desc"
  else
    assert_fail "$desc (deveria ter retornado falso: $*)"
  fi
  return 0
}

assert_summary() {
  local total=$((_ASSERT_PASS + _ASSERT_FAIL))
  if (( _ASSERT_FAIL > 0 )); then
    printf '\n%s%d/%d passaram (%d FALHARAM)%s\n' \
      "${PVX_C[bred]:-}" "$_ASSERT_PASS" "$total" "$_ASSERT_FAIL" "${PVX_C[reset]:-}"
    exit 1
  fi
  printf '\n%s%d/%d passaram%s\n' "${PVX_C[green]:-}" "$_ASSERT_PASS" "$total" "${PVX_C[reset]:-}"
  exit 0
}
