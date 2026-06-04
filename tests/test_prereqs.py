"""Unit tests for host prerequisite detection."""

from __future__ import annotations

import plistlib
import subprocess
from pathlib import Path

import pytest

from hostbootstrap import prereqs
from hostbootstrap.spec import ProjectSpec
from hostbootstrap.substrate import Substrate, SubstrateName


def _write_plist(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        plistlib.dump(payload, handle)


def _completed(
    args: list[str],
    *,
    returncode: int = 0,
    stdout: str = "",
) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(args=args, returncode=returncode, stdout=stdout, stderr="")


def _loaded_launchdaemon(
    monkeypatch: pytest.MonkeyPatch,
    *,
    loaded: bool = True,
) -> None:
    def _fake_run(cmd: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        assert cmd[:2] == ["launchctl", "print"]
        if not loaded:
            return _completed(cmd, returncode=1)
        return _completed(cmd, stdout="type = LaunchDaemon\nstate = running\n")

    monkeypatch.setattr(prereqs.subprocess, "run", _fake_run)


def test_colima_canonical_launchdaemon_passes(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _write_plist(
        tmp_path / "com.colima.default.plist",
        {
            "Label": "com.colima.default",
            "RunAtLoad": True,
            "ProgramArguments": ["/opt/homebrew/bin/colima", "start", "-f"],
        },
    )
    monkeypatch.setattr(prereqs, "_LAUNCHD_DIR", tmp_path)
    _loaded_launchdaemon(monkeypatch)

    prereqs._check_colima_launchdaemon()


def test_colima_custom_wrapper_launchdaemon_passes(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    wrapper = tmp_path / "colima-system-start.sh"
    wrapper.write_text(
        "#!/bin/zsh\nexec /opt/homebrew/opt/colima/bin/colima start -f\n",
        encoding="utf-8",
    )
    _write_plist(
        tmp_path / "com.example.colima.plist",
        {
            "Label": "com.example.colima",
            "RunAtLoad": True,
            "ProgramArguments": [str(wrapper)],
            "UserName": "matthewnowak",
        },
    )
    monkeypatch.setattr(prereqs, "_LAUNCHD_DIR", tmp_path)
    _loaded_launchdaemon(monkeypatch)

    prereqs._check_colima_launchdaemon()


def test_colima_launchagent_is_not_accepted(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    launchdaemons = tmp_path / "LaunchDaemons"
    launchagents = tmp_path / "LaunchAgents"
    launchdaemons.mkdir()
    _write_plist(
        launchagents / "com.colima.default.plist",
        {
            "Label": "com.colima.default",
            "RunAtLoad": True,
            "ProgramArguments": ["/opt/homebrew/bin/colima", "start", "-f"],
        },
    )
    monkeypatch.setattr(prereqs, "_LAUNCHD_DIR", launchdaemons)
    _loaded_launchdaemon(monkeypatch)

    with pytest.raises(prereqs.PrereqError, match="system LaunchDaemon"):
        prereqs._check_colima_launchdaemon()


def test_colima_launchdaemon_requires_run_at_load(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _write_plist(
        tmp_path / "com.colima.default.plist",
        {
            "Label": "com.colima.default",
            "RunAtLoad": False,
            "ProgramArguments": ["/opt/homebrew/bin/colima", "start", "-f"],
        },
    )
    monkeypatch.setattr(prereqs, "_LAUNCHD_DIR", tmp_path)
    _loaded_launchdaemon(monkeypatch)

    with pytest.raises(prereqs.PrereqError, match="system LaunchDaemon"):
        prereqs._check_colima_launchdaemon()


def test_colima_launchdaemon_must_be_bootstrapped(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _write_plist(
        tmp_path / "com.colima.default.plist",
        {
            "Label": "com.colima.default",
            "RunAtLoad": True,
            "ProgramArguments": ["/opt/homebrew/bin/colima", "start", "--foreground"],
        },
    )
    monkeypatch.setattr(prereqs, "_LAUNCHD_DIR", tmp_path)
    _loaded_launchdaemon(monkeypatch, loaded=False)

    with pytest.raises(prereqs.PrereqError, match="not bootstrapped"):
        prereqs._check_colima_launchdaemon()


def test_filevault_off_passes(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fake_run(cmd: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        assert cmd == ["/usr/bin/fdesetup", "status"]
        return _completed(cmd, stdout="FileVault is Off.\n")

    monkeypatch.setattr(prereqs.subprocess, "run", _fake_run)

    prereqs._check_filevault_disabled()


def test_filevault_on_fails(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fake_run(cmd: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        assert cmd == ["/usr/bin/fdesetup", "status"]
        return _completed(cmd, stdout="FileVault is On.\n")

    monkeypatch.setattr(prereqs.subprocess, "run", _fake_run)

    with pytest.raises(prereqs.PrereqError, match="FileVault is enabled"):
        prereqs._check_filevault_disabled()


async def test_apple_development_mode_skips_prelogin_checks(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    calls: list[str] = []

    monkeypatch.setattr(prereqs, "_check_macos_arm64", lambda: calls.append("macos"))
    monkeypatch.setattr(prereqs, "_check_xcode_clt", lambda: calls.append("xcode"))
    monkeypatch.setattr(prereqs, "_check_passwordless_sudo", lambda: calls.append("sudo"))
    monkeypatch.setattr(prereqs, "_check_homebrew", lambda: calls.append("brew"))
    monkeypatch.setattr(
        prereqs,
        "_check_filevault_disabled",
        lambda: calls.append("filevault"),
    )
    monkeypatch.setattr(
        prereqs,
        "_check_colima_launchdaemon",
        lambda: calls.append("colima-launchdaemon"),
    )
    monkeypatch.setattr(prereqs, "_check_docker_socket", lambda: calls.append("docker"))

    project_spec = ProjectSpec(
        project="p",
        substrates={},
        source_path=tmp_path / "hostbootstrap.dhall",
        development=True,
    )
    result = await prereqs._run_apple(
        project_spec,
        Substrate(SubstrateName.APPLE_SILICON, "arm64"),
    )

    assert calls == ["macos", "xcode", "sudo", "brew", "docker"]
    assert "development mode: skipped FileVault pre-login check" in result.messages
    assert "development mode: skipped Colima system LaunchDaemon check" in result.messages
