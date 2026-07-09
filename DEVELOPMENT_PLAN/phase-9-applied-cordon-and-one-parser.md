# Phase 9: Applied Budget Cordon and One Canonical Parser

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-5-cluster-lifecycle-and-resource-cordoning.md](phase-5-cluster-lifecycle-and-resource-cordoning.md), [phase-8-dhall-generation-and-extension.md](phase-8-dhall-generation-and-extension.md)

> **Purpose**: Make the declared resource budget a genuinely enforced ceiling — wire the applied Linux
> kind-node cordon, run the spare-capacity and fits-within checks before bring-up, and use one canonical
> quantity parser for every budget-derived argument builder.

## Phase Status

**Status**: Done

**Reopened then closed (2026-07-05, cross-substrate reliability hardening).** The demo real-run gate surfaced
resource-cordon gaps in this phase's scope: there is no host-headroom preflight (the gate is
`budget ≤ total RAM`, and `spareMemoryBytes` is actually *total* physical RAM on Apple/Windows), so a
16 GiB host + 10 GiB VM passes with ~6 GiB left; the in-VM cluster slice reserves a fixed 4 GiB with
`--memory-swap == --memory` (the `kind load`/push OOM); the WSL2 `.wslconfig` write **replaces** the
user's file rather than merging and omits swap from the storage budget; and disk preflight is Windows-only
(`GenerousStorage` no-ops it on Apple/Linux). The fixes landed (see `## Remaining Work`) and **closed
2026-07-05** by a live Windows/WSL2 `test run all` reporting **`6/6 passed`** — the applied cordon read
`docker update --cpus 5 --memory 6442450944 --memory-swap 12884901888` on both bring-ups (the cluster slice
with `--memory-swap` = 2× the RAM cap, the swap-headroom fix), the metal host-headroom preflight passed, and
the `.wslconfig` was merged (other sections preserved) then restored on teardown.

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
**consumes** it. Sprint 9.6 is closed; Phase 11 owns applying it to a real WSL2 distro.

This phase is **reopened (2026-06-30)** for the **honest WSL2 cordon** correction (Sprint 9.7). The
earlier Sprint 9.6 builder/predicate had two inaccuracies now that the WSL2 memory model is understood
precisely: (1) `wsl2SizingArgs` emitted a `vhdx-size` line as if it were a `.wslconfig` key, but
`.wslconfig` has no such key — the per-distro VHDX cap is the `wsl --install --vhd-size` flag, and the
`[wsl2]` block is the *global* utility-VM ceiling (there is no per-distro `wsl --memory`/`--cpu`); and
(2) the Windows `resolveHostCapacity` predicate read volatile `Win32_OperatingSystem.FreePhysicalMemory`,
so the preflight passed on transient post-reboot free RAM and let an undersized host reach the build. The
corrected builder emits `[wsl2]` `processors`/`memory`/`swap` (swap for OOM headroom, no `vhdx-size`
key), the Windows predicate reads stable total `Win32_ComputerSystem.TotalPhysicalMemory`, and the
per-substrate launch is unified behind one pure lift (`HostBootstrap.Substrate.Provider`,
`spLaunch :: ResourceEnvelope -> Either String [HostEffect]`) so the WSL2 `.wslconfig` write/`--shutdown`
is a first-class effect, not a dropped value. See
[applied_cordon](../documents/engineering/applied_cordon.md) and
[wsl2](../documents/engineering/wsl2.md).

**Closed (2026-07-01).** A live Windows `test run all` wrote the `.wslconfig` `[wsl2]` ceiling
(`processors`/`memory`/`swap`) and ran `wsl --shutdown` before registering the distro, and the full
`project up` → `test run all` → `project destroy` lifecycle closed **`6/6`** on a 16 GiB host with **no** WSL
utility-VM session drop — the applied wall is validated on a live WSL2 distro (jointly with
[phase-11](phase-11-incus-host-provider.md) Sprint 11.7).

## Remaining Work

**Historical reopening 2026-07-05 — cross-substrate resource cordon. Code landed, code-check-validated, and
real-run-closed (§ C) 2026-07-05:**

- **Host-headroom preflight — landed.** `HostCapacity`'s `spare*` fields are renamed `total*` (honest: the
  Apple/Windows reads are *total* physical RAM, not spare), and `verifyBudget` now gates memory on
  `budget + hostMemoryReserveBytes ≤ total` (`hostMemoryReserveBytes` = 4 GiB), so a 16 GiB host + 10 GiB VM
  is refused with a `plus host reserve` diagnostic rather than silently over-committed
  (`HostBootstrap.Cluster.Cordon`; `CordonSpec` covers the reserve boundary).
- **Budget-scaled cluster slice + load/push headroom — landed.** `kindNodeCordonArgs` now sets
  `--memory-swap = 2 × --memory` (swap headroom = RAM) so a multi-GB `kind load`/push bursts into swap
  instead of OOM-killing the node at the floor; the demo's `clusterSliceOfBudget` scales the reserve with the
  budget (`memReserve = max 4 (mem/4)`, `storeReserve = max 40 (store/2)`) instead of a fixed 4 GiB.
- **`.wslconfig` merge, not clobber; count swap in storage — landed.** The WSL2 launch emits a new
  `MergeWslConfig` effect interpreted by the pure `HostBootstrap.Wsl2.mergeWslConfig` (drops only the old
  `[wsl2]` section and appends ours, preserving the user's other sections; backup-once keeps the true
  original), replacing the full-file `WriteHostFile`. On Windows `runVmUp` preflights storage as vhdx + swap
  (`withWsl2SwapStorage`). `Wsl2Spec`/`ProviderSpec` cover the merge and the launch effect.
- **Disk preflight on Apple/Linux — landed.** `GenerousStorage` (1 PB) is replaced by `PosixFreeStorage "/"`,
  read via a new `Df` host tool (`df -P -k`, pure `parseDfAvailableKBytes`), so the storage ring gates on
  real free disk on all three substrates. The removed petabyte fallback is recorded in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

- **Host-reserve is metal-only (real-run correction) — landed.** The first real run failed at the in-VM
  `deploy-kind` with `resource budget plus host reserve exceeds host memory: wants 6 GiB + 4 GiB host reserve,
  host has 9 GiB`: the host-OS reserve was being applied to the **in-VM cluster-slice** preflight (the slice
  is already `budget − reserve`, checked against the VM's *available* memory, so re-reserving double-counts).
  Fixed by splitting the reserve into a metal-only `preflightHostBudget`/`verifyHostBudget`; the plain
  `verifyBudget`/`preflightBudget` the in-VM `clusterCreate` uses is reserve-free. `CordonSpec` covers both.

Code-check gate (2026-07-05): `cabal build all --ghc-options=-Werror` + `cabal test all` (292) green; the
demo `-Werror` build green. **Closed (real-run, § C, 2026-07-05):** the metal host-headroom preflight, the
reserve-free in-VM slice preflight, the 2×-swap kind-node cordon, and the `.wslconfig` merge were all
exercised by the live Windows/WSL2 `test run all` **`6/6`** run. **None remaining.**

Sprint 9.7 (honest WSL2 cordon) is `Done`. Static validation is closed: `cabal build all` and
`cabal test all` pass from `core/` (274 tests; `CordonSpec` covers the corrected `wsl2SizingArgs` —
`[wsl2]` + `swap`, no `vhdx-size` — and the `WindowsTotalMemory` capacity source; the `ProviderSpec`
locks the unified `selectSubstrateProvider` launch/teardown/transfer effect lists, with Lima/Incus
byte-for-byte equal to the former argv). The real-run gate closed **2026-07-01**: a live Windows
`test run all` applied the `.wslconfig` wall on a live WSL2 distro and drove the full `project up` →
`test run all` → `project destroy` Windows lifecycle to **`6/6`**, restoring `.wslconfig` on teardown
(jointly with [phase-11](phase-11-incus-host-provider.md) Sprint 11.7, the Windows lifecycle closure).

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

### Sprint 9.6: Windows host capacity and WSL2 sizing args [Done]

**Status**: Done
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

None. `cabal build all` and `cabal test all` passed on 2026-06-26, and the live Windows host-capacity read
returned `Right (HostCapacity {spareCpu = 16, ...})` through the PowerShell/CIM branch. The real WSL2
distro application of the generated `.wslconfig` + VHDX cap is consumed and validated by
[phase-11-incus-host-provider.md](phase-11-incus-host-provider.md)'s Windows WSL2 sprint.

### Sprint 9.7: Honest WSL2 cordon and one pure lift per substrate [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs` (new),
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs` (`wsl2SizingArgs`, `WindowsTotalMemory`),
`demo/src/HostBootstrapDemo/Commands.hs` (generic lifecycle interpreters),
`core/hostbootstrap-core/test/ProviderSpec.hs` (new), `core/hostbootstrap-core/test/CordonSpec.hs`
**Docs to update**: `documents/engineering/applied_cordon.md`, `documents/engineering/wsl2.md`,
`documents/engineering/resource_budgeting.md`, `README.md`, `system-components.md`

#### Objective

Make the WSL2 cordon honest about what WSL2 can enforce, and collapse the per-substrate VM lifecycle to
one pure lift so the WSL2 difference is data, not a hand-branched special case.

#### Deliverables

- `wsl2SizingArgs` emits the real `.wslconfig` `[wsl2]` body — `processors` / `memory` / `swap` (swap
  sized to the memory budget for OOM headroom) — and **drops** the invalid `vhdx-size` key (storage is the
  per-distro `wsl --install --vhd-size` flag, not a `.wslconfig` setting). The `[wsl2]` block is the
  *global* utility-VM ceiling; WSL2 has no per-distro `wsl --memory`/`--cpu`.
- The Windows capacity predicate reads **total** physical memory (`WindowsTotalMemory` →
  `Win32_ComputerSystem.TotalPhysicalMemory`), replacing the volatile `WindowsAvailableMemory`
  (`FreePhysicalMemory`), so the preflight fails fast on a too-small host instead of passing on transient
  free RAM (mirrors Apple `hw.memsize`).
- New core module `HostBootstrap.Substrate.Provider`: one pure `SubstrateProvider` value per substrate
  (`selectSubstrateProvider`, the lifecycle peer of `capacityReadPlan` / `Lift.foldLeaf`), with launch
  modelled as a list of `HostEffect` (`WriteHostFile` / `RestoreHostFile` / `RunHostTool`). WSL2's
  `.wslconfig` write + `wsl --shutdown` is a first-class effect; Lima/Incus carry an empty file-write
  list. The demo's `runVmUp` / `demoTeardown` / `stageSource` / `copyFileToDemoVM` / `runInDemoVM` /
  `demoVMFrameContext` collapse to generic interpreters over that value (the former
  `DemoVMProvider`, the triplicated exists/wait/teardown/stage branches removed).
- `project destroy` backs up and restores the global `.wslconfig` (never-clobber-user-state).

#### Validation

- `ProviderSpec` asserts the Lima/Incus launch effect lists equal the prior argv **byte-for-byte** (the
  refactor is behavior-preserving on the validated substrates), the WSL2 launch writes the `.wslconfig`
  ceiling with `swap` then shuts down then installs with `--vhd-size`, and the guard-prefixed destroy is
  refused outside the managed namespace. `CordonSpec` covers the corrected `wsl2SizingArgs` and the
  `WindowsTotalMemory` source. `cabal build all` and `cabal test all` pass from `core/` (274 tests); the
  demo binary builds.

#### Remaining Work

None. The applied `.wslconfig` wall on a **live** WSL2 distro — the full `project up` → `test run all` →
`project destroy` Windows closure — was validated **2026-07-01**: the run wrote the `.wslconfig` ceiling,
registered/sized the distro, brought up in-distro Docker/kind without a utility-VM session drop, reported
**`test report: 6/6 passed`** across both message variants, and `project destroy` restored `.wslconfig` with
host `.data` preserved (jointly with [phase-11-incus-host-provider.md](phase-11-incus-host-provider.md)
Sprint 11.7).

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
