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

The model is **the lift chain is the project**. A project binary's identity is its
`chain :: ProjectConfig -> [Step]` value; `project up` is a recursive interpreter that runs the current
frame's steps then hands `pb project up` to the next frame. The canonical home of this model is
[architecture/composition_methodology.md](architecture/composition_methodology.md); every other doc
defers to it rather than re-deriving it. The command surface is summarized in
[Command Surface](#command-surface).

## Architecture

- [architecture/hostbootstrap_core_library.md](architecture/hostbootstrap_core_library.md) — the
  `hostbootstrap-core` Haskell library: module surface, the `Step` algebra a project extends with its
  chain, and the `project`/`context`/`test`/`check-code` command tree project binaries build on.
- [architecture/composition_methodology.md](architecture/composition_methodology.md) — the **canonical
  home of the chain-is-the-project model**: the `[Step]` chain as the single representation, `project up`
  as the recursive/fractal interpreter of the self-reference lift across `Local | InVM | InContainer`,
  fractal bootstrap (the Python bootstrapper is the metal-frame instance of provision → build-pb →
  handoff), and the deploy ≡ business-logic unification (one algebra for deployment and runtime business
  logic).
- [architecture/binary_context_config.md](architecture/binary_context_config.md) — the "know your
  place" binary-context contract: a sibling `<project>.dhall` is parameters + context + witness, the
  read-only `context` command introspects and visualizes the frame, and each frame fails fast on handoff
  unless it matches its declared `.dhall`.
- [architecture/python_haskell_boundary.md](architecture/python_haskell_boundary.md) — what the
  thin Python bootstrapper owns versus `hostbootstrap-core`, and the default-to-Haskell rule.
- [architecture/build_and_run_model.md](architecture/build_and_run_model.md) — the host-native
  build/run model, Tart as build-only, `./.build/`, and why the binary (not the bootstrapper) builds
  the project container.
- [architecture/library_hierarchy.md](architecture/library_hierarchy.md) — the three additive Cabal
  library levels (L0◄L1◄L2) and the four-stream extension contract every level composes additively,
  where stream 1 is the lift chain (the ordered `[Step]` of core and project step kinds).
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
- [engineering/dhall_topology.md](engineering/dhall_topology.md) — the three-tier Dhall model, the
  topology frames that drive the recursive chain (each pb verifies its frame), and the rule that rich
  schemas are binary-generated artifacts.
- [engineering/config_generation.md](engineering/config_generation.md) — the `ConfigArtifact`
  registry, the render round-trip guarantee, and the child `.dhall` minted by the context-init step
  inside `project up`; schema/render introspection folds under the read-only `context` command.
- [engineering/composition_patterns.md](engineering/composition_patterns.md) — a cookbook of composition
  shapes (the `[Step]` chain and its recursive interpreter, context topologies, operation kinds,
  business-logic shapes) consumers compose their chain from.
- [engineering/authoring_project_binaries.md](engineering/authoring_project_binaries.md) — the
  step-by-step guide to authoring a project binary on `hostbootstrap-core`: contributing its
  `chain :: ProjectConfig -> [Step]` plus step actions, test suite, Dhall vocabulary, and budget.
- [engineering/ensure_reconcilers.md](engineering/ensure_reconcilers.md) — the `ensure` reconciler
  contract and the fail-fast-on-wrong-host CLIs; reconcilers run as chain steps within `project up`,
  and standalone `ensure <tool>` is a hidden debug surface.
- [engineering/resource_budgeting.md](engineering/resource_budgeting.md) — the resource budget,
  verify-spare-resources, and Colima/kind cordoning.
- [engineering/applied_cordon.md](engineering/applied_cordon.md) — budget-as-ceiling enforcement: the
  one canonical parser, the three rings, and the per-substrate storage cordon.
- [engineering/incus.md](engineering/incus.md) — the `incus` host-provider axis: the `HostTarget`
  parameterization, `ensure incus`, and the VM lifecycle expressed as core chain steps (deploy-VM under
  `project up`, stop-without-delete under `project down`, delete under `project destroy`) plus
  `incus exec` dispatch and the sizing cordon; the worked demo uses Lima, not Incus, for the Apple
  Silicon pristine VM.
- [engineering/lima.md](engineering/lima.md) — the Lima VM provider used by the worked demo on Apple
  Silicon for a real pristine Linux VM, with the same deploy/stop/destroy VM lifecycle steps.
- [engineering/cluster_lifecycle.md](engineering/cluster_lifecycle.md) — kind/Helm bring-up and teardown
  as chain steps under `project up`/`project down`/`project destroy` (including stop-without-delete), the
  never-delete-`.data` invariant, and production-vs-test profiles.
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
- [engineering/harbor.md](engineering/harbor.md) — downstream image-push guidance.
- [engineering/derived_project_standards.md](engineering/derived_project_standards.md) — the rules
  every derived project follows, including the four-stream contract whose stream 1 is the lift chain.
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

The core command tree is exactly `ensure`, `context`, `project`, `test`, and `check-code`. The recursive
`project init|up|down|destroy` lifecycle interprets the project's `chain :: ProjectConfig -> [Step]` value
across the three-frame descent: `project up` runs the current frame's steps then hands `pb project up` to
the next frame, standing up the live persistent stack; `project down` / `project destroy` tear it down
while preserving host `.data`.

- **The chain is the single representation.** Cluster bring-up runs as the `deploy-kind` and `deploy-chart`
  steps, the `context-init` step mints the child config, `deploy-harbor` and `push-image` stand up and load
  the registry, and the `ensure` reconcilers run as chain steps — all interpreted under `project up`.
- **`context` is read-only introspection.** Its `inspect`/`path`/`show`/`schema`/`render` subcommands
  introspect and visualize the current frame, including schema and render output.
- **`test init` / `test run <suite>|all`** drive the standardized harness, the separate test surface with
  its own isolated per-case kind clusters.
- **The demo contributes its `web` verb** (load-bearing for the chart pod and Dockerfile) plus the
  `vm` / `incus` provider verbs.

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
