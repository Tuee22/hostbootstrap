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
development only*. Downstream installs use `pipx install
"git+https://github.com/tuee22/hostbootstrap.git#egg=hostbootstrap"`, or
`pipx install --force /path/to/hostbootstrap` for a local checkout.
