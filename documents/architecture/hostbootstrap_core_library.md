# hostbootstrap-core Library

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [composition_methodology](composition_methodology.md), [binary_context_config](binary_context_config.md), [python_haskell_boundary](python_haskell_boundary.md), [build_and_run_model](build_and_run_model.md), [ensure_reconcilers](../engineering/ensure_reconcilers.md), [dhall_topology](../engineering/dhall_topology.md)

> **Purpose**: Describe the `hostbootstrap-core` Haskell library — its opaque `StepPlan` algebra and
> recursive interpreter, and the extension contract a project binary uses to build on top of it.

## TL;DR

- `hostbootstrap-core` owns the reusable host-management primitives and recursive interpreter:
  host-tool resolution, substrate detection, `ensure` reconcilers, cluster-lifecycle semantics, and the
  binary-context validation that gates execution. A consumer still owns project/provider actions such as
  the demo's VM setup, image build, and direct-host preparation, and contributes them as steps.
- The core surface a project extends is the **`Step` algebra**. Core ships host-management step kinds
  (deploy-VM, ensure-X, copy-source, build-pb, build-image, context-init, deploy-kind, deploy-chart,
  expose-port); a project contributes its own step kinds (for the demo, deploy-minio, deploy-registry,
  push-image, and accelerator-daemon placement)
  into the same ordered validated `StepPlan`. Host steps and workload steps interleave freely — this is the
  workload-extension seam.
- A project's current forward ordering is its opaque validated `StepPlan`, assembled from pure additive
  step fragments. `project up` is the recursive interpreter that runs the current frame's steps and
  hands off `pb project up` into the next frame. Frame context and teardown are still independently
  supplied as checked single-assignment contributions; the target derives all three from one
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
`demoChainFor :: Substrate -> ProjectConfig scope -> [Step]` fragment (in
`demo/src/HostBootstrapDemo/Commands.hs`), accepted through `addSteps` and finalized into the
`StepPlan` interpreted recursively by `project up`; the demo also
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
contract is the generic `ProjectSpec projectId cfg tcfg`, parameterized over a project's config family
`cfg :: Type -> Type` (its `<project>.dhall`) and test-config type `tcfg` (its
`<project>.test.dhall`). Core then owns no fixed config type and **no default values**.
`ProjectCfg projectId cfg` exposes only read-only `cfgContext` and installs separate Production and
authority-closed Harness mapped `ProjectCodec`s; the raw context updater is gone. Canonical
render/hash/strict re-decode yields scope-correct root-local `ValidatedConfig` identity. The project-owned
the surfaced command tree (`project`, `test`, `service`, `context`, `check-code`) stays fixed. One
restricted `psAssemble` is the default-bearing project-config path for Production init and exact-run
Harness variants; `psTestInit` separately builds `tcfg`. An opaque typed service registry is jointly
finalized with the full codec under one digest, and demo role projection consumes only explicit
assembled Web/Accelerator fields with no fallback values. See the
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
| `HostBootstrap.Ensure.*` | Nine context-free dependency reconcilers live in `allReconcilers`; `Ensure.Colima` is instead a prepared, plan-bound per-project provider-wall adapter. It consumes the admitted exact wall/reservation, refuses conflicting same-name state, never adopts `default`, starts with global context activation disabled, and routes Docker through `colima-<project>`. Other probe strengths and platform install coverage still vary: Docker installs only on Linux and delegates/refuses on Apple/Windows, and Homebrew can only verify the pre-binary minimum. `Ensure.Cuda` owns the signed NVIDIA apt bootstrap, default-runtime/CDI/volume-injection configuration, and the exact nvkind Docker smoke. See [ensure_reconcilers](../engineering/ensure_reconcilers.md). |
| `HostBootstrap.Step` | Opaque `Step`/`StepKind`, disjoint typed core/project identities, explicit reverse policies, namespaced operation keys, and opaque `StepPlan`. Smart constructors are public; raw constructors are not. `mkStepPlan` rejects empty/duplicate/conflicting plans, noncontiguous `A/B/A` returns, and invalid post-handoff placement while preserving every valid list's exact order. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.Readiness` | Opaque validated polling and total probe results. Closed backend probes require an exact planned resource and mint generative plan/resource/dependency-indexed `Ready`; `ObservedReady` is explicitly non-authorizing compatibility evidence for live paths not yet migrated to prepared operations. See [readiness](readiness.md). |
| `HostBootstrap.Reconcile` | Final-codec/step-plan lifecycle identity; opaque planned resources/edges, reconcile/adoption outcomes, prepared operation pairs, phase-indexed handles, and legal persisted journal transitions. This is the Phase 9 type foundation; protected-store and live adapter integration remain downstream. |
| `HostBootstrap.Chain` | The recursive/fractal `StepPlan` interpreter (`renderChain`, `runChainFromFrame`): it runs the current frame's steps then lifts `pb project up` into the next frame. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.Config.Schema` | Owner for project-local `<project>.dhall` schema surfaces, sibling lookup, canonical root admission, canonical render/hash/re-decode verification, child projections, and service/daemon snapshot metadata. `withSiblingValidatedProjectConfigContext` binds service selection and execution to one verified snapshot. Core owns no defaults. The named `context-init` action is still only an announcer; VM/container/service delivery remains split across lifecycle actions. See [dhall_topology](../engineering/dhall_topology.md). |
| `HostBootstrap.Config.Fields` | Opaque common framework view, full-vs-role and Production-vs-Harness discriminators, `RoleCodec`, structural `RuntimeRoleWire`, `ValidatedServiceRequest`, and `RoleParams`. Role wires include mandatory framework validation plus only the selected service fields. |
| `HostBootstrap.Context` | Binary-context substrate inside `<project>.dhall`: discover the sibling path, render topology frames, validate selected ancestry and supplied witnesses, and gate the chain per-frame on handoff. It does not yet validate the whole graph or require a placement-complete witness set. Read-only introspection backs the `context` command. See [binary_context_config](binary_context_config.md). |
| `HostBootstrap.ProjectRoot` | Rank-2 canonical project-root admission with private `CanonicalProjectRoot scope rootId` / `CanonicalHostPath scope rootId` constructors. Relative roots use the config-owned project-home anchor; missing, wrong-kind, escaping, and redirected roots fail before the callback. |
| `HostBootstrap.Cluster.Cordon` | Exact whole-byte resource parsing, capacity verification, and Colima/Lima/Incus/WSL/kind-node builders. Whole-GiB providers reject inexact hard ceilings rather than rounding upward. The complete workload set and live existing-wall reconciliation remain downstream. See [resource_budgeting](../engineering/resource_budgeting.md). |
| `HostBootstrap.Cluster.Budget` | Closed provider keys plus opaque plan-indexed validated/effective budgets, workload fit, constructive partitions/slices, and journal-before-call wall reservation/preparation/settlement. WSL success returns its lease inseparably; uncertain acquisition returns no authority. The Colima live adapter is implemented; other provider CAS/adapters and command integration remain downstream. |
| `HostBootstrap.Cluster.Lifecycle` | kind/nvkind/Helm cluster up/down/delete semantics and the never-delete-`.data` invariant, invoked as the deploy-kind / deploy-chart step kinds. It owns driver-specific config/node topology, the all-node cordon, the NVIDIA runtime smoke, pinned device-plugin `0.19.3`, and the allocatable-GPU gate for `NvkindDriver`. See [cluster_lifecycle](../engineering/cluster_lifecycle.md). |
| `HostBootstrap.Lima` | Lima VM lifecycle argv builders for the Apple Silicon pristine demo VM (`start`, `shell`, `copy`, guarded `delete`), invoked by the deploy-VM step kind. |
| `HostBootstrap.Wsl2` | WSL2 helper argv builders plus readiness classification. The sole registration builder uses `wsl --install ... --name ... --vhd-size`; the provider enters with `wsl -d <distro> --`, terminates for `down`, and guards `unregister` for destroy. The unused `wsl --import` builder has been removed. See [wsl2](../engineering/wsl2.md). |
| `HostBootstrap.Lift` | The self-reference compositional lift: run a subcommand of the binary in a nested context (`Local`/provider VM/`InContainer`) by invoking the binary again there. The `StepPlan` interpreter lifts `pb project up` across each frame boundary through this seam. `canonicalHostMount` admits only a root/path pair carrying identical private indices. The pure argv fold is unit-tested. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.Harness` | The standardized test engine — `runMatrix` over the harness-built `Seams` wired from the project's compiled `TestSuite`. It generates config variants and drives the real `project up`; successful bring-up runs assertions and `project destroy` through `finally`, and ordinary bring-up failures also attempt destroy. Its caught `SafetyRefusal` branch skips teardown. Preconditions and the generated-file delete guard reduce collision risk, but they do not establish production isolation: the demo currently selects the Production plan and `.data`, and lifecycle resources lack complete ownership receipts. See [harness_workflow](harness_workflow.md). |
| `HostBootstrap.Command` | The **fixed** core command tree (`coreCommands`): `project init|up|down|destroy`, `test init|run`, `service init|schema|run`, `context`, and `check-code`. `project down|destroy` invokes core Kind cleanup only when the current frame owns `deploy-kind`; nested VM/project-container clusters remain with the project teardown hook, while attempted cleanup failures aggregate. No per-project verbs. |
| `HostBootstrap.CLI` | Opaque generic `ProjectSpec projectId cfg tcfg`, unfinished `ProjectSpecBuilder`, checked additive operations, explicit frame-context/teardown single-assignment, `finalizeProjectSpec`, and the two entrypoints. Finalization validates suite/case/artifact/input/service contributions; per-config plan projection validates the exact non-empty `StepPlan` before interpretation. One restricted `psAssemble` supplies Production/Harness configs and `psTestInit` supplies `tcfg`. |
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
`push-image`, and accelerator-daemon placement) into the same ordered plan. Host steps and workload steps
interleave freely; `addSteps` appends checked contributions before finalization. This is the
workload-extension seam.

A project's current forward ordering is an opaque `StepPlan`. Its source fragments are pure functions of
project parameters. Optional structural variation (for example, skip the VM frame and go straight to
Docker) is a flag in the root `<project>.dhall`. `mkStepPlan` rejects empty/duplicate/conflicting plans,
non-contiguous frame returns, and invalid post-handoff placement while preserving every accepted source
order exactly. Raw `Step`, identity, and plan constructors are hidden. It is not yet the complete
lifecycle representation because frame-context and teardown functions are supplied separately as checked
single-assignment slots. The target resource-indexed plan is described in
[composition_methodology](composition_methodology.md); `project up --dry-run` renders the same validated
plan without executing it.

`project up` is the **recursive / fractal interpreter** of that plan. In each frame it runs the steps
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
projectSpec
  :: TestSuite
  -> IO ()
  -> [ConfigArtifact]
  -> CodecWitness tcfg
  -> (InitArgs -> tcfg)
  -> (forall scope. AssemblyRequest projectId tcfg (TestVariant tcfg) scope
        -> ConfigAssembly scope (cfg scope))
  -> ProjectSpecBuilder projectId cfg tcfg
addSteps
  :: (cfg (Production projectId) -> [Step])
  -> ProjectSpecBuilder projectId cfg tcfg
  -> ProjectSpecBuilder projectId cfg tcfg
addAssemblyInputs
  :: [ConfigInput]
  -> ProjectSpecBuilder projectId cfg tcfg
  -> ProjectSpecBuilder projectId cfg tcfg
finalizeProjectSpec
  :: ProjectSpecBuilder projectId cfg tcfg
  -> Either ProjectSpecError (ProjectSpec projectId cfg tcfg)
runHostBootstrapCLI :: String -> ProjectSpec projectId cfg tcfg -> IO ()
runBareHostBootstrapCLI :: String -> IO ()
```

`TestCfg tcfg` supplies the pure project-owned projection from the executable `[CaseId]` registry and
decoded `tcfg` into an opaque validated `TestMatrix (TestVariant tcfg)`. The config callback therefore
assembles one already-validated draft; it cannot return an empty list or invent/duplicate raw labels.

- `progName` is the project/config name used in help and diagnostics. Before dispatch it must equal the
  normalized invoked executable name (with a Windows `.exe` removed), or the process exits before
  config/lifecycle work.
- `projectSpec` starts the unfinished builder from the `TestSuite`, project `check-code` action,
  `ConfigArtifact` delta, and project-owned
  init/test-config builders. `addSteps`, `addArtifacts`, `addAssemblyInputs`, and `addServices` append
  without erasure. `setFrameContext` and `setTeardown` are checked single-assignment slots and receive
  separately admitted canonical-root authority. Service definitions inseparably bind identity, typed
  projection, role codec, and handler; no separate selector exists.
  The bare core binary uses a separate
  entrypoint (`runBareHostBootstrapCLI`).
- `finalizeProjectSpec` validates the static contributions. Per-config plan projection validates exact
  non-empty topology and typed identities before an interpreter is returned. `runHostBootstrapCLI`
  accepts only that opaque finalized value, applies executable-name validation, merges it with the core
  command tree, and runs the parser. The interpreter loads the sibling
  `<project>.dhall` before acting in a frame and refuses observed mismatches between the process and the
  descriptive frame declared by the config; opaque authority remains target work.

A project binary contributes a chain value plus extension streams, never its own verbs. Its `Main.hs`
attaches the chain (interleaving core and project step kinds) to the spec and hands it to the entrypoint:

```haskell
import HostBootstrap.CLI
  ( addServices, addSteps, finalizeProjectSpec, projectSpec
  , runHostBootstrapCLI, setFrameContext, setTeardown )
import HostBootstrap.Substrate (detect)
import HostBootstrapDemo.Commands (demoArtifacts, demoChainFor, demoCheckCode, demoFrameContext, demoServices, demoTeardown, demoTestSuite)
import HostBootstrapDemo.Config (demoAssemble, demoTestInit, testConfigCodec)
import System.Exit (die)

main :: IO ()
main = do
  -- Detect the host substrate once so the per-frame lift context folds each
  -- metal→VM handoff to the right provider shell (Incus on Linux CPU, Lima on Apple Silicon).
  -- Linux GPU has no VM frame; its direct handoff is a GPU-enabled container lift.
  substrate <- detect >>= either die pure
  spec <- either (die . show) pure
    ( finalizeProjectSpec
        ( addServices demoServices
            ( addSteps (demoChainFor substrate)
                ( setFrameContext (demoFrameContext substrate)
                    ( setTeardown demoTeardown
                        (projectSpec demoTestSuite demoCheckCode demoArtifacts testConfigCodec demoTestInit demoAssemble)
                    )
                )
            )
        )
    )
  runHostBootstrapCLI "hostbootstrap-demo" spec
```

The bare `hostbootstrap` binary uses the dedicated bare entrypoint:

```haskell
main :: IO ()
main = runBareHostBootstrapCLI "hostbootstrap"
```

This guarantees the **parser tree and command names** are shared, not that bare and project behavior is
identical. `runBareHostBootstrapCLI` uses a private minimal finalized specification with an internal
anchor, minimal/empty test and service registries, no-op teardown, and no project-specific checks or
artifacts. A project binary supplies an opaque finalized `ProjectSpec`; its plan, test seams, typed
services, schema artifacts, and cleanup make those same routes useful. Resource/lifecycle relational
validation beyond the exact step sequence remains the downstream target described above.

### Surfaced commands

| Command | Behavior |
|---|---|
| `context` | Read-only introspection: `path`/`schema`/`render` are static and config-free; `inspect` reads the sibling `.dhall`, while `show [FILE]` reads the selected or default file. |
| `project init` | Config-free initializer. Its no-flag default writes the root host-orchestrator config; the current parser also accepts role additions, an output path, `--force`/`--if-missing`, and resource/deploy overrides interpreted by `psAssemble (ProductionAssembly args)`. Opaque role-specific init requests remain target work. |
| `project up` | Resolve and recursively interpret the opaque `StepPlan` from the current frame; `--dry-run` renders that same plan. Stands up deploy-kind/nvkind → deploy-minio → deploy-registry → push-image → deploy-chart → expose-port, plus the topology-selected accelerator daemon. Most reconcilers still return `IO ()`, so typed idempotence is open. |
| `project down` | Remove the current frame's owned Kind cluster because Kind has no stopped state, preserve durable roots/provider frames, then invoke the project teardown hook in stop mode. It does not recursively dispatch `down` through each child frame. See [durable_state](durable_state.md). |
| `project destroy` | Perform current-frame cleanup and invoke the project destroy hook, which may remove a provider. It does not yet prove child-to-parent recursive interpretation or complete ownership. Host `.data` is carried outside provider disks, but destroy/up/readback remains unvalidated. |
| `test init` | Needs **no** pre-existing `<project>.dhall`; writes `<project>.test.dhall`. In the demo it contains a suite-name list plus resource overrides; compiled Haskell, not this file, owns case bodies and variants. |
| `test run <case-id>\|all` | Needs `<project>.test.dhall`; `all` runs the compiled matrix and a case id selects one compiled case. Help describes the surface as root-only, but the parser does not currently enforce a context root gate. Each variant is assembled as `cfg (Harness projectId runId)` under fresh authority and its matching codec, then drives the real `project up`, asserts, and calls `project destroy`. The demo lifecycle planner still incorrectly selects the Production profile/`.data`; full Harness resource isolation remains open. |
| `service init\|schema\|run` | Run a long-running role. `schema` prints the full schema plus distinct Production/Harness role-wire families (including structured empty families). `run` checks a service leaf, canonically verifies one sibling snapshot, structurally selects exactly one typed registry definition, mints an opaque request under the finalized digest, and invokes a handler closed over only its role fields plus safe framework view. The full config is not reloaded or passed to the handler. Sprint 18.6 replaces the remaining raw handler `IO` with effect-indexed one-use execution. No `service down`. |
| `check-code` | Runs the project's fail-fast code-check action. |

`project up` *deploys* and `test run` *drives* that deploy under a harness-generated config — they are the
same plan, not two representations. `project up` interprets the plan to stand up the persistent deploy
stack and ends at a live webservice (`service run`) on `localhost:30080`; its typed request already
contains the assembled `message`, so the handler does not reopen config. `test run all` runs that same
`project up` once per config variant (the demo runs
two), asserts the live stack (the SPA `#message` polymorphic over the active `EXPECTED_MESSAGE`), using
the currently selected profile. In the demo that is incorrectly Production/`.data`, and lifecycle
resources do not yet all return ownership receipts; see [harness workflow](harness_workflow.md).

## Consumption

The in-repository demo consumes `hostbootstrap-core` as a sibling local package. A remote consumer uses
a `source-repository-package` and must supply a full immutable commit in its `tag` field; the governed
template in [derived project standards](../engineering/derived_project_standards.md) makes that pin
explicit. The rolling base image warms a best-effort Cabal store; matching artifacts are reused
opportunistically and ordinary cache misses may resolve/download/build compatible dependencies.
See [base_image](../engineering/base_image.md) and [warm_store](../engineering/warm_store.md).
