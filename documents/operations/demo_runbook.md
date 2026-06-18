# hostbootstrap-demo Runbook

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [development plan](../../DEVELOPMENT_PLAN/phase-13-hostbootstrap-demo.md), [binary context](../architecture/binary_context_config.md)

> **Purpose**: Walk an operator through the `hostbootstrap-demo` pristine-host bootstrap — the lift
> chain the demo contributes, the `project` lifecycle that interprets it, and which harness case proves
> which feature.

## TL;DR

- `demo/` is the worked consumer `hostbootstrap-demo`: an L0-direct binary (it consumes
  `hostbootstrap-core` directly, like `mcts`), integration mode 2
  (`source-repository-package` + `runHostBootstrapCLI`). See [run models](../architecture/run_models.md).
- The demo's identity is its **lift chain** — `chain :: RootConfig -> [Step]`, a single ordered value
  the core interprets. The demo contributes that chain (plus its step actions, harness cases, and Dhall
  vocabulary) through `ProjectSpec`. The canonical statement of the chain-is-the-project model lives in
  [composition_methodology](../architecture/composition_methodology.md); this runbook only walks the
  demo's instance of it.
- The headline is a from-zero pristine-host bootstrap performed **inside a managed Linux VM** (Lima on
  Apple Silicon, Incus on native Linux; the metal host is not pristine): `apt install pipx` →
  `pipx install` the local hostbootstrap → `hostbootstrap run`. The Python bootstrapper is the
  metal-frame instance of the same fractal pattern (provision the frame → build the binary in it → hand
  off `project up`).
- The operator surface is `project up` / `project down` / `project destroy` to drive the chain, `context`
  to visualize it, and `test run all` to validate the live stack. There is **one** representation: the
  `[Step]` chain. There is no parallel cluster-up / web-serve / e2e chain alongside it.
- The same three harness cases (`pristine-bootstrap` / `web-build` / `e2e-tabs`) prove the surface; the
  run is a demo-only **three-build** illustration on top of the standard single host-native build.

## Current Status

The operator surface below (`project init|up|down|destroy`, read-only `context`, `test init` /
`test run <suite>|all`) and the recursive interpreter that walks the demo's `chain :: RootConfig ->
[Step]` are **implemented and real-run-validated** end-to-end on real hardware (see
[phase-13](../../DEVELOPMENT_PLAN/phase-13-hostbootstrap-demo.md)).

The demo's deploy is the single `[Step]` value `demoChain :: ProjectConfig -> [Step]`
(`demo/src/HostBootstrapDemo/Commands.hs`) that the core's `project init|up|down|destroy` lifecycle
interprets recursively. There is no separate hand-written deploy script: the old `HostBootstrapDemo.Chain`
module (the Op-based `demoDeployChain` / `renderPlan` / `runDeploy`) and the flat noun-first verbs are
gone. The demo's deploy now runs as the lift sequence the core walks —
deploy-VM provider → deploy-VM → build-pb in VM → the `context-init` step in the VM → the whole `test run
all` workflow lifted into the VM-container (`incus exec <vm> -- docker run --rm <image> test all` on
Linux; `limactl shell <instance> -- docker run --rm <image> test all` on Apple Silicon) — then `project
down` / `project destroy` tears it back down. The per-case kind cluster comes up on the **VM's** Docker.

The core command tree is exactly `ensure`, `context`, `project`, `test`, and `check-code`. The flat
`cluster` and `config` verb groups and the `context create` mutation verb are removed: cluster bring-up
folds into the `deploy-kind` / `deploy-chart` chain steps, `config init` became `project init`, `config
show|schema|render` moved under read-only `context`, and `context create` became the `context-init` chain
step. The demo retains only its `web` verb (load-bearing: the chart pod runs `web serve`, the Dockerfile
runs `web bridge`) and the `vm` / `incus` debug-hatch verbs; the demo's `deploy` / `harbor` / `role`
verbs are deleted.

## The demo and its extension contract

The demo's primary contribution is its **lift chain value**, not noun verbs. The demo binary contributes
its `chain`, step actions, harness cases, Dhall vocabulary, and artifacts through `ProjectSpec`
(`demoCommands`, `demoCases`, `demoCheckCode`, `demoArtifacts`); it never re-implements or shadows a core
operation. Core ships the host-management step kinds (deploy-VM, `ensure-X`, copy-source, build-pb,
build-image, context-init, deploy-kind, deploy-chart, expose-port); the demo interleaves its own
workload step kinds (deploy-harbor, launch-web) into the same `[Step]`. This is the workload-extension
seam — host and workload steps compose in one chain.

The demo demonstrates the four-stream additive extension. Stream 1 is the **lift chain** (the ordered
`[Step]`, core + demo steps); the other three streams are unchanged:

| Stream | How the demo extends it | Observable through |
|---|---|---|
| Lift chain | the demo contributes `chain :: RootConfig -> [Step]` (its steps appended, never shadowing core's) | `project up`; `context inspect --dry-run` renders `chain rootCfg` |
| Schema-gen registry | `demoArtifacts` concatenated onto `coreArtifacts` (the demo adds a `demoWeb` pod) | `context render --artifact demoWeb` |
| Test harness | `demoCases` driven by `runMatrix` with `demoSeams`, threaded into the test surface | `test run all` |
| Config | local `hostbootstrap-demo.dhall` plus binary-generated rich schema | `context schema` / `project init` |

See [harness workflow](../architecture/harness_workflow.md) for the per-case `runMatrix` loop and the
seam-split the demo's `demoSeams` plug into, and
[authoring_project_binaries](../engineering/authoring_project_binaries.md) for how a consumer authors its
chain.

## Config: the root `.dhall` and the frames it describes

The demo's root config is the sibling `hostbootstrap-demo.dhall`. It is written by
`project init` (which produces `demo/.build/hostbootstrap-demo.dhall`, then the user
edits it). The `.dhall` carries **parameters + context + witness**, never the chain shape: it sizes the
budget and names the frame each copy of the binary occupies, and each step verifies it is in the frame
its `.dhall` describes or fails fast (see
[binary context](../architecture/binary_context_config.md)).

```text
{ dockerfile = "docker/Dockerfile"
, resources = { cpu = 6, memory = "10GiB", storage = "80GiB" }
, context =
  { project = "hostbootstrap-demo"
  , binary = "hostbootstrap-demo"
  , sourceRoot = "/home/matt/hostbootstrap/demo"
  , contextKind = ContextKind.HostOrchestrator
  , roleName = "host-orchestrator"
  , ...
  }
, deploy = { haReplicas = 1 }
}
```

The `resources` block is the demo's one budget ceiling. The chain's context-init steps carry the relevant
envelope down to the VM, runtime-container, and service frames. The Dockerfile bakes an image-build
`/usr/local/bin/hostbootstrap-demo.dhall`; the context-init step inside the chain mints the
VM-project-container config mounted over that path for the lifted `test run all`; and the chart mounts a
service-role file at the same path for webservice pods. The budget feeds both the VM sizing cordon and
the kind-node cap (see [applied cordon](../engineering/applied_cordon.md), [incus](../engineering/incus.md),
and [binary context](../architecture/binary_context_config.md)). The deploy-VM step rejects smaller
budgets before launching the VM; the full demo lifecycle needs this 6 CPU / 10 GiB / 80 GiB envelope to
hold the base-image pull, project-image build, and kind image load.

## Runtime contexts

The demo binary runs in several frames, and each frame is explicit with a sibling
`hostbootstrap-demo.dhall`. The same command tree exists in every copy; the context file is what makes a
copy refuse commands that do not belong to its frame.

| Frame | Context responsibility |
|---|---|
| Host | metal orchestrator: drives the chain (`project up` ensures the VM provider, brings the VM up; `project down` / `project destroy` tear it down) |
| VM | fresh Linux host: rebuild the host-native binary and build the project container |
| Image-build container | Dockerfile-time `check-code` and config/code generation only |
| Container on the VM | lifted `test run all`: per-case kind clusters, web build, and e2e |
| Cluster service | chart-launched webservice pod: serve only the service role |

## Lifecycle ownership

hostbootstrap owns the lifecycle of **every** resource in the demo; the **only** fail-fast dependencies
are the host minimums the Python wrapper asserts (Ubuntu 24.04 + passwordless `sudo`). Everything else is
installed, orchestrated, and torn back down by the chain:

- **(a)** the metal-orchestrator binary installs and verifies the **VM provider** (Lima on Apple Silicon,
  native Incus on Linux);
- **(b)** inside the spun-up pristine VM, **`ghcup` is installed and the binary is built on the VM**
  (host-native, by `hostbootstrap run`);
- **(c)** that binary **installs Docker (on the VM) and builds the project container**;
- **(d)** the chain lifts the **whole test workflow** into the project container in the VM; inside that
  lifted frame the harness brings up the per-case kind cluster **on the VM's Docker** (the mounted socket)
  and deploys the webservice into it;
- **(e)** **Playwright in a container on the kind network reaches the in-cluster webservice via its
  NodePort and runs the e2e tests** — still inside that one lifted workflow;
- **(f)** teardown spins everything back down, preserving host `.data`.

Every dependency is install-and-verify (the `ensure` step kinds), so the binary is never blocked by an
absent dependency.

## The lift chain (one representation)

The demo is **one** lift chain, not a harness plus a parallel chain of cluster/Harbor/web/e2e ops. The
standardized test harness (`runMatrix` + `Seams`,
[`HostBootstrap.Harness`](../architecture/hostbootstrap_core_library.md)) **is** the representation of
the test workflow: it brings up an isolated per-case environment, runs the case body, and tears it down,
invoking reconcilers (e.g. the `clusterUp` reconciler in `HostBootstrap.Cluster.Lifecycle`) "locally",
unaware of any enclosing context. The chain's only
lifted compute step lifts the **whole** `test run all` workflow into the project container in the VM.
Re-expressing cluster bring-up / web-serve / e2e as a second chain alongside the harness would be a
redundant representation. The canonical statement and the lift algebra live in
[composition_methodology](../architecture/composition_methodology.md#single-representation-the-chain-is-the-representation).

The chain drives a pristine `ubuntu/24.04` VM from zero to a running, e2e-tested `hostbootstrap-demo`,
then (on `project down` / `project destroy`) tears it back down. Only the `test run all` step is a lifted
compute step (it folds through the selected VM provider, then `docker run --rm <image> test all`); the
context-init step before it is boundary materialization that mints the exact runtime config the lifted
container mounts:

| Step | Frame | What it does |
|---|---|---|
| deploy-VM provider | `local` | reconciler on metal: install-and-verify the VM provider, Lima or Incus |
| deploy-VM | `local` | **cordon #1** — launch the budget-sized pristine VM, the wall |
| build-pb in VM | `local → VM` | the headline: build #2 (host-native binary) + build #3 (project container), both **in the VM** |
| context-init | `VM` | parent-generate the VM-project-container runtime config with topology witnesses |
| `test run all` | `inContainer img (inVM vm localContext)` | the **only** lifted compute step — folds through the VM provider, then `docker run --rm <image> test all` |

## Operator surface

The operator drives the chain through the `project` lifecycle.

- **`project init`** — write the root `hostbootstrap-demo.dhall` host-orchestrator
  config; fails fast unless run on a fresh host-level binary with no sibling `.dhall`. Optional
  `--cpu/--memory/--storage/--ha-replicas` set the budget.
- **`context`** — read-only introspection (`inspect` / `path` / `show` / `schema` / `render`): introspect
  the sibling `.dhall` and render the global lift composition (`topologyFrames` / `parentChain`) with the
  current frame highlighted. `context inspect --dry-run` renders `chain rootCfg` as the pure `[Step]` value
  without running it.
- **`project up`** — recursively interpret the chain from the current frame and
  hand off `project up` into each next frame; idempotent (reconcile-to-running). Walks deploy-VM provider
  → deploy-VM (cordon #1) → build-pb in VM (builds #2 and #3) → context-init → the lifted `test run all`.
  Inside that lifted frame the harness runs the `clusterUp` reconciler "locally" = on the **VM's** Docker,
  so the per-case kind cluster lives **in the VM**, with no second "bring up a cluster" path. The harness then
  deploys the `warp`/`wai` webservice into the per-case kind cluster via `demo/chart` (the pod runs the
  web-serve role), exposed on a NodePort; and for `e2e-tabs` starts the already-built
  `hostbootstrap-demo:local` image on the kind network and runs the base-provided Playwright runtime
  against the **in-cluster** service via its NodePort. The e2e runner uses the same project image the
  chart pod runs, so it stays native to the base-image architecture and does not pull
  `mcr.microsoft.com/playwright:*` or use `npx` during validation. When the metal host is logged in to
  Docker Hub, the orchestrator forwards that login over `stdin` so the nested pulls authenticate; the
  credential is never written into the VM or container and never appears in Dhall or `argv` (see
  [registry credentials](../engineering/registry_credentials.md)). See
  [build and run model](../architecture/build_and_run_model.md),
  [derived Dockerfile](../engineering/derived_dockerfile.md),
  [harbor](../engineering/harbor.md) for the optional in-VM registry, and
  [cluster lifecycle](../engineering/cluster_lifecycle.md) for the fail-closed `clusterUp` reconciler the
  `deploy-kind` step drives.
- **`test run all`** (lifted into the VM-container) — root-gated, needs `test.dhall`
  (written by `test init`). Drives `runMatrix` over the demo's case matrix; `all` is always a suite. A
  single case runs with `test run <case>`. It validates the live `project up` stack
  and is decoupled from the deploy.
- **`project down`** — stop services / clusters / the VM (the new
  stop-without-delete capability, `incus`/`limactl` **stop**), delete nothing.
- **`project destroy`** — stop then delete everything the
  chain spun up. Tearing the VM down removes every container, kind cluster, and registry the lifted
  workflow stood up inside it; each per-case cluster the harness created is also torn down by
  `runMatrix`'s `finally`. Host `.data` is **preserved** (the never-delete-`.data` invariant). Teardown
  is best-effort and idempotent, tolerating a partial stack. See [incus](../engineering/incus.md).

## Feature-to-harness-case table

`test run all` drives `runMatrix` over the demo's case matrix — the one workflow the
chain lifts into the VM-container. Each `demoCases` case asserts a distinct slice of the surface via its
real per-case seam; the per-case kind cluster comes up wherever the harness is lifted to — for the demo
chain, on the **VM's** Docker (live-validated, see [Current Status](#current-status)).

| Harness case | Feature demonstrated |
|---|---|
| `pristine-bootstrap` | The from-zero first-run flow (the deploy-VM provider / deploy-VM / build-pb steps): the VM sizing cordon, the in-VM `apt` / `pipx` / `hostbootstrap run` chain, the host-native binary build (#2), Docker ensure with reboot, and the project-container build (#3). |
| `web-build` | The web build path: the in-Dockerfile `check-code` gate runs before the web build; the generated PureScript matches the `warp` / `wai` webservice's API types (round-trip); the `spago` / `esbuild` bundle exists in the project image. |
| `e2e-tabs` | The served surface: the Halogen SPA tabs render and `/api/budget` returns the `fitsBudget` view from the project image's base-provided Playwright run (a container on the kind network) against the **in-cluster** webservice via its NodePort. |

## Three builds vs the standard host-native build

The standard `hostbootstrap` workflow is a **single** host-native build: the project binary is built
host-native, then it builds the project container. The demo deliberately layers a **three-build**
illustration on top of that standard build so an operator can watch a pristine host come up from zero:

- **Build #1 — the metal orchestrator.** `hostbootstrap-demo` is built on the metal host via the usual
  workflow. This is the binary that drives the chain (`project up`).
- **Build #2 — the in-VM host-native binary.** Inside the pristine VM, `hostbootstrap run` builds
  `hostbootstrap-demo` host-native (the build-pb step). This is the standard host-native build,
  reproduced from zero inside the VM.
- **Build #3 — the binary-driven project container.** The in-VM binary builds the demo container from
  `demo/docker/Dockerfile` (the build-image step), whose in-Dockerfile `check-code` step is the
  build-time gate. See [derived Dockerfile](../engineering/derived_dockerfile.md).

Builds #2 and #3 together are the standard host-native flow; build #1 is the extra orchestrator that makes
the pristine VM possible. This three-build sequence is a demo-only illustration, **not** the standard
workflow a derived project follows.
