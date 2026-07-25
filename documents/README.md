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

The model is **the lift chain is the project**. A project binary (`pb`)'s identity is its
`chain :: cfg -> [Step]` value; `project up` is a recursive interpreter that runs the current
frame's steps then hands `pb project up` to the next frame. The canonical home of this model is
[architecture/composition_methodology.md](architecture/composition_methodology.md); every other doc
defers to it rather than re-deriving it. The command surface is summarized in
[Command Surface](#command-surface).

## Architecture

- [architecture/hostbootstrap_core_library.md](architecture/hostbootstrap_core_library.md) — the
  `hostbootstrap-core` Haskell library: module surface, the `Step` algebra a project extends with its
  chain, the invalid shapes its current public constructors still permit, and the
  `project`/`test`/`service`/`context`/`check-code` command tree project binaries build on.
- [architecture/composition_methodology.md](architecture/composition_methodology.md) — the **canonical
  home of the composition model**: the current `[Step]` forward ordering, `project up` as the
  recursive/fractal interpreter of the self-reference lift across `Local | InVM | InContainer`, and the
  target opaque plan deriving forward order, topology, and reverse receipt-driven traversal together,
  fractal bootstrap (the Python bootstrapper is the metal-frame instance of provision → build-pb →
  handoff), and the deploy ≡ business-logic unification (one algebra for deployment and runtime business
  logic).
- [architecture/generic_project_model.md](architecture/generic_project_model.md) — the implemented
  generic project model (§ BB, phase 19): `hostbootstrap-core` owns no hardcoded defaults and is
  parameterized over a project's own config type (`ProjectSpec cfg tcfg`). Current `psInit`, `psTestInit`,
  and `psTestConfig` are independent callbacks; the demo shares `demoInitWithMessage` between `demoInit`
  and `demoTestConfig` by convention. The target `psAssemble` makes one scope-aware assembly path
  structural. The harness generates the run's `<project>.dhall` from a thin `<project>.test.dhall`
  override; a pure `SecretRef` vocabulary supports secrets-strict configs, while excluding its
  representable `TestPlaintext` constructor from production remains project code-check policy.
- [architecture/binary_context_config.md](architecture/binary_context_config.md) — the "know your
  place" binary-context contract: a sibling `<project>.dhall` is parameters + context + witness, the
  read-only `context` command introspects and visualizes the frame, the current descriptive mismatch
  checks, and the target opaque authority that prevents callers from widening their own capabilities.
- [architecture/python_haskell_boundary.md](architecture/python_haskell_boundary.md) — what the
  thin Python bootstrapper owns versus `hostbootstrap-core`, and the default-to-Haskell rule.
- [architecture/build_and_run_model.md](architecture/build_and_run_model.md) — the host-native
  build/run model, the headless host-build pattern (CUDA-on-Windows), `./.build/`, and why the binary
  (not the bootstrapper) builds the project container.
- [architecture/library_hierarchy.md](architecture/library_hierarchy.md) — the three additive Cabal
  library levels (L0◄L1◄L2) and the extension streams every level composes additively (lift chain, Dhall
  vocabulary, schema-gen, test seams, service handlers), over a fixed command surface that is never a stream.
- [architecture/dhall_generation.md](architecture/dhall_generation.md) — `.dhall` as parameters +
  context + witness, the current child projections produced by composite bootstrap/frame-context
  actions (the demo's named `context-init` action is only an announcer), the generated Dhall
  vocabulary, the three-vocabulary layering, and the encoder-declared schema surface.
- [architecture/run_models.md](architecture/run_models.md) — the four execution-shape names
  (`OneShot`, `HostNative`, `HostDaemon`, `Cluster`), the currently unwired selector and exported Dhall
  vocabulary, and the target removal of that parallel representation in favor of the concrete chain.
- [architecture/harness_workflow.md](architecture/harness_workflow.md) — the per-case `runMatrix` loop,
  the implemented compiled-case/resource-override split, the unenforced root-gate claim, the current
  Production-profile test defect, and the sealed harness-authority target.
- [architecture/durable_state.md](architecture/durable_state.md) — the **canonical home of the
  host `.data` carry**: provider shares, the stable `/var/tmp/hostbootstrap-demo-data` Docker-visible
  alias, the current partial direct-host probe, and the still-open destroy/up/readback proof.
- [architecture/readiness.md](architecture/readiness.md) — current retrying probes and the open defects
  that readiness can be forged through both the exposed constructor and caller-selected probes/tags,
  polling policies admit invalid values, witnesses are not resource-indexed, and mutation gating is not
  universal; plus the opaque-capability/total-observation target.
- [architecture/lifecycle_state_model.md](architecture/lifecycle_state_model.md) — the canonical target
  for ownership-/phase-indexed handles, opaque resource capabilities, total observations, explicit
  idempotent reconcile outcomes, one-use session/fence permits, project-mode exclusion, exhaustive
  migration/close recovery, verified ownership receipts, recursive teardown, and their validation gates.

## Engineering

- [engineering/schema.md](engineering/schema.md) — the project-local `<project>.dhall` schema that
  every project binary reads beside itself.
- [engineering/secrets.md](engineering/secrets.md) — the implemented `SecretRef` vocabulary and the
  `test-secrets` seam through which a secrets-strict consumer injects test values (§ BB, phase 19);
  `TestPlaintext` remains representable, production exclusion is currently project code-check policy,
  and core never resolves secrets.
- [engineering/dhall_topology.md](engineering/dhall_topology.md) — the three-tier Dhall model, the
  topology frames that drive the recursive chain (each pb verifies its frame), and the rule that rich
  schemas are binary-generated artifacts.
- [engineering/config_generation.md](engineering/config_generation.md) — the `ConfigArtifact`
  registry, the limits of its public arbitrary schema/render fields and sampled round-trip evidence,
  and the current/target ownership of child `.dhall` projection and delivery; schema/render
  introspection folds under the read-only `context` command.
- [engineering/composition_patterns.md](engineering/composition_patterns.md) — a cookbook of composition
  shapes (the `[Step]` chain and its recursive interpreter, context topologies, operation kinds,
  business-logic shapes) consumers compose their chain from.
- [engineering/accelerator_daemon.md](engineering/accelerator_daemon.md) — the active demo
  generalization where the project binary also runs as a substrate-specific accelerator daemon, JIT-builds
  a real Swift/Metal, CUDA, or C++ worker, exchanges CBOR over WebSocket with the web service, and is
  validated by integration and browser e2e tests; the runtime and real-worker integration are implemented,
  while the required live substrate matrix remains open.
- [engineering/authoring_project_binaries.md](engineering/authoring_project_binaries.md) — the
  step-by-step guide to authoring a project binary on `hostbootstrap-core`: contributing its
  `chain :: cfg -> [Step]` plus step actions, test suite, Dhall vocabulary, and budget.
- [engineering/ensure_reconcilers.md](engineering/ensure_reconcilers.md) — the `ensure` reconciler
  contract; reconcilers are library primitives. Core exposes `ensureStep`, while the current demo calls
  `runEnsure` from larger provider/build actions rather than registering independent `ensure-*` rows.
- [engineering/resource_budgeting.md](engineering/resource_budgeting.md) — the resource budget,
  decode-time scalar checks, the current capacity/cordon checks, the still-unwired complete workload-fit
  gate, and the limits of current substrate enforcement.
- [engineering/applied_cordon.md](engineering/applied_cordon.md) — budget-as-ceiling enforcement: the
  one canonical parser, the implemented typed scalar/capacity boundaries, the target topology-derived
  pod-set fit, and the open bare-Linux storage wall.
- [engineering/incus.md](engineering/incus.md) — the active `SubstrateProvider`/`LiftLayer` Incus path,
  VM/share/exec lifecycle, sizing behavior, and the stale uncalled `HostTarget` compatibility surface.
- [engineering/lima.md](engineering/lima.md) — the Lima VM provider used by the worked demo on Apple
  Silicon for a real pristine Linux VM, with the same deploy/stop/destroy VM lifecycle steps.
- [engineering/wsl2.md](engineering/wsl2.md) — the Windows WSL2 host-provider VM, the peer of
  Lima (Apple Silicon) and Incus (native Linux): `ensure wsl2` prepares WSL2 platform readiness, then the
  project chain registers its own named `Ubuntu-24.04` distro and the same `deploy-VM` / `project down`
  (stop-without-delete) / `project destroy` lifecycle steps drive it; includes the honest WSL2 resource
  cordon (the global `.wslconfig` ceiling vs. the per-distro VHDX cap).
- [engineering/durable_windows_runs.md](engineering/durable_windows_runs.md) — why the long demo gate must
  be detached from the Codex/Claude process tree on Windows, the durable launcher and exit-sentinel
  protocol, and why macOS/Linux runs remain ordinary foreground commands.
- [engineering/cluster_lifecycle.md](engineering/cluster_lifecycle.md) — kind/Helm bring-up and teardown
  as chain steps under `project up`/`project down`/`project destroy`; `project down` deletes kind clusters
  while preserving durable state.
- [engineering/base_image.md](engineering/base_image.md) — the base image contents.
- [engineering/build_release.md](engineering/build_release.md) — base-image build and publish
  semantics.
- [engineering/prerequisites.md](engineering/prerequisites.md) — the Python fail-fast host minimums.
- [engineering/self_update.md](engineering/self_update.md) — the explicit pipx self-update doctrine
  for the Python bootstrapper and the no-hidden-latest-gate rule.
- [engineering/registry_credentials.md](engineering/registry_credentials.md) — forwarding the host's
  Docker Hub login down the lift to authenticate nested pulls, with the credential excluded from Dhall,
  intended durable project/image state, and `argv` while process-memory, environment, inspection, and
  interrupted-cleanup risks remain explicit.
- [engineering/testing.md](engineering/testing.md) — the standardized `runMatrix` harness, the
  `test init` / `test run <case-id>|all` surface, compiled case ownership, unenforced root-gate claim,
  Production-profile demo defect, and supported fast-suite entry points.
- [engineering/in_cluster_registry.md](engineering/in_cluster_registry.md) — the in-cluster registry a downstream project pushes to.
- [engineering/derived_project_standards.md](engineering/derived_project_standards.md) — the rules
  every derived project follows, including the extension-stream contract whose stream 1 is the lift chain.
- [engineering/derived_dockerfile.md](engineering/derived_dockerfile.md) — the idiomatic derived
  project container: the in-Dockerfile `check-code` gate, the `purescript-bridge` → `spago` →
  `esbuild` web build, and the build-stage ordering.
- [engineering/cabal_layout.md](engineering/cabal_layout.md) — the `hostbootstrap-core` Cabal
  package layout, the GHC pin, and the dependency surface.
- [engineering/warm_store.md](engineering/warm_store.md) — the warm Cabal store contents and
  cache-hit contract.
- [engineering/code_check_doctrine.md](engineering/code_check_doctrine.md) — the target canonical
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

## Command Surface

The fixed core command surface is exactly five user-facing verbs: `project`, `test`, `service`, `context`,
and `check-code`. There are no hidden commands. `ensure` is a reconciler library, not a command.
`project up` recursively interprets the project's `chain :: cfg -> [Step]`: it runs the current frame and
hands `pb project up` to the next. Current `project down`/`destroy` do **not** mirror that recursive
dispatch; they clean the current frame's cluster where applicable and invoke a project hook, which may
stop or remove a provider. Child-to-parent lifecycle interpretation remains a target. Durable host
`.data` is excluded from cluster removal, but end-to-end persistence is unvalidated (see
[architecture/durable_state.md](architecture/durable_state.md) and
[architecture/lifecycle_state_model.md](architecture/lifecycle_state_model.md)).

- **The chain is the current forward representation.** Cluster bring-up runs through `deploy-kind`,
  `deploy-minio`, `deploy-registry`, `push-image`, `deploy-chart`, and port exposure; the
  substrate-specific accelerator daemon then runs in-cluster or on the host. In the current demo,
  `context-init` is a no-op announcing frame anchor; VM projection/delivery happens inside the composite
  `build-pb` action and container projection/delivery happens through `psFrameContext` and the handoff.
  Reconcilers are invoked from larger provider/build actions rather than independent `ensure-*` rows.
  Frame-context and teardown
  callbacks remain independently supplied and can drift; the target is one opaque validated
  `ProjectPlan scope specDigest planId configId cfg` whose topology and verb-indexed, receipt-driven reverse
  traversal retain the same lifecycle
  scope and are derived from the same steps.
- **`context` is read-only introspection.** Its `inspect`/`path`/`show`/`schema`/`render` subcommands
  introspect and visualize the current frame, including schema and render output.
- **`test init` / `test run <case-id>|all`** drive the standardized harness over compiled Haskell cases
  and generated config variants. The parser currently does not enforce the documented root gate, and the
  demo's live planner incorrectly selects Production/`.data`; see
  [harness workflow](architecture/harness_workflow.md).
- **The demo contributes its `Web` service variant** (run by `service run` in the chart pod; the build-time
  bridge folds into the build-image step); the former `vm` / `incus` / `web` verbs are removed (the surface
  is fixed) and their provider IO runs as chain steps.

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
