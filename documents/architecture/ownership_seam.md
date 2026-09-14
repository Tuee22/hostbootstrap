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

Three rows exist, and the frame table's ownership column says which one holds a frame's clauses. Two are
platforms: POSIX and Windows, and the outer host's column entry is whichever this binary was built for.
The third is a **transport** that runs the transaction at the frame owning the object; every crossing's
column entry is the POSIX row, because every frame reached *through a crossing* is Linux, so the
transport is not a third implementation of the clauses. That premise is about crossings, not about the
outer host: the shipped act is built host-native (§ N) like every other binary, so the same POSIX row is
also compiled for a Darwin outer host, and one of its primitives has two kernel spellings there. A row
may spell a primitive differently per kernel; what must never be written twice is the clause order. The column is a declaration rather than a value a caller runs,
which is exactly what keeps it one.

The clause order is a property of the types. A mutation consumes the recorded origin and a release
consumes the bound identity, so performing either out of order has no term rather than failing a review.

## Current Status

Host-local owners use the shared ownership primitives for kernel identity, exclusion, origin publication,
no-replace linking, and identity-conditional release. The POSIX row uses descriptor-based operations and
symbolic errno classification. The Windows row uses no-follow handles, `LockFileEx`, file identity, and
write-through creation. `ownershipRowForHost` selects the native row as a build fact.

`HostBootstrap.Substrate.Provider.Ownership` holds provider and share transactions. The cluster and direct
Colima backends retain their exact backend-specific machine, namespace, snapshot, and node identities through
the same clause order. The guest-alias path runs the shared transaction at the guest through the shipped
ownership command; the demo consumes its prepared managed authority. A missing primitive is an explicit
unsupported result, never a weaker ownership receipt.

Clause tokens have nominal object and entry indices. The protected entry's rank-2 identity prevents evidence
from moving between entries or outliving its transaction. Shipped requests are canonical bounded data; the
receiving binary performs the transaction using the row for the frame that owns the object.

The [ownership clauses phase](../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md) owns the
primitive seam. The [providers and lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
owns provider realization and transport, the [cluster lifecycle phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)
owns cluster and Colima adapters, and the [worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md)
owns their concrete consumers. Their dated gates distinguish native kernel checks from live provider acceptance.

## The vocabulary

A transaction needs nouns, and they are stated once, without effects, in `HostBootstrap.Ownership.Object`:

- **`ObjectIdentity`** — the kernel's answer for an object, `device:inode` on POSIX and volume serial plus
  file index on Windows. The constructor is private and admits only a non-empty answer within a fixed
  ceiling, so an empty or fabricated value is never compared as though it were an identity.
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
  both; the third case is an object this process's kernel does not answer for, and it carries an owner
  claim for the same structural reason. Recorded absence is a distinct case from a recorded prior
  identity, because "an owner looked and found nothing" and "no owner has looked" license different
  recoveries.
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

The four clauses are one transaction but not one process, so `Bound` has a second producer: **re-entry**.
An owner binds an identity now and releases it later — after its own bracket, after a restart, or from a
successor's recovery path — and clause 4 has to be reachable from the durable record rather than only
from the token the binding minted. Re-entry takes an exclusive entry, a target, and the bound record the
caller read back through its own store, and mints the same token; a record with no identity binding
describes a transaction that never got past clause 2, so it authorizes no removal and mints nothing. The
object index is introduced fresh, exactly as clause 1 introduces it, and the token still cannot outlive
the entry.

Both indices are nominal. `session` is the protected entry's own rank-2 variable, so a token cannot
outlive the entry that authorized it and no second brand can disagree with it; `object` names which object
the evidence is about. The target the owner named rides on the token too, so no producer takes a path
argument and there is no call at which a matching token and a different path could be presented together.

The constructors live in one Cabal-private module whose only importers are the facade that re-exports the
abstract types and the seam that mints them. Compile-fail fixtures reject constructing each token,
coercing either index, carrying one out of its entry, and importing the private module.

## The record tape

Every owner behind the seam supplies the same four store operations to it: publish a fresh origin
record, publish the bound one, forget the record, and read it back decoded. Those four are the tape,
and they live once, in `HostBootstrap.Ownership.Tape`, over one session, one key, and one
`RecordSubject`. The subject is a pair of phrases — what this owner calls its record, and what it
calls the act of binding an identity to it — so the refusals every owner emits read in its own
vocabulary while the code that emits them is shared.

The tape's operations are the ones the transaction actually needs and no more:

| Operation | What it settles |
|---|---|
| `publishFreshRecord` | clause 2's first write, idempotent when the record already there is this transaction's own |
| `publishBoundRecord` | clause 3's re-publication, against the exact version read back inside the entry |
| `forgetRecord` | clause 4's settlement, where an already-absent record is the state asked for rather than a refusal |
| `readRecordUnder` | the decoded record, with a store failure and a malformed record kept distinct |

Idempotence is a property of the transaction rather than a convenience. The binding is the single
field a later clause adds, so a record whose kind and origin already match this one is this
transaction's own earlier write and publishing again is a no-op; a record that differs in any other
way belongs to someone else and is refused, never overwritten. That refusal is one message, so the
same condition cannot produce two different answers depending on which owner observed it.

The two error layers collapse through one class rather than ten hand-written lifts.
`OwnershipCarrier` has exactly two methods — a clause fault and a store fault, each into the owner's
own closed error sum — and `carryClause` and `carryStore` are the only places the lifting is written.
An owner therefore declares its instance and its subject, and keeps only what is genuinely its own:
its removal-set policy, its payload rules, and its create-then-bind path.

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

The kernel producers refuse a record describing an object another authority owns, and the reported face's
own creating command is not the seam's to run — which is the same rule as ever, seen from the other side:
the moment a seam can run a string, it is a shell again.

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
  interpreter is installed into that entry rather than beside it.
- **A closed set of acts.** Observe, take a directory, take a file, and generic give-back are joined by
  symbolic-link take and give-back for the guest-alias owner. There is no act that runs a command: an external
  effect travels as a described command through the one interpreter (§ KK), and an act that could run a string
  would make the row a shell again.

Both directions are exact values. The transaction is length-framed rather than delimited, because a target
path and a payload are arbitrary bytes and a delimiter would let one of them describe the next field; the
outcome carries the closed fault sum itself, so a refusal that crosses a frame is the refusal that was
made rather than a rendering of one. A transaction a frame cannot read is answered with an encoded refusal
rather than a closed pipe, so a caller learns that the far side declined instead of inferring it from a
stream that ended.

An empty frame stack addresses this machine, which is how a local transaction that must outlive its
launcher's own bracket is expressed — a supervised child whose group is killed when the owning process
disappears cannot be an ordinary bounded run, because the launcher's cleanup is exactly what a hard kill
skips.

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
  derived rather than edited in place and a crash leaves either the prior body or the new one. Its
  clause 1 and clause 2 are its own protected store, opened beside the target, so its exclusive entry is
  the same one every other host-local owner takes and its strictly monotonic fence is that store's own
  never-reused record version rather than a counter file. It is also the owner that keeps both names of a
  publication, for the reason above.
- **The provider-guest alias** keys its record by a digest of an injective owner binding — provider origin,
  share key and generation, alias key and generation, alias, and target — and stores the complete binding
  as well, so the digest is only a bounded filename. Its prepared state records explicit absence plus a
  fresh nonce before the first mutation. The shipped row stages the symlink and binds its exact device/inode
  identity before atomic no-replace publication. This is the primitive with two spellings: Linux gives the
  symlink inode a second name with `link(2)`, while Darwin uses `renamex_np(RENAME_EXCL)` because APFS
  deliberately refuses hard links to symbolic links. Both are the POSIX row's publication step, selected
  at build time by `publishSymbolicLinkNoReplace`; neither is a fourth row. The durable binding
  therefore identifies the inode in both the bound-staging and bound-published recovery windows. A
  correct-looking foreign symlink with no matching durable record is reported foreign. No pathname sidecar
  participates in ownership.

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
