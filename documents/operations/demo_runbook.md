# hostbootstrap-demo Runbook

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [development plan](../../DEVELOPMENT_PLAN/phase-13-hostbootstrap-demo.md)

> **Purpose**: Walk an operator through the `hostbootstrap-demo` pristine-host bootstrap run end to end — the verb sequence, which harness case proves which feature, and the demo-only three-build illustration.

## TL;DR

- `demo/` is the worked consumer `hostbootstrap-demo`: L0-direct (it consumes
  `hostbootstrap-core` directly, like `mcts`), integration mode 2
  (`source-repository-package` + `runHostBootstrapCLI`). See
  [run models](../architecture/run_models.md).
- `demo/app/Main.hs` calls `runHostBootstrapCLI "hostbootstrap-demo" demoCommands`,
  so `hostbootstrap-demo --help` shows the inherited core verbs (`ensure`,
  `config`, `cluster`, `test`, `check-code`) plus the demo's noun-first verbs
  (`incus` / `vm` / `harbor` / `web`) — no core verb is re-implemented.
- The headline is a from-zero pristine-host bootstrap performed **inside an incus
  VM** (the metal host is not pristine): `apt install pipx` → `pipx install` the
  local hostbootstrap → `hostbootstrap up`.
- Three harness cases (`pristine-bootstrap` / `web-build` / `e2e-tabs`) prove the
  surface; the run is a demo-only **three-build** illustration on top of the
  standard single host-native build.

## The demo and its extension contract

`demo/hostbootstrap.dhall` is the static-base config the Python bootstrapper reads
pre-binary to learn the project it builds and execs:

```dhall
{ project = "hostbootstrap-demo"
, dockerfile = "docker/Dockerfile"
, resources = { cpu = 6, memory = "10GiB", storage = "40GiB" }
}
```

The `resources` block is the demo's one budget ceiling. It feeds both the VM
sizing cordon and the kind-node cap (see [applied cordon](../engineering/applied_cordon.md)
and [incus](../engineering/incus.md)).

The demo demonstrates the four-stream additive extension without shadowing any
core verb:

| Stream | How the demo extends it | Observable verb |
|---|---|---|
| CLI tree | `demoCommands` appended via `runHostBootstrapCLI` (append, never shadow) | `hostbootstrap-demo --help` |
| Schema-gen registry | `demoArtifacts` concatenated onto `coreArtifacts` (the demo adds a `demoWeb` pod) | `demo web schema` prints `coreArtifacts ++ demoArtifacts` |
| Test harness | `demoCases` driven by `runMatrix` with `demoSeams` (the app supplies only its case matrix) | `demo vm test` |
| Config | static-base `hostbootstrap.dhall` plus binary-generated rich schema | `demo web schema` |

See [harness workflow](../architecture/harness_workflow.md) for the per-case
`runMatrix` loop and the seam-split the demo's `demoSeams` plugs into.

## Lifecycle ownership

hostbootstrap owns the lifecycle of **every** resource in the demo; the **only** fail-fast dependencies
are the basic host minimums the Python wrapper asserts (Ubuntu 24.04 + passwordless `sudo`). Everything
else is installed, orchestrated, and torn back down by hostbootstrap:

- **(a)** the metal-orchestrator binary installs **incus on the host** (`brew`/`apt`, via core `ensure incus`);
- **(b)** inside the spun-up pristine VM, **`ghcup` is installed and the binary is built on the VM** (host-native, by `hostbootstrap up`);
- **(c)** that binary **installs Docker and builds the project container**;
- **(d)** the **project container spins up the kind cluster and deploys the webservice**;
- **(e)** **Playwright in a container on the VM reaches the webservice and runs the e2e tests**;
- **(f)** hostbootstrap **spins everything back down**, preserving host `.data`.

The detailed verb sequence below expands this. Nothing in it is a host prerequisite beyond the Python
wrapper's minimums — every dependency is install-and-verify (the `ensure` suite), so the binary is never
blocked by an absent dependency.

## Pristine-bootstrap flow (a–k)

The run drives a pristine `ubuntu/24.04` VM from zero to a running, e2e-tested
`hostbootstrap-demo`, then tears it all back down. Each step is a demo verb that
narrates the live step it drives in a real run.

a. `demo incus ensure` — drives core `ensure incus` (install-and-verify the
   host-provider on the metal host). See [incus](../engineering/incus.md).

b. `demo vm up` — launch a budget-sized pristine `ubuntu/24.04` VM. This is
   **cordon #1**: the VM is the wall, sized `limits.cpu=6 / limits.memory=10GiB /
   root=40GiB` from the static-base budget. See
   [applied cordon](../engineering/applied_cordon.md).

c. `demo vm pristine-bootstrap` (the headline) — inside the from-zero VM:
   `apt install pipx`, then `pipx install` the local hostbootstrap wrapper pushed
   into the VM.

d. `hostbootstrap up` (run inside the VM by step c) — ensures the host toolchain
   prerequisites, then builds the demo binary **host-native** (**build #2**) and
   execs it. See [build and run model](../architecture/build_and_run_model.md).

e. The execed binary ensures Docker, rebooting the VM if the group/daemon change
   requires it, then builds the demo container (**build #3**, gated by the
   in-Dockerfile `check-code` step). See
   [derived Dockerfile](../engineering/derived_dockerfile.md).

f. `demo harbor install` — core `cluster up` inside the VM (**cordon #2**: the
   applied `docker update` kind-node cap derived from the budget) plus the Harbor
   registry. See [harbor](../engineering/harbor.md).

g. `demo harbor push` — push the arch-explicit image tag to the in-VM Harbor;
   the tag is then pullable from inside the VM.

h. `demo web serve` — serve the servant webservice on the incus host (this host
   is the Playwright `baseURL`).

i. `demo web bridge` / `demo web schema` — `web bridge` generates the PureScript
   types from the servant `DemoApi` via `purescript-bridge`; `web schema` prints
   the L0 + demo schema union (`coreArtifacts ++ demoArtifacts`).

j. Playwright e2e — runs from the container against the incus-host `baseURL` (the
   e2e target is the incus host, **not** the kind cluster): the Overview / Budget
   / Status tabs render and `/api/budget` returns the `fitsBudget` view.

k. **Spin everything down** — hostbootstrap tears down the Playwright container,
   the webservice, the kind cluster (`cluster down` / `delete`), Harbor, and the
   incus VM (the name-guarded `destroy`), **preserving host `.data`** (the
   never-delete-`.data` invariant). The whole lifecycle is hostbootstrap-owned,
   end to end. See [cluster lifecycle](../engineering/cluster_lifecycle.md) and
   [incus](../engineering/incus.md).

## Feature-to-harness-case table

`demo vm test` drives `runMatrix` over the demo's case matrix. Each `demoCases`
case demonstrates a distinct slice of the surface.

| Harness case | Feature demonstrated |
|---|---|
| `pristine-bootstrap` | The from-zero first-run flow (steps a–g): `ensure incus`, the VM sizing cordon, the in-VM `apt`/`pipx`/`hostbootstrap up` chain, the host-native binary build, Docker ensure with reboot, the project-container build, and the kind + Harbor cordon and push. |
| `web-build` | The web build path (steps e, i): the in-Dockerfile `check-code` gate runs before the web build; the generated PureScript matches the servant API (round-trip); the `spago`/`esbuild` bundle exists. |
| `e2e-tabs` | The served surface (steps h, j): the Halogen SPA tabs render and `/api/budget` returns the `fitsBudget` view from the Playwright run against the incus-host `baseURL`. |

## Three builds vs the standard host-native build

The standard `hostbootstrap` workflow is a **single** host-native build: the
project binary is built host-native, then it builds the project container. The
demo deliberately layers a **three-build** illustration on top of that standard
build so an operator can watch a pristine host come up from zero:

- **Build #1 — the metal orchestrator.** `hostbootstrap-demo` is built on the
  metal host via the usual workflow. This is the binary that runs `demo incus
  ensure` / `demo vm up` / `demo vm pristine-bootstrap`.
- **Build #2 — the in-VM host-native binary.** Inside the pristine VM,
  `hostbootstrap up` builds `hostbootstrap-demo` host-native (step d). This is the
  standard host-native build, reproduced from zero inside the VM.
- **Build #3 — the binary-driven project container.** The in-VM binary builds the
  demo container from `demo/docker/Dockerfile` (step e), whose in-Dockerfile
  `check-code` step is the build-time gate. See
  [derived Dockerfile](../engineering/derived_dockerfile.md).

Builds #2 and #3 together are the standard host-native flow; build #1 is the extra
orchestrator that makes the pristine VM possible. This three-build sequence is a
demo-only illustration, **not** the standard workflow a derived project follows.
