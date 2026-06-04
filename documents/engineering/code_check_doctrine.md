---
name: engineering-code-check-doctrine
description: Code-quality checks run during image build, base and derived. Fail-fast guardrails.
type: standard
---

# Code-check doctrine

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
| Base | Host pre-flight + Dockerfile smoke | `hostbootstrap.check_code:main` + `fourmolu --mode check` + `hlint` |
| Derived (Haskell) | Dockerfile RUN step | `<project> check-code` |
| Derived (any language) | Dockerfile RUN step | the project's canonical lint/format/type command |

## Base image

The base image enforces its own self-check in two layers:

* **Host pre-flight.** `hostbootstrap base build` and `hostbootstrap base
  build-and-push` invoke
  [`hostbootstrap.check_code.main`](../../hostbootstrap/check_code.py) (ruff
  → black → mypy strict) **before** `docker build` runs. If anything fails the
  CLI exits with a one-line message pointing at `poetry run python -m
  hostbootstrap.check_code` for local reproduction. Docker is never invoked.
* **In-Dockerfile smoke.** After the warm Cabal store is built, a single `RUN`
  step verifies that `fourmolu` and `hlint` actually start (catching install
  regressions) and runs them against the warm-store sample source at
  [`support/haskell-deps/app/`](../../support/haskell-deps/) (catching sample
  drift).

The split is deliberate: hostbootstrap's own source (Python) is **not** copied
into the base image, and we do not want to bake Poetry's dev tooling into a
container that ships to every downstream. The host pre-flight keeps source
clean without polluting the image.

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
broken" outcomes. Tests run inside the built image (`hostbootstrap run test all`
and equivalents) — they verify the runtime, not the source. Container images
should expose the project command through a tini-wrapped `ENTRYPOINT`, so
`hostbootstrap run` receives project arguments rather than a raw container
command.

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

* **Haskell projects using the `mcts`-style pattern.** A single `check-code`
  subcommand on the project's own CLI that wraps `fourmolu --mode check`,
  `hlint`, custom file-level checks, and doc-drift checks. The MCTS reference
  is at
  [`MCTS/src/MCTS/CheckCode.hs`](https://example.invalid/MCTS/src/MCTS/CheckCode.hs).
* **Python-only projects.** A `check_code.py` module pattern matching
  [`hostbootstrap.check_code`](../../hostbootstrap/check_code.py): ruff →
  black → mypy strict, fail-fast.
* **Multi-language projects.** A top-level entrypoint that dispatches the
  per-language checks in sequence and fails on any.

A project should expose **one** canonical entrypoint per project, and the
Dockerfile invokes that one. If you find yourself listing five `RUN` steps
for individual tools, build a single `<project> check-code` command instead.

## See also

* [base_image.md](base_image.md) — Dockerfile rules (POSIX sh, no pipes, no
  buildx) that the code-check `RUN` step must also follow
* [derived_project_standards.md](derived_project_standards.md) — full rule
  set for derived projects
* [languages/haskell.md](../languages/haskell.md) — fourmolu and hlint
  versions, where the binaries live in the base image
