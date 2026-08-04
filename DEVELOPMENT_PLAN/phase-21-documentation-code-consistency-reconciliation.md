# Phase 21: Documentation/code consistency reconciliation

**Status**: Authoritative source
**Supersedes**: `../REMEDIATION_PLAN.md`
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)

> **Purpose**: Record the completed historical reconciliation sprints and own the final governed sweep
> that will make code comments, governed docs, and phase narrative agree after the currently reopened
> implementation defects close.

## Phase Status

**Status**: Blocked
**Blocked by**: Sprints 2.7, 10.9, 11.10, 13.17–13.18, 14.6, 15.8–15.9, 16.5–16.6, 17.4,
18.5–18.6, and 20.5
**Satisfied prerequisites**: Sprints 5.5–5.8, 9.10, 13.20, and 19.7–19.8

**Reopened 2026-07-24.** Sprint 21.4 owns the new repo-wide reconciliation after the confirmed code/docs
defects close in their implementation phases. The 2026-07-23 closure below is retained only as historical
evidence for Sprint 21.3.

**Reopened 2026-07-19, CLOSED `Done` 2026-07-23.** The `.data` durability doctrine sweep (Sprint 21.3) plus
the 2026-07-21 readiness/legible-failure/type-level-config-validity reconciliation are complete: the grep
floor is clean (no `host \`.data\`` phrasing and no `.data`-adjacent `§ O` citation outside this ledger), the
new doctrine has canonical homes ([readiness](../documents/architecture/readiness.md), § CC/§ DD,
[durable_state](../documents/architecture/durable_state.md)), the `Budget/fitsWithin` compile-ring is
reconciled to the realized decode-ring/bring-up-ring shape, and `DocValidatorSpec` + the `-Werror` build pass.
The underlying code closed on a live Windows/WSL2 `test run all` **`8/8`** (2026-07-23, phases 9/10/11).

**Historical 2026-07-19 reopening — the then-current `.data` doctrine.** At that point, governed docs
asserted host-state/bind-mount durability that had not been implemented, so Sprint 21.3 narrowed the
contract to the removal-set guarantee. Subsequent Phase 5.6 and Phase 11.8/11.9 work implemented a host
project-root share/guest alias and carried it through container, Kind, and pod. Current prose must state
that mechanism while keeping the write→destroy→up→read-back proof and exclusive ownership open; the
canonical contract is [durable_state](../documents/architecture/durable_state.md).

The reconciliation is a forward-only documentation and small-code-correction phase. It removes the stale
standalone `ensure <tool>` command from the surfaced core tree, keeps the `ensure` reconcilers as library
primitives composed into `ensure-*` plan steps, historically standardized the generic chain signature,
and now records Sprint 19.8's opaque validated `StepPlan`; it deletes the stale `Type.dhall` fixture,
retains and guards `example.dhall`, and
aligns `project down` wording with the implemented kind behavior: provider VMs stop and kind clusters are
deleted, with teardown never enumerating the plan's data path for removal.

Sprints 21.1 and 21.2 remain `Done` — their deliverables (the five-verb surface, the then-current
single-chain model later strengthened to `StepPlan`, the `Type.dhall` deletion, and the guarded
`example.dhall`) all hold independently. This reopening adds work;
it reverses none. The owning phase docs carry forward-pointers or current state wording, and obsolete
surfaces are recorded in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

## Remaining Work

**Current:** Sprint 21.4 is Blocked on the named owning implementation phases. After they land, it must
reconcile the governed docs, source comments/help, status authority, and mechanical drift checks.

**Not this phase's work: the 2026-07-27 ownership-invariant restatement.** § EE's ownership rule was
replaced with the four Locked-Origin Identity Ownership clauses, and the governed suite, root `README.md`,
and phase documents were restated in the same change by the phases that own those surfaces — Phase 9
(reopened, Sprint 9.11), Phases 5, 10, and 11. That is deliberate: a doctrine restatement is made by its
owner, not deferred to a later reconciliation sweep, or the docs describe a rule the code was never
written against. Sprint 21.4's obligation is to **verify** the result — that no surviving text states the
superseded platform-primitive rule, that phase-local statuses match the
[README table](README.md#current-phase-status), and that source comments citing § EE agree with
[ownership_invariant](../documents/architecture/ownership_invariant.md) — not to perform the restatement.

**Historical closure (Sprint 21.3, 2026-07-23).** The `.data` doctrine sweep across `README.md`, `documents/`, and
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

- All current generic forward-plan prose uses opaque validated `StepPlan`; the demo's
  `demoChainFor :: Substrate -> ProjectConfig scope -> [Step]` appears only as the pure fragment passed
  through `addSteps` and finalization. Former raw-chain APIs appear only in explicitly historical
  migration prose.
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

Make every governed statement about `.data` match the behavior implemented at the sprint's 2026-07-23
closure, and give the contract one canonical home so provider docs stop restating it and drifting apart.
Extend the same
reconciliation (2026-07-21) to the readiness-gated-lifecycle, legible-failure, and type-level-config-validity
doctrine (§ CC, § DD): every governed statement matches implemented behavior, with the new doctrine given
canonical homes.

#### Deliverables

- `documents/architecture/durable_state.md` is the canonical home; provider and lifecycle docs defer to
  it rather than restating the contract.
- Historical closure baseline: no governed document claimed a host share that did not yet exist; the
  guaranteed property was that cluster teardown never enumerated the plan's data path for removal.
- Current follow-on contract: the demo creates `.data` at the host project root and carries it through
  the provider share/guest alias, project-container mount, Kind node, and pod. Documents may claim that
  implemented transport, but not the still-unrun destroy/up readback proof or exclusive ownership.
- `.data`-adjacent `§ O` citations repoint to `§ Y`; the ~20 budget/cordoning `§ O` citations are left
  alone.
- Historical intent required correcting Haddock and the two `progDesc` strings that shipped the old
  host-durability phrasing. The current source still says `down` removes no filesystem path, `.data`
  lives inside a frame that destroy deletes, and destroy removes “everything” provisioned; those exact
  source/help defects are now open under Sprint 21.4 rather than reported as complete.
- **(2026-07-21 extension)** The readiness/legible-failure doctrine gained a canonical home
  (`documents/architecture/readiness.md`, standards § CC), while `durable_state.md` remained the durability
  authority (standards § DD).
- Historical claims about legible failure, an attached render-time `Budget/fitsWithin` assertion, and the
  then-undelivered alias were corrected. Later landed alias/share transport must now be documented as
  implemented, and the later Phase 5 Sprint 5.6 readback evidence must be described as closed without
  conflating it with Sprint 10.9's still-open exclusive ownership work. The old `ExitFailure 1`,
  never-attached assert, and ad-hoc alias are recorded in
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

#### Validation

- `DocValidatorSpec` through `cabal test` — metadata blocks, link resolution, the `architecture/` TL;DR
  requirement, naming, and taxonomy for the new page.
- Historical 2026-07-23 grep floor: no then-false `host \`.data\`` phrasing and no `.data`-adjacent `§ O` citation outside
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).
- `cabal build all --ghc-options=-Werror` from `core/` for the comment/`progDesc` edits.

#### Remaining Work

None in the 2026-07-23 sprint scope. Its doctrine sweep, decode-ring reconciliation, and readiness /
legible-failure / config-validity homes landed. Sprint 21.4 owns the later sweep that must describe the
now-implemented host-share/carry mechanism without claiming the still-open readback proof.

### Sprint 21.4: Current code/documentation reconciliation [Blocked]

**Status**: Blocked
**Blocked by**: Sprints 2.7, 10.9, 11.10, 13.17–13.18, 14.6, 15.8–15.9, 16.5–16.6, 17.4,
18.5–18.6, and 20.5
**Satisfied prerequisites**: Sprints 5.5–5.8, 9.10, 13.20, and 19.7–19.8
**Implementation**: governed documentation, source comments/help text, mechanical documentation checks
**Docs to update**: `README.md`, `AGENTS.md`, `documents/`, `DEVELOPMENT_PLAN/`

#### Objective

Reconcile every governed current-state claim after the implementation sprints above, without editing
documentation ahead of the code or preserving duplicate status/count authorities.

#### Deliverables

- Sweep the HostTool, provider/lift, readiness/capability, lifecycle, harness, test-config, base-release,
  warm-store, and demo contracts after their owning phases land.
- Reconcile source comments and user-visible help that still assert superseded guarantees, including
  `Command.hs` test-selector/root-gate and down/destroy/durability text,
  `Readiness.Internal`/`Readiness` constructor-sealing text, `Harness` production-isolation/path text,
  `HostPrereqs` temporary-Python text, the demo's
  mutually-exclusive-run claim, Python's cross-platform handoff description, and CLI Poetry-only
  exposure text. Include `Cluster.Cordon`'s Incus-only Linux/storage/reserve/capacity claims,
  `Web.Api`'s unwired/static `fitsBudget` claim, and `HostBootstrapDemo.Config`'s false single-default-
  source heading. Reconcile `Config.Schema`'s unconditional `project init` missing-config hint,
  `Command`'s decoder-reflection wording and conflation of the project-config schema with the static
  in-scope artifact union, and the remaining raw service-handler `IO` contract after Sprint 18.6 lands;
  Sprint 19.8 has already removed the demo Web/accelerator sibling-config reload.
- Remove stale freeze-only `LABEL`/`ENTRYPOINT`, public/internal witness, definition-only provider,
  hard-coded variant, bare-host-command, appended-verb, Harbor, and obsolete MinIO/metadata claims.
- Keep `DEVELOPMENT_PLAN/README.md` as the only cross-phase status table and keep exact test counts only as
  dated sprint validation evidence.
- Add mechanical drift checks for forbidden obsolete surfaces and for the required rolling
  publish → pull → real-consumer compatibility-smoke sequence.
- Add the § HH drift guards: a sealed boundary stays sealed only if something checks it. Prove that no
  production module outside the sealed launch boundary names a closed stdio disposition (Sprint 2.7's
  surface), and that every boundary claiming a shape is unrepresentable has a registered compile-fail
  fixture. § HH's own limits say the type system does not maintain this — it is a drift obligation, and
  it is this sprint's.

#### Validation

- `DocValidatorSpec` and link/metadata validation pass across all governed Markdown.
- Targeted grep floors find no obsolete current-state phrases outside
  `legacy-tracking-for-deletion.md`, including `SUITE`/“test suite” selector help, “remove no filesystem
  path,” frame-local `.data`, test-only `Readiness.Internal`, mechanically guaranteed
  never-touch-production, and stale execution-selector claims.
- The README phase table and every phase-local status agree, with no second current-count/status roll-up
  in `00-overview.md` or `system-components.md`.

#### Remaining Work

Blocked on the named owning implementation sprints. After they close, perform the governed current-state
sweep and close the mechanical drift gates. The earlier Sprint 21.1–21.3 reconciliation is historical and
cannot establish consistency for defects discovered afterward.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` - fixed command surface and generic entrypoint.
- `documents/architecture/composition_methodology.md` - current teardown semantics and generic chain.
- `documents/architecture/durable_state.md` - **(new)** the canonical home of the never-delete-`.data`
  invariant: the removal-set guarantee, the implemented host-root/provider-share/container/Kind/pod carry,
  and the open write→destroy→up→read-back and ownership work.

**Engineering docs to create/update:**
- `documents/engineering/ensure_reconcilers.md` - library/chain-step reconciler contract.
- `documents/engineering/cluster_lifecycle.md` - kind delete-on-down; teardown never enumerates the data
  path for removal, deferring to `durable_state.md` for the scope of that guarantee.
- `documents/engineering/gitignore_guardrails.md` - why `.data/` is ignored, without the bind-mount claim.
- `documents/engineering/schema.md` - live command-class vocabulary.

**Cross-references to add:**
- Add this phase to `DEVELOPMENT_PLAN/README.md`, `00-overview.md`,
  `development_plan_standards.md`, and `system-components.md`.
