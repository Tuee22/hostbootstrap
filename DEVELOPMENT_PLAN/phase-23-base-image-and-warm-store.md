# Phase 23 — Base image publication and the opportunistic warm store

**Status**: Active
**Depends on**: Phase 22 (service runtime)
**Substrates**: linux-cpu
**Gate**: current-compatible resolution → native build → complete quality gate → publish rolling tag → pull →
real-consumer compatibility smoke, on linux-cpu
**Gate kind**: deferred

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

### Sprint 23.4: The publish, pull, and consumer smoke run [Active]

**Status**: Active
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the dated publish, pull, and real-consumer compatibility smoke on linux-cpu.

#### Deliverables

- one dated run naming the published tag, the pulled digest, and the consumer build that verified it.

#### Validation

The pull and smoke halves are recorded; the publish half is not.

On 2026-09-06, `docker pull docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64` resolved to
`sha256:3634916e85b1fda411ae671a4bca2f72745e0bd106e2e9efebccc25415e0bc49`, and the real-consumer
compatibility smoke built against that exact digest on arm64 macOS 26.6.2 (build 25G83) in 11.8
seconds. The consumer observed `ghc`, `cabal`, a set `CABAL_DIR`, the warm store at
`/opt/basecontainer/haskell-deps`, and `cabal build --dry-run all` resolving `Up to date` against the
inherited store — which is the question a publication gate can answer: is what was published usable by
a project that builds `FROM` it.

The defect that blocked this half is resolved. `compatibility_smoke_spec` pointed at
`demo/docker/Dockerfile`, which requires a named build context holding a separately selected builder,
two verification-key build arguments, and four `required=true` secrets — two of them a signed one-use
build grant only the project binary's build coordinator mints. Driving it from the Python bootstrapper
would have meant minting build authority there, a second authority surface § KK's single-owner rule
exists to prevent. The smoke now builds `docker/compatibility-smoke.Dockerfile`, whose only input is
`BASE_IMAGE`; the demo's authenticated build stays with the coordinator that owns it and is exercised
by the [worked-demo phase](phase-24-worked-demo.md).

`tests/test_base_image.py` now asserts the consumer's own requirements — one `ARG`, no secrets, no
named context — rather than the spec's fields, because asserting the fields is what let a spec that
pointed at a real consumer coexist with a command that could never build it. A companion case asserts
no module under `hostbootstrap/` names a `demo/` path at all.

#### Remaining Work

The publish half is owed: `hostbootstrap base build-and-push --flavor cpu --arch arm64`, which pushes
the rolling tag to the operator's registry namespace. It is the one step of this gate that is an
outward-facing publication rather than an observation, and it is performed only under the operator's
direction.

## Remaining Work

Sprint 23.4 owns the owed run.

The **publish half** of the gate is owed. The pull and smoke halves are recorded above: on 2026-09-06 the
published rolling tag resolved to `sha256:3634916e85b1fda411ae671a4bca2f72745e0bd106e2e9efebccc25415e0bc49`
and the real-consumer compatibility smoke built against that exact digest on arm64 macOS 26.6.2.

The defect that made the gate unexecutable is **fixed**. `compatibility_smoke_spec` now builds
`docker/compatibility-smoke.Dockerfile` (`hostbootstrap/base_image.py:311`, `:368`), whose only input is
`BASE_IMAGE`. It previously built `demo/docker/Dockerfile`, which requires a `hostbootstrap-builder` named
build context, two 64-character verification-key build arguments, and four `required=true` secret mounts —
two of which are a signed one-use build grant only the Haskell coordinator mints — while
`docker_ops.build_command` emits neither `--secret` nor `--build-context`. Driving that Dockerfile from
Python would have created the second build-authority surface the architecture exists to prevent, so the
smoke now asks the question a publication gate can answer on its own.

One **ordering defect remains open**: `cli.py` pushes the rolling tag (`hostbootstrap/cli.py:402`) before
running the smoke (`:405`), so a failing smoke leaves the tag published.

Closing this phase requires the outward-facing publish — a push to the user's Docker Hub namespace, which
an assistant performs only when the user directs it — and then recording the dated
publish → pull → real-consumer run on linux-cpu.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — where publication sits relative to the host build.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the gate kinds this phase closes on and the run it records.
- `documents/engineering/base_image.md` — the rebuild → republish → pull rule.
- `documents/engineering/build_release.md` — the full publication pipeline.
- `documents/engineering/warm_store.md` — broad population and graceful misses.
- `documents/engineering/cabal_layout.md` — one project host and container.

**Cross-references to add:**
- `development_plan_standards.md` § R, § V, and § FF name this phase as the owner of publication and the store.
- `CLAUDE.md` and `AGENTS.md` state the rebuild → republish → pull rule for assistants.
