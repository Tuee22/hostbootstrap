"""Unit tests for host prerequisite detection."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from hostbootstrap import prereqs
from hostbootstrap.spec import (
    ContainerModel,
    HostBinaryModel,
    HostDaemonModel,
    Lifecycle,
    ProjectSpec,
    ResolvedTarget,
    TargetSpec,
)
from hostbootstrap.substrate import Substrate, SubstrateName

_CPU_CONTAINER = ContainerModel(dockerfile=Path("d"), mounts=())


def _project(model: object) -> ProjectSpec:
    return ProjectSpec(
        project="p",
        targets={SubstrateName.LINUX_CPU: TargetSpec(Lifecycle.CLUSTER, model)},  # type: ignore[arg-type]
        source_path=Path("hostbootstrap.dhall"),
    )


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


def test_have_uses_path_lookup(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs.shutil, "which", lambda cmd: f"/bin/{cmd}")
    assert prereqs._have("docker")

    monkeypatch.setattr(prereqs.shutil, "which", lambda _cmd: None)
    assert not prereqs._have("docker")


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
    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd == "docker")
    monkeypatch.setattr(prereqs.subprocess, "run", lambda cmd, **kwargs: _completed(cmd))
    prereqs._check_docker_socket()

    monkeypatch.setattr(prereqs, "_have", lambda _cmd: False)
    with pytest.raises(prereqs.PrereqError, match="docker CLI"):
        prereqs._check_docker_socket()

    monkeypatch.setattr(prereqs, "_have", lambda _cmd: True)
    monkeypatch.setattr(
        prereqs.subprocess,
        "run",
        lambda cmd, **kwargs: _completed(cmd, returncode=1),
    )
    with pytest.raises(prereqs.PrereqError, match="not reachable"):
        prereqs._check_docker_socket()


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

    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd in {"nvidia-smi", "docker"})
    monkeypatch.setattr(
        prereqs.subprocess,
        "run",
        lambda cmd, **kwargs: _completed(cmd, stdout='{"runc":{}}\n'),
    )
    with pytest.raises(prereqs.PrereqError, match="NVIDIA container toolkit"):
        prereqs._check_nvidia_runtime()


async def test_run_linux_doctor_checks_gpu_runtime(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[str] = []
    monkeypatch.setattr(prereqs, "_check_ubuntu_2404", lambda: calls.append("ubuntu"))
    monkeypatch.setattr(prereqs, "_check_passwordless_sudo", lambda: calls.append("sudo"))
    monkeypatch.setattr(prereqs, "_check_docker_socket", lambda: calls.append("docker"))
    monkeypatch.setattr(prereqs, "_check_nvidia_runtime", lambda: calls.append("nvidia"))

    result = await prereqs._run_linux(
        Substrate(SubstrateName.LINUX_GPU, "amd64"),
        ResolvedTarget(SubstrateName.LINUX_GPU, Lifecycle.CLUSTER, _CPU_CONTAINER),
    )

    assert calls == ["ubuntu", "sudo", "docker", "nvidia"]
    assert "NVIDIA container runtime: OK" in result.messages


async def test_run_apple_doctor_requires_ghcup_for_host_binary(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    calls: list[str] = []
    monkeypatch.setattr(prereqs, "_check_macos_arm64", lambda: calls.append("mac"))
    monkeypatch.setattr(prereqs, "_check_xcode_clt", lambda: calls.append("xcode"))
    monkeypatch.setattr(prereqs, "_check_passwordless_sudo", lambda: calls.append("sudo"))
    monkeypatch.setattr(prereqs, "_check_homebrew", lambda: calls.append("brew"))
    monkeypatch.setattr(prereqs, "_check_docker_socket", lambda: calls.append("docker"))
    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd != "ghcup")

    with pytest.raises(prereqs.PrereqError, match="GHC"):
        await prereqs._run_apple(
            Substrate(SubstrateName.APPLE_SILICON, "arm64"),
            ResolvedTarget(SubstrateName.APPLE_SILICON, Lifecycle.CLUSTER, HostBinaryModel()),
        )

    monkeypatch.setattr(prereqs, "_have", lambda _cmd: True)
    result = await prereqs._run_apple(
        Substrate(SubstrateName.APPLE_SILICON, "arm64"),
        ResolvedTarget(SubstrateName.APPLE_SILICON, Lifecycle.CLUSTER, HostDaemonModel("serve")),
    )
    assert calls[:5] == ["mac", "xcode", "sudo", "brew", "docker"]
    assert "Docker daemon reachable: OK" in result.messages


async def test_run_doctor_dispatches_by_substrate(monkeypatch: pytest.MonkeyPatch) -> None:
    project = _project(_CPU_CONTAINER)
    linux = Substrate(SubstrateName.LINUX_CPU, "amd64")
    apple = Substrate(SubstrateName.APPLE_SILICON, "arm64")
    apple_project = ProjectSpec(
        project="p",
        targets={SubstrateName.APPLE_SILICON: TargetSpec(Lifecycle.CLUSTER, HostDaemonModel("serve"))},
        source_path=Path("hostbootstrap.dhall"),
    )
    calls: list[str] = []

    async def _linux(_sub: Substrate, _resolved: ResolvedTarget) -> prereqs.DoctorResult:
        calls.append("linux")
        return prereqs.DoctorResult(linux, ("linux",))

    async def _apple(_sub: Substrate, _resolved: ResolvedTarget) -> prereqs.DoctorResult:
        calls.append("apple")
        return prereqs.DoctorResult(apple, ("apple",))

    monkeypatch.setattr(prereqs, "_run_linux", _linux)
    monkeypatch.setattr(prereqs, "_run_apple", _apple)

    assert (await prereqs.run_doctor(project, linux)).messages == ("linux",)
    assert (await prereqs.run_doctor(apple_project, apple)).messages == ("apple",)
    assert calls == ["linux", "apple"]
