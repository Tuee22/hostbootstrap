# Development Plan

**Status**: Governed orientation document
**Supersedes**: N/A
**Canonical homes**: [development_plan_standards.md](development_plan_standards.md),
[00-overview.md](00-overview.md), [system-components.md](system-components.md),
[rationale.md](rationale.md)

> **Purpose**: Name the phases in execution order and carry the single cross-phase status table.

## How to read this plan

The plan is a **build recipe**. Phases 0 through 28 construct `hostbootstrap` from nothing, and the numbers
*are* the order: at phase *n* only the artifacts of phases ≤ *n* exist. Nothing later contradicts or reverses
anything earlier, so following the numbers in order and validating each phase as you go is the supported way
to develop the project.

`linux-cpu` is the baseline substrate. Phases 0–24 and 28 close on it or on pure-static gates. Phases 25–27
are **acceptance phases**: each adds one non-baseline substrate's own realizations and confirms the build on
it. Nothing depends on them, so a machine without that hardware stops at phase 24 rather than being blocked.

[development_plan_standards.md](development_plan_standards.md) § A states the doctrine and § II the substrate
rule. [rationale.md](rationale.md) explains why the architecture has the shape these phases build, including
the shapes it deliberately does not have.

## Current Phase Status

This table is the **sole cross-phase status source of truth**. Each phase file's own `**Status**` must match
its row here.

| # | Phase | Status | Substrate | Open |
|---|-------|--------|-----------|------|
| 0 | [Governance and documentation standards](phase-0-governance-and-documentation-standards.md) | Done | — | — |
| 1 | [Python pre-binary floor](phase-1-python-pre-binary-floor.md) | Done | linux-cpu | — |
| 2 | [Haskell core scaffolding](phase-2-haskell-core-scaffolding.md) | Done | — | — |
| 3 | [Host tools and substrate detection](phase-3-host-tools-and-substrate-detection.md) | Done | linux-cpu | — |
| 4 | [Protected store](phase-4-protected-store.md) | Done | linux-cpu | — |
| 5 | [Operator, root, and command authority](phase-5-operator-root-and-command-authority.md) | Done | — | — |
| 6 | [Canonical quantities and reconcile results](phase-6-canonical-quantities-and-reconcile-results.md) | Done | — | — |
| 7 | [Dhall configuration and the project model](phase-7-dhall-configuration-and-project-model.md) | Done | — | — |
| 8 | [Ensure reconcilers](phase-8-ensure-reconcilers.md) | Done | linux-cpu | — |
| 9 | [Lifecycle modes and run leases](phase-9-lifecycle-modes-and-run-leases.md) | Done | linux-cpu | — |
| 10 | [Sessions, journal, and fences](phase-10-sessions-journal-and-fences.md) | Done | linux-cpu | — |
| 11 | [Prepared operations](phase-11-prepared-operations.md) | Done | linux-cpu | — |
| 12 | [Step algebra and the project plan](phase-12-step-algebra-and-project-plan.md) | Done | linux-cpu | — |
| 13 | [Authenticated handoff and child admission](phase-13-authenticated-handoff-and-child-admission.md) | Active | linux-cpu | 13.1 the recovery tag pair |
| 14 | [Ownership clauses and reservations](phase-14-ownership-clauses-and-reservations.md) | Done | linux-cpu | — |
| 15 | [Host providers and the lift](phase-15-host-providers-and-the-lift.md) | Done | linux-cpu | — |
| 16 | [Cluster lifecycle and cordoning](phase-16-cluster-lifecycle-and-cordoning.md) | Done | linux-cpu | — |
| 17 | [Recursive lifecycle command](phase-17-recursive-lifecycle-command.md) | Active | linux-cpu | 17.3 frame index and the two entries; live acceptance |
| 18 | [Recovery and migration](phase-18-recovery-and-migration.md) | Active | linux-cpu | 18.2 recovery-boundary teardown and recovery wire; 18.3 configful forward path |
| 19 | [Test harness and run ownership](phase-19-test-harness-and-run-ownership.md) | Active | linux-cpu | live `test run all` acceptance |
| 20 | [`test` and `context` commands](phase-20-test-and-context-commands.md) | Active | linux-cpu | live linux-cpu verb sequence (phase gate) |
| 21 | [Composition and network algebra](phase-21-composition-and-network-algebra.md) | Done | linux-cpu | — |
| 22 | [Service runtime](phase-22-service-runtime.md) | Active | linux-cpu | 22.2/22.3 registry adoption and the deploy step |
| 23 | [Base image and warm store](phase-23-base-image-and-warm-store.md) | Done | linux-cpu | — |
| 24 | [The worked demo](phase-24-worked-demo.md) | Active | linux-cpu | 24.4 guest-alias adoption |
| 25 | [Apple Silicon substrate](phase-25-apple-silicon-substrate.md) | Active | **apple-silicon** | 25.3 acceptance re-run |
| 26 | [NVIDIA GPU substrate](phase-26-nvidia-gpu-substrate.md) | Active | **nvidia** | 26.3 acceptance re-run |
| 27 | [Windows and WSL2 substrate](phase-27-windows-and-wsl2-substrate.md) | Active | **windows** | 27.3 acceptance re-run |
| 28 | [Documentation reconciliation](phase-28-documentation-reconciliation.md) | Planned | — | all |

## The current frontier

The lowest-numbered open phase is **17**. The remaining baseline work is now two shapes rather than one.

**The teardown descent is the frontier.** A recursive verb has two entries, and they are two types rather
than one command class asked to mean both: an operator-initiated teardown validates at the topology root,
and a descent-initiated one is admitted in a nested frame only by verifying the recovery wire its parent
minted from the forest's own authorization point. The reverse projection is frame-indexed alongside it, so
whether an offered node belongs to this frame is a closed sum with a total eliminator rather than a
comparison of frame names.

That shape spans three phases and they land together: the
[authenticated-handoff phase](phase-13-authenticated-handoff-and-child-admission.md) owns the recovery tag,
the [recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md) owns the frame index and
the two entries, and the [recovery phase](phase-18-recovery-and-migration.md) consumes the same wire at its
own nested boundary. Until they do, `project destroy` settles the frames one binary can reach and reports
the rest outstanding.

**Live acceptance owed.** Phases 19 and 20 have every deliverable built and closed by the host static gate;
what each still owes is its own declared live linux-cpu run.

**Machinery without a production call site.**

- **18.2**'s broker, old-permit fence set, verified session/operation manifest, and recorded-session
  interpreter have landed, and a **completed** migration is now resumed rather than refused: the reopening
  yields all four as one consistent set, and `withCompletedMigrationRecovery` → `activateMigratedPlan` follows
  the committed activation through from the durable stable key rather than from the current config. What it
  still owes is the case where the resumed run *acquired* something — child-first teardown driven from a
  recovery boundary, and the signed recovery wire a boundary with an edited or missing old config needs.
  **18.3**'s migration profile builders and activation transition have landed at the digest level, including
  the freeze, the lineage compare-and-swap, and the configless post-CAS recovery; the configful forward path
  (`withCompletedMigrationPlan` and a candidate built from real drafts) and the complete resource-record
  rehydration are open. Phase 18 is also where the settled-destroy proof the lifecycle verbs now mint becomes
  project-closure evidence.
- **22.2**'s effect algebra and its closed `ServiceProgram` have landed: an undeclared effect is a compile
  error, a row outside the signed ceiling has no authorization, and there is no `IO` constructor. The
  **declared row** has now landed with it — `serviceDefinition` takes a `DeclaredEffects`, the registry carries
  it through finalization and selection, and the demo's two roles declare genuinely different rows. What
  remains is the handler return type and the `ServiceBackend` call site, which cannot precede the deploy step
  that installs a signed activation, so they land with **22.3**.
- **22.3**'s relayed activation signing has **landed**: a distinct `ActivationSignRequest`/`Response` tag pair
  reachable only from an admitted child, a manifest wire codec so the root signs a value it decoded rather than
  opaque bytes, `linkSignActivation` on `BrokerLink` with the root signing locally and every other frame
  relaying, and the round-trip plus negative-path coverage this repository pins for every protocol tag. A
  nested frame can now reach the root for a signature, so what 22.3 owes is the deploy-step adoption that
  consumes it — signing one manifest per pod-template revision and having `service run` measure and verify —
  which is wiring rather than a protocol extension and lands with 22.2's registry adoption.
- **24.4**'s published-base consumption is now enforced: every derived build passes `--pull`, and the
  host-native lane resolves the published tag to its repository digest and builds `FROM` that, refusing an
  image that has no repo digest because that is exactly the stale-local case. The digest is a within-run
  handoff rather than a committed pin, which is what § FF requires. What it still owes is the demo's own use of
  the guest-alias route, so its durable-share and alias operations become prepared operations minting managed
  handles; that needs a plan-minted `StepExecution` threaded into the alias step and is only really observable
  inside a live guest. Its profile-scoped durable host root has landed, so a harness run no longer shares the
  operator's durable state.

Every one of those depends only on lower-numbered phases, so they can be taken in order.

## Validation policy

`Done` requires the phase's own declared gate to pass, aligned governed documentation, and no remaining work
in its scope. A phase closes on **its own** gate; it never carries a closure obligation needing hardware it
does not declare.

A dated run validates only the behaviour and substrate it exercised. It cannot stand in for a different
provider, architecture, concurrency race, negative parser path, or newly introduced type boundary — which is
why each acceptance phase lists what it confirms, and why a change to a behaviour a lane exercises makes that
lane's acceptance owed again.

Exact test counts are dated evidence recorded against the gate that produced them, never a repository-wide
"current count".

Two limits worth stating rather than assuming: `fourmolu` and `hlint` run only inside the container
`check-code`, so the host static gate is not the complete quality gate; and the long demo gate brings up real
provider VMs, Docker state, and clusters on the host it runs on. A harness run's cluster identity, removable
state, host ports, and durable root are now its own rather than production's, so the gate no longer takes the
operator's project identity — but it still mutates real host infrastructure, so a disposable host remains the
supported way to run it.

## Governance

- [development_plan_standards.md](development_plan_standards.md) — the doctrine (§ A–§ J, § II) and the
  normative technical contracts (§ K–§ HH).
- [00-overview.md](00-overview.md) — phase responsibilities and the dependency flow, without status.
- [system-components.md](system-components.md) — the implementation surface inventory.
- [rationale.md](rationale.md) — why the design is what it is, and what it is not.
- [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md) — code still standing that the
  architecture does not want, each row naming the phase whose completion deletes it (§ I).
- Each phase file owns its objective, sprints, validation, and remaining work.

## Authority

This directory is authoritative for development sequencing and completion state. Governed architecture and
engineering documents describe supported behaviour; where a contract is not yet fully built, the owning phase
is `Active` and says so.
