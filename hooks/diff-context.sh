#!/usr/bin/env bash
#
# Hook agentSpawn dos revisores.
#
# Emite no STDOUT o repositório, o escopo e o resumo do diff. Verificado: em
# subagente o hook dispara e o STDOUT entra no contexto inicial dele — o revisor
# nasce sabendo o que revisar, sem gastar turno. Isso importa porque o limite de
# turnos do subagente não é configurável.
#
# Por que caminho absoluto e não CWD: verificado que o subagente herda o diretório
# da sessão pai, não o do repositório revisado. Depender de CWD faz o hook falhar em
# silêncio. O estado guarda REPO= e todo git roda com `git -C`.
#
# Dois modos, porque mudança não commitada não tem SHA:
#   committed  →  git diff BASE..HEAD
#   working    →  git diff BASE          (BASE = HEAD; compara commit com o disco)
#
# Arquivo não rastreado não aparece em git diff nenhum. Em modo working eles vêm
# listados no estado e são anunciados aqui, para o revisor ler por inteiro — do
# contrário um arquivo novo passaria batido, e em silêncio.
#
# Contrato do agentSpawn: exit 0 = STDOUT entra no contexto; outro = STDERR vira
# aviso ao usuário. Sempre sai 0 — degradar em silêncio é melhor que poluir a tela,
# e o revisor ainda tem o escopo no prompt de tarefa.

set -uo pipefail

readonly MAX_STAT_LINES=200
readonly STATE_FILE="${XDG_CACHE_HOME:-${HOME}/.cache}/cr-local-olympus/range"

note() { printf '[cr-local-olympus] %s\n' "$1"; }

fallback_to_prompt() {
  note "Escopo não pré-carregado: $1"
  printf 'Use o repositório e o escopo que vieram no seu prompt de tarefa.\n'
}

read_field()  { sed -n "s/^$1=//p" "$STATE_FILE" | head -1; }
read_repeated() { sed -n "s/^$1=//p" "$STATE_FILE"; }

announce_untracked() {
  local repo="$1" count paths
  paths="$(read_repeated UNTRACKED)"
  [[ -n "$paths" ]] || return 0
  count="$(wc -l <<<"$paths")"

  printf '\nATENÇÃO — %s arquivo(s) NÃO RASTREADO(S), invisíveis a qualquer git diff:\n' "$count"
  sed 's|^|  |' <<<"$paths"
  cat <<EOF

Trate cada um como arquivo inteiramente novo e leia o conteúdo completo com a
ferramenta de leitura, em ${repo}/<caminho>. Ignorá-los deixaria código novo sem
revisão nenhuma.
EOF
}

emit_inspection_help() {
  local repo="$1" mode="$2" args="$3"
  printf '\nO escopo completo está sob revisão. Todo git seu precisa de -C, porque seu\n'
  printf 'diretório de trabalho não é o do repositório:\n\n'
  printf '  git -C %s diff %s\n' "$repo" "$args"
  printf '  git -C %s diff --stat %s\n' "$repo" "$args"
  if [[ "$mode" == committed ]]; then
    printf '  git -C %s log --oneline %s\n' "$repo" "$args"
    printf '  git -C %s blame <arquivo>\n' "$repo"
  else
    printf '  git -C %s status --short\n' "$repo"
    printf '  git -C %s blame <arquivo>\n' "$repo"
  fi
}

main() {
  cat >/dev/null 2>&1 || true   # drena o evento JSON do stdin

  [[ -r "$STATE_FILE" && -s "$STATE_FILE" ]] || {
    fallback_to_prompt "estado ausente em ${STATE_FILE}"
    return 0
  }

  local mode repo args
  mode="$(read_field MODE)"
  repo="$(read_field REPO)"
  args="$(read_field DIFF_ARGS)"

  [[ -n "$mode" && -n "$repo" && -n "$args" ]] || {
    fallback_to_prompt "estado malformado (esperado MODE=, REPO=, DIFF_ARGS=)"
    return 0
  }

  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || {
    fallback_to_prompt "REPO=${repo} não é um repositório git"
    return 0
  }

  note "Escopo desta revisão"
  if [[ "$mode" == working ]]; then
    printf 'MODO=working — mudanças ainda NÃO commitadas, do commit %s contra o disco\n' "$args"
  else
    printf 'MODO=committed — diff entre commits\n'
  fi
  printf 'REPO=%s\nDIFF_ARGS=%s\n\n' "$repo" "$args"

  printf 'Arquivos alterados:\n'
  git -C "$repo" diff --stat "$args" 2>/dev/null | head -n "$MAX_STAT_LINES" \
    || printf '(stat indisponível — gere com git diff no seu turno)\n'

  announce_untracked "$repo"
  emit_inspection_help "$repo" "$mode" "$args"
}

main "$@"
