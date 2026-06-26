# Phase 9: Applied Budget Cordon and One Canonical Parser

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-5-cluster-lifecycle-and-resource-cordoning.md](phase-5-cluster-lifecycle-and-resource-cordoning.md), [phase-8-dhall-generation-and-extension.md](phase-8-dhall-generation-and-extension.md)

> **Purpose**: Make the declared resource budget a genuinely enforced ceiling — wire the applied Linux
> kind-node cordon, run the spare-capacity and fits-within checks before bring-up, and use one canonical
> quantity parser for every budget-derived argument builder.

## Phase Status

**Status**: Active

The budget is now an **enforced** ceiling. The one canonical `parseQuantity` feeds every argument
builder (`colimaSizingArgs` emits the full profiled `colima start` argv; `kindNodeCordonArgs` emits the
`docker update` cap; `incusSizingArgs` emits the VM `limits.cpu`/`limits.memory`/`root,size`), so the
bare `"8Gi"` form is interpreted identically everywhere.
`clusterUp` runs the `verifyBudget` spare-capacity preflight, then applies the Linux kind-node cordon
(`docker update --cpus/--memory/--memory-swap <cluster>-control-plane`) after `kind create` and before
Helm, fail-closed. The pure `fitsBudget` proves a concurrent pod
set fits, and storage is cordoned per substrate (Colima `--disk`, incus `root,size`) while omitted from
the `docker update` argv. `resolveHostCapacity` is substrate-aware: Apple silicon reads `sysctl`
`hw.ncpu`/`hw.memsize` through the resolved `HostTool Sysctl`, while Linux reads `/proc/cpuinfo` and
`/proc/meminfo` `MemAvailable`. All argv builders, the wiring, the pure source mapping, and the live
Apple `sysctl` read are implemented and validated (live `docker`/`incus` execution is exercised in real
runs) (see [development_plan_standards.md § O](development_plan_standards.md)).

This phase is **reopened** for the **Windows** substrate. `resolveHostCapacity` gains a Windows branch (the
peer of the Apple `sysctl` and Linux `/proc` reads), and the one canonical `parseQuantity` gains a
`wsl2SizingArgs` sizing builder alongside `colimaSizingArgs` / `incusSizingArgs` / `kindNodeCordonArgs`,
sizing the WSL2 Ubuntu-24.04 distro at the budget wall (the `.wslconfig` `[wsl2]` memory/processors plus the
vhdx storage cap, § O). Phase-9 **owns** this pure builder;
[phase-11-incus-host-provider.md](phase-11-incus-host-provider.md)'s Windows WSL2 host provider
**consumes** it. That is Sprint 9.6 (`[Planned]`).

## Remaining Work

The Windows host-capacity read and the pure `wsl2SizingArgs` sizing builder are the open work — Sprint 9.6
(`[Planned]`). Both pure paths are cabal-test-closable; the real-Windows-host capacity read and the applied
WSL2 `.wslconfig` + vhdx cap sizing a real distro at the wall are real-run-gated and consumed by
[phase-11-incus-host-provider.md](phase-11-incus-host-provider.md).

## Phase Objective

Turn the budget into an enforced ceiling with defense in depth: the Dhall `assert` at render time, the
pure `verifyBudget`/`fitsBudget` before bring-up, and the applied VM / kind-node / run caps at runtime —
all fed by a single canonical quantity parser and argument builder.

## Sprints

### Sprint 9.1: One canonical quantity parser and argument builder [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`, `core/hostbootstrap-core/test/CordonSpec.hs`
**Docs to update**: `documents/engineering/applied_cordon.md`, `documents/engineering/resource_budgeting.md`

#### Objective

Use one grammar and one set of Haskell argument builders for every budget-derived cordon.

#### Deliverables

- A single quantity parser/arg-builder in `Cluster.Cordon` emitting the complete `colima`, Linux
  kind-node, and `incus` argv.
- The Python bootstrapper does not build sizing argv.

#### Validation

- `CordonSpec` asserts the full profiled `colima start` argv and the `docker update` cordon argv from
  the one `parseQuantity`, including a `"8Gi"` fixture. `cabal test` passes. The Python layer does not
  build any sizing argv.

#### Remaining Work

None.

### Sprint 9.2: Applied Linux kind-node cordon [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`, `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`, `core/hostbootstrap-core/test/CordonSpec.hs`
**Docs to update**: `documents/engineering/applied_cordon.md`, `documents/engineering/cluster_lifecycle.md`

#### Objective

Apply the cordon on Linux.

#### Deliverables

- `cluster up` runs `docker update --cpus --memory --memory-swap <clusterName>-control-plane` after
  `kind create` and before Helm, fail-closed; `<clusterName>` is the resolved `ClusterPlan` name, so each
  per-case test cluster is cordoned. `--memory-swap == --memory` so an over-budget cluster self-limits.
- The cordon application is fail-closed.

#### Validation

- A test asserts the cordon argv targets the resolved control-plane container with budget-derived caps.

#### Remaining Work

None.

### Sprint 9.3: `verifyBudget` and `fitsBudget` wired before bring-up [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`, `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`, `core/hostbootstrap-core/test/CordonSpec.hs`
**Docs to update**: `documents/engineering/applied_cordon.md`

#### Objective

Run the spare-capacity gate and the fits-within proof before any spinup.

#### Deliverables

- The pure `fitsBudget :: Vocab.Budget -> [Vocab.PodResources] -> Either Overflow ()` (the Haskell mirror
  of `Core.dhall`'s `fitsWithin`).
- `verifyBudget` invoked as a real fail-fast preflight (resolve host spare capacity, fail with a one-line
  diagnostic if short); `fitsBudget` proves the generated/concurrent pods fit before bring-up.

#### Validation

- `CordonSpec` covers `fitsBudget` (under/over budget) and the wired `verifyBudget` preflight without
  Docker. `cabal test` passes.

#### Remaining Work

None.

### Sprint 9.4: Per-substrate storage cordon [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`, `core/hostbootstrap-core/test/CordonSpec.hs`, `core/hostbootstrap-core/test/IncusSpec.hs`
**Docs to update**: `documents/engineering/applied_cordon.md`, `documents/engineering/resource_budgeting.md`

#### Objective

Enforce the storage dimension where each substrate allows it.

#### Deliverables

- Storage is cordoned by Colima `--disk` (Apple), incus `root,size` (incus VM), or a quota'd hostPath +
  image GC (bare Linux). Storage is dropped from the `docker update` argv (no flag) but kept in
  `verifyBudget`.

#### Validation

- `CordonSpec` asserts Colima `--disk` reflects the declared storage and the `docker update` argv omits
  storage; `verifyBudget` keeps the storage dimension. `cabal test` passes.

#### Remaining Work

None. The incus VM storage cordon (`incusSizingArgs` — `limits.cpu`/`limits.memory`/`root,size`, where
incus cordons storage at the VM wall) is owned by
[phase-11-incus-host-provider.md](phase-11-incus-host-provider.md). The bare-Linux quota'd hostPath +
image GC is a deployment convention documented in
[applied_cordon](../documents/engineering/applied_cordon.md), not a `hostbootstrap-core` arg-builder.

### Sprint 9.5: Substrate-aware spare-capacity resolution [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`, `core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`, `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`, `core/hostbootstrap-core/test/CordonSpec.hs`, `core/hostbootstrap-core/test/HostToolSpec.hs`
**Docs to update**: `documents/engineering/resource_budgeting.md`, `documents/engineering/applied_cordon.md`, `system-components.md`

#### Objective

Resolve spare host capacity per substrate so the bring-up preflight is a real gate on Apple silicon and
Linux.

#### Deliverables

- On `apple-silicon`, `resolveHostCapacity` reads `sysctl -n hw.ncpu` (logical cores) and
  `sysctl -n hw.memsize` (total physical RAM) through the resolved `HostTool Sysctl`.
- On `linux-cpu` / `linux-gpu`, the existing `/proc/cpuinfo` processor count and `/proc/meminfo`
  `MemAvailable` reads are retained.
- Storage stays reported generously (the applied storage cordon is the real wall).
- The non-substrate-aware off-Linux fallbacks — `readCores`'s unconditional single-core default and
  `readAvailableMemory`'s unconditional petabyte default — are removed and recorded in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

#### Validation

- `CordonSpec` covers the pure substrate-to-source mapping (Apple → `sysctl` keys, Linux → `/proc`), a
  fixture proving an N-core Apple capacity satisfies an N-core budget, and a live Apple-silicon `sysctl`
  capacity read. `HostToolSpec` covers the `Sysctl` constructor. `cabal test all` passes.

#### Remaining Work

None.

### Sprint 9.6: Windows host capacity and WSL2 sizing args [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`
(`resolveHostCapacity` Windows branch, `wsl2SizingArgs`),
`core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`, `core/hostbootstrap-core/test/CordonSpec.hs`,
`core/hostbootstrap-core/test/HostToolSpec.hs`
**Docs to update**: `documents/engineering/resource_budgeting.md`,
`documents/engineering/applied_cordon.md`, `system-components.md`

#### Objective

Extend the one canonical quantity parser to **Windows**: resolve spare host capacity on
`windows-cpu` / `windows-gpu`, and emit the WSL2 distro sizing argv from the same `parseQuantity`, so the
budget is an enforced ceiling on Windows exactly as on Apple/Linux.

#### Deliverables

- `resolveHostCapacity` gains the **Windows branch** (the structural peer of the Apple `sysctl` and Linux
  `/proc` reads): it resolves the logical processor count and total physical RAM through a resolved host
  capacity probe (§ K), so the `verifyBudget` spare-capacity preflight is a real gate on Windows.
- `wsl2SizingArgs :: Resources -> Either String [String]` — a new canonical sizing builder drawn from the
  **one** `parseQuantity`, alongside `colimaSizingArgs` / `incusSizingArgs` / `kindNodeCordonArgs` —
  emitting the WSL2 Ubuntu-24.04 distro wall: the `.wslconfig` `[wsl2]` `memory=` / `processors=` settings
  and the vhdx storage cap (WSL2 cordons storage at the VM wall via the `.wslconfig` + vhdx cap, § O).
  Phase-9 **owns** this pure builder; [phase-11-incus-host-provider.md](phase-11-incus-host-provider.md)'s
  WSL2 host provider **consumes** it to cordon the distro at the wall.
- The bare `"8Gi"` form is interpreted identically by `wsl2SizingArgs` as by every other builder (one
  grammar everywhere).

#### Validation

- `CordonSpec` asserts `wsl2SizingArgs` reflect the declared budget byte-for-byte from the one
  `parseQuantity` (including a `"8Gi"` fixture) and covers the pure substrate-to-source mapping for the
  Windows capacity read (Windows → the host capacity probe). `HostToolSpec` covers any host-tool
  constructor the Windows capacity read resolves. `cabal test all` passes.

#### Remaining Work

Real-Windows-host validation (real-run-gated, § C): the Windows capacity mapping and the pure
`wsl2SizingArgs` builder are cabal-test-closable; the live closure — a real `windows-cpu` / `windows-gpu`
capacity read and the applied `.wslconfig` + vhdx cap sizing a real WSL2 distro at the wall — is consumed
and validated by [phase-11-incus-host-provider.md](phase-11-incus-host-provider.md)'s Windows WSL2 sprint.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/applied_cordon.md` - the one ceiling, the three rings (compile / bring-up /
  runtime), the single canonical parser, the per-substrate storage cordon, and the WSL2 distro sizing
  (`wsl2SizingArgs` — the `.wslconfig` + vhdx wall on Windows).
- `documents/engineering/resource_budgeting.md` - rewritten to budget-as-ceiling, pointing applied detail
  at `applied_cordon.md`; the Windows `resolveHostCapacity` branch and the WSL2 wall.

**Cross-references to add:**
- `system-components.md` updates the `HostBootstrap.Cluster.Cordon` row (`fitsBudget` + applied cordon +
  one parser + substrate-aware `resolveHostCapacity` incl. the Windows branch + `wsl2SizingArgs`).
- `README.md` describes the budget-as-ceiling enforcement.
- `legacy-tracking-for-deletion.md` records the removed off-Linux capacity fallbacks.
