# Haskell

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/warm_store.md](../engineering/warm_store.md), [../engineering/code_check_doctrine.md](../engineering/code_check_doctrine.md), [../engineering/linking_and_optimization.md](../engineering/linking_and_optimization.md), [../engineering/testing.md](../engineering/testing.md)

> **Purpose**: Document the Haskell toolchain the base image ships and how derived projects build
> against it.

This page documents what the base image ships for Haskell.

The base image ships a **single current GHC** selected by GHCup's `recommended` tag, the corresponding
current recommended Cabal, and a warm Cabal store. `fourmolu`/`hlint`'s `ghc-lib-parser` targets 9.12, so
the same compiler serves formatting and project builds.

## Warm store

[`core/warm-deps/`](../../core/warm-deps/) declares the shared
dependency set. The base image builds it with
`--enable-tests --enable-benchmarks --enable-shared` at `-O2`. Downstream projects use their ordinary
host-compatible project unchanged; matching store artifacts are reused and misses resolve/compile
normally. See
[engineering/warm_store.md](../engineering/warm_store.md) for the contract and
the dep-addition workflow.

## fourmolu / hlint

Both are prebuilt into the base image at
`/opt/hostbootstrap/haskell-style/bin/`:

* current compatible `fourmolu`
* current compatible `hlint`

`/usr/local/bin/fourmolu` and `/usr/local/bin/hlint` are symlinks to that
directory. They are **container-only**: never installed, built, or run
on the host.

The base image smoke-tests both binaries during its own build (see
[engineering/code_check_doctrine.md](../engineering/code_check_doctrine.md));
derived projects invoke them via their own `<project> check-code` command as a
`RUN` step in the project Dockerfile.

## Editor support (HLS)

The repository is a multi-workspace Cabal layout with no project file at the root, so each Cabal
workspace carries its own `hie.yaml` cradle. This lets the Haskell Language Server provide hover,
go-to-definition, and diagnostics for every `.hs` file even when the repository root is opened as the
editor workspace. See the cradle table in
[engineering/cabal_layout.md](../engineering/cabal_layout.md#editor-and-hls-cradles).

## Project standardisation

All downstream projects standardise on GHC 9.12 as part of adopting
hostbootstrap. See
[engineering/derived_project_standards.md](../engineering/derived_project_standards.md)
for the full rule set every derived project follows, including the single-project rule and the
linking/optimisation policy in
[engineering/linking_and_optimization.md](../engineering/linking_and_optimization.md).

The type discipline those projects inherit is stated once in
[architecture/unrepresentable_state.md](../architecture/unrepresentable_state.md): where a value has one
lawful shape, the unlawful shapes have no constructor, and a boundary claiming that ships a compile-fail
fixture rather than a comment.

## Native Windows Build

Building `hostbootstrap-core` **host-native on Windows** — the native `hostbootstrap.exe`, the peer of
the macOS arm64 binary — uses the native (mingw32) Windows GHC, which reports
`System.Info.os == "mingw32"` rather than `"linux"` or `"darwin"`. The POSIX-only `unix` dependency is
conditionalized at its call sites, with the matching conditional `build-depends`, so the mingw32 build can
compile without it — the *dependency* is conditional, never the module. Current Windows gates and dated
evidence live in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md). Which layer owns the native binary
versus the thin Python bootstrapper that builds and invokes it (POSIX process replacement with `exec`;
Windows child subprocess) is the
[python_haskell_boundary](../architecture/python_haskell_boundary.md).

### Host-portability idioms

Because the binary is built host-native everywhere, the sources and the suites that gate them are
host-portable. Four idioms carry most of that weight:

- **`System.FilePath` versus `System.FilePath.Posix`.** The unqualified module follows the host. Use it
  for a **host** path — an executable the outer host resolves and invokes — and use the `Posix` module
  for a **guest** path, which names a file on a different machine reached through one host-provider
  command. `isAbsolute "/usr/bin/x"` is `False` on Windows under `filepath` 1.5 and later, because a
  drive-less path there is relative to the current drive; that is correct for a host path and wrong for
  a guest one.
- **Read source bytes for a digest.** A frozen source digest computed by decoding to `String` through
  the locale and re-encoding is a property of the host's active code page and of its newline
  translation, not of the file. Read the bytes.
- **Fix the encoding once at an entry point.** `HostBootstrap.CLI` sets `stdout`/`stderr` to UTF-8, and
  the test driver calls `setLocaleEncoding utf8` before the runner starts, so every later text read
  decodes the same characters and output containing non-ASCII text neither mojibakes nor throws on a
  legacy-code-page console.
- **Stub a platform module; do not exclude it.** A module a Cabal `os` condition removes is a module
  nothing on that family asserts, and the suite total reads the same either way — so a platform row is
  compiled everywhere and CPP-stubbed to a total refusal where it cannot apply. Only `build-depends` is
  conditional. That keeps every importer unconditional and makes an unavailable capability something the
  suite states rather than something it omits.

The rules these idioms serve are canonical in [testing](../engineering/testing.md#harness-portability).
