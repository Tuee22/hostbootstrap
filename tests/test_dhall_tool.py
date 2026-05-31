"""Unit tests for dhall-to-json provisioning (no real network)."""

from __future__ import annotations

import hashlib
import io
import platform
import tarfile
from pathlib import Path

import httpx
import pytest

from hostbootstrap import dhall_tool


def test_platform_key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(platform, "system", lambda: "Linux")
    monkeypatch.setattr(platform, "machine", lambda: "x86_64")
    assert dhall_tool._platform_key() == ("Linux", "amd64")
    monkeypatch.setattr(platform, "machine", lambda: "aarch64")
    assert dhall_tool._platform_key() == ("Linux", "arm64")


def test_cache_dir_respects_xdg(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path))
    assert dhall_tool._cache_dir() == tmp_path / "hostbootstrap" / "dhall-json" / "1.7.12"


def test_ensure_uses_cached_binary(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setattr(dhall_tool, "_cache_dir", lambda: tmp_path)
    target = tmp_path / dhall_tool._EXE
    target.write_text("#!/bin/sh\n")
    target.chmod(0o755)

    def _no_download(*_a: object, **_k: object) -> None:
        raise AssertionError("ensure() must not download when a cached binary exists")

    monkeypatch.setattr(dhall_tool, "_download_and_extract", _no_download)
    assert dhall_tool.ensure() == target


def test_ensure_ignores_path_binary(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    # Even if a dhall-to-json sits on PATH, ensure() provisions its own pinned
    # binary into the cache and returns that — never the host one.
    monkeypatch.setenv("PATH", "/usr/local/bin")
    monkeypatch.setattr(dhall_tool, "_cache_dir", lambda: tmp_path)
    target = tmp_path / dhall_tool._EXE

    def _fake_download(asset: dhall_tool._Asset, dest: Path) -> None:
        dest.write_text("#!/bin/sh\n")
        dest.chmod(0o755)

    monkeypatch.setattr(dhall_tool, "_download_and_extract", _fake_download)
    assert dhall_tool.ensure() == target


def test_ensure_no_asset_for_platform(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setattr(dhall_tool, "_cache_dir", lambda: tmp_path)
    monkeypatch.setattr(dhall_tool, "_platform_key", lambda: ("Linux", "arm64"))
    with pytest.raises(dhall_tool.DhallToolError, match="no prebuilt"):
        dhall_tool.ensure()


def _fake_tarball(content: bytes) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:bz2") as tar:
        info = tarfile.TarInfo("dhall-json-1.7.12/bin/dhall-to-json")
        info.size = len(content)
        tar.addfile(info, io.BytesIO(content))
    return buf.getvalue()


def _ok_response(payload: bytes) -> httpx.Response:
    return httpx.Response(200, content=payload, request=httpx.Request("GET", "https://example/x"))


def test_download_and_extract_ok(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    payload = _fake_tarball(b"#!/bin/sh\necho 1.7.12\n")
    monkeypatch.setattr(httpx, "get", lambda *a, **k: _ok_response(payload))
    asset = dhall_tool._Asset("x.tar.bz2", hashlib.sha256(payload).hexdigest())
    dest = tmp_path / "dhall-to-json"
    dhall_tool._download_and_extract(asset, dest)
    assert dest.is_file()
    assert dest.read_bytes() == b"#!/bin/sh\necho 1.7.12\n"
    assert dest.stat().st_mode & 0o111  # executable


def test_download_checksum_mismatch(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    payload = _fake_tarball(b"bin")
    monkeypatch.setattr(httpx, "get", lambda *a, **k: _ok_response(payload))
    asset = dhall_tool._Asset("x.tar.bz2", "0" * 64)
    with pytest.raises(dhall_tool.DhallToolError, match="checksum mismatch"):
        dhall_tool._download_and_extract(asset, tmp_path / "out")


def test_pinned_assets_are_bz2_names() -> None:
    # Guards against a typo when bumping the pin.
    for (system, arch), asset in dhall_tool._ASSETS.items():
        assert asset.filename.startswith("dhall-json-1.7.12-")
        assert asset.filename.endswith(".tar.bz2")
        assert len(asset.sha256) == 64
        assert (system, arch) in {("Darwin", "arm64"), ("Darwin", "amd64"), ("Linux", "amd64")}
