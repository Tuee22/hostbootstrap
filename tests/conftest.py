"""Shared fixtures and the direct-pytest blocker.

The suite must be run via ``poetry run python -m hostbootstrap.test_all`` (see
``hostbootstrap/test_all.py``), which sets the ``HOSTBOOTSTRAP_TEST_ALL``
sentinel. Running ``pytest`` directly is refused here so there is exactly one
supported entry point and configuration.
"""

from __future__ import annotations

import os
from collections.abc import Sequence
from pathlib import Path
from typing import Literal

import pytest

from hostbootstrap import bootstrap, process

RecordedCommand = tuple[tuple[str, ...], Path | None, Literal["checked", "probe"]]


def pytest_configure(config: pytest.Config) -> None:
    if os.environ.get("HOSTBOOTSTRAP_TEST_ALL") != "1":
        raise pytest.UsageError(
            "Run the test suite with `poetry run python -m hostbootstrap.test_all` "
            "(not pytest directly). hostbootstrap.test_all forwards extra args to pytest."
        )


@pytest.fixture
def recorded_commands(monkeypatch: pytest.MonkeyPatch) -> list[RecordedCommand]:
    """Replace process.run/run_checked with recorders; return the captured argv list.

    Every recorded command succeeds (``returncode=0``). Since the toolchain-ensure
    probes go through ``process.run``, this models the common *already-provisioned*
    host: each probe reports the tool present, so no ``ghcup install`` runs.
    """
    calls: list[RecordedCommand] = []

    def _record(
        cmd: Sequence[str], kwargs: dict[str, object], kind: Literal["checked", "probe"]
    ) -> process.CommandResult:
        argv = tuple(cmd)
        if argv[0] != "docker" and "--hostbootstrap-install-identity" not in argv:
            assert kwargs.get("env") == bootstrap._toolchain_env()
        cwd = kwargs.get("cwd")
        assert cwd is None or isinstance(cwd, Path)
        calls.append((argv, cwd, kind))
        return process.CommandResult(args=argv, returncode=0, stdout="", stderr="")

    async def _probe(cmd: Sequence[str], **kwargs: object) -> process.CommandResult:
        return _record(cmd, kwargs, "probe")

    async def _checked(cmd: Sequence[str], **kwargs: object) -> process.CommandResult:
        return _record(cmd, kwargs, "checked")

    monkeypatch.setattr(process, "run", _probe)
    monkeypatch.setattr(process, "run_checked", _checked)
    monkeypatch.setattr(
        bootstrap,
        "cabal_index_state",
        lambda _index: bootstrap.CabalIndexState.MISSING,
    )
    # _build_native copies the located binary to the stable path; with the fakes
    # above there is no real source file, so stub the copy to keep tests off-disk.
    monkeypatch.setattr(bootstrap, "_copy_if_changed", lambda *a, **k: True)
    return calls


@pytest.fixture
def recorded_commands_fresh_host(monkeypatch: pytest.MonkeyPatch) -> list[RecordedCommand]:
    """Like :func:`recorded_commands`, but models a *pristine* host.

    The toolchain-ensure probes (``process.run``) report the tool **absent**
    (``returncode=1``), so every ``ghcup install`` (and Homebrew, on Apple) runs;
    installs and the native build (``process.run_checked``) succeed.
    """
    calls: list[RecordedCommand] = []

    def _record(
        cmd: Sequence[str],
        kwargs: dict[str, object],
        kind: Literal["checked", "probe"],
        returncode: int,
    ) -> process.CommandResult:
        argv = tuple(cmd)
        if argv[0] != "docker" and "--hostbootstrap-install-identity" not in argv:
            assert kwargs.get("env") == bootstrap._toolchain_env()
        cwd = kwargs.get("cwd")
        assert cwd is None or isinstance(cwd, Path)
        calls.append((argv, cwd, kind))
        return process.CommandResult(args=argv, returncode=returncode, stdout="", stderr="")

    async def _probe(cmd: Sequence[str], **kwargs: object) -> process.CommandResult:
        return _record(cmd, kwargs, "probe", 1)

    async def _checked(cmd: Sequence[str], **kwargs: object) -> process.CommandResult:
        return _record(cmd, kwargs, "checked", 0)

    monkeypatch.setattr(process, "run", _probe)
    monkeypatch.setattr(process, "run_checked", _checked)
    monkeypatch.setattr(
        bootstrap,
        "cabal_index_state",
        lambda _index: bootstrap.CabalIndexState.MISSING,
    )
    monkeypatch.setattr(bootstrap, "_copy_if_changed", lambda *a, **k: True)
    return calls
