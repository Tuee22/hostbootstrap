# Phase 14 — The four ownership clauses and host-local reservations

**Status**: Done
**Depends on**: Phase 3 (host tools and the closed effect vocabulary), Phase 4 (protected store),
Phase 11 (prepared operations and preconditions)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-11-03 ; Linux x86_64 gate container
hostbootstrap-plan-gate-20261029 on Windows/WSL2, GHC 9.12.4, Cabal 3.16.1.0 ;
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
`withReobservedIdentity` rather than a second copy of clause 4 (Sprint 14.25).

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
  build their answer through that one producer (Sprints 14.7 to 14.10).
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
14.12 and 14.13 consume.

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

### Sprint 14.4: The portable host-wall backend [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Host.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/ConfigBytes.hs`,
`core/hostbootstrap-core/test/WslGlobalWallSpec.hs`,
`core/hostbootstrap-core/test/WslGlobalWallHostSpec.hs`,
`core/hostbootstrap-core/test/WslGlobalWallConfigBytesSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeWallReceiptAndAuthority.hs`,
`core/hostbootstrap-core/test/compile-fail/CrossWallReservationAuthority.hs`,
`core/hostbootstrap-core/test/compile-fail/EscapeWallReservation.hs`
**Production budget**: at most 400 changed nonempty lines across three modules; one UTF-16 endianness contract
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

Own an exclusive host-global configuration file under the same four clauses, portably.

#### Deliverables

- One portable driver over a platform backend. There is one driver and one implementation of each clause;
  what a POSIX and a Windows kernel differ by is the primitive each supplies, which is a **row** of the
  frame table (§ LL). Sprint 14.7 declares that row and Sprint 14.17 holds this driver's row adoption, so the two
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
`wsl --shutdown`. The exact phase/origin/classification and malformed-record cases below exercise the public model;
the three named public compile-fail fixtures hold hidden constructors and rank-2 separation.

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

Dated2026-11-03 baseline00:20:13.680472 UTC captures73 texts,977 Haskell paths and683 compiler
fixtures at unchanged HEAD5e6a7390dba568e4487ad753ce7f9c7dea35a065. Phase13 and all71 of
its sprints are Done on their actual declared gate;the README frontier is14.4.
This sprint adds the three named public compile-fail fixtures and their CompileFailSpec registrations/
positive public admission control before any such edits. Its only new production type is private
Utf16Endianness;ConfigEncoding stores it only in its UTF-16 branch. GlobalWall's unused conflict
constructor and trust-boundary Haddocks are the other bounded production edits. Host adapter behavior,
all ownership rows,protected-store code,package descriptions,and phase13 frozen subjects stay owned
by their existing contracts. Exact pure wall-model and strict-decoder cases implement the declared
Validation;actual native/focused/all-four results follow. Only the sprint's now-gone conflict-constructor
legacy row is removed after actual focused validation;every other row stays unchanged.

Dated2026-11-03 implementation changes81 nonempty/82 physical production lines in two modules.
Private Utf16Endianness supplies LittleEndian/BigEndian only to the UTF-16 encoding branch and its
unit codecs;the UTF-8 placeholder cases disappear. The unused conflict constructor is absent.
GlobalWall's module,observation,record,authority and revalidation comments state the actual Host/
ProtectedStore trust boundary and the authority-fence check's defence-in-depth role.
The byte-merge tests assert the complete expected UTF-16 body before idempotence and cover the
specified invalid UTF-8/UTF-16/UTF-32 inputs,duplicate wsl2 section and preceding unrelated section.
The model's five new contract cases cover phase guards,changed origins,all three earlier/later apply
phases,exact restored bytes/absence,stale receipts and both retained payload checks. A20-row table
pins every validatePersistedRecord refusal message through both claimOrResumeWall and authority
admission. The armed-stage case checks actual bind refusals/replay;the two duplicated assertions are
removed from the outcome-unknown case and the three names identify their actual subjects.

Actual native core Main passes2026-11-03T00:28:57.928540+00:00 to2026-11-03T00:29:06.045211+00:00,
8.116719 seconds,parent0/empty stderr,frozen production and package metadata.
Actual native demo Main passes2026-11-03T00:28:57.930148+00:00 to2026-11-03T00:29:13.814409+00:00,
15.884360 seconds,parent0/empty stderr,frozen production and package metadata.
Actual public-compiler probe reconstructs the existing public resolver's package isolation and
selects only the actual main unit;it exposes no testing/private package. All three new fixtures fail
for their intended reason:

|Fixture|UTC start to end|Seconds|Actual named refusal|
|---|---|---:|---|
|ForgeWallReceiptAndAuthority.hs|2026-11-03T00:30:26.318306+00:00 to2026-11-03T00:30:26.463389+00:00|0.145081|GHC-01928:both WallReceipt and WallAuthority term constructors are hidden|
|CrossWallReservationAuthority.hs|2026-11-03T00:30:26.463415+00:00 to2026-11-03T00:30:26.625878+00:00|0.162472|GHC-25897:reservationId1 cannot match reservationId from the other continuation|
|EscapeWallReservation.hs|2026-11-03T00:30:26.625905+00:00 to2026-11-03T00:30:26.781798+00:00|0.155903|GHC-25897:reservationId cannot match the chosen Outside identity|

The exact contiguous diagnostic phrases are registered in CompileFailSpec;one positive public
admission/same-reservation authority control is added. Source reversals pass production81/82,
tests317/334 and docs6/7 lines before ledger removal. No package or base/warm input changes occur.
These source/probe results do not close the sprint;actual native cases and all-four results follow.

Actual native core test compilation passes2026-11-03T00:34:51.851739+00:00 to2026-11-03T00:35:00.156015+00:00,
8.304326 seconds,parent0/empty stderr,rts_thr,frozen source and metadata.
Actual native demo test compilation passes2026-11-03T00:32:54.277766+00:00 to2026-11-03T00:33:17.486123+00:00,
23.208501 seconds,parent0/empty stderr,rts_thr,frozen source and metadata.
The first51-case model/byte run at00:34:06.922225 to00:34:07.066612 UTC fails one new
assertion:an unbound present staged object classifies as UnexpectedTargetPresent,not OriginStateChanged.
The other50 cases pass. The new assertion now names that staged-object conflict;no production
behavior or preexisting golden is changed. The final native rebuild above passes with Werror intact.

Actual native model/byte selection passes all51 cases,2026-11-03T00:35:04.829146+00:00 to2026-11-03T00:35:04.970861+00:00,
0.03 reported/0.141693 wall seconds,parent0/empty stderr,frozen sources,binary and actual compiler metadata.
Actual native wall host/model/byte,three exact public refusals,positive public control and Doc selection passes all97 cases,2026-11-03T00:35:05.692186+00:00 to2026-11-03T00:35:13.975329+00:00,
8.16 reported/8.283171 wall seconds,parent0/empty stderr,frozen sources,binary and actual compiler metadata.
Only after that97-case terminal pass,the single owned conflict-constructor ledger row is removed
at2026-11-03T00:36:03.759481 UTC;all other ledger bytes remain exact. Complete source reversals
prove the model changes only its declared comments/unused constructor and the encoder only its
endianness contract. All972 unrelated old Haskell files,all683 prior compiler fixtures,all prior
compile-fail cases/resolvers/private helper,and phase13 subjects/evidence remain exact. Exactly three
fixtures are added,so the tree has980 Haskell paths. Every other subject of the prior1103-file
snapshot,including package/projects,root Python and unowned docs,is unchanged. Only the declared
Wsl2 paragraph is added. Text stays LF and scoped diff checks pass. Final deltas are81/82 production,
317/334 tests and7/8 docs lines. These source checks are not runtime completion;all-four commands
and the actual native demo run follow.

All167 actual native demo tests pass2026-11-03T00:39:50.329625+00:00 to2026-11-03T00:39:55.451793+00:00,
5.10 reported/5.122180 wall seconds,parent0,frozen source/binary/actual plan.json.
The optional reported build-info file is absent;actual metadata is frozen. Existing teardown-refusal
diagnostics remain;the suite and parent pass.

|Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0|UTC start to end|Wall seconds|Actual result|
|---|---|---:|---|
|core/:cabal test all|2026-11-03T00:40:08.709517+00:00 to2026-11-03T00:46:49.196704+00:00|400.489609|All4049 passed,375.94 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|2026-11-03T00:40:08.709842+00:00 to2026-11-03T00:46:50.283690+00:00|401.576282|All167 passed,1.77 reported seconds; All4049 passed,380.14 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|2026-11-03T00:40:08.713852+00:00 to2026-11-03T00:40:09.562401+00:00|0.848533|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|2026-11-03T00:40:08.733677+00:00 to2026-11-03T00:40:16.004492+00:00|7.270841|376 passed,6.11 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1106 audited files,980 Haskell paths and95 docs match the retained Linux tree;all full-command
frozen-after checks pass. Dated aggregate digests:

- all980:ef71f916dcadd6a1150a1058b5f4016fb258c6f81c342dd393e99b398632f224
- owned955:9a1ba1b802ef4017cd139d4568fc91fd0fe2864bb18bcfd791f07acd68ae0a50
- docs95:e0f015074aa3b5bc1eb5e8c08cfe976cba5364cac1e84b861e3008f589e6b170

The complete wall-model/byte contracts,20 malformed-record rows,armed-stage guards,stale phase and
payload checks,three exact public refusals and positive public admission control pass. The private
UTF-16 endianness contract has no UTF-8 placeholder branch. Only the validated unused-conflict ledger
row is removed,after actual97-case validation;all other ledger bytes remain exact. All972 unrelated
old Haskell files,683 prior compiler fixtures,all prior compiler cases/resolvers/private helper,
phase13 frozen subjects/closed evidence,and all other prior1103 tree subjects stay unchanged.
Exactly three fixtures are added. Source reversals pass81/82 production,317/334 tests and7/8 docs
lines. No package edge or base/warm inputs change;root Python/phase1 evidence remain current.
Provider-live is not requested/Unsupported;no live-provider claim is made. The phase's own declared
gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T00:47:01.488727+00:00 to 2026-11-03T00:47:09.131718+00:00,
7.643018 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.5: The owned-object vocabulary [Done]

**Status**: Done
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

Dated2026-11-03 baseline00:47:34.563893 UTC captures80 texts,980 Haskell paths and686 compiler
fixtures. Sprint14.4 is Done on all four actual commands plus closed-status Doc validation;the
README now names14.5 with11 Active/8 Planned. Only Object.hs and OwnershipObjectSpec change
implementation in this sprint;no new type,fixture,module,package edge or base/warm input is added.

The parser returns a record only when its actual renderOriginRecord bytes equal the original input.
The five declared whitespace/CRLF variants remain registered in the refused-record table. Missing
file digest and reported-object claim failures name their actual missing fields,and each has an exact
named assertion. Identity and record Haddocks describe validated/supplied data rather than kernel or
observation provenance. The spec header distinguishes its pure groups from source/Cabal reads.
Its redundant single-file round trip is removed;the existing full round-trip table remains. Clause
assertion/case labels name registration/importer/role checks,with import privacy retained by the
unchanged public compile-fail fixture. The two architecture pages state exact byte admission and the
identity bounds;the obsolete whitespace-tolerance gap is removed. Initial source reversals measure
35/35 production lines in one module,32/32 tests and14/15 docs. These source checks make no runtime
completion claim;actual native/focused/all-four results follow.

Actual native core Main passes2026-11-03T00:52:13.934900+00:00 to2026-11-03T00:52:40.180505+00:00,
26.245764 seconds,parent0/empty stderr,frozen production and package metadata.
Actual native demo Main passes2026-11-03T00:52:13.943142+00:00 to2026-11-03T00:52:47.008439+00:00,
33.065497 seconds,parent0/empty stderr,frozen production and package metadata.
Actual native test builds,complete vocabulary/public-boundary cases and all-four results follow.

Actual native core test compilation passes2026-11-03T00:53:52.050492+00:00 to2026-11-03T00:54:35.033081+00:00,
42.982846 seconds,parent0/empty stderr,rts_thr,frozen source and metadata.
Actual native demo test compilation passes2026-11-03T00:53:52.058516+00:00 to2026-11-03T00:54:11.068730+00:00,
19.010330 seconds,parent0/empty stderr,rts_thr,frozen source and metadata.
Actual native complete ownership vocabulary selection passes all22 cases,2026-11-03T00:55:16.573482+00:00 to2026-11-03T00:55:16.705586+00:00,
0.05 reported/0.132087 wall seconds,parent0/empty stderr,frozen source,binary and actual compiler metadata.
Actual native vocabulary,public constructor/import boundaries and Doc selection passes all44 cases,2026-11-03T00:55:17.374184+00:00 to2026-11-03T00:55:24.233946+00:00,
6.75 reported/6.859785 wall seconds,parent0/empty stderr,frozen source,binary and actual compiler metadata.
Complete source reversals prove only the declared canonical admission,two fault texts and
identity/record comments change in the vocabulary. The spec changes only its five refusal inputs,
two exact fault cases,declared duplicate-case deletion,header and registration labels. All978 other
Haskell files,all980 paths,all686 compiler fixtures,and every other prior1106-file snapshot subject
remain exact. Phase13 and14.4 closed subjects/evidence,package/project metadata and root Python
stay unchanged. Text is LF;scoped diff checks pass. Final deltas are35/35 production,32/32 tests
and14/15 docs lines. No base/warm inputs change. Actual native demo and all-four static results
follow;the source checks alone make no runtime completion claim.

All167 actual native demo tests pass2026-11-03T00:57:05.909849+00:00 to2026-11-03T00:57:11.033332+00:00,
5.10 reported/5.123495 wall seconds,parent0,frozen source/binary/actual plan.json.
The optional reported build-info file is absent;actual metadata is frozen. Existing teardown-refusal
diagnostics remain;the suite and parent pass.

|Final host-static command,retained Linux x86_64/GHC9.12.4/Cabal3.16.1.0|UTC start to end|Wall seconds|Actual result|
|---|---|---:|---|
|core/:cabal test all|2026-11-03T00:57:22.726906+00:00 to2026-11-03T01:03:50.759773+00:00|388.035218|All4050 passed,310.68 reported seconds;Cabal PASS,parent0|
|demo/:cabal test all|2026-11-03T00:57:22.726723+00:00 to2026-11-03T01:03:44.837944+00:00|382.113534|All167 passed,1.39 reported seconds; All4050 passed,310.92 reported seconds;Cabal PASS,parent0|
|root/:poetry run python -m hostbootstrap.check_code|2026-11-03T00:57:22.726822+00:00 to2026-11-03T00:57:23.504856+00:00|0.778020|Ruff/Black/mypy pass,parent0|
|root/:poetry run python -m hostbootstrap.test_all|2026-11-03T00:57:22.739432+00:00 to2026-11-03T00:57:29.641214+00:00|6.901804|376 passed,5.95 reported seconds;100% coverage,1585 statements/460 branches,zero missed/partial,parent0|

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All1106 audited files,980 Haskell paths and95 docs match the retained Linux tree;all full-command
frozen-after checks pass. Dated aggregate digests:

- all980:69ffab4cb8e61b7e467fae74f152b5605afa951d7c8acde557ce3bd5849378a0
- owned955:f37f2b1953c2b890cd3a696dd05a64b8288e6f3c3074c3175479830ca36ed256
- docs95:eb36b3ddef7c704d84e042d1a0850f5098e3e67d234c4fcb368c5df690e0da61

The exact codec,all five whitespace/CRLF refusals,two exact missing-field messages,complete existing
round-trip table,identity/payload/fault cases,registration/importer/role contracts and public import/
constructor boundaries pass. All978 unrelated Haskell files,all686 compiler fixtures,and every other
prior1106-file snapshot subject stay exact. Phase13 and14.4 closed subjects/evidence remain current.
Source reversals pass35/35 production,32/32 tests and14/15 docs lines. No new type,fixture,package
edge or base/warm input is added;root Python/phase1 evidence stay unchanged. Provider-live is not
requested/Unsupported;no live-provider claim is made. The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T01:04:19.998212+00:00 to 2026-11-03T01:04:25.854360+00:00,
5.856167 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

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
`CompileFailSpec`'s `rejectsWithUsing` splits recognized error diagnostics before normalization and
assigns each complete expected phrase to a distinct diagnostic block (§ HH),so a warning or another
block's fragment cannot report the boundary as held. Running
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

### Sprint 14.7: The ownership primitive seam [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Production budget**: at most 400 changed nonempty lines in three modules; one ownership-row capability adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

One seam of kernel primitives, and the producers that turn them into the four clauses. This sprint owns
the seam's shape and its capability gates. Sprint 14.38 holds the creating producers to a recorded
absence and withdraws a failed link's staging name, Sprint 14.39 holds the object index and the reported
face by fixture and guard, and Sprint 14.40 narrows `OwnershipCapabilities` to the fields a clause reads,
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
the mirror case observes that a declared capability really is reached. The entry/re-entry cases use the fully divergent row;later
capability cases use a pure absent observation while every mutating primitive remains divergent.
Recording,binding,re-observation and all three mutators have behavioural refusal cases. The source
guard holds only the identifier count and exact gate spellings;the cases below hold refusal ordering.

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

Dated2026-11-03 baseline01:06:40.981384 UTC captures82 texts,980 Haskell paths and686 compiler
fixtures. Sprint14.5 is Done on all four actual commands and closed-status Doc validation;14.6 is
already Done,so14.7 is the next Active sprint. This bounded owner adoption applies the existing
classifier before the three mutating kernel-face producers reach a primitive. It adds no type,API,
fixture,module or package edge. The five declared behavioural groups are extended with direct
directory-create and object-release tests under missing parent sync,so every newly gated mutator
has a refusal case rather than relying only on a source count.

The plan also corrects14.6's stale matcher sentence:the current public harness splits recognized
error diagnostics before normalization and assigns each complete expected phrase to its own block.
Sprint5.10 is already Done;the source confirms this current behavior. No14.6 implementation or
completion status changes. Actual native/focused/all-four validation follows.

The implementation adds four existing-classifier calls before the three mutators reach a primitive:
ClauseRecord for directory creation;ClauseRecord then ClauseBind for file publication;ClauseRecord
for removal. All prior full-capability bodies retain their behavior. The classifier Haddock names
the gate each kernel-face producer applies and distinguishes the reported face with no row.

Seven new cases use the declared pure-observe/diverging row to prove refusal before publication,
write/link,create/remove/forget,wrong-kind operations,payload mismatch and re-observation. The complete
classifier matrix remains. The shape case now names only identifier count/gate spellings and expects
12 actual identifiers,including all three named mutator contexts. No primitive counter,stand-in
executable or production test branch is introduced. The seam page states the current row's per-call
requirements. Source reversals measure117/117 production lines in one module,121/125 tests and6/7
docs lines. No type,fixture,package or base/warm inputs change. Actual native/focused/all-four results
follow;the source deltas alone make no runtime completion claim.

Actual native core Main passes2026-11-03T01:12:25.368172+00:00 to2026-11-03T01:12:43.101823+00:00,
17.733756 seconds,parent0/empty stderr,frozen production and package metadata.
Actual native demo Main passes2026-11-03T01:12:25.379182+00:00 to2026-11-03T01:12:50.432866+00:00,
25.053837 seconds,parent0/empty stderr,frozen production and package metadata.
Actual native test compilation,behavioural refusal cases,public boundaries and all-four results follow.

Dated 2026-11-03 native Windows validation: core test compilation passes in 49.615123 seconds;
demo test compilation passes 01:13:44.726300 to 01:14:01.203910 UTC in 16.477710 seconds. Both exit 0
with empty stderr and unchanged source/package snapshots. All 34 OwnershipSpec cases pass at
01:17:43.145641 to 01:17:43.391072 UTC (0.245410 wall, 0.16 reported seconds). The broader 55-case
ownership/public-boundary/Doc selection passes at 01:17:48.566811 to 01:17:55.836479 UTC
(7.269693 wall, 7.16 reported seconds), with empty stderr and frozen inputs. Native Demo passes
all 167 cases at 01:18:07.721227 to 01:18:12.854129 UTC (5.132915 wall, 5.11 reported seconds);
its expected negative-fixture stderr is retained in the harness artifact. No case is skipped.

The complete gate/body reversals preserve all prior full-capability computations and prior cases
outside the declared group/import/header/shape changes. All 978 other Haskell files, all 686 fixtures,
all 980 paths, prior phase closure subjects and all other prior 1,106 audited subjects remain exact.
The seam page also corrects its list reference to five gaps, matching the five current bullets.
There is no sprint-owned legacy-ledger row to remove. The full four-command gate results follow.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T01:19:11.140903+00:00 to 2026-11-03T01:26:11.298937+00:00 | 420.160660 | 4057 cases pass, 357.01 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T01:19:11.141064+00:00 to 2026-11-03T01:26:04.579928+00:00 | 413.441448 | 167 cases pass, 1.80 reported seconds; 4057 cases pass, 355.97 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T01:19:11.156809+00:00 to 2026-11-03T01:19:11.956522+00:00 | 0.799701 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T01:19:11.150882+00:00 to 2026-11-03T01:19:18.460098+00:00 | 7.309245 | 376 pass, 6.20 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,106-file matched Windows/Linux snapshot. Dated aggregate digests:

- all980: 9c61a423e3e24094a8432088b6391fe5f36d2efecaa9ed29174a6683d8099a74
- owned955: d556a900ba2f3647bf3fcfbd1b966f0bcab15d5323fdb9225f3c3131deef3880
- docs95: bbcb188030c7c551596be6dd35c29a4ef887c3a28568106675212ea84aae1d58

The classifier matrix, all seven mutator/refusal cases, existing re-entry/reported/tape cases,
and four public compiler boundaries pass. All prior mutator bodies and all 686 compiler fixtures
remain exact outside the four gates and declared Haddock; all 978 unrelated Haskell files remain exact.
No new contract, fixture, module, package edge or base/warm input is introduced. Phase 1 evidence and
all prior phase closure subjects remain current. Provider-live is not requested/Unsupported; this is
no live-provider evidence. The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T01:26:23.697384+00:00 to 2026-11-03T01:26:30.051319+00:00,
6.353956 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.8: The POSIX ownership row [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Posix.hs`,
`core/hostbootstrap-core/test/OwnershipPosixSpec.hs`,
`core/hostbootstrap-core/test/Expect.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Production budget**: at most 400 changed nonempty lines in three modules; one POSIX-row ownership adoption
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

Dated 2026-11-03 work scope: Sprint 14.7 is Done on all four actual static commands and its
closed-status Doc validation. The current owner is the next Active sprint, 14.8. The POSIX row
separates lock-request contention from permission faults, classifies cross-mount and link-count
failures as situational probes, and protects each newly acquired descriptor through a masked
transfer with exception cleanup. The shared occupied assertion names only OwnershipOccupied.
The declared FIFO, two permission, cross-mount and assertion-control cases retain fixed family
sizes; the process-death probe is bracketed. Permission prerequisites are stated when root bypasses
mode bits; a separate non-root POSIX selection will exercise both mode-denial paths before closure.
Native refusing-row compilation, actual POSIX kernel cases and the full four-command gate remain due.

The 01:26:48.354414 UTC baseline captures 85 texts, 980 Haskell paths and 686 compiler fixtures.
The implementation is 42 nonempty/43 physical production lines in one module; tests are 154/164
lines across the existing spec, shared assertion and manifest, and governed docs are 17/19 lines.
The classifier uses symbolic errno at the lock request and preserves full-capability primitive
behavior; cross-device and link-limit reasons are explicit probes. IOException results remain
classified before descriptor close, and an escaping exception closes the descriptor exactly once.
The five added cases retain 25 total spec cases: three declaration/assertion controls and 22 row
cases, with conditional-family sizes 6 identity, 7 publication, 5 exclusion and 4 removal. The
existing process probe is bracketed through termination/reap. No type, fixture, package, executable
or production test branch is introduced. Actual compiler and runtime validation remains due.

Dated 2026-11-03 actual compiler/runtime evidence, unchanged source throughout each run:
native Windows core Main passes 01:28:02.019510 to 01:28:11.450415 UTC (9.430962 seconds),
demo Main passes 01:28:02.032121 to 01:28:10.872659 UTC (8.840595 seconds), core test compilation
passes 01:28:16.360938 to 01:29:43.526294 UTC (87.165904 seconds), and demo test compilation
passes 01:28:16.377180 to 01:28:18.849130 UTC (2.471964 seconds). All exit 0 with empty stderr;
both test binaries declare the threaded RTS. Linux cabal build all --enable-tests passes
01:28:02.114927 to 01:30:39.502240 UTC (157.388282 seconds), parent 0; its only stderr is the
existing package-index age advisory.

The native ownership-row/Doc selection passes 69 checks at 01:29:58.194075 to 01:30:04.743556 UTC
(6.549499 wall, 6.39 reported seconds), empty stderr, including the real Windows occupied cases
under the stricter shared assertion and POSIX unavailable-row refusals. Native Demo passes all
167 cases at 01:29:57.960010 to 01:30:03.103011 UTC (5.143010 wall, 5.12 reported seconds);
the retained negative-fixture diagnostics are expected, with parent 0 and frozen inputs.

Linux /OwnershipPosixSpec/ selects 25 spec cases and four manifest checks. The launcher's initial
catalogue assertion expected only the 25 spec entries and stops before execution; with the actual
29-entry selection, both root and uid 65534 pass all 29 at 01:31:03.478714 to 01:31:03.921816 UTC
(0.443084 wall, 0.13 reported seconds) and 01:31:03.478840 to 01:31:03.921680 UTC
(0.442825 wall, 0.13 reported seconds), respectively. The root run states both mode-bit prerequisite
exceptions; the unprivileged run has no SKIP output and exercises both denial paths, the FIFO guard,
actual cross-mount refusal, lock contention/process-death release and exact absence/removal faults.
Both have empty stderr and frozen snapshots. The catalogue expectation changes only the temporary
launcher, not a case or the implementation.

Preservation passes for all 976 other Haskell files, all 980 paths, all 686 compiler fixtures,
all other prior 1,106 audited subjects, prior phase closure subjects, every other sprint in this
phase, package metadata and root Python/phase 1 inputs. LF and scoped git diff --check pass.
No sprint-owned legacy-ledger row applies. The full four-command gate results follow.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T01:31:52.091408+00:00 to 2026-11-03T01:38:44.496463+00:00 | 412.407638 | 4062 cases pass, 373.32 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T01:31:52.091226+00:00 to 2026-11-03T01:39:58.373580+00:00 | 486.285403 | 167 cases pass, 1.81 reported seconds; 4062 cases pass, 355.30 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T01:31:52.090708+00:00 to 2026-11-03T01:31:52.945138+00:00 | 0.854416 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T01:31:52.091120+00:00 to 2026-11-03T01:31:59.477896+00:00 | 7.386806 | 376 pass, 6.23 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,106-file matched Windows/Linux snapshot. Dated aggregate digests:

- all980: 11274d860d2831583bc873f1a0176ab92ae9fa79897d98c4a63523ea39eb2200
- owned955: f280cb7ed03678b18d05e37bb2f1f0591b3beb963f0d762354d331ed97260ff3
- docs95: 3f502d0726ba05ddc30b06fc4b07923ce2d9d410c2cd01e7f501a5029884ebf0

The exact occupied/probe/unsupported distinctions, FIFO regular-file guard, real cross-mount
refusal, permission denials under uid 65534, process-death release, absent removal and parent sync
cases pass. Root gate runs state the two mode-bit prerequisite exceptions; the independent
unprivileged selection exercises both paths with no skips. Existing Windows occupied cases pass
with the same shared assertion. All 976 unrelated Haskell files and all 686 compiler fixtures
remain exact; no new contract, fixture, module, package edge or base/warm input is introduced.
Phase 1 evidence and prior phase closures remain current. Provider-live is not requested/Unsupported;
no live-provider or crash-durability claim is made. The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T01:40:07.152236+00:00 to 2026-11-03T01:40:13.203658+00:00,
6.051443 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T01:40:21.154377+00:00 to 2026-11-03T01:40:27.188149+00:00,
6.033793 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.9: The symbolic-link interpreter adopts the row's identity observation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`
**Production budget**: at most 400 changed nonempty lines in three modules; one interpreter call-site adoption
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

The symbolic-link interpreter obtains identity through the selected native ownership row. The
platform rows are the kernel-identity readers; the interpreter classifies the observed kind and
link target and uses the row's answer to identify that observation. This bounded adoption keeps
the shared identity encoding contract confined to its vocabulary and two platform-row modules.

#### Deliverables

- `observeSymbolicLink` uses `rowObserveIdentity` under `ownershipRowForHost` and never builds a
  kernel identity from filesystem status words itself.
- An initial authoritative absence remains `SymbolicLinkAbsent`. An identity present before the
  kind/target observation is checked again afterward; a changed or vanished object is refused.
- The existing POSIX status and link-target reads retain their direct kernel bindings. The row's
  probe faults propagate without becoming an absence; no workflow or new primitive is added.
- The Windows-family symbolic-link refusal and all existing wire, retry, crash-window and
  replacement-safe release cases remain registered.

#### Validation

`OwnershipShippedSpec` holds the interpreter's source boundary: no kernel identity constructor or
device/inode reader is named there, and its identity observation reaches the selected row.
`ProviderAliasSpec`'s "create, exact retry, and release use one durable identity" compares the returned
alias identity with the production row's actual observation. Its five real-kernel cases cover exact
retry, an unmanaged alias, interrupted origin publication, interrupted pre-publication binding and
interrupted unlink. The complete shipped interpreter/crossing and Doc selections pass, along with
all four host-static commands. Other hosts assert their declared symbolic-link refusal.

Dated 2026-11-03 baseline 01:40:52.818915 UTC captures 88 texts, 980 Haskell paths and 686
compiler fixtures. Sprint 14.8 is Done on all four commands, closed-status Doc validation and
matched Linux snapshot. The bounded caller adoption precedes the shared identity-byte contract:
the row's vocabulary and two platform modules can then implement that contract within the
three-module budget. The plan's sprint references, standards pointer and legacy-ledger ownership
references are renumbered together; phase numbers and their dependency order are unchanged.
The split plan passes all 17 Doc checks at 01:40:21.154377 to 01:40:27.188149 UTC, parent 0.

The implementation is 54 nonempty/54 physical production lines in one module, tests are 13/13
lines in two existing specs and docs are 4/5 lines. The direct kernel identity constructor and
status device/inode imports are absent from the interpreter. Its selected-row observation brackets
the direct kind/target read and refuses an identity change; initial absence remains authoritative
and a row fault propagates. The new source boundary counts actual identifiers and the row-call
token sequence; the existing real alias retry case compares the returned identity with the actual
row observation. No type, fixture, module, package edge or production test branch is added.
Actual compiler, focused runtime and all-four validation results follow.

Dated 2026-11-03 actual compiler/runtime results, with frozen inputs throughout each command:

| Command or selection | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core Main | 2026-11-03T01:42:06.134062+00:00 to 2026-11-03T01:42:12.176515+00:00 | 6.042490 | parent 0; empty stderr |
| Native demo Main | 2026-11-03T01:42:06.126495+00:00 to 2026-11-03T01:42:13.432260+00:00 | 7.305807 | parent 0; empty stderr |
| Native core test compilation | 2026-11-03T01:42:21.589653+00:00 to 2026-11-03T01:42:30.206710+00:00 | 8.617108 | parent 0; empty stderr |
| Native demo test compilation | 2026-11-03T01:42:21.601416+00:00 to 2026-11-03T01:42:25.944522+00:00 | 4.343129 | parent 0; empty stderr |
| Linux cabal build all --enable-tests | 2026-11-03T01:42:06.204585+00:00 to 2026-11-03T01:42:48.102207+00:00 | 41.897863 | parent 0; existing package-index age advisory only |
| Native shipped/alias/public compiler/Doc selection | 2026-11-03T01:42:50.193989+00:00 to 2026-11-03T01:42:57.861487+00:00 | 7.667528 | parent 0; 66 checks pass, 7.52 reported seconds; empty stderr |
| Linux shipped/alias/public compiler/Doc selection | 2026-11-03T01:43:24.410108+00:00 to 2026-11-03T01:43:30.839300+00:00 | 6.429213 | parent 0; 66 checks pass, 6.06 reported seconds; empty stderr |
| Native complete demo suite | 2026-11-03T01:42:50.119636+00:00 to 2026-11-03T01:42:55.255171+00:00 | 5.135550 | parent 0; 167 checks pass, 5.11 reported seconds; expected negative-fixture diagnostics retained |

Both 66-check selections include every shipped interpreter/crossing and alias case, the new source
boundary, actual returned-identity comparison, all four ownership compiler fixtures and all Doc
cases. The Linux alias family exercises the actual POSIX row; native Windows asserts the declared
symbolic-link refusal. No conditional family changes or disappears. All other interpreter computations,
all prior shipped/alias cases, all other seam prose, 977 unrelated Haskell files and all 686 compiler
fixtures remain exact. Package metadata, root Python/phase 1 inputs, all other sprints and the
renumbered standards/ledger references remain exact from the declared baseline. LF and scoped
git diff --check pass. Source reversals are 54/54 production, 13/13 tests and 4/5 docs lines.
No sprint-owned legacy-ledger row applies. The actual final four-command results follow.

The first four-command run passes both Python legs (376 tests, 100% coverage) but both Cabal
legs report the same single failure out of 4,063: PortabilitySpec's "a separator rewrite lives only
in SourceGuard and PlatformPath". The native test guard's standalone backslash token is parsed
as a forbidden separator literal. Core runs 01:44:43.862265 to 01:50:42.207843 UTC (358.347818 wall,
322.38 reported seconds); demo runs 01:44:43.861867 to 01:50:23.055574 UTC (339.195824 wall,
324.87 core reported seconds; its 167 demo cases pass). Both parents exit 1 and keep frozen inputs.

The owner guard now lexes the complete expected Haskell call with SourceGuard.haskellTokens,
preserving the complete adjacent-token assertion without a standalone separator literal.
PortabilitySpec, SourceGuard and production behavior are unchanged. Focused regression and the
complete final four-command run remain due; no completion is claimed for the failed commands.

The revised guard compiles natively at 01:51:56.599112 to 01:52:05.785001 UTC (9.185949 seconds,
parent 0, empty stderr, threaded RTS), and on Linux at 01:51:56.620859 to 01:52:36.501276 UTC
(39.880647 seconds, parent 0, existing package-index advisory only). All 91 shipped/alias/public
compiler/Doc/Portability checks pass natively at 01:52:15.431863 to 01:52:28.749416 UTC
(13.317617 wall, 13.20 reported seconds), and on Linux at 01:52:58.622291 to 01:53:26.103325 UTC
(27.481185 wall, 27.01 reported seconds). Both have empty stderr and unchanged snapshots.
The existing separator policy is now satisfied without changing that policy or weakening the
complete expected-call token sequence. The repeated full preservation audit passes at 01:52:58.756672
UTC, including all 977 unrelated Haskell files, all 686 compiler fixtures and all prior subjects.
Measured deltas remain 54/54 production, 13/13 tests and 4/5 docs lines. The final four-command
rerun remains due.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T01:53:59.068560+00:00 to 2026-11-03T02:00:29.499063+00:00 | 390.432943 | 4063 cases pass, 352.78 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T01:53:59.068904+00:00 to 2026-11-03T02:00:06.615264+00:00 | 367.548659 | 167 cases pass, 2.25 reported seconds; 4063 cases pass, 358.30 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T01:53:59.068691+00:00 to 2026-11-03T01:54:00.099522+00:00 | 1.030819 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T01:53:59.068813+00:00 to 2026-11-03T01:54:06.823811+00:00 | 7.755031 | 376 pass, 6.51 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,106-file matched Windows/Linux snapshot. Dated aggregate digests:

- all980: 53b053698a2f503f4869b06eb4817e74ce75da12f7aeebf146349f4221bf378c
- owned955: e92832b7fa45082464bf87f72a5a1827915bf0f0c53f372c5d6a724b9783936e
- docs95: b2690bf36e8a058d832b5b7c00a9fee4b258e74def16578d7ff3bbd33b3113dc

The complete shipped/alias/public compiler/Doc selections pass on native Windows and Linux,
with actual alias identity evidence on the POSIX row and declared symbolic-link refusal elsewhere.
All other interpreter computations, prior shipped and alias cases, other seam prose, 977 unrelated
Haskell files and all 686 compiler fixtures remain exact. The declared plan renumbering preserves
phase order and the standards/ledger pointers match their new sprint owners. No type, fixture,
module, package edge or base/warm input is introduced; phase 1 evidence and prior phase closures
remain current. Provider-live is not requested/Unsupported; no live-provider claim is made.
The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T02:01:14.199752+00:00 to 2026-11-03T02:01:20.575749+00:00,
6.376021 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.10: The Windows ownership row [Done]

**Status**: Done
**Production budget**: at most 400 changed nonempty lines in three source modules; one kernel-identity byte contract
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Windows.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Row.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Posix.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Object.hs`,
`core/hostbootstrap-core/test/OwnershipWindowsSpec.hs`,
`core/hostbootstrap-core/test/Expect.hs`,
`core/hostbootstrap-core/test/OwnershipObjectSpec.hs`,
`core/hostbootstrap-core/test/OwnershipPosixSpec.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`,
`core/hostbootstrap-core/test/ProviderResumeSpec.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/Spec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`,
`documents/engineering/testing.md`,
`documents/engineering/wsl2.md`

#### Objective

The same primitives a Windows kernel supplies, and the one selector between the two rows.

#### Deliverables

- Byte-range exclusive **open of one object**, handle-based volume and file identity, reparse-point
  refusal, and atomic no-replace publication. As on the POSIX row, this opens objects and does not supply
  clause 1. The identity is the full `FILE_ID_INFO` (volume serial plus 128-bit file id) read with
  `GetFileInformationByHandleEx`, because the 64-bit `nFileIndex` is not unique on ReFS.
- A create under a missing parent directory is a probe failure (`OwnershipProbeFailed`), as on the POSIX
  row; only `ERROR_FILE_EXISTS` is an occupied name.
- Where a public binding flattens a status used for recovery, a narrow direct kernel call captures it,
  with no C shim and no package-description c-sources. These calls distinguish missing and occupied
  names, unavailable hard links, identifier-read failures and directory-flush failures.
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
2026-09-16 native Windows core gate below runs that case; Sprint 14.17 owes pinning its message to the
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
- "the selector row names and CPP arms stay closed" asserts that `Row.hs` carries no `#elif` and that the
  set of lower-case row-value identifiers ending in `OwnershipRow`, together with its selector,
  excludes the generic `withOwnershipRow` eliminator and is exactly `posixOwnershipRow`,
  `windowsOwnershipRow` and `ownershipRowForHost`, so a third CPP arm selecting a third row fails it;
- the live-holder probe child runs under `bracket` (or `withCreateProcess`) that terminates and waits for
  it, so a failed contention assertion leaves no blocked process behind.

Dated 2026-11-03 baseline 02:01:52.814726 UTC captures 93 texts, 980 Haskell paths and 686
compiler fixtures after Sprint 14.9 closes on all four commands and 17 closed-status Doc checks.
The prior gate leaves only container init/sleep after completion. The current bounded contract
uses a 64-bit volume followed by an 8-byte POSIX or 16-byte Windows object identifier. Object,
Posix and Windows are the only production modules to change; the selector and host-wall volume
comparison are inspected and held by guards. The numeric identity fixtures share one test adapter,
preserving their existing POSIX bytes. The Windows known-answer case directly supplies 16 object
bytes and expects 24 total. No new type, physical module, fixture executable, package edge or
base/warm input is planned.

The Windows row reads FILE_ID_INFO through GetFileInformationByHandleEx, observes attributes
without requesting file contents, flushes the opened parent directory through FlushFileBuffers,
and reports a missing create parent as a probe fault. Real process, in-process contention,
junction, symbolic-link, denied-read and flush cases run on this native Windows host; the same
registered families assert the row's refusal on Linux. Shared test-only probe mechanics avoid
a copied lock-probe driver. New descriptors/handles are protected through masked transfer and
exception cleanup. Actual implementation, compiler and runtime validation remain due.

The byte contract and both platform adoptions are implemented within three production modules.
The initial source-only draft measures 160 changed nonempty lines (28 Object, 25 Posix, 107 Windows);
the vocabulary's generic-identity Haddock is also clarified in the same owner. The shared POSIX
status encoder serves ordinary identity observation and the manifest. Windows reads the full
24-byte FILE_ID_INFO structure, opens identity with FILE_READ_ATTRIBUTES, and opens/flushed parents
under masked transfer/finally cleanup with exact raw status classification. Missing create parents
are probe faults. This is source evidence only; compiler and kernel results remain due.

The existing four numeric identity fixture adopters retain every prior body value and operation,
changing only imports and the shared adapter call name. The complete baseline reversal proof passes
at 02:09:25.888562 UTC. The Windows known answer independently supplies sixteen nontrivial object
bytes and expects the complete twenty-four-byte volume-first encoding. No golden is derived from
the observed output. The seam page reflects the implemented calls and explicitly owes native
validation. Full Windows case coverage, stronger guards, manifests and all four final commands
remain due.

The complete case set and source guards are implemented. Windows declares 24 kernel cases in
families of 7 identity, 6 publication, 6 exclusion and 5 removal; POSIX declares 23 in families
of 6 identity, 8 publication, 5 exclusion and 4 removal. Thirteen new Windows cases exercise the
four symbolic-link clauses, junction identity/open/remove, missing-parent creation, a failed
non-directory observation, denied content reads with preserved identity, in-process contention,
kernel release after real process death and absent removal. The existing parent case flushes
after both creation and removal, and handle reads assert their close result. Shared Expect
mechanics own the real-child probe, readiness and reopen rather than duplicating a row driver.
Two pure cases hold the 8/16-byte admission and unchanged POSIX known answer.

The Windows observation now confirms a missing path against real ancestor attributes, because
ERROR_PATH_NOT_FOUND also names an existing non-directory ancestor. Every opened ancestor is
closed under masked transfer/finally. An actual directory establishes absence; a non-directory
or an unobservable root is a probe fault. The no-follow guard holds exactly five observationFlags
identifiers, all six openObject callers and their named final flags; the selector guard rejects
a third CPP arm or row name. The host wall's decoder retains the complete variable-width identity
and its identityVolume takes exactly the first eight bytes. Its FILE_ID_INFO-width Haddock is
consistent with the new encoder and needs no production change.

The source audit at 02:29:38.813552 UTC measures 197 nonempty/203 physical production lines in
three modules, 454/471 test lines and 50/51 documentation lines, with complete baseline reversals.
The canonical WSL page also describes the full Windows file id and real parent flush; its separate
filesystem-admission gap remains owned here. Main builds before the ancestor check pass on native
core/demo and Linux; the final source and complete test set require fresh compiler validation.
No fixture, module, package edge, base/warm input or unrelated golden is added or rebased.
Actual final compiler, focused and all-four runtime results remain due.

Actual final native application builds pass 02:32:45.396341 to 02:32:55.871977 UTC for core
(10.475678 seconds) and 02:32:45.396931 to 02:32:55.591468 UTC for demo (10.194583 seconds).
Both exit 0 with empty stderr and frozen production/package inputs. Native demo test compilation
passes 02:35:01.359454 to 02:35:13.037846 UTC (11.678441 seconds), threaded RTS. All 167 actual
native demo cases pass 02:36:26.823238 to 02:36:31.953814 UTC (5.130579 wall, 5.10 reported
seconds), parent 0 with frozen inputs; expected negative-fixture teardown diagnostics are retained.

Core test compilation is not yet a passing gate. Linux runs 02:32:45.473940 to 02:34:52.251865 UTC
(126.778463 seconds, parent 1); native runs 02:35:01.349542 to 02:36:30.712624 UTC
(89.363475 seconds, parent 1). Both identify the new source guard's use of an Either token result
as a list; native also rejects the POSIX-only numeric alias adapter's unconditional import.
The guard now unwraps the parser result through expectRight, so a parsing refusal fails the case,
and the alias import follows its existing POSIX-only fixture body. Production and warning policy
are unchanged. Fresh core compilation and all kernel/focused/final commands remain due.

The next compiler runs expose the selector guard's partial head call under the required warning
policy: native 02:37:51.931741 to 02:37:55.735188 UTC (3.803459 seconds) and Linux
02:37:51.953163 to 02:37:55.661673 UTC (3.708507 seconds), both parent 1 with frozen inputs.
The guard now pattern-matches a nonempty token before testing its first character; no warning flag
is changed. The parser result and conditional import compile. Fresh compiler/runtime gates remain due.

Core test compilation passes on native Windows at 02:39:03.029992 to 02:39:10.988574 UTC
(7.958614 seconds, empty stderr, threaded RTS) and on Linux at 02:39:03.050507 to
02:39:09.898274 UTC (6.847780 seconds, empty stderr). Both keep their source snapshots unchanged.

The native Windows selection runs all 36 checks at 02:39:39.736713 to 02:39:40.531115 UTC
(0.794388 wall, 0.72 reported seconds): all 24 real-kernel cases and the other pure/manifest checks
pass except the row-name source guard. Its candidate set also contains the imported generic
withOwnershipRow eliminator. The guard now distinguishes that existing eliminator from row-value
identifiers, keeps exactly the two platform rows and their selector, and retains the no-elif check.
No kernel implementation changes. The complete selection and final gates remain due.

The final core test builds pass natively at 02:42:53.274883 to 02:43:01.707655 UTC
(8.432806 seconds, empty stderr, threaded RTS), and on Linux at 02:42:53.302998 to
02:43:00.129529 UTC (6.826544 seconds, empty stderr). All 36 Windows-row/manifest checks pass
at 02:43:17.208622 to 02:43:17.970390 UTC (0.761755 wall, 0.68 reported seconds), exercising
all 24 real Windows kernel cases with no skips, plus the declaration, encoding, source and manifest
checks. Junctions are real OS-created reparse points; the ACL case proves content reads actually fail
while the same identity remains observable. The parent case reaches real flushes after create and
remove. Both in-process contention and the bracketed, terminated/reaped child prove kernel exclusion.

The complete 342-check ownership-consumer selection passes natively at 02:43:48.944567 to
02:44:03.863951 UTC (14.919436 wall, 14.80 reported seconds), and on Linux at
02:43:48.734658 to 02:44:01.036663 UTC (12.302040 wall, 11.89 reported seconds). It includes
both rows, Object and seam cases, every numeric fixture adopter, shipped/alias transaction cases,
the host-wall driver and both host backends, data/config owners, all four ownership compiler
boundaries, Doc and Portability. Both have empty stderr and frozen snapshots. The direct-Colima
live lane is Unsupported/not requested, not a simulated provider run.

The Linux root selection states its two mode-bit prerequisite exceptions. A separate uid 65534
selection passes all 30 POSIX-row/manifest checks at 02:47:50.188519 to 02:47:50.632512 UTC
(0.443975 wall, 0.11 reported seconds), with empty stderr, frozen inputs and no SKIP output,
so both actual permission denials, FIFO, cross-mount and process-death paths are exercised.

The exact numeric-fixture adoption reversal passes at 02:47:50.967276 UTC, including the
POSIX-only alias import. The full preservation audit passes at 02:48:38.004491 UTC: all
967 other Haskell files, all 980 paths, all 686 compiler fixtures, every other prior 1,106-file
subject, all other sprints, prior handoff goldens, SourceGuard/inventory, Cabal/projects, Python/
phase 1 and base/warm inputs remain exact. The unchanged host-wall source retains the full decoder
width and the eight-byte volume prefix. LF and scoped git diff --check pass. Final source reversals
measure 197/203 production lines in three modules and 459/476 test lines. The canonical docs now
state the exercised native behavior; no mutable suite count is copied into orientation prose.
The final four-command gate remains due.

The first final four-command run has passing code checks and both Cabal legs:

- core: 2026-11-03T02:50:26.177793+00:00 to 2026-11-03T02:55:37.798377+00:00, 311.621940 wall seconds; 4079 pass/280.08 reported seconds; parent 0, frozen inputs.
- demo: 2026-11-03T02:50:26.177128+00:00 to 2026-11-03T02:57:05.796790+00:00, 399.621402 wall seconds; 167 pass/1.33 reported seconds, 4079 pass/273.53 reported seconds; parent 0, frozen inputs.

The Python suite runs 02:50:26.177659 to 02:50:33.173887 UTC (6.996243 wall seconds), parent 1:
375 pass and test_haskell_host_processes_do_not_launch_bare_literal_commands identifies the new
fixture's bare PowerShell and icacls targets. The fixtures now resolve those actual executables,
make the paths absolute and validate them through AbsExe before launch. Paths remain data in the
constant junction command's environment; the Python policy and production are unchanged. No gate
completion is claimed for that failed command. Native fixture, packaging/portability and final
four-command reruns remain due.

The absolute-path fixture correction compiles natively at 02:59:16.258130 to
02:59:24.529246 UTC (8.271149 seconds, empty stderr, threaded RTS), and on Linux at
02:59:16.277523 to 02:59:49.938619 UTC (33.661227 seconds, package-index age advisory only).
The native Windows/Doc/Portability regression passes all 78 checks at 03:00:05.717887 to
03:00:17.603612 UTC (11.885759 wall, 11.80 reported seconds), empty stderr and frozen inputs.
All native junction, ACL, process-death, byte-width and flush cases pass using discovered,
absolute, AbsExe-validated executable paths; no capability or warning check is bypassed.

The complete Python suite passes all 376 tests at 02:59:16.277338 to 02:59:23.008841 UTC
(6.731514 wall seconds), parent 0, empty stderr, 100% coverage over 1,585 statements and
460 branches with zero missed/partial. The unchanged bare-process policy passes. The repeated
preservation audit passes at 03:02:38.241101 UTC, including all 967 unrelated Haskell files,
all 686 fixtures, all other sprints and prior subjects. Final complete baseline reversals
measure 197/203 production lines in three modules, 472/491 test lines and 48/49 governed docs
lines. Production is unchanged by the fixture-path correction. A fresh all-four command
run on this final snapshot remains due.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T03:03:36.971993+00:00 to 2026-11-03T03:08:52.570288+00:00 | 315.599666 | 4079 cases pass, 285.41 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T03:03:36.972210+00:00 to 2026-11-03T03:08:29.423215+00:00 | 292.452274 | 167 cases pass, 1.60 reported seconds; 4079 cases pass, 284.55 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T03:03:36.972320+00:00 to 2026-11-03T03:03:37.695293+00:00 | 0.722961 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T03:03:36.972466+00:00 to 2026-11-03T03:03:43.749442+00:00 | 6.776991 | 376 pass, 5.82 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,106-file matched Windows/Linux snapshot. Dated aggregate digests:

- all980: 72e438e145864df554986c453e7d74d88c0c206256a4a07bb506ef8fad893a09
- owned955: f8b3d6b7770898feb94733553a32eccad720b4870f0a5c82cf21f8be237d74b7
- docs95: 425d2f3d4a7ea7979d1b2db9a15df92f1b63470b9cc817a642aed66c874a16fe

All 24 native Windows kernel cases, complete row/manifest/source checks, both 342-check owner
selections and the unprivileged 30-check POSIX selection pass. Native fixture/Doc/Portability
regression passes 78 checks using actual, AbsExe-validated host executables. The eight-byte
POSIX and sixteen-byte Windows object identifiers use one volume-first encoder. No old numeric
fixture value or independent known answer is rebased. Source reversals measure 197/203 production
lines in three modules, 472/491 tests and 48/49 docs; all 967 other Haskell files, all 686 compiler
fixtures, every other prior subject and all other sprints remain exact. Host-wall decoder/volume
logic is unchanged and compatible. No new type, module, package edge or base/warm input is added.
Phase 1 evidence and prior phase closures remain current. Provider-live and direct-Colima live are
Unsupported/not requested; this is no live-provider or crash-durability claim. The phase's own
gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T03:10:56.539368+00:00 to 2026-11-03T03:11:02.566794+00:00,
6.027435 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.11: Re-entering an object this project already owns [Done]

**Status**: Done
**Production budget**: at most 400 changed nonempty lines in three modules; one existing re-entry contract clarification
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

Dated 2026-11-03 baseline 03:12:12.404944 UTC captures 93 texts, 980 Haskell paths and 686
compiler fixtures. Sprint 14.10 is Done on all four final commands and closed-status Doc validation.
This sprint clarifies the existing re-entry precondition in its Haddock and the seam page: every
bound OriginRecord kind, including ReportedObject and values assembled in memory, is admitted;
reading that record from the owner's protected store is the caller's obligation. The source
cannot authenticate provenance. Unbound refusal, declaration gating and fresh object/session
indices remain the implementation's guarantees. No executable code, signature, type, fixture,
test, module, package or base/warm input change is planned. Existing re-entry and public escape
cases plus all four host-static commands hold the bounded change.

The source edit measures 13 changed nonempty/physical production comment lines in one module;
the seam page is 3/4 lines. The full-module reversal restores exactly the prior Primitive bytes,
so every executable body, signature and export remains exact. All 979 other Haskell files, all
686 compiler fixtures, every other prior 1,106-file subject and all other sprints remain exact.
Tests, packages, Python/phase 1, base and warm inputs are unchanged. LF and scoped git diff --check
pass. No new test is needed for the reversible prose correction; existing re-entry and compiler
boundaries plus all four actual commands remain the completion gate.

Dated 2026-11-03 actual compiler/runtime results, with frozen inputs throughout each command:

| Command or selection | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core Main | 2026-11-03T03:18:23.427755+00:00 to 2026-11-03T03:18:31.628822+00:00 | 8.201101 | parent 0; empty stderr |
| Native demo Main | 2026-11-03T03:18:23.428505+00:00 to 2026-11-03T03:18:31.093788+00:00 | 7.665320 | parent 0; empty stderr |
| Native core test compilation | 2026-11-03T03:18:49.845022+00:00 to 2026-11-03T03:18:55.606964+00:00 | 5.761962 | parent 0; empty stderr |
| Native demo test compilation | 2026-11-03T03:18:49.867503+00:00 to 2026-11-03T03:18:51.926041+00:00 | 2.058545 | parent 0; empty stderr |
| Linux cabal build all --enable-tests | 2026-11-03T03:18:23.486057+00:00 to 2026-11-03T03:18:54.253899+00:00 | 30.767958 | parent 0; existing package-index age advisory only |
| Native re-entry/escape/Doc/Portability selection | 2026-11-03T03:20:17.761919+00:00 to 2026-11-03T03:20:29.669313+00:00 | 11.907425 | parent 0; 77 checks pass, 11.77 reported seconds; empty stderr |
| Linux re-entry/escape/Doc/Portability selection | 2026-11-03T03:20:17.568384+00:00 to 2026-11-03T03:20:27.832714+00:00 | 10.264363 | parent 0; 77 checks pass, 9.83 reported seconds; empty stderr |
| Native complete demo suite | 2026-11-03T03:20:17.653607+00:00 to 2026-11-03T03:20:22.763657+00:00 | 5.110060 | parent 0; 167 checks pass, 5.09 reported seconds; expected negative-fixture diagnostics retained |

Both 77-check selections pass the existing ownership seam, public re-entered escape fixture,
Doc and portability cases. Native demo passes all 167 checks. Every command held its frozen inputs.
The source reversal confirms all executable re-entry code, signatures and exports remain exact;
this sprint changes 13 production comment lines and 3/4 seam-page lines, with no test change.
The actual final four-command results follow.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T03:25:16.993802+00:00 to 2026-11-03T03:30:39.392169+00:00 | 322.400025 | 4079 cases pass, 290.76 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T03:25:16.994083+00:00 to 2026-11-03T03:30:18.625669+00:00 | 301.633139 | 167 cases pass, 1.58 reported seconds; 4079 cases pass, 291.44 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T03:25:16.996333+00:00 to 2026-11-03T03:25:17.756666+00:00 | 0.760321 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T03:25:16.993985+00:00 to 2026-11-03T03:25:23.585609+00:00 | 6.591642 | 376 pass, 5.61 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,106-file matched Windows/Linux snapshot. Dated aggregate digests:

- all980: 81216767680a8737ce5d6119cac7c00e98da8f4b389ebb5ea977ce345f14b6ae
- owned955: 1d0393e8eff767256a001a90eea92d68082c7d3e1dad40f4baa0171336e19912
- docs95: 107402e8cc09d074b8ae7156e2b74b1b29ee7e1af12d5f442e9fa11b77966bd5

Both 77-check re-entry/escape/Doc/Portability selections and the native 167-check demo suite
pass. The 13 production comment lines and 3/4 seam-page lines state the caller's provenance
obligation without changing executable bodies, signatures, exports, tests or compiler fixtures.
All 979 other Haskell files, all 686 compiler fixtures and other baseline subjects remain exact.
No new type, module, package edge or base/warm input is added. Phase 1 evidence and prior phase
closures remain current. The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T03:30:42.709514+00:00 to 2026-11-03T03:30:48.731350+00:00,
6.021851 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.12: The data root consumes the seam [Done]

**Status**: Done
**Production budget**: at most 400 changed nonempty lines in three modules; one data-root caller adoption
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

Dated 2026-11-03 baseline 03:31:03.244534 UTC captures 96 texts, 980 Haskell paths and 686
compiler fixtures after Sprint 14.11 closed on all four static commands and closed-status Doc checks.
This sprint changes the existing data-root caller's recovery and release policy, with no new named
contract, type, module or package edge. Unbound recovery enters through the selected row and removes
only an empty directory non-recursively, then syncs its parent before forgetting. Bound recovery settles
authoritative absence. Lost exclusive creation forgets its unbound record before returning the refusal.
Content clearing re-observes the bound identity immediately before listing, with its remaining pathname
race stated explicitly. The harness already uses the one row selector; its executable code stays exact.
All 18 previous cases remain, with the specified empty-window correction and honest no-record name.
Six new actual-kernel ordering/recovery/adversary cases and retained-record assertions hold this adoption.
The invariant page records current behavior and leaves generated-config gaps to Sprint 14.13.
Actual source measurements, compilation, focused cases and all four static commands remain due.

The applied source delta measures 170 changed nonempty/physical production lines in DataRoot.hs
alone, 122/123 test lines and 26/26 invariant-page lines. All 24 DataRootSpec cases are present
(the retained 18 plus six additions). The test row wrappers call the real kernel primitives: ordering
reads the actual protected record before directory creation, the create race installs actual competing
content, and the late replacement renames the original live directory before installing its replacement.
No counter, fake executable, fabricated identity, production test branch or conditional case is added.
Actual compilation, focused behavioral cases and all four final static commands remain due.

Dated 2026-11-03 actual compiler/runtime results, with frozen inputs throughout each command:

| Command or selection | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core Main | 2026-11-03T03:32:17.350292+00:00 to 2026-11-03T03:32:23.498901+00:00 | 6.148638 | parent 0; empty stderr |
| Native demo Main | 2026-11-03T03:32:17.350540+00:00 to 2026-11-03T03:32:24.601169+00:00 | 7.250669 | parent 0; empty stderr |
| Native core test compilation | 2026-11-03T03:32:34.036471+00:00 to 2026-11-03T03:32:42.206378+00:00 | 8.169945 | parent 0; empty stderr |
| Native demo test compilation | 2026-11-03T03:32:34.055710+00:00 to 2026-11-03T03:32:38.217872+00:00 | 4.162180 | parent 0; empty stderr |
| Linux cabal build all --enable-tests | 2026-11-03T03:32:17.412206+00:00 to 2026-11-03T03:32:56.707643+00:00 | 39.295625 | parent 0; existing package-index age advisory only |
| Native data-root/harness/Doc/Portability selection | 2026-11-03T03:32:58.833913+00:00 to 2026-11-03T03:33:19.936449+00:00 | 21.102627 | parent 0; 113 checks pass, 20.97 reported seconds; empty stderr |
| Linux data-root/harness/Doc/Portability selection | 2026-11-03T03:32:58.632044+00:00 to 2026-11-03T03:33:13.778297+00:00 | 15.146312 | parent 0; 113 checks pass, 14.75 reported seconds; empty stderr |
| Native complete demo suite | 2026-11-03T03:32:58.767447+00:00 to 2026-11-03T03:33:03.907606+00:00 | 5.140168 | parent 0; 167 checks pass, 5.12 reported seconds; expected negative-fixture diagnostics retained |

Both 113-check selections pass all data-root, harness, documentation and portability cases.
Native demo passes all 167 checks. Every command held its frozen inputs. Preservation confirms
all 18 prior data-root cases remain with the specified fixture/name corrections, six real-kernel
cases are added, and all 978 other Haskell files, 686 compiler fixtures and other prior subjects
remain exact. Source deltas are 170/170 production lines in one module, 122/123 tests and
26/26 invariant-page lines. The existing harness selector, all other sprints, package metadata,
Python/phase 1, base and warm inputs are unchanged. LF and scoped git diff --check pass.
No sprint-owned legacy-ledger row applies; the store-adapter duplication remains owned by Sprint 14.23.
The actual final four-command results follow.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T03:34:07.810368+00:00 to 2026-11-03T03:39:29.522366+00:00 | 321.713653 | 4085 cases pass, 290.04 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T03:34:07.810144+00:00 to 2026-11-03T03:39:09.270768+00:00 | 301.462172 | 167 cases pass, 1.40 reported seconds; 4085 cases pass, 290.20 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T03:34:07.810270+00:00 to 2026-11-03T03:34:08.568196+00:00 | 0.757913 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T03:34:07.813166+00:00 to 2026-11-03T03:34:14.585315+00:00 | 6.772165 | 376 pass, 5.71 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,106-file matched Windows/Linux snapshot. Dated aggregate digests:

- all980: de2ae0546cb375272653e6339ec9f6cde6f5fb901b3bda5b50538fdf555ecbd6
- owned955: 8eca202f7456763ca65253e84b86d3b92484aeaabbbed41ae7d50a8e1cf49cfc
- docs95: 335325e26d4afca2d6599a338adfadfc681133433dc4e4846512656a62a991d8

Both 113-check data-root/harness/Doc/Portability selections and the native 167-check demo suite
pass. All 24 data-root cases hold the retained 18 and six added actual-kernel behaviors. Unbound
recovery removes only an empty directory, both absent-record windows settle, lost exclusive
creation forgets its record, and release rechecks identity before listing content. Refused release
and unsettled reacquisition keep exact record bytes. The residual pathname race is stated.
Source reversals measure 170/170 production lines in one module, 122/123 tests and 26/26 docs.
All 978 other Haskell files, all 686 compiler fixtures and other baseline subjects remain exact.
No new type, module, package edge or base/warm input is added. The harness selector is unchanged;
store-adapter duplication remains owned by Sprint 14.23. Phase 1 evidence and prior phase closures
remain current. The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T03:39:35.118021+00:00 to 2026-11-03T03:39:41.032463+00:00,
5.914453 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.13: The generated config consumes the seam [Done]

**Status**: Done
**Production budget**: at most 400 changed nonempty lines in three modules; one generated-config caller adoption
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

Dated 2026-11-03 baseline 03:39:51.878882 UTC captures 99 texts, 980 Haskell paths and 686
compiler fixtures after Sprint 14.12 closed on all four static commands and closed-status Doc validation.
This sprint adopts recovery settlement in the existing generated-config caller; no new named contract,
type, module or package edge is introduced. The existing private RecoveryOutcome distinguishes a removed
unbound target that still owes record settlement from a bound release that already settled. Bound
authoritative absence settles, and successful recovery withdraws the key-derived staging name before
forgetting. Unbound payload recovery retains the entry's observed identity and checks it after reading
bytes immediately before unlinking, with the residual pathname window documented. All previous 23 cases
remain; three actual-kernel recovery cases, exact record-retention assertions, a populated cross-record
key and canonical bound-record bytes hold this adoption. The harness's existing row selector stays exact.
Actual source measurement, compilation, focused behavior and all four static commands remain due.

The applied delta measures 122 nonempty/125 physical production lines in GeneratedConfig.hs alone,
115/117 test lines and 21/21 documentation lines. All 26 cases are present. Record readbacks now pin
both successful crash-window settlements and every listed refusal, including both populated keys in
the cross-record test. The exact canonical bound file record replaces the old substring assertion.
The same-bytes adversary calls the real row reader, retains the original live file at a sibling name,
then creates a distinct same-payload file before recovery's final observation. Bound-absent and
unpublished-target cases also leave actual staging files, proving cleanup on both settlement branches.
No counter, fake executable, fabricated identity, production test branch or conditional case is added.
Actual compilation, focused behavior and all four final commands remain due.

Initial 2026-11-03 native core/demo Main builds (03:41:02.824479 to 03:41:05.186581 UTC)
and Linux build (03:41:02.887902 to 03:41:26.267014 UTC) refused the new outer observed
binding under -Wname-shadowing/-Werror. All inputs stayed frozen. The outer observation is now
named prior; no warning policy or case is weakened. Fresh compilation and runtime results remain due.

Dated 2026-11-03 actual compiler/runtime results, with frozen inputs throughout each command:

| Command or selection | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core Main | 2026-11-03T03:41:54.987222+00:00 to 2026-11-03T03:42:02.839184+00:00 | 7.852002 | parent 0; empty stderr |
| Native demo Main | 2026-11-03T03:41:54.987785+00:00 to 2026-11-03T03:42:04.119890+00:00 | 9.132155 | parent 0; empty stderr |
| Native core test compilation | 2026-11-03T03:42:07.908669+00:00 to 2026-11-03T03:42:33.083016+00:00 | 25.174474 | parent 0; empty stderr |
| Native demo test compilation | 2026-11-03T03:42:07.921106+00:00 to 2026-11-03T03:42:11.962499+00:00 | 4.041412 | parent 0; empty stderr |
| Linux cabal build all --enable-tests | 2026-11-03T03:41:55.063792+00:00 to 2026-11-03T03:42:33.530461+00:00 | 38.466851 | parent 0; empty stderr |
| Native generated-config/data-root/harness/Doc/Portability selection | 2026-11-03T03:42:45.320377+00:00 to 2026-11-03T03:43:07.824500+00:00 | 22.504215 | parent 0; 139 checks pass, 22.34 reported seconds; empty stderr |
| Linux generated-config/data-root/harness/Doc/Portability selection | 2026-11-03T03:42:45.061955+00:00 to 2026-11-03T03:43:01.237905+00:00 | 16.176015 | parent 0; 139 checks pass, 15.69 reported seconds; empty stderr |
| Native complete demo suite | 2026-11-03T03:42:45.156594+00:00 to 2026-11-03T03:42:50.277399+00:00 | 5.120813 | parent 0; 167 checks pass, 5.10 reported seconds; expected negative-fixture diagnostics retained |

Both 139-check selections pass all generated-config, data-root, harness, documentation and
portability cases. Native demo passes all 167 checks. Every command held its frozen inputs.
All 23 prior generated-config cases remain and three kernel cases are added. Preservation
confirms all 978 other Haskell files, 686 compiler fixtures and other prior subjects remain exact.
Source deltas are 122/125 production lines in one module, 115/117 tests and 21/21 documentation.
The harness selector, other sprints, package metadata, Python/phase 1, base and warm inputs are
unchanged. LF and scoped git diff --check pass. No sprint-owned ledger row applies; store-adapter
duplication remains owned by Sprint 14.23. The actual final four-command results follow.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T03:43:34.179213+00:00 to 2026-11-03T03:49:17.652457+00:00 | 343.475011 | 4088 cases pass, 310.19 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T03:43:34.179493+00:00 to 2026-11-03T03:49:17.257049+00:00 | 343.079324 | 167 cases pass, 1.57 reported seconds; 4088 cases pass, 309.25 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T03:43:34.179367+00:00 to 2026-11-03T03:43:34.963847+00:00 | 0.784468 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T03:43:34.192673+00:00 to 2026-11-03T03:43:40.915913+00:00 | 6.723256 | 376 pass, 5.68 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,106-file matched Windows/Linux snapshot. Dated aggregate digests:

- all980: ea47bbf700ad19745e4aea8a4cb305342f71f8b2ee48370427513d00c273eb36
- owned955: e0121dfd8c372793cd2553f31d2c4da8c705fd04594920cd9b9cfa911faee7fc
- docs95: e45a5cc7c9d68a0d8810a939495c0cb8c6302b7adc14dd92af33625c8057d2e9

Both 139-check generated-config/data-root/harness/Doc/Portability selections and the native
167-check demo suite pass. All 26 config cases retain the prior 23 plus three actual-kernel
recovery cases. Unbound removal settles its record, authoritative absence settles bound records,
and every successful recovery with a record withdraws staging before forgetting. The post-read
identity check refuses a distinct same-payload replacement. Exact readbacks hold every listed
refusal; populated cross-record keys pin the key guard, and canonical record bytes pin digest-only
storage. The residual pathname race is stated. Source reversals measure 122/125 production lines
in one module, 115/117 tests and 21/21 docs. All 978 other Haskell files, 686 compiler fixtures
and other baseline subjects remain exact. No new named type, module, package edge or base/warm
input is added. The harness selector is unchanged; store-adapter duplication remains owned by
Sprint 14.23. Phase 1 evidence and prior phase closures remain current. The phase's own gate
remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T03:49:29.116990+00:00 to 2026-11-03T03:49:34.776830+00:00,
5.659852 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T03:52:14.91497+00:00 to 2026-11-03T03:52:19.862971+00:00,
5.771490 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.14: The current-user wall admits only an absolute Windows profile [Done]

**Status**: Done
**Production budget**: at most 400 changed nonempty lines in three modules; one Windows entry-point adoption
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Windows.hs`,
`core/hostbootstrap-core/test/WslGlobalWallWindowsSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`

#### Objective

Derive the production wall only from a non-empty absolute USERPROFILE under Windows path grammar.

#### Deliverables

- Both production entry points refuse unset, empty and relative USERPROFILE values with HostWallUnsupported
  before opening a target or store. Valid profiles keep the existing row and fixed target/state names.
- Retain every native case on every host. Add three profile refusals for both entry points, asserting
  the unavailable-row refusal elsewhere, and update the complete manifest family.
- Absent-origin publication matches exact merged bytes and a second restore reports HostWallNoActiveRecord.
  Present-origin restoration retains exact bytes and the original kernel identity.
- Same-payload replacement retains the original live object at a sibling name, matches TargetReplaced
  exactly and keeps replacement bytes. The module header names the host's row.

#### Validation

Retain all wall cases. WslGlobalWallWindowsSpec adds unset, empty and relative profile refusals for both
entry points, plus the exact publication/repeated-restore/restored-identity/same-payload assertions above.
Every case stays on non-Windows hosts and asserts the declared refusal. CoverageManifest pins the actual
complete family. Run native wall coverage and all four host-static commands before closure.

Dated 2026-11-03 baseline 03:52:56.787541 UTC captures 101 texts, 980 Haskell paths and 686
compiler fixtures. Sprint 14.13 is Done on all four static commands; the wall split passes all
17 closed-status Doc checks. This adoption changes only Windows.hs production code, using the Windows
path grammar before any opening. It retains all four native-family cases and adds three profile refusals
for both public entry points. Native assertions compare exact merged bytes, original/restored kernel
identity and the exact same-payload replacement conflict, retaining the original live object at a sibling
name. CoverageManifest records seven cases and six native/refusal branches on every host.
The WSL page records admitted profiles while retaining the public raw-location gap for Sprint 14.16.
Actual source measurement, compilation, native/Linux cases and all four static commands remain due.

The applied delta measures 25 nonempty/physical production lines in Windows.hs alone,
50/52 test lines across the native spec and its family manifest, and 23/23 WSL-page lines.
The existing admitted-profile opening branch is preserved under the guard. All four prior family
cases remain, with three profile-refusal cases added. Exact merge output and restored kernel
identity replace the weaker assertions; same-payload replacement retains the original through
the actual row's hard link, so the two live identities cannot be a recycled inode.
Actual compilation, native/Linux wall and provider-order coverage, and all four static commands remain due.

Dated 2026-11-03 actual compiler/runtime results, with frozen inputs throughout each command:

| Command or selection | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core Main | 2026-11-03T03:55:36.646219+00:00 to 2026-11-03T03:55:41.659740+00:00 | 5.013545 | parent 0; empty stderr |
| Native demo Main | 2026-11-03T03:55:36.646706+00:00 to 2026-11-03T03:55:49.159630+00:00 | 12.512991 | parent 0; empty stderr |
| Native core test compilation | 2026-11-03T03:56:00.289274+00:00 to 2026-11-03T03:56:08.005629+00:00 | 7.716393 | parent 0; empty stderr |
| Native demo test compilation | 2026-11-03T03:56:30.454881+00:00 to 2026-11-03T03:56:40.237033+00:00 | 9.782200 | parent 0; empty stderr |
| Linux cabal build all --enable-tests | 2026-11-03T03:55:36.703401+00:00 to 2026-11-03T03:56:10.976120+00:00 | 34.272879 | parent 0; existing package-index age advisory only |
| Native wall/provider/Doc/Portability selection | 2026-11-03T03:56:40.878273+00:00 to 2026-11-03T03:56:53.431094+00:00 | 12.552869 | parent 0; 153 checks pass, 12.46 reported seconds; empty stderr |
| Linux wall/provider/Doc/Portability selection | 2026-11-03T03:56:40.637886+00:00 to 2026-11-03T03:56:51.070231+00:00 | 10.432379 | parent 0; 153 checks pass, 10.07 reported seconds; empty stderr |
| Native complete demo suite | 2026-11-03T03:57:38.547882+00:00 to 2026-11-03T03:57:43.663173+00:00 | 5.115299 | parent 0; 167 checks pass, 5.09 reported seconds; expected negative-fixture diagnostics retained |

Both 153-check selections pass the complete wall families, provider ordering, Doc and portability
cases. Windows exercises all six native entry-point branches; Linux asserts all six declared row
refusals, with the seven-case family and its declaration case retained on both hosts. Native demo
passes all 167 checks. Every command held its frozen inputs. Preservation confirms the admitted
profile's opening branch is exact after dedent, all four prior family cases remain with three new
profile refusals, and all 977 other Haskell files, 686 compiler fixtures and other prior subjects
remain exact. Source deltas are 25/25 production lines in one module, 50/52 tests and 23/23 docs.
All other wall code, other sprints, package metadata and Python/phase 1 inputs are unchanged.
Base/warm inputs are not edited. LF and scoped git diff --check pass. No sprint-owned ledger row
applies. Raw location privacy remains owned by Sprint 14.16. All four static commands remain due.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T03:58:22.337138+00:00 to 2026-11-03T04:03:48.109256+00:00 | 325.773793 | 4091 cases pass, 293.06 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T03:58:22.337675+00:00 to 2026-11-03T04:03:27.015413+00:00 | 304.679306 | 167 cases pass, 1.61 reported seconds; 4091 cases pass, 294.51 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T03:58:22.337793+00:00 to 2026-11-03T03:58:23.147043+00:00 | 0.809239 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T03:58:22.342031+00:00 to 2026-11-03T03:58:29.091573+00:00 | 6.749560 | 376 pass, 5.81 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,106-file matched Windows/Linux snapshot. Dated aggregate digests:

- all980: 08b63876d9c27683b989f0b987ee835e15a5039aec6922d40c3d2125fd7cd020
- owned955: 83c74cdf76afae41bd60f697e575f0f20461b22ba55c2b3ea691e0c65ac6af06
- docs95: 4dc589735f9fca36627dbd1669ad430c3a0704fba3961ae193da1394004915b2

Both 153-check wall/provider/Doc/Portability selections and the native 167-check demo suite pass.
All seven native-family cases stay on both hosts: Windows exercises six entry-point branches,
and Linux asserts the six unavailable-row refusals. Unset, empty and relative profiles refuse
both production entries before opening. Exact merged publication, restored original kernel
identity, a second restore with no active record and a same-payload distinct live replacement
are pinned. Source reversals measure 25/25 production lines in one module, 50/52 tests and
23/23 docs. The admitted-profile opening branch is exact after dedent. All 977 other Haskell
files, all 686 compiler fixtures, other wall code and other baseline subjects remain exact.
No new type, module or package edge is added; base/warm inputs are not edited. Phase 1 evidence
and prior phase closures remain current. Raw location privacy remains owned by Sprint 14.16.
The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T04:03:52.899853+00:00 to 2026-11-03T04:03:58.703171+00:00,
5.803331 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.15: Demo teardown observes wall presence without raw location access [Done]

**Status**: Done
**Production budget**: at most 400 changed nonempty lines in three modules; one read-only observation contract with its demo adoption
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Host.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/test/WslGlobalWallHostSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`,
`documents/architecture/ownership_seam.md`

#### Objective

Let teardown observe whether the wall's canonical active record remains without disclosing a location,
store or record key through that observation.

#### Deliverables

- A read-only hostWallOwnershipPresent projection reads the one canonical active key inside the caller's
  live ProtectedSession, returning only presence or the actual protected-store fault.
- Demo teardown opens its known existing protected store and uses that projection under its existing
  nonblocking entry. Retained ownership, held entry and failed store opening still refuse teardown.
- Demo fixtures use real generic protected-store opening and an independent canonical-key fixture,
  retaining all existing teardown cases and record values; production no longer imports the three raw helpers.
- Real-store core cases prove absent/present observation and exact record retention. The reviewed
  export inventory pins the one added read-only function. No mutation or receipt authority is returned.

#### Validation

Retain all prior core wall and demo teardown cases. New core cases read absence and a retained active
record through hostWallOwnershipPresent, asserting the stored version/bytes are unchanged. Demo's
existing held-entry, retained-record, released-record, never-used-store and invalid-store cases drive
the actual generic store and unchanged nonblocking teardown path. A source guard holds the demo's raw
helper imports absent. Run native/Linux selections and all four host-static commands before closure.

Dated 2026-11-03 observer baseline 04:14:27.363448 UTC captures 101 texts, 980 Haskell
paths and 686 compiler fixtures after the prepared private extraction was archived and withdrawn.
The two checkouts match that restored source tree; the later boundary sprint records the failed
demo-import preparation honestly. This sprint adds one read-only observation contract in Host.hs
and its one demo production adoption in Commands.hs. The live session reads the existing canonical
key and returns only presence; malformed retained bytes still count as owned. Demo's nonblocking
entry, teardown refusals, diagnostic text and all existing record fixture values remain.
Three real-source/store cases and the existing demo teardown cases hold the adoption. No module,
type, package edge, compiler fixture or base/warm input is added. Actual measurements and validation
remain due; raw location closure remains owned by Sprint 14.16.

The applied observer adoption measures 37 nonempty/38 physical production lines in two modules,
67/69 test lines across three specs/inventories and 10/11 documentation lines. Core wall coverage
adds three real-store/source cases. Demo retains all 167 cases and all prior teardown fixture values;
its fixtures now open the generic protected store with the independent canonical-key fixture.
Only presence crosses the public projection. All other wall computations, raw API exports pending
Sprint 14.16, package metadata, fixtures, Python and base/warm inputs are unchanged.
Actual compilation, focused selections and all four final static commands remain due.

Dated 2026-11-03 actual compiler/runtime results, with frozen inputs throughout each command:

| Command or selection | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core Main | 2026-11-03T04:18:49.455689+00:00 to 2026-11-03T04:19:23.248699+00:00 | 33.793183 | parent 0; existing package-index age advisory only |
| Native demo Main | 2026-11-03T04:18:49.456593+00:00 to 2026-11-03T04:19:15.203024+00:00 | 25.746567 | parent 0; existing package-index age advisory only |
| Native core test compilation | 2026-11-03T04:19:51.377412+00:00 to 2026-11-03T04:20:22.500898+00:00 | 31.123653 | parent 0; empty stderr |
| Native demo test compilation | 2026-11-03T04:19:51.382710+00:00 to 2026-11-03T04:20:09.250844+00:00 | 17.868228 | parent 0; empty stderr |
| Linux cabal build all --enable-tests | 2026-11-03T04:18:49.520797+00:00 to 2026-11-03T04:19:52.974974+00:00 | 63.454488 | parent 0; existing package-index age advisory only |
| Native wall/provider/export-inventory/Doc/Portability selection | 2026-11-03T04:20:49.594652+00:00 to 2026-11-03T04:21:02.937165+00:00 | 13.342569 | parent 0; 183 checks pass, 13.20 reported seconds; empty stderr |
| Linux wall/provider/export-inventory/Doc/Portability selection | 2026-11-03T04:20:22.074553+00:00 to 2026-11-03T04:20:32.074054+00:00 | 9.999537 | parent 0; 183 checks pass, 9.64 reported seconds; empty stderr |
| Native complete demo suite | 2026-11-03T04:20:49.444269+00:00 to 2026-11-03T04:20:54.564858+00:00 | 5.120599 | parent 0; 167 checks pass, 5.09 reported seconds; expected negative-fixture diagnostics retained |

Both 183-check selections pass complete wall families, provider ordering, sealed export surfaces,
Doc and portability cases. The three new source/store cases hold absent/present readback and
unchanged record version/bytes, no mutation calls in the projection and no demo raw-helper imports.
Native demo passes all 167 retained cases, including never-used stores, retained/released wall
records, held nonblocking entries and failed store opens. Every command held its frozen inputs.
Preservation reverses the projection and its export to restore the complete Host.hs baseline.
All 975 other Haskell files, 686 compiler fixtures, prior demo/wall cases and other subjects remain
exact. Deltas are 37/38 production lines in two modules, 67/69 tests and 10/11 docs. Other sprints,
packages and Python/phase 1 are unchanged; base/warm inputs are not edited. The prepared private
module/fixture remain absent, and their closure is Sprint 14.16. LF and scoped git diff --check
pass. No sprint-owned ledger row applies. The actual final four-command results follow.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T04:21:57.246914+00:00 to 2026-11-03T04:27:37.076193+00:00 | 339.831163 | 4094 cases pass, 306.57 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T04:21:57.246978+00:00 to 2026-11-03T04:27:38.679851+00:00 | 341.434770 | 167 cases pass, 1.54 reported seconds; 4094 cases pass, 307.31 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T04:21:57.246851+00:00 to 2026-11-03T04:21:58.016663+00:00 | 0.769797 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T04:21:57.248256+00:00 to 2026-11-03T04:22:03.971301+00:00 | 6.723067 | 376 pass, 5.73 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,106-file matched Windows/Linux snapshot. Dated aggregate digests:

- all980: 375b27d5167926db4c7afe2a3e2af32a0946c97c0350a8fd4276a569bcb617ae
- owned955: ca73419ea00e083351e009f33f21bc308b1dfa62fec07a0e0517b060f979cc63
- docs95: f6052906c81e57ee3bc3aed8455e25b67a6346beefc761515577a0ac5e1fcada

Both 183-check wall/provider/export-inventory/Doc/Portability selections and all 167 native demo
cases pass. The three new source/store cases hold absent/present observation, exact retained
record version/bytes, read-only source shape and absent demo raw-helper imports. Existing demo
teardown cases still prove never-used stores, retained/released ownership, held nonblocking
entries and failed store opens. The projection returns only presence or the store fault and
uses the one existing canonical key. Source reversals measure 37/38 production lines in two
modules, 67/69 tests and 10/11 docs. Removing only the projection/export restores Host.hs exactly.
All 975 other Haskell files, 686 compiler fixtures and other baseline subjects remain exact.
No new type, module, package edge or fixture is added; base/warm inputs are not edited. Phase 1
evidence and prior phase closures remain current. Raw API closure remains owned by Sprint 14.16,
with the initial preparation and demo-import refusal recorded there. The phase's own gate remains
due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T04:28:04.666883+00:00 to 2026-11-03T04:28:10.555562+00:00,
5.888695 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.16: The host-wall location boundary is private [Done]

**Status**: Done
**Production budget**: at most 400 changed nonempty lines in three modules; one existing location contract boundary
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Host.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Windows.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Wsl2/GlobalWall/Location.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/WslGlobalWallHostSpec.hs`,
`core/hostbootstrap-core/test/WslGlobalWallWindowsSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`,
`documents/architecture/ownership_seam.md`,
`DEVELOPMENT_PLAN/system-components.md`

#### Objective

Keep raw target/store construction and active-record access inside the package interpreter boundary.

#### Deliverables

- Move the existing HostWallLocation representation and raw opener/store/key access to a private module
  shared by the driver, Windows entry points and tests. Public Host exports no openHostWallLocation,
  hostWallProtectedStore or hostWallActiveRecordKey.
- Keep one representation and all existing driver computations. Only the Windows production entry
  derives paths from the admitted profile; receipts and reporting stay opaque.
- Correct the location Haddock and sealed export inventory. Hold public absence with a named
  compile-fail fixture and source boundary check.
- A state path that is a regular file surfaces as HostWallJournalFailure. Crash fixtures use private
  real-store access; production has no injected crash branch.

#### Validation

Retain every wall case. Exercise the location opener against a real regular-file state path and assert
HostWallJournalFailure. Compile the public raw-opener/store/key import fixture for its exact diagnostic.
The public export inventory and source guard prevent re-exposure. Run native/Linux wall selections and
all four host-static commands before closure.

An initial 2026-11-03 extraction preparation passed native core Main at 04:07:54.430167 to
04:08:28.845332 UTC and Linux build-all with tests at 04:07:54.505075 to 04:09:00.510229 UTC.
Native demo Main refused all three removed imports at 04:07:54.428432 to 04:08:14.32828 UTC:
its teardown inspector and fixtures were additional raw-helper consumers. That prepared extraction is
archived outside the repository and its source changes withdrawn. Sprint 14.15 first adds a read-only
presence projection and adopts it in the demo; this sprint then closes the raw boundary while preserving
that projection. No completion is claimed for the preparation. All boundary validation remains due.

Dated 2026-11-03 baseline 04:28:40.256982 UTC captures 101 texts, 980 Haskell paths and 686
compiler fixtures after Sprint 14.15 closes on all four commands and closed-status Doc checks.
The demo now uses only the read-only presence projection and generic store fixtures, so its production
and all 167 test cases stay byte-exact during this boundary change. The location fields, fixed keys,
opener and existing read-only projection move to one private Location.hs representation. Host retains
the opaque location, target reporting and read-only function, removing exactly the three raw exports.
The private opener accepts HostWallJournalFailure at its two package callers without depending on the
public error type. All driver bodies remain exact. Two source/kernel checks, the updated public export
pin and one three-diagnostic public import fixture hold closure. The existing projection source guard
follows its actual private definition. No new type or package dependency is introduced.
The physical component row and both canonical pages name the private home. Actual source measurement,
compilation, runtime selections and all four final static commands remain due.

The applied boundary delta measures 166 nonempty/192 physical production lines across exactly
Host.hs, Windows.hs and the new private Location.hs; tests are 53/55 lines across four files and
docs/component inventory are 20/20 lines. Host retains the read-only presence export, with its exact
definition moved beside the one location/key representation. The source guard follows that actual
private producer and separately pins public raw-helper absence. The driver after its location block
is unchanged. Every demo source/test byte stays exact from the closed adoption baseline.
Cabal adds one private exposed module and no package dependency. Two boundary/kernel cases plus one
public three-diagnostic fixture bring the inventory to 982 Haskell files and 687 compiler fixtures.
Actual compilation, focused/native behavior and all four final commands remain due.

Dated 2026-11-03 actual compiler/runtime results, with frozen inputs throughout each command:

| Command or selection | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core Main | 2026-11-03T04:31:05.093843+00:00 to 2026-11-03T04:31:39.871284+00:00 | 34.777631 | parent 0; existing package-index age advisory only |
| Native demo Main | 2026-11-03T04:31:05.095453+00:00 to 2026-11-03T04:31:31.979571+00:00 | 26.884270 | parent 0; existing package-index age advisory only |
| Native core test compilation | 2026-11-03T04:32:45.787019+00:00 to 2026-11-03T04:33:17.575795+00:00 | 31.788951 | parent 0; empty stderr |
| Native demo test compilation | 2026-11-03T04:32:45.808851+00:00 to 2026-11-03T04:32:56.933663+00:00 | 11.124873 | parent 0; empty stderr |
| Linux cabal build all --enable-tests | 2026-11-03T04:31:05.151828+00:00 to 2026-11-03T04:32:10.484063+00:00 | 65.332583 | parent 0; existing package-index age advisory only |
| Native wall/public-fixture/export-inventory/Doc/Portability selection | 2026-11-03T04:33:48.555251+00:00 to 2026-11-03T04:34:02.828306+00:00 | 14.273116 | parent 0; 210 checks pass, 14.13 reported seconds; empty stderr |
| Linux wall/public-fixture/export-inventory/Doc/Portability selection | 2026-11-03T04:32:45.787216+00:00 to 2026-11-03T04:32:57.841851+00:00 | 12.054687 | parent 0; 210 checks pass, 11.70 reported seconds; empty stderr |
| Native complete demo suite | 2026-11-03T04:33:48.332674+00:00 to 2026-11-03T04:33:53.454426+00:00 | 5.121758 | parent 0; 167 checks pass, 5.10 reported seconds; expected negative-fixture diagnostics retained |

Both 210-check selections pass the complete wall families, the three distinct exact public
not-exported diagnostics, fixture bookkeeping, sealed public surfaces, Doc and portability cases.
The regular-file state path is a journal failure with its bytes intact, public raw exports remain
absent, and the existing read-only projection guard follows its private definition. Native demo
passes all 167 retained cases with no source/test edit in this sprint. Every command held its frozen
inputs. Preservation proves the complete driver body exact, location fields/fixed keys/projection
exact across the move, the complete Windows module exact after import/opener-argument reversal,
and Cabal changed only by one private module line. All 975 other baseline Haskell files, all 686
prior compiler fixtures, other subjects and other sprints remain exact. There are 982 Haskell files,
687 compiler fixtures and 1,108 audited subjects after the new private module/fixture. Deltas are
166/192 production lines in three modules, 53/55 tests and 20/20 docs/component inventory.
Python/phase 1 is unchanged and base/warm inputs are not edited. LF and scoped git diff --check
pass. No sprint-owned ledger row applies. The actual final four-command results follow.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T04:36:19.656080+00:00 to 2026-11-03T04:41:49.694446+00:00 | 330.040195 | 4097 cases pass, 295.87 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T04:36:19.656167+00:00 to 2026-11-03T04:42:00.638184+00:00 | 340.983910 | 167 cases pass, 1.55 reported seconds; 4097 cases pass, 294.70 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T04:36:19.656387+00:00 to 2026-11-03T04:36:20.422715+00:00 | 0.766317 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T04:36:19.656276+00:00 to 2026-11-03T04:36:26.702681+00:00 | 7.046430 | 376 pass, 6.01 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,108-file matched Windows/Linux snapshot. Dated aggregate digests:

- all982: bb42afeae82a9f225f9d3540a0ed5f44e05f4709586b39fee0e5c8acd4687310
- owned957: b5db47c94a578852a220be2209002ab13a44dd9b8bdf9fdb182eb25e2e6f042d
- docs95: 86a0ac56ab78826478e82dc8d23925034672a3db060f4e72143b4e535d1a0815

Both 210-check wall/public-fixture/export-inventory/Doc/Portability selections and all 167 native
demo cases pass. Three distinct complete diagnostics hold the removed public opener/store/key
imports. Real-source/store cases hold private location access, regular-file state refusal and
unchanged read-only presence. The entire demo source/test tree is exact from Sprint 14.15.
The driver body, location fields, fixed keys and presence definition are exact across the move;
Windows reverses exactly after its private import/opener-argument adoption. Cabal adds only one
private module with no dependency edge. Source reversals measure 166/192 production lines in three
modules, 53/55 tests and 20/20 docs/component inventory. All 975 other baseline Haskell files and
686 prior compiler fixtures remain exact; the one new private module and one new fixture give
982 Haskell files, 687 compiler fixtures and 1,108 audited subjects. Python/phase 1 is unchanged,
base/warm inputs are not edited, and prior phase closures remain current. No sprint-owned ledger
row applies. The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T04:45:25.528405+00:00 to 2026-11-03T04:45:31.967502+00:00,
6.439117 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.17: The host-wall driver refusals and recovery are fully checked [Done]

**Status**: Done
**Production budget**: at most 400 changed nonempty lines in three modules; one existing host-wall driver adoption
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Host.hs`,
`core/hostbootstrap-core/test/WslGlobalWallSpec.hs`,
`core/hostbootstrap-core/test/WslGlobalWallHostSpec.hs`,
`core/hostbootstrap-core/test/WslGlobalWallConfigBytesSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`,
`documents/architecture/ownership_seam.md`

#### Objective

Keep the row-backed driver while making its refusals, journal bound and recovery coverage exact.

#### Deliverables

- Only OwnershipOccupied from armed creation becomes UnboundStagePresent; other row faults stay exact.
- Refuse a worst-case record beyond 16 MiB before the first store, including future candidate and identity fields.
- Name every phase/classification constructor and apply the row's pure capability declarations at entry;
  keep the existing row, store/fence and transformer.
- Hold final identity-guard replacement/absence and foreign reservation/receipt/spec refusals with exact conflicts.
- Cover pre-applied/teardown phases, durable armed recovery and retained/stage collisions through real-store rewind values.
- Pin the codec with a golden vector, exact format message, invalid tags/lengths and truncations.
- Pin request/spec refusals, lock-entry ordering, same-payload model refusal and the explicit unavailable-row fallback.
- Cover resume before publication and armed-leftover cleanup, retaining all cases. Sprint 14.25 owns clause-4 deduplication.

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

- `WslGlobalWallHostSpec`: after rewinding to `WallRestoreOutcomeUnknown`, a wrapper that first
  reads the actual payload and then installs a same-bytes distinct live replacement makes the final
  guard return exactly `HostWallConflict (TargetReplaced _ _)` before an absent-origin unlink and,
  in a second case, before a present-origin hard-link retirement; foreign bytes survive. Removing
  the target at that point returns `HostWallConflict (UnexpectedTargetAbsent _)`. The original object
  is retained at a sibling name to exclude inode reuse. The existing swap-before-restore case is
  renamed to say the model refuses it. A swap inside rowRemoveObject or rowLinkNoReplace happens
  after the guard and lies in the acknowledged residual window; it is not claimed to be excluded;
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

Dated 2026-11-03 baseline 04:47:08.126189 UTC captures 103 texts, 982 Haskell paths and 687
compiler fixtures after Sprint 14.16 closes on all four static commands and closed-status Doc checks.
This adoption changes Host.hs only in production: preserve non-occupied create faults, preflight the
future active-record encoding before its first publication, and enumerate all phase/classification
alternatives. The encoded-size bound includes the actual future candidate and the codec's largest
identity without manufacturing a kernel identity. The existing encoder and wire format stay exact.
Validation's race injection is corrected to occur after real payload read and before the final guard:
a swap inside the primitive itself occurs after the guard and cannot prove that guard. The residual
window remains explicit. Existing cases, independent codec bytes, real-store rewind and real-platform
rows hold the change; no production crash point or test branch is added.
Actual source measurements, cases, compilation and all four static results follow.

The real unavailable-row fallback also exposes an entry gap: restore with no record answers
HostWallNoActiveRecord before any primitive can refuse. Both operations now apply the existing pure
ClauseRecord/ClauseBind capability classifier before protected entry, so an unavailable real row returns
its declared Unsupported without a store mutation. The fallback case uses the production POSIX row
on Windows and the production Windows row elsewhere, not a fabricated backend.

The final applied delta measures 175 nonempty/183 physical production lines in Host.hs alone,
509/528 test lines in the host spec/family manifest, and 17/18 canonical documentation lines.
The encoder/wire format is unchanged; the existing decoder identity ceiling is one shared constant
used by future-size planning. The independent 66-byte vector and exact tag/length/truncation reasons
pin that framing. New cases cover final-guard replacement/absence, foreign reservation/receipt,
invalid desired bytes, phase refusals, bound armed recovery, stage/retained collisions, partial-fault
propagation, pre-publication resume and the real near-limit record. The unavailable fallback uses
the actual other platform row. Existing cases gain the ordering, same-payload identity, link reason
and cleanup assertions. Family declarations are 5/5, 4/4, 14/13, 10/10 and 11/2.
The initial 147-line production-only revision compiled natively at 04:53:33.796019 to
04:53:39.015820 UTC (5.219830 seconds, parent 0, empty stderr/frozen input); it predates the later
capability-entry addition and is not the final compiler evidence. All complete compilation/runtime
and four-command results follow.

Initial 2026-11-03 host-wall selections ran all 58 checks: native at 05:21:08.845074 to
05:21:16.112855 UTC (7.267802 seconds), Linux at 05:21:08.657750 to 05:21:14.342777 UTC
(5.685037 seconds). Both returned 1 with the same two failures and frozen inputs. The eight new
codec cases were attached to the read-only group instead of their codec family; their declaration
is now attached to codecCases. The reused-spec desired-byte mismatch reached the existing
HostWallJournalFailure branch; that exact branch now returns fromModelError (InvalidWallJournal ...)
as required. The near-limit, guard, collision and resume cases passed on both hosts. No assertion
or family count was weakened. Fresh complete compilation and selection results follow.

Final 2026-11-03 compiler and runtime results after the corrections above, with inputs frozen throughout each command:

| Command or selection | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core Main | 2026-11-03T05:24:52.586728+00:00 to 2026-11-03T05:24:58.908275+00:00 | 6.321584 | parent 0; empty stderr |
| Native demo Main | 2026-11-03T05:24:52.586949+00:00 to 2026-11-03T05:25:06.285692+00:00 | 13.698826 | parent 0; empty stderr |
| Native core test compilation | 2026-11-03T05:25:21.273477+00:00 to 2026-11-03T05:25:29.968619+00:00 | 8.695191 | parent 0; empty stderr |
| Native demo test compilation | 2026-11-03T05:26:16.922397+00:00 to 2026-11-03T05:26:29.042283+00:00 | 12.119956 | parent 0; empty stderr |
| Linux core build with tests | 2026-11-03T05:24:52.662456+00:00 to 2026-11-03T05:25:09.671021+00:00 | 17.008647 | parent 0; empty stderr |
| Native wall/public-fixture/export-inventory/Doc/Portability selection | 2026-11-03T05:26:17.106047+00:00 to 2026-11-03T05:26:37.826144+00:00 | 20.720198 | parent 0; 238 checks pass, 20.61 reported seconds; empty stderr |
| Linux wall/public-fixture/export-inventory/Doc/Portability selection | 2026-11-03T05:26:16.911021+00:00 to 2026-11-03T05:26:32.472629+00:00 | 15.561680 | parent 0; 238 checks pass, 15.18 reported seconds; empty stderr |
| Native complete demo suite | 2026-11-03T05:27:38.416000+00:00 to 2026-11-03T05:27:43.528793+00:00 | 5.112807 | parent 0; 167 checks pass, 5.09 reported seconds; expected negative-fixture diagnostics retained |

Both complete 238-check selections pass. Native demo passes all 167 retained cases. Preservation
proves all 979 other Haskell files, all 687 compiler fixtures, all other audited subjects and sprints,
the complete encoder/wire, and the decoder after reversal of the named identity ceiling exact.
All demo, package and Python bytes remain exact; base/warm inputs are not edited. The sprint changes
175/183 production lines in one module, 509/528 test lines in two files and 17/18 documentation lines.
LF and scoped git diff --check pass. No sprint-owned ledger row applies. The declared residual
pathname window remains; partial-create fault injection is not evidence of a real full-disk failure.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T05:33:57.242949+00:00 to 2026-11-03T05:39:12.459050+00:00 | 315.217946 | 4125 cases pass, 284.63 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T05:33:57.242829+00:00 to 2026-11-03T05:38:54.929509+00:00 | 297.688418 | 167 cases pass, 1.39 reported seconds; 4125 cases pass, 283.18 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T05:33:57.243164+00:00 to 2026-11-03T05:33:57.979618+00:00 | 0.736441 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T05:33:57.253046+00:00 to 2026-11-03T05:34:03.812596+00:00 | 6.559571 | 376 pass, 5.61 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,108-file matched Windows/Linux snapshot. Dated aggregate digests:

- all982: beec698f9f3846d849bb0c2f467949c1d2505778839267b5d01f5504810c2c89
- owned957: 5fbc4784dd7ff34c6ce3fb23956f5e24c7b6a0b396e0e9eb03e56189868a9155
- docs95: a6a9caa6bb9bb02ddc91793770b8953def04f459153493c27621fbd1277d776b

Both 238-check wall/public-fixture/export-inventory/Doc/Portability selections and all 167 native
demo cases pass. The complete host/model/codec cases cover exact fault propagation, final identity
guards, durable phase recovery, foreign reservations/receipts, near-limit journal preflight, exact
wire tags/lengths, request/spec refusals and actual unsupported rows. Partial-create faults are injected
through the real row wrapper; this is not a full-disk reproduction. The final guard retains its declared
pathname window. The complete encoder/wire and decoder after identity-ceiling constant reversal are
exact; all 979 other Haskell files, all 687 fixtures and all demo/package/Python bytes remain exact.
Production changes are 175/183 lines in one module, tests 509/528 lines in two files, documentation
17/18 lines. Base/warm inputs are not edited and prior phase closures remain current. LF and scoped
git diff --check pass. No sprint-owned ledger row applies. The phase's own gate remains due at phase
closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T05:39:18.849003+00:00 to 2026-11-03T05:39:24.524579+00:00,
5.675594 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.18: Re-enter a reported object without fresh publication [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

A reported owner must re-enter the exact record it read from its protected store, without replaying
fresh publication over a bound record. Add the reported counterpart of kernel re-entry before its
provider and cluster callers adopt it and the tape enforces exact fresh publication in 14.21.

#### Deliverables

- Add reenterReportedObject over a held entry and a bound ReportedObject record, with no row,
  publication or binding write.
- Share the bound-record projection with kernel re-entry while preserving its capability ordering.
- Refuse unbound reported records as malformed and kernel records as unsupported.
- Declare the private export and document the caller's existing store-provenance obligation;
  the sealed StoredOriginRecord type remains owned by Sprint 14.27.

#### Validation

OwnershipSpec checks exact target/record/identity projection from a bound reported record, refuses
an unbound reported record and a bound kernel record before its continuation, and retains every
kernel re-entry capability case. No row is in the new producer's signature. The sealed inventory,
the expanded provider/backend/cluster ownership selection and all four host-static commands pass.

Dated 2026-11-03 implementation after withdrawing the tape preparation: one reported re-entry
producer takes the held entry and a bound reported record. Both faces share only the existing
bound projection; kernel capability refusal still precedes it. Three new cases hold the exact
projection, unbound refusal and kernel-record refusal before continuation. The private export
inventory and canonical seam page declare the producer. The caller still owes the record provenance
checks; this does not claim the planned sealed stored-record contract. Actual measurement,
compilation, expanded selections and all four static results follow.

Dated 2026-11-03 actual compiler/runtime results, frozen throughout each command:

| Command or selection | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core Main | 2026-11-03T05:53:03.432479+00:00 to 2026-11-03T05:53:26.612795+00:00 | 23.180454 | parent 0; empty stderr |
| Native demo Main | 2026-11-03T05:53:03.449682+00:00 to 2026-11-03T05:53:33.080986+00:00 | 29.631480 | parent 0; empty stderr |
| Native core test compilation | 2026-11-03T05:53:53.977513+00:00 to 2026-11-03T05:54:53.883705+00:00 | 59.906541 | parent 0; empty stderr |
| Native demo test compilation | 2026-11-03T05:53:53.995498+00:00 to 2026-11-03T05:54:05.542215+00:00 | 11.546787 | parent 0; empty stderr |
| Linux core build with tests | 2026-11-03T05:53:03.511267+00:00 to 2026-11-03T05:54:53.341018+00:00 | 109.830380 | parent 0; package-index advisory only |
| Native ownership/owners/Doc/Portability/export selection | 2026-11-03T05:55:01.745812+00:00 to 2026-11-03T05:56:01.292834+00:00 | 59.547354 | parent 0; 377 checks pass, 59.40 reported seconds; empty stderr |
| Linux ownership/owners/Doc/Portability/export selection | 2026-11-03T05:55:01.418411+00:00 to 2026-11-03T05:55:28.407540+00:00 | 26.989269 | parent 0; 377 checks pass, 26.50 reported seconds; empty stderr |
| Native complete demo suite | 2026-11-03T05:55:01.537925+00:00 to 2026-11-03T05:55:06.664611+00:00 | 5.126699 | parent 0; 167 checks pass, 5.10 reported seconds; expected negative-fixture diagnostics retained |

Both expanded 377-case selections pass all prior and three new reported re-entry cases. The
catalogues include 37 cluster ownership, 41 provider backend, 38 cluster backend and 19 cluster
reconcile cases omitted by the withdrawn preparation's patterns. Native demo passes all 167 cases.
Preservation proves all 979 other Haskell files, all 687 fixtures and other audited subjects exact;
Object.hs and Tape.hs match the closed 14.17 bytes after the preparation was withdrawn. The one
new producer and shared projection measure 47/50 production lines in one module, tests 24/25
in two files and docs 6/7. Every prior case is retained. Packages, Python/phase 1, demo and base/warm
inputs are unchanged. LF and scoped git diff --check pass. No sprint-owned ledger row applies.
This is shape-checked re-entry with a caller provenance obligation, not the sealed stored-record
contract still owned by 14.27.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T05:56:36.829820+00:00 to 2026-11-03T06:01:56.114871+00:00 | 319.286916 | 4128 cases pass, 288.50 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T05:56:36.830089+00:00 to 2026-11-03T06:02:48.520288+00:00 | 371.692376 | 167 cases pass, 1.27 reported seconds; 4128 cases pass, 285.81 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T05:56:36.829961+00:00 to 2026-11-03T05:56:37.550444+00:00 | 0.720471 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T05:56:36.833425+00:00 to 2026-11-03T05:56:43.268488+00:00 | 6.435086 | 376 pass, 5.54 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,108-file matched Windows/Linux snapshot. Dated aggregate digests:

- all982: 875dcc045be8f71d23cfe408f64e2051276d91a6291b233ee398cd55fdc55161
- owned957: 6f8e6e18ace741ba7e14222502c4ee8cced898ee7ba0e69e519888837f0fd57a
- docs95: d0d63b20198e6c077a3d2ea0ac6cd30e0d5fab6cd33a7ce2319be82ab4f92751

Both expanded 377-case ownership/owners/Doc/Portability/export selections and all 167 native demo
cases pass. The catalogues include all 37 cluster ownership, 41 provider backend, 38 cluster backend
and 19 cluster reconcile cases omitted by the withdrawn tape preparation's literal patterns. Three
new cases prove exact reported target/record/identity projection and both refusals before continuation.
The kernel keeps its capability gate before the shared projection. Production changes are 47/50
lines in one module, tests 24/25 in two files and docs 6/7. All prior cases, all 979 other Haskell
files and all 687 compiler fixtures remain exact. Object.hs and Tape.hs are restored exactly from
the closed 14.17 baseline. Other audited subjects, packages, Python/phase 1, demo and base/warm inputs
are unchanged. LF and scoped git diff --check pass. No sprint-owned ledger row applies. Provider and
cluster adoption belong to 14.19 and 14.20; tape enforcement and its eight cases belong to 14.21.
Re-entry still requires caller store provenance; the sealed stored-record contract belongs to 14.27.
The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T06:03:28.531298+00:00 to 2026-11-03T06:03:34.153687+00:00,
5.622404 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.19: The provider re-enters its stored record and names the clause-fault carrier [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Tape.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

A bare tape result already contains OwnershipFault, including classified store failures. Name its
carrier carryClauseFault so the provider caller states the actual error layer it carries.

#### Deliverables

- Read the exact bound origin record through the tape, validate its claim, origin and identity for
  this provider, and use reenterReportedObject without publishing a fresh or bound record.

- Rename the implementation and export to carryClauseFault and adopt it in the provider owner.
- Correct the tape export heading and carrier/read-back Haddock: publish and forget classify store
  failures through storeFault; readRecordUnder uses fromStoreFault.
- Keep carryStore only as a forwarding name for the not-yet-converted cluster and harness callers,
  with deletion explicitly owned by Sprint 14.23.

#### Validation

The real provider release/backend cases that failed the withdrawn tape preparation now pass;
re-entry preserves the record bytes and version. Include the actual lower-case cluster ownership
and backend group names in the selection. No assertion is weakened.

OwnershipSpec's tape cases and ProviderSpec pass. The provider source names carryClauseFault and no
carryStore. Only the carrier names and bounded re-entry path change; the forwarding name adds no
second implementation. Run all four host-static commands and record actual results.

Dated 2026-11-03 implementation after 14.18 closes: provider re-entry now reads its durable
record through the tape, checks its exact reported claim, absent origin and bound identity, and
uses reenterReportedObject without replaying either publication. An absent record is a probe
failure; a different record is occupied. The old re-publication Haddock is removed. The accurately
named carryClauseFault implementation carries the provider calls, while carryStore forwards for
the remaining cluster/harness callers until 14.23. The replacement-refusal case compares the exact
physical origin envelope, including its version. Tape Haddock states both real error-layer paths.
Actual source measurement, compilation, expanded selections and all four static results follow.

Initial 2026-11-03 expanded selections each ran all 377 cases: native at
06:06:37.119356 to 06:07:36.219491 UTC (59.100463 seconds), Linux at 06:06:36.795613
to 06:07:03.341317 UTC (26.545843 seconds), both parent 1/empty stderr/frozen input.
All 376 other cases passed, including the exact physical provider-origin assertion. The single
failure on each host was DocValidatorSpec: the new forwarding-name Haddock used bare sprint numbers.
The comment now describes the remaining caller adoptions without numeric citations. No executable
byte, assertion, catalogue or guard is changed; final Doc validation and all four results follow.

Dated 2026-11-03 actual compiler/runtime results, frozen throughout each command:

| Command or selection | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core Main | 2026-11-03T06:04:56.179863+00:00 to 2026-11-03T06:05:09.865459+00:00 | 13.685689 | parent 0; empty stderr |
| Native demo Main | 2026-11-03T06:04:56.180633+00:00 to 2026-11-03T06:05:15.699653+00:00 | 19.519136 | parent 0; empty stderr |
| Native core test compilation | 2026-11-03T06:06:11.413552+00:00 to 2026-11-03T06:06:24.227437+00:00 | 12.813962 | parent 0; empty stderr |
| Native demo test compilation | 2026-11-03T06:06:11.421672+00:00 to 2026-11-03T06:06:22.298091+00:00 | 10.876488 | parent 0; empty stderr |
| Linux core build with tests | 2026-11-03T06:04:56.245558+00:00 to 2026-11-03T06:05:43.255038+00:00 | 47.009739 | parent 0; package-index advisory only |
| Native final Doc selection | 2026-11-03T06:09:08.913318+00:00 to 2026-11-03T06:09:14.749723+00:00 | 5.836422 | parent 0; 17 checks pass, 5.75 reported seconds; empty stderr |
| Linux final Doc selection | 2026-11-03T06:09:08.767894+00:00 to 2026-11-03T06:09:13.904002+00:00 | 5.136119 | parent 0; 17 checks pass, 4.80 reported seconds; empty stderr |
| Native complete demo suite | 2026-11-03T06:06:36.924122+00:00 to 2026-11-03T06:06:42.035321+00:00 | 5.111208 | parent 0; 167 checks pass, 5.09 reported seconds; expected negative-fixture diagnostics retained |

The five compiler results and native demo run precede the comment-only correction; their inputs
were frozen throughout each command. Every executable definition stays exact across that correction.
The initial 377-case attempts above passed all 376 non-failing cases, including exact provider-origin
bytes/version preservation; final Doc validation passes all 17 cases on both hosts. Native demo
passes all 167 cases. Final all-four source compilation/test evidence follows below.
Preservation proves all 979 other Haskell files, all 687 fixtures and other audited subjects exact,
all prior case names retained, and the tape's complete publish, bind, forget and read definitions exact.
Provider re-entry names no publication or binding producer. Source deltas measure 82/87 production
lines in two modules, 4/4 tests and 4/4 docs. Packages, Python/phase 1, demo and base/warm inputs
are unchanged. LF and scoped git diff --check pass. No sprint-owned ledger row applies. The forwarding
name remains explicitly owned by the cluster/harness adoptions; it contains no second implementation.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T06:09:56.072044+00:00 to 2026-11-03T06:15:14.478540+00:00 | 318.408354 | 4128 cases pass, 287.16 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T06:09:56.071330+00:00 to 2026-11-03T06:15:08.145656+00:00 | 312.076149 | 167 cases pass, 1.40 reported seconds; 4128 cases pass, 287.59 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T06:09:56.071687+00:00 to 2026-11-03T06:09:56.782868+00:00 | 0.711170 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T06:09:56.071757+00:00 to 2026-11-03T06:10:02.569298+00:00 | 6.497564 | 376 pass, 5.57 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,108-file matched Windows/Linux snapshot. Dated aggregate digests:

- all982: fcfcd34cb984ad3f59b725dbfe9f451a408154991d068e9eb4322de3c2860678
- owned957: 9e5307dde64222b06bdd1bf02f0088ec4ee801ecd4daf2839550fff400bbc432
- docs95: c938045cccb422bbd36efaad89e01d1dc8973d6565ea2116fd8fb13aed03b442

The initial native/Linux 377-case selections each passed all 376 other cases and exposed one
bare-sprint citation in the new Haddock. After that comment-only correction, native/Linux Doc
validation passes all 17 cases; all final Haskell cases pass in both complete commands above.
Native demo passes all 167 cases. The strengthened provider replacement case preserves the exact
physical origin envelope and its version. Provider re-entry reads and validates the stored claim,
absent origin and bound identity before the reported producer, and names no publication or binding
producer. All tape publish/bind/forget/read definitions remain exact; only carrier naming and
Haddock change there. Source deltas are 82/87 production lines in two modules, 4/4 tests and 4/4 docs.
All 979 other Haskell files, all 687 compiler fixtures, all prior case names and other audited subjects
remain exact. Packages, Python/phase 1, demo and base/warm inputs are unchanged. LF and scoped
git diff --check pass. No sprint-owned ledger row applies. The carrier forwarding name remains for
the cluster/harness adoptions in 14.20/14.23 and contains no second implementation. Tape enforcement
and its eight cases remain owned by 14.21. The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T06:15:50.599453+00:00 to 2026-11-03T06:15:56.597533+00:00,
5.998098 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.20: The cluster re-enters its stored record and names the clause-fault carrier [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

The cluster re-enters its actual stored binding without replaying publication, and adopts the same
clause-fault carrier. Its other operations retain their existing decisions and messages.

#### Deliverables

- Read the exact bound origin record through the tape, validate its claim, origin and identity for
  this cluster, and use reenterReportedObject without publishing a fresh or bound record.

- Replace the cluster import and every carryStore use with carryClauseFault.
- Preserve every other cluster operation outside the bounded re-entry and carrier-name adoption.

#### Validation

The real cluster release/backend cases that failed the withdrawn tape preparation now pass;
re-entry preserves the record bytes and version. Include the actual lower-case cluster ownership
and backend group names in the selection. No assertion is weakened.

ClusterOwnershipSpec, ClusterReconcileSpec and OwnershipSpec pass. The cluster source names no
carryStore and all other operations remain exact. Run all four host-static commands.

Dated 2026-11-03 implementation after 14.19 closes: cluster re-entry reads the stored record
through its tape, requires the exact claim, absent origin and bound node identity, then projects it
through reenterReportedObject without fresh or bound publication. A missing record is a probe
failure and a different one is occupied. The cluster uses carryClauseFault throughout; only the
harness owners retain the forwarding name. The stale re-publication Haddock is removed. Its existing
replacement-refusal case now preserves the exact protected origin bytes and version. Actual source
measurement, compilation, expanded selections and all four static results follow.

Initial 2026-11-03 compilation refused the now-unused owned parameter on the private
withBoundNodeClaim helper: native core Main at 06:17:13.053513 to 06:17:19.483374 UTC
(6.429894 seconds), native demo Main at 06:17:13.053811 to 06:17:18.337204 (5.283426 seconds),
and Linux core build at 06:17:13.116835 to 06:17:35.383515 (22.266791 seconds), all parent 1
with frozen inputs. No new tests ran in those commands. The private parameter and its two caller
arguments are removed; no warning policy is weakened. Final compilation and validation results follow.

The initial Linux expanded selection ran 377 cases at 06:19:17.007023 to 06:19:44.935224 UTC
(27.928350 wall seconds, parent 1/empty stderr/frozen input). All 376 other cases passed,
including exact cluster-origin bytes/version preservation. DocValidatorSpec alone rejected a bare
sprint number in the updated canonical page. That sentence now names and links the owning phase;
no Haskell byte or assertion changes. Native expanded selection, final Linux Doc and all four
command results follow.

Dated 2026-11-03 actual compiler/runtime results, frozen throughout each command:

| Command or selection | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core Main | 2026-11-03T06:18:15.587053+00:00 to 2026-11-03T06:18:26.254906+00:00 | 10.667919 | parent 0; empty stderr |
| Native demo Main | 2026-11-03T06:18:15.588286+00:00 to 2026-11-03T06:18:33.958125+00:00 | 18.369951 | parent 0; empty stderr |
| Native core test compilation | 2026-11-03T06:19:17.001838+00:00 to 2026-11-03T06:19:29.840795+00:00 | 12.839029 | parent 0; empty stderr |
| Native demo test compilation | 2026-11-03T06:19:17.012510+00:00 to 2026-11-03T06:19:28.736255+00:00 | 11.723814 | parent 0; empty stderr |
| Linux core build with tests | 2026-11-03T06:18:15.655680+00:00 to 2026-11-03T06:18:40.919218+00:00 | 25.263669 | parent 0; empty stderr |
| Native expanded ownership/owners/Doc/Portability/export selection | 2026-11-03T06:21:14.669631+00:00 to 2026-11-03T06:22:14.044573+00:00 | 59.375279 | parent 0; 377 checks pass, 59.22 reported seconds; empty stderr |
| Linux final Doc selection | 2026-11-03T06:21:14.346292+00:00 to 2026-11-03T06:21:19.705408+00:00 | 5.359129 | parent 0; 17 checks pass, 4.97 reported seconds; empty stderr |
| Native complete demo suite | 2026-11-03T06:21:14.470257+00:00 to 2026-11-03T06:21:19.585934+00:00 | 5.115690 | parent 0; 167 checks pass, 5.09 reported seconds; expected negative-fixture diagnostics retained |

All compiler results above include removal of the unused private argument; no warning is weakened.
The native expanded selection passes all 377 cases, including exact cluster-origin bytes/version
preservation. The initial Linux selection above passed all 376 other cases and exposed the single
bare-sprint citation; after that documentation-only correction, all 17 Linux Doc cases pass. No
Haskell byte changed between those Linux selections. Native demo passes all 167 cases.
Preservation proves all 980 other Haskell files, all 687 fixtures, every prior case name and other
audited subjects exact; the tape, provider and primitive bytes are unchanged. Cluster re-entry names
no fresh/bound publication or binding producer and no carryStore remains in that module. Source
changes measure 62/64 production lines in one module, 5/5 tests and 9/9 docs. Packages, Python/phase 1,
demo and base/warm inputs are unchanged. LF and scoped git diff --check pass. No sprint-owned ledger
row applies. The only remaining carrier forwarding callers are the harness owners, adopted in 14.23.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T06:23:35.215808+00:00 to 2026-11-03T06:28:55.320649+00:00 | 320.106746 | 4128 cases pass, 289.07 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T06:23:35.215563+00:00 to 2026-11-03T06:28:44.988854+00:00 | 309.775131 | 167 cases pass, 1.32 reported seconds; 4128 cases pass, 288.80 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T06:23:35.215880+00:00 to 2026-11-03T06:23:35.932141+00:00 | 0.716250 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T06:23:35.215698+00:00 to 2026-11-03T06:23:41.696116+00:00 | 6.480439 | 376 pass, 5.57 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,108-file matched Windows/Linux snapshot. Dated aggregate digests:

- all982: 97646e50582bc893b71a1295f05a799bb5707d4187c123a98c60cd37baa9c709
- owned957: 02afbb26fa27704aba9f167543f383713ff102545961d8c70a2ee75054f5bc69
- docs95: a8309db19ff41fd3a6385a73c5a81ca748721fc6a21a336867b8335c358e3af7

After removing the unused private helper parameter and its two caller arguments, native/Linux
compilation passes with Werror unchanged. Native expanded validation passes all 377 cases and
all 167 demo cases. Linux's initial expanded attempt passed 376 other cases and exposed one bare
sprint citation in the updated page; the documentation-only correction then passes all 17 Linux
Doc cases. Both complete Haskell commands above pass the final tree. The strengthened replacement
case proves the exact protected cluster-origin bytes and version survive refusal. Cluster re-entry
reads and checks its exact stored claim, absent origin and bound node identity without fresh/bound
publication or binding, and names no carryStore. All 980 other Haskell files, all 687 fixtures,
every prior case name and other audited subjects are exact; tape/provider/primitive bytes remain
unchanged. Deltas are 62/64 production lines in one module, 5/5 tests and 9/9 docs. Packages,
Python/phase 1, demo and base/warm inputs are unchanged. LF and scoped git diff --check pass.
No sprint-owned ledger row applies. Harness carrier adoption/deletion remains owned by 14.23;
tape enforcement remains owned by 14.21. The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T06:29:06.473079+00:00 to 2026-11-03T06:29:12.215661+00:00,
5.742600 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.21: One record tape behind the ownership seam [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Tape.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Object.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`,
`documents/architecture/ownership_invariant.md`

#### Objective boundary

The remaining semantic repair changes only Tape.hs and Object.hs, after reported re-entry and
its provider/cluster adoptions in 14.18 to 14.20. The carrier naming repair finishes with the
harness adoption in 14.23. Historical provider adoption evidence below describes the already-present
implementation, not new production work in this sprint.

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
and `carryClauseFault` are the only places the two error layers are collapsed. `carryClauseFault` lifts through
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

Dated 2026-11-03 withdrawn preparation, originally numbered 14.18: 85/86 production lines in
Tape.hs and Object.hs plus eight cases compiled on native Windows and Linux. Both selected 247-case
runs passed, but their literal patterns omitted the actual lower-case cluster ownership group and
the provider/cluster backend suites. Native demo passed 167 cases. The full commands exposed the
missing caller adoption: existing provider and cluster re-entry replayed fresh publication over an
already bound record. No completion is claimed; all four source/test/doc preparations were archived
outside the repository and withdrawn before Sprint 14.18 was recut as reported re-entry.

| Withdrawn preparation command | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T05:42:52.630169 to 2026-11-03T05:48:02.004038 | 309.375663 | 11/4,133 fail, 278.37 reported seconds; parent 1 |
| demo/: cabal test all | 2026-11-03T05:42:52.630360 to 2026-11-03T05:48:40.161489 | 347.533163 | demo 167 pass/1.33 seconds; core 11/4,133 fail/278.79 seconds; parent 1 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T05:42:52.630525 to 2026-11-03T05:42:53.350898 | 0.720362 | Ruff/Black/mypy pass; parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T05:42:52.644920 to 2026-11-03T05:42:59.102223 | 6.457319 | 376 pass, 100% coverage; parent 0 |

The fresh validation must include ProviderBackendSpec, ClusterBackendSpec, ClusterReconcileSpec and
the actual group named "cluster ownership", as well as the tape cases, so the former omission cannot
be mistaken for caller coverage.

Dated 2026-11-03 implementation after the reported producer and both callers close in 14.18 to
14.20: fresh publication accepts only exact bytes; bound publication swaps only the exact unbound
form and keeps identical bound bytes/version unchanged. A different valid record is Occupied; an
invalid origin body retains its actual Malformed parse fault. Forget parses before deletion. The
shared store classifier maps malformed envelopes to Malformed and other store failures to ProbeFailed.
The eight real-store/binding/classifier cases are restored without weakening an assertion. Both
canonical ownership pages now describe this behavior. The carrier naming and both stored-record
caller adoptions remain unchanged. Actual source measurement, native/Linux compilation, the expanded
selection including the previously failing backend/release groups, and all four results follow.

Dated 2026-11-03 actual compiler/runtime results, frozen throughout each command:

| Command or selection | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core Main | 2026-11-03T06:31:47.858684+00:00 to 2026-11-03T06:32:10.404695+00:00 | 22.546148 | parent 0; empty stderr |
| Native demo Main | 2026-11-03T06:31:47.858843+00:00 to 2026-11-03T06:32:16.353463+00:00 | 28.494793 | parent 0; empty stderr |
| Native core test compilation | 2026-11-03T06:33:11.332714+00:00 to 2026-11-03T06:33:52.144873+00:00 | 40.812401 | parent 0; empty stderr |
| Native demo test compilation | 2026-11-03T06:33:11.343014+00:00 to 2026-11-03T06:33:22.183629+00:00 | 10.840682 | parent 0; empty stderr |
| Linux core build with tests | 2026-11-03T06:31:47.921259+00:00 to 2026-11-03T06:33:15.422404+00:00 | 87.501651 | parent 0; package-index advisory only |
| Native ownership/owners/Doc/Portability/export selection | 2026-11-03T06:34:18.345295+00:00 to 2026-11-03T06:35:17.476212+00:00 | 59.131241 | parent 0; 385 checks pass, 58.95 reported seconds; empty stderr |
| Linux ownership/owners/Doc/Portability/export selection | 2026-11-03T06:34:18.112048+00:00 to 2026-11-03T06:34:45.034595+00:00 | 26.922687 | parent 0; 385 checks pass, 26.41 reported seconds; empty stderr |
| Native complete demo suite | 2026-11-03T06:34:18.239582+00:00 to 2026-11-03T06:34:23.358205+00:00 | 5.118635 | parent 0; 167 checks pass, 5.09 reported seconds; expected negative-fixture diagnostics retained |

Both expanded 385-case selections pass all eight new tape cases, all retained reported re-entry
cases, and the actual provider/cluster backend/release groups that exposed the withdrawn preparation.
Native demo passes all 167 cases. Malformed envelopes and invalid origin bodies remain exact under
all four tape operations; a real directory-as-record read stays a probe failure. Stale bindings keep
their exact bytes/version, an exact unbound form advances once, and identical bound bytes keep their
version. These cases do not force CAS/delete failure after a successful read; actual read-fault branches
and closed store-error classification are what ran. Both caller adoptions remain byte-exact.
Preservation proves all 979 other Haskell files, all 687 fixtures, every prior case, other audited
subjects, complete origin render/parser bytes and carrier definitions unchanged. Source deltas are
79/80 production lines in two modules, 132/138 tests and 45/46 docs across both canonical ownership
pages. Packages, Python/phase 1, demo and base/warm inputs are unchanged. LF and scoped git diff --check
pass. No sprint-owned ledger row applies.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T06:36:13.312506+00:00 to 2026-11-03T06:41:21.587429+00:00 | 308.276755 | 4136 cases pass, 277.27 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T06:36:13.312266+00:00 to 2026-11-03T06:41:54.865202+00:00 | 341.554966 | 167 cases pass, 1.33 reported seconds; 4136 cases pass, 275.14 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T06:36:13.312588+00:00 to 2026-11-03T06:36:14.020365+00:00 | 0.707766 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T06:36:13.318721+00:00 to 2026-11-03T06:36:19.975887+00:00 | 6.657189 | 376 pass, 5.77 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,108-file matched Windows/Linux snapshot. Dated aggregate digests:

- all982: aa47dc73900d51d62e21eb3d9f9c1771a19d4e7d6ec6536833b923c88c9e7c47
- owned957: 08164c5cf95f962bc884d07f1296ac97760c8d01facd571b290ca591c98d6877
- docs95: d7faa2606bbff2ad51ff784a35865ab4df4fb8fd1dd431a08e7e4106b76713d4

Both expanded 385-case selections pass all eight tape cases, retained reported re-entry cases,
and the actual provider/cluster backend and release groups that exposed the withdrawn preparation.
Native demo passes all 167 cases. Exact fresh bytes and exact unbound-to-bound publication preserve
transaction ownership; stale bindings and valid foreign records are Occupied, malformed envelopes
and origin bodies are Malformed, and all refusals preserve bytes/version. Identical bound bytes
keep their version. Real directory-as-record failures remain probe failures. CAS/delete failures
after a successful read were not forced; actual read-fault branches and the closed classifier cases
are the evidence recorded. Both caller adoptions remain byte-exact. The complete origin render/parser
and carrier definitions, all 979 other Haskell files, all 687 fixtures, every prior case and other
audited subjects are unchanged. Deltas are 79/80 production lines in two modules, 132/138 tests and
45/46 docs across both canonical ownership pages. Packages, Python/phase 1, demo and base/warm inputs
are unchanged. LF and scoped git diff --check pass. No sprint-owned ledger row applies. The phase's
own gate remains due at phase closure. Sprint 14.22 is already Done; the next Active work is 14.23.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T06:42:03.466899+00:00 to 2026-11-03T06:42:09.246101+00:00,
5.779218 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.22: The cluster owner adopts the record tape [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`
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
`core/` that closed Sprint 14.23 is the first full run over it, including `ClusterOwnershipSpec` and
`ClusterReconcileSpec`. Recording it that way rather than as a run of its own is what § NN asks for: the
suite that covered this code is the one named.

#### Remaining Work

None.

### Sprint 14.23: The harness owners adopt the record tape [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Tape.hs`, `core/hostbootstrap-core/src/HostBootstrap/Harness/DataRoot.hs`, `core/hostbootstrap-core/src/HostBootstrap/Harness/GeneratedConfig.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`,
`documents/architecture/ownership_seam.md`

#### Objective

These two carry the same eight helpers as each other, verbatim including their documentation
comments, and share twelve consecutive identical import lines. They are the smallest copies and the
clearest demonstration that the adapter was duplicated rather than independently derived.

#### Deliverables

- Both harness owners adopt carryClauseFault; remove the last carryStore forwarding export and
  definition from Tape.hs. No production or test caller retains the old name.

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

Dated 2026-11-03 implementation after the tape enforcement closes: the tape owns one raw
protected-envelope read, and decoded read-back delegates it. Both harness acquisitions use that
raw presence check; forget continuations return the tape fault directly. The duplicated readRecord
and forgetFailure helpers and unused imports are removed. Both harness owners use carryClauseFault,
so the forwarding export/definition is deleted. Four cases check authoritative absence, uninterpreted
body bytes, malformed-envelope domain classification and actual IO faults with a distinct carrier.
The existing architecture guard now forbids raw reads and forgetFailure in both named harness owners.
Both canonical pages describe this route and the owned ledger row is removed. Actual measurement,
native/Linux compilation, expanded selections and all four results follow.

Dated 2026-11-03 actual compiler/runtime results, frozen throughout each command:

| Command or selection | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core Main | 2026-11-03T06:45:39.087467+00:00 to 2026-11-03T06:45:57.670748+00:00 | 18.583396 | parent 0; empty stderr |
| Native demo Main | 2026-11-03T06:45:39.088289+00:00 to 2026-11-03T06:46:03.808970+00:00 | 24.720830 | parent 0; empty stderr |
| Native core test compilation | 2026-11-03T06:47:25.855628+00:00 to 2026-11-03T06:47:59.004474+00:00 | 33.149047 | parent 0; empty stderr |
| Native demo test compilation | 2026-11-03T06:47:25.868048+00:00 to 2026-11-03T06:47:37.657293+00:00 | 11.789316 | parent 0; empty stderr |
| Linux core build with tests | 2026-11-03T06:45:39.153366+00:00 to 2026-11-03T06:46:52.350320+00:00 | 73.197374 | parent 0; package-index advisory only |
| Native ownership/owners/Doc/Portability/export selection | 2026-11-03T06:50:08.351568+00:00 to 2026-11-03T06:51:07.396875+00:00 | 59.045642 | parent 0; 389 checks pass, 58.89 reported seconds; empty stderr |
| Linux ownership/owners/Doc/Portability/export selection | 2026-11-03T06:47:25.855451+00:00 to 2026-11-03T06:47:51.972024+00:00 | 26.116709 | parent 0; 389 checks pass, 25.73 reported seconds; empty stderr |
| Native complete demo suite | 2026-11-03T06:50:08.168912+00:00 to 2026-11-03T06:50:13.280903+00:00 | 5.112004 | parent 0; 167 checks pass, 5.09 reported seconds; expected negative-fixture diagnostics retained |

Both 389-case expanded selections pass all four new raw-reader/domain-carrier cases, the
strengthened harness source guard and every retained ownership/provider/cluster case. Native demo
passes all 167 cases. The compiler and Linux focused results precede removal of one trailing blank
line in Tape.hs; no executable text changed. Native focused/demo selections and the clean scoped
diff check follow that whitespace correction; final all-four source compilation/test evidence follows.
Preservation proves all 978 other Haskell files, all 687 fixtures, every prior case and other audited
subjects exact. All tape publish/bind/forget definitions remain exact. No Haskell source retains
carryStore, and neither harness module names readProtectedRecord, readRecord or forgetFailure.
The owned legacy row alone is deleted. Actual deltas are 95/105 production lines in three modules,
62/67 tests and 24/25 docs including the ledger row. The missing harness-workflow baseline text was
recovered by reversing only the new paragraph, whose complete bytes match the closed prior snapshot
SHA. Packages, Python/phase 1, demo and base/warm inputs are unchanged. LF and scoped git diff --check
pass. The declared raw-read and direct-forget behavior preserves each owner's removal policy.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T06:52:24.161352+00:00 to 2026-11-03T06:57:47.227790+00:00 | 323.068362 | 4140 cases pass, 287.20 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T06:52:24.161270+00:00 to 2026-11-03T06:58:02.223842+00:00 | 338.064586 | 167 cases pass, 1.36 reported seconds; 4140 cases pass, 285.23 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T06:52:24.161039+00:00 to 2026-11-03T06:52:24.876488+00:00 | 0.715433 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T06:52:24.161089+00:00 to 2026-11-03T06:52:30.642987+00:00 | 6.481922 | 376 pass, 5.59 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,108-file matched Windows/Linux snapshot. Dated aggregate digests:

- all982: f61c39765ac1751f246817dbf78770cbee426f8b660bb9c6959f3c71ad9a1a65
- owned957: 0912dc4b430c515e7d949fbc68ddd315dbd5874d88bb47cf776d89f189a63995
- docs95: 824bcda19c705f7565c5b33204092e910ec6304b18b1c6b602387d7847c27ad4

Both expanded 389-case selections pass four new raw-reader/domain-carrier cases and the strengthened
harness guard; native demo passes all 167 cases. Compiler and Linux focused evidence precedes removal
of one trailing blank line; executable text is unchanged, and native focused/demo and both complete
Haskell gates cover the final source. Raw and decoded read-back share one store read; the raw path
preserves absence, envelope bytes/version and the domain store-error variant, while decoded origin
faults use the clause variant. Both harness owners use that raw presence check and direct tape forget;
no duplicate readRecord/forgetFailure helper or carryStore forwarding name remains. All publish,
bind and forget definitions are exact. All 978 other Haskell files, all 687 compiler fixtures,
every prior case and other audited subjects are unchanged. Source deltas are 95/105 production lines
in three modules, 62/67 tests and 24/25 docs including removal of exactly the owned ledger row.
The supplemental harness-workflow baseline matches the closed prior snapshot by complete reversal.
Packages, Python/phase 1, demo and base/warm inputs are unchanged. LF and scoped git diff --check pass.
The owners' own removal policies remain unchanged. The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T12:23:08.899213+00:00 to 2026-11-03T12:23:17.291491+00:00,
8.392304 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.24: The remaining publishers adopt the tape, and one reader decodes the wire [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Tape.hs`,
`core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective boundary

Only the remaining Colima caller adoption and its version-preserving tape operations change source.
The shipped and little-endian adoptions below are historical evidence and remain exact. Colima
retains an origin-record version across its external delete; the tape must compare-and-delete that
version, so an intervening write remains a refusal. Versioned read/forget is one extension to the
existing tape contract, implemented with one decoder and one delete site, across two production
modules. It does not introduce the later sealed stored-record type.

#### Objective

Two owners keep single publish helpers as local definitions inside larger functions — the last copies.
Alongside them, the little-endian word reader is byte-identical in the shipped-ownership row and in the
Windows wall host, which is one wire-format decoder written twice in two unrelated modules.

#### Deliverables

- The tape supplies readVersionedRecordUnder and forgetRecordAtVersion; ordinary decoded read-back
  delegates the versioned decoder, and ordinary forget shares the same exact-version delete.

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

Dated 2026-11-03 implementation after 14.23 closes: all Colima origin records use the reported
or directory tape, including prepared-origin equality, binding, Docker validation, directory
presence, re-entry and release. The versioned reader decodes once from the raw envelope; ordinary
read-back projects its body. Explicit-version forget retains the original pre-command version and
refuses a later write or absence. Both forget modes share one validation/delete implementation.
Colima's separate stage and manifest operations remain raw and retain their versions. Five new
cases cover version/body projection, exact-version deletion, actual intervening-write refusal,
absence refusal and the Colima source guard. Existing malformed cases now cover versioned read/forget;
the invalid-body case is honestly named for decoded operations because raw read preserves body bytes.
The canonical page describes all routes, and exactly the owned legacy row is deleted. Actual source
measurement, native/Linux compilation, focused cases and all four host-static results follow.

Dated 2026-11-03 actual compiler/runtime results, frozen throughout each command:

| Command or selection | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core Main | 2026-11-03T12:35:05.277435+00:00 to 2026-11-03T12:35:35.223963+00:00 | 29.946706 | parent 0; empty stderr |
| Native demo Main | 2026-11-03T12:35:05.280120+00:00 to 2026-11-03T12:35:42.993602+00:00 | 37.713704 | parent 0; empty stderr |
| Native core test compilation | 2026-11-03T12:36:28.229197+00:00 to 2026-11-03T12:36:55.731127+00:00 | 27.502091 | parent 0; empty stderr |
| Native demo test compilation | 2026-11-03T12:36:28.287744+00:00 to 2026-11-03T12:36:46.588033+00:00 | 18.300392 | parent 0; empty stderr |
| Linux core build with tests | 2026-11-03T12:35:05.373415+00:00 to 2026-11-03T12:36:30.025563+00:00 | 84.652624 | parent 0; package-index advisory only |
| Native ownership/owners/Doc/Portability/export selection | 2026-11-03T12:37:56.128391+00:00 to 2026-11-03T12:39:19.714406+00:00 | 83.586473 | parent 0; 394 checks pass, 83.32 reported seconds; empty stderr |
| Linux ownership/owners/Doc/Portability/export selection | 2026-11-03T12:37:55.573467+00:00 to 2026-11-03T12:38:30.006461+00:00 | 34.433174 | parent 0; 394 checks pass, 33.64 reported seconds; empty stderr |
| Native complete demo suite | 2026-11-03T12:37:55.714438+00:00 to 2026-11-03T12:38:01.258134+00:00 | 5.543708 | parent 0; 167 checks pass, 5.51 reported seconds; expected negative-fixture diagnostics retained |

Both expanded 394-case selections pass the five new version/Colima guard cases and strengthened
malformed-state cases. Native demo passes all 167 cases. Real intervening writes and absent retained
versions refuse without changing stored bytes/version; an exact retained version deletes successfully.
Ordinary absence remains settlement. The Colima guard finds no origin codec copy and permits the
single separate manifest deletion; directory operations use their correct tape entrypoints.
ColimaSpec's Linux kernel/store protocol fixtures use scripted command results. Native Windows checks
its declared resolver refusal through onOwnershipHost. Neither is live Apple Silicon Colima acceptance.
Preservation proves all 979 other Haskell files, all 687 fixtures, other audited subjects and prior
cases unchanged, except one label refined to decoded operations so raw-body behavior is described
honestly. Stage/manifest declarations remain exact, and original profile/disk/directory versions are
retained at conditional forget. Exactly the owned legacy row is removed. Deltas are 187/192 production
lines in two modules, 74/74 tests and 14/15 docs including the ledger row. Packages, Python/phase 1,
demo and base/warm inputs are unchanged. LF and scoped git diff --check pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T12:41:58.465890+00:00 to 2026-11-03T12:48:35.816367+00:00 | 397.352802 | 4145 cases pass, 358.43 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T12:41:58.475296+00:00 to 2026-11-03T12:48:37.074383+00:00 | 398.601422 | 167 cases pass, 1.69 reported seconds; 4145 cases pass, 352.20 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T12:41:58.465769+00:00 to 2026-11-03T12:41:59.900593+00:00 | 1.434814 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T12:41:58.475314+00:00 to 2026-11-03T12:42:06.807162+00:00 | 8.331882 | 376 pass, 6.64 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,108-file matched Windows/Linux snapshot. Dated aggregate digests:

- all982: 51cc15f3b80f137f74bb3dc05fb45de23dcf84ce772c5c891233a5921c06f812
- owned957: 6f26db5992279423c770fc57f6f897da1f8e77f9146837b5b2499f53e5fbe070
- docs95: ea55f64044dc34dd2064723fe5ccc3107475577d6617b1bab99fdf42f0649636

Both expanded 394-case selections pass all five new version/Colima guard cases and strengthened
malformed-state cases; native demo passes all 167 cases. Explicit-version forget succeeds only at
the captured version, refuses a real intervening write or absence, and preserves refused bytes/version.
Ordinary forget retains settled-absence behavior. Both routes share one validated conditional delete;
plain and versioned decoded reads share one decoder. Every Colima origin key uses its reported or
directory tape, with original cleanup versions retained across the destructive command. Stage/manifest
protocol declarations remain exact and the direct delete outside the tape is only that manifest.
ColimaSpec uses its Linux kernel/store protocol fixtures with scripted commands and the native Windows
resolver refusal; this is not live Apple Silicon Colima acceptance. All 979 other Haskell files, all
687 fixtures, other audited subjects and prior cases remain exact, except one honestly refined decoded-
operation label. Deltas are 187/192 production lines in two modules, 74/74 tests and 14/15 docs including
exactly the owned legacy row removal. Packages, Python/phase 1, demo and base/warm inputs are unchanged.
LF and scoped git diff --check pass. The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T12:49:27.046623+00:00 to 2026-11-03T12:49:34.604763+00:00,
7.558165 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.25: The host wall's identity-conditional act is the seam's [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Host.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
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
A source guard asserts that `Host.hs` names `withConfirmedIdentity` zero times. The Sprint 14.17
swap-at-act cases in `WslGlobalWallHostSpec` still return their exact constructors. `cabal test all` from
`core/` passes.

Dated 2026-11-03 implementation: the primitive owns the identity-conditional act and both
re-observation faces share its comparison. The wall's copied guard is removed; delete/move use the
observed row's primitives and map only the outer identity-check failure to their exact absent/replaced
conflicts, keeping action errors in the existing domain path. Six cases cover absence, replacement,
matching row/answer, capability refusal before any primitive, observation failure before act, and
both wall functions' source delegation. The classifier guard now counts and pins the added release
gate, and the private export inventory declares the producer. Both canonical pages and the owned
ledger row are reconciled. The existing residual pathname window remains explicit. Actual measurement,
native/Linux compilation, focused ownership/wall selections and all four results follow.

Dated 2026-11-03 actual compiler/runtime results, frozen throughout each command:

| Command or selection | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core Main | 2026-11-03T13:01:33.484856+00:00 to 2026-11-03T13:01:57.084932+00:00 | 23.600217 | parent 0; empty stderr |
| Native demo Main | 2026-11-03T13:01:33.485011+00:00 to 2026-11-03T13:02:04.138607+00:00 | 30.653778 | parent 0; empty stderr |
| Native core test compilation | 2026-11-03T13:03:44.019173+00:00 to 2026-11-03T13:04:27.324997+00:00 | 43.306078 | parent 0; empty stderr |
| Native demo test compilation | 2026-11-03T13:03:44.031782+00:00 to 2026-11-03T13:03:56.682400+00:00 | 12.650690 | parent 0; empty stderr |
| Linux core build with tests | 2026-11-03T13:01:33.571686+00:00 to 2026-11-03T13:03:14.276992+00:00 | 100.705881 | parent 0; package-index advisory only |
| Native ownership/owners/Doc/Portability/export selection | 2026-11-03T13:06:07.948219+00:00 to 2026-11-03T13:07:21.800819+00:00 | 73.853014 | parent 0; 517 checks pass, 73.65 reported seconds; empty stderr |
| Linux ownership/owners/Doc/Portability/export selection | 2026-11-03T13:06:07.599132+00:00 to 2026-11-03T13:06:43.044444+00:00 | 35.445500 | parent 0; 517 checks pass, 34.87 reported seconds; empty stderr |
| Native complete demo suite | 2026-11-03T13:06:07.748040+00:00 to 2026-11-03T13:06:12.891260+00:00 | 5.143228 | parent 0; 167 checks pass, 5.12 reported seconds; expected negative-fixture diagnostics retained |

Both expanded 517-case selections pass the six new ordering/delegation cases, all retained wall
families and the actual replacement/disappearance regressions; native demo passes all 167 cases.
The classifier guard pins the added release gate and thirteen actual identifier sites, rather than
weakening the old check. The new act shares the comparison with reported/kernel re-observation,
checks capabilities before observing and preserves the act's own answer. The wall retains its exact
TargetReplaced/UnexpectedTargetAbsent constructors and its separate action-error layer. The residual
check-to-act window remains explicit; this adds no atomic filesystem exclusion claim.
Preservation proves all 978 other Haskell files, all 687 compiler fixtures, every prior case and other
audited subjects unchanged. The complete driver before namespace helpers and armed/journal/codec
suffix are exact. Only the copied condition and the declared act/error plumbing change. Exactly the
owned legacy row is removed. Deltas are 136/140 production lines in two modules, 70/73 tests in two
files and 18/20 docs including the ledger row. Packages, Python/phase 1, demo and base/warm inputs
are unchanged. LF and scoped git diff --check pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T13:09:50.693787+00:00 to 2026-11-03T13:16:51.621925+00:00 | 420.930603 | 4151 cases pass, 380.90 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T13:09:50.710596+00:00 to 2026-11-03T13:17:28.684538+00:00 | 457.976628 | 167 cases pass, 1.82 reported seconds; 4151 cases pass, 376.80 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T13:09:50.693644+00:00 to 2026-11-03T13:09:51.583842+00:00 | 0.890184 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T13:09:50.717241+00:00 to 2026-11-03T13:09:58.514170+00:00 | 7.796958 | 376 pass, 6.47 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,108-file matched Windows/Linux snapshot. Dated aggregate digests:

- all982: 0a96a6baf46b73a31333e72cc11152c56531503807e123afe6fdd37439c7c9fa
- owned957: b2bc2a799138097b44229add186c6da2df528f449be3b6ead8dbe540c0e315dd
- docs95: cc6144eef819aaf27c860867bd0d91fddd0a4bb54ddfb5305921352fa1e101e7

Both expanded 517-case selections pass the six new seam cases and the existing host-wall replacement,
disappearance, refusal and recovery cases. Native demo passes all 167 cases. The wall delegates its
final identity guard to withReobservedIdentity, which checks ClauseRelease before observation and passes
the same row to the action only on an exact identity match. Absence and replacement preserve the wall's
existing domain refusal; nested action faults retain their own layer. Both kernel re-observation routes
share the comparison, and no withConfirmedIdentity implementation remains. The complete wall driver
before namespace helpers and the armed-stage/journal/codec suffix remain exact. Namespace durability
and resumability remain explicitly owned by the next sprint. All 978 other Haskell files, all 687
fixtures, other audited subjects and prior cases remain exact. Deltas are 136/140 production lines in
two modules, 70/73 tests in two files and 18/20 docs including the owned duplicate-guard ledger row
removal. Packages, Python/phase 1, demo and base/warm inputs are unchanged. LF and scoped git diff
--check pass. The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T13:23:04.120415+00:00 to 2026-11-03T13:23:10.219261+00:00,
6.098860 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.26: The host wall's moves and deletes are durable and resumable mid-move [Done]

**Status**: Done
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

Implementation checkpoint, 2026-11-03: the portable driver now syncs moves/deletes, repairs only
journal-matching duplicate hard-link names before re-observing, reclaims a different fenced armed
identity when the bound stage is absent, and re-probes identity after payload reads. Settlement also
syncs an observed parent before storing success, covering retry after a refused flush. No model,
kernel row, primitive API, record codec or stage-create/link protocol changed.

The source audit at 2026-11-03T13:27:45.021270+00:00 to 13:27:45.061647+00:00 measures
245/247 nonempty/physical production lines in one module, 302/308 test lines in two files and 11/12
documentation lines; every delta reverses to the frozen baseline. Eleven new cases cover four actual
hard-link half-moves, changed-byte preservation, two read races, actual namespace/sync order with
protected-envelope snapshots, a source-unlink refusal and move/delete flush refusals. The previous
bound-stage armed case now asserts reclamation required by this sprint. The three final-act race cases
inject after the post-read identity syscall and preserve their exact absence/replacement assertions.
Conditional families are now 16/15 ownership-refusal cases and 19/19 crash-resume cases. LF and scoped
git diff --check pass. Compilation, native/Linux selections and all four static commands remain due.

Initial native and Linux test compilation refused an ambiguous overloaded move-selector literal under
-Werror=type-defaults. An explicit String annotation corrects the fixture without changing assertions;
both production main builds passed. Fresh test compilation and selections remain due.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T13:28:28.385654+00:00 to 2026-11-03T13:28:36.996937+00:00 | 8.611335 | PASS; parent 0 |
| Native demo main | 2026-11-03T13:28:28.392260+00:00 to 2026-11-03T13:28:45.236670+00:00 | 16.844513 | PASS; parent 0 |
| Native core test | 2026-11-03T13:29:40.916577+00:00 to 2026-11-03T13:29:53.510611+00:00 | 12.594111 | PASS; parent 0 |
| Native demo test | 2026-11-03T13:29:40.953806+00:00 to 2026-11-03T13:29:55.602166+00:00 | 14.648446 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T13:29:40.959421+00:00 to 2026-11-03T13:29:54.874697+00:00 | 13.915343 | PASS; parent 0 |
| Native ownership/wall selection | 2026-11-03T13:30:59.346811+00:00 to 2026-11-03T13:33:03.081795+00:00 | 123.735689 | 528 cases pass; parent 0 |
| Linux ownership/wall selection | 2026-11-03T13:30:58.858751+00:00 to 2026-11-03T13:31:47.788125+00:00 | 48.929643 | 528 cases pass; parent 0 |
| Native complete demo | 2026-11-03T13:30:59.037599+00:00 to 2026-11-03T13:31:04.267156+00:00 | 5.229559 | 167 cases pass; parent 0 |

All successful builds and selections retained frozen source/metadata bytes. Both native test binaries
use rts_thr. Both focused selections include every new case and the existing wall codec, refused
phases, final-act replacement/disappearance, provider/cluster ownership, tape/Colima, portability,
sealed-export and documentation guards. Native demo stderr contains its expected negative fixtures.

The 2026-11-03T13:31:48.810038+00:00 preservation audit confirms all 979 other Haskell files, all 687
compiler fixtures and other audited subjects exact. The pure model, rows, primitive and tape are
unchanged; armed create/bind/link, codec/golden and refused-phase fixtures remain exact. Only the
explicitly changed armed disposition and post-read timing of final-act injection refine prior cases.
Ledger, packages, Python/phase 1, demo and base/warm inputs remain exact. LF and scoped diff check pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T13:33:40.670805+00:00 to 2026-11-03T13:41:57.297650+00:00 | 496.629802 | 4162 cases pass, 440.22 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T13:33:40.682054+00:00 to 2026-11-03T13:41:27.091342+00:00 | 466.412058 | 167 cases pass, 3.20 reported seconds; 4162 cases pass, 441.52 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T13:33:40.686107+00:00 to 2026-11-03T13:33:42.000188+00:00 | 1.314062 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T13:33:40.731563+00:00 to 2026-11-03T13:33:50.170441+00:00 | 9.438901 | 376 pass, 7.73 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,108-file matched Windows/Linux snapshot. Dated aggregate digests:

- all982: 9fd8ce9d198571587a931e73538a7072e4deb2f8e8f09e8cc5ce7c6d880f4754
- owned957: 2d1916f75f441be66f5952eac6b512fee9abd633f89ba89b1ed168479f129307
- docs95: be8ac70afaefc3386489a4807e94cc01cfc6bfdcdc21cfea955ac74f654737ac

Both expanded 528-case selections pass all eleven new wall cases and the prior final-act identity
refusals. Native demo passes all 167 cases. All four actual hard-link half-moves converge from their
rewound outcome-unknown record, removing the exact source and preserving/restoring the journalled
object. Changed duplicate bytes refuse without deleting either name or changing the active envelope.
A source-unlink sharing refusal leaves two real names and recovers on retry. Move/delete flush refusals
keep their intent, and retry syncs the observed parent before settlement. The actual syscall-order
fixture observes five links and six removals, each followed by its parent sync before any protected
envelope advances. Bound-stage fenced armed identities are reclaimed as required, while the post-read
replacement/disappearance cases return Busy before any active record. Final-act cases still assert the
precise existing identity conflicts, with injection after stable observation. All 979 other Haskell
files, all 687 fixtures and other audited subjects remain exact; model, rows, primitive, tape, armed
create/bind/link protocol, record codec/golden cases and refused-phase fixtures are unchanged. Deltas
are 245/247 production lines in one module, 302/308 tests in two files and 11/12 docs. Ledger, packages,
Python/phase 1, demo and base/warm inputs are unchanged. LF and scoped diff check pass. The phase's own
gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T13:42:40.580563+00:00 to 2026-11-03T13:42:47.159658+00:00,
6.579112 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.27: Stored origin evidence and the two store-backed re-entry producers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Tape.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

A protected-store read carries its provenance and exact version in an abstract value tied nominally to the entry that read it. Kernel and reported re-entry accept that value through dedicated producers; shape-validated data alone is insufficient.

#### Deliverables

- Tape defines abstract `StoredOriginRecord session` with a nominal session role and the projections `storedOriginRecord` and `storedRecordVersion`. Its constructor stays inside Tape. Projections are ordinary functions, so neither body nor version can be changed by record-update syntax.
- `readStoredRecordUnder` is the sole mint. It delegates to the existing versioned decoded read, preserving absence, malformed-origin refusals and store-domain errors without a second decoder. Ordinary decoded and raw reads remain inspections.
- Primitive adds `reenterStoredOwnedObject` and `reenterStoredReportedObject`. Each demands a `StoredOriginRecord session` from the same entry and shares the existing pure bound projection. The kernel producer checks ClauseRelease before inspecting the record; the reported producer takes no row.
- Compile-fail fixtures reject in-memory records at both producers, a stored record carried between entries coercion of its session index, and updates of either body or version. Exact exports disclose no constructor. The main library re-exports the tape, and a positive public-consumer control compiles the read, both strict producers and the projections.
- OwnershipSpec exercises stored bound/unbound kernel and reported records, capability refusal without primitives, exact body/version read-back and existing error layers. The caller adoptions are separately bounded below.

#### Validation

The seven new OwnershipSpec cases pass on native Windows and Linux:
- stored read discloses the exact protected version and origin;
- stored kernel re-entry discloses the actual target body and identity without a primitive;
- stored unbound records mint no token on either face;
- stored kernel re-entry checks capability before forcing its stored record;
- stored reported re-entry discloses the actual reported record without a row;
- stored reported re-entry refuses a bound kernel record before its continuation;
- stored evidence is nominal and its sole mint uses the existing decoder.

Existing malformed-envelope, malformed-body, actual unreadable-path and distinct carrier-error cases
also exercise the stored reader, preserving the actual envelopes and versions. The public-consumer
control, "public stored origin read and both strict re-entry routes remain available", compiles using
the actual main-library visibility, its reader, both strict producers and body/version projections.
ReenterInMemoryOwnershipRecord.hs and ReenterInMemoryReportedRecord.hs fail with the exact expected
StoredOriginRecord/OriginRecord mismatch; EscapeStoredOwnershipRecord.hs fails at distinct rigid
entry indices; CoerceStoredOwnershipRecord.hs fails at the nominal index. These six fixtures and six diagnostics pass
on both compilers. UpdateStoredOwnershipRecord.hs and UpdateStoredOwnershipVersion.hs independently refuse body and version updates because
its projections are ordinary functions rather than record selectors. The public export inventory holds the abstract type and tape API exactly.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T14:06:43.428523+00:00 to 2026-11-03T14:07:04.691002+00:00 | 21.262607 | PASS; parent 0 |
| Native demo main | 2026-11-03T14:06:43.435077+00:00 to 2026-11-03T14:07:05.115756+00:00 | 21.680809 | PASS; parent 0 |
| Native core test | 2026-11-03T14:11:57.857285+00:00 to 2026-11-03T14:12:16.799358+00:00 | 18.942182 | PASS; parent 0 |
| Native demo test | 2026-11-03T14:07:48.001838+00:00 to 2026-11-03T14:07:55.844476+00:00 | 7.842688 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T14:11:57.875719+00:00 to 2026-11-03T14:12:37.884759+00:00 | 40.009261 | PASS; parent 0 |
| Native ownership/wall/public boundary selection | 2026-11-03T14:15:23.936942+00:00 to 2026-11-03T14:16:44.371367+00:00 | 80.434888 | 542 cases pass; parent 0 |
| Linux ownership/wall/public boundary selection | 2026-11-03T14:15:23.590341+00:00 to 2026-11-03T14:16:02.364360+00:00 | 38.774221 | 542 cases pass; parent 0 |
| Native complete demo | 2026-11-03T14:15:23.653698+00:00 to 2026-11-03T14:15:28.802109+00:00 | 5.148421 | 167 cases pass; parent 0 |

Both native test binaries use rts_thr. Successful builds and selections retain frozen source/metadata
bytes. Native demo stderr is from its expected negative fixtures. Package-index age advisories are not
source warnings; -Werror remains enabled.

The initial 539-case selections each passed 538 with only the public export-inventory case refused:
Linux 2026-11-03T13:50:02.528524+00:00 to 13:50:38.343994+00:00, 35.815664 wall seconds;
Windows 2026-11-03T13:50:17.195226+00:00 to 13:51:54.347407+00:00, 97.152736 wall seconds.
The public-consumer probe at 2026-11-03T14:04:55.171769+00:00 to 14:04:56.337482+00:00
compiled an update of the initial record-shaped evidence in 1.165717 wall seconds. Earlier all-four
results passed 4,174 cases but did not cover this operation; they establish no sealed-projection
claim. Positional fields and ordinary getter functions now reject both body and version updates;
the two independently named field-update fixtures and fresh builds, selections and all-four results hold that boundary.

The initial combined update fixture was refused at the body field, but its expected wording differed
and GHC stopped before the version update. The 541-case selections each passed 540 and reported only
that intended-refusal wording mismatch: Linux 2026-11-03T14:08:45.707280+00:00 to
14:09:30.215002+00:00, 44.507969 wall seconds; Windows 2026-11-03T14:08:46.140959+00:00 to
14:10:14.499208+00:00, 88.358744 wall seconds. Separate body/version fixtures now each require the
exact Not in scope: record field diagnostic for its own getter. Both assertions remain and pass.

The main-library re-export completes downstream access to the abstract reader and the new positive
control proves it; the exact inventory assertion is retained. Fresh complete builds and 542-case
selections above pass after that completion.

The 2026-11-03T14:11:29.014365+00:00 to 14:11:29.137315+00:00 source audit measures 61/72
nonempty/physical production lines across two modules, 210/230 tests including six new fixtures,
21/25 architecture-document lines and one Cabal re-export line. Every delta reverses to its frozen
baseline. The six new fixture baselines are empty by construction. The preservation audit at
2026-11-03T14:15:33.960774+00:00 confirms all 977 other prior Haskell files, all 687 prior fixtures and
other audited subjects exact. Existing tape operations, unconstrained re-entry and all shared clause
computation remain byte-exact. All six production owner modules are unchanged. The only Cabal change
re-exports Tape. Python/phase 1, demo, base/warm inputs, prior ownership labels, LF and scoped diff check
remain exact or pass. The separately bounded caller adoptions and strict-only boundary follow; this
sprint closes the additive stored-evidence contract.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T14:17:43.102346+00:00 to 2026-11-03T14:24:16.923542+00:00 | 393.823539 | 4176 cases pass, 355.34 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T14:17:43.102558+00:00 to 2026-11-03T14:24:23.449675+00:00 | 400.349502 | 167 cases pass, 1.90 reported seconds; 4176 cases pass, 355.83 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T14:17:43.102737+00:00 to 2026-11-03T14:17:43.982959+00:00 | 0.880207 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T14:17:43.103094+00:00 to 2026-11-03T14:17:50.680396+00:00 | 7.577331 | 376 pass, 6.27 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,114-file matched Windows/Linux tree. Dated aggregate digests:

- all988: 972770691bcabe6eab37226941de72f01ab984171ff540bcac711332ca8f53d9
- owned963: c08a2b44de57fd77bd3dd86f54d05f4987714b550084c9f9a120e05e19120895
- docs95: eb093e06086af4cc2c2f64206419702f38da87573637ff590ba3592cfdd5f8a3

The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T14:26:07.651689+00:00 to 2026-11-03T14:26:14.007996+00:00,
6.356326 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.28: The data root re-enters only from its stored origin [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/DataRoot.hs`,
`core/hostbootstrap-core/test/DataRootSpec.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

releaseDataRoot and recoverDataRoot retain the stored wrapper read under their own data-root tape. Pure policy checks use storedOriginRecord; both kernel re-entry sites consume the wrapper directly. Unbound recovery, late identity checks, generation clearing and precise domain errors remain intact.

#### Deliverables

- releaseDataRoot and recoverDataRoot retain the stored wrapper read under their own data-root tape. Pure policy checks use storedOriginRecord; both kernel re-entry sites consume the wrapper directly. Unbound recovery, late identity checks, generation clearing and precise domain errors remain intact.
- Hold the actual module's stored read and strict re-entry in a source guard. Keep its existing behavioral refusals and record-preservation checks.
- Record the bounded source delta, selected behavior and all four static command results.

#### Validation

OwnershipSpec's "data-root release and recovery retain stored origin evidence" passes against both
actual production definitions. Each reads its own stored wrapper, consumes it at strict kernel
re-entry, and names no unconstrained re-entry or plain decoded reader. DataRootSpec's real-kernel
acquire/release, found-origin preservation, retained/unbound recovery, late identity, replacement and
cleanup cases remain green. All 24 DataRootSpec cases also pass explicitly on native Windows. Existing data-root behavioral
cases are byte-exact; no refusal is weakened.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T14:28:19.386704+00:00 to 2026-11-03T14:28:31.103313+00:00 | 11.716678 | PASS; parent 0 |
| Native demo main | 2026-11-03T14:28:19.404738+00:00 to 2026-11-03T14:28:31.123655+00:00 | 11.718984 | PASS; parent 0 |
| Native core test | 2026-11-03T14:29:30.040466+00:00 to 2026-11-03T14:29:42.923997+00:00 | 12.883610 | PASS; parent 0 |
| Native demo test | 2026-11-03T14:29:30.057912+00:00 to 2026-11-03T14:29:35.597113+00:00 | 5.539237 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T14:28:19.451553+00:00 to 2026-11-03T14:29:08.661200+00:00 | 49.209926 | PASS; parent 0 |
| Native ownership/wall/public boundary selection | 2026-11-03T14:30:20.991932+00:00 to 2026-11-03T14:31:54.933130+00:00 | 93.941753 | 543 cases pass; parent 0 |
| Linux ownership/wall/public boundary selection | 2026-11-03T14:29:30.067182+00:00 to 2026-11-03T14:30:11.932075+00:00 | 41.865131 | 543 cases pass; parent 0 |
| Native data-root kernel selection | 2026-11-03T14:39:26.706167+00:00 to 2026-11-03T14:39:27.123172+00:00 | 0.416985 | 24 cases pass; parent 0 |
| Native complete demo | 2026-11-03T14:30:10.232317+00:00 to 2026-11-03T14:30:15.390411+00:00 | 5.158105 | 167 cases pass; parent 0 |

Both selections also include the six stored-evidence compiler fixtures, positive public-reader
control, provider/cluster ownership and backend groups, generated-config/harness/Colima behavior,
wall recovery and codec, exact exports, portability and documentation guards. All source/compiler
metadata frozen checks pass. Both native test binaries use rts_thr. Native demo stderr is its expected
negative fixture output; the package-index age advisory is not a source warning.

The 2026-11-03T14:27:23.024962+00:00 to 14:27:23.058281+00:00 source audit measures
25/25 nonempty/physical production lines in one module, 13/14 test lines and 3/4 architecture-doc
lines. Every delta reverses to its frozen baseline. The preservation audit at
2026-11-03T14:29:22.952976+00:00 confirms all 986 other Haskell files, all 693 compiler fixtures and
other audited subjects exact. Acquisition, unbound recovery and all generation helper definitions
remain exact; bound recovery projects only policy data and retains its original stored wrapper.
All prior ownership labels remain. The other five owners, primitive/tape/rows, Cabal projects and
packages, Python/phase 1, demo and base/warm inputs are unchanged. LF and scoped diff check pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T14:30:40.845402+00:00 to 2026-11-03T14:37:56.873037+00:00 | 436.030268 | 4177 cases pass, 388.71 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T14:30:40.846726+00:00 to 2026-11-03T14:37:31.358607+00:00 | 410.514365 | 167 cases pass, 2.45 reported seconds; 4177 cases pass, 389.89 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T14:30:40.845027+00:00 to 2026-11-03T14:30:41.900159+00:00 | 1.055119 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T14:30:40.874895+00:00 to 2026-11-03T14:30:49.880349+00:00 | 9.005488 | 376 pass, 7.50 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,114-file matched Windows/Linux tree. Dated aggregate digests:

- all988: cf3f66c00399b39b06b6d27afa6a9af45f770122678bb81d66681f76a1945d78
- owned963: 7fde9ce6ec6e8db444f7de8d5deecb736c8d915e74b2ab26c25ae28663c7a547
- docs95: 69cafc439c2842a355f6b2c9db710684d9962f10e6f8145291a527c0331c3386

The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T14:40:04.437900+00:00 to 2026-11-03T14:40:10.972763+00:00,
6.534886 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.29: The generated config re-enters only from its stored origin [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/GeneratedConfig.hs`,
`core/hostbootstrap-core/test/GeneratedConfigSpec.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

releaseGeneratedConfig and recoverGeneratedConfig retain their stored wrapper through kind, payload and identity validation, then consume it at strict kernel re-entry. Staging withdrawal, unbound outcomes, post-read identity checks and fault constructors remain intact.

#### Deliverables

- releaseGeneratedConfig and recoverGeneratedConfig retain their stored wrapper through kind, payload and identity validation, then consume it at strict kernel re-entry. Staging withdrawal, unbound outcomes, post-read identity checks and fault constructors remain intact.
- Hold the actual module's stored read and strict re-entry in a source guard. Keep its existing behavioral refusals and record-preservation checks.
- Record the bounded source delta, selected behavior and all four static command results.

#### Validation

OwnershipSpec's "generated-config release and recovery retain stored origin evidence" passes
against both actual production definitions. Each reads its own stored wrapper, projects policy/payload
data and consumes that original wrapper at strict kernel re-entry. The module names no unconstrained
re-entry or plain decoded reader. GeneratedConfigSpec's real-kernel creation/release, edited payload,
replacement, retained/unbound recovery, post-read identity and staging cleanup cases remain green.
All prior behavioral cases are byte-exact; no refusal is weakened.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T14:44:59.790661+00:00 to 2026-11-03T14:45:07.789422+00:00 | 7.998807 | PASS; parent 0 |
| Native demo main | 2026-11-03T14:44:59.798398+00:00 to 2026-11-03T14:45:09.616686+00:00 | 9.818340 | PASS; parent 0 |
| Native core test | 2026-11-03T14:45:44.943857+00:00 to 2026-11-03T14:45:58.822238+00:00 | 13.878466 | PASS; parent 0 |
| Native demo test | 2026-11-03T14:47:40.851812+00:00 to 2026-11-03T14:47:46.241721+00:00 | 5.389946 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T14:44:59.890070+00:00 to 2026-11-03T14:45:55.372287+00:00 | 55.482527 | PASS; parent 0 |
| Native ownership/wall/public boundary selection | 2026-11-03T14:47:58.540268+00:00 to 2026-11-03T14:49:35.877868+00:00 | 97.338161 | 595 cases pass; parent 0 |
| Linux ownership/wall/public boundary selection | 2026-11-03T14:47:40.850182+00:00 to 2026-11-03T14:48:23.242650+00:00 | 42.392704 | 595 cases pass; parent 0 |
| Native complete demo | 2026-11-03T14:47:58.031738+00:00 to 2026-11-03T14:48:03.248817+00:00 | 5.217083 | 167 cases pass; parent 0 |

Both expanded 595-case selections include the actual 24-case DataRootSpec and 27-case
OwnershipShippedSpec groups, besides GeneratedConfigSpec. They also include the six stored-evidence compiler fixtures, positive public-reader
control, provider/cluster ownership and backend groups, generated-config/harness/Colima behavior,
wall recovery and codec, exact exports, portability and documentation guards. All source/compiler
metadata frozen checks pass. Both native test binaries use rts_thr. Native demo stderr is its expected
negative fixture output; the package-index age advisory is not a source warning.

The 2026-11-03T14:40:49.566167+00:00 to 14:40:49.602486+00:00 source audit measures
25/25 nonempty/physical production lines in one module, 10/10 test lines and 7/7 architecture-doc
lines. Every delta reverses to its frozen baseline. The preservation audit at
2026-11-03T14:50:05.530673+00:00 confirms all 986 other Haskell files, all 693 compiler fixtures and
other audited subjects exact. Acquisition, unbound recovery, payload/identity and staging helper definitions
remain exact; bound recovery projects policy/payload data and retains its original stored wrapper.
All prior ownership labels remain. The other five owners, primitive/tape/rows, Cabal projects and
packages, Python/phase 1, demo and base/warm inputs are unchanged. LF and scoped diff check pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T14:50:16.597298+00:00 to 2026-11-03T14:57:25.937028+00:00 | 429.342319 | 4178 cases pass, 383.79 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T14:50:16.632495+00:00 to 2026-11-03T14:57:15.789093+00:00 | 419.159126 | 167 cases pass, 2.39 reported seconds; 4178 cases pass, 401.23 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T14:50:16.650973+00:00 to 2026-11-03T14:50:17.629772+00:00 | 0.978776 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T14:50:16.673773+00:00 to 2026-11-03T14:50:25.139956+00:00 | 8.466199 | 376 pass, 6.92 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,114-file matched Windows/Linux tree. Dated aggregate digests:

- all988: c6d50e1db50d7767dae938fd05c204d6b50f08429757ff6cbab61a4af96267f3
- owned963: 030d033867228b3424ad145d1cc27ff4bcf91175a07c9928329f6fa636197e59
- docs95: bd318c16ac540fe55b9fc203d9b9a95803a86437ab45269547a8498c672e4cb3

The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T14:59:18.621850+00:00 to 2026-11-03T14:59:28.094870+00:00,
9.473054 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.30: The shipped owner releases only from its stored origin [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs`,
`core/hostbootstrap-core/test/OwnershipShippedSpec.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

The giveBack path reads a stored origin wrapper and passes it directly to strict kernel re-entry. Inspection-only symbolic-link and acquisition paths keep their existing decoded reads. Wire bytes, canonical requests, symlink policy and conditional release remain intact.

#### Deliverables

- The giveBack path reads a stored origin wrapper and passes it directly to strict kernel re-entry. Inspection-only symbolic-link and acquisition paths keep their existing decoded reads. Wire bytes, canonical requests, symlink policy and conditional release remain intact.
- Hold the actual module's stored read and strict re-entry in a source guard. Keep its existing behavioral refusals and record-preservation checks.
- Record the bounded source delta, selected behavior and all four static command results.

#### Validation

OwnershipSpec's "shipped give-back retains stored origin evidence" passes against the actual
inEntry definition. Only ordinary file/directory giveBack reads the stored wrapper and consumes it at
strict kernel re-entry; the module names no unconstrained producer. All 27 OwnershipShippedSpec cases
and ProviderAliasSpec pass in both expanded selections, including real-kernel lifecycle, exact
replacement refusals and conditional record cleanup. Existing acquisition and symbolic-link paths
retain their behavior; no prior case or refusal is weakened.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T15:02:37.784999+00:00 to 2026-11-03T15:02:44.803034+00:00 | 7.018096 | PASS; parent 0 |
| Native demo main | 2026-11-03T15:02:37.785039+00:00 to 2026-11-03T15:02:46.406807+00:00 | 8.621824 | PASS; parent 0 |
| Native core test | 2026-11-03T15:02:54.843554+00:00 to 2026-11-03T15:03:05.929315+00:00 | 11.085824 | PASS; parent 0 |
| Native demo test | 2026-11-03T15:02:54.857642+00:00 to 2026-11-03T15:02:59.701243+00:00 | 4.843628 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T15:02:37.860507+00:00 to 2026-11-03T15:03:25.691865+00:00 | 47.831633 | PASS; parent 0 |
| Native ownership/wall/public boundary selection | 2026-11-03T15:03:55.517171+00:00 to 2026-11-03T15:05:17.836727+00:00 | 82.320036 | 596 cases pass; parent 0 |
| Linux ownership/wall/public boundary selection | 2026-11-03T15:03:55.178080+00:00 to 2026-11-03T15:04:35.563134+00:00 | 40.385279 | 596 cases pass; parent 0 |
| Native complete demo | 2026-11-03T15:03:55.315933+00:00 to 2026-11-03T15:04:00.465766+00:00 | 5.149842 | 167 cases pass; parent 0 |

Both expanded 596-case selections include the actual 24-case DataRootSpec and 27-case
OwnershipShippedSpec groups, besides GeneratedConfigSpec. They also include the six stored-evidence compiler fixtures, positive public-reader
control, provider/cluster ownership and backend groups, generated-config/harness/Colima behavior,
wall recovery and codec, exact exports, portability and documentation guards. All source/compiler
metadata frozen checks pass. Both native test binaries use rts_thr. Native demo stderr is its expected
negative fixture output; the package-index age advisory is not a source warning.

The 2026-11-03T15:01:41.995439+00:00 to 15:01:42.029754+00:00 source audit measures
7/7 nonempty/physical production lines in one module, 8/8 test lines and 4/4 architecture-doc
lines. Every delta reverses to its frozen baseline. The preservation audit at
2026-11-03T15:03:45.972616+00:00 confirms all 986 other Haskell files, all 693 compiler fixtures and
other audited subjects exact. Ordinary acquisition/observation, symbolic-link policy and all wire codec/helper definitions
remain exact; only ordinary giveBack consumes the new stored wrapper; plain inspection reads retain their original
type and bytes.
All prior ownership labels remain. The other five owners, primitive/tape/rows, Cabal projects and
packages, Python/phase 1, demo and base/warm inputs are unchanged. LF and scoped diff check pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T15:05:27.944857+00:00 to 2026-11-03T15:12:46.243177+00:00 | 438.300973 | 4179 cases pass, 400.30 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T15:05:27.946480+00:00 to 2026-11-03T15:12:14.231647+00:00 | 406.287624 | 167 cases pass, 1.94 reported seconds; 4179 cases pass, 390.61 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T15:05:27.960312+00:00 to 2026-11-03T15:05:28.823784+00:00 | 0.863460 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T15:05:27.969509+00:00 to 2026-11-03T15:05:35.390011+00:00 | 7.420528 | 376 pass, 6.21 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,114-file matched Windows/Linux tree. Dated aggregate digests:

- all988: 3a7bbc46811ed5a15734c6bbb499ed9287823695b2ab5dbafc9575d03a0f346c
- owned963: 17b2f2c56bdfd9dab6df54fd11bb9b85e815ff635e0459232112c1d1287713cd
- docs95: 67cf5b2478b637172cd810fea6d861617c6c25026fc2e527d363df34dcd9939a

The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T15:13:44.339143+00:00 to 2026-11-03T15:13:54.093662+00:00,
9.754552 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.31: The provider re-enters its reported claim from stored evidence [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/test/ProviderBackendSpec.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

withBoundInstanceClaim reads a stored wrapper, checks its projected reported kind, exact owner claim, absent origin and expected identity, then consumes that wrapper in reenterStoredReportedObject. Successful re-entry and refused replacement leave the original protected bytes and version unchanged.

#### Deliverables

- withBoundInstanceClaim reads a stored wrapper, checks its projected reported kind, exact owner claim, absent origin and expected identity, then consumes that wrapper in reenterStoredReportedObject. Successful re-entry and refused replacement leave the original protected bytes and version unchanged.
- Hold the actual module's stored read and strict re-entry in a source guard. Keep its existing behavioral refusals and record-preservation checks.
- Record the bounded source delta, selected behavior and all four static command results.

#### Validation

OwnershipSpec's "provider claim re-entry retains stored origin evidence" passes against the
actual withBoundInstanceClaim definition. The helper reads its provider tape's stored wrapper,
validates the exact reported kind/claim, absent origin and binding, and consumes that original wrapper
at strict reported re-entry. ProviderSpec and ProviderBackendSpec pass, including successful release
and replacement refusal with the exact protected envelope bytes/version unchanged. Scripted provider
observations exercise real protected-store state; this is not live-provider acceptance. Existing
behavioral cases and refusal constructors are unchanged.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T15:17:09.057104+00:00 to 2026-11-03T15:17:19.066405+00:00 | 10.009360 | PASS; parent 0 |
| Native demo main | 2026-11-03T15:17:09.107376+00:00 to 2026-11-03T15:17:20.656855+00:00 | 11.549539 | PASS; parent 0 |
| Native core test | 2026-11-03T15:18:45.422654+00:00 to 2026-11-03T15:19:02.622861+00:00 | 17.200310 | PASS; parent 0 |
| Native demo test | 2026-11-03T15:18:45.434426+00:00 to 2026-11-03T15:18:53.233379+00:00 | 7.799007 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T15:17:09.192719+00:00 to 2026-11-03T15:18:12.180365+00:00 | 62.987997 | PASS; parent 0 |
| Native ownership/wall/public boundary selection | 2026-11-03T15:20:23.724690+00:00 to 2026-11-03T15:22:25.332058+00:00 | 121.608084 | 597 cases pass; parent 0 |
| Linux ownership/wall/public boundary selection | 2026-11-03T15:18:45.403363+00:00 to 2026-11-03T15:19:34.234238+00:00 | 48.831146 | 597 cases pass; parent 0 |
| Native complete demo | 2026-11-03T15:20:08.736899+00:00 to 2026-11-03T15:20:13.913408+00:00 | 5.176520 | 167 cases pass; parent 0 |

Both expanded 597-case selections include the actual 24-case DataRootSpec and 27-case
OwnershipShippedSpec groups, besides GeneratedConfigSpec. They also include the six stored-evidence compiler fixtures, positive public-reader
control, provider/cluster ownership and backend groups, generated-config/harness/Colima behavior,
wall recovery and codec, exact exports, portability and documentation guards. All source/compiler
metadata frozen checks pass. Both native test binaries use rts_thr. Native demo stderr is its expected
negative fixture output; the package-index age advisory is not a source warning.

The 2026-11-03T15:15:31.241630+00:00 to 15:15:31.285822+00:00 source audit measures
14/14 nonempty/physical production lines in one module, 8/8 test lines and 4/4 architecture-doc
lines. Every delta reverses to its frozen baseline. The preservation audit at
2026-11-03T15:18:29.851561+00:00 confirms all 986 other Haskell files, all 693 compiler fixtures and
other audited subjects exact. The complete provider module reverses with only the stored read, projections and strict producer
changes; all claim, origin, identity and error policy is exact. Re-entry performs no publication or
rebinding. Existing provider-backend envelope-preservation cases remain byte-exact.
All prior ownership labels remain. The other five owners, primitive/tape/rows, Cabal projects and
packages, Python/phase 1, demo and base/warm inputs are unchanged. LF and scoped diff check pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T15:20:38.052087+00:00 to 2026-11-03T15:28:10.834971+00:00 | 452.785626 | 4180 cases pass, 399.23 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T15:20:38.052208+00:00 to 2026-11-03T15:27:52.736586+00:00 | 434.687007 | 167 cases pass, 2.49 reported seconds; 4180 cases pass, 411.16 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T15:20:38.052575+00:00 to 2026-11-03T15:20:39.261345+00:00 | 1.208757 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T15:20:38.052733+00:00 to 2026-11-03T15:20:48.650534+00:00 | 10.597842 | 376 pass, 8.70 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,114-file matched Windows/Linux tree. Dated aggregate digests:

- all988: 3a18fc9d135ce908b475575574b12dec9ed965a423cdfd1ebd09c6eebae41f7e
- owned963: 27e7fad46dbc1a16d805098c7db8069a6c6caa24957709fbb9e669840de5a052
- docs95: 430a945386ff7cf84cd44a03107383df33221dad2bc946da0bc6b391ca935129

The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T15:29:47.422794+00:00 to 2026-11-03T15:29:55.525033+00:00,
8.102270 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.32: The cluster re-enters its reported node claim from stored evidence [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs`,
`core/hostbootstrap-core/test/ClusterOwnershipSpec.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

withBoundNodeClaim reads a stored wrapper, checks its projected reported kind, exact owner claim, absent origin and expected identity, then consumes that wrapper in reenterStoredReportedObject. The node release policy and protected-record preservation remain intact.

#### Deliverables

- withBoundNodeClaim reads a stored wrapper, checks its projected reported kind, exact owner claim, absent origin and expected identity, then consumes that wrapper in reenterStoredReportedObject. The node release policy and protected-record preservation remain intact.
- Hold the actual module's stored read and strict re-entry in a source guard. Keep its existing behavioral refusals and record-preservation checks.
- Record the bounded source delta, selected behavior and all four static command results.

#### Validation

OwnershipSpec's "cluster node-claim re-entry retains stored origin evidence" passes against the
actual withBoundNodeClaim definition. The helper reads its cluster tape's stored wrapper,
validates the exact reported kind/claim, absent origin and binding, and consumes that original wrapper
at strict reported re-entry. The actual cluster ownership group, ClusterBackendSpec and ClusterReconcileSpec pass, including successful release
and replacement refusal with the exact protected envelope bytes/version unchanged. Scripted cluster
observations exercise real protected-store state; this is not live-cluster acceptance. Existing
behavioral cases and refusal constructors are unchanged.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T15:31:29.311400+00:00 to 2026-11-03T15:31:36.001206+00:00 | 6.689841 | PASS; parent 0 |
| Native demo main | 2026-11-03T15:31:29.321027+00:00 to 2026-11-03T15:31:37.177489+00:00 | 7.856508 | PASS; parent 0 |
| Native core test | 2026-11-03T15:31:47.592195+00:00 to 2026-11-03T15:31:57.694729+00:00 | 10.102594 | PASS; parent 0 |
| Native demo test | 2026-11-03T15:31:47.597594+00:00 to 2026-11-03T15:31:51.993184+00:00 | 4.395616 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T15:31:29.382813+00:00 to 2026-11-03T15:32:11.297428+00:00 | 41.914852 | PASS; parent 0 |
| Native ownership/wall/public boundary selection | 2026-11-03T15:33:09.552282+00:00 to 2026-11-03T15:34:19.107235+00:00 | 69.555355 | 598 cases pass; parent 0 |
| Linux ownership/wall/public boundary selection | 2026-11-03T15:33:09.263335+00:00 to 2026-11-03T15:33:42.752948+00:00 | 33.489799 | 598 cases pass; parent 0 |
| Native complete demo | 2026-11-03T15:33:09.391197+00:00 to 2026-11-03T15:33:14.512823+00:00 | 5.121637 | 167 cases pass; parent 0 |

Both expanded 598-case selections include the actual 24-case DataRootSpec and 27-case
OwnershipShippedSpec groups, besides GeneratedConfigSpec. They also include the six stored-evidence compiler fixtures, positive public-reader
control, provider/cluster ownership and backend groups, generated-config/harness/Colima behavior,
wall recovery and codec, exact exports, portability and documentation guards. All source/compiler
metadata frozen checks pass. Both native test binaries use rts_thr. Native demo stderr is its expected
negative fixture output; the package-index age advisory is not a source warning.

The 2026-11-03T15:30:37.596714+00:00 to 15:30:37.629701+00:00 source audit measures
14/14 nonempty/physical production lines in one module, 8/8 test lines and 3/3 architecture-doc
lines. Every delta reverses to its frozen baseline. The preservation audit at
2026-11-03T15:33:04.294638+00:00 confirms all 986 other Haskell files, all 693 compiler fixtures and
other audited subjects exact. The complete cluster module reverses with only the stored read, projections and strict producer
changes; all claim, origin, identity and error policy is exact. Re-entry performs no publication or
rebinding. Existing cluster-backend envelope-preservation cases remain byte-exact.
All prior ownership labels remain. The other five owners, primitive/tape/rows, Cabal projects and
packages, Python/phase 1, demo and base/warm inputs are unchanged. LF and scoped diff check pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T15:34:35.034383+00:00 to 2026-11-03T15:39:54.698195+00:00 | 319.665748 | 4181 cases pass, 288.74 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T15:34:35.034203+00:00 to 2026-11-03T15:39:34.813854+00:00 | 299.781462 | 167 cases pass, 1.44 reported seconds; 4181 cases pass, 286.84 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T15:34:35.034009+00:00 to 2026-11-03T15:34:35.781872+00:00 | 0.747850 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T15:34:35.034299+00:00 to 2026-11-03T15:34:41.736758+00:00 | 6.702484 | 376 pass, 5.69 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,114-file matched Windows/Linux tree. Dated aggregate digests:

- all988: c2c392a1d0d2b558f98dbab4d2ce6bb60be7576924185cb5af3141a754dd1fb0
- owned963: 3032d5933d41904f8ecb390e48822075803919170f05def5760d48f4955e2bc8
- docs95: 19e43866ca86d920f03c85b0cda98126793de12aa3619258ed0147952621a955

The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T15:42:48.751490+00:00 to 2026-11-03T15:42:54.675548+00:00,
5.924076 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.33: Colima re-enters stored records and clears only its owned namespaces [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs`,
`core/hostbootstrap-core/test/ColimaSpec.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

Colima's reported profile/disk and owned directory re-entry use stored wrappers and preserve captured versions across destructive commands. Namespace remainder clearing starts inside the strict re-entry of its actually stored parent-directory record and validates that parent identity. It withdraws admitted manifest children with the shared identity-conditional act while that parent authority is held; it manufactures no origin record for child re-entry and publishes no synthetic record to obtain authority.

#### Deliverables

- Colima's reported profile/disk and owned directory re-entry use stored wrappers and preserve captured versions across destructive commands. Namespace remainder clearing starts inside the strict re-entry of its actually stored parent-directory record and validates that parent identity. It withdraws admitted manifest children with the shared identity-conditional act while that parent authority is held; it manufactures no origin record for child re-entry and publishes no synthetic record to obtain authority.
- Hold the actual module's stored read and strict re-entry in a source guard. Keep its existing behavioral refusals and record-preservation checks.
- Record the bounded source delta, selected behavior and all four static command results.

#### Validation

OwnershipSpec's "Colima re-entry and namespace clearing retain stored parent evidence" passes
against the actual cleanupManagedColimaProfileWith definition. Profile/disk and directory reads
retain their actual stored wrappers. Reported re-entry takes no kernel row, and cleanup carries the
captured profile/disk versions across the destructive command into conditional forget.

The existing successful managed cleanup assertions pass unchanged inside the NormalCleanup scenario.
The same complete setup, creation, settlement, manifest-drift and post-command identity refusals also
run with a real parent-directory replacement and a real advanced profile envelope during deletion.
Parent replacement returns OwnershipConflict, preserves foreign bytes and the parked original directory,
and leaves the original home record unchanged. The intervening-version scenario returns
OwnershipProbeFailed and preserves the advanced profile record and its exact raw envelope; both namespace
directories remain. Namespace clearing re-observes its stored parent and each admitted child's exact
identity, withdraws through the shared conditional act and syncs the parent. No fabricated child origin
record or synthetic store publication is used. Command outcomes are interpreted around actual
filesystem/protected-store operations; this is not live Apple Silicon acceptance evidence.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T15:57:22.613143+00:00 to 2026-11-03T15:57:35.623128+00:00 | 13.010067 | PASS; parent 0 |
| Native demo main | 2026-11-03T15:57:22.628473+00:00 to 2026-11-03T15:57:37.762441+00:00 | 15.134061 | PASS; parent 0 |
| Native core test | 2026-11-03T15:57:49.277256+00:00 to 2026-11-03T15:58:08.206840+00:00 | 18.929699 | PASS; parent 0 |
| Native demo test | 2026-11-03T15:57:49.313374+00:00 to 2026-11-03T15:57:56.150703+00:00 | 6.837375 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T15:57:22.703996+00:00 to 2026-11-03T15:58:35.356546+00:00 | 72.652965 | PASS; parent 0 |
| Native ownership/wall/public boundary selection | 2026-11-03T15:58:20.255624+00:00 to 2026-11-03T16:00:15.235489+00:00 | 114.980532 | 599 cases pass; parent 0 |
| Linux ownership/wall/public boundary selection | 2026-11-03T15:58:52.466522+00:00 to 2026-11-03T15:59:41.537251+00:00 | 49.070997 | 599 cases pass; parent 0 |
| Native complete demo | 2026-11-03T15:58:20.024190+00:00 to 2026-11-03T15:58:25.258296+00:00 | 5.234114 | 167 cases pass; parent 0 |

Both expanded 599-case selections include DataRootSpec, OwnershipShippedSpec, GeneratedConfigSpec,
provider/cluster ownership and backend groups, Colima, harness, wall recovery/codec, exact exports,
portability, documentation, all six stored-evidence compiler fixtures and the positive public-reader
control. Source/compiler metadata frozen checks pass. Both native test binaries use rts_thr.
Native demo stderr is its expected negative-fixture output. The package-index age advisory is not
a source warning; the native direct-Colima acceptance lane explicitly reports unsupported without
Apple Silicon hardware and the live-lane opt-in.

The 2026-11-03T15:56:53.427815+00:00 to 15:56:53.452760+00:00 source audit measures
111/111 nonempty/physical production lines in one module, 101/102 test lines and 7/7 documentation
lines. Every edited file reverses exactly to its captured baseline. The preservation audit at
2026-11-03T16:00:28.986947+00:00 confirms all 985 other Haskell files, all 693 compiler fixtures and
other prior snapshot subjects exact. The original successful cleanup assertions remain exact after
accounting for their new scenario nesting; the remainder of ColimaSpec and the implementation from
namespace preparation through the cleanup entrypoint remain exact. Other owners, primitive/tape/rows,
Cabal projects/packages, Python/phase 1, demo and base/warm inputs are unchanged. LF and diff checks pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T15:59:53.314473+00:00 to 2026-11-03T16:07:41.419019+00:00 | 468.107375 | 4182 cases pass, 414.91 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T15:59:53.431488+00:00 to 2026-11-03T16:07:24.676045+00:00 | 451.247283 | 167 cases pass, 2.43 reported seconds; 4182 cases pass, 422.04 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T15:59:53.355271+00:00 to 2026-11-03T15:59:54.598765+00:00 | 1.243471 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T15:59:53.449267+00:00 to 2026-11-03T16:00:03.220264+00:00 | 9.771035 | 376 pass, 8.18 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,114-file matched Windows/Linux tree. Dated aggregate digests:

- all988: 96aaece790f8314ee812ce537016b9fbd8e2b0aabb0573ffa37da0f8df6743ab
- owned963: b89db9eaf78b39616096826cb31a9212d372373d24ef9866c4686e54ed3b8434
- docs95: 0beebb04bd3f6df46e7109885e10ec832cd91f665e54777769ce950948e19e71

The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T16:07:53.881761+00:00 to 2026-11-03T16:08:01.389477+00:00,
7.507742 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.34: Re-entry accepts only evidence read from the protected store [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/EscapeReenteredOwnershipEntry.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`,
`documents/architecture/ownership_invariant.md`

#### Objective

Every re-entry boundary requires stored evidence from the same protected entry. An in-memory or merely parsed origin record cannot mint release authority on either face.

#### Deliverables

- Primitive exposes only reenterStoredOwnedObject and reenterStoredReportedObject for re-entry. The unconstrained reenterOwnedObject and reenterReportedObject producers are absent.
- Both strict producers retain one shared pure bound projection. Their Haddocks state the nominal entry/store-read guarantee and the exact unbound/capability/kind refusals.
- Every production owner has adopted the strict producer and stored reader. No projection of an in-memory bound record or synthetic protected write supplies authority.
- Existing re-entry tests read real protected records before calling either strict producer. EscapeReenteredOwnershipEntry retains its intended session/object diagnostic with a stored input.
- A source guard traverses the production tree and exact export inventory, rejects unconstrained producer definitions/calls, and is shown to bite on in-memory violating module text. The architecture's provenance gap is removed only when this guard and the caller evidence pass.

#### Validation

OwnershipSpec's "all production re-entry requires the exact stored-evidence boundary" passes against
physical core source/internal/app/provider-live and demo source files and the actual primitive export
list. It rejects both deliberately violating producer definitions and calls with in-memory origin
records, while comments and string literals remain controls. Neither unconstrained re-entry name is
defined, called or exported by production. The exact SealedExportInventory passes.

The six existing re-entry cases and withBound now read real protected tape records before the strict
producer. Bound disclosure, unbound refusal, capability-first refusal and reported-kind refusal keep
their exact assertions. The six stored-evidence compiler fixtures and public reader/strict-route control
pass on both hosts. EscapeReenteredOwnershipEntry is retargeted to a StoredOriginRecord input and still
fails for its intended "Couldn't match type 'session' with 'escaped'" diagnostic on both compilers.
The private shared bound projection and every later primitive remain byte-exact.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T16:09:02.050203+00:00 to 2026-11-03T16:09:40.998858+00:00 | 38.948894 | PASS; parent 0 |
| Native demo main | 2026-11-03T16:09:02.078394+00:00 to 2026-11-03T16:09:33.293603+00:00 | 31.215404 | PASS; parent 0 |
| Native core test | 2026-11-03T16:11:57.495375+00:00 to 2026-11-03T16:12:10.989021+00:00 | 13.493718 | PASS; parent 0 |
| Native demo test | 2026-11-03T16:10:26.754389+00:00 to 2026-11-03T16:10:34.218173+00:00 | 7.463827 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T16:11:57.536732+00:00 to 2026-11-03T16:12:10.215559+00:00 | 12.678881 | PASS; parent 0 |
| Native ownership/wall/public boundary selection | 2026-11-03T16:12:18.718813+00:00 to 2026-11-03T16:13:41.731553+00:00 | 83.013223 | 601 cases pass; parent 0 |
| Linux ownership/wall/public boundary selection | 2026-11-03T16:12:18.445036+00:00 to 2026-11-03T16:12:58.872695+00:00 | 40.427882 | 601 cases pass; parent 0 |
| Native complete demo | 2026-11-03T16:11:57.655200+00:00 to 2026-11-03T16:12:02.823790+00:00 | 5.168602 | 167 cases pass; parent 0 |

Both 601-case selections include every stored owner group (DataRootSpec, OwnershipShippedSpec,
GeneratedConfigSpec, provider/cluster ownership/backends and Colima), harness, wall recovery/codec,
exact exports, portability, documentation, all six stored-evidence compiler fixtures, the public-reader
control and the retargeted entry-escape fixture. Frozen source/compiler checks pass and both native
test binaries use rts_thr. Native demo stderr is expected negative-fixture output. The package-index
age advisory is not a source warning. The direct-Colima live lane explicitly reports unsupported without
Apple Silicon hardware and its opt-in; these are static/kernel protocol cases.

The 2026-11-03T16:20:18.105199+00:00 to 16:20:18.120629+00:00 source audit measures
88/94 nonempty/physical production lines in one module, 169/171 test lines and 60/60 documentation
lines. Every edited file reverses exactly to its captured baseline. The preservation audit at
2026-11-03T16:20:18.543130+00:00 confirms all 984 other Haskell files and 692 untouched compiler
fixtures; the only changed fixture is the intended entry-escape retargeting. All other prior snapshot
subjects remain exact. The complete primitive prefix differs only by removing its two old exports;
the shared bound projection and later primitives are exact. Inventory changes remove only those same
two names. All six prior re-entry labels and assertion lines remain. Every production owner, tape/rows,
Cabal packages/projects, Python/phase 1, demo and base/warm inputs is unchanged. LF/diff checks pass.
After the complete gates, a remaining architecture status paragraph was aligned with the strict input;
closed-status DocValidatorSpec validates that documentation-only alignment. Architecture docs now
state the protected stored-read input; the separate runtime entry-lifetime
and exception-safe read work remains explicitly open in this phase.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T16:13:16.366479+00:00 to 2026-11-03T16:19:39.668654+00:00 | 383.304494 | 4183 cases pass, 340.90 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T16:13:16.367906+00:00 to 2026-11-03T16:20:09.241756+00:00 | 412.876355 | 167 cases pass, 1.94 reported seconds; 4183 cases pass, 343.44 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T16:13:16.384928+00:00 to 2026-11-03T16:13:17.361518+00:00 | 0.976574 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T16:13:16.393501+00:00 to 2026-11-03T16:13:24.155386+00:00 | 7.761907 | 376 pass, 6.49 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,114-file matched Windows/Linux tree. Dated aggregate digests:

- all988: e2455b52e0c091d3f7179989e7e30b7669d247cb35c740422c632cf9bc3f418c
- owned963: c6e407e9e5cb38635ab962c67004cbbfa3d188f17b9a12cd243f593df957ac08
- docs95: 3e975e8ea7d851c892de4c345bc3a42152bb580d97b4145d10ecb26ff5a319bd

The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T16:20:43.682717+00:00 to 2026-11-03T16:20:51.860218+00:00,
8.177528 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.35: Windows admits stable identity only on NTFS and ReFS [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Windows.hs`,
`core/hostbootstrap-core/test/OwnershipWindowsSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`, `documents/engineering/wsl2.md`

#### Objective

One filesystem-admission contract decides whether the Windows row can hold stable object identity.
An opened handle's filesystem must be NTFS or ReFS before its full FILE_ID_INFO becomes ownership evidence.

#### Deliverables

- Expose one pure admission function, windowsIdentityFilesystem :: Text -> Maybe OwnershipFault, compiled
  on every host. Admit exactly NTFS and ReFS; refuse other names with OwnershipUnsupported naming the filesystem.
- Read the filesystem with GetVolumeInformationByHandleW on the actual handle already opened, through the
  existing narrow direct kernel boundary. Apply the admission function before encoding its FILE_ID_INFO.
  Authoritative absence admits the nearest existing parent through that same identity path before creation.
  Preserve handle cleanup, no-follow observation and the complete 128-bit file identifier.
- Pin the exact export and actual identity-path source guard, exercise the pure names and native kernel
  observation, and align the identity contract and all four static gates.

#### Validation

OwnershipWindowsSpec's "only NTFS and ReFS admit stable object identity" applies the actual
windowsIdentityFilesystem function to NTFS, ReFS, FAT32, exFAT and FAT. The first two admit;
the other names return the exact OwnershipUnsupported reason containing that filesystem.
"identity admits the opened handle filesystem before encoding FILE_ID_INFO" holds the actual
identityOf definition's handle query, admission, full file-ID query and shared encoding order.
It also holds confirmMissingIdentity's use of the same identity path for the nearest existing parent.

The complete native Windows ownership group passes, including actual file/directory identity,
authoritative absence, link/junction identity, content-read denial, creation/publication, locks,
release-on-death and removal behavior. Get-Volume -DriveLetter C reports NTFS/Healthy on 2026-11-03;
the native fixtures run on that volume. ReFS/FAT names are pure admission cases, not live-volume
acceptance evidence. Linux keeps the declared unavailable-Windows-row refusals while exercising
the same pure policy/source checks. Existing conditional family counts remain unchanged.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T16:28:29.834978+00:00 to 2026-11-03T16:28:38.616176+00:00 | 8.781249 | PASS; parent 0 |
| Native demo main | 2026-11-03T16:28:29.828798+00:00 to 2026-11-03T16:28:37.924939+00:00 | 8.096187 | PASS; parent 0 |
| Native core test | 2026-11-03T16:28:46.021310+00:00 to 2026-11-03T16:29:35.228368+00:00 | 49.207355 | PASS; parent 0 |
| Native demo test | 2026-11-03T16:28:46.031429+00:00 to 2026-11-03T16:28:57.129487+00:00 | 11.098129 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T16:28:29.908648+00:00 to 2026-11-03T16:28:41.407662+00:00 | 11.499065 | PASS; parent 0 |
| Native ownership/wall/public boundary selection | 2026-11-03T16:29:49.500874+00:00 to 2026-11-03T16:31:03.294107+00:00 | 73.793665 | 639 cases pass; parent 0 |
| Linux ownership/wall/public boundary selection | 2026-11-03T16:29:35.164109+00:00 to 2026-11-03T16:30:09.517791+00:00 | 34.353874 | 639 cases pass; parent 0 |
| Native complete demo | 2026-11-03T16:29:35.290394+00:00 to 2026-11-03T16:29:40.430736+00:00 | 5.140356 | 167 cases pass; parent 0 |

The 639-case selections add the complete 38-case Windows ownership group to the preceding boundary
selection. They include every stored owner, harness, wall recovery/codec, exact exports, portability,
documentation, six stored-evidence compiler fixtures, public-reader control and entry-escape fixture.
All frozen checks pass. Both native test binaries use rts_thr and final native build stderr is empty.
Initial native main builds returned 0 but emitted three incompatible C pointer-type warnings for
unused optional DWORD outputs. Those are not clean evidence. The final declaration uses null-only
opaque pointers for those optional outputs; corrected native main/test builds are warning-free.
Native demo stderr is expected negative-fixture output. The direct-Colima live lane explicitly
reports unsupported without Apple Silicon hardware and opt-in.

The 2026-11-03T16:28:09.525159+00:00 to 16:28:09.538660+00:00 source audit measures
69/72 nonempty/physical production lines in one module, 28/30 test lines and 41/41 documentation
lines. Every delta reverses to its captured baseline. The preservation audit at
2026-11-03T16:30:48.609874+00:00 confirms all 985 other Haskell files, all 693 compiler fixtures and
other prior snapshot subjects exact. Existing Windows tests have only insertions. The identity
observer's handle scope, open/create/link/remove/read implementations, and original full file-ID
query/24-byte encoding are exact apart from their new admission nesting. Inventory adds only the
one policy export. The POSIX row, primitives, tape, owners, protected store/object vocabulary, Cabal
packages/projects, Python/phase 1, demo and base/warm inputs remain unchanged. LF/diff checks pass.
The separate unsupported protected-store classification remains open in this phase.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T16:30:58.266280+00:00 to 2026-11-03T16:37:36.676254+00:00 | 398.412390 | 4185 cases pass, 361.66 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T16:30:58.266148+00:00 to 2026-11-03T16:37:40.737537+00:00 | 402.473828 | 167 cases pass, 1.67 reported seconds; 4185 cases pass, 360.05 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T16:30:58.277696+00:00 to 2026-11-03T16:30:59.076114+00:00 | 0.798408 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T16:30:58.277339+00:00 to 2026-11-03T16:31:05.248175+00:00 | 6.970855 | 376 pass, 5.93 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,114-file matched Windows/Linux tree. Dated aggregate digests:

- all988: fb90fda7d2eded51056d11dc767298ff431c4d3c4e923d10db8eb9cbf8814778
- owned963: 439e42237021a4862edca89de936a5f1d4246b7f77d2b4d55fb01e99bdb57b0c
- docs95: 27d71b99953e5a583cdec152c50034d2dc976820462f04f466d316ddde290811

The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T16:38:22.086354+00:00 to 2026-11-03T16:38:28.163809+00:00,
6.077476 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.36: A protected-store clause the host cannot hold is Unsupported [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Object.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`, `documents/engineering/wsl2.md`

#### Objective

One protected-store failure contract distinguishes a lock or writable origin store the host cannot
supply from a failed ordinary probe. Owners receive the same unsupported clause through storeFault.

#### Deliverables

- Add ProtectedUnsupported and one pure exception classifier. Classify FileLockingNotSupported,
  UnsupportedOperation IO errors and permission-denied create/write operations as unsupported, while
  ordinary missing-path IO errors remain ProtectedIOFailure.
- Apply that classifier at store opening, blocking/nonblocking locks and record writes. Catch the
  supported exception families without swallowing asynchronous exceptions; preserve entry cleanup.
- Map ProtectedUnsupported to OwnershipUnsupported in Object.storeFault. Existing ownership carriers
  retain their fromClauseFault route, without another private error translation.
- Exercise exact exception families and owner propagation, a real unwritable POSIX root under an
  unprivileged user, existing native store/lock behavior, exact exports and all four static commands.

#### Validation

AuthoritySpec's unsupported-store cases apply classifyProtectedException to FileLockingNotSupported,
UnsupportedOperation IO errors, permissionErrorType IO errors and doesNotExistErrorType IO errors.
The required locking/acquisition/mutation failures are ProtectedUnsupported; the missing-path case
remains ProtectedIOFailure. The unsupported renderer retains the exact operation and reason.
OwnershipSpec's "unsupported protected-store clauses remain unsupported ownership" confirms the shared
storeFault mapping to OwnershipUnsupported.

"unsupported locking entry failures release the actual store entry" injects the supported exception
through a real entry, then reacquires it and checks its record image unchanged. "unrelated exceptions
escape with the actual store entry released" checks that an AssertionFailed is not flattened and the
entry can be reacquired with its image unchanged. Existing async-session cancellation and owner-thread
cases pass. These are exception-route and cleanup checks, not a claim that the available kernel lacks
locking support.

The real "an unwritable protected store parent is unsupported" case runs separately as UID 65534 on
Linux against a mode-0555 parent. It returns ProtectedUnsupported, creates no store directory, and leaves
the parent empty. The final standalone run selects one case, performs the actual operation with no SKIP,
and has empty stderr. The root-run and Windows selections explicitly report that POSIX permission
fixture unavailable; those skips are not evidence of permission denial.

The exact Protected export list is now pinned as an explicit local sealed surface. Initial Linux
selection passed 679/680 and reported its new pin stale because the supplemental surface declaration
was missing; the declaration is aligned without removing or weakening the pin. A subsequent native
selection passed 678/680 and caught two unchanged raw-read regressions: Windows reports a directory
used as a record path as permission denied. The initial generic error adapter incorrectly made that
unsupported storage. Ordinary read/list probes now retain their original IOFailure adapter; only
mutation/writability faults delegate to the shared unsupported classifier. Both original regression
assertions pass unchanged, including the separately rerun native two-case selection. The earlier full
core/demo runs were deliberately interrupted (core exit 1/SignalException 15, demo exit 130 during core
compilation); neither is passing evidence. Final complete commands below replace them.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T17:03:16.402058+00:00 to 2026-11-03T17:04:23.570272+00:00 | 67.168622 | PASS; parent 0 |
| Native demo main | 2026-11-03T17:03:16.403291+00:00 to 2026-11-03T17:04:26.372595+00:00 | 69.969732 | PASS; parent 0 |
| Native core test | 2026-11-03T17:05:36.556400+00:00 to 2026-11-03T17:07:37.016562+00:00 | 120.460895 | PASS; parent 0 |
| Native demo test | 2026-11-03T17:05:36.559475+00:00 to 2026-11-03T17:05:55.642392+00:00 | 19.083038 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T17:03:16.490730+00:00 to 2026-11-03T17:07:00.681726+00:00 | 224.192344 | PASS; parent 0 |
| Native ownership/wall/public boundary selection | 2026-11-03T17:07:50.380318+00:00 to 2026-11-03T17:09:15.383469+00:00 | 85.003651 | 680 cases pass; parent 0 |
| Linux ownership/wall/public boundary selection | 2026-11-03T17:07:50.155986+00:00 to 2026-11-03T17:08:26.555301+00:00 | 36.399517 | 680 cases pass; parent 0 |
| Native complete demo | 2026-11-03T17:07:35.284582+00:00 to 2026-11-03T17:07:40.399271+00:00 | 5.114703 | 167 cases pass; parent 0 |
| Native unchanged raw-read regression cases | 2026-11-03T17:07:49.560839+00:00 to 2026-11-03T17:07:49.683085+00:00 | 0.122229 | 2 cases pass; parent 0 |
| Actual unprivileged mode-0555 denial, UID 65534 | 2026-11-03T17:07:50.157323+00:00 to 2026-11-03T17:07:50.475085+00:00 | 0.317746 | 1 cases pass; parent 0 |

The final 680-case selections include the protected-store group, every stored owner, complete Windows
ownership group, harness, wall recovery/codec, exact exports, portability, documentation, six
stored-evidence compiler fixtures, public-reader control and entry-escape fixture. All frozen checks
pass. Native main/test build stderr is empty and both native test binaries use rts_thr. Native demo
stderr is its expected negative-fixture output. The direct-Colima live lane reports unsupported without
Apple Silicon hardware and opt-in.

The final 2026-11-03T17:03:01.265748+00:00 to 17:03:01.289361+00:00 audit measures
77/80 nonempty/physical production lines across two modules, 89/91 test lines and 23/23 documentation
lines. Every delta reverses to its captured baseline. Preservation at
2026-11-03T17:04:08.507176+00:00 confirms all 983 other Haskell files, all 693 compiler fixtures and
other prior snapshot subjects exact. Ordinary read/list failures and the IOFailure adapter are exact;
CAS/delete differ only by their mutation error adapters. Record versions, codecs, publication mechanics
and existing live-session owner guard are exact. Run-liveness body/handle scope is exact apart from
the narrow acquisition catch. Blocking lock buffering and acquisition share close-on-exception.
All ownership carriers retain their existing shared fromClauseFault route; no owner-local error
translation is introduced. Rows, tape, owners, Cabal projects/packages, Python/phase 1, demo and
base/warm inputs remain unchanged. LF/diff checks pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T17:08:29.173999+00:00 to 2026-11-03T17:14:16.430703+00:00 | 347.258803 | 4192 cases pass, 310.95 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T17:08:29.184142+00:00 to 2026-11-03T17:17:23.642186+00:00 | 534.461288 | 167 cases pass, 1.48 reported seconds; 4192 cases pass, 324.24 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T17:08:29.175643+00:00 to 2026-11-03T17:08:30.067893+00:00 | 0.892240 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T17:08:29.184326+00:00 to 2026-11-03T17:08:36.357587+00:00 | 7.173285 | 376 pass, 5.98 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,114-file matched Windows/Linux tree. Dated aggregate digests:

- all988: a6708406f3d281b3fc8b16d5f9a0a2ea5d2a18b0ff381a1264706a8e4a462d37
- owned963: 0f1bcd02c5e5f00865e1a0b8f880f34a5c55b698d1d0c86c4be84e71d511c81f
- docs95: e6e4b6336add20a64c6a27303dc9c18378b7ba0254e7dcbe083df7982f782304

The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T17:20:33.906360+00:00 to 2026-11-03T17:20:42.083031+00:00,
8.176698 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.37: Each computation the ownership rows share has one definition site [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/SourceGuard.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

§ KK requires each computation the ownership rows share — the identity read, the no-replace publication,
the identity-conditional act and the record codec — to have one definition site, held by a guard rather
than by review. After Sprints 14.24 and 14.25 remove the last owner-local copies, one guard pins every
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

OwnershipSpec's "physical production sources retain the declared shared computation homes" walks
physical src/internal files independently of Cabal registration. The same checker rejects the kernel
encoder, ordinary/foreign no-replace links, a paired-selector conditional act, an act definition and an
origin codec in deliberately violating module texts. Ordinary stat metadata and comment/string
mentions remain neutral. Actual foreign API strings are read only from foreign-import declarations.

"row declarations are neutral but same-named conditional copies are refused" holds the distinction
between field declarations and selector calls, including a function named refusingPrimitives in the
actual backend source home. The initial three-case selection passed its two controls but flagged
the two backend refusal records because they declare both field names. The final checker distinguishes
declaration syntax without any binding-name whitelist; the added regression case admits the row
declaration and rejects the real paired-selector act under the identical name. All four final cases pass.
The named site/phase table states the allowed backend, symbolic-link and config-install homes and the
guard's lexical/prefix scope; it makes no claim about effects hidden behind arbitrary aliases.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T17:25:19.029144+00:00 to 2026-11-03T17:25:19.787702+00:00 | 0.758561 | PASS; parent 0 |
| Native demo main | 2026-11-03T17:25:19.038099+00:00 to 2026-11-03T17:25:19.862153+00:00 | 0.824056 | PASS; parent 0 |
| Native core test | 2026-11-03T17:43:27.175469+00:00 to 2026-11-03T17:43:47.400649+00:00 | 20.225309 | PASS; parent 0 |
| Native demo test | 2026-11-03T17:43:27.187741+00:00 to 2026-11-03T17:43:28.115690+00:00 | 0.927954 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T17:43:27.276281+00:00 to 2026-11-03T17:43:45.679830+00:00 | 18.403628 | PASS; parent 0 |
| Native computation-home guard | 2026-11-03T17:44:27.891688+00:00 to 2026-11-03T17:44:34.840640+00:00 | 6.948973 | 4 cases pass; parent 0 |
| Native ownership/store/wall/public boundary selection | 2026-11-03T17:44:36.013588+00:00 to 2026-11-03T17:46:47.409221+00:00 | 131.396406 | 684 cases pass; parent 0 |
| Linux ownership/store/wall/public boundary selection | 2026-11-03T17:44:35.516810+00:00 to 2026-11-03T17:45:31.288790+00:00 | 55.772297 | 684 cases pass; parent 0 |
| Native complete demo | 2026-11-03T17:44:35.662706+00:00 to 2026-11-03T17:44:40.884717+00:00 | 5.222007 | 167 cases pass; parent 0 |

The final 684-case selections include the new source guard, complete protected-store and Windows
ownership groups, every stored owner, harness, wall recovery/codec, exact exports, portability,
documentation, six stored-evidence compiler fixtures, public-reader control and entry-escape fixture.
All source/compiler frozen checks pass. Native build stderr is empty; both native test binaries use
rts_thr. Native demo stderr is expected negative-fixture output. The mode-0555 permission fixture
explicitly reports its root/Windows limitation; this source-only sprint claims no new permission
operation. The direct-Colima live lane reports unsupported without Apple Silicon hardware and opt-in.

The final 2026-11-03T17:42:35.877386+00:00 to 17:42:35.922899+00:00 audit measures
zero production changes, 129/137 nonempty/physical test lines in two modules and 21/26 documentation
lines. Every edited file reverses to the captured baseline. The 2026-11-03T17:44:07.809841+00:00
preservation audit confirms all 986 other Haskell files, every production Haskell byte, all 693 compiler
fixtures and other prior snapshot subjects exact. All existing ownership behavior, rows, tape, object
and protected-store vocabulary, Cabal projects/packages, Python/phase 1, demo and base/warm inputs are
unchanged. The only new public name belongs to the test helper. LF/diff checks pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T17:45:21.824880+00:00 to 2026-11-03T17:53:19.433454+00:00 | 477.611469 | 4196 cases pass, 429.95 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T17:45:21.825359+00:00 to 2026-11-03T17:56:05.811608+00:00 | 643.990154 | 167 cases pass, 2.27 reported seconds; 4196 cases pass, 418.94 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T17:45:21.825146+00:00 to 2026-11-03T17:45:22.954721+00:00 | 1.129549 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T17:45:21.825203+00:00 to 2026-11-03T17:45:30.823528+00:00 | 8.998361 | 376 pass, 7.56 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,114-file matched Windows/Linux tree. Dated aggregate digests:

- all988: c302a5d715eb0cb2ca27bb3534c517ec7232878eecbe556e3d43aaa958485f2b
- owned963: be784c8b865113a65a33f12f83b797518c589d77fbae9cb212ecd7e9264fcef6
- docs95: 961ae9e10e0583fafee3750974295948e547465ac3b729565f1d3b8b23aeff0a

The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T20:08:34.164144+00:00 to 2026-11-03T20:08:46.447829+00:00,
12.283744 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.38: The creating producers mutate only from a recorded absence [Done]

**Status**: Done
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

OwnershipSpec's "occupied recorded origins refuse both creators before any primitive" enters and
records controlled present observations for OwnedDirectory and OwnedFile. It inspects the recorded
origin and uses divergent remaining primitives, so an actual creator invocation fails rather than
being counted as a fake success. Both return OwnershipOccupied. This is a refusal-ordering proof,
not a claim about a kernel observation.

"a failed real link retains its fault and target while attempting staging withdrawal" observes the
absent target and durably publishes its origin through the real protected store. It then occupies the
target with foreign bytes and runs actual host staging creation and no-replace linking. The exact
real link fault is retained, the target bytes/identity and record bytes/version remain unchanged,
and staging is withdrawn. Its second scenario injects a typed cleanup refusal and verifies that the
original link fault still wins and the actual staging object remains.

"a failed staging create preserves the existing foreign stage" uses an actual exclusive-create
collision, retaining foreign staging bytes/identity, an absent target and the exact origin envelope.
The failed-create branch removes nothing. All three cases pass on native Windows and Linux through
ownershipRowForHost; the kernel scenarios are not stand-in success/attempt counters.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T20:12:21.531890+00:00 to 2026-11-03T20:12:54.700468+00:00 | 33.168768 | PASS; parent 0 |
| Native demo main | 2026-11-03T20:12:21.531808+00:00 to 2026-11-03T20:13:06.941568+00:00 | 45.410035 | PASS; parent 0 |
| Native core test | 2026-11-03T20:13:44.544739+00:00 to 2026-11-03T20:14:45.207493+00:00 | 60.663108 | PASS; parent 0 |
| Native demo test | 2026-11-03T20:13:44.532814+00:00 to 2026-11-03T20:14:03.717260+00:00 | 19.184566 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T20:12:21.654417+00:00 to 2026-11-03T20:14:07.417791+00:00 | 105.764010 | PASS; parent 0 |
| Native creating-producer cases | 2026-11-03T20:14:57.993745+00:00 to 2026-11-03T20:14:58.217022+00:00 | 0.223258 | 3 cases pass; parent 0 |
| Native ownership/store/wall/public boundary selection | 2026-11-03T20:15:23.134407+00:00 to 2026-11-03T20:17:24.792298+00:00 | 121.658628 | 687 cases pass; parent 0 |
| Linux ownership/store/wall/public boundary selection | 2026-11-03T20:15:22.939514+00:00 to 2026-11-03T20:16:14.190207+00:00 | 51.250996 | 687 cases pass; parent 0 |
| Native complete demo | 2026-11-03T20:15:23.099805+00:00 to 2026-11-03T20:15:28.291246+00:00 | 5.191452 | 167 cases pass; parent 0 |

Both final 687-case selections retain the complete protected-store and Windows ownership groups,
all stored owners, harness, wall recovery/codec, computation-site and exact export guards, portability,
documentation, six stored-evidence compiler fixtures, public-reader control and entry-escape fixture.
Frozen source/compiler checks pass. Native main/test build stderr is empty and both test binaries use
rts_thr. Initial compilation caught a missing originRecordOrigin import; the explicit import is included
in the final clean builds. Native demo stderr is expected negative-fixture output. The mode-0555
fixture reports its root/Windows limitation; the direct-Colima live lane reports unsupported without
Apple Silicon hardware and opt-in.

The 2026-11-03T20:12:09.475108+00:00 to 20:12:09.495695+00:00 final source audit measures
90/91 nonempty/physical production lines in one module, 96/99 test lines and 10/13 documentation lines.
All edited files reverse exactly to the captured baseline. Preservation at
2026-11-03T20:15:33.025722+00:00 confirms all 986 other Haskell files, all 693 compiler fixtures and
other prior snapshot subjects exact. The primitive prefix differs only by the origin getter import;
everything after the creating producers is exact. Failed staging creation retains its original branch,
apart from nesting beneath the new origin guard. The typed link-failure withdrawal is the only new
kernel operation; capability checks still precede record inspection and kind/digest checks remain
inside the absent-origin branch. Rows, tape, owners, object/protected vocabulary, Cabal packages/projects,
Python/phase 1, demo and base/warm inputs are unchanged. LF/diff checks pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T20:16:54.749771+00:00 to 2026-11-03T20:24:37.422566+00:00 | 462.675689 | 4199 cases pass, 412.23 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T20:16:54.749631+00:00 to 2026-11-03T20:25:14.735211+00:00 | 499.988694 | 167 cases pass, 2.46 reported seconds; 4199 cases pass, 417.68 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T20:16:54.790517+00:00 to 2026-11-03T20:16:56.204001+00:00 | 1.413473 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T20:16:54.792699+00:00 to 2026-11-03T20:17:03.491665+00:00 | 8.698998 | 376 pass, 6.97 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,114-file matched Windows/Linux tree. Dated aggregate digests:

- all988: 3bcc8bd08301de4e60775231f61b382315251e74672c20043a980f3d1cbd5f8a
- owned963: 621d65457196198c2ba18776fc33c1635e34ba3304319f0d311926ccbdd83b2a
- docs95: e4f64662f914928232059f43cc107c3084e5b90bd4e73d91074d9d6df7f66ecc

The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T20:27:01.199476+00:00 to 2026-11-03T20:27:10.419640+00:00,
9.220199 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.39: The object index and the reported face are held by fixture and guard [Done]

**Status**: Done
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

EscapeOwnedObjectIndex.hs and EscapeReportedObjectIndex.hs both fail with the complete expected
object/escaped type-mismatch phrase on native Windows and Linux. Their imports and producer calls
resolve; the failure holds the freshly introduced object index, separately from the existing session
escape fixtures. The two reported-face cases inventory every current primitive field, check the
reported producers plus reenterStoredReportedObject and reenterBoundRecord, and reject one violating
source per forbidden vocabulary name. This establishes a bounded source property; arbitrary caller IO
continuations remain the caller's effects.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T20:31:58.275260+00:00 to 2026-11-03T20:31:59.072617+00:00 | 0.797357 | PASS; parent 0 |
| Native demo main | 2026-11-03T20:31:59.362844+00:00 to 2026-11-03T20:32:00.227978+00:00 | 0.865137 | PASS; parent 0 |
| Native core test | 2026-11-03T20:32:00.579307+00:00 to 2026-11-03T20:32:18.732164+00:00 | 18.152955 | PASS; parent 0 |
| Native demo test | 2026-11-03T20:32:10.779385+00:00 to 2026-11-03T20:32:11.386564+00:00 | 0.607179 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T20:32:11.838974+00:00 to 2026-11-03T20:32:51.548375+00:00 | 39.709544 | PASS; parent 0 |
| Native object-index and reported-face cases | 2026-11-03T20:32:47.480964+00:00 to 2026-11-03T20:32:48.327089+00:00 | 0.846110 | 4 cases pass; parent 0 |
| Native ownership/store/wall/public boundary selection | 2026-11-03T20:32:49.052800+00:00 to 2026-11-03T20:34:13.502902+00:00 | 84.450413 | 690 cases pass; parent 0 |
| Linux ownership/store/wall/public boundary selection | 2026-11-03T20:33:17.421742+00:00 to 2026-11-03T20:34:03.641592+00:00 | 46.220010 | 690 cases pass; parent 0 |
| Native complete demo | 2026-11-03T20:32:59.051506+00:00 to 2026-11-03T20:33:04.181910+00:00 | 5.130408 | 167 cases pass; parent 0 |

Both final 690-case selections retain the complete protected-store and Windows ownership groups,
all stored owners, harness, wall recovery/codec, computation-site and exact export guards, portability,
documentation, stored-evidence compiler fixtures, public-reader control and both index escape axes.
All native builds have empty stderr and both test binaries use rts_thr. The Linux build reports only
its stale Hackage index notice. Native demo stderr is expected negative-fixture output. The protected
mode-0555 fixture reports its Windows/root limitation; direct-Colima reports unsupported without the
Apple Silicon host and opt-in. No new case is skipped.

The final source audit at 2026-11-03T20:28:09.464363+00:00 to
2026-11-03T20:28:09.535780+00:00 measures zero production changes, 89/91 nonempty/physical changed
test lines and 10/13 architecture-document lines. Complete reversals match the captured baseline.
Preservation at 2026-11-03T20:33:57.020059+00:00 confirms all 986 other prior Haskell files, all 693
prior compiler fixtures and all production files unchanged; the two new fixtures bring the catalogue
to 695. All rows, tape, owners, object/protected vocabulary, Cabal packages/projects, Python/phase 1,
demo and base/warm inputs are unchanged. LF/diff checks pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T20:33:27.685132+00:00 to 2026-11-03T20:39:31.658671+00:00 | 363.974940 | 4202 cases pass, 327.94 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T20:33:37.855221+00:00 to 2026-11-03T20:39:20.626668+00:00 | 342.772766 | 167 cases pass, 1.69 reported seconds; 4202 cases pass, 326.32 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T20:33:48.047072+00:00 to 2026-11-03T20:33:48.898345+00:00 | 0.851259 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T20:33:49.356264+00:00 to 2026-11-03T20:33:56.526814+00:00 | 7.170560 | 376 pass, 6.08 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,116-file matched Windows/Linux tree. Dated aggregate digests:

- all990: bb662cc80153284e1f9054bb38926d7d00d01c292b16ee4f4dca36d2cc688077
- owned965: e997fef1fe0c539c710c7f860d8660d133b684479bb64b9ffdbd0a8dce602268
- docs95: 2e3cef49fca4b3c94e6d7015a07f4e8670d783e5c5e6ed3bbc6217c5cafeff26

The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T20:39:53.294101+00:00 to 2026-11-03T20:39:59.265439+00:00,
5.971344 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.40: The capability declaration names only what a clause requires [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Posix.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Windows.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/DataRootSpec.hs`,
`core/hostbootstrap-core/test/GeneratedConfigSpec.hs`,
`core/hostbootstrap-core/test/OwnershipWindowsSpec.hs`,
`core/hostbootstrap-core/test/OwnershipPosixSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

§ NN decides `Unsupported` by a declaration the classifier reads, so `OwnershipCapabilities` declares only
the capabilities some clause requires: stable identity, no-replace publication and durable parent sync.
`holdsExclusiveOpen` gates no clause and no owner reads it before `rowOpenExclusive`, whose unavailable
rows refuse in the primitive. Its deletion touches both rows' declarations and the suites of the data
root, the generated config and the Windows row, so it lands after Sprints 14.8 and 14.10, where all of
them exist.

#### Deliverables

- `OwnershipCapabilities` has three fields, `holdsStableIdentity`, `holdsNoReplacePublication` and
  `holdsDurableParentSync`, and every one is a field `clauseRefusal` reads.
- The available and unavailable declarations in `Ownership/Posix.hs` and `Ownership/Windows.hs` declare
  those three fields.
- `ownership_seam.md` states no exclusive-open capability.

#### Validation

OwnershipSpec's "each clause refuses exactly when a capability it needs is absent" asserts exactly
eight combinations of stable identity, no-replace publication and durable parent sync, then applies
the real total classifier to each clause. The four classifier cases pass on both gate hosts. The
unused exclusive-open assertion is absent. OwnershipPosixSpec and OwnershipWindowsSpec's "the row
holds every clause together or none of them" compare the actual row declaration with the host's
supported/unsupported answer, using three fields; data-root and generated-config refusal fixtures
also compile with three arguments.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T20:40:38.850638+00:00 to 2026-11-03T20:40:57.681642+00:00 | 18.831078 | PASS; parent 0 |
| Native demo main | 2026-11-03T20:40:38.850621+00:00 to 2026-11-03T20:41:05.763635+00:00 | 26.913116 | PASS; parent 0 |
| Native core test | 2026-11-03T20:50:12.626957+00:00 to 2026-11-03T20:50:24.880359+00:00 | 12.253447 | PASS; parent 0 |
| Native demo test | 2026-11-03T20:41:32.487548+00:00 to 2026-11-03T20:41:44.007998+00:00 | 11.520491 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T20:50:12.645135+00:00 to 2026-11-03T20:50:48.081751+00:00 | 35.436734 | PASS; parent 0 |
| Native capability classifier | 2026-11-03T20:50:54.661653+00:00 to 2026-11-03T20:50:54.833096+00:00 | 0.171424 | 4 cases pass; parent 0 |
| Native ownership/store/wall/public boundary selection | 2026-11-03T20:50:54.790620+00:00 to 2026-11-03T20:52:23.491362+00:00 | 88.701061 | 719 cases pass; parent 0 |
| Linux ownership/store/wall/public boundary selection | 2026-11-03T20:50:54.460767+00:00 to 2026-11-03T20:51:38.763858+00:00 | 44.303239 | 719 cases pass; parent 0 |
| Native complete demo | 2026-11-03T20:50:54.593387+00:00 to 2026-11-03T20:50:59.715119+00:00 | 5.121733 | 167 cases pass; parent 0 |

Both final 719-case selections include both complete platform-row groups, the protected-store group,
all stored owners, harness, wall recovery/codec, computation-site and exact export guards, portability,
documentation, stored/index compiler fixtures and public-reader control. The native supported row is
Windows/NTFS and the Linux supported row is POSIX. Frozen source/compiler checks pass; native build
stderr is empty and test binaries use rts_thr. The Linux build reports its stale Hackage index notice.
Native demo stderr is expected negative-fixture output. Existing permission fixtures state their
Windows/root limitation; direct-Colima states unsupported without Apple Silicon and opt-in. No case
is newly skipped.

The final source audit at 2026-11-03T20:49:56.519055+00:00 to
2026-11-03T20:49:56.547651+00:00 measures 6/6 nonempty/physical removed production lines in three
modules, 33/33 changed test lines and 2/3 documentation/ledger lines. Complete reversals match the
captured baseline. Preservation at 2026-11-03T20:41:42.693396+00:00 confirms all 982 other Haskell
files and all 695 compiler fixtures unchanged, and reconstructs each production file by deleting only
the dead field declaration/documentation. All clause and primitive bodies remain exact. Tape, owners,
object/protected vocabulary, Cabal packages/projects, Python/phase 1, demo and base/warm inputs are
unchanged. Final diff/LF checks pass. An earlier complete gate passed before two test comments were
aligned; the results below are the final rerun against the corrected comments.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T20:51:04.647096+00:00 to 2026-11-03T20:56:49.010160+00:00 | 344.364389 | 4201 cases pass, 308.90 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T20:51:04.653922+00:00 to 2026-11-03T20:56:24.687810+00:00 | 320.035121 | 167 cases pass, 1.57 reported seconds; 4201 cases pass, 308.31 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T20:51:04.667519+00:00 to 2026-11-03T20:51:05.446816+00:00 | 0.779279 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T20:51:04.677356+00:00 to 2026-11-03T20:51:11.780208+00:00 | 7.102861 | 376 pass, 6.10 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,116-file matched Windows/Linux tree. Dated aggregate digests:

- all990: d9e7f3729621ed20c8a07444682ee5c31611265885c8a707e54684220a9151e7
- owned965: 6b5034faadfa6865b5ef6515341b40c71765f55d2e734ff976437c7ad14735a8
- docs95: 60b04b2f3508b57932fe62000de5e54953a9bb3447e32458419f8cddcc4efc4d

The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T20:57:09.672701+00:00 to 2026-11-03T20:57:18.932770+00:00,
9.260075 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.41: Ownership effects require the live entry on its owning thread [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Internal.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`,
`documents/architecture/ownership_invariant.md`,
`documents/architecture/unrepresentable_state.md`

#### Objective

Nominal indices prevent direct cross-entry evidence, while ordinary IO closures can retain a session
and token after a bracket returns. Every effectful ownership producer therefore requires that the
actual protected entry is still live and the current thread owns it, before any primitive or supplied
continuation. The protected-store floor already enforces these runtime conditions for its own effects;
ownership carries and consumes that same entry fact.

#### Deliverables

- Protected exposes a read-only live-session/owner-thread check over its existing private runtime floor;
  it performs no filesystem probe or publication and preserves precise expired/foreign-thread errors.
- Hidden clause tokens carry their actual ProtectedSession through every successor. Their public
  eliminators and nominal indices stay intact, with no constructor or record-update escape.
- Every effectful owned/reported clause producer, including re-entry, create, publication, identity
  observation and release, consumes the live-entry check before any row primitive or caller callback.
  Pure comparisons may project evidence; no delayed IO effect can rely only on that projection.
- Existing capability refusal ordering and domain fault layers remain intact. Both faces share the
  operational entry check; the reported face still takes no row and reaches no ownership primitive.
- OwnershipSpec exercises deferred IO closures after normal/exceptional entry exit, a foreign thread
  while the entry is held, and live same-thread controls. Actual object/record observations prove a
  refused release changes neither namespace nor envelope. Source guards hold all relevant effectful
  producer paths, following their shared helpers.

#### Validation

OwnershipSpec's "delayed entry and successor effects refuse after normal or exceptional exit" retains
thirteen IO closures across normal exit and an actual thrown AssertionFailed. Both entry faces, both
strict stored routes, recording, both creators, binding, kernel re-observation and both releases return
the precise expired-entry fault before a divergent row primitive or callback. Stored re-entry uses an
actual protected publication/read. The divergent setup proves refusal ordering, not kernel success.

"foreign-thread entry and successor effects refuse while the entry remains live" runs the same thirteen
paths on an actual other thread, checks the precise foreign-thread refusal, and then succeeds on the
owning thread. "refused real releases preserve the file and envelope and a live retry settles both"
creates and publishes an actual host-row file, durably records/binds it, and refuses actual release on
a foreign thread and after expiry. Bytes, kernel identity and the exact protected envelope survive.
A fresh live entry reads that same version, re-enters/re-observes, removes the file and conditionally
forgets its record; both namespace and record then disappear.

"every typed effect follows the shared live-entry check and tokens retain the session" holds the
current definition dependencies through the effectful projection helpers to verifyProtectedSession,
and the actual session field on all four private positional tokens. Both reported source cases follow
the added shared helpers and still reject the complete kernel vocabulary. Public eliminators and
nominal indices retain their signatures, and the exact Protected export pin admits only the read-only
check. Pure comparisons carry description; raw rows and tokenless conditional acts remain below the
typed authority boundary.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T20:58:26.793448+00:00 to 2026-11-03T21:00:03.948406+00:00 | 97.155348 | PASS; parent 0 |
| Native demo main | 2026-11-03T20:58:26.798694+00:00 to 2026-11-03T21:00:18.871291+00:00 | 112.073030 | PASS; parent 0 |
| Native core test | 2026-11-03T21:04:45.861919+00:00 to 2026-11-03T21:05:03.781503+00:00 | 17.919663 | PASS; parent 0 |
| Native demo test | 2026-11-03T21:01:01.228019+00:00 to 2026-11-03T21:01:31.168916+00:00 | 29.941013 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T21:04:45.895974+00:00 to 2026-11-03T21:05:05.276938+00:00 | 19.381019 | PASS; parent 0 |
| Native live-entry cases | 2026-11-03T21:05:40.235265+00:00 to 2026-11-03T21:05:40.558163+00:00 | 0.322872 | 4 cases pass; parent 0 |
| Linux live-entry cases | 2026-11-03T21:05:39.815826+00:00 to 2026-11-03T21:05:40.479631+00:00 | 0.663779 | 4 cases pass; parent 0 |
| Native ownership/store/wall/public boundary selection | 2026-11-03T21:05:46.029960+00:00 to 2026-11-03T21:07:45.598837+00:00 | 119.569316 | 723 cases pass; parent 0 |
| Linux ownership/store/wall/public boundary selection | 2026-11-03T21:05:45.668496+00:00 to 2026-11-03T21:06:39.440668+00:00 | 53.772361 | 723 cases pass; parent 0 |
| Native complete demo | 2026-11-03T21:05:45.758610+00:00 to 2026-11-03T21:05:50.912863+00:00 | 5.154251 | 167 cases pass; parent 0 |

Both final 723-case selections include both platform rows, protected-store cases, every stored owner,
harness, wall recovery/codec, computation-site and exact export guards, portability/documentation,
stored/index compiler fixtures and the public-reader control. Frozen source/compiler checks pass;
native main/test build stderr is empty and both native test binaries use rts_thr. The final Linux
build also has empty stderr. Initial test compilation caught ambiguous fault types in two fixture
reads; both use the existing OwnershipFault-specialized readStoredOrigin wrapper in the final builds.
Native demo stderr is expected negative-fixture output. Existing permission fixtures state their
Windows/root limitation and direct-Colima states unsupported without Apple Silicon/opt-in. No case
is newly skipped.

The final source audit at 2026-11-03T21:04:33.671604+00:00 to
2026-11-03T21:04:33.705523+00:00 measures 133/140 nonempty/physical changed production lines in three
modules, 223/231 changed test lines and 67/72 architecture-document lines. Complete reversals match the
captured baseline. Preservation at 2026-11-03T20:59:27.026373+00:00 confirms all 985 other Haskell files,
all 695 compiler fixtures and all 1,106 other prior snapshot subjects exact. The private protected
runtime floor and the complete row primitive/capability classifier region are byte-identical. Tape,
owners, object codec, Cabal packages/projects, Python/phase 1, demo and base/warm inputs are unchanged.
Final diff/LF checks pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T21:08:03.371293+00:00 to 2026-11-03T21:15:23.816468+00:00 | 440.446877 | 4205 cases pass, 394.91 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T21:08:03.370575+00:00 to 2026-11-03T21:18:51.375596+00:00 | 648.007526 | 167 cases pass, 2.00 reported seconds; 4205 cases pass, 357.03 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T21:08:03.390070+00:00 to 2026-11-03T21:08:04.498521+00:00 | 1.108434 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T21:08:03.407085+00:00 to 2026-11-03T21:08:12.084446+00:00 | 8.677367 | 376 pass, 7.01 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,116-file matched Windows/Linux tree. Dated aggregate digests:

- all990: 3c3aae25c7512a901c97dabc4ffd83e88adc581aa0c26e969a35a2eafef72700
- owned965: 882e1b39bae3aadc98ec13a8eb401ca590cdc50e06c5268db3b9c551f6eb9406
- docs95: 5a854f5a234e38e974d6b59f684e59cca932414b648afb20425cd8a72028e689

The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T21:19:51.461858+00:00 to 2026-11-03T21:19:59.762349+00:00,
8.300505 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.42: A whole-object row read closes its handle on every exit [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

A whole-object read owns its exclusive kernel handle until it closes it. Typed faults, synchronous
exceptions and asynchronous interruption all release that handle before the operation returns or
throws. The row transaction is shared once; owner-specific payload, identity and error policy stay
with each owner.

#### Deliverables

- Primitive supplies `readWholeObject` over one OwnershipRow and target, opening, reading and closing
  inside one exception-safe scope. No handle escapes and no origin authority is minted.
- Acquisition-to-cleanup transfer is masked, payload reading restores the caller's masking state, and
  every exceptional exit closes the actual handle before rethrowing the original exception.
- Preserve error priority: a typed read fault wins over a typed close fault; a successful read reports
  a failed close; an open fault reaches no read or close. Cleanup does not replace an existing thrown
  exception. Exact public exports include only the narrow byte-read operation.
- Real host-row cases prove successful bytes and closed handles, typed read/close fault priority,
  synchronous/asynchronous cleanup and open refusal. A retained actual handle is tested through the
  real primitive after exit; a counter is not the resource-lifetime evidence.

#### Validation

OwnershipSpec's "a successful whole-object read returns bytes and closes the actual handle" opens an
actual host-row file, checks masked acquisition/cleanup and restored caller read masking, returns the
exact payload, then performs an actual read on the retained same kernel handle and observes the closed
handle fault. File bytes remain intact. "typed read and close faults retain read-first priority and
close the actual handle" reads actual bytes and closes the actual handle before injecting its typed
controls; all read-only, close-only and combined failure scenarios retain the specified primary fault
and the real retained handle reports closed.

"a synchronous read exception retains its primary error even when cleanup throws" reads actual bytes,
throws the primary IOException, closes the actual handle and optionally throws a different cleanup
exception. The original exception survives and the real handle reports closed. "asynchronous
interruption restores the read mask and closes the actual handle" opens and reads in an actual worker,
blocks it, sends ThreadKilled through throwTo, joins its actual exceptional completion, and observes
the same handle closed. These are resource-lifetime observations, not close-attempt counters.

"an actual open refusal reaches no read or close" uses a real absent pathname and divergent later
fields. "a cleanup exception propagates after a successful actual read" verifies the actual bytes
before closing and throwing, retains the cleanup exception and observes the actual handle closed.
All six cases pass on Windows/NTFS and Linux/POSIX. They are unconditional host-row cases; existing
CoverageManifest families and declared counts remain unchanged.

The exact Primitive export pin admits the byte-only shared reader and no handle. The reported-face
guard includes its name and the per-name violating control rejects delegation to it. Current wall and
generated-config local readers remain explicit adoption work; shared-helper tests claim no unlanded
caller behavior.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T21:21:27.304732+00:00 to 2026-11-03T21:21:54.744193+00:00 | 27.439568 | PASS; parent 0 |
| Native demo main | 2026-11-03T21:21:27.403307+00:00 to 2026-11-03T21:21:54.458973+00:00 | 27.055769 | PASS; parent 0 |
| Native core test | 2026-11-03T21:25:05.289024+00:00 to 2026-11-03T21:25:25.782269+00:00 | 20.493324 | PASS; parent 0 |
| Native demo test | 2026-11-03T21:23:04.953356+00:00 to 2026-11-03T21:23:11.805310+00:00 | 6.851980 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T21:25:05.296482+00:00 to 2026-11-03T21:25:23.353990+00:00 | 18.057558 | PASS; parent 0 |
| Native scoped-read cases | 2026-11-03T21:26:40.295251+00:00 to 2026-11-03T21:26:40.560984+00:00 | 0.265707 | 6 cases pass; parent 0 |
| Linux scoped-read cases | 2026-11-03T21:26:39.910390+00:00 to 2026-11-03T21:26:40.481734+00:00 | 0.571324 | 6 cases pass; parent 0 |
| Native ownership/store/wall/public boundary selection | 2026-11-03T21:26:48.636368+00:00 to 2026-11-03T21:28:53.892588+00:00 | 125.256667 | 729 cases pass; parent 0 |
| Linux ownership/store/wall/public boundary selection | 2026-11-03T21:26:48.212463+00:00 to 2026-11-03T21:27:47.463974+00:00 | 59.251715 | 729 cases pass; parent 0 |
| Native complete demo | 2026-11-03T21:26:48.425185+00:00 to 2026-11-03T21:26:53.632532+00:00 | 5.207342 | 167 cases pass; parent 0 |

Both final 729-case selections include both platform rows, protected-store and live ownership cases,
every stored owner, harness, wall recovery/codec, computation-site and exact export guards, portability
and documentation, stored/index compiler fixtures and the public-reader control. Frozen source/compiler
checks pass, native main/test build stderr is empty and both native test binaries use rts_thr. The
final Linux build has empty stderr. Native demo stderr is expected negative-fixture output. Existing
permission fixtures state their Windows/root limitation and direct-Colima states unsupported without
Apple Silicon/opt-in. No case is newly skipped.

The final source audit at 2026-11-03T21:24:51.293685+00:00 to
2026-11-03T21:24:51.325361+00:00 measures 29/31 nonempty/physical added production lines in one module,
167/172 changed test lines and 30/35 architecture-document lines. Complete reversals match the captured
baseline. Preservation at 2026-11-03T21:23:15.268404+00:00 confirms all 987 other Haskell files, all 695
compiler fixtures and all 1,110 other snapshot subjects exact. Removing only the new reader block,
import and export reproduces Primitive byte-for-byte. All old clauses, runtime checks and primitive
fields remain exact. Rows, tape, owners, object/protected vocabulary, Cabal packages/projects, Python,
demo and base/warm inputs are unchanged. Final diff/LF checks pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T21:29:32.577320+00:00 to 2026-11-03T21:37:16.864729+00:00 | 464.289495 | 4211 cases pass, 411.11 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T21:29:32.577381+00:00 to 2026-11-03T21:37:27.250225+00:00 | 474.674986 | 167 cases pass, 2.69 reported seconds; 4211 cases pass, 389.83 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T21:29:32.618264+00:00 to 2026-11-03T21:29:33.624308+00:00 | 1.006014 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T21:29:32.630844+00:00 to 2026-11-03T21:29:40.781709+00:00 | 8.150856 | 376 pass, 6.84 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,116-file matched Windows/Linux tree. Dated aggregate digests:

- all990: 01b6cfeb27b846fafffd29aa1e8f6582ad5d411e5f78ea82fe4eb3a490e3efbf
- owned965: aee3d2a1a643e74002e597c60363a16336eb9688f5efea2c26f9c80c85528644
- docs95: 2852a9d29a872164e1c964fce0b31efe3b3ec2666df27b988774a973f900124e

The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T21:38:10.075604+00:00 to 2026-11-03T21:38:17.460885+00:00,
7.385298 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.43: The host wall consumes the scoped whole-object read [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Host.hs`,
`core/hostbootstrap-core/test/WslGlobalWallHostSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`,
`documents/architecture/ownership_seam.md`

#### Objective

The wall pairs stable identity and bytes using the shared scoped read, so interruption releases the
actual kernel handle and leaves its durable record retryable.

#### Deliverables

- Delete the wall's local open/read/close transaction and consume Primitive.readWholeObject with its
  existing fault mapping. Preserve the identity re-probe, byte ceiling and namespace/journal policy.
- Host-wall kernel cases interrupt an actual opened read, prove the handle is closed, preserve the
  active envelope/target and retry normally. Existing typed failure, busy and replacement cases stay.
- A source guard pins the delegation and excludes the duplicated local handle transaction.

#### Validation

WslGlobalWallHostSpec's "interrupted active-wall reads close their handle and remain retryable" drives
the real host-wall operation, store and host row on the worker that owns the entry. It covers both
active re-apply and restore, reads actual target bytes, blocks that opened read, delivers ThreadKilled
with throwTo and joins the exceptional completion. A retained actual read on the same handle then
returns the closed-handle probe fault. Target bytes/kernel identity, the exact active envelope and all
protected record envelopes remain unchanged.

The normal driver retries each interrupted operation and restores the original object's identity and
bytes, clears the active record and leaves no recovery names. No close-attempt counter or fake handle
stands in for kernel closure. CoverageManifest's ownership-refusal family declares 17 cases/16 row
cases; unsupported hosts retain the same case and assert their real row's refusal.

OwnershipSpec's "the host wall delegates its bytes to the shared scope" holds the actual observation
call's shared reader, row and fault mapping, rejects a wall-local readWholeObject definition and
rejects raw open/read/close selectors throughout the wall source. Both new cases pass on native
Windows/NTFS and Linux/POSIX. Existing identity-race, typed fault, busy, codec, namespace durability,
half-move, flush-retry and phase recovery cases remain in the complete selections.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T21:40:35.735682+00:00 to 2026-11-03T21:40:44.999093+00:00 | 9.263446 | PASS; parent 0 |
| Native demo main | 2026-11-03T21:40:35.747713+00:00 to 2026-11-03T21:40:46.953275+00:00 | 11.205624 | PASS; parent 0 |
| Native core test | 2026-11-03T21:41:09.407204+00:00 to 2026-11-03T21:41:26.145195+00:00 | 16.738074 | PASS; parent 0 |
| Native demo test | 2026-11-03T21:42:05.931567+00:00 to 2026-11-03T21:42:10.110342+00:00 | 4.178792 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T21:40:35.839284+00:00 to 2026-11-03T21:41:39.508499+00:00 | 63.669506 | PASS; parent 0 |
| Native wall adoption cases | 2026-11-03T21:42:15.881056+00:00 to 2026-11-03T21:42:16.373888+00:00 | 0.492815 | 2 cases pass; parent 0 |
| Linux wall adoption cases | 2026-11-03T21:42:15.629951+00:00 to 2026-11-03T21:42:16.210228+00:00 | 0.580261 | 2 cases pass; parent 0 |
| Native ownership/store/wall/public boundary selection | 2026-11-03T21:42:26.269078+00:00 to 2026-11-03T21:44:00.540189+00:00 | 94.271551 | 731 cases pass; parent 0 |
| Linux ownership/store/wall/public boundary selection | 2026-11-03T21:42:25.934734+00:00 to 2026-11-03T21:43:18.203488+00:00 | 52.268990 | 731 cases pass; parent 0 |
| Native complete demo | 2026-11-03T21:42:26.082009+00:00 to 2026-11-03T21:42:31.247268+00:00 | 5.165266 | 167 cases pass; parent 0 |

Both final 731-case selections include both platform rows, protected/live-entry and shared-read
cases, all stored owners, harness, wall recovery/codec, computation-site and exact export guards,
portability/documentation, stored/index compiler fixtures and the public-reader control. Frozen
source/compiler checks pass, native main/test build stderr is empty and both native test binaries use
rts_thr. Linux build stderr reports only the stale Hackage index notice. Native demo stderr is expected
negative-fixture output. Existing permission fixtures state their Windows/root limitation and
direct-Colima states unsupported without Apple Silicon/opt-in. No case is newly skipped.

The final source audit at 2026-11-03T21:40:07.243201+00:00 to
2026-11-03T21:40:07.317398+00:00 measures 25/26 nonempty/physical changed production lines in one
module, 99/101 changed test lines and 26/28 architecture/engineering lines. Complete reversals match
the captured baseline. Preservation at 2026-11-03T21:42:10.731651+00:00 confirms all 986 other Haskell
files, all 695 compiler fixtures and all 1,108 other prior snapshot subjects exact. Production differs
only by the shared call/imports and removal of the local handle transaction: identity confirmation,
16 MiB ceiling and every other wall function are exact. Only the named conditional coverage count
changes. The shared primitive, rows, tape, object/protected vocabulary, other owners, Cabal/Python/demo
and base/warm inputs are unchanged. Final diff/LF checks pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T21:46:22.198128+00:00 to 2026-11-03T21:53:20.563922+00:00 | 418.367827 | 4213 cases pass, 380.61 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T21:46:22.198048+00:00 to 2026-11-03T21:53:14.649039+00:00 | 412.452993 | 167 cases pass, 2.13 reported seconds; 4213 cases pass, 390.04 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T21:46:22.211636+00:00 to 2026-11-03T21:46:23.042371+00:00 | 0.830723 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T21:46:22.213003+00:00 to 2026-11-03T21:46:29.884031+00:00 | 7.671050 | 376 pass, 6.51 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,116-file matched Windows/Linux tree. Dated aggregate digests:

- all990: 11c9e3414cb3fb52b22654dad983e37c09540913137c5d2b6f7183c37019d15f
- owned965: 68db3b3750c508d695783cbb596552d3355fce6e84d5c0dc48bc6abdafda397d
- docs95: d2b58401a41311e92dcec81a3e2d42b16b50b786129d5ddae913b9d35281ce2f

The phase's own gate remains due at phase closure.

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T21:54:35.566948+00:00 to 2026-11-03T21:54:42.038233+00:00,
6.471300 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.

### Sprint 14.44: The generated config consumes the scoped whole-object read [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/GeneratedConfig.hs`,
`core/hostbootstrap-core/test/GeneratedConfigSpec.hs`,
`core/hostbootstrap-core/test/SourceGuard.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`,
`documents/architecture/harness_workflow.md`

#### Objective

Payload verification uses the shared scoped reader, so an interrupted generated-config release or
recovery cannot retain an exclusive file handle and block the next attempt.

#### Deliverables

- Delete readThroughRow and call Primitive.readWholeObject, preserving policy, payload digest checks,
  post-read identity observation, staging withdrawal and all existing domain faults.
- Actual generated-config release/recovery interruption cases prove a closed kernel handle, preserved
  target/record and successful retry. Both typed read and close faults keep their declared priority.
- A source guard holds the adoption and shared definition site. The architecture's scoped-read gap is
  removed only after both owner adoptions and their kernel evidence pass.

#### Validation

GeneratedConfigSpec's "interrupted release and recovery close their handle and preserve retryable
evidence" exercises both operations on the worker that owns a real protected entry. It starts from an
actual acquired and bound host-row file, reads its actual payload, delivers ThreadKilled through
throwTo and joins the exceptional completion. A retained actual read on that same handle then reports
the closed-handle fault. Payload bytes, kernel identity and the exact protected record/version remain
unchanged. A fresh live retry returns GeneratedConfigRemoved for release or GeneratedConfigAbsenceRestored
for recovery; target and record-derived staging are absent and the record is forgotten.

OwnershipSpec's "the generated config delegates payload bytes to the shared scope" holds the actual
payloadStillMatches call, absence of readThroughRow and absence of raw open/read/close selectors.
The four "each shared ownership computation has one definition site" cases include the real physical
census and a copied readWholeObject definition rejected by the same checker. Its declared home is
Primitive; comments/strings and neutral row declarations remain neutral. Both new caller cases and
all four computation-site cases pass on Windows/NTFS and Linux/POSIX. Generated-config cases remain
unconditional and all existing conditional families/counts remain unchanged.

| Complete build or selection, 2026-11-03/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| Native core main | 2026-11-03T21:57:50.006299+00:00 to 2026-11-03T21:57:59.595820+00:00 | 9.589566 | PASS; parent 0 |
| Native demo main | 2026-11-03T21:57:50.000193+00:00 to 2026-11-03T21:58:00.813653+00:00 | 10.813511 | PASS; parent 0 |
| Native core test | 2026-11-03T22:00:08.835163+00:00 to 2026-11-03T22:00:19.169027+00:00 | 10.333915 | PASS; parent 0 |
| Native demo test | 2026-11-03T21:59:15.624436+00:00 to 2026-11-03T21:59:20.285302+00:00 | 4.660886 | PASS; parent 0 |
| Linux complete build including tests | 2026-11-03T22:00:08.863535+00:00 to 2026-11-03T22:00:21.263381+00:00 | 12.399890 | PASS; parent 0 |
| Native config and census cases | 2026-11-03T22:01:28.413333+00:00 to 2026-11-03T22:01:34.560952+00:00 | 6.147628 | 6 cases pass; parent 0 |
| Linux config and census cases | 2026-11-03T22:01:28.203921+00:00 to 2026-11-03T22:01:34.576210+00:00 | 6.372300 | 6 cases pass; parent 0 |
| Native ownership/store/wall/public boundary selection | 2026-11-03T22:01:41.496856+00:00 to 2026-11-03T22:04:09.123637+00:00 | 147.627482 | 733 cases pass; parent 0 |
| Linux ownership/store/wall/public boundary selection | 2026-11-03T22:01:41.196859+00:00 to 2026-11-03T22:03:23.032751+00:00 | 101.836368 | 733 cases pass; parent 0 |
| Native complete demo | 2026-11-03T22:01:41.323431+00:00 to 2026-11-03T22:01:46.548327+00:00 | 5.224902 | 167 cases pass; parent 0 |

Both final 733-case selections include both platform rows, protected/live-entry, shared-reader and
both owner adoptions, all stored owners, harness, wall recovery/codec, computation-site and exact
export guards, portability/documentation, stored/index compiler fixtures and the public-reader control.
Frozen source/compiler checks pass; native main/test builds have empty stderr and both native test
binaries use rts_thr. The final Linux build also has empty stderr. Initial fixture compilation caught
the release result's GeneratedConfigRelease type; the worker branches erase their outputs only to
align types, while final retry asserts the exact GeneratedConfigRemoved constructor. Native demo
stderr is expected negative-fixture output. Existing permission fixtures state their Windows/root
limitation and direct-Colima states unsupported without Apple Silicon/opt-in. No case is newly skipped.

The final source audit at 2026-11-03T21:59:57.736615+00:00 to
2026-11-03T21:59:57.757739+00:00 measures 21/22 nonempty/physical changed production lines in one
module, 105/107 changed test lines and 26/29 architecture-document lines. Complete reversals match the
captured baseline. Preservation at 2026-11-03T21:59:20.954028+00:00 confirms all 986 other Haskell files,
all 695 compiler fixtures and all 1,108 other snapshot subjects exact. Production differs only by the
shared call/imports and removal of the local handle transaction: payload comparison, identity re-probe,
staging withdrawal and all remaining owner policy are exact. The checker adds only the narrow shared
definition home. The shared primitive, other owners, rows, tape, object/protected vocabulary, Cabal,
Python/demo and base/warm inputs are unchanged. Final diff/LF checks pass.

| Final host-static command, Linux x86_64/GHC 9.12.4/Cabal 3.16.1.0 | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all | 2026-11-03T22:04:46.610921+00:00 to 2026-11-03T22:14:46.475705+00:00 | 599.867704 | 4215 cases pass, 564.64 reported seconds; Cabal PASS, parent 0 |
| demo/: cabal test all | 2026-11-03T22:04:46.624813+00:00 to 2026-11-03T22:14:51.486835+00:00 | 604.864968 | 167 cases pass, 1.46 reported seconds; 4215 cases pass, 562.09 reported seconds; Cabal PASS, parent 0 |
| root/: poetry run python -m hostbootstrap.check_code | 2026-11-03T22:04:46.624560+00:00 to 2026-11-03T22:04:47.462096+00:00 | 0.837522 | Ruff/Black/mypy pass, parent 0 |
| root/: poetry run python -m hostbootstrap.test_all | 2026-11-03T22:04:46.641641+00:00 to 2026-11-03T22:04:53.812552+00:00 | 7.170930 | 376 pass, 6.12 reported seconds; 100% coverage, 1,585 statements/460 branches, zero missed/partial; parent 0 |

Both Haskell commands include --test-show-details=direct --test-options=--hide-successes.
All frozen-after checks pass over the 1,116-file matched Windows/Linux tree. Dated aggregate digests:

- all990: 8da093bd27b0c16cd7d989eb3df2af6d167df7293f346f4e276f54f39dd48ee3
- owned965: ea28ea3d00878a612ec31408d979f4b2a1d9f0bda9ae53be6778bab14b7fab00
- docs95: 006e87c8704f7b30f43d5fb10a421792acf07c0ee3f0aa3e2de4cc35f5ffd5e9

All four sprint-static commands pass. The sprint stays Active for the phase's own declared gate.

The phase's own declared core/ gate was re-run after all four sprint-static commands passed.
The unchanged 990-file Haskell tree is the same code those commands tested; the phase-gate snapshot
also includes their recorded plan evidence.

| Declared phase gate | UTC start to end | Wall seconds | Actual result |
|---|---|---:|---|
| core/: cabal test all --test-show-details=direct --test-options=--hide-successes | 2026-11-03T22:15:57.518794+00:00 to 2026-11-03T22:21:08.076156+00:00 | 310.558865 | 4,215 cases pass, 305.57 reported seconds; Cabal PASS, parent 0; frozen after exact |

Phase-gate matched-tree digests:

- all990: 8da093bd27b0c16cd7d989eb3df2af6d167df7293f346f4e276f54f39dd48ee3
- owned965: ea28ea3d00878a612ec31408d979f4b2a1d9f0bda9ae53be6778bab14b7fab00
- docs95: 201e6623de07fcecf243c204d7f9bc72a81cd1caf86487ba61557da343667a39

Closed-status native DocValidatorSpec passed all 17 cases at 2026-11-03T22:21:55.671251+00:00 to 2026-11-03T22:22:03.064653+00:00,
7.393421 wall seconds, exit 0/empty stderr, with closed status and frozen test/Cabal bytes unchanged.
The scoped plan/README diff check passes.

#### Remaining Work

None.


## Remaining Work

None.


## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/durable_state.md` — the surface this phase changes in it.
- `documents/architecture/harness_workflow.md` — generated-config read lifetime and retry.
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
