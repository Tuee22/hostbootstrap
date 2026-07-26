# Phase 12: Opportunistic Cabal warm store

**Status**: Authoritative source
**Supersedes**: The layered-freeze and reproducible-base form of this phase
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[system-components.md](system-components.md),
[phase-6-base-image-and-thin-python-bootstrapper.md](phase-6-base-image-and-thin-python-bootstrapper.md),
[phase-13-hostbootstrap-demo.md](phase-13-hostbootstrap-demo.md)

> **Purpose**: Populate the rolling base image with a broad best-effort Cabal cache while keeping one
> ordinary, host-compatible consumer project for host-native and container builds.

## Phase Status

**Status**: Done

Sprint 12.4 reconciled the repository from the short-lived locked-input/layered-freeze design to the
rolling policy on 2026-07-25. Sprints 12.1–12.3 remain historical implementation evidence; their freeze
projection and guaranteed-hit claims are explicitly superseded.

## Remaining Work

None. A fresh registry publication and live real-consumer compatibility smoke remain operator evidence
for the next authorized publish, not a completion requirement for this no-publish policy correction.

## Phase Objective

The base build intentionally discovers current/latest compatible upstream versions. It warms a broad
Cabal store from maintainable dependency manifests, but the store is a performance optimization only.
Consumers use one `cabal.project` unchanged on the host and in a derived container. They do not import
base-owned freezes or project fragments, and a missing or incompatible store artifact may be resolved,
downloaded, and compiled normally.

TLS and integrity metadata remain desirable for direct downloads where practical. They do not create a
committed input-lock or replayability contract. Neither an offline build nor a complete cache hit is a
phase acceptance requirement.

## Sprints

### Sprint 12.1: Broad warm-store manifests [Done, historical]

**Status**: Done, historical
**Implementation**: `core/warm-deps/core/basecontainer-core-deps.cabal`,
`core/warm-deps/daemon/basecontainer-daemon-deps.cabal`, `core/warm-deps/cabal.project`,
`core/warm-deps/warm-store.config`, `docker/basecontainer.Dockerfile`
**Docs to update**: `documents/engineering/warm_store.md`,
`documents/engineering/base_image.md`

#### Objective

Collect the shared/core/web and daemon-family dependency sets into explicit build-only packages so a
base build can populate one Cabal store.

#### Deliverables

- The two manifest packages remain organizational cache-population inputs.
- Their names do not define consumer layers, freezes, or public version contracts.
- `cabal.project` builds both manifests into the same store with the intended compilation ways.

#### Validation

Manifest syntax and dependency coverage were validated in the original sprint. Sprint 12.4 revalidates
the retained single-project form.

#### Remaining Work

None. The later per-layer freeze projections were removed by Sprint 12.4.

### Sprint 12.2: Consumer-layer freeze projection [Superseded]

**Status**: Superseded by Sprint 12.4
**Implementation**: Historical `core.project`, `daemon.project`, `core.freeze`, and `daemon.freeze`
projection
**Docs to update**: `legacy-tracking-for-deletion.md`

#### Objective

Historical objective: project separate core and daemon freeze fragments from the shared store.

#### Deliverables

None current. Consumer freeze fragments and their project files are deletion obligations because the
base store is not a solver API.

#### Validation

Historical freeze-partition checks are not current acceptance evidence.

#### Remaining Work

None beyond Sprint 12.4's deletion and documentation record.

### Sprint 12.3: Expand the shared web dependency set [Done, historical]

**Status**: Done, historical
**Implementation**: `core/warm-deps/core/basecontainer-core-deps.cabal`
**Docs to update**: `documents/engineering/warm_store.md`

#### Objective

Include the real demo/core web-build dependencies in the broad warm-store population set.

#### Deliverables

- `purescript-bridge` and the shared web stack remain represented in the cache-population manifest.
- Presence in the manifest is a best-effort optimization and does not guarantee a consumer cache hit.

#### Validation

The manifest was solver-valid at landing. Sprint 12.4 validates the retained project and fast consumer
builds without an offline/full-hit requirement.

#### Remaining Work

None.

### Sprint 12.4: Rolling inputs, one consumer project, and graceful cache misses [Done]

**Status**: Done
**Implementation**: `hostbootstrap/base_image.py`, `hostbootstrap/cli.py`,
`docker/basecontainer.Dockerfile`, `core/warm-deps/cabal.project`,
`core/warm-deps/warm-store.config`, `demo/cabal.project`, `demo/docker/Dockerfile`,
`tests/test_base_image.py`, `tests/test_warm_store.py`, `tests/test_cli.py`
**Docs to update**: `README.md`, `documents/README.md`,
`documents/architecture/build_and_run_model.md`, `documents/engineering/base_image.md`,
`documents/engineering/build_release.md`, `documents/engineering/cabal_layout.md`,
`documents/engineering/derived_dockerfile.md`,
`documents/engineering/derived_project_standards.md`,
`documents/engineering/warm_store.md`, relevant language/runbook documents,
`development_plan_standards.md`, `00-overview.md`, `README.md`, `system-components.md`,
Phases 6/11/13/21, and `legacy-tracking-for-deletion.md`

#### Objective

Remove the reproducible-base and layered-freeze doctrine while preserving native architecture checks,
source gates, the rolling published-tag pull workflow, and useful warm-store performance.

#### Deliverables

- `base_image.py` resolves current compatible upstream versions and URLs during each build workflow.
  CPU builds use the rolling Ubuntu parent; CUDA builds select the latest compatible native-architecture
  CUDA parent.
- No committed `docker/base-inputs.json` or equivalent version replay manifest exists.
- The Dockerfile installs current/recommended Haskell and stable Rust toolchains plus current compatible
  package-manager tools, over TLS and with available direct-download integrity checks where practical.
- `core/warm-deps/cabal.project` is the only warm-store project. It builds both organizational manifests
  into one Cabal store and generates no consumer freeze.
- `demo/cabal.project` is used unchanged for host-native and container builds. The demo Dockerfile does
  not copy or swap a container-specific project and does not force `--offline`.
- The synthetic offline/freeze verifier and reusable host/core-container/daemon-container templates are
  removed.
- After an operator-authorized publish, the workflow pulls the rolling tag and builds the real demo
  Dockerfile as a compatibility smoke. A resolved digest may bind that build invocation but is not
  reproducibility evidence or a consumer contract.
- Focused tests prove dynamic resolution, one-project use, absence of freeze imports/project swapping,
  and the fact that normal online solving remains available on cache misses.

#### Validation

Validated 2026-07-25:

- `poetry run python -m hostbootstrap.check_code`
- `poetry run python -m coverage run -m hostbootstrap.test_all`
- `poetry run python -m coverage report -m` at the configured 100% threshold
- `cabal build all --ghc-options=-Werror` and `cabal test all --ghc-options=-Werror` from `core/`
- the same fast build/test commands from `demo/`
- governed-document stale-doctrine search covering locks, templates, container-only projects, freeze
  imports, reproducibility, mandatory offline builds, and guaranteed cache hits

Results: Python code checks passed; 220 Python tests passed at 100% statement coverage; core built under
`-Werror` and all 382 tests passed; demo built under `-Werror` and its 101 tests plus the embedded 382
core tests passed. Live release metadata resolved CPU/arm64 inputs (Go 1.26.5, Node v24.18.0,
PureScript v0.15.16, kind v0.32.0, kubectl v1.36.3, Helm v4.2.3, Pulumi v3.254.0) and selected
`nvidia/cuda:13.3.0-cudnn-devel-ubuntu24.04` for CUDA/arm64.

An actual base rebuild/publish/pull/live compatibility smoke is pending operator-facing evidence because
this sprint was not authorized to publish. It was not substituted with a local same-named image or an
offline synthetic proof.

#### Remaining Work

None.

## Documentation Requirements

- Engineering and architecture documents describe rolling selection, the one-project consumer path,
  and opportunistic cache semantics as current behavior.
- Historical locked/freeze surfaces are named only in the cleanup ledger or explicitly marked
  superseded history.
- Examples never import `/opt/basecontainer/...` project/freeze files and never promise offline or
  complete-hit behavior.
- Publication documentation distinguishes a rolling tag and per-build digest from reproducible inputs.
