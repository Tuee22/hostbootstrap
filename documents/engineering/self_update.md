# Bootstrapper Self-Update

**Status**: Authoritative source
**Supersedes**: legacy pipx `#egg=hostbootstrap` install/update guidance and automatic latest-version gating proposals
**Referenced by**: [../README.md](../README.md), [../architecture/python_haskell_boundary.md](../architecture/python_haskell_boundary.md), [../../DEVELOPMENT_PLAN/phase-6-base-image-and-thin-python-bootstrapper.md](../../DEVELOPMENT_PLAN/phase-6-base-image-and-thin-python-bootstrapper.md)

> **Purpose**: Define the self-update doctrine for the pipx-installed Python bootstrapper while
> preserving the thin-bootstrapper boundary and the no-hidden-network-gate rule.

## TL;DR

- The Python bootstrapper owns its own explicit self-update command because it updates the
  pipx-installed wrapper before or outside any project binary.
- `hostbootstrap` has no versioned Python release channel today. The canonical install/update source is
  the repository's default branch through a direct VCS requirement.
- A fixed package version means normal version-based upgrade semantics are not the supported update
  primitive. The supported primitive is a forced pipx reinstall from the canonical VCS spec.
- Self-update is never automatic. `doctor`, `build`, `run`, and `base` must not contact GitHub to check
  freshness, must not mutate the pipx environment, and must not fail merely because the wrapper is not
  at the latest commit.

## Current Status

`hostbootstrap update` is implemented in
[Phase 6, Sprint 6.5](../../DEVELOPMENT_PLAN/phase-6-base-image-and-thin-python-bootstrapper.md). It
updates the pipx app explicitly:

```bash
hostbootstrap update
```

Local checkout installs remain development-only and use:

```bash
pipx install --force /path/to/hostbootstrap
```

## Ownership

Self-update is Python-owned because it manages the Python wrapper's distribution lifecycle. It is not a
host-management reconciler, not a project-binary command, and not part of the Haskell `ensure` suite.
The command may call `pipx`, but it must not add Docker, VM, cluster, resource, or Dhall logic to
Python. See [python_haskell_boundary](../architecture/python_haskell_boundary.md).

## Command Contract

`hostbootstrap update` installs the canonical VCS source into pipx:

```bash
pipx install --force \
  --pip-args=--force-reinstall \
  "hostbootstrap @ git+https://github.com/Tuee22/hostbootstrap.git@main"
```

The `--pip-args` value is glued onto the flag with `=`. pipx parses its CLI with `argparse`, which
refuses to consume a following token that looks like an option (a leading `-`) as that flag's value, so
the split `--pip-args --force-reinstall` form fails with "expected one argument".

The command may expose explicit operator options:

| Option | Contract |
|---|---|
| `--ref REF` | Reinstall from the canonical repository at `REF`; defaults to `main`. |
| `--spec SPEC` | Reinstall from an explicit pip requirement spec, for development or recovery. |
| `--check` | Explicitly compare the installed VCS commit to the remote ref without mutating the pipx environment. |

`--check` is an explicit network operation. If the installed package has no direct VCS metadata, the
command reports that freshness is unknown rather than pretending a local or wheel install is comparable
to the default branch.

## No Hidden Freshness Gate

Being behind the default branch is not a host minimum. The only hard fail-fast Python surface remains
the irreducible pre-binary host floor documented in [prerequisites](prerequisites.md). Normal commands
must remain usable offline after installation and must not turn GitHub reachability into a prerequisite:

- `hostbootstrap doctor` checks local host minimums only.
- `hostbootstrap build` and `hostbootstrap run` build/exec the project binary without a latest-version
  check.
- `hostbootstrap base build` and `hostbootstrap base build-and-push` perform their existing local
  self-check and Docker operations, but do not self-update the wrapper.

## Validation

Phase 6.5 validates the implementation:

- unit tests cover the generated pipx argv without mutating the user's pipx environment;
- failure tests cover missing `pipx`, non-pipx/local installs, and failed subprocesses;
- freshness-check tests cover direct URL metadata with and without a VCS `commit_id`;
- CLI smoke tests prove `hostbootstrap --help` lists `update`;
- the Python code-check and test runner pass.
