# Code-check doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../documentation_standards.md](../documentation_standards.md), [base_image.md](base_image.md), [build_release.md](build_release.md), [derived_dockerfile.md](derived_dockerfile.md), [derived_project_standards.md](derived_project_standards.md), [../languages/haskell.md](../languages/haskell.md), [../languages/python.md](../languages/python.md), [testing.md](testing.md)

> **Purpose**: State the rule that every image build, base or derived, gates on the applicable canonical
> source checks.

## TL;DR

- The base publisher runs the repository source gate on the host before Docker: Python checks and tests,
  `fourmolu` and `hlint` over the Haskell roots, then the core and demo Cabal builds and tests.
- Derived images invoke the project binary's project-owned `check-code` body.
- The style contract is committed: [`fourmolu.yaml`](../../fourmolu.yaml) and
  [`.hlint.yaml`](../../.hlint.yaml) at the repository root. The host source gate and a derived
  `check-code` whose build context carries them read them; the base image's in-build smoke does not.
- This page is the canonical home for where `fourmolu` and `hlint` run:
  [Where the style tools run](#where-the-style-tools-run). The host static gate runs neither.

Code quality is a **build-time guardrail**, distinct from behavioral tests. Every image this repo
produces fails its build if the applicable canonical source check fails.

This is one leg of a larger picture. The **host static gate** — the four legs spelled once in
[development_plan_standards.md § JJ](../../DEVELOPMENT_PLAN/development_plan_standards.md#jj-host-portable-static-gate-and-test-harness),
which run host-native on every supported outer host — is the other, and the two together are what
"the gate passed" means. See [testing](testing.md#gate-kinds).

## The committed style contract

Two files at the repository root fix the configurable options of the style tools. They do not fix the
tools themselves: `fourmolu` and `hlint` are installed unpinned and roll with the base image (see
[languages/haskell.md](../languages/haskell.md) and
[development_plan_standards.md § FF](../../DEVELOPMENT_PLAN/development_plan_standards.md#ff-rolling-base-selection-and-native-compatibility)), so a tool
upgrade that changes formatting or adds a default hint can still change the verdict with no repository
change.

- [`fourmolu.yaml`](../../fourmolu.yaml) writes out every formatter setting, including the ones that
  agree with the tool's current defaults, so an upgrade that changes the default of a listed setting does
  not change that setting here. The values are the ones the existing sources already agreed with most
  closely, measured rather than chosen.
- [`.hlint.yaml`](../../.hlint.yaml) keeps hlint's default rule set and names, family by family, every
  hint the library's own conventions decline — positional elimination of a sum's fields, `data` rather
  than `newtype` for a phantom-indexed opaque value, named arguments rather than eta reduction, explicit
  ASCII ranges rather than a `Data.Char` classifier, and explicit spellings rather than combinator ones.
  A finding outside those families is a new one, and fails.

The two tools find those files from different starting points. `fourmolu` searches upward from the
directory of the first path it is given; `hlint` searches upward from its working directory and then
the home directory, and never looks at where the paths it is given sit. A run reads the committed files
only when they sit at or above both starting points. The table below says, for each place the tools
check sources, whether that holds.

## Where the style tools run

`fourmolu` and `hlint` check sources in exactly three places. The host static gate is not one of them:
its Python `check_code` leg runs `ruff`, `black`, and `mypy`, and its Cabal legs build and test. The
publication's [compatibility smoke](base_image.md#republishing) also starts both tools, but only with
`--version`, and reads no sources.

| Where | Driven by | Sources read | Style files read |
|---|---|---|---|
| Repository source gate, on the maintainer's host, before any Docker build | `base build` / `base build-and-push`, through `_style_gates` in [`hostbootstrap/cli.py`](../../hostbootstrap/cli.py) | formatter: `src`, `internal`, `app`, and `test` of `core/hostbootstrap-core`, and `src`, `app`, and `test` of `demo`, less the seven modules below; linter: the same roots without the two `test` roots. The core `provider-live` suite root is in neither list (see [Current Status](#current-status)) | yes: the committed root files |
| Derived image build | the `RUN` step that invokes `<project> check-code`; for the worked consumer, `demoCheckCode` checks `app` and `src` and then runs a warning-clean Cabal build | the project's own roots, as its `check-code` body names them | only when the build context places them at or above the `check-code` process's working directory, which is also where the relative roots it passes start; the [demo Dockerfile](../../demo/docker/Dockerfile) copies both to `/workspace` and runs `check-code` from `/workspace/demo` |
| Base image build | the smoke `RUN` step in [`docker/basecontainer.Dockerfile`](../../docker/basecontainer.Dockerfile), run from `/opt/basecontainer/haskell-deps` | the warm-store samples `core/app` and `daemon/app` | no: the warm-store copy carries neither file, so the tools run on their installed defaults |

The repository source gate needs both tools on the maintainer's `PATH`, at versions compatible with the
pinned GHC. Its style gates run after the Python checks and tests and before the Cabal legs, so a style
regression fails before any full Haskell build, and each gate names the root it read.

One limit is written into the gate rather than left implicit: fourmolu parses Haskell, not CPP. In seven
modules an `#if`/`#else` splits a declaration and the formatter cannot read the file at all. Those seven
are named one by one in `_FORMATTER_UNREADABLE` in [`hostbootstrap/cli.py`](../../hostbootstrap/cli.py),
so adding to the list is a decision somebody made rather than a file that quietly stopped being checked.
Five of the seven are library modules, and the linter reads them, because hlint does not need to parse the
preprocessor to run — though it does not evaluate it either, which is why `.hlint.yaml` refuses its
duplicate-import finding in the six modules where only a preprocessor branch keeps the two imports apart.
The other two, `LifecycleSpec` and `LiftSpec`, are suite modules outside the linter roots, so neither
tool reads them; that is the deliberate consequence of the named exclusion, not an open gap.

## The rule

Every image build, base or derived, MUST gate completion on its applicable
canonical source checks: for a derived image, the project binary's
`check-code`; for the base, the host source gate followed by the in-image tool
smoke. If a check exits non-zero, the image build exits non-zero. No image is
produced.

This applies in two places:

| Image | Where the check runs | Command |
|---|---|---|
| Base | Host preflight + Dockerfile smoke | Python checks/tests, `fourmolu` and `hlint` over the Haskell roots, and core/demo Cabal build/tests with `-Werror`, then an in-image Haskell-tool smoke |
| Derived | Dockerfile RUN step | `<project> check-code` — the inherited core verb whose body is project-defined |

## Base image

The base image has two complementary checks:

* **Host pre-flight.** Building a base tag runs Python checks/tests, then `fourmolu` and `hlint` over the
  Haskell roots, then core/demo Cabal build/tests with `-Werror`, all before `docker build`; the Haskell
  tests include governed documentation validation. A failing gate aborts with no image built or pushed.
* **In-Dockerfile smoke.** After the warm Cabal store is built (the base bakes
  **no** `hostbootstrap` binary — see [base_image.md](base_image.md)), a single
  `RUN` step verifies that `fourmolu` and `hlint` actually start (catching install
  regressions) and runs them against the warm-store sample sources at
  [`core/warm-deps/core/app/`](../../core/warm-deps/core/app/) and
  [`core/warm-deps/daemon/app/`](../../core/warm-deps/daemon/app/)
  (catching sample drift). The committed style files are not in that copy, so the smoke runs on the
  tools' installed defaults (see [Current Status](#current-status)).

The in-Dockerfile smoke cannot substitute for testing the repository's Haskell sources; both layers are
required. See [build and release](build_release.md).

## Derived images

Every derived project that inherits `FROM ${BASE_IMAGE}` MUST add a single
`RUN` step that invokes its project's canonical code-check command. The step
runs:

* **After** the coordinator-selected authenticated builder and its image-build
  config are installed under `/usr/local/libexec/`. The runtime entrypoint
  `/usr/local/bin/<project>` is still absent at this point; it is materialized
  only in the final layer.
* **Before** the source build and any expensive downstream work (PGO, BOLT,
  foreign-backend compilation, large data ingestion).

[derived_dockerfile.md](derived_dockerfile.md#the-reference-shape) is canonical for the full ordering
and the three secret mounts the step carries.

The point of "before expensive work" is fail-fast latency. A style violation
should abort the image build before a multi-minute PGO/BOLT pipeline starts.

## Why "fail-fast guardrail", not "test"

Code-check enforces **shape**: formatting, lint rules, custom forbidden
patterns, type-correctness. Tests enforce **behavior**.

Both must pass, but they live at different layers and have different cost
profiles. A check-code body runs its formatter and linter first, so a style
violation fails in seconds; its type-correct leg is a full warning-clean Cabal
build, which costs a build and is only as reproducible as dependency
resolution, because a cache miss resolves and downloads online. Running it
during image build shifts enforcement earlier and removes a class of "the
container built but is broken" outcomes. Tests run through the project binary (`<project> test run all` and
equivalents) — they verify the runtime, not the source. Container images expose
the project binary through a tini-wrapped `ENTRYPOINT`, so the binary receives
project arguments rather than a raw container command.

For a conforming derived project, the container image is the canonical artifact: if it exists, the
project-defined source gate passed during its build. For a base publication, the host-side repository
source gate precedes the Docker build.

## Current Status

Derived project Dockerfiles carry the project-binary `check-code` gate. The base publisher runs the
repository source gate described above, including its style gates, and the Dockerfile retains the
Haskell-tool/sample smoke. Two gaps separate the tree from the committed-style contract; the
[base-image-and-warm-store phase](../../DEVELOPMENT_PLAN/phase-23-base-image-and-warm-store.md) owns
them:

- **The base smoke runs on tool defaults.** The warm-store copy carries neither `fourmolu.yaml` nor
  `.hlint.yaml`, so a rolling change to either tool's defaults can change whether the base build passes
  with no repository change.
- **The provider-live suite is not formatted.** `core/hostbootstrap-core/provider-live`, the source
  root of the core package's second test suite, is in neither root list of the source gate, so no tool
  reads its modules.

Live publication evidence and implementation status remain in the development plan.

## Validation

- `tests/test_cli.py` pins the repository source gate:
  `test_quality_gates_run_all_python_core_and_demo_commands` (the non-style gates and their working
  directories), `test_style_gates_enumerate_sources_and_skip_the_modules_fourmolu_cannot_read`,
  `test_style_gates_run_before_the_cabal_legs`, and the cases asserting that a failing or unlaunchable
  gate raises before any Docker call.
- `demo/test/CommandsSpec.hs` case "the Direct derived build uses only the authenticated BuildKit
  channel" pins the derived Dockerfile's stage order: the style-file copies, the authenticated builder
  install, the authenticated `check-code`, then the source build and the final materialization.
- The base smoke is the `RUN` step in
  [`docker/basecontainer.Dockerfile`](../../docker/basecontainer.Dockerfile) itself; a base build fails
  when it fails.

## WRONG vs RIGHT

> **WRONG**
>
> Project `docker/Dockerfile`:
>
> ```dockerfile
> FROM ${BASE_IMAGE}
> COPY . /workspace/proj
> RUN cabal build --enable-tests all && test -s "$(cabal list-bin exe:proj)"
> RUN proj build native-backend
> ```
>
> No code-check anywhere. A container can be produced from source that fails
> `proj check-code`. Style violations only surface when someone manually runs
> the code-check gate — possibly never, in CI shortcuts.
>
> **RIGHT**
>
> The [reference shape](derived_dockerfile.md#the-reference-shape) in
> [derived_dockerfile.md](derived_dockerfile.md), which the
> [demo Dockerfile](../../demo/docker/Dockerfile) realizes. In order: copy the
> sources and the committed style files; install the coordinator-selected
> authenticated builder and its image-build config under `/usr/local/libexec/`;
> run `/usr/local/libexec/<project> check-code` with the three image-build
> secrets mounted; build the sources warning-clean; do the expensive backend
> work; and in the final layer materialize the authenticated builder bytes as
> the runtime entrypoint `/usr/local/bin/<project>` and remove the build-only
> authority.
>
> Code-check precedes both the source build and the expensive backend
> compilation. A formatting regression fails the image build before either
> starts, never burns the PGO budget, and never reaches Docker Hub. This page
> carries no copy of the skeleton, so the two cannot drift.

## What counts as the "canonical code-check" command

* **A `check-code` subcommand on the project binary.** `check-code` is a **core
  verb**: every binary inherits it from the `hostbootstrap-core` command tree, and
  its **body comes from the project's `ProjectSpec`**. The verb is the single
  fail-fast image-build gate; the project fills in the checks it should run
  (`fourmolu --mode check`, `hlint`, custom file-level checks, doc-drift checks).
  A derived project has no silent default check body: if it calls
  `runHostBootstrapCLI`, it must supply the action. The bare core binary uses the
  separate `runBareHostBootstrapCLI` entrypoint and is the only binary whose
  `check-code` intentionally reports no project checks. The base image has no
  project binary and so no `check-code`; it gates through the host source gate
  and the in-image tool smoke (see "Base image"), because the full
  `hostbootstrap` source tree is not copied into the base image.
* **Preconditions.** The verb first validates the sibling `<project>.dhall`
  beside the binary and refuses without it. In the image-build container
  context it also refuses unless the three `hostbootstrap-build-*` secrets
  (channel, verification, coordinator) are mounted for that `RUN` step and
  authenticate the builder; elsewhere it runs the project body directly. See
  [the check-code gate](derived_dockerfile.md#the-check-code-gate).
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
* [derived_dockerfile.md](derived_dockerfile.md) — the reference derived
  Dockerfile, including the authenticated `check-code` step and its secret mounts
* [testing.md](testing.md) — the gate kinds, including the host static gate,
  which runs neither style tool
* [languages/haskell.md](../languages/haskell.md) — how fourmolu and hlint are
  installed (rolling, unpinned) and where the binaries live in the base image
