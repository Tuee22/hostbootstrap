"""Assert the fail-fast host minimums.

The thin bootstrapper asserts only what must hold before any project binary can
be built or run; everything richer (Docker, Colima, CUDA, Homebrew packages,
GHC, WSL2) is ensured by Haskell ``ensure`` reconcilers. ``run_doctor``
dispatches by the detected :class:`Substrate` alone — there is no project model
to consult.

Per ``documents/engineering/prerequisites.md`` the minimums are the **pre-binary
build floor only** — the wrapper asserts nothing beyond what building the project
binary needs, so the ``run`` floor equals the ``build`` floor on every substrate.
Runtime host preconditions once asserted here — a usable ``/dev/kvm`` for the
nested VM providers, and the ``linux-gpu`` NVIDIA container runtime — are now owned
by the binary's ``ensure`` logic (``ensure incus``'s KVM self-heal and
``ensure cuda``), per ``documents/architecture/python_haskell_boundary.md``.

* **Linux** — Ubuntu 24.04 + passwordless sudo.
* **Apple silicon** — passwordless sudo + Xcode Command Line Tools + Homebrew.
* **Windows** — winget (a required precondition, used by ``ensure cudawin``; the
  GHC/Cabal toolchain is PowerShell-bootstrapped, not winget-installed) and Windows
  PowerShell (which runs the toolchain bootstrap). WSL2 is a provider
  dependency owned by the built binary's ``ensure wsl2`` path.
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
    geteuid = getattr(os, "geteuid", None)
    if geteuid is not None and geteuid() == 0:
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


def _check_winget() -> None:
    if not _have("winget"):
        raise PrereqError(
            "winget is required on Windows. Install App Installer from Microsoft Store, then re-run."
        )


def _check_powershell() -> None:
    if not _have("powershell"):
        raise PrereqError(
            "Windows PowerShell is required to bootstrap the Haskell toolchain but "
            "was not found on PATH."
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
    # The runtime floor equals the build floor: KVM (nested VM provider) and the
    # linux-gpu NVIDIA runtime are runtime host preconditions the binary owns via
    # its ``ensure`` logic, not pre-binary work the wrapper asserts.
    messages: list[str] = []
    _check_ubuntu_2404()
    messages.append("Ubuntu 24.04: OK")
    _check_passwordless_sudo()
    messages.append("passwordless sudo: OK")
    return DoctorResult(substrate=substrate, messages=tuple(messages))


async def _run_windows(substrate: Substrate) -> DoctorResult:
    messages: list[str] = []
    _check_winget()
    messages.append("winget: OK")
    _check_powershell()
    messages.append("PowerShell: OK")
    return DoctorResult(substrate=substrate, messages=tuple(messages))


async def run_doctor(substrate: Substrate) -> DoctorResult:
    if substrate.name is SubstrateName.APPLE_SILICON:
        return await _run_apple(substrate)
    if substrate.is_windows:
        return await _run_windows(substrate)
    return await _run_linux(substrate)


def run_doctor_sync(substrate: Substrate) -> DoctorResult:
    return asyncio.run(run_doctor(substrate))
