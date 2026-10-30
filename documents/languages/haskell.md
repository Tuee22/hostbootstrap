# Haskell

**Status**: Supporting reference
**Supersedes**: N/A
**Referenced by**: [../README.md](../README.md), [../engineering/warm_store.md](../engineering/warm_store.md), [../engineering/code_check_doctrine.md](../engineering/code_check_doctrine.md), [../engineering/linking_and_optimization.md](../engineering/linking_and_optimization.md), [../engineering/testing.md](../engineering/testing.md)

> **Purpose**: Document the Haskell toolchain the base image ships and how derived projects build
> against it.

This page documents what the base image ships for Haskell.

The base image ships a **single pinned GHC**, the corresponding current recommended Cabal, and a warm
Cabal store built by that compiler.

The version is one family constant with three governing spellings: `GHC_VERSION` in
[`hostbootstrap/bootstrap.py`](../../hostbootstrap/bootstrap.py), which the host bootstrapper installs
and the base image build receives as a build argument; `with-compiler:` in
[`core/cabal.project`](../../core/cabal.project); and the worked demo's guest-bootstrap literal
`PinnedToolchain "9.12.4"` in [`demo/src/HostBootstrapDemo/Commands.hs`](../../demo/src/HostBootstrapDemo/Commands.hs)
(the core `PinnedToolchain` type carries no version of its own).
The first is the source, the other two cannot read it, and a Python test
(`test_one_ghc_version_governs_host_image_and_guest`) asserts all three agree. Two further copies, the
`tested-with` fields of [`hostbootstrap-core.cabal`](../../core/hostbootstrap-core/hostbootstrap-core.cabal)
and [`hostbootstrap-demo.cabal`](../../demo/hostbootstrap-demo.cabal), are package metadata that selects
nothing; no test asserts them, so a GHC bump updates them by hand. See
[engineering/cabal_layout.md](../engineering/cabal_layout.md#ghc-pin).

## Warm store

[`core/warm-deps/`](../../core/warm-deps/) declares the shared
dependency set. The base image builds it with a plain `cabal build all`; tests, benchmarks, shared
libraries, and `-O2` come from the `tests: True`, `benchmarks: True`, `shared: True`, and
`optimization: 2` settings in
[`core/warm-deps/warm-store.config`](../../core/warm-deps/warm-store.config), which the warm-store
project imports, not from command-line flags. Those top-level settings reach only the two manifest
packages; the cached dependencies build with Cabal's per-package defaults (see
[population inputs](../engineering/warm_store.md#population-inputs)). Downstream projects use their ordinary
host-compatible project unchanged; matching store artifacts are reused and misses resolve/compile
normally. See
[engineering/warm_store.md](../engineering/warm_store.md) for the contract and
the dep-addition workflow.

## fourmolu / hlint

Both are prebuilt into the base image at
`/opt/hostbootstrap/haskell-style/bin/`:

* `fourmolu`, the newest Hackage release Cabal's solver can build with the pinned GHC
* `hlint`, likewise

The layer runs `cabal install` with no version constraint and no index-state pin, so the baked versions
follow Hackage from one rebuild to the next.

`/usr/local/bin/fourmolu` and `/usr/local/bin/hlint` are symlinks to that
directory.

The base publisher's repository source gate — the pre-build gate `base build` and
`base build-and-push` run on the maintainer's host through `_style_gates` in
[`hostbootstrap/cli.py`](../../hostbootstrap/cli.py) — runs both before any Docker build, against the
committed [`fourmolu.yaml`](../../fourmolu.yaml) and [`.hlint.yaml`](../../.hlint.yaml). The four-command
host static gate runs neither. `fourmolu.yaml` writes out every formatter setting, so a change in
fourmolu's defaults does not change the formatting; `.hlint.yaml` keeps hlint's default rule set and
declines named hint families, so a hint a later hlint release adds can fail the gate. Neither tool's
version is pinned, on the host or in the base, so a printer or parser change between releases can also
change a gate's outcome. A maintainer running
`base build` or `base build-and-push` therefore needs both on `PATH`, at a
version compatible with the pinned GHC;
[engineering/code_check_doctrine.md](../engineering/code_check_doctrine.md#where-the-style-tools-run) is
the canonical home for where the style tools run.

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
  command. `isAbsolute "/usr/bin/x"` is `False` on Windows, because a drive-less path there is relative
  to the current drive; that is correct for a host path and wrong for a guest one.
- **Read source bytes for a digest.** A frozen source digest computed by decoding to `String` through
  the locale and re-encoding is a property of the host's active code page and of its newline
  translation, not of the file. Read the bytes. The core portability guard recognizes parenthesized,
  composed, and `$` spellings of digesting re-encoded text.
- **Fix the encoding once at an entry point.** `HostBootstrap.CLI` sets `stdout`/`stderr` to UTF-8.
  Both core and demo suite drivers make `setLocaleEncoding utf8` their first IO action, before
  argument dispatch, source reads or the runner's first demand of standard handles. Their text reads
  and first-opened standard handles therefore use the selected encoding. The demo suite checks its
  runtime locale and retains Unicode case names in the complete reporter output.
- **Stub a platform module; do not exclude it.** A module a Cabal `os` condition removes is a module
  nothing on that family asserts, and the suite total reads the same either way — so a platform row is
  compiled everywhere and CPP-stubbed to a total refusal where it cannot apply. Only `build-depends` is
  conditional. That keeps every importer unconditional and makes an unavailable capability something the
  suite states rather than something it omits. One core suite family does not yet follow this idiom (see
  [Current Status](#current-status)).

The rules these idioms serve are canonical in [testing](../engineering/testing.md#harness-portability).

The test helpers keep the same distinction: `PlatformPath.hostFixturePath` supplies an absolute host
root and discards caller-supplied drive decorations, while guest descriptors retain POSIX grammar.
An unrecognized `--hostbootstrap-` probe argument exits with status 97 and a standard-error diagnostic.
`ConditionalCase` records successful row/refusal callback completions, and the final `CoverageManifest`
case checks those counts after the suite. Completion records establish that the callback returned;
the assertions inside the callback establish what it proves.

The core suite's `SourceGuard` supplies the lexical reader, sorted source walkers, and Cabal component
and common-stanza readers used by repository guards. Effective source roots include imported common
fields; module fields accept inline, continued, comma-separated, and mixed-case spellings. The inventory
includes private libraries and every test-suite root, excluding separately compiled negative fixtures.
The warning guard checks the core and demo components against their shared warnings stanzas: every
component imports the policy, none weakens it, and no source module supplies an `OPTIONS_GHC` or
`OPTIONS` pragma. Both packages carry `-Werror` and `-Wpartial-fields`, so ordinary Cabal commands hold
the warning policy. [Testing](../engineering/testing.md#one-toolkit-for-reading-this-repositorys-own-sources)
owns the complete harness contract.

## Current Status

`HostToolSpec.windowsResolutionCases` keeps both System32 cases on every host. Windows checks the
host's SystemRoot-derived paths; other hosts assert the exact `Nothing` answers. The two-case family
is counted by `CoverageManifest`, including successful conditional row and refusal observations.
