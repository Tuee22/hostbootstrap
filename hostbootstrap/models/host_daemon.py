"""``model: host-daemon``.

A long-running **host-native** daemon must run alongside the project-managed
cluster. hostbootstrap builds the binary and forwards cluster lifecycle to the
project command, but it never backgrounds, supervises, or stops the daemon. A
supervisor or test harness runs ``hostbootstrap daemon run`` and owns that
foreground process.
"""

from __future__ import annotations

import shlex
from collections.abc import Sequence
from pathlib import Path

from hostbootstrap import base_image, process
from hostbootstrap.spec import HostDaemonModel, ProjectSpec
from hostbootstrap.substrate import Substrate

from . import container, host_binary


async def build(
    spec: ProjectSpec,
    model: HostDaemonModel,
    substrate: Substrate,
    *,
    flavor: base_image.Flavor,
    project_root: Path,
    build_base: bool = False,
    base_context: Path | None = None,
    pull: bool = True,
    tag_substrate: Substrate | None = None,
) -> Path:
    """Build the host binary and, if declared, the container counterpart."""
    path = await host_binary.build_binary(
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


def daemon_command(model: HostDaemonModel, *, project_root: Path) -> tuple[str, ...]:
    """The host daemon arguments appended to ``.build/<project>``."""
    _ = project_root
    return tuple(shlex.split(model.daemon))


async def run_one_shot(
    spec: ProjectSpec,
    model: HostDaemonModel,
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


async def run_daemon(
    spec: ProjectSpec,
    model: HostDaemonModel,
    substrate: Substrate,
    *,
    flavor: base_image.Flavor,
    project_root: Path,
    build_base: bool = False,
    base_context: Path | None = None,
    pull: bool = True,
    tag_substrate: Substrate | None = None,
    env: dict[str, str] | None = None,
) -> process.CommandResult:
    """Run the configured daemon in the foreground."""
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
    return await process.run_checked(
        [str(path), *daemon_command(model, project_root=project_root)],
        cwd=project_root,
        env=env,
    )
