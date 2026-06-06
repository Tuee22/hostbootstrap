"""Unit tests for the execution models: pure helpers + recorded runners."""

from __future__ import annotations

from pathlib import Path

import pytest

from hostbootstrap.base_image import Flavor
from hostbootstrap.spec import (
    ContainerArtifact,
    ContainerModel,
    HostBinaryModel,
    HostDaemonModel,
    Mount,
    ProjectSpec,
    TargetSpec,
    Lifecycle,
)
from hostbootstrap.models import container, host_binary, host_daemon
from hostbootstrap.substrate import Substrate, SubstrateName


def _spec(model: object, lifecycle: Lifecycle = Lifecycle.CLUSTER) -> ProjectSpec:
    return ProjectSpec(
        project="proj",
        targets={SubstrateName.LINUX_CPU: TargetSpec(lifecycle, model)},  # type: ignore[arg-type]
        source_path=Path("/proj/hostbootstrap.dhall"),
    )


LINUX = Substrate(SubstrateName.LINUX_CPU, "amd64")
LINUX_GPU = Substrate(SubstrateName.LINUX_GPU, "amd64")
APPLE = Substrate(SubstrateName.APPLE_SILICON, "arm64")


def test_resolve_host_path(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HOME", "/home/me")
    assert container.resolve_host_path("${HOME}/.docker/config.json", Path("/proj")) == (
        "/home/me/.docker/config.json"
    )
    assert (
        container.resolve_host_path("/var/run/docker.sock", Path("/proj")) == "/var/run/docker.sock"
    )
    assert container.resolve_host_path("./.data", Path("/proj")) == "/proj/.data"


def test_image_tag() -> None:
    assert container.image_tag(_spec(None), LINUX) == "proj:linux-cpu-amd64"


def test_container_entrypoint_validation() -> None:
    container.validate_entrypoint_for_args(
        project="proj",
        tag="proj:linux-cpu-amd64",
        entrypoint=("/usr/bin/tini", "--", "/usr/local/bin/proj"),
        args=("status",),
    )

    with pytest.raises(RuntimeError, match="has no ENTRYPOINT"):
        container.validate_entrypoint_for_args(
            project="proj",
            tag="proj:linux-cpu-amd64",
            entrypoint=(),
            args=("status",),
        )
    with pytest.raises(RuntimeError, match="tini-wrapped project ENTRYPOINT"):
        container.validate_entrypoint_for_args(
            project="proj",
            tag="proj:linux-cpu-amd64",
            entrypoint=("/usr/local/bin/proj",),
            args=("status",),
        )
    with pytest.raises(RuntimeError, match="tini-wrapped project ENTRYPOINT"):
        container.validate_entrypoint_for_args(
            project="proj",
            tag="proj:linux-cpu-amd64",
            entrypoint=("/usr/bin/tini", "--", "/usr/local/bin/other"),
            args=("status",),
        )
    with pytest.raises(RuntimeError, match="hostbootstrap run proj status"):
        container.validate_entrypoint_for_args(
            project="proj",
            tag="proj:linux-cpu-amd64",
            entrypoint=("/usr/bin/tini", "--", "/usr/local/bin/proj"),
            args=("proj", "status"),
        )


def test_resolve_command_absolutizes_build_token() -> None:
    assert host_binary.resolve_command(".build/x serve --port 8080", Path("/proj")) == (
        "/proj/.build/x",
        "serve",
        "--port",
        "8080",
    )
    assert host_binary.resolve_command("/usr/bin/x a", Path("/proj")) == ("/usr/bin/x", "a")
    assert host_binary.resolve_command("plaincmd a", Path("/proj")) == ("plaincmd", "a")


def test_daemon_command() -> None:
    model = HostDaemonModel(daemon="service --role worker")
    assert host_daemon.daemon_command(model, project_root=Path("/proj")) == (
        "service",
        "--role",
        "worker",
    )


async def test_container_build_injects_base_image(
    recorded_commands: list[tuple[str, ...]], project_root: Path
) -> None:
    model = ContainerModel(dockerfile=Path("docker/x.Dockerfile"), mounts=())
    tag = await container.build(
        _spec(model), model, LINUX, flavor=Flavor.CPU, project_root=project_root
    )
    assert tag == "proj:linux-cpu-amd64"
    (build_cmd,) = recorded_commands
    assert "BASE_IMAGE=docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64" in build_cmd
    assert "proj:linux-cpu-amd64" in build_cmd


async def test_linux_gpu_container_build_uses_cuda_base(
    recorded_commands: list[tuple[str, ...]], project_root: Path
) -> None:
    model = ContainerModel(dockerfile=Path("docker/x.Dockerfile"), mounts=())
    tag = await container.build(
        _spec(model), model, LINUX_GPU, flavor=Flavor.CUDA, project_root=project_root
    )
    assert tag == "proj:linux-gpu-amd64"
    (build_cmd,) = recorded_commands
    assert "BASE_IMAGE=docker.io/tuee22/hostbootstrap:basecontainer-cuda-amd64" in build_cmd
    assert "proj:linux-gpu-amd64" in build_cmd


async def test_container_run_one_shot(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    project_root: Path,
) -> None:
    async def _entrypoint(_tag: str) -> tuple[str, ...]:
        return ("/usr/bin/tini", "--", "/usr/local/bin/proj")

    monkeypatch.setattr(container.docker_ops, "image_entrypoint", _entrypoint)
    model = ContainerModel(dockerfile=Path("d"), mounts=())
    await container.run_one_shot(
        _spec(model), model, LINUX, ("echo", "hi"), flavor=Flavor.CPU, project_root=project_root
    )
    run = next(" ".join(c) for c in recorded_commands if "docker run" in " ".join(c))
    assert "--rm" in run and "--restart" not in run and run.endswith("echo hi")


async def test_container_run_cluster_command_uses_project_entrypoint(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    project_root: Path,
) -> None:
    async def _entrypoint(_tag: str) -> tuple[str, ...]:
        return ("/usr/bin/tini", "--", "/usr/local/bin/proj")

    monkeypatch.setattr(container.docker_ops, "image_entrypoint", _entrypoint)
    model = ContainerModel(
        dockerfile=Path("docker/x.Dockerfile"),
        mounts=(Mount("./.data", "/opt/proj/.data", False),),
    )
    await container.run_cluster_command(
        _spec(model),
        model,
        LINUX,
        ("cluster", "up"),
        flavor=Flavor.CPU,
        project_root=project_root,
        env={"HOSTBOOTSTRAP_TARGET": "linux-cpu"},
    )
    run = next(" ".join(c) for c in recorded_commands if "docker run" in " ".join(c))
    assert "--rm" in run
    assert "--restart" not in run
    assert "-e HOSTBOOTSTRAP_TARGET=linux-cpu" in run
    assert f"{project_root}/.data:/opt/proj/.data" in run
    assert run.endswith("cluster up")


async def test_host_binary_apple_builds_on_host(
    recorded_commands: list[tuple[str, ...]], project_root: Path
) -> None:
    path = await host_binary.build_binary(
        _spec(None), APPLE, flavor=Flavor.CPU, project_root=project_root
    )
    assert path == project_root / ".build" / "proj"
    (cabal_cmd,) = recorded_commands
    assert cabal_cmd[:2] == ("cabal", "install")
    assert "exe:proj" in cabal_cmd


async def test_host_binary_linux_builds_in_container(
    recorded_commands: list[tuple[str, ...]], project_root: Path
) -> None:
    await host_binary.build_binary(_spec(None), LINUX, flavor=Flavor.CPU, project_root=project_root)
    (run,) = recorded_commands
    flat = " ".join(run)
    assert "docker run" in flat
    assert "basecontainer-cpu-amd64" in flat
    assert "cabal install --installdir .build" in flat
    assert "exe:proj" in flat
    assert f"{project_root}:/src" in flat


async def test_host_binary_builds_optional_container_with_target_substrate(
    recorded_commands: list[tuple[str, ...]], project_root: Path
) -> None:
    model = HostBinaryModel(container=ContainerArtifact(Path("docker/artifact.Dockerfile")))
    await host_binary.build(
        _spec(model),
        model,
        LINUX,
        flavor=Flavor.CUDA,
        project_root=project_root,
        tag_substrate=Substrate(SubstrateName.LINUX_GPU, "amd64"),
    )
    flat = [" ".join(c) for c in recorded_commands]
    assert any("proj:linux-gpu-amd64" in c for c in flat)
    assert any("basecontainer-cuda-amd64" in c for c in flat)


async def test_host_binary_run_one_shot(
    recorded_commands: list[tuple[str, ...]], project_root: Path
) -> None:
    model = HostBinaryModel()
    await host_binary.run_one_shot(
        _spec(model), model, LINUX, ("cluster", "up"), flavor=Flavor.CPU, project_root=project_root
    )
    assert recorded_commands[-1] == (str(project_root / ".build" / "proj"), "cluster", "up")


async def test_host_daemon_run_daemon_foreground(
    recorded_commands: list[tuple[str, ...]], project_root: Path
) -> None:
    model = HostDaemonModel(daemon="service --role worker")
    spec = _spec(model)
    await host_daemon.run_daemon(
        spec,
        model,
        LINUX,
        flavor=Flavor.CPU,
        project_root=project_root,
        env={"HOSTBOOTSTRAP_MODEL": "host-daemon"},
    )
    assert recorded_commands[-1] == (
        str(project_root / ".build" / "proj"),
        "service",
        "--role",
        "worker",
    )
