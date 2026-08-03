# pvx

CLI unificada de suporte técnico Phonevox para centrais Issabel/Asterisk — segurança,
recuperação e utilitários do dia a dia, extensível por módulos.

## Instalação

```bash
sudo ./install.sh
```

Instala em `/opt/pvx/releases/<versão>` com `/opt/pvx/current` symlinkado pra release ativa e
`/usr/local/bin/pvx` apontando pra lá. Rodar de novo (mesma versão ou outra) atualiza sem tocar
em state/config/cache existentes.

## Uso

```bash
pvx                 # sem terminal (ou sem TTY): menu interativo
pvx <comando>       # roda um comando direto
pvx --help          # lista de comandos e opções globais
```

## Comandos principais

| Comando       | O que faz                                                        |
| ------------- | ----------------------------------------------------------------- |
| `modules`     | instala/remove/atualiza módulos (`list/install/remove/update`)     |
| `registry`    | consulta/configura o índice remoto de módulos                     |
| `update`      | atualiza o pvx-core e/ou os módulos instalados (`core\|self`, `modules`) |
| `sysinfo`     | dump read-only de informações do sistema                          |
| `completion`  | gera/instala o autocomplete do bash                                |
| `tests`       | roda a suíte de testes do pvx-core                                 |
| `version`     | mostra a versão instalada                                          |

## Desenvolvimento e testes

O ambiente-alvo é Rocky Linux (Issabel); testes rodam num container, não na máquina de dev:

```bash
docker compose up -d
docker exec -it testrocky bash -c 'cd /opt/issabel-mineracao-src && tests/run all'
```

## Estrutura

```
bin/pvx        dispatcher
lib/           libs compartilhadas (bootstrap, log, exec, registry, self-update, ...)
modules/       módulos instaláveis (ex: dummy, pra desenvolvimento do core)
tests/         suíte de testes (unit + suites)
docker/        ambiente de teste (Rocky Linux)
```
