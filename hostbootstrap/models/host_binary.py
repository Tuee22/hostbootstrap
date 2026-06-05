"""``model: host-binary``.

The primary artifact is a binary that runs **on the host**. hostbootstrap builds
it, optionally builds a container counterpart, and then hands cluster lifecycle
off to the project's own ``cluster up`` / ``down`` / ``delete`` commands. It
creates no system unit.

* **Apple silicon** — run the derived ``cabal install exe:<project>`` command on
  the host; hot rebuilds stay incremental.
* **Linux** — run the same derived Cabal install **inside the base container**
  with the project source mounted, so the toolchain never lands on the Linux
  host; the binary appears in the host ``.build/`` directory.

The project name is the executable name. hostbootstrap installs
``exe:<project>`` into ``.build/<project>``.
"""

from __future__ import annotations

import os
import shlex
from collections.abc import Sequence
from pathlib import Path

from hostbootstrap import base_image, docker_ops, process
from hostbootstrap.spec import HostBinaryModel, ProjectSpec
from hostbootstrap.substrate import Substrate, SubstrateName

from . import container


def build_dir(project_root: Path) -> Path:
    return project_root / ".build"


def binary_path(spec: ProjectSpec, project_root: Path) -> Path:
    return build_dir(project_root) / spec.project


def resolve_command(raw: str, project_root: Path) -> tuple[str, ...]:
    """Split a host command string, absolutizing a leading ``.build/…`` token."""
    parts = shlex.split(raw)
    if parts and not os.path.isabs(parts[0]) and parts[0].startswith(".build/"):
        parts[0] = os.path.abspath(os.path.join(project_root, parts[0]))
    return tuple(parts)


async def build_binary(
    spec: ProjectSpec,
    substrate: Substrate,
    *,
    flavor: base_image.Flavor,
    project_root: Path,
    build_base: bool = False,
    base_context: Path | None = None,
) -> Path:
    """Build the host binary; return its ``.build/<project>`` path."""
    build_dir(project_root).mkdir(parents=True, exist_ok=True)
    cabal_cmd = (
        "cabal install --installdir .build --install-method=copy "
        f"--overwrite-policy=always exe:{spec.project}"
    )

    if substrate.name is SubstrateName.APPLE_SILICON:
        await process.run_checked(shlex.split(cabal_cmd), cwd=project_root)
        return binary_path(spec, project_root)

    base_tag = base_image.base_image_ref(flavor, substrate.arch)
    if build_base:
        if base_context is None:
            raise RuntimeError(
                "--build-base requires --base-context pointing at the hostbootstrap repo"
            )
        base_spec, _ = base_image.build_spec_for(
            flavor,
            substrate.arch,
            context=base_context,
            pull=False,
        )
        await docker_ops.build(base_spec)
    run_spec = docker_ops.RunSpec(
        image=base_tag,
        command=("sh", "-c", cabal_cmd),
        rm=True,
        mounts=((str(project_root), "/src", False),),
        extra=("-w", "/src"),
    )
    await process.run_checked(docker_ops.run_command(run_spec))
    return binary_path(spec, project_root)


async def build(
    spec: ProjectSpec,
    model: HostBinaryModel,
    substrate: Substrate,
    *,
    flavor: base_image.Flavor,
    project_root: Path,
    build_base: bool = False,
    base_context: Path | None = None,
    pull: bool = True,
    tag_substrate: Substrate | None = None,
) -> Path:
    """Build the binary and, if declared, the optional container counterpart."""
    _ = pull  # The host-binary itself is built on the host, not in a container.
    path = await build_binary(
        spec,
        substrate,
        flavor=flavor,
        project_root=project_root,
        build_base=build_base,
        base_context=base_context,
    )
    if model.container is not None:
        await container.build_artifact(
            spec,
            model.container,
            substrate if tag_substrate is None else tag_substrate,
            flavor=flavor,
            project_root=project_root,
            build_base=build_base,
            base_context=base_context,
            pull=pull,
        )
    return path


async def run_one_shot(
    spec: ProjectSpec,
    model: HostBinaryModel,
    substrate: Substrate,
    command: Sequence[str],
    *,
    flavor: base_image.Flavor,
    project_root: Path,
    build_base: bool = False,
    base_context: Path | None = None,
    pull: bool = True,
    tag_substrate: Substrate | None = None,
    env: dict[str, str] | None = None,
) -> process.CommandResult:
    path = await build(
        spec,
        model,
        substrate,
        flavor=flavor,
        project_root=project_root,
        build_base=build_base,
        base_context=base_context,
        pull=pull,
        tag_substrate=tag_substrate,
    )
    return await process.run_checked([str(path), *command], cwd=project_root, env=env)
