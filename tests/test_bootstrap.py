"""Unit tests for the thin pre-binary bootstrapper (§§ M, N)."""

from __future__ import annotations

import hashlib
import os
import tempfile
from collections.abc import Mapping
from pathlib import Path
from types import SimpleNamespace

import pytest

from hostbootstrap import bootstrap
from hostbootstrap import substrate as substrate_module
from hostbootstrap.substrate import Arch, Substrate, SubstrateName

RecordedCommand = tuple[tuple[str, ...], Path | None, str]

APPLE = Substrate(SubstrateName.APPLE_SILICON, Arch.ARM64)
LINUX_CPU = Substrate(SubstrateName.LINUX_CPU, Arch.AMD64)
LINUX_GPU = Substrate(SubstrateName.LINUX_GPU, Arch.AMD64)
WINDOWS_CPU = Substrate(SubstrateName.WINDOWS_CPU, Arch.AMD64)


def _project(project_root: Path) -> bootstrap.ProjectBuildSpec:
    return bootstrap.ProjectBuildSpec(
        identity="demo",
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

executable hostbootstrap-demo
  main-is: Main.hs
""".strip(),
        encoding="utf-8",
    )

    assert bootstrap.discover_project(tmp_path) == bootstrap.ProjectBuildSpec(
        identity="hostbootstrap-demo",
        cabal_file=cabal,
    )


def test_discover_project_rejects_missing_cabal_file(tmp_path: Path) -> None:
    with pytest.raises(bootstrap.ProjectDiscoveryError, match="no .cabal file"):
        bootstrap.discover_project(tmp_path)


def test_discover_project_rejects_multiple_cabal_files(tmp_path: Path) -> None:
    (tmp_path / "a.cabal").touch()
    (tmp_path / "b.cabal").touch()

    with pytest.raises(bootstrap.ProjectDiscoveryError, match="--cabal-file"):
        bootstrap.discover_project(tmp_path)


def test_discover_project_accepts_explicit_selection_when_multiple_exist(tmp_path: Path) -> None:
    for name in ("a", "b"):
        (tmp_path / f"{name}.cabal").write_text(
            f"name: {name}\n\nexecutable {name}\n  main-is: Main.hs\n",
            encoding="utf-8",
        )

    selected = bootstrap.discover_project(tmp_path, selected_cabal_file=Path("b.cabal"))

    assert selected.identity == "b"
    assert selected.cabal_file == (tmp_path / "b.cabal").resolve()


@pytest.mark.parametrize(
    "selection",
    [
        Path("missing.cabal"),
        Path("nested/demo.cabal"),
        Path("demo.txt"),
    ],
)
def test_discover_project_rejects_invalid_explicit_selection(
    tmp_path: Path, selection: Path
) -> None:
    (tmp_path / "demo.txt").touch()
    (tmp_path / "nested").mkdir()
    (tmp_path / "nested/demo.cabal").touch()

    with pytest.raises(bootstrap.ProjectDiscoveryError, match="directly under"):
        bootstrap.discover_project(tmp_path, selected_cabal_file=selection)


@pytest.mark.parametrize(
    "contents",
    [
        "name: other\n\nexecutable demo\n  main-is: Main.hs\n",
        "name: demo\n\nexecutable other\n  main-is: Main.hs\n",
        "name: other\n\nexecutable other\n  main-is: Main.hs\n",
    ],
)
def test_discover_project_rejects_every_identity_mismatch(tmp_path: Path, contents: str) -> None:
    (tmp_path / "demo.cabal").write_text(contents, encoding="utf-8")

    with pytest.raises(bootstrap.ProjectDiscoveryError, match="identity mismatch"):
        bootstrap.discover_project(tmp_path)


def test_discover_project_rejects_missing_executable_stanza(tmp_path: Path) -> None:
    (tmp_path / "demo.cabal").write_text("name: demo\n", encoding="utf-8")

    with pytest.raises(bootstrap.ProjectDiscoveryError, match="no executable stanza"):
        bootstrap.discover_project(tmp_path)


def test_discover_project_accepts_cabal_section_keyword_case(tmp_path: Path) -> None:
    (tmp_path / "demo.cabal").write_text(
        "Name: demo\n\nExecutable demo\n  main-is: Main.hs\n", encoding="utf-8"
    )
    assert bootstrap.discover_project(tmp_path).identity == "demo"


def test_discover_project_rejects_missing_package_name(tmp_path: Path) -> None:
    (tmp_path / "demo.cabal").write_text("executable demo\n  main-is: Main.hs\n", encoding="utf-8")

    with pytest.raises(bootstrap.ProjectDiscoveryError, match="no package name"):
        bootstrap.discover_project(tmp_path)


def test_discover_project_rejects_multiple_package_names(tmp_path: Path) -> None:
    (tmp_path / "demo.cabal").write_text(
        "name: demo\nname: duplicate\n\nexecutable demo\n  main-is: Main.hs\n",
        encoding="utf-8",
    )

    with pytest.raises(bootstrap.ProjectDiscoveryError, match="multiple package name"):
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


def test_linux_build_library_probe_is_one_all_of_query() -> None:
    # `dpkg-query -s` exits non-zero if ANY named package is missing, so a
    # partially provisioned host reinstalls the set instead of passing.
    assert bootstrap.linux_build_library_probe() == (
        "dpkg-query",
        "-s",
        "build-essential",
        "libgmp-dev",
        "libncurses-dev",
        "libtinfo-dev",
        "pkg-config",
        "zlib1g-dev",
    )


def test_linux_build_library_install_refreshes_the_index_first() -> None:
    # A cloud image's apt index is routinely older than its archive, so
    # installing without the refresh 404s on the packages this step adds.
    assert bootstrap.linux_build_library_install_commands() == (
        ("sudo", "-n", "apt-get", "update"),
        (
            "sudo",
            "-n",
            "apt-get",
            "install",
            "-y",
            "build-essential",
            "libgmp-dev",
            "libncurses-dev",
            "libtinfo-dev",
            "pkg-config",
            "zlib1g-dev",
        ),
    )


def test_linux_build_libraries_cover_the_closure_that_broke_a_pristine_host() -> None:
    # The observed failure on a pristine Ubuntu 24.04 metal host was
    # `Missing (or bad) C library: z` while building zlib, and GHC itself links
    # gmp and ncurses.
    packages = bootstrap.linux_build_library_probe()
    for required in ("zlib1g-dev", "libgmp-dev", "libncurses-dev"):
        assert required in packages


@pytest.mark.parametrize("sub", [LINUX_CPU, LINUX_GPU])
def test_toolchain_ensure_steps_linux(sub: Substrate) -> None:
    assert bootstrap.toolchain_ensure_steps(sub) == (
        bootstrap.ToolchainStep(
            probe=("ghcup", "--version"),
            install=(),
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


def test_toolchain_ensure_steps_windows() -> None:
    assert bootstrap.toolchain_ensure_steps(WINDOWS_CPU) == (
        bootstrap.ToolchainStep(
            probe=(bootstrap._WINDOWS_GHCUP, "--version"),
            install=(),
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

    expected_prefix = bootstrap.os.pathsep.join(str(p) for p in bootstrap._WINDOWS_TOOLCHAIN_PATHS)
    assert env["PATH"].startswith(expected_prefix + bootstrap.os.pathsep)
    assert env["PATH"].endswith("C:/existing")


def test_posix_toolchain_env_prepends_ghcup_bins(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(bootstrap.os, "name", "posix")
    monkeypatch.setattr(bootstrap.Path, "home", lambda: tmp_path)
    monkeypatch.setenv("PATH", "/usr/bin")

    env = bootstrap._toolchain_env()

    sep = bootstrap.os.pathsep
    expected_dirs = (
        tmp_path / ".ghcup" / "bin",
        tmp_path / ".cabal" / "bin",
        tmp_path / ".local" / "bin",
    )
    expected_prefix = sep.join(str(p) for p in expected_dirs)
    assert env["PATH"].startswith(expected_prefix + sep)
    assert env["PATH"].endswith("/usr/bin")


async def test_verified_ghcup_download_installs_only_matching_digest(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    payload = b"pinned ghcup"
    digest = hashlib.sha256(payload).hexdigest()
    chmod_modes: list[int] = []
    monkeypatch.setitem(
        bootstrap._GHCUP_DOWNLOADS,
        ("linux", Arch.AMD64),
        ("https://downloads.haskell.org/ghcup/pinned", digest),
    )
    monkeypatch.setattr(bootstrap.Path, "home", lambda: tmp_path)
    monkeypatch.setattr(bootstrap.Path, "chmod", lambda _path, mode: chmod_modes.append(mode))
    monkeypatch.setattr(bootstrap.shutil, "which", lambda name: f"/usr/bin/{name}")

    async def _download(command: tuple[str, ...], **_kwargs: object) -> SimpleNamespace:
        assert command == (
            "/usr/bin/curl",
            "--proto",
            "=https",
            "--tlsv1.2",
            "-fsSL",
            "https://downloads.haskell.org/ghcup/pinned",
            "-o",
            command[-1],
        )
        Path(command[-1]).write_bytes(payload)
        return SimpleNamespace(ok=True)

    monkeypatch.setattr(bootstrap.process, "run_checked", _download)
    await bootstrap._install_verified_ghcup(LINUX_CPU)

    installed = tmp_path / ".ghcup/bin/ghcup"
    assert installed.read_bytes() == payload
    assert chmod_modes == [0o755]


async def test_verified_ghcup_download_rejects_digest_mismatch(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setitem(
        bootstrap._GHCUP_DOWNLOADS,
        ("linux", Arch.AMD64),
        ("https://downloads.haskell.org/ghcup/pinned", "0" * 64),
    )
    monkeypatch.setattr(bootstrap.Path, "home", lambda: tmp_path)
    monkeypatch.setattr(bootstrap.shutil, "which", lambda name: f"/usr/bin/{name}")

    async def _download(command: tuple[str, ...], **_kwargs: object) -> SimpleNamespace:
        Path(command[-1]).write_bytes(b"tampered")
        return SimpleNamespace(ok=True)

    monkeypatch.setattr(bootstrap.process, "run_checked", _download)
    with pytest.raises(RuntimeError, match="digest mismatch"):
        await bootstrap._install_verified_ghcup(LINUX_CPU)
    assert not (tmp_path / ".ghcup/bin/ghcup").exists()


async def test_verified_ghcup_download_supports_windows_powershell(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    payload = b"windows ghcup"
    digest = hashlib.sha256(payload).hexdigest()
    destination = tmp_path / "ghcup.exe"
    monkeypatch.setattr(bootstrap, "_WINDOWS_GHCUP", str(destination))
    monkeypatch.setitem(
        bootstrap._GHCUP_DOWNLOADS,
        ("windows", Arch.AMD64),
        ("https://downloads.haskell.org/ghcup/pinned.exe", digest),
    )
    commands: list[tuple[str, ...]] = []
    temporary_directory = tempfile.TemporaryDirectory
    monkeypatch.setattr(
        bootstrap.tempfile,
        "TemporaryDirectory",
        lambda **kwargs: temporary_directory(dir=tmp_path, prefix="ghcup's-"),
    )

    async def _download(command: tuple[str, ...], **_kwargs: object) -> SimpleNamespace:
        commands.append(command)
        assert command[3] == "& { param($u,$o) Invoke-WebRequest -Uri $u -OutFile $o }"
        assert command[4] == "https://downloads.haskell.org/ghcup/pinned.exe"
        assert "'" in command[5]
        downloaded = Path(command[5])
        downloaded.write_bytes(payload)
        return SimpleNamespace(ok=True)

    monkeypatch.setattr(bootstrap.process, "run_checked", _download)
    await bootstrap._install_verified_ghcup(WINDOWS_CPU)

    assert commands[0][:3] == (
        bootstrap._POWERSHELL,
        "-NoProfile",
        "-Command",
    )
    assert destination.read_bytes() == payload


async def test_verified_ghcup_download_rejects_unpinned_platform_arch() -> None:
    """The table is total over `Arch` per platform only where a pin exists."""
    unpinned = Substrate(SubstrateName.WINDOWS_CPU, Arch.ARM64)
    with pytest.raises(RuntimeError, match="no pinned GHCup download"):
        await bootstrap._install_verified_ghcup(unpinned)


async def test_verified_ghcup_download_requires_curl(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(bootstrap.Path, "home", lambda: tmp_path)
    monkeypatch.setattr(bootstrap.shutil, "which", lambda _name: None)
    with pytest.raises(RuntimeError, match="curl disappeared"):
        await bootstrap._install_verified_ghcup(LINUX_CPU)


@pytest.mark.parametrize("os_name, cabal", [("nt", r"C:\ghcup\bin\cabal.exe"), ("posix", "cabal")])
def test_native_build_command(monkeypatch: pytest.MonkeyPatch, os_name: str, cabal: str) -> None:
    monkeypatch.setattr(bootstrap, "os", SimpleNamespace(name=os_name))
    spec = _project(Path("/proj"))
    assert spec.project == "demo"
    assert bootstrap.native_build_command(spec, Path("/proj")) == (
        cabal,
        "--store-dir",
        str(Path("/proj") / ".build/cabal-store"),
        "build",
        "-j1",
        "exe:demo",
    )


@pytest.mark.parametrize("os_name, cabal", [("nt", r"C:\ghcup\bin\cabal.exe"), ("posix", "cabal")])
def test_native_build_command_offline(
    monkeypatch: pytest.MonkeyPatch, os_name: str, cabal: str
) -> None:
    monkeypatch.setattr(bootstrap, "os", SimpleNamespace(name=os_name))
    spec = _project(Path("/proj"))
    assert bootstrap.native_build_command(spec, Path("/proj"), offline=True) == (
        cabal,
        "--store-dir",
        str(Path("/proj") / ".build/cabal-store"),
        "build",
        "-j1",
        "--offline",
        "exe:demo",
    )


@pytest.mark.parametrize("os_name, cabal", [("nt", r"C:\ghcup\bin\cabal.exe"), ("posix", "cabal")])
def test_cabal_update_command(monkeypatch: pytest.MonkeyPatch, os_name: str, cabal: str) -> None:
    monkeypatch.setattr(bootstrap, "os", SimpleNamespace(name=os_name))
    assert bootstrap.cabal_update_command() == (cabal, "update")


def test_cabal_index_path_honors_cabal_dir(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv("CABAL_DIR", str(tmp_path / "configured"))
    assert bootstrap.cabal_index_path() == (
        tmp_path / "configured/packages/hackage.haskell.org/01-index.tar"
    )

    monkeypatch.delenv("CABAL_DIR")
    monkeypatch.setattr(bootstrap, "os", SimpleNamespace(name="posix", environ=os.environ))
    monkeypatch.setattr(bootstrap.Path, "home", lambda: tmp_path)
    (tmp_path / ".cabal").mkdir()
    assert bootstrap.cabal_index_path() == (
        tmp_path / ".cabal/packages/hackage.haskell.org/01-index.tar"
    )


def test_cabal_index_state_distinguishes_missing_fresh_and_stale(tmp_path: Path) -> None:
    index = tmp_path / "01-index.tar"
    assert bootstrap.cabal_index_state(index, now=100.0) is bootstrap.CabalIndexState.MISSING

    index.write_bytes(b"index")
    index.touch()
    modified = index.stat().st_mtime
    assert bootstrap.cabal_index_state(index, now=modified) is bootstrap.CabalIndexState.FRESH
    assert (
        bootstrap.cabal_index_state(
            index,
            now=modified + bootstrap._CABAL_INDEX_MAX_AGE_SECONDS + 1,
        )
        is bootstrap.CabalIndexState.STALE
    )
    assert bootstrap.cabal_index_state(index, now=modified - 1) is bootstrap.CabalIndexState.FRESH


@pytest.mark.parametrize("os_name, cabal", [("nt", r"C:\ghcup\bin\cabal.exe"), ("posix", "cabal")])
def test_native_listbin_command(monkeypatch: pytest.MonkeyPatch, os_name: str, cabal: str) -> None:
    monkeypatch.setattr(bootstrap, "os", SimpleNamespace(name=os_name))
    spec = _project(Path("/proj"))
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
    cwds: list[Path] = []

    environments: list[dict[str, str]] = []

    def _probe(
        argv: tuple[str, ...],
        *,
        cwd: Path,
        env: dict[str, str],
        stdio: bootstrap.process.Stdio,
    ) -> bootstrap.process.CommandOutcome:
        calls.append(list(argv))
        cwds.append(cwd)
        environments.append(env)
        assert stdio is bootstrap.process.Stdio.INHERIT
        return bootstrap.process.CommandResult(argv, 17, "", "")

    monkeypatch.setattr(bootstrap.os, "name", "nt")
    monkeypatch.setattr(bootstrap.process, "probe", _probe)

    with pytest.raises(SystemExit) as exc:
        bootstrap._exec_project_binary(
            ("demo.exe", "project", "up"),
            Path("/proj"),
            context=substrate_module.invocation_context(WINDOWS_CPU),
        )

    assert exc.value.code == 17
    assert calls == [["demo.exe", "project", "up"]]
    assert cwds == [Path("/proj")]
    assert environments == [
        {"HOSTBOOTSTRAP_HOST_SUBSTRATE": "windows-cpu", "HOSTBOOTSTRAP_HOST_ARCH": "amd64"}
    ]


def test_windows_exec_project_binary_reports_an_unlaunchable_binary(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(bootstrap.os, "name", "nt")
    monkeypatch.setattr(
        bootstrap.process,
        "probe",
        lambda argv, **_k: bootstrap.process.CommandUnavailable(tuple(argv), "not executable"),
    )

    with pytest.raises(RuntimeError, match="could not be run"):
        bootstrap._exec_project_binary(
            ("demo.exe",), Path("/proj"), context=substrate_module.invocation_context(WINDOWS_CPU)
        )


def test_posix_exec_project_binary_rehomes_to_project_root_then_execs(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chdirs: list[Path] = []
    execs: list[tuple[str, list[str], dict[str, str]]] = []
    monkeypatch.setattr(bootstrap.os, "name", "posix")
    monkeypatch.setattr(bootstrap.os, "chdir", lambda p: chdirs.append(p))
    monkeypatch.setattr(
        bootstrap.os, "execve", lambda exe, argv, env: execs.append((exe, argv, env))
    )

    bootstrap._exec_project_binary(
        ("/abs/demo", "project", "up"),
        Path("/proj"),
        context=substrate_module.invocation_context(LINUX_GPU),
    )

    assert chdirs == [Path("/proj")]
    assert [(exe, argv) for exe, argv, _env in execs] == [
        ("/abs/demo", ["/abs/demo", "project", "up"])
    ]
    # The seam is set on the child explicitly, not left to be inherited.
    (_exe, _argv, environment) = execs[0]
    assert environment[substrate_module.SUBSTRATE_ENV_VAR] == "linux-gpu"
    assert environment[substrate_module.ARCH_ENV_VAR] == "amd64"
    assert "PATH" in environment


# ---------------------------------------------------------------------------
# Driver: recorded commands + mocked seams (no Docker, no host mutation)
# ---------------------------------------------------------------------------


def _patch_seams(
    monkeypatch: pytest.MonkeyPatch,
    sub: Substrate,
    *,
    doctored: list[Substrate],
    execed: list[list[str]],
    contexts: list[dict[str, str]] | None = None,
) -> None:
    contexts = [] if contexts is None else contexts
    monkeypatch.setattr(bootstrap.substrate, "detect", lambda: sub)

    async def _fake_doctor(detected: Substrate) -> bootstrap.prereqs.DoctorResult:
        doctored.append(detected)
        return bootstrap.prereqs.DoctorResult(detected, ("ok",))

    def _fake_exec_project_binary(
        argv: tuple[str, ...], project_root: Path, *, context: Mapping[str, str]
    ) -> None:
        execed.append(list(argv))
        contexts.append(dict(context))

    monkeypatch.setattr(bootstrap.prereqs, "run_doctor", _fake_doctor)
    monkeypatch.setattr(bootstrap, "_exec_project_binary", _fake_exec_project_binary)


async def test_bootstrap_states_the_detected_host_to_the_binary_it_launches(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[RecordedCommand],
    tmp_path: Path,
) -> None:
    """§ M: the bootstrapper detects, the binary receives — it does not re-classify."""
    _ = recorded_commands
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    contexts: list[dict[str, str]] = []
    _patch_seams(monkeypatch, LINUX_GPU, doctored=doctored, execed=execed, contexts=contexts)
    await bootstrap.bootstrap(_project(tmp_path), project_root=tmp_path)

    assert contexts == [
        {"HOSTBOOTSTRAP_HOST_SUBSTRATE": "linux-gpu", "HOSTBOOTSTRAP_HOST_ARCH": "amd64"}
    ]


async def test_bootstrap_linux_builds_host_native_without_writing_dhall(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[RecordedCommand],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, LINUX_CPU, doctored=doctored, execed=execed)
    spec = _project(tmp_path)
    await bootstrap.bootstrap(spec, project_root=tmp_path, args=("play",))

    assert doctored == [LINUX_CPU]
    assert [argv for argv, _cwd, _kind in recorded_commands] == [
        # A satisfied host runs the library probe and installs nothing.
        bootstrap.linux_build_library_probe(),
        ("ghcup", "--version"),
        ("ghcup", "whereis", "ghc", "9.12.4"),
        ("ghcup", "whereis", "cabal"),
        bootstrap.cabal_update_command(),
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
        (str(bootstrap.binary_path(spec, tmp_path)), "--hostbootstrap-install-identity"),
    ]
    assert (tmp_path / ".build").is_dir()
    assert not any(path.suffix == ".dhall" for path in (tmp_path / ".build").iterdir())
    assert execed == [[str(bootstrap.binary_path(spec, tmp_path)), "play"]]


async def test_build_binary_builds_without_exec_or_dhall(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[RecordedCommand],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, LINUX_CPU, doctored=doctored, execed=execed)

    spec = _project(tmp_path)
    binary = await bootstrap.build_binary(spec, project_root=tmp_path)

    assert doctored == [LINUX_CPU]
    # build_binary builds and locates the binary, then asks that installed
    # binary to provision its own cryptographic identity. It does not run any
    # ``project init`` / config-init step (no auto-init).
    assert [argv for argv, _cwd, _kind in recorded_commands] == [
        # A satisfied host runs the library probe and installs nothing.
        bootstrap.linux_build_library_probe(),
        ("ghcup", "--version"),
        ("ghcup", "whereis", "ghc", "9.12.4"),
        ("ghcup", "whereis", "cabal"),
        bootstrap.cabal_update_command(),
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
        (str(bootstrap.binary_path(spec, tmp_path)), "--hostbootstrap-install-identity"),
    ]
    assert all("init" not in argv for argv, _cwd, _kind in recorded_commands)
    assert binary == bootstrap.binary_path(spec, tmp_path)
    assert not any(path.suffix == ".dhall" for path in (tmp_path / ".build").iterdir())
    assert execed == []


async def test_build_native_skips_update_for_fresh_index_and_unchanged_copy(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    spec = _project(tmp_path)
    source = tmp_path / "dist/demo"
    source.parent.mkdir()
    source.write_bytes(b"same binary")
    destination = bootstrap.binary_path(spec, tmp_path)
    destination.parent.mkdir()
    destination.write_bytes(b"same binary")
    commands: list[tuple[str, ...]] = []
    copies: list[tuple[Path, Path]] = []
    monkeypatch.setattr(
        bootstrap,
        "cabal_index_state",
        lambda _index: bootstrap.CabalIndexState.FRESH,
    )

    async def _checked(command: object, **_kwargs: object) -> bootstrap.process.CommandResult:
        argv = tuple(str(part) for part in command)  # type: ignore[union-attr]
        commands.append(argv)
        stdout = str(source) if "list-bin" in argv else ""
        return bootstrap.process.CommandResult(argv, 0, stdout, "")

    monkeypatch.setattr(bootstrap.process, "run_checked", _checked)
    monkeypatch.setattr(bootstrap.shutil, "copy2", lambda left, right: copies.append((left, right)))

    await bootstrap._build_native(spec, project_root=tmp_path)

    assert commands == [
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
        (str(destination), "--hostbootstrap-install-identity"),
    ]
    assert copies == []


async def test_build_native_offline_uses_cache_and_copies_changed_binary(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    spec = _project(tmp_path)
    source = tmp_path / "dist/demo"
    source.parent.mkdir()
    source.write_bytes(b"new binary")
    commands: list[tuple[str, ...]] = []
    monkeypatch.setattr(
        bootstrap,
        "cabal_index_state",
        lambda _index: bootstrap.CabalIndexState.STALE,
    )

    async def _checked(command: object, **_kwargs: object) -> bootstrap.process.CommandResult:
        argv = tuple(str(part) for part in command)  # type: ignore[union-attr]
        commands.append(argv)
        stdout = str(source) if "list-bin" in argv else ""
        return bootstrap.process.CommandResult(argv, 0, stdout, "")

    monkeypatch.setattr(bootstrap.process, "run_checked", _checked)

    await bootstrap._build_native(spec, project_root=tmp_path, offline=True)

    assert commands == [
        bootstrap.native_build_command(spec, tmp_path, offline=True),
        bootstrap.native_listbin_command(spec, tmp_path),
        (
            str(bootstrap.binary_path(spec, tmp_path)),
            "--hostbootstrap-install-identity",
        ),
    ]
    assert bootstrap.binary_path(spec, tmp_path).read_bytes() == b"new binary"


async def test_build_native_offline_rejects_missing_index_before_cabal(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(
        bootstrap,
        "cabal_index_state",
        lambda _index: bootstrap.CabalIndexState.MISSING,
    )

    async def _unexpected(*_args: object, **_kwargs: object) -> object:
        raise AssertionError("Cabal must not run without an offline index")

    monkeypatch.setattr(bootstrap.process, "run_checked", _unexpected)
    with pytest.raises(RuntimeError, match="requires a cached Cabal package index"):
        await bootstrap._build_native(_project(tmp_path), project_root=tmp_path, offline=True)


async def test_build_native_offline_wraps_unresolved_inputs(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(
        bootstrap,
        "cabal_index_state",
        lambda _index: bootstrap.CabalIndexState.FRESH,
    )

    async def _failed(command: object, **_kwargs: object) -> object:
        argv = tuple(str(part) for part in command)  # type: ignore[union-attr]
        result = bootstrap.process.CommandResult(argv, 1, "", "dependency unavailable")
        raise bootstrap.process.CommandError(result)

    monkeypatch.setattr(bootstrap.process, "run_checked", _failed)
    with pytest.raises(RuntimeError, match="could not resolve all inputs"):
        await bootstrap._build_native(_project(tmp_path), project_root=tmp_path, offline=True)


async def test_build_native_online_preserves_cabal_command_error(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setattr(
        bootstrap,
        "cabal_index_state",
        lambda _index: bootstrap.CabalIndexState.FRESH,
    )

    async def _failed(command: object, **_kwargs: object) -> object:
        argv = tuple(str(part) for part in command)  # type: ignore[union-attr]
        result = bootstrap.process.CommandResult(argv, 1, "", "build failed")
        raise bootstrap.process.CommandError(result)

    monkeypatch.setattr(bootstrap.process, "run_checked", _failed)
    with pytest.raises(bootstrap.process.CommandError):
        await bootstrap._build_native(_project(tmp_path), project_root=tmp_path)


def test_copy_if_changed_handles_missing_size_and_digest_differences(
    tmp_path: Path,
) -> None:
    source = tmp_path / "source"
    destination = tmp_path / "destination"
    source.write_bytes(b"abc")

    assert bootstrap._copy_if_changed(source, destination) is True
    assert destination.read_bytes() == b"abc"
    assert bootstrap._copy_if_changed(source, destination) is False

    source.write_bytes(b"longer")
    assert bootstrap._copy_if_changed(source, destination) is True
    source.write_bytes(b"XXXXXX")
    assert bootstrap._copy_if_changed(source, destination) is True


async def test_bootstrap_and_build_share_one_doctor(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[RecordedCommand],
    tmp_path: Path,
) -> None:
    # `run` and `build` assert the SAME floor -- there is no separate build
    # doctor. Both drive `run_doctor` exactly once for the detected substrate.
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, LINUX_CPU, doctored=doctored, execed=execed)

    spec = _project(tmp_path)
    await bootstrap.bootstrap(spec, project_root=tmp_path)
    await bootstrap.build_binary(spec, project_root=tmp_path)

    assert doctored == [LINUX_CPU, LINUX_CPU]
    assert execed == [[str(bootstrap.binary_path(spec, tmp_path))]]


async def test_bootstrap_linux_gpu_builds_host_native(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[RecordedCommand],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, LINUX_GPU, doctored=doctored, execed=execed)

    spec = _project(tmp_path)
    await bootstrap.bootstrap(spec, project_root=tmp_path)

    assert [argv for argv, _cwd, _kind in recorded_commands] == [
        bootstrap.linux_build_library_probe(),
        ("ghcup", "--version"),
        ("ghcup", "whereis", "ghc", "9.12.4"),
        ("ghcup", "whereis", "cabal"),
        bootstrap.cabal_update_command(),
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
        (str(bootstrap.binary_path(spec, tmp_path)), "--hostbootstrap-install-identity"),
    ]
    assert execed == [[str(bootstrap.binary_path(spec, tmp_path))]]


async def test_bootstrap_apple_provisioned_host_probes_then_builds_native(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands: list[RecordedCommand],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, APPLE, doctored=doctored, execed=execed)

    spec = _project(tmp_path)
    await bootstrap.bootstrap(spec, project_root=tmp_path, args=("--help",))

    assert doctored == [APPLE]
    assert [argv for argv, _cwd, _kind in recorded_commands] == [
        ("ghcup", "--version"),
        ("ghcup", "whereis", "ghc", "9.12.4"),
        ("ghcup", "whereis", "cabal"),
        bootstrap.cabal_update_command(),
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
        (str(bootstrap.binary_path(spec, tmp_path)), "--hostbootstrap-install-identity"),
    ]
    assert execed == [[str(bootstrap.binary_path(spec, tmp_path)), "--help"]]


# ---------------------------------------------------------------------------
# Pristine host: probes report absent, so the toolchain installs run
# ---------------------------------------------------------------------------


async def test_bootstrap_linux_fresh_host_installs_toolchain(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands_fresh_host: list[RecordedCommand],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, LINUX_CPU, doctored=doctored, execed=execed)
    installed: list[Substrate] = []

    async def _install(sub: Substrate) -> None:
        installed.append(sub)

    monkeypatch.setattr(bootstrap, "_install_verified_ghcup", _install)

    spec = _project(tmp_path)
    await bootstrap.bootstrap(spec, project_root=tmp_path, args=("play",))

    # The C build libraries are installed FIRST, before GHC: GHC itself links
    # gmp and ncurses, and the project's closure links zlib.
    assert [argv for argv, _cwd, _kind in recorded_commands_fresh_host] == [
        bootstrap.linux_build_library_probe(),
        *bootstrap.linux_build_library_install_commands(),
        ("ghcup", "--version"),
        ("ghcup", "whereis", "ghc", "9.12.4"),
        ("ghcup", "install", "ghc", "9.12.4", "--set"),
        ("ghcup", "whereis", "cabal"),
        ("ghcup", "install", "cabal", "--set"),
        bootstrap.cabal_update_command(),
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
        (str(bootstrap.binary_path(spec, tmp_path)), "--hostbootstrap-install-identity"),
    ]
    assert installed == [LINUX_CPU]
    assert execed == [[str(bootstrap.binary_path(spec, tmp_path)), "play"]]


async def test_bootstrap_apple_fresh_host_installs_homebrew_toolchain(
    monkeypatch: pytest.MonkeyPatch,
    recorded_commands_fresh_host: list[RecordedCommand],
    tmp_path: Path,
) -> None:
    doctored: list[Substrate] = []
    execed: list[list[str]] = []
    _patch_seams(monkeypatch, APPLE, doctored=doctored, execed=execed)

    spec = _project(tmp_path)
    await bootstrap.bootstrap(spec, project_root=tmp_path, args=("--help",))

    assert [argv for argv, _cwd, _kind in recorded_commands_fresh_host] == [
        ("ghcup", "--version"),
        ("brew", "install", "ghcup"),
        ("ghcup", "whereis", "ghc", "9.12.4"),
        ("ghcup", "install", "ghc", "9.12.4", "--set"),
        ("ghcup", "whereis", "cabal"),
        ("ghcup", "install", "cabal", "--set"),
        bootstrap.cabal_update_command(),
        bootstrap.native_build_command(spec, tmp_path),
        bootstrap.native_listbin_command(spec, tmp_path),
        (str(bootstrap.binary_path(spec, tmp_path)), "--hostbootstrap-install-identity"),
    ]
    assert execed == [[str(bootstrap.binary_path(spec, tmp_path)), "--help"]]


async def test_offline_toolchain_refuses_missing_tool_before_install(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def _missing(_probe: tuple[str, ...]) -> bool:
        return False

    async def _unexpected(*_args: object, **_kwargs: object) -> object:
        raise AssertionError("offline toolchain check must not install or download")

    monkeypatch.setattr(bootstrap, "_already_present", _missing)
    monkeypatch.setattr(bootstrap, "_install_verified_ghcup", _unexpected)
    monkeypatch.setattr(bootstrap.process, "run_checked", _unexpected)

    # Linux checks the C libraries first, so that is the refusal it reaches.
    with pytest.raises(
        RuntimeError, match="requires the host C build libraries to be preinstalled"
    ):
        await bootstrap._ensure_toolchain(LINUX_CPU, offline=True)
    # Apple has no apt step, so it reaches the build-tool refusal.
    with pytest.raises(RuntimeError, match="requires the host build tool to be preinstalled"):
        await bootstrap._ensure_toolchain(APPLE, offline=True)


async def test_offline_linux_accepts_preinstalled_build_libraries(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A satisfied host must not be told to preinstall what it already has: the
    # library step is a verified no-op, and the refusal then comes from the
    # build tool it really is missing.
    async def _libraries_only(probe: tuple[str, ...]) -> bool:
        return probe == bootstrap.linux_build_library_probe()

    async def _unexpected(*_args: object, **_kwargs: object) -> object:
        raise AssertionError("offline toolchain check must not install or download")

    monkeypatch.setattr(bootstrap, "_already_present", _libraries_only)
    monkeypatch.setattr(bootstrap, "_install_verified_ghcup", _unexpected)
    monkeypatch.setattr(bootstrap.process, "run_checked", _unexpected)

    with pytest.raises(RuntimeError, match="requires the host build tool to be preinstalled"):
        await bootstrap._ensure_toolchain(LINUX_CPU, offline=True)


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
        error = FileNotFoundError(2, "No such file or directory", "ghcup")
        raise bootstrap.process.CommandError(
            bootstrap.process.CommandUnavailable(tuple(cmd), str(error))
        ) from error

    monkeypatch.setattr(bootstrap.process, "run", _missing)
    assert await bootstrap._already_present(("ghcup", "--version")) is False


def test_toolchain_environment_without_an_existing_path(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.delenv("PATH", raising=False)
    monkeypatch.setattr(bootstrap, "os", SimpleNamespace(**(vars(os) | {"name": "posix"})))
    monkeypatch.setattr(bootstrap.Path, "home", lambda: tmp_path)
    assert bootstrap._toolchain_env()["PATH"] == os.pathsep.join(
        str(tmp_path / directory) for directory in (".ghcup/bin", ".cabal/bin", ".local/bin")
    )


def test_copy_missing_source_preserves_the_installed_binary(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    destination = tmp_path / "destination"
    destination.write_bytes(b"installed")
    with pytest.raises(FileNotFoundError):
        bootstrap._copy_if_changed(tmp_path / "missing", destination)
    assert destination.read_bytes() == b"installed"
    assert list(tmp_path.iterdir()) == [destination]


async def test_already_present_gives_up_after_windows_sharing_violations(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(bootstrap.os, "name", "nt")
    sleeps: list[float] = []

    async def _record_sleep(seconds: float) -> None:
        sleeps.append(seconds)

    monkeypatch.setattr(bootstrap.asyncio, "sleep", _record_sleep)

    async def _busy(cmd: object, **_: object) -> bootstrap.process.CommandResult:
        err = OSError("file is in use by another process")
        err.winerror = 32  # type: ignore[attr-defined]
        raise bootstrap.process.CommandError(
            bootstrap.process.CommandUnavailable(tuple(cmd), str(err))
        ) from err

    monkeypatch.setattr(bootstrap.process, "run", _busy)
    assert await bootstrap._already_present(("ghcup", "--version")) is False
    assert sleeps == [5, 5, 5, 5, 5, 5]


async def test_already_present_reraises_non_sharing_oserror(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(bootstrap.os, "name", "nt")

    async def _boom(cmd: object, **_: object) -> bootstrap.process.CommandResult:
        err = OSError("permission denied")
        err.winerror = 5  # type: ignore[attr-defined]
        raise bootstrap.process.CommandError(
            bootstrap.process.CommandUnavailable(tuple(cmd), str(err))
        ) from err

    monkeypatch.setattr(bootstrap.process, "run", _boom)
    with pytest.raises(bootstrap.process.CommandError, match="permission denied"):
        await bootstrap._already_present(("ghcup", "--version"))


@pytest.mark.parametrize(
    "os_name, legacy, cache, expected",
    [
        ("nt", False, None, "appdata/cabal"),
        ("posix", True, None, ".cabal"),
        ("posix", False, "xdg", "xdg/cabal"),
        ("posix", False, None, ".cache/cabal"),
    ],
)
def test_cabal_index_location_follows_cabal_resolution(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    os_name: str,
    legacy: bool,
    cache: str | None,
    expected: str,
) -> None:
    environment = {"APPDATA": str(tmp_path / "appdata")}
    if cache is not None:
        environment["XDG_CACHE_HOME"] = str(tmp_path / cache)
    if legacy:
        (tmp_path / ".cabal").mkdir()
    monkeypatch.setattr(bootstrap, "os", SimpleNamespace(name=os_name, environ=environment))
    monkeypatch.setattr(bootstrap.Path, "home", lambda: tmp_path)
    assert (
        bootstrap.cabal_index_path()
        == tmp_path / expected / "packages/hackage.haskell.org/01-index.tar"
    )


@pytest.mark.parametrize("driver", [bootstrap.bootstrap, bootstrap.build_binary])
@pytest.mark.parametrize("offline", [False, True])
async def test_driver_threads_offline_and_preserves_build_cwd(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    recorded_commands: list[RecordedCommand],
    driver: object,
    offline: bool,
) -> None:
    _patch_seams(monkeypatch, LINUX_CPU, doctored=[], execed=[])
    monkeypatch.setattr(
        bootstrap, "cabal_index_state", lambda _index: bootstrap.CabalIndexState.STALE
    )
    monkeypatch.setenv("PATH", "parent-path")
    spec = _project(tmp_path)
    await driver(spec, project_root=tmp_path, offline=offline)  # type: ignore[operator]
    expected: list[RecordedCommand] = [
        (
            (
                "dpkg-query",
                "-s",
                "build-essential",
                "libgmp-dev",
                "libncurses-dev",
                "libtinfo-dev",
                "pkg-config",
                "zlib1g-dev",
            ),
            None,
            "probe",
        ),
        (("ghcup", "--version"), None, "probe"),
        (("ghcup", "whereis", "ghc", "9.12.4"), None, "probe"),
        (("ghcup", "whereis", "cabal"), None, "probe"),
    ]
    cabal = r"C:\ghcup\bin\cabal.exe" if os.name == "nt" else "cabal"
    if not offline:
        expected.append(((cabal, "update"), tmp_path, "checked"))
    build_command = (
        cabal,
        "--store-dir",
        str(tmp_path / ".build/cabal-store"),
        "build",
        "-j1",
        *(("--offline",) if offline else ()),
        "exe:demo",
    )
    expected.extend(
        (
            (build_command, tmp_path, "checked"),
            (
                (
                    cabal,
                    "--store-dir",
                    str(tmp_path / ".build/cabal-store"),
                    "list-bin",
                    "exe:demo",
                ),
                tmp_path,
                "checked",
            ),
            (
                (str(bootstrap.binary_path(spec, tmp_path)), "--hostbootstrap-install-identity"),
                tmp_path,
                "checked",
            ),
        )
    )
    assert recorded_commands == expected


async def test_fresh_host_ghc_install_failure_stops_before_build(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    recorded_commands_fresh_host: list[RecordedCommand],
) -> None:
    _patch_seams(monkeypatch, APPLE, doctored=[], execed=[])
    original = bootstrap.process.run_checked
    failure = bootstrap.process.CommandError(
        bootstrap.process.CommandResult(
            ("ghcup", "install", "ghc", "9.12.4", "--set"), 1, "", "install failed"
        )
    )

    async def _checked(
        command: tuple[str, ...], **kwargs: object
    ) -> bootstrap.process.CommandResult:
        if command[:3] == ("ghcup", "install", "ghc"):
            raise failure
        return await original(command, **kwargs)

    monkeypatch.setattr(bootstrap.process, "run_checked", _checked)
    with pytest.raises(bootstrap.process.CommandError) as caught:
        await bootstrap.bootstrap(_project(tmp_path), project_root=tmp_path)
    assert caught.value is failure
    assert recorded_commands_fresh_host == [
        (("ghcup", "--version"), None, "probe"),
        (("brew", "install", "ghcup"), None, "checked"),
        (("ghcup", "whereis", "ghc", "9.12.4"), None, "probe"),
    ]


def test_copy_publishes_a_new_file_and_preserves_an_open_old_handle(tmp_path: Path) -> None:
    source = tmp_path / "source"
    destination = tmp_path / "destination"
    source.write_bytes(b"new binary")
    destination.write_bytes(b"old binary")
    before = destination.stat().st_ino
    if os.name == "nt":
        import ctypes
        import msvcrt
        from ctypes import wintypes

        create = ctypes.windll.kernel32.CreateFileW
        create.argtypes = (
            wintypes.LPCWSTR,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.LPVOID,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.HANDLE,
        )
        create.restype = wintypes.HANDLE
        handle = create(str(destination), 0x80000000, 7, None, 3, 0x80, None)
        assert handle != wintypes.HANDLE(-1).value
        previous = os.fdopen(msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY), "rb")
    else:
        previous = destination.open("rb")
    with previous:
        assert bootstrap._copy_if_changed(source, destination)
        assert previous.read() == b"old binary"
        assert destination.read_bytes() == b"new binary"
        assert destination.stat().st_ino != before
    assert set(tmp_path.iterdir()) == {source, destination}


@pytest.mark.parametrize(
    "rollback, locked_previous", [(False, False), (False, True), (True, False)]
)
def test_windows_busy_binary_is_renamed_before_replacement(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, rollback: bool, locked_previous: bool
) -> None:
    source = tmp_path / "source"
    destination = tmp_path / "destination"
    source.write_bytes(b"new")
    destination.write_bytes(b"old")
    real_replace = os.replace
    calls: list[tuple[Path, Path]] = []

    def _replace(left: Path, right: Path) -> None:
        calls.append((left, right))
        if len(calls) == 1:
            raise PermissionError("running image")
        if len(calls) == 3 and rollback:
            raise OSError("publication failed")
        real_replace(left, right)

    real_unlink = Path.unlink

    def _unlink(path: Path, *args: object, **kwargs: object) -> None:
        if locked_previous and path.suffix == ".previous":
            raise PermissionError("old image is running")
        real_unlink(path, *args, **kwargs)

    monkeypatch.setattr(
        bootstrap, "os", SimpleNamespace(**(vars(os) | {"name": "nt", "replace": _replace}))
    )
    monkeypatch.setattr(Path, "unlink", _unlink)
    if rollback:
        with pytest.raises(OSError, match="publication failed"):
            bootstrap._copy_if_changed(source, destination)
        assert destination.read_bytes() == b"old"
        assert len(calls) == 4
    else:
        assert bootstrap._copy_if_changed(source, destination)
        assert destination.read_bytes() == b"new"
        assert len(calls) == 3
    assert calls[1][0] == destination
    assert calls[1][1].suffix == ".previous"
    if locked_previous:
        assert calls[1][1].read_bytes() == b"old"
        real_unlink(calls[1][1])
    assert sorted(path.name for path in tmp_path.iterdir()) == ["destination", "source"]


@pytest.mark.parametrize("os_name, destination_exists", [("posix", True), ("nt", False)])
def test_copy_permission_refusal_without_a_replaceable_windows_binary_cleans_up(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, os_name: str, destination_exists: bool
) -> None:
    source = tmp_path / "source"
    destination = tmp_path / "destination"
    source.write_bytes(b"new")
    if destination_exists:
        destination.write_bytes(b"old")

    def _replace(_left: Path, _right: Path) -> None:
        raise PermissionError("denied")

    monkeypatch.setattr(
        bootstrap, "os", SimpleNamespace(**(vars(os) | {"name": os_name, "replace": _replace}))
    )
    with pytest.raises(PermissionError, match="denied"):
        bootstrap._copy_if_changed(source, destination)
    assert not any(path.name.startswith(".destination-") for path in tmp_path.iterdir())


@pytest.mark.parametrize(
    "outcome",
    [
        bootstrap.process.CommandResult(("tool",), 1, "", "failed"),
        bootstrap.process.CommandTimedOut(("tool",), 0.1),
    ],
)
async def test_already_present_preserves_a_non_launch_command_error(
    monkeypatch: pytest.MonkeyPatch, outcome: bootstrap.process.CommandOutcome
) -> None:
    failure = bootstrap.process.CommandError(outcome)

    async def _failed(*_args: object, **_kwargs: object) -> bootstrap.process.CommandResult:
        raise failure

    monkeypatch.setattr(bootstrap.process, "run", _failed)
    with pytest.raises(bootstrap.process.CommandError) as caught:
        await bootstrap._already_present(("tool",))
    assert caught.value is failure


async def test_already_present_reads_an_unavailable_outcome_without_an_oserror_cause(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def _unavailable(*_args: object, **_kwargs: object) -> bootstrap.process.CommandResult:
        raise bootstrap.process.CommandError(
            bootstrap.process.CommandUnavailable(("tool",), "missing")
        )

    monkeypatch.setattr(bootstrap.process, "run", _unavailable)
    assert not await bootstrap._already_present(("tool",))
