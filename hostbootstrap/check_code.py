"""Development check runner: ruff → black → mypy(strict), fail-fast."""

from __future__ import annotations

import sys
from collections.abc import Sequence
from typing import Final

from . import process

_PACKAGES: Final[tuple[str, ...]] = ("hostbootstrap",)


# A tool that cannot be launched is reported the way a shell reports it, so a
# missing dev dependency reads as a failed step rather than as a traceback.
_NOT_EXECUTABLE: Final[int] = 127


def _run(cmd: Sequence[str]) -> int:
    print(f"$ {' '.join(cmd)}", flush=True)
    outcome = process.probe(cmd, stdio=process.Stdio.INHERIT)
    if isinstance(outcome, process.CommandUnavailable):
        print(outcome.reason, flush=True)
        return _NOT_EXECUTABLE
    return outcome.returncode


def main() -> int:
    for step in (
        ("ruff", "check", *_PACKAGES),
        ("black", "--check", *_PACKAGES),
        ("mypy", *_PACKAGES),
    ):
        rc = _run(step)
        if rc != 0:
            return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())
