# Phase 9: Applied Budget Cordon and One Canonical Parser

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-5-cluster-lifecycle-and-resource-cordoning.md](phase-5-cluster-lifecycle-and-resource-cordoning.md), [phase-8-dhall-generation-and-extension.md](phase-8-dhall-generation-and-extension.md)

> **Purpose**: Make the declared resource budget a genuinely enforced ceiling — wire the applied Linux
> kind-node cordon, run the spare-capacity and fits-within checks before bring-up, and collapse the dual
> budget interpreters into one canonical quantity parser shared across Python and Haskell.

## Phase Status

**Status**: Blocked

**Blocked by**: phase-5 (the lifecycle and the pure cordon cores), phase-8 (`Budget/fitsWithin`,
`Budget/split`)

Phase 5 leaves the cordon **computed and reported but not applied** (`kindNodeLimits` is printed by
`reportCordon`, never run) and `verifyBudget` unwired. Two budget interpreters disagree (Haskell
`colimaSizingArgs` vs Python `_gib`/`colima_start_command`; the Python path mishandles `"8Gi"`). This
phase wires real enforcement and unifies the parser, so the one budget number is a hard ceiling at every
spinup and in every generated config (see
[development_plan_standards.md § O](development_plan_standards.md)).

## Phase Objective

Turn the budget into an enforced ceiling with defense in depth: the Dhall `assert` at render time, the
pure `verifyBudget`/`fitsBudget` before bring-up, and the applied VM / kind-node / run caps at runtime —
all fed by a single canonical quantity parser and argument builder.

## Sprints

### Sprint 9.1: One canonical quantity parser and argument builder [Blocked]

**Status**: Blocked
**Blocked by**: phase-5
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`, `python/hostbootstrap/bootstrap.py` (planned)
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

- A golden test asserts the Haskell-emitted argv equals what the Python layer would build, byte-for-byte,
  including a `"8Gi"` fixture (which the old Python `_gib` mishandled). Python `test_all` covers it.

#### Remaining Work

None.

### Sprint 9.2: Applied Linux kind-node cordon [Blocked]

**Status**: Blocked
**Blocked by**: phase-9 (sprint 9.1)
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`, `haskell/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs` (planned)
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

### Sprint 9.3: `verifyBudget` and `fitsBudget` wired before bring-up [Blocked]

**Status**: Blocked
**Blocked by**: phase-8 (sprint 8.1), phase-9 (sprint 9.2)
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs` (planned)
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

### Sprint 9.4: Per-substrate storage cordon [Blocked]

**Status**: Blocked
**Blocked by**: phase-9 (sprint 9.2)
**Implementation**: `haskell/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs` (planned)
**Docs to update**: `documents/engineering/applied_cordon.md`, `documents/engineering/resource_budgeting.md`

#### Objective

Enforce the storage dimension where each substrate allows it.

#### Deliverables

- Storage is cordoned by Colima `--disk` (Apple), incus `root,size` (incus VM), or a quota'd hostPath +
  image GC (bare Linux). Storage is dropped from the `docker update` argv (no flag) but kept in
  `verifyBudget`.

#### Validation

- The sizing args for each substrate reflect the declared storage; the `docker update` argv omits storage.

#### Remaining Work

None.

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
