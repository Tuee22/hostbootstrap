"""Assert the fail-fast host minimums.

The thin bootstrapper asserts only what must hold before any project binary can
be built or run; everything richer (Docker, Colima, CUDA, Homebrew packages,
GHC, Tart) is ensured by Haskell ``ensure`` reconcilers. ``run_doctor``
dispatches by the detected :class:`Substrate` alone — there is no project model
to consult.

Per ``documents/engineering/prerequisites.md`` the minimums are:

* **Linux** — Ubuntu 24.04 + passwordless sudo + hardware virtualization
  (Intel VT-x / AMD-V enabled and a usable ``/dev/kvm``); ``linux-gpu``
  additionally verifies the NVIDIA container runtime is registered with Docker.
* **Apple silicon** — passwordless sudo + Xcode Command Line Tools + Homebrew.
"""

from __future__ import annotations

import asyncio
import os
import platform
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .substrate import Substrate, SubstrateName


class PrereqError(RuntimeError):
    """A prerequisite is missing or misconfigured."""


@dataclass(frozen=True)
class DoctorResult:
    substrate: Substrate
    messages: tuple[str, ...]
    reboot_required: bool = False


def _have(cmd: str) -> bool:
    return shutil.which(cmd) is not None


def _check_passwordless_sudo() -> None:
    if os.geteuid() == 0:
        return
    if not _have("sudo"):
        raise PrereqError("sudo is required but not installed")
    try:
        result = subprocess.run(
            ["sudo", "-n", "true"],
            capture_output=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise PrereqError(f"could not exec sudo: {exc}") from exc
    if result.returncode != 0:
        raise PrereqError(
            "passwordless sudo is required. Add a NOPASSWD entry for your "
            "user in /etc/sudoers.d/ before re-running."
        )


def _check_ubuntu_2404() -> None:
    os_release = Path("/etc/os-release")
    if not os_release.is_file():
        raise PrereqError("cannot read /etc/os-release; Linux substrates require Ubuntu 24.04")
    data = dict(line.split("=", 1) for line in os_release.read_text().splitlines() if "=" in line)
    distro_id = data.get("ID", "").strip('"')
    version_id = data.get("VERSION_ID", "").strip('"')
    if distro_id != "ubuntu" or version_id != "24.04":
        raise PrereqError(
            f"Linux substrates require Ubuntu 24.04; got ID={distro_id!r} VERSION_ID={version_id!r}"
        )


def _kvm_accessible() -> bool:
    """Whether ``/dev/kvm`` is usable — directly, or as root via passwordless sudo.

    Direct read/write access (the invoking user is in the ``kvm`` group) is the
    fast path. Otherwise, because passwordless sudo is an asserted prerequisite
    and hostbootstrap's privileged work runs as root, a successful
    ``sudo -n`` read/write probe is sufficient: it confirms the device is real and
    functional, and the user's ``kvm``-group membership is reconciled later (like
    ``docker``-group access), not gated here.
    """
    if os.access("/dev/kvm", os.R_OK | os.W_OK):
        return True
    if os.geteuid() == 0 or not _have("sudo"):
        return False
    try:
        result = subprocess.run(
            ["sudo", "-n", "sh", "-c", "test -r /dev/kvm && test -w /dev/kvm"],
            capture_output=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


def _check_virtualization_enabled() -> None:
    cpuinfo = Path("/proc/cpuinfo")
    if not cpuinfo.is_file():
        raise PrereqError("cannot read /proc/cpuinfo to verify hardware virtualization")
    flags: set[str] = set()
    for line in cpuinfo.read_text().splitlines():
        if line.startswith(("flags", "Features")):
            flags.update(line.partition(":")[2].split())
    if "vmx" not in flags and "svm" not in flags:
        raise PrereqError(
            "hardware virtualization (Intel VT-x / AMD-V) is not enabled. "
            "Enable it in your BIOS/UEFI firmware settings before re-running."
        )
    kvm = Path("/dev/kvm")
    if not kvm.exists():
        raise PrereqError(
            "/dev/kvm is missing. Load the kvm kernel module "
            "(modprobe kvm_intel or kvm_amd) before re-running."
        )
    if not _kvm_accessible():
        raise PrereqError(
            "/dev/kvm exists but is not usable, even via sudo. Ensure the kvm "
            "module is loaded and the device is functional before re-running."
        )


def _check_macos_arm64() -> None:
    if platform.system() != "Darwin":
        raise PrereqError("apple-silicon prereqs invoked on a non-Darwin host")
    if platform.machine().lower() not in {"arm64", "aarch64"}:
        raise PrereqError("apple-silicon requires an Apple Silicon Mac (arm64)")


def _check_xcode_clt() -> None:
    try:
        result = subprocess.run(
            ["xcode-select", "-p"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise PrereqError(f"xcode-select failed: {exc}") from exc
    if result.returncode != 0 or not result.stdout.strip():
        raise PrereqError(
            "Xcode Command Line Tools are required. Install with: xcode-select --install"
        )


def _check_homebrew() -> None:
    if not _have("brew"):
        raise PrereqError("Homebrew is required on apple-silicon. Install from https://brew.sh.")


def _check_nvidia_runtime() -> None:
    if not _have("nvidia-smi"):
        raise PrereqError("nvidia-smi not found; install the NVIDIA driver")
    if not _have("docker"):
        return
    try:
        result = subprocess.run(
            ["docker", "info", "--format", "{{json .Runtimes}}"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise PrereqError(f"docker info failed: {exc}") from exc
    if "nvidia" not in result.stdout:
        raise PrereqError(
            "NVIDIA container toolkit is not registered with Docker. "
            "Install nvidia-container-toolkit and re-configure dockerd."
        )


async def _run_apple(substrate: Substrate) -> DoctorResult:
    messages: list[str] = []
    _check_macos_arm64()
    messages.append("macOS arm64: OK")
    _check_xcode_clt()
    messages.append("Xcode Command Line Tools: OK")
    _check_passwordless_sudo()
    messages.append("passwordless sudo: OK")
    _check_homebrew()
    messages.append("Homebrew: OK")
    return DoctorResult(substrate=substrate, messages=tuple(messages))


async def _run_linux(substrate: Substrate) -> DoctorResult:
    messages: list[str] = []
    _check_ubuntu_2404()
    messages.append("Ubuntu 24.04: OK")
    _check_passwordless_sudo()
    messages.append("passwordless sudo: OK")
    _check_virtualization_enabled()
    messages.append("hardware virtualization: OK")

    if substrate.name is SubstrateName.LINUX_GPU:
        _check_nvidia_runtime()
        messages.append("NVIDIA container runtime: OK")

    return DoctorResult(substrate=substrate, messages=tuple(messages))


async def run_doctor(substrate: Substrate) -> DoctorResult:
    if substrate.name is SubstrateName.APPLE_SILICON:
        return await _run_apple(substrate)
    return await _run_linux(substrate)


def run_doctor_sync(substrate: Substrate) -> DoctorResult:
    return asyncio.run(run_doctor(substrate))
