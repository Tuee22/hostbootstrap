# Phase 14 — The four ownership clauses and host-local reservations

**Status**: Done
**Current sprint**: None — every sprint is closed
**Depends on**: Phase 3 (host tools and the closed effect vocabulary), Phase 4 (protected store),
Phase 11 (prepared operations and preconditions)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`

> **Purpose**: Define the four Locked-Origin Identity Ownership clauses once, supply the one seam that
> holds them, and supply the platform rows beneath it.

## Phase Objective

Every resource this project mutates must be *owned*, meaning: exclusive entry the kernel releases, a durable
origin record published before the object exists, the created object's own identity bound to the receipt, and
release conditional on re-observing that identity. A backend that cannot hold a clause reports `Unsupported`
and mints no receipt, rather than minting a weaker one.

Those four clauses are **one transaction**, so this phase supplies one implementation of it and one closed
seam beneath. What differs between a POSIX host and a Windows host is the primitive each supplies — a row
of the frame table (§ LL) — and never a clause written twice. The order the clauses run in is a property
of the types: a mutation consumes the recorded origin and a release consumes the bound identity, so
performing either out of order has no term (§ HH).

The clause set, the seam, the two platform rows, and the host-local objects a run owns directly live here.
The row that ships a transaction to another frame, and the providers that consume it, belong to the
[host-providers-and-self-reference-lift phase](phase-15-host-providers-and-the-lift.md), because that phase
owns the frame table's rows and the one fold that reaches a frame.

## Sprints

### Sprint 14.1: The shared object-identity layer [Done]

**Status**: Done
**Implementation**: superseded within this phase — clause 3's identity read is
`core/hostbootstrap-core/src/HostBootstrap/Ownership/Object.hs`'s vocabulary and the two rows'
primitive, and Sprints 14.11 and 14.12 removed the shared layer this sprint built
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

One realization of clause 3, shared by every host-local backend.

#### Deliverables

- `ObjectIdentity` has a private constructor and one hex journal codec, so an identity is always the kernel's
  answer rather than a caller's string.
- `Identity.Native` reads it from the kernel. Clause 3's identity read is a **row primitive**, so the
  platform rows are where it finally lives (Sprint 14.7); this sprint gives the directory and file
  protocols one realization to share in the meantime, and Sprints 14.11 and 14.12 move them onto the rows.
- `IdentityFault` is closed, and each protocol maps it into its own vocabulary.
- Because directory and file ownership share this layer, their realizations of clause 3 cannot drift, and a
  substrate that cannot supply a stable identity refuses both at one place.

#### Validation

`DataRootSpec` and `GeneratedConfigSpec` exercise the shared layer through both protocols.

#### Remaining Work

None. Clause 3's final home is the platform row, which Sprint 14.7 declares and Sprints 14.11 and
14.12 adopt.

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

`DataRootSpec` covers each clause, adversary replacement reported as conflict without clobbering, release
refused on identity mismatch, exclusion while the lock is held, admission after the holder is killed, and a
kill between the origin record and the first write.

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
conflict report, and a kill between the origin record and publication.

#### Remaining Work

None.

### Sprint 14.4: The portable host-wall backend [Done]

**Status**: Done
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
- Ownership is a lease: settlement returns the lease inseparably with the live authority, so a caller cannot
  hold authority without the lease.
- Teardown restores the wall before any global shutdown, and there is no `.bak` sidecar — a second copy of the
  body is a second source of truth.
- No C shim and no `c-sources`: the clauses are met with dependencies already present.

#### Validation

`WslGlobalWallSpec`, `WslGlobalWallHostSpec`, and `WslGlobalWallConfigBytesSpec` cover the transformer, the
lease, crash recovery on both sides of the write, and the restore-before-shutdown order.

#### Remaining Work

None. The POSIX row is the baseline here; the Windows row is Sprint 14.9's, and its live confirmation is
listed by the acceptance phase that declares Windows hardware (§ II).

### Sprint 14.5: The owned-object vocabulary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Object.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Identity.hs`,
`core/hostbootstrap-core/test/OwnershipObjectSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/architecture/ownership_seam.md`

#### Objective

One IO-free vocabulary for what an owned object is, so every owner speaks the same nouns.

#### Deliverables

- `ObjectIdentity` is the kernel's answer with a private constructor and one hex journal codec, so an
  empty or caller-supplied value is not comparable as though it were an identity.
- `ObjectKind`, `Origin`, and `Payload` name what is owned, what was there before, and what this run
  intends to install. `Origin` distinguishes recorded absence from a recorded prior identity, because
  absence is a fact rather than an inference from a missing record.
- `OriginRecord` has a private constructor and one producer; the bound identity is attached by its own
  producer, so a record cannot claim a binding it never made.
- One canonical record codec replaces the per-object encodings, so a record written by one owner is
  readable by every other and a version tag means one thing.
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

#### Remaining Work

None. The vocabulary is nouns only; the tokens that order the clauses, the seam of primitives beneath
them, the platform rows, and the owners that consume all four are the sprints that follow.

### Sprint 14.6: The clause tokens [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ownership/Clause.hs`,
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
entry, and importing the private module. Each fixture expects one contiguous diagnostic phrase, so an
unrelated error cannot report the boundary as held (§ HH). Running cases pin the shape those fixtures
depend on: the private registration, the exact importer set, the four nominal role declarations, the
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
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

One seam of kernel primitives, and the producers that turn them into the four clauses.

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
  (§ NN).
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
the mirror case observes that a declared capability really is reached. Stated honestly: only the entry
producer is exercised that way, because reaching the later producers needs a token, a token needs a
successful entry, and a successful entry needs a kernel read. That the other producers consult the same
classifier before any primitive is a source guard here; their behaviour is proved against the real kernel
by the row that supplies one.

Dated 2026-08-18 validation evidence (x86_64-windows 11 Home 10.0.26200, GHC 9.12.4, Cabal 3.16.1.0):
`OwnershipSpec` passed 10/10 — five classifier cases over all sixteen capability combinations, two
kernel-reachability cases, and three seam-shape cases. The four fixtures
`MutateBeforeOwnershipRecord.hs`, `ReleaseWithoutOwnershipBinding.hs`, `EscapeOwnershipRowHandle.hs`, and
`CrossOwnershipRowHandle.hs` each fail with their exact declared diagnostic. Canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,001/2,001;
`poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

#### Remaining Work

None. The seam is primitives and producers; the kernels that fill it are the two rows, and the owners
that consume it are the last sprint of this phase.

### Sprint 14.8: The POSIX ownership row [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Posix.hs`,
`core/hostbootstrap-core/test/OwnershipPosixSpec.hs`,
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
  kernel releases when the holding process dies rather than a pathname a survivor must clean up.
- The identity is encoded volume word first and little-endian, which is the encoding every other
  ownership backend already writes, so two identities compared mean the same thing whichever row read
  them.
- Errno classification is symbolic, so the same name means the same thing on Linux and Apple hosts. A
  filesystem that cannot hard-link at all is `Unsupported` rather than a probe failure, because that is a
  clause this host cannot hold.
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
`poetry run python -m hostbootstrap.test_all` passed 231.

#### Remaining Work

None. The row is POSIX primitives; the Windows kernel that fills the same seam and the selector between
the two rows are the next sprint's, and the owners that consume both are the last sprint of this phase.

### Sprint 14.9: The Windows ownership row [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Windows.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ownership/Row.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ownership/Object.hs`,
`core/hostbootstrap-core/test/OwnershipWindowsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_seam.md`

#### Objective

The same primitives a Windows kernel supplies, and the one selector between the two rows.

#### Deliverables

- Byte-range exclusive **open of one object**, handle-based volume and file-index identity,
  reparse-point refusal, atomic no-replace publication, and write-through replacement. As on the POSIX
  row, this opens objects and does not supply clause 1.
- Where a public binding flattens the status a recovery decision needs, a narrow direct kernel boundary
  captures it — with no C shim and no package-description `c-sources`. Two entry points qualify: the open
  that must separate "the name is not there" from "the name is held", and the hard link that must
  separate a taken name from a filesystem that cannot link at all.
- The reparse-point flag and the identity encoding exist once and are shared with the POSIX row's
  encoding, so a driver's volume-first comparison means the same thing on both. The encoding is one
  producer in the owned-object vocabulary that both rows reach; neither row builds an identity of its
  own.
- There is no directory descriptor to flush on this kernel, so the parent's own durability is carried by
  a write-through creation and the link that publishes it. The row declares the capability because the
  guarantee is met; what differs is the mechanism, which is what a row is for.
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

Two things this sprint does not reach are named rather than counted (§ NN). A live refusal of a reparse
point standing at a target needs a Windows kernel and a link the suite may create there; what holds on
every gate host is the source guard that every observation opens with the no-follow flag and that the
non-regular predicate includes the reparse attribute. And the row's Windows-family compilation is
evidence the [host-portability acceptance phase](phase-28-host-portability-acceptance.md) produces, since
that is the phase declaring the hardware (§ C).

Dated 2026-08-18 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): `OwnershipWindowsSpec`
passed 23/23 — eleven cases asserting the row's declared refusal on this gate host, two declaration
cases, two encoding cases, two selector cases, and two source-shape cases. Canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,144/2,144;
`poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

#### Remaining Work

None. Both kernels fill the seam and one selector chooses between them; the three host-local owners'
adoption of that seam is the last sprint of this phase.

### Sprint 14.10: Re-entering an object this project already owns [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Primitive.hs`,
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
- The producer manufactures no evidence. A record with no identity binding describes a transaction that
  never got past clause 2 and licenses no release, so it is refused and mints no token; the record itself
  comes from the caller's own store, so the seam still holds no durable state of its own.
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

#### Remaining Work

None. The seam now reaches clause 4 from a durable record; the three owners that consume it are the
sprints that follow.

### Sprint 14.11: The data root consumes the seam [Done]

**Status**: Done
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
- No kernel identity is read through a seam of this module's own, so a host that cannot supply one
  refuses here at the same place it refuses everywhere else. The production bracket reaches the row
  through the one selector.

#### Validation

Every case `DataRootSpec` carries today is retained, including both crash windows around the origin
record, the adversary-replacement conflict, the release refusal on identity mismatch, exclusion while the
entry is held, and admission after the holder is killed.

Dated 2026-08-18 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): `DataRootSpec` passed
18/18 — five clause-2 cases, three clause-3 cases, five clause-4 cases, and five recovery cases, all
driving the production row against a real kernel. Canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,148/2,148 in 208.76 seconds;
`poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

#### Remaining Work

None. The generated config and the host wall are the two owners still holding their own copies.

### Sprint 14.12: The generated config consumes the seam [Done]

**Status**: Done
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
- No kernel identity is read through a seam of this module's own. The injected object-identity seam and
  its native backend are gone, and the production bracket now reaches one row for both owned objects.

#### Validation

Every case `GeneratedConfigSpec` carries today is retained, including the payload-conditional release,
the found-object refusal, the conflict report, and the kill between the origin record and publication.

Dated 2026-08-18 validation evidence (x86_64-linux, GHC 9.12.4, Cabal 3.16.1.0): `GeneratedConfigSpec`
passed 23/23 — six clause-2 cases, three clause-3 cases, the found-object refusal, seven clause-4 cases,
and six recovery cases, all driving the production row against a real kernel. Canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,151/2,151 in 220.36 seconds;
`poetry run python -m hostbootstrap.check_code` passed; and
`poetry run python -m hostbootstrap.test_all` passed 231.

#### Remaining Work

None. The host wall is the one owner still holding its own copy.

### Sprint 14.13: The host wall's backends become the two rows [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Host.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Windows.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ownership/Row.hs`,
`core/hostbootstrap-core/test/WslGlobalWallHostSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`,
`documents/architecture/ownership_seam.md`

#### Objective

The host wall's two platform backends become the two ownership rows, so its identity-conditional act
exists once rather than once per platform.

#### Deliverables

- The portable driver reaches the clauses through the seam's producers and the host's row, and keeps the
  policy that is genuinely its own: its phase graph, its pure byte transformer, and the lease that is
  returned inseparably with the live authority.
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

#### Validation

Every case `WslGlobalWallSpec`, `WslGlobalWallHostSpec`, `WslGlobalWallConfigBytesSpec`, and
`WslGlobalWallWindowsSpec` carry today is retained, including the transformer, the lease, crash recovery
on both sides of the write, and the restore-before-shutdown order.

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
row is the [host-portability acceptance phase](phase-28-host-portability-acceptance.md)'s, because that
claim needs a second machine and § C forbids a baseline phase owing hardware it does not declare.

#### Remaining Work

None. Every host-local owner holds its clauses through the one seam and against the one row.

## Remaining Work

None. The nouns are stated once, the clause order is a property of the types, one seam of primitives
mints the tokens by actually holding each clause, both kernels fill that seam, one selector chooses
between them, and one producer makes clause 4 reachable from the durable record. All three host-local
owners — the run's data root, its generated sibling config, and the per-user host wall — reach the
clauses through that seam and against that row, so the identity read, the no-replace publication, the
exclusive entry, the identity-conditional act, and the durable record encoding each exist once beneath
every one of them.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/ownership_invariant.md` — the four clauses, the exact guarantee, and the
  `Unsupported` rule.
- `documents/architecture/ownership_seam.md` — the seam, the two platform rows, and the clause tokens.
- `documents/architecture/unrepresentable_state.md` — the clause tokens and their compile-fail fixtures.

**Engineering docs to create/update:**
- `documents/engineering/wsl2.md` — the portable host-wall driver and its byte transformer.

**Cross-references to add:**
- `development_plan_standards.md` § EE and § DD name this phase as the owner of the clause set.
- [rationale.md](rationale.md) explains why the clauses are stated this way and why a bare exclusive create is
  not ownership.
