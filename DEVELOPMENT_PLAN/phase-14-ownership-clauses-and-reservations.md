# Phase 14 — The four ownership clauses and host-local reservations

**Status**: Active
**Depends on**: Phase 3 (host tools and the closed effect vocabulary), Phase 4 (protected store),
Phase 11 (prepared operations and preconditions)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-17 ; `matt-junction`, native x86_64 Ubuntu 24.04.4 LTS,
Linux 7.0.0-28-generic, GHC 9.12.4, Cabal 3.16.1.0 ;
`cabal test all --test-show-details=direct --test-options=--hide-successes` from `core/` ;
pass ; covers in-gate

> **Purpose**: Define the four Locked-Origin Identity Ownership clauses once, supply the one seam that
> holds them, and supply the platform rows beneath it.

## Phase Objective

Every resource this project mutates must be *owned*, meaning: exclusive entry the kernel releases, a durable
origin record published before the object exists, the created object's own identity bound to the receipt, and
release conditional on re-observing that identity. The one window with no identity to re-observe — a run
that died between publishing its origin record and binding the created object's identity — is decided by
the recorded absence: a directory is removed only when it is empty, and a file only when its bytes match
the payload digest the record names. A backend that cannot hold a clause reports `Unsupported` and mints
no receipt, rather than minting a weaker one.

Those four clauses are **one transaction**, so this phase supplies one implementation of it and one closed
seam beneath. What differs between a POSIX host and a Windows host is the primitive each supplies — a row
of the frame table (§ LL) — and never a clause written twice. For every owner whose journal is an
`OriginRecord`, the order the clauses run in is a property of the types: a mutation consumes the recorded
origin and a release consumes the bound identity, so performing either out of order has no term (§ HH).
The host wall's journal is a `PersistedWallRecord`, so it consumes the row's primitives directly and
orders them through its own phase graph; its identity-conditional act is the seam's
`withReobservedIdentity` rather than a second copy of clause 4 (Sprint 14.18).

The clause set, the seam, the two platform rows, and the host-local objects a run owns directly live here.
The row that ships a transaction to another frame, and the providers that consume it, belong to the
[host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md), because that phase
owns the frame table's rows and the one fold that reaches a frame.

## Sprints

### Sprint 14.1: The shared object-identity layer [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Object.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Posix.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Windows.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

One realization of clause 3, shared by every host-local backend.

#### Deliverables

- `ObjectIdentity` has a private constructor and one hex journal codec (`objectIdentityText`,
  `parseObjectIdentityHex`).
- `mkKernelObjectIdentity` is the one producer that turns a kernel's volume and object words into an
  identity. Clause 3's identity read is a **row primitive**, `rowObserveIdentity`, and both platform rows
  build their answer through that one producer (Sprints 14.7 to 14.9).
- `OwnershipFault` is the closed fault sum every row reports into, so no owner maps a second identity-fault
  vocabulary of its own.
- Because directory and file ownership read identity through the same row primitive, their realizations of
  clause 3 cannot drift, and a substrate that cannot supply a stable identity refuses both at one place.

#### Validation

`OwnershipObjectSpec` covers the identity codec and its bounds; the `OwnershipPosixSpec` and
`OwnershipWindowsSpec` identity families cover `rowObserveIdentity` against the real kernel; and
`DataRootSpec` and `GeneratedConfigSpec` drive both owners through the production row.

#### Remaining Work

None. Clause 3's identity read is the platform row's primitive, which Sprint 14.7 declares and Sprints
14.11 and 14.12 consume.

### Sprint 14.2: Data-root ownership [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/DataRoot.hs`,
`core/hostbootstrap-core/test/DataRootSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Own a generated directory under all four clauses.

#### Deliverables

- The whole observe → record-origin → create → bind-identity sequence runs inside one protected entry, so it
  cannot straddle another transaction and the kernel releases the entry if the process dies part-way.
- The origin record names the exact prior identity **or** recorded absence, published before the directory
  exists.
- A run owns its own generation, never the shared parent: the parent is scaffolding, created if missing, never
  owned and never removed.
- Release removes the directory only after re-observing its exact identity. A directory the run merely found is
  preserved; a replaced one is a reported conflict and is left intact.
- The absent-original case restores absence rather than adopting generated content.

#### Validation

`DataRootSpec` covers clauses 2 to 4, adversary replacement reported as conflict without clobbering, release
refused on identity mismatch, and a crash between the origin record and the identity binding, simulated by
writing the record and the directory the dead run would have left. Clause 1 is structural in this owner:
every entry point demands a `ProtectedSession`. Exclusion while the entry is held is exercised against
the protected store itself, by `AuthoritySpec`'s "an out-of-process holder is excluded while the entry is
held"; this owner kills no process of its own.

The real-kernel directory replacement cases pass 20 consecutive focused runs, and the
complete phase gate passes 2,552/2,552 on 2026-09-17 in 176.58 seconds.

#### Remaining Work

None.

### Sprint 14.3: Generated-config ownership [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/GeneratedConfig.hs`,
`core/hostbootstrap-core/test/GeneratedConfigSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

The same four clauses over a file.

#### Deliverables

- The origin record names the recorded absence **and the digest of the payload this run intends to install**,
  published before the file exists. Recording the payload first is what makes the crash window between the
  record and the identity binding resolvable — see [rationale.md](rationale.md).
- The file is published create-if-absent through the package's hard-link-no-replace primitive.
- Release unlinks only on an exact re-observed identity **and** payload; an edited or replaced file is a
  reported conflict and is left intact.
- A **found** object is refused before any mutation and is never adopted: unlike a shared data root, a
  generated config cannot coexist with a config already there.

#### Validation

`GeneratedConfigSpec` covers each clause, the payload-conditional release, the found-object refusal, the
conflict report, and a kill between the origin record and publication. Replacement fixtures retain the
original object at a sibling path, so the real kernel cannot recycle its identity for the replacement.

The 2026-09-17 native Linux demo-workspace gate exposes immediate inode reuse in the delete/recreate
fixture: the core workspace passes 2,552 cases while the demo workspace fails its replaced-config
release case. A real-filesystem probe observes inode reuse in 500/500 delete/recreate pairs.

All 23 generated-config cases pass in each of 20 consecutive runs. On 2026-09-17 the
complete phase gate passes 2,552/2,552 in 176.58 seconds. The full demo workspace also passes
2,552 core cases (175.82 seconds) and 151 demo cases (0.69 seconds), and both Python legs pass.

#### Remaining Work

None.

### Sprint 14.4: The portable host-wall backend [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Host.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/ConfigBytes.hs`,
`core/hostbootstrap-core/test/WslGlobalWallSpec.hs`,
`core/hostbootstrap-core/test/WslGlobalWallHostSpec.hs`,
`core/hostbootstrap-core/test/WslGlobalWallConfigBytesSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`

#### Objective

Own an exclusive host-global configuration file under the same four clauses, portably.

#### Deliverables

- One portable driver over a platform backend. There is one driver and one implementation of each clause;
  what a POSIX and a Windows kernel differ by is the primitive each supplies, which is a **row** of the
  frame table (§ LL). Sprint 14.7 declares that row and Sprint 14.13 has this driver reach it, so the two
  backends are the two rows rather than a seam of their own.
- The managed body is produced by a pure byte transformer, so the file's content is derived rather than edited
  in place, and a crash leaves either the prior body or the new one.
- Ownership is a receipt plus an authority reachable only through it: settlement (`settleWallApply`)
  returns a `WallReceipt`, and a `WallAuthority` exists only inside `withWallAuthority` over that
  receipt, so a caller cannot hold authority without the receipt. The model's phase graph is enforced by refusal: authority is minted
  only from `WallApplied`, `WallRestoreOutcomeUnknown` or `WallRestored`, and every other transition from
  the wrong phase is `IllegalWallTransition`. `PersistedWallRecord` is plain data trusted from the
  protected store: `claimOrResumeWall` validates its shape and its match with the reservation, not how it
  reached its phase, and the module says so.
- Teardown restores the wall before any global shutdown, and there is no `.bak` sidecar — a second copy of the
  body is a second source of truth.
- No C shim and no `c-sources`: the clauses are met with dependencies already present.

#### Validation

`WslGlobalWallSpec`, `WslGlobalWallHostSpec`, and `WslGlobalWallConfigBytesSpec` cover the transformer, the
receipt and authority, and crash recovery on both sides of the write; the restore-before-shutdown order
is `ProviderSpec`'s "stop and guarded delete are explicit", which asserts `ReleaseGlobalWslWall` before
`wsl --shutdown`. No case asserts
any `IllegalWallTransition`, `OriginStateChanged` or `UnexpectedTargetPresent`, and no compile-fail
fixture covers the WSL wall's hidden constructors or rank-2 separation.

The sprint closes when these cases exist and `cabal test all` from `core/` passes:

- `WslGlobalWallSpec`: `withWallAuthority` from receipts in `WallClaimed`, `WallOriginRecorded`,
  `WallStageBound` and `WallApplyOutcomeUnknown` each return `Left (IllegalWallTransition phase _)`;
  `releaseWall` from `WallApplied` and `settleWallApply` on an `ApplyRetryFromOrigin` classification do
  the same;
- `WslGlobalWallSpec`: `recordWallOrigin` over a recorded `OriginalAbsent` retried with
  `OriginalPresent` returns `UnexpectedTargetPresent`, and over `OriginalPresent A` retried with
  `OriginalPresent B` returns `TargetReplaced`; `beginWallStageCreation` with an empty candidate returns
  `InvalidWallIdentity`;
- `WslGlobalWallSpec`, byte-exact origin: from the `restoring` and `restored` receipts of a present
  origin, `RestoreObservation (ObservedPresent originalIdentity "tampered") ObservedAbsent ObservedAbsent`
  classifies as `RestoreBlocked (TargetAmbiguous originalIdentity)` and `settleWallRestore`,
  `releaseWall` and `verifyWallReleased` each return `Left`; a `prepareApplying` whose origin observation
  carries the original identity with altered bytes is refused;
- `WslGlobalWallSpec`, exact absence at teardown: from the `restoring` and `restored` receipts of an
  absent origin, a target observation `ObservedPresent createdIdentity desiredBytes` is not settled,
  released or verified (`RestoreRetryFromApplied` or a `Left`), and `ObservedPresent foreign _` returns
  `Left (WallConflictError (TargetReplaced createdIdentity foreign))`;
- `WslGlobalWallSpec`, armed-stage binding: `bindWallStage (wallReceiptRecord creating) creating
  (ObservedPresent unboundIdentity desiredBytes) unboundIdentity` returns
  `Left (WallConflictError (UnboundStagePresent unboundIdentity))`; from `rebound`, a different identity
  returns `TargetReplaced` and the bound identity with wrong bytes returns `TargetAmbiguous`; and a
  rebind with `ObservedPresent reboundIdentity desiredBytes` returns the same receipt;
- `WslGlobalWallSpec`, malformed records: a table with one record per `validatePersistedRecord` refusal
  (empty candidate, target without origin, `WallOriginRecorded` carrying a target, a present origin whose
  target identity equals the original identity, a zero fence, and the rest), each asserting its exact
  `InvalidWallJournal` message through both `claimOrResumeWall` and `withWallAuthority`;
- `WslGlobalWallSpec`, stale replay: a receipt advanced from applied to restoring, then `beginWallRestore`,
  `releaseWall` and `recordWallOrigin` called with the older receipt against the newer active record,
  each returning `WallConflictError (StaleWallReceipt old new)`; and one case per payload check
  (`persistedTargetIdentity` or `persistedWallOrigin` altered under the same fence) asserting the
  `InvalidWallJournal` payload message from `revalidateActiveReceipt` and from `revalidateAuthority`;
- `WslGlobalWallConfigBytesSpec`: "UTF-16LE and UTF-16BE BOM files merge byte-exactly" asserts
  `desired @?= encode expected` against an expected ASCII body (keeping `custom=yes` under `[general]` and
  `unknown=yes` under `[wsl2]`, with the managed values in place) before the idempotence check;
- `WslGlobalWallConfigBytesSpec`: the strict decoder refuses UTF-16LE and UTF-16BE inputs with an odd
  payload, a `0x0000` unit, `0xD800` followed by ASCII, a lone `0xDC00` and a lone CR; the UTF-32BE BOM
  `00 00 FE FF`; the UTF-8 sequences `E0 80 80`, `ED A0 80`, `F0 80 80 80`, `F4 90 80 80`, the truncated
  `E2 82`, and `E2 28 A1`; a duplicate `[wsl2]` section; and an unrelated section preceding an existing
  managed one is preserved byte-for-byte;
- `CompileFailSpec` registers three fixtures with their exact diagnostics: applying the `WallReceipt` and
  `WallAuthority` data constructors, passing an authority minted under one `withWallReservation`
  continuation with a receipt from a second, and returning a `WallReservation` out of its continuation;
- `WslGlobalWallSpec`, "opaque identity admission rejects empty identities and a zero fence": nested
  `withWallOwner`/`withWallSpec`/`withWallFence` calls reach `withWallReservation` with an empty
  reservation identity and, separately, an empty receipt identity, asserting
  `Left (InvalidWallIdentity "wall reservation identity must not be empty")` and
  `Left (InvalidWallIdentity "wall receipt identity must not be empty")`;
- `WslGlobalWallSpec`, apply classification beyond the outcome-unknown phase: on a `WallOriginRecorded`
  receipt, `classifyWallApply` over the recorded origin with no staged object returns
  `ApplyRetryFromOrigin` and with a present staged object returns `ApplyBlocked _`; on a `WallApplied`
  receipt, the applied observation returns `ApplyAlreadyApplied` and a replaced target returns
  `ApplyBlocked (TargetReplaced _ _)`; a `WallClaimed` receipt returns
  `ApplyNotInProgress WallClaimed`. "apply recovery is total ..." is renamed to name
  the outcome-unknown phase it covers, and the two assertions "present-origin apply classifies every
  atomic publication fault point" repeats verbatim are deleted from one of the two;
- `WslGlobalWallSpec`: "an old authority refuses a newer active fence before restoration" is renamed
  "a stale receipt and authority pair refuses a newer active fence", because `revalidateActiveReceipt`
  returns the `StaleWallFence 61 62` before `revalidateAuthority`'s own fence comparison runs;
- `WslGlobalWallConfigBytesSpec`: "absent and present-empty files produce the exact CRLF body" is
  renamed "an empty file produces the exact CRLF body", since `mergeManagedWslConfig` has no absent
  input and the host driver's mapping of `OriginalAbsent` to empty bytes is `WslGlobalWallHostSpec`'s.

#### Remaining Work

- Write the `WslGlobalWallSpec` phase-guard and origin-change cases, the `WslGlobalWallConfigBytesSpec`
  decoder cases, and the three compile-fail fixtures listed in Validation.
- Correct the `GlobalWall.hs` module header and the `WallAuthority` Haddock, which say receipt and
  authority exist "only from a durably applied (or later teardown) record": `PersistedWallRecord` is
  exported with its fields and `wallReceiptRecord` returns it, so `claimOrResumeWall` admits a
  caller-edited record at any phase whose shape and reservation match. State that phase, origin and
  target identity are trusted from the protected store and are not proven by the type.
- Correct the `GlobalWall.hs` module header, the `WallObservation` Haddock ("supplied by the future
  platform backend") and the `PersistedWallRecord` Haddock ("Registry-serialisable", "a future protected
  Registry backend"): the adapter is `GlobalWall/Host.hs`, whose journal is the wall's own
  `ProtectedStore` under `%UserProfile%\.hostbootstrap\global-wall`, reached through the POSIX and the
  Windows ownership row.
- Delete `ConflictingWallPathShare` from `WallConflict`: nothing in `src`, `demo` or the tests constructs
  it, so the closed refusal sum carries a refusal no path produces.
- `ConfigBytes.hs`: give UTF-16 its own `Utf16Endianness = LittleEndian | BigEndian` and define
  `ConfigEncoding = Utf8Encoding Bool | Utf16Encoding Utf16Endianness`, so `decodeUnit`, `encodeUnit`,
  `decodeUtf16Units` and `encodeUtf16Units` take the endianness and their placeholder
  `Utf8Encoding` clauses (`= 0`, `= []`) cease to exist. Narrow the module header to say a
  controlled-key line is replaced whole, inline comment included, and that the replacement lines land at
  the end of the managed section; every other byte is kept.
- Write the byte-exact-origin, exact-absence, armed-stage-binding, malformed-record, stale-replay and
  UTF-16 merge cases listed in Validation.
- Write the empty reservation and receipt identity assertions and the `ApplyRetryFromOrigin`,
  `ApplyAlreadyApplied` and `ApplyNotInProgress` classification cases listed in Validation, and make the
  three case renames listed there.
- `GlobalWall.hs` `revalidateAuthority`: state in its Haddock that the authority's own fence comparison
  is defence in depth that the typed API cannot reach, because a `WallAuthority` and the `WallReceipt`
  it is paired with share the `fenceId` index and `revalidateActiveReceipt` has already equated the
  receipt's fence with the active record's.

### Sprint 14.5: The owned-object vocabulary [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Object.hs`,
`core/hostbootstrap-core/test/OwnershipObjectSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/architecture/ownership_seam.md`

#### Objective

One IO-free vocabulary for what an owned object is, so every owner speaks the same nouns.

#### Deliverables

- `ObjectIdentity` has a private constructor and one hex journal codec. `mkObjectIdentity` is its
  exported validating producer (non-empty, at most 64 bytes) for any authority's identity — a kernel's,
  a provider's, a container's — and `mkKernelObjectIdentity` is the one producer the rows use. The type
  therefore proves a well-formed identity, not that a kernel answered it.
- `ObjectKind`, `Origin`, and `Payload` name what is owned, what was there before, and what this run
  intends to install. `Origin` distinguishes recorded absence from a recorded prior identity, because
  absence is a fact rather than an inference from a missing record.
- `OriginRecord` has a private constructor and one producer; the bound identity is attached by its own
  producer, so a record cannot claim a binding it never made.
- One canonical record codec replaces the per-object encodings, so a record written by one owner is
  readable by every other and a version tag means one thing. The parser is exact: it accepts a byte
  string only when re-rendering the parsed record reproduces it, so two byte strings never decode to one
  record.
- `OwnershipFault` is the closed fault sum with a total eliminator, carrying structured expected/observed
  identity for a conflict.
- The module performs no IO and names no runner, so every value here is testable by application.
- The harness identity seam reads its identity through this vocabulary and carries its faults across
  through the closed eliminator, so there is one `ObjectIdentity` in the tree from here on and a record
  one owner writes is already comparable with an identity another owner read.

#### Validation

`OwnershipObjectSpec` covers the codec's round trip, its refusal of malformed and trailing input, the
identity constructor's bounds, and the total eliminator. Compile-fail fixtures cover the private
constructors and the record's un-updatable binding.

Dated 2026-08-18 validation evidence (x86_64-windows 11 Home 10.0.26200, GHC 9.12.4, Cabal 3.16.1.0):
`OwnershipObjectSpec` passed 15/15 — four identity cases, three payload cases, six record cases, and two
fault cases, including sixteen malformed-record shapes and eight malformed identity spellings. The four
compile-fail fixtures `ForgeObjectIdentity.hs`, `ForgeOwnershipPayloadDigest.hs`,
`ForgeOwnershipOriginRecord.hs`, and `RebindOwnershipOriginRecord.hs` each fail with their exact declared
diagnostic. Canonical `cabal test all --ghc-options=-Werror` from `core/` passed 1,976/1,976;
`poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

The sprint closes when `OwnershipObjectSpec`'s refused-record list also carries the whitespace variants
`"ownership 1 directory absent - -\r\n"`, `"ownership\t1 directory absent - -\n"`,
`"ownership  1 directory absent - -\n"`, `" ownership 1 directory absent - -\n"` and
`"ownership 1 directory absent - - \n"`, each refused; the malformed-record cases assert the exact
`OwnershipMalformed` text for a file record with `-` as its digest ("a file record is missing its payload
digest") and a reported-object record with `-` as its claim ("a reported-object record is missing its
owner claim"); and `cabal test all` from `core/` passes.

#### Remaining Work

- `Object.hs` `parseOriginRecord` tokenizes with `Text.words`, so tabs, repeated spaces, leading or
  trailing spaces and a CR before the LF all decode, and `Tape.publishFreshRecord`'s parse fallback then
  accepts a CRLF-altered record as this transaction's own write. Require
  `renderOriginRecord parsed == raw` (an exact round trip) before returning, refusing with
  `OwnershipMalformed`; add the five whitespace variants named in Validation.
- Correct the `ObjectIdentity` Haddock ("exists only where a row read a non-empty identity out of a
  kernel, so an empty or fabricated value can never be compared") and the module header's
  "supplied by a caller" claim to say what the type holds: `mkObjectIdentity` is an exported validating
  producer used for provider, container and digest-derived identities, and `mkKernelObjectIdentity` is
  the rows' producer.
- `Object.hs` `parseKind` reports a missing digest as "a file record carries a payload digest" and a
  missing claim as "a reported-object record carries an owner claim", the opposite of the defect, and the
  text reaches operators verbatim through `ownershipFaultMessage`. Reword them to "a file record is
  missing its payload digest" and "a reported-object record is missing its owner claim", and pin both
  texts as named in Validation.
- `OwnershipObjectSpec`: limit the module header's "every case is a pure function applied to a value"
  to the codec, identity, payload and fault groups, since `clauseTests` reads `Internal.hs`, `Clause.hs`
  and the Cabal file from disk; delete "a record is compared by its own bytes rather than by its
  rendering's shape", which round-trips one `OwnedFile` record the round-trip table already covers; and
  rename the assertions "the constructor owner is registered privately" and "the facade and the
  vocabulary are the public surface" to say they check registration only (privacy is held by the
  `ImportOwnershipInternal.hs` fixture), or parse the `ownership-internal` stanza's `other-modules` and
  `exposed-modules` fields and assert `HostBootstrap.Ownership.Internal` sits in the first and not the
  second.

### Sprint 14.6: The clause tokens [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Internal.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Clause.hs`,
`core/hostbootstrap-core/test/compile-fail/`,
`core/hostbootstrap-core/test/OwnershipObjectSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Make the clause order a property of the types, so it is not a prose invariant restated at every owner.

#### Deliverables

- Four abstract tokens — entered, recorded, bound, releasable — each indexed by the protected entry that
  authorized it and by the object it names, with nominal roles so neither index is coercible.
- The constructors live in one Cabal-private module, and its only importers are this phase's own facade
  and the seam, pinned by a source guard.
- Each token discloses exactly what the next clause consumes: the observed origin, the durably published
  record, the bound record and identity, and the record and re-observed identity. Nothing else rides
  alongside, because an origin passed separately is an origin that might have been observed before the
  entry.
- Each token has a total eliminator and no producer outside the seam, so a caller holds one only by
  having reached the clause that mints it.
- The entry index is the protected session's own rank-2 variable rather than a second brand, so a token
  cannot outlive the entry that authorized it and the two facts cannot disagree.

#### Validation

Compile-fail fixtures reject constructing each token, coercing either index, letting a token escape its
entry, and importing the private module. Each fixture is registered with one contiguous expected phrase.
`CompileFailSpec`'s `rejectsWithUsing` matches that phrase anywhere in the fixture's whole stderr; matching
it inside one diagnostic block, so an unrelated error cannot report the boundary as held (§ HH), is owed by
Sprint 5.10 of the [installed-identity phase](phase-5-installed-identity-and-authority-kernels.md). Running
cases pin the shape those fixtures
depend on: that the private module is registered in the Cabal file (which stanza field holds it is the
`ImportOwnershipInternal.hs` fixture's to prove), the exact importer set, the four nominal role declarations, the
facade's exact export list, and each eliminator's declared disclosure.

Dated 2026-08-18 validation evidence (x86_64-windows 11 Home 10.0.26200, GHC 9.12.4, Cabal 3.16.1.0):
the eight fixtures `ForgeOwnershipEntered.hs`, `ForgeOwnershipRecorded.hs`, `ForgeOwnershipBound.hs`,
`ForgeOwnershipReleasable.hs`, `CoerceOwnershipClauseSession.hs`, `CoerceOwnershipClauseObject.hs`,
`EscapeOwnershipClauseEntry.hs`, and `ImportOwnershipInternal.hs` each fail with their exact declared
diagnostic, and `OwnershipObjectSpec` passed 18/18.

#### Remaining Work

None. The tokens carry the order; the primitives that mint them by actually holding a clause are the
seam's, and the seam is the next sprint.

### Sprint 14.7: The ownership primitive seam [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

One seam of kernel primitives, and the producers that turn them into the four clauses. This sprint owns
the seam's shape and its capability gates. Sprint 14.23 holds the creating producers to a recorded
absence and withdraws a failed link's staging name, Sprint 14.24 holds the object index and the reported
face by fixture and guard, and Sprint 14.25 narrows `OwnershipCapabilities` to the fields a clause reads,
once both rows that declare it exist. The reported face's `OwnerClaim`-typed `recordReportedOrigin`
changes the signature its callers in the shipped, provider, cluster and Colima owners apply, so it lands
in Phase 16, where every one of those modules exists.

#### Deliverables

- `OwnershipPrimitive` is a record of primitives only — identity read, exclusive open, directory and file
  creation, no-replace publication, read, remove, close, parent sync — closed existentially over its
  handle type so a handle from one row cannot enter another.
- It carries no workflow, no pathname policy, and no command runner. An external effect that must happen
  between the origin record and the identity binding travels as a described `HostCommand` (§ KK), so the
  seam never grows a way to run a string.
- The row classifies its own platform faults into `OwnershipFault`; no raw status code reaches the
  driver, so the driver cannot come to depend on one platform's numbering.
- `OwnershipCapabilities` declares what a row can hold, and the refusal a row owes when it cannot is a
  total function of that value — so `Unsupported` is decided by application rather than by a stand-in
  (§ NN). Every kernel-face producer that reaches a primitive, the mutating `createOwnedDirectory`,
  `publishOwnedFile` and `releaseOwnedObject` included, applies `clauseRefusal` for the capabilities its
  own primitives need before the first one runs, so a row with a partial capability set is refused before
  it writes, links or removes anything: `createOwnedDirectory` applies `ClauseRecord` (it syncs the
  parent), `publishOwnedFile` applies `ClauseRecord` and `ClauseBind` (it syncs the parent and links
  no-replace), and `releaseOwnedObject` applies `ClauseRecord` (it syncs the parent after
  `rowRemoveObject`).
- The seven clause producers demand their predecessor token, which is where the ordering theorem lives:
  entering observes under the protected entry and introduces the object index rank-2, recording publishes
  the unbound record through the caller's own durable write, creating and publishing mutate only from that
  record, binding attaches the identity and re-publishes, re-observation is what mints the releasable
  token, and release removes the object before it forgets the record.
- The target an owner named rides on the tokens, so no producer takes a path argument and there is no call
  at which a matching token and a different path could be presented together.
- Clause 1 is the protected store's exclusive entry and clause 2 its compare-and-swap; neither is a seam
  field, because a second durable record beside the store is a second source of truth. The seam's
  *exclusive open* is a different thing and is a field: it opens one named object exclusively and without
  following a link, inside an entry the store already holds.

#### Validation

`OwnershipSpec` applies the capability classifier to every combination and asserts that a row which cannot
hold a clause reaches no mutation and mints no token. Compile-fail fixtures cover mutation before the
origin record, release without the identity binding, carrying a handle out of the row that minted it, and
crossing a handle between rows.

The row those cases run against supplies primitives that **diverge**, so "reaches no mutation" is a
property of a program that would not finish if it did rather than of a counter a stand-in incremented, and
the mirror case observes that a declared capability really is reached. Today only the entry and re-entry
producers are exercised that way (re-entry by "a row that cannot hold the clause refuses before the record
is read", against `unreachableRow noCapabilities`); the later gates (`recordOwnedOrigin`,
`bindOwnedIdentity`, `reobserveOwnedIdentity`) are held by the "every producer consults the classifier
before it reaches a primitive" source-text guard, and `createOwnedDirectory`, `publishOwnedFile` and
`releaseOwnedObject` consult no classifier at all. `OwnershipSpec` also covers only the `ReportedObject`
refusal of the two creating producers.

The sprint closes when `OwnershipSpec` carries these behavioural cases and `cabal test all` from `core/`
passes. Unless a case names another row, it runs against a row whose `rowObserveIdentity` is
`\_ -> pure (Right Nothing)` and whose every other primitive diverges, so a token is minted without a
kernel and any primitive reached fails the case:

- a row declaring identity but not durable parent sync: `recordOwnedOrigin` returns `OwnershipUnsupported`
  naming clause 2, and its publish continuation is never invoked;
- a row declaring identity and parent sync but not no-replace publication: `publishOwnedFile` returns
  `OwnershipUnsupported` before `rowCreateFile`, and `bindOwnedIdentity` returns `OwnershipUnsupported`
  naming clause 3;
- under `fullCapabilities`, `createOwnedDirectory` on an `OwnedFile` record and `publishOwnedFile` on an
  `OwnedDirectory` record each return `OwnershipUnsupported` before any primitive;
- under `fullCapabilities`, `publishOwnedFile` with a payload whose digest differs from the record's
  `OwnedFile` digest returns `OwnershipUnsupported` ("the payload offered is not the payload the origin
  record names") before any primitive;
- `reobserveOwnedIdentity` on a `Bound` token the existing `withBound` helper mints from a durable record,
  under `unreachableRow noCapabilities`, returns exactly the `OwnershipUnsupported` text
  `clauseRefusal noCapabilities ClauseRelease` yields and reaches no primitive.

The source guard is then narrowed to what text can hold (the identifier count of `clauseRefusal`, which
becomes 12: its export, signature and definition, the five existing gated uses, one in
`createOwnedDirectory`, two in `publishOwnedFile` and one in `releaseOwnedObject`), and its name stops
claiming more than that count.

Dated 2026-08-18 validation evidence (x86_64-windows 11 Home 10.0.26200, GHC 9.12.4, Cabal 3.16.1.0):
`OwnershipSpec` passed 10/10 — five classifier cases over all sixteen capability combinations, two
kernel-reachability cases, and three seam-shape cases. The four fixtures
`MutateBeforeOwnershipRecord.hs`, `ReleaseWithoutOwnershipBinding.hs`, `EscapeOwnershipRowHandle.hs`, and
`CrossOwnershipRowHandle.hs` each fail with their exact declared diagnostic. Canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,001/2,001;
`poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

#### Remaining Work

- `Primitive.hs`: `createOwnedDirectory` and `publishOwnedFile` reach `rowCreateDirectory`,
  `rowCreateFile` and `rowLinkNoReplace` with no `clauseRefusal`, and `ClauseRecord` does not require
  no-replace publication, so a row declaring identity and parent sync but not publication writes and links
  a file before `bindOwnedIdentity` refuses it. Before any primitive, `createOwnedDirectory` applies
  `clauseRefusal (rowCapabilities primitives) ClauseRecord` (it syncs the parent), `publishOwnedFile`
  applies both `ClauseRecord` and `ClauseBind` (it syncs the parent and links no-replace), and
  `releaseOwnedObject` applies `ClauseRecord` (it syncs the parent after `rowRemoveObject`). Update the
  guard's `clauseRefusal` identifier count from 8 to 12 and add the three new gate texts to its list of
  gated `case clauseRefusal (rowCapabilities primitives) ... of Just refusal -> pure (Left refusal)` lines.
- Add the five behavioural `OwnershipSpec` cases listed in Validation, built on a pure-observe diverging
  row (and the reobserve case on `withBound` under `unreachableRow noCapabilities`), and rename the guard
  "every producer consults the classifier before it reaches a primitive" to the identifier count and gate
  texts it actually checks, deleting its comment that the three mutating producers need no gate.
- Correct the `clauseRefusal` Haddock to name the clause each producer applies, and the `OwnershipSpec`
  module header's claim that the later producers can only be reached through a kernel read:
  `enterReportedObject` and `withBound` mint their tokens without one, which is what the new
  `reobserveOwnedIdentity` case uses.

### Sprint 14.8: The POSIX ownership row [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Posix.hs`,
`core/hostbootstrap-core/test/OwnershipPosixSpec.hs`,
`core/hostbootstrap-core/test/Expect.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`,
`documents/engineering/testing.md`

#### Objective

The primitives a POSIX kernel supplies, once.

#### Deliverables

- Exclusive **open of one object**, no-follow opens, device and inode identity, whole-file write with
  sync, parent directory sync, and the atomic no-replace link, each reached through the `unix` binding
  rather than a front-end process. The row opens objects; it does not supply clause 1, which is the
  protected store's own entry (Sprint 14.7).
- A symbolic link or a non-regular object at a target is refused rather than followed, because clause 3
  binds what the kernel knows and a link is a different object.
- The exclusive open carries an `fcntl` write lock over the whole file, so the exclusion is one the
  kernel releases when the holding process dies rather than a pathname a survivor must clean up. A
  classic `fcntl` lock belongs to the (process, inode) pair, not to the descriptor: it excludes other
  processes only, and closing any descriptor the process holds on that inode drops it. The row therefore
  never holds two handles to one inode at once, and its Haddock says so.
- The identity is encoded volume word first and little-endian, which is the encoding every other
  ownership backend already writes, so two identities compared mean the same thing whichever row read
  them.
- Errno classification is symbolic, so the same name means the same thing on Linux and Apple hosts. A
  filesystem that cannot hard-link at all (`EPERM` or `ENOTSUP` from `link`) is `Unsupported` rather than
  a probe failure, because that is a clause this host cannot hold; `EXDEV` (staging and target on
  different mounts) and `EMLINK` (link-count limit) are situational and are `OwnershipProbeFailed`
  naming that cause. Every raw descriptor the row opens is closed under `bracket` (or `mask` with
  `onException`), so an asynchronous exception cannot leak a descriptor or the `fcntl` lock it holds.
  `EACCES`, `EAGAIN` and `EBUSY` mean "held by another owner" only as the
  answer to the lock request; from `open`, `mkdir` or `lstat`, `EACCES` and `EPERM` are a probe that could
  not answer (`OwnershipProbeFailed`), never an occupied target.
- The row's capability declaration and the derived `posixOwnershipSupported` are read off the row itself,
  so a case's conditional expectation follows the subject rather than repeating a build symbol (§ JJ).
- The module compiles on every host family and answers a total refusal where it cannot apply, so no
  package-description stanza excludes it from a build (§ JJ).

#### Validation

The row is exercised against the **real kernel** in a temporary directory it created — not a stand-in —
so every case proves the syscall it names (§ NN). Clause 1's release-on-death is proved by a real process
actually dying, through the suite's own re-invocation route: the probe takes the row's exclusive open and
drops the raw descriptor rather than closing it, so nothing in that process can release the lock and the
parent's successful re-open is evidence about the kernel. On a host family where the row cannot apply,
the same cases assert its declared refusal rather than disappearing, and `CoverageManifest` declares each
of the four kernel families' size so a case that vanished is a failed count rather than a smaller total.

Dated 2026-08-18 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0):
`OwnershipPosixSpec` passed 24/24 — two declaration cases and twenty-two exercising the row against this
gate host's kernel, across identity, creation and publication, the exclusive open, and removal and
durability. `CoverageManifest` reported all four declared families at their exact sizes. Canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,121/2,121 in 209.17 seconds;
`poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231. `OwnershipPosixSpec` carries 20 cases in the
tree (two declaration cases and eighteen row cases), so that count does not describe the spec as it
stands; the closing run records the spec's own count.

On 2026-09-16, native x86_64 Windows 11 Home 10.0.26200 with GHC 9.12.4 and Cabal 3.16.1.0
compiles the unavailable POSIX row with its explicit `EmptyCase` extension. The row's declared refusal
cases pass in the complete core suite: 2,541/2,541 in 370.93 seconds (528.74 seconds including
component compilation). The complete host static gate also passes: the demo workspace's 151/151 demo
cases and 2,541/2,541 core cases, the Python code check, and 251/251 Python tests.

Three gaps stand against that evidence. The eight cases named for an occupied refusal (the second mkdir,
the second create, create through a link, link over a target, open of a link, open of a directory, open
against a live holder, remove of a link) assert through `Expect.expectOccupied`, which accepts any `Left`,
so the errno-to-fault mapping is never pinned. The `isRegularFile` guard in `posixOpenExclusive` is never
reached, because `O_RDWR` on a directory fails with `EISDIR` first. And "a file is removed, and the
parent's own change is made durable" proves only that the parent could be opened and synced; parent
durability itself is evidence only a crash-injection run can produce, and no case claims it.

The sprint closes when these `OwnershipPosixSpec` cases exist and `cabal test all` from `core/` passes on
a POSIX gate host:

- the eight occupied cases assert `Left (OwnershipOccupied _)` exactly and fail on any other `Left`,
  through the shared `Expect.expectOccupied` specialised to `Either OwnershipFault value`; a case applies
  that helper to `Left (OwnershipProbeFailed "probe" "reason")` and to `Left (OwnershipUnsupported
  "reason")` and asserts each raises an `HUnitFailure`;
- an exclusive open of a FIFO the case creates with `createNamedPipe` returns `Left (OwnershipOccupied _)`
  from the `isRegularFile` guard;
- `rowCreateFile` under a parent the case made mode `0o555`, and `rowObserveIdentity` beneath a
  directory made mode `0o000`, each return `Left (OwnershipProbeFailed _ _)` (skipped with a stated
  reason when the gate process runs as root, which ignores the mode);
- `rowLinkNoReplace` from a staging file to a target on a different mount (the case's temporary
  directory and a `tmpfs` such as `/dev/shm` when both exist, skipped with a stated reason otherwise)
  returns `Left (OwnershipProbeFailed _ _)`, not `OwnershipUnsupported`;
- the durability case is renamed "a parent directory can be opened and synced after a removal";
- "a probe that cannot answer is a fault rather than an absence", which observes `file </> "beneath"` and
  so reaches `ENOTDIR`, is renamed "a path through a non-directory is a fault rather than an absence"
  and asserts `Left (OwnershipOccupied _)`; the `0o000` permission case above is the row's
  `OwnershipProbeFailed` evidence for an observation;
- "removing an object that is not there is a fault rather than a silent success" asserts
  `Left (OwnershipProbeFailed _ _)` (the row's `ENOENT` answer) and fails on any other `Left`;
- "the kernel releases the exclusion when the holding process dies" holds the lock-probe child under
  `bracket (spawnProcess ...) (\probe -> terminateProcess probe >> void (waitForProcess probe))` (or
  `withCreateProcess`), so a failed contention assertion cannot leave the child blocked forever with the
  suite's output handles.

#### Remaining Work

- `Posix.hs` `posixFault` sends `EACCES` from every primitive to `OwnershipOccupied "is held by another
  owner"`. Give `posixOpenExclusive`'s `setLock` result its own classifier that maps `EACCES`/`EAGAIN`
  to `OwnershipOccupied`, and drop `eACCES` from the shared `posixFault` occupied set so `open`, `mkdir`
  and `lstat` permission failures are `OwnershipProbeFailed`. Prove it with the two permission cases
  named in Validation.
- Correct the `PosixOwnedHandle` Haddock ("the lock is on the open file description, so releasing the
  handle is releasing the exclusion") and the module header to state that the `fcntl` lock is
  per-process and per-inode and that the row never holds two handles to one inode.
- `Expect.hs` `expectOccupied :: (HasCallStack, Show value) => String -> Either failure value -> IO ()`
  passes on any `Left`, so a row that answers `OwnershipProbeFailed` or `OwnershipUnsupported` where it
  owes `OwnershipOccupied` passes all twelve callers (eight in `OwnershipPosixSpec`, four in
  `OwnershipWindowsSpec`). Specialise the shared helper to `Either OwnershipFault value`, matching
  `Left (OwnershipOccupied _)` only and failing with the observed fault on any other `Left`, rather than
  adding a local copy per row suite; a caller that owes a different fault names it. Add the helper's own
  refusal case listed in Validation.
- Add the FIFO case and rename the durability case as listed in Validation.
- `Posix.hs` `unsupportedLink` matches `ePERM`, `eXDEV`, `eMLINK` and `eNOTSUP`, so a cross-device
  staging path or a link-count limit reports "this host cannot publish ... it supplies no hard link".
  Keep `ePERM` and `eNOTSUP` there and map `eXDEV` and `eMLINK` to `OwnershipProbeFailed` naming the
  cross-device or link-count cause; add the cross-mount case listed in Validation.
- `posixCreateFile`, `posixOpenExclusive` and `posixSyncParent` open an `Fd` and close it only on paths
  reached through `tryIOError`, which catches no asynchronous exception. Close each descriptor under
  `bracket` or `mask` plus `onException` (in `posixOpenExclusive`, close the locked descriptor on any
  exception before the handle is returned). The manifest walk's own descriptors belong to the phase that
  owns the manifest.
- `OwnershipPosixSpec`: rename the `ENOTDIR` case and pin its `OwnershipOccupied`, pin the absent
  removal's `OwnershipProbeFailed`, and bracket the lock-probe child, as listed in Validation.

### Sprint 14.9: The Windows ownership row [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Windows.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Row.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Object.hs`,
`core/hostbootstrap-core/test/OwnershipWindowsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

The same primitives a Windows kernel supplies, and the one selector between the two rows.

#### Deliverables

- Byte-range exclusive **open of one object**, handle-based volume and file identity, reparse-point
  refusal, and atomic no-replace publication. As on the POSIX row, this opens objects and does not supply
  clause 1. The identity is the full `FILE_ID_INFO` (volume serial plus 128-bit file id) read with
  `GetFileInformationByHandleEx`, because the 64-bit `nFileIndex` is not unique on ReFS.
- A create under a missing parent directory is a probe failure (`OwnershipProbeFailed`), as on the POSIX
  row; only `ERROR_FILE_EXISTS` is an occupied name.
- Where a public binding flattens the status a recovery decision needs, a narrow direct kernel boundary
  captures it — with no C shim and no package-description `c-sources`. Two entry points qualify: the open
  that must separate "the name is not there" from "the name is held", and the hard link that must
  separate a taken name from a filesystem that cannot link at all.
- The reparse-point flag and the identity encoding exist once and are shared with the POSIX row's
  encoding, so a driver's volume-first comparison means the same thing on both. The encoding is one
  producer in the owned-object vocabulary that both rows reach; neither row builds an identity of its
  own.
- The parent's own durability is a real flush: `windowsSyncParent` opens the parent directory with
  `FILE_FLAG_BACKUP_SEMANTICS` and `GENERIC_WRITE`, calls `FlushFileBuffers` on that handle, and closes
  it, and a refused flush is a fault rather than a silent success. Only the file creation passes
  `FILE_FLAG_WRITE_THROUGH`; `CreateHardLinkW`, `CreateDirectoryW` and the removals carry no write-through,
  so the flush is what makes their name changes durable.
- `ownershipRowForHost` selects the row for the running host. Two rows exist; a third would be a second
  implementation of a clause. The selection is a build fact rather than a runtime probe, because which
  primitives exist at all is what the compiler has already decided.

#### Validation

The row is exercised against the real kernel on a Windows gate host, and asserts its declared refusal on
the others; `CoverageManifest` declares each of its four kernel families' size, so a case that vanished
on either family is a failed count rather than a smaller total. The one identity encoding is applied to
values and compared against its exact volume-first little-endian bytes on every gate host, and a source
guard holds that neither row reaches the raw identity constructor — with one producer the two cannot
drift into meaning different things, which is stronger than comparing two copies.

Two things `OwnershipWindowsSpec` does not reach are named rather than counted (§ NN). The live refusal
of a reparse point standing at a target is `WslGlobalWallHostSpec`'s "a symbolic-link target is refused
rather than followed": it creates a real link at the target and drives `applyGlobalWall
ownershipRowForHost` through it, and on a Windows gate host `ownershipRowForHost` is the Win32 row, so
`windowsOpenExclusive`'s non-regular check answers `OwnershipOccupied` ("is a directory or reparse
point"), the wall reports `HostWallUnsupported`, and the link's target bytes are unchanged. The
2026-09-16 native Windows core gate below runs that case; Sprint 14.13 owes pinning its message to the
reparse point. What `OwnershipWindowsSpec` itself holds on every gate host is the source guard that every
observation opens with the no-follow flag and that the non-regular predicate includes the reparse
attribute. And the row's Windows-family compilation is
evidence the [host-portability acceptance phase](phase-29-host-portability-acceptance.md) produces, since
that is the phase declaring the hardware (§ C).

Dated 2026-08-18 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): `OwnershipWindowsSpec`
passed all of its cases — eleven cases asserting the row's declared refusal on this gate host, two
declaration cases, two encoding cases, two selector cases, and two source-shape cases, which is the 19
the spec carries in the tree (the run's reported total of 23 does not match that breakdown). Canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,144/2,144;
`poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

On 2026-09-16, the same native Windows gate compiles the selector's textual manifest refusal with
its explicit `OverloadedStrings` extension. The Windows ownership families exercise the Win32 kernel;
unavailable POSIX rows assert their declared refusals. The complete core suite passes 2,541/2,541,
and every leg of the host static gate passes as recorded in Sprint 14.8.

That evidence leaves a declared deficit. `CoverageManifest` freezes the Windows row at 11 kernel cases
against the POSIX row's 18, and names closing the gap as this phase's owed work: four symbolic-link
behaviours, plus three clauses that are not platform-specific at all ("a probe that cannot answer is a
fault rather than an absence", "the kernel releases the exclusion when the holding process dies", and
"removing an object that is not there is a fault rather than a silent success"). `OwnershipWindowsSpec`
drives no second exclusive open against a live holder, no junction, and no create under a missing parent.

The sprint closes when `OwnershipWindowsSpec` carries these cases, `CoverageManifest`'s Windows family
sizes are raised to match and its "owed work" comment is deleted, and `cabal test all` from `core/` passes
on a Windows gate host (and the cases assert the row's declared refusal on every other gate host):

- an exclusive open against a live holder: the suite re-invokes itself as a probe that takes
  `rowOpenExclusive` and waits; the parent's open returns `Left (OwnershipOccupied _)` while it lives and
  succeeds after `terminateProcess`;
- a directory junction (created without privilege) is refused by `rowOpenExclusive` and by
  `rowRemoveObject` with `Left (OwnershipOccupied _)`, and `rowObserveIdentity` returns the junction's
  own identity rather than its target's;
- `rowRemoveObject` on an absent name returns `Left _`, and a probe that cannot answer (a name under a
  regular file used as a directory) is `Left (OwnershipProbeFailed _ _)` rather than `Right Nothing`;
- `rowCreateFile` at `root </> "missing" </> "file"` returns `Left (OwnershipProbeFailed _ _)`, with the
  matching case on the POSIX row;
- the four symbolic-link clauses each assert either the Windows row's behaviour or its declared refusal;
- `rowSyncParent` after a create and after a removal in a temporary directory returns `Right ()` through a
  real `FlushFileBuffers`;
- in process, a second `rowOpenExclusive` on a file whose handle the case holds returns
  `Left (OwnershipOccupied _)`, `rowCloseHandle` on the held handle returns `Right ()`, and a fresh open
  then succeeds; "an open handle reads the object's whole bytes" asserts its `rowCloseHandle` result is
  `Right ()` instead of discarding it;
- `rowObserveIdentity` on a file whose ACL denies the current user read access (set with `icacls` in the
  case's temporary directory) returns `Right (Just _)`, as `lstat` does on the POSIX row;
- "every observation opens without following a reparse point" also asserts that `observationFlags` is
  named exactly at its signature, its definition and the three call sites in `windowsObserveIdentity`,
  `windowsOpenExclusive` and `windowsRemoveObject`, and that no other `openObject` call outside
  `windowsCreateFile` passes a literal flag set;
- the four occupied call sites ("a directory is refused rather than opened as a file", the second create
  in "a directory is created once and the second attempt is occupied" and in "a file is written whole and
  the second attempt is occupied", and the link in "linking refuses rather than replacing, and leaves the
  target intact") assert `Left (OwnershipOccupied reason)` exactly, through `Expect.expectOccupied`
  specialised to `OwnershipFault` (Sprint 14.8), and the directory case also asserts that `reason`
  contains "is a directory or reparse point";
- "a file is removed, and the parent's own change is made durable" is renamed "a file is removed, and
  its parent can be opened and flushed", since a successful flush is what a case can observe and parent
  durability is evidence only a crash-injection run produces;
- "reaches the one kernel-identity producer" asserts
  `SourceGuard.countHaskellIdentifier "mkKernelObjectIdentity" source >= 2` (the import and a use)
  rather than a raw `isInfixOf` a comment satisfies;
- "the row selector names two rows and no third" asserts that `Row.hs` carries no `#elif` and that the
  set of lower-case identifiers ending in `OwnershipRow` it names is exactly `posixOwnershipRow`,
  `windowsOwnershipRow` and `ownershipRowForHost`, so a third CPP arm selecting a third row fails it;
- the live-holder probe child runs under `bracket` (or `withCreateProcess`) that terminates and waits for
  it, so a failed contention assertion leaves no blocked process behind.

#### Remaining Work

- `Windows.hs` `windowsSyncParent` is `pure (Right ())` while the row declares
  `holdsDurableParentSync = True`; only `windowsCreateFile` passes `FILE_FLAG_WRITE_THROUGH`. Implement it
  as `CreateFileW` on the parent with `FILE_FLAG_BACKUP_SEMANTICS` and `GENERIC_WRITE`, then
  `FlushFileBuffers`, then close, mapping a refused flush through `statusFault`, and correct its Haddock
  and the module header, which claim the creation and the publication are write-through.
- `windowsCreateFile` maps `openObject`'s `Right Nothing` (which under `CREATE_NEW` can only be
  `ERROR_PATH_NOT_FOUND`) to `OwnershipOccupied "is already there"`. Map it to
  `OwnershipProbeFailed ("create " <> subjectOf target) "the parent directory does not exist"`.
- `identityOf` builds the identity from `bhfiVolumeSerialNumber` and the 64-bit `bhfiFileIndex`, which
  Microsoft documents as not unique on ReFS. Read `FILE_ID_INFO` with `GetFileInformationByHandleEx` and
  feed the 64-bit volume serial and the 16-byte file id to the one identity producer, which takes the
  object part as little-endian bytes (8 on POSIX, 16 on Windows) so the volume-first encoding stays one
  producer; update the encoding case's expected bytes. `GlobalWall/Host.hs`'s `getIdentity` Haddock
  ("24 bytes of `FILE_ID_INFO` on Windows") describes this encoding and is false until it lands; check it
  and `validateStageVolume`'s first-8-bytes-are-the-volume reading against the new width in the same
  change.
- `windowsObserveIdentity` opens the target with `GENERIC_READ` only to read its identity, so an object
  whose ACL denies read, or one held open without `FILE_SHARE_READ`, surfaces as `OwnershipOccupied`.
  Open with desired access `FILE_READ_ATTRIBUTES` (`0x80`) instead; add the denied-read case listed in
  Validation.
- Add the in-process contention, close-result and `observationFlags` call-site assertions listed in
  Validation.
- Write the Windows-row cases listed in Validation, raise the Windows family sizes in `CoverageManifest`,
  and delete its "owed work for the phase that owns the ownership seam" comment.
- `OwnershipWindowsSpec`: pin the exact `OwnershipOccupied` refusals, rename the parent-flush case,
  replace the producer guard's raw `isInfixOf` with the identifier count, and make the selector guard
  reject a third row, as listed in Validation.
- `OwnershipWindowsSpec` "every observation opens without following a reparse point": its comment says
  the live refusal of a reparse point is not reached here and is confirmed by the host-portability
  acceptance phase. Reword it to name `WslGlobalWallHostSpec`'s "a symbolic-link target is refused rather
  than followed" as the live confirmation, which reaches the Win32 row through `ownershipRowForHost` on a
  Windows gate host, and to say this case holds the source shape on every gate host.

### Sprint 14.10: Re-entering an object this project already owns [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

Make clause 4 reachable from the durable record, so a release that happens in a later entry is still
inside the clause order.

#### Deliverables

- The four clauses are one transaction but they are not one process: an owner binds an identity now and
  releases it later — after its own bracket, after a restart, or from a successor's recovery path. One
  producer turns an exclusive entry, a target, and the bound record the caller read through its own
  durable store into the clause-3 token, so the release path is written in the same order as the
  acquisition path rather than beside it.
- A record with no identity binding describes a transaction that never got past clause 2 and licenses no
  release, so it is refused and mints no token. The seam holds no durable state of its own and cannot
  tell a record read from the store from one built in memory with `originRecord` and `bindOriginRecord`:
  re-entry trusts that the caller read the record through the store that published it, and its Haddock
  says exactly that. Re-entry admits a record of any kind, because the reported face re-enters
  `ReportedObject` records it then releases through `releaseReportedObject`.
- The object index is introduced fresh, exactly as clause 1 introduces it, so re-entered evidence is
  about this object and cannot be presented for another.
- The refusal a row owes for a clause it cannot hold is applied first, as at every other producer.

#### Validation

`OwnershipSpec` applies the producer to values: an unbound record mints no token, a row that cannot hold
the clause reaches no kernel, and a bound record discloses exactly the target and identity the record
names. A compile-fail fixture holds that a re-entered token cannot outlive the entry that authorized it,
which is the property that makes re-entry an entry rather than a way around one.

Every one of those cases runs against the row whose primitives diverge, so "reaches no kernel" is a
property of a program that would not finish if it did rather than of a counter a stand-in incremented
(§ NN) — and re-entry reaching no kernel is exactly right, because what it reads is a record the caller
already holds.

Dated 2026-08-18 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): `OwnershipSpec` passed
13/13, including the three re-entry cases and the seam-shape guard that now counts five classifier-gated
producers. The fixture `EscapeReenteredOwnershipEntry.hs` fails with its exact declared diagnostic.
Canonical `cabal test all --ghc-options=-Werror` from `core/` passed 2,148/2,148;
`poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

The sprint closes when the Haddock below states the trust re-entry extends and `cabal test all` from
`core/` passes.

#### Remaining Work

- `Primitive.hs` `reenterOwnedObject`'s Haddock says re-entry "does not manufacture evidence" and that
  the record "is the caller's, read through the store that published it", while the producer admits any
  bound `OriginRecord` value, including one built in memory. Reword it to state the trust it extends:
  any bound record is admitted, of any kind, and reading it from the store is the caller's obligation.

### Sprint 14.11: The data root consumes the seam [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/DataRoot.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/test/DataRootSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

The run's durable data root holds its clauses through the one seam.

#### Deliverables

- Acquisition, release, and recovery reach the clauses through the seam's producers and the host's row,
  so the identity read, the durable record encoding, and the identity-conditional act each exist once
  rather than once more here.
- The durable record is the canonical `OriginRecord` and its one codec, so a record this owner writes is
  readable by every other owner.
- The data root keeps the policy that is genuinely its own: the parent is scaffolding, created if missing
  and never owned; a directory the run merely found is preserved and never adopted; and a replaced one is
  a reported conflict left intact.
- A confirmed generation's **content** is cleared by this owner rather than by the seam, and only after
  clause 4's re-observation has said the directory is the one this run created. The seam removes exactly
  the object it was asked to remove, which is what keeps it from ever deleting more than that; what is
  inside a generation is the run's own, so clearing it is policy and sits here.
- Release re-enters the object from the record the store already holds, so the release path is written in
  the same clause order as the acquisition path.
- Recovery settles every state a dead run can leave. An unbound absent-origin record (the clause-2 to
  clause-3 window) removes the generation only when it is an empty directory, through the row's
  non-recursive `rowRemoveObject`, because the dead run had bound nothing and so had written nothing into
  it; a non-empty path is a `DataRootConflict` left intact. A bound absent-origin record whose directory is
  already gone is the window between release's removal and its forget, and is settled rather than
  reported as a conflict. An acquisition whose exclusive create loses the name to another process
  forgets its unbound record, so recovery never reads that process's directory as this run's window.
- No kernel identity is read through a seam of this module's own, so a host that cannot supply one
  refuses here at the same place it refuses everywhere else. The production bracket reaches the row
  through the one selector.

#### Validation

Every case `DataRootSpec` carries is retained, including both crash windows around the origin record, the
adversary-replacement conflict, and the release refusal on identity mismatch. Clause-1 exclusion is the
protected store's, exercised by `AuthoritySpec`'s out-of-process holder case rather than by this owner.

The sprint closes when `DataRootSpec` also carries these cases and `cabal test all` from `core/` passes:

- "a kill after the origin record but before the identity binding restores absence" creates an **empty**
  directory, because the window holds nothing (content is written only after the binding), and still
  recovers to `DataRootAbsenceRestored` with the record read back as `Right Nothing`; a new case puts a
  file in that directory, recovers to `DataRootConflict`, and finds the file and the record bytes
  unchanged;
- a bound absent-origin record whose directory is already gone recovers to `DataRootAlreadyAbsent`, and
  the record reads back as `Right Nothing`;
- an unbound absent-origin record whose directory is already gone recovers to `DataRootAlreadyAbsent`
  with the record settled. The existing "an absent-original run whose directory is already gone settles
  cleanly" case is renamed "recovery with no record reports already absent", because that is the branch
  it reaches;
- both refused releases (replaced and vanished directory) read the protected record back afterwards and
  find the same bytes;
- the clause-2 ordering case runs against a row whose `rowCreateDirectory` first reads the protected
  record and fails the case unless an unbound `OriginAbsent` record is already there;
- an acquisition against a row whose `rowCreateDirectory` first creates the directory and puts a file in
  it (another process winning the name) returns `Left`, the record reads back as `Right Nothing`, and a
  following `recoverDataRoot` leaves the directory and its file intact;
- "an unsettled record under the same key is a conflict, not an overwrite" reads the record bytes before
  the second acquisition and asserts they are unchanged after it.

Dated 2026-08-18 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): `DataRootSpec` passed
18/18 — five clause-2 cases, three clause-3 cases, five clause-4 cases, and five recovery cases, all
driving the production row against a real kernel. Canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,148/2,148 in 208.76 seconds;
`poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

#### Remaining Work

- `DataRoot.hs` `recoverDataRoot`'s unbound branch (`restoreRecordedAbsence`) calls `removePathForcibly`
  on whatever is at the path. Replace it with `enterOwnedObject`: an `OriginAbsent` observation settles
  the record and returns `DataRootAlreadyAbsent`; a present directory whose `listDirectory` is empty is
  removed through `rowRemoveObject` plus `rowSyncParent` and the record settled with
  `DataRootAbsenceRestored`; a non-empty one returns `DataRootConflict` and keeps the record. Prove it
  with the `DataRootSpec` crash-window cases named in Validation.
- `reclaimBoundGeneration` runs `reobserveOwnedIdentity`, which refuses an absent target, so a bound
  record left by a kill between `releaseOwnedObject`'s removal and its forget (or by a failed forget)
  makes every later `reclaimAbandonedRun` return `ModeOwnershipUnresolved`. Observe the target through
  the row first; when it is authoritatively absent, forget the record and return `DataRootAlreadyAbsent`.
  Keep the conflict only for a present object with a different identity. Prove it with the bound
  absent-directory recovery case named in Validation.
- `emptyGeneration` clears the confirmed generation by pathname (`listDirectory` then
  `removePathForcibly`) after the re-observation, so a non-cooperating process that renames the
  directory and puts its own at the name in between loses its content. Re-observe the directory's
  identity through `rowObserveIdentity` immediately before the listing and refuse with the clause-4
  conflict on a mismatch, and correct the module header and `emptyGeneration` Haddock, which say nothing
  is touched until the kernel has confirmed the directory, to name the residual window between that
  re-observation and the per-entry removals.
- Make the `DataRootSpec` changes listed in Validation: the empty-directory crash-window fixture and its
  non-empty refusal case, the bound and unbound absent-directory recoveries, the record read back after
  each refused release, the renamed no-record case, and the clause-2 ordering row.
- `acquireDataRoot`'s `createUnderRecordedAbsence` returns `createOwnedDirectory`'s fault and keeps the
  unbound `OriginAbsent` record, so a directory another process created between the observation and the
  exclusive create is later treated as this run's crash window. When the create answers
  `OwnershipOccupied` (nothing was created), forget the unbound record through the tape before returning
  the fault; prove it with the lost-race acquisition case named in Validation.
- Correct the `DataRootOwnership` Haddock, which says `releaseDataRoot` "revalidates the path and record
  key": only the key is compared. Document `DataRootAlreadyAbsent` as what it reports: no record remained,
  or the record's directory is authoritatively absent; the path is not inspected when no record exists.
- Add the record-unchanged assertion to the unsettled-record conflict case listed in Validation.

### Sprint 14.12: The generated config consumes the seam [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/GeneratedConfig.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Ownership.hs`,
`core/hostbootstrap-core/test/GeneratedConfigSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/architecture/durable_state.md`

#### Objective

The run's generated sibling config holds the same clauses through the same seam.

#### Deliverables

- Acquisition, release, and recovery reach the clauses through the seam's producers and the host's row,
  and the file is published through the row's atomic no-replace primitive rather than through one of this
  module's own. The payload is staged beside the target under a name the record key derives, so two runs
  never stage through one name and a failed publication withdraws its own staging object without
  displacing the fault that caused it.
- The record is the canonical `OriginRecord`, whose file case already carries the intended payload's
  digest — which is what makes the crash window between the record and the binding resolvable.
- The generated config keeps the policy that is genuinely its own: a found object is refused before any
  record is written and is never adopted, and release unlinks only on an exact re-observed identity
  **and** payload. The payload comparison follows clause 4's re-observation and reads the bytes back
  through the row's own exclusive open, so the file it compares is opened without following a link and by
  the primitives that created it, and the refusal names both digests.
- Recovery leaves no record behind when it succeeds. Restoring the recorded absence in the clause-2 to
  clause-3 window forgets the origin record, and a bound record whose file is already gone (the window
  between release's unlink and its forget) is settled as `GeneratedConfigAlreadyAbsent` rather than
  reported as a conflict. Every refusal keeps the record byte-for-byte. The crash-window removal is
  conditional on the identity clause 1 observed still being the object at the target after its payload
  read, and recovery withdraws the dead run's staging name, which the record key determines.
- No kernel identity is read through a seam of this module's own; the production bracket reaches one row
  for both owned objects.

#### Validation

Every case `GeneratedConfigSpec` carries is retained, including the payload-conditional release, the
found-object refusal, the conflict report, and the kill between the origin record and publication.

The sprint closes when these `GeneratedConfigSpec` assertions exist and `cabal test all` from `core/`
passes:

- "a kill after the origin record but before the identity binding restores absence" and "a kill after
  the identity binding restores absence too" each end with
  `readProtectedRecord session key >>= (@?= Right Nothing)`;
- a new case writes a bound absent-origin record whose file is gone, recovers to
  `GeneratedConfigAlreadyAbsent`, and reads the record back as `Right Nothing`;
- each refusal case (edited, re-line-ended, replaced, vanished, cross-record, foreign bytes in the crash
  window, foreign replacement) reads `protectedRecordBytes` before and after the refused call and asserts
  they are equal;
- a crash-window recovery against a row wrapper whose `rowRemoveObject` is reached only after the case
  has replaced the target with a stranger's file of the same bytes refuses with
  `GeneratedConfigConflict`, and the stranger's file survives;
- a crash-window fixture that also leaves the staging file `stagingPath key path` names
  (`.<record key>.hostbootstrap-staging` beside the target) recovers with no object at that name;
- "a receipt cannot release another run's record" gives `config.spec.other` a record of its own, so only
  the key guard can refuse, and matches the conflict's observed side "release attempted under";
- "the record retains the digest, never the config bytes" asserts the stored bytes equal
  `renderOriginRecord` of the bound `OwnedFile` record the acquisition made, rather than that the word
  `project` is absent.

Dated 2026-08-18 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): `GeneratedConfigSpec`
passed 23/23 — six clause-2 cases, three clause-3 cases, the found-object refusal, seven clause-4 cases,
and six recovery cases, all driving the production row against a real kernel. Canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,151/2,151 in 220.36 seconds;
`poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

#### Remaining Work

- `GeneratedConfig.hs` `recoverGeneratedConfig`'s `settleOutcome` maps `RecoveredAbsence` to
  `pure (Right GeneratedConfigAbsenceRestored)` without forgetting, so the unbound branch
  (`restoreRecordedAbsence` through `removeThroughRow`) leaves the dead run's origin record standing and
  the next acquire under that key refuses with "an unsettled record". Split the outcome: the unbound
  branch returns a constructor that `settleOutcome` settles with `settle GeneratedConfigAbsenceRestored`;
  the bound branch, whose `releaseOwnedObject` already forgot the record, keeps the plain `Right`. Prove
  it with the two record read-backs named in Validation.
- `reclaimBoundFile` runs `reobserveOwnedIdentity`, which refuses an absent target, so a kill (or a
  failed `forgetRecord` or `rowSyncParent`) between `releaseOwnedObject`'s unlink and its forget makes
  every later sweep report `GeneratedConfigConflict`. Observe the target through the row first; when it
  is authoritatively absent, forget the record and return `GeneratedConfigAlreadyAbsent`. Keep the
  conflict only for a present object with a different identity or payload. Prove it with the bound
  absent-file recovery case named in Validation.
- Add the record-retained assertion to each refusal case listed in Validation.
- `restoreRecordedAbsence` ignores the identity in `OriginPresent _`, reads the bytes through a fresh
  exclusive open, then calls `rowRemoveObject` on the same name, so an editor's atomic save between the
  read and the unlink loses the stranger's file. Keep the entry's identity and re-observe it through
  `rowObserveIdentity` after the payload read and immediately before the removal, refusing with
  `GeneratedConfigConflict` on a mismatch; correct the module header to name the residual window between
  that re-observation and the unlink. Prove it with the same-bytes replacement case named in Validation.
- `recoverGeneratedConfig` never touches `stagingPath key path`, so a run killed between staging and its
  withdrawal leaves a `.hostbootstrap-staging` file nothing removes. Before settling, withdraw the staging
  name through `rowRemoveObject`, treating an authoritative absence as success; prove it with the staging
  fixture named in Validation.
- Make the cross-record and digest-only assertions in `GeneratedConfigSpec` listed in Validation.

### Sprint 14.13: The host wall's backends become the two rows [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Host.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Windows.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Row.hs`,
`core/hostbootstrap-core/test/WslGlobalWallHostSpec.hs`,
`core/hostbootstrap-core/test/WslGlobalWallWindowsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`,
`documents/architecture/ownership_seam.md`

#### Objective

The host wall's two platform backends become the two ownership rows, so its identity-conditional act
exists once rather than once per platform.

#### Deliverables

- The portable driver opens the host's row with `withOwnershipRow` and calls its primitives
  (`rowObserveIdentity`, `rowOpenExclusive`, `rowReadObject`, `rowCreateFile`, `rowLinkNoReplace`,
  `rowRemoveObject`, `rowSyncParent`) directly, because its journal is a `PersistedWallRecord` rather
  than an `OriginRecord`; it calls no clause producer. It keeps the policy that is genuinely its own: its
  phase graph, its pure byte transformer, and the receipt through which alone its authority is reachable.
  Its matches over `WallJournalPhase` and `RestoreClassification` name every constructor, so a phase or
  classification added to the model is a compile error in the driver rather than a branch reported as
  teardown or `IllegalWallTransition`. Its clause-4 guard, `withConfirmedIdentity`, re-implements the seam's re-observation, which
  is the one standing second copy of a clause; Sprint 14.18 makes that act the seam's.
- The production entry points accept no pathname: only `HostBootstrap.Wsl2.GlobalWall.Windows` derives
  the target and state directory, from a non-empty absolute `USERPROFILE`, and `openHostWallLocation`,
  `hostWallProtectedStore` and `hostWallActiveRecordKey` are not exported from the public library.
- The wall's own platform backend seam is gone, so there is one identity read, one no-replace
  publication, and one exclusive open beneath every host-local owner. Clause 1 is now the wall's own
  protected-store entry and clause 2 its compare-and-swap — the same two the run's data root and
  generated config hold — so the wall carries no lock file, no journal file, and no fence file of its
  own, and the strictly monotonic fence is the store's own never-reused record version.
- The seam's no-replace publication is the kernel primitive it actually is. `rowLinkNoReplace` gives an
  object a second name and leaves the first; the seam's own file publication withdraws the staging name
  after it, and the wall — whose armed object must be journalled before a durable name for it exists —
  composes the same two steps in its own order.
- The object identity is stated once. The wall's model, its durable record codec, and the two rows all
  speak `Ownership.Object`'s `ObjectIdentity`, so the identity a record carries is the identity a row
  read.
- The armed-stage reading is one reading rather than a per-platform fork. Both rows create a durable
  armed object, so an armed leftover in the create-outcome-unknown phase is this owner's own interrupted
  attempt on every host — its name embeds the receipt's never-reused fence — and it is removed by exact
  identity inside the same exclusive entry and the create retried.
- Teardown still restores the wall before any global shutdown, and there is still no second copy of the
  body.
- A failed armed-stage create is an `UnboundStagePresent` conflict only when the row answered
  `OwnershipOccupied`; any other fault (a full disk, a refused write) is returned as itself. A wall whose
  worst-case encoded record (origin and desired bytes, stage candidate and largest identity) exceeds the
  16 MiB journal bound is refused before its first store, so no record can become unstorable at a later
  phase.

#### Validation

Every case `WslGlobalWallSpec`, `WslGlobalWallHostSpec`, `WslGlobalWallConfigBytesSpec`, and
`WslGlobalWallWindowsSpec` carry today is retained, including the transformer, the receipt and
authority, and crash recovery on both sides of the write; the restore-before-shutdown order stays
`ProviderSpec`'s.

The driver's fixture no longer writes through a platform backend: the durable state an interruption
leaves is a value, so the fixture publishes that value through the wall's own protected store and
re-enters the ordinary entry point. Nothing in the driver cooperates, and no crash point or injected
seam is introduced (§ NN).

Dated 2026-08-18 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): the four wall suites
passed 55/55, with `WslGlobalWallHostSpec`'s 20 cases now driving `ownershipRowForHost` and a real
protected store rather than a POSIX-only lane. Canonical `cabal test all --ghc-options=-Werror` from
`core/` passed 2,151/2,151 in 214.35 seconds; `poetry run python -m hostbootstrap.check_code` passed;
and `poetry run python -m hostbootstrap.test_all` passed 231.

**Coverage owed rather than claimed (§ NN).** `WslGlobalWallHostSpec` now runs against whichever row the
gate host supplies, so its twenty cases are evidence about the Windows row only on a Windows gate host.
This Linux run is evidence for the POSIX row alone; the same suite's confirmation against the Windows
row is the [host-portability acceptance phase](phase-29-host-portability-acceptance.md)'s, because that
claim needs a second machine and § C forbids a baseline phase owing hardware it does not declare.

Several refusals of the driver are reached by no case. "clause 4 refuses to delete a replaced managed
target" swaps the file before restore begins, so its refusal comes from the model's
`classifyAppliedForRestore` and `withConfirmedIdentity`'s `TargetReplaced` and `UnexpectedTargetAbsent`
branches are never produced. No case reaches a resume with a foreign reservation or receipt, a pre-applied
or teardown phase, a `WallStageBound` armed-stage recovery, a colliding stage or retained name, a
`decodeWallRecord` tag or bound refusal, or the Windows lane's `USERPROFILE` refusals.

The sprint closes when these cases exist and `cabal test all` from `core/` passes (the Windows-lane cases
on a Windows gate host, asserting the declared refusal elsewhere):

- `WslGlobalWallHostSpec`: a row wrapper whose `rowRemoveObject` (and, in a second case,
  `rowLinkNoReplace`) first swaps the file for a foreign one makes restore return exactly
  `HostWallConflict (TargetReplaced _ _)`, and one whose remove first deletes the file returns
  `HostWallConflict (UnexpectedTargetAbsent _)`; the foreign bytes survive. The existing swap-before-restore
  case is renamed to say the model refuses it;
- apply with reservation `r1` then apply or restore with `r2` returns
  `HostWallConflict (ForeignWallReservation _ _)`, a different receipt returns `ForeignWallReceipt`, and
  the target bytes are unchanged; reusing a spec identity for different desired bytes returns
  `InvalidWallJournal`;
- with the existing `rewindJournal` fixture: rewound to `WallRestored`, apply returns
  `HostWallModelFailure (IllegalWallTransition WallRestored _)`; rewound to `WallStageBound`, restore
  refuses; rewound to `WallReleased` with the origin restored, restore returns `Right ()` and clears the
  active record;
- rewound to `WallStageBound` with the journalled identity's file at the `.armed` name and the durable
  stage name absent, apply succeeds; with a different object there, apply returns
  `HostWallConflict (TargetReplaced _ _)`;
- a pre-created `.wslconfig.hostbootstrap.<fence>.origin` before a present-origin apply returns
  `HostWallConflict (UnexpectedTargetPresent _)`, and a pre-created stage name with foreign bytes in
  `WallStageCreateOutcomeUnknown` refuses; the foreign bytes survive both;
- `decodeWallRecord` refuses a valid encoding patched to phase byte 9, origin tag 3, optional tags 2, an
  identity length of 4, a length prefix of `0xFFFFFFFF`, and truncation at several offsets, each with
  `HostWallJournalFailure`; one golden-bytes vector pins `encodeWallRecord` for a known record;
- "an unknown format is refused" decodes `"HBWSLH02" <> ByteString.drop 8 (encodeWallRecord record)` for a
  real record and asserts the unknown-format message, not merely `HostWallJournalFailure _` (the
  8-byte `"HBWSLXXX"` input reaches the truncation refusal if the magic check is deleted);
- "clause 1 serialises two concurrent entries" records ordering: the outer body sets an `IORef` just
  before returning and the inner body reads it, and the case asserts the inner entry saw `True`;
- "clause 4 refuses to delete a replaced managed target" (and a new sibling case) writes the replacement
  with exactly the published managed bytes, read back after apply, while the original is kept alive by a
  hard link at a sibling path so its inode cannot be reused, and asserts
  `Left (HostWallConflict (TargetReplaced _ _))` with the replacement surviving;
- `mkCurrentUserWallRequest` and `mkManagedWslConfigSpec` are table-driven over each refusal: an empty
  spec, reservation and receipt identity; an oversize identity and body; and for the spec a missing
  `[general]` or `[wsl2]`, a repeated header, a non-managed section, a setting before any header, an
  empty or non-printable line, and a missing required key, each asserting its exact constructor;
- with a row wrapper whose `rowCreateFile` writes a partial armed stage and then answers
  `OwnershipProbeFailed`, apply returns that fault rather than `HostWallConflict (UnboundStagePresent _)`;
- an apply over a `.wslconfig` sized so its `WallOriginRecorded` record fits the 16 MiB bound but a later
  phase's record would not is refused before any store, and the active record reads back as absent;
- `WslGlobalWallWindowsSpec`: with `USERPROFILE` unset, empty, and relative, both entry points return
  `Left (HostWallUnsupported _)`; `openHostWallLocation` with a state path that is a regular file returns
  `HostWallJournalFailure`;
- `WslGlobalWallWindowsSpec`: the absent-origin case's check that
  `profile/.hostbootstrap/global-wall.record` does not exist (a file the protected store never writes)
  is replaced by a second `restoreCurrentUserGlobalWall` returning `Left HostWallNoActiveRecord`; the
  replacement case writes the published managed bytes, as in the host spec, and asserts
  `Left (HostWallConflict (TargetReplaced _ _))` with the replacement surviving;
- `WslGlobalWallWindowsSpec`: the absent-origin case compares the published `.wslconfig` with the exact
  `mergeManagedWslConfig ByteString.empty` rendering of its spec rather than a `"memory=8GB"` substring;
  the present-origin case reads the target after apply and asserts it differs from `original`, and
  asserts that the restored file's identity read through `ownershipRowForHost`'s `rowObserveIdentity`
  equals the identity read before apply; the module header stops saying the driver runs "over the POSIX
  row";
- `WslGlobalWallHostSpec`: `rowCase`'s Haddock, the armed-leftover comment ("The POSIX armed link is
  durable") and the `CoverageManifest` reason texts that cite `fcntl` and `device:inode` for this family
  name the host's ownership row rather than the POSIX one; and `expectRowRefusal` takes the row as an
  argument, and a case runs it against a row that declares no capability and whose every primitive
  answers `Left (OwnershipUnsupported _)`, as the unavailable platform rows do, so the refusal branch
  `rowCase` keeps is exercised rather than unreachable on both shipped rows;
- "a symbolic-link target is refused rather than followed" asserts that the `HostWallUnsupported`
  message names the link ("symbolic link" on the POSIX row, "reparse point" on the Windows row), not any
  `HostWallUnsupported`;
- "an interrupted publication converges on the next apply" carries a comment saying the rewind models a
  crash after the publication call and before `WallApplied` is stored; a new case rewinds to
  `WallApplyOutcomeUnknown` with the bound stage on disk under its durable name and the target absent (the
  layout a crash before the publication call leaves) and asserts the resumed apply reaches `WallApplied`
  with the managed bytes at the target and no stage name left;
- "a durable armed leftover is reclaimed, never published" asserts `doesFileExist armed` is `False` after
  the resume and `targetSiblings target` is `[]` after the final restore;
- the group "the Windows production entry points" is renamed "request construction", since both its
  cases apply the pure `mkCurrentUserWallRequest`.

#### Remaining Work

- `GlobalWall/Windows.hs` `withCurrentUserWall` refuses only an unset `USERPROFILE`; an empty or relative
  value puts `.wslconfig` and the global-wall store under the process CWD. Refuse with
  `HostWallUnsupported` unless the value is non-empty and absolute under the Windows grammar.
- `GlobalWall/Host.hs` exports `openHostWallLocation`, `hostWallProtectedStore` and
  `hostWallActiveRecordKey` from the public library, so any consumer can aim the wall at any path or
  compare-and-swap a forged active record. Move them to the private `ownership-internal` sublibrary (or a
  private module re-exported only to `GlobalWall.Windows` and the test suite), and correct the
  `HostWallLocation` Haddock.
- `GlobalWall/Host.hs` `createArmedStage` re-probes the path after any `rowCreateFile` fault and answers
  `HostWallConflict (UnboundStagePresent identity)` whenever something is there, discarding the row's
  fault, so a partial write on a full disk is reported as an unowned collision. Report the conflict only
  when the row's fault is `OwnershipOccupied`, return every other fault as itself, and correct the
  Haddock that calls a taken name "exact evidence of an unowned collision" for every failure.
- `storeRecord` checks the 16 MiB bound on each store, but the record grows after `WallOriginRecorded`
  (stage candidate, then target identity), so a near-limit `.wslconfig` stores the first record and then
  fails every later store, which restore cannot clear. In `prepareFreshReceipt`, before the first store,
  refuse with `HostWallUnsupported` when the worst-case encoded record exceeds the bound.
- Replace the catch-all `phase ->` branches in `driveApply` and `recoverDurablyBoundArmed`, the
  `classification ->` branches in `driveApplying` and `driveRestoring`, and `phase ->` in `driveRestore`
  with the constructors they cover, as the module's own `fromOwnershipFault` already does.
- Write every case listed in Validation.
- Make the `WslGlobalWallHostSpec` and `WslGlobalWallWindowsSpec` assertion, wording and rename changes
  listed in Validation: the exact native publication bytes and restored identity, the host's-row wording
  and the exercised refusal fallback, the symlink refusal message, the before-publication resume case,
  the armed-leftover residue check, and the request-construction group name.

### Sprint 14.14: One record tape behind the ownership seam [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Tape.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

The four-clause algebra is genuinely shared: every owner enters, records, binds and releases through
the one seam. What each owner supplies to that seam — publish a fresh record, publish a bound one,
forget it, read it back, and collapse the two error layers — is hand-copied, five times. Two of those
copies are identical apart from three message strings, including the four-line comment explaining why
collapsing the layers once is what keeps every caller from writing its own.

They have drifted: one copy takes a `RecordKey` argument it never prints and names "this instance's
key", the other takes none and names "this key", so the same condition produces two different refusals
depending on which owner saw it. Deciding which is correct is part of this sprint, not a detail of it —
adopting whichever is refactored first would pick a winner silently.

#### Deliverables

- A record tape lives beside the ownership primitives, holding the publish, forget and read-back operations over one session, key and subject.
- A two-method carrier class lifts a clause fault and a store fault into a domain's own error sum, replacing the lifting every owner of an origin-record tape hand-wrote. The host wall, whose journal is a `PersistedWallRecord` rather than an origin record and which uses no tape, keeps its own `fromOwnershipFault` and `fromStoreError` in `GlobalWall/Host.hs`.
- The provider owner adopts both and keeps only what is genuinely its own.
- The foreign-record refusal divergence is resolved deliberately, and the sprint records which behaviour was chosen and why.
- A store failure reaches the owner in the class that tells it what to do: a record whose envelope does not decode (`ProtectedMalformedRecord`) is `OwnershipMalformed`, because retrying cannot make it decode, and every other store failure is `OwnershipProbeFailed`.
- The tape never replaces a stored binding. `publishFreshRecord` accepts a stored record only when its bytes are the fresh record's own, so a stored record that carries a binding is another transaction's; `publishBoundRecord` compare-and-swaps only over the unbound form of the record it binds (same kind and origin, no binding) and is a no-op over identical bytes.
- A well-formed record under the key that is not this transaction's is `OwnershipOccupied`, naming the subject: the key is held and this owner does not adopt what it finds. `OwnershipMalformed` is kept for a stored body that does not parse as an origin record.

#### Validation

`HostBootstrap.Ownership.Tape` lives in the private `ownership-internal` sublibrary beside the clause
producers, and holds `publishFreshRecord`, `publishBoundRecord`, `forgetRecord` and `readRecordUnder`
over one session, key and `RecordSubject`. `OwnershipCarrier` has exactly two methods, and `carryClause`
and `carryStore` are the only places the two error layers are collapsed. `carryStore` lifts through
`fromClauseFault`, not `fromStoreFault`: the tape's publish and forget flatten a store failure into an
`OwnershipFault` first, so it reaches the owner as the clause variant, while `readRecordUnder` lifts
through `fromStoreFault`. The provider owner adopted both
and is 113 lines shorter.

**The foreign-record divergence is decided against the unused key parameter.** A parameter no message
reads is one a caller cannot get right or wrong, so the tape takes none, and the refusal names the
*subject*, which is the distinction the longer wording reaches for. It reads *"the durable record
under this key is not the provider origin record this transaction publishes"*. `Tape.hs`'s module header
records the same decision. `OwnershipSpec`'s "a record another transaction published is refused, named by
subject" asserts the shared template with a test subject ("the durable record under this key is not the
sample origin record this transaction publishes"), so the decision is a test rather than a diff;
`providerSubject`'s own wording is pinned by no case.

Dated 2026-09-12 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): `cabal test all
--ghc-options=-Werror` from `core/` passed 2,526/2,526. `ProviderSpec`'s durability guard follows the
tape one layer down: the provider module names the tape's operations and no longer names
`compareAndSwapProtectedRecord`, and the tape does.

No case reaches the tape's store-failure branches: the `Left` answers of `readProtectedRecord`,
`compareAndSwapProtectedRecord` and `compareAndDeleteProtectedRecord` inside `publishFreshRecord`,
`publishBoundRecord` and `forgetRecord`, `readRecordUnder`'s `fromStoreFault`, and the unparseable-record
branch of the fresh-publish comparison. The sprint closes when `OwnershipSpec`'s tape group carries a case
that writes non-envelope bytes to `<store>/records/<key>.rec` and asserts that `readRecordUnder`,
`publishFreshRecord`, `publishBoundRecord` and `forgetRecord` each return `Left (OwnershipMalformed _)`
through the `OwnershipFault` carrier, plus a case whose stored envelope is valid but whose body is not an
origin record and asserts the same, and `cabal test all` from `core/` passes.

The tape group also carries, before the sprint closes: a stored record bound to an identity, with the same
kind and origin as a fresh record, makes `publishFreshRecord` return `Left (OwnershipOccupied _)` and leaves
the stored bytes unchanged; `publishBoundRecord` over a stored record bound to a different identity returns
`Left (OwnershipOccupied _)` with the stored bytes unchanged, over the unbound form returns `Right ()` and
stores the bound bytes, and over identical bytes returns `Right ()` without a new record version; and "a
record another transaction published is refused, named by subject" asserts
`Left (OwnershipOccupied "the durable record under this key is not the sample origin record this transaction
publishes")`.

#### Remaining Work

- `Tape.hs` `extendsThisRecord` compares kind and origin only, so `publishFreshRecord` accepts a stored
  bound record as this transaction's own, and `publishBoundRecord` compare-and-swaps over whatever the
  store holds, so a stale bound record is rebound. Accept a stored record in `publishFreshRecord` only when
  its bytes equal the fresh record's; in `publishBoundRecord`, swap only over the unbound form of `record`
  and refuse any other stored record. Add the three binding cases named in Validation.
- `Tape.hs` `foreignRecord` refuses a well-formed foreign record with `OwnershipMalformed`, the case
  reserved for an uninterpretable record. Return `OwnershipOccupied` with the same subject text for a
  record that parses, and `OwnershipMalformed` carrying the parse fault for one that does not; update the
  "named by subject" case and the module header's statement of the decision.
- `Object.hs` `storeFault` maps every `ProtectedError` to `OwnershipProbeFailed`, so a torn record under
  a shipped alias key reaches `Alias` as a probe failure that it answers with `ReprobeBeforeRetry`
  forever. Map `ProtectedMalformedRecord` to `OwnershipMalformed` and keep `OwnershipProbeFailed` for
  the rest; add the two tape cases named in Validation.
- `Tape.hs` exports `carryStore` under the heading "Carrying the two faults into a domain's own sum",
  though its body is `either (Left . fromClauseFault) Right`, and its Haddock says collapsing a store
  failure into the clause answer would lose a distinction the forget path does collapse. Rename it
  `carryClauseFault` at every call site and correct the export heading and Haddock to say the tape's
  publish and forget deliver a store failure as an `OwnershipFault` (classified by `storeFault`) and only
  `readRecordUnder` lifts through `fromStoreFault`.

### Sprint 14.15: The cluster owner adopts the record tape [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

The cluster owner holds the second full copy of the store adapter. With the tape in place its
domain-specific part is the standing check and the create-then-bind path; the rest is the tape.

#### Deliverables

- The cluster owner's publish, forget, read-back and collapse helpers are replaced by the shared tape and carrier.
- Its own error sum gains the carrier instance rather than hand-written lifting.
- The node-identity subject text is a parameter, not a copied literal.

#### Validation

The cluster owner's publish, forget, read-back and collapse helpers are gone; it holds `clusterSubject`,
`clusterTape`, and an `OwnershipCarrier ClusterOwnershipFault` instance, and is 100 lines shorter. The
node-identity phrase is `subjectBinding` on that subject rather than a literal repeated at each call.

One site did **not** move to the shared refusal and is called out rather than quietly generalised: the
retained-claim path refuses a record of the *wrong kind*, which is a different condition from a record
another transaction owns, so it keeps its own `"the retained cluster ownership record carries no owner
claim"`.

Dated 2026-09-12 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): this sprint's own
change built clean under `-Werror`, and the 2,526-test `cabal test all --ghc-options=-Werror` run from
`core/` that closed Sprint 14.16 is the first full run over it, including `ClusterOwnershipSpec` and
`ClusterReconcileSpec`. Recording it that way rather than as a run of its own is what § NN asks for: the
suite that covered this code is the one named.

#### Remaining Work

None.

### Sprint 14.16: The harness owners adopt the record tape [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/DataRoot.hs`, `core/hostbootstrap-core/src/HostBootstrap/Harness/GeneratedConfig.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`

#### Objective

These two carry the same eight helpers as each other, verbatim including their documentation
comments, and share twelve consecutive identical import lines. They are the smallest copies and the
clearest demonstration that the adapter was duplicated rather than independently derived.

#### Deliverables

- Both owners use the shared tape and carrier.
- The duplicated helpers and the duplicated import block are deleted.
- Each keeps only its own subject and its own removal-set guard.

#### Validation

Both owners hold a subject, a tape, and an `OwnershipCarrier` instance; the publish and bind helpers and
the twelve-line import block are deleted, and the two modules are 48 and 53 lines shorter. Two helpers
of the adapter still stand in each module, near-verbatim: `readRecord`, a raw `readProtectedRecord`
lifted into the domain's store-failure constructor, and `forgetFailure`, which carries the domain error
back into `OwnershipFault` under the same doc comment "Carry a store failure into the seam's fault
vocabulary". The sprint closes when neither module defines either, `OwnershipSpec`'s "every owner behind
the seam reaches the store through the tape" guard also asserts that `DataRoot.hs` and
`GeneratedConfig.hs` name neither `readProtectedRecord` nor `forgetFailure`, and `cabal test all` from
`core/` passes. Each keeps its own removal-set rule — the data root's parent-is-scaffolding and preserve-found
policy, the generated config's payload digest and refuse-found policy.

One semantic difference was found rather than assumed away. Both owners published their origin with
`ExpectAbsent` unconditionally, while the tape reads first and treats an identical record as this
transaction's own earlier write. Adopting the tape is therefore strictly more forgiving at that one point,
and the argument that the difference is unreachable — the clause seam has already refused a record under
this key before the publication runs — is checked by the suite rather than left as reasoning.

Dated 2026-09-12 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): `cabal test all
--ghc-options=-Werror` from `core/` passed 2,526/2,526, including `HarnessSpec` and
`GeneratedConfigSpec`.

#### Remaining Work

- Delete `readRecord` and `forgetFailure` from `DataRoot.hs` and `GeneratedConfig.hs`. The tape gains a
  raw read (`readRawRecordUnder :: RecordTape session -> RecordKey -> IO (Either e (Maybe
  ProtectedRecord))` for any `OwnershipCarrier e`, lifting through `fromStoreFault`) that both
  acquisitions use for their existence check, and the `forget` continuations call `forgetRecord` through
  the `OwnershipFault` carrier instead of carrying the domain error back by hand. Extend the tape guard
  as named in Validation.

### Sprint 14.17: The remaining publishers adopt the tape, and one reader decodes the wire [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`, `core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Wire/LittleEndian.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Host.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

Two owners keep single publish helpers as local definitions inside larger functions — the last copies.
Alongside them, the little-endian word reader is byte-identical in the shipped-ownership row and in the
Windows wall host, which is one wire-format decoder written twice in two unrelated modules.

#### Deliverables

- The remaining local publish helpers are replaced by the shared tape.
- Colima's origin-record read-back and forget (the directory and reported origin records it publishes
  through the tape) go through `readRecordUnder` and `forgetRecord` too, so no owner parses an origin
  record or deletes one by hand.
- The little-endian reader has one home, imported by both readers of that wire format.
- No copy of the store adapter remains; the ledger row for it is removed in the same change.

#### Validation

The shipped row's four helpers are the tape's, through an `OwnershipCarrier OwnershipFault` instance the
tape itself supplies: a row whose transaction crossed a frame has no domain sum above the seam's, so the
carrier is the identity on a clause fault. The Colima owner's three remaining local publish helpers are
the tape's too, under two subjects, because the reported origin and the host directory it creates are
different objects and their refusals name different things. Colima's stage, manifest and profile keys are
a multi-key protocol of its own rather than the origin-record adapter, and stay where they are.

`HostBootstrap.Wire.LittleEndian` is the one home for reading a fixed-width little-endian word, and both
decoders take their words from it. The remaining byte-assembling folds in this tree are *big*-endian
wires, which is a different convention rather than a third copy.

Two guards replace the two ledger rows, in `OwnershipSpec`. "Every owner behind the seam reaches the store
through the tape" names the five owners explicitly and asserts each imports the tape and names neither
compare-and-swap nor compare-and-delete; naming them is deliberate, because a guard that walked every
module would pass the day a sixth owner arrived with a sixth copy. "Both readers of the little-endian wire
share one word reader" asserts each imports the shared reader and no longer imports `Data.Bits` at all.

No run of its own is recorded for this change on 2026-09-12; the runs that cover it are the 2026-09-16
Windows runs below and the 2026-09-17 phase gate recorded in the header.

On 2026-09-16, the shipped decoder imports the shared little-endian reader on every host, including
native Windows. `cabal build all` from `core/` passes; the complete core gate passes 2,541/2,541
in 370.93 seconds. From `demo/`, `cabal test all -j1 --test-show-details=direct --test-options=--hide-successes`
passes 151/151 demo cases in 5.47 seconds and 2,541/2,541 core cases in 368.57 seconds;
the full workspace command takes 703.01 seconds. Both workspaces compile and run the provider-live
component with its declared no-request `Unsupported` outcome. The repository Python code check passes,
and `poetry run python -m hostbootstrap.test_all` passes 251/251 in 4.01 seconds. These runs use
Poetry 2.4.1 and repository-venv Python 3.14.7 on the native Windows gate host.

After recording the phase closure and the acceptance work still owed, the focused `DocValidatorSpec`
gate passes 11/11 in 4.82 seconds. It checks the phase table, sprint status, governed documentation,
and evidence against the working tree. `git diff --check` passes.

Colima's publish helpers are the tape's, but its read-back and forget of the same origin records are
not: `readReportedBinding`, `readBinding` and `readBoundRecord` in `Ensure/Colima/Ownership.hs` call
`readProtectedRecord` and `parseOriginRecord` themselves, and the bound-record forget calls
`compareAndDeleteProtectedRecord` directly. Colima is also absent from `storeAdapterOwners`, so the guard
written to stop a sixth copy does not watch it. The sprint closes when `OwnershipSpec` carries a case
"Colima reads and forgets its origin records through the tape" asserting that `Ensure/Colima/Ownership.hs`
imports the tape and names `parseOriginRecord` zero times, and `cabal test all` from `core/` passes with
`ColimaSpec` green.

#### Remaining Work

- Move `readReportedBinding`, `readBinding` and `readBoundRecord` in `Ensure/Colima/Ownership.hs` onto
  `readRecordUnder` over the tape whose subject published each record (Colima's error type gains an
  `OwnershipCarrier` instance, or uses the `OwnershipFault` one), keeping the record version each caller
  needs, and move the origin-record forget onto `forgetRecord`. Every key whose record is an
  `OriginRecord` moves; the stage and manifest records, which are not origin records, stay where they
  are. Add the guard case named in Validation.

### Sprint 14.18: The host wall's identity-conditional act is the seam's [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Host.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`, `documents/engineering/wsl2.md`

#### Objective

Clause 4's kernel-face condition (re-read the target's identity through the row and act only when it is
the bound identity, refusing an absent or different object) exists once, in the seam. The seam's own
release and the host wall's deletes and moves both reach it, so the wall stops carrying a second copy of
the clause.

#### Deliverables

- `Primitive.hs` exports `withReobservedIdentity :: OwnershipRow -> OwnedTargetPath -> ObjectIdentity ->
  (forall handle. OwnershipPrimitive handle -> IO (Either OwnershipFault a)) -> IO (Either OwnershipFault
  a)`. It applies `clauseRefusal ... ClauseRelease`, observes through `rowObserveIdentity`, refuses an
  absent or different object with `releaseConflict`, and otherwise runs the act against the same row.
- `reobserveOwnedIdentity` and `withReobservedIdentity` share one comparison function, so the two cannot
  disagree about what a match is.
- `GlobalWall/Host.hs` `withConfirmedIdentity` is deleted. `deleteWallFile` and `renameOpenFile` call
  `withReobservedIdentity` and map its conflict to `HostWallConflict (TargetReplaced _ _)` for a
  different identity and `HostWallConflict (UnexpectedTargetAbsent _)` for absence.
- The ledger row for the wall's second clause-4 copy is removed in the same change.

#### Validation

`OwnershipSpec` cases run against rows whose `rowObserveIdentity` is pure and whose other primitives
diverge: an observe answering `Right Nothing` returns the absent conflict and never runs the act; a
different identity returns the replaced conflict and never runs the act; the bound identity runs the act.
A source guard asserts that `Host.hs` names `withConfirmedIdentity` zero times. The Sprint 14.13
swap-at-act cases in `WslGlobalWallHostSpec` still return their exact constructors. `cabal test all` from
`core/` passes.

#### Remaining Work

- Add `withReobservedIdentity` and the shared comparison to `Primitive.hs`, with the three `OwnershipSpec`
  cases.
- Delete `withConfirmedIdentity` from `Host.hs`, rewire `deleteWallFile` and `renameOpenFile` onto
  `withReobservedIdentity`, and add the source guard.

### Sprint 14.19: The host wall's moves and deletes are durable and resumable mid-move [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Host.hs`,
`core/hostbootstrap-core/test/WslGlobalWallHostSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`

#### Objective

Every namespace change the host-wall driver makes is durable before the journal advances past it. Every
state an interrupted change can leave is a state the next run resolves rather than a permanent
`Blocked`.

#### Deliverables

- `renameOpenFile` calls `rowSyncParent` on the destination after a successful `rowLinkNoReplace` and on
  the source after its `rowRemoveObject`, once when both share a parent. `deleteWallFile` calls it after
  the remove. Each returns success only after the sync.
- A move stopped between link and unlink is recoverable. This covers a kill, and a failed source removal
  such as a Windows sharing violation. Before classifying, the driver detects a source and a destination
  that both carry the journalled identity and bytes, confirms the source's identity, and withdraws the
  source name. This holds for all four moves: `publishStage`, `retainOrigin`, `retireManagedTarget` and
  `publishOrigin`.
- In `WallStageBound` with the durable stage name absent, an object at the receipt's fenced `.armed` name
  whose identity is not the journalled one is this owner's own interrupted create, because the name
  embeds the never-reused fence. It is deleted by exact identity and the create is retried, as the
  `WallStageCreateOutcomeUnknown` branch does.
- `observeWallFile` pairs identity and bytes from one object: after `readWholeObject` it re-probes the
  identity and returns `HostWallBusy` if it changed, so no mixed origin is journalled.

#### Validation

`WslGlobalWallHostSpec` gains these cases, using the `rewindJournal` fixture:

- For each of the four moves, the journal is rewound to the matching outcome-unknown phase and the object
  is linked by hand under both names. The next apply or restore converges, the source name is gone, and
  the active record ends in the expected phase.
- With the journal rewound to `WallStageBound`, both stage names absent, and a foreign-identity object at
  the fenced `.armed` name, apply succeeds and the leftover is gone.
- A row wrapper whose `rowReadObject` first replaces the target makes apply return `HostWallBusy`, and no
  active record is written.
- A row wrapper records the primitive call order and asserts that a `rowSyncParent` follows every
  `rowLinkNoReplace` and `rowRemoveObject` before the next protected-store write.

`cabal test all` from `core/` passes.

#### Remaining Work

- Add the parent syncs to `renameOpenFile` and `deleteWallFile`.
- Add half-move detection and withdrawal before classification in apply and restore. In the same change,
  make `renameOpenFile` withdraw the source after an identity check when the link is refused because the
  destination already holds the same identity.
- Add the `WallStageBound` foreign-armed reclaim to `recoverDurablyBoundArmed`.
- Add the identity re-probe to `observeWallFile`.
- Write the four case families listed in Validation.

### Sprint 14.20: Re-entry admits only a record the protected store returned [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Tape.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/DataRoot.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Clause 4 from a later entry is release authority, so the record it starts from is evidence only when the
owner's own protected store returned it. `reenterOwnedObject` demands a value only the tape's read mints,
indexed by the same protected entry, so a record built in memory with `originRecord` and
`bindOriginRecord`, or parsed from bytes a caller holds, cannot be presented as release authority over
whatever object currently carries that identity.

#### Deliverables

- `Tape.hs` defines `StoredOriginRecord session`, whose constructor is private to the `ownership-internal`
  sublibrary and which discloses `storedOriginRecord` and `storedRecordVersion`. `readRecordUnder` is its
  one producer, so the type proves the record came back from this session's store.
- `reenterOwnedObject` takes a `StoredOriginRecord session` in place of an `OriginRecord`; the session
  index ties it to the entry that read it, and an unbound stored record is still refused and mints no
  token.
- Every caller re-enters from the record `readRecordUnder` returned: `Harness/DataRoot.hs`,
  `Harness/GeneratedConfig.hs`, `Ownership/Shipped.hs` and `Ensure/Colima/Ownership.hs` (whose reads go
  through the tape after Sprint 14.17), each keeping the record version it needs from
  `storedRecordVersion`.
- `reenterOwnedObject`'s Haddock states the guarantee the type now holds: re-entry starts only from a
  record this entry read out of the store.

#### Validation

`CompileFailSpec` registers `ReenterInMemoryOwnershipRecord.hs`, which passes a record built with
`bindOriginRecord` to `reenterOwnedObject` and expects the type mismatch naming `StoredOriginRecord`, and
`EscapeStoredOwnershipRecord.hs`, which presents a stored record read under one `withProtectedEntry`
continuation to re-entry under a second and expects the rigid-type-variable mismatch on `session`.
`OwnershipSpec` re-enters from a stored unbound record and asserts the existing
`OwnershipMalformed` "names no identity binding" refusal with no primitive reached, and from a stored bound
record and asserts the token discloses the stored target and identity. `DataRootSpec`,
`GeneratedConfigSpec`, `OwnershipShippedSpec` and `ColimaSpec` stay green. `cabal test all` from `core/`
passes.

#### Remaining Work

- Add `StoredOriginRecord` and make `readRecordUnder` return it; change `reenterOwnedObject` to take it and
  rewrite its Haddock, which says re-entry "does not manufacture evidence" while it admits any bound
  `OriginRecord` value.
- Move every `reenterOwnedObject` caller onto the stored record `readRecordUnder` returned, as listed in
  Deliverables.
- Write the two compile-fail fixtures and the two `OwnershipSpec` cases named in Validation.

### Sprint 14.21: A clause the host cannot hold is refused as Unsupported [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Windows.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Object.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/test/OwnershipWindowsSpec.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`, `documents/engineering/wsl2.md`

#### Objective

The ownership contract names three conditions under which a backend answers `Unsupported` and mints no
receipt: no stable object identity (clause 3), a lock the platform or filesystem cannot take (clause 1),
and a state directory that cannot be written (clause 2). Each is realized as `OwnershipUnsupported`, so a
caller sees a clause this host cannot hold rather than a probe it may retry.

#### Deliverables

- The Windows row reads the volume's filesystem name with `GetVolumeInformationByHandleW` on the handle it
  already opened, through the same narrow direct kernel boundary as its other entry points, and
  `rowObserveIdentity` answers `OwnershipUnsupported` naming the filesystem unless it is `NTFS` or `ReFS`
  (whose identity is the `FILE_ID_INFO` read of Sprint 14.9). The admitted set is one pure function,
  `windowsIdentityFilesystem :: Text -> Maybe OwnershipFault`, compiled on every host family.
- The protected store reports an exclusive lock the platform or filesystem does not support (GHC's
  `FileLockingNotSupported` from `hLock` or `hTryLock`, or an `IOError` of type `UnsupportedOperation`)
  and a root, lock file or record it is denied permission to create or write as a distinct
  `ProtectedUnsupported` failure, classified by one pure function over the exception.
- `Object.hs` `storeFault` maps `ProtectedUnsupported` to `OwnershipUnsupported`, and every
  `OwnershipCarrier` instance in this phase carries it through `fromClauseFault`, so the refusal reaches
  each owner as the unsupported clause.

#### Validation

`OwnershipWindowsSpec` applies `windowsIdentityFilesystem` to `"NTFS"`, `"ReFS"`, `"FAT32"`, `"exFAT"` and
`"FAT"` on every gate host and asserts the first two admit and the rest return
`Just (OwnershipUnsupported _)`; on a Windows gate host, `rowObserveIdentity` on a file in the case's
temporary directory (an NTFS volume) returns `Right (Just _)`. `AuthoritySpec` applies the store's
classifier to `toException FileLockingNotSupported`, to an `UnsupportedOperation` `IOError` and to a
`permissionErrorType` `IOError` and asserts `ProtectedUnsupported`, and to a `doesNotExistErrorType`
`IOError` and asserts `ProtectedIOFailure`; on a POSIX gate host not running as root, opening a store under
a directory made mode `0o555` returns `Left (ProtectedUnsupported _ _)`. `OwnershipSpec` asserts
`storeFault "op" (ProtectedUnsupported "op" "reason")` is `OwnershipUnsupported _`. `cabal test all` from
`core/` passes.

#### Remaining Work

- `Windows.hs` `identityOf` trusts the volume serial and file index on every volume. Read the filesystem
  name with `GetVolumeInformationByHandleW` and refuse through `windowsIdentityFilesystem` before building
  the identity; correct the module header's identity description to name the check.
- `Protected.hs` reports every lock and filesystem failure as `ProtectedIOFailure`, and `withProtectedEntry`
  catches only `IOError`, so `FileLockingNotSupported` escapes as an exception. Add `ProtectedUnsupported`
  and the classifier, apply it in `openProtectedStore`, `withStoreLock`, `tryStoreLock` and the record
  writes, and catch `FileLockingNotSupported` beside `IOError`.
- `Object.hs` `storeFault`: map `ProtectedUnsupported` to `OwnershipUnsupported`.
- Write the cases named in Validation.

### Sprint 14.22: Each computation the ownership rows share has one definition site [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/SourceGuard.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

§ KK requires each computation the ownership rows share — the identity read, the no-replace publication,
the identity-conditional act and the record codec — to have one definition site, held by a guard rather
than by review. After Sprints 14.17 and 14.18 remove the last owner-local copies, one guard pins every
site, so a new copy fails the suite instead of passing its own tests.

#### Deliverables

- `OwnershipSpec`'s group "each shared ownership computation has one definition site" walks every Haskell
  source under `core/hostbootstrap-core/src` and `core/hostbootstrap-core/internal` and asserts, by
  identifier count rather than substring:
  - the kernel identity read: `getSymbolicLinkStatus`, `getFileStatus`, `getFileInformationByHandle` and
    `GetFileInformationByHandleEx` feeding `mkKernelObjectIdentity` appear only in `Ownership/Posix.hs`
    and `Ownership/Windows.hs`, plus the named site `Ownership/Shipped.hs` (the symbolic-link act of the
    host-providers phase);
  - the no-replace link: `createLink` and `CreateHardLinkW` appear only in the two rows, plus the named
    sites `Config/Install/Native.hs` (the config-install primitive of the Dhall-configuration phase) and
    `Ownership/Shipped.hs`;
  - the identity-conditional act: `reobserveOwnedIdentity` and `withReobservedIdentity` are defined only in
    `Ownership/Primitive.hs`, and no module outside it defines a function that reads `rowObserveIdentity`
    and then calls `rowRemoveObject` or `rowLinkNoReplace`;
  - the record codec: `renderOriginRecord` and `parseOriginRecord` are defined only in `Ownership/Object.hs`
    and called only from `Ownership/Object.hs` and `Ownership/Tape.hs`.
- Each named site is listed with the phase that owns it, so the allow-list is a statement of the tree.

#### Validation

The guard group passes on every gate host, and each assertion is shown to bite: a case applies the same
checker to an in-memory module text that defines a second `parseOriginRecord`, and to one that calls
`createLink`, and asserts each is reported. `cabal test all` from `core/` passes.

#### Remaining Work

- Write the guard group and its two biting cases in `OwnershipSpec`, as listed in Deliverables and
  Validation.

### Sprint 14.23: The creating producers mutate only from a recorded absence [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

Clause 3 binds an object this run created, so `createOwnedDirectory` and `publishOwnedFile` create only
from a record whose origin is absence, and a publication whose no-replace link fails leaves no staging
name behind it. Both are properties of the seam's two creating producers in `Primitive.hs`, so every row
and every owner inherits them.

#### Deliverables

- `createOwnedDirectory` and `publishOwnedFile` match `originRecordOrigin record` before the record's kind
  and answer `OwnershipOccupied` for `OriginPresent _` before any primitive, so a record of something
  that was there is never bound to a fresh object after that object vanishes.
- When `rowLinkNoReplace` fails, `publishOwnedFile` withdraws the staging name through `rowRemoveObject`
  best-effort and returns the link's fault, not the withdrawal's, so an owner whose staging name is fixed
  per object (`Ownership/Shipped.hs`) is not refused on every later attempt by its own stray file.
- A failed `rowCreateFile` keeps its fault and the seam removes nothing, because that fault does not say
  whether the row's exclusive open of the staging name succeeded; `GeneratedConfig.discardStaging`, whose
  staging name carries this run's generative identifier, stays the withdrawal that covers a partially
  written staging file, and the seam's link-failure withdrawal makes its second removal a no-op.

#### Validation

The sprint closes when these `OwnershipSpec` cases exist and pass under `cabal test all` from `core/`:

- with a row declaring `fullCapabilities` whose `rowObserveIdentity` answers `Right (Just identity)` and
  whose other primitives diverge, a token recorded through `enterOwnedObject` and `recordOwnedOrigin`
  carries `OriginPresent identity`, and `createOwnedDirectory` on its `OwnedDirectory` record and
  `publishOwnedFile` on its `OwnedFile` record each return `Left (OwnershipOccupied _)` and reach no
  primitive;
- against `ownershipRowForHost` in a temporary directory, a case that records an absent `OwnedFile`
  origin, then writes a file of its own at the target, then calls `publishOwnedFile` gets the link's
  `Left (OwnershipOccupied _)`, finds no object at the staging name, and reads its own file's bytes back
  unchanged.

#### Remaining Work

- `Primitive.hs`: `createOwnedDirectory` and `publishOwnedFile` read only `originRecordKind`. Match
  `originRecordOrigin record` first and return `OwnershipOccupied` for `OriginPresent _` before any
  primitive; add the occupied-origin case listed in Validation.
- `Primitive.hs`: `publishOwnedFile` returns a failed `rowLinkNoReplace` without withdrawing the staging
  name. On a link failure, call `rowRemoveObject` on the staging name, discard its outcome, and return the
  link's fault; add the host-row staging-withdrawal case listed in Validation.

### Sprint 14.24: The object index and the reported face are held by fixture and guard [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

Both faces introduce the object index rank-2, and the reported face reaches no primitive. Today the first
is held only by the session-index fixtures and the second by a guard that bans three of the nine
primitive fields. This sprint holds each by the evidence that can hold it: a compile-fail fixture per
face for the index, and a source guard over the whole primitive vocabulary for the reported face.

#### Deliverables

- `EscapeOwnedObjectIndex.hs` declares `escapes :: OwnershipRow -> ProtectedSession session ->
  FilePath -> IO (Either OwnershipFault (Entered session escaped))` as
  `escapes row session target = enterOwnedObject row session target (\entered -> pure (Right entered))`.
- `EscapeReportedObjectIndex.hs` declares `escapes :: ProtectedSession session -> FilePath ->
  IO (Either OwnershipFault (Entered session escaped))` as
  `escapes session target = enterReportedObject session target OriginAbsent (\entered -> pure (Right entered))`.
- The guard "the reported face names no row and reaches no primitive" bans `OwnershipPrimitive`,
  `rowObserveIdentity`, `rowOpenExclusive`, `rowCreateDirectory`, `rowCreateFile`, `rowLinkNoReplace`,
  `rowReadObject`, `rowRemoveObject`, `rowCloseHandle`, `rowSyncParent` and `identityOfCreated` in the
  reported-face region, beside `OwnershipRow`, `withOwnershipRow`, `rowCapabilities` and `clauseRefusal`.
- The `reportedTests` Haddock calls that a property of the source text rather than "of their types".

#### Validation

The sprint closes when `CompileFailSpec` carries
`rejectsWith "EscapeOwnedObjectIndex.hs" ["Couldn't match type 'object' with 'escaped'"]` and
`rejectsWith "EscapeReportedObjectIndex.hs" ["Couldn't match type 'object' with 'escaped'"]` beside the
seam's other fixtures, each fixture fails with that diagnostic, the widened reported-face guard passes,
and `cabal test all` from `core/` passes.

#### Remaining Work

- Write the two fixtures under `core/hostbootstrap-core/test/compile-fail/` as listed in Deliverables,
  each with `{-# LANGUAGE RankNTypes #-}`, importing `Entered` from `HostBootstrap.Ownership.Clause`,
  `OwnershipFault` and `Origin (OriginAbsent)` from `HostBootstrap.Ownership.Object`, `ProtectedSession`
  from `HostBootstrap.Protected`, and `OwnershipRow` and the entry producer from
  `HostBootstrap.Ownership.Primitive`, and register both in `CompileFailSpec` with the diagnostics named in
  Validation.
- `OwnershipSpec`: extend the reported-face guard's banned list to the names listed in Deliverables, so a
  reported producer that took an `OwnershipPrimitive` and called `rowCreateFile` or `rowLinkNoReplace`
  fails it, and correct the `reportedTests` Haddock's "of their types".

### Sprint 14.25: The capability declaration names only what a clause requires [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Posix.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Windows.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/DataRootSpec.hs`,
`core/hostbootstrap-core/test/GeneratedConfigSpec.hs`,
`core/hostbootstrap-core/test/OwnershipWindowsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

§ NN decides `Unsupported` by a declaration the classifier reads, so `OwnershipCapabilities` declares only
the capabilities some clause requires: stable identity, no-replace publication and durable parent sync.
`holdsExclusiveOpen` gates no clause and no owner reads it before `rowOpenExclusive`, whose unavailable
rows refuse in the primitive. Its deletion touches both rows' declarations and the suites of the data
root, the generated config and the Windows row, so it lands after Sprints 14.8 and 14.9, where all of
them exist.

#### Deliverables

- `OwnershipCapabilities` has three fields, `holdsStableIdentity`, `holdsNoReplacePublication` and
  `holdsDurableParentSync`, and every one is a field `clauseRefusal` reads.
- The available and unavailable declarations in `Ownership/Posix.hs` and `Ownership/Windows.hs` declare
  those three fields.
- `ownership_seam.md` states no exclusive-open capability.

#### Validation

The sprint closes when `OwnershipSpec`'s classifier cases range over the eight combinations of the three
fields, the case "the exclusive open is a primitive rather than a clause requirement" is gone, every
suite that builds an `OwnershipCapabilities` compiles against three fields, and `cabal test all` from
`core/` passes.

#### Remaining Work

- `Primitive.hs`: delete `holdsExclusiveOpen` from `OwnershipCapabilities` and from its Haddock.
- `Ownership/Posix.hs` (the available declaration and the unavailable one) and `Ownership/Windows.hs`
  (the same two): drop `holdsExclusiveOpen`.
- `OwnershipSpec`: delete the case "the exclusive open is a primitive rather than a clause requirement",
  whose comment describes an owner check that does not exist; rewrite `everyCapability` over three
  fields so it yields eight combinations (and its Haddock's "all sixteen"), and `fullCapabilities` and
  `noCapabilities` as three-argument constructions.
- Move every other positional `OwnershipCapabilities` construction to three arguments:
  `DataRootSpec.hs` (`OwnershipCapabilities False False False False`), `GeneratedConfigSpec.hs` (the same)
  and `OwnershipWindowsSpec.hs` (`OwnershipCapabilities True True True True`).
- `documents/architecture/ownership_seam.md`: delete the sentence "`holdsExclusiveOpen` is declared by
  both rows and gates no clause."

## Remaining Work

- Sprint 14.4: wall-model phase-guard, origin, classification and malformed-record cases, strict-decoder
  cases, three compile-fail fixtures, `ConfigEncoding` split, `ConflictingWallPathShare` deletion, and
  `GlobalWall.hs` Haddock corrections.
- Sprint 14.5: exact `parseOriginRecord`, corrected `parseKind` fault texts, and `ObjectIdentity` and
  `OwnershipObjectSpec` header corrections.
- Sprint 14.7: capability gates on `createOwnedDirectory`, `publishOwnedFile` and `releaseOwnedObject`,
  the behavioural partial-capability and reobserve refusal cases, the narrowed classifier guard, and the
  `clauseRefusal` and `OwnershipSpec` header corrections.
- Sprint 14.8: lock-only occupied classification, `EXDEV`/`EMLINK` as probe failures, bracketed
  descriptors, `Expect.expectOccupied` specialised to `OwnershipOccupied`, and exact-fault, FIFO,
  permission, cross-mount and bracketed-probe cases.
- Sprint 14.9: a real `windowsSyncParent` flush, missing-parent probe failure, `FILE_ID_INFO` identity,
  attribute-only identity opens, the missing Windows-row cases and exact guards, and the reparse-point
  comment naming its live confirmation.
- Sprint 14.10: `reenterOwnedObject` Haddock states the trust re-entry extends.
- Sprint 14.11: empty-only crash-window recovery, settled absent bound records, lost-race forget,
  identity re-check before clearing, and the `DataRootSpec` cases.
- Sprint 14.12: record forget on restored absence, settled absent bound records, identity re-check
  before removal, staging withdrawal, and the `GeneratedConfigSpec` assertions.
- Sprint 14.13: absolute `USERPROFILE`, private location helpers, armed-stage fault classification,
  worst-case record bound, explicit matches, and the host-wall and Windows-wall cases.
- Sprint 14.14: malformed store records as `OwnershipMalformed`, a tape that never replaces a stored
  binding, a well-formed foreign record as `OwnershipOccupied`, the `carryStore` rename, and the tape cases.
- Sprint 14.16: `readRecord` and `forgetFailure` deleted from both harness owners through a raw tape
  read.
- Sprint 14.17: Colima's origin-record read-back and forget through the tape, with its guard case.
- Sprint 14.18: one seam-owned identity-conditional act replaces the wall's `withConfirmedIdentity`.
- Sprint 14.19: durable, resumable host-wall moves and deletes, with the armed reclaim and the
  observation re-probe.
- Sprint 14.20: re-entry demands a `StoredOriginRecord` only the tape's read mints, with its compile-fail
  fixtures.
- Sprint 14.21: a non-NTFS/ReFS Windows volume, an unsupported store lock and an unwritable state
  directory each refused as `OwnershipUnsupported`.
- Sprint 14.22: one guard holding the identity read, no-replace link, identity-conditional act and record
  codec to their definition sites.
- Sprint 14.23: occupied-origin refusal before any primitive and staging withdrawal on a failed link, with
  the occupied-origin and host-row cases.
- Sprint 14.24: the two object-index escape fixtures and a reported-face guard over every primitive name.
- Sprint 14.25: `holdsExclusiveOpen` deleted from `OwnershipCapabilities`, both rows and every suite that
  builds one.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/durable_state.md` — the surface this phase changes in it.
- `documents/architecture/ownership_invariant.md` — the four clauses, the exact guarantee, and the
  `Unsupported` rule.
- `documents/architecture/ownership_seam.md` — the seam, the two platform rows, and the clause tokens.
- `documents/architecture/unrepresentable_state.md` — the clause tokens and their compile-fail fixtures.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the gate kinds this phase closes on and the run it records.
- `documents/engineering/wsl2.md` — the portable host-wall driver and its byte transformer.

**Cross-references to add:**
- `development_plan_standards.md` § EE and § DD name this phase as the owner of the clause set.
- [rationale.md](rationale.md) explains why the clauses are stated this way and why a bare exclusive create is
  not ownership.
