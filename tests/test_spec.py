"""Unit tests for spec parsing/validation against crafted JSON (no real Dhall)."""

from __future__ import annotations

from pathlib import Path

import pytest

from hostbootstrap import spec
from hostbootstrap.spec import (
    ContainerModel,
    HostBinaryModel,
    HostDaemonModel,
    Lifecycle,
    SpecError,
)
from hostbootstrap.substrate import Substrate, SubstrateName

_APPLE = Substrate(SubstrateName.APPLE_SILICON, "arm64")
_LINUX_CPU = Substrate(SubstrateName.LINUX_CPU, "amd64")
_LINUX_GPU = Substrate(SubstrateName.LINUX_GPU, "amd64")


def _container(dockerfile: str = "d", **over: object) -> dict[str, object]:
    payload: dict[str, object] = {"dockerfile": dockerfile}
    payload.update(over)
    return {"tag": "Container", "container": payload}


def _host_binary(**over: object) -> dict[str, object]:
    payload: dict[str, object] = {"container": None}
    payload.update(over)
    return {"tag": "HostBinary", "hostBinary": payload}


def _host_daemon() -> dict[str, object]:
    return {
        "tag": "HostDaemon",
        "hostDaemon": {
            "daemon": "service --role worker --config dhall/worker.dhall",
            "container": None,
        },
    }


def _lifecycle(tag: str, model: dict[str, object]) -> dict[str, object]:
    if tag == "Cluster":
        return {"tag": tag, "cluster": model}
    return {"tag": tag, "noCluster": model}


def _entry(substrate: str, lifecycle: dict[str, object]) -> dict[str, object]:
    return {"substrate": substrate, "lifecycle": lifecycle}


def _load(monkeypatch: pytest.MonkeyPatch, tmp_path: Path, data: object) -> spec.ProjectSpec:
    path = tmp_path / "hostbootstrap.dhall"
    path.write_text("-- placeholder; to_json is monkeypatched\n")
    monkeypatch.setattr(spec.dhall_tool, "to_json", lambda _p: data)
    return spec.load(path)


def test_parse_models_and_lifecycles(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    data = {
        "project": "demo",
        "substrates": [
            _entry(
                "apple-silicon",
                _lifecycle("Cluster", _host_daemon()),
            ),
            _entry(
                "linux-cpu",
                _lifecycle(
                    "Cluster",
                    _container(mounts=[{"host": "./.data", "container": "/d", "ro": False}]),
                ),
            ),
            _entry(
                "linux-gpu",
                _lifecycle(
                    "NoCluster",
                    _host_binary(container={"dockerfile": "docker/app.Dockerfile"}),
                ),
            ),
        ],
    }
    ps = _load(monkeypatch, tmp_path, data)
    assert ps.project == "demo"

    apple = ps.targets[SubstrateName.APPLE_SILICON]
    assert apple.lifecycle is Lifecycle.CLUSTER
    assert isinstance(apple.model, HostDaemonModel)
    assert apple.model.daemon == "service --role worker --config dhall/worker.dhall"

    linux = ps.targets[SubstrateName.LINUX_CPU]
    assert linux.lifecycle is Lifecycle.CLUSTER
    assert isinstance(linux.model, ContainerModel)
    assert linux.model.mounts[0].container == "/d"

    gpu = ps.targets[SubstrateName.LINUX_GPU]
    assert gpu.lifecycle is Lifecycle.NO_CLUSTER
    assert isinstance(gpu.model, HostBinaryModel)
    assert gpu.model.container is not None
    assert gpu.model.container.dockerfile == Path("docker/app.Dockerfile")


def test_container_defaults(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    ps = _load(
        monkeypatch,
        tmp_path,
        {
            "project": "p",
            "substrates": [_entry("linux-cpu", _lifecycle("Cluster", _container()))],
        },
    )
    target = ps.targets[SubstrateName.LINUX_CPU]
    assert isinstance(target.model, ContainerModel)
    assert target.model.mounts == ()


def test_duplicate_substrate_rejected(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    data = {
        "project": "p",
        "substrates": [
            _entry("linux-cpu", _lifecycle("Cluster", _container())),
            _entry("linux-cpu", _lifecycle("NoCluster", _container())),
        ],
    }
    with pytest.raises(SpecError, match="more than once"):
        _load(monkeypatch, tmp_path, data)


def test_unknown_substrate_rejected(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    with pytest.raises(SpecError, match="unknown substrate"):
        _load(
            monkeypatch,
            tmp_path,
            {"project": "p", "substrates": [_entry("bsd", _lifecycle("Cluster", _container()))]},
        )


def test_empty_substrates_rejected(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    with pytest.raises(SpecError, match="at least one"):
        _load(monkeypatch, tmp_path, {"project": "p", "substrates": []})


def test_unknown_model_tag_rejected(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    with pytest.raises(SpecError, match="unknown model"):
        _load(
            monkeypatch,
            tmp_path,
            {
                "project": "p",
                "substrates": [_entry("linux-cpu", _lifecycle("Cluster", {"tag": "Nope"}))],
            },
        )


def test_unknown_lifecycle_tag_rejected(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    with pytest.raises(SpecError, match="unknown lifecycle"):
        _load(
            monkeypatch,
            tmp_path,
            {
                "project": "p",
                "substrates": [_entry("linux-cpu", {"tag": "Maybe", "cluster": _container()})],
            },
        )


def test_missing_file_rejected(tmp_path: Path) -> None:
    with pytest.raises(SpecError, match="not found"):
        spec.load(tmp_path / "nope.dhall")


def test_dhall_error_wrapped(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    path = tmp_path / "hostbootstrap.dhall"
    path.write_text("bad\n", encoding="utf-8")

    def _raise(_path: Path) -> object:
        raise spec.dhall_tool.DhallToolError("bad import")

    monkeypatch.setattr(spec.dhall_tool, "to_json", _raise)

    with pytest.raises(SpecError, match="could not evaluate"):
        spec.load(path)


def test_target_for_detected_and_forced(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    ps = _load(
        monkeypatch,
        tmp_path,
        {
            "project": "p",
            "substrates": [
                _entry("apple-silicon", _lifecycle("Cluster", _host_daemon())),
                _entry("linux-cpu", _lifecycle("Cluster", _container())),
                _entry("linux-gpu", _lifecycle("NoCluster", _host_binary())),
            ],
        },
    )
    detected = ps.target_for(_LINUX_CPU)
    assert detected.substrate is SubstrateName.LINUX_CPU
    assert isinstance(detected.model, ContainerModel)

    forced = ps.target_for(_LINUX_CPU, force_target=SubstrateName.APPLE_SILICON)
    assert forced.substrate is SubstrateName.APPLE_SILICON
    assert isinstance(forced.model, HostDaemonModel)

    gpu = ps.target_for(_LINUX_GPU)
    assert gpu.lifecycle is Lifecycle.NO_CLUSTER

    assert isinstance(ps.target_for(_APPLE).model, HostDaemonModel)


def test_target_for_no_matching_substrate(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    ps = _load(
        monkeypatch,
        tmp_path,
        {"project": "p", "substrates": [_entry("linux-cpu", _lifecycle("Cluster", _container()))]},
    )
    with pytest.raises(SpecError, match="no target declared"):
        ps.target_for(_APPLE)


def test_narrowers() -> None:
    with pytest.raises(SpecError):
        spec._as_map([1], where="x")
    with pytest.raises(SpecError):
        spec._as_list({"not": "a list"}, where="x")
    with pytest.raises(SpecError):
        spec._as_str(5, where="x")
    with pytest.raises(SpecError):
        spec._as_bool("nope", where="x")
    assert spec._as_bool(True, where="x") is True
