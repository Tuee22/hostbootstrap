"""Dhall contract tests against the bundled schema package."""

from __future__ import annotations

from pathlib import Path

import pytest

from hostbootstrap import spec
from hostbootstrap.spec import ContainerModel, HostBinaryModel, HostDaemonModel, Lifecycle, SpecError
from hostbootstrap.substrate import SubstrateName

FIXTURES = Path(__file__).parent / "fixtures" / "dhall"


def test_valid_container(require_dhall: Path) -> None:
    _ = require_dhall
    ps = spec.load(FIXTURES / "valid" / "container.dhall")
    target = ps.targets[SubstrateName.LINUX_CPU]
    assert target.lifecycle is Lifecycle.CLUSTER
    assert isinstance(target.model, ContainerModel)
    assert target.model.dockerfile == Path("docker/demo.Dockerfile")
    assert target.model.mounts[0].container == "/opt/demo/.data"


def test_valid_host_binary(require_dhall: Path) -> None:
    _ = require_dhall
    ps = spec.load(FIXTURES / "valid" / "host_binary.dhall")
    target = ps.targets[SubstrateName.LINUX_CPU]
    assert target.lifecycle is Lifecycle.CLUSTER
    assert isinstance(target.model, HostBinaryModel)


def test_valid_host_daemon(require_dhall: Path) -> None:
    _ = require_dhall
    ps = spec.load(FIXTURES / "valid" / "host_daemon.dhall")
    target = ps.targets[SubstrateName.APPLE_SILICON]
    assert target.lifecycle is Lifecycle.CLUSTER
    assert isinstance(target.model, HostDaemonModel)
    assert target.model.daemon == "service --role worker --config dhall/worker.dhall"


def test_valid_no_cluster(require_dhall: Path) -> None:
    _ = require_dhall
    ps = spec.load(FIXTURES / "valid" / "no_cluster.dhall")
    assert set(ps.targets) == {
        SubstrateName.APPLE_SILICON,
        SubstrateName.LINUX_CPU,
        SubstrateName.LINUX_GPU,
    }
    assert all(target.lifecycle is Lifecycle.NO_CLUSTER for target in ps.targets.values())


def test_valid_mixed(require_dhall: Path) -> None:
    _ = require_dhall
    ps = spec.load(FIXTURES / "valid" / "mixed.dhall")
    assert isinstance(ps.targets[SubstrateName.APPLE_SILICON].model, HostDaemonModel)
    assert isinstance(ps.targets[SubstrateName.LINUX_CPU].model, ContainerModel)
    assert isinstance(ps.targets[SubstrateName.LINUX_GPU].model, ContainerModel)
    assert ps.targets[SubstrateName.LINUX_GPU].lifecycle is Lifecycle.NO_CLUSTER


def test_explicit_import_still_works(require_dhall: Path) -> None:
    _ = require_dhall
    ps = spec.load(FIXTURES / "valid" / "explicit_import.dhall")
    assert ps.project == "demo"
    assert ps.targets[SubstrateName.LINUX_CPU].lifecycle is Lifecycle.NO_CLUSTER


@pytest.mark.parametrize(
    "fixture",
    [
        "daemon_on_container",
        "flavor_on_container",
        "missing_daemon",
        "mounts_on_host_binary",
        "unknown_substrate",
    ],
)
def test_invalid_dhall_fixtures_fail(require_dhall: Path, fixture: str) -> None:
    _ = require_dhall
    with pytest.raises(SpecError):
        spec.load(FIXTURES / "invalid" / f"{fixture}.dhall")
