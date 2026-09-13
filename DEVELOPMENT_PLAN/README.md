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
capabilities and placement beyond that floor. Phases 0–24 and 28 close on the invariant or on pure-static
gates. Phases 25–27 are **acceptance phases** for Apple/Metal, NVIDIA-accelerated, and Windows/WSL2/CUDA
contexts: each confirms the universal floor through its provider and the behavior unique to that context.
Nothing depends on those additional acceptance dimensions.

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
| 5 | [Installed identity, operator verification, and authority kernels](phase-5-installed-identity-and-authority-kernels.md) | Done | — | — |
| 6 | [Canonical quantities and reconcile results](phase-6-canonical-quantities-and-reconcile-results.md) | Done | — | — |
| 7 | [Dhall configuration and the generic project model](phase-7-dhall-configuration-and-project-model.md) | Done | — | — |
| 8 | [Ensure reconcilers](phase-8-ensure-reconcilers.md) | Done | linux-cpu | — |
| 9 | [Lifecycle modes and run leases](phase-9-lifecycle-modes-and-run-leases.md) | Done | linux-cpu | — |
| 10 | [Sessions, journal, and fences](phase-10-sessions-journal-and-fences.md) | Done | linux-cpu | — |
| 11 | [Prepared operations](phase-11-prepared-operations.md) | Done | linux-cpu | — |
| 12 | [Step algebra and the project plan](phase-12-step-algebra-and-project-plan.md) | Done | linux-cpu | — |
| 13 | [Authenticated handoff and child admission](phase-13-authenticated-handoff-and-child-admission.md) | Done | linux-cpu | — |
| 14 | [Ownership clauses and reservations](phase-14-ownership-clauses-and-reservations.md) | Done | linux-cpu | — |
| 15 | [Host providers and the lift](phase-15-host-providers-and-the-lift.md) | Done | linux-cpu | — |
| 16 | [Cluster lifecycle, budgets, and cordoning](phase-16-cluster-lifecycle-and-cordoning.md) | Done | linux-cpu | — |
| 17 | [Recursive lifecycle command](phase-17-recursive-lifecycle-command.md) | Active | linux-cpu | named route interactivity |
| 18 | [Recovery and migration](phase-18-recovery-and-migration.md) | Done | linux-cpu | — |
| 19 | [Test harness and run ownership](phase-19-test-harness-and-run-ownership.md) | Active | linux-cpu | gate re-run |
| 20 | [`test` and `context` commands](phase-20-test-and-context-commands.md) | Active | linux-cpu | parsed role at the surface |
| 21 | [Composition and network algebra](phase-21-composition-and-network-algebra.md) | Active | linux-cpu | port as a value |
| 22 | [Service runtime](phase-22-service-runtime.md) | Active | linux-cpu | gate re-run, both legs |
| 23 | [Base image and warm store](phase-23-base-image-and-warm-store.md) | Active | linux-cpu | style contract; core style gate |
| 24 | [The worked demo](phase-24-worked-demo.md) | Active | linux-cpu | protected-store daemon claims |
| 25 | [Apple Silicon substrate](phase-25-apple-silicon-substrate.md) | Active | **apple-silicon** | acceptance re-run |
| 26 | [NVIDIA GPU substrate](phase-26-nvidia-gpu-substrate.md) | Active | **nvidia** | acceptance re-run |
| 27 | [Windows and WSL2 substrate](phase-27-windows-and-wsl2-substrate.md) | Active | **windows** | acceptance re-run |
| 28 | [Host-portability acceptance](phase-28-host-portability-acceptance.md) | Active | — | acceptance re-run |
| 29 | [Documentation reconciliation](phase-29-documentation-reconciliation.md) | Active | — | reconciliation; validator checks |

## The current frontier

Twelve phases are `Active`. The table above says which and what each owes; this section says how
they relate, and nothing here overrides a row there.

The open work divides into three kinds. **Typed boundaries that are stated in prose rather than in the
type**: a record whose optional fields are correlated by comment, and a port carried as a number.
**Workflows written more than once**: the second port-range predicate. **A quality gate that has not reached the
sources it was written for**: the formatter and the linter run against the base image's sample files and
the worked consumer, and have not read the library. The documentation reconciliation that follows all
three is the last phase.

[The legacy ledger](legacy_tracking_for_deletion.md) is no longer empty. Each row names the phase whose
completion deletes the shape, and the ledger schedules nothing on its own: the deleting phase's own
sprint does that.

**The acceptance phases close last.** Phases 25 to 28 cover the host-portable tree, so any source change
in a lower phase re-owes their runs — re-running them before the rest of the plan settles would record
evidence that the next sprint expires. They are taken once no other phase carries open work, and each
is owed at the next visit to the hardware it declares. § G names that state as the honest reading of a
portability claim between runs rather than as an unclosed phase.

The documentation reconciliation phase is last for the same reason in reverse: it corrects governed
prose against the source those phases are changing, and its validator checks are what keep the two
aligned afterwards. Reconciling first would reconcile to a tree that is about to move.

Closed and not reopened: the Python pre-binary floor, the Haskell core scaffolding, host tools and
substrate detection, the protected store, installed identity and the authority kernels, canonical
quantities and reconcile results, Dhall configuration and the generic project model, the ensure
reconcilers, the step algebra and the project plan, lifecycle modes and run leases, sessions and fences, prepared operations, authenticated
handoff and child admission, the four ownership clauses and host-local reservations, host providers and
the self-reference lift, cluster lifecycle and cordoning, and recovery and migration. Their covered paths
are outside the open work, and their gate evidence still measures the tree it names.

## Validation policy

`Done` requires the phase's own declared gate to pass, aligned governed documentation, and no remaining work
in its scope. A phase closes on **its own** gate; it never carries a closure obligation needing hardware it
does not declare.

Two gates **close phases**, and a phase says which one closes it (§ II). Two further gates guard a
build without closing anything — the container `check-code` and the repository's own source gate — which
is why [the testing page](../documents/engineering/testing.md) counts four and this section counts two.
They are the same four gates counted for different purposes. The **host static gate** —
`cabal test all` from `core/` plus the two Python commands — runs as an ordinary
process of the outer host and proves the pure, typed, and lexical contracts. Because every binary is
built host-native (§ N), it must pass host-native on macOS, Linux, and Windows alike (§ JJ); running it
natively on Windows is an outer host realization, not a substrate declaration. A **`linux-cpu` substrate
gate** is one whose gated process and POSIX/container effects execute inside the realized Linux
substrate, and a native Windows or macOS process is not one of those merely because its assertions are
otherwise static. Neither gate substitutes for the other.

A dated run validates only the behaviour and substrate it exercised. It cannot stand in for a different
provider, architecture, concurrency race, negative parser path, or newly introduced type boundary — which is
why each acceptance phase lists what it confirms, and why a change to a behaviour a lane exercises makes that
lane's acceptance owed again.

Exact test counts are dated evidence recorded against the gate that produced them, never a repository-wide
"current count".

Three limits worth stating rather than assuming: `fourmolu` and `hlint` run only inside the container
`check-code`, so the host static gate is not the complete quality gate; a host static gate run is evidence
for the one outer host that ran it, so its dated evidence names that host and a pass on one outer host is
not a claim about another; and the long demo gate brings up real
provider VMs, Docker state, and clusters on the host it runs on. A harness run's cluster identity, removable
state, durable root, and runtime-selected host exposures belong to that exact run. The gate
mutates real host infrastructure, so a disposable
host remains the supported way to run it.

## Governance

- [development_plan_standards.md](development_plan_standards.md) — the doctrine (§ A–§ J, § II) and the
  normative technical contracts (§ K–§ JJ).
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
