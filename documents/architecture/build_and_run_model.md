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
  **within `project up`'s interpretation of the lift chain's `[Step]`**, one step at a time, not by a
  standalone `cluster` or `deploy` verb.
- `project up` runs deploy as a **persistent stack**: it reconciles the chain to running (idempotent),
  leaving the VM, cluster, and services up. `project down` stops them; `project destroy` deletes them.
  `.data` is preserved across both.
- The build/run model is the canonical home for **host-native build mechanics**; the chain model itself
  is owned by [composition_methodology](composition_methodology.md), which this doc defers to.

## Why the binary is built host-native

A `hostbootstrap` binary is a native executable for one OS/arch. A binary built inside a Linux
container is a Linux ELF; it cannot exec on a general host such as Apple silicon. Earlier designs
built the binary in the project container and copied it out — that was abandoned for exactly this
reason. Every substrate builds the binary **host-native**, for the host it will run on:

| Substrate | Where the binary is built | Where it runs | Why |
|-----------|---------------------------|---------------|-----|
| `linux-cpu` / `linux-gpu` | Host-native (the bootstrapper ensures the host GHC/Cabal toolchain) | On the host | The binary is built directly for the host; no container round-trip. |
| `apple-silicon` | Host-native (the bootstrapper ensures a host GHC toolchain via Homebrew → `ghcup`) | On the host | A Linux ELF cannot exec on macOS, so the runnable binary must be a native macOS build. |

In all cases the result is a `./.build/<binary>` host executable. Consumers and the test harness run
`./.build/<binary>`; they never reach into a container to run the host binary. Normal command dispatch
requires the sibling `./.build/<project>.dhall`: the root host-orchestrator config the built binary
mints for itself (the `project init` surface, see [Current Status](#current-status)).

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

## Tart Is Build-Only

Tart hosts a macOS VM used to produce Swift/Metal build artifacts on Apple silicon. Those artifacts
are copied to `./.build/` and run on the host. No built binary ever runs inside the Tart VM; the VM
is a build environment, not a runtime. The `ensure tart` reconciler therefore fails fast on Linux —
see [ensure_reconcilers](../engineering/ensure_reconcilers.md).

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
by the project's `chain :: ProjectConfig -> [Step]` value (the demo's `demoChain`). Each step that runs
compute selects its run-model from the facts in force at that step, **inside the interpretation of the
chain**:

- a build-image or `OneShot`-shaped step resolves to `OneShot`/`HostNative`;
- a long-running serving step resolves to `HostDaemon`;
- a cluster step resolves to `Cluster`, realized by the kind/Helm
  [cluster_lifecycle](../engineering/cluster_lifecycle.md).

There is no standalone `cluster` or `deploy` verb that fixes a run-model up front; the model is a
derived fact of the step being interpreted. The test harness remains the **context-agnostic** engine:
the `Cluster` model runs wherever the harness is lifted to, so lifting `test all` into a VM-container
stands the kind cluster up on that VM's Docker. The harness is lifted as a whole, never re-expressed as
a parallel chain of lifted cluster ops — see
[composition_methodology](composition_methodology.md) for the single-representation rule.

## Deploy Is a Persistent Stack

Deploy is what `project up` leaves running: a **persistent stack**, not a
run-to-completion job. `project up` reconciles the chain to running and is idempotent — a rerun against
a partially-up stack converges the remainder rather than rebuilding from zero. The VM, the cluster, and
the workload services stay up after `project up` returns.

The lifecycle verbs are split so the persistent stack has explicit stop and delete transitions:

| Verb | Effect | `.data` |
|------|--------|---------|
| `project up` | Reconcile the chain to running; leave the persistent stack up. | preserved |
| `project down` | Stop services / clusters / VMs (provider **stop**, e.g. `incus stop` / `limactl stop`); delete nothing. | preserved |
| `project destroy` | Stop, then delete everything spun up. | preserved |

`.data` is preserved across `down` and `destroy` — a core invariant. Teardown recurses **in** while the
frame is still up, then stops or deletes on ascent (the VM stopped last); it is best-effort and
idempotent, tolerating a partial stack. `test run all` validates the live stack from the root frame,
decoupled from deploy — see [harness_workflow](harness_workflow.md).

## The VM Provider Parameterization

A native Linux operation can run against a typed **host target**: the local host or an Incus VM. This is a
host-provider axis orthogonal to substrate — the VM is still a `linux-cpu`/`linux-gpu` machine inside, and
the host target is not a fifth run-model. It parameterizes the existing run-models rather than adding to
them:

```haskell
data HostTarget = Local | InVM IncusVM
```

Every linux-host operation runs through one dispatch point, `runInTarget`, against `Local` or `InVM`,
with **no per-call branching** at the call sites. `runInTarget cfg Local t args` runs the resolved
tool directly; `runInTarget cfg (InVM vm) t args` dispatches through one host
`incus exec <name> -- <tool> <args>` into the VM (where the in-VM `<tool>` is the VM's own `$PATH`
binary, since the VM is a separate machine). The run-models in [run_models](run_models.md) are
unchanged; the host target sits underneath them, so the same machinery runs identically whether the
Linux host is local or encapsulated in an Incus VM. See
[incus](../engineering/incus.md) for the host-provider axis, the Incus install reconciler, and the VM
lifecycle (including stop-without-delete for `project down`).

The two-case `HostTarget` is the **tool-level** lift; the **subcommand-level self-reference lift**
(`HostBootstrap.Lift`) generalizes it to an n-level context stack (`Local | InVM | InContainer`), where a
binary crosses a boundary by invoking its *own* subcommand in the nested context. The Apple Silicon demo
uses the Lima VM provider (`limactl shell <instance> -- ...`); native Linux uses Incus
(`incus exec <vm> -- ...`); containers use `docker run --rm`. `project up` is the
**recursive interpreter** of that lift: it runs the current frame's steps, then hands off
`<binary> project up` into the next frame, where the child owns its segment and verifies it is in the
frame its `.dhall` describes. See [composition_methodology](composition_methodology.md).

## Current Status

The host-native, no-copy-out build is the implemented mechanism and is **unchanged** by the chain
model: Python ensures the host toolchain, builds the binary into `./.build/`, and execs it; the binary
ensures Docker and builds the project container `FROM` the base image, gating on `check-code`.

The recursive `project` command and the `[Step]` chain interpreter described above are **implemented and
real-run-validated end-to-end on real hardware**. A single `project up` on Incus/Linux stood up the live
persistent stack — the cordoned kind cluster (kind `extraPortMappings` publish NodePorts to the VM
localhost) → the full 8-pod production Harbor (NodePort 30500) → the 20GB project image pushed to the
in-cluster registry → the web chart pod serving `localhost:30080` with HTTP 200 — then `project down` /
`project destroy` tore it down with host `.data` preserved.

- **Shipped (the `project` chain):** a single `chain :: ProjectConfig -> [Step]` value the core
  interprets, driven by `project init|up|down|destroy`, a read-only `context` introspection command
  (`inspect`/`path`/`show`/`schema`/`render`), and a `test init` / `test run <suite>|all` split.
  Run-model selection (`selectRunModel`) and the `HostTarget` tool-level lift are implemented; the four
  run-models are real. The core command tree is exactly `ensure`, `context`, `project`, `test`,
  `check-code`; the demo's canonical deploy is `demoChain :: ProjectConfig -> [Step]` in
  `demo/src/HostBootstrapDemo/Commands.hs`, and the demo retains only the `web` verb plus the `vm` /
  `incus` debug-hatch verbs. `project down`'s stop-without-delete is a real provider capability.
- **Folded into chain steps (formerly flat verbs):** the old flat surfaces no longer exist as standalone
  verbs. The former `cluster up`/`down`/`delete`/`status` is now the `deploy-kind` / `deploy-chart` chain
  steps under `project up`, with `project down` / `project destroy` and read-only `context inspect`
  taking the teardown and status roles; the former `context create <kind>` is now the `context-init`
  chain step that mints the child `<project>.dhall` inside `project up`; the former `config init` is now
  `project init`, and `config show|schema|render` moved under read-only `context`; the demo's former
  `deploy` / `harbor` / `role` verbs are gone, replaced by the chain's `deploy-kind` / `deploy-harbor` /
  `push-image` / `deploy-chart` / `expose-port` steps. The reconcilers behind the old `cluster` verb
  (`clusterUp`/`clusterCreate`/`deployChart`/`clusterDown`/`clusterDelete`) remain in
  `HostBootstrap.Cluster.Lifecycle`, now invoked by the chain steps / lifecycle.

`DEVELOPMENT_PLAN/` owns the migration status and the closed phases. The `project` command and the
recursive interpreter are the shipped model this doc describes throughout.

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
