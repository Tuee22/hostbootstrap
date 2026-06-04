"""Unit tests for the execution models: pure helpers + recorded runners."""

from __future__ import annotations

from pathlib import Path

import pytest

from hostbootstrap.models import container, host_binary, host_daemon
from hostbootstrap.spec import (
    BuildSpec,
    ContainerArtifact,
    ContainerModel,
    Flavor,
    Handoff,
    HostBinaryModel,
    HostDaemonModel,
    HostReqs,
    Mount,
    ProjectSpec,
)
from hostbootstrap.substrate import Substrate, SubstrateName


def _spec(model: object) -> ProjectSpec:
    return ProjectSpec(
        project="proj",
        substrates={SubstrateName.LINUX_CPU: model},  # type: ignore[dict-item]
        source_path=Path("/proj/hostbootstrap.dhall"),
    )


LINUX = Substrate(SubstrateName.LINUX_CPU, "amd64")
APPLE = Substrate(SubstrateName.APPLE_SILICON, "arm64")


# --- pure helpers ---------------------------------------------------------


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
    container.validate_entrypoint_for_args(
        project="proj",
        tag="proj:linux-cpu-amd64",
        entrypoint=("/usr/local/bin/proj",),
        args=(),
    )
    container.validate_entrypoint_for_args(
        project="proj",
        tag="proj:linux-cpu-amd64",
        entrypoint=("tini", "-g"),
        args=("status",),
    )
    container.validate_entrypoint_for_args(
        project="proj",
        tag="proj:linux-cpu-amd64",
        entrypoint=("tini", "--"),
        args=("status",),
    )

    with pytest.raises(RuntimeError, match="has no ENTRYPOINT"):
        container.validate_entrypoint_for_args(
            project="proj",
            tag="proj:linux-cpu-amd64",
            entrypoint=(),
            args=("status",),
        )
    with pytest.raises(RuntimeError, match="instead of `hostbootstrap run proj status`"):
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
    model = HostDaemonModel(build=BuildSpec("c", HostReqs()), daemon=".build/proj serve")
    assert host_daemon.daemon_command(model, project_root=Path("/proj")) == (
        "/proj/.build/proj",
        "serve",
    )


# --- recorded runners -----------------------------------------------------


async def test_container_build_injects_base_image(
    recorded_commands: list[tuple[str, ...]], project_root: Path
) -> None:
    model = ContainerModel(
        dockerfile=Path("docker/x.Dockerfile"), flavor=Flavor.CPU, service=False, mounts=()
    )
    tag = await container.build(_spec(model), model, LINUX, project_root=project_root)
    assert tag == "proj:linux-cpu-amd64"
    (build_cmd,) = recorded_commands
    assert "BASE_IMAGE=docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64" in build_cmd
    assert "proj:linux-cpu-amd64" in build_cmd


async def test_container_build_base_uses_local_base_without_pull(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    project_root: Path,
) -> None:
    def fake_build_spec_for(
        flavor: object,
        arch: str,
        *,
        context: Path,
        pull: bool,
        **_: object,
    ) -> tuple[object, object]:
        return (
            container.docker_ops.BuildSpec(
                dockerfile=context / "docker/basecontainer.Dockerfile",
                context=context,
                tags=(f"base-{arch}",),
                build_args={"BASE_IMAGE": "ubuntu:24.04"},
                pull=pull,
            ),
            object(),
        )

    monkeypatch.setattr(container.base_image, "build_spec_for", fake_build_spec_for)
    model = ContainerModel(
        dockerfile=Path("docker/x.Dockerfile"), flavor=Flavor.CPU, service=False, mounts=()
    )
    await container.build(
        _spec(model),
        model,
        LINUX,
        project_root=project_root,
        build_base=True,
        base_context=Path("/hostbootstrap"),
    )

    assert len(recorded_commands) == 2
    base_build, project_build = recorded_commands
    assert "--pull" not in base_build
    assert "--pull" not in project_build
    assert "/hostbootstrap/docker/basecontainer.Dockerfile" in base_build
    assert "BASE_IMAGE=docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64" in project_build


async def test_container_build_base_requires_context(project_root: Path) -> None:
    model = ContainerModel(
        dockerfile=Path("docker/x.Dockerfile"), flavor=Flavor.CPU, service=False, mounts=()
    )

    with pytest.raises(RuntimeError, match="--base-context"):
        await container.build(
            _spec(model), model, LINUX, project_root=project_root, build_base=True
        )


async def test_container_build_artifact_with_local_base(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    project_root: Path,
) -> None:
    def fake_build_spec_for(
        flavor: object,
        arch: str,
        *,
        context: Path,
        pull: bool,
        **_: object,
    ) -> tuple[object, object]:
        return (
            container.docker_ops.BuildSpec(
                dockerfile=context / "docker/basecontainer.Dockerfile",
                context=context,
                tags=(f"base-{arch}",),
                build_args={},
                pull=pull,
            ),
            object(),
        )

    monkeypatch.setattr(container.base_image, "build_spec_for", fake_build_spec_for)
    artifact = ContainerArtifact(dockerfile=Path("docker/artifact.Dockerfile"), flavor=Flavor.CUDA)

    tag = await container.build_artifact(
        _spec(None),
        artifact,
        LINUX,
        project_root=project_root,
        build_base=True,
        base_context=Path("/hostbootstrap"),
    )

    assert tag == "proj:linux-cpu-amd64"
    assert len(recorded_commands) == 2
    assert "base-amd64" in recorded_commands[0]
    assert "basecontainer-cuda-amd64" in " ".join(recorded_commands[1])


async def test_container_build_artifact_base_requires_context(project_root: Path) -> None:
    artifact = ContainerArtifact(dockerfile=Path("docker/artifact.Dockerfile"), flavor=Flavor.CPU)

    with pytest.raises(RuntimeError, match="--base-context"):
        await container.build_artifact(
            _spec(None),
            artifact,
            LINUX,
            project_root=project_root,
            build_base=True,
        )


async def test_container_start_service(
    recorded_commands: list[tuple[str, ...]], project_root: Path
) -> None:
    model = ContainerModel(
        dockerfile=Path("docker/x.Dockerfile"),
        flavor=Flavor.CPU,
        service=True,
        mounts=(Mount("./.data", "/opt/proj/.data", False),),
    )
    await container.start_service(_spec(model), model, LINUX, project_root=project_root)
    flat = [" ".join(c) for c in recorded_commands]
    assert any(c.startswith("docker build") for c in flat)
    assert any("docker rm -f proj" in c for c in flat)
    run = next(c for c in flat if "docker run" in c)
    assert "-d" in run.split() and "--restart unless-stopped" in run and "--name proj" in run
    assert f"{project_root}/.data:/opt/proj/.data" in run


async def test_container_stop_service(
    recorded_commands: list[tuple[str, ...]],
) -> None:
    result = await container.stop_service(_spec(None))

    assert result.ok
    assert recorded_commands == [("docker", "rm", "-f", "proj")]


async def test_container_run_one_shot(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    project_root: Path,
) -> None:
    async def _entrypoint(_tag: str) -> tuple[str, ...]:
        return ("/usr/bin/tini", "--", "/usr/local/bin/proj")

    monkeypatch.setattr(container.docker_ops, "image_entrypoint", _entrypoint)
    model = ContainerModel(dockerfile=Path("d"), flavor=Flavor.CPU, service=False, mounts=())
    await container.run_one_shot(
        _spec(model), model, LINUX, ("echo", "hi"), project_root=project_root
    )
    run = next(" ".join(c) for c in recorded_commands if "docker run" in " ".join(c))
    assert "--rm" in run and run.endswith("echo hi")


async def test_container_run_one_shot_rejects_missing_entrypoint(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    project_root: Path,
) -> None:
    async def _entrypoint(_tag: str) -> tuple[str, ...]:
        return ()

    monkeypatch.setattr(container.docker_ops, "image_entrypoint", _entrypoint)
    model = ContainerModel(dockerfile=Path("d"), flavor=Flavor.CPU, service=False, mounts=())
    with pytest.raises(RuntimeError, match="has no ENTRYPOINT"):
        await container.run_one_shot(
            _spec(model), model, LINUX, ("status",), project_root=project_root
        )

    assert any(command[:2] == ("docker", "build") for command in recorded_commands)
    assert not any(command[:2] == ("docker", "run") for command in recorded_commands)


async def test_host_binary_apple_builds_on_host(
    recorded_commands: list[tuple[str, ...]], project_root: Path
) -> None:
    build = BuildSpec("cabal install --installdir .build exe:proj", HostReqs(ghc=True))
    path = await host_binary.build_binary(_spec(None), build, APPLE, project_root=project_root)
    assert path == project_root / ".build" / "proj"
    (cabal_cmd,) = recorded_commands
    assert cabal_cmd[:2] == ("cabal", "install")


async def test_host_binary_linux_builds_in_container(
    recorded_commands: list[tuple[str, ...]], project_root: Path
) -> None:
    build = BuildSpec("cabal install --installdir .build exe:proj", HostReqs())
    await host_binary.build_binary(_spec(None), build, LINUX, project_root=project_root)
    (run,) = recorded_commands
    flat = " ".join(run)
    assert "docker run" in flat
    assert "basecontainer-cpu-amd64" in flat  # builds in the base image
    assert "sh -c" in flat
    assert f"{project_root}:/src" in flat


async def test_host_binary_linux_build_base_requires_context(project_root: Path) -> None:
    build = BuildSpec("cabal install --installdir .build exe:proj", HostReqs())

    with pytest.raises(RuntimeError, match="--base-context"):
        await host_binary.build_binary(
            _spec(None),
            build,
            LINUX,
            project_root=project_root,
            build_base=True,
        )


async def test_host_binary_linux_build_base_uses_local_base(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    project_root: Path,
) -> None:
    def fake_build_spec_for(
        flavor: object,
        arch: str,
        *,
        context: Path,
        pull: bool,
        **_: object,
    ) -> tuple[object, object]:
        return (
            host_binary.docker_ops.BuildSpec(
                dockerfile=context / "docker/basecontainer.Dockerfile",
                context=context,
                tags=(f"base-{arch}",),
                build_args={},
                pull=pull,
            ),
            object(),
        )

    monkeypatch.setattr(host_binary.base_image, "build_spec_for", fake_build_spec_for)
    build = BuildSpec("cabal install --installdir .build exe:proj", HostReqs())

    await host_binary.build_binary(
        _spec(None),
        build,
        LINUX,
        project_root=project_root,
        build_base=True,
        base_context=Path("/hostbootstrap"),
    )

    assert len(recorded_commands) == 2
    assert "base-amd64" in recorded_commands[0]
    assert "docker run" in " ".join(recorded_commands[1])


async def test_host_binary_build_optional_container(
    recorded_commands: list[tuple[str, ...]],
    project_root: Path,
) -> None:
    model = HostBinaryModel(
        build=BuildSpec("cabal install --installdir .build exe:proj", HostReqs()),
        handoff=Handoff(up=".build/proj up", down=".build/proj down"),
        container=ContainerArtifact(
            dockerfile=Path("docker/artifact.Dockerfile"), flavor=Flavor.CPU
        ),
    )

    path = await host_binary.build(_spec(model), model, LINUX, project_root=project_root)

    assert path == project_root / ".build" / "proj"
    flat = [" ".join(command) for command in recorded_commands]
    assert sum("docker build" in command for command in flat) == 1
    assert sum("docker run" in command for command in flat) == 1


async def test_host_binary_run_one_shot(
    recorded_commands: list[tuple[str, ...]],
    project_root: Path,
) -> None:
    model = HostBinaryModel(
        build=BuildSpec("cabal install --installdir .build exe:proj", HostReqs()),
        handoff=Handoff(up=".build/proj up", down=".build/proj down"),
    )

    await host_binary.run_one_shot(
        _spec(model),
        model,
        APPLE,
        ("status",),
        project_root=project_root,
    )

    assert recorded_commands[-1] == (str(project_root / ".build" / "proj"), "status")


async def test_host_daemon_build_optional_container_and_run_one_shot(
    recorded_commands: list[tuple[str, ...]],
    project_root: Path,
) -> None:
    model = HostDaemonModel(
        build=BuildSpec("cabal install --installdir .build exe:proj", HostReqs()),
        daemon=".build/proj serve",
        container=ContainerArtifact(
            dockerfile=Path("docker/artifact.Dockerfile"), flavor=Flavor.CPU
        ),
    )

    path = await host_daemon.build(_spec(model), model, LINUX, project_root=project_root)
    await host_daemon.run_one_shot(
        _spec(model), model, APPLE, ("status",), project_root=project_root
    )

    assert path == project_root / ".build" / "proj"
    flat = [" ".join(command) for command in recorded_commands]
    assert any("docker build" in command for command in flat)
    assert recorded_commands[-1] == (str(project_root / ".build" / "proj"), "status")
