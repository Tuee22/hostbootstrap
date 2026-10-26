# Development Plan

**Status**: Governed orientation document
**Supersedes**: N/A
**Canonical homes**: [development_plan_standards.md](development_plan_standards.md),
[00-overview.md](00-overview.md), [system-components.md](system-components.md),
[rationale.md](rationale.md)

> **Purpose**: Name the phases in execution order and carry the single cross-phase status table.

## How to read this plan

The plan is a **build recipe**. Phases 0 through 29 construct `hostbootstrap` from nothing, and the numbers
*are* the order: at phase *n* only the artifacts of phases ≤ *n* exist. Nothing later contradicts or reverses
anything earlier, so following the numbers in order and validating each phase as you go is the supported way
to develop the project.

`linux-cpu` is the universal baseline substrate, not a requirement that the outer host be Linux and not the
only context an application may target. `hostbootstrap` lifts an arbitrary application into its declared
hardware context: native
Linux realizes it directly, Apple Silicon through Lima/Colima, and Windows through WSL2. The host-native
bootstrap selects and owns that realization, then runs project work and baseline gates inside the resulting
Linux/container environment. A selected Metal, NVIDIA, or Windows CUDA context adds genuine typed
capabilities and placement beyond that floor. Phases 0–25 close on a `linux-cpu` substrate gate or a
pure-static gate, as each phase's own `**Gate**` says. Phases 26–28 are **acceptance phases** for
Apple/Metal, NVIDIA-accelerated, and Windows/WSL2/CUDA contexts: each confirms the universal floor through
its provider and the behavior unique to that context. Phase 29 is the **host-portability acceptance**: the
host static gate passing natively on Windows, macOS, x86_64 Linux, and arm64 Linux gate hosts. Nothing
depends on an acceptance phase (§ II).

[development_plan_standards.md](development_plan_standards.md) § A states the doctrine and § II the substrate
rule. [rationale.md](rationale.md) explains why the architecture has the shape these phases build, including
the shapes it deliberately does not have.

## Current Phase Status

This table is the **sole cross-phase status source of truth**. Each phase file's own `**Status**` must match
its row here.

| # | Phase | Status | Substrate | Open |
|---|-------|--------|-----------|------|
| 0 | [Governance and documentation standards](phase-0-governance-and-documentation-standards.md) | Active | — | Sprint 0.3; 2 Active, 2 Planned |
| 1 | [Python pre-binary floor](phase-1-python-pre-binary-floor.md) | Active | linux-cpu | Sprint 1.1; 6 Active, 3 Planned |
| 2 | [Haskell core scaffolding](phase-2-haskell-core-scaffolding.md) | Active | — | Sprint 2.3; 4 Active, 1 Planned |
| 3 | [Host tools and substrate detection](phase-3-host-tools-and-substrate-detection.md) | Active | linux-cpu | Sprint 3.1; 10 Active, 1 Planned |
| 4 | [Protected store](phase-4-protected-store.md) | Active | linux-cpu | Sprint 4.1; 2 Active, 2 Planned |
| 5 | [Installed identity, operator verification, and authority kernels](phase-5-installed-identity-and-authority-kernels.md) | Active | — | Sprint 5.2; 9 Active, 2 Planned |
| 6 | [Canonical quantities and reconcile results](phase-6-canonical-quantities-and-reconcile-results.md) | Active | — | Sprint 6.1; 3 Active, 2 Planned |
| 7 | [Dhall configuration and the generic project model](phase-7-dhall-configuration-and-project-model.md) | Active | — | Sprint 7.1; 9 Active, 5 Planned |
| 8 | [Ensure reconcilers](phase-8-ensure-reconcilers.md) | Active | linux-cpu | Sprint 8.2; 6 Active, 7 Planned |
| 9 | [Lifecycle modes and run leases](phase-9-lifecycle-modes-and-run-leases.md) | Active | linux-cpu | Sprint 9.1; 4 Active |
| 10 | [Sessions, journal, and fences](phase-10-sessions-journal-and-fences.md) | Active | linux-cpu | Sprint 10.1; 5 Active, 2 Planned |
| 11 | [Prepared operations](phase-11-prepared-operations.md) | Active | linux-cpu | Sprint 11.1; 3 Active |
| 12 | [Step algebra and the project plan](phase-12-step-algebra-and-project-plan.md) | Active | linux-cpu | Sprint 12.1; 23 Active, 8 Planned |
| 13 | [Authenticated handoff and child admission](phase-13-authenticated-handoff-and-child-admission.md) | Active | linux-cpu | Sprint 13.1; 17 Active, 7 Planned |
| 14 | [Ownership clauses and reservations](phase-14-ownership-clauses-and-reservations.md) | Active | linux-cpu | Sprint 14.4; 12 Active, 8 Planned |
| 15 | [Host providers and the lift](phase-15-host-providers-and-the-lift.md) | Active | linux-cpu | Sprint 15.2; 28 Active, 7 Planned |
| 16 | [Cluster lifecycle, budgets, and cordoning](phase-16-cluster-lifecycle-and-cordoning.md) | Active | linux-cpu | Sprint 16.1a; 45 Active, 10 Planned |
| 17 | [Recursive lifecycle command](phase-17-recursive-lifecycle-command.md) | Active | linux-cpu | Sprint 17.1; 54 Active, 12 Planned |
| 18 | [Recovery and migration](phase-18-recovery-and-migration.md) | Active | linux-cpu | Sprint 18.1; 19 Active, 6 Planned |
| 19 | [Test harness and run ownership](phase-19-test-harness-and-run-ownership.md) | Active | linux-cpu | Sprint 19.1; 4 Active, 7 Planned |
| 20 | [`test` and `context` commands](phase-20-test-and-context-commands.md) | Active | linux-cpu | Sprint 20.1; 4 Active, 1 Planned |
| 21 | [Composition and network algebra](phase-21-composition-and-network-algebra.md) | Active | linux-cpu | Sprint 21.1; 3 Active, 9 Planned |
| 22 | [Service runtime](phase-22-service-runtime.md) | Active | linux-cpu | Sprint 22.1; 3 Active, 9 Planned |
| 23 | [Base image and warm store](phase-23-base-image-and-warm-store.md) | Active | linux-cpu | Sprint 23.1; 8 Active |
| 24 | [The worked demo](phase-24-worked-demo.md) | Active | linux-cpu | Sprint 24.1; 37 Active, 29 Planned |
| 25 | [Documentation reconciliation](phase-25-documentation-reconciliation.md) | Active | — | Sprint 25.4; 3 Active, 10 Planned |
| 26 | [Apple Silicon substrate](phase-26-apple-silicon-substrate.md) | Active | **apple-silicon** | Sprint 26.8; 1 Active |
| 27 | [NVIDIA GPU substrate](phase-27-nvidia-gpu-substrate.md) | Done | **nvidia** | — |
| 28 | [Windows and WSL2 substrate](phase-28-windows-and-wsl2-substrate.md) | Active | **windows** | Sprint 28.5; 1 Active, 1 Planned |
| 29 | [Host-portability acceptance](phase-29-host-portability-acceptance.md) | Done | — | — |

## The current frontier

Phases 0 through 26 and phase 28 are `Active`; phases 27 and 29 are `Done`. Each Active baseline phase owes
code changes and behavioural tests that its own contracts name. Its `## Remaining Work` lists the owing
sprints; each owing sprint's `#### Remaining Work` names the change and the case that proves it, and its
`#### Validation` names the cases that close it. Work resumes at the lowest Active phase, phase 0, and
proceeds in numerical order; inside a phase, the Active sprints come before the Planned ones.

Phases 26 and 28 each owe the live accelerator-daemon kill-and-restart that the worked demo hands to
hardware it cannot reach, at the next visit to an Apple Silicon host and to a native Windows host
respectively. Phase 28 also owes Sprint 28.7, which routes the demo's WSL2 `copy-source` through the exact
provider-share route alone. Their other evidence, and that of phases 27 and 29, stands in each phase's
`**Gate evidence**` rows against the source digest it covered.

**The acceptance phases close last.** Phases 26 to 29 cover the host-portable tree, so a source change in a
lower phase expires their evidence: a `Done` acceptance phase whose digest stops matching is `Active` (§ C)
and owes its run again at the next visit to the hardware or gate hosts it declares. Running them before the
baseline phases settle records evidence the next sprint expires.

The documentation reconciliation phase (25) precedes the acceptance phases for the same reason in reverse:
its drift guards are source, so landing them after a hardware run would expire that run's evidence. Each
acceptance phase keeps its own documents aligned under § C, and the reconciliation guards then hold every
page.

[The legacy ledger](legacy_tracking_for_deletion.md) lists the code still standing that the architecture
does not want. Each row names the phase, and the Active or Planned sprint within it, whose completion
deletes the shape. The ledger schedules nothing: the deleting phase's own `Remaining Work` states the
deletion.

## Validation policy

`Done` requires the phase's own declared gate to pass, aligned governed documentation, and no remaining work
in its scope. A phase closes on **its own** gate; it never carries a closure obligation that needs a
substrate or accelerator it does not declare (§ C).

Two gate kinds **close phases**, and a phase says which one closes it (§ II). The **host static gate** —
all four commands in [§ JJ](development_plan_standards.md#jj-host-portable-static-gate-and-test-harness) — runs as an
ordinary process of the gate host and proves the pure, typed, and lexical contracts. Because every binary
is built host-native (§ N), it must pass host-native on macOS, Linux, and Windows alike (§ JJ); running it
natively on Windows is a gate-host realization, not a substrate declaration. A **`linux-cpu` substrate
gate** is one whose gated process and POSIX/container effects execute inside the realized Linux
substrate, and a native Windows or macOS process is not one of those merely because its assertions are
otherwise static. Neither gate substitutes for the other.
[The testing page](../documents/engineering/testing.md#gate-kinds) is canonical for the gate kinds,
including the live demo gate that the worked-demo and hardware acceptance phases run and the derived
image's `check-code`, a build-time guardrail that closes no phase.

A dated run validates only the behaviour and substrate it exercised. It cannot stand in for a different
provider, architecture, concurrency race, negative parser path, or newly introduced type boundary — which is
why each acceptance phase lists what it confirms, and why a change to a behaviour a lane exercises makes that
lane's acceptance owed again.

Exact test counts are dated evidence recorded against the gate that produced them, never a repository-wide
"current count".

Three limits worth stating rather than assuming. `fourmolu` and `hlint` are not part of the host static
gate: they run in the repository source gate that `base build` and `base build-and-push` run on the host
before Docker, in a derived image's `check-code`, and in the base image's tool smoke, and
[the code-check doctrine](../documents/engineering/code_check_doctrine.md) is canonical for where. A host
static gate run is evidence for the one gate host (§ JJ) that ran it, so its dated evidence names that host
and a pass on one gate host is not a claim about another. And the long demo gate brings up real provider
VMs, Docker state, and clusters on the host it runs on: a harness run's cluster identity, removable state,
durable root, and runtime-selected host exposures belong to that exact run, and because the gate mutates
real host infrastructure, a disposable host remains the supported way to run it.

## Governance

- [development_plan_standards.md](development_plan_standards.md) — the doctrine (§ A–§ J, § II) and the
  normative technical contracts (§ K–§ NN).
- [00-overview.md](00-overview.md) — phase responsibilities and the dependency flow, without status.
- [system-components.md](system-components.md) — the implementation surface inventory.
- [rationale.md](rationale.md) — why the design is what it is, and what it is not.
- [legacy_tracking_for_deletion.md](legacy_tracking_for_deletion.md) — code still standing that the
  architecture does not want, each row naming the phase whose completion deletes it (§ I).
- Each phase file owns its objective, sprints, validation, and remaining work.

## Authority

This directory is authoritative for development sequencing and completion state. Governed architecture and
engineering documents describe supported behaviour; where a contract is not yet fully built, the owning phase
is `Active`, its `Remaining Work` names the owed change, and the document's `## Current Status` states the
gap and links the phase. That pairing is a review rule: no validator check compares a page's gap with the
phase's Remaining Work.
