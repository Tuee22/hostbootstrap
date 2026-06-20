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
- The demo's identity is its **lift chain** — `chain :: ProjectConfig -> [Step]`, a single ordered value
  the core interprets. The demo contributes that chain (plus its step actions, harness cases, and Dhall
  vocabulary) through `ProjectSpec`. The canonical statement of the chain-is-the-project model lives in
  [composition_methodology](../architecture/composition_methodology.md); this runbook walks the
  demo's instance of it.
- The headline is a from-zero pristine-host bootstrap performed **inside a managed Linux VM** (Lima on
  Apple Silicon, Incus on native Linux; the metal host is not pristine): `apt install pipx` →
  `pipx install` the local hostbootstrap → `hostbootstrap run`. The Python bootstrapper is the
  metal-frame instance of the same fractal pattern (provision the frame → build the binary in it → hand
  off `project up`).
- `project up` / `project down` / `project destroy` drive the chain, `context` visualizes it, and
  `test run all` validates the surface by **driving the same `project up`** under a test config. The deploy
  is **one** representation: the `[Step]` chain. `project up` stands up a persistent stack; `test run all`
  reuses that chain (write a test `<project>.dhall` → `project up` → assert → `project destroy`, one
  `project up` per distinct test config), with no separate per-case bring-up.
- The three harness cases (`pristine-bootstrap` / `web-build` / `e2e-tabs`) prove the surface; the
  run is a demo-only **three-build** illustration on top of the standard single host-native build.

## Current Status

The operator surface below (`project init|up|down|destroy`, read-only `context`, `test init` /
`test run <suite>|all`) and the recursive interpreter that walks the demo's `chain :: ProjectConfig ->
[Step]` are real-run-validated end-to-end on real hardware (see
[phase-13](../../DEVELOPMENT_PLAN/phase-13-hostbootstrap-demo.md)).

The demo's deploy is the single `[Step]` value `demoChain :: ProjectConfig -> [Step]`
(`demo/src/HostBootstrapDemo/Commands.hs`) that the core's `project init|up|down|destroy` lifecycle
interprets recursively. The chain descends three frames: the metal `host-orchestrator-0` provisions the
VM and builds the pb and image in it; the in-VM `vm-orchestrator-1` mints the project-container child
config and hands off; the in-container `vm-project-container-2` stands up the persistent stack
(deploy-kind → deploy-harbor → push-image → deploy-chart → expose-port). Each frame's binary runs only
its own segment, then hands off `project up` one level down. `project up` ends at a live webservice on
`localhost:30080`. `project down` stops the VM and `project destroy` deletes it; both preserve host
`.data`.

The core command tree is exactly `ensure`, `context`, `project`, `test`, and `check-code`. Cluster
bring-up is the `deploy-kind` / `deploy-chart` chain steps; `project init` writes the root config;
`context` carries the read-only `show` / `schema` / `render` introspection; and `context-init` is the
chain step that mints a child config. The demo contributes its long-running web role as a `service` variant
(the chart pod runs `service run`, the `Web` variant; the Dockerfile's PureScript→JS bridge runs as the
build-image step) and its VM/provider IO as chain steps — the `vm` / `incus` / `web` verbs are removed (the
surface is fixed; see [legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md)). The deploy
itself is the contributed `demoChain` interpreted by `project up`.

## The demo and its extension contract

The demo's primary contribution is its **lift chain value**. The demo binary contributes its `chain`,
step actions, harness cases, Dhall vocabulary, and artifacts through `ProjectSpec` (`demoCommands`,
`demoCases`, `demoCheckCode`, `demoArtifacts`); it never re-implements or shadows a core operation. Core
ships the host-management step kinds (deploy-VM, `ensure-X`, copy-source, build-pb, build-image,
context-init, deploy-kind, deploy-chart, expose-port); the demo interleaves its own workload step kinds
(deploy-harbor, push-image) into the same `[Step]`. This is the workload-extension seam —
host and workload steps compose in one chain.

The demo demonstrates the additive extension streams (the command surface is **fixed** — a project adds no
verbs). Stream 1 is the **lift chain** (the ordered `[Step]`, core + demo steps); the others are the Dhall
vocabulary, the schema-gen registry, the test harness, and the **service handlers** (the demo's `Web`
service variant run by `service run`):

| Stream | How the demo extends it | Observable through |
|---|---|---|
| Lift chain | the demo contributes `chain :: ProjectConfig -> [Step]` (its steps appended, never shadowing core's) | `project up`; `project up --dry-run` renders `chain rootCfg` |
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
envelope down to the VM, project-container, and service frames. The Dockerfile bakes an image-build
`/usr/local/bin/hostbootstrap-demo.dhall`; the context-init step inside the chain mints the
VM-project-container config mounted over that path for the in-container frame; and the chart mounts a
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
| Host (`host-orchestrator-0`) | metal orchestrator: drives the chain (`project up` ensures the VM provider, brings the VM up, builds the binary and image in it; `project down` / `project destroy` tear the VM down) |
| VM (`vm-orchestrator-1`) | fresh Linux host: build the host-native binary and the project container, then mint the project-container child config and hand off `project up` |
| Image-build container | Dockerfile-time `check-code` and config/code generation only |
| Container on the VM (`vm-project-container-2`) | stand up the persistent stack: the kind cluster, Harbor, the pushed image, the web chart pod, and the verified NodePort |
| Cluster service | chart-launched webservice pod: runs `service run` (`Web` variant) under a ConfigMap-delivered service-role config |

## Lifecycle ownership

hostbootstrap owns the lifecycle of **every** resource in the demo; the **only** fail-fast dependencies
are the host minimums the Python wrapper asserts (Ubuntu 24.04 + passwordless `sudo`). Everything else is
installed, orchestrated, and torn back down by the chain:

- **(a)** the metal-orchestrator binary installs and verifies the **VM provider** (Lima on Apple Silicon,
  native Incus on Linux);
- **(b)** inside the spun-up pristine VM, **`ghcup` is installed and the binary is built on the VM**
  (host-native, by `hostbootstrap run`);
- **(c)** that binary **installs Docker (on the VM) and builds the project container**;
- **(d)** the chain hands `project up` into the project container in the VM, where the container frame
  brings up the persistent kind cluster **on the VM's Docker** (the mounted socket), installs the
  in-cluster Harbor registry, loads and pushes the project image, and deploys the webservice into the
  cluster;
- **(e)** the **expose-port** step verifies the published NodePort, ending `project up` at a live
  webservice on `localhost:30080`;
- **(f)** teardown spins everything back down, preserving host `.data`.

Every dependency is install-and-verify (the `ensure` step kinds), so the binary is never blocked by an
absent dependency.

## The lift chain (one representation)

The demo's deploy is **one** lift chain. It descends three frames and stands up a persistent stack,
handing off `project up` one frame at a time. The canonical statement and the lift algebra live in
[composition_methodology](../architecture/composition_methodology.md#single-representation-the-chain-is-the-representation).

The chain drives a pristine `ubuntu/24.04` VM from zero to a running, end-to-end-served
`hostbootstrap-demo`, then (on `project down` / `project destroy`) tears it back down. The metal frame
provisions the VM and builds the binary and image in it; the in-VM frame mints the project-container
child config; the in-container frame stands up the kind cluster, Harbor, the pushed image, the web chart
pod, and the verified NodePort:

| Step | Frame | What it does |
|---|---|---|
| deploy-VM provider | `host-orchestrator-0` | reconciler on metal: install-and-verify the VM provider, Lima or Incus |
| deploy-VM | `host-orchestrator-0` | **cordon #1** — launch the budget-sized pristine VM, the wall |
| build-pb in VM | `host-orchestrator-0` | the headline: build #2 (host-native binary) + build #3 (project container), both **in the VM** |
| context-init | `vm-orchestrator-1` | mint the project-container child config with topology witnesses, then hand off `project up` into the container |
| deploy-kind | `vm-project-container-2` | **cordon #2** — bring up the persistent kind cluster (Production profile) on the VM's Docker |
| deploy-harbor | `vm-project-container-2` | install the in-cluster Harbor registry (NodePort 30500) |
| push-image | `vm-project-container-2` | load the project image into kind and push it to Harbor |
| deploy-chart | `vm-project-container-2` | deploy the `warp` / `wai` web service chart pod (NodePort 30080) |
| expose-port | `vm-project-container-2` | verify the web NodePort 30080 is reachable, ending at the live webservice |

## Operator surface

The operator drives the chain through the `project` lifecycle.

- **`project init`** — write the root `hostbootstrap-demo.dhall` host-orchestrator
  config; fails fast unless run on a fresh host-level binary with no sibling `.dhall`. Optional
  `--cpu/--memory/--storage/--ha-replicas` set the budget.
- **`context`** — read-only introspection (`inspect` / `path` / `show` / `schema` / `render`): introspect
  the sibling `.dhall` and render the global lift composition with the current frame highlighted.
  `project up --dry-run` renders `chain rootCfg` as the pure `[Step]` plan without running it.
- **`project up`** — recursively interpret the chain from the current frame and
  hand off `project up` into each next frame; idempotent (reconcile-to-running). On the metal
  `host-orchestrator-0` frame it walks deploy-VM provider → deploy-VM (cordon #1) → build-pb in VM
  (builds #2 and #3), then hands off into the VM. The in-VM `vm-orchestrator-1` frame's context-init step
  mints the project-container child config and hands off into the container. The in-container
  `vm-project-container-2` frame then brings up the persistent kind cluster (cordon #2, Production
  profile) on the **VM's** Docker, installs the in-cluster Harbor registry (NodePort 30500), loads and
  pushes the `hostbootstrap-demo:local` image to Harbor, deploys the `warp` / `wai` web service chart pod
  (NodePort 30080, the pod's entrypoint is `service run`, the `Web` variant), and verifies the NodePort — ending at a live
  webservice on `localhost:30080`. When the metal host is logged in to Docker Hub, the orchestrator
  forwards that login over `stdin` so the nested pulls authenticate; the credential is never written into
  the VM or container and never appears in Dhall or `argv` (see
  [registry credentials](../engineering/registry_credentials.md)). See
  [build and run model](../architecture/build_and_run_model.md),
  [derived Dockerfile](../engineering/derived_dockerfile.md),
  [harbor](../engineering/harbor.md) for the in-cluster registry, and
  [cluster lifecycle](../engineering/cluster_lifecycle.md) for the fail-closed `clusterUp` reconciler the
  `deploy-kind` step drives.
- **`test run all`** — root-gated, needs `test.dhall` (written by `test init`). Drives `runMatrix` over the
  demo's case matrix; `all` is always a suite; a single case runs with `test run <case>`. Per distinct test
  config the harness writes a test `hostbootstrap-demo.dhall`, runs the real `project up`, asserts in-frame,
  and tears down with `project destroy` — it reuses the deploy chain rather than standing up a separate
  per-case cluster. Two fail-fast preconditions run first: refuse if a `hostbootstrap-demo.dhall` exists or
  if a production cluster is running; teardown removes only the config and `.test_data` it created.
- **`project down`** — stop the VM (the cluster stops with it), delete nothing.
- **`project destroy`** — stop then delete everything the
  chain spun up. Tearing the VM down removes every container, kind cluster, and registry the chain stood
  up inside it. Host `.data` is **preserved** (the never-delete-`.data` invariant). Teardown is
  best-effort and idempotent, tolerating a partial stack. See [incus](../engineering/incus.md).

## Feature-to-harness-case table

`test run all` drives `runMatrix` over the demo's case matrix — the standardized harness, which **drives
the real `project up`** under a test config rather than being a separate bring-up. Per distinct test config
the harness writes a test `hostbootstrap-demo.dhall` (the Test profile, data under `./.test_data/`), runs
`project up`, and tears the stack down with `project destroy` (guaranteed through `finally`); each
`demoCases` case asserts a distinct slice of the live stack in the frame appropriate to it (e.g. the
`e2e-tabs` Playwright assertion as a container on the kind network in the VM frame, outside the cluster).
*(Target; the harness recast is reopened, real-run-gated — phase-10/13/17.)*

| Harness case | Feature demonstrated |
|---|---|
| `pristine-bootstrap` | The from-zero first-run flow (the deploy-VM provider / deploy-VM / build-pb steps): the VM sizing cordon, the in-VM `apt` / `pipx` / `hostbootstrap run` chain, the host-native binary build (#2), Docker ensure, and the project-container build (#3). |
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

## Apple Silicon readiness

On Apple Silicon the chain runs on a Lima VM (`--vm-type vz`, macOS 13+) instead of Incus; the Lima
command surface (`limactl start`/`shell`/`copy`/`stop`/`delete`) and the source-staging, metal→VM handoff,
and sizing steps are symmetric with the Incus path. Before the first Apple run an operator satisfies these
substrate-specific prerequisites:

- **Republish the `arm64` base first.** The project image resolves its base to
  `docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64`, which build #3 pulls inside the Lima VM. The
  base build is single-arch host-native, so the `arm64` tag is rebuilt and republished **from the Apple
  Silicon machine**: `hostbootstrap base build-and-push --flavor cpu --arch arm64`. The republished tag
  carries the `core.freeze`/`daemon.freeze` split the repo's `core/warm-deps` projection expects. A
  consumer never works around a stale published base by editing `container.cabal.project` to import a
  freeze the published base does not ship. See [base image](../engineering/base_image.md) and
  [build & release](../engineering/build_release.md).
- **Verify the `arm64` image set.** The Harbor chart and the project image's Playwright browsers
  (`chromium`/`firefox`/`webkit`) pull `linux/arm64` images. An operator confirms each `goharbor/*`
  sub-image and the WebKit system dependencies resolve on `aarch64` before relying on the Apple path, so
  `deploy-harbor`'s `--wait` and the `e2e-tabs` case do not stall on a missing-arch image.
- **Provision host disk.** Lima sizes `--disk` only on first creation of the instance, and the
  budget-sized VM needs ~100 GiB of free APFS space to grow into. An operator deletes any stale
  `hostbootstrap-demo-vm` instance (`limactl delete`) so the fresh sizing takes effect, and confirms the
  free space before the run.
- **Forward the host NodePort.** `expose-port` verifies the webservice from inside the VM; the macOS host
  reaching `localhost:30080` depends on Lima forwarding the `0.0.0.0`-bound guest NodePort, which a
  current Lima does by default. An operator pins a Lima version that forwards `0.0.0.0` guest ports. See
  [Lima provider](../engineering/lima.md).
- **Forward the registry credential.** A Docker Hub login stored in the macOS keychain (`credsStore`)
  carries no inline token, so the in-VM base pull degrades to an anonymous, rate-limit-prone pull. To
  forward the authenticated pull an operator supplies an inline `auths` token (a `DOCKER_CONFIG` whose
  `config.json` carries a plaintext Docker Hub entry).
