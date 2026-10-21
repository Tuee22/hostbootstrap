# Phase 24 — The worked demo

**Status**: Done
**Depends on**: Phase 16 (provider, cluster, and guest lifecycle foundations), Phase 17 (proof-complete
recursive lifecycle command), Phase 22 (service-runtime activation and `service run` semantics), Phase 23
(base image publication and the opportunistic warm store)
**Substrates**: linux-cpu
**Gate**: `cabal build all` and `cabal test hostbootstrap-demo-test` from `demo/`, the
core host-static gate from `core/`, plus live
`hostbootstrap run -- project up`, `hostbootstrap run -- project down`,
`hostbootstrap run -- project destroy`, and `hostbootstrap run -- test run all` reporting `10/10 passed`
inside the universal `linux-cpu` realization on any supported outer host
**Gate kind**: deferred
**Gate evidence**: 2026-10-20 ; `MacBookPro`, native arm64 macOS 26.6.2 (build 25G83),
Apple M1 Max, 64 GiB memory, GHC 9.12.4, Cabal 3.16.1.0, Poetry 2.3.2, Python 3.14.3,
live universal `linux-cpu` realized through native VZ/aarch64 Lima 2.1.2 guests ;
`cabal build all` and `cabal test all` from `core/`,
`cabal build all -j1`, `cabal test all`, and
`cabal test hostbootstrap-demo-test --test-show-details=direct --test-options=--hide-successes`
from `demo/`, `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` from the repository root,
plus repository Python-bootstrapper
`poetry run hostbootstrap run --project-root demo project init`,
`poetry run hostbootstrap run --project-root demo project up`,
`poetry run hostbootstrap run --project-root demo project down`,
`poetry run hostbootstrap run --project-root demo project destroy`,
`poetry run hostbootstrap run --project-root demo test init`, and
`poetry run hostbootstrap run --project-root demo test run all`
reporting `10/10 passed`, followed by terminal ownership,
Production-data preservation, ambient-state, and covered-source audits ;
pass ; covers 0b27634921cf2e486ef70fcefcc27943206f30197760b685a60ec81d247f80e7
**Evidence covers**: `.dockerignore` `.hlint.yaml` `core/cabal.project` `core/hostbootstrap-core/app` `core/hostbootstrap-core/dhall` `core/hostbootstrap-core/hostbootstrap-core.cabal` `core/hostbootstrap-core/internal` `core/hostbootstrap-core/provider-live` `core/hostbootstrap-core/src` `core/hostbootstrap-core/test` `demo/app` `demo/cabal.project` `demo/chart` `demo/docker` `demo/hostbootstrap-demo.cabal` `demo/kind.yaml` `demo/nvkind-in-cluster.yaml` `demo/playwright/package.json` `demo/playwright/playwright.config.ts` `demo/playwright/tests` `demo/src` `demo/test` `demo/web/spago.yaml` `demo/web/src/Main.purs` `demo/web/src/index.js` `fourmolu.yaml` `hostbootstrap` `pyproject.toml` `tests`

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
`demo/test/CommandsSpec.hs`, `core/hostbootstrap-core/test/compile-fail/`
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
`core/hostbootstrap-core/test/CLISpec.hs`, `demo/test/CommandsSpec.hs`
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
- One exact demo owner receives distinct runtime-assigned loopback ports for its registry, web, S3 store, and
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
- The reverse adapter consumes `RetainResource` on Down without releasing the alias or its ownership row;
  Destroy consumes `ReleaseResource` and gives back the exact link after child teardown.
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

None. On 2026-09-09, the current core and demo gates pass, and the fresh Windows/WSL Production
Up/Down/Destroy sequence passes. After Down and a cold restart, the alias retains device/inode
`2096:217048`, the exact target, and the exact ownership-record hash. Destroy releases the alias row
and removes the provider while preserving the host marker. Sprint 24.42 records the commands,
timings, image digest, and terminal audit.

Dated evidence on 2026-08-26 on macOS 26.5 arm64 with Lima 2.1.2, GHC 9.12.4, Cabal 3.16.1.0, and
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
- `BeforeRestart` writes the marker through the live Docker/cluster route and verifies the exact
  run-profile durable root in the assertion frame.
- The assertion environment derives the exact profile from the admitted canonical project root and
  retains its provider projection for marker readback and diagnostics in that frame.
- The Harness engine owns intermediate destroy, fresh broker generation, exact snapshot/plan rebind, and the
  second forward; the assertion callback receives only `AfterRestart`.
- `AfterRestart` reads the same marker through the recreated workload and exact durable root, retaining one report row.
- Both configured variants therefore retain exactly five rows and the complete matrix remains exactly 10 rows.

#### Validation

The command-level core fixture proves real protected generation rotation and exact plan rebind; `HarnessSpec`
proves one-row phase merging; `CommandsSpec` fixes the demo policy and phase-specific operations. The live
linux-cpu Harness run must report 10/10 after performing both same-run generations.

On 2026-10-16, the native Linux/NVIDIA matrix reports `8/10 passed`: both variants' durable
readback rows read the absent VM-only alias, while their exact host and node roots contain the marker.
The correction derives the profile root from the admitted generated config, projects it through the
selected provider, and retains the resulting path in the assertion environment for both phases.
`CommandsSpec` adds two behavioral cases for Direct/Lima/Incus, both Windows lanes, Production,
distinct Harness runs, drive separators, and roots containing spaces. All 77 focused cases pass,
as do Fourmolu 0.19.0.1 and HLint 3.10 on both changed files.
The source adoption remains within one production module and the sprint's 120-line budget.

The complete corrected-tree host static gate passes on `matt-caledon-desktop`, native x86_64
Ubuntu 24.04.5 LTS, Linux 7.0.0-38-generic, GHC 9.12.4, Cabal 3.16.1.0, Poetry 1.8.2,
and Python 3.12.3. From `core/`, `cabal build all` and plain `cabal test all` pass, including
2,552/2,552 cases in 231.98 seconds. From `demo/`, `cabal build all` passes in 22.12 seconds;
plain `cabal test all` passes 161/161 demo cases in 2.23 seconds and 2,552/2,552 core cases in
235.92 seconds (240.35 seconds for the workspace command). The exact unfiltered
`cabal test hostbootstrap-demo-test` passes 161/161 in 1.37 seconds (3.72 seconds for the command).
Both provider-live components return their declared no-request `Unsupported` result. The repository
Python code check passes, and `poetry run python -m hostbootstrap.test_all` passes 251/251 in
2.04 seconds. Both edited files retain LF, and `git diff --check` passes. Before/after measurements
over the 29 roots and 862 files agree at
`2270a6319a8e5bc12c64b9edf057f031f79ba673af2677a9cfcf001b3551d11b`.

#### Remaining Work

None. The complete live `linux-cpu` confirmation is owned by Sprint 24.50.

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

### Sprint 24.42: The live demo matrix run [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the dated live demo lifecycle and matrix run inside the universal linux-cpu realization.

The claim this sprint makes is about the universal floor, whichever outer host realizes it. Where that
host is Windows, the additional Windows-only wall, ownership, and accelerator behavior the same run
exercises is owned by the
[Windows and WSL2 substrate phase](phase-27-windows-and-wsl2-substrate.md), not asserted here.

#### Deliverables

- one dated run of `hostbootstrap run -- project up`, `project down`, `project destroy`, and
  `test run all` reporting `10/10 passed`, naming its host.

#### Validation

The gate host is native x86_64 Windows 11 Home 10.0.26200 with an AMD Ryzen 7 5700G, 15.87 GiB of
host memory, and an NVIDIA GeForce RTX 3090 on driver 616.64. Its toolchain is GHC 9.12.4,
Cabal 3.16.1.0, Poetry 2.4.1, repository-venv Python 3.14.7, Docker CLI 29.6.1, and WSL 2.7.10.0 on
kernel 6.18.33.2-2. The universal `linux-cpu` realization is the WSL2 Linux guest the provider owns.

The current-source static preflight passes on that host. From `core/`,
`cabal test all --ghc-options=-Werror` passes 2,500/2,500 in 329.88 seconds, and the provider-live
component reports its declared no-request `Unsupported` outcome. From `demo/`,
`cabal build all --ghc-options=-Werror` is warning-clean and
`cabal test hostbootstrap-demo-test --ghc-options=-Werror` passes 149/149 in 5.40 seconds. From the
repository root, `poetry run python -m hostbootstrap.check_code` passes and
`poetry run python -m hostbootstrap.test_all` passes 235/235. The 46-file covered source measures
`bead951148f4b26e04c53272877c55c4f80539619efd081335bdeea7367846dd`.

The fresh Production sequence runs through the repository Python bootstrapper against that same
covered source. The generated config declares 6 CPUs, 10 GiB memory, and 80 GiB storage and measures
SHA-256 `5ec0092759c6818db0879c97399f5f33f345062781adf06d5e8214378fbb0a22`. The three canonical
commands are `poetry run hostbootstrap run --project-root demo project up`, `project down`, and
`project destroy`; each uses the harness-owned durable Windows launcher.

| Command | Result | Duration |
|---------|--------|----------|
| Up | exit 0 | 3,542.59 s |
| Down | exit 0 | 33.30 s |
| Destroy | exit 0 | 12.61 s |

Up builds the native project inside a fresh Ubuntu 24.04.4 WSL guest, pulls published CPU/amd64 base
digest `sha256:e46fb5699af246dc631704cd9bba5020776a7e96fbba1f4c450b5b9971ffb9d5`, and builds derived
image `sha256:866175c5db3841f4019f19e82e7d183be57e6f3f3f556950dcc2eda9fc835122`. The in-image quality
gate and the exported runtime, config, key, and web checks pass. The kind control plane and the exact
exposure relay run; web, MinIO, and registry pods are Ready and their health endpoints return HTTP 200.
The budget endpoint reports 6/10/80 and `Hello, world!`, the durable endpoint reads the preserved
marker, and the Windows accelerator returns 5 for 2 + 3 with backend `windows-gpu` and artifact hash
`fc76cd884d2539b8`. Down stops the daemon and utility VM and restores the original wall bytes; an
explicit cold guest restart observes the same alias device/inode, target, ownership record, and durable
marker. Destroy removes the distribution, Production mode, and alias ownership row, closes the lease at
epoch 8, and leaves the reverse intent terminal at version 6.

The complete Harness matrix then runs against the same covered source. The harness `test init` entry
writes `.build/hostbootstrap-demo.test.dhall`, which declares the same 6/10/80 resources and the two
stable variants and measures SHA-256
`8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`. The repository Python
bootstrapper's complete-matrix entry, launched through the harness-owned durable Windows launcher,
starts at 2026-09-11 01:28:44 UTC, exits 0 at 04:26:15 UTC after 10,651 seconds (2 hours 57 minutes
31 seconds), and reports exactly `10/10 passed`. Both `hello-world` (`run-7a1188be2e68`) and
`hello-universe` (`run-7eeb3f4ea634`) pass pristine bootstrap, web build, end-to-end tabs, registry
persistence, and durable readback; each durable-readback case crosses settled destruction and fresh
same-run cluster recreation before reading its retained bytes.

The matrix performs four pristine generations, one per fresh WSL2 guest, at global wall fences 23, 24,
25, and 26. Every generation installs a fresh Ubuntu 24.04 distribution, pulls published CPU/amd64 base
digest `sha256:e46fb5699af246dc631704cd9bba5020776a7e96fbba1f4c450b5b9971ffb9d5` without Docker
layer-cache reuse, and builds its own derived image:

| Variant | Generation | Derived image digest |
|---------|------------|----------------------|
| `hello-world` | 1 | `sha256:8997e96ad7e45b71d888b1d51b80227c6e79540cac96ebb4a474cfcac851032d` |
| `hello-world` | 2 | `sha256:de2d2bcfa28c033d6f0d46339021cb6e7181a04f82ca153f9a2ca55b79648a8b` |
| `hello-universe` | 1 | `sha256:0c872c258e4cc260e87219bcb0fb00b163e5bfc6218956087d9c5f1414da685a` |
| `hello-universe` | 2 | `sha256:9e388ac4f0c17d23393824b6db4886bde36f300f3914a76cd706305e9e3f33d8` |

The terminal audit finds both leases `closed`, at epochs 4 and 8, and both profiles `available`. No
project mode, generated-config, or data-root record remains. The generated
`.build/hostbootstrap-demo.dhall` is gone while the operator-owned
`.build/hostbootstrap-demo.test.dhall` remains at its exact hash; `.test_data` exists and is empty and
neither run data directory survives. No WSL distribution is installed, the utility VM is stopped, and no
demo daemon or detached matrix process runs. The global wall is released and `.wslconfig` holds its exact
original SHA-256 `2986099d4e292abed1bacbf7b7cb514188bad4304f930800803a85470ee4e694`. The terminal 46-file
source measurement still matches the in-run
`bead951148f4b26e04c53272877c55c4f80539619efd081335bdeea7367846dd`.

#### Remaining Work

None. The dated run above is complete: the Production sequence, the `10/10` matrix, the terminal
ownership audit, and the matching source measurement.

### Sprint 24.43: The demo's daemon claims are protected-store entries [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/architecture/ownership_invariant.md`

#### Objective

The run-ownership module records, in its own header, that it exists to replace a bare directory-creation
lock whose crash left two directories behind with nothing to distinguish a dead predecessor from a live
one, and an operator had to remove both by hand. The demo holds two of those locks. A hard kill of
`project up` leaves them and wedges every subsequent run — the exact failure the ownership work was done
to remove. The protected store is already imported by this module.

#### Deliverables

- Both daemon claims become protected-store entries, so a dead holder is released by the kernel rather than by hand.
- The nine accessors that each append one suffix to one directory become one function taking the suffix.
- A stale entry from a killed predecessor is resolved by the sweep rather than by a message telling an operator which directories to delete.

#### Validation

The host static gate for the claim construction. The behavioural confirmation — kill the run, then
start another and observe it proceed — belongs to the acceptance phase that declares the hardware, not
to this sprint.

#### Remaining Work

None, beyond the behavioural confirmation this sprint does not own. The lifecycle *operation* is now
`withProtectedEntry` over a store in the daemon's own directory: an OS-released exclusive lock spanning
the whole bracket, so a hard kill releases it in the kernel and the next run proceeds rather than
refusing with a directory name for an operator to delete. The *ownership* claim outlives the process —
the daemon keeps running after `project up` returns — so it is a compare-and-swapped record rather than
a lock, written under that same operation entry, with `ExpectAbsent` refusing a second live holder and
`hostAcceleratorDaemonOwned` answering the pid/ownership consistency check the cleanup already made.
Nine one-line path accessors became one function taking the suffix; two of the nine were the claims and
are not files at all now. `CommandsSpec` pins all of that, and the demo suite passed 151/151.

The kill-and-restart confirmation is owed by the substrate acceptance that declares the host: the daemon
runs only on Apple Silicon and Windows/GPU, so no `linux-cpu` gate reaches it.

### Sprint 24.44: The demo's cluster configuration and tool paths are its own [Done]

**Status**: Done
**Implementation**: `demo/kind.yaml`, `demo/src/HostBootstrapDemo/Commands.hs`,
`demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/derived_project_standards.md`

#### Objective

Two of the three cluster configurations are byte-identical apart from their comments, while the
selector branches three ways — so one branch is a distinction the YAML does not make. Separately, the
container path of the base image's formatter and linter is a constant the bootstrapper owns and the
demo re-spells as two literals, which is both a duplication across languages and the reason the demo's
own code-check can only ever run inside the image.

#### Deliverables

- The selector branches once per configuration that differs, or the configurations are made to differ for the reason the branch claims.
- The drift guard that counts mount lines in those files is updated with them.
- The style-tool location reaches the demo through the configuration seam rather than as a literal.
- The demo's code-check resolves its tools on a host as well as in the image.

#### Validation

The host static gate, plus this phase's demo suite.

#### Remaining Work

None. `kind-in-cluster.yaml` is deleted and the selector branches twice, once per template that differs:
the two files were byte-identical apart from their comments, so the third branch was a distinction the
YAML did not make and a reader had to open both files to discover it. `kind.yaml`'s comment now says it
serves both lanes and why — neither reserves a host port, so neither needs a cluster of its own. The
drift guard that counted mount lines in the deleted file is gone with it, and the selector case now
asserts that the in-cluster and host-resident contexts choose the same template rather than naming two.

`demoCheckCode` resolves `fourmolu`, `hlint` and `cabal` by name on `PATH`. Two of the three literals it
replaced re-spelled `HASKELL_STYLE_TOOLS_DIR`, which the Python bootstrapper owns and passes as a build
argument and which the base image puts on `PATH`; the third named a GHCup layout. The constant stays
owned in one place, the demo no longer restates it in a second language, and the verb now runs on a host
that has the three tools as well as inside the image. The demo suite passed 151/151.

### Sprint 24.45: The worked-demo gate against the current tree [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Record the complete worked-demo gate against the current covered tree. The host realizes the universal
`linux-cpu` baseline through its supported provider; a Direct Linux GPU run exercises a different lane.

#### Deliverables

- The declared gate runs in full: both demo Cabal legs, the core host-static gate, and the live
  `project up`, `project down`, `project destroy` and `test run all` legs.
- A gate-evidence row records the gate host, the commands as run, and the case total.
- The covers digest is re-measured over this phase's own paths and recorded.

#### Validation

The phase's own gate. It brings up real provider, Docker and cluster state on the host that runs it.

The gate ran in full on 2026-09-14, on the gate host the row above names. Its recorded source digest
precedes the current lifecycle short-close correction, so a complete new run is owed.

The `linux-cpu` gate host is a guest VM, because this machine reports `/dev/nvidiactl` and
`/proc/driver/nvidia/version` and therefore realizes `linux-gpu` on metal. The guest was created with no
provider installed, so the chain's own `ensure` step installed Incus inside it — which is what exposed
the two repairs this run also confirms.

The Production sequence:

| Command | Result | Duration |
|---------|--------|----------|
| `project init` | exit 0 | 1,012.69 s |
| `project up` | exit 0 | 2,527.69 s |
| `project down` | exit 0 | 18.56 s |
| `project destroy` | exit 0 | 31.88 s |

`project init` writes the sibling config, which measures SHA-256
`b949ceb3c943ec9b04206b4cbdd2fcf8d2a80da03236745450556c60ae2dcae1`; its duration is the cold host-native
build of the project binary inside the guest, not the command's own work. Up provisions the Incus guest,
builds the binary there, pulls published CPU/amd64 base digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`, and builds derived image
`sha256:37c013915c0999fa055fcdf055ef649cbb309f2c7462869d398947363ad4ebab` before descending into it for
the cluster, registry, workload and web service. Down stops the guest through its retained ownership
record. Destroy then reports
`project destroy: starting hostbootstrap-demo-vm so its retained children can be reached`, unwinds every
retained child through the frame it reopened, and deletes the guest — the observable the reachability
repair exists to produce, and the exact point at which the same sequence failed before it.

The complete Harness matrix then ran against the same covered source, from 18:34:50Z to 21:14:25Z:
exit 0 after 9,574.61 seconds (2 hours 39 minutes 35 seconds), reporting exactly `10/10 passed`. Both
`hello-world` (`run-3546b7b4d7f`) and `hello-universe` (`run-7bade736622`) passed pristine bootstrap, web
build, end-to-end tabs, registry persistence, and durable readback; each durable-readback case crossed a
settled destruction and a fresh same-run recreation before reading its retained bytes. The four pristine
generations each built their own derived image:

| Variant | Generation | Derived image digest |
|---------|------------|----------------------|
| `hello-world` | 1 | `sha256:34e7966ebf4e6a47d0ca4d414b1e72cce3eba586160e74ac911542c973963e1f` |
| `hello-world` | 2 | `sha256:cd97972a87414af4b26234083e5b368b4c948d8239afb3866042e6c4d0a2c042` |
| `hello-universe` | 1 | `sha256:14f6bdab08eba4ac8085b689ce46ccd897f2d897f02218afd272b58c4f8ebca2` |
| `hello-universe` | 2 | `sha256:7118d37280fb8ff373c21201bea52c545d77ee11d936919b89f586f43c841eaf` |

The terminal audit is clean: `incus list` reports no instance, the generated
`.build/hostbootstrap-demo.dhall` is gone while the operator-owned
`.build/hostbootstrap-demo.test.dhall` remains at
`8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`, and `.test_data` exists and is empty.
`kind` and `docker` are absent from the gate host's own `PATH`, which is correct for this lane: both live
inside the guest the run created and deleted.

On 2026-09-16, the complete native Windows static gate passes against the short-close correction:
`cabal build all` and `cabal test all` from `core/` (2,543/2,543), `cabal build all`,
`cabal test hostbootstrap-demo-test` (151/151), and `cabal test all` from `demo/`
(151/151 plus 2,543/2,543 core cases), plus the repository Python code check and 251/251
Python tests. The host and command options are recorded in Sprint 17.57. The post-closure documentation
validator passes 11/11 in 6.19 seconds. Production initialization through the repository Python
bootstrapper and harness-owned durable Windows launcher succeeds at 20:33:23 UTC in 27.64 seconds.
Its generated Production config measures SHA-256
`5ec0092759c6818db0879c97399f5f33f345062781adf06d5e8214378fbb0a22` and declares 6 CPUs,
10 GiB memory, and 80 GiB storage. The independently provisioned Linux host also passes every static
gate leg, as recorded in Sprint 28.5, and is removed before Production bring-up begins.
The same durable launcher runs the repository Python bootstrapper's complete Production sequence:

| Command | Result | Duration |
|---------|--------|----------|
| `project up` | exit 0 | 2,618.06 s |
| `project down` | exit 0 | 15.38 s |
| `project destroy` | exit 0 | 9.82 s |

Up runs from 20:39:44 UTC to 21:23:22 UTC. It creates a fresh WSL2 guest at wall fence 31, pulls
published CPU/amd64 base digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`, and builds image
`sha256:11755765a487337268d3fa68d63fc48711672570b96f2c531507bddda6e4a3ef`.
The image quality gate, web build, exported-runtime verification, unmodified Kind import, registry
push, and web exposure pass. The hidden native Windows accelerator daemon becomes ready at a
loopback-only endpoint. Down restores the original wall before stopping the guest; destroy removes
the stopped guest and exits at 21:23:47 UTC.

The terminal Production lease is `closed` at epoch 11 and no project mode remains. The daemon and WSL
distribution are absent, no active wall record remains, and the original `.wslconfig` hash is restored.
The operator test config retains its exact hash. Production durable data remains, as `destroy` intends.
The runbook's disposable Production-config removal is performed only after its original hash is checked;
the idle WSL utility VM is then shut down before the complete Harness matrix begins.
The complete matrix starts at 21:26:26 UTC with `hello-world` run `run-6e2eb13b6da4`, wall fence 32.
It exits 1 at 22:08:19 UTC after 2,512.69 seconds with `0/12 passed`: an invalid tar header during
Kind image extraction causes failed bring-up, and the corrected close check preserves the unresolved
run instead of releasing its mode. Sprint 27.5 records the image, layer, retained lease, and wall audit.

The final session-journal and canonical-resource corrections pass the complete Windows static gate,
recorded in Sprint 28.5: core 2,547/2,547, demo 151/151 plus 2,547/2,547 core cases, Python code
checks, and 251/251 Python cases. The independent x86_64 Linux gate also passes: 2,552 core cases,
151 demo cases, both Python legs, and the complete demo workspace. The focused demo gate passes
all 151 cases on both platforms. The 46 covered
files now measure `281a2cd1e6247562ae90d3edb1738daa0b498b6c9072c6a382b296ab31e63f5c`.
The normal harness recovery retry at 23:01:51 UTC closes the abandoned session but retains its
unsettled canonical provider/share ownership and Harness mode. It exits 1 with `0/10 passed`, all
refused, after 26.52 seconds. That retained mode also excludes a fresh Production cycle. No complete
current-source live gate is claimed; the previous Production pass predates these corrections.

On 2026-09-17 UTC, the native Linux visit validates the settled working tree on `matt-junction`
and its existing `hb-linux-cpu` gate VM. All 976 tracked working-tree files are copied and verified
byte-for-byte before the live gate. The native host passes `cabal build all` from `core/` and `demo/`,
the focused demo suite (151/151), and the complete host static gate after the real-kernel replacement
fixture corrections in phases 14 and 19: core `cabal test all` passes 2,552/2,552 in 176.58 seconds;
the demo workspace passes 2,552/2,552 core cases in 175.82 seconds plus 151/151 demo cases in
0.69 seconds; the repository Python code check and 251/251 Python tests in 1.65 seconds pass.
The VM reports `substrate: linux-cpu (amd64)` and begins with an empty nested provider inventory
and test-data root. Repository Python-bootstrapper `project init` succeeds.

Production `project up` passes, observed complete by 01:28:28 UTC. It pulls CPU/amd64 base
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`, builds image
`sha256:2eb9674f9485106b38afdc36b75f1d987fa2d8e349e2b758f4e94930796dca30`, passes the image quality
gate, web build, exported-runtime verification, unmodified Kind import, and registry push, and reaches
Running web and accelerator pods. `project down` exits 0 in 9.454 seconds. `project destroy` restarts
the stopped guest to reach its retained children, exits 0 in 34.250 seconds, and leaves the nested
Incus inventory empty. The Production lease is `closed` at generation 14, project mode is absent,
and Production durable data is retained. The generated Production config measures
`b949ceb3c943ec9b04206b4cbdd2fcf8d2a80da03236745450556c60ae2dcae1`; the operator test config
retains `8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`.
The disposable Production config is removed only after that check. `test init` refuses to overwrite
the existing operator test config, which is retained unchanged.

The complete `test run all` starts at 01:30:37 UTC and exits 0 with `test report: 10/10 passed`
in 9,408.679 seconds (2 hours 36 minutes 48.679 seconds). Both variants pass `pristine-bootstrap`,
`web-build`, `e2e-tabs`, `registry-persistence`, and `durable-readback`, including destruction and
same-run recreation before durable readback. Each of the four generations passes exported-runtime
verification and the unmodified Kind import:

| Variant and run | Generation | Derived image digest |
|-----------------|------------|----------------------|
| `hello-world`, `run-270210cc9b7` | 1 | `sha256:414335c49d125bbb5417719240dfe482ec326fa707dd642cf192f205e4eda755` |
| `hello-world`, `run-270210cc9b7` | 2 | `sha256:cfb80494a89ac1c564ac0841c460d2c485e88eb6bfac9229282a8f4b6083faa5` |
| `hello-universe`, `run-6bd796f49d0` | 1 | `sha256:5260f0334c222cdc3640e8d98b2fd52bc125d74f43ae3a1e5181d157c41a3797` |
| `hello-universe`, `run-6bd796f49d0` | 2 | `sha256:53fd80771c56155ef65d1df98849d88c9bc31aa566aeb745e79a6cbb490cdb59` |

The terminal audit at 04:10:38 UTC finds no nested Incus instance, both current Harness leases
`closed` at generations 18 and 22, both profiles `available`, and no mode, generated-config ownership,
or data-root ownership record. The generated config is absent, `.test_data` is empty, and the operator
test config retains its exact hash. The 46 covered files remeasure to that dated run's original digest.
The current-source baseline gate is complete; the preserved Windows run remains owned by phase 27.
The post-closure `DocValidatorSpec` check passes 11/11 in 2.66 seconds.

#### Remaining Work

None.

### Sprint 24.46: The consumer's provider opens on every lane it stops [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`
**Production modules**: `HostBootstrapDemo.Commands` (1; cap 3)
**Sprint budget**: two branches on an action this consumer already receives; at most 25 production
Haskell lines and no new type.
**Substrates**: linux-cpu
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

The recursive lifecycle command's reachability step asks the provider reverse to reopen an existing
managed frame so retained children can settle. A reverse opens only a provider the run reached and
retained; a provider that was never created admits no guest descent, guest cleanup, or provisioning.

#### Deliverables

- The Incus branch opens through the retained ownership record, with no caller-supplied generation or
  owner, exactly as its stop and delete peers do.
- The Lima/WSL2 branch admits a present managed instance before using the plan's reboot-ready
  effects and the forward path's readiness probe; an absent instance never reaches a start effect.
- A failed forward before provider creation performs no guest descent or guest cleanup.
- Neither branch can reach the stop effect while answering a reachability step.

#### Validation

The worked demo's own live gate on the Incus lane, where the observable is `project destroy` reporting
that it started the provider and then settling every retained child. The Lima and WSL2 branches are
confirmed by the [Apple Silicon](phase-25-apple-silicon-substrate.md) and
[Windows and WSL2](phase-27-windows-and-wsl2-substrate.md) acceptances, each on its own hardware; this
phase does not claim them.

**2026-10-17 — absent-provider refusal exposes open work.** The standalone native Apple
matrix refuses its unchanged 80-GiB storage budget against 29 GiB free before forward provider
creation. Reverse then starts an absent `hostbootstrap-demo-vm`, provisioning a default
4-CPU/4-GiB/100-GiB guest rather than reopening retained work. Guest child admission and alias
cleanup fail because that guest has no installed project binary or durable alias. The matrix
reports `0/12 passed`, with unresolved teardown and mode closure. The gate-created guest is
stopped and deleted after its ownership and lack of project state are independently established;
the bound Harness lease and mode are preserved. Sprint 25.7 records the exact failed run.

**2026-10-20 — admission and native validation pass.** Reachability probes provider
existence before either provider branch. The pure admission decision returns `TeardownFailed` for
an absent frame, keeping unobserved children outstanding without provisioning or entering a guest.
`CommandsSpec` covers both decision values and guards their call-site order; `TeardownSpec` applies
the real forest transition to the failed reachability observation and verifies retained child work
with no guest descent.

On `MacBookPro`, native arm64 macOS 26.6.2, GHC 9.12.4 and Cabal 3.16.1.0,
`cabal build all` from `core/` and `cabal build all -j1` from `demo/` pass. Plain
`cabal test all` passes in both workspaces: 2,553/2,553 core cases in 553.83 seconds from
`core/`, then 2,553/2,553 in 552.81 seconds plus 164/164 demo cases in 6.25 seconds from
`demo/`. The separately declared `cabal test hostbootstrap-demo-test --test-show-details=direct
--test-options=--hide-successes` passes 164/164 in 5.86 seconds. Both provider-live components
report their declared not-requested `Unsupported` result. Repository-root
`poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all`
pass; the final Python runner reports 251/251 in 2.45 seconds. Fourmolu 0.19.0.1 and 0.21
and HLint 3.10 accept all three changed Haskell files.

The additional native negative probe uses `cabal repl exe:hostbootstrap-demo
--repl-options=-ignore-dot-ghci` from `demo/`, real substrate detection and `buildHostConfig`,
and the normal Production-default `projectConfigForRole`. Calling
`demoProviderReverse pc cfg ReachFrame` returns the exact absent-frame `TeardownFailed`;
the equality assertion passes and GHCi exits 0 at 16:35 UTC. Independent snapshots at
16:34:47 and 16:35:36 UTC, with a half-second Lima/state monitor between them, observe
no VM and unchanged absence of `.build`, `.hostbootstrap`, `.data`, `.test_data`, identities,
and daemon state. This proves the actual absent-Lima callback without allocating a failed
Harness lease; it does not claim full capacity-refusal recovery or a traced guest-command count.

#### Remaining Work

None.

### Sprint 24.47: Revalidate the worked demo after shared guest setup changes [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/src/HostBootstrapDemo/Config.hs`,
`demo/test/` — the shared guest setup and S3 store image changed during live revalidation
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

The WSL-only Docker image-store choice and the portable S3 store deployment
change paths covered by this deferred phase. The earlier live worked-demo gate
no longer proves the resulting tree. Re-run this phase's complete declared gate
on a supported outer host before advancing the later acceptance phases.

#### Deliverables

- The static core and demo legs of this phase's gate pass against the changed tree.
- Production up, down, and destroy plus the full Harness matrix pass in the
  universal `linux-cpu` realization.
- The terminal ownership audit and this phase's covered-source digest are recorded.

#### Validation

The changed tree passes `cabal build all` from `demo/`, `cabal build all` and
`cabal test all` from `core/` (2,547 tests), and the demo's
`hostbootstrap-demo-test` (151 tests). The repository Python code check and
test suite also pass (251 tests). The live phase gate and covered-source
digest remain pending. The first fresh Windows/WSL2 `project up` run reached
Docker after a guest-native Haskell build and reported `overlay2` before its
published-base pull. That exact published digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`
pulled successfully. The project image then failed `check-code` because
Fourmolu required a different guarded-case layout in the new WSL driver check.
The source was formatted exactly as suggested and the published base image's
Fourmolu check passed against the host worktree. `project down` could not
reverse the failed up because build #3 had not produced `hostbootstrap-demo:local`.
The uniquely identified production guest and its protected state were archived
and reset; the live gate must be rerun on the formatted source.
After the formatting edit, `cabal build all` and `cabal test all` pass from
`core/` (2,547 tests), `cabal build all` and `cabal test all -j1` pass from
`demo/` (151 demo tests and 2,547 core tests), and the repository Python
code check and all 251 Python tests pass. This re-establishes the static
portion of the gate; the live legs remain pending.
The fresh production `project up` on Windows/WSL2 wall fence 41 exits 0:
the published CPU/amd64 base digest is pulled under `overlay2`, build #3
verifies its exported runtime and web bundle, Kind imports the project image,
the local registry push completes, and the host accelerator daemon reports
ready. `project down` also exits 0, releases the WSL2 wall, restores the
original `.wslconfig`, and stops the guest. `project destroy` exits 0 and
unregisters that guest. The post-production audit finds no active wall,
no WSL registrations or hostbootstrap processes, no active protected mode,
and `.wslconfig` at its original SHA-256. The full Harness matrix remains
pending.
The first matrix invocation refuses `0/10` before guest creation because the
generated production `.build/hostbootstrap-demo.dhall` from `project init`
still occupies the Harness output path. After confirming no active project
process or WSL registration, that generated config is archived outside the
repository at `C:\Users\Matt\AppData\Local\Temp\hb-recovery-archive-20260923\production-config-fence41.dhall`
with matching SHA-256; the operator test config remains present. The matrix
must be rerun with that output path free.
The rerun starts against the unchanged formatted source. Both fresh
`hello-world` generations reach assertions, then destroy their guest and
release the wall; the second leaves the harness ready to open
`hello-universe` under fence 44. This is partial progress, not the complete
`10/10` gate result.
The matrix then exits 1 with `5/12 passed`: all five `hello-world` checks
pass, but the first `hello-universe` guest's Docker 29.1.3 classic `overlay2`
pull of the published base fails after downloading every layer with
`layers from manifest don't match image configuration`. Its assertions are
broken and reverse teardown leaves protected ownership. A diagnostic retry
of the same `docker pull` in that retained guest succeeds at the exact
published digest. The error is in Docker's intermittent pull/unpack path;
this result does not close the phase.
Two further cold pulls of that digest pass after limiting the retained WSL2
guest to one concurrent layer download. The WSL2 daemon config now carries
that setting, and published-base pulls in WSL2 guests have a three-attempt
bound. The changed Haskell source compiles with `-Werror` and passes Fourmolu;
the complete static gate then passes on this tree: `cabal build all` and
`cabal test all -j1` from `demo/` (151 demo and 2,547 core tests),
`cabal build all` and `cabal test all` from `core/` (2,547 tests), the
repository Python code check, and all 251 Python tests. The failed guest's
274 protected-state files and wall record are archived outside the repository,
the wall restores to its original `.wslconfig` hash, and its uniquely
identified WSL registration is removed. The live gate remains owed.
The next fresh production `project up` reaches Docker `overlay2` at WSL wall
fence 45. Its first serialized published-base pull still fails with
`layers from manifest don't match image configuration`; the new bounded
retry reports the pull failure accurately and its second attempt succeeds
at digest `sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`.
The run proceeds to build #3; its terminal result and the matrix remain owed.
Production `project up` then exits 0. Build #3 verifies the exported runtime,
config, public keys, and web bundle; Kind imports the derived image and the
host daemon reaches ready. `project down` and `project destroy` also exit 0.
The audit finds no WSL registration, active wall, protected mode, or
hostbootstrap process, and `.wslconfig` matches its original SHA-256
`2986099D4E292ABED1BACBF7B7CB514188BAD4304F930800803A85470EE4E694`.
The generated production config is archived outside the repository with its
hash intact so the full Harness matrix can use the output path. That matrix
remains the open live leg.
The full matrix's first fresh `hello-world` guest (fence 46) pulls the
published digest on its first attempt, completes build #3 and assertions,
then destroys the guest and releases the wall. Its second fresh guest
(fence 47) reaches `overlay2`; its first published-base pull again fails
with the layer/configuration mismatch, while the bounded second attempt
succeeds at the same digest and proceeds to build #3. The matrix terminal
report exits 1 with `4/12 passed`. The second guest completes build #3 and
starts same-run restart, but `kind load docker-image hostbootstrap-demo:local`
exits 1 inside `project:push-image`. The parent reports a terminal callback
failure after acknowledgement; the retained lifecycle child record exposes
the actual Kind command refusal. Kind's detailed stderr is absent from the
record, so the lower-level import failure is unproven. Failed-Up unwind leaves
the child chain open; teardown and mode close cannot settle its protected
records, and `hello-universe` is refused. The failed guest was unregistered
and the wall restored; 240 protected-state files were archived outside the
repository after verifying the run identity. The WSL-only Kind image load
now has three bounded attempts and emits captured output on stderr for each
failed attempt. This source change compiles with `-Werror`; the full gate is
owed again.
The WSL-only Kind retry passes Fourmolu 0.19.0.1 with the repository style
contract, `cabal build all` from `demo/`, and `cabal test all -j1` from
`demo/` (151 demo tests and 2,547 core tests). The repository Python code
check and all 251 Python tests also pass. The separate core gate and fresh
live legs are in progress. The separate `cabal test all` from `core/` then
exits 0, including the core test suite and the expected skipped native
provider-live lane. The fresh production `project up` has acquired WSL wall
fence 48; its terminal result is pending.
The fence-48 production run exits 1 before Docker: GHCup's pinned GHC 9.12.4
installation exits 1 while `gmake install` copies libraries. Its generated
`make.log` and `ghcup.log` stop during installation without a reported make
error; the guest reports 68 GiB free disk and 9.2 GiB available memory, and
the kernel log contains no OOM kill. Subsequent Hyper-V Worker Admin event
inspection identifies a guest-reported CPU Machine Check Exception and
`Kernel panic - not syncing: Fatal local machine check` at 07:07 local time.
This explains the abruptly stopped installer. The physical or virtualization
fault beneath the reported machine check is not identified. This run never
exercises the new Kind import code and cannot serve
as live gate evidence. Its guest and protected records require the approved
reset before another pristine run.
The approved reset archives the fence-48 wall record, 22 protected-state
files, and the generated production config outside the repository; the wall
restore returns `Right ()`, the verified sole WSL GUID is unregistered, and
`.wslconfig` matches its original SHA-256. A new production attempt is
launched on the unchanged source.
That fence-49 production attempt also exits during GHCup installation, before
Docker. Its extracted GHC profiling archive is 595,591,168 bytes, whereas
the matching member in GHCup's digest-verified download is 617,432,916
bytes; `ranlib` on the extracted archive reproduces `State.p_o: file
truncated`, while the complete tar member passes `ranlib`. Hyper-V Worker
Admin records further guest-reported CPU Machine Check Exceptions and fatal
local machine-check panics at 07:18, 07:20, and 07:25 local time, including
during a direct diagnostic extraction. The run cannot validate the code;
further pristine WSL gates on this host need a stable host/virtualization
environment. The approved operator reset archived the fence-49 wall record,
22 protected-state files, and generated production config outside the
repository. Wall restoration returned `Right ()`, the verified sole guest GUID
`{9c5cb108-819c-4992-85bb-83a7e81090ff}` was unregistered, zero WSL
registrations remain, and `.wslconfig` retains its original SHA-256
`2986099d4e292abed1bacbf7b7cb514188bad4304f930800803a85470ee4e694`.
All four Hyper-V fatal events carry the same machine-check status word
`b200000080060001`; the Windows System log has no WHEA-Logger event in the
same two-day window. The host runs WSL 2.7.10.0, kernel 6.18.33.2-2, and
Windows build 26200.9457. A [Microsoft WSL issue](https://github.com/microsoft/WSL/issues/41649)
reports the same guest status word on another host across later WSL and kernel
versions; it does not establish this machine's underlying cause or a fix.
The previously used `matt-junction` Linux host is reachable but rejects the
available SSH identity with `Permission denied (publickey)`, so its `hb-linux-cpu`
guest cannot be used for the owed gate from this workspace.

The four saved panic dumps and matching Windows Resource-Exhaustion-Detector
events show a concrete host condition at each crash: system commit was
63.62–63.76 GiB against a 63.87 GiB limit. The Windows `psmux` client
`tmux.exe` (PID 11040) accounted for 44.24–45.77 GiB, while `vmmemWSL`
accounted for 7.49–8.63 GiB. The page file is automatically managed; its
limit had grown during the earlier runs. The dumps also contain an earlier
WSLg `Xwayland`/`dxgkrnl` warning. Commit exhaustion is established, but the
mechanism that reports it as a guest machine check is not proved.

A controlled fence-50 Production retry starts through the durable WMI launcher
outside the `psmux` process tree, with ten-second Windows commit and `psmux`
samples. The current Codex process itself runs in an attached `psmux` pane,
so that client cannot be restarted during this session. `project init`
passes. Fresh `project up` installs GHC 9.12.4, builds and installs the guest
binary, pulls base digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`,
and reaches Docker build #3. No new guest machine-check or Windows
resource-exhaustion event appears. The attempt is deliberately interrupted
while the image's `check-code` runs: commit reached 23.008 GiB against a
23.347 GiB limit, and `psmux` private commit had grown from 0.07 to 1.67
GiB. Thus it establishes progress beyond the earlier GHC failure, not a
passing Production gate or an isolated no-`psmux` result. Normal `project down`
cannot enter the unfinished image, and `project destroy` refuses the
remaining reverse state. The run's 35 protected files, generated config,
and wall record are archived outside the repository. Wall restoration
returns `Right ()`; verified sole guest GUID
`{41d9da26-9ecd-412f-9c64-9183a67a1d6d}` is unregistered; zero WSL
registrations remain; and `.wslconfig` retains its original SHA-256 above.
The same attached `psmux` client continues growing after the WSL guest is
unregistered, reaching 2.13 GiB while system commit is 12.94 GiB of a
22.34 GiB limit. Its growth is independent of this live WSL guest.

After the operator resets `tmux`, a fresh fence-51 Production `project init`
passes and `project up` starts through the detached WMI launcher. The new
`tmux` client still hosts Codex and grows during the run. Guest GHC installation
and project-binary compilation pass; Docker starts with the WSL-only `overlay2`
store, pulls the published CPU/amd64 base at the digest above, and enters
image build #3. There is no new Hyper-V machine-check event or Windows
resource-exhaustion event. At the build's end, however, Cabal reports that
building `test:hostbootstrap-core-test` segfaulted. Guest `dmesg` records
`ghc_worker` signal 11 and a general protection fault in
`libHSghc-9.12.4-5301-ghc9.12.4.so`. The last sampled Windows commit is
18.011 GiB of 19.745 GiB, with the new `tmux` client at 1.935 GiB; guest
memory after failure has 9.1 GiB available and no OOM kill is recorded. This
attempt therefore fails at a compiler crash without reproducing the earlier
WSL kernel panic. The cause of that compiler crash remains unproven, and the
Production gate has not passed. `project down` cannot enter the unfinished
image; `project destroy` refuses `ModeReverseRootInProgress`. The 22
protected-state files, generated config, and wall record are archived outside
the repository under `failed-production-post-tmux-reset-fence51` with matching
counts and SHA-256 hashes. The core wall restore removes the active record;
the verified sole guest GUID `{fdafab47-5988-4be8-9038-4724a34ea5c0}` is
unregistered. Zero WSL registrations remain and `.wslconfig` retains its
original SHA-256 above. After recording this failure, `cabal test all -j1`
from `core/` passes all 2,547 core tests, including `DocValidatorSpec`; the
native provider-live lane takes its declared skip. `git diff --check` passes.

With the attached `psmux` client detached, the next fresh Production
`project init` passes and `project up` proceeds through guest GHC installation,
the project-binary build, the published CPU/amd64 base pull at digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`,
and the in-image `check-code` step that had segfaulted at fence 51. Windows
commit remains about 16.4 GiB of 19.745 GiB during the image build, with no
new machine-check or resource-exhaustion event. The run then exits 1 during
Kind rollout. The live pod is in `ImagePullBackOff`: Quay returns HTTP 401 for
the demo's `quay.io/minio/minio:latest` image. Direct pulls of a pinned MinIO
release from Quay and Docker Hub also fail. The parent reports a terminal
callback acknowledgement failure, but the pod event identifies the immediate
deployment failure. This run does not establish that `psmux` caused the earlier
GHC crash or WSL machine checks. Normal `project down` and `project destroy`
both exit 0; the audit finds zero WSL registrations, no active wall, and the
original `.wslconfig` SHA-256. The 99 generated protected-state records and
production config are archived outside the repository under
`failed-production-detached-client-20260924`, leaving their worktree paths free
for another run. The unavailable image dependency requires a portable S3 store;
the full live gate remains owed.
After recording this attempt, `cabal test all -j1` from `core/` exits 0,
including `DocValidatorSpec`; `git diff --check` also passes.
The demo now renders a versioned VersityGW POSIX-backed S3 Deployment in place
of the unavailable MinIO image. `docker manifest inspect` confirms that
`ghcr.io/versity/versitygw:v1.7.0` publishes linux/amd64 and linux/arm64
manifests. `cabal build all` from `demo/` passes with `-Werror`. The full
static and live gates must run against this new tree.
On 2026-09-24, the first Production run with that store passes `project init`,
`project up`, `project down`, and `project destroy` on native Windows/WSL2.
The guest pulls published CPU/amd64 base digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`,
passes the in-image code check and export verification, and brings up
VersityGW `v1.7.0` and the registry as Ready Kind Deployments. The 16.3 GB
project image loads into Kind and pushes through the S3-backed registry;
the pushed manifest digest is
`sha256:81366613bb1b80ecd325e304cca4a3511a3a03643d06012d1ec3be9fdf00ccf5`.
The web endpoint and hidden Windows host daemon reach readiness. With no
attached `psmux` client, sampled Windows commit remains below 16.8 GiB of a
19.745 GiB limit during the build. Teardown releases the WSL wall, restores
the original `.wslconfig` SHA-256, and unregisters the sole guest. The 108
generated protected-state files and production config (SHA-256
`5EC0092759C6818DB0879C97399F5F33F345062781ADF06D5E8214378FBB0A22`)
are archived outside the repository under `production-versity-20260924` to
leave the Harness output path free. The complete matrix remains owed.
The complete Windows host static gate then passes against this source tree:
`cabal build all` and `cabal test all` from `demo/` (151 demo and 2,547
core tests), `cabal build all` and `cabal test all` from `core/` (2,547 tests,
including `DocValidatorSpec`), the repository Python code check, and all 251
Python tests. `git diff --check` passes. The full live matrix remains owed.
The fresh full Windows/WSL2 matrix started on 2026-09-24 and exited 1 on
2026-09-25 with `4/12 passed`. Its first `hello-world` generation (wall fence
54) built and deployed the image and passed the initial assertions. The
same-run restart for `durable-readback` created a second fresh guest (fence
55); that guest pulled the exact published CPU/amd64 base digest, completed
both project builds, and verified the exported runtime, config, keys, and web
bundle. Its `kind load docker-image` first failed while extracting layer
`sha256:593011a328f7a4180421214f7ebcaf88b70debf94326a0e3b0700c708f32daea`
because the node content store could not find that digest. Both bounded
retries then failed at `docker save` with `file integrity checksum failed for
"usr/lib/x86_64-linux-gnu/libclang-19.so.19"`. Thus the retained local Docker
image could not be exported; repeating Kind import of that same image did not
repair it. The lower-level cause of the fresh guest's local image corruption
is unproven. Failed-Up unwind left the child chain and protected effect record
unsettled, so teardown and mode close reported leaks and `hello-universe` was
refused. The guest was already destroyed, the global wall released, and the
original `.wslconfig` restored. With no WSL registration or hostbootstrap
process remaining, all 137 protected-state files were archived intact outside
the repository under `failed-versity-matrix-fence55-20260925.hostbootstrap`;
`wsl --shutdown` cleared the lingering utility VM. The final audit finds no
WSL registration, hostbootstrap process, active wall, generated run config, or
protected mode, and the `.wslconfig` SHA-256 is again
`2986099D4E292ABED1BACBF7B7CB514188BAD4304F930800803A85470EE4E694`.
The complete live gate remains owed.

The WSL2 bootstrap now checks the derived image with `docker save` redirected
to `/dev/null` before Kind or the registry exists. This reads every archived layer,
including base files that the runtime smoke test does not execute. On the
observed file-integrity-checksum class, it first refuses to clear an occupied
Docker daemon, then removes the guest's unused images and builder cache,
re-pulls the published base with digest verification, and
rebuilds. The repair is bounded to three builds in a project-owned WSL2
guest; other export failures retain their diagnostic and fail. This is a
recovery for the observed local image corruption, not a claim that its
lower-level cause has been identified. The revised source passes the native
Windows static gate: `cabal build all` and `cabal test all` in both `demo/`
and `core/` (151 demo, 2,547 core, and the native provider-live skip),
the Python code check and all 251 Python tests, Fourmolu 0.19.0.1 on the
changed module, and HLint 3.10 with no hints. A fresh Production run and the
complete live matrix remain owed on this changed tree.

The first fresh Production `project up` on the checksum-recovery change
stopped before Kind because its preflight used `docker save -o /dev/null`.
Docker refuses that character device as an output file. In the retained guest,
`docker save hostbootstrap-demo:local > /dev/null` completed successfully,
proving this attempt's image was exportable. The preflight now uses that
redirection, and `cabal build all` in `demo/` passes. Normal `project down`
released the WSL wall and restored the original `.wslconfig`, but `project
destroy` stopped because the guest's durable alias path was a directory where
its ownership record expected a symbolic link. Recovery and the full live gate
remain owed.
The sole WSL registration matched the demo guest and GUID
`{b11e094b-84b6-4aab-8dc8-8e68e22b87b6}`; 84 protected-state files,
both generated configs, and the generated keys were archived intact outside
the repository under `failed-integrity-preflight-20260925`. The approved
operator reset unregistered that guest and shut WSL down. The terminal audit
shows no registered distribution, and `.wslconfig` still hashes to
`2986099D4E292ABED1BACBF7B7CB514188BAD4304F930800803A85470EE4E694`.

The next fresh Windows/WSL2 Production sequence on the corrected preflight
passed `project init`, `project up`, `project down`, and `project destroy`.
The guest pulled the published CPU/amd64 base digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`;
`docker save` over the entire derived image and the exported-runtime probe
both passed. Kind's first import failed with a missing containerd content
digest `sha256:9f522cd6153474e0565bf0d2dd54e8b52ab08c80d6b1a64487f523fe3a866fc6`.
The declared retry recovered: the image loaded, the in-cluster push returned
manifest digest
`sha256:449768998ad08b5bd2db741d9719adc3bcdc15bf62ff54f2405dd22b74efd19d`,
and the web service and host daemon reached readiness. `project down`
released wall fence 57 and restored the original `.wslconfig`; `project
destroy` unregistered the sole guest. The host has no WSL registration or
hostbootstrap-demo process, and `.wslconfig` again hashes to
`2986099D4E292ABED1BACBF7B7CB514188BAD4304F930800803A85470EE4E694`.
The 108 protected-state files, generated Production config (SHA-256
`5EC0092759C6818DB0879C97399F5F33F345062781ADF06D5E8214378FBB0A22`),
and generated keys were archived intact outside the repository under
`production-integrity-redir-20260925` to leave the Harness output path
pristine. The full Harness matrix remains owed.
The complete Windows/WSL2 Harness matrix was launched durably at
2026-09-24 23:20 EDT under `phase24-integrity-redir-matrix-20260925`.
Its first `hello-world` generation is `run-1a4ccab22128` and acquired wall
fence 58. The Python host checks on this tree pass (`ruff`, Black, mypy,
251 tests), as do `cabal build all` in `core/`,
`cabal test hostbootstrap-demo-test` in `demo/` (151 tests), and
`git diff --check`. `cabal test all` in `core/` also exits 0, including
the core suite and native provider-live refusal. The matrix outcome remains
pending.
The matrix's first guest at fence 58 pulled the expected published base,
passed the full derived-image archive check, loaded and pushed the image
(manifest `sha256:f87877ead41b6002af4776b1677d2484c027a3a21e23ce379a3b1b6e7a37fe23`),
and reached web and daemon readiness. The Harness opened `hello-world`
assertions, destroyed that guest, restored the WSL wall, and began its
same-run restart at fence 59. The complete matrix result is still pending.
After the README frontier update, `cabal test all` from `demo/` passed again:
151 demo tests and the 2,547-case core suite, including `DocValidatorSpec`.
The second matrix guest at wall fence 59 passed the WSL2 project-image archive
and exported-runtime checks. Its first Kind image import reported missing
containerd content digest
`sha256:9f58ca9c5ce6715bba03208cd6974205b75a52ec2485e10a402153262859a28a`;
the declared retry recovered. The web service and host daemon reached readiness,
the Harness opened the restarted `hello-world` assertions, and normal destroy
released the wall. The same matrix then began its third fresh guest at fence 60
for `hello-universe`; the complete result remains pending.

On 2026-09-30 UTC the native x86_64 Linux visit to `matt-junction` (Ubuntu 24.04.5 LTS, Linux
7.0.0-31-generic, GHC 9.12.4, Cabal 3.16.1.0, Python 3.12.3, Poetry 2.4.1) runs this phase's complete
gate against the covered source the Windows visit left, which measures
`04d0e9d3f27226ba03e1546b3bc6ea9b631dd2443e18f64e965bcf4037184d8e`. The host static legs pass on
`matt-junction`: from `core/`, `cabal build all` and `cabal test all` (2,552/2,552 in 216.68 seconds);
from `demo/`, `cabal build all`, `cabal test hostbootstrap-demo-test` (151/151), and `cabal test all -j1`
(151/151 demo cases in 0.83 seconds and 2,552/2,552 core cases in 204.28 seconds); and from the repository root,
`poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all`
(251/251 in 1.55 seconds). Both Cabal workspaces run the provider-live component to its declared
no-request refusal. Fourmolu 0.19.0.1 and HLint 3.10 report no change and no hint over `demo/src` and
`demo/app`, the scope of the image's own `check-code`. The live legs run in the existing `hb-linux-cpu`
guest from a pristine demo state: the 2026-09-17 tree and its `.build`, `.hostbootstrap`, `.data`, and
`.test_data` are archived outside the repository, the nested provider inventory is empty, and the guest's
tree measures the same covered digest as the host's. The guest reaches its package mirrors only after
non-persistent `DOCKER-USER` accept rules on `matt-junction` let `incusbr0` traffic past Docker's
`FORWARD DROP` policy; that host firewall state is outside the repository and the gate. The guest runs Ubuntu 24.04.5 LTS on Linux 6.8.0-139-generic with
16 vCPU and 32 GiB, Incus 6.0.0, GHC 9.12.4, Cabal 3.16.1.0, Poetry 2.4.3, and Python 3.12.3, and
`doctor` reports `substrate: linux-cpu (amd64)`.

The repository Python bootstrapper's Production sequence passes in that guest:

| Command | Result | Duration |
|---------|--------|----------|
| `project init` | exit 0 | 1,123.17 s |
| `project up` | exit 0 | 2,539.68 s |
| `project down` | exit 0 | 22.69 s |
| `project destroy` | exit 0 | 35.09 s |

`project init`'s duration is the cold host-native build of the project binary inside the guest; the
sibling config it writes measures `b949ceb3c943ec9b04206b4cbdd2fcf8d2a80da03236745450556c60ae2dcae1`.
Up provisions the nested Incus guest, builds the binary there, pulls published CPU/amd64 base
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`, and verifies the derived
image's exported runtime, config, public keys, and web bundle before descending into it. The VersityGW
store reports ready at `object-store.default.svc:9000` with its `registry` bucket, the registry rolls out
behind a runtime-assigned loopback exposure, the image loads into Kind and pushes as manifest
`sha256:a6dfd7e7403ab260f2babe1521168e9b9fc98d74ab6b27f508da58679ff13c50`, the web service answers at its
resolved endpoint, and the in-cluster accelerator daemon rolls out. Down stops the guest through its
retained ownership record; destroy starts it so its retained children can be reached, then deletes it
through that record. The Production audit finds an empty nested provider inventory, the Production lease
`closed`, its reverse root terminal, and no mode record; Production durable data remains, as `destroy`
intends. The
generated Production config is archived outside the repository with its hash intact, and `test init`
writes the operator test config at `8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`.

The complete `test run all` starts at 05:04:02 UTC and exits 0 with `test report: 10/10 passed` in
10,976.15 seconds (3 hours 2 minutes 56 seconds). Both `hello-world` (`run-59b4fb85ecb`) and
`hello-universe` (`run-a52709f83c4`) pass `pristine-bootstrap`, `web-build`, `e2e-tabs`,
`registry-persistence`, and `durable-readback`, the last across a settled destruction and a fresh
same-run recreation. Each of the four pristine generations pulls the published CPU/amd64 base digest
above, verifies the derived image's exported runtime, config, public keys, and web bundle, brings up the
VersityGW store with its `registry` bucket, loads the image into Kind and pushes it through the
S3-backed registry, and deletes its guest through the retained ownership record:

| Variant and run | Generation | Pushed manifest digest |
|-----------------|------------|------------------------|
| `hello-world`, `run-59b4fb85ecb` | 1 | `sha256:eca2b198af87aae1480557c87bc227d07f3d45305ed4f9ffa9e52da27bbf3c39` |
| `hello-world`, `run-59b4fb85ecb` | 2 | `sha256:4ef4cfdac1a76cef29d8b76f50ec3634485bb74cd39512feea463afdbab151a3` |
| `hello-universe`, `run-a52709f83c4` | 1 | `sha256:4623b1b7fc253d00b566139b7b614b5044a43ad819c0ed8975b30c23149d51b9` |
| `hello-universe`, `run-a52709f83c4` | 2 | `sha256:b059c25f9ef369335c7659fbaeac593b4f0ea4857dbf67322b7f81007e66dcde` |

The terminal audit at 08:06:58 UTC finds no nested Incus instance, both Harness leases `closed` at
generations 7 and 11, both profiles `available` at generations 6 and 10, and no mode, generated-config
ownership, or data-root ownership record. The generated config is absent, `.test_data` exists and is
empty, the operator test config retains its exact hash, and no project process remains. The 47 covered
files remeasure to that dated run's original digest on both the gate host and `matt-junction`. The current-source
baseline gate is complete.

#### Remaining Work

None.

### Sprint 24.48: Teardown verifies the current protected ownership stores [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Make the Harness's terminal ownership assertion inspect the protected daemon claims and WSL wall
receipt used by the current lifecycle, so obsolete paths cannot admit a false clean teardown.

#### Deliverables

- The daemon assertion takes the current protected operation entry and refuses a retained owner or PID.
- The Windows assertion inspects the current protected global-wall active record.
- Regression cases exercise retained current records, a held operation, and released ownership.

#### Validation

On 2026-10-15, the correction passes the complete native Windows host static gate. The audit finds
`verifyHarnessTeardown` checking removed daemon owner/operation directories and `global-wall.record`
instead of the current daemon `.claims` and per-user `global-wall` protected stores. The assertion
now observes the daemon's existing owner record and the production wall-location API under their
protected entries. Windows profile selection uses `USERPROFILE`, matching the wall backend.

The retained fence-61 wall is settled through `restoreCurrentUserGlobalWall`, invoked through
`cabal exec -- ghci` with the demo's exact owner, specification, reservation, receipt, and managed
body. This typed recovery restores the original file identity and hash, clears the active wall and
retained origin pathname, and preserves the monotonic fence. Eight observer regressions exercise
retained current records, held entries, PID-only residue, released records, never-used stores, and
failed store opens. Fourmolu 0.19.0.1 and HLint 3.10 pass over both edited files;
`git diff --check` passes.

The first demo workspace attempt exits 1 because two new specs treat the compare-and-swap result
as a record rather than the record version it returns. Both specs now pass that version directly
to `ExpectVersion`. Its passing 2,547-case core component in 404.83 seconds does not establish a
passing composed gate; the final complete workspace pass below includes the corrected specs.

The final native gate passes all declared legs:

- From `core/`, `cabal build all` passes warning-clean, followed by
  `cabal test all --test-options=--hide-successes` at 2,547/2,547 in 403.76 seconds after resolution
  of the newer compatible dependency graph. The initial core run also passes 2,547/2,547 in
  535.81 seconds, including `DocValidatorSpec`.
- From `demo/`, `cabal build all --builddir=.build/host-static` passes warning-clean, and
  `cabal test all --builddir=.build/host-static --test-options=--hide-successes` exits 0 with
  159/159 demo cases in 5.60 seconds and 2,547/2,547 core cases in 384.59 seconds. The isolated
  build directory keeps this gate separate from the concurrent bootstrapper's executable build.
- Both Cabal workspaces pass the provider-live component's declared no-request refusal.
- From the repository root, `poetry run python -m hostbootstrap.check_code` passes, and
  `poetry run python -m hostbootstrap.test_all` passes 251/251 in 11.29 seconds.

No production source changes follow the final passing gate.

#### Remaining Work

None.

### Sprint 24.49: Validate the corrected teardown in the complete worked demo [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`, `documents/engineering/wsl2.md`,
`documents/architecture/durable_state.md`, `documents/operations/demo_runbook.md`

#### Objective

Run the phase's complete declared gate after correcting its terminal ownership assertions.

#### Deliverables

- Production up, down, and destroy pass through the supported Windows/WSL2 baseline realization.
- The complete Harness matrix passes with a terminal ownership and wall audit.
- Gate evidence records the actual commands and the remeasured covered-source digest.

#### Validation

Completed on 2026-10-16 UTC after the 2026-10-15 Windows visit: the corrected tree passes the
complete native Windows and x86_64 Linux static gates, the supported Windows/WSL2 Production
`init`/`up`/`down`/`destroy` sequence, and the complete Harness matrix at `10/10 passed` with exit 0.
Both the Production and final Harness ownership/wall audits pass.

The phase's 29 roots cover 862 authored files: the full live gate's compiled core/consumer components,
package/project and bootstrap metadata, chart/browser/SPA and style/build-context inputs, plus the
static gate's source, tests, schemas, and inspected cluster fixtures. They measure
`25747980e634fb9c9e40bb61d7d28a1479c784607f30fb93a37dd7c70691db19`.
The post-gate measurement on 2026-10-16 is identical; source and authored fixture bytes remain
unchanged throughout the live runs. The earlier 47-file
subset measurement `cbafd88a0d75bfa414560f90c2a7fb4265db1fbf835ac1d29a3ee56ff4d564f1` retains
its narrower provenance.

The final Windows static gate passes core build and 2,547/2,547 core cases in 403.76 seconds;
the isolated demo build and full workspace pass 159/159 demo cases in 5.60 seconds and 2,547/2,547
core cases in 384.59 seconds. Python code checks and 251/251 tests in 11.29 seconds pass.
Sprint 24.48 records the exact commands and the corrected first spec compilation failure.
The first closure documentation check refuses a row that records the complete workspace test but
omits the separately named `cabal test hostbootstrap-demo-test` leg. That exact target is rerun with
`--builddir=.build/host-static --test-show-details=direct --test-options=--hide-successes` and passes
159/159 in 5.55 seconds; the evidence row now records both actual commands.
The closure `DocValidatorSpec` rerun passes 11/11 in 5.43 seconds, checking status harmony,
complete gate-command evidence, and the current covered-source digest.
The complete Linux gate in the Production guest exits 0 at 21:41:23 UTC after 1,214.41 seconds:
core build and 2,552/2,552 cases in 327.64 seconds; the complete demo workspace at 159/159 in
2.08 seconds plus 2,552/2,552 core cases in 326.72 seconds; Python code checks and 251/251 tests
in 3.31 seconds. Both workspaces on both hosts report the provider-live component's declared
no-request result. The 857-file portability subset matches between Windows and Linux before and
after the gate; Sprint 28.5 records its digest, commands, and cache configuration.

All live commands use this checkout's repository Python bootstrapper,
`poetry run hostbootstrap run --project-root demo`, on `DESKTOP-R6BTBVS`.
`project init` exits 0 at 20:30 UTC and writes the Production sibling config with SHA-256
`5ec0092759c6818db0879c97399f5f33f345062781adf06d5e8214378fbb0a22`.
The source-built executable retains SHA-256
`b0a46ea3e9090221811bc925e0e280c365b34845032210d763f2868e90d1458f`;
the operator test config retains SHA-256
`8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`.

Production `project up` starts at 20:31 UTC through the harness-owned WMI durable launcher, label
`phase24-production-up-20261015`, and exits 0 at 21:19:07 UTC after approximately 47 minutes 42 seconds.
It acquires wall fence 62 and creates `hostbootstrap-demo-vm`, Ubuntu 24.04.5 LTS on kernel
6.18.33.2-microsoft-standard-WSL2. Observed allocation is six CPUs, 10,184,824 kB memory, and an
83,955,703,808-byte formatted filesystem from the declared 80 GiB VHD; the managed wall sets
six processors, 10 GB memory, 10 GB swap, and both 21,600,000 ms idle timeouts.
Docker uses `overlay2` and pulls published CPU/amd64 base
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`.
The derived image is `sha256:b6c94394b6d0efc4ee9e21e5733275f15be2262be6d4e158837c6127a1a0225f`.
Its code checks, archive integrity, and exported runtime/config/public-key/web-bundle verification
pass; Kind imports it and all three application deployments become ready. Requests through the
runtime-assigned relay prove CUDA arithmetic and Float32 rounding. Sprint 27.5 records the native
Windows worker and loopback placement observations.

Production `project down`, durable label `phase24-production-down-20261015`, exits 0 at 21:44:23 UTC
and restores the wall before stopping the guest. `project destroy` exits 0 at 21:45:10 UTC and
unregisters that exact guest. The verified Production sibling config is removed through the
runbook's operator step before Harness admission.
The 21:46 UTC audit finds the Production lease closed (record version 5, epoch 3), its consumed
profile retained, no ephemeral mode/config/data-root records, no daemon PID/current protected owner
or native worker, and no WSL registration. The wall is inactive at fence 62 and the original
`.wslconfig` hash and Windows file ID are restored. The operator test config is unchanged,
`.test_data` is empty, and Production `.data` is preserved. Governed durable-state, WSL2, and runbook
prose reflects the managed-alias and restore-before-shutdown contracts; focused documentation
checks pass on Windows and Linux.

The complete `poetry run hostbootstrap run --project-root demo test run all` matrix starts at
2026-10-15 21:46:23.514 UTC through WMI durable label `phase24-matrix-20261015`, PID 31600.
Both `hello-world` generations belong to `run-6b565ce5808`:

- Fence 63 publishes image `sha256:cb897da5442f89b4d45d9ac028e6bf265a4414cfa66f01aebdf51e6b8759eff1`,
  first observed through its verified public web activation manifest at 22:32:48.056 UTC.
- Its engine-owned reconstruction at fence 64 publishes
  `sha256:0bf2239bf5dbe15736c82cd75ed5fc94f6fc35d54c0789dc9403b984bd659294`,
  first observed at 23:19:31.672 UTC.

After world teardown restores the wall, `hello-universe` starts as `run-bcec61e1608` at fence 65,
with WSL GUID `{b7955e79-55ea-46e9-9e16-9700c92cd8ea}` observed at 23:20:14.528 UTC.
Both universe generations complete, with the final recreation at fence 66. The matrix exits 0 at
2026-10-16 00:53:07.207 UTC after 11,203.69 seconds (3 hours 6 minutes 43.69 seconds), reporting
`10/10 passed`: pristine bootstrap, web build, end-to-end tabs, registry persistence, and durable
readback all pass for both variants. Sprint 27.5 holds all four exact image IDs, guest identities,
verified public manifests, and actual published-base pulls.

The final read-only audit passes at 00:55:51 UTC. Both Harness leases are Closed at record version 6
(epochs 7 and 11); their retained Available profiles are record version 3, epochs 6 and 10, with
forward lease version 4. The final destroy invocation advances the lease generation, and terminal
close advances its version again; Sprint 27.5 records the audit helper's corrected comparison.
There are no ephemeral mode/config/data-root records, generated project config, daemon PID/current
protected owner, native worker, or WSL registration. `.test_data` is empty, Production `.data` is
preserved, and the operator test config hash is unchanged. The wall is inactive at fence 66, with
original SHA-256 `2986099d4e292abed1bacbf7b7cb514188bad4304f930800803a85470ee4e694`
and Windows file ID `0x00000000000000000061000000023bde` restored. After wall restoration and
an empty WSL inventory, the supported `wsl.exe --shutdown` exits 0; host process observation confirms
the empty utility VM is stopped.
The Harness itself proves protected-entry release through the corrected production observer; the
external audit does not claim an independent entry-lock probe.

The preceding baseline pass retains its original narrower scope: `demo/src` `demo/app` `demo/test` `demo/docker` `core/hostbootstrap-core/src/HostBootstrap/Lifecycle` `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan`.
Its dated evidence and original digest remain unchanged:

- 2026-09-30 ; `hb-linux-cpu`, an Ubuntu 24.04.5 LTS guest, Linux 6.8.0-139-generic
  x86_64, 16 vCPU and 32 GiB, reused with an empty nested provider inventory under Incus 6.0.0 on `matt-junction`
  (x86_64 Ubuntu 24.04.5 LTS, Linux 7.0.0-31-generic) with nested virtualization, running GHC 9.12.4,
  Cabal 3.16.1.0, Poetry 2.4.3 and Python 3.12.3, where `doctor` reports `substrate: linux-cpu (amd64)` ;
  repository Python bootstrapper `poetry run hostbootstrap run --project-root demo project init`,
  `poetry run hostbootstrap run --project-root demo project up`,
  `poetry run hostbootstrap run --project-root demo project down`,
  `poetry run hostbootstrap run --project-root demo project destroy`,
  `poetry run hostbootstrap run --project-root demo test init`, then
  `poetry run hostbootstrap run --project-root demo test run all` from a pristine demo state, with
  `cabal build all`, `cabal test hostbootstrap-demo-test`, and `cabal test all -j1` from `demo/` and
  `cabal build all` and `cabal test all` from `core/` plus
  `poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all`
  on the x86_64 Linux gate host `matt-junction` ; pass ;
  covers 04d0e9d3f27226ba03e1546b3bc6ea9b631dd2443e18f64e965bcf4037184d8e

The exact 2026-10-16 gate-evidence row is retained for the source that run exercised.
The later formatter update does not restamp this result:

- 2026-10-16 ; `DESKTOP-R6BTBVS`, native x86_64 Windows 11 Home 10.0.26300.9457,
AMD Ryzen 7 5700G, 63.87 GiB, RTX 3090, GHC 9.12.4, Cabal 3.16.1.0, Poetry 2.4.1, Python 3.14.7,
with Ubuntu 24.04.5 LTS/WSL2 6.18.33.2, 6 CPUs, 10 GiB memory and 80 GiB VHD ;
`cabal build all` and `cabal test all --test-options=--hide-successes` from `core/`,
`cabal build all --builddir=.build/host-static` and
`cabal test all --builddir=.build/host-static --test-options=--hide-successes` and
`cabal test hostbootstrap-demo-test --builddir=.build/host-static --test-show-details=direct --test-options=--hide-successes`
from `demo/`,
`poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all`
from the root, plus repository-bootstrapper `poetry run hostbootstrap run --project-root demo project init`,
`poetry run hostbootstrap run --project-root demo project up`,
`poetry run hostbootstrap run --project-root demo project down`,
`poetry run hostbootstrap run --project-root demo project destroy`,
`poetry run hostbootstrap run --project-root demo test init`, and
`poetry run hostbootstrap run --project-root demo test run all` (`10/10 passed`, exit 0),
followed by the terminal ownership/WSL wall audit ; pass ;
covers 25747980e634fb9c9e40bb61d7d28a1479c784607f30fb93a37dd7c70691db19

#### Remaining Work

None.

### Sprint 24.49a: Meet the compatible Haskell formatter contract [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/DocValidatorSpec.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/languages/haskell.md`, `documents/engineering/testing.md`

#### Objective

Let the base-publication source preflight pass the compatible formatter without changing runtime
behavior. This sprint owns three production source modules and their affected specs.

#### Deliverables

- Apply Fourmolu 0.19.0.1 import ordering and indentation to the affected core source and specs.
- Express the demo chart values through local `valueLines`, preserving the exact generated text and
  satisfying both Fourmolu 0.19.0.1 and 0.21.
- Validate the source-only change with the host static gate; Sprint 24.50 separately owns live confirmation.

#### Validation

On 2026-10-16, the canonical publication preflight passes all formatter roots with Fourmolu 0.19.0.1
and all linter roots with HLint 3.10; the demo source/app roots also pass Fourmolu 0.21. The native
macOS core build and complete demo workspace build/test pass, including 159/159 demo cases in
5.51 seconds and its core component. After the source edits settle,
`cabal test all --test-show-details=direct --test-options=--hide-successes` from `core/` exits 0 with
2,552/2,552 in 453.84 seconds plus the provider-live component's declared no-request result.
`poetry run python -m hostbootstrap.check_code` passes, and
`poetry run python -m hostbootstrap.test_all` passes 251/251 in 1.89 seconds. The existing governed
Haskell style and testing pages describe this policy accurately and need no contract change.

#### Remaining Work

None.

### Sprint 24.49b: Scope extension pragmas to the branches that use them [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Posix.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Row.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/languages/haskell.md`, `documents/engineering/testing.md`

#### Objective

Keep the Windows refusal branches' required language extensions while allowing the POSIX lint
preflight to reject unused pragmas. This sprint owns two production source modules.

#### Deliverables

- Guard `EmptyCase` in the POSIX ownership module with the existing Windows CPP condition, retaining
  the extension required by its Windows empty cases.
- Guard `OverloadedStrings` in the ownership-row selector with the Windows condition that uses it.
- Validate the source-only change with the host static gate; native Windows confirmation remains
  owned by Phases 27 and 28, and Sprint 24.50 separately owns the live worked-demo confirmation.

#### Validation

On 2026-10-16, both modules pass focused Fourmolu 0.19.0.1 and HLint 3.10 checks. The finalized
pragmas compile in the native macOS core build and complete demo workspace build/test; its core
component and 159/159 demo cases pass. The subsequent native
`cabal test all --test-show-details=direct --test-options=--hide-successes` from `core/` exits 0 with
2,552/2,552 in 453.84 seconds plus the provider-live component's declared no-request result.
Both Python host-static commands pass, with 251/251 tests in 1.89 seconds. The same current source
also passes the complete arm64 Linux static gate recorded in Phase 28. These are POSIX-host
confirmations; the reopened Windows acceptance retains its own required native run. The governed
style and testing contracts remain accurate.

#### Remaining Work

None.

### Sprint 24.50: Revalidate the worked demo against the complete authored source [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`, `documents/operations/demo_runbook.md`

#### Objective

Re-establish this phase's complete gate after the formatter and conditional-pragma work owned by
Sprints 24.49a and 24.49b, the assertion-frame durable-root adoption owned by Sprint 24.38,
and the absent-provider reverse admission owned by Sprint 24.46.

#### Deliverables

- The complete host static gate, core build, demo build, and focused demo suite pass against the complete authored tree.
- Production init, up, down, and destroy pass through a supported universal `linux-cpu` realization,
  followed by the complete Harness matrix reporting `10/10 passed`.
- Terminal ownership, Production-data preservation, and ambient-state restoration are audited, and
  dated gate evidence records every declared leg and a fresh measurement over this phase's evidence paths.

#### Validation

**2026-10-20 — complete phase gate passes.** Sprint 24.46 records the complete native
host static gate and actual absent-Lima callback probe. Before Production initialization, the
29-root, 862-file source scope measures
`0b27634921cf2e486ef70fcefcc27943206f30197760b685a60ec81d247f80e7`.
All four demo generated-state roots are absent, as are installed identities and Lima instances.
The fresh 16:36 UTC ambient baseline contains the running Colima `default` profile
(9 CPUs, 32 GiB memory, 512 GiB disk), Docker context `colima`, and 38 Docker containers,
including the separately owned arm64 Linux static-gate container. Unrelated workloads are
preserved against this pre-live baseline. The explicit CPU/arm64 rolling-base pull resolves
`sha256:c5bedce2f8cc9bcdc82d46eedfda9bb10bbb2837b64d59258a777a18988590cf`, and Phase 23's
input digest remains unchanged. Repository Python-bootstrapper
`poetry run hostbootstrap run --project-root demo project init` starts at 16:36:29 UTC;
its cold local store resolves against Hackage index state `2026-10-20T12:40:44Z`.
Initialization exits 0 at 17:02:09 UTC after 1,540.15 seconds. The installed binary measures
`60ff3279b02f88ccce2e43e21a66270973528460946780fae49646d0bab682fe`, and the generated
Production config measures `6d5fdb277fbf7a775689f22686c987c5efa923a4611ce7b418d9b4ec9ca06990`.
The five installed identity artifacts are regular, single-link, 32-byte mode-0600 files;
their hashes and file metadata are retained for subsequent comparison. At this checkpoint,
test config, `.hostbootstrap`, `.data`, `.test_data`, and Lima instances are absent.

Production `project up` runs from 17:03:15 to 17:36:29 UTC and exits 0 in
1,994.18 seconds. The native VZ/aarch64 Lima guest has the declared 6 CPUs, 10 GiB memory,
and 80 GiB disk; its machine identity is `a23a05228b31446f83194b64d7573d33`.
Its staged source independently matches the pre-gate Phase 24 scope and the Apple live scope
`ecf6b4522ebbd983f3f702fe6b95e14c7d1c3843811b7fb0c781b3a5a094d0e7`.
The container quality gate and exported-runtime/configuration/public-key/web-bundle verification
pass, producing derived image
`sha256:57c4024a5140c161fcea49f7f3eaf4bd2f4da357749f21b6a03321de229adc76`.
The command reports web readiness at `http://127.0.0.1:32769/` and host-daemon readiness at
`ws://127.0.0.1:32771/api/accelerator/daemon`, PID 8118. An independent observation finds all
12 pods Running and Ready and the daemon reparented to native host PID 1. The independent
17:42:09 UTC application probes pass: the authenticated web exposure returns HTTP 200;
`/api/budget` confirms the declared budget fits; accelerator addition of 1.5 and 2.25 returns
3.75 with backend `apple-metal` and artifact fingerprint `a2d3bf4f0f5612bb`. The daemon launches
a native arm64 Mach-O worker. Marker POST and GET both return `hostbootstrap-destroy-up-v1`,
and the canonical `.data/web/marker` has SHA-256
`05932ad6080575c3081d3870d02780bd1e2750c039f2e4cee37a69de1eeb1c21`.
Binary, Production config, and all five identity artifacts exactly match the post-init metadata
and hashes. The following Production reversal and Harness results complete the live gate.

Canonical `project down` exits 0 at 17:47:05 UTC in 285.56 seconds, including a stale-index
refresh to `2026-10-20T17:20:44Z` and its affected dependency rebuild. This rebuild legitimately
replaces the installed executable bytes with SHA-256
`dfbc5f5b798c54f32d3f46a55b91cd2c9d1146d06035fec711dad3649401ced2`;
its inode and size remain the same, and all five identity artifacts and the Production config
retain their complete post-init hashes and metadata. The provider is observed Stopped with
the same directory identity and declared budget. Canonical `project destroy` starts at
17:47:50 UTC to reopen the retained frame for terminal child release.

`project destroy` exits 0 at 17:48:04 UTC in 14.04 seconds. The independent observer sees
the original provider directory inode 480937611 transition Stopped → Running → absent;
the command explicitly starts the stopped frame before releasing its retained children.
The 17:48:26 UTC terminal audit passes: the actual Production lease is Closed at version 5,
epoch 3; its profile remains Consumed at version 2, epoch 1; the project journal is Closed
at version 2; the reverse root is Terminal Destroy at version 6; and the coordinator is Idle
at version 45, sequence 22. No mode, config/data-root ownership, provider directory,
daemon claim/witness, or project process remains. The complete retained `.data` tree has
40 entries (15 directories and 25 regular files), 10,535 file bytes, no symlinks, and
descriptor-relative no-follow fingerprint
`85f63dc8237b2d735ad25ca14596d11b30097554d7b52b26be64194120374441`.
The marker retains its content and inode 480945445. This complete tree and the terminal
record hashes are the preservation baseline for the Harness leg.

Only the verified generated Production sibling config is removed. Canonical `test init`
exits 0 at 17:48:57 UTC in 2.32 seconds and writes the 236-byte operator test config,
SHA-256 `8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`.
The installed executable and all five identity artifacts match the post-Production snapshot.
The source scopes still match their pre-gate measurements; Lima is empty, and ambient
Colima/Docker inventories and configuration hashes match the pre-live baseline. The matrix
starts at 17:49:19 UTC with 652.25 GiB free, against its declared 6-CPU/10-GiB/80-GiB budget.
The complete result and terminal preservation audits follow below.

The first Harness generation is observed at 17:49:33 UTC for `hello-world`, run
`run-3f91a394f28d8`: fresh machine identity `4b75e581ad5b42e1ac4cff747f75f799`,
provider directory inode 480962371, and the declared 6-CPU/10-GiB/80-GiB budget.
Its physical run root matches the protected data-root ownership, and both staged source
scopes match the host at 17:49:44 UTC. It starts with no project binary, images, or containers.
Its guest-native build is complete by 18:05:38 UTC, with 152 core and 11 demo object files.
The explicit base pull returns the published CPU/arm64 digest, and the derived image passes
the container quality gate and exported runtime/config/public-key/web-bundle verification
by 18:16:39 UTC. The independently observed image is
`sha256:5f26dabda263e1eb38e8c8041ea2ee244fb0522bd0b9943b59d9960f262093c1`.
The first native daemon is Ready by 18:21:43 UTC and its Metal worker is observed at
18:21:48 UTC. The engine then performs the same-run destroy/recreate. The independent
18:23:18–31 UTC gap audit observes the exact marker under run-root inode 480962139,
marker inode 480981023, with the expected bytes and SHA-256
`05932ad6080575c3081d3870d02780bd1e2750c039f2e4cee37a69de1eeb1c21`.
Its identity/content survive the first provider's removal and the replacement's startup,
before that fresh guest has an application. Marker permissions change from 0644 to 0666
during declared re-preparation; the run root remains 0700. The first daemon and worker
are absent by 18:23:25 UTC. Generation 2 has fresh provider directory inode 480981109
and machine identity `236d0aaf2f374bbfa09751e6d352f572`; it is up and staging the same
run's source/config by 18:26:22 UTC.
Both staged source scopes match again. Generation 2 completes its guest-native build by
18:41:49 UTC, pulls the same published base, and passes the container quality gate and
exported-runtime/config/public-key/web-bundle verification by 18:54:50 UTC. Its independently
observed derived image is
`sha256:4cf11e4f0b16002c2d2996a0b87e376585f397d17145becce289ad22c025cfb7`.
Its application redeploys for the same-run after-restart assertions.
At 18:52:04 UTC an independent mid-matrix audit confirms the entire Production `.data`
fingerprint and metadata remain unchanged, as do its terminal lease/profile/reverse-root/
journal/coordinator record hashes. The installed binary, all five identity artifacts, and
operator test config also match their preservation snapshots. This checkpoint does not
stand in for the still-running matrix or its final audit.

Generation 2 reaches host-daemon readiness at 18:59:36 UTC, opens the same-run
after-restart assertions, and completes terminal destroy before the next variant begins.
At 19:01:00 UTC the first actual Harness lease is Closed at version 6, epoch 7; its profile
is Available at version 3, epoch 6. Its generated-config/data-root ownership and physical
run root are absent. Persisted Harness project journal rows remain Open with Idle
coordinators, separately from the final Closed lease; no journal-closure claim is made.
Generation 3 is observed at 18:59:57 UTC for `hello-universe`, run
`run-3fcf16c002e28`: fresh machine identity `cf251fd0173744d79d28e0d1d4c557d3`,
provider directory inode 481001533, declared 6-CPU/10-GiB/80-GiB budget, and exact owned
data-root inode 481001489/mode 0700. Both staged-source scopes match at 19:00:07 UTC.
This guest starts with no project binary, images, or containers; its cold bootstrap is
complete by 19:15:19 UTC, with 152 core and 11 demo object files. Its explicit base pull
returns the same published CPU/arm64 digest, and its derived image passes the container
quality gate and exported-runtime/config/public-key/web-bundle verification by 19:27:41 UTC.
The independently observed image is
`sha256:0a5838e804c9ef9b5dfd335fabbdeeb186f58d984fddcdc3fab5fe4b97d1eedc`.
Current-visit guest provenance is observed at 19:15:31 UTC: Ubuntu 24.04.4 LTS,
aarch64 Linux 6.8.0-117-generic, GHC 9.12.4, Cabal 3.16.1.0, and Python 3.12.3.
The subsequent rollout and same-run restart are recorded below.

Generation 3 reaches native host-daemon readiness at 19:32:13 UTC, with its Metal worker
observed at 19:32:17 UTC and all 12 pods Ready. During the second engine-owned same-run
destroy/recreate, the 19:33:49–19:34:00 UTC gap audit captures the exact marker at inode
481020405 and the expected bytes/SHA-256. These survive the old provider's removal and
the replacement's Stopped → Running transition before the fresh application exists.
Marker permissions change from 0644 to 0666; run-root inode 481001489 remains 0700.
The old daemon and worker are absent by 19:33:56 UTC. Generation 4 is observed at
19:34:11 UTC: fresh machine identity `77b0cf6eec8c4ae1be74f528cd20dc00`, provider
directory inode 481020640, and the declared 6-CPU/10-GiB/80-GiB budget. It retains the
exact same second-run root, lease/profile epoch 10, and matching staged source scopes
at 19:34:21 UTC. It executes the final cold rebuild and after-restart assertions.
Generation 4 completes its native build by 19:50:00 UTC, pulls the same published base,
and passes the container quality gate and exported-runtime/config/public-key/web-bundle
verification by 20:02:05 UTC. Its independently observed Linux/arm64 derived image is
`sha256:1faf1813adbe5ea66a55b6a1874f92916ae4ffdbf7e068a0f3721b4750cb6cc5`.
The retained marker still has inode 481020405 and the expected 27-byte content/hash before
the final application assertions. The final deployment, assertions, and terminal audits
complete below.

The complete matrix exits 0 at 20:07:19.964 UTC in 8,280.90 seconds, reporting **10/10 passed**.
Both variants pass `pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence`,
and `durable-readback`, including both same-run assertion phases. All four fresh native
providers and their source/image identities are independently observed:

| Generation | Variant / run | Guest machine identity | Derived image SHA-256 |
|---|---|---|---|
| 1 | hello-world / `run-3f91a394f28d8` | `4b75e581ad5b42e1ac4cff747f75f799` | `5f26dabda263e1eb38e8c8041ea2ee244fb0522bd0b9943b59d9960f262093c1` |
| 2 | hello-world / `run-3f91a394f28d8` | `236d0aaf2f374bbfa09751e6d352f572` | `4cf11e4f0b16002c2d2996a0b87e376585f397d17145becce289ad22c025cfb7` |
| 3 | hello-universe / `run-3fcf16c002e28` | `cf251fd0173744d79d28e0d1d4c557d3` | `0a5838e804c9ef9b5dfd335fabbdeeb186f58d984fddcdc3fab5fe4b97d1eedc` |
| 4 | hello-universe / `run-3fcf16c002e28` | `77b0cf6eec8c4ae1be74f528cd20dc00` | `1faf1813adbe5ea66a55b6a1874f92916ae4ffdbf7e068a0f3721b4750cb6cc5` |

The final host daemon is Ready at 20:07:10 UTC. The independent terminal audit passes at
20:07:38 UTC: all three actual leases are Closed (Production version 5/epoch 3;
Harness version 6/epochs 7 and 11). Production's profile remains Consumed at version 2,
epoch 1; Harness profiles are Available at version 3, epochs 6 and 10. Production's
Closed journal/reverse-root and all retained terminal record hashes match the post-destroy
baseline. Both Harness journals persist as Open at version 1; all three coordinators are
Idle (Production sequence 22, Harness sequence 41 each). No project mode, config/data-root
ownership, generated sibling config, Lima VM/directory, daemon claim/witness, or native
owned process remains; `.test_data` exists and is empty.

The entire Production `.data` tree exactly retains its 40-entry, 10,535-byte fingerprint
`85f63dc8237b2d735ad25ca14596d11b30097554d7b52b26be64194120374441` and metadata.
The post-Production executable `dfbc5f5b798c54f32d3f46a55b91cd2c9d1146d06035fec711dad3649401ced2`,
all five identity artifacts, and operator test config retain their exact metadata and hashes.
The native post-matrix source measurement still matches all pre-gate scopes, including Phase 24's
29 roots/862 files at `0b27634921cf2e486ef70fcefcc27943206f30197760b685a60ec81d247f80e7`.
Ambient Colima profile/budget/configuration, Docker context, all 38 pre-live container identities,
all 11 image entries, and credential-configuration hashes are unchanged; Docker image listing
order differs, with no image-set change. All three owned observers stop with exit 0 at
20:08:08 UTC, and their exact PIDs are absent. The separately owned Linux static-gate
container is retained through final documentation validation, then removed at 20:19:05 UTC;
Phase 28 records its 11/11 Linux documentation check and unchanged ambient-state audit.
The native closing `DocValidatorSpec` command passes 11/11 in 3.56 seconds at
20:14:47 UTC (301.80 seconds including the refreshed dependency/project/test build),
before the next phase's separate live Colima gate starts.

The preceding x86_64 gate row retains its original commands and provenance:

- 2026-10-17 ; `hostbootstrap-cpu-gate-20261016`, x86_64 Ubuntu
24.04.5 LTS, Linux 6.8.0-147-generic, GHC 9.12.4, Cabal 3.16.1.0,
Poetry 2.5.1, Python 3.12.3, complete gate executed 2026-10-16–17 UTC ;
`cabal build all` and `cabal test all` from `core/`,
`cabal build all`, `cabal test all`, and `cabal test hostbootstrap-demo-test`
from `demo/`, `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` from the repository root,
plus repository Python-bootstrapper
`poetry run hostbootstrap run --project-root demo project init`,
`poetry run hostbootstrap run --project-root demo project up`,
`poetry run hostbootstrap run --project-root demo project down`,
`poetry run hostbootstrap run --project-root demo project destroy`,
`poetry run hostbootstrap run --project-root demo test init`, and
`poetry run hostbootstrap run --project-root demo test run all`
reporting `10/10 passed`, followed by terminal ownership,
Production-data preservation, ambient-state, and covered-source audits ;
pass ; covers 2270a6319a8e5bc12c64b9edf057f031f79ba673af2677a9cfcf001b3551d11b

The preceding native Apple run retains its actual commands and source provenance:

-  2026-10-16 ; `MacBookPro`, native arm64 macOS 26.6.2 (build 25G83),
Apple M1 Max, 64 GiB memory, Lima 2.1.2, Colima 0.10.3, GHC 9.12.4, Cabal 3.16.1.0,
Fourmolu 0.19.0.1, HLint 3.10, Python 3.14.3, Poetry 2.3.2 ;
`cabal build all` and `cabal test all --test-show-details=direct --test-options=--hide-successes`
from `core/`, `cabal build all --ghc-options=-Werror`, `cabal test all --ghc-options=-Werror`,
and `cabal test hostbootstrap-demo-test --test-show-details=direct --test-options=--hide-successes`
from `demo/`, `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` from the repository root, plus repository
Python-bootstrapper `poetry run hostbootstrap run --project-root demo project init`,
`poetry run hostbootstrap run --project-root demo project up`,
`poetry run hostbootstrap run --project-root demo project down`,
`poetry run hostbootstrap run --project-root demo project destroy`,
`poetry run hostbootstrap run --project-root demo test init`, and
`poetry run hostbootstrap run --project-root demo test run all` reporting `10/10 passed`
through the native Lima/aarch64 universal `linux-cpu` realization, followed by terminal ownership,
Production-data preservation, ambient-state, and source-digest audits ; pass ;
covers 82fe6ef5ab04aee2488bf374f13f178cac1f0f8df0c170ee802aea243adfb042

On 2026-10-16 the complete declared gate passes on `MacBookPro`, native arm64 macOS 26.6.2
(build 25G83), Apple M1 Max, 64 GiB memory, with the toolchain and commands in the preceding
preserved dated row.
The phase was reopened before the covered source edits; Sprint 24.49 retains its preceding Windows
pass, original source scope, and digest. That Apple run's 29-root, 862-file scope measures
`82fe6ef5ab04aee2488bf374f13f178cac1f0f8df0c170ee802aea243adfb042` before and after the live run.

The compatible publication preflight passes every Fourmolu 0.19.0.1 and HLint 3.10 root; focused
checks also pass both finalized Windows-only pragma guards. The demo source/app roots additionally
pass Fourmolu 0.21. The core build and full demo workspace build/test pass, including 159/159 demo
cases in 5.51 seconds and its core component. The separately declared demo test target passes
159/159 in 5.45 seconds. A final native `cabal test all` refresh against the settled source exits 0
with 2,552/2,552 in 453.84 seconds and the provider-live component's declared no-request
`Unsupported` result. Both Python host-static commands pass; the final runner passes 251/251 in
1.89 seconds. A separate coverage run passes 251/251 in 1.65 seconds with 100% over 1,413 statements.
`poetry run hostbootstrap doctor` reports `apple-silicon (arm64)` and passes its prerequisites.

The canonical CPU/arm64 base publication exits 0 at 15:14 UTC after source preflight, native build,
local-image consumer smoke, publication, explicit pull, and published-image consumer smoke.
Phase 23 records the dated publication. Production and all four Harness guests explicitly pull
`docker.io/tuee22/hostbootstrap@sha256:c5bedce2f8cc9bcdc82d46eedfda9bb10bbb2837b64d59258a777a18988590cf`.
The derived-image bootstrap verifies the exported runtime, configuration, public keys, and web bundle
before descent. The observed Lima guest is Ubuntu 24.04.4 LTS, aarch64 Linux 6.8.0-117-generic,
with Cabal 3.16.1.0; the native `vz` realization carries 6 CPUs, 10 GiB memory, and 80 GiB disk.
No architecture emulation or nested virtualization is used.

Production init exits 0 at 14:59 UTC. Its installed executable measures
`68c15238abe4700e7a270c1e4d5b424ee5ba3d2efd4fb0ffe6f5283460ee5abf` and its generated config
`6d5fdb277fbf7a775689f22686c987c5efa923a4611ce7b418d9b4ec9ca06990`.
Production up runs approximately 15:15–15:48 UTC and exits 0 with the web service and host daemon
Ready; the exposed web root independently returns HTTP 200. Its guest machine identity is
`b9fe9529e3fe44499db3586fab5ea88a`, and its derived image is
`sha256:d7b5986a56cbf99bc8b098ebefebe514070e0f458300e669b37168253d68d60b`.
Down exits 0 at 15:48 UTC. Destroy exits 0 at 15:49 UTC after restarting the stopped VM to release
retained children and deleting it. The read-only audit observes Production lease Closed epoch 3/
version 5, profile Consumed epoch 1/version 2, reverse-root Terminal Destroy version 6, and journal
Closed at transaction sequence 22/version 2. An initial audit-decoder assertion is resolved by
unwrapping the journal's nested transaction envelope; no stored state or source changes.

After verifying the generated Production config's regular-file identity and exact digest, only that
sibling config is removed through the prescribed operator step. Test init exits 0 and writes the
operator test config, measuring `8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`.
The complete matrix runs approximately 15:51–17:59 UTC (about 129 minutes), exits 0, and reports
`10/10 passed`. Each variant passes `pristine-bootstrap`, `web-build`, `e2e-tabs`,
`registry-persistence`, and `durable-readback`. The engine performs four fresh Lima bring-ups and
four terminal destroys, including one same-run recreation per variant. A separate read-only observer
captures these identities before automatic teardown and exits 0:

| Generation | Variant / run | Guest machine identity | Derived image SHA-256 |
|---|---|---|---|
| 1 | hello-world / `run-2b855a179ead0` | `90d244c12ff24ff496ad9419957f8b9f` | `183b4a3cf451d60c2b8e40be2ccd182c97e057e1ffdc1089740ffa9d5a36e03b` |
| 2 | hello-world / `run-2b855a179ead0` | `34a3b8414d6b4ab29821357252960c62` | `84ffdb54b49064ce44acc6f2e3a9361b3cdf441c9e3300ec4109d94939a4c1b8` |
| 3 | hello-universe / `run-2bbd549fc29c0` | `8d94d8f28325443ea634cc02b36dc305` | `ec32ccc193e55ca8f8a28308a3dc3a84c78eaf345b24523098c8a5006fbc798c` |
| 4 | hello-universe / `run-2bbd549fc29c0` | `f0b143a362b8495c8a40ad431fde4408` | `bb88b4bfbcfce681ff1df55d9f5e7eabcda5e493e7bfc75975070d19d9487767` |

The 18:00 UTC read-only terminal audit passes without discrepancies. Both Harness leases are
Closed at version 6, epochs 7 and 11; profiles are Available at version 3, epochs 6 and 10,
with forward lease version 4. Production closure records remain exactly unchanged. No ephemeral
mode/config/data-root ownership record, live demo daemon/worker, daemon protected owner, or
PID/ready/shutdown/output witness remains. Lima is empty, the generated Production sibling config
is absent, the operator test config is unchanged, and `.test_data` exists and is empty.

The complete retained Production `.data` tree matches its post-Production fingerprint exactly:
`4b1bb49a369f2ce3680822979fdbe2c1994b9a5e29763e6ab95fd11a5d0504b8`, 39 entries
(15 directories and 24 regular files), 10,508 file bytes, no symlinks, and unchanged root device
16777230/inode 470616174/mode 0755. Descriptor-relative no-follow streaming verifies the full tree.
The installed binary bytes/identity and all five 32-byte mode-0600 identity-file metadata remain
unchanged. The ambient Docker context, Colima profile listings/configuration hashes, and Docker
credential hash match the visit's initial snapshot. Unrelated workloads are left in place; their
container IDs are not claimed stable during concurrent external work. The separate Phase 28 static
container remains temporarily for final documentation validation and its own cleanup.

The runbook now states the combined pristine-visit Production-to-Harness sequence and the separate
native direct-Colima leg. No runtime contract changes. The unchanged-source Apple matrix also supplies
Phase 25's matrix leg; that phase separately owns Metal/direct-Colima acceptance and its 845-file digest.

On 2026-10-16–17 UTC, the corrected source passes the complete static gate, Production
lifecycle, and full Harness matrix on the independent x86_64 CPU gate host
`hostbootstrap-cpu-gate-20261016`, UUID `6c040aea-0554-4f14-ab67-30c27bbd18a1`,
provisioned through Incus on `matt-caledon-desktop`. The gate host runs Ubuntu 24.04.5 LTS,
Linux 6.8.0-147-generic, with 8 CPUs, 24 GiB memory, and a 250 GiB sparse root disk.
Nested AMD virtualization is enabled; the KVM API and VM-creation ioctl pass, NVIDIA markers
are absent, and the repository bootstrapper's `doctor` reports `linux-cpu (amd64)`.
Its own Incus project starts empty. The pre-existing stopped metal VM is preserved.

The corrected working-tree source and real checkout metadata are copied into `/root/hostbootstrap`
without build state, caches, installed identities, or credentials. GHC 9.12.4, Cabal 3.16.1.0,
Poetry 2.5.1, and Python 3.12.3 drive the run. Independent initial metal and guest measurements
agree on the 29-root, 862-file scope:
`2270a6319a8e5bc12c64b9edf057f031f79ba673af2677a9cfcf001b3551d11b`.
The complete static gate starts at 2026-10-16 20:09:04 UTC after the pristine-state audit.
Its actual command results are:

- From `core/`, `cabal build all` passes its cold build in 1,085.23 seconds, and
  `cabal test all` passes 2,552/2,552 in 191.17 seconds (354.15 seconds including the test build).
- From `demo/`, `cabal build all` passes in 15.32 seconds,
  `cabal test hostbootstrap-demo-test` passes 161/161 in 1.82 seconds, and canonical
  `cabal test all` exits 0 in 353.16 seconds, including 2,552/2,552 core cases in 201.73 seconds.
- From the repository root, `poetry run python -m hostbootstrap.check_code` passes, and
  `poetry run python -m hostbootstrap.test_all` passes 251/251 in 2.30 seconds.

Both provider-live components report their declared no-request disposition; these are not live
provider acceptance results. The demo static leg starts at 20:33:41 UTC after the Production
bootstrap releases its Cabal build tree. The external
`/root/.config/hostbootstrap-phase24/cabal.config` preserves baseline settings and selects only
the existing `/root/hostbootstrap/demo/.build/cabal-store`, avoiding another cold dependency
build without changing source or solver inputs.

All live commands use this checkout's repository Python bootstrapper,
`poetry run hostbootstrap run --project-root demo`. Production `project init` exits 0 in
1,308.36 seconds. `project up` starts at 2026-10-16 20:32:56 UTC and exits 0 in 3,325.49 seconds.
Its native inner Incus provider has 6 CPUs, 10 GiB memory, 80 GiB storage, and UUID
`8e09d5e3-10ba-4745-ae9e-31972e25f3d1`. The generated config and installed binary hashes,
and all five 32-byte, mode-0600 identity-file metadata, are captured without reading key bytes.
Production and all four Harness generations anonymously pull the published CPU/amd64 base,
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`, matching
Phase 23's published evidence. Base inputs remain unchanged. Production's container quality gate
and exported-runtime verification pass at 21:18:37 UTC, producing derived image
`sha256:37d4f8220e4fdf9ada80d8d8a0f3b5d8a142775bdfbd5f3a960bebbf9ad8a6b4`.

The independent 21:28:37 UTC application check verifies the 182-byte HTML, 102,333-byte bundle,
fitting 6-CPU/10-GiB/80-GiB budget, and actual accelerator result `3.75` on the `linux-cpu`
artifact `1cde4043891ef815`. Marker POST and GET both return `hostbootstrap-destroy-up-v1`;
the canonical outer `.data/web/marker` holds the same 27 bytes, SHA256
`05932ad6080575c3081d3870d02780bd1e2750c039f2e4cee37a69de1eeb1c21`.
Canonical `project down` exits 0 in 40.97 seconds and `project destroy` in 40.50 seconds.
The 21:31:21 UTC Production audit finds the inner provider absent, the actual lease Closed at
version 5, epoch 3, its profile Consumed at version 2, epoch 1, and no mode/config/data-root
ownership or host-daemon/process witness. The journal is Closed at version 2, transaction 19;
the reverse-root record is Terminal Destroy at version 6, target 3. Its retained admission
successor is Bound at version 4, epoch 3, distinct from the actual final Closed lease.
The binary and all five identity-file metadata remain unchanged. The retained `.data` tree has
44 entries (17 directories and 27 regular files), 10,514 file bytes, and streaming no-follow
fingerprint `917683fa25ef40887e5e54844e01841ba88812ed515b17c03917c1252ead65d0`.
The marker retains its bytes, hash, inode, mode, and owner through both reversals.

After verifying and removing only the generated Production sibling config, canonical `test init`
exits 0 in 3.51 seconds. The 236-byte regular operator test config measures
`8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`.
The complete canonical `test run all` starts at 2026-10-16 21:31:59 UTC, exits 0 at approximately
2026-10-17 01:08 UTC after 12,968.49 seconds, and reports `10/10 passed`. Both variants pass
`pristine-bootstrap`, `web-build`, `e2e-tabs`, `registry-persistence`, and `durable-readback`.
Each variant retains its exact run/config across its engine-owned destroy/recreate and completes
both assertion phases. All four fresh providers are independently observed; each passes its native
bootstrap, container quality gate, and exported-runtime verification:

| Generation | Variant / run | Provider UUID | Guest machine identity | Derived image SHA-256 |
|---|---|---|---|---|
| 1 | hello-world / `run-5d21ca81fe0` | `6c76d09d-36db-4626-bd25-0c0c8829c179` | `6c76d09d36db4626bd250c0c8829c179` | `f95b9fb48cefe7711021b20ae1c5cf99c12ceef028fcd822ba3ae3b8db76c2be` |
| 2 | hello-world / `run-5d21ca81fe0` | `9dcf0c20-b3d1-4b8d-87ed-14e496d58832` | `9dcf0c20b3d14b8d87ed14e496d58832` | `b6102824d379204179e1a46f0522ae135c3f497959d7b89aefa23364494f091f` |
| 3 | hello-universe / `run-bb655a33e1c` | `5b2686ce-396c-4634-bc07-0a3441682758` | `5b2686ce396c4634bc070a3441682758` | `7d4f288c6153cfe531b88942fb28d14e0f0d39799690f11a5bf8148ab0c440a2` |
| 4 | hello-universe / `run-bb655a33e1c` | `a1add52f-8114-438c-b8d7-e94771625ff8` | `a1add52f8114438cb8d7e94771625ff8` | `f804ef08f15598c148f6dc181846e1ea6ee6dc358216e9ee923298522bbedaa4` |

The generation-2 provider is created at 2026-10-16 22:25:52 UTC. At 22:27:18 UTC,
before its application build, descriptor-relative no-follow traversal independently reads the
exact outer `.test_data/run-5d21ca81fe0/web/marker`: the expected 27 regular-file bytes and SHA256
`05932ad6080575c3081d3870d02780bd1e2750c039f2e4cee37a69de1eeb1c21`, device 2050/inode
2813235, mode 0666, uid/gid 0, and one link. Identity/content metadata is stable through the read;
read-atime is excluded. The bytes remain present after the first provider's destruction and before
the recreated application can write. Generation 2 reaches actual web readiness at 23:19:45 UTC
and CPU-daemon readiness at 23:19:51 UTC, then completes after-restart assertions and terminal destroy.

Generation 3 is created at 2026-10-16 23:20:04 UTC, and generation 4 at 2026-10-17 00:13:59 UTC.
At 00:14:02 UTC, before the recreated application can start, the exact outer
`.test_data/run-bb655a33e1c/web/marker` independently holds the same expected bytes and SHA256.
Descriptor-relative no-follow traversal confirms a regular file, device 2050/inode 2813235,
mode 0666, uid/gid 0, one link, and stable content/identity metadata through the read.
The four derived images are independently observed at 2026-10-16 22:15:46 and 23:10:14 UTC,
and 2026-10-17 00:03:47 and 00:58:10 UTC, respectively.

Generation 4 reaches web readiness at 2026-10-17 01:07:53.326 UTC and CPU-daemon readiness
at 01:07:58.274 UTC, with `DaemonConnected` and the `linux-cpu` artifact `1cde4043891ef815`.
Its after-restart assertions and terminal destroy complete before the final matrix report.

The independent terminal audit passes at 2026-10-17 01:08:55.705694 UTC. The two actual Harness
leases are Closed at version 6, epochs 7 and 11; their profiles are Available at version 3,
epochs 6 and 10, with forward lease version 4. No project mode, generated-config ownership,
data-root ownership, generated sibling config, provider VM, daemon directory/owner/witness,
or live project process remains. `.test_data` exists and is empty. The operator test config's
content and metadata remain unchanged, with its original SHA256
`8a88f68edd459803fe6ffa8a60cabc4615fea91ce489842a6ba798fbab43136b`.
Both retained Harness project journals are Open at version 1, transaction 1, as the declared
source semantics permit: `finalizeHarnessClose` closes the actual run lease and then releases
the exact mode epoch. These journal rows are recorded separately from the final Closed leases.

The complete retained Production `.data` tree exactly matches its post-Production no-follow
fingerprint `917683fa25ef40887e5e54844e01841ba88812ed515b17c03917c1252ead65d0`:
44 entries, 17 directories, 27 regular files, and 10,514 file bytes. The Production lease
Closed at version 5, epoch 3, profile Consumed at version 2, epoch 1, journal Closed at
version 2, transaction 19, and reverse-root Terminal Destroy at version 6, target 3 retain
their exact recorded byte hashes. The installed binary retains its file identity and SHA256
`d3a1b5fc390411f7771d9e74da0be3ebab9159b3ce7371f6069c630056c4bdeb`;
all five 32-byte, mode-0600 identity-file metadata remain unchanged.

The final metal and guest measurements agree over all 29 roots and 862 files at
`2270a6319a8e5bc12c64b9edf057f031f79ba673af2677a9cfcf001b3551d11b`, matching the
pre-gate source. The 01:09:22 UTC native ambient-state audit passes: the pre-existing stopped
Incus VM is unchanged, Docker reports no containers, no compute GPU process remains, and the
same Xorg PID 1734 and GNOME PID 1886 remain.

After the final seven-file documentation sync, the closure `DocValidatorSpec` check passes
11/11 natively in 3.66 seconds and 11/11 on the gate host in 3.89 seconds. All five guest
phase covers digests still match after that sync. The independent observers stop cleanly at
01:10:25 UTC, with an empty inner provider inventory.

At 01:11:38 UTC, the separately owned development gate host is deleted after re-verifying its
exact UUID. The 01:11:55 UTC cleanup audit confirms that exactly its two IP-scoped forwarding
rules are removed and `DOCKER-USER` has no remaining rule. The only metal Incus instance is the
pre-existing stopped `hostbootstrap-demo-vm`, unchanged at UUID
`a62c4700-1bd7-45a1-9497-4b165a60ee91`. Docker and GPU-compute inventories remain empty,
the same Xorg/GNOME PIDs remain, and the original metal GHC 9.14.1 default is restored.
The post-cleanup 29-root, 862-file source measurement still matches
`2270a6319a8e5bc12c64b9edf057f031f79ba673af2677a9cfcf001b3551d11b`.

#### Remaining Work

None.

## Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/unrepresentable_state.md` — the surface this phase changes in it.
- `documents/architecture/ownership_invariant.md` — the surface this phase changes in it.
- `documents/architecture/hostbootstrap_core_library.md` — the surface this phase changes in it.
- `documents/architecture/harness_workflow.md` — the surface this phase changes in it.
- `documents/architecture/generic_project_model.md` — the surface this phase changes in it.
- `documents/architecture/binary_context_config.md` — the surface this phase changes in it.

- `documents/architecture/network_reachability.md` — runtime-owned loopback exposure and resolved endpoints.
- `documents/architecture/lifecycle_state_model.md` — the canonical/live dependency registries and fresh
  provider/cluster refinements.
- `documents/architecture/composition_methodology.md` — the exact provider, cluster, workload, reverse, and
  projector composition order.

**Engineering docs to create/update:**
- `documents/engineering/resource_budgeting.md` — the surface this phase changes in it.
- `documents/engineering/derived_project_standards.md` — the surface this phase changes in it.
- `documents/engineering/derived_dockerfile.md` — the surface this phase changes in it.
- `documents/engineering/cluster_lifecycle.md` — the surface this phase changes in it.

- `documents/engineering/testing.md` — what the long gate covers that the static suites cannot.
- `documents/engineering/accelerator_daemon.md` — the per-substrate placement.
- `documents/engineering/build_release.md` — published-base provenance and authenticated derived-image build.

**Cross-references to add:**

- `documents/operations/demo_runbook.md` — the operator sequence, duration envelope, exact `Unsupported` Direct
  reverse boundary, and disposable-host requirement.
