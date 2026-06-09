# Phase 9: Applied Budget Cordon and One Canonical Parser

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-5-cluster-lifecycle-and-resource-cordoning.md](phase-5-cluster-lifecycle-and-resource-cordoning.md), [phase-8-dhall-generation-and-extension.md](phase-8-dhall-generation-and-extension.md)

> **Purpose**: Make the declared resource budget a genuinely enforced ceiling — wire the applied Linux
> kind-node cordon, run the spare-capacity and fits-within checks before bring-up, and collapse the dual
> budget interpreters into one canonical quantity parser shared across Python and Haskell.

## Phase Status

**Status**: Done

The budget is now an **enforced** ceiling. The one canonical `parseQuantity` feeds every argument
builder (`colimaSizingArgs` emits the full profiled `colima start` argv; `kindNodeCordonArgs` emits the
`docker update` cap; `incusSizingArgs` emits the VM `limits.cpu`/`limits.memory`/`root,size`), so the
bare `"8Gi"` form is interpreted identically everywhere (the removed Python `_gib` mishandled it).
`clusterUp` runs the `verifyBudget` spare-capacity preflight, then applies the Linux kind-node cordon
(`docker update --cpus/--memory/--memory-swap <cluster>-control-plane`) after `kind create` and before
Helm, fail-closed; the print-only `reportCordon` is gone. The pure `fitsBudget` proves a concurrent pod
set fits, and storage is cordoned per substrate (Colima `--disk`, incus `root,size`) while omitted from
the `docker update` argv. All argv builders and the wiring are implemented and unit-tested (live
`docker`/`incus` execution is exercised in real runs) (see
[development_plan_standards.md § O](development_plan_standards.md)).

## Phase Objective

Turn the budget into an enforced ceiling with defense in depth: the Dhall `assert` at render time, the
pure `verifyBudget`/`fitsBudget` before bring-up, and the applied VM / kind-node / run caps at runtime —
all fed by a single canonical quantity parser and argument builder.

## Sprints

### Sprint 9.1: One canonical quantity parser and argument builder [Done]

**Status**: Done
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`, `haskell/hostbootstrap-core/test/CordonSpec.hs`
**Docs to update**: `documents/engineering/applied_cordon.md`, `documents/engineering/resource_budgeting.md`

#### Objective

Replace the two divergent budget interpreters with one grammar; the Python layer builds host VM argv only
from the Haskell-emitted output.

#### Deliverables

- A single quantity parser/arg-builder in `Cluster.Cordon` emitting the complete `colima`/`incus` argv
  (including the `--profile` / `limits` the Python copy currently owns).
- The Python bootstrapper consumes that argv verbatim; the duplicate Python budget logic (`_gib`) is
  removed.

#### Validation

- `CordonSpec` asserts the full profiled `colima start` argv and the `docker update` cordon argv from
  the one `parseQuantity`, including a `"8Gi"` fixture (which the removed Python `_gib` mishandled).
  `cabal test` passes. The Python layer no longer builds any sizing argv (removed in phase-6,
  Sprint 6.3), so there is no Python interpreter to dedup against.

#### Remaining Work

None.

### Sprint 9.2: Applied Linux kind-node cordon [Done]

**Status**: Done
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`, `haskell/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`, `haskell/hostbootstrap-core/test/CordonSpec.hs`
**Docs to update**: `documents/engineering/applied_cordon.md`, `documents/engineering/cluster_lifecycle.md`

#### Objective

Actually apply the cordon on Linux instead of printing it.

#### Deliverables

- `cluster up` runs `docker update --cpus --memory --memory-swap <clusterName>-control-plane` after
  `kind create` and before Helm, fail-closed; `<clusterName>` is the resolved `ClusterPlan` name, so each
  per-case test cluster is cordoned. `--memory-swap == --memory` so an over-budget cluster self-limits.
- The print-only `reportCordon` path in `Command.hs` is removed.

#### Validation

- A test asserts the cordon argv targets the resolved control-plane container with budget-derived caps.

#### Remaining Work

None.

### Sprint 9.3: `verifyBudget` and `fitsBudget` wired before bring-up [Done]

**Status**: Done
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`, `haskell/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`, `haskell/hostbootstrap-core/test/CordonSpec.hs`
**Docs to update**: `documents/engineering/applied_cordon.md`

#### Objective

Run the spare-capacity gate and the fits-within proof before any spinup.

#### Deliverables

- The pure `fitsBudget :: ResourceBudget -> [PodResources] -> Either Overflow ()`.
- `verifyBudget` invoked as a real fail-fast preflight (resolve host spare capacity, fail with a one-line
  diagnostic if short); `fitsBudget` proves the generated/concurrent pods fit before bring-up.

#### Validation

- `CordonSpec` covers `fitsBudget` (under/over budget) and the wired `verifyBudget` preflight without
  Docker. `cabal test` passes.

#### Remaining Work

None.

### Sprint 9.4: Per-substrate storage cordon [Done]

**Status**: Done
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`, `haskell/hostbootstrap-core/test/CordonSpec.hs`, `haskell/hostbootstrap-core/test/IncusSpec.hs`
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
incus cordons storage at the VM wall) landed with
[phase-11-incus-host-provider.md](phase-11-incus-host-provider.md) (Sprint 11.4). The bare-Linux quota'd
hostPath + image GC is a deployment convention documented in
[applied_cordon](../documents/engineering/applied_cordon.md), not a `hostbootstrap-core` arg-builder.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/applied_cordon.md` - the one ceiling, the three rings (compile / bring-up /
  runtime), the single canonical parser, and the per-substrate storage cordon.
- `documents/engineering/resource_budgeting.md` - rewritten to budget-as-ceiling, pointing applied detail
  at `applied_cordon.md`.

**Cross-references to add:**
- `system-components.md` updates the `HostBootstrap.Cluster.Cordon` row (`fitsBudget` + applied cordon +
  one parser).
- `README.md` describes the budget-as-ceiling enforcement.
