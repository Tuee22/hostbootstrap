# Phase 11 — Prepared operations and preconditions

**Status**: Active
**Depends on**: Phase 10 (versioned sessions, the project journal, and durable fences)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-06 ; arm64 macOS 26.6.2 (build 25G83), GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --ghc-options=-Werror` ; pass ; covers in-gate

> **Purpose**: Make every external effect require a value whose only lawful origin is one protected
> compare-and-swap taken immediately before it, over freshly re-probed evidence.

## Phase Objective

This is the gate every reservation, mutation, and delete passes through. An adapter does not accept a request;
it accepts a `PreparedOperation` paired with the `PreparedPreconditions` minted with it, and the pair records
the exact target identity, generation, operation key, precondition set, call digest, session, fence, attempt,
and journal version. Anything stale, replaced, or not-ready yields no pair at all.

The point is not extra checking. It is that a caller has no way to *express* an effect without the pair, so
"the preconditions were verified before the call" is a fact about the type rather than a discipline.

## Sprints

### Sprint 11.1: The prepared gate [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared/Internal.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`, `core/hostbootstrap-core/test/PrepareFixture.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

One unforgeable gate whose every producer proves the same durable unknown-phase compare-and-swap origin. The
routed mint site in `Lifecycle.FrameExecutor`, and moving `recordDurableUnknown` out of the exposed
`HostBootstrap.Lifecycle.Prepared`, edit files the recursive lifecycle command phase introduces (Phase 17), so
Sprint 17.72 owns them.

#### Deliverables

- `PreparedGate` is opaque: its constructor and `mintPreparedGate` live in the package-private
  `HostBootstrap.Lifecycle.Prepared.Internal`.
- The local producer is `withPreparedGate` in `Lifecycle/Session.hs`. Inside one protected entry it checks the
  open project permit, the open session, the operation's registration, the live fence, and the recorded phase,
  publishes the operation's unknown phase through `runTransaction` on the record `operationKeyFor` derives from
  the plan digest, session, and operation key, re-reads the committed record, and only then mints the gate from
  that record's version. So the record that an attempt *may* have happened always precedes the attempt.
- A routed reifier is lawful only as an allowlisted hidden consumer of an authenticated exact response that
  proves that same root compare-and-swap and all of the gate's coordinates. Transport receipt, a caller's
  assertion, or constructor access without that proof cannot mint a gate.
- The gate carries the attempt number and journal version, so `withPreparedOperation` reads them off it rather
  than accepting two integers a caller could mismatch.
- A gate recorded under another plan digest or another operation key is refused.
- The consumed journal version cannot authorize a second prepare or a close.
- The durable phase record is UTF-8, tab-separated, newline-free: a field that would introduce a separator or
  lose a character is refused before any write, so the bytes on disk decode back to exactly the fields
  written.

#### Validation

`SessionSpec` covers the local mint and its refusals: "a prepare records the unknown phase before the adapter
runs", "the consumed journal version cannot acknowledge twice", "a settled operation cannot be prepared
again", "a terminal operation receives no effect authority", "a prepare against a superseded fence is
refused", "an unregistered operation cannot prepare", "a stale project permit cannot drive a prepare", and "a
terminally closed project refuses every prepare". `ReconcileSpec` covers "a gate recorded for another
operation cannot prepare this one" and "a gate recorded in another plan's journal cannot prepare".
`CompileFailSpec` `ForgePreparedGate.hs` rejects constructor use. `ProjectPlanSpec` pins the `mintPreparedGate`
call sites to `Lifecycle.Session`, `Lifecycle.FrameExecutor`, and the two `Prepared` modules.

The sprint closes when a `SessionSpec` case exists and passes under `cabal test all` from `core/` in which
`withPreparedGate` given an unknown phase containing a tab, and one containing a character above U+00FF,
refuses with a `SessionError` and leaves the operation record at its prior version.

#### Remaining Work

- Rewrite the Haddocks that call `recordDurableUnknown` the sole producer: the module header and function
  Haddock in `Lifecycle/Prepared.hs` and the `withPreparedOperation` Haddock in `Reconcile.hs`. Name
  `withPreparedGate` in `Session.hs` as the local production mint site and what it verifies, and drop the claim
  that the plan, operation, fence, and attempt on the gate are the ones the store returned when only the journal
  version is.
- `encodeFields` packs with `ByteStringChar8.pack`, which keeps only the low byte of each character, and
  neither it nor `withPreparedGate` refuses a tab or newline, though `withPreparedGate` writes the caller's
  unknown-phase text. Encode with `TextEncoding.encodeUtf8`, decode with `decodeUtf8'`, and refuse a field
  containing a tab or newline before any write (in `withPreparedGate`, a typed `SessionError`). Correct the
  record-encoding comment in `Prepared.hs`, which claims a field alphabet nothing enforces. Prove it with the
  `SessionSpec` case named in Validation.
- `test/PrepareFixture.hs` builds its record key with a local `sanitize` that maps every other character to
  `-`, not with `operationKeyFor`, so the adapter specs never land on a record production addresses. Derive
  the key with `operationKeyFor` and delete `sanitize`. Rewrite the `withGateFor` Haddock: only the journal
  version comes from the store, it is always the first-write version of a fresh store, and the caller chooses
  the session, fence, and attempt (`gateFor` fixes them at `session-1`, 1, 1; `gateForValues` takes them).

### Sprint 11.2: The prepare compare-and-swap [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Reconcile.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`, `documents/engineering/testing.md`

#### Objective

Revalidate the journal state, re-probe every dependency, then mint the only matching pair. The mode, lease,
revision, verb, and frame revalidation reads the step algebra phase's command authority and lifecycle cursor,
and is that phase's (Phase 12).

#### Deliverables

- One protected compare-and-swap (`withPreparedGate`) revalidates the broker epoch against the session's
  recorded broker generation, the open project state and the presented journal version (through
  `withCurrentOpenPermit`), the open session, the operation's registration, the current fence, and the
  operation's recorded phase classification.
- `withPreparedOperation` then refuses a gate or a sealed set from another plan digest, another operation key,
  or another call digest, and a dependency set that is not the exact ordered edge set of the descriptor.
- The prepare runs **every** dependency probe of the descriptor's edge set itself, after the gate is minted.
  Stale, replaced, or not-ready evidence returns no `PreparedOperation`.
- The sealed `OperationPreconditionSet` has one producer, run inside the prepare, which runs each member's probe
  itself, so a caller cannot select or omit a dependency observation. That the probe it runs is a real backend
  re-observation rather than a retained constant is the cluster lifecycle phase's contract (Phase 16), where
  every caller of the raw probe wrapper exists.
- An operation's edge set is the exact ordered resource-bearing prefix of the plan, derived by traversal rather
  than declared.
- The successful outcome is a `PreparedOperation`/`PreparedPreconditions` pair the adapter accepts **together**,
  plus the successor `ProjectPermit` at the new journal version; the consumed permit fails the next
  compare-and-swap. A prepare does not version the `OperationSession`: every prepare re-reads the live session
  record and refuses one that is not open.
- Every terminal observation returns `OperationAdvance` on success or a typed failure; its eliminator yields the
  result only with the sole successor state/permit pair. A retained readiness value or either half of the pair
  alone is not effect authority.

#### Validation

`SessionSpec` covers each `withPreparedGate` revalidation branch through the cases Sprint 11.1 names, plus "a
fenced-retryable phase needs a fence above the one it was observed at" and "an operation at an unrecognised
phase blocks rather than proceeding". `ReconcileSpec` covers "operation preparation rejects an omitted plan
dependency", "chart preparation refuses a failed readiness reprobe", "chart preparation seals exactly its ready
cluster dependency", "the traversal seals the resource-bearing edge set it derived", and "the zero-dependency
branch refuses an operation that declares edges". `CompileFailSpec` rejects `ForgePreconditionSet.hs`,
`ForgePreparedGate.hs`, and `MismatchPreparedPairRoles.hs`.

The sprint closes when these also exist and pass under `cabal test all` from `core/`: a `ReconcileSpec` case
whose dependency probe counts its runs and reports ready, asserting the count is 0 before `withPreparedOperation`
and 1 after it; a `ReconcileSpec` case whose probe reports not-ready on its first run, asserting
`withPreparedOperation` returns `Left` with no pair; the `CompileFailSpec` diagnostic
`Module 'HostBootstrap.Reconcile' does not export 'withOperationPreconditions'`; and "operation preparation
rejects an omitted plan dependency" rewritten so its refusal comes back from `withPreparedOperation` itself, not
from `zeroDependencyPreconditions`.

#### Remaining Work

- `withOperationPreconditions` and `zeroDependencyPreconditions` are exported from `HostBootstrap.Reconcile`
  and return an `OperationPreconditionSet` the caller holds as an ordinary value, and `withPreparedOperation`
  accepts it at any later time; its only staleness test is a zero generation or phase version. A caller can
  seal while a dependency is ready and prepare after it degrades. Make `withPreparedOperation` take the
  `DependencySnapshot` in place of the set, run in `IO`, and run the traversal itself after the gate and
  descriptor checks (the empty-edge descriptor takes the zero-dependency branch). Drop `OperationPreconditionSet`'s
  producers from the export list, and pass the snapshot at the call sites in `Reconcile.hs`,
  `Cluster/Reconcile.hs`, `Ensure/Colima.hs`, and `Substrate/Provider/Alias.hs`. Update the
  `withOperationPreconditions` reference in the `Readiness.hs` Haddock and `ForgePreconditionSet.hs`. Prove it
  with the two `ReconcileSpec` cases and the compile-fail diagnostic named in Validation.
- `ReconcileSpec` "operation preparation rejects an omitted plan dependency" (`missingDependencyPreparation`)
  calls `zeroDependencyPreconditions` on the `core:copy-source` descriptor of `dependentTestPlan`, which refuses
  because the descriptor declares `core:deploy-vm`, so `withPreparedOperation` is never entered and deleting its
  dependency-set guards leaves the case green. Rewrite the case to call `withPreparedOperation` with the
  `core:copy-source` descriptor, its gate, and a `DependencySnapshot` that lacks the `core:deploy-vm` entry, and
  assert the exact `Failure` it returns, whose detail names "no managed resource for plan dependency
  core:deploy-vm of core:copy-source". The case must fail if the traversal's missing-member refusal is deleted.
- Correct two Haddocks in `Reconcile.hs`. The traversal block ("The plan-owned dependency-snapshot traversal")
  sits directly above the `zeroDependencyPreconditions` block, so `withOperationPreconditions` carries no
  documentation; move it onto the `withOperationPreconditions` signature. The `DependencySnapshot` Haddock
  names only `completeReconcile` and `completePreparedUnchanged` as producers of the `Managed` handle an entry
  needs; name every producer: those two, `completeAdoption`, `completePreparedPhaseTransition` through
  `withPhaseAdvance`, `withReboundManagedResourceEvidence`, `withPlannedReboundManagedResourceEvidence` (which
  choose the handle's phase index), and the carrier openers such as `withFreshRunningProviderHandle` in
  `Substrate/Provider/Reconcile.hs`.
- `documents/engineering/testing.md` names neither the prepare kill-point (the `SessionSpec` case "a prepare
  records the unknown phase before the adapter runs") nor the prepared-pair compile-fail fixtures
  `ForgePreconditionSet.hs`, `ForgePreparedGate.hs`, and `MismatchPreparedPairRoles.hs`. Add both.

### Sprint 11.3: The plan-minted execution descriptor [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Execution/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Give a step a value that names its own node, so it can reach a gate.

#### Deliverables

- `StepExecution scope planId` is minted only by the plan and carries the plan digest, the step's own operation
  key and frame, and its exact ordered edge set.
- It has no public constructor, so it exists only inside a real interpretation of a real validated plan.
- The `scope` and `planId` indices are universally quantified at the action, so an action sees them as skolems
  it cannot choose — which is what makes the pairing with a gate's index-carrying values a type-check rather
  than a convention.
- An action derives its node from the descriptor rather than reconstructing it, so the plan and the effect
  cannot disagree about which node ran.
- `withStepPreparedGate` is the local descriptor route to the prepare compare-and-swap: it reads the plan
  digest and the operation key **off the descriptor**, so a step reaches exactly one gate — its own — and
  cannot name a sibling node's operation. It refuses a descriptor whose plan digest is not the session's,
  because those indices are phantom on the session side and would otherwise unify. A hidden routed reifier
  remains subject to Sprint 11.1's same-origin law and must exact-match the authenticated response to the
  descriptor rather than accepting caller-selected coordinates.
- `mkRecordName` is the one injective encoding by which a *namespaced* identity reaches the store's key
  alphabet. Both identities the gate needs are namespaced — a plan operation key (`core:deploy-kind`) and a
  plan digest (`<specDigest>:<planBytesDigest>`) — and a character-replacing sanitizer would let two of them
  share a key. A plain segment carries no `.`, a namespace carries no `.`, and a token neither begins nor ends
  with `.` nor contains `..`, so `..` occurs in an image only as the path separator, `recordNameIdentity`
  inverts every image, and two distinct identities can never share one durable phase record.

#### Validation

`ChainSpec` covers the descriptor's contents and the absence of a public constructor. `SessionSpec` covers
the route: "a step reaches the prepared gate for its own operation" and the encoded record it lands on, "a
descriptor from another plan cannot prepare in this session", and "a plain operation key cannot occupy an
encoded key's record", which refuses `core.deploy-kind` and `a:b:c`.
`cabal test all --ghc-options=-Werror` from `core/` passed 944/944 on 2026-08-05 (aarch64-osx, GHC 9.12.4).

The sprint closes when a `SessionSpec` case exists and passes under `cabal test all` from `core/` asserting
that `mkRecordName` refuses `core:.x` and `core:x.` with `ProtectedInvalid`, and that
`registerOperationIntent` of `core:.x` in a session that holds `core/x` refuses rather than addressing
`core/x`'s record.

#### Remaining Work

- `recordNameSegment` in `internal/ownership/HostBootstrap/Protected.hs` checks for `..` on the raw segment
  before the namespace `.` is inserted, so a token that begins with `.` passes and the image gains a `..`:
  `core:.x` and `core/x` both encode to `core..x`, and `recordNameIdentity` reads it back as `core/x`. A token
  that ends with `.` breaks the path separator the same way (`core:x./y` encodes to `core.x...y`). Refuse a
  token that begins or ends with `.` with `ProtectedInvalid`, and add the `SessionSpec` case named in
  Validation.

## Remaining Work

- Sprint 11.1: name `withPreparedGate` as the local gate producer in the Haddocks, encode the phase record as
  UTF-8 with separator refusal, and key `PrepareFixture` through `operationKeyFor`.
- Sprint 11.2: run the dependency traversal inside `withPreparedOperation` so a sealed precondition set cannot
  be retained, make the omitted-dependency case reach `withPreparedOperation`, correct the traversal and
  `DependencySnapshot` Haddocks, and document the prepare kill-point and prepared-pair fixtures in `testing.md`.
- Sprint 11.3: refuse a `mkRecordName` token that begins or ends with `.`, so `core:.x` and `core/x` cannot
  share a record.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/lifecycle_state_model.md` — the prepare compare-and-swap and the prepared pair.
- `documents/architecture/composition_methodology.md` — the plan-minted execution descriptor.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the prepare kill-point and compile-fail fixtures.

**Cross-references to add:**
- `development_plan_standards.md` § EE and § CC name this phase as the owner of the prepare gate.
