# Build and Run Model

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [python_haskell_boundary](python_haskell_boundary.md), [hostbootstrap_core_library](hostbootstrap_core_library.md), [resource_budgeting](../engineering/resource_budgeting.md), [binary_context_config](binary_context_config.md)

> **Purpose**: Define the build/run model — why every project binary is built **host-native** into
> `./.build/`, why building the project container is the binary's job, and how the four run-models are
> selected within `project up`'s step interpretation, where deploy stands up a **persistent stack**.

## TL;DR

- Every project produces one host binary at `./.build/<binary>`, built **host-native** on every
  substrate — the same way everywhere. A Linux ELF cannot exec on a general host such as Apple silicon,
  so there is **no** build-in-container, copy-out path.
- The Python bootstrapper is the **metal-frame** of the fractal bootstrap: it ensures the host build
  toolchain, builds the binary host-native, and execs it. Building the **project container** is the
  execed binary's job, gating on the `check-code` code-check.
- The four run-models (`OneShot`, `HostNative`, `HostDaemon`, `Cluster`) are **selected** from detected
  facts and generated topology — never declared in Dhall. They are selected
  **within `project up`'s interpretation of the lift chain's `[Step]`**, one step at a time, each a
  derived fact of the step being interpreted.
- `project up` runs deploy as a **persistent stack**: it reconciles the chain to running (idempotent),
  leaving the VM, cluster, and services up. `project down` deletes kind compute and stops VM frames;
  `project destroy` deletes everything spun up. `.data` is preserved across both.
- The build/run model is the canonical home for **host-native build mechanics**; the chain model itself
  is owned by [composition_methodology](composition_methodology.md), which this doc defers to.

## Why the binary is built host-native

A `hostbootstrap` binary is a native executable for one OS/arch. A binary built inside a Linux
container is a Linux ELF; it cannot exec on a general host such as Apple silicon. Every substrate
builds the binary **host-native**, for the host it will run on:

| Substrate | Where the binary is built | Where it runs | Why |
|-----------|---------------------------|---------------|-----|
| `linux-cpu` / `linux-gpu` | Host-native (the bootstrapper ensures the host GHC/Cabal toolchain) | On the host | The binary is built directly for the host; no container round-trip. |
| `apple-silicon` | Host-native (the bootstrapper ensures a host GHC toolchain via Homebrew → `ghcup`) | On the host | A Linux ELF cannot exec on macOS, so the runnable binary must be a native macOS build. |
| `windows-cpu` / `windows-gpu` | Host-native (the bootstrapper ensures a host GHC toolchain via GHCup, with **winget** as the Homebrew-analog pre-binary package-manager floor) | On the host | The binary is the native Windows `hostbootstrap.exe` (mingw32 GHC), the peer of the macOS arm64 binary; a Linux ELF cannot exec on Windows. |

In all cases the result is a `./.build/<binary>` host executable. Consumers and the test harness run
`./.build/<binary>`; they never reach into a container to run the host binary. Normal command dispatch
requires the sibling `./.build/<project>.dhall`: the root host-orchestrator config the built binary
mints for itself (the `project init` surface, see [Current Status](#current-status)). Immediately after
the build that config is normally **absent** — Python does not create or trigger it — so a normal command
run before `project init` **fails fast** (exit 1); `project init` (or the harness, which generates the
config) is what brings it into existence.

## Why `./.build/` Is Always Present

`./.build/<binary>` is the single, stable location every consumer and the test harness exec. Building
it host-native on every substrate means downstream tooling does not branch on substrate to locate or
run the binary. See [python_haskell_boundary](python_haskell_boundary.md) for the bootstrap sequence
that produces it.

The bootstrapper populates that path with a plain, incremental `cabal build exe:<project>` (not
`cabal install`): it asks cabal for the freshly built executable's path under `dist-newstyle/` via
`cabal list-bin exe:<project>` and copies it to `./.build/<project>`. `cabal build` is incremental and,
on an unchanged rerun, prints just `Up to date` — it does not re-package each local source into an
sdist tarball, re-resolve the plan, or copy the exe on every invocation the way `cabal install` does,
so a warm rerun is quiet while a genuine cold build still shows live compile progress. This mirrors the
in-container build, which already uses `cabal build` + `list-bin`.

## No Automatic Wrapper Freshness Check

The build/run model stays offline-capable after installation. The bootstrapper does not contact GitHub,
compare the installed wrapper to the default branch, or mutate the pipx environment before building the
project binary. Updating the wrapper is an explicit operator action documented in
[self_update](../engineering/self_update.md), not a precondition for a normal build or run.

## Where the host build cache lives

The host-native `cabal build` keeps its package store **repo-local** at `./.build/cabal-store/`
(passed as cabal's global `--store-dir`), not in the user-global store at
`~/.local/state/cabal/store/`. Because `./.build/` is git-ignored, `git clean -fxd` resets the **full**
host build state — the compiled dependency closure included — so a cleaned tree rebuilds cold rather
than silently reusing deps from a shared user store. This is the host build's store only; it is
distinct from, and shares nothing with, the in-container warm store at `/opt/cache/cabal/` that the
later project-container build reuses (see [warm_store](../engineering/warm_store.md)).

## Headless Host Build (Windows CUDA)

Some build artifacts are platform-locked to the bare host and cannot be produced in a build VM. The
**headless host build** is the shape for them: build the artifact directly on the bare host, stage it
into the cluster, and never run the workload in a build VM (composition pattern #7, see
[composition_patterns](../engineering/composition_patterns.md)). The first worked instance is
CUDA-on-Windows: the `ensure cudawin` reconciler readies the Windows host CUDA build stack — the NVIDIA
driver, the CUDA Toolkit, and the MSVC C++ build tools (nvcc's host compiler) — via **winget**, then
nvcc artifacts are produced on the bare Windows host, copied into `./.build/`, and staged into the
cluster. No workload ever runs in a build VM; the host is the build environment, not a runtime. The
`ensure cudawin` reconciler therefore fails fast off a Windows GPU host — see
[ensure_reconcilers](../engineering/ensure_reconcilers.md) and [cuda](../languages/cuda.md). This is a
distinct concern from the in-container `linux-gpu` nvidia-container-toolkit path (`ensure cuda`), which
stays as is.

## The Project Container Is the Binary's Job

The Python bootstrapper does **not** ensure Docker or build the project container. Once the
host-native binary is built and execed, the **binary** does that work, because it can do everything a
built binary reasonably can:

- **Ensure Docker**: the binary's Docker reconciler provisions and verifies Docker (on Apple, the
  per-project Colima VM sized to the resource budget; on Linux, the daemon plus invoking-user socket
  access for the current session and future login sessions). This is an `ensure`
  reconciler invoked as a **chain step** within `project up`. See
  [resource_budgeting](../engineering/resource_budgeting.md).
- **Build the project container** `FROM` the base image, gating on the project's canonical code-check
  (formatting, lint, type/compile checks). Building the container is the mechanism that enforces this
  gate. The Dockerfile first mints the container's sibling `/usr/local/bin/<project>.dhall` so the
  container's normal commands read a context that names the container frame. See
  [code_check_doctrine](../engineering/code_check_doctrine.md) and
  [binary_context_config](binary_context_config.md).

The two builds are distinct and owned by distinct layers: the bootstrapper's host-native binary build
(the prerequisite to having any binary at all) and the binary's later container build (the code-check
gate and any container-resident services). Neither is redundant — collapsing them would either skip
the gate or ship an unrunnable binary. This is the **fractal bootstrap**: provision a frame, build or
install the binary in it, then hand off the binary's own subcommand into the next frame. The Python
bootstrapper is the metal-frame instance of that pattern; the container frame skips the build and runs
the binary the image already carries. See [composition_methodology](composition_methodology.md).

## Run-Models Are Selected Within `project up`

The four run-models — `OneShot`, `HostNative`, `HostDaemon`, `Cluster` — are **selected** from
detected substrate and the generated topology, never declared in Dhall. The canonical definition lives
in [run_models](run_models.md); this section states only *when* the selection happens.

`project up` recursively interprets the lift chain — an ordered `[Step]` produced
by the project's `chain :: cfg -> [Step]` value (the demo's `demoChain`). Each step that runs
compute selects its run-model from the facts in force at that step, **inside the interpretation of the
chain**:

- a build-image or `OneShot`-shaped step resolves to `OneShot`/`HostNative`;
- a long-running serving step resolves to `HostDaemon`;
- a cluster step resolves to `Cluster`, realized by the kind/Helm
  [cluster_lifecycle](../engineering/cluster_lifecycle.md).

The run-model is a derived fact of the step being interpreted, never declared up front. A long-running
serving step is a service role run via `service run` — a **leaf-frame pod entrypoint** deployed by the
`deploy-chart` step, resolving a Dhall `ServiceType` variant against the service-handler registry, with
**no `service down`** (its lifetime is the pod's). See [run_models](run_models.md) for the `service`
command and handler registry.

The test harness is **not** a separate cluster-standup path: it **drives the real `project up`**. The
harness **generates** a test `<project>.dhall` (functionally, via the project's own builder — never
shelling the CLI), runs `project up`, asserts in-frame via the self-reference lift, then runs
`project destroy`. A suite may declare more than one config variant, and the harness stands each up and
tears it down in turn (the demo runs two), never an isolated per-case cluster via a separate seam path.
Because it drives the same `project up`, the `Cluster` model comes up wherever that `project up` runs, on
the Docker the running process sees — see [composition_methodology](composition_methodology.md) for the
single-representation rule.

## Deploy Is a Persistent Stack

Deploy is what `project up` leaves running: a **persistent stack**, not a
run-to-completion job. `project up` reconciles the chain to running and is idempotent — a rerun against
a partially-up stack converges the remainder rather than rebuilding from zero. The VM, the cluster, and
the workload services stay up after `project up` returns.

The lifecycle verbs are split so the persistent stack has explicit stop and delete transitions:

| Verb | Effect | `.data` |
|------|--------|---------|
| `project up` | Reconcile the chain to running; leave the persistent stack up. | preserved |
| `project down` | Delete kind clusters and stop provider VMs (e.g. `incus stop` / `limactl stop`, or `wsl --shutdown` on Windows); preserve durable state. | preserved |
| `project destroy` | Stop, then delete everything spun up. | preserved |

`.data` is preserved across `down` and `destroy` — a core invariant. Teardown recurses **in** while the
frame is still up, then stops or deletes on ascent (the VM stopped last); it is best-effort and
idempotent, tolerating a partial stack. The test harness validates the live stack by **driving the same
`project up`** (generating a test `<project>.dhall` functionally, running `project up`, asserting in-frame
with the assertion polymorphic over the active variant's `EXPECTED_MESSAGE`, then `project destroy`),
iterating over each config variant the suite declares (the demo runs two), using durable test storage
`.test_data` and never touching `.data` — see [harness_workflow](harness_workflow.md).

## The VM Provider Parameterization

A native Linux operation can run against a typed **host target**: the local host or an Incus VM. This is a
host-provider axis orthogonal to substrate — the VM is still a `linux-cpu`/`linux-gpu` machine inside, and
the host target is not a fifth run-model. It parameterizes the existing run-models rather than adding to
them. The declared resource **budget is the one ceiling — the VM wall**: the VM is sized to the budget,
and the in-VM cluster is a **slice within that wall**, not a separate budget-sized allocation. There is
**no budget-sized VM headroom and no doubling** (see [resource_budgeting](../engineering/resource_budgeting.md)).
The wall is a hard per-VM cap on Incus and Lima; on WSL2 — which has no per-distro cap — it is the global
`.wslconfig` utility-VM ceiling plus a per-distro VHDX cap (see
[applied_cordon](../engineering/applied_cordon.md)).

```haskell
data HostTarget = Local | InVM IncusVM
```

Every linux-host operation runs through one dispatch point, `runInTarget`, against `Local` or `InVM`,
with **no per-call branching** at the call sites. `runInTarget cfg Local t args` runs the resolved
tool directly; `runInTarget cfg (InVM vm) t args` dispatches through one host
`incus exec <name> -- <tool> <args>` into the VM (where the in-VM `<tool>` is the VM's own `$PATH`
binary, since the VM is a separate machine). The host target sits underneath the run-models in
[run_models](run_models.md), so the same machinery runs identically whether the Linux host is local or
encapsulated in an Incus VM. See
[incus](../engineering/incus.md) for the host-provider axis, the Incus install reconciler, and the VM
lifecycle (including stop-without-delete for `project down`).

The two-case `HostTarget` is the **tool-level** lift; the **subcommand-level self-reference lift**
(`HostBootstrap.Lift`) generalizes it to an n-level context stack (`Local | InVM | InContainer`), where a
binary crosses a boundary by invoking its *own* subcommand in the nested context. The Apple Silicon demo
uses the Lima VM provider (`limactl shell <instance> -- ...`); native Linux uses Incus
(`incus exec <vm> -- ...`); Windows uses WSL2 Ubuntu-24.04, the Windows VM-provider frame and peer of
Lima/Incus (`wsl -d <distro> -- ...`, see [wsl2](../engineering/wsl2.md)); containers use
`docker run --rm`. `project up` is the
**recursive interpreter** of that lift: it runs the current frame's steps, then hands off
`<binary> project up` into the next frame, where the child owns its segment and verifies it is in the
frame its `.dhall` describes. See [composition_methodology](composition_methodology.md).

## Current Status

The reconciled behavior here is implemented: the harness **drives the real `project up`** rather than a
separate per-case cluster path, the service run-model runs via `service run` and is deployed by
`deploy-chart`, and the resource model is **budget-is-the-VM-wall / cluster-is-a-slice** with no doubling.
Those surfaces are closed in the development plan.

The **Windows** substrate is partially closed. `windows-cpu`/`windows-gpu` detection, native
`hostbootstrap.exe` host-native build via winget-rooted GHCup, and the headless host build's `ensure
cudawin` CUDA stack are implemented and validated at the code/unit level. The WSL2 Ubuntu-24.04 VM frame
(`ensure wsl2`, the Windows peer of Lima/Incus — see [wsl2](../engineering/wsl2.md)) closed in phase-11
on 2026-07-01 when the real Windows/WSL2 lifecycle completed through `test run all` (`6/6`) and `project destroy`.

The **fixed core command surface** is exactly `project`, `test`, `service`, `context`, and `check-code` —
there are **no per-project verbs**. A project extends core through streams (lift chain, Dhall vocabulary,
schema-gen, test seams, and service handlers), never by adding command verbs.

The host-native, no-copy-out build is the mechanism: Python ensures the host toolchain, builds the
binary into `./.build/`, and execs it; the binary ensures Docker and builds the project container
`FROM` the base image, gating on `check-code`.

The recursive `project` command and the `[Step]` chain interpreter described above run end-to-end on
real hardware. A single `project up` on Incus/Linux stands up the live persistent stack — the cordoned
kind cluster (kind `extraPortMappings` publish NodePorts to the VM localhost) → the production Harbor
(NodePort 30500) → the project image pushed to the in-cluster registry → the web chart pod serving
`localhost:30080` with HTTP 200 — and `project down` / `project destroy` tear it down with host `.data`
preserved.

- **The `project` chain:** a single `chain :: cfg -> [Step]` value the core interprets,
  driven by `project init|up|down|destroy`, a read-only `context` introspection command that treats every
  `<project>.dhall` uniformly, the `service` command (`service run` runs one long-running role), and the
  `test` harness. Run-model selection (`selectRunModel`) and the `HostTarget` tool-level lift are real;
  the four run-models are real. The **fixed** core command surface is exactly `project`, `test`,
  `service`, `context`, `check-code` — no per-project verbs. The demo's deploy is
  `demoChain :: ProjectConfig -> [Step]` in `demo/src/HostBootstrapDemo/Commands.hs`; the demo's
  `web serve` resolves to `service run` (`Web` variant) and `web bridge` to the build-image step, both
  extensions of core via the service-handler and lift-chain streams rather than new verbs. `project down`
  deletes kind compute and stops VM frames while preserving durable state.
- **The chain steps:** `project up` interprets the chain across three frames. The metal frame runs
  `deploy-VM` (ensure the provider, launch the budget-sized VM) and `build-pb` (the host-native binary
  build plus the project-image build in the VM), then hands off into the VM. The in-VM frame runs
  `context-init`, which mints the child `<project>.dhall` for the project container and streams it in-place
  into the container over the handoff `stdin` (no config bind-mount), then hands off into the container. The container frame runs `deploy-kind` (the cordoned kind cluster — a slice within the
  VM wall) → `deploy-harbor` (the in-cluster Harbor registry) → `push-image` (kind-load + push the
  project image) → `deploy-chart` (deploys the service pod whose entrypoint is `service run`, with the
  active config delivered as a ConfigMap overriding the baked container `<project>.dhall`) →
  `expose-port` (verify the NodePort). Core ships the
  host-management step kinds; the demo interleaves its workload step kinds into the same `[Step]`. The
  kind/Helm reconcilers (`clusterUp`/`clusterCreate`/`deployChart`/`clusterDown`/`clusterDelete`) live in
  `HostBootstrap.Cluster.Lifecycle`, invoked by the chain steps and the teardown path. `project down` /
  `project destroy` and read-only `context inspect` carry the teardown and status roles.

`DEVELOPMENT_PLAN/` owns the phase status. The `project` command and the recursive interpreter are the
model this doc describes throughout.

## See also

- [composition_methodology](composition_methodology.md) — canonical home of the chain / `[Step]` model,
  the recursive `project up` interpreter, the fractal bootstrap, and single representation.
- [run_models](run_models.md) — the four run-models and the selection key that `project up` consumes per
  step.
- [python_haskell_boundary](python_haskell_boundary.md) — the metal-frame bootstrap that produces
  `./.build/<binary>`.
- [binary_context_config](binary_context_config.md) — how each frame's `<project>.dhall` lets the binary
  verify its place before side effects.
- [cluster_lifecycle](../engineering/cluster_lifecycle.md) — the kind/Helm lifecycle the `Cluster`
  run-model drives as a chain step.
