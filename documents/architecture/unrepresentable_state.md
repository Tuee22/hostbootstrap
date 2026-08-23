# Unrepresentable Illegal State

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [readiness.md](readiness.md), [ownership_invariant.md](ownership_invariant.md),
[hostbootstrap_core_library.md](hostbootstrap_core_library.md),
[binary_context_config.md](binary_context_config.md),
[../../DEVELOPMENT_PLAN/development_plan_standards.md](../../DEVELOPMENT_PLAN/development_plan_standards.md)

> **Purpose**: State, once, the method this repository uses to make an illegal value impossible to
> construct — and state exactly what that method does not buy.

## TL;DR

- A boundary is a **type**, not a convention, a comment, or a review habit.
- Four techniques carry it: private constructor + validating smart producer; rank-2 continuation;
  closed sum + total eliminator; phantom indices.
- A claim of unrepresentability **ships a compile-fail fixture**. Without one, the claim is a comment.
- A test that asserts the current value of an unsealed field pins whatever that field happens to hold.
  When the held value is wrong, the test makes the defect the contract.
- None of this excludes an external actor, and none of it makes a runtime effect exactly-once.

The normative contract is
[§ HH](../../DEVELOPMENT_PLAN/development_plan_standards.md). This page is its canonical
explanation; individual boundaries cite it instead of re-deriving the method.

## Why this page exists

The repository has applied this method at nearly every boundary it has built — and had never stated it.
It appeared as local prose at each site (`AbsExe` "makes a bare command name unrepresentable", readiness
"forged readiness … is unrepresentable at the new boundary", the opaque `StepPlan`, the private
`CanonicalProjectRoot`), and was grounded normatively only in § EE, which is scoped to capabilities and
lifecycle-state tokens, and § CC, which is scoped to readiness.

The cost of having no general statement is not stylistic. Each new boundary re-derived the method from
whichever neighbour its author happened to read, and a boundary nobody thought to seal simply had none.
The host-daemon launch was that boundary: a plain `CreateProcess` record assembled at a call site, with
a stdio disposition that closed the child's descriptors. Every gate passed. One of them asserted the
defect.

## The method

### Private constructor, validating smart producer

The constructor is absent from every exposed module — including any module merely *named* `Internal`.
The producer validates and is the only way in.

`HostBootstrap.HostTool.AbsExe` is the smallest worked example: `mkAbsExe` rejects a non-absolute path,
so a bare command name is not an `AbsExe`, and § K's doctrine holds by construction rather than by
review. `HostBootstrap.Step.ProjectStepId`, `HostBootstrap.Readiness.PollPolicy`, and
`HostBootstrap.Lifecycle.Prepared.PreparedGate` are the same shape at increasing stakes — the last of
these can exist only after durable Unknown is recorded. A local root route mints it directly after the CAS;
a storeless `FrameExecutor` may reify the same gate only through a hidden allow-listed mint after exact
comparison of the root-signed prepared response's node/dependencies/operation-gate/projected-gates packages
with its local `ExecutionNode` and durable coordinates.

The root's own `PreparedNodeGrant` is the same idea one level up, and it is built. It carries the authorized
node, that node's ordered dependencies, and the two gate packages — and no request, response, store, session,
record key, or compare-and-swap operation, so its evidence fold discloses what a frame may
do without disclosing how the root recorded it. Its producer cannot reach the constructor until every exact
durable unknown row is published and strictly read back, the node's own first and then each projected
operation in the catalog's order, so a partially prepared node yields no grant rather than a grant claiming
more than was prepared. The live endpoint renders and signs `Prepared` only from that post-publication evidence;
`Descend` and `Refused` are
different response families with no constructor on that path, which is why "the root told me to descend"
cannot be mistaken for "the root authorized this effect". The grant carries gate *packages* rather than
`PreparedGate` values, so it mints nothing and the hidden mint allowlist is unchanged.

The owner that prepares and settles reaches a frame session only through that session's fixed-unit coordinate
fold. It never receives the session's record key, version, or row bytes, so advancing or rewriting a session
is not something it declines to do — it is something it has no term to express. Every durable row it writes
is one it derived a key for itself, and settlement's row carries the session ordinal in its key, so settling
one node twice at one ordinal converges on the record already present while two ordinals address two rows.

### Rank-2 continuation

Some values are only meaningful inside the scope that authorized them. A rank-2 bracket binds a fresh
type variable the caller cannot instantiate, so the value cannot outlive its bracket.

`withProtectedEntry`, `withCanonicalProjectRoot`, `withInstalledProjectIdentity`, and the composite
Production/Harness root brackets all do this. It is what makes "this handle belongs to the entry,
root, installed binary, or broker generation that opened it" a type error rather than a comment.

### Closed sum, total eliminator

An outcome set is a closed sum, and it is consumed by an eliminator with no wildcard. Adding a case is
then a compile error at every site that must decide about it.

`CaseResult`'s three eliminators are documented for exactly this reason: they are total "so adding an
outcome cannot silently be counted as success". `TeardownOutcome`, `ReconcileError`, and
`DaemonEvent` are the same shape. A wildcard in an eliminator is the defect this technique exists to
prevent — it silently absorbs the case nobody considered.

### Phantom indices

A `scope`, `planId`, `runId`, or `resource` index costs nothing at runtime and makes cross-plan,
cross-scope, and cross-resource mixing a type error only when the carrier's role is nominal. GHC otherwise
permits `coerce` across a phantom or representational parameter even when the constructor is hidden.
`LifecycleProfile (Production projectId)` versus
`LifecycleProfile (Harness projectId runId)` is the load-bearing instance: a test component has no
route to a Production profile because there is no term of that type it can reach.

`LifecycleCursor scope planId frame brokerGeneration verb phase` is the six-index durable instance.
Every role is nominal, its constructor is hidden, and its only public producer consumes the matching
`AcquisitionJournal` plus `ProjectFrame`. The public successor surface contains only
`Prepare -> Execute -> Teardown`; there is no function whose input can skip Execute, change the verb,
advance Teardown, or reinterpret one frame/broker/plan cursor as another. Existential recovery does not
weaken that relation: `withCurrentLifecycleCursor` quantifies the phase itself and delivers the matching
phase witness and cursor together.

`ReverseRootIntent projectId sourceBrokerGeneration verb` is the durable reverse-root instance. All three
roles are nominal, its constructor is module-private, and its closed GADT has exactly Pending and Committed
cases for Down and Destroy. There is no Up case and, at the current substrate boundary, deliberately no
producer, transition, repair, deletion, accessor, recovery facade, or testing seam. Its strict versioned
length-framed codec and stable per-Production-project key are used only by the internal refusal guard;
ordinary snapshot, allocation, migration, Harness, profile-slot, and terminal-mutation funnels fail closed
when that key is present. The hidden-token Session source-record eliminator exposes exact canonical
Up/Teardown acquisition and cursor coordinates only to a package-admitted callback. Generic acquisition and
cursor open/reopen remain lower non-authorizing primitives, not a route to reverse authority.

The reconciliation boundary applies the same rule exhaustively. `StepExecution`, `StepRuntime`, and
`ResourceCarrier` make both `scope` and `planId` nominal; `ResourceHandle` makes scope, plan, resource
identity/kind, ownership, and phase nominal; and the receipt, adoption, dependency, prepared-operation,
result, journal-proof, and phase-transition families make every identity or typestate parameter nominal.
Thus an equal runtime representation cannot turn a foreign observation into managed ownership, pair the
halves of different preparations, or relabel one plan's carried resource as another's.

The interpreter-carried `PlannedStepObservation scope planId configId` likewise makes all three roles
nominal. The backend-facing `StepObservation` remains deliberately plan-independent and non-authorizing;
the public plan facade wraps it before Chain classifies or settles it. This proves scope, plan, and
configuration continuity, not a separate node identity: exact Chain supplies the matching planned node and
descriptor at the call site, while the wrapper itself has no node index.

Indices are only as strong as the values that carry them. An index on a type whose every accessor
returns plain `Text` is documentation, not enforcement — worth writing when a future consumer will
need the pairing checked, but it should be described as such until then.

### Project-plan absence guards

The [step-algebra-and-project-plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)
mechanically guards the project-plan boundary. Its scope is exact and intentionally narrower than the
behavior of every consumer:

- of the snapshot family, the public pure `HostBootstrap.ProjectPlan` facade exposes only
  non-authorizing `StablePlanSnapshot`; public snapshot evidence lives in
  `HostBootstrap.ProjectPlan.Snapshot`, while indexed construction and the canonical encoder remain behind
  the representation boundary;
- the current production-source import allowlist for `HostBootstrap.Lifecycle.Plan` is
  `HostBootstrap.ProjectPlan`, `HostBootstrap.ProjectPlan.Construct`, `HostBootstrap.ProjectPlan.Frame`,
  `HostBootstrap.ProjectPlan.Snapshot`, `HostBootstrap.Authority.ProjectPlan`, and
  `HostBootstrap.Lifecycle.Mode`, plus the audited transitional consumers
  `HostBootstrap.Lifecycle.Session` and `HostBootstrap.Reconcile`; the lexical guard pins that exact set,
  rejects any additional production importer, and keeps full Lift out of every plan-kernel importer;
- every Cabal-exposed module has an explicit lexically parsed export list. None exposes the indexed snapshot,
  canonical encoder, hidden kernel, or a `PlannedResource` constructor, and the plan facade is the sole public
  exporter of the plan-owned resource/edge projection routes;
- the command-admission source guard counts only the Production fresh-or-recovered plan admission. The
  [test-harness-and-run-ownership
  phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md) owns Harness command adoption and
  the assertion-only `TestSuite` boundary; and
- generic `ResourceEnvelope` remains descriptive input to exact generic Budget admission. Proof that the
  demo envelope comes from its exact configuration, workload, overhead, partition, and slices remains
  with the [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md)'s concrete workload and slice
  projection.

Dated closure evidence remains in the
[step-algebra-and-project-plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)
rather than being duplicated on this architecture page.

## The proof obligation

A boundary that claims a shape cannot be constructed ships a compile-fail fixture under
`core/hostbootstrap-core/test/compile-fail/`, registered in `CompileFailSpec`.

Worked examples: `ForgeStepExecution.hs` (a project cannot fabricate a plan-minted descriptor),
`CoerceExecutionRoles.hs`, `CoerceResourceHandleRoles.hs`, `CoerceReconcilePlanRoles.hs`, and
`CoerceReconcileEvidenceRoles.hs` (opaque indices cannot be representation-coerced),
`CoercePlannedStepObservationRoles.hs` (an interpreter-carried observation cannot be relabelled across
scope, plan, or configuration), `CrossAuthorityChain.hs` and `CrossCursorChain.hs` (an exact Chain entry
cannot substitute foreign command evidence),
`ForgePreparedGate.hs` (nor a prepare gate, nor reach one by record update), `ForgeTeardownForest.hs`
(nor a teardown forest, nor substitute one verb's projection for another's), and
`ForgeProviderWallSettlementPermit.hs` / `ImportBudgetInternal.hs` /
`ImportColimaSettlementInternal.hs` (nor turn a descriptive wall observation into live authority or import
either the provider-neutral mint or owning adapter bridge), and `ForgePreparedProviderStart.hs` /
`ImportProviderStartInternal.hs` (nor manufacture or complete the journal-bound provider start).
`CallerFenceProviderWallReservation.hs` and `CrossPartitionProviderWallReservation.hs` pin the related
pre-call rules: a wall, partition, and caller-chosen positive number are not a journal reservation, and a
reservation from another constructive partition cannot enter the call.

Two rules make a fixture worth having:

1. **It must fail for the named reason.** `rejectsWith` pins the expected diagnostic. A fixture that
   merely fails to compile proves nothing — a typo would satisfy it.
2. **The expectation must not be satisfiable by an unrelated error.** Splitting an expected diagnostic
   into separately-matched tokens is the common way to get this wrong: an unrelated in-scope error on
   the same source line can satisfy each token independently. Keep the expectation one contiguous
   phrase; the matcher collapses whitespace so compiler line-wrapping does not break it.

## Tests that pin a defect

This is the failure mode the method is meant to remove, and the one that hides longest.

A test asserting the current value of an unsealed field cannot distinguish "this is the right value"
from "this is the value that happens to be there". If the held value is wrong, the assertion promotes
the defect to a contract, and every gate then agrees with it — which is indistinguishable, from the
outside, from the boundary holding.

The host-daemon launch carried exactly such a test: three assertions that its stdio disposition equalled
the one that closed the child's descriptors. It was green for as long as the defect existed.

Prefer an assertion that the lawful shape **does the lawful thing**. A child launched through a sealed
boundary can be observed to have an open standard input at EOF and both output streams reaching one
place; no unlawful disposition passes that test, so it fails when the boundary is missing instead of
certifying its absence.

## What this does not buy

Stating the limits is part of the contract, not a caveat appended to it.

- **It does not exclude an external actor.** Hidden constructors exclude construction by cooperating
  code in this repository. A same-privilege process outside it is unaffected, and
  [ownership_invariant.md](ownership_invariant.md) is explicit that no substrate supplies that
  exclusion.
- **It does not bind a caller who reaches past the boundary.** Sealing a module does not remove the
  underlying package from the build plan. Keeping a surface sealed is a drift-guard obligation, owned
  by the [composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md),
  not a property the type system maintains on its own.
- **It does not make a runtime effect exactly-once.** § EE states the limit directly: no plan may claim
  compile-time exactly-once effects from phantom types alone. Ordinary Haskell values are not linear;
  "consumed" is an interpreter invariant enforced by a journal, and the type only prevents forging the
  token. The lifecycle cursor demonstrates the distinction: one protected CAS reserves each transition
  at most once, but its callback runs after unlock and is deliberately at-least-once. Recovery or a
  callback exception may redeliver the same durable phase; backend exactly-once behavior still requires
  its own journal/fence/idempotence contract.
- **It does not make an unsound design sound.** A closed sum over the wrong domain is still wrong.
  Totality guarantees every case is *considered*, not that the cases are the right ones.

## Current boundaries

| Boundary | Sealed value | Fixture |
|---|---|---|
| Host-tool resolution (§ K) | `AbsExe` | — (smart constructor, `HostToolSpec`) |
| Owned-object vocabulary (§ EE) | `ObjectIdentity`, `PayloadDigest`, `OriginRecord` — the kernel answers the identity, the digest is computed from the payload a run intends to install, and the record has no updatable field, so its binding cannot be replaced | `ForgeObjectIdentity.hs`, `ForgeOwnershipPayloadDigest.hs`, `ForgeOwnershipOriginRecord.hs`, `RebindOwnershipOriginRecord.hs` |
| The four clause tokens (§ EE) | `Entered`, `Recorded`, `Bound`, `Releasable` — each minted by a clause actually being held, each indexed nominally by the protected entry that authorized it and by the object it names, with the entry index the protected session's own rank-2 variable so a token cannot outlive its entry | `ForgeOwnershipEntered.hs`, `ForgeOwnershipRecorded.hs`, `ForgeOwnershipBound.hs`, `ForgeOwnershipReleasable.hs`, `CoerceOwnershipClauseSession.hs`, `CoerceOwnershipClauseObject.hs`, `EscapeOwnershipClauseEntry.hs`, `ImportOwnershipInternal.hs` |
| Readiness (§ CC) | `Ready`, `Probe`, `PollPolicy` | `RawReadiness.hs` |
| Capabilities and lifecycle state (§ EE) | `PreparedGate`, ownership receipts, `RunLease` | `ForgePreparedGate.hs`, `ForgeRunLease.hs` |
| Provider-wall admission and settlement (§ EE) | journal-derived `ProviderWallReservation`; nominal backend-produced `ProviderWallSettlementPermit`; journal-bound provider start completed only by a hidden owning adapter | `CallerFenceProviderWallReservation.hs`, `CrossPartitionProviderWallReservation.hs`, `ForgeProviderWallSettlementPermit.hs`, `RawObservationProviderWallSettlement.hs`, `ImportBudgetInternal.hs`, `ImportColimaSettlementInternal.hs`, `ForgePreparedProviderStart.hs`, `ImportProviderStartInternal.hs`, `CoerceProviderWallSettlementPermitRoles.hs`, `CoercePreparedProviderStartRoles.hs` |
| Exact direct-Colima ownership (§ EE/§ HH) | opaque `PreparedColimaWallCall`, backend-minted `ColimaWallObservation`, `LiveColimaWall`, `ColimaCleanupAuthority`, and journal-bound `PreparedColimaCleanupCall`; private resolver/backend/settlement constructors and mutation arguments | `CrossPlanColimaConsumer.hs`, `ForgeColimaAuthorities.hs`, `CoerceColimaAuthorityRoles.hs`, `ImportColimaBackendInternal.hs`, `ImportColimaResolverOverride.hs`, `ImportColimaResolverTesting.hs`, `ImportColimaResolverInstall.hs`, `ImportColimaSettlementInternal.hs`, `OpenColimaOwnershipBackend.hs`, `OpenPreparedColimaMutationArgs.hs`, `ColimaAcquireCallAsCleanupGate.hs`, `WrongColimaCleanupPhase.hs` |
| Installed and broker identity (§ X) | `InstalledProjectIdentity`, `BrokerEpoch` | `EscapeInstalledProjectIdentity.hs`, `ForgeInstalledProjectIdentity.hs`, `CoerceInstalledProjectIdentity.hs`, `CoerceBrokerEpoch.hs` |
| Root authority (§ X) | `RootInvocationAuthority`, `RootScopeAuthority`; no public root or recorded-epoch opener | `ForgeCommandAuthority.hs`, `CrossRootScopeAuthority.hs`, `ForgeRootScopeAuthority.hs`, `OpenRootInvocationAuthority.hs`, `OpenRecordedBrokerEpoch.hs` |
| Command authority (§ X) | nominally indexed `CommandAuthority`; no generic producer in the safe authority facade | `ForgeCommandAuthority.hs`, `CrossScopeCommandAuthority.hs`, `CrossPlanCommandAuthority.hs`, `CrossFrameCommandAuthority.hs`, `OpenGenericCommandAuthority.hs` |
| Authority kernel package boundary (§ X) | hidden `HostBootstrap.Authority.Kernel` | `ImportAuthorityKernel.hs` |
| Plan-bound acquisition and frame cursor (§ W/§ EE) | hidden-constructor `AcquisitionJournal`; six-role nominal `LifecycleCursor`; existential current-phase recovery; only adjacent phase successors | `ForgeLifecycleCursor.hs`, `CoerceLifecycleCursorScope.hs`, `CrossPlanLifecycleCursorOpen.hs`, `CrossFrameLifecycleCursor.hs`, `CrossBrokerLifecycleCursor.hs`, `CrossVerbLifecycleCursor.hs`, `CrossPhaseLifecycleCursor.hs`, `SkipLifecycleCursorExecute.hs`, `AdvanceTerminalLifecycleCursor.hs` |
| Durable reverse-root intent substrate (§ W/§ X/§ Y) | module-private, three-role-nominal `ReverseRootIntent`; exactly Pending/Committed Down/Destroy states; no public producer, projection, transition, repair, deletion, recovery, or test seam; ordinary snapshot, allocation, migration, Harness, profile-slot, and terminal-mutation funnels refuse its stable key, while lower acquisition/cursor open and reopen remain deliberately non-authorizing | `OpenReverseRootIntent.hs`, `ProjectPlanSpec`, `SessionSpec` |
| Durable reverse descent (§ W/§ X/§ Y/§ HH) | Cabal-hidden, eight-role-nominal `ReverseDescent` has only private Prepared and Bound constructors. Prepared retains the exact entry/work/adapter/authority package; Bound retains canonical binding bytes plus its exact durable successor, never an offer or token. Planned-token replay may reproduce the same offer for transmission, while a separate strict hidden path reauthorizes and rehydrates exact Bound state without opening the token map. Neither constructor nor retained term enters the public library surface, and full Prepared bytes are bounded before publication | `OpenReverseDescentSubstrate.hs`, `OpenPreparedRootReverseDescentProducer.hs`, `ProjectPlanSpec` |
| Sealed semantic lifecycle completion (§ W/§ X/§ Y/§ HH) | Cabal-private lower `Handoff.Completion` owns exactly five exports: the four-role-nominal `LifecycleCompletion`, three fixed-unit acknowledged producers, and its proof-only fold. Cabal-private `Handoff.TerminalReport` accepts only an exact typed rooted Up session plus coordinator-produced canonical origin bytes and renders the completed report without a store, signer, process, Chain, or command import. `Command.LifecycleEntry` is its sole origin producer and adopts the lower completion fold inside validated receipt confirmation; Process retains the other fixed forward/reverse completion call sites. Cabal-private upper `Handoff.Lifecycle` remains the child/reverse completed-report owner and imports neither lower owner. Receiver imports none of them, and no testing seam exists | `ImportHandoffCompletion.hs`, `ImportHandoffTerminalReport.hs`, `ImportHandoffLifecycle.hs`, `HandoffSpec`, `ProjectPlanSpec` |
| Root-resident lifecycle acknowledgement substrate (§ W/§ X/§ Y/§ HH) | Hidden root-parent kernels retain exact binding, challenge, full grant, report, acknowledgement, and lawful Reported→Acknowledged→Adopted successors. Exact CAS losers converge, strict readback runs under the root broker guard, and fixed callbacks expose no store, durable row, disposition, or caller-selected result. No child-side persistence claim belongs to this boundary | [the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) proof matrix |
| Keyless rooted transport (§ W/§ X/§ Y/§ HH) — **implemented** | The authenticated-handoff phase limits Relay to singleton outer fields, bounded sealed external requester-path construction, exact inner-byte preservation, strict structural request/response pairing, one outstanding request, intermediate path-suffix checks, and complete root-path equality. Only the originating typed operation verifies the signed response with the independently installed key. Outer and signed rooted refusals remain distinct uninterpreted bytes. After that structural validation the root link runs the rooted lifecycle service the recursive-lifecycle-command phase installs, whose shape is the link field's own, so the transport decides whether a request is well formed and never what it is answered with. Relay exposes no broker, store, catalog, retained session path, semantic replay/receipt decision, process owner, raw response, polymorphic result, or terminal callback, and reaches the fixed signer only through its own hidden recovery signing admission; it constructs no recursive child and claims no successful rooted process exchange | `ImportHandoffRelay.hs`, `HandoffSpec` source guards, [the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) semantic/process proof matrix |
| Rooted terminal receipt (§ W/§ X/§ Y/§ HH) — **implemented** | Only the root writes Published/Received: it retains the exact admitted offer for the matching session, produces a terminal origin only after all exact frame work settles, publishes before signed `FrameComplete`, admits fixed semantic completion inside idempotent `ReceiptConfirm`, and only then returns signed `ReceiptRecorded`. A child receives no `ProtectedStore`, raw receipt key, receipt mutation helper, completion constructor, catalog, or signer | [the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) proof matrix |
| Finalized forward-child projector (§ W/§ X/§ Y/§ HH) | Real-project construction installs exactly one scope-polymorphic projector; missing and duplicate installation refuse structurally. The hidden kernel canonically validates child configuration through the finalized codec and exposes only fixed projected plan inputs. No projector-derived bytes, root constructor, caller-polymorphic result, or runtime seam exists | `ImportProjectPlanConstructInternal.hs`, `OpenFinalizedForwardChildProjector.hs`, `CLISpec`, `ProjectPlanSpec` |
| Exact planned forward handoff (§ W/§ X/§ Y/§ HH) | Opaque `PlannedForwardHandoff` joins exact parent plan/current/context evidence to the unique immediate child edge, independently constructs the target plan and digest binding, and retains only inert binding input plus a sanitized route. It owns the lifecycle-context join alone and delegates every descriptor, context, configuration, and target-plan check to the shared immediate-target kernel. It exposes no live broker, token, selectable executable, `SelfRef`, store, cursor, process, or effect authority and has no runtime caller | `OpenPlannedForwardHandoff.hs`, `ProjectPlanSpec`, [the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) source guards |
| Shared immediate-target projection (§ W/§ X/§ Y/§ HH) — **implemented** | Cabal-hidden `withImmediateTargetKernel` is the one boundary that proves the unique immediate ancestry edge and jointly yields the projected descriptor, canonically validated child configuration, independently admitted target plan, digest binding, target current frame, exact derived child context, raw and stripped route, canonical payload, both digests, and invocation input. It introduces no type and retains no `ValidatedLifecycleContext`, canonical root, protected store, or invocation authority, which is why the exact single-edge package and the recursive catalog can share it without either borrowing the other's lifecycle evidence. Its only importers are those two hidden owners | `ImportProjectPlanProjectionInternal.hs`, `OpenImmediateTargetProjection.hs`, `ProjectPlanSpec` |
| Recursive rooted plan catalog (§ W/§ X/§ Y/§ HH) — **implemented** | Cabal-hidden, four-role-nominal `RootedPlanCatalog` is its own entry carrier: one base retaining the root's finalized specification, invocation authority, plan, current frame, and root-resident lifecycle context, plus one extension per admitted descent. Construction rechecks root residency, the supplied/retained/project frame join, the admitted context endpoint, and the authority's installed project and durable store identity before descending through the shared kernel; descent terminates at a frame with no declared edge and is bounded by the root topology's own frame count. Every entry is reachable only through rank-2 folds over the catalog, so no entry, evidence value, raw row, child-supplied plan, or nested lifecycle-context route exists. The value grants no journal, cursor, session, grant, signing, process, or protected-store operation and has no runtime caller | `ImportLifecycleRootedPlan.hs`, `OpenRootedPlanCatalog.hs`, `ProjectPlanSpec` |
| Catalog-admitted forward package (§ W/§ X/§ Y/§ HH) — **implemented** | Cabal-hidden, eight-role-nominal `CatalogForwardHandoff` exists only for an edge the recursive catalog already admitted. One rank-2 catalog fold selects by exact parent and child frame and refuses a missing, duplicated, or sibling child; it then rechecks the entry against the parent level's own retained plan, so a parent frame that is not that level's current frame, a descent the parent plan does not declare with exactly the retained raw route, or projected node keys that are not the parent plan's own all refuse before the fold. The package rechecks the admitted child against the evidence the entry retains — target-plan current frame, validated-configuration endpoint, rendered plan digest against the binding's, and configuration/payload digests against each other and against the canonical payload's own hash — and holds both routes to exactly one lift layer. It retains no lifecycle context, parent plan, or specification index, exposes only the stripped route, binding input, and canonical payload under a fixed unit result, and has no process or command call site | `OpenCatalogForwardHandoff.hs`, `ImportProjectPlanHandoffInternal.hs`, `ProjectPlanSpec`, `CLISpec` |
| Protocol-safe lifecycle process route (§ K/§ W/§ X/§ HH) — **implemented** | Cabal-hidden, seven-role-nominal `LifecycleProcessRoute` is derived from a catalog forward package or a recovery package and its plan-owned lift route, never assembled, and points only at the child a frame launches rather than at that frame's own session: the parent and child frames are the binding input's own, the phase must be the one that edge belongs to, and the lift must be exactly one plan-owned layer. One argument vector exists per provider — Docker interactive at `/`, Incus, Lima, and WSL noninteractive at `/` with noninteractive sudo where the guest's default user is not root — and the child's command is the fixed coordinate-free `--hostbootstrap-lifecycle-child` entry marker; the authenticated Offer is the sole source of its verb. The closed grammar refuses `ConfigDelivery`, container extra arguments, a container outliving its exchange, a non-absolute or delimiter-bearing path, and any derived name reading as an option, a separator, or a descriptor request, so detach, TTY, attach, standard-input, entrypoint, working-directory, and signal overrides are unrepresentable rather than filtered. The one startup step with no other owner sits beside it rather than on it: a frame's own opening admits the nested arm of that frame's `RecursiveHandoffRuntime` — a root arm speaks for no authenticated frame — builds the four-field `OpenFrame` from a fresh nonce alone, and verifies the signed answer against the installed key and those exact bytes, admitting only an `Opened` and yielding that request and that response with no decoded coordinate. No post-open request builder exists here at all: the storeless frame executor already owns the root-selected path, session, stage, ordinal, and predecessor and the closed post-open families. It names no process, descriptor, handle, store, signer, or executor and spawns nothing | `ImportHandoffProcessRoute.hs`, `RenderLifecycleProcessRouteArgv.hs`, `ProjectPlanSpec` |
| Digest-proven specification reindex (§ Q/§ BB/§ HH) — **implemented** | `ProjectCodec scope specDigest cfg` and `FinalizedServiceRegistry scope specDigest (cfg scope)` each keep a nominal specification index, so a carrier admitted under a durably recovered index and one finalized in this invocation are distinct types even when their digests are equal. Each representation lives in its own Cabal-hidden owner whose only importer is the facade that re-exports it abstractly, and each owner holds exactly one reindex kernel. A kernel consumes the digest-equality token, compares it against the digest the carrier itself retains — the registry retains the exact digest its finalization stamped, so an empty registry is checked too — and preserves every retained term: label, schema, digest, decoders, renderers, and the registry's identities, projections, declared effect rows, handlers, and role codec terms. Neither kernel reaches a public facade, mints a token, or admits a caller-selected index | `ImportConfigClassInternal.hs`, `ImportServiceInternal.hs`, `OpenProjectCodecReindex.hs`, `OpenFinalizedServiceRegistryReindex.hs`, `CoerceProjectCodecSpec.hs`, `CoerceFinalizedServiceRegistrySpec.hs`, `SpecIndexSpec` |
| Bracketed recursive process (§ HH) — **implemented owner; command adoption target** | the owner accepts only catalog-admitted planned or recovery input, constructs process/channels internally, fixes cwd and argv, isolates descriptors, and completes only after rooted semantic completion and receipt. It spawns exactly one sanitized `LifecycleProcessRoute` at the absolute path its host tool resolves to, into a new process group with private stdin/stdout pipes and inherited stderr; no caller supplies a callback, deadline, grace value, process shape, or channel, and an already opened route launches no second child. One bracket owns the descriptors, the relay lifetime, the direction's fixed completion kernel, and the reap: group TERM, fixed grace, group KILL if still present, unconditional wait, then the pipes. Its constants bound the launch and the grace only; the relay bounds the frames a peer owes immediately and leaves the admitted effect's own wait alone, so no blanket lifecycle wall-clock deadline exists. EOF, exit zero, diagnostics, and channel closure are not completion. Catchable host exits terminate and reap the host-side group; uncatchable parent death promises only pipe EOF/kernel cleanup and no guest-descendant reap | [the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) proof matrix |
| Exact validated lifecycle context (§ W/§ X/§ EE) | opaque five-role-nominal `ValidatedLifecycleContext` retains canonical root, the coordinator's already-open protected store, and root-or-nested parent-plan `CurrentFrame`, `ProjectFrame`, and `ValidatedContext`. It is root-process-resident and has no child-process eliminator; rank-2 `RootedPlanCatalog` selection structurally binds a target plan/config/current frame without a second evidence type or store authority | `ForgeValidatedLifecycleContext.hs`, `CoerceValidatedLifecycleContextRoles.hs`, `CrossValidatedLifecycleContextIndices.hs`, `EscapeValidatedLifecycleContextFrame.hs`, `OpenValidatedLifecycleContextAuthority.hs`, `ValidatedLifecycleContextAsAuthority.hs`, `ImportLifecycleContextInternal.hs` |
| Closed rooted lifecycle request codec (§ X/§ Y/§ HH) — **implemented** | One Cabal-private, non-indexed, hidden-constructor six-case sum has checked constructors, strict canonical decode/render, and one total fold. Four-field `OpenFrame` contains only a nonce; the nine-/ten-field post-open forms bound their nested path, tokens, ordinal, nonce, predecessor digest, and optional body. The exact-source gate proves single ownership and the absence of facade exposure, authority/storage imports, testing companions, and semantic/process/durable importers; only the neutral Receiver-internal path fold serves Relay transport, and it assigns no lifecycle semantics | `ImportHandoffRooted.hs`, `HandoffSpec` source guards |
| Closed rooted lifecycle response codec and authentication (§ X/§ Y/§ HH) — **implemented** | The neutral codec adds one Cabal-private, non-indexed, hidden-constructor seven-case sum as descriptive signed data, not authority. Exact nine-field `Opened` and eleven-field post-open forms have seven checked unsigned builders, one signature-attaching decoder, strict canonical decode/render, one total fold, exact request-family pairing, and 7 MiB/6 MiB total/body bounds. `Prepared` nests node/dependencies/operation-gate/projected-gates; `FrameComplete` is structurally opaque; `ReceiptRecorded` repeats the matching predecessor digest; rooted `Refused` is post-open only. The no-new-type public facade exposes only the abstract value, renderer, fixed live-broker signer over domain + installed-key digest + exact request + canonical unsigned response, and installed-key fixed CPS verifier. Its sole transport caller is Relay's originating typed operation, after the neutral Receiver-internal pair fold; no caller-supplied signature placeholder, generic signer, second capability, store, semantic successor, or semantic/process/durable importer belongs to these boundaries. The recursive-lifecycle-command phase alone assigns typed body, successor, settlement, and replay semantics | `ImportHandoffRooted.hs`, `HandoffSpec` source/ownership guards |
| Rooted plan catalog and frame executor (§ W/§ X/§ Y/§ HH) — **target** | Only the root can construct `RootedPlanCatalog`, select a catalog node and projected operation set, mutate a frame journal, or sign a rooted response. Four-field `OpenFrame` carries no path or session coordinate: its sealed external envelope is the sole ancestry and obeys the same one-to-256-component, 4,096-byte-per-component grammar as the inner post-open path; attachment failure is outer refusal. Only verified exact nine-field `Opened` discloses the admitted canonical path plus root-issued session/stage/next ordinal; it contains no digest of itself. Once the complete signed `Opened` is available, its derived digest seeds the first predecessor for the next request. Eleven-field post-open responses echo request path/session/nonce, supply successor stage/ordinal, and stay inside the exact family. Post-open inner path must equal envelope and session path before mutation. A `FrameExecutor` is storeless, exists only after that verification, and can reify prepared gates only after exact local comparison of the four nested node/dependencies/operation-gate/projected-gates packages — packages it reads out of a verified `Prepared` answer rather than accepts beside one, so a `Descend` or a signed `Refused` cannot reach the same branch. That owner is implemented and Cabal-private; the process exchange it takes part in is what remains target. Closed request/response sums, lineage/catalog/path/nonce replay identity, ordinals/nonces/predecessor digests, and strict replay prevent accidental route/key substitution; they do not claim identity against a malicious launching parent | recursive lifecycle compile-fail/source-guard matrix |
| Rooted recovery package (§ W/§ X/§ Y/§ HH) — **implemented generic receiver; catalog producer target** | Neutral `RecoveryChildPackage` canonically frames child-config plus adapter bytes but authenticates nothing by possession. `RootedPayloadBinding` commits separately to the complete package and child-config field. `withVerifiedRecoveryChildPackage` requires the exact `VerifiedHandoff`, rerenders and reverifies the supplied signed data, decodes only the authenticated payload, and recomputes both digests before exposing fields. The [authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md) owns that boundary and its generic package-aware receiver carrier, which composes no package of its own. The [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) alone constructs the catalog-selected package, admits its complete config/digest, and routes its exact Offer to the installed root signer; its reverse transport takes no payload argument, so an adapter alone is unrepresentable there | handoff/recovery negative matrix |
| Plan, descent, reverse (§ W/§ Y) | `StepPlan`, `StepExecution`, plan/config-indexed `PlannedStepObservation`, `TeardownForest` | `ForgeStepExecution.hs`, `CoercePlannedStepObservationRoles.hs`, `ForgeTeardownForest.hs` |
| Provider runtime dependency production (§ CC/§ EE/§ HH) — **implemented producer** | Only an exact prepared provider Ready call settled to its backend-indexed `Running` successor can publish the pending provider-domain package. Plan/frame/resource/origin/generation come from that exact execution and successor; separate commitments hash the complete still-pending producer gate and the action-local Ready call/observation. The canonical package cannot contain the captured strong backend or managed handle, while the separate invocation-local live registry accepts only the fixed fresh-readiness request. Exact retry converges, canonical drift refuses, and every new carrier begins empty | `ProviderBackendSpec`, `LifecycleDependencySpec`, `ImportLifecycleDependencyInternal.hs` |
| Exact carried ownership opening (§ EE/§ HH) — **implemented** | The existing private carried resource retains the already-validated ownership operation independently of optional local settlement bytes, never a receipt or managed witness. An authenticated dependency package may seed the exact resource/generation/operation without gaining settlement publication authority. Only `Reconcile` can combine key/generation/version/operation into a freshly rebound generic managed handle and matching receipt under a rank-2 continuation, and only for the current node or its exact plan dependency prefix. Missing ownership, unrelated keys, duplicate membership, empty operation, and a fresh carrier refuse before the continuation | `ReconcileSpec`, `ChainSpec`, `ResourceRecordSpec`, `RecursiveLifecycleSpec` |
| Fresh provider dependency recovery (§ CC/§ EE/§ HH) — **implemented** | A fixed successor must join the sole exact provider package, a plan-admitted provider resource, carried ownership evidence, reconstructed backend origin, unexpired route, and a live backend response. The request/response canonically bind the complete package commitment plus one bounded nonce; the service consumes the nonce once and returns only that commitment, nonce, and freshly observed generation. Only their full agreement constructs a backend-indexed managed provider and exposes `RunningProviderDependency` under a rank-2 continuation; neither canonical bytes nor reachability alone can mint it | `ProviderBackendSpec`, `LifecycleDependencySpec`, `EscapeFreshRunningProviderDependency.hs` |
| Cluster runtime dependency production and recovery (§ CC/§ EE/§ HH) — **implemented** | Only an applied exact cordon plus a freshly reprobed settled readiness witness can register the cluster-domain package and separate live service. Canonical bytes bind plan, scope, cluster resource/frame, closed backend origin, managed generation, pending producer gate, ready settlement, route, and expiry but contain none of the captured backend, cordon, readiness, probe, receipt, or writer. The opener requires the sole exact package and every successor-visible coordinate, consumes a nonce-bound fresh service observation, and asks `Cluster.Reconcile` to settle another fresh observation inside the continuation; package presence or a carried ready version alone yields nothing | `ClusterBackendSpec`, `LifecycleDependencySpec`, `ImportLifecycleDependencyInternal.hs` |
| Exact current-frame Chain (§ W/§ X/§ EE) | one `ProjectPlan` plus matching execute-phase `CommandAuthority` and `LifecycleCursor`; nominal observation flow | `CrossAuthorityChain.hs`, `CrossCursorChain.hs`, `CoercePlannedStepObservationRoles.hs` |
| Production command plan continuity (§ W/§ X/§ Y) | one retained or fixed-identity reconstructed `ProjectPlan` across render/persist, the hidden fixed root-Up entry, lower Chain, and current-frame reverse work; only that entry derives journal/cursor/authority and no plan-only alternate producer exists | `CLISpec`, `AuthoritySpec`, `ChainSpec`, `TeardownSpec` |
| Exact current-frame reverse projection (§ W/§ Y) | nominal `TeardownPlan scope planId frame verb`, produced only from the matching `ProjectPlan` and `CurrentFrame`; projection-only opening retains `frame` through forest/progress/authorization/work/completion/`SubtreeSettled` | `CrossPlanCurrentFrameTeardown.hs`, `CrossFrameTeardownPlan.hs`, `CoerceTeardownPlanFrame.hs`, `CrossFrameTeardownPipeline.hs`, `CoerceTeardownFrameRoles.hs`, `LifecyclePlanAsTeardownPlanSource.hs`, `CallerFrameNameTeardown.hs`, `DuplicateCurrentFrameTeardown.hs`, `OpenTeardownForestWithLifecyclePlan.hs`, `OpenTeardownForestWithCurrentFrame.hs`, `ForgeTeardownPlan.hs`, `ForgeInitialTeardownForest.hs`, `ForgeTeardownForest.hs` |
| Canonical reverse verb (§ X/§ Y) | the same nominal `ProjectVerb verb` admitted by the command boundary is retained through teardown plan, forest, work, completion, recursive argv, and cluster action selection; no local teardown-verb universe or caller text exists | `ImportLegacyTeardownVerb.hs`, `CoerceProjectVerb.hs`, `CrossVerbTeardownWork.hs`, `ProjectUpCannotVerifyDestroy.hs`, `CallerTextAsProjectVerb.hs` |
| Recursive teardown work classification (§ X/§ Y) | hidden-constructor nominal `TeardownWork`, `LocalWork`, and existential-child `DescentWork`; only local work exposes execution, descent exposes only the exact immediate edge, and the driver has no generic point-effect callback | `ForgeTeardownWork.hs`, `LocalWorkAsDescentWork.hs`, `DescentWorkAsLocalRunner.hs`, `CrossFrameLocalWork.hs`, `CrossFrameDescentWork.hs`, `EscapeDescentChildFrame.hs`, `CoerceTeardownWorkRoles.hs`, `OpenTeardownWorkAgainstForeignForest.hs`, `GenericPointTeardownDriver.hs`, `ImportFormerTeardownCursor.hs`, `ImportDirectTeardownAdvance.hs`, `ImportTeardownPlanNodeProjections.hs` |
| Frame-bound subtree settlement and root destroy (§ X/§ Y) | nominal hidden-constructor `SubtreeSettled scope planId frame verb` retains the exact ordered terminal observations; descent accepts only its existential child's matching proof; unframed `DestroySettled scope planId` requires the exact plan/current-frame package and unique topology root | `ForgeSubtreeSettlement.hs`, `CoerceSubtreeSettlementRoles.hs`, `CrossSubtreeDescentSettlement.hs`, `CrossFrameTeardownPipeline.hs`, `ProjectUpCannotVerifyDestroy.hs`, `DownCannotVerifyDestroy.hs`, `SubtreeAsDestroySettled.hs`, `SubtreeAsDestroyClosure.hs`, `FramedDestroySettled.hs`, `LegacyRootDestroyVerifier.hs`, `ImportDirectTeardownAdvance.hs` |
| Process launch (§ HH) | `DetachedLaunch`, `DetachedChild`, `DetachedWorkingDirectory`, `DetachedOutputSink` | `ForgeDetachedLaunch.hs`, `RelabelDetachedLaunch.hs` |
| Authenticated recursive teardown entry (§ X/§ Y) — **target** | the exact child-entry wire consumed only with the implemented plan-bound `DescentWork` edge | `ForgeTeardownDescent.hs` |

The direct-Colima row is an implemented, gate-closed source boundary owned by the
[cluster-lifecycle, budgets, and cordoning
phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md). Its Cabal-private resolver
testing seam exposes descriptive views and a non-nestable, thread-local, bracket-cleared fixture execution
override. Every adapter discovery and revalidation still runs strict fixture-root parsing and opaque resolver
settlement; the seam exports no trusted-toolchain/backend-result constructor and is absent from the public
library surface, so downstream code cannot use it to mint any value in the sealed column. Production
recursive adoption remains open in the
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md), and demo
adoption remains open in the [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md).

The exact Production command retains or reconstructs one plan identity and has no second command-authority,
forward-interpreter, descriptor, or reverse-plan entry. That absence does not make pure reverse work into
authority: `down`/`destroy` exact authorization remains part of the recursive boundary, and a nested
lifecycle invocation currently refuses before effects.

The exact plan-projection and work-classification prefix is implemented: one plan plus its admitted current
frame produces the four-index `TeardownPlan`, while the opener accepts that projection alone. The forest,
authorization branches, hidden local/descent work, every successor and completion, and `SubtreeSettled`
retain the same nominal opening frame. `DestroySettled` is unframed and root-only. Only `LocalWork` exposes the retained reverse callback;
existential-child `DescentWork` exposes only the exact immediate topology edge, and branch-specific attempts
retain their originating forest; only the exact child subtree proof advances descent. The remaining
**target contract** is authenticated child entry. That suffix is owned by
[the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
and its wire by [the authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md).
Phase status is tracked in [the development plan](../../DEVELOPMENT_PLAN/README.md); this page does not
duplicate it.

## The teardown descent boundary — target

This target starts from the already implemented `TeardownPlan scope planId frame verb` and closed
`TeardownWork` classification; it does not derive or accept another `CurrentFrame`. That existing index
reaches every forest and work state. What remains is to authenticate entry along the exact `DescentWork`
parent/child edge and bind settlement to the resulting child completion.

A recursive verb reaches two states that look alike and are not. An **operator** types
`project destroy` at the topology root. A **parent frame** invokes the same verb inside its child during
a child-first unwind. One command class asked to mean both is a convention: it either admits the nested
form to an operator, or refuses the descent its own architecture requires.

The two states therefore get two types. The operator entry validates at the root and nowhere else. The
descent entry is admitted only by verifying the recovery wire its parent minted from the forest's own
authorization point — so its discriminator is an authenticated value on a private channel, not a flag,
an environment variable, or an `argv` position. There is no constructor for it without that wire, which
is what `ForgeTeardownDescent.hs` pins.

Alongside it, whether an offered node belongs to this frame is already a closed sum with a total eliminator,
not a comparison of frame names. The local reverse runner accepts only `LocalWork`; `DescentWork` exposes
only the exact immediate parent/child edge, and the driver itself accepts separate branch handlers. The
existing nominal `frame` phantom prevents mixing forests, successors, work, or settlement from different
openings; `CrossFrameTeardownPipeline.hs`, `CoerceTeardownFrameRoles.hs`, and the work-specific fixtures pin
that foundation.

`ForgeTeardownDescent.hs` remains the § HH proof obligation for the still-target descent entry. Until it
exists and fails for its named reason, that part of this section describes an intent rather than a boundary.

## The process-launch boundary

`HostBootstrap.Detached` is the worked example of this page applied to a boundary that had none.

A child that outlives its launcher has exactly one lawful stdio disposition, descriptor-inheritance
setting, session, environment, and working directory, so none of those is a parameter. `DetachedLaunch`
hides its record constructor **and every field accessor** — the second half matters, because an exported
accessor still admits record update, which would let a caller re-point a launch it was handed.
`withDetachedChild` is a rank-2 bracket over the *launch*, not the child's lifetime: on exit the child is
still running and only the launcher's own handles have been released, so the acquire is total (it either
succeeds or returns a typed `DetachedLaunchError` having created no child) while the body's exceptions
propagate unchanged.

The lawful disposition is `UseHandle` throughout. Standard input is the host's null device, so the child
sees an open descriptor already at EOF; both output streams share one handle, so the child's own output is
retained where the launcher can quote it and a startup failure names its cause (§ CC) instead of
collapsing to "the process is gone".

It closed on a live run, not only on its static gate. The Apple Silicon lane had reported `0/10` against
this exact defect; re-run against the sealed boundary on 2026-08-03 it reported `10/10 passed`, with the
daemon reaching readiness on every bring-up and the browser case asserting real daemon-computed work.
That is the strongest available evidence that the sealed shape is the *lawful* one and not merely a
different one.

Its gate is the shape this page argues for. `DetachedSpec` launches a real child — this test executable
re-invoked through a probe argv — and observes that the child read its standard input to EOF, that both
its output streams reached the retained sink, and that it kept writing after the bracket returned. No
unlawful disposition passes that: `NoStream` closes the descriptor so the read raises, `Inherit` sends the
output to the test runner instead of the sink, and `CreatePipe` does not typecheck because the disposition
is not a parameter. A textual drift check additionally proves that no production module outside the
boundary so much as names `NoStream`.
