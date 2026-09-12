# Phase 23 — Base image publication and the opportunistic warm store

**Status**: Active
**Current sprint**: None — phase complete
**Depends on**: Phase 22 (service runtime)
**Substrates**: linux-cpu
**Gate**: current-compatible resolution → native build → complete quality gate → publish rolling tag → pull →
real-consumer compatibility smoke, on linux-cpu
**Gate kind**: deferred
**Gate evidence**: 2026-09-09 ; x86_64 Ubuntu 24.04.4 LTS, Linux 7.0.0-28-generic,
Docker 29.7.1, GHC 9.12.4, Cabal 3.16.1.0, Poetry 2.4.1, Python 3.12.3 ;
repository-local Python-bootstrapper `poetry run hostbootstrap base build-and-push --flavor cpu
--arch amd64` ; pass ; covers 78e785dcc3c00042f0f8c91cc32311243d40fe61e11584c9eafd12dccd42b718
**Evidence covers**: `docker/basecontainer.Dockerfile` `docker/compatibility-smoke.Dockerfile`
`core/warm-deps` `hostbootstrap/base_image.py` `hostbootstrap/cli.py`
`hostbootstrap/docker_ops.py`

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
**Implementation**: `hostbootstrap/base_image.py`, `hostbootstrap/cli.py`, `docker/`,
`tests/test_base_image.py`, `tests/test_cli.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/base_image.md`

#### Objective

Prove the published tag is the one consumers get.

#### Deliverables

- Before pushing, the workflow resolves the newly built image's local `sha256:...` ID and a cold
  compatibility-consumer build uses that immutable ID; a consumer failure therefore refuses before registry
  mutation. The rolling tag is deliberately not used here because BuildKit can resolve a registry-backed tag
  from the registry even without `--pull`; the pre-publish smoke uses the classic builder so the daemon-local
  ID cannot be reinterpreted as a registry repository. The post-publish digest smoke remains a BuildKit build.
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

### Sprint 23.4: The publish, pull, and consumer smoke run [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the dated publish, pull, and real-consumer compatibility smoke on linux-cpu.

#### Deliverables

- one dated run naming the published tag, the pulled digest, and the consumer build that verified it.

#### Validation

On 2026-09-09, the repository-local Python bootstrapper completed the canonical pipeline on native
x86_64 Ubuntu 24.04.4 LTS with Docker 29.7.1. The complete Python/core/demo source preflight passed,
then the CPU image built with the current compatible selections: GHC 9.10.3, Cabal 3.16.1.0,
Fourmolu 0.19.0.1, HLint 3.10, Go 1.27.1, Node 24.21.0, npm 12.0.2, PureScript 0.15.16,
kind 0.33.0, kubectl 1.37.0, Helm 4.2.4, Pulumi 3.261.0, Rust 1.98.1, and Poetry 2.4.3.

The pre-publication compatibility consumer built with the classic builder against immutable local image
ID `sha256:e46fb5699af246dc631704cd9bba5020776a7e96fbba1f4c450b5b9971ffb9d5`. It observed GHC,
Cabal, `CABAL_DIR`, and `/opt/basecontainer/haskell-deps`, and its `cabal build --dry-run all` resolved
`Up to date`. Only after that pass did the workflow push
`docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64`.

The push reported digest `sha256:e46fb5699af246dc631704cd9bba5020776a7e96fbba1f4c450b5b9971ffb9d5`.
The workflow pulled that tag, resolved the same repository digest, and cold-built the compatibility
consumer with BuildKit against the exact digest. The published-artifact smoke again observed GHC 9.10.3,
Cabal 3.16.1.0, the warm store, and an `Up to date` inherited-store resolution.

#### Remaining Work

None.

### Sprint 23.5: A committed style contract [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal`, `documents/engineering/code_check_doctrine.md`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/code_check_doctrine.md`, `documents/languages/haskell.md`

#### Objective

§ R now says the style contract is committed rather than defaulted. Today no formatter or linter
configuration exists anywhere in the repository, so the contract is whatever the tools defaulted to on
the day the rolling base was last republished — which makes a base rebuild able to change what passes
with no repository change at all. A committed configuration is what turns the gate's verdict into a
property of the source.

#### Deliverables

- `fourmolu.yaml` and `.hlint.yaml` are committed at the repository root.
- Their settings are chosen to match the existing sources as closely as possible, so the reformat that follows is as small as it can be.
- The code-check doctrine names them as the contract and stops describing style as a property of the installed tool.
- No source is reformatted in this sprint.

#### Validation

The host static gate is unaffected: this sprint adds configuration and changes no source.

#### Remaining Work

The reformat, the gate, the smoke, and the image surface are Sprints 23.6 to 23.9.

### Sprint 23.6: The repository's Haskell sources meet the committed style [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core`, `demo`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/code_check_doctrine.md`

#### Objective

Formatting only. This sprint exists separately so the diff has one shape and a reviewer knows that
before opening it: no semantic change, no import change, no export change. Landing it inside any other
sprint would make that sprint unreviewable and would obscure the history of every module the
deduplication work has just restructured.

#### Deliverables

- The formatter is applied in place to the library, its internal sublibraries, its application, its suites and the worked consumer.
- The diff contains formatting and nothing else; that property is the deliverable.
- This sprint lands as its own commit.

#### Validation

The host static gate, unchanged in every total. An identical set of passing cases before and after is
the evidence that the change is formatting.

#### Remaining Work

None beyond the phase's own.

### Sprint 23.7: The source gate runs the formatter and the linter [Planned]

**Status**: Planned
**Implementation**: `hostbootstrap/cli.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/code_check_doctrine.md`, `documents/engineering/build_release.md`

#### Objective

The repository's source gate runs the Python checks and four warning-clean Cabal invocations, and no
formatter or linter at all. The only places either tool runs today are the base image's two sample
files and the worked consumer's own sources — so the library, the largest Haskell root the family
builds on, has never been read by either. § R now places it inside the contract; this is the step that
makes that mechanical.

#### Deliverables

- The source gate gains a formatter check and a linter step over the library and consumer source roots.
- They run before the expensive Cabal legs, so a style regression fails in seconds rather than after a full build.
- Linter findings are triaged into accepted hints and justified configuration entries — never a per-module compiler suppression, of which the library currently has none.
- The gate's failure message names which check failed and over which root.

#### Validation

The source gate itself, on a clean tree: it passes, and it fails on a deliberately misformatted file.

#### Remaining Work

None beyond the phase's own.

### Sprint 23.8: The compatibility smoke asks a consumer's question [Planned]

**Status**: Planned
**Implementation**: `docker/compatibility-smoke.Dockerfile`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/base_image.md`, `documents/engineering/warm_store.md`

#### Objective

The smoke says it proves a derived project resolves against the inherited store, and what it resolves
is the base's own warm-store package set — the very packages whose resolution produced that store. Its
question is close to tautological, and it is the last gate between a rebuilt base and the registry.

#### Deliverables

- The smoke resolves a small consumer package whose dependency closure is not the warm store's own.
- It continues to check the toolchain and the store's presence as distinct failures.
- It verifies that the formatter and linter the base installs actually start, since the doctrine treats their presence as part of what the base guarantees.
- Its comment describes what it now does.

#### Validation

The smoke build itself, against a freshly built local image and again against the pulled digest, which
is what this phase's gate already requires.

#### Remaining Work

None beyond the phase's own.

### Sprint 23.9: The bootstrapper's image surface is typed [Planned]

**Status**: Planned
**Implementation**: `hostbootstrap/base_image.py`, `hostbootstrap/docker_ops.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/base_image.md`

#### Objective

Three small defects on the publication surface. A flavor selector that no production code calls maps
the Windows accelerator substrate to the CPU base, contradicting every other part of the system; a
build specification carries resource caps alongside a builder flag that decides whether those caps are
honoured at all, so a silently-ignored request is expressible; and the package's one type suppression
hides a default value that is not of the type it claims.

#### Deliverables

- The uncalled flavor selector is deleted, or corrected and given a call site — one of the two, decided here.
- Its test covers every substrate rather than the three that leave the Windows cases unexercised.
- The builder selection and the resource caps become one value, so caps cannot be requested from a builder that ignores them.
- The environment default is an empty mapping of the declared type, and the suppression is deleted.

#### Validation

The host static gate, with coverage at 100%. The flavor test's extension to every substrate is the
part that matters: the current gap is a worked example of line coverage certifying an untested
branch.

#### Remaining Work

None beyond the phase's own.

## Remaining Work

The style contract is owed as committed configuration. **Sprint 23.5** owns it, and
Sprints 23.6 to 23.9 follow with the reformat, the gate that reads it, the consumer smoke, and the typed
image surface.

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
