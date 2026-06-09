# Phase 10: Standardized Test Harness and Run-Models

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-8-dhall-generation-and-extension.md](phase-8-dhall-generation-and-extension.md), [phase-9-applied-cordon-and-one-parser.md](phase-9-applied-cordon-and-one-parser.md)

> **Purpose**: Land the one standardized Dhall-driven test harness (`runMatrix` over a `Seams` record,
> with isolated per-case profiles, the prefix delete-guard, and budget-slicing) and name the minimal set
> of four run-models the harness and the bootstrapper select between.

## Phase Status

**Status**: Blocked

**Blocked by**: phase-8 (the `config render` per-case Dhall and the `Core.dhall` budget helpers), phase-9
(the applied cordon and `fitsBudget`/`Budget/split`)

Every project's tests run through one L0 engine: `runMatrix` drives a list of generated per-case configs,
each spinning up an isolated, budget-sliced environment that tears down while preserving production
`.data`. The harness is parameterized by a `Seams` record (the default seams do a container run; cluster
projects supply kind/Helm seams), and the app supplies only the case matrix. The same phase names the
four run-models the wider system selects between.

## Phase Objective

Provide the reusable test workflow and the run-model contract (see
[development_plan_standards.md § S, T](development_plan_standards.md)). Isolation, the delete-guard, the
profile/path derivation, budget-slicing, and report aggregation live once in L0; the app supplies the
matrix; never-touch-production is mechanical and unit-tested.

## Sprints

### Sprint 10.1: `runMatrix` driver and per-case isolation [Blocked]

**Status**: Blocked
**Blocked by**: phase-8 (sprint 8.4)
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Harness.hs` (planned)
**Docs to update**: `documents/architecture/harness_workflow.md`, `system-components.md`

#### Objective

Land the matrix driver and the isolated per-case profile derivation.

#### Deliverables

- `runMatrix :: Seams env -> [Case] -> IO Report`. Per case: derive the `TestCase` profile (cluster name
  `<project>-test-<case>`, data root `./.test_data/<case>/`), render the per-case Dhall, run the body, and
  tear down in a guaranteed `finally`; aggregate a `Report`.

#### Validation

- `HarnessSpec` asserts the profile/path derivation and that teardown runs on a failing case body.

#### Remaining Work

None.

### Sprint 10.2: `guardTestDelete` and the never-touch-production invariant [Blocked]

**Status**: Blocked
**Blocked by**: phase-5 (the teardown partition)
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`, `haskell/hostbootstrap-core/src/HostBootstrap/Harness.hs` (planned)
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/cluster_lifecycle.md`

#### Objective

Make never-touch-production mechanical: a parameterized prefix delete-guard plus the data-preserving
teardown partition.

#### Deliverables

- `guardTestDelete :: Prefix -> ClusterName -> Either GuardError ClusterName` (the prefix is
  project-supplied); the test-profile teardown refuses any name not matching the prefix. The pure
  `teardown` partition keeps `.data` out of the removal set for both `down` and `delete`.

#### Validation

- `LifecycleSpec`/`HarnessSpec` assert a non-prefixed name is rejected and `.data` is never in the removal
  set. `cabal test` passes.

#### Remaining Work

None.

### Sprint 10.3: Budget-slicing [Blocked]

**Status**: Blocked
**Blocked by**: phase-9 (sprint 9.3)
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Harness.hs` (planned)
**Docs to update**: `documents/architecture/harness_workflow.md`

#### Objective

Keep the matrix within the project ceiling.

#### Deliverables

- `sliceBudget` divides the budget across concurrent cases via `Budget/split`; `fitsBudget` is checked
  against the actual concurrent set. Divisible CPU cases split equally; GPU/indivisible cases run serially
  at full budget (driven by a per-case weight/`indivisible` field).

#### Validation

- A test asserts the concurrent slices sum within budget and a GPU case runs at concurrency 1.

#### Remaining Work

None.

### Sprint 10.4: The four run-models and the selection key [Blocked]

**Status**: Blocked
**Blocked by**: phase-6 (build-twice/copy-out), phase-10 (sprint 10.1)
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Harness.hs`, `python/hostbootstrap/bootstrap.py` (planned)
**Docs to update**: `documents/architecture/run_models.md`, `documents/architecture/build_and_run_model.md`

#### Objective

Name the minimal run-model set and how it is selected.

#### Deliverables

- The four models — `OneShot` (build-if-needed + `docker run --rm [-it] [mounts]`, budget-capped),
  `HostNative` (build-twice/copy-out + host exec), `HostDaemon` (long-running host service), `Cluster`
  (kind+Helm) — and the selection key `(verb x detected-substrate x library-layer x generated-topology)`,
  never declared in Dhall. The default container-run (`OneShot`) `Seams` ship in L0.

#### Validation

- The default `Seams` run a one-shot container case; `run_models.md` documents the selection key.

#### Remaining Work

None.

### Sprint 10.5: `test` and `check-code` verbs [Blocked]

**Status**: Blocked
**Blocked by**: phase-10 (sprint 10.1)
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Command.hs` (planned)
**Docs to update**: `documents/engineering/testing.md`, `documents/engineering/code_check_doctrine.md`

#### Command Surface

- `<project> test <suite>` — drive `runMatrix` and print the report card.
- `<project> check-code` — the image-build gate; the body is project-defined.

#### Deliverables

- Both verbs on the core tree, inherited by every binary; `check-code` wraps the project's own checks
  fail-fast.

#### Validation

- `<project> test --help` lists suites; `<project> check-code` exits non-zero on a seeded failure.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/run_models.md` - the four run-models matrix and the selection key.
- `documents/architecture/harness_workflow.md` - the per-case loop, the seam-split (L0 driver vs cluster
  seams vs app matrix), and budget-slicing.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` - rewritten to the standardized harness and the `test` verb.

**Cross-references to add:**
- `system-components.md` adds the `HostBootstrap.Harness` row and the `test`/`check-code` verbs.
- `documents/engineering/code_check_doctrine.md` states `check-code` is a project-defined body.
