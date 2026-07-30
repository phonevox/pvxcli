#!/usr/bin/env bash
# lib/tui.sh — prompts interativos em bash puro (sem `dialog`/`whiptail`, sem `declare -n`:
# piso de bash 4.2, nameref só existe a partir do 4.3 — os helpers internos enxergam as
# variáveis locais do chamador via escopo dinâmico do bash em vez disso).
#
# tui::select    — escolha única, navegação ↑/↓, enter escolhe na hora. Resultado em TUI_CHOICE.
# tui::checklist — seleção múltipla, espaço marca/desmarca, enter confirma. Resultado no array
#                  TUI_RESULT (mesma ordem dos itens recebidos).
# Ambas: 'q'/ESC/Ctrl-C cancela (rc=1). Sem TTY em stdin/stdout (pipe, cron, CI) cai num modo
# texto por número — nunca trava esperando teclas de terminal num ambiente não-interativo.

# tui::select <título> <item1> [item2 ...]
tui::select() {
  local title=$1
  shift
  local -a items=("$@")
  local n=${#items[@]}

  TUI_CHOICE=''
  ((n == 0)) && return 1

  if [[ -t 0 && -t 1 ]]; then
    tui::_select_tty "$title" "${items[@]}"
  else
    tui::_select_fallback "$title" "${items[@]}"
  fi
}

tui::_select_tty() {
  local title=$1
  shift
  local -a items=("$@")
  local n=${#items[@]}
  local i cur=0 cursor_char='>'
  local key key2 key3 rows_drawn=0 cancelled=0 chosen=-1
  local stty_saved=''

  declare -F color::supports_unicode >/dev/null 2>&1 && color::supports_unicode && cursor_char='❯'

  stty_saved=$(stty -g 2>/dev/null) || stty_saved=''
  stty -echo -icanon min 1 time 0 2>/dev/null || true

  tui::_select_tty_restore() {
    [[ -n ${stty_saved:-} ]] && stty "$stty_saved" 2>/dev/null
    return 0
  }
  trap tui::_select_tty_restore RETURN
  # INT/TERM à parte, de propósito: um trap que só CHAMA outra função e dá `return` de dentro
  # dela só retorna dessa função-filha — não do loop bloqueado no `read` lá embaixo. O `read`
  # reinicia sozinho depois que o trap termina (restart de syscall do bash), e como a stty já
  # foi restaurada (echo ligado de novo) mas o loop continua rodando, toda tecla seguinte
  # (inclusive mais Ctrl-C) só aparece como texto puro na tela, sem fazer nada — reproduzido de
  # verdade pressionando Ctrl-C no menu interativo. O `return` precisa estar na própria string
  # do trap (não numa função chamada por ele) pra de fato encerrar ESTA função no ponto da
  # interrupção; começa limpando os três traps pra não deixar um handler obsoleto pra trás.
  trap 'trap - INT TERM RETURN; tui::_select_tty_restore; printf "\n"; TUI_CHOICE=""; return 1' INT TERM

  while true; do
    if ((rows_drawn > 0)); then
      tput cuu "$rows_drawn" 2>/dev/null || true
    fi
    tput ed 2>/dev/null || true

    printf '%s%s%s\n' "${PVX_C[bold]:-}" "$title" "${PVX_C[reset]:-}"
    for ((i = 0; i < n; i++)); do
      if ((i == cur)); then
        printf '  %s%s %s%s\n' "${PVX_C[cyan]:-}" "$cursor_char" "${items[i]}" "${PVX_C[reset]:-}"
      else
        printf '    %s\n' "${items[i]}"
      fi
    done
    printf '  %s↑/↓ (j/k) navega · enter escolhe · q cancela%s\n' "${PVX_C[gray]:-}" "${PVX_C[reset]:-}"
    rows_drawn=$((n + 2))

    key=''
    if ! IFS= read -rsn1 key; then
      cancelled=1
      break
    fi

    if [[ $key == $'\x1b' ]]; then
      key2=''
      IFS= read -rsn1 -t 0.05 key2 || true
      if [[ $key2 == '[' ]]; then
        key3=''
        IFS= read -rsn1 -t 0.05 key3 || true
        key="[$key3"
      elif [[ -n $key2 ]]; then
        key=$key2
      fi
    fi

    case $key in
      '[A' | k | K) cur=$(((cur - 1 + n) % n)) ;;
      '[B' | j | J) cur=$(((cur + 1) % n)) ;;
      '') chosen=$cur; break ;; # enter
      q | Q | $'\x1b') cancelled=1; break ;;
    esac
  done

  trap - RETURN INT TERM
  tui::_select_tty_restore
  printf '\n'

  TUI_CHOICE=''
  ((cancelled)) && return 1
  TUI_CHOICE=${items[chosen]}
  return 0
}

tui::_select_fallback() {
  local title=$1
  shift
  local -a items=("$@")
  local n=${#items[@]}
  local i line

  TUI_CHOICE=''
  printf '\n%s%s%s\n' "${PVX_C[bold]:-}" "$title" "${PVX_C[reset]:-}"
  for ((i = 0; i < n; i++)); do
    printf '  %2d) %s\n' "$((i + 1))" "${items[i]}"
  done
  printf '  %sdigite o número · q cancela%s\n' "${PVX_C[gray]:-}" "${PVX_C[reset]:-}"

  while true; do
    line=''
    if ! IFS= read -r -p '> ' line; then
      return 1
    fi
    line=$(tui::_trim "$line")
    case $line in
      q | Q | sair | SAIR) return 1 ;;
      *)
        if [[ $line =~ ^[0-9]+$ ]] && ((line >= 1 && line <= n)); then
          # shellcheck disable=SC2034 # lido pelo chamador depois que esta função retorna
          TUI_CHOICE=${items[line - 1]}
          return 0
        fi
        printf '  entrada não reconhecida: %s\n' "$line"
        ;;
    esac
  done
}

# tui::pause [<label>] — pausa depois de uma ação que já imprimiu algo, antes de redesenhar o
# menu que chamou. Uma tecla só, sem precisar de enter: qualquer tecla comum continua
# (TUI_BACK=0); 'q'/'Q'/ESC/Ctrl-C volta (TUI_BACK=1) — o chamador decide o que "voltar" significa
# (tipicamente: sair do loop do submenu atual, um nível pra cima). Sem TTY, cai num modo texto
# por linha (mesma convenção do resto deste arquivo).
tui::pause() {
  local label=${1:-'pressione enter pra continuar (q/esc volta)'}
  TUI_BACK=0

  if [[ ! -t 0 || ! -t 1 ]]; then
    printf '\n%s%s%s\n' "${PVX_C[gray]:-}" "$label" "${PVX_C[reset]:-}"
    local resp=''
    if ! IFS= read -r resp; then
      TUI_BACK=1
      return 0
    fi
    [[ $resp == q || $resp == Q ]] && TUI_BACK=1
    return 0
  fi

  printf '\n%s%s%s' "${PVX_C[gray]:-}" "$label" "${PVX_C[reset]:-}"
  local stty_saved='' key='' key2=''
  stty_saved=$(stty -g 2>/dev/null) || stty_saved=''
  stty -echo -icanon min 1 time 0 2>/dev/null || true

  tui::_pause_restore() {
    [[ -n ${stty_saved:-} ]] && stty "$stty_saved" 2>/dev/null
    return 0
  }
  trap tui::_pause_restore RETURN
  # INT/TERM à parte — ver o comentário equivalente em tui::_select_tty. Ctrl-C aqui é
  # tratado igual a 'q' (TUI_BACK=1), não como falha: tui::pause sempre retorna 0.
  trap 'trap - INT TERM RETURN; tui::_pause_restore; printf "\n"; TUI_BACK=1; return 0' INT TERM

  if ! IFS= read -rsn1 key; then
    key=q
  elif [[ $key == $'\x1b' ]]; then
    key2=''
    IFS= read -rsn1 -t 0.05 key2 || true
    [[ -n $key2 ]] && key=$key2 # era um arrow/outra sequência — ignora, trata como "continuar"
  fi

  trap - RETURN INT TERM
  tui::_pause_restore
  printf '\n'

  case $key in
    q | Q | $'\x1b')
      # shellcheck disable=SC2034 # lido pelo chamador depois que esta função retorna
      TUI_BACK=1
      ;;
  esac
  return 0
}

# tui::input <label> [default] — prompt de texto livre (caminho, URL, etc.). Resultado em
# TUI_INPUT. Linha vazia usa o <default>, se houver; sem default, linha vazia ou EOF (Ctrl-D)
# cancela (rc=1) — não trava esperando teclado num pipe fechado (ex: stdin de /dev/null).
tui::input() {
  local label=$1 default=${2:-}
  local prompt line

  TUI_INPUT=''
  if [[ -n $default ]]; then
    printf -v prompt '%s [%s]: ' "$label" "$default"
  else
    printf -v prompt '%s: ' "$label"
  fi

  line=''
  if ! IFS= read -r -p "$prompt" line; then
    return 1
  fi
  if [[ -z $line ]]; then
    [[ -z $default ]] && return 1
    TUI_INPUT=$default
    return 0
  fi
  # shellcheck disable=SC2034 # lido pelo chamador depois que esta função retorna
  TUI_INPUT=$line
  return 0
}

# tui::checklist <título> <item1> [item2 ...]
tui::checklist() {
  local title=$1
  shift
  local -a items=("$@")
  local n=${#items[@]}

  TUI_RESULT=()
  ((n == 0)) && return 0

  if [[ -t 0 && -t 1 ]]; then
    tui::_checklist_tty "$title" "${items[@]}"
  else
    tui::_checklist_fallback "$title" "${items[@]}"
  fi
}

tui::_checklist_tty() {
  local title=$1
  shift
  local -a items=("$@")
  local n=${#items[@]}
  local -a checked=()
  local i cur=0 mark all_on cursor_char='>'
  local key key2 key3 rows_drawn=0 cancelled=0
  local stty_saved=''

  declare -F color::supports_unicode >/dev/null 2>&1 && color::supports_unicode && cursor_char='❯'

  for ((i = 0; i < n; i++)); do checked[i]=0; done

  stty_saved=$(stty -g 2>/dev/null) || stty_saved=''
  stty -echo -icanon min 1 time 0 2>/dev/null || true

  tui::_checklist_tty_restore() {
    [[ -n ${stty_saved:-} ]] && stty "$stty_saved" 2>/dev/null
    return 0
  }
  trap tui::_checklist_tty_restore RETURN
  # INT/TERM à parte — ver o comentário equivalente em tui::_select_tty.
  trap 'trap - INT TERM RETURN; tui::_checklist_tty_restore; printf "\n"; TUI_RESULT=(); return 1' INT TERM

  while true; do
    if ((rows_drawn > 0)); then
      tput cuu "$rows_drawn" 2>/dev/null || true
    fi
    tput ed 2>/dev/null || true

    printf '%s%s%s\n' "${PVX_C[bold]:-}" "$title" "${PVX_C[reset]:-}"
    for ((i = 0; i < n; i++)); do
      mark=' '
      ((checked[i])) && mark='x'
      if ((i == cur)); then
        printf '  %s%s [%s] %s%s\n' "${PVX_C[cyan]:-}" "$cursor_char" "$mark" "${items[i]}" "${PVX_C[reset]:-}"
      else
        printf '    [%s] %s\n' "$mark" "${items[i]}"
      fi
    done
    printf '  %s↑/↓ (j/k) navega · espaço marca · a marca/desmarca tudo · enter confirma · q cancela%s\n' \
      "${PVX_C[gray]:-}" "${PVX_C[reset]:-}"
    rows_drawn=$((n + 2))

    key=''
    if ! IFS= read -rsn1 key; then
      cancelled=1
      break
    fi

    if [[ $key == $'\x1b' ]]; then
      key2=''
      IFS= read -rsn1 -t 0.05 key2 || true
      if [[ $key2 == '[' ]]; then
        key3=''
        IFS= read -rsn1 -t 0.05 key3 || true
        key="[$key3"
      elif [[ -n $key2 ]]; then
        key=$key2
      fi
    fi

    case $key in
      '[A' | k | K) cur=$(((cur - 1 + n) % n)) ;;
      '[B' | j | J) cur=$(((cur + 1) % n)) ;;
      ' ') checked[cur]=$((1 - checked[cur])) ;;
      a | A)
        all_on=1
        for ((i = 0; i < n; i++)); do
          ((checked[i])) || {
            all_on=0
            break
          }
        done
        for ((i = 0; i < n; i++)); do checked[i]=$((all_on ? 0 : 1)); done
        ;;
      '') break ;; # enter
      q | Q | $'\x1b') cancelled=1; break ;;
    esac
  done

  trap - RETURN INT TERM
  tui::_checklist_tty_restore
  printf '\n'

  TUI_RESULT=()
  if ((cancelled)); then
    return 1
  fi
  for ((i = 0; i < n; i++)); do
    ((checked[i])) && TUI_RESULT+=("${items[i]}")
  done
  return 0
}

tui::_checklist_fallback() {
  local title=$1
  shift
  local -a items=("$@")
  local n=${#items[@]}
  local -a checked=()
  local i mark line tok valid all_on

  for ((i = 0; i < n; i++)); do checked[i]=0; done

  while true; do
    printf '\n%s%s%s\n' "${PVX_C[bold]:-}" "$title" "${PVX_C[reset]:-}"
    for ((i = 0; i < n; i++)); do
      mark=' '
      ((checked[i])) && mark='x'
      printf '  [%s%s%s] %2d) %s\n' "${PVX_C[green]:-}" "$mark" "${PVX_C[reset]:-}" "$((i + 1))" "${items[i]}"
    done
    printf '  %snúmeros marca/desmarca · a=todos · enter/ok confirma · q cancela%s\n' \
      "${PVX_C[gray]:-}" "${PVX_C[reset]:-}"

    line=''
    if ! IFS= read -r -p '> ' line; then
      break
    fi
    line=$(tui::_trim "$line")

    case $line in
      '' | ok | OK | s | S | sim | SIM) break ;;
      q | Q | sair | SAIR)
        TUI_RESULT=()
        return 1
        ;;
      a | A | todos | TODOS)
        all_on=1
        for ((i = 0; i < n; i++)); do
          ((checked[i])) || {
            all_on=0
            break
          }
        done
        for ((i = 0; i < n; i++)); do checked[i]=$((all_on ? 0 : 1)); done
        ;;
      *)
        valid=0
        for tok in $line; do
          if [[ $tok =~ ^[0-9]+$ ]] && ((tok >= 1 && tok <= n)); then
            checked[tok - 1]=$((1 - checked[tok - 1]))
            valid=1
          fi
        done
        ((valid)) || printf '  entrada não reconhecida: %s\n' "$line"
        ;;
    esac
  done

  TUI_RESULT=()
  for ((i = 0; i < n; i++)); do
    ((checked[i])) && TUI_RESULT+=("${items[i]}")
  done
  return 0
}

tui::_trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}
