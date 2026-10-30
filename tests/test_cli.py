"""CLI smoke tests (no docker, no host mutation)."""

from __future__ import annotations

import asyncio
import sys
import tomllib
from dataclasses import replace
from pathlib import Path

import httpx
import pytest
from click.testing import CliRunner

from hostbootstrap import bootstrap, cli, docker_ops, process, self_update
from hostbootstrap.substrate import Arch, Substrate, SubstrateName

LINUX = Substrate(SubstrateName.LINUX_CPU, Arch.AMD64)


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
    def _check_status(*, ref: str | None) -> self_update.CheckStatus:
        assert ref is None
        return self_update.CheckStatus(
            installed_commit="a" * 40,
            remote_commit="a" * 40,
            requested_revision="v1.2",
            compared_ref="v1.2",
        )

    monkeypatch.setattr(cli.self_update, "check_status", _check_status)

    result = CliRunner().invoke(cli.main, ["update", "--check"])

    assert result.exit_code == 0
    assert "up to date" in result.output
    assert "v1.2" in result.output


def test_update_check_reports_available_update(monkeypatch: pytest.MonkeyPatch) -> None:
    def _check_status(*, ref: str | None) -> self_update.CheckStatus:
        assert ref == "feature"
        return self_update.CheckStatus(
            installed_commit="a" * 40,
            remote_commit="b" * 40,
            requested_revision="main",
            compared_ref="feature",
        )

    monkeypatch.setattr(cli.self_update, "check_status", _check_status)

    result = CliRunner().invoke(cli.main, ["update", "--check", "--ref", "feature"])

    assert result.exit_code == 1
    assert "update available" in result.output
    assert "aaaaaaaaaaaa" in result.output
    assert "bbbbbbbbbbbb" in result.output
    assert "feature" in result.output


def test_default_project_root_is_current_directory(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.chdir(tmp_path)
    captured: list[Path] = []

    def _load(root: Path, **_kwargs: object) -> bootstrap.ProjectBuildSpec:
        captured.append(root)
        return _project()

    async def _build(*_args: object, **_kwargs: object) -> Path:
        return tmp_path / ".build" / "proj"

    monkeypatch.setattr(cli, "_load_project", _load)
    monkeypatch.setattr(cli.bootstrap, "build_binary", _build)
    result = CliRunner().invoke(cli.main, ["build"])
    assert result.exit_code == 0, result.exception
    assert captured == [tmp_path.resolve()]


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
    assert cli._arch_default() is Arch.AMD64


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

    never_ran = process.CommandError(process.CommandUnavailable(("cabal", "build"), "No such file"))
    assert "could not be run" in cli._format_command_error(never_ran)

    assert "`sudo` not found" in cli._format_file_not_found(
        FileNotFoundError(2, "missing", b"/usr/bin/sudo")
    )
    assert cli._format_file_not_found(FileNotFoundError()) is None
    assert cli._format_file_not_found(FileNotFoundError(2, "missing", "unknown-tool")) is None
    assert cli._format_http_error(httpx.ConnectError("offline")) == "network error: offline"
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


def _stub_self_check_passing(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    events: list[str] = []
    authority = cli.MaintainerCommandAuthority(Path.cwd().resolve(), cli._MAINTAINER_TOKEN)

    def _authority() -> cli.MaintainerCommandAuthority:
        events.append("authority")
        return authority

    def _quality(_context: Path, _authority: cli.MaintainerCommandAuthority) -> None:
        events.append("quality-gates")

    monkeypatch.setattr(cli, "_require_maintainer_authority", _authority)
    monkeypatch.setattr(cli, "_run_quality_gates_or_abort", _quality)
    monkeypatch.setattr(cli, "_arch_default", lambda: Arch.AMD64)

    async def _native(_requested: Arch, _host: Arch) -> None:
        events.append("arch-check")

    async def _pull(_tag: str, **_kwargs: object) -> object:
        return process.CommandResult(args=("docker", "pull"), returncode=0, stdout="", stderr="")

    async def _digest(tag: str) -> str:
        repository = tag.split(":", 1)[0]
        return f"{repository}@sha256:{'a' * 64}"

    async def _image_id(_tag: str) -> str:
        return f"sha256:{'b' * 64}"

    monkeypatch.setattr(cli, "_validate_native_architecture", _native)
    monkeypatch.setattr(cli.docker_ops, "pull", _pull)
    monkeypatch.setattr(cli.docker_ops, "image_digest_reference", _digest)
    monkeypatch.setattr(cli.docker_ops, "image_id", _image_id)
    monkeypatch.setattr(
        cli.base_image,
        "compatibility_smoke_spec",
        lambda *_args, **_kwargs: _stub_build_spec()[0],
    )
    # Keep base-build tests hermetic: don't probe real host resources.
    monkeypatch.setattr(cli, "_resolve_build_budget", lambda _targets, *, sequential: None)
    return events


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
        (cli.Flavor.CPU, Arch.ARM64),
        (cli.Flavor.CUDA, Arch.ARM64),
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
    assert captured == [(cli.Flavor.CPU, Arch.ARM64)]
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

    def _probe(
        cmd: tuple[str, ...], *, cwd: Path, stdio: process.Stdio, **_kw: object
    ) -> process.CommandOutcome:
        assert stdio is process.Stdio.INHERIT
        captured.append((list(cmd), cwd))
        return process.CommandResult(tuple(cmd), 0, "", "")

    monkeypatch.setattr(cli.process, "probe", _probe)
    cli._run_quality_gates_or_abort(tmp_path, authority)

    context = tmp_path.resolve()
    expected = [
        ("Python code check", (sys.executable, "-m", "hostbootstrap.check_code"), context),
        ("Python tests", (sys.executable, "-m", "hostbootstrap.test_all"), context),
        (
            "core Haskell build",
            ("cabal", "build", "all", "--ghc-options=-Werror"),
            context / "core",
        ),
        ("core Haskell tests", ("cabal", "test", "all", "--ghc-options=-Werror"), context / "core"),
        (
            "demo Haskell build",
            ("cabal", "build", "all", "--ghc-options=-Werror"),
            context / "demo",
        ),
        ("demo Haskell tests", ("cabal", "test", "all", "--ghc-options=-Werror"), context / "demo"),
    ]
    assert [
        (gate.label, gate.command, gate.cwd) for gate in cli._quality_gates(context)
    ] == expected
    assert captured == [(list(command), cwd) for _label, command, cwd in expected]


def test_style_gates_enumerate_sources_and_skip_the_modules_fourmolu_cannot_read(
    tmp_path: Path,
) -> None:
    src = tmp_path / "core" / "hostbootstrap-core" / "src" / "HostBootstrap"
    src.mkdir(parents=True)
    (src / "Network.hs").write_text("module HostBootstrap.Network where\n", encoding="utf-8")
    # The one module named in the CPP exclusion set, at exactly that path.
    (src / "Registry.hs").write_text("module HostBootstrap.Registry where\n", encoding="utf-8")
    demo = tmp_path / "demo" / "src"
    demo.mkdir(parents=True)
    (demo / "Main.hs").write_text("module Main where\n", encoding="utf-8")

    gates = {gate.label: list(gate.command) for gate in cli._style_gates(tmp_path)}

    assert gates["Haskell formatter over core/hostbootstrap-core/src"] == [
        "fourmolu",
        "--mode",
        "check",
        "core/hostbootstrap-core/src/HostBootstrap/Network.hs",
    ]
    assert gates["Haskell formatter over demo/src"] == [
        "fourmolu",
        "--mode",
        "check",
        "demo/src/Main.hs",
    ]
    assert gates["Haskell linter over core/hostbootstrap-core/src"] == [
        "hlint",
        "core/hostbootstrap-core/src",
    ]
    assert gates["Haskell linter over demo/src"] == ["hlint", "demo/src"]
    # A root with no Haskell under it contributes no formatter gate, and a root
    # that does not exist contributes no linter gate.
    assert "Haskell formatter over demo/app" not in gates
    assert "Haskell linter over demo/app" not in gates


def test_style_gates_run_before_the_cabal_legs(tmp_path: Path) -> None:
    src = tmp_path / "demo" / "src"
    src.mkdir(parents=True)
    (src / "Main.hs").write_text("module Main where\n", encoding="utf-8")

    labels = [gate.label for gate in cli._quality_gates(tmp_path)]

    assert labels.index("Haskell formatter over demo/src") < labels.index("core Haskell build")
    assert labels.index("Haskell linter over demo/src") < labels.index("core Haskell build")


def test_quality_gate_nonzero_raises_before_docker(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    authority = cli.MaintainerCommandAuthority(tmp_path.resolve(), cli._MAINTAINER_TOKEN)
    calls = 0

    def _probe(cmd: tuple[str, ...], **_kw: object) -> process.CommandOutcome:
        nonlocal calls
        calls += 1
        return process.CommandResult(tuple(cmd), 7, "", "")

    monkeypatch.setattr(cli.process, "probe", _probe)
    with pytest.raises(cli.click.ClickException, match="Python code check failed"):
        cli._run_quality_gates_or_abort(tmp_path, authority)
    assert calls == 1


def test_quality_gate_that_cannot_be_launched_raises_before_docker(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    authority = cli.MaintainerCommandAuthority(tmp_path.resolve(), cli._MAINTAINER_TOKEN)
    monkeypatch.setattr(
        cli.process,
        "probe",
        lambda cmd, **_k: process.CommandUnavailable(tuple(cmd), "No such file"),
    )
    with pytest.raises(cli.click.ClickException, match="could not be run"):
        cli._run_quality_gates_or_abort(tmp_path, authority)


def test_quality_gates_reject_non_authorized_repo_root(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    authority = cli.MaintainerCommandAuthority(
        tmp_path.resolve() / "canonical", cli._MAINTAINER_TOKEN
    )

    def _probe(*_a: object, **_kw: object) -> object:
        raise AssertionError("no command runs for another checkout")

    monkeypatch.setattr(cli.process, "probe", _probe)
    with pytest.raises(cli.click.ClickException, match="not the canonical checkout"):
        cli._run_quality_gates_or_abort(tmp_path, authority)


def test_native_architecture_requires_request_host_and_engine_match(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def _arm64() -> Arch:
        return Arch.ARM64

    monkeypatch.setattr(cli.docker_ops, "engine_arch", _arm64)
    asyncio.run(cli._validate_native_architecture(Arch.ARM64, Arch.ARM64))
    with pytest.raises(cli.click.ClickException, match="must be native"):
        asyncio.run(cli._validate_native_architecture(Arch.AMD64, Arch.ARM64))

    async def _amd64() -> Arch:
        return Arch.AMD64

    monkeypatch.setattr(cli.docker_ops, "engine_arch", _amd64)
    with pytest.raises(cli.click.ClickException, match="Docker engine=amd64"):
        asyncio.run(cli._validate_native_architecture(Arch.ARM64, Arch.ARM64))


def test_build_then_publish_smokes_before_and_after_registry_mutation(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    tag = "docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64"
    digest = f"docker.io/tuee22/hostbootstrap@sha256:{'b' * 64}"
    local_image_id = f"sha256:{'a' * 64}"
    base_spec = _stub_build_spec()[0]
    local_smoke_spec = docker_ops.BuildSpec(
        dockerfile=tmp_path / "demo/docker/Dockerfile",
        context=tmp_path,
        tags=("local-compatibility",),
        build_args={"BASE_IMAGE": local_image_id},
    )
    published_smoke_spec = docker_ops.BuildSpec(
        dockerfile=tmp_path / "demo/docker/Dockerfile",
        context=tmp_path,
        tags=("published-compatibility",),
        build_args={"BASE_IMAGE": digest},
    )
    order: list[str] = []

    async def _build(spec: docker_ops.BuildSpec, *, prefix: str = "") -> object:
        _ = prefix
        if spec is base_spec:
            order.append("base-build")
        elif spec is local_smoke_spec:
            order.append("local-derived-build")
        else:
            assert spec is published_smoke_spec
            order.append("published-derived-build")
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

    async def _image_id(value: str) -> str:
        assert value == tag
        order.append("image-id")
        return local_image_id

    def _validation(
        flavor: cli.Flavor,
        arch: Arch,
        *,
        context: Path,
        base_reference: str,
        pull: bool,
    ) -> docker_ops.BuildSpec:
        assert (flavor, arch, context) == (cli.Flavor.CPU, Arch.ARM64, tmp_path)
        if pull:
            assert base_reference == digest
            order.append("published-compatibility-spec")
            return published_smoke_spec
        assert base_reference == local_image_id
        order.append("local-compatibility-spec")
        return local_smoke_spec

    monkeypatch.setattr(cli.docker_ops, "build", _build)
    monkeypatch.setattr(cli.docker_ops, "push", _push)
    monkeypatch.setattr(cli.docker_ops, "pull", _pull)
    monkeypatch.setattr(cli.docker_ops, "image_digest_reference", _digest)
    monkeypatch.setattr(cli.docker_ops, "image_id", _image_id)
    monkeypatch.setattr(cli.base_image, "compatibility_smoke_spec", _validation)

    result = asyncio.run(
        cli._build_then_publish(
            base_spec,
            tag,
            cli.Flavor.CPU,
            Arch.ARM64,
            tmp_path,
        )
    )

    assert result == digest
    assert order == [
        "base-build",
        "image-id",
        "local-compatibility-spec",
        "local-derived-build",
        "push",
        "pull",
        "digest",
        "published-compatibility-spec",
        "published-derived-build",
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


def test_run_threads_explicit_cabal_selection_and_offline(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    project = _project()
    captured: dict[str, object] = {}

    def _load(root: Path, *, selected_cabal_file: Path | None) -> bootstrap.ProjectBuildSpec:
        captured["root"] = root
        captured["selection"] = selected_cabal_file
        return project

    async def _bootstrap(
        spec: bootstrap.ProjectBuildSpec,
        *,
        project_root: Path,
        args: tuple[str, ...],
        offline: bool,
    ) -> None:
        captured.update(spec=spec, build_root=project_root, args=args, offline=offline)

    monkeypatch.setattr(cli, "_load_project", _load)
    monkeypatch.setattr(cli.bootstrap, "bootstrap", _bootstrap)
    result = CliRunner().invoke(
        cli.main,
        [
            "run",
            "--project-root",
            str(tmp_path),
            "--offline",
            "--cabal-file",
            "x.cabal",
            "project",
            "up",
        ],
    )
    assert result.exit_code == 0, result.exception
    assert captured == {
        "root": tmp_path.resolve(),
        "selection": Path("x.cabal"),
        "spec": project,
        "build_root": tmp_path.resolve(),
        "args": ("project", "up"),
        "offline": True,
    }


@pytest.mark.parametrize("command", ["build", "build-and-push"])
def test_base_authority_architecture_and_quality_precede_docker(
    monkeypatch: pytest.MonkeyPatch,
    command: str,
) -> None:
    events = _stub_self_check_passing(monkeypatch)
    _patch_build_spec(monkeypatch)

    async def _build(*_args: object, **_kwargs: object) -> process.CommandResult:
        events.append("build")
        return process.CommandResult(("docker", "build"), 0, "", "")

    async def _push(*_args: object, **_kwargs: object) -> process.CommandResult:
        events.append("push")
        return process.CommandResult(("docker", "push"), 0, "", "")

    monkeypatch.setattr(cli.docker_ops, "build", _build)
    monkeypatch.setattr(cli.docker_ops, "push", _push)
    result = CliRunner().invoke(cli.main, ["base", command, "--flavor", "cpu"])
    assert result.exit_code == 0, result.exception
    expected = ["authority", "arch-check", "quality-gates", "build"]
    if command == "build-and-push":
        expected += ["build", "push", "build"]
    assert events == expected


@pytest.mark.parametrize("command", ["build", "build-and-push"])
@pytest.mark.parametrize("stage", ["authority", "arch-check", "quality-gates"])
def test_base_preflight_failure_makes_no_docker_mutation(
    monkeypatch: pytest.MonkeyPatch,
    command: str,
    stage: str,
) -> None:
    events = _stub_self_check_passing(monkeypatch)

    def _refuse(*_args: object, **_kwargs: object) -> object:
        events.append(stage)
        raise cli.click.ClickException(f"{stage} refused")

    async def _refuse_arch(*_args: object, **_kwargs: object) -> None:
        _refuse()

    def _unexpected(*_args: object, **_kwargs: object) -> object:
        raise AssertionError("Docker must not run after a preflight refusal")

    if stage == "authority":
        monkeypatch.setattr(cli, "_require_maintainer_authority", _refuse)
    elif stage == "arch-check":
        monkeypatch.setattr(cli, "_validate_native_architecture", _refuse_arch)
    else:
        monkeypatch.setattr(cli, "_run_quality_gates_or_abort", _refuse)
    monkeypatch.setattr(cli.docker_ops, "build", _unexpected)
    monkeypatch.setattr(cli.docker_ops, "push", _unexpected)
    result = CliRunner().invoke(cli.main, ["base", command, "--flavor", "cpu"])
    assert result.exit_code != 0
    assert f"{stage} refused" in result.output
    assert (
        events
        == ["authority", "arch-check", "quality-gates"][
            : ["authority", "arch-check", "quality-gates"].index(stage) + 1
        ]
    )


@pytest.mark.parametrize("command", ["build", "build-and-push"])
def test_base_default_context_follows_invocation_directory(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    command: str,
) -> None:
    _stub_self_check_passing(monkeypatch)
    captured: list[Path] = []

    def _spec(
        *_args: object, context: Path, **_kwargs: object
    ) -> tuple[docker_ops.BuildSpec, object]:
        captured.append(context)
        return _stub_build_spec()

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(cli.base_image, "build_spec_for", _spec)
    monkeypatch.setattr(cli.docker_ops, "build", _ok_build)
    monkeypatch.setattr(cli.docker_ops, "push", _ok_build)
    result = CliRunner().invoke(cli.main, ["base", command, "--flavor", "cpu"])
    assert result.exit_code == 0, result.exception
    assert captured == [tmp_path.resolve()]


def test_formatter_argv_is_chunked_under_the_windows_budget(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    source = tmp_path / "core" / "hostbootstrap-core" / "src" / "Long Source Directory"
    source.mkdir(parents=True)
    paths = []
    for index in range(8):
        path = source / f"Source{index}.hs"
        path.write_text("module Source where\n", encoding="utf-8")
        paths.append(path.relative_to(tmp_path).as_posix())
    budget = 180
    monkeypatch.setattr(cli, "_FORMATTER_ARGV_BUDGET", budget)
    gates = [gate for gate in cli._style_gates(tmp_path) if gate.command[0] == "fourmolu"]
    assert len(gates) > 1
    assert [path for gate in gates for path in gate.command[3:]] == sorted(paths)
    assert all(
        process.rendered_windows_commandline_length(gate.command) <= budget for gate in gates
    )
    assert [gate.label for gate in gates] == [
        f"Haskell formatter over core/hostbootstrap-core/src (part {index}/{len(gates)})"
        for index in range(1, len(gates) + 1)
    ]
    monkeypatch.setattr(cli, "_FORMATTER_ARGV_BUDGET", 25)
    with pytest.raises(cli.click.ClickException, match="source exceeds the argument budget"):
        cli._style_gates(tmp_path)


@pytest.mark.parametrize("sequential", [False, True])
def test_concurrent_flavors_interleave_and_sequential_flavors_finish_in_order(
    monkeypatch: pytest.MonkeyPatch,
    sequential: bool,
) -> None:
    _stub_self_check_passing(monkeypatch)
    _patch_build_spec(monkeypatch)
    events: list[str] = []
    monkeypatch.setattr(
        cli.base_image,
        "compatibility_smoke_spec",
        lambda *_a, **_k: replace(_stub_build_spec()[0], tags=("smoke",)),
    )

    async def _build(spec: docker_ops.BuildSpec, *, prefix: str = "") -> process.CommandResult:
        if spec.tags == ("t",):
            label = prefix.strip("[] ")
            events.append(f"{label}-start")
            await asyncio.sleep(0)
            events.append(f"{label}-end")
        return process.CommandResult(("docker", "build"), 0, "", "")

    monkeypatch.setattr(cli.docker_ops, "build", _build)
    monkeypatch.setattr(cli.docker_ops, "push", _ok_build)
    result = CliRunner().invoke(
        cli.main, ["base", "build-and-push", *(["--sequential"] if sequential else [])]
    )
    assert result.exit_code == 0, result.exception
    assert events == (
        ["cpu-start", "cpu-end", "cuda-start", "cuda-end"]
        if sequential
        else ["cpu-start", "cuda-start", "cpu-end", "cuda-end"]
    )


@pytest.mark.parametrize("sequential", [False, True])
def test_failed_flavor_retains_other_publication_unless_sequential(
    monkeypatch: pytest.MonkeyPatch,
    sequential: bool,
) -> None:
    _stub_self_check_passing(monkeypatch)
    _patch_build_spec(monkeypatch)
    started: list[str] = []
    pushed: list[str] = []

    async def _build(_spec: docker_ops.BuildSpec, *, prefix: str = "") -> process.CommandResult:
        label = prefix.strip("[] ")
        started.append(label)
        await asyncio.sleep(0)
        if label == "cpu":
            raise _make_command_error("plain cpu failure")
        return process.CommandResult(("docker", "build"), 0, "", "")

    async def _push(tag: str, **_kwargs: object) -> process.CommandResult:
        pushed.append(tag)
        return process.CommandResult(("docker", "push"), 0, "", "")

    monkeypatch.setattr(cli.docker_ops, "build", _build)
    monkeypatch.setattr(cli.docker_ops, "push", _push)
    result = CliRunner().invoke(
        cli.main, ["base", "build-and-push", *(["--sequential"] if sequential else [])]
    )
    assert result.exit_code != 0
    if sequential:
        assert started == ["cpu"]
        assert pushed == []
        assert "published and validated" not in result.output
    else:
        assert "cuda" in started
        assert pushed == ["docker.io/tuee22/hostbootstrap:basecontainer-cuda-amd64"]
        assert "[cuda] published and validated" in result.output
        assert "[cpu]" in result.output


@pytest.mark.parametrize("unexpected", [False, True])
def test_concurrent_failures_report_every_flavor_or_preserve_programming_error(
    monkeypatch: pytest.MonkeyPatch,
    unexpected: bool,
) -> None:
    _stub_self_check_passing(monkeypatch)
    _patch_build_spec(monkeypatch)
    programming_error = KeyError("x")
    errors = {
        "cpu": _make_command_error("cpu failure"),
        "cuda": programming_error if unexpected else _make_command_error("cuda failure"),
    }

    async def _build(*_args: object, prefix: str = "", **_kwargs: object) -> process.CommandResult:
        await asyncio.sleep(0)
        raise errors[prefix.strip("[] ")]

    monkeypatch.setattr(cli.docker_ops, "build", _build)
    result = CliRunner().invoke(cli.main, ["base", "build-and-push"], standalone_mode=False)
    assert result.exit_code != 0
    if unexpected:
        assert result.exception is programming_error
    else:
        assert isinstance(result.exception, cli.click.ClickException)
        assert "[cpu] `docker push" in str(result.exception)
        assert "[cuda] `docker push" in str(result.exception)


@pytest.mark.parametrize("error", [KeyError("bad-value"), KeyError()])
def test_friendly_group_preserves_key_errors(
    monkeypatch: pytest.MonkeyPatch,
    error: KeyError,
) -> None:
    _stub_self_check_passing(monkeypatch)

    def _raise(*_args: object, **_kwargs: object) -> object:
        raise error

    monkeypatch.setattr(cli.base_image, "build_spec_for", _raise)
    result = CliRunner().invoke(cli.main, ["base", "build", "--flavor", "cpu"])
    assert result.exception is error


def test_missing_docker_launch_has_its_install_hint(monkeypatch: pytest.MonkeyPatch) -> None:
    _stub_self_check_passing(monkeypatch)
    _patch_build_spec(monkeypatch)

    async def _missing(*_args: object, **_kwargs: object) -> process.CommandResult:
        raise process.CommandError(process.CommandUnavailable(("docker", "build"), "missing"))

    monkeypatch.setattr(cli.docker_ops, "build", _missing)
    result = CliRunner().invoke(cli.main, ["base", "build", "--flavor", "cpu"])
    assert result.exit_code != 0
    assert cli._MISSING_BINARY_HINTS["docker"] in result.output
    assert "Traceback" not in result.output
    assert "could not be run" in cli._format_command_error(
        process.CommandError(process.CommandUnavailable((), "missing"))
    )


@pytest.mark.parametrize(
    "condition",
    [
        None,
        "name",
        "git",
        "lock",
        "prefix",
        "base-prefix",
        "executable",
        "ruff",
        "black",
        "mypy",
        "pytest",
        "toml",
    ],
)
def test_maintainer_authority_requires_each_repository_condition(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    condition: str | None,
) -> None:
    package = tmp_path / "hostbootstrap"
    package.mkdir()
    executable = tmp_path / ".venv" / "bin" / "python"
    executable.parent.mkdir(parents=True)
    executable.touch()
    metadata = f'[tool.poetry]\nname = "{"other" if condition == "name" else "hostbootstrap"}"\n'
    (tmp_path / "pyproject.toml").write_text(metadata, encoding="utf-8")
    if condition != "git":
        (tmp_path / ".git").mkdir()
    if condition != "lock":
        (tmp_path / "poetry.lock").touch()
    prefix = tmp_path / ("other-env" if condition == "prefix" else ".venv")
    monkeypatch.setattr(cli, "__file__", str(package / "cli.py"))
    monkeypatch.setattr(cli.sys, "prefix", str(prefix))
    monkeypatch.setattr(
        cli.sys, "base_prefix", str(prefix if condition == "base-prefix" else tmp_path / "system")
    )
    monkeypatch.setattr(
        cli.sys,
        "executable",
        str(tmp_path / "external-python" if condition == "executable" else executable),
    )
    monkeypatch.setattr(
        cli.importlib.util, "find_spec", lambda name: None if name == condition else object()
    )
    if condition == "toml":

        def _bad_toml(_text: str) -> object:
            raise tomllib.TOMLDecodeError("invalid metadata", "", 0)

        monkeypatch.setattr(cli.tomllib, "loads", _bad_toml)
    authority = cli._maintainer_command_authority()
    if condition is None:
        assert isinstance(authority, cli.MaintainerCommandAuthority)
        assert authority.repository_root == tmp_path.resolve()
    else:
        assert authority is None


def test_help_renders_under_cp1252(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(cli, "_maintainer_cli_enabled", lambda: True)
    runner = CliRunner(charset="cp1252")
    for args in (
        ["--help"],
        ["base", "--help"],
        ["base", "build", "--help"],
        ["base", "build-and-push", "--help"],
    ):
        result = runner.invoke(cli.main, args)
        assert result.exit_code == 0, result.exception
        assert result.exception is None
        if args == ["--help"]:
            assert "check-code" in result.output
            assert "test-all" in result.output


def test_help_text_is_cp1252_encodable(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(cli, "_maintainer_cli_enabled", lambda: True)

    def _visit(command: cli.click.Command) -> None:
        for text in [
            command.help,
            command.short_help,
            *(getattr(param, "help", None) for param in command.params),
        ]:
            if text:
                assert text.isascii(), text
                text.encode("cp1252")
        if isinstance(command, cli.click.Group):
            with cli.click.Context(command) as context:
                for name in command.list_commands(context):
                    child = command.get_command(context, name)
                    assert child is not None
                    _visit(child)

    _visit(cli.main)
