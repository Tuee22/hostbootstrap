"""Unit tests for subprocess result capture."""

from __future__ import annotations

import asyncio
import io
import sys
from pathlib import Path

import pytest

from hostbootstrap import process


async def test_drain_none_is_noop() -> None:
    lines: list[str] = []
    mirror = io.StringIO()

    await process._drain(None, lines, mirror)

    assert lines == []
    assert mirror.getvalue() == ""


async def test_drain_prefixes_mirror_but_keeps_lines_raw() -> None:
    reader = asyncio.StreamReader()
    reader.feed_data(b"one\ntwo\n")
    reader.feed_eof()
    lines: list[str] = []
    mirror = io.StringIO()

    await process._drain(reader, lines, mirror, "[cpu ] ")

    # Captured lines stay raw; only the live mirror is labelled.
    assert lines == ["one\n", "two\n"]
    assert mirror.getvalue() == "[cpu ] one\n[cpu ] two\n"


async def test_run_captures_stdout_stderr_env_and_quiet() -> None:
    script = (
        "import os, sys; "
        "print(os.environ['HOSTBOOTSTRAP_PROCESS_TEST']); "
        "print('err', file=sys.stderr)"
    )

    result = await process.run(
        [sys.executable, "-c", script],
        env={"HOSTBOOTSTRAP_PROCESS_TEST": "ok"},
        quiet=True,
    )

    assert result.ok
    assert result.stdout == "ok\n"
    assert result.stderr == "err\n"


async def test_run_checked_success_and_failure() -> None:
    ok = await process.run_checked([sys.executable, "-c", "print('shown')"])
    assert ok.ok
    assert ok.stdout == "shown\n"

    with pytest.raises(process.CommandError) as caught:
        await process.run_checked([sys.executable, "-c", "import sys; sys.exit(3)"], quiet=True)

    assert caught.value.result.returncode == 3
    assert "command failed (3)" in str(caught.value)


def test_probe_captures_a_completed_run() -> None:
    outcome = process.probe(
        [sys.executable, "-c", "import sys; print('out'); print('err', file=sys.stderr)"]
    )

    assert isinstance(outcome, process.CommandResult)
    assert outcome.ok
    assert outcome.stdout == "out\n"
    assert outcome.stderr == "err\n"


def test_probe_reports_a_failed_run_as_a_result(tmp_path: Path) -> None:
    outcome = process.probe(
        [sys.executable, "-c", "import sys; sys.exit(4)"],
        cwd=tmp_path,
        stdio=process.Stdio.INHERIT,
    )

    assert isinstance(outcome, process.CommandResult)
    assert outcome.returncode == 4
    assert outcome.stdout == ""


def test_probe_reports_a_command_that_never_ran() -> None:
    outcome = process.probe(["hostbootstrap-no-such-executable"])

    assert isinstance(outcome, process.CommandUnavailable)
    assert not outcome.ok
    assert "hostbootstrap-no-such-executable" in process.describe(outcome)


def test_run_checked_sync_raises_for_both_ways_of_not_succeeding() -> None:
    ok = process.run_checked_sync([sys.executable, "-c", "print('fine')"])
    assert ok.stdout == "fine\n"

    with pytest.raises(process.CommandError) as failed:
        process.run_checked_sync([sys.executable, "-c", "import sys; sys.exit(5)"])
    assert failed.value.result is not None
    assert failed.value.result.returncode == 5

    with pytest.raises(process.CommandError) as unavailable:
        process.run_checked_sync(["hostbootstrap-no-such-executable"])
    assert unavailable.value.result is None
    assert "could not be run" in str(unavailable.value)
