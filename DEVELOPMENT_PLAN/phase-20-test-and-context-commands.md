# Phase 20 — `test` and `context` command semantics

**Status**: Active
**Depends on**: Phase 19 (test harness and exclusive run ownership)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`, plus the focused `CLISpec` and `ContextSpec`
groups inside a realized linux-cpu host
**Gate kind**: deferred
**Gate evidence**: 2026-11-10 ; x86_64 Ubuntu 24.04.5 LTS under WSL2 (Linux 6.18.54.1-microsoft-standard-WSL2), GHC
9.12.4, Cabal 3.16.1.0, the package's own `-Werror` warning stanza ;
`cabal test all --test-show-details=direct --test-options=--hide-successes` from `core/` (5336 tests, 6787 seconds),
then `cabal test hostbootstrap-core:test:hostbootstrap-core-test --test-show-details=direct
--test-options="--pattern CLISpec"` (103 tests) and the same command with `--pattern ContextSpec`, both from `core/` ;
pass ;
covers d7709835dd5e73ccdde3df5309fc0db72f62bc527d72d872c9435614b8119bc5
**Evidence covers**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs` `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Schema.hs` `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Context.hs` `core/hostbootstrap-core/test/CLISpec.hs` `core/hostbootstrap-core/test/ContextSpec.hs`

> **Purpose**: Fix the exact grammar and side-effect boundary of `test init`, `test run <case-id>|all`,
> `context`, and `check-code`.

## Phase Objective

The engine exists; this phase is the surface an operator actually types. Two properties matter: each verb's
grammar names what it operates on in the project's own typed vocabulary, and each verb's side effects are
exactly what its name implies — `context` reads and never writes, `test init` writes only the test config, and
`test run` is the only verb that mutates infrastructure.

## Sprints

### Sprint 20.1: `test init` and its overwrite policy [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Write the test config, and be explicit about replacing one.

#### Deliverables

- `test init` writes `<project>.test.dhall` from the project's own typed test-config vocabulary.
- The writer request is opaque: a caller supplies the project's typed values, not a rendered file, so core cannot
  be asked to write arbitrary bytes.
- The request's destination is bound to the installed identity: `testConfigWriteFor` takes the
  `InstalledProjectIdentity projectId` that `testCommand` already holds, never a `Text` name, and resolves
  `siblingTestConfigPath (installedProjectName project)`. A name carrying a separator, `..`, or an absolute or
  drive-qualified form never reaches the path join, because `withInstalledProjectKernel` admits only
  alphanumerics, `-`, and `_`.
- `installTestConfig` forces the rendered bytes into a temporary file in the sibling directory before the
  destination is touched, then publishes in one kernel operation: `RefuseExistingTestConfig` publishes through
  `linkNoReplace`, so a name taken at any moment (a file created after the existence check, or a dangling
  symlink) yields `TestConfigExists` and the existing entry is left as it was; `ReplaceExistingTestConfig`
  renames the temporary over the target. A failed or interrupted write leaves the prior test config
  byte-identical and no temporary file behind.
- The overwrite policy is stated rather than implied: an existing config is refused unless replacement is
  requested explicitly, and the refusal names the file
  (`test init: <path> already exists; pass --replace to overwrite it`).
- `test init` writes only `<project>.test.dhall`; it neither reads nor creates the sibling `<project>.dhall`.
- On a host with no build directory, `test run` refuses by naming the missing test config
  (``test run: missing <path>; run `<progName> test init` first``) before any sweep, lease, or variant, which
  is the documented sequence rather than a defect.

#### Validation

`CLISpec` covers the grammar, the typed request, and both overwrite branches: a first `test init` writes, a
second refuses and leaves an operator's edit byte-identical, and `--replace` is the only route that
overwrites. `cabal test all --ghc-options=-Werror` from `core/` passed 998/998 on 2026-08-05 (aarch64-osx,
GHC 9.12.4), and the demo suite passed 112/112.

The sprint closes when these `CLISpec` cases exist and pass under `cabal test all` from `core/` and from
`demo/`:

- "test init refuses an existing test config unless replacement is requested" asserts, for each refused
  `init`, that the subprocess exit is `ExitFailure 1` and its stderr contains
  `<testPath> already exists; pass --replace to overwrite it`.
- "test init writes a test config without a pre-existing project config" asserts the sibling
  `<project>.dhall` is absent before the call and still absent after it, and that the test config exists.
- "test run fails fast without a test.dhall" runs with no sibling `<project>.dhall` and no test config,
  asserts the subprocess exit is `ExitFailure 1`, its stderr contains
  ``test run: missing <testPath>; run `<progName> test init` first``, and the protected store under the
  working directory is unchanged.
- "test config writer resolves only the installed project's sibling" asserts that a request built under
  `withInstalledProjectIdentity projectName` has `Schema.testConfigWritePath` equal to
  `Schema.siblingTestConfigPath projectName`, whose directory is the test executable's directory, and that
  `withInstalledProjectIdentity "../escape"` returns `Left (AuthorityInvalidIdentity _)`.
- "test config replace leaves the prior file intact when rendering fails" asserts that
  `installTestConfig ReplaceExistingTestConfig` with a value whose rendering throws rethrows, leaves the existing
  test config byte-identical, and leaves no `.hostbootstrap-config.tmp`-prefixed file in its directory.
- "test config refuse creates nothing when rendering fails" asserts that `installTestConfig
  RefuseExistingTestConfig` with the same throwing value and no existing test config rethrows, leaves the
  destination absent, and leaves no temporary file in its directory.

Closing evidence, 2026-11-10, native Windows 11 Pro 10.0.26300 (GHC 9.12.4, Cabal 3.16.1.0):
`Schema.testConfigWriteFor` takes the `InstalledProjectIdentity` that `testCommand` holds and resolves
`siblingTestConfigPath (installedProjectName project)`, and `runTestInit` passes `project`.
`Schema.installTestConfig` forces `renderProjectConfigBytes` into a same-directory `.hostbootstrap-config.tmp` file,
flushes and closes it before touching the destination, publishes `RefuseExistingTestConfig` through `linkNoReplace`
(a taken name or dangling symlink yields `TestConfigExists`) and `ReplaceExistingTestConfig` through `renameFile`, and
removes the temporary on every exit path. `CLISpec` asserts the exact `<testPath> already exists; pass --replace to
overwrite it` refusal for each refused `init`, that `test init` leaves the sibling `<project>.dhall` absent before and
after, that `test run` without a test config and without a sibling config exits `ExitFailure 1` naming
`test run: missing <testPath>` and ``test init` first`` with the protected-store tree unchanged, that the writer
resolves only the installed project's sibling and `withInstalledProjectIdentity "../escape"` returns
`Left (AuthorityInvalidIdentity _)`, and that a failing render leaves the prior file byte-identical under replace and
creates nothing under refuse, with no temporary behind. The cases run in-process with captured stderr rather than
through the plan's `cliFixtureResult` subprocess runner. The warning-clean `cabal test all` from `core/` and from
`demo/` passed (5336 tests, and the demo suite's 169).

#### Remaining Work

None.

### Sprint 20.2: `test run <case-id>|all` [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Select compiled cases by their typed identity.

#### Deliverables

- The selector takes a validated `CaseId` or `all`; an unknown case is refused before any variant runs, by
  naming the compiled set (`unknown test case "<id>"; available: <ids>, all`) rather than running nothing and
  reporting success or widening to the whole matrix.
- Help text and metavariables name a case, not a suite, so the surface matches the typed vocabulary.
- `test run` is the only verb in this phase with infrastructure side effects, and it enters through the harness
  ownership bracket. At the command surface, an operator's existing sibling `<project>.dhall` refuses the run
  (`a production config already exists at <path>; refusing to overwrite it`) and survives it byte-identical.
- `check-code` is the project's canonical quality gate verb and is supplied by construction.

#### Validation

`CLISpec` covers selection and the rendered help: the metavariable is `CASE-ID` and no surface text says
"suite", asserted against the real `--help` output of a subprocess running the actual parser.

The sprint closes when these `CLISpec` cases exist and pass under `cabal test all` from `core/` and from
`demo/`:

- "test run refuses an unknown case by naming the compiled set" observes `ExitFailure 1`, stderr containing
  `unknown test case "no-such-case"; available: ok, all`, and no assertion environment opened.
- "test run names a compiled case, not a suite, in its surface text" asserts the help contains the exact
  phrases ``or `all` for every compiled case`` and ``or `all` for the whole matrix``.
- "test run refuses to overwrite an existing sibling project config" runs a spec whose Harness run would
  otherwise succeed, observes `ExitFailure 1` and the production-config refusal text naming the path, the
  config's bytes unchanged, and no assertion environment opened.
- "test init then test run exits non-zero when a case fails (config is generated then removed)" observes the
  generated config present while the case asserts, the failing case's assertion invoked, and the config absent
  afterwards.

Closing evidence, 2026-11-09, native Windows 11 Pro 10.0.26300 (GHC 9.12.4, Cabal 3.16.1.0): the four `CLISpec` cases
run in-process with captured output rather than through subprocess fixtures. "test run refuses an unknown case by
naming the compiled set" asserts `ExitFailure 1`, the exact `unknown test case "no-such-case"; available: ok, all`
line, and that the assertion environment never opened. "test run names a compiled case, not a suite, in its surface
text" pins the exact ``or `all` for every compiled case`` and ``or `all` for the whole matrix`` phrases. "test run
refuses to overwrite an existing sibling project config" runs a spec whose run would otherwise succeed and asserts
`ExitFailure 1`, the production-config refusal naming the path (captured from stdout and stderr by the new
`captureCLIExitOutput`), the config bytes unchanged, and no assertion environment opened. "test init then test run
exits non-zero when a case fails (config is generated then removed)" observes the generated config present each time
an assertion environment opens, the failing assertion invoked, and the config absent afterwards; the fixture plans
two variants (default and alternate), so the observations are `[True, True]` and two invocations, not the single
observation the plan text assumed. The warning-clean `cabal test all` from `core/` and from `demo/` passed.

#### Remaining Work

None.

### Sprint 20.3: Read-only `context` introspection [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/handoff-implementation/HostBootstrap/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/ContextSpec.hs`, `core/hostbootstrap-core/test/CLISpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

Show the composition without touching anything.

#### Deliverables

- `context inspect` (the sibling `<project>.dhall`) and `context show FILE` decode the config and print
  `Context.renderComposition` of its explicit binary context: the `topologyFrames` chain, one line per frame
  with frame id, provider, kind, and parent, and the `currentFrame` marked. Every `<project>.dhall` renders
  uniformly, whatever roles it declares, without special-casing a frame.
- What `context` prints is the config's declared composition; it constructs no `ProjectPlan`, so it does not
  render the plan's step frames.
- A missing or undecodable config is a one-line refusal (`context: no config at <path>`, or
  `context: failed to decode <path>` and the decoder error's first line, whose exact form Sprint 20.8 sets),
  not a backtrace.
- It performs no write of any kind — no config, no state, no identity install, no provider call.

#### Validation

`ContextSpec` "renderComposition renders the lift chain with the current frame highlighted" pins the
rendering with the current frame at the project-container frame.

The sprint closes when these cases exist and pass under `cabal test all` from `core/` and from `demo/`:

- `ContextSpec`: `renderComposition` with the current frame at `host-orchestrator-0` and at
  `vm-orchestrator-1` of the same three-frame `sampleContext` marks exactly that line with `  -> ` and every
  other line with `   . `.
- `CLISpec` "context inspect and context show render the sibling composition and write nothing": both verbs
  exit 0, print `Context.renderComposition` of the written config's context, and leave the executable's
  sibling directory and the working directory's `.hostbootstrap` tree byte-identical.
- `CLISpec` "context inspect refuses a missing sibling config and writes nothing": `ExitFailure 1`, stderr
  containing `context: no config at <cfgPath>`, and both trees byte-identical.

Closing evidence, 2026-11-10, native Windows 11 Pro 10.0.26300 (GHC 9.12.4, Cabal 3.16.1.0): `ContextSpec`
"renderComposition marks only the host frame when it is current" and "... only the VM frame when it is current" build
`sampleContext { currentFrame = ... }` and assert the full rendered string, marking exactly one line with `  -> ` and
every other with `   . `. `CLISpec` "context inspect and context show render the sibling composition and write
nothing" writes the sibling config, runs both verbs through the real parser, and asserts `Right ()`, the exact
`Context.renderComposition` of the config's context ending the captured stdout and printed once (in-process stdout also
carries the test runner's progress line, so this replaces the plan's exact-equality subprocess check), the executable's
sibling directory unchanged by file size (it holds the test binary), and the `.hostbootstrap` tree byte-identical.
"context inspect refuses a missing sibling config and writes nothing" asserts `ExitFailure 1`, stderr containing
`context: no config at <cfgPath>`, and the `.hostbootstrap` tree byte-identical. The warning-clean `cabal test all` from
`core/` and from `demo/` passed.

#### Remaining Work

None.

### Sprint 20.4: Realized-Linux verb-sequence acceptance [Done]

**Status**: Done
**Implementation**: none — this sprint changes no source
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the live sequence this phase's grammar owes, as a sprint rather than as a preamble nothing counts.

#### Deliverables

- Zero production lines. Sprints 20.1 through 20.3 close on the host static gate; what is left is running
  the verbs where their side effects are real.
- The phase-owned concrete command fixture invokes the real parser for `test init`, `test run`, and `context`
  inside a realized Linux substrate. Its focused `CLISpec` and `ContextSpec` groups carry the side-effect
  boundary cases Sprints 20.1 through 20.3 name — `context` reads and never writes, `test init` writes only
  the test config, and `test run` is the only verb that enters Harness mutation — so running them there
  observes each boundary on linux-cpu.
- The overwrite policy and the case-selector surface are exercised against their exact current shape,
  because a sequence run against an older grammar is evidence about that grammar.
- Dated evidence names the substrate realization and the outer host.

#### Validation

The focused real-parser groups. They assert nothing beyond this phase's static contract; running them inside
the realized substrate confirms that the exact current parser, typed fixture, filesystem effects, and process
exit behavior hold on linux-cpu without importing the worked demo's later provider and workload lifecycle.

Dated realized-host evidence: on 2026-08-22, inside a disposable Ubuntu 24.04 amd64 Incus VM on a Linux
outer host, `CLISpec` passed 57/57 with `--ghc-options=-Werror`, including the actual `test init` → exact
Harness `test run` paths, overwrite/refusal cases, selector/help grammar, and cleanup. `ContextSpec` plus the
matching `LiftContextSpec` selection passed 84/84 with `--ghc-options=-Werror`, including composition rendering,
missing/decode refusals, topology/current-frame validation, and the pure lift composition.

#### Remaining Work

None.

### Sprint 20.5: The realized-host CLI and context run [Done]

**Status**: Done
**Implementation**: none — this sprint records a run
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/testing.md`

#### Objective

Record the dated focused `CLISpec` and `ContextSpec` selection inside a realized linux-cpu host.

#### Deliverables

- one dated run of both groups with `--ghc-options=-Werror` inside a realized linux-cpu host.

#### Validation

On 2026-09-06, both focused groups passed inside a realized `linux-cpu` host — the published
`basecontainer-cpu-arm64` base at digest
`sha256:3634916e85b1fda411ae671a4bca2f72745e0bd106e2e9efebccc25415e0bc49`, reporting `Linux aarch64`
with the pinned GHC 9.12.4 and Cabal 3.16.1.0. `CLISpec` passed `58/58` and `ContextSpec` passed
`85/85`, both under `-Werror`.

The run is recorded against a writable copy of the working tree inside the realization. A first attempt
mounted the tree read-only and four `CLISpec` cases refused with
`could not take the run liveness lock: … Read-only file system`. That is the harness being observed
correctly rather than a defect: those cases take the protected store's run-liveness lock under the
project root, so a root that cannot be written is a refusal the ownership seam is supposed to produce.
It is recorded because it is the difference between this gate having run and having appeared to.

On 2026-09-09, the focused `CLISpec` group passes 64/64 in 2.12 seconds and the `ContextSpec`
selection passes 85/85 in 0.23 seconds on Ubuntu 24.04.4 LTS through WSL2, using GHC 9.12.4
and Cabal 3.16.1.0. The complete core gate passes 2,504/2,504 in 190.86 seconds on that realization
and 2,499/2,499 in 499.45 seconds on the Windows outer host. All 971 tracked working-tree files
match the validated Linux copy byte for byte. The focused command selection retains the exact Harness
mutation boundary cases; its covered digest matches the header evidence.

#### Remaining Work

None.

### Sprint 20.6: The initializer carries the role it parsed [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

§ Z fixes this surface's grammar and its side-effect boundary. The initializer takes its default role
as rendered text and hands that text to a decision about installed identity, so the surface is where a
parsed value is turned back into a string and compared. This sprint is the command-surface half of that
change: the parser's default and help text are rendered from the role value rather than carrying a
second literal spelling of it.

#### Deliverables

- The initializer's role parameter is the parsed role kind.
- The parser default and its help text render that value.
- No literal role spelling remains at this surface.
- The command suite covers an aliased and a normalised spelling reaching the same parsed value.

#### Validation

The host static gate, plus this phase's focused command and context suites. The gate-evidence row
records both the full suite and the focused legs its gate names.

`initParserInfo` takes `Context.ContextKind`, the `--role` default and its shown value are rendered from
that parsed role, the help text lists `configRoleNames`, and the identity decision compares
`roleKind == defaultRole`; no role spelling remains in the module outside prose. `ContextSpec` covers the
canonical, aliased, and case/separator-normalised spellings of the default role reaching one provisioning
decision, and refuses provisioning for another role at the same path. On 2026-09-13 the complete
2,536/2,536 `cabal test all` ran on the x86_64 Linux gate host, and the focused 64/64 `CLISpec` and
88/88 `ContextSpec` legs were built and run inside a realized `linux-cpu` container. One gate-evidence
row records both legs and the re-measured covers digest.

#### Remaining Work

None.

### Sprint 20.7: The `test` surface refuses an off-root invocation [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/harness_workflow.md`, `documents/engineering/testing.md`

#### Objective

§ Z makes the `test` surface root-only: an invocation from a non-root frame is refused before any lifecycle
read or mutation. `testCommand` states "root-only" in its `progDesc` and applies no binary-context root gate
to `test init` or `test run`; `test run`'s only refusal of a child frame is the harness's existing-config
precondition, which runs inside the protected transaction after the abandoned-run sweep, and `test init`
has no refusal at all. This sprint builds the one root gate both subcommands pass first.

#### Deliverables

- One root gate, evaluated by `test init` before it builds the test-config request and by `test run`
  before it reads `<project>.test.dhall` or enters `withCanonicalProjectRoot`.
- When the executable's sibling `<project>.dhall` exists, the gate decodes it and validates its topology,
  and refuses unless `Context.isRootFrame` holds for its context; the refusal names the current frame.
- A sibling config that is present but undecodable is refused by the gate with a one-line diagnostic, never
  treated as root.
- With no sibling config, the gate admits the invocation, so `test init` stays a bootstrap entrypoint and
  `test run` keeps its existing-config precondition inside the protected transaction.
- A refused invocation writes no test config, reads no test config, and creates no protected-store entry.

#### Validation

The sprint closes when these `CLISpec` cases exist and pass under `cabal test all` from `core/` and from
`demo/`:

- "test init refuses an off-root invocation and writes nothing": with a sibling config whose current frame
  is non-root, `test init` exits `ExitFailure 1`, stderr names the current frame, and the test config is
  absent afterwards.
- "test run refuses an off-root invocation before any lifecycle read": with the same sibling config and a
  test config present, `test run all` exits `ExitFailure 1`, stderr names the current frame, the protected
  store listing under the working directory is unchanged, and the suite's assertion opener is never called.
- "test init admits the root frame and the absent config": `test init` succeeds with no sibling config and
  with a sibling config whose current frame is the root frame.

Closing evidence, 2026-11-10, native Windows 11 Pro 10.0.26300 (GHC 9.12.4, Cabal 3.16.1.0): `Command.hs` carries one
`rootGate`, the first action of both `runTestInit` and `runTestRun`. With a sibling `<project>.dhall` present it decodes
the file with the binary's Production `ProjectCodec`, runs `Context.validateTopology`, and dies with
`test: refusing a non-root invocation: current frame <frame> is not the root frame` unless `Context.isRootFrame` holds;
an undecodable file dies with `test: failed to decode <path>: ...`; with no sibling config it admits the invocation.
The `test` command's help no longer claims "(root-only)". `CLISpec` pins "test init refuses an off-root invocation and
writes nothing" (a sibling config built with `Context.deriveVMContext`, so its current frame has a parent),
"test run refuses an off-root invocation before any lifecycle read" (the `.hostbootstrap` tree unchanged and the
assertion opener never called), "test init refuses an undecodable sibling config instead of treating it as root", and
"test init admits the root frame and the absent config". The cases run in-process with captured stderr rather than
through the plan's subprocess runner. The warning-clean `cabal test all` from `core/` and from `demo/` passed.

#### Remaining Work

None.

### Sprint 20.8: `context` refuses a role wire and names the codec it decodes with [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/binary_context_config.md`

#### Objective

The config-free `context inspect`/`context show` decode with what a command that holds no authority can
obtain. `coreCommands` hands `contextCommand` the binary's one Production `ProjectCodec`; a Harness
`ProjectCodec` exists only inside `withHarnessProjectCodec`, which takes a run's `HarnessConfigAuthority`, and
`context` holds no run. The full project wire carries no scope field and `BinaryContext` carries no scope, so
the rendered composition asserts no scope: a Harness-scoped config whose wire is also a valid Production wire
renders, and one that carries a Harness-only value (a `TestPlaintext` secret) fails the Production decode.
The decoded config reaches only `Context.renderComposition`; no lifecycle, handoff, or authority-bearing
surface receives it. This sprint makes the two refusals say what they are: a role wire is refused by the
first-stage envelope check the
[Dhall-configuration-and-generic-project-model phase](phase-7-dhall-configuration-and-project-model.md)
adds for project lifecycle and `check-code` (Sprint 7.15) before any second-stage decode, and a full-wire
decode failure names the Production codec it ran.

#### Deliverables

- `readContextConfig`, which `context inspect` and `context show FILE` both call, reads the file's text and
  runs Sprint 7.15's first-stage envelope check before `decodeProjectCodecWithSettings`; a `ServiceRoleWire`
  exits 1 with the one line `context: <path> holds a service role wire; context renders a full project
  config`, and no decoder runs.
- A full wire that the Production `ProjectCodec` cannot decode exits 1 with the one line
  `context: failed to decode <path> with the Production project codec: <first line of the decoder error>`.
- A file the Production codec decodes renders `Context.renderComposition` of its context and nothing else,
  whichever scope's codec wrote it; `context: no config at <path>` is unchanged.
- Every refusal and every rendering writes nothing.

#### Validation

The sprint closes when these cases exist and pass under `cabal test all` from `core/` and from `demo/`:

- `CLISpec` "context refuses a service role wire before decoding it": the role wire built the way
  `withVerifiedServiceRuntime` builds its `roleWire` (`withProductionProjectCodec @Fixture.ProjectConfig
  @Fixture.FixtureProject`, `withFinalizedServiceRegistry ProductionScope`, `withSelectedServiceProgram`,
  `renderValidatedServiceRequest`), written once to a temporary file under `context-show-file` and once to
  the sibling `cfgPath` under `context-inspect`; each run is `ExitFailure 1`, stderr contains
  `holds a service role wire; context renders a full project config` and not `failed to decode`, and both
  snapshotted trees are byte-identical.
- `CLISpec` "context show renders a Harness-written fixture config and asserts no scope": a
  `Fixture.defaultProjectConfig projectName "." HostOrchestrator` written with
  `Schema.publishScopedProjectConfigFile OverwriteExistingOutput` through `withHarnessProjectCodec @Fixture.ProjectConfig
  (V.harnessConfigAuthority authority)` inside `withFixtureHarnessAuthority`; `context-show-file` is
  `ExitSuccess` with stdout exactly `Context.renderComposition (cfgContext cfg)`, and the trees are
  byte-identical.
- `CLISpec` "context show names the Production codec when a file does not decode": a `SecretProjectConfig`
  Harness wire carrying `V.testPlaintextSecret (V.harnessConfigAuthority authority) (V.TestSecret
  "fixture")`, rendered as `SchemaSpec` renders its injected Harness config; `context-show-file` is
  `ExitFailure 1`, stderr contains `context: failed to decode <file> with the Production project codec: `,
  and the trees are byte-identical.
- The cases of Sprint 20.3 pass unchanged.

Closing evidence, 2026-11-10, native Windows 11 Pro 10.0.26300 (GHC 9.12.4, Cabal 3.16.1.0): `readContextConfig`
(`Command.hs`) reads the file's bytes (a non-UTF-8 file is refused with the Production-codec line), runs the first-stage
`inspectConfigWireKind` with settings rooted at the file's own directory, refuses a `ServiceRoleWire` with
`context: <path> holds a service role wire; context renders a full project config` before any decoder runs, and
otherwise decodes through `decodeProjectCodecWithSettings` with the same file-rooted settings, mapping a failure to
`context: failed to decode <path> with the Production project codec: <first line>`. `CLISpec` pins "context refuses a
service role wire before decoding it" (both verbs, no "failed to decode", the `.hostbootstrap` tree unchanged),
"context show renders a Harness-written fixture config and asserts no scope" (a config written through
`withHarnessProjectCodec` renders its composition with the tree unchanged), and "context show names the Production
codec when a file does not decode". The cases run in-process with captured output rather than through the plan's
subprocess runner. The warning-clean `cabal test all` from `core/` and from `demo/` passed.

#### Remaining Work

None.


### Sprint 20.9: Re-run the phase gate on a realized linux-cpu host [Done]

**Status**: Done
**Implementation**: none; this sprint reruns the phase's declared gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Restore the completion evidence that Sprints 20.1, 20.7, and 20.8 expired by editing `Command.hs`, `Config/Schema.hs`,
`CLISpec.hs`, and `ContextSpec.hs`, paths in this phase's `**Evidence covers**` set. This is evidence expiry under
§ C, not a design-error reopening.

#### Deliverables

- Run the declared gate: `cabal test all` from `core/`, then the focused `CLISpec` and `ContextSpec` groups, on a
  realized linux-cpu host.
- Re-record `**Gate evidence**` with the new `**Evidence covers**` digest and set the phase `Done`.

#### Validation

2026-11-10, x86_64 Ubuntu 24.04.5 LTS under WSL2 (the `hostbootstrap-linux-d` distribution; Linux
6.18.54.1-microsoft-standard-WSL2, GHC 9.12.4, Cabal 3.16.1.0). The first full run passed 5334 of 5336: the
`RecoveryInterruptionSpec` case "destroy-settled survives a real process death with terminal lease and mode" timed out
at its fixed five-second subprocess-sentinel wait, and `CoverageManifest` failed on that row's missing completion. With
the wait widened the case passes alone in 44.9 seconds, so the failure was the test's timing bound on a slow
virtualized host, not a regression; `awaitFile` now waits up to a minute. The rerun of `cabal test all` from `core/`
passed 5336 of 5336 in 6787 seconds with the `recovery-interruption` row completing (1,0), the focused `CLISpec` group
passed 103 of 103, and the focused `ContextSpec` group passed. The provider-live component reported its declared
no-request Unsupported outcome and exited successfully.

#### Remaining Work

None.

### Sprint 20.10: Re-run the phase gate after the contended-liveness case [Active]

**Status**: Active
**Implementation**: none; this sprint reruns the phase's declared gate
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/README.md`

#### Objective

Restore the completion evidence that the contended-liveness case added to `CLISpec.hs` expired, a path in this
phase's `**Evidence covers**` set. This is evidence expiry under § C, not a design-error reopening.

#### Deliverables

- Run the declared gate: `cabal test all` from `core/`, then the focused `CLISpec` and `ContextSpec` groups, on a
  realized linux-cpu host.
- Re-record `**Gate evidence**` with the new `**Evidence covers**` digest and set the phase `Done`.

#### Validation

Not yet run.

#### Remaining Work

- Run the declared gate on the Linux gate host and record the `**Gate evidence**` row.

## Remaining Work

Evidence expiry, not a design-error reopening (§ C): the contended-liveness case added to `CLISpec.hs` changed this
phase's `**Evidence covers**` digest. Sprint 20.10 owes the re-run of the declared gate.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/hostbootstrap_core_library.md` — the surfaced `test` and `context` grammar.
- `documents/architecture/binary_context_config.md` — read-only introspection, the Production codec it
  decodes with, and its role-wire refusal.
- `documents/architecture/harness_workflow.md` — the `test` surface's root gate.

**Engineering docs to create/update:**
- `documents/engineering/testing.md` — the operator-facing test surface.

**Cross-references to add:**
- `development_plan_standards.md` § Z names this phase as the owner of the test/context grammar.
