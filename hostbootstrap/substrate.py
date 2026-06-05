"""Substrate detection.

Three frozen models — *apple-silicon*, *linux-cpu*, *linux-gpu* — match the
three substrates downstream projects target. Detection is pure: it reads the
platform and a small set of files (``/proc/driver/nvidia/version`` etc.) and
returns one frozen value. No side effects.
"""

from __future__ import annotations

import platform
import shutil
import subprocess
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Final


class SubstrateName(StrEnum):
    APPLE_SILICON = "apple-silicon"
    LINUX_CPU = "linux-cpu"
    LINUX_GPU = "linux-gpu"


class Accel(StrEnum):
    """A workload's hardware-acceleration requirement.

    A project declares an ``Accel`` per target; the host is detected and the
    requirement is matched against what the host can provide (see
    :data:`_CAPABILITIES`). ``Cpu`` needs no acceleration and is satisfied by
    every host; ``Cuda`` needs an NVIDIA host; ``Metal`` needs Apple silicon.
    """

    CPU = "cpu"
    CUDA = "cuda"
    METAL = "metal"


# How specific each accel is. A host provides at most one accelerator, so among
# the targets a host can satisfy there is at most one non-``Cpu`` — the resolver
# prefers it (the accelerated path) over the always-available ``Cpu`` fallback.
_ACCEL_SPECIFICITY: Final[dict[Accel, int]] = {
    Accel.CPU: 0,
    Accel.CUDA: 1,
    Accel.METAL: 1,
}


def accel_specificity(accel: Accel) -> int:
    return _ACCEL_SPECIFICITY[accel]


# Capability subsumption: which acceleration requirements each detected host can
# satisfy. This is the single source of truth that makes a ``Cpu`` target
# portable across every host and an accelerated target bound to its hardware.
_CAPABILITIES: Final[dict[SubstrateName, frozenset[Accel]]] = {
    SubstrateName.APPLE_SILICON: frozenset({Accel.CPU, Accel.METAL}),
    SubstrateName.LINUX_CPU: frozenset({Accel.CPU}),
    SubstrateName.LINUX_GPU: frozenset({Accel.CPU, Accel.CUDA}),
}


@dataclass(frozen=True)
class Substrate:
    """The detected host substrate.

    ``arch`` is the Docker-style architecture (``amd64`` / ``arm64``). For
    apple-silicon it is always ``arm64``.
    """

    name: SubstrateName
    arch: str

    @property
    def is_apple_silicon(self) -> bool:
        return self.name is SubstrateName.APPLE_SILICON

    @property
    def is_linux(self) -> bool:
        return self.name in {SubstrateName.LINUX_CPU, SubstrateName.LINUX_GPU}

    @property
    def has_gpu(self) -> bool:
        return self.name is SubstrateName.LINUX_GPU

    @property
    def capabilities(self) -> frozenset[Accel]:
        """The acceleration requirements this host can satisfy."""
        return _CAPABILITIES[self.name]


_DOCKER_ARCH: Final[dict[str, str]] = {
    "x86_64": "amd64",
    "amd64": "amd64",
    "aarch64": "arm64",
    "arm64": "arm64",
}

_NVIDIA_MARKERS: Final[tuple[Path, ...]] = (
    Path("/proc/driver/nvidia/version"),
    Path("/dev/nvidiactl"),
)


def _docker_arch() -> str:
    raw = platform.machine().lower()
    if raw not in _DOCKER_ARCH:
        raise RuntimeError(f"unsupported host architecture: {raw}")
    return _DOCKER_ARCH[raw]


def _has_nvidia_gpu() -> bool:
    if any(marker.exists() for marker in _NVIDIA_MARKERS):
        return True
    nvidia_smi = shutil.which("nvidia-smi")
    if nvidia_smi is None:
        return False
    try:
        result = subprocess.run(
            [nvidia_smi, "-L"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0 and "GPU" in result.stdout


def detect() -> Substrate:
    system = platform.system()
    if system == "Darwin":
        arch = _docker_arch()
        if arch != "arm64":
            raise RuntimeError(
                "hostbootstrap only supports Apple Silicon (arm64) on macOS; "
                f"detected arch={arch!r}"
            )
        return Substrate(SubstrateName.APPLE_SILICON, arch)
    if system == "Linux":
        arch = _docker_arch()
        if _has_nvidia_gpu():
            return Substrate(SubstrateName.LINUX_GPU, arch)
        return Substrate(SubstrateName.LINUX_CPU, arch)
    raise RuntimeError(f"unsupported host platform: {system}")
