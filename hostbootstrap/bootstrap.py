"""The thin pre-binary bootstrapper.

The Python layer does only what must run *before any project binary exists*
(see ``documents/architecture/python_haskell_boundary.md`` §§ M, N):

1. assert the fail-fast host minimums;
2. ensure the host build toolchain (Homebrew → ``ghcup`` → GHC/Cabal on Apple
   silicon; ``ghcup`` → GHC/Cabal on Linux) — the prerequisites to *build* the
   binary;
3. build the project binary **host-native** at ``./.build/<project>`` on every
   substrate (a Linux ELF cannot exec on Apple silicon, so there is no
   build-in-container-and-copy-out path);
4. ``exec`` the binary, handing control to ``hostbootstrap-core``'s command tree
   extended by the project.

Ensuring Docker, building the project container (``FROM`` the base image), and
applying the budget cordon are the **project binary's** job once it is running —
not the Python layer's. The Python bootstrapper neither talks to Docker nor sizes
a VM.

Everything is a pure command-builder (returning exact argv so it is trivially
testable) plus a thin async :func:`bootstrap` driver. The single
:func:`os.execv` call never returns, so it carries the only ``# pragma: no
cover``.
"""

from __future__ import annotations

import os
from pathlib import Path

from . import prereqs, process, substrate
from .spec import StaticBaseSpec
from .substrate import Substrate, SubstrateName

_BREW: str = "brew"
_GHCUP: str = "ghcup"
_CABAL: str = "cabal"

# The family-pinned GHC every project's ``cabal.project`` selects (matches
# ``base_image.GHC_VERSION`` and the warm-store toolchain). The toolchain ensure
# installs exactly this version so the host-native build resolves its pinned
# ``with-compiler: ghc-9.12.4`` rather than whatever ``ghcup`` calls recommended.
GHC_VERSION: str = "9.12.4"

# The host-native build output directory; ./.build/<project> is always present.
_BUILD_DIR: str = ".build"


# ---------------------------------------------------------------------------
# Pure command-builders
# ---------------------------------------------------------------------------


def toolchain_ensure_commands(sub: Substrate) -> tuple[tuple[str, ...], ...]:
    """The host build-toolchain ensure commands (§ N), run before the build.

    Apple silicon: Homebrew installs ``ghcup``, which installs GHC and Cabal.
    Linux: ``ghcup`` installs GHC and Cabal (``ghcup`` is the documented host
    prerequisite, the Linux counterpart of Homebrew on Apple). The commands are
    probe-tolerant: ``brew install`` / ``ghcup install`` are no-ops when the
    tool is already present.
    """
    ghcup_steps = (
        (_GHCUP, "install", "ghc", GHC_VERSION, "--set"),
        (_GHCUP, "install", "cabal", "--set"),
    )
    if sub.name is SubstrateName.APPLE_SILICON:
        return ((_BREW, "install", "ghcup"), *ghcup_steps)
    return ghcup_steps


def native_build_command(spec: StaticBaseSpec) -> tuple[str, ...]:
    """Build the project binary host-native into ``./.build/`` (every substrate)."""
    return (
        _CABAL,
        "install",
        f"exe:{spec.project}",
        "--installdir",
        _BUILD_DIR,
        "--install-method=copy",
        "--overwrite-policy=always",
    )


def binary_path(spec: StaticBaseSpec, project_root: Path) -> Path:
    """The single stable ``./.build/<project>`` location every consumer execs."""
    return project_root / _BUILD_DIR / spec.project


def exec_argv(spec: StaticBaseSpec, project_root: Path, args: tuple[str, ...]) -> tuple[str, ...]:
    """The argv handed to ``os.execv``: the built binary plus trailing args."""
    return (str(binary_path(spec, project_root)), *args)


# ---------------------------------------------------------------------------
# Async driver
# ---------------------------------------------------------------------------


async def _assert_minimums(sub: Substrate) -> None:
    await prereqs.run_doctor(sub)


async def _ensure_toolchain(sub: Substrate) -> None:
    """Ensure the host build toolchain (the prerequisites to build the binary)."""
    for command in toolchain_ensure_commands(sub):
        await process.run_checked(command)


async def _build_native(spec: StaticBaseSpec, *, project_root: Path) -> None:
    """Build the binary host-native into ``./.build/<project>``."""
    binary_path(spec, project_root).parent.mkdir(parents=True, exist_ok=True)
    await process.run_checked(native_build_command(spec), cwd=project_root)


async def bootstrap(
    spec: StaticBaseSpec,
    *,
    project_root: Path,
    args: tuple[str, ...] = (),
) -> None:
    """Run the pre-binary bootstrap (§§ M, N), then ``exec`` the project binary."""
    sub = substrate.detect()

    # 1. fail-fast host minimums.
    await _assert_minimums(sub)

    # 2. ensure the host build toolchain (the prerequisites to build the binary).
    await _ensure_toolchain(sub)

    # 3. build the project binary host-native on every substrate.
    await _build_native(spec, project_root=project_root)

    # 4. exec the binary, handing control to the project command tree.
    argv = exec_argv(spec, project_root, args)
    os.execv(argv[0], list(argv))  # pragma: no cover
