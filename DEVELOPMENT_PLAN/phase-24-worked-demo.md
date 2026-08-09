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

### Sprint 24.3: The five-case test matrix from decoded config [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Config.hs`, `demo/test/ConfigSpec.hs`
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
- The demo's test component receives only the harness-indexed planning function.

#### Validation

`ConfigSpec` covers the projection directly: the matrix's variants are the declared ones, a third variant
appears from a config edit alone, each variant carries its own served message, every case runs under every
declared variant, and each of the empty, malformed, and duplicate declarations is refused before the run.
`CommandsSpec` covers each case's assertions; the live `test run all` reports `10/10 passed`.

#### Remaining Work

None.

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
- The run's profile is a field of the config rather than a constant in the source. `RunProfile` is written by
  assembly — `ProductionRun` for a production config, `HarnessRun` carrying that run's own name for a harness
  one — and `clusterProfileOf` turns it into the core's `ClusterProfile`. Because it is an ordinary field of the
  config a parent streams to each child frame, the container frame resolves the profile the host frame decided
  rather than re-deciding it.
- Every cluster plan the demo resolves takes that profile, so a harness run gets its own run-scoped cluster
  name, its own removable state, and no host-port publishing. The one deliberate exception is the pre-run safety
  probe, which asks whether the operator's *production* stack is running and must therefore keep naming it.
- The **durable host root** is the run's own as well: `profileDataSegments` is the single definition of where a
  run's durable state lives — production's never-removed `.data`, or the `.test_data/<run>` generation the
  harness ownership bracket already holds under all four clauses — and both a resolved plan's preserved
  `dataPath` and the container's durable mount derive from it, so the directory mounted and the directory
  preserved are one by construction. `canonicalHostSubPath` is what admits it: a run-scoped root is not a fixed
  name, so the segments are supplied and each is checked to be a single ordinary component, because a segment
  that could climb out would hand a trusted host adapter a path the root never admitted.
- The harness's own teardown verification reads the profile off the generated sibling config before running
  `project destroy`, so what it proves gone is the run's stack rather than production's.
- Published-base consumption cannot silently fall back to a stale local image. Two things enforce it, and the
  split is deliberate:
  - every derived build passes `--pull`, so the base named in `FROM` is fetched before the build rather than
    taken from whatever the host already has under that rolling tag. It is on the argv rather than in a wrapper
    because both lanes go through one builder, including the one that renders the argv into an in-VM shell
    script where a command substitution would be quoting-fragile;
  - the host-native lane additionally resolves the published tag to its **repository digest** and builds `FROM`
    that reference. An image with no repository digest is refused by name — that is exactly the stale-local
    case, since an image built locally and never pulled or pushed has no repo digest at all.
  The digest is a **within-run handoff**, never written to config or committed: § FF is explicit that a digest
  "does not make locked inputs, digest-pinned consumers, or reproducible rebuilds part of the architecture", so
  the reference is resolved fresh on every build and a rebuild that discovers a newer compatible base simply
  resolves a newer digest.
- Object-storage and registry metadata are reconciled from one finalized plan.
- The durable-share and guest-alias operations are prepared operations that mint managed handles.

#### Validation

`CommandsSpec` covers the profile threading: a harness run's container plan carries its own cluster name, its
own state, and no host ports, while production's keeps all three; the profile decoded from a config survives
each child-frame projection; and the durable root a run mounts is the same path its plan preserves, for both
profiles. `ProjectRootSpec` covers the subpath admission — the production and run-scoped roots it produces, and
that `..`, `.`, an empty segment, an embedded separator, a drive letter, and an empty segment list are each
refused by name. `CommandsSpec` and `ConfigSpec` cover the published-base consumption: every derived build's
argv carries `--pull` and still passes the base through as a build arg, a published digest pins the repository
rather than the tag text (including when a registry port is present and when the reference carries no tag), a
digest that is not a `sha256:` reference is refused rather than concatenated, and the pull and inspect argv name
the published tag and ask for its repository digests. The live `test run all` on linux-cpu plus the production `project up` / `down` / `destroy`
sequence close the rest.

#### Remaining Work

One item. Published-base consumption is enforced; the guest-alias route is not.

The demo still mints its durable alias through its own `classifyAlias`/`planAliasEnsure` state machine over raw
guest probes, rather than through `reconcileNodeGuestAlias` — the route the
[host-providers phase](phase-15-host-providers-and-the-lift.md) supplies, which is what turns the durable-share
and alias operations into prepared operations minting managed handles. Adopting it means threading a
plan-minted `StepExecution` into the alias step, which is a change to how that step is declared and driven
rather than a local edit, and its correctness is only really observable inside a live guest — so it is owed
together with this phase's live acceptance rather than closable against the static gate alone.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/network_reachability.md` — the demo's concrete reachability-safe rendering.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — what the long gate covers that the static suites cannot.
- `documents/engineering/accelerator_daemon.md` — the per-substrate placement.

**Cross-references to add:**
- `documents/operations/demo_runbook.md` — the operator sequence, the duration envelope, and the
  disposable-host requirement.
