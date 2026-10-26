# Cabal Layout

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [hostbootstrap_core_library](../architecture/hostbootstrap_core_library.md), [warm_store](warm_store.md), [haskell](../languages/haskell.md)

> **Purpose**: Record the `hostbootstrap-core` Cabal package layout — the GHC pin, the dependency
> surface, and the library/executable/test stanzas — so derived builds and the base image stay
> aligned with the warm Cabal store.

## TL;DR

- `hostbootstrap-core` is a single Cabal package built with the base-image GHC toolchain.
- `core/cabal.project` is the self-contained Cabal workspace for the core, the peer of the root-level
  Poetry project. The `demo/` consumer carries one `demo/cabal.project` used host-native and inside its
  derived container; the repository root holds no Cabal project file.
- The package ships one public `library` (the `HostBootstrap.*` surface), seven Cabal-private
  sublibraries, one `executable hostbootstrap` (the bare binary, built like any project binary — not
  baked into the base image), and two test suites; see [package stanzas](#package-stanzas).
- Each Cabal workspace carries its own `hie.yaml` so the Haskell Language Server resolves the right
  project when the repository root is opened as the editor workspace (`core/`, `demo/`, and a
  deliberate `none` cradle for the build-only `core/warm-deps/` stubs).

## GHC Pin

The core workspace currently selects its supported GHC explicitly:

```cabal
with-compiler: ghc-9.12.4
optimization: 2
```

That version is the same one the base image installs and the host bootstrapper pins, which is what lets
one `cabal.project` be valid host-native and inside the derived container: the compiler keys the warm
Cabal store, so a base carrying another one would ship a store this workspace could not read and could
not configure this project at all. It remains a compatibility choice rather than a base-input replay
lock — everything else in the base still rolls (§ FF) — and compatibility is validated by source gates
and a real consumer smoke. The demo's one project pins no compiler and needs none: it resolves the same
GHC on the host and in the container. Neither imports a base-owned path.

`with-compiler:` is one of the version's three asserted spellings; the `tested-with: GHC ==9.12.4` fields of
`hostbootstrap-core.cabal` and `hostbootstrap-demo.cabal` are two further copies that select nothing and
that no test asserts, so a GHC bump updates them by hand ([Haskell](../languages/haskell.md) names all
five).

`optimization: 2` is a top-level project setting, so it reaches only the workspace's local package; the
dependencies build with Cabal's per-package defaults. It therefore does not align dependency builds with
the warm store, and the store's own top-level settings likewise reach only its manifest packages (see
[warm store](warm_store.md#population-inputs)).

### Build resource bound

`core/cabal.project` also bounds the host memory a core build can take:

```cabal
jobs: 1

package *
  ghc-options: +RTS -M6144M -xr18432M -RTS
```

A per-process heap cap bounds the host only together with the number of compiler processes, so the job
count is pinned beside it: core builds compile one package at a time, and each GHC process has a 6 GiB
heap cap. A module that needs more than 6 GiB of heap fails the build rather than driving the host into
its out-of-memory path. `demo/cabal.project` carries neither setting; the demo's Dockerfile passes `-j1`
to its in-image build.

## Package Stanzas

[`core/hostbootstrap-core/hostbootstrap-core.cabal`](../../core/hostbootstrap-core/hostbootstrap-core.cabal)
is the source of truth for every stanza, its modules, and its dependencies. It declares:

| Stanza | Source directory | Contents |
|--------|------------------|----------|
| `library` | `src`, `internal/cluster-backend` | the public `HostBootstrap.*` module surface tracked in [`../../DEVELOPMENT_PLAN/system-components.md`](../../DEVELOPMENT_PLAN/system-components.md); it re-exports seven modules of `ownership-internal` (`HostBootstrap.Protected` and six `HostBootstrap.Ownership.*` modules) through `reexported-modules` |
| `library effect-internal` (private) | `internal/effect` | the effect vocabulary's runner, quoter, and child process group |
| `library harness-lifecycle-internal` (private) | `internal/harness-lifecycle` | the constructor boundary for Harness lifecycle actions, which the public `HostBootstrap.Harness` facade exposes without a constructor |
| `library ownership-internal` (private) | `internal/ownership` | the protected store, digests, and the ownership object, clause, row, and tape modules |
| `library colima-backend-internal` (private) | `internal/colima-backend` | the Colima backend's resolver, runner, routing, and staging |
| `library lifecycle-transaction-internal` (private) | `src` | the durable interrupted-transaction vocabulary a recovery fixture writes |
| `library network-port-internal` (private) | `internal/network-port` | the TCP `Port` type and its one constructor `mkPort` |
| `library lifecycle-dependency-internal` (private) | `src` | the backend-neutral runtime dependency commitments (`RuntimeDependencyPackage`) |
| `executable hostbootstrap` | `app` | `app/Main.hs`, the bare binary: `runBareHostBootstrapCLI "hostbootstrap"` |
| `test-suite hostbootstrap-core-test` | `test` | the `tasty` suite, including the documentation validator gate |
| `test-suite hostbootstrap-provider-live-linux-cpu` | `provider-live` | the destructive provider-live gate; it is compiled and run on every host by `cabal test all`, and `requirePlatformAndConfirmation` prints an unsupported line and exits successfully unless `HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM=incus-direct-host` is set, then refuses any host but native Linux/x86_64 |

A `visibility: private` sublibrary is importable only by components of this package, so a downstream
consumer cannot import its modules except through the public library's `reexported-modules`. A module
whose internals must stay out of downstream reach belongs in a private sublibrary rather than in the
public library's exposed modules.

Every component imports one `common warnings` stanza, which carries the project's whole warning policy:
`-Wall -Wcompat -Wincomplete-record-updates -Wincomplete-uni-patterns -Wredundant-constraints
-Wpartial-fields -Werror`. The policy is a property of the package rather than of a flag a caller
remembers, so a plain `cabal build` refuses exactly what the gate refuses. `hostbootstrap-demo.cabal`
carries the identical stanza. `-Wpartial-fields` is there because a record selector on a
multi-constructor type throws at the call site instead of failing to compile.

## Dependency Surface

The [`.cabal` file](../../core/hostbootstrap-core/hostbootstrap-core.cabal) is the source of truth for
each component's `build-depends`. The public library takes `optparse-applicative` (the composable command
tree) and `dhall` (the in-process project-local config decoder/generator) as its defining dependencies,
plus `aeson`, `base`, `bytestring`, `containers`, `crypton`, `directory`, `filepath`, `memory`, `network`,
`process`, `safe-exceptions`, `temporary`, and `text`, plus two platform dependencies: `unix` on
non-Windows and `Win32` on Windows, backing the POSIX prereq checks and the two ownership rows. The
private sublibraries draw only on that same set. The test suites add `tasty` and `tasty-hunit`.

The warm-store manifest names every one of these that is not a GHC boot package, except `crypton`: it
names `cryptonite` instead, so `crypton` reaches the base-image store only if the warm-store solve pulls it
in transitively. The store is an opportunistic cache either way (see [warm store](warm_store.md)), so a
miss compiles normally.

**Only `build-depends` is conditional.** No stanza excludes a module from a host family: a platform row is
compiled everywhere and stubbed to a total refusal where it cannot apply, so its importers are
unconditional and the suite states an unavailable capability rather than omitting it. See
[testing](testing.md).

## Editor And HLS Cradles

Because the repository root holds no Cabal project file, the Haskell Language Server cannot resolve a
project when the root is opened as the editor workspace (over code-server, Remote-SSH, or a local
editor). Each Cabal workspace therefore carries its own `hie.yaml`, so `hie-bios` discovers the
nearest cradle by walking up from each source file and runs `cabal` in the directory that owns the
matching `cabal.project`:

| Cradle | Workspace | Covers |
|--------|-----------|--------|
| `core/hie.yaml` | `core/cabal.project` | every `hostbootstrap-core` component: the public library, the private sublibraries, the `hostbootstrap` executable, and both test suites |
| `demo/hie.yaml` | `demo/cabal.project` | `hostbootstrap-demo` plus `hostbootstrap-core` from local source |
| `core/warm-deps/hie.yaml` | `core/warm-deps/cabal.project` | a deliberate `none` cradle (the build-only stubs — see below) |

The `core/` and `demo/` cradles are the bare `cradle: cabal:` form, which lets `cabal` pick the owning
component per file, so hover, go-to-definition, and diagnostics work for every `.hs` file in those
trees.

`core/warm-deps/` uses a `none` cradle on purpose. Its `basecontainer-core-deps` /
`basecontainer-daemon-deps` packages are build-only stubs (`main = pure ()`) whose `.cabal` files
exist only to pull the entire warm dependency closure so the base image can prebuild the shared Cabal
store (see [warm_store](warm_store.md)). They are intended for the base container and would solve/build
hundreds of packages on the host. The `none` cradle makes HLS skip them deliberately instead of failing
slowly.

A single root-level cradle is intentionally not used: a `cabal` cradle anchored at the repository
root would run `cabal` where no project file exists and fail for every file.

## Build And Test

- `cabal build all` builds the library and the bare executable, warning-clean by the package's own
  policy — there is no `--ghc-options=-Werror` to remember.
- `cabal test all` runs both test suites: the `tasty` suite, including the `DocValidatorSpec`
  documentation gate, and the provider-live suite, which reports itself unsupported and passes unless its
  confirmation is set.
- `hostbootstrap --help` prints the composed core command tree, which lists the `context`, `project`,
  `test`, `service`, and `check-code` verbs.
