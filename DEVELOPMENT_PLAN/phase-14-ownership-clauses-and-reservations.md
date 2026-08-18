# Phase 14 — The four ownership clauses and host-local reservations

**Status**: Active
**Current sprint**: Sprint 14.5 — The owned-object vocabulary
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
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/Identity.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/Identity/Native.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

One realization of clause 3, shared by every host-local backend.

#### Deliverables

- `ObjectIdentity` has a private constructor and one hex journal codec, so an identity is always the kernel's
  answer rather than a caller's string.
- `Identity.Native` reads it from the kernel. Clause 3's identity read is a **row primitive**, so the
  platform rows are where it finally lives (Sprint 14.7); this sprint gives the directory and file
  protocols one realization to share in the meantime, and Sprint 14.10 moves them onto the rows.
- `IdentityFault` is closed, and each protocol maps it into its own vocabulary.
- Because directory and file ownership share this layer, their realizations of clause 3 cannot drift, and a
  substrate that cannot supply a stable identity refuses both at one place.

#### Validation

`DataRootSpec` and `GeneratedConfigSpec` exercise the shared layer through both protocols.

#### Remaining Work

None. Clause 3's final home is the platform row, which Sprint 14.7 declares and Sprint 14.10 adopts.

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
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Posix.hs`,
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
  frame table (§ LL). Sprint 14.7 declares that row and Sprint 14.10 has this driver reach it, so the two
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

### Sprint 14.5: The owned-object vocabulary [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Object.hs`,
`core/hostbootstrap-core/test/OwnershipObjectSpec.hs`
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

#### Validation

`OwnershipObjectSpec` covers the codec's round trip, its refusal of malformed and trailing input, the
identity constructor's bounds, and the total eliminator. Compile-fail fixtures cover the private
constructors and the record's un-updatable binding.

#### Remaining Work

All implementation, tests, fixtures, and documentation.

### Sprint 14.6: The clause tokens [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Clause.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ownership/Internal.hs`,
`core/hostbootstrap-core/test/compile-fail/`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/unrepresentable_state.md`

#### Objective

Make the clause order a property of the types, so it is not a prose invariant restated at every owner.

#### Deliverables

- Four abstract tokens — entered, recorded, bound, releasable — each indexed by the protected entry that
  authorized it and by the object it names, with nominal roles so neither index is coercible.
- The constructors live in one Cabal-private module whose sole importer is the seam, pinned by a source
  guard.
- Each token has a total eliminator and no producer outside the seam, so a caller holds one only by
  having reached the clause that mints it.
- The entry index is the protected session's own rank-2 variable rather than a second brand, so a token
  cannot outlive the entry that authorized it and the two facts cannot disagree.

#### Validation

Compile-fail fixtures reject constructing each token, coercing either index, letting a token escape its
entry, and importing the private module. Each fixture expects one contiguous diagnostic phrase, so an
unrelated error cannot report the boundary as held (§ HH).

#### Remaining Work

All implementation, fixtures, and documentation.

### Sprint 14.7: The ownership primitive seam [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Primitive.hs`,
`core/hostbootstrap-core/test/OwnershipSpec.hs`
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
- The seven clause producers demand their predecessor token, which is where the ordering theorem lives.
- Clause 1 is the protected store's exclusive entry and clause 2 its compare-and-swap; neither is a seam
  field, because a second durable record beside the store is a second source of truth. The seam's
  *exclusive open* is a different thing and is a field: it opens one named object exclusively and without
  following a link, inside an entry the store already holds.

#### Validation

`OwnershipSpec` applies the capability classifier to every combination and asserts that a row which cannot
hold a clause reaches no mutation and mints no token. Compile-fail fixtures cover mutation before the
origin record, release without the identity binding, forging a handle, and crossing a handle between rows.

#### Remaining Work

All implementation, tests, fixtures, and documentation.

### Sprint 14.8: The POSIX ownership row [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Posix.hs`,
`core/hostbootstrap-core/test/OwnershipPosixSpec.hs`
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
- Errno classification is symbolic, so the same name means the same thing on Linux and Apple hosts.
- The module compiles on every host family and answers a total refusal where it cannot apply, so no
  package-description stanza excludes it from a build (§ JJ).

#### Validation

The row is exercised against the **real kernel** in a temporary directory it created — not a stand-in —
so every case proves the syscall it names (§ NN). Clause 1's release-on-death is proved by a real process
actually dying, through the suite's own re-invocation route. On a host family where the row cannot apply,
the same cases assert its declared refusal rather than disappearing.

#### Remaining Work

All implementation, tests, and documentation.

### Sprint 14.9: The Windows ownership row [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ownership/Windows.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ownership/Row.hs`,
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
  captures it — with no C shim and no package-description `c-sources`.
- The reparse-point flag and the identity encoding exist once and are shared with the POSIX row's
  encoding, so a driver's volume-first comparison means the same thing on both.
- `ownershipRowForHost` selects the row for the running host. Two rows exist; a third would be a second
  implementation of a clause.

#### Validation

The row is exercised against the real kernel on a Windows gate host, and asserts its declared refusal on
the others. The identity encoding is compared against the POSIX row's over the same values, so the two
cannot drift into meaning different things.

#### Remaining Work

All implementation, tests, and documentation.

### Sprint 14.10: The host-local owners consume the seam [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Harness/DataRoot.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Harness/GeneratedConfig.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Host.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`,
`documents/architecture/durable_state.md`

#### Objective

The three host-local owners hold the clauses through the one seam.

#### Deliverables

- The data root, the generated config, and the host wall each reach the clauses through the seam's
  producers and the host's row.
- Each keeps the policy that is genuinely its own: the data root's self-created-parent rule, the generated
  config's found-object refusal before any record is written and its payload-conditional release, and the
  wall's phase graph and byte transformer.
- The wall's platform backends become the two rows, so its identity-conditional act exists once rather
  than once per platform.
- No owner reads a kernel identity through a seam of its own, so a host that cannot supply one refuses all
  three at one place.

#### Validation

Every case each owner's suite carries today is retained, including the crash windows on both sides of the
origin record and the conflict reports. Coverage that the removal of a patchable crash point does not
reach is **named as owed** in this sprint rather than counted as covered (§ NN).

#### Remaining Work

All adoption, tests, and documentation.

## Remaining Work

The clauses are stated and held, but held once per owned object rather than once. The identity read, the
no-replace publication, the identity-conditional act, and the durable record encoding each exist more than
once, and a third exclusive-entry realization sits beside the two platform ones — copies that agree on the
inputs each was written for and have never been asked the same question together.

Sprints 14.5 through 14.10 supply the single transaction, the seam beneath it, the two platform rows, and
the three host-local owners' adoption of them.

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
