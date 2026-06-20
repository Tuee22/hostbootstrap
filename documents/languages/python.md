# Python

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/base_image.md](../engineering/base_image.md)

> **Purpose**: Document the Python toolchain the base image ships and how the thin Python
> bootstrapper stays isolated from project runtimes.

This page documents what the base image ships for Python.

The base image carries the Ubuntu 24.04 default Python 3 with Poetry as the
**only** global Python package. Everything else lives inside the project's
own dependencies.

## Caches

The image sets the standard cache directories under `/opt/cache`:

* `PIP_CACHE_DIR=/opt/cache/python/pip`
* `POETRY_CACHE_DIR=/opt/cache/python/pypoetry`
* `PYTHONPYCACHEPREFIX=/opt/build/python/pycache`
* `POETRY_VIRTUALENVS_CREATE=false`
* `POETRY_VIRTUALENVS_IN_PROJECT=false`

Container-installed Poetry must not create per-project venvs inside the
container: that is the host-side concern.

## Host isolation

Downstream projects that maintain their own host-level `.venv` (e.g. ML
inference Python adapters) must **never** add the Python bootstrapper to that
venv. Install it with `pipx` so it lives in its own host-side app environment and
exposes only the `hostbootstrap` command on `PATH`. Once the project binary is
built and exec'd, the bootstrapper's job is done; it has no place inside a
project's runtime environment.

## hostbootstrap itself

The hostbootstrap repo uses Poetry with an **in-project** `.venv`
(`poetry.toml` sets `virtualenvs.in-project = true`) — *for repo
development only*. Downstream installs use
`pipx install "hostbootstrap @ git+https://github.com/Tuee22/hostbootstrap.git@main"`, or
`pipx install --force /path/to/hostbootstrap` for a local checkout. Update the pipx app with:

```bash
hostbootstrap update
```

The update path is explicit. Normal `doctor`, `build`, `run`, and `base` invocations do not check or
mutate the pipx install; see [../engineering/self_update.md](../engineering/self_update.md).

The Poetry project is rooted at the **repository root** (`pyproject.toml`, the
`hostbootstrap/` package, `stubs/`, and `tests/` all live there alongside
`core/`). Run all Python commands from the repo root:

- Code checks: `poetry run python -m hostbootstrap.check_code`
  (runs `ruff check hostbootstrap stubs`, `black --check hostbootstrap stubs`, then `mypy hostbootstrap`).
- Tests: `poetry run python -m hostbootstrap.test_all`.
- Coverage: `poetry run python -m coverage run -m hostbootstrap.test_all && poetry run python -m coverage report -m`
  (configured with `fail_under = 100`).

### Maintainer commands are dev-only

`base`, `check-code`, and `test-all` are **maintainer** commands: the CLI registers them only when the
dev toolchain (ruff/black/mypy/pytest) is importable — i.e. in this repo's Poetry `.venv`, never in the
pipx-installed consumer CLI. The gate is `cli._maintainer_cli_enabled()`; in the global CLI these names
resolve to a plain `No such command` and are absent from `--help`. The Poetry venv additionally exposes
two convenience subcommands that wrap the module runners:

- `poetry run hostbootstrap check-code` — same gate as `python -m hostbootstrap.check_code`.
- `poetry run hostbootstrap test-all [pytest args...]` — same runner as `python -m hostbootstrap.test_all`
  (forwards args to pytest; still goes through the `HOSTBOOTSTRAP_TEST_ALL` sentinel).

Because `base` only runs inside the dev venv, its pre-build self-check runs `check_code` directly in the
current interpreter (`sys.executable -m hostbootstrap.check_code`) rather than shelling out to
`poetry run` — see [../engineering/code_check_doctrine.md](../engineering/code_check_doctrine.md).

Do not invoke `pytest` directly; `tests/conftest.py` requires the
`hostbootstrap.test_all` runner. See
[../architecture/python_haskell_boundary.md](../architecture/python_haskell_boundary.md)
for the ownership boundary between this bootstrapper and `hostbootstrap-core`.
