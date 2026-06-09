# Phase 12: Layered Warm Store

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-6-base-image-and-thin-python-bootstrapper.md](phase-6-base-image-and-thin-python-bootstrapper.md), [phase-8-dhall-generation-and-extension.md](phase-8-dhall-generation-and-extension.md)

> **Purpose**: Split the warm Cabal store freeze by library layer so the non-daemon compute CLI is not
> coupled to the daemon dependency closure, generate both freezes in-image (never committed), and add the
> `purescript-bridge` dependency the demo's web build needs.

## Phase Status

**Status**: Active

The layered-freeze **contract** is landed and documented: `core.freeze` (base + `hostbootstrap-core`
closure + the shared web-build extras, including `purescript-bridge`) is imported by `mcts` and
`daemon-substrate`; `daemon.freeze` (the daemon-family deps) is imported only by the daemon apps, so a
non-daemon consumer (`mcts`, off L0) is no longer coupled to the daemon closure. `purescript-bridge` is
in the `core.freeze` manifest (`haskell/haskell-deps/basecontainer-haskell-deps.cabal`); both freezes are
gitignored and dockerignored (`git ls-files` shows none), and `documents/engineering/warm_store.md` /
`base_image.md` / `gitignore_guardrails.md` / `derived_project_standards.md` describe the layered import,
the in-image generation, and the never-committed rule (the dep-add workflow rebuilds the base tags). The
phase stays `Active` for the two-freeze **in-image generation** itself — splitting the base build's
single `cabal freeze` into a `core.freeze` and a `daemon.freeze` — which is implemented and validated by
a real base-image build (not runnable in this code-only environment; see
[development_plan_standards.md § V](development_plan_standards.md)).

**Remaining Work**:
- Split the base build's single `cabal freeze` step into two layered-projection freezes
  (`core.freeze` / `daemon.freeze`) in `docker/basecontainer.Dockerfile`, validated by a base-image
  build (a derived project importing only `core.freeze` resolves without the daemon closure;
  `cabal build --dry-run` shows only its own targets). This requires building the base image.

## Phase Objective

Make the warm-store freeze layered and in-image-generated so cache-hit and version-pinning track the
library layers, and add `purescript-bridge` so derived projects with a PureScript web build hit the warm
store.

## Sprints

### Sprint 12.1: Freeze fragmentation [Active]

**Status**: Active
**Implementation**: `docker/basecontainer.Dockerfile`, `haskell/haskell-deps/basecontainer-haskell-deps.cabal`
**Docs to update**: `documents/engineering/warm_store.md`, `documents/engineering/base_image.md`

#### Objective

Split the single freeze into per-layer fragments.

#### Deliverables

- `/opt/basecontainer/haskell-deps/core.freeze` (base + `hostbootstrap-core` closure; imported by `mcts`
  and `daemon-substrate`) and `daemon.freeze` (Pulsar/MinIO/proto/HTTP; imported only by daemon apps).
  Each project's `cabal.project` imports only the fragment(s) for its layer.

#### Validation

- A derived project importing only `core.freeze` resolves without the daemon closure; `cabal build
  --dry-run` shows only the project's own targets. This is validated by a base-image build.

#### Remaining Work

The layered split is documented (the warm-store manifest is annotated with the core/daemon grouping and
the docs describe the import-by-layer contract); the base build's single `cabal freeze` must be split
into a `core.freeze` and a `daemon.freeze` projection, validated by a real base-image build.

### Sprint 12.2: In-image generation, never committed [Active]

**Status**: Active
**Implementation**: `.dockerignore`, `.gitignore`, `docker/basecontainer.Dockerfile`
**Docs to update**: `documents/engineering/warm_store.md`, `documents/engineering/gitignore_guardrails.md`

#### Objective

Generate both freezes in-image and stop the (incorrect) commit instruction.

#### Deliverables

- The freezes are produced by `cabal freeze` during the base build and written into the image; none is
  committed — `.gitignore`/`.dockerignore` exclude `cabal.project.freeze`, `core.freeze`, and
  `daemon.freeze`. The dep-addition workflow rebuilds the base tags instead of committing a freeze
  (the "commit the freeze" claim is fixed in `warm_store.md`).

#### Validation

- `git ls-files` shows no committed freeze (verified). The base image containing both generated freezes
  at the documented paths is validated by a base-image build.

#### Remaining Work

The `.gitignore`/`.dockerignore` guardrail and the never-committed docs are landed; emitting the two
freezes (rather than the single `cabal.project.freeze`) is the Sprint 12.1 in-image-generation work,
validated by a base-image build.

### Sprint 12.3: `purescript-bridge` in the warm store [Done]

**Status**: Done
**Implementation**: `haskell/haskell-deps/basecontainer-haskell-deps.cabal`
**Docs to update**: `documents/engineering/warm_store.md`, `documents/languages/purescript.md`

#### Objective

Warm the Haskell library the demo's web build uses to generate PureScript types.

#### Deliverables

- `purescript-bridge` added to the **`core.freeze`** manifest (it is a shared web-build dependency an
  L0-direct web consumer like the demo needs, not part of the daemon closure; `core.freeze`'s scope is
  therefore base + `hostbootstrap-core` closure + the shared web-build extras) so a derived project's
  `web bridge` step hits the warm store.

#### Validation

- `purescript-bridge` is present in the warm-store manifest
  (`haskell/haskell-deps/basecontainer-haskell-deps.cabal`), so a project depending on it builds with a
  warm-store cache hit (the cache hit is validated by a base-image build).

#### Remaining Work

None — `purescript-bridge` is in the `core.freeze` manifest.

## Documentation Requirements

**Engineering docs to create/update:**
- `documents/engineering/warm_store.md` - rewritten to the layered, in-image, never-committed freeze and
  the `core.freeze`/`daemon.freeze` split; FIX the "commit the freeze" claim.
- `documents/engineering/base_image.md` - the four single-arch tags and the layered warm store.
- `documents/engineering/gitignore_guardrails.md` - the freezes are gitignored/dockerignored by design.

**Cross-references to add:**
- `system-components.md` splits the warm-store row into `core.freeze`/`daemon.freeze`.
