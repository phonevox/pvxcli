#!/usr/bin/env bash
# lib/integrity.sh — verificação de integridade de arquivos/tarballs de módulo: hash sha256,
# pré-scan de segurança de tar (rejeita path absoluto/travessia), exigência de 1 único
# diretório de topo, e conferência de um manifesto SHA256SUMS interno pós-extração.
#
# Extraído de lib/registry.sh e lib/cmd_modules.sh (era só usado ali) porque tanto
# tools/pack-module.sh e tools/make-index.sh (hash) quanto o fluxo de install/update (hash +
# segurança de tar) precisam disso, e a verificação de integridade é uma preocupação distinta
# o bastante (segurança) pra merecer sua própria lib em vez de viver dentro de registry/state.

# integrity::sha256_file <arquivo> — hash criptográfico real (sem fallback não-criptográfico:
# isto é usado pra VERIFICAÇÃO DE INTEGRIDADE de tarball, ao contrário de json::_hash_file que
# só invalida cache).
integrity::sha256_file() {
  local file=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    log::error 'nem sha256sum nem shasum disponíveis — não é possível verificar integridade'
    return 1
  fi
}

# integrity::tar_safety_scan <tarball> — pré-scan de segurança: rejeita entrada com caminho
# absoluto e travessia de diretório ("..") antes de qualquer extração.
integrity::tar_safety_scan() {
  local tarball=$1 line seg
  local -a segs
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    if [[ $line == /* ]]; then
      log::error 'tarball inseguro: entrada com caminho absoluto: %s' "$line"
      return 11
    fi
    IFS='/' read -ra segs <<<"$line"
    for seg in "${segs[@]}"; do
      if [[ $seg == '..' ]]; then
        log::error 'tarball inseguro: travessia de diretório: %s' "$line"
        return 11
      fi
    done
  done < <(tar -tzf "$tarball" 2>/dev/null)
  return 0
}

# integrity::tar_top_dir <tarball> — lista (únicos) os diretórios de topo dentro do tarball.
# Um pacote de módulo válido deve ter exatamente 1.
integrity::tar_top_dir() {
  tar -tzf "$1" 2>/dev/null | awk -F/ '{print $1}' | sort -u
}

# integrity::verify_sha256sums_dir <diretório> — se <diretório>/SHA256SUMS existir, confere
# via `sha256sum -c`/`shasum -a 256 -c` (rodando com cwd=<diretório>, já que o manifesto usa
# caminhos relativos). Sem SHA256SUMS não é erro (avisa e segue) — nem todo tarball de módulo
# precisa ter um.
integrity::verify_sha256sums_dir() {
  local dir=$1
  if [[ ! -r "$dir/SHA256SUMS" ]]; then
    log::warn 'diretório não tem SHA256SUMS — pulando verificação de manifesto'
    return 0
  fi
  local sums_ok=0
  (
    cd "$dir" || exit 1
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum -c SHA256SUMS
    else
      shasum -a 256 -c SHA256SUMS
    fi
  ) >/dev/null 2>&1 && sums_ok=1
  if ((!sums_ok)); then
    log::error 'SHA256SUMS não confere após extração (%s)' "$dir"
    return 5
  fi
  return 0
}
