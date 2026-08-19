#!/usr/bin/env bash
#
# Hook preToolUse do orquestrador, matcher: subagent
#
# Transforma o gate de instrução em trava de engine. Sem isto, "confirme a base
# antes de despachar" é só texto no prompt e o modelo pode atropelar. Com exit 2 o
# kiro-cli bloqueia a ferramenta e devolve o STDERR ao modelo.
#
# Libera quando o estado existir, apontar para um repositório git real, com SHAs que
# existem nele, e for recente.
#
# Contrato do preToolUse:
#   0 = libera
#   2 = BLOQUEIA e manda STDERR ao modelo
#   outro = libera com aviso  (evitar: falharia aberto)

set -uo pipefail

# O working tree pode ter mudado desde a confirmação. Revisar diff obsoleto é pior
# que não revisar, porque o laudo parece válido.
readonly MAX_AGE_SECONDS=3600
readonly STATE_FILE="${XDG_CACHE_HOME:-${HOME}/.cache}/cr-local-olympus/range"

block() {
  printf 'BLOQUEADO pelo gate do cr-local-olympus.\n\n%s\n' "$1" >&2
  exit 2
}

read_field() { sed -n "s/^$1=//p" "$STATE_FILE" | head -1; }

require_state_present() {
  [[ -r "$STATE_FILE" && -s "$STATE_FILE" ]] && return 0
  block \
"A base do diff ainda não foi confirmada com o usuário.

Cumpra o gate antes de despachar:

  1. Levante branch atual, working tree, branch default do remote e quantos
     commits a base local está atrás.
  2. Mostre os números e PERGUNTE ao usuário: qual branch base, se roda
     git fetch, e o escopo (working / branch / range). Encerre o turno.
  3. Depois do ok, resolva os SHAs e grave o estado:

     <raiz>/scripts/set-range.sh committed <repo> <base_sha> <head_sha>
     <raiz>/scripts/set-range.sh working   <repo>

     Use 'working' para mudanças ainda não commitadas, 'committed' para diff
     entre commits. <repo> é a saída de: git rev-parse --show-toplevel

Só então despache o pipeline."
}

require_valid_repo() {
  local repo="$1"
  [[ -n "$repo" ]] || block \
"Estado sem REPO=. Grave o caminho absoluto do repositório (git rev-parse --show-toplevel)."
  [[ -d "$repo" ]] || block "REPO=${repo} não existe como diretório."
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || block \
"REPO=${repo} não é um repositório git."
}

require_valid_shas() {
  local repo="$1" ref
  shift
  for ref in "$@"; do
    [[ -n "$ref" ]] || block \
"Estado incompleto: falta BASE= (ou HEAD= em modo committed)."
    git -C "$repo" rev-parse --verify --quiet "$ref" >/dev/null || block \
"O escopo aponta para '${ref}', que não existe em ${repo}.
Rode git fetch e resolva o escopo novamente."
  done
}

# Dois modos porque mudança não commitada não tem SHA:
#   committed  exige BASE e HEAD
#   working    exige só BASE (o HEAD atual), comparado contra o disco
require_valid_mode() {
  local mode="$1" repo="$2" base="$3" head="$4"
  case "$mode" in
    committed)
      require_valid_shas "$repo" "$base" "$head"
      ;;
    working)
      require_valid_shas "$repo" "$base"
      git -C "$repo" diff --quiet HEAD && \
        [[ -z "$(git -C "$repo" ls-files --others --exclude-standard)" ]] && block \
"O escopo é 'working' mas o working tree de ${repo} está limpo agora.
Nada a revisar, ou o estado ficou obsoleto. Reconfirme com o usuário."
      ;;
    "")
      block "Estado sem MODE=. Regrave com scripts/set-range.sh, que preenche o modo."
      ;;
    *)
      block "MODE inválido no estado: '${mode}'. Esperado 'committed' ou 'working'."
      ;;
  esac
}

require_fresh() {
  local now mtime age
  now="$(date +%s)"
  mtime="$(stat -c %Y "$STATE_FILE" 2>/dev/null || echo "$now")"
  age=$(( now - mtime ))
  (( age <= MAX_AGE_SECONDS )) || block \
"A base foi confirmada há $(( age / 60 )) min, acima do limite de $(( MAX_AGE_SECONDS / 60 )) min.
O working tree pode ter mudado. Reconfirme com o usuário e regrave o estado."
}

main() {
  cat >/dev/null 2>&1 || true   # drena o evento JSON do stdin

  require_state_present

  local mode repo base head
  mode="$(read_field MODE)"
  repo="$(read_field REPO)"
  base="$(read_field BASE)"
  head="$(read_field HEAD)"

  require_valid_repo "$repo"
  require_valid_mode "$mode" "$repo" "$base" "$head"
  require_fresh

  exit 0
}

main "$@"
