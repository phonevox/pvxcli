# Desenvolvimento de módulos e snippets pro pvx

Guia completo pra quem vai criar um módulo (ou um snippet) pro `pvx`. Cobre a arquitetura por
trás do dispatcher, organização de repositório, `module.json`, hooks, as libs compartilhadas
(com destaque pra TUI e spinner), como o registry funciona, empacotamento e testes. Pensado pra
quem nunca mexeu no pvx-core conseguir sair daqui com um módulo funcionando — fique à vontade
pra pular direto pra seção que precisar, cada uma tenta ser o mais autocontida possível.

> **Regra de ouro**: qualquer coisa que dependa de terminal de verdade (TUI, prompt de senha,
> spinner, cor) só pode ser validada num ambiente Linux de verdade, com um terminal real (SSH,
> console, ou um container que reproduza o alvo). Rodar os testes na sua máquina de
> desenvolvimento é um sanity check rápido, não validação.

## Índice

1. [Modelo mental em 5 minutos](#1-modelo-mental-em-5-minutos)
2. [Módulo ou snippet? Qual escolher](#2-módulo-ou-snippet-qual-escolher)
3. [Anatomia de um módulo](#3-anatomia-de-um-módulo)
4. [`module.json` — schema comentado](#4-modulejson--schema-comentado)
5. [O contrato do entrypoint](#5-o-contrato-do-entrypoint)
6. [Hooks: install/update/uninstall/logs](#6-hooks-installupdateuninstalllogs)
7. [Tour pelas libs compartilhadas](#7-tour-pelas-libs-compartilhadas)
8. [Como o registry funciona](#8-como-o-registry-funciona)
9. [Empacotando um módulo](#9-empacotando-um-módulo)
10. [Testando](#10-testando)
11. [Ciclo de vida completo, do zero à instalação](#11-ciclo-de-vida-completo-do-zero-à-instalação)
12. [Snippets em detalhe](#12-snippets-em-detalhe)
13. [Checklist de boas práticas / armadilhas conhecidas](#13-checklist-de-boas-práticas--armadilhas-conhecidas)
14. [Exemplo prático: um módulo "hello" do zero](#14-exemplo-prático-um-módulo-hello-do-zero)

---

## 1. Modelo mental em 5 minutos

`bin/pvx` é um **dispatcher**. Quando você roda `pvx <comando> [args...]`, ele não sabe de
antemão o que `<comando>` significa — ele pergunta, em ordem, pra uma lista de "resolvers", até
um responder "eu sei resolver isso":

```
core::resolve      -> comandos embutidos no core (modules, registry, tests, update, help...)
registry::resolve  -> módulo instalado (existe um symlink em $PVX_STATE_DIR/commands/<cmd>)
snippet::resolve   -> arquivo único em share/pvx/snippets/<cmd>.sh
```

Cada um resolve pra um "tipo" (`core`, `module` ou `snippet`) + um alvo, e o dispatcher trata os
três de formas ligeiramente diferentes:

| tipo | como roda | processo | quando usar |
|---|---|---|---|
| `core` | chama uma função Bash do próprio core | mesmo processo do `pvx` | nunca — é só pro próprio core |
| `module` | executa o entrypoint via symlink (`$PVX_STATE_DIR/commands/<cmd>` → `.../modules/<nome>/bin/pvx-<nome>`) | processo filho novo | ferramenta com estado próprio, hooks de instalação, várias ações, potencialmente `requires_root` |
| `snippet` | dá `source` no arquivo e chama `snippet::<nome>::main` | mesmo processo do `pvx` (in-process) | comando pequeno, single-file, read-only ou quase, sem necessidade de state/hooks/versão própria |

O resto deste guia é focado em **módulo**, que é o caso mais rico (tem ciclo de vida de
instalação, hooks, versão, registry) — a seção 2 detalha quando usar cada um.

Um módulo instalado nunca roda "sozinho": o dispatcher sempre injeta `PVX_LIB_DIR` (aponta pra
`lib/` do pvx-core instalado) antes de chamar o entrypoint, e o entrypoint sempre começa dando
`source` no `bootstrap.sh` de lá. É o mesmo modelo de um plugin de WordPress chamando função de
`wp-includes`, ou um plugin de oh-my-zsh dando `source` no framework — o módulo é código que
roda **dentro** da "casca" do pvx-core, nunca isolado.

## 2. Módulo ou snippet? Qual escolher

| | Módulo | Snippet |
|---|---|---|
| onde vive | repositório git próprio, fora do `pvxcli` | um arquivo único dentro do próprio `pvxcli`, em `share/pvx/snippets/` |
| processo | subprocesso (novo `bash`, via shebang) | in-process (sourced pelo próprio `pvx`) |
| versão própria | sim (`module.json`, comparada no update) | não — vive e evolui junto do pvx-core |
| hooks de instalação | sim (install/update/uninstall/logs) | não existe conceito de instalação |
| state próprio (`$PVX_STATE_DIR/state/<nome>/`) | sim, opcional (`state_dir: true`) | não |
| pode exigir root | sim (`requires_root` no `module.json`) | tecnicamente sim, mas não há contrato — evite |
| instalado por | `pvx modules install ...` | já vem no checkout/instalação do core |
| bom pra | ferramentas com lógica de verdade, múltiplas ações, coisa que muda de versão sozinha (ex: `netinstall`, um scanner de segurança) | dump read-only rápido, comando de 1 arquivo que não precisa de ciclo de vida (ex: `sysinfo`) |

Regra prática: se o script que você quer portar tem mais de ~100 linhas, tem estado próprio, ou
algum dia vai precisar de uma versão 2.0 independente do resto do pvx, é módulo. Se é
essencialmente "um dump de informação" ou uma ação pontual sem necessidade de instalação
separada, é snippet — olhe `share/pvx/snippets/sysinfo.sh` como referência real (seção 12 entra
em detalhe).

## 3. Anatomia de um módulo

```
pvx-mod-<nome>/                  <- nome do REPOSITÓRIO
├── module.json                  <- obrigatório — metadado + contrato de instalação
├── README.md                    <- obrigatório — "isto é um módulo do pvx, não roda sozinho"
├── bin/
│   └── pvx-<nome>                <- obrigatório — entrypoint (module.json aponta pra ele em "entrypoint")
├── hooks/                        <- opcionais — install/update/uninstall/logs
│   ├── install
│   ├── update
│   └── uninstall
├── lib/                          <- opcional — libs EXCLUSIVAS deste módulo (nunca vendoriza core lib aqui)
│   └── common.sh
├── config/                       <- opcional — arquivos-modelo (ver "config_files" no module.json)
├── docs/                         <- opcional — specs/decisões de design do próprio módulo
└── tests/                        <- opcional, mas fortemente recomendado
    └── unit.sh
```

Isso é exatamente o layout de `modules/netinstall/` (o módulo real mais complexo do projeto
hoje) e uma versão maior de `modules/dummy/` (o fixture mínimo usado pelos testes do próprio
core). Nenhuma dessas pastas além de `bin/` e `module.json` é imposta por código — são convenção
— mas seguir esse layout é o que faz `tools/pack-module.sh` e o resto da toolchain funcionarem
sem configuração extra.

Um detalhe que costuma confundir quem olha o repositório de um módulo pela primeira vez: ele
"parece quebrado" isolado — `bin/pvx-<nome>` referencia `$PVX_LIB_DIR/bootstrap.sh`, que não
existe dentro do próprio repositório do módulo. **Isso é esperado**, não bug (ver seção 5). É
por isso que o `README.md` do módulo precisa deixar isso explícito por escrito: *"isto é um
módulo do pvx, não roda sozinho — requer pvx-core `>=X` instalado, instale com `pvx modules
install <url deste repo>`"*, com link pro repositório `pvxcli`.

### Nomenclatura: repositório ≠ comando

Duas camadas, não confundir:

| camada | onde vive | regra | exemplo |
|---|---|---|---|
| nome do **repositório** | GitHub | `pvx-mod-<nome>` | `pvx-mod-qint` |
| nome do **módulo/comando** | `module.json` (`.name`/`.command`) | `^[a-z][a-z0-9-]{1,31}$` | `qint` → `pvx qint ...` |

O prefixo `pvx-mod-` no nome do repo é o mesmo que `tools/pack-module.sh` já gera sozinho pro
artefato (`pvx-mod-<nome>-<versão>.tar.gz`) — usar o mesmo prefixo evita ter duas convenções de
nome pro mesmo módulo. O nome curto (sem prefixo) fica só dentro do `module.json`, porque é o
que vira comando digitado pelo usuário.

### Por que módulo = 1 repositório, nunca um monorepo com vários módulos

`pvx modules install <url-git>` clona o repositório inteiro e trata a raiz clonada como a raiz
do módulo — não existe extração de subdiretório nem sparse-checkout no instalador de hoje. O
caminho de tarball (`install --file`) tem a mesma exigência: o pacote precisa ter exatamente 1
diretório de topo. Então: um módulo, um repositório. Se algum dia um monorepo com vários módulos
for necessário, é trabalho novo (suporte a subdiretório no instalador) — não assuma que já
funciona. `modules/dummy`, dentro do próprio `pvxcli`, é a única exceção — é fixture de teste do
core (os smoke tests dependem dele), não o padrão pra módulos de produto de verdade.

### Dev local sem publicar a cada iteração

Clonar/desenvolver o módulo dentro de `modules/<nome>/` no checkout do `pvxcli` funciona bem pra
iterar — `.gitignore` já exclui `/modules/*` (exceto `dummy`), então não polui `git status` nem
corre o risco de um `git add -A` engolir os arquivos do módulo como se fossem do core. **Não é
git submodule, de propósito**: o `pvxcli` nunca precisa fixar um commit do módulo pra nada
(build, teste do core) — módulos são instalados em runtime nas centrais, um clone local solto e
ignorado é mais simples de gerenciar. Loop de teste, sem tocar em rede/GitHub a cada mudança:

```bash
tools/pack-module.sh modules/<nome>            # gera dist/pvx-mod-<nome>-<versão>.tar.gz
pvx modules install --file dist/pvx-mod-<nome>-<versão>.tar.gz --force
```

## 4. `module.json` — schema comentado

```jsonc
{
  "schema_version": 1,                 // obrigatório, tem que ser 1
  "name": "netinstall",                // ^[a-z][a-z0-9-]{1,31}$ — identidade no registry/state
  "command": "netinstall",             // mesma regra; é o que o usuário digita: `pvx <command>`
  "version": "0.6.2",                  // semver-like: N.N.N + sufixo -alpha.1 opcional
  "summary": "Instalação netinstall (des)assistida do Issabel 4/5",
  "description": "texto mais longo, usado em listagens/help",
  "entrypoint": "bin/pvx-netinstall",  // caminho relativo — nunca absoluto, nunca com ".."
  "requires_root": true,               // dispatcher checa ANTES de rodar; o módulo AINDA deve checar sozinho
  "hooks": {
    "install": "hooks/install",
    "uninstall": "hooks/uninstall",
    "update": "hooks/update",
    "logs": null                       // null/ausente = hook não existe
  },
  "requires": {
    "pvx_core": ">=0.1.7",             // contrato de versão mínima do CORE — não vendoriza lib!
    "modules": [],                     // outros módulos pvx dos quais este depende
    "packages": ["bash", "curl", "git"]  // binários/pacotes de sistema que o entrypoint espera
  },
  "os": { "families": ["rhel"] },      // "rhel"/"debian"/"suse" — vazio = qualquer família
  "provides": { "actions": ["issabel4", "issabel5"] },  // listagem/help; não é imposto no código
  "config_files": [],                  // copiados pra $PVX_ETC_DIR/modules.d/<nome>/ só se ainda não existirem
  "state_dir": true                    // true = ganha $PVX_STATE_DIR/state/<nome>/ (cache/logs/estado)
}
```

Campos com regra checada de verdade no install: `schema_version`, `name`, `command` (inclusive
checagem de colisão com comando reservado do core — `modules completion help version tests
doctor config cache paths log update`), `version`, `entrypoint`. O resto é convenção/best-effort,
mas vale preencher com cuidado porque é o que aparece em `pvx modules list`/`pvx registry
list`/`pvx modules help`.

Dois campos merecem destaque porque afetam comportamento real do instalador:

- **`requires.pvx_core`** é a forma correta de declarar "este módulo precisa de tal versão do
  core" — a instalação é recusada se a versão do core instalado não satisfizer essa restrição.
  Isso substitui qualquer necessidade de vendorizar/duplicar lib do core (ver seção 5).
- **`os.families`** filtra por **capacidade declarada**, não allowlist fechada do core — se o
  array estiver vazio, o módulo é considerado compatível com qualquer família. Se a família
  atual não estiver na lista, a instalação recusa a menos que `--force` seja passado.

## 5. O contrato do entrypoint

Todo entrypoint de módulo começa assim (copiado literalmente do padrão usado em
`modules/dummy/bin/pvx-dummy` e `modules/netinstall/bin/pvx-netinstall`):

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

: "${PVX_LIB_DIR:?PVX_LIB_DIR não definido — este módulo deve ser executado via pvx, não direto}"
# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require_init color log os exec tui flags   # só as libs que você realmente vai usar
```

Por quê cada linha:

- `set -Eeuo pipefail` — igual ao resto do projeto: erro não tratado aborta, variável não
  setada é erro, falha em qualquer estágio de um pipe conta. **Isso tem consequências reais**
  pra como você escreve chamadas de comando — ver seção 13.
- `: "${PVX_LIB_DIR:?...}"` — falha alto e com mensagem clara se alguém tentar rodar o
  entrypoint direto (`./bin/pvx-meu-modulo`) em vez de via `pvx meu-modulo`. `PVX_LIB_DIR` só
  existe porque o dispatcher (`bin/pvx`) exporta antes de chamar o módulo — é o contrato
  central de "módulo é plugin, não programa standalone".
- `source "$PVX_LIB_DIR/bootstrap.sh"` — dá acesso a `pvx::require`/`pvx::require_init`
  (carregadores de lib idempotentes), à tabela de exit codes (`PVX_EXIT_*`, ver abaixo), a
  `pvx::tmpdir`/`pvx::on_exit`/etc.
- `pvx::install_traps` — instala os traps padrão (EXIT roda hooks registrados via
  `pvx::on_exit`, ERR loga contexto de erro em modo debug, INT/TERM saem com código
  correto). Sem isso, coisas como o spinner (seção 7.5) e a restauração de terminal do `tui.sh`
  perdem a rede de segurança.
- `pvx::require_init color log os exec tui flags` — dá `source` em cada lib (idempotente: cada
  uma só é carregada uma vez, mesmo se chamado de novo em outro ponto pedindo a mesma lib) **e**
  já chama `color::init`/`log::init` sozinho, na hora — não precisa das duas linhas manuais que
  esse mesmo entrypoint tinha antes. Liste só o que for usar; olhe a seção 7 pra saber o que
  cada lib oferece.

  Se você prefere controlar o momento do init na mão (ex.: seu módulo faz alguma coisa entre
  carregar a lib e inicializá-la), use `pvx::require` puro + `color::init`/`log::init`
  explícitos — é exatamente o padrão antigo, ainda válido, só não é mais o default recomendado.
  É também o que o próprio `bin/pvx` faz internamente: ele precisa ler `/etc/pvx/pvx.conf`
  **entre** inicializar a cor e inicializar o log (uma config `log_dir = ...` só vale se o log
  ainda não tiver aberto o arquivo do dia), então usa `pvx::require` + `color::init`/`log::init`
  manuais nessa ordem específica em vez do atalho — um módulo comum não tem esse tipo de
  intercalação, por isso o atalho é seguro pra ele.

Variáveis que o dispatcher **já preenche** antes de chamar seu entrypoint (não precisa
recalcular nada disso):

| variável | conteúdo |
|---|---|
| `PVX_ROOT` | raiz do pvx-core instalado |
| `PVX_LIB_DIR` | `$PVX_ROOT/lib` |
| `PVX_MODULE_NAME` | nome do seu módulo (resolvido do symlink de despacho) |
| `PVX_MODULE_VERSION` | versão instalada, lida do `module.json` publicado |
| `PVX_MODULE_DIR` | `$PVX_MODULES_DIR/<nome>` — raiz do SEU módulo já instalado |
| `PVX_MODULE_STATE_DIR` | `$PVX_STATE_DIR/state/<nome>` — garantido no disco se `state_dir: true` (ver seção 6) |
| `PVX_DRY_RUN` / `PVX_ASSUME_YES` / `PVX_OFFLINE` | flags globais já parseadas pelo `pvx` pai |

Libs **exclusivas** do seu módulo (ex.: `modules/netinstall/lib/common.sh`) vivem em
`lib/` dentro do próprio módulo e são carregadas via `PVX_MODULE_DIR`, não via `pvx::require`:

```bash
# shellcheck source=/dev/null
source "$PVX_MODULE_DIR/lib/common.sh"
```

**Nunca copie/vendorize** `color.sh`/`log.sh`/`exec.sh`/`tui.sh`/`json.sh`/etc. dentro do seu
módulo. É exatamente a duplicação (~8 cópias quase-idênticas de uma lib de cores) que os
scripts legados que inspiraram este projeto tinham, e que foi o motivo de existir uma lib
compartilhada única e bem testada no core. Se falta alguma coisa na lib compartilhada, o
caminho certo é propor a mudança lá, não duplicar.

### Os códigos de saída (`PVX_EXIT_*`)

| código | constante | significado | quem já usa |
|---|---|---|---|
| 0 | `PVX_EXIT_OK` | sucesso | é o default — não precisa fazer nada especial |
| 1 | `PVX_EXIT_FAILURE` | falha genérica, sem categoria melhor | fallback |
| 2 | `PVX_EXIT_USAGE` | uso incorreto (flag/argumento inválido) | `flags.sh`, em erro de parsing |
| 69 | `PVX_EXIT_UNAVAILABLE` | dependência externa ausente (comando, rede) | `exec::require_cmd` |
| 77 | `PVX_EXIT_NOPERM` | falta de permissão (precisa ser root) | `os::require_root` |
| 78 | `PVX_EXIT_CONFIG` | configuração inválida/corrompida | — |
| 79 | `PVX_EXIT_UNSUPPORTED` | SO/plataforma não suportada | `os::require_rhel_like` |
| 80 | `PVX_EXIT_PRECONDITION` | pré-condição de negócio não satisfeita | ex.: netinstall recusando reinstalar por cima de uma central já ativa |
| 124 | `PVX_EXIT_TIMEOUT` | operação estourou o timeout | mesmo código que o comando `timeout` usa |
| 127 | `PVX_EXIT_NOTFOUND` | comando/módulo não encontrado | mesmo código que o shell usa pra "command not found" |
| 130 | `PVX_EXIT_ABORTED` | interrompido (Ctrl-C) | convenção Unix: 128 + número do sinal (SIGINT=2) |

Não são números escolhidos à toa: a maioria já é convenção conhecida fora do pvx (69/77/78 vêm
do `sysexits.h` clássico do Unix; 124/127/130 são os mesmos códigos que `timeout`, o próprio
shell e um Ctrl-C comum já usam). Usar os mesmos números ajuda quem só olha o `$?` de fora a
entender o que aconteceu, mesmo sem ler seu código.

**O que fazer no seu módulo**: os códigos **1 e 3-63 estão livres** pra você definir o
significado que quiser (documente no `--help`/README do seu módulo). Reaproveite um
`PVX_EXIT_*` da tabela **só** quando a situação for literalmente a mesma coisa (ex.:
`exit "$PVX_EXIT_USAGE"` pra uma flag inválida do seu próprio módulo) — não invente um
significado novo pra um código que já tem um significado combinado.

## 6. Hooks: install/update/uninstall/logs

### Por que hooks existem

Um módulo pode precisar preparar/limpar algo no exato momento em que é instalado, atualizado ou
removido — mesmo sem o usuário nunca ter chamado nenhuma ação dele ainda. Exemplos reais:
inicializar um diretório de state com um valor default, registrar/desregistrar um cron,
migrar um formato de dado entre versões no `update`. Sem um hook, essa lógica teria que virar
uma ação manual que o usuário lembraria (ou esqueceria) de rodar depois de instalar — hooks
tornam isso automático e parte do próprio ciclo de vida do `pvx modules install/update/remove`.

**Hooks não são obrigatórios, e o módulo funciona sem eles.** O módulo de verdade é o
`entrypoint` — é ele que roda toda vez que alguém digita `pvx <comando> <ação>`. Hooks só
cobrem os momentos em que ninguém está chamando seu entrypoint (durante `pvx modules
install/update/remove`, executado pelo core). Sem nenhum hook declarado (`"hooks": {}` ou
campos `null`), `pvx modules install` continua funcionando normalmente — só não roda nenhuma
lógica extra sua no meio do processo.

### Contrato

| hook | quando roda | env extra além do padrão | falha aborta? |
|---|---|---|---|
| `hooks.install` | depois de extrair/validar o pacote, antes de publicar como versão ativa | — | **sim** (rc≠0 aborta a instalação inteira, nada é publicado) |
| `hooks.update` | depois de extrair a nova versão, antes de trocar a versão publicada | `PVX_MODULE_OLD_VERSION` (além de `PVX_MODULE_VERSION`, que já é a NOVA versão) | **sim** (rc≠0 mantém a versão antiga publicada — rollback automático) |
| `hooks.uninstall` | antes de apagar os arquivos do módulo | — | não (só `log::warn`; remoção prossegue mesmo assim) |
| `hooks.logs` | substitui `pvx <comando> logs` (padrão seria `log::tail`) | — | n/a (é `exec`'ado, substitui o processo) |

Todo hook (exceto `logs`) recebe este ambiente, e **precisa sair com `0` em sucesso**:

```
PVX_ROOT               PVX_LIB_DIR
PVX_MODULE_NAME         PVX_MODULE_VERSION      PVX_MODULE_DIR
PVX_STATE_DIR           PVX_MODULE_STATE_DIR
PVX_HOOK                (install|update|uninstall)
PVX_DRY_RUN
```

Na prática o hook é só um script bash normal — escreva com `set -Eeuo pipefail` no topo, sem
precisar de nada especial de shebang/permissão (o core roda ele como `bash <caminho>`, então nem
precisa ter o bit `+x` setado).

Não existe (hoje) um mecanismo pra hook "customizado" com nome novo — só estes quatro slots são
lidos pelo core. Se você precisar de lógica que rode em outro momento que não seja
install/update/uninstall, isso não é hook: é uma **ação normal do seu entrypoint** (ex.: uma
ação `pvx meu-modulo cron-tick`, que o próprio `hooks/install` registra num cron na hora de
instalar).

### O que acontece se o hook falhar (crash ou `exit` ≠ 0)?

Depende de qual hook, e a diferença importa:

| hook | falha aborta a operação? | o que acontece de fato |
|---|---|---|
| `install` | **sim** | instalação inteira é abortada — o módulo nunca chega a ser publicado (sem symlink, sem registro de instalado) |
| `update` | **sim** | update é abortado, mas a versão **antiga continua publicada e funcionando** (rollback automático) — só a versão nova é descartada |
| `uninstall` | **não** (best-effort) | só loga um aviso; a remoção prossegue mesmo assim (arquivos apagados, registro atualizado) |

Um crash dentro do hook (variável não setada, comando que falhou sob `set -e`, o que for) conta
exatamente igual a um `exit` deliberado — o core só olha o código de saída, não distingue os
dois casos. E não existe timeout embutido na chamada de hook: se o seu hook travar esperando
algo (rede sem timeout próprio, por exemplo), `pvx modules install/update/remove` fica
pendurado esperando ele indefinidamente — vale seu hook ter timeout próprio em qualquer coisa
que possa bloquear.

Um efeito colateral pra ficar de olho no `install`: se seu `module.json` declara
`config_files`, esses arquivos são copiados **antes** do hook rodar — um `hooks/install` que
crasha depois disso deixa esses arquivos de config órfãos (a instalação em si continua
abortada/não-instalada, mas o lixo de config fica). Rodar `pvx modules install` de novo depois
de corrigir o hook resolve.

### Exemplo real mínimo (de `modules/dummy/hooks/install`)

```bash
#!/usr/bin/env bash
# hooks/install — no-op REAL (não só um `touch`): registra a chamada em hooks.log, com
# timestamp, pra provar ordem de chamada e passagem de env nos testes.
set -Eeuo pipefail
: "${PVX_MODULE_STATE_DIR:?PVX_MODULE_STATE_DIR não definido}"
mkdir -p "$PVX_MODULE_STATE_DIR"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '?')
printf 'install %s %s\n' "${PVX_MODULE_VERSION:-?}" "$ts" >>"$PVX_MODULE_STATE_DIR/hooks.log"
exit 0
```

**Boa prática destacada aqui**: mesmo um hook que "não tem nada real pra fazer" (porque a lógica
de fato já é coberta por outra parte do ciclo — ex: `config_files` já cuida da cópia de
template) deve registrar isso de forma real e auditável em vez de ser um script vazio e
silencioso. Um `hooks.log` legível é o que permite a um técnico (ou a um teste automatizado)
confirmar que o hook rodou, quando, e com qual versão — muito mais útil que confiar cegamente
que "provavelmente rodou".

### `hooks.logs` é diferente dos outros três

Não é um hook de ciclo de vida — é um substituto opcional pra ação universal `pvx <comando>
logs`. Sem ele, `pvx <comando> logs` cai no `log::tail` genérico (grep no arquivo de log do
pvx filtrado pelo nome do comando) — que já funciona sozinho se seu entrypoint usa
`log::info`/`log::error`/etc. normalmente, sem precisar de nenhum hook. Se seu módulo é um
"serviço" com log próprio fora do `pvx.log` (ex.: um daemon, um monitor), declare `hooks.logs`
apontando pra um script que faça o próprio `tail -f`/equivalente — o dispatcher faz `exec` nele
(substitui o processo atual), então ele deve ser o comando final, não algo que retorna.

## 7. Tour pelas libs compartilhadas

Referência rápida — cada lib é carregada via `pvx::require <nome>` (sem `.sh`):

| lib | pra que serve |
|---|---|
| `bootstrap.sh` | sempre carregada primeiro (via `source` direto, não `pvx::require`) — exit codes, `pvx::require`, exit hooks, tmpdir |
| `color.sh` | cores ANSI com detecção de TTY/`NO_COLOR`/etc. |
| `log.sh` | logging por nível, rotação diária, redação de segredos |
| `exec.sh` | `run`/`srun`/`qrun`, spinner, confirmação, segredo via env |
| `flags.sh` | parser de flags declarativo (`--help` autogerado) |
| `tui.sh` | prompts interativos (select/checklist/input/password/pause) |
| `json.sh` | parser JSON puro-bash (sem `jq`) |
| `os.sh` | detecção de distro/capacidades, sem allowlist fechada |
| `paths.sh` | tabela de caminhos conhecidos (Issabel/Asterisk/pvx) |
| `net.sh` | download de URL (`curl`), aceita `file://`/`http(s)://` |
| `integrity.sh` | hash sha256, segurança de tar, manifesto SHA256SUMS |
| `registry.sh` | comparação de versão (`version::cmp`/`version::satisfies`), estado de módulos instalados |
| `snippets.sh` | helpers de apresentação (`snippets::header/kv/ok/warn/bad`) |

As próximas subseções vão fundo nas mais usadas por quem escreve um módulo. **7.5 (spinner)** e
**7.7 (tui)** merecem atenção especial — são as que mais moldam como o operador vive o seu
módulo na tela.

### 7.1 `bootstrap.sh`

Já explicado na seção 5 (contrato do entrypoint + tabela de exit codes). Vale reforçar duas
funções que todo módulo mais elaborado acaba usando:

```bash
pvx::on_exit minha_funcao_de_limpeza   # pilha LIFO — roda no trap EXIT do processo inteiro
tmp=$(pvx::tmpdir)                     # diretório temporário 0700, apagado sozinho no exit
```

`pvx::on_exit` é a forma correta de garantir limpeza mesmo em caminhos de erro/Ctrl-C — é o
mesmo mecanismo que o spinner e o `tui.sh` usam internamente pra nunca deixar o terminal
travado.

### 7.2 `color.sh`

```bash
printf '%s%s%s\n' "${PVX_C[green]:-}" 'tudo certo' "${PVX_C[reset]:-}"     # stdout
printf '%s%s%s\n' "${PVX_CE[error]:-}" 'deu ruim' "${PVX_CE[reset]:-}" >&2  # stderr
```

`PVX_C` é o mapa pra stdout, `PVX_CE` pra stderr — **são mapas separados de propósito**, porque
stdout e stderr podem ter "TTY-ness" diferente (ex.: `pvx sysinfo > relatorio.txt` — stdout vira
arquivo, stderr continua sendo o terminal). Sempre acesse com `${PVX_C[chave]:-}` (fallback pra
string vazia) — nunca assuma que a cor está ligada. Chaves de paleta: `reset bold dim underline
red green yellow blue magenta cyan white gray bred bgreen byellow`. Chaves semânticas (mais
recomendadas que cor crua, porque sobrevivem a uma futura repaleta): `error warn ok info trace
debug fatal path cmd num head hint`.

Nunca precisa chamar `color::init` você mesmo além da vez no boot do entrypoint — é
idempotente, mas recomputar o modo (`color::set_mode`) é raro fora do parsing de flags globais.

### 7.3 `log.sh`

```bash
log::info  'módulo %s: iniciando ação %s' "$PVX_MODULE_NAME" "$action"
log::warn  'pacote %s não encontrado, pulando' "$pkg"
log::error 'falha ao conectar em %s' "$host"
log::fatal 'estado inconsistente, abortando' 70   # loga + exit 70

log::add_secret "$senha"   # qualquer log:: subsequente que contenha essa string mostra "***"
log::hint 'tente: pvx meu-modulo --force'   # dica visual, sempre em stderr, sem timestamp/nível
```

Tudo em `log::*` vai simultaneamente pro console (respeitando `PVX_LOG_LEVEL`, ajustável via
`-v`/`-q`/`--debug`/`--log-level`) e pro arquivo de log do dia (sempre mais verboso). **Sempre
use os `%s`/`%d` do `printf` em vez de interpolar string direto** (`log::info 'usuário: %s'
"$user"`, não `log::info "usuário: $user"`) — os argumentos extras passam por `log::redact`,
que também aplica heurísticas de mascaramento de formato (`password=...`, `--token ...`,
`-p<algo>`) além da lista explícita de `log::add_secret`.

### 7.4 `exec.sh` — `run`/`srun`/`qrun`

Três verbos, não dois, porque "não muta estado" e "muta estado" precisam se comportar
diferente sob `--dry-run`:

```bash
qrun -- rpm -qa                 # CONSULTA — roda sempre, mesmo em --dry-run (você precisa do resultado)
run  -- systemctl restart httpd # MUTA estado — em --dry-run só loga "[dry-run] $ ..." e retorna 0
srun -- rm -rf "$dir"           # igual a run, mas rc inaceitável ABORTA o processo (exit)
```

Depois de qualquer uma das três, `PVX_RC`/`PVX_OUT`/`PVX_ERR`/`PVX_CMD`/`PVX_DURATION_MS` ficam
preenchidas. Flags úteis (todas antes do `--`):

```bash
run --ok 0,1 --retry 2 --retry-delay 3 --timeout 30 --capture --mask 1 --label 'instalando X' \
  -- comando "$arg_publico" "$arg_secreto"
```

- `--ok 0,1` — quais códigos de saída contam como sucesso (default só `0`)
- `--retry N --retry-delay S` — repete em caso de falha, com espera entre tentativas
- `--timeout S` — usa `timeout`/`gtimeout` se disponível
- `--capture` — não imprime stdout/stderr na hora, só preenche `PVX_OUT`/`PVX_ERR`
- `--mask 1,2` — mascara os argumentos posicionais 1 e 2 (0-indexed) no log renderizado (ex.:
  senha passada como argumento — mas prefira nunca fazer isso, ver `exec::with_env_secret`
  abaixo e a seção 13)
- `--label texto` — usa esse texto no log/spinner em vez do comando renderizado inteiro

Utilidades relacionadas:

```bash
exec::require_cmd rpm curl || exit "$PVX_EXIT_UNAVAILABLE"   # falha com dica de "tente: <mgr> install <cmd>"
exec::confirm 'prosseguir? [y/N]' n                          # respeita -y/PVX_ASSUME_YES; sem TTY cai no default
exec::with_env_secret DB_PASSWORD "$pw" -- mysql -u root      # segredo só no AMBIENTE do filho, nunca em argv
exec::mysql_defaults_file "$user" "$pass"                     # gera --defaults-file=... (nunca -p<senha> em argv)
exec::retry 3 2 -- curl -fsS "$url"                            # retry genérico c/ backoff, fora do fluxo run/srun/qrun
```

`exec::confirm` merece nota: **nunca** use `read -p "..." resp 2>/dev/null` você mesmo. `bash`
escreve o texto de `-p` em **stderr**, e um `2>/dev/null` na mesma chamada apaga o prompt
inteiro — o usuário vê a tela parada, aperta Enter às cegas, e cai no default sem nunca ter lido
a pergunta (bug real, já mordeu duas vezes neste projeto — ver seção 13). Use `exec::confirm`
ou, se precisar de algo mais elaborado, `tui::input`/`tui::password`.

### 7.5 `exec.sh` — spinner (a "barra de progresso" do pvx)

**Nota importante antes de tudo**: o pvx-core **não tem** uma barra de progresso percentual
(`[####    ] 40%`) hoje — o que existe é um **spinner indeterminado** (estilo `npm install`),
porque `run`/`srun`/`qrun` não sabem de antemão quanto trabalho falta pra um comando externo
terminar. Se você ouviu falar em "lib de progressbar" do pvx, é isto: `exec::spinner_start`/
`exec::spinner_stop`.

#### Por que ele existe

`run`/`srun`/`qrun` sempre capturam **toda** a saída do comando num arquivo temporário e só a
"reproduzem" depois que ele termina — não é streaming em tempo real. Isso significa que, sem
nada mais, a tela fica **completamente parada** durante um comando demorado (`dnf` baixando de
um mirror lento, um scriptlet `%post` de RPM fazendo algo pesado) — indistinguível de "travou"
pro operador olhando o terminal. O spinner existe só pra resolver esse problema de percepção:
mostrar "ainda estou vivo, faz N segundos que comecei isto".

#### Como funciona por baixo

- Só anima quando `stderr` é um terminal de verdade e `PVX_NO_SPINNER` não está setado — nunca
  polui log em arquivo, pipe ou CI.
- Espera **0.15s** antes do primeiro frame, pra um comando bem rápido (a maioria) não ganhar
  spinner + linha em branco à toa.
- Roda a animação num subprocesso em background, escrevendo o frame + label + segundos
  decorridos em loop. `exec::spinner_stop` encerra esse subprocesso e limpa a linha.
- Se registra sozinho como hook de saída na primeira vez que é chamado — garante que, mesmo se
  um Ctrl-C interromper o processo com o spinner ainda ativo, o cursor volta ao normal.
- `run`/`srun`/`qrun` **já chamam isto sozinhos** ao redor de todo comando executado — um módulo
  que usa esses três verbos ganha o spinner de graça, sem escrever nada a mais.
- O rótulo é truncado em 60 caracteres (+"...") pra não quebrar linha em terminal estreito.

#### Uso direto (fora de run/srun/qrun)

Pra trabalho que não passa pelos três verbos — um loop esperando um serviço subir, uma
sequência de chamadas de API, etc.:

```bash
exec::spinner_start 'esperando o Asterisk subir...'
until os::service_active asterisk; do sleep 1; done
exec::spinner_stop
```

Sempre pareie `start` com `stop` — chamar `start` duas vezes sem `stop` no meio encerra o
spinner anterior sozinho (defensivo, mas não conte com isso; deixe o pareamento explícito).

#### Atualizando o rótulo dinamicamente — `exec::spinner_update`

Pra um loop que processa vários itens (arquivos, pacotes, hosts, o que for) e você quer que o
operador veja EM QUAL item está agora, sem reiniciar o spinner a cada passo:

```bash
exec::spinner_start 'processando arquivos...'
for f in "${arquivos[@]}"; do
  exec::spinner_update "processando: $f ($((i + 1))/${#arquivos[@]})"
  processar_arquivo "$f"
  i=$((i + 1))
done
exec::spinner_stop
```

`exec::spinner_update` troca só o texto exibido — o mesmo subprocesso continua rodando (nenhum
fork novo, nenhum delay de 0.15s por chamada) e o cronômetro `(Ns)` **não reinicia**: ele
continua contando desde o `spinner_start` original, mostrando quanto tempo o trabalho INTEIRO
está levando, não só o passo atual. É um no-op seguro se não houver spinner ativo (sem TTY,
`PVX_NO_SPINNER=1`, ou `spinner_start` nunca chamado) — nunca precisa de guarda extra no seu
código, pode chamar direto dentro do loop.

Por baixo, o rótulo vive num arquivo pequeno em `pvx::tmpdir()`, relido pelo subprocesso do
spinner a cada frame (a cada 0.08s) — é o único jeito de um processo pai "falar" com um
subprocesso já rodando em bash puro, sem dependência nova nenhuma.

Se o que você quer é justamente reiniciar o cronômetro a cada passo (mostrar "quanto tempo ESTE
passo específico está levando", não o total acumulado), aí sim pareie `stop`+`start` de novo a
cada iteração, como antes:

```bash
local i total=${#pkgs[@]}
for ((i = 0; i < total; i++)); do
  exec::spinner_start "instalando pacotes ($((i + 1))/$total): ${pkgs[i]}"
  os::pkg_install "${pkgs[i]}"
  exec::spinner_stop
done
```

Os dois padrões são válidos — a diferença é só qual cronômetro faz sentido mostrar pro que seu
módulo está fazendo.

### 7.6 `flags.sh`

Parser declarativo, sem `eval`. Padrão de uso num entrypoint:

```bash
flag::add_standard   # -h/-v/-q/-n(--dry-run)/-y(--yes)/--debug/--log-level/--color/--offline
flag::add lang --default pt_BR --help 'idioma do sistema'
flag::add astver --type enum --enum '16|18' --short a --help 'versão do Asterisk'
flag::add addpkgs --repeat --help 'pacote adicional (pode repetir a flag)'
flag::add_secret sql-password --prompt 'senha root do MySQL'
flag::set_usage "$0" 'meu módulo faz X' 'pvx meu-modulo [flags]'
flag::parse "$@" || exit $?

lang=$(flag::get lang)
if flag::has astver; then astver=$(flag::get astver); fi
flag::bool dry-run && printf 'rodando em modo simulação\n'
mapfile -t extras < <(flag::get_all addpkgs)   # todos os valores de uma flag --repeat
```

`flag::add_standard` já cobre as flags globais que **todo** comando do pvx aceita — chame no
começo do parsing do seu módulo pra ficar consistente com o resto da CLI (ex.: `--dry-run`
automaticamente vira `PVX_DRY_RUN=1`, que `run`/`srun` já respeitam sozinhos). Tipos disponíveis
em `--type`: `bool int string secret path csv existing-path ipv4 ipv6 ip cidr port duration
enum` (mais custom via `flag::type_register`).

`flag::add_secret` merece destaque — declarar uma flag assim automaticamente também cria a
variante `--<nome>-file` (lê o valor de um arquivo, sem aparecer em `ps`) e avisa (`log::warn`)
se o valor vier em texto puro pela linha de comando. Prioridade de resolução em `flag::get`
pra um tipo `secret`: flag explícita > `--<nome>-file` > variável de ambiente declarada em
`--env` > prompt interativo (só se tiver TTY) > fallback vazio.

**Princípio de design a copiar**: um módulo não precisa de "modo interativo" separado de "modo
não-interativo" — é sempre a mesma regra pra cada informação: se a flag foi dada, usa e não
pergunta nada; se faltou e tem TTY, pergunta só aquilo (nunca um wizard de tudo junto); sem TTY
e sem flag, erro claro do que falta. Isso é bem mais robusto que dois caminhos de código
paralelos (um "wizard" e um "modo flags") que divergem com o tempo. Padrão típico:

```bash
if flag::has minha-opcao; then
  valor=$(flag::get minha-opcao)
elif tui::is_interactive; then
  tui::input 'minha opção' default_aqui || exit "$PVX_EXIT_ABORTED"
  valor=$TUI_INPUT
else
  valor=default_aqui   # ou: log::error + exit "$PVX_EXIT_USAGE" se não há default seguro
fi
```

### 7.7 `tui.sh` — prompts interativos

#### Por que existe (em vez de `dialog`/`whiptail`)

`tui.sh` é bash puro, sem depender de nenhum pacote de sistema externo (`dialog`/`whiptail` nem
sempre estão instalados numa Issabel mínima, e este é justamente um projeto de
segurança/recuperação — quanto menos dependência externa pra rodar numa central possivelmente
comprometida, melhor). Segundo motivo de design: o piso do projeto é bash **4.2**, que não tem
`declare -n` (nameref só existe a partir do 4.3) — os helpers internos não podem "devolver" um
array pro chamador via referência. A solução adotada é **escopo dinâmico**: funções como
`tui::select` escrevem o resultado em variáveis globais bem conhecidas (`TUI_CHOICE`,
`TUI_RESULT`, `TUI_INPUT`, `TUI_PASSWORD`, `TUI_BACK`) que você lê logo depois da chamada.

#### Detecção de TTY — nunca trava um script/cron/CI

Toda função pública verifica `tui::is_interactive` (stdin **e** stdout precisam ser terminal de
verdade) antes de entrar em modo raw/interativo. Sem isso — rodando via pipe, cron, CI, ou um
`pvx meu-modulo | tee log.txt` — cai automaticamente num modo texto por número, nunca fica
esperando teclas de terminal que nunca vão chegar.

`tui::is_interactive` é a mesma checagem exposta como função nomeada — use ela (em vez de
reescrever a checagem crua) sempre que o SEU módulo precisar decidir, por fora, "abro um
`tui::select`/`checklist` ou caio num fallback de flag/erro?" (é exatamente o padrão do bloco
`flag::has` acima). As próprias `tui::select`/`checklist`/`pause` já fazem essa checagem
sozinhas por dentro — chamar de novo do lado de fora não muda nada nelas, só evita duplicar a
checagem crua no seu código.

#### API pública

```bash
# escolha única — TUI_CHOICE recebe o item escolhido (texto exato), rc=1 se cancelado (q/ESC/Ctrl-C)
tui::select "$(tui::breadcrumb meu-modulo)" 'opção 1' 'opção 2' 'opção 3' || exit 0
case $TUI_CHOICE in
  'opção 1') ... ;;
esac

# seleção múltipla — TUI_RESULT é um array com os itens marcados, na mesma ordem recebida
TUI_CHECKLIST_DEFAULT=(1 0 1)   # pré-marca item 1 e 3, ANTES de chamar — opcional
tui::checklist "$(tui::breadcrumb meu-modulo 'o que instalar?')" pacote-a pacote-b pacote-c
for item in "${TUI_RESULT[@]}"; do printf 'vai instalar: %s\n' "$item"; done

# texto livre — TUI_INPUT; Enter vazio usa o default (se houver); sem default, EOF/vazio cancela
tui::input 'nome do usuário' phonevox "$(tui::breadcrumb meu-modulo usuario)" || exit "$PVX_EXIT_ABORTED"
usuario=$TUI_INPUT

# senha mascarada — TUI_PASSWORD; sem TTY devolve "" silenciosamente, nunca ecoa nem vaza pro stdout
tui::password "$(tui::breadcrumb meu-modulo senha)" 'senha do banco'
senha=$TUI_PASSWORD

# pausa de uma tecla só — TUI_BACK=1 se apertou q/ESC/Ctrl-C, 0 caso contrário
tui::pause 'pressione enter pra continuar (q volta)'
((TUI_BACK)) && return 0
```

Helpers de título, pra ficar visualmente consistente com o resto do pvx:

```bash
tui::breadcrumb meu-modulo instalar        # "pvx > meu-modulo > instalar" (último segmento em cyan/negrito)
tui::with_desc "$(tui::breadcrumb meu-modulo)" 'texto explicando o que esta tela faz'
```

`tui::with_desc` junta um breadcrumb com uma descrição de uma ou mais linhas — a primeira linha
sai em negrito, a(s) seguinte(s) numa cor normal, com uma linha em branco separando "explicação"
de "pergunta".

#### As três armadilhas que já morderam este projeto (evite repetir)

1. **Nunca chame `tui::select`/`tui::checklist` via `$(...)` ou `< <(...)`.** Parte da UI
   (título, itens, rodapé de ajuda) é escrita em **stdout**, não só em stderr — capturar a
   função via substituição de comando embaralha esse texto junto com o valor que você queria
   capturar. Chame direto (bare) e leia `TUI_CHOICE`/`TUI_RESULT` na variável global logo em
   seguida — nunca tente "retornar" o resultado via `$(minha_funcao_que_chama_tui)`. Motivo
   adicional: a detecção de TTY dentro da função sempre daria falso rodando dentro de uma
   substituição de comando, fazendo a UI interativa nunca aparecer.

2. **Toda ação de um menu interativo (seu ou de um submenu que você construir) precisa de
   `|| true` (ou `|| rc=$?`).** Sob `set -Eeuo pipefail`, uma função de ação que retorna
   diferente de zero — mesmo que já tenha logado seu próprio erro — dispara o trap de `ERR` e
   derruba a sessão **inteira**, não só aquela ação. Padrão correto:
   ```bash
   case $chosen in
     acao1) minha_funcao_acao1 || true ;;
   esac
   ```

3. **Uma função cuja última instrução literal é `[[ condição ]] && return 0` retorna `1`
   (falha) quando a condição é falsa** — mesmo sem nada ter dado errado. Sob `set -e`, isso
   derruba o processo se essa função for chamada como comando solto. Sempre termine funções de
   ação/menu com um `return 0` explícito como última linha, não dependendo do exit status do
   último teste.

### 7.8 `json.sh`

Parser JSON puro-bash — sem depender de `jq` (pode não existir num RHEL mínimo/offline).

```bash
json::flatten_cached "$arquivo.json" "$arquivo.flat"   # só reprocessa se o hash do .json mudou
valor=$(json::get "$arquivo.flat" .algum.campo)
valor_com_default=$(json::get_def "$arquivo.flat" .campo.opcional 'default')
n=$(json::len "$arquivo.flat" .um.array)
for ((i = 0; i < n; i++)); do
  item=$(json::get "$arquivo.flat" ".um.array[$i].nome")
done
```

Na prática, um módulo comum raramente precisa chamar `json.sh` diretamente — é mais usado
internamente pelo core pra ler `module.json`/`index.json`. Mas se o seu módulo tem config
própria em JSON, é a lib certa pra ler sem exigir `jq` instalado.

### 7.9 `os.sh`

```bash
os::require_root "meu-modulo ação"          # exit "$PVX_EXIT_NOPERM" se não for root
os::require_rhel_like "meu-modulo" || exit "$PVX_EXIT_UNSUPPORTED"
os::is_container && log::warn 'rodando em container — comportamento pode variar'
os::pkg_manager           # dnf|yum|microdnf|apt-get|zypper|apk — o primeiro encontrado
os::pkg_install pacote1 pacote2
os::service_active asterisk
os::selinux_state          # enforcing|permissive|disabled
os::issabel_version         # via /etc/issabel.conf ou rpm -q issabel-pbx
```

Design consciente: `os.sh` **não tem allowlist fechada de distro** — `os::is_rhel_like`/
`os::is_debian_like`/`os::is_suse_like` são cidadãos de primeira classe, e quem decide se um
host é compatível com o SEU módulo é o `module.json` (`os.families`), não esta lib. Prefira
sempre checar **capacidade** (`os::pkg_manager`, `os::has_systemd`) a checar identidade de
distro quando o que importa é "esse binário existe", não "essa é a distro X".

### 7.10 `paths.sh`

Tabela única de caminhos conhecidos (Issabel/Asterisk/pvx), sobrescrevível por site via
`/etc/pvx/pvx.conf`:

```bash
path::get asterisk_etc                  # -> /etc/asterisk (ou prefixo de teste + isso)
path::exists issabel_web                # true/false
path::join "$(path::get issabel_root)" dialer config.ini
path::require asterisk_etc mysql_data || exit "$PVX_EXIT_PRECONDITION"
```

Chaves já cadastradas: `asterisk_etc/lib/spool/monitor/log/agi/sounds/run`,
`issabel_root/dialer/conf/web/backup/menu_db`, `mysql_data/cnf`, `httpd_conf/confd`,
`fail2ban_etc`, `cron_d`, `pvx_root/current/modules/etc/conf/state/cache/log/baselines/lock`.
Se o seu módulo tem um caminho próprio recorrente, é aceitável usar `path::set` pra registrá-lo
em runtime, mas não é obrigatório — variável local simples também serve pra algo usado uma vez
só.

### 7.11 `net.sh`

```bash
net::is_offline && log::error 'sem rede'   # true se PVX_OFFLINE=1 OU curl ausente
net::fetch "$url" "$destino" 'rótulo pro log' 30   # timeout em segundos; nunca deixa parcial no destino final
caminho=$(net::fetch_to_cache "$url" "$PVX_CACHE_DIR/downloads" 'meu download')
```

`net::fetch` sempre baixa pra um arquivo temporário e só promove pro destino final em sucesso —
nunca deixa um download incompleto "parecendo válido" se cair no meio. Em caso de falha, traduz
o código de erro do `curl` numa mensagem específica (DNS, conexão recusada, timeout, erro
HTTP/TLS) em vez de um genérico "falha ao baixar".

### 7.12 `integrity.sh`

```bash
sha=$(integrity::sha256_file "$arquivo")
integrity::tar_safety_scan "$tarball" || exit $?        # rejeita path absoluto/".." ANTES de extrair
integrity::tar_top_dir "$tarball"                        # lista diretórios de topo (deve ser só 1)
integrity::verify_sha256sums_dir "$dir_extraido"         # confere manifesto SHA256SUMS, se existir
```

Usada pelo core no fluxo de instalação/update de módulo, e por `tools/pack-module.sh` ao gerar
o `SHA256SUMS` de um pacote. Um módulo comum não costuma chamar isso diretamente, mas é
relevante saber que existe se você for escrever ferramentas de empacotamento/distribuição
próprias.

### 7.13 `registry.sh` — comparação de versão

Além de gerenciar o estado local de módulos instalados (uso interno do core), expõe duas
funções de versão úteis em qualquer módulo que precise comparar versões:

```bash
version::cmp 1.2.3 1.10.0        # -> 2 (a < b) — compara numericamente, não lexicograficamente
version::satisfies "$v" '>=1.2.0'  # true/false — mesma sintaxe usada em requires.pvx_core
```

### 7.14 `snippets.sh`

Só formatação de saída, usada por snippets (seção 12) e reaproveitável por um módulo se fizer
sentido visualmente parecer um relatório read-only:

```bash
snippets::header 'minha seção'
snippets::kv 'chave' 'valor'
snippets::ok   'tudo certo com X'
snippets::warn 'Y está num estado estranho'
snippets::bad  'Z falhou'
```

## 8. Como o registry funciona

`registry/index.json` (ou uma URL configurada via `pvx registry set`) é **só um índice** —
nunca contém código de módulo, só metadado + de onde buscar:

```jsonc
{
  "schema_version": 1,
  "modules": [
    {
      "name": "qint", "command": "qint", "version": "1.0.0",
      "summary": "...", "requires": { "pvx_core": ">=0.1.0" }, "os": { "families": ["rhel"] },
      "git": { "url": "https://github.com/<org>/pvx-mod-qint.git", "ref": "v1.0.0" }
    },
    {
      "name": "outro", "command": "outro", "version": "0.2.0",
      "tarball": { "url": "https://.../pvx-mod-outro-0.2.0.tar.gz", "sha256": "<sha256>" }
    }
  ]
}
```

Cada entrada usa **ou** `git` **ou** `tarball`, nunca os dois. `git.ref` opcional — sem ele,
segue a branch padrão do repositório (prefira travar numa tag de release pra não puxar `HEAD`
em movimento silenciosamente).

### O que o `pvx modules install <nome>` faz, em linguagem simples

1. Busca o índice (com cache local — não bate rede toda vez, só quando o cache expira ou você
   força com `pvx registry refresh --force`).
2. Confere se seu módulo é compatível com esta máquina: família de SO (`os.families`), versão
   mínima do core (`requires.pvx_core`), pacotes exigidos (`requires.packages`).
3. Baixa (tarball) ou clona (git) o módulo, e confere a integridade — checksum do tarball
   contra o valor do índice, ou o `module.json` validado.
4. Roda o `hooks.install` (se existir), publica o módulo, e cria o comando `pvx <nome>`.

Se algo nesse caminho falhar, nada fica "meio instalado": ou o módulo termina publicado por
completo, ou a instalação é abortada e nada muda no sistema.

### Como você instalou afeta como o `update` funciona

- instalado **via registry** → atualização compara a versão do índice remoto contra a instalada.
- instalado **direto via `git`** (sem passar pelo índice) → atualização re-verifica o
  repositório original diretamente.
- instalado **via `--file` avulso** → sem como checar atualização automaticamente; reinstale
  manualmente quando tiver uma versão nova.

### Comandos de consulta/configuração

```bash
pvx registry status              # URL configurada, idade do cache, quantos módulos disponíveis
pvx registry list                # nome/versão/resumo de cada módulo do índice
pvx registry refresh [--force]
pvx registry set <url>           # grava em /etc/pvx/pvx.conf — requer root
```

## 9. Empacotando um módulo

Três ferramentas em `tools/`, cada uma cobrindo uma etapa da distribuição:

### `tools/pack-module.sh <diretório-do-módulo>`

```bash
tools/pack-module.sh modules/meu-modulo
# -> dist/pvx-mod-meu-modulo-<versão>.tar.gz (+ .sha256 sidecar)
```

Valida o `module.json`, copia o diretório pra um staging (removendo `.git`), gera um
`SHA256SUMS` na raiz do pacote e empacota com o diretório de topo sendo `<nome>-<versão>/` —
exatamente o que o instalador exige (1 único diretório de topo).

### `tools/make-index.sh <diretório-com-tarballs> <saída.json> [base-url]`

Gera um `index.json` a partir de tarballs já empacotados, **inspecionando o `module.json` de
dentro de cada tarball** (não confia no nome do arquivo). Se houver duas versões do mesmo
módulo no diretório, usa a mais alta como a "disponível". Sem `base-url`, gera URLs `file://`
(perfeito pra testar localmente, sem precisar de servidor HTTP nenhum).

### `tools/add-git-module.sh <git-url> [ref] <index.json>`

Alternativa pra um módulo distribuído direto do próprio repositório git, sem tarball nenhum:
clona raso, lê `name`/`command`/`version`/`summary` do `module.json`, e escreve/atualiza a
entrada `git` correspondente no índice — preservando todas as outras entradas já publicadas.
Se `<ref>` for um SHA completo de 40 hex, a entrada fica marcada como "pinned" (imutável);
senão, "ref" (tag/branch podem ser movidos pelo mantenedor sem aviso).

### Fluxo de dev local, sem publicar a cada iteração

```bash
tools/pack-module.sh modules/meu-modulo
pvx modules install --file dist/pvx-mod-meu-modulo-<versão>.tar.gz
# testou, quer mudar algo:
#   edita modules/meu-modulo/, roda pack-module.sh de novo, install --file --force
```

## 10. Testando

Existem **dois níveis** de teste, e é importante não confundi-los:

### Nível 1 — testes do próprio pvx-core

Isso é o que o **core** usa pra testar `lib/*.sh`/`bin/pvx` (pasta `tests/`, roda via
`tests/run` ou `pvx tests`). Você não precisa entender os detalhes desse framework pra testar
seu módulo — só vale saber que `tests/suites/smoke.sh` é a referência de "ciclo de vida
completo de um módulo testado de ponta a ponta" (empacota, instala, atualiza, remove, tudo via
o `pvx` real), caso você queira montar algo parecido pro seu próprio módulo mais adiante.

### Nível 2 — testes de um módulo (o que você vai escrever de verdade)

Um módulo é um repositório **separado** — não faz sentido vendorizar o framework de teste
inteiro do core só pra um punhado de asserções. `modules/netinstall/tests/unit.sh` mostra o
padrão recomendado: um mini-framework próprio, de poucas linhas, dentro do próprio módulo:

```bash
_PASS=0; _FAIL=0
assert_eq() {
  local desc=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then
    printf '  ok - %s\n' "$desc"; _PASS=$((_PASS + 1))
  else
    printf '  FALHOU - %s (esperado=[%s] obtido=[%s])\n' "$desc" "$expected" "$actual" >&2
    _FAIL=$((_FAIL + 1))
  fi
}
# ... suas asserções diretas ...
printf '\n%d/%d testes passaram\n' "$_PASS" "$((_PASS + _FAIL))"
((_FAIL == 0))
```

Esse teste **ainda depende do pvx-core pra rodar** (precisa de `bootstrap.sh`/`lib/*`), mas via
uma variável de ambiente apontando pra um checkout do core, não por vendoring:

```bash
: "${PVX_ROOT:?defina PVX_ROOT apontando pro checkout do pvxcli antes de rodar isto}"
PVX_LIB_DIR="$PVX_ROOT/lib"
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::require color log os exec tui flags net
source "$MODULE_DIR/lib/common.sh"
```

Não existe um `pvx modules test <nome>` automático — testar um módulo é rodar o `tests/*.sh`
dele diretamente (com `PVX_ROOT` setado), do jeito que o próprio autor do módulo organizar.

### Receita: mockar comandos que tocam o sistema de verdade

Um módulo que chama `useradd`/`chpasswd`/`os::pkg_install`/etc. não deve executar isso de
verdade num teste. O padrão é sobrescrever a função por um shell function local, registrar as
chamadas **num arquivo** (nunca num array — uma chamada via `$(...)` roda em subshell, e
mutação de array dentro dela não volta pro processo principal), e desfazer no final:

```bash
calls_file=$(pvx::tmpdir)/calls.txt
: >"$calls_file"
os::pkg_install() { printf '%s\n' "$*" >>"$calls_file"; return 0; }

out=$(minha_funcao_que_chama_pkg_install pacote-a pacote-b)
unset -f os::pkg_install

assert_eq 'chamou pkg_install com os pacotes certos' 'pacote-a pacote-b' "$(cat "$calls_file")"
```

### A regra que não tem exceção: valide num ambiente real

Rode a suíte (a do core e a do seu módulo) num Linux de verdade, com um terminal real —
container, VPS, ou a própria central de teste. Ferramentas de shell variam de forma sutil entre
plataformas (versão de bash, dialeto de `stat`/`tar`/`date`, presença ou não de um TTY de
verdade), e qualquer coisa que toque `tui.sh`, prompt de senha, ou o spinner só se comporta como
o operador final vai ver de fato nesse tipo de ambiente. Rodar os testes na sua máquina de
desenvolvimento durante o dia a dia é útil como sanity check rápido — só não substitui essa
validação antes de considerar algo pronto.

## 11. Ciclo de vida completo, do zero à instalação

```
1. crie o repositório pvx-mod-<nome> (fora do pvxcli), OU clone-o dentro de modules/<nome>/
   pra iterar localmente (ignorado pelo .gitignore).

2. escreva module.json (seção 4), bin/pvx-<nome> (seção 5), hooks/ (seção 6, se precisar).

3. desenvolva usando as libs compartilhadas (seção 7) — pvx::require, nunca vendorize.

4. escreva tests/ próprios (seção 10) e rode num ambiente Linux real (seção 10).

5. tools/pack-module.sh modules/<nome>
   pvx modules install --file dist/pvx-mod-<nome>-<versão>.tar.gz
   # itere aqui: editar -> pack -> install --file --force -> testar de novo

6. quando estiver pronto pra publicar de verdade:
   a) publique o repositório no git (tag de release recomendada), e adicione a entrada no
      índice via tools/add-git-module.sh <url> <tag> registry/index.json; OU
   b) hospede o tarball gerado por pack-module.sh em algum lugar (S3, GitHub Releases, etc.)
      e adicione a entrada via tools/make-index.sh (ou editando o índice manualmente).

7. distribua o índice atualizado (arquivo estático servido por http(s), ou aponte
   PVX_REGISTRY_URL de cada central pra ele via `pvx registry set`).

8. dali em diante, qualquer central roda: pvx modules install <nome>
```

## 12. Snippets em detalhe

Um snippet é um único arquivo em `share/pvx/snippets/<nome>.sh`, sourced **in-process** pelo
próprio `pvx` (não é um subprocesso) — por isso ganha automaticamente todo `PVX_C`/`PVX_CE`/log
já inicializado pelo processo pai, sem precisar rechamar `color::init`/`log::init`. Contrato:
definir uma função `snippet::<nome>::main` (caracteres não-alfanuméricos do nome do comando
viram `_`):

```bash
#!/usr/bin/env bash
# share/pvx/snippets/meu-snippet.sh — sourced in-process pelo dispatcher.
snippet::meu_snippet::main() {
  case ${1:-} in
    -h | --help) printf 'uso: pvx meu-snippet\n\ndescrição curta.\n'; return 0 ;;
  esac
  pvx::require snippets   # + o que precisar
  snippets::header 'algo'
  snippets::kv chave valor
  return 0
}
```

Regra de ouro pra um snippet read-only (`sysinfo` é o exemplo real, `share/pvx/snippets/
sysinfo.sh`): **nunca `exit`/`return` diferente de zero por causa de um dado individual
ausente**. Cada seção do relatório é isolada e imprime "n/a"/"não encontrado" pro que não se
aplica, em vez de abortar o resto do relatório inteiro por causa de, por exemplo, o Asterisk não
estar instalado nessa máquina específica.

Snippets não passam pelo `registry`/`modules` — eles chegam junto do checkout/instalação do
próprio pvx-core. Não têm versão própria, não têm hooks, não podem ser removidos/atualizados
independente do core. Se seu "snippet" está crescendo a ponto de precisar de qualquer uma
dessas coisas, é hora de virar módulo (seção 2).

## 13. Checklist de boas práticas / armadilhas conhecidas

Consolidado de bugs reais já encontrados e corrigidos neste projeto — vale conferir cada item
antes de considerar um módulo pronto:

- [ ] **Nunca** vendorize cópia de `color.sh`/`log.sh`/`exec.sh`/`tui.sh`/`json.sh`/etc. dentro
      do módulo — sempre `pvx::require`. Declare `requires.pvx_core` no `module.json` pra
      documentar a dependência de versão.
- [ ] **Toda chamada solta de `run --`/`srun --` sob `set -Eeuo pipefail` pode matar o processo
      inteiro** se o comando falhar e a chamada não estiver dentro de um `if`/`&&`/`||`. Isso é
      inerente ao `set -e`, não um bug de `exec.sh` — quando uma falha específica NÃO pode
      derrubar todo o fluxo (um passo legitimamente opcional, por exemplo), guarde
      explicitamente: `if ! run -- comando; then ...trate...; fi`.
- [ ] Em qualquer menu interativo (seu ou reaproveitando um padrão do core), toda ação
      despachada por `case` precisa de `|| true` (ou `|| rc=$?` + tratamento) — senão um rc≠0
      derruba a sessão inteira em vez de só voltar pro menu.
- [ ] **`local a=$1 b=$a` numa linha só quebra sob `set -u`** — bash expande os valores de
      TODOS os nomes de um `local` antes de "criar" qualquer um deles no escopo atual; `$a` em
      `b=$a` ainda não existe localmente ali, e sem um `a` externo pra herdar dá `a: unbound
      variable`. Pior: se quem CHAMA a função por acaso já tem uma variável de mesmo nome (`a`)
      no próprio escopo, o escopo dinâmico do bash cai nela silenciosamente e o bug não
      aparece — até alguém chamar a função a partir de uma variável de outro nome (achado de
      verdade 3x: `modules/firewall/lib/common.sh`, `lib/tui.sh:tui::_title_rows`,
      `lib/cmd_modules.sh:modules::_split_ref` — a última "funcionava" só porque toda função
      que a chamava guardava o valor numa variável também chamada `title`/igual). Sempre que
      uma atribuição de `local` depender do valor de outra do MESMO `local`, separe em dois
      `local`s: `local a=$1` seguido de `local b=$a ...`.
- [ ] Uma função cuja última linha literal é `[[ cond ]] && return 0` retorna `1` quando `cond`
      é falsa, mesmo sem erro nenhum — termine com `return 0` explícito quando for essa a
      intenção.
- [ ] **Nunca** use `read -p "..." resp 2>/dev/null` — o `2>/dev/null` engole o prompt (escrito
      em stderr por padrão do bash) junto com o erro que você queria calar. Use
      `exec::confirm`/`tui::input`/`tui::password`, ou pelo menos separe o `printf` do `read`.
- [ ] **Nunca** chame `tui::select`/`tui::checklist`/`tui::input`/`tui::password` via `$(...)`
      — parte da UI é escrita em stdout, e a substituição de comando quebra a detecção de TTY.
      Leia o resultado da variável global (`TUI_CHOICE`/`TUI_RESULT`/etc.) logo depois da
      chamada direta.
- [ ] **Segredo nunca em argv** (`ps` de qualquer usuário no sistema enxerga argumentos de
      processo). Use `flag::add_secret` (+ `--<nome>-file`), `exec::with_env_secret`, ou
      `exec::mysql_defaults_file` — nunca `comando -p"$senha"` nem `comando --password "$senha"`
      cru.
- [ ] Toda confirmação destrutiva deve **falhar fechado** sem TTY e sem `-y`/`PVX_ASSUME_YES`
      (nunca assuma "sim" por padrão só porque não há como perguntar) — `exec::confirm` já faz
      isso certo.
- [ ] Operações que mutam o sistema devem passar por `run`/`srun` (não `system()`/backtick cru)
      pra herdar `--dry-run`, log automático do comando renderizado, e o spinner de graça.
      Leituras que precisam rodar mesmo em `--dry-run` usam `qrun`.
- [ ] Use os códigos livres (`1` e `3`-`63`) pro significado específico do seu módulo, e reuse
      um `PVX_EXIT_*` da tabela (seção 5) só quando a situação for literalmente a mesma coisa.
- [ ] Declare `requires_root: true` no `module.json` se o entrypoint precisa de root — o
      dispatcher checa isso **antes** de rodar o módulo, mas o módulo ainda deve chamar
      `os::require_root` internamente também (defesa em profundidade, e cobre quem chama
      funções do módulo fora do fluxo normal de dispatch).
- [ ] `config_files` só devem ser copiados se ainda não existirem no destino — isso já é o
      comportamento do core ao publicar um módulo; não sobrescreva customização do técnico num
      update.
- [ ] Teste num Linux real (container ou VPS), nunca só na sua máquina de dev — principalmente
      tudo que toca TTY, `stat`/`tar`/`date` com flags específicas de plataforma, ou bash < 4.3.
- [ ] Hooks devem sempre sair com `0` em sucesso e registrar o que fizeram de forma auditável
      (mesmo um hook "vazio" — ver `hooks.log` do `dummy`), nunca ser um script silencioso.
- [ ] Nomes de módulo/comando não podem colidir com um comando reservado do core (`modules
      completion help version tests doctor config cache paths log update`) — `module.json`
      já é validado contra isso no install, mas escolha o nome pensando nisso de antemão.

## 14. Exemplo prático: um módulo "hello" do zero

Um esqueleto mínimo, mas usando de propósito flags + TUI + spinner + hook, pra servir de
template real (não um "hello world" vazio). Estrutura:

```
pvx-mod-hello/
├── module.json
├── README.md
├── bin/pvx-hello
└── hooks/install
```

**`module.json`**

```jsonc
{
  "schema_version": 1,
  "name": "hello",
  "command": "hello",
  "version": "0.1.0",
  "summary": "Módulo de exemplo do guia de desenvolvimento",
  "entrypoint": "bin/pvx-hello",
  "requires_root": false,
  "hooks": { "install": "hooks/install", "uninstall": null, "update": null, "logs": null },
  "requires": { "pvx_core": ">=0.1.0", "modules": [], "packages": [] },
  "os": { "families": [] },
  "provides": { "actions": ["greet"] },
  "config_files": [],
  "state_dir": true
}
```

**`hooks/install`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
: "${PVX_MODULE_STATE_DIR:?PVX_MODULE_STATE_DIR não definido}"
mkdir -p "$PVX_MODULE_STATE_DIR"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '?')
printf 'install %s %s\n' "${PVX_MODULE_VERSION:-?}" "$ts" >>"$PVX_MODULE_STATE_DIR/hooks.log"
exit 0
```

**`bin/pvx-hello`**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

: "${PVX_LIB_DIR:?PVX_LIB_DIR não definido — este módulo deve ser executado via pvx, não direto}"
# shellcheck source=/dev/null
source "$PVX_LIB_DIR/bootstrap.sh"
pvx::install_traps
pvx::require_init color log os exec tui flags

hello::usage() {
  cat <<'EOF'
uso: pvx hello greet [flags]

ações:
  greet   cumprimenta alguém (por flag ou perguntando na hora)

flags de "greet":
  --nome NOME   quem cumprimentar (sem isso, pergunta se houver terminal)
EOF
}

hello::greet() {
  flag::reset
  flag::add_standard
  flag::add nome --help 'quem cumprimentar'
  flag::set_usage "$0 greet" 'cumprimenta alguém' 'pvx hello greet [flags]'
  flag::parse "$@" || exit $?

  local nome=''
  if flag::has nome; then
    nome=$(flag::get nome)
  elif tui::is_interactive; then
    tui::input 'nome de quem cumprimentar' "$(whoami)" "$(tui::breadcrumb hello greet)" \
      || exit "$PVX_EXIT_ABORTED"
    nome=$TUI_INPUT
  else
    log::error 'greet: informe --nome (sem terminal interativo disponível pra perguntar)'
    exit "$PVX_EXIT_USAGE"
  fi

  exec::spinner_start "preparando cumprimento pra $nome..."
  sleep 1   # aqui entraria trabalho de verdade
  exec::spinner_stop

  printf '%solá, %s!%s\n' "${PVX_C[green]:-}" "$nome" "${PVX_C[reset]:-}"
  log::info 'hello: cumprimentou %s' "$nome"
}

action=${1:-}
case $action in
  greet)
    shift
    hello::greet "$@"
    ;;
  -h | --help | '')
    hello::usage
    ;;
  *)
    printf 'hello: ação desconhecida: %s\n' "$action" >&2
    hello::usage >&2
    exit 2
    ;;
esac
```

Teste local:

```bash
tools/pack-module.sh modules/hello
pvx modules install --file dist/pvx-mod-hello-0.1.0.tar.gz
pvx hello greet                 # com TTY: pergunta o nome
pvx hello greet --nome Adrian   # sem perguntar nada
```

Esse esqueleto já cobre, num exemplo pequeno: contrato de entrypoint (seção 5), hook real com
log auditável (seção 6), `flags.sh` com o padrão "flag > TTY > erro claro" (seção 7.6),
`tui::input` sem `$(...)` (seção 7.7), spinner ao redor de trabalho que não passa por
`run`/`srun` (seção 7.5), e cor semântica (seção 7.2). A partir daqui é questão de trocar
`sleep 1` pela lógica de verdade do seu módulo.
