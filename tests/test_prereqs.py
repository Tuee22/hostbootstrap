"""Unit tests for the fail-fast host minimums (substrate-only dispatch)."""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Sequence
from pathlib import Path
from typing import cast

import pytest
from hostbootstrap import prereqs, process
from hostbootstrap.substrate import Arch, Substrate, SubstrateName


def _ran(
    args: Sequence[str],
    *,
    returncode: int = 0,
    stdout: str = "",
    stderr: str = "",
) -> process.CommandResult:
    return process.CommandResult(tuple(args), returncode, stdout, stderr)


def _never_ran(args: Sequence[str], reason: str = "noexec") -> process.CommandUnavailable:
    return process.CommandUnavailable(tuple(args), reason)


def _patch_os_release(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    text: str | None,
) -> None:
    real_path = Path
    os_release = tmp_path / "os-release"
    if text is not None:
        os_release.write_text(text, encoding="utf-8")
    elif os_release.exists():
        os_release.unlink()

    def _fake_path(value: str) -> Path:
        if value == "/etc/os-release":
            return os_release
        return real_path(value)

    monkeypatch.setattr(prereqs, "Path", _fake_path)


def test_have_uses_path_lookup(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs.shutil, "which", lambda cmd: f"/bin/{cmd}")
    assert prereqs._have("docker")

    monkeypatch.setattr(prereqs.shutil, "which", lambda _cmd: None)
    assert not prereqs._have("docker")


def test_passwordless_sudo_checks(monkeypatch: pytest.MonkeyPatch) -> None:
    def _must_not_run(*_args: object, **_kwargs: object) -> None:
        raise AssertionError("root must not inspect or invoke sudo")

    monkeypatch.setattr(prereqs.os, "geteuid", lambda: 0, raising=False)
    monkeypatch.setattr(prereqs, "_have", _must_not_run)
    monkeypatch.setattr(prereqs.process, "probe", _must_not_run)
    prereqs._check_passwordless_sudo()

    monkeypatch.setattr(prereqs.os, "geteuid", lambda: 501, raising=False)
    monkeypatch.setattr(prereqs, "_have", lambda _cmd: False)
    with pytest.raises(prereqs.PrereqError, match=r"sudo is required.*apt-get install sudo"):
        prereqs._check_passwordless_sudo()

    monkeypatch.setattr(prereqs, "_have", lambda _cmd: True)

    monkeypatch.setattr(prereqs.process, "probe", lambda cmd, **_k: _never_ran(cmd))
    with pytest.raises(prereqs.PrereqError, match=r"could not exec sudo.*apt-get install sudo"):
        prereqs._check_passwordless_sudo()

    monkeypatch.setattr(prereqs.process, "probe", lambda cmd, **_k: _ran(cmd, returncode=1))
    with pytest.raises(prereqs.PrereqError, match=r"passwordless sudo.*NOPASSWD.*sudoers\.d"):
        prereqs._check_passwordless_sudo()

    def _probe(cmd: Sequence[str], **kwargs: object) -> process.CommandOutcome:
        assert list(cmd) == ["sudo", "-n", "true"]
        assert kwargs["timeout"] == 5
        return _ran(cmd)

    monkeypatch.setattr(prereqs.process, "probe", _probe)
    prereqs._check_passwordless_sudo()


def test_passwordless_sudo_on_host_without_geteuid(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delattr(prereqs.os, "geteuid", raising=False)
    monkeypatch.setattr(prereqs, "_have", lambda _cmd: True)
    monkeypatch.setattr(prereqs.process, "probe", lambda args, **_kwargs: _ran(args))
    prereqs._check_passwordless_sudo()


def test_ubuntu_check(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _patch_os_release(monkeypatch, tmp_path, 'ID="ubuntu"\nVERSION_ID="24.04"\n')
    prereqs._check_ubuntu_2404()

    for distro, version in (("debian", "12"), ("ubuntu", "22.04"), ("debian", "24.04")):
        _patch_os_release(monkeypatch, tmp_path, f'ID="{distro}"\nVERSION_ID="{version}"\n')
        with pytest.raises(prereqs.PrereqError, match=r"Ubuntu 24\.04"):
            prereqs._check_ubuntu_2404()

    _patch_os_release(monkeypatch, tmp_path, None)
    with pytest.raises(prereqs.PrereqError, match="cannot read"):
        prereqs._check_ubuntu_2404()


@pytest.mark.parametrize("machine", ["arm64", "aarch64", "ARM64", " AARCH64 "])
def test_macos_checks(monkeypatch: pytest.MonkeyPatch, machine: str) -> None:
    monkeypatch.setattr(prereqs.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(prereqs.platform, "machine", lambda: machine)
    prereqs._check_macos_arm64()

    monkeypatch.setattr(prereqs.platform, "machine", lambda: "x86_64")
    with pytest.raises(prereqs.PrereqError, match="Apple Silicon"):
        prereqs._check_macos_arm64()

    monkeypatch.setattr(prereqs.platform, "system", lambda: "Linux")
    with pytest.raises(prereqs.PrereqError, match="non-Darwin"):
        prereqs._check_macos_arm64()


def test_xcode_clt_check(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        prereqs.process,
        "probe",
        lambda cmd, **_k: _ran(cmd, stdout="/Library/Developer/CommandLineTools\n"),
    )
    prereqs._check_xcode_clt()

    monkeypatch.setattr(prereqs.process, "probe", lambda cmd, **_k: _ran(cmd, returncode=1))
    with pytest.raises(prereqs.PrereqError, match=r"Xcode.*xcode-select --install"):
        prereqs._check_xcode_clt()

    monkeypatch.setattr(prereqs.process, "probe", lambda cmd, **_k: _never_ran(cmd))
    with pytest.raises(prereqs.PrereqError, match=r"xcode-select failed.*xcode-select --install"):
        prereqs._check_xcode_clt()


def test_homebrew_check(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd == "brew")
    prereqs._check_homebrew()

    monkeypatch.setattr(prereqs, "_have", lambda _cmd: False)
    with pytest.raises(prereqs.PrereqError, match=r"Homebrew.*https://brew\.sh"):
        prereqs._check_homebrew()


def test_curl_check(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd == "curl")
    prereqs._check_curl()

    monkeypatch.setattr(prereqs, "_have", lambda _cmd: False)
    with pytest.raises(prereqs.PrereqError, match=r"curl.*apt-get install curl"):
        prereqs._check_curl()


def test_winget_check(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd == "winget")
    prereqs._check_winget()

    monkeypatch.setattr(prereqs, "_have", lambda _cmd: False)
    with pytest.raises(prereqs.PrereqError, match=r"winget.*Install App Installer"):
        prereqs._check_winget()


def test_powershell_check(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd == "powershell")
    prereqs._check_powershell()

    monkeypatch.setattr(prereqs, "_have", lambda _cmd: False)
    with pytest.raises(prereqs.PrereqError, match=r"PowerShell.*Enable Windows PowerShell"):
        prereqs._check_powershell()


def test_git_long_paths_enabled_reads_config(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd == "git")

    def _probe(args: Sequence[str], **_kwargs: object) -> process.CommandOutcome:
        assert list(args) == ["git", "config", "--type=bool", "--get", "core.longpaths"]
        # Git normalizes a configured "1" (and every other true spelling).
        return _ran(args, stdout="true\n")

    monkeypatch.setattr(prereqs.process, "probe", _probe)
    assert prereqs._git_long_paths_enabled() is True

    monkeypatch.setattr(
        prereqs.process, "probe", lambda args, **_k: _ran(args, returncode=1, stdout="")
    )
    assert prereqs._git_long_paths_enabled() is False


def test_git_long_paths_enabled_none_when_unusable(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs, "_have", lambda _cmd: False)
    assert prereqs._git_long_paths_enabled() is None

    monkeypatch.setattr(prereqs, "_have", lambda cmd: cmd == "git")

    monkeypatch.setattr(prereqs.process, "probe", lambda args, **_k: _never_ran(args, "no git"))
    assert prereqs._git_long_paths_enabled() is None


def test_windows_long_paths_policy_reads_registry(monkeypatch: pytest.MonkeyPatch) -> None:
    enabled = f"{prereqs._LONG_PATHS_KEY}\n    LongPathsEnabled    REG_DWORD    0x1\n"
    monkeypatch.setattr(prereqs.process, "probe", lambda args, **_k: _ran(args, stdout=enabled))
    assert prereqs._windows_long_paths_policy_enabled()

    disabled = enabled.replace("0x1", "0x0")
    monkeypatch.setattr(prereqs.process, "probe", lambda args, **_k: _ran(args, stdout=disabled))
    assert not prereqs._windows_long_paths_policy_enabled()

    monkeypatch.setattr(
        prereqs.process, "probe", lambda args, **_k: _ran(args, returncode=1, stdout="")
    )
    assert not prereqs._windows_long_paths_policy_enabled()


def test_windows_long_paths_policy_false_when_reg_unavailable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(prereqs.process, "probe", lambda args, **_k: _never_ran(args, "no reg.exe"))
    assert not prereqs._windows_long_paths_policy_enabled()


def test_long_paths_status_reports_without_raising(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs, "_git_long_paths_enabled", lambda: None)
    assert prereqs._long_paths_status() == "long paths: git not found; core.longpaths not verified"

    monkeypatch.setattr(prereqs, "_git_long_paths_enabled", lambda: True)
    monkeypatch.setattr(prereqs, "_windows_long_paths_policy_enabled", lambda: True)
    assert prereqs._long_paths_status() == "long paths: OK"

    monkeypatch.setattr(prereqs, "_git_long_paths_enabled", lambda: False)
    git_only = prereqs._long_paths_status()
    assert "core.longpaths" in git_only
    assert "LongPathsEnabled" not in git_only
    assert "MAX_PATH" in git_only

    monkeypatch.setattr(prereqs, "_git_long_paths_enabled", lambda: True)
    monkeypatch.setattr(prereqs, "_windows_long_paths_policy_enabled", lambda: False)
    policy_only = prereqs._long_paths_status()
    assert "LongPathsEnabled" in policy_only
    assert "core.longpaths" not in policy_only

    monkeypatch.setattr(prereqs, "_git_long_paths_enabled", lambda: False)
    both = prereqs._long_paths_status()
    assert "core.longpaths" in both
    assert "LongPathsEnabled" in both


async def test_run_linux_minimums(monkeypatch: pytest.MonkeyPatch) -> None:
    # The Linux floor is the build floor on every substrate: only Ubuntu +
    # passwordless sudo plus curl for the pinned GHCup download. KVM and the linux-gpu NVIDIA runtime moved to the
    # binary's ``ensure`` logic, so there is no CPU/GPU distinction here.
    calls: list[str] = []
    monkeypatch.setattr(prereqs, "_check_ubuntu_2404", lambda: calls.append("ubuntu"))
    monkeypatch.setattr(prereqs, "_check_passwordless_sudo", lambda: calls.append("sudo"))
    monkeypatch.setattr(prereqs, "_check_curl", lambda: calls.append("curl"))

    for name in (SubstrateName.LINUX_CPU, SubstrateName.LINUX_GPU):
        calls.clear()
        result = await prereqs._run_linux(Substrate(name, Arch.AMD64))
        assert calls == ["ubuntu", "sudo", "curl"]
        assert result.messages == (
            "Ubuntu 24.04: OK",
            "passwordless sudo: OK",
            "curl: OK",
        )


async def test_run_apple_minimums(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[str] = []
    monkeypatch.setattr(prereqs, "_check_macos_arm64", lambda: calls.append("mac"))
    monkeypatch.setattr(prereqs, "_check_xcode_clt", lambda: calls.append("xcode"))
    monkeypatch.setattr(prereqs, "_check_passwordless_sudo", lambda: calls.append("sudo"))
    monkeypatch.setattr(prereqs, "_check_homebrew", lambda: calls.append("brew"))

    result = await prereqs._run_apple(Substrate(SubstrateName.APPLE_SILICON, Arch.ARM64))

    assert calls == ["mac", "xcode", "sudo", "brew"]
    assert result.messages == (
        "macOS arm64: OK",
        "Xcode Command Line Tools: OK",
        "passwordless sudo: OK",
        "Homebrew: OK",
    )


async def test_run_windows_minimums(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[str] = []
    monkeypatch.setattr(prereqs, "_check_winget", lambda: calls.append("winget"))
    monkeypatch.setattr(prereqs, "_check_powershell", lambda: calls.append("powershell"))
    monkeypatch.setattr(prereqs, "_long_paths_status", lambda: "long paths: OK")

    result = await prereqs._run_windows(Substrate(SubstrateName.WINDOWS_CPU, Arch.AMD64))

    assert calls == ["winget", "powershell"]
    assert result.messages == ("winget: OK", "PowerShell: OK", "long paths: OK")
    assert not result.reboot_required


async def test_run_windows_long_path_advisory_never_aborts(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A host missing long-path support still passes doctor; the message is advisory."""
    monkeypatch.setattr(prereqs, "_check_winget", lambda: None)
    monkeypatch.setattr(prereqs, "_check_powershell", lambda: None)
    monkeypatch.setattr(prereqs, "_git_long_paths_enabled", lambda: False)
    monkeypatch.setattr(prereqs, "_windows_long_paths_policy_enabled", lambda: False)

    result = await prereqs._run_windows(Substrate(SubstrateName.WINDOWS_CPU, Arch.AMD64))

    assert result.messages[-1].startswith("long paths: not fully enabled")
    assert not result.reboot_required


@pytest.mark.parametrize(
    ("name", "branch"),
    [
        (SubstrateName.LINUX_CPU, "linux"),
        (SubstrateName.LINUX_GPU, "linux"),
        (SubstrateName.APPLE_SILICON, "apple"),
        (SubstrateName.WINDOWS_CPU, "windows"),
        (SubstrateName.WINDOWS_GPU, "windows"),
    ],
)
async def test_run_doctor_dispatches_by_substrate(
    monkeypatch: pytest.MonkeyPatch, name: SubstrateName, branch: str
) -> None:
    detected = Substrate(name, Arch.ARM64 if name is SubstrateName.APPLE_SILICON else Arch.AMD64)
    calls: list[str] = []

    async def _linux(sub: Substrate) -> prereqs.DoctorResult:
        calls.append("linux")
        return prereqs.DoctorResult(sub, ("linux",))

    async def _apple(sub: Substrate) -> prereqs.DoctorResult:
        calls.append("apple")
        return prereqs.DoctorResult(sub, ("apple",))

    async def _windows(sub: Substrate) -> prereqs.DoctorResult:
        calls.append("windows")
        return prereqs.DoctorResult(sub, ("windows",))

    monkeypatch.setattr(prereqs, "_run_linux", _linux)
    monkeypatch.setattr(prereqs, "_run_apple", _apple)
    monkeypatch.setattr(prereqs, "_run_windows", _windows)

    result = await prereqs.run_doctor(detected)
    assert result.substrate is detected
    assert result.messages == (branch,)
    assert calls == [branch]


async def test_run_doctor_refuses_an_unknown_substrate() -> None:
    unknown = Substrate(cast(SubstrateName, "unknown"), Arch.AMD64)
    with pytest.raises(AssertionError, match="Expected code to be unreachable"):
        await prereqs.run_doctor(unknown)


@pytest.mark.parametrize("check", ["_check_passwordless_sudo", "_check_xcode_clt"])
def test_required_probe_timeout_reports_timeout(
    monkeypatch: pytest.MonkeyPatch, check: str
) -> None:
    monkeypatch.setattr(prereqs.os, "geteuid", lambda: 501, raising=False)
    monkeypatch.setattr(prereqs, "_have", lambda _cmd: True)
    monkeypatch.setattr(
        prereqs.process, "probe", lambda args, **_kwargs: process.CommandTimedOut(tuple(args), 5)
    )
    with pytest.raises(prereqs.PrereqError, match="command timed out after 5s"):
        getattr(prereqs, check)()


def test_advisory_probe_timeout_does_not_abort(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(prereqs, "_have", lambda _cmd: True)
    monkeypatch.setattr(
        prereqs.process, "probe", lambda args, **_kwargs: process.CommandTimedOut(tuple(args), 5)
    )
    assert prereqs._git_long_paths_enabled() is None
    assert not prereqs._windows_long_paths_policy_enabled()


@pytest.mark.parametrize(
    ("runner", "checks"),
    [
        (prereqs._run_linux, ("_check_ubuntu_2404", "_check_passwordless_sudo", "_check_curl")),
        (
            prereqs._run_apple,
            (
                "_check_macos_arm64",
                "_check_xcode_clt",
                "_check_passwordless_sudo",
                "_check_homebrew",
            ),
        ),
        (prereqs._run_windows, ("_check_winget", "_check_powershell", "_long_paths_status")),
    ],
)
async def test_doctor_stops_at_first_missing_prerequisite(
    monkeypatch: pytest.MonkeyPatch,
    runner: Callable[[Substrate], Awaitable[prereqs.DoctorResult]],
    checks: tuple[str, ...],
) -> None:
    calls: list[str] = []

    def _refuse() -> None:
        calls.append(checks[0])
        raise prereqs.PrereqError("missing prerequisite")

    def _must_not_run() -> None:
        raise AssertionError("doctor must stop after its first refusal")

    monkeypatch.setattr(prereqs, checks[0], _refuse)
    for check in checks[1:]:
        monkeypatch.setattr(prereqs, check, _must_not_run)
    with pytest.raises(prereqs.PrereqError, match="missing prerequisite"):
        await runner(Substrate(SubstrateName.LINUX_CPU, Arch.AMD64))
    assert calls == [checks[0]]


def test_run_doctor_sync_wraps_async(monkeypatch: pytest.MonkeyPatch) -> None:
    linux = Substrate(SubstrateName.LINUX_CPU, Arch.AMD64)

    async def _linux(_sub: Substrate) -> prereqs.DoctorResult:
        return prereqs.DoctorResult(linux, ("ok",))

    monkeypatch.setattr(prereqs, "_run_linux", _linux)
    assert prereqs.run_doctor_sync(linux).messages == ("ok",)
