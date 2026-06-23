# .gitignore guardrails

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [derived_project_standards.md](derived_project_standards.md), [warm_store.md](warm_store.md)

> **Purpose**: List what every project that adopts hostbootstrap must keep out of version control,
> including the always-present `./.build/` host binary and the never-deleted `.data/` state.

Every project that adopts hostbootstrap must keep these out of git:

* `.venv/`, `__pycache__/`, `*.pyc` — Python build state.
* `.mypy_cache/`, `.ruff_cache/`, `.pytest_cache/` — Python tool caches.
* `.coverage`, `htmlcov/`, `coverage/` — generated coverage data and reports;
  the 100% gate belongs in `pyproject.toml`, not in checked-in report output.
* `dist-newstyle/`, `.cabal-sandbox/`, `cabal.project.freeze`, `core.freeze`,
  `daemon.freeze` — Haskell build state and the layered warm-store freezes. The
  warm-store freezes (`cabal.project.freeze`, `core.freeze`, `daemon.freeze`)
  are gitignored **and** dockerignored **by design**: they are generated
  in-image by `cabal freeze` during the base build and are never committed or
  sent in build context. The base image is the **single source of truth** for
  the transitive dependency versions, and a derived project imports the
  fragment(s) for its layer (`core.freeze` for every layer; `daemon.freeze`
  additionally for a daemon app) rather than committing a freeze of its own
  (see [warm_store.md](warm_store.md)).
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
* `.data/` — host persistent state. It is bind-mounted while a cluster is
  running and must **never** be deleted by cluster teardown; the
  never-delete-`.data` invariant is owned by `hostbootstrap-core`'s
  cluster-lifecycle semantics (see [cluster_lifecycle.md](cluster_lifecycle.md)).
* `.test_data/` — the test harness's durable test root, written by `test run`
  in place of `.data/` so the suite never touches production state. The harness
  creates it per run and deletes only the `.test_data` it created (see
  [cluster_lifecycle.md](cluster_lifecycle.md) and [testing.md](testing.md)).

The repo's [`.gitignore`](../../.gitignore) covers all of the above for
hostbootstrap itself; downstream projects mirror the same pattern.
