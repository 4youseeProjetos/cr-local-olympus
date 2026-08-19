#!/usr/bin/env bash
#
# Liga/desliga os componentes do cr-local-olympus dentro de ~/.kiro/.
#
# O kiro-cli só descobre agentes em ~/.kiro/agents/ e skills em
# ~/.kiro/skills/*/SKILL.md — caminhos fixos, pasta arbitrária não é varrida.
#
# Skills são linkadas: o SKILL.md não referencia caminho nenhum, então symlink
# basta e `git pull` propaga sozinho.
#
# Agentes são RENDERIZADOS, não linkados. Os campos `prompt` (file://) e o
# `command` dos hooks exigem caminho absoluto, que depende de onde o repo foi
# clonado. Os arquivos em agents/ são templates com __CR_ROOT__, substituído aqui
# pela raiz real. Consequência: depois de `git pull`, rode ./install.sh de novo.
#
# Propriedade dos arquivos é registrada num manifesto, não inferida do conteúdo:
# inferir por caminho quebra quando o clone tem outro nome de diretório.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIRO_AGENTS="${HOME}/.kiro/agents"
KIRO_SKILLS="${HOME}/.kiro/skills"
MANIFEST_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/cr-local-olympus"
MANIFEST="${MANIFEST_DIR}/manifest"
readonly ROOT KIRO_AGENTS KIRO_SKILLS MANIFEST_DIR MANIFEST
readonly ROOT_PLACEHOLDER='__CR_ROOT__'

die() { printf 'ERRO: %s\n' "$1" >&2; exit 1; }

agent_templates() { find "${ROOT}/agents" -maxdepth 1 -name '*.json' -type f | sort; }
skill_dirs()      { find "${ROOT}/skills" -maxdepth 1 -mindepth 1 -type d | sort; }

dest_for_agent() { printf '%s/%s\n' "$KIRO_AGENTS" "$(basename "$1")"; }
dest_for_skill() { printf '%s/%s\n' "$KIRO_SKILLS" "$(basename "$1")"; }

is_ours() {
  local dest="$1"
  [[ -r "$MANIFEST" ]] || return 1
  grep -qxF "$dest" "$MANIFEST"
}

# Recusa mexer em destino que existe e não está no manifesto: pode ser config que
# o usuário escreveu à mão, e sobrescrever silenciosamente seria perda de trabalho.
guard_destination() {
  local dest="$1"
  [[ -e "$dest" || -L "$dest" ]] || return 0
  is_ours "$dest" && return 0
  die "${dest} já existe e não está no manifesto deste install. Mova ou remova antes."
}

render_agent() {
  local src="$1" dest="$2"
  sed "s|${ROOT_PLACEHOLDER}|${ROOT}|g" "$src" > "${dest}.tmp"
  if grep -q "$ROOT_PLACEHOLDER" "${dest}.tmp"; then
    rm -f "${dest}.tmp"
    die "placeholder ${ROOT_PLACEHOLDER} sobrou em $(basename "$src") após o render"
  fi
  mv "${dest}.tmp" "$dest"
}

ensure_hooks_executable() {
  local hook
  while IFS= read -r hook; do
    [[ -x "$hook" ]] || chmod +x "$hook"
  done < <(find "${ROOT}/hooks" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \))
}

# Valida tudo antes de escrever qualquer coisa, para não deixar instalação parcial.
preflight() {
  local src dest
  while IFS= read -r src; do
    dest="$(dest_for_agent "$src")"
    guard_destination "$dest"
  done < <(agent_templates)
  while IFS= read -r src; do
    dest="$(dest_for_skill "$src")"
    guard_destination "$dest"
  done < <(skill_dirs)
}

install_all() {
  preflight
  ensure_hooks_executable
  mkdir -p "$KIRO_AGENTS" "$KIRO_SKILLS" "$MANIFEST_DIR"

  local new_manifest src dest
  new_manifest="$(mktemp)"

  while IFS= read -r src; do
    dest="$(dest_for_agent "$src")"
    render_agent "$src" "$dest"
    printf '%s\n' "$dest" >> "$new_manifest"
    printf '  agente  %s\n' "$(basename "$dest")"
  done < <(agent_templates)

  while IFS= read -r src; do
    dest="$(dest_for_skill "$src")"
    ln -sfn "$src" "$dest"
    printf '%s\n' "$dest" >> "$new_manifest"
    printf '  skill   %s\n' "$(basename "$dest")"
  done < <(skill_dirs)

  mv "$new_manifest" "$MANIFEST"
  print_next_steps
}

# O install é o último ponto em que temos a atenção de quem instalou. Se os próximos
# passos não saírem aqui, o usuário roda a skill do agente errado e o gate — que é a
# salvaguarda central — fica inerte sem nenhum sinal.
print_next_steps() {
  cat <<EOF

Raiz resolvida: ${ROOT}
Manifesto:      ${MANIFEST}

PRÓXIMOS PASSOS

  1. Reinicie a sessão do kiro-cli.
     Agente novo só é carregado na inicialização.

  2. Entre no agente orquestrador:
       /agent cr-olympus

     Obrigatório. O hook que barra o review antes de você confirmar a base do
     diff vive na config desse agente. De outro agente a skill roda, mas sem
     trava nenhuma.

  3. De dentro do repositório que quer revisar:
       /cr-local-olympus

CONFERIR

  ./install.sh --status               todos devem dizer "instalado"
  kiro-cli agent list | grep cr-      4 agentes
  python3 tests/check-consistency.py  deve terminar em 0 divergências
EOF
}

remove_all() {
  [[ -r "$MANIFEST" ]] || { printf 'Nada instalado (sem manifesto em %s).\n' "$MANIFEST"; return 0; }
  local count=0 dest
  while IFS= read -r dest; do
    [[ -n "$dest" ]] || continue
    if [[ -e "$dest" || -L "$dest" ]]; then
      rm -rf "$dest"
      printf '  removido %s\n' "$(basename "$dest")"
      count=$((count + 1))
    fi
  done < "$MANIFEST"
  rm -f "$MANIFEST"
  printf '\n%d componente(s) removido(s).\n' "$count"
}

state_of() {
  local dest="$1"
  is_ours "$dest" && { [[ -e "$dest" || -L "$dest" ]] && echo instalado || echo 'no manifesto, mas o arquivo desapareceu'; return; }
  [[ -e "$dest" || -L "$dest" ]] && { echo 'CONFLITO (existe, fora do manifesto)'; return; }
  echo 'não instalado'
}

show_status() {
  printf '%-22s %-8s %s\n' COMPONENTE TIPO ESTADO
  local src
  while IFS= read -r src; do
    printf '%-22s %-8s %s\n' "$(basename "$src")" agente "$(state_of "$(dest_for_agent "$src")")"
  done < <(agent_templates)
  while IFS= read -r src; do
    printf '%-22s %-8s %s\n' "$(basename "$src")" skill "$(state_of "$(dest_for_skill "$src")")"
  done < <(skill_dirs)
  printf '\nRaiz: %s\n' "$ROOT"
}

main() {
  case "${1:-install}" in
    install|"")  install_all ;;
    --remove|-r) remove_all ;;
    --status|-s) show_status ;;
    *) printf 'uso: %s [install|--status|--remove]\n' "$(basename "$0")" >&2; return 64 ;;
  esac
}

main "$@"
