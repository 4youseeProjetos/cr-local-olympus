#!/usr/bin/env python3
"""Hook preToolUse dos revisores (matcher: shell). Bloqueia git que altere estado.

Segunda camada do read-only. A primeira e' shell.denyByDefault + allowedCommands na
config do agente. Esta existe porque denyByDefault casa contra o comando inteiro, e
comando encadeado contrabandeia mutacao:  git diff HEAD && git reset --hard

Falha fechada: evento ilegivel bloqueia. Num revisor read-only negar demais custa um
aviso; permitir de menos custa o working tree do usuario.

Exit codes do preToolUse:  0 = libera  |  2 = bloqueia e manda stderr ao modelo
"""

from __future__ import annotations

import json
import shlex
import sys

EXIT_ALLOW = 0
EXIT_BLOCK = 2

# Subcomandos git que alteram repositorio, indice ou working tree.
FORBIDDEN_VERBS: frozenset[str] = frozenset({
    "add", "am", "apply", "branch", "checkout", "cherry-pick", "clean", "clone",
    "commit", "config", "fetch", "filter-branch", "gc", "init", "merge", "mv",
    "prune", "pull", "push", "rebase", "remote", "reset", "restore", "revert",
    "rm", "stash", "submodule", "switch", "symbolic-ref", "tag", "update-ref",
    "worktree",
})

# Separadores de encadeamento. Cada segmento e' analisado isoladamente.
CHAIN_SEPARATORS: tuple[str, ...] = ("&&", "||", ";", "|", "\n")

COMMAND_KEYS: tuple[str, ...] = ("command", "cmd", "script")


def block(reason: str) -> None:
    """Encerra o processo bloqueando a ferramenta, com motivo visivel ao modelo."""
    print(f"BLOQUEADO: revisor e' read-only.\n\n{reason}", file=sys.stderr)
    sys.exit(EXIT_BLOCK)


def parse_event(raw: str) -> dict:
    """Desserializa o evento do hook. Evento ilegivel e' falha fechada."""
    if not raw.strip():
        block("Evento do hook veio vazio. Falha fechada.")
    try:
        event = json.loads(raw)
    except json.JSONDecodeError as exc:
        block(f"Evento do hook nao e' JSON valido ({exc}). Recebido: {raw[:200]!r}")
    if not isinstance(event, dict):
        block(f"Evento do hook deveria ser um objeto JSON, veio {type(event).__name__}.")
    return event


def extract_command(event: dict) -> str:
    """Le o comando do tool_input, aceitando as chaves conhecidas do kiro-cli."""
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        block(f"tool_input ausente ou nao e' objeto. Evento: {json.dumps(event)[:200]}")

    for key in COMMAND_KEYS:
        value = tool_input.get(key)
        if isinstance(value, str) and value.strip():
            return value

    keys = sorted(tool_input)
    block(
        "Nao foi possivel achar o comando no tool_input. Falha fechada.\n"
        f"Chaves esperadas: {list(COMMAND_KEYS)}. Chaves presentes: {keys}"
    )
    raise AssertionError("inalcancavel")  # block() encerra o processo


def split_segments(command: str) -> list[str]:
    """Quebra o comando nos separadores de encadeamento."""
    segments = [command]
    for separator in CHAIN_SEPARATORS:
        segments = [part for seg in segments for part in seg.split(separator)]
    return [seg for seg in segments if seg.strip()]


def tokenize(segment: str) -> list[str]:
    """Tokeniza respeitando quoting. Segmento inquebravel e' falha fechada."""
    try:
        return shlex.split(segment)
    except ValueError as exc:
        block(f"Nao foi possivel tokenizar o segmento ({exc}): {segment!r}")
        raise AssertionError("inalcancavel")


def find_forbidden_verb(segment: str) -> str | None:
    """Devolve o verbo proibido se o segmento invocar git com mutacao.

    Varre todos os tokens em vez de tentar achar a posicao do subcomando: git aceita
    flags globais com valor separado (git -c core.pager=cat checkout), o que faz a
    posicao do subcomando variar. Match exato de token evita falso positivo em
    caminho e valor de flag (add.py, --grep=reset nao casam).

    >>> find_forbidden_verb("git diff abc..def")
    >>> find_forbidden_verb("git -c core.pager=cat checkout main")
    'checkout'
    """
    tokens = tokenize(segment)
    if not tokens:
        return None
    if not any(tok == "git" or tok.endswith("/git") for tok in tokens):
        return None
    return next((tok for tok in tokens if tok in FORBIDDEN_VERBS), None)


def main() -> int:
    event = parse_event(sys.stdin.read())
    command = extract_command(event)

    for segment in split_segments(command):
        verb = find_forbidden_verb(segment)
        if verb is None:
            continue
        block(
            f"O comando invoca 'git {verb}', que altera estado:\n\n"
            f"  {command}\n\n"
            "Permitido apenas inspecao: git diff, show, log, blame, status,\n"
            "rev-parse, rev-list, ls-files, cat-file, describe.\n\n"
            "Se precisar de uma copia de outra revisao, peca ao usuario — nao mova\n"
            "o HEAD deste checkout."
        )

    return EXIT_ALLOW


if __name__ == "__main__":
    sys.exit(main())
