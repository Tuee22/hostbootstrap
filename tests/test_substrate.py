"""Unit tests for substrate detection."""

from __future__ import annotations

import platform
import subprocess
from pathlib import Path

import pytest

from hostbootstrap import substrate
from hostbootstrap.substrate import SubstrateName


@pytest.mark.parametrize(
    ("machine", "expected"),
    [("x86_64", "amd64"), ("amd64", "amd64"), ("aarch64", "arm64"), ("arm64", "arm64")],
)
def test_docker_arch_mapping(monkeypatch: pytest.MonkeyPatch, machine: str, expected: str) -> None:
    monkeypatch.setattr(platform, "machine", lambda: machine)
    assert substrate._docker_arch() == expected


def test_unknown_arch_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(platform, "machine", lambda: "sparc")
    with pytest.raises(RuntimeError):
        substrate._docker_arch()


def test_detect_apple_silicon(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(platform, "system", lambda: "Darwin")
    monkeypatch.setattr(platform, "machine", lambda: "arm64")
    assert substrate.detect() == substrate.Substrate(SubstrateName.APPLE_SILICON, "arm64")


def test_detect_darwin_intel_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(platform, "system", lambda: "Darwin")
    monkeypatch.setattr(platform, "machine", lambda: "x86_64")
    with pytest.raises(RuntimeError):
        substrate.detect()


def test_detect_linux_cpu(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(platform, "system", lambda: "Linux")
    monkeypatch.setattr(platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(substrate, "_has_nvidia_gpu", lambda: False)
    assert substrate.detect() == substrate.Substrate(SubstrateName.LINUX_CPU, "amd64")


def test_detect_linux_gpu(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(platform, "system", lambda: "Linux")
    monkeypatch.setattr(platform, "machine", lambda: "aarch64")
    monkeypatch.setattr(substrate, "_has_nvidia_gpu", lambda: True)
    assert substrate.detect() == substrate.Substrate(SubstrateName.LINUX_GPU, "arm64")


def test_detect_unknown_system(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(platform, "system", lambda: "Plan9")
    with pytest.raises(RuntimeError):
        substrate.detect()


def test_substrate_properties() -> None:
    apple = substrate.Substrate(SubstrateName.APPLE_SILICON, "arm64")
    gpu = substrate.Substrate(SubstrateName.LINUX_GPU, "amd64")

    assert apple.is_apple_silicon
    assert not apple.is_linux
    assert gpu.is_linux
    assert gpu.has_gpu


def test_has_nvidia_gpu_from_marker(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    marker = tmp_path / "version"
    marker.touch()
    monkeypatch.setattr(substrate, "_NVIDIA_MARKERS", (marker,))

    assert substrate._has_nvidia_gpu()


def test_has_nvidia_gpu_false_without_marker_or_smi(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setattr(substrate, "_NVIDIA_MARKERS", (tmp_path / "missing",))
    monkeypatch.setattr(substrate.shutil, "which", lambda _cmd: None)

    assert not substrate._has_nvidia_gpu()


def test_has_nvidia_gpu_from_nvidia_smi(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setattr(substrate, "_NVIDIA_MARKERS", (tmp_path / "missing",))
    monkeypatch.setattr(substrate.shutil, "which", lambda _cmd: "/bin/nvidia-smi")

    def _fake_run(cmd: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        assert cmd == ["/bin/nvidia-smi", "-L"]
        return subprocess.CompletedProcess(cmd, 0, stdout="GPU 0: test\n", stderr="")

    monkeypatch.setattr(substrate.subprocess, "run", _fake_run)

    assert substrate._has_nvidia_gpu()


def test_has_nvidia_gpu_handles_nvidia_smi_failure(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setattr(substrate, "_NVIDIA_MARKERS", (tmp_path / "missing",))
    monkeypatch.setattr(substrate.shutil, "which", lambda _cmd: "/bin/nvidia-smi")
    monkeypatch.setattr(
        substrate.subprocess,
        "run",
        lambda cmd, **kwargs: subprocess.CompletedProcess(cmd, 1, stdout="", stderr=""),
    )
    assert not substrate._has_nvidia_gpu()

    def _raise(*_args: object, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        raise OSError("noexec")

    monkeypatch.setattr(substrate.subprocess, "run", _raise)
    assert not substrate._has_nvidia_gpu()
