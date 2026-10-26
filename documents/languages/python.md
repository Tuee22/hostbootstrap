# Python

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md)

> **Purpose**: Document the Python toolchain the base image ships and how the thin Python
> bootstrapper stays isolated from project runtimes.

This page documents what the base image ships for Python.

The base image carries the Ubuntu 24.04 default Python 3. The only Python tooling it installs globally is
Poetry, together with Poetry's own dependencies and pip, setuptools, and wheel, which the same
`pip install --ignore-installed --upgrade` step upgrades to their latest releases. Everything else lives
inside the project's own dependencies.

## Caches

The image sets these cache directories under `/opt/cache`:

* `PIP_CACHE_DIR=/opt/cache/python/pip`
* `POETRY_CACHE_DIR=/opt/cache/python/pypoetry`

Bytecode is a build output, so it goes under `/opt/build` rather than `/opt/cache`:

* `PYTHONPYCACHEPREFIX=/opt/build/python/pycache`

Two Poetry behaviour flags complete the set:

* `POETRY_VIRTUALENVS_CREATE=false`
* `POETRY_VIRTUALENVS_IN_PROJECT=false`

Container-installed Poetry must not create per-project venvs inside the
container: that is the host-side concern.

## Host isolation

Downstream projects that maintain their own host-level `.venv` (e.g. ML
inference Python adapters) must **never** add the Python bootstrapper to that
venv. Install it with `pipx` so it lives in its own host-side app environment and
exposes only the `hostbootstrap` command on `PATH`. Once the project binary is
built and handed off, the bootstrapper's job is done; it has no place inside a
project's runtime environment.

An online bootstrap build refreshes the Cabal index only when it is missing or stale, and installs a
missing toolchain. On Linux and on Windows `amd64` it downloads a pinned GHCup binary (with `curl` or
PowerShell `Invoke-WebRequest`) and verifies its SHA-256 before installing it; Apple Silicon installs
GHCup through Homebrew, whose formula is not pinned here. `--offline` is explicit and fail-closed: it needs
a cached Cabal index and an already-installed toolchain, and refuses rather than downloading. See
[Python/Haskell boundary](../architecture/python_haskell_boundary.md#network-and-offline-behavior) for the
full behavior.

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
`hostbootstrap/` package, and `tests/` all live there alongside
`core/`). Run all Python commands from the repo root:

- Code checks: `poetry run python -m hostbootstrap.check_code`
  (runs `ruff check hostbootstrap`, `black --check hostbootstrap`, then `mypy hostbootstrap`).
- Tests: `poetry run python -m hostbootstrap.test_all`.
- Coverage: `poetry run python -m coverage run -m hostbootstrap.test_all && poetry run python -m coverage report -m`
  (configured with `fail_under = 100`).

### Maintainer command capability gate

`base`, `check-code`, and `test-all` are **maintainer** commands: the CLI registers them only when the
running interpreter is this repository checkout's in-project Poetry environment. The gate is
`cli._maintainer_cli_enabled()`, which holds only when `_maintainer_command_authority` finds all of:

- the `pyproject.toml` next to the package names the Poetry project `hostbootstrap`;
- the checkout root carries `.git` and a `poetry.lock` file;
- `sys.prefix` is that checkout's `.venv`, it is a virtual environment, and the running executable lies
  inside it;
- the dev toolchain modules (ruff, black, mypy, pytest) are importable.

A pipx install fails the checkout and prefix conditions even with those four modules injected, so the
names are absent from `--help` and resolve to `No such command`. The Poetry environment exposes
two convenience subcommands that wrap the module runners:

- `poetry run hostbootstrap check-code` — same gate as `python -m hostbootstrap.check_code`.
- `poetry run hostbootstrap test-all [pytest args...]` — same runner as `python -m hostbootstrap.test_all`
  (forwards args to pytest; still goes through the `HOSTBOOTSTRAP_TEST_ALL` sentinel).

Before any Docker build, `base build` and `base build-and-push` run the repository source gate on the
maintainer's host, in order: `check_code` and `test_all` in the current interpreter
(`sys.executable -m hostbootstrap.check_code`, then `-m hostbootstrap.test_all`, rather than shelling out
to `poetry run`); `fourmolu --mode check` and `hlint` over the Haskell roots; then
`cabal build all --ghc-options=-Werror` and `cabal test all --ghc-options=-Werror` in `core/` and then in
`demo/`. A maintainer therefore needs `fourmolu`, `hlint`, and a working Cabal with the pinned GHC on
`PATH`, and the command runs both Haskell suites before it builds an image. The first failing step stops
it with no image built or pushed.
[Where the style tools run](../engineering/code_check_doctrine.md#where-the-style-tools-run) is the
canonical home for the style legs.

Do not invoke `pytest` directly; `tests/conftest.py` requires the
`hostbootstrap.test_all` runner. See
[../architecture/python_haskell_boundary.md](../architecture/python_haskell_boundary.md)
for the ownership boundary between this bootstrapper and `hostbootstrap-core`.
