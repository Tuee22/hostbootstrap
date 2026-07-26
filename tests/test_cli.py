"""CLI smoke tests (no docker, no host mutation)."""

from __future__ import annotations

import asyncio
from pathlib import Path

import httpx
import pytest
from click.testing import CliRunner

from hostbootstrap import bootstrap, cli, docker_ops, process, self_update
from hostbootstrap.substrate import Substrate, SubstrateName

LINUX = Substrate(SubstrateName.LINUX_CPU, "amd64")


def _project() -> bootstrap.ProjectBuildSpec:
    return bootstrap.ProjectBuildSpec(
        identity="proj",
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

    default_ref_result = CliRunner().invoke(
        cli.main, ["update", "--spec", "/work", "--ref", "main"]
    )
    assert default_ref_result.exit_code != 0
    assert "cannot be combined" in default_ref_result.output

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
    monkeypatch.setattr(cli, "_load_project", lambda _path, **_kwargs: project)

    async def _fake_bootstrap(
        spec: bootstrap.ProjectBuildSpec,
        *,
        project_root: Path,
        args: tuple[str, ...],
        offline: bool,
    ) -> None:
        captured["spec"] = spec
        captured["root"] = project_root
        captured["args"] = args
        captured["offline"] = offline

    monkeypatch.setattr(cli.bootstrap, "bootstrap", _fake_bootstrap)

    result = CliRunner().invoke(
        cli.main,
        ["run", "--project-root", str(tmp_path), "play", "--seed", "7"],
    )
    assert result.exit_code == 0, result.output
    assert captured["spec"] is project
    assert captured["root"] == tmp_path.resolve()
    assert captured["args"] == ("play", "--seed", "7")
    assert captured["offline"] is False


def test_run_missing_cabal_fails_cleanly(tmp_path: Path) -> None:
    result = CliRunner().invoke(cli.main, ["run", "--project-root", str(tmp_path)])
    assert result.exit_code != 0
    assert "no .cabal file found" in result.output


def test_build_invokes_build_binary_and_echoes_path(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    project = _project()
    captured: dict[str, object] = {}
    monkeypatch.setattr(cli, "_load_project", lambda _path, **_kwargs: project)

    async def _fake_build_binary(
        spec: bootstrap.ProjectBuildSpec,
        *,
        project_root: Path,
        offline: bool,
    ) -> Path:
        captured["spec"] = spec
        captured["root"] = project_root
        captured["offline"] = offline
        return project_root / ".build" / "proj"

    monkeypatch.setattr(cli.bootstrap, "build_binary", _fake_build_binary)

    result = CliRunner().invoke(cli.main, ["build", "--project-root", str(tmp_path)])
    assert result.exit_code == 0, result.output
    assert captured["spec"] is project
    assert captured["root"] == tmp_path.resolve()
    assert captured["offline"] is False
    assert f"built {tmp_path.resolve() / '.build' / 'proj'}" in result.output


def test_build_multiple_cabal_files_fails_cleanly(tmp_path: Path) -> None:
    (tmp_path / "a.cabal").touch()
    (tmp_path / "b.cabal").touch()
    result = CliRunner().invoke(cli.main, ["build", "--project-root", str(tmp_path)])
    assert result.exit_code != 0
    assert "multiple .cabal files" in result.output


def test_build_threads_explicit_cabal_selection_and_offline(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    project = _project()
    captured: dict[str, object] = {}

    def _load(root: Path, *, selected_cabal_file: Path | None) -> bootstrap.ProjectBuildSpec:
        captured["root"] = root
        captured["selection"] = selected_cabal_file
        return project

    async def _build(
        spec: bootstrap.ProjectBuildSpec,
        *,
        project_root: Path,
        offline: bool,
    ) -> Path:
        captured["spec"] = spec
        captured["build_root"] = project_root
        captured["offline"] = offline
        return project_root / ".build" / "proj"

    monkeypatch.setattr(cli, "_load_project", _load)
    monkeypatch.setattr(cli.bootstrap, "build_binary", _build)

    result = CliRunner().invoke(
        cli.main,
        [
            "build",
            "--project-root",
            str(tmp_path),
            "--cabal-file",
            "proj.cabal",
            "--offline",
        ],
    )

    assert result.exit_code == 0, result.output
    assert captured == {
        "root": tmp_path.resolve(),
        "selection": Path("proj.cabal"),
        "spec": project,
        "build_root": tmp_path.resolve(),
        "offline": True,
    }


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
    monkeypatch.setattr(cli.bootstrap, "discover_project", lambda _path, **_kwargs: project)
    assert cli._load_project(Path("/proj")) is project

    def _bad_project(_path: Path, **_kwargs: object) -> bootstrap.ProjectBuildSpec:
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
    authority = cli.MaintainerCommandAuthority(Path.cwd().resolve(), cli._MAINTAINER_TOKEN)
    monkeypatch.setattr(cli, "_require_maintainer_authority", lambda: authority)
    monkeypatch.setattr(cli, "_run_quality_gates_or_abort", lambda _context, _authority: None)

    async def _native(_requested: str, _host: str) -> None:
        return None

    async def _pull(_tag: str, **_kwargs: object) -> object:
        return process.CommandResult(args=("docker", "pull"), returncode=0, stdout="", stderr="")

    async def _digest(tag: str) -> str:
        repository = tag.split(":", 1)[0]
        return f"{repository}@sha256:{'a' * 64}"

    monkeypatch.setattr(cli, "_validate_native_architecture", _native)
    monkeypatch.setattr(cli.docker_ops, "pull", _pull)
    monkeypatch.setattr(cli.docker_ops, "image_digest_reference", _digest)
    monkeypatch.setattr(
        cli.base_image,
        "compatibility_smoke_spec",
        lambda *_args, **_kwargs: _stub_build_spec()[0],
    )
    # Keep base-build tests hermetic: don't probe real host resources.
    monkeypatch.setattr(cli, "_resolve_build_budget", lambda _targets, *, sequential: None)


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


def test_resolve_build_budget_off_linux_returns_none(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(cli.resources, "detect_host_resources", lambda: None)
    assert cli._resolve_build_budget((cli.Flavor.CPU,), sequential=False) is None


def test_resolve_build_budget_aborts_below_floor(monkeypatch: pytest.MonkeyPatch) -> None:
    res = cli.resources.HostResources(cpu_count=1, mem_total_bytes=1, mem_available_bytes=1)
    monkeypatch.setattr(cli.resources, "detect_host_resources", lambda: res)
    with pytest.raises(cli.click.ClickException, match="insufficient host resources"):
        cli._resolve_build_budget((cli.Flavor.CPU, cli.Flavor.CUDA), sequential=False)


def test_resolve_build_budget_splits_for_concurrent_flavors(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    res = cli.resources.HostResources(
        cpu_count=9, mem_total_bytes=32 * 1024**3, mem_available_bytes=24 * 1024**3
    )
    monkeypatch.setattr(cli.resources, "detect_host_resources", lambda: res)

    one = cli._resolve_build_budget((cli.Flavor.CPU,), sequential=False)
    two = cli._resolve_build_budget((cli.Flavor.CPU, cli.Flavor.CUDA), sequential=False)
    seq = cli._resolve_build_budget((cli.Flavor.CPU, cli.Flavor.CUDA), sequential=True)

    assert one is not None and two is not None and seq is not None
    # Two concurrent builds split the host; --sequential collapses back to one.
    assert two.cabal_jobs < one.cabal_jobs
    assert seq.cabal_jobs == one.cabal_jobs


def test_base_build_threads_budget_into_build_spec(monkeypatch: pytest.MonkeyPatch) -> None:
    _stub_self_check_passing(monkeypatch)
    budget = cli.resources.BuildBudget(
        docker_cpus="4",
        docker_memory="8192m",
        docker_memory_swap="8192m",
        cabal_jobs=4,
    )
    monkeypatch.setattr(cli, "_resolve_build_budget", lambda _targets, *, sequential: budget)
    captured: list[object] = []

    def _capture(*_a: object, **kwargs: object) -> tuple[docker_ops.BuildSpec, object]:
        captured.append(kwargs.get("budget"))
        return _stub_build_spec()

    monkeypatch.setattr(cli.base_image, "build_spec_for", _capture)
    monkeypatch.setattr(cli.docker_ops, "build", _ok_build)

    result = CliRunner().invoke(cli.main, ["base", "build", "--flavor", "cpu", "--arch", "amd64"])
    assert result.exit_code == 0, result.output
    assert captured == [budget]


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
    assert "inspection only" in result.output


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
        f"[cpu ] published and validated docker.io/tuee22/hostbootstrap@sha256:{'a' * 64}"
        in result.output
    )
    assert (
        f"[cuda] published and validated docker.io/tuee22/hostbootstrap@sha256:{'a' * 64}"
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


def test_quality_gates_run_all_python_core_and_demo_commands(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    captured: list[tuple[list[str], Path]] = []
    authority = cli.MaintainerCommandAuthority(tmp_path.resolve(), cli._MAINTAINER_TOKEN)

    class _CompletedOK:
        returncode = 0

    def _fake_run(cmd: list[str], *, cwd: Path, check: bool = False) -> object:
        _ = check
        captured.append((cmd, cwd))
        return _CompletedOK()

    monkeypatch.setattr(cli.subprocess, "run", _fake_run)
    cli._run_quality_gates_or_abort(tmp_path, authority)

    assert captured == [
        (list(gate.command), gate.cwd) for gate in cli._quality_gates(tmp_path.resolve())
    ]


def test_quality_gate_nonzero_raises_before_docker(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    authority = cli.MaintainerCommandAuthority(tmp_path.resolve(), cli._MAINTAINER_TOKEN)
    calls = 0

    class _Completed:
        returncode = 7

    def _fake_run(*_a: object, **_kw: object) -> object:
        nonlocal calls
        calls += 1
        return _Completed()

    monkeypatch.setattr(cli.subprocess, "run", _fake_run)
    with pytest.raises(cli.click.ClickException, match="Python code check failed"):
        cli._run_quality_gates_or_abort(tmp_path, authority)
    assert calls == 1


def test_quality_gates_reject_non_authorized_repo_root(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    authority = cli.MaintainerCommandAuthority(
        tmp_path.resolve() / "canonical", cli._MAINTAINER_TOKEN
    )

    def _fake_run(*_a: object, **_kw: object) -> object:
        raise AssertionError("subprocess.run must not be reached for another checkout")

    monkeypatch.setattr(cli.subprocess, "run", _fake_run)
    with pytest.raises(cli.click.ClickException, match="not the canonical checkout"):
        cli._run_quality_gates_or_abort(tmp_path, authority)


def test_native_architecture_requires_request_host_and_engine_match(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def _arm64() -> str:
        return "arm64"

    monkeypatch.setattr(cli.docker_ops, "engine_arch", _arm64)
    asyncio.run(cli._validate_native_architecture("arm64", "arm64"))
    with pytest.raises(cli.click.ClickException, match="must be native"):
        asyncio.run(cli._validate_native_architecture("amd64", "arm64"))


def test_build_then_publish_orders_pull_and_real_consumer_smoke(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    tag = "docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64"
    digest = f"docker.io/tuee22/hostbootstrap@sha256:{'b' * 64}"
    base_spec = _stub_build_spec()[0]
    smoke_spec = docker_ops.BuildSpec(
        dockerfile=tmp_path / "demo/docker/Dockerfile",
        context=tmp_path,
        tags=("compatibility",),
        build_args={"BASE_IMAGE": digest},
    )
    order: list[str] = []

    async def _build(spec: docker_ops.BuildSpec, *, prefix: str = "") -> object:
        _ = prefix
        order.append("base-build" if spec is base_spec else "derived-build")
        return process.CommandResult(args=("docker", "build"), returncode=0, stdout="", stderr="")

    async def _push(value: str, *, prefix: str = "") -> object:
        _ = prefix
        assert value == tag
        order.append("push")
        return process.CommandResult(args=("docker", "push"), returncode=0, stdout="", stderr="")

    async def _pull(value: str, *, prefix: str = "") -> object:
        _ = prefix
        assert value == tag
        order.append("pull")
        return process.CommandResult(args=("docker", "pull"), returncode=0, stdout="", stderr="")

    async def _digest(value: str) -> str:
        assert value == tag
        order.append("digest")
        return digest

    def _validation(
        flavor: cli.Flavor,
        arch: str,
        *,
        context: Path,
        pulled_reference: str,
    ) -> docker_ops.BuildSpec:
        assert (flavor, arch, context, pulled_reference) == (
            cli.Flavor.CPU,
            "arm64",
            tmp_path,
            digest,
        )
        order.append("compatibility-spec")
        return smoke_spec

    monkeypatch.setattr(cli.docker_ops, "build", _build)
    monkeypatch.setattr(cli.docker_ops, "push", _push)
    monkeypatch.setattr(cli.docker_ops, "pull", _pull)
    monkeypatch.setattr(cli.docker_ops, "image_digest_reference", _digest)
    monkeypatch.setattr(cli.base_image, "compatibility_smoke_spec", _validation)

    result = asyncio.run(
        cli._build_then_publish(
            base_spec,
            tag,
            cli.Flavor.CPU,
            "arm64",
            tmp_path,
        )
    )

    assert result == digest
    assert order == [
        "base-build",
        "push",
        "pull",
        "digest",
        "compatibility-spec",
        "derived-build",
    ]


# ---------------------------------------------------------------------------
# Maintainer-only command gating (dev venv vs global pipx)
# ---------------------------------------------------------------------------


def test_maintainer_authority_is_opaque_and_bound_to_repo_poetry_venv(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    authority = cli._maintainer_command_authority()
    assert authority is not None
    assert authority.repository_root == Path.cwd().resolve()
    with pytest.raises(TypeError, match="minted only"):
        cli.MaintainerCommandAuthority(Path.cwd(), object())

    pipx_prefix = Path("/tmp/pipx/venvs/hostbootstrap")
    monkeypatch.setattr(cli.sys, "prefix", str(pipx_prefix))
    monkeypatch.setattr(cli.sys, "base_prefix", "/usr")
    monkeypatch.setattr(cli.sys, "executable", str(pipx_prefix / "bin/python"))
    monkeypatch.setattr(cli.importlib.util, "find_spec", lambda _name: object())
    assert cli._maintainer_command_authority() is None
    assert cli._maintainer_cli_enabled() is False


def test_maintainer_authority_rejects_unreadable_checkout(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def _unreadable(_text: str) -> object:
        raise OSError("checkout disappeared")

    monkeypatch.setattr(cli.tomllib, "loads", _unreadable)
    assert cli._maintainer_command_authority() is None


def test_require_maintainer_authority_fails_without_checkout_proof(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(cli, "_maintainer_command_authority", lambda: None)
    with pytest.raises(cli.click.ClickException, match="in-project Poetry"):
        cli._require_maintainer_authority()


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
    authority = cli.MaintainerCommandAuthority(Path.cwd().resolve(), cli._MAINTAINER_TOKEN)
    monkeypatch.setattr(cli, "_maintainer_command_authority", lambda: authority)
    monkeypatch.setattr(cli.check_code, "main", lambda: 0)
    assert CliRunner().invoke(cli.main, ["check-code"]).exit_code == 0

    monkeypatch.setattr(cli.check_code, "main", lambda: 3)
    assert CliRunner().invoke(cli.main, ["check-code"]).exit_code == 3


def test_test_all_command_forwards_args_and_exit_code(monkeypatch: pytest.MonkeyPatch) -> None:
    authority = cli.MaintainerCommandAuthority(Path.cwd().resolve(), cli._MAINTAINER_TOKEN)
    monkeypatch.setattr(cli, "_maintainer_command_authority", lambda: authority)
    captured: dict[str, list[str]] = {}

    def _run(args: list[str]) -> int:
        captured["args"] = args
        return 0

    monkeypatch.setattr(cli.test_all, "run", _run)
    assert CliRunner().invoke(cli.main, ["test-all", "-k", "models", "-q"]).exit_code == 0
    assert captured["args"] == ["-k", "models", "-q"]

    monkeypatch.setattr(cli.test_all, "run", lambda _args: 5)
    assert CliRunner().invoke(cli.main, ["test-all"]).exit_code == 5
