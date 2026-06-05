---
name: documents-index
description: Index of the hostbootstrap SSoT documentation tree.
type: index
---

# Documents

This directory is the single source of truth for hostbootstrap's design,
toolchain, and engineering practices. The repository
[`README.md`](../README.md) is a concise adoption guide; the deep technical
material lives here.

* [documentation_standards.md](documentation_standards.md) — authoritative doc
  conventions for this repository.

## Engineering references

* [engineering/schema.md](engineering/schema.md) — the `hostbootstrap.dhall`
  project-config schema, its three execution models, and how illegal states
  are rejected.
* [engineering/base_image.md](engineering/base_image.md) — the four
  `basecontainer-<flavor>-<arch>` tags and what they contain.
* [engineering/build_release.md](engineering/build_release.md) — base-image
  build, publish, and `--build-base` semantics.
* [engineering/prerequisites.md](engineering/prerequisites.md) — host
  prereqs absorbed by `hostbootstrap doctor`.
* [engineering/testing.md](engineering/testing.md) — the layered test suite, the
  development test runner, coverage gate, and why direct pytest is refused.
* [engineering/harbor.md](engineering/harbor.md) — downstream guidance for a
  project pushing its own arch-explicit image (hostbootstrap does not push
  project images).
* [engineering/derived_project_standards.md](engineering/derived_project_standards.md) —
  the five rules every derived project follows; the doctrine entry point for
  authors of new project Dockerfiles.
* [engineering/warm_store.md](engineering/warm_store.md) — the warm Cabal
  store contents, cache-hit contract, and dep-addition workflow.
* [engineering/code_check_doctrine.md](engineering/code_check_doctrine.md) —
  the rule that every image build, base or derived, gates on the project's
  canonical code-check.
* [engineering/linking_and_optimization.md](engineering/linking_and_optimization.md) —
  static linking, `shared: True`, `-O2`, and `INLINABLE` policy.
* [engineering/gitignore_guardrails.md](engineering/gitignore_guardrails.md) —
  what must stay out of version control.

## Per-language guidance

* [languages/haskell.md](languages/haskell.md)
* [languages/python.md](languages/python.md)
* [languages/node.md](languages/node.md)
* [languages/purescript.md](languages/purescript.md)
* [languages/playwright.md](languages/playwright.md)
* [languages/rust.md](languages/rust.md)
* [languages/cpp.md](languages/cpp.md)
* [languages/cuda.md](languages/cuda.md)
* [languages/go.md](languages/go.md)
* [languages/cluster_tooling.md](languages/cluster_tooling.md)
