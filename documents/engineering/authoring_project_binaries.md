# Authoring A Project Binary

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [composition_methodology](../architecture/composition_methodology.md), [binary_context_config](../architecture/binary_context_config.md), [derived_project_standards](derived_project_standards.md)

> **Purpose**: A step-by-step guide for a new consumer — author the project's `chain :: RootConfig ->
> [Step]` (the lift chain that *is* the project), supply the step actions, test suite, artifacts, and
> Dhall vocabulary, and declare the budget — extending `hostbootstrap-core` without authoring noun verbs.

## TL;DR

- **The chain is the project.** A consumer's primary contribution is a single ordered value,
  `chain :: RootConfig -> [Step]`, plus the actions for any project-specific `Step` kinds it adds. The
  core interprets that chain recursively under `project up`. The consumer does **not** author noun verbs
  (`cluster`, `deploy`, `vm`, …); those dissolve into `Step`s. The foundational model is
  [composition_methodology](../architecture/composition_methodology.md); the reusable shapes are
  [composition_patterns](composition_patterns.md).
- **`.dhall` is parameters + context + witness, never shape.** The root `<project>.dhall` carries
  parameters and the optional structural flags; the chain is a pure function of those parameters. Each
  frame's binary verifies it is in the frame its sibling `.dhall` describes, or fails fast before side
  effects.
- **The `Step` algebra is the reuse unit.** Core ships host-management step kinds; the project
  contributes its own step kinds into the same `[Step]`, and host and workload steps interleave freely.
  This is the workload-extension seam.

## Steps

1. **Define the root config schema and defaults.** The project binary owns `<project>.dhall`: the
   resource budget, structural flags (e.g. skip-VM), Dockerfile path, and the parameters the chain reads.
   `project init` writes the root `<project>.dhall` (a host-orchestrator config with no parent) with
   optional `--cpu/--memory/--storage/--ha-replicas`. Python derives the project name from the Cabal file
   and does not read Dhall. See [schema](schema.md) and [resource_budgeting](resource_budgeting.md).
2. **Author the chain.** Provide `chain :: RootConfig -> [Step]` — the ordered lift sequence that is the
   project's identity. A `Step` is a typed operation in the `Step` algebra; the chain is one
   representation (single-representation §W holds), and `project up --dry-run` renders `chain rootCfg`.
   Compose from the core's host-management step kinds (deploy-VM, ensure-`X`, copy-source, build-pb,
   build-image, context-init, deploy-kind, deploy-chart, expose-port) and the project's own kinds; host
   and workload steps interleave in one list. The core interprets the chain recursively and idempotently
   (reconcile-to-running). See [composition_patterns](composition_patterns.md).
3. **Define project step kinds and their actions.** A workload step the core does not ship (deploy-harbor,
   launch-web, …) is a project-contributed `Step` kind plus its action. Hand these — together with the
   chain, a non-empty `TestSuite`, the `check-code` action, and the `ConfigArtifact` delta — to the
   core CLI entry so they merge into the recursive interpreter. The core command surface
   (`project`/`context`/`test`/`check-code`) passes through unchanged; the project extends the chain and
   the step vocabulary, never the noun verbs (the CLI stream of the four-stream contract, where stream 1
   is the lift chain; see [library_hierarchy](../architecture/library_hierarchy.md)).
4. **Let the interpreter cross boundaries.** Each descent is fractal bootstrap: provision the frame, build
   or install the binary in it, then hand off `pb project up` into the next frame. The consumer does not
   write a bespoke remote-exec path; the core lift folds the self-invocation (`limactl shell` / `incus
   exec` / `docker run`). One operation has one representation, so the deploy's only lifted **compute**
   step lifts the *whole* test workflow — `test run all` — into the project container in the VM; the
   cluster, the deploy, and the e2e are the harness's job inside that one lifted frame, not separate
   lifted steps. See [`HostBootstrap.Lift`](../architecture/hostbootstrap_core_library.md) and
   [composition_methodology § Single Representation](../architecture/composition_methodology.md#single-representation-the-chain-is-the-representation).
5. **Supply the test suite.** Provide a `Seams`/`Case` matrix (the fourth stream); `test run <suite>|all`
   drives `runMatrix` from the root frame, gated on an existing `test.dhall`. A case sets up its isolated
   environment, asserts the real workload, and tears down (guaranteed). `test run all` validates the live
   `project up` stack and is decoupled from bring-up. See [testing](testing.md) and
   [harness_workflow](../architecture/harness_workflow.md).
6. **Register schema artifacts and Dhall vocabulary.** Concatenate the project's `ConfigArtifact`s onto
   `coreArtifacts` and embed `Core.dhall` for any new step parameters, provider kinds, or witness kinds
   the chain introduces (the schema-gen and Dhall streams). Context-init is a generated step: the child
   `.dhall` for a nested frame is minted by a context-init `Step` during `project up`, not by a separate
   mutation verb. See [config_generation](config_generation.md) and
   [dhall_topology](dhall_topology.md).

## A Worked Chain (the demo)

The demo's `chain rootCfg` is the canonical example. It nests *pristine-host VM bootstrap* over *one-shot
container lift*, and every host and workload step lives in one ordered `[Step]`:

```text
deploy-VM            local                                   -- reconcile the platform provider (Lima/Apple, Incus/Linux) to a usable VM
copy-source          local -> VM                             -- stage the source tree into the VM
ensure ghc           local -> VM                             -- reconcile the toolchain inside the VM
build-pb             local -> VM                             -- re-establish the binary host-native in the VM
ensure docker        local -> VM                             -- reconcile docker inside the VM
build-image          local -> VM                             -- build the project image in the VM
context-init         inVM vm localContext                    -- mint the VM-project-container child .dhall
test run all         inContainer img (inVM vm localContext)  -- the ONLY lifted compute step
```

The lone lifted compute step is `test run all`: it folds through the selected VM provider to `docker run
--rm <image> test run all`. Inside that one lifted frame the harness runs its reconcilers "locally" on the
VM's Docker, so kind, harbor, and the webservice come up **in the VM** — reached with **no** second "bring
up a cluster" path. The project's own step kinds (deploy-harbor, launch-web, expose NodePort to host) sit
in the same list alongside the core host-management kinds; the interpreter runs them in order and is
restartable from any frame.

`project down` walks the same chain to stop services, clusters, and VMs (`incus`/`limactl` **stop**)
without deleting; `project destroy` stops then deletes everything spun up. Teardown recurses in while the
frame is still up, then stops/deletes on ascent (the VM last); it is best-effort and idempotent, and
`.data` is always preserved.

## Sketches

- **Managed cloud cluster**: a chain of `build-image → context-init → cloud-CLI create cluster (external
  state backend) → deploy-chart`. No deploy-VM step; the cloud is the substrate, expressed as project step
  kinds over the same `[Step]`.
- **Local cluster via a host service manager**: `ensure the cluster as a host service (rke2/k3s) →
  deploy-chart → optionally a cloud-validation step backed by an in-cluster state store`.

Both are the same algebra — a `[Step]` chain interpreted recursively across a context topology — differing
only in which steps the chain selects. Optional structural variation (skip the VM, straight to Docker) is
a root-`.dhall` flag, so the chain stays a pure function of root parameters. The fail-fast frame check is
applied at every boundary; teardown preserves `.data`.

## Current Status

- **Shipped (the `[Step]` chain).** `hostbootstrap-core` exposes exactly `ensure`, `context`, `project`,
  `test`, and `check-code`. The consumer's contribution is `chain :: RootConfig -> [Step]` plus project
  step actions; the demo supplies `demoChain :: ProjectConfig -> [Step]` in
  `demo/src/HostBootstrapDemo/Commands.hs`. The recursive `project` command (`init`/`up`/`down`/`destroy`),
  the read-only `context` introspection (`inspect`/`path`/`show`/`schema`/`render` — `inspect` renders the
  lift composition and current frame; `show`/`schema`/`render` were formerly the flat `config` verb), and
  the `test init` / `test run <suite>|all` split are all implemented and real-run validated end-to-end on
  real hardware. The demo retains only the `web` verb (`web serve`/`web bridge` — load-bearing: the chart
  pod runs `web serve`, the Dockerfile runs `web bridge`) plus the `vm`/`incus` debug-hatch verbs;
  `ensure <tool>` is the hidden debug surface alongside the chain interpreter. The single-representation
  doctrine holds: `demo deploy` collapsed into the one `project up` lift sequence whose only lifted compute
  step is `test run all` in the VM-project-container.
- **History.** The old flat surface — `config` (`init`/`schema`/`show`/`render`), the flat `cluster` verb,
  `context create`, and the demo's hand-written noun verbs (`deploy`, `harbor`, `role`) plus the Op-based
  `demoDeployChain` in `HostBootstrapDemo.Chain` — has been removed. `config init` became `project init`;
  `config show/schema/render` moved under the read-only `context` verb; `cluster up`/`down`/`delete`/
  `status` became the `deploy-kind`/`deploy-chart` chain steps under `project up`, `project down`,
  `project destroy`, and `context inspect`; `context create` became the in-`project up` `context-init`
  chain step. The `clusterUp`/`clusterCreate`/`deployChart`/`clusterDown`/`clusterDelete` reconcilers
  remain in `HostBootstrap.Cluster.Lifecycle`, now invoked by the chain steps and the lifecycle interpreter
  rather than by a flat verb.

## See also

- [composition_methodology](../architecture/composition_methodology.md) — the canonical home of the
  chain-is-the-project model, the recursive `project up` interpreter, and fractal bootstrap.
- [composition_patterns](composition_patterns.md) — the cookbook of `Step`-chain shapes this guide
  composes.
- [derived_project_standards](derived_project_standards.md) — the per-stream rules (stream 1 = the lift
  chain) every derived project follows.
