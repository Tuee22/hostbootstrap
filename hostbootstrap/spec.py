"""Parse and validate ``hostbootstrap.dhall`` into frozen dataclasses.

The schema is the Dhall package under ``dhall/`` (see
``documents/engineering/schema.md``). A project declares exactly one target per
hardware substrate. Each target chooses a lifecycle (``Cluster`` or
``NoCluster``) and an execution model (``Container`` / ``HostBinary`` /
``HostDaemon``). Dhall's type checker guarantees the per-model record shape;
this module maps rendered JSON into dataclasses and performs residual checks
such as duplicate substrate rejection.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path

from . import dhall_tool
from .substrate import Substrate, SubstrateName


class SpecError(RuntimeError):
    """Raised when ``hostbootstrap.dhall`` is missing or invalid."""


class Model(StrEnum):
    CONTAINER = "container"
    HOST_BINARY = "host-binary"
    HOST_DAEMON = "host-daemon"


class Lifecycle(StrEnum):
    CLUSTER = "cluster"
    NO_CLUSTER = "no-cluster"


@dataclass(frozen=True)
class Mount:
    host: str
    container: str
    read_only: bool = False


@dataclass(frozen=True)
class ContainerArtifact:
    dockerfile: Path


@dataclass(frozen=True)
class ContainerModel:
    """``model: container`` — build a thin image and run the project entrypoint."""

    dockerfile: Path
    mounts: tuple[Mount, ...]

    kind: Model = Model.CONTAINER


@dataclass(frozen=True)
class HostBinaryModel:
    """``model: host-binary`` — build a host binary and run the project command."""

    container: ContainerArtifact | None = None

    kind: Model = Model.HOST_BINARY


@dataclass(frozen=True)
class HostDaemonModel:
    """``model: host-daemon`` — host-binary cluster handoff plus a daemon process."""

    daemon: str
    container: ContainerArtifact | None = None

    kind: Model = Model.HOST_DAEMON


ModelSpec = ContainerModel | HostBinaryModel | HostDaemonModel


@dataclass(frozen=True)
class TargetSpec:
    lifecycle: Lifecycle
    model: ModelSpec


@dataclass(frozen=True)
class ResolvedTarget:
    """The substrate entry selected for this invocation."""

    substrate: SubstrateName
    lifecycle: Lifecycle
    model: ModelSpec


@dataclass(frozen=True)
class ProjectSpec:
    project: str
    targets: Mapping[SubstrateName, TargetSpec]
    source_path: Path

    def target_for(
        self,
        substrate: Substrate,
        *,
        force_target: SubstrateName | None = None,
    ) -> ResolvedTarget:
        """Select the detected substrate entry, or an explicit forced target."""
        target_name = substrate.name if force_target is None else force_target
        target = self.targets.get(target_name)
        if target is None:
            supported = ", ".join(sorted(name.value for name in self.targets))
            raise SpecError(
                f"no target declared for substrate {target_name.value!r}; "
                f"project supports [{supported}]"
            )
        return ResolvedTarget(
            substrate=target_name,
            lifecycle=target.lifecycle,
            model=target.model,
        )


# ---------------------------------------------------------------------------
# JSON narrowing helpers (the rendered Dhall is plain JSON)
# ---------------------------------------------------------------------------


def _as_map(value: object, *, where: str) -> Mapping[str, object]:
    if not isinstance(value, dict):
        raise SpecError(f"{where}: expected an object, got {type(value).__name__}")
    return value


def _as_list(value: object, *, where: str) -> Sequence[object]:
    if not isinstance(value, list):
        raise SpecError(f"{where}: expected a list, got {type(value).__name__}")
    return value


def _as_str(value: object, *, where: str) -> str:
    if not isinstance(value, str):
        raise SpecError(f"{where}: expected a string, got {type(value).__name__}")
    return value


def _as_bool(value: object, *, where: str) -> bool:
    if not isinstance(value, bool):
        raise SpecError(f"{where}: expected a boolean, got {type(value).__name__}")
    return value


def _substrate(value: object, *, where: str) -> SubstrateName:
    raw = _as_str(value, where=where)
    try:
        return SubstrateName(raw)
    except ValueError as exc:
        raise SpecError(f"{where}: unknown substrate {raw!r}") from exc


def _mount(value: object, *, where: str) -> Mount:
    mapping = _as_map(value, where=where)
    return Mount(
        host=_as_str(mapping.get("host"), where=f"{where}.host"),
        container=_as_str(mapping.get("container"), where=f"{where}.container"),
        read_only=_as_bool(mapping.get("ro", False), where=f"{where}.ro"),
    )


def _container_artifact(value: object, *, where: str) -> ContainerArtifact | None:
    if value is None:
        return None
    mapping = _as_map(value, where=where)
    return ContainerArtifact(
        dockerfile=Path(_as_str(mapping.get("dockerfile"), where=f"{where}.dockerfile")),
    )


def _model(value: object, *, where: str) -> ModelSpec:
    mapping = _as_map(value, where=where)
    tag = _as_str(mapping.get("tag"), where=f"{where}.tag")

    if tag == "Container":
        payload = _as_map(mapping.get("container"), where=f"{where}.container")
        mounts_raw = _as_list(payload.get("mounts", []), where=f"{where}.container.mounts")
        return ContainerModel(
            dockerfile=Path(
                _as_str(payload.get("dockerfile"), where=f"{where}.container.dockerfile")
            ),
            mounts=tuple(
                _mount(entry, where=f"{where}.container.mounts[{i}]")
                for i, entry in enumerate(mounts_raw)
            ),
        )
    if tag == "HostBinary":
        payload = _as_map(mapping.get("hostBinary"), where=f"{where}.hostBinary")
        return HostBinaryModel(
            container=_container_artifact(
                payload.get("container"), where=f"{where}.hostBinary.container"
            ),
        )
    if tag == "HostDaemon":
        payload = _as_map(mapping.get("hostDaemon"), where=f"{where}.hostDaemon")
        return HostDaemonModel(
            daemon=_as_str(payload.get("daemon"), where=f"{where}.hostDaemon.daemon"),
            container=_container_artifact(
                payload.get("container"), where=f"{where}.hostDaemon.container"
            ),
        )
    raise SpecError(f"{where}.tag: unknown model {tag!r}")


def _lifecycle(value: object, *, where: str) -> TargetSpec:
    mapping = _as_map(value, where=where)
    tag = _as_str(mapping.get("tag"), where=f"{where}.tag")
    if tag == "Cluster":
        return TargetSpec(
            lifecycle=Lifecycle.CLUSTER,
            model=_model(mapping.get("cluster"), where=f"{where}.cluster"),
        )
    if tag == "NoCluster":
        return TargetSpec(
            lifecycle=Lifecycle.NO_CLUSTER,
            model=_model(mapping.get("noCluster"), where=f"{where}.noCluster"),
        )
    raise SpecError(f"{where}.tag: unknown lifecycle {tag!r}")


def load(path: Path) -> ProjectSpec:
    if not path.is_file():
        raise SpecError(f"hostbootstrap.dhall not found at {path}")

    try:
        rendered = dhall_tool.to_json(path)
    except dhall_tool.DhallToolError as exc:
        raise SpecError(f"could not evaluate {path}: {exc}") from exc

    data = _as_map(rendered, where="<root>")
    project = _as_str(data.get("project"), where="project")

    entries = _as_list(data.get("substrates"), where="substrates")
    if not entries:
        raise SpecError("substrates: at least one substrate must be declared")

    targets: dict[SubstrateName, TargetSpec] = {}
    for index, raw_entry in enumerate(entries):
        where = f"substrates[{index}]"
        entry = _as_map(raw_entry, where=where)
        substrate = _substrate(entry.get("substrate"), where=f"{where}.substrate")
        if substrate in targets:
            raise SpecError(f"substrate {substrate.value!r} is declared more than once")
        targets[substrate] = _lifecycle(entry.get("lifecycle"), where=f"{where}.lifecycle")

    return ProjectSpec(project=project, targets=targets, source_path=path)
