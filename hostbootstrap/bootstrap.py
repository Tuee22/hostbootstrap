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
4. write the host-level ``project-binary-context-config.dhall`` next to the
   built binary;
5. ``exec`` the binary, handing control to ``hostbootstrap-core``'s command tree
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

import json
import os
import shutil
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
_CONTEXT_FILE_NAME: str = "project-binary-context-config.dhall"

# The host-native cabal package store, kept repo-local (under the already
# git-ignored ./.build/) so `git clean -fxd` resets the full build state — the
# compiled dependency closure included — instead of serving deps from the
# user-global cabal store at ~/.local/state/cabal/store. This is the host build's
# store only; the in-container build uses the warm store at /opt/cache/cabal.
_STORE_DIR: str = f"{_BUILD_DIR}/cabal-store"

_CONTEXT_KINDS: tuple[str, ...] = (
    "HostOrchestrator",
    "VMOrchestrator",
    "VMProjectContainer",
    "ClusterService",
    "Daemon",
    "OneShotJob",
    "TestHarness",
)

_CAPABILITIES: tuple[str, ...] = (
    "HostTools",
    "IncusProvider",
    "DockerSocket",
    "ContainerRuntime",
    "KubernetesAPI",
    "KindNetwork",
    "DurableStore",
    "ServicePort",
)

_COMMAND_CLASSES: tuple[str, ...] = (
    "EnsureCommand",
    "ConfigInspectionCommand",
    "ConfigGenerationCommand",
    "ContextCreationCommand",
    "ClusterLifecycleCommand",
    "TestWorkflowCommand",
    "CheckCodeCommand",
    "HostOrchestratorCommand",
    "DaemonCommand",
    "ServiceCommand",
    "ProjectCommand",
)


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


def native_build_command(spec: StaticBaseSpec, project_root: Path) -> tuple[str, ...]:
    """Build the project binary host-native, in place (every substrate).

    Plain ``cabal build`` (not ``cabal install``): it is incremental and, on an
    unchanged rerun, prints just ``Up to date`` — it does **not** re-package each
    local source into an sdist tarball, re-resolve, or copy the exe on every
    invocation the way ``install`` does. The built binary is then located via
    :func:`native_listbin_command` and copied to the stable ``./.build/<project>``
    path by :func:`_build_native`, so the no-branching exec contract is preserved
    without the install-time chatter.

    ``--store-dir`` (a cabal *global* flag, so it precedes the ``build``
    subcommand) keeps the package store repo-local under ``./.build/cabal-store``
    rather than the user-global store, so ``git clean -fxd`` fully resets the host
    build state — dependencies included. Cabal requires the store dir to be
    **absolute** (it derives each package's ``--prefix`` from it, and a relative
    prefix is rejected at configure time), so it is resolved against *project_root*.
    """
    return (
        _CABAL,
        "--store-dir",
        str(project_root / _STORE_DIR),
        "build",
        f"exe:{spec.project}",
    )


def native_listbin_command(spec: StaticBaseSpec, project_root: Path) -> tuple[str, ...]:
    """Print the built exe's path under ``dist-newstyle/`` (no rebuild, no chatter).

    Carries the same absolute ``--store-dir`` as :func:`native_build_command` so it
    resolves the identical build plan and reports the binary that build produced.
    """
    return (
        _CABAL,
        "--store-dir",
        str(project_root / _STORE_DIR),
        "list-bin",
        f"exe:{spec.project}",
    )


def binary_path(spec: StaticBaseSpec, project_root: Path) -> Path:
    """The single stable ``./.build/<project>`` location every consumer execs."""
    return project_root / _BUILD_DIR / spec.project


def binary_context_path(spec: StaticBaseSpec, project_root: Path) -> Path:
    """The host-level sibling context path for ``./.build/<project>``."""
    return binary_path(spec, project_root).parent / _CONTEXT_FILE_NAME


def exec_argv(spec: StaticBaseSpec, project_root: Path, args: tuple[str, ...]) -> tuple[str, ...]:
    """The argv handed to ``os.execv``: the built binary plus trailing args."""
    return (str(binary_path(spec, project_root)), *args)


def _dhall_text(value: str) -> str:
    """Render a Python string as a Dhall ``Text`` literal."""
    return json.dumps(value)


def _dhall_union(constructors: tuple[str, ...], value: str) -> str:
    if value not in constructors:
        raise ValueError(f"{value!r} is not in the Dhall union {constructors!r}")
    return f"< {' | '.join(constructors)} >.{value}"


def _dhall_union_list(constructors: tuple[str, ...], values: tuple[str, ...]) -> str:
    return "[ " + ", ".join(_dhall_union(constructors, value) for value in values) + " ]"


def _empty_parent_chain() -> str:
    return "[] : List { frameKind : < " + " | ".join(_CONTEXT_KINDS) + " >, frameBinary : Text }"


def host_context_dhall(spec: StaticBaseSpec, *, project_root: Path) -> str:
    """Render the host-orchestrator binary context as Dhall.

    This is the first runtime context: it is created by the Python bootstrapper
    after the host-native binary exists, then read by the project binary before
    normal command dispatch once Phase 15 wiring is complete.
    """
    allowed_commands = (
        "EnsureCommand",
        "ConfigInspectionCommand",
        "ConfigGenerationCommand",
        "ContextCreationCommand",
        "ClusterLifecycleCommand",
        "TestWorkflowCommand",
        "CheckCodeCommand",
        "HostOrchestratorCommand",
        "ProjectCommand",
    )
    child_kinds = (
        "VMOrchestrator",
        "VMProjectContainer",
        "ClusterService",
        "Daemon",
        "OneShotJob",
        "TestHarness",
    )
    return "\n".join(
        [
            "{ project = " + _dhall_text(spec.project),
            ", binary = " + _dhall_text(spec.project),
            ", sourceRoot = " + _dhall_text(str(project_root)),
            ", contextKind = " + _dhall_union(_CONTEXT_KINDS, "HostOrchestrator"),
            ", parentChain = " + _empty_parent_chain(),
            ", capabilities = " + _dhall_union_list(_CAPABILITIES, ("HostTools", "IncusProvider")),
            ", allowedCommandClasses = " + _dhall_union_list(_COMMAND_CLASSES, allowed_commands),
            ", resourceEnvelope = "
            + "{ cpu = "
            + str(spec.resources.cpu)
            + ", memory = "
            + _dhall_text(spec.resources.memory)
            + ", storage = "
            + _dhall_text(spec.resources.storage)
            + " }",
            ", childContextKinds = " + _dhall_union_list(_CONTEXT_KINDS, child_kinds),
            "}",
            "",
        ]
    )


def write_host_context(spec: StaticBaseSpec, *, project_root: Path) -> Path:
    """Idempotently write the first sibling binary context next to the host binary."""
    path = binary_context_path(spec, project_root)
    path.parent.mkdir(parents=True, exist_ok=True)
    content = host_context_dhall(spec, project_root=project_root)
    if path.exists() and path.read_text(encoding="utf-8") == content:
        return path
    path.write_text(content, encoding="utf-8")
    return path


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
    """Build the binary host-native and copy it to ``./.build/<project>``.

    ``cabal build`` leaves the exe at a hashed path under ``dist-newstyle/``; we
    ask cabal for that path (``list-bin``, quiet so its one line is not echoed as
    chatter) and copy it to the stable ``./.build/<project>`` location every
    consumer execs. :func:`shutil.copy2` preserves the exec bit and overwrites any
    prior binary.
    """
    binary_path(spec, project_root).parent.mkdir(parents=True, exist_ok=True)
    await process.run_checked(native_build_command(spec, project_root), cwd=project_root)
    located = await process.run_checked(
        native_listbin_command(spec, project_root), cwd=project_root, quiet=True
    )
    shutil.copy2(Path(located.stdout.strip()), binary_path(spec, project_root))


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

    # 4. create the first "know your place" runtime context.
    write_host_context(spec, project_root=project_root)

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
