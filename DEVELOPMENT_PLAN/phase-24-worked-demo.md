# Phase 24 — The worked demo

**Status**: Done
**Depends on**: Phase 16 (provider, cluster, and guest lifecycle foundations), Phase 17 (proof-complete
recursive lifecycle command), Phase 22 (service-runtime activation and `service run` semantics), Phase 23
(base image publication and the opportunistic warm store)
**Substrates**: linux-cpu
**Gate**: `cabal build all` and `cabal test hostbootstrap-demo-test --ghc-options=-Werror` from `demo/`, the
core host-static gate from `core/`, plus live
`hostbootstrap run -- project up`, `hostbootstrap run -- project down`,
`hostbootstrap run -- project destroy`, and `hostbootstrap run -- test run all` reporting `10/10 passed`
inside the universal `linux-cpu` realization on any supported outer host

> **Purpose**: Be the real consumer that proves the library composes — a complete application with its own
> plan, config vocabulary, test component, and service variants.

## Phase Objective

Everything below this phase is a library. This phase is the consumer that exercises it end to end: a
scope-polymorphic plan instantiated separately for production and for each harness run, a web application with
a real cluster, an in-cluster registry backed by object storage, an accelerator daemon, and a five-case test
matrix generated from decoded configuration.

It is also where the universal-realization contract becomes live: the host-native binary must establish
native Linux, Lima/Colima, or WSL2 as appropriate and re-enter this same project in `linux-cpu`; a native
macOS or Windows execution of the commands is not equivalent. The container quality gate lives here because `fourmolu` and `hlint` run only inside the image's
own `check-code` — see [rationale.md](rationale.md). Sprints 24.30 and 24.41 are the worked-demo Production and
Harness live confirmations of the host-static recursive lifecycle command completed by Phase 17.

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
  test run's cluster and data root derive from its run identity while host ports are selected only by the
  runtime-owned exposure operation.
- The demo's chain runs on the core interpreter; there is no demo-local deploy interpreter.
- The pulled rolling base is consumed `FROM` the published tag, and the in-Dockerfile `check-code` stage runs
  the container gate.
- The decoded config, finalized plan, and generated test vocabulary remain one coherent demo-owned assembly;
  no hidden environment or command-line term changes its topology.
- Production and Harness Dhall contain stable application/Service ports only. There is no field, default,
  derived run hash, or numeric convention for a provider-/host-local port; service identity and internal target
  are the complete exposure intent available before effects.

#### Validation

`CommandsSpec` covers the plan shape, both scope instantiations, and the config vocabulary. `ConfigSpec` and a
source guard prove generated/example Dhall has no host-port field and no Haskell default or run-derived host
number feeds plan construction. The container gate runs on every image build.

#### Remaining Work

None. Completed 2026-08-23. Production and Harness config/plan projection retains only the four semantic
service/internal-target declarations; the three canonical Kind/nvkind files contain no host mapping, and
`ConfigSpec`, `ClusterConfigSpec`, and `CommandsSpec` guard the absence. The complete demo gate passed 142/142
under `--ghc-options=-Werror`.

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
  behind a service address on Linux, host-native through its exact runtime-resolved loopback exposure on Apple
  and Windows.
- The daemon's readiness is observed rather than slept for, and its launch uses the sealed invocation-shape
  boundary so a pre-readiness failure writes its cause somewhere readable.
- The application, registry, and accelerator variants expose only their finalized service interfaces; demo
  orchestration does not acquire lifecycle authority from an application callback.

#### Validation

`CommandsSpec` proves every provider-/host-local application, registry, object-store, web, accelerator, and
test client accepts only the resolved endpoint for its semantic service. The live `10/10` matrix exercises
those clients after the later exposure adopter closes.

#### Remaining Work

None. Completed 2026-08-23. MinIO initialization, registry rendering and image push, web exposure, and the
host-resident accelerator daemon select their semantic service only inside the lexical resolved-exposure
continuation. The focused `CommandsSpec` source and value checks passed 58/58 and the complete demo gate passed
142/142 under `--ghc-options=-Werror`.

### Sprint 24.3: The five-case test matrix from decoded config [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Config.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/ConfigSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`, `documents/operations/demo_runbook.md`

#### Objective

Generate the matrix from configuration, not from Haskell source.

#### Deliverables

- Five compiled cases: `pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence`, and
  `durable-readback`; two config variants; ten report-card rows.
- `durable-readback` writes through the web service and reads the same bytes back from the plan-owned durable
  root without receiving or invoking a lifecycle callback.
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
`CommandsSpec` covers the immediate stack assertions and the lifecycle-free declarative write/read shape.

#### Remaining Work

None. Completed 2026-08-22. The decoded two-variant registry expands the five compiled cases into ten stable
report-card rows, and all malformed, empty, and duplicate declarations refuse before acquisition.
`durable-readback` now performs a real POST/GET round trip through the live service's plan-owned durable root
while remaining structurally unable to invoke lifecycle commands. `ConfigSpec` and `CommandsSpec` cover the
matrix and write/read shape, and the complete demo suite passed 138/138 with `--ghc-options=-Werror`.

### Sprint 24.4: Plan-owned profile/root and service-target projection [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/src/HostBootstrapDemo/Config.hs`, `demo/test/CommandsSpec.hs`, `demo/test/ConfigSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands`, `HostBootstrapDemo.Config` (2; cap 3)
**Sprint budget**: no new named contract and no lifecycle call-site adoption; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Project both demo scopes' profile/root terms alongside their exact project plan and close the published-artifact
provenance boundary without adopting lifecycle consumers in this projection-only sprint.

#### Deliverables

- Production and Harness command assembly retain one exact `ProjectPlan`; `RunProfile` remains descriptive
  configuration and never becomes independent lifecycle authority.
- One digest-checked demo projection returns the exact plan's closed provider, cluster, workload, service, and
  assertion slices together with resources, semantic service targets, replica count, and canonical durable host root. Production
  projects preserved `.data`; Harness projects `.test_data/<run>` under its run bracket.
- The guest mount source and `PreserveOnReverse` resource derive from the same canonical durable-root projection;
  this sprint exposes the joined terms but does not adopt later lifecycle call sites.
- Every derived build passes `--pull`; the host-native lane resolves the published base tag to a repository
  digest and builds `FROM` that within-run reference without writing it to config or the repository.
- This sprint exposes assembly/provenance inputs for later packages only. Provider, cluster, chart, and teardown
  consumers remain owned by their numbered adoption sprints and receive no premature plan-owned claim here.

#### Validation

`CommandsSpec` and `ConfigSpec` cover both scope projections, durable-root identity, Harness isolation,
`--pull`, digest resolution, malformed-digest refusal, and published-tag inspection.
The demo host-static gate must pass. The named-module and 400-line budgets are checked before implementation;
overflow is split into a new sprint rather than expanding this one. Sprint 24.30 owns live confirmation.

#### Remaining Work

None. Completed 2026-08-23. The digest-checked projection returns the exact plan slices, canonical durable
root, and stable cluster-internal targets without a host-local number; both scope projections, base-digest
pinning, and absence guards pass in the complete 142-case demo gate under `--ghc-options=-Werror`.

### Sprint 24.5: Authored provider resources and exact direct-parent join [Done]

**Status**: Done
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

None. The closed `ProviderResourceDeclaration` vocabulary, validation, version-4 stable-plan encoding,
plan-derived current/immediate-child frame projection, VM/Direct demo declarations, and pure exact direct-parent
join are implemented. Core coverage includes duplicate/missing-child-descent refusal, current/child projection,
the stable snapshot golden, and hidden construction. Demo coverage includes both topology declarations and
zero/duplicate/ancestor/sibling/wrong-frame joins. The production change stayed within the three named modules
and below the 400-line cap. Validation on 2026-08-22: the core gate passed 2,387/2,387 and the demo gate passed
126/126 plus its nested core 2,387/2,387, all with `--ghc-options=-Werror`.

### Sprint 24.6: Neutral exact-plan execution package [Done]

**Status**: Done
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

None. Completed 2026-08-22. The nominal Cabal-private `PlanExecutionPackage`, dedicated `StepExecution` slot,
plan-owned neutral-term projection, sole reconciler producer, config-digest continuity, forward-prefix
retention, hidden-construction fixture, nominal-role inventory, and import-cycle/source-owner guards are
implemented. Together with Sprint 24.6a, the complete core host-static gate passed 2,389/2,389 under `-Werror`.

### Sprint 24.6a: Plan-indexed recursive frame carrier [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/FrameExecutor.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Production modules**: `HostBootstrap.Lifecycle.FrameExecutor`, `HostBootstrap.Command.Child` (2; cap 3)
**Sprint budget**: no new named type; at most 200 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Retain the admitted plan index across the storeless recursive frame executor so its local step can consume the
sole plan-produced execution package without weakening either nominal boundary.

#### Deliverables

- The forward frame opener receives the interpretation's plan-indexed resource carrier and fixes the executor's
  root-plan index to that same admitted plan; the existing generative compatibility opener remains for reverse.
- Recursive child execution retains the exact `PlannedStep` and calls only `Reconcile.stepExecutionFor`; it no
  longer constructs an execution descriptor or package from received text.
- Signed plan/frame/node/gate checks still occur before the action, and the plan-indexed carrier remains hidden.

#### Validation

Focused recursive-frame/source-shape tests plus the complete core host-static gate. Check the two-module,
zero-type, and 200-line budgets before marking Done.

#### Remaining Work

None. Completed 2026-08-22. The plan-indexed opener, retained exact `PlannedStep`, and sole
`Reconcile.stepExecutionFor` child route are implemented. The focused executor boundary, constructor
compile-fail, and governed-document tests passed; the complete core host-static gate passed 2,389/2,389 under
`-Werror`.

### Sprint 24.7: Workload partition and exact plan slices [Done]

**Status**: Done
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
  workload, cluster-internal service-target, or durable-root field is projected.
- Missing, duplicate, out-of-order, cross-scope, wrong-frame, or digest-mismatched entries refuse during pure
  projection, before budget admission or backend effects.

#### Validation

`CommandsSpec` and `ConfigSpec` cover both topology shapes, exact slice membership, ordering, digest checks,
and every refusal. The demo host-static gate must pass. The module and 400-line budgets are checked before
implementation; any new named contract, adoption, fourth module, or overflow is split into a new sprint.
Completed 2026-08-22: the focused VM/Direct role and canonical-digest checks passed, the governed-document
validator passed, and the full demo gate passed 128/128 together with the nested core gate at 2,389/2,389.

#### Remaining Work

None. The closed typed-identity eliminator partitions the exact nominal `PlannedStep` stream into five ordered
roles without a new contract type; `demoExactPlanSlices` joins the provider/cluster edge, retains each node's
exact dependency/resource prefix and shared config digest, and refuses cardinality or frame drift. The config
projection re-renders and digest-matches before returning refined resources, replicas, service targets, or durable root.
The two production-module and 400-line caps were retained.

### Sprint 24.8: Domain-separated runtime dependency package [Done]

**Status**: Done
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

Completed 2026-08-22: focused package/domain/registry tests and the hidden-module compile-fail fixture passed;
the governed-document validator and `-Werror` build passed; and the full core host-static gate passed all
2,394 tests. The implementation adds one named type across two production modules and 241 significant
production lines, within the declared budgets.

#### Remaining Work

None. The Cabal-private nominal package now binds every canonical coordinate and admits only bounded,
domain-prefixed routes. Exact provider/cluster openers reject coordinate, commitment, route, generation,
lifetime, and domain drift. One invocation-owned carrier shares separate canonical-package and live-closure
registries across every step runtime; live invocation checks exact canonical membership before calling the
closure, while neither registry serializes backend authority or managed handles.

### Sprint 24.9: Provider-domain package producer [Done]

**Status**: Done
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

Completed 2026-08-22: the focused provider backend gate passed 24/24, the existing package/domain suite and
hidden-import fixture cover exact opening and expiry boundaries, the governed-document validator passed as
part of the full gate, and the full core host-static gate passed all 2,395 tests under `-Werror`. No named
contract or consumer call site was added; the producer adds 113 significant production lines in its one
changed production module, within the two-module and 400-line caps.

#### Remaining Work

None. Exact settled Ready authority now publishes one pending provider package whose distinct hashes bind the
complete still-pending producer gate and action-local Ready call/observation. The paired service captures the
strong backend and managed handle only in the invocation-local live registry and accepts one fixed reprobe
request. Exact retries converge, canonical drift refuses, invalid gates fail before registration, and a new
carrier begins without either registry. `Chain` remains the sole owner of the later durable acknowledgment;
this producer introduces no promotion or consumer path.

### Sprint 24.9a: Exact carried ownership evidence [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`
**Production modules**: `HostBootstrap.Lifecycle.Execution.Internal`, `HostBootstrap.Reconcile` (2; cap 3)
**Sprint budget**: no new named contract and no call-site adoption; at most 300 production Haskell lines.
Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Let a fixed typed successor recover the exact generic handle/ownership-receipt pair carried from authenticated
ownership evidence, without decoding a witness from stable bytes or adding provider knowledge to the neutral
execution carrier.

#### Deliverables

- The existing `CarriedResource` keeps the already-validated ownership operation independently from its optional
  local settlement bytes; no receipt, managed handle, provider witness, or new named type enters the carrier.
- Authenticated child seeding transfers exact package resource/generation/operation evidence without attaching
  the parent frame's settlement, so the child can rebind ownership but cannot publish foreign settlement bytes.
- `Reconcile` alone can open one exact plan-admitted carried resource as a fresh lexical generic managed handle
  and matching `OwnershipReceipt`, binding key, generation, observation version, and ownership operation.
- Missing ownership evidence, a resource outside the node's exact dependency prefix, duplicate carriage, or
  malformed/empty ownership operation refuses before the continuation.
- Existing reporting and Chain publication APIs retain their prior shapes; stable bytes remain the canonical
  durable artifact and the added tuple field is invocation-local only.

#### Validation

`ReconcileSpec` covers exact lexical opening plus missing, foreign-key, empty-operation, and fresh-carrier
refusals. Existing Chain and resource-record suites must pass, followed by the full core host-static gate. The
no-type/two-module/300-line budgets are checked before implementation.

Completed 2026-08-22: the focused reconciliation gate passed 66/66, including exact receipt revalidation,
foreign-key refusal, and fresh-carrier refusal; the full core host-static gate passed all 2,395 tests under
`-Werror`, including Chain, resource-record, and governed-document validation. No named type or call-site was
added, and the two-module implementation remains well below the 300-line cap.

#### Remaining Work

None. The private carrier retains its already-validated ownership operation independently of optional local
settlement bytes without changing stable encoding or the existing Chain publication view. Authenticated transfer
can therefore seed ownership without granting settlement publication. `withCarriedManagedResourceReceipt`
alone rebinds one exact plan-admitted member to a lexical generic handle/receipt pair and refuses missing
ownership, unrelated keys, duplicates, empty operation, and fresh invocation state before its rank-2 continuation.

### Sprint 24.10: Fresh provider dependency recovery [Done]

**Status**: Done
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

Completed 2026-08-22: the focused provider backend gate passed 24/24; package/protocol-focused coverage passed
26/26; the lexical non-escape compile-fail fixture passed; and the full core host-static gate passed all 2,396
tests under `-Werror`, including governed-document validation. No named contract or project call site was
added, and the three-module implementation remains below the 400-line cap.

#### Remaining Work

None. The fixed successor selects the sole exact provider package and joins it with a plan-admitted provider
resource, freshly rebound carried handle/receipt, reconstructed backend origin, exact route, and live lifetime.
The live service consumes one bounded nonce and returns a canonical response bound to that nonce, the complete
package commitment, and the freshly reprobed generation. Only full agreement exposes a
`RunningProviderDependency` under the rank-2 continuation; retained reprobes derive fresh nonces, replay and
expiry refuse, and canonical bytes or backend reachability alone authorize nothing.

### Sprint 24.10a: Exact Lima provider backend realization [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Production modules**: `HostBootstrap.Substrate.Provider`,
`HostBootstrap.Substrate.Provider.Internal`, `HostBootstrap.Substrate.Provider.Backend` (3; cap 3)
**Sprint budget**: no new named contract and no project call-site adoption; at most 400 production Haskell
lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Realize the Apple host's closed Lima provider row through the same prepared provider backend vocabulary used
by exact resource settlement.

#### Deliverables

- Construction admits only an Apple-silicon `HostConfig`, the closed Lima provider value, a resolved Lima
  executable, one exact resource envelope, and absolute writable host/guest share paths.
- Semantic and realization fingerprints bind the VM identity, budget, share endpoints, and resolved tool; a
  changed term cannot reopen a package under another backend origin.
- Provisioning executes only the Lima row's closed launch effects, with exact absence/presence observations
  before and after mutation; readiness uses the row's bounded guest probe.
- A provider-bound Lima route admits only that VM and runs host-tool, guest, and provisioning-egress probes
  through the one host-command interpreter.
- Share observation requires the backend-retained host/guest endpoints and a live writable guest directory;
  it mints no independent mount mutation because Lima declares the share at VM creation.
- Forward stop/delete stay `Unsupported`; step-declared reverse remains the sole destructive Lima route.

#### Validation

`ProviderBackendSpec` covers host/provider/tool admission and exact budget/share fingerprint changes; provider
route suites cover the closed binding. The focused provider-backend group and complete core host-static gate
must pass under `--ghc-options=-Werror`. The zero-type/three-module/400-line budgets are checked before Done.

#### Remaining Work

None. Completed 2026-08-26 on aarch64 macOS: the focused provider-backend group passed 29/29, including Lima
admission and exact fingerprint changes, and the complete core host-static gate passed 2,462/2,462 under
`-Werror` in 433.14 seconds. The three-module implementation adds no named type or project call site and stays
below 400 production lines.

### Sprint 24.11: VM provider provision-to-ready adoption [Done]

**Status**: Done
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
- One demo call site selects the closed Incus or Lima strong backend, then prepares, runs, journals, and
  settles the provider reconciler under the exact budget and lifecycle bracket before any cluster or descent
  work begins.
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

The one adopter in `HostBootstrapDemo.Commands` receives the interpreter-supplied exact `StepExecution`,
selects the Incus or Lima strong backend without changing the lifecycle call shape, resolves only the
plan-owned provider resource at that execution's opaque operation key, and orders backend discovery,
provision call/settlement, managed Ready call/settlement, carried reverse identity, and pending dependency
package registration. Foreign, failed, and provisional branches return before registration; share,
cluster, and descent remain later in the action/chain. `CommandsSpec` pins both backend branches to this one
adopter and its fixed route, ordering, and no-fallback resource lookup. On 2026-08-26 the focused 61-case
`CommandsSpec` group passed under `--ghc-options=-Werror`.

#### Remaining Work

None. Completed 2026-08-26 on aarch64 macOS: `CommandsSpec` passed 61/61, the complete demo gate passed
145/145, and both the canonical and demo-linked core gates passed 2,462/2,462 under `-Werror`. Python quality
checks and all 231 Python tests also passed.

### Sprint 24.12: Direct provider reservation-to-ready adoption [Done]

**Status**: Done
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

- The Direct topology consumes its own plan-declared `core:deploy-vm` provider reservation at the current
  metal frame and the matching exact direct-parent join; that shared provider operation denotes a Direct host
  reservation here and creates no VM resource.
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

On 2026-08-22 the Direct Linux GPU provider action received its exact interpreter-supplied
`StepExecution`. Its adopter in `HostBootstrapDemo.Commands` resolves only the current-frame
plan-owned provider resource at that execution's opaque operation key, admits the canonical project root and
configured base-image egress through `mkDirectHostBackendSpec`, and orders reservation provision, managed
Ready, carried `reserved`/`demo-direct-provider-v1` reverse identity, and pending Direct package registration.
The separate following `core:build-image` action consumes that reservation before it performs CUDA and
project-image construction; nvkind work and descent remain later. Direct
foreign/failure/provisional paths return before package registration, and the implementation adds no VM
resource, physical reverse claim, or named contract. The one-adoption, one-module, and 400-line budgets hold.
`CommandsSpec` pins the exact current-frame callsite, full ordering, pre-CUDA placement, fixed Direct route,
and absence of operation-name fallback; its existing topology test proves the Direct plan has a current-frame
provider declaration and no VM provider resource, while lower backend suites retain root/egress/mismatch and
failure matrices. The canonical demo host-static gate passed all 130 demo tests and its linked core gate passed
all 2,396 core tests under `-Werror`. Live Direct acceptance remains Sprint 24.30.

#### Remaining Work

None.

### Sprint 24.13: Copy-source managed-share adoption [Done]

**Status**: Done
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
- One demo call site opens the fresh provider dependency through the selected Incus or Lima strong backend,
  prepares the exact copy-source resource, reconciles its share, journals ownership, and settles the backend
  observation before descent.
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

The VM topology contains one exact `copy-source` node after `deploy-vm` and before the VM descent; Direct
contains none. The shared Incus/Lima action freshly opens the producer's package-bound Running provider,
resolves only its own `DurableShareResource`, prepares with the fresh backend reprobe, reconciles and settles
the exact share, and keeps the managed provider/share handles lexical through mount validation and the nested
alias action. Incus may attach and restart; Lima proves the writable create-time mount retained by its exact
backend. Failure, foreign settlement, replay, and package mismatch return before the continuation can complete,
and no managed share is written to a carrier or later node. On 2026-08-26 the focused 61-case `CommandsSpec`
group passed under `--ghc-options=-Werror`.

#### Remaining Work

None. Completed 2026-08-26 on aarch64 macOS: the shared Incus/Lima lexical adopter passed the 61-case focused
`CommandsSpec`, complete 145-case demo gate, and both 2,462-case core gates under `-Werror`; no managed handle
or receipt crosses the action boundary.

### Sprint 24.14: Lexically nested guest-alias adoption [Done]

**Status**: Done
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

On 2026-08-22 `copy-source` began declaring its exact `core:copy-source/guest-alias` projection and the Incus
managed-share continuation replaced the compatibility `mintDurableAlias` call with the lower exact alias
reconciler. Fresh recovery now rebinds erased carrier evidence to the exact planned provider identity before
opening its rank-2 backend/provider continuation; that planned provider, its managed Running handle, the exact
planned/managed share pair, stable alias path, unchanged provider-selected target, and live mount probe enter
`reconcileNodeGuestAlias` together. Provider-bound capability discovery and strong-alias narrowing occur inside
the share settlement continuation, and alias settlement completes before it returns to `Chain`; neither handle
can reach the descent node or a carrier. Direct declares neither copy-source nor the alias projection. This adds
no named contract and remains one call-site adoption in one demo production module under 400 lines.
`CommandsSpec` pins the projection, target, lexical nesting, exact reconciler route, Direct absence, and removal
of the compatibility mutator; the lower alias suite retains the complete origin/source/target/replay/closed-
bracket mismatch matrix. The demo gate passed all 132 tests and the complete core host-static gate passed all
2,396 tests under `-Werror`.

#### Remaining Work

None.

### Sprint 24.15: Canonical provider-package wire vocabulary [Done]

**Status**: Done
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

On 2026-08-22 the provider-package codec gained its closed provider/cluster domain decoder, exact twelve-field
canonical re-render check, 64-KiB package bound, and 128-KiB request/response bound. The authenticated handoff
vocabulary gained the three closed singleton-field tags and a raw-byte facade for package, request, success,
and explicit-refusal frames; it deliberately adds neither a state-machine adoption nor a named contract.
`LifecycleDependencySpec` passed all 6 focused tests covering exact golden bytes, round trips, malformed and
noncanonical fields, changed commitments, replay, empty refusal, oversize, and the forbidden-witness source
guard. `HandoffSpec` passed all 108 tests including facade framing, duplicate fields, changed nonce, and the
closed-tag source guard. The three production modules remained within the 400-line sprint budget (56
significant lines in `HostBootstrap.Handoff`, 15 in `HostBootstrap.Handoff.Protocol`, and the bounded codec
addition in `HostBootstrap.Lifecycle.Dependency.Internal`), with no call-site adoption. The complete core
host-static gate passed all 2,399 tests under `-Werror` on `linux-cpu`.

#### Remaining Work

None.

### Sprint 24.16: Caller-free provider reprobe service kernel [Done]

**Status**: Done
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

On 2026-08-22 the caller-free kernel began opening every provider package coordinate and its exclusive
lifetime before backend access, atomically consuming one of at most 64 bracket-local nonces, and bounding the
lexical observation to 100 milliseconds. Exact-generation observations produce canonical success fields; replay,
capacity exhaustion, timeout, provider closure/refusal, and generation change produce canonical nonce-bound
refusals, while malformed or mismatched requests never reach the probe. The continuation receives only a
byte-field handler and the kernel installs no Process endpoint, exports no backend authority, adds no named
contract, and adopts no call site. `HandoffSpec` passed all 109 tests, including success, route mismatch,
single-use replay, closure, changed generation, timeout, and sealed ownership; `RecursiveLifecycleSpec` passed
all 6 real-process/local-kernel cases with a fake exact-generation observation. The implementation touched the
three declared production modules and added 62 significant facade lines plus a small Relay alias, remaining
well below 400 production lines. The complete core host-static gate passed all 2,401 tests under `-Werror` on
`linux-cpu` in 157.01 seconds.

#### Remaining Work

None.

### Sprint 24.17: Keyless multi-hop reprobe relay and child client [Done]

**Status**: Done
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

On 2026-08-22 `Handoff.Process` gained the sole service installation: it nests the caller-free kernel and a
record-narrowed `BrokerLink` endpoint inside the existing forward child-process exchange. Root links refuse
without that lexical installation. An admitted child's hidden receiver client uses only its retained channel
and request identity, permits one outstanding request, consumes at most 64 nonces, and accepts exactly the
closed matching response before the package codec verifies commitment, nonce, and outcome. Each intermediate
link forwards the exact field list through its authenticated parent channel, with a one-second upstream
deadline; it receives no endpoint authority or result constructor. The implementation adds no named contract,
socket, environment/config/argv/file route, generic carrier, or call-site adoption and stays within the three
declared modules and 400-line budget. `HandoffSpec` passed all 110 cases, including the live kernel matrix and
static one-hop/multi-hop route, keylessness, endpoint lifetime, bounds, and alternate-channel ownership; the
existing 6-case `RecursiveLifecycleSpec` retained its real two-boundary topology and exact fake observation
fixture. The complete core host-static gate passed all 2,402 tests under `-Werror` on `linux-cpu` in 155.88
seconds.

#### Remaining Work

None.

### Sprint 24.18: Authenticated child package admission [Done]

**Status**: Done
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

On 2026-08-22 the one forward-child descent adoption began querying the already authenticated edge for its
parent-selected provider package only when the admitted local plan has cross-frame dependencies. The query
carries no candidate package; Relay returns the Process endpoint's exact canonical package or explicit
absence. A present provider-domain package is registered in the child's invocation-wide `ResourceCarrier`,
and the hidden nonce client is attached in its distinct live-service registry before the frame executor opens.
Every local `StepRuntime` shares that carrier, and deeper descents forward the same canonical package and fixed
service. Admission performs no probe and names no `RunningProviderDependency`, managed provider/share handle,
or cluster-readiness witness. `ChainSpec` passed all 44 cases including the package-only seed/no-witness source
proof, `HandoffSpec` passed all 110 bounded transport cases, and `RecursiveLifecycleSpec` passed all 6 real
two-process-boundary cases including explicit package absence. The three declared production modules remained
within the no-new-contract and 400-line sprint budget, and the child owner remained below its pre-existing
two-split 800-significant-line ceiling. The complete core host-static gate passed all 2,403 tests under
`-Werror` on `linux-cpu` in 160.83 seconds.

#### Remaining Work

None.

### Sprint 24.19: Exact rendered cluster config and exposure intent [Done]

**Status**: Done
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

Render exact canonical Kind/nvkind configuration and semantic exposure intent from digest-matched plan
metadata before any cluster backend is selected.

#### Deliverables

- A pure demo renderer consumes only Sprint 24.7's exact cluster slice and finalized config projection, verifies
  the retained config digest, and emits canonical bytes plus their digest and deterministic state/config paths.
- The closed driver value selects only Kind or nvkind rendering; driver-specific node, mount, accelerator,
  network, and kubeconfig fields are total and unknown driver text is unrepresentable.
- The projection declares a closed set of service identities, protocols, and stable cluster-internal targets.
  Canonical Kind/nvkind bytes contain no host-side port number or `extraPortMappings`; host publication is a
  later owned runtime result rather than configuration.
- The VM/container render preserves the selected writable durable target and cluster topology, while Direct
  rendering contains no VM/share/alias fiction; both retain the same exact cluster resource identity.
- Canonical output is stable under map ordering and rejects lexical path escape, unknown fields, noncanonical
  bytes, digest disagreement, and independently supplied cluster/profile/root terms. Symlink and file-identity
  checks are intentionally deferred to the later IO backend under its lock.

#### Validation

`ClusterConfigSpec` and `CommandsSpec` cover Kind/nvkind golden output, both topologies, exact semantic targets,
absence of host-port rendering, canonical stability, digest agreement, and all refusal cases. A source guard
rejects numeric host-port policy in Dhall, Haskell, generated Kind/nvkind YAML, and chart/test client fixtures.
The demo host-static gate must pass. The
module/400-line budgets are checked before implementation; any type, adoption, fourth module, or overflow is
split.

#### Remaining Work

None. Completed 2026-08-23. The pure Kind/nvkind renderer emits canonical host-port-free bytes plus the exact
semantic service/target set, and refuses digest/slice drift. `ClusterConfigSpec` covers both golden renderings
and the complete demo gate passed 142/142 under `--ghc-options=-Werror`.

### Sprint 24.20: Plan-owned cluster driver/config package [Done]

**Status**: Done
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

Bind the exact closed driver, canonical rendered config, exposure intents, and plan-owned cluster package into the one
input accepted by cluster preparation.

#### Deliverables

- Opaque `PlanOwnedClusterConfig` is the sole named type and binds the exact existing `PlanOwnedCluster`, closed
  Kind/nvkind driver, canonical bytes/digest, config/state paths, semantic exposure intents, node mappings, and workload slice.
- `withPlanOwnedCluster` first constructs the existing base `PlanOwnedCluster` from the planned provider
  resource and admitted provider→cluster edge, without runtime dependency or config recursion; a separate
  hidden binder then matches Sprint 24.19 output and produces the wrapper. Runtime dependency is consumed only
  when preparing the reconcile.
- Cluster preparation no longer hardcodes `Kind` or resolves a driver independently; it consumes the completed
  wrapper and exposes no raw path, driver text, or alternate config argument.
- `PreparedClusterReconcile` retains that exact package so every reconcile, cordon, readiness, and cleanup
  operation observes one driver, bytes digest, path set, mapping set, and ownership identity.
- Wrong driver/config pairing, changed bytes or path, sibling provider, stale generation, duplicate/unknown
  service target, host-port-bearing config, mismatched slice, or independently supplied term refuses before
  backend discovery or mutation.

#### Validation

`ClusterReconcileSpec`, `ClusterConfigSpec`, and compile-fail fixtures cover sole construction, exact retention,
both drivers, all mismatches, and removal of the hardcoded Kind path. Core and demo host-static gates must pass.
The sole-type/module/line budgets are checked before implementation; overflow is split.

#### Remaining Work

None. Completed 2026-08-23. `PlanOwnedClusterConfig` binds the closed driver, canonical bytes/digest, paths,
node mappings, workload slice, and semantic exposure intents; its hidden binder rejects host publication and
invalid/duplicate intents. The complete core gate passed 2,428/2,428 and the demo gate passed 142/142 under
`--ghc-options=-Werror`.

### Sprint 24.21: Closed Kind/nvkind cluster and exposure backend [Done]

**Status**: Done
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
config term needed for reconcile, runtime-owned relay exposure, cordon, readiness, and cleanup.

#### Deliverables

- Backend discovery consumes only `PlanOwnedClusterConfig` and resolves exactly the closed Kind or nvkind
  branch; caller-selected driver names, executables, paths, and argument lists are absent.
- The strong backend retains the exact Kind-or-nvkind creation driver plus Docker, Kubectl, and Helm tool
  identities required by its branch, the canonical config digest and ownership identity, and the completed
  Phase 16 clause-holding store. Flock, Python, and supervisor identities are intentionally absent: Phase 16
  deleted that locking front end/interpreter and this sprint must not recreate it.
- Every subprocess invocation is generated internally from the retained branch and exact package; nvkind never
  falls back to Kind and Kind never silently invokes nvkind.
- Discovery and reprobe reject missing/wrong tools, changed executable identity, changed config bytes/digest,
  state-root escape, backend replacement, unsupported substrate, and ambiguous installation before mutation.
- Existing reconcile, applied-cordon, readiness, and cleanup calls accept only the resolved closed backend and
  retain their lock, fresh-observation, generation, and exact-identity guarantees.
- After cluster readiness, the backend realizes Sprint 24.19's service intents through the generic
  cluster-lifecycle exposure operation. The exact derived project image supplies the hidden relay process;
  Docker joins it to the cluster network and atomically publishes each relay listener on loopback with no
  host-side number. Exact inspection returns one resolved mapping per declared service and no others.

#### Validation

`ClusterBackendSpec` and compile-fail fixtures cover both branches, exact tool retention and invocations,
replacement/mismatch refusal, no fallback, and all lifecycle operations. The core host-static gate must pass.
The module and 400-line budgets are checked before implementation; any new type or adoption is split.

#### Remaining Work

None. Completed 2026-08-23. The closed backend creates one identity-labelled immutable-image relay on the Kind
network, lets Docker select loopback ports, exact-inspects every declared mapping, and conditionally releases
only the recorded identity. Focused exposure tests passed 11/11, all 519 compile-fail boundaries passed, and
the complete core gate passed 2,428/2,428 under `--ghc-options=-Werror`.

### Sprint 24.22: Cluster-domain readiness and exposure recovery [Done]

**Status**: Done
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

Produce and later open a cluster-domain runtime package so successors receive freshly reprobed lexical
`ClusterReadiness` and exact resolved exposures, never carried witnesses or reconstructed ports.

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
- The package commits each semantic service to its resolved-exposure identity. Its opener re-inspects the exact
  relay and mappings before exposing endpoints lexically; a port number without matching relay/cluster
  generation and ownership operation carries no authority.

#### Validation

`ClusterBackendSpec`, `LifecycleDependencySpec`, and compile-fail fixtures cover exact production, fresh open,
every mismatch/staleness case, non-escape, and absence of forbidden witnesses. The core host-static gate must
pass. The module and 400-line budgets are checked first; any new type or adoption is split.

#### Remaining Work

None. Completed 2026-08-23. The cluster package commits its exact resolved service set and the live opener
freshly re-inspects it before yielding readiness and opaque exposures lexically; nonce replay, changed mapping,
wildcard, malformed response, and cross-service attempts refuse. All 519 compile-fail boundaries and the
complete 2,428-case core gate passed under `--ghc-options=-Werror`.

### Sprint 24.23: Exact cluster reconcile, exposure, cordon, and readiness adoption [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: one cluster lifecycle call-site adoption and no new named contract; at most 400 production
Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Adopt one exact demo cluster call site from fresh provider recovery through reconcile, readiness, runtime-owned
exposure, applied cordon, and cluster-package production.

#### Deliverables

- The action-side plan projection attaches the already-validated exact Sprint 24.7 budget to the executing
  cluster resource under fresh partition indices and joins the cluster/provider resources using only the
  opaque `StepExecution`'s retained plan metadata; it never reconstructs a sibling `ProjectPlan`. The call
  site consumes that slice, Sprint 24.20 plan-owned cluster config, Sprint 24.21
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
- Exposure settlement occurs only after exact cluster readiness and before cluster-package publication. The
  action supplies semantic targets, never candidate host ports; reverse removes the identity-bound relay before
  cluster deletion.
- Direct and VM/container lanes reach this same call-site shape through their distinct admitted provider routes;
  no compatibility export, demo-local cluster mutation, hardcoded Kind, or raw tool call is permitted.

#### Validation

`CommandsSpec` plus the core cluster specs cover both lanes, action-side exact-plan/slice projection, exact
order, package carriage, failure unwind, every mismatch, and absence of
raw mutations. The core and demo host-static gates must pass. The one-adoption/module/line budgets are checked before
implementation; overflow is split before the call site lands.

#### Remaining Work

None. Completed 2026-08-23. The single VM/Direct adopter orders provider recovery, plan/config/backend binding,
reconcile, cordon, readiness, exposure settlement, and package publication. Both reverse routes recover and
remove the identity-bound relay before cluster deletion. `CommandsSpec` passed 58/58; the complete core and
demo gates passed 2,428/2,428 and 142/142 under `--ghc-options=-Werror`.

### Sprint 24.24: Planned chart/workload resource [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
**Production modules**: `HostBootstrap.Step`, `HostBootstrap.Lifecycle.Plan`,
`HostBootstrap.ProjectPlan` (3; cap 3)
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

None. `ChartWorkloadResource` is abstract and generative, and its only projection reads an admitted
`core:deploy-chart` declaration. Admission requires one non-empty declaration with unique effects and exactly
one prior `core:deploy-kind` dependency in the chart frame. Stable plan format 5 binds the declaration and its
cluster dependency; every structural/recovery decoder consumes the same schema. The public reverse identity is
derived from the admitted release, namespace, and workload declaration key. Focused validation passed 92
indexed-plan tests and the hidden-construction compile-fail fixture. On 2026-08-22 the complete core gate passed
2,413/2,413 in 163.08 seconds under `--ghc-options=-Werror`. The sprint introduced its one declared named type,
used all three allowed production modules, adopted no call site, and stayed below 400 added production Haskell
lines.

### Sprint 24.25a: Exact workload/partition declaration binding [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Workload/Binding.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/BudgetSpec.hs`
**Production modules**: `HostBootstrap.Lifecycle.Plan`, `HostBootstrap.Cluster.Budget`,
`HostBootstrap.Cluster.Workload.Binding` (3; cap 3)
**Sprint budget**: no new named contract and no call-site adoption; at most 400 production Haskell lines. Split
before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Give Sprint 24.25 a caller-free, canonical equality between the stable chart declaration and the generative
workload-set/partition outputs.

#### Deliverables

- The hidden plan kernel folds the exact chart declaration, stable plan digest, and same-frame cluster key only
  while the nominal `ChartWorkloadResource` is in scope; no facade exposes a constructor or caller-authored
  replacement record.
- `PlannedWorkloadSet` and `BudgetPartition` retain deterministic canonical identities derived from their exact
  ordered workloads, budgets, and slices. Empty text, delimiter ambiguity, reordering, resource substitution,
  or budget drift changes or refuses the identity.
- One equality fold joins the chart declaration key/digest to the exact generative workload set and partition;
  callers supply neither an expected key nor an expected digest, and a mismatch yields no continuation.
- Existing budget admission semantics and nominal indices remain unchanged, and no backend command is run.

#### Validation

`ProjectPlanSpec` and `BudgetSpec` cover deterministic identity, ordering and budget sensitivity, exact match,
all declaration substitutions, and absence of a caller-authored digest seam. The complete core host-static gate
must pass. The no-type/module/line budgets are checked before implementation.

#### Remaining Work

None. The chart resource retains its stable plan digest and same-frame cluster key behind a hidden detail fold.
`PlannedWorkloadSet` and `BudgetPartition` derive length-framed SHA-256 identities from exact ordered workload,
overhead, resource/frame, slice, and quantity fields; the workload key is hash-framed as well. The pure binding
fold compares all three identities and releases no continuation on substitution. Focused `BudgetSpec` passed
25/25 cases, including ordering, quantity, budget, and declaration drift. On 2026-08-22 the complete core gate
passed 2,416/2,416 in 165.67 seconds under `--ghc-options=-Werror`. The sprint added no named type or call-site
adoption, used all three allowed production modules, and stayed below 400 added production Haskell lines.

### Sprint 24.25b: Chart dependency and journal preparation kernel [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/test/ClusterReconcileSpec.hs`, `core/hostbootstrap-core/test/ReconcileSpec.hs`
**Production modules**: `HostBootstrap.Cluster.Reconcile`, `HostBootstrap.Reconcile` (2; cap 3)
**Sprint budget**: no new named contract and no call-site adoption; at most 400 production Haskell lines. Split
before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Seal the chart operation's exact ready-cluster dependency and durable prepare gate through the existing generic
reconciliation journal without exposing resource-handle construction.

#### Deliverables

- `ClusterReadiness` projects its retained managed cluster handle only through the public read-only cluster
  module; callers still cannot construct or relabel readiness evidence.
- One chart-specialized generic reconciliation kernel derives the chart handle, operation descriptor, exact
  cluster dependency, call digest, observation version, and operation/precondition pair from the nominal chart
  resource, ready cluster handle/probe, and `PreparedGate`.
- The kernel rejects wrong cluster identity, empty call digest, stale/foreign gate, missing or duplicate
  dependency, failed readiness reprobe, and zero fence/version before yielding its generative continuation.
- No workload backend command, activation witness, or new result/type is introduced.

#### Validation

`ClusterReconcileSpec` and `ReconcileSpec` cover the exact ready dependency and every substitution/refusal.
The complete core host-static gate must pass. The no-type/module/line budgets are checked before implementation.

#### Remaining Work

None. Completed 2026-08-22. `ClusterReadiness` exposes only its read-only handle/probe projections, and the
generic chart preparation kernel derives and seals the exact cluster dependency, chart handle, operation
descriptor, call digest, gate, operation, and preconditions. Focused `ClusterReconcileSpec` and `ReconcileSpec`
coverage passed, including wrong-cluster, failed-readiness, and wrong-gate refusals; the complete core gate passed
2,421/2,421 after the forward workload slice was added.

### Sprint 24.25: Prepared and settled chart/workload backend [Done]

**Status**: Done
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

Prepare, run, observe, journal, and settle the exact chart resource behind readiness evidence,
without adding a parallel result type.

#### Deliverables

- Cabal-hidden `PreparedChartWorkload` is the sole named type and retains the exact planned resource,
  `PreparedGate`, freshly opened lexical `ClusterReadiness`, successor execution descriptor,
  canonical values/image digests, and operation attempt/version.
- Its only preparer checks that readiness, resource, cluster identity, plan, scope, frame, gate, canonical values,
  and declared effects all match the stable plan before Helm or Kubernetes access. Runtime role activation is
  installed for the deployed service revision; it is not controller authority and is never made available to
  the deployment action.
- `Cluster.Backend` renders the one producer-owned Helm/Kubectl transaction internally from the registered
  cluster runtime service and exact package fields; callers provide no executable, raw arguments,
  release/namespace, values path, or readiness flag.
- The prepared value runs and settles inside its hidden eliminator, returning the existing generic
  `ReconcileResult`/`ChangeView`; replacement, stale readiness/activation/gate, digest drift, foreign release,
  partial apply, timeout, or unready workload refuses, and no second named result is introduced.
- Reverse cleanup is the independently bounded no-new-type Sprint 24.25c immediately below.

#### Validation

`ClusterWorkloadSpec` and compile-fail fixtures cover sole forward preparation, exact apply rendering,
Changed settlement, journal/version binding, canonical-value drift, malformed success, readiness failure, and
no second result type. The core host-static gate must pass. The sole-type/module/line budgets are checked before
implementation; reverse cleanup is split because the combined implementation exceeds 400 lines.

#### Remaining Work

None. Completed 2026-08-22. Cabal-hidden `PreparedChartWorkload` is the sole new named type and is produced only
after exact declaration, freshly recovered cluster-readiness, values-digest, dependency, and journal-gate
checks. The producer-owned runtime service renders Helm upgrade/install through stdin followed by the exact
Kubectl deployment rollout, while the successor settles through the generic `ReconcileResult`/`ChangeView`.
Nine focused behavior cases cover exact apply, drift and malformed-output refusals, rollout failure,
conservative no-op settlement, cleanup convergence, replay, and route substitution. The complete core gate
passed 2,429/2,429 with `--ghc-options=-Werror`; the governed-documentation validator passed within that gate.

### Sprint 24.25c: Journal-owned chart/workload reverse cleanup [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Workload.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/ClusterWorkloadSpec.hs`
**Production modules**: `HostBootstrap.Cluster.Workload`, `HostBootstrap.Cluster.Backend` (2; cap 3)
**Sprint budget**: no new named type and no call-site adoption; at most 400 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Release the exact Helm workload owned by a settled forward chart resource without replaying forward preparation
or exposing command construction.

#### Deliverables

- One hidden eliminator consumes only the exact managed forward settlement and the planned release, namespace,
  and resource identity retained by the prepared package; it admits no caller-supplied executable or arguments.
- The backend renders Helm uninstall and authoritative absence observation internally under the retained backend.
- Removed and already-absent releases converge through existing reconciliation views, while replacement,
  foreign ownership, malformed output, partial removal, and command failure refuse.
- Cleanup requires no `PreparedGate`, `ClusterReadiness`, activation witness, values bytes, or second result type.

#### Validation

`ClusterWorkloadSpec` covers exact uninstall rendering, absence convergence, ownership/version substitution, and
all backend refusal branches. The complete core host-static gate must pass, and the no-type/module/line budgets
are checked before implementation.

#### Remaining Work

None. Completed 2026-08-22. The no-new-type cleanup fold admits only a generic managed forward settlement for
the exact nominal chart resource, derives release and namespace from the stable declaration, renders Helm
uninstall and status internally, and converges over authoritative absence. Focused cleanup coverage passed for
both removal/absence convergence and malformed-success refusal. The complete core host-static gate passed
2,423/2,423 with `--ghc-options=-Werror`; the governed-documentation validator passed within that gate. The
cleanup addition uses the same two production modules, adds no named type, and remains below 400 production
Haskell lines.

### Sprint 24.25d: Successor-local chart and readiness recovery [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Workload.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`
**Production modules**: seven tightly coupled existing modules; split into a second bounded prerequisite before
additional production growth if the 400-line cap would be exceeded.
**Sprint budget**: no new named contract and no call-site adoption; at most 400 production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Let the fixed chart successor recover its own exact stable chart declaration, acknowledged managed-cluster
handle, and one-use freshly serviced readiness observation without reconstructing the producer's backend package.

#### Deliverables

- The neutral execution descriptor retains the current node's chart declaration only when the admitted plan
  projected one; a rank-2 opener reconstructs the nominal chart resource for that exact node.
- The successor rebinds the acknowledged cluster settlement from the invocation carrier at its exact planned
  resource type and validates the canonical cluster package without accepting a caller-selected backend origin.
- The invocation-owned service performs the fresh backend probe and returns its nonce-bound observation version;
  `ClusterReadiness` is reconstructed lexically as a one-use dependency probe over the carried managed handle.
- Missing declaration, unacknowledged cluster settlement, package substitution, duplicate service, replay,
  expiry, zero version, or a second readiness use refuses before chart effects.

#### Validation

`ReconcileSpec`, `ClusterBackendSpec`, `ClusterReconcileSpec`, and compile-fail fixtures cover exact projection,
fresh successor recovery, one-use behavior, every mismatch, and non-escape. The complete core gate must pass.

#### Remaining Work

None. Completed 2026-08-22. The execution descriptor retains the exact optional chart declaration, the
successor rebinds only its acknowledged carried cluster settlement, and the canonical cluster package opens
without caller-supplied backend origin. Its live service returns a nonce-bound fresh readiness version and owns
the exact chart effect transaction; readiness is reconstructed only inside a rank-2, one-use continuation.
Focused coverage passes for exact execution, chart application, replay, and route substitution, and the complete
core gate passed 2,429/2,429 with `--ghc-options=-Werror`.

### Sprint 24.26: Readiness-gated activated chart/workload adoption [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/docker/Dockerfile`, `demo/chart/`, `demo/hostbootstrap-demo.cabal`, `demo/test/CommandsSpec.hs`,
`hostbootstrap/bootstrap.py`, `tests/test_bootstrap.py`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Relay.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Identity/Install.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Workload.hs`
**Production modules**: one demo adopter, the thin Python builder, and twelve existing core boundary modules;
the activated adoption is split across the owners of identity installation, root-only signing, keyless relay,
child execution, service installation, and chart preparation rather than introducing a parallel facade.
**Sprint budget**: one activated chart/workload call-site adoption and no new named contract. The existing
boundary modules are changed only at their fixed entry/fold; no generic signer or activation carrier is added.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Run the demo service only from an exact root-signed immutable activation revision, through the planned,
readiness-gated chart transaction.

#### Deliverables

- The fixed chart successor opens Sprint 24.22's cluster-domain package only after acknowledged producer-node
  sequencing, fresh-reprobes the exact cluster, and keeps `ClusterReadiness` lexical for this one action.
- The action's own `PreparedGate` and Sprint 24.24's planned resource are joined with that readiness; missing or
  mismatched evidence refuses before backend work. The prepared workload retains only an exact lowercase
  activation-revision basename and the backend injects only that basename into Helm.
- One demo call site prepares, runs, observes, and settles Sprint 24.25's transaction, then returns its generic
  `ChangeView` through the existing `Chain` outcome/journal path.
- The demo defines both long-running roles as closed `ServiceProgram`s. Before Helm, it measures the exact image
  and in-image binary, decodes the Production role wire, finalizes the registry, builds the canonical manifest,
  and asks the invocation-local execution service to sign it. Nested frames relay those canonical bytes to the
  root; only the root activation key signs, and only when the plan digest plus exact planned service/effect row
  match.
- The returned signature is adopted through the existing activation installer under the durable data root.
  Docker receives only the independently installed public key. The chart mounts the immutable revision and
  authority store read-only/by exact path and obtains the real Kubernetes pod UID and container restart count;
  its dedicated service account may only `get` its own pod.
- After copying a stable project binary, the thin builder invokes one exact private Haskell entry which installs
  or validates the handoff, build, and activation identities. Python never reads, creates, or interprets key
  material, and this entry creates no project configuration.
- The legacy `deployChart` call and independent `clusterProfileOf`/`containerPlan`/filesystem/config terms are
  removed; no Phase 22 sprint is redefined as owning this demo chart mutation.

#### Validation

`CommandsSpec` covers readiness/gate/signing/install ordering, both demo lanes, exact chart assets, restricted
pod-get RBAC, real restart identity, plan projection, and absence of `deployChart`. Core activation, relay,
identity-install, lifecycle-dependency, and workload tests cover canonical signing, exact policy, key
separation, bounded protocol v2, basename validation, and refusal. `test_bootstrap` covers the post-copy private
entry without config initialization. Core, Python, and demo host-static gates must pass before live acceptance.

#### Remaining Work

None. Completed 2026-08-23. The complete core gate passes 2,442/2,442 under `-Werror`, the complete demo suite
passes 142/142, all 231 Python tests pass, and Ruff, Black, MyPy, and the changed-file Fourmolu check are clean.
Sprint 24.30 retains the separate live activation evidence rather than duplicating it here.

### Sprint 24.27: Exact worked-demo reverse command adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/ResourceRecord.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrap.Command`, `HostBootstrap.Command.LifecycleEntry`,
`HostBootstrap.Cluster.Backend`, `HostBootstrap.Lifecycle.ResourceRecord`, `HostBootstrap.Reconcile`,
`HostBootstrap.Teardown` (6; cap 6)
**Sprint budget**: one reverse-command call-site adoption and no new named contract; at most 400 production
Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/operations/demo_runbook.md`

#### Objective

Adopt exact chart cleanup in the shared demo `down`/`destroy` command from retained teardown
plan/frame/journal authority, without pretending `TeardownAction` receives a forward `StepExecution` package.

#### Deliverables

- The one Production reverse-command entry consumes Phase 17's exact `TeardownPlan`, current frame, command
  intent, cursor, and reconstructed `ProjectPlan`; it never accepts or reconstructs `PlanExecutionPackage`.
- The exact `LocalWork` operation key projects only its plan-owned chart resource. Cleanup reads that resource's
  canonical protected record, verifies its plan digest, frame, and resource identity, and derives the Helm
  release and namespace only from the verified chart projection.
- Child-first forest order runs authenticated chart removal before the owning frame's cluster cleanup. Existing
  declared provider/share/alias reverses remain reachable only through their exact projected `LocalWork` node.
- Missing ownership is retained as foreign; malformed, stale, wrong-plan, wrong-frame, and wrong-resource records
  fail before Helm. A verified released tombstone converges without a second mutation.
- Both the Production driver and the Harness destroy driver use the same record-authenticated chart rule, while
  `down`/`destroy` continue to omit the canonical durable root from their removal sets.

#### Validation

`ProjectPlanSpec` and `CommandsSpec` cover retained-plan command entry, exact operation/record/chart stages,
absence of forward-package use, and the established child-first/down/destroy projections. Resource-record,
cluster-workload, teardown, and compile-fail suites cover mismatch refusal, idempotent cleanup, ordering, and
non-forgeability. Core and demo host-static gates must pass. The one-adoption/module/line budgets are checked.

Completed 2026-08-22: the focused core and demo source-shape gates passed; the full core host-static gate passed
2,429/2,429 and the complete demo suite passed 139/139 under `--ghc-options=-Werror`. The implementation adds
no named contract, keeps the single Production reverse-command entry, and remains below the 400-line budget.

#### Remaining Work

None. The sealed root reverse entry lends its reconstructed exact plan to each opaque local-work callback. A
chart node can therefore open only the record named by its plan digest, frame, and resource key; only a verified
owned record reaches Helm, and a verified released record is already converged. No forward execution package or
caller-selected chart identity enters reverse execution. The authenticated reverse child derives the exact
Production or `harness:<run-id>` lifecycle profile from its verified handoff binding, executes retained cluster
release in the child frame, and classifies a callback-free non-core node as foreign-retained rather than as a
successful release.

### Sprint 24.28: Exact demo forward-child projector [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/app/Main.hs`,
`demo/test/CommandsSpec.hs`, `demo/test/compile-fail/`
**Production modules**: `HostBootstrapDemo.Commands`, `Main` (2; cap 3)
**Sprint budget**: one demo projector call-site adoption and no new named contract; at most 400 production
Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/composition_methodology.md`, `documents/architecture/generic_project_model.md`,
`documents/architecture/hostbootstrap_core_library.md`, `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Install the exact project-owned forward-child projector after every projected provider, cluster, chart,
guest, and reverse consumer is exact.

#### Deliverables

- `demoForwardChildPlan`, its chain-at-context/payload helpers, and `validateDirectParentLift` form the sole
  demo projector; `Main` installs it exactly once with `addForwardChildPlan`.
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

`CommandsSpec`, `Main` source guards, and the core projector compile-fail fixtures cover Production/Harness
scopes, VM and Direct topologies, exact immediate-edge semantics, the sole Direct rebase, payload cases, hidden
package fields, and no compatibility export. The demo host-static gate must pass. The one-adoption/module/line
budgets are checked.

Completed 2026-08-22: `Main` retains its expected projector-installation hash
`7956057055b30b02f534eaa147dbef0d01756445e0d56148ecc259bbb0a794cb`; the focused behavioral gate covers the
root→VM, VM→container, Direct, Harness, foreign-edge, and wrong-lift paths; and the complete demo suite passed
140/140 under `--ghc-options=-Werror`. The implementation adds no named contract and remains below 400
production Haskell lines.

#### Remaining Work

None. The installed scope-polymorphic projector proves the retained ancestry prefix and unique immediate edge,
rebuilds the child-local graph from the narrowed config, admits only the exact Direct durable-source rebase,
and yields no binding, executable, `SelfRef`, or compatibility export.

### Sprint 24.29: Authenticated derived-image adoption [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `demo/docker/Dockerfile`,
`core/hostbootstrap-core/test/CommandSpec.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrap.Command`, `HostBootstrapDemo.Commands` (2 Haskell modules; cap 3;
`demo/docker/Dockerfile` is a build input)
**Sprint budget**: the VM and Direct image-build call-site adoption and no new named contract; at most 400
production Haskell lines. Split before implementation if either cap would be exceeded.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/build_release.md`,
`documents/operations/demo_runbook.md`

#### Objective

Build the demo image only through the authenticated project-owned build protocol after the exact plan/projector
and published-base provenance boundaries close.

#### Deliverables

- Both demo build lanes consume an authenticated clean source/build identity, a freshly resolved published-base
  repository digest, and the canonical Dockerfile/context projection. The Direct lane fixes its executable and
  context locally; the VM lane measures the installed guest builder and transfers authority secret files through the
  provider's typed file-transfer route.
- The existing build protocol binds project/spec/config, build nonce, source, coordinator, builder, and frame.
  Each build uses a fresh temporary channel, disables Docker layer-cache reuse, and removes pushed VM secret
  files after the build attempt.
- The binding's specification digest is the jointly finalized Production runtime codec that image
  `check-code` opens. A Harness lifecycle may request the build, but its separately labelled Harness plan codec
  is not substituted for the image entrypoint's specification.
- Every derived build retains `--pull`, uses the within-run repository digest resolved in Sprint 24.4, and runs
  the image's warning-clean `check-code`; a stale local base cannot satisfy the result.
- Image-build `check-code` accepts only the fixed BuildKit channel/verification/coordinator/config secret mounts
  and the selected builder supplied as the read-only `hostbootstrap-builder` named build context, canonically
  validates the sibling image config, measures `/workspace/demo` and the running installed builder,
  verifies the signed grant, and consumes its at-most-once `CheckCodePhase` authority before the project hook.
- No environment, argv, Dhall field, source file, or durable project file transports build authority. The
  Dockerfile installs the coordinator-selected, source-built builder from the named build context and the config
  from a secret, authenticates the warning-clean gate, compiles and verifies the in-image Cabal product, then
  materializes the digest-bound builder bytes as the export-stable runtime executable.

#### Validation

`BuildAuthoritySpec` and `CommandsSpec` cover authenticated signing/verification, digest identity, at-most-once
phase use, `--pull`, `--no-cache`, published digest resolution, fixed secret delivery, warning-clean stage
ordering, malformed/cross-project/replacement refusal, and absence of Dockerfile config minting. Core and demo
host-static gates must pass. The adoption/module/line budgets are checked.

Completed 2026-08-22: `BuildAuthoritySpec` passed 28/28, the focused demo BuildKit adopter passed, the full core
host-static gate passed 2,429/2,429, and the complete demo suite passed 141/141 under
`--ghc-options=-Werror`. No named contract was added; the two-module implementation plus Dockerfile remains
below 400 production Haskell lines.

#### Remaining Work

None. Both derived-image lanes resolve and pull the published base, sign a fresh source/config/builder binding,
deliver authority material through transient BuildKit secrets and the measured builder through a read-only named
build context, and run authenticated `check-code` before verifying the in-image source build and exposing the
digest-bound authenticated builder as the runtime image binary. `CommandsSpec` also proves that both lifecycle
scopes bind image authority to the exact finalized Production runtime specification measured by that entrypoint.
Ordinary host developer `check-code` remains a config-gated local action.

### Sprint 24.30: Production recursive-lifecycle acceptance [Done]

**Status**: Done
**Implementation**: no production change; evidence in this phase and
`documents/operations/demo_runbook.md`
**Production modules**: none (0; cap 3)
**Sprint budget**: no new named contract, no call-site adoption, and zero production Haskell lines; this is the
separate live-substrate confirmation of the preceding host-static changes.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/engineering/testing.md`, `documents/architecture/composition_methodology.md`

#### Objective

Confirm the proof-complete recursive lifecycle command through the real Production demo consumer.

#### Deliverables

- Acceptance starts only after Sprints 24.3–24.29 and the demo static gate are green; it introduces no fallback
  interpreter, authority injector, compatibility export, test-only lifecycle route, or production code.
- Fresh Production `project up` traverses every declared frame through Phase 17's root-coordinated storeless
  frame executor and reaches exact provider, cluster, workload, service readiness, and read-only endpoint
  assertions.
- One exact demo owner receives distinct runtime-assigned loopback ports for its registry, web, MinIO, and
  host-accelerator listeners without candidate scanning, retry-on-collision, or operator configuration. Every
  probe uses the endpoint resolved for its own exact service and generation. The lower cluster-lifecycle phase's
  live gate separately proves concurrent same-listener allocation in one Docker namespace.
- Production `project down` and root-only `project destroy` drive Sprint 24.27's shared child-first reverse
  route, report Direct physical release as `Unsupported`, remove only owned state, and preserve the canonical
  durable-root sentinel required by each command contract.
- Dated evidence records host/OS/architecture, tool versions, published base and derived image identities,
  exact command results, and audited provider/cluster/workload/durable-root end state.

#### Validation

On fresh linux-cpu, pass `cabal build all` and
`cabal test hostbootstrap-demo-test --ghc-options=-Werror` from `demo/` and the core host-static gate from
`core/`; prove the live demo's distinct authenticated service endpoints; then run
`hostbootstrap run -- project up`, `hostbootstrap run -- project down`, and
`hostbootstrap run -- project destroy`. Record evidence only after every command exits as specified, owned
infrastructure is absent or explicitly `Unsupported` as contracted, and durable-root assertions pass. Phase 17
retains only its host-static process gate; Phase 19 retains its separately owned Harness/interruption gate.

#### Remaining Work

None. Completed 2026-08-24 on the disposable `hostbootstrap-phase24-cpu-host` gate host: Ubuntu 24.04.4 LTS,
Linux 6.8.0-138-generic x86_64, Incus 6.0.0, Docker 29.1.3, Python 3.12.3, GHC 9.12.4, Cabal 3.16.1.0, and
`hostbootstrap` 0.1.0. Fresh Production `project up`, `project down`, and root-only `project destroy` each
exited successfully; the sequence reached distinct runtime-assigned registry, web, and MinIO loopback
endpoints, retained the durable sentinel through both reverse verbs, and removed the owned provider after
Destroy. The separately owned lower cluster-lifecycle live gate supplies the concurrent same-listener
allocation proof.

### Sprint 24.31: The guest bootstrap and the guest alias driver [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/docker/Dockerfile`, `.dockerignore`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/GuestBootstrap.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Command.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Dependency/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`,
`core/hostbootstrap-core/test/GuestBootstrapSpec.hs`,
`demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/operations/demo_runbook.md`

#### Objective

Establish the project binary inside a pristine guest through the one guest-bootstrap vocabulary, publish the
exact provider/share dependencies, and let the guest alias hold and release its four ownership clauses through
the shipped project binary.

#### Deliverables

- The pristine-guest bring-up consumes the closed guest bootstrap vocabulary the
  [ensure-reconcilers phase](phase-8-ensure-reconcilers.md) owns: five ordered, separately probeable steps,
  each an argument vector, ending with the binary installed where the lift expects it.
- Because the step is probe-first, a re-run of a partially bootstrapped guest completes the steps that are
  outstanding instead of repeating the ones that are not.
- Linux Docker readiness includes the separately packaged Buildx plugin. Authenticated build #3 consumes one
  coordinator-created, `.hostbootstrap`-free core-plus-demo archive: the bytes hashed locally are the exact bytes
  transferred to and built inside the guest, and the builder digest has one canonical unprefixed form.
- With the binary established there, the guest alias holds its four clauses through the ownership seam,
  over the shipped row addressed at that frame — so the alias's identity is still read by the kernel that
  owns the object, and it is read by this binary.
- The shipped row stages the symbolic link and binds that exact device/inode identity in the durable record
  before atomic no-replace publication. Linux publishes a second name with `link(2)`; Darwin moves the same
  bound inode with `renamex_np(RENAME_EXCL)`, because APFS does not admit a hard link to a symbolic link.
  Both the bound-staging and bound-published interruption windows resume without adopting a pathname.
- The alias's durable record uses the shared record vocabulary, so a record written in a guest is readable
  by the host frame that owns the share.
- This is the sprint in which a frame crossing carries an ownership transaction for the first time, so it
  is where that row earns its live confirmation.
- The copy-source action runs only after the guest binary build, retains the VM descent, publishes the exact
  Provisioned share member and its closed runtime commitment after alias success, and forwards provider plus
  provider-share commitments as one bounded canonical bundle. The child rebinds each exact receipt through a
  distinct nonce-bound live service before cluster preconditions.
- Incus share readiness requires the declared guest target itself to be a writable `virtiofs` mountpoint before
  alias publication or child descent; a writable directory in the guest's underlying source tree is not share
  readiness and cannot race Docker's bind-source resolution. The owned share transaction activates a newly
  attached VM disk through one identity-checked restart before it binds and publishes that share.
- The VM provider publishes Running from its actual absent acquisition predecessor. The alias operation key is
  the full provider/share relation declared by the plan, and forward ordering remains bootstrap → shipped alias
  → provider/share dependency publication → child entry.
- Lifecycle routes place Lima's `--workdir` flag before the instance operand, matching Lima 2.x's command
  grammar instead of forwarding that flag to the guest shell. Harness reverse restores access only on
  non-symlink descendants of its exact virtiofs run share; it never attempts to chmod the Lima mountpoint.

#### Validation

`GuestBootstrapSpec`, `ProviderAliasSpec`, `OwnershipShippedSpec`, provider-dependency tests, and
`CommandsSpec` cover the five-step probe-first plan, Buildx readiness, deterministic build bytes, exact
provider/share bundle, full alias relation, ordering, settlement, retry, replacement-safe release, and shipped
POSIX ownership behavior. The complete core and demo host-static gates must pass. The live confirmation starts
from the retained pristine-guest state, creates the alias, completes child cluster descent, proves the alias
survives provider stop/restart, and releases it while the durable share remains intact.

On 2026-08-26, macOS arm64 passed the complete warning-clean core gate at 2,474/2,474 in 357.86 seconds,
`cabal build all` from `demo/`, and the complete warning-clean demo gate at 145/145.

#### Remaining Work

None. Completed on 2026-08-26 on macOS 26.5 arm64 with Lima 2.1.2, GHC 9.12.4, Cabal 3.16.1.0, and
`hostbootstrap` 0.1.0. The fresh Apple/Lima Harness run bootstrapped the project binary and Docker 29.1.3 in
each of four pristine guests, published the guest alias, completed child cluster descent, survived the
engine-owned same-run Destroy/recreate boundary for both variants, and released the provider on terminal
Destroy. Run `run-3ed8c816cf5d0` (`hello-world`) and run `run-3efa98a88f190` (`hello-universe`) contributed
five passing assertions each to the exact `10/10 passed` report. The terminal audit found no Lima instance,
generated sibling config, Harness durable root, or live accelerator ownership state; the operator test config,
project authority store, and build caches remained.

The earlier live evidence for the Incus path also remains part of this sprint's gate: on 2026-08-24, a fresh
Ubuntu 24.04 linux-cpu/x86_64 Incus run bootstrapped the project binary
inside a pristine guest, attached the exact host `.data` root as writable `virtiofs`, and completed cluster
descent. Before and after an explicit provider stop/start, `/var/tmp/hostbootstrap-demo-data` resolved to the
same owned host root, a write marker remained readable, and both installed activation-revision digests were
unchanged. Root-only `project destroy` then deleted the provider while preserving that durable root and marker.

### Sprint 24.32: Chart-declared service activation frame [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`
**Production modules**: `HostBootstrap.Step`, `HostBootstrap.Lifecycle.Plan`,
`HostBootstrapDemo.Commands` (3; cap 3)
**Sprint budget**: no new named type and no lifecycle call-site adoption; at most 400 production Haskell
lines. The existing chart declaration gains one exact canonical field.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/generic_project_model.md`,
`documents/operations/demo_runbook.md`

#### Objective

Make the derived service-runtime frame part of the exact plan-authored chart workload rather than asking a
later signer to infer it from the chart execution frame or mounted configuration bytes.

#### Deliverables

- `declaresChartWorkloadResource` retains the exact derived service activation frame beside workload identity,
  role, and effects; empty frames refuse during plan validation.
- `ChartWorkloadResource` and the neutral execution package carry that field without exposing a constructor or
  manufacturing it at reconciliation time.
- The canonical plan format hashes the activation frame, and the strict structural reader admits the
  corresponding ten-field chart record.
- The demo derives the declared frame through the same `renderServiceConfigForContext` projection used to
  render the mounted service wire and Helm values.

#### Validation

`ProjectPlanSpec` proves exact projection and that changing only the activation frame changes canonical bytes;
`CommandsSpec` proves the demo declaration consumes the same derived frame. Run the warning-clean core build,
focused plan gate, complete demo gate, and Sprint 24.30 live acceptance.

#### Remaining Work

None. Completed 2026-08-23. The warning-clean core build, focused `ProjectPlanSpec`, container
`fourmolu`/`hlint`, focused `CommandsSpec` 58/58, complete demo 142/142 gate, and repeated aggregate core gate
at 2,446/2,446 pass. The fresh linux-cpu run retained the exact declared activation frame through rooted
authorization and created its immutable activation revision before Helm entered the workload transaction.

### Sprint 24.33: Exact rooted activation-placement authorization [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/test/ChainSpec.hs`
**Production modules**: `HostBootstrap.Command.LifecycleEntry` (1; cap 3)
**Sprint budget**: no new named type and one activation-signing call-site correction; at most 200 production
Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/operations/demo_runbook.md`

#### Objective

Authorize activation only from an exact chart declaration in the admitted root or child-plan catalog, using
the service-runtime frame that declaration owns.

#### Deliverables

- The root derives one closed `(activation frame, plan digest, service, permitted effects)` placement from each
  admitted chart resource in the root plan and recursively admitted child plans.
- Signing requires the manifest frame to select exactly one placement and then requires exact plan digest,
  service, and filtered service-effect equality before the existing activation policy and broker can run.
- A lifecycle-plan frame without a chart-declared activation placement is not authority, and duplicate
  activation frames refuse rather than selecting one.

#### Validation

`ChainSpec` pins catalog-wide derivation from opaque chart resources and the exact manifest comparison. The
warning-clean core build and focused 46-case Chain gate must pass before the pristine live rerun.

#### Remaining Work

None. Completed 2026-08-23. The warning-clean build, focused Chain gate at 46/46, and repeated aggregate core
gate at 2,446/2,446 pass. In the fresh linux-cpu run the root accepted the chart-declared service frame,
published its signed immutable activation revision, and invoked Helm; no lifecycle frame or mounted config
bytes supplied signing authority.

### Sprint 24.34: Docker-host durable-root projection [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/ClusterConfig.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/ClusterConfigSpec.hs`
**Production modules**: `HostBootstrapDemo.ClusterConfig`, `HostBootstrapDemo.Commands` (2; cap 3)
**Sprint budget**: no new named type and one cluster-config call-site adoption; at most 200 production Haskell
lines. The existing owned guest alias becomes the canonical Docker-daemon mount source.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/operations/demo_runbook.md`

#### Objective

Render the Kind node's durable bind from the path interpreted by the Docker daemon rather than from the
project container's in-frame durable path.

#### Deliverables

- The exact cluster config keeps its state and config artifacts under the plan-owned in-frame durable root.
- Kind `extraMounts.hostPath` uses the existing owned Docker-host alias, whose target is the provider-shared
  durable root, while `containerPath` remains `/var/lib/hostbootstrap-demo-data`.
- The rendered Kind and nvkind bytes agree with the checked-in topology templates and do not expose a child
  container path to the sibling Docker daemon.
- The activation revision and service-authority directories created through the project-container mount are
  therefore visible inside the Kind node before Helm admits a workload that requires them.

#### Validation

`ClusterConfigSpec` pins the distinct in-frame state paths and Docker-host mount source. Run the focused demo
gate, complete demo gate, and repeat the fresh Sprint 24.30 linux-cpu sequence through a Ready web deployment.

#### Remaining Work

None. Completed 2026-08-24. The fresh Incus-backed Production run mounted the owned guest alias as the Kind
node's Docker-host source; the node saw the immutable web and accelerator activation revisions plus the shared
service-authority directory before both deployments reached `1/1 Running`. The alias remained the same writable
`virtiofs` projection across an explicit provider stop/start.

### Sprint 24.35: Helm 4 rollback and result contract [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/test/FakeCluster.hs`, `core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterWorkloadSpec.hs`
**Production modules**: `HostBootstrap.Cluster.Backend` (1; cap 3)
**Sprint budget**: no new named contract and one backend command correction; at most 100 production Haskell
lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/operations/demo_runbook.md`

#### Objective

Invoke Helm's supported rollback-on-failure contract without a deprecation warning, and classify Helm 4's
first-install status record without weakening the exact captured-command boundary.

#### Deliverables

- The chart reconcile command requests `--rollback-on-failure` and retains its explicit `--wait` readiness
  boundary.
- Successful Helm and Kubectl calls remain required to return an empty stderr stream; the backend does not
  weaken exact command-result classification to hide warnings.
- A first install is accepted only when Helm 4's exact install announcement is accompanied by the matching
  release name, deployed status, revision 1, and `Install complete` description. The prior supported install
  phrase remains admitted, while an incomplete status record is refused.
- The fake backend accepts only the supported command vector, so a return to the deprecated flag breaks the
  focused static gate, and it emits Helm 4's status shape so classifier drift breaks the workload gate.
- The live linux-cpu acceptance records Helm's version and reaches the Ready workload without a command warning.

#### Validation

`ClusterBackendSpec` and `ClusterWorkloadSpec` cover the exact chart reconcile vector, the Helm 4 first-install
record, and refusal of an incomplete record.
Run the warning-clean core build, focused backend gates, complete core gate, and repeat the fresh Sprint 24.30
linux-cpu sequence through a Ready web deployment.

#### Remaining Work

None. Completed 2026-08-23. The warning-clean core build, focused `ClusterBackendSpec` 32/32 and
`ClusterWorkloadSpec` 10/10 gates, complete core 2,446/2,446 gate, and governed-doc 2/2 gate pass. A fresh
linux-cpu run using Helm 4.2.3 settled the first-install status record without stderr and reached a 1/1 Ready
`hostbootstrap-demo-web` pod; the later accelerator-daemon step exposed the separate standalone-activation
gap.

### Sprint 24.36: Plan-authored standalone service activation placements [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`
**Production modules**: `HostBootstrap.Step`, `HostBootstrap.Lifecycle.Plan`,
`HostBootstrap.Command.LifecycleEntry` (3; cap 3)
**Sprint budget**: no new named type and one standalone declaration field; at most 240 production Haskell
lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

Let any exact plan step declare one service activation placement without pretending that every service is a
Helm-owned chart workload.

#### Deliverables

- `declaresServiceActivation` retains one exact activation frame, role, and non-empty unique effect row on an
  ordinary opaque `Step`; it does not retain runtime measurements or signing authority.
- Canonical plan format version 7 hashes a structurally exact standalone-activation list for every step.
- Admission rejects empty fields, duplicate effects, more than one standalone declaration per step, and an
  activation frame reused by either a chart or another standalone declaration.
- The rooted signing catalog derives placements from chart and standalone declarations in admitted root and
  child plans, then preserves the existing exact frame, plan-digest, role, and effect comparison.

#### Validation

`ProjectPlanSpec` proves canonical sensitivity and collision refusal. Run the warning-clean core build, focused
plan gate, and complete core host-static gate.

#### Remaining Work

None. Completed 2026-08-23. The warning-clean core build, focused three-case canonical/version/collision gate,
complete core 2,448/2,448 gate, and governed documentation gate pass. Canonical format version 7 retains the
standalone declaration and admission rejects activation-frame reuse across chart and standalone placements.

### Sprint 24.36a: Far-frame recorded exposure observation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Shipped.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ClusterShippedSpec.hs`
**Production modules**: `HostBootstrap.Cluster.Backend`, `HostBootstrap.Cluster.Shipped`,
`HostBootstrap.CLI` (3; cap 3)
**Sprint budget**: one opaque exposure-observation result and one read-only frame transaction; at most 400
production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cluster_lifecycle.md`,
`documents/architecture/composition_methodology.md`

#### Objective

Re-observe one recorded cluster service exposure inside the exact provider frame that owns its Docker engine,
without carrying a child-frame runtime witness into its parent.

#### Deliverables

- `HostBootstrap.Cluster.Backend` opens the protected exposure row for the exact cluster, refuses absent,
  pending, malformed, conflicting, or duplicate service facts, and re-observes the recorded relay's exact
  identity and loopback port mapping before returning the requested host port.
- `HostBootstrap.Cluster.Shipped` defines one bounded, closed, read-only request and response vocabulary for
  that observation. The request admits only an absolute POSIX state path, a valid cluster name, and one
  bounded service name; the response contains no Docker handle, ownership witness, or credential.
- The near-side function crosses only through `withFrameChildTransaction` and one already-derived lift
  context; its capability-restricted wrapper projects that context from the exact `ProviderCapability`.
  Providers whose lifecycle owns the route directly, including WSL2, supply the plan-selected provider lift.
  The far-side interpreter derives its host configuration locally and performs the backend observation there.
- The frame-child dispatcher distinguishes this request by its closed prefix and otherwise delegates to the
  shipped ownership interpreter, preserving one authenticated child entry surface.
- Focused tests cover canonical round trips, malformed and oversized refusals, wrong-identity and wrong-port
  rejection, exact service selection, interpreter fall-through, and child-process observation.

#### Validation

Run the warning-clean focused `ClusterBackendSpec` and `ClusterShippedSpec` gates, then the complete
warning-clean core host-static gate and governed-documentation gate.

#### Remaining Work

None. Completed 2026-08-26. The read-only backend observation, bounded frame vocabulary, shared frame-child
dispatcher, and focused gates are complete. `ClusterBackendSpec` passed 37/37, `ClusterShippedSpec` passed 8/8,
the public-consumer bind boundaries passed 2/2, the complete warning-clean core gate passed 2,474/2,474 in
430.34 seconds on macOS arm64, and the governed-documentation gate passed 2/2.

### Sprint 24.37: Accelerator service-activation adoption [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: no new named contract and one additional activation call-site adoption; at most 300
production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/accelerator_daemon.md`,
`documents/operations/demo_runbook.md`

#### Objective

Launch every accelerator placement through the same signed `service run` activation and concrete instance
boundary as the chart-owned web service.

#### Deliverables

- Linux accelerator steps declare their exact daemon activation placement and install a root-signed immutable
  revision for the measured in-cluster image and binary before applying the Deployment.
- The accelerator Deployment mounts the durable activation-revision and service-authority directories and
  supplies their fixed runtime coordinates.
- The pod obtains its own UID and exact container restart count through the chart-owned runtime service account
  before invoking `service run`; neither value is caller-authored configuration.
- Host-resident Apple and Windows accelerator steps declare the same placement, measure the copied daemon
  executable, install its verification key and activation revision beside durable state, and mint a fresh
  invocation nonce for each detached process.
- Before root descent, the rooted coordinator installs its already-admitted activation signer into the exact
  root Chain carrier. Child frames retain their relayed signer, while the same root carrier survives child close
  and supplies only signed grants to post-handoff activation; no signing key crosses a frame or enters plan
  bytes.
- After the deployment child frame closes, the Apple host-resident accelerator step reopens the exact owned
  provider and obtains its capability; the WSL2 route uses its plan-selected provider lift. Both use the
  far-frame observation transaction to recover the accelerator relay's freshly identity-checked loopback port,
  and neither expects the child's cluster runtime package to survive.
- Generated-manifest and chain gates fix the activation declarations, mounts, coordinates, and instance-qualified
  launch shapes.

#### Validation

Run focused `CommandsSpec` and `ChainSpec`, the complete demo gate, warning-clean demo build, formatter and
linter checks, and the complete core gate. The worked-demo live acceptance confirms the linux-cpu call site
through a Ready daemon and successful terminal `project up`; hardware acceptance phases confirm the
host-resident and GPU call sites.

#### Remaining Work

None. Completed 2026-08-26. Far-frame relay observation is adopted for the Apple and Windows host-resident
daemon launch. `CommandsSpec` fixes the Apple fresh-provider/capability route, the WSL2 plan-selected lift
route, and port-only endpoint consumption and passed 61/61. `ChainSpec` passed 48/48 with the exact root-carrier
signer binding, the complete warning-clean core gate passed 2,474/2,474 in 357.86 seconds, and the complete
warning-clean demo build and 145/145 gate passed on macOS arm64. Each of the four live pristine-image builds
passed the image's in-container `check-code`; the Apple/Lima Harness gate reported `10/10 passed`, and all four
post-handoff host daemons reached Ready through the root-signed activation carrier and far-frame exposure.
The published base digest was
`sha256:3634916e85b1fda411ae671a4bca2f72745e0bd106e2e9efebccc25415e0bc49`; the four derived-image digests were
`sha256:c5558991213ee0e6e5aba5f161a3ad4d1d4356582e3d7347f6da87ad6a7d61ec`,
`sha256:fa0f37a5b15a874f018ac72e1a707e16e220ebb2c6bccf24c334760eebf1dde2`,
`sha256:3968f151dc0b59c135afc795d0d1dc99c02c3195a7ec2077a2116b1cdc7d0b66`, and
`sha256:024a9bfaec30e47c81e8cf4f49ce1d2a34c9b1631d3a8f0b6e777c34c2f5c212`.

### Sprint 24.38: Declarative same-run durable readback [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: no new named contract and one assertion-policy adoption; at most 120 production Haskell
lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`,
`documents/engineering/testing.md`, `documents/operations/demo_runbook.md`

#### Objective

Prove durable state by reading it after an engine-owned settled destroy and fresh invocation of the same
Harness run, without giving project assertion code lifecycle authority.

#### Deliverables

- `durable-readback` declares `AssertAcrossRestart`; the other four cases run only before restart.
- `BeforeRestart` writes the marker through the live Docker/cluster route and verifies the Docker-host alias.
- The Harness engine owns intermediate destroy, fresh broker generation, exact snapshot/plan rebind, and the
  second forward; the assertion callback receives only `AfterRestart`.
- `AfterRestart` reads the same marker through the recreated workload and host alias, retaining one report row.
- Both configured variants therefore retain exactly five rows and the complete matrix remains exactly 10 rows.

#### Validation

The command-level core fixture proves real protected generation rotation and exact plan rebind; `HarnessSpec`
proves one-row phase merging; `CommandsSpec` fixes the demo policy and phase-specific operations. The live
linux-cpu Harness run must report 10/10 after performing both same-run generations.

#### Remaining Work

None. The implementation and focused core restart gate pass. Sprint 24.41 owns the fresh live Harness matrix
that confirms this same-run transition on linux-cpu.

### Sprint 24.39: Non-empty derived-image executable [Done]

**Status**: Done
**Implementation**: `demo/docker/Dockerfile`, `demo/test/CommandsSpec.hs`
**Production modules**: none; the Dockerfile is the one build call-site adoption
**Sprint budget**: no new named contract; one Dockerfile build/runtime-artifact correction.
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/derived_dockerfile.md`,
`documents/engineering/derived_project_standards.md`, `documents/operations/demo_runbook.md`

#### Objective

Make successful derived-image construction prove both the in-image source build and the exported runtime
entrypoint, without depending on BuildKit to snapshot the in-container linked Cabal product.

#### Deliverables

- The final source build uses the same `--ghc-options=-Werror` configuration as the authenticated code-check
  gate that precedes it, so one Docker build tree is not reconfigured under conflicting GHC option sets.
- The Dockerfile binds the exact `cabal list-bin` result and requires the in-image source build to be non-empty.
- The source-built, digest-bound authenticated builder occupies a build-only libexec path. After the web build,
  the Dockerfile copies its bytes with `dd` into a new regular `/usr/local/bin/hostbootstrap-demo` file, removes
  the build-only authority, final-materializes the config, public keys, and web bundle, and requires every
  runtime-critical artifact to be non-empty. The coordinator repeats those checks against the exported image.
- The post-bootstrap `copy-source` continuation re-mints the ephemeral VM-provider witness only after the exact
  share and guest alias have settled, because Incus virtiofs attachment stop/starts the guest and clears `/run`.
- The reference derived-project documentation carries the same warning-clean, final-materialized authenticated
  runtime artifact, config/key/web materialization, and exported-image probe shape.

#### Validation

`CommandsSpec` fixes authenticated stage order, the final warning-clean build, web build, runtime artifact
materialization, the exported-image probe, and the post-share witness ordering. The fresh linux-cpu
Production image build must report a non-empty installed binary before authenticated handoff and complete the
full workload sequence.

#### Remaining Work

None. Completed 2026-08-24. A fresh Production build pulled base digest
`sha256:6254553581475f9f54bd2538d4d5a7ba8528732dabb7c437609014ff56a6aead`, produced derived manifest
`sha256:f5939eb9716a610fbc6e2010392911c2d8eb59df63f6d008bb39e6d0d2730e5b`, and exported a non-empty
80,028,904-byte `/usr/local/bin/hostbootstrap-demo`. The final config (2,579 bytes), both public keys
(32 bytes each), and web bundle (102,333 bytes) were also non-empty before authenticated handoff and the
complete workload sequence succeeded.

### Sprint 24.40: Authenticated reverse-child cluster release [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command/Child/Reverse.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Teardown/Executor/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Production modules**: `HostBootstrap.Command.Child`, `HostBootstrap.Command.Child.Reverse`,
`HostBootstrap.Teardown.Executor.Internal` (3; cap 3)
**Sprint budget**: no new named contract and one authenticated reverse-child call-site adoption; at most 120
production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/testing.md`,
`documents/operations/demo_runbook.md`

#### Objective

Make callback-free reverse work execute its core-owned retained cluster action in the authenticated child frame
and preserve exact Production/Harness profile identity.

#### Deliverables

- The storeless executor delegates callback-free work to one caller-owned core reverse action instead of
  manufacturing a released observation.
- The authenticated child derives `production` or `harness:<run-id>` only from the verified handoff scope and
  uses that exact admitted profile to derive retained cluster ownership.
- `DeleteCluster` releases the exact recorded exposure before the retained cluster; a failed release remains a
  failed teardown observation.
- A callback-free non-core node is terminally foreign-retained because the current frame acquired nothing it can
  release.
- The reverse action is a Cabal-private module within one 400-line sprint budget; no root store, broker, signing
  key, lifecycle authority, or caller-selected cluster identity enters it.

#### Validation

`HandoffSpec` fixes callback delegation, exact profile derivation, exposure-before-cluster order, non-core
classification, private-module ownership, and the line budget. `ProjectPlanSpec` fixes the third sealed
reverse-cursor use and preserves the existing child owner's two-sprint attribution. The focused gates and the
complete warning-clean core gate must pass.

#### Remaining Work

None. Completed 2026-08-24. The complete core host-static gate passed 2,457/2,457 under `-Werror`; the reverse
child source guard proves the private action is the only core callback, and the live Sprint 24.41 run confirms
its retained-cluster release in four fresh child generations.

### Sprint 24.41: Harness recursive-lifecycle acceptance [Done]

**Status**: Done
**Implementation**: no production change; evidence in this phase and `documents/operations/demo_runbook.md`
**Production modules**: none (0; cap 3)
**Sprint budget**: no new named contract, no call-site adoption, and zero production Haskell lines.
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/testing.md`,
`documents/operations/demo_runbook.md`

#### Objective

Confirm the complete two-variant recursive Harness matrix after every worked-demo capability is present.

#### Deliverables

- Each variant performs pristine recursive Up, all five assertions, settled child-first Destroy, a protected
  fresh same-run generation, recursive Up, durable readback, and terminal close.
- Every pristine generation pulls the published rolling base by repository digest and builds its derived image
  without Docker layer-cache reuse.
- The report is exactly ten rows and the terminal audit finds no provider VM, cluster, workload, generated run
  config, or Harness durable root; the operator-owned test config remains.
- Dated evidence records the gate host, toolchain, duration, run IDs, base digest, and all derived image digests.

#### Validation

Run `hostbootstrap run -- test run all` on a fresh disposable linux-cpu host and require exactly `10/10 passed`.
Then audit the provider and filesystem end state and repeat the core, demo, and Python host-static gates.

#### Remaining Work

None. Completed 2026-08-24 on the disposable `hostbootstrap-phase24-cpu-host` gate host: Ubuntu 24.04.4 LTS,
Linux 6.8.0-138-generic x86_64, Incus 6.0.0, Docker 29.1.3, Python 3.12.3, GHC 9.12.4, Cabal 3.16.1.0, and
`hostbootstrap` 0.1.0. The fresh Harness command completed in 105m12.680s and reported exactly `10/10 passed`.
Both `hello-world` (`run-6d81c1594f58`) and `hello-universe` (`run-7059dc5c98eb`) performed write → settled
Destroy → fresh Up → read within one run.

Every one of the four pristine generations pulled published base digest
`sha256:6254553581475f9f54bd2538d4d5a7ba8528732dabb7c437609014ff56a6aead`; their derived image digests were
`sha256:d2c003d48ca746e60d9ca96fb20422dca2b65184e09c33f8660c1c81e3df238e`,
`sha256:c3d185248323121a63b937ae2122020b469eecf824e225035d49bcbe1719d98f`,
`sha256:72a2064bc698e59832dd0f5f4792323d36dc4b5e3fbecf8539dd3b161cdfe7b0`, and
`sha256:c274ee1ecb7898acccc74eb7e5ab8b89432eaf9e6b126379c9722ed735dac615`. The terminal audit found no
`hostbootstrap-demo-vm`, no Harness `.test_data`, and no generated `hostbootstrap-demo.dhall`; the
operator-owned `hostbootstrap-demo.test.dhall` remained. The post-run gates passed core 2,457/2,457, demo
145/145, Python 231/231, and Python coverage 1,331/1,331 statements.

## Remaining Work

None. Phase 24 is complete. The Production lifecycle, exact authenticated recursive reverse path, distinct
automatic service exposures, pristine guest alias, Docker-host durable projection, concurrent signed roles,
non-empty derived image, and two-variant same-run durable recreate are statically and live confirmed on
linux-cpu. The 2026-08-26 Apple/Lima run supplied the remaining native and in-container evidence at exactly
`10/10 passed` and ended with an empty live-runtime audit. NVIDIA-, Windows-, and cross-family
host-portability confirmation belongs only to Phases 26–28.

No sprint transports a Managed/Running/Readiness witness, handle, authentication key, executable selector, or
raw probe in canonical bytes or a generic resource carrier. The two invocation-owned registries have separate
roles: canonical packages contain commitments and bounded client routes; opaque live services contain backend
closures and die on failure, retry, Process close, or fresh invocation. Share and alias settle lexically inside
one copy-source action before `Chain` continues. Direct reverse terminalizes its journal reservation and reports
physical stop/delete `Unsupported`. Phase 22 remains only the lower activation/`service run` dependency and does
not own the demo chart call site.

## Documentation Requirements

**Architecture docs to create/update:**

- `documents/architecture/network_reachability.md` — runtime-owned loopback exposure and resolved endpoints.
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
