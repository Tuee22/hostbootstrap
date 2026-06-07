"""The thin five-step bootstrapper.

The Python layer does only what must run *before any project binary exists*
(see ``documents/architecture/python_haskell_boundary.md``):

1. assert the fail-fast host minimums;
2. ensure Docker (on Apple silicon, provision a per-project Colima VM sized to
   the ``resources`` budget);
3. build the project container ``FROM`` the base image — the ``check-code``
   quality gate, which always runs;
4. copy the built binary to ``./.build/<project>`` (Linux: build in-container
   and copy it out; Apple: build host-native because a Linux ELF cannot exec on
   macOS);
5. ensure the host runtimes the binary needs and ``exec`` it, handing control
   to ``hostbootstrap-core``'s command tree extended by the project.

Everything is a pure command-builder (returning exact argv so it is trivially
testable) plus a thin async :func:`bootstrap` driver. The single
:func:`os.execv` call never returns, so it carries the only ``# pragma: no
cover``.
"""

from __future__ import annotations

import os
from pathlib import Path

from . import base_image, docker_ops, prereqs, process, substrate
from .spec import SkeletalSpec
from .substrate import Substrate, SubstrateName

_DOCKER: str = "docker"
_COLIMA: str = "colima"
_BREW: str = "brew"

# The shared name under which the project container is built and torn down.
_BUILD_DIR: str = ".build"
# Where the binary lands inside the project container (Linux copy-out path).
_CONTAINER_BINARY_DIR: str = "/out"


# ---------------------------------------------------------------------------
# Pure command-builders
# ---------------------------------------------------------------------------


def image_tag(spec: SkeletalSpec, sub: Substrate) -> str:
    """The local tag for the project container on this substrate."""
    return f"{spec.project}:{sub.name.value}-{sub.arch}"


def container_build_spec(
    spec: SkeletalSpec,
    sub: Substrate,
    *,
    project_root: Path,
    flavor: base_image.Flavor,
    pull: bool = True,
) -> docker_ops.BuildSpec:
    """Build the project container ``FROM`` the base tag (the check-code gate)."""
    return docker_ops.BuildSpec(
        dockerfile=project_root / spec.dockerfile,
        context=project_root,
        tags=(image_tag(spec, sub),),
        build_args={"BASE_IMAGE": base_image.base_image_ref(flavor, sub.arch)},
        pull=pull,
    )


def colima_start_command(spec: SkeletalSpec) -> tuple[str, ...]:
    """Provision a per-project Colima VM sized to the ``resources`` budget."""
    resources = spec.resources
    return (
        _COLIMA,
        "start",
        "--profile",
        spec.project,
        "--cpu",
        str(resources.cpu),
        "--memory",
        _gib(resources.memory),
        "--disk",
        _gib(resources.storage),
    )


def _gib(value: str) -> str:
    """Render a ``"<N>GiB"`` budget as the bare integer Colima's flags expect."""
    text = value.strip()
    for suffix in ("GiB", "GB", "G", "gib", "gb", "g"):
        if text.endswith(suffix):
            return text[: -len(suffix)].strip()
    return text


def copy_out_create_command(spec: SkeletalSpec, sub: Substrate) -> tuple[str, ...]:
    """Create a stopped container so its built binary can be copied out."""
    return (_DOCKER, "create", "--name", _copy_out_name(spec), image_tag(spec, sub))


def copy_out_cp_command(spec: SkeletalSpec, *, project_root: Path) -> tuple[str, ...]:
    """Copy ``/out/<project>`` out of the stopped container to ``./.build/``."""
    source = f"{_copy_out_name(spec)}:{_CONTAINER_BINARY_DIR}/{spec.project}"
    return (_DOCKER, "cp", source, str(binary_path(spec, project_root)))


def copy_out_rm_command(spec: SkeletalSpec) -> tuple[str, ...]:
    """Remove the throwaway copy-out container."""
    return (_DOCKER, "rm", _copy_out_name(spec))


def _copy_out_name(spec: SkeletalSpec) -> str:
    return f"{spec.project}-copyout"


def native_build_command(spec: SkeletalSpec) -> tuple[str, ...]:
    """Build the binary host-native into ``./.build/`` (Apple silicon)."""
    return (
        "cabal",
        "install",
        f"exe:{spec.project}",
        "--installdir",
        _BUILD_DIR,
        "--install-method=copy",
        "--overwrite-policy=always",
    )


def ensure_ghc_command() -> tuple[str, ...]:
    """Ensure a host GHC toolchain (Apple native build needs one)."""
    return (_BREW, "install", "ghcup")


def binary_path(spec: SkeletalSpec, project_root: Path) -> Path:
    """The single stable ``./.build/<project>`` location every consumer execs."""
    return project_root / _BUILD_DIR / spec.project


def exec_argv(spec: SkeletalSpec, project_root: Path, args: tuple[str, ...]) -> tuple[str, ...]:
    """The argv handed to ``os.execv``: the built binary plus trailing args."""
    return (str(binary_path(spec, project_root)), *args)


# ---------------------------------------------------------------------------
# Async driver
# ---------------------------------------------------------------------------


async def _assert_minimums(sub: Substrate) -> None:
    await prereqs.run_doctor(sub)


async def _ensure_docker(spec: SkeletalSpec, sub: Substrate) -> None:
    if sub.name is SubstrateName.APPLE_SILICON:
        await process.run_checked(colima_start_command(spec))


async def _copy_binary_out(spec: SkeletalSpec, sub: Substrate, *, project_root: Path) -> None:
    """Extract the in-container binary to ``./.build/<project>`` (Linux path)."""
    binary_path(spec, project_root).parent.mkdir(parents=True, exist_ok=True)
    await process.run_checked(copy_out_create_command(spec, sub))
    try:
        await process.run_checked(copy_out_cp_command(spec, project_root=project_root))
    finally:
        await process.run_checked(copy_out_rm_command(spec))


async def _build_native(spec: SkeletalSpec, *, project_root: Path) -> None:
    """Build the binary host-native (Apple silicon); ensure host GHC first."""
    binary_path(spec, project_root).parent.mkdir(parents=True, exist_ok=True)
    await process.run_checked(ensure_ghc_command())
    await process.run_checked(native_build_command(spec), cwd=project_root)


async def bootstrap(
    spec: SkeletalSpec,
    *,
    project_root: Path,
    args: tuple[str, ...] = (),
    pull: bool = True,
) -> None:
    """Run the five-step bootstrap, then ``exec`` the project binary."""
    sub = substrate.detect()
    flavor = _flavor_for(sub)

    # 1. fail-fast host minimums.
    await _assert_minimums(sub)

    # 2. ensure Docker (per-project Colima VM on Apple, sized to the budget).
    await _ensure_docker(spec, sub)

    # 3. build the project container (the check-code gate; always runs).
    await docker_ops.build(
        container_build_spec(spec, sub, project_root=project_root, flavor=flavor, pull=pull)
    )

    # 4. copy the built binary to ./.build/<project>.
    if sub.name is SubstrateName.APPLE_SILICON:
        await _build_native(spec, project_root=project_root)
    else:
        await _copy_binary_out(spec, sub, project_root=project_root)

    # 5. exec the binary, handing control to the project command tree.
    argv = exec_argv(spec, project_root, args)
    os.execv(argv[0], list(argv))  # pragma: no cover


def _flavor_for(sub: Substrate) -> base_image.Flavor:
    return base_image.substrate_to_flavor(sub.name)
