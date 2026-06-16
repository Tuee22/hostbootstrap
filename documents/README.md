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

## Architecture

- [architecture/hostbootstrap_core_library.md](architecture/hostbootstrap_core_library.md) — the
  `hostbootstrap-core` Haskell library: module surface and the optparse command-tree extension
  contract project binaries build on.
- [architecture/composition_methodology.md](architecture/composition_methodology.md) — the
  composable-operation algebra, the self-reference lift across `Local | InVM | InContainer`, the
  one-operation-one-representation rule (the test harness is a context-agnostic lift target, so a
  consumer lifts the whole test workflow rather than re-expressing it as a parallel chain), and the
  deploy ≡ business-logic unification (one algebra for deployment and runtime business logic).
- [architecture/binary_context_config.md](architecture/binary_context_config.md) — the "know your
  place" binary-context contract: every normal project-binary command reads a sibling
  `<project>.dhall` and refuses commands that do not match its declared context.
- [architecture/python_haskell_boundary.md](architecture/python_haskell_boundary.md) — what the
  thin Python bootstrapper owns versus `hostbootstrap-core`, and the default-to-Haskell rule.
- [architecture/build_and_run_model.md](architecture/build_and_run_model.md) — the host-native
  build/run model, Tart as build-only, `./.build/`, and why the binary (not the bootstrapper) builds
  the project container.
- [architecture/library_hierarchy.md](architecture/library_hierarchy.md) — the three additive Cabal
  library levels (L0◄L1◄L2) and the four-stream extension contract every level composes additively.
- [architecture/dhall_generation.md](architecture/dhall_generation.md) — the local runtime config,
  generated child configs, and generated Dhall roles, plus the three-vocabulary layering and the reflect-from-decoders vs
  hand-written-assert nuance.
- [architecture/run_models.md](architecture/run_models.md) — the four run-models (`OneShot`,
  `HostNative`, `HostDaemon`, `Cluster`) and the collapsed key that selects one, never declared in Dhall.
- [architecture/harness_workflow.md](architecture/harness_workflow.md) — the per-case `runMatrix` loop,
  the seam-split (L0 driver vs cluster seams vs app matrix), the mechanical delete-guard, and budget-slicing.

## Engineering

- [engineering/schema.md](engineering/schema.md) — the project-local `<project>.dhall` schema that
  every project binary reads beside itself.
- [engineering/dhall_topology.md](engineering/dhall_topology.md) — the three-tier Dhall model and the
  rule that rich schemas are binary-generated artifacts.
- [engineering/config_generation.md](engineering/config_generation.md) — the `ConfigArtifact`
  registry, the `config schema`/`config render` verbs, and the render round-trip guarantee.
- [engineering/composition_patterns.md](engineering/composition_patterns.md) — a cookbook of composition
  shapes (context topologies, operation kinds, business-logic shapes) consumers compose their chain from.
- [engineering/authoring_project_binaries.md](engineering/authoring_project_binaries.md) — the
  step-by-step guide to authoring a project binary on `hostbootstrap-core` (verbs, the lift chain, the
  test seams, the budget).
- [engineering/ensure_reconcilers.md](engineering/ensure_reconcilers.md) — the `ensure` reconciler
  contract and the fail-fast-on-wrong-host CLIs.
- [engineering/resource_budgeting.md](engineering/resource_budgeting.md) — the resource budget,
  verify-spare-resources, and Colima/kind cordoning.
- [engineering/applied_cordon.md](engineering/applied_cordon.md) — budget-as-ceiling enforcement: the
  one canonical parser, the three rings, and the per-substrate storage cordon.
- [engineering/incus.md](engineering/incus.md) — the `incus` host-provider axis: the `HostTarget`
  parameterization, `ensure incus`, the VM lifecycle and `incus exec` dispatch, and the sizing cordon;
  the worked demo uses Lima, not Incus, for the Apple Silicon pristine VM.
- [engineering/lima.md](engineering/lima.md) — the Lima VM provider used by the worked demo on Apple
  Silicon for a real pristine Linux VM.
- [engineering/cluster_lifecycle.md](engineering/cluster_lifecycle.md) — kind/Helm lifecycle
  semantics, the never-delete-`.data` invariant, and production-vs-test profiles.
- [engineering/base_image.md](engineering/base_image.md) — the base image contents.
- [engineering/build_release.md](engineering/build_release.md) — base-image build and publish
  semantics.
- [engineering/prerequisites.md](engineering/prerequisites.md) — the Python fail-fast host minimums.
- [engineering/self_update.md](engineering/self_update.md) — the explicit pipx self-update doctrine
  for the Python bootstrapper and the no-hidden-latest-gate rule.
- [engineering/registry_credentials.md](engineering/registry_credentials.md) — forwarding the host's
  Docker Hub login down the lift to authenticate nested pulls, modelled so the credential is never in
  Dhall, never persisted, and never in `argv`.
- [engineering/testing.md](engineering/testing.md) — the standardized `runMatrix` harness, the `test`
  verb, and the project test suites.
- [engineering/harbor.md](engineering/harbor.md) — downstream image-push guidance.
- [engineering/derived_project_standards.md](engineering/derived_project_standards.md) — the rules
  every derived project follows.
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
  a–j pristine-bootstrap flow, the feature-to-harness-case table, and the
  three-builds-vs-standard-host-native-build explanation.

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
