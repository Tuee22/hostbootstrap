# Phase 13: hostbootstrap-demo Worked App

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-11-incus-host-provider.md](phase-11-incus-host-provider.md), [phase-12-layered-warm-store.md](phase-12-layered-warm-store.md)

> **Purpose**: Add a self-contained worked consumer under `demo/` whose test suite demonstrates every main
> feature end to end, centered on a from-zero pristine-host bootstrap performed inside a managed Linux VM
> (Lima on Apple Silicon, native Incus on Linux).

## Phase Status

**Status**: Active

**Reopened (2026-06-19)** for the unified-harness / fixed-command-surface / resource-SSoT correction (see
`## Remaining Work`): the demo's test seams must drive the real `project up` instead of a second bring-up
mirror, the budget-doubling VM sizing must collapse to budget = VM wall / cluster = slice, and the
`web serve` / `web bridge` verbs must move to `service run` (`Web` variant) + the build-image step. The
earlier chain-is-the-project migration remains real-run-validated end-to-end (2026-06-18): the
demo's deploy is now the contributed `demoChain :: ProjectConfig -> [Step]` value (plus `demoFrameContext` /
`demoTeardown`) interpreted by the core `project up`, which stood up the full live persistent stack — the
3-frame recursive descent → `deploy-kind` → the 8-pod production Harbor → the 20GB image push → the web chart
pod → `localhost:30080` serving HTTP 200 — and tore it down with `project down` / `project destroy` (host
`.data` preserved, § O). The hand-written `demoDeployChain` (`HostBootstrapDemo.Chain`) and the demo's
`deploy` / `harbor` / `role` noun verbs are deleted; the `web` verb (load-bearing for the chart pod + the
Dockerfile) and the `vm` / `incus` debug hatches remain. The interpreter it rests on is
[phase-16](phase-16-project-lifecycle-command.md) (Done). The original narrative below describes the shape
that is now built.

`hostbootstrap-demo` lives under `demo/` with a repo-local build path at `demo/.build`. It extends
`hostbootstrap-core` directly via `runHostBootstrapCLI "hostbootstrap-demo" projectSpec`, exercising the
four extension streams: CLI append, schema-registry concat, Dhall vocabulary use, and the `runMatrix`
harness. Its `ProjectSpec` supplies `demoCommands`, `demoCheckCode`, `demoArtifacts`, and the non-empty
`TestSuite demoSeams demoCases`.

This phase is reopened for the **"the chain is the project"** migration (§ Y, § T). The demo's worked
shape is the proving ground for the chain-is-code model: a project's primary CLI contribution is its
**lift chain** value (`chain :: RootConfig -> [Step]`, interpreted by the core `project` lifecycle), not
the noun verbs the demo ships today. The single-representation invariant (§ W) is unchanged — what
changes is the **representation**: the hand-written `demoDeployChain` and its small interpreter in
`demo/src/HostBootstrapDemo/Chain.hs`, together with the demo's `vm`/`deploy`/`incus`/`harbor`/`web`/`role`
noun verbs in `Commands.hs`, become a `chain :: RootConfig -> [Step]` value the **core** `Step`
interpreter runs, plus the demo's contributed workload step actions. The target shape is described below
as what is being built; the `project up`/`project down`/`project destroy` interpreter it depends on is
owned by phase-16, so this phase tracks the demo's side of the migration as **remaining work**, not as a
shipped capability.

The demo's currently-shipped deploy shape follows the single-representation doctrine (§ W). `demo deploy`
is one explicit lift sequence whose only lifted compute step is `test all` inside the project container in
the managed VM:

```text
vm ensure
vm up
vm pristine-bootstrap
<vm-provider-exec> -- docker run --rm <image> test all
vm down
```

Inside that lifted `test all`, the harness runs `clusterUp` locally on the VM's Docker, so the kind
cluster lives in the VM. The demo uses sibling `hostbootstrap-demo.dhall` files for each runtime context:
host, VM, VM project container, and service/daemon pod.

The demo covers these supported surfaces:

- `demo vm ensure`, `demo vm up`, and `demo vm down` exercise the selected VM provider and VM budget
  cordon: Lima on Apple Silicon, native Incus on Linux.
- `demo vm pristine-bootstrap` runs the first-run path inside a fresh Ubuntu VM and demonstrates the
  three builds: metal orchestrator, in-VM host-native binary, and in-VM project container.
- `hostbootstrap-demo test all` runs the standardized harness over `pristine-bootstrap`, `web-build`, and `e2e-tabs`
  with guaranteed per-case teardown.
- `demo web bridge`, `demo web serve`, and `demo/docker/Dockerfile` cover the `warp`/`wai` service,
  `purescript-bridge`, Halogen, `spago`, `esbuild`, and the in-Dockerfile `check-code` gate.
- `demo harbor install` and `demo harbor push` cover the registry verbs; full operator-scale Harbor runs
  remain release/demo operations.
- `demo role serve` and `demo role submit` exercise the L0 role-lifecycle skeleton.

The Apple Silicon path uses Lima (not an Incus VM), and the runtime context is topology-strict: a direct
host/container fallback cannot run `test all` against the wrong Docker daemon, because a
VM-project-container config requires a VM-orchestrator ancestor and runtime witnesses (the Dockerfile bakes
image-build authority only; the lifted runtime container receives a parent-generated config mounted over
`/usr/local/bin/hostbootstrap-demo.dhall`). The Lima fold, the topology-aware context enforcement, and the
full real Apple Silicon Lima lifecycle — including the Playwright e2e suite — are all validated for the
current noun-verb shape.

## Current Status

The demo's noun-verb deploy shape (the `demo deploy` lift sequence above, the `vm`/`incus`/`harbor`/`web`/`role`
verbs, the hand-written `demoDeployChain` and its interpreter in `Chain.hs`, the `runMatrix` harness, the
four runtime `hostbootstrap-demo.dhall` configs, and both VM providers) is **implemented and validated**.
What is **not yet built** is the migration of that shape onto the core `Step` interpreter: the demo does
not yet contribute a `chain :: RootConfig -> [Step]` value, and there is no `project up`/`project down`/`project destroy`
surface — the core `project` lifecycle command that interprets the chain is owned by phase-16, and the
demo's migration onto it is the remaining work below. Do **not** read this phase as claiming the `project`
command or the chain-as-`[Step]` representation is shipped.

## Remaining Work

The contributed `demoChain :: ProjectConfig -> [Step]` interpreted by `project up` is built and
real-run-validated (2026-06-18). The reopened, real-run-gated work is the unified-harness / resource-SSoT /
fixed-surface correction (development_plan_standards § W, § O, § P, § AA):

- **Drive the harness through `project up`.** Rewrite the demo's `demoSeams` so each case is an
  **assertion** over a real `project up`, not a parallel bring-up. Delete the `seamSetup` mirror
  (`clusterCreate caseResources` → `kind load` → `deployChart`) and the per-case
  `testCaseProfile`/`caseResources` cluster model in `demo/src/HostBootstrapDemo/Commands.hs`; per distinct
  test config the harness writes a test `<project>.dhall`, runs `project up`, asserts in the appropriate
  frame (the e2e Playwright case as a container on the kind network in the VM frame, outside the cluster),
  and tears down with `project destroy` ([phase-10](phase-10-standardized-test-harness.md)).
- **Fix the resource SSoT (the doubling).** Remove `vmSizingWithHeadroom` so the VM is sized to the
  declared budget (the VM wall), and cordon the production kind cluster (`deployKindAction`) to a **slice**
  within that wall rather than the full budget. The one ceiling is used once (§ O); recorded under
  [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) `Pending`.
- **Move the long-running web role to `service`.** `web serve` → `service run` (`Web` variant of the demo's
  `ServiceType` ADT, [phase-18](phase-18-service-runtime-command.md)); `web bridge` → the build-image chain
  step; the chart pod's entrypoint becomes `service run` with its config delivered by a ConfigMap. The
  `vm`/`incus`/`web` verbs and the `ProjectCommand` extension are deleted; their IO is retained as
  library/step functions ([phase-16](phase-16-project-lifecycle-command.md)).
- **Closing gate (forward deps):** the full demo lifecycle + `test run all` (incl. Playwright e2e across
  three browsers) + `service run` (the web pod) completes on a 16 GiB Apple-Silicon host — unblocked by the
  sizing fix (VM = budget fits; cluster runs as a slice inside it). The interpreter this drives is owned by
  [phase-16](phase-16-project-lifecycle-command.md); the harness engine by
  [phase-10](phase-10-standardized-test-harness.md); the service command by
  [phase-18](phase-18-service-runtime-command.md).

## Phase Objective

Provide the canonical worked consumer and operations runbook. The demo's point is to demonstrate
`hostbootstrap` bootstrapping a **pristine** linux host from zero: because the metal host is not pristine,
the demo orchestrates a pristine managed Linux VM and runs the genuine first-run flow inside it
(`apt install pipx` -> `pipx install hostbootstrap` -> `hostbootstrap run`). This is a deliberate
**3-build** illustration on top of the standard host-native build (see
[development_plan_standards.md § N](development_plan_standards.md)): a metal orchestrator build plus,
inside the pristine VM, the host-native binary build (by `hostbootstrap run`) and the binary-driven
project-container build.

The demo is also the worked proof that **hostbootstrap owns the lifecycle of every resource** and that
the **only fail-fast dependencies are the Python wrapper's host minimums**. The full a→f owned lifecycle
(see [demo_runbook.md](../documents/operations/demo_runbook.md)): (a) the metal binary reconciles the VM
provider (Lima on Apple Silicon, Incus on Linux); (b) `ghcup` is installed and the binary is built **on the VM**; (c) the binary
installs Docker and builds the project container; (d) the project container spins up the kind cluster and
deploys the webservice; (e) the project image's base-provided Playwright runtime runs e2e against it from
a container on the VM; (f) hostbootstrap spins everything back down, preserving `.data`. Nothing in
(a)–(f) is a host prerequisite beyond the
Python minimums — every dependency is install-and-verify (the `ensure` suite, § L), so the binary is
never blocked by an absent dependency.

## Sprints

### Sprint 13.1: `demo/` skeleton and the metal orchestrator binary [Done]

**Status**: Done
**Implementation**: `demo/hostbootstrap-demo.cabal`, `demo/cabal.project`, `demo/app/Main.hs`, `demo/src/HostBootstrapDemo/Commands.hs`
**Docs to update**: `documents/operations/demo_runbook.md`, `system-components.md`

#### Objective

Stand up the `demo/` tree and the metal orchestrator binary: the Cabal package extending
`hostbootstrap-core`, the appended project commands, and build #1.

#### Deliverables

- The `demo/` tree: the Cabal package extending `hostbootstrap-core` via `runHostBootstrapCLI` and
  `ProjectSpec`, the appended `demoCommands`, the required `demoCheckCode` image-build gate, and
  **Build #1** (the metal orchestrator) via the usual workflow.

#### Validation

- `hostbootstrap-demo --help` shows the inherited core verbs plus the demo verbs.

#### Remaining Work

None.

### Sprint 13.2: Linux Incus pristine VM path [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (`incus ensure` / `vm up` / `vm down` drive the real incus host-provider surface)
**Docs to update**: `documents/operations/demo_runbook.md`

#### Objective

Drive core's `ensure incus` and spin up a budget-sized pristine `ubuntu/24.04` VM (cordon #1) via the
demo's noun-first project verbs on native Linux. Apple Silicon Lima support is tracked in Sprint 13.14.

#### Deliverables

- The demo groups its project verbs under nouns (`incus`/`vm`/`harbor`/`web`), distinct from the
  inherited verb-first core verbs (`ensure`/`config`/`cluster`/`test`/`check-code`): `demo incus ensure`
  consumes core's `ensure incus` (install-and-verify: explicit Colima-backed Incus provider on Apple,
  native daemon on Linux)
  and, on Linux only, ensures the VM capability the core reconciler does not cover —
  `qemu-system-x86` + `ovmf` plus a daemon restart so incus re-detects QEMU; `demo vm up` derives the
  VM sizing from the one canonical parser (`incusSizingArgs`) and launches a
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
  full closure — all `hostbootstrap-core` modules plus all demo modules — linking the
  binary and running it (`config schema` printed the reflected `budget`/`podResources`/`kindNode`
  vocabulary). The VM was then destroyed behind the name-prefix guard (`vm down`). Builds #1 (metal) and #2
  (in-VM host-native) of the 3-build sequence are live-validated; build #3 (the project container) is
  live-validated on the host.

#### Remaining Work

None. The pristine path (`pipx install --force /root/hostbootstrap`) is live-validated end to end on a
real host: `vm up` (cordon #1) -> cold in-VM build -> `config schema` -> guarded `vm down`. On Linux,
the first-run prerequisites are ensured by the demo verbs and the bootstrapper:
`qemu-system-x86`/`ovmf`, the `incusbr0`<->Docker forwarding rule, pinned GHC 9.12.4, and
`zlib1g-dev`; Apple Silicon now uses Lima for the demo's pristine VM path (Sprint 13.14).

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

None. `demo harbor install` (cluster up + cordon #2 + `helm upgrade --install harbor`) and `demo harbor
push` (`docker tag` + `push`) are real verbs; the registry **push/pull mechanism is live-validated**
(pushed an image to a registry at the Harbor NodePort and pulled it back). Deploying the full 8-pod
Harbor Helm chart and pushing the multi-GB project image at scale is an operator/demo operation, not open
phase work (see the Phase Status operator-scale note).

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
the L0-direct demo reaches the core source). Validated by a real `docker build` + the Playwright e2e (9/9: 3 specs × chromium/firefox/webkit).

### Sprint 13.6: Harness cluster lifecycle + Playwright (in-cluster, via NodePort) [Done]

**Status**: Done
**Implementation**: the harness `Seams` (per-case kind cluster up + guaranteed teardown) in `demo/src/HostBootstrapDemo/Commands.hs` (`demoSeams`); `demo/playwright/` (config + e2e specs across chromium, firefox, webkit)
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/languages/playwright.md`

#### Objective

Drive isolated per-case clusters through the standardized harness (each torn down on completion), deploy the
webservice **into** the per-case kind cluster via `demo/chart`, and run the Playwright e2e suite from the
already-built project image on the kind network against the in-cluster service via its **NodePort**.

#### Deliverables

- `demoSeams`: each case's `seamSetup` brings up an isolated per-case kind cluster and `seamTeardown`
  **tears it down** (`clusterDelete`, preserving `.data`, guarded to the test-name prefix), guaranteed by
  `runMatrix`'s `finally`. The webservice is deployed into the per-case kind cluster via `demo/chart` (the
  pod runs `web serve`); the Playwright runner is the same `hostbootstrap-demo:local` project image on the
  kind network, using the base image's global Playwright install and browser cache (chromium, firefox, webkit) against the in-cluster
  service via its **NodePort** (the e2e target is the kind cluster).
- Per-case seams and harness-driven Playwright run against the in-cluster NodePort; `e2e-tabs` is
  live-validated.

#### Validation

- **Harness cluster lifecycle + cleanup done (live).** `hostbootstrap-demo test all` (rebuilt in-VM) ran all three
  cases; each did `cluster up` (cordon #2 applied) → body → `cluster delete` (`.data` preserved), and
  after the run `kind get clusters` reported **"No kind clusters found"** — the harness leaves no leftover
  clusters (`test report: 3/3 passed`). The unit-tested teardown-runs-on-failure guarantee (`HarnessSpec`)
  backs the always-cleans-up property. The per-case bodies are **real assertions**. **`demo test e2e-tabs`
  is live-validated end to end on a real host:** `cluster up` (chart deployed) → `kind load` the project
  image → NodePort readiness → the project image runs `playwright test` from `/workspace/demo/playwright`
  against the in-cluster service via its NodePort, all specs green on every engine (9 runs: 3 specs × chromium/firefox/webkit; tabs render, the Budget tab shows
  `fits: true`, `GET /api/budget` returns `fits:true`) → clean teardown (`1/1 passed`, no leftover cluster,
  source tree untouched).

#### Remaining Work

None. The harness cluster lifecycle, the real per-case seams, and the harness-driven Playwright
(`e2e-tabs`) are live-validated.

### Sprint 13.7: Retire `example/Main.hs` [Done]

**Status**: Done
**Implementation**: `documents/engineering/derived_project_standards.md`, `README.md`,
`legacy-tracking-for-deletion.md`
**Docs to update**: `documents/engineering/derived_project_standards.md`, `legacy-tracking-for-deletion.md`

#### Objective

Make `demo/` the documented worked consumer.

#### Deliverables

- Governed docs and derived-project standards point readers at `demo/` as the worked consumer.

#### Validation

- `cabal build all` succeeds; governed docs point to `demo/` for the worked consumer.

#### Remaining Work

None.

### Sprint 13.8: Wire the demo through the self-reference lift [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/src/HostBootstrap/Lift.hs`
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/architecture/composition_methodology.md`

#### Objective

Wire the demo through `HostBootstrap.Lift`: nested work runs by re-invoking the binary's own subcommand in
the target context.

#### Deliverables

- `demo` composes its chain (metal -> VM -> container) on `liftSubcommand`.
- Build #3 (the project-container build) is available in the VM before the lifted `test all` step.
- The harness remains the single cluster/deploy/e2e representation.

#### Validation

- `cabal build` (demo) succeeds; build #3 (the project container) builds `FROM` the base with the
  in-Dockerfile `check-code` gate.
- `demo deploy --dry-run` folds the lifted compute step to
  the selected VM provider followed by `docker run --rm <image> test all`.
- The integrated in-VM run exercises the harness inside the project container in the VM, so kind runs on
  the VM's Docker.

#### Remaining Work

The self-reference lift (`HostBootstrap.Lift`) the demo composes its chain on stays valid and is reused by
the migrated chain. What this sprint's contract changes under the new model: the demo's chain is no longer
a hand-composed `liftSubcommand` fold wired behind the `demo deploy` noun verb — it becomes a
`chain :: RootConfig -> [Step]` value the core `project` interpreter folds onto `liftSubcommand` at each
frame transition (provision the frame → build/install the pb → hand off `pb project up`, § Y). Migrate the
metal → VM → container composition from the demo's bespoke chain assembly to core step kinds so the lift
fold is performed by the interpreter, not by demo orchestration code. The interpreter is **new work owned
by phase-16**; this sprint owns rebasing the demo's lift composition onto the contributed `[Step]` chain.

### Sprint 13.9: Real per-case seams [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs` (`demoSeams`)
**Docs to update**: `documents/operations/demo_runbook.md`, `documents/engineering/testing.md`

#### Objective

Define per-case seams that assert the deployed workload, including Playwright in the `e2e-tabs` case.

#### Deliverables

- The demo ships `demo/chart` (a NodePort Service deploying the webservice **into** the per-case kind
  cluster); `cluster up` installs it (chart-conditional, fail-closed — Phase 5 Sprint 5.4). Per-case
  bodies: `pristine-bootstrap` asserts the live cluster; `web-build` asserts the `spago`/`esbuild` bundle;
  `e2e-tabs` starts the `hostbootstrap-demo:local` project image on the kind network and runs
  `/workspace/demo/playwright` against the in-cluster service via its NodePort, passing iff the spec
  passes.

#### Validation

- The chart is validated offline (`helm lint` / `helm template` render the NodePort Service + the
  Deployment running `hostbootstrap-demo:local web serve`). A failing deploy fails the case; the live
  deploy + NodePort reachability + the Playwright run are exercised on a real host (the project image is
  made available to the cluster via `kind load` or the Harbor pull).
- **Live (real host):** `demo test pristine-bootstrap` ran kind create → cordon → `helm upgrade --install:
  ok` (the chart deployed) → the per-case assertion → clean teardown (`test report: 1/1 passed`, no
  leftover cluster), confirming the fail-closed `cluster up` + chart-conditional deploy + per-case seam +
  teardown on a real host.
- **Live (real host):** `demo test e2e-tabs` is green end to end (`1/1 passed`): `cluster up` (chart
  deployed) → `kind load` the project image → NodePort readiness → the project image runs
  `playwright test` against the in-cluster NodePort (9 runs: 3 specs × chromium/firefox/webkit, all green) → clean teardown.
- **Live (in-container, the production path):** `docker run --rm -v /var/run/docker.sock:/var/run/docker.sock
  --network host hostbootstrap-demo:local test web-build` is green (`1/1 passed`): the harness runs **inside
  the project container** — kind-in-container via the mounted socket → cordon → `helm upgrade --install: ok`
  → `assertWebBundle` confirms the in-image `web/public/app.js` bundle → guarded teardown, no leftover
  cluster. This validates the lifted in-container execution (build #3 running its own harness) and
  `web-build`'s assertion against the bundle build #3 produces.
- **Context-agnostic e2e runner.** `assertE2E` now uses the already-built project image as the Playwright
  runner with all three installed browser engines (chromium, firefox, webkit), so the specs and the base image's browser cache are available inside the same image whether the
  harness is invoked on the host or lifted into the VM project container. The run does not pull
  `mcr.microsoft.com/playwright:*`, run `npm install`, or use `npx` at validation time.

#### Remaining Work

None. The per-case seams (`assertClusterLive` / `assertWebBundle` / `assertE2E`, dispatched on the case id)
are live-validated: `pristine-bootstrap` and `e2e-tabs` on the host, `web-build` in-container; the e2e
runner is context-agnostic because it uses the project image.

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

This sprint reified the demo deploy chain as a pure data value with a **demo-local** interpreter
(`HostBootstrapDemo.Chain`) behind the `demo deploy [--dry-run]` noun verb. The new model moves that
representation up into the core: the chain becomes a `chain :: RootConfig -> [Step]` value over **core**
step kinds, and the interpreter that renders `--dry-run` and runs apply is the core `project` lifecycle
command (`project up --dry-run` renders the same chain apply executes, § Y/§ W), not a demo-local
`renderPlan`. Migrate the demo's pure chain value off the bespoke `Chain.hs` interpreter onto the core
`Step` interpreter and retire `demo deploy` as a noun verb in favor of `project up`/`project down`/`project destroy`.
The core interpreter and the `project --dry-run` rendering are **new work owned by phase-16**; the
pure-function-of-the-chain-value property is preserved through the migration.

### Sprint 13.11: F2 — `demo role serve`/`submit` (role over toy bus + object store) [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Role.hs`
**Docs to update**: `documents/engineering/composition_patterns.md`, `documents/architecture/run_models.md`

#### Objective

A stateless role (the `HostDaemon` run-model) over a hand-rolled toy bus + MinIO, dispatching to the
existing `fitsBudget` engine — the in-tree worked instance of the business-logic role shape.

#### Deliverables

- `HostBootstrapDemo.Role`: the role loop, the toy-bus stand-in, the MinIO artifact fetch, dispatch to
  `fitsBudget`; `demo role serve`/`submit`. A harness case asserts submit -> correct `fitsBudget`
  round-trips the bus. Warm-store dependency changes follow the base rebuild/republish rule.

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
not a parallel representation. The demo deploy chain is the single canonical lift sequence whose
**only** lifted compute step is `test all` lifted into the project container in the VM, folding to
the selected VM provider followed by `docker run --rm <image> test all` — so the harness runs `clusterUp` "locally" on the
VM's Docker and the kind cluster lives **in the VM**, reached with no second "bring up a cluster" path.
The harness (`HostBootstrap.Harness`) is the **one** representation and is **unchanged** — it is the
context-agnostic lift target (no `LiftContext` inside it, per § U).

The single canonical demo chain (`demo deploy`):

```text
vm ensure               local                                   -- reconciler on metal
vm up                   local                                   -- cordon #1 (the VM is the wall)
vm pristine-bootstrap   local -> VM                             -- build #2 (host-native) + build #3 (project image), IN the VM
test all                inContainer img (inVM vm localContext)  -- the ONLY lifted compute step; folds through the VM provider, then docker run --rm <image> test all
vm down                 local                                   -- guarded teardown (.data preserved)
```

#### Deliverables

- The demo deploy chain in `Chain.hs` is the single canonical sequence above; the **only** lifted compute
  step is `test all` in `inContainer img (inVM vm localContext)`.
- Cluster bring-up, service deploy, and e2e execution are the harness's responsibility inside the lifted
  `test all` workflow.
- `runVmBootstrap` (in `Commands.hs`) also builds **#3** (the project image) **in the VM**, so the lifted
  `test all` finds the image on the VM's Docker — no separate metal-side image path.
- The harness remains the context-agnostic lift target (the one representation, § W).

#### Validation

- `demo deploy --dry-run` prints the single canonical sequence (the only lifted compute step is `test all`
  under `inContainer (inVM ...)`, folding through the selected VM provider and then `docker run --rm
  hostbootstrap-demo:local test all`).
- **Live (real host).** A staged run brought build #2 **and build #3** up in the VM (image on the VM's
  Docker), then the lifted `test all` passed `3/3` with a concurrent poller showing the kind control-plane
  node on the **VM's** Docker at every sampled second (t=30s…330s) and **none on metal**. The literal `demo
  deploy` apply then ran `vm ensure -> vm up -> pristine[#2+#3] -> lifted test all (3/3) -> vm down`,
  `DEPLOY_EXIT=0`, with no leftover VM and a clean metal host — kind genuinely comes up in the VM via the
  single lift sequence.

#### Remaining Work

The single-representation collapse this sprint achieved (one canonical lift sequence whose only lifted
compute step is `test all`, harness unchanged as the one lift target) **stays the invariant** under the
new model — the single-representation doctrine (§ W) is unchanged. What changes is the **carrier** of that
single representation: the canonical sequence is no longer a hand-written `Chain.hs` value behind
`demo deploy`, it is the `chain :: RootConfig -> [Step]` value the core `project` interpreter runs. Migrate
the canonical sequence (`vm ensure` → `vm up` → `vm pristine-bootstrap` → lifted `test all` → `vm down`)
to core step kinds (deploy-VM, `ensure-*`, copy-source, build-pb, build-image, `context-init`, the
lifted-`test`/run-leaf step, deploy-VM-down) plus the demo's contributed steps, so the one representation
is the interpreted `[Step]` chain. `runVmBootstrap`'s build-#3-in-the-VM behavior is preserved as the
build-pb/build-image steps in the chain. The core `Step` interpreter is **new work owned by phase-16**;
this sprint owns re-expressing the collapsed sequence as the contributed chain value over those step
kinds without reintroducing a second representation.

### Sprint 13.13: Migrate demo runtime configs [Done]

**Status**: Done
**Implementation**: `demo/hostbootstrap-demo.cabal`, `demo/docker/Dockerfile`,
`demo/src/HostBootstrapDemo/Commands.hs`, `demo/src/HostBootstrapDemo/Chain.hs`
**Docs to update**: `documents/operations/demo_runbook.md`,
`documents/engineering/derived_project_standards.md`, `documents/engineering/derived_dockerfile.md`,
`legacy-tracking-for-deletion.md`

#### Objective

Move the worked demo to the project-local config contract: every copy of the
`hostbootstrap-demo` binary reads a sibling `hostbootstrap-demo.dhall`, and the role/capability
distinction lives inside the file content rather than the filename.

#### Deliverables

- Host default config generated by `hostbootstrap-demo config init` as
  `demo/.build/hostbootstrap-demo.dhall`, with Dockerfile path and budget in the project-local config.
- VM-local config projected before the in-VM bootstrap/binary exec.
- Image-build config baked by the Dockerfile at `/usr/local/bin/hostbootstrap-demo.dhall` through
  `hostbootstrap-demo config init --role image-build-container`; runtime VM-project-container configs are
  parent-generated and mounted over that path for lifted workflows.
- Service/daemon config generated or mounted during cluster bring-up for any `web serve` or role-daemon
  pod; the chart mounts a service-role `hostbootstrap-demo.dhall`.

#### Validation

- `hostbootstrap-demo --help`, `config init`, and normal missing-config failure behavior are covered.
- Demo dry-run output shows the same single lift sequence through the project-local config gate.
- Real-run validation repeats the lightweight demo path enough to prove host, VM, container, and
  service contexts are each using their own sibling `hostbootstrap-demo.dhall`.
- Current validation: `cabal build all` from `demo/` passes; `helm template hostbootstrap-demo demo/chart`
  renders the service config mount; `cabal run hostbootstrap-demo -- config init --role host-orchestrator
  --source-root /home/matt/hostbootstrap/demo --dockerfile docker/Dockerfile --cpu 6 --memory 10GiB
  --storage 80GiB --ha-replicas 1 --force` creates the host config; and `cabal run hostbootstrap-demo --
  deploy --dry-run` renders the single lift sequence through the gate.

#### Remaining Work

None.

### Sprint 13.14: Apple Lima VM path and topology-strict runtime configs [Done]

**Status**: Done
**Implementation**: `demo/src/HostBootstrapDemo/Commands.hs`, `demo/src/HostBootstrapDemo/Chain.hs`, `core/hostbootstrap-core/src/HostBootstrap/Lima.hs`, `core/hostbootstrap-core/src/HostBootstrap/Ensure/Lima.hs`, `core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`, `core/hostbootstrap-core/src/HostBootstrap/Context.hs`, `demo/docker/Dockerfile`
**Docs to update**: `README.md`, `documents/architecture/binary_context_config.md`, `documents/architecture/composition_methodology.md`, `documents/operations/demo_runbook.md`, `documents/engineering/lima.md`, `documents/engineering/schema.md`, `documents/engineering/dhall_topology.md`, `legacy-tracking-for-deletion.md`

#### Objective

Make the demo's VM provider substrate-aware and make its runtime configs fail fast when the binary is not
running in the topology frame the Dhall declares.

#### Deliverables

- Apple Silicon deploy uses Lima VM commands and lift folding, not Incus VM commands.
- Native Linux deploy keeps the Incus VM path.
- `vm up` fails fast when the host config budget is below the documented full-lifecycle floor
  (6 CPU / 10GiB memory / 80GiB storage), before launching an undersized VM.
- Dockerfile-baked config is image-build-only; lifted runtime containers receive a parent-generated
  VM-project-container config mounted over `/usr/local/bin/hostbootstrap-demo.dhall`.
- Direct `docker run <image> test all` with only the baked image-build config is not authorized, and
  standalone VM-project-container configs fail before cluster creation because the topology lacks a
  VM-orchestrator ancestor.

#### Validation

- Current validation: `cabal build all` from `core/` passes; `cabal build all` from `demo/` passes;
  Apple Silicon `deploy --dry-run` folds to `limactl shell hostbootstrap-demo-vm -- docker run
  --rm ... test all`. The first real Lima lifecycle reached the in-VM Docker ensure; that exposed and
  fixed the missing Linux `docker` group/current-session socket reconciliation in `ensure docker`
  (now unit-tested and verified with `sg docker -c "docker info"` plus a `/var/run/docker.sock` ACL
  check in the disposable Lima VM). The next real Lima lifecycle reached the in-VM project-image build
  and exposed an undersized 20GiB generated host config; `vm up` now rejects budgets below the
  documented 6 CPU / 10GiB / 80GiB full-lifecycle floor before VM launch. A subsequent run exposed an
  unused Lima-managed containerd boot-script hang; `HostBootstrap.Lima.startVMArgs` now starts the VM
  with `--containerd none` and a bounded `--timeout 15m` because Docker is installed by the project
  binary inside the guest. The full Apple Silicon lifecycle now passes: `deploy` ran `vm ensure`, created
  the 6 CPU / 10GiB / 80GiB Lima VM, completed `vm pristine-bootstrap` including build #2 and the
  in-VM project image build, lifted `docker run --rm -v /var/run/docker.sock:/var/run/docker.sock
  --network=host hostbootstrap-demo:local test all`, reported `test report: 3/3 passed` (`pristine-bootstrap`,
  `web-build`, `e2e-tabs`), and destroyed the Lima VM through guarded `vm down`.

The topology-strict split is implemented and covered by `ContextSpec` and `SchemaSpec`:
`ImageBuildContainer` permits build-time `check-code`/config generation only, `context create container`
is parent-derived, and `VMProjectContainer` requires a VM-orchestrator ancestor. Current validation:
`cabal test all` from `core/` passes (199 tests); `cabal build all` from `demo/` passes; and
`cabal run hostbootstrap-demo -- deploy --dry-run` renders the six-step chain with the VM-local
`context create container` step and the runtime config/witness mounts on the lifted `docker run`.

#### Remaining Work

None. The full real Apple Silicon Lima lifecycle is validated end to end (2026-06-16): `deploy` ran
`vm ensure` → `vm up` (the 6 CPU / 10 GiB / 80 GiB Lima VM — cordon #1, sized
`--cpus 6 --memory 10 --disk 80`) → `vm pristine-bootstrap` (build #2 host-native in the VM, base
`basecontainer-cpu-arm64` pulled (authenticated via the forwarded host Docker Hub credential — never in
Dhall, never persisted, never in `argv`), build #3 the `hostbootstrap-demo:local` project image with the
in-Dockerfile `check-code` gate of `fourmolu`/`hlint`/`cabal -Werror`) → `context create container` (the
VM-local runtime config) → the single lifted compute step
`limactl shell hostbootstrap-demo-vm -- docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v …runtime-container.dhall:/usr/local/bin/hostbootstrap-demo.dhall:ro -v /run/hostbootstrap:ro --network=host -e HOSTBOOTSTRAP_CURRENT_FRAME=vm-project-container-2 -e HOSTBOOTSTRAP_REGISTRY_AUTH hostbootstrap-demo:local test all`,
where the harness brought up the per-case kind clusters on the **VM's** Docker (cordon #2 applied:
`docker update --cpus 2 --memory 2147483648 --memory-swap 2147483648 hostbootstrap-demo-test-e2e-tabs-control-plane`;
the in-container `kind`/e2e pulls authenticated through the same forwarded credential, consumed into an
ephemeral `DOCKER_CONFIG`) and reported `test report: 3/3 passed` (`pristine-bootstrap`, `web-build`, and
`e2e-tabs` — the e2e Playwright run is green across chromium, firefox, and webkit: 9 runs, 3 specs × 3
engines) → guarded `vm down` (`.data` preserved). `DEMO_DEPLOY_EXIT=0`, no leftover VM.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/derived_dockerfile.md` - the idiomatic derived Dockerfile (in-Dockerfile
  `check-code` gate; the `purescript-bridge` -> `spago` -> `esbuild` web build; the build-stage ordering).

**Operations docs to create/update:**
- `documents/operations/demo_runbook.md` - lift-based flow, real per-case seams, `deploy --dry-run` /
  `role` verbs, the 3-builds explanation, and the four `hostbootstrap-demo.dhall` runtime configs.

**Cross-references to add:**
- `documents/engineering/harbor.md`, `documents/languages/purescript.md`,
  `documents/languages/playwright.md`, and `documents/engineering/derived_project_standards.md` reference
  the demo.
- `system-components.md` adds the `hostbootstrap-demo` worked-consumer subsection.
- `legacy-tracking-for-deletion.md` records obsolete compatibility surfaces.
