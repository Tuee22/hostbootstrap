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
  chain, and the `project`/`test`/`service`/`context`/`check-code` command tree project binaries build on.
- [architecture/composition_methodology.md](architecture/composition_methodology.md) — the **canonical
  home of the chain-is-the-project model**: the `[Step]` chain as the single representation, `project up`
  as the recursive/fractal interpreter of the self-reference lift across `Local | InVM | InContainer`,
  fractal bootstrap (the Python bootstrapper is the metal-frame instance of provision → build-pb →
  handoff), and the deploy ≡ business-logic unification (one algebra for deployment and runtime business
  logic).
- [architecture/generic_project_model.md](architecture/generic_project_model.md) — the implemented
  generic project model (§ BB, phase 19): `hostbootstrap-core` owns no hardcoded defaults and is
  parameterized over a project's own config type (`ProjectSpec cfg tcfg`); `project init` and the harness
  share one project-owned `psInit` (DRY); the harness generates the run's `<project>.dhall` from a thin
  `test.dhall` override; a pure `SecretRef` vocabulary keeps secrets-strict configs plaintext-free.
- [architecture/binary_context_config.md](architecture/binary_context_config.md) — the "know your
  place" binary-context contract: a sibling `<project>.dhall` is parameters + context + witness, the
  read-only `context` command introspects and visualizes the frame, and each frame fails fast on handoff
  unless it matches its declared `.dhall`.
- [architecture/python_haskell_boundary.md](architecture/python_haskell_boundary.md) — what the
  thin Python bootstrapper owns versus `hostbootstrap-core`, and the default-to-Haskell rule.
- [architecture/build_and_run_model.md](architecture/build_and_run_model.md) — the host-native
  build/run model, the headless host-build pattern (CUDA-on-Windows), `./.build/`, and why the binary
  (not the bootstrapper) builds the project container.
- [architecture/library_hierarchy.md](architecture/library_hierarchy.md) — the three additive Cabal
  library levels (L0◄L1◄L2) and the extension streams every level composes additively (lift chain, Dhall
  vocabulary, schema-gen, test seams, service handlers), over a fixed command surface that is never a stream.
- [architecture/dhall_generation.md](architecture/dhall_generation.md) — `.dhall` as parameters +
  context + witness, the child config minted by the generated context-init step, the generated Dhall
  vocabulary, the three-vocabulary layering, and the reflect-from-decoders schema derivation.
- [architecture/run_models.md](architecture/run_models.md) — the four run-models (`OneShot`,
  `HostNative`, `HostDaemon`, `Cluster`) and the key that selects one, never declared in Dhall.
- [architecture/harness_workflow.md](architecture/harness_workflow.md) — the per-case `runMatrix` loop,
  the seam-split (L0 driver vs cluster seams vs app matrix), the mechanical delete-guard, and budget-slicing.

## Engineering

- [engineering/schema.md](engineering/schema.md) — the project-local `<project>.dhall` schema that
  every project binary reads beside itself.
- [engineering/secrets.md](engineering/secrets.md) — the implemented `SecretRef` vocabulary (no plaintext
  secrets in a production `<project>.dhall`) and the `test-secrets` seam a secrets-strict consumer injects
  test secrets through (§ BB, phase 19); core never resolves secrets.
- [engineering/dhall_topology.md](engineering/dhall_topology.md) — the three-tier Dhall model, the
  topology frames that drive the recursive chain (each pb verifies its frame), and the rule that rich
  schemas are binary-generated artifacts.
- [engineering/config_generation.md](engineering/config_generation.md) — the `ConfigArtifact`
  registry, the render round-trip guarantee, and the child `.dhall` minted by the context-init step
  inside `project up`; schema/render introspection folds under the read-only `context` command.
- [engineering/composition_patterns.md](engineering/composition_patterns.md) — a cookbook of composition
  shapes (the `[Step]` chain and its recursive interpreter, context topologies, operation kinds,
  business-logic shapes) consumers compose their chain from.
- [engineering/accelerator_daemon.md](engineering/accelerator_daemon.md) — the active demo
  generalization where the project binary also runs as a substrate-specific accelerator daemon, JIT-builds
  a real Swift/Metal, CUDA, or C++ worker, exchanges CBOR over WebSocket with the web service, and is
  validated by integration and browser e2e tests; the UI/no-fallback/codegen shell is implemented, while
  daemon runtime and real worker integration remain open.
- [engineering/authoring_project_binaries.md](engineering/authoring_project_binaries.md) — the
  step-by-step guide to authoring a project binary on `hostbootstrap-core`: contributing its
  `chain :: cfg -> [Step]` plus step actions, test suite, Dhall vocabulary, and budget.
- [engineering/ensure_reconcilers.md](engineering/ensure_reconcilers.md) — the `ensure` reconciler
  contract; reconcilers are library primitives that run as `ensure-*` chain steps within `project up`.
- [engineering/resource_budgeting.md](engineering/resource_budgeting.md) — the resource budget,
  verify-spare-resources, and Colima/kind cordoning.
- [engineering/applied_cordon.md](engineering/applied_cordon.md) — budget-as-ceiling enforcement: the
  one canonical parser, the three rings, and the per-substrate storage cordon.
- [engineering/incus.md](engineering/incus.md) — the `incus` host-provider axis: the `HostTarget`
  parameterization, `ensure incus`, and the VM lifecycle expressed as core chain steps (deploy-VM under
  `project up`, provider-VM stop under `project down`, delete under `project destroy`) plus
  `incus exec` dispatch and the sizing cordon; the worked demo uses Lima, not Incus, for the Apple
  Silicon pristine VM.
- [engineering/lima.md](engineering/lima.md) — the Lima VM provider used by the worked demo on Apple
  Silicon for a real pristine Linux VM, with the same deploy/stop/destroy VM lifecycle steps.
- [engineering/wsl2.md](engineering/wsl2.md) — the Windows WSL2 host-provider VM, the peer of
  Lima (Apple Silicon) and Incus (native Linux): `ensure wsl2` prepares WSL2 platform readiness, then the
  project chain registers its own named `Ubuntu-24.04` distro and the same `deploy-VM` / `project down`
  (stop-without-delete) / `project destroy` lifecycle steps drive it; includes the honest WSL2 resource
  cordon (the global `.wslconfig` ceiling vs. the per-distro VHDX cap).
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
  Docker Hub login down the lift to authenticate nested pulls, modelled so the credential is never in
  Dhall, never persisted, and never in `argv`.
- [engineering/testing.md](engineering/testing.md) — the standardized `runMatrix` harness, the
  root-gated `test init` / `test run <suite>|all` surface (`test.dhall`), and the project test suites.
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
- [engineering/code_check_doctrine.md](engineering/code_check_doctrine.md) — every image build gates
  on the project's canonical code-check.
- [engineering/linking_and_optimization.md](engineering/linking_and_optimization.md) — static
  linking and optimization policy.
- [engineering/gitignore_guardrails.md](engineering/gitignore_guardrails.md) — what stays out of
  version control.

## Operations

- [operations/demo_runbook.md](operations/demo_runbook.md) — the `hostbootstrap-demo` runbook: the
  `project up` / `project down` / `project destroy` lifecycle plus `test run all` and `context`
  visualization, the feature-to-harness-case table, and the
  three-builds-vs-standard-host-native-build explanation.

## Command Surface

The fixed core command surface is exactly five user-facing verbs: `project`, `test`, `service`, `context`,
and `check-code`. There are no hidden commands. `ensure` is a reconciler library, not a command. The recursive
`project init|up|down|destroy` lifecycle interprets the project's `chain :: cfg -> [Step]` value
across the three-frame descent: `project up` runs the current frame's steps then hands `pb project up` to
the next frame, standing up the live persistent stack; `project down` / `project destroy` tear it down
while preserving host `.data`.

- **The chain is the single representation.** Cluster bring-up runs as the `deploy-kind` and `deploy-chart`
  steps, the `context-init` step mints the child config, `deploy-registry` and `push-image` stand up and load
  the registry, and the `ensure` reconcilers run as chain steps — all interpreted under `project up`.
- **`context` is read-only introspection.** Its `inspect`/`path`/`show`/`schema`/`render` subcommands
  introspect and visualize the current frame, including schema and render output.
- **`test init` / `test run <suite>|all`** drive the standardized harness, which runs the real `project up`
  under a test config (one per distinct test config), asserts the live stack, and tears it down.
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
