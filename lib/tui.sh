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

# Rede de segurança pra restaurar o terminal (stty -echo -icanon) mesmo se o trap local de
# INT/TERM de tui::_select_tty/_checklist_tty por algum motivo não rodar até o fim (ex: um
# segundo Ctrl-C chegando durante o próprio handler do primeiro) — sem isto, o terminal do
# operador fica sem eco/canônico pro resto da sessão shell, MESMO depois do processo `pvx` já
# ter terminado (achado de verdade: reproduzido apertando Ctrl-C repetidamente durante um
# tui::select). Mesmo padrão já usado no arquivo pra outros hooks de saída (exec::spinner_stop,
# pvx::_cleanup_tmpdir): estado global + registro único em pvx::on_exit (que SEMPRE roda no
# fim do processo, via `trap 'pvx::_run_exit_hooks' EXIT` — esse trap nunca é tocado pelos
# traps locais de INT/TERM/RETURN daqui).
_PVX_TUI_STTY_SAVED=''
_PVX_TUI_STTY_HOOK_REGISTERED=0

tui::_stty_restore_failsafe() {
  [[ -n $_PVX_TUI_STTY_SAVED ]] && stty "$_PVX_TUI_STTY_SAVED" 2>/dev/null
  return 0
}

# tui::_stty_raw_mode — usado por tui::_select_tty/_checklist_tty/tui::pause: salva o estado
# atual do terminal em _PVX_TUI_STTY_SAVED (pro failsafe) e liga o modo raw (-echo -icanon).
# NUNCA chame via `$(...)`: rodaria a função numa subshell, e as mutações em
# _PVX_TUI_STTY_SAVED/_PVX_TUI_STTY_HOOK_REGISTERED (globais) morreriam com a subshell sem
# nunca chegar no shell principal — mesmo achado de verdade já documentado em bootstrap.sh pra
# pvx::tmpdir/pvx::invocation_id. Chame direto (bare) e leia _PVX_TUI_STTY_SAVED depois.
tui::_stty_raw_mode() {
  _PVX_TUI_STTY_SAVED=$(stty -g 2>/dev/null) || _PVX_TUI_STTY_SAVED=''
  if ((! _PVX_TUI_STTY_HOOK_REGISTERED)); then
    _PVX_TUI_STTY_HOOK_REGISTERED=1
    declare -F pvx::on_exit >/dev/null 2>&1 && pvx::on_exit tui::_stty_restore_failsafe
  fi
  stty -echo -icanon min 1 time 0 2>/dev/null || true
}

# tui::is_interactive — true se stdin E stdout são ambos um terminal de verdade. Mesma checagem
# "[[ -t 0 && -t 1 ]]" que estava duplicada crua em bin/pvx, lib/cmd_modules.sh,
# lib/core/registry.sh, lib/core/completion.sh e em módulos (ex: netinstall) — nomeada aqui só
# pra quem PRECISA decidir ANTES de chamar tui::select/checklist/etc (ex: "abro o submenu ou
# mostro --usage estático?"). As próprias tui::select/checklist/pause continuam fazendo a
# checagem sozinhas por dentro — esta função não muda nada do comportamento delas.
#
# De propósito NÃO usada por lib/exec.sh (exec::confirm, exec::spinner_active) nem por
# lib/flags.sh (flag::_resolve_secret) mesmo essas tendo checagem de TTY parecida — aquelas
# libs são "de baixo nível" (run/srun/qrun, parsing de flag) e não devem ganhar uma dependência
# nova de tui.sh só por causa de uma checagem de 1 linha; cada uma mantém a própria checagem
# crua, com a semântica exata que precisa (ex: exec::spinner_active olha só stderr, não
# stdin+stdout — são perguntas diferentes: "alguém está vendo isto animar" vs "dá pra ler tecla
# E desenhar menu").
tui::is_interactive() {
  [[ -t 0 && -t 1 ]]
}

# tui::breadcrumb [segmento1 segmento2 ...] — monta "HOME > seg1 > ... > segN" pra usar como
# <título> de tui::select/tui::checklist nos submenus do pvx, com o último segmento (a página
# atual) em destaque — sem argumento nenhum, é só "HOME".
tui::breadcrumb() {
  local -a segs=("$@")
  local n=${#segs[@]} i out='pvx'
  for ((i = 0; i < n; i++)); do
    if ((i == n - 1)); then
      out+=" > ${PVX_C[cyan]:-}${segs[i]}${PVX_C[reset]:-}"
    else
      out+=" > ${segs[i]}"
    fi
  done
  printf '%s' "$out"
}

# tui::with_desc <título> [descrição] — junta título + descrição numa string multi-linha pra
# passar como <título> de tui::select/tui::checklist/tui::password (ou como 3º arg opcional de
# tui::input): a 1ª linha (breadcrumb) sai em negrito, a(s) linha(s) seguinte(s) — a descrição —
# em cinza, um nível visual abaixo. Sem <descrição>, devolve só o título puro (retrocompatível
# com todo chamador que já passa só um breadcrumb).
tui::with_desc() {
  local title=$1 desc=${2:-}
  [[ -z $desc ]] && { printf '%s' "$title"; return 0; }
  printf '%s\n%s' "$title" "$desc"
}

# tui::_print_title <título> [prefixo por linha] — usado por tui::select/checklist/password/
# input: imprime a 1ª linha do título (breadcrumb) em negrito, no mesmo estilo/cor de sempre;
# linha(s) seguinte(s) (descrição, se o título vier de tui::with_desc) na cor padrão do
# terminal (nunca em cinza/dim — legibilidade ruim em vários temas de terminal, achado de
# verdade), indentadas 2 espaços igual todo o resto da UI (itens, rodapé de ajuda). Com
# descrição, uma linha em branco depois pra separar "explicação" de "pergunta/interação" —
# sem descrição (título de 1 linha, comportamento de sempre em todo o resto do código),
# nenhuma linha extra.
tui::_print_title() {
  local title=$1 prefix=${2:-} first=1 has_desc=0 tline
  while IFS= read -r tline; do
    if ((first)); then
      printf '%s%s%s%s\n' "$prefix" "${PVX_C[bold]:-}" "$tline" "${PVX_C[reset]:-}"
      first=0
    else
      printf '%s  %s\n' "$prefix" "$tline"
      has_desc=1
    fi
  done <<<"$title"
  # `return 0` explícito: sem descrição, `((has_desc))` (0) seria a última instrução da função
  # e devolveria rc=1 — sob `set -e` (todo o pvx roda assim), UMA chamada solta desta função
  # pra um título de 1 linha só (o caso mais comum, em todo o resto do código) matava o
  # processo inteiro. Achado de verdade: reproduzido em produção logo depois do release.
  ((has_desc)) && printf '%s\n' "$prefix"
  return 0
}

# tui::_title_rows <título> — quantas linhas tui::_print_title vai imprimir pra esse título
# (1 sem descrição; N+1 com descrição de N linhas, já contando a linha em branco extra) — usado
# por tui::_select_tty pra saber quanto `tput cuu` subir no redraw; sem isto, um título com
# descrição desalinha o redraw depois do 1º frame (mesma classe de bug já documentada em
# phonevox_tweaks_menu/tui::checklist).
tui::_title_rows() {
  local title=$1
  # "local a=$1 b=$a" NUM SÓ statement: sob `set -u`, "$title" ainda não existe no escopo
  # desta função enquanto o resto do MESMO `local` é avaliado — só não quebrava até agora por
  # coincidência de nome (todo chamador de hoje também guarda o breadcrumb numa variável
  # local chamada "title", e o escopo dinâmico do bash cai pra ELA em vez de dar erro).
  # Reproduzido de verdade passando um valor por uma variável de OUTRO nome: "title: unbound
  # variable". Precisa de um `local` próprio antes de reusar "$title".
  local rows=1 rest=$title
  while [[ $rest == *$'\n'* ]]; do
    rows=$((rows + 1))
    rest=${rest#*$'\n'}
  done
  ((rows > 1)) && rows=$((rows + 1))
  printf '%d' "$rows"
}

# tui::header <texto> — marca um item de tui::select/tui::_select_fallback como cabeçalho de
# GRUPO: não-selecionável, navegação por seta pula por cima (tui::_select_tty) / não ganha
# número (tui::_select_fallback), renderizado sem cursor/bullet. Usa um byte de controle (SOH,
# "\x01") como sentinela no início da string — nunca aparece em texto normal nem em sequência
# ANSI (que sempre começa em ESC, "\x1b"), então nunca colide com um item de verdade. Pensado
# pra separar visualmente categorias distintas numa lista só (ex: "comandos" / "módulos" /
# "snippets" no menu principal do pvx, ver core::_menu_build_options em bin/pvx) sem precisar
# de N chamadas separadas a tui::select (que perderia a navegação contínua entre grupos).
tui::header() {
  printf '\x01%s' "$1"
}

tui::_is_header() {
  [[ $1 == $'\x01'* ]]
}

# tui::select <título> <item1> [item2 ...]
tui::select() {
  local title=$1
  shift
  local -a items=("$@")
  local n=${#items[@]}

  TUI_CHOICE=''
  ((n == 0)) && return 1

  if tui::is_interactive; then
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
  local i cursor_char='>'
  local key key2 key3 rows_drawn=0 cancelled=0 chosen=-1
  local stty_saved=''

  # posições navegáveis, excluindo cabeçalhos de grupo (tui::header) — pré-computado uma vez,
  # não recalculado a cada tecla. `cur_idx` (estado real do cursor) indexa DENTRO deste array;
  # `cur` (índice em `items`, usado só pra renderizar/escolher) é derivado dele a cada frame.
  local -a selectable=()
  for ((i = 0; i < n; i++)); do
    tui::_is_header "${items[i]}" || selectable+=("$i")
  done
  local m=${#selectable[@]}
  ((m == 0)) && return 1
  local cur_idx=0 cur=${selectable[0]}

  declare -F color::supports_unicode >/dev/null 2>&1 && color::supports_unicode && cursor_char='❯'

  local title_rows
  title_rows=$(tui::_title_rows "$title")

  tui::_stty_raw_mode
  stty_saved=$_PVX_TUI_STTY_SAVED

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

    tui::_print_title "$title"
    for ((i = 0; i < n; i++)); do
      if tui::_is_header "${items[i]}"; then
        printf '  %s%s%s\n' "${PVX_C[bold]:-}" "${items[i]#?}" "${PVX_C[reset]:-}"
      elif ((i == cur)); then
        printf '  %s%s %s%s\n' "${PVX_C[cyan]:-}" "$cursor_char" "${items[i]}" "${PVX_C[reset]:-}"
      else
        printf '    %s\n' "${items[i]}"
      fi
    done
    printf '  %s↑/↓ para navegar · enter para selecionar · esc ou ctrl+c para cancelar%s\n' \
      "${PVX_C[gray]:-}" "${PVX_C[reset]:-}"
    rows_drawn=$((title_rows + n + 1))

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
      '[A' | k | K)
        cur_idx=$(((cur_idx - 1 + m) % m))
        cur=${selectable[cur_idx]}
        ;;
      '[B' | j | J)
        cur_idx=$(((cur_idx + 1) % m))
        cur=${selectable[cur_idx]}
        ;;
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
  printf '\n'
  tui::_print_title "$title"
  # cabeçalhos de grupo (tui::header) não ganham número — a numeração conta só os itens de
  # verdade, então `numbered[k]` mapeia "número exibido k+1" de volta pro índice real em `items`.
  local -a numbered=()
  for ((i = 0; i < n; i++)); do
    if tui::_is_header "${items[i]}"; then
      printf '  %s\n' "${items[i]#?}"
    else
      numbered+=("$i")
      printf '  %2d) %s\n' "${#numbered[@]}" "${items[i]}"
    fi
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
        if [[ $line =~ ^[0-9]+$ ]] && ((line >= 1 && line <= ${#numbered[@]})); then
          # shellcheck disable=SC2034 # lido pelo chamador depois que esta função retorna
          TUI_CHOICE=${items[numbered[line - 1]]}
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
  local label=${1:-'pressione enter pra continuar'}
  TUI_BACK=0

  if ! tui::is_interactive; then
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
  tui::_stty_raw_mode
  stty_saved=$_PVX_TUI_STTY_SAVED

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

# tui::input <label> [default] [título] — prompt de texto livre (caminho, URL, etc.). Resultado
# em TUI_INPUT. Linha vazia usa o <default>, se houver; sem default, linha vazia ou EOF (Ctrl-D)
# cancela (rc=1) — não trava esperando teclado num pipe fechado (ex: stdin de /dev/null).
# <título> opcional (breadcrumb, ou breadcrumb+descrição via tui::with_desc) — mesmo cabeçalho
# de tui::select/checklist/password, pra sub-perguntas não ficarem "soltas" no meio do fluxo.
tui::input() {
  local label=$1 default=${2:-} title=${3:-}
  local prompt line

  TUI_INPUT=''
  [[ -n $title ]] && tui::_print_title "$title" >&2
  if [[ -n $default ]]; then
    printf -v prompt '  %s [%s]: ' "$label" "$default"
  else
    printf -v prompt '  %s: ' "$label"
  fi

  # Ctrl-C aqui é um `read` comum (modo cozido, sem stty pra restaurar) — sem este trap, o
  # trap GLOBAL do processo (pvx::install_traps) mataria o pvx inteiro no meio de um prompt de
  # texto, em vez de só cancelar este input e devolver pro chamador, igual a
  # tui::select/checklist/pause.
  trap 'trap - INT TERM; printf "\n"; TUI_INPUT=""; return 1' INT TERM

  line=''
  if ! IFS= read -r -p "$prompt" line; then
    trap - INT TERM
    return 1
  fi
  trap - INT TERM
  if [[ -z $line ]]; then
    [[ -z $default ]] && return 1
    TUI_INPUT=$default
    return 0
  fi
  # shellcheck disable=SC2034 # lido pelo chamador depois que esta função retorna
  TUI_INPUT=$line
  return 0
}

# tui::password <título> <rótulo> — prompt de senha mascarado (sem eco), com o mesmo cabeçalho
# em negrito de tui::select/tui::checklist (passe um `tui::breadcrumb ...` como título) — pra
# ficar visualmente consistente com o resto dos prompts do menu, em vez de cada chamador
# desenhar o próprio estilo. Resultado em TUI_PASSWORD; nunca ecoado na tela e nunca escrito em
# stdout (só o título/rótulo vão pra stderr) — seguro chamar de dentro de um chamador que usa
# `$(...)` pra capturar OUTRA coisa (ex: netinstall::ask_password decide se gera senha
# aleatória a partir do resultado). Sem TTY em stdin, devolve "" sem perguntar nada.
tui::password() {
  local title=$1 label=$2
  TUI_PASSWORD=''
  [[ -t 0 ]] || return 0

  tui::_print_title "$title" >&2
  printf '  %s: ' "$label" >&2

  # Ctrl-C aqui é um `read` comum (modo cozido) — ver o comentário equivalente em tui::input.
  trap 'trap - INT TERM; printf "\n" >&2; TUI_PASSWORD=""; return 1' INT TERM
  local v=''
  IFS= read -rs v
  trap - INT TERM
  printf '\n' >&2

  TUI_PASSWORD=$v
  return 0
}

# tui::checklist <título> <item1> [item2 ...] — pra pré-marcar itens (ex: opções recomendadas
# já ligadas, o operador só aperta enter pra aceitar), setar o array TUI_CHECKLIST_DEFAULT ANTES
# de chamar, um 0/1 por item na MESMA ORDEM dos itens; item sem entrada correspondente (array
# menor que a lista de itens) ou array não setado = desmarcado, comportamento de sempre. Lido
# só nesta chamada — sempre limpo no final, pra uma chamada seguinte sem setar de novo não
# herdar defaults de uma chamada anterior por engano.
tui::checklist() {
  local title=$1
  shift
  local -a items=("$@")
  local n=${#items[@]}

  TUI_RESULT=()
  ((n == 0)) && return 0

  local _tui_rc=0
  if tui::is_interactive; then
    tui::_checklist_tty "$title" "${items[@]}" || _tui_rc=$?
  else
    tui::_checklist_fallback "$title" "${items[@]}" || _tui_rc=$?
  fi
  TUI_CHECKLIST_DEFAULT=()
  return "$_tui_rc"
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

  local title_rows
  title_rows=$(tui::_title_rows "$title")

  for ((i = 0; i < n; i++)); do
    checked[i]=0
    [[ ${TUI_CHECKLIST_DEFAULT[i]:-0} == 1 ]] && checked[i]=1
  done

  tui::_stty_raw_mode
  stty_saved=$_PVX_TUI_STTY_SAVED

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

    tui::_print_title "$title"
    for ((i = 0; i < n; i++)); do
      mark=' '
      ((checked[i])) && mark='x'
      if ((i == cur)); then
        printf '  %s%s [%s] %s%s\n' "${PVX_C[cyan]:-}" "$cursor_char" "$mark" "${items[i]}" "${PVX_C[reset]:-}"
      else
        printf '    [%s] %s\n' "$mark" "${items[i]}"
      fi
    done
    printf '  %s↑/↓ para navegar · espaço marca · a marca/desmarca tudo · enter para selecionar · esc ou ctrl+c para cancelar%s\n' \
      "${PVX_C[gray]:-}" "${PVX_C[reset]:-}"
    rows_drawn=$((title_rows + n + 1))

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

  for ((i = 0; i < n; i++)); do
    checked[i]=0
    [[ ${TUI_CHECKLIST_DEFAULT[i]:-0} == 1 ]] && checked[i]=1
  done

  while true; do
    printf '\n'
    tui::_print_title "$title"
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
