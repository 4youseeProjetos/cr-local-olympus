# cr-local-olympus

Code review do seu PR local por **dois revisores independentes** no kiro-cli: um de
qualidade e arquitetura, um de segurança — rodando em **modelos de famílias
diferentes**, para que os pontos cegos não coincidam.

## O problema

Um revisor de IA sozinho tem dois vícios previsíveis: mistura preocupação de estilo
com risco de segurança, e não tem contraditório — o que ele afirma, fica.

Dois revisores no mesmo modelo não resolvem: eles erram junto e concordam entre si,
o que produz confiança falsa, o pior resultado possível numa revisão dupla.

Aqui os revisores têm escopos separados e modelos de fornecedores diferentes.
Depois, cada um lê o laudo do outro e é obrigado a confirmar ou refutar. Achado que
sobrevive à leitura de duas famílias de modelo é o sinal mais forte que o fluxo
produz.

## Como funciona

```
/cr-local-olympus
      │
      ▼
 orquestrador ──▶ GATE: confirma branch base e se está atualizada
      │                 (bloqueado por hook até você responder)
      ▼
   triagem ──┬── qualidade ──┬── cross-qualidade ─┐
             └── seguranca ──┴── cross-seguranca ─┴─▶ laudo único
```

`qualidade` e `seguranca` rodam em paralelo **sem ver o laudo um do outro** — a
independência é o que dá valor ao cross-check. Depois os dois stages `cross-*`
recebem ambos os laudos e trocam de lente.

Diagrama completo com modelos, janelas de contexto e guardas:
[`docs/fluxo-cr.html`](docs/fluxo-cr.html)

## Requisitos

- `kiro-cli` autenticado, com acesso a `claude-opus-5`, `gpt-5.6-sol` e `gpt-5.6-terra`
  (confira com `kiro-cli chat --list-models`)
- `git`
- O agente da sua sessão precisa ter a ferramenta `subagent` disponível

## Instalação

**1. Clone e instale** — onde preferir, o `install.sh` se localiza sozinho:

```bash
git clone https://github.com/4youseeProjetos/cr-local-olympus.git
cd cr-local-olympus
./install.sh
```

**2. Confira que os quatro agentes entraram:**

```bash
./install.sh --status              # todos devem dizer "instalado"
kiro-cli agent list | grep cr-     # cr-olympus, cr-quality, cr-security, cr-triage
python3 tests/check-consistency.py # deve terminar em "0 divergencia(s)"
```

**3. Reinicie a sessão do kiro-cli** — agente novo é carregado na inicialização.

Os componentes são globais, então o comando funciona de dentro de qualquer
repositório. É o que importa: a revisão roda no repo que você está revisando, não
neste.

Para atualizar: `git pull && ./install.sh`. O install é **obrigatório** no update,
porque os agentes são renderizados com o caminho do seu clone, não linkados.
Para remover: `./install.sh --remove`.

## Verificação

```bash
python3 tests/check-consistency.py
```

O diagrama **não** é gerado a partir das configs — ele é artefato de comunicação,
muda raramente, e escolhas manuais o deixam mais legível do que um gerador deixaria.
O risco real não é falta de automação, é **drift**: o diagrama afirmar um modelo e o
agente usar outro. Este script cobre isso sem gerador, conferindo quatro coisas:

- o modelo de cada agente contra o que o diagrama declara
- se todos os revisores são citados na skill (senão nunca são despachados)
- se todos estão em `crew.availableAgents` do orquestrador (senão o dispatch falha)
- se os prompts e hooks referenciados existem

## Uso

**Passo obrigatório:** entre no agente orquestrador antes de rodar a skill.

```
/agent cr-olympus
```

Ou `ctrl+shift+r`. Isto **não é opcional**: o hook que barra o dispatch antes da sua
confirmação vive na config do `cr-olympus`. Rodando de outro agente a skill funciona,
mas o gate passa a ser só instrução de texto, sem trava de engine.

Depois, **de dentro do repositório que quer revisar**:

```
/cr-local-olympus
```

O fluxo **para e pergunta** qual é a branch base, se ela está atualizada e qual o
escopo — working tree, branch inteira ou range de commits. Nada é despachado antes da
sua confirmação, porque base desatualizada produz diff cheio de commit de terceiro e
contamina as duas revisões.

Você pode adiantar o escopo: `/cr-local-olympus branch`, `/cr-local-olympus working`,
`/cr-local-olympus abc123..def456`. Ainda assim ele confirma.

### O que cada escopo cobre

| Escopo | Cobre | Não cobre |
|---|---|---|
| `working` | modificações rastreadas (staged e não staged) **e** arquivos não rastreados | commits já feitos |
| `branch` | tudo que já foi **commitado** na branch, contra a base | trabalho ainda no disco |
| `range` | os commits entre dois SHAs | trabalho ainda no disco |

`branch` e `range` revisam **apenas o que foi commitado**. Se seu working tree estiver
sujo e você escolher um desses, o que está no disco fica fora da revisão — o fluxo
avisa quando detecta isso.

Arquivo **não rastreado** não aparece em `git diff` nenhum, nem em `git diff HEAD`.
Em modo `working` o fluxo os detecta com `git ls-files --others`, os anuncia aos
revisores e exige que sejam lidos por inteiro. Sem isso, um arquivo novo inteiro
passaria sem revisão, e em silêncio.

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

**Confira a linha `analisei X de Y arquivos`** no fim de cada laudo. É como se detecta
que um revisor não cobriu tudo — o que pode acontecer em silêncio, porque o limite de
turnos do subagente não é configurável e, ao bater, ele devolve trabalho parcial sem
erro. Em diff acima de ~2000 linhas o `cr-security` também pode truncar por janela
(272k contra 1M do Claude); nesse caso estreite o escopo ou inverta os modelos.

## Componentes

| Componente          | Papel                                | Modelo          |
|---------------------|--------------------------------------|-----------------|
| `/cr-local-olympus` | skill de entrada, monta o pipeline   | —               |
| `cr-triage`         | classifica risco por arquivo         | `gpt-5.6-terra` |
| `cr-quality`        | qualidade, arquitetura, testes       | `claude-opus-5` |
| `cr-security`       | segurança do diff, com filtro de FP  | `gpt-5.6-sol`   |

A triagem é **consultiva, nunca filtro**: o diff completo permanece em escopo para
os dois revisores, e cada um tem autoridade para contrariar a classificação e
escalar achado em arquivo marcado como baixo risco.

## Read-only por construção

Revisor não mexe no seu código. Três camadas:

- Os revisores **não têm** a ferramenta `write`. O laudo volta pelo canal de summary
  do subagente, então escrever arquivo é capacidade desnecessária
- `shell` com `denyByDefault`, liberando apenas leitura: `git diff|show|log|blame|
  status|rev-parse|rev-list|ls-files|cat-file|describe`, tolerando `-C` e flags globais
- Hook `preToolUse` que tokeniza o comando e bloqueia git capaz de alterar estado,
  inclusive escondido em encadeamento (`git diff && git reset --hard`)

Aplicar correção é decisão sua, num passo separado.

## Comportamento verificado

Confirmado por teste nesta stack, sem estar na documentação da Kiro:

- Hook `agentSpawn` dispara em subagente **e** seu STDOUT entra no contexto dele —
  é assim que o range do diff chega pronto em cada revisor, sem gastar turno
- Saída de um stage propaga automaticamente para quem o declara em `depends_on`
- O agente pai recebe **somente os stages folha**. Stage com dependente não
  retorna — por isso os `cross-*` emitem o laudo completo, não só o delta
- O subagente **herda o diretório da sessão pai**, não o do repositório revisado.
  Por isso o estado guarda `REPO=` e todo git roda com `git -C`
- `kiro-cli agent list` reconhece agente via symlink

Smoke test de ponta a ponta contra um diff com falha plantada: a triagem classificou,
o revisor de segurança achou a injeção de SQL com 9/10 de confiança e identificou que
o diff era regressão de um commit anterior, e o revisor de qualidade pegou um bug que
não estava plantado (`DELETE` sem `commit()`) além de cobrar as convenções do
`global-rules.md` do projeto. Os dois declararam cobertura. Achados diferentes em
cada modelo — a descorrelação funciona na prática.

## Limites do kiro-cli que moldaram o desenho

| Limite | Consequência no desenho |
|---|---|
| Subagente não cria subagente | Todo fan-out é declarado de uma vez pelo orquestrador |
| Subagente não herda trust do pai | Cada agente carrega o próprio `allowedTools` |
| Pipeline é fail-fast | Falha em um stage cancela os irmãos em execução |
| Limite de turnos não configurável, e ao bater devolve trabalho parcial **sem erro** | Todo stage declara `analisei X de Y arquivos`, para expor truncamento |
| Não existe ferramenta de pergunta ao usuário | O gate é texto + fim de turno, com hook `preToolUse` como trava real |

## Layout

```
cr-local-olympus/
├── agents/     templates dos agentes (.json)    → renderizados em ~/.kiro/agents/
├── skills/     skill de entrada (SKILL.md)      → symlink p/ ~/.kiro/skills/
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

**Skill vira symlink.** O `SKILL.md` não referencia caminho nenhum, então o link
basta e `git pull` propaga sozinho.

**Agente é renderizado.** Os campos `prompt` (`file://`) e o `command` dos hooks
exigem caminho **absoluto**, que depende de onde você clonou. Os arquivos em
`agents/` são templates com `__CR_ROOT__`, substituído na instalação pela raiz real.
Por isso o clone pode ficar em qualquer lugar — mas depois de `git pull` é preciso
rodar `./install.sh` de novo para re-renderizar.

O `install.sh` registra o que instalou num manifesto
(`~/.local/state/cr-local-olympus/manifest`) e só remove o que está lá. Se um
destino existir fora do manifesto, ele aborta antes de escrever qualquer coisa, para
não sobrescrever config que você criou à mão.

## Créditos

Os prompts dos revisores partem de trabalho de terceiros:

- [Superpowers](https://github.com/obra/superpowers) — template `code-reviewer` do
  skill `requesting-code-review`, base do revisor de qualidade
- [Trail of Bits `skills`](https://github.com/trailofbits/skills) — metodologia do
  skill `differential-review` (triagem por risco, blast radius, git blame em código
  de segurança removido) e a disciplina de verificação do `fp-check`
- [claude-code-security-review](https://github.com/anthropics/claude-code-security-review)
  — categorias de vulnerabilidade e a lista de exclusões de falso positivo
