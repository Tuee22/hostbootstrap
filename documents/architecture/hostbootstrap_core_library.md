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
  expose-port); a project contributes its own step kinds (for the demo, deploy-registry and push-image)
  into the same ordered `[Step]`. Host steps and workload steps interleave freely — this is the
  workload-extension seam.
- A project's identity is its **lift chain**, a pure function `chain :: cfg -> [Step]`. The
  chain value IS the project (single representation). `project up` is the recursive interpreter that runs
  the current frame's steps and hands off `pb project up` into the next frame.
- The surfaced core command tree is exactly five user-facing verbs: `project`, `test`, `service`,
  `context`, and `check-code`. There are no hidden commands. `ensure` is a reconciler library a project
  composes as `ensure-*` chain steps.
- The canonical home of this model is [composition_methodology](composition_methodology.md); this doc
  describes the library surface that realizes it and defers there for the model itself.

## Current Status

The core surface is the **recursive `project` interpreter**. It merges the `context`
read-only command, `project init|up|down|destroy`, the `test init|run` split, `service init|schema|run`,
and `check-code` into a
composable `optparse-applicative` value. The demo's deploy is the first-class
`demoChainFor :: Substrate -> ProjectConfig -> [Step]` value (in
`demo/src/HostBootstrapDemo/Commands.hs`), interpreted recursively by `project up`; the demo also
contributes its `web` and `accelerator` service variants and its VM/provider IO as chain steps — the
surface is fixed, so it adds no verbs. The binary-context gate and
the project-local `<project>.dhall` schema decoder/encoder back the interpreter.

A single `project up` on Incus/Linux stands up the live persistent stack — a cordoned kind cluster, the
in-cluster registry, the project image pushed to the in-cluster registry, and the web chart pod
serving HTTP 200 on `localhost:30080` — and `project down` / `project destroy` tear it down. Each host
reconciler runs as a chain step under the recursive interpreter.

The direct `linux-gpu` path is also represented by the same core surfaces, not a second orchestrator.
Its two-frame demo chain runs the metal resource preflight plus `Ensure.Docker`/`Ensure.Cuda`, builds the
CUDA project image, and hands off with `--gpus=all`. In the child context, core selects
`NvkindDriver`, creates the explicit control-plane + GPU-worker topology, splits and applies the one
cluster envelope across both node containers, probes allocatable GPU before any Helm or `kubectl`
mutation, installs NVIDIA device-plugin `0.19.3` only when that probe is not already positive, and gates
on positive `nvidia.com/gpu` before the project deploys its GPU-requesting daemon pod. These surfaces are
unit/static-validated at 364 core tests and 87 demo tests. Phase 3.7 closed on 2026-07-15: a
named Ubuntu 24.04 WSL2 guest classified `linux-gpu` on an RTX 3090 Windows machine installed and verified
the eight-step runtime plan, then immediately exited 0 with `ensure cuda: present (no-op)`. That WSL2 guest
was not native Linux. Phase 5.5 remains `Active` until the native Linux CPU Incus/ClusterIP/C++ and native
Linux GPU direct-nvkind/CUDA/browser lanes each report `8/8`.

The Windows surface splits by responsibility: the `windows-cpu`/`windows-gpu` substrates and
`Ensure.CudaWin` are implemented and validated on a real Windows GPU host, and the
`HostBootstrap.Wsl2` provider and `Ensure.Wsl2` close the Phase-11 Windows pristine lifecycle. See
[wsl2](../engineering/wsl2.md) and [ensure_reconcilers](../engineering/ensure_reconcilers.md).

Current generic model: under
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md) the extension
contract is the generic `ProjectSpec cfg tcfg`, parameterized over a project's own config type `cfg`
(its `<project>.dhall`) and test-config type `tcfg` (its `test.dhall`). Core then owns no fixed config
type and **no default values** — it couples to `cfg` through `cfg -> BinaryContext`,
`BinaryContext -> cfg -> cfg`, and the project-owned `psServiceVariant :: cfg -> Either String String`,
while the surfaced command tree (`project`, `test`, `service`, `context`,
`check-code`) stays fixed. Defaults live solely in the project-owned `psInit :: InitArgs -> cfg`, the only
default-bearing function in the spec; `project init` layers optional flag overrides over those `psInit`
defaults, and the harness reuses `psInit` (via `psTestConfig`) to generate the run config. See the
[generic_project_model.md](generic_project_model.md) design,
[phase 19](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md), and
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md).

## Module Surface

The library namespace is `HostBootstrap.*`. The set below is indicative of the surface consumers depend
on; the canonical inventory is tracked in
[`../../DEVELOPMENT_PLAN/system-components.md`](../../DEVELOPMENT_PLAN/system-components.md).

| Module | Responsibility |
|--------|----------------|
| `HostBootstrap.HostTool` | Closed `HostTool` enumeration of external tools resolved to absolute paths (including `Nvkind`/`NvidiaSmi` and the Windows tools `Winget`, `Nvcc`, and `Wsl`); no `$PATH`-resolved bare-command invocation. |
| `HostBootstrap.HostConfig` | Typed host configuration: resolved tool paths, detected substrate, and the spare-resource view used for budgeting. |
| `HostBootstrap.HostPrereqs` | Fail-fast host-minimum checks (the pre-binary subset the thin bootstrapper reclaims). |
| `HostBootstrap.Substrate` | Substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`, `windows-cpu`, `windows-gpu`) and host-applicability predicates. |
| `HostBootstrap.Ensure` | The `Reconciler` value type and runner; invoked as the `ensure-*` chain-step library, not exposed as a command. |
| `HostBootstrap.Ensure.*` | One reconciler module per host dependency (`Docker`, `Colima`, `Lima`, `Cuda`, `CudaWin`, `Homebrew`, `Ghc`, `Incus`, `Wsl2`); each is an idempotent value with a host-applicability predicate and a reconcile action. `Ensure.Cuda` owns the signed NVIDIA apt bootstrap, default-runtime/CDI/volume-injection configuration, and the exact nvkind Docker smoke. See [ensure_reconcilers](../engineering/ensure_reconcilers.md). |
| `HostBootstrap.Step` | The `Step` algebra — the core surface a project extends with its `chain` — plus its pure renderers and frame grouping (`renderChainPlan`, `stepsForFrame`, `chainFrames`). Core ships host-management step kinds; a project contributes its own through the `ProjectStep` seam. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.Chain` | The recursive/fractal `[Step]` interpreter (`renderChain`, `runChainFromFrame`): it runs the current frame's steps then lifts `pb project up` into the next frame. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.Config.Schema` | Owner for project-local `<project>.dhall` schema surfaces, sibling lookup (`siblingProjectConfigPath`), child projections, and service/daemon config snapshot log metadata. It owns **no default config values** — defaults live in the project's `psInit`. The context-init step mints child `.dhall` through this surface. See [dhall_topology](../engineering/dhall_topology.md). |
| `HostBootstrap.Context` | Binary-context substrate inside `<project>.dhall`: discover the sibling path, render the topology frames, validate that the running binary occupies the frame its `.dhall` describes, and gate the chain per-frame on handoff. Read-only introspection backs the `context` command. See [binary_context_config](binary_context_config.md). |
| `HostBootstrap.Cluster.Cordon` | Resource-budget verification and cordoning (Colima/Lima VM sizing args plus a named kind-node limit builder). Lifecycle composes the node builder over a plan's full node list after splitting the one cluster envelope. See [resource_budgeting](../engineering/resource_budgeting.md). |
| `HostBootstrap.Cluster.Lifecycle` | kind/nvkind/Helm cluster up/down/delete semantics and the never-delete-`.data` invariant, invoked as the deploy-kind / deploy-chart step kinds. It owns driver-specific config/node topology, the all-node cordon, the NVIDIA runtime smoke, pinned device-plugin `0.19.3`, and the allocatable-GPU gate for `NvkindDriver`. See [cluster_lifecycle](../engineering/cluster_lifecycle.md). |
| `HostBootstrap.Lima` | Lima VM lifecycle argv builders for the Apple Silicon pristine demo VM (`start`, `shell`, `copy`, guarded `delete`), invoked by the deploy-VM step kind. |
| `HostBootstrap.Wsl2` | WSL2 VM lifecycle argv builders for the Windows pristine demo distro (`import`, `wsl -d <distro> --`, `terminate`, `shutdown`, guarded `unregister`) plus the `classifyWsl2Readiness` host-reboot classifier, invoked by the deploy-VM step kind. The Windows VM-provider peer of `HostBootstrap.Lima` / Incus. See [wsl2](../engineering/wsl2.md). |
| `HostBootstrap.Lift` | The self-reference compositional lift: run a subcommand of the binary in a nested context (`Local`/provider VM/`InContainer`) by invoking the binary again there. The `[Step]` interpreter lifts `pb project up` across each frame boundary through this seam. The pure argv fold is unit-tested. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.Harness` | The standardized test engine — `runMatrix` over the harness-built `Seams` (`assertSeams`) wired from the project's `TestSuite` (case matrix + assertions). It **drives the real `project up`**: per config variant it **generates** the run's `<project>.dhall` functionally (via the project's own `psTestConfig`/`projectConfigForRole`, never shelling the CLI), runs `project up` over the project's own chain, runs the case assertions in the appropriate frame (reusing the self-reference lift, with `EXPECTED_MESSAGE` parameterizing the polymorphic assertion), and tears down with `project destroy` through `finally`. A suite may declare more than one variant; each is stood up and torn down in turn. It owns no second cluster-bring-up path; two fail-fast preconditions (refuse if the sibling `siblingProjectConfigPath` config exists or a production cluster is running) and a self-created-only delete-guard protect production. See [harness_workflow](harness_workflow.md). |
| `HostBootstrap.Command` | The **fixed** core command tree (`coreCommands`): `project init|up|down|destroy`, `test init|run`, `service init|schema|run`, `context`, and `check-code`. `project down|destroy` invokes core Kind cleanup only when the current frame owns `deploy-kind`; nested VM/project-container clusters remain with the project teardown hook, while attempted cleanup failures aggregate. No per-project verbs. |
| `HostBootstrap.CLI` | The generic `ProjectSpec cfg tcfg`, `runHostBootstrapCLI`, and `runBareHostBootstrapCLI`; the entrypoint validates a project's `chain`, test suite, code-check, service registry, service selector, and artifact delta before merging them with `coreCommands`. The spec carries the project-owned config seams `psInit :: InitArgs -> cfg` (the **only** default-bearing function — core ships no defaults), `psTestInit :: InitArgs -> tcfg`, `psTestConfig :: tcfg -> IO [(Text, cfg)]`, and `psServiceVariant :: cfg -> Either String String`. |
| `HostBootstrap.DocValidator` | The mechanical documentation validator run through the code-check. See [documentation_standards](../documentation_standards.md). |

## Host-Tool Resolution And Substrate Ownership

External tools are resolved through the closed `HostTool` enumeration (`HostBootstrap.HostTool`) to
absolute paths. The `AbsExe` newtype makes a bare command name unrepresentable as a resolved tool — its
smart constructor rejects any non-absolute path — so no library or project code invokes a
`$PATH`-resolved bare command (see
[development_plan_standards § K](../../DEVELOPMENT_PLAN/development_plan_standards.md)).
`HostBootstrap.HostConfig` is the typed configuration that pairs the detected substrate with the
resolved tool paths the reconcilers read.

Substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`, `windows-cpu`, `windows-gpu`) is owned by `HostBootstrap.Substrate`;
its classification core is pure (`classify`, `parseDockerArch`) with a thin IO wrapper for the platform
reads and the NVIDIA probe. `HostBootstrap.HostPrereqs` carries the fail-fast host minimums, dispatched
by substrate, each resolving its tools through the typed configuration. See
[prerequisites](../engineering/prerequisites.md).

## The Step Algebra And The Project Chain

The core surface a project extends is the `Step` algebra, not a set of noun verbs. A `Step` is a typed,
composable unit the recursive interpreter runs and reports. `hostbootstrap-core` ships the
**host-management step kinds**:

- `deploy-VM` — provision the platform VM (Lima on Apple Silicon, Incus on native Linux, WSL2 on Windows);
- `ensure-X` — run a reconciler to converge a host dependency (`ensure-ghc`, `ensure-docker`, …);
- `copy-source` — stage project source into the frame;
- `build-pb` — build/install the project binary in the frame (parent-orchestrated, since the child `pb`
  does not exist yet);
- `build-image` — build the project container image;
- `context-init` — mint the child `<project>.dhall` for the next frame;
- `deploy-kind` / `deploy-chart` — cluster and Helm-release lifecycle leaves;
- `expose-port` — expose an in-cluster `NodePort` to the host.

A project contributes its **own** step kinds (for the demo: `deploy-registry`, `push-image`) into the same
ordered `[Step]`. Host steps and workload steps interleave freely; the project appends its step kinds to
the chain. This is the workload-extension seam.

A project's identity is the chain value:

```haskell
chain :: cfg -> [Step]
```

The chain is a **pure function of the project parameters**. Optional structural variation (for example,
skip the VM frame and go straight to Docker) is a flag in the root `<project>.dhall`, so the chain stays
a pure function. The chain is the single representation of the project (single-representation doctrine,
see [composition_methodology](composition_methodology.md)); `project up --dry-run` renders
`chain projectCfg` without executing it.

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
projectSpec :: TestSuite -> IO () -> [ConfigArtifact] -> (InitArgs -> cfg) -> (InitArgs -> tcfg) -> (tcfg -> IO [(Text, cfg)]) -> ProjectSpec cfg tcfg
withChain :: (cfg -> [Step]) -> ProjectSpec cfg tcfg -> ProjectSpec cfg tcfg
withFrameContext :: (cfg -> StepFrame -> LiftContext) -> ProjectSpec cfg tcfg -> ProjectSpec cfg tcfg
withTeardown :: (cfg -> Bool -> IO ()) -> ProjectSpec cfg tcfg -> ProjectSpec cfg tcfg
withServices :: ServiceRegistry -> ProjectSpec cfg tcfg -> ProjectSpec cfg tcfg
withServiceConfig :: (cfg -> Either String String) -> ProjectSpec cfg tcfg -> ProjectSpec cfg tcfg
runHostBootstrapCLI :: String -> ProjectSpec cfg tcfg -> IO ()
runBareHostBootstrapCLI :: String -> IO ()
```

- `progName` is the program name used in help and diagnostics.
- `projectSpec` builds the spec from the non-empty `TestSuite` threaded into the inherited `test` verb,
  the project-defined `check-code` action, the project `ConfigArtifact` delta, and the project-owned
  init/test-config builders. `withChain` attaches the project's primary contribution — its
  `chain :: cfg -> [Step]` value; `withFrameContext` attaches the per-frame lift-context
  builder; `withTeardown` attaches the chain-frame teardown; `withServices` appends service handlers;
  `withServiceConfig` maps the effective config's project-owned `ServiceType` to one handler key.
  The bare core binary uses a separate
  entrypoint (`runBareHostBootstrapCLI`).
- `runHostBootstrapCLI` validates the spec, merges it with the core command tree, and runs the resulting
  parser. The interpreter loads the sibling `<project>.dhall` before acting in a frame and refuses to
  proceed when the binary does not occupy the frame the context declares.

A project binary contributes a chain value plus extension streams, never its own verbs. Its `Main.hs`
attaches the chain (interleaving core and project step kinds) to the spec and hands it to the entrypoint:

```haskell
import HostBootstrap.CLI (projectSpec, runHostBootstrapCLI, withChain, withFrameContext, withServiceConfig, withServices, withTeardown)
import HostBootstrap.Substrate (detect)
import HostBootstrapDemo.Commands (demoArtifacts, demoChainFor, demoCheckCode, demoFrameContext, demoServices, demoTeardown, demoTestSuite)
import HostBootstrapDemo.Config (configuredServiceVariant, demoInit, demoTestConfig, demoTestInit)
import System.Exit (die)

main :: IO ()
main = do
  -- Detect the host substrate once so the per-frame lift context folds each
  -- metal→VM handoff to the right provider shell (Incus on Linux CPU, Lima on Apple Silicon).
  -- Linux GPU has no VM frame; its direct handoff is a GPU-enabled container lift.
  substrate <- detect >>= either die pure
  runHostBootstrapCLI
    "hostbootstrap-demo"
    ( withChain
        (demoChainFor substrate)
        ( withFrameContext
            (demoFrameContext substrate)
            (withTeardown demoTeardown (withServiceConfig configuredServiceVariant (withServices demoServices (projectSpec demoTestSuite demoCheckCode demoArtifacts demoInit demoTestInit demoTestConfig))))
        )
    )
```

The bare `hostbootstrap` binary uses the dedicated bare entrypoint:

```haskell
main :: IO ()
main = runBareHostBootstrapCLI "hostbootstrap"
```

This guarantees `project init|up|down|destroy`, `test init|run`, `service init|schema|run`, `context`, and
`check-code` behave identically whether invoked through the bare binary or any project binary; a project
contributes step kinds, a chain value, test seams, service handlers, and schema artifacts alongside the
core command tree.

### Surfaced commands

| Command | Behavior |
|---|---|
| `context` | Read-only introspection over the sibling `.dhall`: `inspect` renders the lift composition with the current frame marked, and `path`/`show`/`schema`/`render` print the canonical config filename, the config, the schema, and static examples of the reusable Dhall artifacts. |
| `project init` | Write the root `<project>.dhall` (host-orchestrator, no parent); fails fast unless run on a fresh host-level binary with no sibling `.dhall`. Layers optional `--cpu/--memory/--storage/--ha-replicas` overrides over the project's `psInit` defaults (core ships no defaults). |
| `project up` | Recursively interpret `chain projectCfg` from the current frame; idempotent (reconcile-to-running). `--dry-run` renders the chain. Stands up the persistent stack (deploy-kind/nvkind → deploy-registry → push-image → deploy-chart → expose-port, plus the accelerator-daemon placement selected by project topology). |
| `project down` | Stop service/VM frames and delete kind clusters; `down`'s removal set is empty, so it deletes no filesystem path at all. See [durable_state](durable_state.md). |
| `project destroy` | Stop, then delete everything spun up — on a lifted topology that includes the provisioned frame *and its disk*, so a guest-side `.data` goes with it. See [durable_state](durable_state.md). |
| `test init` | Needs **no** pre-existing `<project>.dhall`; writes `<project>.test.dhall` (the case matrix plus thin config overrides) via the project-owned `psTestInit`. `project init` writes via `psInit`, whose defaults the harness later reuses (through `psTestConfig`) to generate the run config. |
| `test run <suite>\|all` | Root-only, needs `<project>.test.dhall`; `all` runs the whole matrix. Per config variant it **generates** the run's `<project>.dhall` functionally (via `psTestConfig`, never shelling the CLI), **drives the real `project up`**, asserts in-frame, then `project destroy`; a suite may declare more than one variant (the demo runs two) and each is stood up and torn down in turn. Two fail-fast preconditions protect production — the existence check is the executable-sibling `siblingProjectConfigPath` (`.build/<project>.dhall`); durable storage is `.test_data`. Fail-fast on any failing case. |
| `service init\|schema\|run` | Run a long-running role; `service run` is a leaf-frame pod entrypoint dispatched over the project's `ServiceType` ADT; fail-fast unless the config declares a service role + variant; no `service down`. The handler **reads its effective config** and renders it — the demo's `Web` handler reads `cfg.message` and serves it through `BudgetView.message` to the SPA `#message`. |
| `check-code` | Runs the project's fail-fast code-check action. |

`project up` *deploys* and `test run` *drives* that deploy under a harness-generated config — they are the
same chain, not two representations. `project up` interprets the chain to stand up the persistent deploy
stack and ends at a live webservice (`service run`) on `localhost:30080`, whose handler reads its config
and renders `message`. `test run all` runs that same `project up` once per config variant (the demo runs
two), asserts the live stack (the SPA `#message` polymorphic over the active `EXPECTED_MESSAGE`), using
`.test_data` (never `.data`) and deleting only what it created.

## Consumption

The library is consumed as a pinned `source-repository-package` git dependency in each project's
`cabal.project`, so every consumer builds against an exact commit. The base image warms
`hostbootstrap-core`'s dependencies into the frozen Cabal store so derived builds hit the warm store.
See [base_image](../engineering/base_image.md) and [warm_store](../engineering/warm_store.md).
