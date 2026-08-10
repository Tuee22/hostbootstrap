# Phase 24 — The worked demo

**Status**: Active
**Depends on**: Phase 16 (exact cluster and direct-provider consumers), Phase 23 (base image publication and
the opportunistic warm store)
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
**Implementation**: `demo/src/HostBootstrapDemo/Config.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/ConfigSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`, `documents/operations/demo_runbook.md`

#### Objective

Generate the matrix from configuration, not from Haskell source.

#### Deliverables

- Five compiled cases: `pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence`, and
  `durable-readback`; two config variants; ten report-card rows.
- `durable-readback` writes through the web service, runs `project destroy`, runs `project up`, and reads the same
  bytes back from the host durable root.
- `TestConfig` carries a declared `testVariants` set, and `demoTestMatrix` projects the run matrix out of it, so
  adding, renaming, or removing a variant is an edit to the generated `<project>.test.dhall` rather than to a
  Haskell module. `test init` writes the two the demo ships with.
- Each declared name is validated into a `VariantId` while the matrix is being built — before the run acquires
  anything. An empty set is the core's own `EmptyVariantRegistry`, duplicates are its `DuplicateVariantIds`, and a
  malformed name is `InvalidVariantDeclaration`, which the harness phase's matrix vocabulary now carries because
  a project's decoded declaration is exactly where one can be malformed.
- The demo's `TestSuite` supplies the safety probe, assertion environment, typed case matrix, per-case
  assertions, and post-reverse absence assertion. It receives no lifecycle callback; the harness engine owns
  and retains the exact Harness plan.

#### Validation

`ConfigSpec` covers the projection directly: the matrix's variants are the declared ones, a third variant
appears from a config edit alone, each variant carries its own served message, every case runs under every
declared variant, and each of the empty, malformed, and duplicate declarations is refused before the run.
`CommandsSpec` covers the immediate live-stack assertions. The live `test run all` must report
`10/10 passed`, including both destroy/up cycles.

#### Remaining Work

The config-derived five-case/two-variant matrix is implemented. The `durable-readback` assertion remains
open: project-owned assertion code has no lifecycle callback and deliberately reports failure until the
harness engine can interpret a declarative write/read assertion around one exact same-run recreate cycle.
That cycle retains the Harness mode, run, config, durable root, and plan; consumes a version-bound settled
destroy; allocates a fresh lifecycle-invocation generation for the second `up`; and permits only the final
generation's settled destroy to authorize terminal Harness close. The live `10/10` gate supplies the
end-to-end evidence.

### Sprint 24.4: Plan-owned profile/root wiring and artifact provenance [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/src/HostBootstrapDemo/Config.hs`,
`demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Make both demo scopes consume the profile and canonical durable root retained by their exact project plan.

#### Deliverables

- Production and Harness dispatch retain one exact `ProjectPlan` through prepared operations and the reverse
  projection; there is no production-only shortcut.
- `RunProfile` is descriptive assembly input consumed once while the scope-correct plan is constructed. Cluster,
  provider, mount, and teardown consumers receive only the plan-owned profile/root projection; they do not
  reread `runProfile`, call `clusterProfileOf` on a child config, or accept an independently supplied
  `ClusterProfile` or filesystem root.
- The plan-owned projection derives cluster name, removable state, port publication, and durable host root
  together. Production owns its preserved `.data`; Harness owns `.test_data/<run>` under its four-clause run
  bracket. The path mounted into the guest and the `PreserveOnReverse` resource are the same plan projection.
- The pre-run safety probe remains deliberately Production-specific, but it is assertion input rather than
  lifecycle authority and cannot be reused to choose the Harness plan.
- Post-reverse absence verification consumes the retained Harness plan and current-frame reverse projection; it
  does not reread the generated sibling config to reconstruct a profile or root.
- Published-base consumption cannot silently fall back to a stale local image. Every derived build passes
  `--pull`, and the host-native lane additionally resolves the published tag to a repository digest and builds
  `FROM` that within-run reference. The digest is neither written to config nor committed.
- Object-storage and registry metadata are reconciled from the same finalized plan.

#### Validation

`CommandsSpec` covers plan-owned profile/root projection for both scopes, child-frame retention, Harness name
and port isolation, mount/preserve identity, and post-reverse verification from the retained plan. A
public-signature/source guard rejects a cluster, provider, mount, or teardown consumer that accepts independent
`RunProfile`, `ClusterProfile`, or root terms. `ProjectRootSpec` covers canonical subpath admission.
`CommandsSpec` and `ConfigSpec` continue to cover `--pull`, repository-digest resolution, malformed-digest
refusal, and published-tag inspection. The live `test run all` plus the Production `project up` / `down` /
`destroy` sequence close the runtime half.

#### Remaining Work

The published-base handoff is implemented. Exact plan-owned profile/root projection and removal of independent
consumer terms remain open.

### Sprint 24.5: Concrete workload and slice projection [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/src/HostBootstrapDemo/Config.hs`,
`demo/test/CommandsSpec.hs`,
`demo/test/ConfigSpec.hs`,
`demo/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/operations/demo_runbook.md`

#### Objective

Project the demo's real non-empty workload, overhead, partition, and resource slices from its exact plan.

#### Deliverables

- Decoded demo sizing and the exact workload-bearing `PlannedResource`s produce one non-empty
  `PlannedWorkloadSet`; workload names and frames come from those resources rather than parallel strings.
- The demo declares explicit cluster/system overhead and slice requests, verifies workload fit, and constructs
  one `BudgetPartition` whose `ResourceSlice`s remain indexed to the same plan and provider wall.
- The exact cluster and direct-provider consumers receive only their matching slice and reservation. No raw
  `ResourceEnvelope`, independently reconstructed budget, or unpartitioned host floor reaches an adapter.
- Production and Harness reuse the same projection function under different exact plans; their workload,
  partition, and slice values cannot be exchanged.

#### Validation

`CommandsSpec` and `ConfigSpec` cover the concrete non-empty workload set, declared overhead, exact fit and
overflow, complete partition, and delivery of the matching slice to each consumer. Compile-fail fixtures reject
cross-plan workload, provider, partition, and slice substitution.

#### Remaining Work

All deliverables, after Sprints 12.30, 16.2, and 16.4 expose their exact generic and consumer boundaries.

### Sprint 24.6: Guest-alias consumer adoption [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Use the clause-holding prepared guest-alias backend from the exact demo plan.

#### Deliverables

- The `copy-source` step uses its plan-minted `StepExecution` to call `reconcileNodeGuestAlias`.
- Provider and durable-share dependencies come from the node descriptor, and the one prepared gate is consumed
  for exactly that alias projection.
- The `copy-source` route contains no demo-local alias classifier or raw guest probe; settlement returns no
  managed handle or receipt to unproved callers.

#### Validation

`CommandsSpec` covers descriptor-driven preparation and conflict refusal. The live linux-cpu gate observes the
managed alias inside a real guest and confirms receipt-gated cleanup.

#### Remaining Work

All deliverables. The demo's guest calls still name a raw guest-shell planner that the provider boundary does
not expose, so the demo package does not compile until this adoption lands.

### Sprint 24.7: Authenticated derived-image gate [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `demo/docker/Dockerfile`,
`demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`,
`documents/engineering/derived_dockerfile.md`

#### Objective

Consume the reusable build-invocation protocol at the worked demo's real command and Docker-build boundary.

#### Deliverables

- The static core command seam distinguishes ordinary developer `check-code` from an attesting image-build
  gate and requires the latter to receive the exact `ImageBuildFrame` and `BuildInvocationAuthority` before
  invoking the project code-check action.
- The demo build route fixes the source root from the build engine's actual context and the builder path from
  the command's running executable, measures those paths and the coordinator binary, signs one exact binding,
  and delivers the channel through a build-engine secret/session mount rather than Dhall, `argv`, an
  environment variable, an image layer, or durable config. Neither path is accepted from untrusted command
  input.
- The concrete channel owns cross-verification replay: it either presents and acknowledges the signed channel
  exactly once or durably consumes the exact `buildId` before invoking the gate. A fresh call to the reusable
  verifier cannot by itself satisfy this guarantee.
- Missing, replayed, mismatched, or unmeasured delivery refuses; the existing baked
  `image-build-container` config remains descriptive and cannot provide fallback authority.
- The Dockerfile and demo command route consume `HostBootstrap.Build`; they do not mint a second build
  authority representation.

#### Validation

Focused core/demo command tests cover the authorized route and every refusal. They prove the consumer fixes its
measurement paths and that presenting the same valid signed channel through a fresh verification attempt is
refused before project code-check runs. A real derived-image build proves the in-Dockerfile gate consumed and
acknowledged the ephemeral authority and that an absent channel fails closed.

#### Remaining Work

All command-consumer, coordinator-channel, Dockerfile, focused-test, and live-container integration. In
particular, implement and test trusted source-root/running-executable derivation plus either single
presentation/acknowledgement or durable `buildId` replay refusal across separate verifier calls.

## Remaining Work

Sprint 24.3 owns the exact same-run durable write/destroy/up/read assertion. Sprint 24.4 replaces independent
profile/root terms with the retained plan projection. Sprint 24.5 supplies the concrete workload, overhead,
partition, and slices consumed by the exact Phase-16 cluster and Colima boundaries. Sprint 24.6 adopts the
clause-holding guest-alias route, which is also what makes the demo package compile again: its guest calls
still name a raw guest-shell planner the provider boundary does not expose. Sprint 24.7 consumes the
authenticated build protocol in the real demo command/Dockerfile route. The phase closes only after the demo
static gate, live `10/10` Harness run, and Production `up` / `down` / `destroy` sequence pass on linux-cpu.

Because every downstream live gate drives the demo binary, the live halves of the cluster-lifecycle,
recursive-lifecycle, test-harness, and `test`/`context` phases cannot run before Sprint 24.6 restores that
build. Those phases still own their own gates; this sprint is what makes them runnable.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/network_reachability.md` — the demo's concrete reachability-safe rendering.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — what the long gate covers that the static suites cannot.
- `documents/engineering/accelerator_daemon.md` — the per-substrate placement.

**Cross-references to add:**
- `documents/operations/demo_runbook.md` — the operator sequence, the duration envelope, and the
  disposable-host requirement.
