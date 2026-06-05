"""CLI smoke tests (no docker, no host mutation)."""

from __future__ import annotations

from pathlib import Path

import httpx
import pytest
from click.testing import CliRunner

from hostbootstrap import cli, docker_ops, process
from hostbootstrap.spec import (
    ContainerModel,
    HostBinaryModel,
    HostDaemonModel,
    Lifecycle,
    ProjectSpec,
    TargetSpec,
)
from hostbootstrap.substrate import Substrate, SubstrateName

LINUX = Substrate(SubstrateName.LINUX_CPU, "amd64")


def _container_model() -> ContainerModel:
    return ContainerModel(dockerfile=Path("Dockerfile"), mounts=())


def _binary_model() -> HostBinaryModel:
    return HostBinaryModel()


def _daemon_model() -> HostDaemonModel:
    return HostDaemonModel(daemon="service --role worker")


def _project(model: object, *, lifecycle: Lifecycle = Lifecycle.CLUSTER) -> ProjectSpec:
    return ProjectSpec(
        project="proj",
        targets={SubstrateName.LINUX_CPU: TargetSpec(lifecycle, model)},  # type: ignore[arg-type]
        source_path=Path("/proj/hostbootstrap.dhall"),
    )


def _project_all_targets() -> ProjectSpec:
    return ProjectSpec(
        project="proj",
        targets={
            SubstrateName.APPLE_SILICON: TargetSpec(Lifecycle.CLUSTER, _daemon_model()),
            SubstrateName.LINUX_CPU: TargetSpec(Lifecycle.CLUSTER, _container_model()),
            SubstrateName.LINUX_GPU: TargetSpec(Lifecycle.NO_CLUSTER, _binary_model()),
        },
        source_path=Path("/proj/hostbootstrap.dhall"),
    )


def test_help_lists_commands_and_omits_push() -> None:
    result = CliRunner().invoke(cli.main, ["--help"])
    assert result.exit_code == 0
    for command in ("doctor", "build", "cluster", "daemon", "run", "base"):
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


def test_daemon_subcommands() -> None:
    result = CliRunner().invoke(cli.main, ["daemon", "--help"])
    assert result.exit_code == 0
    assert "run" in result.output
    assert "start" not in result.output
    assert "stop" not in result.output


def test_run_exposes_local_base_build_and_force_target_options() -> None:
    result = CliRunner().invoke(cli.main, ["run", "--help"])
    assert result.exit_code == 0
    assert "--build-base" in result.output
    assert "--base-context" in result.output
    assert "--force-target" in result.output


def test_run_forwards_help_after_runtime_args(monkeypatch: pytest.MonkeyPatch) -> None:
    project = _project(_container_model())
    captured: list[tuple[str, ...]] = []
    monkeypatch.setattr(cli, "_load_spec", lambda _path: project)
    monkeypatch.setattr(cli, "_detect_substrate", lambda: LINUX)

    async def _fake_run(
        _spec: ProjectSpec,
        _sub: Substrate,
        _root: Path,
        command: tuple[str, ...],
        **_kwargs: object,
    ) -> process.CommandResult:
        captured.append(command)
        return process.CommandResult(args=command, returncode=0, stdout="", stderr="")

    monkeypatch.setattr(cli, "_run", _fake_run)

    result = CliRunner().invoke(cli.main, ["run", "play", "--help"])

    assert result.exit_code == 0
    assert captured == [("play", "--help")]


def test_build_missing_spec_fails_cleanly(tmp_path: Path) -> None:
    missing = tmp_path / "hostbootstrap.dhall"
    result = CliRunner().invoke(cli.main, ["build", "--spec", str(missing)])
    assert result.exit_code != 0
    assert "not found" in result.output


def test_default_spec_path_is_dhall() -> None:
    assert Path("hostbootstrap.dhall") == cli._DEFAULT_SPEC_PATH


def test_load_detect_and_base_context_helpers(monkeypatch: pytest.MonkeyPatch) -> None:
    project = _project(_container_model())
    monkeypatch.setattr(cli.spec, "load", lambda _path: project)
    assert cli._load_spec(Path("x.dhall")) is project

    def _bad_spec(_path: Path) -> ProjectSpec:
        raise cli.SpecError("bad spec")

    monkeypatch.setattr(cli.spec, "load", _bad_spec)
    with pytest.raises(cli.click.ClickException, match="bad spec"):
        cli._load_spec(Path("x.dhall"))

    monkeypatch.setattr(cli.substrate, "detect", lambda: LINUX)
    assert cli._detect_substrate() == LINUX

    def _bad_detect() -> Substrate:
        raise RuntimeError("bad host")

    monkeypatch.setattr(cli.substrate, "detect", _bad_detect)
    with pytest.raises(cli.click.ClickException, match="bad host"):
        cli._detect_substrate()

    assert cli._base_context_value(False, Path("/repo")) is None
    assert cli._base_context_value(True, Path("/repo")) == Path("/repo")
    with pytest.raises(cli.click.ClickException, match="--base-context"):
        cli._base_context_value(True, None)

    assert cli._parse_force_target(None) is None
    assert cli._parse_force_target("apple-silicon") is SubstrateName.APPLE_SILICON


def test_target_env_records_selected_target_model_and_lifecycle() -> None:
    project = _project_all_targets()
    resolved = project.target_for(LINUX, force_target=SubstrateName.APPLE_SILICON)
    assert cli._target_env(resolved) == {
        "HOSTBOOTSTRAP_TARGET": "apple-silicon",
        "HOSTBOOTSTRAP_MODEL": "host-daemon",
        "HOSTBOOTSTRAP_LIFECYCLE": "cluster",
    }


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

    assert "`sudo` not found" in cli._format_file_not_found(
        FileNotFoundError(2, "missing", b"/usr/bin/sudo")
    )
    assert cli._format_file_not_found(FileNotFoundError()) is None
    assert cli._format_file_not_found(FileNotFoundError(2, "missing", "unknown-tool")) is None
    assert cli._format_http_error(httpx.ConnectError("offline")) == "network error: offline"
    assert cli._format_runtime_error(KeyError("x")) == "unsupported value: 'x'"
    assert cli._format_runtime_error(RuntimeError()) == "RuntimeError"


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


@pytest.mark.parametrize(
    ("exc", "needle"),
    [
        (cli.dhall_tool.DhallToolError("dhall failed"), "dhall failed"),
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


def test_doctor_command_outputs_messages_and_reboot(monkeypatch: pytest.MonkeyPatch) -> None:
    project = _project(_container_model())
    monkeypatch.setattr(cli, "_load_spec", lambda _path: project)
    monkeypatch.setattr(cli, "_detect_substrate", lambda: LINUX)
    monkeypatch.setattr(
        cli.prereqs,
        "run_doctor_sync",
        lambda _spec, _sub: cli.prereqs.DoctorResult(LINUX, ("one", "two"), reboot_required=True),
    )

    result = CliRunner().invoke(cli.main, ["doctor"])

    assert result.exit_code == 1
    assert "substrate: linux-cpu (amd64)" in result.output
    assert "  - one" in result.output
    assert "reboot required" in result.output


def test_doctor_command_wraps_prereq_error(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(cli, "_load_spec", lambda _path: _project(_container_model()))
    monkeypatch.setattr(cli, "_detect_substrate", lambda: LINUX)

    def _raise(*_args: object) -> cli.prereqs.DoctorResult:
        raise cli.prereqs.PrereqError("missing prereq")

    monkeypatch.setattr(cli.prereqs, "run_doctor_sync", _raise)

    result = CliRunner().invoke(cli.main, ["doctor"])
    assert result.exit_code != 0
    assert "missing prereq" in result.output


def test_click_commands_pass_force_target_and_base_options(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    project = _project_all_targets()
    spec_path = tmp_path / "hostbootstrap.dhall"
    base_context = tmp_path / "base"
    calls: list[tuple[str, object]] = []
    monkeypatch.setattr(cli, "_load_spec", lambda _path: project)
    monkeypatch.setattr(cli, "_detect_substrate", lambda: LINUX)

    async def _fake_build(
        _spec: ProjectSpec,
        _sub: Substrate,
        root: Path,
        **kwargs: object,
    ) -> None:
        calls.append(("build-root", root))
        calls.append(("build-force", kwargs["force_target"]))
        calls.append(("build-base-context", kwargs["base_context"]))

    async def _fake_run(
        _spec: ProjectSpec,
        _sub: Substrate,
        root: Path,
        command: tuple[str, ...],
        **kwargs: object,
    ) -> process.CommandResult:
        calls.append(("run-root", root))
        calls.append(("run-command", command))
        calls.append(("run-force", kwargs["force_target"]))
        return process.CommandResult(args=command, returncode=0, stdout="", stderr="")

    async def _fake_cluster_up(
        _spec: ProjectSpec,
        _sub: Substrate,
        root: Path,
        **kwargs: object,
    ) -> None:
        calls.append(("cluster-up-root", root))
        calls.append(("cluster-up-force", kwargs["force_target"]))

    async def _fake_cluster_down(
        _spec: ProjectSpec,
        _sub: Substrate,
        root: Path,
        **kwargs: object,
    ) -> None:
        calls.append(("cluster-down-root", root))
        calls.append(("cluster-down-force", kwargs["force_target"]))

    async def _fake_cluster_delete(
        _spec: ProjectSpec,
        _sub: Substrate,
        root: Path,
        **kwargs: object,
    ) -> None:
        calls.append(("cluster-delete-root", root))
        calls.append(("cluster-delete-force", kwargs["force_target"]))

    async def _fake_daemon_run(
        _spec: ProjectSpec,
        _sub: Substrate,
        root: Path,
        **kwargs: object,
    ) -> process.CommandResult:
        calls.append(("daemon-run-root", root))
        calls.append(("daemon-run-force", kwargs["force_target"]))
        return process.CommandResult(args=(), returncode=0, stdout="", stderr="")

    monkeypatch.setattr(cli, "_build", _fake_build)
    monkeypatch.setattr(cli, "_run", _fake_run)
    monkeypatch.setattr(cli, "_cluster_up", _fake_cluster_up)
    monkeypatch.setattr(cli, "_cluster_down", _fake_cluster_down)
    monkeypatch.setattr(cli, "_cluster_delete", _fake_cluster_delete)
    monkeypatch.setattr(cli, "_daemon_run", _fake_daemon_run)

    runner = CliRunner()
    assert (
        runner.invoke(
            cli.main,
            [
                "build",
                "--spec",
                str(spec_path),
                "--build-base",
                "--base-context",
                str(base_context),
                "--force-target",
                "apple-silicon",
            ],
        ).exit_code
        == 0
    )
    assert (
        runner.invoke(
            cli.main,
            [
                "run",
                "--spec",
                str(spec_path),
                "--force-target",
                "linux-gpu",
                "echo",
                "hi",
            ],
        ).exit_code
        == 0
    )
    assert (
        runner.invoke(
            cli.main,
            ["cluster", "up", "--spec", str(spec_path), "--force-target", "apple-silicon"],
        ).exit_code
        == 0
    )
    assert (
        runner.invoke(
            cli.main,
            ["cluster", "down", "--spec", str(spec_path), "--force-target", "apple-silicon"],
        ).exit_code
        == 0
    )
    assert (
        runner.invoke(
            cli.main,
            ["cluster", "delete", "--spec", str(spec_path), "--force-target", "apple-silicon"],
        ).exit_code
        == 0
    )
    assert (
        runner.invoke(
            cli.main,
            ["daemon", "run", "--spec", str(spec_path), "--force-target", "apple-silicon"],
        ).exit_code
        == 0
    )

    assert ("build-root", tmp_path) in calls
    assert ("build-force", SubstrateName.APPLE_SILICON) in calls
    assert ("build-base-context", base_context) in calls
    assert ("run-command", ("echo", "hi")) in calls
    assert ("run-force", SubstrateName.LINUX_GPU) in calls
    assert ("cluster-up-force", SubstrateName.APPLE_SILICON) in calls
    assert ("cluster-down-force", SubstrateName.APPLE_SILICON) in calls
    assert ("cluster-delete-force", SubstrateName.APPLE_SILICON) in calls
    assert ("daemon-run-force", SubstrateName.APPLE_SILICON) in calls


async def test_build_and_run_dispatch_to_model_backends(
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
) -> None:
    calls: list[tuple[str, tuple[str, ...] | None]] = []

    async def _container_build(*_args: object, **_kwargs: object) -> None:
        calls.append(("container-build", None))

    async def _binary_build(*_args: object, **_kwargs: object) -> None:
        calls.append(("binary-build", None))

    async def _daemon_build(*_args: object, **_kwargs: object) -> None:
        calls.append(("daemon-build", None))

    async def _container_run(
        *_args: object,
        **_kwargs: object,
    ) -> process.CommandResult:
        calls.append(("container-run", None))
        return process.CommandResult(args=(), returncode=0, stdout="", stderr="")

    async def _binary_run(
        *_args: object,
        command: tuple[str, ...] | None = None,
        **_kwargs: object,
    ) -> process.CommandResult:
        captured = _args[3] if len(_args) > 3 else command
        calls.append(("binary-run", captured))  # type: ignore[arg-type]
        return process.CommandResult(args=command or (), returncode=0, stdout="", stderr="")

    async def _daemon_run(
        *_args: object,
        command: tuple[str, ...] | None = None,
        **_kwargs: object,
    ) -> process.CommandResult:
        captured = _args[3] if len(_args) > 3 else command
        calls.append(("daemon-run", captured))  # type: ignore[arg-type]
        return process.CommandResult(args=command or (), returncode=0, stdout="", stderr="")

    monkeypatch.setattr(cli.container_model, "build", _container_build)
    monkeypatch.setattr(cli.host_binary, "build", _binary_build)
    monkeypatch.setattr(cli.host_daemon, "build", _daemon_build)
    monkeypatch.setattr(cli.container_model, "run_one_shot", _container_run)
    monkeypatch.setattr(cli.host_binary, "run_one_shot", _binary_run)
    monkeypatch.setattr(cli.host_daemon, "run_one_shot", _daemon_run)

    for model in (_container_model(), _binary_model(), _daemon_model()):
        await cli._build(_project(model), LINUX, project_root)
        await cli._run(_project(model), LINUX, project_root, ("status",))

    assert [name for name, _command in calls] == [
        "container-build",
        "container-run",
        "binary-build",
        "binary-run",
        "daemon-build",
        "daemon-run",
    ]


async def test_cluster_helpers_forward_project_commands(
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
) -> None:
    calls: list[tuple[str, object]] = []

    async def _container_cluster(
        *_args: object,
        **kwargs: object,
    ) -> process.CommandResult:
        calls.append(("container-cluster", _args[3]))  # command positional argument
        calls.append(("container-env", kwargs["env"]))
        return process.CommandResult(args=(), returncode=0, stdout="", stderr="")

    async def _binary_run(
        *_args: object,
        command: tuple[str, ...] | None = None,
        **kwargs: object,
    ) -> process.CommandResult:
        captured = _args[3] if len(_args) > 3 else command
        calls.append(("binary-run", captured))  # type: ignore[arg-type]
        calls.append(("binary-env", kwargs["env"]))
        return process.CommandResult(args=command or (), returncode=0, stdout="", stderr="")

    async def _daemon_run(
        *_args: object,
        command: tuple[str, ...] | None = None,
        **kwargs: object,
    ) -> process.CommandResult:
        captured = _args[3] if len(_args) > 3 else command
        calls.append(("daemon-run", captured))  # type: ignore[arg-type]
        calls.append(("daemon-env", kwargs["env"]))
        return process.CommandResult(args=command or (), returncode=0, stdout="", stderr="")

    monkeypatch.setattr(cli.container_model, "run_cluster_command", _container_cluster)
    monkeypatch.setattr(cli.host_binary, "run_one_shot", _binary_run)
    monkeypatch.setattr(cli.host_daemon, "run_one_shot", _daemon_run)

    await cli._cluster_up(_project(_container_model()), LINUX, project_root)
    await cli._cluster_down(_project(_binary_model()), LINUX, project_root)
    await cli._cluster_up(_project(_daemon_model()), LINUX, project_root)
    await cli._cluster_delete(_project(_daemon_model()), LINUX, project_root)

    assert ("container-cluster", ("cluster", "up")) in calls
    assert ("binary-run", ("cluster", "down")) in calls
    assert ("daemon-run", ("cluster", "up")) in calls
    assert ("daemon-run", ("cluster", "delete")) in calls
    assert (
        "container-env",
        {
            "HOSTBOOTSTRAP_TARGET": "linux-cpu",
            "HOSTBOOTSTRAP_MODEL": "container",
            "HOSTBOOTSTRAP_LIFECYCLE": "cluster",
        },
    ) in calls
    assert (
        "binary-env",
        {
            "HOSTBOOTSTRAP_TARGET": "linux-cpu",
            "HOSTBOOTSTRAP_MODEL": "host-binary",
            "HOSTBOOTSTRAP_LIFECYCLE": "cluster",
        },
    ) in calls
    assert ("daemon-start", None) not in calls
    assert ("daemon-stop", None) not in calls


async def test_daemon_run_requires_host_daemon_target(
    monkeypatch: pytest.MonkeyPatch,
    project_root: Path,
) -> None:
    calls: list[tuple[str, object]] = []

    async def _run_daemon(*_args: object, **kwargs: object) -> process.CommandResult:
        calls.append(("env", kwargs["env"]))
        return process.CommandResult(args=(), returncode=0, stdout="", stderr="")

    monkeypatch.setattr(cli.host_daemon, "run_daemon", _run_daemon)

    await cli._daemon_run(_project(_daemon_model()), LINUX, project_root)
    assert (
        "env",
        {
            "HOSTBOOTSTRAP_TARGET": "linux-cpu",
            "HOSTBOOTSTRAP_MODEL": "host-daemon",
            "HOSTBOOTSTRAP_LIFECYCLE": "cluster",
        },
    ) in calls

    with pytest.raises(RuntimeError, match="requires a HostDaemon target"):
        await cli._daemon_run(_project(_container_model()), LINUX, project_root)


async def test_no_cluster_rejects_cluster_lifecycle(project_root: Path) -> None:
    project = _project(_container_model(), lifecycle=Lifecycle.NO_CLUSTER)
    with pytest.raises(RuntimeError, match="NoCluster"):
        await cli._cluster_up(project, LINUX, project_root)


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


def test_self_check_runs_poetry_in_context(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: list[tuple[list[str], Path]] = []

    class _CompletedOK:
        returncode = 0

    def _fake_run(cmd: list[str], *, cwd: Path, check: bool = False) -> object:
        _ = check
        captured.append((cmd, cwd))
        return _CompletedOK()

    monkeypatch.setattr(cli.subprocess, "run", _fake_run)
    cli._run_self_check_or_abort(Path("/tmp/repo"))
    assert captured == [
        (
            ["poetry", "run", "python", "-m", "hostbootstrap.check_code"],
            Path("/tmp/repo"),
        )
    ]


def test_self_check_nonzero_raises_click_exception(monkeypatch: pytest.MonkeyPatch) -> None:
    class _Completed:
        returncode = 7

    def _fake_run(*_a: object, **_kw: object) -> object:
        return _Completed()

    monkeypatch.setattr(cli.subprocess, "run", _fake_run)
    with pytest.raises(cli.click.ClickException, match="self-check failed"):
        cli._run_self_check_or_abort(Path("/tmp/repo"))


def test_self_check_missing_poetry_raises_click_exception(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fake_run(*_a: object, **_kw: object) -> object:
        raise FileNotFoundError(2, "No such file or directory", "poetry")

    monkeypatch.setattr(cli.subprocess, "run", _fake_run)
    with pytest.raises(cli.click.ClickException, match="poetry"):
        cli._run_self_check_or_abort(Path("/tmp/repo"))


def test_resolve_pull_combinations() -> None:
    assert cli._resolve_pull(build_base=False, no_pull=False) is True
    assert cli._resolve_pull(build_base=True, no_pull=False) is False
    assert cli._resolve_pull(build_base=False, no_pull=True) is False
    with pytest.raises(cli.click.ClickException, match="mutually exclusive"):
        cli._resolve_pull(build_base=True, no_pull=True)
