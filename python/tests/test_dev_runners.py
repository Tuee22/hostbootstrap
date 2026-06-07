"""Unit tests for development-only command runners."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import subprocess
import warnings
from pathlib import Path

import pytest

from hostbootstrap import check_code, cli, test_all


def _exec_file_as_main(path: Path, package: str) -> None:
    loader = importlib.machinery.SourceFileLoader("__main__", str(path))
    spec = importlib.util.spec_from_loader("__main__", loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    module.__package__ = package
    with warnings.catch_warnings():
        warnings.filterwarnings(
            "ignore",
            message="__package__ != __spec__.parent",
            category=DeprecationWarning,
        )
        loader.exec_module(module)


def test_check_code_run_returns_subprocess_code(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fake_run(cmd: tuple[str, ...], *, check: bool) -> subprocess.CompletedProcess[str]:
        assert cmd == ("ruff", "check")
        assert check is False
        return subprocess.CompletedProcess(cmd, 7)

    monkeypatch.setattr(check_code.subprocess, "run", _fake_run)

    assert check_code._run(("ruff", "check")) == 7


def test_check_code_main_success_and_fail_fast(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[tuple[str, ...]] = []

    def _ok(cmd: tuple[str, ...]) -> int:
        calls.append(cmd)
        return 0

    monkeypatch.setattr(check_code, "_run", _ok)
    assert check_code.main() == 0
    assert [cmd[0] for cmd in calls] == ["ruff", "black", "mypy"]

    calls.clear()

    def _fail_on_black(cmd: tuple[str, ...]) -> int:
        calls.append(cmd)
        return 5 if cmd[0] == "black" else 0

    monkeypatch.setattr(check_code, "_run", _fail_on_black)
    assert check_code.main() == 5
    assert [cmd[0] for cmd in calls] == ["ruff", "black"]


def test_test_all_main_sets_sentinel_and_forwards_args(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, object] = {}

    def _fake_main(args: list[str]) -> int:
        captured["args"] = args
        captured["sentinel"] = test_all.os.environ["HOSTBOOTSTRAP_TEST_ALL"]
        return 4

    monkeypatch.setattr(test_all, "_pytest_main", _fake_main)
    monkeypatch.setattr(test_all.sys, "argv", ["test_all", "-k", "models"])

    assert test_all.main() == 4
    assert captured["args"] == ["tests", "-k", "models"]
    assert captured["sentinel"] == "1"


def test_module_entrypoints_exit(monkeypatch: pytest.MonkeyPatch) -> None:
    def _fake_run(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(args, 0)

    def _fake_pytest_main(_args: list[str]) -> int:
        return 0

    monkeypatch.setattr(subprocess, "run", _fake_run)
    monkeypatch.setattr(test_all, "_pytest_main", _fake_pytest_main)
    monkeypatch.setattr(pytest, "main", _fake_pytest_main)
    monkeypatch.setattr("sys.argv", ["runner"])

    with pytest.raises(SystemExit) as check_exit:
        _exec_file_as_main(Path(check_code.__file__), "hostbootstrap")
    assert check_exit.value.code == 0

    with pytest.raises(SystemExit) as test_exit:
        _exec_file_as_main(Path(test_all.__file__), "hostbootstrap")
    assert test_exit.value.code == 0

    monkeypatch.setattr("sys.argv", ["hostbootstrap", "--help"])
    with pytest.raises(SystemExit) as cli_exit:
        _exec_file_as_main(Path(cli.__file__), "hostbootstrap")
    assert cli_exit.value.code == 0
