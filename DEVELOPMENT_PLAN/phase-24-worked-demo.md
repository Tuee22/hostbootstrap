# Phase 24 — The worked demo

**Status**: Active
**Depends on**: Phase 16 (provider, cluster, and guest lifecycle foundations), Phase 17 (proof-complete
recursive lifecycle command), Phase 22 (service-runtime activation and `service run` semantics), Phase 23
(base image publication and the opportunistic warm store)
**Substrates**: linux-cpu
**Gate**: `cabal build all` and `cabal test all --ghc-options=-Werror` from `demo/`, plus live
`hostbootstrap run -- project up`, `hostbootstrap run -- project down`,
`hostbootstrap run -- project destroy`, and `hostbootstrap run -- test run all` reporting `10/10 passed` on
linux-cpu

> **Purpose**: Be the real consumer that proves the library composes — a complete application with its own
> plan, config vocabulary, test component, and service variants.

## Phase Objective

Everything below this phase is a library. This phase is the consumer that exercises it end to end: a
scope-polymorphic plan instantiated separately for production and for each harness run, a web application with
a real cluster, an in-cluster registry backed by object storage, an accelerator daemon, and a five-case test
matrix generated from decoded configuration.

It is also where the container quality gate lives, because `fourmolu` and `hlint` run only inside the image's
own `check-code` — see [rationale.md](rationale.md). Sprint 24.30 is the sole worked-demo live confirmation of
the host-static recursive lifecycle command completed by Phase 17.

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

- The demo declares its own config vocabulary and step fragments, finalized into one `StepPlan`; it adds no
  verb of its own.
- The plan is scope-polymorphic and is instantiated separately for `Production` and for each harness run, so a
  test run's cluster, data root, and ports derive from its run identity.
- The demo's chain runs on the core interpreter; there is no demo-local deploy interpreter.
- The pulled rolling base is consumed `FROM` the published tag, and the in-Dockerfile `check-code` stage runs
  the container gate.
- The decoded config, finalized plan, and generated test vocabulary remain one coherent demo-owned assembly;
  no hidden environment or command-line term changes its topology.

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
- The application, registry, and accelerator variants expose only their finalized service interfaces; demo
  orchestration does not acquire lifecycle authority from an application callback.

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
- `durable-readback` writes through the web service, runs `project destroy`, runs `project up`, and reads the
  same bytes back from the host durable root.
- `TestConfig` carries a declared `testVariants` set, and `demoTestMatrix` projects the run matrix out of it, so
  adding, renaming, or removing a variant is an edit to the generated `<project>.test.dhall` rather than to a
  Haskell module. `test init` writes the two the demo ships with.
- Each declared name is validated into a `VariantId` while the matrix is being built — before the run acquires
  anything. An empty set is the core's own `EmptyVariantRegistry`, duplicates are its `DuplicateVariantIds`,
  and a malformed name is `InvalidVariantDeclaration`.
- The demo's `TestSuite` supplies the safety probe, assertion environment, typed case matrix, per-case
  assertions, and post-reverse absence assertion. It receives no lifecycle callback; the harness engine owns
  and retains the exact Harness plan.

#### Validation

`ConfigSpec` covers the projection directly: the matrix's variants are the declared ones, a third variant
appears from a config edit alone, each variant carries its own served message, every case runs under every
declared variant, and each of the empty, malformed, and duplicate declarations is refused before the run.
`CommandsSpec` covers the immediate stack assertions and the declarative write/read lifecycle shape. Sprint
24.30 owns the live `10/10` confirmation, including both destroy/up cycles.

#### Remaining Work

The config-derived five-case/two-variant matrix is implemented. The `durable-readback` assertion remains open:
project-owned assertion code has no lifecycle callback and deliberately reports failure until the harness
engine can interpret a declarative write/read assertion around one exact same-run recreate cycle. That cycle
retains the Harness mode, run, config, durable root, and plan; consumes a version-bound settled destroy;
allocates a fresh lifecycle-invocation generation for the second `up`; and permits only the final generation's
settled destroy to authorize terminal Harness close. Sprint 24.30 supplies the live evidence after the exact
consumer chain below is complete.

### Sprint 24.4: Plan-owned profile/root assembly and artifact provenance [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/src/HostBootstrapDemo/Config.hs`, `demo/test/CommandsSpec.hs`, `demo/test/ConfigSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands`, `HostBootstrapDemo.Config` (2; cap 3)
**Sprint budget**: no new named contract and no lifecycle call-site adoption; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Assemble both demo scopes from the profile and canonical durable root retained by their exact project plan,
and close the published-artifact provenance boundary without claiming later consumers are already adopted.

#### Deliverables

- Production and Harness assembly retain one exact `ProjectPlan`; `RunProfile` is descriptive input consumed
  once while the scope-correct plan is constructed, never independent lifecycle authority.
- The plan projection derives cluster name, removable state, port publication, and canonical durable host root
  together. Production owns preserved `.data`; Harness owns `.test_data/<run>` under its run bracket.
- The guest mount source and `PreserveOnReverse` resource are the same plan projection, and post-reverse absence
  verification consumes the retained Harness plan rather than rereading sibling config.
- Every derived build passes `--pull`; the host-native lane resolves the published base tag to a repository
  digest and builds `FROM` that within-run reference without writing it to config or the repository.
- This sprint exposes assembly/provenance inputs for later packages only. Provider, cluster, chart, and teardown
  consumers remain owned by their numbered adoption sprints and receive no premature plan-owned claim here.

#### Validation

`CommandsSpec` and `ConfigSpec` cover both scope assemblies, durable-root identity, Harness isolation, retained
post-reverse projection, `--pull`, digest resolution, malformed-digest refusal, and published-tag inspection.
The demo host-static gate must pass. The named-module and 400-line budgets are checked before implementation;
overflow is split into a new sprint rather than expanding this one. Sprint 24.30 owns live confirmation.

#### Remaining Work

The published-base handoff is implemented. Exact plan-owned profile/root assembly and removal of independent
assembly terms remain open; consumer adoption remains explicitly later.

### Sprint 24.5: Authored provider resources and exact direct-parent join [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrap.Step`, `HostBootstrap.Lifecycle.Plan`,
`HostBootstrapDemo.Commands` (3; cap 3)
**Sprint budget**: one new named type, `ProviderResourceDeclaration`, and no call-site adoption; at most 400
production Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/engineering/resource_budgeting.md`, `documents/operations/demo_runbook.md`

#### Objective

Let plans author provider resources at their actual target frames, then prove each cluster has exactly one
immediate provider parent.

#### Deliverables

- `HostBootstrap.Step` adds the sole named type `ProviderResourceDeclaration` and a closed declaration
  extension whose target is only the current frame or its unique immediate child; callers supply neither raw
  frame text nor a resource key.
- `Lifecycle.Plan` validates, retains, and hashes the declaration, resolves its target frame, and derives the
  `ProviderResource` identity from the declaring operation and target rather than assuming the executing frame
  or the literal `core:deploy-vm` operation.
- Validation refuses duplicates, a child target without exactly one declared descent, an absent topology
  target, and any declaration inconsistent with the node's exact resource prefix.
- The demo's pure projection enumerates only plan-admitted declarations, resolves each cluster frame's unique
  immediate parent, and joins it to exactly one provider at that frame; zero, duplicate, ancestor, sibling, or
  wrong-frame candidates fail before backend work.
- VM topology declares the provider at the VM target frame, while Direct topology declares a distinct Direct
  reservation provider at the current metal frame; the direct graph never invents a `deploy-vm` operation.

#### Validation

`ProjectPlanSpec`, compile-fail fixtures, and `CommandsSpec` cover stable identity, target-frame resolution,
VM and Direct success, and every ambiguous or mismatched join. The core and demo host-static gates must pass.
The named-type/module/line budgets are checked before implementation; any second type, adoption, fourth module,
or over-400 estimate is split into another sprint.

#### Remaining Work

The closed declaration vocabulary, stable plan encoding, and pure demo joins remain to be implemented.

### Sprint 24.6: Neutral exact-plan execution package [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Lifecycle.Execution.Internal`, `HostBootstrap.Lifecycle.Plan`,
`HostBootstrap.Reconcile` (3; cap 3)
**Sprint budget**: one new named type, `PlanExecutionPackage`, and no call-site adoption; at most 400 production
Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/generic_project_model.md`

#### Objective

Seed step execution with neutral canonical plan metadata without introducing an Execution-to-Plan import cycle.

#### Deliverables

- Cabal-private `PlanExecutionPackage` is owned by `Lifecycle.Execution.Internal` and contains only nominal plan,
  scope, frame, operation, resource-prefix, retained config-digest, and already-canonical metadata needed by an
  executing step; it does not contain `ProjectPlan` or a backend witness.
- `Lifecycle.Plan` owns the fixed projection that inspects the exact admitted `ProjectPlan` and emits only
  canonical neutral terms. `Reconcile.stepExecutionFor` is the sole package constructor joining those terms
  through the hidden constructor; `Lifecycle.Execution.Internal` never imports Plan or `ProjectPlan`.
- Demo action configuration is available only as canonical plan metadata emitted through its finalized codec;
  a typed consumer must re-render and match the retained digest before using projected fields.
- The package is carried by a dedicated hidden execution slot, not `CarriedResource`, and cannot be forged,
  replaced, decoded from public bytes, or reconstructed from independently supplied config.
- Forward step projections retain the same nominal package identity and exact resource prefix; mismatched plan,
  scope, frame, operation, digest, or generation is refused before an action begins. Teardown receives no
  `StepExecution` package, so this sprint makes no reverse-consumption claim.

#### Validation

`ReconcileSpec` and compile-fail fixtures cover sole production, digest agreement, forward retention, mismatch
refusal, hidden construction, and an import-cycle guard. The core host-static gate must pass. The sole-type,
module, and 400-line budgets are checked before implementation; overflow is split before work starts.

#### Remaining Work

The neutral carrier, sole producer, and finalized-codec digest checks remain to be implemented.

### Sprint 24.7: Workload partition and exact plan slices [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/src/HostBootstrapDemo/Config.hs`, `demo/test/CommandsSpec.hs`, `demo/test/ConfigSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands`, `HostBootstrapDemo.Config` (2; cap 3)
**Sprint budget**: no new named contract and no lifecycle call-site adoption; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/operations/demo_runbook.md`

#### Objective

Derive the demo's provider, cluster, and workload partitions and their exact frame-local slices from the
admitted plan package.

#### Deliverables

- A pure projection partitions finalized operations into provider, cluster, chart/workload, service, and
  assertion roles by closed operation/resource kind rather than by textual key convention.
- Each projected role retains the exact nominal plan, scope, frame, operation, resource prefix, and config
  digest from `PlanExecutionPackage`; a consumer cannot widen a slice or substitute a sibling frame.
- The VM and Direct topologies produce distinct but structurally checked slices, including the provider join
  from Sprint 24.5 and the child-local workload suffix below the selected container edge.
- Canonical demo config is re-rendered through the finalized codec and digest-matched before any cluster,
  workload, port, or durable-root field is projected.
- Missing, duplicate, out-of-order, cross-scope, wrong-frame, or digest-mismatched entries refuse during pure
  projection, before budget admission or backend effects.

#### Validation

`CommandsSpec` and `ConfigSpec` cover both topology shapes, exact slice membership, ordering, digest checks,
and every refusal. The demo host-static gate must pass. The module and 400-line budgets are checked before
implementation; any new named contract, adoption, fourth module, or overflow is split into a new sprint.

#### Remaining Work

The closed partition and exact-slice projection remain to be implemented.

### Sprint 24.8: Domain-separated runtime dependency package [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/LifecycleDependencySpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Lifecycle.Dependency.Internal`,
`HostBootstrap.Lifecycle.Execution.Internal` (2; cap 3; Cabal metadata is not a production module)
**Sprint budget**: one new named type, `RuntimeDependencyPackage`, and no call-site adoption; at most 400
production Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/binary_context_config.md`

#### Objective

Carry domain-separated canonical recovery commitments and a package-private fresh-probe route without creating
a Dependency/Reconcile/Execution import cycle or smuggling runtime authority through a generic carrier.

#### Deliverables

- Cabal-private `RuntimeDependencyPackage scope planId` is the sole named type. Its closed domain distinguishes
  provider and cluster recovery, and its canonical fields bind plan, scope, resource, frame, backend origin,
  generation, journal/receipt commitments, route, and expiry.
- The package may retain only a package-private bounded client route, never a backend or fresh-probe closure,
  and never retains or serializes
  `ManagedProviderHandle`, `ManagedProviderShareHandle`, `RunningProviderDependency`, `ClusterReadiness`, any
  generic managed handle, or receipt authority.
- A separate invocation-owned opaque live-service registry may hold a closure capturing the strong backend and
  managed handle/readiness source after its `StepAction`; the canonical package registry holds commitments and
  bounded client routes only. Both registries are private tuple fields, not additional named types.
- `Lifecycle.Execution.Internal` holds both interpretation-wide registries once per invocation and shares them
  across every `StepRuntime`, independent of per-step state and `CarriedResource`. Neither lower module imports
  Provider, Cluster, Reconcile, or ProjectPlan types, so the DAG stays acyclic.
- Package construction, domain opening, closure replacement, and public decoding remain hidden. Wrong domain,
  nominal identity, commitment, route, generation, or lifetime is rejected before a probe is attempted.

#### Validation

`LifecycleDependencySpec`, compile-fail fixtures, and an import-cycle guard cover hidden construction, exact
commitments, domain separation, dedicated carriage, and the absence of every forbidden witness type. The core
host-static gate must pass. The sole-type/module/line budgets are checked before implementation; overflow is
split rather than weakening the boundary.

#### Remaining Work

The private package, interpretation-wide registry, canonical commitments, and abstract fresh-probe route
remain to be implemented.

### Sprint 24.9: Provider-domain package producer [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/LifecycleDependencySpec.hs`
**Production modules**: `HostBootstrap.Lifecycle.Dependency.Internal`,
`HostBootstrap.Substrate.Provider.Backend` (2; cap 3)
**Sprint budget**: no new named contract and no consumer call-site adoption; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Register an invocation-only pending provider commitment and live service after exact action-local
provision-to-ready settlement; fixed-node `Chain` sequencing alone prevents a successor/descent from running
until the producer gate has been acknowledged.

#### Deliverables

- `Substrate.Provider.Backend` can register a pending provider-domain package only inside the action-local
  settled running-provider bracket. `StepAction` returns before `Chain.acknowledgeOutcome` durably commits the
  row, so package registration never claims that the journal is already committed.
- Canonical commitments bind the plan/resource/frame/backend origin, backend generation, producer operation and
  gate, action-local ready observation, package route, and bracket expiry; a key/generation/version tuple alone
  is insufficient. Provider Ready has no separate durable journal row.
- The backend registers a bounded fresh-reprobe closure under that commitment in the invocation-owned opaque
  live-service registry. The closure captures the strong backend and managed provider handle; neither enters
  the canonical package registry or generic execution carrier.
- The package-private bounded client route addresses only that service and commitment; it cannot expose a raw
  probe, backend command, closure, handle, journal writer, or caller-selected resource identity.
- Only the fixed successor/descent node may look up the pending package after `Chain` has acknowledged the
  producer gate and advanced. Failure, retry, stale generation, or closed invocation invalidates package and
  service; every fresh lifecycle invocation starts with empty registries. No separate journal-promotion API is
  introduced.

#### Validation

`ProviderBackendSpec` and `LifecycleDependencySpec` cover pending registration, fixed-successor opening,
premature/wrong-node/stale/expired/retry/fresh-invocation refusal, and a source-shape assertion that the package
contains no handle. The core host-static gate must pass. Module and 400-line budgets are checked before work;
any new type or adoption is split out.

#### Remaining Work

The settled producer, backend-owned service registration, and commitment tests remain to be implemented.

### Sprint 24.10: Fresh provider dependency recovery [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Reconcile.hs`,
`core/hostbootstrap-core/test/ProviderReconcileSpec.hs`,
`core/hostbootstrap-core/test/LifecycleDependencySpec.hs`
**Production modules**: `HostBootstrap.Lifecycle.Dependency.Internal`,
`HostBootstrap.Substrate.Provider.Backend`, `HostBootstrap.Substrate.Provider.Reconcile` (3; cap 3)
**Sprint budget**: no new named contract and no project call-site adoption; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Open an exact provider package into a fresh lexical running dependency only after backend reprobe and ownership
evidence agree.

#### Deliverables

- The hidden provider-domain opener is available only to the fixed successor/descent after acknowledged producer
  sequencing; it verifies plan, scope, resource, frame, backend origin, generation, action-local ready
  commitment, route, and live expiry. It depends only on that sequencing and invents no provider-ready rows.
- It invokes the package-private fresh probe; the live provider service rechecks its still-owned handle against
  the real backend and returns only a sealed observation bound to the request nonce and commitment.
- `Substrate.Provider.Reconcile` combines that observation with the exact journaled ownership evidence and
  reconstructs a
  fresh `ManagedProviderHandle` and `RunningProviderDependency` only inside a lexical continuation.
- Neither successful canonical decoding nor successful backend reachability alone is enough. Missing provision
  or ready ownership, replay, wrong nonce, changed origin/generation, closed lifetime, or a mismatched resource
  refuses without yielding a dependency.
- The recovered witnesses cannot enter `RuntimeDependencyPackage`, `PlanExecutionPackage`, `CarriedResource`,
  stable bytes, config, environment, argv, or a return value that outlives the continuation.

#### Validation

`ProviderReconcileSpec` and `LifecycleDependencySpec` cover fresh success and all commitment, ownership,
reprobe, replay, and lifetime failures; compile-fail coverage rejects escaping the witnesses. The core
host-static gate must pass. The module and 400-line budgets are checked first; any type or consumer adoption is
split out.

#### Remaining Work

The hidden opener, backend reprobe/refinement, and lexical non-escape tests remain to be implemented.

### Sprint 24.11: VM provider provision-to-ready adoption [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: one VM provider call-site adoption and no new named contract; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Adopt the exact VM provider resource through provision, ready settlement, and provider-package production.

#### Deliverables

- The VM topology consumes only the Sprint 24.5 provider declaration resolved at the VM target frame and the
  matching plan execution package/slice; no operation-name fallback or caller-built key is accepted.
- One demo call site prepares, runs, journals, and settles the Phase 16 VM provider reconciler under the exact
  budget and lifecycle bracket before any cluster or descent work begins.
- Action-local ready settlement proves the observed backend identity/generation and uses Sprint 24.9 to register
  an invocation-only pending provider package/service. Only the fixed later node reached after `Chain`
  acknowledges the producer gate may open it; failure, retry, or fresh invocation clears it.
- The package, not a managed/running witness, is installed in the interpretation-wide dependency registry for
  subsequent descent; failed or provisional runs install nothing and retain no package.
- This forward adopter writes the exact settled provider journal identity needed by Sprint 24.27's separate
  teardown/command adoption; it does not claim that a `TeardownAction` can consume `PlanExecutionPackage`.

#### Validation

`CommandsSpec` covers exact VM success, sequencing, package carriage, failure unwind, the journal identity and
static reverse-input projection required by Sprint 24.27, and rejection of wrong frame/resource/journal/budget.
The demo host-static gate must pass. The one-adoption/module/line budgets are checked before implementation;
overflow is split before this call site lands.

#### Remaining Work

The VM provider adoption and its static fixtures remain to be implemented.

### Sprint 24.12: Direct provider reservation-to-ready adoption [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: one Direct provider call-site adoption and no new named contract; at most 400 production
Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Adopt the Direct lane's explicit current-frame provider reservation without pretending it is a VM deployment.

#### Deliverables

- The Direct topology consumes its own plan-declared provider reservation at the current metal frame and the
  matching exact direct-parent join; it contains no synthetic `deploy-vm` operation or VM resource.
- One demo call site prepares, runs, journals, and settles the Direct provider backend under its exact budget
  and lifecycle bracket before cluster work.
- Action-local ready settlement records Direct backend origin, generation, expected reservation outcome, and
  observation receipt, then registers the invocation-only pending package/service through Sprint 24.9; only the
  fixed later node reached after `Chain` acknowledges the producer gate may open it.
- The package enters only the interpretation-wide dependency registry. No raw host probe, pre-existing socket, generic
  resource key, or caller-supplied readiness boolean substitutes for the settled reservation.
- This forward adopter writes the exact settled Direct reservation journal identity for Sprint 24.27. Direct
  reverse can terminalize only that journal reservation; physical stop/delete are `Unsupported`, and neither
  this sprint nor teardown may claim or fabricate backend release.

#### Validation

`CommandsSpec` covers exact Direct success, absence of VM operations, package production, failure unwind, the
journal identity/static reverse-input projection required by Sprint 24.27, and mismatch refusals; it does not
claim physical reverse release. The demo host-static gate must pass. The one-adoption/module/line budgets are
checked before implementation; overflow is split before this call site lands.

#### Remaining Work

The Direct reservation adopter and its static fixtures remain to be implemented.

### Sprint 24.13: Copy-source managed-share adoption [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: one copy-source share call-site adoption and no new named contract; at most 400 production
Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Insert the real writable durable copy-source share between the VM provider and container descent, with its
managed handle kept lexical for the immediately nested guest-alias action.

#### Deliverables

- VM/container topology includes the exact plan-declared `copySourceStep` between the settled VM provider and
  child descent; Direct topology has no share or alias step.
- One demo call site opens the fresh provider dependency, prepares the exact copy-source resource, provisions
  its share, journals ownership, and settles the backend observation before descent.
- The writable source is the canonical host durable root and its unchanged absolute guest target is the
  admitted selected-edge target; image, arguments, remove policy, socket, target, read-only flag, and config
  remain unchanged.
- The `ManagedProviderShareHandle` exists only inside this call site's lexical continuation. It is never placed
  in `CarriedResource`, either execution package, plan/config bytes, a journal payload, or a later node.
- The continuation remains open around Sprint 24.14's alias reconciliation inside this same copy-source action,
  then settles and closes before returning to `Chain` for selected container descent; failure unwinds the share
  and yields no reusable handle or receipt authority.

#### Validation

`CommandsSpec` covers exact ordering, source/target identity, route preservation, Direct-lane absence, unwind,
and source-shape/non-escape guards. The demo host-static gate must pass. The one-adoption/module/line budgets are
checked before implementation; overflow is split rather than moving a handle across a node.

#### Remaining Work

The copy-source share adopter and lexical continuation remain to be implemented.

### Sprint 24.14: Lexically nested guest-alias adoption [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: one guest-alias call-site adoption and no new named contract; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/operations/demo_runbook.md`

#### Objective

Reconcile the VM guest alias while the exact provider and share handles are simultaneously live in the one
copy-source action.

#### Deliverables

- The sole demo alias call is inserted inside Sprint 24.13's managed-share continuation, so the freshly opened
  provider handle and exact share handle coexist lexically in the same action.
- `reconcileNodeGuestAlias` receives the exact plan-declared provider, share, alias, and target identity; it
  cannot reconstruct either handle from `CarriedResource`, a receipt, or a later execution node.
- Alias settlement completes inside the share continuation before that action returns; only then may `Chain`
  continue to selected container descent. No managed share handle remains open across the later descent node.
- Direct topology proves the alias action absent, and VM topology refuses missing share settlement, wrong
  provider origin, wrong durable source/target, replay, or a closed provider/share bracket.
- The existing partial alias/projector work remains mutable and does not make this sprint Done; no compatibility
  export, demo-local handle constructor, or cross-node handle carrier is permitted.

#### Validation

`CommandsSpec` covers lexical nesting, ordering, the settled journal transition/static reverse input required by
Sprint 24.27, Direct absence, mismatch refusal, and non-escape source guards; reverse adoption itself remains
24.27. The demo host-static gate must pass. The one-adoption/module/line budgets are checked before the call-site
work is completed; overflow is split without separating share from alias.

#### Remaining Work

The lower alias seam exists. Exact nesting inside the not-yet-adopted copy-source action, complete static
coverage, and warning-clean integration remain open.

### Sprint 24.15: Canonical provider-package wire vocabulary [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/LifecycleDependencySpec.hs`
**Production modules**: `HostBootstrap.Handoff`, `HostBootstrap.Handoff.Protocol`,
`HostBootstrap.Lifecycle.Dependency.Internal` (3; cap 3)
**Sprint budget**: no new named contract and no call-site adoption; at most 400 production Haskell lines. Split
before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Define the canonical provider-package commitment and reprobe request/response bytes carried by the existing
authenticated handoff protocol, without encoding a closure or runtime witness.

#### Deliverables

- Closed protocol tags encode the provider domain, exact canonical package commitments, bounded request nonce,
  observation result, refusal reason, and expiry; unknown tags and noncanonical encodings fail closed.
- Wire bytes never encode a closure, backend command, `ManagedProviderHandle`, `ManagedProviderShareHandle`,
  `RunningProviderDependency`, `ClusterReadiness`, journal writer, receipt authority, or reusable secret.
- No live-service closure ever enters the package or encoder. A receiver can construct only the hidden bounded
  client route supplied by Sprints 24.17–24.18 after authenticated admission, never deserialize executable code.
- Request and response bytes bind the Handoff route, plan, scope, resource, frame, backend origin, generation,
  journal/ready commitments, request nonce, and Process invocation lifetime.
- Canonical round trips preserve exactly the committed fields; wrong domain, duplicate fields, trailing bytes,
  oversized input, changed binding, replayed nonce, or expired lifetime is an explicit protocol refusal.

#### Validation

`HandoffSpec` and `LifecycleDependencySpec` cover canonical golden bytes, round trips, all malformed or
forbidden cases, and a source guard excluding witness serialization. The core host-static gate must pass. The
module and 400-line budgets are checked before implementation; any new type or adoption is split out.

#### Remaining Work

The closed wire vocabulary, canonical codec, and negative fixtures remain to be implemented.

### Sprint 24.16: Caller-free provider reprobe service kernel [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Protocol.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Production modules**: `HostBootstrap.Handoff`, `HostBootstrap.Handoff.Protocol`,
`HostBootstrap.Handoff.Relay` (3; cap 3)
**Sprint budget**: no new named contract and no call-site adoption; at most 400 production Haskell lines. Split
before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Define the caller-free provider reprobe service kernel for the root or parent that owns the real Incus or Direct
backend; installation in the future Process bracket belongs to Sprint 24.17.

#### Deliverables

- A caller-free kernel accepts an already-authenticated bounded request plus a lexical live provider probe and
  returns a canonical response; this sprint installs no service and imports no future `Handoff.Process`.
- Each request is authenticated against the exact admitted handoff binding, route, invocation generation,
  package commitment, request nonce, and the journaled provision-plus-ready evidence before backend access.
- The owning root/parent performs only the real supported Incus or Direct backend probe locally; Lima and WSL
  live probes remain unsupported, and a child is never asked to
  discover host tools or treat channel reachability as provider readiness.
- A response is canonical, nonce-bound, origin/generation-bound, single-request evidence only. It conveys no
  handle, reusable probe authority, HMAC key, journal writer, or capability that survives the duplex bracket.
- Wrong route, commitment, ownership evidence, generation, nonce, backend identity, replay, timeout, or closed
  provider produces an authenticated refusal and no fresh dependency.

#### Validation

`HandoffSpec` and `RecursiveLifecycleSpec` use real local duplex fixtures and fake backend observations to cover live
success, all binding/lifetime/refusal cases, and non-export of backend authority. The core host-static gate must
pass. The one-adoption/module/line budgets are checked before implementation; overflow is split.

#### Remaining Work

The caller-free bounded request kernel and refusal fixtures remain open; installation belongs to Sprint 24.17.

### Sprint 24.17: Keyless multi-hop reprobe relay and child client [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Receiver.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Production modules**: `HostBootstrap.Handoff.Relay`, `HostBootstrap.Handoff.Receiver`,
`HostBootstrap.Handoff.Process` (3; cap 3)
**Sprint budget**: one Process-owned service installation and no new named contract; at most 400 production
Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Relay exact reprobe frames across nested live Process duplexes without distributing root authentication keys or
allowing an intermediate frame to reinterpret them.

#### Deliverables

- One internal installation places Sprint 24.16's kernel inside the live provider and `Handoff.Process` brackets
  and exposes a bracket-scoped duplex endpoint; closing either bracket irreversibly closes service and clients.
- An intermediate parent validates only its immediate transport framing and relays the exact canonical payload
  bytes toward the owning root/parent and back; it receives no root key, handle, or authority to mint a result.
- The child-side hidden client binds each fresh nonce to the admitted immediate-edge route and invocation
  lifetime, accepts exactly one matching authenticated response, and exposes only package-private probe output.
- Relay depth, frame size, deadline, outstanding request count, and response count are bounded; cross-route
  substitution, reflection, duplicate response, late response, truncation, or unknown tag fails closed.
- No alternate socket, environment variable, argv term, config field, durable file, generic carrier, or
  caller-supplied executable can become a reprobe channel or long-lived authority.

#### Validation

`HandoffSpec` and `RecursiveLifecycleSpec` cover one-hop and multi-hop success, keylessness, bounds, close
races, replay/reflection/substitution refusal, and absence of alternate channels. The core host-static gate must
pass. The module and 400-line budgets are checked before implementation; any new type or adoption is split.

#### Remaining Work

The bracket-scoped endpoint, keyless relay, hidden client, and multi-hop fixtures remain to be implemented.

### Sprint 24.18: Authenticated child package admission [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Process.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`, `core/hostbootstrap-core/test/ChainSpec.hs`
**Production modules**: `HostBootstrap.Handoff.Process`, `HostBootstrap.Command.Child`,
`HostBootstrap.Chain` (3; cap 3)
**Sprint budget**: one authenticated child-descent call-site adoption and no new named contract; at most 400
production Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Admit and seed the canonical provider package only after authenticated child descent; fresh parent-serviced
provider opening remains inside Sprint 24.23's cluster action.

#### Deliverables

- One child-descent call site accepts provider-package bytes only after Phase 17 authenticates the child plan,
  canonical config, immediate selected topology edge, `HandoffBindingInput`, invocation, and live Process route.
- Admission verifies the exact plan/resource/frame/provider commitments and installs a package with the Sprint
  24.17 hidden client into the interpretation-wide registry shared by all child `StepRuntime`s; no running
  witness is seeded.
- This adoption stops after canonical package admission and client attachment. It never calls the provider
  opener or produces a `RunningProviderDependency`; Sprint 24.23 owns that fresh lexical refinement.
- The child cannot select a host executable, backend command, probe route, or SelfRef, and no Managed/Running/
  Readiness witness, key, or raw channel enters plan bytes, config, environment, argv, or a carrier.
- Wrong ancestry edge, child-local plan/config digest, package commitment, binding, nonce, generation, replay,
  timeout, or closed duplex refuses before cluster preparation and unwinds the descent bracket.

#### Validation

`RecursiveLifecycleSpec` and `ChainSpec` use real local process-boundary fixtures to cover authenticated admission,
shared child registry visibility, no witness seeding, multi-hop relay, and every mismatch/lifetime refusal. The
core host-static gate must pass. The one-adoption/module/line budgets are checked before implementation; any
overflow is split.

#### Remaining Work

The authenticated child admission, registry seed, and process fixtures remain open; refinement is deferred.

### Sprint 24.19: Exact rendered cluster config and loopback set [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/ClusterConfig.hs`,
`demo/src/HostBootstrapDemo/Config.hs`, `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/test/ClusterConfigSpec.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.ClusterConfig`, `HostBootstrapDemo.Config`,
`HostBootstrapDemo.Commands` (3; cap 3)
**Sprint budget**: no new named contract and no lifecycle call-site adoption; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/network_reachability.md`,
`documents/operations/demo_runbook.md`

#### Objective

Render the exact canonical Kind/nvkind configuration and loopback publication set from digest-matched plan
metadata before any cluster backend is selected.

#### Deliverables

- A pure demo renderer consumes only Sprint 24.7's exact cluster slice and finalized config projection, verifies
  the retained config digest, and emits canonical bytes plus their digest and deterministic state/config paths.
- The closed driver value selects only Kind or nvkind rendering; driver-specific node, mount, accelerator,
  network, and kubeconfig fields are total and unknown driver text is unrepresentable.
- The loopback set is derived from the exact plan-owned published ports and binds only local addresses; duplicate,
  wildcard, out-of-range, undeclared, or cross-scope ports fail before filesystem or backend work.
- The VM/container render preserves the selected writable durable target and cluster topology, while Direct
  rendering contains no VM/share/alias fiction; both retain the same exact cluster resource identity.
- Canonical output is stable under map ordering and rejects lexical path escape, unknown fields, noncanonical
  bytes, digest disagreement, and independently supplied cluster/profile/root terms. Symlink and file-identity
  checks are intentionally deferred to the later IO backend under its lock.

#### Validation

`ClusterConfigSpec` and `CommandsSpec` cover Kind/nvkind golden output, both topologies, loopback isolation,
canonical stability, digest agreement, and all refusal cases. The demo host-static gate must pass. The
module/400-line budgets are checked before implementation; any type, adoption, fourth module, or overflow is
split.

#### Remaining Work

The pure renderer, finalized-codec projection, golden fixtures, and loopback checks remain open.

### Sprint 24.20: Plan-owned cluster driver/config package [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`demo/src/HostBootstrapDemo/ClusterConfig.hs`, `core/hostbootstrap-core/test/ClusterReconcileSpec.hs`,
`demo/test/ClusterConfigSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Cluster.Lifecycle`, `HostBootstrap.Cluster.Reconcile`,
`HostBootstrapDemo.ClusterConfig` (3; cap 3)
**Sprint budget**: one new named type, `PlanOwnedClusterConfig`, and no call-site adoption; at most 400
production Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/generic_project_model.md`

#### Objective

Bind the exact closed driver, canonical rendered config, mappings, and plan-owned cluster package into the one
input accepted by cluster preparation.

#### Deliverables

- Opaque `PlanOwnedClusterConfig` is the sole named type and binds the exact existing `PlanOwnedCluster`, closed
  Kind/nvkind driver, canonical bytes/digest, config/state paths, loopback set, node mappings, and workload slice.
- `withPlanOwnedCluster` first constructs the existing base `PlanOwnedCluster` from the planned provider
  resource and admitted provider→cluster edge, without runtime dependency or config recursion; a separate
  hidden binder then matches Sprint 24.19 output and produces the wrapper. Runtime dependency is consumed only
  when preparing the reconcile.
- Cluster preparation no longer hardcodes `Kind` or resolves a driver independently; it consumes the completed
  wrapper and exposes no raw path, driver text, or alternate config argument.
- `PreparedClusterReconcile` retains that exact package so every reconcile, cordon, readiness, and cleanup
  operation observes one driver, bytes digest, path set, mapping set, and ownership identity.
- Wrong driver/config pairing, changed bytes or path, sibling provider, stale generation, wildcard publication,
  mismatched slice, or independently supplied term refuses before backend discovery or mutation.

#### Validation

`ClusterReconcileSpec`, `ClusterConfigSpec`, and compile-fail fixtures cover sole construction, exact retention,
both drivers, all mismatches, and removal of the hardcoded Kind path. Core and demo host-static gates must pass.
The sole-type/module/line budgets are checked before implementation; overflow is split.

#### Remaining Work

The opaque package, exact constructor, and cluster-preparation integration remain open.

### Sprint 24.21: Closed Kind/nvkind cluster backend [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/internal/cluster-backend/HostBootstrap/Cluster/Backend/Internal.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Cluster.Backend`, `HostBootstrap.Cluster.Backend.Internal` (2; cap 3)
**Sprint budget**: no new named contract and no project call-site adoption; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/operations/demo_runbook.md`

#### Objective

Resolve the plan-owned Kind or nvkind driver into one closed backend that retains every exact host tool and
config term needed for reconcile, cordon, readiness, and cleanup.

#### Deliverables

- Backend discovery consumes only `PlanOwnedClusterConfig` and resolves exactly the closed Kind or nvkind
  branch; caller-selected driver names, executables, paths, and argument lists are absent.
- The strong backend retains the exact Kind/nvkind, Docker, Kubectl, Helm, Flock, Python, and supervisor tool
  identities required by its branch, plus the canonical config digest and ownership identity.
- Every subprocess invocation is generated internally from the retained branch and exact package; nvkind never
  falls back to Kind and Kind never silently invokes nvkind.
- Discovery and reprobe reject missing/wrong tools, changed executable identity, changed config bytes/digest,
  state-root escape, backend replacement, unsupported substrate, and ambiguous installation before mutation.
- Existing reconcile, applied-cordon, readiness, and cleanup calls accept only the resolved closed backend and
  retain their lock, fresh-observation, generation, and exact-identity guarantees.

#### Validation

`ClusterBackendSpec` and compile-fail fixtures cover both branches, exact tool retention and invocations,
replacement/mismatch refusal, no fallback, and all lifecycle operations. The core host-static gate must pass.
The module and 400-line budgets are checked before implementation; any new type or adoption is split.

#### Remaining Work

The closed branch discovery, nvkind support, retained tools, and negative fixtures remain open.

### Sprint 24.22: Cluster-domain readiness recovery [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/LifecycleDependencySpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Cluster.Backend`, `HostBootstrap.Cluster.Reconcile`,
`HostBootstrap.Lifecycle.Dependency.Internal` (3; cap 3)
**Sprint budget**: no new named contract and no project call-site adoption; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Produce and later open a cluster-domain runtime package so chart work receives a freshly reprobed lexical
`ClusterReadiness`, never a carried readiness witness.

#### Deliverables

- Only exact action-local reconcile settlement followed by applied cordon and ready settlement may register a
  pending cluster-domain package; its commitments bind the plan-owned cluster config, driver/backend origin,
  generation, expected ownership/cordon/ready outcomes, route, and expiry without claiming a committed row.
- `Cluster.Backend` registers the bounded fresh-readiness closure in an invocation-owned opaque live-service
  registry separate from the canonical package registry. The closure captures the strong backend/readiness
  source; no `ClusterReadiness` witness is stored in either registry.
- The hidden cluster-domain opener is available only to the fixed successor node after `Chain` acknowledges the
  producer gate. It verifies every action-local commitment, executes a fresh backend readiness observation, and
  asks `Cluster.Reconcile` to reconstruct `ClusterReadiness` only inside a lexical continuation; it introduces
  no separate reconcile/cordon/ready durable rows or journal-promotion API.
- Canonical package presence or action-local ready settlement alone is insufficient. Wrong domain/config/driver,
  changed cluster identity/generation, missing ownership or cordon evidence, replay, stale probe, or failed
  readiness yields no witness.
- The package, wire, and canonical registry cannot contain or expose `ClusterReadiness`, an applied-cordon capability, managed
  backend handle, raw probe, journal writer, reusable receipt, or a value escaping the lexical continuation.

#### Validation

`ClusterBackendSpec`, `LifecycleDependencySpec`, and compile-fail fixtures cover exact production, fresh open,
every mismatch/staleness case, non-escape, and absence of forbidden witnesses. The core host-static gate must
pass. The module and 400-line budgets are checked first; any new type or adoption is split.

#### Remaining Work

The cluster-domain producer, fresh opener, readiness refinement, and static refusal coverage remain open.

### Sprint 24.23: Exact cluster reconcile, cordon, and readiness adoption [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: one cluster lifecycle call-site adoption and no new named contract; at most 400 production
Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Adopt one exact demo cluster call site from fresh provider recovery through reconcile, applied cordon, readiness,
and cluster-package production.

#### Deliverables

- The call site consumes the exact Sprint 24.7 slice, Sprint 24.20 plan-owned cluster config, Sprint 24.21
  backend, and a provider package from the interpretation registry; it accepts no independent driver/config,
  provider handle, readiness flag, or cluster name.
- It is the sole child-side opener of the admitted provider package: before reindexing it authenticates the
  exact parent→child `PlanDigestBinding` and selected immediate topology edge; after fixed-node acknowledged
  sequencing it requests a parent-serviced fresh probe, refines a lexical `RunningProviderDependency`, then
  prepares and runs
  the exact cluster reconcile, journals
  ownership, settles the observed cluster, applies the exact cordon, and only then settles fresh readiness.
- Within that lexical readiness continuation it invokes Sprint 24.22's producer, registers the invocation-owned
  live readiness service separately, and stores only a pending cluster-domain package in the canonical
  registry. Only the fixed chart successor reached after `Chain` acknowledges the producer gate may open it;
  failure, retry, or a fresh invocation destroys both registries.
- Failure or replacement at any stage produces no readiness/package and unwinds only journal-proven owned work;
  wrong provider/cluster/frame/config/driver/budget/generation or out-of-order cordon is refused before use.
- Direct and VM/container lanes reach this same call-site shape through their distinct admitted provider routes;
  no compatibility export, demo-local cluster mutation, hardcoded Kind, or raw tool call is permitted.

#### Validation

`CommandsSpec` covers both lanes, exact order, package carriage, failure unwind, every mismatch, and absence of
raw mutations. The demo host-static gate must pass. The one-adoption/module/line budgets are checked before
implementation; overflow is split before the call site lands.

#### Remaining Work

The exact cluster adopter, cluster-package carry, and static integration fixtures remain open.

### Sprint 24.24: Planned chart/workload resource [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Step`, `HostBootstrap.Lifecycle.Plan` (2; cap 3)
**Sprint budget**: one new named type, `ChartWorkloadResource`, and no call-site adoption; at most 400 production
Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Represent the demo chart deployment as one exact plan-owned workload resource rather than a raw Helm mutation.

#### Deliverables

- Opaque `ChartWorkloadResource` is the sole named type and is projected only from a finalized chart/workload
  step at its exact cluster frame and operation key; callers cannot construct its resource key or frame.
- Its stable plan bytes bind chart artifact digest, release, namespace, canonical values digest, image identity,
  canonical workload/partition declaration key and digest, service role, cluster resource, and exact effects;
  they do not contain the later generative `PlannedWorkloadSet` or `BudgetPartition` values.
- Plan admission requires exactly one matching cluster parent and declared workload/partition identity, and
  refuses missing, duplicate, sibling, ancestor, wrong-frame, wrong-scope, or cross-plan resources before
  execution. Sprint 24.25 later matches the generative Sprint 24.7 outputs to those retained declarations.
- The resource's operation participates in the existing lifecycle session so `Chain` supplies its own exact
  `PreparedGate`; no demo code mints, stores, or accepts a gate independently.
- Reverse identity is derived from the same planned release/namespace/resource fields and cannot select another
  release, delete a shared namespace, or infer ownership from a live Helm listing.

#### Validation

`ProjectPlanSpec` and compile-fail fixtures cover stable bytes, exact parent/partition admission, gate ownership,
reverse identity, hidden construction, and every mismatch. The core host-static gate must pass. The
sole-type/module/line budgets are checked before implementation; overflow is split.

#### Remaining Work

The closed resource, plan encoding/admission, and exact reverse identity remain open.

### Sprint 24.25: Prepared and settled chart/workload backend [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Workload.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/ClusterWorkloadSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Cluster.Workload`, `HostBootstrap.Cluster.Backend` (2; cap 3; Cabal
metadata is not a production module)
**Sprint budget**: one new named type, `PreparedChartWorkload`, and no call-site adoption; at most 400 production
Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Prepare, run, observe, journal, and settle the exact chart resource behind readiness and activation evidence,
without adding a parallel result type.

#### Deliverables

- Cabal-hidden `PreparedChartWorkload` is the sole named type and retains the exact planned resource,
  `PreparedGate`, freshly opened lexical `ClusterReadiness`, `VerifiedRuntimeRoleActivation`, closed backend,
  canonical values/image digests, and operation attempt/version.
- Its only preparer checks that readiness, activation, resource, the already-produced Sprint 24.7
  `PlannedWorkloadSet`/`BudgetPartition`, cluster identity, plan, scope, frame, gate, and declared effects all
  match their retained declarations before Helm or Kubernetes access.
- `Cluster.Backend` renders the one lock-held Helm/Kubectl transaction internally from retained tools and exact
  package fields; callers provide no executable, raw arguments, release/namespace, values path, or readiness flag.
- The prepared value runs and settles inside its hidden eliminator, returning the existing generic
  `ReconcileResult`/`ChangeView`; replacement, stale readiness/activation/gate, digest drift, foreign release,
  partial apply, timeout, or unready workload refuses, and no second named result is introduced.
- The same two modules add a no-new-type reverse cleanup eliminator. It consumes only the planned
  release/namespace/resource identity plus exact journal-owned forward settlement, renders lock-held Helm
  uninstall/absence observation internally, and returns the existing generic result; it needs no forward
  `PreparedGate`, `ClusterReadiness`, activation witness, raw process result, or caller-supplied command.

#### Validation

`ClusterWorkloadSpec` and compile-fail fixtures cover sole forward preparation, exact apply and reverse-cleanup
rendering, Changed/Unchanged/absence settlement, journal/version binding, all stale/foreign/failure cases, and
no second result type. The core host-static gate must pass. The sole-type/module/line budgets are checked before
implementation; if forward plus reverse would exceed 400 lines, cleanup is split into a prior bounded sprint.

#### Remaining Work

The hidden workload module/type, closed forward and reverse transactions, settlement, and negative fixtures
remain open.

### Sprint 24.26: Readiness-gated chart/workload adoption [Planned]

**Status**: Planned
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands`, `HostBootstrap.RoleLifecycle` (2; cap 3)
**Sprint budget**: one chart/workload call-site adoption and no new named contract; at most 400 production
Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Replace the legacy demo `deployChart` mutation with the exact planned, readiness-gated, activation-authorized
workload transaction.

#### Deliverables

- The fixed chart successor opens Sprint 24.22's cluster-domain package only after acknowledged producer-node
  sequencing, fresh-reprobes the exact cluster, and keeps `ClusterReadiness` lexical for this one action.
- Phase 22's exact `VerifiedRuntimeRoleActivation`, the action's own `PreparedGate`, and Sprint 24.24's planned
  resource are joined with that readiness; missing or mismatched evidence refuses before backend work.
- One demo call site prepares, runs, observes, and settles Sprint 24.25's transaction, then returns its generic
  `ChangeView` through the existing `Chain` outcome/journal path.
- The legacy `deployChart` call and independent `clusterProfileOf`/`containerPlan`/filesystem/config terms are
  removed; no Phase 22 sprint is redefined as owning this demo chart mutation.
- This adoption attaches the exact no-new-type cleanup projection from Sprint 24.25 to the planned chart node.
  Reverse later consumes only that planned identity and journal-owned settlement, precedes cluster cleanup, and
  cannot remove a foreign release, shared namespace, or unowned workload.

#### Validation

`CommandsSpec` covers readiness/activation/gate ordering, Changed/Unchanged, reverse order, both demo lanes, all
mismatches, and absence of `deployChart`. Core and demo host-static gates must pass. The one-adoption/module/
line budgets are checked before implementation; overflow is split before the call site lands.

#### Remaining Work

The exact chart adopter, legacy-call removal, reverse projection, and static fixtures remain open.

### Sprint 24.27: Exact worked-demo reverse command adoption [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/ChainSpec.hs`,
`demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrap.Command`, `HostBootstrap.Chain`,
`HostBootstrapDemo.Commands` (3; cap 3)
**Sprint budget**: one demo reverse-command call-site adoption and no new named contract; at most 400 production
Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/operations/demo_runbook.md`

#### Objective

Adopt the exact demo `down`/`destroy` consumer from retained teardown plan/frame/journal authority, without
pretending `TeardownAction` receives a forward `StepExecution` package.

#### Deliverables

- One demo reverse-command call site consumes Phase 17's exact `TeardownPlan`, current frame, command intent,
  cursor, and committed journal ownership; it never accepts or reconstructs `PlanExecutionPackage`.
- Child-first reverse settles chart/workload removal, cluster cleanup, alias/share journal transitions, and VM
  provider stop/delete only through their exact planned resource identities and owned forward outcomes.
- Direct reverse terminalizes only its exact journaled reservation. Physical Direct stop/delete remain
  `Unsupported`; neither demo nor core reports a fabricated backend release.
- `down` preserves the canonical durable root and reversible provider state required by its contract; root-only
  `destroy` removes only destruction-authorized owned state and preserves the exact durable sentinel required by
  the matrix.
- Missing/foreign/stale ownership, wrong plan/frame/generation/cursor, out-of-order parent cleanup, retry, or an
  unsupported backend action fails explicitly and cannot fall back to raw demo cleanup commands.

#### Validation

`ChainSpec` and `CommandsSpec` cover VM and Direct reverse projections, child-first order, down/destroy
distinction, Direct `Unsupported`, retries, all ownership mismatches, and absence of forward-package use. Core
and demo host-static gates must pass. The one-adoption/module/line budgets are checked before implementation;
overflow is split.

#### Remaining Work

The exact reverse-command adopter and its static VM/Direct/down/destroy fixtures remain open.

### Sprint 24.28: Exact demo forward-child projector [Active]

**Status**: Active
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/app/Main.hs`,
`demo/test/CommandsSpec.hs`, `demo/test/compile-fail/`
**Production modules**: `HostBootstrapDemo.Commands`, `Main` (2; cap 3)
**Sprint budget**: one demo projector call-site adoption and no new named contract; the currently frozen partial
patch is +205 governed significant lines over its 2,542-line baseline and the completed sprint must remain
within 400 production Haskell lines. Split before implementation if that cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/composition_methodology.md`, `documents/architecture/generic_project_model.md`,
`documents/architecture/hostbootstrap_core_library.md`, `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Finish the deliberately frozen partial demo projector only after Sprints 24.4–24.27 make every projected
provider, cluster, chart, guest, and reverse consumer exact.

#### Deliverables

- The frozen projector hunk set is the `demoForwardChildPlan` export/import support, chain-at-context/payload
  helpers, the contiguous `demoForwardChildPlan` through `validateDirectParentLift` region, and `Main`'s
  `addForwardChildPlan` installation. `Main` remains at recorded whole-file hash
  `7956057055b30b02f534eaa147dbef0d01756445e0d56148ecc259bbb0a794cb`; the mutable `Commands.hs` whole-file
  hash is deliberately not a gate because prerequisite sprints must edit that module.
- The recorded projector-attributable patch is +205 governed significant production lines over its frozen
  2,542-line pre-projector baseline. Later prerequisite deltas are measured separately and excluded when that
  named hunk set is remeasured; the partial work does not make the sprint Done or bypass the prerequisite gate.
- The completed projector proves only the retained ancestry prefix and unique immediate parent→child edge, not
  whole child-plan/descent equality. VM/VM-container ancestry edges remain exact; child-local graphs may differ
  below the child.
- The selected Direct container edge alone may rebase one writable durable source to its unchanged absolute
  target (source=target in the child plan) while preserving image, arguments, remove, socket, target, read-only,
  and config delivery. For `ViaContainer`, canonical payload equals `cdPayload`; root→VM has no ConfigDelivery.
- The exact package retains topology evidence, `LiftContext`/invocation route, canonical authenticated protocol
  payload, and `HandoffBindingInput`, never an actual `HandoffBinding`, independently selectable executable, or
  `SelfRef`; it derives a ConfigDelivery-stripped Process route and adds no `Cluster.Lifecycle` compatibility export.

#### Validation

After Sprints 24.4–24.27, `CommandsSpec`, `Main` source guards, and compile-fail fixtures cover both scopes and
topologies, exact immediate-edge semantics, the sole Direct rebase, payload cases, hidden package fields, and no
compatibility export. The demo host-static gate must pass. Before work resumes, `Main`'s hash and the named
projector hunk manifest/+205 attribution must still match after excluding prerequisite deltas; any projector
drift is investigated rather than absorbed.

#### Remaining Work

The partial +205 patch remains deliberately frozen. It may resume only after every exact consumer prerequisite
through Sprint 24.27 is implemented and green; its source is not rolled back or exported for compatibility.

### Sprint 24.29: Authenticated derived-image adoption [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `demo/docker/Dockerfile`,
`core/hostbootstrap-core/test/CommandSpec.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrap.Command`, `HostBootstrapDemo.Commands` (2 Haskell modules; cap 3;
`demo/docker/Dockerfile` is a build input)
**Sprint budget**: one authenticated image-build call-site adoption and no new named contract; at most 400
production Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`,
`documents/operations/demo_runbook.md`

#### Objective

Build the demo image only through the authenticated project-owned build protocol after the exact plan/projector
and published-base provenance boundaries close.

#### Deliverables

- One demo build call site consumes the exact project plan, authenticated source/build identity, retained
  published-base repository digest, and canonical Dockerfile/context projection; callers supply no raw context
  root or executable.
- The build protocol binds request, progress, completion, output image identity, and acknowledgement to the same
  invocation/build nonce and refuses replay, cross-project substitution, or an unacknowledged prior result.
- Every derived build retains `--pull`, uses the within-run repository digest resolved in Sprint 24.4, and runs
  the image's warning-clean `check-code`; a stale local base cannot satisfy the result.
- Completion is accepted only for the expected content-addressed image and exact source/Dockerfile digest;
  timeout, daemon replacement, malformed output, wrong architecture, or partial image is a typed failure.
- No environment/argv/config/durable file transports build authority, and no legacy raw image-build wrapper or
  compatibility route remains reachable from the demo command tree.

#### Validation

`CommandSpec` and `CommandsSpec` cover authenticated request/completion, digest identity, `--pull`, replay and
replacement refusal, warning-clean stage selection, and absence of raw routes. Core and demo host-static gates
must pass. The one-adoption/module/line budgets are checked before implementation; overflow is split.

#### Remaining Work

The authenticated image call site and static protocol/provenance fixtures remain open.

### Sprint 24.30: Recursive lifecycle worked-demo acceptance [Planned]

**Status**: Planned
**Implementation**: no production change; evidence in this phase and
`documents/operations/demo_runbook.md`
**Production modules**: none (0; cap 3)
**Sprint budget**: no new named contract, no call-site adoption, and zero production Haskell lines; this is the
separate live-substrate confirmation of the preceding host-static changes.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/engineering/testing.md`, `documents/architecture/composition_methodology.md`

#### Objective

Confirm the proof-complete recursive lifecycle command through the real Production and Harness demo consumer.

#### Deliverables

- Acceptance starts only after Sprints 24.3–24.29 and the demo static gate are green; it introduces no fallback
  interpreter, authority injector, compatibility export, test-only lifecycle route, or production code.
- Fresh Production `project up` traverses every declared frame through Phase 17's root-coordinated storeless
  frame executor and reaches exact provider, cluster, workload, service readiness, and read-only endpoint
  assertions.
- Production `project down` and root-only `project destroy` drive Sprint 24.27's shared child-first reverse
  route, report Direct physical release as `Unsupported`, remove only owned state, and preserve the canonical
  durable-root sentinel required by each command contract.
- `hostbootstrap run -- test run all` reports exactly `10/10 passed`, including each same-run write → destroy →
  fresh up → read cycle and terminal Harness close under the retained Harness plan/run/config/durable root.
- Dated evidence records host/OS/architecture, tool versions, published base and derived image identities,
  durations, exact command results, `10/10` report, and audited provider/cluster/workload/durable-root end state.

#### Validation

On fresh linux-cpu, pass `cabal build all` and `cabal test all --ghc-options=-Werror` from `demo/`, then run
`hostbootstrap run -- project up`, `hostbootstrap run -- project down`,
`hostbootstrap run -- project destroy`, and `hostbootstrap run -- test run all`. Record evidence only after
every command exits as specified, the report is exactly `10/10 passed`, owned infrastructure is absent or
explicitly `Unsupported` as contracted, and durable-root assertions pass. Phase 17 retains only its host-static
process gate; Phase 19 retains its separately owned Harness/interruption gate.

#### Remaining Work

The complete fresh linux-cpu Production sequence, Harness `10/10` run, end-state audit, and dated evidence.

## Remaining Work

Sprint 24.3 closes the exact same-run durable assertion, and Sprint 24.4 closes plan/profile/root assembly and
published artifact provenance. Sprints 24.5–24.7 author provider resources, seed neutral exact-plan execution,
and derive exact slices. Sprints 24.8–24.18 add invocation-owned canonical/live dependency registries,
provider settlement/recovery, VM and Direct adopters, lexical share/alias settlement, and authenticated
parent-serviced reprobe transport. Sprints 24.19–24.23 render and bind exact Kind/nvkind config, close backend
selection, recover cluster readiness, and adopt cluster reconcile/cordon/readiness. Sprints 24.24–24.27 plan,
settle, adopt, and reverse the chart/workload and full demo lifecycle. The frozen partial projector resumes in
Sprint 24.28, the derived image adopts the authenticated build route in Sprint 24.29, and only Sprint 24.30 owns
live Production and Harness evidence.

No sprint transports a Managed/Running/Readiness witness, handle, authentication key, executable selector, or
raw probe in canonical bytes or a generic resource carrier. The two invocation-owned registries have separate
roles: canonical packages contain commitments and bounded client routes; opaque live services contain backend
closures and die on failure, retry, Process close, or fresh invocation. Share and alias settle lexically inside
one copy-source action before `Chain` continues. Direct reverse terminalizes its journal reservation and reports
physical stop/delete `Unsupported`. Phase 22 remains only the lower activation/`service run` dependency and does
not own the demo chart call site.

## Documentation Requirements

**Architecture docs to create/update:**

- `documents/architecture/network_reachability.md` — the demo's exact loopback-safe Kind/nvkind rendering.
- `documents/architecture/lifecycle_state_model.md` — the canonical/live dependency registries and fresh
  provider/cluster refinements.
- `documents/architecture/composition_methodology.md` — the exact provider, cluster, workload, reverse, and
  projector composition order.

**Engineering docs to create/update:**

- `documents/engineering/testing.md` — what the long gate covers that the static suites cannot.
- `documents/engineering/accelerator_daemon.md` — the per-substrate placement.
- `documents/engineering/build_release.md` — published-base provenance and authenticated derived-image build.

**Cross-references to add:**

- `documents/operations/demo_runbook.md` — the operator sequence, duration envelope, exact `Unsupported` Direct
  reverse boundary, and disposable-host requirement.
