# Phase 2 — Haskell core scaffolding

**Status**: Done
**Depends on**: Phase 1 (Python pre-binary floor)
**Substrates**: none (static)
**Gate**: `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/`, host-native on
every supported outer host realization

> **Purpose**: Establish the `hostbootstrap-core` package, its pinned compiler, and the generic CLI
> entrypoint every consuming project binary is built from.

## Phase Objective

Create the library that owns everything after the pre-binary floor: one Cabal package, one pinned GHC, one
warm-store-compatible optimisation level, and one entrypoint a project binary calls to inherit the fixed
command tree. Nothing here knows about hosts, providers, or lifecycles — it is the shell the rest is built
inside.

The suite that gates that shell is part of it. § N builds the binary host-native on every substrate, so
this phase also owns the harness foundation that lets the host static gate run host-native on every
supported outer host realization (§ JJ): the fixture-path constructor, the separator-neutral
repo-relative path helper, the suite driver's locale, the coverage manifest that makes an unrun case say
so, and the absence guards that keep a host-specific shape out of a host-portable suite.

It owns § NN's evidence contract in the same way it owns § JJ's rules — as the shared foundation, plus
the guards for the shapes that are the harness's own. A guard against a shape in *production* is shipped
by the phase whose work removes that shape (§ I), because a guard is an assertion that something a phase
built is gone, and only that phase can make it gone.

## Sprints

### Sprint 2.1: The Cabal package and compiler pin [Done]

**Status**: Done
**Implementation**: `core/cabal.project`, `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hie.yaml`
**Substrates**: none
**Docs to update**: `documents/engineering/cabal_layout.md`

#### Objective

One self-contained Haskell workspace with a pinned toolchain.

#### Deliverables

- `core/cabal.project` names the single package and pins `with-compiler: ghc-9.12.4`.
- `optimization: 2` matches the warm Cabal store baked into the base image, so derived builds reuse the
  pre-built dependency unfoldings.
- The package declares a library, an executable (`hostbootstrap`), and one test suite.
- `-Werror` is supplied by the gate rather than baked into the package, so a warm tree cannot hide a
  warning the clean gate would catch.
- The same `cabal.project` is used host-native and inside the derived container; there is no
  container-only project file and no base-owned freeze import.

#### Validation

`cabal build all` and `cabal test all --ghc-options=-Werror` from `core/`.

#### Remaining Work

None.

### Sprint 2.2: The generic CLI entrypoint [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/app/Main.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Give a project binary one function to call, and give the bare library binary its own.

#### Deliverables

- `runHostBootstrapCLI` is the entrypoint a consuming project binary calls; it supplies the fixed command
  tree and dispatches into the project's own extension streams.
- `runBareHostBootstrapCLI` is the separate entrypoint for `hostbootstrap-core`'s own executable, which
  carries no installed project config family.
- The two are distinct functions rather than one function with a mode flag, so a bare invocation cannot
  present itself as a project.
- Argument parsing is `optparse`-based and the command tree is closed at this layer.

#### Validation

`CLISpec` covers dispatch for each verb and the bare-versus-project entrypoint distinction.

#### Remaining Work

None.

### Sprint 2.3: Host-portable test harness foundation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/Spec.hs`,
`core/hostbootstrap-core/test/SourceGuard.hs`, `core/hostbootstrap-core/test/PlatformPath.hs`,
`core/hostbootstrap-core/test/PortabilitySpec.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal` (test `other-modules` only)
**Substrates**: none
**Docs to update**: `documents/engineering/testing.md`, `documents/languages/haskell.md`

#### Objective

Give every suite one way to say "absolute on this host", "this repo-relative module", and "these source
bytes", so the host static gate proves the same contracts on every supported outer host realization.

#### Deliverables

- The suite driver fixes the locale encoding before the runner starts, so a spec that reads a source
  file or captured command output decodes the same text regardless of the host's active code page.
- It fixes the process's file-creation mask in the same place and for the same reason. A fixture that
  writes a file inherits the launching shell's umask, so on a host whose umask is `0002` every fixture
  file is group-writable and a subject that refuses a group-writable input fails there while passing on a
  host whose umask is `0022`. Normalizing the mask to `0022` before any fixture runs makes what a fixture
  writes the same on every gate host, so the assertion stays a property of the code under test rather
  than of the shell that launched the gate (§ JJ). The definition is total on Windows, which has no mask
  to normalize.
- A frozen source digest is therefore a digest of the file's own bytes, and a governed golden containing
  non-ASCII text compares equal on every host.
- `SourceGuard` exposes one separator-neutral repo-relative path helper, so an import allow-list,
  importer set, or module-ownership list compares canonical forward-slash paths.
- `PlatformPath` exposes one total constructor for an absolute **host** fixture path. A guest path is a
  path on a different machine and stays POSIX, matching the invocation split § K already draws.
- A compile-fail fixture over a hidden module expects one contiguous diagnostic, because the module it
  names is built on every gate host and is unreachable from a public importer for the same reason
  everywhere.
- A frozen source digest is computed from the file's own bytes rather than from a locale-decoded read,
  so it is a property of the file and not of the gate host's code page or newline translation (§ JJ).
- `PortabilitySpec` carries the absence guards that keep each shape from returning: no spec derives a
  frozen digest from a locale-decoded read, the driver applies the locale fix rather than merely
  importing it, the separator rewrite lives in exactly one harness module, `SourceGuard` is the only
  module that turns a source path into a comparable name, and no host tool-path fixture reaches the total
  `AbsExe` constructor as a POSIX-absolute literal. Each names its
  [rationale.md](rationale.md) § Gates and validation entry.
- The work is test-harness only: no production module, no named production type, and no command call
  site.

#### Validation

The three helpers are exercised by the suites that consume them rather than in isolation, because a
harness helper with only its own unit test proves nothing about the guards it is there to make portable.
The evidence is the gate itself: `cabal build all` and `cabal test all --ghc-options=-Werror` from
`core/`, run host-native and recorded against the gate host that ran it (§ JJ).

Dated evidence: on 2026-08-17, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/` host-native — all 1,878
tests in 503.74 seconds — alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231 passed. That run includes the `PortabilitySpec`
absence guards this sprint ships — the byte-read guard among them — and every suite its helpers reach. It
is a native-Windows pass of the complete host static gate.

Confirming the same gate on a macOS and a Linux gate host is not this sprint's obligation and not this
phase's: it needs three machines, which § C forbids a baseline phase owing, and the
[host-portability acceptance phase](phase-28-host-portability-acceptance.md) owns it.

#### Remaining Work

None.

### Sprint 2.4: The fifth rule and the coverage manifest [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/PortabilitySpec.hs`, `core/hostbootstrap-core/test/Spec.hs`,
`core/hostbootstrap-core/test/WslGlobalWallHostSpec.hs`,
`core/hostbootstrap-core/test/WslGlobalWallWindowsSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Posix.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`
**Substrates**: none
**Docs to update**: `documents/engineering/testing.md`, `documents/languages/haskell.md`

#### Objective

Give the harness § JJ's fifth rule, so a case whose subject this gate host cannot hold says so instead of
disappearing, and give the gate the two § NN absence guards whose shapes are the harness's own.

#### Deliverables

- A case whose subject is unavailable on this gate host asserts the refusal its row declares rather than
  disappearing. A conditional changes an expectation; it does not remove a case. Both host-wall platform
  rows carry one `rowCase` that runs the body where the row holds and asserts the row's total refusal
  where it does not, and the Windows row's first case asserts that the row's own declaration agrees with
  the gate host it is running on.
- `CoverageManifest` declares, per family, the family's size on **every** gate host, how many of those
  cases drive the platform row, and why the row is conditional. The driver assembles the manifest from
  the same list the runner is given, so what it counts is what runs, and each row's case *name* carries
  the report — the gate output says which families exercised a real kernel and which recorded a refusal.
- Platform rows are compiled on every host and stubbed to a total refusal where they cannot apply:
  `HostBootstrap.Wsl2.GlobalWall.Posix` gains `posixGlobalWallSupported` and a refusing backend, and
  `HostBootstrap.Handoff.Process` gains a refusal naming the POSIX group signal it needs. The package
  description therefore carries no `os()`- or `arch()`-conditional module or `buildable` field, and the
  opt-in live-provider suite is gated by its flag alone — a second host condition would answer "asked for
  and not built" with the same green nothing as "not asked for".
- Because the process owner is no longer excluded anywhere, its compile-fail fixture expects one
  diagnostic rather than one per host, and the suite driver carries no platform `#if` at all.
- `PortabilitySpec` gains the two absence guards for the harness's own shapes, each naming its
  [rationale.md](rationale.md) § Gates and validation entry: no `os()`/`arch()` condition decides which
  modules the package builds, and no spec renames the suite process's own `PATH`.
- The work is test-harness and package-description apart from the two platform rows' refusal branches; it
  introduces no new production module, no new named production type, and no command call site.

#### Validation

`PortabilitySpec` proves each guard is non-vacuous by naming the shape it forbids and finding none; the
package-description guard was additionally exercised against a reintroduced `if !os(linux) buildable`
stanza and reported it. The manifest is proved by the gate itself: the declared per-family size is part of
the run, so a suite that silently stopped running a group fails on the count rather than passing with a
smaller one.

Dated evidence: on 2026-08-17, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/` host-native at
1,950/1,950 in 235.04 seconds, plus `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231 passed. Twenty of those cases are the POSIX row's,
which this gate host previously did not compile at all. On this gate host the manifest reports the POSIX
row's 17 row-driven cases asserting its declared refusal and the Win32 row's 3 exercising the kernel; on a
POSIX gate host the same cases run with the two reports exchanged.

#### Remaining Work

None.

## Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` — the library's surfaced command tree and the two
  entrypoints.

**Engineering docs to create/update:**
- `documents/engineering/cabal_layout.md` — the workspace layout, compiler pin, and optimisation level.
- `documents/engineering/testing.md` — the gate kinds and the harness portability rules.

**Language docs to create/update:**
- `documents/languages/haskell.md` — the host-portability idioms a suite uses.

**Cross-references to add:**
- root `README.md` names the repository layout and the hosts the fast suites run on.
- `CLAUDE.md` and `AGENTS.md` name the `core/`-rooted build and test commands.
