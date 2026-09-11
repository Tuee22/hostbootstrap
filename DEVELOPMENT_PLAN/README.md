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
| 17 | [Recursive lifecycle command](phase-17-recursive-lifecycle-command.md) | Done | linux-cpu | — |
| 18 | [Recovery and migration](phase-18-recovery-and-migration.md) | Done | linux-cpu | — |
| 19 | [Test harness and run ownership](phase-19-test-harness-and-run-ownership.md) | Done | linux-cpu | — |
| 20 | [`test` and `context` commands](phase-20-test-and-context-commands.md) | Done | linux-cpu | — |
| 21 | [Composition and network algebra](phase-21-composition-and-network-algebra.md) | Done | linux-cpu | — |
| 22 | [Service runtime](phase-22-service-runtime.md) | Done | linux-cpu | — |
| 23 | [Base image and warm store](phase-23-base-image-and-warm-store.md) | Done | linux-cpu | — |
| 24 | [The worked demo](phase-24-worked-demo.md) | Done | linux-cpu | — |
| 25 | [Apple Silicon substrate](phase-25-apple-silicon-substrate.md) | Done | **apple-silicon** | — |
| 26 | [NVIDIA GPU substrate](phase-26-nvidia-gpu-substrate.md) | Active | **nvidia** | Sprint 26.4: current-tree matrix and audit |
| 27 | [Windows and WSL2 substrate](phase-27-windows-and-wsl2-substrate.md) | Done | **windows** | — |
| 28 | [Host-portability acceptance](phase-28-host-portability-acceptance.md) | Active | — | Sprint 28.4: current-tree macOS and native Linux runs |
| 29 | [Documentation reconciliation](phase-29-documentation-reconciliation.md) | Done | — | — |

## The current frontier

The cluster backend compiles its platform-specific helpers only on the hosts that execute them, and its
Windows tests assert the declared refusals. The recursive lifecycle command admits root-only command entries
and gives children only root-selected execution grants. Documentation reconciliation covers the governed documents,
source comments, help text, and architecture guards. [The legacy ledger](legacy_tracking_for_deletion.md) is empty.
The table above owns phase status; each phase's validation section owns its dated gate evidence.

The [worked-demo phase](phase-24-worked-demo.md) is closed by its 2026-09-11 run on a native Windows outer
host realizing `linux-cpu` through WSL2: the Production Up/Down/Destroy sequence, then a complete Harness
matrix reporting `10/10 passed` in 2 hours 57 minutes across four pristine guest generations, then a terminal
ownership audit whose source measurement still matches the in-run tree. The
[Windows/WSL2 acceptance phase](phase-27-windows-and-wsl2-substrate.md) is closed by the Windows-only
behavior that same run exercises: the global wall taken at four successive fences and restored to its exact
original bytes ahead of any global shutdown, the Windows ownership row against the real Win32 surface, the
hidden Windows host accelerator daemon serving a loopback-only endpoint, and a three-hour gate surviving an
agent session through the durable-run mechanism.

The [Apple-Silicon acceptance phase](phase-25-apple-silicon-substrate.md) is closed by its 2026-09-09
pristine Apple matrix, native direct-Colima lane, and terminal ownership audit against one unchanged
covered tree. Its phase document records the dated results and image digests. The
[NVIDIA acceptance phase](phase-26-nvidia-gpu-substrate.md) records a 2026-09-09 native
Linux/x86_64 RTX 5090 matrix and terminal audit. Changes to its covered journal source make the
current-tree run owed again; its phase document retains the dated result and covered-source digest.

The [host-portability acceptance phase](phase-28-host-portability-acceptance.md) records separate native
Windows, macOS, and Linux gate runs, with the suite's explicit platform conditions explaining their totals.
Static and substrate evidence are distinct. Its Windows family passes against the current tree on
2026-09-11 at 2,500/2,500 core cases and 235/235 Python cases. A current-source macOS family run and a
complete native Linux family run remain owed, and a Linux guest realized on a Windows host is not one of
them: § II makes a gate host the OS, architecture, and toolchain the gate process itself runs on.

The [host-providers phase](phase-15-host-providers-and-the-lift.md) is closed by its 2026-09-09 native
Linux/x86_64 KVM/Incus run: all 2,497 static cases passed before the live component completed its prepared
Incus lifecycle and mutation-free Direct refusal with no residue. The
[base-image phase](phase-23-base-image-and-warm-store.md) is closed by its 2026-09-09 native
Linux/x86_64 run: the complete source preflight and immutable local-ID compatibility smoke passed before
the rolling CPU/amd64 tag was pushed, pulled at
`sha256:e46fb5699af246dc631704cd9bba5020776a7e96fbba1f4c450b5b9971ffb9d5`, and smoked again against
that exact published digest.

Two acceptance rows stay open, and both wait on hardware rather than on work in this tree. The
current-source NVIDIA run needs a native Linux host with an NVIDIA GPU; the available SSH key is refused
for `matt@matt-junction`. The portability row needs a native macOS gate host and a native Linux gate host
for the two families the Windows run cannot speak for. Every other row is closed against the current
covered source. No gate is running.

## Validation policy

`Done` requires the phase's own declared gate to pass, aligned governed documentation, and no remaining work
in its scope. A phase closes on **its own** gate; it never carries a closure obligation needing hardware it
does not declare.

Two gates carry that weight, and a phase says which one closes it (§ II). The **host static gate** —
`cabal test all --ghc-options=-Werror` from `core/` plus the two Python commands — runs as an ordinary
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
