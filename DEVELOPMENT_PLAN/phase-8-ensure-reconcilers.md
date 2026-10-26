# Phase 8 — Ensure reconcilers

**Status**: Active
**Depends on**: Phase 7 (Dhall configuration and the generic project model)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-12 ; x86_64 Ubuntu 24.04.4 LTS, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` ; pass ; covers in-gate

> **Purpose**: Bring each host dependency to a declared state idempotently, with substrate applicability
> decided by the classified substrate rather than attempted and caught, and supply the generic resolved-tool
> self-reference Lift that crosses already-described frame contexts.

## Phase Objective

Once the binary exists it can install what it needs. Each `ensure` reconciler answers one question — is this
dependency present at the required version, and if not, install it — and answers it idempotently, so a second
run is a no-op rather than a reinstall. Applicability is derived from the classified substrate, so a
reconciler that cannot apply reports that rather than failing.

The accelerator and host-realization reconcilers beyond universal `linux-cpu` are written here; their live confirmation belongs to
the substrate phases (§ II), because a run on one substrate proves nothing about another.

Above Phase 7's pure target/context vocabulary, this phase resolves the one outer host tool and folds a
self-reference command through any nested stack. That fold in `HostBootstrap.Lift` is the single renderer
of a frame crossing (§ LL), and this phase owns it; the provider rows it crosses, provider lifecycle
realization, and registry-aware leaf extensions are later additive consumers that derive from it.

## Sprints

### Sprint 8.1: The reconciler contract [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`

#### Objective

One shape every reconciler has.

#### Deliverables

- A reconciler is a host-applicability predicate plus a `HostConfig -> IO ()` reconcile action. The pure
  `decide` function returns either the exact wrong-host diagnostic or the action to run; it does not mint a
  typed reconcile result.
- Reconcile actions are probe-first. A satisfied probe takes the successful no-op path; an absent dependency
  with a supported plan is installed and re-probed; an unsupported or still-unsatisfied state fails closed.
- The executable every reconciler step launches resolves through the closed `HostTool` boundary
  (`runTool` → `interpretHostCommand`), so no step is launched by a bare `$PATH` name. A program named
  inside a `Sudo` argument vector (`apt-get`, `systemctl`, `usermod`, `setfacl`, `nvidia-ctk`) is resolved
  by `sudo` itself, and the apple-metal smoke probe runs the artifact it just compiled by its absolute
  scratch-directory path.
- `runReconciler` emits the one-line wrong-host diagnostic to `stderr` and exits nonzero before calling the
  action. Successful actions currently report through ordinary `IO ()`; typed retained outcomes belong to the
  later plan-owned reconcile boundary.

#### Validation

`EnsureSpec` covers pure applicability/diagnostic selection and the applicable action path. Deterministic
install/re-probe/no-op coverage is owned by Sprint 8.2.

#### Remaining Work

None.

### Sprint 8.2: The baseline reconcilers [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Ghc.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Incus.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Homebrew.hs`,
`core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`, `documents/engineering/incus.md`

#### Objective

Cover the dependencies the baseline lane needs, and give the shared install driver one total answer to
what each install step's outcome means.

#### Deliverables

- `ensure docker` brings a reachable Docker daemon with `buildx` to every frame (installed on Linux,
  probed and delegated on apple-silicon and Windows). `ensure incus` brings the Incus host provider to a
  usable state on apple-silicon and Linux; its Linux convergence is completed by Sprint 8.11.
- `ensure ghc` installs `ghcup` and ghcup's recommended GHC on apple-silicon and sets it as the default
  `ghc`. It does not pin a version: the pinned guest toolchain is Sprint 8.6's `PinnedToolchain`, and the
  outer-host compiler pin is the Python bootstrapper's (§ N). The verify probe finds the GHC the plan just
  installed, because `HostTool` resolution searches ghcup's install directory as well as `$PATH`.
- `ensure homebrew` covers the macOS package prerequisite without selecting or mutating a project provider
  profile. Homebrew is a host minimum the Python bootstrapper asserts and never installs, so an absent `brew`
  fails with the instruction to install it from brew.sh, and the module header and the `ProvidedElsewhere`
  text say exactly that.
- `installAndVerifyWith` reads each step's outcome through one pure, total classifier: continue, already
  installed (winget's "already installed" and "no available upgrade" answers), reboot required (WSL text
  matched after `normalizeWslText` strips UTF-16 NUL padding, or the `wsl --install` exit `-1`), or failed.
- Every member remains config-free. A provider adapter that needs validated project, plan, budget, partition,
  reservation, or profile evidence is not a `Reconciler` and cannot appear in this phase's registry.

#### Validation

`EnsureSpec` covers each reconciler's pure plan and applicability branches. A deterministic seam around the
production `installAndVerify` driver covers already-present no-op, absent → install → successful re-probe,
second-run no-op, install refusal, install failure, and failed re-probe without invoking a real package
manager. The focused `EnsureSpec`/`LiftSpec`/`CordonSpec` gate passed 128/128 with `-Werror` on 2026-08-09
(aarch64-osx, GHC 9.12.4). The [worked-demo phase](phase-24-worked-demo.md)
exercises the baseline reconcilers in the live lifecycle; that later integration evidence is not a closure
obligation of this static phase.

The sprint closes when these cases also exist in `EnsureSpec` and pass under the phase gate
(`cabal test all` from `core/`): every branch of the step-outcome classifier, including the UTF-16-padded
WSL reboot text and a non-WSL tool printing "reboot"; the ghcup install-directory candidates for a set and
an unset `GHCUP_INSTALL_BASE_PREFIX`; and the delegation instruction of each `ProvidedElsewhere` row.

#### Remaining Work

- `Ensure.hs`: lift `installAndVerifyWith`'s step handling into an exported pure
  `classifyStepOutcome :: HostTool -> [String] -> Either String (ExitCode, String, String) -> StepOutcome`
  with constructors `StepContinue`, `StepAlreadyInstalled`, `StepRebootRequired`, and `StepFailed String`,
  and drive `runStep` from it. Move `normalizeWslText` into `Ensure.hs` (re-exported by `Ensure.Wsl2`) and
  match the WSL reboot text on `normalizeWslText (out ++ errOut)` in both the success and failure branches.
  Test in `EnsureSpec`: winget non-zero with "Found an existing package already installed" and with "No
  available upgrade found" → `StepAlreadyInstalled`; winget non-zero with other text → `StepFailed`;
  `Wsl` exit 0 with UTF-16-padded "changes will not be effective until the system is rebooted" →
  `StepRebootRequired`; `Wsl ["--install", "--no-distribution"]` exit `-1` → `StepRebootRequired`; the
  same reboot text from `Brew` → `StepContinue`; a runner `Left` → `StepFailed` carrying its text. Add an
  `installAndVerifyWith` case whose runner answers winget "already installed" and assert the event log
  shows the refresh and the passing re-probe.
- `HostTool.hs` and `Ensure/Ghc.hs`: give `Ghc` and `Ghcup` a POSIX `discoverFallback` that checks
  `$GHCUP_INSTALL_BASE_PREFIX/.ghcup/bin`, defaulting to `$HOME/.ghcup/bin`, computed by a pure
  `ghcupBinCandidates :: [(String, String)] -> [FilePath]`; change the second step to
  `InstallStep Ghcup ["install", "ghc", "--set", "recommended"]`. Test the candidates for both environments
  and update the `ghc` plan case to the new argv.
- `Ensure/Homebrew.hs`: reword the module header and the `ProvidedElsewhere` text, which say the Python
  bootstrapper installs Homebrew pre-binary, to state that the bootstrapper asserts Homebrew as a host
  minimum (`hostbootstrap/prereqs.py` `_check_homebrew`) and that the operator installs it from brew.sh.
- `EnsureSpec`: assert the delegation text, not only `isLeft`, for Docker's apple row (names Colima),
  Docker's Windows row (names the WSL2 host-provider path), and Homebrew's refusal (names brew.sh and does
  not say the bootstrapper installs it).

### Sprint 8.3: Accelerator and outer-host provider reconcilers [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/AppleMetal.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Cuda.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/CudaWin.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Lima.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Wsl2.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/lima.md`, `documents/engineering/wsl2.md`,
`documents/engineering/accelerator_daemon.md`

#### Objective

Write each non-baseline reconciler here; confirm it on its own substrate later.

#### Deliverables

- `ensure apple-metal` reconciles the Swift/Metal toolchain. `ensure cudawin` reconciles the Windows CUDA
  build stack (CUDA Toolkit, MSVC build tools, LLVM). `ensure cuda` reconciles the Linux GPU container
  runtime: with the host driver as a precondition, it installs `nvidia-container-toolkit`, registers the
  NVIDIA runtime as Docker's default with CDI, enables volume-mount device injection, and restarts Docker.
  It installs no CUDA compiler; `nvcc` on linux-gpu comes from the published CUDA base image (§ L).
- `ensure lima` and `ensure wsl2` reconcile the Apple and Windows host providers; Sprint 8.10 owns WSL2
  readiness and install ordering.
- Each declares its applicable substrates, so invoking it on a substrate it does not apply to is a reported
  `not applicable` rather than an attempted install.
- The accelerator matrix is one table: Swift/Metal on apple-silicon, `nvcc` on linux-gpu and windows-gpu, and
  `clang++` on linux-cpu.
- `withProbeDir` gives each accelerator smoke probe a scratch directory unique to that probe run, removes
  it on every exit including an interrupt, maps only synchronous exceptions from setup or the probe to a
  failed probe, and lets asynchronous exceptions (`UserInterrupt`, `ThreadKilled`, timeouts) propagate.
- Each reconciler's module header states what its probe proves: the `nvkind` smoke proves the NVIDIA
  runtime is Docker's default and volume-mount injection is effective, and claims nothing about CDI.

#### Validation

`EnsureSpec` covers each reconciler's applicability decision and pure install plan; the argv builders
of the apple-metal probe (`macosSdkArgs`, `systemProfilerMetalArgs`, `swiftMetalCompileArgs`) and that its
probe source calls `MTLCreateSystemDefaultDevice`; both branches of `reportedGpu`; and the WSL diagnostic
classifiers. The IO observations (`visibleMetalDevice`, the CUDA smoke compile, `wsl2Ready`) are not
exercised by the static suite. Live confirmation on apple-silicon, nvidia, and windows is listed by the
corresponding substrate phase.

The sprint closes when `EnsureSpec` also carries the `withProbeDir` cases below and they pass under the
phase gate (`cabal test all` from `core/`).

#### Remaining Work

- `Ensure.hs` `withProbeDir`: create the directory with `withSystemTempDirectory` from the `temporary`
  package the library already depends on (a unique name per run, the fixed name kept only as the template
  prefix), so setup, the action, and removal sit inside one bracket, and catch only synchronous exceptions
  (`tryAny` from the `safe-exceptions` dependency, or a `tryJust` that rethrows `SomeAsyncException`).
  Test in `EnsureSpec`: an action that throws an `IOError` yields `False` and leaves no directory; an
  action that throws `UserInterrupt` rethrows it and still leaves no directory; two nested calls with the
  same name receive distinct directories.
- `Ensure/Cuda.hs`: reword the `satisfied` Haddock to the two facts the `nvkind` smoke proves (default
  NVIDIA runtime, effective volume-mount injection) and drop the CDI claim.
- Live confirmation is not a closure obligation of this phase (§ C, § II).

### Sprint 8.4: Generic resolved-tool self-reference Lift [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Wsl2.hs`,
`core/hostbootstrap-core/test/LiftSpec.hs`, `core/hostbootstrap-core/test/EnsureSpec.hs`,
`core/hostbootstrap-core/test/CoverageManifest.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`,
`documents/architecture/composition_methodology.md`,
`documents/architecture/build_and_run_model.md`

#### Objective

Fold one self-reference command through the pure context stack while resolving only the outer host tool and
keeping provider realization and registry policy above the generic dispatcher.

#### Deliverables

- `HostBootstrap.Lift` publicly reexports `HostBootstrap.Lift.Context` and owns `SelfRef`, `LiftDispatch`,
  `LiftLeaf`, `foldLeaf`, `foldLift`, and the effectful self-subcommand entrypoints.
- The fold preserves outermost-first nesting, streams child config over `stdin`, lowers container delivery,
  and resolves only the outer host command through `HostConfig`/`HostTool`; target-internal tools remain the
  nested machine's own commands.
- At the local frame only this binary (`SelfSub`, through `SelfRef`'s local path) and an admitted lifecycle
  binary (`LifecycleProcessCmd`) are launched as a `SelfTarget`. A raw leaf at the local frame names a
  `HostTool` and launches as a `ToolTarget`, or is refused with a typed `Left` naming the executable; it is
  never launched by `$PATH` lookup under a `SelfTarget`.
- A raw leaf in a container layer is passed to the image `ENTRYPOINT` (the binary) as its arguments, and the
  `LiftLeaf` Haddock says so rather than describing it as a command run as-is.
- `shellQuoteArgs` is the single generic quoting implementation available to later additive leaf helpers.
- `Ensure.Wsl2` owns its prerequisite diagnostics, output normalization, virtualization classification, and
  `bcdedit` argument rendering without importing the later WSL2 provider realization.
- Generic Lift imports no Incus, Lima, WSL2, `Substrate.Provider`, Registry, or cluster realization module.
- Reachability, blob-upload, and registry-auth leaf helpers are not part of this sprint; the
  composition-and-network phase adds them over this lower fold.

#### Validation

`LiftSpec` covers local, Incus, Lima, WSL2, container, and nested folds; generic raw-command and self-command
equivalence; streamed config delivery; effect dispatch; and adversarial shell quoting. `EnsureSpec` covers
WSL diagnostic classification on matching text only, UTF-16-shaped output normalization, and `bcdedit`
arguments. The shared
decorated/multiline-aware source guard enforces the exact dependency boundary and that `Ensure.Wsl2` does
not import the provider realization. The focused `EnsureSpec`/`LiftSpec`/`CordonSpec` gate passed 128/128
with `-Werror` on 2026-08-09 (aarch64-osx, GHC 9.12.4).

Dated evidence for the phase gate: `cabal test all --ghc-options=-Werror` from `core/` passed 1478/1478 on
2026-08-09 (aarch64-osx, GHC 9.12.4).

The sprint closes when `LiftSpec` also carries the cases below, with the same case count on Windows as on
POSIX hosts (or a declared `Unsupported` row for each case a Windows host cannot run), no CPP region in
`LiftSpec` holding a `testCase`, `testGroup`, or `TestTree` token, and `CoverageManifest` rows for the
"shared shell quoting boundary" and "local effect seam" families whose declared sizes equal the counted
leaves; `EnsureSpec` carries the negative WSL diagnostic cases below; and they pass under the phase gate
(`cabal test all` from `core/`).

#### Remaining Work

- `Lift.hs` and `HostTool.hs`: stop rendering a local `RawCmd` as `selfCommand exe args`. Add `Curl` to
  `HostTool` (the worked demo's local reachability and blob probes are local `curl` leaves), give
  `LiftDispatch` a local raw case that `foldLeafCommand` turns into a `ToolTarget` when the executable is a
  `HostTool`'s `toolCommandName`, and into a typed refusal otherwise, surfaced as `Left` by
  `liftLeaf`/`liftLeafWithStdin`. Test in `LiftSpec`: `foldLeafCommand localContext (SelfSub self sub)`
  targets `SelfTarget` at the local self path; a local `reachLeaf url` targets `ToolTarget Curl`; a local
  `RawCmd "no-such-tool" []` is refused, and `liftLeaf` returns `Left` without launching anything.
- `Lift.hs`: reword the `LiftLeaf` Haddock to state that a `RawCmd` in a container layer is passed to the
  image `ENTRYPOINT` as its arguments, and add a `LiftSpec` case pinning
  `foldLeaf (inContainer c localContext) (RawCmd "x" ["y"])` to the `docker run … <image> x y` argv.
- `LiftSpec`: pin the single-frame lifecycle channel by value with a non-empty binary —
  `foldLeaf (inVM vm localContext) (lifecycleProcessLeaf "/usr/local/bin/hostbootstrap-demo" ["--hostbootstrap-lifecycle-child"])`
  equals `DispatchTool Incus ["exec", <vm>, "--cwd", "/", "-T", "--", "/usr/local/bin/hostbootstrap-demo", "--hostbootstrap-lifecycle-child"]`,
  and the Lima frame (`shell --workdir / <vm> -- sudo -n -H <binary> …`) likewise. The WSL2 frame's pin
  is Sprint 8.16's, because that sprint changes its rendering.
- `EnsureSpec` `wslPrerequisiteCases`: add negative cases for both `Ensure.Wsl2` diagnostic predicates, so
  a `const True` mutation fails the suite. `wslReportsVirtualizationDisabled` and
  `wslReportsNoInstalledDistributions` each answer `False` for ordinary `wsl --status` output
  (`(ExitSuccess, "Default Distribution: Ubuntu-24.04\nDefault Version: 2", "")`, plain and `utf16ish`),
  for `(ExitSuccess, "", "")`, and for the other predicate's diagnostic text:
  `wslReportsVirtualizationDisabled` on "Windows Subsystem for Linux has no installed distributions." and
  `wslReportsNoInstalledDistributions` on "WSL2 is unable to start since virtualization is not enabled".
- `LiftSpec`: assert `liftStdin` selects the innermost layer on nested contexts —
  `liftStdin (inContainer deliveringContainer (inVM vm localContext))` equals the payload, and the same for
  the Lima and WSL2 nestings.
- `LiftSpec`: keep "local exec failure is returned structurally" unconditional, and give the local
  stdout and with-stdin cases a host-native subject on Windows (the test executable through a probe argv,
  as `Spec.hs` does for other effect cases), so the Windows gate runs the local `liftLeaf`,
  `liftSubcommand`, and `liftLeafWithStdin` path. A case that still cannot run on Windows is a declared
  `Unsupported` row, not a CPP removal.
- `LiftSpec`: rewrite `shellQuoteCases` and `effectCases` without `#ifdef`/`#ifndef`, branching on a `Bool`
  predicate defined outside any test list. The POSIX shell round-trip case runs its body where `/bin/sh` is
  a host executable and otherwise asserts the exact `Left` the same `runSelf` call returns on that host; the
  Windows-only outer-provider dispatch case and its POSIX twin are one case. Declare both families in
  `CoverageManifest` with their host-independent sizes, row-case counts, and reasons.

### Sprint 8.5: Reconcilers as frame rows [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Incus.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Wsl2.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon/Foundation.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`, `core/hostbootstrap-core/test/SubstrateSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`

#### Objective

Make a reconciler a row over one closed frame table (§ LL), so which hosts it applies to, how those hosts
are described, and what it installs on each are three views of one value.

#### Deliverables

- `HostFrame` is the closed three-constructor frame axis, and `substrateFrame` is the one place the five
  classification tags collapse onto it. `isLinux`, `isWindows`, and `isAppleSilicon` are derived from that
  single fact rather than each spelling its own constructor pair.
- The accelerator is a capability *of* a frame rather than a frame of its own: a row that needs one says so
  with `rowRequiresNvidia`, and `frameTable` orders accelerator rows first so a table carrying both selects
  the specific one.
- `Reconciler` carries a `FrameTable`. `appliesTo`, `requirement`, and `reconcilerInstallSteps` are derived
  from it, so a reconciler that claims a host its own plan refuses is unrepresentable.
- A frame another frame owns is an **absent row**: `ensure incus` has apple and linux rows and no Windows
  row at all, because the WSL2 frame owns the Windows host provider and a second refusal is a second answer
  to one question.
- `ProvidedElsewhere` is the row that applies — the dependency is probed in this frame — but delegates the
  install, so "Docker on apple-silicon comes from Colima" is a row rather than a refusal.
- `capacityReadPlan` routes on the frame, so a new classification tag cannot silently miss a case that reads
  as exhaustive. The host minimums are the Python bootstrapper's pre-binary floor (§ N), not a reconciler
  row.

#### Validation

`EnsureSpec`'s frame-table group asserts the agreement itself on every reconciler and every host: an
applicable host has a plan, an inapplicable one gets exactly the diagnostic `decide` returns, and the
requirement each diagnostic quotes is the rows' own rendering. The absent-row case covers delegation of the
Windows host provider to the WSL2 frame. The frame collapse over all five classification tags is pinned
indirectly by that applicability matrix; `SubstrateSpec` asserts `isAppleSilicon`, `isLinux`, and `hasGpu`
on the apple-silicon, linux-gpu, and windows-gpu tags.

The sprint closes when `EnsureSpec` also carries the accelerator-ordering case below and `SubstrateSpec`
the direct frame-collapse case, and both pass under the phase gate (`cabal test all` from `core/`).

#### Remaining Work

- `EnsureSpec`: build a table from the exported constructors with the general row written first —
  `frameTable [linuxRow (InstallHere a), linuxGpuRow (InstallHere b)]` for distinct step lists `a` and `b` —
  and assert that the derived install plan is `b` on linux-gpu and `a` on linux-cpu, and that the
  table's requirement rendering is the expected text. This replaces the body of "an accelerator row is
  selected ahead of its frame's general row", which today asserts only `cuda`'s applicability and passes
  with the reordering in `frameTable` removed.
- `SubstrateSpec`: assert `substrateFrame` over all five classification tags and `isWindows` on each, so
  the collapse and every derived predicate are pinned directly.

### Sprint 8.6: The guest bootstrap vocabulary [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/GuestBootstrap.hs`,
`core/hostbootstrap-core/test/GuestBootstrapSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/build_and_run_model.md`

#### Objective

Own the one residue § KK names: the closed, ordered set of steps that establishes the binary inside a fresh
frame, before any of the binary's own typed operations can run there.

#### Deliverables

- `HostBootstrap.Ensure.GuestBootstrap` is the sole owner. `GuestPackage` is the closed guest floor,
  `PinnedToolchain` the pinned GHC, and `GuestBootstrapStep` the five steps — floor, toolchain, Python
  bootstrapper, host-native build, install — each separate because each is separately probeable.
- `guestBootstrapPlan` is generated from a closed, `Enum`/`Bounded` step-kind axis through a function with no
  wildcard pattern, so a step constructor the plan omits is a non-exhaustive-patterns error under `-Werror`;
  the plan fixes the order, so a caller selects the target and never the sequence.
- Every step renders to argument vectors, and `stepActions` is a list precisely so the two shapes that
  reach for an interpreter do not need one — a piped installer is a fetch step followed by a run step, and
  a working directory is an argument to `env`. A probe answers from the step's own observation: the
  package floor counts as installed only when `dpkg` reports every package in the installed state (`ii`),
  so a removed-with-config or half-configured package is absent.
- The bootstrapper step reinstalls from the staged source on every bootstrap (`pipx install --force`)
  and is verified afterwards, so a frame that is bootstrapped again builds with the bootstrapper it was
  just handed rather than an earlier one.
- `mkGuestBootstrapTarget` admits POSIX-absolute guest paths alone (§ MM), so a drive-qualified outer-host
  path cannot reach a Linux guest process as a relative path, and admits a toolchain home only when its
  last component is `.ghcup`, the directory the ghcup installer creates under
  `GHCUP_INSTALL_BASE_PREFIX`.
- `runGuestBootstrapWith` is the probe-first driver — probe, act on absence, re-probe, stop at the first step
  that will not settle — the control flow `installAndVerify` holds for a host reconciler (§ L), over a frame.
- The pinned-toolchain probe requires the installer, the exact versioned GHC executable, and Cabal together;
  an interrupted installer therefore remains absent and the same step resumes instead of admitting a partial
  toolchain to the host-native build.
- Every leaf folds through `HostBootstrap.Lift`, so the crossing into the frame is the one fold's (§ LL) and
  this module renders none of it.

#### Validation

`GuestBootstrapSpec` covers the target's guest-path admission and its three refusals; the plan's order and
floor; that no rendering hands a program to an interpreter and no argument carries a Windows separator;
the exact probe argv of every step; and the driver's four control-flow outcomes against an injected leaf
runner — satisfied frame, empty frame, failed action, and a step that never settles.

The sprint closes when the cases named in Remaining Work exist in `GuestBootstrapSpec` and pass under the
phase gate (`cabal test all` from `core/`).

Dated evidence for the phase gate: on 2026-08-17, Windows 11 Home 10.0.26200 x86_64 with GHC 9.12.4 and
Cabal 3.16.1.0 passed `cabal test all --ghc-options=-Werror` from `core/` host-native at 1,922/1,922 in
234.62 seconds, together with `poetry run python -m hostbootstrap.check_code` and
`poetry run python -m hostbootstrap.test_all` at 231 passed. That run is evidence for the one gate host that
produced it (§ II); confirming the same gate on the remaining gate host families belongs to the
[host-portability acceptance phase](phase-29-host-portability-acceptance.md).

On 2026-09-01, after tightening the interrupted-toolchain probe, the Windows host-static gate passed again:
`cabal test all --ghc-options=-Werror` reported 2,477/2,477 in 725.28 seconds,
`poetry run python -m hostbootstrap.check_code` passed, and
`poetry run python -m hostbootstrap.test_all` reported 231/231.

#### Remaining Work

- `GuestBootstrap.hs`: add `data GuestStepKind = FloorStep | ToolchainStep | BootstrapperStep | BuildStep
  | InstallBinaryStep deriving (Eq, Show, Enum, Bounded)`, a wildcard-free `stepFor :: GuestBootstrapTarget ->
  GuestStepKind -> GuestBootstrapStep`, and `stepKind :: GuestBootstrapStep -> GuestStepKind`; define
  `guestBootstrapPlan target = map (stepFor target) [minBound .. maxBound]` and correct the module header
  and `guestBootstrapPlan` Haddock to name this mechanism. Test: `map stepKind (guestBootstrapPlan target)`
  equals `[minBound .. maxBound]`.
- `GuestBootstrap.hs`: give the floor step an output-reading probe — `dpkg-query -W -f '${db:Status-Abbrev}\n'`
  over the floor packages, satisfied only when the run exits 0 and every line begins `ii` — with the
  classification a pure exported function. Test it with all-`ii`, one `rc`, one `iU`, and a non-zero exit
  for an unknown package, and assert a driver run whose fake answers `rc` runs the floor actions.
- `GuestBootstrap.hs`: make the bootstrapper step act unconditionally — the driver runs
  `pipx install --force <source>` without consulting a skip probe and then verifies `test -x <bootstrapper>`,
  reporting `GuestStepInstalled`. Test: on an otherwise satisfied frame the journal contains the `pipx`
  action and its verification.
- `GuestBootstrap.hs`: `mkGuestBootstrapTarget` refuses a toolchain home whose normalised last component is
  not `.ghcup`. Test the refusals for `/opt/ghcup` and `/root/.ghcup/`, and assert the run argv carries
  `GHCUP_INSTALL_BASE_PREFIX=` the parent of the toolchain home.
- `GuestBootstrapSpec`: replace the distinctness check with `length (nub names) @?= length names` and pin
  the floor's package names as a literal list; pin the package-install argv exactly (including `-y` and the
  package names), the bootstrapper action (`pipx install --force <source>`), and the binary install
  (`sudo -n install -m 0755 <built> <installed>`); in the toolchain case assert the path after `-o` in the
  fetch is the path after `sh` in the run, and the `--proto =https --tlsv1.2` arguments and URL.
- `GuestBootstrapSpec`: in the empty-frame driver case assert the full journal equals, for each step in
  plan order, its probe, its actions in order, then its re-probe, and make the scripted runner settle a
  probe only after that step's own actions have run since its last failure; in the runner-error cases
  assert the message carries the `guest bootstrap: ` prefix and the failing step's `stepLabel` for the
  first-probe and re-probe branches as well as the action branch.
- The worked-demo phase adopts this vocabulary at its own pristine-host call site; a live confirmation is
  not a closure obligation of this static phase (§ C, § II).

### Sprint 8.7: The raw leaf names its executable apart from its arguments [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`core/hostbootstrap-core/test/compile-fail/RepointSelfReference.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/library_hierarchy.md`

#### Objective

§ K makes a bare command name unrepresentable at host-tool resolution, and the lift's raw command leaf
holds the same line one layer up: it names an executable and its arguments separately, so the empty
argument vector has no spelling. The executable field is a plain `String`, so the leaf does not by itself
refuse an empty executable name; resolving a local raw leaf's executable through `HostTool`, which refuses
a name no tool carries, is Sprint 8.4's. Beside it, the self-reference value's two paths are distinct types with no
constructor or selector a consumer can reach.

#### Deliverables

- The raw command leaf is an executable and its arguments, so the equation that dispatched an empty executable has no reason to exist.
- Every caller that holds a list narrows it at its own boundary: the two that already answer with `Maybe` refuse the empty vector, and the one that does not takes the executable and the arguments apart.
- The self-reference value's two paths are distinct newtypes, so they cannot be transposed.
- Its constructor and its field accessors are both hidden — an exported accessor still admits record update, which is the half that matters — and one named reader answers the in-guest path.
- A compile-fail fixture pins that a caller cannot re-point a self-reference it was handed.

#### Validation

The phase gate (`cabal test all` from `core/`), plus the new fixture. The lift suite covers the dispatch
shapes. Dated evidence: on 2026-09-12, x86_64 Ubuntu 24.04.4 LTS with GHC 9.12.4 and Cabal 3.16.1.0, `cabal test all` from
`core/` passed 2,521 tests.

#### Remaining Work

None. The reconciler workflow and the accelerator probe are Sprints 8.8 and 8.9.

### Sprint 8.8: One group-and-socket reconciler workflow [Active]

**Status**: Active
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Incus.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`

#### Objective

One workflow puts the invoking non-root user in a daemon's group and grants that user immediate access
to the daemon's socket: read the environment, find the user, skip with a message when there is none,
add the user to the group, then grant. The two reconcilers that need it differ in a group, a socket,
and a label, and § LL makes those three arguments rather than a second copy. The refusal wording is
derived from the label and the step rather than spelled at each site. Adding a user to `docker` or
`incus-admin` is root-equivalent, so the exact privileged argv is pinned by test.

#### Deliverables

- `Ensure.hs`, which already owns the shared reconciler vocabulary, holds the group-and-socket workflow parameterised by group, socket, and label.
- Both reconcilers are applications of it, and each keeps only what is genuinely its own — Docker's future-login verification, its direct-access short circuit, and its ACL-tool install.
- The three-way answer to a privileged step — it succeeded, it ran and returned non-zero, or the tool could not be run — is written once and worded from the reconciler's label and the step's own description.
- The workflow has an injectable form taking the environment and the `Sudo` runner, the way `installAndVerifyWith` takes its effects, so its argv and its three answers are tested without a real `sudo`.
- A host with no invoking non-root user is a skip with a message on every path, including an effective uid with no passwd entry.

#### Validation

The phase gate (`cabal test all` from `core/`). Dated evidence: on 2026-09-12, x86_64 Ubuntu 24.04.4 LTS
with GHC 9.12.4 and Cabal 3.16.1.0, `cabal test all` from `core/` passed.

The sprint closes when the `EnsureSpec` cases named in Remaining Work exist and pass under the phase gate.

#### Remaining Work

- `Ensure.hs`: add `withInvokingGroupMemberWith`, taking the environment, the euid user lookup, and the
  `Sudo` runner, and define `withInvokingGroupMember`, `grantSocketAccess`, and `requireSudoStep` over it.
  Test in `EnsureSpec` with a recording runner: the exact argv `["usermod", "-aG", "docker", "matt"]`
  then `["setfacl", "-m", "u:matt:rw", "/var/run/docker.sock"]`; no runner call and the "(skipping)"
  message when no non-root user is found; a non-zero `usermod` exit dies with the label, the step
  description, and the exit code; a runner `Left` dies with the label and the runner's text.
- `Ensure.hs` `effectiveNonRootUser`: catch the synchronous `IOError` from `getUserEntryForID` and answer
  `Nothing`, so the documented skip path runs for an effective uid with no passwd entry.
- `EnsureSpec`: exercise the euid fallback of `invokingNonRootUser` with `[("USER", "root")]` — on POSIX
  the answer equals `Nothing` under euid 0 and otherwise the passwd name of `getEffectiveUserID`; on
  Windows the declared answer is `Nothing`.

### Sprint 8.9: One accelerator probe [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Cuda.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/CudaWin.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`

#### Objective

The question "does the accelerator tool report a device" has one answer. `Ensure.reportedGpu` is it,
and the two reconcilers, the cluster's runtime smoke, and substrate detection all ask through it or
through the marker it reads.

#### Deliverables

- The probe has one implementation, in the module that owns the shared reconciler vocabulary.
- The token a device listing prints is named once, in substrate detection, so detection and the probe agree by construction rather than by inspection.
- No duplicate body remains: the host-driver predicate, the `nvkind` runtime predicate, the Windows inline match, and the cluster's re-export are the one predicate.

#### Validation

The phase gate (`cabal test all` from `core/`). The ensure suite asserts the one predicate over a listing, an empty success, a
failed run, an unrunnable tool, and the shared marker itself. Dated evidence: on 2026-09-12, x86_64
Ubuntu 24.04.4 LTS with GHC 9.12.4 and Cabal 3.16.1.0, `cabal test all` from `core/` passed.

#### Remaining Work

None.

### Sprint 8.10: WSL2 readiness is a platform observation [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Wsl2.hs`,
`core/hostbootstrap-core/hostbootstrap-core.cabal`, `core/hostbootstrap-core/test/EnsureSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`, `documents/engineering/ensure_reconcilers.md`

#### Objective

`ensure wsl2` converges a bare Windows host to a WSL2 platform that can run a WSL2 distribution. Readiness
is what `wsl --status` reports about the platform, never the reachability of the online distribution
catalog. The next action is a pure decision over three observations — platform status, hypervisor
presence, and firmware virtualization — consulted in the order Windows reports them truthfully, and the two
machine facts come from a Win32 binding rather than PowerShell text (§ KK).

#### Deliverables

- `classifyWslStatus :: Either String (ExitCode, String, String) -> WslPlatformStatus` is pure over the
  captured `wsl --status`, read through `normalizeWslText`, and answers `WslPlatformReady`,
  `WslVirtualizationUnavailable`, or `WslPlatformAbsent`. Ready is an exit-0 status without
  virtualization-disabled text, or a "has no installed distributions" report without it; a non-zero status
  carrying virtualization-disabled text is `WslVirtualizationUnavailable`; every other non-zero status and a
  runner `Left` are `WslPlatformAbsent`. `wsl --list --online` is not consulted.
- `wslNextAction :: WslPlatformStatus -> Bool -> Bool -> WslAction` (status, hypervisor present, firmware
  virtualization enabled) is total. Ready sets the default version. Not ready with a hypervisor present runs
  the install plan. No hypervisor, firmware enabled, and platform absent runs the install plan, which
  enables the Virtual Machine Platform. No hypervisor, firmware enabled, and virtualization unavailable runs
  `bcdedit /set hypervisorlaunchtype auto` and then asks for a reboot. No hypervisor and firmware disabled is
  the BIOS/UEFI refusal. Firmware virtualization decides nothing while a hypervisor runs.
- The ready path runs `wsl --set-default-version 2` (idempotent), so a host whose default is WSL1 converges
  and the provider distribution is created as WSL2.
- Hypervisor presence (CPUID leaf 1, ECX bit 31, read in a C stub listed under the library's `c-sources`)
  and firmware virtualization (`IsProcessorFeaturePresent(PF_VIRT_FIRMWARE_ENABLED)`) are a Windows-only FFI
  binding behind `#ifdef mingw32_HOST_OS`; `Ensure.Wsl2` passes no `-Command` text.

#### Validation

The `EnsureSpec` cases below exist and pass under the phase gate (`cabal test all` from `core/`).
`classifyWslStatus` over: exit 0 with "Default Version: 2"; exit 0 with virtualization-disabled text;
non-zero with UTF-16-padded "has no installed distributions"; non-zero with "WSL2 is unable to start since
virtualization is not enabled"; non-zero with other text; and `Left`. `wslNextAction` over every
combination of its three inputs, including that a present hypervisor with firmware reported disabled yields
the install plan, and that no hypervisor with the platform absent yields the install plan rather than
`bcdedit`. Live convergence on a bare Windows host is listed by the Windows/WSL2 substrate phase.

#### Remaining Work

- `Ensure/Wsl2.hs`: add `WslPlatformStatus`, `classifyWslStatus`, `WslAction`, and `wslNextAction`; drive
  `reconcileWsl2` and `wsl2Ready` from them; delete `wsl2OnlineListReady`. Add the `classifyWslStatus` and
  `wslNextAction` cases to `EnsureSpec`.
- `Ensure/Wsl2.hs` and `hostbootstrap-core.cabal`: add the Win32 binding for hypervisor presence and
  firmware virtualization, replace both `powershell -NoProfile -Command` probes with it, and delete
  `powerShellBoolArgs`, `parsePowerShellBool`, `runPowerShellBool`, and the `powerShellBoolArgs` assertion
  in `EnsureSpec`.
- `Ensure/Wsl2.hs`: run `wsl --set-default-version 2` on the ready path, and pin that the ready action is
  `InstallStep Wsl ["--set-default-version", "2"]` in an `EnsureSpec` case.
- With the PowerShell probes gone, `Ensure/Wsl2.hs` carries no interpreter token (`"powershell"`,
  `"-Command"`).

### Sprint 8.11: Linux Incus convergence acts only on what it observed [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Incus.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`, `documents/engineering/ensure_reconcilers.md`

#### Objective

The Linux Incus row observes the provider before it changes it — VM capability for the host's
architecture, daemon reachability, and image-source egress — and acts only on what is missing, so a usable
provider is a verified no-op that neither reinstalls packages nor restarts a daemon another project's
operations are using. Every observation and every action is an argument vector (§ KK), and the provider
capability is minted only by that observation.

#### Deliverables

- VM capability is a list of `Sudo` argument vectors — `test -x` on the QEMU binary, `test -f` on each
  firmware image, `test -x` on each of `virtiofsdCandidatePaths` — combined in Haskell (QEMU, any firmware
  image, any `virtiofsd` candidate or a resolved `virtiofsd`). Packages, QEMU binary, and firmware images
  follow the substrate's `Arch`: `qemu-system-x86`, `ovmf`, `/usr/bin/qemu-system-x86_64`, and
  `/usr/share/OVMF/OVMF_CODE.fd` or `OVMF_CODE_4M.fd` on `Amd64`; `qemu-system-arm`, `qemu-efi-aarch64`,
  `/usr/bin/qemu-system-aarch64`, and `/usr/share/AAVMF/AAVMF_CODE.fd` on `Arm64`.
- A pure `linuxIncusConvergence :: Arch -> LinuxIncusObservation -> [InstallStep]` decides the work:
  the VM-package install only when the capability observation fails, `incus admin init --minimal` only when
  the root daemon probe fails, and `systemctl restart incus` only when either of those ran.
- The `DOCKER-USER` forwarding rules are separate argument vectors — `iptables -nL DOCKER-USER` (an absent
  chain skips both rules), `iptables -C DOCKER-USER <dir> incusbr0 -j ACCEPT`, and `iptables -I …` only when
  the check fails — and the KVM module load tries `modprobe kvm_intel`, `modprobe kvm_amd`, and
  `modprobe kvm` as separate steps until `/dev/kvm` exists.
- `withIncusProviderCapability` takes the `HostConfig` and runs `probeIncusProviderStatus` itself, and the
  ready constructor of `IncusProviderStatus` is not exported (callers read a status through an exported
  eliminator), so no caller mints the capability from a status it constructed.
- The `grantKvmReadWrite` Haddock names `invokingNonRootUser`.

#### Validation

The `EnsureSpec` cases below and the compile-fail fixture exist and pass under the phase gate
(`cabal test all` from `core/`): the capability probe argv lists for `Amd64` and `Arm64` pinned exactly and
the per-architecture package list; `linuxIncusConvergence` returning `[]` for a fully usable observation,
the package install followed by the restart when capability fails, and init followed by the restart when the
daemon probe fails; the `iptables` and `modprobe` argument vectors; classifier precedence with two failures
at once; and every non-ready status refused by the capability gate.

#### Remaining Work

- `Ensure/Incus.hs`: replace `linuxVmCapabilityProbeScript` and its `sudo sh -c` call with
  `linuxVmCapabilityProbes :: Arch -> …` and the Haskell combination, and make the VM packages depend on
  `Arch`. Test both architectures' argv lists and package lists exactly; this replaces the case that counts
  `&&` tokens in the script.
- `Ensure/Incus.hs`: add `LinuxIncusObservation` and `linuxIncusConvergence`, and drive
  `reconcileLinuxIncus` from them so the unconditional `apt-get install` and `systemctl restart incus` run
  only when the plan contains them. Test the three plans named in Validation.
- `Ensure/Incus.hs`: replace the `bash -c` iptables script in `ensureBridgeForwarding` and the `sh -c`
  modprobe chain in `ensureKvmAccess` with the argument vectors above. Test the rendered argv sequence for
  both.
- `Ensure/Incus.hs`: change `withIncusProviderCapability` to run the probe itself, stop exporting
  `IncusProviderReady`, and register `core/hostbootstrap-core/test/compile-fail/ForgeIncusProviderCapability.hs`
  in `CompileFailSpec` with `rejectsWith` naming the out-of-scope constructor. In `EnsureSpec` add
  `classifyIncusProviderStatus True (failed "permission denied") (failed "qemu") (failed "x")` →
  `IncusPermissionDenied`, `classifyIncusProviderStatus True ok (failed "qemu") (failed "x")` →
  `IncusVMIncapable`, and a refusal for each of the six non-ready statuses.
- `Ensure/Incus.hs`: replace `targetIncusAdminUser` with `invokingNonRootUser` in the `grantKvmReadWrite`
  Haddock.
- With the `sh -c` capability probe, the `bash -c` forwarding script, and the `sh -c` modprobe chain
  replaced, `Ensure/Incus.hs` carries no interpreter token (`"sh"`, `"bash"`).

### Sprint 8.12: The CUDA repository and Docker group steps are argument vectors [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Cuda.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/accelerator_daemon.md`,
`documents/engineering/ensure_reconcilers.md`

#### Objective

The NVIDIA repository setup and Docker's group verification are steps the binary composes from argument
vectors, not shell programs run as root (§ KK). Each fetch fails closed, nothing is written under
`/etc/apt` or `/usr/share/keyrings` until both fetches have completed and been checked, and every argv is
pinned by test.

#### Deliverables

- The repository setup fetches the key and the list to a scratch directory with `curl -fsSL -o`, rewrites
  the list in Haskell with a pure `signedByListText` that refuses a body with no `deb ` line, then runs
  `gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg <key>` and
  `install -m 0644 <list> /etc/apt/sources.list.d/nvidia-container-toolkit.list` under `Sudo`. A failed
  fetch or a refused body leaves both destination files untouched.
- Docker's future-login check reads the user's groups with `id -nG <user>` and the socket's owning group
  and group-write bit in Haskell; no `sg … -c` command line is issued.
- The Linux docker row refreshes the package index (`apt-get update`) before `apt-get install`.

#### Validation

The `EnsureSpec` cases below exist and pass under the phase gate (`cabal test all` from `core/`): the
exact linux-gpu step sequence with no `/bin/sh`; `signedByListText` over NVIDIA's list line, an HTML error
body (refused), and an empty body (refused); the exact Docker Linux plan with `apt-get update` first; and
the group-check argv through Sprint 8.8's injectable runner.

#### Remaining Work

- `Ensure/Cuda.hs`: replace `repositorySetupScript` and its `/bin/sh -c` step with the scratch-directory
  fetches, `signedByListText`, and the two `Sudo` writes; update the `cuda` plan case in `EnsureSpec` and
  add the `signedByListText` cases.
- `Ensure/Docker.hs`: replace `sg docker -c "docker info >/dev/null"` in `verifyDockerGroup` with the
  `id -nG` membership read and the socket-group check; pin the argv in `EnsureSpec`.
- `Ensure/Docker.hs`: prepend `InstallStep Sudo ["apt-get", "update"]` to the Linux row and update the
  `docker` plan case.
- With `repositorySetupScript` and the `sg … -c` line gone, `Ensure/Cuda.hs` (`"/bin/sh"`) and
  `Ensure/Docker.hs` (`"sg"`) carry no interpreter token.

### Sprint 8.13: Guest bootstrap coordinates are role types [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/GuestBootstrap.hs`,
`core/hostbootstrap-core/test/GuestBootstrapSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`

#### Objective

The guest bootstrap target is a sealed value whose six path coordinates each have their own type (§ HH),
so a transposed argument is a type error and no consumer can re-point a field of a target
`mkGuestBootstrapTarget` admitted. A bootstrap step exists outside the module only as the plan renders it
from such a target.

#### Deliverables

- `GuestSourceRoot`, `GuestProjectDir`, `GuestToolchainHome`, `GuestBootstrapperExe`, `GuestBuiltBinary`,
  and `GuestInstalledBinary` are newtypes over one validated POSIX-absolute `GuestPath`, taken by
  `mkGuestBootstrapTarget` and carried by the step constructors.
- `GuestBootstrapTarget`'s record fields are not exported; the readers are plain functions, so record update
  outside the module does not compile.
- `GuestBootstrapStep` is exported as a type without its constructors, so a step reaches a caller only
  through `guestBootstrapPlan` over an admitted target; the fixed order and the POSIX-absolute rule (§ MM)
  hold for every step a caller can hold, and a caller reads a step through `stepKind`, `stepLabel`,
  `stepProbe`, and `stepActions`.
- Three registered compile-fail fixtures pin these properties.

#### Validation

`GuestBootstrapSpec` passes over the role types without importing a step constructor, and the three
compile-fail fixtures are registered in `CompileFailSpec` with the diagnostic each expects, under the phase
gate (`cabal test all` from `core/`).

#### Remaining Work

- `Ensure/GuestBootstrap.hs`: introduce `GuestPath` and the six role newtypes, change
  `mkGuestBootstrapTarget` and the step constructors to them, and export the readers as functions rather
  than record fields; update `GuestBootstrapSpec`.
- Add `core/hostbootstrap-core/test/compile-fail/RepointGuestBootstrapTarget.hs` (record update of a
  target's source root outside the module) and
  `core/hostbootstrap-core/test/compile-fail/TransposeGuestBinaryRoles.hs` (an installed-binary path passed
  where the built binary is expected), each registered with `rejectsWith` and its expected phrase.
- `Ensure/GuestBootstrap.hs`: export `GuestBootstrapStep` without `(..)`, and move `GuestBootstrapSpec` off
  the constructors onto `stepKind` and the plan. Add
  `core/hostbootstrap-core/test/compile-fail/ForgeGuestBootstrapStep.hs` (constructing
  `InstallGuestProjectBinary` outside the module), registered with `rejectsWith` naming the out-of-scope
  constructor.
- `Ensure/GuestBootstrap.hs`: align the module Haddock ("'guestBootstrapPlan' is total over the step
  constructors, so a step added here is a step every caller runs") and the `guestBootstrapPlan` Haddock
  ("adding a step to the vocabulary without adding it here is a non-exhaustive-patterns warning") with the
  code. `guestBootstrapPlan` is a list literal that matches on no constructor, so a new constructor warns
  only in `stepLabel`, `stepProbe`, and `stepActions`; the Haddocks say the plan fixes the order and that
  `GuestBootstrapSpec`'s "the five steps run in the one order the vocabulary declares" case pins that the
  plan names every step.

### Sprint 8.14: Container config delivery runs no shell [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`core/hostbootstrap-core/test/LiftSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

A delivering container receives its sibling configuration without an interpreter (§ KK): the image's
`ENTRYPOINT` stays the binary, the projection reaches the container's filesystem through `docker cp`, and
the fold renders only argument vectors.

#### Deliverables

- A delivering container is three described commands: `docker create` (with `--rm` when `clRemoveAfter`)
  of the image and folded subcommand, printing the container id; `docker cp - <id>:<directory of
  cdWritePath>` fed a single-entry ustar stream, built in Haskell, holding the projection under the write
  path's file name; and `docker start -a <id>`.
- `liftSubcommandWithStdin` keeps its signature and runs the three commands when the terminal container
  delivers config, so the recursive-handoff callers are unchanged.
- `configWriteScript` and the `--entrypoint sh` override are deleted; no container rendering carries an
  interpreter token.

#### Validation

The `LiftSpec` cases below exist and pass under the phase gate (`cabal test all` from `core/`): the exact
create, cp, and start argument vectors for a delivering container; the ustar stream's header name, size,
and payload bytes; and a non-delivering container still folding to one `docker run`.

#### Remaining Work

- `Lift.hs`: render config delivery as the create, cp, and start commands; add the pure ustar encoder;
  route `liftSubcommandWithStdin` through them; delete `configWriteScript` and its export. Replace the
  `LiftSpec` cases that pin the entrypoint override and `configWriteScript` quoting with the cases in
  Validation.
- With `configWriteScript` and the `--entrypoint sh` override gone, `Lift.hs` carries no interpreter token
  (`"sh"`).

### Sprint 8.15: A container layer is terminal by type [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`, `core/hostbootstrap-core/test/LiftSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

A container is the innermost layer of a lift context by construction (§ HH), so the fold, the `stdin` a
context wants, and the frame it lands in are three readings of one value that cannot disagree.

#### Deliverables

- `LiftContext` carries its VM layers and an optional terminal container as separate fields, and its
  constructor is not exported. `localContext`, `inVM`, `inLimaVM`, and `inWsl2VM` build a VM-only stack,
  and `inContainer` closes one, so a VM layer after a container does not type-check.
- `foldLeaf`, `liftStdin`, and `liftContextFrame` read the same terminal container.
- The raw `LiftContext [...]` constructions in other modules move onto these builders; the edits there are
  mechanical.

#### Validation

`LiftSpec` passes with the nested-context cases rebuilt on the builders, and a registered compile-fail
fixture rejects a VM layer after a container, under the phase gate (`cabal test all` from `core/`).

#### Remaining Work

- `Lift/Context.hs` and `Lift.hs`: split `LiftContext` into its VM stack and terminal container, hide the
  constructor, retype the builders, and derive `foldLeaf`, `liftStdin`, and `liftContextFrame` from the one
  field; move every raw `LiftContext [...]` construction in `src/` and `demo/` onto the builders.
- Add `core/hostbootstrap-core/test/compile-fail/VMLayerAfterContainer.hs`
  (`inVM vm (inContainer c localContext)`), registered with `rejectsWith` and its expected phrase.

### Sprint 8.16: The lifecycle crossing is a placement of the one VM renderer [Planned]

**Status**: Planned
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`, `core/hostbootstrap-core/test/LiftContextSpec.hs`,
`core/hostbootstrap-core/test/LiftSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

A VM crossing has one renderer per provider (§ LL), and the lifecycle channel is that renderer applied to
a different placement rather than a second hand-written argv. The placement — working directory,
non-interactive execution, and root elevation — is a value, so the command fold and the lifecycle channel
differ only in the placement they pass and cannot disagree about how a provider boundary is crossed. Every
WSL crossing delivers its argv through `--exec`, so no guest shell re-parses a lifecycle argument.

#### Deliverables

- `HostBootstrap.Lift.Context` exports `VMPlacement` (`placementWorkdir :: Maybe FilePath`,
  `placementNonInteractive :: Bool`, `placementElevated :: Bool`), `foldPlacement`
  (`VMPlacement Nothing False False`), and `lifecyclePlacement` (`VMPlacement (Just "/") True True`).
- `execVMArgsAt :: VMPlacement -> IncusVM -> [String] -> [String]` renders `exec <vm>`, then
  `--cwd <dir>` for a workdir, `-T` when non-interactive, `--`, and the argv; Incus `exec` already runs as
  root, so elevation adds nothing.
- `shellVMArgsAt :: VMPlacement -> LimaVM -> [String] -> [String]` renders `shell`, `--workdir <dir>` for
  a workdir, `<vm> --`, then `sudo`, `-n` when non-interactive, and `-H` when elevated, and the argv.
- `wslExecArgsAt :: VMPlacement -> String -> [String] -> [String]` renders `-d <distro>`, `--cd <dir>` for
  a workdir, `--exec`, then the same `sudo` prefix as Lima when elevated, and the argv.
- `execVMArgs`, `shellVMArgs`, and `wslExecArgs` are these renderers applied to the fold placement:
  `execVMArgs = execVMArgsAt foldPlacement`,
  `wslExecArgs = wslExecArgsAt foldPlacement`, and
  `shellVMArgs = shellVMArgsAt foldPlacement { placementElevated = True }`, because a Lima guest's default
  user is not root.
- `foldLeaf` chooses the placement once from the leaf (`lifecyclePlacement` for `LifecycleProcessCmd`,
  the fold placement otherwise) and folds every VM layer, outer and nested, through the one inner fold. The
  six hand-written lifecycle equations of `build` and the `insideLifecycleVM` helper do not exist, and
  `Lift.hs` carries no `"--cwd"`, `"--workdir"`, `"--cd"`, `"-T"`, or `"sudo"` literal.
- The `Lift.Context` module header states that the command fold and the lifecycle channel render every VM
  crossing through these renderers and differ only in the placement they pass.

#### Validation

The cases below exist and pass under the phase gate (`cabal test all` from `core/`).
`LiftContextSpec` pins each `…At` renderer's exact argv under `foldPlacement` and `lifecyclePlacement`,
and that `execVMArgs vm argv`, `shellVMArgs lima argv`, and `wslExecArgs d argv` equal
`["exec", <vm>, "--"] ++ argv`, `["shell", <vm>, "--", "sudo", "-H"] ++ argv`, and
`["-d", d, "--exec"] ++ argv`. `LiftSpec` pins
`foldLeaf (inWsl2VM w localContext) (lifecycleProcessLeaf "/usr/local/bin/hostbootstrap-demo" ["--hostbootstrap-lifecycle-child"])`
as `DispatchTool Wsl ["-d", <distro>, "--cd", "/", "--exec", "sudo", "-n", "-H", "/usr/local/bin/hostbootstrap-demo", "--hostbootstrap-lifecycle-child"]`;
the three composed lifecycle-channel cases with the WSL case carrying `--exec` in place of `--`; a nested
lifecycle leaf `inVM vm (inWsl2VM w localContext)` whose inner `incus exec <vm> --cwd / -T --` follows the
WSL `--exec sudo -n -H` prefix; and a lifecycle argument `"a&b;$c"` arriving as one unchanged argv
element on all three providers. A `SourceGuard` case asserts `Lift.hs` carries none of the placement
literals.

#### Remaining Work

- `Lift/Context.hs`: add `VMPlacement`, `foldPlacement`, `lifecyclePlacement`, and the three `…At`
  renderers; redefine `execVMArgs`, `shellVMArgs`, and `wslExecArgs` over them; rewrite the module header
  to the one-renderer boundary. Add the renderer cases to `LiftContextSpec`.
- `Lift.hs`: fold `LifecycleProcessCmd` through the `…At` renderers with `lifecyclePlacement`, delete the
  hand-written lifecycle equations and `insideLifecycleVM`, and update the `foldLeaf` Haddock. In
  `LiftSpec`, change the composed WSL lifecycle case from `--` to `--exec`, and add the single-frame WSL
  pin, the nested Incus-in-WSL case, the shell-metacharacter argument case, and the placement-literal
  source guard named in Validation.

## Remaining Work

- Sprint 8.2: classify install-step outcomes in one pure function (NUL-stripped WSL reboot text), make
  `ensure ghc` verify the GHC ghcup installs, correct the Homebrew refusal text, and pin the delegation
  texts.
- Sprint 8.3: make `withProbeDir` unique per run and interrupt-transparent, and correct the `nvkind`
  smoke's CDI claim.
- Sprint 8.4: resolve local raw leaves through `HostTool`, state the container raw-leaf semantics, pin
  the lifecycle-channel, nested `liftStdin`, and Windows effect-seam cases, keep every `LiftSpec` case on
  every gate host with `CoverageManifest` rows, and add negative cases for the two WSL diagnostic
  predicates.
- Sprint 8.5: make the accelerator-ordering case able to fail and pin the frame collapse directly.
- Sprint 8.6: generate the plan from a closed step-kind axis, read the floor's `dpkg` state, reinstall the
  bootstrapper every run, require a `.ghcup` toolchain home, and tighten `GuestBootstrapSpec`.
- Sprint 8.8: give the group-and-socket workflow an injectable form with argv and refusal tests, and make
  an unlisted euid a skip.
- Sprint 8.10: decide WSL2 readiness from `wsl --status` alone, order the hypervisor and firmware
  observations, install before `bcdedit`, and replace the PowerShell probes with a Win32 binding.
- Sprint 8.11: converge Linux Incus only on observed gaps, per architecture, with argv probes and a
  probe-minted capability.
- Sprint 8.12: express the NVIDIA repository setup and Docker group check as argument vectors and refresh
  apt before the Docker install.
- Sprint 8.13: give the guest bootstrap coordinates role types, seal the target's fields, and stop
  exporting the step constructors.
- Sprint 8.14: deliver container config through `docker cp` with no shell, leaving `Lift.hs` with no
  interpreter token.
- Sprint 8.15: make the container the terminal lift layer by type.
- Sprint 8.16: render the lifecycle crossing through the one per-provider VM renderer with a placement
  value, delivering WSL argv through `--cd / --exec`.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — where reconcilers sit between the host floor and the plan.
- `documents/architecture/hostbootstrap_core_library.md` — the generic Lift over the pure context vocabulary.
- `documents/architecture/composition_methodology.md` — resolved outer dispatch and nested command folding.

**Engineering docs to create/update:**
- `documents/engineering/ensure_reconcilers.md` — the reconciler contract and the applicability rule.
- `documents/engineering/incus.md`, `documents/engineering/lima.md`, `documents/engineering/wsl2.md` — the
  provider reconcilers.
- `documents/engineering/accelerator_daemon.md` — the per-substrate accelerator toolchain matrix.

**Cross-references to add:**
- `development_plan_standards.md` § L names this phase as the owner of the reconciler contract.
- `development_plan_standards.md` § U names this phase as the owner of the provider-neutral resolved-tool
  self-reference Lift.
- The [cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md) owns the
  plan-bound direct-Colima adapter because it consumes project-plan and admitted-wall evidence.
