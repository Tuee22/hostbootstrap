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
- [architecture/python_haskell_boundary.md](architecture/python_haskell_boundary.md) — what the
  thin Python bootstrapper owns versus `hostbootstrap-core`, and the default-to-Haskell rule.
- [architecture/build_and_run_model.md](architecture/build_and_run_model.md) — the
  substrate-dependent build/run model, Tart as build-only, `./.build/`, and the build-twice
  rationale.

## Engineering

- [engineering/schema.md](engineering/schema.md) — the skeletal `hostbootstrap.dhall` schema.
- [engineering/dhall_topology.md](engineering/dhall_topology.md) — the three-tier Dhall model and the
  rule that rich schemas are binary-generated artifacts.
- [engineering/ensure_reconcilers.md](engineering/ensure_reconcilers.md) — the `ensure` reconciler
  contract and the fail-fast-on-wrong-host CLIs.
- [engineering/resource_budgeting.md](engineering/resource_budgeting.md) — the resource budget,
  verify-spare-resources, and Colima/kind cordoning.
- [engineering/cluster_lifecycle.md](engineering/cluster_lifecycle.md) — kind/Helm lifecycle
  semantics, the never-delete-`.data` invariant, and production-vs-test profiles.
- [engineering/base_image.md](engineering/base_image.md) — the base image contents.
- [engineering/build_release.md](engineering/build_release.md) — base-image build and publish
  semantics.
- [engineering/prerequisites.md](engineering/prerequisites.md) — the Python fail-fast host minimums.
- [engineering/testing.md](engineering/testing.md) — the layered test suite and development test
  runner.
- [engineering/harbor.md](engineering/harbor.md) — downstream image-push guidance.
- [engineering/derived_project_standards.md](engineering/derived_project_standards.md) — the rules
  every derived project follows.
- [engineering/warm_store.md](engineering/warm_store.md) — the warm Cabal store contents and
  cache-hit contract.
- [engineering/code_check_doctrine.md](engineering/code_check_doctrine.md) — every image build gates
  on the project's canonical code-check.
- [engineering/linking_and_optimization.md](engineering/linking_and_optimization.md) — static
  linking and optimization policy.
- [engineering/gitignore_guardrails.md](engineering/gitignore_guardrails.md) — what stays out of
  version control.

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
