# Phase 23 — Base image publication and the opportunistic warm store

**Status**: Active
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
**Gate evidence**: 2026-10-16 ; `MacBookPro`, native arm64 macOS 26.6.2 (build 25G83),
Apple M1 Max, Colima 0.10.3, Docker client 29.3.0 / engine 29.2.1, GHC 9.12.4,
Cabal 3.16.1.0, Fourmolu 0.19.0.1, HLint 3.10, Poetry 2.3.2, Python 3.14.3 ;
repository Python-bootstrapper `poetry run hostbootstrap base build-and-push --flavor cpu --arch arm64`,
including complete source preflight, native build, local-image real-consumer smoke, rolling-tag
publication, explicit pull, and pulled-image real-consumer smoke,
`docker.io/tuee22/hostbootstrap:basecontainer-cpu-arm64` pulled as
`docker.io/tuee22/hostbootstrap@sha256:c5bedce2f8cc9bcdc82d46eedfda9bb10bbb2837b64d59258a777a18988590cf` ;
pass ; covers 01f1270d3cbc657325290f425e77e9492fa6ceef4e577a69891a2d1450e065b0
**Evidence covers**: `.dockerignore` `docker/basecontainer.Dockerfile` `docker/compatibility-smoke.Dockerfile`
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

### Sprint 23.1: Native rolling publication [Active]

**Status**: Active
**Implementation**: `docker/basecontainer.Dockerfile`, `hostbootstrap/base_image.py`,
`hostbootstrap/docker_ops.py`, `hostbootstrap/cli.py`, `.dockerignore`, `tests/test_cli.py`,
`tests/test_base_image.py`, `tests/test_docker_ops.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/base_image.md`, `documents/engineering/build_release.md`

#### Objective

One command, host-native, fully gated.

#### Deliverables

- `hostbootstrap base build-and-push --flavor <f> --arch <a>` is the canonical command: plain single-architecture
  `docker build` plus `docker push`, host-native, no buildx.
- The published tag is rolling: `basecontainer-<flavor>-<arch>`. A recorded digest identifies one publication but
  is not a locked-input or consumer-pinning contract.
- The requested architecture is validated against both the host and the Docker engine before publishing
  (`_validate_native_architecture` in `hostbootstrap/cli.py`), so an image cannot be pushed under the wrong
  architecture tag, including from an emulated or remote engine whose architecture differs from the host's.
- Publication runs the complete Python and Haskell gate first; a failing gate does not publish.
- A rebuild intentionally discovers current compatible upstream versions; it does not replay a committed input
  lock. The CUDA parent is the newest `cudnn-devel-ubuntu24.04` tag by numeric (major, minor, patch) order
  that carries the requested architecture.
- The base build's context is the repository root, and Docker anchors `.dockerignore` patterns to that root,
  so every build-state entry is written `**/`-prefixed and excludes nested build state (`core/dist-newstyle/`,
  `demo/dist-newstyle/`, `demo/.data/`, `demo/.build/`, nested `.hostbootstrap/`, Harness `.test_data/` run
  roots, and a `cabal.project.freeze` under `core/` or `demo/`), not only the copy at the root.

#### Validation

`hostbootstrap.test_all` covers the command shape, the architecture validation, and the gate ordering. Dated
evidence: a published rolling tag pulled and smoked against the real consumer on linux-cpu.

The sprint closes when these cases exist and pass under `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` (coverage at 100%), and the `demo/` leg `cabal test all` still
passes, because `demo/test/CommandsSpec.hs` reads the root `.dockerignore`:

- `tests/test_cli.py::test_native_architecture_requires_request_host_and_engine_match` also asserts that
  requested = host = `Arch.AMD64` with the engine stubbed to `Arch.ARM64` raises `click.ClickException`
  matching `must be native`.
- A `tests/test_base_image.py` case gives one architecture several candidates — an older tag listed first,
  plus a `12.9.x` and a `12.10.x` tag — and asserts `resolve_cuda_base_image` returns the `12.10.x` tag, so
  dropping the sort, sorting ascending, or sorting lexically each fails it.
- `tests/test_docker_ops.py::test_build_command_minimal_no_pull_no_target` asserts
  `cmd[-3:] == ("--file", "D", ".")` instead of the disjunctive tail check.
- A `tests/test_base_image.py` case reads the root `.dockerignore` and asserts each of `**/dist-newstyle/`,
  `**/.data/`, `**/.build/`, `**/.hostbootstrap/`, `**/.test_data/` and `**/cabal.project.freeze` is
  present and that no root-only spelling of those entries remains.

#### Remaining Work

- Rewrite the build-state entries of `.dockerignore` with a `**/` prefix, add `**/.test_data/`, replace the
  `cabal.project.freeze` comment with one that says patterns are context-root-anchored unlike `.gitignore`,
  and add the `.dockerignore` assertion case to `tests/test_base_image.py`.
- Add the engine-mismatch assertion to
  `tests/test_cli.py::test_native_architecture_requires_request_host_and_engine_match`.
- Add the multi-candidate CUDA ordering case to `tests/test_base_image.py`.
- Replace the disjunctive tail assertion in `tests/test_docker_ops.py::test_build_command_minimal_no_pull_no_target`
  with `cmd[-3:] == ("--file", "D", ".")`.

### Sprint 23.2: Publish → pull → real-consumer smoke [Active]

**Status**: Active
**Implementation**: `hostbootstrap/base_image.py`, `hostbootstrap/cli.py`, `hostbootstrap/docker_ops.py`, `docker/`,
`tests/test_base_image.py`, `tests/test_cli.py`, `tests/test_docker_ops.py`
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
- The pulled digest (`parse_digest_reference` in `hostbootstrap/docker_ops.py`) is exactly one `RepoDigests`
  string entry of the expected repository whose digest is `sha256:` followed by exactly 64 lowercase hex
  characters. `docker.io/` and `index.docker.io/` prefixes are elided before the repository comparison, and
  a reference with no `:tag` part (`localhost:5000/repo`) names its whole self as the repository.
- The compatibility consumer is not the demo: no module under `hostbootstrap/` names a `demo` path segment in
  any spelling, except the quality-gate roots `hostbootstrap/cli.py` names explicitly (`_FORMATTER_ROOTS`,
  `_LINTER_ROOTS`, and the demo legs of `_quality_gates`).

#### Validation

The smoke build against the pulled tag is the gate. Dated evidence is recorded with the publication.

The sprint closes when these cases exist and pass under `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` (coverage at 100%):

- `tests/test_docker_ops.py` cases for `parse_digest_reference`: a matching-repository entry with a 63-character
  digest and one with 64 non-hex characters (`"g" * 64`) each raise `RuntimeError` matching `exactly one`; a
  non-string entry beside the expected one (`[5, "<expected>"]`) returns the expected reference; an
  `index.docker.io/tuee22/hostbootstrap@sha256:<64 hex>` entry normalizes to the `docker.io/` reference; and the
  tag `localhost:5000/repo` with the entry `localhost:5000/repo@sha256:<64 hex>` returns that entry.
- `tests/test_base_image.py::test_python_owns_no_demo_path` parses each `hostbootstrap/*.py` module with `ast`
  and fails on any string constant that is `"demo"`, starts with `demo/` or `demo\\`, or contains `/demo/`,
  unless it sits inside the allow-listed `cli.py` assignments `_FORMATTER_ROOTS`, `_LINTER_ROOTS` or the body of
  `_quality_gates`; a fixture module containing `context / "demo" / "docker" / "Dockerfile"` is refused.

#### Remaining Work

- Tighten `parse_digest_reference` to `re.fullmatch(r"[0-9a-f]{64}", ...)` on the digest part and add the
  five `tests/test_docker_ops.py` cases above.
- Rewrite `tests/test_base_image.py::test_python_owns_no_demo_path` as the `ast`-based segment check with the
  named `cli.py` allow-list, so a `Path("demo") / "docker"` or `("demo", "docker")` spelling fails it.

### Sprint 23.3: The opportunistic warm store [Active]

**Status**: Active
**Implementation**: `core/warm-deps/`, `core/cabal.project`, `tests/test_base_image.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/warm_store.md`, `documents/engineering/cabal_layout.md`

#### Objective

Broad best-effort population, graceful misses.

#### Deliverables

- The warm store is populated broadly from the shared dependency set. The core manifest
  (`core/warm-deps/core/basecontainer-core-deps.cabal`) lists every direct non-boot, non-internal dependency of
  `hostbootstrap-core`, `crypton` included, so the core closure is warm by listing rather than by a transitive
  path.
- Consumers use the same host-compatible `cabal.project` inside and outside containers. There is no
  container-only project file and no base-owned freeze import, because the store is a cache and not a solver API.
- A cache miss resolves and builds online without failing the build.
- Top-level options in a `cabal.project` (`optimization`, `tests`, `benchmarks`, `shared`) reach only that
  project's local packages. `core/warm-deps/warm-store.config` therefore shapes the two stub packages and the
  solver plan, `core/cabal.project`'s `optimization: 2` shapes `hostbootstrap-core`, and store dependencies on
  both sides take Cabal's per-package defaults; the comments in both files say exactly that and claim no
  dependency-level alignment.
- The manifest descriptions state how each package reaches the store: `http-client` and `http-client-tls` reach
  the core closure transitively through `dhall`, and are not listed in the core manifest.
- `core/warm-deps/patches/README.md` carries the governed metadata block and states that nothing applies a file
  placed there: a patch takes effect only as a vendored package directory named in `core/warm-deps/cabal.project`
  `packages:`, which the Dockerfile's existing `COPY core/warm-deps/` carries into the build.

#### Validation

A derived build with a deliberately absent dependency resolves and builds. `cabal build all` from `demo/`
succeeds against both a warm and a cold store.

The sprint closes when a `tests/test_base_image.py` case parses every `build-depends` of
`core/hostbootstrap-core/hostbootstrap-core.cabal`, drops boot packages, `Win32` and `hostbootstrap-core`
internal libraries, and asserts each remaining package name appears in the core manifest's `build-depends`
(it fails today on `crypton`); `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` pass; and, because the manifest is a warm-store input, the
affected base tags are rebuilt, republished and pulled through this phase's gate.

#### Remaining Work

- Add `crypton` to `core/warm-deps/core/basecontainer-core-deps.cabal` `build-depends` and add the
  manifest-coverage case to `tests/test_base_image.py`.
- Rewrite the comment at `core/warm-deps/warm-store.config:1-5` and `core/cabal.project:8-10` to say top-level
  options reach only local packages, removing the claim that they align dependency builds for reuse.
- Rewrite the `http-client` note in `core/warm-deps/daemon/basecontainer-daemon-deps.cabal` to say the two
  packages reach the core closure transitively through `dhall`, not that the core manifest lists them.
- Rewrite `core/warm-deps/patches/README.md` with the metadata block and the vendored-package wiring above.

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
Cabal, `CABAL_DIR`, and `/opt/basecontainer/haskell-deps`, and its `cabal build --dry-run all`, which the
smoke of that date ran over the warm-store project at `/opt/basecontainer/haskell-deps` itself, resolved
`Up to date`. The smoke Sprint 23.8 owns resolves a synthesized consumer package instead, so its plan always
lists at least that local package as requiring a build. Only after that pass did the workflow push
`docker.io/tuee22/hostbootstrap:basecontainer-cpu-amd64`.

The push reported digest `sha256:e46fb5699af246dc631704cd9bba5020776a7e96fbba1f4c450b5b9971ffb9d5`.
The workflow pulled that tag, resolved the same repository digest, and cold-built the compatibility
consumer with BuildKit against the exact digest. The published-artifact smoke again observed GHC 9.10.3,
Cabal 3.16.1.0, the warm store, and an `Up to date` inherited-store resolution.

#### Remaining Work

None.

### Sprint 23.5: A committed style contract [Active]

**Status**: Active
**Implementation**: `fourmolu.yaml`, `.hlint.yaml`, `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`documents/engineering/code_check_doctrine.md`, `docker/basecontainer.Dockerfile`, `tests/test_base_image.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/code_check_doctrine.md`, `documents/languages/haskell.md`

#### Objective

§ R says the style contract is committed rather than defaulted. A committed configuration fixes every
option the formatter and the linter expose, so a base rebuild cannot change what passes through a changed
default. It does not fix the tool versions: the rolling base installs the current compatible `fourmolu` and
`hlint` (§ FF), and a newer release can add a default hint or change output under identical options. The
configuration removes option drift, not tool-version drift.

#### Deliverables

- `fourmolu.yaml` and `.hlint.yaml` are committed at the repository root.
- Their settings are chosen to match the existing sources as closely as possible, so the reformat that follows is as small as it can be.
- The code-check doctrine names them as the contract and stops describing style as a property of the installed tool.
- No source is reformatted in this sprint. The only source edits are the two defect families the linter names
  and the configuration does not decline: eight unused `LANGUAGE` pragmas and twelve duplicate imports of one
  module in one scope.
- Each file's header comment states what the file fixes and what it does not: it fixes the configurable options,
  the tool versions roll with the base, and `.hlint.yaml` is read for `demo/` sources too (by the host source
  gate's linter legs over `demo/src` and `demo/app`, and by the derived image's `check-code`), so its declined
  families apply to the consumer as well. Adoption-time measurements are stated with their date.
- The base build's style sample check reads the committed contract: `docker/basecontainer.Dockerfile` copies
  `fourmolu.yaml` and `.hlint.yaml` into `/opt/basecontainer/haskell-deps/` before the `RUN` step that runs
  `fourmolu --mode check core/app daemon/app` and `hlint core/app daemon/app` there, so both tools find the
  committed options by searching upward rather than running on their installed defaults.

#### Validation

The two configuration files are committed at the repository root. `fourmolu` finds its file by searching
upward from the directory of the first path it is given; `hlint` searches its working directory and that
directory's ancestors, then the home directory, and never looks at where the paths it is given sit. The
repository source gate runs both with the repository root as working directory on root-relative paths, so both
read the committed files. The formatter settings are written out in full and are the measured best
match on 2026-09-13: of the 190 library, sublibrary and consumer modules then present, 74 were already
byte-identical under them, against 0 for 2-space indentation with leading module headers, 6 for single-line
Haddock, 20 for leading function arrows and 10 for leading import/export lists. The linter configuration keeps
hlint's default rule set and names 51 hint families the library's conventions decline, grouped by the reason.
Six duplicate-import findings are declined in configuration rather than in source, because hlint does not
evaluate CPP and reads the two halves of an `#if`/`#else` as one scope; merging them would import a
Windows-absent name on Windows.

On 2026-09-13 `hlint` over the library, its sublibraries, its application and the worked consumer reported
`No hints`. The source corrections (the pragmas and the duplicate imports) are covered by the host static gate
run Sprint 23.6 records on the same date, at 2,536 core and 150 demo cases.

The sprint closes when the two header comments below are rewritten and the host static gate (§ JJ) passes;
the comments carry no behavioural test, and they are reviewed against `_LINTER_ROOTS` in `hostbootstrap/cli.py`
and the `HASKELL_STYLE_TOOLS_DIR` install step in `docker/basecontainer.Dockerfile`. It also needs a
`tests/test_base_image.py` case that reads `docker/basecontainer.Dockerfile` and asserts a `COPY` of each of
`fourmolu.yaml` and `.hlint.yaml` into `/opt/basecontainer/haskell-deps/` precedes the line running
`fourmolu --mode check`, and, because the Dockerfile is a base input, this phase's gate rebuilding,
republishing and pulling the affected tags with that sample check passing.

#### Remaining Work

- Rewrite the header of `.hlint.yaml` (lines 3-7) and of `fourmolu.yaml` (lines 3-8) to say the file fixes the
  configurable options while the tool versions roll with the base, removing "the gate's verdict is a property
  of this repository" and "A tool upgrade that changes a default now changes nothing here".
- Rewrite the `demo/` paragraph of `.hlint.yaml` (lines 15-18) to say `demo/` is linted with this same file by
  the host source gate and the container `check-code`, so every declined family applies to it, and that it
  currently contains no instance of them.
- Rewrite the measurement paragraph of `fourmolu.yaml` (lines 10-15) in the past tense with the 2026-09-13
  adoption date, and add that every formatter-readable module now matches except the modules
  `_FORMATTER_UNREADABLE` in `hostbootstrap/cli.py` names.
- Add `COPY fourmolu.yaml /opt/basecontainer/haskell-deps/fourmolu.yaml` and
  `COPY .hlint.yaml /opt/basecontainer/haskell-deps/.hlint.yaml` to `docker/basecontainer.Dockerfile` ahead of
  the style sample `RUN` step, and add the ordering case to `tests/test_base_image.py`.

### Sprint 23.6: The repository's Haskell sources meet the committed style [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core`, `demo`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/code_check_doctrine.md`

#### Objective

Bring the existing Haskell sources to the committed style. The reformat is formatting apart from three
named changes it forces, and naming them is what lets a reviewer separate the semantic content from the
reformatted files: no import change and no export change beyond them.

#### Deliverables

- The formatter is applied in place to the core package's `src`, `internal`, `app` and `test` roots and to the
  worked consumer's `src`, `app` and `test` roots. The `provider-live` suite root is brought to the style by
  Sprint 23.7, which owns the formatter's root set.
- The change is formatting except for the three non-formatting edits recorded below: the re-frozen source-guard
  constants, the re-expressed rooted-transport baseline, and positional elimination of `MeasuredInstance`.
- The reformat is not isolated in a commit of its own; those three named edits are the content a reviewer
  separates from it.

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

### Sprint 23.7: The source gate runs the formatter and the linter [Active]

**Status**: Active
**Implementation**: `hostbootstrap/cli.py`, `tests/test_cli.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/code_check_doctrine.md`, `documents/engineering/build_release.md`

#### Objective

§ R places the library and the consumer inside the style contract, and the repository's source gate is what
makes that mechanical: it runs the formatter and the linter over the Haskell roots both Cabal projects
declare, ahead of the warning-clean Cabal legs.

#### Deliverables

- The source gate runs a formatter check over every Haskell source root the two Cabal projects declare — the
  core package's `src`, `internal`, `app`, `test` and `provider-live` roots and the consumer's `src`, `app` and
  `test` roots — and a linter step over the library and consumer source roots (`_FORMATTER_ROOTS` and
  `_LINTER_ROOTS` in `hostbootstrap/cli.py`).
- They run before the expensive Cabal legs, so a style regression fails in seconds rather than after a full build.
- Linter findings are triaged into accepted hints and justified configuration entries — never a per-module compiler suppression, of which the library currently has none.
- The gate's failure message names which check failed and over which root.
- A test derives the root set from the `hs-source-dirs` of `core/hostbootstrap-core/hostbootstrap-core.cabal`
  and `demo/hostbootstrap-demo.cabal`, so a suite root a Cabal file declares and the formatter does not read
  fails the Python suite.

#### Validation

`_style_gates` contributes one formatter gate per root in `_FORMATTER_ROOTS` and five linter gates over the
library, its sublibraries, its application and the consumer's sources. Each gate's label names the check and the
root it read. They are placed ahead of the four Cabal legs in `_quality_gates`, and a test pins that ordering
rather than trusting the literal order of the tuple. On 2026-09-13 every gate exited 0 against the clean tree
over 797 files in seven roots, and appending a misformatted declaration to `core/hostbootstrap-core/app/Main.hs`
made the formatter gate for that root exit 100 until it was removed.

The sprint closes when a `tests/test_cli.py` case reads every `hs-source-dirs` entry of both Cabal files, maps
each to its top-level directory under the package (`internal/effect` to `internal`), and asserts each is covered
by a `_FORMATTER_ROOTS` entry (it fails today on `provider-live`); `fourmolu --mode check` exits 0 over the four
`core/hostbootstrap-core/provider-live/*.hs` modules; and the host static gate (§ JJ) passes.

#### Remaining Work

- Add `("core", "hostbootstrap-core", "provider-live")` to `_FORMATTER_ROOTS` in `hostbootstrap/cli.py`.
- Format the four `core/hostbootstrap-core/provider-live` modules in place (formatting only; any guard constant
  that measures them is re-frozen and named, as Sprint 23.6 does).
- Add the Cabal-derived root-coverage case to `tests/test_cli.py`.

### Sprint 23.8: The compatibility smoke asks a consumer's question [Active]

**Status**: Active
**Implementation**: `docker/compatibility-smoke.Dockerfile`, `hostbootstrap/base_image.py`, `tests/test_base_image.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/base_image.md`, `documents/engineering/warm_store.md`

#### Objective

The smoke is the last gate between a rebuilt base and the registry, and it asks whether a derived project can
use the image. Re-resolving the base's own warm-store package set is close to tautological, and so is any
consumer whose dependency closure is contained in the store's: the question has to reach past the store.

#### Deliverables

- The smoke writes a consumer package of its own (its own name, version and dependency list) and resolves a
  build plan for it with `cabal build --dry-run all`. Beside store packages it depends on at least one Hackage
  package absent from the store's package database, so its closure is not contained in the store's, and it
  writes a `cabal.project` with `packages: .` and `optimization: 2`, the project setting `core/` and `demo/`
  both carry.
- A plan that names downloads is a pass and a plan that cannot be produced is the failure, because the warm
  store is an opportunistic cache rather than a lock.
- The toolchain and the store are separate `RUN` steps with separate messages: one starts `ghc` and `cabal`;
  the other requires `$CABAL_DIR`, a store directory `$CABAL_DIR/store/ghc-<ghc --numeric-version>-*`, and at
  least one registered `package.db/*.conf` in it, so a store keyed to another compiler fails the build.
- A third step starts `fourmolu` and `hlint`, since the doctrine treats their presence as part of what the
  base guarantees.
- Its comments list only what each step checks, say the style tools also run in the host source gate, the base
  build's sample check and every derived project's container `check-code`, and cite this phase by name.
- Where the smoke's Dockerfile header, the `compatibility_smoke_spec` docstring in `hostbootstrap/base_image.py`
  and the docstring of `test_compatibility_smoke_consumer_needs_only_the_base_image` explain why the consumer is
  not the demo, they name what `demo/docker/Dockerfile` requires: the `hostbootstrap-builder` named build
  context, the `hostbootstrap-build-config` secret, and the `check-code` step's one-`RUN` presentation of the
  `hostbootstrap-build-channel`, `hostbootstrap-build-verification` and `hostbootstrap-build-coordinator`
  secrets.

#### Validation

The smoke build itself, against a freshly built local image and again against the pulled digest, which
is what this phase's gate already requires.

The sprint closes when the smoke passes in both positions of this phase's gate; a negative run against a
throwaway image `FROM` the local base that renames `$CABAL_DIR/store/ghc-*` to `ghc-0.0.0-x` fails at the
store step with that step's message, recorded here with its date; and a `tests/test_base_image.py` case reads
`docker/compatibility-smoke.Dockerfile` and asserts the toolchain and store checks sit in different `RUN`
instructions, the synthesized `cabal.project` sets `optimization: 2`, and the consumer's `build-depends` names a
package that is absent from both `core/warm-deps` manifests.

#### Remaining Work

- Split the first `RUN` of `docker/compatibility-smoke.Dockerfile` into a toolchain step (`ghc --version`,
  `cabal --version`) and a store step that runs
  `set -- "${CABAL_DIR}/store/ghc-$(ghc --numeric-version)-"*; test -d "$1"; set -- "$1"/package.db/*.conf; test -f "$1"`,
  each with its own message; drop the `/opt/basecontainer/haskell-deps` check from the store step's claim.
- Add one Hackage leaf package absent from the store to the consumer's `build-depends` (confirm absence with
  `ghc-pkg --package-db "${CABAL_DIR}/store/ghc-<ver>-<abi>/package.db" list` on the published image before
  choosing it), and write `/tmp/compatibility-smoke/cabal.project` with `packages: .` and `optimization: 2`.
- Rewrite the comments: the store comment names only what is checked; the style-tool comment says the tools also
  run in the host source gate (`_style_gates` in `hostbootstrap/cli.py`) and in the base build's sample check;
  the header cites the base-image-and-warm-store phase by name rather than as "Phase 23".
- Add the static `tests/test_base_image.py` case above and record the dated negative store run.
- Rewrite the `compatibility_smoke_spec` docstring in `hostbootstrap/base_image.py`, the docstring of
  `tests/test_base_image.py::test_compatibility_smoke_consumer_needs_only_the_base_image` and the "NOT the
  demo's Dockerfile" paragraph of `docker/compatibility-smoke.Dockerfile` to name the demo Dockerfile's
  requirements as listed above, replacing "four ``required=true`` secrets, two of which are a signed one-use
  build grant" and dropping the test docstring's account of a previous consumer.

### Sprint 23.9: The bootstrapper's image surface is typed [Active]

**Status**: Active
**Implementation**: `hostbootstrap/base_image.py`, `hostbootstrap/docker_ops.py`, `tests/test_docker_ops.py`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/base_image.md`

#### Objective

The publication surface carries only what the publication pipeline calls, and its types make the wrong request
unrepresentable: no flavor selector without a caller, no resource cap on a builder that ignores it, no type
suppression, and no second `docker run` vocabulary whose mount rendering mixes host and guest path grammars.

#### Deliverables

- There is no substrate-to-flavor selector: the Python bootstrapper builds no derived image, and the base build
  takes its flavor as an explicit argument.
- A build carries one `Builder`: `BuildKitBuilder`, which has no field on which to request `--memory`/`--cpu-*`,
  or `ClassicBuilder`, the only builder that honours them and the only place a cap can be written.
- The package carries no type suppression.
- `hostbootstrap/docker_ops.py` holds only the vocabulary the publication pipeline calls. `RunSpec`,
  `run_command`, `tag_command`, `image_exists_command`, `image_exists`, `image_entrypoint_command`,
  `image_entrypoint` and `parse_image_entrypoint` have no production caller and are deleted with their tests;
  `_NO_ENV` goes with `RunSpec`, its only user.

#### Validation

The host static gate, with coverage at 100%.

`substrate_to_flavor` is absent and has no test; `BuildSpec` carries a `Builder` and `_has_resource_caps` is
absent; `hostbootstrap/` carries no `type: ignore`. Coverage is 100% with no omissions.

The sprint closes when `grep -rnw` over `hostbootstrap/` and `tests/` finds none of the eight deleted names,
`poetry run python -m hostbootstrap.check_code` passes, and `poetry run python -m hostbootstrap.test_all` passes
with coverage at 100%.

#### Remaining Work

- Delete `RunSpec`, `run_command`, `tag_command`, `image_exists_command`, `image_exists`,
  `image_entrypoint_command`, `image_entrypoint`, `parse_image_entrypoint` and `_NO_ENV` from
  `hostbootstrap/docker_ops.py`, and delete `test_run_command_one_shot_rm_with_mounts`,
  `test_run_command_detached_service`, `test_parse_image_entrypoint`, `test_image_exists_false` and the
  `tag`/`exists`/`entrypoint` assertions of `test_push_tag_inspect_commands` and
  `test_async_wrappers_delegate_to_process` in `tests/test_docker_ops.py`.

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

The phase's own gate. It is an outward-facing publication that agents run as required.

#### Remaining Work

None. On 2026-09-13 the pipeline ran end to end for both flavors. Each run discovered current compatible
upstream versions, passed the complete source gate — now including the seven formatter and five linter
legs ahead of the four Cabal legs — cold-built the rolling tag with the classic builder under the host's
measured caps, proved the consumer smoke against the immutable local image ID, pushed, pulled the tag
back, and proved the smoke again against the pulled digest. Those 2026-09-13 digests are not recorded: Sprint
23.11's pinned republication replaced both tags the next day, and the amd64 gate-evidence row above names GHC
9.12.4 and the digests of that republication.

**The first attempt failed, and the failure was the point.** `dl.min.io` answered `410 Gone` for the
MinIO client: the open-source server, client and KES projects were archived and every community release
stopped being served. A rebuild that discovers current upstream versions is exactly what finds that, and
it found it before the registry was mutated rather than after. The client now resolves from the
project's own GitHub releases by tag — the same shape `kind`, `kubectl`, `helm` and `pulumi` already
used — and the Dockerfile verifies the installed binary reports that tag. Both flavors were rebuilt,
because the Dockerfile change reaches both.

**The base and the host agree about style options by construction and about tool versions on the
publication date.** The derived image's build context carries `fourmolu.yaml` and `.hlint.yaml` at the root
both tools search upward to, so the in-image `check-code` and the host source gate read the same options. The
republished images carry fourmolu 0.19.0.1 and HLint 3.10, the versions the host source gate ran that day; the
base installs both unpinned (§ FF), so a later republication can carry newer versions than the host gate runs.

### Sprint 23.11: The base supplies the family-pinned compiler [Active]

**Status**: Active
**Implementation**: `docker/basecontainer.Dockerfile`, `docker/compatibility-smoke.Dockerfile`,
`hostbootstrap/base_image.py`, `tests/test_base_image.py`
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
- The pinned toolchain is reachable by any uid: GHCup installs under a world-readable prefix outside `/root`
  (`GHCUP_INSTALL_BASE_PREFIX=/opt/ghcup`, so `PATH` names `/opt/ghcup/.ghcup/bin` instead of
  `/root/.ghcup/bin`), and a container leg that runs as the host's uid starts the same `ghc` and `cabal` a
  root `RUN` step does.
- Every version probe in `docker/basecontainer.Dockerfile` compares a command-substitution result rather than
  piping into `grep` (`v="$(ghc --numeric-version)"; test "$v" = "${GHC_VERSION}"` for an exact match, a
  `case "$v" in *"${X}"*) ;; *) exit 1 ;; esac` for a substring match), so a probe that exits non-zero fails
  the build under `set -eu` as `documents/engineering/base_image.md` requires.
- The Dockerfile header names the three classes of input: resolved on the host by `hostbootstrap/base_image.py`
  (Go, Node, PureScript, kind, kubectl, Helm, MinIO client, Pulumi, the AWS CLI URL, the CUDA parent), rolling
  at `docker build` time inside the Dockerfile (nvkind `@latest`, Cabal `recommended`, unversioned `fourmolu`
  and `hlint`, npm globals, Playwright browsers, pip and Poetry, Rust `stable`), and pinned (GHC through
  `GHC_VERSION`, LLVM through `LLVM_MAJOR`).

#### Validation

The phase's own gate: the full publication pipeline for both flavors. The Dockerfile's own exact-version
check fails the build in place if GHCup hands back another version. The published image is then observed to
carry the pinned compiler and a store keyed to it.

On 2026-09-14 both amd64 flavors are rebuilt and republished from the pinned tree; the amd64 gate-evidence row
above names their digests. The published images carry GHC 9.12.4 and a store at
`/opt/cache/cabal/store/ghc-9.12.4-5301`, the same ABI directory the host's own store uses, and a
`cabal build all --dry-run` from `core/` in a container from the CPU base resolves a complete plan on the
image's own compiler. The acceptance that follows this publication takes 51m27s against a 53m25s pre-pin
baseline: `demo/cabal.project` pins no compiler, so the demo's in-image build already matched the base's
compiler; the pin's value is that `core/` configures in the image at all.

On 2026-10-16, the native Apple visit republishes the CPU/arm64 rolling tag as the prerequisite for
Sprint 26.7. The canonical command above exits 0 at 15:14 UTC after its complete source preflight,
native Docker build, local-image consumer smoke, push, explicit pull, and published-image consumer
smoke. The pulled image is Linux/arm64, supplies GHC 9.12.4 and Cabal 3.16.1.0, and selects
Fourmolu 0.19.0.1 and HLint 3.10. Its warm store uses the image's `ghc-9.12.4-bc61` ABI directory.
Only `basecontainer-cpu-arm64` is republished during this visit; the historical amd64 CPU/CUDA
publication above is retained. The unchanged 13-file publication scope independently remeasures to
`01f1270d3cbc657325290f425e77e9492fa6ceef4e577a69891a2d1450e065b0`.

The sprint closes when a `docker/compatibility-smoke.Dockerfile` step runs
`setpriv --reuid=65534 --regid=65534 --clear-groups -- ghc --numeric-version` and the same for `cabal`, and
passes against the local image and the pulled digest; a `tests/test_base_image.py` case reads
`docker/basecontainer.Dockerfile` and asserts no line pipes into `grep`, `PATH` names no `/root/.ghcup`
directory, and the header names `GHC_VERSION` and `LLVM_MAJOR` as the pinned inputs; and this phase's gate
republishes the affected tags, since the Dockerfile is a base input.

#### Remaining Work

- Install GHCup, GHC and Cabal under `GHCUP_INSTALL_BASE_PREFIX=/opt/ghcup` in `docker/basecontainer.Dockerfile`
  and replace `/root/.ghcup/bin` in its `ENV PATH` with `/opt/ghcup/.ghcup/bin`; add the non-root `setpriv`
  toolchain step to `docker/compatibility-smoke.Dockerfile`.
- Rewrite the nine `<probe> | grep` checks of `docker/basecontainer.Dockerfile` (the Go, Node, PureScript,
  kind, kubectl, Helm, MinIO client, Pulumi and GHC probes) as command-substitution comparisons.
- Rewrite the header comment of `docker/basecontainer.Dockerfile` with the three input classes above.
- Add the static `tests/test_base_image.py` case above.

## Remaining Work

- Sprint 23.1: anchor `.dockerignore` build-state entries with `**/`, and pin the engine-mismatch, CUDA-ordering and `--file` tail cases.
- Sprint 23.2: tighten the pulled-digest parser to 64 hex characters with its missing cases, and make the no-demo-path guard a segment check.
- Sprint 23.3: list `crypton` in the core manifest with a coverage test, and correct the warm-store, project, daemon-manifest and patches comments.
- Sprint 23.5: narrow the `fourmolu.yaml` and `.hlint.yaml` headers to option drift, the demo scope and the dated adoption measurement, and copy both files beside the base build's style sample check.
- Sprint 23.7: add the `provider-live` root to the formatter gate, format its modules, and derive the root set from the Cabal files in a test.
- Sprint 23.8: split the smoke's toolchain and compiler-keyed store checks, reach past the store's closure with `optimization: 2`, and correct its comments and the demo-secrets account in its docstrings.
- Sprint 23.9: delete the uncalled `docker run`/tag/inspect vocabulary from `hostbootstrap/docker_ops.py`.
- Sprint 23.11: make the toolchain reachable by a non-root uid, replace the base Dockerfile's `grep` pipelines, name its three input classes, and republish the affected tags through this phase's gate.

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
