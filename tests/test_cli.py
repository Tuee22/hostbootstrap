"""CLI smoke tests (no docker, no host mutation)."""

from __future__ import annotations

from pathlib import Path

import httpx
import pytest
from click.testing import CliRunner

from hostbootstrap import bootstrap, cli, docker_ops, process, self_update
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


def _help_commands(output: str) -> set[str]:
    return {
        line.strip().split()[0]
        for line in output.splitlines()
        if line.startswith("  ") and line.strip()
    }


def test_help_lists_only_thin_commands() -> None:
    result = CliRunner().invoke(cli.main, ["--help"])
    assert result.exit_code == 0
    commands = _help_commands(result.output)
    # In a dev (Poetry) install the maintainer commands are visible too.
    for command in ("doctor", "build", "run", "base", "update", "check-code", "test-all"):
        assert command in commands
    for unsupported in ("up", "cluster", "daemon", "push"):
        assert unsupported not in commands


@pytest.mark.parametrize("unsupported", ["up", "cluster", "daemon", "push"])
def test_non_bootstrap_commands_are_not_python_commands(unsupported: str) -> None:
    result = CliRunner().invoke(cli.main, [unsupported])
    assert result.exit_code != 0
    assert "No such command" in result.output


def test_run_has_no_force_target_or_pull_option() -> None:
    result = CliRunner().invoke(cli.main, ["run", "--help"])
    assert result.exit_code == 0
    # The pre-binary bootstrapper neither builds the container nor pulls the base.
    assert "--force-target" not in result.output
    assert "--no-pull" not in result.output


def test_update_help_is_explicit_self_update_surface() -> None:
    result = CliRunner().invoke(cli.main, ["update", "--help"])
    assert result.exit_code == 0
    assert "--ref" in result.output
    assert "--spec" in result.output
    assert "--check" in result.output


def test_update_invokes_self_update(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, object] = {}

    def _run_update(*, ref: str, spec: str | None) -> str:
        captured["ref"] = ref
        captured["spec"] = spec
        return spec or self_update.direct_vcs_spec(ref)

    monkeypatch.setattr(cli.self_update, "run_update", _run_update)

    result = CliRunner().invoke(cli.main, ["update", "--ref", "feature"])

    assert result.exit_code == 0, result.output
    assert captured == {"ref": "feature", "spec": None}
    assert "updated hostbootstrap from" in result.output
    assert "@feature" in result.output


def test_update_accepts_explicit_spec(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, object] = {}

    def _run_update(*, ref: str, spec: str | None) -> str:
        captured["ref"] = ref
        captured["spec"] = spec
        return spec or self_update.direct_vcs_spec(ref)

    monkeypatch.setattr(cli.self_update, "run_update", _run_update)

    result = CliRunner().invoke(cli.main, ["update", "--spec", "/work/hostbootstrap"])

    assert result.exit_code == 0, result.output
    assert captured == {"ref": self_update.DEFAULT_REF, "spec": "/work/hostbootstrap"}
    assert "updated hostbootstrap from /work/hostbootstrap" in result.output


def test_update_rejects_conflicting_options() -> None:
    result = CliRunner().invoke(cli.main, ["update", "--spec", "/work", "--ref", "feature"])
    assert result.exit_code != 0
    assert "cannot be combined" in result.output

    check_result = CliRunner().invoke(cli.main, ["update", "--check", "--spec", "/work"])
    assert check_result.exit_code != 0
    assert "cannot be combined" in check_result.output


def test_update_wraps_self_update_errors(monkeypatch: pytest.MonkeyPatch) -> None:
    def _raise(*, ref: str, spec: str | None) -> str:
        raise self_update.SelfUpdateError("pipx failed")

    monkeypatch.setattr(cli.self_update, "run_update", _raise)

    result = CliRunner().invoke(cli.main, ["update"])

    assert result.exit_code != 0
    assert "pipx failed" in result.output
    assert "Traceback" not in result.output


def test_update_check_reports_up_to_date(monkeypatch: pytest.MonkeyPatch) -> None:
    def _check_status(*, ref: str) -> self_update.CheckStatus:
        assert ref == "main"
        return self_update.CheckStatus(
            installed_commit="a" * 40,
            remote_commit="a" * 40,
            requested_revision="main",
        )

    monkeypatch.setattr(cli.self_update, "check_status", _check_status)

    result = CliRunner().invoke(cli.main, ["update", "--check"])

    assert result.exit_code == 0
    assert "up to date" in result.output


def test_update_check_reports_available_update(monkeypatch: pytest.MonkeyPatch) -> None:
    def _check_status(*, ref: str) -> self_update.CheckStatus:
        return self_update.CheckStatus(
            installed_commit="a" * 40,
            remote_commit="b" * 40,
            requested_revision="main",
        )

    monkeypatch.setattr(cli.self_update, "check_status", _check_status)

    result = CliRunner().invoke(cli.main, ["update", "--check"])

    assert result.exit_code == 1
    assert "update available" in result.output
    assert "aaaaaaaaaaaa" in result.output
    assert "bbbbbbbbbbbb" in result.output


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


async def _ok_build(*_a: object, **_kw: object) -> object:
    return process.CommandResult(args=("docker", "build"), returncode=0, stdout="", stderr="")


def test_base_build_and_push_concurrent_labels_each_stream(monkeypatch: pytest.MonkeyPatch) -> None:
    """No ``--flavor`` builds both flavors concurrently, labelling each line."""
    _stub_self_check_passing(monkeypatch)
    _patch_build_spec(monkeypatch)

    async def _ok_push(_tag: str, *_a: object, **_kw: object) -> object:
        return process.CommandResult(args=("docker", "push"), returncode=0, stdout="", stderr="")

    monkeypatch.setattr(cli.docker_ops, "build", _ok_build)
    monkeypatch.setattr(cli.docker_ops, "push", _ok_push)

    result = CliRunner().invoke(cli.main, ["base", "build-and-push", "--arch", "amd64"])
    assert result.exit_code == 0, result.output
    # cpu is padded to cuda's width so the labels align.
    assert (
        "[cpu ] built and pushed docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64"
        in result.output
    )
    assert (
        "[cuda] built and pushed docker.io/tuee22/hostbootstrap:basecontainer-cuda-amd64"
        in result.output
    )


def test_base_build_and_push_sequential(monkeypatch: pytest.MonkeyPatch) -> None:
    """``--sequential`` pushes the flavors strictly in order."""
    _stub_self_check_passing(monkeypatch)
    _patch_build_spec(monkeypatch)
    order: list[str] = []

    async def _record_push(tag: str, *_a: object, **_kw: object) -> object:
        order.append(tag)
        return process.CommandResult(args=("docker", "push"), returncode=0, stdout="", stderr="")

    monkeypatch.setattr(cli.docker_ops, "build", _ok_build)
    monkeypatch.setattr(cli.docker_ops, "push", _record_push)

    result = CliRunner().invoke(
        cli.main, ["base", "build-and-push", "--arch", "amd64", "--sequential"]
    )
    assert result.exit_code == 0, result.output
    assert order == [
        "docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64",
        "docker.io/tuee22/hostbootstrap:basecontainer-cuda-amd64",
    ]


def test_base_build_both_flavors_concurrent_no_push(monkeypatch: pytest.MonkeyPatch) -> None:
    """``base build`` (no push) builds both flavors concurrently, labelled."""
    _stub_self_check_passing(monkeypatch)
    _patch_build_spec(monkeypatch)
    pushed: list[str] = []

    async def _record_push(tag: str, *_a: object, **_kw: object) -> object:
        pushed.append(tag)
        return process.CommandResult(args=("docker", "push"), returncode=0, stdout="", stderr="")

    monkeypatch.setattr(cli.docker_ops, "build", _ok_build)
    monkeypatch.setattr(cli.docker_ops, "push", _record_push)

    result = CliRunner().invoke(cli.main, ["base", "build", "--arch", "amd64"])
    assert result.exit_code == 0, result.output
    assert pushed == []
    assert "[cpu ] built docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64" in result.output
    assert "[cuda] built docker.io/tuee22/hostbootstrap:basecontainer-cuda-amd64" in result.output


def test_self_check_runs_check_code_in_context(
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
    # Runs in the current (dev) interpreter, not `poetry run`, since base is dev-only.
    assert captured == [
        (
            [cli.sys.executable, "-m", "hostbootstrap.check_code"],
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


def test_self_check_rejects_non_repo_root(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    def _fake_run(*_a: object, **_kw: object) -> object:
        raise AssertionError("subprocess.run must not be reached without pyproject.toml")

    monkeypatch.setattr(cli.subprocess, "run", _fake_run)
    with pytest.raises(cli.click.ClickException, match="not a hostbootstrap repo root"):
        cli._run_self_check_or_abort(tmp_path)


# ---------------------------------------------------------------------------
# Maintainer-only command gating (dev venv vs global pipx)
# ---------------------------------------------------------------------------


def test_maintainer_cli_enabled_reflects_toolchain(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(cli.importlib.util, "find_spec", lambda _name: object())
    assert cli._maintainer_cli_enabled() is True

    def _missing_pytest(name: str) -> object | None:
        return None if name == "pytest" else object()

    monkeypatch.setattr(cli.importlib.util, "find_spec", _missing_pytest)
    assert cli._maintainer_cli_enabled() is False


def test_maintainer_commands_hidden_in_global_cli(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(cli, "_maintainer_cli_enabled", lambda: False)

    commands = _help_commands(CliRunner().invoke(cli.main, ["--help"]).output)
    for hidden in ("base", "check-code", "test-all"):
        assert hidden not in commands
    # The consumer surface still works.
    for consumer in ("doctor", "build", "run", "update"):
        assert consumer in commands

    for argv in (["base", "build-and-push"], ["check-code"], ["test-all"]):
        result = CliRunner().invoke(cli.main, argv)
        assert result.exit_code != 0
        assert "No such command" in result.output


def test_check_code_command_propagates_exit_code(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(cli.check_code, "main", lambda: 0)
    assert CliRunner().invoke(cli.main, ["check-code"]).exit_code == 0

    monkeypatch.setattr(cli.check_code, "main", lambda: 3)
    assert CliRunner().invoke(cli.main, ["check-code"]).exit_code == 3


def test_test_all_command_forwards_args_and_exit_code(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, list[str]] = {}

    def _run(args: list[str]) -> int:
        captured["args"] = args
        return 0

    monkeypatch.setattr(cli.test_all, "run", _run)
    assert CliRunner().invoke(cli.main, ["test-all", "-k", "models", "-q"]).exit_code == 0
    assert captured["args"] == ["-k", "models", "-q"]

    monkeypatch.setattr(cli.test_all, "run", lambda _args: 5)
    assert CliRunner().invoke(cli.main, ["test-all"]).exit_code == 5
