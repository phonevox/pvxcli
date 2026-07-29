#!/usr/bin/env bash
# lib/snippets.sh — helpers de apresentação compartilhados pelos "snippets" (comandos embutidos
# de arquivo único em share/pvx/snippets/*.sh, sourced in-process pelo dispatcher — ver
# `snippet::resolve` e o branch `kind=snippet` de main() em bin/pvx). Só formatação de saída
# aqui, nenhuma lógica de negócio — cada snippet decide o que mostrar, isto só decide como.

snippets::header() {
  printf '\n%s== %s ==%s\n' "${PVX_C[bold]:-}" "$1" "${PVX_C[reset]:-}"
}

# snippets::kv <chave> <valor> — "chave: valor" com a chave alinhada em coluna fixa, pra ficar
# legível quando várias linhas seguidas têm chaves de tamanhos diferentes.
snippets::kv() {
  printf '  %-22s %s\n' "$1:" "$2"
}

snippets::ok() { printf '  %s✓%s %s\n' "${PVX_C[ok]:-}" "${PVX_C[reset]:-}" "$1"; }
snippets::warn() { printf '  %s!%s %s\n' "${PVX_C[warn]:-}" "${PVX_C[reset]:-}" "$1"; }
snippets::bad() { printf '  %s✗%s %s\n' "${PVX_C[error]:-}" "${PVX_C[reset]:-}" "$1"; }

# snippets::list — nomes (sem .sh) de todo snippet disponível em $PVX_ROOT/share/pvx/snippets.
snippets::list() {
  local f
  [[ -d "$PVX_ROOT/share/pvx/snippets" ]] || return 0
  for f in "$PVX_ROOT"/share/pvx/snippets/*.sh; do
    [[ -e $f ]] || continue
    f=${f##*/}
    printf '%s\n' "${f%.sh}"
  done
}
