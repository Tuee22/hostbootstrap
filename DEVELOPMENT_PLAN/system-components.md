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
| `HostBootstrap.CLI` | Implemented construction boundary | Fixed command entrypoint; scope-indexed Production/Harness integration, opaque `ProjectSpecBuilder`/`ProjectSpec`, additive root-bound step fragments and other additive streams, and finalized typed service registry are implemented. There is no lifecycle slot beside the plan: descent and reverse are declared on the step. Receipt-aware lifecycle authority remains in its owning phases |
| `HostBootstrap.Command` | Partial | Parser/dispatch and command gates. The `test` grammar is closed against the project's typed vocabulary: `test run` names a `CASE-ID` (or the whole-matrix selector) and refuses an unknown case by naming the compiled set, and `test init` writes through an opaque `TestConfigWrite` whose producer resolves the sibling destination itself, refusing an existing file by name unless `--replace` is passed. Validated service dispatch is the service-runtime phase |
| `HostBootstrap.Detached` | Implemented boundary | The closed boundary for spawning a child that outlives its launcher (§ HH, the host-tools-and-substrate-detection phase, landed 2026-08-03). Its assembled `CreateProcess` is private, and so are `DetachedLaunch`'s constructor and *every field accessor*, so the stdio disposition, descriptor inheritance, session, and console detachment are properties of the boundary rather than fields a call site fills in; the executable is an `AbsExe` and the working directory and output sink are absolute by construction. `withDetachedChild` is a rank-2 bracket over the launch, not the child's lifetime: acquire-and-spawn is total, and the body's exceptions propagate unchanged. Standard input is the host's null device (open, at EOF) and both output streams share one retained sink the launcher reads to quote a startup failure (§ CC). `ForgeDetachedLaunch.hs`/`RelabelDetachedLaunch.hs` pin the seals and `DetachedSpec` observes a real child through the boundary. Closed on the Apple Silicon lane 2026-08-03 at `10/10 passed`, where the host daemon reached readiness on all four bring-ups |
| `HostBootstrap.HostTool` | Implemented boundary | Closed tool enumeration and `AbsExe`; every governed host call resolves to an absolute path |
| `HostBootstrap.HostConfig` | Implemented | Resolved host configuration |
| `HostBootstrap.HostPrereqs` | Implemented floor | Haskell host prerequisites aligned with the pre-binary Python floor |
| `HostBootstrap.Substrate` | Implemented | Apple/Linux/Windows CPU/GPU substrate classification |
| `HostBootstrap.Ensure*` | Partial | The nine config-free reconciler families remain; Colima is a separate plan-bound per-project adapter. Incus now converges and totally classifies daemon reachability, permission, VM capability, and required image-server egress, and only the ready branch mints its opaque capability. WSL global-state ownership and recursive command integration remain downstream. The existing `fitsBudget` predicate is not the sole wired admission authority |
| `HostBootstrap.Cluster.Cordon` | Implemented pure parser/builder boundary, partial live enforcement | Exact whole-byte quantity parsing, resource builders, capacity preflight, and the typed bare-Linux `StorageCordonUnsupported` policy exist. Whole-GiB providers reject inexact hard ceilings instead of rounding upward. Direct Colima has an exact observed project-wall adapter; Incus/WSL and existing Lima walls are not fully reconciled, while conditional cleanup remains the cluster-lifecycle-and-cordoning phase work |
| `HostBootstrap.Cluster.Budget` | Implemented the canonical-quantities-and-reconcile-results phase foundation plus Colima adapter | Closed provider keys; plan-indexed validated/effective budget; workload fit; constructive partitions/slices; and journal-before-call wall reservation/preparation/settlement are opaque. WSL success returns its lease inseparably and uncertain acquisition returns no authority. the worked-demo phase owns the complete demo workload projection; remaining provider phases own their live CAS/adapters |
| `HostBootstrap.Cluster.Lifecycle` | Partial | Cluster planning/lifecycle; the host-tools-and-substrate-detection phase closed canonical project-root admission and the direct-host durable projection, the cluster-lifecycle-and-cordoning phase owns receipt-aware backend storage operations, and the test-harness-and-run-ownership phase owns Production/Harness mode/profile opening over the operator-root-and-command-authority phase's command authority. `profileDataSegments` is the single definition of where a run's durable state lives — production's never-removed `.data` or a harness run's owned `.test_data/<run>` — and both a resolved plan's preserved `dataPath` and a consumer's `CanonicalHostPath` mount derive from it, so the directory mounted and the directory preserved are one by construction |
| `HostBootstrap.Cluster.Backend` | Implemented clause-holding backend, call site open | The four § EE clauses for the kind/nvkind cluster over an injected `ClusterExec`, plus the loopback-bound exposure operation. the cluster-lifecycle-and-cordoning phase (2026-08-02) made the clause-1 front end **probed rather than assumed**: discovery accepts `flock(1)` or `lockf(1)` — two shell front ends for the same `flock(2)` on the same inode — reports which it found, retains it on the opaque capability, and fails closed on an unrecognized report, so the clause suite executes on a BSD userland as well as a GNU one. Wiring it at the live `deploy-kind` call site remains the cluster-lifecycle-and-cordoning phase/16.6 |
| `HostBootstrap.Step` / `Chain` / `Teardown` | Implemented forward, descent, and reverse boundaries; partial lifecycle | Opaque steps, disjoint typed identities, explicit reverse policy, operation keys/dependency prefixes, exact-order `StepPlan` validation, the plan-owned per-frame descent (`descendsVia`/`frameDescent`, validated one-per-frame), the plan-owned reverse effect (`reversedBy`, driven by `runTeardownProjection` for both verbs), and one plan consumer are implemented. A step's forward action is `StepAction` — `forall scope planId. StepExecution scope planId -> IO StepObservation` — so the interpreter hands each action the descriptor the plan minted for its own node (§ U) instead of a bare `HostConfig`, and converts what the action observed into that node's own row; `Chain.runChainFromFrame` therefore takes the `LifecyclePlan`. A step also declares the operations it **projects** with `projectsOperation`; `mkStepPlan` admits the shape `<zero or more of the step's dependency keys, in plan order>/<its own key>/<suffix>`, claimed once per plan, so the declaring node is the last resource the relation names and no sibling can reach it. The interpreter registers, gates, and settles each projection with its node, and leaves an untaken one unsettled so the close refuses. The recursive child-first unwind, and with it the `TeardownForest`'s first production call site, remain the recursive-lifecycle-command phase |
| `HostBootstrap.Lifecycle.Execution` | Implemented | The opaque plan-minted execution descriptor a step's action receives: the host-tool configuration plus the exact plan digest, operation key, frame, and ordered dependency edge set the step runs under, indexed by the plan's `scope`/`planId`. Its sole producer is `Reconcile.stepExecutionFor`, which derives every field from the `LifecyclePlan` rather than from a caller, and its constructor is package-internal (`ForgeStepExecution.hs` pins that). Sealing the edge set into an `OperationPreconditionSet` is the prepared-operations phase's traversal, and the descriptor now reaches the prepare compare-and-swap through `Session.withStepPreparedGate`, which reads the plan digest and operation key off the descriptor so a step can gate exactly one node — its own. A step's action returns a typed plan-independent `StepObservation`, which the chain interpreter converts into that node's own row. The interpreter drives the full § EE transaction per node — durable unknown phase inside an exclusive entry, effect outside any entry, settle inside a fresh one — and the action reaches the gates that transaction opened: `stepExecutionPreparedGate` for the node's own operation and `stepExecutionTakeProjectedGate` (once per key) for each operation the plan validated as a projection of it. The descriptor also carries the interpretation's `ResourceCarrier scope planId`, through which `Reconcile.carryManagedResource` and `withCarriedManagedResource` move a dependency's `Managed` handle in process from the node that acquired it to the node that declared an edge to it. Minting a `Managed` handle through a gate is a resource adapter's act; the first is the host-providers phase's guest-alias adoption |
| `HostBootstrap.Teardown` | Implemented projection/forest, call sites open | The verb-indexed reverse projection (the recursive-lifecycle-command phase, 2026-07-30). `teardownPlan` reads the validated `StepPlan` out of the `LifecyclePlan` itself, so forward traversal and reverse teardown provably name the same resources; `down` stops a provider frame and `destroy` deletes it, while both delete the kind cluster and neither can touch a `PreserveOnReverse` step. `openTeardownForest` is the sole initial producer; the forest enforces child-first recursion with a destroy-only pre-descent reachability step, returns a successor on every outcome, keeps a failed node's parent blocked while siblings drain, and never completes while a failure stands. `verifyDestroySettled` accepts only a completed `Destroy` forest and is the sole producer of `DestroySettled`, reached from a verb-polymorphic call site only through `settledDestroyEvidence`, which matches the verb index inside the module so a `down` run yields nothing. `driveTeardownForest` is the loop the production verbs run: `project down`/`destroy` open the forest over the real plan, descend into the next frame by invoking the same verb there through the plan's own declared descent, run each node of this frame through the reverse its own forward step declared, and report one structured row per node. The frame index — the `frame` phantom on plan, forest and cursor, its `CurrentFrame` witness, and the closed local/foreign cursor sum that replaces comparing frame names — is the recursive-lifecycle-command phase's open work, and the descent's typed admission arrives with the authenticated-handoff phase's recovery tag. Converting the proof into `Lifecycle.Mode.destroySettledClosure`'s `ProjectClosureEvidence SettledDestroyClose` needs a bound run lease the lifecycle verbs do not open; that is the recovery-and-migration phase |
| `HostBootstrap.Readiness` | Implemented the canonical-quantities-and-reconcile-results phase foundation, partial live integration | Opaque validated polling and total results; closed backend probes require exact planned resources and mint generative plan/resource/dependency-indexed readiness. `planDependencyProbe` registers a probe for the traversal to run at prepare time rather than binding a retained observation. `ObservedReady` is explicitly non-authorizing compatibility evidence. Provider/interpreter phases own migration of live effects to prepared operations |
| `HostBootstrap.Reconcile` | Implemented the canonical-quantities-and-reconcile-results phase foundation | Final-codec/step-plan lifecycle identity; opaque planned resources/edges, reconcile/adoption outcomes, prepared operation pairs, phase-indexed handles, and legal persisted journal transitions. the recursive-lifecycle-command phase added the plan-owned dependency-snapshot traversal: a descriptor's edge set is the exact ordered **resource-bearing** prefix, and the sealed `OperationPreconditionSet` the prepare consumes has one producer that runs each member's probe itself. It then removed the caller-supplied journal version: `withPreparedOperation` takes a `Lifecycle.Prepared.PreparedGate` instead of two `Word64`s and refuses one recorded under another plan digest or operation key. Direct Colima acquisition is implemented; live protected-store and remaining adapter interpretation continue in the cluster-lifecycle-and-cordoning phase, 10.9, 11.10, 15.9, and 16.6 |
| `HostBootstrap.Protected` | Implemented | The protected, versioned record store every durable lifecycle decision compare-and-swaps against: portable OS-released exclusive entry (`hLock`), non-re-entrant sessions, atomic publish, expected-version writes/deletes, durable store identity, and a non-blocking `tryProtectedEntry`. `mkRecordName`/`recordNameIdentity` are the one injective encoding by which a **namespaced** identity — a plan operation key `core:deploy-kind`, a plan digest `<specDigest>:<planBytesDigest>` — reaches the key alphabet; its image (components with a `.`) and its plain domain (components without one) are disjoint, and a `/`-separated path of such identities — which is what a relation between operations is — encodes segment-wise joined by `..`, which no segment may contain. Two identities can therefore never share a record |
| `HostBootstrap.Authority` | Implemented root/command boundary, partial handoff | Type-indexed closed `ProjectVerb`/`LifecyclePhase`, installed project identity, the OS/operator check, monotonic broker generations, the non-config `RootInvocationAuthority` gate, one-use `CommandAuthority` reservation, and the root/verb half of Production closure. The broker-relayed cross-frame handoff and the prepare compare-and-swap remain the operator-root-and-command-authority phase work |
| `HostBootstrap.Lifecycle.Mode` | Implemented mode/lease/profile boundary, partial recovery | Project-wide mode exclusion, unbound/bound run leases, fresh Production/Harness `LifecycleProfile` openers, composite root brackets, closure evidence, mode release, and the abandoned-run sweep. The sweep takes separate unbound and bound fold callbacks, so an unbound run's owned state is reclaimed before its lease closes. `classifyAbandonedBoundRun` gives the bound half its own producer of `BoundInvocationRecovery` — reachable only from a `VerifiedIncompleteRunLease` the sweep minted, and only for its `IncompleteBound` kind — so a bound abandoned Harness run is now classified and resolved rather than only named. A persisted `Closing` epoch is now resumed rather than refused: `resumeHarnessClose` is the only route to a close authorization that does not persist a new epoch, it admits exactly the epoch the dead run recorded, and it needs no fresh all-sessions-closed proof because the close it resumes already consumed one. The reopening now also yields the fresh authority broker, the old-permit fence set, the verified session/operation manifest, the recorded-session interpretation, and the `CurrentBrokerSessionAdmission` only all three together can mint. The **plan-migration** algebra sits here too: `withProjectUpMigrationProfile` is the sole producer of a revision carry and admits only a `NormalActiveRecovery` binding; `withProspectiveMigrationPlan` persists and authoritatively reads back one candidate under a derived stable migration key and yields a non-authorizing `ProspectivePlanSnapshot`; `withPlanMigration` records the incomplete side of the barrier and then freezes the old lease, which is what stops old-revision preparation; `commitMigrationActivation` switches the lineage and records the completed side, converging rather than refusing when re-run against the same frozen capability; `activateMigratedPlan` settles the old revision's sessions before admitting the new revision's broker; and `withCompletedMigrationRecovery` is the configless post-CAS path that recovers the superseded revision from the durable key rather than from any config. The configful forward rebuild (`withCompletedMigrationPlan`, and a candidate built from real drafts) and the complete resource-record rehydration remain the recovery-and-migration phase's work |
| `HostBootstrap.Harness.Ownership` | Implemented | The production run-ownership bracket: abandoned-run sweep with separate unbound/bound fold callbacks, protected mode/lease acquisition, data-root acquisition/release through `Harness.DataRoot`, and generated-config acquisition/release through `Harness.GeneratedConfig`. It replaces the unrecoverable `.test_data.hostbootstrap-run-owner` and `<config>.hostbootstrap-test-owner` lock directories. Its bound-run callback resolves an ordinary Open revision that `verifyNoProjectResourcesAcquired` proves acquired nothing — reclaiming both owned objects and closing the lease and mode — and stays fail-closed, naming why, on a persisted `Closing` epoch, either migration revision, or a run that did record effects |
| `HostBootstrap.Harness.DataRoot` | Implemented | All four § EE ownership clauses for the run's durable data root, and the first § EE backend wired into a production route: exclusive entry is the caller's `ProtectedSession`, the origin record names the exact prior identity-or-absence before the directory is created, ownership binds the created directory's stable kernel identity, and release/recovery re-observe that identity — refusing a replacement instead of deleting it. A host without a stable identity is `Unsupported` and mints no ownership |
| `HostBootstrap.Harness.GeneratedConfig` | Implemented | The same four § EE clauses over the run's generated sibling `<project>.dhall`, and the second § EE backend wired into a production route: exclusive entry is the caller's `ProtectedSession`, the origin record names the recorded absence **and the intended payload digest** before the file exists, the file is published create-if-absent, ownership binds its created kernel identity, and release/recovery unlink only on an exact re-observed identity **and** payload. A found object is refused before any mutation rather than adopted, and a host without a stable identity is `Unsupported` |
| `HostBootstrap.Harness.Identity` | Implemented | The shared clause-3 identity layer both harness ownership protocols bind to, so the directory and file realizations cannot drift: a private-constructor `ObjectIdentity`, its hex journal codec, the injected `ObjectIdentityBackend` seam, and the closed `IdentityFault` each protocol maps into its own vocabulary |
| `HostBootstrap.Harness.Identity.Native` | Implemented; native Windows gate passed 2026-08-01 as `Harness.DataRoot.Native` | The host identity backend behind that seam: POSIX `lstat` `(device, inode)`, and on Windows `GetFileInformationByHandle` over a handle opened with `FILE_FLAG_BACKUP_SEMANTICS` and locally defined `FILE_FLAG_OPEN_REPARSE_POINT`. Volume word first, little-endian, as the peer ownership backends encode it. `DataRootSpec` and `GeneratedConfigSpec` both run this backend directly |
| `HostBootstrap.Handoff` | Implemented | The authenticated cross-frame handoff transport: length-delimited framing, the length-prefixed `HandoffBinding` and its exact inverse parse, the root-only Ed25519 `RootBroker` with its keyless `BrokerRelay`, fresh-challenge grants, `VerifiedHandoff`, and `ChildPlanAuthority`. `registerHandoffEdge` is the root's sole opener and writes the edge durably before a grant can be asked for, so `grantHandoff` answers only for an edge the root opened (`HandoffEdgeUnregistered` otherwise) and relaying is strictly weaker than signing. Consumption is a compare-and-swap at the observed version: an identical retry returns the same deterministic signature, any other challenge is a reuse refusal |
| `HostBootstrap.Handoff.Receiver` | Implemented, live call site open | The child half of the exchange over a duplex `HandoffChannel` (`stdin` inbound, `stdout` outbound — the only descriptors a container or VM boundary carries, so a receiving binary's diagnostics belong on `stderr`). `withReceivedHandoffEdge` mints a fresh challenge after the offer arrives, verifies against the independently installed key, admits the exact bytes, and sends every refusal rather than closing the pipe; its continuation is rank-2 in the edge's indices. Message order is enforced by `ChildProtocolState`. Adopting it at the recursive descent, in place of `Lift.ConfigDelivery`'s shell writer, is the recursive-lifecycle-command phase |
| `HostBootstrap.Handoff.Relay` | Implemented, live call site open | The parent half and the duplex relay. `BrokerLink` is a frame's route to the root's two capabilities — open an edge, grant one; `rootBrokerLink` carries the live broker plus the plan's `EdgeAdmission`, and `relayedBrokerLink` carries a channel and a request identity and nothing else, so an intermediate frame is structurally keyless (pinned by `RelaySignsWithoutBroker.hs`). `offerHandoffEdge` is one descent implementation for every frame: open through the link, offer, then serve whatever the child relays upward. Proved across a real three-process chain |
| `HostBootstrap.Activation` | Implemented foundation | The broker-signed runtime role activation: an `ActivationManifest` binding the immutable rollout revision and every pre-instantiation index but deliberately no instance identity, startup's own `RuntimeMeasurement` (binary, mounted wire, private bundle, pod UID plus restart count or host invocation nonce), the inseparable `VerifiedRuntimeRoleActivation`, and the one-use `LifecycleAdmission` compare-and-swap. Secrets are representable only as digests. the composition-and-network-algebra phase and 18.6 own the consuming role lifecycle and service gate |
| `HostBootstrap.Build` | Implemented foundation | Ephemeral build-invocation authority for the in-Dockerfile gate: the signed `BuildBinding`, the coordinator's Ed25519 grant, independent source-context and builder-binary measurement, the coordinator channel (absent channel is an explicit refusal, not a fallback), `ImageBuildFrame`, and the narrow `CheckCodePhase`/`BuildPhase` authorities. No function accepts a `BinaryContext`, so the baked image-build config reaches none of it. Requiring it at `checkCodeCommand` and in the demo Dockerfile is the recursive-lifecycle-command phase |
| `HostBootstrap.Lifecycle.Prepared` | Implemented | The shared lower module that owns the durable half of a prepare (the recursive-lifecycle-command phase, 2026-07-30). `PreparedGate` hides its constructor and its sole producer, `recordDurableUnknown`, performs the compare-and-swap that publishes an operation's unknown phase, so the plan, operation, fence, attempt, and journal version an adapter is prepared against are the store's rather than a caller's literals. It sits below both `Lifecycle.Session` and `Reconcile`, which the `Session -> Authority -> Reconcile` dependency would otherwise keep from naming each other |
| `HostBootstrap.Lifecycle.Session` | Implemented foundation | The protected operation session, durable idempotent fence rotation, the total recovery discriminator, and the prepare compare-and-swap that records the operation's unknown phase before an adapter can run — now minting the `Lifecycle.Prepared` gate `Reconcile.withPreparedOperation` requires. `withStepPreparedGate` is the route a step's plan-minted descriptor takes to that gate, refusing a descriptor whose plan digest is not the session's; the chain interpreter drives it for every node of a live `project up`. A thrown safety refusal settles terminally like a returned one, while any other exception leaves the record unknown for recovery to own. It also owns the **abandoned-run admission** chain: `fenceOldPermits` completes an unsettled initial-fence protocol idempotently, enumerates the exact operation keys still holding authority, and only then rotates; `verifySessionManifest` pairs the independently enumerated complete session and operation sets and refuses an orphan operation, a duplicate session, or a declared membership the store contradicts, keeping a zero-operation Open session as a required member; `interpretRecordedSessions` handles every operation by its recorded disposition, rebinds each still-Open session onto the fresh generation, and closes it, leaving committed work untouched and refusing an unrecognised phase; and `admitCurrentBroker` is the sole producer of `CurrentBrokerSessionAdmission`, which needs all three and re-proves every session Closed |
| `HostBootstrap.Context` | Partial | Descriptive binary context and command capability checks; the total topology-graph validator and the closed `ContextPlacement`/`requiredWitnesses` relation (exact required evidence set per placement) are landed; closed the host-tools-and-substrate-detection phase resolves `sourceRoot` separately without rewriting the context, and opaque command authority/narrowing is the operator-root-and-command-authority phase.9 |
| `HostBootstrap.ProjectRoot` | Implemented foundation | Private rank-2 canonical-root admission, same-root host durable projection, and the typed direct-host mount adapter are implemented. `canonicalHostSubPath` derives a host path under the admitted root from supplied segments — a run-scoped durable root is not a fixed name — and checks each is a single ordinary component (non-empty, no separator or drive letter, neither `.` nor `..`), so a segment cannot hand a trusted adapter a path the root never admitted; the final opaque plan and remaining boundary projections are owned by the test-harness-and-run-ownership phase, 11.10, 16.6, and 19.8 |
| `HostBootstrap.Substrate.Provider` | Implemented backend, production call-site migration open | Single provider launch/share/alias data route; direct-host aliases are removed. `Provider.Alias` supplies the clause-holding guest backend and opaque prepared call/release receipts, plus `reconcileNodeGuestAlias` — the route a step action takes, resolving the provider and durable share from its own node's plan prefix, deriving the alias from its own declared projection, taking the interpreter's gate for that projection once, and sealing the durable share's carried managed handle. The demo's use of that route is the worked-demo phase's. Its guest-userland assumptions became probed on 2026-08-02: discovery reports the guest's exclusive-lock front end (`flock`/`lockf`) and asks `stat` itself which identity dialect it speaks (`-c`/`-f`), both retained on the capability and passed to one byte-identical script, so the four clauses run on either userland — which matters in the ordinary case, since a macOS host drives a Linux guest. `spStop` and `spDestroy` release the production WSL2 global wall before the disclosed global `wsl --shutdown` effect |
| `HostBootstrap.Lift` | Implemented, pending operation integration | Sole provider-backed nested command dispatch; live provider mutations still need the plan-owned prepared-operation pair |
| `HostBootstrap.Incus` / `Lima` / `Wsl2` | Partial provider integration | Provider argv/probes and launch builders exist; Incus has a total capability/egress classifier and the unused WSL import builder is gone. The production WSL utility-VM wall now enters through the journalled host-wall driver and releases on teardown; prepared-operation adoption across every provider mutation and the remaining native lanes stay open in their owning sprints |
| `HostBootstrap.Wsl2.GlobalWall` | Implemented production authority and recovery driver | Exact present/absent origin, durable unknown phases, identity-bound stage/apply/restore classification, fencing, opaque receipt/authority values, and conflict-only recovery are consumed by the production `ApplyGlobalWslWall`/`ReleaseGlobalWslWall` route. The shared model/codec gate is portable, the full driver gate runs on POSIX, and a focused native Windows production-entrypoint gate passed 4/4 on 2026-08-01 |
| `HostBootstrap.Wsl2.GlobalWall.ConfigBytes` | Implemented, retained | Strict bounded UTF-8/UTF-16 transformation with idempotence fixtures. Portable and unaffected by the ownership restatement; carried forward unchanged |
| `HostBootstrap.Wsl2.GlobalWall.Windows` | Implemented production backend; focused native gate passed 2026-08-01 | Windows realization of the portable host-wall driver. Public `Win32` types/wrappers cover ordinary operations; a narrow direct `kernel32` FFI preserves exact status for ownership-critical handle and namespace calls. The superseded `cbits` shim, its `hb_wsl_*` wrapper imports, Cabal `c-sources` block, and threaded-RTS carve-out are removed; no private `Win32` module or C source remains |
| `HostBootstrap.Harness` | Implemented typed foundation, partial ownership | Opaque typed case/variant matrix, selection, and reporting are implemented. `CaseResult` distinguishes the project's own `Fail` from the engine-classified `Refused`, `LifecycleFailed`, and `TeardownFailed`, and the report card labels each distinctly; the `Conflict`/`Unsupported` rows arrive with the reconciler wiring of the cluster-lifecycle-and-cordoning phase/16.6, since nothing produces those outcomes yet. Exclusive run ownership is an injected `HarnessRunOwnership` seam the command layer fills with `Harness.Ownership`; receipt-driven cleanup and the harness close projection remain the test-harness-and-run-ownership phase.9 |
| `HostBootstrap.Service` | Implemented typed codec/request boundary, partial runtime | Closed typed registry definitions bind identity/projection/role codec/handler; finalization shares one digest with the full codec, service dispatch verifies one snapshot, and a handler's whole input is `ServiceHandler fields` = `RoleParams specDigest configId secretDigest fields service -> IO ()` — its own role's opaque bundle, with no framework view, so a role that needs a framework datum declares it as a field its own projection supplies. Replacing the handler's raw `IO` with one-use effect-indexed execution is still the service-runtime phase's; the composition-and-network-algebra phase integrates the phase lifecycle; native accelerator real-run evidence remains open |
| `HostBootstrap.RoleLifecycle` | Implemented engine, call site open | The phase-indexed role lifecycle (the composition-and-network-algebra phase, 2026-07-30). It also carries the declared effect row: `RoleEffect` promotes, `EffectName` is its per-effect tag, `DeclaredEffects effects` is a type-level row whose term-level twin agrees by construction, and `HasEffect` has no empty-row equation so an undeclared effect is an unsolved constraint rather than a runtime refusal. `authorizeServiceEffects` is the sole producer of `EffectAuthorization … effects`, admitting a declared row only within the signed `permittedEffects` ceiling and recomputing the lease requirement from the declaration. The public `RoleSpec`/`runRole` callback bag is deleted. A role now passes `verifyRolePlanDraft` (no durable mutation) → `withRoleLifecycleAdmission` (one-use reservation keyed on plan digest, frame, revision, and measured instance) → `withRuntimeRolePlan` (CAS-consumes that reservation, mints `RolePlan`/`RolePlanDigestBinding`/`VerifiedServicePlacement` and the sole `Prereq` cursor), after which the core-owned engine privately drives Prereq → Acquire → Ready → Serve → Drain → Exit and returns only `RoleExitReport`. The lease requirement is derived from the signed effect ceiling, and the exclusive branch holds a kernel lock across Acquire→Drain. `service run` does not yet enter through it: nothing in production can mint a `RootInvocationAuthority`, so no `ActivationManifest` can be signed (the recursive-lifecycle-command phase item 1). the service-runtime phase adds the effect-indexed selected-service package on top |
| `HostBootstrap.Service.Program` | Implemented program/interpreter, registry adoption open | The closed effect-indexed `ServiceProgram payload service effects a` a handler returns. Constructors are private and there is no `IO`/`MonadIO` constructor, so a project builds one only through the smart constructors and the `Monad` instance and cannot write a second interpreter; `interpretServiceProgram` is the sole eliminator and demands the `EffectAuthorization`. Payload types sit under one `payload` index with associated types, so a program and its backend agree by one type equality. Every listener/peer/worker argument is an `AcquiredResource service` the Ready phase alone produces. `DurableStore` is core-executed against a `DurablePath` minted only through `canonicalHostSubPath`; the other three families reach an injected `ServiceBackend`, the `ClusterExec`/`GuestExec` boundary. There is no unauthorized-effect failure: the indexed row and the authorized row agree by construction. `serviceDefinition` does not yet take a row and no call site builds a backend |
| `HostBootstrap.Config.*` | Implemented root/config-role boundary, partial handoff | Generic scope-indexed config classes, opaque secret refs, canonical verification, common framework view, full-vs-role/scope discriminators, `RoleCodec`, request, and role parameters are implemented. Authenticated child handoff/command authority remain Phases 15.9/16.6. The package-internal `Config.Install.Native` supplies the atomic no-replace publication primitive the authenticated sibling install requires — a **hard** link (`link(2)` / `CreateHardLinkW`), which publishes the written bytes under the final name and fails when the name is taken; the former symbolic link published a reference the inspector then refused, so the installed outcome was unreachable (repaired 2026-08-02, the operator-root-and-command-authority phase) |
| `HostBootstrap.Dhall.*` | Implemented foundation | Opaque `CodecWitness` owns schema/decode/render, opaque artifacts require an admitted codec, literal schema commands are snapshotted, every current `Core.dhall` type export is equality-owned, and the Dhall-configuration-and-project-model phase's `ProjectCodec` supplies installed identity/scope/spec-digest binding |
| `HostBootstrap.Registry` | Partial | Docker Hub credential discovery/forwarding exists, but raw-text/substring classification and environment transport remain open in the operator-root-and-command-authority phase/19.7; schema/artifact registration lives in `HostBootstrap.Dhall.Gen` |
| `HostBootstrap.Network` / `HostBootstrap.RegistryPlan` | Implemented generic algebra | Closed the composition-and-network-algebra phase landed scope-indexed endpoints/clients/exposures, proof-gated blob delivery, opaque finalized registry plans, and route-specific readiness; the worked-demo phase consumes them in the demo |
| `HostBootstrap.DocValidator` | Implemented | Mechanical documentation checks; new drift floors are the documentation-reconciliation phase.4 |

## Lifecycle Type Contract

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
Ordinary project teardown preserves it in both scopes; an exact settled/no-project-effects closure proof
plus the bound harness lease can mint a harness-only terminal close plan for that run's generated config
and `.test_data`.

The target execution profile is opaque:

```text
LifecycleProfile (Production projectId)
LifecycleProfile (Harness projectId runId)
RecoveredProductionLifecycleProfile projectId specDigest planDigest planId brokerGeneration
```

the operator-root-and-command-authority phase.9's independent non-config gate mints only exact root invocation authority. the test-harness-and-run-ownership phase.9 owns all
profile opening: fresh Production/Harness profiles require their still-unbound lease, while configful
abandoned Production `ProjectUp` requires the exact root/mode/bound-lease/snapshot/recovery tuple and can
open only the indexed recovered profile. Exclusive harness ownership can open only its run-indexed fresh
profile; Harness/teardown recovery cannot inhabit the Production recovery type. Exact verb/frame/phase command
authority is derived later from that root, the validated plan/context, and the journal cursor.
`containerPlan` derives cluster
name, data root, ports, and ownership identity from the profile. A
`TestComponent` receives only harness-profile authority and cannot call the Production planner.
Successful Production `ProjectUp`/`ProjectDown` closes only its terminally acknowledged
`BoundRunLease`/broker invocation; Production mode, active snapshot/revision, Open-project state, and
resource records remain. Destroy/true-pre-effect project closure is the separate mode-release path.

## Ensure Reconcilers

| Reconciler family | Host applicability | Notes |
|-------------------|--------------------|-------|
| Docker | supported host substrates | Post-binary dependency |
| Homebrew / GHC | Apple Silicon | Core reconcilers are Apple-only; Linux/guest toolchain bootstrap follows the separate bootstrap/lift path |
| Colima / Lima | Apple Silicon | Provider-specific |
| Incus | Apple/Linux | Apple Incus is explicit-provider support; demo default uses Lima |
| WSL2 | Windows | Provider install/readiness; provisioning route consolidation is the host-providers phase.10 |
| CUDA | Linux GPU | Requires detected NVIDIA device/driver visibility |
| CUDA Windows | Windows GPU | Host-native build stack |
| Apple Metal | Apple Silicon | Host-native accelerator build stack |

Reconcilers must adopt the the canonical-quantities-and-reconcile-results phase `ReconcileResult` contract. A mere executable-present Boolean is not
the final reconciler state model.

## Project Configuration

Each built project binary owns a sibling `<project>.dhall`. The current config type is project-defined
through `ProjectSpec projectId cfg tcfg`, where `cfg` is scope-indexed; core does not own universal
project defaults. One restricted `psAssemble` supplies Production and Harness configs, and matching
mapped codecs admit their distinct wire schemas. Context fields describe placement and requested roles
but do not themselves mint mutation authority.

Current partial surfaces:

- capability and witness constructors/record updates are not fully opaque (the operator-root-and-command-authority phase.9);
- `addRole` unions classes/capabilities even when the primary context kind is incompatible:
  `service run` separately rejects a non-leaf primary kind, while `project up` can accept a widened
  daemon/image-build leaf (the operator-root-and-command-authority phase.9);
- topology validation follows only the selected parent chain and executes only supplied runtime
  witnesses; it does not reject every duplicate/cycle/disconnected frame or prove that the required
  witness set is complete (the operator-root-and-command-authority phase.9);
- `project up` step actions can still reopen the sibling config after initial validation, so one
  invocation can mix config versions; service dispatch no longer does—it canonically verifies one
  snapshot and closes the action over its request. the operator-root-and-command-authority phase.9 threads one `ValidatedConfig` into plan
  construction and closed plan operations, while the service-runtime phase.6 gives a service handler only the matching
  `ValidatedServiceRequest specDigest configId secretDigest fields service`/
  `RoleParams specDigest configId secretDigest fields service` through a
  closed `ServiceProgram`, never the snapshot or full config;
- the arbitrary string selector and fallback parameters are removed; role wires contain framework
  validation plus only selected service fields, while the full generated service/daemon config still
  retains unrelated plan fields. Effect-indexed authorization and one-use execution remain the service-runtime phase;
- typed `CaseId`/`VariantId` and the total `TestMatrix` relation are implemented, while the demo's
  concrete variants remain hard-coded until the worked-demo phase.5;
- `SecretRef scope` is opaque; Production cannot represent `TestPlaintext`, and Harness plaintext
  requires the matching generative run authority. Cross-process child grants remain downstream;
- the demo's variant set is projected from `<project>.test.dhall`'s declared `testVariants`, each name validated into a `VariantId` before the matrix exists; and
- the current production/test profile can be selected without authority-indexed construction, and the
  self-invoked child receives no authenticated one-time authority handoff. the cluster-lifecycle-and-cordoning phase supplies the
  backend operations/receipts; the operator-root-and-command-authority phase supplies the independent root and command gate; the test-harness-and-run-ownership phase
  owns the mode/profile opener; and the recursive-lifecycle-command phase consumes them in the recursive plan.

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
untrusted wire type; exact `ConfigHandoff` grant/byte verification jointly produces the generic
`VerifiedConfigWire`, `VerifiedHandoff`, child-local config authority, and `ValidatedConfig` under one
fresh identity, including pointer-only configs. Controller restarts use a separately signed,
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

Open contracts:

- the demo's pulled rolling-base consumption remains the worked-demo phase.18;
- one host-compatible consumer project and opportunistic cache reuse are the base-image-and-warm-store phase.4;
- rolling build-time discovery must select current compatible releases over TLS and retain available
  integrity checks without becoming a committed replay lock (the base-image-and-warm-store phase.4); and
- documented vanilla/dynamic shared-library ways must be mechanically matched to the artifacts actually
  present; profiling remains off unless explicitly enabled and validated (the base-image-and-warm-store phase.4).

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

the test-and-context-commands phase.4 owns exact parser/gate reconciliation, including which `context` operations exist and which
commands may run without a sibling config. No project-appended verbs or standalone `ensure` command are
part of the target tree.

## hostbootstrap-demo

The demo is the worked consumer. Its current code includes VM/direct provider paths, kind/nvkind,
MinIO-backed registry storage, a web SPA, service ConfigMaps, and accelerator worker/daemon paths.

Open demo contracts:

- the host Docker client can currently receive a `307` redirect to cluster-only
  `minio.default.svc`; the worked-demo phase replaces the raw topology and proves repeated push/pull plus
  registry-pod persistence;
- thread one typed Production plan and a harness-only `TestComponent`;
- derive every cluster/root/port identity from the opaque lifecycle profile;
- pull the published rolling base before a derived compatibility build; a resolved digest may identify
  that workflow input without becoming a consumer lock;
- reconcile stale Harbor/appended-verb metadata with the current registry/MinIO path;
- drive typed cases/variants from decoded test config;
- add the threaded RTS contract to the static demo test component and restore the canonical `cabal test all`
  gate (the worked-demo phase); and
- complete the named native accelerator and durability real-run gates.

the worked-demo phase owns demo wiring/provenance; the worked-demo phase owns config-driven variants; generic harness/type work
remains in Phases 10 and 19.

## Update Rule

When a component changes, update this inventory's state and purpose, the owning phase, and the governed
canonical documentation together. Do not add a phase status or test-count roll-up here — the
[README phase table](README.md) is the sole status authority (§ J).

Each row names its owning phase by **name**, not by number, so a renumbering does not falsify this file
(§ A, § J).
