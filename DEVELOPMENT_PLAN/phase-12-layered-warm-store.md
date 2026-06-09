# Phase 12: Layered Warm Store

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-6-base-image-and-thin-python-bootstrapper.md](phase-6-base-image-and-thin-python-bootstrapper.md), [phase-8-dhall-generation-and-extension.md](phase-8-dhall-generation-and-extension.md)

> **Purpose**: Split the warm Cabal store freeze by library layer so the non-daemon compute CLI is not
> coupled to the daemon dependency closure, generate both freezes in-image (never committed), and add the
> `purescript-bridge` dependency the demo's web build needs.

## Phase Status

**Status**: Blocked

**Blocked by**: phase-6 (the base image and warm store), phase-8 (the `hostbootstrap-core` surface whose
closure `core.freeze` pins)

Today one freeze pins the whole family's transitive versions. Under the three-level hierarchy that couples
a non-daemon consumer (`MCTS`, off L0) to the daemon dependency closure it never uses. This phase splits
the freeze into a `core.freeze` (base + `hostbootstrap-core`) and a `daemon.freeze` (the daemon-family
deps), each imported by the layer that needs it, both generated in-image by `cabal freeze` and never
committed (see [development_plan_standards.md § V](development_plan_standards.md)).

## Phase Objective

Make the warm-store freeze layered and in-image-generated so cache-hit and version-pinning track the
library layers, and add `purescript-bridge` so derived projects with a PureScript web build hit the warm
store.

## Sprints

### Sprint 12.1: Freeze fragmentation [Blocked]

**Status**: Blocked
**Blocked by**: phase-6
**Implementation**: `docker/basecontainer.Dockerfile`, `haskell/haskell-deps/` (planned)
**Docs to update**: `documents/engineering/warm_store.md`, `documents/engineering/base_image.md`

#### Objective

Split the single freeze into per-layer fragments.

#### Deliverables

- `/opt/basecontainer/haskell-deps/core.freeze` (base + `hostbootstrap-core` closure; imported by `MCTS`
  and `daemon-substrate`) and `daemon.freeze` (Pulsar/MinIO/proto/HTTP; imported only by daemon apps).
  Each project's `cabal.project` imports only the fragment(s) for its layer.

#### Validation

- A derived project importing only `core.freeze` resolves without the daemon closure; `cabal build
  --dry-run` shows only the project's own targets.

#### Remaining Work

None.

### Sprint 12.2: In-image generation, never committed [Blocked]

**Status**: Blocked
**Blocked by**: phase-12 (sprint 12.1)
**Implementation**: `docker/basecontainer.Dockerfile`, `.dockerignore`, `.gitignore` (planned)
**Docs to update**: `documents/engineering/warm_store.md`, `documents/engineering/gitignore_guardrails.md`

#### Objective

Generate both freezes in-image and stop the (incorrect) commit instruction.

#### Deliverables

- Both freezes are produced by `cabal freeze` during the base build and written into the image; neither is
  committed (`.dockerignore`/`.gitignore` exclude them). The dep-addition workflow rebuilds the base tags
  instead of committing a freeze.

#### Validation

- `git ls-files` shows no committed freeze; the base image contains the generated freezes at the documented
  paths.

#### Remaining Work

None.

### Sprint 12.3: `purescript-bridge` in the warm store [Blocked]

**Status**: Blocked
**Blocked by**: phase-12 (sprint 12.1)
**Implementation**: `haskell/haskell-deps/basecontainer-haskell-deps.cabal` (planned)
**Docs to update**: `documents/engineering/warm_store.md`, `documents/languages/purescript.md`

#### Objective

Warm the Haskell library the demo's web build uses to generate PureScript types.

#### Deliverables

- `purescript-bridge` added to the warm-store manifest so a derived project's `web bridge` step hits the
  warm store.

#### Validation

- A project depending on `purescript-bridge` builds with a warm-store cache hit.

#### Remaining Work

None.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/warm_store.md` - rewritten to the layered, in-image, never-committed freeze and
  the `core.freeze`/`daemon.freeze` split; FIX the "commit the freeze" claim.
- `documents/engineering/base_image.md` - the four single-arch tags and the layered warm store.
- `documents/engineering/gitignore_guardrails.md` - the freezes are gitignored/dockerignored by design.

**Cross-references to add:**
- `system-components.md` splits the warm-store row into `core.freeze`/`daemon.freeze`.
