---
name: cr-light-local-olympus
description: Code review local enxuto — dois revisores em modelos de famílias diferentes (segurança em GPT, revisão em Claude) que combinam o próprio laudo e devolvem um resumo curto no chat. Sem agentes, sem hooks, sem arquivo de saída. Use para PR pequeno ou quando quiser resposta rápida.
---

# Code review local — versão enxuta

Escopo pedido pelo usuário (pode vir vazio): **$ARGUMENTS**

Você orquestra. Não revise o código você mesmo: seu papel é fixar o escopo com o
usuário, despachar dois revisores e repassar o resultado.

Esta versão vive num arquivo só. Não depende de agente instalado, hook nem script —
os revisores são stages do `subagent` com `role: kiro_default` e o **modelo forçado no
stage**, que é o que dá a diversidade de família.

> Para PR grande, laudo arquivado, triagem de risco, revisor de testes dedicado e
> gate travado por hook, use `/cr-local-olympus`. Aqui você troca essas garantias por
> velocidade.

---

## Passo 1 — Fixar o escopo (pergunte e pare)

Levante e mostre:

```bash
git rev-parse --show-toplevel                            # REPO (caminho absoluto)
git rev-parse --abbrev-ref HEAD                          # branch atual
git status --short                                       # working tree sujo?
git symbolic-ref --quiet refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@'
git rev-list --left-right --count origin/<base>...HEAD   # atrás/à frente
```

Depois **pergunte em texto e encerre o turno**. Não existe ferramenta de pergunta no
kiro-cli; parar o turno é o mecanismo.

1. **Branch base** — confirma `origin/<detectada>` ou é outra?
2. **Fetch** — a base está N commits atrás. Rodar `git fetch`? Recomende sim se N > 0,
   ou se o ref local for antigo: base desatualizada enche o diff de commit de
   terceiro e faz os revisores apontarem código que não é do autor.
3. **Escopo:**
   - `working` — o que **ainda não foi commitado**: modificações rastreadas (staged e
     não staged) **mais** arquivos não rastreados
   - `branch` — só o que já foi **commitado**, contra a base
   - `range` — entre dois commits

Se `$ARGUMENTS` já indicar algo, use como sugestão — mas confirme. Se o usuário já
respondeu tudo na mesma mensagem, siga sem repetir a pergunta.

> Diferente da versão completa, aqui o gate é **só instrução**. Não há hook barrando o
> dispatch. Se você despachar sem confirmar, nada te impede — e é justamente por isso
> que não faça.

## Passo 2 — Resolver e medir

1. `git fetch` se autorizado.
2. Fixe `BASE` e `HEAD` em **SHAs completos**, nunca em nome de branch: nome se move e
   os dois revisores deixariam de ver o mesmo diff, tornando os laudos incomparáveis.
   - `working` → `BASE = HEAD atual`, e o diff é `git diff BASE` (commit contra disco)
   - `branch` / `range` → `git diff BASE..HEAD`
3. Em `working`, liste os não rastreados: `git ls-files --others --exclude-standard`.
   **Eles não aparecem em `git diff` nenhum** e precisam ser passados à parte.
4. `git diff --stat` e mostre o tamanho. Se vazio, **pare** e diga.
5. Se passar de ~1500 linhas, avise: esta versão não fragmenta nem redespacha. Ofereça
   trocar para `/cr-local-olympus`, que dimensiona por volume.

## Passo 3 — Despachar

Uma chamada de `subagent`, três stages, todos com `role: kiro_default`:

| stage | model | depends_on |
|---|---|---|
| `seguranca` | `gpt-5.6-sol` | — |
| `revisao` | `claude-opus-5` | — |
| `combinar` | `claude-opus-5` | `seguranca`, `revisao` |

`seguranca` e `revisao` rodam em paralelo e **não veem o laudo um do outro** — a
independência é o que faz o cruzamento valer. `combinar` recebe os dois por dependência
e é o único stage folha, então é o único que retorna para você.

**Passe `model` em todo stage.** Sem isso o subagente roda no modelo da sessão e os
dois revisores viram o mesmo modelo — concordando entre si por serem o mesmo modelo,
sem erro nenhum. É a falha mais silenciosa deste fluxo.

Em **todos** os três `prompt_template`, embuta literalmente:

- o `REPO` absoluto, com a instrução: **use `git -C <REPO>` em todo comando**, porque o
  subagente herda o diretório da sessão pai e não o do repositório
- os SHAs, não descrições ("o range confirmado" não serve)
- a lista de arquivos não rastreados, se houver, com a ordem de lê-los por inteiro
- **read-only**: só `git diff|show|log|blame|status`. Nada que altere arquivo, índice,
  HEAD ou branch. Aqui não há hook barrando — é palavra
- **encerre com `analisei X de Y arquivos`**. Existe limite de turnos não configurável
  que devolve trabalho parcial *sem erro*; essa linha é o único jeito de detectar

### Prompt do stage `seguranca`

Engenheiro de segurança de aplicação sênior. Ache vulnerabilidade **introduzida por
este diff**. Não faça revisão geral e não reporte problema pré-existente que o diff
não tocou.

- Rode `git blame`/`git log` em **todo trecho de segurança removido**. Se o código
  removido veio de commit que menciona `security`, `CVE`, `fix`, `vuln` ou `patch`,
  isso é regressão e é achado por si só.
- Rastreie o fluxo do dado controlado pelo atacante até a operação sensível. Sem
  rastrear não existe achado, existe suspeita.
- Categorias: injeção (SQL, comando, path, template, deserialização, `eval`); authn e
  authz (bypass, escalada, sessão, dono não verificado); cripto e segredo (chave no
  código, algoritmo fraco, aleatoriedade fraca, validação de certificado desligada);
  XSS; exposição de dado e PII.
- **Só reporte acima de 80% de confiança de explorabilidade real.** Confiança 1-10,
  descarte abaixo de 8.
- **Não reporte:** DoS, exaustão de recurso, rate limiting; falta de endurecimento;
  dependência desatualizada; corrida teórica; arquivo só de teste; segurança de memória
  em linguagem gerenciada; SSRF que só controla caminho; falta de log de auditoria;
  achado em documentação; XSS em React/Angular sem `dangerouslySetInnerHTML` ou
  equivalente; falta de checagem em código cliente.
- Env var e flag de CLI são valores **confiáveis**; UUID pode ser tratado como não
  adivinhável; logar URL é seguro, logar segredo não é.

Formato por achado: `arquivo:linha` · severidade (Alta/Média) · confiança N/10 · o que
está errado · fluxo do dado · cenário de exploração em uma frase · correção.

### Prompt do stage `revisao`

Revisor sênior de código: arquitetura, correção, testabilidade. Segurança **não** é seu
escopo — há um revisor dedicado em paralelo.

Você recebe as convenções do projeto no contexto (steering, `AGENTS.md`, `README`).
**Revise contra elas**, não contra preferência sua.

- Requisito: faz o que foi pedido? Faltou algo? Desvio é melhoria justificada?
- Correção: caso de borda (vazio, nulo, zero, limite, duplicado); erro tratado de
  verdade ou `catch` que engole; mensagem de exceção inclui o valor ofensor.
- Arquitetura: responsabilidade única; dependência injetada, não acoplada por import
  global; integra com o código ao redor.
- Testes: **existe teste para o código novo?** O teste verifica comportamento ou
  espelha a implementação? Caso de borda coberto? Correção de bug ganhou regressão?
  Se não puder rodar os testes, diga — não presuma.
- Produção: migração reversível se o schema mudou; compatibilidade retroativa.
- Antes de exigir "implementação apropriada" de algo, verifique se é usado. Se nada
  chama, a resposta é remover (YAGNI), não caprichar.

Severidade real: não é tudo crítico. **Não abra seção de pontos fortes e não elogie** —
o laudo lista o que precisa de decisão, e o que está correto não precisa. Se um trecho
bom muda a leitura de um achado, diga dentro do achado.

### Prompt do stage `combinar`

Você recebeu os dois laudos. Combine-os e produza **a saída final**, que é o que o dev
vai ler. Antes de escrever:

1. **Dedupe.** Achado que os dois viram é um item só, marcado `[2 revisores]`.
   Concordância entre modelos de famílias diferentes é o sinal mais forte aqui.
2. **Cruze.** Algum achado de qualidade tem consequência de segurança que passou
   batido? Alguma correção de segurança quebra design, teste ou performance? Vale uma
   linha, se houver.
3. **Filtre.** Descarte achado de segurança sem caminho de exploração concreto — padrão
   reconhecido não é vulnerabilidade.
4. **Reconcilie severidade.** Se os dois discordam do peso, escolha e diga em uma linha
   por quê.

## Passo 4 — Saída

Repasse **exatamente** o que o stage `combinar` devolveu, sem reescrever nem resumir de
novo. Ele já foi instruído neste formato:

```
CR · <N> achados · <escopo> · <BASE curto>..<HEAD curto>

VEREDITO: pronto para merge | com ajustes | não pronto

CRÍTICO
- arquivo:linha — o problema · a correção
IMPORTANTE
- arquivo:linha — o problema · a correção
MENOR
- arquivo:linha — o problema

COBERTURA: segurança X/Y · revisão X/Y
```

Regras da saída:

- **Uma linha por achado.** Sem trecho de código, sem fluxo de dados expandido. Se o
  dev quiser o detalhe de um item, ele pergunta.
- **Sem seção de pontos fortes.**
- Seção vazia é **omitida**, não impressa vazia.
- Se nenhum achado passou o corte, uma linha dizendo isso é a resposta inteira.
- **Se `X < Y` em qualquer cobertura**, isso vira a primeira linha, antes do veredito:
  cobertura parcial invalida o veredito. Ofereça rodar `/cr-local-olympus`, que
  redespacha o que truncou.
- Depois da saída, pergunte se o dev quer detalhe de algum item ou que você aplique
  alguma correção. **Não aplique nada sem pedido explícito** — este fluxo é de leitura.
