"""The one place this package launches a subprocess.

Two shapes, one vocabulary. The asynchronous :func:`run` is a thin layer over
:mod:`asyncio.create_subprocess_exec`: output is streamed to the parent's
stdout/stderr in real time (so long-running builds show progress live) while
also being captured into a frozen :class:`CommandResult`. The synchronous
:func:`probe` is for the short host questions asked before any event loop
exists, and names the child's stdio disposition with :class:`Stdio`.

A command can return non-zero, fail to start, or exceed its deadline. :func:`probe`
returns that distinction as a value — :class:`CommandResult`,
:class:`CommandUnavailable`, or :class:`CommandTimedOut` — so a caller reads the outcome rather than
off which exception it happened to catch, and wraps the one value into its own
error type.

``run_checked`` and ``run_checked_sync`` raise :class:`CommandError` when the
command was expected to succeed and did not (fail-fast).
"""

from __future__ import annotations

import asyncio
import codecs
import os
import subprocess
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import TextIO, cast


class Stdio(StrEnum):
    """Where a synchronous child's output goes."""

    CAPTURE = "capture"
    INHERIT = "inherit"


@dataclass(frozen=True)
class CommandResult:
    args: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.returncode == 0


@dataclass(frozen=True)
class CommandUnavailable:
    """The command never ran: its executable could not be launched at all."""

    args: tuple[str, ...]
    reason: str

    @property
    def ok(self) -> bool:
        return False


@dataclass(frozen=True)
class CommandTimedOut:
    """The child exceeded the execution deadline and was terminated."""

    args: tuple[str, ...]
    timeout: float

    @property
    def ok(self) -> bool:
        return False


CommandOutcome = CommandResult | CommandUnavailable | CommandTimedOut


def describe(outcome: CommandOutcome) -> str:
    rendered = " ".join(outcome.args)
    if isinstance(outcome, CommandUnavailable):
        return f"command could not be run ({outcome.reason}): {rendered}"
    if isinstance(outcome, CommandTimedOut):
        return f"command timed out after {outcome.timeout:g}s: {rendered}"
    return f"command failed ({outcome.returncode}): {rendered}"


class CommandError(RuntimeError):
    """A command expected to succeed did not.

    ``outcome`` says which failure occurred, and ``result`` is the completed run
    when there was one.
    """

    def __init__(self, outcome: CommandOutcome) -> None:
        super().__init__(describe(outcome))
        self.outcome = outcome

    @property
    def result(self) -> CommandResult | None:
        return self.outcome if isinstance(self.outcome, CommandResult) else None


def merged_environment(env: Mapping[str, str]) -> dict[str, str]:
    """This process's environment with *env* layered over it."""
    merged = dict(os.environ)
    merged.update(env)
    return merged


def rendered_windows_commandline_length(args: Sequence[str]) -> int:
    """Length of the argv rendering passed to Windows CreateProcess."""
    return len(subprocess.list2cmdline(args))


def probe(
    cmd: Sequence[str],
    *,
    cwd: Path | str | None = None,
    env: Mapping[str, str] | None = None,
    timeout: float | None = None,
    stdio: Stdio = Stdio.CAPTURE,
) -> CommandOutcome:
    """Run *cmd* to completion synchronously and say what happened.

    Never raises for a command that simply failed, and never raises for one that
    could not be started: both are outcomes. With :data:`Stdio.INHERIT` the child
    writes straight to this process's streams and the captured text is empty.
    """
    argv = tuple(cmd)
    where = str(cwd) if cwd is not None else None
    environment = merged_environment(env) if env is not None else None
    try:
        if stdio is Stdio.CAPTURE:
            captured = subprocess.run(
                list(argv),
                cwd=where,
                env=environment,
                capture_output=True,
                encoding="utf-8",
                errors="replace",
                timeout=timeout,
                check=False,
            )
            return CommandResult(argv, captured.returncode, captured.stdout, captured.stderr)
        inherited = subprocess.run(
            list(argv), cwd=where, env=environment, timeout=timeout, check=False
        )
        return CommandResult(argv, inherited.returncode, "", "")
    except subprocess.TimeoutExpired:
        # subprocess may report its remaining wait budget. The outcome retains
        # the caller's deadline, which is present whenever a timeout can occur.
        return CommandTimedOut(argv, cast(float, timeout))
    except (OSError, subprocess.SubprocessError) as exc:
        return CommandUnavailable(argv, str(exc))


def run_checked_sync(
    cmd: Sequence[str],
    *,
    cwd: Path | str | None = None,
    env: Mapping[str, str] | None = None,
    timeout: float | None = None,
    stdio: Stdio = Stdio.CAPTURE,
) -> CommandResult:
    """Run *cmd* synchronously and raise :class:`CommandError` unless it succeeded."""
    outcome = probe(cmd, cwd=cwd, env=env, timeout=timeout, stdio=stdio)
    if isinstance(outcome, CommandResult) and outcome.ok:
        return outcome
    raise CommandError(outcome)


async def _drain(
    stream: asyncio.StreamReader | None,
    sink_lines: list[str],
    mirror: TextIO,
    prefix: str = "",
) -> None:
    if stream is None:
        return
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    pending = ""

    def emit(text: str) -> None:
        sink_lines.append(text)
        labelled = prefix + text
        encoding = mirror.encoding or "utf-8"
        mirror.write(labelled.encode(encoding, errors="replace").decode(encoding))
        mirror.flush()

    while True:
        chunk = await stream.read(65536)
        if not chunk:
            pending += decoder.decode(b"", final=True)
            if pending:
                emit(pending)
            return
        pending += decoder.decode(chunk)
        while "\n" in pending:
            line, pending = pending.split("\n", 1)
            emit(line.removesuffix("\r") + "\n")


async def run(
    cmd: Sequence[str],
    *,
    cwd: Path | str | None = None,
    env: Mapping[str, str] | None = None,
    quiet: bool = False,
    prefix: str = "",
) -> CommandResult:
    """Run *cmd* asynchronously, streaming output and capturing the result.

    When *prefix* is given, every mirrored output line is prepended with it so
    concurrent runs stay legible (the captured ``stdout``/``stderr`` stay raw).
    """

    effective_env = merged_environment(env) if env is not None else None

    argv = tuple(cmd)
    try:
        process = await asyncio.create_subprocess_exec(
            *argv,
            cwd=str(cwd) if cwd is not None else None,
            env=effective_env,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except OSError as exc:
        raise CommandError(CommandUnavailable(argv, str(exc))) from exc

    out_lines: list[str] = []
    err_lines: list[str] = []

    out_sink = open(os.devnull, "w") if quiet else sys.stdout  # noqa: SIM115
    err_sink = open(os.devnull, "w") if quiet else sys.stderr  # noqa: SIM115

    drains = [
        asyncio.create_task(_drain(process.stdout, out_lines, out_sink, prefix)),
        asyncio.create_task(_drain(process.stderr, err_lines, err_sink, prefix)),
    ]
    try:
        await asyncio.gather(*drains)
        returncode = await process.wait()
    except BaseException:
        for task in drains:
            task.cancel()
        if process.returncode is None:
            process.kill()
        await process.wait()
        await asyncio.gather(*drains, return_exceptions=True)
        raise
    finally:
        if quiet:
            out_sink.close()
            err_sink.close()

    return CommandResult(
        args=tuple(cmd),
        returncode=returncode,
        stdout="".join(out_lines),
        stderr="".join(err_lines),
    )


async def run_checked(
    cmd: Sequence[str],
    *,
    cwd: Path | str | None = None,
    env: Mapping[str, str] | None = None,
    quiet: bool = False,
    prefix: str = "",
) -> CommandResult:
    result = await run(cmd, cwd=cwd, env=env, quiet=quiet, prefix=prefix)
    if not result.ok:
        raise CommandError(result)
    return result
