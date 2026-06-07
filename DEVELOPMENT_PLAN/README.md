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
bootstrapper (under `python/`). The phases below describe the ordered buildout to the target; all
phases are `Done` — the Haskell core owns the host-management logic and the Python layer is the thin
five-step bootstrapper. Consumer-side migration of individual projects is tracked in those projects'
own repositories (see Phase 7).

## Phases

| Phase | Title | Status |
|-------|-------|--------|
| 0 | [Documentation and governance](phase-0-documentation-and-governance.md) | Done |
| 1 | [hostbootstrap-core scaffolding](phase-1-hostbootstrap-core-scaffolding.md) | Done |
| 2 | [Host tools and config](phase-2-host-tools-and-config.md) | Done |
| 3 | [Ensure reconcilers](phase-3-ensure-reconcilers.md) | Done |
| 4 | [Skeletal Dhall and command tree](phase-4-skeletal-dhall-and-command-tree.md) | Done |
| 5 | [Cluster lifecycle and resource cordoning](phase-5-cluster-lifecycle-and-resource-cordoning.md) | Done |
| 6 | [Base image and thin Python bootstrapper](phase-6-base-image-and-thin-python-bootstrapper.md) | Done |
| 7 | [Consumer migration](phase-7-consumer-migration.md) | Done |

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
validator is a Phase-0 deliverable; until it lands, conformance is verified by manual review against
the standards.

## Authority

This plan owns current-state implementation status. When status claims in
[`../documents/`](../documents/) conflict with the plan, reconcile the governed docs to the plan.
See [development_plan_standards.md § J](development_plan_standards.md).
