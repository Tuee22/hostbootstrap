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
  chain `chain :: cfg -> [Step]`; `project up` interprets that `[Step]` recursively, and the
  run-model is the shape a given compute step takes once its topology and substrate are known. The
  chain is the canonical model — see [composition_methodology](composition_methodology.md).
- The **generated topology is the spine**: `ClusterTopology → Cluster`, `DaemonTopology → HostDaemon`,
  and `ContainerOnly →` `HostNative` when a host-native build is in force, else `OneShot`.
- **Deploy is a persistent stack.** `project up` stands up a long-lived stack and keeps it running
  (services, clusters, VMs stay up); `project down` deletes kind compute and stops VM frames, and
  `project destroy` deletes everything spun up, both preserving `.data`. `test run all` is the separate
  test surface, decoupled from deploy.
- The `HostDaemon` model is reached operationally through the **`service` command**: `service run` is a
  **leaf-frame pod entrypoint** (not an orchestrator) that runs one long-running role, and it is deployed
  into the cluster by `project up`'s `deploy-chart` step. The role and its variant come from a Dhall
  `ServiceType` ADT resolved against a **service-handler registry**. See
  [The `service` Command And Service Handlers](#the-service-command-and-service-handlers) below.
- The model feeds the test harness through `Seams`, but the harness **drives the real `project up`**: it
  writes a test `<project>.dhall`, runs `project up`, asserts in-frame via the self-reference lift, then
  runs `project destroy`. It does not stand up isolated per-case clusters via a separate seam path. See
  [harness workflow](harness_workflow.md).

## The Four Run-Models

| Model | What it does | Budget treatment |
|-------|--------------|------------------|
| `OneShot` | Build-if-needed, then `docker run --rm [-it] [mounts]` — a single container invocation that exits. | Budget-capped: the container runs within the project ceiling. |
| `HostNative` | Host-native build (into `./.build/`) plus a host exec of the resulting binary. | Host process, sliced by the harness budget when run as a case. |
| `HostDaemon` | A long-running service role (not a one-shot exec): a stateless service over durable external stores (message bus + object store), run operationally via `service run` as a leaf-frame pod entrypoint. See [The `service` Command And Service Handlers](#the-service-command-and-service-handlers). | Holds its share for its lifetime. |
| `Cluster` | A kind cluster plus Helm releases — the full orchestrated substrate. | Cordoned per substrate; `fitsBudget` proves the concurrent set fits. |

`OneShot` and `HostNative` differ only in **where the code runs**: `OneShot` runs inside a container
the binary builds; `HostNative` runs the host binary directly. `HostDaemon` differs from `HostNative`
in **lifetime**: a daemon stays up rather than running to completion. `Cluster` is the only model that
stands up an orchestrated multi-node substrate; it is realized by the cluster lifecycle in
[cluster lifecycle](../engineering/cluster_lifecycle.md), driven by the `deploy-kind`/`deploy-chart`
steps the chain interprets.

The `Cluster` model is **context-agnostic**: it is stood up by the real `project up` against whatever
Docker the running process sees. The harness drives that same `project up` rather than maintaining a
parallel "bring up a cluster" path — there is one representation, exercised as a unit (see
[composition_methodology](composition_methodology.md)).

## The `service` Command And Service Handlers

The `HostDaemon` run-model is the long-running-service shape; the **`service` command** is how that shape
is run in production and in tests.

- `service run` is a **leaf-frame pod entrypoint**, not an orchestrator. It runs exactly one long-running
  role inside the pod it was deployed into. It **fails fast** unless the active `<project>.dhall` declares
  a service role with a valid variant. The service handler **reads its effective config** and renders it
  (the demo's `Web` handler serves `cfg.message` to the SPA `#message`).
- Multiple service types are expressed as a Dhall **`ServiceType` ADT**; `service run` resolves the
  declared variant against a **service-handler registry** (each variant maps to one handler) and runs that
  handler. There is **no `service down`** — a service's lifetime is the pod's lifetime, and teardown is
  `project down`/`project destroy` of the enclosing stack.
- A service is **deployed by `project up`'s `deploy-chart` step**. The pod's container is the baked project
  image whose entrypoint is `service run`; the active config is delivered as a **ConfigMap** that overrides
  the baked container `<project>.dhall`, so the deployed role/variant is config-selected at deploy time.

In the demo, `web serve` maps to `service run` with the `Web` variant (the long-running HTTP role), and
`web bridge` maps to the build-image step (a build-time role, not a service). The `service` command is a
fixed core verb; a project extends it by **registering service handlers**, not by adding service
sub-commands.

## Selection Happens Inside The Step Chain

The run-model is not a top-level mode the operator picks. It is the shape a **compute step** takes when
`project up` interprets the lift chain and reaches a step whose topology and substrate are now known.

- A binary's identity is its chain value `chain :: cfg -> [Step]` — an ordered list of steps that
  interleaves core host-management step kinds (deploy-VM, ensure-X, copy-source, build-pb, build-image,
  context-init, deploy-kind, deploy-chart, expose-port) with the project's own step kinds (deploy-registry,
  push-image, …). This ordered `[Step]` is the extension-stream's **lift chain** (stream 1); see
  [library hierarchy](library_hierarchy.md).
- `project up` interprets that chain recursively (the fractal interpreter): it runs the current frame's
  steps, then hands off `pb project up` into the next frame, where each nested binary owns its segment.
- When interpretation reaches a compute step, `selectRunModel` derives one of the four models from the
  generated topology and the detected substrate. The four run-models are thus the **vocabulary of compute
  shapes** a step can resolve to; the chain decides *which* steps run and in what frame, and selection
  decides *how* each compute step executes.

The chain is the canonical representation of the project; `project up --dry-run` renders `chain cfg`
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

The behavior described above is implemented. The `service`-command service run-model uses a leaf-frame
`service run` entrypoint, a `ServiceType` ADT plus service-handler registry, deploy via `deploy-chart` with
a ConfigMap override, and no `service down`. The harness **drives the real `project up`** under generated
test configs rather than standing up isolated per-case clusters. The reconciliation that spanned phases
10, 13, 14, 15, 16, 17, 18, 19, and 20 is closed in the development plan.

The **fixed core command surface** is exactly `project`, `test`, `service`, `context`, and `check-code` —
there are **no per-project verbs**. `project init|up|down|destroy` drives the lifecycle; `service run`
runs a long-running service role; the read-only `context` command introspects uniformly across every
`<project>.dhall`; and `test` drives the harness. A project extends core through streams (lift chain,
Dhall vocabulary, schema-gen, test seams, and service handlers), never by adding command verbs.

The four run-models and `selectRunModel` are exercised by the core tests; selection consumes the
generated topology plus detected substrate, reached through the recursive `project up` interpreter over
an explicit `chain :: cfg -> [Step]` value. In the demo, the deploy sequence is the
`demoChain :: ProjectConfig -> [Step]` value in `demo/src/HostBootstrapDemo/Commands.hs`, interpreted
recursively by `project up`; `web serve` resolves to `service run` (`Web` variant) and `web bridge` to
the build-image step.

A single `project up` on Incus/Linux stands up the live persistent stack — a cordoned kind cluster (kind
`extraPortMappings` publish NodePorts to the VM localhost) → the in-cluster registry (NodePort
30500) → the project image pushed to the in-cluster registry → the web chart pod at `localhost:30080`
serving HTTP 200, with the service deployed by the `deploy-chart` step. `project down` deletes kind
compute and stops the VM while preserving host `.data`; `project destroy` deletes the VM too. The test harness
drives this same `project up`: it writes a test `<project>.dhall`, refuses to run if a `<project>.dhall`
already exists or a production cluster is running, runs `project up`, asserts in-frame via the
self-reference lift, then runs `project destroy` (deleting only what it created this run) — using
durable test storage `.test_data`, never `.data`.

## See Also

- [composition_methodology](composition_methodology.md) — the canonical home of the chain-is-the-project
  model, the recursive `project up` interpreter, and the single-representation doctrine; `HostDaemon` is
  the long-running-service model.
- [harness workflow](harness_workflow.md) — how `Seams` realize the selected model per case while the
  harness drives the real `project up`.
- [build and run model](build_and_run_model.md) — the host-native build into `./.build/` that
  `keyHostNative` reflects.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — the kind/Helm lifecycle the `Cluster`
  model drives, expressed as `deploy-kind`/`deploy-chart` chain steps.
- [library hierarchy](library_hierarchy.md) — the extension-stream merge whose stream 1 is the lift chain.
- [testing](../engineering/testing.md) — the `test` surface that runs the harness over a project's matrix.
