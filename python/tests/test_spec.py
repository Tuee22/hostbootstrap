"""Unit tests for static-base spec parsing against crafted JSON (no real Dhall)."""

from __future__ import annotations

from pathlib import Path

import pytest

from hostbootstrap import spec
from hostbootstrap.spec import Resources, StaticBaseSpec, SpecError


def _valid() -> dict[str, object]:
    return {
        "project": "demo",
        "dockerfile": "docker/demo.Dockerfile",
        "resources": {"cpu": 4, "memory": "8GiB", "storage": "20GiB"},
    }


def _load(monkeypatch: pytest.MonkeyPatch, tmp_path: Path, data: object) -> StaticBaseSpec:
    path = tmp_path / "hostbootstrap.dhall"
    path.write_text("-- placeholder; to_json is monkeypatched\n")
    monkeypatch.setattr(spec.dhall_tool, "to_json", lambda _p: data)
    return spec.load(path)


def test_load_static_base_spec(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    result = _load(monkeypatch, tmp_path, _valid())
    assert result.project == "demo"
    assert result.dockerfile == Path("docker/demo.Dockerfile")
    assert result.resources == Resources(cpu=4, memory="8GiB", storage="20GiB")
    assert result.source_path == tmp_path / "hostbootstrap.dhall"


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


def test_root_must_be_object(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    with pytest.raises(SpecError, match="<root>: expected an object"):
        _load(monkeypatch, tmp_path, [1, 2, 3])


def test_missing_project_rejected(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    data = _valid()
    del data["project"]
    with pytest.raises(SpecError, match="project: expected a string"):
        _load(monkeypatch, tmp_path, data)


def test_missing_dockerfile_rejected(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    data = _valid()
    del data["dockerfile"]
    with pytest.raises(SpecError, match="dockerfile: expected a string"):
        _load(monkeypatch, tmp_path, data)


def test_resources_must_be_object(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    data = _valid()
    data["resources"] = "8GiB"
    with pytest.raises(SpecError, match="resources: expected an object"):
        _load(monkeypatch, tmp_path, data)


def test_cpu_must_be_integer(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    data = _valid()
    data["resources"] = {"cpu": "4", "memory": "8GiB", "storage": "20GiB"}
    with pytest.raises(SpecError, match="resources.cpu: expected an integer"):
        _load(monkeypatch, tmp_path, data)


def test_cpu_rejects_bool(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    data = _valid()
    data["resources"] = {"cpu": True, "memory": "8GiB", "storage": "20GiB"}
    with pytest.raises(SpecError, match="resources.cpu: expected an integer"):
        _load(monkeypatch, tmp_path, data)


def test_memory_must_be_string(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    data = _valid()
    data["resources"] = {"cpu": 4, "memory": 8, "storage": "20GiB"}
    with pytest.raises(SpecError, match="resources.memory: expected a string"):
        _load(monkeypatch, tmp_path, data)


# ---------------------------------------------------------------------------
# Real Dhall round-trip against the bundled static-base package
# (covers dhall_tool._package_path and validates the schema end to end).
# ---------------------------------------------------------------------------

_VALID_DHALL = (
    'H.config { project = "demo"\n'
    "         , dockerfile = \"docker/demo.Dockerfile\"\n"
    '         , resources = { cpu = 4, memory = "8GiB", storage = "20GiB" }\n'
    "         }\n"
)


def test_real_dhall_round_trip(require_dhall: Path, tmp_path: Path) -> None:
    _ = require_dhall
    path = tmp_path / "hostbootstrap.dhall"
    path.write_text(_VALID_DHALL, encoding="utf-8")

    result = spec.load(path)
    assert result.project == "demo"
    assert result.dockerfile == Path("docker/demo.Dockerfile")
    assert result.resources == Resources(cpu=4, memory="8GiB", storage="20GiB")


def test_real_dhall_rejects_wrong_field_type(require_dhall: Path, tmp_path: Path) -> None:
    _ = require_dhall
    path = tmp_path / "hostbootstrap.dhall"
    # `cpu` must be a Natural; a Text value is a Dhall type error.
    path.write_text(
        'H.config { project = "demo"\n'
        "         , dockerfile = \"d\"\n"
        '         , resources = { cpu = "four", memory = "8GiB", storage = "20GiB" }\n'
        "         }\n",
        encoding="utf-8",
    )
    with pytest.raises(SpecError, match="could not evaluate"):
        spec.load(path)


def test_narrowers() -> None:
    with pytest.raises(SpecError):
        spec._as_map([1], where="x")
    with pytest.raises(SpecError):
        spec._as_str(5, where="x")
    with pytest.raises(SpecError):
        spec._as_int("5", where="x")
    with pytest.raises(SpecError):
        spec._as_int(True, where="x")
    assert spec._as_map({"a": 1}, where="x") == {"a": 1}
    assert spec._as_str("ok", where="x") == "ok"
    assert spec._as_int(7, where="x") == 7
