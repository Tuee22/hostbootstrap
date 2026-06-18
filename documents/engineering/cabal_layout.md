# Cabal Layout

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md), [warm_store](warm_store.md), [haskell](../languages/haskell.md)

> **Purpose**: Record the `hostbootstrap-core` Cabal package layout — the GHC pin, the dependency
> surface, and the library/executable/test stanzas — so derived builds and the base image stay
> aligned with the warm Cabal store.

## TL;DR

- `hostbootstrap-core` is a single Cabal package built with the base-image GHC toolchain.
- `core/cabal.project` — the self-contained Cabal workspace for the core, the peer of the
  root-level Poetry project — pins `with-compiler: ghc-9.12.4` and `optimization: 2` to match the warm store
  baked into the base image (see [warm_store](warm_store.md)). The `demo/` consumer carries its own
  `demo/cabal.project`; the repository root holds no Cabal project file.
- The package ships one `library` (the `HostBootstrap.*` surface), one `executable hostbootstrap`
  (the bare binary, built like any project binary — not baked into the base image), and one
  `test-suite`.
- Each Cabal workspace carries its own `hie.yaml` so the Haskell Language Server resolves the right
  project when the repository root is opened as the editor workspace (`core/`, `demo/`, and a
  deliberate `none` cradle for the build-only `core/warm-deps/` stubs).

## GHC Pin

The GHC version is pinned in `core/cabal.project` to the base-image toolchain:

```cabal
with-compiler: ghc-9.12.4
optimization: 2
```

The pin and optimisation level match `core/warm-deps/cabal.project`, which warms the shared
dependency set into the frozen Cabal store. Pinning both means a derived project that builds
`hostbootstrap-core` reuses the pre-built dependency unfoldings instead of recompiling them.

## Package Stanzas

`core/hostbootstrap-core/hostbootstrap-core.cabal` declares:

| Stanza | Contents |
|--------|----------|
| `library` | the `HostBootstrap.*` module surface tracked in [`../../DEVELOPMENT_PLAN/system-components.md`](../../DEVELOPMENT_PLAN/system-components.md) |
| `executable hostbootstrap` | `app/Main.hs`, the bare binary: `runBareHostBootstrapCLI "hostbootstrap"` |
| `test-suite hostbootstrap-core-test` | the `tasty` suite, including the documentation validator gate |

## Dependency Surface

The library takes `optparse-applicative` (the composable command tree) and `dhall` (the in-process
project-local config decoder/generator) as its defining dependencies, plus the small set used by host-tool
resolution and the reconcilers (`base`, `containers`, `directory`, `filepath`, `process`,
`safe-exceptions`, `text`, and `unix` — the last backing the POSIX prereq checks in
`HostPrereqs` via `System.Posix`). Every one of these is already warmed into the base-image Cabal
store.

## Editor And HLS Cradles

Because the repository root holds no Cabal project file, the Haskell Language Server cannot resolve a
project when the root is opened as the editor workspace (over code-server, Remote-SSH, or a local
editor). Each Cabal workspace therefore carries its own `hie.yaml`, so `hie-bios` discovers the
nearest cradle by walking up from each source file and runs `cabal` in the directory that owns the
matching `cabal.project`:

| Cradle | Workspace | Covers |
|--------|-----------|--------|
| `core/hie.yaml` | `core/cabal.project` | the `hostbootstrap-core` library, the `hostbootstrap` executable, and the `hostbootstrap-core-test` suite |
| `demo/hie.yaml` | `demo/cabal.project` | `hostbootstrap-demo` plus `hostbootstrap-core` from local source |
| `core/warm-deps/hie.yaml` | `core/warm-deps/cabal.project` | a deliberate `none` cradle (the build-only stubs — see below) |

The `core/` and `demo/` cradles are the bare `cradle: cabal:` form, which lets `cabal` pick the owning
component per file, so hover, go-to-definition, and diagnostics work for every `.hs` file in those
trees.

`core/warm-deps/` uses a `none` cradle on purpose. Its `basecontainer-core-deps` /
`basecontainer-daemon-deps` packages are build-only stubs (`main = pure ()`) whose `.cabal` files
exist only to pull the entire warm dependency closure so the base image can prebuild the shared Cabal
store (see [warm_store](warm_store.md)). They build only inside the container, and their
`core.freeze` / `daemon.freeze` pins are generated in-image and never committed, so there is no
host-resolvable build plan — a `cabal` cradle there would try to solve and build hundreds of packages
on the host. The `none` cradle makes HLS skip them deliberately instead of failing slowly.

A single root-level cradle is intentionally not used: a `cabal` cradle anchored at the repository
root would run `cabal` where no project file exists and fail for every file.

## Build And Test

- `cabal build all` builds the library and the bare executable.
- `cabal test all` runs the `tasty` suite, including the `DocValidatorSpec` documentation gate.
- `hostbootstrap --help` prints the composed core command tree, which lists the `ensure`, `config`,
  and `cluster` verbs today.
