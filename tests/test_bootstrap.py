"""Unit tests for the thin pre-binary bootstrapper (§§ M, N)."""

from __future__ import annotations

from pathlib import Path

import pytest

from hostbootstrap import bootstrap
from hostbootstrap.spec import Resources, StaticBaseSpec
from hostbootstrap.substrate import Substrate, SubstrateName

APPLE = Substrate(SubstrateName.APPLE_SILICON, "arm64")
LINUX_CPU = Substrate(SubstrateName.LINUX_CPU, "amd64")
LINUX_GPU = Substrate(SubstrateName.LINUX_GPU, "amd64")


def _spec(project_root: Path) -> StaticBaseSpec:
    return StaticBaseSpec(
        project="demo",
        dockerfile=Path("docker/demo.Dockerfile"),
        resources=Resources(cpu=4, memory="8GiB", storage="20GiB"),
        source_path=project_root / "hostbootstrap.dhall",
    )


# ---------------------------------------------------------------------------
# Pure command-builders (exact argv)
# ---------------------------------------------------------------------------


def test_toolchain_ensure_commands_apple() -> None:
    # Apple silicon: Homebrew installs ghcup, then ghcup installs GHC and Cabal.
    assert bootstrap.toolchain_ensure_commands(APPLE) == (
        ("brew", "install", "ghcup"),
        ("ghcup", "install", "ghc", "9.12.4", "--set"),
        ("ghcup", "install", "cabal", "--set"),
    )


@pytest.mark.parametrize("sub", [LINUX_CPU, LINUX_GPU])
def test_toolchain_ensure_commands_linux(sub: Substrate) -> None:
    # Linux: ghcup installs GHC and Cabal; no Homebrew step.
    assert bootstrap.toolchain_ensure_commands(sub) == (
        ("ghcup", "install", "ghc", "9.12.4", "--set"),
        ("ghcup", "install", "cabal", "--set"),
    )


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


def test_binary_path_and_exec_argv() -> None:
    spec = _spec(Path("/proj"))
    assert bootstrap.binary_path(spec, Path("/proj")) == Path("/proj/.build/demo")
    assert bootstrap.exec_argv(spec, Path("/proj"), ("play", "--seed", "7")) == (
        "/proj/.build/demo",
        "play",
        "--seed",
        "7",
    )


# ---------------------------------------------------------------------------
# Driver: recorded commands + mocked seams (no Docker, no host mutation)
# ---------------------------------------------------------------------------


def _patch_seams(
    monkeypatch: pytest.MonkeyPatch,
    sub: Substrate,
    *,
    doctored: list[Substrate],
    execed: list[list[str]],
) -> None:
    monkeypatch.setattr(bootstrap.substrate, "detect", lambda: sub)

    async def _fake_doctor(detected: Substrate) -> object:
        doctored.append(detected)
        return None

    def _fake_execv(path: str, argv: list[str]) -> None:
        execed.append([path, *argv[1:]])

    monkeypatch.setattr(bootstrap.prereqs, "run_doctor", _fake_doctor)
    monkeypatch.setattr(bootstrap.os, "execv", _fake_execv)


async def test_bootstrap_linux_builds_host_native(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, LINUX_CPU, doctored=doctored, execed=execed)

    spec = _spec(tmp_path)
    await bootstrap.bootstrap(spec, project_root=tmp_path, args=("play",))

    assert doctored == [LINUX_CPU]
    # No Docker, no Colima, no copy-out: ensure ghcup toolchain then build native.
    assert recorded_commands == [
        ("ghcup", "install", "ghc", "9.12.4", "--set"),
        ("ghcup", "install", "cabal", "--set"),
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
    assert execed == [[str(tmp_path / ".build/demo"), "play"]]


async def test_bootstrap_linux_gpu_builds_host_native(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, LINUX_GPU, doctored=doctored, execed=execed)

    await bootstrap.bootstrap(_spec(tmp_path), project_root=tmp_path)

    # linux-gpu takes the same host-native path (no container build / copy-out).
    assert recorded_commands[-1][:3] == ("cabal", "install", "exe:demo")
    assert execed == [[str(tmp_path / ".build/demo")]]


async def test_bootstrap_apple_ensures_homebrew_toolchain_then_builds_native(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, APPLE, doctored=doctored, execed=execed)

    await bootstrap.bootstrap(_spec(tmp_path), project_root=tmp_path, args=("--help",))

    assert doctored == [APPLE]
    # Homebrew installs ghcup, ghcup installs GHC+Cabal, then native cabal install.
    assert recorded_commands == [
        ("brew", "install", "ghcup"),
        ("ghcup", "install", "ghc", "9.12.4", "--set"),
        ("ghcup", "install", "cabal", "--set"),
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
