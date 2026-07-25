# Phase 9: Applied budget cordon and one canonical parser

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-5-cluster-lifecycle-and-resource-cordoning.md](phase-5-cluster-lifecycle-and-resource-cordoning.md), [phase-8-dhall-generation-and-extension.md](phase-8-dhall-generation-and-extension.md)

> **Purpose**: Make the declared resource budget a genuinely enforced ceiling — wire the applied Linux
> kind-node cordon, run the resolved-capacity and fits-within checks before bring-up, and use one canonical
> quantity parser for every budget-derived argument builder.

## Phase Status

**Status**: Active

**Reopened 2026-07-24.** Sprint 9.10 supersedes the earlier Done assessment: the readiness constructor is
public through an exposed `Internal` module, probes do not yet model all outcomes, and lifecycle/reconcile
authority is not phase-indexed or structured. The resource side is also incomplete: `fitsBudget` is not
wired into bring-up; top-level `resources` and raw `context.resourceEnvelope` are duplicate authorities;
child projection copies the full envelope; `clusterSliceOfBudget` can equal or exceed a below-floor
parent envelope; provider quantities round up; existing VM/VHDX walls are not uniformly reconciled; WSL
global state has no exclusive owner; and direct Linux GPU outer effects remain uncapped. The 2026-07-23
run remains historical evidence only.

**Reopened 2026-07-21, CLOSED `Done` 2026-07-23 — readiness framework and type-level config validity.** Two
gaps in this phase's scope surfaced from the Windows/WSL2 durable-share failure. (1) The
`HostBootstrap.Readiness` poll/witness framework — the reliability peer of the pure
`HostBootstrap.Substrate.Provider` lift this phase's Sprint 9.7 unified — was real in code but never recorded
in the plan or `system-components.md`, and its **gating discipline was not universal**: mutating in-guest
steps (the durable-share alias, the `runVmBootstrap` install/build steps, staging) ran ungated and one-shot.
(2) Configuration validity was a **runtime `die`**, not decode-time: `memory`/`storage` were `Text`, the
resource floor a runtime check, `haReplicas`/ports/timeout unbounded `Natural`. Sprint 9.8 formalized the
readiness framework and universal gating; Sprint 9.9 made config validity decode-time via typed newtypes.
**Both closed** on a live Windows/WSL2 `test run all` reporting **`8/8 passed`** (2026-07-23), static-gated by
`cabal test all --ghc-options=-Werror` (**core 382 + demo 98**, fourmolu/hlint clean). The former
`Budget/fitsWithin` compile-ring proposal is **not attachable** to a generated config (it carries `Text`
quantities and no pod set), so it is reconciled to the realized shape: the **partial decode ring** is the
typed newtypes, and the pod-set fit check is a **target bring-up ring** (`fitsBudget`) that current
lifecycle does not call — see
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

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

Current CPU/memory walls are partial and mostly creation-time; a universal storage ceiling is not true
because bare Linux lacks quota/image-GC enforcement (Sprint 9.4 with Phase 5.7). The shared
`parseQuantity` feeds the argument builders, but preflight uses exact parsed bytes while provider
builders round memory/storage up to whole GiB. `clusterCreate` runs the reserve-free `verifyBudget`
capacity preflight, then applies the Linux kind/nvkind-node cordon after cluster create and before
workload deployment, fail-closed, to every node named by `ClusterPlan`. The pure `fitsBudget` helper is
unit-tested but no bring-up call supplies the real concurrent pod set. Initial Lima/Incus/WSL provider
storage mechanisms exist; sized Colima is unwired, existing VM/VHDX sizing is not reconciled, and
storage is omitted from `docker update`. `resolveHostCapacity` is substrate-aware: Apple silicon reads `sysctl`
`hw.ncpu`/`hw.memsize` through the resolved `HostTool Sysctl`, while Linux reads `/proc/cpuinfo` and
`/proc/meminfo` `MemAvailable`. All argv builders, the wiring, the pure source mapping, and the live
Apple `sysctl` read are implemented and validated (live `docker`/`incus` execution is exercised in real
runs) (see [development_plan_standards.md § O](development_plan_standards.md)).

**Historical Sprint 9.6 reopening, superseded by the correction immediately below.**
`resolveHostCapacity` gained a Windows branch (the peer of the Apple `sysctl` and Linux `/proc` reads),
and the one canonical `parseQuantity` gained WSL sizing builders alongside `colimaSizingArgs` /
`incusSizingArgs` / `kindNodeCordonArgs`. The current `wsl2SizingArgs` emits only the shared utility-VM
`.wslconfig` body (`processors`/`memory`/`swap`); the selected install argv separately supplies the
registration-time per-distro `--vhd-size` cap. Phase 9 **owns** these pure representations;
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

**Current:** Sprint 9.4 remains Active for an explicit bare-Linux unsupported storage result and a real
quota/image-GC enforcement decision. Sprint 9.10 is Blocked by Sprints 19.7–19.8 for the scope-indexed
codec and finalized plan/spec that must be its sole capability/resource-envelope source. It owns opaque
readiness/capability construction, total typed probes, ownership-/phase-indexed lifecycle state,
`ReconcileResult`/structured conflicts, one pure provider-exact wall spec/effective budget, a
constructive pre-effect `BudgetPartition`, journaled same-spec live wall authority, complete plan
workload/effect checks, exclusive WSL global-wall ownership, and existing-wall reconciliation. The dated
Sprint 9.8/9.9 text below is historical partial evidence and does not close these contracts.

**Historical 2026-07-21 reopening — initial readiness and type-level scalar validity.** Sprint 9.8 added
the initial forgeable phantom witness and selected step gates; Sprint 9.9 added typed `Quantity`, a
resource-floor constructor, and bounded newtypes. The proposed generated `Budget/fitsWithin` assertion was
not attachable and never landed; the intended pod-set `fitsBudget` bring-up call also did not land.
Sprint 9.10 owns the stronger contract.

**Historical reopening 2026-07-05 — cross-substrate resource cordon. Code landed, code-check-validated, and
real-run-closed (§ C) 2026-07-05:**

- **Host-headroom preflight — historical intermediate, superseded below.** `HostCapacity`'s `spare*`
  fields were renamed `total*` (honest: the Apple/Windows reads are *total* physical RAM, not spare), and
  the first correction put `budget + hostMemoryReserveBytes ≤ total` directly in `verifyBudget`
  (`hostMemoryReserveBytes` = 4 GiB). The later real-run correction split that into metal-only
  `verifyHostBudget`; current plain `verifyBudget` is reserve-free for an already-sliced in-VM cluster.
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

Turn one opaque, provider-exact admitted budget into an enforced ceiling with defense in depth: exact
scalar/resource invariants reject at Dhall promotion, plan admission constructs a proved
`BudgetPartition`, `verifyBudget` and a plan-derived non-empty `fitsBudget` check run before the first
relevant effect, and reconciled VM/kind-node/container/storage walls enforce that sole effective
quantity at runtime. WSL's CPU/memory wall is an exclusively owned shared utility-VM resource, not a
per-distro fiction. No render-time `Budget/fitsWithin` assertion is attached to generated config.

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

- Historical delivery under the now-removed flat command targeted the control plane after `kind create`
  and before Helm. The current replacement is the lifecycle operation inside the `deploy-kind`
  project-plan/`project up` path: it derives every node from `ClusterPlan` and runs
  `docker update --cpus --memory --memory-swap` for each (control plane plus nvkind worker where present),
  fail-closed.
  The historical landing used `--memory-swap == --memory`; the later Sprint 9.7 correction uses
  `--memory-swap == 2 × --memory` to provide swap headroom while preserving the RAM ceiling.
- The cordon application is fail-closed.

#### Validation

- Tests assert the cordon argv targets every resolved plan node with split budget-derived caps.

#### Remaining Work

None.

### Sprint 9.3: `verifyBudget` wiring and `fitsBudget` helper [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`, `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`, `core/hostbootstrap-core/test/CordonSpec.hs`
**Docs to update**: `documents/engineering/applied_cordon.md`

#### Objective

Land the capacity gate and the pure fits-within helper. The historical sprint title/closure text
overstated the latter's lifecycle wiring; Sprint 9.10 owns the missing plan-derived call.

#### Deliverables

- The pure `fitsBudget :: Vocab.Budget -> [Vocab.PodResources] -> Either Overflow ()` (the Haskell mirror
  of `Core.dhall`'s `fitsWithin`).
- `verifyBudget` invoked as a real fail-fast preflight (resolve substrate capacity, fail with a one-line
  diagnostic if short). `fitsBudget` remains an unwired helper; no current lifecycle operation supplies
  the generated/concurrent pod set.

#### Validation

- `CordonSpec` covers `fitsBudget` (under/over supplied fixtures) and the wired `verifyBudget` preflight
  without Docker. It does not prove a command invokes `fitsBudget` with the exact plan workload set.

#### Remaining Work

None for the historical capacity/helper landing. Sprint 9.10 owns the missing command wiring and
non-empty plan-indexed workload set.

### Sprint 9.4: Per-substrate storage cordon policy [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`, `core/hostbootstrap-core/test/CordonSpec.hs`, `core/hostbootstrap-core/test/IncusSpec.hs`
**Docs to update**: `documents/engineering/applied_cordon.md`, `documents/engineering/resource_budgeting.md`

#### Objective

Represent and enforce storage where a substrate provides a real mechanism, and return a typed unsupported
outcome where it does not.

#### Deliverables

- Colima `--disk` (Apple) and Incus `root,size` (Incus VM) are represented by their argument builders.
- Bare Linux has no implemented quota'd hostPath/image-GC mechanism yet; the policy must report that
  honestly until Phase 5 Sprint 5.7 interprets a real enforcement primitive.
- Storage is dropped from the `docker update` argv (there is no flag) but retained in `verifyBudget`.

#### Validation

- `CordonSpec` asserts Colima/Incus sizing, the absence of a Docker storage flag, and the typed bare-Linux
  unsupported result. The Phase 5 real run proves any later bare-Linux enforcement.

#### Remaining Work

Add the explicit bare-Linux unsupported policy/result. That honest typed result closes this sprint even
when no enforcement backend exists. Any later bare-Linux quota implementation and its real-run evidence
belong to Phase 5 Sprint 5.7 and do not retroactively block this policy sprint; the Incus interpreter
remains owned by Phase 11.

### Sprint 9.5: Substrate-aware capacity resolution [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`, `core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`, `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`, `core/hostbootstrap-core/test/CordonSpec.hs`, `core/hostbootstrap-core/test/HostToolSpec.hs`
**Docs to update**: `documents/engineering/resource_budgeting.md`, `documents/engineering/applied_cordon.md`, `system-components.md`

**Historical scope.** This sprint's storage fallback was superseded by Sprint 9.7. Current POSIX
capacity resolution reads real filesystem availability through `df`; the generous sentinel below is
retained only as the initial landing record.

#### Objective

Resolve the relevant host capacity per substrate so the bring-up preflight is a real gate on Apple
silicon and Linux. Apple reports total physical memory and applies the separate metal reserve; Linux
reports available memory.

#### Deliverables

- On `apple-silicon`, `resolveHostCapacity` reads `sysctl -n hw.ncpu` (logical cores) and
  `sysctl -n hw.memsize` (total physical RAM) through the resolved `HostTool Sysctl`.
- On `linux-cpu` / `linux-gpu`, the existing `/proc/cpuinfo` processor count and `/proc/meminfo`
  `MemAvailable` reads are retained.
- At this historical landing, storage remained reported generously. Sprint 9.7 removed that behavior and
  made the preflight read real free disk.
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

**Historical scope, superseded by Sprint 9.7.** The initial builder incorrectly treated a VHDX size as
part of `.wslconfig`. Current `wsl2SizingArgs` emits only the global utility-VM body; the selected WSL
install builder separately supplies `--vhd-size`. Provider outputs normalize quantities to effective
whole-GiB ceilings, so byte-for-byte preservation of the user's quantity text is not a contract.

#### Objective

Extend the one canonical quantity parser to **Windows**: resolve host capacity on
`windows-cpu` / `windows-gpu`, and land the initial WSL2 sizing-body attempt from the same
`parseQuantity`. Sprint 9.7 owns the corrected global-body/per-distro-storage split.

#### Deliverables

- `resolveHostCapacity` gains the **Windows branch** (the structural peer of the Apple `sysctl` and Linux
  `/proc` reads): it resolves the logical processor count and total physical RAM through a resolved host
  capacity probe (§ K), so the resolved-capacity preflight plus metal reserve is a real gate on Windows.
- The initial `wsl2SizingArgs :: Resources -> Either String [String]` used the one parser for
  `.wslconfig` memory/processors and an invalid `vhdx-size` line. Sprint 9.7 removed that line; current
  storage sizing is the separate per-distro `wsl --install --vhd-size` argument.
- The bare `"8Gi"` form is interpreted identically by `wsl2SizingArgs` as by every other builder (one
  grammar everywhere).

#### Validation

- The historical tests covered a bare `"8Gi"` fixture and the Windows capacity source. Current Sprint
  9.7 tests assert the corrected body and the separate VHDX install argument using normalized,
  ceiling-rounded effective quantities rather than byte-for-byte input text.

#### Remaining Work

None for the historical initial landing. Sprint 9.7 supersedes its invalid VHDX/body model. The live
Windows host-capacity read returned `Right (HostCapacity {spareCpu = 16, ...})` through the
PowerShell/CIM branch.

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

None. The applied shared utility-VM `.wslconfig` wall with a **live** WSL2 distro — the full
`project up` → `test run all` → `project destroy` Windows closure — was validated **2026-07-01**: the
run wrote the `.wslconfig` ceiling, registered the distro with its initial VHDX cap, brought up
in-distro Docker/kind without a utility-VM session drop, reported
**`test report: 6/6 passed`** across both message variants, and `project destroy` restored the host
`.wslconfig` (jointly with [phase-11-incus-host-provider.md](phase-11-incus-host-provider.md)
Sprint 11.7).

### Sprint 9.8: Initial readiness framework and selected step gating [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`, `core/hostbootstrap-core/src/HostBootstrap/Readiness/Internal.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/architecture/readiness.md`, `system-components.md`

#### Objective

Record the initial `HostBootstrap.Readiness` surface and gate the named in-guest bootstrap/share steps
through its retrying probe/witness mechanism. Universal, opaque, resource-instance-bound readiness is
follow-on work in Sprint 9.10.

#### Module Surface

- `HostBootstrap.Readiness` — the initial phantom `Ready tag` (hidden from the facade but forgeable
  through exposed `HostBootstrap.Readiness.Internal`, the defect reopened in Sprint 9.10),
  `awaitReady`/`awaitReadyWith`, `Probe`/`ProbeResult`
  (`ProbeReady | NotReady | Failed String`), `PollPolicy` + the named policies, `PollError`/`renderPollError`,
  and the pure `pollStep`. Added to the `system-components.md` module inventory (a pre-existing drift: the
  module shipped without an inventory row).

#### Deliverables

- The initial gating discipline as the basis for `documents/architecture/readiness.md`.
- The named previously-ungated mutating in-guest steps (the VM durable-share alias — phase-11 Sprint 11.9 —, the
  `runVmBootstrap` install/build steps, `stageSource`, `streamVMConfig`) brought under a `Ready` witness, and
  the trivial-guest-probe contract (no compound `set -eu`; no nested `"$(…)"`) enforced so a probe survives
  the Windows PowerShell→`wsl`→`bash` path.

#### Validation

- `cabal test` from `core/` — the existing `Readiness`/poll unit tests (`pollStep`/`drivePure`) plus the
  witness-threading types; omitting a required witness fails to compile. Because the public
  `MkReady` escape hatch can forge one, this historical validation does not prove semantic ordering.

#### Remaining Work

**Initial scope landed and static-validated (2026-07-22).** `HostBootstrap.Readiness` was documented and
[readiness](../documents/architecture/readiness.md) and recorded in
[system-components.md](system-components.md) (the pre-existing inventory drift closed). The previously
ungated in-guest mutating steps are now witness-gated: `stageSource` / `streamVMConfig` and the
`runVmBootstrap` install/build steps take a `Ready VMReady` argument (minted by `substrateWait` at the frame
start, threaded through the `guestStep` runner), and the VM durable-share alias is gated by
`Ready DurableShareMounted` (phase-11 Sprint 11.9). This makes an **omitted** witness a type error and
documents the intended call shape; because `MkReady` remains publicly forgeable and unbound to a resource
instance, it does not yet make out-of-order execution a type error. Sprint 9.10 owns that stronger claim.
The trivial-guest-probe contract is honoured (single simple commands: `test -L`/`readlink`/`test -e`,
`test -d && test -w` — no compound `set -eu`, no nested `"$(…)"`). Static gate green:
`cabal test all --ghc-options=-Werror` **core 382 + demo 98** (the demo runs the embedded core suite).
**Historical real-run evidence (§ C, 2026-07-23):** a live Windows/WSL2 `test run all` reported **`8/8 passed`** —
`pristine-bootstrap` (both variants) exercised the witness-gated staging/config-stream/install steps and the
in-guest bootstrap end to end. None remains in Sprint 9.8's narrowed initial scope; Sprint 9.10 owns
constructor opacity, generative resource identity, total outcomes, and universal lifecycle typing.

### Sprint 9.9: Type-level configuration validity [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`, `core/hostbootstrap-core/dhall/Core.dhall`, `demo/src/HostBootstrapDemo/Config.hs`
**Docs to update**: `documents/engineering/applied_cordon.md`, `documents/engineering/schema.md`, `documents/engineering/resource_budgeting.md`, `documents/architecture/dhall_generation.md`

#### Objective

Move selected scalar/resource failures from bring-up into `<project>.dhall`/`<project>.test.dhall`
decoding. The historical sprint did not make all invalid construction unrepresentable: constructors and
numeric/string instances remain public, and lifecycle consumes a separate raw context envelope. The
pod-set `fitsWithin` check remains a target bring-up check because generated config has neither a numeric
quantity representation nor a pod set to attach that assertion to.

#### Deliverables

- A transparent `Quantity` newtype whose `FromDhall` validates recognized syntax at decode. Its public
  constructor/`IsString` path and acceptance of bare-byte, zero, and below-provider-minimum values are
  retained defects.
- A validating `Resources` decoder for the top-level demo record. `Resources(..)` and numeric-wrapper
  constructors remain public, and `context.resourceEnvelope` bypasses this decoder.
- Decode-validating newtypes for `haReplicas` (demo: exactly `1`), service ports (1..65535), and timeout
  (1..30). Public constructors remain, and cross-field port distinctness still has a rejecting validation
  branch.
- The **decode ring realized as typed newtypes** (replacing the former proposed compile ring):
  `Core.dhall`'s
  `Budget/fitsWithin` operates on a `Natural` `Budget` and a `List PodResources`, but a generated
  `<project>.dhall` carries its `memory`/`storage` as Kubernetes **`Text`** quantities (which Dhall cannot
  numerically compare) and **no pod set** — so a Dhall-native `fitsWithin` assert has nothing to quantify
  over without embedding Haskell-computed `Natural`s and the demo's pod footprint into every rendered config
  (config bloat, redundant with the bring-up ring). The realized **decode-time** validity ring is therefore
  the typed decoders above: selected malformed fields reject at the Dhall boundary. The pod-set fit check
  is a **target bring-up ring** (`fitsBudget`), not current command wiring. `dhall/example.dhall`'s
  runtime-failing `haReplicas = 2` is corrected to `1` (and the core
  `SchemaSpec` fixture/`renderProjectConfig` sites with it). The superseded `Text`-quantity/unbounded-`Natural`
  surfaces are recorded in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

#### Validation

- `cabal test` — decode-time rejections (bad unit, below-floor cpu, `haReplicas ≠ 1`, out-of-range/zero
  ports, bad timeout) plus valid sub-records still decoding (`ConfigSpec` "invalid config fields are rejected
  at decode"), and `example.dhall` round-trips through the corrected fixture.

#### Remaining Work

**Code landed and static-validated (2026-07-22).** The demo's top-level config gained a
validating-`FromDhall` layer for selected failures: a typed `Quantity` (syntax-validated via the shared
`parseQuantity`), bounded `HaReplicas` (exactly `1`) / `Port` (1..65535) / `TimeoutSeconds` (1..30), and a
resource-floor `Resources` (cpu ≥ 1). All encode **transparently** (a newtype's `ToDhall` renders its
underlying `Text`/`Natural`), so the reflected schema and goldens are unchanged; `IsString`/`Num` keep
internal literals and `fromIntegral` working. `example.dhall`'s `haReplicas` is corrected to `1`. Static gate
green: `cabal test all --ghc-options=-Werror` **core 382 + demo 98** (9 new `ConfigSpec` decode-rejection
cases). This did not seal constructors, validate the separate applied envelope, enforce provider
minimums, or wire `fitsBudget`; Sprint 9.10 owns those repairs. **Real-run evidence (§ C, 2026-07-23):**
the live Windows/WSL2 `test run all`
reported **`8/8 passed`** — the generated configs (including the accelerator daemon config with the
decode-validating `Port`/`TimeoutSeconds` and `Quantity` fields) drove both variants. None remains in the
historical narrowed decode-fixture scope; Sprint 9.10 owns the public/applied-state gaps.

### Sprint 9.10: Opaque readiness and phase-indexed reconciliation types [Blocked]

**Status**: Blocked
**Blocked by**: Sprints 19.7–19.8
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Readiness/Internal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
`demo/src/HostBootstrapDemo/Config.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/architecture/readiness.md`,
`documents/architecture/lifecycle_state_model.md`,
`documents/engineering/applied_cordon.md`, `documents/engineering/resource_budgeting.md`,
`documents/architecture/hostbootstrap_core_library.md`, `legacy-tracking-for-deletion.md`

#### Objective

Make readiness/resource observation total, seal capability construction, and express legal lifecycle
ordering and one-budget enforcement in types shared by the cordon, provider, harness, and recursive
interpreter.

#### Deliverables

- Remove the exposed `HostBootstrap.Readiness.Internal` constructor; tests obtain witnesses only by
  driving injected probes through the real validating transition. Make `Probe resource dependency`
  opaque and plan/backend-produced: hiding `MkReady` is insufficient while a caller can supply an
  always-ready public probe and independently choose the returned tag.
- Make `PollPolicy` and its duration/attempt components opaque. Smart constructors require positive
  attempts and a non-negative bounded delay, compute the total duration with overflow-safe arithmetic,
  and reject zero, negative-equivalent, overflowed, and over-limit policies before polling.
- Replace the partial three-way probe result with a total typed result that distinguishes ready,
  transiently not ready, unavailable/not-applicable, structured conflict, and deterministic failure.
- Introduce lifecycle-scope-, ownership-, and phase-indexed generative state/capability tokens bound to
  the exact plan and resource instance:
  `ResourceHandle scope planId id resource ownership phase`,
  `Ready scope planId id resource dependency`, and `OwnershipReceipt scope planId id resource`. The `planId` is
  generative for each validated plan, so two Production projects/runs cannot exchange handles or
  journals. Provision, readiness, staging, build, run, stop, and destroy transitions accept only legal
  predecessor scope/plan/identity/ownership/phase states; Production and Harness values cannot mix even
  when stable names match.
- Replace the independently editable top-level `resources` and raw `context.resourceEnvelope` with one
  opaque `ValidatedBudget scope planId budgetId`. Decode/promotion uses exact positive bounded
  CPU/memory/storage representations with backend minimums; constructors, `Num`/`IsString` bypasses, raw
  lifecycle text, and floating conversion are not public effect inputs. Pure provider selection yields
  only `ProviderBudgetCapability scope planId provider capabilityId`. Exact admission consumes that
  capability and yields
  `ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId` jointly with
  `EffectiveBudget scope planId budgetId provider capabilityId wallSpecId` only when every dimension is
  exactly representable by that backend and byte-for-byte
  equal to the user-visible `ValidatedBudget`; a value that would require whole-GiB upward rounding is
  rejected before effects. These are pure planning values, not ownership or write authority. Capacity
  and workload checks consume that admitted value, never the pre-admission request.
- Derive `PlannedWorkloadSet scope planId workloadSetId`; `fitsBudget` consumes it with that exact
  effective budget and yields only
  `VerifiedWorkloadFit scope planId budgetId provider capabilityId wallSpecId workloadSetId`. Construct
  an opaque
  `BudgetPartition scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId`
  before issuing any provider-wall acquisition or mutation permit. It proves that every
  `ResourceSlice scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId frame
  resourceId` is positive, satisfies its provider/node minimum, and that all concurrent
  slices plus explicit provider/VM overhead are at most the admitted `EffectiveBudget`. The current
  `clusterSliceOfBudget` `max` floors are not evidence: a below-floor CPU/memory/storage input can produce
  a slice equal to or larger than its parent. No raw child envelope or independently recomputed floor may
  enter an argument builder.
- Derive a non-empty concurrent workload set and every budget-relevant effect from the finalized plan.
  `fitsBudget` consumes that exact set with the same `EffectiveBudget` and yields the fit proof; partition
  construction then consumes that proof. Only later mutations consume the proved partition/slices.
  Direct Linux GPU build and project-container effects, direct Colima, every kind/nvkind node, and storage
  either consume an enforceable slice from the same budget or return a typed `Unsupported` before work; a
  later node-only cap cannot authorize an uncapped outer effect.
- Reconcile an existing provider wall against the exact `EffectiveBudget`. Return a typed
  `Unchanged | Migrated receipt | Refused conflict` result; never silently start an old Lima/Incus VM,
  leave a WSL VHDX stale, or claim a rewritten `.wslconfig` applied while a running utility VM retained
  the old wall. After the partition exists, a journaled transition first mints
  `ProviderWallReservation scope planId provider wallSpecId reservationId fence`. The sole initial-wall
  adapter consumes that reservation with the same wall spec and partition, may create/apply or observe the
  wall, and returns
  `ProviderWallAuthority scope planId provider wallSpecId wallEpoch fence` only after authoritative
  applied/unchanged observation. The post-effect authority is never required to authorize the call that
  mints it. An uncertain reserve/acquire/apply result exposes only recovery/reprobe state, never mutation
  authority. Model the WSL utility-VM wall as one shared
  global resource protected by a platform-authoritative exclusive lease/CAS. Only its exact owner may change or restore
  `%UserProfile%\.wslconfig`; a foreign or incompatible concurrent declaration returns structured
  `Conflict` rather than overwriting the active wall. Its identity-bound receipt records
  original-present bytes or original-absent before writing, so crash/retry restores the true original
  state. For WSL, the `ProviderWallReservation ... reservationId fence` retains the platform-exclusive
  pre-call lock/CAS across the initial shared-wall call. Applied/unchanged observation consumes it and
  jointly returns `WslGlobalWallLease scope planId wallSpecId wallEpoch fence` inseparably with the live
  wall authority. Each later permit also consumes the
  same-`wallSpecId` partition/slice and revalidates the epoch/fence; the capability, wall spec, partition,
  or effective value alone grants no write. The distro's VHDX remains a separate per-distro
  resource/slice.
- Index every hidden probe as `Probe resource dependency`, so a caller cannot choose which readiness
  phantom a successful probe returns. Require named transitions or opaque plan-minted transition
  descriptors that bind the target identity to the exact dependency identity/type; remove any generic
  mutation signature that accepts an unrelated caller-selected `Ready`. Every share, alias, cluster, and
  workload creation accepts both a plan-minted target handle and the exact
  `PlannedEdge scope planId targetId target dependencyId dependencyResource dependency`; no existential child identity is
  invented by the reconciler. Plan-minted `PlannedResourceLocator`s eliminate to an opaque bundle that
  contains the handle and exact `ResourceAtFrame`; an edge eliminator accepts two already-open bundles
  and returns only their exact plan edge. Multiple edges to a shared dependency therefore retain one
  existential identity, while a stable-name lookup cannot be asserted equal later.
- Retain backend generation, resource phase, and observation version inside each opaque readiness value,
  but do not accept caller-retained witnesses at preparation. A plan-owned dependency-snapshot producer
  internally traverses the descriptor's exact zero/one/many edge set, looks up the matching managed
  resources, runs the plan-owned probes, and seals its fresh observations plus backend call digest into
  `OperationPreconditionSet`. The no-dependency branch is private. Atomically rerun/revalidate the
  complete set during operation prepare before issuing
  a permit; only success jointly returns matching `PreparedOperation` and fresh
  `PreparedPreconditions`. A stale replacement is `Conflict`; same-identity loss of readiness requires
  reprobe and has no effect path.
  When GPU-plugin readiness advances a cluster from `ApiReady` to `PluginReady`, return one opaque bundle
  that reprobes and carries both API and plugin evidence at `PluginReady`; an earlier API witness is not
  reusable after the phase transition.
- Remove every public backend-effect signature that accepts only `CommandAuthority`, a transition
  descriptor, or a handle. Each named reconcile/phase/teardown adapter must require the exact
  resource/generation/operation/precondition-set/call-digest/session/fence/attempt/journal-indexed
  `PreparedOperation` and `PreparedPreconditions` returned jointly inside the protected prepare
  continuation and the matching plan descriptor, operation binding, or operation-indexed teardown step;
  raw/retained readiness/prerequisite capabilities, either half of the pair, and a pair for another
  target are not effect authority. Every terminal observation must return `OperationAdvance` on success or typed
  failure, exposing its result only with the sole successor Open-project state/revision-permit pair.
- Introduce `Either ReconcileError ReconcileResult`, with successful
  `ManagedResult` carrying a `ResourceHandle … Managed …`, receipt, and
  `Changed (Created | Repaired | Adopted)` or `Unchanged`, versus `ForeignResult` carrying only a
  `ResourceHandle … Unmanaged …` and foreign observation. `ReconcileError = Conflict | SafetyRefusal |
  Unsupported | Failure`, each carrying structured details; `Failure` also carries
  `RecoveryDisposition`. Idempotence
  accepts only `ResourceHandle ... Unclassified Observed`, making `Unchanged` legal only through exact
  prior-commit evidence at the target phase. Use a separate `PhaseTransition`/`VerifiedAtPhase` algebra
  for non-release managed phase changes, so boot/stop cannot be mislabeled as create/repair/no-op.
  Idempotence preserves the managed handle and receipt when state is ours; the foreign handle cannot type-check at
  mutation or deletion. Explicit adoption requires both a verified foreign-origin bundle tying the
  unmanaged handle to its exact generation/observation version and matching opaque operation-key-indexed
  authority. Absence and unsupported enforcement remain explicit observation/error outcomes.
- Persist untrusted, generative-identity-free `PersistedJournalRecord` values. Protected-store
  verification yields
  `VerifiedJournalRecord scope planDigest frameKey resourceKey generation operation operationKey
  recordVersion phase`;
  matching plan/frame/resource/operation bindings yield the private local
  `JournalEntry scope planId frame id generation resource operation operationKey recordVersion phase`.
  Persist stable scope, plan digest, frame/resource keys, backend generation, operation, stable operation
  key, and monotonic record version before any mutating backend call—never `planId`, resource `id`, or a
  capability. Its legal branches are:
  reservation unknown → `ReservationAbsent` (same-generation reservation retry), `Reserved`,
  `ObservedManaged` (reserve-is-create), or terminal `ObservedForeign`; `Reserved` → effect unknown →
  `EffectAbsent` (same-generation effect retry), `ObservedManaged`, or terminal `ObservedForeign`; and
  only `ObservedManaged → Committed`. Cleanup is
  `Committed → TeardownOutcomeUnknown → Released`, with a same-identity observation returning explicitly
  to `Committed` for retry and replacement becoming terminal foreign state. Hidden phase-indexed
  transitions expose no absent/foreign-to-commit edge. Adoption uses a distinct operation key and graph:
  `AdoptionIntentRecorded → AdoptionOutcomeUnknown`, whose total observation is
  `AdoptionObservedManaged`, `AdoptionObservedAbsent`, or terminal
  `AdoptionObservedForeign`/policy refusal. Only
  `AdoptionObservedManaged → AdoptionCommitted` mints adopted ownership. Authoritative absence permits
  only an explicit **same-operation-key** retry after `OldPermitsFenced` proves a delayed transfer cannot
  land; without that proof it is `Unsupported`/operator resolution. Adoption cleanup is
  `AdoptionCommitted → AdoptionTeardownOutcomeUnknown → AdoptionReleased`; same identity may retry under
  the same key after fencing, while replacement is terminal foreign state. The ordinary foreign entry
  remains terminal. Rebinding an ownership receipt requires exact verified raw receipt bytes, all
  plan/frame/resource/operation bindings, and a `ReceiptCommitProof` for the matching ordinary or
  adoption commit. Record each unknown state before the authoritative
  reservation, mutation, or deletion; a crash must reprobe the same generation and stable operation key.
  Callers cannot blindly replay a non-idempotent create, commit an unverified result, or delete after
  identity changes. A later ephemeral recreation requires verified absence plus an exact-resource/
  operation `FreshGeneration ... planId frame frameKey resourceKey id ... oldOperation oldOperationKey
  oldGeneration newAcquireOperationKey newGeneration` from `Released` or `AdoptionReleased`; it proves
  the exact local identity/operation binding and old tombstone but grants only eligibility. Its sole
  consumer constructs a released-reacquisition origin, and
  `registerOperationIntent` must revalidate/consume its protected version while atomically writing the
  new generation and session membership. Initial acquisition instead requires the sole
  no-prior-generation proof. Unknown/foreign state has no rollover path, and
  re-adoption requires a new adoption transaction instead.
- Give repairs and non-release managed phase changes distinct operation-indexed journal graphs. Repair
  intent/effect-unknown reprobes exactly
  `RepairObservedOriginal | RepairObservedTarget | RepairObservedAbsent |
  RepairObservedUnexpected | RepairObservedForeign`; the original branch may retry only the same
  operation key after `OldPermitsFenced`, and only target observation can enter `RepairCommitted` and
  yield `RepairedEvidence`. Absent, unexpected third phase, and foreign replacement are terminal/
  operator-resolution branches. Boot/stop/destroy-reachability bind exact resource/from/to and use the
  analogous
  `PhaseObservedFrom | PhaseObservedTo | PhaseObservedAbsent | PhaseObservedUnexpected |
  PhaseObservedForeign` total observation; the from branch has the same fenced same-key retry rule, and
  only `PhaseObservedTo → PhaseCommitted` commits. Both families retain the prior ownership receipt and
  have no edge into acquisition, release, or fresh-generation rollover.
- Define strong filesystem ownership honestly: bare exclusive create/rename, content comparison, and
  compare-then-unlink do not exclude a same-privilege replacement. Only an OS-protected namespace plus a
  conditional identity-bound mutation/delete may mint a strong receipt; otherwise return `Unsupported`
  (a separately named cooperative mode remains non-authorizing).
- Keep all quantity/resource constructors total at the public boundary and prove invalid decoded values
  cannot reach argument builders.

#### Validation

- Compile-time/runtime negative fixtures prove callers cannot construct readiness/capability tokens,
  provide an always-ready probe, invoke transitions out of order, choose a probe's result dependency,
  call a backend effect without the exact target/operation/precondition-set/call-digest-indexed prepared
  pair and matching descriptor/binding/teardown step, pass retained `Ready`/prerequisite values after
  prepare, discard the sole successor journal pair on a typed failure, reuse a
  witness for a different
  resource instance/generation, mix Production and Harness handles, or mix two distinct Production
  plans' handles, transitions, journals, receipts, and plans. Compile-fail fixtures also prove every
  cross-resource mutation requires the exact plan-minted target/dependency edge. A positive compile
  fixture assembles the real provider → share → alias chain exclusively through `PlannedResource`
  eliminators without unsafe equality or existential escape. Another builds the full GPU plan/edge set
  and proves the internal `OperationDependencySnapshot` traversal includes and reprobes both API and
  plugin evidence at one `PluginReady` version; no caller-built prerequisite bundle exists.
  Prepare-time replacement and wrong edge/precondition-set/call digest/observation version yield no
  authorization; an adapter accepts only the jointly fresh prepared pair.
  Wrong frame,
  resource binding, operation, or operation key cannot rebind a verified journal record.
- Poll-policy tests reject zero attempts, negative-equivalent raw inputs, per-delay and total-duration
  overflow, and values above the bound; no public raw constructor or unvalidated attempt-count helper
  remains.
- Budget-admission tests reject every non-exact provider quantity instead of rounding it upward, and
  prove capacity/workload checks consume the same admitted `EffectiveBudget`.
  Partition properties prove positive slices, provider/node minima, and
  `sum concurrent slices + explicit overhead <= EffectiveBudget`; below-floor fixtures that make the
  current demo helper equal/exceed its parent cannot construct `BudgetPartition`. Compile-fail and
  transition tests prove `ProviderBudgetCapability`, `ProviderWallSpec`, `EffectiveBudget`, or a
  partition alone cannot call a builder; journaled wall acquisition starts only after the matching
  partition exists and yields the sole same-`wallSpecId` authority accepted with its slices. Wrong-spec,
  stale-epoch/fence, and unknown acquisition states yield no mutation permit.
- WSL backend race/fault tests prove one global-wall owner at a time, incompatible/foreign concurrent
  declarations return `Conflict` without changing `.wslconfig`, and crash recovery restores exact
  original-present bytes or original-absent state only through the matching receipt. The successful
  acquisition returns the live wall authority and `WslGlobalWallLease` inseparably; crash-before-ack
  recovery reprobes the exact wall spec and cannot acquire or mutate under a new same-shaped value.
- Property/unit tests exhaust every probe/reconcile constructor and resource boundary without partial
  pattern matches or exception-as-state.
- Process-kill/fault-injection tests at every acquisition/teardown journal boundary prove uncertain
  reservation/effects are reprobed under the persisted stable operation key, same-generation retries do
  not duplicate resources, absent/foreign observations cannot commit, replacement during teardown never
  authorizes deletion, and released cleanup is not repeated. The matrix includes adoption
  intent/unknown/observed-absent/observed-managed/observed-foreign/commit/teardown/release, the
  `OldPermitsFenced` requirement for same-key absence retry, and ordinary/adopted released-generation
  rollover. First acquire without no-history proof and reacquire without the exact token-origin-
  registration chain fail; stale/reused/wrong-resource tokens lose the registration compare-and-swap.
  An adopted resource can be safely destroyed and recreated without entering the ordinary create history
  by fiat.
- Kill injection on both sides of repair, boot, stop, and destroy-reachability calls proves recovery
  exhausts original/from, target/to, absent, unexpected-third-phase, and foreign observations for the
  exact generation/from/to under the same operation key. It proves only target/to commits, original/from
  retry requires `OldPermitsFenced`, terminal branches preserve the original receipt, and recovery never
  silently replays or crosses into release/acquisition.
- `cabal test all --ghc-options=-Werror` passes, followed by a provider lifecycle run exercising retry,
  conflict, and successful reconciliation.

#### Remaining Work

Blocked until Sprints 19.7–19.8 land the scoped codec and finalized plan/spec that mint these values.
Then define and migrate the lifecycle types, remove the exposed constructor/module, and update all
consumers in Phases 5, 10, 11, 15, and 16. The 2026-07-23 `8/8` result remains dated behavior evidence
but cannot close this new public-type-contract defect.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/readiness.md` - the initial Sprint 9.8 mechanism plus Sprint 9.10's opaque,
  resource-instance-bound witness, total probes, and ownership-/phase-indexed lifecycle contract.
- `documents/architecture/dhall_generation.md` - partial current scalar/resource decoding and the target
  plan-derived `fitsBudget` pod-set check; no generated `Budget/fitsWithin` assertion is claimed.

**Engineering docs to create/update:**
- `documents/engineering/applied_cordon.md` - current duplicate/raw inputs and partial walls versus the
  one-budget target; the three rings (decode / bring-up / runtime); exact provider-effective quantities;
  per-substrate storage; WSL2 global-file/VHDX recovery; and opaque validated resource construction.
- `documents/engineering/schema.md` - current partial scalar validation and the target in which
  field/provider validity is unrepresentable after decode (opaque `Quantity`, bounded
  `haReplicas`/ports/timeout, one resource-floor constructor; Sprints 9.9/9.10).
- `documents/engineering/resource_budgeting.md` - current partial/creation-time enforcement versus the
  budget-as-ceiling target, pointing applied detail at `applied_cordon.md`; complete plan effects,
  existing-wall reconciliation, and the Windows/WSL2 global-wall constraints.

**Cross-references to add:**
- `system-components.md` updates the `HostBootstrap.Cluster.Cordon` row (`fitsBudget` + applied cordon +
  one parser + substrate-aware `resolveHostCapacity` incl. the Windows branch + `wsl2SizingArgs`).
- `README.md` describes the budget-as-ceiling enforcement.
- `legacy-tracking-for-deletion.md` records the removed off-Linux capacity fallbacks.
