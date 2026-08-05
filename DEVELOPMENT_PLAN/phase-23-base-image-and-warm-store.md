# Phase 23 — Base image publication and the opportunistic warm store

**Status**: Done
**Depends on**: Phase 22 (service runtime)
**Substrates**: linux-cpu
**Gate**: current-compatible resolution → native build → complete quality gate → publish rolling tag → pull →
real-consumer compatibility smoke, on linux-cpu

> **Purpose**: Publish a rolling, native-architecture base image whose warm Cabal store is an opportunistic
> cache, and prove a real consumer builds against the pulled tag.

## Phase Objective

Derived projects build `FROM` a published rolling tag, so that tag is the source of truth and the repository
must not drift from it. Publication is therefore a full pipeline rather than a build: discover the current
compatible upstream versions, build host-native for the publishing architecture, pass the complete gate, push
the rolling tag, pull it back, and smoke a real consumer against the pulled image.

The warm Cabal store inside the image is a cache and nothing more. A miss resolves and builds normally — see
[rationale.md](rationale.md).

## Sprints

### Sprint 23.1: Native rolling publication [Done]

**Status**: Done
**Implementation**: `docker/basecontainer.Dockerfile`, `hostbootstrap/base_image.py`,
`hostbootstrap/docker_ops.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/base_image.md`, `documents/engineering/build_release.md`

#### Objective

One command, host-native, fully gated.

#### Deliverables

- `hostbootstrap base build-and-push --flavor <f> --arch <a>` is the canonical command: plain single-architecture
  `docker build` plus `docker push`, host-native, no buildx.
- The published tag is rolling: `basecontainer-<flavor>-<arch>`. A recorded digest identifies one publication but
  is not a locked-input or consumer-pinning contract.
- The architecture is validated against the host before publishing, so an image cannot be pushed under the wrong
  architecture tag.
- Publication runs the complete Python and Haskell gate first; a failing gate does not publish.
- A rebuild intentionally discovers current compatible upstream versions; it does not replay a committed input
  lock.

#### Validation

`hostbootstrap.test_all` covers the command shape, the architecture validation, and the gate ordering. Dated
evidence: a published rolling tag pulled and smoked against the real consumer on linux-cpu.

#### Remaining Work

None.

### Sprint 23.2: Publish → pull → real-consumer smoke [Done]

**Status**: Done
**Implementation**: `hostbootstrap/base_image.py`, `docker/`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/base_image.md`

#### Objective

Prove the published tag is the one consumers get.

#### Deliverables

- After pushing, the tag is **pulled** and a real consumer project is built against the pulled image, so the
  evidence is about the published artifact rather than a local layer cache.
- Building the base locally and testing a derived project against the un-republished local image is not
  substitute evidence, because it hides drift between the repository and the registry.
- When the base Dockerfile or the warm-store inputs change, the affected tag must be rebuilt, republished, and
  pulled before any derived evidence counts.

#### Validation

The smoke build against the pulled tag is the gate. Dated evidence is recorded with the publication.

#### Remaining Work

None.

### Sprint 23.3: The opportunistic warm store [Done]

**Status**: Done
**Implementation**: `core/warm-deps/`, `core/cabal.project`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/warm_store.md`, `documents/engineering/cabal_layout.md`

#### Objective

Broad best-effort population, graceful misses.

#### Deliverables

- The warm store is populated broadly from the shared dependency set, with build ways aligned to the consumer
  where practical so unfoldings are reusable.
- Consumers use the same host-compatible `cabal.project` inside and outside containers. There is no
  container-only project file and no base-owned freeze import, because the store is a cache and not a solver API.
- A cache miss resolves and builds online without failing the build.
- The store's optimisation level matches the consumer's, so a mismatch does not silently defeat reuse.

#### Validation

A derived build with a deliberately absent dependency resolves and builds. `cabal build all` from `demo/`
succeeds against both a warm and a cold store.

#### Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — where publication sits relative to the host build.

**Engineering docs to create/update:**
- `documents/engineering/base_image.md` — the rebuild → republish → pull rule.
- `documents/engineering/build_release.md` — the full publication pipeline.
- `documents/engineering/warm_store.md` — broad population and graceful misses.
- `documents/engineering/cabal_layout.md` — one project host and container.

**Cross-references to add:**
- `development_plan_standards.md` § N, § V, and § FF name this phase as the owner of publication and the store.
- `CLAUDE.md` and `AGENTS.md` state the rebuild → republish → pull rule for assistants.
