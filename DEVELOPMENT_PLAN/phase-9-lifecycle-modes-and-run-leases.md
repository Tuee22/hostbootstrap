# Phase 9 — Lifecycle modes and run leases

**Status**: Active
**Depends on**: Phase 5 (installed identity, operator verification, and authority kernels), Phase 7
(Dhall configuration and the generic project model)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-06 ; arm64 macOS 26.6.2 (build 25G83), GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --ghc-options=-Werror` ; pass ; covers in-gate

> **Purpose**: Establish exact Production and Harness mode, run, lease, snapshot, and lifecycle-profile
> authority before project-plan construction begins.

## Phase Objective

Each installed project holds a protected mode lease whose type identifies Production or one exact Harness
run. Harness acquisition mints its run identity generatively, and every mode, snapshot, and lease value
retains that identity through its phantom indices. Binding changes an unbound lease into a bound lease only
when the verified snapshot has the same scope.

An opaque `ActiveProjectMode` narrows the project-wide lease to its exact lifecycle scope. The Production
and Harness lifecycle-profile openers then consume matching root, mode, and unbound-lease evidence through
separate protected one-use slots. Each opaque profile retains the exact installed-project name,
protected-store identity, and broker epoch observed at that transition, so downstream plan admission can
reject evidence assembled from distinct stores even when their project names and epoch numbers happen to
match. Retaining ordinary Haskell values therefore cannot open a second profile or erase its durable origin.

## Sprints

### Sprint 9.1: Indexed `ProjectModeLease` [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Represent the held project mode in the lease type so only the transition for that exact mode can consume
it.

#### Deliverables

- Opaque `ProductionMode` and `HarnessMode runId` types are the only public mode tags.
- `ProjectModeLease projectId mode brokerGeneration` binds installed project, exact mode, and broker
  generation in one opaque capability.
- The protected record uses an internal stable wire sum that decodes only into the matching typed mode
  transition.
- Production acquisition retains an already-held Production mode for the same project, while a Harness
  acquisition contends on the same protected record.
- The public surface consists of opaque mode witnesses and scope-specific transitions; wire constructors
  and mutation kernels (`acquireModeWire`, `acquireProductionMode`, `acquireHarnessMode`) remain
  package-private.
- A mode record at `mode.<project>` that `decodeMode` cannot decode (neither `production<TAB><epoch>` nor
  `harness<TAB><epoch><TAB><run>` with a run segment `parseRunKey` accepts) is refused by `acquireModeWire`
  with `ModeMalformedRecord "mode.<project>"`; it is never treated as an absent mode, and the refusal
  leaves its bytes in place.

#### Validation

`AuthoritySpec` proves exact-mode acquisition, Production retention, cross-mode refusal, and a
multi-process contention case with one winner. The sprint closes when these cases also exist and pass
under `cabal test all` from `core/`, with the phase gate built with `-Werror`:

- `CompileFailSpec` rejects `test/compile-fail/OpenGenericProjectModeMutation.hs` with
  `Module 'HostBootstrap.Lifecycle.Mode' does not export 'acquireModeWire'`, so the generic-mutation
  boundary names the kernel the library actually has. `CompileFailSpec` also proves that a Production
  lease cannot inhabit a Harness mode and that callers cannot construct a mode tag.
- An `AuthoritySpec` case writes `not-a-mode` at `mode.<project>`, then runs `withProductionRoot` and
  `withHarnessRoot`; each returns `Left (ModeMalformedRecord "mode.<project>")`, neither callback runs, and
  the record bytes and version read back unchanged. A second variant writes
  `harness<TAB>1<TAB><49 alphanumerics>` and expects the same refusal.
- The `AuthoritySpec` case "production takes the mode and retains it across a second entry" reads
  `mode.<project>` after the first `withProductionRoot` returns and asserts the record is present and its
  bytes are `production<TAB><epoch>` with the epoch of that root's `projectModeLeaseEpoch`; after the
  second entry returns it reads the record again and asserts it is still present and names Production.
  Releasing the mode on exit (which deletes the record) fails the case.

#### Remaining Work

- Rewrite `test/compile-fail/OpenGenericProjectModeMutation.hs` to import `acquireModeWire` (the generic
  kernel that exists in `HostBootstrap.Lifecycle.Mode`) instead of the nonexistent `acquireMode`, and change
  its `CompileFailSpec` expectation to `Module 'HostBootstrap.Lifecycle.Mode' does not export
  'acquireModeWire'`. The fixture fails today only because the name does not exist, so it would stay
  green if the real kernel were exported.
- Add the two `AuthoritySpec` malformed-mode cases named in Validation (`not-a-mode` bytes and an
  over-long harness run segment), each asserting the exact `ModeMalformedRecord "mode.<project>"` value,
  no callback entry, and unchanged record bytes and version.
- In `test/AuthoritySpec.hs`, make "production takes the mode and retains it across a second entry" read
  the mode record between and after the two entries, as named in Validation. Today it asserts only
  `projectModeLeaseName`, which is the constant `"production"` for every Production lease, so a root that
  released the mode on exit and took it again would pass.

### Sprint 9.2: Generative `RunId runId` [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/harness_workflow.md`

#### Objective

Give each Harness acquisition a fresh type identity that cannot be selected or reconstructed by a caller.

#### Deliverables

- `RunId runId` is opaque and exposes only a non-authorizing text projection for diagnostics and stable
  record keys.
- The Harness acquisition transition mints `RunId runId` only inside a rank-2 continuation.
- `HarnessMode runId`, `Harness projectId runId`, the indexed mode lease, and the Harness unbound lease all
  carry the same generative `runId`.
- Production uses a structurally distinct lease-identity branch that contains no Harness `RunId runId`.
- The text projection is diagnostic/key material only and is never accepted as a `RunId runId`
  constructor input. The text-to-key parser `parseRunKey` and the key-to-witness reifier
  `withReifiedRunId` are package-private.
- A run key is 1 to 48 ASCII alphanumerics or `-`. The protected record field codec (`encodeFields`,
  `decodeFields`, `exactFields`) writes UTF-8 and decodes strictly, so every key it carries reads back
  byte-for-byte, and undecodable bytes are a malformed record rather than a different key.
- Every epoch and version number in a mode, lease, invocation-disposition, or profile-slot record parses
  only as canonical unsigned decimal within `Word64` (digits only, no sign, whitespace, parentheses, hex
  prefix, or leading zero other than `0` itself), so the parser accepts exactly the text `showWord`
  writes; anything else is a malformed record, never a wrapped or different epoch.

#### Validation

`AuthoritySpec` proves distinct Harness acquisitions receive distinct stable identities and that the
Production identity branch is classified independently. `CompileFailSpec` proves that values from two
Harness continuations cannot cross-pair and that callers cannot mint `RunId runId` (`ForgeRunId.hs`). The
sprint closes when these cases also exist and pass under `cabal test all` from `core/`, with the phase
gate built with `-Werror`:

- `CompileFailSpec` rejects `test/compile-fail/OpenRunIdFromText.hs` with
  `Module 'HostBootstrap.Lifecycle.Mode' does not export 'parseRunKey'`, and a second fixture
  `test/compile-fail/OpenReifiedRunId.hs` with `... does not export 'withReifiedRunId'`.
- An `AuthoritySpec` case calls `inspectPlanSnapshot` with the run text `ő-run` and gets
  `Left (ModeInvalidIdentity ...)`; a case calls `mkInvocationCloseKey "ő-close"` and gets
  `Left (ModeInvalidIdentity ...)`.
- A `LifecycleSpec` `refusalCase`, beside "an invalid terminal close key is never normalized or
  surfaced", writes the Production invocation record as `ack<TAB>` followed by the invalid UTF-8 byte
  `0xFF`, and the existing-bound admission refuses it with `ModeMalformedRecord` naming that record key.
- An `AuthoritySpec` case writes each of `production<TAB>-1`, `production<TAB>18446744073709551617`,
  `production<TAB>(1)`, `production<TAB>0x1`, and `production<TAB>01` at `mode.<project>` and runs
  `withProductionRoot`; each returns `Left (ModeMalformedRecord "mode.<project>")`, the callback never
  runs, and the record bytes and version read back unchanged. A second case writes `unbound<TAB>-1` at the
  Production lease key and gets `Left (ModeMalformedRecord <lease key>)` from `withProductionRoot` with the
  lease bytes unchanged.

#### Remaining Work

- Rewrite `test/compile-fail/OpenRunIdFromText.hs` to import `parseRunKey` (the real text-to-key parser)
  instead of the nonexistent `mkRunId`, with the `CompileFailSpec` expectation
  `Module 'HostBootstrap.Lifecycle.Mode' does not export 'parseRunKey'`; add
  `test/compile-fail/OpenReifiedRunId.hs` importing `withReifiedRunId` with the matching expectation. Both
  fixtures fail today only for a name that does not exist.
- In `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`, add `isAscii` to the `legal`
  predicates of `parseRunKey` and `mkInvocationCloseKey`, matching the project-name rule in
  `Authority/Kernel.hs`. `isAlphaNum` alone admits keys such as `ő-close`, which `encodeFields`
  (`ByteStringChar8.pack . Text.unpack`) truncates to a different key (`Q-close`) on write.
- Make `encodeFields` encode UTF-8 (`Text.Encoding.encodeUtf8`) and make `decodeFields` and `exactFields`
  decode with `decodeUtf8'`, returning no fields on a decode failure so each caller reports its existing
  malformed-record refusal. Add the `AuthoritySpec` and `LifecycleSpec` cases named in Validation.
- Rewrite `readWord` in `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs` to accept only
  canonical decimal: every character a digit, no leading zero unless the text is exactly `0`, the
  `Integer` value at most `maxBound :: Word64`, and `showWord value == raw`. Today it uses
  `reads :: ReadS Word64`, which accepts `-1` as `18446744073709551615`, wraps `18446744073709551617` to
  `1`, and accepts whitespace, parentheses, and `0x` forms, so `decodeLease`, `decodeMode`,
  `decodeDisposition`, and the profile-slot decoder turn bytes this module never writes into a valid
  epoch. Add the two `AuthoritySpec` non-canonical-epoch cases named in Validation.

### Sprint 9.3: Scope-indexed lease binding and `VerifiedPlanSnapshot` [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Bind a lease only to a protected snapshot verified for the same Production or Harness scope.

#### Deliverables

- `UnboundRunLease scope brokerGeneration` is the sole pre-binding lease capability.
- `VerifiedPlanSnapshot scope specDigest planDigest` binds the protected snapshot observation to its exact
  lifecycle scope and digests.
- `BoundRunLease scope specDigest planDigest brokerGeneration` retains the same scope, both digests, and
  broker generation.
- The protected binding transition has this exact surface:

  ```haskell
  bindRunLease
    :: UnboundRunLease scope brokerGeneration
    -> VerifiedPlanSnapshot scope specDigest planDigest
    -> (BoundRunLease scope specDigest planDigest brokerGeneration -> IO a)
    -> IO (Either LeaseConflict a)
  ```

- A successful compare-and-swap enters only the bound-lease continuation; a conflicting protected lease
  state returns `LeaseConflict` without authority.
- Fresh root acquisition (`recordUnboundLease`) creates an unbound lease from an absent record, or
  compare-and-swaps an exact decoded `LeaseUnbound` record for the supported pre-effect retry. A decoded
  `LeaseClosed` record is re-armed only by a Production `up` root: it clears the invocation disposition and
  a terminal reverse-root intent, reopens the closed Production journal, and writes `LeaseUnbound`.
  Production `down` and `destroy` and every Harness root refuse it with `ModeLeaseNotBindable <run>
  "closed"`. A decoded `LeaseBound` record returns `ModeLeaseNotBindable <run> "bound"`, every other state
  is refused with its own state name, and malformed bytes return `ModeMalformedRecord`; none of these
  refusal branches enters the root continuation or changes the lease or snapshot record.
  `withProductionRoot` classifies the existing Production lease record before it advances the broker epoch
  counter or writes the mode record, so a Production root refused by any of those lease branches leaves
  every protected record (broker counter, `mode.<project>`, lease, snapshot) byte- and version-identical,
  and an existing bound Production run stays admissible at its recorded epoch afterwards.
- The only snapshot producer is `persistCanonicalPlanSnapshot`, which derives the revision's spec, config,
  and plan digests from an opaque `CanonicalPlanSnapshot`. No exported function persists caller-chosen
  digest text, so the digests `bindRunLease` copies from a `VerifiedPlanSnapshot` are always plan-derived.
- A persisted snapshot record has one encoding: the magic-prefixed canonical record, whose config digest
  and canonical bytes are one optional unit (`Maybe` of a single canonical-material value, tag 0 or tag 1).
  A record carrying only one of the two cannot be built, and tab-separated bytes are a malformed record.
  `inspectPlanSnapshot` reads that record into a non-authorizing `PlanSnapshotView` whose accessors
  project every field, the config digest and canonical bytes included.

#### Validation

`AuthoritySpec` proves successful same-scope binding, exact digest retention, conflict behavior, and the
supported unbound pre-effect retry. It also proves that a second Production root refuses a bound lease
without entering its continuation while preserving the exact lease and snapshot versions and bytes, and
that malformed lease bytes receive the typed refusal without mutation. `CompileFailSpec` proves that a
Production lease cannot bind a Harness snapshot, two Harness run scopes cannot cross-pair, and a snapshot
for one digest pair cannot yield another pair's bound lease. The sprint closes when these cases also exist
and pass under `cabal test all` from `core/`, with the phase gate built with `-Werror`:

- `CompileFailSpec` rejects a fixture `test/compile-fail/OpenFreeDigestSnapshotProducer.hs` that imports
  `persistPlanSnapshot` from `HostBootstrap.Lifecycle.Mode`, with
  `Module 'HostBootstrap.Lifecycle.Mode' does not export 'persistPlanSnapshot'`.
- Every `AuthoritySpec` and `HarnessSpec` case that persists a snapshot does so through
  `persistCanonicalPlanSnapshot`, and the binding cases above still pass.
- An `AuthoritySpec` case writes the tab-separated bytes `1<TAB>spec-1<TAB>plan-1` at a run's snapshot key
  and asserts that `inspectPlanSnapshot` and `verifyPlanSnapshot` return
  `Left (ModeMalformedRecord <snapshot key>)`; a second variant uses the revision text
  `18446744073709551617` and expects the same refusal rather than revision 1.
- An `AuthoritySpec` case persists a snapshot through `persistCanonicalPlanSnapshot`, reads it back with
  `inspectPlanSnapshot`, and asserts that `planSnapshotViewConfigDigest` returns `Just` the snapshot's
  config digest and `planSnapshotViewCanonicalBytes` returns `Just` its canonical bytes.
- The existing `LifecycleSpec` case "a legacy digest-only snapshot cannot mint bound plan evidence" still
  passes.
- The `AuthoritySpec` cases "a second Production root preserves an existing bound lease and snapshot" and
  "a Production root preserves and refuses a malformed lease record" capture `protectedStoreImage store`
  immediately before the refused `withProductionRoot` and assert the image after the refusal is equal,
  in addition to their existing refusal, no-entry, and lease/snapshot checks.
- A `LifecycleSpec` case built on `withExistingBoundSnapshotFixture` runs `withProductionRoot store
  project ProjectUp`, expects `Left (ModeLeaseNotBindable "production" "bound")` with no callback entry,
  then calls `withBoundPlanSnapshot` (`HostBootstrap.ProjectPlan.Snapshot`) and gets `Right` through the
  continuation the fixture's disposition selects, never `Left` wrapping `ModeEpochMismatch`.
- The `AuthoritySpec` case "a fresh binding proves no recovery is owed" calls `withProjectUpMigrationProfile
  (productionRootAuthority root) (productionRootModeLease root) bound snapshot` inside the `bindRunLease`
  continuation and asserts `Right`; that producer refuses every binding origin other than `FreshBinding`
  with `ModeSnapshotMismatch "fresh lease binding" "recovered or migrated lease binding"`, so a fresh bind
  tagged as an existing or migrated binding fails the case.
- The `AuthoritySpec` case "rebinding an already-bound lease is not a fresh transition" asserts that the
  second `bindRunLease` returns a `Left conflict` with `leaseConflictMessage conflict == modeErrorMessage
  (ModeLeaseNotBindable "production" "bound")`, not merely some `Left`.

#### Remaining Work

- Delete `persistPlanSnapshot` from `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs` and its
  export list. It writes caller-chosen spec and plan digests as a config-less record, has no caller in
  `src/` or `app/`, and lets any holder of an `UnboundRunLease` reach a `BoundRunLease` through
  `verifyPlanSnapshot` and `bindRunLease` for digests that name no admitted plan. Move its callers
  (`test/AuthoritySpec.hs` and `test/HarnessSpec.hs`) to `persistCanonicalPlanSnapshot`, and add the
  `OpenFreeDigestSnapshotProducer.hs` compile-fail fixture. Reword the `bindRunLease` Haddock to name
  `persistCanonicalPlanSnapshot` as the producer that makes the bound digests plan-derived.
- Move the two lease Haddock blocks onto the types they describe: "A recorded run lease that has no plan
  snapshot yet..." sits above the private `LeaseLocation` and belongs above `UnboundRunLease`; "A lease
  bound to one verified plan snapshot..." sits above the private `BindingOrigin` and belongs above
  `BoundRunLease`. Give `LeaseLocation` and `BindingOrigin` their own one-line comments.
- Replace the two independent `Maybe` fields (config digest, canonical bytes) of `PlanSnapshotRecord` and
  `VerifiedPlanSnapshot` with one `Maybe` of a canonical-material record holding both, and delete the
  `_ -> Builder.word8 2` branch of `encodePlanSnapshotRecord`, which writes a tag no decoder accepts.
- Delete `decodeLegacySnapshotRecord` and the `<|>` fallback in `decodePlanSnapshotRecord`. No writer
  produces the tab-separated format, and the fallback accepts revisions through `reads` (sign, whitespace,
  hex, silent `Word64` wrap) and Latin-1 digests without `maxSnapshotTextBytes`. Add the two
  `AuthoritySpec` tab-separated refusal cases named in Validation.
- Add the `AuthoritySpec` read-back case named in Validation for `planSnapshotViewConfigDigest` and
  `planSnapshotViewCanonicalBytes`; no test reads either accessor, so a view that dropped the canonical
  material stays green. `CLISpec` reads only the revision and the spec and plan digests.
- In `withProductionRoot` (`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`), read and
  classify `lease.<project>.production` with the same decode and refusal rules `recordUnboundLease` applies
  (bound, closed for `down`/`destroy`, any other non-unbound state, malformed bytes) before
  `withFreshEpoch` and `acquireProductionMode` run. Today `withFreshEpoch` advances the broker counter and
  `acquireModeWire` rewrites `mode.<project>` to the new epoch (or creates it from absent) before
  `recordUnboundLease` refuses, and nothing undoes those writes, so after one refused `up` the bound lease
  records epoch N while the mode record names N+1 and `prepareExistingBoundSnapshotAt` refuses the bound
  run with `ModeEpochMismatch`; a refusal over a malformed lease leaves a newly created Production mode
  record behind. Add the `protectedStoreImage` assertions to the two refused-root `AuthoritySpec` cases and
  the `LifecycleSpec` bound-run-still-admissible case named in Validation.
- Strengthen two `AuthoritySpec` binding cases as named in Validation: "a fresh binding proves no recovery
  is owed" asserts the binding origin through `withProjectUpMigrationProfile` (today it only reads back
  the `"plan-1"` digest the fixture stored, so retagging the fresh bind as `ExistingBinding` stays green),
  and "rebinding an already-bound lease is not a fresh transition" pins the
  `ModeLeaseNotBindable "production" "bound"` message (today any `Left`, including a store failure or a
  stale-version refusal, passes).

### Sprint 9.4: `ActiveProjectMode` narrowing [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Narrow an indexed project-wide mode lease into the exact lifecycle scope authorized by its mode tag.

#### Deliverables

- `ActiveProjectMode scope brokerGeneration` is opaque and retains the active broker generation.
- Production narrowing has the exact type:

  ```haskell
  productionActiveMode
    :: ProjectModeLease projectId ProductionMode brokerGeneration
    -> ActiveProjectMode (Production projectId) brokerGeneration
  ```

- Harness narrowing has the exact type:

  ```haskell
  harnessActiveMode
    :: ProjectModeLease projectId (HarnessMode runId) brokerGeneration
    -> ActiveProjectMode (Harness projectId runId) brokerGeneration
  ```

- These two scope-specific functions are the only producers of active-mode authority.

#### Validation

`CompileFailSpec` proves that Production and Harness active modes cannot substitute for one another, that
two Harness run indices cannot cross-pair, and that the constructor is inaccessible. `AuthoritySpec`
checks that each narrowing preserves the broker epoch observed through the originating lease. The phase
gate runs with `-Werror`.

#### Remaining Work

None.

### Sprint 9.5: Protected one-use Production `LifecycleProfile` slot [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Open a Production lifecycle profile exactly once from matching root scope, active mode, and unbound lease
authority.

#### Deliverables

- `LifecycleProfile scope` is opaque and grants only the scope named by its phantom index.
- Its hidden representation retains the exact installed-project name, protected-store identity, and broker
  epoch observed through the opening lease; downstream evidence leaves need not infer that origin from the
  scope phantom or from coincidentally equal epoch numbers.
- The Production opener has the exact type:

  ```haskell
  withProductionLifecycleProfile
    :: RootScopeAuthority (Production projectId)
    -> ActiveProjectMode (Production projectId) brokerGeneration
    -> UnboundRunLease (Production projectId) brokerGeneration
    -> (LifecycleProfile (Production projectId) -> a)
    -> IO (Either AuthorityError a)
  ```

- The opener compare-and-swaps the unbound lease's protected Production profile slot from available to
  consumed before entering the continuation.
- Root scope, active mode, and unbound lease agree on Production scope and broker generation by type.
- A retained input tuple cannot consume the slot again; the protected transition returns an authority
  error and yields no profile.
- The shared slot consumer (`consumeLifecycleProfileSlot`, used by both the Production and the Harness
  opener) reads the lease record in the same protected entry and mints a profile only while it decodes to
  `LeaseUnbound` at the `UnboundRunLease`'s record version; a bound, closed, or re-versioned lease is
  refused and the slot stays available.
- When ordinary admission refuses inside that entry (for example `ModeReverseRootInProgress` from a durable
  reverse-root intent), the returned `AuthorityError` carries the `modeErrorMessage` of the refusal rather
  than a generic malformed-binding text.

#### Validation

`AuthoritySpec` proves one successful open and refusal of a second open with the same retained evidence
(`AuthorityInvocationConsumed`, one continuation entry). The slot compare-and-swap runs inside the
exclusive protected entry, whose cross-process exclusion "an out-of-process holder is excluded while the
entry is held" proves; the core suite runs on the non-threaded runtime, so its two-`forkIO` opener cases
are a second-opener refusal, not race evidence. `CompileFailSpec` proves that Harness evidence and a
different broker generation cannot inhabit the Production opener. The sprint closes when these cases also
exist and pass under `cabal test all` from `core/`, with the phase gate built with `-Werror`:

- Inside a `withProductionRoot` callback, the test rewrites the lease record to different bytes (a
  `LeaseBound` record, so its version advances), then calls `withProductionLifecycleProfile` with the
  root's original `UnboundRunLease`; it gets a `Left` authority refusal, the continuation never runs, and
  the profile slot still reads `ProfileAvailable` at the original epoch and lease version. The same case
  runs for `withHarnessLifecycleProfile` inside `withHarnessRoot`.
- Inside a `withProductionRoot` callback, the test writes a Pending Destroy reverse-root intent at
  `reverse-root.<project>` and calls `withProductionLifecycleProfile`; the `Left` value's message
  contains the `ModeReverseRootInProgress` text "a durable reverse-root intent owns ordinary lifecycle
  admission", and the slot stays available.
- The two `AuthoritySpec` cases named "two Production profile openers race to one continuation entry" and
  "two Harness profile openers race to one continuation entry" are renamed "a second Production profile
  opener with the same evidence is refused" and "a second Harness profile opener with the same evidence is
  refused", and drop the `entries` counter, whose count only repeats the number of `Right` results; each
  still asserts exactly one `Right` and one `AuthorityInvocationConsumed`.

#### Remaining Work

- In `consumeLifecycleProfileSlot` (`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`), read
  the lease record at `leaseLocationLeaseKey` before the slot compare-and-swap and require that it decodes
  to `LeaseUnbound` with record version `unboundRunLeaseRecordVersion unbound`; refuse otherwise with an
  `AuthorityMalformedBinding` naming the lease state. Today the opener compares only the slot's
  epoch and lease version with the retained `UnboundRunLease`, and binding never touches the slot, so a
  caller that binds the lease and keeps the old `UnboundRunLease` still opens a profile, contrary to the
  `LifecycleProfile` Haddock ("only from the exact active mode plus a still-unbound lease"). Add the
  rewritten-lease cases for both openers named in Validation.
- In the same function, replace the `Left _ -> AuthorityMalformedBinding "ordinary lifecycle admission is
  unavailable"` mapping with one that appends `modeErrorMessage failure`, so an operator refused because a
  reverse-root operation is in progress is told so. Add the reverse-root-intent case named in Validation.
- In `test/AuthoritySpec.hs`, rename the Production and Harness "race to one continuation entry" opener
  cases and drop their `entries` counters, as named in Validation. The core test suite is built without
  `-threaded`, so the two `forkIO` workers share one OS thread and in practice open one after the other,
  and the counter is bumped only after `open` has returned `Right`; neither case observes concurrent
  contention, so the names claim evidence the cases do not produce.

### Sprint 9.6: Protected one-use Harness `LifecycleProfile` slot [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`,
`documents/architecture/harness_workflow.md`

#### Objective

Open a Harness lifecycle profile exactly once from evidence for one generative Harness run.

#### Deliverables

- The Harness opener has the exact type:

  ```haskell
  withHarnessLifecycleProfile
    :: RootScopeAuthority (Harness projectId runId)
    -> HarnessAuthority projectId runId
    -> RunId runId
    -> ActiveProjectMode (Harness projectId runId) brokerGeneration
    -> UnboundRunLease (Harness projectId runId) brokerGeneration
    -> (LifecycleProfile (Harness projectId runId) -> a)
    -> IO (Either AuthorityError a)
  ```

- Root scope, Harness authority, run witness, active mode, and unbound lease share the exact `projectId`,
  `runId`, and broker generation indices.
- The resulting profile retains the exact installed-project name, protected-store identity, and broker epoch
  observed through that Harness lease, just as the Production profile does.
- The opener compare-and-swaps that run's protected Harness profile slot from available to consumed before
  entering the continuation.
- A retained evidence tuple cannot consume the slot again or open a profile for another run.

#### Validation

`AuthoritySpec` proves one successful open and refusal of a second open with the same retained evidence
(`AuthorityInvocationConsumed`, one continuation entry). Cross-process exclusion of the slot
compare-and-swap rests on the exclusive protected entry, as Sprint 9.5's Validation states.
`CompileFailSpec` proves that Production evidence, another Harness run, or another broker generation
cannot inhabit the opener. The phase gate runs with `-Werror`.

Dated evidence for the phase gate and lease-acquisition contract:
`cabal test all --ghc-options=-Werror` from `core/` passed 1169/1169 on 2026-08-09 (aarch64-osx,
GHC 9.12.4), including all 113 public compile-fail boundaries. The same run covered distinct identities
across successive Harness acquisitions, the bound and malformed Production-root refusal/preservation
cases, exact lease/snapshot conflicts, and the Production and Harness same-slot second-opener
refusals. The library and test-suite build also passed with `-Werror`.

Origin-retention revalidation on 2026-08-09 (aarch64-osx, GHC 9.12.4) passed the exact gate at 1194/1194,
including Production and Harness project/store profile projections, an end-to-end two-store/same-project/
same-epoch refusal before snapshot persistence, and all 123 public compile-fail boundaries.

#### Remaining Work

None. The lease recheck in the slot consumer both openers share, its Harness-opener case, and the
rename of the Harness second-opener case are owned by Sprint 9.5.

## Remaining Work

- Sprint 9.1: the mode-mutation compile-fail fixture names `acquireModeWire`; malformed mode-record
  refusal cases; the Production retention case reads the mode record between entries.
- Sprint 9.2: the `RunId` compile-fail fixtures name `parseRunKey` and `withReifiedRunId`; ASCII-only run
  and close keys; UTF-8 record field codec; canonical-decimal epoch parsing in `readWord`.
- Sprint 9.3: delete the public `persistPlanSnapshot`; move the lease Haddocks; one canonical-material
  snapshot field; delete the tab-separated legacy snapshot decoder; a read-back case covers the config
  digest and canonical bytes accessors of `PlanSnapshotView`; a refused Production root classifies
  the lease before advancing the epoch or writing the mode record, proved by whole-store image and
  bound-run-still-admissible cases; the fresh-binding and rebinding cases pin binding origin and refusal.
- Sprint 9.5: the profile slot consumer rechecks the unbound lease and keeps the admission refusal's
  message; the Production and Harness opener "race" cases are renamed as second-opener refusals.

## Documentation Requirements

**Architecture docs to create/update:**

- `documents/architecture/lifecycle_state_model.md` — indexed modes, generative run identity,
  scope-indexed lease binding, active-mode narrowing, and protected profile slots.
- `documents/architecture/harness_workflow.md` — Harness run identity and one-use profile admission.

**Engineering docs to create/update:**

- `documents/engineering/testing.md` — protected compare-and-swap races and compile-fail authority
  fixtures.

**Cross-references to add:**

- Keep `development_plan_standards.md` § EE and the Phase 9 README status row aligned with these six
  foundations.
