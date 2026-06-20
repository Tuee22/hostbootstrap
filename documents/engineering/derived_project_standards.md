# Derived project standards

**Status**: Authoritative source
**Supersedes**: the execution-model / lifecycle ("five rules" tied to Container/HostBinary/HostDaemon) derived-project doctrine
**Referenced by**: [../README.md](../README.md), [base_image.md](base_image.md), [warm_store.md](warm_store.md), [code_check_doctrine.md](code_check_doctrine.md), [harbor.md](harbor.md), [linking_and_optimization.md](linking_and_optimization.md), [binary_context_config](../architecture/binary_context_config.md)

> **Purpose**: State the rules a derived project follows to build the one binary that extends
> `hostbootstrap-core`, contribute its lift **chain** and step actions, inherit the base image, gate on
> `check-code`, and materialize the binary at `./.build/`.

This is the single page a derived project's author reads before writing their `docker/Dockerfile`,
`cabal.project`, and project binary. It is the union of the doctrine docs under
[`engineering/`](.), in the form of rules with one-line explanations and a link to the authoritative
source. The model these rules instantiate — the chain-is-the-project, the recursive `project up`
interpreter, fractal bootstrap — is defined once in
[composition_methodology](../architecture/composition_methodology.md); this page defers to it and never
re-derives it.

## The derived project is one binary whose identity is its lift chain

A derived project ships **exactly one binary** named after its Cabal file. For example,
`hostbootstrap-demo.cabal` produces project/binary name `hostbootstrap-demo`. The Python bootstrapper uses
that Cabal-derived name only to build `exe:<project>` host-native. Once the binary exists, command dispatch
is governed by the sibling runtime config file, [`<project>.dhall`](schema.md).

The binary's primary contribution is **not** a set of noun verbs — it is a value:

```haskell
chain :: ProjectConfig -> [Step]
```

an ordered list of `Step`s the core interprets. The shape of that list **is** the project's identity
(single representation, see [composition_methodology § single representation](../architecture/composition_methodology.md#single-representation-the-chain-is-the-representation)):
host-management step kinds the core ships (deploy-VM, ensure-X, copy-source, build-pb, build-image,
context-init, deploy-kind, deploy-chart, expose-port) interleave freely with the project's own step kinds
(deploy-harbor, push-image, …). `project up` recursively interprets `chain rootCfg` from the current frame
and hands off `pb project up` into the next frame; `project up --dry-run` renders the chain plan without
executing it. The `.dhall` carries **parameters + context + witness**, never the shape — each binary
verifies it is in the frame its `.dhall` describes, or fails fast.

The binary extends `hostbootstrap-core`'s command tree rather than re-implementing core verbs:

```haskell
import HostBootstrap.CLI (projectSpec, runHostBootstrapCLI, withChain)
import HostBootstrap.Harness (TestSuite (TestSuite))

main :: IO ()
main =
  runHostBootstrapCLI
    "app"
    ( withChain
        appChain
        (projectSpec appCommands (TestSuite appSeams appCases) appCheckCode appArtifacts)
    )
```

`projectSpec` takes the project's commands, test suite, code-check action, and schema artifacts;
`withChain` attaches the lift chain (and `withFrameContext` / `withTeardown` attach the per-frame
lift-context builder and the chain-frame teardown). `runHostBootstrapCLI progName projectSpec` composes
the project's chain, test suite, code-check action, and
schema artifacts onto the inherited tree (`project init|up|down|destroy`, `context`, `test init|run`,
`check-code`). The spec is fail-closed: the chain must type-check against `ProjectConfig`, the test suite must
be non-empty, the `check-code` action is required, duplicate case/artifact names are rejected, and project
artifacts feed the inherited `context` introspection registry. The bare `hostbootstrap` binary uses
`runBareHostBootstrapCLI`; it is the only intentional empty-chain/empty-suite binary. `project init` runs
without an active local config to write the root `<project>.dhall`; every other normal command loads that
config and fails fast when it is missing or when the command is not valid for the declared frame. There is
no Python-owned `hostbootstrap.dhall`; resource, context, and witness settings live in the binary-owned
root config, and child configs are minted by the context-init step inside `project up`.

The worked consumer lives at `demo/` (the `hostbootstrap-demo` app): its `app/Main.hs` calls
`runHostBootstrapCLI "hostbootstrap-demo" (withChain demoChain (... (projectSpec demoCommands (TestSuite
demoSeams demoCases) demoCheckCode demoArtifacts)))`. Its `demoChain` contributes the demo's
host→VM→container→cluster lift (deploy VM, build pb + image in the VM, context-init the project-container
child config, deploy kind, deploy harbor, push image, deploy chart, expose NodePort) as a single `[Step]`
the core interprets across the 3-frame fractal descent. `project up` interprets that chain to stand up the
persistent stack; `context` visualizes the composition; and `test run all` **drives that same `project up`**
under a test config (one per distinct test config), asserting the live stack with `demoSeams` and tearing it
down with `project destroy` — reusing the chain, not a separate per-case cluster.

## The three-level library hierarchy

The reusable surface is a three-level Cabal library hierarchy. Each level adds **only its delta** and
imports the level below it; nothing re-implements a lower level's verbs:

| Level | Library | Consumers |
|-------|---------|-----------|
| L0 | `hostbootstrap-core` | `mcts` and `hostbootstrap-demo` consume it directly; `daemon-substrate` imports it |
| L1 | `daemon-substrate` | the daemon apps import it |
| L2 | `{jitML, infernix}` | the leaf apps |

Each level extends the same **parallel extension streams**, one additive merge idiom each (canonical statement:
[library_hierarchy](../architecture/library_hierarchy.md)):

| Stream | Merge idiom | Rule |
|--------|-------------|------|
| **the lift chain** | append `Step`s into `chain :: ProjectConfig -> [Step]` | core ships host-management step kinds; a level appends its own step kinds; host and workload steps interleave, never shadow |
| **Dhall vocabulary** | `let C = ./Core.dhall` | embed and extend; never redefine `Core` |
| **schema-gen** `ConfigArtifact` registry | concatenate across levels | a level appends its own artifacts |
| **test-harness** `Seams` | supply the level's seams | the app supplies its seams + case matrix as a `TestSuite`, threaded into the inherited `test run` verb |

Stream 1 is the workload-extension seam: a project contributes step kinds into the same `[Step]` the core
interprets. "L0-direct" (consuming L0 without going through L1) is independent of the integration mode
below: `mcts` is L0-direct via mode 1; `hostbootstrap-demo` is L0-direct via mode 2; `daemon-substrate` is
L1 via mode 2.

## Two integration modes

A project integrates with `hostbootstrap` in one of two modes:

1. **Freeze-import + the base-image contract** (no Cabal dependency on `hostbootstrap-core`). The
   project imports only the warm-store freeze and consumes the base image's `LABEL`/`ENTRYPOINT`
   contract; it does not depend on the `hostbootstrap-core` library in its `cabal.project`. This suits
   a project that wants the warm toolchain and the base-image binary contract without contributing a
   chain in Haskell (e.g. `mcts`).
2. **`source-repository-package` + `runHostBootstrapCLI` extension.** The project adds
   `hostbootstrap-core` (or `daemon-substrate` at L1) as a `source-repository-package` dependency and
   ships one binary that calls `runHostBootstrapCLI progName projectSpec`, contributing its chain, step
   actions, non-empty test suite, code-check action, and schema artifacts (e.g. `daemon-substrate` and its
   apps, and the worked `demo/` consumer). This is the mode the *Worked compliant Dockerfile shape* below
   illustrates.

Both modes build the binary **host-native** into `./.build/<project>` and gate the project container on
`check-code`; they differ only in whether the project takes a Cabal dependency to contribute a chain in
Haskell.

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
3. **Build the binary, materialize the image-build context, run `<project> check-code`, and add a
   tini-wrapped `ENTRYPOINT`.** Image-build context materialization is explicit: the Dockerfile runs the
   binary once to write its image-build-container `<project>.dhall` after the binary is installed and
   before any normal command. The check then runs under the narrow image-build frame and before any
   expensive backend work; the container is built on every substrate as the mandatory code-check gate. The
   container frame skips the build step at runtime — `docker run img project up` enters the chain already
   built. Runtime launchers receive a parent-generated runtime `<project>.dhall` minted by the context-init
   step. See [code_check_doctrine.md](code_check_doctrine.md#derived-images) and
   [binary_context_config](../architecture/binary_context_config.md).
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
a binary whose chain extends the core step algebra, and an image that cannot exist with code-check
violations.

## Build and run: where the binary lives

Every project produces a host binary at `./.build/<project>`, built **host-native** on every
substrate:

- The Python bootstrapper ensures the host build toolchain (on Apple, Homebrew → `ghcup` →
  GHC/Cabal; the equivalent on Linux) and builds the binary host-native into `./.build/<project>`.
  A Linux ELF cannot exec on a general host such as Apple silicon, so the binary is always built for
  the host it runs on — there is no build-in-container, copy-out path. The Python bootstrapper is the
  **metal-frame instance** of the fractal bootstrap (provision the frame → build/install the pb in it →
  hand off `pb project up`); see
  [python_haskell_boundary](../architecture/python_haskell_boundary.md).
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

RUN app project init --role image-build-container --output /usr/local/bin/app.dhall

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

The `project init --role image-build-container` line is the container-image bootstrap hook. It is the only
binary entry point in the Dockerfile that may run before the sibling config file exists; later build-time
commands such as `check-code` load that config and refuse commands not valid for the image-build frame. At
runtime the parent's context-init step mounts or materializes the role-specific `<project>.dhall` at
`/usr/local/bin/<project>.dhall`, and the container enters the chain with `docker run img project up`.

## Status

The binary surface **is** the `project` chain, validated end-to-end on real hardware. The core command
tree is exactly `ensure`, `context`, `project`, `test`, `check-code`:

- `chain :: ProjectConfig -> [Step]` is interpreted by the recursive `project init|up|down|destroy`
  commands.
- `context` is read-only introspection: `inspect` renders the lift composition with the current frame
  marked, and `path`/`show`/`schema`/`render` inspect and describe the project-local config.
- `test init` writes `test.dhall`; `test run <suite>|all` runs a suite, or the whole matrix with `all`,
  from the root frame.
- `check-code` runs the project's fail-fast code-check gate.
- `ensure <tool>` is a surfaced verb that reconciles a single host dependency; `project up` also invokes the reconcilers as `ensure-*` chain steps.

The demo's deploy is the contributed `demoChain :: ProjectConfig -> [Step]` value in
`demo/src/HostBootstrapDemo/Commands.hs` — a list of `Step` the core interprets across the 3-frame fractal
descent. The demo contributes its `Web` service variant (run by `service run`; the build-time bridge folds
into the build-image step) and its VM/provider IO as chain steps — the surface is fixed, so it adds no
verbs. The image-build hook runs as `project init --role image-build-container`.

A single `project up` on Incus/Linux stands up the live persistent stack — a cordoned kind cluster
(kind `extraPortMappings` publish NodePorts to the VM localhost) → the full 8-pod production Harbor
(NodePort 30500) → the project image pushed to the in-cluster registry → the web chart pod →
`localhost:30080` serving HTTP 200 — after which `project down` / `project destroy` tear it down with the
durable host `.data` preserved. `test run all` **drives that same `project up`** under a test config (one
per distinct test config), asserts the live stack, and tears it down — reusing the chain rather than a
separate per-case cluster.
`DEVELOPMENT_PLAN/` owns the phase status; this page describes the model and the worked `demo/` consumer
that realizes it.

## See also

* [composition_methodology](../architecture/composition_methodology.md) — the canonical model: chain-is-the-project, the recursive `project up` interpreter, fractal bootstrap
* [authoring_project_binaries](authoring_project_binaries.md) — how a consumer authors its `chain` and step actions
* [library_hierarchy](../architecture/library_hierarchy.md) — the extension-stream contract (stream 1 = the lift chain)
* [base_image.md](base_image.md) — what the base image ships, including the warm core closure
* [warm_store.md](warm_store.md) — the Cabal store cache-hit contract
* [code_check_doctrine.md](code_check_doctrine.md) — the build-time code-check gate
* [linking_and_optimization.md](linking_and_optimization.md) — linking and optimisation defaults
* [harbor.md](harbor.md) — pushing the project image (out of scope for hostbootstrap itself)
* [binary_context_config](../architecture/binary_context_config.md) — the runtime sibling config file every normal command reads
