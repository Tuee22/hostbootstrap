"""``hostbootstrap`` Click application.

The single entrypoint installed on every downstream host (via
``pip install git+…``). Commands implement §6 of the plan: doctor, build,
cluster up/down/delete, run, base build-and-push. Each substrate's execution model
(``container`` / ``host-binary`` / ``host-daemon``) is declared in the project's
``hostbootstrap.dhall`` and dispatched here.
"""

from __future__ import annotations

import asyncio
import shlex
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Final

import click
import httpx

from . import (
    base_image,
    dhall_tool,
    docker_ops,
    prereqs,
    process,
    spec,
    substrate,
    units,
)
from .base_image import Flavor
from .models import container as container_model
from .models import host_binary, host_daemon
from .spec import ContainerModel, HostBinaryModel, ProjectSpec, SpecError
from .substrate import Substrate, SubstrateName

_DEFAULT_SPEC_PATH: Final[Path] = Path("hostbootstrap.dhall")


def _load_spec(spec_path: Path) -> ProjectSpec:
    try:
        return spec.load(spec_path)
    except SpecError as exc:
        raise click.ClickException(str(exc)) from exc


def _detect_substrate() -> Substrate:
    try:
        return substrate.detect()
    except RuntimeError as exc:
        raise click.ClickException(str(exc)) from exc


def _base_context_value(build_base: bool, base_context: Path | None) -> Path | None:
    if not build_base:
        return None
    if base_context is None:
        raise click.ClickException(
            "--build-base requires --base-context pointing at the hostbootstrap repo"
        )
    return base_context


def _resolve_pull(build_base: bool, no_pull: bool) -> bool:
    """Decide whether ``docker build`` passes ``--pull`` for the base image.

    Default: ``--pull`` (refresh from Docker Hub). ``--build-base`` rebuilds
    the base locally and skips the pull. ``--no-pull`` reuses an existing
    locally-tagged base without rebuilding (useful after a separate
    ``hostbootstrap base build``).
    """
    if build_base and no_pull:
        raise click.ClickException(
            "--build-base and --no-pull are mutually exclusive; "
            "--build-base already skips the pull."
        )
    return not (build_base or no_pull)


async def _build(
    project_spec: ProjectSpec,
    sub: Substrate,
    project_root: Path,
    *,
    build_base: bool = False,
    base_context: Path | None = None,
    pull: bool = True,
) -> None:
    model = project_spec.model_for(sub)
    if isinstance(model, ContainerModel):
        await container_model.build(
            project_spec,
            model,
            sub,
            project_root=project_root,
            build_base=build_base,
            base_context=base_context,
            pull=pull,
        )
    elif isinstance(model, HostBinaryModel):
        await host_binary.build(
            project_spec,
            model,
            sub,
            project_root=project_root,
            build_base=build_base,
            base_context=base_context,
            pull=pull,
        )
    else:
        await host_daemon.build(
            project_spec,
            model,
            sub,
            project_root=project_root,
            build_base=build_base,
            base_context=base_context,
            pull=pull,
        )


async def _run(
    project_spec: ProjectSpec,
    sub: Substrate,
    project_root: Path,
    args: Sequence[str],
    *,
    build_base: bool = False,
    base_context: Path | None = None,
    pull: bool = True,
) -> process.CommandResult:
    model = project_spec.model_for(sub)
    if isinstance(model, ContainerModel):
        return await container_model.run_one_shot(
            project_spec,
            model,
            sub,
            args,
            project_root=project_root,
            build_base=build_base,
            base_context=base_context,
            pull=pull,
        )
    if isinstance(model, HostBinaryModel):
        return await host_binary.run_one_shot(
            project_spec,
            model,
            sub,
            args,
            project_root=project_root,
            build_base=build_base,
            base_context=base_context,
            pull=pull,
        )
    return await host_daemon.run_one_shot(
        project_spec,
        model,
        sub,
        args,
        project_root=project_root,
        build_base=build_base,
        base_context=base_context,
        pull=pull,
    )


async def _cluster_up(
    project_spec: ProjectSpec,
    sub: Substrate,
    project_root: Path,
    *,
    build_base: bool = False,
    base_context: Path | None = None,
    pull: bool = True,
) -> None:
    model = project_spec.model_for(sub)
    if isinstance(model, ContainerModel):
        if model.service:
            await container_model.start_service(
                project_spec,
                model,
                sub,
                project_root=project_root,
                build_base=build_base,
                base_context=base_context,
                pull=pull,
            )
            click.echo(f"started service container {project_spec.project!r} (unless-stopped).")
        else:
            await container_model.build(
                project_spec,
                model,
                sub,
                project_root=project_root,
                build_base=build_base,
                base_context=base_context,
                pull=pull,
            )
            click.echo("built project image; invoke one-shot work with `hostbootstrap run …`.")
    elif isinstance(model, HostBinaryModel):
        await host_binary.build(
            project_spec,
            model,
            sub,
            project_root=project_root,
            build_base=build_base,
            base_context=base_context,
            pull=pull,
        )
        cmd = host_binary.resolve_command(model.handoff.up, project_root)
        await process.run_checked(list(cmd), cwd=project_root)
    else:
        await host_daemon.build(
            project_spec,
            model,
            sub,
            project_root=project_root,
            build_base=build_base,
            base_context=base_context,
            pull=pull,
        )
        cmd = host_daemon.daemon_command(model, project_root=project_root)
        if project_spec.development:
            click.echo("development mode: skipped host-daemon system unit creation.")
            click.echo(f"daemon command: {shlex.join(cmd)}")
        else:
            unit_path = await units.ensure(project_spec.project, cmd, project_root)
            click.echo(f"ensured host-daemon unit {unit_path}.")


async def _cluster_down(project_spec: ProjectSpec, sub: Substrate, project_root: Path) -> None:
    model = project_spec.model_for(sub)
    if isinstance(model, ContainerModel):
        await container_model.stop_service(project_spec)
    elif isinstance(model, HostBinaryModel):
        cmd = host_binary.resolve_command(model.handoff.down, project_root)
        await process.run_checked(list(cmd), cwd=project_root)
    elif project_spec.development:
        click.echo("development mode: skipped host-daemon system unit removal.")
    else:
        await units.remove(project_spec.project)


async def _cluster_delete(project_spec: ProjectSpec, sub: Substrate, project_root: Path) -> None:
    model = project_spec.model_for(sub)
    if isinstance(model, ContainerModel):
        await container_model.stop_service(project_spec)
    elif isinstance(model, HostBinaryModel):
        raw = model.handoff.delete if model.handoff.delete is not None else model.handoff.down
        cmd = host_binary.resolve_command(raw, project_root)
        await process.run_checked(list(cmd), cwd=project_root)
    elif project_spec.development:
        click.echo("development mode: skipped host-daemon system unit removal.")
    else:
        await units.remove(project_spec.project)


# ---------------------------------------------------------------------------
# Friendly error handler
# ---------------------------------------------------------------------------


_DOCKER_STDERR_PATTERNS: Final[tuple[tuple[str, str], ...]] = (
    (
        "tag does not exist",
        "image not built locally — run `hostbootstrap base build-and-push` "
        "to build and push it.",
    ),
    (
        "denied: requested access",
        "not authenticated with the registry — run `docker login` and retry.",
    ),
    (
        "unauthorized",
        "not authenticated with the registry — run `docker login` and retry.",
    ),
    (
        "cannot connect to the docker daemon",
        "docker daemon not reachable — start Docker Desktop / colima and retry.",
    ),
    (
        "is the docker daemon running",
        "docker daemon not reachable — start Docker Desktop / colima and retry.",
    ),
)


def _format_command_error(exc: process.CommandError) -> str:
    result = exc.result
    stderr_lower = result.stderr.lower()
    argv0 = result.args[0] if result.args else "command"
    for needle, message in _DOCKER_STDERR_PATTERNS:
        if needle in stderr_lower:
            return message
    summary = " ".join(result.args[:3])
    if len(result.args) > 3:
        summary += " …"
    return (
        f"`{summary}` failed (exit {result.returncode}); " f"see {argv0} output above for details."
    )


_MISSING_BINARY_HINTS: Final[dict[str, str]] = {
    "docker": "`docker` not found in PATH — install Docker and retry.",
    "sudo": "`sudo` not found in PATH — required for host operations.",
    "systemctl": "`systemctl` not found in PATH — host-daemon support requires systemd.",
    "launchctl": "`launchctl` not found in PATH — host-daemon support requires macOS launchd.",
    "nvidia-smi": "`nvidia-smi` not found in PATH — install the NVIDIA driver.",
}


def _format_file_not_found(exc: FileNotFoundError) -> str | None:
    name = exc.filename
    if isinstance(name, bytes):
        name = name.decode("utf-8", errors="replace")
    if not name:
        return None
    base = Path(name).name
    hint = _MISSING_BINARY_HINTS.get(base)
    if hint is not None:
        return hint
    return None


def _format_http_error(exc: httpx.HTTPError) -> str:
    try:
        request = exc.request
    except RuntimeError:
        request = None
    url = str(request.url) if request is not None else None
    where = f" reaching {url}" if url else ""
    return f"network error{where}: {exc}"


def _format_runtime_error(exc: BaseException) -> str:
    if isinstance(exc, KeyError):
        return f"unsupported value: {exc.args[0]!r}"
    return str(exc) or exc.__class__.__name__


class _FriendlyGroup(click.Group):
    """Click group that converts known exception types to ``ClickException``.

    Why: a bare ``CommandError`` / ``httpx.HTTPError`` / ``UnitError`` /
    ``DhallToolError`` / ``RuntimeError`` from deep in the stack would otherwise
    surface to the user as a Python traceback. Click prints ``ClickException``
    as ``Error: <msg>`` with no traceback and a non-zero exit.
    """

    def invoke(self, ctx: click.Context) -> object:
        try:
            return super().invoke(ctx)
        except click.ClickException:
            raise
        except click.exceptions.Exit:
            raise
        except process.CommandError as exc:
            raise click.ClickException(_format_command_error(exc)) from exc
        except FileNotFoundError as exc:
            message = _format_file_not_found(exc)
            if message is None:
                raise
            raise click.ClickException(message) from exc
        except httpx.HTTPError as exc:
            raise click.ClickException(_format_http_error(exc)) from exc
        except units.UnitError as exc:
            raise click.ClickException(str(exc)) from exc
        except dhall_tool.DhallToolError as exc:
            raise click.ClickException(str(exc)) from exc
        except (RuntimeError, KeyError) as exc:
            raise click.ClickException(_format_runtime_error(exc)) from exc


# ---------------------------------------------------------------------------
# Click app
# ---------------------------------------------------------------------------

_SPEC_OPTION = click.option(
    "--spec",
    "spec_path",
    type=click.Path(path_type=Path),
    default=_DEFAULT_SPEC_PATH,
    show_default=True,
    help="Path to the project's hostbootstrap.dhall",
)

_BUILD_BASE_OPTION = click.option(
    "--build-base",
    is_flag=True,
    help="Build the selected base image locally first and do not pull it from Docker Hub.",
)

_BASE_CONTEXT_OPTION = click.option(
    "--base-context",
    type=click.Path(path_type=Path),
    default=None,
    help="Hostbootstrap repo root to use with --build-base.",
)

_NO_PULL_OPTION = click.option(
    "--no-pull",
    is_flag=True,
    help=(
        "Do not pull the base image from Docker Hub. Use the locally-tagged "
        "image as-is (e.g. one previously built with `hostbootstrap base build`)."
    ),
)


@click.group(cls=_FriendlyGroup, context_settings={"help_option_names": ["-h", "--help"]})
@click.version_option(package_name="hostbootstrap")
def main() -> None:
    """Host-installed CLI for the hostbootstrap base images."""


@main.command()
@_SPEC_OPTION
def doctor(spec_path: Path) -> None:
    """Detect substrate; validate + idempotently install host prerequisites."""
    project_spec = _load_spec(spec_path)
    sub = _detect_substrate()
    try:
        result = prereqs.run_doctor_sync(project_spec, sub)
    except prereqs.PrereqError as exc:
        raise click.ClickException(str(exc)) from exc
    click.echo(f"substrate: {result.substrate.name.value} ({result.substrate.arch})")
    for message in result.messages:
        click.echo(f"  - {message}")
    if result.reboot_required:
        click.echo("reboot required; re-run `hostbootstrap doctor` after rebooting.")
        sys.exit(1)


@main.command()
@_SPEC_OPTION
@_BUILD_BASE_OPTION
@_BASE_CONTEXT_OPTION
@_NO_PULL_OPTION
def build(
    spec_path: Path,
    build_base: bool,
    base_context: Path | None,
    no_pull: bool,
) -> None:
    """Idempotently build the project artifact for the current substrate."""
    project_spec = _load_spec(spec_path)
    sub = _detect_substrate()
    project_root = spec_path.resolve().parent
    asyncio.run(
        _build(
            project_spec,
            sub,
            project_root,
            build_base=build_base,
            base_context=_base_context_value(build_base, base_context),
            pull=_resolve_pull(build_base, no_pull),
        )
    )


@main.group(cls=_FriendlyGroup)
def cluster() -> None:
    """Cluster lifecycle: up, down, delete."""


@cluster.command("up")
@_SPEC_OPTION
@_BUILD_BASE_OPTION
@_BASE_CONTEXT_OPTION
@_NO_PULL_OPTION
def cluster_up(
    spec_path: Path,
    build_base: bool,
    base_context: Path | None,
    no_pull: bool,
) -> None:
    """Bring the whole stack to running (idempotent)."""
    project_spec = _load_spec(spec_path)
    sub = _detect_substrate()
    project_root = spec_path.resolve().parent
    asyncio.run(
        _cluster_up(
            project_spec,
            sub,
            project_root,
            build_base=build_base,
            base_context=_base_context_value(build_base, base_context),
            pull=_resolve_pull(build_base, no_pull),
        )
    )


@cluster.command("down")
@_SPEC_OPTION
def cluster_down(spec_path: Path) -> None:
    """Tear the cluster down; never deletes host .data."""
    project_spec = _load_spec(spec_path)
    sub = _detect_substrate()
    project_root = spec_path.resolve().parent
    asyncio.run(_cluster_down(project_spec, sub, project_root))
    click.echo("cluster down: host .data preserved.")


@cluster.command("delete")
@_SPEC_OPTION
def cluster_delete(spec_path: Path) -> None:
    """Thorough teardown (cluster + derived state); still never deletes .data."""
    project_spec = _load_spec(spec_path)
    sub = _detect_substrate()
    project_root = spec_path.resolve().parent
    asyncio.run(_cluster_delete(project_spec, sub, project_root))
    click.echo("cluster delete: derived state removed; host .data preserved.")


@main.command(context_settings={"allow_interspersed_args": False})
@_SPEC_OPTION
@_BUILD_BASE_OPTION
@_BASE_CONTEXT_OPTION
@_NO_PULL_OPTION
@click.argument("args", nargs=-1)
def run(
    spec_path: Path,
    build_base: bool,
    base_context: Path | None,
    no_pull: bool,
    args: tuple[str, ...],
) -> None:
    """Build if needed, then pass ``args`` to the project entrypoint."""
    project_spec = _load_spec(spec_path)
    sub = _detect_substrate()
    project_root = spec_path.resolve().parent
    asyncio.run(
        _run(
            project_spec,
            sub,
            project_root,
            args,
            build_base=build_base,
            base_context=_base_context_value(build_base, base_context),
            pull=_resolve_pull(build_base, no_pull),
        )
    )


# ---------------------------------------------------------------------------
# base build-and-push
# ---------------------------------------------------------------------------


@main.group(cls=_FriendlyGroup)
def base() -> None:
    """Produce/publish the four ``basecontainer-<flavor>-<arch>`` tags."""


def _arch_default() -> str:
    return substrate.detect().arch


async def _build_then_push(build_spec: docker_ops.BuildSpec, tag: str) -> None:
    await docker_ops.build(build_spec)
    await docker_ops.push(tag)


def _run_self_check_or_abort(context: Path) -> None:
    """Run hostbootstrap's own ruff/black/mypy gate before building the base.

    The base image build flow MUST NOT publish source with style or type
    errors. We shell out to ``poetry run python -m hostbootstrap.check_code``
    in the build context (the hostbootstrap repo checkout) so the check runs
    against Poetry's development venv — ruff, black, and mypy are dev-only
    dependencies and are not available in the pipx-installed CLI's own venv.
    See documents/engineering/code_check_doctrine.md.
    """
    try:
        completed = subprocess.run(
            ["poetry", "run", "python", "-m", "hostbootstrap.check_code"],
            cwd=context,
            check=False,
        )
    except FileNotFoundError as exc:
        raise click.ClickException(
            "self-check requires `poetry` on PATH; install Poetry and retry "
            "(see hostbootstrap README)."
        ) from exc
    if completed.returncode != 0:
        raise click.ClickException(
            "self-check failed; fix with "
            "`poetry run python -m hostbootstrap.check_code` and retry."
        )


def _base_targets(flavor: str | None) -> tuple[Flavor, ...]:
    if flavor is None:
        return (Flavor.CPU, Flavor.CUDA)
    return (Flavor(flavor),)


_BASE_FLAVOR_OPTION = click.option(
    "--flavor",
    type=click.Choice([f.value for f in Flavor]),
    default=None,
    help="Base image flavor to build; omit to build both cpu and cuda.",
)

_BASE_ARCH_OPTION = click.option(
    "--arch",
    type=click.Choice(["amd64", "arm64"]),
    default=None,
    help="Target arch; defaults to the host arch.",
)

_BASE_CONTEXT_BUILD_OPTION = click.option(
    "--context",
    type=click.Path(path_type=Path),
    default=Path.cwd(),
    show_default=True,
    help="Build context root (the hostbootstrap repo).",
)


@base.command("build")
@_BASE_FLAVOR_OPTION
@_BASE_ARCH_OPTION
@_BASE_CONTEXT_BUILD_OPTION
def base_build(flavor: str | None, arch: str | None, context: Path) -> None:
    """Cold-rebuild base image(s) locally (``--no-cache --pull``); no push.

    For local validation: rebuilds the base image from scratch and leaves it
    tagged in the local Docker daemon. Use this before ``hostbootstrap build
    --build-base`` to validate downstream projects against an unpublished
    base.
    """
    _run_self_check_or_abort(context)
    target_arch = arch or _arch_default()
    for flavor_enum in _base_targets(flavor):
        build_spec, _ = base_image.build_spec_for(
            flavor_enum,
            target_arch,
            context=context,
            pull=True,
            no_cache=True,
        )
        tag = base_image.base_image_ref(flavor_enum, target_arch)
        asyncio.run(docker_ops.build(build_spec))
        click.echo(f"built {tag}")


@base.command("build-and-push")
@_BASE_FLAVOR_OPTION
@_BASE_ARCH_OPTION
@_BASE_CONTEXT_BUILD_OPTION
def base_build_and_push(flavor: str | None, arch: str | None, context: Path) -> None:
    """Cold-rebuild base image(s) (``--no-cache --pull``) and push them.

    The publish path is always cold so the registry copy matches a clean
    rebuild from source — no silent layer-cache carryover.
    """
    _run_self_check_or_abort(context)
    target_arch = arch or _arch_default()
    for flavor_enum in _base_targets(flavor):
        build_spec, _ = base_image.build_spec_for(
            flavor_enum,
            target_arch,
            context=context,
            pull=True,
            no_cache=True,
        )
        tag = base_image.base_image_ref(flavor_enum, target_arch)
        asyncio.run(_build_then_push(build_spec, tag))
        click.echo(f"built and pushed {tag}")


_ = SubstrateName  # re-exported for downstream importers


if __name__ == "__main__":
    main()
