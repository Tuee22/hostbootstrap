# Phase 20 — `test` and `context` command semantics

**Status**: Active
**Depends on**: Phase 19 (test harness and exclusive run ownership)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`, plus the focused `CLISpec` and `ContextSpec`
groups inside a realized linux-cpu host
**Gate kind**: deferred
**Gate evidence**: 2026-09-13 ; full suite on x86_64 Ubuntu 24.04.4 LTS (Linux 7.0.0-28-generic, GHC
9.12.4, Cabal 3.16.1.0), focused legs in an x86_64 Linux container from the published
`basecontainer-cpu-amd64` base with no accelerator device visible, built and run there with that same
pinned toolchain mounted in ;
`cabal test all --ghc-options=-Werror --test-show-details=direct --test-options=--hide-successes` from
`core/`, then `cabal test hostbootstrap-core:test:hostbootstrap-core-test --ghc-options=-Werror
--test-show-details=direct --test-options="--pattern CLISpec"` and the same command with
`--pattern ContextSpec`, both from `core/` in that container ; pass ;
covers 893814d13438030a1b058ab5fcefb836048ee69887611031a5d4d24d79d1c175
**Evidence covers**: `core/hostbootstrap-core/src/HostBootstrap/Command.hs` `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs` `core/hostbootstrap-core/src/HostBootstrap/Context.hs` `core/hostbootstrap-core/test/CLISpec.hs` `core/hostbootstrap-core/test/ContextSpec.hs`

> **Purpose**: Fix the exact grammar and side-effect boundary of `test init`, `test run <case-id>|all`,
> `context`, and `check-code`.

## Phase Objective

The engine exists; this phase is the surface an operator actually types. Two properties matter: each verb's
grammar names what it operates on in the project's own typed vocabulary, and each verb's side effects are
exactly what its name implies — `context` reads and never writes, `test init` writes only the test config, and
`test run` is the only verb that mutates infrastructure.

## Sprints

### Sprint 20.1: `test init` and its overwrite policy [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
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

#### Remaining Work

- Add a subprocess runner `cliFixtureResult :: String -> IO (ExitCode, T.Text, T.Text)` in `CLISpec.hs`
  beside `schemaFixtureOutput`. It invokes the test executable with
  `--hostbootstrap-schema-fixture <name>` and returns the exit code, stdout, and stderr without failing on a
  non-zero exit. Sprints 20.2 and 20.3 reuse it.
- Overwrite refusal message: add a `runSchemaFixture` entry `"test-init"` that runs `withArgs ["test", "init"]`
  under `specWith passingSuite (pure ()) []`. In "test init refuses an existing test config unless replacement is
  requested", run each of the two refused `init` calls through `cliFixtureResult "test-init"` and assert
  `ExitFailure 1` plus stderr containing `testPath ++ " already exists; pass --replace to overwrite it"`.
  Keep the existing byte-identity and `--replace` assertions.
- Test-init side-effect boundary: in "test init writes a test config without a pre-existing project config",
  remove any stale `cfgPath` (`Schema.siblingProjectConfigPath projectName`) first, then assert
  `doesFileExist cfgPath == False` before the call, `doesFileExist testPath == True` after it, and
  `doesFileExist cfgPath == False` after it.
- Missing-test-config refusal: rewrite "test run fails fast without a test.dhall" so it no longer wraps the
  run in `withProjectConfig`. Add a `runSchemaFixture` entry `"test-run-all"` that runs
  `withArgs ["test", "run", "all"]` under `specWithHarnessContext stateRoot projectName passingSuite (pure ()) []`,
  with `stateRoot` taken from `getCurrentDirectory`. In the case, remove any stale test config and sibling
  config first, record the sorted recursive listing of the store root
  `stateRoot </> ".hostbootstrap" </> "authority" </> T.unpack projectName` (absent counts as empty), run
  `cliFixtureResult "test-run-all"`, and assert `ExitFailure 1`, stderr containing
  `"test run: missing " ++ testPath` and ``test init` first``, and an identical store listing afterwards.
- Identity-bound destination: in `Config/Schema.hs`, change `testConfigWriteFor` to
  `InstalledProjectIdentity projectId -> CodecWitness tcfg -> tcfg -> IO (TestConfigWrite tcfg)`, resolving the
  path with `siblingTestConfigPath (installedProjectName project)`; in `Command.hs`, `runTestInit` passes
  `testCommand`'s `project` in place of `T.pack progName`. In `CLISpec.hs`, add "test config writer resolves
  only the installed project's sibling": under `withInstalledProjectIdentity projectName` (with `projectName`
  from `executableProjectName`), build the request with `Fixture.testConfigCodec` and
  `Fixture.defaultTestConfig (Fixture.Resources 4 "8GiB" "20GiB")`, and assert its `Schema.testConfigWritePath` equals
  `Schema.siblingTestConfigPath projectName` and its `takeDirectory` equals `takeDirectory` of
  `getExecutablePath`; then assert `withInstalledProjectIdentity "../escape" (\_ -> pure ())` returns
  `Left (AuthorityInvalidIdentity _)`.
- Atomic test-config publication: rewrite `installTestConfig` in `Config/Schema.hs` so it forces
  `renderProjectConfigBytes codec value`, writes it with `openBinaryTempFile (takeDirectory path)
  ".hostbootstrap-config.tmp"` plus `hPut` and `hFlush`, and closes the handle before touching the destination,
  removing the temporary on every exit path as `createSiblingConfig` does. `RefuseExistingTestConfig` publishes
  with `linkNoReplace temporary path` and maps a link failure on a taken name to `TestConfigExists path`;
  `ReplaceExistingTestConfig` publishes with `renameFile temporary path`. In `CLISpec.hs`, add "test config
  replace leaves the prior file intact when rendering fails": run `test init`, read the test config's bytes, call
  `Schema.installTestConfig Schema.ReplaceExistingTestConfig` on a request whose value is
  `Fixture.TestConfig{testResources = error "render aborted"}`, assert it throws `ErrorCall`, the bytes are
  unchanged, and the directory listing has no `.hostbootstrap-config.tmp`-prefixed entry. Add "test config
  refuse creates nothing when rendering fails": with no test config present, the same call under
  `RefuseExistingTestConfig` throws, `doesPathExist testPath` is `False`, and no temporary remains.

### Sprint 20.2: `test run <case-id>|all` [Active]

**Status**: Active
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

#### Remaining Work

- Unknown-case refusal: add a `runSchemaFixture` entry `"test-run-unknown-case"` that runs
  `withArgs ["test", "run", "no-such-case"]` under `specWithHarnessContext stateRoot projectName suite (pure ()) []`,
  where `suite` is `passingSuite` with its assertion opener writing the file named by a
  `HOSTBOOTSTRAP_CLI_CASE_MARKER` environment variable (the `"project-dry-run"` fixture's marker pattern). In
  the case, run `test init` first and assert its result is `Right ()`, then run
  `cliFixtureResult "test-run-unknown-case"` (Sprint 20.1) with the marker variable set to a fresh temporary
  path, and assert `ExitFailure 1`, stderr containing `unknown test case "no-such-case"; available: ok, all`,
  and the marker file absent.
- Whole-matrix selector in help: in "test run names a compiled case, not a suite, in its surface text",
  replace the `allCasesSelector` infix check with two checks for
  ``"or `" ++ allCasesSelector ++ "` for every compiled case"`` and
  ``"or `" ++ allCasesSelector ++ "` for the whole matrix"``; the bare token `all` is a substring of `.dhall`.
- Existing-config refusal: rewrite "test run refuses to overwrite an existing sibling project config" on
  `specWithHarnessContext stateRoot projectName` with the marker-writing suite above, through a fixture entry
  `"test-run-all-marked"`. Assert `test init` returns `Right ()`, write the sibling config with
  `Schema.writeProjectConfigFile`, read its bytes, run `cliFixtureResult "test-run-all-marked"`, and assert
  `ExitFailure 1`, stdout or stderr containing
  `"a production config already exists at " ++ cfgPath ++ "; refusing to overwrite it"`, the config bytes
  unchanged, and the marker file absent.
- Generated-config observation: in "test init then test run exits non-zero when a case fails (config is generated
  then removed)", assert `test init` returns `Right ()`; give `failingSuite`'s assertion opener a
  `doesFileExist cfgPath` probe recorded in an `IORef` and its case assertion a call counter, as "test run
  interprets one exact Harness plan through forward and reverse" does; assert the recorded presence is `[True]`
  and the counter is 1, beside the existing exit and absence assertions.

### Sprint 20.3: Read-only `context` introspection [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
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

#### Remaining Work

- Add the two `renderComposition` cases to `ContextSpec.hs`, built as `sampleContext { currentFrame = ... }`,
  each asserting the full rendered string.
- Add `runSchemaFixture` entries `"context-inspect"` (`withArgs ["context", "inspect"]`) and `"context-show"`
  (`withArgs ["context", "show", cfgPath]`) under `specWith passingSuite (pure ()) []`. Add a `CLISpec` helper
  that snapshots a directory tree as a sorted list of (relative path, file bytes).
- Add "context inspect and context show render the sibling composition and write nothing": write the sibling
  config with `Schema.writeProjectConfigFile Fixture.projectConfigCodec cfgPath
  (Fixture.defaultProjectConfig projectName "." HostOrchestrator)`, snapshot `takeDirectory cfgPath` and
  `stateRoot </> ".hostbootstrap"`, run `cliFixtureResult "context-inspect"` and
  `cliFixtureResult "context-show"` (Sprint 20.1), and assert `ExitSuccess` with stdout equal to
  `Context.renderComposition (cfgContext cfg)` for each, then equal snapshots; remove the config in `finally`.
- Add "context inspect refuses a missing sibling config and writes nothing": remove any stale sibling config
  first, snapshot both trees, run `cliFixtureResult "context-inspect"`, and assert `ExitFailure 1`, stderr
  containing `"context: no config at " ++ cfgPath`, and equal snapshots.

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

### Sprint 20.7: The `test` surface refuses an off-root invocation [Active]

**Status**: Active
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

#### Remaining Work

- In `Command.hs`, add a root gate helper used as the first action of `runTestInit` and `runTestRun`: it
  checks `siblingProjectConfigPath`, decodes an existing file with the binary's Production `ProjectCodec`,
  runs `Context.validateTopology`, and dies with
  `test: refusing a non-root invocation: current frame <frame> is not the root frame` unless
  `Context.isRootFrame` holds; an undecodable file dies with `test: failed to decode <path>: ...`. Replace the
  "(root-only)" `progDesc` claim with text the gate makes true.
- Add the three `CLISpec` cases above through `cliFixtureResult` (Sprint 20.1), building the non-root sibling
  config with `Fixture.defaultProjectConfig projectName "." VMOrchestrator` (or any role whose current frame
  has a parent) and the root one with `HostOrchestrator`; record the store listing and an assertion-opener
  marker as Sprint 20.2's marker-writing suite does.

### Sprint 20.8: `context` refuses a role wire and names the codec it decodes with [Planned]

**Status**: Planned
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
  `Schema.writeScopedProjectConfigFile` through `withHarnessProjectCodec @Fixture.ProjectConfig
  (V.harnessConfigAuthority authority)` inside `withFixtureHarnessAuthority`; `context-show-file` is
  `ExitSuccess` with stdout exactly `Context.renderComposition (cfgContext cfg)`, and the trees are
  byte-identical.
- `CLISpec` "context show names the Production codec when a file does not decode": a `SecretProjectConfig`
  Harness wire carrying `V.testPlaintextSecret (V.harnessConfigAuthority authority) (V.TestSecret
  "fixture")`, rendered as `SchemaSpec` renders its injected Harness config; `context-show-file` is
  `ExitFailure 1`, stderr contains `context: failed to decode <file> with the Production project codec: `,
  and the trees are byte-identical.
- The cases of Sprint 20.3 pass unchanged.

#### Remaining Work

- In `Command.hs`, rewrite `readContextConfig` to read the file's text, run Sprint 7.15's first-stage
  envelope check, refuse a `ServiceRoleWire` with the role-wire line, and otherwise decode through
  `decodeProjectCodecWithSettings codec (setInputRootDirectory (takeDirectory path)
  Dhall.defaultInputSettings)`, as the sibling-config read in `Config/Schema.hs` does, mapping a decode
  failure to the Production-codec line.
- In `CLISpec.hs`, add the `runSchemaFixture` entry `"context-show-file"`, which reads the path from
  `HOSTBOOTSTRAP_CLI_CONTEXT_FILE` through `lookupEnv` (dying when it is unset) and runs
  `withArgs ["context", "show", file] (runHostBootstrapCLI (specWith passingSuite (pure ()) []))`; the parent
  sets and restores the variable around `cliFixtureResult` as the `project-dry-run` case does with its marker.
- Add the three `CLISpec` cases above through `cliFixtureResult` (Sprint 20.1) and the tree-snapshot helper
  (Sprint 20.3).

## Remaining Work

- Sprint 20.1: assert the `test init` overwrite-refusal and `test run` missing-test-config messages through a
  subprocess runner, and that `test init` leaves the sibling `<project>.dhall` absent; bind
  `testConfigWriteFor` to `InstalledProjectIdentity`; publish the test config atomically (temporary file plus
  `linkNoReplace` to refuse, rename to replace).
- Sprint 20.2: pin the unknown-case refusal text, the help's exact `all` phrases, the existing-config refusal on
  a run that would otherwise succeed, and the generated config's presence during the case.
- Sprint 20.3: drive `context inspect` and `context show` through the real parser, assert their output and a
  byte-identical tree, and render the current-frame marker at each frame position.
- Sprint 20.7: add the root gate `test init` and `test run` pass first, refusing a non-root sibling config
  before any test-config or protected-store access, and pin both refusals.
- Sprint 20.8: refuse a role wire in `context inspect`/`context show` through the first-stage envelope check
  before any decode, and name the Production codec in the decode-failure line.

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
