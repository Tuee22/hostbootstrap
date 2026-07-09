"""Unit tests for the fail-fast host minimums (substrate-only dispatch)."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from hostbootstrap import prereqs
from hostbootstrap.substrate import Substrate, SubstrateName


def _completed(
    args: list[str],
    *,
    returncode: int = 0,
    stdout: str = "",
    stderr: str = "",
) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(
        args=args, returncode=returncode, stdout=stdout, stderr=stderr
    )


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


def test_have_uses_path_lookup(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs.shutil, "which", lambda cmd: f"/bin/{cmd}")
    assert prereqs._have("docker")

    monkeypatch.setattr(prereqs.shutil, "which", lambda _cmd: None)
    assert not prereqs._have("docker")


def test_passwordless_sudo_checks(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs.os, "geteuid", lambda: 0, raising=False)
    prereqs._check_passwordless_sudo()

    monkeypatch.setattr(prereqs.os, "geteuid", lambda: 501, raising=False)
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


def test_ubuntu_check(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _patch_os_release(monkeypatch, tmp_path, 'ID="ubuntu"\nVERSION_ID="24.04"\n')
    prereqs._check_ubuntu_2404()

    _patch_os_release(monkeypatch, tmp_path, 'ID="debian"\nVERSION_ID="12"\n')
    with pytest.raises(prereqs.PrereqError, match="Ubuntu 24.04"):
        prereqs._check_ubuntu_2404()

    _patch_os_release(monkeypatch, tmp_path, None)
    with pytest.raises(prereqs.PrereqError, match="cannot read"):
        prereqs._check_ubuntu_2404()


def test_macos_checks(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(prereqs.platform, "machine", lambda: "arm64")
    prereqs._check_macos_arm64()

    monkeypatch.setattr(prereqs.platform, "machine", lambda: "x86_64")
    with pytest.raises(prereqs.PrereqError, match="Apple Silicon"):
        prereqs._check_macos_arm64()

    monkeypatch.setattr(prereqs.platform, "system", lambda: "Linux")
    with pytest.raises(prereqs.PrereqError, match="non-Darwin"):
        prereqs._check_macos_arm64()


def test_xcode_clt_check(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        prereqs.subprocess,
        "run",
        lambda cmd, **kwargs: _completed(cmd, stdout="/Library/Developer/CommandLineTools\n"),
    )
    prereqs._check_xcode_clt()

    monkeypatch.setattr(
        prereqs.subprocess,
        "run",
        lambda cmd, **kwargs: _completed(cmd, returncode=1),
    )
    with pytest.raises(prereqs.PrereqError, match="Xcode"):
        prereqs._check_xcode_clt()

    def _raise(*_args: object, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        raise OSError("noexec")

    monkeypatch.setattr(prereqs.subprocess, "run", _raise)
    with pytest.raises(prereqs.PrereqError, match="xcode-select failed"):
        prereqs._check_xcode_clt()


def test_homebrew_check(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd == "brew")
    prereqs._check_homebrew()

    monkeypatch.setattr(prereqs, "_have", lambda _cmd: False)
    with pytest.raises(prereqs.PrereqError, match="Homebrew"):
        prereqs._check_homebrew()


def test_nvidia_runtime(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd in {"nvidia-smi", "docker"})
    monkeypatch.setattr(
        prereqs.subprocess,
        "run",
        lambda cmd, **kwargs: _completed(cmd, stdout='{"runc":{},"nvidia":{}}\n'),
    )
    prereqs._check_nvidia_runtime()

    monkeypatch.setattr(prereqs, "_have", lambda _cmd: False)
    with pytest.raises(prereqs.PrereqError, match="nvidia-smi"):
        prereqs._check_nvidia_runtime()

    # nvidia-smi present but docker absent: short-circuit, no runtime probe.
    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd == "nvidia-smi")
    prereqs._check_nvidia_runtime()

    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd in {"nvidia-smi", "docker"})

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


def test_winget_check(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd == "winget")
    prereqs._check_winget()

    monkeypatch.setattr(prereqs, "_have", lambda _cmd: False)
    with pytest.raises(prereqs.PrereqError, match="winget"):
        prereqs._check_winget()


def test_powershell_check(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd == "powershell")
    prereqs._check_powershell()

    monkeypatch.setattr(prereqs, "_have", lambda _cmd: False)
    with pytest.raises(prereqs.PrereqError, match="PowerShell"):
        prereqs._check_powershell()


def test_hardware_virtualization_check(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    kvm = tmp_path / "kvm"
    kvm.write_bytes(b"")
    monkeypatch.setattr(
        prereqs, "Path", lambda value: kvm if value == "/dev/kvm" else Path(value)
    )

    # present + read/write -> OK
    monkeypatch.setattr(prereqs.os, "access", lambda _p, _mode: True)
    prereqs._check_hardware_virtualization()

    # present but not accessible -> group-membership hint
    monkeypatch.setattr(prereqs.os, "access", lambda _p, _mode: False)
    with pytest.raises(prereqs.PrereqError, match="not read/write"):
        prereqs._check_hardware_virtualization()

    # absent -> firmware/kvm-module hint
    missing = tmp_path / "absent"
    monkeypatch.setattr(
        prereqs, "Path", lambda value: missing if value == "/dev/kvm" else Path(value)
    )
    with pytest.raises(prereqs.PrereqError, match="/dev/kvm not found"):
        prereqs._check_hardware_virtualization()


async def test_run_linux_cpu_minimums(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[str] = []
    monkeypatch.setattr(prereqs, "_check_ubuntu_2404", lambda: calls.append("ubuntu"))
    monkeypatch.setattr(prereqs, "_check_passwordless_sudo", lambda: calls.append("sudo"))
    monkeypatch.setattr(prereqs, "_check_hardware_virtualization", lambda: calls.append("kvm"))
    monkeypatch.setattr(prereqs, "_check_nvidia_runtime", lambda: calls.append("nvidia"))

    result = await prereqs._run_linux(Substrate(SubstrateName.LINUX_CPU, "amd64"))

    assert calls == ["ubuntu", "sudo", "kvm"]
    assert result.messages == (
        "Ubuntu 24.04: OK",
        "passwordless sudo: OK",
        "hardware virtualization (/dev/kvm): OK",
    )


async def test_run_linux_build_minimums_omit_kvm(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[str] = []
    monkeypatch.setattr(prereqs, "_check_ubuntu_2404", lambda: calls.append("ubuntu"))
    monkeypatch.setattr(prereqs, "_check_passwordless_sudo", lambda: calls.append("sudo"))
    monkeypatch.setattr(prereqs, "_check_hardware_virtualization", lambda: calls.append("kvm"))
    monkeypatch.setattr(prereqs, "_check_nvidia_runtime", lambda: calls.append("nvidia"))

    result = await prereqs.run_build_doctor(Substrate(SubstrateName.LINUX_CPU, "amd64"))

    assert calls == ["ubuntu", "sudo"]
    assert result.messages == (
        "Ubuntu 24.04: OK",
        "passwordless sudo: OK",
    )


async def test_run_linux_gpu_build_minimums_omit_kvm_and_nvidia(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[str] = []
    monkeypatch.setattr(prereqs, "_check_ubuntu_2404", lambda: calls.append("ubuntu"))
    monkeypatch.setattr(prereqs, "_check_passwordless_sudo", lambda: calls.append("sudo"))
    monkeypatch.setattr(prereqs, "_check_hardware_virtualization", lambda: calls.append("kvm"))
    monkeypatch.setattr(prereqs, "_check_nvidia_runtime", lambda: calls.append("nvidia"))

    result = await prereqs.run_build_doctor(Substrate(SubstrateName.LINUX_GPU, "amd64"))

    assert calls == ["ubuntu", "sudo"]
    assert result.messages == (
        "Ubuntu 24.04: OK",
        "passwordless sudo: OK",
    )


async def test_run_linux_gpu_checks_nvidia_runtime(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[str] = []
    monkeypatch.setattr(prereqs, "_check_ubuntu_2404", lambda: calls.append("ubuntu"))
    monkeypatch.setattr(prereqs, "_check_passwordless_sudo", lambda: calls.append("sudo"))
    monkeypatch.setattr(prereqs, "_check_hardware_virtualization", lambda: calls.append("kvm"))
    monkeypatch.setattr(prereqs, "_check_nvidia_runtime", lambda: calls.append("nvidia"))

    result = await prereqs._run_linux(Substrate(SubstrateName.LINUX_GPU, "amd64"))

    assert calls == ["ubuntu", "sudo", "kvm", "nvidia"]
    assert "NVIDIA container runtime: OK" in result.messages


async def test_run_apple_minimums(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[str] = []
    monkeypatch.setattr(prereqs, "_check_macos_arm64", lambda: calls.append("mac"))
    monkeypatch.setattr(prereqs, "_check_xcode_clt", lambda: calls.append("xcode"))
    monkeypatch.setattr(prereqs, "_check_passwordless_sudo", lambda: calls.append("sudo"))
    monkeypatch.setattr(prereqs, "_check_homebrew", lambda: calls.append("brew"))

    result = await prereqs._run_apple(Substrate(SubstrateName.APPLE_SILICON, "arm64"))

    assert calls == ["mac", "xcode", "sudo", "brew"]
    assert result.messages == (
        "macOS arm64: OK",
        "Xcode Command Line Tools: OK",
        "passwordless sudo: OK",
        "Homebrew: OK",
    )


async def test_run_windows_minimums(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[str] = []
    monkeypatch.setattr(prereqs, "_check_winget", lambda: calls.append("winget"))
    monkeypatch.setattr(prereqs, "_check_powershell", lambda: calls.append("powershell"))

    result = await prereqs._run_windows(Substrate(SubstrateName.WINDOWS_CPU, "amd64"))

    assert calls == ["winget", "powershell"]
    assert result.messages == ("winget: OK", "PowerShell: OK")
    assert not result.reboot_required


async def test_run_doctor_dispatches_by_substrate(monkeypatch: pytest.MonkeyPatch) -> None:
    linux = Substrate(SubstrateName.LINUX_CPU, "amd64")
    apple = Substrate(SubstrateName.APPLE_SILICON, "arm64")
    windows = Substrate(SubstrateName.WINDOWS_CPU, "amd64")
    calls: list[str] = []

    async def _linux(_sub: Substrate) -> prereqs.DoctorResult:
        calls.append("linux")
        return prereqs.DoctorResult(linux, ("linux",))

    async def _apple(_sub: Substrate) -> prereqs.DoctorResult:
        calls.append("apple")
        return prereqs.DoctorResult(apple, ("apple",))

    async def _windows(_sub: Substrate) -> prereqs.DoctorResult:
        calls.append("windows")
        return prereqs.DoctorResult(windows, ("windows",))

    monkeypatch.setattr(prereqs, "_run_linux", _linux)
    monkeypatch.setattr(prereqs, "_run_apple", _apple)
    monkeypatch.setattr(prereqs, "_run_windows", _windows)

    assert (await prereqs.run_doctor(linux)).messages == ("linux",)
    assert (await prereqs.run_doctor(apple)).messages == ("apple",)
    assert (await prereqs.run_doctor(windows)).messages == ("windows",)
    assert calls == ["linux", "apple", "windows"]


async def test_run_build_doctor_dispatches_by_substrate(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    linux = Substrate(SubstrateName.LINUX_CPU, "amd64")
    apple = Substrate(SubstrateName.APPLE_SILICON, "arm64")
    windows = Substrate(SubstrateName.WINDOWS_CPU, "amd64")
    calls: list[str] = []

    async def _linux_build(_sub: Substrate) -> prereqs.DoctorResult:
        calls.append("linux-build")
        return prereqs.DoctorResult(linux, ("linux-build",))

    async def _linux_runtime(_sub: Substrate) -> prereqs.DoctorResult:
        calls.append("linux-runtime")
        return prereqs.DoctorResult(linux, ("linux-runtime",))

    async def _apple(_sub: Substrate) -> prereqs.DoctorResult:
        calls.append("apple")
        return prereqs.DoctorResult(apple, ("apple",))

    async def _windows(_sub: Substrate) -> prereqs.DoctorResult:
        calls.append("windows")
        return prereqs.DoctorResult(windows, ("windows",))

    monkeypatch.setattr(prereqs, "_run_linux_build", _linux_build)
    monkeypatch.setattr(prereqs, "_run_linux", _linux_runtime)
    monkeypatch.setattr(prereqs, "_run_apple", _apple)
    monkeypatch.setattr(prereqs, "_run_windows", _windows)

    assert (await prereqs.run_build_doctor(linux)).messages == ("linux-build",)
    assert (await prereqs.run_build_doctor(apple)).messages == ("apple",)
    assert (await prereqs.run_build_doctor(windows)).messages == ("windows",)
    assert calls == ["linux-build", "apple", "windows"]


def test_run_doctor_sync_wraps_async(monkeypatch: pytest.MonkeyPatch) -> None:
    linux = Substrate(SubstrateName.LINUX_CPU, "amd64")

    async def _linux(_sub: Substrate) -> prereqs.DoctorResult:
        return prereqs.DoctorResult(linux, ("ok",))

    monkeypatch.setattr(prereqs, "_run_linux", _linux)
    assert prereqs.run_doctor_sync(linux).messages == ("ok",)
