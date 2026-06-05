"""``model: container`` (§9.5).

hostbootstrap builds a thin image ``FROM`` the hostbootstrap base tag and runs
it. The container owns any cluster/upload work itself; hostbootstrap never
creates a system service unit for this model.

* ``service = False`` → one-shot ``docker run --rm`` (the compose-replacement case).
* ``service = True``  → ``cluster up`` runs it detached with
  ``--restart unless-stopped`` so the Docker daemon restarts it across reboots.

Project source is built into the image (the Dockerfile inherits ``FROM
${BASE_IMAGE}``); the heavy toolchain is pulled with the base, so cold builds
compile only project code.
"""

from __future__ import annotations

import json
import os
import shlex
from collections.abc import Sequence
from pathlib import Path

from hostbootstrap import base_image, docker_ops, process
from hostbootstrap.spec import ContainerArtifact, ContainerModel, ProjectSpec
from hostbootstrap.substrate import Substrate


def image_tag(spec: ProjectSpec, substrate: Substrate) -> str:
    return f"{spec.project}:{substrate.name.value}-{substrate.arch}"


def resolve_host_path(host: str, project_root: Path) -> str:
    """Expand ``${VARS}`` and absolutize a bind-mount host path."""
    expanded = os.path.expandvars(host)
    if os.path.isabs(expanded):
        return expanded
    return os.path.abspath(os.path.join(project_root, expanded))


def _mounts(model: ContainerModel, project_root: Path) -> tuple[tuple[str, str, bool], ...]:
    return tuple(
        (resolve_host_path(m.host, project_root), m.container, m.read_only) for m in model.mounts
    )


def _command_name(token: str) -> str:
    return Path(token).name


def _entrypoint_program(entrypoint: Sequence[str]) -> str:
    first = _command_name(entrypoint[0])
    if first != "tini":
        return first

    if "--" not in entrypoint:
        return first

    marker = entrypoint.index("--")
    if marker + 1 >= len(entrypoint):
        return first
    return _command_name(entrypoint[marker + 1])


def _render_hostbootstrap_run(args: Sequence[str]) -> str:
    return shlex.join(("hostbootstrap", "run", *args))


def _render_entrypoint(entrypoint: Sequence[str]) -> str:
    return json.dumps(list(entrypoint))


def validate_entrypoint_for_args(
    *,
    project: str,
    tag: str,
    entrypoint: Sequence[str],
    args: Sequence[str],
) -> None:
    """Enforce the unified ``hostbootstrap run [args...]`` topology for containers."""
    if not entrypoint:
        raise RuntimeError(
            f"container image {tag!r} has no ENTRYPOINT; `hostbootstrap run` treats "
            "trailing tokens as arguments to the project entrypoint, matching "
            "host-binary and host-daemon modes. Add "
            f'`ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/{project}"]` '
            "to the Dockerfile, or another tini-wrapped project executable."
        )

    program = _entrypoint_program(entrypoint)
    if args and program == _command_name(args[0]):
        raise RuntimeError(
            f"container image {tag!r} already declares ENTRYPOINT "
            f"{_render_entrypoint(entrypoint)}; pass only project arguments after "
            f"`hostbootstrap run`, for example `{_render_hostbootstrap_run(args[1:])}` "
            f"instead of `{_render_hostbootstrap_run(args)}`."
        )


async def build(
    spec: ProjectSpec,
    model: ContainerModel,
    substrate: Substrate,
    *,
    flavor: base_image.Flavor,
    project_root: Path,
    build_base: bool = False,
    base_context: Path | None = None,
    pull: bool = True,
) -> str:
    """Build the project image ``FROM`` the base tag; return its local tag."""
    tag = image_tag(spec, substrate)
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
    build_spec = docker_ops.BuildSpec(
        dockerfile=project_root / model.dockerfile,
        context=project_root,
        tags=(tag,),
        build_args={"BASE_IMAGE": base_image.base_image_ref(flavor, substrate.arch)},
        pull=pull and not build_base,
    )
    await docker_ops.build(build_spec)
    return tag


async def build_artifact(
    spec: ProjectSpec,
    artifact: ContainerArtifact,
    substrate: Substrate,
    *,
    flavor: base_image.Flavor,
    project_root: Path,
    build_base: bool = False,
    base_context: Path | None = None,
    pull: bool = True,
) -> str:
    """Build the optional container counterpart declared by a binary/daemon model."""
    tag = image_tag(spec, substrate)
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
    build_spec = docker_ops.BuildSpec(
        dockerfile=project_root / artifact.dockerfile,
        context=project_root,
        tags=(tag,),
        build_args={"BASE_IMAGE": base_image.base_image_ref(flavor, substrate.arch)},
        pull=pull and not build_base,
    )
    await docker_ops.build(build_spec)
    return tag


async def run_one_shot(
    spec: ProjectSpec,
    model: ContainerModel,
    substrate: Substrate,
    command: Sequence[str],
    *,
    flavor: base_image.Flavor,
    project_root: Path,
    build_base: bool = False,
    base_context: Path | None = None,
    pull: bool = True,
) -> process.CommandResult:
    tag = await build(
        spec,
        model,
        substrate,
        flavor=flavor,
        project_root=project_root,
        build_base=build_base,
        base_context=base_context,
        pull=pull,
    )
    entrypoint = await docker_ops.image_entrypoint(tag)
    validate_entrypoint_for_args(
        project=spec.project,
        tag=tag,
        entrypoint=entrypoint,
        args=command,
    )
    run_spec = docker_ops.RunSpec(
        image=tag,
        command=tuple(command),
        rm=True,
        mounts=_mounts(model, project_root),
    )
    return await process.run_checked(docker_ops.run_command(run_spec))


async def start_service(
    spec: ProjectSpec,
    model: ContainerModel,
    substrate: Substrate,
    *,
    flavor: base_image.Flavor,
    project_root: Path,
    build_base: bool = False,
    base_context: Path | None = None,
    pull: bool = True,
) -> process.CommandResult:
    """Start the long-running container detached with ``--restart unless-stopped``."""
    tag = await build(
        spec,
        model,
        substrate,
        flavor=flavor,
        project_root=project_root,
        build_base=build_base,
        base_context=base_context,
        pull=pull,
    )
    # Recreate idempotently: remove any prior container of the same name first.
    await process.run(["docker", "rm", "-f", spec.project], quiet=True)
    run_spec = docker_ops.RunSpec(
        image=tag,
        detach=True,
        restart="unless-stopped",
        name=spec.project,
        mounts=_mounts(model, project_root),
    )
    return await process.run_checked(docker_ops.run_command(run_spec))


async def stop_service(spec: ProjectSpec) -> process.CommandResult:
    return await process.run(["docker", "rm", "-f", spec.project], quiet=True)
