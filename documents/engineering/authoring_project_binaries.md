# Authoring A Project Binary

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [composition_methodology](../architecture/composition_methodology.md), [derived_project_standards](derived_project_standards.md)

> **Purpose**: A step-by-step guide for a new consumer — define project verbs, compose a chain of
> operations across contexts with the self-reference lift, supply the test seams, and declare the
> budget — extending `hostbootstrap-core` without shadowing it.

## TL;DR

- A project binary extends the core command tree (append, never shadow), composes its **specific chain**
  of operations from the generic primitives, and supplies its case matrix and budget. The foundational
  model is [composition_methodology](../architecture/composition_methodology.md); the reusable shapes are
  [composition_patterns](composition_patterns.md).
- Crossing an execution-context boundary is a self-reference lift — `liftSubcommand` re-invokes the
  binary's own subcommand in the nested context — not a bespoke remote-exec path.

## Steps

1. **Declare the static-base config.** A `hostbootstrap.dhall` at the project root names the project, its
   Dockerfile, and the one resource budget (the ceiling every cordon enforces). See
   [schema](schema.md) and [resource_budgeting](resource_budgeting.md).
2. **Define verbs as composable optparse values.** Hand the project's `command "…"` entries to
   `runHostBootstrapCLI progName projectCommands suite`; the core verbs (`ensure`/`config`/`cluster`/
   `test`/`check-code`) pass through unchanged. Append, never shadow (the CLI stream of the four-stream
   contract; see [library_hierarchy](../architecture/library_hierarchy.md)).
3. **Compose the chain.** A deploy verb is ordinary `IO` sequencing of operations. Cross a boundary by
   lifting a subcommand into a context built from `localContext` with `inVM` / `inContainer`. One operation
   has one representation, so the deploy's single lifted **compute** step lifts the *whole* test workflow —
   `test all` — into the project container in the VM (`inContainer img (inVM vm localContext)`); the cluster,
   the deploy, and the e2e are the harness's job inside that one lifted context, not separate lifted steps:

   ```haskell
   self <- currentSelfRef inVMBinaryPath
   let projectCtr = ContainerLift { clImage = "project:local", clMounts = [], clExtraArgs = [], clRemoveAfter = True }
   -- lift the WHOLE test workflow (helm/kind on the container $PATH, the kind cluster on the VM's Docker);
   -- folds to: incus exec <vm> -- docker run --rm <image> test all
   liftSubcommand cfg self (inContainer projectCtr (inVM vmName localContext)) ["test", "all"]
   ```

   Inside the container the harness runs as if local; the binary is the container `ENTRYPOINT`. Re-expressing
   cluster bring-up / web-serve / e2e as a *separate* chain of lifted ops alongside the harness is a
   redundant second representation (it double-creates clusters when it lifts a harness case). See
   `HostBootstrap.Lift` in [hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md) and
   [composition_methodology § Single Representation](../architecture/composition_methodology.md#single-representation-the-test-workflow-is-a-lifted-operation).
4. **Supply the test seams.** Provide a `Seams`/`Case` matrix (the fourth stream); the inherited `test`
   verb drives `runMatrix`. A case sets up its isolated environment, asserts the real workload, and tears
   down (guaranteed). See [testing](testing.md) and [harness_workflow](../architecture/harness_workflow.md).
5. **Register schema artifacts (optional).** Concatenate the project's `ConfigArtifact`s onto
   `coreArtifacts` and embed `Core.dhall` for any new vocabulary (the schema-gen and Dhall streams). See
   [config_generation](config_generation.md).

## A Worked Chain (nesting two shapes)

The demo nests *pristine-host VM bootstrap* (shape 2) over *one-shot container lift* (shape 1): bring up a
budget-sized VM, re-establish the binary host-native inside it and build the project image (both in the
VM), then lift the **whole test workflow** into that container as the single compute step. One operation
has one representation, and the test harness *is* that representation — so the lone lifted step is
`test all`, not a parallel chain of lifted cluster/web-serve/e2e ops (see
[composition_methodology § Single Representation](../architecture/composition_methodology.md#single-representation-the-test-workflow-is-a-lifted-operation)):

```text
ensure incus            local                                   -- reconciler on metal
vm up                   local                                   -- cordon #1 (the VM is the wall)
vm pristine-bootstrap   local -> VM                             -- build #2 (host-native) + build #3 (project image), in the VM
test all                inContainer img (inVM vm localContext)  -- the ONLY lifted compute step; folds to: incus exec <vm> -- docker run --rm <image> test all
vm down                 local                                   -- guarded teardown (.data preserved)
```

Inside that one lifted `test all`, the harness runs `clusterUp` "locally" on the VM's Docker, so the kind
cluster, the deploy, and the e2e all happen there — reached with no second "bring up a cluster" lift.

## Sketches

- **Managed cloud cluster** (shape 3): `build image → lift(InContainer): cloud-CLI create cluster (external
  state backend) → lift(InContainer): helm deploy into it`. No VM; the cloud is the substrate.
- **Local cluster via a host service manager** (shape 4): `ensure the cluster as a host service (rke2/k3s)
  → deploy into it → optionally layer a cloud-validation stack via an in-cluster state store`.

Both are the same algebra — operations composed across a context topology — differing only in which
shapes nest. The cordon is applied at every boundary (the one canonical parser); teardown preserves
`.data`.

## See also

- [composition_methodology](../architecture/composition_methodology.md) — operations, the lift, and the
  deploy ≡ business-logic unification.
- [composition_patterns](composition_patterns.md) — the shape catalogue this guide composes.
- [derived_project_standards](derived_project_standards.md) — the per-stream rules every derived project
  follows.
