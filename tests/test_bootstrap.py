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


def test_toolchain_ensure_steps_apple() -> None:
    # Apple silicon: probe ghcup itself (Homebrew installs it if absent), then
    # probe/install GHC and Cabal.
    assert bootstrap.toolchain_ensure_steps(APPLE) == (
        bootstrap.ToolchainStep(
            probe=("ghcup", "--version"),
            install=("brew", "install", "ghcup"),
        ),
        bootstrap.ToolchainStep(
            probe=("ghcup", "whereis", "ghc", "9.12.4"),
            install=("ghcup", "install", "ghc", "9.12.4", "--set"),
        ),
        bootstrap.ToolchainStep(
            probe=("ghcup", "whereis", "cabal"),
            install=("ghcup", "install", "cabal", "--set"),
        ),
    )


@pytest.mark.parametrize("sub", [LINUX_CPU, LINUX_GPU])
def test_toolchain_ensure_steps_linux(sub: Substrate) -> None:
    # Linux: probe/install GHC and Cabal via ghcup; no Homebrew step.
    assert bootstrap.toolchain_ensure_steps(sub) == (
        bootstrap.ToolchainStep(
            probe=("ghcup", "whereis", "ghc", "9.12.4"),
            install=("ghcup", "install", "ghc", "9.12.4", "--set"),
        ),
        bootstrap.ToolchainStep(
            probe=("ghcup", "whereis", "cabal"),
            install=("ghcup", "install", "cabal", "--set"),
        ),
    )


def test_native_build_command() -> None:
    spec = _spec(Path("/proj"))
    # Plain incremental `cabal build` (not `install`): no sdist/resolve/copy chatter.
    # The store dir is absolute (resolved against project_root) — cabal rejects a
    # relative --store-dir at per-package configure time.
    assert bootstrap.native_build_command(spec, Path("/proj")) == (
        "cabal",
        "--store-dir",
        "/proj/.build/cabal-store",
        "build",
        "exe:demo",
    )


def test_native_listbin_command() -> None:
    spec = _spec(Path("/proj"))
    # Same absolute --store-dir as the build, so list-bin resolves the same plan
    # and reports the binary that build produced under dist-newstyle/.
    assert bootstrap.native_listbin_command(spec, Path("/proj")) == (
        "cabal",
        "--store-dir",
        "/proj/.build/cabal-store",
        "list-bin",
        "exe:demo",
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
    # Already-provisioned host: each toolchain probe reports the tool present, so
    # no `ghcup install` runs — only the probes, the native build, and the list-bin
    # locate. The build/list-bin argv (incl. the absolute repo-local --store-dir)
    # is pinned in test_native_build_command / test_native_listbin_command.
    assert recorded_commands == [
        ("ghcup", "whereis", "ghc", "9.12.4"),
        ("ghcup", "whereis", "cabal"),
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
    ]
    assert (tmp_path / ".build").is_dir()
    assert execed == [[str(tmp_path / ".build/demo"), "play"]]


async def test_build_binary_builds_without_exec(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, LINUX_CPU, doctored=doctored, execed=execed)

    spec = _spec(tmp_path)
    binary = await bootstrap.build_binary(spec, project_root=tmp_path)

    # Same pre-binary build path as bootstrap(), but it returns the path and
    # never execs. Already-provisioned host: probes only, no install.
    assert doctored == [LINUX_CPU]
    assert recorded_commands == [
        ("ghcup", "whereis", "ghc", "9.12.4"),
        ("ghcup", "whereis", "cabal"),
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
    ]
    assert (tmp_path / ".build").is_dir()
    assert binary == bootstrap.binary_path(spec, tmp_path)
    assert execed == []


async def test_bootstrap_linux_gpu_builds_host_native(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, LINUX_GPU, doctored=doctored, execed=execed)

    spec = _spec(tmp_path)
    await bootstrap.bootstrap(spec, project_root=tmp_path)

    # linux-gpu takes the same host-native path (no container build / copy-out).
    assert recorded_commands[-2:] == [
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
    ]
    assert execed == [[str(tmp_path / ".build/demo")]]


async def test_bootstrap_apple_provisioned_host_probes_then_builds_native(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, APPLE, doctored=doctored, execed=execed)

    spec = _spec(tmp_path)
    await bootstrap.bootstrap(spec, project_root=tmp_path, args=("--help",))

    assert doctored == [APPLE]
    # Already-provisioned Apple host: ghcup, GHC, and Cabal all probe present, so
    # neither Homebrew nor any `ghcup install` runs — only probes, build, list-bin.
    assert recorded_commands == [
        ("ghcup", "--version"),
        ("ghcup", "whereis", "ghc", "9.12.4"),
        ("ghcup", "whereis", "cabal"),
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
    ]
    assert (tmp_path / ".build").is_dir()
    assert execed == [[str(tmp_path / ".build/demo"), "--help"]]


# ---------------------------------------------------------------------------
# Pristine host: probes report absent, so the toolchain installs run
# ---------------------------------------------------------------------------


async def test_bootstrap_linux_fresh_host_installs_toolchain(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands_fresh_host: list[tuple[str, ...]],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, LINUX_CPU, doctored=doctored, execed=execed)

    spec = _spec(tmp_path)
    await bootstrap.bootstrap(spec, project_root=tmp_path, args=("play",))

    # Pristine host: each probe reports absent, so its install runs after it.
    assert recorded_commands_fresh_host == [
        ("ghcup", "whereis", "ghc", "9.12.4"),
        ("ghcup", "install", "ghc", "9.12.4", "--set"),
        ("ghcup", "whereis", "cabal"),
        ("ghcup", "install", "cabal", "--set"),
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
    ]
    assert execed == [[str(tmp_path / ".build/demo"), "play"]]


async def test_bootstrap_apple_fresh_host_installs_homebrew_toolchain(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands_fresh_host: list[tuple[str, ...]],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, APPLE, doctored=doctored, execed=execed)

    spec = _spec(tmp_path)
    await bootstrap.bootstrap(spec, project_root=tmp_path, args=("--help",))

    # Pristine Apple host: ghcup is absent, so Homebrew installs it, then ghcup
    # installs GHC and Cabal, then the native build and list-bin locate run.
    assert recorded_commands_fresh_host == [
        ("ghcup", "--version"),
        ("brew", "install", "ghcup"),
        ("ghcup", "whereis", "ghc", "9.12.4"),
        ("ghcup", "install", "ghc", "9.12.4", "--set"),
        ("ghcup", "whereis", "cabal"),
        ("ghcup", "install", "cabal", "--set"),
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
    ]
    assert execed == [[str(tmp_path / ".build/demo"), "--help"]]


# ---------------------------------------------------------------------------
# _already_present: probe outcome → present / absent
# ---------------------------------------------------------------------------


async def test_already_present_true_when_probe_succeeds(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def _ok(cmd: object, **_: object) -> bootstrap.process.CommandResult:
        argv = tuple(str(part) for part in cmd)  # type: ignore[union-attr]
        return bootstrap.process.CommandResult(args=argv, returncode=0, stdout="", stderr="")

    monkeypatch.setattr(bootstrap.process, "run", _ok)
    assert await bootstrap._already_present(("ghcup", "whereis", "cabal")) is True


async def test_already_present_false_when_probe_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def _fail(cmd: object, **_: object) -> bootstrap.process.CommandResult:
        argv = tuple(str(part) for part in cmd)  # type: ignore[union-attr]
        return bootstrap.process.CommandResult(args=argv, returncode=1, stdout="", stderr="")

    monkeypatch.setattr(bootstrap.process, "run", _fail)
    assert await bootstrap._already_present(("ghcup", "whereis", "cabal")) is False


async def test_already_present_false_when_probe_binary_missing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def _missing(cmd: object, **_: object) -> bootstrap.process.CommandResult:
        raise FileNotFoundError(2, "No such file or directory", "ghcup")

    monkeypatch.setattr(bootstrap.process, "run", _missing)
    assert await bootstrap._already_present(("ghcup", "--version")) is False
