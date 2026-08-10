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


def test_provider_surface_has_one_dispatch_and_no_definition_only_builders() -> None:
    """The provider API stays production-consumed and single-routed."""
    root = Path(__file__).resolve().parents[1]
    core = root / "core/hostbootstrap-core"
    cabal = (core / "hostbootstrap-core.cabal").read_text(encoding="utf-8")
    production_sources = tuple((core / "src").rglob("*.hs")) + tuple(
        (root / "demo/src").rglob("*.hs")
    )
    production = "\n".join(source.read_text(encoding="utf-8") for source in production_sources)

    assert "HostBootstrap.HostTarget" not in cabal
    assert not (core / "src/HostBootstrap/HostTarget.hs").exists()
    for removed in (
        "runInTarget",
        "rebootDockerToReady",
        "classifyDockerReadiness",
        "classifyWsl2Readiness",
        "rebootVMArgs",
        "wslImportArgs",
    ):
        assert removed not in production

    # One occurrence is the definition; at least one more proves a production use.
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
        "wslTerminateArgs",
        "wslUnregisterArgs",
        "wslShutdownArgs",
    ):
        assert len(re.findall(rf"\b{builder}\b", production)) >= 2, builder
