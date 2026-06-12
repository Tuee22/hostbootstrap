# Phase 13: hostbootstrap-demo Worked App

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-11-incus-host-provider.md](phase-11-incus-host-provider.md), [phase-12-layered-warm-store.md](phase-12-layered-warm-store.md)

> **Purpose**: Add a self-contained worked consumer under `demo/` whose test suite demonstrates every main
> feature end to end — centered on a from-zero pristine-host bootstrap performed inside an incus VM —
> superseding the thin `hostbootstrap-example` binary.

## Phase Status

**Status**: Done

The **single-representation doctrine (§ W) is implemented and live-validated.** The demo deploy is one
explicit lift sequence whose only lifted compute step is `test all`, lifted into the project container in
the VM (`incus exec <vm> -- docker run --rm <image> test all`), so the harness runs `clusterUp` "locally"
on the VM's Docker and the kind cluster lives **in the VM** — there is no second, parallel cluster-deploy
representation (the old `Chain.hs` `cluster up`/`harbor install`/`web serve`/`e2e` ops are removed, Sprint
13.12). Validated on a real host three ways: `demo deploy --dry-run` renders the 5-step plan (step 4 folds
to `incus exec hostbootstrap-demo-vm -- docker run --rm <image> hostbootstrap-demo:local test all`); a
staged run built #2 **and #3** in the VM, then the lifted `test all` passed `3/3` with a concurrent poller
showing the kind control-plane node on the **VM's** Docker at every sampled second and **none on metal**;
and the literal `demo deploy` apply ran `ensure incus -> vm up -> pristine[#2+#3] -> lifted test all (3/3)
-> vm down`, `DEPLOY_EXIT=0`, no leftover VM, metal clean.

`hostbootstrap-demo` lives at `demo/` with its own static-base `hostbootstrap.dhall`
(`project="hostbootstrap-demo"`, `resources {cpu=6, memory="10GiB", storage="80GiB"}`), Haskell source,
and build path `demo/.build` (the host-native build's cabal package store is kept repo-local at
`demo/.build/cabal-store`, so `git clean -fxd` resets the full build state — deps included — rather
than reusing the user-global store; see
[build_and_run_model.md](../documents/architecture/build_and_run_model.md)). It extends
`hostbootstrap-core` directly (L0-direct, like `mcts`) via
`runHostBootstrapCLI "hostbootstrap-demo" demoCommands`, exercising the four-stream extension end-to-end
(CLI append, `demo web schema` schema concat, the `runMatrix` harness). `example/Main.hs` is **retired**
(Sprint 13.7). The whole demo has been **exercised in a real run on a bare-metal host** (nested-virt incus
VMs + Docker + kind), and the project verbs (`incus`/`vm`/`harbor`/`web`) are real (no narrate stubs) —
the harness *seams* are now real per-case assertions, **all three live-validated on the metal host**
(`pristine-bootstrap` and `e2e-tabs` directly on the host, `web-build` and `e2e-tabs` again in a
container **on the metal host's Docker** — originally a dev shortcut; the integrated
in-VM run where the harness lifts into the project container in the VM is now live-validated too (Sprint 13.12)):

- **incus host-provider (13.2)** — `demo incus ensure` installs incus + the VM capability (qemu/ovmf) +
  the `incusbr0`↔Docker forwarding rule; `demo vm up`/`vm down` launch and destroy a budget-cordoned
  `ubuntu/24.04` VM (cordon #1: `limits.cpu=6`/`memory=10GiB`/`root,size=80GiB`).
- **Pristine bootstrap + the 3 builds (13.3)** — `demo vm pristine-bootstrap` runs `apt install pipx` →
  `pipx install hostbootstrap` → `hostbootstrap run` inside the VM, building the demo binary **host-native**
  (build #2); the project container (`demo/docker/Dockerfile`, **build #3**) builds `FROM` the pulled base
  — warm `cabal build` → `check-code` → `web bridge` → `spago build` → `esbuild` — alongside the metal
  orchestrator (build #1).
- **Harness cluster lifecycle + cordon #2 (13.4/13.6)** — `demo test all` brings up an isolated per-case
  kind cluster, applies cordon #2 (the `docker update` kind-node cap), and **tears it down**
  (`clusterDelete`, `.data` preserved), leaving no leftover clusters. The cluster up/teardown and the
  per-case **bodies are now real assertions** (caveat below); `pristine-bootstrap` is live-validated.
- **Web + SPA (13.5)** — `demo web bridge` reflects the `warp`/`wai`/`aeson` API into PureScript;
  the Halogen SPA compiles (`spago build`) + bundles (`esbuild`); `demo web serve` returns
  `GET /api/budget` = `{"fits":true,…}`. A **manual** Playwright run against `demo web serve` passes 3/3
  (tabs render + the fitsBudget verdict); the harness `e2e-tabs` case now lifts a Playwright container
  against the in-cluster service via NodePort (caveat below).
- **Harbor (13.4)** — `demo harbor install` (cluster up + Helm-install Harbor) and `demo harbor push`
  (tag + push) are real; the registry push/pull mechanism is live-validated.

**Harness seams (landed; all three cases live-validated on the metal host).** The hollow `demoSeams` are
**replaced** by real per-case seams (Sprint 13.9): `pristine-bootstrap` asserts the live cluster,
`web-build` the bundle, `e2e-tabs` a Playwright run against the in-cluster service via NodePort; `cluster
up` deploys the webservice into the per-case cluster via `demo/chart`. `demo test pristine-bootstrap` is
**live-validated** on a real metal host (kind create → cordon → `helm upgrade --install: ok` → the
per-case assertion → clean teardown, `1/1 passed`, no leftover cluster) — the original "helm not found"
failure is fixed end to end. `e2e-tabs` is **live-validated** both directly on the metal host (the full
harness Playwright run, below) and **in a container on the metal host's Docker**
(`docker run … hostbootstrap-demo:local test e2e-tabs`, `1/1 passed`, no leftover cluster/volume);
`web-build` is **live-validated in a container on the metal host's Docker** (`docker run … test web-build`
asserts the in-image bundle, `1/1 passed`). Those in-container runs were a dev shortcut on the metal host
— kind came up on the metal host's Docker. The integrated in-VM run, where the demo deploy lifts `test all`
into the project container **in the VM** so kind comes up on the VM's Docker, is **live-validated** (Sprint
13.12 — the single-representation collapse of § W). The e2e spec is delivered
through a context-agnostic named volume (`deliverSpec`, `docker cp`), so the e2e lifts into any context.
The new `demo deploy --dry-run` (F1) and `demo role serve`/`submit` (F2) verbs are landed.
**Build #3 is live-validated:** the project container builds — the in-Dockerfile
`check-code` gate (fourmolu + hlint + warning-clean build) **passes on the refactor's new modules**
(`Lift`/`Container`/`RoleLifecycle`/`Chain`/`Role`/`Commands`) — the `spago`/`esbuild` web bundle builds
(`public/app.js`), and the image's `web serve` returns the correct `/api/budget` (`{"fits":true,…}`). The
**in-cluster deploy + NodePort path is live-validated** (an e2e probe): the 20 GB image `kind load`ed into
a real kind cluster (~2m), the chart `STATUS: deployed`, and the webservice answered `/api/budget`
(`{"fits":true,…}`) **through its NodePort** from a container on the kind network — exactly how the
Playwright container reaches it; clean teardown. The `e2e-tabs` seam encodes this (`kind load` + a NodePort
readiness wait + the Playwright run); the full harness `test e2e-tabs` (incl. the Playwright spec) is
**live-validated** (`1/1 passed`, clean teardown, source tree untouched).

**Operator-scale notes** (heavy real runs, the same standard Phases 5/10/11/12 follow): the multi-arch
published base tags (Phase 12), the full 8-pod Harbor Helm deployment, and pushing the multi-GB project
image at scale are exercised by an operator's release/demo run — the implementation and its mechanism are
validated here.

#### Completion

All sprints 13.1–13.12 are `Done`, and the **single-representation doctrine (§ W) is realized**: the demo
deploy is one explicit lift sequence whose only lifted compute step is `test all`, lifted into the project
container in the VM, so the kind cluster comes up on the **VM's** Docker — no parallel cluster-deploy
chain. Sprint 13.12 is live-validated three ways: `demo deploy --dry-run` (the 5-step plan; step 4 folds to
`incus exec <vm> -- docker run --rm <image> test all`); a staged run (build #2 **and build #3** in the VM,
then the lifted `test all` `3/3` with a concurrent poller proving the kind node was on the VM's Docker and
**none on metal**); and the literal `demo deploy` apply (`ensure incus -> vm up -> pristine[#2+#3] ->
lifted test all 3/3 -> vm down`, `DEPLOY_EXIT=0`, no leftover VM, metal clean). The earlier metal-host
in-container runs (Sprints 13.8/13.9) were a dev shortcut, superseded by the in-VM lift. The pristine
3-build bootstrap (Sprint 13.3) and the per-case seams (Sprints 13.8–13.11) are live-validated; the e2e
spec delivery is context-agnostic (`deliverSpec`); F1 (`demo deploy`) and F2 (`demo role serve`/`submit`)
are landed. These exercise Phase 11's lift and Phase 14's methodology.

**Operator-scale runs** (the same standard Phases 5/10/11/12 follow) remain an operator's release/demo
activity: the multi-arch published base tags, the full 8-pod Harbor deployment at scale, and pushing the
multi-GB project image — implementation and mechanism are validated here.

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
  `resources {cpu=6, memory="10GiB", storage="80GiB"}`), the cabal package extending
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
  `limits.cpu: "6"`, `limits.memory: 10GiB`, and root device `size: 80GiB`; `incus list` showed it
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

- **Build #2 live-validated (post-reorg, post-refactor code).** `sudo demo vm up` launched a
  budget-cordoned (cordon #1) pristine `ubuntu/24.04` VM with network egress; `sudo demo vm
  pristine-bootstrap` ran `apt install pipx` → ghcup + GHC 9.12.4 → `pipx install --force
  /root/hostbootstrap` → `hostbootstrap run`, doing a **cold, warm-store-less host-native build** of the
  full refactored closure — all 26 `hostbootstrap-core` modules (incl. the new
  `Lift`/`RoleLifecycle`/`Container`) + all 7 demo modules (`Chain`/`Role`/Web.*/Commands) — linking the
  binary and running it (`config schema` printed the reflected `budget`/`podResources`/`kindNode`
  vocabulary). The VM was then destroyed behind the name-prefix guard (`vm down`). Builds #1 (metal) and #2
  (in-VM host-native) of the 3-build sequence are live-validated; build #3 (the project container) is
  live-validated on the host.

#### Remaining Work

None. The corrected post-reorg path (`pipx install --force /root/hostbootstrap`) is **live-validated end to
end** on a real host: `vm up` (cordon #1) → the cold in-VM build of the full refactored closure → the
binary ran `config schema` → guarded `vm down`. The first-run prerequisites this surfaced —
`qemu-system-x86`/`ovmf`, the `incusbr0`↔Docker `iptables` forwarding, the pinned GHC 9.12.4, and
`zlib1g-dev` — are ensured by the demo verbs and the bootstrapper.

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

### Sprint 13.6: Harness cluster lifecycle + Playwright (in-cluster, via NodePort) [Done]

**Status**: Done
**Implementation**: the harness `Seams` (per-case kind cluster up + guaranteed teardown) in `demo/src/HostBootstrapDemo/Commands.hs` (`demoSeams`); `demo/playwright/` (config + e2e spec)
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/languages/playwright.md`

#### Objective

Drive isolated per-case clusters through the standardized harness (each torn down on completion), deploy the
webservice **into** the per-case kind cluster via `demo/chart`, and run the Playwright e2e suite from a
container on the kind network against the in-cluster service via its **NodePort**.

#### Deliverables

- `demoSeams`: each case's `seamSetup` brings up an isolated per-case kind cluster and `seamTeardown`
  **tears it down** (`clusterDelete`, preserving `.data`, guarded to the test-name prefix), guaranteed by
  `runMatrix`'s `finally`. The webservice is deployed into the per-case kind cluster via `demo/chart` (the
  pod runs `web serve`); the Playwright runner runs from a container on the kind network against the
  in-cluster service via its **NodePort** (the e2e target is the kind cluster).
- **Resolved (Sprint 13.9):** the real per-case seams and the harness-driven Playwright (a container
  lifted against the in-cluster NodePort) are landed; `e2e-tabs` is live-validated.

#### Validation

- **Harness cluster lifecycle + cleanup done (live).** `demo test all` (rebuilt in-VM) ran all three
  cases; each did `cluster up` (cordon #2 applied) → body → `cluster delete` (`.data` preserved), and
  after the run `kind get clusters` reported **"No kind clusters found"** — the harness leaves no leftover
  clusters (`test report: 3/3 passed`). The unit-tested teardown-runs-on-failure guarantee (`HarnessSpec`)
  backs the always-cleans-up property. The per-case bodies are **real assertions**. **`demo test e2e-tabs`
  is live-validated end to end on a real host:** `cluster up` (chart deployed) → `kind load` the project
  image → NodePort readiness → a Playwright container runs `demo/playwright` against the in-cluster service
  via its NodePort, all 3 specs green (tabs render, the Budget tab shows `fits: true`, `GET /api/budget`
  returns `fits:true`) → clean teardown (`1/1 passed`, no leftover cluster, source tree untouched).

#### Remaining Work

None. The harness cluster lifecycle, the real per-case seams, and the harness-driven Playwright
(`e2e-tabs`) are live-validated.

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

### Sprint 13.8: Wire the demo through the self-reference lift [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/src/HostBootstrap/Lift.hs`
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/architecture/composition_methodology.md`

#### Objective

Replace `runVmBootstrap`'s hand-rolled `bash -lc` self-reference and the host-process `clusterUp` call
with `HostBootstrap.Lift`: the cluster/Harbor/deploy/e2e steps run in the project container (`helm`/`kind`
on the container `$PATH`), reached by the binary re-invoking its own subcommand.

#### Deliverables

- `demo` composes its chain (metal → VM → container) on `liftSubcommand`; `cluster up` / `harbor install`
  lift into the container; build #3 (the project-container build) is wired into the chain.

#### Validation

- `cabal build` (demo) succeeds; build #3 (the project container) builds host-native FROM the pulled base
  with the in-Dockerfile `check-code` gate.
- **Live (in a container on the metal host — a dev shortcut, NOT the in-VM path).** `docker run --rm -v
  /var/run/docker.sock:/var/run/docker.sock --network host hostbootstrap-demo:local test e2e-tabs` is green
  end to end (`1/1 passed`): the harness runs **inside the project container** (build #3, ENTRYPOINT = the
  binary — the self-reference needs no name in argv) and drives kind-in-container via the mounted socket →
  cordon → `helm upgrade --install: ok` → `kind load` the project image → NodePort readiness → the Playwright
  spec delivered through the context-agnostic named volume → `npx playwright test` green → guarded teardown
  with **no leftover cluster or volume**. This exercises the lifted in-container execution (`helm`/`kind` on
  the container `$PATH`, never the host) and closes the real-run halves of Phase 5 Sprint 5.4 and Phase 11
  Sprint 11.5.

> **Correction (Sprint 13.12).** The container above ran on the **metal host's** Docker, so kind came up
> on the **metal host**, not in the VM. The original claim that this in-container run validated "the full
> metal → VM → container nesting" was **wrong**: build #2 (in-VM host-native, Sprint 13.3) and the
> in-container harness run were each validated **separately on the metal host**, and the demo today still
> carries **two redundant cluster-deploy representations** (the harness and the parallel `Chain.hs` ops).
> The **integrated** in-VM run — the demo deploy folding to `incus exec <vm> -- docker run --rm <image>
> test all` so the harness lifts into the project container in the VM and the kind cluster lives on the
> VM's Docker — is **Sprint 13.12**, now **live-validated** (the single-representation collapse, § W: the
> literal `demo deploy` brings kind up on the VM's Docker, `3/3`, none on metal).

#### Remaining Work

None. The demo composes its chain on `liftSubcommand`; the in-container execution of the full e2e path was
first validated **on the metal host** (a dev shortcut), and the **integrated in-VM run** — kind on the VM's
Docker via the single lifted `test all`, with the two redundant representations collapsed into one lift
sequence — is **live-validated** in Sprint 13.12.

### Sprint 13.9: Real per-case seams [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (`demoSeams`)
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/engineering/testing.md`

#### Objective

Replace the hollow `demoSeams` with real per-case seams that assert the deployed workload, and actually
run Playwright in the `e2e-tabs` case.

#### Deliverables

- The demo ships `demo/chart` (a NodePort Service deploying the webservice **into** the per-case kind
  cluster); `cluster up` installs it (chart-conditional, fail-closed — Phase 5 Sprint 5.4). Per-case
  bodies: `pristine-bootstrap` asserts the live cluster; `web-build` asserts the `spago`/`esbuild` bundle;
  `e2e-tabs` lifts a Playwright container onto the kind network and runs `demo/playwright/demo.spec.ts`
  against the in-cluster service via its NodePort, passing iff the spec passes. Closes the
  hollow-`demoSeams` entry in [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md).

#### Validation

- The chart is validated offline (`helm lint` / `helm template` render the NodePort Service + the
  Deployment running `hostbootstrap-demo:local web serve`). A failing deploy makes the case FAIL (no longer
  vacuous); the live deploy + NodePort reachability + the Playwright run are exercised on a real host (the
  project image is made available to the cluster via `kind load` or the Harbor pull).
- **Live (real host):** `demo test pristine-bootstrap` ran kind create → cordon → `helm upgrade --install:
  ok` (the chart deployed) → the per-case assertion → clean teardown (`test report: 1/1 passed`, no
  leftover cluster), confirming the fail-closed `cluster up` + chart-conditional deploy + per-case seam +
  teardown on a real host.
- **Live (real host):** `demo test e2e-tabs` is green end to end (`1/1 passed`): `cluster up` (chart
  deployed) → `kind load` the project image → NodePort readiness → a Playwright container runs
  `demo/playwright` against the in-cluster NodePort (3 specs green) → clean teardown.
- **Live (in-container, the production path):** `docker run --rm -v /var/run/docker.sock:/var/run/docker.sock
  --network host hostbootstrap-demo:local test web-build` is green (`1/1 passed`): the harness runs **inside
  the project container** — kind-in-container via the mounted socket → cordon → `helm upgrade --install: ok`
  → `assertWebBundle` confirms the in-image `web/public/app.js` bundle → guarded teardown, no leftover
  cluster. This validates the lifted in-container execution (build #3 running its own harness) and
  `web-build`'s assertion against the bundle build #3 produces.
- **Context-agnostic e2e spec delivery.** `assertE2E` now delivers `demo/playwright` through a named Docker
  volume populated by `docker cp` (`deliverSpec`), which streams from the harness's own filesystem — so the
  e2e lifts into **any** context (host or in-container) instead of silently depending on a host path the
  daemon would resolve on the host. Re-validated live on the host (`demo test e2e-tabs`, `1/1 passed`, real
  Playwright through the volume).

#### Remaining Work

None. The per-case seams (`assertClusterLive` / `assertWebBundle` / `assertE2E`, dispatched on the case id)
are live-validated: `pristine-bootstrap` and `e2e-tabs` on the host, `web-build` in-container; the e2e spec
delivery is context-agnostic.

### Sprint 13.10: F1 — `demo deploy --dry-run` (pure chain + interpreter) [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Chain.hs`
**Docs to update**: `documents/engineering/composition_patterns.md`

#### Objective

Reify the demo deploy/lift chain as a pure data value run by a small interpreter; `demo deploy [--dry-run]`
prints the planned operation/argv sequence without effect, while apply runs it via `liftSubcommand`.

#### Deliverables

- `HostBootstrapDemo.Chain`: the pure chain value + interpreter, wired as `demo deploy`; a pure unit test
  asserting the dry-run plan is a pure function of the chain value.

#### Validation

- `demo deploy --dry-run` prints the planned operation sequence with no side effects (verified); the pure
  `renderPlan` is a function of the chain value.

#### Remaining Work

None. The apply path runs the chain via `liftSubcommand`, exercised in the demo's live run (Sprint 13.8).

### Sprint 13.11: F2 — `demo role serve`/`submit` (role over toy bus + object store) [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Role.hs`
**Docs to update**: `documents/engineering/composition_patterns.md`, `documents/architecture/run_models.md`

#### Objective

A stateless role (the `HostDaemon` run-model) over a hand-rolled toy bus + MinIO, dispatching to the
existing `fitsBudget` engine — the in-tree worked instance of the business-logic role shape.

#### Deliverables

- `HostBootstrapDemo.Role`: the role loop, the toy-bus stand-in, the MinIO artifact fetch, dispatch to
  `fitsBudget`; `demo role serve`/`submit`. A harness case asserts submit → correct `fitsBudget`
  round-trips the bus. If a new warm-stored Haskell dependency is required, it triggers the base
  rebuild+republish (the conditional base build-and-push, performed only when directed).

#### Validation

- `demo role submit` then `demo role serve` round-trips the toy bus and returns the correct `fitsBudget`
  verdict against the capacity artifact (a filesystem object-store stand-in) — verified locally. The role
  drives through the L0 `runRole` lifecycle skeleton (Phase 14, `HostBootstrap.RoleLifecycle`).

#### Remaining Work

None.

### Sprint 13.12: Collapse the two cluster-deploy representations into one lift sequence [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Chain.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/architecture/composition_methodology.md`

#### Objective

Adopt the single-representation doctrine (§ W) in the demo: the test workflow is a **lifted operation**,
not a parallel representation. Collapse the demo deploy chain to the single canonical lift sequence whose
**only** lifted compute step is `test all` lifted into the project container in the VM — folding to
`incus exec <vm> -- docker run --rm <image> test all` — so the harness runs `clusterUp` "locally" on the
VM's Docker and the kind cluster lives **in the VM**, reached with no second "bring up a cluster" path.
The harness (`HostBootstrap.Harness`) is the **one** representation and is **unchanged** — it is the
context-agnostic lift target (no `LiftContext` inside it, per § U).

The single canonical demo chain (`demo deploy`):

```text
ensure incus            local                                   -- reconciler on metal
vm up                   local                                   -- cordon #1 (the VM is the wall)
vm pristine-bootstrap   local -> VM                             -- build #2 (host-native) + build #3 (project image), IN the VM
test all                inContainer img (inVM vm localContext)  -- the ONLY lifted compute step; folds to: incus exec <vm> -- docker run --rm <image> test all
vm down                 local                                   -- guarded teardown (.data preserved)
```

#### Deliverables

- The demo deploy chain in `Chain.hs` collapses to the single canonical sequence above; the **only**
  lifted compute step is `test all` in `inContainer img (inVM vm localContext)`.
- The redundant `cluster up` / `harbor install` / `web serve` / `e2e` ops in `Chain.hs` (the parallel
  representation that duplicated the harness and double-created clusters when it lifted a harness case) are
  **removed**.
- `runVmBootstrap` (in `Commands.hs`) also builds **#3** (the project image) **in the VM**, so the lifted
  `test all` finds the image on the VM's Docker — no separate metal-side image path.
- The harness is **unchanged** — it remains the context-agnostic lift target (the one representation, § W).

#### Validation

- `demo deploy --dry-run` prints the single canonical sequence (the only lifted compute step is `test all`
  under `inContainer (inVM …)`, folding to `incus exec hostbootstrap-demo-vm -- docker run --rm <image>
  hostbootstrap-demo:local test all`); the redundant ops no longer appear in the plan.
- **Live (real host).** A staged run brought build #2 **and build #3** up in the VM (image on the VM's
  Docker), then the lifted `test all` passed `3/3` with a concurrent poller showing the kind control-plane
  node on the **VM's** Docker at every sampled second (t=30s…330s) and **none on metal**. The literal `demo
  deploy` apply then ran `ensure incus -> vm up -> pristine[#2+#3] -> lifted test all (3/3) -> vm down`,
  `DEPLOY_EXIT=0`, with no leftover VM and a clean metal host — kind genuinely comes up in the VM via the
  single lift sequence.

#### Remaining Work

None. The collapse landed (`Chain.hs` folds to the single canonical sequence; the redundant `cluster
up`/`harbor install`/`web serve`/`e2e` ops are removed; `runVmBootstrap` builds #3 in the VM) and is
live-validated by the literal `demo deploy` apply (`3/3`, kind on the VM's Docker, none on metal, guarded
teardown, no leftovers). The demo storage budget was raised 40 → 80 GiB so the in-VM `test all` holds the
~20 GB image plus its `kind load` duplicate.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/derived_dockerfile.md` - the idiomatic derived Dockerfile (in-Dockerfile
  `check-code` gate; the `purescript-bridge` -> `spago` -> `esbuild` web build; the build-stage ordering).

**Operations docs to create/update:**
- `documents/operations/demo_runbook.md` - **rewrite** for the lift-based flow (the chain run via
  `HostBootstrap.Lift`), real per-case seams (no vacuous passes), the new `deploy --dry-run` / `role`
  verbs, and the 3-builds explanation; drop the old feature-to-case table that implied the hollow seams
  proved the features.

**Cross-references to add:**
- `documents/engineering/harbor.md`, `documents/languages/purescript.md`,
  `documents/languages/playwright.md`, and `documents/engineering/derived_project_standards.md` reference
  the demo.
- `system-components.md` adds the `hostbootstrap-demo` worked-consumer subsection.
- `legacy-tracking-for-deletion.md` records the `example/Main.hs` removal.
