"""Shared fixtures and the direct-pytest blocker.

The suite must be run via ``poetry run python -m hostbootstrap.test_all`` (see
``hostbootstrap/test_all.py``), which sets the ``HOSTBOOTSTRAP_TEST_ALL``
sentinel. Running ``pytest`` directly is refused here so there is exactly one
supported entry point and configuration.
"""

from __future__ import annotations

import os
from collections.abc import Iterator
from pathlib import Path

import pytest

from hostbootstrap import bootstrap, process


def pytest_configure(config: pytest.Config) -> None:
    if os.environ.get("HOSTBOOTSTRAP_TEST_ALL") != "1":
        raise pytest.UsageError(
            "Run the test suite with `poetry run python -m hostbootstrap.test_all` "
            "(not pytest directly). hostbootstrap.test_all forwards extra args to pytest."
        )


@pytest.fixture
def recorded_commands(monkeypatch: pytest.MonkeyPatch) -> list[tuple[str, ...]]:
    """Replace process.run/run_checked with recorders; return the captured argv list.

    Every recorded command succeeds (``returncode=0``). Since the toolchain-ensure
    probes go through ``process.run``, this models the common *already-provisioned*
    host: each probe reports the tool present, so no ``ghcup install`` runs.
    """
    calls: list[tuple[str, ...]] = []

    async def _fake(cmd: object, **_: object) -> process.CommandResult:
        argv = tuple(str(part) for part in cmd)  # type: ignore[union-attr]
        calls.append(argv)
        return process.CommandResult(args=argv, returncode=0, stdout="", stderr="")

    monkeypatch.setattr(process, "run", _fake)
    monkeypatch.setattr(process, "run_checked", _fake)
    # _build_native copies the located binary to the stable path; with the fakes
    # above there is no real source file, so stub the copy to keep tests off-disk.
    monkeypatch.setattr(bootstrap.shutil, "copy2", lambda *a, **k: None)
    return calls


@pytest.fixture
def recorded_commands_fresh_host(monkeypatch: pytest.MonkeyPatch) -> list[tuple[str, ...]]:
    """Like :func:`recorded_commands`, but models a *pristine* host.

    The toolchain-ensure probes (``process.run``) report the tool **absent**
    (``returncode=1``), so every ``ghcup install`` (and Homebrew, on Apple) runs;
    installs and the native build (``process.run_checked``) succeed.
    """
    calls: list[tuple[str, ...]] = []

    async def _probe(cmd: object, **_: object) -> process.CommandResult:
        argv = tuple(str(part) for part in cmd)  # type: ignore[union-attr]
        calls.append(argv)
        return process.CommandResult(args=argv, returncode=1, stdout="", stderr="")

    async def _checked(cmd: object, **_: object) -> process.CommandResult:
        argv = tuple(str(part) for part in cmd)  # type: ignore[union-attr]
        calls.append(argv)
        return process.CommandResult(args=argv, returncode=0, stdout="", stderr="")

    monkeypatch.setattr(process, "run", _probe)
    monkeypatch.setattr(process, "run_checked", _checked)
    monkeypatch.setattr(bootstrap.shutil, "copy2", lambda *a, **k: None)
    return calls


@pytest.fixture
def project_root(tmp_path: Path) -> Iterator[Path]:
    """A throwaway project directory."""
    yield tmp_path
