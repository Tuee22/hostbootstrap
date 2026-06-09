"""Unit tests for subprocess result capture."""

from __future__ import annotations

import io
import sys

import pytest

from hostbootstrap import process


async def test_drain_none_is_noop() -> None:
    lines: list[str] = []
    mirror = io.StringIO()

    await process._drain(None, lines, mirror)

    assert lines == []
    assert mirror.getvalue() == ""


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
