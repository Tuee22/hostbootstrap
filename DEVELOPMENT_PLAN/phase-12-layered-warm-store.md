# Phase 12: Layered Warm Store

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [system-components.md](system-components.md), [phase-6-base-image-and-thin-python-bootstrapper.md](phase-6-base-image-and-thin-python-bootstrapper.md), [phase-8-dhall-generation-and-extension.md](phase-8-dhall-generation-and-extension.md)

> **Purpose**: Split the warm Cabal store freeze by library layer so the non-daemon compute CLI is not
> coupled to the daemon dependency closure, generate both freezes in-image (never committed), and add the
> `purescript-bridge` dependency the demo's web build needs.

## Phase Status

**Status**: Done

The warm-store freeze is **layered and in-image-generated**. The warm-store package is split into two
layer manifests under `haskell/haskell-deps/` — `basecontainer-core-deps.cabal` (base + the
`hostbootstrap-core` closure + the shared web-build extras: `purescript-bridge` and the web-server stack
`warp`/`wai*`/`network`/`http-types`/`websockets`) and `basecontainer-daemon-deps.cabal` (the
daemon-family deps: Redis/Postgres/proto/secure-WS-client — `hedis`, `postgresql-simple`, `proto-lens*`,
`wuss`). `cabal.project` builds the single shared store from both; the base build then projects it per
layer — `cabal freeze --project-file=core.project` → `core.freeze` and `--project-file=daemon.project` →
`daemon.freeze` (all three project files `import: warm-store.config`, so the freezes are projections of
one store). `mcts` and any L0-direct consumer (the demo) import only `core.freeze` and are not coupled to
the daemon closure; a daemon app imports both. The membership of the shared web-server packages
(`warp`/`wai*`/`network`) — the question this layering had to settle — is **resolved into `core.freeze`**;
`http-client*` is in `core.freeze` too (pulled into the core closure by `dhall`'s remote-import support).

The split is **validated**: both freezes are produced with the correct partition — `core.freeze` pins no
daemon-distinctive package (`hedis`/`postgresql-simple`/`proto-lens*`/`wuss`) while `daemon.freeze` does,
and a `cabal build --dry-run` of `hostbootstrap-core` importing only `core.freeze` resolves with no
daemon package in the plan — confirmed both on the host `ghc-9.12.4` toolchain and in a real `ghc-9.12.4`
container running the exact in-image freeze step. The freezes are never committed
(`.gitignore`/`.dockerignore` exclude `cabal.project.freeze`, `core.freeze`, `daemon.freeze`, and the
`*.project.freeze` intermediates), and `purescript-bridge` is in the `core.freeze` manifest (Sprint 12.3).
The published `basecontainer-<flavor>-<arch>` tag's full warm-store compile (every package built at
`-O2`) is produced by the operator's `base build-and-push` — the same real-build standard Phases 5/10/11
follow (see [development_plan_standards.md § V](development_plan_standards.md)).

## Phase Objective

Make the warm-store freeze layered and in-image-generated so cache-hit and version-pinning track the
library layers, and add `purescript-bridge` so derived projects with a PureScript web build hit the warm
store.

## Sprints

### Sprint 12.1: Freeze fragmentation [Done]

**Status**: Done
**Implementation**: `haskell/haskell-deps/core/basecontainer-core-deps.cabal`, `haskell/haskell-deps/daemon/basecontainer-daemon-deps.cabal`, `haskell/haskell-deps/{cabal,core,daemon}.project`, `haskell/haskell-deps/warm-store.config`, `docker/basecontainer.Dockerfile`
**Docs to update**: `documents/engineering/warm_store.md`, `documents/engineering/base_image.md`

#### Objective

Split the single freeze into per-layer fragments.

#### Deliverables

- `/opt/basecontainer/haskell-deps/core.freeze` (base + `hostbootstrap-core` closure + the shared
  web-build extras; imported by `mcts` and `daemon-substrate`) and `daemon.freeze`
  (Redis/Postgres/proto/secure-WS-client; imported only by daemon apps). The warm-store package is two
  layer manifests (`basecontainer-core-deps.cabal` / `basecontainer-daemon-deps.cabal`); `core.project`
  and `daemon.project` project the shared store into the two freezes. Each project's `cabal.project`
  imports only the fragment(s) for its layer.

#### Validation

- **Done.** `cabal freeze --project-file=core.project` and `--project-file=daemon.project` produce the
  two freezes; `core.freeze` pins no daemon-distinctive package (`hedis`/`postgresql-simple`/
  `proto-lens*`/`wuss`) while `daemon.freeze` does; a `cabal build --dry-run` of `hostbootstrap-core`
  importing only `core.freeze` resolves with **no** daemon package in the plan. Confirmed on the host
  `ghc-9.12.4` toolchain and in a `ghc-9.12.4` container.

#### Remaining Work

None. The published base tag's full warm-store compile (every package built at `-O2`) is produced by the
operator's `base build-and-push`.

### Sprint 12.2: In-image generation, never committed [Done]

**Status**: Done
**Implementation**: `.dockerignore`, `.gitignore`, `docker/basecontainer.Dockerfile`
**Docs to update**: `documents/engineering/warm_store.md`, `documents/engineering/gitignore_guardrails.md`

#### Objective

Generate both freezes in-image and stop the (incorrect) commit instruction.

#### Deliverables

- The freezes are produced by `cabal freeze --project-file=…` during the base build and written into the
  image; none is committed — `.gitignore`/`.dockerignore` exclude `cabal.project.freeze`, `core.freeze`,
  `daemon.freeze`, and the `*.project.freeze` intermediates. The dep-addition workflow rebuilds the base
  tags instead of committing a freeze (the "commit the freeze" claim is fixed in `warm_store.md`).

#### Validation

- **Done.** `git ls-files` shows no committed freeze. A `ghc-9.12.4` container running the exact in-image
  step (`cabal update` + `cabal freeze --project-file=core.project` + `--project-file=daemon.project` +
  `mv` to `core.freeze`/`daemon.freeze`) produces both freezes at the working path with the correct
  partition. The published base tag carrying them at `/opt/basecontainer/haskell-deps/` is produced by
  the operator's `base build-and-push`.

#### Remaining Work

None.

### Sprint 12.3: `purescript-bridge` in the warm store [Done]

**Status**: Done
**Implementation**: `haskell/haskell-deps/core/basecontainer-core-deps.cabal`
**Docs to update**: `documents/engineering/warm_store.md`, `documents/languages/purescript.md`

#### Objective

Warm the Haskell library the demo's web build uses to generate PureScript types.

#### Deliverables

- `purescript-bridge` added to the **`core.freeze`** manifest (it is a shared web-build dependency an
  L0-direct web consumer like the demo needs, not part of the daemon closure; `core.freeze`'s scope is
  therefore base + `hostbootstrap-core` closure + the shared web-build extras) so a derived project's
  `web bridge` step hits the warm store.

#### Validation

- `purescript-bridge` is present in the `core.freeze` manifest
  (`haskell/haskell-deps/core/basecontainer-core-deps.cabal`) and is pinned in the generated `core.freeze`
  (verified in the host and in-container freeze runs), so a project depending on it builds with a
  warm-store cache hit (the full cache hit is validated by a base-image build).

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
