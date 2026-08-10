# System Components

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Inventory the host-management components the repository implements, identify partial or
> definition-only surfaces honestly, and point each open contract to its owning phase.

## Status and Evidence Rule

Current phase status is reported only by the
[README phase table](README.md). This inventory contains no phase-status roll-up and
no mutable “current test count.” Dated validation evidence belongs in phase sprints.

`Implemented` below means the named module/surface exists and satisfies its contract. `Partial` means code
exists but the contract is not fully built, and the owning phase is `Active` and says which sprint carries the
rest. There is no `Definition-only` state: a surface with no consumer is a surface no phase should introduce
(§ A), so it is removed by rewriting the phase rather than tracked.

## hostbootstrap-core Module Surface

| Module | State | Purpose / open contract |
|--------|-------|-------------------------|
| `HostBootstrap.CLI` | Implemented static construction boundary | Fixed command entrypoint and identity-parametric `ProjectSpec cfg tcfg`; the static value carries no lifecycle scope, specification digest, plan, or configuration identity. Scope finalization yields exactly `FinalizedProjectSpec scope specDigest cfg`, retaining the matching codec, typed service registry, and plan builder. Production and Harness dispatch each retain one exact scope-indexed plan per invocation; the Harness variant bracket keeps it alive through generated-config ownership and the shared forward/reverse interpreters. There is no lifecycle slot beside the plan: descent and reverse are declared on the step |
| `HostBootstrap.ProjectPlan` | Implemented pure facade | Opaque `PlanDraft`, generative `ProjectPlan`, `PlannedStep`, `DerivedTopology`, plan-owned `PlannedResource`/edge vocabulary, and public non-authorizing `StablePlanSnapshot`; fresh admission retains the exact scope/spec/config/root/nodes, and forward order, topology, version-3 stable bytes, current-frame evidence, resources, dependency edges, stable step identity, reverse policy, and declared reverse callback are pure projections implemented through Sprint 12.26. The v3 bytes and digest bind the exact canonical-root descriptor, which `stablePlanSnapshotRoot` projects descriptively. Sprint 12.25's specialized authority leaf consumes these projections without adding an authority producer to the pure facade, Sprint 12.26's `HostBootstrap.Teardown.teardownPlan` uses only the public pure projections to derive exact reverse work, and public `HostBootstrap.Chain` consumes `forward` and `DerivedTopology` directly. Production retains or reconstructs that value through render/persist/journal/cursor/authorize/interpret/teardown; each Harness variant retains its exact `ProjectPlan (Harness projectId runId) ...` through generated-config ownership and the same current-frame Chain/reverse boundaries. Lexical package, export, producer, import, and single-admission guards pin that public/private boundary |
| `HostBootstrap.ProjectPlan.Construct` | Implemented fresh/recovered/child construction boundary | Three-parameter `FinalizedProjectSpec scope specDigest cfg`, non-empty concrete draft projection, fresh rank-2 plan admission, and fixed-identity recovered Production reconstruction are implemented. `withChildProjectPlan` consumes a fully indexed `VerifiedConfigHandoff`, the same verified wire/config, and non-empty drafts; it verifies the signed stable revision plus project/protected-store/broker origin and jointly yields the exact fresh child plan, `PlanDigestBinding`, and opaque fully indexed `ChildPlanAuthority`. Fresh ordinary admission consumes the exact `CanonicalProjectRoot` and supplies its absolute path to the version-3 indexed snapshot. Recovery safely aligns an independently finalized candidate definition/config through exact retained specification/configuration digests, regenerates drafts, and yields only the existing-admission `planId` after exact root-bound bytes/digest agreement. Static `ProjectSpec cfg tcfg` remains above this lower scope-finalization boundary |
| `HostBootstrap.ProjectPlan.Frame` | Implemented pure evidence boundary with cursor, authority, and reverse-projection consumers | Sprint 12.14's `withCurrentFrame` purely joins the exact plan to descriptive binary context and jointly generates hidden-constructor `CurrentFrame`, `ProjectFrame`, and `ValidatedContext` under one fresh frame index. It retains the semantic frame `Text` unchanged; Sprint 12.22 defines its canonical UTF-8 cursor-record binding, Sprint 12.23 consumes the exact `ProjectFrame` at cursor admission, Sprint 12.25 consumes the matching `ProjectFrame`/`ValidatedContext` at exact local `project up` authorization, and Sprint 12.26 consumes `CurrentFrame` with the exact `ProjectPlan` to index the pure reverse projection. Pure frame values still grant no journal, cursor, command, lease, or mutation authority |
| `HostBootstrap.ProjectPlan.Snapshot` | Implemented snapshot boundary | Stable snapshot projection, Sprint 12.15's pure `PlanDigestBinding` verification, Sprint 12.16's non-authorizing `BoundPlanSnapshot`, Sprint 12.17's origin-checked persistence/readback plus separate fresh-only lease CAS, and Sprint 12.18's terminal/Open existing-Production admission are implemented. Existing admission structurally validates the bounded version-3 root field and accepts only an absolute root or the shared `Reconcile.LifecyclePlan` compatibility sentinel before minting local evidence. The pure recovered-profile refinement is owned by `HostBootstrap.Lifecycle.Mode`, exact recovered-plan reconstruction is owned by `HostBootstrap.ProjectPlan.Construct`, and Sprint 12.21's plan-bound journal admission is implemented in `HostBootstrap.Lifecycle.Mode` rather than this snapshot facade |
| `HostBootstrap.Command` | Partial | Parser/dispatch and command gates. The `test` grammar is closed against the project's typed vocabulary: `test run` names a `CASE-ID` (or the whole-matrix selector) and refuses an unknown case by naming the compiled set, and `test init` writes through an opaque `TestConfigWrite` whose producer resolves the sibling destination itself, refusing an existing file by name unless `--replace` is passed. Production lifecycle dispatch first reconstructs an existing bound plan or admits the one lawful fresh/unbound-retry plan. Dry rendering, snapshot persistence/binding, journal/cursor admission, `authorizeProjectUp`, public Chain interpretation, and exact current-frame teardown consume that value; at a declared descent it fails closed rather than invoking an unauthenticated child. Harness dispatch finalizes the Harness scope, constructs one plan for the generative run, retains it through generated-config ownership, and packages direct current-frame Chain forward/exact reverse around assertion-only code behind the opaque lifecycle capability; it does not shell a nested `project up`. Ordinary Harness close follows settled destroy, closed-session proof, exact `ProjectClosureEvidence`, close authorization, and ownership settlement; independently proved pre-effect refusal uses the bound fallback without reverse. Phase 13 supplies the authenticated child-plan authority substrate, while [the recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) still owns Production descent, child acquisition integration, and proof-complete recursive traversal. The demo's same-run durable destroy/up/readback cycle remains open in Phase 24. Effect-indexed selected-service dispatch remains with [the service-runtime phase](phase-22-service-runtime.md) |
| `HostBootstrap.Detached` | Implemented boundary | The closed boundary for spawning a child that outlives its launcher (§ HH, [the host-tools-and-substrate-detection phase](phase-3-host-tools-and-substrate-detection.md), landed 2026-08-03). Its assembled `CreateProcess` is private, and so are `DetachedLaunch`'s constructor and *every field accessor*, so the stdio disposition, descriptor inheritance, session, and console detachment are properties of the boundary rather than fields a call site fills in; the executable is an `AbsExe` and the working directory and output sink are absolute by construction. `withDetachedChild` is a rank-2 bracket over the launch, not the child's lifetime: acquire-and-spawn is total, and the body's exceptions propagate unchanged. Standard input is the host's null device (open, at EOF) and both output streams share one retained sink the launcher reads to quote a startup failure (§ CC). `ForgeDetachedLaunch.hs`/`RelabelDetachedLaunch.hs` pin the seals and `DetachedSpec` observes a real child through the boundary. Closed on the Apple Silicon lane 2026-08-03 at `10/10 passed`, where the host daemon reached readiness on all four bring-ups |
| `HostBootstrap.HostTool` | Implemented boundary | Closed tool enumeration and `AbsExe`; every governed host call resolves to an absolute path |
| `HostBootstrap.HostConfig` | Implemented | Resolved host configuration |
| `HostBootstrap.HostPrereqs` | Implemented floor | Haskell host prerequisites aligned with the pre-binary Python floor |
| `HostBootstrap.Substrate` | Implemented | Apple/Linux/Windows CPU/GPU substrate classification |
| `HostBootstrap.Ensure*` | Implemented reconciler boundary | The nine config-free reconciler families remain. Their pure applicability/diagnostic and install-plan branches plus deterministic already-present, install/re-probe, second-run no-op, refusal, and failure paths at the production `installAndVerify` driver are covered, and the complete owning phase gate is closed. Reconciler actions return raw `IO ()`, not a typed report-card result. `HostBootstrap.Ensure.Colima` is a separate prepared per-project wall adapter, not a member of that reconciler registry: its current compatibility profile opener still consumes `Reconcile.LifecyclePlan` plus `BinaryContext`. Sprint 16.4 replaces those independent terms with the exact `ProjectPlan`, provider `PlannedResource`, topology, partition, and reservation package. Incus already converges and totally classifies daemon reachability, permission, VM capability, and required image-server egress; only the ready branch mints its opaque capability. WSL global-state ownership and recursive command integration remain downstream |
| `HostBootstrap.Cluster.Cordon.Foundation` | Implemented exposed lower boundary | [The canonical-quantities-and-reconcile-results phase](phase-6-canonical-quantities-and-reconcile-results.md) owns opaque canonical-unit `ResourceBudget`, exact quantity parsing/refusal, provider-neutral capacity reads/verification, exact-budget sizing renderers, and the typed bare-Linux unsupported-storage policy. The pure foundation grants no config, provider, or plan authority and imports only lower `HostConfig`, `HostTool`, and `Substrate` families. Public exposure, the exact import-set guard, focused behavior tests, and the complete phase gate are closed |
| `HostBootstrap.Cluster.Cordon` | Implemented configuration facade | [The Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md) owns the public facade that reexports the lower foundation and adapts `Config.Vocab.Resources`/`ResourceEnvelope`, configuration-facing preflight wrappers, and descriptive pure `fitsBudget`. It owns no plan-indexed workload/fit/partition/slice proof and imports no provider realization or cluster lifecycle module. Facade behavior tests, the exact dependency/source guard, and the complete phase gate are closed. [The cluster-lifecycle-and-cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md) owns exact application at cluster/direct-Colima consumers |
| `HostBootstrap.Cluster.Budget` | Implemented exact generic admission; consumers open | Closed provider keys, budget/workload/partition/slice vocabulary, and journal-before-call wall reservation/preparation/settlement exist. Sprint 12.30 owns generic admission from one exact `ProjectPlan`, matching provider/cluster `PlannedResource`s, and its `DerivedTopology`, plus nominal cross-plan guards. Raw backend observations remain plan-independent; prepared and settled packages retain the plan indices. Sprint 16.2 and Sprint 16.4 own cluster and direct-Colima consumer adoption, while Sprint 24.5 supplies the concrete demo workload, overhead, partition, and slices |
| `HostBootstrap.Cluster.Lifecycle` | Partial | The compatibility lifecycle still accepts independently supplied `ClusterProfile`, root, and `ResourceEnvelope`. Sprint 16.2 replaces the cluster preparation/reconciliation path with the exact plan-owned cluster resource, provider dependency, topology, and slice, retaining indices through readiness and settlement. Its raw backend observation remains plan-independent. The pure teardown partition and `PreserveOnReverse` projection already keep durable state out of removal work. Sprint 24.4 makes the demo consume the plan-owned profile/root projection, and Sprint 24.3 owns live same-run durable readback |
| `HostBootstrap.Cluster.Backend` | Implemented clause-holding backend; exact consumer open | The four § EE clauses for the kind/nvkind cluster over an injected `ClusterExec`, plus the loopback-bound exposure operation, exist. Its clause-1 front end probes and retains either the `flock(1)` or `lockf(1)` frontend and fails closed on an unrecognized report. Sprint 16.2 adopts that backend under the exact cluster prepared/settled package; Sprint 24.5 supplies the demo's matching concrete slice. [The recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) owns proof-complete recursive sequencing |
| `HostBootstrap.Step` / `Chain` / `Teardown` | Implemented exact forward/reverse projections and Production/Harness current-frame adoption | Opaque steps, disjoint typed identities, explicit reverse policy, operation keys/dependency prefixes, exact-order `StepPlan` validation, the per-frame descent declaration (`descendsVia`/`frameDescent`, validated one-per-frame), and declared reverse effects are implemented. Sprint 12.26's exact pure `teardownPlan` consumes `ProjectPlan` plus `CurrentFrame`, retains the admitted forward nodes' stable identities, operation keys, policies, and callbacks, omits preserved nodes, and projects the current-frame topology suffix deepest-frame-first and in reverse forward order within each frame. Construction runs no callback. Public `HostBootstrap.Chain.runChainFromFrame` consumes the exact `ProjectPlan` plus matching execute-phase `CommandAuthority` and `LifecycleCursor`, selects the current-frame nodes from `forward`, and derives descent from `DerivedTopology`. Before any I/O or durable transition it checks the authority against the supplied protected store and verifies the cursor's retained store plus decoded acquisition project/store/broker origin against that authority, then compares retained frame/verb/phase terms. Every protected entry then revalidates the exact acquisition source and current cursor row under the same exclusive entry before its dependent journal/session/prepare/settle/close action, so an execute cursor advanced to teardown cannot be reused stale. Its operation session uses the authority's broker epoch and invocation identity, so it opens neither a second broker nor a second command identity. Each planned node enters total `stepExecutionFor`; no raw membership branch remains on the public route. A step's forward action is `StepAction` — `forall scope planId. StepExecution scope planId -> IO StepObservation` — so the interpreter hands each action the descriptor minted for its own node instead of a bare `HostConfig`. A step also declares the operations it **projects** with `projectsOperation`; `mkStepPlan` admits the shape `<zero or more of the step's dependency keys, in plan order>/<its own key>/<suffix>`, claimed once per plan, so the declaring node is the last resource the relation names and no sibling can reach it. The interpreter registers, gates, and settles each projection with its node, and terminal observations settle their attempted session before returning. Production `Command` retains or reconstructs one exact plan for rendering, persistence, journal/cursor admission, authorization, Chain, and current-frame teardown; Harness `Command` retains one exact generative-run plan through the same current-frame Chain and reverse projection. No Production compatibility bridge remains. Nested lifecycle entry fails closed; authenticated forward child admission, exact recursive `down`/`destroy` authorization, and complete cross-frame traversal remain [the recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md)'s work |
| `HostBootstrap.Lifecycle.Execution` | Implemented exact plan-projected descriptor | The opaque execution descriptor a step's action receives carries host-tool configuration plus exact plan and configuration digests, stable node identity, operation key, frame, and ordered dependency/projection sets. The total `Reconcile.stepExecutionFor` jointly consumes one `ProjectPlan` and its matching `PlannedStep`, so plan/configuration mismatches are type errors and no raw step membership branch exists; public Chain calls that producer directly for Production and Harness. Its `scope`/`planId` roles are nominal, as are the runtime and `ResourceCarrier`. No Production compatibility descriptor producer exists; lower adapters that still consume `LifecyclePlan` do not create a second command route. The constructor is package-internal (`ForgeStepExecution.hs` pins that). Sealing the edge set into an `OperationPreconditionSet` is [the prepared-operations phase](phase-11-prepared-operations.md)'s traversal, and the descriptor reaches the prepare compare-and-swap through `Session.withStepPreparedGate`, which reads the plan digest and operation key off the descriptor so a step can gate exactly one node — its own. A step action returns a non-authorizing, plan-independent `StepObservation`; the public plan facade wraps it under the projected scope, plan, and configuration indices as opaque nominal `PlannedStepObservation scope planId configId`, and Chain classifies, reports, and acknowledges only that indexed value. The interpreter drives the full § EE transaction per node — durable unknown phase inside an exclusive entry, effect outside any entry, settle inside a fresh one — and the action reaches the gates that transaction opened: `stepExecutionPreparedGate` for the node's own operation and `stepExecutionTakeProjectedGate` (once per key) for each operation the plan validated as a projection of it. The descriptor also carries the interpretation's `ResourceCarrier scope planId`, through which `Reconcile.carryManagedResource` and `withCarriedManagedResource` move a dependency's `Managed` handle in process from the node that acquired it to the node that declared an edge to it. Minting a `Managed` handle through a gate is a resource adapter's act; [the host-providers phase](phase-15-host-providers-and-the-lift.md) supplies the guest-alias adapter and [the worked-demo phase](phase-24-worked-demo.md) owns its remaining demo adoption |
| `HostBootstrap.Teardown` | Implemented exact pure projection and current-frame Production/Harness consumers; recursive authority open | `teardownPlan` has the exact pure shape `ProjectPlan scope specDigest planId configId cfg -> CurrentFrame scope planId frame -> TeardownVerb verb -> TeardownPlan scope planId frame verb`. It projects only the current frame and its topology descendants, deepest frame first and reverse within each frame; the nodes retain the forward plan's stable `StepIdentity` and `OperationKey`, choose core provider/kind actions by `StepIdentity` rather than display text, preserve declared callbacks without running them, and omit every `PreserveOnReverse` node. `down` stops a provider frame and `destroy` deletes it, while both delete the kind cluster. `openTeardownForest` is the sole initial-forest producer and consumes only that projection, with no duplicate plan or frame argument. The forest is intentionally still `TeardownForest scope planId verb`: Sprint 17.3 propagates the projection's existing frame index through the forest, progress/authorization/cursor/completion values, and the closed local/foreign sum without deriving or accepting a second `CurrentFrame`. The existing forest returns a successor on every outcome, keeps a failed node's parent blocked while siblings drain, never completes while a failure stands, and permits only a completed `Destroy` forest to produce `DestroySettled`. Production and Harness `Command` retain the exact `ProjectPlan`/`CurrentFrame` pair and drive this projection directly. Harness combines `DestroySettled`, the exact bound lease, and the closed-session proof through `Lifecycle.Mode.destroySettledClosure` before close authorization. The pure projection is not teardown command authority; nested entry fails closed, and [the recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) still owns proof-complete operator/descent authorization, authenticated child admission consumption, and complete recursive traversal. Recovery beyond the live retained Harness plan remains [the recovery-and-migration phase](phase-18-recovery-and-migration.md)'s work |
| `HostBootstrap.Readiness` | Implemented [canonical-quantities-and-reconcile-results](phase-6-canonical-quantities-and-reconcile-results.md) foundation, partial live integration | Opaque validated polling and total results; closed backend probes require exact planned resources and mint generative plan/resource/dependency-indexed readiness. `planDependencyProbe` registers a probe for the traversal to run at prepare time rather than binding a retained observation. `ObservedReady` is explicitly non-authorizing compatibility evidence. [The host-providers phase](phase-15-host-providers-and-the-lift.md) implements closed raw provider discovery and exact prepared Incus/Direct readiness behind backend-indexed managed authority; its static gate is closed and its native Linux/x86_64 KVM/Incus gate remains open. [The cluster-lifecycle phase](phase-16-cluster-lifecycle-and-cordoning.md) supplies the cluster live adapter, while remaining recursive and demo call-site adoption belongs to [the recursive-lifecycle-command](phase-17-recursive-lifecycle-command.md) and [worked-demo](phase-24-worked-demo.md) phases |
| `HostBootstrap.Reconcile` | Implemented exact descriptor boundary over the phase-6 reconcile foundation | `ProjectPlan` is the sole whole-plan producer of opaque planned resources and exact edges. `Reconcile` consumes that public vocabulary and its projected nodes, supplies the one total plan-owned `stepExecutionFor` route, reconcile/adoption outcomes, prepared operation pairs, phase-indexed handles, and legal persisted journal transitions. The descriptor derives its plan/configuration/node/frame/operation identity and ordered dependency/projection views from the public plan facade; public Chain calls this total producer directly for Production and Harness. The lower `LifecyclePlan`/raw-`Step` consumers remain only for unmigrated adapters; neither Production nor Harness `Command` has a compatibility descriptor or interpreter route. Every identity and typestate parameter on opaque reconciliation evidence has a nominal role, including ownership, preparation, and phase-transition values, so `coerce` cannot relabel equal representations into authority. [The prepared-operations phase](phase-11-prepared-operations.md)'s dependency-snapshot traversal makes a descriptor's edge set the exact ordered resource-bearing prefix, and the sealed `OperationPreconditionSet` has one producer that runs each member's probe itself. `withPreparedOperation` takes a `Lifecycle.Prepared.PreparedGate` instead of caller-supplied journal versions and refuses one recorded under another plan digest or operation key. Raw backend observations remain plan-independent, while prepared/settled packages and managed results retain their plan indices. Sprint 12.30 owns only generic Budget admission; Sprints 16.2 and 16.4 own exact cluster and direct-Colima consumers; Sprint 24.5 owns the demo's concrete workload/slice projection; recursive adoption remains [the recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md)'s traversal work |
| `HostBootstrap.Protected` | Implemented | The protected, versioned record store every durable lifecycle decision compare-and-swaps against: portable OS-released exclusive entry (`hLock`), non-re-entrant sessions, atomic publish, expected-version writes/deletes, durable store identity, and a non-blocking `tryProtectedEntry`. `mkRecordName`/`recordNameIdentity` are the one injective encoding by which a **namespaced** identity — a plan operation key `core:deploy-kind`, a plan digest `<specDigest>:<planBytesDigest>` — reaches the key alphabet; its image (components with a `.`) and its plain domain (components without one) are disjoint, and a `/`-separated path of such identities — which is what a relation between operations is — encodes segment-wise joined by `..`, which no segment may contain. Two identities can therefore never share a record |
| `HostBootstrap.Authority` | Implemented producer-free safe facade and lower kernel | The safe facade owns closed `ProjectVerb`/`LifecyclePhase` vocabulary, executable-path-verified rank-2 installed identity, exact-store OS-principal evidence, and opaque broker/root/root-scope/command inspection, but no command-authority producer. The hidden kernel owns fresh project/store-bound monotonic broker epochs, closed exact-scope root minting, sealed stable reservation members, and canonical one-use invocation reservation. It has no raw recorded-generation or public standalone-root opener and no configuration/reconciliation dependency. Pure frame or cursor evidence alone grants no authority; exact plan-aware production lives in the specialized leaf rather than widening this lower facade |
| `HostBootstrap.Authority.ProjectPlan` | Implemented exact local root/child command gate and consumer | `authorizeProjectUp` is fixed to `RootInvocationAuthority scope brokerGeneration VerbUp` plus the term `ProjectUp`, and consumes the matching verified/bound snapshots, digest binding, bound lease, exact `ProjectPlan`, `AcquisitionJournal`, `ProjectFrame`, same-broker `LifecycleCursor ... VerbUp phase`, and `ValidatedContext`. `authorizeChildProject` instead consumes the fully indexed `ChildPlanAuthority` from `ProjectPlan.Construct` with its exact plan/journal/frame/cursor/context and rechecks signed project, protected-store, broker, specification, configuration, stable-plan, verb, phase, and child-frame coordinates. Both routes enter `Lifecycle.Session`'s narrow one-use reservation bridge and only full success yields matching `CommandAuthority`; neither grants signing authority. Production and Harness currently consume the root current-frame gate. The [recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) owns opening the child journal/cursor and consuming the child gate during recursive Production traversal |
| `HostBootstrap.Lifecycle.Mode` | Implemented mode/lease/profile and plan-bound lifecycle facade, partial recovery | The project-wide protected record is indexed by opaque `ProductionMode` or `HarnessMode runId`; Harness acquisition mints opaque nominal `RunId runId` inside a rank-2 continuation. `ProjectModeLease projectId mode brokerGeneration` narrows only through the two scope-specific `ActiveProjectMode` producers. A scope-indexed `VerifiedPlanSnapshot` can enter the fresh-only `bindRunLease`, and an already-bound record returns `LeaseConflict`. Existing Production admission instead enters through the public `ProjectPlan.Snapshot.withBoundPlanSnapshot` facade: one protected-record-read-only entry validates the existing authority binding, exact broker/mode/lease epoch, canonical snapshot, and invocation state; its terminal callback receives only the close key, while only Open yields the fully indexed `BoundInvocationRecovery scope specDigest planDigest planId brokerGeneration`. The pure `withRecoveredProductionLifecycleProfile` refinement consumes that exact seven-value Open package without another store entry, slot, or `planId`, revalidates all retained runtime origins/identities/bytes and existing-binding provenance, and yields the opaque five-index recovered profile with its classified Open revision. The Production and Harness fresh `LifecycleProfile` openers consume matching root, active-mode, and still-unbound lease evidence through protected one-use slots, with Harness additionally requiring the exact authority and run witness; the opaque profile retains that lease's installed-project name, protected-store identity, and broker epoch for downstream exact-origin checks. Composite root brackets, closure evidence, mode release, and the abandoned-run sweep are implemented. Ordinary Harness terminal authorization requires the exact bound lease, closed-session proof, and `ProjectClosureEvidence (Harness projectId runId)` produced from settled destroy; `authorizeHarnessClose` rejects pre-effect evidence, persists Closing, and only its resulting authorization may finalize the lease/mode close. The independently verified no-effect path remains the separate short close for a true pre-effect refusal. The sweep takes separate unbound and bound fold callbacks, so an unbound run's owned state is reclaimed before its lease closes. `classifyAbandonedBoundRun` gives the bound Harness half its own `HarnessBoundRecovery` through a package-private durable observation — reachable only from a `VerifiedIncompleteRunLease` the sweep minted, and only for its `IncompleteBound` kind — so a bound abandoned Harness run is classified and resolved rather than only named. A persisted `Closing` epoch is now resumed rather than refused: `resumeHarnessClose` is the only route to a close authorization that does not persist a new epoch, it admits exactly the epoch the dead run recorded, and it needs no fresh all-sessions-closed proof because the close it resumes already consumed one. The reopening now also yields the fresh authority broker, the old-permit fence set, the verified session/operation manifest, the recorded-session interpretation, and the `CurrentBrokerSessionAdmission` only all three together can mint. The **plan-migration** algebra sits here too: `withProjectUpMigrationProfile` is the sole producer of a revision carry and admits only a `NormalActiveRecovery` binding; `withProspectiveMigrationPlan` persists and authoritatively reads back one candidate under a derived stable migration key and yields a non-authorizing `ProspectivePlanSnapshot`; `withPlanMigration` records the incomplete side of the barrier and then freezes the old lease, which is what stops old-revision preparation; `commitMigrationActivation` switches the lineage and records the completed side, converging rather than refusing when re-run against the same frozen capability; `activateMigratedPlan` settles the old revision's sessions before admitting the new revision's broker; and `withCompletedMigrationRecovery` is the configless post-CAS path that recovers the superseded revision from the durable key rather than from any config. `withAcquisitionJournal` is the sole public plan-bound journal opener, and Sprint 12.23 makes this module the public cursor facade as well: it reexports opaque `LifecycleCursor`, inspection, expected/current-phase openers, and the only two successor eliminators, while Session owns the protected records. The journal retains the live mode/lease/snapshot validator established by its exact opener, and Sprint 12.25's pure lease-to-journal check covers the complete private project/store/key/version/run/digest/epoch origin before authorization can use it. All callbacks run after the protected entry closes. The configful forward rebuild (`withCompletedMigrationPlan`, and a candidate built from real drafts) and the complete resource-record rehydration remain [the recovery-and-migration phase](phase-18-recovery-and-migration.md)'s work |
| `HostBootstrap.Harness.Ownership` | Implemented | The run-ownership bracket performs the abandoned-run sweep, protected Harness mode/lease acquisition, data-root acquisition/release through `Harness.DataRoot`, and generated-config acquisition/release through `Harness.GeneratedConfig`. Ownership is represented only by protected lease/origin/identity records; no pathname lock-directory protocol participates. Its package-private monotone close controller moves through unbound, binding sentinel, bound fallback, authorized pending, settled, and consumed states; the public module exposes only the opaque indexed handle, never raw close mutators or caller-supplied finalizer actions. The unbound `verifyNoProjectResourcesAcquired` proof refuses both same-run effect and acquisition rows because either is impossible ownership before binding. A bound true-pre-effect refusal may use `verifyBoundRunHasNoProjectResourcesAcquired` and the retained fallback; ordinary lifecycle completion must instead supply exact settled-destroy closure evidence before close authorization becomes pending and ownership may settle it. Persisted Closing recovery resumes its recorded authorization, while incomplete binding, effects without settled destroy, and unresolved migration revisions stay fail-closed |
| `HostBootstrap.Harness.DataRoot` | Implemented | All four § EE ownership clauses for the run's durable data root, and the first § EE backend wired into a production route: exclusive entry is the caller's `ProtectedSession`, the origin record names the exact prior identity-or-absence before the directory is created, ownership binds the created directory's stable kernel identity, and release/recovery re-observe that identity — refusing a replacement instead of deleting it. A host without a stable identity is `Unsupported` and mints no ownership |
| `HostBootstrap.Harness.GeneratedConfig` | Implemented | The same four § EE clauses over the run's generated sibling `<project>.dhall`, and the second § EE backend wired into a production route: exclusive entry is the caller's `ProtectedSession`, the origin record names the recorded absence **and the intended payload digest** before the file exists, the file is published create-if-absent, ownership binds its created kernel identity, and release/recovery unlink only on an exact re-observed identity **and** payload. A found object is refused before any mutation rather than adopted, and a host without a stable identity is `Unsupported` |
| `HostBootstrap.Harness.Identity` | Implemented | The shared clause-3 identity layer both harness ownership protocols bind to, so the directory and file realizations cannot drift: a private-constructor `ObjectIdentity`, its hex journal codec, the injected `ObjectIdentityBackend` seam, and the closed `IdentityFault` each protocol maps into its own vocabulary |
| `HostBootstrap.Harness.Identity.Native` | Implemented; native Windows gate passed 2026-08-01 as `Harness.DataRoot.Native` | The host identity backend behind that seam: POSIX `lstat` `(device, inode)`, and on Windows `GetFileInformationByHandle` over a handle opened with `FILE_FLAG_BACKUP_SEMANTICS` and locally defined `FILE_FLAG_OPEN_REPARSE_POINT`. Volume word first, little-endian, as the peer ownership backends encode it. `DataRootSpec` and `GeneratedConfigSpec` both run this backend directly |
| `HostBootstrap.Handoff` | Implemented transport proof | The authenticated cross-frame transport owns length-delimited framing, the generative inverse parser for length-prefixed `HandoffBinding`, the root-only Ed25519 `RootBroker` with its keyless `BrokerRelay`, fresh-challenge grants, and transport-only `VerifiedHandoff scope brokerGeneration`. `withRootBroker` narrows a separately provisioned long-lived project signing key—distinct from Build and Activation—to one verified root invocation and holds one live-state lock through every durable/signing operation; retained brokers refuse after the bracket closes. Handoff grants use the framed `hostbootstrap/handoff-grant` domain plus protocol version 1, while recovery-wire signatures use the same project trust root under the distinct `hostbootstrap/recovery-wire/v1` domain. The signed binding includes installed project, specification, payload kind, scope, protected-store identity, stable plan revision, broker generation, parent/child frames, child-config digest, verb, closed phase, and token commitment. It does **not** own or mint `ChildPlanAuthority`. `registerHandoffEdge` is the root's sole opener and writes the edge durably before a grant can be asked for, so `grantHandoff` answers only for an edge the root opened (`HandoffEdgeUnregistered` otherwise) and relaying is strictly weaker than signing. Consumption is a compare-and-swap at the observed version: an identical retry returns the same deterministic signature, any other challenge is a reuse refusal |
| `HostBootstrap.Handoff.Receiver` | Implemented, live call site open | The child half of the exchange over a duplex `HandoffChannel` (`stdin` inbound, `stdout` outbound — the only descriptors a container or VM boundary carries, so a receiving binary's diagnostics belong on `stderr`). `withReceivedHandoffEdge` takes opaque installed `HandoffScope scope`, mints a fresh challenge after the offer arrives, parses without accepting caller-chosen wire phantoms, verifies against the independently installed key, admits the exact bytes, and sends every refusal rather than closing the pipe. Its continuation retains the installed scope and quantifies only the authenticated broker generation. Public `ReceivedEdge` exposes verified views only; its constructor, raw channel, and request identity are package-private in hidden `Handoff.Receiver.Internal`, so those endpoints cannot be recovered through the public received-edge value. That seal does not revoke a caller's lexically retained `HandoffChannel`; the Relay row states the resulting § HH/raw-channel limit. Message order is enforced by `ChildProtocolState`. Adopting it at the recursive descent, in place of `Lift.ConfigDelivery`'s shell writer, belongs to [the recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) |
| `HostBootstrap.Handoff.Relay` | Implemented protocol; live call site open | The parent half and duplex relay. `BrokerLink` routes root-owned edge open/grant, Activation signing, and recovery-wire signing. `rootBrokerLink` derives its verification route from the live handoff broker and carries the distinct Activation broker plus closed edge/recovery admissions; `relayedBrokerLink` is derived only from an authenticated `ReceivedEdge` and contains no broker or signing key, so an intermediate frame remains structurally unable to sign (pinned by `RelaySignsWithoutBroker.hs`). Every ordinary `BrokerLink` request carries a private, repository-sealed requester path: each cooperating parent validates the exact admitted child and immediate-parent relationship, prepends its verified current frame, and refuses sibling/ancestor splices before broker admission. This is the § HH guarantee for code using the sealed API, not end-to-end cryptographic attestation against an external actor or code deliberately retaining and writing the raw channel; exact root edge/recovery admissions remain the final authorization. Ordinary config admission plus Activation and store/generation/verb-bound recovery cross a genuine multi-process, multi-hop chain; request zero is refused before peer-visible or durable effects. The recursive-lifecycle-command phase owns the Production call site |
| `HostBootstrap.Activation` | Implemented protocol; deployment consumer open | Runtime role activation uses its own independently provisioned long-lived Activation signing/verification identity and the `hostbootstrap/activation/v1` signature domain. A runtime-closed `ActivationBroker` signs only the exact canonical manifests in its closed policy; an escaped broker refuses. `ActivationManifest` binds the immutable rollout revision and every pre-instantiation index but deliberately no instance identity. Its dedicated private-bundle coordinate is an opaque canonical SHA-256 digest computed from bytes. Startup supplies its own `RuntimeMeasurement` (binary, mounted wire, private bundle, non-empty pod UID plus restart count or non-empty host invocation nonce), and verification against an independently selected exact manifest and protected-store origin yields the inseparable `VerifiedRuntimeRoleActivation`. Activation itself confers no lifecycle authority. [The composition-and-network-algebra phase](phase-21-composition-and-network-algebra.md) owns the sole one-use admission and consuming role lifecycle, and [the service-runtime phase](phase-22-service-runtime.md) owns the production service gate |
| `HostBootstrap.Build` | Implemented protocol; consumer open | The attesting image-build gate uses a distinct independently provisioned long-lived Build signing/verification identity. A runtime-closed coordinator signs the canonical `BuildBinding` under `hostbootstrap/build/v1`; an escaped coordinator refuses. The grant binds source-root and builder-path measurements and arrives through a coordinator channel whose absence is an explicit refusal, not a fallback. Verification measures the caller-supplied paths and jointly yields `ImageBuildFrame` and `BuildInvocationAuthority`, from which only per-returned-authority, at-most-once `CheckCodePhase`/`BuildPhase` authorities can be derived. It neither establishes that those paths are the engine context/running executable nor globally consumes a signed file across verifier calls. No function accepts a `BinaryContext`, so the baked image-build config reaches none of it. Current `HostBootstrap.Command.checkCodeCommand` does not consume this authority. Its static consumer seam, trusted path derivation, single presentation/acknowledgement or durable `buildId` replay refusal, delivery through the demo Docker build, and live container evidence belong to [the worked-demo phase](phase-24-worked-demo.md); ordinary developer `check-code` remains distinct |
| `HostBootstrap.Lifecycle.Prepared` | Implemented | The shared lower module that owns the durable half of a prepare ([the prepared-operations phase](phase-11-prepared-operations.md), 2026-07-30). `PreparedGate` hides its constructor and its sole producer, `recordDurableUnknown`, performs the compare-and-swap that publishes an operation's unknown phase, so the plan, operation, fence, attempt, and journal version an adapter is prepared against are the store's rather than a caller's literals. It sits below both `Lifecycle.Session` and `Reconcile`, which the `Session -> Authority -> Reconcile` dependency would otherwise keep from naming each other |
| `HostBootstrap.Lifecycle.Session` | Implemented foundation, acquisition/cursor records, and atomic command-reservation bridge | The protected operation session, durable idempotent fence rotation, total recovery discriminator, and prepare compare-and-swap are implemented and mint the `Lifecycle.Prepared` gate `Reconcile.withPreparedOperation` requires. `withStepPreparedGate` is the route exact public Chain descriptors and remaining lower `LifecyclePlan` consumers take to that gate; it refuses another plan digest, and thrown safety refusals settle terminally while other exceptions leave an explicit unknown state. The abandoned-run admission chain idempotently fences old permits, verifies independently complete session/operation manifests including zero-operation Open sessions, interprets every recorded operation, closes/rebinds surviving sessions, and admits only a fully checked current broker. Sprint 12.21's opaque `AcquisitionJournal scope planId brokerGeneration` retains its exact canonical source row and opener-established live validator. Sprint 12.22's opaque six-index `LifecycleCursor scope planId frame brokerGeneration verb phase` and canonical bounded record make all roles nominal without granting backend-effect authority. Sprint 12.23 opens it only from that journal plus the matching `ProjectFrame` and owns recovery and transitions. The acquisition phase is only the absent-row seed. A canonical length-framed per-frame row becomes authoritative after its absent-to-present CAS, and every open/successor rechecks the exact source key, record version, and bytes. `withCurrentLifecycleCursor` existentially discovers the durable phase; the only edges are `Prepare -> Execute -> Teardown`, with no terminal or verb-changing successor. CAS reservation is at-most-once, while unlocked callback delivery is at-least-once and may repeat after recovery or an exception. Sprint 12.25's narrow bridge accepts a package-sealed `CommandReservation` and in one protected entry revalidates the live mode/lease/snapshot, exact acquisition source, and exact cursor key/version/bytes/binding/verb/phase before invoking the existing one-use reservation kernel; stale or drifted evidence writes no invocation row. `lifecycleCursorMatchesCommandAuthority` additionally compares the cursor's retained protected store and decoded acquisition project/store/broker origin with the command authority; exact Chain calls it before I/O, so hostile package substitution fails before any journal transition. `validateCurrentLifecycleCursor` rechecks the exact acquisition source and current durable cursor row inside an already-open protected entry; Chain runs it before every dependent journal/session/prepare/settle/close action, so a stale execute cursor cannot race an advance to teardown. `Lifecycle.Mode` owns the public cursor facade; Session owns key derivation, strict codecs, collision refusal, readback, and protected CAS. The lower public journal/session/prepare primitives are non-authorizing and do not establish plan-bound admission; proof-complete callers pass through the plan-bound opener |
| `HostBootstrap.Context` | Implemented descriptive/frame foundation and exact-plan consumers | Descriptive binary context/capability checks, the total topology-graph validator, and the closed `ContextPlacement`/`requiredWitnesses` relation are implemented by [the Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md). [The host-tools-and-substrate-detection phase](phase-3-host-tools-and-substrate-detection.md) resolves `sourceRoot` separately without rewriting context. Phase 12.14 implements pure plan-bound admission that jointly yields opaque `CurrentFrame`, `ProjectFrame`, and `ValidatedContext`; it grants no command or mutation authority by itself. Sprint 12.25's specialized `authorizeProjectUp` gate consumes the exact `ProjectFrame`/`ValidatedContext`, rechecks structural placement, and combines them with the independent bound-plan lifecycle package. Sprint 12.26's pure `teardownPlan` consumes the matching `CurrentFrame`, and public Chain consumes the exact execute-phase evidence for both Production and Harness. [The recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) still owns proof-complete recursive composition/traversal rather than this descriptive evidence |
| `HostBootstrap.ProjectRoot` | Implemented foundation and retained plan input | Private rank-2 canonical-root admission retains the surrounding config/lifecycle scope and mints only the fresh `rootId`; sibling admission therefore returns `CanonicalProjectRoot configScope rootId`. Same-root host durable projection and the typed direct-host mount adapter are implemented. `canonicalHostSubPath` derives a host path under the admitted root from supplied segments and rejects non-components. The opaque `ProjectPlan` retains the exact admitted root and owns resource projections; Production and Harness dispatch plus public Chain consume that exact plan and root |
| `HostBootstrap.Substrate.Provider` | Implemented boundary; native phase gate open | `SubstrateProvider` is an opaque descriptive value selected from the closed Incus/Lima/WSL2/Direct kind. Its closed request plans accept only raw exit/stream/transport outcomes, parse strict single-line reports privately, poll only bounded `NotReady`, and mint a generative backend-indexed capability only from the exact opaque managed Running provider. `Provider.Reconcile` exposes opaque nominal `ManagedProviderHandle` and `ManagedProviderShareHandle` authorities plus prepared provision/ready/share/stop/delete operations. The Incus backend holds one `flock` namespace, publishes and binds durable provider/share origins, and conditionally mutates only the exact UUID/nonce identity. Direct settles only a plan-local reservation and identity share; stop, delete, guest execution, and guest alias are structured refusals with no physical-host mutation. `Provider.Alias` consumes the exact managed provider/share authorities, settles only to an opaque nominal `ManagedGuestAliasHandle`, admits only retained guest `flock` (a discovered `lockf` remains descriptive `Unsupported`), and recovers durable `prepared`/`managed`/`releasing` records before identity-conditional release. The static gate is closed; the native Linux/x86_64 KVM/Incus gate remains open, and the demo's exact provider and prepared-alias call-site adoption remains [the worked-demo phase](phase-24-worked-demo.md) |
| `HostBootstrap.Lift.Context` | Implemented public pure boundary | [The Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md) owns the Incus/Lima/WSL2 target records, container/config-delivery data, outermost-first `LiftContext`, canonical incremental constructors, same-root `canonicalHostMount`, and exact inner transport argv renderers. The data constructors remain public for inspection and exact fixture construction. The module performs no tool resolution or effect and imports no later plan, provider-realization, Registry, or cluster module. Public exposure, `LiftContextSpec`, compile-fail mount cases, the lower-boundary source guard, and the complete phase gate are closed |
| `HostBootstrap.Lift` | Implemented generic dispatch boundary | [The ensure-reconcilers phase](phase-8-ensure-reconcilers.md) owns the provider-neutral resolved-tool fold/effect dispatch and reexports `Lift.Context`. It resolves only the outer host tool, streams config delivery, and owns no provider realization or Registry policy. Fold, effect-seam, adversarial shell-quoting, decorated/multiline-aware exact import-guard coverage, and the complete phase gate are closed. `reachLeaf` and the blob leaf smart constructors are later additive extensions owned by [the composition-and-network-algebra phase](phase-21-composition-and-network-algebra.md), not part of the generic fold contract |
| `HostBootstrap.Incus` / `Lima` / `Wsl2` | Implemented provider realization boundary; native phase gate open | [The host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md) owns lifecycle probes/builders that consume and reexport the lower target records and inner renderers. Incus has the baseline prepared, four-clause provider/share backend; Lima and WSL2 consume the same opaque provider descriptor, closed discovery, and lower rendering contracts while their native confirmation remains in their terminal substrate acceptance phases. The production WSL utility-VM wall enters through its separate journalled host-wall driver and releases on teardown. Reexport/import-direction guards, focused provider coverage, and the host-provider static gate are closed; the native Linux/x86_64 KVM/Incus gate and later demo call-site adoption stay open |
| `HostBootstrap.Wsl2.GlobalWall` | Implemented production authority and recovery driver | Exact present/absent origin, durable unknown phases, identity-bound stage/apply/restore classification, fencing, opaque receipt/authority values, and conflict-only recovery are consumed by the production `ApplyGlobalWslWall`/`ReleaseGlobalWslWall` route. The shared model/codec gate is portable, the full driver gate runs on POSIX, and a focused native Windows production-entrypoint gate passed 4/4 on 2026-08-01 |
| `HostBootstrap.Wsl2.GlobalWall.ConfigBytes` | Implemented, retained | Strict bounded UTF-8/UTF-16 transformation with idempotence fixtures. Portable and unaffected by the ownership restatement; carried forward unchanged |
| `HostBootstrap.Wsl2.GlobalWall.Windows` | Implemented production backend; focused native gate passed 2026-08-01 | Windows realization of the portable host-wall driver. Public `Win32` types/wrappers cover ordinary operations; a narrow direct `kernel32` FFI preserves exact status for ownership-critical handle and namespace calls. The package has no private `Win32` module, C shim/source, Cabal `c-sources` block, or threaded-RTS carve-out |
| `HostBootstrap.Harness` | Implemented typed assertion engine, ownership, and direct exact-plan interpretation | Opaque typed case/variant matrix, selection, reporting, and exclusive run ownership are implemented. `CaseResult` distinguishes the project's own `Fail` from the engine-classified `Refused`, `LifecycleFailed`, and `TeardownFailed`; `HarnessRunOwnership` supplies receipt-driven cleanup and Harness close. The five-field `TestSuite` contains only its safety precondition, per-variant assertion-environment opener, typed cases, case assertion, and post-reverse assertion—there is no project lifecycle callback or self-invocation route. For each selected variant, `Command` retains one exact `ProjectPlan (Harness projectId runId) ...` through generated-config ownership and supplies the engine an opaque `HarnessLifecycle` backed by the shared Chain forward and exact reverse. Its constructor lives in a private Cabal component; the public facade exposes only the opaque value and eliminators, so downstream suites cannot forge another lifecycle interpreter. True pre-effect refusal skips reverse only after the bound no-resource proof; acquired failures reverse, and ordinary terminal close requires settled-destroy closure evidence. [The recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) still owns proof-complete recursive traversal and a same-run restart transition; the demo durable destroy/up/readback assertion remains honestly open in [the worked-demo phase](phase-24-worked-demo.md), and [the test-harness-and-run-ownership phase](phase-19-test-harness-and-run-ownership.md) owns remaining interruption/live acceptance |
| `HostBootstrap.Service` | Implemented typed codec/request boundary, partial runtime | Closed typed registry definitions bind identity/projection/role codec/handler; finalization shares one digest with the full codec, service dispatch verifies one snapshot, and a handler's whole input is `ServiceHandler fields` = `RoleParams specDigest configId secretDigest fields service -> IO ()` — its own role's opaque bundle, with no framework view, so a role that needs a framework datum declares it as a field its own projection supplies. Replacing the handler's raw `IO` with one-use effect-indexed execution remains [the service-runtime phase](phase-22-service-runtime.md)'s work; [the composition-and-network-algebra phase](phase-21-composition-and-network-algebra.md) supplies the phase lifecycle. Native accelerator real-run evidence belongs to the corresponding substrate acceptance phases |
| `HostBootstrap.RoleLifecycle` | Implemented engine, call site open | The phase-indexed role lifecycle ([the composition-and-network-algebra phase](phase-21-composition-and-network-algebra.md), 2026-07-30). It also carries the declared effect row: `RoleEffect` promotes, `EffectName` is its per-effect tag, `DeclaredEffects effects` is a type-level row whose term-level twin agrees by construction, and `HasEffect` has no empty-row equation so an undeclared effect is an unsolved constraint rather than a runtime refusal. `authorizeServiceEffects` is the sole producer of `EffectAuthorization … effects`, admitting a declared row only within the signed `permittedEffects` ceiling and recomputing the lease requirement from the declaration. The public `RoleSpec`/`runRole` callback bag is absent. A role passes `verifyRolePlanDraft` (no durable mutation) → `withRoleLifecycleAdmission` (the sole one-use reservation, using a bounded legal `role-admission.<sha256>` key over domain-separated, length-framed exact plan/frame/revision/measured-instance coordinates) → `withRuntimeRolePlan` (CAS-consumes that reservation, mints `RolePlan`/`RolePlanDigestBinding`/`VerifiedServicePlacement` and the sole `Prereq` cursor), after which the core-owned engine privately drives Prereq → Acquire → Ready → Serve → Drain → Exit and returns only `RoleExitReport`. Admission, plan opening, and engine entry each refuse a protected store different from the activation's privately retained origin before their respective durable, liveness, or engine effects. The current API prevents duplicate use but does not rehydrate an existing reservation or consumed plan after asynchronous/callback acknowledgement loss; Phase 21 owns that recovery protocol. The lease requirement is derived from the signed effect ceiling, and the exclusive branch holds a kernel lock across Acquire→Drain. Production `service run` entry requires the proof-complete root and recursive command path owned by [the recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md); [the service-runtime phase](phase-22-service-runtime.md) owns the effect-indexed selected-service package and call-site adoption |
| `HostBootstrap.Service.Program` | Implemented program/interpreter, registry adoption open | The closed effect-indexed `ServiceProgram payload service effects a` a handler returns. Constructors are private and there is no `IO`/`MonadIO` constructor, so a project builds one only through the smart constructors and the `Monad` instance and cannot write a second interpreter; `interpretServiceProgram` is the sole eliminator and demands the `EffectAuthorization`. Payload types sit under one `payload` index with associated types, so a program and its backend agree by one type equality. Every listener/peer/worker argument is an `AcquiredResource service` the Ready phase alone produces. `DurableStore` is core-executed against a `DurablePath` minted only through `canonicalHostSubPath`; the other three families reach an injected `ServiceBackend`, the `ClusterExec`/`GuestExec` boundary. There is no unauthorized-effect failure: the indexed row and the authorized row agree by construction. `serviceDefinition` carries its declared effect row through selection, but handlers still return raw `IO` and no call site builds a backend; [the service-runtime phase](phase-22-service-runtime.md) owns that adoption |
| `HostBootstrap.Config.*` | Implemented config/role and handoff-refinement boundary; live adoption open | Generic scope-indexed config classes, opaque secret refs, canonical verification, common framework view, full-vs-role/scope discriminators, `RoleCodec`, request, and role parameters are implemented. `Config.Schema.withVerifiedConfigHandoff` consumes transport-only `VerifiedHandoff`, exact `VerifiedConfigWire`, matching `ValidatedConfig`, and a closed `ProjectVerb`; only after checking payload kind, wire/config digest, specification, verb, and closed phase does its rank-2 continuation receive fully indexed `VerifiedConfigHandoff scope planDigest brokerGeneration parentFrame childFrame configId verb phase`. `ValidatedConfig` remains abstract in the public schema facade; its hidden representation provides the sole recovery reindex. [The Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md) supplies the package-internal `Config.Install.Native` atomic no-replace hard-link primitive (`link(2)` / `CreateHardLinkW`) used by sibling config installation. [The authenticated-handoff phase](phase-13-authenticated-handoff-and-child-admission.md) owns the cross-frame refinement and child-plan authority substrate; [the recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) owns its live Production descent and child journal/acquisition adoption |
| `HostBootstrap.Dhall.*` | Implemented foundation | Opaque `CodecWitness` owns schema/decode/render, opaque artifacts require an admitted codec, literal schema commands are snapshotted, every current `Core.dhall` type export is equality-owned, and [the Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md)'s `ProjectCodec` supplies installed identity/scope/spec-digest binding |
| `HostBootstrap.Registry` | Implemented additive Lift ownership; stronger credential capability open | Docker Hub credential discovery/forwarding exists, but it still exposes raw text, classifies registry keys by substring, and uses environment transport. Registry owns `liftSubcommandWithAuth`, depends on the lower generic Lift and its quoting helper, and is protected by a source guard proving Lift imports no Registry policy. [The recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) owns the scope/registry/credential-indexed capability and broker-owned transport across authenticated child handoff; [the worked-demo phase](phase-24-worked-demo.md) owns demo adoption and live confirmation. Schema/artifact registration lives in `HostBootstrap.Dhall.Gen` |
| `HostBootstrap.Network` / `HostBootstrap.RegistryPlan` | Implemented generic algebra and additive Lift helpers; blob tests and phase gate open | [The composition-and-network-algebra phase](phase-21-composition-and-network-algebra.md) supplies scope-indexed endpoints/clients/exposures, proof-gated blob delivery, opaque finalized registry plans, route-specific readiness, and the later `reachLeaf`/blob leaf helpers over generic Lift. `reachLeaf` coverage and the Registry-to-Lift direction guard are implemented; exact argument-shape coverage for the four blob leaves and the fresh phase gate remain open. [The worked-demo phase](phase-24-worked-demo.md) consumes the algebra in the demo |
| `HostBootstrap.DocValidator` | Implemented | Mechanical documentation checks; new drift floors belong to [the documentation-reconciliation phase](phase-28-documentation-reconciliation.md) |

Ownership across this inventory is deliberately split at the consumer boundary. Phase 12 owns the exact
`ProjectPlan`/current-frame/Chain and Production `Command` current-frame foundation; Phase 17 owns
authenticated recursive child entry/traversal. Phase 19 owns the Harness
`Command` consumer and assertion engine; its direct interpretation of the common plan is not Phase 12
call-site work.

Phase 12's snapshot/recovery boundary is intentionally split from the current mode primitives. Through
Sprint 12.20, version-3 root-bound public stable bytes, pure `PlanDigestBinding` verification, non-authorizing
`BoundPlanSnapshot` evidence, origin-checked fresh persistence/binding, and fully indexed existing
Production admission, pure recovered-profile refinement, and exact recovered-plan reconstruction are
implemented. Reconstruction safely joins an independently finalized config/draft candidate before reproducing
the protected bytes over the existing
`BoundInvocationRecovery scope specDigest planDigest planId brokerGeneration`. Fresh persistence stores,
flushes, reads back, and verifies the private indexed snapshot before a separate lease-record
compare-and-swap. Those are ordered durable transitions, not an atomic multi-record transaction; the
intermediate persisted-snapshot/unbound-lease stage is classified. Existing-snapshot admission generates
the sole local `planId`, which recovery classification, the recovered profile, and reconstruction retain
without another quantifier or mint.

## Lifecycle Type Contract

The current Phase 12 construction/projection path through Sprint 12.26 is:

```text
ProjectSpec cfg tcfg
  -> FinalizedProjectSpec scope specDigest cfg
  -> NonEmpty (PlanDraft scope specDigest (cfg scope))
  -> ProjectPlan scope specDigest planId configId cfg
  -> forward / topology / CurrentFrame package
       / plan-owned resources and dependency edges
  -> StablePlanSnapshot
  -> VerifiedPlanSnapshot / BoundPlanSnapshot / PlanDigestBinding
  -> BoundRunLease / NormalActiveRecovery

ProjectPlan scope specDigest planId configId cfg
  + CurrentFrame scope planId frame
  + TeardownVerb verb
  -> TeardownPlan scope planId frame verb
  -> openTeardownForest
  -> TeardownForest scope planId verb
       (forest frame propagation remains Sprint 17.3)

ProtectedStore + InstalledProjectIdentity
  -> terminal InvocationCloseKey
   | Open root / Production mode / existing BoundRunLease
          / VerifiedPlanSnapshot / BoundPlanSnapshot / PlanDigestBinding
          / BoundInvocationRecovery scope specDigest planDigest planId brokerGeneration
          -> RecoveredProductionLifecycleProfile
               projectId specDigest planDigest planId brokerGeneration
          -> independently finalized matching config + regenerated drafts
          -> ProjectPlan
               (Production projectId) specDigest planId configId cfg
          -> AcquisitionJournal scope planId brokerGeneration
          -> ProjectFrame scope specDigest planId configId frame
          -> LifecycleCursor scope planId frame brokerGeneration verb phase
          -> authorizeProjectUp
          -> CommandAuthority scope planId frame brokerGeneration VerbUp phase
```

The static `ProjectSpec` carries no runtime identity. The finalizer supplies scope/specification, and
fresh plan admission supplies `planId`; callers cannot choose either. Reconciliation's exact descriptor
producer consumes the admitted plan and one matching projected node. Public Chain consumes that exact
plan's `forward`/`DerivedTopology` projections plus matching execute-phase command authority and cursor,
checks the supplied store and the cursor's retained store plus decoded acquisition project/store/broker
origin before I/O, and uses the authority's broker epoch and invocation identity. Production `Command`
retains or reconstructs one exact plan through rendering, snapshot persistence/binding, journal/cursor
admission, `authorizeProjectUp`, public Chain interpretation, and current-frame teardown. The Production
compatibility authority, forward-interpreter, descriptor, and teardown-plan APIs are absent. Harness
constructs its exact generative-run plan after variant selection and retains it through generated-config
ownership, journal/cursor admission, public Chain interpretation, and the matching reverse projection.
Plan-owned resources and edges, the broker-indexed acquisition journal, same-broker
per-frame cursor, exact current-frame `project up` authority, exact plan-projected descriptor, and exact
pure frame-indexed reverse projection are implemented. The recovered profile and exact fixed-identity
reconstruction are also implemented.

Sprint 12.21 splits journal ownership without creating another public admission route.
`HostBootstrap.Lifecycle.Mode.withAcquisitionJournal` owns retained evidence checks, rereads the live
mode, exact lease version/state/bytes, and canonical snapshot in the lease's one protected-store entry,
then invokes the callback after that entry closes. `HostBootstrap.Lifecycle.Session` owns the separate
`acquisition.<project>.<run>.<brokerEpoch>` record and its strict binding/phase codec. That record is
neither the Phase-10 `project.<planDigest>` Open/Closing transaction nor a resource-operation attempt
record.

Sprints 12.22–12.23 keep one facade split: 12.22 owns the opaque value and canonical record, while 12.23
owns admission, recovery, and transitions. `HostBootstrap.Lifecycle.Mode` publicly reexports the cursor
and its expected-phase, current-phase, and successor eliminators. `HostBootstrap.Lifecycle.Session` owns
the `cursor.<sha256>` key derived from canonical length-framed acquisition-key/frame bytes and the strict
canonical payload binding the exact source key/version/bytes, frame, immutable verb, and current phase.
The acquisition phase seeds a frame only until its cursor row exists; thereafter that row is
authoritative. Distinct frames therefore advance independently. Exact retries and concurrent readers may
redeliver the current cursor, but only one CAS can reserve each successor.

Sprints 12.24–12.25 add the plan-owned resource/edge projections and exact local command gate.
`HostBootstrap.Authority.ProjectPlan.authorizeProjectUp` checks the complete retained bound-plan package,
typed frame/cursor/context, and the lease's private protected origin before the narrow Session bridge enters
one protected transaction for live mode/lease/snapshot/source/cursor revalidation plus one-use reservation.
The lower `HostBootstrap.Authority` facade remains producer-free.

The target lifecycle algebra is shared, not reimplemented by provider/demo code:

```text
opaque resource identity
  -> total ProbeResult
  -> generative Ready lifecycle-scope plan resource-instance dependency
  -> plan-internal complete-edge traversal + fresh OperationDependencySnapshot
  -> plan-owned closed OperationPreconditionSet (exact zero/one/many edges + probes + call digest)
  -> protected prepare revalidation
  -> matching PreparedOperation + PreparedPreconditions
  -> lifecycle-scope-, plan-, ownership-, and phase-indexed conditional backend transition
  -> Either ReconcileError
       (ReconcileResult scope planId id resource Observed targetPhase)

ReconcileResult
  = ManagedResult
      (opaque ManagedTransition binding, as one value:
         ResourceHandle ... Managed targetPhase
         + OwnershipReceipt ... id resource
         + ManagedOutcome ... Observed targetPhase)
  | ForeignResult
      (ResourceHandle ... Unmanaged targetPhase)
      (Observation ... id resource)

ReconcileError
  = Conflict ConflictReason
  | SafetyRefusal RefusalReason
  | Unsupported UnsupportedReason
  | Failure FailureContext RecoveryDisposition
```

A managed unchanged result preserves teardown authority. A foreign result grants an `Unmanaged` handle
that cannot be passed to mutation or teardown; explicit adoption requires matching opaque authority and
returns a managed handle plus receipt. Recursive teardown consumes only receipts acquired by that run.
The generative `planId` also prevents two Production plans from exchanging handles, journals, or
receipts. `Down` and `Destroy` have distinct teardown-plan types; the durable root remains in the plan
under `Preserve`.
Retained `Ready` values never enter a backend adapter. Prepare reruns the plan-owned probes and
identity/version checks; only the jointly returned prepared pair can call the effect, and a backend that
cannot condition the call on that prepared version is `Unsupported`.
Ordinary project teardown preserves it in both scopes. A Harness run that acquired resources must finish
exact destroy and combine its `DestroySettled`, closed-session proof, and exact bound lease into
`ProjectClosureEvidence (Harness projectId runId)` before close authorization; only a separately verified
true pre-effect refusal may use the no-resource short close. Generated config and `.test_data/<runId>` remain
owned until that close state is settled or safely recovered.

The target execution profile is opaque:

```text
LifecycleProfile (Production projectId)
LifecycleProfile (Harness projectId runId)
RecoveredProductionLifecycleProfile projectId specDigest planDigest planId brokerGeneration
```

Existing-snapshot admission generates the one local `planId` carried by that recovered profile; recovery
opening and reconstruction retain it and do not quantify a second identity. The local command substrate
is broker-indexed end to end; its acquisition journal, frame-local lifecycle cursor, and exact `project up`
command authority are implemented:

```text
AcquisitionJournal scope planId brokerGeneration
LifecycleCursor scope planId frame brokerGeneration verb phase
CommandAuthority scope planId frame brokerGeneration verb phase
```

[The installed-identity-and-authority-kernels phase](phase-5-operator-root-and-command-authority.md) supplies
only the lower exact-root and one-use reservation kernels. [The lifecycle-modes-and-run-leases
phase](phase-9-lifecycle-modes-and-run-leases.md) owns fresh Production/Harness profile opening from the exact
root, mode, and still-unbound lease, while [the step-algebra-and-project-plan
phase](phase-12-step-algebra-and-project-plan.md) and [the recovery-and-migration
phase](phase-18-recovery-and-migration.md) own the exact bound-plan and recovered-profile paths. Exclusive
harness ownership can consume only its run-indexed fresh profile; Harness/teardown recovery cannot inhabit the
Production recovery type. Phase 12 owns the exact local bound-plan/current-frame substrate; Phase 17 alone
composes proof-complete recursive operator/descent authorization and traversal. The exact local
verb/frame/phase authority derives from the lower kernels, validated plan/context, bound lease, acquisition
journal, and same-broker cursor.
The current demo `containerPlan` still derives cluster name, data root, ports, and ownership identity from an
independently passed `ClusterProfile`; Sprint 24.4 replaces that consumer boundary with one projection from the
retained exact plan. The five-field `TestSuite` is assertion-only; the Harness command retains and interprets
the exact Harness `ProjectPlan` instead of exposing a lifecycle callback or re-entering Production. Its opaque
lifecycle capability is constructed only across the private component boundary, while exact settled-destroy
closure evidence gates the ordinary terminal close.
Successful Production `ProjectUp`/`ProjectDown` closes only its terminally acknowledged
`BoundRunLease`/broker invocation; Production mode, active snapshot/revision, Open-project state, and
resource records remain. Destroy/true-pre-effect project closure is the separate mode-release path.

## Ensure Reconcilers

| Reconciler family | Host applicability | Notes |
|-------------------|--------------------|-------|
| Docker | supported host substrates | Post-binary dependency |
| Homebrew / GHC | Apple Silicon | Core reconcilers are Apple-only; Linux/guest toolchain bootstrap follows the separate bootstrap/lift path |
| Lima | Apple Silicon | Config-free provider prerequisite reconciler; direct Colima is a separate exact plan-bound wall owned by Sprint 16.4 |
| Incus | Apple/Linux | Apple Incus is explicit-provider support; demo default uses Lima |
| WSL2 | Windows | Provider install/readiness and the consolidated provisioning route come from [the host-providers phase](phase-15-host-providers-and-the-lift.md); native confirmation belongs to [the Windows/WSL2 acceptance phase](phase-27-windows-and-wsl2-substrate.md) |
| CUDA | Linux GPU | Requires detected NVIDIA device/driver visibility |
| CUDA Windows | Windows GPU | Host-native build stack |
| Apple Metal | Apple Silicon | Host-native accelerator build stack |

Reconcilers adopt [the canonical-quantities-and-reconcile-results phase](phase-6-canonical-quantities-and-reconcile-results.md)'s `ReconcileResult` contract. A mere executable-present Boolean is not
the final reconciler state model.

## Project Configuration

Each built project binary owns a sibling `<project>.dhall`. The current config type is project-defined
through identity-parametric `ProjectSpec cfg tcfg`, where `cfg` is scope-indexed; core does not own
universal project defaults. The static value has no runtime scope/specification/plan phantom; scope
finalization produces exactly `FinalizedProjectSpec scope specDigest cfg`. One restricted assembler quantifies installed identity and supplies Production
and Harness configs, a `ServiceRegistry cfg` projects at either selected scope, and matching mapped codecs
admit their distinct wire schemas. The CLI verifies the executable identity once and retains it through
every dispatch boundary. Context fields describe placement and requested roles but do not themselves mint
mutation authority.

Current boundaries and open adoption:

- `BinaryContext`, `Capability`, and `RuntimeWitness` are constructible descriptive records and authorize
  nothing. [The step-algebra-and-project-plan phase](phase-12-step-algebra-and-project-plan.md) now
  implements the pure, jointly generated plan-bound `CurrentFrame`, `ProjectFrame`, and `ValidatedContext`
  package; Production and Harness dispatch plus public Chain consume the exact execute-phase evidence;
- `addRole` admits only the closed compatible leaf-to-leaf relation, and `validateTopology` rejects duplicate,
  cyclic, disconnected, illegal-placement, and incomplete witness graphs. These descriptive checks belong to
  [the Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md);
- project commands read and admit one sibling `ValidatedConfig`. Production retains or reconstructs one
  opaque `ProjectPlan` and carries it through rendering, persistence, journal/cursor admission,
  authorization, public Chain, and current-frame teardown. Harness constructs one exact
  `ProjectPlan (Harness projectId runId) ...` per selected variant and retains it through generated-config
  ownership, the same Chain interpreter, and exact reverse;
  service dispatch likewise verifies one snapshot and closes its action over the request. [The service-runtime
  phase](phase-22-service-runtime.md) owns changing the matching
  `ValidatedServiceRequest specDigest configId secretDigest fields service`/
  `RoleParams specDigest configId secretDigest fields service` handler from raw `IO` to a closed
  `ServiceProgram`;
- role selection is typed, and role wires contain framework validation plus only selected service fields while
  the full generated service/daemon config retains unrelated plan fields. Effect-indexed authorization and
  one-use execution remain [the service-runtime phase](phase-22-service-runtime.md)'s work;
- typed `CaseId`/`VariantId`, the total `TestMatrix` relation, and the demo's projection of declared
  `testVariants` from `<project>.test.dhall` are implemented by [the test-harness-and-run-ownership
  phase](phase-19-test-harness-and-run-ownership.md) and [the worked-demo phase](phase-24-worked-demo.md);
- `SecretRef scope` is opaque; Production cannot represent `TestPlaintext`, and Harness plaintext requires the
  matching generative run authority. [The authenticated-handoff phase](phase-13-authenticated-handoff-and-child-admission.md)
  supplies cross-process child grants, while [the recursive-lifecycle-command
  phase](phase-17-recursive-lifecycle-command.md) owns their live descent adoption; and
- exact authority-indexed Production/Harness profile construction is implemented by [the lifecycle-modes-and-run-leases
  phase](phase-9-lifecycle-modes-and-run-leases.md). [The cluster-lifecycle-and-cordoning
  phase](phase-16-cluster-lifecycle-and-cordoning.md) supplies backend operations and receipts; [the
  installed-identity-and-authority-kernels phase](phase-5-operator-root-and-command-authority.md) supplies only
  the lower root and reservation kernels; [the step-algebra-and-project-plan
  phase](phase-12-step-algebra-and-project-plan.md) owns the exact local/current-frame plan, journal, cursor,
  and authority substrate; and the [recursive-lifecycle-command
  phase](phase-17-recursive-lifecycle-command.md) alone owns proof-complete recursive command entry and
  traversal.

The target test configuration uses validated `CaseId` and `VariantId` values and a project-owned typed
projection from `tcfg` to labeled `cfg` variants. `all` is a parser selector over registered case IDs, not
stored configuration.

The target secret boundary uses `SecretRef scope` and a project-owned `ProjectConfig scope` (or equivalent
`cfg :: Type -> Type`, consumed as `cfg scope`). `SecretRef (Production projectId)` exposes only `Vault`,
`TransitKey`, and `Prompt`;
`TestPlaintext` requires matching `HarnessConfigAuthority projectId runId` and constructs only
`SecretRef (Harness projectId runId)`. Ordinary init/decode/dispatch remains project-indexed Production;
pure `psTestMatrix` validates stable variant drafts, then a fresh per-variant
`HarnessAuthority projectId runId` enters the shared `psAssemble`. Separate Dhall
schemas reject test plaintext on the production path before mutation. Harness Dhall decodes to an
untrusted wire type. Transport verification produces `VerifiedHandoff scope brokerGeneration`; exact-byte
config verification separately produces `VerifiedConfigWire` and `ValidatedConfig`, and only
`Config.Schema.withVerifiedConfigHandoff` joins those values into the fully indexed config-handoff proof
that `ProjectPlan.Construct.withChildProjectPlan` accepts. Controller restarts use a separately signed,
config-digest-bound runtime manifest rather than replaying that edge handoff. Raw wire cannot be promoted
merely because run authority exists, and no exported coercion can widen harness config into production
or another project/run.

## Thin Python Bootstrapper

| Surface | State | Contract / open work |
|---------|-------|----------------------|
| `doctor` | Implemented | Report the irreducible pre-binary host floor |
| `build` | Implemented | Explicit Cabal-file selection, one validated package/executable/artifact identity, conditional index refresh, explicit offline refusal, and unchanged-copy no-op |
| `run` | Implemented | The same idempotent host-native build followed by POSIX `exec` or a Windows child subprocess |
| `update` | Implemented | Explicit operator-invoked pipx self-update |
| `base build` | Implemented | Verified repository authority, native request/host/engine architecture equality, and the complete Python/core/demo source gate precede local inspection builds |
| `base build-and-push` | Implemented | Current-compatible resolution → source gate → native build → push rolling tag → pull → real-demo compatibility smoke; a digest may identify the pulled build without locking inputs |
| `check-code` / `test-all` | Implemented | Exposed only from the canonical checkout's in-project Poetry development interpreter through opaque maintainer authority |

Python does not own project Dhall, Docker/provider ensure, project-container construction, lifecycle, or
runtime cordons.

## Base Image and Warm Store

The rolling base image contains the Haskell toolchain, build tools, Kubernetes/container tools, and a
broad best-effort Cabal warm store selected from current compatible upstream versions at build time. It
contains no project binary and exposes no freeze-only integration `LABEL`/`ENTRYPOINT`. Projects
integrate by Cabal dependency plus `runHostBootstrapCLI`, use the same `cabal.project` on the host and in
a derived container, and may resolve/download/compile dependencies on a cache miss.

Current contracts:

- [the worked-demo phase](phase-24-worked-demo.md) makes every derived demo build pull the published rolling
  base and makes the host-native lane consume its freshly resolved repository digest;
- [the base-image-and-warm-store phase](phase-23-base-image-and-warm-store.md) supplies one host-compatible
  consumer project and opportunistic cache reuse;
- that phase's rolling build-time discovery selects current compatible releases over TLS and retains available
  integrity checks without becoming a committed replay lock; and
- its documented vanilla/dynamic shared-library ways match the artifacts present; profiling remains off unless
  explicitly enabled and validated.

## Command Tree

The supported top-level project-binary tree is:

```text
project init|up|down|destroy
test init [--replace]
test run <case-id>|all
service init|schema|run
context ...
check-code
```

`test init` writes through an opaque `TestConfigWrite` whose only producer resolves the sibling destination
from the project's own name, so the command supplies a typed test-config value rather than a path or rendered
bytes. Its replacement policy is stated rather than defaulted: an existing `<project>.test.dhall` is refused
by name unless `--replace` is passed.

[The test-and-context-commands phase](phase-20-test-and-context-commands.md) owns exact parser/gate
reconciliation, including which `context` operations exist and which commands may run without a sibling
config. Its static contract is implemented and its declared live linux-cpu sequence remains open. No
project-appended verbs or standalone `ensure` command are part of the target tree.

## hostbootstrap-demo

The demo is the worked consumer. Its current code includes VM/direct provider paths, kind/nvkind,
MinIO-backed registry storage, a web SPA, service ConfigMaps, and accelerator worker/daemon paths.

Current demo contracts:

- [the worked-demo phase](phase-24-worked-demo.md) owns the finalized proxy-through-registry topology and the
  repeated push/pull plus registry-pod-persistence proof;
- the demo's five-field `TestSuite` is assertion-only. Core retains one exact Harness-scoped `ProjectPlan`
  through generated-config ownership and the shared forward/reverse interpreter. Cluster, durable-root, port,
  and ownership identity currently still pass through config-derived `RunProfile`/`ClusterProfile` terms;
  Sprint 24.4 replaces those independent consumer inputs with the retained plan projection. The configured
  durable-readback case remains an explicit failing assertion until Phase 17 supplies a safe same-run
  destroy/restart transition and Phase 24 wires the write → destroy → fresh up → read proof;
- every derived compatibility build pulls the published rolling base, with a freshly resolved repository
  digest allowed only as a within-run identity rather than a consumer lock;
- typed cases and config variants derive from decoded test config, and the static demo component participates in
  the canonical `cabal test all` gate;
- Sprint 24.5 projects the concrete demo workload, overhead, partition, and exact resource slices into the
  Phase-16 cluster and Colima consumers;
- adopting `reconcileNodeGuestAlias` at the demo's `copy-source` step remains [the worked-demo
  phase](phase-24-worked-demo.md)'s Sprint-24.6 production-wiring item; and
- named non-baseline accelerator and durability confirmation belongs to [the Apple Silicon](phase-25-apple-silicon-substrate.md),
  [NVIDIA GPU](phase-26-nvidia-gpu-substrate.md), and [Windows/WSL2](phase-27-windows-and-wsl2-substrate.md)
  acceptance phases.

[The worked-demo phase](phase-24-worked-demo.md) owns demo wiring, provenance, and config-driven variants.
Reusable configuration, plan, and harness contracts belong respectively to [the Dhall-configuration-and-generic-project-model
phase](phase-7-dhall-configuration-and-project-model.md), [the step-algebra-and-project-plan
phase](phase-12-step-algebra-and-project-plan.md), and [the test-harness-and-run-ownership
phase](phase-19-test-harness-and-run-ownership.md).

## Update Rule

When a component changes, update this inventory's state and purpose, the owning phase, and the governed
canonical documentation together. Do not add a phase status or test-count roll-up here — the
[README phase table](README.md) is the sole status authority (§ J).

Each row names its owning phase by **name**, not by number, so a renumbering does not falsify this file
(§ A, § J).
