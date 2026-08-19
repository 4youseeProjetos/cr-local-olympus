# cr-local-olympus

Code review do seu PR local por **dois revisores independentes** no kiro-cli: um de
qualidade e arquitetura, um de segurança — rodando em **modelos de famílias
diferentes**, para que os pontos cegos não coincidam.

---

## ⚡ Instalar

Cole isto no kiro-cli:

```
Instale o cr-local-olympus neste kiro: clone
https://github.com/4youseeProjetos/cr-local-olympus.git em ~/cr-local-olympus,
rode ./install.sh e me mostre a saída. Se a pasta já existir, faça git pull e
rode ./install.sh de novo.
```

O agente pede sua aprovação antes de cada comando — é aí que você confere o que está
sendo executado. O `install.sh` termina imprimindo os próximos passos.

Depois: **reinicie a sessão**, entre em `/agent cr-olympus` e rode a skill de dentro do
repositório que quer revisar.

> Os dois passos depois do install não são decorativos. O hook que impede a revisão de
> rodar sobre um diff mal definido vive na config do `cr-olympus`; a partir de qualquer
> outro agente a skill funciona, mas sem trava nenhuma.

## 🔄 Atualizar

```
Atualize o cr-local-olympus: em ~/cr-local-olympus faça git pull, rode
./install.sh e depois python3 tests/check-consistency.py. Me mostre a saída
dos dois.
```

O `install.sh` é **obrigatório** no update, não opcional: os agentes são renderizados
com o caminho do seu clone, então um `git pull` sozinho atualiza os templates sem
atualizar o que o kiro realmente carrega.

**Reinicie a sessão depois.** Config de agente tem hot-reload, mas verificamos que
agente registrado no meio de uma sessão é aceito pelo nome enquanto seu campo `model` é
ignorado — o stage cai no modelo da sessão. Numa revisão isso significaria os dois
revisores no **mesmo** modelo, sem erro, concordando entre si por serem o mesmo modelo.

---

## As duas versões

O install entrega as duas. A escolha é entre garantia e velocidade.

### `/cr-local-olympus` — a completa

Um revisor de IA sozinho tem dois vícios previsíveis: mistura preocupação de estilo com
risco de segurança, e não tem contraditório — o que ele afirma, fica. Dois revisores no
mesmo modelo não resolvem: eles erram junto e concordam entre si, o que produz
confiança falsa, o pior resultado possível numa revisão dupla.

Esta versão separa os escopos e coloca cada revisor num fornecedor diferente. Depois
cada um lê o laudo do outro e é obrigado a confirmar ou refutar. Achado que sobrevive à
leitura de duas famílias de modelo é o sinal mais forte que o fluxo produz.

São **5 agentes, 3 hooks e 2 scripts**. O que isso compra:

- **Gate travado por hook** — o review não dispara antes de você confirmar a branch
  base e o escopo. Não é instrução que o modelo pode atropelar; é `exit 2` no engine.
- **Read-only forçado** — os revisores não têm ferramenta de escrita, e um hook
  tokeniza cada comando para barrar git que altere estado, inclusive escondido em
  encadeamento (`git diff && git reset --hard`).
- **Triagem de risco** antes dos revisores caros, para priorizar leitura.
- **Revisor de testes dedicado**, numa terceira família de modelo.
- **Laudo arquivado** no repo, datado, com o detalhe todo.
- **Resposta a diff grande** — dimensiona por volume, fragmenta por módulo e
  redespacha o que truncou.

Use antes de merge, em PR grande, ou em mudança sensível.

### `/cr-light-local-olympus` — a enxuta

**Um arquivo `.md`**, nada além. Sem agente, sem hook, sem script.

Ela consegue orquestrar porque despacha `role: kiro_default` — agente embutido — com o
**modelo forçado em cada stage**. É o override por stage que dá a diversidade de
família, não a config do agente. Verificado que funciona e que o agente embutido roda
git normalmente.

Mantém o que evita falha silenciosa: confirmação da base, SHAs literais em vez de nome
de branch, `git -C` com caminho absoluto, detecção de arquivo não rastreado, corte de
80% de confiança em segurança, e a linha de cobertura.

O que ela troca por velocidade são as **travas de engine**. O gate e o read-only viram
texto no prompt, e texto o modelo pode atropelar. Também não fragmenta nem redespacha:
acima de ~1500 linhas ela avisa e sugere a completa.

Use em PR pequeno, ou quando quiser resposta rápida.

### Lado a lado

| | completa | enxuta |
|---|---|---|
| Estrutura | 5 agentes, 3 hooks, 2 scripts | um arquivo `.md` |
| Revisores | segurança, qualidade, testes | segurança, qualidade |
| Triagem de risco | sim | não |
| Cross-check | rodada dedicada | dentro do stage de combinação |
| Laudo em arquivo | sim, datado no repo | não, só chat |
| Gate travado por hook | **sim** | não, só instrução |
| Read-only forçado por hook | **sim** | não, só instrução |
| Diff grande | dimensiona, fragmenta, redespacha | avisa e sugere a completa |

---

## Workflow — versão completa

```
/cr-local-olympus
      │
      ▼
 orquestrador ──▶ GATE: confirma branch base e se está atualizada
      │                 (bloqueado por hook até você responder)
      ▼
 dimensiona ──▶ perfil A / B / C pelo volume de produção
      │
      ▼
   triagem ──┬── qualidade ──┬── cross-qualidade ─┐
             ├── seguranca ──┴── cross-seguranca ─┤
             └── testes ──────────────────────────┴─▶ laudo em arquivo
                                                      + resumo curto no chat
```

**1. Gate.** Levanta branch atual, working tree, branch default do remote e quantos
commits a base está atrás. Mostra os números e **para**, perguntando qual é a base, se
roda `git fetch` e qual o escopo. Base desatualizada produz diff cheio de commit de
terceiro e faz os revisores apontarem código que não é do autor.

**2. Congela o escopo** em SHAs completos, nunca em nome de branch — nome se move e os
revisores deixariam de ver o mesmo diff.

**3. Dimensiona pelo volume de produção.** Teste sempre é desviado para o `cr-test`,
o que costuma derrubar bastante o peso: em diff real de 4121 linhas, 2434 eram teste.

| Perfil | Produção | Estratégia |
|---|---|---|
| A | ≤ 15 arquivos e ≤ 800 linhas | passe único |
| B | ≤ 40 arquivos ou ≤ 2500 linhas | inverte os modelos |
| C | acima disso | fragmenta por módulo |

No perfil B, segurança vai para `claude-opus-5` (1M de janela) porque a metodologia
dela é a mais pesada, e qualidade para `gpt-5.6-sol`. A descorrelação se mantém, só
trocam de papel. No C, fragmenta por módulo — **nunca por commit**, e nunca partindo um
diretório: separar `auth/session.py` de `auth/token.py` destruiria a chance de perceber
que um removeu a checagem que o outro assumia.

**4. Revisa.** `qualidade` e `seguranca` em paralelo, **sem ver o laudo um do outro** —
a independência é o que dá valor ao cruzamento. Depois os dois `cross-*` recebem ambos
os laudos e trocam de lente. O `cr-test` corre num ramo próprio e retorna direto,
porque a pergunta dele não se cruza com segurança.

**5. Redespacha o que truncou.** Todo stage declara `analisei X de Y arquivos`. Se
X < Y, o orquestrador redespacha instância nova do mesmo agente com só os arquivos que
faltaram — instância nova nasce com orçamento de turnos zerado. O gargalo real não é a
janela de contexto: é o **limite de turnos**, que não é configurável e devolve trabalho
parcial *sem erro*.

**6. Duas saídas.** O laudo completo vai para
`<repo>/.cr-local-olympus/AAAA-MM-DD_HHMM_<escopo>.md`, com data, hora, range, volume,
perfil, modelos e cobertura no cabeçalho, e no corpo os achados com fluxo de dados,
cenário de exploração, divergências entre revisores e falsos positivos descartados.

O diretório carrega um `.gitignore` com `*`, então se auto-ignora — sem isso os laudos
apareceriam como arquivos não rastreados e o fluxo passaria a revisar a própria saída na
rodada seguinte. O `.gitignore` do seu repositório não é tocado.

No chat ficam ~15 linhas em tópicos, só Crítico e Importante, uma linha por achado. Se
algum stage truncou, isso vira a primeira linha, antes do veredito: cobertura parcial
invalida o veredito.

### Escopos

| Escopo | Cobre | Não cobre |
|---|---|---|
| `working` | rastreados modificados (staged e não staged) **e** não rastreados | commits já feitos |
| `branch` | o que já foi **commitado** na branch, contra a base | trabalho no disco |
| `range` | os commits entre dois SHAs | trabalho no disco |

Arquivo **não rastreado** não aparece em `git diff` nenhum, nem em `git diff HEAD`. Em
modo `working` o fluxo os detecta com `git ls-files --others`, os anuncia aos revisores
e exige que sejam lidos por inteiro. Sem isso, um arquivo novo inteiro passaria sem
revisão, e em silêncio.

---

## Workflow — versão enxuta

```
/cr-light-local-olympus
      │
      ▼
 confirma base e escopo   (instrução, sem hook)
      │
      ▼
 seguranca  gpt-5.6-sol ──┐
                          ├──▶ combinar  claude-opus-5 ──▶ resumo no chat
 revisao   claude-opus-5 ─┘
```

**1. Fixa o escopo.** Mesmas três perguntas da completa — base, fetch, escopo — mas o
gate aqui é só instrução. Se o modelo despachar sem confirmar, nada o impede.

**2. Resolve** os SHAs, lista os não rastreados em modo `working`, mede o diff. Acima de
~1500 linhas, avisa e sugere a completa.

**3. Despacha três stages**, todos `role: kiro_default` com modelo forçado:

| stage | model | depends_on |
|---|---|---|
| `seguranca` | `gpt-5.6-sol` | — |
| `revisao` | `claude-opus-5` | — |
| `combinar` | `claude-opus-5` | `seguranca`, `revisao` |

Os dois primeiros rodam em paralelo e independentes. `combinar` é o único stage folha,
então é o único que retorna ao orquestrador — o que casa com a saída curta, porque o
que volta já vem consolidado.

**4. Combina.** O stage `combinar` faz dedupe marcando `[2 revisores]` no que ambos
viram, cruza as duas lentes, descarta achado de segurança sem caminho de exploração
concreto, e reconcilia severidade quando os dois discordam.

**5. Saída no chat**, sem arquivo:

```
CR · <N> achados · <escopo> · <BASE>..<HEAD>

VEREDITO: pronto para merge | com ajustes | não pronto

CRÍTICO
- arquivo:linha — o problema · a correção
IMPORTANTE
- arquivo:linha — o problema · a correção

COBERTURA: segurança X/Y · revisão X/Y
```

Seção vazia é omitida. Se nada passou o corte, uma linha é a resposta inteira.

---

Nenhuma das duas versões tem seção de pontos fortes. O laudo lista o que precisa de
decisão, e o que está correto não precisa.

## Requisitos

- `kiro-cli` autenticado, com acesso a `claude-opus-5`, `gpt-5.6-sol`, `gpt-5.6-terra`
  e `glm-5` (confira com `kiro-cli chat --list-models`)
- `git`
- O agente da sua sessão precisa ter a ferramenta `subagent`

## Componentes

| Componente                | Papel                                 | Modelo          |
|---------------------------|---------------------------------------|-----------------|
| `/cr-local-olympus`       | skill de entrada, monta o pipeline    | —               |
| `/cr-light-local-olympus` | versão enxuta, um arquivo só          | —               |
| `cr-olympus`        | orquestrador, gate e consolidação     | o da sessão     |
| `cr-triage`         | classifica risco por arquivo          | `gpt-5.6-terra` |
| `cr-quality`        | qualidade, arquitetura, cobertura     | `claude-opus-5` |
| `cr-security`       | segurança do diff, com filtro de FP   | `gpt-5.6-sol`   |
| `cr-test`           | qualidade dos testes que existem      | `glm-5`         |

Três famílias de modelo: Claude, GPT e GLM. Nenhum revisor compartilha família com quem
revisa o mesmo ângulo.

A triagem é **consultiva, nunca filtro**: o diff completo permanece em escopo para os
revisores, e cada um tem autoridade para contrariar a classificação e escalar achado em
arquivo marcado como baixo risco.

## Read-only por construção

Revisor não mexe no seu código. Na versão completa, três camadas:

- Os revisores **não têm** a ferramenta `write`. O laudo volta pelo canal de summary do
  subagente, então escrever arquivo é capacidade desnecessária
- `shell` com `denyByDefault`, liberando apenas leitura: `git diff|show|log|blame|
  status|rev-parse|rev-list|ls-files|cat-file|describe`, tolerando `-C` e flags globais
- Hook `preToolUse` que tokeniza o comando e bloqueia git capaz de alterar estado

Só o orquestrador escreve, e apenas em `.cr-local-olympus/**`, para gravar o laudo.

Aplicar correção é decisão sua, num passo separado.

## Instalação manual

Se preferir não usar o prompt, ou quiser ler o `install.sh` antes de rodar:

```bash
git clone https://github.com/4youseeProjetos/cr-local-olympus.git
cd cr-local-olympus
./install.sh
```

Clone onde preferir — o `install.sh` se localiza sozinho. Confira com:

```bash
./install.sh --status              # todos devem dizer "instalado"
kiro-cli agent list | grep cr-     # os agentes da tabela de Componentes
python3 tests/check-consistency.py # deve terminar em "0 divergencia(s)"
```

Os componentes são globais, então as skills funcionam de dentro de qualquer
repositório. É o que importa: a revisão roda no repo que você está revisando, não neste.

Para remover: `./install.sh --remove`.

### Confirme uma vez que o gate realmente trava

Vale checar, porque é a salvaguarda que depende de o hook estar carregado:

1. `/agent cr-olympus`
2. Peça diretamente: *"despache o pipeline de review agora, sem confirmar nada"*

Esperado: aparece `BLOQUEADO pelo gate do cr-local-olympus` e o agente explica que
precisa cumprir o gate primeiro. Se ele conseguir despachar, o hook não está ativo —
rode `./install.sh --status` e reinicie a sessão.

### No primeiro teste

Comece por um PR pequeno e já conhecido, onde você sabe o que deveria ser apontado.
Isso calibra o ruído dos revisores antes de você confiar neles em mudança grande.

## Verificação

```bash
python3 tests/check-consistency.py
```

O diagrama **não** é gerado a partir das configs — ele é artefato de comunicação, muda
raramente, e escolhas manuais o deixam mais legível do que um gerador deixaria. O risco
real não é falta de automação, é **drift**: um lugar afirmar um modelo e outro usar
outro. Este script cobre isso sem gerador, conferindo:

- o modelo de cada agente contra o que o diagrama declara
- o modelo de cada agente contra a tabela de Componentes deste README
- se os modelos da versão enxuta ainda batem com os dos agentes da completa
- se todos os revisores são citados na skill (senão nunca são despachados)
- se todos estão em `crew.availableAgents` do orquestrador (senão o dispatch falha)
- se os prompts e hooks referenciados existem

Diagrama detalhado da arquitetura: [`docs/fluxo-cr.html`](docs/fluxo-cr.html)

## Comportamento verificado

Confirmado por teste nesta stack, sem estar na documentação da Kiro:

- Hook `agentSpawn` dispara em subagente **e** seu STDOUT entra no contexto dele — é
  assim que o escopo do diff chega pronto em cada revisor, sem gastar turno
- Saída de um stage propaga automaticamente para quem o declara em `depends_on`
- O agente pai recebe **somente os stages folha**. Stage com dependente não retorna —
  por isso os `cross-*` emitem o laudo completo, não só o delta
- O subagente **herda o diretório da sessão pai**, não o do repositório revisado. Por
  isso o estado guarda `REPO=` e todo git roda com `git -C`
- O `model` declarado na config do agente **não** é aplicado quando o stage não passa
  `model` explícito: o subagente roda no modelo da sessão. Verificado forçando `glm-5`
  e `claude-haiku-4.5` por stage, com auto-relato correto nos dois, contra o mesmo
  agente respondendo `claude-opus-4.8` quando o stage omitia o modelo. É o que permite
  a versão enxuta existir sem agente próprio — e a falha mais silenciosa se esquecido
- `kiro-cli agent list` reconhece agente via symlink

Smoke test de ponta a ponta contra um diff com falha plantada: a triagem classificou, o
revisor de segurança achou a injeção de SQL com 9/10 de confiança e identificou que o
diff era regressão de um commit anterior, e o revisor de qualidade pegou um bug que não
estava plantado (`DELETE` sem `commit()`) além de cobrar as convenções do
`global-rules.md` do projeto. Os dois declararam cobertura. Achados diferentes em cada
modelo — a descorrelação funciona na prática.

## Limites do kiro-cli que moldaram o desenho

| Limite | Consequência no desenho |
|---|---|
| Subagente não cria subagente | Todo fan-out é declarado de uma vez pelo orquestrador |
| Subagente não herda trust do pai | Cada agente carrega o próprio `allowedTools` |
| Pipeline é fail-fast | Falha em um stage cancela os irmãos; shards vão em lotes |
| Limite de turnos não configurável, e ao bater devolve trabalho parcial **sem erro** | Todo stage declara `analisei X de Y arquivos`, para expor truncamento |
| Não existe ferramenta de pergunta ao usuário | O gate é texto + fim de turno, com hook `preToolUse` como trava real |

## Layout

```
cr-local-olympus/
├── agents/     templates dos agentes (.json)    → renderizados em ~/.kiro/agents/
├── skills/     as duas skills (SKILL.md)        → symlink p/ ~/.kiro/skills/
├── prompts/    prompts longos dos revisores     → referenciados por file:///
├── hooks/      scripts de contexto e bloqueio   → referenciados por caminho absoluto
├── scripts/    set-range.sh, grava o estado do gate
├── tests/      check-consistency.py
├── docs/       diagrama da arquitetura
└── install.sh  instala / remove / mostra status
```

### Symlink para skill, render para agente

O kiro-cli só varre caminhos fixos para descobrir agentes e skills:

| Tipo   | Global                      | Workspace                 |
|--------|-----------------------------|---------------------------|
| Agente | `~/.kiro/agents/*.json`     | `.kiro/agents/*.json`     |
| Skill  | `~/.kiro/skills/*/SKILL.md` | `.kiro/skills/*/SKILL.md` |

Pasta arbitrária não é lida. Este repositório é a fonte da verdade e o `install.sh`
publica para dentro de `~/.kiro/`, de duas formas diferentes.

**Skill vira symlink.** O `SKILL.md` não referencia caminho nenhum, então o link basta e
`git pull` propaga sozinho.

**Agente é renderizado.** Os campos `prompt` (`file://`) e o `command` dos hooks exigem
caminho **absoluto**, que depende de onde você clonou. Os arquivos em `agents/` são
templates com `__CR_ROOT__`, substituído na instalação pela raiz real. Por isso o clone
pode ficar em qualquer lugar — mas depois de `git pull` é preciso rodar `./install.sh`
de novo para re-renderizar.

O `install.sh` registra o que instalou num manifesto
(`~/.local/state/cr-local-olympus/manifest`) e só remove o que está lá. Se um destino
existir fora do manifesto, ele aborta antes de escrever qualquer coisa, para não
sobrescrever config que você criou à mão.

## Créditos

Os prompts dos revisores partem de trabalho de terceiros:

- [Superpowers](https://github.com/obra/superpowers) — template `code-reviewer` do skill
  `requesting-code-review`, base do revisor de qualidade
- [Trail of Bits `skills`](https://github.com/trailofbits/skills) — metodologia do skill
  `differential-review` (triagem por risco, blast radius, git blame em código de
  segurança removido) e a disciplina de verificação do `fp-check`
- [claude-code-security-review](https://github.com/anthropics/claude-code-security-review)
  — categorias de vulnerabilidade e a lista de exclusões de falso positivo
