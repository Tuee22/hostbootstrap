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
`HostBootstrap.Ownership.Object`: the kernel's identity answer, the bytes a run intends to install and
their digest, what is owned and what was there before, the durable origin record with its one canonical
codec, and the closed fault sum with its total eliminator. See
[ownership seam](ownership_seam.md#the-vocabulary) for what each carries and why.

The [per-backend clause matrix](#per-backend-clause-matrix) is the one statement of which backend holds
which clause and how. Every backend in it holds all four clauses except two:

- **The Direct provider realization holds none, by design.** It admits the already-local host by
  observing it, publishes no origin, never claims the host, and answers stop and delete with
  `Unsupported`, so it mints no receipt that would need the clauses.
- **The Lima and WSL2 guest-VM provider realization holds none, and that is a gap.** Its provisioning
  probes whether an instance with the configured name exists and reports a present one as already owned
  (`ProviderProvisionAlreadyOwned`), with no origin record, no owner claim, and no bound identity, so a
  pre-existing, unrelated instance with that name is adopted as managed. Holding the clauses over that
  realization, or refusing an unclaimed instance, belongs to the
  [host providers and lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md).

Four further gaps sit between the contract below and the tree:

- **`Unsupported` covers fewer cases than [the contract](#when-a-backend-returns-unsupported) names.**
  The Windows row reads the volume serial number and file index without checking the filesystem type,
  so a non-NTFS volume is trusted rather than refused. An unavailable lock or an unwritable state
  directory surfaces as a store fault (`OwnershipProbeFailed`), not as `OwnershipUnsupported`. Both
  belong to the
  [ownership clauses and reservations phase](../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md).
- **The seam's re-entry and record tape trust the caller.** Re-entry accepts any bound record a caller
  presents, and the tape replaces a stored binding rather than refusing it;
  [ownership seam](ownership_seam.md#current-status) states both and names the same phase.
- **Harness recovery does not yet settle every crash window.** The data root's recovery of an unbound
  absent-origin record (the window between clauses 2 and 3) removes whatever stands at the generation
  path, recursively, where the contract removes only an empty directory and reports a non-empty one as a
  conflict. For both harness owners, a bound record whose object is already gone (a kill between
  release's removal and its forget) is reported as a conflict on every later recovery, where the contract
  settles it as already absent; and the generated config's unbound-window recovery leaves the record
  standing. All three belong to the
  [ownership clauses and reservations phase](../../DEVELOPMENT_PLAN/phase-14-ownership-clauses-and-reservations.md).
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

### 2. Durable origin record before the first write

Before the first mutating call, the backend durably records either the exact original bytes **or** an
explicit absence marker, keyed by a generative nonce. Absence is a recorded fact, never an inference
from a missing backup. This clause is what makes restore correct after a crash between the first write
and the run's completion — without it, a retry can record generated content as the original and
teardown then restores that content instead of the user's state.

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
| [`HostBootstrap.Cluster.Ownership`](../../core/hostbootstrap-core/src/HostBootstrap/Cluster/Ownership.hs), joined to the plan by [`HostBootstrap.Cluster.Backend`](../../core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs) — reported face | a kind cluster and every node container | the protected store under the plan's state directory, entered once per call except an already-owned reconcile, which enters twice (see [Current Status](#current-status)) | one record per node over explicit absence, all published before `kind create cluster` | each node container's runtime-reported identity | every node re-observed, the cluster removed through the one interpreter, each record forgotten only over a reported absence | anything at the name that no record claims is a conflict |
| [`HostBootstrap.Cluster.Backend`](../../core/hostbootstrap-core/src/HostBootstrap/Cluster/Backend.hs) — protected-store records written directly | the cluster-adjacent exposure relay container | the cluster's protected-store entry | a nonce- and specification-bound pending record, published before `docker container run` | the inspected relay container identity and every runtime-selected loopback mapping | name, identity, labels, generation, operation, and mapping set re-inspected; record forgotten only after the identity is absent | a replacement, wildcard, missing or extra mapping, or changed target is a conflict |
| [`HostBootstrap.Ensure.Colima.Ownership`](../../core/hostbootstrap-core/src/HostBootstrap/Ensure/Colima/Ownership.hs) — both faces | one 128-bit plan/lifecycle namespace and its isolated Colima profile | the protected-store entry; the reusable profile-global lock is synchronization only | a reserved stage record binding the owner token, the lineage digest, and the invocation digest, published before any namespace object exists | the Colima home, Docker config, root/data wall, machine and context, every required artifact, and a directory-chain digest, retained as the managed stage's evidence beside a retained namespace manifest | the stage advances to `ColimaReleasing` with the cleanup invocation digest, and the retained manifest is revalidated against the live home and Docker config, before `colima delete --force --data`; the machine and disk identities are re-observed first and their absence proved after; the home's remaining entries, other than its cache and tmp directories, are then each removed by re-observed identity | foreign profiles, copied records, replacements, and partial foreign stages are conflicts |
| [`HostBootstrap.Substrate.Provider.Backend`](../../core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs) — Direct realization | the already-local host | none | none: no origin is published | none | stop and delete answer `Unsupported` | admitted by observation and never claimed |
| [`HostBootstrap.Substrate.Provider.Backend`](../../core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Backend.hs) — Lima and WSL2 realization (`StrongLimaBackend`) | a Lima instance or a WSL distro | none | none | none: existence is a name-membership probe | stop and delete through a forward handle answer `Unsupported`; reverse belongs to the plan's retained step-declared adapter | **reported as already owned** — the gap [above](#current-status) |

What each owner adds beyond the shared mechanism:

- **Harness data root.** The parent `.test_data` is scaffolding: created if missing, never owned, never
  removed. A confirmed generation's content is cleared only after clause 4's re-observation and before the
  seam removes the directory. The enclosing Harness close is described in
  [harness workflow](harness_workflow.md). By contract, recovery of the window between clauses 2 and 3
  removes the generation only when it is an empty directory, because the dead run bound nothing and wrote
  nothing into it, and a bound record whose directory is already gone settles as already absent; the
  tree's departure from both is under [Current Status](#current-status).
- **Generated config.** Recording the payload digest before the write is what makes the crash window
  between the record and the identity binding resolvable without adopting bytes the record does not name.
  No pathname sidecar participates.
- **WSL2 global wall.** The driver is portable over the POSIX and Windows rows and keeps both names of its
  armed publication until the durable one is bound ([ownership seam](ownership_seam.md#the-no-replace-publication)).
  The Win32-row suite compiles and runs on every gate host: on Windows its three row cases (absent origin,
  present origin, replacement) drive the production entry point against a temporary `USERPROFILE`, and
  elsewhere each asserts the row's refusal. Detail is in [WSL2](../engineering/wsl2.md).
- **Incus instance and shares.** The claim rides on the creating command, so where an interrupted
  transaction stands is a total function of the record, the provider's report, and the claim the
  instance carries. A share's attachment re-observes the device on both sides of the attachment and the
  instance on both sides of the readback. Durability is the protected store's compare-and-swap; the
  driver names no mutating filesystem primitive. The opaque `ManagedProviderHandle` and
  `ManagedProviderShareHandle` retain the exact backend origin. The restart a newly attached share needs
  is in [Incus](../engineering/incus.md).
- **Provider-guest durable alias.** `StrongAliasBackend` is derived only from the capability for the
  exact managed Running provider, and `ManagedGuestAliasHandle` hides the generic handle and receipt after
  settlement. The far-side publication is `link(2)` on Linux and `renamex_np(RENAME_EXCL)` on Darwin,
  because APFS refuses hard links to symbolic links; both are in `HostBootstrap.Ownership.Shipped`, outside
  the row record ([ownership seam](ownership_seam.md#what-each-owner-adds)). Retries converge across the
  unbound, bound-staging, and published windows, and destroy releases the exact identity before deleting
  the provider frame. A later prepared call for the same alias path and target that finds the exact link
  its record names settles as unchanged when the caller holds the prior commit proof, and as repaired
  otherwise.
- **kind cluster.** Every node is an owned object, because clause 3 binds one identity per record; a later
  cordon therefore addresses a node by its bound identity. The node observation asks the node's name of
  both the listing and the inspection, readiness re-enters the records on both sides of its probe, and
  release leaves a same-named replacement standing. Cluster cleanup refuses until the exposure relay has
  completed clause 4. Detail is in [cluster lifecycle](../engineering/cluster_lifecycle.md).
- **Direct Colima.** The pre-call `prepared` stage cannot adopt a present profile after an
  outcome-unknown start; only a matching managed stage recovers it, and live Docker reacquires the same
  binding. The plan's statement of this boundary is
  [§ EE](../../DEVELOPMENT_PLAN/development_plan_standards.md#ee-opaque-capabilities-and-phase-indexed-lifecycle-state),
  owned by the
  [cluster lifecycle phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md); its live
  Apple lane belongs to the
  [Apple Silicon substrate phase](../../DEVELOPMENT_PLAN/phase-26-apple-silicon-substrate.md).

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
- the filesystem refuses the hard link that atomic no-replace publication needs;
- the identity a host or authority answers is empty or longer than the vocabulary's ceiling;
- a record's kind does not match the producer it reaches: a file record offered to directory creation, a
  directory record offered to file publication, a reported-object record offered to either, or a payload
  that is not the one the record's digest names;
- a symbolic-link act, or the direct-Colima manifest observation, reaches a Windows binary.

Two parts of the contract's list are not realized as `OwnershipUnsupported`. The Windows row trusts the
volume serial number and file index on every volume without checking the filesystem type, so a volume
whose file index is not stable is not refused. A lock that cannot be taken, or a state directory that
cannot be written, surfaces as the store fault `OwnershipProbeFailed`. The gap is stated under
[Current Status](#current-status).

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
  face; [Lima](../engineering/lima.md) — the provider lane that holds none, per the
  [matrix](#per-backend-clause-matrix).
- [development_plan_standards.md § EE](../../DEVELOPMENT_PLAN/development_plan_standards.md#ee-opaque-capabilities-and-phase-indexed-lifecycle-state)
  — the plan's restatement of the clauses.
