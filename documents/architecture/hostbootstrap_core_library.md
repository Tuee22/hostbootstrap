# hostbootstrap-core Library

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [composition_methodology](composition_methodology.md), [binary_context_config](binary_context_config.md), [python_haskell_boundary](python_haskell_boundary.md), [build_and_run_model](build_and_run_model.md), [ensure_reconcilers](../engineering/ensure_reconcilers.md), [dhall_topology](../engineering/dhall_topology.md)

> **Purpose**: Describe the `hostbootstrap-core` Haskell library — its module surface, the `[Step]`
> chain algebra it ships, and the extension contract a project binary uses to build on top of it.

## TL;DR

- `hostbootstrap-core` is the Haskell library that owns all host-management logic: host-tool
  resolution, substrate detection, `ensure` reconcilers, cluster-lifecycle semantics, and the
  binary-context validation that gates the recursive interpreter.
- The core surface a project extends is the **`Step` algebra**. Core ships host-management step kinds
  (deploy-VM, ensure-X, copy-source, build-pb, build-image, context-init, deploy-kind, deploy-chart,
  expose-port); a project contributes its own step kinds (deploy-harbor, launch-web, …) into the same
  ordered `[Step]`. Host steps and workload steps interleave freely — this is the workload-extension
  seam.
- A project's identity is its **lift chain**, a pure function `chain :: RootConfig -> [Step]`. The chain
  value IS the project (single representation). `project up` is the recursive interpreter that runs the
  current frame's steps and hands off `pb project up` into the next frame.
- The surfaced core command tree is `project init|up|down|destroy`, `context` (read-only introspection),
  `test init|run`, and `check-code`. The bare `hostbootstrap` binary carries no project chain and an
  empty test matrix; `ensure <tool>` is retained only as a hidden debug surface.
- The canonical home of this model is [composition_methodology](composition_methodology.md); this doc
  describes the library surface that realizes it and defers there for the model itself.

## Current Status

What is implemented today is the **recursive `project` interpreter**, not a flat command tree. The
shipped core surface merges `project init|up|down|destroy`, the `context` read-only command, the
`test init|run` split, and `check-code` into a composable `optparse-applicative` value, plus the hidden
`ensure <tool>` debug surface. The demo's deploy is the first-class `demoChain :: ProjectConfig ->
[Step]` value (in `demo/src/HostBootstrapDemo/Commands.hs`), interpreted recursively by `project up`;
the demo retains only its `web` verb and the `vm`/`incus` debug-hatch verbs. The binary-context gate and
the project-local `<project>.dhall` schema decoder/encoder are implemented.

This model is **real-run validated end-to-end on real hardware**: a single `project up` on Incus/Linux
stood up the live persistent stack — a cordoned kind cluster, the full 8-pod production Harbor, the
20GB project image pushed to the in-cluster registry, and the web chart pod serving HTTP 200 on
`localhost:30080` — and `project down` / `project destroy` tore it down with host `.data` preserved. The
flat `cluster` verbs and the demo's hand-written deploy chain (the former `demoDeployChain` in
`HostBootstrapDemo.Chain`) have been removed; their reconcilers now run as chain steps under the
recursive interpreter. `DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` tracks the removed surface.

## Module Surface

The library namespace is `HostBootstrap.*`. The set below is indicative of the surface consumers depend
on; the canonical inventory is tracked in
[`../../DEVELOPMENT_PLAN/system-components.md`](../../DEVELOPMENT_PLAN/system-components.md).

| Module | Responsibility |
|--------|----------------|
| `HostBootstrap.HostTool` | Closed `HostTool` enumeration of external tools resolved to absolute paths; no `$PATH`-resolved bare-command invocation. |
| `HostBootstrap.HostConfig` | Typed host configuration: resolved tool paths, detected substrate, and the spare-resource view used for budgeting. |
| `HostBootstrap.HostPrereqs` | Fail-fast host-minimum checks (the pre-binary subset the thin bootstrapper reclaims). |
| `HostBootstrap.Substrate` | Substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`) and host-applicability predicates. |
| `HostBootstrap.Ensure` | The `Reconciler` value type and the reconciler dispatcher; invoked as the ensure-X step kind, and exposed as the hidden `ensure <tool>` debug surface. |
| `HostBootstrap.Ensure.*` | One reconciler module per host dependency (`Docker`, `Colima`, `Lima`, `Cuda`, `Homebrew`, `Ghc`, `Tart`); each is an idempotent value with a host-applicability predicate and a reconcile action. See [ensure_reconcilers](../engineering/ensure_reconcilers.md). |
| `HostBootstrap.Step` | The `Step` algebra and the recursive `[Step]` interpreter — the core surface a project extends with its `chain`. Core ships host-management step kinds; the interpreter runs the current frame's steps then lifts `pb project up` into the next frame. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.Config.Schema` | Owner for project-local `<project>.dhall` schema/default surfaces, sibling lookup, child projections, and service/daemon config snapshot log metadata. The context-init step mints child `.dhall` through this surface. See [dhall_topology](../engineering/dhall_topology.md). |
| `HostBootstrap.Context` | Binary-context substrate inside `<project>.dhall`: discover the sibling path, render the topology frames, validate that the running binary occupies the frame its `.dhall` describes, and gate the chain per-frame on handoff. Read-only introspection backs the `context` command. See [binary_context_config](binary_context_config.md). |
| `HostBootstrap.Cluster.Cordon` | Resource-budget verification and cordoning (Colima/Lima VM sizing args and kind node limits). See [resource_budgeting](../engineering/resource_budgeting.md). |
| `HostBootstrap.Cluster.Lifecycle` | kind/Helm cluster up/down/delete semantics and the never-delete-`.data` invariant, invoked as the deploy-kind / deploy-chart step kinds. See [cluster_lifecycle](../engineering/cluster_lifecycle.md). |
| `HostBootstrap.Lima` | Lima VM lifecycle argv builders for the Apple Silicon pristine demo VM (`start`, `shell`, `copy`, guarded `delete`), invoked by the deploy-VM step kind. |
| `HostBootstrap.Lift` | The self-reference compositional lift: run a subcommand of the binary in a nested context (`Local`/provider VM/`InContainer`) by invoking the binary again there. The `[Step]` interpreter lifts `pb project up` across each frame boundary through this seam. The pure argv fold is unit-tested. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.Harness` | The standardized test engine — `runMatrix` over a project's `Seams` (`seamSetup`/`seamRun`/`seamTeardown`), per-case isolation, the delete-guard, and budget-slicing. The harness is **context-agnostic**: its seams invoke reconcilers "locally", so the harness is a **lift target**, not a lift-aware component. `test run all` lifts the whole harness workflow into the live frame rather than re-expressing it as a parallel chain. See [harness_workflow](harness_workflow.md). |
| `HostBootstrap.Command` | The composable core command tree (`coreCommands`): `project init|up|down|destroy`, `context`, `test init|run`, `check-code`, and the hidden `ensure` debug surface. |
| `HostBootstrap.CLI` | `ProjectSpec`, `runHostBootstrapCLI`, and `runBareHostBootstrapCLI`; the entrypoint validates a project's `chain`, test suite, code-check, and artifact delta before merging them with `coreCommands`. |
| `HostBootstrap.DocValidator` | The mechanical documentation validator run through the code-check. See [documentation_standards](../documentation_standards.md). |

## Host-Tool Resolution And Substrate Ownership

External tools are resolved through the closed `HostTool` enumeration (`HostBootstrap.HostTool`) to
absolute paths. The `AbsExe` newtype makes a bare command name unrepresentable as a resolved tool — its
smart constructor rejects any non-absolute path — so no library or project code invokes a
`$PATH`-resolved bare command (see
[development_plan_standards § K](../../DEVELOPMENT_PLAN/development_plan_standards.md)).
`HostBootstrap.HostConfig` is the typed configuration that pairs the detected substrate with the
resolved tool paths the reconcilers read.

Substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`) is owned by `HostBootstrap.Substrate`;
its classification core is pure (`classify`, `parseDockerArch`) with a thin IO wrapper for the platform
reads and the NVIDIA probe. `HostBootstrap.HostPrereqs` carries the fail-fast host minimums, dispatched
by substrate, each resolving its tools through the typed configuration. See
[prerequisites](../engineering/prerequisites.md).

## The Step Algebra And The Project Chain

The core surface a project extends is the `Step` algebra, not a set of noun verbs. A `Step` is a typed,
composable unit the recursive interpreter runs and reports. `hostbootstrap-core` ships the
**host-management step kinds**:

- `deploy-VM` — provision the platform VM (Lima on Apple Silicon, Incus on native Linux);
- `ensure-X` — run a reconciler to converge a host dependency (`ensure-ghc`, `ensure-docker`, …);
- `copy-source` — stage project source into the frame;
- `build-pb` — build/install the project binary in the frame (parent-orchestrated, since the child `pb`
  does not exist yet);
- `build-image` — build the project container image;
- `context-init` — mint the child `<project>.dhall` for the next frame;
- `deploy-kind` / `deploy-chart` — cluster and Helm-release lifecycle leaves;
- `expose-port` — expose an in-cluster `NodePort` to the host.

A project contributes its **own** step kinds (for the demo: `deploy-harbor`, `launch-web`) into the same
ordered `[Step]`. Host steps and workload steps interleave freely; the project does not subclass or wrap
the core verbs, it appends its step kinds to the chain. This is the workload-extension seam.

A project's identity is the chain value:

```haskell
chain :: RootConfig -> [Step]
```

The chain is a **pure function of the root parameters**. Optional structural variation (for example, skip
the VM frame and go straight to Docker) is a flag in the root `<project>.dhall`, so the chain stays a
pure function. The chain is the single representation of the project (single-representation doctrine, see
[composition_methodology](composition_methodology.md)); `project up --dry-run` renders `chain rootCfg`
without executing it.

`project up` is the **recursive / fractal interpreter** of that chain. In each frame it runs the steps
that belong to the current frame, then lifts `pb project up` into the next frame through
`HostBootstrap.Lift`; each `pb` owns its segment and is restartable from any frame. Every descent is the
same fractal pattern — provision the frame, build/install the `pb` in it, hand off `pb project up` — and
the Python bootstrapper is the metal-frame instance of that exact pattern (see
[python_haskell_boundary](python_haskell_boundary.md)). The model itself, including teardown's
recurse-in-then-stop-on-ascent shape and the `.data`-preserved invariant, is owned by
[composition_methodology](composition_methodology.md); this doc defers there rather than re-deriving it.

## Command-Tree Extension Contract

`HostBootstrap.CLI` exposes the core command tree as a composable `optparse-applicative` value and a
generic project entrypoint:

```haskell
projectSpec :: (RootConfig -> [Step]) -> TestSuite -> IO () -> [ConfigArtifact] -> ProjectSpec
runHostBootstrapCLI :: String -> ProjectSpec -> IO ()
runBareHostBootstrapCLI :: String -> IO ()
```

- `progName` is the program name used in help and diagnostics.
- `ProjectSpec` carries the project's primary contribution — its `chain :: RootConfig -> [Step]` value —
  together with the non-empty `TestSuite` threaded into the inherited `test` verb, the project-defined
  `check-code` action, and the project `ConfigArtifact` delta. Absence is represented by a different
  entrypoint (`runBareHostBootstrapCLI`), not by a silent project default.
- `runHostBootstrapCLI` validates the spec, merges it with the core command tree, and runs the resulting
  parser. The interpreter loads the sibling `<project>.dhall` before acting in a frame and refuses to
  proceed when the binary does not occupy the frame the context declares.

A project binary contributes a chain value, not noun verbs. Its `Main.hs` builds its chain (interleaving
core and project step kinds) and hands it to the entrypoint:

```haskell
import HostBootstrap.CLI (projectSpec, runHostBootstrapCLI)
import HostBootstrap.Step (Step)

demoChain :: RootConfig -> [Step]
demoChain cfg = coreHostSteps cfg <> [deployHarbor cfg, launchWeb cfg, exposePort cfg]

main :: IO ()
main =
  runHostBootstrapCLI
    "daemon-substrate"
    (projectSpec demoChain daemonSuite daemonCheckCode daemonArtifacts)
```

The bare `hostbootstrap` binary is explicit, not a project pretending to have an empty chain:

```haskell
main :: IO ()
main = runBareHostBootstrapCLI "hostbootstrap"
```

This guarantees `project init|up|down|destroy`, `context`, `test init|run`, and `check-code` behave
identically whether invoked through the bare binary or any project binary; a project only contributes
step kinds and a chain value, it never shadows or rewrites the core command tree.

### Surfaced commands

| Command | Behavior |
|---|---|
| `project init` | Write the root `<project>.dhall` (host-orchestrator, no parent); fails fast unless run on a fresh host-level binary with no sibling `.dhall`. Carries optional `--cpu/--memory/--storage/--ha-replicas`. |
| `project up` | Recursively interpret `chain rootCfg` from the current frame; idempotent (reconcile-to-running). `--dry-run` renders the chain. |
| `project down` | Stop services/clusters/VMs (the provider **stop** capability, e.g. `incus`/`limactl stop`); deletes nothing. |
| `project destroy` | Stop, then delete everything spun up; `.data` is always preserved. |
| `context` | Read-only introspection: render the sibling `.dhall` and the global lift composition (`topologyFrames`/`parentChain`) with the current frame highlighted. Absorbs the old `config show/schema/render`. |
| `test init` | Needs an existing `project.dhall`; writes `test.dhall` (may carry test-specific config). |
| `test run <suite>|all` | Root-only, needs `test.dhall`; `all` is always a suite. Lifts the harness into the live `project up` stack and validates it; fail-fast otherwise. |
| `check-code` | Unchanged; runs the project's code-check action. |
| `ensure <tool>` | Hidden debug surface only; reconcilers normally run as `ensure-X` chain steps within `project up`. |

The verbs dissolved into chain steps or step actions — `cluster up|down|delete|status`, `context create`
(→ the context-init step), `config init` (→ `project init`), and the demo's flat
`deploy`/`vm`/`incus`/`harbor`/`web`/`role` — are no longer top-level commands in the target surface.
`DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md` tracks their removal.

## Consumption

The library is consumed as a pinned `source-repository-package` git dependency in each project's
`cabal.project`, so every consumer builds against an exact commit. The base image warms
`hostbootstrap-core`'s dependencies into the frozen Cabal store so derived builds hit the warm store.
See [base_image](../engineering/base_image.md) and [warm_store](../engineering/warm_store.md).
