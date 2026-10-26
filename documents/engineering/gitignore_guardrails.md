# .gitignore guardrails

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [durable_state.md](../architecture/durable_state.md), [prerequisites.md](prerequisites.md), [secrets.md](secrets.md)

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
* `target/` — Rust build output.
* `*.lock`, `package-lock.json`, `pnpm-lock.yaml`, `npm-shrinkwrap.json` —
  package manager lockfiles. Every lockfile is ignored, for binary and library
  crates alike: the `*.lock` glob already matches `Cargo.lock`, `poetry.lock`,
  `yarn.lock`, and `spago.lock`, and the repository's `.gitignore` also names
  them individually; the other three names need their own entries because they
  do not end in `.lock`.
* `.build/` — the host binary built host-native for every
  project; always present after a successful bootstrap. It must never be
  bind-mounted into an outer container. It also holds the host-native cabal
  package store at `.build/cabal-store/` (kept repo-local so `git clean -fxd`
  resets the full build state, deps included — see
  [build_and_run_model.md](../architecture/build_and_run_model.md)), so the
  existing `.build/` ignore already covers the store; no separate entry is needed.
  **On Windows that reset requires long-path support.** Cabal stages every install
  under `<store>/ghc-*/incoming/new-<pid>/` and replicates the absolute destination
  path beneath it, so for a project checked out under the user profile
  (`C:\Users\<name>\...`) the repo-local store path doubles to roughly 285
  characters — past the 260-char `MAX_PATH`. GHC creates those paths without complaint (its `base`
  prefixes `\\?\`), and Cabal removes its own staging on a successful build, so the
  leftovers only survive an **interrupted** build — exactly what the long demo gate
  invites (see [durable_windows_runs.md](durable_windows_runs.md)). Without
  `git config --global core.longpaths true`, `git clean -fxd` then fails with
  `Filename too long` and silently leaves the tree behind. `hostbootstrap doctor`
  reports this on Windows; see [prerequisites.md](prerequisites.md). Shortening the
  store path is not a reliable alternative: the doubling applies to the whole absolute
  path, so for a project under the user profile that prefix alone consumes the
  headroom. Only a project rooted at a very short path (such as `C:\w`) stays under
  `MAX_PATH`, and hostbootstrap does not choose where a project is checked out, so
  long-path support is the requirement.
* `.data/` — the production profile's durable host directory. The demo creates
  `<project-root>/.data`, carries it through provider shares and
  `/var/tmp/hostbootstrap-demo-data`, and mounts it through kind/nvkind into the
  pod. It is not workload-only: the provider, guest-alias, and cluster backends
  keep their ownership records beneath it (see
  [what lives under `.data`](../architecture/durable_state.md#what-lives-under-data)),
  so a backup, restore, or prune of the directory moves those records too. Cluster
  teardown never removes the data path itself or a workload subtree, but a
  plan-owned cluster's delete removes its cluster state leaf beneath it; full
  destroy/up/readback evidence belongs in the worked-demo and substrate acceptance phases (see
  [../architecture/durable_state.md](../architecture/durable_state.md#teardown-guarantee)).
* `.hostbootstrap/` — the protected per-project lifecycle authority store the
  binary creates at `<project-root>/.hostbootstrap/authority/<project>`, beside
  other control state such as the direct-Colima adapter's `.hostbootstrap/colima`
  leaf and its isolated `DOCKER_CONFIG`. It is durable by design and never
  committed (see
  [../architecture/durable_state.md](../architecture/durable_state.md)).
* `.test_data/` — the Harness run's owned durable-root parent. Each run uses
  `.test_data/<runId>`; the ignore entry is only a source-control guardrail and
  does not itself prove exact plan-owned profile/root projection (see
  [testing.md](testing.md)).

The repo's [`.gitignore`](../../.gitignore) covers all of the above for
hostbootstrap itself; downstream projects mirror the same pattern.
