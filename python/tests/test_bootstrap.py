"""Unit tests for the thin five-step bootstrapper."""

from __future__ import annotations

from pathlib import Path

import pytest

from hostbootstrap import bootstrap, docker_ops
from hostbootstrap.base_image import Flavor
from hostbootstrap.spec import Resources, SkeletalSpec
from hostbootstrap.substrate import Substrate, SubstrateName

APPLE = Substrate(SubstrateName.APPLE_SILICON, "arm64")
LINUX_CPU = Substrate(SubstrateName.LINUX_CPU, "amd64")
LINUX_GPU = Substrate(SubstrateName.LINUX_GPU, "amd64")


def _spec(project_root: Path) -> SkeletalSpec:
    return SkeletalSpec(
        project="demo",
        dockerfile=Path("docker/demo.Dockerfile"),
        resources=Resources(cpu=4, memory="8GiB", storage="20GiB"),
        source_path=project_root / "hostbootstrap.dhall",
    )


# ---------------------------------------------------------------------------
# Pure command-builders (exact argv)
# ---------------------------------------------------------------------------


def test_image_tag() -> None:
    spec = _spec(Path("/proj"))
    assert bootstrap.image_tag(spec, LINUX_CPU) == "demo:linux-cpu-amd64"
    assert bootstrap.image_tag(spec, APPLE) == "demo:apple-silicon-arm64"


def test_container_build_spec_targets_base_arg() -> None:
    spec = _spec(Path("/proj"))
    build_spec = bootstrap.container_build_spec(
        spec,
        LINUX_GPU,
        project_root=Path("/proj"),
        flavor=Flavor.CUDA,
        pull=False,
    )
    assert build_spec.dockerfile == Path("/proj/docker/demo.Dockerfile")
    assert build_spec.context == Path("/proj")
    assert build_spec.tags == ("demo:linux-gpu-amd64",)
    assert build_spec.build_args == {
        "BASE_IMAGE": "docker.io/tuee22/hostbootstrap:basecontainer-cuda-amd64"
    }
    assert build_spec.pull is False


def test_colima_start_command_sizes_to_budget() -> None:
    spec = _spec(Path("/proj"))
    assert bootstrap.colima_start_command(spec) == (
        "colima",
        "start",
        "--profile",
        "demo",
        "--cpu",
        "4",
        "--memory",
        "8",
        "--disk",
        "20",
    )


@pytest.mark.parametrize(
    ("memory", "expected"),
    [
        ("8GiB", "8"),
        ("16GB", "16"),
        ("32G", "32"),
        (" 12 gib ", "12"),
        ("64", "64"),
    ],
)
def test_gib_strips_known_suffixes(memory: str, expected: str) -> None:
    spec = SkeletalSpec(
        project="demo",
        dockerfile=Path("d"),
        resources=Resources(cpu=2, memory=memory, storage="20GiB"),
        source_path=Path("hostbootstrap.dhall"),
    )
    cmd = bootstrap.colima_start_command(spec)
    assert cmd[cmd.index("--memory") + 1] == expected


def test_copy_out_commands() -> None:
    spec = _spec(Path("/proj"))
    assert bootstrap.copy_out_create_command(spec, LINUX_CPU) == (
        "docker",
        "create",
        "--name",
        "demo-copyout",
        "demo:linux-cpu-amd64",
    )
    assert bootstrap.copy_out_cp_command(spec, project_root=Path("/proj")) == (
        "docker",
        "cp",
        "demo-copyout:/out/demo",
        "/proj/.build/demo",
    )
    assert bootstrap.copy_out_rm_command(spec) == ("docker", "rm", "demo-copyout")


def test_native_build_command() -> None:
    spec = _spec(Path("/proj"))
    assert bootstrap.native_build_command(spec) == (
        "cabal",
        "install",
        "exe:demo",
        "--installdir",
        ".build",
        "--install-method=copy",
        "--overwrite-policy=always",
    )


def test_ensure_ghc_command() -> None:
    assert bootstrap.ensure_ghc_command() == ("brew", "install", "ghcup")


def test_binary_path_and_exec_argv() -> None:
    spec = _spec(Path("/proj"))
    assert bootstrap.binary_path(spec, Path("/proj")) == Path("/proj/.build/demo")
    assert bootstrap.exec_argv(spec, Path("/proj"), ("play", "--seed", "7")) == (
        "/proj/.build/demo",
        "play",
        "--seed",
        "7",
    )


def test_flavor_for_maps_gpu_to_cuda() -> None:
    assert bootstrap._flavor_for(LINUX_GPU) is Flavor.CUDA
    assert bootstrap._flavor_for(LINUX_CPU) is Flavor.CPU
    assert bootstrap._flavor_for(APPLE) is Flavor.CPU


# ---------------------------------------------------------------------------
# Driver: recorded commands + mocked seams
# ---------------------------------------------------------------------------


def _patch_seams(
    monkeypatch: pytest.MonkeyPatch,
    sub: Substrate,
    *,
    builds: list[docker_ops.BuildSpec],
    doctored: list[Substrate],
    execed: list[list[str]],
) -> None:
    monkeypatch.setattr(bootstrap.substrate, "detect", lambda: sub)

    async def _fake_doctor(detected: Substrate) -> object:
        doctored.append(detected)
        return None

    async def _fake_build(build_spec: docker_ops.BuildSpec) -> object:
        builds.append(build_spec)
        return None

    def _fake_execv(path: str, argv: list[str]) -> None:
        execed.append([path, *argv[1:]])

    monkeypatch.setattr(bootstrap.prereqs, "run_doctor", _fake_doctor)
    monkeypatch.setattr(bootstrap.docker_ops, "build", _fake_build)
    monkeypatch.setattr(bootstrap.os, "execv", _fake_execv)


async def test_bootstrap_linux_copies_binary_out(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    tmp_path: Path,
) -> None:
    builds: list[docker_ops.BuildSpec] = []
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, LINUX_CPU, builds=builds, doctored=doctored, execed=execed)

    spec = _spec(tmp_path)
    await bootstrap.bootstrap(spec, project_root=tmp_path, args=("play",))

    assert doctored == [LINUX_CPU]
    assert len(builds) == 1
    assert builds[0].tags == ("demo:linux-cpu-amd64",)
    # No Colima on Linux; docker create/cp/rm to copy the binary out.
    assert recorded_commands == [
        ("docker", "create", "--name", "demo-copyout", "demo:linux-cpu-amd64"),
        ("docker", "cp", "demo-copyout:/out/demo", str(tmp_path / ".build/demo")),
        ("docker", "rm", "demo-copyout"),
    ]
    assert (tmp_path / ".build").is_dir()
    assert execed == [[str(tmp_path / ".build/demo"), "play"]]


async def test_bootstrap_linux_gpu_uses_cuda_flavor(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    tmp_path: Path,
) -> None:
    builds: list[docker_ops.BuildSpec] = []
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, LINUX_GPU, builds=builds, doctored=doctored, execed=execed)

    await bootstrap.bootstrap(_spec(tmp_path), project_root=tmp_path)

    assert builds[0].build_args == {
        "BASE_IMAGE": "docker.io/tuee22/hostbootstrap:basecontainer-cuda-amd64"
    }
    assert execed == [[str(tmp_path / ".build/demo")]]


async def test_bootstrap_apple_builds_native_and_ensures_ghc(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    tmp_path: Path,
) -> None:
    builds: list[docker_ops.BuildSpec] = []
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, APPLE, builds=builds, doctored=doctored, execed=execed)

    await bootstrap.bootstrap(_spec(tmp_path), project_root=tmp_path, args=("--help",))

    assert doctored == [APPLE]
    assert len(builds) == 1
    assert builds[0].tags == ("demo:apple-silicon-arm64",)
    # Colima provisioned first, then ensure GHC, then native cabal install.
    assert recorded_commands == [
        (
            "colima",
            "start",
            "--profile",
            "demo",
            "--cpu",
            "4",
            "--memory",
            "8",
            "--disk",
            "20",
        ),
        ("brew", "install", "ghcup"),
        (
            "cabal",
            "install",
            "exe:demo",
            "--installdir",
            ".build",
            "--install-method=copy",
            "--overwrite-policy=always",
        ),
    ]
    assert (tmp_path / ".build").is_dir()
    assert execed == [[str(tmp_path / ".build/demo"), "--help"]]


async def test_copy_binary_out_removes_container_on_cp_failure(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    spec = _spec(tmp_path)
    calls: list[tuple[str, ...]] = []

    async def _fake(cmd: object, **_: object) -> object:
        argv = tuple(str(part) for part in cmd)  # type: ignore[union-attr]
        calls.append(argv)
        if argv[:2] == ("docker", "cp"):
            raise RuntimeError("cp failed")
        return None

    monkeypatch.setattr(bootstrap.process, "run_checked", _fake)

    with pytest.raises(RuntimeError, match="cp failed"):
        await bootstrap._copy_binary_out(spec, LINUX_CPU, project_root=tmp_path)

    # The rm runs even though cp raised (finally clause).
    assert calls[0][:2] == ("docker", "create")
    assert calls[-1] == ("docker", "rm", "demo-copyout")
