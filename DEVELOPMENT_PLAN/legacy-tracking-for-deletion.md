# Legacy Tracking for Deletion

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Authoritative cleanup ledger for obsolete compatibility surfaces — pure-Python
> host-management code, the shelled `dhall-to-json` path, legacy Dhall schema files, old context
> artifact names, and stale command shortcuts.

## Pending

These surfaces are still present. Each entry names its location, its disposition, and the owning phase.
`prereqs.py` remains retained for the residual fail-fast host minimums. The old Python Dhall reader and
static-base schema are no longer retained by design: the target Python bootstrapper derives the project
name from the Cabal file and does not read or write Dhall. When a surface is removed or superseded, its
entry moves to **Completed** in the same change. Per
[development_plan_standards.md § I](development_plan_standards.md).

- **`hostbootstrap/prereqs.py`** — the Python host-prerequisite checks. The fail-fast host
  minimums have been trimmed to the pre-binary subset (Linux: Ubuntu 24.04 + passwordless sudo,
  `linux-gpu` additionally the NVIDIA container runtime; Apple: passwordless sudo + Xcode CLT +
  Homebrew), dispatched by substrate alone (no `ProjectSpec`/`ResolvedTarget`). All richer host logic
  lives in Haskell `HostBootstrap.HostPrereqs` plus the `ensure` reconcilers. `prereqs.py` is
  **retained as the trimmed thin-bootstrapper minimums**, not removed; this entry stays Pending
  tracking the eventual lift of the residual checks into `hostbootstrap-core`. Owning phase: phase-2
  (host trio lift) and phase-3 (reconcilers).
## Completed

These three-execution-model surfaces were removed when the Python CLI was reduced to the `doctor` /
`build` / `run` / `base` surface in phase-6 (Sprint 6.2), and the pre-binary-boundary overreach was removed when
`bootstrap.py` converged on the thin § M / § N boundary (phase-6, Sprint 6.3). The Python suite passes
at 100% coverage after their removal.

- **The redundant demo deploy-chain representation** (the explicit `cluster up` / `harbor install` /
  `web serve` / `e2e` ops in `demo/src/HostBootstrapDemo/Chain.hs`, plus running the harness standalone on
  metal as a separate path) — a **second representation** of the cluster deploy alongside the standardized
  harness (`HostBootstrap.Harness`), violating the single-representation doctrine
  ([development_plan_standards.md § W](development_plan_standards.md)). **Removed.** `Chain.hs` now folds to
  the single canonical deploy lift sequence whose only lifted compute step is `test all` lifted into the
  project container in the VM (`incus exec <vm> -- docker run --rm <image> test all`); the harness (the one
  representation, the context-agnostic lift target) runs `clusterUp` "locally" on the VM's Docker and the
  kind cluster lives in the VM. **Live-validated** — the literal `demo deploy` apply runs `3/3` with kind on
  the VM's Docker and **none** on metal, guarded teardown, no leftovers. Owning phase: phase-13 (Sprint
  13.12). Replacement: the single canonical deploy lift sequence in `Chain.hs` (see
  [composition_methodology](../documents/architecture/composition_methodology.md)).

- **`core/hostbootstrap-core/dhall/Type.dhall` and `core/hostbootstrap-core/dhall/example.dhall`
  static-base fixtures** — the old `hostbootstrap.dhall` type and example. **Replaced** with
  project-local `<project>.dhall` schema and example fixtures in phase-4 Sprint 4.4. Validation:
  `cabal test all` from `core/` decodes the canonical `example.dhall` fixture through `ProjectConfig`.

- **`hostbootstrap/dhall_tool.py`**, **`hostbootstrap/spec.py`**, and
  **`hostbootstrap/dhall/package.dhall`** — the Python-side `dhall-to-json` provisioning path,
  `StaticBaseSpec` reader, and static-base schema package. **Removed** in phase-6 Sprint 6.4. Replacement:
  `hostbootstrap/bootstrap.py` derives the project name from the single Cabal file and the built project
  binary owns `<project>.dhall` initialization/schema/default generation. Validation:
  `poetry run python -m hostbootstrap.check_code` passes; `poetry run python -m hostbootstrap.test_all -q`
  passes with 113 tests.

- **Python host-context writer in `hostbootstrap/bootstrap.py`** — the code that idempotently wrote
  `./.build/project-binary-context-config.dhall` after the host-native build. **Removed** in phase-6
  Sprint 6.4. Replacement: the Python bootstrapper writes no Dhall; the built binary owns sibling
  `<project>.dhall` initialization and child projection. Validation: Python tests assert no `.dhall` file is written under
  `./.build/`.

- **`StaticBase` compatibility API in `HostBootstrap.Config.Schema`** (`StaticBase`,
  `decodeStaticBaseText`, `decodeStaticBaseFile`, `renderStaticBase`) — Haskell compatibility surface for
  the old static-base config. **Removed** in phase-15 Sprint 15.5. Replacement:
  `ProjectConfig` plus `decodeProjectConfigText`/`File`, `renderProjectConfig`, `config init`, and the
  sibling `<project>.dhall` command gate. Validation: `cabal test all` from `core/` passes (159 tests), and
  `rg StaticBase core/hostbootstrap-core/src core/hostbootstrap-core/test demo/src demo/app` finds no
  code references.

- **`project-binary-context-config.dhall` artifact name and sibling discovery rule** — the separate
  context file beside host, VM, container, and service binaries. **Removed/replaced** in phase-15 Sprint
  15.5 by the sibling `<project>.dhall` rule with role/capability context inside the file content.
  Validation: `cabal test all` covers sibling `<project>.dhall` discovery, missing-config fail-fast,
  malformed config failures, wrong-project failures, role/capability mismatches, and no-side-effect
  command gating.

- **`--create-container-config` Dockerfile shortcut** — the old shortcut created
  `/usr/local/bin/project-binary-context-config.dhall` without requiring a parent config. **Removed** in
  phase-15 Sprint 15.5. Replacement: `<project> config init --role vm-project-container --output
  /usr/local/bin/<project>.dhall`. Validation: the demo Dockerfile uses the replacement command, and a
  direct `hostbootstrap-demo config init --role vm-project-container --output <tmp>/hostbootstrap-demo.dhall`
  smoke writes a non-empty config with `VMProjectContainer` and `roleName = "vm-project-container"`.

- **`demo/hostbootstrap.dhall`** — the demo static-base config. **Removed** in phase-13 Sprint 13.13.
  Replacement: `hostbootstrap-demo config init` generates the host default
  `demo/.build/hostbootstrap-demo.dhall`; the Dockerfile bakes `/usr/local/bin/hostbootstrap-demo.dhall`;
  the chart mounts a service-role `hostbootstrap-demo.dhall`. Validation: `cabal build all` from `demo/`
  passes, and `helm template hostbootstrap-demo demo/chart` renders the config mounts.

- **`core/hostbootstrap-core/example/Main.hs`** (and the `hostbootstrap-example` executable stanza in
  `core/hostbootstrap-core/hostbootstrap-core.cabal`) — the thin one-verb (`greet`) worked example.
  **Removed**, superseded by the full worked consumer under `demo/` (`hostbootstrap-demo`), which extends
  the core tree (`runHostBootstrapCLI`), the schema-gen registry (`coreArtifacts ++ demoArtifacts`), and
  the harness (its own case matrix). `cabal build all` succeeds without the example stanza. Owning phase:
  phase-13 (Sprint 13.7). Replacement: `demo/`.
- **The pre-binary-boundary overreach in `hostbootstrap/bootstrap.py`** — the Docker-ensure
  (`colima_start_command`), the project-container build (`container_build_spec` + `docker_ops.build`),
  the Colima VM sizing, and the Linux build-in-container-and-copy-out
  (`copy_out_create_command`/`copy_out_cp_command`/`copy_out_rm_command`/`_copy_binary_out`).
  **Removed.** `bootstrap.py` is now the pre-binary path (assert minimums → ensure the host build
  toolchain → build the binary **host-native on every substrate** → exec). Ensuring Docker, building the
  container, config initialization, and the applied cordon are the project binary's job (§ M, § N, § X).
  Owning phase: phase-6 (Sprint 6.3); the temporary context-write handoff added by Phase 15 is now a
  pending legacy surface above.
- **The duplicate Python budget-interpretation logic** (`_gib` and the Python-side Colima sizing in
  `colima_start_command`) — a second quantity interpreter that mishandled the `"8Gi"` form. **Removed**
  with the overreach above (phase-6, Sprint 6.3); the Python bootstrapper no longer sizes a VM at all.
  The one canonical Haskell quantity parser/arg-builder in `HostBootstrap.Cluster.Cordon` that the
  project binary uses to size the VM is the phase-9 (Sprint 9.1) work; there is no longer a Python
  budget interpreter to dedup against.

- **`hostbootstrap/models/*`** (`container.py`, `host_binary.py`, `host_daemon.py`,
  `__init__.py`) — the three execution-model implementations. **Removed.** Every project now produces
  one binary through a single substrate-driven build/run path (`hostbootstrap/bootstrap.py`);
  there is no model dispatch. Owning phase: phase-6.
- **The three-execution-model + `Cluster`/`NoCluster` + `Mount` Dhall schema in
  `hostbootstrap/dhall/package.dhall`** — the rich union schema. **Replaced first** with the static-base
  schema (`project`, `dockerfile`, `resources {cpu, memory, storage}`), then removed entirely in Phase 6
  Sprint 6.4 with the Python Dhall package and reader. This completed entry records the old rich-union
  cleanup; the later Haskell `StaticBase` compatibility API cleanup is recorded above. Owning phase:
  phase-6.
- **The `spec.py` model dataclasses** (`Model`, `Lifecycle`, `Mount`, `ContainerArtifact`,
  `ContainerModel`, `HostBinaryModel`, `HostDaemonModel`, `TargetSpec`, `ResolvedTarget`, `target_for`).
  **Removed.** `hostbootstrap/spec.py` was temporarily rewritten to the static-base `StaticBaseSpec`
  reader, then removed in Phase 6 Sprint 6.4. Owning phase: phase-6.
- **The `--force-target` model dispatch** in `hostbootstrap/cli.py` — the `--force-target`
  option, the `isinstance(model, …)` branching across `_build` / `_run` / `_daemon_run` /
  `_cluster_*`, the `cluster` / `daemon` Click groups, and the `_model_name` / `_require_daemon` /
  `_require_cluster` helpers. **Removed.** The thin CLI is `doctor` / `build` / `run` / `base`; the bootstrapper
  has a single build-once-and-exec path driven by substrate detection. Owning phase: phase-6.
- **`python/tests/test_models.py`, `python/tests/test_spec_dhall.py`, and
  `python/tests/fixtures/dhall/*`** — pinned to `models/*` and the three-model schema. **Removed.**
  `python/tests/test_cli.py`, `test_spec.py`, and `test_prereqs.py` were rewritten to the thin surface;
  the later Python Dhall tests were removed with `dhall_tool.py` in Phase 6 Sprint 6.4. Owning phase:
  phase-6.
- **The hollow demo harness seams** (`demoSeams` in `demo/src/HostBootstrapDemo/Commands.hs`) — one
  shared `seamRun` that discarded the per-case identity and asserted only that the kind cluster existed, so
  every case (`pristine-bootstrap` / `web-build` / `e2e-tabs`) passed vacuously, and `seamSetup` invoked
  `clusterUp` in the host process rather than lifting it into the project container (where `helm`/`kind`
  live). **Superseded and removed** — replaced by real per-case seams (`assertClusterLive` /
  `assertWebBundle` / `assertE2E`, dispatched on the case id) that deploy the webservice into the per-case
  cluster via `demo/chart` and assert the workload; `e2e-tabs` lifts a Playwright container against the
  in-cluster NodePort with the spec delivered through a context-agnostic named volume (`deliverSpec`). The
  enabling fixes — the fail-closed `cluster up` (`requireStep` replacing the swallowed `reportStep`) and the
  `seamSetup`-in-`try` case isolation in `HostBootstrap.Harness` — landed under phase-5 / phase-10. All three
  cases are **live-validated on the metal host**: `pristine-bootstrap` + `e2e-tabs` directly on the host
  and `web-build` / `e2e-tabs` in a container **on the metal host's Docker**
  (`docker run … hostbootstrap-demo:local test web-build` / `… test e2e-tabs`, both `1/1`) — a dev
  shortcut, kind on the metal host's Docker, **not** the in-VM lifted path; the integrated in-VM run
  closed in phase-13 Sprint 13.12. This entry stays in **Completed** because the hollow-`demoSeams`
  surface itself **was** removed; the separate redundant deploy-chain representation it left in place is
  tracked as its own **Pending** entry above. Owning phase: phase-13 (Sprints 13.8/13.9). Replacement:
  real `demoSeams` driving the lift (see
  [composition_methodology](../documents/architecture/composition_methodology.md)).
- **The demo's `vm test` subcommand** (`vmTest` + `runDemoTests` in
  `demo/src/HostBootstrapDemo/Commands.hs`) — the per-noun test command that bound the demo's case
  matrix to `vm test` instead of the inherited `test` verb. **Removed.** The core `test` verb now runs
  the project matrix via the `TestSuite` hook (`runSuiteSelection` + the `all` selector); the demo
  binds `demoSeams`/`demoCases` through `demo/app/Main.hs` and its cases run under `demo test all` /
  `demo test <case>`. Owning phase: phase-10 (Sprint 10.6) / phase-13.

## Rules

Per [development_plan_standards.md § I](development_plan_standards.md):

- If an obsolete or duplicate surface still exists, it must appear in the **Pending** section above.
  Each entry names its location, the reason for removal, and the owning phase or sprint.
- When cleanup lands, move the entry from **Pending** to **Completed** in the same change.
- Empty `Pending` and `Completed` sections are valid. The ledger exists as a stable home so cleanup
  obligations are never lost; absence of pending items reflects current reality, not an incomplete
  file.

## Entry format

When a future entry is added, use this shape:

```markdown
- `path/to/obsolete/file` — short reason for removal. Owning phase: phase-N.
```

For more complex entries:

```markdown
- **`path/to/obsolete/surface`** — reason for removal. Owning phase: phase-N, sprint X.Y.
  Replacement: `path/to/new/surface` (see `documents/...`).
```
