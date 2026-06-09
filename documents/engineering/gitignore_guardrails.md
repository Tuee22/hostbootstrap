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
  the 100% gate belongs in `python/pyproject.toml`, not in checked-in report output.
* `dist-newstyle/`, `.cabal-sandbox/`, `cabal.project.freeze` — Haskell build
  state. (`cabal.project.freeze` is intentionally excluded; the warm store
  pins compatible versions.)
* `node_modules/`, `dist/`, `output/`, `.spago/`, `playwright-report/`,
  `test-results/`, `*.tsbuildinfo` — JS / TS / PureScript / Playwright.
* `target/`, `Cargo.lock` (libraries only) — Rust.
* `*.lock`, `poetry.lock`, `package-lock.json`, `yarn.lock`,
  `pnpm-lock.yaml`, `spago.lock`, `npm-shrinkwrap.json` — package manager
  lockfiles.
* `.build/` — the host binary built host-native for every
  project; always present after a successful bootstrap. It must never be
  bind-mounted into an outer container.
* `.data/` — host persistent state. It is bind-mounted while a cluster is
  running and must **never** be deleted by cluster teardown; the
  never-delete-`.data` invariant is owned by `hostbootstrap-core`'s
  cluster-lifecycle semantics (see [cluster_lifecycle.md](cluster_lifecycle.md)).

The repo's [`.gitignore`](../../.gitignore) covers all of the above for
hostbootstrap itself; downstream projects mirror the same pattern.
