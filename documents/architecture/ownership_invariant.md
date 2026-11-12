# Ownership Invariant

**Status**: Authoritative source
**Supersedes**: the platform-primitive ownership rule that admitted a backend only with an OS-protected
namespace plus an identity-bound conditional kernel mutation, and returned `Unsupported` otherwise
**Referenced by**: [ownership seam](ownership_seam.md), [lifecycle state model](lifecycle_state_model.md),
[durable state](durable_state.md), [harness workflow](harness_workflow.md),
[unrepresentable state](unrepresentable_state.md), [composition methodology](composition_methodology.md),
[WSL2](../engineering/wsl2.md), [Incus](../engineering/incus.md), [Lima](../engineering/lima.md),
[cluster lifecycle](../engineering/cluster_lifecycle.md), [documents index](../README.md)

> **Purpose**: Define the one ownership invariant every substrate must satisfy before mutating shared
> state — its four clauses and the exact guarantee it does and does not provide.

## TL;DR

Ownership is a **protocol** requirement, not a platform-primitive requirement. A backend may mint an
ownership receipt when it holds all four **Locked-Origin Identity Ownership** clauses: an OS-released
exclusive lock, a durable origin record written before the first mutation, identity binding to the
object's stable identity as its owning authority answers it rather than its pathname, and conditional
release on exact identity match. This makes crash/retry **recoverable**, **excludes** concurrent
cooperating runs, and **detects** foreign mutation; it does **not** exclude a hostile same-privilege
process. No substrate supplies that exclusion, and the contract makes no such claim. A backend that cannot
satisfy a clause returns `Unsupported` and mints no receipt.

This page is the canonical statement of the invariant and of its per-backend realization.
[development_plan_standards.md § EE](../../DEVELOPMENT_PLAN/development_plan_standards.md#ee-opaque-capabilities-and-phase-indexed-lifecycle-state)
is the plan's restatement of the four clauses, the contract phases close against, and it names this page
as the canonical statement.

Store-backed re-entry has an abstract `StoredOriginRecord session` input with a nominal entry
index. Only the tape's `readStoredRecordUnder` mints it, from an actual decoded protected read and
its exact version. The dedicated kernel and reported producers refuse in-memory data by type.
They are the only re-entry producers; physical production-source and exact export guards forbid
unconstrained entrypoints. Every owner retains the actual wrapper until strict re-entry.
The projections are ordinary functions, so record-update syntax cannot change either the body or
version of a sealed read.

The ownership entry's nominal index prevents direct cross-entry values. Hidden clause tokens also
carry the actual protected session, so typed ownership effects consume its live owner-thread check
before any primitive or supplied continuation. Delayed IO closures are refused after normal or
exceptional entry exit and on a foreign thread. The [ownership seam](ownership_seam.md#live-entry-for-typed-clause-effects)
states the runtime boundary and its real-file preservation/retry evidence.

## Scope

The invariant governs every object a backend mutates on the project's behalf: a named VM, cluster,
generated config, data root, port, host daemon, global provider setting, or durable alias. A pathname
compare, a content hash, or an immediate re-probe substitutes for none of the four clauses: each answers a
question about a name or about bytes at one instant, and none of them binds the object.

This page uses **frame** in the frame-table sense of [the glossary](../README.md#glossary) — a row of the
frame table, and the machine a provider reaches — except where it names a plan's frame text, which is the
default topology sense (a `ProjectFrame` identity).

## Current Status

The nouns the four clauses are written in are stated once, without effects, in
`HostBootstrap.Ownership.Object`: a validated owning-authority identity, the bytes a run intends to install and
their digest, what is owned and what was there before, the durable origin record with its one canonical
codec, and the closed fault sum with its total eliminator. See
[ownership seam](ownership_seam.md#the-vocabulary) for what each carries and why.

`mkObjectIdentity` validates non-empty identities of at most 64 bytes;providers and containers use it
as well as kernels. The rows encode their kernel words through `mkKernelObjectIdentity`. The type
proves those bounds, not provenance or mutation authority. Origin records accept only their exact
rendered bytes;tabs,extra spaces and CRLF variants are malformed rather than normalized.

The [per-backend clause matrix](#per-backend-clause-matrix) is the one statement of which backend holds
which clause and how. Every owning backend in it holds all four clauses. The Direct realization is explicit:

- **The Direct provider realization holds none, by design.** It admits the already-local host by
  observing it, publishes no origin, never claims the host, and answers stop and delete with
  `Unsupported`, so it mints no receipt that would need the clauses.
The Lima and WSL2 guest-VM backend holds an owned directory lease around a distinct protected
reported-object entry. Creation records absence and carries the record's claim; adoption requires
that claim and Lima's native instance-directory identity or WSL's exact owned install location and
registration GUID. Every dependent effect checks the current VM and parent lease before and after.
An unrecorded same-named VM remains foreign.


One further gap sits between the contract below and the tree:

- **An already-owned cluster reconcile enters the store twice.** The cluster backend answers an
  already-owned reconcile in one protected-store entry and checks that the cluster is running in a
  second, where the contract takes the entry once per transaction. It belongs to the
  [cluster lifecycle phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md).

The worked demo routes its VM durable share by provider. Incus and Lima run the exact prepared route
(`runExactVmShare`). WSL2 runs the shipped symbolic-link alias transaction directly
(`reconcileShippedDurableAlias`) and then the same exact route; both reach the alias through the shipped
row described in the [matrix](#per-backend-clause-matrix).

Plan-level identities — `ProjectPlan`, the `StepExecution` that `stepExecutionFor` produces, and Chain's
exact `CommandAuthority` and `LifecycleCursor` — are typed in
[execution-shape taxonomy](run_models.md) and
[hostbootstrap-core library](hostbootstrap_core_library.md).
Those plan identities are descriptive identity and topology evidence, not ownership receipts or mutation
authority. They prevent a caller from supplying a plan digest, frame text, resource identity, or
dependency edge independently; the selected backend must still satisfy all four clauses below before it
may mutate the named object or mint ownership evidence.

Cluster exposure authority retains those identities through opaque types. All four indices of
`PreparedClusterExposure` (scope, plan, cluster and frame) and `ResolvedExposure` (scope, plan, cluster
and service) have nominal roles. Representation coercion cannot retag either value. The prepared
value comes from an already-applied cluster cordon; exact authenticated relay inspection produces
the resolved value, and service lookup opens it through a rank-2 continuation.
A stopped relay produces no endpoint authority. Release still authenticates its recorded name,
identity and ownership labels, but accepts the stopped container's empty port map. Recovery removes
that exact stopped relay before creating a new operation and mappings. A refused removal or corrupt
record preserves ownership evidence rather than forgetting it.

`runPlannedStep` compares the descriptor's operation and frame with the selected projected node before
running its callback. A mismatch returns the exact refusal without running that callback. The projected
node constructor remains private at the plan-kernel boundary as well as the public facade.

The public object-store family is `ObjectStoreResourceKind`, keyed by the project's
`project:deploy-object-store` step and exposed as `ObjectStoreResource` by the plan and reconciliation
facades. `HostBootstrap.Plan.Resource` owns its single private datatype; the plan kernel imports that
actual tag directly. The readiness kernel's `ObjectStoreRolloutProbe` relates it to
`ObjectStoreRolloutReady`, and the public readiness facade re-exports the existing probe-key constructors.
All these consumers share one representation identity without a local tag alias or conversion.

Persisted journal verification takes the exact plan, its projected `PlannedResource` and the matching
indexed handle. It checks that witness's plan digest and key, then binds the record's frame to
`plannedResourceFrame` alongside the record's digest, resource, generation, operation and version
checks. The witness retains the resource family's placement even when one node projects families in
different frames; an operation key alone does not identify that placement.

Reconciliation derives its resource, journal, adoption and operation evidence from the same admitted
`ProjectPlan`. Each identity in the invocation-local resource carrier retains its ownership operation.
Before protected interpretation, Chain's private entry policy joins the actual store, acquisition origin,
frame and admitted topology as defined by [binary-context admission](binary_context_config.md).
Local managed-resource carrying checks the matching handle and ownership receipt and retains durable
settlement evidence only for the node's own key or one of its declared projected operations. The
declaring node's frame selects both successor and expected predecessor bytes. A dependency's handle
and receipt remain readable through the ordered prefix, but its dependent cannot replace the dependency's
carried settlement; `Conflict` preserves the complete existing entry. Authenticated child transfer retains
ownership evidence without the parent frame's settlement. Chain publishes local settlement before
acknowledging the corresponding journal outcome.
Every carried-resource opener restricts readback to the current node's own key or its exact
ordered dependency prefix, including an opener given a typed `PlannedResource`. A key outside that view
yields `Conflict`. An allowed dependency with no carried managed resource yields a `Failure` requiring
`ReprobeBeforeRetry`.
`withCarriedManagedResource` reopens the managed handle under fresh generative indices.

The carrier and runtime use their real allocation functions in the `Lifecycle.Execution.Core` module
of the Cabal-private `lifecycle-representation-internal` unit shared by production and tests. Main
specializes the payload and gate to its own runtime-dependency package and actual prepared gate, and
owns registry, service and gate policy. The public execution facade exposes opaque values and reporting
projections; allocation remains inside the package interpreter boundary.

Phase and sprint ownership is in [the development-plan index](../../DEVELOPMENT_PLAN/README.md). The
clauses below bind every backend that mints an ownership receipt; a row that cannot hold one refuses
before mutation.

## The four clauses

A backend satisfies the invariant only when it holds all four. Partial satisfaction is `Unsupported`,
not a weaker receipt.

### 1. Exclusive entry

A kernel-held lock is acquired before any mutation and retained across the whole
observe/mutate/settle bracket. The lock must be released by the operating system on process death, so
a crashed run cannot strand it. A lock held only by cooperating library code, or one that requires an
orderly unlock, does not satisfy this clause.

The descriptor or handle carrying that lock is non-inheritable across an executed child. A provider or
service process may intentionally outlive its launcher, but it is not thereby an owner of the launcher's
protected-store entry or project-wide liveness extent. On POSIX the store sets `FD_CLOEXEC`; the Windows
handle row is already non-inheritable.

The protected store's entry uses `base`'s portable `hLock`, together with an in-process mutex. Its
nonblocking entry first tries that mutex, then `hTryLock`; contention from another thread or process
returns absence. The holding thread's own re-entry is a typed `ProtectedInvalid` refusal.

Each admitted `ProtectedSession` carries a nominal provenance index and a fresh private extent token.
The token records its owner thread and is revoked before the entry unlocks. Read, list, compare-and-swap,
conditional delete and writable-store probes require that live owner-thread token before IO. A rank-2
index alone cannot stop an ordinary IO closure retaining a session; retained actions are therefore
explicitly refused after exit, inside a later entry, and on a foreign thread. Pure store identity/root
projections carry description and confer no record access.

Run liveness holds a separate kernel lock for the complete run. Its name is validated by the record-key
alphabet before directory creation or file opening. Acquisition is masked; the body runs in the caller's
masking state, and every return or exception closes the handle. A competing process observes the live
holder before acquiring anything, and an executed child cannot inherit the lock.

### 2. Durable origin record before the first write

Before the first mutating call, the backend durably records either the exact original bytes **or** an
explicit absence marker, keyed by a generative nonce. Absence is a recorded fact, never an inference
from a missing backup. This clause is what makes restore correct after a crash between the first write
and the run's completion — without it, a retry can record generated content as the original and
teardown then restores that content instead of the user's state.

The protected store publishes a closed temporary in the destination directory, synchronizes its data,
renames it atomically, and synchronizes the parent directory on POSIX. Windows uses `flushFileBuffers`
on a native writable handle before a write-through `moveFileEx` replacement, preserving absolute local/UNC
long paths. Darwin requests `F_FULLFSYNC` for the regular temporary and
again for the published regular file after parent-directory `fsync`, ordering device-cache flushes around
publication without relying on a directory ioctl. A failed requested barrier is a typed store failure;
there is no weaker fallback. The old-or-complete-new crash guarantee assumes the filesystem and device
honor their successful flush requests. The source gate holds barrier order and full temporary cleanup;
it does not claim to reproduce power loss. Apple's [fsync](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html)
and [fcntl](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html)
manuals explain the distinction between host synchronization and the full device-cache request.

Protected record keys are at most 200 ASCII bytes: lowercase letters, digits, hyphen, underscore and
internal dots. Leading/trailing dots and Windows reserved device prefixes are refused. The one identity
codec escapes uppercase `C` as `_c` and literal underscore as `__`; namespaces and relation paths retain
their structure. `mkRecordSegment` uses that codec for a scalar and refuses path injection. A tuple of
complete encoded identities uses the canonical three-dot separator, which no encoded identity contains.
Recovery decodes components and requires exact re-encoding; it never lowercases or filters identity text.

The immutable store identity envelope is `hbps2 <nonce>\n`, recording this key-encoding epoch. An old,
unknown, empty or identity-less populated store is refused before its rows are interpreted. The library
preserves those bytes and performs no generic filename migration or old-key fallback: an old literal
`_b` cannot be distinguished from the new encoding of uppercase `B` without owner payload knowledge.
Any recovery of incompatible stores must be explicitly owned; a miss under the new encoding grants no
fresh ownership over historical rows.

### 3. Identity binding, never pathname

Every operation after the first binds to the object's stable identity, as answered by the authority
that owns the object, rather than the name it was reached by. On the kernel face that is the kernel's
`(volumeOrDevice, fileIndexOrInode)` pair; on the reported face it is the identity the provider or
container runtime reports for the object it created (an Incus instance's volatile.uuid, a container's
identity). An identity qualifies only when its authority never answers it for a different live object;
a name, including a container or instance name, never qualifies. A pathname is evidence of nothing
between two operations: another process can rename, replace, or redirect the name in that window.
Reparse points and symbolic links at a target are never followed. Where a symbolic link is itself the
owned object, as the provider-guest durable alias is, it is bound by its own identity.

### 4. Conditional release

Restore and delete re-observe the recorded identity and act only on an exact match. Any other
observation is a structured `Conflict` carrying expected and observed identity, and the object is left
untouched. The invariant never removes state because its pathname matched.

## How the clauses are realized

The clauses are uniform; the mechanism that supplies each belongs to a **row** of the frame table, and the
transaction they compose is written once above those rows. [Ownership seam](ownership_seam.md) is the
canonical home for that structure: the seam of kernel primitives, the two platform rows, the row that runs
a transaction at the frame owning the object, and the atomic no-replace publication. Which backend holds
which clause, and what each owner adds on top, is the [per-backend clause matrix](#per-backend-clause-matrix)
below.

Not every owned object is one a kernel this process can call answers for. A provider instance's stable
identity is answered by the provider, so the clause producers have a second **reported** face: the
observation arrives as a value a total classification produced, the object is created and removed by
described commands through the one interpreter, and the record carries the claim this run stamps on the
object so the interval between clause 2 and clause 3 stays resolvable. The clauses themselves are
unchanged — clause 1 is the same exclusive entry, clause 2 the same compare-and-swap, and every shared
computation is written once and reached by both faces. [Ownership seam](ownership_seam.md#the-two-faces)
carries the detail.

Provider probes also cross that boundary as argument vectors. The guest-VM share observation uses
separate directory and write-access probes, and provisioning egress uses a direct name-service query.
The provider backend and ownership driver carry no shell program or locking front end.
Their source guard checks both that absence and the path through the one command interpreter to
the described provider commands.

Durable provider records inherit the protected store's durability contract. A source guard scans the
provider facade and every module beneath it, allowing only explicit read-only filesystem imports.
It also checks that the ownership driver applies the record tape's fresh, bound and forget
publications, and that the tape applies the protected store's compare primitives. The provider
boundary has no separate publication or filesystem-write path.

The shipped symbolic-link row binds the staging inode before publishing the alias. Give-back cleans
that recorded staging name before forgetting, whether the alias is exact or already absent, and refuses
a replacement at either name. The unlink helper observes identity again and passes that fresh sample
through the bound identity check before removal. An unbound record can give back an absent alias and
an exact staging link; an occupant at the alias is a conflict. Without a record, every occupant is
occupied. Both acts validate the exact link-target claim and absent origin before acting.

Three consequences belong here rather than there, because they are properties of the contract rather than
of its realization. A backend that cannot supply a clause returns `Unsupported` and mints no receipt —
never a weaker receipt. The clause *order* is not a convention a reviewer checks: a mutation consumes the
recorded origin and a release consumes the bound identity, so performing either out of order has no term.
The types fix the order of the calls, not the values passed through them: the identity clause 3 binds and
the origin the reported face enters with are caller-supplied, so an owner passes the identity its creating
primitive returned or its classified command outcome, and refusing a found object is the owner's policy
(see the [matrix](#per-backend-clause-matrix) and
[ownership seam](ownership_seam.md#the-clause-tokens)). And on the reported face the same order still holds even though the removal happens outside this process:
the record is forgotten only over a reported absence, so an object that survived its removal leaves a
record that still claims it rather than an orphan nobody claims. That comparison is of the *identity*,
not the name: an object standing where this run's object was, after the removal it issued, is somebody
else's, and is reported as a replacement and left exactly as it was found.

A second property of the reported face is easy to get wrong and is worth stating. Every release and every
dependent transaction re-establishes clauses 1 through 3 over a record a previous entry already bound, so
the record it finds carries clause 3's identity as well as clause 2's origin. Clause 2's republication
therefore compares what the record *says* — its kind and its prior origin — and treats the binding as the
one field a later step of the same transaction adds. Comparing the encoded bytes instead refuses the
transaction's own record as a foreign one, which makes every re-entry impossible.

## Per-backend clause matrix

One row per backend, each verified against its module. "Kernel face" and "reported face" are the seam's
two faces ([ownership seam](ownership_seam.md#the-two-faces)); "host row" is the row
`ownershipRowForHost` selects for the binary's own kernel.

| Backend | Object | 1 — exclusive entry | 2 — origin record | 3 — identity | 4 — conditional release | A found object |
|---|---|---|---|---|---|---|
| [`HostBootstrap.Harness.DataRoot`](../../core/hostbootstrap-core/src/HostBootstrap/Harness/DataRoot.hs) — kernel face, host row | the run's `.test_data` generation directory | the caller's protected-store entry | canonical `OriginRecord`, directory case, published before the directory is created | the created directory's kernel identity | re-entry from the record, re-observation, content cleared, directory removed | preserved: the record names it and no identity is ever bound |
| [`HostBootstrap.Harness.GeneratedConfig`](../../core/hostbootstrap-core/src/HostBootstrap/Harness/GeneratedConfig.hs) — kernel face, host row | the run's generated sibling config file | the caller's protected-store entry | canonical `OriginRecord`, file case carrying the intended payload digest | the published file's kernel identity, after atomic no-replace publication | re-entry, re-observation, then a byte comparison against the recorded digest; an edited file is left intact | refused before any record is written |
| [`HostBootstrap.Wsl2.GlobalWall.Host`](../../core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Host.hs) — host-row primitives under its own driver | the per-user `.wslconfig` | the wall's own protected store, opened beside the target | the wall's own record (`encodeWallRecord`) naming the exact prior bytes or their absence, plus a strictly monotonic fence record | the host row's identity read | re-observation through the row before every removal or move; a replacement is refused | its bytes are the recorded origin and are restored byte-for-byte |
| [`HostBootstrap.Substrate.Provider.Ownership`](../../core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs) — reported face | an Incus instance, and each share attached to it | the protected store under the provider's state directory | explicit absence plus a fresh owner claim, published before `incus launch`, which carries the claim on the instance | the instance's volatile.uuid; a share's device, re-observed together with the instance | re-observation before and after every mutation and guest command; the record is forgotten only over a reported absence | an instance no record claims, or one carrying another record's claim, is a conflict |
| [`HostBootstrap.Substrate.Provider.Alias`](../../core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Alias.hs) over [`HostBootstrap.Ownership.Shipped`](../../core/hostbootstrap-core/src/HostBootstrap/Ownership/Shipped.hs) — shipped symbolic-link acts, reported-face producers | the provider-guest durable alias, a symbolic link in the guest | the protected store's exclusive entry, taken by the project binary in the guest in a store inside the host-backed share; no guest `flock`, `stat`, or Python front end participates | a reported-object record over explicit absence, with a claim derived from the link target, keyed by a digest of the alias path and target | the staging link's device/inode pair, bound before no-replace publication | re-observation of the exact link, removal by name, record forgotten over absence | a link no record claims is reported foreign |
| [`HostBootstrap.Cluster.Ownership`](../../core/hostbootstrap-core/internal/cluster-ownership/HostBootstrap/Cluster/Ownership.hs), joined to the plan by [`HostBootstrap.Cluster.Backend`](../../core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs) — reported face | a kind cluster and every node container | the protected store under the plan's state directory, entered once per call except an already-owned reconcile, which enters twice (see [Current Status](#current-status)) | one record per node over explicit absence, all published before `kind create cluster` | each node container's runtime-reported identity | every node re-observed, the cluster removed through the one interpreter, each record forgotten only over a reported absence | anything at the name that no record claims is a conflict |
| [`HostBootstrap.Cluster.Backend`](../../core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs) — protected-store records written directly | the cluster-adjacent exposure relay container | the cluster's protected-store entry | a nonce- and specification-bound pending record, published before `docker container run` | the inspected relay container identity and every runtime-selected loopback mapping | name, identity, labels, generation, operation, and mapping set re-inspected; record forgotten only after the identity is absent | a replacement, wildcard, missing or extra mapping, or changed target is a conflict |
| [`HostBootstrap.Ensure.Colima.Ownership`](../../core/hostbootstrap-core/internal/colima-ownership/HostBootstrap/Ensure/Colima/Ownership.hs) — both faces | one 128-bit plan/lifecycle namespace and its isolated Colima profile | the protected-store entry; the reusable profile-global lock is synchronization only | a reserved stage record binding the owner token, the lineage digest, and the invocation digest, published before any namespace object exists | the Colima home, Docker config, root/data wall, machine and context, every required artifact, and a directory-chain digest, retained as the managed stage's evidence beside a retained namespace manifest | the stage advances to `ColimaReleasing` with the cleanup invocation digest, and the retained manifest is revalidated against the live home and Docker config, before `colima delete --force --data`; the machine and disk identities are re-observed first and their absence proved after; the home's remaining entries, other than its cache and tmp directories, are then each removed by re-observed identity | foreign profiles, copied records, replacements, and partial foreign stages are conflicts |
| [`HostBootstrap.Substrate.Provider.Backend`](../../core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs) — Direct realization | the already-local host | none | none: no origin is published | none | stop and delete answer `Unsupported` | admitted by observation and never claimed |
| [`HostBootstrap.Substrate.Provider.Backend`](../../core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs) — Lima and WSL2 realization (`StrongLimaBackend`) | a VM inside an owned local namespace | the directory lease and distinct protected VM-record entry | absence is published before create-only or installation | Lima instance-directory kernel identity or WSL registration GUID, plus the exact creation/location claim | claim, VM identity and parent lease are checked before and after dependent effects; forward stop/delete answer `Unsupported` | refused as foreign without VM mutation |

What each owner adds beyond the shared mechanism:

- **Harness data root.** The parent `.test_data` is scaffolding: created if missing, never owned, never
  removed. Release checks the bound identity again immediately before listing and clearing content, then
  the seam removes the directory. A non-cooperating replacement between that check and per-entry
  pathname removals remains possible. Recovery of the window between clauses 2 and 3 removes only an
  empty directory through the row's non-recursive removal; non-empty content and its record survive as
  a conflict. Bound and unbound absent-origin records settle when the directory is authoritatively
  absent. A lost exclusive-create race forgets the unbound record, so recovery never adopts the winner.
  With no record, recovery reports already absent without inspecting the path. The enclosing Harness
  close is described in [harness workflow](harness_workflow.md).
- **Generated config.** Recording the payload digest before the write makes the unbound crash window
  recoverable without adopting foreign bytes. Recovery re-observes the entry's identity after reading
  matching payload bytes and immediately before unlinking; a same-bytes replacement is refused with
  the record intact. A replacement between that observation and unlink remains possible. Bound records
  whose target is authoritatively absent settle as already absent. Successful recovery withdraws the
  record-derived staging name before forgetting; every refusal keeps the exact record bytes.
  No pathname sidecar participates.
- **WSL2 global wall.** The driver is portable over the POSIX and Windows rows and keeps both names of its
  armed publication until the durable one is bound ([ownership seam](ownership_seam.md#the-no-replace-publication)).
  The Win32-row suite compiles and runs on every gate host: on Windows its three row cases (absent origin,
  present origin, replacement) drive the production entry point against a temporary `USERPROFILE`, and
  elsewhere each asserts the row's refusal. Detail is in [WSL2](../engineering/wsl2.md).
- **Incus instance and shares.** The claim rides on the creating command, so where an interrupted
  transaction stands is a total function of the record, the provider's report, and the claim the
  instance carries. Provision answers AlreadyOwned only when the bound record carries this run's
  own claim; another run's bound instance is a conflict. Ready retries only a guest classified as
  not ready, and a failure or identity conflict ends the poll after one probe. Guest conflict markers
  carry both identity sides as bounded ASCII tokens under the emitter and parser's shared grammar.
  A delete whose bound instance is already gone re-enters its retained binding, validates its
  share records, observes absence afresh and retires the shares before its instance record.
  An interrupted launch that left a claimed unbound instance binds that identity before teardown.
  The forward route requires this run's claim; retained cleanup derives its claim from the record.
  A share's attachment re-observes the device on both sides of the attachment and the
  instance on both sides of the readback. Before instance deletion, every bound share device
  must still have its recorded identity or be absent. A changed device preserves the instance
  and every record. The instance is observed again after that bookkeeping, immediately before
  the guarded delete, so a replacement receives no destructive command. The instance's
  reported absence authorizes retirement of the validated child records. Durability is the protected store's compare-and-swap; the
  driver names no mutating filesystem primitive. The opaque `ManagedProviderHandle` and
  `ManagedProviderShareHandle` retain the exact backend origin. The restart a newly attached share needs
  is in [Incus](../engineering/incus.md).
  A bounded device-name digest of the binding's UTF-8 bytes alone does not prove the share binding: the owned transaction's exact
  device readback refuses a same-named device with another binding before mutation. Preparation also
  requires a declared provider dependency and its fresh successful backend reprobe.
- **Provider-guest durable alias.** `StrongAliasBackend` is derived only from the capability for the
  exact managed Running provider. Admission reads retained discovery without another probe: daemon
  and VM capability must be Ready; provisioning egress may be unavailable or not ready, but conflict
  and failure refuse. A blocked VM is reported under its own label, and Direct is Unsupported.
  The backend retains the capability generation, host configuration, project self reference and lift
  context for the shared shipped transaction. `ManagedGuestAliasHandle` hides the generic handle and receipt after
  settlement. The far-side publication is `link(2)` on Linux and `renamex_np(RENAME_EXCL)` on Darwin,
  because APFS refuses hard links to symbolic links; both are in `HostBootstrap.Ownership.Shipped`, outside
  the row record ([ownership seam](ownership_seam.md#what-each-owner-adds)). Retries converge across the
  unbound, bound-staging, and published windows, and destroy releases the exact identity before deleting
  the provider frame. A later prepared call for the same alias path and target that finds the exact link
  its record names settles as unchanged when the caller holds the prior commit proof, and as repaired
  otherwise. The settled handle's descriptive operation key can identify the committed journal record
  for verification against the exact admitted plan, resource and generation; the receipt itself stays
  private. No unused plan/provider owner text is carried alongside the shared alias/target record.
  Prepared release requires a positive version equal to the managed alias's retained observation
  version. Zero and stale versions refuse before entering the guest. Give-back rechecks the bound
  link identity, preserves a replacement and its record on conflict, and on success removes the
  alias and its record while retaining the durable target and protected authority directory.
- **kind cluster.** Every node is an owned object, because clause 3 binds one identity per record; a later
  cordon therefore addresses a node by its bound identity. The node observation asks the node's name of
  both the listing and the inspection, readiness carries the control-plane identity re-observed after its probe and advances its version only
  when that identity matches the cordoned handle, and
  release leaves a same-named replacement standing. Cluster cleanup refuses until the exposure relay has
  completed clause 4. Managed settlement retains the control-plane identity separately from its journal
  generation; a foreign result retains the actual observed identity without adoption. Stopped owned node
  containers remain bound, so recovery starts them or uses `project down` to release through the record.
  Backend capability fields contain only the retained configuration, driver and observation data;
  a source guard checks their exact types. Detail is in [cluster lifecycle](../engineering/cluster_lifecycle.md).
- **Direct Colima.** The `prepared` stage refuses an outcome-unknown present profile unless its retained
  claim and bound machine identity match a fresh observation; a matching managed stage also recovers it.
  Live Docker revalidates the same binding. The plan's statement of this boundary is
  [§ EE](../../DEVELOPMENT_PLAN/development_plan_standards.md#ee-opaque-capabilities-and-phase-indexed-lifecycle-state),
  owned by the
  [cluster lifecycle phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md); its live
  Apple lane belongs to the
  [Apple Silicon substrate phase](../../DEVELOPMENT_PLAN/phase-26-apple-silicon-substrate.md).

  Direct discovery admits a freshly detected Apple-silicon host and resolves the effective
  user's home from the OS account database. The production producer uses native observation
  after checking the bootstrap executable; fixture observations remain descriptive and cannot
  redirect that producer. Missing-Colima Brew evidence is distinct from ready-toolchain
  authority, and every acquisition, live Docker call and cleanup revalidates ready evidence
  immediately before and after its effects.

  Shared POSIX identity observation, directory/file creation and exclusive opening resolve
  each existing parent component through a retained no-follow directory descriptor. The final
  name is looked up or opened relative to that parent. Identity lookup still observes a final
  symbolic link as its own object, while a symbolic parent refuses before acquisition. The
  file's regular-kind check, whole-file synchronization and kernel-held lock lifetime remain.

  Shared POSIX publication retains both source and target parent descriptors and uses
  linkat without replacement. Removal observes the final name and calls unlinkat relative
  to that same held parent; parent synchronization fsyncs its held directory. Path-based
  manifest observation and raw-entry release open their root through the shared no-follow
  parent traversal, then retain the root descriptor for their existing identity checks,
  raw-name walk, synchronization and absence readback. A linked ancestor cannot redirect
  these operations into another directory.

  Before acquisition allocates the isolated Docker-config namespace, it lists Docker contexts
  when its retained stage is absent or earlier than ColimaContextStaged. The exact
  colima-<profile> name refuses with a profile conflict before namespace preparation or start;
  unrelated names do not collide. ContextStaged and later resumptions retain their already-owned
  context. The same pure stage-threshold and exact-name decisions drive the actual acquisition
  route. Command/report failures remain typed refusals and cannot reach later acquisition steps.

  Context cleanup decides presence from the Docker context listing. An unlisted owned name
  skips inspection and removal. For a listed name, cleanup re-enters the existing context-
  directory origin without acquisition, retains its actual identity and record version across
  inspection, and compares the resulting context fingerprint with the releasing record.
  A missing/replaced binding or different fingerprint refuses without context rm. After rm
  succeeds, a fresh listing must report the name absent before ColimaContextReleased is
  published; a still-listed name keeps the durable stage at ColimaReleasing.

  The private releaseManifestRemainder producer consumes the directory's live bound
  ownership token and a retained raw manifest entry. Release and durable-record capability
  checks precede native observation. The bound root must remain present and identical;
  only below that verified root may an absent leaf or intermediate descendant count as
  already released. A different present identity refuses. Exact removal stays descriptor-
  relative, synchronizes the held parent and reads absence back without decoding raw names.

  Cleanup captures the parsed retained manifest before the external delete and carries that
  value through settlement. It projects raw docker/ and colima/ entries relative to each
  bound root. Current remainders must match retained identity, kind, mode and any immutable
  content/link evidence; missing retained entries require no removal. New or changed entries
  refuse instead of acquiring release authority from observation. Home cache and tmp exclusions
  cover each complete subtree, and admitted entries release deepest-first through the private
  bound-root producer. A file introduced during delete therefore remains in place.

  Before cleanup enters Releasing, a matching Managed lineage may refresh metadata proof
  from the actual, strictly re-entered home, Docker-config, cache and temporary directories.
  The entry retains each binding identity/version across observation and publishes the
  canonical manifest before compare-and-swapping its Managed stage evidence. Unchanged
  proof preserves both record versions. An interruption between those two writes leaves
  Managed; ordinary readers refuse the incoherent proof until the Managed-only refresh
  reconciles it. Missing or malformed proof is never recreated by refresh. Releasing and
  later stages cannot refresh, so new or replacement release entries cannot broaden teardown
  authority. Acquisition still publishes its manifest before first becoming Managed.

  A fully Released record admits a later acquisition only with a different acquisition
  invocation and actual absence of home/context objects and every prior artifact origin
  and manifest record. The stage table returns BeginColimaLineage for that observation;
  this is a new Reserved transaction, not a backward advance of the completed stage graph.
  Its write compare-and-swaps the exact retained Released version. A foreign namespace or
  residual record refuses without adoption, and a completed acquisition invocation cannot
  replay. Repeated completed cleanup remains command-free; its old invocation cannot act
  on the new Managed transaction.

  Cleanup consumes the same stage table. Only an exact live profile wall/runtime,
  machine identity/epoch and retained profile/disk origin allow Managed to freeze into
  Releasing; its distinct cleanup invocation is durable before the table permits delete.
  Reported profile absence and kernel disk absence feed the subsequent settlement
  decisions. Docker-context absence and exact protected-stage versions remain required.
  Final namespace release first revalidates the retained home/cache/tmp bindings and
  absence of the already-released context and reported-object bindings. Repeating a
  completed cleanup verifies actual root and artifact-record absence before retaining
  Released without a tool command; foreign roots, residual records and incompatible
  partial stages refuse without reacquiring authority.

  Acquisition namespace preparation, Prepared start, evidence-bearing settlement and exact
  Managed re-entry consume the same total stage decision table. Fresh unclaimed namespaces
  must have no objects or artifact records; staged and Prepared directories re-enter their
  retained identity bindings. An already-present profile under Prepared refuses when its origin remains unbound. A matching
  retained claim and bound machine identity permit re-observation without a second start. Only an
  absent-profile start decision permits creation; successful start readbacks and joined artifact/wall proof
  provide the distinct created-profile observation used to publish Managed. Ordinary exact
  Managed re-entry consumes KeepColimaStage after its full observations.

  Docker-config parent directories below the protected plan root have shared origin records.
  Preparation creates each missing parent through the shared no-follow row inside the entry;
  an existing unrecorded parent refuses adoption. Later preparation and live start, artifact,
  settlement, Docker and cleanup paths re-enter the retained parent identities. Missing or
  replaced owned parents refuse, even if the context directory itself kept its inode.
  Parent keys derive from the relative component sequence with lossless length-prefixed
  character words, so profiles sharing a parent re-enter one binding. Cleanup checks those
  identities and removes empty created parents child-first, retaining any nonempty directory
  and its record for shared or foreign contents. Repeated completed cleanup does not recreate
  a parent. The prepared driver performs no recursive parent mkdir before ownership entry.

  The manifest walk retains its root and parent descriptors. Entry status comes from fstatat
  with AT_SYMLINK_NOFOLLOW, and link-target bytes come from readlinkat against that parent.
  The normal path observer brackets the root open and uses this same descriptor observer.
  Renaming the root and populating its old pathname cannot redirect the retained walk. Each walk
  opens an independent stream relative to its held directory, so read offsets do not leak between
  observations. A failed
  fdopendir closes its fresh descriptor; a successful stream closes the descriptor it owns.

  Manifest paths are raw bytes, validated by one POSIX slash grammar on every host. Directory
  names and link targets enter through raw descriptor-relative APIs; rendering hex-encodes the
  same bytes and parsing retains them without UTF-8 decoding. Locale and invalid UTF-8 names
  therefore cannot change the stored path. Diagnostics alone escape non-ASCII name bytes.

  Colima remainder cleanup rechecks its protected parent, then passes the retained root identity
  and observed entry to the shared POSIX raw-name primitive. The primitive checks the opened root
  and target identities, traverses raw components no-follow through held descriptors, and refuses
  foreign owners or unsafe entry kinds/modes. unlinkat, parent fsync and authoritative absence
  readback complete each removal. A replaced root, replaced target or symbolic parent refuses.

  The shared POSIX manifest observer records symbolic-link target bytes without walking their
  targets. It refuses writable directories, writable or multiply linked regular files, foreign
  owners and unsupported object kinds; immutable content is bounded to 4 MiB per file. File,
  directory, link and socket entries keep their declared kinds. Kernel cases assert these
  refusals exactly. The foreign-owner family probes a real owner change and reports its
  availability separately; Windows cases assert the native row's Unsupported answer.

  Trusted toolchain construction first applies the same content validator to native observations and
  decoded reports. Canonical tool/formula paths, positive identities and ordered helper-directory
  bindings are checked before settlement; a Colima version directory containing a path-list separator
  therefore cannot enter authority through the native route. The wire report itself is descriptive,
  and its exported constructors remain inside the private Colima component. Static tests distinguish
  exact content/framing refusals from the Windows native resolver's declared Apple-platform refusal.

  Native executable and directory observations use one total owner/mode policy. The production
  kind enforces system-root, Homebrew-user and Docker Desktop root-or-user ownership consistently
  for both entry kinds; writable modes and the explicit administrative-directory exceptions are
  checked in the same function. The fixture kind names its private effective-user-owned root rather
  than claiming production ownership. Production and fixture policy cases run on all gate hosts,
  while the Linux native fixture also resolves and settles under a saved/restored hostile ambient
  environment and working directory. A no-follow, close-on-exec descriptor supplies each admitted
  executable or helper-directory identity. Its kind, ownership and mode are checked, and its
  device/inode must agree with pathname observations before and after opening. An OS descriptor
  refusal yields unsupported output; a real child process tests this with a zero soft descriptor
  limit after warming a ready fixture.

  A shipped tool's supervisor keeps its own PID live while supervising from outside the tool's
  retained process group. That PID reserves the group's identifier until every possible group
  signal is finished. Tool exit quiesces remaining members before returning its status; parent
  death kills the group and supervisor. Generic timeout and cancellation escalation keeps the
  unreaped leader reserved until no later group signal can target a reused identifier. A null
  signal's permission or other probe failure cannot establish group absence. Teardown also checks
  that the process handle still retains the original leader; an already reaped handle authorizes no
  later group signal. Capture cleanup stops its reader threads before closing their handles.

  Retained ready and missing-Colima evidence is compared with fresh resolution through the same
  total pure classifiers that production IO revalidation calls. The private testing view exposes
  descriptive results without an authority value or callback into production resolution. Native
  fixture inode replacement and alias changes prove refusal and fingerprint sensitivity; the
  [reconciler contract](../engineering/ensure_reconcilers.md) names the exact outcomes.

## What the invariant excludes

Stating this exactly is part of the contract; any stronger claim is unsupported.

| Scenario | Outcome |
|---|---|
| A run crashes between the origin record and the first write | Recoverable. The next run reads the origin record and restores exact bytes or absence. |
| A run crashes after the first write | Recoverable, same mechanism. |
| Two concurrent `hostbootstrap` runs target the same state | Excluded. The second blocks on clause 1, then observes clause 3's identity. |
| A cooperating peer replaces the object with a different kernel identity between two operations | Detected. Clause 3 reports `Conflict`; clause 4 refuses release. |
| A hostile same-privilege process ignores the lock and replaces the object | **Not excluded.** A changed identity is detected on the next observation, unless the replacement lands in the release window below. |
| A same-privilege process replaces the object between clause 4's re-observation and the removal | **Not excluded.** Kernel-face release re-observes the identity and then removes the object by name inside the protected entry, which excludes only cooperating runs; a replacement in that window is removed rather than detected. |
| A removed object's kernel identity is recycled for a replacement with the same checked payload | Not distinguishable by the recorded identity and payload alone. |

An advisory lock can be ignored by a process that chooses to, and no substrate in scope offers a
mandatory one for these objects. Kernel identities describe live objects; the POSIX device/inode pair
is not a permanent generation identifier after unlink. Replacement tests retain the original object at
a sibling path while creating the replacement, so they prove refusal of a distinct live identity
without assuming the filesystem never recycles one. They do not establish detection of identity reuse.

## When a backend returns `Unsupported`

`Unsupported` is a real outcome, not a failure to try. A backend returns it — and mints no receipt —
when a clause is unsatisfiable on the host. The contract names three such conditions:

- the filesystem cannot report a stable object identity (clause 3);
- the lock cannot be taken because the platform or filesystem does not support it (clause 1);
- the state directory is not writable, so no origin record can be made durable (clause 2).

The seam answers `OwnershipUnsupported` in these cases:

- a row's capability declaration lacks what a clause needs. `clauseRefusal` applies the declaration
  before any kernel call, and the row a binary was not built for declares nothing, so every clause
  through it is refused;
- a Windows handle's filesystem is neither NTFS nor ReFS, or its volume query reports that it is unsupported;
- the protected store cannot supply its lock or accessible durable state: unsupported locking/IO and
  permission failures are ProtectedUnsupported, carried to OwnershipUnsupported by the shared storeFault;
- the filesystem refuses the hard link that atomic no-replace publication needs;
- the identity a host or authority answers is empty or longer than the vocabulary's ceiling;
- a record's kind does not match the producer it reaches: a file record offered to directory creation, a
  directory record offered to file publication, a reported-object record offered to either, or a payload
  that is not the one the record's digest names;
- a symbolic-link act, or the direct-Colima manifest observation, reaches a Windows binary.

The Windows row queries the filesystem on its already-open no-follow handle with
[GetVolumeInformationByHandleW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getvolumeinformationbyhandlew)
before admitting NTFS or ReFS. An absent target admits its nearest existing parent through that same
identity path before returning authoritative absence. The row requires the full FILE_ID_INFO volume
serial and 128-bit identifier. This is a filesystem admission policy, not a claim about any untested ReFS/FAT volume.
Required store acquisition/mutation classifies FileLockingNotSupported, UnsupportedOperation IO errors
and permission denial as ProtectedUnsupported. Blocking/nonblocking entry, store opening and liveness-lock acquisition
catch only the supported synchronous exception families; unrelated exceptions and cancellation propagate.
Record writes, deletes and writability checks share that classification through the mutation adapter.
Ordinary record reads and listings retain probe failures, including a non-file record path that Windows
reports as permission denied.
The shared ownership carrier preserves this as OwnershipUnsupported. Missing-path IO failures retain
ProtectedIOFailure, including the read APIs' existing explicit absence handling.

`Unsupported` carries the attempted operation and the reason. It is distinct from `Conflict` (an
identity mismatch), `SafetyRefusal` (a policy decline), and `Failure` (an IO fault); observation is
total, so these never collapse into one branch. See
[lifecycle state model](lifecycle_state_model.md) for the full error algebra.

## Why all four clauses are required

An "OS-protected namespace plus an identity-bound conditional mutation/delete" is a statement about a
*platform primitive*, and no platform in scope supplies one for these objects. It is not the governing
contract for three reasons:

1. **It is uniformly unavailable.** Backend discovery would return `Unsupported` on every substrate, so a
   typed ownership path could not be reached. A rule that no backend
   can satisfy enforces nothing.
2. **A platform-specific shim breaks uniformity.** A Windows-only native shim would make one substrate
   authoritative and the others not — the opposite of what a
   uniform contract is for.
3. **A privileged broker has unbounded scope.** Such a service is a large, platform-specific,
   security-sensitive surface bought for a guarantee the contract cannot honestly deliver uniformly.

The four-clause protocol keeps the load-bearing properties — crash recovery, exclusion of cooperating races,
and refusal to clobber — and expresses them identically on all substrates. It does not claim exclusion of a
hostile same-privilege process.

## Validation

The invariant is proved by the criteria below. They are not `os(windows)`-gated: a uniform contract
requires a uniform gate, so the ownership suite runs on every substrate, and a case whose subject is
unavailable on the gate host asserts the refusal its row declares rather than disappearing. What counts as
evidence for each criterion — and what cannot — is in [testing](../engineering/testing.md).

1. An adversary replaces the object with a distinct kernel identity between observation and mutation. The backend reports `Conflict`
   with structured expected/observed identity, does **not** clobber the object, and mints no receipt.
2. Release is refused when the observed identity does not match the receipt's.
3. A second entry attempt is excluded while the lock is held, and succeeds after the holding process is
   killed (proving the OS released it).
4. A child that remains alive across `exec` cannot retain the parent's lock; the parent leaves its extent and
   immediately reacquires it while the child is still running.
5. A kill between the origin record and the first write leaves recoverable state, including the
   **absent-original** case: the next run restores absence rather than treating generated content as
   the original.
6. A clean-path run reaches absence, creates the object, and reruns over it on every supported substrate.
   A later call that finds the exact object its record already bound settles `Unchanged` through
   `completePreparedUnchanged` when the caller passes the `PriorCommitProof` of an earlier settlement, and
   `Repaired` without one, as [durable state](durable_state.md#root-authority-and-alias-target) states for
   the provider-guest alias.
7. An unsatisfiable clause returns `Unsupported` with its reason, and no receipt is minted.

A foreign provider settlement exposes only descriptive identity, generation and observation through
its foreign branch; it grants no managed wrapper or receipt. Tests of that branch assert its settled
detail and generation. A prepared binding's owner text is descriptive input, so an assertion over that
text is labelled separately from ownership evidence returned by settlement. The
[lifecycle validation table](lifecycle_state_model.md#validation) identifies the relevant boundary.

Validation status and scheduling belong to
[the development-plan index](../../DEVELOPMENT_PLAN/README.md); dated evidence lives with the sprint
whose gate produced it.

## Related

- [ownership seam](ownership_seam.md) — the one transaction, the seam beneath it, and the rows that
  supply each clause's mechanism.
- [lifecycle state model](lifecycle_state_model.md) — the handle/receipt/phase algebra a satisfying
  backend settles into, and the total error branches.
- [durable state](durable_state.md) — the provider-guest durable alias.
- [WSL2](../engineering/wsl2.md) — the global `.wslconfig` wall.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — the kind cluster, whose records bind each
  node container's identity, and its exposure relay.
- [harness workflow](harness_workflow.md) — the run's `.test_data` root and generated config.
- [Incus](../engineering/incus.md) — the provider lane that holds all four clauses through the reported
  face; [Lima](../engineering/lima.md) — the recorded guest-VM realization in the
  [matrix](#per-backend-clause-matrix).
- [development_plan_standards.md § EE](../../DEVELOPMENT_PLAN/development_plan_standards.md#ee-opaque-capabilities-and-phase-indexed-lifecycle-state)
  — the plan's restatement of the clauses.

A local directory can enclose dependent work through the opaque `ShippedDirectoryLease`.
`withShippedDirectoryLease` uses the ordinary shipped directory acquisition, reads its bound record
from the same protected entry, and keeps that entry open throughout its callback.
`useShippedDirectoryLease` checks that thread's live entry and the directory's current kernel identity
before and after an action. An escaped closure or another thread receives a refusal before the action.
This lease preserves directory ownership across a dependent transaction; it does not release the
directory when the callback ends.
The guest-VM transaction composes that directory lease with a distinct protected reported-object
entry. Its shared tape records absence before creation and binds Lima's real instance-directory
identity or WSL's native registration GUID. The creation claim remains an independent check:
Lima carries it in creation environment metadata; WSL must occupy the exact owned install location.
Dependent effects re-enter the stored binding, recheck the claim and native identity before and after
execution, and run under the parent's lease. Failure retains an unbound origin for explicit recovery.
The backend uses this transaction for provisioning, readiness, share probes, daemon discovery and
bound guest work. Its daemon request admits only the fixed provider probe vector. WSL's global
resource wall retains its separate typed owner.

The Colima ownership driver lives in the private `colima-ownership-internal` library.
Its interpreter-taking entry points are available only to the owning adapter and private tests;
the public `HostBootstrap.Ensure.Colima` adapter supplies the retained trusted resolver.
The HostConfig-taking wrappers have been removed. The descriptive Command and Report modules
remain available through public reexports. Static tests exercise private policy and native
protected-store operations; the public Apple toolchain chain still requires Apple Silicon acceptance.

Provider-wall observations share one declaration in the private wall-observation-internal leaf.
The public budget API reexports the same six descriptive constructors through its hidden kernel.
The leaf depends only on base and the shared refusal vocabulary; it carries no settlement permit
or plan-indexed authority. Private backend policy can classify failures without importing the
public budget authority implementation.

Direct-Colima acquisition classifies mutation faults in the private ownership driver. A conflicting
profile or mismatched ownership origin is a refusal that leaves the namespace untouched. Entry,
command, report, start and delete failures carry ReprobeBeforeRetry. The public adapter passes the
complete expected wall description to that pure classification and retains only the closed
backend's successful ownership observation for settlement.

Colima owner tokens, origin filenames, acquisition and invocation digests, and namespace/toolchain
owner binding share one private pure identity algebra. The public adapter projects its actual plan,
prepared wall, journal gate and retained backend into that algebra. Domain tags, canonical UTF-8/NUL
framing, field order and the four owner-binding digest groups are fixed protocol data; the resulting
strings carry no authority until the owning backend and exact settlement joins admit them.

Colima cleanup authority comes only from the exact opaque settled live wall. Its eliminator
retains the complete owned backend observation, wall epoch, managed Running handle, matching
receipt and reservation fence as one package. The private cleanup driver checks owner, lineage
and acquisition invocation before replay, namespace admission or destructive work. Pure lineage
refusal and the native fixture-backed live-wall eliminator are covered statically; neither
descriptive admission nor a raw observation grants deletion authority to a public caller.

The cleanup driver's first decisions are lineage admission and a closed durable-stage retry
classification. Refusal returns before context admission or destructive work. A Released replay
uses the existing conditional absence checks rather than entering the deletion path; a Releasing
retry must name its already committed cleanup invocation. The decision constructors are private
descriptive values, separate from the opaque public cleanup authority.

Colima release recovery uses the shared `resumeReportedRemoval` boundary. A fresh absence can finish
record cleanup; a surviving or replacement disk, changed profile binding or changed stage refuses.
The frozen manifest permits only missing retained entries with unchanged remaining identities and
metadata, while the bound home and Docker-config roots are revalidated. Ordinary Managed standing
continues to require the complete exact manifest. These decisions grant no public deletion authority.

Colima directory readers and release share one created-directory binding policy. A retained record
must describe an absent-origin, identity-bound directory. Recovery never removes a replacement or
claims an unrecorded present directory. The shared kernel producer supplies the live-entry,
capability, fresh-absence and parent-sync obligations before the versioned record is forgotten.

The managed Colima Docker route first reads and admits its retained stage and lineage before
parent validation, context-directory acquisition or command work. Released, in-progress release,
missing and mismatched stages therefore cannot recreate a context or origin. Actual protected-store
cases hold the records unchanged, and source-flow checks connect that admission to the driver.
Context removal shares the pure delete-completion decision; failure retains the releasing stage
and context ownership, while successful strict absence readback precedes ContextReleased.

ContextReleased is a committed retry stage for the same cleanup invocation. Fresh completion and
that retry share one kernel-only context namespace settlement: it checks the exact held stage and
version, retained manifest evidence and parent bindings, then removes only unchanged retained
entries and the bound created directory. Already removed directories settle their origins through
the shared absence/sync boundary. Replacements or added entries preserve their objects and records.
The durable transition to Released follows successful context settlement. Static cases exercise
actual temporary kernel objects and protected records; public provider commands remain live evidence.

Fresh Released settlement and exact replay share one kernel-only namespace finisher. It verifies
the actual held stage/version, committed manifest evidence and every remaining root binding before
removing retained entries, then settles temporary, cache and home origins child-first. The manifest
is forgotten only at its retained version, after all owned roots settle. Missing evidence authorizes
no deletion: only actual complete vacancy can finish without a manifest. Scaffolding is removed
through retained identity-bearing manifest entries. Empty retained parents release conditionally;
a removed parent's origin recovers over fresh absence, while shared or replaced parents remain.

### Cluster generation claims

Cluster and node standings compare the exact expected plan-generation claim with the reported-object
record before accepting an unbound or bound standing. A matching container identity cannot make another
generation's record this plan's own. Retained cleanup reads the stored claim and carries it through the
same standing and node checks; it does not derive a new owner string from the claim's digest. Before
forgetting an origin-recorded cluster, every existing node record passes the same kind, claim and absent-
origin validation, so a refusal leaves the whole record set intact. An unbound record after an interrupted
create still has a residual adoption window: the driver namespace is not reserved, and a later same-named
cluster can be classified created-unbound before an identity is bound.

Cluster node binding commits workers before the control plane. A cluster root that is already bound
still re-observes each declared worker. A matching generation's published, unbound worker origin is
bound to the actual observed identity and reconciliation reports recovery; a missing record, different
claim or replacement identity remains a refusal. Retained transactions carry the stored claim through
this same worker recovery, so recovery never substitutes a newly derived generation owner.

Cluster ownership transactions are compiled in the Cabal-private `cluster-ownership-internal` library.
The main library reexports the command, report, standing, cordon and interpreter modules that consumers
need, while `HostBootstrap.Cluster.Ownership` remains inaccessible to downstream components. The backend,
bare live gate and internal test suite depend on the one private implementation; no copied test module
or downstream constructor grants a route around prepared backend entry.

Cluster fixture answers are authored protocol models. Distinct tool-named executables make a vector
sent to the wrong model tool fail before its fixture state changes. This establishes fixture routing
and compatibility; provider agreement comes from the actual cluster-live gate. Fault rendering is
checked directly over every fault constructor, and credential fixture assertions compare bytes.

Protected records and private cluster credentials share the private publication primitives for data sync,
atomic same-directory replacement and namespace durability. Windows replacement requests write-through;
POSIX syncs the parent, and Darwin also requests the stronger device-cache flush. A failed requested flush
refuses. Reconciliation publishes the exact Kind credential before binding nodes and refreshes it on an
already-owned entry, retaining private temporary-file permissions and propagating publication failures.

A refused cluster create re-observes both the actual cluster listing and its control-plane container
inside the same protected entry. Only authoritative absence of both permits retiring the published
unbound origins, after the shared generation-claim preflight. A standing object or failed observation
preserves those origins. Successful retirement leaves a later same-named cluster under no record, so
reconciliation refuses it as foreign instead of adopting the failed attempt's namespace.

Cluster release shares the ordinary record-kind, generation and prior-origin validation. Its total
classification also admits an absent bound container as an interrupted removal. That admits record
cleanup over fresh absence through `resumeReportedRemoval`; it supplies no present-object observation.
A surviving bound node provides the actual identity check before any repeated delete. All declared
nodes are re-observed, worker records retire first, and the root binding survives partial record cleanup.

A retained cluster plan supplies coordinates, not proof of a previously owned object. The backend checks
actual record presence under the protected entry before delegating release; absent metadata cannot
establish retained ownership. Direct release can still finish orphan metadata over actual absence.
The shared node-removal classifier distinguishes absence, the same surviving bound identity and a
replacement, and a replacement or an unclaimed present node authorizes no record retirement.

Driver admission retains every client needed to create, observe and remove the owned cluster. Selecting
nvkind for creation does not remove Kind from the declaration: ownership listing, credential readback
and deletion still use Kind. Admission derives the required tools from the described command catalog
and includes the chart client, and a missing resolved tool mints no backend capability.

Cluster target admission validates complete encoded ownership addresses before storage entry. The
retained reverse uses the same target constructor as forward calls, preserving the control-plane root
record and each worker's canonical tuple key. Address failure grants no entry and creates no partial
ownership namespace; the protected store remains the single authority for key encoding and bounds.

The cluster backend holds one protected entry across already-owned reconciliation and its running-state
check. A second compliant owner cannot replace the durable binding between those observations. Both
checks use the same generation-bearing descriptor and session; the resulting observation carries the
identity classified under that entry.

Ownership manifest entries expose read-only accessors. Prefixing and namespace projection rebuild
each entry through the validating constructor, retaining the raw path bytes and refusing an
over-long or noncanonical result.

An Incus owned-share observation reads the bound record and device without attaching or repairing either;
it verifies the owned parent identity before and after the device read.
