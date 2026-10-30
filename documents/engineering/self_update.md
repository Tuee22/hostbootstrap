# Bootstrapper Self-Update

**Status**: Authoritative source
**Supersedes**: prior bootstrapper install/update guidance
**Referenced by**: [../README.md](../README.md), [../architecture/python_haskell_boundary.md](../architecture/python_haskell_boundary.md), [prerequisites.md](prerequisites.md), [../languages/python.md](../languages/python.md), [Python pre-binary floor phase](../../DEVELOPMENT_PLAN/phase-1-python-pre-binary-floor.md)

> **Purpose**: Define the self-update doctrine for the pipx-installed Python bootstrapper while
> preserving the thin-bootstrapper boundary and the no-hidden-network-gate rule.

## TL;DR

- The Python bootstrapper owns its own explicit self-update command because it updates the
  pipx-installed wrapper before or outside any project binary.
- `hostbootstrap` ships from a single canonical install/update source: the repository's default branch
  through a direct VCS requirement.
- The supported update primitive is a forced pipx reinstall from the canonical VCS spec.
- Self-update is never automatic. `doctor`, `build`, `run`, and `base` never check the wrapper's own
  freshness against GitHub, never mutate the pipx environment, and never fail merely because the wrapper
  is not at the latest commit. The rule is about the wrapper's freshness, not about network use: `base`
  queries GitHub release metadata to choose upstream tool versions for the image it builds (see
  [no hidden freshness gate](#no-hidden-freshness-gate)).

## Current Status

`hostbootstrap update` updates the pipx app explicitly. It is specified in the
[Python pre-binary floor phase](../../DEVELOPMENT_PLAN/phase-1-python-pre-binary-floor.md):

```bash
hostbootstrap update
```

Local checkout installs are development-only and use:

```bash
pipx install --force /path/to/hostbootstrap
```

`hostbootstrap update --check` compares the installed commit against the commit pip would install for
the selected ref. An explicit `--ref` selects that ref; otherwise the installed VCS metadata's
`requested_revision` selects it, falling back to `main` when no requested revision is recorded. The
result prints the compared ref alongside the installed and remote commits, or the matching installed
commit when up to date.

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

The README, downstream install guidance, and the `cli.py` module docstring all use pipx for the initial
install. A plain `pip install` is not a supported bootstrap path and must not be described as one;
`hostbootstrap update` operates on the pipx-managed application.

The command exposes these options:

| Option | Contract |
|---|---|
| `--ref REF` | Reinstall from the canonical repository at `REF`; defaults to `main`. With `--check`, an explicit value overrides the installed requested revision. |
| `--spec SPEC` | Reinstall from an explicit pip requirement spec, for development or recovery. Refused together with an explicit `--ref`. |
| `--check` | Compare the installed VCS commit to the explicit ref, installed requested revision, or `main`, in that order, and print the selected ref. Refused together with `--spec`. |

`--check` is an explicit network operation. It reports that freshness is unknown, rather than pretending
the install is comparable to the canonical repository, when the installed package has no direct git VCS
metadata (a local or wheel install) and when its recorded source URL is not the canonical repository.

The remote query asks `git ls-remote` for `refs/heads/<ref>`, `refs/tags/<ref>`, and
`refs/tags/<ref>^{}`. Resolution selects exact ref names in pip's order: the branch head first, then
the peeled annotated-tag commit, then the unpeeled tag. A similarly named branch such as
`refs/heads/backup/main` cannot satisfy a check of `main`. Conflicting commits for the selected exact
name, or output with no exact match, produce `SelfUpdateError`.

Malformed `direct_url.json` input also produces `SelfUpdateError`: invalid JSON or a non-object
document is malformed, a non-object `vcs_info` has malformed VCS metadata, a git source without a
string `url` and `commit_id` is missing git source metadata, and a non-string `requested_revision`
is a malformed requested revision. A subprocess timeout is reported as a timeout, with its deadline
and command, rather than as a missing executable.

Exit status:

| Outcome | Exit |
|---|---|
| update installed, or `--check` finds the installed commit equal to the remote one | 0 |
| `--check` finds an update available | 1 |
| freshness unknown, a refused option combination, missing `pipx` or `git`, or a failed subprocess | 1 |

An update being available and the check failing share exit status 1; the printed message tells them
apart (`hostbootstrap update available: ...` against an error).

## No Hidden Freshness Gate

Being behind the default branch is not a host minimum. Normal commands do not perform a hidden
**freshness** check or turn GitHub reachability into a version gate:

- `hostbootstrap doctor` checks local host minimums only.
- `hostbootstrap build` and `hostbootstrap run` build and invoke the project binary without a latest-version
  check. Online mode may refresh a stale index or download missing toolchain/dependency inputs;
  `--offline` requires those inputs locally and forbids that work.
- `hostbootstrap base build` and `hostbootstrap base build-and-push` are maintainer commands exposed only
  after validating the canonical checkout's in-project Poetry interpreter, project/lock metadata, and
  development toolchain. Importable development modules alone do not expose them. The commands perform
  their source gates and Docker operations, and resolve current upstream tool versions (several through
  GitHub's release API) as image build inputs, but do not check or self-update the wrapper.

## Validation

The test suite covers the implementation:

- unit tests cover the generated pipx argv without mutating the user's pipx environment;
- failure tests cover missing `pipx`, non-pipx/local installs, and failed subprocesses;
- freshness-check tests cover malformed direct URL metadata, exact branch and tag selection,
  ambiguous and unmatched output, and explicit, installed, and fallback ref selection;
- subprocess tests distinguish missing executables, nonzero exits, and timeouts;
- CLI tests assert the compared ref appears for both current and outdated installations;
- CLI smoke tests prove `hostbootstrap --help` lists `update`;
- the Python code-check and supported test runner execute these checks.
