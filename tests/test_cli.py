"""CLI smoke tests (no docker, no host mutation)."""

from __future__ import annotations

from pathlib import Path

import httpx
import pytest
from click.testing import CliRunner

from hostbootstrap import cli, docker_ops, process
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


def test_base_exposes_only_build_and_push() -> None:
    result = CliRunner().invoke(cli.main, ["base", "--help"])
    assert result.exit_code == 0
    assert "build-and-push" in result.output
    # The separate "build" / "push" leaf commands no longer exist on `base`.
    standalone_build = CliRunner().invoke(cli.main, ["base", "build"])
    assert standalone_build.exit_code != 0
    standalone_push = CliRunner().invoke(cli.main, ["base", "push"])
    assert standalone_push.exit_code != 0


def test_cluster_subcommands() -> None:
    result = CliRunner().invoke(cli.main, ["cluster", "--help"])
    assert result.exit_code == 0
    for verb in ("up", "down", "delete"):
        assert verb in result.output


def test_run_exposes_local_base_build_options() -> None:
    result = CliRunner().invoke(cli.main, ["run", "--help"])
    assert result.exit_code == 0
    assert "--build-base" in result.output
    assert "--base-context" in result.output


def test_build_missing_spec_fails_cleanly(tmp_path: Path) -> None:
    missing = tmp_path / "hostbootstrap.dhall"
    result = CliRunner().invoke(cli.main, ["build", "--spec", str(missing)])
    assert result.exit_code != 0
    assert "not found" in result.output


def test_default_spec_path_is_dhall() -> None:
    assert cli._DEFAULT_SPEC_PATH == Path("hostbootstrap.dhall")


def _make_command_error(stderr: str, *, returncode: int = 1) -> process.CommandError:
    result = process.CommandResult(
        args=("docker", "push", "tuee22/hostbootstrap:basecontainer-cpu-arm64"),
        returncode=returncode,
        stdout="",
        stderr=stderr,
    )
    return process.CommandError(result)


def _stub_build_spec(*_a: object, **_kw: object) -> tuple[docker_ops.BuildSpec, object]:
    spec = docker_ops.BuildSpec(
        dockerfile=Path("D"),
        context=Path("."),
        tags=("t",),
        build_args={},
        no_cache=True,
    )
    return spec, object()


def _patch_build_spec(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(cli.base_image, "build_spec_for", _stub_build_spec)


@pytest.mark.parametrize(
    ("stderr", "needle"),
    [
        ("The push refers to ...\ntag does not exist: foo", "image not built locally"),
        ("denied: requested access to the resource is denied", "docker login"),
        ("unauthorized: incorrect username or password", "docker login"),
        ("Cannot connect to the Docker daemon at unix://...", "docker daemon not reachable"),
    ],
)
def test_friendly_docker_errors_have_no_traceback(
    monkeypatch: pytest.MonkeyPatch, stderr: str, needle: str
) -> None:
    _patch_build_spec(monkeypatch)

    async def _raises(*_a: object, **_kw: object) -> object:
        raise _make_command_error(stderr)

    monkeypatch.setattr(cli.docker_ops, "build", _raises)
    result = CliRunner().invoke(cli.main, ["base", "build-and-push"])
    assert result.exit_code != 0
    assert needle in result.output
    assert "Traceback" not in result.output
    assert "CommandError" not in result.output


def test_friendly_http_error_has_no_traceback(monkeypatch: pytest.MonkeyPatch) -> None:
    def _raises(*_a: object, **_kw: object) -> object:
        raise httpx.ConnectError("nodename nor servname provided", request=httpx.Request("GET", "https://example.invalid/v1"))

    monkeypatch.setattr(cli.base_image, "build_spec_for", _raises)
    result = CliRunner().invoke(cli.main, ["base", "build-and-push"])
    assert result.exit_code != 0
    assert "network error" in result.output
    assert "Traceback" not in result.output


def test_friendly_missing_binary_has_no_traceback(monkeypatch: pytest.MonkeyPatch) -> None:
    _patch_build_spec(monkeypatch)

    async def _raises(*_a: object, **_kw: object) -> object:
        raise FileNotFoundError(2, "No such file or directory", "docker")

    monkeypatch.setattr(cli.docker_ops, "build", _raises)
    result = CliRunner().invoke(cli.main, ["base", "build-and-push"])
    assert result.exit_code != 0
    assert "`docker` not found in PATH" in result.output
    assert "Traceback" not in result.output


def test_base_build_and_push_forces_no_cache(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, object] = {}

    def _capture(*args: object, **kwargs: object) -> tuple[docker_ops.BuildSpec, object]:
        captured["args"] = args
        captured["kwargs"] = kwargs
        return _stub_build_spec()

    async def _noop_build(*_a: object, **_kw: object) -> object:
        return process.CommandResult(args=("docker", "build"), returncode=0, stdout="", stderr="")

    async def _noop_push(*_a: object, **_kw: object) -> object:
        return process.CommandResult(args=("docker", "push"), returncode=0, stdout="", stderr="")

    monkeypatch.setattr(cli.base_image, "build_spec_for", _capture)
    monkeypatch.setattr(cli.docker_ops, "build", _noop_build)
    monkeypatch.setattr(cli.docker_ops, "push", _noop_push)

    result = CliRunner().invoke(cli.main, ["base", "build-and-push", "--arch", "arm64"])
    assert result.exit_code == 0, result.output
    assert captured["kwargs"].get("no_cache") is True  # type: ignore[union-attr]
    assert captured["kwargs"].get("pull") is True  # type: ignore[union-attr]
    assert "built and pushed" in result.output


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
