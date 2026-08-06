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
| 12 | [Step algebra and the project plan](phase-12-step-algebra-and-project-plan.md) | Active | linux-cpu | 12.5 projected operations and carried handles |
| 13 | [Authenticated handoff and child admission](phase-13-authenticated-handoff-and-child-admission.md) | Done | linux-cpu | — |
| 14 | [Ownership clauses and reservations](phase-14-ownership-clauses-and-reservations.md) | Done | linux-cpu | — |
| 15 | [Host providers and the lift](phase-15-host-providers-and-the-lift.md) | Active | linux-cpu | 15.3 prepared guest-alias adoption |
| 16 | [Cluster lifecycle and cordoning](phase-16-cluster-lifecycle-and-cordoning.md) | Done | linux-cpu | — |
| 17 | [Recursive lifecycle command](phase-17-recursive-lifecycle-command.md) | Active | linux-cpu | 17.3 recursive child-first unwind |
| 18 | [Recovery and migration](phase-18-recovery-and-migration.md) | Active | linux-cpu | 18.2 broker/fence/manifest half; 18.3 migration gates |
| 19 | [Test harness and run ownership](phase-19-test-harness-and-run-ownership.md) | Active | linux-cpu | 19.3 reconciler-produced report rows |
| 20 | [`test` and `context` commands](phase-20-test-and-context-commands.md) | Active | linux-cpu | live linux-cpu verb sequence (phase gate) |
| 21 | [Composition and network algebra](phase-21-composition-and-network-algebra.md) | Done | linux-cpu | — |
| 22 | [Service runtime](phase-22-service-runtime.md) | Active | linux-cpu | 22.2 effect-indexed narrowing; 22.3 role adoption at `service run` |
| 23 | [Base image and warm store](phase-23-base-image-and-warm-store.md) | Done | linux-cpu | — |
| 24 | [The worked demo](phase-24-worked-demo.md) | Active | linux-cpu | 24.3 config-driven matrix; 24.4 harness profile in demo resolution |
| 25 | [Apple Silicon substrate](phase-25-apple-silicon-substrate.md) | Active | **apple-silicon** | 25.3 acceptance re-run |
| 26 | [NVIDIA GPU substrate](phase-26-nvidia-gpu-substrate.md) | Active | **nvidia** | 26.3 acceptance re-run |
| 27 | [Windows and WSL2 substrate](phase-27-windows-and-wsl2-substrate.md) | Active | **windows** | 27.3 acceptance re-run |
| 28 | [Documentation reconciliation](phase-28-documentation-reconciliation.md) | Planned | — | all |

## The current frontier

The lowest-numbered open phase is **12**. The remaining baseline work shares one shape: the machinery exists
and is unit-gated, but a **production call site** does not yet drive it.

- **12.5** is the one the rest of the frontier turns out to rest on. A relating resource's operation key is a
  projection of the keys it relates, so it is not any node's own key and no node can prepare it; and a prepared
  call's dependency snapshot consumes a *managed* handle another node minted, which cannot be serialized. Until
  a node can reach its projections' gates and receive its dependencies' handles, no resource adapter has a
  reachable call site.
- **15.3**'s guest-alias backend and **24**'s alias adoption are the first consumers of exactly that.
- **17.3** makes `project destroy` descend into child frames before running its own reverse steps, which is
  what gives the landed teardown forest a production call site. The recursive descent is also where phase 13's
  authenticated transport gets its call site.
- **19.3** turns each node's row into a report-card row; the rows themselves now exist.

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
provider and cluster state under the project's own identity, so it runs on a disposable host.

## Governance

- [development_plan_standards.md](development_plan_standards.md) — the doctrine (§ A–§ J, § II) and the
  normative technical contracts (§ K–§ HH).
- [00-overview.md](00-overview.md) — phase responsibilities and the dependency flow, without status.
- [system-components.md](system-components.md) — the implementation surface inventory.
- [rationale.md](rationale.md) — why the design is what it is, and what it is not.
- Each phase file owns its objective, sprints, validation, and remaining work.

## Authority

This directory is authoritative for development sequencing and completion state. Governed architecture and
engineering documents describe supported behaviour; where a contract is not yet fully built, the owning phase
is `Active` and says so.
