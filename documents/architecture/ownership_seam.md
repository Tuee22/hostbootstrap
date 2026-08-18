# Ownership Seam

**Status**: Authoritative source
**Supersedes**: the per-substrate realization section of [ownership invariant](ownership_invariant.md)
**Referenced by**: [ownership invariant](ownership_invariant.md), [durable state](durable_state.md),
[build and run model](build_and_run_model.md), [readiness](readiness.md),
[unrepresentable state](unrepresentable_state.md), [WSL2](../engineering/wsl2.md),
[Incus](../engineering/incus.md), [cluster lifecycle](../engineering/cluster_lifecycle.md),
[documents index](../README.md)

> **Purpose**: Define how the four ownership clauses are realized — one transaction, one seam, and the
> closed set of platform rows beneath it — and which mechanism each row supplies.

## TL;DR

The four clauses [ownership invariant](ownership_invariant.md) states are **one transaction**: observe,
record the origin, mutate, bind the identity, release conditionally. It is written once, over one closed
seam of kernel primitives. What differs between platforms is the *primitive*, which is a row of the frame
table — never a clause written twice.

Three rows exist. Two are platforms: POSIX and Windows. The third is a **transport** that runs the
transaction at the frame owning the object, and it is not a third implementation, because every frame this
project reaches is Linux and what executes there is the POSIX row.

The clause order is a property of the types. A mutation consumes the recorded origin and a release
consumes the bound identity, so performing either out of order has no term rather than failing a review.

## Current Status

The clauses are held today, but held once per owned object rather than once. The harness data root, the
generated sibling config, and the global host wall each carry the transaction; the provider, cluster, and
Colima drivers carry it again as interpreter programs; and the identity read, the no-replace publication,
the identity-conditional act, and the durable record encoding each exist more than once.

The **vocabulary** below is built and is the one home for the identity, the intended payload, the origin
record, its canonical codec, and the closed fault sum. The harness identity seam reads its identity
through it, so a record one owner writes is already comparable with an identity another owner read.

The **clause tokens** and the **seam** are built with it. The four tokens are abstract, both of their
indices are nominal, and the entry index is the protected session's own rank-2 variable, so evidence
cannot move between entries or between objects and cannot outlive the entry that authorized it. The seam
is a record of primitives closed existentially over its handle type, with seven producers that each demand
their predecessor token; a row declares which clauses it can hold and the refusal it owes for one it
cannot is a total function of that declaration, applied before any kernel call. What is still owed is the
two kernels that fill the seam and the owners that consume it.

The seam, the clause tokens, and the two platform rows are the
[four-ownership-clauses-and-host-local-reservations phase](../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md)'s;
the shipped row and the provider drivers are the
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)'s;
the cluster and Colima drivers are the
[cluster-lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)'s;
and the guest alias driver is the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md)'s, because replacing it needs the
project binary established inside the guest first. Everything below describes the target contract; the
phase index carries what is built.

## The vocabulary

A transaction needs nouns, and they are stated once, without effects, in `HostBootstrap.Ownership.Object`:

- **`ObjectIdentity`** — the kernel's answer for an object, `device:inode` on POSIX and volume serial plus
  file index on Windows. The constructor is private and admits only a non-empty answer within a fixed
  ceiling, so an empty or fabricated value is never compared as though it were an identity.
- **`Payload` and `PayloadDigest`** — the exact bytes a run intends to publish at an owned file, and the
  digest a record carries in their place. Recording the intended payload before the file exists is what
  makes the crash window between the origin record and the identity binding resolvable.
- **`ObjectKind` and `Origin`** — what is owned, and what was there before. A directory has no payload and
  a file has one, so the digest is a field of the file's own case rather than an optional value beside
  both; and recorded absence is a distinct case from a recorded prior identity, because "an owner looked
  and found nothing" and "no owner has looked" license different recoveries.
- **`OriginRecord`** — the durable record clause 2 publishes. Its constructor is private, its one producer
  records only what was observed, and the identity binding is attached by its own producer, so a record
  cannot claim a binding it never made. A second, different binding is a conflict rather than an update.
- **One canonical record codec** — one line, six space-separated tokens, one terminator, and nothing else,
  so a record one owner writes is readable by every other and a version tag means one thing. Every
  malformed shape is a refusal rather than a partially understood record, because a record an owner
  half-reads is the one input that could make it delete something it does not own.
- **`OwnershipFault`** — the closed fault sum, with a total eliminator and a structured conflict report
  carrying both the expected and the observed side. Each case licenses a different act: a row that cannot
  hold a clause mints no receipt, a failed probe is not an absence, a malformed record is never guessed
  at, an occupied target is left alone, and a conflict is reported rather than resolved.

None of it performs IO or names a runner, so every property of the vocabulary is provable by application
rather than against a filesystem.

## The seam

The seam is a record of **primitives**, not of workflow: an identity read, an exclusive open, directory and
file creation, a no-replace publication, a read, a remove, a close, and a parent sync. It is closed
existentially over its handle type, so a handle minted by one row cannot enter another.

Three things it deliberately does not carry:

- **No command runner.** An external effect that must happen between the origin record and the identity
  binding — launching an instance, creating a cluster — travels as a described `HostCommand` through the
  one interpreter (see [build and run model](build_and_run_model.md)). The moment a seam can run a string,
  it is a shell again.
- **No raw platform status.** A row classifies its own faults into the closed fault sum, so the driver
  above it never comes to depend on one platform's error numbering.
- **No clause 1 or clause 2 field.** Exclusive entry is the protected store's own OS-released entry and the
  durable origin record is its compare-and-swap. A second durable record beside the store would be a second
  source of truth.

`OwnershipCapabilities` declares what a row can hold, and the refusal a row owes when it cannot is a total
function of that value — so `Unsupported` is decided by application rather than by a stand-in, which is
what [testing](../engineering/testing.md) means by evidence.

## The clause tokens

Each clause mints a token, and the producer of the next clause demands it:

| Token | Minted by | Discloses |
|---|---|---|
| `Entered session object` | observing the target inside the protected entry | the target, and what was there before |
| `Recorded session object` | publishing the unbound origin record durably | the target, and that record |
| `Bound session object` | attaching the created object's own identity and re-publishing | the target, the bound record, the identity |
| `Releasable session object` | re-observing the target and finding exactly that identity | the target, the record to forget, the identity |

Both indices are nominal. `session` is the protected entry's own rank-2 variable, so a token cannot
outlive the entry that authorized it and no second brand can disagree with it; `object` names which object
the evidence is about. The target the owner named rides on the token too, so no producer takes a path
argument and there is no call at which a matching token and a different path could be presented together.

The constructors live in one Cabal-private module whose only importers are the facade that re-exports the
abstract types and the seam that mints them. Compile-fail fixtures reject constructing each token,
coercing either index, carrying one out of its entry, and importing the private module.

## The rows

The clauses are uniform; the mechanism that supplies each is per-row. All frames this project reaches run
Linux, so the shipped row is one implementation reused, not a third.

| Clause | POSIX row | Windows row | Shipped row |
|---|---|---|---|
| 1 — exclusive entry | kernel lock on a retained descriptor, released by the OS on process death | `LockFileEx` byte-range lock | the receiving process holds the POSIX row's lock for exactly its own lifetime |
| 2 — durable origin record | write-temp, fsync, rename under the project state directory | same | the transaction carries the record it will write; the row writes it where the object lives |
| 3 — identity binding | `deviceID` / `fileID`, read without following a link | `getFileInformationByHandle` → volume serial plus file index | the POSIX row's read, performed by the kernel that owns the object |
| 4 — conditional release | re-observe, compare, act only on exact match | same | same |

Every mechanism uses a dependency or platform API already present. `Win32` ships with the pinned GHC, and
the Windows row supplements its public surface with a narrow direct `kernel32` boundary where exact status
preservation drives a recovery decision. `unix` supplies the POSIX row.

Both platform rows are **compiled on every host family** and answer a total refusal where they cannot
apply, so no package-description condition excludes either from a build. A module a condition removes is a
module nothing asserts, and the suite total reads the same either way — see
[testing](../engineering/testing.md).

## The shipped row

An object is owned by the kernel that can lock it, so a transaction addressed to a frame runs *in* that
frame. The row carries the transaction to a process of this same binary there and reads back one outcome.

Two properties make it a transport rather than a workflow:

- **One invocation per transaction.** The receiving process lives exactly as long as the lock it holds, so
  clause 1 stays a kernel fact rather than an application-level release that must be correct on every
  error path. A process that dies mid-transaction releases the lock because it died.
- **One crossing renderer.** The argument vector comes from the lift's own fold and from nowhere else, so
  the row adds no second answer to "cross into this frame". The sanitizing predicates the process route
  owns are applied as a check over that fold's output.

An empty frame stack addresses this machine, which is how a local transaction that must outlive its
launcher's own bracket is expressed — a supervised child whose group is killed when the owning process
disappears cannot be an ordinary bounded run, because the launcher's cleanup is exactly what a hard kill
skips.

## The no-replace publication

Publishing a file under a name that must not already exist uses the platform's atomic **no-replace link**:
`link(2)` on POSIX and `CreateHardLinkW` on Windows. A hard link publishes the written bytes under the
final name in one kernel operation and fails when the name is taken.

A *symbolic* link is not a substitute: it publishes a reference rather than the bytes, and a destination
that reads as a link is refused by the same inspector that enforces clause 3's "reparse points and symlinks
at the target are rejected rather than followed". `rename(2)` is not a substitute either, because it
replaces the destination.

## What each owner adds

The transaction is shared; the policy is the owner's own.

- **A host directory** — the harness data root — owns its own generation and never the shared parent. The
  parent is scaffolding: created if missing, never owned, never removed.
- **A host file** — the generated sibling config — adds the intended payload digest to its origin record,
  because a file's bytes are part of what "the object this run owns" means. That is what makes the crash
  window between the record and the identity binding resolvable. A found object is refused before any
  mutation rather than adopted: a generated config cannot share a path with a config already present.
- **The global host wall** keeps its phase graph and its pure byte transformer, so the file's content is
  derived rather than edited in place and a crash leaves either the prior body or the new one.
- **The provider-guest alias** keys its record by a digest of an injective owner binding — provider origin,
  share key and generation, alias key and generation, alias, and target — and stores the complete binding
  as well, so the digest is only a bounded filename. Its prepared state records explicit absence plus a
  fresh nonce before the first mutation, and a correct-looking foreign symlink with no matching durable
  record is reported foreign. No pathname sidecar participates in ownership.

## Validation

The seam is proved by three kinds of evidence, and by no others (see
[testing](../engineering/testing.md)):

1. **Pure functions applied to values.** Every classification, every record codec, every state transition,
   and every capability refusal is a total function, so it is tested by calling it. There is no stand-in,
   because the function under test is the function.
2. **Rows exercised against the real kernel**, in a temporary directory the case created. Clause 1's
   release-on-death is proved by a real process actually dying.
3. **Compile-fail fixtures** for the clause tokens, each expecting one contiguous diagnostic phrase, so an
   unrelated error cannot report a boundary as held. See
   [unrepresentable state](unrepresentable_state.md).

A case whose subject is unavailable on the gate host asserts the refusal its row declares rather than
disappearing. Validation status and scheduling belong to
[the development-plan index](../../DEVELOPMENT_PLAN/README.md); dated evidence lives with the sprint whose
gate produced it.

## Related

- [ownership invariant](ownership_invariant.md) — the four clauses and the exact guarantee they buy.
- [build and run model](build_and_run_model.md) — the described-command vocabulary an external effect
  travels on, and the frame table this seam is a column of.
- [lifecycle state model](lifecycle_state_model.md) — the handle/receipt/phase algebra a satisfying row
  settles into.
- [durable state](durable_state.md) — the durable records these rows write and read back.
- [testing](../engineering/testing.md) — what counts as evidence for a row, and what cannot.
- [development_plan_standards.md § EE and § LL](../../DEVELOPMENT_PLAN/development_plan_standards.md) — the
  normative statements.
