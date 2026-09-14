# Phase 23 — Base image publication and the opportunistic warm store

**Status**: Done
**Depends on**: Phase 22 (service runtime)
**Substrates**: linux-cpu
**Gate**: current-compatible resolution → native build → complete quality gate → publish rolling tag → pull →
real-consumer compatibility smoke, on linux-cpu
**Gate kind**: deferred
**Gate evidence**: 2026-09-13 ; x86_64 Ubuntu 24.04.4 LTS, Linux 7.0.0-28-generic,
Docker 29.7.1, GHC 9.12.4, Cabal 3.16.1.0, fourmolu 0.19.0.1, HLint 3.10, Poetry 2.4.1,
Python 3.12.3 ; repository-local Python-bootstrapper `poetry run hostbootstrap base build-and-push
--flavor cpu --arch amd64` then the same command `--flavor cuda`, publishing
`basecontainer-cpu-amd64@sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8` and
`basecontainer-cuda-amd64@sha256:e4faab53cfaf88898c4e7c5c838396daa08f82cf4cb387906b8d35d181fdfa7a` ;
pass ; covers 01f1270d3cbc657325290f425e77e9492fa6ceef4e577a69891a2d1450e065b0
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

### Sprint 23.5: A committed style contract [Done]

**Status**: Done
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

None. `fourmolu.yaml` and `.hlint.yaml` are committed at the repository root, where both tools find them
by searching upward from the file they are given. The formatter settings are written out in full,
including the ones that agree with the tool's current defaults, and they are the measured best match:
of the 190 library, sublibrary and consumer modules, 74 were already byte-identical under them, against
0 for 2-space indentation with leading module headers, 6 for single-line Haddock, 20 for leading function
arrows and 10 for leading import/export lists. The linter configuration keeps hlint's default rule set
and names 51 hint families the library's conventions decline, grouped by the reason it declines them.

Two families were corrected in source instead, because they name defects rather than spellings: eight
unused `LANGUAGE` pragmas and twelve duplicate imports of one module in one scope. Six further
duplicate-import findings are refused in configuration rather than in source, because hlint does not
evaluate CPP and reads the two halves of an `#if`/`#else` as one scope; merging them would import a
Windows-absent name on Windows. On 2026-09-13 `hlint` over the library, its sublibraries, its
application and the worked consumer reported `No hints`.

### Sprint 23.6: The repository's Haskell sources meet the committed style [Done]

**Status**: Done
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

None. On 2026-09-13 the formatter was applied in place to 375 files across both Cabal projects, and the
case total is unchanged at 2,536 core and 150 demo. Three things a reformat of this size surfaces are
worth recording rather than leaving for a reader to rediscover.

**Seven modules the formatter cannot read.** fourmolu parses Haskell, not CPP, and in seven modules an
`#if`/`#else` splits a declaration. Those seven are excluded by name from the gate Sprint 23.7 adds,
never by pattern.

**Frozen guards were re-frozen, and the deltas kept.** Fourteen source-guard constants measure bytes or
significant lines of a module: four digests, several line counts, and two section markers whose text the
formatter rewrote. Each was re-frozen to the reformatted measurement. One needed more than that: the
rooted-transport budget compares a measured file against a pre-reformat baseline constant, and the
reformat inflated the measured side by 62 lines. The baseline was re-expressed by the same amount, so the
48-line sprint increment the budget is about is preserved rather than re-derived — the spec now says so
at the constant. Every budget assertion still holds on its own terms; none was widened.

**A latent `-Werror` defect surfaced.** `MeasuredInstance` in `HostBootstrap.Activation` declared record
fields across two constructors, which `-Wpartial-fields` refuses — and the package carries that warning
as an error. It had never failed because the module had not been recompiled since, and a cold build of
the original file reproduces the same three errors. The constructors are now eliminated positionally,
which is what the package's own warning policy says a sum's fields are for; no selector was in use.

### Sprint 23.7: The source gate runs the formatter and the linter [Done]

**Status**: Done
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

None. `_style_gates` contributes seven formatter gates — one per Haskell root of both Cabal projects,
covering 797 files — and five linter gates over the library, its sublibraries, its application and the
consumer's sources. Each gate's label names the check and the root it read, so a failure says which. They
are placed ahead of the four Cabal legs in `_quality_gates`, and a test pins that ordering rather than
trusting the literal order of the tuple. On 2026-09-13 every gate exited 0 against the clean tree, and
appending a misformatted declaration to `core/hostbootstrap-core/app/Main.hs` made the formatter gate for
that root exit 100 until it was removed.

### Sprint 23.8: The compatibility smoke asks a consumer's question [Done]

**Status**: Done
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

None. The smoke now writes a consumer package of its own — its own name, version and dependency list,
naming the dependency shape a derived project has — and resolves a build plan for it, instead of
re-resolving `/opt/basecontainer/haskell-deps`. A plan that names downloads is a pass and a plan that
cannot be produced is the failure, because the warm store is an opportunistic cache rather than a lock;
the comment says exactly that. The toolchain check and the store-presence check remain separate `RUN`
steps with separate messages, and a third step starts `fourmolu` and `hlint`, whose presence the
code-check doctrine treats as part of what the base guarantees.

### Sprint 23.9: The bootstrapper's image surface is typed [Done]

**Status**: Done
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

The host static gate, with coverage at 100%.

#### Remaining Work

None. The decision on the flavor selector is **deletion**. `substrate_to_flavor` had no production
caller, and there is no call site to give it: the Python bootstrapper does not build derived images, and
the base build takes its flavor as an explicit argument. Deleting it removes the contradiction its
Windows row carried and the untested-branch problem with it, so the deliverable asking its test to cover
every substrate is answered by there being no selector and no test.

`BuildSpec` no longer carries resource caps beside a boolean that decides whether they are honoured. A
build now carries one `Builder`: `BuildKitBuilder`, which rejects `--memory`/`--cpu-*` and therefore has
no field on which to request one, or `ClassicBuilder`, which is the only builder that honours them and
the only place a cap can be written. A silently ignored resource request is no longer representable, and
`_has_resource_caps` — the runtime recovery that used to notice the mistake — is gone. `RunSpec.env`
defaults to an immutable empty mapping of its declared type and the `type: ignore[assignment]` is
deleted; the package now carries none. Coverage is 100% with no omissions.

### Sprint 23.10: The publication gate against the styled tree [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/base_image.md`

#### Objective

This phase's gate is the whole publication pipeline, and five of its six inputs have just changed: the
Dockerfile's consumer smoke, the bootstrapper's image surface, the source gate that runs before Docker,
and the committed style contract both new gate legs read. The published rolling tag no longer matches the
repository that describes it until the pipeline is re-run end to end.

#### Deliverables

- The declared gate runs in full: current-compatible resolution, native build, complete source gate,
  push, pull, and the consumer smoke against the pulled digest.
- A gate-evidence row records the gate host, the command as run, and the published digest.
- The covers digest is re-measured over this phase's own paths and recorded.

#### Validation

The phase's own gate. It is an outward-facing publication and runs only on the operator's direction.

#### Remaining Work

None. On 2026-09-13 the pipeline ran end to end for both flavors. Each run discovered current compatible
upstream versions, passed the complete source gate — now including the seven formatter and five linter
legs ahead of the four Cabal legs — cold-built the rolling tag with the classic builder under the host's
measured caps, proved the consumer smoke against the immutable local image ID, pushed, pulled the tag
back, and proved the smoke again against the pulled digest. The published digests are in the row above.

**The first attempt failed, and the failure was the point.** `dl.min.io` answered `410 Gone` for the
MinIO client: the open-source server, client and KES projects were archived and every community release
stopped being served. A rebuild that discovers current upstream versions is exactly what finds that, and
it found it before the registry was mutated rather than after. The client now resolves from the
project's own GitHub releases by tag — the same shape `kind`, `kubectl`, `helm` and `pulumi` already
used — and the Dockerfile verifies the installed binary reports that tag. Both flavors were rebuilt,
because the Dockerfile change reaches both.

**The base and the host now agree about style by construction.** The republished images carry
fourmolu 0.19.0.1 and HLint 3.10, the versions the host source gate ran, and the derived image's build
context now carries `fourmolu.yaml` and `.hlint.yaml` at the root both tools search upward to. Before
that, the in-image `check-code` read whichever defaults its installed versions happened to hold, which
is the property the committed contract exists to remove.

### Sprint 23.11: The base supplies the family-pinned compiler [Done]

**Status**: Done
**Implementation**: `docker/basecontainer.Dockerfile`, `hostbootstrap/base_image.py`,
`tests/test_base_image.py`
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/development_plan_standards.md`,
`documents/engineering/base_image.md`, `documents/engineering/cabal_layout.md`,
`documents/languages/haskell.md`, `documents/engineering/testing.md`

#### Objective

The base installs `ghcup install ghc recommended`, which is 9.10.3, while `core/cabal.project` selects
9.12.4. Three things follow, and none of them is what § FF intended. `core/` cannot be configured inside
the image at all, because no `ghc-9.12.4` is on its `PATH` — the realized `linux-cpu` gate leg had to
mount a compiler in from outside. The warm Cabal store is keyed by compiler, so the store this image
exists to ship is one a core-pinned consumer cannot read. And `hostbootstrap-core` is compiled by two
different compilers depending on where it builds, only one of which the host static gate exercises.

§ FF is about *discovering* what consumers will resolve against, which is right for every other input
here and is what caught the MinIO archival in Sprint 23.10. The compiler is not that kind of input: it
keys what the base ships rather than being discovered by it, and this repository already pins it twice —
for the host and for the VM guest. § FF is amended to say so.

#### Deliverables

- GHC arrives as a build argument carrying the version the host bootstrapper already pins, and the image
  build verifies the installed compiler reports it — the verification every other pinned tool has.
- One constant reaches all three spellings, and a test asserts the two that cannot read it agree with it.
- § FF carves the compiler out of rolling selection and says why; the governed pages follow.
- The four places that already claim the base supplies the pinned compiler become true.

#### Validation

The phase's own gate: the full publication pipeline for both flavors. The Dockerfile's own
`grep -Fx` fails the build in place if GHCup hands back another version. The published image is then
observed to carry the pinned compiler and a store keyed to it.

#### Remaining Work

None. On 2026-09-14 both flavors were rebuilt and republished from the pinned tree — the digests in the
row above. The published images carry GHC 9.12.4 and a store at
`/opt/cache/cabal/store/ghc-9.12.4-5301`, which is the same ABI directory the host's own store uses.

The structural result is the one worth recording: `core/` now configures inside the published image. A
`cabal build all --dry-run` from `core/` in a container from the new CPU base resolves a complete plan on
the image's own compiler. Before the pin that was not a slow path or a cache miss — there was no
`ghc-9.12.4` in the image at all, so the project could not be configured there under any conditions.

Two limits found while confirming it, neither owned by this sprint. The image's toolchain lives under
`/root/.ghcup/bin`, so a container leg that runs as the host's uid cannot reach it even now that the
version agrees; a derived build is unaffected, because its `RUN` steps are root. And the compatibility
smoke's synthesized consumer sets no optimization, so it plans at `-O1` against a store built at `-O2`
and reports `requires build` where a real consumer — `core` and `demo` both set `optimization: 2` —
would reuse. Making the smoke set it would sharpen the probe.

The acceptance that follows this publication took 51m27s against a 53m25s pre-pin baseline. That is a
smaller gain than the change might suggest, and the reason is worth stating rather than dressing up:
`demo/cabal.project` pins no compiler, so the demo's in-image build was already matching whatever the
base shipped and already getting reuse. The pin's value is that `core/` became buildable there at all,
not that the demo got faster.

## Remaining Work

None.

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
