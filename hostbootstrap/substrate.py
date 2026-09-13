"""Outer-host realization detection.

Frozen values describe the host detected at runtime so the bootstrapper can
select the provider that realizes the universal ``linux-cpu`` project
substrate. They are provider-dispatch facts, not competing project execution
contracts; projects do not declare a host matrix in the Python bootstrapper.
Detection reads the platform and a small set of files
(``/proc/driver/nvidia/version`` etc.), falling back to an ``nvidia-smi -L``
command probe when those markers are absent, and returns one frozen value.
It does not mutate host state.
"""

from __future__ import annotations

import platform
import shutil
from collections.abc import Mapping
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Final

from . import process


class Arch(StrEnum):
    """The Docker-style architecture vocabulary the bootstrapper speaks."""

    AMD64 = "amd64"
    ARM64 = "arm64"


class SubstrateName(StrEnum):
    APPLE_SILICON = "apple-silicon"
    LINUX_CPU = "linux-cpu"
    LINUX_GPU = "linux-gpu"
    WINDOWS_CPU = "windows-cpu"
    WINDOWS_GPU = "windows-gpu"


@dataclass(frozen=True)
class Substrate:
    """The detected outer-host realization.

    ``arch`` is the Docker-style architecture. For apple-silicon it is always
    :data:`Arch.ARM64`.
    """

    name: SubstrateName
    arch: Arch

    @property
    def is_apple_silicon(self) -> bool:
        return self.name is SubstrateName.APPLE_SILICON

    @property
    def is_linux(self) -> bool:
        return self.name in {SubstrateName.LINUX_CPU, SubstrateName.LINUX_GPU}

    @property
    def is_windows(self) -> bool:
        return self.name in {SubstrateName.WINDOWS_CPU, SubstrateName.WINDOWS_GPU}

    @property
    def has_gpu(self) -> bool:
        return self.name in {SubstrateName.LINUX_GPU, SubstrateName.WINDOWS_GPU}


# The one alias table. Every machine string, Docker `info` answer, and operator
# `--arch` flag enters the vocabulary through it and is an `Arch` afterwards.
_ARCH_ALIASES: Final[Mapping[str, Arch]] = {
    "x86_64": Arch.AMD64,
    "amd64": Arch.AMD64,
    "aarch64": Arch.ARM64,
    "arm64": Arch.ARM64,
}

_NVIDIA_MARKERS: Final[tuple[Path, ...]] = (
    Path("/proc/driver/nvidia/version"),
    Path("/dev/nvidiactl"),
)


def parse_arch(value: str) -> Arch | None:
    """Map one architecture spelling onto the closed value, or ``None``."""
    return _ARCH_ALIASES.get(value.strip().lower())


def _docker_arch() -> Arch:
    raw = platform.machine().lower()
    arch = parse_arch(raw)
    if arch is None:
        raise RuntimeError(f"unsupported host architecture: {raw}")
    return arch


def _has_nvidia_gpu() -> bool:
    if any(marker.exists() for marker in _NVIDIA_MARKERS):
        return True
    nvidia_smi = shutil.which("nvidia-smi")
    if nvidia_smi is None:
        return False
    outcome = process.probe([nvidia_smi, "-L"], timeout=5)
    if isinstance(outcome, process.CommandUnavailable):
        return False
    return outcome.ok and "GPU" in outcome.stdout


# The invocation-context seam (§ M). The bootstrapper detects the outer host
# before a binary exists and states the answer here; the binary receives it
# rather than classifying the same host a second time. The names are declared
# rather than inherited: the bootstrapper sets exactly this pair on the binary
# it launches, and each value is one spelling of a closed vocabulary.
SUBSTRATE_ENV_VAR: Final[str] = "HOSTBOOTSTRAP_HOST_SUBSTRATE"
ARCH_ENV_VAR: Final[str] = "HOSTBOOTSTRAP_HOST_ARCH"


def invocation_context(sub: Substrate) -> dict[str, str]:
    """The detected host, as the two values the launched binary receives."""
    return {SUBSTRATE_ENV_VAR: sub.name.value, ARCH_ENV_VAR: sub.arch.value}


def detect() -> Substrate:
    system = platform.system()
    if system == "Darwin":
        arch = _docker_arch()
        if arch is not Arch.ARM64:
            raise RuntimeError(
                "hostbootstrap only supports Apple Silicon (arm64) on macOS; "
                f"detected arch={arch.value!r}"
            )
        return Substrate(SubstrateName.APPLE_SILICON, arch)
    if system == "Linux":
        arch = _docker_arch()
        if _has_nvidia_gpu():
            return Substrate(SubstrateName.LINUX_GPU, arch)
        return Substrate(SubstrateName.LINUX_CPU, arch)
    if system == "Windows":
        arch = _docker_arch()
        if _has_nvidia_gpu():
            return Substrate(SubstrateName.WINDOWS_GPU, arch)
        return Substrate(SubstrateName.WINDOWS_CPU, arch)
    raise RuntimeError(f"unsupported host platform: {system}")
