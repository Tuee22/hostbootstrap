# hostbootstrap-core Library

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [composition_methodology](composition_methodology.md), [binary_context_config](binary_context_config.md), [python_haskell_boundary](python_haskell_boundary.md), [build_and_run_model](build_and_run_model.md), [ensure_reconcilers](../engineering/ensure_reconcilers.md), [dhall_topology](../engineering/dhall_topology.md)

> **Purpose**: Describe the `hostbootstrap-core` Haskell library — its opaque `StepPlan` authoring
> algebra, exact `ProjectPlan` interpreter, and the extension contract a project binary uses to build on
> top of it.

## TL;DR

- `hostbootstrap-core` owns the reusable host-management primitives and the current-frame substrate of the
  target recursive interpreter:
  host-tool resolution, substrate detection, `ensure` reconcilers, cluster-lifecycle semantics, and the
  binary-context validation that gates execution. A consumer still owns project/provider actions such as
  the demo's VM setup, image build, and direct-host preparation, and contributes them as steps.
- The core surface a project extends is the **`Step` algebra**. Core ships host-management step kinds
  (deploy-VM, ensure-X, copy-source, build-pb, build-image, context-init, deploy-kind, deploy-chart,
  expose-port); a project contributes its own step kinds (for the demo, deploy-minio, deploy-registry,
  push-image, and accelerator-daemon placement)
  into the same ordered validated `StepPlan`. That value is the authoring and validation input admitted
  into one `ProjectPlan scope specDigest planId configId cfg`; host and workload steps interleave freely.
- A project's public forward execution boundary is the exact admitted `ProjectPlan`. `renderChain`
  consumes its complete non-empty `forward` projection. `runChainFromFrame` consumes the same plan plus
  matching Execute `CommandAuthority` and `LifecycleCursor`, runs its non-empty current-frame projection,
  and derives descent from its `DerivedTopology`.
- The surfaced core command tree is exactly five user-facing verbs: `project`, `test`, `service`,
  `context`, and `check-code`. There are no hidden commands. `ensure` is a reconciler library a project
  may call from a step action; core also exports an `ensureStep` constructor. The current demo invokes
  `runEnsure` inside larger provider/build actions instead of representing each reconcile call as an
  independent `ensure-*` row.
- The canonical home of this model is [composition_methodology](composition_methodology.md); this doc
  describes the library surface that realizes it and defers there for the model itself.

## Current Status

The core surface is the fixed **`project` command and current-frame interpreter substrate**. It merges the `context`
read-only command, `project init|up|down|destroy`, the `test init|run` split, `service init|schema|run`,
and `check-code` into a
composable `optparse-applicative` value. The demo's deploy is the first-class
`demoChainFor :: Substrate -> ProjectConfig scope -> [Step]` fragment (in
`demo/src/HostBootstrapDemo/Commands.hs`), accepted through `addSteps` and validated as the authored graph
from which exact project-plan admission derives `forward` and `DerivedTopology`; the demo also
contributes its `web` and `accelerator` service variants and its VM/provider IO as chain steps — the
surface is fixed, so it adds no verbs. The binary-context gate and
the project-local `<project>.dhall` schema decoder/encoder back the interpreter.

The public `HostBootstrap.Chain` surface is exact-plan-only. Production dispatch retains or reconstructs
one admitted plan across rendering, snapshot persistence/binding, authority, cursor admission, and
interpretation; its reverse verbs use the matching plan/current-frame projection. Harness dispatch now
retains one Harness-indexed plan inside the generated-config ownership bracket and packages that exact
plan's common forward/reverse actions for direct engine use. The project's five-field `TestSuite` supplies
only the safety precondition, assertion-environment opener, case matrix, per-case assertion, and
post-reverse absence assertion; it owns no lifecycle callback or subprocess route. `StepPlan` remains
available to author and validate a graph; it is not the public Chain execution boundary. Nested lifecycle
entry fails closed
until authenticated child admission and proof-complete recursive traversal are available, and exact
`down`/`destroy` authorization belongs to
[the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md).

Development ownership follows that boundary: the
[step-algebra-and-project-plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)
owns the exact plan/current-frame/Chain and Production current-frame foundation, while authenticated
recursive child entry and traversal remain with the
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md). The
[test-harness-and-run-ownership phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md)
owns the Harness command consumer and assertion engine.

The lift surface is layered below that plan boundary. The
[Dhall-configuration-and-generic-project-model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md)
owns pure `HostBootstrap.Lift.Context`; the
[ensure-reconcilers phase](../../DEVELOPMENT_PLAN/phase-8-ensure-reconcilers.md) owns the generic resolved-tool
`HostBootstrap.Lift`; and the
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
owns provider lifecycle realizations that consume and reexport the lower target records/renderers. Registry
policy is additive above generic Lift, never an import of generic Lift itself.

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
contract is the generic `ProjectSpec cfg tcfg`, parameterized over a project's config family
`cfg :: Type -> Type` (its `<project>.dhall`) and test-config type `tcfg` (its
`<project>.test.dhall`). Core then owns no fixed config type and **no default values**.
`ProjectCfg cfg` exposes only read-only `cfgContext` and installs identity-generative Production and
authority-closed Harness mapped `ProjectCodec`s; the raw context updater is gone. Canonical
render/hash/strict re-decode yields scope-correct root-local `ValidatedConfig` identity. The project-owned
the surfaced command tree (`project`, `test`, `service`, `context`, `check-code`) stays fixed. One
restricted `psAssemble` is the default-bearing project-config path for Production init and exact-run
Harness variants; `psTestInit` separately builds `tcfg`. An opaque typed service registry is jointly
finalized with the full codec under one digest, and demo role projection consumes only explicit
assembled Web/Accelerator fields with no fallback values. See the
[generic_project_model.md](generic_project_model.md) design,
[Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md), and
[development_plan_standards.md § BB](../../DEVELOPMENT_PLAN/development_plan_standards.md).

## Module Surface

The library namespace is `HostBootstrap.*`. The set below is indicative of the surface consumers depend
on; the canonical inventory is tracked in
[`../../DEVELOPMENT_PLAN/system-components.md`](../../DEVELOPMENT_PLAN/system-components.md).

| Module | Responsibility |
|--------|----------------|
| `HostBootstrap.HostTool` | Closed enumeration and absolute-path resolver for managed external tools (including provider discovery tools `Python3`/`Flock`/`Lockf`, `Nvkind`/`NvidiaSmi`, and Windows `Winget`/`Nvcc`/`Wsl`). The prepared Incus and guest-alias ownership routes require the resolved `Flock` namespace; a discovered `Lockf` remains descriptive and cannot mint that authority. Most production paths consume resolved tools, but the repository-wide removal of residual bare-command calls is still open. |
| `HostBootstrap.Detached` | The sealed host-invocation *shape* boundary (§ HH) for a child that outlives its launcher. `DetachedLaunch` hides its constructor and every field accessor; the stdio disposition, descriptor inheritance, session, and console detachment are fixed inside the module. `withDetachedChild` is a rank-2 bracket over the launch, total on acquire, that retains the child's own output for the launcher to quote (§ CC). |
| `HostBootstrap.HostConfig` | Typed host configuration containing detected substrate and resolved tool paths. `HostCapacity` is discovered separately by provider-neutral `HostBootstrap.Cluster.Cordon.Foundation` for budgeting. |
| `HostBootstrap.HostPrereqs` | Fail-fast host-minimum checks (the pre-binary subset the thin bootstrapper reclaims). |
| `HostBootstrap.Substrate` | Substrate detection (`apple-silicon`, `linux-cpu`, `linux-gpu`, `windows-cpu`, `windows-gpu`) and host-applicability predicates. |
| `HostBootstrap.Ensure` | The `Reconciler` value type and `runEnsure` runner. It is not exposed as a command; the current demo calls it from composite step actions, while `HostBootstrap.Step.ensureStep` is available for projects that model a reconcile call as its own row. |
| `HostBootstrap.Ensure.*` | Nine context-free dependency reconcilers live in `allReconcilers`; `Ensure.Colima` is instead a prepared per-project provider-wall adapter. Its current profile opener consumes `Reconcile.LifecyclePlan` plus `BinaryContext`; the [cluster-lifecycle-and-cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md) owns exact `ProjectPlan`/resource/topology/partition/reservation adoption. It refuses conflicting same-name state, never adopts `default`, starts with global context activation disabled, and routes Docker through `colima-<project>`. `Ensure.Wsl2` owns prerequisite diagnostics, normalization, virtualization classification, and `bcdedit` rendering without importing the WSL2 lifecycle realization. Other probe strengths and platform install coverage still vary: Docker installs only on Linux and delegates/refuses on Apple/Windows, and Homebrew can only verify the pre-binary minimum. `Ensure.Cuda` owns the signed NVIDIA apt bootstrap, default-runtime/CDI/volume-injection configuration, and the exact nvkind Docker smoke. See [ensure_reconcilers](../engineering/ensure_reconcilers.md). |
| `HostBootstrap.Step` | Opaque `Step`/`StepKind`, disjoint typed core/project identities, explicit reverse policies, namespaced operation keys, and opaque `StepPlan`. Smart constructors are public; raw constructors are not. `mkStepPlan` rejects empty/duplicate/conflicting plans, noncontiguous `A/B/A` returns, and a post-handoff suffix that does not unwind deepest participating frame first while preserving every valid list's exact order. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.ProjectPlan` | Pure public facade for one generative admitted plan. It exposes opaque `PlannedStep` forward order, `DerivedTopology`, stable snapshot, exact resource/edge projections, and reverse policy/callback projections while keeping construction in the trusted admission layer. |
| `HostBootstrap.Readiness` | Opaque validated polling and total probe results. Closed backend probes require an exact planned resource and mint generative plan/resource/dependency-indexed `Ready`; `ObservedReady` is explicitly non-authorizing compatibility evidence for live paths not yet migrated to prepared operations. See [readiness](readiness.md). |
| `HostBootstrap.Reconcile` | Final-codec/step-plan lifecycle identity; opaque planned resources/edges, reconcile/adoption outcomes, prepared operation pairs, phase-indexed handles, and legal persisted journal transitions. The result/handle foundation belongs to the [canonical-quantities-and-reconcile-results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md); protected-store and live adapter integration remain downstream. |
| `HostBootstrap.Chain` | Exact public current-frame foundation for the recursive interpreter. `renderChain` consumes one `ProjectPlan`'s complete `forward` projection. `runChainFromFrame` consumes that plan plus matching Execute `CommandAuthority` and `LifecycleCursor`, checks the supplied store and the cursor's retained acquisition project/store/broker origin against the authority before opening a record, and rereads the exact acquisition source/current cursor row inside every protected transition. It selects a non-empty current-frame segment and derives the operation-session epoch and identity from the authority. `DerivedTopology` describes a possible descent but grants no child admission; the [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) owns authenticated recursive entry/traversal. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.Config.Schema` | Owner for project-local `<project>.dhall` schema surfaces, sibling lookup, canonical root admission, canonical render/hash/re-decode verification, child projections, and service/daemon snapshot metadata. `withSiblingValidatedProjectConfigContext` binds service selection and execution to one verified snapshot. Core owns no defaults. The named `context-init` action is still only an announcer; VM/container/service delivery remains split across lifecycle actions. See [dhall_topology](../engineering/dhall_topology.md). |
| `HostBootstrap.Config.Fields` | Opaque common framework view, full-vs-role and Production-vs-Harness discriminators, `RoleCodec`, structural `RuntimeRoleWire`, `ValidatedServiceRequest`, and `RoleParams`. Role wires include mandatory framework validation plus only the selected service fields. |
| `HostBootstrap.Context` | Binary-context substrate inside `<project>.dhall`: discover the sibling path, render topology frames, validate the whole graph, selected ancestry, and the placement-complete required/exact witness set, and gate the chain per frame on handoff. Duplicate identifiers, missing parents, cycles, disconnected frames, and incomplete or extraneous witnesses refuse validation. Read-only introspection backs the `context` command. See [binary_context_config](binary_context_config.md). |
| `HostBootstrap.ProjectRoot` | Rank-2 canonical project-root admission with private `CanonicalProjectRoot scope rootId` / `CanonicalHostPath scope rootId` constructors. Admission retains the surrounding config/lifecycle `scope` and mints only `rootId`; the sibling gate therefore cannot yield an independently scoped root. Relative roots use the config-owned project-home anchor; missing, wrong-kind, escaping, and redirected roots fail before the callback. |
| `HostBootstrap.Authority` | Safe lower-authority facade: closed verbs/phases, executable-path-verified rank-2 installed identity, exact-store OS-principal evidence, and opaque broker epoch, root, root-scope, and command-authority inspection. It exposes no raw recorded-epoch or standalone root opener. |
| `HostBootstrap.Authority.Kernel` | Unexposed representation and protected-transition kernel for fresh project/store-bound broker epochs, closed exact-scope root minting, and canonical one-use command reservation. An import guard allow-lists package consumers and keeps configuration/plan validation above this layer. |
| `HostBootstrap.Protected` | Versioned durable record store with OS-released exclusive entry, store identity, exact-version compare-and-swap/delete, atomic publish, injective record-name encoding, and an effective create/remove probe for the exact records directory. |
| `HostBootstrap.Cluster.Cordon.Foundation` | Implemented exposed lower boundary. The [canonical-quantities-and-reconcile-results phase](../../DEVELOPMENT_PLAN/phase-6-canonical-quantities-and-reconcile-results.md) owns opaque canonical-unit `ResourceBudget`, exact quantity parsing/refusal, provider-neutral capacity reads/verification, exact-budget sizing renderers, and storage-wall policy. It imports only lower host config/tool/substrate families, with the exact import set mechanically guarded. Whole-GiB providers reject inexact hard ceilings rather than rounding upward. See [resource_budgeting](../engineering/resource_budgeting.md). |
| `HostBootstrap.Cluster.Cordon` | Implemented configuration-facing facade owned by the [Dhall-configuration-and-generic-project-model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md). It reexports the foundation and adapts `Config.Vocab.Resources`/`ResourceEnvelope`, preflight wrappers, and descriptive pure `fitsBudget`; it owns no plan-indexed workload/fit/partition/slice proof. Its exact dependency direction is mechanically guarded. |
| `HostBootstrap.Cluster.Budget` | Closed provider keys plus opaque plan-indexed validated/effective budgets, workload fit, constructive partitions/slices, and journal-before-call wall reservation/preparation/settlement. WSL success returns its lease inseparably; uncertain acquisition returns no authority. The Colima live adapter is implemented; other provider CAS/adapters and command integration remain downstream. |
| `HostBootstrap.Cluster.Lifecycle` | kind/nvkind/Helm cluster up/down/delete semantics and the never-delete-`.data` invariant, invoked as the deploy-kind / deploy-chart step kinds. It owns driver-specific config/node topology, the all-node cordon, the NVIDIA runtime smoke, pinned device-plugin `0.19.3`, and the allocatable-GPU gate for `NvkindDriver`. See [cluster_lifecycle](../engineering/cluster_lifecycle.md). |
| `HostBootstrap.Lift.Context` | Implemented public boundary owned by the [Dhall-configuration-and-generic-project-model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md): Incus/Lima/WSL2 target records, container/config delivery, an outermost-first context stack with canonical incremental constructors, same-root `canonicalHostMount`, and the three inner transport argv renderers. Its data constructors remain public for inspection and exact fixture construction. The module resolves no tool and performs no effect; the boundary and complete phase gate are closed. |
| `HostBootstrap.Lift` | The generic self-reference fold and effect dispatch is implemented over `Lift.Context`; the [ensure-reconcilers phase](../../DEVELOPMENT_PLAN/phase-8-ensure-reconcilers.md) has closed its effect-seam, adversarial quoting, robust import-guard coverage, and complete phase gate. Lift reexports the pure vocabulary, resolves only the outer host tool, streams child config, and imports no provider realization or Registry module. The exact Chain derives each frame boundary's context from `DerivedTopology` and hands off `pb project up` through this lower seam. Reachability/blob leaf helpers are later additive network/registry extensions rather than part of this generic contract. See [composition_methodology](composition_methodology.md). |
| `HostBootstrap.Substrate.Provider` | Implemented boundary with its native phase gate closed. `SubstrateProvider` is abstract and selected from a closed Incus/Lima/WSL2/Direct kind; narrow projections expose descriptive identity, Lift context, and pure plans without exposing construction or record update. Discovery executes provider-owned closed requests against raw outcomes, privately parses strict one-line reports, bounds retry, and mints a generative backend-indexed capability only from the exact opaque managed Running provider. `Provider.Reconcile` exposes opaque nominal managed provider/share authorities and exact prepared provision/ready/share/stop/delete calls. The Incus realization holds the four ownership clauses over VM/share mutation and bound guest execution. Direct is only a plan-local admission and identity share, with structured stop/delete/guest/alias refusals and no physical-host ownership. `Provider.Alias` consumes the matching managed provider/share authority, admits only retained guest `flock`, and owns crash-recoverable `prepared`/`managed`/`releasing` origin states plus identity-conditional release. The [host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md) carries both its static and its native Linux/x86_64 KVM/Incus closure evidence; the [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns demo call-site adoption. |
| `HostBootstrap.Incus` / `HostBootstrap.Lima` / `HostBootstrap.Wsl2` | Provider lifecycle probes and argv builders consume and reexport their target records and inner renderers from `Lift.Context`, leaving lifecycle-specific create/start/copy/stop/delete behavior in the provider modules. The [host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md) owns that boundary's closed gate, and the Apple Silicon and Windows acceptance phases own the native Lima and WSL2 confirmations. `Ensure.Wsl2` owns prerequisite diagnostics; `HostBootstrap.Wsl2` only compatibility-reexports those lower definitions. See [Incus](../engineering/incus.md), [Lima](../engineering/lima.md), and [WSL2](../engineering/wsl2.md). |
| `HostBootstrap.Registry` | Registry credential discovery/forwarding exists. The active [composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md) owns the registry-aware `liftSubcommandWithAuth` consumer here so Registry imports generic Lift and its quoting helper while Lift imports no Registry policy. The stronger scope/credential capability remains later lifecycle work. See [registry_credentials](../engineering/registry_credentials.md). |
| `HostBootstrap.Harness` | The standardized assertion engine. Its five-field existential `TestSuite` contains the safety precondition, assertion-environment opener, case matrix, per-case assertion, and post-reverse absence assertion—no bring-up or teardown callback. For each variant the command-owned `ConfigVariant` supplies an opaque lifecycle over one exact Harness plan; the engine runs forward, assertions, reverse, and the absence check in that order and reports lifecycle/cleanup failures separately. Terminal close requires the reverse action's settled-destroy `ProjectClosureEvidence`; callback success alone is not close authority. See [harness_workflow](harness_workflow.md). |
| `HostBootstrap.Harness.Lifecycle.Internal` | Constructor and eliminators for the opaque `HarnessLifecycle`. It lives in the private `harness-lifecycle-internal` Cabal component, which the main library and its own test suite may depend on but downstream packages cannot. Command constructs the runtime value from one exact Harness plan; engine tests use the same private component rather than exposing a public constructor. |
| `HostBootstrap.Command` | The **fixed** core command tree (`coreCommands`): `project init|up|down|destroy`, `test init|run`, `service init|schema|run`, `context`, and `check-code`. `project down|destroy` are two verb-indexed projections of the one plan: core Kind cleanup runs only when the current frame owns `deploy-kind`, every other node runs the reverse its own step declared, and per-node outcomes are structured with failures aggregated after every independent node has run. No per-project verbs. |
| `HostBootstrap.CLI` | Opaque identity-parametric `ProjectSpec cfg tcfg`, unfinished `ProjectSpecBuilder`, checked additive operations (step fragments rank-2 in one shared root/config scope), `finalizeProjectSpec`, and the two entrypoints. Finalization validates suite/case/artifact/input/service contributions; dispatch verifies and retains the executable identity before selecting codecs or commands, and per-config plan projection validates the exact non-empty `StepPlan` before interpretation. One restricted identity-polymorphic `psAssemble` supplies Production/Harness configs and `psTestInit` supplies `tcfg`. |
| `HostBootstrap.DocValidator` | The mechanical documentation validator run through the code-check. See [documentation_standards](../documentation_standards.md). |

## Host-Tool Resolution And Substrate Ownership

External tools are resolved through the closed `HostTool` enumeration (`HostBootstrap.HostTool`) to
absolute paths. The `AbsExe` newtype makes a bare command name unrepresentable as a resolved tool — its
smart constructor rejects any non-absolute path, the canonical instance of the method described in
[unrepresentable_state](unrepresentable_state.md). Most managed paths use this representation, but
repository-wide migration is not complete: residual bare-command call sites remain open in the
[host-tools-and-substrate-detection phase](../../DEVELOPMENT_PLAN/phase-3-host-tools-and-substrate-detection.md).
The target is that no library or project code invokes a `$PATH`-resolved bare host command (see
[development_plan_standards § K](../../DEVELOPMENT_PLAN/development_plan_standards.md)).
`HostBootstrap.HostConfig` is the typed configuration that pairs the detected substrate with the
resolved tool paths the reconcilers read.

Resolution is only one of the two axes. § K fixes *which* executable an invocation names; the *shape* of
the invocation — stdio disposition, descriptor inheritance, session, environment, and working directory
— is a separate boundary under
[§ HH](../../DEVELOPMENT_PLAN/development_plan_standards.md), owned by `HostBootstrap.Detached`. A child
that outlives its launcher is where the two axes come apart, and it is the case the boundary is built
for: no module outside it assembles a `CreateProcess` for such a child, the disposition is not a
parameter, and `withDetachedChild` owns the launch rather than the child's lifetime. See
[unrepresentable_state](unrepresentable_state.md) for the method and the boundary's own gate.

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
  action body only announces, though for the container boundary it is the node that declares the descent
  carrying the payload, while the VM projection stays inside the composite bootstrap action;
- `deploy-kind` / `deploy-chart` — cluster and Helm-release lifecycle leaves;
- `expose-port` — expose an in-cluster `NodePort` to the host.

A project contributes its **own** step kinds (for the demo: `deploy-minio`, `deploy-registry`,
`push-image`, and accelerator-daemon placement) into the same ordered plan. Host steps and workload steps
interleave freely; `addSteps` appends checked contributions before finalization. This is the
workload-extension seam.

A project's authored forward graph is an opaque `StepPlan`. Its source fragments are pure functions of
project parameters. Optional structural variation (for example, skip the VM frame and go straight to
Docker) is a flag in the root `<project>.dhall`. `mkStepPlan` rejects empty/duplicate/conflicting plans,
non-contiguous frame returns, post-handoff suffixes outside deepest-to-root unwind order, and any frame that does not declare
exactly one descent, while preserving every accepted source order exactly. Raw `Step`, identity, and plan
constructors are hidden.

Trusted admission binds that validated graph to the exact scope, specification, canonical root,
configuration, and fresh `planId`. The public `ProjectPlan` is therefore the executable representation:
its `forward` projection is a `NonEmpty (PlannedStep ...)`, and its `DerivedTopology` is the matching frame
graph. `renderChain` renders the complete admitted `forward` order. The effectful `runChainFromFrame`
accepts no raw `StepPlan`, frame name, or second topology; its `CommandAuthority` and `LifecycleCursor`
share the exact plan, frame, broker generation, `VerbUp`, and `ExecutePhase` indices. It checks their
retained frame/verb/phase terms, the supplied store, and the cursor's retained acquisition
project/store/broker origin against the authority. It then selects the current frame's non-empty nodes and
uses the authority's broker epoch and invocation identity for the operation session. Every node descriptor,
prepared call, and carried resource remains under the same plan indices. The backend-facing
`StepObservation` is plan-independent; `runPlannedStep` immediately wraps it as nominal
`PlannedStepObservation scope planId configId`, and Chain uses only that plan/config-indexed value for
success, detail, and terminal settlement.
Every protected entry rereads the exact acquisition source and current cursor row while holding that
entry, so advancing the retained Execute row to Teardown makes later Chain transitions refuse.

The exact Chain is the **current-frame substrate** of the target recursive/fractal interpreter. It asks
`DerivedTopology` whether a descent follows the authorized current-frame segment, but current Production
accepts only the topology root and fails closed at nested entry rather than handing off through
`HostBootstrap.Lift`. The recursive-lifecycle-command phase supplies authenticated recursive child
authorization and proof-complete traversal above this substrate; see
[the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md).
Current convergence after a partial failure is best-effort because effects lack complete durable
identity-bound journals; the remaining preparation and operation-lifecycle work is owned by
[the prepared-operations phase](../../DEVELOPMENT_PLAN/phase-11-prepared-operations.md) and
[the cluster-lifecycle-and-cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md).
Every descent is the same fractal pattern
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
  -> (forall projectId scope. AssemblyRequest projectId tcfg (TestVariant tcfg) scope
        -> ConfigAssembly scope (cfg scope))
  -> ProjectSpecBuilder cfg tcfg
addSteps
  :: (forall scope rootId. CanonicalProjectRoot scope rootId -> cfg scope -> [Step])
  -> ProjectSpecBuilder cfg tcfg
  -> ProjectSpecBuilder cfg tcfg
addAssemblyInputs
  :: [ConfigInput]
  -> ProjectSpecBuilder cfg tcfg
  -> ProjectSpecBuilder cfg tcfg
finalizeProjectSpec
  :: ProjectSpecBuilder cfg tcfg
  -> Either ProjectSpecError (ProjectSpec cfg tcfg)
runHostBootstrapCLI :: String -> ProjectSpec cfg tcfg -> IO ()
runBareHostBootstrapCLI :: String -> IO ()
```

`TestCfg tcfg` supplies the pure project-owned projection from the executable `[CaseId]` registry and
decoded `tcfg` into an opaque validated `TestMatrix (TestVariant tcfg)`. The config callback therefore
assembles one already-validated draft; it cannot return an empty list or invent/duplicate raw labels.

- `progName` is the project/config name used in help and diagnostics. Before dispatch it must equal the
  normalized actual executable basename (with a Windows `.exe` removed), or the process exits before
  config/lifecycle work. The admitted rank-2 `InstalledProjectIdentity projectId` is then retained through
  Production codec/service/assembler/command construction and every Harness run; the static spec cannot
  choose `projectId`.
- `projectSpec` starts the unfinished builder from the `TestSuite`, project `check-code` action,
  `ConfigArtifact` delta, and project-owned
  init/test-config builders. `addSteps`, `addArtifacts`, `addAssemblyInputs`, and `addServices` append
  without erasure, and an `addSteps` fragment receives the admitted canonical-root authority so its
  steps — including the descent each frame declares with `Step.descendsVia` — derive project-relative
  paths from it, and each acquiring step declares the effect that releases it with `Step.reversedBy`.
  Service definitions inseparably bind identity, typed
  projection, role codec, and handler; no separate selector exists.
  The bare core binary uses a separate
  entrypoint (`runBareHostBootstrapCLI`).
- `finalizeProjectSpec` validates the static contributions. Per-config plan projection validates exact
  non-empty topology and typed identities before an interpreter is returned. `runHostBootstrapCLI`
  accepts only that opaque finalized value, applies executable-name validation, merges it with the core
  command tree, and runs the parser. The interpreter loads the sibling
  `<project>.dhall` before acting in a frame and refuses observed mismatches between the process and the
  descriptive frame declared by the config. The lower opaque identity/store/root/reservation vocabulary is
  implemented; the plan/lease/frame/cursor/context-complete gates that consume it remain lifecycle-command
  work.

A project binary contributes a chain value plus extension streams, never its own verbs. Its `Main.hs`
attaches the chain (interleaving core and project step kinds) to the spec and hands it to the entrypoint:

```haskell
import HostBootstrap.CLI
  ( addServices, addSteps, finalizeProjectSpec, projectSpec
  , runHostBootstrapCLI )
import HostBootstrap.Substrate (detect)
import HostBootstrapDemo.Commands (demoArtifacts, demoChainFor, demoCheckCode, demoServices, demoTestSuite)
import HostBootstrapDemo.Config (demoAssemble, demoTestInit, testConfigCodec)
import System.Exit (die)

main :: IO ()
main = do
  -- Detect the host substrate once so the chain's declared metal→VM descent folds
  -- to the right provider shell (Incus on Linux CPU, Lima on Apple Silicon).
  -- Linux GPU has no VM frame; its direct handoff is a GPU-enabled container lift.
  substrate <- detect >>= either die pure
  spec <- either (die . show) pure
    ( finalizeProjectSpec
        ( addServices demoServices
            ( addSteps (demoChainFor substrate)
                        (projectSpec demoTestSuite demoCheckCode demoArtifacts testConfigCodec demoTestInit demoAssemble)
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
| `project init` | Config-free initializer. Its no-flag default writes the root host-orchestrator config; the shared `InitArgs` parser also accepts role additions, an output path, `--force`/`--if-missing`, and resource/deploy overrides interpreted by `psAssemble (ProductionAssembly args)`. Role additions are checked by `roleAdditionAllowed`/`addRole`; `--force` takes precedence when both write-policy flags are present. |
| `project up` | Resolve and interpret the exact current frame. The public Chain boundary consumes one exact `ProjectPlan`, matching Execute authority/cursor evidence, and the plan's `DerivedTopology`; its `renderChain` renders that plan's complete `forward` projection. Production dispatch, including `--dry-run`, retains or reconstructs that exact plan through rendering or through snapshot/journal/cursor/authorization/Chain execution. Nested entry fails closed. The authenticated-handoff phase supplies the child-plan authority substrate, but the recursive-lifecycle-command phase still owns child journal/cursor admission and recursive Production continuation. Most reconcilers still return `IO ()`, so typed idempotence is open. |
| `project down` | Retain or reconstruct one exact Production plan and drive its `StopFrame` current-frame reverse projection, preserving durable roots/provider frames and deleting an owned Kind cluster because Kind has no stopped state. The pure projection is not exact command authority; nested entry refuses pending [the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md). See [durable_state](durable_state.md). |
| `project destroy` | Retain or reconstruct one exact Production plan and drive its `DeleteFrame` current-frame reverse projection. It does not yet provide authenticated child-to-parent interpretation, exact teardown authorization, or complete receipt-bound ownership. Host `.data` is carried outside provider disks. The Harness `durable-readback` case remains red until the engine can perform a nonterminal destroy followed by a fresh same-run exact `up`; that is not implemented by exposing lifecycle IO to the assertion. |
| `test init` | Needs **no** pre-existing `<project>.dhall`; writes `<project>.test.dhall`. In the demo it contains resource overrides plus declarative variant names/messages; compiled Haskell still owns case bodies and lifecycle-free assertions. |
| `test run <case-id>\|all` | Needs `<project>.test.dhall`; `all` runs the compiled matrix and a case id selects one compiled case. Help describes the surface as root-only, but the parser does not currently enforce a context root gate. Each variant is assembled as `cfg (Harness projectId runId)` under fresh authority and its matching codec, owns its generated sibling config, admits one exact Harness `ProjectPlan`, interprets that plan forward, runs assertion-only cases, and interprets its reverse projection directly. Settled destroy evidence is required before terminal Harness close. The configured `durable-readback` case deliberately fails until an engine-owned same-run lifecycle-invocation generation can place its write/read assertions around a nonterminal destroy→up cycle. |
| `service init\|schema\|run` | Run a long-running role. `schema` prints the full schema plus distinct Production/Harness role-wire families (including structured empty families). `run` checks a service leaf, canonically verifies one sibling snapshot, structurally selects exactly one typed registry definition, mints an opaque request under the finalized digest, and invokes a handler closed over only its role fields plus safe framework view. The full config is not reloaded or passed to the handler. The [service-runtime phase](../../DEVELOPMENT_PLAN/phase-22-service-runtime.md) owns effect-indexed one-use handler execution. No `service down`. |
| `check-code` | Runs the project's fail-fast code-check action. |

`project up` and `test run` consume the same plan/step representation, not a separate Harness selector.
Production executes its exact current-frame Chain and refuses nested entry; Harness retains its separately
scoped exact plan and directly wraps the common current-frame forward/reverse interpretation around
assertions rather than shelling `project up`. The lifecycle package constructor is private, so assertions cannot
replace either action or turn a descriptive config into lifecycle authority.
`project up` interprets the plan to stand up the persistent deploy stack and ends at a live webservice
(`service run`) on `localhost:30080`; its typed request already
contains the assembled `message`, so the handler does not reopen config. `test run all` directly runs the
corresponding Harness-scoped current-frame forward plan once per config variant (the demo runs
two), asserts the live stack (the SPA `#message` polymorphic over the active `EXPECTED_MESSAGE`), using
the exact Harness profile. Lifecycle resources do not yet all return ownership receipts, and the
same-run durable destroy/up/readback cycle remains open; see [harness workflow](harness_workflow.md).

## Consumption

The in-repository demo consumes `hostbootstrap-core` as a sibling local package. A remote consumer uses
a `source-repository-package` and must supply a full immutable commit in its `tag` field; the governed
template in [derived project standards](../engineering/derived_project_standards.md) makes that pin
explicit. The rolling base image warms a best-effort Cabal store; matching artifacts are reused
opportunistically and ordinary cache misses may resolve/download/build compatible dependencies.
See [base_image](../engineering/base_image.md) and [warm_store](../engineering/warm_store.md).
