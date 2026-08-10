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
these can only exist if the durable compare-and-swap that mints it actually landed.

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
(nor a teardown forest, nor substitute one verb's projection for another's).

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
| Readiness (§ CC) | `Ready`, `Probe`, `PollPolicy` | `RawReadiness.hs` |
| Capabilities and lifecycle state (§ EE) | `PreparedGate`, ownership receipts, `RunLease` | `ForgePreparedGate.hs`, `ForgeRunLease.hs` |
| Installed and broker identity (§ X) | `InstalledProjectIdentity`, `BrokerEpoch` | `EscapeInstalledProjectIdentity.hs`, `ForgeInstalledProjectIdentity.hs`, `CoerceInstalledProjectIdentity.hs`, `CoerceBrokerEpoch.hs` |
| Root authority (§ X) | `RootInvocationAuthority`, `RootScopeAuthority`; no public root or recorded-epoch opener | `ForgeCommandAuthority.hs`, `CrossRootScopeAuthority.hs`, `ForgeRootScopeAuthority.hs`, `OpenRootInvocationAuthority.hs`, `OpenRecordedBrokerEpoch.hs` |
| Command authority (§ X) | nominally indexed `CommandAuthority`; no generic producer in the safe authority facade | `ForgeCommandAuthority.hs`, `CrossScopeCommandAuthority.hs`, `CrossPlanCommandAuthority.hs`, `CrossFrameCommandAuthority.hs`, `OpenGenericCommandAuthority.hs` |
| Authority kernel package boundary (§ X) | hidden `HostBootstrap.Authority.Kernel` | `ImportAuthorityKernel.hs` |
| Plan-bound acquisition and frame cursor (§ W/§ EE) | hidden-constructor `AcquisitionJournal`; six-role nominal `LifecycleCursor`; existential current-phase recovery; only adjacent phase successors | `ForgeLifecycleCursor.hs`, `CoerceLifecycleCursorScope.hs`, `CrossPlanLifecycleCursorOpen.hs`, `CrossFrameLifecycleCursor.hs`, `CrossBrokerLifecycleCursor.hs`, `CrossVerbLifecycleCursor.hs`, `CrossPhaseLifecycleCursor.hs`, `SkipLifecycleCursorExecute.hs`, `AdvanceTerminalLifecycleCursor.hs` |
| Plan, descent, reverse (§ W/§ Y) | `StepPlan`, `StepExecution`, plan/config-indexed `PlannedStepObservation`, `TeardownForest` | `ForgeStepExecution.hs`, `CoercePlannedStepObservationRoles.hs`, `ForgeTeardownForest.hs` |
| Exact current-frame Chain (§ W/§ X/§ EE) | one `ProjectPlan` plus matching execute-phase `CommandAuthority` and `LifecycleCursor`; nominal observation flow | `CrossAuthorityChain.hs`, `CrossCursorChain.hs`, `CoercePlannedStepObservationRoles.hs` |
| Production command plan continuity (§ W/§ X/§ Y) | one retained or fixed-identity reconstructed `ProjectPlan` across render/persist/journal/cursor/authorize/Chain/current-frame reverse work; no plan-only alternate producer | `CLISpec`, `AuthoritySpec`, `ChainSpec`, `TeardownSpec` |
| Exact current-frame reverse projection (§ W/§ Y) | nominal `TeardownPlan scope planId frame verb`, produced only from the matching `ProjectPlan` and `CurrentFrame`; projection-only forest opening | `CrossPlanCurrentFrameTeardown.hs`, `CrossFrameTeardownPlan.hs`, `CoerceTeardownPlanFrame.hs`, `LifecyclePlanAsTeardownPlanSource.hs`, `CallerFrameNameTeardown.hs`, `DuplicateCurrentFrameTeardown.hs`, `OpenTeardownForestWithLifecyclePlan.hs`, `OpenTeardownForestWithCurrentFrame.hs`, `ForgeTeardownPlan.hs`, `ForgeInitialTeardownForest.hs` |
| Process launch (§ HH) | `DetachedLaunch`, `DetachedChild`, `DetachedWorkingDirectory`, `DetachedOutputSink` | `ForgeDetachedLaunch.hs`, `RelabelDetachedLaunch.hs` |
| Recursive teardown frame and descent (§ X/§ Y) — **target** | propagation of the existing frame phantom through forest/progress/authorization/cursor/completion, the local\/foreign cursor sum, and the descent entry | `CrossFrameTeardownCursor.hs`, `ForgeTeardownDescent.hs` |

The exact Production command retains or reconstructs one plan identity and has no second command-authority,
forward-interpreter, descriptor, or reverse-plan entry. That absence does not make pure reverse work into
authority: `down`/`destroy` exact authorization remains part of the recursive boundary, and a nested
lifecycle invocation currently refuses before effects.

The exact plan-projection prefix is implemented: one plan plus its admitted current frame produces the
four-index `TeardownPlan`, while the opener accepts that projection alone. The last row is the remaining
**target contract**: the forest and every successor value are still unframed, and no closed local/foreign
cursor or authenticated descent entry exists yet. That suffix is owned by
[the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
and its wire by [the authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md).
Phase status is tracked in [the development plan](../../DEVELOPMENT_PLAN/README.md); this page does not
duplicate it.

## The teardown descent boundary — target

This target starts from the already implemented `TeardownPlan scope planId frame verb`; it does not
derive or accept another `CurrentFrame`. What remains is to carry that existing index into every forest
state and to authorize its local and descendant branches.

A recursive verb reaches two states that look alike and are not. An **operator** types
`project destroy` at the topology root. A **parent frame** invokes the same verb inside its child during
a child-first unwind. One command class asked to mean both is a convention: it either admits the nested
form to an operator, or refuses the descent its own architecture requires.

The two states therefore get two types. The operator entry validates at the root and nowhere else. The
descent entry is admitted only by verifying the recovery wire its parent minted from the forest's own
authorization point — so its discriminator is an authenticated value on a private channel, not a flag,
an environment variable, or an `argv` position. There is no constructor for it without that wire, which
is what `ForgeTeardownDescent.hs` pins.

Alongside it, whether an offered node belongs to this frame stops being a comparison of frame names and
becomes a closed sum with a total eliminator: the local reverse runner accepts only a local cursor, and a
foreign cursor's sole continuation is the descent. The `frame` phantom is what makes the two
distinguishable, and `CrossFrameTeardownCursor.hs` pins that one frame's cursor is not another's.

Both fixtures are the § HH proof obligation for the claims in this section. Until they exist and fail for
their named reasons, the section describes an intent rather than a boundary.

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
