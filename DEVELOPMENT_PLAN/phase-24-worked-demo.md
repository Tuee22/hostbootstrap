# Phase 24 — The worked demo

**Status**: Active
**Depends on**: Phase 23 (base image publication and the opportunistic warm store)
**Substrates**: linux-cpu
**Gate**: `cabal build all` and `cabal test all --ghc-options=-Werror` from `demo/`, plus a live
`hostbootstrap run -- test run all` reporting `10/10 passed` on linux-cpu

> **Purpose**: Be the real consumer that proves the library composes — a complete application with its own
> plan, config vocabulary, test component, and service variants.

## Phase Objective

Everything below this phase is a library. This phase is the consumer that exercises it end to end: a
scope-polymorphic plan instantiated separately for production and for each harness run, a web application with
a real cluster, an in-cluster registry backed by object storage, an accelerator daemon, and a five-case test
matrix generated from decoded configuration.

It is also where the container quality gate lives, because `fourmolu` and `hlint` run only inside the image's
own `check-code` — see [rationale.md](rationale.md).

## Sprints

### Sprint 24.1: The demo plan and config vocabulary [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/src/HostBootstrapDemo/Config.hs`,
`demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

One scope-polymorphic plan the demo instantiates per scope.

#### Deliverables

- The demo declares its own config vocabulary and its own step fragments, finalized into one `StepPlan`; it adds
  no verb of its own.
- The plan is scope-polymorphic and is instantiated separately for `Production` and for each harness run, so a
  test run's cluster, data root, and ports derive from its run identity.
- The demo's chain runs on the core interpreter; there is no demo-local deploy interpreter.
- The pulled rolling base is consumed `FROM` the published tag, and the in-Dockerfile `check-code` stage runs the
  container gate.

#### Validation

`CommandsSpec` covers the plan shape, both scope instantiations, and the config vocabulary. The container gate
runs on every image build.

#### Remaining Work

None.

### Sprint 24.2: The application, registry, and accelerator daemon [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Web/`, `demo/src/HostBootstrapDemo/Container.hs`,
`demo/src/HostBootstrapDemo/Accelerator/`, `demo/chart/`, `demo/web/`
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/engineering/accelerator_daemon.md`

#### Objective

A real application with real dependencies.

#### Deliverables

- A web service and single-page application, served through the cluster, with an idiomatic Dockerfile.
- A single-binary in-cluster registry backed by object storage, with a finalized registry plan that renders
  redirect configuration as output and requires a settled route before an image push.
- An accelerator daemon reached over a private listener with a CBOR round trip, placed per substrate: in-cluster
  behind a service address on Linux, host-native behind a local-only node port on Apple and Windows.
- The daemon's readiness is observed rather than slept for, and its launch uses the sealed invocation-shape
  boundary so a pre-readiness failure writes its cause somewhere readable.

#### Validation

`CommandsSpec` plus the live `10/10` matrix on linux-cpu. Dated evidence: the native Incus/ClusterIP/C++ lane
reported `10/10 passed`.

#### Remaining Work

None.

### Sprint 24.3: The five-case test matrix from decoded config [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/src/HostBootstrapDemo/Config.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`, `documents/operations/demo_runbook.md`

#### Objective

Generate the matrix from configuration, not from Haskell source.

#### Deliverables

- Five compiled cases: `pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence`, and
  `durable-readback`; two config variants; ten report-card rows.
- `durable-readback` writes through the web service, runs `project destroy`, runs `project up`, and reads the same
  bytes back from the host durable root.
- The test matrix and its variant drafts are constructed from **decoded typed config values**, so changing the
  variant set does not require a Haskell edit.
- The demo's test component receives only the harness-indexed planning function.

#### Validation

`CommandsSpec` covers the generated matrix and each case's assertions; the live `test run all` reports
`10/10 passed`.

#### Remaining Work

The five cases and two variants exist and pass, but the matrix is constructed in Haskell rather than projected
from decoded config, so adding a variant still requires a source edit. The remaining item is that projection,
which consumes the typed case/variant projection in the Dhall-configuration phase.

### Sprint 24.4: Production-plan wiring and artifact provenance [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Make the demo's production path use the same owned machinery its harness path does.

#### Deliverables

- The demo's production plan is threaded through the same profile opener, prepared operations, and teardown
  projection as its harness plan; there is no production-only shortcut.
- Published-base consumption is enforced by digest, so a derived build cannot silently use a stale local image.
- Object-storage and registry metadata are reconciled from one finalized plan.
- The durable-share and guest-alias operations are prepared operations that mint managed handles.

#### Validation

The live `test run all` on linux-cpu plus the production `project up` / `down` / `destroy` sequence.

#### Remaining Work

The demo's plan resolution still hardcodes `Production`, so the live test stack uses the production cluster
identity and durable root — which is why the long gate must run on a disposable host. Threading the harness
profile through the demo's own resolution is the remaining item, together with the prepared guest-alias adoption
that waits on the step-reaches-a-gate work.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/network_reachability.md` — the demo's concrete reachability-safe rendering.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — what the long gate covers that the static suites cannot.
- `documents/engineering/accelerator_daemon.md` — the per-substrate placement.

**Cross-references to add:**
- `documents/operations/demo_runbook.md` — the operator sequence, the duration envelope, and the
  disposable-host requirement.
