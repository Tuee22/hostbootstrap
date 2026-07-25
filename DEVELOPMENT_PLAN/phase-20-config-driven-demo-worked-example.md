# Phase 20: Config-driven demo worked example

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [development_plan_standards.md](development_plan_standards.md), [phase-13-hostbootstrap-demo.md](phase-13-hostbootstrap-demo.md), [phase-18-service-runtime-command.md](phase-18-service-runtime-command.md), [phase-19-generic-project-model.md](phase-19-generic-project-model.md)

> **Purpose**: Demonstrate the generic project model end to end by adding a **project-owned config field**
> to the demo — a `message` string that flows from the parent-derived `<project>.dhall` through a
> dynamically rendered in-cluster ConfigMap, the `Web` service, and the SPA — plus a **multi-variant** test
> run and **polymorphic** Playwright assertion, proving that a project adds config fields and a
> config-driven workload with **no core config shape change**.

## Phase Status

**Status**: Blocked
**Blocked by**: Sprints 10.9, 18.6, and 19.6–19.8

**Reopened 2026-07-24.** The demo variants are hard-coded, `testSuites` is dead configuration, and the
historical message handler still reloads the full sibling config through raw `IO ()`. Sprint 20.5 owns
config-driven demo consumption and the worked-example migration after Phase 18's typed service package,
Phase 19's typed matrix/scoped assembler/opaque project spec, and Phase 10's harness-indexed execution
boundary exist.

Phase 20's original message-flow work is implemented and historically validated. At its former phase
close it was code-check-validated (core 238 + demo
13, `cabal build all --ghc-options=-Werror` clean) and real-run-validated 2026-06-23 (`test run all`
reported `6/6 passed` across the two message variants `"Hello, world!"` and `"Hello, Universe!"`, each a
full `project up` → assert → `project destroy` with full teardown and spin-up between, with polymorphic
e2e asserting the correct `#message`). Those counts and the `6/6` are historical phase-close evidence;
no later live matrix result is inferred from them. It builds on the demo (phase 13), the `service` command
(phase 18), and the generic project model (phase 19). The demo's `message` is a
field on the **demo's own `cfg`** (the concrete type phase 19 sprint 19.2 demoted out of core), never a
core-owned field or a generic `extra` slot. The multi-variant test run reuses phase 19's
harness-generated-config flow (sprint 19.3). Sprint 20.5 reopens the phase because those two variants are
hard-coded in Haskell and the decoded `testSuites` configuration is unused.

This is the **worked-example** half of the generic-project-model story: phase 19 makes the library
generic; phase 20 proves it by having the demo exercise a project-defined config field and a
config-driven, redeployed workload. Validation substrate: **linux-cpu** (the two-cluster real run on
native Incus/Linux; both machine types can validate linux-cpu, and the apple-silicon/Lima path is the
symmetric alternative).

## Remaining Work

Sprint 20.5 is Blocked by Sprints 10.9, 18.6, and 19.6–19.8. Once the typed matrix, scoped assembler,
typed selected-service package, finalized project-spec APIs, and harness-indexed execution boundary
land, generate the demo variants entirely from decoded `<project>.test.dhall`, migrate Web message
delivery to config-ID-bound filtered role parameters, remove the hard-coded message list/dead
`testSuites` field, and prove a config-only third variant runs without a Haskell edit.

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

The current deployer projects the service config from the actual parent config, renders a full demo
record (including `message`), dynamically applies its **ConfigMap**, and hashes the exact mounted bytes
into the pod template. The chart does not own a static ConfigMap or receive `message` as a Helm value.
At the historical landing, `ServiceHandler` was an `IO ()` action: config-selected `service run` chose
the handler, then `serveWeb` reopened and validated the effective config before serving
`BudgetView.message`. That double-read/full-record handler boundary is a current defect, not the target.
Sprint 20.5 declares `message` visible to the Web service in the project codec; Sprint 18.6 then passes
it only through `RoleParams specDigest configId secretDigest fields Web` to a closed `ServiceProgram`.
The target deployer
renders a role-specific descriptive wire rather than the full demo record, fingerprints those exact
bytes in the manifest, and the service process verifies them into a fresh child-local `configId` before
constructing its request and parameters.

## Sprints

### Sprint 20.1: Demo `message` config field and config → SPA path [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Config.hs`,
`demo/src/HostBootstrapDemo/Web/Api.hs`, `demo/web/src/Main.purs`
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

### Sprint 20.2: Historical service-config reread and dynamic ConfigMap delivery [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Service.hs` / `Command.hs` (the fixed handler contract and config-selected dispatch), `demo/src/HostBootstrapDemo/Commands.hs`, `demo/src/HostBootstrapDemo/Config.hs`, `demo/src/HostBootstrapDemo/Web/Server.hs`, `demo/chart/templates/deployment.yaml`
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`, `documents/architecture/run_models.md`, `documents/engineering/cluster_lifecycle.md`, `documents/operations/demo_runbook.md`

#### Objective

Record the historical landing that threaded `message` to the running pod without coupling core to the
demo config. At that closure the fixed `ServiceHandler` action was `IO ()`: config-selected
`service run` resolved the handler, and `serveWeb` loaded its own effective project config and rendered
`message`. The demo's deploy action rendered the actual parent-derived service config, created and
applied its ConfigMap manifest dynamically, and passed Helm the current frame, exact config-byte hash,
and placement. This is implementation history, not the post-Sprints 18.6/19.8 handler contract.

#### Deliverables

- At the historical closure, `ServiceHandler` remained an `IO ()` action; `serveWeb` loaded the
  effective config, validated the selected `Web` payload, and read `message` from that second snapshot.
- `renderServiceConfigForContext` produces the current full parent-derived service config;
  `serviceConfigMapManifest` wraps those exact bytes in the generated ConfigMap; `deployChartAction`
  applies it before Helm.
- The pod-template config-hash annotation fingerprints the exact mounted bytes. Helm values carry only
  chart/runtime controls (current frame, config hash, and placement), not the project-owned message.

#### Validation

Static config round-trip/manifest tests assert both message values survive projection, the generated
ConfigMap contains the rendered config, and changing the mounted bytes changes the rollout hash.
Historical live evidence is the 2026-06-23 Linux run in which the web pod served each configured message.

#### Remaining Work

None in this sprint's historical implementation scope. `serveWeb` currently reads `message` from its
reopened effective config; the deployer renders and applies the complete parent-derived service config
and exact-byte rollout hash. Sprint 20.5 replaces that handler boundary after Sprints 18.6/19.8. The
2026-06-23 `6/6` result is retained as historical live message-flow evidence; current delivery mechanics
are covered statically and do not create a new live claim.

### Sprint 20.3: Multi-variant demo test run (two clusters) [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (the demo `TestSuite` / case matrix)
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/testing.md`, `documents/operations/demo_runbook.md`

#### Objective

Extend the demo's harness to run **two config variants** in one `test run all`: the default
`"Hello, world!"` deployment and a harness-generated `"Hello, Universe!"` deployment. Each variant is a
full `project up` → assert → `project destroy`, with the entire cluster torn down and spun up between
variants. The harness builds each variant's config functionally via the independent project-owned
`psTestConfig` callback; the demo calls a helper also used by `psInit` by convention (phase 19). It never
shells the CLI.

#### Deliverables

- The historical demo `TestSuite` declares the two message variants and `runMatrix` drives each variant's
  bring-up, assertions, and teardown. Its path-name `.test_data` convention is not an ownership guarantee;
  Sprint 10.9 replaces it with an opaque `Harness projectId runId` profile, consuming Sprint 5.7's
  provider/storage receipts.

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

### Sprint 20.5: Config-driven demo case and variant generation [Blocked]

**Status**: Blocked
**Blocked by**: Sprints 10.9, 18.6, and 19.6–19.8
**Implementation**: `demo/src/HostBootstrapDemo/Config.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`demo/src/HostBootstrapDemo/Web/Server.hs`, `demo/app/Main.hs`,
`demo/hostbootstrap-demo.cabal`,
`demo/test/ConfigSpec.hs`,
`demo/test/CommandsSpec.hs`,
`demo/test/WebServerSpec.hs`,
`demo/test/ServiceBoundaryCompileFail.hs` (new)
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/engineering/testing.md`, `documents/engineering/schema.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Make the worked demo consume Phase 19's typed test configuration instead of hard-coding its message
variants/carrying an unused `testSuites` field, and consume the selected Web service's message through
Phase 18's filtered, config-ID-bound handler input rather than reopening the full config.

#### Deliverables

- Define the demo's typed variant records and `CaseId -> NonEmpty VariantId` references in
  `<project>.test.dhall`, including message/resource overrides. `CaseId` refers to the registered Haskell
  handler; the Dhall file does not define executable cases.
- Generate a pure validated `TestMatrix VariantDraft` from the decoded values. For each distinct variant,
  let the engine open a fresh `Harness projectId runId` lease and call the demo's `psAssemble`; adding or
  removing a variant in config changes the run without editing `demoTestSuite`.
- Remove `testSuites` and the hard-coded two-message variant list, while keeping assertions parameterized
  by the active typed variant.
- Thread the generated variants into Phase 13's harness-indexed `TestComponent` through the finalized
  opaque project specification; the harness engine remains owned by Phase 10.
- In the demo's jointly finalized field schema/role codec, include `Service Web` in `message`'s closed
  consumer set and derive the
  Web `ValidatedServiceRequest specDigest configId secretDigest fields Web` in the same child-local
  generative continuation as
  the validated mounted config. Project/deploy fields whose consumer sets omit Web cannot enter its
  role parameters; required framework control fields remain validation-only.
- Change the Web ConfigMap path to render the role-specific descriptive wire, not the full parent demo
  record. Bind its exact digest to the rollout manifest/runtime activation authority, verify the mounted
  bytes through the child-local role codec, and only then mint the fresh service `configId` and
  request. The opaque request/parameters never cross the process boundary. Sprint 18.6 applies the same
  rule to the accelerator role.
- Replace `serveWeb`'s sibling-file load and raw `IO ()` registry action with
  `RoleParams specDigest configId secretDigest fields Web -> ServiceProgram ... effects ()`; read
  `message` only from those
  parameters and package the program with the matching authorized `ServiceSelection ... effects`.

#### Validation

- Golden/round-trip tests cover at least one, two, reordered, and invalid/duplicate variants.
- A temporary third variant introduced only in `<project>.test.dhall` is discovered, run, asserted, and torn down
  without Haskell source changes.
- The selected-case and `all` demo runs report stable typed IDs and use each variant's message/resources.
- Compile-fail/TOCTOU tests prove Web cannot receive a message from another `configId`, the handler has
  no full-config/config-read escape hatch, and replacing the mounted file after selection does not alter
  the message observed by that invocation.
- Projection/golden tests prove the mounted Web wire contains its framework fields and Web parameters,
  omits host/build/deploy/accelerator-only fields, and fingerprints exactly the bytes the child verifies.

#### Remaining Work

Blocked until Sprints 10.9, 18.6, and 19.6–19.8 land the harness-indexed execution boundary, typed
selected-service package, typed matrix, scoped assembler, and validated project specification consumed
here. Then migrate the demo schema/generator/Web handler, delete the hard-coded/dead/raw-reload surfaces,
and run the config-only variant-change proof. The historical two-message `6/6` run does not demonstrate
a config-driven matrix or the target handler boundary.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` — distinguish the current raw handler/reload
  from the target config-ID/effect-indexed selected-service package
- `documents/architecture/run_models.md` — the service-role run-model selects from one validated config
  and the handler receives only its filtered role parameters
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
