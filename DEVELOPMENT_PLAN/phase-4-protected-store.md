# Phase 4 — Protected store

**Status**: Done
**Depends on**: Phase 3 (host tools and substrate detection)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-06 ; arm64 macOS 26.6.2 (build 25G83), GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --ghc-options=-Werror` ; pass ; covers in-gate
**Gate evidence**: 2026-10-26 ; `hostbootstrap-core-gate-20261026`, x86_64 Ubuntu 24.04.4 CPU-only container on WSL2 Linux 6.18.33.2, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --test-options=--hide-successes` from `core/` ; pass ; covers in-gate
**Gate evidence**: 2026-10-26 ; `DESKTOP-R6BTBVS`, native x86_64 Windows 11 10.0.26300.9457, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --test-options=--hide-successes` from `core/` and `demo/`, `poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all` from the root ; pass ; covers in-gate

> **Purpose**: Provide the one durable, exclusively entered, versioned record store every later ownership,
> authority, and lifecycle decision is made inside.

## Phase Objective

Everything above this phase needs to make a decision that survives a crash and cannot be raced: take a
mode, bind a lease, publish an origin record. That needs a store with three properties — exclusive entry
released by the kernel when a process dies, records with versions so a decision can compare-and-swap, and
durability: a published record survives the death of the writing process and of the host. This phase is
that store and nothing else; it knows nothing about what is recorded in it.

## Sprints

### Sprint 4.1: Exclusive entry and versioned records [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`, `documents/engineering/testing.md`

#### Objective

One exclusive entry, one versioned record type, one compare-and-swap.

#### Deliverables

- `openProtectedStore` yields an opaque `ProtectedStore` at the supplied absolute directory; its caller
  places that directory under the canonical project root. The
  `ProtectedStore`, `ProtectedStoreIdentity`, `ProtectedSession`, and `RecordKey` constructors are private
  to `HostBootstrap.Protected`, which the public library re-exports, so a consumer cannot forge any of them.
- `withProtectedEntry` runs a continuation inside the store's exclusive entry, which the **kernel** releases
  if the process dies part-way through — a lock a dead process still holds is not a lock. A nested
  `withProtectedEntry` or `tryProtectedEntry` from the holding thread is refused with `ProtectedInvalid`
  ("not re-entrant") instead of deadlocking. `tryProtectedEntry` never blocks: it returns `Right Nothing`
  when another process or another thread of this process holds the entry.
- `ProtectedSession` has a private constructor and nominal session index. Its per-entry token names the
  holding thread and is revoked before unlocking. Every record operation and the writable-store probe
  require that live token on its owner thread. Rank-2 provenance alone does not prevent an ordinary IO
  closure retaining a session; a retained action outside its extent, inside a later entry, or on another
  thread returns `ProtectedInvalid` before IO, so it cannot straddle transactions.
- `RecordKey` is validated on construction, so a key cannot shift the meaning of the fields after it.
- `mkRecordName` is the one **injective** encoding from a namespaced identity — or a `/`-separated path of
  them, which is what a relation between operations is — into that alphabet, and `recordNameIdentity` is its
  total inverse on the image. A namespaced segment `ns:token` encodes as `ns.token`, path segments join with
  `..`, and `recordNameSegment` refuses every segment whose encoding could hold `..` or end in `.`: a plain
  segment containing `.`, a namespace containing `.`, a token that begins or ends with `.`, any raw `..`,
  an empty segment, namespace, or token, and a second `:`.
- `compareAndSwapProtectedRecord` and `compareAndDeleteProtectedRecord` take an `Expectation`
  (`ExpectAbsent` or `ExpectVersion`), so every write states what it believed; `readProtectedRecord`
  returns the observed version or absence the caller then states.
- `listProtectedRecords` enumerates at one store version, so a fold sees a consistent set.
- A malformed record is a typed `ProtectedMalformedRecord`, never silently ignored: a missing header
  terminator, an unknown magic, a version that is not a positive integer, and a header that is not exactly
  `<magic> <version>` are each refused with their own reason.

#### Validation

The complete core gate executes these cases:

- `AuthoritySpec` store cases: the record round-trip, each expectation branch of compare-and-swap, and
  the out-of-process contention probe (`--hostbootstrap-protected-entry-probe`) that proves a second entry
  is excluded while the first is held.
- `AuthoritySpec` "a conditional delete removes only the observed version": the delete with the stale
  version returns `Left (ProtectedVersionMismatch _ (Just stale) (Just current))` and the record reads back
  as `"two"`; the delete with the current version then returns `Right ()` and `readProtectedRecord` reads
  back `Right Nothing`.
- `AuthoritySpec` "a key that could escape the store is rejected": besides `"../escape"`, `""`, and
  `".hidden"`, the separator-bearing keys `"a/b"`, `"x/../../escape"`, `"a\\b"`, and `"C:x"` — none empty,
  none starting with `.` — each return `Left (ProtectedInvalid reason)` whose `reason` contains
  "may contain only", so the case fails if the alphabet guard is deleted or loosened.
- `AuthoritySpec` "the protected entry refuses re-entry from its holder": inside `withProtectedEntry`, both
  a nested `withProtectedEntry store` and a nested `tryProtectedEntry store` return
  `Left (ProtectedInvalid _)` whose text contains "not re-entrant"; the case runs under `timeout` so a
  regression to a deadlock fails instead of hanging the suite.
- `AuthoritySpec` "an in-process peer thread sees the held entry as contention": a `forkIO` thread holds
  `withProtectedEntry` until signalled; `tryProtectedEntry` from the main thread returns `Right Nothing`
  under `timeout`, and after release returns `Right (Just ())`.
- `AuthoritySpec` "every malformed record header is refused": records written directly as `garbage`,
  `xxxx 1\nbody`, `hbps1 0\nbody`, `hbps1 -3\nbody`, `hbps1 x\nbody`, `hbps1\nbody`, and
  `hbps1 1 2\nbody` each read back as `ProtectedMalformedRecord` with the reason for its branch.
- `AuthoritySpec` "record names refuse every ambiguous segment" and "record names are injective and
  invertible" (below).
- `AuthoritySpec`: retained read/write/delete/list/writable-probe IO actions refuse after their entry
  ends and during a later entry on the same thread. A foreign thread also refuses a currently live
  session. Each case checks the records and store files remain unchanged.
- `CompileFailSpec`: `CoerceProtectedSession.hs` rejects relabelling the nominal session index.
- `CompileFailSpec` rejects `ForgeProtectedSession.hs`, `ForgeRecordKey.hs`, `ForgeProtectedStore.hs`, and
  `ForgeProtectedStoreIdentity.hs`, each with GHC's "Illegal term-level use of the type constructor" diagnostic.

`AuthoritySpec` additionally passed "escaped protected IO actions are refused after entry exit", "a
later entry cannot revive escaped protected IO actions", and "a live protected session refuses
record operations from a foreign thread". Retained actions after successful nonblocking entry, IO
exceptions and asynchronous interruption also refuse before IO. Constructor and nominal-session
compile-fail fixtures passed with their pinned diagnostics.

Validated on 2026-10-26 in the complete Linux CPU and native Windows core gates recorded above.

#### Remaining Work

None.

### Sprint 4.2: The run-liveness lock [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Make "the owner of this record is still alive" an observable fact.

#### Deliverables

- `withRunLiveness` takes a project-wide lock and holds it for the caller's whole run, not just one
  transaction. The lock's name is validated with the `mkRecordKey` alphabet before any file is opened, so
  `<store>/liveness/<name>.lock` is always one file inside the store's `liveness` directory; a name that
  fails validation is `ProtectedInvalid` and the body does not run.
- The lock is kernel-released, so a genuinely dead predecessor never blocks a successor. Acquisition runs
  under `mask`, so an asynchronous exception arriving between `hTryLock` and the body closes the handle
  instead of leaving the lock held until finalization.
- Every protected-store and run-liveness lock handle is non-inheritable across an executed child. A provider
  daemon may outlive its launcher, but cannot retain the launcher's project-liveness or store-entry lock.
- This is the primitive that makes an abandoned-record sweep sound. Without it a live owner's record is
  indistinguishable from a dead one's, and a starting run can take a project another run still owns — see
  [rationale.md](rationale.md).
- A live holder refuses the peer *before* the peer acquires anything.

#### Validation

`AuthoritySpec` "run liveness is close-on-exec and cannot be retained by a provider child" launches a real
executed child that remains alive after its parent leaves the liveness extent, and asserts that immediate
reacquisition succeeds. On 2026-08-26 on aarch64 macOS it passed in the 113-case `AuthoritySpec` group, and
the complete core host-static gate passed 2,462/2,462 under `-Werror` in 433.14 seconds.

The complete core gate executes these cases:

- `AuthoritySpec` "a live liveness holder refuses an out-of-process peer": while the parent is inside
  `withRunLiveness store "peer-probe"`, the re-invoked probe exits 3 (`Right Nothing`); after the parent's
  extent ends, the same probe exits 0 (`Right (Just ())`).
- `AuthoritySpec` "a liveness name that could escape the store is refused": `withRunLiveness` with
  `"../escape"`, `"a/b"`, an absolute path, and `""` each returns `Left (ProtectedInvalid _)`, the body does
  not run, and no `.lock` file exists outside `<root>/liveness`.
- `AuthoritySpec` "an interrupted liveness extent releases its lock": `timeout` around
  `withRunLiveness store "interrupted" (threadDelay 10000000)` returns `Nothing`, and a following
  `withRunLiveness store "interrupted" (pure ())` returns `Right (Just ())`; the same reacquisition holds
  after each of 200 iterations of `timeout` with a delay of 0 to 199 microseconds around
  `withRunLiveness store "interrupted" (pure ())`.

`AuthoritySpec` also passed "liveness body exceptions propagate unchanged and release the lock"; the
peer probe, invalid-name no-body cases, close-on-exec child, timeout and 200 interrupted
acquisitions all ran.

Validated on 2026-10-26 in the complete Linux CPU and native Windows core gates recorded above.

#### Remaining Work

None.

### Sprint 4.3: Store identity binding [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Kernel.hs`, `core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Bind a store to the project that owns it. `HostBootstrap.Protected` supplies the store's durable identity
and nothing else; the binding record and both refusals live in `HostBootstrap.Authority.Kernel`, which
interprets records this store holds.

#### Deliverables

- `protectedStoreIdentityText` and `sessionStoreIdentity` expose the store's own identity.
- `HostBootstrap.Authority.Kernel` writes the `authority.binding` record with `ExpectAbsent` on first
  authorized use; a store whose binding names a different project is refused with `AuthorityStoreNotOurs`
  rather than shared.
- An authorization issued against one store cannot be presented to another: the authority kernel's
  records and reservations carry the issuing store's `protectedStoreIdentityText`, and a session on a
  different store refuses it before any record changes.

#### Validation

`AuthoritySpec` "a store already bound to another project refuses this one" covers the binding and the
cross-project refusal; "a malformed authority binding refuses root admission" covers a corrupt binding; and
"pre-effect Production closure refuses another protected store" covers the cross-store refusal, asserting
the second store's record set is unchanged.

Validated on 2026-10-26 in the complete Linux CPU and native Windows core gates recorded above.

#### Remaining Work

None.

### Sprint 4.4: Versioned, injective record-name encoding [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Give case-bearing identities one injective encoding and distinguish the new encoding from historical
rows before any row can be interpreted. The original record-name sprint is split here, before its
implementation, because its producer inventory exceeds § G's three-module production cap.

#### Deliverables

- `mkRecordName` escapes every ASCII uppercase letter `C` as `_c` and literal `_` as `__`, before joining
  the existing namespace/path separators. `recordNameIdentity` decodes those escapes as well as the
  separators and stays the total inverse on the admitted image.
- `recordTupleSeparator` is `...`, which cannot occur in any `mkRecordName` image: encoded segments
  contain no adjacent/edge dots and path separators contain exactly two. Producers framing several
  already encoded identities use this one separator and decode each component independently.
- `mkRecordSegment` admits one scalar identity through the same segment codec and refuses `/`, so a
  runtime field cannot introduce another path component. `mkRecordName` retains full identity-path
  admission. Namespaced tokens still refuse leading/trailing dots and adjacent dots; a plain segment
  still refuses dots. Callers encode identity components in their declared namespaces before joining fixed structure,
  rather than passing an already assembled dotted record key to `mkRecordName`.
- The store identity envelope carries an explicit key-encoding version. Opening refuses an old,
  unrecognized, empty, or missing envelope over populated records with `ProtectedInvalid`, before
  interpreting or mutating records. A new store publishes the current version exactly once under its
  entry; reopening preserves its identity.
- Historical `_b` can be either an old literal underscore name or the new uppercase `B` encoding, so
  neither a fallback lookup nor a generic filename migration is admitted. Incompatible rows remain
  intact for an owner-aware recovery; absence of the new key never licenses fresh acquisition over them.
- No claim of cross-family acceptance is owed here: § C closes this baseline phase on its declared Linux
  CPU gate. The same host-portable cases run in the Windows static gate here, and macOS confirmation is
  owned by the host-portability acceptance phase's declared gate.

#### Validation

Under `cabal test all` from `core/`, `AuthoritySpec` proves `project:Build` and `project:build` differ
under `Text.toLower`, `a_b` and `aB` differ, both pairs round-trip, and separate records retain their own
bytes. The Sprint 4.1 exhaustive one/two-segment enumeration extends its alphabet to `ab.:A_` and still
finds no shared encoding. New/reopened stores retain one current-format identity. Legacy identity,
unknown/empty identity, and identity-less populated-store fixtures return the exact typed refusal and
preserve all file bytes; no old-key fallback is probed.

`AuthoritySpec` passed "record names are injective and invertible", "case-variant identities keep
separate durable records", "incompatible store identities refuse without changing any file", and "a
current identity envelope preserves its opaque nonce". Exhaustive admitted identities include
uppercase and literal underscores; incompatible identity images preserve all original bytes.

Validated on 2026-10-26 in the complete Linux CPU and native Windows core gates recorded above.

#### Remaining Work

None.

### Sprint 4.4a: Authority, mode and session key producers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/authority/HostBootstrap/Authority/Kernel.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Mode.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Session.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`, `core/hostbootstrap-core/test/SessionSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Keep every authority, project, run and operation identity distinct through its record-key producers and
through the prefix scanners that recover those records.

#### Deliverables

- Every case-bearing component in these three modules goes through the canonical `mkRecordName` codec;
  scanners use the same encoded prefix and decode identity components through `recordNameIdentity`.
  Full-identity tuple fields use `recordTupleSeparator`, so namespace/path delimiters within a field
  cannot collide with the boundary between fields.
- Fixed lowercase keys, canonical hashed components, and already serialized `RecordKey` values are not
  encoded a second time.
- `parseRunKey` admits only the ASCII identity grammar that its record names can represent; malformed
  durable identities refuse through the mode error type before constructing a key.
- Encoded keys keep the 200-byte bound. Invalid or overlong values return the owning domain's typed
  refusal before durable effects, never truncation, lossy filtering, an unhandled partial constructor,
  or an old-name fallback.

#### Validation

The authority/mode/session behaviour cases pass with uppercase and underscore project/operation
identities, exact inverse prefix recovery and distinct records. ASCII run admission and a non-ASCII
malformed durable run are pinned, and oversized encoded-key refusal preserves records.

`AuthoritySpec` passed "actual case and underscore executable identities retain exact broker and
mode records", "durable ASCII runs recover their exact decoded case", and "a durable non-ASCII run
refuses before key construction and body entry". The copied executables include the
64-uppercase-character boundary and pin the legitimate profile row. `SessionSpec` passed "session
and operation tuple fields recover exact independent identities" and both invalid/oversized-address
cases with unchanged durable images.

Validated on 2026-10-26 in the complete Linux CPU and native Windows core gates recorded above.

#### Remaining Work

None.

### Sprint 4.4b: Harness, snapshot and role liveness key producers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Snapshot.hs`,
`core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`,
`core/hostbootstrap-core/test/HarnessSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/RoleLifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/architecture/lifecycle_state_model.md`

#### Objective

Make Harness/config ownership and every run-liveness lock consume the same identity encoding.

#### Deliverables

- Harness data/config and project-plan snapshot keys encode their case-bearing components before fixed
  separators; scanners/recovery decode those components through the same canonical inverse.
- Every `withRunLiveness` caller supplies an encoded legal name. Role service/frame liveness no longer
  uses `Text.filter` as an identity sanitizer: distinct admitted identities remain distinct.
- Typed invalid/overlong refusals precede effects, and no historical raw-key fallback is attempted.

#### Validation

`HarnessSpec` passed "real case and underscore project identities keep exact origin records and
recovery", using actual copied executables, persisted snapshots and hard-kill recovery.
`ProjectPlanSpec` passed the source-order case "reverse-root Snapshot selection is strict,
liveness-scoped, and caller-sealed"; this is structural evidence for the reverse selector.
`RoleLifecycleSpec` passed its case/underscore and tuple-boundary lease cases and "invalid role
lease names refuse before callbacks or record changes", using genuinely signed service/frame
identities. Harness project/run inputs are already bounded; the invalid/expanded-overlong runtime
refusals are the Role cases. Eight `CLISpec` Harness runtime cases now own fresh temporary working
directories and preserve historical stores under the original cwd.

Validated on 2026-10-26 in the complete Linux CPU and native Windows core gates recorded above.

#### Remaining Work

None.

### Sprint 4.4c: Runtime cluster, exposure and provider key producers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`, `core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Keep cluster/node/exposure and provider instance/share names distinct even when they contain case,
underscores or permitted internal dots.

#### Deliverables

- Scalar components enter `mkRecordSegment` through the canonical `mkRecordName` codec in their
  declared namespaces; assembled dotted keys are never treated
  as plain identity segments. Two component tuples that concatenate to the same raw dotted text remain
  distinct after encoding.
- Provider share recovery removes the encoded instance prefix and decodes the device component through
  `recordNameIdentity`; a raw instance-name length is never used to slice encoded text.
- Invalid or oversized names return the existing typed ownership/backend refusal before writes, without
  truncation or legacy-key adoption. Already hashed/fixed keys retain their meaning.

#### Validation

Cluster/node, exposure and provider cases cover uppercase, underscore and internal-dot names, tuple
boundary collisions, exact share-device recovery and refused oversized inputs with unchanged records.
The existing runtime ownership behaviour suites pass.

`ClusterOwnershipSpec` passed "case and tuple variants keep independent cluster and node records"
and "an oversized node address publishes no partial origin records". `ClusterBackendSpec` passed "an
invalid or expanded exposure address creates no store". `ProviderBackendSpec` passed "provider
instance and device tuple boundaries cannot share a record", "retained provider deletion recovers
literal case, dot and underscore device identities", and "retained provider deletion refuses a
noncanonical device record key", preserving the neighboring instance rows.

Validated on 2026-10-26 in the complete Linux CPU and native Windows core gates recorded above.

#### Remaining Work

None.

### Sprint 4.4d: Provider transaction address preflight [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Refuse invalid provider-share addresses before opening the store, rather than opening a valid instance
transaction and only then discovering its share key cannot be represented. This fourth producer module
is split from Sprint 4.4c to keep each production group inside § G's three-module ceiling.

#### Deliverables

- The complete instance/share key is validated before `openProtectedStore` and before any driver or
  ownership effect; successful transactions use exactly that canonical key.
- Oversized escaped device names and invalid scalar names return the existing typed refusal, create no
  store metadata, and run no provider mutation. Valid transactions keep the same clause-holding route.

#### Validation

The public backend spec constructor refuses invalid/oversized instance names before IO, and the public
record-key factories refuse invalid/expanded share addresses. Prepared public share calls derive a fixed
bounded lowercase hash device, so arbitrary invalid device strings cannot honestly reach the private
transaction. A lexical source guard therefore pins complete share-address admission before store opening,
without a test-only execution entry. Real valid-share lifecycle/recovery tests exercise the unchanged
production transaction route.

`ProviderBackendSpec` passed "provider share address admission precedes every store-opening route",
"invalid provider instance addresses refuse before creating store metadata", and the real
valid-share lifecycle/recovery cases. The first is a lexical ordering guard; arbitrary invalid
device text remains unreachable through the bounded public prepared-share constructor.

Validated on 2026-10-26 in the complete Linux CPU and native Windows core gates recorded above.

#### Remaining Work

None.

### Sprint 4.4e: The final filesystem-safe key alphabet [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

After every identity producer uses the canonical codec, make the key constructor enforce names that
are distinct on all supported filesystems.

#### Deliverables

- `mkRecordKey` admits only ASCII lowercase letters, ASCII digits, `-`, `_` and `.`, with at most 200
  bytes. Uppercase, non-ASCII letters/digits, leading dots and trailing dots are `ProtectedInvalid`.
- The prefix before the first dot cannot be a Windows reserved device name: `con`, `prn`, `aux`, `nul`,
  `com1`-`com9` or `lpt1`-`lpt9`.
- Trailing dots are refused because Windows otherwise aliases `a` with `a.`; lowercase alone does not
  satisfy the filesystem-distinct objective.

#### Validation

`AuthoritySpec` refuses `Alpha`, `é`, `٣`, `nul`, `CON`, `com1.rec`, `a.`, and an overlong ASCII key;
it admits `alpha-1_b.c` and a legal 200-byte boundary key. The exhaustive codec and separate-record
cases pass unchanged. The complete core gate verifies every migrated caller under the stricter key
constructor; cross-family confirmation remains the phase 29 acceptance obligation.

`AuthoritySpec` passed "record keys are ASCII, case-free and filesystem-distinct" and the
scalar/path-injection, exhaustive codec, separate-record and maximum-length boundary cases.

Validated on 2026-10-26 in the complete Linux CPU and native Windows core gates recorded above.

#### Remaining Work

None.

### Sprint 4.4f: Production transaction target identity framing [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Transaction.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`, `core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/lifecycle_state_model.md`

#### Objective

Make the transaction target validator consume the same encoded project/run tuples as the mode
producer. This additional consumer is split before its implementation to keep the producer groups
inside § G's three-module production cap.

#### Deliverables

- Production lease targets use the canonical tuple separator; reverse-intent targets retain their
  fixed `.production` suffix. Both use the exact encoded project identity. Mode, lease and intent
  targets must still name one exact project generation.
- Historical raw separators, noncanonical identity suffixes and mixed project targets refuse; there is
  no old-key fallback and no weakening of transaction expectation or payload validation.
- Session target plan membership uses the canonical tuple boundary, so a historical single-dot or
  prefix-shaped target cannot be adopted by an otherwise matching plan.

#### Validation

`SessionSpec` persists interrupted descriptors through the existing private descriptor seam and
recovers through the ordinary journal reader. Both Production kinds recover for `Build`, `build`,
`a_b` and `aB`, checking exact target bytes, mode deletion and the committed coordinator. Mixed lease
or intent identities, noncanonical mode suffixes and historical lease/session separators refuse with
the complete record image unchanged. The real Production closure, Down/Destroy, interruption recovery
and recursive lifecycle cases also run in the complete gate.

All 14 new `SessionSpec` descriptor cases passed, including "a case-mixed lease target refuses
before materialization", "an underscore-mixed lease target refuses before materialization", "a mixed
reverse-intent target refuses before materialization", and both historical-separator refusals.
Production closure, public Down/Destroy, and the Linux recursive/interruption families passed;
Windows recorded the declared platform refusals for the POSIX-only recursive/interruption families.

Validated on 2026-10-26 in the complete Linux CPU and native Windows core gates recorded above.

#### Remaining Work

None.

### Sprint 4.5: Published records survive host power loss [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

`publishBytes` writes a temporary, `hFlush`es it, and renames it over the destination. That is atomic
against the death of the process, because the bytes are already in the kernel, but not against an OS crash
or power loss, where the rename can reach the disk before the data and leave an empty `<key>.rec` or an
empty `store.identity`. This sprint makes the store's durability claim hold for the host, using the same
primitives `HostBootstrap.Ownership.Posix` and `HostBootstrap.Ownership.Windows` already use.

#### Deliverables

- `publishBytes` syncs the temporary's data to disk before the rename: `fileSynchronise` on a writable
  descriptor on POSIX, followed by Darwin's `F_FULLFSYNC` device-cache flush on macOS, and a write-through
  or `FlushFileBuffers` handle on Windows. A failed requested flush refuses rather than falling back to
  a weaker guarantee.
- On POSIX `publishBytes` syncs the parent directory after the rename; Darwin then requests a full
  device flush through the published regular file's writable descriptor, avoiding an unsupported
  directory-ioctl assumption. Durability assumes the filesystem/device honor their successful flush requests.
  Apple's documented distinction between fsync and full device flush is part of this introducing contract,
  not a later correction. Cross-family runtime confirmation belongs to phase 29's declared gate.
- Windows publishes through `MoveFileEx` with replacement and the SDK's write-through flag, excluding
  copy-across-volume behavior. Its private path handling retains absolute local/UNC long-path support.
  POSIX retains atomic `renameFile` within the same directory.
- The cleanup that removes the temporary covers the whole write, sync, and rename sequence, so a failed
  write leaves no `<key>.rec.tmp-<hex>` behind.
- The module header states exactly this guarantee: after a process death, OS crash, or power loss a record
  is the old one or the complete new one.

#### Validation

The complete core gate executes these cases:

- `AuthoritySpec` source-guard case "publishBytes syncs before it renames and cleans up every failure":
  the body of `publishBytes` calls the platform sync primitive before the atomic platform rename, calls the
  parent-directory sync after it on POSIX, and places the temporary's creation, write, sync, and rename
  under the one handler that removes the temporary.
- The existing record round-trip and compare-and-swap cases pass unchanged, and after them `records/` holds
  no entry containing `.rec.tmp-`. A real 200-byte-key round-trip under a long temporary root preserves
  Windows extended-path publication support.

Neither power loss nor a mid-write disk failure is reproducible through the store's public API in the
host static gate, so the source-guard case holds ordering and cleanup scope, including the Darwin
full-device-flush call. [Apple's fsync manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html)
explains why plain fsync does not itself request that drive-cache guarantee; its
[fcntl manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html)
defines F_FULLFSYNC. Microsoft's
[MoveFileEx documentation](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw)
defines the write-through rename request. The gate claims these implemented barriers and exercised record behaviour, not a
simulated power-loss experiment.

The complete gates passed on 2026-10-26: Linux CPU core 2,701/2,701 in 391.63 seconds; native
Windows core 2,694/2,694 in 491.67 seconds; the demo workspace 164/164 demo cases in 5.87 seconds
plus 2,694/2,694 core cases in 504.42 seconds. Both Python legs passed, with 376 tests in 7.32
seconds and 100% coverage of 1,585 statements and 460 branches. The full suite includes the real
maximum-length key beyond MAX_PATH, complete CAS/read/reopen behaviour and publication-order source
guards. No physical power-loss experiment or macOS runtime confirmation is claimed.

Validated on 2026-10-26 in the complete Linux CPU and native Windows core gates recorded above.

#### Remaining Work

None.

## Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/ownership_invariant.md` — exclusive entry and the liveness lock as clause 1's primitive.
- `documents/architecture/lifecycle_state_model.md` — versioned records and store identity binding.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the out-of-process contention probes and why they are not
  `os(windows)`-gated.

**Cross-references to add:**
- `development_plan_standards.md` § EE names this phase as the supplier of clause 1's primitive.
- [rationale.md](rationale.md) explains why liveness must precede any sweep.
