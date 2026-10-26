# Documents

**Status**: Supporting reference
**Supersedes**: prior YAML-front-matter `documents-index`
**Referenced by**: [../README.md](../README.md), [documentation_standards.md](documentation_standards.md)

> **Purpose**: Index the governed `documents/` suite for `hostbootstrap` — the Haskell
> `hostbootstrap-core` library plus the thin Python bootstrapper — under the canonical categories.

`documents/` is the only canonical documentation root for `hostbootstrap`. The repository
[`README.md`](../README.md) is a governed orientation layer; the canonical design and engineering
material lives here. Conventions are defined in
[documentation_standards.md](documentation_standards.md).

The model is **one admitted project plan interpreted recursively**. A project binary finalizes additive
step fragments into an opaque plan. Its root coordinator owns durable state, authenticates storeless child
executors, and settles their returned observations; reverse traversal visits children before parents.
[Composition methodology](architecture/composition_methodology.md) is the canonical home of this model.
The command surface is summarized in [Command Surface](#command-surface).

## Architecture

- [architecture/hostbootstrap_core_library.md](architecture/hostbootstrap_core_library.md) — the
  `hostbootstrap-core` Haskell library: module surface, the opaque `Step`/`StepPlan` algebra a project
  extends, its validation boundary, and the
  `project`/`test`/`service`/`context`/`check-code` command tree project binaries build on.
- [architecture/composition_methodology.md](architecture/composition_methodology.md) — the **canonical
  home of the composition model**: the opaque `StepPlan` forward ordering, exact current-frame Chain,
  the authenticated recursive interpreter of the self-reference lift across
  `Local | InVM | InContainer`, and the opaque project plan deriving forward order, topology, and reverse
  traversal together,
  fractal bootstrap (the Python bootstrapper is the metal-frame instance of provision → build-pb →
  handoff), and the deploy ≡ business-logic unification (one algebra for deployment and runtime business
  logic).
- [architecture/generic_project_model.md](architecture/generic_project_model.md) — the generic project
  model (§ BB): `hostbootstrap-core` owns no hardcoded defaults and is
  parameterized over a project's scope-indexed config family
  (`ProjectSpec cfg tcfg`). One identity-polymorphic restricted `psAssemble` is the structural default source for
  Production init and per-variant Harness generation; `psTestInit` separately builds `tcfg`. The harness
  generates the run's `<project>.dhall` from a thin `<project>.test.dhall` override. `SecretRef scope`
  supports secrets-strict configs, requires exact Harness config authority for plaintext, and exposes
  no plaintext alternative in the Production schema.
- [architecture/binary_context_config.md](architecture/binary_context_config.md) — the "know your
  place" binary-context contract: a sibling `<project>.dhall` is parameters + context + witness, the
  read-only `context` command introspects and visualizes the frame, the complete descriptive topology and
  exact-witness checks, the implemented lower installed/store/root/reservation authority boundary, and the
  proof-complete command gates that prevent callers from widening their own capabilities.
- [architecture/python_haskell_boundary.md](architecture/python_haskell_boundary.md) — what the
  thin Python bootstrapper owns versus `hostbootstrap-core`: Python owns only the work that must happen
  before a project binary exists, the host-statement seam it hands the binary, and nothing after it.
- [architecture/build_and_run_model.md](architecture/build_and_run_model.md) — the host-native
  build/run model, the headless host-build pattern (CUDA-on-Windows), `./.build/`, and why the binary
  (not the bootstrapper) builds the project container.
- [architecture/library_hierarchy.md](architecture/library_hierarchy.md) — the three additive Cabal
  library levels (L0◄L1◄L2) and the extension streams every level composes additively (lift chain, Dhall
  vocabulary, schema-gen, test seams, service handlers), over a fixed command surface that is never a stream.
- [architecture/dhall_generation.md](architecture/dhall_generation.md) — `.dhall` as parameters +
  context + witness, the current child projections produced by the composite bootstrap and by the
  descent the demo's `context-init` node declares (that node's action body is only an
  announcement), the generated Dhall
  vocabulary, the three-vocabulary layering, and the validated-codec schema surface.
- [architecture/run_models.md](architecture/run_models.md) — the four execution-shape names
  (`OneShot`, `HostNative`, `HostDaemon`, `Cluster`) as consequences of the one exact project plan, with no
  parallel execution selector or Dhall representation.
- [architecture/harness_workflow.md](architecture/harness_workflow.md) — the per-case `runMatrix` loop,
  compiled-case/config-variant split, exact Harness-plan lifecycle, assertion-only `TestSuite`, generated
  config and run ownership, and the engine-owned same-run recreate assertion protocol.
- [architecture/durable_state.md](architecture/durable_state.md) — the **canonical home of the
  durable-state contract**: one canonical host-root authority, typed substrate projections,
  provider-local guest aliases, direct-host canonical-path bypass, the clause-holding guest-alias backend
  and its prepared demo consumer, plus the destroy/up/readback proof.
- [architecture/ownership_invariant.md](architecture/ownership_invariant.md) — the **canonical home of
  the ownership invariant**: the four Locked-Origin Identity Ownership clauses (exclusive entry, durable
  origin record, identity binding, conditional release) and the exact guarantee they do and do not
  provide. Replaces the platform-primitive rule that no substrate could satisfy.
- [architecture/ownership_seam.md](architecture/ownership_seam.md) — the **canonical home of the
  ownership realization**: the one transaction those clauses compose, the closed seam of kernel
  primitives beneath it, the POSIX and Windows rows, the row that runs a transaction at the frame owning
  the object, the atomic no-replace publication, and what each individual owner adds on top.
- [architecture/readiness.md](architecture/readiness.md) — opaque resource-indexed witnesses, validated
  polling, the implemented closed raw provider-discovery boundary, and the plan-owned prepared adapters that consume them.
- [architecture/lifecycle_state_model.md](architecture/lifecycle_state_model.md) — the canonical contract
  for ownership-/phase-indexed handles, opaque resource capabilities, total observations, explicit
  idempotent reconcile outcomes, one-use session/fence permits, project-mode exclusion, exhaustive
  migration/close recovery, verified ownership receipts, recursive teardown, and their validation gates.
- [architecture/network_reachability.md](architecture/network_reachability.md) — the canonical contract
  for scope-indexed endpoints and clients, runtime-owned automatic loopback exposure, authenticated resolved
  endpoint carriage, proof-gated registry blob delivery, opaque finalized registry plans, and route-specific
  readiness that makes an external client redirect to a cluster-only object store unrepresentable.
- [architecture/unrepresentable_state.md](architecture/unrepresentable_state.md) — the **canonical home
  of the method** every boundary above applies: private constructors with validating producers, rank-2
  scope containment, closed sums with total eliminators, and phantom indices — plus the compile-fail
  proof obligation that separates a boundary from a comment, why a test asserting an unsealed field can
  pin a defect as the contract, and exactly what the technique does not buy.

## Engineering

- [engineering/schema.md](engineering/schema.md) — the project-local `<project>.dhall` schema that
  every project binary reads beside itself.
- [engineering/secrets.md](engineering/secrets.md) — the implemented `SecretRef` vocabulary and the
  `test-secrets` seam through which a secrets-strict consumer injects test values (§ BB and the
  [test-harness-and-run-ownership phase](../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md));
  plaintext requires exact Harness authority and is absent from the Production schema; core never resolves secrets.
- [engineering/dhall_topology.md](engineering/dhall_topology.md) — the three-tier Dhall model, the
  topology frames that drive the recursive chain (each pb verifies its frame), and the rule that rich
  schemas are binary-generated artifacts.
- [engineering/config_generation.md](engineering/config_generation.md) — the `ConfigArtifact`
  registry, validated codec schemas and round-trip evidence,
  and the plan-owned projection and authenticated delivery of child `.dhall`; schema/render
  introspection folds under the read-only `context` command.
- [engineering/composition_patterns.md](engineering/composition_patterns.md) — a cookbook of composition
  shapes (the step plan and its recursive interpreter, context topologies, operation kinds,
  business-logic shapes) consumers compose their plan from.
- [engineering/accelerator_daemon.md](engineering/accelerator_daemon.md) — the active demo
  generalization where the project binary also runs as a substrate-specific accelerator daemon, JIT-builds
  a real Swift/Metal, CUDA, or C++ worker, exchanges CBOR over WebSocket with the web service, and is
  validated by integration and browser e2e tests; the runtime and real-worker integration are implemented,
  with live substrate evidence recorded in the owning acceptance phases.
- [engineering/authoring_project_binaries.md](engineering/authoring_project_binaries.md) — the
  step-by-step guide to authoring a project binary on `hostbootstrap-core`: contributing additive
  step fragments plus actions, test suite, Dhall vocabulary, and budget.
- [engineering/ensure_reconcilers.md](engineering/ensure_reconcilers.md) — the `ensure` reconciler
  contract; reconcilers are library primitives. Core exposes `ensureStep`, while the current demo calls
  `runEnsure` from larger provider/build actions rather than registering independent `ensure-*` rows.
- [engineering/resource_budgeting.md](engineering/resource_budgeting.md) — the resource budget,
  decode-time scalar checks, the current capacity/cordon checks, the plan-indexed complete workload-fit
  gate, and the limits of current substrate enforcement.
- [engineering/applied_cordon.md](engineering/applied_cordon.md) — budget-as-ceiling enforcement: the
  one canonical parser, the implemented typed scalar/capacity boundaries, the topology-derived
  workload fit, and the explicit bare-Linux unsupported-storage policy.
- [engineering/incus.md](engineering/incus.md) — the opaque provider descriptor's Incus path, its
  prepared four-clause VM/share backend, closed raw discovery, VM/share/exec lifecycle, and sizing limits;
  its static gate and native Linux/x86_64 KVM/Incus gate are closed.
- [engineering/lima.md](engineering/lima.md) — the Lima VM provider used by the worked demo on Apple
  Silicon for a real pristine Linux VM, with the same deploy/stop/destroy VM lifecycle steps.
- [engineering/wsl2.md](engineering/wsl2.md) — the Windows WSL2 host-provider VM, the peer of
  Lima (Apple Silicon) and Incus (native Linux): `ensure wsl2` prepares WSL2 platform readiness, then the
  project chain registers its own named `Ubuntu-24.04` distro and the same `deploy-vm` / `project down`
  (stop-without-delete) / `project destroy` lifecycle steps drive it; includes the WSL2 cordon — the
  global `.wslconfig` CPU/memory wall on the shared utility VM — and why the per-distro VHDX storage cap
  is a separate limit.
- [engineering/durable_windows_runs.md](engineering/durable_windows_runs.md) — why the long demo gate must
  be detached from the Codex/Claude process tree on Windows, the durable launcher and exit-sentinel
  protocol, and why macOS/Linux runs remain ordinary foreground commands.
- [engineering/cluster_lifecycle.md](engineering/cluster_lifecycle.md) — Kind/Helm bring-up, runtime-owned
  exposure, recovery, and teardown as chain steps under `project up`/`project down`/`project destroy`;
  `project down` deletes owned relays and Kind clusters while preserving durable state.
- [engineering/base_image.md](engineering/base_image.md) — rolling base selection, contents, native
  architecture, and publication boundary.
- [engineering/build_release.md](engineering/build_release.md) — base-image build and publish
  semantics.
- [engineering/prerequisites.md](engineering/prerequisites.md) — the Python fail-fast host minimums.
- [engineering/self_update.md](engineering/self_update.md) — the explicit pipx self-update doctrine
  for the Python bootstrapper and the no-hidden-latest-gate rule.
- [engineering/registry_credentials.md](engineering/registry_credentials.md) — forwarding the host's
  Docker Hub login down the lift to authenticate nested pulls, with the credential excluded from Dhall,
  intended durable project/image state, and `argv` while process-memory, environment, inspection, and
  interrupted-cleanup risks remain explicit.
- [engineering/testing.md](engineering/testing.md) — the four gate kinds (the host static gate,
  the `linux-cpu` substrate gate, the container `check-code` gate, and the live demo gate) and what each
  proves, harness portability, what counts
  as evidence, the supported fast-suite entry points, the demo's `test init` / `test run <case-id>|all`
  surface over compiled cases and one exact Harness-scoped plan per variant, the current safety
  boundaries, and the live gate contract.
- [engineering/in_cluster_registry.md](engineering/in_cluster_registry.md) — the in-cluster registry a downstream project pushes to.
- [engineering/derived_project_standards.md](engineering/derived_project_standards.md) — the rules
  every derived project follows, including the extension-stream contract whose stream 1 is the lift chain.
- [engineering/derived_dockerfile.md](engineering/derived_dockerfile.md) — the idiomatic derived
  project container: the in-Dockerfile `check-code` gate, the `purescript-bridge` → `spago` →
  `esbuild` web build, and the build-stage ordering.
- [engineering/cabal_layout.md](engineering/cabal_layout.md) — the `hostbootstrap-core` Cabal
  package layout, supported compiler selection, and dependency surface.
- [engineering/warm_store.md](engineering/warm_store.md) — the opportunistic Cabal store and
  one-project consumer contract.
- [engineering/code_check_doctrine.md](engineering/code_check_doctrine.md) — the canonical
  code-check gate for every image, plus the base image's narrower current preflight.
- [engineering/linking_and_optimization.md](engineering/linking_and_optimization.md) — static
  linking and optimization policy.
- [engineering/gitignore_guardrails.md](engineering/gitignore_guardrails.md) — what stays out of
  version control.

## Operations

- [operations/demo_runbook.md](operations/demo_runbook.md) — the `hostbootstrap-demo` runbook: the
  `project up` / `project down` / `project destroy` lifecycle plus `test run all` and `context`
  visualization, the durable alias path and purpose, the compiled harness-case table, and current
  operator-safety limitations.

## Glossary

Three terms are load-bearing across the corpus and mean narrower things than their ordinary English
reading. This section is their one canonical home; a page using one of them in a narrower sense says
which sense it means.

**Substrate.** Three related vocabularies share the word, and they are not the same set.

| Vocabulary | Where it lives | Members |
|---|---|---|
| the detected outer host | `SubstrateName` in [`HostBootstrap.Substrate`](../core/hostbootstrap-core/src/HostBootstrap/Substrate.hs) | `AppleSilicon`, `LinuxCpu`, `LinuxGpu`, `WindowsCpu`, `WindowsGpu`, each paired with an `Arch` |
| the plan's hardware-context declaration | the `**Substrates**:` phase-header field ([§ II](../DEVELOPMENT_PLAN/development_plan_standards.md)) | `linux-cpu`, plus at most one of `apple-silicon`, `nvidia`, `windows` |
| the universal baseline | this corpus and the plan | `linux-cpu` alone |

The header field is a **hardware-context declaration**, not the code enumeration: `nvidia` and `windows`
are context names that no `SubstrateName` constructor spells, and a phase declaring `windows` is naming
the context it accepts rather than a detected outer host. `linux-cpu` is the one token all three
vocabularies share, and it is the baseline every phase targets. A behaviour that differs by outer host
does not route on the five detected tags; it routes on the three host frames they collapse to (the
host-frame sense of **Frame** below).

**Frame.** The word has three senses. The first is the default; a page that means another says which.

| Sense | What a frame is | Where it lives |
|---|---|---|
| **topology** (the default) | one process's place in the composed topology. The closed *kind* of place is `ContextKind`, with eight constructors — `HostOrchestrator`, `VMOrchestrator`, `VMProjectContainer`, `ImageBuildContainer`, `ClusterService`, `Daemon`, `OneShotJob`, `TestHarness`; one node of the descriptive topology is a `TopologyFrame`; one node of an admitted plan is a `ProjectFrame`, an *identity* carried as opaque text | [`HostBootstrap.Context`](../core/hostbootstrap-core/src/HostBootstrap/Context.hs), [`HostBootstrap.ProjectPlan.Frame`](../core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Frame.hs) |
| **host frame** (the host-frame axis) | the outer-host family a behaviour is written once per. `HostFrame` has three constructors — `LinuxFrame`, `AppleFrame`, `WindowsFrame` — and `substrateFrame` is the one place the five `SubstrateName` tags collapse to them: `LinuxCpu` and `LinuxGpu` are both `LinuxFrame`, `WindowsCpu` and `WindowsGpu` both `WindowsFrame`, because an accelerator is a capability *of* a frame rather than a frame of its own. `isLinux`, `isWindows` and `isAppleSilicon` are derived from it | [`HostBootstrap.Substrate`](../core/hostbootstrap-core/src/HostBootstrap/Substrate.hs) |
| **frame table** (a provider's frame) | a way to reach a context (the machine a `LiftContext` addresses, whose kernel answers for the objects there) plus the closed table of facts that context differs by: the host tool and its argument shape, the path grammar, the sizing renderer, the ownership-primitive row, and the file-transfer and share primitives. A provider adds a *row* to this table, never a copy of a workflow. "The frame that interprets a path" is this sense: a host path is read by the current machine's own grammar, a guest path by the POSIX grammar of the frame it is handed to | [§ LL](../DEVELOPMENT_PLAN/development_plan_standards.md#ll-the-frame-table-the-substrate-axis-is-a-lift-not-a-fork) and [§ MM](../DEVELOPMENT_PLAN/development_plan_standards.md#mm-a-path-belongs-to-the-frame-that-interprets-it) |

In a plan or lifecycle context, an unqualified "frame" means the `ProjectFrame` identity rather than the
`ContextKind` kind; where a page means the kind, it names a constructor. A page that routes on the outer
host says "host frame", and a page about a provider's reach, paths, sizing or ownership row says "frame
table" or "the frame that interprets" it.

A **crossing** (a "frame crossing") is one step of the lift from a frame-table frame into the next: the
near side derives the argument vector that launches this same binary in the target frame from the lift's
own fold (`foldLeaf`) and nowhere else, and the two sides then speak only over the authenticated handoff
channel. The lifecycle-child and frame-child entries in
[Entries before the parser](architecture/hostbootstrap_core_library.md#entries-before-the-parser) are the
far side of a crossing.

**Cordon.** In `hostbootstrap` a cordon **applies the plan's resource wall** at the boundary the
realization supports: the declared sizing of a provider VM (Incus, Lima, a direct Colima profile, or the
global CPU/memory wall on the shared WSL2 utility VM) and the CPU and memory ceiling of each bound
cluster-node container, both rendered from the one admitted budget. A storage cap that the realization
does not enforce is reported as unsupported rather than called a cordon; the per-substrate table is in
[resource budgeting](engineering/resource_budgeting.md#cordoning-per-substrate). A cordon never marks a
node unschedulable. This is the opposite of the Kubernetes term: `kubectl cordon` makes a node refuse new
pods and changes no resource limit. A reader who knows Kubernetes will otherwise read every cordon
sentence in [cluster lifecycle](engineering/cluster_lifecycle.md) backwards.

## Command Surface

The fixed core command surface is exactly five user-facing verbs: `project`, `test`, `service`, `context`,
and `check-code`. `ensure` is a reconciler library, not a command, and a project adds no verb. The
canonical statement is [architecture/hostbootstrap_core_library.md](architecture/hostbootstrap_core_library.md).
It includes the five core entries `runCLI` tests before the parser runs (installed identity, exposure
relay, Colima command transaction, lifecycle child, frame child), none of which is in the command tree,
and which of them stay within the bounds of an internal marker; that list is
[Entries before the parser](architecture/hostbootstrap_core_library.md#entries-before-the-parser).
`project up` recursively interprets one opaque validated plan. The root owns all durable lifecycle state
and launches each declared child through the fixed authenticated lifecycle-child entry; the child executes
only root-selected grants. `project down` and `project destroy` traverse the same plan child-first using
their distinct reverse policies. Cluster removal excludes durable host `.data`; the persistence contract
and acceptance evidence are linked from [architecture/durable_state.md](architecture/durable_state.md) and
[architecture/lifecycle_state_model.md](architecture/lifecycle_state_model.md).

- **The chain is the current forward representation.** Cluster bring-up runs through `deploy-kind`,
  `deploy-object-store`, `deploy-registry`, `push-image`, `deploy-chart`, and runtime-owned exposure; the
  substrate-specific accelerator daemon then runs in-cluster or on the host. In the current demo,
  `context-init`'s action body is a no-op announcement; VM projection/delivery happens inside the
  composite `build-pb` action and container projection/delivery happens through the descent that
  `context-init` step declares plus the handoff.
  Reconcilers are invoked from larger provider/build actions rather than independent `ensure-*` rows.
  Production retains or reconstructs one opaque validated
  `ProjectPlan scope specDigest planId configId cfg`; its topology, current-frame forward execution, and
  verb-indexed reverse projection retain the same lifecycle scope and derive from the same steps.
  Authenticated child observations and root-owned receipts settle recursive reverse traversal.
- **`context` is read-only introspection.** Its `inspect`/`path`/`show`/`schema`/`render` subcommands
  introspect and visualize the current frame, including schema and render output.
- **`test init` / `test run <case-id>|all`** drive the standardized harness over compiled Haskell cases
  and generated config variants. Each variant retains one exact Harness-scoped plan and its isolated
  `.test_data/<runId>` root through common recursive forward/reverse interpretation; restart-spanning cases
  cross a protected fresh invocation and exact plan rebind without receiving lifecycle authority; see
  [harness workflow](architecture/harness_workflow.md).
- **The demo contributes `Web` and `Accelerator` service variants** (run by `service run` in the chart pod; the build-time
  bridge folds into the build-image step). The command surface is fixed, so VM, Incus, web, and other
  provider work runs as chain steps rather than project-specific verbs.

See [composition_methodology.md](architecture/composition_methodology.md) for the model and
[`DEVELOPMENT_PLAN/`](../DEVELOPMENT_PLAN/) for the authoritative phase status.

## Languages

`languages/` is a documented extra category holding per-language toolchain guidance for what the base
image ships.

- [languages/haskell.md](languages/haskell.md)
- [languages/python.md](languages/python.md)
- [languages/node.md](languages/node.md)
- [languages/purescript.md](languages/purescript.md)
- [languages/playwright.md](languages/playwright.md)
- [languages/rust.md](languages/rust.md)
- [languages/cpp.md](languages/cpp.md)
- [languages/cuda.md](languages/cuda.md)
- [languages/go.md](languages/go.md)
- [languages/cluster_tooling.md](languages/cluster_tooling.md)
