"""Unit tests for development-only command runners."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import subprocess
import sys
import warnings
from pathlib import Path

import pytest

from hostbootstrap import bootstrap, check_code, cli, process, substrate, test_all


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


def test_check_code_run_returns_the_tool_exit_code(monkeypatch: pytest.MonkeyPatch) -> None:
    def _probe(cmd: tuple[str, ...], *, stdio: process.Stdio, cwd: Path) -> process.CommandOutcome:
        assert cmd == ("ruff", "check")
        assert stdio is process.Stdio.INHERIT
        assert cwd == Path(check_code.__file__).resolve().parents[1]
        return process.CommandResult(cmd, 7, "", "")

    monkeypatch.setattr(check_code.process, "probe", _probe)

    assert check_code._run(("ruff", "check")) == 7


def test_check_code_run_reports_a_tool_that_cannot_be_launched(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(
        check_code.process,
        "probe",
        lambda cmd, **_k: process.CommandUnavailable(tuple(cmd), "No such file: ruff"),
    )

    assert check_code._run(("ruff", "check")) == check_code._NOT_EXECUTABLE
    assert "No such file: ruff" in capsys.readouterr().out


def test_check_code_main_success_and_fail_fast(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[tuple[str, ...]] = []

    def _ok(cmd: tuple[str, ...]) -> int:
        calls.append(cmd)
        return 0

    monkeypatch.setattr(check_code, "_run", _ok)
    assert check_code.main() == 0
    assert calls == [
        (sys.executable, "-m", "ruff", "check", "hostbootstrap"),
        (sys.executable, "-m", "black", "--check", "hostbootstrap"),
        (sys.executable, "-m", "mypy", "hostbootstrap"),
    ]

    calls.clear()

    def _fail_on_black(cmd: tuple[str, ...]) -> int:
        calls.append(cmd)
        return 5 if cmd[2] == "black" else 0

    monkeypatch.setattr(check_code, "_run", _fail_on_black)
    assert check_code.main() == 5
    assert [cmd[2] for cmd in calls] == ["ruff", "black"]


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
    monkeypatch.setattr("sys.argv", ["runner", "-q"])

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


@pytest.mark.parametrize(
    ("args", "expected"),
    [
        (["tests/test_cli.py"], ["tests/test_cli.py"]),
        (["tests/test_cli.py::test_cli_help"], ["tests/test_cli.py::test_cli_help"]),
        (["-k", "models"], ["tests", "-k", "models"]),
        (["-q"], ["tests", "-q"]),
        (["--tb=short"], ["tests", "--tb=short"]),
        (["-m", "selected", "tests/test_cli.py"], ["-m", "selected", "tests/test_cli.py"]),
    ],
)
def test_test_all_forwards_paths_and_options(
    monkeypatch: pytest.MonkeyPatch, args: list[str], expected: list[str]
) -> None:
    captured: list[list[str]] = []
    monkeypatch.setattr(test_all, "_pytest_main", lambda argv: captured.append(argv) or 0)
    assert test_all.run(args) == 0
    assert captured == [expected]


@pytest.mark.parametrize(
    ("pytest_status", "measured", "expected"), [(0, 100.0, 0), (0, 99.0, 1), (3, 99.0, 3)]
)
def test_test_all_enforces_coverage_after_a_passing_full_run(
    monkeypatch: pytest.MonkeyPatch, pytest_status: int, measured: float, expected: int
) -> None:
    calls: list[str] = []

    class Measurement:
        def start(self) -> None:
            calls.append("start")

        def stop(self) -> None:
            calls.append("stop")

        def save(self) -> None:
            calls.append("save")

        def get_option(self, name: str) -> float:
            assert name == "report:fail_under"
            return 100.0

        def report(self) -> float:
            calls.append("report")
            return measured

    monkeypatch.setattr("coverage.Coverage", Measurement)
    monkeypatch.setattr(test_all, "_reload_package_modules", lambda: calls.append("reload"))

    def run_pytest(args: list[str]) -> int:
        assert args == ["tests"]
        calls.append("pytest")
        return pytest_status

    monkeypatch.setattr(test_all, "_pytest_main", run_pytest)
    assert test_all.run([]) == expected
    assert calls == ["start", "reload", "pytest", "stop", "save"] + (
        [] if pytest_status else ["report"]
    )


def test_test_all_filtered_run_does_not_measure_partial_coverage(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr("coverage.Coverage", lambda: pytest.fail("filtered run starts coverage"))
    monkeypatch.setattr(test_all, "_pytest_main", lambda args: 0 if args == ["tests", "-q"] else 1)
    assert test_all.run(["-q"]) == 0


def test_check_code_reports_a_timed_out_tool(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(
        check_code.process, "probe", lambda cmd, **kwargs: process.CommandTimedOut(tuple(cmd), 5)
    )
    assert check_code._run(("ruff", "check")) == check_code._NOT_EXECUTABLE
    assert "timed out after 5s" in capsys.readouterr().out


def test_coverage_reload_orders_real_dependencies_before_their_consumers() -> None:
    modules = {module.__name__: module for module in (bootstrap, substrate, process)}
    ordered = test_all._package_reload_order(modules)
    assert ordered == [process, substrate, bootstrap]
    assert len(ordered) == len(set(ordered))
