"""Unit tests for substrate detection."""

from __future__ import annotations

import platform
from collections.abc import Sequence
from pathlib import Path

import pytest

from hostbootstrap import docker_ops, process, substrate
from hostbootstrap.substrate import Arch, SubstrateName


@pytest.mark.parametrize(
    ("machine", "expected"),
    [
        ("x86_64", Arch.AMD64),
        ("amd64", Arch.AMD64),
        ("aarch64", Arch.ARM64),
        ("arm64", Arch.ARM64),
    ],
)
def test_docker_arch_mapping(monkeypatch: pytest.MonkeyPatch, machine: str, expected: Arch) -> None:
    monkeypatch.setattr(platform, "machine", lambda: machine)
    assert substrate._docker_arch() is expected


@pytest.mark.parametrize("spelling", ["x86_64", "amd64", "aarch64", "arm64", "AARCH64", " arm64 "])
def test_one_alias_table_serves_the_host_and_the_docker_engine(
    monkeypatch: pytest.MonkeyPatch, spelling: str
) -> None:
    """Both boundaries read the same table, so neither can drift from the other."""
    monkeypatch.setattr(platform, "machine", lambda: spelling)
    assert substrate._docker_arch() is docker_ops.normalize_architecture(spelling)


def test_invocation_context_states_both_closed_values() -> None:
    detected = substrate.Substrate(SubstrateName.WINDOWS_GPU, Arch.ARM64)
    assert substrate.invocation_context(detected) == {
        substrate.SUBSTRATE_ENV_VAR: "windows-gpu",
        substrate.ARCH_ENV_VAR: "arm64",
    }


def test_parse_arch_returns_none_for_an_unsupported_spelling() -> None:
    assert substrate.parse_arch("s390x") is None


def test_unknown_arch_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(platform, "machine", lambda: "sparc")
    with pytest.raises(RuntimeError):
        substrate._docker_arch()


def test_detect_apple_silicon(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(platform, "system", lambda: "Darwin")
    monkeypatch.setattr(platform, "machine", lambda: "arm64")
    assert substrate.detect() == substrate.Substrate(SubstrateName.APPLE_SILICON, Arch.ARM64)


def test_detect_darwin_intel_rejected(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(platform, "system", lambda: "Darwin")
    monkeypatch.setattr(platform, "machine", lambda: "x86_64")
    with pytest.raises(RuntimeError):
        substrate.detect()


def test_detect_linux_cpu(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(platform, "system", lambda: "Linux")
    monkeypatch.setattr(platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(substrate, "_has_nvidia_gpu", lambda: False)
    assert substrate.detect() == substrate.Substrate(SubstrateName.LINUX_CPU, Arch.AMD64)


def test_detect_linux_gpu(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(platform, "system", lambda: "Linux")
    monkeypatch.setattr(platform, "machine", lambda: "aarch64")
    monkeypatch.setattr(substrate, "_has_nvidia_gpu", lambda: True)
    assert substrate.detect() == substrate.Substrate(SubstrateName.LINUX_GPU, Arch.ARM64)


def test_detect_windows_cpu(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(platform, "system", lambda: "Windows")
    monkeypatch.setattr(platform, "machine", lambda: "AMD64")
    monkeypatch.setattr(substrate, "_has_nvidia_gpu", lambda: False)
    assert substrate.detect() == substrate.Substrate(SubstrateName.WINDOWS_CPU, Arch.AMD64)


def test_detect_windows_gpu(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(platform, "system", lambda: "Windows")
    monkeypatch.setattr(platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(substrate, "_has_nvidia_gpu", lambda: True)
    assert substrate.detect() == substrate.Substrate(SubstrateName.WINDOWS_GPU, Arch.AMD64)


def test_detect_unknown_system(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(platform, "system", lambda: "Plan9")
    with pytest.raises(RuntimeError):
        substrate.detect()


def test_substrate_properties() -> None:
    apple = substrate.Substrate(SubstrateName.APPLE_SILICON, Arch.ARM64)
    gpu = substrate.Substrate(SubstrateName.LINUX_GPU, Arch.AMD64)
    windows_gpu = substrate.Substrate(SubstrateName.WINDOWS_GPU, Arch.AMD64)

    assert apple.is_apple_silicon
    assert not apple.is_linux
    assert gpu.is_linux
    assert gpu.has_gpu
    assert windows_gpu.is_windows
    assert not windows_gpu.is_linux
    assert windows_gpu.has_gpu


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

    def _probe(cmd: Sequence[str], **_: object) -> process.CommandOutcome:
        assert list(cmd) == ["/bin/nvidia-smi", "-L"]
        return process.CommandResult(tuple(cmd), 0, "GPU 0: test\n", "")

    monkeypatch.setattr(substrate.process, "probe", _probe)

    assert substrate._has_nvidia_gpu()


def test_has_nvidia_gpu_handles_nvidia_smi_failure(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setattr(substrate, "_NVIDIA_MARKERS", (tmp_path / "missing",))
    monkeypatch.setattr(substrate.shutil, "which", lambda _cmd: "/bin/nvidia-smi")
    monkeypatch.setattr(
        substrate.process,
        "probe",
        lambda cmd, **_k: process.CommandResult(tuple(cmd), 1, "", ""),
    )
    assert not substrate._has_nvidia_gpu()

    monkeypatch.setattr(
        substrate.process,
        "probe",
        lambda cmd, **_k: process.CommandUnavailable(tuple(cmd), "noexec"),
    )
    assert not substrate._has_nvidia_gpu()
