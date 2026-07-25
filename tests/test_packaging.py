"""Packaging metadata tests."""

from __future__ import annotations

import re
import tomllib
from pathlib import Path


def test_public_console_scripts_are_runtime_only() -> None:
    pyproject = tomllib.loads(
        (Path(__file__).resolve().parent.parent / "pyproject.toml").read_text()
    )

    assert pyproject["tool"]["poetry"]["scripts"] == {"hostbootstrap": "hostbootstrap.cli:main"}


def test_haskell_host_processes_do_not_launch_bare_literal_commands() -> None:
    """A literal process target bypasses HostTool/AbsExe and is never allowed."""
    root = Path(__file__).resolve().parents[1]
    patterns = (
        re.compile(r'\breadProcessWithExitCode\s+"[^/\\"]+"'),
        re.compile(r'\bproc\s+"[^/\\"]+"'),
        re.compile(r'\bcallProcess\s+"[^/\\"]+"'),
        re.compile(r'\brawSystem\s+"[^/\\"]+"'),
    )
    offenders: list[str] = []
    for tree in (root / "core/hostbootstrap-core", root / "demo"):
        for source in tree.rglob("*.hs"):
            for line_number, line in enumerate(
                source.read_text(encoding="utf-8").splitlines(), start=1
            ):
                if any(pattern.search(line) for pattern in patterns):
                    offenders.append(f"{source.relative_to(root)}:{line_number}: {line.strip()}")
    assert offenders == [], "bare Haskell process targets:\n" + "\n".join(offenders)
