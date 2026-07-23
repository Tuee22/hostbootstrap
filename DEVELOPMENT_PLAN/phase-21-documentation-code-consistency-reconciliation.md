# Phase 21: Documentation/Code Consistency Reconciliation

**Status**: Authoritative source
**Supersedes**: `../REMEDIATION_PLAN.md`
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)

> **Purpose**: Record the repo-wide reconciliation that made code comments, governed docs, and phase
> narrative agree with the current five-command surface, generic project model, Dhall schema source of
> truth, and cluster teardown semantics.

## Phase Status

**Status**: Done

**Reopened 2026-07-19, CLOSED `Done` 2026-07-23.** The `.data` durability doctrine sweep (Sprint 21.3) plus
the 2026-07-21 readiness/legible-failure/type-level-config-validity reconciliation are complete: the grep
floor is clean (no `host \`.data\`` phrasing and no `.data`-adjacent `§ O` citation outside this ledger), the
new doctrine has canonical homes ([readiness](../documents/architecture/readiness.md), § CC/§ DD,
[durable_state](../documents/architecture/durable_state.md)), the `Budget/fitsWithin` compile-ring is
reconciled to the realized decode-ring/bring-up-ring shape, and `DocValidatorSpec` + the `-Werror` build pass.
The underlying code closed on a live Windows/WSL2 `test run all` **`8/8`** (2026-07-23, phases 9/10/11).

**Reopened 2026-07-19 — the `.data` durability doctrine.** This phase's charter is making code comments,
governed docs, and phase narrative agree with implemented behavior, and a false **mechanism** claim
survived its sweep: governed docs asserted that `.data` was host state, was bind-mounted while a cluster
ran, and survived `project destroy`. None of that is implemented. Sprint 21.2's sweep aligned the
*teardown* wording correctly but did not test the durability claim riding alongside it, so the phase's
closure was not earned in its own scope. Sprint 21.3 owns the reconciliation; the corrected doctrine is
[durable_state](../documents/architecture/durable_state.md).

The reconciliation is a forward-only documentation and small-code-correction phase. It removes the stale
standalone `ensure <tool>` command from the surfaced core tree, keeps the `ensure` reconcilers as library
primitives composed into `ensure-*` chain steps, standardizes the generic chain signature as
`chain :: cfg -> [Step]`, deletes the stale `Type.dhall` fixture, retains and guards `example.dhall`, and
aligns `project down` wording with the implemented kind behavior: provider VMs stop and kind clusters are
deleted, with teardown never enumerating the plan's data path for removal.

Sprints 21.1 and 21.2 remain `Done` — their deliverables (the five-verb surface, `chain :: cfg -> [Step]`,
the `Type.dhall` deletion, the guarded `example.dhall`) all hold independently. This reopening adds work;
it reverses none. The owning phase docs carry forward-pointers or current state wording, and obsolete
surfaces are recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Remaining Work

**CLOSED (Sprint 21.3, 2026-07-23).** The `.data` doctrine sweep across `README.md`, `documents/`, and
`DEVELOPMENT_PLAN/`, the `.data`-adjacent `§ O` → `§ Y` citation repoint, and the 2026-07-21
readiness/legible-failure/type-level-config-validity reconciliation are complete: `DocValidatorSpec` is green
through `cabal test`, the `-Werror` build passes, and the grep floor holds (no `host \`.data\`` phrasing and
no `.data`-adjacent `§ O` citation outside
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)). **None remaining.**

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

### Sprint 21.3: `.data` durability doctrine reconciliation [Done]

**Status**: Done
**Implementation**: `README.md`, `documents/`, `DEVELOPMENT_PLAN/`, `core/hostbootstrap-core/src/HostBootstrap/`, `demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/architecture/durable_state.md`, `documents/architecture/readiness.md`, `documents/architecture/harness_workflow.md`, `documents/engineering/cluster_lifecycle.md`, `documents/engineering/applied_cordon.md`, `documents/architecture/dhall_generation.md`, `documents/engineering/gitignore_guardrails.md`, `documents/operations/demo_runbook.md`, `README.md`

#### Objective

Make every governed statement about `.data` match implemented behavior, and give the contract one
canonical home so the four provider docs stop restating it and drifting apart independently. Extend the same
reconciliation (2026-07-21) to the readiness-gated-lifecycle, legible-failure, and type-level-config-validity
doctrine (§ CC, § DD): every governed statement matches implemented behavior, with the new doctrine given
canonical homes.

#### Deliverables

- `documents/architecture/durable_state.md` is the canonical home; provider and lifecycle docs defer to
  it rather than restating the contract.
- No governed document claims `.data` is host state, is bind-mounted, or survives `project destroy` of a
  provisioned frame. The strongest offender was the assertion that `.data` "is bind-mounted while a
  cluster is running" — a mechanism claim with no implementation anywhere in the tree.
- The **true** property is stated precisely and kept: cluster teardown never enumerates the plan's data
  path for removal, and leaves an existing directory untouched.
- Wording is scoped to lifted/provisioned frames, so the direct-host `nvkind` lane — where `.data` really
  is a host path that outlives `destroy` — is not contradicted.
- `.data`-adjacent `§ O` citations repoint to `§ Y`; the ~20 budget/cordoning `§ O` citations are left
  alone.
- Haddock and the two `progDesc` strings that shipped the old host-durability phrasing in the binary's
  own `--help` are corrected.
- **(2026-07-21 extension)** The readiness/legible-failure doctrine has a canonical home
  (`documents/architecture/readiness.md`, standards § CC) and the durable-share primitive is de-staled in
  `durable_state.md` (standards § DD); provider, harness, cordon, and Dhall-generation docs defer to them.
- No governed document claims a bring-up failure is legible, the `Budget/fitsWithin` assert is attached at
  render, or the durable alias/primitive is delivered — each is corrected to its honest reopened state. The
  `ExitFailure 1` collapse, the never-attached § O `fitsWithin`, and the ad-hoc `set -eu` alias are recorded
  in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

#### Validation

- `DocValidatorSpec` through `cabal test` — metadata blocks, link resolution, the `architecture/` TL;DR
  requirement, naming, and taxonomy for the new page.
- A grep floor: no `host \`.data\`` phrasing and no `.data`-adjacent `§ O` citation outside
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
- `cabal build all --ghc-options=-Werror` from `core/` for the comment/`progDesc` edits.

#### Remaining Work

None (closed 2026-07-23). The doctrine sweep, the `§ O` compile-ring reconciliation, and the readiness /
legible-failure / config-validity homes are in place; `DocValidatorSpec` and the `-Werror` build pass, and
the grep floor holds.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` - fixed command surface and generic entrypoint.
- `documents/architecture/composition_methodology.md` - current teardown semantics and generic chain.
- `documents/architecture/durable_state.md` - **(new)** the canonical home of the never-delete-`.data`
  invariant: the removal-set guarantee, frame-relativity, one-way host→guest transfer, and the open work
  to make host-durable state real.

**Engineering docs to create/update:**
- `documents/engineering/ensure_reconcilers.md` - library/chain-step reconciler contract.
- `documents/engineering/cluster_lifecycle.md` - kind delete-on-down; teardown never enumerates the data
  path for removal, deferring to `durable_state.md` for the scope of that guarantee.
- `documents/engineering/gitignore_guardrails.md` - why `.data/` is ignored, without the bind-mount claim.
- `documents/engineering/schema.md` - live command-class vocabulary.

**Cross-references to add:**
- Add this phase to `DEVELOPMENT_PLAN/README.md`, `00-overview.md`,
  `development_plan_standards.md`, and `system-components.md`.
