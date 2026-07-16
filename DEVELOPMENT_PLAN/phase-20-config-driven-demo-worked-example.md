# Phase 20: Config-Driven Demo Worked Example and Multi-Variant Harness

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [development_plan_standards.md](development_plan_standards.md), [phase-13-hostbootstrap-demo.md](phase-13-hostbootstrap-demo.md), [phase-18-service-runtime-command.md](phase-18-service-runtime-command.md), [phase-19-generic-project-model.md](phase-19-generic-project-model.md)

> **Purpose**: Demonstrate the generic project model end to end by adding a **project-owned config field**
> to the demo — a `message` string that flows from the parent-derived `<project>.dhall` through a
> dynamically rendered in-cluster ConfigMap, the `Web` service, and the SPA — plus a **multi-variant** test
> run and **polymorphic** Playwright assertion, proving that a project adds config fields and a
> config-driven workload with **no core config shape change**.

## Phase Status

**Status**: Done

Phase 20 is **implemented and validated**. At phase close it was code-check-validated (core 238 + demo
13, `cabal build all --ghc-options=-Werror` clean) and real-run-validated 2026-06-23 (`test run all`
reported `6/6 passed` across the two message variants `"Hello, world!"` and `"Hello, Universe!"`, each a
full `project up` → assert → `project destroy` with full teardown and spin-up between, with polymorphic
e2e asserting the correct `#message`). Those counts and the `6/6` are historical phase-close evidence.
The current dynamic-config implementation remains covered by the repository-wide 364-core / 87-demo
static suites; no later live matrix result is inferred from that evidence. It builds **forward** on the demo (phase 13), the `service` command
(phase 18), and the generic project model (phase 19); it reopened nothing. The demo's `message` is a
field on the **demo's own `cfg`** (the concrete type phase 19 sprint 19.2 demoted out of core), never a
core-owned field or a generic `extra` slot. The multi-variant test run reuses phase 19's
harness-generated-config flow (sprint 19.3).

This is the **worked-example** half of the generic-project-model story: phase 19 makes the library
generic; phase 20 proves it by having the demo exercise a project-defined config field and a
config-driven, redeployed workload. Validation substrate: **linux-cpu** (the two-cluster real run on
native Incus/Linux; both machine types can validate linux-cpu, and the apple-silicon/Lima path is the
symmetric alternative).

## Motivation

The demo exercises the generic project model by adding its **own** field and threading it through a real
workload without adding that field to `hostbootstrap-core`. It also serves as the harness's multi-config
demonstration:

- A single `message : Text` field on the demo's `cfg` is the smallest field that visibly proves the
  contract. The operator edits it in `hostbootstrap-demo.dhall`; it renders on the served page.
- The field only earns its keep if the harness can **redeploy** the stack with a different value and
  assert the difference. That is the multi-variant test run: spin up the default `"Hello, world!"`
  cluster, tear it down, spin up a harness-generated `"Hello, Universe!"` cluster, and have the same
  Playwright spec assert whichever message the active deployment set.

The deployer projects the service config from the actual parent config, renders the whole file (including
`message`), dynamically applies its **ConfigMap**, and hashes the exact mounted bytes into the pod
template. The chart does not own a static ConfigMap or receive `message` as a Helm value. The fixed
`ServiceHandler` remains an `IO ()` action; config-selected `service run` chooses the handler, and
`serveWeb` reads and validates its own effective config before serving `BudgetView.message`.

## Sprints

### Sprint 20.1: Demo `message` config field and config → SPA path [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/` (the demo `cfg`), `Web/Api.hs`, `web/src/Main.purs`
**Docs to update**: `documents/engineering/schema.md`, `documents/architecture/binary_context_config.md`, `documents/languages/purescript.md`

#### Objective

Add a mandatory `message : Text` field to the demo's own config type and surface it on the SPA: extend
`BudgetView` with `message`, set it from the config in the served `/api/budget` response, and render it in
the Halogen SPA under a stable `#message` element. The PureScript bridge regenerates `BudgetView` so the
SPA cannot drift from the API.

#### Deliverables

- `message : Text` on the demo `cfg`; the demo's `psInit` default is `"Hello, world!"` (no core default).
- `BudgetView.message`; the SPA renders `#message`; the bridge round-trip stays byte-stable.

#### Validation

`cabal test all`; in-container `web-build` asserts the bundle carries the message render. Validation
substrate: linux-cpu (code-check + in-container build).

#### Remaining Work

Done — the demo `cfg` carries `message : Text` (default `"Hello, world!"`), `BudgetView.message` is set
from the config and rendered under the SPA `#message`, validated 2026-06-23 (`test run all` 6/6).

### Sprint 20.2: Service reads its effective config; dynamic ConfigMap delivery [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs` / `Command.hs` (the fixed handler contract and config-selected dispatch), `demo/src/HostBootstrapDemo/Commands.hs`, `demo/src/HostBootstrapDemo/Config.hs`, `demo/src/HostBootstrapDemo/Web/Server.hs`, `demo/chart/templates/deployment.yaml`
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`, `documents/architecture/run_models.md`, `documents/engineering/cluster_lifecycle.md`, `documents/operations/demo_runbook.md`

#### Objective

Thread `message` to the running pod without coupling core to the demo config. The fixed
`ServiceHandler` action stays `IO ()`: config-selected `service run` resolves the handler, and `serveWeb`
loads its own effective project config and renders `message`. The demo's deploy action renders the actual
parent-derived service config, creates and applies its ConfigMap manifest dynamically, and passes Helm the
current frame, exact config-byte hash, and placement. This is a project-owned realization of the Phase 18
handler/config-selector and Phase 5/16 deployment seams.

#### Deliverables

- `ServiceHandler` remains an `IO ()` action; `serveWeb` loads the effective config, validates the selected
  `Web` payload, and reads `message` from that config.
- `renderServiceConfigForContext` produces the full parent-derived service config;
  `serviceConfigMapManifest` wraps those exact bytes in the generated ConfigMap; `deployChartAction`
  applies it before Helm.
- The pod-template config-hash annotation fingerprints the exact mounted bytes. Helm values carry only
  chart/runtime controls (current frame, config hash, and placement), not the project-owned message.

#### Validation

Static config round-trip/manifest tests assert both message values survive projection, the generated
ConfigMap contains the rendered config, and changing the mounted bytes changes the rollout hash.
Historical live evidence is the 2026-06-23 Linux run in which the web pod served each configured message.

#### Remaining Work

None. `serveWeb` reads `message` from its effective config; the deployer dynamically renders and applies
the complete parent-derived service config and exact-byte rollout hash. The 2026-06-23 `6/6` result is
retained as historical live message-flow evidence; current delivery mechanics are covered statically and
do not create a new live claim.

### Sprint 20.3: Multi-variant demo test run (two clusters) [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (the demo `TestSuite` / case matrix)
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/testing.md`, `documents/operations/demo_runbook.md`

#### Objective

Extend the demo's harness to run **two config variants** in one `test run all`: the default
`"Hello, world!"` deployment and a harness-generated `"Hello, Universe!"` deployment. Each variant is a
full `project up` → assert → `project destroy`, with the entire cluster torn down and spun up between
variants. The harness builds each variant's config functionally via the project-owned builder (reusing
`psInit`/`psTestConfig`, phase 19), never by shelling the CLI.

#### Deliverables

- The demo `TestSuite` declares the two message variants; `runMatrix` drives each variant's bring-up,
  assertions, and teardown; durable test data stays under `.test_data`, never `.data`.

#### Validation

`test run all` runs both variants green on native Incus/Linux. Validation substrate: linux-cpu (the
two-cluster real run, ~1–1.5h; the apple-silicon/Lima path is the symmetric alternative).

#### Remaining Work

Done — the demo `TestSuite` declares the two message variants (`"Hello, world!"`, `"Hello, Universe!"`)
and `runMatrix` drives each variant's bring-up, assertions, and teardown with full spin-up between,
validated 2026-06-23 (`test run all` 6/6).

### Sprint 20.4: Polymorphic Playwright assertion [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (`assertE2EInVM`), `demo/playwright/tests/demo.spec.ts`
**Docs to update**: `documents/languages/playwright.md`, `documents/operations/demo_runbook.md`

#### Objective

Make the `e2e-tabs` Playwright case **polymorphic**: the harness exports the active variant's message as
`EXPECTED_MESSAGE` into the container, and the spec asserts the SPA `#message` element matches whatever the
active deployment set, on all three browser engines — so one spec validates both variants.

#### Deliverables

- `assertE2EInVM` passes `-e EXPECTED_MESSAGE=<msg>`; `demo.spec.ts` reads `process.env.EXPECTED_MESSAGE`
  and asserts `#message`.

#### Validation

`test run all` e2e passes for both messages. Validation substrate: linux-cpu.

#### Remaining Work

Done — `assertE2EInVM` passes `-e EXPECTED_MESSAGE=<msg>` and `demo.spec.ts` reads
`process.env.EXPECTED_MESSAGE` and asserts the SPA `#message` per variant on all three engines,
validated 2026-06-23 (`test run all` 6/6).

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` — config-selected dispatch retains the generic
  `IO ()` handler contract; project handlers load their own effective config
- `documents/architecture/run_models.md` — the service-role run-model selects from config and the handler
  reads its dynamically delivered effective config
- `documents/architecture/binary_context_config.md` — `message` as a project-extended Parameters-layer field

**Engineering docs to create/update:**
- `documents/engineering/schema.md` — the demo `cfg` gains a `message` field (project-defined, not core)
- `documents/engineering/cluster_lifecycle.md` — the project deployer renders/applies the service ConfigMap
  and fingerprints the exact mounted config bytes; Helm does not receive `message`

**Cross-references to add:**
- `documents/operations/demo_runbook.md` — the `message` flow + the two-variant run + polymorphic e2e
- `documents/languages/playwright.md` — the polymorphic `EXPECTED_MESSAGE` assertion
- `documents/languages/purescript.md` — `BudgetView.message` keeps the SPA in sync with the API
- align the `phase-13` / `phase-18` / `phase-19` and `README` entry points
