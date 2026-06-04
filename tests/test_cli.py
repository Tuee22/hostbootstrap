"""CLI smoke tests (no docker, no host mutation)."""

from __future__ import annotations

from pathlib import Path

import pytest
from click.testing import CliRunner

from hostbootstrap import cli
from hostbootstrap.spec import BuildSpec, HostDaemonModel, HostReqs, ProjectSpec
from hostbootstrap.substrate import Substrate, SubstrateName


def test_help_lists_commands_and_omits_push() -> None:
    result = CliRunner().invoke(cli.main, ["--help"])
    assert result.exit_code == 0
    for command in ("doctor", "build", "cluster", "run", "base"):
        assert command in result.output
    assert "push" not in result.output


def test_push_command_removed() -> None:
    result = CliRunner().invoke(cli.main, ["push"])
    assert result.exit_code != 0
    assert "No such command" in result.output


def test_cluster_subcommands() -> None:
    result = CliRunner().invoke(cli.main, ["cluster", "--help"])
    assert result.exit_code == 0
    for verb in ("up", "down", "delete"):
        assert verb in result.output


def test_build_missing_spec_fails_cleanly(tmp_path: Path) -> None:
    missing = tmp_path / "hostbootstrap.dhall"
    result = CliRunner().invoke(cli.main, ["build", "--spec", str(missing)])
    assert result.exit_code != 0
    assert "not found" in result.output


def test_default_spec_path_is_dhall() -> None:
    assert cli._DEFAULT_SPEC_PATH == Path("hostbootstrap.dhall")


async def test_development_hostdaemon_cluster_lifecycle_skips_units(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    project_root: Path,
) -> None:
    async def _unit_call(*_: object, **__: object) -> Path:
        raise AssertionError("development mode must not touch system units")

    monkeypatch.setattr(cli.units, "ensure", _unit_call)
    monkeypatch.setattr(cli.units, "remove", _unit_call)

    project_spec = ProjectSpec(
        project="proj",
        substrates={
            SubstrateName.LINUX_CPU: HostDaemonModel(
                build=BuildSpec("cabal install --installdir .build exe:proj", HostReqs()),
                daemon=".build/proj serve",
            )
        },
        source_path=project_root / "hostbootstrap.dhall",
        development=True,
    )
    sub = Substrate(SubstrateName.LINUX_CPU, "amd64")

    await cli._cluster_up(project_spec, sub, project_root)
    await cli._cluster_down(project_spec, sub, project_root)
    await cli._cluster_delete(project_spec, sub, project_root)

    flat = [" ".join(command) for command in recorded_commands]
    assert any("docker run" in command for command in flat)
    assert all("systemctl" not in command and "launchctl" not in command for command in flat)
