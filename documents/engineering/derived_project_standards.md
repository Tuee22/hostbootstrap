# Derived project standards

**Status**: Authoritative source
**Supersedes**: the execution-model / lifecycle ("five rules" tied to Container/HostBinary/HostDaemon) derived-project doctrine
**Referenced by**: [../README.md](../README.md), [base_image.md](base_image.md), [warm_store.md](warm_store.md), [code_check_doctrine.md](code_check_doctrine.md), [harbor.md](harbor.md), [linking_and_optimization.md](linking_and_optimization.md)

> **Purpose**: State the rules a derived project follows to build the one binary that extends
> `hostbootstrap-core`, inherit the base image, gate on `check-code`, and materialize the binary at
> `./.build/`.

This is the single page a derived project's author reads before writing their `docker/Dockerfile`,
`cabal.project`, and project binary. It is the union of the doctrine docs under
[`engineering/`](.), in the form of rules with one-line explanations and a link to the authoritative
source.

## The derived project is one binary that extends the core

A derived project ships **exactly one binary** named after `project` in
[`hostbootstrap.dhall`](schema.md). That binary extends `hostbootstrap-core`'s optparse command tree
rather than re-implementing core verbs:

```haskell
import HostBootstrap.CLI (runHostBootstrapCLI)

main :: IO ()
main = runHostBootstrapCLI "app" appProjectCommands
```

`runHostBootstrapCLI progName projectCommands` composes the project's own subcommands onto the core
tree (`ensure …`, substrate detection, cluster-lifecycle verbs, `check-code`, `config schema`,
`config render`). The skeletal `hostbootstrap` binary baked into the base image is the same tree with
no project commands. There is no execution-model, lifecycle, or mount declaration anywhere in the
project — those concepts are removed; the binary's own subcommands and its generated project/test
Dhall carry whatever runtime shape the project needs.

## The rules

1. **Inherit `FROM ${BASE_IMAGE}` and follow the Dockerfile rules.** POSIX `/bin/sh`, no pipes, no
   buildx, no `--platform`. See [base_image.md](base_image.md#dockerfile-rules).
2. **Use the warm-store `cabal.project` template AND import the warm-store freeze.** Set
   `with-compiler: ghc-9.12.4`, `tests: True`, `benchmarks: True`, `shared: True`,
   `optimization: 2`, and add `import: /opt/basecontainer/haskell-deps/cabal.project.freeze` in
   `cabal.project`. Derived projects ship **zero** `cabal.project.freeze` files of their own — the
   freeze lives only in the base image and is referenced at build time so version drift cannot
   happen. Add `hostbootstrap-core` as a `source-repository-package` (or local) dependency; its
   transitive closure is already warm in the store. Without the freeze import, the resolver picks
   different transitive versions than the warm store and rebuilds. See
   [warm_store.md](warm_store.md#required-import-the-freeze-file).
3. **Build the binary, run `<project> check-code`, and add a tini-wrapped `ENTRYPOINT`.** The check
   runs after the binary is installed and before any expensive backend work; the container is built
   on every substrate as the mandatory code-check gate. See
   [code_check_doctrine.md](code_check_doctrine.md#derived-images).
4. **Link executables statically; build libraries with `shared: True`.** Do not pass
   `--enable-executable-dynamic` or `--enable-executable-static`. See
   [linking_and_optimization.md](linking_and_optimization.md#recommended-policy).
5. **Don't rebuild what the warm store already builds.** Check
   `cabal build --dry-run --enable-tests --enable-benchmarks all` inside the container. If a
   third-party package (including a `hostbootstrap-core` dependency) shows up in the plan, fix your
   project's flags first; if it's a genuine miss, add it to
   [`support/haskell-deps/basecontainer-haskell-deps.cabal`](../../support/haskell-deps/basecontainer-haskell-deps.cabal).
   See [warm_store.md](warm_store.md#how-to-verify-your-project-hits-the-cache).

A project that follows all five rules has a Dockerfile that is small, a build that hits the cache,
a binary that extends the core command tree, and an image that cannot exist with code-check
violations.

## Build and run: where the binary lives

Every project produces a host binary at `./.build/<project>`, and its container is built on every
substrate as the code-check gate:

- On **Linux** the binary is built inside the project container (`FROM` the base image) and copied
  out to `./.build/<project>`; it runs on the host because host and container share the same glibc
  family.
- On **Apple silicon** a Linux ELF cannot exec on macOS, so the Python layer ensures a host GHC
  toolchain (via Homebrew) and the binary is built natively on the host into `./.build/<project>`.
  The container is still built as the code-check gate; Tart, when used, is build-only (Swift/Metal
  artifacts copied to `./.build/`) and never a runtime.

A `./.build/<project>` is always present after a successful bootstrap, regardless of substrate.

## Worked compliant Dockerfile shape

```dockerfile
# check=skip=InvalidDefaultArgInFrom

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

WORKDIR /workspace/app

COPY . /workspace/app

RUN cabal build --enable-tests --enable-benchmarks all \
    && install -m 0755 "$(cabal list-bin --enable-tests --enable-benchmarks exe:app)" /usr/local/bin/app

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

import: /opt/basecontainer/haskell-deps/cabal.project.freeze

tests: True
benchmarks: True
shared: True
optimization: 2

source-repository-package
  type: git
  location: https://github.com/tuee22/hostbootstrap.git
  subdir: hostbootstrap-core
```

No `cabal.project.freeze` is committed in the project — the warm-store freeze is imported from the
base image at build time, and `hostbootstrap-core`'s dependency closure is already warm.

## See also

* [base_image.md](base_image.md) — what the base image ships, including the skeletal `hostbootstrap`
  binary and the warm core closure
* [warm_store.md](warm_store.md) — the Cabal store cache-hit contract
* [code_check_doctrine.md](code_check_doctrine.md) — the build-time code-check gate
* [linking_and_optimization.md](linking_and_optimization.md) — linking and optimisation defaults
* [harbor.md](harbor.md) — pushing the project image (out of scope for hostbootstrap itself)
