# Phase 3 — Host tools and substrate detection

**Status**: Done
**Depends on**: Phase 2 (Haskell core scaffolding)
**Substrates**: linux-cpu
**Gate**: `cabal test all --ghc-options=-Werror` from `core/`

> **Purpose**: Close both axes of host invocation — *which* executable a call names, and the *shape* the
> call takes — and classify the outer host realization on which the binary is running.

## Phase Objective

Every later phase invokes host tools. Two independent things can go wrong: the call can resolve to the
wrong executable, and it can be launched with a stdio and session disposition that makes its failure
invisible. Both boundaries are closed here, together, because resolving a path absolutely says nothing
about the shape of the call — and a child that outlives its launcher is where the two come apart most
sharply.

## Sprints

### Sprint 3.1: The closed `HostTool` boundary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`,
`core/hostbootstrap-core/src/HostBootstrap/HostConfig.hs`,
`core/hostbootstrap-core/test/HostToolSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

No invocation resolves through `$PATH`.

#### Deliverables

- `HostTool` is a closed enumeration of every external tool core may invoke: the host-provider tools
  (`incus`, `lima`, `colima`, `wsl`), the cluster tools (`kind`, `kubectl`, `helm`), the package managers,
  and the accelerator toolchains.
- The enumeration is a **description of what the binary drives**, so which tools are in it is decided by
  the phases that drive them, not here. This sprint owns the boundary: that the set is closed, that entry
  to it is by construction, and that nothing resolves outside it. § K names the
  [cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md) as the
  owner of the membership, because it holds the last host-side driver.
- Each tool resolves to an `AbsExe` — an absolute path — recorded in typed `HostConfig`.
- `buildHostConfig` performs resolution once; no library or project code calls a bare command name.
- A tool that cannot be resolved is a typed refusal naming the tool, not a runtime `ENOENT`.
- In-VM tools are reached through one resolved host-provider command; the VM's own `$PATH` is the VM's
  concern, because the VM is a separate machine.

#### Validation

`HostToolSpec` covers resolution, the refusal, and the absence of bare-name invocation. Every constructor
has a bare command name with no separator, which is the property that makes resolution the only way to
reach an executable; which constructors exist is pinned by the phase that owns the membership.

Dated evidence: on 2026-08-18, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/` host-native at
1,951/1,951 in 241.11 seconds, plus `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231 passed.

#### Remaining Work

None.

### Sprint 3.2: Outer-host realization classification [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate.hs`,
`core/hostbootstrap-core/test/SubstrateSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

Classify the outer host into one closed provider-selection set without redefining the universal
`linux-cpu` execution substrate.

#### Deliverables

- `detect` yields exactly one outer-host realization tag from `apple-silicon`, `linux-cpu`, `linux-gpu`,
  `windows-cpu`, `windows-gpu`; the retained spellings are host/provider dispatch vocabulary, while the
  plan's `linux-cpu` baseline is the Linux/container execution invariant realized through that dispatch.
- The GPU distinction on Linux is drawn from concrete host evidence (`/proc/driver/nvidia/version` and
  `/dev/nvidiactl`), so a host without NVIDIA markers classifies as `linux-cpu` and cannot be presented as
  a GPU lane.
- Classification is a total function: there is no unknown outer host that later provider code must guess
  about. Apple selects Lima/Colima, Windows selects WSL2, and native Linux selects its native runtime path;
  each CPU route realizes the same project-visible `linux-cpu` substrate.

#### Validation

`SubstrateSpec` covers each branch and the evidence each one reads.

#### Remaining Work

None.

### Sprint 3.3: Host prerequisites after the binary exists [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/HostPrereqs.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

State the post-binary host floor separately from the pre-binary one.

#### Deliverables

- `HostPrereqs` names what the binary requires of its host, per substrate.
- The set is derived from the classified substrate rather than asserted uniformly.
- A missing prerequisite is a typed refusal that names it.

#### Validation

Covered by `SubstrateSpec` and `HostToolSpec` over each substrate branch.

#### Remaining Work

None.

### Sprint 3.4: The invocation-shape boundary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Detached.hs`,
`core/hostbootstrap-core/test/DetachedSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

Close the second axis: the stdio disposition, descriptor inheritance, session, environment, and working
directory of every launched child.

#### Deliverables

- `HostBootstrap.Detached` is the single sealed boundary for launching a child, including one that outlives
  its launcher.
- A detached child's stdio disposition is declared explicitly, so a failure cause is written somewhere a
  reader can find it rather than to a descriptor that is already closed.
- Descriptor inheritance, session leadership, environment, and working directory are all part of the
  declared shape; none is inherited by accident.
- The type makes an unspecified disposition unrepresentable, so a call site cannot omit one.

#### Validation

`DetachedSpec` covers each disposition and asserts a detached child's cause survives its launcher.

#### Remaining Work

None.

### Sprint 3.5: The canonical project root [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/ProjectRoot.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/test/ProjectRootSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/CrossScopeProjectRoot.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Derive one canonical root for a project's durable state.

#### Deliverables

- `CanonicalProjectRoot` is an opaque, validated absolute root; a caller cannot supply an arbitrary path as
  "the project root".
- Root admission retains the surrounding config/lifecycle `scope` and mints only a fresh `rootId`; the sibling
  config admission therefore yields `CanonicalProjectRoot configScope rootId`, never an independently scoped
  root that a later plan must reconcile by convention.
- Every durable projection — state, build outputs, protected store — is derived from it, so two call sites
  cannot disagree about where a project's state lives.
- The root is host-durable and is never inside a provider frame.

#### Validation

`ProjectRootSpec` covers derivation, validation, and the durable projections. `CrossScopeProjectRoot.hs`
proves a root admitted with one config scope cannot be consumed as another.

Dated evidence for the phase gate: `cabal test all --ghc-options=-Werror` from `core/` passed 1047/1047
on 2026-08-08 (aarch64-osx, GHC 9.12.4).

#### Remaining Work

None.

### Sprint 3.6: The one shell quoter [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/Quote.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Effect.hs`,
`core/hostbootstrap-core/test/EffectSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

Give the package one answer to "how does this argument survive the interpreter that will re-split it".

#### Deliverables

- `HostBootstrap.Effect.Quote` is the sole definition site: `shellQuoteArg` for POSIX `sh`,
  `shellQuoteArgs` for a joined argv, and `powerShellQuoteArg` for Windows PowerShell.
- It is a leaf — pure, naming no tool, path, or process — in its own private sublibrary, so the main
  library, the private backend sublibraries beneath it, and the consumer above it all reach the same
  definition rather than the nearest copy.
- `HostBootstrap.Effect` re-exports it, so a consuming project composes commands against the library's
  quoter instead of writing one.
- The two grammars are separate functions rather than one function with a flag, because a POSIX shell
  leaves the quoting to spell a literal quote while PowerShell doubles it in place; a caller that reaches
  for the wrong one names it, rather than producing a string that is wrong only for some inputs.
- Every argument is quoted, including the empty one, which would otherwise leave the argument vector.
- `EffectSpec` holds the absence guards: exactly one definition site per grammar across the library, its
  sublibraries, and the consumer, and no module names a quoter of its own.

#### Validation

`EffectSpec`'s guards run over the library, its private sublibraries, and the demo consumer, and
`LiftSpec`'s shared shell-quoting cases exercise the quoter through the lift that consumes it.

Dated evidence: on 2026-08-17, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/` host-native at
1,881/1,881 in 223.77 seconds.

#### Remaining Work

None.

### Sprint 3.7: The one process runner [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/Run.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Effect.hs`,
`core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs`,
`core/hostbootstrap-core/internal/cluster-backend/HostBootstrap/Cluster/Backend/Internal.hs`,
`core/hostbootstrap-core/test/EffectSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

Give the package one answer to "start this child and read what it said", so a descriptor, exception, or
teardown decision is made once rather than at every spawn site.

#### Deliverables

- `HostBootstrap.Effect.Run` is the sole definition site of a captured child process. It lives beside
  the quoter, in the leaf sublibrary the main library, the private backend sublibraries, and the
  consumer above them all reach.
- Two dispositions, because two are genuinely distinct rather than one with a flag. `runCaptured` feeds
  a stdin string and reads both output streams to end. `runBoundedGrouped` is what a driver needs when
  its child may hang, may talk forever, or may leave descendants: the child leads its own process group,
  receives a complete `RunNamespace` rather than inheriting the launcher's environment and working
  directory, and is bounded by a `RunBounds` row of wall clock, per-stream output ceiling, and
  termination grace.
- The two hand-written bounded runners are gone. The Colima backend and the cluster backend each keep
  only their own row of `RunBounds` and their own `RunNamespace`, and neither carries a pipe reader, a
  watchdog, or a group teardown of its own. They previously disagreed about all three — chunked
  `ByteString` reads against character-at-a-time truncation, a real timeout against a polled `MVar`, and
  a six-second grace against two — and no gate compared them because each passed its own tests.
- Every bound the runner states is one it actually holds. A wall clock, a grace period, and a reap
  budget are all waited out by polling the child's status rather than by wrapping a blocking wait in a
  timeout: a process wait is a foreign call, and under the non-threaded runtime the gate builds this
  package with, an asynchronous exception cannot bring the launcher back out of one. A bound written
  that way expires without anything happening, so the escalation beneath it — group `SIGTERM`, the
  grace, then group `SIGKILL` — never runs, and an uncooperative child hangs the launcher for as long as
  it likes. Polling reaps the child without entering a call the launcher cannot return from, so the same
  numbers mean the same thing on every gate host.
- The teardown waits for the *group*, not the leader. A driver whose leader exits immediately and leaves
  a grandchild holding the pipes has not finished just because the leader has, so the grace period ends
  when the group is empty and the escalation to `SIGKILL` is driven by a null-signal probe of the group
  rather than by the leader's exit alone. Descendants are exactly what a grouped teardown exists to
  reach.
- Failure to *start* stays distinct from failure to *succeed*: a child that ran and exited non-zero is
  `Right` with its exit code, and only a child that never existed is `Left`.
- Every catch is synchronous-only, so a cancelled launcher no longer reads as a broken tool.
- The macOS branch applies to both backends the working-directory handling only the cluster backend
  previously carried, so the two no longer disagree about it. A gate host that is not Apple never takes
  that branch, which is why the [Apple Silicon substrate phase](phase-25-apple-silicon-substrate.md)
  lists confirming it among what it confirms.
- Discovery is the one carve-out and it is named rather than implied: the Windows `vswhere` probe runs
  before any tool is resolved, so it names no described effect, and it still spawns through the one
  runner.
- `EffectSpec` holds the absence guards: exactly one definition site for the captured primitive and for
  the bounded runner, process-group signalling confined to the two boundaries that own a group, and an
  explicit list of the four modules allowed to assemble a child process at all.

#### Validation

`EffectSpec`'s seven guards, `ColimaSpec`'s bounded-subprocess and timeout-ownership cases, and
`ClusterBackendSpec`'s closed-command cases run the unified runner through both backends.

Dated evidence: on 2026-08-17, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/` host-native at
1,885/1,885 in 222.28 seconds, plus `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231 passed.

Dated evidence: on 2026-08-18, x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0 passed the same gate
host-native at 2,121/2,121 in 209.17 seconds, plus both Python commands with 231 passed. That gate host
is where the bounded teardown is exercised end to end: `ClusterBackendSpec`'s three grouped-teardown
cases drive a real child that ignores `SIGTERM`, a leader that exits leaving a grandchild on the pipes,
and an asynchronous cancellation of the launcher, each against the platform's own signals.

#### Remaining Work

None.

### Sprint 3.8: The closed vocabulary and its one interpreter [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Effect/Vocabulary.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Effect/Interpreter.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Effect.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/test/EffectSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

Make a host-level command a value in one closed vocabulary, and put the interpreter of that vocabulary
in the library beside it.

#### Deliverables

- `HostBootstrap.Effect.Vocabulary` carries the four things § KK requires of a described command: the
  target, the exact argument vector, the stdio disposition, and the frame whose process interprets it.
  It is pure and names no runner, so argument construction is separately testable and a function that
  builds an argument vector cannot also run it.
- The target is closed over a resolved `HostTool` and the binary's own path. There is no constructor
  for a bare command name, which is the invocation § K exists to prevent.
- The frame is part of the value rather than context a caller remembers, and it earns that place:
  `framePathGrammar` is the one answer to § MM's question, so a validator's grammar follows the process
  that will read the path rather than the code that derived it.
- The crossing is *recorded* here and *rendered* by the lift's single fold. `foldLeafCommand` pairs the
  fold's own dispatch with `liftContextFrame`'s description of where it lands, so a reader and a
  validator agree with the fold instead of re-deriving it — and `CrossedInto` is non-empty by
  construction, so "crossed nothing" is a different value rather than a length to check.
- `HostBootstrap.Effect.Interpreter` is the one interpreter. `resolveLaunch` is pure and total: it turns
  a described command into the executable and argument vector the host launches, including the one
  reframing an outer host imposes — on Windows a WSL command goes through PowerShell, built with the one
  PowerShell quoter. `interpretHostEffects` runs an effect list under one of two failure policies.
- The interpreter that lived in the consumer is gone. The demo supplies only the two seams a library
  genuinely cannot: the wall's project-owned ownership identity, and where a run's transcript goes.
  Every other decision — resolution, launch, and the judgement of a failure — is the interpreter's.
- `Ensure.runToolWithStdin` and the lift's leaf runners are now the same call into that interpreter, so
  the WSL reframing has one home instead of being a branch inside the reconciler runner.
- `EffectSpec` holds the guards: one definition site each for the effect interpreter and the described-
  command interpreter, and no consumer-resident interpreter; plus behavioural cases for resolution,
  refusal, the frame's grammar, and the frame the fold reports.

#### Validation

`EffectSpec`'s guards and behavioural cases, `LiftSpec`'s dispatch and import-boundary cases, and
`ProviderSpec`'s exact provider effect lists cover the vocabulary and its interpreter.

#### Remaining Work

None.

### Sprint 3.9: The tree carries no script [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/EffectSpec.hs`,
`documents/engineering/durable_windows_runs.md`, `CLAUDE.md`, `AGENTS.md`
**Substrates**: —
**Docs to update**: `documents/engineering/durable_windows_runs.md`

#### Objective

Remove from the tree the scripts this phase owns, and make their absence a guard rather than a habit.

#### Deliverables

- The two Windows durable-run files — the out-of-tree launcher and its `PreToolUse` guard — are gone
  from the repository. They exist because of one development harness's own process reaper, so under
  § KK they live in that harness's configuration (`%USERPROFILE%\.claude\hostbootstrap\`) rather than
  here. Nothing in the build, the gates, or the operator surface depended on them.
- `documents/engineering/durable_windows_runs.md` keeps the mechanism, the root cause, and the
  procedure, and gains what it previously assumed: how to install both files on a fresh Windows
  machine. The document is what travels with the repository.
- `EffectSpec` asserts that the tree carries no script, against an explicit list of what is left. The
  directories it does not descend into come from the repository's own `.gitignore`, so a new build
  output directory is not a new place a script can hide.
- One entry remains on that list, and it names the phase that removes it: the live kind/Helm gate is the
  [cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md)'s.

#### Validation

`EffectSpec`'s script-absence guard, and the documentation validator over the changed governed
documents.

Dated evidence for the phase gate: on 2026-08-17, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and
Cabal 3.16.1.0 passed `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/`
host-native at 1,894/1,894 in 226.70 seconds, plus
`poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all` at
231 passed.

#### Remaining Work

None.

## Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — the closed `HostTool`/`AbsExe` boundary and the separate
  invocation-shape boundary.
- `documents/architecture/build_and_run_model.md` — the closed substrate set and the evidence each branch reads.
- `documents/architecture/durable_state.md` — the canonical project root and its durable projections.

**Engineering docs to create/update:**
- `documents/engineering/prerequisites.md` — the host floor per substrate.
- `documents/engineering/testing.md` — what the static suites do and do not cover for host invocation.

**Cross-references to add:**
- `development_plan_standards.md` § K and § HH name this phase as the owner of the two axes.
