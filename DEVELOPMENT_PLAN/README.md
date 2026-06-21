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

Phases 0-15 built the host-management substrate, validated by the full real demo lifecycle (a real Apple
Silicon Lima run reporting `3/3 passed` including the Playwright e2e case): Apple Silicon uses a Lima VM,
native Linux uses Incus, and the Dhall context model carries explicit execution topology with runtime
witnesses. Each project binary reads a sibling `<project>.dhall`; host, VM, image-build container, runtime
container, and service copies use the same filename rule while authority lives inside the file content.

The command topology is the **chain-is-the-project** model: a project's deploy is a pure
`chain :: RootConfig -> [Step]` value interpreted **recursively** by one `project init|up|down|destroy`
lifecycle command, with a read-only `context` introspection command and a `test` surface (see
[development_plan_standards.md § Y/§ Z](development_plan_standards.md) and
[composition_methodology](../documents/architecture/composition_methodology.md)). Each frame transition is
the same fractal bootstrap — provision the frame, build the pb in it, hand off `pb project up` — of which
the Python bootstrapper is the metal-frame instance.

The **unified-harness / fixed-surface / resource-SSoT** correction (phases 10, 13, 14, 15, 16, 17, 18) is
**complete — all phases are `Done`**. The command surface is **fixed** to `project` / `test` / `service` /
`context` / `check-code` (no per-project verbs; `hostbootstrap-core` is a library of composable tools, § P);
the test harness **drives the real `project up`** under the test surface rather than re-expressing bring-up
(§ W); the declared budget is the **one ceiling = the VM wall** with the cluster a **slice within it** (no
doubling, § O); each `<project>.dhall` carries an explicit, possibly multi-role context (`project init
--also-role`, § X); and long-running roles run through the `service` command (§ AA). It is code-check- and
real-run-validated: `cabal test all` (226), `cabal build all --ghc-options=-Werror`, fourmolu/hlint on the
demo, and the Python gate are green. The **full `project up` lifecycle runs end-to-end on both native
Incus/Linux and a 16 GiB Apple-Silicon host** — the live stack serves HTTP 200 (8-pod Harbor on `arm64` via
the dual-arch `ghcr.io/octohelm/harbor/*` images, the web pod running `service run web`). `test run all`
reports **`3/3 passed` on both** Apple-Silicon/Lima (2026-06-20) and native Incus/Linux (2026-06-21): every
case (incl. the two reachability checks and the Playwright e2e) runs in the **VM frame** via the
self-reference lift, so it reaches the in-cluster NodePort regardless of whether the provider forwards the
guest port to the host (see
[phase-17](phase-17-chain-driven-test-and-context-introspection.md)). The two formerly-noted
follow-ups are now **delivered**: `test.dhall` is a reflected record carrying per-test resource overrides
(`TestConfig`, written by `test init`, read by `test run`), and the demo's SPA is described as typed Dhall
data (the `demoWebApp` schema-gen artifact). The only remaining aspirational item is generating the SPA's
source *from* that spec (full SPA codegen), tracked as a vision note in
[composition_patterns.md](../documents/engineering/composition_patterns.md), not open phase work. The flat
`cluster` / `config init` / `context create` verbs, the demo `vm` / `incus` / `web` verbs, the
`ProjectCommand` extension, the harness bring-up mirror, and the budget-doubling VM sizing are superseded
([legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md)).

The **generic-project-model** correction (phase 19, § BB) is **newly reopened and documentation-only**.
`hostbootstrap-core` is to become a generic library with **no hardcoded defaults**, parameterized over a
project's own config type (`ProjectSpec cfg tcfg`): defaults live only in a project-owned `psInit`, `project
init` and the test harness share that one builder (DRY), the harness **generates** the run's `<project>.dhall`
from a thin `test.dhall` override, and a pure `SecretRef` vocabulary keeps a secrets-strict consumer's
production configs plaintext-free. Phases 4, 8, 10, 15, and 17 are reopened (`Active`) because their `Done`
scope assumed core-owned defaults, a fixed universal config type, and a `test`-reuses-existing-config flow;
phase 19 (`Planned`) owns the work and the superseded surfaces are listed in
[legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md). See
[phase-19-generic-project-model.md](phase-19-generic-project-model.md) and
[generic_project_model](../documents/architecture/generic_project_model.md).

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
| 4 | [Project-local Dhall and command tree](phase-4-skeletal-dhall-and-command-tree.md) | Active |
| 5 | [Cluster lifecycle and resource cordoning](phase-5-cluster-lifecycle-and-resource-cordoning.md) | Done |
| 6 | [Base image and thin Python bootstrapper](phase-6-base-image-and-thin-python-bootstrapper.md) | Done |
| 7 | [Consumer adoption](phase-7-consumer-migration.md) | Done |
| 8 | [Dhall generation and the extension contract](phase-8-dhall-generation-and-extension.md) | Active |
| 9 | [Applied budget cordon and one canonical parser](phase-9-applied-cordon-and-one-parser.md) | Done |
| 10 | [Standardized test harness and run-models](phase-10-standardized-test-harness.md) | Active |
| 11 | [incus first-class host-provider](phase-11-incus-host-provider.md) | Done |
| 12 | [Layered warm store](phase-12-layered-warm-store.md) | Done |
| 13 | [hostbootstrap-demo worked app](phase-13-hostbootstrap-demo.md) | Done |
| 14 | [Composable-operation algebra and composition methodology](phase-14-composition-methodology.md) | Done |
| 15 | [Binary context config and command gating](phase-15-binary-context-config.md) | Active |
| 16 | [Project lifecycle command and step-chain interpreter](phase-16-project-lifecycle-command.md) | Done |
| 17 | [Chain-driven test surface and context introspection](phase-17-chain-driven-test-and-context-introspection.md) | Active |
| 18 | [Service runtime command](phase-18-service-runtime-command.md) | Done |
| 19 | [Generic project model and no core defaults](phase-19-generic-project-model.md) | Planned |

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
