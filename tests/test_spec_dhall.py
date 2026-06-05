"""Contract tests: real dhall-to-json + the shipped hostbootstrap/dhall/package.dhall.

These exercise the headline guarantee — illegal states are unrepresentable — by
loading fixtures through the actual Dhall type-checker. The fixtures carry no
import line: the schema is injected as ``H`` by ``dhall_tool.to_json`` (the same
path the CLI uses), so these also cover the zero-boilerplate config convention.
They are skipped when a dhall-to-json binary cannot be provisioned (e.g. offline
CI).
"""

from __future__ import annotations

from pathlib import Path

import pytest

from hostbootstrap import spec
from hostbootstrap.spec import ContainerModel, HostBinaryModel, HostDaemonModel, SpecError
from hostbootstrap.substrate import Accel

pytestmark = pytest.mark.dhall

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "dhall"


def test_valid_container(require_dhall: Path) -> None:
    ps = spec.load(FIXTURES / "valid" / "container.dhall")
    assert isinstance(ps.targets[Accel.CPU], ContainerModel)


def test_valid_service_container(require_dhall: Path) -> None:
    ps = spec.load(FIXTURES / "valid" / "service_container.dhall")
    model = ps.targets[Accel.CPU]
    assert isinstance(model, ContainerModel)
    assert model.service is True
    assert {m.container for m in model.mounts} == {"/opt/demo/.data", "/var/run/docker.sock"}


def test_valid_host_binary(require_dhall: Path) -> None:
    ps = spec.load(FIXTURES / "valid" / "host_binary.dhall")
    model = ps.targets[Accel.CPU]
    assert isinstance(model, HostBinaryModel)
    assert model.handoff.up == ".build/demo cluster up"
    assert model.handoff.delete is None


def test_valid_host_daemon(require_dhall: Path) -> None:
    ps = spec.load(FIXTURES / "valid" / "host_daemon.dhall")
    model = ps.targets[Accel.METAL]
    assert isinstance(model, HostDaemonModel)
    assert model.daemon == ".build/demo inference --serve"
    assert model.build.host.ghc is True


def test_valid_development_config(require_dhall: Path) -> None:
    ps = spec.load(FIXTURES / "valid" / "development.dhall")
    assert ps.development is True
    assert isinstance(ps.targets[Accel.CPU], ContainerModel)


def test_valid_mixed(require_dhall: Path) -> None:
    ps = spec.load(FIXTURES / "valid" / "mixed.dhall")
    assert isinstance(ps.targets[Accel.METAL], HostDaemonModel)
    assert isinstance(ps.targets[Accel.CUDA], ContainerModel)


def test_explicit_import_shadows_injected(require_dhall: Path) -> None:
    # A project file may still bind its own `H` (e.g. `let H = env:HOSTBOOTSTRAP_PACKAGE`);
    # it harmlessly shadows the CLI-injected binding and renders identically.
    ps = spec.load(FIXTURES / "valid" / "explicit_import.dhall")
    assert isinstance(ps.targets[Accel.CPU], ContainerModel)


@pytest.mark.parametrize(
    "fixture",
    [
        "daemon_on_container",
        "missing_daemon",
        "mounts_on_host_binary",
        "flavor_on_container",
        "unknown_accel",
    ],
)
def test_illegal_states_are_type_errors(require_dhall: Path, fixture: str) -> None:
    with pytest.raises(SpecError):
        spec.load(FIXTURES / "invalid" / f"{fixture}.dhall")
