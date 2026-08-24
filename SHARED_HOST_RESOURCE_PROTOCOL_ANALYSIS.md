# Shared Host Resource Protocol Analysis

**Status**: Proposal review; non-authoritative
**Reviewed proposal**: [Finite Resource Execution Authority Protocol](documents/engineering/shared_host_resource_protocol.md)
**Repository scope**: `hostbootstrap`

> **Purpose**: Assess whether the proposed shared host resource protocol is a sound direction for
> `hostbootstrap`, identify the correctness and integration questions that must be resolved, and
> recommend a smaller path to an implementable first version.

## Executive Summary

The proposal addresses a real gap. `hostbootstrap` already has project-plan admission, resource
budgeting, prepared operations, durable lifecycle recovery, ownership receipts, and several applied
provider or container walls. It does not yet have one machine-global authority that lets several
participating project binaries safely arbitrate the same finite host resources. A protocol that joins:

```text
pure requirement fit
  + live kernel-backed custody
  + applied and read-back enforcement
  = permission to launch governed work
```

is therefore a useful direction.

The proposal is not ready to become an authoritative `hostbootstrap` contract or an implementation
plan in its current form. The principal issues are:

1. the protocol depends on a lifetime-exclusive resource-cell lock, but no cell-lock object or type is
   actually defined;
2. recovery is indexed primarily by project parent scope, which does not safely cover a different
   project reusing a cell left dirty by a crashed predecessor;
3. independent reimplementation in every project conflicts with `hostbootstrap`'s L0/L1/L2 reuse
   architecture;
4. the proposed `Program`, journal, authority, and receipt hierarchy is not composed with the existing
   `ProjectPlan`, `RunLease`, `PreparedGate`, protected store, and ownership machinery;
5. persistent `project up` followed by a later `down` or `destroy` is not fully represented by the
   parent-lock and claim-key protocol;
6. the privileged installer, permission model, project authentication, and operator recovery surface
   are unspecified;
7. claim and catalog tombstones grow without a defined bound;
8. MPS recovery is modeled more locally than NVIDIA's documented failure domain permits; and
9. the document is not yet integrated into this repository's documentation or development-plan
   governance.

The appropriate disposition is to retain the design as a draft direction, repair the protocol-level
holes, and rebase it onto `hostbootstrap`'s existing lifecycle interpreter. A first implementation
should be narrower: Linux, participating trusted binaries, post-Haskell-handoff work, cgroup-v2
CPU/RAM containment, and whole-GPU or distinct-MIG-GI exclusion. Darwin, Windows, and MPS should be
added only through separate mechanism-specific acceptance gates.

## What the Proposal Gets Right

Several ideas should be preserved.

### A bounded guarantee

The proposal does not claim that a cooperating library can control an administrator, an unrelated
container runtime, or every foreign process on an open workstation. Its distinction between
`ParticipatingProjects` and `WholeHost` is important. It also correctly refuses to relabel reactive
monitoring as a hard wall.

### Fit, custody, and enforcement are different proofs

A request fitting a static budget is not proof that the budget is currently free. Holding a lock is
not proof that a cgroup, Job Object, VM, quota, or accelerator partition has been applied correctly.
An applied wall without host-global admission can still oversubscribe a machine. Requiring all three
facts before launch is the strongest part of the design.

### Physical identities, not scalar lock names

The proposal correctly models a CUDA device or MIG GPU Instance as a physical lock domain and device
memory as capacity supplied by that domain. A fabricated `CudaVramLock` would not correspond to a
kernel or hardware object. The whole-GPU/MIG hierarchy is also well chosen: distinct GPU Instances
partition memory resources, whereas Compute Instances within one GI share the parent GI's memory and
engines. This matches NVIDIA's [MIG concepts](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/latest/concepts.html).

### Crash recovery does not use a timeout as ownership

Permanent lock objects, kernel release on process death, durable `Prepared` state before effects,
identity readback, and fail-closed quarantine are preferable to deleting lock files or waiting for a
TTL. A timeout can indicate that investigation is needed; it cannot prove that a VM, process tree,
mount, quota, or GPU context is gone.

### Honest substrate strength

The distinction among admission-only, reactive, bounded-shared, hard-ceiling, exclusive, and
hardware-partitioned mechanisms is useful. In particular, the proposal avoids claiming that:

- a Docker or Kubernetes device selection reserves VRAM;
- a Windows affinity mask excludes foreign processes;
- a sparse disk maximum reserves backing storage;
- native Darwin supplies a hard descendant-memory wall; or
- MPS is equivalent to MIG.

## Protocol Correctness Concerns

### 1. The resource-cell lock is missing

The proposal says that per-cell locks carry lifetime ownership and that acquisition takes the selected
cell. The on-disk inventory, however, defines only:

- `epoch.lock`;
- `admission.lock`;
- one lock per registered parent scope; and
- hierarchical locks for observed physical domains.

There is no `cells/<digest>.lock`, no `CellLockKey`, and no cell case in the physical-domain kind.
This is not merely a missing line in the layout description.

Consider two project parents eligible for the same logical cell. The cell contains a RAM allowance and
a storage allowance on physical domains also used by other cells.

- If both parents take shared locks on the host-memory and storage-volume domains, they can both select
  the same cell and spend its scalar allowance twice.
- If both domains are locked exclusively, two different cells on the same host or volume cannot run
  concurrently, defeating the purpose of partitioning the host.
- The short-held admission lock cannot carry ownership after it is released.
- A parent lock excludes only another claim in that parent scope; it does not exclude a different
  project's parent from selecting the same cell.

The protocol needs an immutable catalog `CellId` and permanent exclusive cell lock. A reasonable fixed
inventory is:

```text
locks/epoch.lock
locks/admission.lock
locks/parents/<parent-id>.lock
locks/cells/<cell-id>.lock
locks/resources/<kind>/<domain-id>.lock
```

The canonical order must say where cell locks sit relative to ancestor and leaf domain locks. Cell lock
objects need the same no-replacement, file-identity, epoch, tombstone, and recovery rules as other
permanent locks.

### 2. Recovery needs cell-owned state

The proposed current allocation record is stored under a parent scope. That is sufficient to recover a
retry of the same parent, but not obviously sufficient when another parent or project next targets the
same cell.

For example:

1. project A acquires cell C and creates an enforcement domain;
2. A's anchor crashes, releasing its kernel locks while the effect remains;
3. project B later selects C under a different parent lock; and
4. B has no normative cell record directing it to A's exact stale effect bundle.

A generic live-capacity observation may notice some foreign usage, but that is not the same as locating
and reconciling the exact deterministic identities recorded by A.

The protocol should either:

- maintain one cell-owned current record, with parent records pointing to it; or
- require every admission to scan and reconcile the finite parent-record set while holding the
  admission and cell locks.

The first design gives the safety invariant a clearer durable home:

```text
one cell lock + one cell current record = one live or recoverable allocation
```

### 3. `DomainKind` is not a device identity

The Haskell sketch indexes `PhysicalDomain` and `LockKey` by a finite `DomainKind`. Two CUDA devices,
two storage volumes, or two CPU partitions therefore share the same type-level kind. A value can still
carry a UUID at runtime, but the sketch does not demonstrate its claimed compile-time rejection of
substituting one device for another.

The type shape should distinguish classification from identity, for example:

```haskell
data PhysicalDomain host boot capabilities (kind :: DomainKind) domainId
data LockKey host boot epoch capabilities kind domainId
```

The observer should mint `domainId` generatively after validating the stable physical identifier.

### 4. Fixed lifetime bundles conflict with whole-GPU time-sharing

The proposal forbids lock-bundle expansion and holds the complete resource bundle until terminal cleanup.
It also says that projects can take turns on a whole GPU while keeping CPU-side clusters or services
alive. Those two statements require an additional algebra.

A long-lived cell containing both CPU resources and a whole GPU cannot release only the GPU and later
reacquire it without shrinking and expanding the live bundle. The design needs one of:

- a long-lived base-cell lease plus a separately admitted, phase-scoped accelerator sublease;
- distinct registered parent scopes for persistent services and accelerator work, with their possible
  concurrency charged into the catalog; or
- a deliberate rule that the whole cell, including CPU services, is serialized whenever the GPU is
  serialized.

The first option is the most flexible, but it requires a bounded nested-acquisition protocol and an exact
deadlock rule. It cannot be implied by the current `Lease` type.

### 5. Idempotency and catalog history are unbounded

The proposal requires every completed `ClaimKey` to remain spent forever and every retired lock object to
remain as a permanent tombstone. Serial workloads and catalog revisions can therefore consume unbounded
storage and inodes.

For a parent scope that permits only one live claim, a monotonic generation can bound the durable state:

- retain a high-water mark for completed generations;
- reject every generation at or below that mark;
- retain detailed receipts only for a documented bounded window; and
- define whether callers are entitled to retrieve an arbitrarily old receipt or merely receive
  `AlreadySpent` after compaction.

Catalog lock tombstones need a separate bound or an explicit authority-root migration/reset operation
performed only while the epoch is exclusively held and all effects are proven absent.

### 6. Rounding behavior needs one rule

The arithmetic section says provider or filesystem rounding is derived deterministically and charged
before admission. The acquisition section later says to refuse upward rounding. Those are different
contracts.

The safety rule should normally be:

```text
effective rounded wall <= admitted cell offer
```

An effective value larger than the user's raw request can be safe when the rounded value was calculated
and charged before admission. If exact equality is a product requirement, the proposal should state that
as a stricter policy rather than as a resource-safety necessity.

## Integration with Existing `hostbootstrap` Architecture

### 7. Independent implementation conflicts with the library hierarchy

The proposal forbids a common package and requires `hostbootstrap`, `jitML`, `infernix`, and `amoebius` to
implement the same protocol independently. The canonical
[library hierarchy](documents/architecture/library_hierarchy.md) instead defines:

```text
hostbootstrap-core (L0) <- daemon-substrate (L1) <- jitML / infernix (L2)
```

The repository's [one effect interpreter](core/hostbootstrap-core/src/HostBootstrap/Effect/Interpreter.hs)
exists specifically so every consumer does not write a locally divergent answer to the same host effect.
Duplicating a safety-critical lock, codec, journal, and recovery implementation in each L2 project would
reverse that design.

A better ownership split is:

- `hostbootstrap-core` implements the protocol for its direct and transitive consumers;
- L1/L2 projects contribute their own demand derivation and closed workload description;
- `amoebius` may implement the frozen ABI independently when implementation diversity is desired; and
- black-box interoperability tests exercise the independent implementations against the same host objects.

Independent conformance is valuable. Four production copies are not required to obtain it.

### 8. `Program` must not become a second orchestration representation

The proposal sketches a `Program` with a sole effect interpreter. `hostbootstrap` already has one admitted
project representation and interpreter:

- `ProjectPlan` supplies the exact plan and topology;
- `Chain` interprets the current frame;
- the rooted lifecycle coordinates frames;
- `HostCommand` is the closed host-effect vocabulary; and
- the effect interpreter owns command resolution and launch.

The resource protocol should wrap that route. It should not introduce a second AST describing the same
work. A suitable relationship is:

```text
ProjectPlan + validated local workload projection
  -> derive local HostRequirement
  -> acquire ResourceCellLease and apply envelope
  -> mint ResourceExecutionPermit
  -> run the existing Chain / rooted lifecycle / effect interpreter
  -> settle existing lifecycle and ownership receipts
  -> retire the outer allocation and release the cell
```

If `Program` is intended only as private typestate for the outer acquisition/enforcement/release bracket,
the document should say so and should not present it as another workload language.

There is also a current implementation gap. `StepAction` is presently:

```haskell
forall scope planId. StepExecution scope planId -> IO StepObservation
```

in [HostBootstrap.Step](core/hostbootstrap-core/src/HostBootstrap/Step.hs). An arbitrary `IO` callback does
not meet the proposed claim that every raw launch path is mechanically unreachable. Achieving that claim
would be a substantial extension-surface redesign, not a thin adapter. The proposal should either scope the
guarantee to already closed core effects or explicitly plan that redesign.

### 9. The two durable protocols need an exact crosswalk

The proposal introduces project identity, parent scopes, claims, leases, applied envelopes, execution
authority, allocation records, and resource receipts. `hostbootstrap` already has installed identity,
project modes, run leases, broker generations, sessions, fences, prepared operations, provider-wall
authority, resource records, ownership receipts, and lifecycle receipts.

Before implementation, the design needs a crosswalk for at least:

| Proposed outer concept | Existing `hostbootstrap` concept or required relationship |
|---|---|
| `ProjectId` | installed project identity and executable identity |
| `ParentScopeId` | Production/Harness mode and any independently admitted role |
| `ClaimKey` / generation | durable run, invocation, attempt, and broker-generation identity |
| `Requirement` | `PlannedWorkloadSet`, `VerifiedWorkloadFit`, and project-specific demand |
| `Lease` | outer host allocation held around, but not replacing, `RunLease` |
| `AppliedEnvelope` | provider, cluster, cgroup, VM, or Job Object wall authority |
| outer `Prepared` record | ordering relative to `PreparedGate` and ownership origin records |
| `ResourceReceipt` | summary that references, but does not counterfeit, inner receipts |

The outer allocation journal should remain an arbitration record. It should not become a second owner that
generically deletes VMs, clusters, mounts, or provider resources from descriptive identifiers alone.
Recovery should:

1. reacquire the exact outer cell and domain locks;
2. authenticate and invoke the project's exact existing recovery interpreter where available;
3. directly clean only an enclosing enforcement domain whose ownership it can prove; and
4. quarantine anything whose inner ownership or outcome remains uncertain.

### 10. Persistent lifecycle commands need an anchor protocol

The proposal correctly notes that a VM, cluster, or service cannot borrow the invoking CLI's lifetime.
However, saying that a same-key retry may authenticate to the anchor is not yet a protocol.

For `hostbootstrap`, the following sequence must be defined:

```text
project up succeeds and returns
  -> workload and cell anchor remain live
project down or project destroy starts later
  -> later process authenticates to the exact anchor/claim
  -> teardown runs with the required resource authority
  -> enforcement domain becomes empty
  -> outer allocation is retired and locks are released
```

The specification must settle:

- whether `up`, `down`, and `destroy` share one durable claim;
- how the later verb discovers and authenticates the anchor;
- what happens if the anchor is alive but its IPC endpoint is unavailable;
- how broker-generation or executable upgrades affect attachment;
- whether `down` releases the cell when it preserves durable project data;
- how a later `up` obtains the next attempt generation; and
- whether `destroy` after a completed `down` needs a new, smaller cleanup cell.

Without this, `ParentScopeBusy` can prevent the command needed to release the persistent resource.

### 11. The initial Python bootstrap is outside the proposed authority

The [Python/Haskell boundary](documents/architecture/python_haskell_boundary.md) places toolchain
provisioning and the first native Cabal build before the project binary and validated `ProjectPlan` exist.
The Haskell protocol therefore cannot derive or govern that initial compiler/linker demand as currently
described.

The clean first boundary is:

> The shared host resource guarantee begins after the native project binary has been built, its installed
> identity has been validated, and its project plan has been admitted.

Nested bootstrap work performed after that point may be included. Governing the first Python/Cabal build
would require a separate pre-binary implementation and would materially change the Python/Haskell ownership
boundary.

### 12. Resource demand must remain optional and host-local

Current [resource budgeting](documents/engineering/resource_budgeting.md) deliberately treats a provider
budget as project-owned and optional. A consumer that targets an already existing remote cluster may have
no provider budget.

The outer protocol should therefore derive a local-host requirement from the effects that actually run on
that host. It should not add a universal `resources` field or require an entire multi-host project plan to
fit one cell on one machine. A multi-frame or remote plan should produce a set of per-host requirements,
each admitted by the authority local to that host. Distributed all-or-nothing acquisition, if ever needed,
is a separate protocol and should not be implied by the daemonless local-host design.

### 13. Existing `fcntl` ownership locks and new `flock` resource locks need layering

The proposal standardizes BSD `flock` for resource locks and forbids `fcntl`/`lockf` in that namespace.
The existing [ownership seam](documents/architecture/ownership_seam.md) uses an `fcntl` lock on POSIX for
protected object transactions.

These can coexist only if their purposes and ordering are explicit:

- outer resource arbitration uses the permanent `flock` namespace;
- inner protected-store/object ownership continues using its existing transaction lock; and
- acquisition always proceeds from outer epoch/parent/cell/domain locks to inner lifecycle and ownership
  entries, never in the reverse direction.

The two lock families must not be described as mutually excluding one another. They are separate kernel
namespaces.

## Privilege, Permissions, and Trust

### 14. The privileged installer has no owner or command surface

The proposal requires creation of fixed system-wide roots, local groups, ACLs, permanent lock objects,
catalog state, cgroup partitions, quotas, and possibly MIG topology. Catalog mutation is explicitly an
offline privileged operation. It nevertheless says only that `hostbootstrap` may optionally install the
catalog.

The design must identify:

- the executable or installer that owns initial installation;
- how it fits the fixed `project` / `test` / `service` / `context` / `check-code` command surface;
- who authors the human-facing layout input;
- how that input becomes deterministic CBOR;
- who assigns project, parent, cell, and domain identifiers;
- how principals are enrolled and removed;
- how catalog upgrades and topology changes are authorized; and
- how an operator inspects, recovers, quarantines, and unquarantines a cell.

No daemon is required for admission, but an administrative surface is still required.

### 15. The proposed POSIX modes do not enforce immutability

A root-owned directory with mode `0770` gives every member of the group directory-write authority. On
POSIX that permits renaming or unlinking directory entries even when the individual files are root-owned.
Regular-file mode `0660` also permits every group member to rewrite the layout and records.

File-identity checks can detect a replacement after it occurs, but by then two processes may already have
opened and locked different inodes under the same pathname. That is precisely the split lock namespace the
protocol says must be impossible.

Use a permission table with separate concerns, for example:

- catalog and lock directories: administrator-owned and participant-nonwritable;
- immutable layout and lock files: administrator-created, participant-readable/openable but not replaceable;
- mutable allocation records: isolated per project or written through a privileged broker/helper; and
- receipt access: least-privilege read access, not group-wide mutation.

### 16. `ProjectId` is not operating-system authentication

An opaque Haskell constructor prevents an ordinary caller inside one correct program from fabricating an
identity. It does not authenticate one independently compiled process to another. If the protocol's threat
model is fully cooperative, this should be stated plainly. If cell allowlists are intended to resist a
buggy or hostile same-privilege participant, the design needs a binding to installed project identity,
per-project OS principals/ACLs, signatures, or a privileged verifier.

The existing ownership doctrine already states that a hostile same-privilege process is outside its
guarantee. The new protocol should use the same explicit threat boundary and avoid presenting an opaque
type as a cross-process credential.

### 17. Windows boot identity needs a privileged initialization story

The proposed first participant creates a volatile key under `HKLM`. Microsoft documents that creating a
registry subkey requires `KEY_CREATE_SUB_KEY` on its parent
([`RegCreateKeyEx`](https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regcreatekeyexa)).
An ordinary member of a resource-authority users group will not normally have that right.

The protocol must choose between:

- a privileged boot service/task that initializes the nonce;
- installation-time delegation of narrowly scoped key-creation rights, including ACL and nonce-rotation
  rules; or
- another stable Windows boot-identity source.

### 18. Close-on-exec is not close-on-fork

On POSIX, `O_CLOEXEC` prevents a descriptor from surviving a successful `exec`; a forked child initially
inherits the same descriptors and `flock` open-file descriptions. The Linux
[`fork(2)` documentation](https://man7.org/linux/man-pages/man2/fork.2.html) states this explicitly.

The anchor needs a strict launch discipline: no fork-only workload child, close inherited descriptors in
the child before any non-exec path, and exercise abnormal pre-exec failure in a live test. Otherwise a child
can unintentionally extend lock custody after the intended anchor dies.

## Substrate-Specific Concerns

### 19. MPS recovery must quarantine the server/device failure domain

The proposal carefully classifies MPS as bounded shared execution, but its recovery narrative still suggests
that an exact client slot may be cleaned while siblings remain live. NVIDIA documents that terminating an
MPS client without synchronizing outstanding work can leave the server and other clients in an undefined
state, including hangs, failures, or corruption; recovery may require restarting the affected server and
clients. See [NVIDIA's MPS guidance](https://docs.nvidia.com/deploy/mps/when-to-use-mps.html).

Consequently:

- a clean, cooperative client exit may release one slot;
- an abrupt or uncertain client exit must taint at least the relevant MPS server/device failure domain;
- new clients must be refused until the server and every affected sibling are safely drained or declared
  quarantined; and
- the protocol must not claim exact per-slot crash recovery where the substrate does not supply it.

MPS should be deferred from the first version. Whole-device exclusion and distinct MIG GIs have much
clearer isolation and recovery semantics.

### 20. Linux strict CPU isolation needs exact partition readback

A cpuset assignment is not automatically an exclusive scheduling partition. The strict profile should
require a valid `cpuset.cpus.partition` root and read back the effective exclusive CPU set, not merely write
`cpuset.cpus`. The Linux kernel's
[cgroup-v2 documentation](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html) distinguishes
requested CPUs, effective CPUs, and exclusive partition roots.

Similarly, `memory.max` is a hard cgroup limit but may be exceeded transiently during reclaim. The guarantee
should remain about an enforced kernel boundary and bounded admitted maxima, not an instantaneous physical
resident-set equality.

### 21. Windows process containment must forbid breakaway paths

Windows Job Objects are a reasonable process-tree envelope, but the profile must fix breakaway flags and
creation order. Microsoft documents that child association can be changed by
`JOB_OBJECT_LIMIT_BREAKAWAY_OK` or `JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK`; the closed launcher must set
neither and must create the target suspended before assignment. See
[Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects).

The proposal's classification of job committed-memory limits as something other than a physical-RAM
reservation is appropriately cautious and should be retained.

### 22. Darwin remains a weaker lane

The proposal is correct not to claim a native aggregate descendant-memory wall on Darwin. An exclusive
Metal token can prevent participating projects from using the device concurrently, and reactive pressure
handling can be useful, but neither becomes a hard consumption ceiling. Hard-bound requirements should
continue to refuse or select an independently bounded substrate.

## ABI and Conformance Governance

### 23. The semantic ABI needs one normative release authority

The document says Markdown is not executable authority and that each repository owns separate Haskell
declarations and vectors. It also requires byte-for-byte compatible deterministic CBOR, path grammar,
digest separation, lock order, state transitions, and recovery behavior.

Those requirements need one clearly versioned normative release source. Otherwise four local declaration
sets can all be internally reviewed and still disagree. The release should include at least:

- protocol version and ABI digest;
- canonical field tags and bounded integer widths;
- identifier and path grammar;
- digest algorithms and domain-separation labels;
- lock hierarchy and total canonical ordering;
- state-machine transition table;
- canonical CBOR positive and negative vectors;
- compatibility and refusal vectors;
- crash schedules; and
- an identifier-allocation and upgrade-governance policy.

This may be a tiny neutral package or a signed/versioned data corpus. It need not grant runtime authority or
introduce a daemon. If the prohibition on importing another repository's executable code remains, a shared
data-only conformance release is the minimum practical interoperability anchor.

### 24. Additional validation cases are required

The proposal's validation section is a good foundation. It should additionally cover:

- two different parents selecting the same logical cell;
- stale effects from parent A discovered by parent B;
- cell-record/parent-record partial commits in both directions;
- interrupted ABI and catalog migration;
- permission and ACL regression;
- replacement of every path component, not only the final file;
- symlink, hard-link, reparse-point, and private-bind-mount substitution;
- malformed and resource-exhausting CBOR fuzzing;
- attach-to-anchor races and authentication failure;
- forced anchor death during every durable transition;
- POSIX fork-before-exec descriptor inheritance;
- Windows Job Object breakaway attempts;
- service-manager or VM auto-restart after reboot;
- bounded receipt/tombstone storage after many attempts;
- MPS client crash and server-wide quarantine; and
- cross-implementation differential execution, not only duplicated golden tests.

## Documentation and Development-Plan Concerns

### 25. The document should be a draft with explicit current status

The proposal mixes target behavior, current project comparisons, and future validation while declaring
itself an authoritative source. Under
[documentation standards](documents/documentation_standards.md), a broad document mixing implemented and
target behavior needs a `Current Status` section, and implementation order and closure criteria belong in
`DEVELOPMENT_PLAN/`.

Until the ownership and protocol questions above are settled, `Draft` is the accurate status.

### 26. Metadata and navigation are not integrated

The proposal's metadata is hidden inside a `<details>` block after introductory prose rather than appearing
in the governed metadata position immediately below the title. It links to `./README.md`, but there is no
`documents/engineering/README.md`; the actual documents index is
[documents/README.md](documents/README.md), which does not yet list the proposal.

During this review, the focused documentation test:

```text
cabal test hostbootstrap-core-test \
  --test-options='--pattern DocValidatorSpec' \
  --test-show-details=direct
```

failed with one repository violation:

```text
documents/engineering/shared_host_resource_protocol.md:
unresolved relative link: ./README.md
```

The document should also link the existing canonical homes it overlaps:

- [resource budgeting](documents/engineering/resource_budgeting.md);
- [ownership invariant](documents/architecture/ownership_invariant.md);
- [ownership seam](documents/architecture/ownership_seam.md);
- [durable state](documents/architecture/durable_state.md);
- [lifecycle state model](documents/architecture/lifecycle_state_model.md);
- [Python/Haskell boundary](documents/architecture/python_haskell_boundary.md); and
- [unrepresentable state](documents/architecture/unrepresentable_state.md).

### 27. Phase citations and plan ownership are absent

The introduction cites bare amoebius phase numbers, including phase numbers that do not exist in this
repository. No `hostbootstrap` phase owns the proposed changes to authority kernels, resource quantities,
leases, journals, project-plan admission, ownership, recovery, or substrate gates.

Before implementation, the development plan must identify which existing contracts are amended and which
new phases introduce the outer protocol. Phase references in governed documentation should use phase names
and links rather than bare numbers.

### 28. The proposal should be split

At 869 lines, the proposal combines several independently reviewable contracts. The repository's
documentation standard asks authors to reconsider documents above roughly 300 lines. A useful split would
be:

1. architecture: guarantee, scope, resource graph, and relationship to `ProjectPlan`;
2. engineering ABI: paths, identities, lock hierarchy, encoding, state machine, and recovery;
3. substrate matrix: Linux, Darwin, Windows, CUDA, MIG, and MPS mechanism strength; and
4. API/conformance appendix: Haskell sketch, canonical vectors, and cross-implementation gates.

Splitting also makes it possible to give each topic one canonical home rather than duplicating resource,
ownership, and lifecycle doctrine.

## Recommended `hostbootstrap` Architecture

The outer protocol should be an optional host-local bracket around existing lifecycle execution:

```text
InstalledProjectIdentity
  + admitted ProjectPlan
  + plan-derived local workload demand
                  |
                  v
        Host-global resource adapter
        - validate observed host/layout
        - take epoch, parent, cell, and domain locks
        - publish outer allocation intent
        - create/read back enclosing walls
                  |
                  v
         ResourceExecutionPermit
                  |
                  v
       existing rooted lifecycle / Chain
       existing HostCommand interpreter
       existing PreparedGate and ownership rows
                  |
                  v
      existing lifecycle/ownership receipts
                  |
                  v
       retire outer allocation and unlock
```

This structure preserves two distinct responsibilities:

- the outer protocol decides whether this host may admit the work and holds the host allocation; and
- the existing lifecycle protocol decides which project resource may be created, reconciled, or removed.

The outer record may reference an authenticated commitment to the inner lifecycle identity, but it should
not reproduce the inner resource journal.

## Recommended First Version

The first version should deliberately omit much of the final matrix.

### Scope

- one physical Linux host;
- participating, mutually trusted project binaries;
- guarantee begins after Haskell handoff and project-plan admission;
- local-host work only;
- one `hostbootstrap-core` implementation plus, optionally, one independent conformance implementation;
- `ParticipatingProjects` guarantee only; and
- operator-installed static catalog.

### Resources and mechanisms

- immutable logical cell lock;
- cell-owned current record plus parent pointer;
- bounded CPU and memory arithmetic;
- cgroup-v2 process-tree containment;
- valid exclusive cpuset partitions only when exclusive CPU is requested;
- storage capacity only where a real reservation/quota exists;
- exclusive whole-GPU UUID locks; and
- distinct MIG GI locks where supported.

### Deferred features

- MPS sharing;
- Darwin reactive execution;
- Windows Job Object execution;
- WSL host delegation;
- VM-mediated or vGPU assignment;
- storage throughput guarantees;
- `WholeHost` claims;
- distributed multi-host acquisition; and
- transparent pre-Haskell bootstrap admission.

Each deferred feature should enter through its own mechanism declaration, live acceptance gate, and explicit
strength classification.

## Decisions Required Before Implementation

The following decisions should be recorded before code work begins:

1. Does `hostbootstrap-core` own the reusable implementation, or is independent implementation a deliberate
   exception to the library hierarchy?
2. What exact local work lies inside the guarantee, and does it begin only after Haskell handoff?
3. Is the threat model cooperative correctness or protection against same-privilege participants?
4. What is the permanent cell-lock identity and where is cell-owned recovery state stored?
5. How do persistent `up`, later `down`/`destroy`, and accelerator subleases map to parent scopes and claims?
6. What is the transaction order between the outer allocation record and the existing protected lifecycle
   store?
7. Who installs, upgrades, and repairs the privileged host catalog?
8. What bounded idempotency and tombstone-retention policy is acceptable?
9. What artifact is the normative semantic ABI and who publishes a new version?
10. Which substrate is the first implementation and which mechanisms are explicitly deferred?

## Conclusion

The proposal's central safety equation is appropriate for this project: a derived requirement should not
authorize execution until a matching host cell is both held and enforced. Its treatment of physical GPU
identity, honest enforcement strength, crash recovery, and quarantine is directionally strong.

The proposal currently combines that good outer model with an incomplete cell-ownership primitive, a second
unintegrated authority stack, an unspecified privileged administration surface, and a reuse strategy that
conflicts with `hostbootstrap`'s library architecture. Those are design issues to resolve before coding, not
reasons to discard the goal.

The recommended path is to preserve the guarantee, make cell identity and recovery explicit, implement the
protocol once in `hostbootstrap-core`, wrap the existing plan/lifecycle interpreter, and prove a narrow Linux
whole-GPU/MIG version before expanding the substrate matrix.
