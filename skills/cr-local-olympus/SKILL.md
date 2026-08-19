---
name: cr-local-olympus
description: Code review do PR local por dois revisores independentes — um de qualidade e arquitetura, um de segurança — em modelos de famílias diferentes. Use antes de abrir PR, antes de merge, ou quando quiser uma segunda leitura de mudanças ainda não commitadas.
---

# Code review local — dois revisores independentes

Escopo pedido pelo usuário (pode vir vazio): **$ARGUMENTS**

Você é o orquestrador. Não revise o código você mesmo — sua função é resolver a
base do diff com o usuário, despachar o pipeline e consolidar os laudos.

---

## Fase 1 — Gate: resolver a base do diff

**Não despache nenhum subagente antes de o usuário confirmar a base.** Um
`origin/main` desatualizado produz um diff cheio de commit de terceiro, e isso
contamina as duas revisões — os revisores vão apontar problema em código que não
é do autor.

Levante o estado atual e mostre o resultado:

```bash
git rev-parse --abbrev-ref HEAD                          # branch atual
git status --short                                       # working tree sujo?
git symbolic-ref --quiet refs/remotes/origin/HEAD \
  | sed 's@^refs/remotes/origin/@@'                      # branch default do remote
git log -1 --format='%h %cr' origin/<base>               # quão velha é a base local
git rev-list --left-right --count origin/<base>...HEAD   # atrás/à frente
```

Se `git symbolic-ref` falhar, tente `git remote show origin | grep 'HEAD branch'`.
Se ainda falhar, não adivinhe — pergunte.

Agora **pergunte ao usuário em texto e encerre o turno**. Não existe ferramenta de
pergunta no kiro-cli; o gate é você escrever a pergunta e parar.

Traga os números levantados e peça três confirmações:

1. **Branch base** — confirmado `origin/<detectada>`, ou é outra?
2. **Atualização** — a base local está N commits atrás. Rodar `git fetch` antes de
   comparar? (Recomende sim se N > 0.)
3. **Escopo** — qual dos três:
   - `working` — o que **ainda não foi commitado**: modificações rastreadas (staged
     e não staged) **mais** os arquivos não rastreados
   - `branch` — a branch inteira contra a base, ou seja só o que já foi commitado
   - `range` — intervalo explícito entre dois commits

   Deixe claro para o usuário o que cada um cobre. `branch` e `range` **ignoram
   trabalho não commitado**; se o working tree estiver sujo e ele escolher um desses,
   avise que o que está no disco não será revisado.

Se `$ARGUMENTS` já indicar escopo ou branch, use como sugestão pré-preenchida —
mas ainda confirme. Se o usuário já respondeu tudo na mesma mensagem, siga sem
perguntar de novo.

## Fase 2 — Congelar o range e gravar o estado

Depois do ok:

1. Rode `git fetch` se autorizado.
2. Resolva e **fixe** `BASE` e `HEAD` em SHAs concretos, não em nomes de branch.
   Nome de branch se move; SHA não. Todos os stages têm que ver exatamente o mesmo
   diff, senão os laudos não são comparáveis.
3. Grave o estado com o script. O hook de gate barra o dispatch até este estado
   existir e ser válido, e o hook de contexto dos revisores lê dele:

```bash
# escopo branch ou range — só o que foi commitado
<RAIZ>/scripts/set-range.sh committed "$REPO" "$BASE_SHA" "$HEAD_SHA"

# escopo working — o que está no disco e ainda não foi commitado
<RAIZ>/scripts/set-range.sh working "$REPO"
```

Descubra a raiz pelo caminho do seu próprio hook de gate, ou pergunte ao usuário.
O script valida repo e refs, resolve nome de branch para SHA completo, grava
`~/.cache/cr-local-olympus/range` e imprime o `--stat`.

**Arquivo não rastreado não aparece em `git diff` nenhum.** Em modo `working` o
script os lista no estado e o hook de contexto os anuncia aos revisores, que devem
lê-los por inteiro. Repita essa lista no `prompt_template` — arquivo novo sem revisão
é a pior falha silenciosa possível aqui.

O estado vale por 1 hora — passado isso o gate volta a bloquear, porque o working
tree pode ter mudado e revisar diff obsoleto é pior que não revisar.

4. Rode `git diff --stat BASE..HEAD` e mostre o tamanho.
5. Se o diff estiver vazio, **pare** e diga isso. Não despache pipeline vazio.
6. Se passar de ~2000 linhas alteradas, avise que o `cr-security` roda em
   `gpt-5.6-sol` com janela de 272k e pode truncar — ofereça estreitar o escopo ou
   inverter os modelos entre os dois revisores.

### O diretório de trabalho dos subagentes

Verificado: o subagente **herda o diretório da sessão pai**, não o do repositório.
Se sua sessão não foi aberta dentro do repo, `git diff` puro falha lá dentro.

Por isso todo comando git nos prompts dos stages usa `-C` com o caminho absoluto:

```
git -C <REPO> diff <BASE>..<HEAD>
```

Os revisores já recebem essa instrução pelo hook de contexto, mas repita o caminho
absoluto no `prompt_template` — não confie em um só canal.

## Fase 3 — Dimensionar o pipeline pelo tamanho

Meça antes de despachar, e **separe teste de produção na contagem**:

```bash
git -C <REPO> diff --numstat <DIFF_ARGS>
```

Classifique como teste o que casar com o padrão do projeto — `test_*`, `*_test.*`,
`*.test.*`, `*.spec.*`, `tests/`, `test/`, `spec/`, `__tests__/`, `*Test.java`,
`conftest.py`, fixtures. Confirme o padrão olhando a árvore, não presuma.

Some separadamente: arquivos e linhas de **produção**, arquivos e linhas de **teste**.

Teste vai para o `cr-test`, que roda em paralelo. Isso normalmente derruba o volume
que os revisores caros enxergam — em diff real de 4121 linhas, 2434 eram teste, ou
seja 59% do peso saía do escopo deles só com esse roteamento.

Escolha o perfil pela contagem de **produção**:

| Perfil | Produção | Estratégia |
|---|---|---|
| **A** pequeno | ≤ 15 arquivos e ≤ 800 linhas | um passe, modelos padrão |
| **B** médio | ≤ 40 arquivos ou ≤ 2500 linhas | um passe, **modelos invertidos** |
| **C** grande | acima disso | **fragmentar por módulo** |

**Perfil B — inverter os modelos.** `cr-security` passa para `claude-opus-5` (janela
de 1M) e `cr-quality` para `gpt-5.6-sol` (272k). A metodologia de segurança é a mais
pesada — lê arquivo ao redor, roda `git blame` no que foi removido, rastreia quem
chama o que mudou — então ela fica com a janela maior. A descorrelação se mantém:
continua um Claude contra um GPT, só trocam de papel.

**Perfil C — fragmentar.** Peça à triagem que proponha os grupos, porque ela já leu o
diff inteiro e conhece os módulos. Regras do corte:

- Agrupe por diretório ou módulo. **Nunca parta um diretório** entre shards: separar
  `auth/session.py` de `auth/token.py` destrói a chance de perceber que um removeu a
  checagem que o outro assumia.
- Mire em ≤ 12 arquivos e ≤ 800 linhas de produção por shard.
- Todo shard recebe a **lista completa** de arquivos alterados, com o subconjunto dele
  marcado. Sem isso ele não sabe o que existe fora e não consegue dizer "preciso ver X,
  que não está comigo".
- **Não fragmente por commit.** Vulnerabilidade introduzida num commit cujo call site
  muda em outro fica partida entre shards, e cada um vê meia história. Pior: revisar
  commit a commit revisa estados intermediários que nunca existiram em produção. A
  unidade revisável é o diff final.

**Despache cada shard como uma chamada separada** de `subagent`, não tudo num DAG só.
O pipeline é fail-fast, e com muitos shards num único DAG uma falha cancela todos os
irmãos. Em lotes, uma falha custa um lote.

Diga ao usuário o perfil escolhido, quantos shards e o custo aproximado antes de
disparar: cada shard são duas execuções a 2,2x e 2,4x de crédito.

## Fase 4 — Despachar o pipeline

Uma única chamada da ferramenta `subagent`. Os stages folha retornam para você.

| stage | role | model (perfil A) | depends_on |
|---|---|---|---|
| `triagem` | `cr-triage` | `gpt-5.6-terra` | — |
| `qualidade` | `cr-quality` | `claude-opus-5` | `triagem` |
| `seguranca` | `cr-security` | `gpt-5.6-sol` | `triagem` |
| `testes` | `cr-test` | `glm-5` | `triagem` |
| `cross-qualidade` | `cr-quality` | `claude-opus-5` | `qualidade`, `seguranca` |
| `cross-seguranca` | `cr-security` | `gpt-5.6-sol` | `qualidade`, `seguranca` |

No perfil B, troque os modelos de `qualidade`/`cross-qualidade` e
`seguranca`/`cross-seguranca` entre si. O `cr-test` fica em `glm-5` sempre.

`qualidade`, `seguranca` e `testes` rodam em paralelo, e os dois primeiros **não
veem o laudo um do outro** — a independência é o que dá valor ao cross-check. Os
stages `cross-*` recebem os dois laudos automaticamente por dependência.

O `testes` é folha e retorna direto para você. Ele não entra no cross-check: a
pergunta dele ("estes testes provam algo?") não se cruza com a de segurança.

### Escopo de cada stage

Não é o mesmo para todos, e isso é deliberado:

- `seguranca` — só produção. Arquivo que existe apenas para teste não é reportável
  como vulnerabilidade, então incluí-lo é gasto de contexto sem retorno.
- `qualidade` — **produção e teste**. Ele é quem responde "o código novo tem teste?",
  e ausência de teste só se detecta vendo os dois lados.
- `testes` — arquivos de teste, **mais a lista** dos arquivos de produção alterados.
  Ele julga a qualidade dos testes que existem; a lista serve só para ele cruzar e
  apontar símbolo novo sem teste, em uma linha.

Regras para montar os `prompt_template`:

- **Sempre embuta os SHAs literais** de `BASE..HEAD` no texto de cada stage. Não
  escreva "o range confirmado"; escreva os SHAs.
- **Sempre embuta o caminho do repositório** e instrua `git -C <REPO>`.
- Repasse a saída da triagem como **prioridade de leitura, nunca como filtro**.
  Deixe explícito no prompt: o diff completo do escopo daquele stage permanece sob
  revisão, e o revisor tem autoridade para contrariar a triagem e escalar achado em
  arquivo marcado BAIXO.
- Em modo `working`, repasse a lista de arquivos **não rastreados** — eles não
  aparecem em `git diff` e precisam ser lidos por inteiro.
- Exija de todo stage: **declarar cobertura** no formato `analisei X de Y arquivos`.
  Subagente tem limite de turnos não configurável e, se bater, devolve trabalho
  parcial sem erro. A linha de cobertura é como você detecta truncamento.
- Nos stages `cross-*`, defina a troca de lente:
  - `cross-seguranca`: os achados de qualidade têm impacto de segurança que passou
    batido? E aplique filtro de falso positivo aos seus próprios achados —
    descarte o que estiver abaixo de 80% de confiança.
  - `cross-qualidade`: as correções propostas pela segurança quebram design,
    testes ou performance? Alguma é YAGNI sobre código que ninguém chama?

### Se algum stage voltar truncado, redespache

Depois de cada rodada, leia a linha `analisei X de Y` de **todos** os stages. Se
algum tiver X < Y, o subagente bateu o limite de turnos e devolveu trabalho parcial.

Nesse caso, redespache uma instância nova do **mesmo** agente com apenas os arquivos
que ficaram de fora. Instância nova nasce com orçamento de turnos e contexto zerados,
então o que não caberia num passe cabe em dois.

No máximo duas rodadas de recuperação. Se ainda voltar incompleto, pare e diga ao
usuário quais arquivos não foram revisados — nunca apresente cobertura parcial como
se fosse revisão completa.

Isso é mais confiável que tentar acertar o tamanho do shard de antemão, porque o
limite de turnos não é documentado nem observável: aqui a própria instrumentação de
cobertura vira o gatilho da correção.

### Os stages cross-* têm que emitir o laudo completo

Verificado: **você só recebe a saída dos stages folha**. Stage que tem dependente
não retorna para você. No pipeline acima, isso significa que `triagem`, `qualidade`
e `seguranca` **não chegam até você** — só `cross-qualidade` e `cross-seguranca`.

Então instrua cada `cross-*` a devolver o laudo **inteiro e já revisado**, não
apenas o delta: cada achado que sobreviveu, com `arquivo:linha`, severidade final e
justificativa, mais a lista do que foi descartado e por quê, mais a linha de
cobertura da rodada 1 que ele recebeu.

Se você precisar dos laudos crus da rodada 1 no relatório, peça explicitamente que
os `cross-*` os reproduzam — não há outro caminho para eles chegarem a você.

O pipeline é **fail-fast**: se um stage falhar, os irmãos em execução são
cancelados. Se isso acontecer, diga qual stage caiu e o motivo — não apresente
resultado parcial como se fosse revisão completa.

## Fase 5 — Consolidar

Junte os laudos — os dois do cross-check mais o de testes — em **um** relatório:

- **Dedupe** — achado que os dois apontaram vira um item, marcado como confirmado
  em dupla. Concordância entre modelos de famílias diferentes é o sinal mais forte
  que este fluxo produz; destaque.
- **Divergência** — quando um aponta e o outro refuta, mostre os dois lados e diga
  qual argumento é mais forte e por quê. Não silencie o desacordo.
- **Severidade** — Crítico / Importante / Menor. Calibre: não é tudo crítico.
- **Cobertura** — reproduza as linhas `analisei X de Y` de cada stage. Se algum
  não cobriu tudo, diga na abertura do relatório.
- **Testes** — seção própria com o laudo do `cr-test`. Não dilua os achados dele
  nos outros: a pergunta "os testes provam algo?" tem resposta independente de
  "o código está correto?", e misturar as duas esconde suíte fraca sob código bom.
- **Perfil e shards** — diga qual perfil de tamanho foi usado e, se houve
  fragmentação, quantos shards e se algum achado cruzou fronteira de shard.
- **Veredito** — pronto para merge / com ajustes / não.

Cada item precisa de referência `arquivo:linha`, o que está errado, por que
importa, e como corrigir se não for óbvio.

Ao final, pergunte se o usuário quer que você aplique alguma correção. **Você não
aplica nada sem pedido explícito** — este fluxo é de leitura.

---

## Dependências

Os quatro agentes revisores precisam estar instalados (`./install.sh` na raiz do
clone): `cr-triage`, `cr-quality`, `cr-security`, `cr-test`. Confira com
`kiro-cli agent list`.

Se algum estiver faltando, pare e avise — não substitua por outro agente nem
tente revisar você mesmo, porque isso perde o read-only e a diversidade de modelo,
que são a razão de existir deste fluxo.
