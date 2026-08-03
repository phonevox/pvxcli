#!/usr/bin/env bash
# lib/exec.sh — execução de comandos com consciência de dry-run, log automático do comando
# renderizado (segredos mascarados), captura opcional de stdout/stderr, retry e timeout.
#
# Três verbos, não dois: `run`/`srun` sozinhos não expressam "consulta que deve sempre
# executar, mesmo em --dry-run" (uma leitura como `rpm -qa` precisa rodar de verdade nesse
# modo, senão qualquer branch downstream que dependa do resultado silenciosamente quebra).
#
#   qrun  — não muta estado (consulta); roda normalmente mesmo em --dry-run
#   run   — muta estado; em --dry-run só loga e retorna 0; rc inaceitável só é reportado
#   srun  — igual a run, mas rc inaceitável aborta o processo (exit)

PVX_RC=0
PVX_OUT=''
PVX_ERR=''
PVX_CMD=''
PVX_DURATION_MS=0

# Normalmente já vêm setados por bin/pvx no boot — defaults próprios aqui pra esta lib não
# quebrar sob `set -u` quando usada de forma standalone (dev de módulo, testes).
PVX_DRY_RUN=${PVX_DRY_RUN:-0}
PVX_ASSUME_YES=${PVX_ASSUME_YES:-0}

_PVX_SECRET_FILES=()
_PVX_SECRET_FILES_HOOK_REGISTERED=0

# --- spinner in-line (estilo npm), API pública reutilizável por qualquer módulo -------------
# Achado de verdade: run/srun/qrun capturam TODA a saída em arquivo e só a "reproduzem" depois
# que o comando termina (ver comentário em exec::_run_impl mais abaixo — não é streaming). Pro
# operador, isso significa tela completamente parada durante um comando demorado (dnf baixando
# de um mirror lento, um scriptlet %post de RPM fazendo algo pesado, etc.), indistinguível de
# "travou". run/srun/qrun já chamam isto sozinhos (ver mais abaixo) — mas qualquer módulo pode
# usar direto ao redor de trabalho que NÃO passa por run/srun/qrun (um loop esperando um
# serviço subir, uma chamada de API, etc.):
#
#   exec::spinner_start 'esperando o Asterisk subir...'
#   until os::service_active asterisk; do sleep 1; done
#   exec::spinner_stop
#
# Só anima quando stderr é um terminal de verdade (nunca polui log em arquivo/pipe/CI) — exige
# nenhum cuidado extra do chamador além de sempre parear start com stop.
PVX_NO_SPINNER=${PVX_NO_SPINNER:-0}
_PVX_SPINNER_PID=''
_PVX_SPINNER_HOOK_REGISTERED=0

exec::spinner_active() {
  (( PVX_NO_SPINNER )) && return 1
  [[ -t 2 ]] || return 1
  return 0
}

exec::spinner_start() {
  # start chamado duas vezes sem stop no meio (ex: chamador esqueceu, ou run() aninhado):
  # encerra o spinner anterior antes de abrir outro, nunca deixa dois escrevendo \r ao mesmo
  # tempo na mesma linha.
  [[ -n $_PVX_SPINNER_PID ]] && exec::spinner_stop
  exec::spinner_active || return 0
  local label=$1
  (( ${#label} > 60 )) && label="${label:0:57}..."
  if (( ! _PVX_SPINNER_HOOK_REGISTERED )); then
    _PVX_SPINNER_HOOK_REGISTERED=1
    # registra o cleanup no exit hook ANTES do primeiro spin: se um Ctrl-C interromper o
    # processo com o spinner ainda ativo, a chamada explícita de spinner_stop lá embaixo nunca
    # roda (o SIGINT corta o fluxo ali mesmo) — o hook de saída é quem garante o cursor de
    # volta e o subprocesso do spinner morto, mesmo nesse caminho.
    pvx::on_exit exec::spinner_stop
  fi
  tput civis 2>/dev/null >&2 || true
  (
    local -a frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    local i=0 start=$SECONDS elapsed
    while true; do
      elapsed=$((SECONDS - start))
      printf '\r%s %s (%ds)\033[K' "${frames[i]}" "$label" "$elapsed" >&2
      i=$(( (i + 1) % ${#frames[@]} ))
      sleep 0.08
    done
  ) &
  _PVX_SPINNER_PID=$!
}

exec::spinner_stop() {
  [[ -n $_PVX_SPINNER_PID ]] || return 0
  kill "$_PVX_SPINNER_PID" 2>/dev/null || true
  wait "$_PVX_SPINNER_PID" 2>/dev/null || true
  _PVX_SPINNER_PID=''
  exec::spinner_active && printf '\r\033[K' >&2
  tput cnorm 2>/dev/null >&2 || true
  return 0
}

# --- renderização do comando para log, com máscara de índices e redação de segredos ----------
exec::_render() {
  local mask_csv=$1
  shift
  local out='' a q idx=0
  for a in "$@"; do
    if [[ ,$mask_csv, == *",$idx,"* ]]; then
      q='***'
    else
      printf -v q '%q' "$a"
    fi
    out+="${out:+ }$q"
    idx=$((idx + 1))
  done
  out=$(log::redact "$out")
  printf '%s' "$out"
}

exec::_rc_ok() {
  local rc=$1 csv=$2 code
  local -a codes
  IFS=',' read -ra codes <<<"$csv"
  for code in ${codes[@]+"${codes[@]}"}; do
    [[ $rc == "$code" ]] && return 0
  done
  return 1
}

exec::_with_timeout() {
  local timeout=$1
  shift
  if [[ -n $timeout ]] && command -v timeout >/dev/null 2>&1; then
    timeout --foreground -k 5 "$timeout" "$@"
  elif [[ -n $timeout ]] && command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k 5 "$timeout" "$@"
  else
    "$@"
  fi
}

# --- núcleo compartilhado pelos três verbos ----------------------------------------------------
exec::_run_impl() {
  local mutates=$1 fatal_on_bad_rc=$2
  shift 2
  local ok_csv='0' timeout='' retry=0 retry_delay=1 cwd='' capture=0 mask='' label=''
  while (( $# )); do
    case $1 in
      --ok) ok_csv=${2:-0}; shift 2 ;;
      --timeout) timeout=${2:-}; shift 2 ;;
      --retry) retry=${2:-0}; shift 2 ;;
      --retry-delay) retry_delay=${2:-1}; shift 2 ;;
      --cwd) cwd=${2:-}; shift 2 ;;
      --capture) capture=1; shift ;;
      --mask) mask=${2:-}; shift 2 ;;
      --label) label=${2:-}; shift 2 ;;
      --)
        shift
        break
        ;;
      *) break ;;
    esac
  done

  PVX_CMD=$(exec::_render "$mask" "$@")
  local desc=${label:-$PVX_CMD}

  if (( mutates )) && (( PVX_DRY_RUN )); then
    log::info '[dry-run] $ %s' "$PVX_CMD"
    PVX_RC=0
    PVX_OUT=''
    PVX_ERR=''
    PVX_DURATION_MS=0
    return 0
  fi

  log::debug '$ %s' "$PVX_CMD"

  local out_file err_file
  out_file="$(pvx::tmpdir)/exec-out.$$.$RANDOM"
  err_file="$(pvx::tmpdir)/exec-err.$$.$RANDOM"

  local start_raw='' end_raw=''
  read -r start_raw _ 2>/dev/null </proc/uptime || start_raw=''

  local attempt=0 rc=0
  while true; do
    attempt=$((attempt + 1))
    : >"$out_file"
    : >"$err_file"
    # Roda em BACKGROUND (+ wait), não em primeiro plano direto, por dois motivos: (1) dá pro
    # spinner animar enquanto o comando real roda, sem competir pelo mesmo terminal — o
    # spinner escreve \r direto em stderr, o comando real vai pros arquivos de captura; (2)
    # ACHADO DE VERDADE, o motivo mais importante: bin/pvx roda inteiro sob `set -e`. Um
    # comando de primeiro plano solto (`cmd; rc=$?`, sem `&&`/`||` na mesma linha) que retorna
    # != 0 dispara o errexit IMEDIATAMENTE ali, matando o processo `pvx` INTEIRO antes mesmo de
    # chegar no `rc=$?` — nenhum log::error, nenhum "-> rc=", nenhuma linha de stderr, nada:
    # exatamente o "kickout" silencioso mesmo com --debug que motivou essa revisão. E como
    # praticamente toda chamada de `run --`/`srun --` no repo inteiro (núcleo + módulos) é
    # solta, sem `|| true` no fim, QUALQUER comando que falhasse matava o pvx inteiro sem
    # aviso — não só o dnf gigante do netinstall. `cmd & wait "$pid" && rc=0 || rc=$?` blinda
    # isso: por estar dentro de uma lista `&&`/`||`, o bash NUNCA conta essa falha pro errexit,
    # não importa o que aconteça dentro do comando (documentado no bash: falha de um comando
    # cujo resultado está sendo testado por &&/||/if/while nunca dispara o -e).
    exec::spinner_start "$desc"
    if [[ -n $cwd ]]; then
      (cd "$cwd" && exec::_with_timeout "$timeout" "$@" >"$out_file" 2>"$err_file") &
    else
      exec::_with_timeout "$timeout" "$@" >"$out_file" 2>"$err_file" &
    fi
    local cmd_pid=$!
    wait "$cmd_pid" && rc=0 || rc=$?
    exec::spinner_stop
    exec::_rc_ok "$rc" "$ok_csv" && break
    (( attempt > retry )) && break
    log::warn 'comando falhou (rc=%d), tentativa %d/%d — %s' "$rc" "$attempt" "$((retry + 1))" "$desc"
    sleep "$retry_delay" 2>/dev/null || true
  done

  read -r end_raw _ 2>/dev/null </proc/uptime || end_raw=''
  if [[ $start_raw == *.* && $end_raw == *.* ]]; then
    local start_cs=${start_raw/./} end_cs=${end_raw/./}
    PVX_DURATION_MS=$(((10#$end_cs - 10#$start_cs) * 10))
  else
    PVX_DURATION_MS=0
  fi

  # Nota: stdout/stderr são sempre capturados em arquivo (pra poder mostrar as últimas linhas
  # de stderr em caso de falha, independente de --capture); em modo não-capture, o conteúdo é
  # "reproduzido" nos streams reais depois que o comando termina — não é streaming em tempo
  # real. Aceito nesta passada em nome da simplicidade/corretude.
  if (( capture )); then
    PVX_OUT=$(<"$out_file")
    PVX_ERR=$(<"$err_file")
  else
    cat "$out_file"
    cat "$err_file" >&2
    PVX_OUT=''
    PVX_ERR=$(<"$err_file")
  fi
  rm -f "$out_file" "$err_file"
  PVX_RC=$rc

  if exec::_rc_ok "$rc" "$ok_csv"; then
    log::debug '  -> rc=%d (%dms)' "$rc" "$PVX_DURATION_MS"
  else
    log::error 'comando falhou: %s (rc=%d, %dms)' "$desc" "$rc" "$PVX_DURATION_MS"
    local tail_err
    tail_err=$(printf '%s' "$PVX_ERR" | tail -n 10)
    [[ -n $tail_err ]] && log::error 'stderr (últimas linhas):%s%s' $'\n' "$tail_err"
    if (( fatal_on_bad_rc )); then
      exit "$rc"
    fi
  fi

  return "$rc"
}

qrun() { exec::_run_impl 0 0 "$@"; }
run() { exec::_run_impl 1 0 "$@"; }
srun() { exec::_run_impl 1 1 "$@"; }

# --- utilidades de comando/segredo --------------------------------------------------------------
exec::has_cmd() { command -v "$1" >/dev/null 2>&1; }

exec::require_cmd() {
  local cmd hint mgr
  for cmd in "$@"; do
    exec::has_cmd "$cmd" && continue
    hint=''
    if declare -F os::pkg_manager >/dev/null 2>&1; then
      mgr=$(os::pkg_manager 2>/dev/null) || mgr=''
      [[ -n $mgr ]] && hint=" (tente: $mgr install $cmd)"
    fi
    log::error 'comando necessário não encontrado: %s%s' "$cmd" "$hint"
    return "$PVX_EXIT_UNAVAILABLE"
  done
  return 0
}

# Passa um segredo só via ambiente de um processo filho — nunca em argv (visível via `ps`).
# Roda em subshell + exec: nem o segredo nem o processo filho vazam pro shell chamador.
exec::with_env_secret() {
  local var=$1 value=$2
  shift 2
  log::add_secret "$value"
  (
    export "$var=$value"
    exec "$@"
  )
}

exec::_shred_secret_files() {
  local f
  for f in ${_PVX_SECRET_FILES[@]+"${_PVX_SECRET_FILES[@]}"}; do
    [[ -f $f ]] || continue
    if command -v shred >/dev/null 2>&1; then
      shred -u -- "$f" 2>/dev/null || rm -f -- "$f"
    else
      rm -f -- "$f"
    fi
  done
  return 0
}

# Correção concreta do achado "senha de banco visível via ps": nunca `-p<senha>` em argv.
exec::mysql_defaults_file() {
  local user=$1 pass=$2
  local dir file
  dir=$(pvx::tmpdir)
  file="$dir/mysql-defaults-$$-$RANDOM.cnf"
  {
    printf '[client]\n'
    printf 'user=%s\n' "$user"
    printf 'password=%s\n' "$pass"
  } >"$file"
  chmod 0600 "$file"
  log::add_secret "$pass"
  _PVX_SECRET_FILES+=("$file")
  if (( ! _PVX_SECRET_FILES_HOOK_REGISTERED )); then
    _PVX_SECRET_FILES_HOOK_REGISTERED=1
    pvx::on_exit exec::_shred_secret_files
  fi
  printf '%s\n' "$file"
}

# Nunca trava sob cron/non-TTY: honra PVX_ASSUME_YES e, sem TTY, cai no default sem bloquear.
exec::confirm() {
  local prompt=$1 default=${2:-n}
  (( PVX_ASSUME_YES )) && return 0
  if [[ ! -t 0 || ! -t 1 ]]; then
    [[ $default == y ]] && return 0
    return 1
  fi
  local ans=''
  # NÃO usar "read -p": o bash escreve esse prompt em STDERR, não stdout (ver `man bash`) — um
  # "2>/dev/null" na mesma chamada (pensado só como blindagem caso /dev/tty falhe) apagava o
  # prompt inteiro junto. A confirmação ficava invisível e parecia "cancelar sozinha": o
  # usuário via só a tela de antes, apertava enter (respondendo "" a uma pergunta que nunca
  # viu) e caía no default 'n' — achado de verdade em `pvx modules remove`, reproduzido com
  # `script` (pty real) confirmando que o prompt nunca aparecia na sessão.
  printf '%s ' "$prompt"
  IFS= read -r ans </dev/tty 2>/dev/null || ans=$default
  [[ -z $ans ]] && ans=$default
  case $ans in
    y | Y | yes | s | S | sim) return 0 ;;
    *) return 1 ;;
  esac
}

# Retry genérico com backoff exponencial pra comandos fora do fluxo run/srun/qrun (ex: net::fetch).
exec::retry() {
  local n=$1 delay=$2
  shift 2
  local attempt=0 rc=0
  while true; do
    attempt=$((attempt + 1))
    # `&& rc=0 || rc=$?`, não `"$@"; rc=$?`: sob `set -e` (bin/pvx roda assim), um comando
    # solto que falha dispara o errexit ali mesmo, matando o processo inteiro ANTES de tentar
    # de novo — destrutiria o propósito inteiro do retry na primeira tentativa ruim. Mesmo
    # achado do loop principal em exec::_run_impl (ver comentário lá).
    "$@" && rc=0 || rc=$?
    (( rc == 0 )) && return 0
    (( attempt > n )) && return "$rc"
    sleep "$delay" 2>/dev/null || true
    delay=$((delay * 2))
  done
}
