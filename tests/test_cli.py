"""CLI smoke tests (no docker, no host mutation)."""

from __future__ import annotations

from pathlib import Path

import httpx
import pytest
from click.testing import CliRunner

from hostbootstrap import bootstrap, cli, docker_ops, process
from hostbootstrap.substrate import Substrate, SubstrateName

LINUX = Substrate(SubstrateName.LINUX_CPU, "amd64")


def _project() -> bootstrap.ProjectBuildSpec:
    return bootstrap.ProjectBuildSpec(
        project="proj",
        cabal_file=Path("/proj/proj.cabal"),
    )


# ---------------------------------------------------------------------------
# Thin command surface
# ---------------------------------------------------------------------------


def test_help_lists_thin_commands_and_omits_removed() -> None:
    result = CliRunner().invoke(cli.main, ["--help"])
    assert result.exit_code == 0
    for command in ("doctor", "build", "run", "base"):
        assert command in result.output
    for gone in ("up", "cluster", "daemon", "push"):
        assert gone not in result.output


@pytest.mark.parametrize("removed", ["up", "cluster", "daemon", "push"])
def test_removed_commands_are_gone(removed: str) -> None:
    result = CliRunner().invoke(cli.main, [removed])
    assert result.exit_code != 0
    assert "No such command" in result.output


def test_run_has_no_force_target_or_pull_option() -> None:
    result = CliRunner().invoke(cli.main, ["run", "--help"])
    assert result.exit_code == 0
    # The pre-binary bootstrapper neither builds the container nor pulls the base.
    assert "--force-target" not in result.output
    assert "--no-pull" not in result.output


def test_default_project_root_is_current_directory() -> None:
    assert Path(".") == cli._DEFAULT_PROJECT_ROOT


# ---------------------------------------------------------------------------
# build / run commands
# ---------------------------------------------------------------------------


def test_run_forwards_trailing_args(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    project = _project()
    captured: dict[str, object] = {}
    monkeypatch.setattr(cli, "_load_project", lambda _path: project)

    async def _fake_bootstrap(
        spec: bootstrap.ProjectBuildSpec,
        *,
        project_root: Path,
        args: tuple[str, ...],
    ) -> None:
        captured["spec"] = spec
        captured["root"] = project_root
        captured["args"] = args

    monkeypatch.setattr(cli.bootstrap, "bootstrap", _fake_bootstrap)

    result = CliRunner().invoke(
        cli.main,
        ["run", "--project-root", str(tmp_path), "play", "--seed", "7"],
    )
    assert result.exit_code == 0, result.output
    assert captured["spec"] is project
    assert captured["root"] == tmp_path.resolve()
    assert captured["args"] == ("play", "--seed", "7")


def test_run_missing_cabal_fails_cleanly(tmp_path: Path) -> None:
    result = CliRunner().invoke(cli.main, ["run", "--project-root", str(tmp_path)])
    assert result.exit_code != 0
    assert "no .cabal file found" in result.output


def test_build_invokes_build_binary_and_echoes_path(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    project = _project()
    captured: dict[str, object] = {}
    monkeypatch.setattr(cli, "_load_project", lambda _path: project)

    async def _fake_build_binary(
        spec: bootstrap.ProjectBuildSpec,
        *,
        project_root: Path,
    ) -> Path:
        captured["spec"] = spec
        captured["root"] = project_root
        return project_root / ".build" / "proj"

    monkeypatch.setattr(cli.bootstrap, "build_binary", _fake_build_binary)

    result = CliRunner().invoke(cli.main, ["build", "--project-root", str(tmp_path)])
    assert result.exit_code == 0, result.output
    assert captured["spec"] is project
    assert captured["root"] == tmp_path.resolve()
    assert f"built {tmp_path.resolve() / '.build' / 'proj'}" in result.output


def test_build_multiple_cabal_files_fails_cleanly(tmp_path: Path) -> None:
    (tmp_path / "a.cabal").touch()
    (tmp_path / "b.cabal").touch()
    result = CliRunner().invoke(cli.main, ["build", "--project-root", str(tmp_path)])
    assert result.exit_code != 0
    assert "multiple .cabal files" in result.output


# ---------------------------------------------------------------------------
# doctor command
# ---------------------------------------------------------------------------


def test_doctor_command_outputs_messages_and_reboot(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(cli, "_detect_substrate", lambda: LINUX)
    monkeypatch.setattr(
        cli.prereqs,
        "run_doctor_sync",
        lambda _sub: cli.prereqs.DoctorResult(LINUX, ("one", "two"), reboot_required=True),
    )

    result = CliRunner().invoke(cli.main, ["doctor"])

    assert result.exit_code == 1
    assert "substrate: linux-cpu (amd64)" in result.output
    assert "  - one" in result.output
    assert "reboot required" in result.output


def test_doctor_command_no_reboot(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(cli, "_detect_substrate", lambda: LINUX)
    monkeypatch.setattr(
        cli.prereqs,
        "run_doctor_sync",
        lambda _sub: cli.prereqs.DoctorResult(LINUX, ("ok",)),
    )

    result = CliRunner().invoke(cli.main, ["doctor"])
    assert result.exit_code == 0
    assert "  - ok" in result.output


def test_doctor_command_wraps_prereq_error(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(cli, "_detect_substrate", lambda: LINUX)

    def _raise(*_args: object) -> cli.prereqs.DoctorResult:
        raise cli.prereqs.PrereqError("missing prereq")

    monkeypatch.setattr(cli.prereqs, "run_doctor_sync", _raise)

    result = CliRunner().invoke(cli.main, ["doctor"])
    assert result.exit_code != 0
    assert "missing prereq" in result.output


# ---------------------------------------------------------------------------
# Loaders and helpers
# ---------------------------------------------------------------------------


def test_load_and_detect_helpers(monkeypatch: pytest.MonkeyPatch) -> None:
    project = _project()
    monkeypatch.setattr(cli.bootstrap, "discover_project", lambda _path: project)
    assert cli._load_project(Path("/proj")) is project

    def _bad_project(_path: Path) -> bootstrap.ProjectBuildSpec:
        raise cli.bootstrap.ProjectDiscoveryError("bad project")

    monkeypatch.setattr(cli.bootstrap, "discover_project", _bad_project)
    with pytest.raises(cli.click.ClickException, match="bad project"):
        cli._load_project(Path("/proj"))

    monkeypatch.setattr(cli.substrate, "detect", lambda: LINUX)
    assert cli._detect_substrate() == LINUX

    def _bad_detect() -> Substrate:
        raise RuntimeError("bad host")

    monkeypatch.setattr(cli.substrate, "detect", _bad_detect)
    with pytest.raises(cli.click.ClickException, match="bad host"):
        cli._detect_substrate()


def test_arch_default_uses_detection(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(cli.substrate, "detect", lambda: LINUX)
    assert cli._arch_default() == "amd64"


# ---------------------------------------------------------------------------
# Error formatters
# ---------------------------------------------------------------------------


def test_format_helpers_cover_fallbacks() -> None:
    generic = process.CommandError(
        process.CommandResult(
            args=("cmd", "a", "b", "c"),
            returncode=9,
            stdout="",
            stderr="plain failure",
        )
    )
    assert "`cmd a b" in cli._format_command_error(generic)
    assert "failed (exit 9)" in cli._format_command_error(generic)

    empty = process.CommandError(
        process.CommandResult(args=(), returncode=2, stdout="", stderr="boom")
    )
    assert "command" in cli._format_command_error(empty)

    assert "`sudo` not found" in cli._format_file_not_found(
        FileNotFoundError(2, "missing", b"/usr/bin/sudo")
    )
    assert cli._format_file_not_found(FileNotFoundError()) is None
    assert cli._format_file_not_found(FileNotFoundError(2, "missing", "unknown-tool")) is None
    assert cli._format_http_error(httpx.ConnectError("offline")) == "network error: offline"
    assert cli._format_runtime_error(KeyError("x")) == "unsupported value: 'x'"
    assert cli._format_runtime_error(RuntimeError()) == "RuntimeError"


def test_format_http_error_includes_url() -> None:
    request = httpx.Request("GET", "https://example.invalid/x")
    exc = httpx.ConnectError("offline", request=request)
    assert "reaching https://example.invalid/x" in cli._format_http_error(exc)


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


def _stub_self_check_passing(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(cli, "_run_self_check_or_abort", lambda _context: None)


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
    _stub_self_check_passing(monkeypatch)

    async def _raises(*_a: object, **_kw: object) -> object:
        raise _make_command_error(stderr)

    monkeypatch.setattr(cli.docker_ops, "build", _raises)
    result = CliRunner().invoke(cli.main, ["base", "build-and-push"])
    assert result.exit_code != 0
    assert needle in result.output
    assert "Traceback" not in result.output
    assert "CommandError" not in result.output


def test_friendly_group_converts_file_not_found(monkeypatch: pytest.MonkeyPatch) -> None:
    _stub_self_check_passing(monkeypatch)

    def _raises(*_a: object, **_kw: object) -> object:
        raise FileNotFoundError(2, "missing", "/usr/bin/docker")

    monkeypatch.setattr(cli.base_image, "build_spec_for", _raises)
    result = CliRunner().invoke(cli.main, ["base", "build", "--arch", "amd64"])
    assert result.exit_code != 0
    assert "`docker` not found" in result.output


def test_friendly_group_reraises_unknown_file_not_found(monkeypatch: pytest.MonkeyPatch) -> None:
    _stub_self_check_passing(monkeypatch)

    def _raises(*_a: object, **_kw: object) -> object:
        raise FileNotFoundError(2, "missing", "/usr/bin/unknown-tool")

    monkeypatch.setattr(cli.base_image, "build_spec_for", _raises)
    result = CliRunner().invoke(cli.main, ["base", "build", "--arch", "amd64"])
    assert result.exit_code != 0
    assert isinstance(result.exception, FileNotFoundError)


def test_friendly_group_converts_http_error(monkeypatch: pytest.MonkeyPatch) -> None:
    _stub_self_check_passing(monkeypatch)

    def _raises(*_a: object, **_kw: object) -> object:
        raise httpx.ConnectError("offline")

    monkeypatch.setattr(cli.base_image, "build_spec_for", _raises)
    result = CliRunner().invoke(cli.main, ["base", "build", "--arch", "amd64"])
    assert result.exit_code != 0
    assert "network error" in result.output
    assert "Traceback" not in result.output


@pytest.mark.parametrize(
    ("exc", "needle"),
    [
        (RuntimeError("runtime failed"), "runtime failed"),
        (KeyError("bad-value"), "unsupported value: 'bad-value'"),
    ],
)
def test_friendly_group_converts_known_errors(
    monkeypatch: pytest.MonkeyPatch,
    exc: BaseException,
    needle: str,
) -> None:
    _stub_self_check_passing(monkeypatch)

    def _raises(*_a: object, **_kw: object) -> object:
        raise exc

    monkeypatch.setattr(cli.base_image, "build_spec_for", _raises)

    result = CliRunner().invoke(cli.main, ["base", "build-and-push", "--arch", "amd64"])

    assert result.exit_code != 0
    assert needle in result.output
    assert "Traceback" not in result.output


# ---------------------------------------------------------------------------
# base build / build-and-push + self-check
# ---------------------------------------------------------------------------


def test_base_build_and_push_forces_no_cache(monkeypatch: pytest.MonkeyPatch) -> None:
    _stub_self_check_passing(monkeypatch)
    captured: list[tuple[tuple[object, ...], dict[str, object]]] = []
    pushed: list[str] = []

    def _capture(*args: object, **kwargs: object) -> tuple[docker_ops.BuildSpec, object]:
        captured.append((args, kwargs))
        return _stub_build_spec()

    async def _noop_build(*_a: object, **_kw: object) -> object:
        return process.CommandResult(args=("docker", "build"), returncode=0, stdout="", stderr="")

    async def _noop_push(tag: str, *_a: object, **_kw: object) -> object:
        pushed.append(tag)
        return process.CommandResult(args=("docker", "push"), returncode=0, stdout="", stderr="")

    monkeypatch.setattr(cli.base_image, "build_spec_for", _capture)
    monkeypatch.setattr(cli.docker_ops, "build", _noop_build)
    monkeypatch.setattr(cli.docker_ops, "push", _noop_push)

    result = CliRunner().invoke(cli.main, ["base", "build-and-push", "--arch", "arm64"])
    assert result.exit_code == 0, result.output
    assert [(args[0], args[1]) for args, _kwargs in captured] == [
        (cli.Flavor.CPU, "arm64"),
        (cli.Flavor.CUDA, "arm64"),
    ]
    assert all(kwargs.get("no_cache") is True for _args, kwargs in captured)
    assert all(kwargs.get("pull") is True for _args, kwargs in captured)
    assert pushed == [
        "docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64",
        "docker.io/tuee22/hostbootstrap:basecontainer-cuda-arm64",
    ]


def test_base_build_no_push(monkeypatch: pytest.MonkeyPatch) -> None:
    _stub_self_check_passing(monkeypatch)
    captured: list[tuple[object, object]] = []
    pushed: list[str] = []

    def _capture(*args: object, **_kwargs: object) -> tuple[docker_ops.BuildSpec, object]:
        captured.append((args[0], args[1]))
        return _stub_build_spec()

    async def _noop_build(*_a: object, **_kw: object) -> object:
        return process.CommandResult(args=("docker", "build"), returncode=0, stdout="", stderr="")

    async def _record_push(tag: str, *_a: object, **_kw: object) -> object:
        pushed.append(tag)
        return process.CommandResult(args=("docker", "push"), returncode=0, stdout="", stderr="")

    monkeypatch.setattr(cli.base_image, "build_spec_for", _capture)
    monkeypatch.setattr(cli.docker_ops, "build", _noop_build)
    monkeypatch.setattr(cli.docker_ops, "push", _record_push)

    result = CliRunner().invoke(cli.main, ["base", "build", "--flavor", "cpu", "--arch", "arm64"])
    assert result.exit_code == 0, result.output
    assert captured == [(cli.Flavor.CPU, "arm64")]
    assert pushed == []
    assert "built docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64" in result.output


def test_self_check_runs_poetry_in_context(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    (tmp_path / "pyproject.toml").touch()
    captured: list[tuple[list[str], Path]] = []

    class _CompletedOK:
        returncode = 0

    def _fake_run(cmd: list[str], *, cwd: Path, check: bool = False) -> object:
        _ = check
        captured.append((cmd, cwd))
        return _CompletedOK()

    monkeypatch.setattr(cli.subprocess, "run", _fake_run)
    cli._run_self_check_or_abort(tmp_path)
    assert captured == [
        (
            ["poetry", "run", "python", "-m", "hostbootstrap.check_code"],
            tmp_path,
        )
    ]


def test_self_check_nonzero_raises_click_exception(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    (tmp_path / "pyproject.toml").touch()

    class _Completed:
        returncode = 7

    def _fake_run(*_a: object, **_kw: object) -> object:
        return _Completed()

    monkeypatch.setattr(cli.subprocess, "run", _fake_run)
    with pytest.raises(cli.click.ClickException, match="self-check failed"):
        cli._run_self_check_or_abort(tmp_path)


def test_self_check_missing_poetry_raises_click_exception(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    (tmp_path / "pyproject.toml").touch()

    def _fake_run(*_a: object, **_kw: object) -> object:
        raise FileNotFoundError(2, "No such file or directory", "poetry")

    monkeypatch.setattr(cli.subprocess, "run", _fake_run)
    with pytest.raises(cli.click.ClickException, match="poetry"):
        cli._run_self_check_or_abort(tmp_path)


def test_self_check_rejects_non_repo_root(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    def _fake_run(*_a: object, **_kw: object) -> object:
        raise AssertionError("subprocess.run must not be reached without pyproject.toml")

    monkeypatch.setattr(cli.subprocess, "run", _fake_run)
    with pytest.raises(cli.click.ClickException, match="not a hostbootstrap repo root"):
        cli._run_self_check_or_abort(tmp_path)
