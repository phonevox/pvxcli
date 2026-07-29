#!/usr/bin/env bash
# tests/lib/menu.sh — menu de seleção múltipla (checklist) em bash puro, pra uso interativo
# do tests/run. Sem `declare -n`/`local -n` de propósito — o pvx-core tem piso de bash 4.2
# (nameref só existe a partir do 4.3); em vez disso os "helpers" internos enxergam as
# variáveis locais do chamador via escopo dinâmico do bash (uma função vê os `local` de quem
# a chamou, contanto que não redeclare o mesmo nome).

# menu::checklist <título> <item1> [item2 ...]
# Navega com ↑/↓ (ou j/k), espaço marca/desmarca o item atual, 'a' marca/desmarca tudo,
# enter confirma, 'q'/ESC cancela. Assume o terminal inteiro enquanto está aberto (modo raw).
# Resultado fica no array global MENU_RESULT (na mesma ordem dos itens recebidos). Devolve
# rc=1 se o usuário cancelou (MENU_RESULT fica vazio nesse caso); rc=0 caso contrário — mesmo
# que a seleção final esteja vazia por escolha do usuário.
#
# Sem TTY em stdin/stdout (ex: chamado a partir de um pipe) cai pro modo texto: lista os itens
# numerados e lê uma linha por vez (números pra alternar, "a" p/ todos, vazio/"ok" confirma,
# "q" cancela) — útil também pra testar o próprio runner sem terminal interativo.
menu::checklist() {
  local title=$1
  shift
  local -a items=("$@")
  local n=${#items[@]}

  MENU_RESULT=()
  (( n == 0 )) && return 0

  if [[ -t 0 && -t 1 ]]; then
    menu::_checklist_tty "$title" "${items[@]}"
  else
    menu::_checklist_fallback "$title" "${items[@]}"
  fi
}

menu::_checklist_tty() {
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

  menu::_checklist_tty_restore() {
    [[ -n ${stty_saved:-} ]] && stty "$stty_saved" 2>/dev/null
    return 0
  }
  trap menu::_checklist_tty_restore RETURN INT TERM

  while true; do
    if (( rows_drawn > 0 )); then
      tput cuu "$rows_drawn" 2>/dev/null || true
    fi
    tput ed 2>/dev/null || true

    printf '%s%s%s\n' "${PVX_C[bold]:-}" "$title" "${PVX_C[reset]:-}"
    for ((i = 0; i < n; i++)); do
      mark=' '
      (( checked[i] )) && mark='x'
      if (( i == cur )); then
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
      # key2 vazio (timeout) => ESC puro, `key` continua $'\x1b'
    fi

    case $key in
      '[A' | k | K) cur=$(( (cur - 1 + n) % n )) ;;
      '[B' | j | J) cur=$(( (cur + 1) % n )) ;;
      ' ') checked[cur]=$(( 1 - checked[cur] )) ;;
      a | A)
        all_on=1
        for ((i = 0; i < n; i++)); do
          (( checked[i] )) || { all_on=0; break; }
        done
        for ((i = 0; i < n; i++)); do checked[i]=$(( all_on ? 0 : 1 )); done
        ;;
      '') break ;; # enter
      q | Q | $'\x1b') cancelled=1; break ;;
    esac
  done

  trap - RETURN INT TERM
  menu::_checklist_tty_restore
  printf '\n'

  MENU_RESULT=()
  if (( cancelled )); then
    return 1
  fi
  for ((i = 0; i < n; i++)); do
    (( checked[i] )) && MENU_RESULT+=("${items[i]}")
  done
  return 0
}

# menu::select <título> <item1> [item2 ...]
# Seleção única, estilo "entrar na pasta": navega com ↑/↓ (ou j/k), enter escolhe o item atual
# na hora (sem marcação prévia). 'q'/ESC cancela. Resultado fica na variável global
# MENU_CHOICE. Devolve rc=1 se cancelado (MENU_CHOICE fica vazio nesse caso).
menu::select() {
  local title=$1
  shift
  local -a items=("$@")
  local n=${#items[@]}

  MENU_CHOICE=''
  (( n == 0 )) && return 1

  if [[ -t 0 && -t 1 ]]; then
    menu::_select_tty "$title" "${items[@]}"
  else
    menu::_select_fallback "$title" "${items[@]}"
  fi
}

menu::_select_tty() {
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

  menu::_select_tty_restore() {
    [[ -n ${stty_saved:-} ]] && stty "$stty_saved" 2>/dev/null
    return 0
  }
  trap menu::_select_tty_restore RETURN INT TERM

  while true; do
    if (( rows_drawn > 0 )); then
      tput cuu "$rows_drawn" 2>/dev/null || true
    fi
    tput ed 2>/dev/null || true

    printf '%s%s%s\n' "${PVX_C[bold]:-}" "$title" "${PVX_C[reset]:-}"
    for ((i = 0; i < n; i++)); do
      if (( i == cur )); then
        printf '  %s%s %s%s\n' "${PVX_C[cyan]:-}" "$cursor_char" "${items[i]}" "${PVX_C[reset]:-}"
      else
        printf '    %s\n' "${items[i]}"
      fi
    done
    printf '  %s↑/↓ (j/k) navega · enter entra · q cancela%s\n' "${PVX_C[gray]:-}" "${PVX_C[reset]:-}"
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
      '[A' | k | K) cur=$(( (cur - 1 + n) % n )) ;;
      '[B' | j | J) cur=$(( (cur + 1) % n )) ;;
      '') chosen=$cur; break ;; # enter
      q | Q | $'\x1b') cancelled=1; break ;;
    esac
  done

  trap - RETURN INT TERM
  menu::_select_tty_restore
  printf '\n'

  MENU_CHOICE=''
  (( cancelled )) && return 1
  MENU_CHOICE=${items[chosen]}
  return 0
}

menu::_select_fallback() {
  local title=$1
  shift
  local -a items=("$@")
  local n=${#items[@]}
  local i line

  MENU_CHOICE=''
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
    line=$(menu::_trim "$line")
    case $line in
      q | Q | sair | SAIR) return 1 ;;
      *)
        if [[ $line =~ ^[0-9]+$ ]] && (( line >= 1 && line <= n )); then
          MENU_CHOICE=${items[line - 1]}
          return 0
        fi
        printf '  entrada não reconhecida: %s\n' "$line"
        ;;
    esac
  done
}

menu::_checklist_fallback() {
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
      (( checked[i] )) && mark='x'
      printf '  [%s%s%s] %2d) %s\n' "${PVX_C[green]:-}" "$mark" "${PVX_C[reset]:-}" "$((i + 1))" "${items[i]}"
    done
    printf '  %snúmeros marca/desmarca · a=todos · enter/ok confirma · q cancela%s\n' \
      "${PVX_C[gray]:-}" "${PVX_C[reset]:-}"

    line=''
    if ! IFS= read -r -p '> ' line; then
      break
    fi
    line=$(menu::_trim "$line")

    case $line in
      '' | ok | OK | s | S | sim | SIM) break ;;
      q | Q | sair | SAIR) MENU_RESULT=(); return 1 ;;
      a | A | todos | TODOS)
        all_on=1
        for ((i = 0; i < n; i++)); do
          (( checked[i] )) || { all_on=0; break; }
        done
        for ((i = 0; i < n; i++)); do checked[i]=$(( all_on ? 0 : 1 )); done
        ;;
      *)
        valid=0
        for tok in $line; do
          if [[ $tok =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= n )); then
            checked[tok - 1]=$(( 1 - checked[tok - 1] ))
            valid=1
          fi
        done
        (( valid )) || printf '  entrada não reconhecida: %s\n' "$line"
        ;;
    esac
  done

  MENU_RESULT=()
  for ((i = 0; i < n; i++)); do
    (( checked[i] )) && MENU_RESULT+=("${items[i]}")
  done
  return 0
}

menu::_trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}
