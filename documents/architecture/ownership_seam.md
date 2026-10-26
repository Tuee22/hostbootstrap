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
Windows row uses no-follow handles, `LockFileEx`, file identity, and write-through file creation; its
parent sync performs no IO (see the gaps below). `ownershipRowForHost` selects the native row as a build
fact.

Which backend holds which clause, and how, is the
[per-backend clause matrix](ownership_invariant.md#per-backend-clause-matrix). A missing primitive is an
explicit unsupported result, never a weaker ownership receipt.

Clause tokens have nominal object and entry indices. The protected entry's rank-2 identity prevents evidence
from moving between entries or outliving its transaction. Shipped requests are canonical bounded data; the
receiving binary performs the transaction using its own host row.

Six gaps sit between this page's contract and the tree:

- **Re-entry trusts the record it is handed.** `ObjectIdentity` and `OriginRecord` keep their
  constructors private, but the public functions `mkObjectIdentity`, `parseObjectIdentityHex`,
  `parseOriginRecord`, and `bindOriginRecord` validate shape only. `reenterOwnedObject` accepts any bound
  record, so a caller that builds one from bytes holds release authority over whatever object currently
  has that identity. Re-entry is sound only when the record was read back from the owner's own protected
  store.
- **The tape replaces a stored binding.** `publishFreshRecord` accepts a stored record whose kind and
  origin match, whatever binding it carries, and `publishBoundRecord` then writes over the stored version
  without comparing bindings, so a stale bound record is rebound rather than refused. The harness owners
  and the shipped acts read the stored record before clause 2 and refuse or resume from it, which keeps
  them clear of this.
- **A foreign record is reported as malformed.** A well-formed record that belongs to another transaction
  is refused with `OwnershipMalformed`, the case reserved for a record that cannot be interpreted, so a
  caller cannot tell the two apart by case.
- **The record reader is whitespace-tolerant.** Rendering is canonical, but reading splits the line on
  any whitespace, so tabs, repeated or surrounding spaces, and a carriage return before the newline are
  accepted rather than refused.
- **The Windows row's parent sync does nothing.** The row declares `holdsDurableParentSync`, but its
  `rowSyncParent` returns success without a kernel call. Only file creation passes
  `FILE_FLAG_WRITE_THROUGH`, and a written file is flushed through its own handle; the hard link,
  directory creation, and removals that change a parent's entries carry no write-through, so nothing
  makes those name changes durable. The contract is a FlushFileBuffers on a handle opened on the parent
  directory, with a refused flush reported as a fault.
- **The host wall keeps its own clause-4 check.** The global host wall reaches the row's primitives
  directly, and its identity-conditional removal and move run through its own `withConfirmedIdentity`
  rather than an identity-conditional act the seam supplies, so the comparison clause 4 rests on is
  written twice.

All six belong to the
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
  well-formed hex in each identity, digest, or claim field; it splits that line on any whitespace. Every
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
| 4 — releasing (`reenterOwnedObject`, `reobserveOwnedIdentity`) | `holdsStableIdentity` |

`holdsExclusiveOpen` is declared by both rows and gates no clause.

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
| re-entry | `reenterOwnedObject` | — |
| 4 | `reobserveOwnedIdentity`, `releaseOwnedObject` | `reobserveReportedIdentity`, `releaseReportedObject` |

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
object index is introduced fresh, exactly as clause 1 introduces it, and the token still cannot outlive
the entry.

The tokens order the calls; they do not certify the values. `bindOwnedIdentity` and
`bindReportedIdentity` take the identity as a parameter, `enterReportedObject` takes the observed origin
as a parameter, and `reenterOwnedObject` takes the record as a parameter. An owner therefore passes the
identity its creating primitive returned or its classified command outcome, and re-enters only from a
record its own store returned. Refusing a found object is likewise the owner's policy: the kernel
creation primitives refuse a target that already exists, and the
[per-backend clause matrix](ownership_invariant.md#per-backend-clause-matrix) states what each owner does
with one.

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
field a later clause adds, so `publishFreshRecord` decides by kind and origin alone: a stored record
whose kind and origin match this one is taken as this transaction's own earlier write and publishing
again is a no-op, whatever binding it carries; a record that differs in kind or origin, or does not
parse, belongs to someone else and is refused with `OwnershipMalformed`, never overwritten. That refusal
is one message, so the same condition cannot produce two different answers depending on which owner
observed it. `publishBoundRecord` then writes over the exact stored version without comparing bindings,
so the store does not refuse a rebinding: an owner that must not rebind reads and resolves the stored
record before clause 2, as the harness owners and the shipped acts do ([Current Status](#current-status)).

The two error layers collapse through one class rather than ten hand-written lifts.
`OwnershipCarrier` has exactly two methods — `fromClauseFault` and `fromStoreFault`, each into the
owner's own closed error sum. `carryClause` collapses a clause producer's refusal and the domain result
nested inside it; `carryStore` carries a bare clause result (`OwnershipFault`) into the domain sum.
A store fault (`ProtectedError`) is lifted by `fromStoreFault` itself, which `readRecordUnder` applies.
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
  symbolic-link take and give-back for the guest-alias owner. The symbolic-link acts are available only
  in a POSIX frame; a Windows binary answers them with `OwnershipUnsupported`. There is no act that runs a
  command: an external effect travels as a described command through the one interpreter
  ([§ KK](../../DEVELOPMENT_PLAN/development_plan_standards.md#kk-one-effect-vocabulary-and-no-scripts)),
  and an act that could run a string would make the row a shell again.

Both directions are exact values. The transaction is length-framed rather than delimited, because a target
path and a payload are arbitrary bytes and a delimiter would let one of them describe the next field; the
outcome carries the closed fault sum itself, so a refusal that crosses a frame is the refusal that was
made rather than a rendering of one. A transaction a frame cannot read is answered with an encoded refusal
rather than a closed pipe, so a caller learns that the far side declined instead of inferring it from a
stream that ended.

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
  rather than a counter file. Its re-observation before a removal or move is its own copy of clause 4's
  comparison ([Current Status](#current-status)).
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
