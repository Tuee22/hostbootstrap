"""Docker command builders and async runners.

Pure functions assemble the argument lists (so they are trivially testable and
re-orderable); the runners just hand the result to :mod:`hostbootstrap.process`.
"""

from __future__ import annotations

import json
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from . import process
from .substrate import Arch, parse_arch

_DOCKER: Final[str] = "docker"

# Per-build resource caps are only honoured by the classic (non-BuildKit) builder
# — `docker buildx build` rejects `--memory`/`--cpu-*`. The repo already mandates
# plain single-arch `docker build` (no buildx; see base_image.md), so when a build
# carries a resource budget we force the classic builder via this env. The classic
# builder has no `--cpus`; we express the same cap with a CFS quota over a fixed
# 100 ms period (quota = cpus * period), exactly how `--cpus` is implemented.
_BUILDKIT_OFF_ENV: Final[dict[str, str]] = {"DOCKER_BUILDKIT": "0"}
_CPU_PERIOD_US: Final[int] = 100_000


@dataclass(frozen=True)
class BuildKitBuilder:
    """The default builder.

    It rejects ``--memory``/``--cpu-*`` outright, so it carries no resource caps
    and there is no field on which to request one.
    """


@dataclass(frozen=True)
class ClassicBuilder:
    """The non-BuildKit builder, and the only one that honours per-build caps.

    A cap is optional here, but it is *only* expressible here. That is the whole
    point of the split: a build could previously carry ``memory``/``cpus``
    alongside a builder flag that decided whether they were honoured at all, so a
    silently ignored resource request was a representable state.
    """

    memory: str | None = None
    memory_swap: str | None = None
    cpus: str | None = None


#: Which builder runs a ``docker build``, and — for the one that honours them —
#: the caps it runs under. The two cases are the two builders Docker has.
Builder = BuildKitBuilder | ClassicBuilder


@dataclass(frozen=True)
class BuildSpec:
    """Inputs for a ``docker build`` invocation.

    ``build_args`` becomes one ``--build-arg KEY=VALUE`` flag per entry, in the
    iteration order of the mapping; ``tags`` becomes one ``--tag`` flag per tag.
    """

    dockerfile: Path
    context: Path
    tags: tuple[str, ...]
    build_args: Mapping[str, str]
    target: str | None = None
    pull: bool = True
    no_cache: bool = False
    builder: Builder = BuildKitBuilder()


def build_command(spec: BuildSpec) -> tuple[str, ...]:
    cmd: list[str] = [_DOCKER, "build"]
    for key, value in spec.build_args.items():
        cmd.extend(["--build-arg", f"{key}={value}"])
    for tag in spec.tags:
        cmd.extend(["--tag", tag])
    if spec.target is not None:
        cmd.extend(["--target", spec.target])
    if spec.pull:
        cmd.append("--pull")
    if spec.no_cache:
        cmd.append("--no-cache")
    if isinstance(spec.builder, ClassicBuilder):
        if spec.builder.memory is not None:
            cmd.extend(["--memory", spec.builder.memory])
        if spec.builder.memory_swap is not None:
            cmd.extend(["--memory-swap", spec.builder.memory_swap])
        if spec.builder.cpus is not None:
            quota = int(float(spec.builder.cpus) * _CPU_PERIOD_US)
            cmd.extend(["--cpu-period", str(_CPU_PERIOD_US), "--cpu-quota", str(quota)])
    cmd.extend(["--file", spec.dockerfile.as_posix()])
    cmd.append(spec.context.as_posix())
    return tuple(cmd)


def push_command(tag: str) -> tuple[str, ...]:
    return (_DOCKER, "push", tag)


def pull_command(reference: str) -> tuple[str, ...]:
    return (_DOCKER, "pull", reference)


def engine_arch_command() -> tuple[str, ...]:
    return (_DOCKER, "info", "--format", "{{.Architecture}}")


def image_repo_digests_command(tag: str) -> tuple[str, ...]:
    return (_DOCKER, "image", "inspect", "--format", "{{json .RepoDigests}}", tag)


def image_id_command(tag: str) -> tuple[str, ...]:
    return (_DOCKER, "image", "inspect", "--format", "{{.Id}}", tag)


def normalize_architecture(value: str) -> Arch:
    """Read the Docker engine's own architecture answer into the closed value."""
    arch = parse_arch(value)
    if arch is None:
        raise RuntimeError(f"unsupported Docker architecture: {value.strip()!r}")
    return arch


def parse_digest_reference(rendered: str, *, tag: str) -> str:
    try:
        raw: object = json.loads(rendered.strip())
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"could not parse Docker RepoDigests for {tag!r}") from exc
    if not isinstance(raw, list):
        raise RuntimeError(f"unexpected Docker RepoDigests for {tag!r}")

    last_slash = tag.rfind("/")
    last_colon = tag.rfind(":")
    repository = tag[:last_colon] if last_colon > last_slash else tag

    def docker_repository_name(value: str) -> str:
        for prefix in ("docker.io/", "index.docker.io/"):
            if value.startswith(prefix):
                return value.removeprefix(prefix)
        return value

    expected_repository = docker_repository_name(repository)
    matches = [
        value
        for value in raw
        if isinstance(value, str)
        and "@sha256:" in value
        and docker_repository_name(value.split("@", 1)[0]) == expected_repository
        and re.fullmatch(r"[0-9a-f]{64}", value.split("@sha256:", 1)[1]) is not None
    ]
    if len(matches) != 1:
        raise RuntimeError(
            f"expected exactly one pulled repository digest for {tag!r}, got {matches!r}"
        )
    digest = matches[0].split("@", 1)[1]
    return f"{repository}@{digest}"


def parse_image_id(rendered: str, *, tag: str) -> str:
    image_id = rendered.strip()
    if re.fullmatch(r"sha256:[0-9a-f]{64}", image_id) is None:
        raise RuntimeError(f"unexpected Docker image ID for {tag!r}: {image_id!r}")
    return image_id


async def build(spec: BuildSpec, *, prefix: str = "") -> process.CommandResult:
    env = _BUILDKIT_OFF_ENV if isinstance(spec.builder, ClassicBuilder) else None
    return await process.run_checked(build_command(spec), prefix=prefix, env=env)


async def push(tag: str, *, prefix: str = "") -> process.CommandResult:
    return await process.run_checked(push_command(tag), prefix=prefix)


async def pull(reference: str, *, prefix: str = "") -> process.CommandResult:
    return await process.run_checked(pull_command(reference), prefix=prefix)


async def engine_arch() -> Arch:
    result = await process.run_checked(engine_arch_command(), quiet=True)
    return normalize_architecture(result.stdout)


async def image_digest_reference(tag: str) -> str:
    result = await process.run_checked(image_repo_digests_command(tag), quiet=True)
    return parse_digest_reference(result.stdout, tag=tag)


async def image_id(tag: str) -> str:
    result = await process.run_checked(image_id_command(tag), quiet=True)
    return parse_image_id(result.stdout, tag=tag)
