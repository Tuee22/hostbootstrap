---
name: testing
description: How hostbootstrap is tested — the layered suite, the development test runner, and how to run it.
type: guide
---

# Testing

hostbootstrap orchestrates external tools by shelling out, so the suite is built
around pure command builders plus thin recorded runners. The default run touches
no network, no Docker daemon, no `sudo`, and no host service manager.

## Running The Suite

There is exactly one supported runner module,
[`hostbootstrap.test_all`](../../hostbootstrap/test_all.py):

> **WRONG**
>
> ```sh
> poetry run pytest
> ```
>
> `tests/conftest.py` refuses direct pytest because it requires the
> `HOSTBOOTSTRAP_TEST_ALL` sentinel.
>
> **RIGHT**
>
> ```sh
> poetry run python -m hostbootstrap.test_all
> poetry run python -m hostbootstrap.test_all -k spec
> ```

[`hostbootstrap.check_code`](../../hostbootstrap/check_code.py) is separate and
runs ruff, black, and mypy:

```sh
poetry run python -m hostbootstrap.check_code
```

Run both before publishing a hostbootstrap change.

## Layers

**Pure unit tests** cover value resolvers and command builders:

- [`docker_ops`](../../hostbootstrap/docker_ops.py) build/run command tuples
- [`base_image`](../../hostbootstrap/base_image.py) tag and URL builders
- [`substrate`](../../hostbootstrap/substrate.py) host detection
- [`spec`](../../hostbootstrap/spec.py) substrate/lifecycle/model parsing
- [`models`](../../hostbootstrap/models) path, mount, entrypoint, Cabal, and
  foreground daemon command helpers

**Spec parser tests** use crafted JSON to cover residual checks Dhall cannot
express: duplicate substrates, missing selected targets, unknown lifecycle/model
tags, and `--force-target` selection.

**Dhall contract tests** (`tests/test_spec_dhall.py`) run the real
`dhall-to-json` against fixtures in `tests/fixtures/dhall/`. Valid fixtures cover
`Container`, `HostBinary`, `HostDaemon`, mixed substrate matrices, explicit
`env:HOSTBOOTSTRAP_PACKAGE`, and `NoCluster`. Invalid fixtures prove structural
type errors: daemon on container, flavor on container, missing HostDaemon
daemon, mounts on HostBinary, and unknown substrate.

**CLI smoke tests** use Click's `CliRunner` and monkeypatching to assert command
dispatch, `--force-target` propagation, clean errors, base build/push behavior,
cluster forwarding, and `daemon run` applicability.

**Recorded runner tests** replace `process.run` / `run_checked` with an argv
recorder. They assert the exact `docker` and `cabal` commands without touching
Docker or Cabal.

## Markers And Skipping

Configured in `pyproject.toml`:

- `dhall` needs a provisioned `dhall-to-json`; the `require_dhall` fixture skips
  when it cannot be obtained.
- `docker` needs a running Docker daemon and skips when absent.
- `slow` marks long-running checks.

The default suite remains hermetic and fast.

## Out Of Scope

hostbootstrap no longer writes launchd/systemd unit files and no longer configures
restart-after-reboot behavior. There are therefore no unit-file rendering tests or
real service-manager integration tests. Operators who want automatic restart run
`hostbootstrap daemon run` from their own launchd/systemd wrapper outside
hostbootstrap.
