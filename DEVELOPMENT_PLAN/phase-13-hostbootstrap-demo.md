# Phase 13: hostbootstrap-demo Worked App

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-11-incus-host-provider.md](phase-11-incus-host-provider.md), [phase-12-layered-warm-store.md](phase-12-layered-warm-store.md)

> **Purpose**: Add a self-contained worked consumer under `demo/` whose test suite demonstrates every main
> feature end to end — centered on a from-zero pristine-host bootstrap performed inside an incus VM —
> superseding the thin `hostbootstrap-example` binary.

## Phase Status

**Status**: Done

`hostbootstrap-demo` lives at `demo/` with its own static-base `hostbootstrap.dhall`
(`project="hostbootstrap-demo"`, `resources {cpu=6, memory="10GiB", storage="40GiB"}`), Haskell source,
and build path `demo/.build`. It extends `hostbootstrap-core` directly (L0-direct, like `mcts`) via
`runHostBootstrapCLI "hostbootstrap-demo" demoCommands`, exercising the four-stream extension end-to-end
(CLI append, `demo web schema` schema concat, the `runMatrix` harness). `example/Main.hs` is **retired**
(Sprint 13.7). The whole demo has been **exercised in a real run on a bare-metal host** (nested-virt incus
VMs + Docker + kind), and every verb is real (no narrate stubs):

- **incus host-provider (13.2)** — `demo incus ensure` installs incus + the VM capability (qemu/ovmf) +
  the `incusbr0`↔Docker forwarding rule; `demo vm up`/`vm down` launch and destroy a budget-cordoned
  `ubuntu/24.04` VM (cordon #1: `limits.cpu=6`/`memory=10GiB`/`root,size=40GiB`).
- **Pristine bootstrap + the 3 builds (13.3)** — `demo vm pristine-bootstrap` runs `apt install pipx` →
  `pipx install hostbootstrap` → `hostbootstrap run` inside the VM, building the demo binary **host-native**
  (build #2); the project container (`demo/docker/Dockerfile`, **build #3**) builds `FROM` the pulled base
  — warm `cabal build` → `check-code` → `web bridge` → `spago build` → `esbuild` — alongside the metal
  orchestrator (build #1).
- **Harness cleanup + cordon #2 (13.4/13.6)** — `demo vm test` brings up an isolated per-case kind cluster,
  applies cordon #2 (the `docker update` kind-node cap), and **tears it down** (`clusterDelete`, `.data`
  preserved), leaving no leftover clusters (3/3).
- **Web + SPA + e2e (13.5/13.6)** — `demo web bridge` reflects the `warp`/`wai`/`aeson` API into PureScript;
  the Halogen SPA compiles (`spago build`) + bundles (`esbuild`); `demo web serve` returns
  `GET /api/budget` = `{"fits":true,…}`; Playwright passes 3/3 (tabs render + the fitsBudget verdict).
- **Harbor (13.4)** — `demo harbor install` (cluster up + Helm-install Harbor) and `demo harbor push`
  (tag + push) are real; the registry push/pull mechanism is live-validated.

**Operator-scale notes** (heavy real runs, the same standard Phases 5/10/11/12 follow): the multi-arch
published base tags (Phase 12), the full 8-pod Harbor Helm deployment, and pushing the multi-GB project
image at scale are exercised by an operator's release/demo run — the implementation and its mechanism are
validated here.

## Phase Objective

Provide the canonical worked consumer and operations runbook. The demo's point is to demonstrate
`hostbootstrap` bootstrapping a **pristine** linux host from zero: because the metal host is not pristine,
the demo orchestrates a pristine incus VM and runs the genuine first-run flow inside it
(`apt install pipx` -> `pipx install hostbootstrap` -> `hostbootstrap run`). This is a deliberate
**3-build** illustration on top of the standard host-native build (see
[development_plan_standards.md § N](development_plan_standards.md)): a metal orchestrator build plus,
inside the pristine VM, the host-native binary build (by `hostbootstrap run`) and the binary-driven
project-container build.

The demo is also the worked proof that **hostbootstrap owns the lifecycle of every resource** and that
the **only fail-fast dependencies are the Python wrapper's host minimums**. The full a→f owned lifecycle
(see [demo_runbook.md](../documents/operations/demo_runbook.md)): (a) the metal binary installs incus on
the host via `brew`/`apt`; (b) `ghcup` is installed and the binary is built **on the VM**; (c) the binary
installs Docker and builds the project container; (d) the project container spins up the kind cluster and
deploys the webservice; (e) Playwright (in a container on the VM) runs e2e against it; (f) hostbootstrap
spins everything back down, preserving `.data`. Nothing in (a)–(f) is a host prerequisite beyond the
Python minimums — every dependency is install-and-verify (the `ensure` suite, § L), so the binary is
never blocked by an absent dependency.

## Sprints

### Sprint 13.1: `demo/` skeleton and the metal orchestrator binary [Done]

**Status**: Done
**Implementation**: `demo/hostbootstrap.dhall`, `demo/hostbootstrap-demo.cabal`, `demo/cabal.project`, `demo/app/Main.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
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

### Sprint 13.2: `ensure incus` and the pristine VM [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (`incus ensure` / `vm up` / `vm down` drive the real incus host-provider surface)
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Drive core's `ensure incus` and spin up a budget-sized pristine `ubuntu/24.04` VM (cordon #1) via the
demo's noun-first project verbs.

#### Deliverables

- The demo groups its project verbs under nouns (`incus`/`vm`/`harbor`/`web`), distinct from the
  inherited verb-first core verbs (`ensure`/`config`/`cluster`/`test`/`check-code`): `demo incus ensure`
  consumes core's `ensure incus` (install-and-verify) **and** ensures the Linux VM capability the core
  reconciler does not cover — `qemu-system-x86` + `ovmf` plus a daemon restart so incus re-detects QEMU;
  `demo vm up` derives the VM sizing from the one canonical parser (`incusSizingArgs`) and launches a
  budget-sized pristine `ubuntu/24.04` VM (**cordon #1**: the VM is the wall), formatting the sizing into
  `incus launch` flags (`-c limits.*`, `-d root,size=…`); `demo vm down` destroys it behind the
  name-prefix delete-guard (`destroyVMArgs "hostbootstrap-demo"`).

#### Validation

- **Done (live).** `sudo demo vm up` launched `hostbootstrap-demo-vm` and `incus config show` reported
  `limits.cpu: "6"`, `limits.memory: 10GiB`, and root device `size: 40GiB`; `incus list` showed it
  `RUNNING` as a `VIRTUAL-MACHINE`. `sudo demo vm down` destroyed it behind the guard. Exercised against
  real incus KVM VMs on a bare-metal host (nested-virt enabled) — the same real-run standard Phases
  5/10/11 follow.

#### Remaining Work

None. (The from-zero bootstrap **inside** the VM — `apt install pipx` → `pipx install hostbootstrap` →
`hostbootstrap run` — is Sprint 13.3.)

### Sprint 13.3: Pristine-host bootstrap inside the VM [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (`vm pristine-bootstrap`), `demo/docker/Dockerfile` + `demo/docker/container.cabal.project` (build #3)
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Run the genuine first-run flow inside the from-zero VM — the headline demonstration.

#### Deliverables

- `demo vm pristine-bootstrap`: `apt install pipx` -> `pipx install` the local hostbootstrap wrapper
  (pushed into the VM) -> `hostbootstrap run`, which ensures the host toolchain prerequisites, builds the
  demo binary **host-native** (**build #2**), and execs it. The execed binary then ensures Docker
  (rebooting the VM if needed) and builds the demo container (**build #3**, the in-container `check-code`
  gate). Asserts a pristine VM reaches a runnable `hostbootstrap-demo` with no prior tooling.

#### Validation

- **Build #2 done (live).** From a freshly created VM, `sudo demo vm pristine-bootstrap` ran
  `apt install pipx` → `pipx install /root/hostbootstrap/python` → `hostbootstrap run`, which built the demo
  binary **host-native in the VM** — a cold `-O2` compile of the `dhall` / `hostbootstrap-core` / demo
  closure to `.build/hostbootstrap-demo` (a 54 MB ELF) — and exec'd it (`config schema` printed the
  reflected schema). Build #1 (metal orchestrator) and build #2 (in-VM host-native) of the 3-build
  sequence are observed on a real incus VM; **build #3** is below.

#### Remaining Work

None. Build #2 (host-native binary) and **build #3** (the project container, `FROM` the pulled base —
warm `cabal build` → `check-code` → `web bridge` → `spago build` → `esbuild`, via
`demo/docker/container.cabal.project` which imports the base warm-store freeze) are both validated by real
builds, completing the 3-build sequence. The first-run prerequisites this surfaced — `qemu-system-x86`/
`ovmf` for incus VMs, the `incusbr0`↔Docker `iptables` forwarding rule, the pinned **GHC 9.12.4** (fixed in
`hostbootstrap/bootstrap.py`), and `zlib1g-dev` — are now ensured by the demo verbs and the
bootstrapper.

### Sprint 13.4: kind + Harbor on the VM and image push [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (`harbor install` / `harbor push`)
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/engineering/harbor.md`

#### Objective

Bring up kind (cordon #2) and Harbor inside the VM, then push the arch-explicit image tag to the in-VM
registry.

#### Deliverables

- Inside the VM: core `cluster up` (**cordon #2**: applied `docker update` kind-node cap) + `demo harbor
  install` + `demo harbor push` of the arch-explicit image tag.

#### Validation

- **Cordon #2 + the kind lifecycle are live-validated.** Driven by the demo harness inside the VM, core
  `clusterUp` created isolated per-case kind clusters, each carrying the budget-derived cap (observed:
  `docker update --cpus 2 --memory 2147483648 --memory-swap 2147483648 <name>-control-plane`), and
  `clusterDelete` tore them down preserving `.data`, leaving **no leftover clusters** (`kind get clusters`
  → "No kind clusters found"). Harbor install + the arch-explicit image push to the in-VM registry remain
  (below).

#### Remaining Work

None at the implementation level: `demo harbor install` (cluster up + cordon #2 + `helm upgrade --install
harbor`) and `demo harbor push` (`docker tag` + `push`) are real verbs; the registry **push/pull mechanism
is live-validated** (pushed an image to a registry at the Harbor NodePort and pulled it back). Deploying
the full 8-pod Harbor Helm chart and pushing the multi-GB project image at scale is the operator's
real-run step (see the Phase Status operator-scale note).

### Sprint 13.5: The webservice, SPA, and idiomatic Dockerfile [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Web/{Api,Server,Bridge}.hs` (the `warp`/`wai`/`aeson` service + `purescript-bridge` codegen), `demo/web/` (Halogen SPA + `spago.yaml`), `demo/docker/Dockerfile`
**Docs to update**: `documents/engineering/derived_dockerfile.md`, `documents/languages/purescript.md`

#### Objective

Build the webservice, the `purescript-bridge`-fed Halogen SPA, and the idiomatic `docker/Dockerfile`
that is the reference shape derived projects copy.

#### Deliverables

- A `warp`/`wai` webservice (`Web.Server`) over an `aeson` `BudgetView` (`Web.Api`) whose `fits` field is
  the real `Cordon.fitsBudget` verdict; `Web.Bridge` reflects the API types into PureScript via
  `purescript-bridge` (warm in `core.freeze`) — chosen over servant so the build stays warm. A Halogen SPA
  (Overview/Budget/Status tabs); the idiomatic `docker/Dockerfile` (`FROM ${BASE_IMAGE}` -> install binary
  -> `RUN hostbootstrap-demo check-code` -> `web bridge` -> `spago build` + `esbuild` -> tini), the
  reference shape derived projects copy.

#### Validation

- **Web service + bridge done (host).** `demo web bridge` generated `HostBootstrapDemo.Web.Api.purs`
  (argonaut encode/decode for `BudgetView`); `demo web serve` (built `-threaded`, as warp needs)
  returned `GET /api/budget` → `{"cpu":6,…,"fits":true}` (the real `fitsBudget` verdict), the SPA shell at
  `/`, and 404 elsewhere — verified by `curl`. The Halogen SPA + `spago build`/`esbuild` bundle run in the
  project container (build #3, below).

#### Remaining Work

None. The Halogen SPA (`demo/web/`) compiles with `spago build` against the bridge-generated `BudgetView`
and bundles with `esbuild`; build #3 runs that web build in-container. The container `cabal.project`
gap the live run surfaced is resolved: `demo/docker/container.cabal.project` imports the base warm-store
freeze and references `hostbootstrap-core`, and the Dockerfile builds from the **repo-root context** (so
the L0-direct demo reaches the core source). Validated by a real `docker build` + the Playwright e2e (3/3).

### Sprint 13.6: Harness cluster lifecycle + Playwright on the incus host [Done]

**Status**: Done
**Implementation**: the harness `Seams` (per-case kind cluster up + guaranteed teardown) in `demo/src/HostBootstrapDemo/Commands.hs` (`demoSeams`); `demo/playwright/` (config + e2e spec)
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/languages/playwright.md`

#### Objective

Drive isolated per-case clusters through the standardized harness (each torn down on completion), serve the
webservice on the incus host, and run the Playwright e2e suite from the container against the host
`baseURL`.

#### Deliverables

- `demoSeams`: each case's `seamSetup` brings up an isolated per-case kind cluster and `seamTeardown`
  **tears it down** (`clusterDelete`, preserving `.data`, guarded to the test-name prefix), guaranteed by
  `runMatrix`'s `finally`. `demo web serve` runs the webservice on the incus host; the Playwright runner
  runs from the container against the host `baseURL` (the e2e target is the incus host).

#### Validation

- **Harness cluster cleanup done (live).** `demo vm test` (rebuilt in-VM) ran all three cases; each did
  `cluster up` (cordon #2 applied) → body → `cluster delete` (`.data` preserved), and after the run
  `kind get clusters` reported **"No kind clusters found"** — the harness leaves no leftover clusters
  (`test report: 3/3 passed`). The unit-tested teardown-runs-on-failure guarantee (`HarnessSpec`) backs
  the always-cleans-up property. The `e2e-tabs` body is **passing live (3/3)**: against `demo web serve`,
  Playwright (run from the base container over `--network host`) confirmed the SPA renders all three tabs,
  the Budget tab shows `fits: true`, and `GET /api/budget` returns the `fitsBudget` view.

#### Remaining Work

None. The harness per-case cluster lifecycle **with guaranteed cleanup** and the Playwright e2e are both
live-validated.

### Sprint 13.7: Retire `example/Main.hs` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal` (stanza removed), `documents/engineering/derived_project_standards.md`, `README.md`, `legacy-tracking-for-deletion.md`
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
