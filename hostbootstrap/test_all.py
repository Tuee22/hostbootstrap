"""Development test runner for the full hostbootstrap test suite.

This is the supported way to run the tests. Invoking ``pytest`` directly is
refused by ``tests/conftest.py`` (it checks the ``HOSTBOOTSTRAP_TEST_ALL``
sentinel this runner sets), so the suite always runs through one command
with one configuration. Extra arguments are forwarded to pytest, e.g.
``poetry run python -m hostbootstrap.test_all -k docker_ops -q``.
"""

from __future__ import annotations

import importlib
import os
import sys
from typing import Protocol, cast

_SENTINEL: str = "HOSTBOOTSTRAP_TEST_ALL"


class _PytestModule(Protocol):
    def main(self, args: list[str]) -> int: ...


def _pytest_main(args: list[str]) -> int:
    pytest = cast(_PytestModule, importlib.import_module("pytest"))
    return int(pytest.main(args))


def main() -> int:
    os.environ[_SENTINEL] = "1"
    return _pytest_main(["tests", *sys.argv[1:]])


if __name__ == "__main__":
    sys.exit(main())
