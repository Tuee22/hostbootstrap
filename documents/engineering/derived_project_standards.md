# Derived project standards

**Status**: Authoritative source
**Supersedes**: the execution-model / lifecycle ("five rules" tied to Container/HostBinary/HostDaemon) derived-project doctrine
**Referenced by**: [../README.md](../README.md), [base_image.md](base_image.md), [warm_store.md](warm_store.md), [code_check_doctrine.md](code_check_doctrine.md), [harbor.md](harbor.md), [linking_and_optimization.md](linking_and_optimization.md), [binary_context_config](../architecture/binary_context_config.md)

> **Purpose**: State the rules a derived project follows to build the one binary that extends
> `hostbootstrap-core`, materialize its explicit binary-context config, inherit the base image, gate on
> `check-code`, and materialize the binary at `./.build/`.

This is the single page a derived project's author reads before writing their `docker/Dockerfile`,
`cabal.project`, and project binary. It is the union of the doctrine docs under
[`engineering/`](.), in the form of rules with one-line explanations and a link to the authoritative
source.

## The derived project is one binary that extends the core

A derived project ships **exactly one binary** named after its Cabal file. For example,
`hostbootstrap-demo.cabal` produces project/binary name `hostbootstrap-demo`. The Python bootstrapper uses
that Cabal-derived name only to build `exe:<project>` host-native. Once the binary exists, normal command
dispatch is governed by the sibling runtime config file, [`<project>.dhall`](schema.md).

That binary extends `hostbootstrap-core`'s optparse command tree rather than re-implementing core verbs:

```haskell
import HostBootstrap.CLI (runHostBootstrapCLI)
import HostBootstrap.Harness (emptySuite)

main :: IO ()
main = runHostBootstrapCLI "app" appProjectCommands emptySuite
```

`runHostBootstrapCLI progName projectCommands testSuite` composes the project's own subcommands onto the
core tree (`ensure …`, substrate detection, cluster-lifecycle verbs, `check-code`, `config schema`,
`config render`, `test`). Bootstrap/inspection config surfaces (`config init`, `config path`,
`config schema`, `config show FILE`, and static `config render`) run without an active local config.
Config loading/gating surrounds normal commands: they fail fast when `<project>.dhall` is missing or the
command is not valid for the declared context. The bare `hostbootstrap` binary is the same tree with no
project commands, built the same way (host-native, like every project binary), not baked into the base
image. There is no Python-owned `hostbootstrap.dhall`; execution-model, lifecycle, role, mount,
Dockerfile, resource, and deploy settings live in the binary-owned config and generated child configs.

The worked consumer lives at `demo/` (the `hostbootstrap-demo` app): its `app/Main.hs` calls
`runHostBootstrapCLI "hostbootstrap-demo" demoCommands (TestSuite demoSeams demoCases)`, so
`hostbootstrap-demo --help` shows the core verbs (`ensure`, `config`, `cluster`, `test`, `check-code`)
plus the demo's own noun-first verbs (`incus`/`vm`/`harbor`/`web`/`deploy`/`role`) — the extension contract a consumer
follows, with no core verb re-implemented. It also exercises the other extension streams: `demo web
schema` prints the `coreArtifacts ++ demoArtifacts` schema union, and `demo test all` drives the harness
(`demoSeams`/`demoCases`, bound to the inherited `test` verb) over the demo's case matrix.

## The three-level library hierarchy

The reusable surface is a three-level Cabal library hierarchy. Each level adds **only its delta** and
imports the level below it; nothing re-implements a lower level's verbs:

| Level | Library | Consumers |
|-------|---------|-----------|
| L0 | `hostbootstrap-core` | `mcts` and `hostbootstrap-demo` consume it directly; `daemon-substrate` imports it |
| L1 | `daemon-substrate` | the daemon apps import it |
| L2 | `{jitML, infernix}` | the leaf apps |

Each level extends the same **four parallel streams**, one additive merge idiom each:

| Stream | Merge idiom | Rule |
|--------|-------------|------|
| optparse **CLI tree** | `runHostBootstrapCLI progName (lower ++ delta) testSuite` | append; never shadow a lower verb |
| **Dhall vocabulary** | `let C = ./Core.dhall` | embed and extend; never redefine `Core` |
| **schema-gen** `ConfigArtifact` registry | concatenate across levels | a level appends its own artifacts |
| **test-harness** `Seams` | supply the level's seams | the app supplies its seams + case matrix as a `TestSuite`, threaded into the inherited `test` verb |

"L0-direct" (consuming L0 without going through L1) is independent of the integration mode below:
`mcts` is L0-direct via mode 1; `hostbootstrap-demo` is L0-direct via mode 2; `daemon-substrate` is L1
via mode 2.

## Two integration modes

A project integrates with `hostbootstrap` in one of two modes:

1. **Freeze-import + the base-image contract** (no Cabal dependency on `hostbootstrap-core`). The
   project imports only the warm-store freeze and consumes the base image's `LABEL`/`ENTRYPOINT`
   contract; it does not depend on the `hostbootstrap-core` library in its `cabal.project`. This suits
   a project that wants the warm toolchain and the base-image binary contract without extending the
   command tree in Haskell (e.g. `mcts`).
2. **`source-repository-package` + `runHostBootstrapCLI` extension.** The project adds
   `hostbootstrap-core` (or `daemon-substrate` at L1) as a `source-repository-package` dependency and
   ships one binary that calls `runHostBootstrapCLI progName projectCommands testSuite`, appending its
   own verbs to the inherited tree and supplying its test suite (e.g. `daemon-substrate` and its apps,
   and the worked `demo/` consumer). This is the mode the *Worked compliant Dockerfile shape* below
   illustrates.

Both modes build the binary **host-native** into `./.build/<project>` and gate the project container on
`check-code`; they differ only in whether the project takes a Cabal dependency to extend the command
tree in Haskell.

## The rules

1. **Inherit `FROM ${BASE_IMAGE}` and follow the Dockerfile rules.** POSIX `/bin/sh`, no pipes, no
   buildx, no `--platform`. See [base_image.md](base_image.md#dockerfile-rules).
2. **Use the warm-store `cabal.project` template AND import the layered warm-store freeze.** Set
   `with-compiler: ghc-9.12.4`, `tests: True`, `benchmarks: True`, `shared: True`,
   `optimization: 2`, and import the fragment(s) for the project's layer in `cabal.project`: an
   L0-direct consumer adds `import: /opt/basecontainer/haskell-deps/core.freeze`; a daemon app
   additionally adds `import: /opt/basecontainer/haskell-deps/daemon.freeze`. Derived projects ship
   **zero** freeze files of their own — the freezes live only in the base image and are referenced
   at build time so version drift cannot happen. Add `hostbootstrap-core` as a
   `source-repository-package` (or local) dependency; its transitive closure is already warm in the
   store. Without the freeze import, the resolver picks different transitive versions than the warm
   store and rebuilds. See [warm_store.md](warm_store.md#required-import-the-freeze-fragments).
3. **Build the binary, materialize the container config, run `<project> check-code`, and add a
   tini-wrapped `ENTRYPOINT`.** Container config materialization is explicit:
   `RUN <project> config init --role vm-project-container --output /usr/local/bin/<project>.dhall` runs
   after the binary is installed and before any normal command. The check then runs under the declared
   container context and before any expensive backend work; the container is built on every substrate as
   the mandatory code-check gate. See [code_check_doctrine.md](code_check_doctrine.md#derived-images)
   and [binary_context_config](../architecture/binary_context_config.md).
4. **Link executables statically; build libraries with `shared: True`.** Do not pass
   `--enable-executable-dynamic` or `--enable-executable-static`. See
   [linking_and_optimization.md](linking_and_optimization.md#recommended-policy).
5. **Don't rebuild what the warm store already builds.** Check
   `cabal build --dry-run --enable-tests --enable-benchmarks all` inside the container. If a
   third-party package (including a `hostbootstrap-core` dependency) shows up in the plan, fix your
   project's flags first; if it's a genuine miss, add it to the appropriate layer
   manifest under [`core/warm-deps/`](../../core/warm-deps/)
   (core + web → `basecontainer-core-deps.cabal`; daemon-family →
   `basecontainer-daemon-deps.cabal`).
   See [warm_store.md](warm_store.md#how-to-verify-your-project-hits-the-cache).

A project that follows all five rules has a Dockerfile that is small, a build that hits the cache,
a binary that extends the core command tree, and an image that cannot exist with code-check
violations.

## Build and run: where the binary lives

Every project produces a host binary at `./.build/<project>`, built **host-native** on every
substrate:

- The Python bootstrapper ensures the host build toolchain (on Apple, Homebrew → `ghcup` →
  GHC/Cabal; the equivalent on Linux) and builds the binary host-native into `./.build/<project>`.
  A Linux ELF cannot exec on a general host such as Apple silicon, so the binary is always built for
  the host it runs on — there is no build-in-container, copy-out path.
- Tart, when used on Apple, is build-only (Swift/Metal artifacts copied to `./.build/`) and never a
  runtime.

Building the project **container** is the execed binary's job (its `check-code` gate), not the
bootstrapper's. A `./.build/<project>` is always present after a successful bootstrap, regardless of
substrate.

## Worked compliant Dockerfile shape

```dockerfile
# check=skip=InvalidDefaultArgInFrom

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

WORKDIR /workspace/app

COPY . /workspace/app

RUN cabal build --enable-tests --enable-benchmarks all \
    && install -m 0755 "$(cabal list-bin --enable-tests --enable-benchmarks exe:app)" /usr/local/bin/app

RUN app config init --role vm-project-container --output /usr/local/bin/app.dhall

RUN app check-code

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/app"]
```

The `# check=skip=InvalidDefaultArgInFrom` parser directive on line 1 silences a BuildKit lint
warning: the linter evaluates `FROM ${BASE_IMAGE}` against the static empty `ARG` default (the value
is supplied as a build arg) and reports an "invalid base image name." The directive is required
boilerplate for every derived project that follows the `FROM ${BASE_IMAGE}` pattern.

Its `cabal.project`:

```cabal
packages: .

with-compiler: ghc-9.12.4

import: /opt/basecontainer/haskell-deps/core.freeze

tests: True
benchmarks: True
shared: True
optimization: 2

source-repository-package
  type: git
  location: https://github.com/tuee22/hostbootstrap.git
  subdir: core/hostbootstrap-core
```

This worked consumer is L0-direct, so it imports `core.freeze` only. A daemon app would add a second
`import: /opt/basecontainer/haskell-deps/daemon.freeze` line alongside it.

No freeze is committed in the project — the layered warm-store freezes are imported from the
base image at build time, and `hostbootstrap-core`'s dependency closure is already warm.

The `config init --role vm-project-container` line is the container-config bootstrap hook. It is the only
binary entry point in the Dockerfile that may run before the sibling config file exists; later commands
such as `check-code` load that config and refuse commands not valid for a container build/check context.

## See also

* [base_image.md](base_image.md) — what the base image ships, including the warm core closure
* [warm_store.md](warm_store.md) — the Cabal store cache-hit contract
* [code_check_doctrine.md](code_check_doctrine.md) — the build-time code-check gate
* [linking_and_optimization.md](linking_and_optimization.md) — linking and optimisation defaults
* [harbor.md](harbor.md) — pushing the project image (out of scope for hostbootstrap itself)
* [binary_context_config](../architecture/binary_context_config.md) — the runtime sibling config file
  every normal binary command reads
