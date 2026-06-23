# Phase 20: Config-Driven Demo Worked Example and Multi-Variant Harness

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [development_plan_standards.md](development_plan_standards.md), [phase-13-hostbootstrap-demo.md](phase-13-hostbootstrap-demo.md), [phase-18-service-runtime-command.md](phase-18-service-runtime-command.md), [phase-19-generic-project-model.md](phase-19-generic-project-model.md)

> **Purpose**: Demonstrate the generic project model end to end by adding a **project-owned config field**
> to the demo — a `message` string that flows `<project>.dhall` → the in-cluster ConfigMap → the `Web`
> service → the SPA — and a **multi-variant** test run that stands up two full clusters with different
> messages and a **polymorphic** Playwright assertion, proving that a project adds config fields and a
> config-driven workload with **no core change**.

## Phase Status

**Status**: Done

Phase 20 is **implemented and validated**. It is code-check-validated (core 238 + demo 13, `cabal build
all --ghc-options=-Werror` clean) and real-run-validated 2026-06-23 (`test run all` reported `6/6
passed` across the two message variants `"Hello, world!"` and `"Hello, Universe!"`, each a full `project
up` → assert → `project destroy` with full teardown and spin-up between, the polymorphic e2e asserting
the correct `#message` per variant). It builds **forward** on the demo (phase 13), the `service` command
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

The demo today serves a static page. It does not exercise the one thing the generic project model makes
possible: a project adding its **own** config field and threading it through a real workload, with no
change to `hostbootstrap-core`. A worked example closes that gap and doubles as the harness's
multi-config demonstration:

- A single `message : Text` field on the demo's `cfg` is the smallest field that visibly proves the
  contract. The operator edits it in `hostbootstrap-demo.dhall`; it renders on the served page.
- The field only earns its keep if the harness can **redeploy** the stack with a different value and
  assert the difference. That is the multi-variant test run: spin up the default `"Hello, world!"`
  cluster, tear it down, spin up a harness-generated `"Hello, Universe!"` cluster, and have the same
  Playwright spec assert whichever message the active deployment set.

The web pod reads its config from the chart **ConfigMap** (not the operator's host config), and the
`service run web` handler today loads its config through the gate and then **discards** it, so the field
needs two real wirings: the ConfigMap must template the message, and the service handler must read the
config it is handed.

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

### Sprint 20.2: Service handler reads its config; ConfigMap message templating [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs` / `Command.hs` (the handler contract), `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs` (`deployChart`), `demo/src/HostBootstrapDemo/Web/Server.hs`, `demo/chart/templates/configmap.yaml`
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`, `documents/architecture/run_models.md`, `documents/engineering/cluster_lifecycle.md`, `documents/operations/demo_runbook.md`

#### Objective

Thread the `message` to the running pod. The `ServiceHandler` action receives the validated config it is
gated on (today the gate loads then discards it), so `serveWeb` renders `message` from its own config.
`deployChart` gains a generic project extra-values parameter (helm `--set-string`), and the demo's
`deployChartAction` passes `message` from the live config into the chart ConfigMap, which templates it into
the pod's `<project>.dhall`. This is a **forward extension** of the service-handler contract (phase 18) and
the cluster-lifecycle deploy step (phase 5/16); it removes nothing.

#### Deliverables

- The service-handler action receives its config; `serveWeb` reads `message` (no bare `IO ()` discard).
- `deployChart :: HostConfig -> ClusterPlan -> [(Text, Text)] -> IO ()` (generic extra-values); the demo
  forwards `message` into a templated ConfigMap.

#### Validation

`cabal test all`; the live web pod serves the configured message. Validation substrate: linux-cpu (the
real `project up` web reachability on native Incus/Linux).

#### Remaining Work

Done — `serveWeb` reads `message` from its delivered config, `deployChart` gained a generic project
extra-values parameter (helm `--set-string`, with commas backslash-escaped in the value), and the demo
forwards `message` into a templated ConfigMap, validated 2026-06-23 (`test run all` 6/6).

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
- `documents/architecture/hostbootstrap_core_library.md` — the service handler receives its config
- `documents/architecture/run_models.md` — the service-role run-model reads its delivered config
- `documents/architecture/binary_context_config.md` — `message` as a project-extended Parameters-layer field

**Engineering docs to create/update:**
- `documents/engineering/schema.md` — the demo `cfg` gains a `message` field (project-defined, not core)
- `documents/engineering/cluster_lifecycle.md` — `deployChart` forwards project extra-values into the ConfigMap

**Cross-references to add:**
- `documents/operations/demo_runbook.md` — the `message` flow + the two-variant run + polymorphic e2e
- `documents/languages/playwright.md` — the polymorphic `EXPECTED_MESSAGE` assertion
- `documents/languages/purescript.md` — `BudgetView.message` keeps the SPA in sync with the API
- align the `phase-13` / `phase-18` / `phase-19` and `README` entry points
