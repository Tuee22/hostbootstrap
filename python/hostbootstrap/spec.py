"""Read the skeletal ``hostbootstrap.dhall`` into frozen dataclasses.

The schema is the skeletal Dhall package under ``dhall/`` — identical in shape
across every project and matching ``haskell/hostbootstrap-core/dhall/Type.dhall``
(``{ project, dockerfile, resources { cpu, memory, storage } }``). The
pre-binary Python layer decodes this tier itself because the base image bakes no
``hostbootstrap`` binary (a Linux ELF cannot run on Apple silicon); the
in-process Haskell decoder (``HostBootstrap.Config.Schema``) owns the rich
project/test tiers via the project binary.

Dhall's own type-checker enforces the record shape while rendering to JSON, so
by the time we narrow the output here the shape is already valid; this module
only maps the rendered JSON into dataclasses.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

from . import dhall_tool


class SpecError(RuntimeError):
    """Raised when ``hostbootstrap.dhall`` is missing or invalid."""


@dataclass(frozen=True)
class Resources:
    """The resource budget used to size the per-project cordon."""

    cpu: int
    memory: str
    storage: str


@dataclass(frozen=True)
class SkeletalSpec:
    """The one config tier the Python bootstrapper reads."""

    project: str
    dockerfile: Path
    resources: Resources
    source_path: Path


# ---------------------------------------------------------------------------
# JSON narrowing helpers (the rendered Dhall is plain JSON)
# ---------------------------------------------------------------------------


def _as_map(value: object, *, where: str) -> Mapping[str, object]:
    if not isinstance(value, dict):
        raise SpecError(f"{where}: expected an object, got {type(value).__name__}")
    return value


def _as_str(value: object, *, where: str) -> str:
    if not isinstance(value, str):
        raise SpecError(f"{where}: expected a string, got {type(value).__name__}")
    return value


def _as_int(value: object, *, where: str) -> int:
    # ``bool`` is a subclass of ``int``; reject it so a JSON ``true`` is not
    # silently read as a CPU count.
    if isinstance(value, bool) or not isinstance(value, int):
        raise SpecError(f"{where}: expected an integer, got {type(value).__name__}")
    return value


def load(path: Path) -> SkeletalSpec:
    if not path.is_file():
        raise SpecError(f"hostbootstrap.dhall not found at {path}")

    try:
        rendered = dhall_tool.to_json(path)
    except dhall_tool.DhallToolError as exc:
        raise SpecError(f"could not evaluate {path}: {exc}") from exc

    data = _as_map(rendered, where="<root>")
    resources = _as_map(data.get("resources"), where="resources")
    return SkeletalSpec(
        project=_as_str(data.get("project"), where="project"),
        dockerfile=Path(_as_str(data.get("dockerfile"), where="dockerfile")),
        resources=Resources(
            cpu=_as_int(resources.get("cpu"), where="resources.cpu"),
            memory=_as_str(resources.get("memory"), where="resources.memory"),
            storage=_as_str(resources.get("storage"), where="resources.storage"),
        ),
        source_path=path,
    )
