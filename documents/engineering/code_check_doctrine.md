# Code-check doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [base_image.md](base_image.md), [derived_project_standards.md](derived_project_standards.md), [warm_store.md](warm_store.md), [../languages/haskell.md](../languages/haskell.md)

> **Purpose**: State the rule that every image build, base or derived, gates on the project's
> canonical code-check, so an image with style or lint violations cannot be produced.

Code quality is a **build-time guardrail**, not a test-time check. Every image
this repo produces — the base image, and every derived project image — must
fail its build if the project's canonical code-check fails. An image with style
or lint violations is not buildable in the first place; it does not exist
long enough to be tested.

## The rule

Every image build, base or derived, MUST gate completion on the project's
canonical code-check command. If the check exits non-zero, the image build
exits non-zero. No image is produced.

This applies in two places:

| Image | Where the check runs | Command |
|---|---|---|
| Base | Host pre-flight + Dockerfile smoke | `fourmolu --mode check` + `hlint`, run directly |
| Derived | Dockerfile RUN step | `<project> check-code` — the inherited core verb whose body is project-defined |

## Base image

The base image enforces its own self-check in two layers:

* **Host pre-flight.** Building a base tag runs the canonical code-check over
  `hostbootstrap-core` (the Haskell library) and the thin Python bootstrapper
  **before** `docker build` runs. If anything fails the build exits with a
  one-line message for local reproduction and Docker is never invoked.
* **In-Dockerfile smoke.** After the warm Cabal store is built (the base bakes
  **no** `hostbootstrap` binary — see [base_image.md](base_image.md)), a single
  `RUN` step verifies that `fourmolu` and `hlint` actually start (catching install
  regressions) and runs them against the warm-store sample source at
  [`core/warm-deps/core/app/`](../../core/warm-deps/core/app/)
  (catching sample drift).

The split is deliberate: the full `hostbootstrap` source tree is **not** copied
into the base image, so dev tooling does not ship to every downstream. The host
pre-flight keeps source clean without polluting the image.

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
broken" outcomes. Tests run through the project binary (`<project> test all` and
equivalents) — they verify the runtime, not the source. Container images expose
the project binary through a tini-wrapped `ENTRYPOINT`, so the binary receives
project arguments rather than a raw container command.

A derived project's container image is the canonical artifact. If that
artifact exists, the source it was built from passes code-check by
construction. There is no separate "did the lint pass?" question to ask later.

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
> `hostbootstrap run test all` — possibly never, in CI shortcuts.
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
  its **body is project-defined**. The verb is the single fail-fast image-build
  gate; the project fills in the checks it should run (`fourmolu --mode check`,
  `hlint`, custom file-level checks, doc-drift checks). The bare core binary has
  no project checks, so its `check-code` passes with a message; a derived project
  extends the body with its own checks. The base image still gates by invoking the
  formatter and linter directly (see "Base image"), because the full
  `hostbootstrap` source tree is not copied into the base image.
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
