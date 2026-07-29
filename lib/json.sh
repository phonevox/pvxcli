#!/usr/bin/env bash
# lib/json.sh — parser JSON puro em bash, sem depender de `jq` (pode não existir em RHEL
# mínimo/CentOS 7 offline). Converte JSON em formato "flat" cacheável: linhas
# "<path>\t<tipo>\t<valor>", onde tipo é s(tring)/l(iteral: número|true|false|null)/o(bjeto)/
# a(rray) — para container o "valor" é a CONTAGEM de itens (torna json::len O(1) e preserva
# containers vazios). Todo consumidor deve ler o `.flat` já gerado (via json::flatten_cached),
# nunca reparsear o JSON bruto por chamada — parsear é ~330ms num índice de 9KB, consultar o
# flat já gerado é ~3ms.
#
# Regra de implementação: zero *command substitution* no loop de parsing (medido: custava 2x
# o tempo total) — a saída é acumulada em `_JOUT` (concatenação de string) e resultados
# intermediários (caminho de filho, string decodificada) voltam via variável global, nunca
# `$(...)`.

_JS=''      # texto JSON sendo parseado (global, evita passar a string toda em cada chamada)
_JI=0       # índice de leitura corrente em _JS
_JOUT=''    # buffer de saída (linhas do flat, acumuladas por concatenação)
_JSTR=''    # resultado de json::_parse_string (string decodificada)
_JPATH=''   # resultado de json::_child_key_path / json::_child_idx_path
_JCH=''     # resultado de json::_decode_u_escape

json::_skip_ws() {
  local c
  while ((_JI < ${#_JS})); do
    c=${_JS:_JI:1}
    case $c in
      ' ' | $'\t' | $'\n' | $'\r') _JI=$((_JI + 1)) ;;
      *) break ;;
    esac
  done
  return 0
}

json::_child_key_path() {
  local parent=$1 key=$2
  if [[ $parent == . ]]; then
    _JPATH=".$key"
  else
    _JPATH="$parent.$key"
  fi
  return 0
}

json::_child_idx_path() {
  local parent=$1 idx=$2
  _JPATH="${parent}[$idx]"
  return 0
}

json::_emit() {
  local path=$1 type=$2 value=$3
  value=${value//\\/\\\\}
  value=${value//$'\t'/\\t}
  value=${value//$'\n'/\\n}
  _JOUT+="$path"$'\t'"$type"$'\t'"$value"$'\n'
  return 0
}

# \uHHHH -> caractere real, via suporte nativo do printf do bash (4.2+) pro escape \u.
# Não junta pares substitutos (\uD800-\uDFFF) — limitação aceita, module.json/index.json não
# devem conter codepoints fora do BMP.
json::_decode_u_escape() {
  local hex=$1 fmt
  fmt="\\u$hex"
  # shellcheck disable=SC2059
  printf -v _JCH "$fmt" 2>/dev/null || _JCH='?'
  return 0
}

json::_parse_string() {
  # pré-condição: _JS[_JI] é a aspa de abertura
  local i=$((_JI + 1)) c out='' e hex
  while ((i < ${#_JS})); do
    c=${_JS:i:1}
    if [[ $c == '"' ]]; then
      _JSTR=$out
      _JI=$((i + 1))
      return 0
    elif [[ $c == '\' ]]; then
      i=$((i + 1))
      ((i < ${#_JS})) || break
      e=${_JS:i:1}
      case $e in
        '"') out+='"' ;;
        '\') out+='\' ;;
        /) out+='/' ;;
        b) out+=$'\b' ;;
        f) out+=$'\f' ;;
        n) out+=$'\n' ;;
        r) out+=$'\r' ;;
        t) out+=$'\t' ;;
        u)
          hex=${_JS:i+1:4}
          [[ $hex =~ ^[0-9A-Fa-f]{4}$ ]] || {
            printf 'json: \\u inválido na posição %d\n' "$i" >&2
            return 1
          }
          json::_decode_u_escape "$hex"
          out+=$_JCH
          i=$((i + 4))
          ;;
        *)
          printf 'json: escape desconhecido "\\%s" na posição %d\n' "$e" "$i" >&2
          return 1
          ;;
      esac
      i=$((i + 1))
    else
      out+=$c
      i=$((i + 1))
    fi
  done
  printf 'json: string não terminada (iniciada perto da posição %d)\n' "$_JI" >&2
  return 1
}

json::_parse_string_value() {
  local path=$1
  json::_parse_string || return 1
  json::_emit "$path" s "$_JSTR"
  return 0
}

json::_parse_keyword() {
  local path=$1
  if [[ ${_JS:_JI:4} == true ]]; then
    json::_emit "$path" l true
    _JI=$((_JI + 4))
    return 0
  fi
  if [[ ${_JS:_JI:4} == null ]]; then
    json::_emit "$path" l null
    _JI=$((_JI + 4))
    return 0
  fi
  if [[ ${_JS:_JI:5} == false ]]; then
    json::_emit "$path" l false
    _JI=$((_JI + 5))
    return 0
  fi
  printf 'json: token inválido na posição %d\n' "$_JI" >&2
  return 1
}

json::_parse_number() {
  local path=$1 start=$_JI c mark
  [[ ${_JS:_JI:1} == - ]] && _JI=$((_JI + 1))
  mark=$_JI
  while ((_JI < ${#_JS})); do
    c=${_JS:_JI:1}
    [[ $c == [0-9] ]] || break
    _JI=$((_JI + 1))
  done
  if ((_JI == mark)); then
    printf 'json: número inválido na posição %d\n' "$start" >&2
    return 1
  fi
  if [[ ${_JS:_JI:1} == . ]]; then
    _JI=$((_JI + 1))
    mark=$_JI
    while ((_JI < ${#_JS})); do
      c=${_JS:_JI:1}
      [[ $c == [0-9] ]] || break
      _JI=$((_JI + 1))
    done
    if ((_JI == mark)); then
      printf 'json: fração inválida na posição %d\n' "$start" >&2
      return 1
    fi
  fi
  if [[ ${_JS:_JI:1} == [eE] ]]; then
    _JI=$((_JI + 1))
    [[ ${_JS:_JI:1} == [+-] ]] && _JI=$((_JI + 1))
    mark=$_JI
    while ((_JI < ${#_JS})); do
      c=${_JS:_JI:1}
      [[ $c == [0-9] ]] || break
      _JI=$((_JI + 1))
    done
    if ((_JI == mark)); then
      printf 'json: expoente inválido na posição %d\n' "$start" >&2
      return 1
    fi
  fi
  json::_emit "$path" l "${_JS:start:_JI-start}"
  return 0
}

json::_parse_object() {
  local path=$1 count=0 key
  _JI=$((_JI + 1)) # consome '{'
  json::_skip_ws
  if [[ ${_JS:_JI:1} == '}' ]]; then
    _JI=$((_JI + 1))
    json::_emit "$path" o 0
    return 0
  fi
  while true; do
    json::_skip_ws
    if [[ ${_JS:_JI:1} != '"' ]]; then
      printf 'json: esperava chave de string na posição %d\n' "$_JI" >&2
      return 1
    fi
    json::_parse_string || return 1
    key=$_JSTR
    json::_skip_ws
    if [[ ${_JS:_JI:1} != ':' ]]; then
      printf 'json: esperava ":" na posição %d\n' "$_JI" >&2
      return 1
    fi
    _JI=$((_JI + 1))
    json::_skip_ws
    json::_child_key_path "$path" "$key"
    json::_parse_value "$_JPATH" || return 1
    count=$((count + 1))
    json::_skip_ws
    case ${_JS:_JI:1} in
      ,)
        _JI=$((_JI + 1))
        continue
        ;;
      '}')
        _JI=$((_JI + 1))
        break
        ;;
      *)
        printf 'json: esperava "," ou "}" na posição %d\n' "$_JI" >&2
        return 1
        ;;
    esac
  done
  json::_emit "$path" o "$count"
  return 0
}

json::_parse_array() {
  local path=$1 count=0
  _JI=$((_JI + 1)) # consome '['
  json::_skip_ws
  if [[ ${_JS:_JI:1} == ']' ]]; then
    _JI=$((_JI + 1))
    json::_emit "$path" a 0
    return 0
  fi
  while true; do
    json::_skip_ws
    json::_child_idx_path "$path" "$count"
    json::_parse_value "$_JPATH" || return 1
    count=$((count + 1))
    json::_skip_ws
    case ${_JS:_JI:1} in
      ,)
        _JI=$((_JI + 1))
        continue
        ;;
      ']')
        _JI=$((_JI + 1))
        break
        ;;
      *)
        printf 'json: esperava "," ou "]" na posição %d\n' "$_JI" >&2
        return 1
        ;;
    esac
  done
  json::_emit "$path" a "$count"
  return 0
}

json::_parse_value() {
  local path=$1 c
  if ((_JI >= ${#_JS})); then
    printf 'json: fim inesperado do texto (esperava um valor)\n' >&2
    return 1
  fi
  c=${_JS:_JI:1}
  case $c in
    '{') json::_parse_object "$path" ;;
    '[') json::_parse_array "$path" ;;
    '"') json::_parse_string_value "$path" ;;
    t | f | n) json::_parse_keyword "$path" ;;
    -|[0-9]) json::_parse_number "$path" ;;
    *)
      printf 'json: caractere inesperado "%s" na posição %d\n' "$c" "$_JI" >&2
      return 1
      ;;
  esac
}

# --- API pública -----------------------------------------------------------------------------

json::flatten() {
  local text=$1
  _JS=$text
  _JI=0
  _JOUT=''
  json::_skip_ws
  json::_parse_value '.' || return 1
  json::_skip_ws
  if ((_JI < ${#_JS})); then
    printf 'json: lixo após o valor raiz na posição %d\n' "$_JI" >&2
    return 1
  fi
  printf '%s' "$_JOUT"
  return 0
}

json::flatten_file() {
  local file=$1 text
  [[ -r $file ]] || {
    printf 'json: arquivo não encontrado/legível: %s\n' "$file" >&2
    return 1
  }
  text=$(<"$file")
  json::flatten "$text"
}

json::_hash_file() {
  local file=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    stat -c '%s-%Y' "$file" 2>/dev/null || stat -f '%z-%m' "$file" 2>/dev/null
  fi
}

# json::flatten_cached <json_file> <flat_file> — regenera <flat_file> só se o hash de
# <json_file> mudou desde a última chamada (hash guardado em "<flat_file>.src").
json::flatten_cached() {
  local json_file=$1 flat_file=$2 src_file="${2}.src"
  local cur_hash prev_hash=''
  cur_hash=$(json::_hash_file "$json_file") || return 1
  if [[ -r $src_file ]]; then
    read -r prev_hash <"$src_file" || prev_hash=''
  fi
  if [[ -r $flat_file && -n $cur_hash && $cur_hash == "$prev_hash" ]]; then
    return 0
  fi
  local flat
  flat=$(json::flatten_file "$json_file") || return 1
  printf '%s\n' "$flat" >"$flat_file.tmp" && mv -f "$flat_file.tmp" "$flat_file"
  printf '%s\n' "$cur_hash" >"$src_file.tmp" && mv -f "$src_file.tmp" "$src_file"
  return 0
}

# json::get <flat_file> <path> — imprime o valor; rc=1 se o caminho não existe.
json::get() {
  local flat_file=$1 path=$2
  awk -F'\t' -v p="$path" '
    $1 == p { print $3; found=1; exit }
    END { exit !found }
  ' "$flat_file"
}

json::get_def() {
  local flat_file=$1 path=$2 default=$3 val
  if val=$(json::get "$flat_file" "$path"); then
    printf '%s' "$val"
  else
    printf '%s' "$default"
  fi
  return 0
}

# json::len <flat_file> <path> — contagem de itens de um array/objeto; rc=1 se ausente ou
# não for um container.
json::len() {
  local flat_file=$1 path=$2
  awk -F'\t' -v p="$path" '
    $1 == p && ($2 == "o" || $2 == "a") { print $3; found=1; exit }
    END { exit !found }
  ' "$flat_file"
}

# json::keys <flat_file> <path> — chaves filhas diretas de um objeto (uma por linha).
json::keys() {
  local flat_file=$1 path=$2
  local prefix=$path
  [[ $prefix == . ]] && prefix=''
  awk -F'\t' -v p="$prefix" '
    {
      full = $1
      if (p == "") {
        rest = substr(full, 2)
      } else {
        plen = length(p)
        if (substr(full, 1, plen) != p) next
        if (substr(full, plen + 1, 1) != ".") next
        rest = substr(full, plen + 2)
      }
      if (rest == "") next
      dot = index(rest, ".")
      br = index(rest, "[")
      cut = length(rest) + 1
      if (dot > 0 && dot < cut) cut = dot
      if (br > 0 && br < cut) cut = br
      key = substr(rest, 1, cut - 1)
      if (key != "" && !(key in seen)) { seen[key] = 1; print key }
    }
  ' "$flat_file"
}

# json::find_idx <flat_file> <array_path> <campo> <valor> — índice do elemento de um array
# de objetos cujo <campo> == <valor>; rc=3 se não encontrado.
json::find_idx() {
  local flat_file=$1 array_path=$2 field=$3 value=$4 n idx v
  n=$(json::len "$flat_file" "$array_path") || return 3
  for ((idx = 0; idx < n; idx++)); do
    if v=$(json::get "$flat_file" "${array_path}[$idx].$field") && [[ $v == "$value" ]]; then
      printf '%s' "$idx"
      return 0
    fi
  done
  return 3
}

# json::escape <string> — escapa uma string pra uso dentro de um literal JSON (só usado por
# tools/ ao gerar JSON, ex. registry/index.json de teste — não é um caminho quente).
json::escape() {
  local s=$1 out='' i c
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      '"') out+='\"' ;;
      '\') out+='\\' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      *) out+=$c ;;
    esac
  done
  printf '%s' "$out"
}
