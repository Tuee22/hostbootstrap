# Phase 2 — Haskell core scaffolding

**Status**: Active
**Depends on**: Phase 1 (Python pre-binary floor)
**Substrates**: none (static)
**Gate**: `cabal build all` and `cabal test all` from `core/`, on the gate host
that runs it — § C forbids a baseline phase owing evidence from a family it does not declare, and
cross-family confirmation belongs to the
[host-portability acceptance phase](phase-29-host-portability-acceptance.md)
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-12 ; x86_64 Ubuntu 24.04.4 LTS, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal build all && cabal test all` ; pass ; covers in-gate

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
- The package declares the main library, seven private sublibraries (`effect-internal`,
  `harness-lifecycle-internal`, `ownership-internal`, `colima-backend-internal`,
  `lifecycle-transaction-internal`, `network-port-internal`, `lifecycle-dependency-internal`), one
  executable (`hostbootstrap`), and two test suites: `hostbootstrap-core-test` and the live-provider suite
  `hostbootstrap-provider-live-linux-cpu`. `documents/engineering/cabal_layout.md` carries the full
  component list.
- Every component that imports `crypton` carries the shared `crypton <1.1` compatibility ceiling. The
  project currently targets the 1.0 API; an unconstrained current-index solve otherwise selects the
  source-incompatible 1.1 series and makes a clean host build depend on stale store contents.
- The warning policy lives in the package's own `common warnings` stanza (Sprint 2.6), so every
  component of the package inherits it and no component opts out.
- The same `cabal.project` is used host-native and inside the derived container; there is no
  container-only project file and no base-owned freeze import.

#### Validation

`cabal build all` and `cabal test all` from `core/`; the package's `common warnings` stanza carries
`-Werror`, so the plain commands hold the warning policy (Sprint 2.6).

#### Remaining Work

None. Revalidated 2026-08-23 against the current Hackage index from an empty build tree: Cabal selected
`crypton-1.0.6` through the explicit shared ceiling and compiled the core library and demo executable.

### Sprint 2.2: The generic CLI entrypoint [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
`core/hostbootstrap-core/app/Main.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Substrates**: none
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Give a project binary one function to call, and give the bare library binary its own. How the bare init
builder reports an assembly refusal belongs to the configuration-initialization contract of the
[Dhall configuration and project-model phase](phase-7-dhall-configuration-and-project-model.md), and the
case that pins the five-verb command surface to the [service-runtime phase](phase-22-service-runtime.md),
where the last verb exists.

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

### Sprint 2.3: Host-portable test harness foundation [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/test/Spec.hs`,
`core/hostbootstrap-core/test/SourceGuard.hs`, `core/hostbootstrap-core/test/PlatformPath.hs`,
`core/hostbootstrap-core/test/PortabilitySpec.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal` (test `other-modules` only)
**Substrates**: none
**Docs to update**: `documents/engineering/testing.md`, `documents/languages/haskell.md`

#### Objective

Give every suite one way to say "absolute on this host", "this repo-relative module", and "these source
bytes", so the host static gate proves the same contracts on every supported outer host realization.
The work is test-harness only: no production module, no named production type, and no command call site.

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
- A frozen source digest is computed from the file's own bytes rather than from a locale-decoded read, so
  it is a property of the file and not of the gate host's code page or newline translation (§ JJ), and a
  governed golden containing non-ASCII text compares equal on every host.
- `SourceGuard` exposes one separator-neutral repo-relative path helper, so an import allow-list,
  importer set, or module-ownership list compares canonical forward-slash paths.
- `PlatformPath` exposes one total constructor for an absolute **host** fixture path: no argument,
  including one whose first segment names a drive (`D:/x`), yields a path the host calls relative. A guest
  path is a path on a different machine and stays POSIX, matching the invocation split § K already draws.
- The suite driver refuses a re-entrant probe argument vector it does not recognize: an argv whose head
  begins with `--hostbootstrap-` and matches no probe branch exits with a distinctive status rather than
  falling through to the full-suite branch, so a renamed or wrong-arity probe flag cannot satisfy a parent
  that judges the probe only by the absence of an effect.
- A compile-fail fixture over a hidden module carries one host-independent expectation rather than one per
  host, because the module it names is built on every gate host and is unreachable from a public importer
  for the same reason everywhere. The matcher that requires each expected phrase to match inside a single
  diagnostic block is Sprint 5.10's, in the
  [installed-identity and authority-kernels phase](phase-5-installed-identity-and-authority-kernels.md).
- `PortabilitySpec` carries the absence guards that keep each shape from returning: no spec derives a
  frozen digest from a locale-decoded read, in any spelling (application, `.` composition, or `$`); the
  driver applies the locale fix as the first statement of `main`, before any file read or `defaultMain`;
  a separator rewrite lives only in the two harness modules that own one — `SourceGuard` for
  repo-relative names and `PlatformPath` for the host-path-to-POSIX-descriptor rendering; `SourceGuard` is
  the only module that turns a source path into a comparable name; and no host tool-path fixture reaches
  the total `AbsExe` constructor as a POSIX-absolute literal. Each case's failure message names its
  [rationale.md](rationale.md) § Gates and validation entry by heading.

#### Validation

The three helpers are exercised by the suites that consume them rather than in isolation, because a
harness helper with only its own unit test proves nothing about the guards it is there to make portable.
The evidence is the gate itself: `cabal build all` and `cabal test all` from `core/`, run host-native and
recorded against the gate host that ran it (§ JJ). Closure requires these cases to exist and pass there:

- `PortabilitySpec` "no frozen digest is derived from a locale-decoded read" fails on the point-free
  spelling `childConfigDigest . TextEncoding.encodeUtf8 . Text.pack` and on the `$` spelling as well as the
  parenthesised one, and passes over the tree because `HandoffSpec` takes no such digest.
- `PortabilitySpec` "the suite driver fixes the locale encoding before the runner starts" asserts that the
  token index of `setLocaleEncoding utf8` in `Spec.hs` precedes the first `readFile`, `getArgs`, and
  `defaultMain` token of `main`.
- `PortabilitySpec`'s separator case, renamed "a separator rewrite lives only in SourceGuard and
  PlatformPath", fails on a backslash character literal, a `"\\"` string literal, a `splitDirectories`
  identifier, or an `import System.FilePath.Posix` outside those two modules (a `splitDirectories` inside a
  string literal is not an occurrence).
- A `PortabilitySpec` case "hostFixturePath is absolute for a drive-letter segment" asserts
  `isAbsolute (hostFixturePath "D:/x")` and `isAbsolute (hostFixturePath "/D:/x")` on every gate host.
- A `PortabilitySpec` case "an unrecognized probe flag is refused" launches the suite executable with
  `["--hostbootstrap-no-such-probe"]` and asserts the distinctive exit status and empty standard output.
- Each `PortabilitySpec` case's failure message contains the heading of its rationale.md § Gates and
  validation entry, and a case asserts that every heading so named exists in `DEVELOPMENT_PLAN/rationale.md`.

Dated evidence: on 2026-08-17, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/` host-native — all 1,878
tests in 503.74 seconds — alongside `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231 passed. That run includes the `PortabilitySpec`
absence guards this sprint ships — the byte-read guard among them — and every suite its helpers reach. It
is a native-Windows pass of the complete host static gate.

Confirming the same gate on a macOS and a Linux gate host is not this sprint's obligation and not this
phase's: it needs three machines, which § C forbids a baseline phase owing, and the
[host-portability acceptance phase](phase-29-host-portability-acceptance.md) owns it.

#### Remaining Work

- `core/hostbootstrap-core/test/HandoffSpec.hs` (the two `digest = childConfigDigest .
  TextEncoding.encodeUtf8 . Text.pack` bindings): read the frozen sources with `Data.ByteString.readFile`
  and digest the bytes directly. Then extend `reencodedDigestSequences` in `PortabilitySpec` (or replace it
  with a window search) so any `encodeUtf8` token within the same binding as a `childConfigDigest` or
  `sha256Text` token fails, whether joined by `(`, `.`, or `$`.
- `PortabilitySpec` locale case: compare token positions in `Spec.hs` so `setLocaleEncoding utf8` must
  precede the first `getArgs`, `readFile`, and `defaultMain` token after `main =`.
- `PortabilitySpec` separator case: rename it and widen it to the four shapes named in Validation, with an
  allow-list of exactly `SourceGuard.hs` and `PlatformPath.hs`.
- `core/hostbootstrap-core/test/PlatformPath.hs` `posixSegments`: drop a segment that ends in `:` (or
  refuse it with `error` naming the argument), so `hostFixturePath` cannot yield a drive-relative path on
  Windows; add the drive-letter case named in Validation.
- `core/hostbootstrap-core/test/Spec.hs`: after every existing probe branch (including the
  `shippedCommandEntryArguments` branch) and immediately before the catch-all, add a branch that matches any argv whose
  head begins with `--hostbootstrap-`, writes `unrecognized probe: <argv>` to standard error, and exits
  with `ExitFailure 97`; add the launch case named in Validation. In `AuthoritySpec`'s case that launches
  `--hostbootstrap-liveness-inheritance-probe`, assert `getProcessExitCode` on the probe answers `Nothing`
  at the moment the parent reacquires, so the case judges a running probe rather than an absent one.
- Give every `PortabilitySpec` failure message its rationale.md heading (the guards of Sprints 2.3, 2.4,
  and 2.6 alike) and add the case that checks each named heading exists.

### Sprint 2.4: The fifth rule and the coverage manifest [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/PortabilitySpec.hs`, `core/hostbootstrap-core/test/Spec.hs`,
`core/hostbootstrap-core/test/WslGlobalWallHostSpec.hs`,
`core/hostbootstrap-core/test/WslGlobalWallWindowsSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Wsl2/GlobalWall/Host.hs`,
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
  the same list the runner is given, so what it counts is what runs. Each row's report is observed, not
  declared: every conditional case reaches its row-or-refusal branch through one recording combinator,
  and a final manifest case compares the observed number of row-branch and refusal-branch completions per
  family against `familyRowCases` and `familyRowHolds`, so a refusal branch cut to `pure ()` or a branch
  that never ran fails the gate rather than printing a passing report.
- Platform rows are compiled on every host and answer a total refusal where they cannot apply. The POSIX
  ownership row declares `HostBootstrap.Ownership.Posix.posixOwnershipSupported`, and the WSL global-wall
  host families read `HostBootstrap.Ownership.Row.hostOwnershipSupported`; the global-wall modules are
  `HostBootstrap.Wsl2.GlobalWall.Host`, `.Windows`, and `.ConfigBytes`. `HostBootstrap.Handoff.Process`
  is compiled everywhere and ends its child through `HostBootstrap.Effect.ChildGroup`, which carries no
  total non-POSIX refusal: on POSIX it signals the child's process group, and its Windows row is
  `terminateProcess` of the single launched child, which ends that child and not processes it launched. The package
  description carries no `os()`-, `arch()`-, or `flag()`-conditional module or `buildable` field (only
  `build-depends` binds `unix` or `Win32` per host), and the live-provider suite is compiled on every host
  and decides at runtime through `requirePlatformAndConfirmation` whether its subject is available.
- The process owner's compile-fail fixture carries one expectation rather than one per host. The suite
  driver carries no platform `#if` that removes a case; its only conditionals are the
  `System.Posix.Files` import and the `fixFileCreationMask` definition (Sprint 2.3).
- `PortabilitySpec` gains the two absence guards for the harness's own shapes, each naming its
  [rationale.md](rationale.md) § Gates and validation entry: no `os()`, `arch()`, or `flag()` condition —
  in an `if` or an `elif`, under any field-name case — decides which modules the package builds or whether
  a component is buildable, and no spec binds `PATH` — not the suite process's own through `setEnv` or
  `unsetEnv`, and not a child's through a `"PATH"` or `"Path"` string token in an environment-binding
  position (the first element of a binding tuple, or an `env = Just` list) — outside an explicit allow-list.
  The allow-list holds exactly `RecursiveLifecycleSpec.recursiveFixtureEnvironment`, whose `fixture-tools`
  stand-ins are the process-transport fixture the recursive-lifecycle phase records as not being evidence
  of a provider crossing (§ NN), and each entry carries that rationale.
- The work is test-harness and package-description only; it introduces no new production module, no new
  named production type, and no command call site.

#### Validation

`PortabilitySpec` proves each guard is non-vacuous by naming the shape it forbids and finding none; the
package-description guard was additionally exercised against a reintroduced `if !os(linux) buildable`
stanza and reported it. The manifest is proved by the gate itself: the declared per-family size is part of
the run, so a suite that silently stopped running a group fails on the count rather than passing with a
smaller one. Closure requires these cases to exist and pass under `cabal test all` from `core/`:

- A `CoverageManifest` case "every conditional family ran the branch its row declares", sequenced after
  every declared family with tasty `after AllFinish`, which reads the recorded branch completions and
  fails when a family's refusal-branch count is not `familyRowCases` where `familyRowHolds` is `False`, or
  its row-branch count is not `familyRowCases` where it is `True`.
- `PortabilitySpec` unit cases over `hostConditionalFields` with literal package-description fragments:
  `if flag(x)` followed by `elif os(windows)` with an `other-modules:` body, `if os(windows)` with
  `Buildable: False`, `if flag(live)` with `buildable: False`, and `if arch(aarch64)` with
  `Exposed-Modules:` each report the offending field; `if !os(windows)` with only `build-depends:` reports
  nothing.
- `PortabilitySpec` unit cases over the `PATH` binding scanner with literal fragments: `setEnv "PATH" dir`,
  `[("PATH", tools)]`, `[("Path", tools)]`, and `(proc exe []){env = Just [("PATH", tools)]}` are each
  reported; `lookup "PATH" inherited` is not; and the guard case "no spec binds PATH outside the
  allow-list" passes over the tree with `RecursiveLifecycleSpec.recursiveFixtureEnvironment` as its only
  allow-list entry, failing if that entry no longer binds `PATH` (so a stale entry cannot linger).

Dated evidence: on 2026-08-17, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/` host-native at
1,950/1,950 in 235.04 seconds, plus `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231 passed. Twenty of those cases are the POSIX row's,
which this gate host previously did not compile at all. On this gate host the manifest reports the POSIX
row's 17 row-driven cases asserting its declared refusal and the Win32 row's 3 exercising the kernel; on a
POSIX gate host the same cases run with the two reports exchanged.

#### Remaining Work

- Add a harness module `test/ConditionalCase.hs` (listed in the test suite's `other-modules`, imported by
  both the specs and `CoverageManifest`, so no import cycle forms with `ProviderAliasSpec`) exporting
  `conditionalCase :: [TestName] -> Bool -> TestName -> IO () -> IO () -> TestTree` (family path, row
  holds, case name, row body, refusal body). It records into a process-global `IORef (Map [TestName]
  (Int, Int))` which branch completed without an exception. Route every row-driven case of the declared
  families through it: `WslGlobalWallHostSpec.rowCase`, `WslGlobalWallWindowsSpec`'s row cases,
  `RecursiveLifecycleSpec.withLocalGuestFrame`, the `recovery-interruption` row case,
  `OwnershipPosixSpec`/`OwnershipWindowsSpec` row cases, and `ProviderAliasSpec.kernelCase`.
- Add the sequenced manifest case named in Validation to `CoverageManifest.tests`.
- `PortabilitySpec.hostConditionalFields`: treat a line beginning `elif ` like `if `, treat `flag(` like
  `os(` and `arch(`, and lowercase the field name before comparing it with `build-depends`; add the unit
  cases named in Validation.
- `PortabilitySpec` case "no spec points the suite's own PATH at an executable it wrote": widen it from the
  `setEnv`/`unsetEnv` token pairs to every `"PATH"` or `"Path"` string token in an environment-binding
  position (a token sequence `(`, `"PATH"`, `,`, or such a tuple inside an `env = Just` list), rename it
  "no spec binds PATH outside the allow-list", and give it an explicit allow-list of exactly
  `RecursiveLifecycleSpec.recursiveFixtureEnvironment` with the § NN process-transport rationale in the
  entry; add the scanner unit cases named in Validation.

### Sprint 2.5: The fifth rule reaches conditional ownership transactions [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/ClusterBackendSpec.hs`,
`core/hostbootstrap-core/test/ProviderAliasSpec.hs`
**Substrates**: none
**Docs to update**: `documents/engineering/testing.md`

#### Objective

A family whose subject is an ownership transaction rather than a platform row is counted on every gate
host, and a family whose subject holds everywhere is counted like any other.

#### Objective boundary

Sprint 2.4 gives the harness the rule and applies it to the platform rows. The families here are
conditional on what a transaction needs rather than on a row. This sprint owns only whether their cases
exist on a host that cannot run them; the transactions belong to the phases that own them. A manifest row
is temporary by construction: a family leaves the manifest when its subject stops being host-conditional.
The [cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md) owns
the cluster transaction and the [worked-demo phase](phase-24-worked-demo.md) the guest alias transaction.

#### Deliverables

- `ProviderAliasSpec`'s family "the shipped guest alias ownership row" (5 cases) carries no case-removing
  `#ifdef`. Each case exists on every gate host and takes its expectation from `kernelCase`: the shipped
  symbolic-link transaction runs where `localGuestAliasSupported` holds, and the row's
  `ShippedRefused (OwnershipUnsupported _)` answer to the same transaction is asserted where it does not.
- The alias refusal is asked through the production route: the case drives `runShippedOwnership
  ownershipRowForHost` with the alias's own transaction, and a source case asserts the alias adapter uses
  `ShipTakeSymbolicLink` and carries no legacy guest alias driver or guest tool probe.
- `ClusterBackendSpec`'s family holds on every gate host: the cluster's transaction is the protected
  store's exclusive entry and its effects are described commands, so the family carries no manifest row
  and is counted like any other. A source case asserts the hidden backend component retains capability
  data and no injected executor.
- `CoverageManifest` declares the alias family, so the gate output names it, names its size, and says which
  branch this host took. A case that vanished is a failed count rather than a smaller total.
- The manifest's admission criterion is "a subject a gate host may not have", which covers a platform row
  and an ownership transaction alike.

#### Validation

The manifest is proved by the gate itself: the alias family's declared size is part of the run, so a suite
that stopped running one of its cases fails on the count. The refusal body is non-vacuous because it runs
the production ownership transaction and matches the exact `OwnershipUnsupported` refusal.

Dated 2026-08-20 validation evidence (x86_64-windows, GHC 9.12.4, Cabal 3.16.1.0): canonical
`cabal test all --ghc-options=-Werror` from `core/` passed 2,227/2,227 in 310.17 seconds; the
same host passed `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231. The family shape above is evidenced by a
`cabal test all` from `core/` whose `CoverageManifest` line reads "ProviderAliasSpec / the shipped guest
alias ownership row: 5 cases" and which carries no cluster row.

#### Remaining Work

None.

### Sprint 2.6: The build description carries the warnings the gate asserts [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal`, `demo/hostbootstrap-demo.cabal`, `core/hostbootstrap-core/test/PortabilitySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/cabal_layout.md`, `documents/engineering/code_check_doctrine.md`

#### Objective

The warning policy the project holds is a property of the packages that describe the build, not of a
flag each caller supplies. A plain `cabal build` refuses exactly what the gate refuses, so a warning
cannot land and sit until whoever runs the gate next happens to remember the flag — and
`-Wpartial-fields` is in the policy because a record selector on a multi-constructor type throws at the
call site rather than failing to compile.

#### Deliverables

- The `common warnings` stanza of both Cabal packages carries `-Werror`, so the build description asserts the policy every gate asserts, and every component of each package imports that stanza.
- `-Wpartial-fields` joins it, and the library, the bare executable, both suites, and the worked consumer compile clean under it.
- The gate command in every document reduces to `cabal test all` with no remembered flag, and § JJ's spelling is the one that survives.
- No module of either suite or of the library carries an `OPTIONS_GHC` (or legacy `OPTIONS`) suppression pragma, in any spelling GHC accepts.
- `PortabilitySpec` holds the policy as absence guards: the stanza's `ghc-options` carry `-Werror` and `-Wpartial-fields` as whole flags; every `library`, `executable`, and `test-suite` stanza carries `import: warnings`; no component `ghc-options` line carries `-Wwarn`, `-Wno-error`, or a `-Wno-` form of a policy flag; and no module under `src`, `app`, `internal`, `test` (excluding `test/compile-fail`), or `provider-live` opts out through a pragma.

#### Validation

The host static gate. `cabal build all` and `cabal test all` from `core/` and from `demo/` fail on a
warning without being asked to, which is the property under test. Closure requires the `PortabilitySpec`
cases "every component imports the warning stanza and none overrides it" and "no module suppresses a
warning the policy asserts" to pass over the tree under `cabal test all` from `core/`, the latter
matching the pragma through `SourceGuard.haskellTokens` (the token after `{-#` compared case-insensitively
against `OPTIONS_GHC` and `OPTIONS`) and reading the test and provider-live sources as well as production.
Dated evidence: on 2026-09-12,
x86_64 Ubuntu 24.04.4 LTS with GHC 9.12.4 and Cabal 3.16.1.0, a full reconfigure and rebuild of every
component of both packages under the package-declared policy compiled warning-clean, and
`cabal test all` from `core/` passed 2,507 tests in 162.32 seconds.

A dated `**Gate evidence**` row records the command that ran on its date and is not rewritten by this
sprint; the reduced spelling is what a document asks a reader to *run*.

#### Remaining Work

- `core/hostbootstrap-core/test/ClusterWorkloadSpec.hs`: drop `{-# OPTIONS_GHC -Wno-missing-signatures #-}`
  and give every top-level binding its signature, so the module compiles clean under the stanza's policy.
- `PortabilitySpec` pragma guard: replace the raw `"{-# OPTIONS_GHC"` substring search with a token
  search over `SourceGuard.haskellTokens` (the token following `-#` compared case-insensitively with
  `OPTIONS_GHC` and `OPTIONS`), and widen its corpus from `src`/`app`/`internal` to every Haskell source
  `SourceGuard.listHaskellSources` yields under `test` (excluding `test/compile-fail`) and `provider-live`.
- `PortabilitySpec` stanza guard: parse every component stanza of `hostbootstrap-core.cabal`, assert each
  carries `import: warnings`, assert no component `ghc-options` line carries `-Wwarn`, `-Wno-error`,
  `-Wno-partial-fields`, or `-Wno-error=`, and match the required flags as whitespace-separated tokens
  rather than with `isInfixOf`.

### Sprint 2.7: One source-introspection toolkit for the suites [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/test/SourceGuard.hs`, `core/hostbootstrap-core/test/SpecIndexSpec.hs`, `core/hostbootstrap-core/test/CordonSpec.hs`,
`core/hostbootstrap-core/test/PortabilitySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

`SourceGuard.hs` is the one toolkit a source guard reads this repository's own sources through, and it
owns both halves of that job: the lexical reader that turns a module into tokens, imports, and exports,
and the structural reader that locates the package, walks its source tree, and reads one field out of
its description. A guard is an assertion about a set of modules, so one reader is what makes two guards
over the same field enumerate the same set. Each later phase routes its own suites' walkers through this
toolkit, and the one-sided module-enumeration case in `SpecIndexSpec`, a later phase's suite, is deleted by
that suite's owner, the [recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md).

#### Deliverables

- The Cabal-stanza reader (for every component stanza, not only the main library), the `exposed-modules`/`other-modules` field reader, the source-tree walker, the package-root bracket, and the significant-line counter live once in `SourceGuard`, beside the token reader, and this phase's own suite, `PortabilitySpec`, walks a source tree, locates the package root, and reads a stanza only through it.
- One `exposed-modules` parser serves every guard, and it reads both layouts Cabal permits — a value beginning on the field's own line and a value continuing on indented lines — under any field-name case.
- `CordonSpec` reads imports and the exposure field through the shared toolkit, and keeps only its own typed refusals.
- A guard over test sources enumerates every `hs-source-dirs` of both test-suite stanzas (`test`, recursively, excluding `test/compile-fail`, and `provider-live`) through the shared walker.
- `PortabilitySpec` checks the enumeration without a frozen number and in both directions: every module a component's `exposed-modules`/`other-modules` fields name has a file under one of that component's `hs-source-dirs`, and every module file under any component's `hs-source-dirs` is named, by exact module-name equality, by a component whose `hs-source-dirs` contain it. A reader that under-reads a field reports the difference as a named set.

#### Validation

The host static gate. Every source-guard case passes unchanged under the one reader, which is the
evidence that no guard's enumerated set moved when the copies were reconciled. Dated evidence: on
2026-09-12, x86_64 Ubuntu 24.04.4 LTS with GHC 9.12.4 and Cabal 3.16.1.0, `cabal test all` from
`core/` passed 2,508 tests.

Closure requires, under `cabal test all` from `core/`: a `PortabilitySpec` case "every component declares
exactly the module files under its source directories" comparing `fieldModules` output per stanza against
the walked files by exact equality in both directions, so that deleting a module `M` from the main
library's `exposed-modules` fails it even while a module `M.Internal` remains declared, and a reader that
returns no modules fails it; and `PortabilitySpec` defining no function of its own that calls
`listDirectory`.

#### Remaining Work

- Route `PortabilitySpec`'s private walkers through `SourceGuard.listHaskellSources`/`readHaskellSources`
  and `withPackageSourceIn`, and delete them: `haskellSourcesUnder`, `productionSources`,
  `forEachTestSourceBut` (non-recursive over `test` only), `testRoot`, and `readPackageDescription`.
- Move `PortabilitySpec.commonWarningsOptions` into `SourceGuard` as a named-stanza reader, and add a
  reader that returns every component stanza with its `hs-source-dirs`.
- Make `forEachTestSourceBut` enumerate both test-suite `hs-source-dirs` recursively, excluding
  `test/compile-fail`.
- Add the two-directional enumeration case named in Validation to `PortabilitySpec`, using `fieldModules`
  over every component stanza instead of `isInfixOf` against the whole description.

### Sprint 2.8: Module contracts state what the code does [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/test/CoverageManifest.hs`,
`core/hostbootstrap-core/test/Expect.hs`, `core/hostbootstrap-core/hostbootstrap-core.cabal`
**Substrates**: none
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Every harness comment and package-description comment this phase's sprints introduced states what the
code does, and the shared test helpers carry no export nobody calls. The `HostBootstrap.Handoff.Process`
module header belongs to the module's owner, the
[recursive-lifecycle-command phase](phase-17-recursive-lifecycle-command.md).

#### Deliverables

- The `CoverageManifest` comment that justifies the alias row describes the shipped symbolic-link ownership
  transaction and the POSIX symbolic-link and no-replace hard-link primitives it needs, matching the row's
  reason string.
- The `hostbootstrap-core.cabal` comment above `library lifecycle-transaction-internal` names the
  comparison it draws: `colima-backend-internal`'s private
  `HostBootstrap.Ensure.Colima.Backend.Resolver.Testing`.
- `Expect` exports only helpers with callers and carries each Haddock once.

#### Validation

The host static gate from `core/` (`cabal build all` and `cabal test all`) passes with the edits; the
deletion of `expectLeft` is proved by the build, and a reviewer can check each rewritten comment against
the code it describes at the cited definition.

#### Remaining Work

- Rewrite the paragraph of the `manifest` Haddock in `CoverageManifest.hs` that begins "One ownership
  /driver/ is conditional", replacing the `O_NOFOLLOW` / `flock(2)`-across-`exec` description.
- Replace "the direct-provider testing seam" in the `hostbootstrap-core.cabal` comment with the module name.
- Delete `expectLeft` and its export from `core/hostbootstrap-core/test/Expect.hs`, and delete the
  duplicated "The value, or a failure naming what came back instead." comment line above `expectRight`.

## Remaining Work

- Sprint 2.3: `HandoffSpec` digests file bytes; the digest, locale, and separator guards close their gaps; `hostFixturePath` refuses drive-relative output; the driver refuses an unknown probe flag; each guard names its rationale heading.
- Sprint 2.4: the coverage manifest observes which branch each conditional case ran, the host-condition guard reads `elif`, `flag()`, and any field-name case, and the `PATH` guard covers environment-binding positions with an explicit allow-list.
- Sprint 2.6: `ClusterWorkloadSpec` drops its warning suppression; the pragma guard is token-based over test sources; every component's stanza import and overrides are checked.
- Sprint 2.7: `PortabilitySpec`'s private source-tree walkers and package-description readers move into `SourceGuard`, and `PortabilitySpec` checks the module enumeration in both directions by exact name.
- Sprint 2.8: the `CoverageManifest` and package-description comments state what the code does, and `Expect` drops its unused `expectLeft`.

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
