"""Packaging metadata tests."""

from __future__ import annotations

import tomllib
from pathlib import Path


def test_public_console_scripts_are_runtime_only() -> None:
    pyproject = tomllib.loads(
        (Path(__file__).resolve().parent.parent / "pyproject.toml").read_text()
    )

    assert pyproject["tool"]["poetry"]["scripts"] == {"hostbootstrap": "hostbootstrap.cli:main"}
