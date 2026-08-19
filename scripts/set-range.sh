#!/usr/bin/env bash
#
# Grava o estado do escopo confirmado, consumido por gate-dispatch.sh e
# diff-context.sh.
#
#   set-range.sh committed <repo> <base> <head>
#   set-range.sh working   <repo>
#
# Dois modos porque mudança não commitada não tem SHA:
#
#   committed  diff entre dois commits          → git diff BASE..HEAD
#   working    commit atual contra o disco      → git diff BASE   (BASE = HEAD)
#
# Existe como script, e não como `printf > arquivo` no prompt do orquestrador, para
# que o allowedCommands do cr-olympus libere exatamente esta operação sem
# auto-aprovar redirecionamento arbitrário de shell.
#
# Arquivo não rastreado não aparece em `git diff` nenhum. Em modo working eles são
# listados no estado, para que os revisores os leiam por inteiro — do contrário um
# arquivo novo passaria batido, e em silêncio.

set -euo pipefail

STATE_DIR="${XDG_CACHE_HOME:-${HOME}/.cache}/cr-local-olympus"
readonly STATE_DIR
readonly STATE_FILE="${STATE_DIR}/range"

die() { printf 'ERRO: %s\n' "$1" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
uso:
  set-range.sh committed <repo> <base> <head>   diff entre dois commits
  set-range.sh working   <repo>                 commit atual contra o working tree

Em modo committed, grave SHAs e não nomes de branch: nome se move durante a
execução e os stages deixariam de ver o mesmo diff.
EOF
  exit 64
}

resolve_toplevel() {
  local repo="$1"
  [[ -d "$repo" ]] || die "repo não existe como diretório: ${repo}"
  git -C "$repo" rev-parse --show-toplevel 2>/dev/null \
    || die "não é um repositório git: ${repo}"
}

resolve_sha() {
  local toplevel="$1" ref="$2"
  git -C "$toplevel" rev-parse --verify --quiet "${ref}^{commit}" \
    || die "ref inexistente em ${toplevel}: ${ref}"
}

# Lista arquivos não rastreados, um por linha, prefixados com UNTRACKED=.
# Só faz sentido em modo working: em modo committed tudo já está sob controle do git.
emit_untracked() {
  local toplevel="$1" path
  while IFS= read -r path; do
    [[ -n "$path" ]] && printf 'UNTRACKED=%s\n' "$path"
  done < <(git -C "$toplevel" ls-files --others --exclude-standard)
}

write_state() {
  mkdir -p "$STATE_DIR"
  cat > "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

report() {
  local toplevel="$1"
  printf 'Escopo gravado em %s\n\n' "$STATE_FILE"
  cat "$STATE_FILE"
  printf '\nArquivos alterados:\n'
  git -C "$toplevel" diff --stat "$(sed -n 's/^DIFF_ARGS=//p' "$STATE_FILE")" 2>/dev/null \
    || printf '(stat indisponível)\n'
}

setup_committed() {
  local toplevel="$1" base head
  base="$(resolve_sha "$toplevel" "$2")"
  head="$(resolve_sha "$toplevel" "$3")"
  [[ "$base" != "$head" ]] || die "base e head são o mesmo commit (${base}): diff vazio"

  write_state <<EOF
MODE=committed
REPO=${toplevel}
BASE=${base}
HEAD=${head}
DIFF_ARGS=${base}..${head}
EOF
}

setup_working() {
  local toplevel="$1" base
  base="$(resolve_sha "$toplevel" HEAD)"

  local has_change=0
  git -C "$toplevel" diff --quiet HEAD || has_change=1
  [[ -n "$(git -C "$toplevel" ls-files --others --exclude-standard)" ]] && has_change=1
  (( has_change )) || die "working tree limpo em ${toplevel}: nada a revisar"

  {
    printf 'MODE=working\nREPO=%s\nBASE=%s\nDIFF_ARGS=%s\n' "$toplevel" "$base" "$base"
    emit_untracked "$toplevel"
  } | write_state
}

main() {
  [[ $# -ge 2 ]] || usage
  local mode="$1" toplevel
  toplevel="$(resolve_toplevel "$2")"

  case "$mode" in
    committed) [[ $# -eq 4 ]] || usage; setup_committed "$toplevel" "$3" "$4" ;;
    working)   [[ $# -eq 2 ]] || usage; setup_working   "$toplevel" ;;
    *)         die "modo inválido: '${mode}'. Esperado 'committed' ou 'working'." ;;
  esac

  report "$toplevel"
}

main "$@"
