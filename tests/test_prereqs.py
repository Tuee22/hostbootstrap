"""Unit tests for host prerequisite detection."""

from __future__ import annotations

import plistlib
import subprocess
from pathlib import Path

import pytest

from hostbootstrap import prereqs
from hostbootstrap.spec import BuildSpec, Handoff, HostBinaryModel, HostReqs, ProjectSpec
from hostbootstrap.substrate import Substrate, SubstrateName


def _write_plist(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        plistlib.dump(payload, handle)


def _completed(
    args: list[str],
    *,
    returncode: int = 0,
    stdout: str = "",
) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(args=args, returncode=returncode, stdout=stdout, stderr="")


def _patch_os_release(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    text: str | None,
) -> None:
    real_path = Path
    os_release = tmp_path / "os-release"
    if text is not None:
        os_release.write_text(text, encoding="utf-8")
    elif os_release.exists():
        os_release.unlink()

    def _fake_path(value: str) -> Path:
        if value == "/etc/os-release":
            return os_release
        return real_path(value)

    monkeypatch.setattr(prereqs, "Path", _fake_path)


def _loaded_launchdaemon(
    monkeypatch: pytest.MonkeyPatch,
    *,
    loaded: bool = True,
) -> None:
    def _fake_run(cmd: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        assert cmd[:2] == ["launchctl", "print"]
        if not loaded:
            return _completed(cmd, returncode=1)
        return _completed(cmd, stdout="type = LaunchDaemon\nstate = running\n")

    monkeypatch.setattr(prereqs.subprocess, "run", _fake_run)


def test_have_uses_path_lookup(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs.shutil, "which", lambda cmd: f"/bin/{cmd}")
    assert prereqs._have("docker")

    monkeypatch.setattr(prereqs.shutil, "which", lambda _cmd: None)
    assert not prereqs._have("docker")


def test_colima_canonical_launchdaemon_passes(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _write_plist(
        tmp_path / "com.colima.default.plist",
        {
            "Label": "com.colima.default",
            "RunAtLoad": True,
            "ProgramArguments": ["/opt/homebrew/bin/colima", "start", "-f"],
        },
    )
    monkeypatch.setattr(prereqs, "_LAUNCHD_DIR", tmp_path)
    _loaded_launchdaemon(monkeypatch)

    prereqs._check_colima_launchdaemon()


def test_colima_custom_wrapper_launchdaemon_passes(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    wrapper = tmp_path / "colima-system-start.sh"
    wrapper.write_text(
        "#!/bin/zsh\nexec /opt/homebrew/opt/colima/bin/colima start -f\n",
        encoding="utf-8",
    )
    _write_plist(
        tmp_path / "com.example.colima.plist",
        {
            "Label": "com.example.colima",
            "RunAtLoad": True,
            "ProgramArguments": [str(wrapper)],
            "UserName": "matthewnowak",
        },
    )
    monkeypatch.setattr(prereqs, "_LAUNCHD_DIR", tmp_path)
    _loaded_launchdaemon(monkeypatch)

    prereqs._check_colima_launchdaemon()


def test_colima_launchagent_is_not_accepted(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    launchdaemons = tmp_path / "LaunchDaemons"
    launchagents = tmp_path / "LaunchAgents"
    launchdaemons.mkdir()
    _write_plist(
        launchagents / "com.colima.default.plist",
        {
            "Label": "com.colima.default",
            "RunAtLoad": True,
            "ProgramArguments": ["/opt/homebrew/bin/colima", "start", "-f"],
        },
    )
    monkeypatch.setattr(prereqs, "_LAUNCHD_DIR", launchdaemons)
    _loaded_launchdaemon(monkeypatch)

    with pytest.raises(prereqs.PrereqError, match="system LaunchDaemon"):
        prereqs._check_colima_launchdaemon()


def test_colima_launchdaemon_requires_run_at_load(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _write_plist(
        tmp_path / "com.colima.default.plist",
        {
            "Label": "com.colima.default",
            "RunAtLoad": False,
            "ProgramArguments": ["/opt/homebrew/bin/colima", "start", "-f"],
        },
    )
    monkeypatch.setattr(prereqs, "_LAUNCHD_DIR", tmp_path)
    _loaded_launchdaemon(monkeypatch)

    with pytest.raises(prereqs.PrereqError, match="system LaunchDaemon"):
        prereqs._check_colima_launchdaemon()


def test_colima_launchdaemon_must_be_bootstrapped(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _write_plist(
        tmp_path / "com.colima.default.plist",
        {
            "Label": "com.colima.default",
            "RunAtLoad": True,
            "ProgramArguments": ["/opt/homebrew/bin/colima", "start", "--foreground"],
        },
    )
    monkeypatch.setattr(prereqs, "_LAUNCHD_DIR", tmp_path)
    _loaded_launchdaemon(monkeypatch, loaded=False)

    with pytest.raises(prereqs.PrereqError, match="not bootstrapped"):
        prereqs._check_colima_launchdaemon()


def test_filevault_off_passes(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fake_run(cmd: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        assert cmd == ["/usr/bin/fdesetup", "status"]
        return _completed(cmd, stdout="FileVault is Off.\n")

    monkeypatch.setattr(prereqs.subprocess, "run", _fake_run)

    prereqs._check_filevault_disabled()


def test_filevault_on_fails(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fake_run(cmd: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        assert cmd == ["/usr/bin/fdesetup", "status"]
        return _completed(cmd, stdout="FileVault is On.\n")

    monkeypatch.setattr(prereqs.subprocess, "run", _fake_run)

    with pytest.raises(prereqs.PrereqError, match="FileVault is enabled"):
        prereqs._check_filevault_disabled()


def test_filevault_command_errors(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        prereqs.subprocess,
        "run",
        lambda cmd, **kwargs: _completed(cmd, returncode=2, stdout="bad\n"),
    )
    with pytest.raises(prereqs.PrereqError, match="could not check FileVault"):
        prereqs._check_filevault_disabled()

    monkeypatch.setattr(
        prereqs.subprocess,
        "run",
        lambda cmd, **kwargs: _completed(cmd, stdout="unexpected\n"),
    )
    with pytest.raises(prereqs.PrereqError, match="unrecognized FileVault"):
        prereqs._check_filevault_disabled()

    def _raise(*_args: object, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        raise OSError("noexec")

    monkeypatch.setattr(prereqs.subprocess, "run", _raise)
    with pytest.raises(prereqs.PrereqError, match="could not check FileVault status"):
        prereqs._check_filevault_disabled()


def test_passwordless_sudo_checks(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs.os, "geteuid", lambda: 0)
    prereqs._check_passwordless_sudo()

    monkeypatch.setattr(prereqs.os, "geteuid", lambda: 501)
    monkeypatch.setattr(prereqs, "_have", lambda _cmd: False)
    with pytest.raises(prereqs.PrereqError, match="sudo is required"):
        prereqs._check_passwordless_sudo()

    monkeypatch.setattr(prereqs, "_have", lambda _cmd: True)

    def _raise(*_args: object, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        raise OSError("noexec")

    monkeypatch.setattr(prereqs.subprocess, "run", _raise)
    with pytest.raises(prereqs.PrereqError, match="could not exec sudo"):
        prereqs._check_passwordless_sudo()

    monkeypatch.setattr(
        prereqs.subprocess,
        "run",
        lambda cmd, **kwargs: _completed(cmd, returncode=1),
    )
    with pytest.raises(prereqs.PrereqError, match="passwordless sudo"):
        prereqs._check_passwordless_sudo()

    monkeypatch.setattr(prereqs.subprocess, "run", lambda cmd, **kwargs: _completed(cmd))
    prereqs._check_passwordless_sudo()


def test_docker_socket_checks(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs, "_have", lambda _cmd: False)
    with pytest.raises(prereqs.PrereqError, match="docker CLI"):
        prereqs._check_docker_socket()

    monkeypatch.setattr(prereqs, "_have", lambda _cmd: True)

    def _raise(*_args: object, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        raise OSError("noexec")

    monkeypatch.setattr(prereqs.subprocess, "run", _raise)
    with pytest.raises(prereqs.PrereqError, match="could not exec docker"):
        prereqs._check_docker_socket()

    monkeypatch.setattr(
        prereqs.subprocess,
        "run",
        lambda cmd, **kwargs: _completed(cmd, returncode=1),
    )
    with pytest.raises(prereqs.PrereqError, match="docker daemon"):
        prereqs._check_docker_socket()

    monkeypatch.setattr(prereqs.subprocess, "run", lambda cmd, **kwargs: _completed(cmd))
    prereqs._check_docker_socket()


def test_ubuntu_2404_check(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _patch_os_release(monkeypatch, tmp_path, 'ID="ubuntu"\nVERSION_ID="24.04"\n')
    prereqs._check_ubuntu_2404()

    _patch_os_release(monkeypatch, tmp_path, None)
    with pytest.raises(prereqs.PrereqError, match="cannot read"):
        prereqs._check_ubuntu_2404()

    _patch_os_release(monkeypatch, tmp_path, 'ID="debian"\nVERSION_ID="12"\n')
    with pytest.raises(prereqs.PrereqError, match="Ubuntu 24.04"):
        prereqs._check_ubuntu_2404()


def test_macos_homebrew_and_xcode_checks(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs.platform, "system", lambda: "Linux")
    with pytest.raises(prereqs.PrereqError, match="non-Darwin"):
        prereqs._check_macos_arm64()

    monkeypatch.setattr(prereqs.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(prereqs.platform, "machine", lambda: "x86_64")
    with pytest.raises(prereqs.PrereqError, match="Apple Silicon"):
        prereqs._check_macos_arm64()

    monkeypatch.setattr(prereqs.platform, "machine", lambda: "arm64")
    prereqs._check_macos_arm64()

    monkeypatch.setattr(prereqs, "_have", lambda _cmd: False)
    with pytest.raises(prereqs.PrereqError, match="Homebrew"):
        prereqs._check_homebrew()

    def _raise(*_args: object, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        raise OSError("noexec")

    monkeypatch.setattr(prereqs.subprocess, "run", _raise)
    with pytest.raises(prereqs.PrereqError, match="xcode-select failed"):
        prereqs._check_xcode_clt()

    monkeypatch.setattr(
        prereqs.subprocess,
        "run",
        lambda cmd, **kwargs: _completed(cmd, returncode=1, stdout=""),
    )
    with pytest.raises(prereqs.PrereqError, match="Xcode Command Line Tools"):
        prereqs._check_xcode_clt()

    monkeypatch.setattr(
        prereqs.subprocess,
        "run",
        lambda cmd, **kwargs: _completed(cmd, stdout="/Library/Developer/CommandLineTools\n"),
    )
    prereqs._check_xcode_clt()


def test_plist_and_colima_helpers(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    assert prereqs._plist_mapping(tmp_path / "missing.plist") is None

    invalid = tmp_path / "invalid.plist"
    invalid.write_text("not plist", encoding="utf-8")
    assert prereqs._plist_mapping(invalid) is None

    list_plist = tmp_path / "list.plist"
    with list_plist.open("wb") as handle:
        plistlib.dump(["not", "dict"], handle)
    assert prereqs._plist_mapping(list_plist) is None

    assert prereqs._launchd_argv({"ProgramArguments": ["colima", 5]}) == ()
    assert prereqs._launchd_argv({"Program": "/bin/colima"}) == ("/bin/colima",)
    assert prereqs._launchd_argv({}) == ()
    assert not prereqs._argv_starts_colima_foreground(())
    assert prereqs._argv_starts_colima_foreground(("colima", "start", "--foreground"))
    assert not prereqs._script_starts_colima_foreground(tmp_path / "missing.sh")

    class _Unreadable:
        def is_file(self) -> bool:
            return True

        def read_text(self, **_kwargs: object) -> str:
            raise OSError("unreadable")

    assert not prereqs._script_starts_colima_foreground(_Unreadable())  # type: ignore[arg-type]

    wrapper = tmp_path / "colima-wrapper"
    wrapper.write_text("exec colima start --foreground\n", encoding="utf-8")
    monkeypatch.setattr(prereqs.shutil, "which", lambda _cmd: str(wrapper))
    assert prereqs._plist_starts_colima_foreground({"ProgramArguments": ["colima-wrapper"]})

    monkeypatch.setattr(prereqs.shutil, "which", lambda _cmd: None)
    assert not prereqs._plist_starts_colima_foreground({"ProgramArguments": ["missing-wrapper"]})
    assert not prereqs._plist_starts_colima_foreground({})


def test_colima_launchdaemon_candidate_filtering(tmp_path: Path) -> None:
    assert prereqs._colima_launchdaemon_candidates(tmp_path / "missing") == ()

    (tmp_path / "invalid.plist").write_text("not plist", encoding="utf-8")
    _write_plist(tmp_path / "bad-label.plist", {"Label": 5, "RunAtLoad": True})
    _write_plist(tmp_path / "not-run-at-load.plist", {"Label": "x", "RunAtLoad": False})
    _write_plist(
        tmp_path / "ok.plist",
        {
            "Label": "com.colima.ok",
            "RunAtLoad": True,
            "ProgramArguments": ["/opt/homebrew/bin/colima", "start", "-f"],
        },
    )

    candidates = prereqs._colima_launchdaemon_candidates(tmp_path)
    assert candidates == (
        prereqs.ColimaLaunchDaemon(
            label="com.colima.ok",
            plist=tmp_path / "ok.plist",
        ),
    )


def test_launchdaemon_loaded_handles_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    def _raise(*_args: object, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        raise OSError("noexec")

    monkeypatch.setattr(prereqs.subprocess, "run", _raise)
    assert not prereqs._launchdaemon_loaded("x")

    monkeypatch.setattr(
        prereqs.subprocess,
        "run",
        lambda cmd, **kwargs: _completed(cmd, stdout="type = LaunchAgent\n"),
    )
    assert not prereqs._launchdaemon_loaded("x")


def test_nvidia_runtime_checks(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs, "_have", lambda cmd: False)
    with pytest.raises(prereqs.PrereqError, match="nvidia-smi"):
        prereqs._check_nvidia_runtime()

    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd == "nvidia-smi")
    prereqs._check_nvidia_runtime()

    monkeypatch.setattr(prereqs, "_have", lambda _cmd: True)

    def _raise(*_args: object, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        raise OSError("noexec")

    monkeypatch.setattr(prereqs.subprocess, "run", _raise)
    with pytest.raises(prereqs.PrereqError, match="docker info failed"):
        prereqs._check_nvidia_runtime()

    monkeypatch.setattr(
        prereqs.subprocess,
        "run",
        lambda cmd, **kwargs: _completed(cmd, stdout='{"runc":{}}\n'),
    )
    with pytest.raises(prereqs.PrereqError, match="NVIDIA container toolkit"):
        prereqs._check_nvidia_runtime()

    monkeypatch.setattr(
        prereqs.subprocess,
        "run",
        lambda cmd, **kwargs: _completed(cmd, stdout='{"nvidia":{}}\n'),
    )
    prereqs._check_nvidia_runtime()


async def test_apple_development_mode_skips_prelogin_checks(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    calls: list[str] = []

    monkeypatch.setattr(prereqs, "_check_macos_arm64", lambda: calls.append("macos"))
    monkeypatch.setattr(prereqs, "_check_xcode_clt", lambda: calls.append("xcode"))
    monkeypatch.setattr(prereqs, "_check_passwordless_sudo", lambda: calls.append("sudo"))
    monkeypatch.setattr(prereqs, "_check_homebrew", lambda: calls.append("brew"))
    monkeypatch.setattr(
        prereqs,
        "_check_filevault_disabled",
        lambda: calls.append("filevault"),
    )
    monkeypatch.setattr(
        prereqs,
        "_check_colima_launchdaemon",
        lambda: calls.append("colima-launchdaemon"),
    )
    monkeypatch.setattr(prereqs, "_check_docker_socket", lambda: calls.append("docker"))

    project_spec = ProjectSpec(
        project="p",
        substrates={},
        source_path=tmp_path / "hostbootstrap.dhall",
        development=True,
    )
    result = await prereqs._run_apple(
        project_spec,
        Substrate(SubstrateName.APPLE_SILICON, "arm64"),
    )

    assert calls == ["macos", "xcode", "sudo", "brew", "docker"]
    assert "development mode: skipped FileVault pre-login check" in result.messages
    assert "development mode: skipped Colima system LaunchDaemon check" in result.messages


async def test_apple_production_checks_host_requirements(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    calls: list[str] = []
    for name in [
        "_check_macos_arm64",
        "_check_xcode_clt",
        "_check_passwordless_sudo",
        "_check_homebrew",
        "_check_filevault_disabled",
        "_check_colima_launchdaemon",
        "_check_docker_socket",
    ]:
        monkeypatch.setattr(prereqs, name, lambda name=name: calls.append(name))
    monkeypatch.setattr(prereqs, "_have", lambda _cmd: True)

    project_spec = ProjectSpec(
        project="p",
        substrates={
            SubstrateName.APPLE_SILICON: HostBinaryModel(
                build=BuildSpec("cabal build", HostReqs(ghc=True, tart=True)),
                handoff=Handoff(up=".build/p up", down=".build/p down"),
            )
        },
        source_path=tmp_path / "hostbootstrap.dhall",
    )

    result = await prereqs._run_apple(
        project_spec,
        Substrate(SubstrateName.APPLE_SILICON, "arm64"),
    )

    assert calls == [
        "_check_macos_arm64",
        "_check_xcode_clt",
        "_check_passwordless_sudo",
        "_check_homebrew",
        "_check_filevault_disabled",
        "_check_colima_launchdaemon",
        "_check_docker_socket",
    ]
    assert "FileVault disabled: OK" in result.messages
    assert "Colima system-level LaunchDaemon: OK" in result.messages


async def test_apple_host_requirement_errors(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    for name in [
        "_check_macos_arm64",
        "_check_xcode_clt",
        "_check_passwordless_sudo",
        "_check_homebrew",
        "_check_filevault_disabled",
        "_check_colima_launchdaemon",
        "_check_docker_socket",
    ]:
        monkeypatch.setattr(prereqs, name, lambda: None)

    project_spec = ProjectSpec(
        project="p",
        substrates={
            SubstrateName.APPLE_SILICON: HostBinaryModel(
                build=BuildSpec("cabal build", HostReqs(ghc=True, tart=True)),
                handoff=Handoff(up=".build/p up", down=".build/p down"),
            )
        },
        source_path=tmp_path / "hostbootstrap.dhall",
    )
    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd != "tart")
    with pytest.raises(prereqs.PrereqError, match="requires Tart"):
        await prereqs._run_apple(project_spec, Substrate(SubstrateName.APPLE_SILICON, "arm64"))

    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd != "ghcup")
    with pytest.raises(prereqs.PrereqError, match="requires GHC"):
        await prereqs._run_apple(project_spec, Substrate(SubstrateName.APPLE_SILICON, "arm64"))


async def test_linux_doctor_cpu_and_gpu(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    calls: list[str] = []
    monkeypatch.setattr(prereqs, "_check_ubuntu_2404", lambda: calls.append("ubuntu"))
    monkeypatch.setattr(prereqs, "_check_passwordless_sudo", lambda: calls.append("sudo"))
    monkeypatch.setattr(prereqs, "_check_docker_socket", lambda: calls.append("docker"))
    monkeypatch.setattr(prereqs, "_check_nvidia_runtime", lambda: calls.append("nvidia"))
    project_spec = ProjectSpec(
        project="p", substrates={}, source_path=tmp_path / "hostbootstrap.dhall"
    )

    cpu = await prereqs.run_doctor(project_spec, Substrate(SubstrateName.LINUX_CPU, "amd64"))
    gpu = await prereqs.run_doctor(project_spec, Substrate(SubstrateName.LINUX_GPU, "amd64"))

    assert cpu.messages == (
        "Ubuntu 24.04: OK",
        "passwordless sudo: OK",
        "Docker daemon reachable: OK",
    )
    assert "NVIDIA container runtime: OK" in gpu.messages
    assert calls == ["ubuntu", "sudo", "docker", "ubuntu", "sudo", "docker", "nvidia"]


def test_run_doctor_sync(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    expected = prereqs.DoctorResult(Substrate(SubstrateName.LINUX_CPU, "amd64"), ("ok",))

    async def _fake_run_doctor(
        _spec: ProjectSpec,
        _substrate: Substrate,
    ) -> prereqs.DoctorResult:
        return expected

    monkeypatch.setattr(prereqs, "run_doctor", _fake_run_doctor)

    result = prereqs.run_doctor_sync(
        ProjectSpec(project="p", substrates={}, source_path=tmp_path / "hostbootstrap.dhall"),
        Substrate(SubstrateName.LINUX_CPU, "amd64"),
    )
    assert result is expected


async def test_run_doctor_dispatches_apple(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    expected = prereqs.DoctorResult(Substrate(SubstrateName.APPLE_SILICON, "arm64"), ("apple",))

    async def _fake_apple(
        _spec: ProjectSpec,
        _substrate: Substrate,
    ) -> prereqs.DoctorResult:
        return expected

    monkeypatch.setattr(prereqs, "_run_apple", _fake_apple)

    result = await prereqs.run_doctor(
        ProjectSpec(project="p", substrates={}, source_path=tmp_path / "hostbootstrap.dhall"),
        Substrate(SubstrateName.APPLE_SILICON, "arm64"),
    )
    assert result is expected
