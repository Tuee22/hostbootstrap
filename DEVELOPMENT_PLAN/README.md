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
The repository is a Haskell `hostbootstrap-core` library (under `core/`) plus a thin Python
bootstrapper (rooted at the repository root). The library owns host-tool resolution, substrate
detection, install-and-verify `ensure` reconcilers, cluster lifecycle and resource cordoning,
binary-owned Dhall generation, runtime context command gating, the standardized test harness, the
self-reference lift, and the optparse command tree projects extend. The Python layer owns the
pre-binary bootstrap: assert irreducible host minimums, ensure the host build toolchain, build the
project binary host-native, trigger the binary's idempotent `config init --if-missing`, and exec it. It
also owns the explicit pipx self-update command for the bootstrapper itself.

Phases 0-12 are `Done`. Phases 13, 14, and 15 are `Active` because the binary-context contracts are
being tightened: Apple Silicon uses a Lima VM for the demo, native Linux uses Incus, and the Dhall
context model is being hardened from flat roles into an explicit execution topology with runtime
witnesses. Each project binary still reads a sibling `<project>.dhall`;
host, VM, container, and service copies use the same filename rule while authority lives inside the file
content. The worked demo remains the reference consumer: `demo deploy` is one explicit lift sequence
whose only lifted compute step is the standardized `test all` workflow inside the project container in
the VM. That keeps the kind cluster on the VM's Docker and avoids a second deploy representation beside
the harness.

Operator-scale activities such as publishing multi-arch base tags, running the full Harbor deployment,
and pushing the multi-GB project image are release/demo operations, not open phase work. See
[00-overview.md](00-overview.md) for phase responsibilities and [system-components.md](system-components.md)
for the component inventory.

## Phases

| Phase | Title | Status |
|-------|-------|--------|
| 0 | [Documentation and governance](phase-0-documentation-and-governance.md) | Done |
| 1 | [hostbootstrap-core scaffolding](phase-1-hostbootstrap-core-scaffolding.md) | Done |
| 2 | [Host tools and config](phase-2-host-tools-and-config.md) | Done |
| 3 | [Ensure reconcilers](phase-3-ensure-reconcilers.md) | Done |
| 4 | [Project-local Dhall and command tree](phase-4-skeletal-dhall-and-command-tree.md) | Done |
| 5 | [Cluster lifecycle and resource cordoning](phase-5-cluster-lifecycle-and-resource-cordoning.md) | Done |
| 6 | [Base image and thin Python bootstrapper](phase-6-base-image-and-thin-python-bootstrapper.md) | Done |
| 7 | [Consumer adoption](phase-7-consumer-migration.md) | Done |
| 8 | [Dhall generation and the four-stream extension](phase-8-dhall-generation-and-extension.md) | Done |
| 9 | [Applied budget cordon and one canonical parser](phase-9-applied-cordon-and-one-parser.md) | Done |
| 10 | [Standardized test harness and run-models](phase-10-standardized-test-harness.md) | Done |
| 11 | [incus first-class host-provider](phase-11-incus-host-provider.md) | Active |
| 12 | [Layered warm store](phase-12-layered-warm-store.md) | Done |
| 13 | [hostbootstrap-demo worked app](phase-13-hostbootstrap-demo.md) | Active |
| 14 | [Composable-operation algebra and composition methodology](phase-14-composition-methodology.md) | Active |
| 15 | [Binary context config and command gating](phase-15-binary-context-config.md) | Active |

## Governance

- [development_plan_standards.md](development_plan_standards.md) defines how the plan is organized,
  updated, and kept aligned with implementation and the governed `documents/` suite.
- [00-overview.md](00-overview.md) tells the cross-phase narrative and names the dependency edges.
- [system-components.md](system-components.md) is the authoritative inventory of host-management
  components.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) is the cleanup ledger for obsolete
  compatibility surfaces.

## Validation Policy

This repository does not use `.github/` workflows or GitHub Actions as a validation surface. The
supported gate is the project's canonical code-check, run on every base and derived image build (see
[development_plan_standards.md § R](development_plan_standards.md)). The mechanical documentation
validator (`HostBootstrap.DocValidator`) runs through the canonical code-check
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
