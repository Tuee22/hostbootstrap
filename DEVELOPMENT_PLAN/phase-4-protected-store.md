# Phase 4 — Protected store

**Status**: Done
**Depends on**: Phase 3 (host tools and substrate detection)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`

> **Purpose**: Provide the one durable, exclusively entered, versioned record store every later ownership,
> authority, and lifecycle decision is made inside.

## Phase Objective

Everything above this phase needs to make a decision that survives a crash and cannot be raced: take a
mode, bind a lease, publish an origin record. That needs a store with three properties — exclusive entry
released by the kernel when a process dies, records with versions so a decision can compare-and-swap, and
durability. This phase is that store and nothing else; it knows nothing about what is recorded in it.

## Sprints

### Sprint 4.1: Exclusive entry and versioned records [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

One exclusive entry, one versioned record type, one compare-and-swap.

#### Deliverables

- `openProtectedStore` yields an opaque `ProtectedStore` rooted under the canonical project root.
- `withProtectedEntry` runs a continuation inside the store's exclusive entry, which the **kernel** releases
  if the process dies part-way through — a lock a dead process still holds is not a lock.
- A `ProtectedSession` exists only inside that continuation and is the sole capability for reading or
  writing records, so no record operation can straddle two transactions.
- `RecordKey` is validated on construction, so a key cannot shift the meaning of the fields after it.
- `mkRecordName` is the one **injective** encoding from a namespaced identity — or a `/`-separated path of
  them, which is what a relation between operations is — into that alphabet. A key is a filesystem name, so
  neither `:` nor `/` can reach one; encoding rather than sanitizing is what keeps two distinct identities
  from sharing one durable record. `recordNameIdentity` is its total inverse on the image.
- `readProtectedRecord`, `compareAndSwapProtectedRecord`, and `compareAndDeleteProtectedRecord` take an
  `Expectation` (`ExpectAbsent` or `ExpectVersion`), so every write states what it believed.
- `listProtectedRecords` enumerates at one store version, so a fold sees a consistent set.
- A malformed record is a typed failure, never silently ignored.

#### Validation

`AuthoritySpec`'s store cases cover the entry, each expectation branch, the malformed-record refusal, and
an out-of-process contention probe that proves a second entry is excluded while the first is held.

#### Remaining Work

None.

### Sprint 4.2: The run-liveness lock [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Make "the owner of this record is still alive" an observable fact.

#### Deliverables

- `withRunLiveness` takes a project-wide lock and holds it for the caller's whole run, not just one
  transaction.
- The lock is kernel-released, so a genuinely dead predecessor never blocks a successor.
- Every protected-store and run-liveness lock handle is non-inheritable across an executed child. A provider
  daemon may outlive its launcher, but cannot retain the launcher's project-liveness or store-entry lock.
- This is the primitive that makes an abandoned-record sweep sound. Without it a live owner's record is
  indistinguishable from a dead one's, and a starting run can take a project another run still owns — see
  [rationale.md](rationale.md).
- A live holder refuses the peer *before* the peer acquires anything.

#### Validation

`AuthoritySpec` covers the held/released branches, an out-of-process probe of the live refusal, and a real
executed child that remains alive after its parent leaves the liveness extent while immediate reacquisition
succeeds. The complete core host-static gate must pass.

#### Remaining Work

None. Completed 2026-08-26 on aarch64 macOS: the real executed-child regression passed in the 113-case
`AuthoritySpec` group, and the complete core host-static gate passed 2,462/2,462 under `-Werror` in 433.14
seconds. The child remained alive while the parent immediately reacquired the same liveness lock.

### Sprint 4.3: Store identity binding [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Protected.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/ownership_invariant.md`

#### Objective

Bind a store to the project that owns it.

#### Deliverables

- `protectedStoreIdentityText` and `sessionStoreIdentity` expose the store's own identity.
- A store records which project it belongs to on first authorized use, and a different project is refused
  rather than sharing it.
- An authorization issued against one store cannot be presented to another.

#### Validation

`AuthoritySpec` covers the binding, the cross-project refusal, and the cross-store refusal.

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
