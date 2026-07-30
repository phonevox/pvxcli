#!/usr/bin/env bash
# lib/core/tests.sh — `pvx tests`: camada fina sobre tests/run (não reimplementa descoberta
# nem execução de teste nenhuma — só traduz a forma de comando pro padrão do resto do pvx e,
# no menu interativo, delega pro próprio menu que tests/run já tem).
core::cmd_tests() {
  local runner="$PVX_ROOT/tests/run"
  if [[ ! -x $runner ]]; then
    # install.sh copia tests/ de propósito (ver o comentário lá) — "pvx tests" é ferramenta de
    # diagnóstico da própria central, não só de desenvolvimento do pvx-core, então precisa
    # continuar funcionando depois de instalado. Só chega aqui num release antigo (de antes
    # disso) ou numa instalação manual/incompleta que não seguiu o install.sh.
    log::error 'tests/ ausente nesta instalação (%s) — release antigo ou instalação incompleta; reinstale com uma versão mais nova do pvx-core' \
      "$PVX_ROOT"
    return "$PVX_EXIT_UNAVAILABLE"
  fi

  # bin/pvx já exportou PVX_STATE_DIR/PVX_CACHE_DIR/PVX_ETC_DIR/PVX_MODULES_DIR (e
  # PVX_ROOT_PREFIX) pro ambiente de quem chamou "pvx tests" — mas lib/registry.sh e
  # lib/paths.sh só preenchem essas variáveis com `${VAR:-default}`, então, se já estiverem
  # setadas (herdadas), tests/run e o que ele roda (ex: suites/smoke.sh, que monta o próprio
  # sandbox via PVX_ROOT_PREFIX) NUNCA recalculariam o valor certo — ficariam presos nos
  # caminhos REAIS do sistema, vazando estado de fora pra dentro do teste. Achado de verdade
  # rodando `pvx tests run all` numa central com o pvx instalado: suites/smoke.sh escrevia
  # (e lia) em /var/lib/pvx real em vez do sandbox isolado dele. Limpa aqui — cada teste
  # recomeça do zero e decide seu próprio isolamento (ou a falta dele) sozinho.
  unset PVX_ROOT_PREFIX PVX_STATE_DIR PVX_CACHE_DIR PVX_ETC_DIR PVX_MODULES_DIR

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
