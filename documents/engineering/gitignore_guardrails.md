# .gitignore guardrails

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [derived_project_standards.md](derived_project_standards.md), [warm_store.md](warm_store.md)

> **Purpose**: List what every project that adopts hostbootstrap must keep out of version control,
> including generated `./.build/` host artifacts and intended durable `.data/` state.

Every project that adopts hostbootstrap must keep these out of git:

* `.venv/`, `__pycache__/`, `*.pyc` — Python build state.
* `.mypy_cache/`, `.ruff_cache/`, `.pytest_cache/` — Python tool caches.
* `.coverage`, `htmlcov/`, `coverage/` — generated coverage data and reports;
  the 100% gate belongs in `pyproject.toml`, not in checked-in report output.
* `dist-newstyle/`, `.cabal-sandbox/`, `cabal.project.freeze` — local Haskell build state and an
  accidentally generated solver freeze. The rolling base's warm store is not a version contract, and
  consumers neither import nor commit base-owned freeze fragments (see [warm_store.md](warm_store.md)).
* `node_modules/`, `dist/`, `output/`, `.spago/`, `playwright-report/`,
  `test-results/`, `*.tsbuildinfo` — JS / TS / PureScript / Playwright.
* `target/`, `Cargo.lock` (libraries only) — Rust.
* `*.lock`, `poetry.lock`, `package-lock.json`, `yarn.lock`,
  `pnpm-lock.yaml`, `spago.lock`, `npm-shrinkwrap.json` — package manager
  lockfiles.
* `.build/` — the host binary built host-native for every
  project; always present after a successful bootstrap. It must never be
  bind-mounted into an outer container. It also holds the host-native cabal
  package store at `.build/cabal-store/` (kept repo-local so `git clean -fxd`
  resets the full build state, deps included — see
  [build_and_run_model.md](../architecture/build_and_run_model.md)), so the
  existing `.build/` ignore already covers the store; no separate entry is needed.
  **On Windows that reset requires long-path support.** Cabal stages every install
  under `<store>/ghc-*/incoming/new-<pid>/` and replicates the absolute destination
  path beneath it, so the repo-local store doubles to roughly 285 characters — past
  the 260-char `MAX_PATH`. GHC creates those paths without complaint (its `base`
  prefixes `\\?\`), and Cabal removes its own staging on a successful build, so the
  leftovers only survive an **interrupted** build — exactly what the long demo gate
  invites (see [durable_windows_runs.md](durable_windows_runs.md)). Without
  `git config --global core.longpaths true`, `git clean -fxd` then fails with
  `Filename too long` and silently leaves the tree behind. `hostbootstrap doctor`
  reports this on Windows; see [prerequisites.md](prerequisites.md). Shortening the
  store path is not an alternative — the doubling applies to the whole absolute path,
  so the user-profile prefix alone consumes the headroom.
* `.data/` — the production profile's durable host directory. The demo creates
  `<project-root>/.data`, carries it through provider shares and
  `/var/tmp/hostbootstrap-demo-data`, and mounts it through kind/nvkind into the
  pod. Cluster teardown omits it from its removal set, although full
  destroy/up/readback is not yet validated (see
  [../architecture/durable_state.md](../architecture/durable_state.md)).
* `.test_data/` — the Harness run's owned durable-root parent. Each run uses
  `.test_data/<runId>`; the ignore entry is only a source-control guardrail and
  does not itself prove exact plan-owned profile/root projection (see
  [testing.md](testing.md)).

The repo's [`.gitignore`](../../.gitignore) covers all of the above for
hostbootstrap itself; downstream projects mirror the same pattern.
