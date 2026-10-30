# Phase 3 — Host tools and substrate detection

**Status**: Done
**Depends on**: Phase 2 (Haskell core scaffolding)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-12 ; x86_64 Ubuntu 24.04.4 LTS, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` ; pass ; covers in-gate
**Gate evidence**: 2026-10-26 ; `hostbootstrap-core-gate-20261026`, x86_64 Ubuntu 24.04.4 CPU-only container on WSL2 Linux 6.18.33.2, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --test-options=--hide-successes` from `core/` ; pass ; covers in-gate
**Gate evidence**: 2026-10-26 ; `DESKTOP-R6BTBVS`, native x86_64 Windows 11 10.0.26300.9457, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all --test-options=--hide-successes` from `core/` and `demo/`, `poetry run python -m hostbootstrap.check_code` and `poetry run python -m hostbootstrap.test_all` from the root ; pass ; covers in-gate

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
- Each tool resolves to an `AbsExe` — an absolute path — recorded in typed `HostConfig`. `AbsExe` is a
  newtype whose constructor is private and whose accessor `absExePath` is a plain function rather than an
  exported record field, so neither construction nor record update can produce a bare command name;
  `mkAbsExe` is its only producer.
- `buildHostConfig` measures every tool once at the start of an invocation; no library or project code
  calls a bare command name. `resolveInstalled` is the one sanctioned re-measurement: for a tool the
  configuration has no entry for (one an `ensure` step installed after the measurement), it calls
  `discover` again and still answers with an `AbsExe` or nothing.
- Versioned toolkit roots (the POSIX `/usr/local/cuda-*` siblings, the Windows CUDA `v*` directories, and
  the MSVC `VC\Tools\MSVC\<version>` directories) are ordered newest first by one pure function that
  compares numeric version components, so `cuda-12.10` ranks above `cuda-12.9` and `cuda-12.4` above
  `cuda-9.2`.
- Windows fallback paths derive from the host's own folders (`%SystemRoot%\System32` for `wsl.exe` and
  `bcdedit.exe`, `%ProgramFiles%` and `%ProgramFiles(x86)%` for the toolchain roots) and fall back to the
  search path, so a host installed on a drive other than `C:` resolves the same tools.
- A tool that cannot be resolved is a typed refusal naming the tool, not a runtime `ENOENT`.
- In-VM tools are reached through one resolved host-provider command; the VM's own `$PATH` is the VM's
  concern, because the VM is a separate machine.

#### Validation

`HostToolSpec` covers resolution, the refusal, and the absence of bare-name invocation. Every constructor
has a bare command name with no separator, which is the property that makes resolution the only way to
reach an executable; which constructors exist is pinned by the phase that owns the membership.

The sprint closes when these cases exist and pass under `cabal test all` from `core/`:

- `HostToolSpec`: the version-ordering function ranks `["cuda-9.2", "cuda-12.4", "cuda-12.9",
  "cuda-12.10"]` as `cuda-12.10, cuda-12.9, cuda-12.4, cuda-9.2`, ranks `["v9.0", "v12.10", "v12.9",
  "v13.0"]` as `v13.0, v12.10, v12.9, v9.0`, and ranks MSVC `14.40.33807` above `14.29.30133`;
  `cudaCandidatePaths` returns the stable symlink first and then that order.
- `HostToolSpec`: `resolveInstalled` over a configuration holding a path that cannot exist on any host
  (`/nonexistent/hostbootstrap-configured/docker`, or `C:\nonexistent\docker.exe` on Windows) returns
  exactly that path, so a resolver that re-measures first fails the case.
- `HostToolSpec`: every `Just` answer `discover` gives over `allHostTools` is absolute and has a basename
  beginning with the tool's `toolCommandName` stem. A regular file satisfies `doesFileExist`; a Windows
  Winget `AppExecutionAlias`, which that predicate cannot follow, must have native alias metadata and
  successfully execute that exact absolute path with `--version`, producing non-empty output. A dangling
  link cannot satisfy the launch proof. No case asserts only over the fixture map built through `mustAbs`.
- `HostToolSpec` (Windows only): `discover Wsl` and `discover Bcdedit` equal the `System32` path built
  from `%SystemRoot%`.
- `CompileFailSpec`: a registered fixture `test/compile-fail/RelabelAbsExe.hs` that writes
  `relabel e = e { absExePath = "docker" }` is rejected with
  `Not in scope: record field 'absExePath'`.

Dated evidence: on 2026-08-18, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/` host-native at
1,951/1,951 in 241.11 seconds, plus `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231 passed.

Dated closing evidence, 2026-10-26: The actual-discovery cases pass on both hosts, including native SystemRoot paths, configured-first refusal-resistant resolution, numeric CUDA/MSVC ordering, the abstract record-field rejection, and successful exact-path Winget alias execution.
The declared Linux CPU core gate passed 2,633/2,633 in 234.60 seconds. Native Windows core passed
2,626/2,626 in 442.17 seconds; the demo leg passed 164/164 in 5.80 seconds and its included core
2,626/2,626 in 430.02 seconds. Python check_code and the complete 376-case suite passed, with 100%
line and branch coverage. The closing phase evidence below records the commands and gate hosts.

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
- The accelerator evidence is read per frame. On Linux it is the kernel markers
  (`/proc/driver/nvidia/version`, `/dev/nvidiactl`), then a device listed by `nvidia-smi -L`; on Windows
  it is `nvidia-smi -L` alone, because the kernel markers are Linux paths; on macOS there is no probe.
  `nvidia-smi` is resolved through `discover NvidiaSmi`, never a raw search-path lookup, and the listing
  runs under a five-second wall clock (the bootstrapper's own bound for the same probe), with a timeout
  read as "no GPU".
- The evidence reads sit behind a pure closed probe plan and a pure answer over observed marker and bounded-run values;
  short IO wiring supplies the real reads. The decision is tested without replacing the executor.
- Classification is a total function: there is no unknown outer host that later provider code must guess
  about. Apple selects Lima/Colima, Windows selects WSL2, and native Linux selects its native runtime path;
  each CPU route realizes the same project-visible `linux-cpu` substrate.
- `substrateFrame` is the one place the five tags collapse to the three frames, and `isAppleSilicon`,
  `isLinux`, and `isWindows` are derived from it.

#### Validation

`SubstrateSpec` covers each `classify` branch over a literal GPU answer. The sprint closes when these
cases also exist and pass under `cabal test all` from `core/`:

- The per-frame evidence decision, over observed values: Linux with a marker present is a GPU
  host; Linux with no marker and an `nvidia-smi -L` listing containing `nvidiaDeviceMarker` is a GPU
  host; Windows with a marker path present and no `nvidia-smi` is not; a timed-out `nvidia-smi` run is
  not; macOS selects no marker or listing read.
- A table case: `substrateFrame` over all five names gives `AppleFrame, LinuxFrame, LinuxFrame,
  WindowsFrame, WindowsFrame`, and `isWindows` is `True` exactly for the two Windows names.

Dated closing evidence, 2026-10-26: SubstrateSpec passes its per-frame marker/listing decisions, timeout and other refusal outcomes, all five tag/frame mappings, and derived predicates without replacing a process executor.
The declared Linux CPU core gate passed 2,633/2,633 in 234.60 seconds. Native Windows core passed
2,626/2,626 in 442.17 seconds; the demo leg passed 164/164 in 5.80 seconds and its included core
2,626/2,626 in 430.02 seconds. Python check_code and the complete 376-case suite passed, with 100%
line and branch coverage. The closing phase evidence below records the commands and gate hosts.

#### Remaining Work

None.

### Sprint 3.3: Host prerequisites after the binary exists [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/HostToolSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`,
`documents/architecture/hostbootstrap_core_library.md`, `documents/engineering/prerequisites.md`

#### Objective

State the post-binary host floor separately from the pre-binary one. § M gives the pre-binary floor (OS
version, passwordless sudo, Xcode CLT and Homebrew, winget and Windows PowerShell) to the bootstrapper,
which asserts it before the binary exists; after the binary exists, every prerequisite with an install
plan is a § L `ensure` reconciler. The binary therefore carries no second copy of the pre-binary floor.

#### Deliverables

- The pre-binary floor has one implementation, the bootstrapper's `prereqs.py`; no Haskell module
  re-asserts it.
- Post-binary prerequisites are reconcilers dispatched on the classified substrate's frame, each refusing
  with a typed value that names what is missing.
- `HostBootstrap.HostPrereqs` and its exported `checkHostMinimums`, which no command calls, are absent
  from the package, and an absence guard keeps them absent.

#### Validation

The sprint closes when, under `cabal test all` from `core/`, an absence case asserts that no Haskell
source under `core/hostbootstrap-core/src`, `core/hostbootstrap-core/internal`,
`core/hostbootstrap-core/app`, or `demo/src` defines `checkHostMinimums` or declares
`module HostBootstrap.HostPrereqs`, and the Python suite's `tests/test_prereqs.py` still covers the
Ubuntu 24.04, sudo, Xcode CLT, Homebrew, winget, and PowerShell floor.

Dated closing evidence, 2026-10-26: The production-root absence guard passes with the dead Haskell prerequisite module and Cabal exposure removed. The complete Python prerequisite cases remain in the passing 376-case Python suite.
The declared Linux CPU core gate passed 2,633/2,633 in 234.60 seconds. Native Windows core passed
2,626/2,626 in 442.17 seconds; the demo leg passed 164/164 in 5.80 seconds and its included core
2,626/2,626 in 430.02 seconds. Python check_code and the complete 376-case suite passed, with 100%
line and branch coverage. The closing phase evidence below records the commands and gate hosts.

#### Remaining Work

None.

### Sprint 3.4: The invocation-shape boundary [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Detached.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/test/DetachedSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeDetachedLaunch.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/build_and_run_model.md`

#### Objective

Close the second axis: the stdio disposition, descriptor inheritance, session, environment, and working
directory of every launched child.

#### Deliverables

- `HostBootstrap.Detached` is the single sealed boundary for a child that outlives its launcher. It is one
  of the launch boundaries `EffectSpec` lists (Sprint 3.7); the others own a captured run, a bounded
  grouped run, a handoff child holding an inherited descriptor pair, and a long-lived worker session.
- A detached child's stdio disposition is declared explicitly, so a failure cause is written somewhere a
  reader can find it rather than to a descriptor that is already closed.
- Descriptor inheritance, session leadership, environment, and working directory are all part of the
  declared shape; none is inherited by accident.
- The type makes an unspecified disposition unrepresentable, so a call site cannot omit one.
- A `DetachedChild` cannot be used outside the `withDetachedChild` body that produced it: its operations
  run in an indexed monad (`DetachedIO child`) that only `withDetachedChild` runs, the ST pattern, so a
  closure over the child cannot be returned and run later.
- Both child-extent roles are nominal and both constructors are private. `liftDetachedIO` admits ordinary
  IO without exposing an interpreter for a child action, and `tryDetachedIO`/`onDetachedException` retain
  the same extent through exception handling.
- `withDetachedChild` masks its own acquire, spawn, and hand-off and runs the body restored, so an
  asynchronous exception can neither leak the sink or null-device handle nor leave a running child the
  body never saw.
- Exceptional handoff or body exit aborts the exact child with bounded polling and hard-termination
  escalation, preserving the original exception. Normal return leaves the detached child running.
- `awaitDetachedChild` waits out its budget by polling `getProcessExitCode`, never by wrapping
  `waitForProcess` in `timeout`, so the bound holds under the non-threaded runtime the core suite is
  built with.

#### Validation

`DetachedSpec` asserts a launched child's standard input is open at EOF, both outputs reach the one
sink, the child outlives the bracket, acquire-and-spawn is total, and body exceptions propagate. The
sprint closes when these cases also exist and pass under `cabal test all` from `core/`:

- Standard input is the null device, not the launcher's: the probe is launched from a parent whose own
  standard input is a pipe holding pending bytes, and the child still reports 0 bytes read.
- The environment and working directory are the launch's: the launch passes a minimal environment holding
  a sentinel variable and omitting one the launcher has, the child prints its environment and
  `getCurrentDirectory`, and the case asserts the sentinel is present, the omitted variable is absent,
  and the directory equals the launch's working directory. The record-accessor assertions in
  `withProbeLaunch` are replaced by a child-reported `getArgs` check.
- `terminateDetachedChild` on a lingering child is followed by `awaitDetachedChild` returning `Just`.
- `awaitDetachedChild` on a lingering child with a 200 ms budget returns `Nothing` within the budget.
- A real lingering child stops appending after a body exception, and that exception reaches the caller
  unchanged. On POSIX the child ignores `SIGTERM`, proving hard-termination escalation; Windows termination
  is already hard.
- The drift guard scans `core/hostbootstrap-core/internal` as well, fails when any listed source root is
  absent or holds no `.hs` file, and admits exactly the transitional entry named in Remaining Work.
- `CompileFailSpec`: a registered fixture `test/compile-fail/EscapeDetachedChild.hs` that returns
  `terminateDetachedChild child` out of the body is rejected with
  "Couldn't match type 'child' with 'escaped'". `CoerceDetachedChildRole.hs` and `CoerceDetachedIORole.hs`
  reject child-extent relabelling with "Couldn't match type 'ChildA' with 'ChildB'".

Dated closing evidence, 2026-10-26: Real probes verify pending launcher input does not reach the child, exact argv/environment/cwd, bounded wait, explicit termination, normal detachment, and exceptional exact-child cleanup. Linux exercises the SIGTERM-ignoring child escalation; indexed-child and action coercion/escape fixtures reject for their named boundaries.
The declared Linux CPU core gate passed 2,633/2,633 in 234.60 seconds. Native Windows core passed
2,626/2,626 in 442.17 seconds; the demo leg passed 164/164 in 5.80 seconds and its included core
2,626/2,626 in 430.02 seconds. Python check_code and the complete 376-case suite passed, with 100%
line and branch coverage. The closing phase evidence below records the commands and gate hosts.

#### Remaining Work

None.

### Sprint 3.5: The canonical project root [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/ProjectRoot.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
`core/hostbootstrap-core/test/ProjectRootSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/CrossScopeProjectRoot.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/durable_state.md`

#### Objective

Derive one canonical root for a project's durable state.

#### Deliverables

- `CanonicalProjectRoot` is an opaque, validated absolute root; its constructor is private, so a caller
  cannot supply an arbitrary path as "the project root".
- Both `scope` and `rootId` are nominal in `CanonicalProjectRoot` and `CanonicalHostPath`, so neither a
  root nor a derived host path can be relabelled through `Data.Coerce`.
- `withCanonicalProjectRoot` mints only a fresh `rootId`, under a rank-2 continuation, so a root identity
  cannot leave the bracket that admitted it. It takes no scope witness: `scope` is whatever the caller's
  types fix. The sibling config admission `withSiblingValidatedProjectConfigRoot` fixes it to its codec's
  scope, so the root it admits is `CanonicalProjectRoot configScope rootId` and cannot be consumed under
  another scope; every other admission fixes `scope` by unification with the consumer it hands the root
  to. The module's Haddock says exactly that.
- The anchor is the parent of the config's directory when that directory is `.build`, and the config's
  directory otherwise, compared with the host's filename grammar (`.BUILD` also matches on Windows).
  A relative configured root is confined to the canonicalized anchor by a comparison
  of trailing-separator-terminated paths, so a sibling such as `../project-evil` is not "under"
  `project`; an absolute configured root is exempt from confinement. Confinement is checked on the
  canonicalized root, so a link inside the project cannot redirect admission outside it.
- Every refusal — `ProjectRootResolutionFailed`, `ProjectRootEscapesAnchor`, `ProjectRootMissing`,
  `ProjectRootNotDirectory` — is returned before the continuation runs.
- Every durable projection — state, build outputs, protected store — is derived from it, so two call sites
  cannot disagree about where a project's state lives.
- The root is host-durable and is never inside a provider frame.

#### Validation

`ProjectRootSpec` covers derivation, the missing, not-a-directory, and `../outside` refusals, the
subpath refusals, and the durable projections. `CrossScopeProjectRoot.hs` proves a root admitted by the
sibling config admission with one config scope cannot be consumed as another.

Dated sprint evidence: `cabal test all --ghc-options=-Werror` from `core/` passed 1047/1047 on
2026-08-08 (aarch64-osx, GHC 9.12.4).

The sprint closes when these cases also exist and pass under `cabal test all` from `core/` on Linux and
on Windows host-native:

- `ProjectRootSpec`: with `workspace/project/.build/demo.dhall` and a sibling directory
  `workspace/project-evil`, configured root `"../project-evil"` gives
  `Left (ProjectRootEscapesAnchor <canonical project-evil> <canonical project>)`.
- `ProjectRootSpec`: the same layout with the canonical absolute path of `workspace/outside` as the
  configured root gives `Right` with that path (the absolute exemption).
- `ProjectRootSpec`: a config at `workspace/project/demo.dhall` (not under `.build`) with configured root
  `"."` gives `Right <canonical project>`, and with `"../outside"` gives `ProjectRootEscapesAnchor` against
  `project` as the anchor.
- `ProjectRootSpec`: a config in an actual `workspace/project/.BUILD` directory with configured root
  `"."` admits the canonical parent project on Windows and the canonical `.BUILD` directory on POSIX.
  The case runs on every host and derives its expected anchor from the host family independently of the
  production filename comparator.
- `ProjectRootSpec`: a configured root carrying an embedded NUL (`"bad\0root"`) gives
  `ProjectRootResolutionFailed` whose first field is the candidate `anchor </> "bad\0root"`; the case
  matches the constructor and that field, not the host's error text.
- `ProjectRootSpec`: the "replaced relative root" case runs on every host, including Windows (where
  `createDirectoryLink` creates a directory symlink and `canonicalizePath` resolves it), and asserts
  `ProjectRootEscapesAnchor`; a host on which the link cannot be created fails the case naming that
  precondition rather than passing.
- `ProjectRootSpec`: every refusal case (missing, not-a-directory, `../outside`, `../project-evil`, the
  link redirect, the resolution failure) passes a continuation that sets an `IORef Bool`, and asserts it
  is still `False` after the refusal.
- `CompileFailSpec`: `test/compile-fail/EscapeCanonicalProjectRoot.hs`
  (`escaped = withCanonicalProjectRoot cfg root pure`) is rejected with
  "Couldn't match type 'rootId' with 'escapedRoot'", and
  `test/compile-fail/ForgeCanonicalProjectRoot.hs` (`forged = CanonicalProjectRoot "/tmp"`) is rejected
  with "Illegal term-level use of the type constructor 'CanonicalProjectRoot'".
- `CompileFailSpec`: `CoerceCanonicalProjectRootScope.hs` and `CoerceCanonicalHostPathScope.hs` reject
  relabelling with "Couldn't match type 'ScopeA' with 'ScopeB'"; `CoerceCanonicalProjectRootId.hs` and
  `CoerceCanonicalHostPathRootId.hs` reject relabelling with "Couldn't match type 'RootA' with 'RootB'".

Dated closing evidence, 2026-10-26: All admission/refusal and untouched-continuation cases pass, including real link redirection, non-.build anchors, absolute-root exemption, sibling-prefix escape, embedded-NUL resolution refusal, and the host-sensitive .BUILD anchor. Constructor, root escape, and four nominal-index coercion fixtures reject for the observed GHC reasons.
The declared Linux CPU core gate passed 2,633/2,633 in 234.60 seconds. Native Windows core passed
2,626/2,626 in 442.17 seconds; the demo leg passed 164/164 in 5.80 seconds and its included core
2,626/2,626 in 430.02 seconds. Python check_code and the complete 376-case suite passed, with 100%
line and branch coverage. The closing phase evidence below records the commands and gate hosts.

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
  `shellQuoteArgs` for a joined argv, and `powerShellQuoteArg` for a Windows PowerShell single-quoted
  string.
- It is a leaf — pure, naming no tool, path, or process — in its own private sublibrary, so the main
  library, the private backend sublibraries beneath it, and the consumer above it all reach the same
  definition rather than the nearest copy.
- `HostBootstrap.Effect` re-exports it, so a consuming project composes commands against the library's
  quoter instead of writing one.
- `powerShellQuoteArg` doubles every character PowerShell's tokenizer reads as a single quote — the
  ASCII apostrophe U+0027 and the typographic U+2018, U+2019, U+201A, and U+201B — in place, as
  PowerShell's own `EscapeSingleQuotedStringContent` does, so a value such as `C:\Users\O’Neil` cannot
  end the literal early. No library command is spelled as PowerShell text: a WSL command launches
  `wsl.exe` directly with its argument vector, so `HostBootstrap.Effect.Interpreter` does not import the
  quoter. That launch shape is owed by Sprint 3.8, whose Remaining Work deletes the PowerShell route and
  the import the tree's `Interpreter.hs` still carries. The quoter's consumer is the demo's Windows host-daemon launch text, whose private
  `powerShellQuote` copy in `HostBootstrapDemo.Commands` phase 24 (Sprint 24.43) replaces with
  `powerShellQuoteArg`, together with a guard that refuses a PowerShell quoter under any name.
- Every argument is quoted, including the empty one, which would otherwise leave the argument vector.
- `EffectSpec` holds the absence guards: exactly one binding site for the POSIX quoter across the
  library, its sublibraries, and the consumer, counted over both a signature and a binding head (a
  top-level or `where` binding `shellQuoteArg ... =`); exactly one definition site for
  `powerShellQuoteArg`; and no module names a quoter of its own. A renamed copy is out of reach of a
  lexical guard, and the guard's module header says so.

#### Validation

`EffectSpec`'s guards run over the library, its private sublibraries, and the demo consumer, and
`LiftSpec`'s shared shell-quoting cases exercise the quoter through the lift that consumes it. The
sprint closes when these cases exist and pass under `cabal test all` from `core/`:

- The binding-head count passes over the tree, and a fixture source carrying `where shellQuoteArg = ...`
  outside `Quote.hs` makes it report that source.
- One `EffectSpec` case per single-quote character: `powerShellQuoteArg "O'Neil"` is `"'O''Neil'"`,
  `powerShellQuoteArg "O\x2018Neil"` is `"'O\x2018\x2018Neil'"`, and likewise for U+2019, U+201A, and
  U+201B; `powerShellQuoteArg ""` is `"''"`.

Dated evidence: on 2026-08-17, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/` host-native at
1,881/1,881 in 223.77 seconds.

Dated closing evidence, 2026-10-26: The shared source corpus and local binding-head negative fixture pass; each of the five PowerShell quote characters and the empty argument is pinned. The demo quoter under another name remains the explicitly scoped Phase 24 obligation.
The declared Linux CPU core gate passed 2,633/2,633 in 234.60 seconds. Native Windows core passed
2,626/2,626 in 442.17 seconds; the demo leg passed 164/164 in 5.80 seconds and its included core
2,626/2,626 in 430.02 seconds. Python check_code and the complete 376-case suite passed, with 100%
line and branch coverage. The closing phase evidence below records the commands and gate hosts.

#### Remaining Work

None.

### Sprint 3.7: The one process runner [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/Run.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Effect.hs`,
`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
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
  termination grace. Both read the child's output as bytes and decode it as lenient UTF-8, so the same
  bytes give the same `CapturedRun` under either disposition and under any process locale. The Colima
  backend's shipped command transaction and fallback NVIDIA discovery share the bounded runner, each
  keeping its own `RunBounds` row and `RunNamespace`; the cluster backend issues described commands through the
  interpreter (Sprint 3.8) and runs no bounded child.
- Every bound the runner states is one it actually holds. The wall clock is one budget measured from the
  launch, covering the request write, the drain, and the exit wait together. A wall clock, a grace
  period, and a reap budget are all waited out by polling the child's status rather than by wrapping a
  blocking wait in a timeout: a process wait is a foreign call, and under the non-threaded runtime the
  gate builds this package with, an asynchronous exception cannot bring the launcher back out of one.
  The output readers start before the request is written, so a request larger than a pipe buffer cannot
  deadlock against a child that writes first.
- The teardown waits for the *group*, not the leader. On POSIX the grace period ends when the group is
  empty and the escalation to `SIGKILL` is driven by a null-signal probe of the group rather than by the
  leader's exit alone. On Windows the leader is launched into a job object (`use_process_jobs`), so
  `terminateProcess` ends its descendants too.
- Failure to *start* stays distinct from failure to *succeed*: a child that ran and exited non-zero is
  `Right` (or `BoundedCompleted`) with its exit code, and only a child that never existed is `Left` (or
  `BoundedFailed`). A child that exits without reading its request is a completed run, not a spawn
  failure. Every catch is synchronous-only, so a cancelled launcher does not read as a broken tool.
- The working directory reaches the leader without interpreter text on every host. On macOS, where
  `process` cannot combine `create_group`, an explicit environment, and `cwd`, the leader is the
  installed binary's hidden working-directory entry, which changes directory and `exec`s the requested
  executable, and reports a missing directory or executable on a reserved exit code that the runner maps
  to `BoundedFailed`, as Linux and Windows report the same conditions at spawn. A gate host that is not
  Apple never takes that branch, which is why the
  [Apple Silicon substrate phase](phase-26-apple-silicon-substrate.md) lists confirming it among what it
  confirms.
- Discovery spawns are named rather than implied: the Windows `vswhere` probe and the `nvidia-smi -L`
  accelerator probe of fallback detection (Sprint 3.2) run before any configuration is measured, so they
  name no described effect, and both spawn through the one runner.
- `EffectSpec` holds the absence guards: exactly one definition site for the captured primitive and for
  the bounded runner; process-group signalling confined to the three group owners (this runner, the
  Colima shipped command transaction with its parent-death watchdog, and the handoff transports' shared
  `Effect.ChildGroup`); and an explicit list of the six launch boundaries (this runner, the Colima
  shipped command transaction, `HostBootstrap.Detached`, `Handoff.Process`, `Handoff.Transaction`, and
  the demo accelerator daemon). The launch-boundary guard recognises every spawning spelling of
  `System.Process`, `System.Process.Typed`, and `System.Posix.Process`, not only `createProcess` and
  `withCreateProcess`.

#### Validation

`EffectSpec`'s eleven source guards and `ColimaSpec`'s "the shipped command transaction kills its group
on hard parent death" case cover the runner's boundary today. The sprint closes when these behavioural
cases exist in `EffectSpec` and pass under `cabal test all` from `core/`, each driving the test
executable re-invoked through a probe flag dispatched in `test/Spec.hs` (the `DetachedSpec` idiom), on
POSIX hosts unless noted:

- A child that sleeps past a 500 ms wall returns `BoundedTimedOut`, and its process id answers no
  null signal afterwards.
- A child that closes both streams and then sleeps returns `BoundedTimedOut` within one wall plus the
  grace, not two walls.
- A child that writes more than `boundOutputBytes` returns `BoundedOutputLimit`, not a truncated run.
- A child that ignores `SIGTERM` and forks a grandchild holding the pipes leaves neither process alive
  after the grace and the `SIGKILL` escalation.
- A missing executable returns `BoundedFailed`; a `killThread` on the launching thread re-raises
  `ThreadKilled` and leaves no group member.
- A child that exits without reading a request larger than a pipe buffer returns `BoundedCompleted`
  with its exit code.
- `runCaptured` over a child writing invalid UTF-8 returns `Right` with U+FFFD in place of the bad bytes
  while the process locale is ASCII (every host).
- The launch-boundary guard, run over an in-memory source that calls `callProcess`, reports it (every
  host).

Dated evidence: on 2026-08-17, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/` host-native at
1,885/1,885 in 222.28 seconds, plus `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231 passed.

Dated evidence: on 2026-08-18, x86_64 Linux with GHC 9.12.4 and Cabal 3.16.1.0 passed the same gate
host-native at 2,121/2,121 in 209.17 seconds, plus both Python commands with 231 passed.

Dated closing evidence, 2026-10-26: The complete Linux gate exercises real timeout, single wall budget, output ceiling, grandchild escalation, cancellation, unread large input, duplex pipes, native cwd/argv entry, missing directory/executable, and locale-independent byte decoding. Windows executes all portable cases and actual process-probe/native-entry refusals. The focused Windows effect run passed 43/43 before the complete gates. The four new CLI lines are excluded from the unrelated projector attribution; frozen projector hashes and 216/217 line totals remain unchanged.
The declared Linux CPU core gate passed 2,633/2,633 in 234.60 seconds. Native Windows core passed
2,626/2,626 in 442.17 seconds; the demo leg passed 164/164 in 5.80 seconds and its included core
2,626/2,626 in 430.02 seconds. Python check_code and the complete 376-case suite passed, with 100%
line and branch coverage. The closing phase evidence below records the commands and gate hosts.

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
- The frame is part of the value: the lift fold sets it through `inFrame` for every command it crosses,
  and `hostCommand`/`selfCommand` label a command `OuterHost`. `framePathGrammar` is the one pure answer
  to § MM's question for a labelled command. The interpreter does not read the frame and no production
  validator consumes `framePathGrammar`, so the label is descriptive, and the module's Haddock says
  exactly that.
- The crossing is *recorded* here and *rendered* by the lift's single fold. `foldLeafCommand` pairs the
  fold's own dispatch with `liftContextFrame`'s description of where it lands, so a reader and a
  validator agree with the fold instead of re-deriving it — and `CrossedInto` is non-empty by
  construction, so "crossed nothing" is a different value rather than a length to check.
- `HostBootstrap.Effect.Interpreter` is the one interpreter. `resolveLaunch` is pure and total: it turns
  a described command into the executable and argument vector the host launches. A WSL command launches
  the resolved `wsl.exe` directly with `hostToolProcessArguments Wsl`, the shape `Handoff.Process` and
  `Handoff.Transaction` already launch through, so its argument vector — an empty argument, an embedded
  double quote, a typographic apostrophe — reaches `wsl.exe` unchanged and its exit status is the
  command's own; no PowerShell text stands between them. `interpretHostEffects` runs an effect list
  under one of two failure policies.
- The demo carries no interpreter of its own. It supplies only the two seams a library genuinely cannot:
  the wall's project-owned ownership identity, and where a run's transcript goes. Every other decision —
  resolution, launch, and the judgement of a failure — is the interpreter's. Under `BestEffort` the
  intent is announced once per effect list, and a skipped step's reason is the first line of its standard
  error, else of its standard output, else its exit code.
- `Ensure.runToolWithStdin` and the lift's leaf runners are the same call into that interpreter, so a
  launch shape has one home instead of being a branch inside the reconciler runner.
- `EffectSpec` holds the guards: one definition site each for the effect interpreter and the described-
  command interpreter, and no consumer-resident interpreter; plus behavioural cases for resolution,
  refusal, the frame's grammar, the frame the fold reports, and the two failure policies.

#### Validation

`EffectSpec`'s guards and behavioural cases, `LiftSpec`'s dispatch and import-boundary cases, and
`ProviderSpec`'s exact provider effect lists cover the vocabulary and its resolution. The sprint closes
when these cases also exist in `EffectSpec` and pass under `cabal test all` from `core/`:

- `resolveLaunch` for `hostCommand Wsl ["-d", "demo", "--", "", "a \"b\""]` with `Wsl` resolved gives
  the `wsl.exe` path and `hostToolProcessArguments Wsl` over those arguments, on every host; with `Wsl`
  unresolved it gives `Left "wsl not found on this host"`.
- `interpretHostEffects` over a recording `EffectEnvironment` (an `IORef` journal of acquire, release,
  and echo calls) and a configuration whose `SelfTarget` is the test executable re-invoked through a probe
  flag: `FailFast` stops after a failing command and returns `EffectCommandFailed` with its argument
  vector and exit code, running nothing after it; `BestEffort` echoes the intent once, echoes the skip,
  and still runs a trailing `ReleaseGlobalWslWall`; an unresolved tool gives `EffectCommandUnavailable`; a
  failing command whose diagnostic is on standard output gives a non-empty skip reason.
- An `EffectSpec` source guard asserts `Effect/Interpreter.hs` names neither `powerShellQuoteArg`,
  `HostBootstrap.Effect.Quote`, nor `powershell`, so the direct `wsl.exe` launch is the only WSL route.

Dated closing evidence, 2026-10-26: Direct WSL resolution preserves empty, quoted, and typographic arguments; missing WSL refuses by name. Recording effect-policy cases verify fail-fast stopping, one best-effort intent, stderr/stdout/exit fallback reasons including CRLF, and trailing release. The interpreter-text and duplicate-interpreter guards pass.
The declared Linux CPU core gate passed 2,633/2,633 in 234.60 seconds. Native Windows core passed
2,626/2,626 in 442.17 seconds; the demo leg passed 164/164 in 5.80 seconds and its included core
2,626/2,626 in 430.02 seconds. Python check_code and the complete 376-case suite passed, with 100%
line and branch coverage. The closing phase evidence below records the commands and gate hosts.

#### Remaining Work

None.

### Sprint 3.9: The tree carries no script [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/EffectSpec.hs`,
`documents/engineering/durable_windows_runs.md`, `CLAUDE.md`, `AGENTS.md`
**Substrates**: none
**Docs to update**: `documents/engineering/durable_windows_runs.md`

#### Objective

Remove from the tree the scripts this phase owns, and make their absence a guard rather than a habit.

#### Deliverables

- The two Windows durable-run files — the out-of-tree launcher and its `PreToolUse` guard — are gone
  from the repository. They exist because of one development harness's own process reaper, so under
  § KK they live in that harness's configuration (`%USERPROFILE%\.claude\hostbootstrap\`) rather than
  here. Nothing in the build, the gates, or the operator surface depended on them.
- `documents/engineering/durable_windows_runs.md` keeps the mechanism, the root cause, and the
  procedure, and states how to install both files on a fresh Windows
  machine. The document is what travels with the repository.
- `EffectSpec` asserts that the tree carries no script: the list of script files it finds — by a `.sh`,
  `.ps1`, `.bat`, `.cmd`, or `.psm1` extension, or by a `#!` first line — is empty.
- The directories it does not descend into come from the repository's own `.gitignore`, so a new build
  output directory is not a new place a script can hide. An ignore pattern excludes only directories,
  never a file of the same name, and a pattern with an inner `/` (such as `demo/web/public/`) excludes
  only that repository-relative path, as git anchors it.

#### Validation

`EffectSpec`'s script-absence guard, and the documentation validator over the changed governed
documents. The sprint closes when the guard's fixture, under `cabal test all` from `core/`, carries a
`.gitignore` of `build/` and `demo/web/public/` and reports both a `#!/bin/sh` file named `build` at the
fixture root and a `setup.sh` under `docker/public/`, while still skipping a `build/` directory and
`demo/web/public/`.

Dated evidence: on 2026-08-17, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and Cabal 3.16.1.0
passed `cabal build all` and `cabal test all --ghc-options=-Werror` from `core/` host-native at
1,894/1,894 in 226.70 seconds, plus `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231 passed.

Dated closing evidence, 2026-10-26: The repository script-absence guard and directory-only anchored-ignore fixture pass on Linux and Windows. The durable Windows launcher and guard remain outside the repository; their installation procedure is retained in durable_windows_runs.md.
The declared Linux CPU core gate passed 2,633/2,633 in 234.60 seconds. Native Windows core passed
2,626/2,626 in 442.17 seconds; the demo leg passed 164/164 in 5.80 seconds and its included core
2,626/2,626 in 430.02 seconds. Python check_code and the complete 376-case suite passed, with 100%
line and branch coverage. The closing phase evidence below records the commands and gate hosts.

#### Remaining Work

None.

### Sprint 3.10: One substrate detection, and a total accelerator answer [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate.hs`,
`core/hostbootstrap-core/test/SubstrateSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/python_haskell_boundary.md`, `documents/engineering/prerequisites.md`

#### Objective

§ M gives pre-binary detection to the bootstrapper, so the binary's job is to receive that answer rather
than compute it a second time. The accelerator question is answered by a total case over the substrate
sum, so a substrate added to the closed sum is a compile error here instead of a silent 'no
accelerator'.

#### Deliverables

- The binary accepts the substrate the bootstrapper detected through the documented invocation-context seam, and the ordinary `detect` is that read.
- Reading the statement is pure over the two field values, so the refusals are testable without setting a host environment.
- A statement that arrives half-set is a refusal rather than a fallback; only the complete absence of one means the host is classified here.
- A stated `apple-silicon` with any architecture other than `arm64` is refused with the message `classify` gives for an Intel Mac, so the seam admits no pair `classify` could not produce.
- `detectHere` is the labelled fallback for a binary invoked with no bootstrapper in front of it, and says in one line that it is one.
- The accelerator predicate is a total case over the substrate sum, so a new substrate is a compile error rather than a default answer.
- The architecture alias table and the accelerator marker list have one home each in this language, and the suite reads the bootstrapper's own source to assert that its definition lines (`SUBSTRATE_ENV_VAR: Final[str] = "..."`, `ARCH_ENV_VAR: Final[str] = "..."`, and the enum value assignments) state both seam field names and all seven vocabulary spellings; a spelling that appears only in a comment or docstring does not satisfy it.

#### Objective boundary

One fallback classification remains, because a binary invoked directly has no statement to read. That is
why the cross-language agreement is asserted mechanically rather than declared: the second
implementation exists for a reason, so what keeps it from drifting is a guard, not a comment.

#### Validation

The substrate suite pins each classification and its refusals, the total accelerator answer for every
constructor the sum has, the seam's complete/absent/half-set/unknown-tag readings, and the
bootstrapper's source stating the same seven spellings. Dated evidence: on 2026-09-12, x86_64 Ubuntu
24.04.4 LTS with GHC 9.12.4 and Cabal 3.16.1.0, the core leg of the host static gate (`cabal test all`
from `core/`) passed with `SubstrateSpec` at 24 cases; the demo and Python legs are not recorded for
that run.

The sprint closes when these cases also exist and pass under the full host static gate (§ JJ's four
commands):

- `parseStatedHost (Just "apple-silicon") (Just "amd64")` is `Just (Left ...)` carrying the Intel-Mac
  message `classify "darwin" "x86_64"` gives.
- The seam guard matches the bootstrapper's definition lines, and fails on an in-memory copy of
  `substrate.py` whose spellings survive only in a comment.

Dated closing evidence, 2026-10-26: The Apple Silicon/amd64 statement receives the direct Intel-Mac refusal. The seam guard reads actual Python field/enum assignments and rejects comment-only and both docstring-only fixtures. The complete four-command native host static gate passes.
The declared Linux CPU core gate passed 2,633/2,633 in 234.60 seconds. Native Windows core passed
2,626/2,626 in 442.17 seconds; the demo leg passed 164/164 in 5.80 seconds and its included core
2,626/2,626 in 430.02 seconds. Python check_code and the complete 376-case suite passed, with 100%
line and branch coverage. The closing phase evidence below records the commands and gate hosts.

#### Remaining Work

None.

### Sprint 3.11: The Windows resolution cases exist on every gate host [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/test/HostToolSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: none
**Docs to update**: `documents/engineering/testing.md`, `documents/languages/haskell.md`

#### Objective

§ JJ's fifth rule applied to this phase's own suite: a case whose subject one gate host lacks stays in the
suite there and asserts what the subject answers. `HostToolSpec.windowsResolutionCases` holds the two
Windows `System32` discovery cases inside a `#ifdef mingw32_HOST_OS` region whose `#else` arm is the empty
list, so a POSIX gate host runs two fewer cases while the total stays green.

#### Deliverables

- `HostToolSpec.windowsResolutionCases` (two cases) exist on every gate host. On Windows each asserts the
  `System32` path `discover Wsl` and `discover Bcdedit` answer; on a non-Windows host each asserts the exact
  answer the same `discover` call gives there, pinned in the case.
- The branch is a `Bool` predicate defined outside any test list, so no CPP region in `HostToolSpec`
  carries a `testCase`, `testGroup`, or `TestTree` token.
- The family sits under a named `testGroup` and is declared in `CoverageManifest` with its
  host-independent size, so a case that vanishes on one host fails the count.

#### Validation

Closure requires, under `cabal test all` from `core/`: both cases running on the gate host and the
`CoverageManifest` row for the family whose declared size equals the counted leaves. The family size is the
same on a Windows and a POSIX gate host.

Dated closing evidence, 2026-10-26: Both System32 resolution cases exist on both hosts: Linux records two actual unavailable answers and Windows records two native path answers. The manifest observes each selected callback; the five POSIX effect cases are similarly retained and counted.
The declared Linux CPU core gate passed 2,633/2,633 in 234.60 seconds. Native Windows core passed
2,626/2,626 in 442.17 seconds; the demo leg passed 164/164 in 5.80 seconds and its included core
2,626/2,626 in 430.02 seconds. Python check_code and the complete 376-case suite passed, with 100%
line and branch coverage. The closing phase evidence below records the commands and gate hosts.

#### Remaining Work

None.

## Remaining Work

None.

## Closing validation

The 2026-10-26 Linux CPU gate ran in `hostbootstrap-core-gate-20261026`, an x86_64 Ubuntu 24.04.4
container with no GPU devices or markers; the unmodified detector reports `linux-cpu/amd64`.
The source mirror was verified byte-for-byte against all 987 current working-tree files. The container
uses the published CPU base digest
`sha256:64ccb7f28c96c8c4810bae44719118bf49fbed4700f93919d4d5b06cb22a36d8`, GHC 9.12.4 and
Cabal 3.16.1.0 on WSL2 Linux 6.18.33.2. `cabal test all --test-options=--hide-successes` passed all
2,633 core cases in 234.60 seconds. The output flag changes reporting only.

The native host is `DESKTOP-R6BTBVS`, x86_64 Windows 11 10.0.26300.9457, GHC 9.12.4 and
Cabal 3.16.1.0. The full host static gate passed: core 2,626 in 442.17 seconds; demo 164 in 5.80
seconds plus its included core 2,626 in 430.02 seconds; Python check_code passed and test_all passed
376 in 6.38 seconds, covering all 1,585 statements and 460 branches. Plain `cabal build all` also
passed in core and demo. Cabal ran with a UTF-8 console; no case was filtered out of these full runs.
The existing LiftSpec/LifecycleSpec platform case differences belong to their later owning phases;
this phase's Windows-resolution and POSIX-process families have the same sizes on both hosts.

All 19 declared conditional families matched their observed completions: Linux 52 row/16 refusal,
Windows 33 row/35 refusal. The opt-in provider-live and direct-Colima lanes reported their explicit
unrequested results; this phase claims no provider/Apple acceptance from those messages.

The initial Linux full run failed six expectations (two escape diagnostics, the abstract field
diagnostic, pre-parser ordering, unrelated CLI attribution, and a malformed plan update); these were
corrected before the closing run. The initial native core failed 71/2,625, chiefly because the new byte
capture exposed CRLF from test protocol producers. FakeCluster and FakeProvider now emit explicit
UTF-8/LF, preserving the production protocol refusals; the affected 271-case native selection passed
before the complete reruns. Winget's valid native AppExecutionAlias is verified by actual execution.
The plan update's heading-selection error was repaired with all eleven sprint sections restored.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — the closed `HostTool`/`AbsExe` boundary and the separate
  invocation-shape boundary.
- `documents/architecture/build_and_run_model.md` — the closed substrate set and the evidence each branch reads.
- `documents/architecture/durable_state.md` — the canonical project root and its durable projections.

**Engineering docs to create/update:**
- `documents/engineering/durable_windows_runs.md` — the surface this phase changes in it.
- `documents/engineering/prerequisites.md` — the host floor per substrate.
- `documents/engineering/testing.md` — what the static suites do and do not cover for host invocation.

**Cross-references to add:**
- `development_plan_standards.md` § K and § HH name this phase as the owner of the two axes.
