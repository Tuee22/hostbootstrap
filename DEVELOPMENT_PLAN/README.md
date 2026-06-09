# Development Plan

**Status**: Governed orientation document
**Supersedes**: N/A
**Canonical homes**: [development_plan_standards.md](development_plan_standards.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md)

> **Purpose**: Phase plan orientation. Names the phases in execution order, reports the current
> status of each, and links to the standards and inventory documents.

## Foundation

`hostbootstrap` is the reusable host-management layer for the project family
([`daemon-substrate`](https://github.com/Tuee22/daemon-substrate),
[`mcts`](https://github.com/Tuee22/mcts), and the future consumers
[`infernix`](https://github.com/Tuee22/infernix) and [`jitML`](https://github.com/Tuee22/jitML)).
The target architecture is a Haskell `hostbootstrap-core` library plus a thin Python bootstrapper:
the library owns host-tool resolution, the `ensure` reconcilers, substrate detection,
cluster-lifecycle and resource cordoning, and the optparse command tree projects extend; the Python
layer shrinks to the pre-binary bootstrap. See [00-overview.md](00-overview.md) for the cross-phase
narrative and [system-components.md](system-components.md) for the component inventory.

The repository runs the Haskell `hostbootstrap-core` library (under `haskell/`) plus the thin Python
bootstrapper (under `python/`). The phases below describe the ordered buildout. The host-management
surface is implemented and the Python layer is the thin pre-binary bootstrapper; the global-architecture
deltas have largely landed — the binary-generated `config schema`/`config render` (Phase 8), the applied
budget cordon (Phase 9), the standardized test harness (Phase 10), and the incus host-provider
(Phase 11) are all implemented and unit-tested. The two phases that remain `Active` are so because their
live end-to-end half is real-run/real-build-gated (the layered warm store, Phase 12; the worked demo,
Phase 13 — see § Validation Policy); the Phase-0 governance, including the doctrine-clarity sweep, has
**closed** (per § A it may reopen only when a future architecture contract adds a new doc-coverage
obligation). See [00-overview.md](00-overview.md) for the cross-phase narrative and the net-new phases. Consumer-side
migration of individual projects is tracked in those projects' own repositories (see Phase 7).

## Phases

| Phase | Title | Status |
|-------|-------|--------|
| 0 | [Documentation and governance](phase-0-documentation-and-governance.md) | Done |
| 1 | [hostbootstrap-core scaffolding](phase-1-hostbootstrap-core-scaffolding.md) | Done |
| 2 | [Host tools and config](phase-2-host-tools-and-config.md) | Done |
| 3 | [Ensure reconcilers](phase-3-ensure-reconcilers.md) | Done |
| 4 | [Static-Base Dhall and command tree](phase-4-skeletal-dhall-and-command-tree.md) | Done |
| 5 | [Cluster lifecycle and resource cordoning](phase-5-cluster-lifecycle-and-resource-cordoning.md) | Done |
| 6 | [Base image and thin Python bootstrapper](phase-6-base-image-and-thin-python-bootstrapper.md) | Done |
| 7 | [Consumer migration](phase-7-consumer-migration.md) | Done |
| 8 | [Dhall generation and the four-stream extension](phase-8-dhall-generation-and-extension.md) | Done |
| 9 | [Applied budget cordon and one canonical parser](phase-9-applied-cordon-and-one-parser.md) | Done |
| 10 | [Standardized test harness and run-models](phase-10-standardized-test-harness.md) | Done |
| 11 | [incus first-class host-provider](phase-11-incus-host-provider.md) | Done |
| 12 | [Layered warm store](phase-12-layered-warm-store.md) | Active |
| 13 | [hostbootstrap-demo worked app](phase-13-hostbootstrap-demo.md) | Active |

## Governance

- [development_plan_standards.md](development_plan_standards.md) defines how the plan is organized,
  updated, and kept aligned with implementation and the governed `documents/` suite.
- [00-overview.md](00-overview.md) tells the cross-phase narrative and names the dependency edges.
- [system-components.md](system-components.md) is the authoritative inventory of host-management
  components.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is the cleanup ledger for the
  pure-Python surfaces the inversion removes.

## Validation Policy

This repository does not use `.github/` workflows or GitHub Actions as a validation surface. The
supported gate is the project's canonical code-check, run on every base and derived image build (see
[development_plan_standards.md § R](development_plan_standards.md)). The mechanical documentation
validator (`HostBootstrap.DocValidator`) has **landed** and runs through the canonical code-check
(`cabal test`); manual review covers only the editorial tier.

Two validation surfaces gate the plan, and a phase's two halves are validated by different ones:

- **The code-check gate** — `cabal test` / `check_code` (above). Validates the library, the pure cores,
  the argument builders, the command wiring, the unit tests, and the governed docs.
- **The real-run / real-build gate** — a real host run (incus / Docker / kind / web / Playwright) and
  the base-image build. Validates the live half — the part the phase docs describe as *"exercised in
  real runs."*

A phase is `Active` (in scope, open) when its remaining half is the real-run / real-build gate; that
work is **not** out of scope — it is open until a real run or build closes it. The repository does not
treat that gate as a CI surface; an operator (or a real demo run) exercises it.

## Authority

This plan owns current-state implementation status. When status claims in
[`../documents/`](../documents/) conflict with the plan, reconcile the governed docs to the plan.
See [development_plan_standards.md § J](development_plan_standards.md).
