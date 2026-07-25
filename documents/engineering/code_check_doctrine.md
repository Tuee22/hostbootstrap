# Code-check doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [base_image.md](base_image.md), [derived_project_standards.md](derived_project_standards.md), [warm_store.md](warm_store.md), [../languages/haskell.md](../languages/haskell.md)

> **Purpose**: State the target rule that every image build, base or derived, gates on the project's
> canonical code-check, and distinguish that doctrine from the base image's incomplete current preflight.

## TL;DR

- The target is one fail-fast canonical code-check before any base or derived image can be produced.
- Derived images invoke the project binary's project-owned `check-code` body.
- The base image does not yet satisfy the full target: its host preflight checks Python and its
  Dockerfile smoke checks installed Haskell tools/sample sources, but repository Haskell source and
  tests are not part of that preflight.

Code quality is a **build-time guardrail**, distinct from behavioral tests. Under the finished doctrine,
every image this repo produces fails its build if the applicable canonical code-check fails.

## The rule

Every image build, base or derived, MUST gate completion on the project's
canonical code-check command. If the check exits non-zero, the image build
exits non-zero. No image is produced.

This applies in two places:

| Image | Where the check runs | Command |
|---|---|---|
| Base | Host preflight + Dockerfile smoke | **Current:** Python `ruff`/`black`/`mypy` only, then an in-image Haskell-tool smoke. **Target:** add the full Haskell source gate before Docker. |
| Derived | Dockerfile RUN step | `<project> check-code` — the inherited core verb whose body is project-defined |

## Base image

The base image currently has two checks, but they do not amount to the claimed full source gate:

* **Host pre-flight.** Building a base tag currently runs only
  `python -m hostbootstrap.check_code` (`ruff`, `black`, `mypy`) before `docker build`. It does not run
  the Haskell formatter/linter/build/test gate.
* **In-Dockerfile smoke.** After the warm Cabal store is built (the base bakes
  **no** `hostbootstrap` binary — see [base_image.md](base_image.md)), a single
  `RUN` step verifies that `fourmolu` and `hlint` actually start (catching install
  regressions) and runs them against the warm-store sample sources at
  [`core/warm-deps/core/app/`](../../core/warm-deps/core/app/) and
  [`core/warm-deps/daemon/app/`](../../core/warm-deps/daemon/app/)
  (catching sample drift).

The in-Dockerfile smoke cannot substitute for testing the repository's Haskell sources. The target
preflight runs Python checks/tests and the canonical Haskell check/tests (including documentation
validation) before Docker or push. See [build and release](build_release.md).

## Derived images

Every derived project that inherits `FROM ${BASE_IMAGE}` MUST add a single
`RUN` step that invokes its project's canonical code-check command. The step
runs:

* **After** the project's own CLI binary is installed to `/usr/local/bin/`
  (so the canonical entrypoint exists).
* **Before** any expensive downstream work (PGO, BOLT, foreign-backend
  compilation, large data ingestion).

The point of "before expensive work" is fail-fast latency. A style violation
should abort the image build in seconds, not after a multi-minute PGO/BOLT
pipeline.

## Why "fail-fast guardrail", not "test"

Code-check enforces **shape**: formatting, lint rules, custom forbidden
patterns, type-correctness. Tests enforce **behavior**.

Both must pass, but they live at different layers and have different cost
profiles. Code-check is fast and deterministic; running it during image build
shifts enforcement earlier and removes a class of "the container built but is
broken" outcomes. Tests run through the project binary (`<project> test run all` and
equivalents) — they verify the runtime, not the source. Container images expose
the project binary through a tini-wrapped `ENTRYPOINT`, so the binary receives
project arguments rather than a raw container command.

For a conforming derived project, the container image is the canonical artifact: if it exists, the
project-defined source gate passed during its build. This implication does not yet extend to the
repository Haskell sources merely because a base image exists.

## Current Status

Derived project Dockerfiles carry the project-binary `check-code` gate. The base build currently runs
the narrower Python host preflight and the in-image Haskell-tool/sample smoke described above. The
development plan owns the missing full Haskell repository gate; implementation state and evidence are
kept there rather than duplicated here.

## WRONG vs RIGHT

> **WRONG**
>
> Project `docker/Dockerfile`:
>
> ```dockerfile
> FROM ${BASE_IMAGE}
> COPY . /workspace/proj
> RUN cabal build --enable-tests all && install ... /usr/local/bin/proj
> RUN proj build native-backend
> ```
>
> No code-check anywhere. A container can be produced from source that fails
> `proj check-code`. Style violations only surface when someone manually runs
> the code-check gate — possibly never, in CI shortcuts.
>
> **RIGHT**
>
> ```dockerfile
> FROM ${BASE_IMAGE}
> COPY . /workspace/proj
> RUN cabal build --enable-tests all && install ... /usr/local/bin/proj
> RUN proj check-code
> RUN proj build native-backend
> ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/proj"]
> ```
>
> Code-check sits between the build install and the expensive backend
> compilation. A formatting regression fails the image build in seconds, never
> burns the PGO budget, and never reaches Docker Hub.

## What counts as the "canonical code-check" command

* **A `check-code` subcommand on the project binary.** `check-code` is a **core
  verb**: every binary inherits it from the `hostbootstrap-core` command tree, and
  its **body comes from the project's `ProjectSpec`**. The verb is the single
  fail-fast image-build gate; the project fills in the checks it should run
  (`fourmolu --mode check`, `hlint`, custom file-level checks, doc-drift checks).
  A derived project has no silent default check body: if it calls
  `runHostBootstrapCLI`, it must supply the action. The bare core binary uses the
  separate `runBareHostBootstrapCLI` entrypoint and is the only binary whose
  `check-code` intentionally reports no project checks. The base image still
  gates by invoking the formatter and linter directly (see "Base image"), because
  the full `hostbootstrap` source tree is not copied into the base image.
* **Multi-language projects.** A project's `check-code` body dispatches its
  per-language checks (the foreign-backend formatters/linters) in sequence and
  fails on any. The core verb supplies the inherited entrypoint and the fail-fast
  contract; the project supplies what runs inside it.

A project should expose **one** canonical entrypoint — its binary's `check-code`
subcommand — and the Dockerfile invokes that one. If you find yourself listing
five `RUN` steps for individual tools, fold them into `<project> check-code`
instead.

## See also

* [base_image.md](base_image.md) — Dockerfile rules (POSIX sh, no pipes, no
  buildx) that the code-check `RUN` step must also follow
* [derived_project_standards.md](derived_project_standards.md) — full rule
  set for derived projects
* [languages/haskell.md](../languages/haskell.md) — fourmolu and hlint
  versions, where the binaries live in the base image
