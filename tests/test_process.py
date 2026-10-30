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


async def test_run_captures_stdout_stderr_env_and_quiet(
    monkeypatch: pytest.MonkeyPatch, capfd: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("HOSTBOOTSTRAP_PROCESS_PARENT", "inherited")
    script = (
        "import os, sys; "
        "print(os.environ['HOSTBOOTSTRAP_PROCESS_TEST']); "
        "print(os.environ['HOSTBOOTSTRAP_PROCESS_PARENT']); "
        "print('err', file=sys.stderr)"
    )

    result = await process.run(
        [sys.executable, "-c", script],
        env={"HOSTBOOTSTRAP_PROCESS_TEST": "ok"},
        quiet=True,
    )

    assert result.ok
    assert result.stdout == "ok\ninherited\n"
    assert result.stderr == "err\n"
    assert capfd.readouterr() == ("", "")


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


@pytest.mark.parametrize("stdio", [process.Stdio.CAPTURE, process.Stdio.INHERIT])
def test_probe_reports_a_timeout_distinct_from_an_unavailable_command(stdio: process.Stdio) -> None:
    argv = (sys.executable, "-c", "import time; time.sleep(5)")
    outcome = process.probe(argv, timeout=0.1, stdio=stdio)
    assert outcome == process.CommandTimedOut(argv, 0.1)
    assert outcome.ok is False
    assert "timed out after 0.1s" in process.describe(outcome)
    with pytest.raises(process.CommandError) as caught:
        process.run_checked_sync(argv, timeout=0.1, stdio=stdio)
    assert isinstance(caught.value.outcome, process.CommandTimedOut)
    assert caught.value.result is None


def test_probe_replaces_undecodable_output_and_merges_environment(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("HOSTBOOTSTRAP_PROBE_PARENT", "parent")
    script = "import os; os.write(1, os.environ['HOSTBOOTSTRAP_PROBE_PARENT'].encode()+b'\\x81\\x8d\\x8f\\x90\\x9d'); os.write(2, b'\\x81\\x8d\\x8f\\x90\\x9d')"
    outcome = process.probe(
        (sys.executable, "-c", script), env={"HOSTBOOTSTRAP_PROBE_CHILD": "child"}
    )
    assert isinstance(outcome, process.CommandResult)
    assert outcome.stdout == "parent" + "\ufffd" * 5
    assert outcome.stderr == "\ufffd" * 5


async def test_run_mirrors_output_with_a_prefix(
    capfd: pytest.CaptureFixture[str], tmp_path: Path
) -> None:
    result = await process.run(
        (sys.executable, "-c", "import sys; print('out'); print('err', file=sys.stderr)"),
        cwd=tmp_path,
        prefix="[one] ",
    )
    assert result.stdout == "out\n"
    assert result.stderr == "err\n"
    assert capfd.readouterr() == ("[one] out\n", "[one] err\n")


async def test_run_captures_lines_larger_than_the_stream_limit() -> None:
    result = await process.run(
        (
            sys.executable,
            "-c",
            "import os; os.write(1, b'x'*200000+b'\\nlast'); os.write(2, b'\\xff')",
        ),
        quiet=True,
    )
    assert result.stdout == "x" * 200000 + "\nlast"
    assert result.stderr == "\ufffd"


async def test_drain_preserves_split_utf8_and_replaces_for_the_mirror_encoding() -> None:
    class _Chunks:
        def __init__(self) -> None:
            self.chunks = iter((b"one\r", b"\n\xe2", b"\x82\xac\nlast", b""))

        async def read(self, size: int) -> bytes:
            assert size == 65536
            return next(self.chunks)

    lines: list[str] = []
    buffer = io.BytesIO()
    mirror = io.TextIOWrapper(buffer, encoding="ascii", newline="\n")
    await process._drain(_Chunks(), lines, mirror, "[x] ")  # type: ignore[arg-type]
    assert lines == ["one\n", "\u20ac\n", "last"]
    assert buffer.getvalue() == b"[x] one\n[x] ?\n[x] last"


async def test_run_reports_an_executable_it_cannot_launch() -> None:
    with pytest.raises(process.CommandError) as caught:
        await process.run(("hostbootstrap-no-such-executable",))
    assert isinstance(caught.value.outcome, process.CommandUnavailable)
    assert caught.value.outcome.args == ("hostbootstrap-no-such-executable",)


async def test_run_reaps_the_child_when_the_mirror_fails(monkeypatch: pytest.MonkeyPatch) -> None:
    children: list[asyncio.subprocess.Process] = []
    real_create = asyncio.create_subprocess_exec

    async def _capture(*args: object, **kwargs: object) -> asyncio.subprocess.Process:
        child = await real_create(*args, **kwargs)
        children.append(child)
        return child

    class _BrokenMirror(io.StringIO):
        def write(self, text: str) -> int:
            raise RuntimeError("mirror failed")

    with monkeypatch.context() as scoped:
        scoped.setattr(process.asyncio, "create_subprocess_exec", _capture)
        scoped.setattr(process.sys, "stdout", _BrokenMirror())
        with pytest.raises(RuntimeError, match="mirror failed"):
            await process.run(
                (sys.executable, "-c", "import time; print('ready', flush=True); time.sleep(30)")
            )
    assert len(children) == 1
    assert children[0].returncode is not None


async def test_run_awaits_an_already_exited_child_on_drain_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    waited: list[bool] = []

    class _Exited:
        returncode = 0
        stdout = None
        stderr = None

        async def wait(self) -> int:
            waited.append(True)
            return 0

        def kill(self) -> None:
            raise AssertionError("an exited child must not be killed")

    async def _create(*_args: object, **_kwargs: object) -> _Exited:
        return _Exited()

    async def _failed(*_args: object) -> None:
        raise RuntimeError("drain failed")

    monkeypatch.setattr(process.asyncio, "create_subprocess_exec", _create)
    monkeypatch.setattr(process, "_drain", _failed)
    with pytest.raises(RuntimeError, match="drain failed"):
        await process.run(("exited-child",), quiet=True)
    assert waited == [True]


def test_rendered_windows_commandline_length_includes_quoting() -> None:
    assert process.rendered_windows_commandline_length(("tool", "a b", 'c"d')) == len(
        'tool "a b" c\\"d'
    )
