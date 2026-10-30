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
from collections.abc import Mapping
from types import ModuleType
from typing import TYPE_CHECKING, Protocol, cast

if TYPE_CHECKING:
    import coverage

_SENTINEL: str = "HOSTBOOTSTRAP_TEST_ALL"


class _PytestModule(Protocol):
    def main(self, args: list[str]) -> int: ...


def _pytest_main(args: list[str]) -> int:
    pytest = cast(_PytestModule, importlib.import_module("pytest"))
    return int(pytest.main(args))


def _pytest_args(args: list[str]) -> list[str]:
    value_options = {
        "-k",
        "-m",
        "-c",
        "-o",
        "-p",
        "--override-ini",
        "--maxfail",
        "--tb",
        "--capture",
        "--rootdir",
        "--confcutdir",
        "--basetemp",
        "--junitxml",
        "--junit-prefix",
        "--deselect",
        "--ignore",
        "--ignore-glob",
        "--import-mode",
    }
    value_follows = False
    for arg in args:
        if value_follows:
            value_follows = False
        elif arg.startswith("-"):
            value_follows = arg in value_options
        else:
            return args
    return ["tests", *args]


def _package_reload_order(modules: Mapping[str, ModuleType]) -> list[ModuleType]:
    visited: set[str] = set()
    ordered: list[ModuleType] = []

    def reload_module(name: str) -> None:
        if name in visited:
            return
        visited.add(name)
        module = modules[name]
        for value in tuple(vars(module).values()):
            dependency = (
                value.__name__
                if isinstance(value, ModuleType)
                else getattr(value, "__module__", "")
            )
            if dependency in modules:
                reload_module(dependency)
        ordered.append(module)

    for name in modules:
        reload_module(name)
    return ordered


def _reload_package_modules() -> None:
    """Count imported module bodies without leaving stale imported class identities."""
    modules = {
        name: module
        for name, module in tuple(sys.modules.items())
        if name.startswith("hostbootstrap") and isinstance(module, ModuleType)
    }
    for module in _package_reload_order(modules):
        importlib.reload(module)


def run(args: list[str]) -> int:
    os.environ[_SENTINEL] = "1"
    targets = _pytest_args(args)
    if args:
        return _pytest_main(targets)

    measurement = cast("coverage.Coverage", importlib.import_module("coverage").Coverage())
    measurement.start()
    try:
        _reload_package_modules()
        result = _pytest_main(targets)
    finally:
        measurement.stop()
        measurement.save()
    if result:
        return result
    threshold = cast(float, measurement.get_option("report:fail_under"))
    return 0 if measurement.report() >= threshold else 1


def main() -> int:
    return run(sys.argv[1:])


if __name__ == "__main__":
    sys.exit(main())
