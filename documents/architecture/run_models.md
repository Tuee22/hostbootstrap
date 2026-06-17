# Run Models

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents index](../README.md), [development plan](../../DEVELOPMENT_PLAN/phase-10-standardized-test-harness.md)

> **Purpose**: Define the four run-models every `hostbootstrap` binary selects between, and where that
> selection happens — within a `Step`'s interpretation as `project up` walks the lift chain — so the
> run-model is derived from detected facts and never declared in Dhall.

## TL;DR

- There are exactly four run-models: `OneShot`, `HostNative`, `HostDaemon`, and `Cluster`.
- The run-model is **selected**, never declared. `selectRunModel :: RunModelKey -> RunModel` derives
  it from a `RunModelKey { keyTopology, keyHostNative }` that collapses the full
  `(verb × detected-substrate × library-layer × generated-topology)` key.
- The **selection happens within `project up`'s step interpretation.** A binary's identity is its lift
  chain `chain :: RootConfig -> [Step]`; `project up` interprets that `[Step]` recursively, and the
  run-model is the shape a given compute step takes once its topology and substrate are known. The
  chain is the canonical model — see [composition_methodology](composition_methodology.md).
- The **generated topology is the spine**: `ClusterTopology → Cluster`, `DaemonTopology → HostDaemon`,
  and `ContainerOnly →` `HostNative` when a host-native build is in force, else `OneShot`.
- **Deploy is a persistent stack.** `project up` reconciles a long-lived stack to running (services,
  clusters, VMs stay up); `project down` stops it and `project destroy` deletes it, both preserving
  `.data`. `test run all` validates the live stack from the root frame, decoupled from deploy.
- The model feeds the test harness through `Seams`: the default L0 `defaultSeams` realize the
  `OneShot` model; a cluster project supplies kind/Helm seams for the `Cluster` model. See
  [harness workflow](harness_workflow.md).
- The harness is the **context-agnostic test engine** — it invokes its reconcilers (e.g. `cluster up`)
  "locally", unaware of any enclosing frame — so it is a **lift target**, not a lift-aware component.
  The `Cluster` run-model therefore runs **wherever the harness is lifted to**: lift `test run all` into a
  VM-container and the kind cluster comes up on that VM's Docker. The harness is lifted as a whole, never
  re-expressed as a parallel chain of lifted cluster ops. See
  [composition_methodology](composition_methodology.md).

## The Four Run-Models

| Model | What it does | Budget treatment |
|-------|--------------|------------------|
| `OneShot` | Build-if-needed, then `docker run --rm [-it] [mounts]` — a single container invocation that exits. | Budget-capped: the container runs within the project ceiling. |
| `HostNative` | Host-native build (into `./.build/`) plus a host exec of the resulting binary. | Host process, sliced by the harness budget when run as a case. |
| `HostDaemon` | A long-running host service (not a one-shot exec) — the **role model**: a stateless role over durable external stores (message bus + object store). See [composition_methodology](composition_methodology.md). | Host process; the daemon holds its share for its lifetime. |
| `Cluster` | A kind cluster plus Helm releases — the full orchestrated substrate. | Cordoned per substrate; `fitsBudget` proves the concurrent set fits. |

`OneShot` and `HostNative` differ only in **where the code runs**: `OneShot` runs inside a container
the binary builds; `HostNative` runs the host binary directly. `HostDaemon` differs from `HostNative`
in **lifetime**: a daemon stays up rather than running to completion. `Cluster` is the only model that
stands up an orchestrated multi-node substrate; it is realized by the cluster lifecycle in
[cluster lifecycle](../engineering/cluster_lifecycle.md), driven by the `deploy-kind`/`deploy-chart`
steps the chain interprets.

The `Cluster` model is **context-agnostic**: the harness drives `cluster up` "locally" against whatever
Docker the running process sees. Lifting the whole `test run all` workflow into a VM-container therefore
stands the kind cluster up on the **VM's** Docker (the mounted socket), with no second "bring up a cluster"
path — the harness is the one representation, lifted as a unit (see
[composition_methodology](composition_methodology.md)).

## Selection Happens Inside The Step Chain

The run-model is not a top-level mode the operator picks. It is the shape a **compute step** takes when
`project up` interprets the lift chain and reaches a step whose topology and substrate are now known.

- A binary's identity is its chain value `chain :: RootConfig -> [Step]` — an ordered list of steps that
  interleaves core host-management step kinds (deploy-VM, ensure-X, copy-source, build-pb, build-image,
  context-init, deploy-kind, deploy-chart, expose-port) with the project's own step kinds (deploy-harbor,
  launch-web, …). This ordered `[Step]` is the four-stream's **lift chain** (stream 1); see
  [library hierarchy](library_hierarchy.md).
- `project up` interprets that chain recursively (the fractal interpreter): it runs the current frame's
  steps, then hands off `pb project up` into the next frame, where each nested binary owns its segment.
- When interpretation reaches a compute step, `selectRunModel` derives one of the four models from the
  generated topology and the detected substrate. The four run-models are thus the **vocabulary of compute
  shapes** a step can resolve to; the chain decides *which* steps run and in what frame, and selection
  decides *how* each compute step executes.

The chain is the canonical representation of the project; `project up --dry-run` renders `chain rootCfg`
without acting. The chain shape itself lives in [composition_methodology](composition_methodology.md),
which this document defers to; here we only define the four models a compute step resolves to.

## The Selection Key

The run-model is a function of detected facts, not a configured value. The full conceptual key is
`(verb × detected-substrate × library-layer × generated-topology)`. `RunModelKey` collapses that to
the two fields that actually discriminate:

- `keyTopology` — the **generated** topology: `ClusterTopology`, `DaemonTopology`, or `ContainerOnly`.
- `keyHostNative` — whether a host-native build is in force.

`selectRunModel` resolves the key with the generated topology as the spine:

| `keyTopology` | `keyHostNative` | Selected model |
|---------------|-----------------|----------------|
| `ClusterTopology` | (any) | `Cluster` |
| `DaemonTopology` | (any) | `HostDaemon` |
| `ContainerOnly` | host-native build in force | `HostNative` |
| `ContainerOnly` | otherwise | `OneShot` |

The topology is **generated** (decoded from the project's Dhall and reflected into the binary), so the
selection consumes a derived fact rather than a literal model name. See
[dhall generation](dhall_generation.md) for how topology is generated and
[library hierarchy](library_hierarchy.md) for the library-layer dimension the full key folds in.

## Selected, Never Declared

The run-model does not appear in Dhall. A project declares its **topology** and resource **budget**;
the binary detects its **substrate** and whether a host-native build is in force; `selectRunModel`
turns those into one of the four models. Declaring a model directly would let a project name a model
its substrate or topology cannot honour (for example asking for `Cluster` from a `ContainerOnly`
topology), so the model is always derived.

> **WRONG**
>
> A project's Dhall declares the run-model literally:
>
> ```dhall
> { runModel = "Cluster"
> , topology = ContainerOnly
> }
> ```
>
> This is wrong because the declared model can contradict the generated topology and the detected
> substrate: a `ContainerOnly` project would claim a kind/Helm `Cluster` run that nothing stands up,
> and the harness would have no consistent `Seams` to drive.

> **RIGHT**
>
> The project declares topology and budget; the binary selects the model as it interprets a step:
>
> ```haskell
> selectRunModel RunModelKey
>   { keyTopology   = ContainerOnly     -- generated from project Dhall
>   , keyHostNative = True              -- detected: host-native build in force
>   }
> -- => HostNative
> ```
>
> The generated topology is the spine and the detected `keyHostNative` breaks the `ContainerOnly`
> tie, so the model can never contradict the facts it was derived from.

## Current Status

The four run-models and `selectRunModel` are implemented and exercised by the core tests; selection
already consumes the generated topology plus detected substrate. Today that selection is reached through
the **flat verb surface** — the implemented binaries dispatch `ensure`, `config`/`context create`,
`cluster`, and `test` (plus the demo's `vm`/`deploy`/`incus`/`harbor`/`web`/`role`), and the demo's
deploy sequence is the hand-written `demoDeployChain` in `demo/src/HostBootstrapDemo/Chain.hs`. The
harness lift (`test all` lifted into the VM-container) is the implemented single-representation deploy.

The **target** is the recursive `project up` interpreter over an explicit `chain :: RootConfig -> [Step]`
value: `project init|up|down|destroy`, the read-only `context` introspection command, and the
`test init` / `test run <suite>|all` split. The `project` command and the `[Step]` chain interpreter are
**not yet implemented** — `project up`, `project down` (stop-without-delete), `project destroy`, and the
core `Step` algebra are planned, with the affected phases reopened in `DEVELOPMENT_PLAN/`. Until that
lands, the four run-models are selected inside the flat verbs above rather than inside a chain step; the
selection logic itself is unchanged by the migration.

## See Also

- [composition_methodology](composition_methodology.md) — the canonical home of the chain-is-the-project
  model, the recursive `project up` interpreter, and the single-representation doctrine; `HostDaemon` is
  the role model.
- [harness workflow](harness_workflow.md) — how `Seams` realize the selected model per case; the
  `test init` / `test run` split.
- [build and run model](build_and_run_model.md) — the host-native build into `./.build/` that
  `keyHostNative` reflects.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — the kind/Helm lifecycle the `Cluster`
  model drives, expressed as `deploy-kind`/`deploy-chart` chain steps.
- [library hierarchy](library_hierarchy.md) — the four-stream merge whose stream 1 is the lift chain.
- [testing](../engineering/testing.md) — the `test` surface that runs the harness over a project's matrix.
