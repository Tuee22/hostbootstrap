# Phase 21: Documentation/Code Consistency Reconciliation

**Status**: Authoritative source
**Supersedes**: `../REMEDIATION_PLAN.md`
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)

> **Purpose**: Record the repo-wide reconciliation that made code comments, governed docs, and phase
> narrative agree with the current five-command surface, generic project model, Dhall schema source of
> truth, and cluster teardown semantics.

## Phase Status

**Status**: Done

The reconciliation is a forward-only documentation and small-code-correction phase. It removes the stale
standalone `ensure <tool>` command from the surfaced core tree, keeps the `ensure` reconcilers as library
primitives composed into `ensure-*` chain steps, standardizes the generic chain signature as
`chain :: cfg -> [Step]`, deletes the stale `Type.dhall` fixture, retains and guards `example.dhall`, and
aligns `project down` wording with the implemented kind behavior: provider VMs stop, kind clusters are
deleted, and durable host state is preserved.

No earlier phase is reopened by this record. The owning phase docs now carry forward-pointers or current
state wording, and obsolete surfaces are recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Sprints

### Sprint 21.1: Code and artifact reconciliation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`, `core/hostbootstrap-core/dhall/example.dhall`, `hostbootstrap/cli.py`, `demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`, `documents/engineering/ensure_reconcilers.md`, `documents/engineering/cluster_lifecycle.md`, `system-components.md`

#### Objective

Make the implementation match the current documented contract before rewriting the governed docs.

#### Deliverables

- The core command surface is exactly `project`, `test`, `service`, `context`, and `check-code`; there are
  no hidden commands.
- `ensure` remains a reconciler library (`Reconciler`, `runEnsure`, `runReconciler`, `ensure-*` steps).
- `Type.dhall` is deleted; `example.dhall` is retained as a guarded fixture.
- The Python `update --spec/--ref` guard detects an explicit `--ref`, even when it equals the default.
- The demo chart path renders Dhall text values through the Dhall encoder and passes live replica values
  explicitly.

#### Validation

- `cabal test` from `core/`.
- `poetry run python -m hostbootstrap.check_code`.
- `poetry run python -m hostbootstrap.test_all`.

#### Remaining Work

None.

### Sprint 21.2: Governed documentation sweep [Done]

**Status**: Done
**Implementation**: `README.md`, `documents/`, `DEVELOPMENT_PLAN/`, `AGENTS.md`
**Docs to update**: `documents/documentation_standards.md`, `documents/README.md`, `DEVELOPMENT_PLAN/README.md`

#### Objective

Remove repo-wide drift left by the service command and generic-project-model refactors without creating a
parallel canonical home.

#### Deliverables

- All generic chain-signature prose uses `chain :: cfg -> [Step]`; demo-only prose uses
  `demoChain :: ProjectConfig -> [Step]`.
- Command-surface prose uses the five user-facing verbs and says `ensure` is a library, not a command.
- Cluster lifecycle prose distinguishes provider-VM stop from kind-cluster delete-on-down.
- The legacy ledger lists deleted surfaces accurately and retains current fixtures accurately.
- `AGENTS.md` and `CLAUDE.md` carry the same git-history rule.

#### Validation

- `DocValidatorSpec` through `cabal test`.
- Manual consistency grep for the old command surface and type signatures.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` - fixed command surface and generic entrypoint.
- `documents/architecture/composition_methodology.md` - current teardown semantics and generic chain.

**Engineering docs to create/update:**
- `documents/engineering/ensure_reconcilers.md` - library/chain-step reconciler contract.
- `documents/engineering/cluster_lifecycle.md` - kind delete-on-down with durable-state preservation.
- `documents/engineering/schema.md` - live command-class vocabulary.

**Cross-references to add:**
- Add this phase to `DEVELOPMENT_PLAN/README.md`, `00-overview.md`,
  `development_plan_standards.md`, and `system-components.md`.
