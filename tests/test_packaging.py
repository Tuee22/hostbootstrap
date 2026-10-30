"""Packaging metadata tests."""

from __future__ import annotations

import re
import tomllib
from pathlib import Path

import pytest


def _strip_haskell_comments(source: str) -> str:
    """Blank comments while preserving source offsets, strings, and nested blocks."""
    tokens = re.compile(r"""'(?:\\.|[^'\\])'|"(?:\\.|[^"\\])*"|--[^\n]*|\{-""", re.DOTALL)
    delimiters = re.compile(r"\{-|-\}")
    characters = list(source)
    index = 0
    while token := tokens.search(source, index):
        index = token.end()
        if token.group().startswith(("'", '"')):
            continue
        if token.group() == "{-":
            depth = 1
            index = len(source)
            for delimiter in delimiters.finditer(source, token.end()):
                depth += 1 if delimiter.group() == "{-" else -1
                if depth == 0:
                    index = delimiter.end()
                    break
        for offset in range(token.start(), index):
            if characters[offset] != "\n":
                characters[offset] = " "
    return "".join(characters)


_HOST_PROCESS_FUNCTIONS = (
    "readProcessWithExitCode",
    "readProcess",
    "readCreateProcess",
    "proc",
    "shell",
    "callProcess",
    "rawSystem",
    "spawnProcess",
    "createProcess",
)


def _bare_literal_process_targets(source: str) -> list[tuple[int, str]]:
    pattern = re.compile(r"\b(?:" + "|".join(_HOST_PROCESS_FUNCTIONS) + r')\s+"[^/\\"]+"')
    stripped = _strip_haskell_comments(source)
    return [
        (source.count("\n", 0, match.start()) + 1, match.group())
        for match in pattern.finditer(stripped)
    ]


def _production_builder_use_count(source: str, builder: str) -> int:
    text = _strip_haskell_comments(source)
    # A declaration/export or import is not an expression consuming the builder.
    text = re.sub(r"(?ms)^module\s+\S+.*?\bwhere\b", "", text)
    text = re.sub(r"(?m)^import\b[^\n]*(?:\n[ \t]+[^\n]*)*", "", text)
    text = re.sub(r'"(?:\\.|[^"\\])*"', '""', text)
    declaration = re.compile(
        rf"^{re.escape(builder)}(?:\s*::[^\n]*|\b[^\n]*=[^\n]*)$", re.MULTILINE
    )
    expressions = declaration.sub("", text)
    return len(re.findall(rf"\b{re.escape(builder)}\b", expressions))


def test_public_console_scripts_are_runtime_only() -> None:
    pyproject = tomllib.loads(
        (Path(__file__).resolve().parent.parent / "pyproject.toml").read_text()
    )

    assert pyproject["tool"]["poetry"]["scripts"] == {"hostbootstrap": "hostbootstrap.cli:main"}


def test_no_empty_stub_directory_is_carried_as_a_check_target() -> None:
    """An empty directory named by three tool configurations contributes nothing."""
    root = Path(__file__).resolve().parents[1]
    assert not (root / "stubs").exists()
    assert "stubs" not in (root / "pyproject.toml").read_text(encoding="utf-8")


def test_haskell_host_processes_do_not_launch_bare_literal_commands() -> None:
    """A literal process target bypasses HostTool/AbsExe and is never allowed."""
    root = Path(__file__).resolve().parents[1]
    offenders: list[str] = []
    for tree in (root / "core/hostbootstrap-core", root / "demo"):
        for source in tree.rglob("*.hs"):
            for line_number, target in _bare_literal_process_targets(
                source.read_text(encoding="utf-8")
            ):
                offenders.append(f"{source.relative_to(root)}:{line_number}: {target.strip()}")
    assert offenders == [], "bare Haskell process targets:\n" + "\n".join(offenders)


def test_provider_surface_has_one_dispatch_and_no_definition_only_builders() -> None:
    """Hold rationale.md's 'A provider builder has a production consumer' contract."""
    root = Path(__file__).resolve().parents[1]
    core = root / "core/hostbootstrap-core"
    cabal = (core / "hostbootstrap-core.cabal").read_text(encoding="utf-8")
    production_sources = tuple((core / "src").rglob("*.hs")) + tuple(
        (root / "demo/src").rglob("*.hs")
    )
    source_texts = tuple(source.read_text(encoding="utf-8") for source in production_sources)
    production = "\n".join(source_texts)

    assert "HostBootstrap.HostTarget" not in cabal
    assert not (core / "src/HostBootstrap/HostTarget.hs").exists()
    for removed in (
        "runInTarget",
        "rebootDockerToReady",
        "classifyDockerReadiness",
        "classifyWsl2Readiness",
        "rebootVMArgs",
        "wslImportArgs",
        "wslTerminateArgs",
    ):
        assert removed not in production

    # Exports, imports, signatures, and defining equations prove no production use.
    for builder in (
        "createVMArgs",
        "startVMArgs",
        "stopVMArgs",
        "execVMArgs",
        "pushFileArgs",
        "deviceListArgs",
        "addDiskDeviceArgs",
        "destroyVMArgs",
        "bcdeditHypervisorLaunchArgs",
        "wslInstallArgs",
        "wslExecArgs",
        "wslUnregisterArgs",
        "wslShutdownArgs",
    ):
        assert (
            sum(_production_builder_use_count(text, builder) for text in source_texts) >= 1
        ), builder


@pytest.mark.parametrize("function", _HOST_PROCESS_FUNCTIONS)
def test_literal_process_scanner_reads_multiline_calls_and_ignores_comments(function: str) -> None:
    source = (
        f'-- {function} "ignored"\n'
        f'{{- outer {{- {function} "nested" -}}\n'
        f'{function} "also ignored" -}}\n'
        f'{function}\n    "docker" []\n'
        'spawnProcess "wsl" []\n'
    )
    matches = _bare_literal_process_targets(source)
    assert [line for line, _target in matches] == [4, 6]
    assert matches[0][1].startswith(function)
    assert matches[1][1] == 'spawnProcess "wsl"'


def test_literal_process_scanner_keeps_comment_markers_inside_strings() -> None:
    assert _bare_literal_process_targets('proc "has--dashes" []') == [(1, 'proc "has--dashes"')]
    assert _bare_literal_process_targets('proc "/absolute/docker" []') == []
    assert _bare_literal_process_targets('proc "C:\\\\tools\\\\docker.exe" []') == []
    assert _bare_literal_process_targets('-- proc "docker"') == []


def test_provider_builder_counter_requires_an_expression_use() -> None:
    source = """module Synthetic (
    createVMArgs,
    Other (..),
) where
import Other (createVMArgs)
import qualified Another (
    createVMArgs,
    )
-- createVMArgs is documented here.
{- createVMArgs is documented here too. -}
createVMArgs :: VM -> [String]
createVMArgs vm = ["createVMArgs"]
"""
    assert _production_builder_use_count(source, "createVMArgs") == 0
    assert (
        _production_builder_use_count(
            source.replace("createVMArgs ::", "createVMArgs\n    ::"), "createVMArgs"
        )
        == 0
    )
    assert (
        _production_builder_use_count(source + "build vm = createVMArgs vm\n", "createVMArgs") == 1
    )
