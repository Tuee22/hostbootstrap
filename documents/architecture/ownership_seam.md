# Ownership Seam

**Status**: Authoritative source
**Supersedes**: the per-substrate realization section of [ownership invariant](ownership_invariant.md)
**Referenced by**: [ownership invariant](ownership_invariant.md), [durable state](durable_state.md),
[build and run model](build_and_run_model.md), [readiness](readiness.md),
[lifecycle state model](lifecycle_state_model.md), [harness workflow](harness_workflow.md),
[WSL2](../engineering/wsl2.md), [Incus](../engineering/incus.md), [Lima](../engineering/lima.md),
[documents index](../README.md)

> **Purpose**: Define how the four ownership clauses are realized — one transaction, one seam, and the
> closed set of platform rows beneath it — and which mechanism each row supplies.

## TL;DR

The four clauses [ownership invariant](ownership_invariant.md) states are **one transaction**: observe,
record the origin, mutate, bind the identity, release conditionally. It is written once, over one closed
seam of kernel primitives. What differs between platforms is the *primitive*, which is a row of the
[frame table (§ LL)](../../DEVELOPMENT_PLAN/development_plan_standards.md#ll-the-frame-table-the-substrate-axis-is-a-lift-not-a-fork)
— never a clause written twice.

This page uses **frame** in the frame-table sense of [the glossary](../README.md#glossary), not the
default topology sense: the machine a `LiftContext` addresses, whose kernel answers for the objects there. A **crossing** is a lift from one such
frame into another through the authenticated handoff. The frame table's ownership column names the row
that holds a frame's clauses; it is a declaration rather than a value a caller runs.

- **Two platform rows**, POSIX and Windows. `ownershipRowForHost` selects the one this binary was built
  for, as a build fact rather than a runtime probe.
- **The shipped row** is a transport, not a third implementation of the clauses: it runs the
  transaction in a process of this same binary at the frame owning the object, and that process uses its
  own `ownershipRowForHost`. Every frame reached through a crossing is Linux, so across a crossing that is
  the POSIX row; an empty `LiftContext` addresses this machine and runs this host's row.
- **Per-kernel spellings.** Every binary is built host-native
  ([§ N](../../DEVELOPMENT_PLAN/development_plan_standards.md#n-host-native-binary-build)), so the POSIX
  row is compiled for a Darwin outer host as well as for Linux, and a primitive may be spelled differently
  per kernel. What must never be written twice is the clause order.

The types fix the order of the calls: a mutation consumes the recorded origin and a release consumes the
bound identity, so performing either out of order has no term rather than failing a review. They do not
fix the values passed through them: the identity clause 3 binds, the origin the reported face enters
with, and the record re-entry starts from are all caller-supplied ([the clause tokens](#the-clause-tokens)).

## Current Status

Host-local owners use the shared ownership primitives for kernel identity, exclusion, origin publication,
no-replace linking, and identity-conditional release. The POSIX row opens objects through descriptors
with no-follow flags, removes by name after an `lstat`, and classifies errno by symbolic constant. The
Windows row uses no-follow handles, `LockFileEx`, full FILE_ID_INFO identity and write-through file
creation; parent sync opens and flushes the parent directory. Native kernel cases exercise the wider
identity and both parent-flush points; the owning phase records dated evidence. `ownershipRowForHost`
selects the native row as a build fact.

POSIX lock contention is classified only at the lock request: EACCES, EAGAIN and EBUSY there
mean an occupied object; permission failures from opening, creating or observing are probe failures.
A link across mounts or beyond the link-count limit is a situational probe failure, while a filesystem
that supplies no hard link is unsupported. Acquired descriptors are masked through transfer and
closed on an escaping exception, including before an exclusive handle is returned.

Which backend holds which clause, and how, is the
[per-backend clause matrix](ownership_invariant.md#per-backend-clause-matrix). A missing primitive is an
explicit unsupported result, never a weaker ownership receipt.

Clause tokens have nominal object and entry indices. The protected entry's rank-2 identity prevents direct evidence
values from moving between entries; its operational lifetime is addressed below. Shipped requests are canonical bounded data; the
receiving binary performs the transaction using its own host row.

Typed ownership effects enforce the protected entry's existing live-token and owner-thread floor.
The hidden tokens carry their actual session through every successor; strict re-entry and every
effectful clause path refuse retained closures after entry exit or on a foreign thread. Public
evidence eliminators and nominal indices keep their existing signatures.

Both whole-object owners consume the shared exception-safe handle scope. The wall and generated-config
kernel cases interrupt actual reads, observe the retained handles closed, preserve exact ownership
evidence and targets, and retry through their production operations.

The shared read and its caller adoptions belong to the
[ownership clauses and reservations phase](../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md),
which owns the primitive seam. The [providers and lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
owns provider realization and transport, the [cluster lifecycle phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)
owns cluster and Colima adapters, and the [worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md)
owns their concrete consumers. Their dated gates distinguish native kernel checks from live provider acceptance.

## The vocabulary

A transaction needs nouns, and they are stated once, without effects, in `HostBootstrap.Ownership.Object`:

- **`ObjectIdentity`** — the owning authority's answer for an object: `device:inode` on POSIX and volume
  serial plus file index on Windows, both encoded by `mkKernelObjectIdentity`, or the identity a provider
  or container runtime reports. The raw constructor is private; the smart constructors admit only a
  non-empty value within a fixed ceiling, so an empty or over-long value is never compared as an identity.
  They check shape, not provenance: a well-shaped value read from a record parses as an identity.
- **`Payload` and `PayloadDigest`** — the exact bytes a run intends to publish at an owned file, and the
  digest a record carries in their place. Recording the intended payload before the file exists is what
  makes the crash window between the origin record and the identity binding resolvable.
- **`OwnerClaim`** — the tag a run stamps on an object whose identity another authority answers for. A
  directory or a file is created by the very act that gives it its kernel identity; a provider instance is
  created by a described command whose answer can be lost, so without a tag a run that crashed in that
  window could not tell its own half-made instance from one a previous record left behind. The claim is
  minted before the creating command, carried *by* that command so the object names it from the moment it
  exists, and written into the durable record.
- **`ObjectKind` and `Origin`** — what is owned, and what was there before. A directory has no payload and
  a file has one, so the digest is a field of the file's own case rather than an optional value beside
  both; the third case (`ReportedObject`) is an object no row primitive creates — one another authority
  answers for, or the alias's symbolic link — and it carries an owner claim for the same structural
  reason. Recorded absence is a distinct case from a recorded prior identity, because "an owner looked and
  found nothing" and "no owner has looked" license different recoveries.
- **`OriginRecord`** — the durable record clause 2 publishes. Its constructor is private, `originRecord`
  builds an unbound record from a kind and an origin, and `bindOriginRecord` attaches the binding: binding
  a second, different identity to an in-memory record is a conflict rather than an update. A record parsed
  from bytes by `parseOriginRecord` may already carry a binding, so the binding a record holds is evidence
  only when the record came from the owner's own protected store.
- **One canonical record codec** — rendering writes one line of six single-space-separated tokens and one
  newline, so a record one owner writes is readable by every other and a version tag means one thing.
  Reading requires ASCII, exactly one newline-terminated line, the magic, the version, six tokens, and
  well-formed hex in each identity, digest, or claim field,then exact byte equality with its re-rendering.
  Tabs, repeated or surrounding spaces, and a carriage return before LF are refused. Every
  shape outside that is a refusal rather than a partially understood record, because a record an owner
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
  source of truth. The seam's exclusive open is a different thing and is a field: it opens one
  already-existing named object, without following a link, inside an entry the store already holds. It is
  not clause 1. On the POSIX row it is an `fcntl` write lock over the whole file, which belongs to the
  (process, inode) pair rather than to the descriptor: it excludes other processes only, and closing any
  descriptor the process holds on that inode drops it. On the Windows row it is a `LockFileEx` byte-range
  lock, which conflicts between handles even inside one process.

`OwnershipCapabilities` declares what a row can hold, and `clauseRefusal` turns that declaration into the
refusal a row owes, before any kernel call — so `OwnershipUnsupported` is decided by application rather
than by a stand-in, which is what [testing](../engineering/testing.md) means by evidence.

| Clause | Capabilities `clauseRefusal` requires |
|---|---|
| 1 — entering (`enterOwnedObject`) | `holdsStableIdentity` |
| 2 — recording (`recordOwnedOrigin`) | `holdsStableIdentity`, `holdsDurableParentSync` |
| 3 — binding (`bindOwnedIdentity`) | `holdsStableIdentity`, `holdsNoReplacePublication` |
| 4 — releasing (`reenterStoredOwnedObject`, `reobserveOwnedIdentity`) | `holdsStableIdentity` |

Mutating producers check the declaration of the row supplied to that call before any primitive.
Directory creation applies ClauseRecord for its parent sync; file publication applies ClauseRecord
and ClauseBind for parent sync and no-replace linking;object removal applies ClauseRecord before
removal and parent sync. A token from an earlier row does not waive the current row's requirements.
Re-entry and re-observation apply ClauseRelease to the identity comparison that precedes release.
Partial-capability refusals mint no later token and invoke no publication or forget continuation.

The shared kernel identity encoder takes a 64-bit volume word and raw object bytes. The volume
comes first in little-endian order; the object is eight bytes on POSIX and the full sixteen-byte
Windows file identifier. POSIX identities keep sixteen total bytes; Windows identities carry
twenty-four. The producer validates these widths; the generic identity constructor keeps its
broader bounded shape-only contract.

### Module map

| Module | Holds | Visibility |
|---|---|---|
| [`HostBootstrap.Ownership.Object`](../../core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Object.hs) | the vocabulary above | public re-export |
| [`HostBootstrap.Ownership.Primitive`](../../core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Primitive.hs) | the seam record, `OwnershipCapabilities`, `clauseRefusal`, and every clause producer | public re-export |
| [`HostBootstrap.Ownership.Clause`](../../core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Clause.hs) | the abstract clause tokens and their eliminators | public re-export |
| [`HostBootstrap.Ownership.Internal`](../../core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Internal.hs) | the token constructors | Cabal-private |
| [`HostBootstrap.Ownership.Posix`](../../core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Posix.hs), [`HostBootstrap.Ownership.Windows`](../../core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Windows.hs) | the two platform rows | public re-export |
| [`HostBootstrap.Ownership.Row`](../../core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Row.hs) | `ownershipRowForHost`, the one production row selector | public re-export |
| [`HostBootstrap.Ownership.Tape`](../../core/hostbootstrap-core/internal/ownership/HostBootstrap/Ownership/Tape.hs) | the record tape and `OwnershipCarrier` | Cabal-private library |
| [`HostBootstrap.Protected`](../../core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs) | the protected store: clause 1's entry and clause 2's compare-and-swap | public re-export |
| [`HostBootstrap.Ownership.Shipped`](../../core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs) | the shipped row and the symbolic-link acts | public |

The clause producers come in two faces ([the two faces](#the-two-faces)):

| Clause | Kernel face | Reported face |
|---|---|---|
| 1 | `enterOwnedObject` | `enterReportedObject` |
| 2 | `recordOwnedOrigin` | `recordReportedOrigin` |
| creation | `createOwnedDirectory`, `publishOwnedFile` | a described command, outside the seam |
| 3 | `bindOwnedIdentity` | `bindReportedIdentity` |
| re-entry | `reenterStoredOwnedObject` | — |
| 4 | `reobserveOwnedIdentity`, `releaseOwnedObject` | `reobserveReportedIdentity`, `releaseReportedObject` |

`recordReportedOrigin` takes an owner claim and records only a `ReportedObject` for that claim.

`releaseOwnedObject` refuses a `ReportedObject` record before any kernel removal or record forgetting.
Reported symbolic links are released through `releaseReportedObject`.

The shipped symbolic-link interpreter obtains identity through the selected native row. It reads
the identity before classifying kind and link target, then confirms the same identity afterward;
a changed or vanished object is refused. It carries no separate device/inode encoding. An initial
authoritative absence remains an absence, and a failed row probe remains a fault.

## The clause tokens

Each clause mints a token, and the producer of the next clause demands it:

| Token | Minted by | Discloses |
|---|---|---|
| `Entered session object` | observing the target inside the protected entry | the target, and what was there before |
| `Recorded session object` | publishing the unbound origin record durably | the target, and that record |
| `Bound session object` | attaching the identity the caller passes — by contract the created object's own — and re-publishing | the target, the bound record, the identity |
| `Releasable session object` | re-observing the target and finding exactly that identity | the target, the record to forget, the identity |

The four clauses are one transaction but not one process, so `Bound` has a second producer: **re-entry**.
An owner binds an identity now and releases it later — after its own bracket, after a restart, or from a
successor's recovery path — and clause 4 has to be reachable from the durable record rather than only
from the token the binding minted. Re-entry takes an exclusive entry, a target, and the bound record the
caller read back through its own store, and mints the same token; a record with no identity binding
describes a transaction that never got past clause 2, so it authorizes no removal and mints nothing. The
object index is introduced fresh, exactly as clause 1 introduces it. Direct values cannot cross entries,
and an effect using a retained IO closure must still pass the actual entry's live owner-thread check.

Re-entry requires the protected tape's abstract stored-read wrapper from this same nominal entry.
An in-memory or parsed origin record has no route to either producer. Both faces share the bound-record
projection; a missing binding mints no token. The kernel face checks release capability first, and the
reported face refuses a kernel kind without taking a row or publishing a record.

The tokens order the calls; they do not certify the values. `bindOwnedIdentity` and
`bindReportedIdentity` take the identity as a parameter, `enterReportedObject` takes the observed origin
as a parameter, and the strict re-entry producers take protected stored-read evidence as a parameter. An owner therefore passes the
identity its creating primitive returned or its classified command outcome, and re-enters only from a
record its own store returned. Refusing a found object is likewise the owner's policy: the kernel
creation primitives refuse a target that already exists, and the
[per-backend clause matrix](ownership_invariant.md#per-backend-clause-matrix) states what each owner does
with one.

Both indices are nominal. `session` is the protected entry's own rank-2 variable, so a token value cannot
escape its entry's type scope and no second brand can disagree with it; `object` names which object
the evidence is about. The target the owner named rides on the token too, so no producer takes a path
argument and there is no call at which a matching token and a different path could be presented together.

The constructors live in one Cabal-private module whose only importers are the facade that re-exports the
abstract types and the seam that mints them. Compile-fail fixtures reject constructing each token,
coercing either index, carrying one out of its entry, and importing the private module.

## Stored read evidence

The tape provides abstract `StoredOriginRecord session`, with a nominal entry index.
`readStoredRecordUnder` is its sole mint and retains the origin body and exact protected version from
the existing versioned decoder. Its projections permit inspection; there is no constructor or producer
from a caller's bytes. The abstract type is also named by the public ownership facade. The main library re-exports the tape,
so a downstream owner can read evidence under its own protected entry before strict re-entry; the
constructor remains private.
The projections are ordinary functions, so record-update syntax cannot change either the body or
version of a sealed read.

`reenterStoredOwnedObject` and `reenterStoredReportedObject` accept only this evidence from the
same entry. They share the existing bound-record projection and preserve capability, unbound and
reported-kind refusals. The reported route takes no row. These are the only re-entry producers.
A guard walks physical production files and checks the exact export surface; violating module text
demonstrates that an unconstrained producer definition or call is rejected.

The data root and generated config consume the stored wrapper directly during release and
retained-origin recovery. They project policy and payload data while keeping that same wrapper until
strict re-entry. Unbound recovery, late identity/payload refusals and staging cleanup are retained.
The shipped owner's ordinary file/directory give-back also consumes the wrapper read under its own
tape. Its acquisition and symbolic-link inspection paths retain their decoded reads and wire policy.
The provider's instance-claim re-entry also consumes its stored wrapper after checking the exact
reported kind, owner claim, absent origin and bound identity. It republishes nothing and preserves a
refused record's bytes/version. Cluster node-claim re-entry now consumes its own stored wrapper through the same exact kind, claim,
absent-origin and identity checks, without republishing or rebinding. Colima also re-enters its stored profile/disk and directory records, preserving captured versions
across destructive commands. Namespace children are cleared only inside the stored parent-directory
re-entry: the parent's identity is re-observed, the admitted child's exact identity is checked through
the shared conditional act, and the changed parent is synced. A manifest supplies observations, never
a fabricated child origin record or a synthetic store publication. All six owners now use the strict
producers, and neither unconstrained entrypoint exists.

## The record tape

Every owner behind the seam shares publication, binding, forget and read-back through one tape.
The tape also supplies a raw protected-envelope read for acquisition checks that need presence,
without interpreting an origin body. These operations are the tape,
and they live once, in `HostBootstrap.Ownership.Tape`, over one session, one key, and one
`RecordSubject`. The subject is a pair of phrases — what this owner calls its record, and what it
calls the act of binding an identity to it — so the refusals every owner emits read in its own
vocabulary while the code that emits them is shared.

The tape's operations are the ones the transaction actually needs and no more:

| Operation | What it settles |
|---|---|
| `publishFreshRecord` | clause 2's first write, idempotent when the record already there is this transaction's own |
| `publishBoundRecord` | clause 3's binding over the exact unbound form; identical bound bytes retain their version |
| `forgetRecordAtVersion` | deletion only against a retained version; absence or a changed version is a refusal |
| `forgetRecord` | clause 4's settlement, where an already-absent record is the state asked for rather than a refusal |
| `readRawRecordUnder` | the protected envelope without interpreting its body, with the owner's store-error variant |
| `readVersionedRecordUnder` | the decoded origin and protected version from the same envelope read |
| `readRecordUnder` | the decoded record, with malformed envelope/body state distinguished from other store failures |

Fresh publication is idempotent only over byte-identical records. A stored record with the same
kind and origin but an existing binding belongs to another transaction and remains intact.
Bound publication swaps only over its exact unbound form; identical bound bytes are a no-op
that preserves the store version. Every other well-formed record is refused as OwnershipOccupied,
using the subject-specific message rather than an unused key argument.

An uninterpretable store envelope or origin body is OwnershipMalformed. Fresh publication, bound
publication, read-back and forget all preserve that state for diagnosis; forget does not erase an
invalid origin body. Other store failures remain OwnershipProbeFailed with their attempted operation.
Decoded read-back lifts store failures through the owner's fromStoreFault; publish and forget
classify those failures with storeFault before their OwnershipFault result reaches the carrier.

The two error layers collapse through one class rather than ten hand-written lifts.
`OwnershipCarrier` has exactly two methods — `fromClauseFault` and `fromStoreFault`, each into the
owner's own closed error sum. `carryClause` collapses a clause producer's refusal and the domain result
nested inside it; `carryClauseFault` carries a bare clause result (`OwnershipFault`) into the domain sum.
All carrier callers use that name; no forwarding spelling remains. The harness owners use
`readRawRecordUnder` for their acquisition presence check and decoded read-back for recovery.
Their forget continuations return the tape's OwnershipFault directly, without converting a domain
error back into a probe failure.
A store fault (`ProtectedError`) is lifted by `fromStoreFault` in the raw reader.
`readVersionedRecordUnder` performs the shared origin decode through `fromClauseFault`;
`readRecordUnder` projects only the decoded body from that same result.
Colima reads every reported and directory origin through its matching tape subject. Cleanup retains
the original protected version across the destructive command and calls `forgetRecordAtVersion`,
so a later write is refused rather than deleted as current state. Both forget routes share origin
validation and one conditional-delete site; ordinary forget accepts settled absence, while an
explicit retained version requires that version still to exist. Colima's separate stage/manifest
multi-record protocol keeps its raw store operations.

An owner therefore declares its instance and its subject, and keeps only what is genuinely its own:
its removal-set policy, its payload rules, and its create-then-bind path.

Reported re-entry uses `reenterStoredReportedObject` over a held protected entry and its sealed
stored read. It projects the exact target, record and identity without a row or publication.
Unbound records are malformed; kernel records are unsupported. Kernel re-entry keeps its capability
check and shares only the bound projection. The input type proves the tape read under this nominal
entry; the caller still validates the exact claim and subject. Provider, cluster and Colima reported
callers use this route. The tape refuses any different stored record on fresh publication,
including a record that already carries a binding.

Kernel re-observation and `withReobservedIdentity` share one exact identity comparison. The
conditional act checks the release capability before observing, refuses absence or replacement,
and passes the same row's primitives to the act only on a match. The host wall's delete and move
use it, preserving their specific absent/replaced conflicts and existing action errors. Observation
and mutation remain separate kernel calls with the declared same-privilege replacement window.

## The two faces

Not every owned object is one a kernel this process can call answers for. A provider instance's stable
identity is answered by the provider; a cluster's by the cluster. So the clause producers come in two
faces over the **same four tokens**:

| | kernel face | reported face |
|---|---|---|
| where the observation comes from | a row's `rowObserveIdentity` | a total classification of a described command's outcome |
| what creates the object | a row primitive — a directory, a published file | a described `HostCommand` through the one interpreter |
| what removes it | a row primitive | a described `HostCommand` through the one interpreter |
| clause 1 | the protected store's exclusive entry | the same entry |
| clause 2 | the store's compare-and-swap | the same compare-and-swap |
| what the row declares | which clauses this kernel can hold | nothing — the reported face takes no row |

Each computation the two share — the record an origin describes, the binding attached to it, the conflict a
re-observation reports — is written once and reached by both, so the faces differ in *who answers the
observation* and never in what a clause means. The reported face's signatures name no `OwnershipRow` and
reach no primitive, which is a property of their types rather than of a stand-in nobody called.

Two consequences are worth stating. Clause 4's precondition is **pure** on both faces, because by the time
it is asked both have already made their observation; every conflict it can report is therefore reachable
by application. And the reported face's release forgets the record only over a reported *absence*: the
removal happened outside this process, so the answer that comes back after it is what decides whether the
record is forgotten at all. A target still present is a conflict, because a record forgotten over a
surviving object is exactly the orphan clause 4 exists to prevent.

An interrupted reported removal can leave a bound durable record after the object is gone.
`resumeReportedRemoval` accepts that retained `Bound` token and a fresh absence under the same
live protected entry. It performs clause-4 cleanup only over absence; every present identity is a
conflict. The ordinary `reobserveReportedIdentity` precondition still admits exactly the bound
identity before a removal is issued. Provider recovery validates its child share records, takes the
fresh instance observation, and retires the shares before the instance record.

The kernel producers refuse a record describing an object another authority owns, and the reported face's
own creating command is not the seam's to run — which is the same rule as ever, seen from the other side:
the moment a seam can run a string, it is a shell again.

The reported face is also used for one object a local kernel does answer for: the provider-guest alias's
symbolic link, whose creation no row primitive performs. There the "authority" is the shipped act's own
direct observation, and the face's producers order the clauses exactly as they do for a provider
instance ([what each owner adds](#what-each-owner-adds)).

## The rows

The clauses are uniform. Clauses 1 and 2 are the protected store's
([`HostBootstrap.Protected`](../../core/hostbootstrap-core/internal/ownership/HostBootstrap/Protected.hs)) and
are identical under every row; the store's root is the owner's choice — the store the harness bracket
opens, a provider's or plan's state directory, the store opened beside the host-wall target, or the
authority a shipped transaction names.
The mechanism for clauses 3 and 4, and every primitive, is per-row. The shipped row reuses the receiving
binary's own row rather than adding a third implementation.

| Clause | POSIX row | Windows row | Shipped row |
|---|---|---|---|
| 1 — exclusive entry | the protected store's lock: `base`'s portable `hLock` (`flock`/`fcntl`) on a retained descriptor, released by the OS on process death | the same store lock, which is `LockFileEx` on Windows | the receiving process holds the store lock at the authority the transaction names, for exactly its own lifetime |
| 2 — durable origin record | the protected store's compare-and-swap: write-temp, fsync, rename | same | same, performed by the receiving process |
| 3 — identity binding | `deviceID` / `fileID` from `lstat`, without following a link | `getFileInformationByHandle` → volume serial plus file index | the receiving binary's own row: POSIX across every crossing, this host's row for an empty `LiftContext` |
| 4 — conditional release | re-observe, compare, then remove by name | same | same, through the receiving binary's row |

Release is check-then-remove: the row re-observes the identity and then removes the object by its name,
both inside the protected entry. The entry excludes cooperating runs only, so a same-privilege process
that replaces the object between the two steps is not excluded
([ownership invariant](ownership_invariant.md#what-the-invariant-excludes)).

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
That process runs `runShippedOwnership` over its own `ownershipRowForHost`.

Private frame entries share `HostBootstrap.CLI.interpretFrameTransaction`. Cluster exposure
recognizes its own request first; ownership handles the remaining bytes. The suite's real
child entry imports this production dispatcher. Its process-group fixture wrapper handles
that probe alone and delegates ordinary transactions to the shared route. Local crossing
cases therefore exercise the same dispatch as a project binary.

The frame table's ownership column is descriptive: it names the outer host's build row or
the crossed frame's POSIX row. Production routing belongs to the lift transport. The column
mints no authority to ship or run a transaction, and no production module consults it for that choice.

The transaction is abstract. Its authority root, owned object and symbolic-link destination have
three distinct opaque types: `ShippedAuthorityPath`, `ShippedTargetPath` and
`ShippedLinkTargetPath`. Their producers share one validation over nonempty absolute Unicode
scalar paths, refusing NUL and surrogate escapes. `mkShippedOwnership` requires the authority
and object roles; the two symbolic-link acts require the destination role. Guest paths use POSIX
grammar, while an empty context retains the outer host's fully absolute native grammar, including
Windows. The receiver checks every path present in the act against its own grammar before creating
or opening the authority store. Invalid input refuses before any platform-specific act is attempted.
The codec uses the same admitted-path reader for all three roles, preserving the existing six tags
and length-framed UTF-8 fields.
A guest alias spec retains these admitted roles. Its `guestAliasLinkTarget` view supplies the
validated destination to prepared calls and the demo's compatibility consumer, so neither needs a
partial conversion from a descriptive path string.

Three properties make it a transport rather than a workflow:

- **One invocation per transaction.** The receiving process lives exactly as long as the lock it holds, so
  clause 1 stays a kernel fact rather than an application-level release that must be correct on every
  error path. A process that dies mid-transaction releases the lock because it died. That lock is the
  protected store's own exclusive entry, opened by the receiving process at the authority the transaction
  names; clause 2 is that store's compare-and-swap, so a shipped transaction holds the same two clauses,
  the same way, as every host-local owner.
- **One crossing renderer.** The argument vector comes from the lift's own fold and from nowhere else, so
  the row adds no second answer to "cross into this frame". The crossing, its sanitizing, its private
  protocol channel, and its process-group bracket are the authenticated-handoff boundary's, which carries
  one opaque transaction out and one opaque outcome back and interprets neither; the ownership
  interpreter is installed into that entry rather than beside it. ProviderSpec scans every public
  and private source module and pins the six consumers of the primitive renderers, including their
  placement-aware variants. Outside the lift and its context, the same guard refuses crossing-command
  literals, including escaped spellings. Constructed positive and negative cases validate that predicate.
- **A closed set of acts.** Observe, take a directory, take a file, and generic give-back are joined by
  symbolic-link take and give-back for the guest-alias owner. The symbolic-link acts are available only
  in a POSIX frame; a Windows binary answers them with `OwnershipUnsupported`. There is no act that runs a
  command: an external effect travels as a described command through the one interpreter
  ([§ KK](../../DEVELOPMENT_PLAN/development_plan_standards.md#kk-one-effect-vocabulary-and-no-scripts)),
  and an act that could run a string would make the row a shell again.

Both directions are exact values. Paths travel as UTF-8 text and only the payload is arbitrary bytes.
The transaction is length-framed rather than delimited, so neither kind of field can describe the next;
the outcome carries the closed fault sum itself, so a refusal that crosses a frame is the refusal that was
made rather than a rendering of one. A transaction a frame cannot read is answered with an encoded refusal
rather than a closed pipe, so a caller learns that the far side declined instead of inferring it from a
stream that ended.

Observation records nothing, but opening an absent authority store creates its directories and identity
file before the act runs.

A repeated directory or file take reads the sealed record under its protected entry. The
record must describe the requested kind and payload and an absent origin. A bound record
is re-entered through the ownership seam and its identity observed again before the
interpreter returns `ShippedObjectTaken`. A missing or replaced object yields the exact
`OwnershipConflict`; the retry preserves the stored record and any replacement object.

An unbound absent-origin directory record describes an interrupted take. Take and give-back
use the same observation under the protected entry to resolve it. With the target absent,
take creates and binds the directory using the exact unbound record's idempotent publication;
give-back forgets that record. A present target yields `OwnershipConflict` with recovery
guidance and preserves its identity, contents and exact protected record/version.

The near side returns `Either ShippedFailure ShippedOutcome`. `ShippedCrossingFailed` retains
a transport diagnostic, `ShippedOutcomeUndecodable` retains the diagnostic for an unreadable
answer, and `ShippedFrameRefused` retains the owning frame's exact `OwnershipFault`.
`classifyShippedOutcome` makes this total decision over the actual transport result.
Alias acquisition and release share `shippedAliasFailureRecovery`: only the frame's decoded
`OwnershipMalformed` refusal is `DoNotRetry`. A crossing failure, unreadable answer or
inapplicable decoded outcome requires a fresh observation before retry.

The decoder applies one 4 MiB ceiling to every length-framed field, including paths.
Field admission can be narrower, as it is for the identity's 1-to-64-byte width.
The encoder writes fields without enforcing that ceiling; the transport's whole-message
bound is separate. Text fields require UTF-8, while file payloads and identities retain bytes.
Malformed widths, text and origin tags are answered in the closed malformed-input fault.

The kernel cases check actual protected-record bindings and versions, staging cleanup and
the exact occupied or replacement conflict. A refused occupied take leaves its key vacant,
so a later take after the operator removes the object succeeds. Alias release forgets its
record, allowing another take to create a new link.

The shipped codec is platform-neutral: its shared `HostBootstrap.Wire.LittleEndian` reader is available
on Windows as well as POSIX. A kernel-specific refusal does not remove the request or outcome decoder.

An empty `LiftContext` addresses this machine, which is how a local transaction that must outlive its
launcher's own bracket is expressed — a supervised child whose group is killed when the owning process
disappears cannot be an ordinary bounded run, because the launcher's cleanup is exactly what a hard kill
skips. The receiving process then runs this host's own row, so on a Windows host it is the Windows row and
the symbolic-link acts refuse.

## The no-replace publication

Publishing a file under a name that must not already exist uses the platform's atomic **no-replace link**:
`link(2)` on POSIX and `CreateHardLinkW` on Windows. A hard link publishes the written bytes under the
final name in one kernel operation and fails when the name is taken.

The row's primitive is the link and nothing more: it gives an object a second name and leaves the first.
Withdrawing the staging name is the composing owner's own step, because owners genuinely differ there. The
seam's file publication writes, links, and then withdraws — the staging name was only ever a way to get
bytes onto the volume. The host wall does not withdraw: its armed object's identity has to be journalled
before any durable name for it exists, so it links a second name and keeps both until the durable one is
bound. Folding the withdrawal into the primitive would make that second shape unrepresentable.

A *symbolic* link is not a substitute: it publishes a reference rather than the bytes, and a destination
that reads as a link is refused by the same inspector that enforces clause 3's rule that reparse points
and symbolic links at a target are never followed. The one owner whose object *is* a symbolic link, the
provider-guest durable alias, publishes it outside the row (below). `rename(2)` is not a substitute either, because it
replaces the destination.

## What each owner adds

The transaction is shared; the policy is the owner's own. Each owner's object, mechanism per clause, and
treatment of a found object is the
[per-backend clause matrix](ownership_invariant.md#per-backend-clause-matrix); this section states only
the two places where an owner's shape bears on the seam itself.

- **The global host wall** composes the row's primitives under its own driver and keeps both names of a
  publication, for the reason above. Its fence is its protected store's never-reused record version
  rather than a counter file. Its location representation, raw opener and store/key access are in the
  [private location module](../../core/hostbootstrap-core/internal/ownership/HostBootstrap/Wsl2/GlobalWall/Location.hs).
  Windows derives the paths from the admitted profile; the driver and real-store fixtures share that
  private representation. The public facade keeps opaque target reporting and read-only presence.
  Its read-only `hostWallOwnershipPresent` projection reads the canonical
  active key inside a live protected entry and returns presence only; the demo uses that projection
  for teardown instead of raw location access. It returns no mutation authority. Its re-observation
  before a removal or move is its own copy of clause 4's comparison ([Current Status](#current-status)).
  Its raw-row driver first applies the existing capability classifier. Armed-stage creation treats only
  an occupied fault as a collision; other failures propagate unchanged. The first active store reserves
  the future candidate and largest codec identity, so later journal phases remain within 16 MiB.
  A matching spec with irreproducible desired bytes is an InvalidWallJournal.
  Guard cases replace the object after actual payload read and before identity confirmation; they do
  not claim to exclude replacement inside the later namespace primitive.
- **The provider-guest alias** owns a symbolic link, which no row primitive publishes. Its acts live in
  [`HostBootstrap.Ownership.Shipped`](../../core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs),
  outside the `OwnershipPrimitive` record: the far side observes, creates, publishes, and removes the link
  with direct POSIX calls and reaches the row only for `rowSyncParent`, so `clauseRefusal` does not gate
  those calls. Its clause tokens come from the reported-face producers (`enterReportedObject`,
  `recordReportedOrigin`, `bindReportedIdentity`, `reobserveReportedIdentity`, `releaseReportedObject`)
  with a reported-object record whose claim is derived from the link target, although its identity is the
  local kernel's device/inode answer. It stages the link and binds that identity before publication, so
  the durable binding identifies the inode in both the bound-staging and bound-published recovery windows.
  Publication is the module-local `publishSymbolicLinkNoReplace`, selected at build time: Linux gives the
  link inode a second name with `link(2)`, and Darwin moves it with `renamex_np(RENAME_EXCL)` because APFS
  refuses hard links to symbolic links. A correct-looking foreign link with no matching durable record is
  reported foreign.

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
- [development_plan_standards.md § EE](../../DEVELOPMENT_PLAN/development_plan_standards.md#ee-opaque-capabilities-and-phase-indexed-lifecycle-state)
  and [§ LL](../../DEVELOPMENT_PLAN/development_plan_standards.md#ll-the-frame-table-the-substrate-axis-is-a-lift-not-a-fork)
  — the plan's statements of the clauses and of the frame table.


## Object scope and the reported source boundary

The kernel and reported entry producers each introduce a fresh rank-2 object index.
EscapeOwnedObjectIndex and EscapeReportedObjectIndex attempt to return Entered session escaped
directly from those continuations; the compiler rejects the fresh object/escaped mismatch.
The session-index fixtures hold the other axis separately.

The reported-face source guard covers its producer region, strict stored re-entry and the shared
bound-record projection. Its vocabulary includes every current OwnershipPrimitive field, row
construction/capability access and kernel-producer delegates. A field-inventory check rejects an
uncovered primitive field, and per-name violating module texts exercise the same guard.
This is a property of the guarded source definitions; the IO callbacks remain the caller's.

## Live entry for typed clause effects

The protected store's read-only `verifyProtectedSession` consumes the same private live token and owner
thread as record access, without a filesystem probe. Every hidden `Entered`, `Recorded`, `Bound` and
`Releasable` carries that actual session in a positional constructor. Their public eliminators still
disclose the target and ownership evidence; no public constructor or updatable session field exists.

Both entry faces and both strict stored re-entry routes check the live entry. Recording, creating,
publishing, binding, kernel re-observation and both releases follow the same check through their
shared evidence helpers before any row primitive or supplied callback. Existing capability refusals
still run first. Expired and foreign-thread errors retain the protected store's precise diagnostic,
mapped by `storeFault` with the attempted operation `use the ownership entry`.

Pure identity comparison may project a successor after expiry, but the successor retains the revoked
session and authorizes no later typed effect. Raw rows and `withReobservedIdentity` take ordinary paths
and identities below this typed authority boundary; arbitrary caller IO and raw row calls remain the
caller's responsibility.

`OwnershipSpec` retains delayed closures for all thirteen entry/successor IO paths, after normal and
exceptional exit and on a foreign thread. Divergent rows/callbacks prove refusal ordering. A separate
actual host-row case creates, publishes and binds a real file, refuses foreign-thread and expired
release while preserving bytes, identity and protected envelope, then settles removal and versioned
forget through a fresh live entry. The source guard follows every shared live-entry helper, and the
reported-face guard follows those helpers without admitting an ownership primitive.

## Scoped whole-object read

`Primitive.readWholeObject` takes one raw ownership row and target and returns bytes or the original
domain fault; it returns no handle and mints no origin authority. It masks acquisition and transfer to
cleanup, restores the caller's masking state for payload reading, and closes every successfully opened
handle before returning or throwing.

A thrown read exception is rethrown even if cleanup also throws. With typed results, a read fault wins
a typed close fault, while a successful read reports a failed close. A thrown close exception after a
normal read still propagates. An open refusal reaches neither read nor close. The public export pin
admits only the byte-read function, and the reported-face guard includes its name among kernel
delegations it refuses.

`OwnershipSpec` opens actual temporary files through the host row. A retained closure performs a real
row read on the same handle after each exit and observes the closed-handle fault. Cases cover bytes,
typed read/close priority, synchronous read failure with failing cleanup, actual `throwTo` interruption
of a worker read, actual open refusal and cleanup exception after success. The asynchronous case joins
the worker before inspecting the handle, and masking-state observations check acquisition/read/close.
No close-call counter stands in for resource closure.

The host wall delegates byte reading to the shared scope and retains its own fault mapping, post-read
identity confirmation and 16 MiB limit. Its local handle transaction is absent. A host-row case
interrupts both active-wall re-apply and restore reads, observes the actual handle closed, preserves
target bytes/identity and the exact active/protected envelopes, then retries through the normal driver
and restores the original identity/bytes. Its conditional family declares the added case on every host.

Generated-config payload verification uses the same scope; its local readThroughRow transaction and
raw open/read/close imports are absent. Actual release and recovery interruption cases retain the file's
bytes and kernel identity and the exact protected record/version, then retry to restore absence and
forget the record. Payload digest, post-read identity, staging-withdrawal and domain fault policy stay
with the owner.

The physical production census holds readWholeObject's sole definition in Primitive. Its violating
copied-definition control fails the same checker, and both owner source guards hold delegation and
absence of local transactions. These checks are bounded source properties alongside the actual kernel
handle and retry evidence.

## Creating from the recorded origin

The directory/file creating producers check their declared row capabilities, then require the
recorded origin to be OriginAbsent before inspecting its kind. OriginPresent is occupied and reaches
no creating primitive. Clause 3 therefore binds an object this run creates rather than replacing the
meaning of a recorded pre-existing object after its name disappears.

File publication preserves a failed staging-create fault and removes nothing: an exclusive-create
failure does not prove that this run owns the staging name. Once staging creation succeeds, a failed
no-replace link attempts staging withdrawal best-effort and returns the original link fault even if
withdrawal returns a typed fault. A foreign target remains intact. The generated-config owner's
generation-scoped partial-write cleanup retains its responsibility for failed creation.

## Shared computation sites

The ownership source guard walks physical Haskell files under the core's src and internal roots,
including files not registered in Cabal. It checks lexical identifiers, prefix definitions and foreign
import declarations. Ordinary stat metadata in build, socket and executable probes does not encode
ownership identity and remains outside that identity rule. String/comment mentions are not calls.

| Source home | Shared computation | Owning phase |
|---|---|---|
| Ownership.Object | Origin codec and kernel identity encoder | [Ownership clauses and reservations](../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md) |
| Ownership.Tape | Origin codec consumers | [Ownership clauses and reservations](../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md) |
| Ownership.Posix and Ownership.Windows | Kernel identity and no-replace link primitives | [Ownership clauses and reservations](../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md) |
| Ownership.Primitive | Re-observation and the identity-conditional act | [Ownership clauses and reservations](../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md) |
| Ownership.Shipped | Symbolic-link identity/publication | [Host providers and lift](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md) |
| Config.Install.Native | Config-install no-replace publication | [Dhall configuration and project model](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md) |

The checker confines ownership kernel encoding to its vocabulary and declared row/act homes,
no-replace links to their declared primitive homes, and origin codec references to Object/Tape.
It holds the shared act and codec definitions at their actual homes. A different prefix definition
that invokes rowObserveIdentity and rowRemoveObject or rowLinkNoReplace is refused. Row-assembly and
refusal records bind their fields rather than invoking selectors; that syntax is distinct from effects.
A refusal-like function name provides no exemption for a real copied act.
In-memory violating and neutral module texts exercise the same checker. This is a guard over the
declared source shapes, not a proof about effects hidden behind arbitrary aliases.

`resumeOwnedRemoval` is the kernel counterpart of reported-removal recovery. It consumes a retained
Bound token under the live entry, requires both release and durable-record capabilities, and
accepts only a created kernel object's record. A fresh kernel absence permits parent-directory
synchronization followed by record forgetting. A present identity, reported object or found-state
origin refuses. Ordinary re-observation and release continue to require the bound object present.
