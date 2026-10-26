# Phase 4 — Protected store

**Status**: Active
**Depends on**: Phase 3 (host tools and substrate detection)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-06 ; arm64 macOS 26.6.2 (build 25G83), GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --ghc-options=-Werror` ; pass ; covers in-gate

> **Purpose**: Provide the one durable, exclusively entered, versioned record store every later ownership,
> authority, and lifecycle decision is made inside.

## Phase Objective

Everything above this phase needs to make a decision that survives a crash and cannot be raced: take a
mode, bind a lease, publish an origin record. That needs a store with three properties — exclusive entry
released by the kernel when a process dies, records with versions so a decision can compare-and-swap, and
durability: a published record survives the death of the writing process and of the host. This phase is
that store and nothing else; it knows nothing about what is recorded in it.

## Sprints

### Sprint 4.1: Exclusive entry and versioned records [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`, `documents/engineering/testing.md`

#### Objective

One exclusive entry, one versioned record type, one compare-and-swap.

#### Deliverables

- `openProtectedStore` yields an opaque `ProtectedStore` rooted under the canonical project root. The
  `ProtectedStore`, `ProtectedStoreIdentity`, `ProtectedSession`, and `RecordKey` constructors are private
  to `HostBootstrap.Protected`, which the public library re-exports, so a consumer cannot forge any of them.
- `withProtectedEntry` runs a continuation inside the store's exclusive entry, which the **kernel** releases
  if the process dies part-way through — a lock a dead process still holds is not a lock. A nested
  `withProtectedEntry` or `tryProtectedEntry` from the holding thread is refused with `ProtectedInvalid`
  ("not re-entrant") instead of deadlocking. `tryProtectedEntry` never blocks: it returns `Right Nothing`
  when another process or another thread of this process holds the entry.
- A `ProtectedSession` exists only inside that continuation and is the sole capability for reading or
  writing records, so no record operation can straddle two transactions.
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

Closure requires these cases to exist and pass in `cabal test all` from `core/`:

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
- `CompileFailSpec` rejects `ForgeProtectedSession.hs`, `ForgeRecordKey.hs`, `ForgeProtectedStore.hs`, and
  `ForgeProtectedStoreIdentity.hs`, each with GHC's "Illegal term-level use of the type constructor" diagnostic.

#### Remaining Work

- `Protected.hs` `recordNameSegment`: refuse a namespaced token that begins or ends with `.` with
  `ProtectedInvalid`. Today `mkRecordName "a:.b"` and `mkRecordName "a/b"` both encode as `a..b`, and the
  encoding of `"a:b./c"` decodes as `a:b/:c`. Add the dot-edged token rule to the `mkRecordName` Haddock's
  injectivity bullets, whose "no segment may contain `..`, so an encoded segment holds no adjacent pair of
  dots" argument omits the `.` the encoding inserts beside a dot-edged token; the `recordNameIdentity`
  Haddock's "total inverse of `mkRecordName` on its image" holds once the refusal lands. Add the
  `AuthoritySpec` table case "record names refuse every ambiguous segment" over `""`, `"a//b"`, `"/a"`, `"a/"`, `"a.b"`, `"a.b:c"`, `":b"`, `"a:"`,
  `"a:.b"`, `"a:b."`, `"a:b./c"`, `"a:b..c"`, `"a:b:c"`, and `"a b"`, each `Left (ProtectedInvalid _)`.
  Add "record names are injective and invertible": enumerate every one- and two-segment path whose segments
  are strings of length 1 to 3 over `a`, `b`, `.`, `:`; for every input `mkRecordName` admits, assert
  `recordNameIdentity` of the encoding returns the input and that no two distinct admitted inputs share an
  encoding.
- `Protected.hs` `tryStoreLock`: take the in-process mutex with `tryTakeMVar` (restored by `bracket` under
  `mask`) instead of the blocking `withMVar`, and return `Nothing` when another thread holds it, so the
  `tryProtectedEntry` Haddock's "another process (or another thread of this one) holds it" `Nothing` case
  and its "without blocking" claim hold. Add the `AuthoritySpec` thread-contention case and the re-entry refusal case described in Validation.
- `AuthoritySpec`: add the malformed-header table case described in Validation.
- `AuthoritySpec` "a conditional delete removes only the observed version": replace the bare `isLeft` on the
  stale delete with a match on `ProtectedVersionMismatch` carrying the stale expected and current observed
  versions, then delete with `ExpectVersion` of the current version and assert `Right ()` followed by a
  `readProtectedRecord` of `Right Nothing`, so a `compareAndDeleteProtectedRecord` that never deletes fails
  the store-level case.
- `AuthoritySpec` "a key that could escape the store is rejected": add `mkRecordKey` refusals for `"a/b"`,
  `"x/../../escape"`, `"a\\b"`, and `"C:x"`, each matched as `Left (ProtectedInvalid reason)` with
  "may contain only" in `reason` rather than `isLeft`, since the existing three keys are also refused by the
  empty-key and leading-dot guards and do not pin the alphabet guard.
- `test/compile-fail/`: add `ForgeRecordKey.hs` (applies `RecordKey` to `"../../x"`), `ForgeProtectedStore.hs`
  (applies `ProtectedStore` to its fields), and `ForgeProtectedStoreIdentity.hs`, and register each in
  `CompileFailSpec` beside `ForgeProtectedSession.hs` with the "Illegal term-level use of the type
  constructor" diagnostic.
- `documents/engineering/testing.md`: state that the protected-store contention and liveness probes use
  `base`'s `hLock`/`hTryLock` (`flock`/`fcntl` on POSIX, `LockFileEx` on Windows) through the suite's own
  re-invocation route, which is why they carry no `os(windows)` condition.

### Sprint 4.2: The run-liveness lock [Active]

**Status**: Active
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

Closure additionally requires these cases to exist and pass in `cabal test all` from `core/`:

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

#### Remaining Work

- `AuthoritySpec`: add `runLivenessProbe storeRoot name` (exit 0 when `withRunLiveness` returns
  `Right (Just ())`, 3 on `Right Nothing`, 4 on `Left`), dispatch it from `test/Spec.hs` on
  `--hostbootstrap-liveness-probe <root> <name>` beside `--hostbootstrap-protected-entry-probe`, and add the
  out-of-process live-refusal case described in Validation.
- `Protected.hs` `withRunLiveness`: validate the name through `mkRecordKey` before creating the directory or
  opening the lock file, returning `Left (ProtectedInvalid _)` without running the body; add the
  escaping-name case described in Validation.
- `Protected.hs` `withRunLiveness`: acquire under `mask`, closing the handle on the not-taken branch and on
  any exception before the body, and run the body under `restore` with `finally hClose`; catch only the
  acquisition's `IOError`, so the body's own exceptions still propagate unchanged. Add the
  interrupted-extent case described in Validation.

### Sprint 4.3: Store identity binding [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Authority/Kernel.hs`, `core/hostbootstrap-core/test/AuthoritySpec.hs`
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

#### Remaining Work

None.

### Sprint 4.4: Record names are distinct on every supported filesystem [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

A record key is a file name, and the default filesystems of Windows (NTFS) and macOS (APFS) compare names
case-insensitively, so two keys that differ only in case name one `<key>.rec`. A step identity admits
`A`-`Z`, so a plan with steps `Build` and `build` puts two operation journals in one file. This sprint makes
the key alphabet itself distinct under ASCII case folding and byte-bounded, so "two distinct identities
never share one durable record" holds on every host the static gate runs on.

#### Deliverables

- `mkRecordKey` admits only ASCII lowercase letters, ASCII digits, `-`, `_`, and `.`, so the 200-character
  cap is also a 200-byte cap and no key depends on the locale's file-name encoding; an uppercase or
  non-ASCII character is `ProtectedInvalid`.
- `mkRecordKey` refuses a key whose text before its first `.` is a Windows reserved device name (`con`,
  `prn`, `aux`, `nul`, `com1`-`com9`, `lpt1`-`lpt9`).
- `mkRecordName` encodes case injectively into that alphabet: each ASCII uppercase letter `C` becomes `_c`
  and each literal `_` becomes `__`, so its image holds no uppercase letter, and `recordNameIdentity`
  decodes both escapes and stays the total inverse on the image.
- Every direct `mkRecordKey` caller whose key text derives from a case-bearing identity routes that identity
  through `mkRecordName` first.

#### Validation

Closure requires these cases to exist and pass in `cabal test all` from `core/`, on the macOS and Windows
host static gates as well as Linux:

- `AuthoritySpec` "record keys are ASCII and case-free": `mkRecordKey` refuses `"Alpha"`, `"é"`, `"٣"`,
  `"nul"`, `"CON"`, `"com1.rec"`, and admits `"alpha-1_b.c"`.
- `AuthoritySpec` "case-variant record names stay distinct": `mkRecordName "project:Build"` and
  `mkRecordName "project:build"` differ after `Text.toLower`; `mkRecordName "a_b"` and `mkRecordName "aB"`
  differ; both round-trip through `recordNameIdentity`.
- `AuthoritySpec` "case-variant identities keep separate durable records": in one store, records keyed by
  `mkRecordName "project:Build"` and `mkRecordName "project:build"` are each created with `ExpectAbsent`
  and read back with their own bytes.
- The Sprint 4.1 enumeration case extended with `A` and `_` in its alphabet still finds no shared encoding.

#### Remaining Work

- `Protected.hs` `mkRecordKey`: restrict the alphabet to `isAsciiLower`, `isDigit`, `-`, `_`, `.` and add
  the reserved-device-name refusal; add the "record keys are ASCII and case-free" case.
- `Protected.hs` `mkRecordName` and `recordNameIdentity`: add the `_c` / `__` escapes; add the
  "case-variant record names stay distinct" and "case-variant identities keep separate durable records"
  cases, and extend the Sprint 4.1 enumeration alphabet with `A` and `_`.
- Every caller listed by `grep -rn mkRecordKey core/hostbootstrap-core/src` that forms a key from a
  case-bearing identity (a project step name, a user-chosen cluster, instance, or profile name) passes it
  through `mkRecordName`; the existing behaviour suites for those callers pass unchanged.

### Sprint 4.5: Published records survive host power loss [Planned]

**Status**: Planned
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

- `publishBytes` syncs the temporary's data to disk before the rename: `fileSynchronise` on the descriptor
  on POSIX, and a write-through or `FlushFileBuffers` handle on Windows.
- On POSIX `publishBytes` syncs the parent directory after the rename, as `posixSyncParent` does, so the
  name change is durable too.
- The cleanup that removes the temporary covers the whole write, sync, and rename sequence, so a failed
  write leaves no `<key>.rec.tmp-<hex>` behind.
- The module header states exactly this guarantee: after a process death, OS crash, or power loss a record
  is the old one or the complete new one.

#### Validation

Closure requires these cases to exist and pass in `cabal test all` from `core/`:

- `AuthoritySpec` source-guard case "publishBytes syncs before it renames and cleans up every failure":
  the body of `publishBytes` calls the platform sync primitive before `renameFile`, calls the
  parent-directory sync after it on POSIX, and places the temporary's creation, write, sync, and rename
  under the one handler that removes the temporary.
- The existing record round-trip and compare-and-swap cases pass unchanged, and after them `records/` holds
  no entry containing `.rec.tmp-`.

Neither power loss nor a mid-write disk failure is reproducible through the store's public API in the
host static gate, so the source-guard case is what holds the ordering and the cleanup scope.

#### Remaining Work

- `Protected.hs` `publishBytes`: sync the temporary before `renameFile` (POSIX `fileSynchronise`; Windows
  write-through or `FlushFileBuffers`), sync the parent directory after it on POSIX, and wrap the whole
  sequence in the temporary-removing cleanup; correct the module header's crash guarantee to match. Add
  the `AuthoritySpec` source-guard case and the no-leftover-temporary assertion described in Validation.

## Remaining Work

- Sprint 4.1: refuse dot-edged namespaced tokens in `mkRecordName`, make `tryProtectedEntry` non-blocking
  against an in-process holder, align the `mkRecordName` and `tryProtectedEntry` Haddocks with that code,
  and add the record-name, re-entry, thread-contention, malformed-header, current-version delete,
  separator-key alphabet, and compile-fail forgery cases.
- Sprint 4.2: validate the liveness lock name, acquire it under `mask`, and add the out-of-process
  live-refusal, escaping-name, and interrupted-extent cases.
- Sprint 4.4: make record keys ASCII and case-free and escape case injectively in `mkRecordName`.
- Sprint 4.5: sync published records and their directory to disk, remove the temporary on every failed
  publish, and state that crash guarantee in the module header.

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
