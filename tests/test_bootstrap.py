"""Unit tests for the thin pre-binary bootstrapper (§§ M, N)."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest

from hostbootstrap import bootstrap
from hostbootstrap.substrate import Substrate, SubstrateName

APPLE = Substrate(SubstrateName.APPLE_SILICON, "arm64")
LINUX_CPU = Substrate(SubstrateName.LINUX_CPU, "amd64")
LINUX_GPU = Substrate(SubstrateName.LINUX_GPU, "amd64")
WINDOWS_CPU = Substrate(SubstrateName.WINDOWS_CPU, "amd64")


def _project(project_root: Path) -> bootstrap.ProjectBuildSpec:
    return bootstrap.ProjectBuildSpec(
        project="demo",
        executable="demo",
        cabal_file=project_root / "demo.cabal",
    )


# ---------------------------------------------------------------------------
# Project discovery
# ---------------------------------------------------------------------------


def test_discover_project_derives_name_from_single_cabal_file(tmp_path: Path) -> None:
    cabal = tmp_path / "hostbootstrap-demo.cabal"
    cabal.write_text(
        """
name: hostbootstrap-demo

executable hostbootstrap
  main-is: Main.hs
""".strip(),
        encoding="utf-8",
    )

    assert bootstrap.discover_project(tmp_path) == bootstrap.ProjectBuildSpec(
        project="hostbootstrap-demo",
        executable="hostbootstrap",
        cabal_file=cabal,
    )


def test_discover_project_rejects_missing_cabal_file(tmp_path: Path) -> None:
    with pytest.raises(bootstrap.ProjectDiscoveryError, match="no .cabal file"):
        bootstrap.discover_project(tmp_path)


def test_discover_project_rejects_multiple_cabal_files(tmp_path: Path) -> None:
    (tmp_path / "a.cabal").touch()
    (tmp_path / "b.cabal").touch()

    with pytest.raises(bootstrap.ProjectDiscoveryError, match="multiple .cabal files"):
        bootstrap.discover_project(tmp_path)


def test_discover_project_rejects_missing_executable_stanza(tmp_path: Path) -> None:
    (tmp_path / "demo.cabal").write_text("name: demo\n", encoding="utf-8")

    with pytest.raises(bootstrap.ProjectDiscoveryError, match="no executable stanza"):
        bootstrap.discover_project(tmp_path)


def test_discover_project_rejects_multiple_executable_stanzas(tmp_path: Path) -> None:
    (tmp_path / "demo.cabal").write_text(
        """
name: demo

executable first
  main-is: First.hs

executable second
  main-is: Second.hs
""".strip(),
        encoding="utf-8",
    )

    with pytest.raises(bootstrap.ProjectDiscoveryError, match="multiple executable stanzas"):
        bootstrap.discover_project(tmp_path)


# ---------------------------------------------------------------------------
# Pure command-builders (exact argv)
# ---------------------------------------------------------------------------


def test_toolchain_ensure_steps_apple() -> None:
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


def test_toolchain_ensure_steps_windows() -> None:
    assert bootstrap.toolchain_ensure_steps(WINDOWS_CPU) == (
        bootstrap.ToolchainStep(
            probe=(bootstrap._WINDOWS_GHCUP, "--version"),
            install=(
                bootstrap._POWERSHELL,
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                bootstrap._GHCUP_WINDOWS_BOOTSTRAP,
            ),
        ),
        bootstrap.ToolchainStep(
            probe=(bootstrap._WINDOWS_GHCUP, "whereis", "ghc", "9.12.4"),
            install=(bootstrap._WINDOWS_GHCUP, "install", "ghc", "9.12.4", "--set"),
        ),
        bootstrap.ToolchainStep(
            probe=(bootstrap._WINDOWS_GHCUP, "whereis", "cabal"),
            install=(bootstrap._WINDOWS_GHCUP, "install", "cabal", "--set"),
        ),
    )


def test_windows_toolchain_env_prepends_installed_tool_dirs(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(bootstrap.os, "name", "nt")
    monkeypatch.setenv("PATH", "C:/existing")

    env = bootstrap._toolchain_env()

    assert env["PATH"].startswith("C:\\ghcup\\bin;C:\\cabal\\bin;")
    assert env["PATH"].endswith("C:/existing")


def test_native_build_command() -> None:
    spec = _project(Path("/proj"))
    cabal = bootstrap._WINDOWS_CABAL if bootstrap.os.name == "nt" else "cabal"
    assert bootstrap.native_build_command(spec, Path("/proj")) == (
        cabal,
        "--store-dir",
        str(Path("/proj") / ".build/cabal-store"),
        "build",
        "exe:demo",
    )


def test_cabal_update_command() -> None:
    cabal = bootstrap._WINDOWS_CABAL if bootstrap.os.name == "nt" else "cabal"
    assert bootstrap.cabal_update_command() == (cabal, "update")


def test_native_listbin_command() -> None:
    spec = _project(Path("/proj"))
    cabal = bootstrap._WINDOWS_CABAL if bootstrap.os.name == "nt" else "cabal"
    assert bootstrap.native_listbin_command(spec, Path("/proj")) == (
        cabal,
        "--store-dir",
        str(Path("/proj") / ".build/cabal-store"),
        "list-bin",
        "exe:demo",
    )


def test_binary_path_and_exec_argv() -> None:
    spec = _project(Path("/proj"))
    expected = Path("/proj") / ".build" / ("demo.exe" if bootstrap.os.name == "nt" else "demo")
    assert bootstrap.binary_path(spec, Path("/proj")) == expected
    assert bootstrap.exec_argv(spec, Path("/proj"), ("play", "--seed", "7")) == (
        str(expected),
        "play",
        "--seed",
        "7",
    )


def test_windows_exec_project_binary_exits_with_child_status(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[list[str]] = []

    def _fake_run(argv: list[str], *, check: bool) -> SimpleNamespace:
        calls.append(argv)
        assert check is False
        return SimpleNamespace(returncode=17)

    monkeypatch.setattr(bootstrap.os, "name", "nt")
    monkeypatch.setattr(bootstrap.subprocess, "run", _fake_run)

    with pytest.raises(SystemExit) as exc:
        bootstrap._exec_project_binary(("demo.exe", "project", "up"))

    assert exc.value.code == 17
    assert calls == [["demo.exe", "project", "up"]]


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

    async def _fake_doctor(detected: Substrate) -> bootstrap.prereqs.DoctorResult:
        doctored.append(detected)
        return bootstrap.prereqs.DoctorResult(detected, ("ok",))

    def _fake_exec_project_binary(argv: tuple[str, ...]) -> None:
        execed.append(list(argv))

    monkeypatch.setattr(bootstrap.prereqs, "run_doctor", _fake_doctor)
    monkeypatch.setattr(bootstrap, "_exec_project_binary", _fake_exec_project_binary)


async def test_bootstrap_linux_builds_host_native_without_writing_dhall(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, LINUX_CPU, doctored=doctored, execed=execed)

    spec = _project(tmp_path)
    await bootstrap.bootstrap(spec, project_root=tmp_path, args=("play",))

    assert doctored == [LINUX_CPU]
    assert recorded_commands == [
        ("ghcup", "whereis", "ghc", "9.12.4"),
        ("ghcup", "whereis", "cabal"),
        bootstrap.cabal_update_command(),
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
    ]
    assert (tmp_path / ".build").is_dir()
    assert not any(path.suffix == ".dhall" for path in (tmp_path / ".build").iterdir())
    assert execed == [[str(bootstrap.binary_path(spec, tmp_path)), "play"]]


async def test_build_binary_builds_without_exec_or_dhall(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, LINUX_CPU, doctored=doctored, execed=execed)

    spec = _project(tmp_path)
    binary = await bootstrap.build_binary(spec, project_root=tmp_path)

    assert doctored == [LINUX_CPU]
    # build_binary builds and locates the binary -- it does NOT run any
    # ``project init`` / config-init step (no auto-init).
    assert recorded_commands == [
        ("ghcup", "whereis", "ghc", "9.12.4"),
        ("ghcup", "whereis", "cabal"),
        bootstrap.cabal_update_command(),
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
    ]
    assert all("init" not in cmd for cmd in recorded_commands)
    assert binary == bootstrap.binary_path(spec, tmp_path)
    assert not any(path.suffix == ".dhall" for path in (tmp_path / ".build").iterdir())
    assert execed == []


async def test_bootstrap_linux_gpu_builds_host_native(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, LINUX_GPU, doctored=doctored, execed=execed)

    spec = _project(tmp_path)
    await bootstrap.bootstrap(spec, project_root=tmp_path)

    assert recorded_commands[-3:] == [
        bootstrap.cabal_update_command(),
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
    ]
    assert execed == [[str(bootstrap.binary_path(spec, tmp_path))]]


async def test_bootstrap_apple_provisioned_host_probes_then_builds_native(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[tuple[str, ...]],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, APPLE, doctored=doctored, execed=execed)

    spec = _project(tmp_path)
    await bootstrap.bootstrap(spec, project_root=tmp_path, args=("--help",))

    assert doctored == [APPLE]
    assert recorded_commands == [
        ("ghcup", "--version"),
        ("ghcup", "whereis", "ghc", "9.12.4"),
        ("ghcup", "whereis", "cabal"),
        bootstrap.cabal_update_command(),
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
    ]
    assert execed == [[str(bootstrap.binary_path(spec, tmp_path)), "--help"]]


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

    spec = _project(tmp_path)
    await bootstrap.bootstrap(spec, project_root=tmp_path, args=("play",))

    assert recorded_commands_fresh_host == [
        ("ghcup", "whereis", "ghc", "9.12.4"),
        ("ghcup", "install", "ghc", "9.12.4", "--set"),
        ("ghcup", "whereis", "cabal"),
        ("ghcup", "install", "cabal", "--set"),
        bootstrap.cabal_update_command(),
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
    ]
    assert execed == [[str(bootstrap.binary_path(spec, tmp_path)), "play"]]


async def test_bootstrap_apple_fresh_host_installs_homebrew_toolchain(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands_fresh_host: list[tuple[str, ...]],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, APPLE, doctored=doctored, execed=execed)

    spec = _project(tmp_path)
    await bootstrap.bootstrap(spec, project_root=tmp_path, args=("--help",))

    assert recorded_commands_fresh_host == [
        ("ghcup", "--version"),
        ("brew", "install", "ghcup"),
        ("ghcup", "whereis", "ghc", "9.12.4"),
        ("ghcup", "install", "ghc", "9.12.4", "--set"),
        ("ghcup", "whereis", "cabal"),
        ("ghcup", "install", "cabal", "--set"),
        bootstrap.cabal_update_command(),
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
    ]
    assert execed == [[str(bootstrap.binary_path(spec, tmp_path)), "--help"]]


# ---------------------------------------------------------------------------
# _already_present: probe outcome -> present / absent
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
