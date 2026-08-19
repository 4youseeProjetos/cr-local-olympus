#!/usr/bin/env python3
"""Verifica que o diagrama, os agentes e a skill contam a mesma historia.

O diagrama nao e' gerado a partir das configs de proposito: ele e' artefato de
comunicacao, muda raramente e ganha clareza com escolhas manuais que um gerador nao
faria. O risco real nao e' falta de automacao, e' DRIFT — o diagrama afirmar um
modelo e o agente usar outro. Isso ja quase aconteceu quando a triagem mudou de
qwen3-coder-next para gpt-5.6-terra.

Este script cobre o drift sem gerador: le a verdade de agents/*.json e confere se o
HTML e a skill concordam.

Uso:  python3 tests/check-consistency.py
Exit: 0 tudo consistente | 1 divergencia encontrada
"""

from __future__ import annotations

import html as html_mod
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
AGENTS_DIR = ROOT / "agents"
DIAGRAM = ROOT / "docs" / "fluxo-cr.html"
SKILL = ROOT / "skills" / "cr-local-olympus" / "SKILL.md"
LIGHT_SKILL = ROOT / "skills" / "cr-light-local-olympus" / "SKILL.md"
README = ROOT / "README.md"

MODEL_IN_DIAGRAM = "(o da sessão)"
"""Marcador para agente sem model fixo, que herda o modelo da sessao."""


def load_agents() -> dict[str, dict]:
    """Le as configs de agente, indexadas pelo nome declarado dentro do JSON."""
    agents: dict[str, dict] = {}
    for path in sorted(AGENTS_DIR.glob("*.json")):
        config = json.loads(path.read_text(encoding="utf-8"))
        name = config.get("name")
        if not name:
            raise ValueError(f"{path} nao declara 'name'")
        agents[name] = config
    if not agents:
        raise ValueError(f"nenhum agente encontrado em {AGENTS_DIR}")
    return agents


def extract_diagram_nodes(markup: str) -> dict[str, str]:
    """Extrai {nome do no: modelo declarado} do diagrama.

    Casa a estrutura real do HTML — div.name com o nome, seguido de um li cujo
    rotulo e' 'modelo' — em vez de varrer uma janela de caracteres, que quebrava
    conforme o no tinha ou nao lista de metadados.
    """
    node_pattern = re.compile(
        r'<div class="name">(?P<name>[^<]+)</div>'
        r'(?P<body>.*?)'
        r'(?=<div class="name">|</body>)',
        re.S,
    )
    model_pattern = re.compile(r"<li><b>modelo</b>(?P<model>[^<]+)</li>")

    nodes: dict[str, str] = {}
    for node in node_pattern.finditer(markup):
        name = html_mod.unescape(node.group("name")).strip()
        found = model_pattern.search(node.group("body"))
        if not found:
            continue
        raw = html_mod.unescape(found.group("model"))
        # O diagrama mostra "modelo · multiplicador"; so' o modelo interessa aqui.
        nodes[name] = raw.split("·")[0].strip()
    return nodes


def check_models(agents: dict[str, dict], nodes: dict[str, str]) -> list[str]:
    """Confere o modelo de cada agente contra o que o diagrama afirma."""
    problems: list[str] = []
    for name, config in agents.items():
        expected = config.get("model") or MODEL_IN_DIAGRAM
        declared = nodes.get(name)
        if declared is None:
            problems.append(f"{name}: ausente no diagrama (esperado modelo {expected})")
        elif declared != expected:
            problems.append(f"{name}: config diz {expected}, diagrama diz {declared}")
    return problems


def check_skill_roles(agents: dict[str, dict], skill_text: str) -> list[str]:
    """Confere que a skill referencia exatamente os agentes revisores existentes."""
    reviewers = {name for name in agents if name != "cr-olympus"}
    return [
        f"{name}: nao aparece na SKILL.md, entao nunca sera despachado"
        for name in sorted(reviewers)
        if name not in skill_text
    ]


def check_orchestrator_allowlist(agents: dict[str, dict]) -> list[str]:
    """Confere que o allowlist do crew cobre todos os revisores.

    Se um revisor ficar fora de availableAgents, o dispatch falha em runtime com
    'Agents not available for crew stages'.
    """
    orchestrator = agents.get("cr-olympus")
    if orchestrator is None:
        return ["cr-olympus: agente orquestrador ausente"]

    crew = orchestrator.get("toolsSettings", {}).get("crew", {})
    available = set(crew.get("availableAgents", []))
    reviewers = {name for name in agents if name != "cr-olympus"}
    missing = sorted(reviewers - available)
    return [
        f"{name}: fora de crew.availableAgents do cr-olympus, dispatch falharia"
        for name in missing
    ]


def check_referenced_files(agents: dict[str, dict]) -> list[str]:
    """Confere que prompts e hooks referenciados existem no repositorio.

    Os templates usam __CR_ROOT__, que o install.sh troca pela raiz real; aqui a
    substituicao e' feita em memoria para validar antes de instalar.
    """
    problems: list[str] = []
    for name, config in agents.items():
        for reference in iter_path_references(config):
            resolved = reference.replace("__CR_ROOT__", str(ROOT)).replace("file://", "")
            if not pathlib.Path(resolved).exists():
                problems.append(f"{name}: referencia inexistente {resolved}")
    return problems


def iter_path_references(config: dict) -> list[str]:
    """Coleta os valores de config que apontam para arquivo do repositorio."""
    references: list[str] = []
    prompt = config.get("prompt", "")
    if isinstance(prompt, str) and prompt.startswith("file://"):
        references.append(prompt)
    for hook in config.get("hooks", []):
        command = hook.get("action", {}).get("command", "")
        if command.startswith("__CR_ROOT__"):
            references.append(command)
    return references


def check_readme_table(agents: dict[str, dict], readme_text: str) -> list[str]:
    """Confere a tabela de Componentes do README contra as configs.

    O README enumera agente e modelo em prosa, e prosa envelhece: a contagem de
    agentes ja ficou errada duas vezes quando o cr-test entrou. Enumeracao que nao
    da' para eliminar, da' para testar.
    """
    row = re.compile(
        r"^\|\s*`(?P<name>cr-[\w-]+)`\s*\|[^|]*\|\s*(?P<model>[^|]+?)\s*\|",
        re.M,
    )
    declared = {
        m.group("name"): m.group("model").strip().strip("`")
        for m in row.finditer(readme_text)
    }

    problems: list[str] = []
    for name, config in agents.items():
        expected = config.get("model") or "o da sessão"
        if name not in declared:
            problems.append(f"{name}: ausente na tabela de Componentes do README")
        elif declared[name] != expected:
            problems.append(
                f"{name}: README diz {declared[name]!r}, config diz {expected!r}"
            )
    for name in sorted(set(declared) - set(agents)):
        problems.append(f"{name}: na tabela do README mas nao existe em agents/")
    return problems


def check_light_skill_models(agents: dict[str, dict], light_text: str) -> list[str]:
    """Confere que a versao light usa os mesmos modelos que os agentes da completa.

    A light nao tem agente proprio: ela nomeia os modelos direto no texto, porque
    injeta 'model' por stage. Isso e' o que faz uma skill sozinha ter diversidade de
    familia — e tambem o que a faz divergir em silencio quando a versao completa troca
    de modelo. Aqui a divergencia vira falha de teste.
    """
    expected = {
        "cr-security": agents.get("cr-security", {}).get("model"),
        "cr-quality": agents.get("cr-quality", {}).get("model"),
    }
    problems: list[str] = []
    for agent_name, model in expected.items():
        if not model:
            problems.append(f"{agent_name}: sem model na config, nada a comparar")
        elif model not in light_text:
            problems.append(
                f"{agent_name} usa {model}, que nao aparece na skill light — "
                "as duas versoes divergiram de modelo"
            )
    return problems


def main() -> int:
    agents = load_agents()
    nodes = extract_diagram_nodes(DIAGRAM.read_text(encoding="utf-8"))
    skill_text = SKILL.read_text(encoding="utf-8")
    light_text = LIGHT_SKILL.read_text(encoding="utf-8")
    readme_text = README.read_text(encoding="utf-8")

    checks = {
        "modelo do diagrama vs config": check_models(agents, nodes),
        "tabela de componentes do README": check_readme_table(agents, readme_text),
        "revisores citados na skill": check_skill_roles(agents, skill_text),
        "modelos da skill light vs agentes": check_light_skill_models(agents, light_text),
        "allowlist do orquestrador": check_orchestrator_allowlist(agents),
        "prompts e hooks referenciados": check_referenced_files(agents),
    }

    failed = 0
    for label, problems in checks.items():
        status = "ok" if not problems else "FALHOU"
        print(f"[{status}] {label}")
        for problem in problems:
            print(f"       - {problem}")
        failed += len(problems)

    print(f"\n{len(agents)} agentes conferidos, {failed} divergencia(s).")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
