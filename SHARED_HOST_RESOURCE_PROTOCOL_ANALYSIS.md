# Shared Host Resource Protocol Analysis

## Executive Summary

The proposed [Shared Host Resource Protocol](documents/engineering/shared_host_resource_protocol.md)
addresses a real gap in `hostbootstrap`: the project can validate and enforce parts of one project's
resource budget, but it cannot currently arbitrate CPU, memory, storage, or accelerator use against
another independently running project on the same physical host.

The proposal is directionally strong. Its permanent host-global objects, exact physical-domain locks,
resource-indexed mechanism strengths, progressive assurance profiles, bounded records, and fail-closed
recovery rules are consistent with this repository's existing ownership and
make-illegal-states-unrepresentable (MISU) principles. Its separation between generic host admission and
project-local workload meaning is also the correct dependency direction.

However, the proposal is not yet an adoptable `hostbootstrap` design. For this project it would introduce
a second durable state machine, a second recovery authority, a new long-lived process role, a privileged
machine-wide installation, and a separately governed release program. The proposal calls the shared layer
an admission and custody fence, but it does not yet define how that fence composes with `hostbootstrap`'s
existing root coordinator, `ProtectedStore`, lifecycle leases, prepared operations, journals, ownership
receipts, or recovery interpreter.

The most important conclusion is therefore:

> Retain the protocol as a Draft cross-project RFC, but do not add its neutral dependency, host catalog,
> or runtime objects to `hostbootstrap` until a hostbootstrap-specific composition contract and an owning
> development-plan phase exist.

The first viable adoption should be deliberately narrow: a foreground, post-binary operation or exact
whole-device turn. It should not initially claim to govern persistent `project up` workloads, because VMs,
clusters, mounts, services, provider effects, and restartable containers require the proposal's full
recoverable profile.

## Review Scope

This analysis considers the protocol against the current repository contracts for:

- the [Python/Haskell boundary](documents/architecture/python_haskell_boundary.md);
- the [lifecycle state model](documents/architecture/lifecycle_state_model.md);
- [durable state](documents/architecture/durable_state.md);
- the [ownership invariant](documents/architecture/ownership_invariant.md) and
  [ownership seam](documents/architecture/ownership_seam.md);
- [resource budgeting](documents/engineering/resource_budgeting.md) and
  [applied cordoning](documents/engineering/applied_cordon.md);
- the [execution shapes](documents/architecture/run_models.md);
- the [testing contract](documents/engineering/testing.md);
- the [development-plan standards](DEVELOPMENT_PLAN/development_plan_standards.md); and
- current phase ownership in the [development-plan index](DEVELOPMENT_PLAN/README.md).

This is an architectural assessment. It does not establish protocol conformance, implementation status,
or authority for any other participating repository.

## The Problem Is Real

The proposal correctly distinguishes project-local resource controls from host-global arbitration.
Repository-local locks, a Kubernetes request, a VM ceiling, or a container memory cap can constrain one
workload, but none prevents another project from independently claiming the same physical host capacity or
exclusive device.

Current `hostbootstrap` resource handling has several explicitly documented limitations:

- resource budgets are project/provider concerns rather than a universal host scheduler;
- direct Linux GPU outer work is uncapped;
- bare-Linux storage has no runtime quota or image-garbage-collection wall;
- Lima, Incus, and WSL2 sizing is not uniformly reconciled for existing instances;
- WSL2 CPU and memory use one per-user global utility-VM wall, not a per-distribution wall;
- the Python base-image builder divides resources only among the builds it starts itself; and
- no existing project-local lock can arbitrate with another independently implemented project.

This means the protocol is not inventing a theoretical problem. Cross-project GPU exclusion, safe shared
WSL2 wall ownership, and avoidance of simultaneous memory-heavy builds are concrete use cases.

## Where the Proposal Fits Well

### Exact host-global exclusion

The fixed host root and permanent precreated lock objects give every participant the opportunity to name
the same arbitration boundary. That is categorically stronger than repository-local paths or independently
chosen lock names.

Using locks for cells and physical domains while treating scalar quantities as capacity, rather than lock
names, is a sound distinction. Ancestor/child conflicts also give the model a plausible way to represent
whole GPUs, MIG partitions, and future physical subdomains without allowing a whole device and one of its
children to be allocated concurrently.

### Resource families are separate from mechanisms

CPU, memory, storage, CUDA, Metal, and future accelerator families describe what is being charged.
Cgroups, Job Objects, quotas, whole-device exclusion, MIG creation, and MPS describe how a claim is
enforced or observed. Keeping these as separate release dimensions avoids treating an operating-system
containment tool as if it were a physical resource.

This also fits the existing `hostbootstrap` substrate model: the shared family projection can remain
host-coordination metadata while `ProjectPlan` retains the project's richer provider, frame, topology, and
workload meaning.

### Honest progressive assurance

The separation among `CooperativeCellLease`, `EnforcedCellLease`, and
`RecoverableExecutionAuthority` is one of the proposal's strongest features. It avoids several common
overclaims:

- a capacity calculation is not a hard wall;
- an exclusive device lock is not a scalar CPU or memory ceiling;
- a successfully applied wall is not crash recovery; and
- a receipt is not reusable live authority.

This is consistent with the current ownership invariant, which explicitly says that an OS-released lock,
durable origin, stable identity binding, and identity-conditional release exclude cooperating races and
detect foreign mutation, but do not control a hostile process with the same privilege.

### One project-owned conversion

The proposed adapter shape is compatible with the existing exact-plan doctrine:

```text
validated ProjectPlan
  -> complete local workload requirement
  -> normalized protocol requirement
  -> closed operation identity
```

The return direction is equally important:

```text
protocol resource receipt
  + project lifecycle receipt
  -> project terminal result
```

Requiring exactly one conversion in each direction prevents an independent resource calculator from
silently disagreeing with the plan that the lifecycle interpreter actually executes.

### Base and turn separation

Long-lived base capacity and short-lived accelerator or build bursts genuinely have different lifetimes.
A persistent cluster should not retain a GPU merely because one later operation might need it, and a live
project must not be permitted arbitrary unplanned expansion.

Predeclared base-plus-turn combinations, atomic multi-domain acquisition, and a bounded number of turns are
a reasonable safety model. They also give exact-device use a plausible narrow initial adoption target.

### Bounded storage and fail-closed recovery

Finite preallocated records, bounded receipt windows, monotonic attempt generations, explicit saturation,
and offline migration prevent an unattended protocol from growing unbounded metadata or treating counter
wrap as fresh identity.

Likewise, refusing to infer absence merely because a lock was released is correct. A dead process does not
prove that its VM, container, mount, service, device context, delayed provider request, or retained storage
has disappeared.

## Current Applicability to `hostbootstrap`

| Project area | Current fit | Assessment |
|---|---|---|
| Exact `ProjectPlan` demand derivation | Strong conceptual fit | This is the correct project adapter source, but the complete concurrent workload projection and all substrate walls are not uniformly closed today. |
| Foreground post-binary work | Plausible cooperative fit | A bounded, non-detaching build/test action or exact whole-device turn could be an initial vertical slice. |
| Python toolchain/bootstrap build | Not covered | The Haskell kernel does not exist until Python has installed the toolchain and built the binary. |
| Python base-image builds | Partially related | Current Linux logic caps Docker/Cabal work and divides only known sibling builds; it does not join cross-project admission. |
| VM, cluster, mount, service, or provider lifecycle | Requires full recoverable profile | These are explicitly outside the cooperative and finite-enforced machines. They are the main `project up` workload. |
| Linux CPU/RAM | Partial enforcement | Some provider and node walls exist, but existing sizing and all outer effects are not uniformly reconciled. |
| Bare-Linux storage | Admission-only | It cannot support a hard-ceiling claim until quota/image-GC or an equivalent enforced extent exists. |
| Linux GPU | Useful exact-device turn, incomplete whole workload | Whole-device exclusion is valuable, but outer host build/container work remains uncapped. |
| Apple Silicon | Cooperative/reactive for some dimensions | Metal exclusion is plausible; native hard descendant-memory claims are not. |
| Windows/WSL2 | Important but structurally special | The utility-VM wall is global per user, so it needs exact shared ownership; Job Objects could cover bounded child processes, but WSL2 is not a per-project CPU/RAM wall. |
| Persistent host daemon | Process-model conflict | Current `service run` is a lifecycle-owned leaf; the proposed anchor is a custody and recovery participant. |

## Critical Integration Findings

### 1. The proposal introduces a second durable lifecycle authority

The shared protocol owns more than a lock facade. Its core includes lease transitions, dual-page journals,
attempt identity, receipts, quarantine, migration, and recovery behavior. Its recoverable cell machine moves
through `Prepared`, `Applied`, `Running`, `Releasing`, `Recovering`, and terminal states. The cell record is
described as the machine-global recovery source.

`hostbootstrap` already has a lifecycle authority with overlapping responsibilities:

- one root coordinator;
- one `ProtectedStore`;
- Production/Harness mode leases;
- bound run leases and broker generations;
- exact plan snapshots and acquisition cursors;
- prepared operations and fences;
- ownership records and receipts;
- per-operation journals;
- recovery and migration; and
- terminal acknowledgment and teardown evidence.

The assertion that the outer protocol is only an admission and custody fence is directionally useful, but
it is not yet a composition rule. Both layers record preparation, operation identity, recovery state, and
terminal outcome.

The following cross-layer crash windows are currently unspecified:

1. A cell is recorded `Prepared`, but the project-local `PreparedGate` is never persisted.
2. The project operation is prepared, but its external effect begins before the cell reaches the matching
   state.
3. The project settles an effect, but the cell record remains in an earlier generation.
4. Project teardown establishes absence, but the protocol terminal record is not published.
5. The protocol record is terminal, but the project receipt or retained-storage settlement is incomplete.
6. The anchor dies after one journal advances but before the other does.

Failing closed to quarantine is safe for each ambiguous case, but if most ordinary crash windows end there,
the recoverable profile is not operationally recoverable.

### Required composition contract

Before implementation, a hostbootstrap-specific contract must define at least:

- how `ProjectId`, admission slot, attempt generation, cell, and protocol epoch bind to lifecycle scope,
  broker generation, plan digest, operation key, attempt, and journal version;
- whether a protocol attempt denotes a complete `ProjectPlan`, one plan operation, or a persistent base plus
  several subordinate operations;
- which layer first records durable intent;
- which exact project record a protocol `Prepared` state commits to;
- how recovery proves that both records describe the same operation;
- which layer is allowed to initiate provider or lifecycle reconciliation;
- the only producer of the combined terminal receipt;
- the transition that makes a cell reusable; and
- the exact quarantine disposition for every unmatched pair of states.

A useful target shape would be:

```text
protocol admission and retained lease
  -> project-local preparation under the exact lease identity
  -> external effect under both authorities
  -> project-local terminal receipt
  -> protocol readback and terminal settlement
  -> lock release
```

The protocol record should remain authoritative only for cross-project occupancy. The project store should
remain authoritative for desired state and project-specific recovery. Neither should attempt to reconstruct
the other's semantics from descriptive records.

### 2. Cross-layer lock ordering is missing

The protocol defines a canonical order among epoch, admission-slot, cell, ancestor, and leaf locks. It does
not define their order relative to `hostbootstrap`'s project-local `ProtectedStore` entry or existing
provider/global-wall locks.

This creates a direct inversion risk:

```text
recovery path:
  protocol cell/domain authority
    -> project ProtectedStore

live turn path, if called inside a project operation:
  project ProtectedStore
    -> protocol turn cell/domain authority
```

The two paths can deadlock even when each layer's internal ordering is correct.

The safe rule should be explicit and structural:

1. protocol admission and turn acquisition occur outside every project-local protected entry;
2. the root coordinator acquires the complete required host bundle before preparing the dependent local
   operation;
3. project-local recovery may run while the corresponding protocol authority is retained;
4. project code never requests new host locks from inside a `ProtectedSession`; and
5. terminal project settlement completes before protocol terminal settlement releases the outer authority.

This implies that turns must be planned root-coordinator operations, not callbacks that an arbitrary inner
step may request while already holding local state authority.

### 3. The project-local anchor conflicts with the current process model

The proposal's anchor is not merely a supervised workload. It:

- owns protocol handles for the workload lifetime;
- creates the enclosing enforcement domain;
- authenticates later clients over IPC;
- retains project, attempt, cell, process-birth, and endpoint identities;
- accepts a closed project operation vocabulary;
- participates in attachment and retry; and
- invokes the project's authenticated recovery path when needed.

Current `hostbootstrap` doctrine instead makes the root process the durable lifecycle coordinator and
describes `service run` as a leaf runtime. A host daemon is started and stopped by the surrounding project
lifecycle; it is not another project-plan interpreter.

There are two possible designs:

1. **Extend the root coordinator into the anchor.** The CLI attaches to an already-running or newly started
   host-native root coordinator. That process owns both the protocol lease and the existing project
   lifecycle store. This avoids two coordinators but materially changes root process lifetime and startup.
2. **Introduce a separate custody-only anchor.** It owns locks and enforcement-domain handles but never
   interprets desired state. This preserves the current coordinator, but it cannot independently perform
   the proposal's inner recovery role without becoming a second coordinator.

The first design is more coherent with the proposal's recovery requirements. The second needs a much
narrower anchor contract than the current document describes.

Whichever design is selected must also define:

- startup before the first persistent effect;
- restart after reboot;
- OS-native supervision on Linux, Darwin, and Windows;
- IPC endpoint creation and stable identity;
- peer-credential and nonce verification;
- compatibility with the fixed public command surface;
- behavior when the project executable has been upgraded; and
- decommissioning when a catalog or core release changes.

### 4. The pre-Haskell bootstrap gap is material

For ordinary `doctor`, `build`, and `run`, Python must discover the project, install or validate GHCup/GHC/
Cabal, refresh the package index when required, build the executable, and copy it into `.build` before the
Haskell project binary can run.

The default neutral implementation is proposed as a Haskell package. Therefore the protocol cannot govern
the work needed to produce its own first consumer unless one of the following exists beforehand:

- a separately installed neutral protocol client;
- a Python compatibility implementation;
- a privileged launcher that performs admission before Python; or
- an explicit policy that pre-binary work is outside the protocol.

The document currently chooses the last option provisionally by describing initial bootstrap as weaker or
excluded. That is honest, but it is a major limitation for `hostbootstrap`, because native compilation and
base-image warm-store builds are among its heaviest operations.

A Python compatibility port would also weaken two central arguments: the shared boundary would no longer
have one routine implementation, and cross-language encoding/native-lock behavior would require its own
conformance program. A separately installed neutral CLI is cleaner, but it makes the neutral repository an
operator-facing product rather than only a Cabal dependency.

### 5. Early profiles cover little of normal `project up`

The cooperative and finite enforced profiles allow foreground, supervised, non-detaching operations without
asynchronous provider effects. The proposal explicitly assigns persistent clusters, VMs, services, mounts,
restartable containers, and provider-mediated effects to the recoverable profile.

Those excluded effects are not peripheral to this repository. They are the normal project lifecycle.
Consequently:

- the cooperative profile can improve exact-device exclusion and foreground build/test coexistence;
- the enforced finite profile can add honest walls to bounded child process groups where supported;
- neither profile can honestly authorize the complete demo or ordinary persistent `project up`; and
- meaningful lifecycle adoption requires the hardest profile, including the unresolved dual-journal and
  anchor design.

The phrase "immediate cooperative profile" should not be read as an incremental path to normal project
bring-up without a major later integration. It is a useful but narrow product capability.

### 6. Artifact enrollment is not an OS-enforced security boundary

The protocol binds a project identifier and OS principal to an artifact digest or trusted signing policy,
but participants must also receive write access to shared cell pages. The protocol correctly excludes a
hostile process running as an enrolled principal.

This distinction matters in development environments, where several projects commonly run under the same
Unix user or Windows account. ACLs can distinguish principals; they cannot distinguish two artifact digests
running as the same principal. A same-principal process can bypass the conforming adapter and write bytes
directly, although malformed or inconsistent bytes should cause quarantine rather than unsafe reuse.

Therefore:

- artifact digest/signature enrollment is compatibility, provenance, and audit evidence;
- distinct OS principals can provide stronger project isolation;
- same-principal development remains cooperative even with exact artifact enrollment; and
- a stronger artifact-enforced boundary would require a trusted launcher, service, kernel integrity policy,
  or another mechanism outside the current daemonless design.

The proposal should avoid language suggesting that artifact enrollment itself grants or enforces write
authority.

### 7. Release independence is semantic, not operational

Separating `CoreMajor`, family releases, and mechanism releases is useful. Adding a family need not change
the core encoding or lifecycle algebra.

However, an older client must refuse the whole catalog when an unknown family may alias host memory,
storage, an ancestor, or a known domain. Unified-memory accelerators and shared storage are precisely the
families most likely to have those aliases. An isolation certificate helps only when the old core can prove
the new domain is disjoint using already-known graph semantics.

As a result, a new family can require:

- rebuilding several project artifacts with the new registry;
- coordinating their deployment;
- taking the epoch lock for an offline catalog migration; and
- refusing old clients after cutover.

It is accurate to call this **core-encoding independence**. It is not generally independent operational
deployment.

### 8. The neutral repository is operationally a product

The proposal calls the neutral repository a dependency island rather than a sixth product. Its dependency
direction is indeed neutral: it imports no project lifecycle or seed package.

Operationally, however, it owns:

- release keys and maintainers;
- identifier allocation;
- a canonical package and ABI;
- installers and privileged filesystem layout;
- catalog schema and signing;
- status, migration, quarantine-clear, and decommission commands;
- native lock and journal implementations on three host families;
- family and mechanism release processes; and
- conformance declarations and release artifacts.

That is a product-sized governance and maintenance commitment even if it is not a product-to-product
dependency. The distinction should be framed as neutrality of ownership and imports, not absence of product
cost.

### 9. Haskell source alone is an awkward cross-implementation authority

The proposal says canonical declarations, laws, and vectors are Haskell source, while Amoebius independently
re-derives the kernel and compatibility ports may exist for clients that cannot consume the package.

For a real interoperability ABI, releases should also contain immutable, content-addressed artifacts that
do not require executing or interpreting the reference Haskell implementation:

- exact canonical encoding rules;
- positive and negative wire vectors;
- lock-object grammar and ordering tables;
- dual-page selection and corruption vectors;
- transition/refusal tables;
- crash schedules and expected dispositions;
- catalog signature and isolation-certificate vectors; and
- platform-specific lock/identity obligations.

Generated vectors may be produced from Haskell, but the release must publish and digest them. Keeping only
ephemeral rendered copies beneath ignored `.build/**` paths is insufficient for long-lived compatibility,
clean-room re-derivation, or audit of an archived release.

### 10. Static catalogs and permanent quarantine have a substantial operator cost

Precreating every lock and bounded record removes runtime namespace races and unbounded growth. It also means
that new cells, slots, bounds, and relevant hardware projections require privileged offline maintenance.

The immediate profiles additionally turn unexpected process loss, reboot, torn state, or uncertain output
into permanent quarantine. That is safe, but interrupted long-running builds and tests are not exceptional in
development. A killed foreground holder can turn a shared cell into an administrator-cleared outage.

Before deployment, the operator experience needs to be treated as a first-class deliverable:

- signed catalog generation and review;
- dry-run capacity and alias validation;
- status and contention diagnostics;
- exact quarantine cause reporting;
- audited proof-based quarantine clearing;
- bounded-record saturation forecasts;
- offline migration and rollback limits;
- project and principal enrollment/de-enrollment; and
- disposable-host conformance catalog creation.

Production and development catalogs likely need different signer and enrollment policies, but they must not
differ in protocol semantics or object grammar.

## Governance and Development-Plan Findings

### No owning phase exists

The protocol points implementation and qualification status at the development-plan index, but the current
phase table has no phase that owns:

- the neutral dependency port;
- the project adapter;
- anchor integration;
- cross-layer lock ordering;
- catalog installation;
- a foreground cooperative adopter;
- the recoverable lifecycle adopter; or
- cross-project conformance.

This makes the proposal intentionally non-implemented, but also non-executable as a `hostbootstrap`
development plan. The repository's plan doctrine requires architectural changes to appear in the one
constructive narrative with an independently validatable owning phase.

Adoption cannot simply be appended as a late corrective phase if it changes assumptions established by the
existing ownership, lifecycle, resource, or process phases. Under the repository's additive-plan doctrine,
the narrative must be re-cut so the protocol authority is available before the first dependent lifecycle
surface is introduced. That may require phase insertion and renumbering rather than a single final phase.

### The document is too broad for its claimed repository role

The file is more than one thousand lines and contains four separable concerns:

1. the core on-disk and kernel-object ABI;
2. resource-family and mechanism extension semantics;
3. project adapter, anchor, and lifecycle composition; and
4. neutral-repository governance and eventual Amoebius cutover.

The documentation standard asks authors to reconsider splitting a governed document after roughly 300 lines.
More importantly, the protocol says this repository copy records only hostbootstrap metadata, navigation,
and its proposed adoption boundary, while the actual copy contains the full normative cross-project design.

During review, a reasonable split would be:

- a neutral core-protocol RFC;
- a family/mechanism extension RFC;
- a governance and release RFC; and
- a short hostbootstrap adoption analysis or record.

After a neutral release exists, this repository should retain only the short adoption record described by
the proposal itself: exact release coordinates, supported catalog/profile revisions, local adapter boundary,
current implementation phase, and validation evidence.

## Recommended Hostbootstrap Composition

The following is a candidate direction, not an implemented contract.

### Authority placement

- The neutral protocol owns only cross-project admission, physical-domain custody, enclosing enforcement
  domains, and global quarantine.
- The existing root coordinator remains the sole interpreter of `ProjectPlan` desired state.
- The existing `ProtectedStore` remains the sole authority for project mode, plan snapshot, operation
  journal, ownership binding, and project recovery.
- A persistent root coordinator may retain the protocol handles and thereby serve as the project anchor.
- Child frame executors remain storeless and receive neither protocol lock constructors nor inherited lock
  handles.

### Acquisition order

```text
root validates exact ProjectPlan and complete requirement
  -> neutral kernel returns eligible cells
  -> root coordinator acquires base/turn protocol authority
  -> root opens local prepared operation under the bound protocol identity
  -> root creates and read-backs the enclosing wall/domain
  -> closed project interpreter performs the exact effect
  -> local lifecycle settles and returns its terminal receipt
  -> protocol verifies empty domain/storage disposition
  -> protocol publishes terminal state and releases locks
```

No protocol acquisition occurs while a project `ProtectedSession` is live. No child can acquire or enlarge
the host bundle. Recovery takes the same outer-to-inner order.

### Identity binding

The adapter should bind, without lossy text reconstruction:

```text
Protocol ProjectId
Protocol CatalogEpoch
Protocol SlotId
Protocol AttemptGeneration
Protocol CellId
Protocol RequirementDigest

to

InstalledProject identity
Lifecycle scope and mode
BrokerGeneration
StablePlanDigest
OperationKey or complete-plan identity
Project journal attempt and fence
```

The binding itself must be canonical, signed or otherwise authenticated where it crosses a process boundary,
and retained in both records by digest. Equality of display text is not sufficient.

### Recovery split

- The protocol can decide whether a cell is globally occupied, terminal, or quarantined.
- It can stop and empty only the enclosing enforcement domain it created and owns.
- It cannot infer provider desired state or delete named project objects from descriptive records.
- The project recovery interpreter alone reconciles project-owned VMs, clusters, mounts, services, or
  provider effects.
- The protocol reaches `Retired` only after project recovery supplies the exact terminal receipt and protocol
  readback establishes the enclosing domain and retained-storage disposition.
- Any unmatched identity, delayed effect, unknown project outcome, or unavailable recovery interpreter
  quarantines rather than guessing.

## Recommended Adoption Sequence

### Stage 0: Governance prerequisite

Do not change `hostbootstrap` dependencies yet. First establish:

- the neutral repository and maintainers;
- core scope and threat model;
- signed release and catalog formats;
- immutable conformance artifacts;
- platform lock/identity primitives;
- installer, status, migration, and decommission boundaries; and
- agreement among at least two genuinely independent participating projects.

### Stage 1: Pure adapter prototype

Implement no host-global mutation. Define and test only:

- the conversion from an exact validated plan requirement to the generic resource graph;
- canonical units and overflow behavior;
- alias projection;
- eligible-cell calculation;
- mechanism satisfaction;
- exact unknown-family refusal; and
- canonical identity binding between protocol and project coordinates.

This prototype should reveal whether the supposedly minimal core is actually independent of project
lifecycle concepts.

### Stage 2: Foreground cooperative vertical slice

Choose one operation that is:

- post-Haskell-binary;
- foreground and non-detaching;
- closed under one supervised process group;
- free of asynchronous provider effects;
- free of retained output not already charged to storage reserve; and
- useful when contended by another project.

An exact whole-CUDA-device or Metal-device turn is a stronger candidate than generic CPU/memory admission,
because physical exclusivity is clear and externally observable. A bounded build/test burst is another
candidate if its pre-binary exclusion is explicit.

The gate must use independently built participants against the same real installed objects. Same-cell
contention, disjoint-cell concurrency, process death, quarantine, and incompatible-version refusal must all
be observed.

### Stage 3: Finite enforced process domain

Add one host/mechanism pair with a real creation-before-run and effective-value readback boundary, such as a
Linux cgroup or Windows Job Object for a bounded child process group. Do not yet admit providers, VMs,
clusters, mounts, or restartable services.

This stage should establish the exact `AppliedEnvelope -> ExecutionAuthority` seam and prove that work cannot
start before readback.

### Stage 4: Root coordinator as persistent anchor

Only after the dual-authority composition is specified should the root coordinator become long-lived. Add:

- authenticated client attachment;
- exact attempt retry;
- executable upgrade refusal/migration;
- reboot reacquisition;
- anchor death handling;
- closed project operation IPC; and
- process supervision on each supported host family.

### Stage 5: One recoverable persistent provider

Adopt one provider whose current ownership and recovery semantics are already strongest. Prove every paired
protocol/project crash prefix and delayed-operation case. Do not generalize to all providers until this
vertical slice demonstrates that the two durable machines compose without routine manual quarantine.

### Stage 6: Broader substrate and family adoption

Add further resource/mechanism rows only with live evidence on hosts that actually provide them. Maintain
honest `Unsupported` results for absent walls, especially bare-Linux storage, Darwin descendant memory,
existing unreconciled VM sizing, and WSL2's non-per-distribution CPU/RAM behavior.

## Required Acceptance Evidence

The protocol's conformance section is broadly appropriate. For `hostbootstrap`, acceptance additionally
needs evidence for the composition seam:

### Pure and serialization evidence

- exact `ProjectPlan` requirement conversion;
- protocol/project identity binding and changed-subject negatives;
- complete workload projection rather than an independently supplied list;
- base-plus-turn compatibility and overflow;
- alias closure, including unified memory and shared storage;
- exact mechanism-strength satisfaction;
- canonical record and receipt encodings; and
- saturation and offline-maintenance dispositions.

### Compile-fail and package-boundary evidence

- project code cannot construct protocol authority;
- a child cannot acquire or enlarge a host bundle;
- authority cannot be relabelled across project, plan, broker, attempt, cell, family, or mechanism;
- lower assurance cannot satisfy a stronger launcher;
- a receipt cannot enter a live-authority API;
- raw backend observations cannot settle either protocol or project authority; and
- the neutral package cannot import project lifecycle, command, provider, or plan modules.

### Cross-layer crash evidence

Every interruption point around both durable records must be exercised, including:

- protocol prepared before local prepare;
- local prepare before wall creation;
- wall application before readback;
- readback before local applied settlement;
- effect completion before project receipt;
- project receipt before protocol terminal settlement;
- protocol terminal write before lock release;
- anchor death and reboot;
- delayed provider completion after apparent absence; and
- recovery interpreter unavailable or artifact version changed.

Each case must have a single expected disposition: converge, remain busy, recover, retire, or quarantine.

### Live cross-project evidence

- two independently built participants contend on the same installed slot/cell/domain;
- disjoint cells run concurrently;
- whole device conflicts with every registered child partition;
- compatible child partitions run concurrently where supported;
- same attempt attaches or receives its retained terminal outcome;
- a different attempt in the same finite slot reports busy;
- holder death never silently frees uncertain external state;
- existing project-local locks do not bypass the global cell; and
- incompatible core clients contend on the permanent epoch object and refuse deterministically.

Tests that mutate or quarantine the real fixed root should run on a disposable conformance host or against a
catalog expressly installed for that gate. A repository-local or environment-selected root would not prove
interoperability with the permanent production objects.

## Decision Criteria

The protocol should advance from Draft to hostbootstrap adoption only when all of the following are true:

1. A neutral release authority exists and is accepted by the participating projects.
2. The core ABI is fixed narrowly enough that it imports no project lifecycle meaning.
3. Hostbootstrap's protocol/project composition and lock ordering are specified completely.
4. The anchor process role is reconciled with the single root coordinator and fixed command surface.
5. Pre-Haskell bootstrap scope is explicitly included or excluded without overstating coverage.
6. A development-plan phase or re-cut constructive narrative owns every implementation and validation step.
7. At least two independent implementations contend successfully on real permanent objects.
8. The first foreground profile provides enough operational value to justify catalog and installer cost.
9. Quarantine, migration, and saturation have usable operator tooling.
10. Persistent adoption demonstrates recovery rather than turning ordinary crash windows into manual
    quarantine.

## Final Assessment

The protocol solves the right cross-project problem and uses the right safety vocabulary. It is particularly
strong in its refusal to confuse capacity arithmetic, exclusive locks, hard walls, and crash recovery. Its
generic resource graph, separate mechanism releases, base/turn distinction, bounded durable state, and exact
cross-project contention model are credible foundations.

For `hostbootstrap`, though, the proposal is not a small interoperability-kernel addition. It currently
amounts to:

- a new machine-wide authority domain;
- another durable recovery state machine;
- a persistent root/anchor process model;
- a privileged installer and operator toolchain;
- a cross-project release and conformance organization; and
- a re-cut of where resource admission sits relative to `ProjectPlan`, prepared operations, and lifecycle
  recovery.

That scope may be justified, but it must be treated explicitly. The immediate next design artifact should
not be implementation code. It should be the hostbootstrap-specific composition contract that maps one exact
protocol lease into one exact project lifecycle and defines every lock order, journal transition, receipt,
and crash disposition between them.
