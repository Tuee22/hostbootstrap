# Phase 5 — Installed identity, operator verification, and authority kernels

**Status**: Active
**Depends on**: Phase 4 (protected store)
**Substrates**: none (static)
**Gate**: `cabal test all` from `core/`, including the compile-fail fixtures,
host-native on the gate host that runs it
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-12 ; x86_64 Ubuntu 24.04.4 LTS, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` ; pass ; covers in-gate

> **Purpose**: Turn independently verified executable, operating-system, store, and generation facts into
> opaque authority inputs, while leaving lifecycle-specific command admission to the phases that possess
> the complete plan, lease, frame, cursor, and context package.

## Phase Objective

An invocation cannot establish authority by choosing a phantom type, replaying a recorded integer, or
presenting descriptive configuration. This phase supplies the lower authority vocabulary and the sealed
compare-and-swap kernels later lifecycle gates consume. The safe facade verifies installed identity and
the current OS principal, exposes opaque inspection, and parses the closed verb vocabulary; only the
allow-listed package implementation can allocate a fresh epoch, select a root scope, or reserve a command
invocation. Recorded recovery evidence reopens an epoch only through the allow-listed package-private
reifier, which accepts exactly the currently allocated nonzero generation and never advances the counter.

## Sprints

### Sprint 5.1: Closed verb and phase vocabulary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Make lifecycle verbs and phases closed type-indexed vocabularies.

#### Deliverables

- `ProjectVerb` is a GADT over `VerbUp`, `VerbDown`, and `VerbDestroy`; a value for one verb cannot inhabit
  another.
- `LifecyclePhase` distinguishes `PreparePhase`, `ExecutePhase`, and `TeardownPhase` at the type level.
- Parsing yields one existential member of the closed verb set or a typed refusal; there is no text-backed
  extension constructor.

#### Validation

`AuthoritySpec` covers every accepted verb, unknown-verb refusal, and exact rendering.

#### Remaining Work

None.

### Sprint 5.2: Generative installed project identity [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Bind project identity before any plan, run, or authority identity exists.

#### Deliverables

- `InstalledProjectIdentity projectId` has a hidden constructor and exists only inside a rank-2 continuation.
- `withInstalledProjectIdentity` validates an ASCII stable project name against the normalized leaf of
  `getExecutablePath`, including the Windows `.exe` spelling, before minting `projectId`.
- The safe facade cannot fix project identity to a caller-chosen phantom or reconstruct it from its rendered
  name; Phase 7 threads this opener through the configuration and CLI surfaces.
- Stable record keys derive their project component only from `InstalledProjectIdentity`.
- The kernel opener `withInstalledProjectKernel` refuses an empty name, a name longer than 64 characters, and
  any character outside ASCII alphanumerics, `-`, and `_`, each with its own `AuthorityInvalidIdentity` reason.
- The only caller of `withInstalledProjectKernel` is the facade opener in `HostBootstrap/Authority.hs`; no
  package module re-mints an identity from a recorded project name.

#### Validation

Closure criteria, run by the host static gate (`cabal test all` from `core/`):

- `AuthoritySpec` covers matching/mismatching executable identities, Windows suffix normalization, and invalid
  ASCII stable names (dotted and non-ASCII).
- `AuthoritySpec` asserts `withInstalledProjectIdentity ""` returns
  `Left (AuthorityInvalidIdentity "the installed project name must not be empty")`; a 65-character name
  returns `Left (AuthorityInvalidIdentity "the installed project name must be at most 64 characters")`; and a
  64-character name passes the length bound, so its refusal is the executable-mismatch reason
  ("does not match the invoked executable"), not the length reason.
- A source guard pins the caller set of `withInstalledProjectKernel` across `core/hostbootstrap-core/src` to
  `HostBootstrap/Authority.hs` alone (compared with `SourceGuard.repoRelativePath`).
- Pinned compile-fail fixtures cover constructor forgery, rank-2 escape, and nominal-index coercion; Phase 7
  covers propagation across distinct runtime invocations.

#### Remaining Work

- Add the three `withInstalledProjectIdentity` boundary cases above (empty, 65 characters, 64 characters) to
  `AuthoritySpec`, each asserting the exact `AuthorityInvalidIdentity` reason or the executable-mismatch reason.
- `reserveCurrentLifecycleCommandKernel` (`Lifecycle/Session.hs`) re-mints an `InstalledProjectIdentity` by
  calling `withInstalledProjectKernel` on the recorded `acquisitionBindingProject binding` before invoking
  `reserveCommandInvocationKernel`. Replace it: the identity the kernel compares against is the
  executable-verified `InstalledProjectIdentity` the root admission opened, threaded from the
  `Command/LifecycleEntry.hs` callers through `authorizeRootProject` into `reserveCurrentLifecycleCommandKernel`.
  Add the caller-set source guard above, and a `SessionSpec` drift case that pairs a journal and cursor coerced
  (SessionSpec's `unsafeCoerce` drift pattern) from a fixture of another installed project and asserts
  `AuthorityStoreNotOurs` with no `invocation.` record written.

### Sprint 5.3: Verified OS principal [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Represent the OS decision separately from lifecycle authority.

#### Deliverables

- `verifyOsPrincipal` asks the operating system to create and remove a probe in the exact protected records
  directory and yields opaque `VerifiedOsPrincipal` only on success.
- The evidence retains the protected-store identity and is refused by a kernel operating on another store.
- `VerifiedOsPrincipal` grants no verb, scope, plan, epoch, or command authority by itself.

#### Validation

Closure criteria, run by the host static gate (`cabal test all` from `core/`):

- `AuthoritySpec` covers OS refusal ("OS-principal verification refuses an unavailable records directory") and
  matching-store evidence ("OS-principal evidence names the exact protected store").
- A kernel-level case opens two fixture stores A and B, verifies a principal in store A, presents it to
  `withVerifiedRootInvocationKernel` and to `withExistingVerifiedRootInvocationKernel` in a session of store B,
  and asserts `Left (AuthorityOperatorRefused "the operator authorization was issued for a different protected store")`
  with store B's protected image unchanged.

#### Remaining Work

- The cross-store principal guard (`principalMatchesStore` in `Authority/Kernel.hs`) is reached by no test:
  `withProductionRoot` and `withHarnessRoot` verify the principal in the same session they admit, so the
  composite brackets cannot express a foreign principal. Give the suite a kernel-level route — a
  `visibility: private` sublibrary seam in the pattern of `lifecycle-transaction-internal` (Sprint 5.11) that
  exposes the root kernels to `hostbootstrap-core-test` only, with a compile-fail fixture pinning that a
  downstream consumer cannot import it — and add the two-store case above for both root kernels.

### Sprint 5.4: Broker epochs [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Make a broker generation evidence of a protected transition, not an integer claim.

#### Deliverables

- `BrokerEpoch brokerGeneration` is opaque and generative.
- The package-private fresh opener advances the installed project's protected monotonic counter before yielding
  the new epoch and retains its exact project and store origin.
- Root admission rechecks that origin.
- The package-private recorded-value reifier `withReifiedAllocatedBrokerEpochKernel` takes a recorded `Word64`
  and yields a fresh-phantom `BrokerEpoch` only when that value is nonzero and equals the installed project's
  current protected allocation counter; it never advances the counter. It refuses a zero value ("a recorded
  broker generation must be positive"), an absent counter ("the recorded broker generation has no allocation
  counter"), a malformed counter ("the broker generation counter is malformed"), and any other value ("the
  recorded broker generation does not match the allocated counter").
- Its callers are allow-listed: `Lifecycle/Mode.hs` alone, at the committed-generation convergence and at
  `withRecordedEpoch` for existing-bound reverse-root recovery.
- The exposed modules offer no `Word64 -> BrokerEpoch` route, and nominal roles prevent coercing one generation
  index into another.

#### Validation

Closure criteria, run by the host static gate (`cabal test all` from `core/`):

- `AuthoritySpec` covers monotonic allocation, malformed/exhausted counter refusal, and project/store separation.
- `LifecycleSpec`'s `existingBoundRefusalCases` carries a "broker counter deleted" row and a "broker counter
  malformed" row: each corrupts `broker.<project>.generation` under an existing bound Production run, drives the
  existing-bound recovery that reaches `withRecordedEpoch`, and asserts the exact `ModeAuthorityFailure`
  reason ("the recorded broker generation has no allocation counter", and "the broker generation counter is
  malformed") with no authority minted.
- A source guard pins the caller set of `withReifiedAllocatedBrokerEpochKernel` across
  `core/hostbootstrap-core/src` to `HostBootstrap/Authority/Kernel.hs` and `HostBootstrap/Lifecycle/Mode.hs`.
- Pinned compile-fail fixtures cover constructor opacity and nominal coercion. `OpenRecordedBrokerEpoch.hs`
  imports `withReifiedAllocatedBrokerEpochKernel` from `HostBootstrap.Authority` and from
  `HostBootstrap.Lifecycle.Mode` and pins "does not export 'withReifiedAllocatedBrokerEpochKernel'" for each.

#### Remaining Work

- Add the two `existingBoundRefusalCases` rows (counter deleted, counter malformed) to `LifecycleSpec`, asserting
  the exact reasons above and an unchanged protected image apart from the corrupted counter.
- Add the caller-set source guard for `withReifiedAllocatedBrokerEpochKernel`.
- `OpenRecordedBrokerEpoch.hs` probes `withRecordedBrokerEpoch`, a name the tree does not define, so it holds
  only because that name is absent. Repoint it at `withReifiedAllocatedBrokerEpochKernel` from both exposed
  modules and re-pin the registration in `CompileFailSpec`.

### Sprint 5.5: Scoped root invocation authority [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectScope.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Verify one exact root invocation without letting a public caller select its lifecycle scope.

#### Deliverables

- `HostBootstrap.ProjectScope` defines the constructorless phantom scope indices `Production projectId` and
  `Harness projectId runId` that `scope` ranges over, shared by the authority kernel and the configuration
  vocabulary.
- `RootInvocationAuthority scope brokerGeneration verb` is opaque and retains the installed project, durable
  protected-store identity, project/store-bound broker epoch, and exact closed verb.
- Its package-private producer consumes the exact installed identity, verified OS principal, epoch, verb, and a
  scope selected by the composite lifecycle transaction.
- The verifier binds an unclaimed authority store to the installed identity with compare-and-swap and refuses a
  store already bound to another project.
- The exposed module offers no standalone root opener and no scope-selection witness.

#### Validation

Closure criteria, run by the host static gate (`cabal test all` from `core/`):

- `AuthoritySpec` reaches the kernel through the composite Production/Harness brackets and covers project/store
  binding ("a store already bound to another project refuses this one" asserts `AuthorityStoreNotOurs`) and the
  retained project name. The verb and scope are type indices (`ProjectVerb VerbUp` has one inhabitant), so the
  compile-fail fixtures below are their proof; the runtime case "the root gate mints authority for the exact
  verb and scope" asserts only the project name, and its line forcing `rootScopeAuthority root` with `seq` checks
  nothing (the scope's field mapping is Sprint 5.6's case).
- A kernel-level case allocates a `BrokerEpoch` in store A and presents it, with a principal verified in store B,
  to `withVerifiedRootInvocationKernel` and to `withExistingVerifiedRootInvocationKernel` in a session of store B,
  asserting `Left (AuthorityEpochOriginMismatch <project> <store B identity>)` with store B's protected image
  unchanged; a second case does the same with an epoch allocated for another installed project in store B.
- Pinned compile-fail fixtures cover constructor, scope-substitution, nominal-role, and public-opener absence.

#### Remaining Work

- The epoch-origin guard (`epochMatches` in `Authority/Kernel.hs`) is reached by no test. Add the two
  kernel-level cases above through the private test seam Sprint 5.3 adds.
- Rename the `AuthoritySpec` case "the root gate mints authority for the exact verb and scope" to "the root gate
  retains the installed project name" and drop its `seq` line.

### Sprint 5.6: Root-scope narrowing [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Expose the root's established scope without exposing a scope constructor.

#### Deliverables

- `RootScopeAuthority scope` is opaque.
- `rootScopeAuthority` projects it only from `RootInvocationAuthority scope brokerGeneration verb`.
- No function converts one `RootScopeAuthority` to another scope or constructs one from configuration/context.
- The projection copies the root's project name, store identity, and epoch word into the matching fields; the
  project and store are both `Text`, so their order is a runtime property, not a type one.

#### Validation

Closure criteria, run by the host static gate (`cabal test all` from `core/`): compile-fail fixtures cover
construction and cross-scope substitution, and an `AuthoritySpec` case, through the private test seam Sprint 5.3
adds, opens a root in a fixture store and asserts `rootScopeProjectName (rootScopeAuthority root)` equals the
installed project name, `rootScopeStoreIdentity` equals that store's identity, and `rootScopeEpochWord` equals
`brokerEpochWord (rootAuthorityEpoch root)`.

#### Remaining Work

- No test checks the projection's field mapping (the existing case only forces `rootScopeAuthority root` to
  WHNF). Add the three-field `AuthoritySpec` case above.

### Sprint 5.7: Command authority vocabulary [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeCommandAuthority.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Define the opaque result shared by proof-complete lifecycle command gates.

#### Deliverables

- `CommandAuthority scope planId frame authorityEpoch verb phase` carries the exact scope, plan, frame,
  authority epoch, verb, and phase indices.
- Its constructor is package-private; the safe authority facade exposes inspection but no producer. The later
  proof-complete plan, child, and teardown gates own production: the root producer is the root-refined generic
  `authorizeRootProject` (Sprint 17.8) with a Cabal-private root-Up `LifecycleEntry` consumer, and this phase
  keeps the constructor and kernel ownership.
- `commandAuthorityEpoch` returns the indexed epoch value rather than erasing it to an unrelated word.
- `commandAuthorityMatchesStore` answers `True` only for the protected store the authority's retained broker
  epoch originated in; every effectful boundary that receives a store separately calls it.
- `AuthorityError` carries only refusals some kernel or gate produces.
- The safe authority facade exports no generic lifecycle command-authority producer; the reservation producer
  remains package-private and proof-complete gates own its use.

#### Validation

Closure criteria, run by the host static gate (`cabal test all` from `core/`):

- Pinned construction/coercion fixtures cover scope, plan, frame, and epoch indices, and the exported-surface
  guard (`authorityFacadeExports` in `AuthoritySpec`) pins the safe facade's absence of a generic producer.
- An `AuthoritySpec` case authorizes a root `CommandAuthority` in store A through the Sprint 5.8 reservation
  fixture and asserts `commandAuthorityMatchesStore authority storeA == True` and
  `commandAuthorityMatchesStore authority storeB == False` for a second opened fixture store B.
- A source guard asserts every `AuthorityError` constructor named in `Authority/Kernel.hs` is constructed at
  least once in `core/hostbootstrap-core/src` outside `authorityErrorMessage`.

#### Remaining Work

- Add the two-store `commandAuthorityMatchesStore` case above; no test exercises its `False` result.
- `AuthorityUnknownFrame` is exported through `AuthorityError (..)` and rendered by `authorityErrorMessage`, but
  no module constructs it. Delete the constructor and its rendering arm, and add the produced-constructor
  source guard above.

### Sprint 5.8: One-use command reservation kernel [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`, `core/hostbootstrap-core/test/SourceGuard.hs`,
`core/hostbootstrap-core/test/Spec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Give later complete authorization gates one atomic reservation primitive.

#### Deliverables

- Package-private `CommandReservation` contains the stable installed-project, protected-store, plan-digest,
  frame-key, epoch, verb, and phase identity already verified by its caller.
- `reserveCommandInvocationKernel` refuses a reservation whose project differs from the supplied installed
  identity (`AuthorityStoreNotOurs`) or whose store differs from the session's store (`AuthorityWrongStore`),
  then compare-and-swaps the exact absent reservation record into place and reads it back before yielding
  `CommandAuthority`.
- The record key is SHA-256 over one canonical length-prefixed encoding; the complete encoding is retained in
  the record so a digest collision or any foreign record under that key refuses with
  `AuthorityReservationConflict` rather than consuming another invocation, and a read-back that does not return
  the written version and bytes refuses the same way.
- Reverse-root Teardown replay: the reservation carries a private replay flag, set by
  `reverseRootReplayEligible` exactly for `ProjectDown` and `ProjectDestroy` with `Teardown`. A byte-identical
  existing record for a replay-eligible reservation re-delivers `CommandAuthority` at that record's version, so
  a crashed root teardown resumes; every other byte-identical existing record refuses with
  `AuthorityInvocationConsumed`. The flag is not part of the canonical identity and `CommandAuthority` does not
  carry it. `reverseRootReplayEligible` enumerates every verb/phase pair with no wildcard, so a new verb or phase
  constructor forces a replay decision at compile time.
- For every reservation that is not replay-eligible, concurrent identical reservations have exactly one winner;
  changing any stable member names a distinct reservation.
- The kernel performs no plan, lease, frame, cursor, or context validation and is not an authorization gate.

#### Validation

Closure criteria, run by the host static gate (`cabal test all` from `core/`). The behavioural cases drive the
kernel directly through the private root-kernel seam Sprint 5.3 adds, which this sprint extends to export
`commandReservationKernel`, `reserveCommandInvocationKernel`, `reservationIdentity`, `invocationKey`,
`withInstalledProjectKernel`, `withFreshBrokerEpochKernel`, and `withReifiedAllocatedBrokerEpochKernel`. No
case depends on a later phase's plan, journal, cursor, or lifecycle lease. The shared setup opens a fixture
protected store, admits the test executable's identity (`Fixture.withFixtureInstalledProject`), verifies an OS
principal in that store, allocates one broker epoch `e` with `withFreshBrokerEpochKernel`, opens the root with
`withVerifiedRootInvocationKernel ProductionRootScope ... e ProjectUp`, and builds the base reservation
`R = commandReservationKernel root "plan-d" Execute "frame-f"`. Store reads and rewrites in the cases use
`HostBootstrap.Protected` (`readProtectedRecord`, `listProtectedRecords`, `compareAndSwapProtectedRecord`), which
the test suite already depends on through `ownership-internal`.

- The races use one rebuild-and-reserve routine, because the store's exclusive entry is held per session and a
  thread cannot re-enter it: the setup binds the store and allocates `e` in one session, records
  `brokerEpochWord e`, and leaves the session. The routine then enters its own session, admits the executable
  identity, verifies a principal, reifies `e` from its word with `withReifiedAllocatedBrokerEpochKernel`, reopens
  the root with `withExistingVerifiedRootInvocationKernel ProductionRootScope ... ProjectUp`, rebuilds `R`
  byte-identically, and calls `reserveCommandInvocationKernel`.
- One-winner race, threads: two `forkIO` threads each run the routine; exactly one returns `CommandAuthority`,
  the other returns `AuthorityInvocationConsumed`, and `listProtectedRecords` shows exactly one `invocation.`
  record.
- One-winner race, processes: the parent starts the test executable with
  `--hostbootstrap-command-reservation-probe <store root> <epoch word> plan-d frame-f` (dispatched in `Spec.hs`
  in the form of AuthoritySpec's protected-entry probe) and runs the routine itself while the probe runs it;
  the probe exits 0 on `CommandAuthority` and 3 on `AuthorityInvocationConsumed`. Exactly one of parent and
  probe wins, the other observes `AuthorityInvocationConsumed`, and the store holds exactly one `invocation.`
  record.
- Key distinctness, behavioural: after reserving `R`, each of these reservations changes exactly one member,
  returns `CommandAuthority` with a `commandAuthorityInvocation` different from `R`'s, and writes a second
  `invocation.` record: plan digest (`"plan-d2"`), frame (`"frame-f2"`), phase (`Prepare`, same root), verb (a
  second root opened over the same `e` with `ProjectDown`, phase `Execute`), epoch (a second fresh epoch, root
  `ProjectUp`), and store (a second fresh fixture store whose first allocated epoch carries the same word as `e`;
  the record is written in that store).
- Key distinctness, project: one store binds one project (`withVerifiedRootInvocationKernel` refuses a second
  with `AuthorityStoreNotOurs`), so the project member cannot change alone behaviourally. The case calls
  `reservationIdentity` twice with every argument equal except the project text and asserts the two encodings
  differ and `invocationKey` yields two different record keys.
- Project mismatch: `R` presented with an identity minted by `withInstalledProjectKernel "other-project"`
  returns `AuthorityStoreNotOurs "other-project" <executable name>` and writes no `invocation.` record.
- Conflict: for each of up `Execute`, down `Teardown`, and destroy `Teardown`, the case reserves once, rewrites
  that reservation's own record (key `invocationKey (reservationIdentity ...)`) with different bytes by
  `compareAndSwapProtectedRecord` at its current version, re-runs the same reservation, and asserts
  `AuthorityReservationConflict` with the record's version unchanged since the rewrite.
- Replay: a second identical `down` `Teardown` reservation and a second identical `destroy` `Teardown`
  reservation each return `CommandAuthority` with the same invocation id; a second identical `up` `Execute`
  reservation returns `AuthorityInvocationConsumed`.
- Wrong store: `R` (root opened in store A) presented in a session of a second fixture store B under the same
  installed identity returns `AuthorityWrongStore <store A identity> <store B identity>` and writes no
  `invocation.` record in B.
- Import guards restrict the kernel to its allow-listed package implementation: the ten package importers plus
  the Sprint 5.3 seam module, found across every `hs-source-dirs` entry of the main library stanza (today `src`
  and `internal/cluster-backend`, read from `hostbootstrap-core.cabal` with `SourceGuard.mainLibraryStanza` and
  walked with `SourceGuard.listHaskellSources`), named with `SourceGuard.repoRelativePath` (the
  separator-neutral helper the [Haskell-core-scaffolding phase](phase-2-haskell-core-scaffolding.md) owns) so
  the allow-list names the same modules on every supported outer host realization (§ JJ). The
  configuration/reconciliation guard parses the kernel's imports with `SourceGuard.haskellImports` and asserts no
  imported module — qualified or not, and none in the transitive closure of its `HostBootstrap` imports —
  starts with `HostBootstrap.Config` or `HostBootstrap.Reconcile`. The closure walker resolves each
  `HostBootstrap` import against the `hs-source-dirs` of every `library` stanza in `hostbootstrap-core.cabal`
  (the kernel imports `HostBootstrap.Protected` from `internal/ownership`), and fails on a `HostBootstrap`
  import it cannot resolve rather than stopping there.

On 2026-08-17 the gate passed host-native on Windows 11 Home 10.0.26200 x86_64 (GHC 9.12.4, Cabal 3.16.1.0)
at 1,877/1,877, the first run to exercise the separator-neutral allow-list from a native-separator gate host.

#### Remaining Work

- Export `reservationIdentity` and `invocationKey` from `Authority/Kernel.hs`, and extend the private
  root-kernel seam Sprint 5.3 adds to re-export `commandReservationKernel`, `reserveCommandInvocationKernel`,
  `reservationIdentity`, `invocationKey`, `withInstalledProjectKernel`, `withFreshBrokerEpochKernel`, and
  `withReifiedAllocatedBrokerEpochKernel` to `hostbootstrap-core-test` only; add the seam module to the
  kernel-importer allow-list.
- `AuthoritySpec` never calls the reservation kernel: its reservation cases are source-text guards (including
  a count of seven `field (` tokens). Add the thread race, key-distinctness (behavioural and project-encoding),
  project-mismatch, conflict, replay, and wrong-store cases listed in Validation, driven through the seam.
- Add the `--hostbootstrap-command-reservation-probe` dispatch to `Spec.hs` and its probe body in
  `AuthoritySpec`, exiting 0 on `CommandAuthority` and 3 on `AuthorityInvocationConsumed`, and the two-process
  race case that runs it.
- Replace the wildcard `reverseRootReplayEligible _ _ = False` in `Authority/Kernel.hs` with the explicit
  verb/phase pairs, and update the AuthoritySpec source guard that pins the wildcard line.
- The "the kernel has no configuration dependency" and "the kernel has no lifecycle-plan dependency"
  assertions in `AuthoritySpec` match the raw substrings `import HostBootstrap.Config` and
  `import HostBootstrap.Reconcile`, which qualified imports (`import qualified HostBootstrap.Config.Vocab`)
  pass. Rewrite them on `SourceGuard.haskellImports` with the transitive closure described in Validation, adding
  to `SourceGuard` a reader that returns the `hs-source-dirs` of every `library` stanza so the walker resolves
  `HostBootstrap.Protected` in `internal/ownership` and fails on an unresolved `HostBootstrap` import.
- "the authority kernel has a closed package-internal importer set" and its `childCommandReservationKernel`
  scan walk only `core/hostbootstrap-core/src`, although the main library also compiles
  `internal/cluster-backend`. Derive the scan roots from the main library stanza's `hs-source-dirs` and walk
  each through `SourceGuard.listHaskellSources`, deleting `AuthoritySpec`'s private, unsorted
  `haskellSources` walker.

### Sprint 5.9: The identity decision reads the role it parsed [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Writing the root config at the binary's own sibling path is what provisions the installed handoff and
build identities, and that decision is about the **role**, not about the spelling the role arrived in.
`--role` accepts aliases and normalises case and separators, so the decision is taken on the parsed
value the same function already produced.

#### Deliverables

- The initializer's default-role parameter is the parsed role kind, not its rendered text.
- The provisioning guard compares parsed role kinds.
- The parser default and help text render that value rather than carrying a second literal.
- Cases cover the canonical spelling, an accepted alias, and a case- and separator-normalised spelling, each asserting that identity is provisioned, and one non-default role asserting that it is not.
- The cases restore whatever the executable's siblings held: a sibling that existed beforehand is rewritten with
  its original bytes, and a sibling that was absent beforehand (the sibling `.dhall` and the five identity
  files) is deleted, so no case's expectation depends on the order it ran in and no signing seed is left beside
  the test executable.

#### Validation

The host static gate; the command suite is where the cases land. Dated evidence: on 2026-09-12,
x86_64 Ubuntu 24.04.4 LTS with GHC 9.12.4 and Cabal 3.16.1.0, `cabal test all` from `core/` passed
with the four `project init` cases green, including `--role host` and `--role "  HOST_Orchestrator  "`
each provisioning the five root identity files. Closure adds a `ContextSpec` case that runs
`withRestoredFiles` over a path absent beforehand, creates it inside the action, and asserts the path is
absent afterwards; and one over a path present beforehand, rewritten inside the action, asserting its
original bytes afterwards.

#### Remaining Work

- `withRestoredFiles` in `ContextSpec` restores absent siblings with `restore Nothing = pure ()`, leaving the
  provisioned `.handoff.key`, `.build.key`, `.activation.key`, public halves, and sibling `.dhall` next to the
  test executable. Make `restore` for an absent path remove the file if it exists, and add the two
  `withRestoredFiles` cases above.

### Sprint 5.10: Every registered fixture pins the diagnostic it expects [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeSessionPermit.hs`,
`core/hostbootstrap-core/test/compile-fail/ObservedReadyGuestAlias.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

§ HH requires a compile-fail fixture to fail *for its named reason*, because a fixture that merely
fails to compile is satisfied by a typo. Every registered fixture therefore states the phrase it
expects, and the registration takes no other shape — including the two the architecture page cites as
the proof for its readiness and capability boundaries.

#### Deliverables

- Every registered fixture carries one contiguous expected phrase, read from the diagnostic it actually produces.
- The capability and readiness fixtures the boundary table cites — `ForgePreparedGate.hs` and `RawReadiness.hs` — are among them.
- Expectations split across separately-matched fragments are re-joined into one phrase, because fragments can be satisfied independently by an unrelated error on the same line. The matcher enforces it: `rejectsWithUsing` splits stderr into per-diagnostic blocks, each expected phrase must match inside one block, and two expected phrases satisfied only by the same block fail the case. Fixtures compile with `-fno-diagnostics-show-caret`, so a block holds diagnostic text only and an echoed source line cannot satisfy a phrase.
- A phrase names the rejected slot or the boundary, not only one side of a mismatch or an echoed source line.
- The registration combinator takes `NonEmpty String`, so an unpinned fixture is not expressible rather than merely absent.
- Fixtures whose diagnostic is an arity or kind error rather than the boundary they are registered under are repaired to ask their own question, not re-pinned to what they happened to say: their signatures fully apply every type they name.

#### Validation

The host static gate (`cabal test all` from `core/`). The compile-fail suite is the subject and the long pole.
Dated evidence: on 2026-09-12, x86_64 Ubuntu 24.04.4 LTS with GHC 9.12.4 and Cabal 3.16.1.0, the public
boundary suite passed 522 cases in 83.11 seconds with every case stating its expected phrase.

Closure criteria: every fixture named in Remaining Work carries the repaired phrase below, copied from the
fixture's actual stderr; the per-block matcher is in place, fixtures compile with
`-fno-diagnostics-show-caret`, and every registration passes under both; and `rejectsWith` has type
`FilePath -> NonEmpty String -> TestTree`.

#### Remaining Work

- `RawRegistryPlan.hs` and `ForgeReadyBlobRoute.hs` are pinned to the kind errors their own under-applied
  signatures raise ("Expecting four more arguments to ..."), which fire whether or not the constructor is
  exported. Fully apply `RegistryPlan` and `ReadyBlobRoute` (six parameters each, `RegistryPlan.hs`), give the
  bodies the current record arity, and pin the hidden-constructor diagnostic each then produces
  ("Illegal term-level use of the type constructor '...'" or "Data constructor not in scope: ...").
- Re-join split registrations into one contiguous phrase each, and make `rejectsWithUsing` match per diagnostic
  block as stated in Deliverables. Named cases: `CallerTextAsProjectVerb.hs` ("Couldn't match type: [Char]
  with: ...ProjectVerb Verb"); `CallerSelectedDescentSubtree.hs` (two phrases, one per binding: "Couldn't match
  expected type: TeardownPlan Scope Plan Child VerbDestroy -> result with actual type: CurrentFrame Scope Plan
  Child" and "Couldn't match type: [Char] with: TeardownPlan Scope Plan Child VerbDestroy", each completed from
  stderr); `CoerceProductionClosureAuthorization.hs`
  ("Couldn't match type 'FirstGeneration' with 'SecondGeneration' arising from a use of 'coerce'", plus a
  second binding that coerces the project index with its own phrase); and
  `PassRawAdmissionToReverseRootTargetCursor.hs` (one "Couldn't match expected type
  '...AcquisitionJournalAdmission' with actual type '()'" phrase) and `PassRawAdmissionToResumedReverseRoot.hs`,
  `PassRawAdmissionToFreshReverseRoot.hs`, and `PassRawAdmissionToReauthorizedBoundSnapshot.hs` (each one
  "Couldn't match expected type '...ExistingBoundSnapshotAdmission' with actual type '()'" phrase), plus a sibling
  fixture per admission witness that names its constructor from the public module so a constructible witness
  turns the suite red. `PassRawAdmissionToReverseAcquisitionJournal.hs` is not repaired here: Sprint 12.21
  deletes it, its registration, and `reopenExistingReverseAcquisitionJournalKernel` together.
- `CoerceHandoffRecoverySigningCapability.hs` pins one shared representation phrase and nine bare kernel names,
  and omits `signRecoveryWireKernel`. Split it into one fixture per kernel (all ten, including
  `signRecoveryWireKernel`), each pinned to "Couldn't match representation of type '()' with that of
  'HostBootstrap.Handoff.Internal.RecoverySigningKernel'".
- `CoerceRoleLifecycleAuthorityRoles.hs` pins 34 echoed source lines ("cursorScope = coerce", ...), which any
  error in the equation prints. Give each index its own marker pair (for example `CursorScopeA`/`CursorScopeB`)
  and pin one "Couldn't match type '<A>' with '<B>' arising from a use of 'coerce'" phrase per index.
- Under-pinned single phrases: `CallerFrameNameTeardown.hs` pins "Couldn't match type: [Char] with:
  CurrentFrame Scope Plan Frame"; `EmptyProspectiveMigrationDrafts.hs` gains a signature with concrete marker
  types and pins "Couldn't match expected type: NonEmpty (PlanDraft ... with actual type: [a0]".
- `PassFreshEvidenceToBoundSnapshot.hs` passes the evidence in `withBoundPlanSnapshot`'s terminal-callback slot,
  so it proves only that a lease is not a callback. Supply a real terminal callback, pass the evidence as an
  extra argument, and pin the too-many-arguments diagnostic naming `withBoundPlanSnapshot`.
- Change `rejectsWith`/`rejectsWithUsing` to take `NonEmpty String`.
- Add `-fno-diagnostics-show-caret` to the `PublicCompiler` arguments in `resolvePublicCompiler`, then convert
  every phrase that is echoed source text rather than diagnostic text (the `<name> = coerce` phrases among
  them) to a diagnostic phrase.
- `MutateBeforeOwnershipRecord.hs` pins only the actual side ("with actual type: Entered session object"). Pin
  "Couldn't match expected type:
  hostbootstrap-core-0.1.0.0:ownership-internal:HostBootstrap.Ownership.Internal.Recorded session object with
  actual type: Entered session object", the shape `ReleaseWithoutOwnershipBinding.hs` uses.
- `EscapeProviderCapabilityIdentity.hs` passes a bare `ResourceHandle ... Managed Running` where
  `discoverProvider` takes `ManagedProviderHandle scope planId backendId providerId Running`, so it carries a
  second, unrelated type error. Change the parameter to `ManagedProviderHandle` (exported by
  `HostBootstrap.Substrate.Provider`) and confirm the capability-escape phrase is then the only diagnostic.
- `HarnessConfigAsProduction.hs` wraps the secret in a fixture-local `Config` newtype and pins the same
  one-sided phrase as `ProductionPlaintext.hs`. Route the Harness secret into a library config consumer that
  requires Production scope, and pin both sides of the mismatch (the Harness actual type and
  `SecretRef (Production Project)`); delete the fixture if no library consumer exists.
- `ImportLifecycleDependencyInternal.hs` omits the module name. Pin "Could not load module
  'HostBootstrap.Lifecycle.Dependency.Internal'. It is a member of the hidden package
  'hostbootstrap-core-0.1.0.0:lifecycle-dependency-internal'" (the sublibrary's `visibility: private` is checked
  by Sprint 5.13's stanza guard, because every non-main unit is hidden under `-hide-all-packages`).
- `ForgeSessionPermit.hs` forges `ProjectPermit`, `OperationSession`, `SessionId`, `FenceEpoch`, `PreparedGate`,
  and `OperationAdvance` in one file but pins only "Illegal term-level use of the type constructor
  'ProjectPermit'", so the `ProjectPermit` line keeps the case green if any of the other constructors is
  exported. Keep `ForgeSessionPermit.hs` to the `ProjectPermit` binding and split the rest, each importing
  `HostBootstrap.Lifecycle.Session` and taking any other sealed value it needs as a parameter so the forged
  constructor is the file's only error: `ForgeOperationSession.hs` (`SessionId -> OperationSession scope planId`),
  `ForgeSessionId.hs`, `ForgeFenceEpoch.hs`, and `ForgeOperationAdvance.hs`
  (`ProjectPermit scope planId -> OperationAdvance scope planId ()`). Register each with "Illegal term-level use
  of the type constructor '<Type>'" for its own type. Drop the `PreparedGate` binding, which
  `ForgePreparedGate.hs` holds.

### Sprint 5.11: The session testing seam leaves the public surface [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/compile-fail/ForgeTransactionPermitFromDescriptor.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

The direct-provider testing seam is private precisely so downstream code cannot use it to mint a value
in the sealed column, and the session seam is private for the same reason. Its types mint no authority;
the bytes it renders are the coordinator's own, and a consumer that could write them could put the
store into a state no run produced.

#### Deliverables

- `HostBootstrap.Lifecycle.Session.Testing` and the transaction vocabulary it re-exports live in a private sublibrary, the pattern the package already uses five times.
- A compile-fail fixture pins that a downstream consumer cannot import it, naming the sublibrary that holds it.
- The suite that legitimately uses it depends on the private sublibrary directly.

#### Validation

The host static gate (`cabal test all` from `core/`), plus the fixture. Dated evidence: on 2026-09-12, x86_64
Ubuntu 24.04.4 LTS with GHC 9.12.4 and Cabal 3.16.1.0, `cabal build all` and `cabal test all` from `core/`
passed, with the fixture reporting the seam as a member of the hidden `lifecycle-transaction-internal`
sublibrary.

#### Remaining Work

None. Which modules the `lifecycle-transaction-internal` stanza exposes beside the seam is the session phase's
(phase 10).

### Sprint 5.12: Coordinate types at the prepared-gate boundary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Prepared/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Rooted/Node.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/FrameExecutor.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

§ HH states that a coordinate carried across a sealed boundary is a type. The prepared gate is the
smallest complete instance and the one the architecture page leads with: its producer takes three text
coordinates then three numeric ones, and the canonical renderer beside it has the same shape, so a
transposition would be invisible from mint to wire. This sprint is the pilot — one boundary, done
fully, so the cost of the remaining ones is judged from something real rather than estimated.

#### Deliverables

- Each coordinate role at this boundary is a newtype: the plan digest, the operation key, the session, the fence, the attempt, and the journal version.
- The rooted renderer's three further roles — the catalog identity, the frame, and the supersession generation — are newtypes too, so the generation that stands where a fence stands cannot be written in its place.
- The producer and the canonical renderer both take them, so the two cannot disagree about order.
- The fields, the accessors, and the framing are unchanged: no runtime representation changes and no durable byte changes. This is an argument-order proof, not a format change.

#### Objective boundary

What it cost: nine newtypes and one exported constructor each, four call sites wrapped, one round-trip
check inside the module wrapped, and two source guards re-stated against the new call shape. No
consumer of a gate changed, because the accessors still answer in the underlying types. That is the
price for one boundary of six-plus-three coordinates; the remaining sealed producers are not in this
sprint's scope.

#### Validation

The host static gate. The existing cases pin the canonical bytes, and they pass unchanged — which is
the evidence that the newtypes are a compile-time property only. Dated evidence: on 2026-09-12,
x86_64 Ubuntu 24.04.4 LTS with GHC 9.12.4 and Cabal 3.16.1.0, `cabal test all` from `core/` passed
2,517 tests.

#### Remaining Work

None.

### Sprint 5.13: Sealed export surfaces and fixture probes are pinned against the tree [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/SourceGuard.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/unrepresentable_state.md`, `documents/engineering/testing.md`

#### Objective

A compile-fail fixture that imports a name the tree never defines passes because that name is absent, not
because a live boundary holds. An exposed module that re-exports a sealed producer is caught only if some
fixture happens to probe that exact name, and an unregistered fixture is never compiled at all. This sprint
pins all three against the tree: every exposed module that imports a sealed witness's producer has its export
list pinned, every fixture file is registered once, and every registered fixture probes identifiers that exist.

#### Deliverables

- An export-surface guard pins the exact export list (`SourceGuard.moduleExportTokens`) of every exposed module
  in the main library stanza that imports a module listed in `other-modules` or a private sublibrary. The guard
  enumerates that set from `hostbootstrap-core.cabal` (`SourceGuard.mainLibraryStanza`,
  `SourceGuard.fieldModules`) and fails when such a module has no pinned list or when a pinned list changes.
  The set includes at least `HostBootstrap.Lifecycle.Context`, `HostBootstrap.Harness.Ownership`,
  `HostBootstrap.ProjectPlan.Construct`, `HostBootstrap.RegistryPlan`, `HostBootstrap.Lifecycle.Mode`, and
  `HostBootstrap.Lifecycle.Session`; the existing `authorityFacadeExports` and HandoffSpec guards count toward it.
- A registration-completeness check in `CompileFailSpec` asserts that every `.hs` file under `test/compile-fail`
  is registered exactly once (no unregistered file, no duplicate registration), that every registration names an
  existing file, and that every identifier and module named in a fixture's import lists is defined somewhere
  under `core/hostbootstrap-core/src` or `core/hostbootstrap-core/internal`.
- A stanza guard asserts that every `library <name>` stanza other than the main library carries
  `visibility: private`, because the compile-fail harness hides every non-main unit and so cannot see a
  sublibrary turned public.
- Each fixture the check flags is repointed at the live identifiers guarding the same boundary, or deleted when
  another registered fixture already holds that boundary.
- `OpenValidatedLifecycleContextAuthority.hs` imports `mintValidatedLifecycleContext` and
  `withValidatedRootLifecycleContext` from `HostBootstrap.Lifecycle.Context` and pins
  "Module 'HostBootstrap.Lifecycle.Context' does not export '<name>'" for each.
- `ImportRawHarnessCloseAction.hs` imports `newOwnedHarnessCloseControl` and `consumeOwnedHarnessClose` from
  `HostBootstrap.Harness.Ownership` and pins the does-not-export phrase for each; a new
  `ImportHarnessOwnershipInternal.hs` pins that `HostBootstrap.Harness.Ownership.Internal` is a hidden module.
- `OpenAuthenticatedChildCursorEvidence.hs` imports `mintChildPlanAuthorityKernel` and
  `childPlanAuthorityBindingKernel` from `HostBootstrap.ProjectPlan.Construct`, pins the does-not-export phrase
  for each, and its comment names `ChildPlanAuthority`.
- Speculative-name fixtures probe live names: `CallerFixedAuthenticatedRootScopeParser.hs` and
  `ImportInstalledProjectCompatibility.hs` are deleted (`EscapeAuthenticatedRootScopeRun.hs` holds the live
  root-scope boundary, and `HostBootstrap.Config.InstalledProject` never existed);
  `OpenRecoveryChildPackageDecoder.hs` imports `recoveryChildPackageFromWireKernel` from `HostBootstrap.Handoff`
  and pins its does-not-export phrase; `ImportDirectTeardownAdvance.hs` keeps only `authorizationPointKey`.

#### Validation

The host static gate (`cabal test all` from `core/`). The export-surface guard, the registration-completeness
check, and the stanza guard exist and pass. Each repointed fixture passes with its new phrase copied from actual
stderr. Re-exporting `mintValidatedLifecycleContext` from `HostBootstrap.Lifecycle.Context` turns both the
export guard and the fixture red (checked once by hand when the sprint closes, then reverted). On 2026-10-25, 39
of the 524 registered fixtures named identifiers absent from the tree (33 of them only absent identifiers);
closure requires that count to be zero.

#### Remaining Work

- Add the export-surface guard, the registration-completeness check, and the private-stanza guard described above.
- Repoint or delete the 39 fixtures the check flags, starting with the six named in Deliverables
  (`OpenRecordedBrokerEpoch.hs` is Sprint 5.4's).

### Sprint 5.14: The authority kernel hashes through Digest [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`
**Substrates**: none
**Docs to update**: `DEVELOPMENT_PLAN/system-components.md`

#### Objective

`HostBootstrap.Digest` exports the lowercase-hex `sha256Hex`, and the authority kernel derives its command
invocation names and `invocationKey` store keys with that export rather than with a byte-identical local copy,
so an invocation key recomputed elsewhere cannot drift from the one the kernel reserved.

#### Deliverables

- `Authority.Kernel` imports `sha256Hex` from `HostBootstrap.Digest` and defines no SHA-256 helper of its own.
- Every invocation name and `invocationKey` the kernel derives keeps the bytes `AuthoritySpec` pins.

#### Validation

`AuthoritySpec` passes unchanged inside `cabal test all --ghc-options=-Werror` from `core/`, and the host
static gate (§ JJ) passes.

#### Remaining Work

- Delete `sha256Hex` from `core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs` and import it from
  `HostBootstrap.Digest`.

## Remaining Work

- Sprint 5.2: add the identity length-bound cases, and thread the executable-verified identity into
  `reserveCurrentLifecycleCommandKernel` instead of re-minting it from the recorded project name.
- Sprint 5.3: add the private root-kernel test seam and the two-store foreign-principal case.
- Sprint 5.4: add the counter-deleted and counter-malformed recovery rows, the reifier caller-set guard, and
  repoint `OpenRecordedBrokerEpoch.hs`.
- Sprint 5.5: add the cross-store and cross-project epoch-origin cases, and rename the root verb/scope case.
- Sprint 5.6: add the root-scope projection field-mapping case.
- Sprint 5.7: add the two-store `commandAuthorityMatchesStore` case, and delete the never-produced
  `AuthorityUnknownFrame` with a produced-constructor guard.
- Sprint 5.8: extend the private kernel seam with the reservation kernels, add the kernel-level reservation
  cases and the two-process reservation probe, replace the replay-eligibility wildcard, and rewrite the import
  guards over every main-library source directory with a transitive closure resolved across every library
  stanza, read through `SourceGuard`.
- Sprint 5.9: make `withRestoredFiles` delete originally absent siblings and add its two cases.
- Sprint 5.10: repair the kind-error, split, under-pinned, and two-error fixtures (including one fixture per
  type forged in `ForgeSessionPermit.hs`), compile fixtures without caret excerpts, match per diagnostic block,
  and take `NonEmpty String`.
- Sprint 5.13: add the export-surface, registration-completeness, and private-stanza guards, and repoint or
  delete the 39 fixtures that probe absent names.
- Sprint 5.14: `Authority.Kernel` takes `sha256Hex` from `HostBootstrap.Digest`.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/binary_context_config.md` — installed identity, OS evidence, root scope, and the
  reservation kernel beneath proof-complete command gates.
- `documents/architecture/lifecycle_state_model.md` — the composite lifecycle transaction that alone scopes a
  root and the later consumers of `CommandAuthority`.
- `documents/architecture/unrepresentable_state.md` — compile-fail fixture discipline, the export-surface and
  registration guards, and the coordinate types at the prepared-gate boundary.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — compile-fail/export/import guards and the cross-process reservation race.

**Cross-references to add:**
- `development_plan_standards.md` § X and § EE name this phase as the owner of the lower authority vocabulary;
  Phases 9, 12, 13, 17, and 18 own its proof-complete lifecycle consumers.
