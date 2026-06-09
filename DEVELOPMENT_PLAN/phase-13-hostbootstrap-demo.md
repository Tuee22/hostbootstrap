# Phase 13: hostbootstrap-demo Worked App

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-11-incus-host-provider.md](phase-11-incus-host-provider.md), [phase-12-layered-warm-store.md](phase-12-layered-warm-store.md)

> **Purpose**: Add a self-contained worked consumer under `demo/` whose test suite demonstrates every main
> feature end to end — centered on a from-zero pristine-host bootstrap performed inside an incus VM —
> superseding the thin `hostbootstrap-example` binary.

## Phase Status

**Status**: Blocked

**Blocked by**: phase-8 (binary-generated config), phase-9 (applied cordon), phase-10 (the harness and
run-models), phase-11 (incus), phase-12 (the layered warm store + `purescript-bridge`)

`hostbootstrap-demo` lives at `demo/` with its own static-base `hostbootstrap.dhall`, Haskell source, and
build path `demo/.build`. It extends `hostbootstrap-core` directly (L0-direct, like `mcts`) and exercises
the full surface: install-and-verify `ensure incus`, the host-provider axis, the host-native build
model, the applied budget cordons, `config schema`/`render`, the standardized harness, an idiomatic
in-Dockerfile `check-code` gate, a `purescript-bridge`/`spago` webservice and SPA, and Playwright e2e.
It supersedes `haskell/hostbootstrap-core/example/Main.hs`.

## Phase Objective

Provide the canonical worked consumer and operations runbook. The demo's point is to demonstrate
`hostbootstrap` bootstrapping a **pristine** linux host from zero: because the metal host is not pristine,
the demo orchestrates a pristine incus VM and runs the genuine first-run flow inside it
(`apt install pipx` -> `pipx install hostbootstrap` -> `hostbootstrap up`). This is a deliberate
**3-build** illustration on top of the standard host-native build (see
[development_plan_standards.md § N](development_plan_standards.md)): a metal orchestrator build plus,
inside the pristine VM, the host-native binary build (by `hostbootstrap up`) and the binary-driven
project-container build.

## Sprints

### Sprint 13.1: `demo/` skeleton and the metal orchestrator binary [Blocked]

**Status**: Blocked
**Blocked by**: phase-8
**Implementation**: `demo/hostbootstrap.dhall`, `demo/hostbootstrap-demo.cabal`, `demo/app/Main.hs`, `demo/src/HostBootstrapDemo/Commands.hs` (planned)
**Docs to update**: `documents/operations/demo_runbook.md`, `system-components.md`

#### Objective

Stand up the `demo/` tree and the metal orchestrator binary — the static-base config, the cabal package
extending `hostbootstrap-core`, and build #1.

#### Deliverables

- The `demo/` tree: static-base `hostbootstrap.dhall` (`project="hostbootstrap-demo"`,
  `resources {cpu=6, memory="10GiB", storage="40GiB"}`), the cabal package extending
  `hostbootstrap-core` via `runHostBootstrapCLI`, and the appended `demoCommands`. **Build #1** (the metal
  orchestrator) via the usual workflow.

#### Validation

- `hostbootstrap-demo --help` shows the inherited core verbs plus the demo verbs.

#### Remaining Work

None.

### Sprint 13.2: `ensure incus` and the pristine VM [Blocked]

**Status**: Blocked
**Blocked by**: phase-11, phase-13 (sprint 13.1)
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (planned)
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Drive core's `ensure incus` and spin up a budget-sized pristine `ubuntu/24.04` VM (cordon #1) via the
demo's noun-first project verbs.

#### Deliverables

- The demo groups its project verbs under nouns (`incus`/`vm`/`harbor`/`web`), distinct from the
  inherited verb-first core verbs (`ensure`/`config`/`cluster`/`test`/`check-code`): `demo incus ensure`
  (consumes core's `ensure incus`) and `demo incus vm up` spin a budget-sized pristine `ubuntu/24.04` VM
  (**cordon #1**: the VM is the wall).

#### Validation

- `incus list` shows the VM with `limits.cpu=6 / limits.memory=10GiB / root=40GiB`.

#### Remaining Work

None.

### Sprint 13.3: Pristine-host bootstrap inside the VM [Blocked]

**Status**: Blocked
**Blocked by**: phase-13 (sprint 13.2)
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (planned)
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Run the genuine first-run flow inside the from-zero VM — the headline demonstration.

#### Deliverables

- `demo vm pristine-bootstrap`: `apt install pipx` -> `pipx install` the local hostbootstrap wrapper
  (pushed into the VM) -> `hostbootstrap up`, which ensures the host toolchain prerequisites, builds the
  demo binary **host-native** (**build #2**), and execs it. The execed binary then ensures Docker
  (rebooting the VM if needed) and builds the demo container (**build #3**, the in-container `check-code`
  gate). Asserts a pristine VM reaches a runnable `hostbootstrap-demo` with no prior tooling.

#### Validation

- The harness `pristine-bootstrap` case passes from a freshly created VM; the 3-build sequence is observed.

#### Remaining Work

None.

### Sprint 13.4: kind + Harbor on the VM and image push [Blocked]

**Status**: Blocked
**Blocked by**: phase-9, phase-13 (sprint 13.3)
**Implementation**: `demo/src/HostBootstrapDemo/Harbor.hs` (planned)
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/engineering/harbor.md`

#### Objective

Bring up kind (cordon #2) and Harbor inside the VM, then push the arch-explicit image tag to the in-VM
registry.

#### Deliverables

- Inside the VM: core `cluster up` (**cordon #2**: applied `docker update` kind-node cap) + `demo harbor
  install` + `demo harbor push` of the arch-explicit image tag.

#### Validation

- The pushed tag is pullable from the in-VM Harbor; the kind node carries the budget-derived caps.

#### Remaining Work

None.

### Sprint 13.5: The webservice, SPA, and idiomatic Dockerfile [Blocked]

**Status**: Blocked
**Blocked by**: phase-12, phase-13 (sprint 13.1)
**Implementation**: `demo/src/HostBootstrapDemo/Web/{Api,Server,Bridge}.hs`, `demo/web/`, `demo/docker/Dockerfile` (planned)
**Docs to update**: `documents/engineering/derived_dockerfile.md`, `documents/languages/purescript.md`

#### Objective

Build the servant webservice, the `purescript-bridge`-fed Halogen SPA, and the idiomatic `docker/Dockerfile`
that is the reference shape derived projects copy.

#### Deliverables

- A servant `DemoApi` whose Haskell types feed both JSON and `purescript-bridge`; a Halogen SPA
  (Overview/Budget/Status tabs); the idiomatic `docker/Dockerfile` (`FROM ${BASE_IMAGE}` -> install binary
  -> `RUN hostbootstrap-demo check-code` -> `web bridge` -> `spago build` + `esbuild` -> tini), the
  reference shape derived projects copy.

#### Validation

- `web-build` case: generated PureScript matches the servant API (round-trip); the bundle exists; the
  in-Dockerfile `check-code` gate runs before the web build.

#### Remaining Work

None.

### Sprint 13.6: Playwright on the incus host [Blocked]

**Status**: Blocked
**Blocked by**: phase-13 (sprints 13.3, 13.5)
**Implementation**: `demo/playwright/`, `demo/src/HostBootstrapDemo/Harness.hs` (planned)
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/languages/playwright.md`

#### Objective

Serve the webservice on the incus host and run the Playwright e2e suite from the container against the host
`baseURL`.

#### Deliverables

- `demo web serve` runs the webservice on the incus host; the Playwright runner runs from the container
  against the host `baseURL` (the e2e target is the incus host, not the kind cluster).

#### Validation

- The `e2e-tabs` case: all tabs render and `/api/budget` returns the `fitsBudget` view.

#### Remaining Work

None.

### Sprint 13.7: Retire `example/Main.hs` [Blocked]

**Status**: Blocked
**Blocked by**: phase-13 (sprint 13.1)
**Implementation**: `haskell/hostbootstrap-core/example/Main.hs`, `haskell/hostbootstrap-core/hostbootstrap-core.cabal` (planned)
**Docs to update**: `documents/engineering/derived_project_standards.md`, `legacy-tracking-for-deletion.md`

#### Objective

Retire the `hostbootstrap-example` executable and `example/`, re-point the "worked example" references at
`demo/`, and record the removal in the legacy ledger.

#### Deliverables

- Remove the `hostbootstrap-example` executable stanza and `example/`; re-point the "worked example"
  references at `demo/`; record the removal in the legacy ledger.

#### Validation

- `cabal build all` succeeds without the example stanza; no doc links to `example/Main.hs` remain.

#### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/derived_dockerfile.md` - the idiomatic derived Dockerfile (in-Dockerfile
  `check-code` gate; the `purescript-bridge` -> `spago` -> `esbuild` web build; the build-stage ordering).

**Operations docs to create/update:**
- `documents/operations/demo_runbook.md` - the a-j pristine-bootstrap flow, the feature-to-case table, and
  the 3-builds-vs-standard-host-native-build explanation.

**Cross-references to add:**
- `documents/engineering/harbor.md`, `documents/languages/purescript.md`,
  `documents/languages/playwright.md`, and `documents/engineering/derived_project_standards.md` reference
  the demo.
- `system-components.md` adds the `hostbootstrap-demo` worked-consumer subsection.
- `legacy-tracking-for-deletion.md` records the `example/Main.hs` removal.
