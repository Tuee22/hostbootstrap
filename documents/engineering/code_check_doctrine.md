# Code-check doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [base_image.md](base_image.md), [derived_project_standards.md](derived_project_standards.md), [warm_store.md](warm_store.md), [../languages/haskell.md](../languages/haskell.md), [testing.md](testing.md)

> **Purpose**: State the rule that every image build, base or derived, gates on the applicable canonical
> source checks.

## TL;DR

- The base publisher runs the Python/core/demo source gates before Docker; derived images run their
  project binary's canonical code-check.
- Derived images invoke the project binary's project-owned `check-code` body.

Code quality is a **build-time guardrail**, distinct from behavioral tests. Under the finished doctrine,
every image this repo produces fails its build if the applicable canonical code-check fails.

This is one leg of a larger picture. `fourmolu` and `hlint` are installed in the base image and run only
here, so the **host static gate** — the fast Haskell and Python suites, which run host-native on every
supported outer host — is the behavioural leg and is not the complete quality gate. The two together are
what "the gate passed" means. See [testing](testing.md#gate-kinds).

## The rule

Every image build, base or derived, MUST gate completion on the project's
canonical code-check command. If the check exits non-zero, the image build
exits non-zero. No image is produced.

This applies in two places:

| Image | Where the check runs | Command |
|---|---|---|
| Base | Host preflight + Dockerfile smoke | Python checks/tests and core/demo Cabal build/tests with `-Werror`, then an in-image Haskell-tool smoke |
| Derived | Dockerfile RUN step | `<project> check-code` — the inherited core verb whose body is project-defined |

## Base image

The base image has two complementary checks:

* **Host pre-flight.** Building a base tag runs Python checks/tests and core/demo Cabal build/tests with
  `-Werror` before `docker build`; the Haskell tests include governed documentation validation.
* **In-Dockerfile smoke.** After the warm Cabal store is built (the base bakes
  **no** `hostbootstrap` binary — see [base_image.md](base_image.md)), a single
  `RUN` step verifies that `fourmolu` and `hlint` actually start (catching install
  regressions) and runs them against the warm-store sample sources at
  [`core/warm-deps/core/app/`](../../core/warm-deps/core/app/) and
  [`core/warm-deps/daemon/app/`](../../core/warm-deps/daemon/app/)
  (catching sample drift).

The in-Dockerfile smoke cannot substitute for testing the repository's Haskell sources; both layers are
required. See [build and release](build_release.md).

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
project-defined source gate passed during its build. For a base publication, the host-side repository
source gate precedes the Docker build.

## Current Status

Derived project Dockerfiles carry the project-binary `check-code` gate. The base publisher runs the
Python/core/demo source preflight and the Dockerfile retains the Haskell-tool/sample smoke described
above. Live publication evidence and implementation status remain in the development plan.

## WRONG vs RIGHT

> **WRONG**
>
> Project `docker/Dockerfile`:
>
> ```dockerfile
> FROM ${BASE_IMAGE}
> COPY . /workspace/proj
> RUN cabal build --enable-tests all --ghc-options=-Werror && test -s "$(cabal list-bin exe:proj)"
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
> RUN cabal build --enable-tests all --ghc-options=-Werror && test -s "$(cabal list-bin exe:proj)"
> RUN proj check-code
> RUN proj build native-backend
> RUN built_binary="$(cabal list-bin exe:proj)" && test -s "${built_binary}" && dd if=/usr/local/libexec/proj of=/usr/local/bin/proj bs=4M status=none && chmod 0755 /usr/local/bin/proj && rm /usr/local/libexec/proj && rm /usr/local/libexec/proj.dhall && test -s /usr/local/bin/proj
> ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/proj"]
> ```
>
> Code-check sits between the source build and the expensive backend
> compilation. A formatting regression fails the image build in seconds, never
> burns the PGO budget, and never reaches Docker Hub. The final layer verifies
> the in-image Cabal product, materializes the source-built and digest-bound
> authenticated builder bytes as a new regular runtime entrypoint, and checks
> that file, so runtime does not depend on snapshotting either the in-container
> link output or a direct large-file named-context copy.

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
