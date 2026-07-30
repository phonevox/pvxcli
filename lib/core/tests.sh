#!/usr/bin/env bash
# lib/core/tests.sh — `pvx tests`: camada fina sobre tests/run (não reimplementa descoberta
# nem execução de teste nenhuma — só traduz a forma de comando pro padrão do resto do pvx e,
# no menu interativo, delega pro próprio menu que tests/run já tem).
core::cmd_tests() {
  local runner="$PVX_ROOT/tests/run"
  if [[ ! -x $runner ]]; then
    # tests/ é excluído de propósito de qualquer instalação via install.sh (só faz sentido num
    # checkout de dev) — não é uma instalação quebrada, é o comportamento esperado de uma
    # central com o pvx instalado normalmente. Ver o comentário equivalente em install.sh.
    log::error '"pvx tests" só está disponível rodando a partir de um checkout de desenvolvimento (tests/ não é copiado numa instalação via install.sh)'
    return "$PVX_EXIT_UNAVAILABLE"
  fi

  local sub=${1:-}
  case $sub in
    '' | -h | --help)
      "$runner" "$@"
      ;;
    list)
      "$runner" --list
      ;;
    run)
      shift
      local kind=${1:-}
      case $kind in
        '')
          "$runner"
          ;;
        all)
          "$runner" all
          ;;
        units)
          shift
          "$runner" units "$@"
          ;;
        suites)
          shift
          "$runner" suites "$@"
          ;;
        *)
          log::error 'tests run: argumento desconhecido: %s' "$kind"
          core::_tests_usage >&2
          return "$PVX_EXIT_USAGE"
          ;;
      esac
      ;;
    *)
      log::error 'tests: subcomando desconhecido: %s' "$sub"
      core::_tests_usage >&2
      return "$PVX_EXIT_USAGE"
      ;;
  esac
}

core::_tests_usage() {
  cat <<'EOF'
uso: pvx tests <subcomando> [args...]

subcomandos:
  list                     lista as suites e units de teste descobertas
  run all                  roda todas as suites + todos os units
  run units [nome...]      roda units específicos (ou todos, se nenhum nome for dado)
  run suites [nome...]     roda suites específicas (ou todas, se nenhuma for dada)

sem subcomando, num terminal interativo, "pvx tests" abre o menu de seleção do próprio
tests/run (categoria -> checklist de quais rodar).
EOF
}
