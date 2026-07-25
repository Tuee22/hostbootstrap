# hostbootstrap-core Library

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [composition_methodology](composition_methodology.md), [binary_context_config](binary_context_config.md), [python_haskell_boundary](python_haskell_boundary.md), [build_and_run_model](build_and_run_model.md), [ensure_reconcilers](../engineering/ensure_reconcilers.md), [dhall_topology](../engineering/dhall_topology.md)

> **Purpose**: Describe the `hostbootstrap-core` Haskell library — its module surface, the `[Step]`
> chain algebra it ships, and the extension contract a project binary uses to build on top of it.

## TL;DR

- `hostbootstrap-core` owns the reusable host-management primitives and recursive interpreter:
  host-tool resolution, substrate detection, `ensure` reconcilers, cluster-lifecycle semantics, and the
  binary-context validation that gates execution. A consumer still owns project/provider actions such as
  the demo's VM setup, image build, and direct-host preparation, and contributes them as steps.
- The core surface a project extends is the **`Step` algebra**. Core ships host-management step kinds
  (deploy-VM, ensure-X, copy-source, build-pb, build-image, context-init, deploy-kind, deploy-chart,
  expose-port); a project contributes its own step kinds (for the demo, deploy-minio, deploy-registry,
  push-image, and accelerator-daemon placement)
  into the same ordered `[Step]`. Host steps and workload steps interleave freely — this is the
  workload-extension seam.
- A project's current forward ordering is its **lift chain**, a pure function
  `chain :: cfg -> [Step]`. `project up` is the recursive interpreter that runs the current frame's steps
  and hands off `pb project up` into the next frame. Frame context and teardown are still independently
  supplied; the target replaces all three with one opaque validated
  `ProjectPlan scope specDigest planId configId cfg`.
- The surfaced core command tree is exactly five user-facing verbs: `project`, `test`, `service`,
  `context`, and `check-code`. There are no hidden commands. `ensure` is a reconciler library a project
  may call from a step action; core also exports an `ensureStep` constructor. The current demo invokes
  `runEnsure` inside larger provider/build actions instead of representing each reconcile call as an
  independent `ensure-*` row.
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

On Incus/Linux, `project up` is intended to stand up the persistent stack — a cordoned kind cluster, the
in-cluster registry, the project image pushed to the in-cluster registry, and the web chart pod. The
current `project down`/`project destroy` path performs owned current-frame Kind cleanup plus the project
hook; the target child-first inverse remains plan-owned. Reconciler calls occur while the recursive
interpreter runs, but the demo currently embeds them in composite `deploy-VM`, `build-pb`, `build-image`,
and accelerator actions. It does not use `ensureStep` to expose each call as its own chain row.

The direct `linux-gpu` path is also represented by the same core surfaces, not a second orchestrator.
Its two-frame demo chain runs the metal resource preflight plus `Ensure.Docker`/`Ensure.Cuda`, builds the
CUDA project image, and hands off with `--gpus=all`. The demo's `containerPlan` selects
`NvkindDriver`; core executes that supplied plan, creates the explicit control-plane + GPU-worker
topology, splits and applies the one
cluster envelope across both node containers, probes allocatable GPU before any Helm or `kubectl`
mutation, installs NVIDIA device-plugin `0.19.3` only when that probe is not already positive, and gates
on positive `nvidia.com/gpu` before the project deploys its GPU-requesting daemon pod. These surfaces have
static coverage. Native and virtualized hardware evidence, current gate status, and test totals belong in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

The Windows surface splits by responsibility: the `windows-cpu`/`windows-gpu` substrates and
`Ensure.CudaWin` describe the host build stack, while `HostBootstrap.Wsl2` and `Ensure.Wsl2` implement
the Windows provider path. Current hardware evidence and closure remain in the development plan. See
[wsl2](../engineering/wsl2.md) and [ensure_reconcilers](../engineering/ensure_reconcilers.md).

Current generic model: under
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md) the extension
contract is the generic `ProjectSpec cfg tcfg`, parameterized over a project's own config type `cfg`
(its `<project>.dhall`) and test-config type `tcfg` (its `<project>.test.dhall`). Core then owns no fixed config
type and **no default values**. The current `ProjectCfg` class requires `cfgContext` and
`cfgWithContext`; production paths read through `cfgContext`, while `cfgWithContext` is an unused
compatibility method outside instances/tests and is not lift authority. The target scope-aware
`ProjectCodec scope specDigest cfg`/`ValidatedConfig scope specDigest configId (cfg scope)` transition
removes that raw update seam. The project-owned
`psServiceVariant :: cfg -> Either String String` supplies service selection, while the surfaced command
tree (`project`, `test`, `service`, `context`,
`check-code`) stays fixed. Core owns no defaults. Current `psInit :: InitArgs -> cfg`, `psTestInit`, and
`psTestConfig` are independent callbacks. `project init` layers optional flag overrides over the
`psInit` value; the demo calls `demoInitWithMessage` from both `demoInit` and `demoTestConfig` by
convention, while `test init` follows the separate `psTestInit` path. Demo service projection still
carries separate fallback ports/timeouts. Target `psAssemble` makes one scope-aware structural assembler
from which every role projection is total. See the
[generic_project_model.md](generic_project_model.md) design,
[phase 19](../../DEVELOPMENT_PLAN/phase-19-generic-project-model.md), and
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md).

## Module Surface

The library namespace is `HostBootstrap.*`. The set below is indicative of the surface consumers depend
on; the canonical inventory is tracked in
[`../../DEVELOPMENT_PLAN/system-components.md`](../../DEVELOPMENT_PLAN/system-components.md).

| Module | Responsibility |
|--------|----------------|
| `HostBootstrap.HostTool` | Closed enumeration and absolute-path resolver for managed external tools (including `Nvkind`/`NvidiaSmi` and Windows `Winget`, `Nvcc`, and `Wsl`). Most production paths consume resolved tools, but the repository-wide removal of residual bare-command calls is still open. |
| `HostBootstrap.HostConfig` | Typed host configuration containing detected substrate and resolved tool paths. `HostCapacity` is discovered separately by `HostBootstrap.Cluster.Cordon` for budgeting. |
| `HostBootstrap.HostPrereqs` | Fail-fast host-minimum checks (the pre-binary subset the thin bootstrapper reclaims). |
| `HostBootstrap.Substrate` | Substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`, `windows-cpu`, `windows-gpu`) and host-applicability predicates. |
| `HostBootstrap.Ensure` | The `Reconciler` value type and `runEnsure` runner. It is not exposed as a command; the current demo calls it from composite step actions, while `HostBootstrap.Step.ensureStep` is available for projects that model a reconcile call as its own row. |
| `HostBootstrap.Ensure.*` | One reconciler module per host dependency (`Docker`, `Colima`, `Lima`, `AppleMetal`, `Cuda`, `CudaWin`, `Homebrew`, `Ghc`, `Incus`, `Wsl2`); each is a probe-first value with a host-applicability predicate and reconcile action. Idempotence is the target contract, while current probe strength and platform install coverage vary: Docker installs only on Linux and delegates/refuses on Apple/Windows, and Homebrew can only verify the pre-binary minimum. `Ensure.Cuda` owns the signed NVIDIA apt bootstrap, default-runtime/CDI/volume-injection configuration, and the exact nvkind Docker smoke. See [ensure_reconcilers](../engineering/ensure_reconcilers.md). |
| `HostBootstrap.Step` | The current public `Step`/`StepKind` algebra, its constructors (including `postHandoffStep`/`PostHandoff`), pure renderers, and first-appearance frame grouping (`renderChainPlan`, `stepsForFrame`, `chainFrames`). The public record/sum constructors permit empty chains, duplicate frame/step identifiers, a project kind named like a core kind, and noncontiguous `A/B/A` frames; grouping then executes all `A` rows before `B`, so the rendered source order can disagree with execution. The target hides those constructors behind a validated plan. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.Chain` | The recursive/fractal `[Step]` interpreter (`renderChain`, `runChainFromFrame`): it runs the current frame's steps then lifts `pb project up` into the next frame. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.Config.Schema` | Owner for project-local `<project>.dhall` schema surfaces, sibling lookup (`siblingProjectConfigPath`), child projections, and service/daemon config snapshot metadata. Core owns no defaults. Its current init/test callbacks are independent; the demo shares `demoInitWithMessage` between `demoInit` and `demoTestConfig` by convention, while service projection has separate fallback values. In the current demo the named `context-init` action is only an announcer: the VM config is projected/delivered by the composite bootstrap action, the container config by `psFrameContext` plus the lift, and service/daemon configs by deployment actions. See [dhall_topology](../engineering/dhall_topology.md). |
| `HostBootstrap.Context` | Binary-context substrate inside `<project>.dhall`: discover the sibling path, render topology frames, validate selected ancestry and supplied witnesses, and gate the chain per-frame on handoff. It does not yet validate the whole graph or require a placement-complete witness set. Read-only introspection backs the `context` command. See [binary_context_config](binary_context_config.md). |
| `HostBootstrap.Cluster.Cordon` | Resource-budget verification and cordoning (Colima/Lima/Incus/WSL provider builders plus named kind-node limits). Current lifecycle splits one cluster envelope over the declared node list, but `fitsBudget` is not wired to the complete topology-derived workload set, provider builders can round byte ceilings upward, existing provider walls are not uniformly reconciled, and the demo has duplicate editable/applied budget authorities. The target admits one pure provider-exact `ProviderWallSpec`/`EffectiveBudget`, constructs only proved positive pre-effect `BudgetPartition` slices, authorizes initial create/apply through a journaled same-spec reservation, and requires the observed live wall authority for later mutations; WSL's utility-VM wall is exclusive shared global state. See [resource_budgeting](../engineering/resource_budgeting.md). |
| `HostBootstrap.Cluster.Lifecycle` | kind/nvkind/Helm cluster up/down/delete semantics and the never-delete-`.data` invariant, invoked as the deploy-kind / deploy-chart step kinds. It owns driver-specific config/node topology, the all-node cordon, the NVIDIA runtime smoke, pinned device-plugin `0.19.3`, and the allocatable-GPU gate for `NvkindDriver`. See [cluster_lifecycle](../engineering/cluster_lifecycle.md). |
| `HostBootstrap.Lima` | Lima VM lifecycle argv builders for the Apple Silicon pristine demo VM (`start`, `shell`, `copy`, guarded `delete`), invoked by the deploy-VM step kind. |
| `HostBootstrap.Wsl2` | WSL2 helper argv builders plus readiness classification. The active provider registers its named Ubuntu distro through `wsl --install ... --name ... --vhd-size`, enters it with `wsl -d <distro> --`, terminates it for `down`, and guards `unregister` for destroy. Older `wsl --import` helpers remain uncalled. See [wsl2](../engineering/wsl2.md). |
| `HostBootstrap.Lift` | The self-reference compositional lift: run a subcommand of the binary in a nested context (`Local`/provider VM/`InContainer`) by invoking the binary again there. The `[Step]` interpreter lifts `pb project up` across each frame boundary through this seam. The pure argv fold is unit-tested. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.Harness` | The standardized test engine — `runMatrix` over the harness-built `Seams` wired from the project's compiled `TestSuite`. It generates config variants and drives the real `project up`; successful bring-up runs assertions and `project destroy` through `finally`, and ordinary bring-up failures also attempt destroy. Its caught `SafetyRefusal` branch skips teardown. Preconditions and the generated-file delete guard reduce collision risk, but they do not establish production isolation: the demo currently selects the Production plan and `.data`, and lifecycle resources lack complete ownership receipts. See [harness_workflow](harness_workflow.md). |
| `HostBootstrap.Command` | The **fixed** core command tree (`coreCommands`): `project init|up|down|destroy`, `test init|run`, `service init|schema|run`, `context`, and `check-code`. `project down|destroy` invokes core Kind cleanup only when the current frame owns `deploy-kind`; nested VM/project-container clusters remain with the project teardown hook, while attempted cleanup failures aggregate. No per-project verbs. |
| `HostBootstrap.CLI` | The generic `ProjectSpec cfg tcfg`, `runHostBootstrapCLI`, and `runBareHostBootstrapCLI`. Current validation checks only a non-empty test suite, reserved/duplicate case ids, artifact shadowing/duplicates, and duplicate service variants. It does not inspect the function-valued chain, context, teardown, service selector, code-check action, or generated config variants; `withChain`, `withFrameContext`, `withTeardown`, and `withServiceConfig` replace prior values. The target opaque constructor validates the complete relation before dispatch. The current spec carries independent `psInit :: InitArgs -> cfg`, `psTestInit`, and `psTestConfig` callbacks plus arbitrary `psServiceVariant :: cfg -> Either String String`; target `psAssemble` and the existential typed `SelectedService` package remove fallback/default and selector/payload drift. |
| `HostBootstrap.DocValidator` | The mechanical documentation validator run through the code-check. See [documentation_standards](../documentation_standards.md). |

## Host-Tool Resolution And Substrate Ownership

External tools are resolved through the closed `HostTool` enumeration (`HostBootstrap.HostTool`) to
absolute paths. The `AbsExe` newtype makes a bare command name unrepresentable as a resolved tool — its
smart constructor rejects any non-absolute path. Most managed paths use this representation, but
repository-wide migration is not complete: residual bare-command call sites remain open in Phase 2.5.
The target is that no library or project code invokes a `$PATH`-resolved bare host command (see
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
- `ensure-X` — a constructor for a reconciler-shaped row (`ensure-ghc`, `ensure-docker`, …); the
  current demo instead calls `runEnsure` inside composite actions;
- `copy-source` — stage project source into the frame;
- `build-pb` — build/install the project binary in the frame (parent-orchestrated, since the child `pb`
  does not exist yet);
- `build-image` — build the project container image;
- `context-init` — a frame-anchor kind intended to own child projection and delivery; its current demo
  action only announces because those effects are split across composite bootstrap/frame-context actions;
- `deploy-kind` / `deploy-chart` — cluster and Helm-release lifecycle leaves;
- `expose-port` — expose an in-cluster `NodePort` to the host.

A project contributes its **own** step kinds (for the demo: `deploy-minio`, `deploy-registry`,
`push-image`, and accelerator-daemon placement) into the same
ordered `[Step]`. Host steps and workload steps interleave freely; the project appends its step kinds to
the chain. This is the workload-extension seam.

A project's current forward ordering is the chain value:

```haskell
chain :: cfg -> [Step]
```

The chain is a **pure function of the project parameters**. Optional structural variation (for example,
skip the VM frame and go straight to Docker) is a flag in the root `<project>.dhall`, so the chain stays
a pure function. Its public element and frame constructors do not enforce non-emptiness, contiguous
frames, unique typed identifiers, or separation between core and project kind names. Because
`stepsForFrame` filters the whole list and `chainFrames` orders frames by first appearance, a source list
`A / B / A` renders in that order but executes both `A` segments before `B`. It is not yet the complete
lifecycle representation because frame-context and teardown functions are supplied separately, and those
setters replace rather than append. The target single-representation doctrine is the opaque plan in
[composition_methodology](composition_methodology.md); `project up --dry-run` currently renders
`chain projectCfg` without executing it.

`project up` is the **recursive / fractal interpreter** of that chain. In each frame it runs the steps
that belong to the current frame, then lifts `pb project up` into the next frame through
`HostBootstrap.Lift`; each `pb` owns its segment and the command can be re-entered at any declared frame.
Current convergence after a partial failure is best-effort because effects lack complete durable
identity-bound journals; Sprints 9.10 and 16.6 own that target. Every descent is the same fractal pattern
— provision the frame, build/install the `pb` in it, hand off `pb project up` — and the Python
bootstrapper is the metal-frame instance of that exact pattern (see
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
  init/test-config builders. `withChain` sets the project's primary contribution — its
  `chain :: cfg -> [Step]` value; `withFrameContext` attaches the per-frame lift-context
  builder; `withTeardown` attaches the chain-frame teardown; `withServices` is the one setter here that
  appends service handlers; `withServiceConfig` maps the effective config's project-owned `ServiceType`
  to one handler key. Repeating any of `withChain`, `withFrameContext`, `withTeardown`, or
  `withServiceConfig` silently replaces the earlier value.
  The bare core binary uses a separate
  entrypoint (`runBareHostBootstrapCLI`).
- `runHostBootstrapCLI` applies the current limited name/test-suite validation, merges the spec with the
  core command tree, and runs the resulting parser. It does not validate chain topology, non-emptiness,
  the case-to-variant relation, or function-valued callbacks. The interpreter loads the sibling
  `<project>.dhall` before acting in a frame and refuses observed mismatches between the process and the
  descriptive frame declared by the config; opaque authority remains target work.

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

This guarantees the **parser tree and command names** are shared, not that bare and project behavior is
identical. `runBareHostBootstrapCLI` deliberately supplies an empty chain, minimal/empty test and service
registries, no-op teardown, and no project-specific checks or artifacts. A project binary supplies a
`ProjectSpec` that passes the limited current name/test-suite validation; its chain, test seams, service
handlers, schema artifacts, and cleanup make those same routes useful. Complete relational validation is
the target described above.

### Surfaced commands

| Command | Behavior |
|---|---|
| `context` | Read-only introspection: `path`/`schema`/`render` are static and config-free; `inspect` reads the sibling `.dhall`, while `show [FILE]` reads the selected or default file. |
| `project init` | Config-free initializer. Its no-flag default writes the root host-orchestrator config; the current parser also accepts role additions, an output path, `--force`/`--if-missing`, and resource/deploy overrides over the project's `psInit` defaults. Opaque role-specific init requests remain target work. |
| `project up` | Recursively interpret `chain projectCfg` from the current frame; attempts reconcile-to-running. `--dry-run` renders the chain. Stands up deploy-kind/nvkind → deploy-minio → deploy-registry → push-image → deploy-chart → expose-port, plus the topology-selected accelerator daemon. Most reconcilers still return `IO ()`, so typed idempotence is open. |
| `project down` | Remove the current frame's owned Kind cluster because Kind has no stopped state, preserve durable roots/provider frames, then invoke the project teardown hook in stop mode. It does not recursively dispatch `down` through each child frame. See [durable_state](durable_state.md). |
| `project destroy` | Perform current-frame cleanup and invoke the project destroy hook, which may remove a provider. It does not yet prove child-to-parent recursive interpretation or complete ownership. Host `.data` is carried outside provider disks, but destroy/up/readback remains unvalidated. |
| `test init` | Needs **no** pre-existing `<project>.dhall`; writes `<project>.test.dhall`. In the demo it contains a suite-name list plus resource overrides; compiled Haskell, not this file, owns case bodies and variants. |
| `test run <case-id>\|all` | Needs `<project>.test.dhall`; `all` runs the compiled matrix and a case id selects one compiled case. Help describes the surface as root-only, but the parser does not currently enforce a context root gate. Per generated config variant it drives the real `project up`, asserts, then calls `project destroy`. The demo planner incorrectly selects Production/`.data`; target `Harness projectId runId` isolation remains open. |
| `service init\|schema\|run` | Run a long-running role. Current core checks a leaf primary kind, calls arbitrary `psServiceVariant`, and looks up its key; it does not require a service ADT/capability relation. Demo handlers then reload the sibling config, so selection and execution can observe different bytes. The target runtime verifier jointly mints a request/role parameters under one fresh child-local `configId` plus exact-byte wire evidence; no full `ValidatedConfig` crosses that boundary. Internal dispatch packages them with matching placement/authority/effect proof and a closed handler; the handler receives no full config. No `service down`. |
| `check-code` | Runs the project's fail-fast code-check action. |

`project up` *deploys* and `test run` *drives* that deploy under a harness-generated config — they are the
same chain, not two representations. `project up` interprets the chain to stand up the persistent deploy
stack and ends at a live webservice (`service run`) on `localhost:30080`, whose handler reads its config
and renders `message`. `test run all` runs that same `project up` once per config variant (the demo runs
two), asserts the live stack (the SPA `#message` polymorphic over the active `EXPECTED_MESSAGE`), using
the currently selected profile. In the demo that is incorrectly Production/`.data`, and lifecycle
resources do not yet all return ownership receipts; see [harness workflow](harness_workflow.md).

## Consumption

The in-repository demo consumes `hostbootstrap-core` as a sibling local package. A remote consumer uses
a `source-repository-package` and must supply a full immutable commit in its `tag` field; the governed
template in [derived project standards](../engineering/derived_project_standards.md) makes that pin
explicit. The base image warms `hostbootstrap-core`'s dependencies into the frozen Cabal store so
derived builds hit the warm store.
See [base_image](../engineering/base_image.md) and [warm_store](../engineering/warm_store.md).
