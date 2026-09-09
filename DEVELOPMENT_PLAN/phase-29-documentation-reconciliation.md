# Phase 29 — Documentation reconciliation and drift guards

**Status**: Done
**Depends on**: Phase 28 (host-portability acceptance)
**Substrates**: none (static)
**Gate**: `DocValidatorSpec` inside `cabal test all --ghc-options=-Werror` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-06 ; arm64 macOS 26.6.2 (build 25G83), GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --ghc-options=-Werror` ; pass ; covers in-gate

> **Purpose**: After the narrative is fully built, reconcile the governed `documents/` suite, comments, and help
> text with what the code actually does — and install the guards that keep them reconciled.

## Phase Objective

The governed documents describe supported behaviour, and § J requires them to agree with the plan. While phases
are still open they legitimately describe contracts that are not yet fully wired. This phase is the sweep that
closes that gap once, and then makes it mechanically hard to reopen.

It is last because it is the only phase whose subject is every other phase. It adds nothing to the build.

## Sprints

### Sprint 29.1: Reconcile the governed documents [Done]

**Status**: Done
**Implementation**: `documents/**`
**Substrates**: none
**Docs to update**: every governed document

#### Objective

Make each governed document describe what the code does.

#### Deliverables

- Every architecture document's contracts match the implemented surfaces, with no target-only statement left
  presented as current behaviour.
- Every engineering document's commands and paths are the real ones.
- Each document's `**Referenced by**` list is accurate, and each family's canonical home is the one
  `documents/README.md` names.
- Every `documents/` reference to a phase is **by name and link** (§ J). A bare number in prose is an
  execution position that a renumbering falsifies, and a bare *sprint* number falsifies faster still —
  a citation naming a sprint the owning phase no longer declares points at nothing at all.
- Duration and capacity figures are the observed ones, and any figure another document *derives* from them is
  recomputed rather than left resting on a stale input.
- [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md) is empty, because every shape it named
  has been deleted by the phase that owned it. An empty ledger is this phase's closing condition for that
  document, not a document to keep populated.
- Every ledger row that still exists names a deleting phase that resolves, which `DocValidatorSpec`
  enforces mechanically — an unowned row is how a ledger rots into the repair log § I forbids.

#### Validation

`DocValidatorSpec` plus a read-through of each family against its implementation. The validator checks the
ledger's rows resolve; the read-through checks the ledger is empty.

The 2026-09-05 source audit confirms that receiver admission introduces scope only through
`withAuthenticatedRootScopeFromWire`, and `ReceivedRecoveryDescent` retains both the complete
`RecoveryChildPackage` and its distinct `RootedPayloadBinding`. Provider records describe primitives;
`Provider.Ownership` holds the shared transactions, and the substrate tag is matched once for provider
selection. `Handoff.Process.Route.sanitizedLaunch` derives its dispatch from `Lift.foldLeaf`. Their
corresponding ledger shapes are absent. The service-handler and root-closure owners have also deleted
their listed shapes, leaving the ledger empty.

#### Remaining Work

None.

### Sprint 29.2: Reconcile comments and help text [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/**`, `demo/src/**`, `hostbootstrap/**`
**Substrates**: none
**Docs to update**: `documents/documentation_standards.md`

#### Objective

Make in-code references and operator-visible text accurate.

#### Deliverables

- Source comments cite phases by name and link, never by execution number.
- Command help and refusal messages use the actual typed vocabulary.
- Operator entry refusals identify the installed root command as the supported route.
- Convenience actions describe the completion observations they actually provide and do not claim managed
  ownership, readiness, or idempotence evidence.

#### Validation

`CLISpec` exercises help, dispatch, missing-config guidance, and signed runtime selection. The documentation
validator scans governed documents and production source for numeric phase citations and proves the refusal
with negative prose and source fixtures. Both are included in the complete gate recorded below.

#### Remaining Work

None.

### Sprint 29.3: Install the drift guards [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/DocValidator.hs`,
`core/hostbootstrap-core/test/DocValidatorSpec.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Substrates**: none
**Docs to update**: `DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

Make the reconciled state mechanically hard to lose.

#### Deliverables

- Architecture absence guards name the owning constructive phase and the matching rationale entry.
- Existing doctrine checks enforce dependency order, reversal vocabulary, sprint structure, substrate budget,
  status harmony, and contiguous phase numbering.
- Script/interpreter (§ KK), frame-table (§ LL), path-frame (§ MM), and host-harness (§ JJ) guards remain
  in their lower owning suites and run in the aggregate gate.
- A new architecture fixture detects removed authority modules, unbounded service definitions, and obsolete
  root closure tokens; a valid named-phase link is accepted while numeric prose/source references refuse.
- Provider nonce replay is a behavioral assertion: the second request refuses before another observation,
  rather than a test that merely searches its own source for claimed coverage labels.

#### Validation

The malformed-repository and architecture fixtures make each new validator guard fail for its named reason.
The full gate also runs the existing effect, provider, path, ownership, and compile-fail guard families listed
below. `RecursiveLifecycleSpec` preserves its seven-case accounting and directly observes one-use nonce behavior.

#### Remaining Work

None.

## Completion Evidence

On 2026-09-05, Linux x86_64 with GHC 9.12.4 and Cabal 3.16.1.0 passed the complete
`cabal test all --ghc-options=-Werror` gate: 2,494/2,494 in 148.63 seconds. `cabal build all` also passed.
The full gate includes the three `DocValidatorSpec` cases, actual signed CLI service dispatch, fixed host
coverage accounting, and the provider nonce replay case that refuses before a second observation.

The final native macOS full suite also passed 2,494/2,494 in 402.88 seconds, and native Windows passed
2,489/2,489 in 886.48 seconds with the five declared platform-selection differences. The Linux documentation
selection passed all three cases in 0.95 seconds after status reconciliation. A final macOS documentation
check also passed 3/3 after the standards, composition, Dhall, and provider guides were reconciled; obsolete
current-versus-target passages and the duplicate composition API sketch have been removed.

The governed lifecycle, binary-context, budget, configuration, secret, ownership, service, and operator
guides describe their current source owners. The component inventory resolves to actual modules. Obsolete
illustrative API sketches and completed-work backlog claims are absent; the legacy ledger is empty.
Root operator refusals name the installed root entry as the remedy. Production source and governed-document
phase references use durable names and links.

The guard families retain their constructive owners:

| Rejected shape / doctrine | Executable guard |
|---|---|
| Plan order, reversal, status, sprint structure, substrate budget, ledger ownership | `DocValidatorSpec` malformed-repository fixture |
| Child durable-store route, root-only closure token, unbounded service handler | `DocValidatorSpec` architecture fixture, `AuthoritySpec`, `SpecIndexSpec`, compile-fail boundaries |
| Scripts and duplicate effect/quoter/interpreter sites (§ KK) | `EffectSpec`, including extension and shebang negative fixtures |
| Duplicate provider/crossing workflows (§ LL) | `ProviderSpec`, `LiftSpec`, `RegistrySpec` and exact crossing arguments |
| Host grammar over guest paths and duplicate path helpers (§ MM/§ JJ) | `EffectSpec`, `LiftContextSpec`, `PortabilitySpec`, and shared source-guard fixtures |
| Forged ownership, stale lease/receipt, incomplete traversal or migration, and premature close | Ownership, Authority, Session, ProjectPlan, recovery and compile-fail suites |
| Numeric phase references outside the plan | `DocValidatorSpec` positive named link and negative prose/source fixtures |

Every new architecture violation names its constructive phase to rewrite and its rationale. Existing lower
boundary guards stay with their owners; the final phase adds no second interpreter or authority surface.

## Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- every document under `documents/architecture/` — reconciled against the implemented surfaces.

**Engineering docs to create/update:**
- every document under `documents/engineering/` and `documents/operations/` — reconciled against the real
  commands and observed figures.

**Cross-references to add:**
- `documents/documentation_standards.md` — the surface this phase changes in it.
- `README.md`, `AGENTS.md`, `CLAUDE.md`, `DEVELOPMENT_PLAN/README.md`, `00-overview.md`, and
  `system-components.md` all agree on the phase names and defer status to the README table.
