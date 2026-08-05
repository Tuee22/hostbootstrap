# Phase 14 — The four ownership clauses and host-local reservations

**Status**: Done
**Depends on**: Phase 4 (protected store), Phase 11 (prepared operations and preconditions)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`

> **Purpose**: Define the four Locked-Origin Identity Ownership clauses once, and supply the host-local
> backends that hold all four.

## Phase Objective

Every resource this project mutates must be *owned*, meaning: exclusive entry the kernel releases, a durable
origin record published before the object exists, the created object's own identity bound to the receipt, and
release conditional on re-observing that identity. A backend that cannot hold a clause reports `Unsupported`
and mints no receipt, rather than minting a weaker one.

The clause set and its shared identity layer live here, together with the two host-local objects a run owns
directly. Provider-guest backends are built by the phase that owns the provider.

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
- `ObjectIdentityBackend` is the injected seam; `Identity.Native` is the host realization.
- `IdentityFault` is closed, and each protocol maps it into its own vocabulary.
- Because directory and file ownership share this layer, their realizations of clause 3 cannot drift, and a
  substrate that cannot supply a stable identity refuses both at one place.

#### Validation

`DataRootSpec` and `GeneratedConfigSpec` exercise the shared layer through both protocols.

#### Remaining Work

None.

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

- One portable driver with a platform backend seam; the POSIX realization is the baseline.
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

None. The Windows backend and its live confirmation belong to the Windows substrate phase.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/ownership_invariant.md` — the four clauses, the shared identity layer, and the
  `Unsupported` rule.

**Engineering docs to create/update:**
- `documents/engineering/wsl2.md` — the portable host-wall driver and its byte transformer.

**Cross-references to add:**
- `development_plan_standards.md` § EE and § DD name this phase as the owner of the clause set.
- [rationale.md](rationale.md) explains why the clauses are stated this way and why a bare exclusive create is
  not ownership.
