"""``hostbootstrap`` Click application.

The single entrypoint installed on every downstream host (via
``pipx install "hostbootstrap @ git+…"``). The surface is thin: ``doctor`` asserts the fail-fast
host minimums; ``build`` runs the pre-binary bootstrapper (assert minimums →
ensure the host build toolchain → build the binary host-native) without exec'ing;
``run`` does the same and then execs the binary with the forwarded args; ``update``
explicitly updates the pipx-installed wrapper. The maintainer commands ``base``
(``base build`` / ``base build-and-push``, producing the ``basecontainer-<flavor>-<arch>``
tags), ``check-code``, and ``test-all`` need the dev toolchain and are registered only
in a Poetry development install — they are hidden from the pipx-installed CLI (see
``_maintainer_cli_enabled``). Ensuring Docker,
building the project container, and cordoning are the project binary's job; all
richer host-management logic lives in ``hostbootstrap-core`` and runs through the
execed project binary.
"""

from __future__ import annotations

import asyncio
import importlib.util
import subprocess
import sys
import tomllib
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Final

import click
import httpx

from . import (
    base_image,
    bootstrap,
    check_code,
    docker_ops,
    prereqs,
    process,
    resources,
    self_update,
    substrate,
    test_all,
)
from .base_image import Flavor
from .substrate import Substrate

_DEFAULT_PROJECT_ROOT: Final[Path] = Path(".")


def _load_project(
    project_root: Path, *, selected_cabal_file: Path | None = None
) -> bootstrap.ProjectBuildSpec:
    try:
        return bootstrap.discover_project(project_root, selected_cabal_file=selected_cabal_file)
    except bootstrap.ProjectDiscoveryError as exc:
        raise click.ClickException(str(exc)) from exc


def _detect_substrate() -> Substrate:
    try:
        return substrate.detect()
    except RuntimeError as exc:
        raise click.ClickException(str(exc)) from exc


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
    """Click group that converts known exception types to ``ClickException``."""

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
        except (RuntimeError, KeyError) as exc:
            raise click.ClickException(_format_runtime_error(exc)) from exc


# ---------------------------------------------------------------------------
# Maintainer-only command gating
# ---------------------------------------------------------------------------

_MAINTAINER_TOOLCHAIN: Final[tuple[str, ...]] = ("ruff", "black", "mypy", "pytest")
_MAINTAINER_COMMANDS: Final[frozenset[str]] = frozenset({"base", "check-code", "test-all"})
_MAINTAINER_TOKEN: Final[object] = object()


@dataclass(frozen=True, init=False)
class MaintainerCommandAuthority:
    """Opaque proof that parser construction runs in this checkout's Poetry venv."""

    repository_root: Path

    def __init__(self, repository_root: Path, token: object) -> None:
        if token is not _MAINTAINER_TOKEN:
            raise TypeError("MaintainerCommandAuthority is minted only by repository validation")
        object.__setattr__(self, "repository_root", repository_root)


def _maintainer_command_authority() -> MaintainerCommandAuthority | None:
    """Validate source checkout, in-project Poetry interpreter, and dev group."""
    repository_root = Path(__file__).resolve().parent.parent
    expected_venv = (repository_root / ".venv").resolve()
    try:
        prefix = Path(sys.prefix).resolve()
        executable = Path(sys.executable).absolute()
        pyproject = tomllib.loads((repository_root / "pyproject.toml").read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError):
        return None
    poetry = pyproject.get("tool", {}).get("poetry", {})
    valid = (
        isinstance(poetry, dict)
        and poetry.get("name") == "hostbootstrap"
        and (repository_root / ".git").exists()
        and (repository_root / "poetry.lock").is_file()
        and prefix == expected_venv
        and sys.prefix != sys.base_prefix
        and executable.is_relative_to(prefix)
        and all(importlib.util.find_spec(name) is not None for name in _MAINTAINER_TOOLCHAIN)
    )
    if not valid:
        return None
    return MaintainerCommandAuthority(repository_root, _MAINTAINER_TOKEN)


def _maintainer_cli_enabled() -> bool:
    return _maintainer_command_authority() is not None


def _require_maintainer_authority() -> MaintainerCommandAuthority:
    authority = _maintainer_command_authority()
    if authority is None:
        raise click.ClickException(
            "maintainer commands require this repository's in-project Poetry development environment"
        )
    return authority


class _MainGroup(_FriendlyGroup):
    """Top-level group that hides the maintainer commands outside a dev install."""

    def list_commands(self, ctx: click.Context) -> list[str]:
        names = super().list_commands(ctx)
        if _maintainer_cli_enabled():
            return names
        return [name for name in names if name not in _MAINTAINER_COMMANDS]

    def get_command(self, ctx: click.Context, cmd_name: str) -> click.Command | None:
        if cmd_name in _MAINTAINER_COMMANDS and not _maintainer_cli_enabled():
            return None
        return super().get_command(ctx, cmd_name)


# ---------------------------------------------------------------------------
# Click app
# ---------------------------------------------------------------------------

_PROJECT_ROOT_OPTION = click.option(
    "--project-root",
    "project_root",
    type=click.Path(path_type=Path),
    default=_DEFAULT_PROJECT_ROOT,
    show_default=True,
    help="Project root containing exactly one .cabal file",
)

_CABAL_FILE_OPTION = click.option(
    "--cabal-file",
    "selected_cabal_file",
    type=click.Path(path_type=Path),
    default=None,
    help="Cabal file to select explicitly when the project root contains more than one.",
)

_OFFLINE_OPTION = click.option(
    "--offline",
    is_flag=True,
    default=False,
    help="Use only the cached Cabal index/store; perform no package-index update.",
)


@click.group(cls=_MainGroup, context_settings={"help_option_names": ["-h", "--help"]})
@click.version_option(package_name="hostbootstrap")
def main() -> None:
    """Host-installed CLI for the hostbootstrap base images."""


@main.command()
def doctor() -> None:
    """Detect the substrate and assert the fail-fast host minimums."""
    sub = _detect_substrate()
    try:
        result = prereqs.run_doctor_sync(sub)
    except prereqs.PrereqError as exc:
        raise click.ClickException(str(exc)) from exc
    click.echo(f"substrate: {result.substrate.name.value} ({result.substrate.arch})")
    for message in result.messages:
        click.echo(f"  - {message}")
    if result.reboot_required:
        click.echo("reboot required; re-run `hostbootstrap doctor` after rebooting.")
        sys.exit(1)


@main.command()
@_PROJECT_ROOT_OPTION
@_CABAL_FILE_OPTION
@_OFFLINE_OPTION
def build(project_root: Path, selected_cabal_file: Path | None, offline: bool) -> None:
    """Build the project binary host-native into ``./.build/`` (no exec)."""
    root = project_root.resolve()
    project = _load_project(root, selected_cabal_file=selected_cabal_file)
    binary = asyncio.run(bootstrap.build_binary(project, project_root=root, offline=offline))
    click.echo(f"built {binary}")


@main.command(context_settings={"allow_interspersed_args": False})
@_PROJECT_ROOT_OPTION
@_CABAL_FILE_OPTION
@_OFFLINE_OPTION
@click.argument("args", nargs=-1)
def run(
    project_root: Path,
    selected_cabal_file: Path | None,
    offline: bool,
    args: tuple[str, ...],
) -> None:
    """Build idempotently, then exec the project binary with ``args``."""
    root = project_root.resolve()
    project = _load_project(root, selected_cabal_file=selected_cabal_file)
    asyncio.run(
        bootstrap.bootstrap(
            project,
            project_root=root,
            args=args,
            offline=offline,
        )
    )


@main.command("update")
@click.option(
    "--ref",
    "ref",
    default=self_update.DEFAULT_REF,
    show_default=True,
    help="Git ref in the canonical hostbootstrap repository.",
)
@click.option(
    "--spec",
    "spec",
    default=None,
    help="Explicit pip requirement spec to install instead of the canonical repository ref.",
)
@click.option(
    "--check",
    "check_only",
    is_flag=True,
    help="Check the installed VCS commit against the remote ref without updating.",
)
@click.pass_context
def update_cli(ctx: click.Context, ref: str, spec: str | None, check_only: bool) -> None:
    """Explicitly update the pipx-installed Python bootstrapper."""
    ref_was_explicit = ctx.get_parameter_source("ref") is not click.core.ParameterSource.DEFAULT
    if spec is not None and ref_was_explicit:
        raise click.ClickException("`--spec` cannot be combined with `--ref`.")
    if check_only and spec is not None:
        raise click.ClickException("`--check` cannot be combined with `--spec`.")
    try:
        if check_only:
            status = self_update.check_status(ref=ref)
            installed = status.installed_commit[:12]
            remote = status.remote_commit[:12]
            if status.up_to_date:
                click.echo(f"hostbootstrap up to date ({installed})")
                return
            click.echo(f"hostbootstrap update available: installed {installed}, remote {remote}")
            sys.exit(1)
        install_spec = self_update.run_update(ref=ref, spec=spec)
    except self_update.SelfUpdateError as exc:
        raise click.ClickException(str(exc)) from exc
    click.echo(f"updated hostbootstrap from {install_spec}")


# ---------------------------------------------------------------------------
# base build-and-push
# ---------------------------------------------------------------------------


@main.group(cls=_FriendlyGroup)
def base() -> None:
    """Produce/publish the four ``basecontainer-<flavor>-<arch>`` tags."""


def _arch_default() -> str:
    return substrate.detect().arch


async def _build_then_publish(
    build_spec: docker_ops.BuildSpec,
    tag: str,
    flavor: Flavor,
    arch: str,
    context: Path,
    *,
    prefix: str = "",
) -> str:
    """Build/push/pull a rolling tag, then run the real consumer smoke."""
    await docker_ops.build(build_spec, prefix=prefix)
    await docker_ops.push(tag, prefix=prefix)
    await docker_ops.pull(tag, prefix=prefix)
    digest_reference = await docker_ops.image_digest_reference(tag)
    validation = base_image.compatibility_smoke_spec(
        flavor,
        arch,
        context=context,
        pulled_reference=digest_reference,
    )
    await docker_ops.build(validation, prefix=prefix)
    return digest_reference


@dataclass(frozen=True)
class _QualityGate:
    label: str
    command: tuple[str, ...]
    cwd: Path


def _quality_gates(context: Path) -> tuple[_QualityGate, ...]:
    return (
        _QualityGate(
            "Python code check",
            (sys.executable, "-m", "hostbootstrap.check_code"),
            context,
        ),
        _QualityGate(
            "Python tests",
            (sys.executable, "-m", "hostbootstrap.test_all"),
            context,
        ),
        _QualityGate(
            "core Haskell build",
            ("cabal", "build", "all", "--ghc-options=-Werror"),
            context / "core",
        ),
        _QualityGate(
            "core Haskell tests",
            ("cabal", "test", "all", "--ghc-options=-Werror"),
            context / "core",
        ),
        _QualityGate(
            "demo Haskell build",
            ("cabal", "build", "all", "--ghc-options=-Werror"),
            context / "demo",
        ),
        _QualityGate(
            "demo Haskell tests",
            ("cabal", "test", "all", "--ghc-options=-Werror"),
            context / "demo",
        ),
    )


def _run_quality_gates_or_abort(context: Path, authority: MaintainerCommandAuthority) -> None:
    """Complete every repository source gate before the first Docker build."""
    resolved = context.resolve()
    if resolved != authority.repository_root:
        raise click.ClickException(
            f"{resolved} is not the canonical checkout for this maintainer interpreter "
            f"({authority.repository_root})"
        )
    for gate in _quality_gates(resolved):
        completed = subprocess.run(list(gate.command), cwd=gate.cwd, check=False)
        if completed.returncode != 0:
            raise click.ClickException(
                f"{gate.label} failed (exit {completed.returncode}); "
                "no base image was built or pushed."
            )


async def _validate_native_architecture(requested_arch: str, host_arch: str) -> None:
    engine_arch = await docker_ops.engine_arch()
    if requested_arch != host_arch or requested_arch != engine_arch:
        raise click.ClickException(
            "base architecture must be native: "
            f"requested={requested_arch}, host={host_arch}, Docker engine={engine_arch}; "
            "buildx/emulation and cross-architecture tag publication are not supported"
        )


def _base_targets(flavor: str | None) -> tuple[Flavor, ...]:
    if flavor is None:
        return (Flavor.CPU, Flavor.CUDA)
    return (Flavor(flavor),)


def _resolve_build_budget(
    targets: tuple[Flavor, ...], *, sequential: bool
) -> resources.BuildBudget | None:
    """Measure host resources, abort if below floor, and size a per-build budget.

    Returns ``None`` off Linux (docker already runs inside a resource-bounded VM
    there), leaving the build unbounded as before. On Linux a below-floor host
    aborts the command; otherwise the host is split across however many flavors
    build concurrently so two simultaneous builds never sum past the host.
    """
    res = resources.detect_host_resources()
    if res is None:
        return None
    try:
        resources.assert_build_minimums(res)
    except resources.ResourceError as exc:
        raise click.ClickException(str(exc)) from exc
    concurrency = 1 if sequential or len(targets) <= 1 else len(targets)
    return resources.compute_build_budget(res, concurrency=concurrency)


def _base_work(
    flavor: str | None,
    target_arch: str,
    context: Path,
    *,
    budget: resources.BuildBudget | None,
) -> list[tuple[docker_ops.BuildSpec, str, Flavor]]:
    """Resolve the (build spec, tag, label) targets for one arch.

    The label is the flavor name (``cpu`` / ``cuda``) used to prefix that build's
    streamed output. With no ``--flavor`` this is both flavors; with one, a
    single target (so concurrency is moot). *budget*, when set, applies the
    docker memory/cpu caps and host-sized cabal ``-j`` to every target.
    """
    work: list[tuple[docker_ops.BuildSpec, str, Flavor]] = []
    for flavor_enum in _base_targets(flavor):
        build_spec, _ = base_image.build_spec_for(
            flavor_enum,
            target_arch,
            context=context,
            pull=True,
            no_cache=True,
            budget=budget,
        )
        tag = base_image.base_image_ref(flavor_enum, target_arch)
        work.append((build_spec, tag, flavor_enum))
    return work


async def _run_base_targets(
    work: Sequence[tuple[docker_ops.BuildSpec, str, Flavor]],
    *,
    publish: bool,
    sequential: bool,
    context: Path,
    arch: str,
) -> None:
    """Build locally or complete the publish→pull→digest→derived-build transaction.

    Concurrent by default — the cpu/cuda base builds are fully independent — with
    each build's streamed output line-prefixed ``[<label>]`` so the interleaved
    streams stay legible. ``--sequential`` (and the single-target case) runs them
    one at a time, preserving the original fail-fast behaviour. In the concurrent
    case both builds run to completion, then the first failure (if any) is
    re-raised so the friendly Docker-error translation still applies.
    """
    width = max((len(flavor.value) for _spec, _tag, flavor in work), default=0)

    async def _one(build_spec: docker_ops.BuildSpec, tag: str, flavor: Flavor) -> None:
        label = flavor.value
        prefix = f"[{label.ljust(width)}] "
        if publish:
            digest = await _build_then_publish(
                build_spec,
                tag,
                flavor,
                arch,
                context,
                prefix=prefix,
            )
            click.echo(f"{prefix}published and validated {digest}")
        else:
            await docker_ops.build(build_spec, prefix=prefix)
            click.echo(f"{prefix}built {tag} for base-image inspection only")

    if sequential or len(work) <= 1:
        for build_spec, tag, flavor in work:
            await _one(build_spec, tag, flavor)
        return

    outcomes = await asyncio.gather(
        *(_one(build_spec, tag, flavor) for build_spec, tag, flavor in work),
        return_exceptions=True,
    )
    for outcome in outcomes:
        if isinstance(outcome, BaseException):
            raise outcome


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

_BASE_SEQUENTIAL_OPTION = click.option(
    "--sequential",
    is_flag=True,
    default=False,
    help=(
        "Build flavors one at a time instead of concurrently "
        "(lower peak RAM/CPU/disk; only affects building both cpu and cuda)."
    ),
)


@base.command("build")
@_BASE_FLAVOR_OPTION
@_BASE_ARCH_OPTION
@_BASE_CONTEXT_BUILD_OPTION
@_BASE_SEQUENTIAL_OPTION
def base_build(flavor: str | None, arch: str | None, context: Path, sequential: bool) -> None:
    """Cold-rebuild base image(s) locally (``--no-cache --pull``); no push.

    For base-image inspection only: rebuilds from scratch and leaves the tag in
    the local Docker daemon. Derived projects must not consume it; compatibility
    validation follows ``build-and-push`` → pull → real-demo smoke. With no
    ``--flavor`` the cpu and cuda builds run concurrently (output line-prefixed
    ``[cpu]`` / ``[cuda]``); pass ``--sequential`` to build one at a time.
    """
    authority = _require_maintainer_authority()
    resolved_context = context.resolve()
    host_arch = _arch_default()
    target_arch = arch or host_arch
    asyncio.run(_validate_native_architecture(target_arch, host_arch))
    _run_quality_gates_or_abort(resolved_context, authority)
    budget = _resolve_build_budget(_base_targets(flavor), sequential=sequential)
    work = _base_work(flavor, target_arch, resolved_context, budget=budget)
    asyncio.run(
        _run_base_targets(
            work,
            publish=False,
            sequential=sequential,
            context=resolved_context,
            arch=target_arch,
        )
    )


@base.command("build-and-push")
@_BASE_FLAVOR_OPTION
@_BASE_ARCH_OPTION
@_BASE_CONTEXT_BUILD_OPTION
@_BASE_SEQUENTIAL_OPTION
def base_build_and_push(
    flavor: str | None, arch: str | None, context: Path, sequential: bool
) -> None:
    """Cold-rebuild base image(s) (``--no-cache --pull``) and push them.

    The publish path is always cold and intentionally discovers current
    compatible upstream inputs. With no ``--flavor``
    the cpu and cuda builds run concurrently (output line-prefixed ``[cpu]`` /
    ``[cuda]``); pass ``--sequential`` to build one at a time (lower peak
    resource use).
    """
    authority = _require_maintainer_authority()
    resolved_context = context.resolve()
    host_arch = _arch_default()
    target_arch = arch or host_arch
    asyncio.run(_validate_native_architecture(target_arch, host_arch))
    _run_quality_gates_or_abort(resolved_context, authority)
    budget = _resolve_build_budget(_base_targets(flavor), sequential=sequential)
    work = _base_work(flavor, target_arch, resolved_context, budget=budget)
    asyncio.run(
        _run_base_targets(
            work,
            publish=True,
            sequential=sequential,
            context=resolved_context,
            arch=target_arch,
        )
    )


# ---------------------------------------------------------------------------
# dev-only runners (check-code / test-all) — hidden outside a Poetry install
# ---------------------------------------------------------------------------


@main.command("check-code")
def check_code_command() -> None:
    """Run the Python code-check gate (ruff → black → mypy). Dev-only."""
    _require_maintainer_authority()
    raise SystemExit(check_code.main())


@main.command(
    "test-all",
    context_settings={"allow_interspersed_args": False, "ignore_unknown_options": True},
)
@click.argument("pytest_args", nargs=-1, type=click.UNPROCESSED)
def test_all_command(pytest_args: tuple[str, ...]) -> None:
    """Run the full pytest suite via the supported runner; forwards args to pytest. Dev-only."""
    _require_maintainer_authority()
    raise SystemExit(test_all.run(list(pytest_args)))


if __name__ == "__main__":
    main()
