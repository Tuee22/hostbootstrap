# hostbootstrap Development Plan Standards

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md)

> **Purpose**: Define how the `hostbootstrap` development plan is organized, updated, and kept
> aligned with implementation, validation, and the governed `documents/` suite.

`hostbootstrap` is the reusable host-management layer for the project family
([`daemon-substrate`](https://github.com/Tuee22/daemon-substrate),
[`mcts`](https://github.com/Tuee22/mcts), [`infernix`](https://github.com/Tuee22/infernix), and
[`jitML`](https://github.com/Tuee22/jitML)).
It provides a Haskell `hostbootstrap-core` library plus a thin Python bootstrapper. This file is
canonical for `hostbootstrap`'s own plan; each consuming project keeps its own plan standards.

## Core Principles

### A. Stable Numbered Narrative and Explicit Execution Order

The plan reads as one dependency-aware description of the current Haskell-core library plus thin
Python bootstrapper consumed by project binaries. Phase numbers are stable thematic and historical
identifiers; after completed work is reopened, they are not themselves an execution schedule.

- New phases are appended rather than renumbering existing history.
- The executable order is the strict landing order in [00-overview.md](00-overview.md), together
  with each open sprint's `Blocked by` edge. That graph may intentionally schedule a higher-numbered
  reopening sprint before a lower-numbered dependent sprint.
- When a later phase depends on an earlier phase's closure obligation, the later phase names that
  dependency explicitly instead of duplicating the earlier phase's ownership.
- Phase 0 is always documentation and governance. Its **foundational** deliverables — the metadata
  standard, this plan tree, and the documentation validator — gate every code-writing phase. Follow-on
  documentation obligations are tracked explicitly without changing the status of unrelated code phases.
- Newly discovered gaps are handled by adding explicit follow-on work, not by leaving stale
  completion claims in older documents.

### B. Detailed, Implementation-Oriented Content

The plan is intentionally concrete.

- Include real files, module paths, command shapes, and validation gates where they materially
  clarify what must be built.
- Examples need not be verbatim implementation, but they must not contradict the supported
  architecture.
- When the plan cites a consumer project, it distinguishes the reusable `hostbootstrap` concern
  from consumer-specific behavior that remains out of scope here.

### C. Honest Completion Tracking

Status describes the current repository state, not the intended future state.

| Status | Meaning |
|--------|---------|
| `Done` | Implemented and validated; no remaining work |
| `Active` | Partially closed; remaining work is listed explicitly |
| `Blocked` | Waiting on a named prerequisite |
| `Planned` | Ready to start; dependencies are already satisfied |

Rules:

- `Done` requires passing validation, aligned docs, and no remaining work in that phase's scope.
- `Active` requires a `Remaining Work` section.
- `Blocked` requires a `Blocked by` line naming the prerequisite phase or sprint.
- If Phase 0 is still open, later code-writing phases use `Blocked`, not `Planned`.
- A later phase may stay `Done` while an earlier phase is `Active`/`Blocked` only when the open
  item is a clearly named external dependency the later phase calls out.
- `Active` remaining work may be **real-run/real-build-gated** — validated by a real host run or a
  base-image build rather than the canonical code-check. Such work is **in scope and open**, never "out
  of scope"; the phase stays `Active` until the real run or build closes it (see the
  [README Validation Policy](README.md)).

### D. Declarative Current-State Language

Current objectives, deliverables, and acceptance criteria describe the supported architecture in
present-tense declarative language. Cleanup obligations and the authoritative inventory of obsolete
surfaces belong in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

An obsolete name may also appear in an explicitly labeled historical delivery/scope record or dated
validation-evidence record when removing it would falsify repository history. Such a record must mark
the surface as historical rather than current and link to the deletion ledger when cleanup remains
open. Unlabeled obsolete names and obsolete names presented as current architecture are forbidden in
phase narrative.

### E. One Canonical Folder Model

The authoritative plan lives in this exact layout:

```text
DEVELOPMENT_PLAN/
├── development_plan_standards.md
├── README.md
├── 00-overview.md
├── system-components.md
├── phase-0-documentation-and-governance.md
├── phase-1-hostbootstrap-core-scaffolding.md
├── phase-2-host-tools-and-config.md
├── phase-3-ensure-reconcilers.md
├── phase-4-skeletal-dhall-and-command-tree.md
├── phase-5-cluster-lifecycle-and-resource-cordoning.md
├── phase-6-base-image-and-thin-python-bootstrapper.md
├── phase-7-consumer-migration.md
├── phase-8-dhall-generation-and-extension.md
├── phase-9-applied-cordon-and-one-parser.md
├── phase-10-standardized-test-harness.md
├── phase-11-incus-host-provider.md
├── phase-12-layered-warm-store.md
├── phase-13-hostbootstrap-demo.md
├── phase-14-composition-methodology.md
├── phase-15-binary-context-config.md
├── phase-16-project-lifecycle-command.md
├── phase-17-chain-driven-test-and-context-introspection.md
├── phase-18-service-runtime-command.md
├── phase-19-generic-project-model.md
├── phase-20-config-driven-demo-worked-example.md
├── phase-21-documentation-code-consistency-reconciliation.md
└── legacy-tracking-for-deletion.md
```

Phase numbering may grow as later work is scoped. Adding or renaming a phase requires updating this
file, `README.md`, `00-overview.md`, and `system-components.md` in the same change.

### F. System Component Inventory

[system-components.md](system-components.md) is the authoritative inventory for:

- `hostbootstrap-core` Haskell module surfaces (`HostBootstrap.*`)
- the `ensure` reconcilers and their host applicability
- the project-local `<project>.dhall` schema
- the runtime binary-context fields inside that local config
- the thin Python bootstrapper surface
- the explicit pipx self-update surface for the Python bootstrapper
- the base image contents and warm Cabal store
- the optparse command tree that consuming project binaries extend

When the host-management architecture changes, update the component inventory in the same change.

### G. Phase Document Requirements

Each phase document groups its sprint-level sections under one `## Sprints` parent, with each
sprint nested one level deeper, in this format:

```markdown
## Sprints

### Sprint X.Y: Name [STATUS]

**Status**: Done | Active | Planned | Blocked
**Implementation**: `path/to/file` (required for Done, recommended for Active)
**Blocked by**: sprint id(s) (required for Blocked)
**Docs to update**: `documents/...`, `README.md`

#### Objective

#### Deliverables

#### Validation

#### Remaining Work
```

Additional sections (`Module Surface`, `Command Surface`, `Reconciler Contract`) are encouraged
when they clarify closure criteria. The decimal-insert form (`X.Y.Z`) is permitted when later
scoping splits a sprint and renumbering would churn more cross-references than it is worth.

### H. Documentation Requirements Section

Every phase document ends with a `## Documentation Requirements` section:

```markdown
## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/X.md` - design contract

**Engineering docs to create/update:**
- `documents/engineering/Y.md` - technical note

**Cross-references to add:**
- align the relevant plan and README entry points
```

Before Phase 0 closes, paths under `documents/` may not exist yet; they still appear in
`Docs to update` and `Documentation Requirements` so obligations are explicit.

### I. Explicit Cleanup and Removal Ledger

[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is the authoritative cleanup
ledger for obsolete Python modules, the shelled `dhall-to-json` path, the three-execution-model
schema, and any stale compatibility surface. `Pending` lists existing cleanup obligations, `Retained
Current Surfaces` distinguishes intentional current code from cleanup work, and `Removed Surfaces`
names obsolete surfaces that must stay absent.

### J. README and Documents Harmony

The plan and the governed `documents/` suite must agree on current-state implementation status.
The root `README.md` is the finished-shape orientation document. It must not claim a capability is
implemented unless the plan marks the owning phase `Done`.

- `DEVELOPMENT_PLAN/README.md` is the **single cross-phase status source of truth**. Its phase table is
  the only place that summarizes every phase's live status. A phase document still carries the required
  local `Phase Status` and sprint statuses, but they must match that table; `00-overview.md` and
  `system-components.md` link to the table instead of maintaining another status roll-up.
- Exact test counts and real-run results are dated validation evidence, never a second “current suite”
  status. They live with the sprint whose gate produced them; orientation and inventory documents do not
  copy a mutable current count.
- `00-overview.md`, all phase files, and `system-components.md` use the same phase names and defer
  cross-phase current-state claims to the README table.
- `README.md`, `AGENTS.md`, and `CLAUDE.md` are governed root documents; root docs that are not
  canonical for a topic summarize and link to the canonical `documents/` home.

## hostbootstrap-Specific Contracts

Sections K–FF are the normative target contracts. They define what phase closure must make true; they
are not blanket claims that every invariant is already enforced. The
[README phase table](README.md#current-phase-status), phase-local `Current Status`/`Remaining Work`, and
the governed architecture documents distinguish implemented behavior from open repair. When a target
statement below conflicts with current code, the owning phase stays Active rather than weakening the
contract or describing the illegal state as supported.

### K. Host-Tool Resolution Doctrine

External tools are resolved through a closed `HostTool` enumeration to absolute paths in
`hostbootstrap-core`. No library or project code calls `proc "<bare-command-name>"` that resolves
through `$PATH`; every invocation reads an absolute path from typed host configuration. The enum includes
host-provider tools such as `colima` and `incus` (§ U); the in-VM tools they dispatch to are the VM's own
`$PATH` binaries reached through a single resolved host provider command (the VM is a separate machine —
the doctrine governs host invocation).

### L. Substrate and Ensure-Reconciler Contract

Substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`, `windows-cpu`, `windows-gpu`) is owned
by `hostbootstrap-core`.
**The purpose of the `ensure` suite is that an absent dependency with a supported install plan is
installed rather than treated as a manual prerequisite.** Context-free host dependencies are represented
by probe-first `ensure` reconcilers — a host-applicability predicate plus a reconcile action — exposed to
projects as library primitives
(`ensureDocker`, `ensureLima`, `ensureCuda`, `ensureCudaWin`, `ensureWsl2`,
`ensureHomebrew`, `ensureGhc`, `ensureIncus`, and the accelerator build-stack reconciler
`ensureAppleMetal`) and as `ensure-*` step kinds composed into the lift chain. There is no
top-level `ensure` command and there are no hidden commands. The target reconcile action **installs** the
dependency when its total probe reports absence and a plan exists, then re-probes; a satisfied capability
is a verified, typed no-op. Current install-and-reprobe behavior is idempotent only to the strength of
each probe or package-manager no-op path; several probes and raw `IO ()` results do not yet prove
resource identity or retain a typed reconcile outcome. An absent-but-installable dependency is therefore
installed rather than reported as a manual prerequisite. The Python wrapper's host minimums (§ M) are the only intentionally non-installing
**pre-binary** prerequisite gate, not the system's only failure class. A reconciler fails closed on
wrong-host applicability, an irreducible/non-installable precondition, a conflict or safety refusal, or
failed post-install verification. NVIDIA device/driver visibility is part of
substrate detection: without a working `nvidia-smi`, a host is not classified as `linux-gpu` or
`windows-gpu`, so the GPU reconciler rejects that substrate rather than claiming it can install a driver
for hardware it cannot yet identify. Once a GPU substrate is established, its installable toolchain
dependencies are reconciled normally. `ensure incus` is explicitly applicable
on **both** apple-silicon and linux — on Apple it prepares the Colima-backed Incus provider for explicit
Incus workflows, and on Linux it initializes the native daemon that encapsulates a fresh linux host (§ U).
It is not the first or only cross-substrate predicate: current `Ensure.Docker` declares
`appliesTo = const True`, although its absent-daemon install plan is Linux-only and delegates/refuses
elsewhere.
Provider adapters that require validated project/config/plan authority are not config-free reconcilers
and cannot appear in `allReconcilers`. In particular, direct Apple Colima consumes a plan-bound project
profile plus the admitted wall/partition/reservation, installs the tool if absent, observes exact
runtime/CPU/memory/disk state, and never treats `default` as project authority.
The worked demo's default Apple Silicon VM path uses Lima, not an Incus VM. The
kube tools (`kubectl`/`helm`/`kind`) are baked into the L0 base image and the cluster lifecycle that
drives them is L0 (Phase 5), so they need no separate host reconciler in the in-container path. The worked
accelerator demo's CUDA base also carries `nvkind`; Phase 5 owns that cluster driver as an L0 lifecycle
primitive, and the project selects it only for the explicit Linux GPU direct-container topology. Future
project-specific GPU tools can still be contributed by a consumer or mid-layer (`daemon-substrate`)
through the extension-stream merge (§ T). The accelerator-daemon demo keeps
the same boundary: Apple Silicon and Windows GPU host daemons run host `ensure` for the Swift/Metal or
CUDA build stack, while Linux CPU/GPU daemon pods do **not** run in-container ensure and instead trust the
published hostbootstrap base image to contain `clang++` or `nvcc`. The `ensure` reconcilers are normally
invoked as **chain steps** within `project up` (§ Y), not as hand-run verbs. The target provider
reconciler reaches a **usable** provider, not merely an installed binary, and observes any egress the next
step requires before minting readiness. Current Linux `ensure incus` checks only client presence and no
provider reconciler verifies egress; Phase 11 owns that gap with Phase 9's observation types.

### M. Python-Thin / Haskell-Core Boundary

In the ordinary `doctor`/`build`/`run` project path, the Python bootstrapper does only the **minimum to
build the project binary**: discover the single Cabal file and executable stanza, assert the fail-fast
host minimums, ensure the host toolchain prerequisites needed to **build** the binary, then build the
project binary **host-native** and invoke it. Handoff uses POSIX process replacement with `exec` and a
child subprocess whose exit code Python returns on Windows.
Python does not initialize or trigger config creation. The binary owns its
Dhall — a normal command fails fast (exit 1) when no sibling `<project>.dhall` exists, and the config is
created by an explicit `project init` or generated by the test harness through the scope-aware
`psAssemble`. Python itself
does not read or write Dhall. Those fail-fast host minimums are the irreducible, intentionally
non-installing **pre-binary** floor (OS version, passwordless sudo, Xcode CLT + Homebrew as the Apple
toolchain root, and on Windows winget and Windows PowerShell as the toolchain root). After the binary
exists, each dependency with a supported `ensure` install plan is installed when absent and re-probed
(§ L); wrong-host use, non-installable prerequisites, conflicts, safety refusals, invalid authority, and
failed verification still fail closed. The bootstrapper does **not** ensure Docker and does **not** build
the project container — those are not pre-binary necessities; the project binary, once running, ensures
Docker, builds the project container, drives the VM provider (including WSL2 on Windows), drives the cluster, and does everything
else it reasonably can. There is **no copy-out**: a binary built inside a
Linux container cannot exec on a general host such as Apple silicon, which is why the binary is built
host-native and the Python layer must ensure the host build toolchain first. Reusable host-management
primitives and interpretation live in `hostbootstrap-core`; consumer-specific provider/build actions
live in the project binary (Haskell). New host logic defaults to one of those Haskell layers according
to ownership, and a Python addition must be justified by the pre-binary bootstrapping constraint. The
shape the Python layer runs — provision the host, build the pb host-native, then hand off by the
substrate's invocation mechanism — recurs at **every** frame the
binary later crosses (§ U): the Python bootstrapper is the **metal-frame instance** of the fractal
bootstrap, and each chain descent repeats provision → build the pb in the frame → hand off
`pb project up`.

The explicit pipx `update` surface and repository-maintainer `base`/check/test command set are separate
distribution operations. An operator may ask Python to update the installed application or build/publish
a base image, but those commands do not enter the project lifecycle and do not move Dhall, provider,
project-image, cluster, service, test-run, or teardown ownership out of Haskell.

The pre-binary bootstrap is an early phase dependency, not a later convenience: on a fresh host it is the
way the repository obtains the Haskell toolchain needed to validate `hostbootstrap-core`. Therefore the
toolchain bootstrap is tracked with the host-floor/tooling phase (Phase 2), while later phases consume the
result. Later phases must not introduce a prerequisite that an earlier Haskell validation gate needs.

The Python layer also owns its own explicit pipx self-update path, because that command replaces the
pipx-installed bootstrapper before or outside any project binary. This is distribution lifecycle, not
host-management logic: it is not an `ensure` reconciler and it must not contain Docker, Dhall, VM,
cluster, resource, or cordon behavior. With no versioned Python release channel, the canonical update
primitive is a forced pipx reinstall from the direct VCS requirement for the default branch. Self-update
is operator-invoked only; `doctor`, `build`, `run`, and `base` must not auto-update, auto-check GitHub
freshness, or fail merely because the wrapper is not at the latest commit.

### N. Host-Native Binary Build

Every project's binary is built **host-native** on every substrate — it is **not** built inside a Linux
container and copied out, because a binary built in a Linux container cannot exec on a general host (e.g.
Apple silicon). The universal pre-binary host dependency is therefore the **build toolchain**, not Docker.

- The Python bootstrapper ensures the host Haskell build toolchain and Cabal package index (Homebrew →
  `ghcup` → GHC/Cabal on Apple; the equivalent on Linux; a pinned, integrity-verified `ghcup.exe`
  retrieved through Windows PowerShell → GHC/Cabal on Windows) —
  the prerequisites to build the binary — then builds `./.build/<binary>`
  host-native and invokes it (POSIX `exec`; Windows child subprocess); it does not initialize or trigger
  config creation (the binary owns its Dhall, § M). A `./.build/<binary>` is always present on the host
  after the build.
- The project **container** is a separate artifact the **project binary** builds (via Docker, `FROM` the
  base image) once it is running — the workload image and the mandatory code-check quality gate. The
  Python layer neither ensures Docker nor builds the container (§ M).
- On Windows, CUDA is a **build-only host capability** — the **headless host build** (composition
  pattern #7): NVIDIA device/driver visibility establishes the `windows-gpu` substrate, then `ensure
  cudawin` readies the CUDA Toolkit, MSVC VCTools, and LLVM clang; nvcc artifacts are produced on the bare
  Windows host and staged into the cluster, and no workload runs in a build VM. On
  native Windows GHC `System.Info.os` is `mingw32`, so the core's POSIX-only `unix` dependency is
  conditionalized at its three call sites to build the binary host-native.
- Inside a managed Linux VM (§ U) the same host-native build applies — Lima on Apple Silicon,
  native Incus on Linux. The VM is a fresh linux host: the pipx-installed `hostbootstrap` ensures the
  toolchain, builds the binary host-native, and hands off by POSIX `exec`; the binary then ensures Docker and builds the
  container in the VM. The worked demo's pristine-host bootstrap counts **3 builds** — a metal
  orchestrator build plus, inside the pristine VM, the host-native binary build and the binary-driven
  project-container build — a demo-only illustration, not the standard workflow.

### O. Resource Budget and Cordoning

The target has one opaque validated per-project budget (`cpu`, `memory`, `storage`) and no independently
editable copy. Admission rejects a declaration that the selected provider cannot represent exactly, so
the byte-valued `EffectiveBudget` equals the user-visible `ValidatedBudget`; no builder may silently
round a hard ceiling upward. The canonical indices are:

```text
ValidatedBudget scope planId budgetId
ProviderBudgetCapability scope planId provider capabilityId
ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId
EffectiveBudget scope planId budgetId provider capabilityId wallSpecId
PlannedWorkloadSet scope planId workloadSetId
VerifiedWorkloadFit scope planId budgetId provider capabilityId wallSpecId workloadSetId
BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId
ResourceSlice
  scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame resourceId
ProviderWallReservation scope planId provider wallSpecId reservationId fence
ProviderWallAuthority scope planId provider wallSpecId wallEpoch fence
WslGlobalWallLease scope planId wallSpecId wallEpoch fence
```

Provider selection first yields only a pure `ProviderBudgetCapability`; it grants no ownership or
mutation authority. Exact admission consumes that capability with the validated declaration and jointly
mints a `ProviderWallSpec ... wallSpecId` plus an equal, exactly representable
`EffectiveBudget ... wallSpecId`. `fitsBudget` consumes the same-index workload set and yields only the
matching fit proof. Partition construction consumes those pure values and mints exact plan/frame resource
slices before any provider-wall acquisition or reconciliation effect.

Only after the proved `BudgetPartition` exists may a journaled wall-acquisition operation reserve the
same `wallSpecId`. Its exact prepared adapter consumes the wall spec, partition projection, and
`ProviderWallReservation`; it may create/apply or observe the initial provider wall and returns a live
`ProviderWallAuthority scope planId provider wallSpecId wallEpoch fence` only after an authoritative
applied/unchanged observation. The token that authorizes this initial call is the journaled reservation,
not the post-effect authority it will mint. A backend with a pre-create authoritative reservation exposes
that reservation explicitly; it cannot manufacture the later authority early.

For WSL, the `ProviderWallReservation ... reservationId fence` itself retains the platform-exclusive
pre-call lock/CAS across the shared-wall call. Authoritative applied/unchanged observation consumes that
reservation and jointly returns the epoch-indexed `WslGlobalWallLease` inseparably with the live
`ProviderWallAuthority`; the post-observation lease is never a precondition for its own minting. An
unknown reservation/acquire/apply outcome yields only same-spec recovery state until exact reprobe
settles it. Every later reconcile or dependent
budget-relevant mutation requires both a projection carrying the same `wallSpecId` and that live
authority and revalidates its `wallEpoch`/`fence`. Thus the effective value or pure wall spec alone is
never write authority. The partition proves that every positive
slice plus provider overhead is at most that same wall and that each provider/node minimum is met. A
zero, oversized, or floor-rounded “strictly smaller” cluster slice is unrepresentable. The budget is
never added to itself. Separately, the metal preflight requires
`host RAM ≥ budget + 4 GiB host reserve`.

Current implementation now provides the Phase 9 pure admission foundation, while provider adapters and
complete workload projection remain owned by their dependent sprints:

- demo `ProjectConfig.resources` is the sole editable budget. `BinaryContext` contains placement and
  command-gating data but no resource-envelope copy; child projection preserves the already-refined
  `Resources`;
- `Quantity`, `Resources`, `HaReplicas`, `Port`, and `TimeoutSeconds` hide their constructors and expose
  total smart constructors. They have no `Num`/`IsString` bypass, and CLI assembly returns a data error
  before lifecycle effects when refinement fails;
- `parseQuantity` uses exact integer decimal arithmetic. Lima/Colima/Incus/WSL builders and
  `ProviderWallSpec` admission reject a quantity that is not exactly representable in whole GiB rather
  than rounding a hard ceiling upward;
- `ValidatedBudget`, the closed typed `ProviderKey` relation, jointly indexed `ProviderWallSpec` /
  `EffectiveBudget`, non-empty `PlannedWorkloadSet`, `VerifiedWorkloadFit`, constructive
  `BudgetPartition`/`ResourceSlice`, and journal-before-call `ProviderWallReservation` /
  `ProviderWallAuthority` are opaque. Successful WSL settlement returns its `WslGlobalWallLease`
  inseparably with the live authority;
- the demo-local `clusterSliceOfBudget` remains a legacy calculation used by the current interpreter,
  not a `BudgetPartition` proof. The complete plan-derived workload/slice projection is Sprint 13.18
  work;
- `verifyBudget` is wired as the cluster-capacity preflight. `fitsBudget` is only a helper/test/static
  API calculation; lifecycle does not derive or check the exact non-empty concurrent workload set;
- new Lima/Incus/WSL resources receive initial sizing, but existing VM/VHDX sizing is not uniformly
  compared or reconciled. Direct Colima has a prepared exact project-profile adapter that disables
  global context activation and routes Docker through its named context; recursive command consumption
  and conditional cleanup remain downstream. Direct Linux GPU outer build/container effects are
  uncapped; only the later nvkind nodes receive CPU/memory caps. Bare Linux has no storage quota or
  image-GC wall;
- WSL2 has no per-distro CPU/memory cap. Its global `%UserProfile%\.wslconfig` affects every distro, and
  the production route still infers ownership from backup existence, so concurrent project declarations
  can race or overwrite one another and an absent original has no durable origin record. A
  focused-tested pure state model and exact UTF-8/UTF-16 byte transformer exist; the four § EE clauses
  are not yet held at this call site. An existing running distro/VHDX need not adopt a changed
  declaration;
- the WSL2 wall is also not released on `project down`: teardown terminates the distro and restores the
  file, but the managed body pins the idle timeouts to `-1`, so the shared utility VM retains the full
  memory balloon indefinitely. Lima and Incus release their walls on stop. Until WSL2 does the same, the
  "a project holds its wall from `up` until `destroy`" contract is stated uniformly but honored on two
  of three provider substrates.

The target defense has three closed rings: promotion mints the sole provider-exact `ValidatedBudget`;
plan preparation runs `verifyBudget` plus `fitsBudget` over the exact non-empty workload/effect set and
constructs the proved `BudgetPartition` before its first dependent mutation; and runtime reconciliation
first journal-acquires/revalidates the same `wallSpecId` and then either applies the matching
`EffectiveBudget` everywhere or returns typed `Unsupported`/`Conflict`. Existing
walls return typed unchanged/migrated/refused results. Lima and Incus own per-VM walls. WSL2 instead owns
one provider-effective shared utility-VM wall behind an exclusive, crash-recoverable global-state
lease/CAS; each distro may own its VHDX slice, but incompatible concurrent wall declarations refuse
rather than overwrite `%UserProfile%\.wslconfig`. The WSL wall mutation permit consumes/revalidates the
same `wallSpecId`/`wallEpoch`/`fence` as the `ProviderWallAuthority` and `WslGlobalWallLease`; a
same-shaped value from another plan or owner cannot apply or restore it.
Sprint 9.10 owns the exact admission/partition algebra, closed Sprint 9.4 records the typed
bare-Linux-unsupported storage decision, closed Sprint 5.8 owns direct Colima acquisition, Sprints 5.7
and 11.10 own the remaining provider/cleanup walls, Sprint 13.18 the complete demo workload projection, and
Sprint 19.8 the single finalized plan/config authority. A Dhall-native `Budget/fitsWithin` assertion is
not attached to generated config because that config contains text quantities and no resolved pod set.

Project budget interpretation remains Haskell-owned; Python does not size project VMs or clusters. On
Linux, the maintainer-only `hostbootstrap base build` separately measures host CPU/RAM and caps the
warm-store build container. On macOS and Windows the current command supplies no explicit Docker
CPU/memory caps and retains the Dockerfile's `-j1`; it must not be described as host-sized there. That
build-phase limit is not an interpreter of `<project>.dhall`; see
[base_image.md](../documents/engineering/base_image.md#host-sized-warm-store-build-budget).

### P. Fixed Command Surface And The Extension Streams

`hostbootstrap-core` exposes a **fixed** command surface plus a project entrypoint
(`runHostBootstrapCLI progName projectSpec`). Every project binary — and the bare `hostbootstrap` binary —
surfaces the **same** tree: the three DSL-driven commands `project init|up|down|destroy`,
`test init|run`, and `service init|schema|run` (§ Y, § Z, § AA), plus the read-only `context`
introspection command and `check-code`. There are **no per-project verbs**: `hostbootstrap-core` is a
**library of composable tools** (step kinds, reconcilers, the self-reference lift, service handlers), not a
CLI topology, so a project never adds a command. A project extends the core only through the
**extension streams** finalized into opaque `ProjectSpec`: additive step fragments resolved to one
validated **lift plan** (`StepPlan`, § Y),
the **Dhall vocabulary**, the **schema-gen** `ConfigArtifact` registry, the **test seams** (a non-empty
test suite), and the **service runtime seam**: a possibly empty typed `ServiceRegistry`. Each definition
inseparably binds identity, structural field projection, reflected role codec, and handler; there is no
independent string selector. Registry finalization jointly binds the full `ProjectCodec`, role-wire
`RoleCodec`s, and canonical `specDigest`. A parent/local admission projects only a role-specific
descriptive wire; verification mints the opaque
`ValidatedServiceRequest specDigest configId secretDigest fields service`. The sole selection gate consumes that request, exact
leaf placement, inseparable revision/instance activation/projection package, and the finalized typed registry to
produce an existential
`SelectedService scope specDigest planId configId secretDigest frame revision instanceId ServePhase
fields`. The package contains a matching
`ServiceSelection scope specDigest planId configId secretDigest frame revision instanceId ServePhase
service effects` proof and handler
program for the same `service` and authorized `effects`; the handler receives only the bundle's
`RoleParams specDigest configId secretDigest fields service`, never the full config. The Dhall
`ServiceType` ADT lives in the project's `cfg`; it is not the handler registry. These
streams sit alongside the project `check-code` action. Static finalization validates those extension
points before parser construction: duplicate cases/artifacts/inputs/service identities and conflicting
single assignments are rejected; the test suite and step contribution must be non-empty; each resolved
plan has unique typed identities, exact contiguous frame order, and explicit reverse policy;
the declared project name must equal the invoked executable identity, and `check-code` is supplied by
construction rather than silently defaulted. `ProjectSpec` carries **no**
`ProjectCommand` deltas — the surface is closed (see
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)). The bare `hostbootstrap` binary
(`hostbootstrap-core`'s own executable) uses the separate `runBareHostBootstrapCLI` entrypoint; it is
built like any project binary, not baked into the base image.

### Q. Configuration via Dhall

Configuration is typed Dhall in distinct roles:

- the **local runtime config** `<project>.dhall`, generated by the built project binary, read from next to
  the executable before normal command dispatch, and edited by the user for host-level settings;
- the **generated child config** `<project>.dhall`, materialized by a parent binary at VM, container,
  daemon, and service boundaries. Current descriptive context/capability declarations are narrowed, but
  the demo payload remains the full `ProjectConfig` and inherits the full resource envelope; the target
  uses role-specific parameter types, exact plan/frame resource slices, and separately verified opaque
  authority;
- the **rich project/deploy** Dhall and one project-defined typed `<project>.test.dhall`. The latter maps validated
  `CaseId`/`VariantId` selections and overrides to generated run `cfg` variants through the
  project-owned projection (Phase 19.6); it is not one file per case. Selected top-level scalar/resource
  fields are checked at decode; complete applied-budget validation and the pod-set bring-up check are
  Phase 9.10 targets, not current claims. No generated `fitsWithin` assertion is claimed. Both are
  generated by the project binary from a reusable Dhall vocabulary. The ungated
  `context render` surface renders static registry examples; runtime deploy and child projections are
  emitted by commands that have already validated the active local config.

The current project binary exposes two distinct schema surfaces and one default writer.
`context schema` prints the in-scope static `ConfigArtifact` registry; `service schema` currently prints
the validated-codec full project-local `cfg` shape; and `project init` writes a default full project
config. The opaque lower-layer witness admits that schema only after the normalized `ToDhall`
`declared` and `FromDhall` `expected` expressions are judgmentally equal; semantic round trips remain a
separate test obligation.

The target keeps the command tree but separates trust domains. Finalization computes one canonical
`specDigest`; `FinalizedProjectSpec scope specDigest cfg fields` inseparably contains the matching
project, framework-envelope, role, and registry codecs. `ProjectCodec scope specDigest cfg` validates the
full root/Harness config. Because the scope-indexed secret vocabularies differ, the full schema is an
explicitly named `Production`/`Harness` `ConfigArtifact` family in the
`context schema`/`context render` registry, never one scope-erased union. A jointly finalized project-owned
`RoleCodec scope specDigest fields` derives the closed `RuntimeRoleWire fields service` family from the hidden
consumer-indexed field schema and typed service registry. `service schema` prints that role-wire schema
registry/union as explicitly named `Production` and `Harness` scope families, because their secret
vocabularies can differ; it never conflates them as one schema. Harness role schemas contain typed
secret handles, not inline `TestPlaintext`; private run-scoped bundle bytes are a separate digest-bound
channel. `service init` writes one selected
Production role wire, while the harness assembler/projection writes Harness role wires internally. No
schema output contains secret values or promotes Harness to Production. An explicitly empty service
registry has an explicit empty result for both families and no runnable role.

The lower schema layer mints an opaque `CodecWitness a` only after normalized encoder/decoder expressions
compare equal. The project boundary wraps those proofs with installed identity and scope; full-config
decoding/plan construction consumes `ProjectCodec`, while runtime-role rendering and verification
consume the inseparable `RoleCodec` derived from the same finalized field schema. Every
committed hand-written `Core.dhall` type must either be generated from the codec or have an explicit
judgmental-equality test. Round-trip/property tests remain required for semantic encoding behavior.
Python derives the project name from the Cabal file and has no Dhall-facing configuration role: it
builds the host-native binary and invokes it using the platform-specific handoff above; the binary owns
config creation (§ M). Python never reads or writes Dhall itself.

`specDigest` remains on `ValidatedConfig`, `ProjectPlan`, plan drafts/bindings/frames, service
requests/parameters/selection/programs, and build authority. An activation manifest additionally binds
the measured `binaryDigest`, exact `configDigest`, and separate `secretDigest`. This document sometimes
uses shorter type names in explanatory prose; those are readability abbreviations only, never permission
to erase these indices. Same-shaped values from different finalizations, binaries, config bytes, or
secret bundles cannot cross-pair.

Full and role wires share one jointly derived, opaque
`FrameworkEnvelopeCodec scope specDigest fields`, a closed wire-kind discriminator, and a closed
descriptive Production/Harness scope-kind discriminator. It validates only the framework identity/context/topology fields needed before routing
and yields `LocalContextView scope specDigest wireKind frame`; it cannot expose service parameters or mint command
authority. Config-free `context inspect`/`context show` start from the installed project's scope-erased
`FinalizedSchemaFamily`, select the one named Production/Harness envelope codec identified by that tag,
require it to validate the same tag, and return a display-only scope witness. Missing/unknown,
disagreeing, or structurally ambiguous scope evidence yields an explicit display error rather than a
guessed witness. Authority-bearing dispatch gets scope only from its independently verified
root/handoff/activation package and then requires the descriptive tag to agree. The view applies to
either a full project wire or a
cluster-service/daemon role wire. Existing-frame routing performs the same first-stage discrimination:
project lifecycle and ordinary `check-code` require `FullProjectWire` before invoking `ProjectCodec`,
while `service run` requires `RuntimeRoleWire` before invoking `RoleCodec`. Thus a valid role wire receives
a structured wrong-command/authority refusal instead of being mislabeled malformed full config, and no
route can choose the wrong second-stage decoder.

### R. Quality Gate Contract

Static quality is a first-class requirement. The Haskell formatter is `ormolu`/`fourmolu` and
`hlint` runs against supported source roots, both installed in the base image from current compatible
upstream releases selected by the rolling build. Every image build, base
or derived, gates on the project's canonical `check-code` — for a derived image, a single in-Dockerfile
`RUN <project> check-code` stage whose body is project-defined. The standardized test harness's
`<project> test` report card is the project-level validation gate. The mechanical documentation
validator (`HostBootstrap.DocValidator`) runs through the code-check. The plan
distinguishes mechanically enforced gates from editor-only guidance.

### S. Imported Practices and Explicit Non-Adoption

`hostbootstrap` borrows the governance shape (metadata blocks, phase plan structure, completion
tracking, declarative current-state language) from the consumer projects. It does not adopt any
consumer's product features, runtime surfaces, daemon-role model, or hardware-correctness
validation cadence; those remain consumer concerns. Non-adopted external doctrine must not be
treated as a current blocker or completion criterion. The standardized test harness and the four named
execution shapes are `hostbootstrap`-owned doctrine, but the shapes are expressed by the consumed
lifecycle plan rather than a parallel selector or Dhall literal (§ T).

### T. Library Hierarchy, Extension Streams, and Execution Shapes

`hostbootstrap-core` is a **library of composable tools**, not a CLI topology; the command surface is
fixed (§ P) and is **not** an extension point. The reusable surface is a three-level Cabal library
hierarchy: `hostbootstrap-core` (L0) ◄ `daemon-substrate` (L1) ◄ `{jitML, infernix}` (L2); `mcts` consumes
L0 directly. Each level adds only its delta to the **parallel extension streams**, one additive merge idiom
each: additive **step fragments** (`cfg -> [Step]` — the level below's host-management step kinds
with the project's own step kinds appended, interleaved, validated into one `StepPlan`, and interpreted by the core `project` lifecycle,
§ Y); the **Dhall vocabulary** (`let C = ./Core.dhall`, embedded, never redefined); the **schema-gen**
`ConfigArtifact` registry (concatenated across levels through `ProjectSpec`); the **test-harness** `Seams`
(threaded through a non-empty `TestSuite`); and the **service runtime seam** (an additive, possibly empty
typed registry jointly finalized with the config/role codecs; Sprint 18.6 adds the
config/frame-indexed `SelectedService` execution package, § AA). A project integrates through a Cabal dependency
(`source-repository-package` with a full immutable commit `tag` for a remote consumer, or a local
package in this repository) plus the `runHostBootstrapCLI` extension. A moving branch or omitted remote
tag is not a governed input. A freeze file constrains dependency solving; it is not an integration
API. The former freeze-only base-image `LABEL`/`ENTRYPOINT` mode is not implemented and is tracked for
deletion rather than described as current. Four names classify execution **shapes** — `OneShot` (one-shot
`docker run`), `HostNative` (host-native build + host invocation), `HostDaemon`/service (a long-running role,
reached via `service run` as a leaf-frame service or daemon entrypoint, either controller-managed in a pod
or lifecycle-managed on the host, § AA), and `Cluster` (kind+Helm). These are consequences of the typed
steps in the one project lifecycle plan (and, for a service leaf, its local service-role config), not a
second selector representation and not a `Core.dhall` field. Sprint 10.10 removed the former
unconsumed parallel definitions.

### U. Host-Provider Axis And The Self-Reference Lift

A project binary crosses an execution-context boundary by invoking its **own** subcommand in the nested
context — the self-reference lift (`HostBootstrap.Lift`). Contexts compose as provider-backed frames,
outermost-first; the empty stack is the local host. The VM layer is provider-specific: Apple Silicon uses
Lima (`limactl shell <instance> -- ...`) for the demo VM, native Linux uses Incus
(`incus exec <vm> -- ...`), and Windows uses WSL2 (`wsl -d <distro> -- ...`) provisioning a fresh
Ubuntu-24.04 distro. A **derived project container** is the `docker run --rm` layer whose project
Dockerfile installs the binary as its `ENTRYPOINT`; this is not the removed freeze-only base-image
integration mode (§ T).
The stack nests — host → VM → container folds to the selected VM provider command followed by
`docker run --rm <image> <subcmd>`. Before a nested call crosses a boundary, current code obtains a
context-adjusted child config through a separate projection seam and **streams it in-place over the
lift's `stdin` channel** (§ X) — the callee writes it to its own sibling path before dispatch — so the
callee can explicitly reason about its place even though it runs the same command tree. That payload
still has the demo's full project record and parent resource envelope. Current delivery uses `stdin`,
with no parent-side intermediate config file or bind-mount (the Kubernetes service pod's ConfigMap
override is the exception, § AA), but the child sibling is persisted and inspectable in the child frame.
The target plan owns both projection and delivery and carries only a role-specific payload. Each
nested call runs the same command tree, so a step runs "locally." Current reconcilers are
context-agnostic `HostConfig -> IO ()` callbacks; the target retains independence from raw
`BinaryContext` but replaces that result-free signature with a plan-minted scoped transition descriptor,
resource/dependency inputs sealed into an exact `OperationPreconditionSet`, a prepare-time fresh
`PreparedOperation`/`PreparedPreconditions` pair, and structured `ReconcileResult` (§ CC/§ EE). A
retained readiness capability is never a backend-adapter input. The argv fold
is pure (unit-tested) and honors § K: only the outermost host dispatch names a
tool the resolver maps to an absolute path; every nested tool is the target's own bare `$PATH` name.
`SubstrateProvider` plus the n-level `Lift` frame stack is the one provider/dispatch abstraction.
The former definition-only `HostTarget = Local | InVM` predecessor has been removed and must not return
as a parallel public dispatch path; its removal is recorded in the cleanup ledger. L0 owns only the generic lift; the *specific* chain (the worked
demo's host → VM → container) is project logic. The chain is interpreted **recursively**: `project up`
runs the current frame's steps, then hands off `pb project up` into the next frame, so each binary owns
its own segment and the command can be invoked at any declared frame (§ Y). Current recovery after a
partial failure is best-effort; only the target durable journal, ownership receipts, and revision-bound
recovery make convergence restartable. Each frame transition repeats the same three beats — provision
the frame, build/install the pb in it, hand off `pb project up` — of which the Python bootstrapper (§ M)
is the metal-frame instance. See
[composition_methodology](../documents/architecture/composition_methodology.md).

### V. Opportunistic Warm Store

The base image pre-builds a broad Cabal dependency set as a best-effort performance cache. The store is
not a public version, freeze, or offline-build contract: consumers use their ordinary host-compatible
`cabal.project` unchanged inside a derived container, do not import `/opt/basecontainer/...` project or
freeze fragments, and may download or compile dependencies when no matching store artifact exists.
Warm-store manifests may group dependencies for maintainability, but those groups do not define
consumer layers or solver inputs. Cache reuse is opportunistic and must never be an acceptance
requirement.

### W. Single Representation And The Harness That Drives The Chain

An operation has exactly **one** representation. The target is an opaque
`ProjectPlan scope specDigest planId configId cfg` constructed inside a rank-2 continuation from a
lifecycle profile, `ValidatedConfig scope specDigest configId (cfg scope)`, and a non-empty validated
`PlanDraft scope specDigest (cfg scope)` sequence. Here `cfg :: Type -> Type` is a scope-indexed config family;
`configId` binds the exact decoded/authenticated bytes and generative `planId` prevents two Production
plans from sharing journals, handles, or receipts. `project up` interprets the forward projection and
`--dry-run` renders that same projection (§ Y). Frame topology, resource identity/acquisition, and the
verb-indexed reverse projections retain that `scope`/`planId` and are derived from the plan;
independently supplied plan, frame-context, and teardown interpretations violate this doctrine and are
removed by Phase 16.6. The current opaque validated `StepPlan` supplies one exact forward ordering, but
separate checked frame-context/teardown contributions are not by themselves the finished lifecycle
representation.
There is no second hand-written orchestration path
beside the chain — and the test harness is not one. The standardized test harness
(`HostBootstrap.Harness`) **drives the real `project up`** rather than re-expressing bring-up: per distinct
test configuration it writes a test-specific `<project>.dhall`, runs `project up` over the project's own
chain, runs the case assertions in the frame appropriate to each (reusing the self-reference lift, § U),
and tears the stack down with `project destroy`. The bring-up a test exercises is therefore **the same
chain** production uses — there is no parallel `seamSetup` that stands up a cluster a second way, and no
resource model that can drift between test and deploy. Crossing into the self-invoked process uses the
authenticated, one-time scope handoff defined in § EE; a generated config is never treated as authority.
The harness owns only the case matrix, the per-case assertions, and the test-config parameters; it never
owns a second cluster-bring-up path. Re-expressing
deploy bring-up as a parallel chain of lifted ops alongside the chain — including inside a test seam —
would be a redundant representation. Cross-references: § Y (the chain and its recursive interpreter), § Z
(the chain-driven test surface and its safety preconditions), and § U (the self-reference lift the chain
and the in-frame assertions are built from).

### X. Binary Context Configuration And Command Gating

`sourceRoot` is descriptive configuration, never host-path authority. Root-config admission resolves it
exactly once against the stable project-home anchor owned by the selected root config (never the
caller's current working directory), verifies that it denotes the intended project tree, and
canonicalizes it before any plan is opened. That effectful bracket yields an opaque
`CanonicalProjectRoot scope rootId`; callers cannot construct one from `Text`/`FilePath`,
`getCurrentDirectory`, the executable's sibling `.build` directory, or a later re-read of config.
`withProjectPlan` consumes that authority and derives every project-relative resource, including the
Production `.data` or Harness `.test_data/<runId>` root, under the same `rootId`.

One durable resource therefore has one identity and may have several **typed projections**, not one
portable pathname string. Direct-host Docker mounts consume only a verified canonical host path derived
from `CanonicalProjectRoot`. Provider-backed lanes may additionally reconcile a provider-local guest
alias, but that alias is a `GuestPath provider frame` projection and never replaces, authenticates, or
reconstructs the host root. Container, kind-node, pod, and guest paths remain distinct types until the
adapter that owns the boundary renders them. A pure frame planner consumes these projections from the
plan; it does not perform IO, reinterpret `"."`, concatenate an untrusted source root, or choose a
host/guest path by convention.

Every project binary must know where it is in the global composition chain through a sibling runtime
config file:

```text
<project>.dhall
```

Python currently discovers the Cabal-file stem and sole executable stanza separately, builds the
host-native executable, and invokes it using the platform-specific handoff in § M; it does not initialize
or trigger config creation (the binary owns its Dhall, § M). Phase 6 replaces the parallel names with one
validated `ProjectIdentity`. The built
binary owns `project init` / schema / help surfaces for creating the first host-level sibling config.
After that, each nested project binary receives or creates its own local config before it runs:

- a VM bootstrap **streams the VM-local context in-place**: the parent renders the narrowed VM projection
  and pipes it over the lift's `stdin` channel into the VM, where the descending binary writes its own
  sibling `<project>.dhall` before it runs;
- the project Dockerfile installs the binary, then runs
  `project init --role image-build-container --output /usr/local/bin/<project>.dhall` before any normal
  command; in the target that baked config is descriptive and build-time `check-code` additionally
  consumes ephemeral
  `BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest`
  from the build
  coordinator. The authority binds inputs known before the image exists; the resulting image digest is
  recorded afterward;
- runtime container launches receive the parent-rendered runtime projection the **same in-place way** —
  streamed over `stdin` into the single `docker run` and written to the sibling path before dispatch — for
  the exact VM/container frame the container is launched into, with **no host-side intermediate config
  file and no config bind-mount**;
- a Kubernetes workload receives its context from the controller that owns identity and durable placement;
  for durable services, that controller is a `StatefulSet`; expected restarts authenticate through
  platform workload/binary identity plus a broker-signed manifest, verified into one inseparable
  `VerifiedRuntimeRoleActivation`, not a
  permanently live `project up` broker or the ConfigMap alone.

The current context shape is project-extensible and carries project/binary identity, **explicit
context** (primary context kind), local capabilities, allowed command classes, parent chain, topology
frames, current frame, runtime witnesses, resource envelope, and child-context creation rules. A
`<project>.dhall` may declare additional roles, but `addRole` currently unions their classes and
capabilities without producing opaque command authority. The resulting gates are inconsistent:
`service run` additionally requires a primary `ClusterService`/`Daemon` leaf, so adding a service role to
a host orchestrator does **not** authorize it; `project up|down|destroy` check widened lifecycle classes
without an exact root-placement relation, so a daemon/image-build leaf can incorrectly gain orchestration authority. Phase 15.9 replaces this with
role-specific opaque command authorities and smart constructors that cannot form incompatible
role/class combinations.

The target first decodes untrusted description and returns
`ValidatedContext scope planId frame` only after checking the topology derived from
`ProjectPlan scope specDigest planId configId cfg`. Project lifecycle dispatch requires
`CommandAuthority scope planId frame (BrokerEpoch brokerGeneration) verb phase`, minted from an independently established
`RootInvocationAuthority scope brokerGeneration verb`, a closed `ProjectVerb verb`, the matching
same-generation bound lease/plan/frame context, and
`LifecycleCursor scope planId frame verb phase`. Service dispatch instead requires platform/manifest
verification to jointly mint the inseparable
`VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId
configDigest secretDigest service rolePlanDigest permittedEffects`. The manifest signs the immutable
rollout revision and controller/template identity before a workload exists; platform verification pairs
it with the concrete pod UID plus restart count or protected OS invocation nonce. Callers cannot
cross-pair its `RuntimeActivationAuthority`, signed `VerifiedRuntimeRolePlanProjection`, or private-channel
locator. The scope-correct project-owned `RoleCodec` verifies the actual mounted role-wire bytes, while
the activation-bound secret-channel verifier separately produces the exact `VerifiedSecretBundle`;
together they yield a fresh `VerifiedConfigWire`/`ValidatedServiceRequest`. The projection
contains only the non-secret leaf slice plus a proof binding its `rolePlanDigest` and exact
`configDigest` to the parent `planDigest`; a narrowed child never pretends to recompute the full
lifecycle-plan digest. Before Prereq or acquisition, `verifyRolePlanDraft` validates the non-empty draft
and signed role-plan digest without durable mutation. `withRoleLifecycleAdmission` then atomically
reserves the instance's one-use durable lifecycle admission/journal with fresh
`planId`/`invocationId`; if its independently complete predecessor manifest is non-empty it returns only
typed recovery-required state. The activation-bound `admissionKey` moves only Reserved→Consumed; lost
reservation acknowledgment yields `RoleLifecycleAdmissionUnknown` and the same opener/resume API
rehydrates stored identities rather than allocating again. `withRuntimeRolePlan` linearly CAS-consumes
the exact Reserved admission and verified draft and is fixed to that admission's `planId`; duplicate
tokens have one winner and it cannot reserve or mint a second cursor. Commit-before-cursor-delivery
yields `RolePlanOpenUnknown`; `resumeRuntimeRolePlanOpen` reconstructs only that same consumed
plan/invocation and cursor. It constructs only
`RolePlan scope specDigest planId configId secretDigest frame revision instanceId` plus
`RolePlanDigestBinding scope specDigest planDigest rolePlanDigest planId` and
`VerifiedServicePlacement scope specDigest planId frame revision instanceId service permittedEffects`
from that projection, the verified request, and a project-owned role draft. It never rebuilds a lifecycle
`ProjectPlan` or root authority. After Sprint 14.6 yields the exact Serve cursor, identity-indexed ready
managed handles, and the inseparable retained receipt/lease package,
`selectAndRunService` consumes that foundation with the plan/binding/placement, validated request,
activation package, frame/context, and finalized runtime spec. It rechecks the exact workload-instance
identity and always returns the Drain transition on selection rejection, run outcome, or catchable
shutdown. It is internal to the sole public, core-owned masked run-to-Exit operation, so project callbacks
never receive live cursors/receipts and cannot bypass Drain by throwing. Runtime Harness verification
reads only the activation-bound private channel and mints no `HarnessConfigAuthority`; it does not replay
a consumed edge handoff. Thus context
does not mint root authority, an `up` grant
cannot authorize `down`/`destroy`, a stale phase or rollout revision/process instance cannot replay a verb, and another
Production plan cannot substitute its context. Each opaque authority also has a one-use invocation
identity; the effectful authorization gate atomically reserves that invocation at the live cursor/epoch,
a protected session-open compare-and-swap prevents reuse, and every effect requires the exact
resource/generation/operation/session/fence/attempt/journal-indexed prepared-operation value returned
after the matching journal transition and the matching plan-minted descriptor, operation binding, or
teardown step. A terminal observation returns `OperationAdvance` on both success and typed failure; its
eliminator yields the result only with the sole successor Open-project state/revision-permit pair.
Ordinary Haskell values alone are not linear.

The relationship between contexts is expressed in the **pure compositional lifts** — the topology is a
pure frame graph with parent links (§ U), not an implicit permission in the command line; it can
represent arbitrary chains such as host -> VM -> container -> cluster -> service pod, or host -> VM ->
Pulumi role -> EKS cluster -> workload. A process must fail before side effects when its local witnesses
do not prove it is in the declared current frame.

The exact current config-precondition matrix is:

- config-free writers: `project init`, `service init`, and `test init`;
- static/config-free routes: help, `service schema`, and `context path|schema|render`;
- file readers: `context inspect` reads the sibling config, while `context show [FILE]` reads its
  selected or default file;
- the harness route: `test run` reads the test config, refuses an existing sibling project config, and
  generates its own project config;
- existing-frame routes: `project up|down|destroy`, `service run`, and `check-code`.

Existing-frame commands fail
fast with exit code 1 when the context file is missing, fails to decode, names a different
project/binary, does not declare the required capabilities, or does not permit the requested command. A
Phase 15 context also fails when required local witnesses cannot be verified. A
daemon/service command must refuse to start unless the context declares a daemon/service role;
host-orchestrator commands must refuse to run inside a cluster-service pod; and a VM-scoped kind/test
workflow must refuse to run directly on the host Docker daemon unless the Dhall declares a local
test-harness frame.

Every context's `<project>.dhall` is **generated by the project binary from passed Dhall parameters** —
some supplied at the frame and some **forwarded from the parent context's `<project>.dhall`** — so a child
config is generated rather than hand-authored. Current helpers narrow the descriptive context to the
child frame but retain the full demo `ProjectConfig`, parent resource envelope, and host/build/deploy
fields. The target makes the security invariant structural: the parent renders only a descriptive
`RuntimeRoleWire fields service` containing required framework-validation fields plus fields visible to
that exact child consumer, together with validated frame/resource/witness proof. The wire cannot contain
the parent's plan-only fields. The child verifies those exact bytes through the matching `RoleCodec`,
mints a fresh child-local `configId`, and only then obtains opaque role parameters; neither the parent's
`configId` nor a `ValidatedServiceRequest` is serialized.

Current projection and delivery are split from the named `context-init` row, whose action only announces
a frame anchor. The VM projection/streaming occurs inside the composite bootstrap action, the container
projection is selected independently through `psFrameContext` and carried by the lift, and a Kubernetes
service receives a ConfigMap that overrides the image's baked container config. VM/container projections
travel on the lift's `stdin` only — never `argv` or an environment variable — and the descending binary
writes its own executable-sibling `<project>.dhall`; there is no host-side intermediate config file or
config bind-mount. The target `ProjectPlan` gives projection, authentication, durable preparation, and
delivery to one plan node, so an announcing row cannot disagree with the bytes the child receives.
In-place delivery landed in Phase 15 Sprint 15.7 / Phase 13 Sprint 13.15 (closed 2026-07-02, validated by
a live Windows/WSL2 `test run all` `6/6`); the superseded
build-then-copy/mount surfaces it replaced are in the **Removed Surfaces** of
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). The read-only `context` command (§ Z) treats **every** `<project>.dhall`
uniformly — it introspects the explicit context and renders the global compositional lift sequence
(`topologyFrames` / `parentChain`) with the current frame highlighted, regardless of which roles the config
declares; it performs no mutation. Phase 15 established the shared-substrate contract (the built binary
creates the host-level default, parent surfaces produce nested configs, normal dispatch gates on the
sibling config); the reopened work (§ Y, § Z, § AA) makes the surface the fixed `project` / `test` /
`service` tree, supports multi-role configs and forwarded parameters, keeps `context` read-only, and
targets one plan-owned child-config operation. A later refinement (landed 2026-07-02) moved
child-config **delivery** from build-then-copy/mount to **in-place streaming** over the lift's `stdin`
channel.

### Y. Project Lifecycle Command And The Step Chain

A project's lifecycle is a pure, **opaque** `ProjectPlan scope specDigest planId configId cfg`, where
`cfg :: Type -> Type`. A fresh plan is constructed only inside a fresh `planId` continuation from
`LifecycleProfile scope`, `ValidatedConfig scope specDigest configId (cfg scope)`, and a non-empty
`PlanDraft scope specDigest (cfg scope)` sequence. Bound Production recovery is the only exception to fresh
construction: an exact `RecoveredProductionLifecycleProfile projectId specDigest planDigest planId
brokerGeneration` plus the matching verified/bound snapshot and binding may reconstruct only that same
`planId`/spec/digest, or open its separately typed migration builder. A Production plan therefore cannot
contain a harness config even if both configs use only shared fields, and two Production plans cannot
exchange state. Its constructor
validates the frame graph and every teardown policy; `PlannedStep scope planId configId (cfg scope)` and
`DerivedTopology scope planId` are projected from the plan. `teardownPlan DownVerb` and
`teardownPlan DestroyVerb` have distinct `TeardownPlan scope planId verb` result types and accept only the
matching `AcquisitionJournal scope planId`. The pure plan does not expose cursors:
`openTeardownForest` is the sole initial-forest producer and requires the matching bound snapshot,
active revision, Open-project state, and revision-permit version. Its exhaustive next-work eliminator
yields `CompletedTeardownForest` or one closed `TeardownAuthorizationPoint`; only its private eliminator
exposes either a destroy-only plan-derived pre-descent reachability step or the plan-derived
settled-child proof/cursor for an ordinary step. Callers cannot wrap either branch. After `down`, the
pre-descent step can
make only the exact stopped provider teardown-reachable before retained children are visited; its
successor forest exposes those children, and only their later settlement exposes the ordinary provider
stop/delete step. Each attempt returns the successor forest even on typed failure. Only a completed
Destroy forest can enter the `DestroySettled` verifier. Callers cannot independently supply or update
chain, topology, teardown, lifecycle scope, or plan identity. The current opaque `StepPlan` plus separate
checked frame-context/teardown fields is the migration source, not the finished single representation.

The plan shape is **code**: it is the project's identity (§ W). The sibling `<project>.dhall` carries
**parameters + context + witness**, never plan shape; a copy of the binary verifies it is in the frame its
`<project>.dhall` describes, or fails fast (§ X). Optional structural variation (for example, deploy
straight to Docker and skip the VM) is a typed field in the **root** `<project>.dhall`, so plan
construction is a pure function of validated root parameters.

- `project init` — a config-free initializer. With no role, output, or overwrite flags it writes the
  default root host-orchestrator config. The current shared parser also accepts `--role`, repeated
  `--also-role`, `--output`, `--force`, `--if-missing`, and resource/deploy overrides. That flexibility
  can currently express incompatible role/class combinations; the target uses opaque role-specific init
  requests, validated combinations, and one explicit overwrite policy (Phases 15.9/17.4). Python builds
  and invokes the host-native binary using the platform-specific handoff in § M; it does not initialize
  or trigger config creation. A normal
  existing-frame command fails fast (exit 1) when no sibling `<project>.dhall` exists (§ M).
  Target overwrite semantics are closed: no flag = `RefuseExisting`, `--force` =
  `ReplaceExisting`, `--if-missing` = `KeepExisting`, and both flags together are invalid.
  Every policy publishes from a fully written and flushed invocation-indexed same-directory temporary:
  refuse/keep use atomic no-replace installation, replace uses atomic replacement, and the parent
  directory is flushed before success. Missing platform primitives return `Unsupported`; retries
  classify `PublicationUnknown` and recover only their verified orphan temp, never expose a partial
  destination or adopt/delete a foreign temp.
- `project up` — interpret the chain **recursively** from the current frame: run the steps for this frame,
  then for the next nested frame provision it, build/install the pb in it, and hand off `pb project up`
  (the fractal bootstrap, § U). Recursive up exists today; its active type-level refinement is
  receipt-preserving reconciliation (managed `Changed Created|Repaired|Adopted` or managed
  `Unchanged`, with foreign observations returning a non-authorizing `Unmanaged` handle; § EE) in
  Phases 9.10/16.6.
  `--dry-run` renders the pure chain without acting.
- `project down` — the **target** is child-first recursive stop across every acquired frame. VM frames use the
  provider **stop** operation (incus/Lima **stop**, WSL2 `--terminate`; never destroy or unregister), so
  the guest and its disk survive. At the kind-cluster frame, `down` deletes the kind cluster, because kind
  has no reliable stop/restart contract; its removal set is **empty**, so no filesystem path is removed.
  Cluster-local persistence (for example a PVC on kind's default `local-path` provisioner) lives **inside
  the kind node container** and does not survive that delete. Best-effort and idempotent means every
  independent cleanup is attempted and any failures are aggregated and reported; it never means silently
  swallowing cleanup failure. Current code dispatches current/root teardown hooks rather than a typed
  recursive acquisition unwind; Phase 16.6 owns that gap.
- `project destroy` — the **target** is recursive `down`, then deletion of everything this run acquired,
  **including the provisioned frame
  and its disk** (`incus delete --force`, `limactl delete --force`, `wsl --unregister`, which removes the
  vhdx). The host-root `.data` is **inside** the single plan with an explicit `Preserve` policy and a
  verified receipt, but neither reverse projection places it in a destructive removal set. The demo now
  creates that host project-root, carries it through the provider share/alias and nested mounts, and
  retains it across frame teardown. The mechanism has historical provider evidence, but Phase 5.6 remains
  Active until a dedicated write → destroy → up → read-back run proves durability end to end. The canonical
  home is [durable_state](../documents/architecture/durable_state.md). Current child-first recursive
  destroy/partial-failure unwind remains Phase 16.6 work.

The `Preserve` rule applies to both ordinary project verbs in every scope. Harness terminal cleanup is a
separate, plan-derived projection. A narrow `HarnessCloseRoot`, derived from either the live harness root
or the exact abandoned-run recovery authority, combines the project-wide Harness mode lease, bound
snapshot, `BoundRunLease (Harness projectId runId) specDigest planDigest brokerGeneration`, exact versioned
`ProjectOperationState ... OpenProject`, and same-version `ProjectClosureEvidence`.
`authorizeHarnessClose` verifies every ordinary operation session Closed and atomically changes Open to
a fresh `ClosingProject` epoch while creating its close journal; a concurrent prepare and close cannot
both win, and a retained proof from before destroy→up cannot close the new journal version. The sole
`verifyDestroySettled` producer checks the complete plan-derived destroy forest, terminal release
observations, protected journal, absence of unresolved nodes/live prepared operations, and the independently
complete Closed session set. The sole
`verifyNoProjectResourcesAcquired` producer checks the exact bound snapshot/revision/state tuple has no
resource operation/prepare/fence/receipt/effect record and that every registered session is Closed and
empty. Only their closed conversions mint `ProjectClosureEvidence`; unresolved partial ownership
produces none.

The close projection releases the exact owned generated config and `.test_data/<runId>` generations
through the same durable intent/unknown/reprobe/fence protocol, specialized to the Closing epoch. Every
terminal close observation returns `HarnessCloseAdvance` on success or typed failure; its eliminator
yields the only successor close journal. A persisted Closing run resumes only its exact close
authority/journal; it cannot remint Open, general Harness, or `ProjectUp` authority. After all close
operations and sessions settle, one protected finalizer atomically records `ClosedProject`, closes the
bound lease, and releases the exact Harness mode epoch last. Production mode release after settled
destroy instead requires a closed `ProductionClosureAuthorization` made only from exact
`ProjectDestroy` authority plus `DestroySettled`. Its other constructor accepts any exact Production verb
only with `VerifiedNoProjectResourcesAcquired`, so a true pre-effect `up` refusal can close but partial
`up`/`down` teardown cannot be relabeled as settled. The finalizer records Closed, closes its invocation
lease, and clears its mode in one protected compare-and-swap, with no persisted mode-cleared Closing
intermediate. Session opening advances and compare-and-swaps that same Open project-journal version, so
it and Production finalization have exactly one winner.
Before another run is allocated, `recoverAbandonedHarnessRuns` enumerates both unbound and bound
incomplete leases at one protected-store version. Separate rank-2 fold callbacks receive every exact
existential `VerifiedIncompleteRunLease`; the sweep rechecks terminal closure after each callback, so a
caller cannot manufacture/skip a run or return no-op success. An unbound lease closes only with
`VerifiedUnboundLeaseHasNoEffects`; a bound lease reopens its exact snapshot and
`BoundInvocationRecovery`, then selects Open revision recovery or persisted close recovery before any
journal is exposed. Only a protected empty-set compare-and-swap yields
`ClosedAbandonedHarnessRuns`, which `withHarnessRoot` consumes atomically with fresh allocation. This
preserves durable data for destroy→up assertions within a variant without leaking it after terminal
harness close.

A normal root-frame `project up` failure runs the same receipt-driven delete teardown before it reports
failure. Outcome classification is exhaustive and consistent: compatible but unowned state is
`ForeignResult`; an incompatible/occupied identity or contradictory ownership claim is `Conflict`; a
policy decision declining an otherwise authorized owned/absent transition is `SafetyRefusal`; a backend
that cannot provide the required strong semantics is `Unsupported`; and an attempted operation failure
is `Failure` with recovery disposition. Only a refusal proven to precede every acquisition has an empty
rollback set. A late policy refusal after journaled preparatory effects unwinds those exact owned effects;
it must not skip cleanup merely because its report label says refusal.

The **Step algebra** is the reuse unit: `hostbootstrap-core` ships the host-management step kinds
(deploy-VM, `ensure-*`, copy-source, build-pb, build-image, `context-init`, deploy-kind, deploy-chart,
expose-port), and a project contributes its own step kinds into the same `[Step]` (the lift-chain stream,
§ T). Host and project steps interleave freely; a project's workload (a registry install, a web-serve, a
role) is expressed as steps in the chain, not as separate top-level verbs.

### Z. Chain-Driven Test Surface And Context Introspection

The test surface **drives the real `project up`** rather than re-expressing bring-up (§ W). It is the one
test engine. Current project code owns compiled case assertions and the current config-to-variant
projection; the engine owns selection, reporting, in-process cleanup attempts, and reuse of the project
lifecycle rather than a second cluster-bring-up path. The target adds typed case/variant projection,
project-wide exclusive execution, durable recovery, and receipt-driven cleanup.

- `test init` — currently writes a per-project `<project>.test.dhall` containing resource overrides,
  without requiring a pre-existing sibling `<project>.dhall`. Opaque typed case/variant identity and the
  total matrix relation are now implemented in Haskell; the target moves the demo's concrete variant
  mapping into typed config and adds scoped overrides such as secrets. Its target request has no
  overwrite flag and uses
  `RefuseExisting`.
- `test run <case-id>|all` — runs one registered typed case or every registered case. The **target**
  semantics are root-only, fail fast without `<project>.test.dhall`, and reject a non-root context before side
  effects; Phase 17.4 owns that still-open parser/gating contract. For each **distinct test configuration**
  (cases sharing a config share one stack; a case needing different resources/secrets declares a different
  config) the harness: (a) writes a test-specific `<project>.dhall` (the test-config overrides projected
  into a normal project config), (b) runs `project up` over the project's own chain, (c) runs that config's
  case assertions in the frame appropriate to each, reusing the self-reference lift (§ U) — e.g. a
  Playwright assertion as a container on the VM host network in the VM frame, outside the cluster — and
  (d) tears the stack down with `project destroy`.

The target harness checks two **hard fail-fast safety preconditions** before *any* test runs, so a test never interferes
with production: (1) a sibling `<project>.dhall` already exists → refuse (never overwrite a production
config); (2) a production cluster is running → refuse (never touch production state). The sole
precondition verifier derives its total probe from installed project identity; callers cannot inject a
successful probe. `withHarnessRoot` reruns it while atomically acquiring the project-wide Harness mode
lease. Production openers contend on the same mode record, so neither profile can slip between precheck
and ownership; `ProjectDown` retains Production mode, and Harness mode is released only after terminal
close. If either precondition holds, **no tests run**. Later classification follows § Y/§ EE: compatible unowned state is `ForeignResult`,
incompatible identity is `Conflict`, policy refusal is `SafetyRefusal`, and missing strong backend
semantics is `Unsupported`. State the run did not create is never torn down, while any journaled
preparatory resources it did acquire are rolled back by receipt; a late refusal cannot silently skip
that owned rollback. Generated config and
`.test_data` require all four Locked-Origin Identity Ownership clauses in § EE, not a
check-then-create sidecar, path-name heuristic, bare exclusive create, or compare-then-unlink. A
backend that cannot take the kernel lock, record the origin, or report a stable object identity
reports `Unsupported` and mints no receipt. The harness carries a receipt
through bring-up, assertions, and teardown and may remove only that exact generation. An incompatible
pre-existing path or contradictory ownership claim is a structured conflict and no test runs; a
compatible unowned object remains `ForeignResult`. Changed config bytes are quarantined
without releasing ownership; foreign state is never torn down. Test durable storage is always
`.test_data/<runId>`, never `.data`. A teardown failure makes the variant fail rather than producing a
green report with leaked state. Ordinary project teardown preserves that root; after the variant's
settled destroy, the harness-only terminal close projection conditionally releases its owned generation
and closes the lease.

Because the harness invokes the real command in another process, its independently authorized root owns
the profile-specific broker and
`UnboundRunLease (Harness projectId runId) brokerGeneration`, then binds that lease to the exact verified
plan snapshot before any prepared operation. Immediate children relay to
that root rather than receiving a signing key. The root sends a one-time handoff token bound to scope,
exact `PlanDigest`, broker generation, parent/child edge, child `ConfigDigest`, verb, and phase plus the
matching wire over a private duplex session. The child returns a fresh challenge; the root consumes the
lease nonce and signs all bound fields. Verification against the independently installed public key and
the actual bytes jointly creates
`VerifiedConfigWire (Harness projectId runId) childConfigDigest childConfigId` and the exact
`VerifiedHandoff ... ConfigHandoff childConfigId verb phase`; raw wire cannot be promoted and a narrowed child never reuses its parent's
exact-byte `configId`.

Each one-use command/handoff invocation opens one durable versioned session only with
`CurrentBrokerSessionAdmission`. Clean activation mints that admission after proving no older broker
session remains Open; abandoned-run activation instead uses the exact old-permit fence set and a
verified manifest pairing the independent complete session set with its independently complete
operation set. Registering an initial intent consumes the exact closed origin—sole no-prior-generation
evidence or a released-reacquisition `FreshGeneration`—and atomically adds the operation/generation to
that exact session while advancing the session/project-journal versions; no orphan intent can be
omitted and the caller cannot choose a generation. An intent may validly have no initial fence but cannot
prepare. Recovery idempotently completes the stable initial-fence protocol and threads the sole
successor session/state/permit before exposing current-fence authority. Its protected
exact-set interpreter CAS-rebinds each existing stable session record—including a zero-operation Open
session—and totally classifies unknown, the five pre-call continuable phases, already-observed retryable,
successful, and terminal operation records. Only the continuable phases receive current-fence prepare
authority; only reservation/effect/adoption absence, same-identity ordinary/adopted teardown,
repair-original, and managed-phase-from receive verified current-fence same-key retry authority; a crash
after recording one of those observations remains recoverable. It verifies/rebinds the complete
resource-record set, settles/closes every member, and threads the sole successor state/permit pair.
Missing/duplicate members, wrong membership, missing/replaced resource evidence, or unresolved internal
recovery cannot yield admission or open a new command session.
Session open and close also advance that shared project-journal version and return the sole successor
state/permit pair; opening rechecks permit-open/not-frozen state in the same protected transition used by
migration freeze and terminal close.
Before every child reservation/mutation/delete, the root
verifies a prepare request naming the exact authority epoch,
verb/phase/frame, session, journal/resource/generation/operation version, current authoritative fence,
precondition-set identity, and call digest. The plan is the sole producer of the exact closed zero/one/
many dependency snapshot and jointly indexed `OperationPreconditionSet`/verified backend call. It
internally traverses the descriptor's complete edge set and runs the plan-owned probes; callers cannot
supply retained readiness or omit an edge, and its private no-dependency branch prevents fabricated
requirements. One protected
compare-and-swap consumes that set, reruns every target/dependency probe and observation version,
obtains conditional backend versions, and revalidates the active project mode, bound lease, active
plan revision/no migration freeze, Open-project state, command/session/fence, readiness generation, and
record phase, then records the exact operation-specific unknown state **before** returning the
resource/generation/operation/precondition-set/call-digest/session/fence/attempt/journal-indexed
`PreparedOperation` and matching fresh `PreparedPreconditions` required by the adapter together with the
fresh-versioned successor Open-session, Open-project state, and
revision-permit authority. Every adapter terminal observation returns `OperationAdvance` on success or
typed failure; its eliminator yields the result only with the sole next state/permit pair. An adapter
accepts neither retained `Ready`/prerequisite data nor either half of the prepared pair. Initial fence
creation and `FenceIntentRecorded → FenceOutcomeUnknown → FenceObserved` rotation persist and resume one
stable proposed epoch while returning the sole successor state/permit pair; a delayed old permit is
rejected or deduplicated. Terminal acknowledgment first
verifies every registered outcome settled and then compare-and-swaps the exact Open-session version
Closed, so a retained proof or concurrent prepare cannot win. Loss before prepare refuses, while loss
after a prepared backend call leaves an explicit unknown state for total reprobe. Generative handles,
`JournalEntry`, and receipts are never serialized. The token is never in Dhall, `argv`, an environment
variable, or durable config; teardown gets a fresh token, and a harness broker cannot sign Production
authority. Before allocating a new run, the root must recover/teardown any protected incomplete old
harness lease under that exact old run scope. The current config-only lift does not yet provide these
guarantees.
Direct implementation owners for this target are Sprints 5.7, 9.10, 10.9, 15.9, 16.6, 17.4,
19.6–19.8, and 20.5; their exact execution prerequisites remain the phase-local `Blocked by` metadata.

`context` is a **read-only** command that treats **every** `<project>.dhall` uniformly: it introspects the
explicit context and renders the global compositional sequence of lifts (`topologyFrames` / `parentChain`)
with the current frame highlighted, so an operator can see the whole `metal → VM → container → cluster`
chain and where this binary lands in it — regardless of which roles the config declares. It performs no
mutation. Child-config creation is internal `project up` work, currently split from the announcing
`context-init` row and targeted for one plan-owned projection/delivery operation (§ Y); it is not a
`context` subcommand.

### AA. Service Runtime Command

`service` is the third DSL-driven core command (alongside `project` and `test`). It runs a project's
**long-running roles** — the `HostDaemon`/service run-model (§ T) — and is driven by a **service-configured**
`<project>.dhall`:

- `service init` — writes one descriptive Production role wire from a selected service in the finalized
  registry, one legal `ClusterService` or `Daemon` placement, and role fields assembled/projected through
  that same spec. Callers cannot choose the hidden field row or arbitrary roles. Its target
  writer-specific request has no overwrite flag and uses `RefuseExisting`. It does not sign or install
  runtime authority: an authorized controller/OS-service launcher must atomically pair those bytes with
  the broker-signed manifest and measured identity before `service run`.
- `service schema` — currently prints the full validated-codec `cfg` shape. The target prints the
  finalized project-owned role-wire schema registry/union derived by `RoleCodec`, with separately named
  `Production` and `Harness` scope families; round-trip/anti-drift tests prove every runnable role wire
  agrees with the decoder for its exact scope (§ Q).
- `service run` — loads the effective config and runs its selected role. There is no positional variant
  argument. There is **no `service down`**: lifetime is owned by the enclosing Kubernetes controller or
  host project lifecycle and torn down by `project down` / `project destroy` (§ Y).

`service run` is a **leaf-frame runtime command, never an orchestrator**. Core checks the primary kind is
`ClusterService` or `Daemon`, canonically verifies one sibling snapshot, and structurally selects exactly
one definition from the jointly finalized typed registry. The selected request and action share that
snapshot; demo handlers do not reload config. The finalized project specification hides each
project-declared role field type and jointly derives its full `ProjectCodec` and
`RoleCodec scope specDigest fields`; callers cannot pair codecs or choose `fields`. A validated config can
project a `RuntimeRoleWire fields service`, but not a request or handler parameters. At the runtime
boundary, the signed manifest fixes an immutable rollout `revision`, while platform verification pairs it
with a measured `instanceId` (pod UID plus restart count or protected OS invocation nonce) and yields one
`VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId
configDigest secretDigest service rolePlanDigest permittedEffects`. Runtime role-wire/ConfigMap bytes
contain Production pointers or Harness secret handles, never inline fixture bytes; the exact run-scoped
private bundle is internally read and verified through the activation-bound channel, not accepted from a
caller or gated by `HarnessConfigAuthority`. `withVerifiedRuntimeRoleWire` consumes the matching
activation package, finalized runtime spec, verified secret bundle, and actual mounted bytes. Its private
eliminator yields the local
`VerifiedConfigWire` plus an existential opaque
`ValidatedServiceRequest specDigest configId secretDigest fields service` under one fresh child-local `configId`. That request
is an inseparable bundle of the typed request and
`RoleParams specDigest configId secretDigest fields service`; neither member has a public independent constructor or projection,
and neither crosses the process boundary. `fields` is built through a closed consumer-indexed schema algebra:
`ProjectField (VisibleTo consumers) name a`, where the closed consumer tags include framework
validation, a typed plan frame, Harness assembly, and `Service service`. Context/identity/request
metadata can therefore be visible to framework validation without entering a handler, and build/deploy
inputs can be limited to their plan frame rather than mislabeled as service or host data. Core owns the
consumer/filter algebra but not the project field names or value types.
`RuntimeRoleWire fields service` contains the union of the mandatory
`FrameworkValidation` projection and fields tagged `Service service`; plan/build/deploy-only fields cross
neither boundary. `RoleParams specDigest configId secretDigest fields service` is the narrower second filter: it can be
constructed only from fields tagged `Service service` under that exact config identity, so
framework-only metadata remains available to validation without entering the handler, and parameters
from another validation cannot type-check. Sprint 14.6's role engine first atomically reserves one durable
lifecycle admission for the exact instance, then constructs the matching role plan/binding/placement.
The signed placement's `permittedEffects` ceiling conservatively derives the acquisition plan and closed
lease disposition before Acquire: a ceiling that permits any exclusive/mutating effect requires the live
fenced lease, while only a ceiling that prohibits all such effects can yield the no-lease proof. The
engine then acquires managed listener/connection/worker handles and probes those exact identities. Partial
acquisition or readiness failure yields only Drain plus every owned/unknown receipt; success yields
`ReadyServiceHandles` and the unique Serve cursor. Serve has no handler-visible open/bind/spawn escape
hatch. A restartable worker's ready identity is a stable supervisor handle; only a core-owned,
journal-prepared supervisor transition may replace a child, and it must reprobe that child before another
request. The sole effectful `selectAndRunService` operation then jointly consumes those values, the whole
local request bundle, inseparable activation/projection package, and finalized runtime spec. Registry
lookup reveals the exact handler effect row. A private
`EffectAuthorization scope specDigest planId frame revision instanceId service effects` is constructible only when
the opaque `VerifiedServicePlacement ... permittedEffects` permits that row; `DurableStore` additionally
requires `DurablePlacementAuthority scope specDigest planId frame revision instanceId service`, derived from
verified durable placement rather than decoded context. The gate atomically reserves a one-use
`ServiceCommandAuthority scope specDigest planId configId secretDigest frame revision instanceId
ServePhase service effects` and transfers it
directly into one existential package:

```text
SelectedService scope specDigest planId configId secretDigest frame revision instanceId ServePhase fields
  = exists service effects.
      ServiceSelection
        scope specDigest planId configId secretDigest frame revision instanceId ServePhase service effects
    + ValidatedServiceRequest specDigest configId secretDigest fields service
    + (RoleParams specDigest configId secretDigest fields service
         -> ServiceProgram
              scope specDigest planId configId secretDigest frame revision instanceId
              ServePhase service effects ())
```

Those three members cannot be separated or substituted by callers. The package is internal to the
core-owned masked run-to-Exit operation; no arbitrary `IO a` callback receives it, a phase cursor, or live
receipts. Private phase eliminators cannot escape those values to consumer code.
`ServiceSelection ... effects` is an opaque proof that the exact effect row is authorized by the
placement/effect witness and consumed service command authority, so activation authority alone, a
non-Serve cursor, a non-durable placement demanding `DurableStore`, or a program demanding a different
or additional effect cannot be packaged. No generic service `CommandAuthority`, pure
`finalizeSelectedService`, or separable effect proof is public. The service command authority is
single-use; an already consumed invocation cannot construct or run another service package. The handler
receives only `RoleParams specDigest configId secretDigest fields service`, not
`ValidatedConfig ... cfg`. `ServiceProgram` is a closed,
capability-indexed program type with no public `IO`, `MonadIO`, arbitrary filesystem, or config-read
escape hatch; core interprets only the finalized service's authorized network/durable-store/process
effects. Therefore the public handler API cannot reopen the sibling path or pair a Web payload with an
accelerator handler.

An effect row is family permission, never mutation or retry authority. Every mutating
durable-store/process/backend constructor first creates an opaque
`SealedServiceEffectCall ... effect ... targetId operationKey callDigest` containing the exact target and
arguments. The backend adapter accepts no separate raw request. Private protected prepare consumes only
that sealed call, the exact prior `ServiceEffectReady` session, and the whole retained resource/lease
package. Success yields
`PreparedServiceEffect ... targetId operationKey callDigest fence attempt journalVersion` carrying the
sealed call and package; a different target or arguments cannot reuse it.

Prepare itself is constructive on failure: known rejection yields a
`ServiceEffectPrepareFailed effect targetId operationKey callDigest fence attempt` session, and uncertain
journal commit yields
`ServiceEffectPrepareUnknown effect targetId operationKey callDigest fence attempt`. The private
eliminator returns either failure state only with the sole successor journal session and whole retained
package directly into the core-owned Serve→Drain/recovery path. Neither state is accepted by normal
prepare, and no `Either` can drop its cleanup authority before a `PreparedServiceEffect` exists.

The backend consumes only that prepared value and returns
`ServiceEffectAdvance ... targetId operationKey callDigest ... fromJournalVersion nextJournalVersion
nextEffectState`. Its private eliminator exposes `ServiceEffectOutcome nextEffectState` only with the sole
fresh journal session under the unchanged effect row/phase and reconstituted retained package—never a
bare lease detached from receipts. Unknown indexes that successor as
`ServiceEffectUnknown effect targetId operationKey callDigest fence attempt`, which has no ordinary
prepare/retry constructor until same-key/fence reprobe yields an observed resolution or
`VerifiedSameKeyRetry ... configId secretDigest ... service effects phase effect invocationId sessionId
targetId operationKey callDigest fence previousAttempt nextAttempt unknownJournalVersion
retryJournalVersion`; observed success/failure yields `ServiceEffectReady`. Private
`resumeVerifiedSameKeyRetry` jointly consumes that exact parameterized Unknown session, the full-lineage
proof, and retained package and feeds its successor Ready session plus reconstructed sealed call only
back into the same core interpreter. There is no public/caller-selected Unknown→Ready conversion. Another
target, call digest, config, secret bundle, effect row, phase, invocation, session, or journal version
cannot cross-pair. This includes crash-after-call-before-ack. Read/listen and
supervised use of already acquired
handles are the only unprepared operations. Adding an open/bind/spawn or raw `IO` escape hatch is not a
valid effect contribution. The retained resource package inseparably carries every receipt/unknown and a
closed lease disposition: either proof that the signed placement ceiling prohibits every
exclusive/mutating effect or the matching live `ServiceGenerationLease ... fence`. The activation and
verified placement derive this requirement before Acquire; callers cannot choose the no-lease branch.
Serve accepts only a finalized registry row proved within that same ceiling, so a mutating program cannot
appear on the no-lease branch. Only the live-lease branch can mint
`PreparedServiceEffect`; neither receipts nor lease can be projected away before Drain.

Selection rejection, completion, typed failure, catchable shutdown, and caught interruption all produce
one opaque `RoleAdvance ... ServePhase DrainPhase ServiceDispatchResult`; no `Either` or callback may
drop receipts. Its sole eliminator yields the result only with the unique Drain cursor and retained
receipt/lease package, still inside the core-owned runner. Drain attempts every independent
release/reprobe despite individual failures and yields
`RoleAdvance ... DrainPhase ExitPhase DrainResult`; only its eliminator exposes the aggregate result with
the Exit cursor. Uncatchable process death uses durable admission/receipt/lease/journal recovery rather
than an impossible in-process guarantee. Rolling revisions/instances may overlap for non-exclusive
service work; cross-instance replay fails, and exclusive/mutating work retains a
`ServiceGenerationLease` through Drain. The admission opener independently enumerates a complete
`VerifiedOldRoleInstanceManifest` for one stable placement; every member retains its full old
plan/spec/binary/config/secret/role-plan/effect-ceiling and local
plan/config/revision/instance/invocation/journal/resource lineage. Recovery folds that exact set and
rejects omitted, duplicate, extra, or substituted records before yielding
one `SettledRoleLifecycleRecovery` whose contained `RecoveredRoleInstanceSet` and
`RoleRecoveryClearance` both retain the full new
plan/spec/binary/config/secret/service/role-plan/effect lineage. Recovery Unknown carries the same
lineage and can only enter `resumeRoleLifecycleRecoveryUnknown`, which re-probes the stable key into
another exhaustive advance. Every member requires authoritative `VerifiedRoleInstanceNonLive`, which
the final CAS revalidates. Non-exclusive live overlap remains legal and outside recovery; only
authoritatively non-live incomplete/unclean members are settled. A live exclusive predecessor yields
Busy/Conflict or liveness Unknown without recovery authority, and an exclusive successor waits for all
non-live predecessors. The no-exclusive branch requires
`VerifiedNoServiceLeaseTransfer` for the complete set. Otherwise transfer publishes no successor lease
until the typed `ServiceLeaseTransferBarrier ... predecessorFenceSet newFence transferVersion` proves
an atomic backend fence has excluded every old mutation, or retained nontransferable locks held across
each call until all prepared/in-flight old attempts settled or became authoritatively fenced. A backend
with neither primitive is `Unsupported`. Only `resumeRoleLifecycleAdmission` may consume the single
settled package, atomically close the old invocations, and reserve the new
admission. Lost acknowledgment resumes the same key. After that barrier, later old prepares fail; Drain
releases the lease only after dependent cleanup settles.

Core need not impose a universal service field: the project-owned field schema and `RoleCodec` define
how a full validated config projects each role wire and how a verified local wire yields its typed
request/consumer tags. Construction-time/property tests validate that semantic mapping. The generative
eliminator binds the hidden row, local wire, request, and role parameters together; callers never choose
`fields` independently. Core cannot infer that a misleading project tag is semantically accurate, so
the generic guarantee is relative to the project's declared schema; the demo's field classification has
compile-fail/projection tests. The guarantee is not that core can inspect an arbitrary function and
prove it “non-constant”; the arbitrary function no longer exists. Missing-config diagnostics name the
exact owning parent/controller projection, or `service init` together with the required authorized
manifest installer; they never imply that a descriptive file alone authorizes `service run` and never
recommend root `project init`. The registry may be explicitly
empty; then no `SelectedService` exists and the fixed command fails before a handler.

`project up` and `service` **compose, they do not overlap**: the chain's `deploy-chart` step deploys the
pod whose entrypoint is `service run`, and the pod's config arrives as a **ConfigMap that overrides the
image's baked container `<project>.dhall`** (§ X). The project may render that ConfigMap dynamically from
the validated parent-derived role-wire projection and fingerprint the exact narrowed mounted bytes on
the pod template so a config change rolls the workload; a hand-maintained chart copy is not a second
config authority. The child verifies that wire and creates the request locally.
`project up` *deploys* the service; `service run` *is*
the service. A project's long-running workload is therefore a service variant reached through this fixed
command, not a per-project verb (the former demo `web serve` / `web bridge` verbs are dissolved — `web
serve` → `service run` (`Web` variant); `web bridge` → the build-image chain step; see
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)).

### BB. Generic Project Model and No Core Defaults

`hostbootstrap-core` is a **library of pure shapes plus the lift algebra and the harness**; it owns **no
default config values and no fixed config type**. The reusable substrate is the compositional lift
(`BinaryContext`, `childContext`, the `Step`/frame graph, `ProviderKind`) and the test engine — **not** the
config record. This contract reopens the surfaces in Phase 19
([phase-19-generic-project-model.md](phase-19-generic-project-model.md)); the superseded surfaces are
listed in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

The generic, scope-indexed `cfg`/`tcfg` substrate and typed test-matrix foundation are implemented:
`TestCfg` projects opaque validated `CaseId`/`VariantId` registries and pure drafts, while the single
restricted `psAssemble` constructs either `cfg (Production projectId)` or
`cfg (Harness projectId runId)` from a closed scope-specific request. Production and Harness install
separate mapped `ProjectCodec`s; Production has no plaintext-secret wire branch, and Harness plaintext
requires the exact generative run authority. Generated-config cleanup is still byte-conditional, and
the demo still resolves its live cluster with Production/`.data`. Phases 10, 13, 19, and 20 own those
remaining lifecycle repairs; the later target bullets below must not be read as current downstream
handoff or isolation evidence.

In target type spellings below, `Production` is shorthand only for the project-indexed
`Production projectId`, and `Harness runId` for `Harness projectId runId`. The full index is required at
API boundaries: installed project identity must be generative before plan or run identity.

- **No core defaults.** `defaultResources` / `defaultDeployConfig` / `defaultProjectConfig` and the
  `initAction` flag defaults are removed. `psAssemble` is the single project-owned default-bearing
  function for Production init and per-variant Harness assembly. `psTestInit` remains a separate
  test-config constructor because it builds `tcfg`, not project `cfg`; demo Web/Accelerator parameters
  are explicit assembled fields and service projection invents no fallback values.
- **Explicit, fail-fast configs.** Every `<project>.dhall` and `<project>.test.dhall` field is mandatory; a missing
  field fails the strict Dhall decode **before any side effect** (no `//`-merge, no `fromMaybe` in decode).
- **Generic over the config type and scope.** The extension contract is
  `ProjectSpec projectId cfg tcfg`, parameterized over a project's config family
  `cfg :: Type -> Type` (its `<project>.dhall`) and test-config type `tcfg` (its
  `<project>.test.dhall`). `ProjectCfg projectId cfg` exposes only read-only `cfgContext` and installs
  Production and authority-closed Harness `ProjectCodec`s; the raw `cfgWithContext` updater is removed.
  Canonical render/hash/strict re-decode through the scope-correct
  `ProjectCodec`/`ValidatedConfig` transition mints root-local config identity. No command-specific
  string selector exists: finalized project validation projects a role-specific wire; matching
  `RoleCodec` verification jointly mints
  the opaque `ValidatedServiceRequest specDigest configId secretDigest fields service`. Dispatch consumes it with exact
  placement, current service command authority, and the finalized typed registry into
  `SelectedService scope specDigest planId configId secretDigest frame revision instanceId ServePhase
  fields`. Core owns the
  consumer-indexed field/filter and
  closed-program boundary but none of the project field names/value types; the handler receives only
  `RoleParams specDigest configId secretDigest fields service`, never the full `cfg` or arbitrary `IO`. The selected package's
  effect-indexed proof must match the handler program, so an unauthorized effect row cannot be
  represented.
  `ProjectConfig` / `Resources` / `DeployConfig` become the demo's concrete instance, not core types.
- **The resource budget is a provider concern (refines § O).** Budget/provider-cordoning is a field of a
  project's `cfg` carried by a provider lift, **not** a universal config field. A secrets-strict,
  RKE2/EKS-sized consumer carries no provider budget at all. For a project that does declare one, § O's
  sole admitted `EffectiveBudget` is the provider-effective wall: a per-VM wall on Lima/Incus, or an
  exclusively owned shared utility-VM wall plus a per-distro VHDX slice on WSL2. An incompatible
  concurrent WSL declaration is `Conflict`; it cannot overwrite the global wall.
- **DRY, scope-aware assembly.** A single project-owned
  `psAssemble :: AssemblyRequest scope tcfg -> ConfigAssembly scope (cfg scope)` is the only
  default-bearing function. `ConfigAssembly` permits only declared config/secret reads and exposes no
  general `IO`, `MonadIO`, or lifecycle/backend mutation; assembly therefore cannot hide an effect
  before the plan snapshot/journal/permit exists.
  `AssemblyRequest` is the sole closed scope-input GADT: its Production constructor carries only
  independently verified project-config values, while its Harness constructor carries the exact
  `HarnessAuthority projectId runId` and one opaque validated `VariantDraft` that already contains its
  stable variant identity and typed override payload.
  Identity and variant occur once, so two inputs cannot disagree. It has no generic role/class list,
  output path, overwrite flag, or service/test writer policy; those belong to the command-specific
  writers.
  `project init` and per-variant harness assembly are projections of that same assembler. A pure
  `psTestMatrix :: tcfg -> Either TestConfigError (TestMatrix VariantDraft)` validates stable reporting
  IDs/references before effects; for each distinct variant draft the engine opens a **fresh** generative
  harness `runId`/lease, then calls `psAssemble (HarnessAssembly authority draft)`. The exact
  `HarnessAuthority`, scope-correct `ProjectCodec`, and assembled value then enter
  `withAssembledHarnessConfig`, whose canonical render/hash/strict re-decode jointly yields the
  root-local verified wire identity and `ValidatedConfig` required by the first `withProjectPlan`.
  No function converts
  `cfg (Production projectId)` to `cfg (Harness projectId runId)`, and duplicating a second defaults
  builder is not compliant.
  `psTestInit :: TestInitRequest -> tcfg` builds a complete, valid `<project>.test.dhall`; the opaque
  request contains only test-config values and cannot encode project/service placement or overwrite
  policy.
- **`<project>.test.dhall` is a thin override and the harness generates the run's config (closes the § Z drift).**
  `test run` reads `<project>.test.dhall`, refuses if a `<project>.dhall` exists or a production cluster is running,
  builds typed config variants through the scope-aware restricted assembler (which can use declared
  readers for inputs such as `test-secrets.dhall`), writes each variant's `<project>.dhall`,
  runs the real `project up`, asserts, and runs `project destroy`. The target projection returns an
  opaque total `TestMatrix`: non-empty unique case/variant registries, exactly one non-empty variant row
  for every registered Haskell case, known unique references, and no orphan variant. Sharing a variant
  and assigning multiple variants are explicit relations. `VariantId` is stable reporting identity, not
  ownership identity: each distinct config variant receives a fresh harness `runId`, cluster/data root,
  and exact plan/config lease. Cases sharing that variant share its one stack. No later variant begins
  until the prior run's lease is closed or reported as requiring operator recovery. Cleanup deletes only a generated config
  whose verified ownership record and bytes still match, and deletes only a self-created harness data
  root; changed/foreign state is retained and reported. `test init` does **not** require a pre-existing
  `<project>.dhall`.
- **Generic secrets shape.** Core offers `SecretRef scope`, which projects embed in
  `cfg scope`; raw `Text` cannot occupy a secret-ref field and core never resolves secrets. The reflected
  Production wire schema has only `Vault | TransitKey | Prompt`, while `TestPlaintext` requires opaque
  `HarnessConfigAuthority projectId runId` and can
  produce only `SecretRef (Harness projectId runId)`. Generative authority is never serialized: the harness Dhall
  schema decodes through an untrusted Harness wire. At the root, exact authority plus canonical
  render/hash/strict re-decode through the scope-correct opaque `ProjectCodec` jointly mint generic
  `VerifiedConfigWire` and `ValidatedConfig`; the restricted assembler may read a declared
  project-specific `test-secrets.dhall` input. The later child boundary uses grant and byte verification
  to mint
  `VerifiedConfigWire (Harness projectId runId) childConfigDigest childConfigId`, the exact
  `VerifiedHandoff ... ConfigHandoff childConfigId verb phase`, and
  child-local `HarnessConfigAuthority projectId runId`; promotion returns
  `ValidatedConfig (Harness projectId runId) specDigest childConfigId
  (ProjectConfig (Harness projectId runId))` in the same rank-2
  continuation. Those values enter `withChildProjectPlan` with the closed verb and non-empty plan draft;
  only that rank-2 gate yields a fresh child `ProjectPlan`, `PlanDigestBinding`, and exact
  `ChildPlanAuthority` for `authorizeChildProject`. Raw wire cannot be promoted merely because a caller
  has run authority, and the child
  does not need the root's non-serializable authority before verification. A pointer-only harness config
  is still Harness-indexed.
  Production decoders and commands have no plaintext constructor, harness-wire promotion, or unscoped
  record update. Phase 19.7 implements the root-local construction/codec boundary; the child handoff and
  plan transitions remain owned by their downstream lifecycle phases.
- **A project field that flows to the workload is a field of the project's OWN `cfg`.** A value the
  workload reads and renders (the demo's `message` the web service reads/renders) is a field of the demo's
  own `cfg`, never a core-owned field and never a generic extra slot — core owns no project-specific field.
- **A suite may declare more than one test config.** The demo's two clusters are two config variants; the
  harness stands each up / asserts / `project destroy`s in turn, with the in-frame assertion parameterized
  by the config it set (`EXPECTED_MESSAGE`).

The canonical design home is
[generic_project_model](../documents/architecture/generic_project_model.md); the secrets seam is
[secrets.md](../documents/engineering/secrets.md). § P (fixed command surface), § W (single
representation / harness drives the chain), § X (binary context), § Y (the lifecycle command), and § Z (the
chain-driven test surface) are unchanged in shape — this section makes the **types** they thread generic
and removes core-owned defaults.

### CC. Readiness-Gated Lifecycle Steps and Legible Failure

Every lifecycle step that **mutates a frame** — provisions it, stages into it, installs into it, or
reconciles its state — runs only behind a proof that the dependency it needs is ready. That proof is a
**sealed, lifecycle-plan- and resource-instance-bound
`Ready scope planId id resource dependency` witness**
(`HostBootstrap.Readiness`): the constructor is absent from every exposed library module, including any
nominal `Internal` module. A hidden `Probe resource dependency` fixes the evidence kind it can mint, so
the caller cannot choose a result phantom, and only its validated polling transition can return
`Ready scope planId id resource dependency`. The generative `planId` prevents values from distinct Production
plans from mixing. Tests exercise that transition through injected probes; they do not receive a public
constructor.

A mutating transition first takes an opaque descriptor binding
`scope`/`planId`, target identity/type, dependency identity/type, and predecessor/successor phases. Only validated
`ProjectPlan scope specDigest planId configId cfg` construction—using
`ValidatedConfig scope specDigest configId (cfg scope)`—can mint that descriptor after proving the topology
relation. Its internal dependency-snapshot traversal looks up the exact managed resources and runs the
plan-owned probes for the complete ordered zero/one/many edge set, then jointly seals those fresh
observations and the verified backend call into `OperationPreconditionSet`. Callers cannot provide a
retained witness or select/omit a member. The private zero-dependency branch is available only for operations whose
descriptor declares none. Thus
"act before the dependency is ready", choose an unrelated
dependency, or mix production and harness values is a **type error**, not a convention. The witness is
generative and bound to the exact resource identity observed; readiness for one VM, daemon, mount,
registry, or generation cannot authorize another resource with the same phantom tag. As
`Ready DockerDaemon` already gates the in-VM project-image build and `Ready RegistryServing` already gates
the image push, so must the durable-share mount gate the alias step (§ DD).

The Phase 9 foundation now removes `HostBootstrap.Readiness.Internal`, keeps every readiness constructor
private, validates `Micros` and `PollPolicy`, and fixes each `BackendProbeKey` to a closed planned-resource
family. A plan-indexed probe can be constructed only with the matching `PlannedResource` and positive
generation, phase, and observation versions; tests drive the real polling transition rather than minting
test witnesses. `ObservedReady` remains only as explicitly non-authorizing compatibility evidence for
call paths that have not yet adopted the plan-owned operation-preparation algebra. The downstream
provider/interpreter phases named in § O own that migration; they must not treat compatibility evidence
as mutation authority.

The opaque witness retains the observed backend generation, resource phase, and journal version, but it
is only a precondition-set input. Immediately before preparing an operation, the interpreter consumes that
set, atomically revalidates those facts, reruns every plan-owned dependency/target probe, and obtains any
conditional backend versions. Only success jointly returns the exact
`PreparedOperation`/`PreparedPreconditions` pair the adapter accepts; no retained witness, handle, edge,
or raw prerequisite bundle is an adapter argument. Replacement is `Conflict`; same-identity loss of
readiness is `Failure ... ReprobeBeforeRetry`; lack of a conditional backend primitive is
`Unsupported`. A post-prepare conditional mismatch enters the typed unknown/recovery graph rather than
assuming readiness. Retaining an old Haskell value cannot bypass those gates, and the type does not claim
an external service stays ready forever.

A probe is **retrying and total**: every observation outcome is represented as typed data. Its result
distinguishes ready, transiently not ready, unavailable/not-applicable, ownership conflict, and
deterministic failure; an exception, Boolean, or bare exit code is never used as the state model. Transient
conditions are retried within an opaque `PollPolicy`; smart constructors require positive attempts and a
non-negative bounded delay, compute total duration with overflow-safe arithmetic, and reject zero,
negative-equivalent, overflowed, or over-limit policies before polling. Deterministic failures and
conflicts stop immediately with structured details. A one-shot in-guest step that runs a compound `set -eu` script with
no witness and no retry is a **defect**: it races the readiness it assumes and hides the reason it failed.

Guest probes stay **trivial** so they survive the host→guest command path unchanged. On Windows the
`wsl -d <distro> -- bash -lc <script>` invocation crosses PowerShell's native-argument quoting, so a probe
is a single simple command (`docker info >/dev/null 2>&1`, `test -d <path>`, `readlink <path>`) — never a
multi-statement script with nested `"$(… "…")"` quoting. Retry and branching live in Haskell (the
`awaitReady` loop plus a pure classifier over the probe output), not in an inline shell loop.

**Failure is legible.** A bring-up failure never collapses to a message-less `ExitFailure 1`. Lifecycle
failures are a structured exception (`LifecycleFailure`, the peer of the `SafetyRefusal` round-trip, § Z)
that carries the cause across the subprocess and harness boundary, and a runner that captures a child's
output **streams it, then dies with it** rather than folding it into a stderr the harness unwinds. The test
report card renders the carried message (`displayException`), so a failed variant states *why*. The
canonical homes are [readiness](../documents/architecture/readiness.md) and
[harness_workflow](../documents/architecture/harness_workflow.md).

### DD. The Durable-Share Primitive

A host directory reaches a guest through **one** per-substrate share primitive on `SubstrateProvider` /
`HostPathShare`, modeled as pure data and interpreted generically (the lifecycle peer of the launch/cordon
effect lists, § U). It has three parts, and the substrates differ only in which parts they need:

- a **host-side reconcile** (`ShareReconcile`, the optional field shaped like the cordon-reconcile of § O) —
  Incus attaches a disk device post-create; Lima declares the mount at instance create; WSL2 needs none
  (drvfs already exposes the drive and the path rewrite already exists);
- a **guest-side alias reconcile** — where a provider guest is present, its stable Docker-visible path is
  a symlink to the share, modeled as a pure `AliasState`
  (`AliasAbsent | AliasLinkedCorrectly | AliasLinkedElsewhere | AliasOccupied`) with a total classifier
  and a create/remove planner. The same classifier serves every provider guest. Direct Linux has no
  guest boundary and supplies the canonical host projection directly, so it must not create or consume
  this alias;
- a **mount-readiness** probe (§ CC) — the guest share is proven present and writable before the alias is
  scheduled, and the alias transition revalidates the same share identity immediately before mutation.
  The capability prevents logical out-of-order use; it does not pretend an external actor cannot unmount
  the share between unrelated system calls.

The target makes every step of the share readiness-/identity-gated (§ CC) and legible. The current VM
call graph still threads the non-authorizing `ObservedReady` compatibility value; it can no longer forge
plan-indexed `Ready` authority, but the provider adapter has not yet migrated to the prepared-operation
pair. Canonical direct-host root admission and its same-root host bind are implemented; the remaining
provider boundary projections stay open. The primitive is what makes a durable root host-backed rather than frame-local; until a real
destroy→up→read run validates it end to end, no governed document describes host-durable `.data` as
validated (§ C, § J). The canonical home is
[durable_state](../documents/architecture/durable_state.md).

### EE. Opaque Capabilities and Phase-Indexed Lifecycle State

Capabilities are authority, not descriptive labels. `Capability`, readiness witnesses, ownership
witnesses, adoption authority, and lifecycle-state tokens expose no constructors or record updates from a
public or `Internal` library module. They are minted only by validated transitions, narrowed when crossing
a frame, and consumed by the operation they authorize. Tests use injected interpreters and typed fixture
builders; exporting a constructor “for tests” defeats the boundary.

Ordinary Haskell values are not linear, so “consumed” is also an interpreter invariant: each transition
checks the current generation/lease and journals the successor state or one-time nonce consumption.
Hidden constructors and indices prevent construction and wrong-resource/scope mixing; the journal
rejects stale replay by cooperating interpreters. It does **not** by itself exclude an external actor in
the check/effect window.

Closing that window is a **protocol** requirement, not a platform-primitive requirement. Before mutating
a named VM, cluster, generated config, data root, port, host daemon, global provider setting, or durable
alias, a backend satisfies all four clauses of **Locked-Origin Identity Ownership**:

1. **Exclusive entry.** A kernel-held lock the OS releases on process death is acquired before any
   mutation and retained across the whole observe/mutate/settle bracket.
2. **Durable origin record before the first write.** The exact original bytes *or* an explicit
   absence marker are recorded durably, keyed by a generative nonce, before the first mutating call.
3. **Identity binding, never pathname.** Every operation after the first binds to the object's stable
   kernel identity — the `(volumeOrDevice, fileIndexOrInode)` pair — not to the name it was reached by.
4. **Conditional release.** Restore and delete re-observe that identity and act only on an exact match;
   any other observation is a structured `Conflict` and the object is left untouched.

The guarantee this buys, stated exactly: it **excludes** crash/retry and concurrent cooperating runs, and
it **detects** rather than silently overwrites foreign mutation. It does **not** exclude a hostile
same-privilege process. No substrate supplies that exclusion, so no plan may claim it. A backend that
cannot satisfy all four clauses — an unsupported filesystem, an unavailable lock, an identity the
platform will not report — reports `Unsupported` and mints no receipt. A pathname compare, content hash,
or immediate re-probe substitutes for none of the four. No plan may claim compile-time exactly-once
effects from phantom types alone.

The canonical statement of this contract, with its per-substrate realization, is
[ownership_invariant](../documents/architecture/ownership_invariant.md).

The lifecycle interpreter carries lifecycle scope, resource identity, ownership, and phase indices in
its state type: `ResourceHandle scope planId id resource ownership phase`. `Unclassified`, `Managed`,
and `Unmanaged` are distinct ownership states; provisioned, ready, staged, built, running, stopped, and
destroyed are distinct phases (the exact names may vary). A transition accepts only the predecessor
scope/plan/resource/ownership/phase it can legally follow and returns the successor state plus
capabilities retaining that same scope and plan.
Recursive descent and teardown use these values rather than reconstructing authority from a
`BinaryContext`, a file path, a process check, or a Boolean. A context may describe requested placement,
but only a validated local transition can mint authority to mutate it.

Every mutating reconciler returns `Either ReconcileError ReconcileResult`. A `ManagedResult` carries a
`ResourceHandle scope planId id resource Managed phase`, the matching
`OwnershipReceipt scope planId id resource`, and an indexed outcome whose non-authorizing view is
`Changed (Created | Repaired | Adopted)` or `Unchanged`. Operation-specific hidden evidence fixes legal
from/to/outcome combinations: adoption consumes matching authority, and `Unchanged` requires verified
prior committed ownership at the same phase. A `ForeignResult` carries only a
`ResourceHandle scope planId id resource Unmanaged phase` and a foreign observation. The latter type
cannot be passed to mutation, stop, or destroy. The only `Unmanaged` → `Managed` transition requires
an opaque `VerifiedForeignOrigin scope planId id resource generation observationVersion` that jointly
binds that handle/observation plus matching
`AdoptionAuthority scope planId id resource generation observationVersion operationKey`, and reports
`Changed Adopted`; ordinary reconciliation cannot
silently adopt. Idempotence never degrades a resource validated as ours into an unmanaged observation.
`ReconcileError` distinguishes `Conflict`, `SafetyRefusal`, `Unsupported`, and `Failure`. A conflict
carries structured expected/observed identity and an
operator-safe remedy; a safety refusal records why an otherwise legal transition was declined; a failure
records the attempted operation, cause, and `RecoveryDisposition`. Observation is total (§ CC), so absence, not-ready,
unsupported, foreign ownership, and probe failure cannot collapse into one branch. A conflict or safety
refusal never triggers cleanup of the refused resource.

Before a run mutates a named VM, cluster, generated config, data root, port, host daemon, or global
provider setting, it must hold all four clauses above for that backend. A backend that cannot supply
them returns `Unsupported`; a pathname compare or content hash substitutes for none of them. The
resulting ownership receipt records the
exact plan/resource identity and generation and is required by recursive teardown. Cleanup is therefore a typed
ownership operation: compatible unowned state remains `ForeignResult`, incompatible identity is
`Conflict`, a policy refusal remains `SafetyRefusal`, and an unsatisfiable clause is `Unsupported`.
Owned partial state is unwound in reverse lifecycle order and all cleanup failures are aggregated.

Because an external effect and the ownership record cannot share one atomic transaction, durable state
is an untrusted, generative-identity-free `PersistedJournalRecord`. Protected-store verification yields
`VerifiedJournalRecord scope planDigest frameKey resourceKey generation operation operationKey
recordVersion phase`;
matching plan-digest, frame/resource-identity, and operation bindings yield the local private
`JournalEntry scope planId frame id generation resource operation operationKey recordVersion phase`.
Its legal graph is:
`IntentRecorded → ReservationOutcomeUnknown`; reservation unknown branches to `ReservationAbsent`
(same-generation reservation retry), `Reserved`, `ObservedManaged` (reserve-is-create), or terminal
`ObservedForeign`; `Reserved → EffectOutcomeUnknown`; effect unknown branches to `EffectAbsent`
(same-generation effect retry), `ObservedManaged`, or terminal `ObservedForeign`; and **only**
`ObservedManaged → Committed`. Cleanup is `Committed → TeardownOutcomeUnknown → Released`, with an
observed same identity returning explicitly to `Committed` for retry and replacement becoming terminal
foreign state. A released ephemeral generation can start a later acquisition only from verified absence
plus an opaque
`FreshGeneration scope planDigest planId frame frameKey resourceKey id resource oldOperation
oldOperationKey oldGeneration newAcquireOperationKey newGeneration`; it binds the exact local
identity/operation evidence and old ordinary/adoption release to a distinct new `AcquireOperation` key.
The token is only eligibility: its sole consumer creates a
released-reacquisition origin, and `registerOperationIntent` revalidates/consumes the exact protected
release/absence version while atomically writing the new generation and session membership. First
acquisition instead requires the sole protected no-prior-generation proof. An unknown or foreign
generation has no rollover edge. Stable scope/plan
digest/frame/resource/generation/operation key—not `planId`, resource
`id`, or handles—are persisted before a mutating backend call; each unknown state is durable before its
external operation. Hidden, phase-/operation-indexed constructors expose no absent/foreign-to-commit edge,
wrong-operation substitution, or unproved new-generation retry.

Adoption is a separate journal transaction:
`AdoptionIntentRecorded → AdoptionOutcomeUnknown`; total reprobe then records
`AdoptionObservedManaged`, `AdoptionObservedAbsent`, or terminal `AdoptionObservedForeign`/refusal.
Only `AdoptionObservedManaged → AdoptionCommitted` can mint adopted ownership. Authoritative absence
permits an explicit retry under the **same** adoption operation key only after `OldPermitsFenced` proves
that a delayed transfer cannot land; without that proof it is `Unsupported`/operator resolution, not a
new attempt. Foreign observation and policy refusal are terminal. Cleanup is
`AdoptionCommitted → AdoptionTeardownOutcomeUnknown → AdoptionReleased`, and there is no adoption edge
from an ordinary `ObservedForeign` acquisition entry.
Both ordinary and adoption release records can authorize a later exact-resource `FreshGeneration`
rollover after verified absence; either must pass through the sole released-reacquisition origin and
atomic intent/session registration to begin the ordinary acquisition graph under its distinct new
acquisition key, while explicit re-adoption would instead require new adoption authority and intent.
Neither unknown phase can roll over.
Receipt rebinding requires raw persisted receipt verification, exact plan/frame/resource/operation
bindings, and a `ReceiptCommitProof` admitting only the matching ordinary `Committed` acquisition or
matching `AdoptionCommitted` transfer. A phase transition, teardown entry, same generation under another
resource/operation, or foreign observation cannot mint a receipt. Operational failures carry their
recovery disposition and never erase journal state.

Repairs and non-release phase changes are separately journaled effects. A repair uses
`RepairIntentRecorded → RepairEffectOutcomeUnknown` before its backend call, then total reprobe observes
exactly one of `RepairObservedOriginal`, `RepairObservedTarget`, `RepairObservedAbsent`,
`RepairObservedUnexpected`, or `RepairObservedForeign`. The original-phase branch may retry only the
same operation key after old-permit fencing; **only**
`RepairObservedTarget → RepairCommitted` commits. Absent, unexpected third phase, and foreign
replacement are terminal/operator-resolution branches and have no commit edge.

Boot, stop, and destroy-reachability use an operation indexed by exact `resource/from/to` and the
analogous total graph:
`PhaseIntentRecorded → PhaseEffectOutcomeUnknown → PhaseObservedFrom | PhaseObservedTo |
PhaseObservedAbsent | PhaseObservedUnexpected | PhaseObservedForeign`. The from-phase branch may retry
only the same operation key after old-permit fencing; **only**
`PhaseObservedTo → PhaseCommitted` commits. Absent, unexpected third phase, and foreign replacement are
terminal/operator-resolution branches. Both effect families preserve the existing receipt, and neither
can enter acquisition/adoption commit, teardown release, or `FreshGeneration`. Kill recovery reprobes
instead of blindly replaying those effects.

Execution profile is also indexed typed authority. Fresh construction uses
`LifecycleProfile (Production projectId)` or `LifecycleProfile (Harness projectId runId)`. Configful
abandoned Production `ProjectUp` uses the distinct
`RecoveredProductionLifecycleProfile projectId specDigest planDigest planId brokerGeneration`;
constructors are
opaque to consumers. Phase 15.9's non-config gate verifies installed project identity, OS/operator
authorization, protected authority-store identity, and the exact verb before minting
`RootInvocationAuthority (Production projectId) brokerGeneration verb`; it does not mint a profile.
Phase 10.9's rank-2 production and harness mode transaction creates
the fresh broker generation and exclusive `UnboundRunLease`; the harness opener generates the run
identity and yields only the matching existential
`HarnessRootAuthority projectId runId brokerGeneration`. The public root brackets are composite: they
invoke the Phase 15 verifier inside the protected Phase 10 mode/lease transaction, without exposing an
intermediate state. Only Phase 10's fresh profile openers can combine the exact root scope/authority,
active mode, and still-unbound lease into the matching `LifecycleProfile`; the resulting plan snapshot
then binds that same lease. Its separate protected bound-recovery opener requires the exact Production
`ProjectUp` root, active mode, bound lease, verified/bound snapshot and binding, and
`BoundInvocationRecovery`, and yields only the correspondingly indexed recovered profile. It cannot
inhabit Harness or teardown scope. Phase 17.4 only requires the authority at its parser route. Both profiles contend on one project-wide
`ProjectModeLease projectId mode brokerGeneration` record. Production retains its mode across `down`;
Harness acquisition rechecks its derived
preconditions in the same compare-and-swap, and Harness mode is released only after terminal close.
`bindRunLease` is an effectful protected compare-and-swap which verifies the protected snapshot and
produces `BoundRunLease scope specDigest planDigest brokerGeneration` before any `PreparedOperation`. Fresh binding
jointly yields `NormalActiveRecovery`; existing/abandoned binding yields
`BoundInvocationRecovery`. Its Production eliminator first distinguishes an exact terminal
`up`/`down` acknowledgment awaiting/uncertain lease close from Open operational revision recovery; the
former can only resume the stable invocation-close key. Its Harness eliminator distinguishes exact
persisted Closing from Open before the Open branch further selects normal/incomplete/completed revision
recovery. No generic journal exists before those eliminators. Callers
cannot choose the run or broker phantom first, and every effect-authorizing gate requires the root
authority and lease to carry the same broker generation. Each Phase 10 profile opener consumes the
matching Phase 15 root authority inside the composite bracket, breaking any
command-authority/lifecycle-validation cycle. `withProjectPlan` consumes the profile/config/draft, and
`containerPlan` is only a projection of that exact
`ProjectPlan scope specDigest planId configId cfg`; there are no
independent name/path/profile arguments that can disagree. A `TestComponent` accepts only
harness-profile authority, so it cannot select `Production` and rely on a post-resolution check.
Harness config assembly before binding is restricted to `ConfigAssembly`; normal failure closes the
unbound lease only after protected proof that no token, prepared-attempt, journal, or effect exists, while a crash
leaves an explicit unbound incomplete lease for the recovery sweep.

In-process authority is non-serializable. Recursive self-invocation uses the independently authorized
root's protected `AuthorityBroker`/bound lease and a one-time token bound to exact scope, plan revision,
broker generation, edge, child config digest, verb, and phase over a private duplex session—never Dhall,
`argv`, environment, or durable config. Immediate parents receive no signing key. Challenge/grant plus
byte verification through the scope-correct `ProjectCodec` produces the generic
`VerifiedConfigWire scope childConfigDigest childConfigId` and exact
`VerifiedHandoff ... ConfigHandoff childConfigId verb phase`; narrowed child
bytes receive a fresh local `childConfigId`. These values do not directly authorize dispatch:
`withChildProjectPlan` consumes them with the validated config, closed verb, and non-empty plan draft and
jointly yields a fresh local `ProjectPlan`, `PlanDigestBinding`, and exact `ChildPlanAuthority` inside a
rank-2 continuation. Only `authorizeChildProject` consumes that narrow authority; it never receives root,
harness-root, or signing authority.

Each one-use command/handoff invocation atomically opens one versioned operation session only after the
current broker has admission, advances the shared project-journal version, and returns its sole successor
state/permit pair. Session close does the same. Clean activation proves no older-generation session
remains Open.
Abandoned-run recovery instead consumes the exact old-permit fence set in a protected exact-set fold,
verifies a manifest pairing the independent complete session and operation sets, CAS-rebinds each
existing stable session record to the fresh broker/local identity, and internally handles every unknown,
pre-call continuable, whitelisted already-observed retryable, successful, or terminal operation before requiring that exact session's
Closed proof plus sole successor state/permit pair. A zero-operation Open session remains a required
member. Initial intent creation consumes the exact first/reacquisition origin and session membership is
atomic with that generation write. A persisted initial intent with no fence is an explicit recovery
state; the classifier idempotently completes the stable initial-fence protocol before continuable work
receives an `OperationFence`. It also verifies/rebinds the complete
resource-record set; only the matching bound snapshot and that opaque set can yield a recovered frame
and a closed owned-or-released evidence sum for the forest's exact authorization point. The owned branch
alone yields a managed handle/receipt; the released branch alone yields the verified tombstone and can
mint `FreshGeneration` only after protected absence plus a distinct acquisition key. That eligibility
token cannot call or register by itself; its sole consumer supplies the exact origin to the atomic
registration compare-and-swap. Only both complete
session/operation sets yield
`CurrentBrokerSessionAdmission`; missing/duplicate records, wrong membership, missing/replaced resource
evidence, or unresolved recovery cannot manufacture it or create a second logical session. Before each
child lifecycle effect, the root runs one protected
prepare compare-and-swap that revalidates exact
project-mode and broker epochs, bound lease, active revision/no migration freeze, authority
epoch/verb/phase/frame, Open-project and Open-session versions, current authoritative fence, readiness
generation, journal phase, operation key, exact plan-owned closed precondition-set identity, and call
digest. It reruns every target/dependency probe and conditional version; stale/replaced/not-ready
evidence returns no `PreparedOperation`. It durably records the operation-specific unknown state, advances the session
version, and only then returns matching attempt/fence-indexed `PreparedOperation` and fresh
`PreparedPreconditions` required by the backend adapter together with the successor Open-session, successor
Open-project operation state, and matching revision-permit authority at one fresh journal version. The
consumed journal version cannot authorize a later prepare, settlement proof, or project close. The
prepared pair retains the exact resource identity/kind, generation, operation/key, precondition-set/
call digest, session/fence/attempt, and prepared journal version; each named adapter also requires the
matching descriptor, operation binding, or operation-indexed teardown step and accepts no separately
retained readiness/prerequisite value. Every terminal observation returns
`OperationAdvance` on success or typed failure, and its eliminator exposes the result only with the sole
fresh successor state/permit pair. Initial fences and crash-time fence rotations have durable
intent/unknown/observed states and resume the same stable proposed epoch; delayed old permits are
rejected or deduplicated. Terminal acknowledgment verifies every registered outcome settled and
compare-and-swaps that exact session version Closed, so a concurrent prepare or retained settled proof
cannot win. Children reprobe raw stable journal/receipt records and bind them to fresh local
plan/resource identities rather than carrying capabilities across processes. Ordinary acquisition,
ordinary teardown, adoption transfer/adopted release, repair, and managed phase transition enter their
distinct unknown states before their respective backend calls.

Successful ordinary Production `up`/`down` then has one further typed boundary. The core recursive
interpreter alone mints `ProductionInvocationCompleted` after independently deriving the complete
session/operation sets, proving every session Closed, every operation terminal, and no prepared operation or
prepared call outstanding, and revoking current-broker admission at that exact journal version.
`closeCompletedProductionInvocation` revalidates that proof plus the Production mode epoch, bound lease,
snapshot/binding, active revision, complete resource-record set, and Open-project state in one protected
compare-and-swap. Its success consumes only the `BoundRunLease`, broker admission, and revision-permit authority;
it returns `ProductionInvocationClosed` with the same
`ProjectModeLease ... ProductionMode`, bound snapshot/binding, active revision/journal,
`RehydratedResourceSet`, and successor `OpenProject` state. It does not release mode or resources and
cannot mint `ClosedProject`. Unknown acknowledgment exposes only
`ProductionInvocationCloseUnknown`. Bound recovery classifies the persisted terminal acknowledgment
before revision recovery and can only observe the same close already committed or idempotently resume
that stable close key; it cannot reopen a session. `ProjectDestroy` and verified true-pre-effect refusal
remain the only `releaseProductionMode` paths.

The root broker remains live through one recursive invocation. A later Production `down`/`destroy`
re-runs the independent root gate, verifies the protected versioned non-secret plan/teardown snapshot,
lease/journal/receipts and backend identities, and opens a new broker generation. It does not infer old
teardown from edited/missing config or a changed binary; unknown snapshot versions refuse without
effects. Compatible revision carry first uses the sole `withProjectUpMigrationProfile` producer to
revalidate the exact `ProjectUp` migration root, active mode, old-bound lease/snapshot/binding, and
`NormalActiveRecovery` without a new plan. The pre-freeze `withProspectiveMigrationPlan` bracket
consumes that indexed profile and same old-bound package with the scope-correct new config and non-empty
drafts and jointly creates one fresh candidate plan plus its pure non-authorizing
`ProspectivePlanSnapshot`/binding. Only `withPlanMigration` can consume that exact candidate. It
persists/fsyncs and authoritatively reads back the candidate under a fresh stable migration key before
it may freeze the old revision; failed/unknown persistence leaves admission unchanged, and a
pre-freeze crash leaves only a non-authorizing unreferenced record. After persistence, the opener
derives the complete exact old `VerifiedResourceRecordSet` internally, atomically records that same
stable key while freezing operation preparation and revoking session admission, then drains or
authoritatively fences every old prepared operation before staging. Session opening and freeze contend on the same
project-journal/revision version; the freeze cannot settle until every independently enumerated
session, including zero-operation sessions, is Closed. Per-resource migration authority is
indexed by unchanged frame/resource/generation/ownership-operation/key/policy, settled
owned-or-released disposition, and complete `recordSetDigest`. A plan-owned exact-set fold stages each
complete `VerifiedResourceRecordBundle`; owned members carry their receipt, released members carry only
their tombstone, and missing/duplicate/extra/unknown/disposition-mismatched members refuse.
Live migration uses `bindLiveMigrationPlanSnapshot` over the already-built candidate plus the exact
stable-keyed persisted proof; it never reconstructs a plan after freeze. Abandoned Production
`ProjectUp` must first load the exact persisted prospective `VerifiedPlanSnapshot` named by the
incomplete recovery record and then use the exact bound-recovery profile plus
`withRecoveredMigrationPlanSnapshot`. It may reconstruct only when the provided config/drafts render
that loaded snapshot. These gates produce only migration-local plan/binding values, and prospective,
frozen, and staged records authorize no effect. Freeze replaces the old bound lease with one exact
stable-keyed `FrozenMigrationRunLease`. Only a protected
compare-and-swap over the complete set can archive old active
records, switch the lineage old→new, consume that frozen capability, return only the new-bound lease,
and yield one old/new-indexed `PlanMigrationBarrier`; old- and new-bound authority cannot coexist.

`activateMigratedPlan` must consume that barrier, the exact new-bound lease/active revision, local
plan/binding, and complete set before exposing a journal or preparation authority. It rechecks that no old session
remains Open and jointly yields the new revision's `CurrentBrokerSessionAdmission`; completed configless
recovery must produce the same admission before opening a teardown session. A pre-CAS restart resumes
the frozen old-active migration under a fresh local `migrationId`; `ProjectDown`/`ProjectDestroy` may instead cancel
inactive staging while old remains active. A post-CAS restart selects completed recovery. Both paths
first load and verify the exact prospective snapshot named by the durable `stableMigrationKey`, never a
digest inferred from current config. `withCompletedMigrationPlan` then requires the exact new-bound
recovery profile and rebuilds configful forward state only when it matches those persisted bytes, while
`withCompletedMigrationRecovery` uses the same non-secret protected snapshot data for configless teardown. Kill
injection between CAS and activation must not issue a `PreparedOperation`. Old-digest binding/preparation cannot reopen
after the CAS, and released tombstones cannot become managed.
Before a new harness run, `recoverAbandonedHarnessRuns` handles both unbound no-effect and bound
snapshot-driven old leases through separate rank-2 folds over the exact
`VerifiedIncompleteRunLease` values; terminal closure is rechecked after every callback. Bound recovery
first eliminates `BoundInvocationRecovery`; a persisted Closing epoch resumes only its close journal,
while Open revision recovery selects
normal/incomplete/completed activation. Normal activation with an older Open operation session must use
the recorded-session interpreter and independent session/operation manifest before any current-broker
session admission. Only the
protected empty-set compare-and-swap proof can be
consumed by `withHarnessRoot` for fresh allocation. Harness brokers cannot sign
Production grants. Replay/wrong bindings refuse; broker loss before prepare refuses, while loss after a
prepared backend call leaves an explicit unknown for reprobe. Every edge invocation receives a fresh token.
Nested recovery derives a signed non-secret adapter wire from the bound snapshot and requires an exact
parent→child `RecoveryProjectionBinding`, `VerifiedRecoveryWire`, and
`VerifiedHandoff ... RecoveryHandoff recoveryWireId verb TeardownPhase` plus the closed teardown
authorization point produced only by the forest for either ordinary child-settled work or destroy-only
pre-descent reachability. The recovered frame and exact resource evidence must come from the bound
snapshot plus complete rehydrated set; raw receipt bytes cannot authorize it. Recovery does not
reconstruct a normal child config and cannot authorize `ProjectUp`.
Controller-managed service restarts use a separate platform/OS verifier. The signed manifest authorizes
an immutable rollout revision/controller template; after creation, independently measured workload/OS
identity contributes the concrete pod UID plus restart count or invocation nonce. Together with the
pinned project key they yield one
`VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId
configDigest secretDigest service rolePlanDigest permittedEffects`; its activation authority, role-plan
projection, and protected secret-channel locator cannot be separated or mixed.
The scope-correct project-owned `RoleCodec` verifies the mounted role-wire bytes, and the activation
internally reads/verifies the Production-empty or Harness-private bundle, into a fresh
`VerifiedConfigWire`/`ValidatedServiceRequest`. The signed projection proves its narrowed
`rolePlanDigest` and exact `configDigest` belong to that parent `planDigest`; the child does not recompute
the full lifecycle plan from its least-authority wire. `verifyRolePlanDraft` first checks the project
draft/digest without durable mutation. `withRoleLifecycleAdmission` then atomically reserves the one-use
lifecycle admission/journal—or yields only the complete predecessor recovery manifest—and
`withRuntimeRolePlan` linearly consumes that exact admission plus verified draft. It yields only
`RolePlan scope specDigest planId configId secretDigest frame revision instanceId`, the matching
`RolePlanDigestBinding`, and a same-`planId` `VerifiedServicePlacement`; `selectAndRunService` also requires
the exact Serve cursor, ready handles, retained receipt/lease package, and finalized runtime spec. It rechecks the
workload-instance identity, proves the selected handler's exact effect row (including opaque
durable-placement authority where required), and atomically transfers a private
`ServiceCommandAuthority scope specDigest planId configId secretDigest frame revision instanceId
ServePhase service effects` into the internal selected package. R1/I1 values cannot run in R2/I2 or after
I1 terminates; non-exclusive rollout overlap is permitted. Exclusive lease transfer publishes the
successor only after exact-set old-instance recovery produces typed
`ServiceLeaseTransferBarrier` from an atomic backend fence or retained-lock in-flight-settlement barrier
covering every predecessor; `resumeRoleLifecycleAdmission` consumes it before a new plan exists, and
unsupported backends refuse. The core-owned masked run-to-Exit operation is the only public runner. Activation alone cannot authorize
effects or execution. A restart cannot construct a
lifecycle `ProjectPlan`, root authority, or lifecycle mutation. Dockerfile-time checks use ephemeral,
project/spec/config/build/source/builder-bound `BuildInvocationAuthority`, a
scope-correct Production `ProjectCodec`, `VerifiedConfigWire (Production projectId) ...`, a matching
`ImageBuildFrame projectId specDigest configId frame`, and
`VerifiedSourceContext projectId sourceDigest`, never the baked config alone. Identical bytes from
another installed project cannot satisfy that gate. Backends
unable to verify those
identity/epoch channels return `Unsupported`. The canonical full algebra is
[lifecycle_state_model](../documents/architecture/lifecycle_state_model.md).

### FF. Rolling Base Selection and Native Compatibility

`hostbootstrap` is greenfield and intentionally uses rolling
`basecontainer-<flavor>-<arch>` tags. Each base rebuild discovers and selects the current/latest
compatible upstream parent, tools, and package sets at build time; rebuilding the same source revision
need not reproduce an earlier image. A committed base-input version lock is not required. TLS and
available integrity metadata should still protect downloads, but neither turns the selected versions
into a replayability contract. A resulting digest may identify one published build for inspection or a
single workflow handoff; it does not make locked inputs, digest-pinned consumers, or reproducible rebuilds
part of the architecture.

`base build` and `base build-and-push` validate that the requested architecture matches the native Docker
engine/host architecture before work starts. Cross-architecture emulation is not silently selected. A
publish workflow runs the complete Python, Haskell, and consumer source-quality gates, builds natively,
pushes the rolling tag, pulls that published tag, and may use the pulled result in a real-consumer
compatibility smoke. Local same-named images do not substitute for that post-publish pull. The smoke
checks compatibility only; it is not reproducibility or complete-cache evidence.

Host-native and container builds use the same consumer `cabal.project`. A derived Dockerfile never swaps
in a container-only project and never imports base-owned freeze files. The inherited Cabal store is an
opportunistic cache: matching artifacts may be reused, while cache misses may resolve, download, and
compile normally. Offline builds and guaranteed cache hits are not acceptance criteria. Phase 6 owns
rolling publication, native-architecture enforcement, source gates, pull, and the compatibility-smoke
workflow; Phase 12 owns the single-project and opportunistic-store policy.

### GG. Scope-Indexed Network Reachability and Blob Delivery

A network endpoint is not interchangeable text. Core models the scope from which a client can reach an
endpoint (`ClusterOnly`, `ProviderLocal`, `HostLocal`, or `Public`) and keeps that index on opaque
endpoint, exposure, and client values. A finalized registry plan jointly binds the client, verified
published exposure, backing object-store endpoint, credential authority, and blob-delivery strategy.
Consumers may contribute concrete registry resources and image operations, but may not independently
select endpoint strings or a serialized redirect boolean.

`RedirectToBackend` is constructible only from a proof that the client scope can reach the backend
scope. There is no proof from `HostLocal` to `ClusterOnly`; that topology can construct only
`ProxyThroughRegistry`. Rendering is total over delivery strategy, so proxy delivery emits
`storage.redirect.disable: true` and redirect delivery emits `false`. The boolean is output, never an
input to the DSL.

Static coherence does not replace runtime identity. The plan-owned route probe verifies the exact
client→exposure and registry→store paths, rejects an out-of-scope redirect, and yields a
revision-/plan-/registry-/store-indexed `ReadyBlobRoute`. A bare `/v2/` response cannot satisfy an image
operation precondition. Phase 14 owns the generic reachability and delivery algebra, Phase 9 owns the
identity-bound readiness/precondition machinery, and Phase 13 owns the demo renderer and live
host-client→NodePort→cluster-only-MinIO proof. The canonical architecture is
[network_reachability](../documents/architecture/network_reachability.md).
