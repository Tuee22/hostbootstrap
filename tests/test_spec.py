"""Unit tests for spec parsing/validation against crafted JSON (no real Dhall)."""

from __future__ import annotations

from pathlib import Path

import pytest

from hostbootstrap import spec
from hostbootstrap.spec import (
    ContainerModel,
    HostBinaryModel,
    HostDaemonModel,
    SpecError,
)
from hostbootstrap.substrate import Accel, Substrate, SubstrateName

_APPLE = Substrate(SubstrateName.APPLE_SILICON, "arm64")
_LINUX_CPU = Substrate(SubstrateName.LINUX_CPU, "amd64")
_LINUX_GPU = Substrate(SubstrateName.LINUX_GPU, "amd64")


def _container(dockerfile: str = "d", **over: object) -> dict[str, object]:
    payload: dict[str, object] = {"dockerfile": dockerfile, "service": False}
    payload.update(over)
    return {"tag": "Container", "container": payload}


def _host_binary(**build: object) -> dict[str, object]:
    return {
        "tag": "HostBinary",
        "hostBinary": {
            "build": {"cabal": "cabal install exe:demo", "host": {"ghc": True}},
            "handoff": {"up": ".build/demo up", "down": ".build/demo down", "delete": None},
            **build,
        },
    }


def _host_daemon() -> dict[str, object]:
    return {
        "tag": "HostDaemon",
        "hostDaemon": {
            "build": {"cabal": "c", "host": {"ghc": True}},
            "daemon": ".build/demo serve",
        },
    }


def _target(accel: str, model: dict[str, object]) -> dict[str, object]:
    return {"accel": accel, "model": model}


def _load(monkeypatch: pytest.MonkeyPatch, tmp_path: Path, data: object) -> spec.ProjectSpec:
    path = tmp_path / "hostbootstrap.dhall"
    path.write_text("-- placeholder; to_json is monkeypatched\n")
    monkeypatch.setattr(spec.dhall_tool, "to_json", lambda _p: data)
    return spec.load(path)


def test_parse_all_three_models(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    data = {
        "project": "demo",
        "targets": [
            _target(
                "cpu",
                _container(
                    service=True, mounts=[{"host": "./.data", "container": "/d", "ro": False}]
                ),
            ),
            _target("cuda", _host_binary()),
            _target("metal", _host_daemon()),
        ],
    }
    ps = _load(monkeypatch, tmp_path, data)
    assert ps.project == "demo"
    assert ps.development is False
    cpu = ps.targets[Accel.CPU]
    assert isinstance(cpu, ContainerModel) and cpu.service and cpu.mounts[0].container == "/d"
    assert isinstance(ps.targets[Accel.CUDA], HostBinaryModel)
    daemon = ps.targets[Accel.METAL]
    assert isinstance(daemon, HostDaemonModel) and daemon.daemon == ".build/demo serve"
    assert daemon.build.host.ghc is True


def test_container_defaults(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    ps = _load(
        monkeypatch,
        tmp_path,
        {
            "project": "p",
            "targets": [_target("cpu", {"tag": "Container", "container": {"dockerfile": "d"}})],
        },
    )
    model = ps.targets[Accel.CPU]
    assert isinstance(model, ContainerModel)
    assert model.service is False and model.mounts == ()


def test_development_mode_flag(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    ps = _load(
        monkeypatch,
        tmp_path,
        {
            "project": "p",
            "development": True,
            "targets": [_target("cpu", _container())],
        },
    )
    assert ps.development is True


def test_container_artifact_parsed(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    ps = _load(
        monkeypatch,
        tmp_path,
        {
            "project": "p",
            "targets": [
                _target(
                    "cuda",
                    _host_binary(container={"dockerfile": "docker/app.Dockerfile"}),
                )
            ],
        },
    )

    model = ps.targets[Accel.CUDA]
    assert isinstance(model, HostBinaryModel)
    assert model.container is not None
    assert model.container.dockerfile == Path("docker/app.Dockerfile")


def test_duplicate_accel_rejected(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    data = {
        "project": "p",
        "targets": [_target("cpu", _container()), _target("cpu", _container())],
    }
    with pytest.raises(SpecError, match="more than once"):
        _load(monkeypatch, tmp_path, data)


def test_unknown_accel_rejected(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    with pytest.raises(SpecError, match="unknown accel"):
        _load(monkeypatch, tmp_path, {"project": "p", "targets": [_target("tpu", _container())]})


def test_empty_targets_rejected(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    with pytest.raises(SpecError, match="at least one"):
        _load(monkeypatch, tmp_path, {"project": "p", "targets": []})


def test_unknown_tag_rejected(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    with pytest.raises(SpecError, match="unknown model"):
        _load(
            monkeypatch,
            tmp_path,
            {"project": "p", "targets": [_target("cpu", {"tag": "Nope"})]},
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


def test_target_for_cpu_runs_on_every_host(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    ps = _load(monkeypatch, tmp_path, {"project": "p", "targets": [_target("cpu", _container())]})
    for host in (_APPLE, _LINUX_CPU, _LINUX_GPU):
        resolved = ps.target_for(host)
        assert resolved.accel is Accel.CPU
        assert isinstance(resolved.model, ContainerModel)


def test_target_for_prefers_accelerated_over_cpu(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    ps = _load(
        monkeypatch,
        tmp_path,
        {
            "project": "p",
            "targets": [
                _target("cpu", _container()),
                _target("cuda", _host_binary()),
                _target("metal", _host_daemon()),
            ],
        },
    )
    # linux-gpu can satisfy cpu+cuda; the resolver picks the accelerated one.
    assert ps.target_for(_LINUX_GPU).accel is Accel.CUDA
    # apple can satisfy cpu+metal; it picks metal.
    assert ps.target_for(_APPLE).accel is Accel.METAL
    # linux-cpu can only satisfy cpu.
    assert ps.target_for(_LINUX_CPU).accel is Accel.CPU


def test_target_for_no_eligible_target(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    ps = _load(monkeypatch, tmp_path, {"project": "p", "targets": [_target("cuda", _host_binary())]})
    with pytest.raises(SpecError, match="no target runnable on host 'apple-silicon'"):
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
