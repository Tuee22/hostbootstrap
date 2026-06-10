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
from typing import NamedTuple

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


class ToolchainStep(NamedTuple):
    """A single toolchain-ensure step: a quiet *probe* and its *install* fallback.

    ``probe`` is a cheap, local, side-effect-free check (it never touches the
    network); ``install`` is run **only** when the probe reports the tool absent.
    """

    probe: tuple[str, ...]
    install: tuple[str, ...]


def toolchain_ensure_steps(sub: Substrate) -> tuple[ToolchainStep, ...]:
    """The host build-toolchain ensure steps (§ N), run before the build.

    Apple silicon: Homebrew installs ``ghcup``, which installs GHC and Cabal.
    Linux: ``ghcup`` installs GHC and Cabal (``ghcup`` is the documented host
    prerequisite, the Linux counterpart of Homebrew on Apple). Each step is
    **probe-then-install**: a quiet local probe (``ghcup whereis …`` /
    ``ghcup --version``) runs first, and the ``install`` command runs only when
    the probe reports the tool missing. This keeps the common path silent and
    offline — ``ghcup install`` would otherwise refresh its metadata from GitHub
    and warn that the pinned tools are already installed on every command.

    The GHC probe checks the pinned ``ghc-9.12.4`` itself: every project's
    ``cabal.project`` selects it via ``with-compiler: ghc-9.12.4``, which ghcup
    exposes as a version-suffixed binary once installed regardless of which GHC
    is "set", so probing installed-ness (not set-ness) is sufficient.
    """
    ghcup_steps = (
        ToolchainStep(
            probe=(_GHCUP, "whereis", "ghc", GHC_VERSION),
            install=(_GHCUP, "install", "ghc", GHC_VERSION, "--set"),
        ),
        ToolchainStep(
            probe=(_GHCUP, "whereis", "cabal"),
            install=(_GHCUP, "install", "cabal", "--set"),
        ),
    )
    if sub.name is SubstrateName.APPLE_SILICON:
        # ghcup itself must exist before its probes can run; probe for it, and
        # install it via Homebrew only when absent.
        brew_step = ToolchainStep(
            probe=(_GHCUP, "--version"),
            install=(_BREW, "install", "ghcup"),
        )
        return (brew_step, *ghcup_steps)
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


async def _already_present(probe: tuple[str, ...]) -> bool:
    """Whether *probe* reports its tool present (quiet; missing binary ⇒ absent)."""
    try:
        result = await process.run(probe, quiet=True)
    except FileNotFoundError:
        # The probe binary itself is missing (e.g. ``ghcup`` on a pristine Apple
        # host before Homebrew installs it) — treat as absent so install runs.
        return False
    return result.ok


async def _ensure_toolchain(sub: Substrate) -> None:
    """Ensure the host build toolchain (the prerequisites to build the binary).

    Each step probes first and installs only when the tool is absent, so the
    common (already-provisioned) path stays silent and makes no network call.
    """
    for step in toolchain_ensure_steps(sub):
        if await _already_present(step.probe):
            continue
        await process.run_checked(step.install)


async def _build_native(spec: StaticBaseSpec, *, project_root: Path) -> None:
    """Build the binary host-native into ``./.build/<project>``."""
    binary_path(spec, project_root).parent.mkdir(parents=True, exist_ok=True)
    await process.run_checked(native_build_command(spec), cwd=project_root)


async def build_binary(spec: StaticBaseSpec, *, project_root: Path) -> Path:
    """Run the pre-binary bootstrap (§§ M, N) and build the binary host-native.

    Asserts the fail-fast host minimums, ensures the host build toolchain, and
    builds the project binary into ``./.build/<project>``. Returns the built
    binary's path. Does **not** exec — this is the shared build path behind both
    ``hostbootstrap build`` and ``hostbootstrap run``.
    """
    sub = substrate.detect()

    # 1. fail-fast host minimums.
    await _assert_minimums(sub)

    # 2. ensure the host build toolchain (the prerequisites to build the binary).
    await _ensure_toolchain(sub)

    # 3. build the project binary host-native on every substrate.
    await _build_native(spec, project_root=project_root)

    return binary_path(spec, project_root)


async def bootstrap(
    spec: StaticBaseSpec,
    *,
    project_root: Path,
    args: tuple[str, ...] = (),
) -> None:
    """Build the project binary host-native, then ``exec`` it with ``args``."""
    await build_binary(spec, project_root=project_root)

    # exec the binary, handing control to the project command tree.
    argv = exec_argv(spec, project_root, args)
    os.execv(argv[0], list(argv))  # pragma: no cover
