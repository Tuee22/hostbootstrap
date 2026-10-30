# Phase 8 — Ensure reconcilers

**Status**: Done
**Depends on**: Phase 7 (Dhall configuration and the generic project model)
**Substrates**: linux-cpu
**Gate**: `cabal test all` from `core/`
**Gate kind**: self-verifying
**Gate evidence**: 2026-09-12 ; x86_64 Ubuntu 24.04.4 LTS, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` ; pass ; covers in-gate
**Gate evidence**: 2026-10-28 ; native Windows 11 x86_64, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` ; pass ; covers in-gate
**Gate evidence**: 2026-10-28 ; native-filesystem Ubuntu 24.04.4 x86_64 CPU container, GHC 9.12.4, Cabal 3.16.1.0 ; `cabal test all` ; pass ; covers in-gate

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

On 2026-10-28, the complete unfiltered core suite passed on native Windows 11 x86_64 (3,315 cases)
and the native-filesystem Ubuntu 24.04.4 x86_64 CPU container (3,317), GHC 9.12.4/Cabal 3.16.1.0.
The registered EnsureSpec subtree ran its applicability/diagnostic, wrong-host no-action, applicable
action, verified no-op and install/re-probe cases. The runner includes EnsureSpec.tests directly;
no test selector was supplied. Detailed deterministic driver coverage remains recorded in 8.2.

#### Remaining Work

None.

### Sprint 8.2: One total install-step outcome classifier [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Wsl2.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`

#### Objective

Give the shared probe/install/refresh/re-probe driver one total answer to each install step's outcome.
The driver remains config-free and uses the resolved HostTool boundary.

#### Deliverables

- `classifyStepOutcome` maps every runner result to `StepContinue`, `StepAlreadyInstalled`,
  `StepRebootRequired`, or `StepFailed String`, and `installAndVerifyWith` interprets that result.
- Winget's already-installed/no-upgrade failures continue through refresh and verification. WSL reboot
  text is recognized after the shared `normalizeWslText` strips UTF-16 NUL padding; the special install
  exit is classified explicitly. Text from another tool cannot request the WSL reboot path.
- `Ensure` owns normalization and `Ensure.Wsl2` reexports it through the existing public facade chain.
- The deterministic driver seam covers initial no-op, successful installation and re-probe, second-run
  no-op, install refusal/failure, and failed re-probe without running a package manager.

#### Validation

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
`EnsureSpec` 61 cases, `Wsl2Spec` 4, sealed checks 60, inventory checks 54, and `DocValidatorSpec` 17.
Library and components held package `-Werror`.

Fifteen pure cases cover the four outcomes, exact failure messages, winget install-only/nonzero guards,
UTF-16-padded WSL reboot text on success/failure, restart case folding, the special install exit versus
non-install, and non-WSL reboot text. The production driver test pins initial failed probe, winget
already-installed response, configuration refresh, and successful re-probe using the refreshed config.
Existing no-op/install/refusal/failure/re-probe controls pass without invoking a package manager.

Ensure owns the shared normalizer and Ensure.Wsl2 reexports it through the existing facade. Its separate
PowerShell Boolean parser retains its required character import. The exact public export inventory and
numeric split-sprint references pass. Production scope is two modules.

#### Remaining Work

None.

### Sprint 8.3: Baseline tool plans and discovery [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Ghc.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Homebrew.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/engineering/prerequisites.md`, `documents/architecture/hostbootstrap_core_library.md`,
`documents/architecture/build_and_run_model.md`

#### Objective

Declare the baseline dependency plans and resolve the tools those plans install. Each frame's row owns
its plan or delegation instruction. Linux Incus convergence is extended by Sprint 8.14; the worked-demo
phase exercises the live lifecycle, and neither is a closure dependency of these static plan checks.

#### Deliverables

- Docker's rows install a reachable daemon with buildx on Linux and delegate host-provider work on Apple
  and Windows. Incus declares its Apple and Linux host-provider plans.
- The Apple GHC plan installs ghcup's recommended GHC and sets it as default. HostTool verification
  searches ghcup's POSIX install directory as well as PATH, including a configured install-base prefix.
  The guest compiler pin belongs to PinnedToolchain; the outer compiler pin belongs to the bootstrapper.
- Homebrew is a host minimum the bootstrapper asserts. Its refusal tells the operator to install it
  from brew.sh and claims no bootstrapper installation or project-profile mutation.
- Every ProvidedElsewhere row states who supplies the dependency; each reconciler remains config-free.

#### Validation

On 2026-10-27, native Windows 11 x86_64 and native-filesystem Ubuntu 24.04.4 x86_64 CPU container,
GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from `core/`:
`EnsureSpec` 64 cases, selector `HostToolSpec` 21 (including its manifest declaration), sealed checks 60,
inventory checks 54, and `DocValidatorSpec` 17.
Library and components held package `-Werror`.

Three pure cases pin install-base-prefix precedence, HOME fallback, and no-root candidates as literal
POSIX paths on both gate hosts. POSIX Ghc/Ghcup fallback consumes those candidates through the existing
executable admission path; PATH precedence and the Windows branches remain intact. The exact GHC plan
uses `install ghc --set recommended`. Delegation cases pin Colima, Windows CPU/GPU WSL2 host-provider
instructions, and the brew.sh/operator Homebrew refusal with the bootstrapper's assertion contract.
Resolver/prerequisite docs and the exact HostTool export inventory match. Production scope is three modules.

#### Remaining Work

None.

### Sprint 8.4: Accelerator and outer-host provider reconcilers [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Cuda.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/accelerator_daemon.md`

#### Objective

Write each non-baseline reconciler here; confirm it on its own substrate later.

#### Deliverables

- `ensure apple-metal` reconciles the Swift/Metal toolchain. `ensure cudawin` reconciles the Windows CUDA
  build stack (CUDA Toolkit, MSVC build tools, LLVM). `ensure cuda` reconciles the Linux GPU container
  runtime: with the host driver as a precondition, it installs `nvidia-container-toolkit`, registers the
  NVIDIA runtime as Docker's default with CDI, enables volume-mount device injection, and restarts Docker.
  It installs no CUDA compiler; `nvcc` on linux-gpu comes from the published CUDA base image (§ L).
- `ensure lima` and `ensure wsl2` reconcile the Apple and Windows host providers; Sprint 8.12 owns WSL2
  status classification, and Sprint 8.13 owns native prerequisite decisions and install ordering.
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

On 2026-10-27, `cabal test all --test-options=--hide-successes` from `core/` passed on native
Windows 11 x86_64 (3,051 core tests, 513.29 seconds) and the native-filesystem Ubuntu 24.04.4
x86_64 CPU container (3,058 core tests, 382.83 seconds), GHC 9.12.4/Cabal 3.16.1.0, with package
`-Werror`. The provider-live component reported its explicit opt-in `Unsupported` result on both hosts;
no live provider or accelerator run is claimed by this static gate.

`EnsureSpec`'s `probe scratch directories` group runs four cases on both hosts:
`a successful probe uses a real file and removes its directory`,
`an IOError is a failed probe and still removes its directory`,
`UserInterrupt escapes a probe after its directory is removed`, and
`nested probes with the same prefix keep distinct live directories`.
The nested case observes the outer sentinel and inner removal while the outer callback is still live;
all cases require callback observations and check removal after return. Against the fixed-name,
exception-swallowing implementation, the Windows regression run failed the interrupt and nested cases
(2 of 4); with the bracketed unique-directory implementation all four passed before the full gates.

The existing applicability, install-plan, accelerator argv/source, reported-GPU, and WSL diagnostic
cases remain in the full suite. The CUDA probe Haddock and accelerator-daemon document state its
actual proof: Docker's default NVIDIA runtime and effective volume-mount injection. The install plan
still enables CDI. Production scope is two modules; live accelerator confirmation belongs to the
corresponding acceptance phase.

#### Remaining Work

None.

### Sprint 8.5: Curl is a resolved host tool [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`,
`core/hostbootstrap-core/test/HostToolSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/hostbootstrap_core_library.md`

#### Objective

Give described host HTTP commands one catalog identity and the configured absolute-path resolution
and refusal behavior the existing host-tool interpreter owns. The generic Lift consumes this lower
tool vocabulary in the next sprint.

#### Deliverables

- Append `Curl` after `Tar` in `HostTool`, preserving the existing enum positions.
- Render `Curl` as the canonical command name `curl` and use the existing PATH and native executable
  discovery rather than a platform-specific resolver or an additional host minimum.
- Resolve a configured `Curl` through its admitted `AbsExe`, and report `UnresolvedTool Curl` when it is
  absent from the host configuration.
- Include `Curl` in the exact tool inventory and the native discovery and re-resolution checks.

#### Validation

On 2026-10-27, native Windows 11 x86_64 and the native-filesystem Ubuntu 24.04.4 x86_64 CPU
container, GHC 9.12.4/Cabal 3.16.1.0, passed focused `cabal test hostbootstrap-core-test` runs from
`core/`: selector `HostToolSpec` 24 cases (including its manifest declaration), sealed-export checks 60,
inventory checks 54, and `DocValidatorSpec` 17.
The changed enumeration rebuilt its library and test consumers with package `-Werror`.

`HostToolSpec` runs `Curl has the canonical command name`, `Curl resolves through its configured
absolute path`, and `Curl uses the standard missing-tool error`; the configured case compares the
admitted absolute path, and the missing case checks both `resolveMaybe` and `UnresolvedTool Curl`.
The exact tool catalog appends `Curl` after `Tar`. Existing discovery and re-resolution loops cover
every tool on both gate hosts without requiring optional tools to be installed. The resolver document
states the described `hostCommand Curl args` behavior. Production scope is one module and two added lines.

#### Remaining Work

None.

### Sprint 8.6: Generic resolved-tool self-reference Lift [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Transaction.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/test/LiftSpec.hs`, `core/hostbootstrap-core/test/EnsureSpec.hs`,
`core/hostbootstrap-core/test/EffectSpec.hs`, `core/hostbootstrap-core/test/RegistrySpec.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/Spec.hs`, `core/hostbootstrap-core/test/CoverageManifest.hs`
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
- `Ensure.Wsl2` owns its prerequisite diagnostics, virtualization classification, and `bcdedit` argument
  rendering, and reexports the output normalizer owned by `Ensure`, without importing the later WSL2
  provider realization.
- Generic Lift imports no Incus, Lima, WSL2, `Substrate.Provider`, Registry, or cluster realization module.
- Reachability, blob-upload, and registry-auth leaf helpers are not part of this sprint; the
  composition-and-network phase adds them over this lower fold.

#### Validation

On 2026-10-27, `cabal test all --test-options=--hide-successes` from `core/` passed on native
Windows 11 x86_64 (3,071 core tests, 507.33 seconds) and the native-filesystem Ubuntu 24.04.4 x86_64
CPU container (3,073 core tests, 381.93 seconds), GHC 9.12.4/Cabal 3.16.1.0, with package `-Werror`.
The opt-in provider-live component reported its explicit `Unsupported` result on both hosts; no live
provider or accelerator confirmation is claimed.

The focused selectors passed on both hosts: `LiftSpec` 42 selected cases (40 Lift leaves plus two
manifest declarations), `EnsureSpec` 70, `EffectSpec` 44, and `RegistrySpec` 21. `LiftSpec` pins local
self and Curl targets, unknown and absolute raw refusal through both effect entrypoints, container
ENTRYPOINT argv, the non-empty Incus/Lima lifecycle binary, and innermost stdin through all three VM
nestings. Its native process subjects are the actual test executable: stdout and stdin preserve UTF-8
and LF, empty stdin matches the ordinary seam, and a real absent absolute executable reports the
lower native launch failure. `EnsureSpec`'s two negative WSL matrices reject ordinary plain/NUL-padded,
empty, and unrelated diagnostic text while retaining the positive cases.

The full suite observed shell row/refusal completions `(0,1)` on Windows and `(1,0)` on Linux, and
native local-effect completions `(4,0)` on both. Those families contain two and six leaves respectively;
no test-bearing token is inside a LiftSpec CPP region. The exact lower import guard passed.
`EffectSpec` verifies the fallible fold's target/frame and raw-path refusal; `RegistrySpec` pins the
four local raw Curl dispatches. `HandoffSpec` retains its exact transaction-size guard at 262 significant
lines, including the explicit raw-local refusal. Both production adopters preserve their refusal paths;
provider ownership still checks standing before and after execution. The three architecture documents
match the dispatch and ENTRYPOINT contract. Production scope is three modules.

#### Remaining Work

None.

### Sprint 8.7: Reconcilers as frame rows [Done]

**Status**: Done
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

On 2026-10-27, `cabal test all --test-options=--hide-successes` from `core/` passed on native
Windows 11 x86_64 (3,071 core tests, 506.26 seconds) and the native-filesystem Ubuntu 24.04.4 x86_64
CPU container (3,073 core tests, 387.03 seconds), GHC 9.12.4/Cabal 3.16.1.0, with package `-Werror`.
Focused selectors also passed on both hosts: `EnsureSpec` 70, `SubstrateSpec` 34, `DocValidatorSpec` 17.
The opt-in provider-live component reported its explicit `Unsupported` result; no live provider run
is claimed.

`EnsureSpec`'s `an accelerator row is selected ahead of its frame's general row` constructs a reconciler
with the general Linux row first and a GPU row second, carrying distinct literal install plans. It
asserts the GPU-specific plan on linux-gpu, the general plan on linux-cpu, and the exact requirement
`linux-gpu or linux`. Removing accelerator priority would select the wrong plan, so the case now
observes the ordering contract itself.

The existing `SubstrateSpec` cases `every tag has exactly one frame and its derived predicates` and
`the accelerator answer is a case over the whole sum` directly pin the frame, all three derived
predicates, and GPU classification over all five tags. They already meet this sprint's direct-collapse
obligation; no duplicate case or production change is needed. The ensure-reconcilers document already
states the same frame collapse and specific-row precedence. The only code change is the strengthened
EnsureSpec fixture and its public imports.

#### Remaining Work

None.

### Sprint 8.8: The guest bootstrap vocabulary [Done]

**Status**: Done
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

On 2026-10-27, `cabal test all --test-options=--hide-successes` from `core/` passed on native
Windows 11 x86_64 (3,086 core tests, 505.01 seconds) and the native-filesystem Ubuntu 24.04.4 x86_64
CPU container (3,088 core tests, 376.85 seconds), GHC 9.12.4/Cabal 3.16.1.0, with package `-Werror`.
The opt-in provider-live component reported its explicit `Unsupported` result; no live guest or provider
confirmation is claimed. Focused `GuestBootstrapSpec` 35 cases and `DocValidatorSpec` 17 also passed on
both hosts.

`GuestBootstrapSpec` pins the literal five-kind order and its equality with the complete enum, non-empty
step labels, and all eleven distinct literal floor packages. Exact argv cases cover dpkg's status-format argument,
apt, pipx `--force`, the GHC installer TLS/URL/fetch-run path pairing and install-base parent, and the
privileged binary install. The only permitted backslash is the exact dpkg format at its known `-f` slot;
all other arguments retain the guest-path separator check. Target cases reject `/opt/ghcup` and
`/root/.ghcup/` while the existing `/root/.ghcup` target remains admitted.

Eight floor cases cover installed, removed-config, unpacked, nonzero, empty, truncated, excess, and
empty-expected statuses. The driver case with exit-zero `rc` output runs the floor actions. Exact journals
cover all 16 empty-frame events and all six otherwise-satisfied events, repeated twice: the bootstrapper
always acts and verifies, and reports `GuestStepInstalled`. The scripted runner recognizes exact probes
and settles them only after their own ordered actions since failure; controls reject unrelated,
incomplete, out-of-order, and reset action sequences. Action failure, an unsettled re-probe, and all
three runner-error stages pin the owning step, `guest bootstrap: ` prefix, and absence of later calls.

`GuestStepKind`, exhaustive `stepFor`/`stepKind`, and the driver-used floor classifier implement those
contracts in one production module. Both listed documents match the package-output and source-refresh
policies. Public target selectors and step constructors remain the later role-boundary sprint's scope.

#### Remaining Work

None.

### Sprint 8.9: The raw leaf names its executable apart from its arguments [Done]

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
a name no tool carries, is Sprint 8.6's. Beside it, the self-reference value's two paths are distinct
types with no
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

None.

### Sprint 8.10: One group-and-socket reconciler workflow [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Ensure/Incus.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`
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

On 2026-10-27, `cabal test all --test-options=--hide-successes` from `core/` passed on native
Windows 11 x86_64 (3,093 core tests, 499.69 seconds) and the native-filesystem Ubuntu 24.04.4 x86_64
CPU container (3,095 core tests, 375.99 seconds), GHC 9.12.4/Cabal 3.16.1.0, with package `-Werror`.
Focused selections passed on both hosts: `EnsureSpec` 77, sealed-export checks 60, inventory checks 54,
and `DocValidatorSpec` 17. The opt-in provider-live component reported its explicit `Unsupported` result;
no live privileged operation is claimed.

Seven `EnsureSpec` cases in `invoking user and socket grants` exercise the injected workflow. Literal
Docker/matt and Incus/alex controls pin different labels, groups, users, socket paths, progress messages,
and the actual `usermod` then `grantSocketAccess`/`setfacl` argv. The environment case bypasses lookup;
the root-only environment invokes it. A missing user prints the exact skip with no privileged call or
callback. A nonzero usermod result and a runner refusal pin their exact diagnostics and stop before the
socket callback; an ACL failure uses the same checked-step formatter. The native fallback case compares
`invokingNonRootUser` with the host's effective-uid/passwd rule, and remains present on Windows with
its declared `Nothing` answer. Capture restores both streams and handles native newlines.

The new export is pinned in the exact Ensure inventory. Three production modules share the injected
checked-step runner while retaining Docker's direct-info short circuit, ACL-tool installation and
future-login verification, and Incus's grant/message behavior. The native passwd lookup catches only
`IOError` and reports no user for an absent entry. The reconciler document states that boundary without
claiming arbitrary injected lookup exceptions are swallowed. No real sudo, group, or socket operation
is part of the static cases.

#### Remaining Work

None.

### Sprint 8.11: One accelerator probe [Done]

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

### Sprint 8.12: WSL readiness comes from platform status [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Wsl2.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`, `documents/engineering/ensure_reconcilers.md`,
`DEVELOPMENT_PLAN/rationale.md`

#### Objective

Classify the WSL platform's own status independently of prerequisite remediation. Readiness is what
`wsl --status` reports, rather than reachability of the online distribution catalogue. Native prerequisite
observations and actions belong to Sprint 8.13; live bare-Windows convergence belongs to Phase 28.

#### Deliverables

- Introduce only `WslPlatformStatus`, with `WslPlatformReady`, `WslVirtualizationUnavailable`, and
  `WslPlatformAbsent`, and export the pure `classifyWslStatus` over `Either String (ExitCode, String, String)`.
- Reuse the shared normalized diagnostic predicates over stdout and stderr. Virtualization-disabled text
  wins on either exit success or failure, including text that also reports no installed distributions.
  Otherwise exit success or a no-installed-distributions report is ready; other failures and a runner
  `Left` are absent. A default version of 1 does not make the installed platform absent.
- `wsl2Ready` consumes exactly one `runTool cfg Wsl ["--status"]` result and accepts only
  `WslPlatformReady`. Delete `wsl2OnlineListReady`; no online catalogue is a readiness observation.
- Keep prerequisite remediation and its existing probes within Sprint 8.13's boundary. The public WSL2
  provider facade retains its existing four prerequisite reexports.

#### Validation

On 2026-10-27, `cabal test all --test-options=--hide-successes` from `core/` passed on native
Windows 11 x86_64 (3,108 core tests, 500.72 seconds) and the native-filesystem Ubuntu 24.04.4 x86_64
CPU container (3,110 core tests, 371.49 seconds), GHC 9.12.4/Cabal 3.16.1.0, with package `-Werror`.
Focused selections passed on both hosts: `EnsureSpec` 92, `Wsl2Spec` 4, and `DocValidatorSpec` 17.
The opt-in provider-live component reported its explicit `Unsupported` result; no live Windows
convergence is claimed.

`EnsureSpec`'s `WSL platform status` group contains fourteen independent literal classifier rows and
one structural guard. They cover all six required results, virtualization precedence on successful and
failed combined reports, uppercase/NUL/stderr normalization, no-distribution success, default version 1,
and empty exit success. The guard resolves the library source and reads the complete balanced
`wsl2Ready` definition, pins its one `--status` observation and classifier comparison, and rejects the
removed helper definition and lexed online argv. Its reason is recorded under `WSL readiness comes
from platform status` in the rationale.

The public provider facade retains its four prerequisite reexports and existing checks. The single
production module adds one status type and classifier; prerequisite ordering, native observations,
default-version convergence, and removal of PowerShell helpers remain Sprint 8.13's scope. Both
engineering documents now describe status-only readiness and keep that boundary explicit, using named
owner links. The source, tests, rationale, and nineteen-sprint status/reference split agree.

#### Remaining Work

None.

### Sprint 8.13: WSL prerequisite actions follow native observations [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Wsl2.hs`,
`core/hostbootstrap-core/cbits/wsl_hypervisor.c`, `core/hostbootstrap-core/hostbootstrap-core.cabal`,
`core/hostbootstrap-core/test/EnsureSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/wsl2.md`, `documents/engineering/ensure_reconcilers.md`,
`DEVELOPMENT_PLAN/rationale.md`, `DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

Select and execute prerequisite remediation from platform status and native hypervisor and firmware
observations. This adds the one action type over Sprint 8.12's status vocabulary. Static validation
performs no installation or reboot; live convergence on a bare Windows host belongs to Phase 28.

#### Deliverables

- Introduce only `WslAction` and a total
  `wslNextAction :: WslPlatformStatus -> Bool -> Bool -> WslAction`, in status/hypervisor/firmware order.
- Ready runs `InstallStep Wsl ["--set-default-version", "2"]`, so an installed platform whose default
  is version 1 converges. A not-ready platform with a present hypervisor runs the install plan, regardless
  of the firmware report. Successful install/no-op completion refreshes the host tools and runs the same
  default-version action, so a later passing probe cannot leave the default at 1. No hypervisor plus
  enabled firmware installs an absent platform, or enables hypervisor launch and requests reboot for
  virtualization-unavailable status. No hypervisor and an unavailable firmware report produces a
  refusal asking the operator to check BIOS/UEFI and host configuration.
- Query hypervisor presence before firmware when remediation needs those observations. Hypervisor
  presence comes from CPUID leaf 1/ECX bit 31 on supported Windows architectures; firmware uses the
  native `IsProcessorFeaturePresent(PF_VIRT_FIRMWARE_ENABLED)` binding. Unsupported observations return
  an explicit refusal through the existing `Either String` shape rather than a fabricated false fact.
- Register the small native C primitive unconditionally in the library's `c-sources`, with platform
  guards inside C and an unconditional Haskell binding to its supported-or-unsupported result. The
  Win32 firmware import and implementation are Windows-only. Host-conditional source registration
  violates the existing portability gate; the Win32 dependency is already declared for Windows.
- Drive `reconcileWsl2` from the action and remove `powerShellBoolArgs`, `parsePowerShellBool`, and
  `runPowerShellBool`; the module passes no `-Command` text.

#### Validation

On 2026-10-27, `cabal test all --test-options=--hide-successes` from `core/` passed on native
Windows 11 x86_64 (3,123 core tests, 504.69 seconds) and the native-filesystem Ubuntu 24.04.4 x86_64
CPU container (3,125 core tests, 381.95 seconds), GHC 9.12.4/Cabal 3.16.1.0, with package `-Werror`.
Focused selections passed on both hosts: `EnsureSpec` 107, `Wsl2Spec` 4, `PortabilitySpec` 25, and
`DocValidatorSpec` 17. The new C source and Haskell FFI compiled and linked on both platforms; Windows
used its native x86_64 Clang toolchain, and Linux built the explicit unsupported observation branch.
The provider-live component reported its opt-in `Unsupported` result; no live installation or reboot
is claimed.

`EnsureSpec` pins all twelve independent status/hypervisor/firmware actions. Its ready rows expect the
actual `WslSetDefaultVersion (InstallStep Wsl ["--set-default-version", "2"])` payload. A balanced-definition
guard pins payload consumption and install-driver completion followed by fresh host configuration and
the same default setter, including the legitimate install-no-op path. The injected reboot-driver case
pins the exact stop diagnostic with no refresh, later default-version step, or re-probe. The PowerShell
absence guard rejects all three helpers, the tool token, and interpreter argv; the existing status and
provider-facade guards remain.

`PortabilitySpec` holds unconditional source registration. The C primitive reports supported values or
an explicit unsupported result, and the existing Win32 wrapper supplies OS-reported firmware
availability. Hypervisor presence bypasses that flag; the refusal wording makes no infallible BIOS
claim. The source adds one action type in one Haskell module, a seventeen-line C primitive, and its
Cabal registration. Both engineering docs, the native-observation rationale, and the deletion ledger
match the completed boundary; the removed PowerShell shape is no longer listed. Named owner/API links
pass the governed documentation gate. Live bare-Windows convergence remains the acceptance phase's work.

#### Remaining Work

None.

### Sprint 8.14: Linux Incus convergence follows observations [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Incus.hs`,
`core/hostbootstrap-core/src/HostBootstrap/HostTool.hs`, `core/hostbootstrap-core/test/EnsureSpec.hs`,
`core/hostbootstrap-core/test/HostToolSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`, `documents/engineering/ensure_reconcilers.md`,
`DEVELOPMENT_PLAN/rationale.md`, `DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

Observe actionable Linux provider gaps before changing the host, then converge without unnecessary
package installation or daemon restart. A usable provider's convergence plan is empty. The separate
probe-minted capability boundary is Sprint 8.15; live Incus/KVM confirmation belongs to the worked-demo
phase and is not a closure obligation of this static sprint.

#### Deliverables

- Introduce only `LinuxIncusObservation`, retaining the resolved absolute Incus executable and the VM
  capability/root-daemon observations needed for planning. A pure
  `linuxIncusConvergence :: Arch -> LinuxIncusObservation -> [InstallStep]` installs VM packages only
  on a capability gap, initializes only on a root-daemon gap, and restarts exactly once when either ran.
- Render grouped `Sudo` capability probes: QEMU `test -x`, alternative firmware `test -f`, and executable
  virtiofsd candidates. Combine the groups in Haskell. Amd64 uses `qemu-system-x86`, `ovmf`,
  `/usr/bin/qemu-system-x86_64`, and OVMF firmware; Arm64 uses `qemu-system-arm`, `qemu-efi-aarch64`,
  `/usr/bin/qemu-system-aarch64`, and `/usr/share/AAVMF/AAVMF_CODE.fd`. Preserve literal candidate paths.
- Append `Virtiofsd` to the existing host-tool catalog after `Curl`; use its existing typed resolver
  for the PATH fallback and still observe `test -x` on the resolved path. Do not duplicate executable
  discovery inside the reconciler or treat a configured stale path as capability.
- Make Linux client installation package-only. Root-daemon probing uses the resolved absolute Incus
  path, and initialization exists solely in the observation-driven plan. Refresh host configuration
  after client/tool installation before using the installed executables or final provider probe.
- Replace forwarding interpreter text with chain/check/insert argv: a missing `DOCKER-USER` chain skips
  the rules, and insertion follows only a failed rule check.
- Replace the module-loader shell chain with ordered `kvm_intel`, `kvm_amd`, and `kvm` attempts,
  checking `/dev/kvm` after every attempt and stopping when it exists.
- Preserve shared group/socket and KVM grants. The `grantKvmReadWrite` Haddock names
  `invokingNonRootUser`; the module carries no `sh` or `bash` interpreter token.

#### Validation

On 2026-10-27, `cabal test all --test-options=--hide-successes` from `core/` passed on native
Windows 11 x86_64 (3,152 core tests, 520.22 seconds) and the native-filesystem Ubuntu 24.04.4 x86_64
CPU container (3,154 core tests, 382.89 seconds), GHC 9.12.4/Cabal 3.16.1.0, with package `-Werror`.
Focused selections passed on both hosts: `EnsureSpec` 133, `HostToolSpec` 27, and `DocValidatorSpec`
17. The provider-live component compiled on both hosts and reported its opt-in `Unsupported` result;
no privileged convergence or live provider success is claimed.

`EnsureSpec`'s `Incus observed convergence` cases pin complete grouped probe and VM-package argv for
both architectures, all four convergence combinations on each architecture, the resolved absolute
root-daemon executable, and a configured stale virtiofsd path that still requires `test -x`. The
`VM-capability combination` rows require QEMU and at least one firmware and virtiofsd result. Forwarding
and module-order cases pin chain/check/insert vectors and Intel, AMD, then generic KVM attempts.

The balanced-definition guards `Linux observations drive the only convergence plan and refresh every
installed tool`, `VM capability executes every grouped probe before combining its actual results`,
`forwarding skips a missing chain and inserts only after its rule check fails`, and `KVM rechecks the
device after each module attempt and stops when it exists` connect those plans to production flow.
The interpreter-absence guard rejects the removed capability helper and both shell tokens.
`HostToolSpec` pins the appended catalog entry, configured resolution, and the missing-tool diagnostic.
Both engineering docs and the named convergence rationale match the implementation; the three removed
shell shapes no longer appear in the deletion ledger. Capability admission remains the next sprint's
scope. Production changes span two source modules and introduce only `LinuxIncusObservation`.

#### Remaining Work

None.

### Sprint 8.15: Incus capability admission runs its own probe [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Incus.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeIncusProviderCapability.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeIncusProviderReady.hs`,
`core/hostbootstrap-core/provider-live/ProviderLiveRunner.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/incus.md`, `documents/engineering/ensure_reconcilers.md`,
`DEVELOPMENT_PLAN/rationale.md`

#### Objective

Admit the existing opaque Incus readiness capability only from the configured provider's current
observation. Descriptive statuses remain useful to callers without supplying capability authority.
Static closure compiles the opt-in live harness but does not require a running Incus daemon; live
provider confirmation belongs to the worked-demo phase.

#### Deliverables

- `withIncusProviderCapability` accepts `HostConfig` and runs `probeIncusProviderStatus` internally
  before the existing capability is minted. No public status-to-capability helper remains.
- Hide `IncusProviderReady`; retain the six non-ready constructors and expose a descriptive,
  production-used `incusProviderStatusResult :: IncusProviderStatus -> Either String ()` eliminator.
- Preserve failure precedence: daemon permission outranks VM/egress failures, and a VM-capability
  failure outranks egress. A Ready status derived from the classifier can be read through the eliminator.
- Adopt the configured-probe gate in `verifyUsableProvider` and the descriptive eliminator in
  `ProviderLiveRunner`; retain the harness's opt-in execution boundary.
- Register `ForgeIncusProviderCapability.hs` and `ForgeIncusProviderReady.hs` as independent genuine
  public-only constructor-boundary fixtures using `rejectsWith` and a well-typed import/body targeting
  each actual hidden constructor.

#### Validation

On 2026-10-27, `cabal test all --test-options=--hide-successes` from `core/` passed on native
Windows 11 x86_64 (3,163 core tests, 513.75 seconds) and the native-filesystem Ubuntu 24.04.4 x86_64
CPU container (3,165 core tests, 387.76 seconds), GHC 9.12.4/Cabal 3.16.1.0, with package `-Werror`.
Focused selections passed on both hosts: `EnsureSpec` 142, the two `ForgeIncusProvider` fixtures,
and `DocValidatorSpec` 17. The updated provider-live component compiled and reported its opt-in
`Unsupported` result on both hosts; no live Incus or privileged setup was run.

`EnsureSpec`'s six `the descriptive eliminator refuses` rows derive each status through the real
classifier and pin its literal refusal. `the complete classifier row passes the descriptive status
check` pins Ready through the eliminator without minting capability. Separate simultaneous-failure
cases pin daemon permission before VM/egress and VM before egress. `a configured missing client cannot
run the capability callback` invokes the actual gate with an empty tool configuration and executes any
returned action before asserting the exact refusal and zero callbacks.

`capability admission observes its configuration before checking status and minting` pins the complete
balanced gate and reconciler definitions against the named observation rationale. The gate runs its
configured probe, consumes the descriptive eliminator, and only then supplies the opaque capability;
the reconciler passes configuration directly. Both constructor fixtures use genuine public-only
imports and independently reject with GHC-10237 naming their own hidden child. The native Windows
Ready fixture compiled against the preceding public interface and rejected after the library rebuild;
the capability fixture rejected on both sides. No obsolete arity or unrelated type error supplies the
negative result.

The two engineering docs, live-harness preflight, and rationale match the configured-probe boundary.
Classifier output remains descriptive, tool paths remain caller-configured, and readiness is a current
observation rather than an indefinite guarantee. Production changes span two source modules and
introduce no new named type.

#### Remaining Work

None.

### Sprint 8.16: NVIDIA repository publication follows validated fetches [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Cuda.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/accelerator_daemon.md`,
`documents/engineering/ensure_reconcilers.md`, `DEVELOPMENT_PLAN/rationale.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

Set up the NVIDIA repository through typed argument vectors and Haskell file processing. Failed fetches
or a refused repository body leave both destination files untouched. Repository preparation is an
explicit runtime stage with owned scratch storage, separate from the real static bootstrap-tool and
runtime-tail command lists; no pretend command stands for Haskell work.

#### Deliverables

- Preserve the driver's precondition and the complete satisfied no-op. Install only missing repository
  tools through real `repositoryToolSteps`; observe typed Curl and a successful `gpg --version`, then
  refresh host configuration before using newly installed tools.
- A production-used `setupRepositoryWith` owns a temporary directory and uses the resolved tool runner
  for both `curl -fsSL -o` downloads. Strictly read and validate both fetched files before publishing.
  Ordinary IO errors refuse; asynchronous exceptions propagate after scratch cleanup.
- `signedByListText` inserts the fixed signed-by keyring into every supported active NVIDIA `deb
  https://` line. Preserve comments, blank lines, `$(ARCH)`, and final-newline behavior; refuse empty,
  HTML, comment-only, embedded-deb, or unsupported active syntax rather than retaining unsigned entries.
- After both successful fetches and list validation, run `gpg --dearmor --yes -o
  /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg <key>` and `install -m 0644 <signed-list>
  /etc/apt/sources.list.d/nvidia-container-toolkit.list` under `Sudo`. This ordering does not promise an
  atomic two-file publication or rollback after a publication command fails.
- Keep `installSteps` as the real runtime tail: apt update, toolkit installation, runtime/default/CDI
  configuration, volume-mount injection setting, and Docker restart. Production consumes that tail
  after repository setup and verifies the exact nvkind smoke. Remove `repositorySetupScript` and the
  interpreter step entirely.

#### Validation

On 2026-10-27, `cabal test all --test-options=--hide-successes` from `core/` passed on native
Windows 11 x86_64 (3,196 core tests, 509.74 seconds) and the native-filesystem Ubuntu 24.04.4 x86_64
CPU container (3,198 core tests, 385.62 seconds), GHC 9.12.4/Cabal 3.16.1.0, with package `-Werror`.
Focused selections passed on both hosts: `EnsureSpec` 175 and `DocValidatorSpec` 17. The provider-live
component compiled and reported its opt-in `Unsupported` result on both hosts; no live repository,
privileged publication, GPU, or CDI run is claimed.

`EnsureSpec`'s 33 `NVIDIA repository preparation` cases include eleven literal list controls and
independent path-bearing fetch/publication vectors. The successful production-helper workflow records
both downloads before publication and observes the actual binary key and rewritten UTF-8 list bytes.
Fourteen pre-publication refusal cases cover command refusals/nonzero exits, missing/empty files,
invalid UTF-8, and unsupported list bodies; their exact journals contain no publication command.
IO-error and `UserInterrupt` cases verify owned scratch cleanup, with the asynchronous exception
propagating. Publication-failure cases stop after the failed command and clean scratch without
claiming rollback. Every fixture write is restricted to the actual owned temporary download paths.

The real bootstrap-tool and runtime-tail lists are pinned separately. `CUDA verifies its no-op before
tool preparation, repository publication, and the runtime tail` connects the guarded reconciler,
actual tool observations, refresh, scratch workflow, tail, and final smoke. The named interpreter
absence guard rejects the deleted helper and shell argv. Both engineering docs and the staging
rationale match this boundary; the removed CUDA shell row no longer appears in the deletion ledger,
and the Docker row remains for the next sprint. Production changes occupy one module and introduce
no new named type.

#### Remaining Work

None.

### Sprint 8.17: Docker group and socket checks use observed permissions [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/Docker.hs`,
`core/hostbootstrap-core/test/EnsureSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`, `DEVELOPMENT_PLAN/rationale.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

Verify the future login's group-based Docker socket access from actual group and socket observations,
then preserve immediate invocation access. This read-only check replaces `sg` interpreter text; it
makes no claim to execute a future login or prove daemon connectivity.

#### Deliverables

- A narrow production-used result-producing runner invokes `Sudo` with `id -nG <user>`. Require a
  successful command and exact group-name tokens; the shared checked-step callback discards stdout
  and therefore cannot stand in for this observation.
- Read the fixed Docker socket's owning group name and group-write bit in Haskell. Require membership
  in that actual group and a writable group bit. IO/metadata failures refuse; native Windows compiles
  an explicit unsupported observation while POSIX imports remain platform-guarded.
- Refuse before the current-session ACL path on a failed group/socket observation. Preserve the shared
  invoking-user selection, group grant, direct Docker probe, and current-session ACL behavior.
- Prepend `InstallStep Sudo ["apt-get", "update"]` before Linux package installation. Remove the
  `sg docker -c` step and interpreter token.

#### Validation

On 2026-10-27, `cabal test all --test-options=--hide-successes` from `core/` passed on native
Windows 11 x86_64 (3,211 core tests, 513.49 seconds) and the native-filesystem Ubuntu 24.04.4 x86_64
CPU container (3,213 core tests, 386.71 seconds), GHC 9.12.4/Cabal 3.16.1.0, with package `-Werror`.
Focused selections passed on both hosts: `EnsureSpec` 190 and `DocValidatorSpec` 17. The provider-live
component compiled and reported its opt-in `Unsupported` result on both hosts; no actual host group,
socket, future login, or daemon permission was changed by these static checks.

`EnsureSpec`'s fifteen `Docker group and socket verification` cases include ten portable verifier
controls. Independent literals pin the exact `id -nG matt` argv, complete tokens, case, whitespace,
custom socket-owning groups, the group-write bit, and command/metadata refusals. Event journals require
id before metadata and require command failure to skip metadata. Separate thrown-IO-error and
`UserInterrupt` cases pin ordinary refusal and asynchronous propagation.

`production permission refusal precedes the actual direct-info and ACL flow` connects the existing
shared invoking-user/group grant to the production verifier, with failure before the actual
current-session continuation. It preserves the direct Docker probe, ACL-tool installation, and socket
grant. `native socket metadata supplies its real owning group and group-write bit` pins the fixed
socket path, complete POSIX mapping, and explicit native-Windows refusal. The named interpreter
absence guard and Linux plan case hold removal of `sg` and apt update before installation.

The engineering doc, group/socket rationale, and deletion ledger match the boundary. Group grant
precedes verification; current-session access work follows success. The verifier observes permissions
without minting authority or executing a future login. Production changes occupy one module and
introduce no new named type.

#### Remaining Work

None.

### Sprint 8.18: Guest paths enter through a sealed bootstrap target [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/GuestBootstrap.hs`,
`core/hostbootstrap-core/test/GuestBootstrapSpec.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`, `core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/RepointGuestBootstrapTarget.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeGuestBootstrapStep.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/build_and_run_model.md`, `DEVELOPMENT_PLAN/rationale.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`

#### Objective

Admit each POSIX-absolute guest path into one opaque `GuestPath` and retain that proof in the bootstrap
target and its steps. Ordinary readers preserve inspection, while construction remains behind the
target's admission and closed plan. This base introduces one type; the six coordinate roles are adopted
individually in Sprints 8.19–8.24.

#### Deliverables

- Add abstract `GuestPath`, `mkGuestPath :: FilePath -> Either String GuestPath`, and a raw-preserving
  view. Validation uses guest POSIX grammar on every outer host and retains the original spelling.
- Store `GuestPath` in all six target coordinates and every private step path payload. Keep the six raw
  inputs of `mkGuestBootstrapTarget` and the sole demo caller unchanged. Preserve aggregate path-error
  order and duplicates, then the pinned-toolchain check, then the existing `.ghcup` check.
- Keep all seven target record labels private. Export ordinary readers returning `GuestPath` for path
  coordinates and `PinnedToolchain` for the toolchain; external record update is unavailable.
- Export `GuestBootstrapStep` abstractly. The admitted target supplies the closed plan, and callers read
  steps through `stepKind`, `stepLabel`, `stepProbe`, and `stepActions`. Preserve exact argv, driver
  journals, original path spelling, and target/step `Show` output including precedence.
- Replace both external floor-constructor matches in `GuestBootstrapSpec` with `stepKind` and existing
  complete package/probe/action observations. Add direct path-admission, ordinary-reader, and `Show`
  controls while retaining the ordered plan and driver cases.
- Register genuine `RepointGuestBootstrapTarget` and `ForgeGuestBootstrapStep` fixtures. Their bodies
  supply valid `GuestPath` payloads and would compile if the intended field or constructor were exposed;
  pin each actual public-compiler diagnostic through `rejectsWith`.
- Add the exact GuestBootstrap export pin and its actual supplemental entry in `AuthoritySpec`'s
  inventory check. The named constructor/absence guards explain the sealed target boundary in the
  rationale entry "Guest bootstrap steps come from admitted targets". Docs distinguish this base from
  the six remaining raw argument roles.

#### Validation

On 2026-10-27, `cabal test all --test-options=--hide-successes` from `core/` passed on native
Windows 11 x86_64 (3,231 core tests, 554.55 seconds) and the native-filesystem Ubuntu 24.04.4 x86_64
CPU container (3,233 core tests, 443.62 seconds), GHC 9.12.4/Cabal 3.16.1.0, with package `-Werror`.
`cabal build all` from `demo/` also passed on both hosts against the changed local core, including the
actual target-factory caller. Provider-live compiled and reported its opt-in `Unsupported` result;
no live guest bootstrap is claimed.

Focused selections passed on both hosts: `GuestBootstrapSpec` 53, `RepointGuestBootstrapTarget` 1,
`ForgeGuestBootstrapStep` 1, sealed boundaries 60, inventory 54, and `DocValidatorSpec` 17. Thirteen
new path cases pin POSIX admission, raw spelling and compatible presentation. Five target controls
pin aggregate refusal order and duplicates, pin-before-home priority, all six proof-valued readers,
target/step `Show` precedence, and ordinary definitions with private labels. Existing literal argv,
ordered kinds, installed-package probes, and driver journals remain without public step constructors.

The genuine public-only fixtures supply admitted `GuestPath` values. Repoint rejects GHC-22385 for
record field `guestSourceRoot`; ForgeStep rejects GHC-10237 for the hidden `InstallGuestProjectBinary`
child. The exact export inventory and actual supplemental discovery entry keep path, target, and step
constructors opaque. Both governed docs and the named rationale match the base boundary. The raw-slot
ledger row remains for the six separately adopted coordinate roles; the factory still accepts six
raw path arguments. Production changes occupy one module and introduce only `GuestPath`.

#### Remaining Work

None.

### Sprint 8.19: The guest source root has its own role [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/GuestBootstrap.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/GuestBootstrapSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/RepointGuestBootstrapTarget.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/build_and_run_model.md`

#### Objective

Distinguish the staged repository root with one opaque `GuestSourceRoot` over `GuestPath`, retaining
that role from the real target argument to the bootstrapper's source payload.

#### Deliverables

- Add only `GuestSourceRoot`, with construction from validated `GuestPath` and an ordinary path view.
  Type target argument one, its reader, and `InstallGuestBootstrapper`'s source payload with that role.
- Adopt the actual demo `vmRepoRoot` argument immediately through guest-path admission and the role
  builder. Render its original spelling into the bootstrapper label and `pipx install --force` argv.
- Update `RepointGuestBootstrapTarget` to provide a valid `GuestSourceRoot` replacement; its rejection
  must remain the absent record-field boundary. Update the exact export pin and ordinary-reader tests.
- Add one alternate source-root control proving that only the source-dependent label/argv positions
  change. Preserve all other literal argv, order, journals, target admission checks, and `Show` output.

#### Validation

On 2026-10-27, focused selections passed on native Windows 11 x86_64 and the native-filesystem
Ubuntu 24.04.4 x86_64 CPU container: `GuestBootstrapSpec` 54, `RepointGuestBootstrapTarget` 1,
sealed boundaries 60, inventory 54, and `DocValidatorSpec` 17. `cabal build all` from both `core/`
and `demo/` passed on both hosts, GHC 9.12.4/Cabal 3.16.1.0 with package `-Werror`.

The alternate-source control compares every kind, probe, action and label: only the explicit pipx
source argument and bootstrapper source label change. Existing argv, driver journals, pin/home checks,
and compatible presentation remain. Source refusal is checked at path admission; target error-order
controls use the remaining raw slots. Repoint supplies a correctly typed source role and retains its
actual public-compiler field-access diagnostic. The exact export pin contains the opaque role and its
total builder/view; no new authority fixture or unrelated full-suite rerun is needed.

The actual demo admits and labels `vmRepoRoot` before the existing target call. Both governed docs
reflect the retained source role and five remaining raw inputs. Production changes occupy two source
modules and introduce only `GuestSourceRoot`; no live guest is claimed.

#### Remaining Work

None.

### Sprint 8.20: The guest project directory has its own role [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/GuestBootstrap.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/GuestBootstrapSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`

#### Objective

Distinguish the build's working directory with one opaque `GuestProjectDir` over `GuestPath`, used by
the real target and build step.

#### Deliverables

- Add only `GuestProjectDir`, with construction from `GuestPath` and an ordinary path view. Type target
  argument two, its reader, and the build step's project-directory payload with that role.
- Adopt the actual demo `vmDemoRoot` argument immediately. Preserve the original path in the build
  label and `env -C` argv; retain source-root typing and the remaining factory admission checks.
- Update the exact export pin and reader controls. An alternate project-directory control changes
  only its declared label/working-directory positions, preserving other argv, order, journals and `Show`.

#### Validation

On 2026-10-27, focused selections passed on native Windows 11 x86_64 and the native-filesystem
Ubuntu 24.04.4 x86_64 CPU container: `GuestBootstrapSpec` 55, sealed boundaries 60, inventory 54,
and `DocValidatorSpec` 17. `cabal build all` from both `core/` and `demo/` passed on both hosts,
GHC 9.12.4/Cabal 3.16.1.0 with package `-Werror`.

The alternate-project control compares all kinds, probes, actions and labels. Only the independently
specified build label and complete `env -C` build action change; PATH, bootstrapper, built probe and
every other observation remain fixed. Existing source-root, presentation and driver controls remain.
Invalid project spelling is tested at path admission; four remaining raw coordinates retain ordered
aggregate refusal and duplicates before pin/home checks. The second reader and exact opaque export
pin retain the project role. Existing constructor fixtures remain correctly typed without changes.

The actual demo admits and labels `vmDemoRoot` for argument two while preserving the independently
spelled built-binary argument. The engineering doc records two roles and four raw inputs; the
count-free architecture overview remains accurate. Production changes occupy two modules and
introduce only `GuestProjectDir`; no live guest is claimed.

#### Remaining Work

None.

### Sprint 8.21: The guest toolchain home has its own role [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/GuestBootstrap.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/GuestBootstrapSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`

#### Objective

Distinguish the installed toolchain's home with one opaque `GuestToolchainHome` over `GuestPath`,
carried by both toolchain installation and project build.

#### Deliverables

- Add only `GuestToolchainHome`, with construction from `GuestPath` and an ordinary path view. Type
  target argument three, its reader, and the toolchain/build home payloads with that role.
- Adopt the demo's `/root/.ghcup` argument immediately. Keep pinned-toolchain and `.ghcup` validation
  in the target with the existing order and refusals; preserve the installer parent's prefix and paths.
- Update the exact export pin and reader controls. An alternate admitted home changes its toolchain
  probes, installer location/base prefix and build PATH, preserving other argv, order, journals and `Show`.

#### Validation

On 2026-10-27, focused selections passed on native Windows 11 x86_64 and the native-filesystem
Ubuntu 24.04.4 x86_64 CPU container: `GuestBootstrapSpec` 57, sealed boundaries 60, inventory 54,
and `DocValidatorSpec` 17. `cabal build all` from both `core/` and `demo/` passed on both hosts,
GHC 9.12.4/Cabal 3.16.1.0 with package `-Werror`.

The relative-home control checks common admission before the total role builder. Admitted absolute
but incompatible homes retain their exact target refusals; combined raw-error, empty-pin and
incompatible-home cases pin the existing priority. The reader retains original `/root//.ghcup`
spelling. The alternate-home control compares all kinds, labels, probes and actions against baseline,
pinning independent literal toolchain executable probes, installer fetch/run filename and base parent,
and the complete build PATH. Labels and all other coordinates remain unchanged.

Existing source/project alternates, presentation, argv, journals and constructor fixtures remain valid.
The exact export pin retains the opaque home role and total builder/view. The actual demo admits and
labels `/root/.ghcup` for argument three. The engineering doc distinguishes the role from the target's
`.ghcup` condition and leaves three raw inputs. Production changes occupy two modules and introduce
only `GuestToolchainHome`; no live guest is claimed.

#### Remaining Work

None.

### Sprint 8.22: The guest bootstrapper executable has its own role [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/GuestBootstrap.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/GuestBootstrapSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`

#### Objective

Distinguish the installed Python bootstrapper with one opaque `GuestBootstrapperExe` over `GuestPath`,
retained by the bootstrapper and build steps.

#### Deliverables

- Add only `GuestBootstrapperExe`, with construction from `GuestPath` and an ordinary path view. Type
  target argument four, its reader, and the bootstrapper/build executable payloads with that role.
- Adopt the demo's `/root/.local/bin/hostbootstrap` argument immediately. Preserve its executable probe,
  build executable and PATH parent, with existing target admission and earlier role types.
- Update the exact export pin and reader controls. An alternate executable changes only those probe
  and build positions, preserving other literal argv, order, journals and `Show` output.

#### Validation

On 2026-10-27, focused selections passed on native Windows 11 x86_64 and the native-filesystem
Ubuntu 24.04.4 x86_64 CPU container: `GuestBootstrapSpec` 59, sealed boundaries 60, inventory 54,
and `DocValidatorSpec` 17. `cabal build all` from both `core/` and `demo/` passed on both hosts,
GHC 9.12.4/Cabal 3.16.1.0 with package `-Werror`.

Relative-executable admission and the typed fourth reader retain the path boundary. Two independent
raw-output rows pin distinct built-before-installed order and duplicate multiplicity before empty pin
and incompatible home checks. The complete alternate-executable control changes only its literal
`test -x` probe and full build action's executable/PATH parent; labels, pipx source action, binary
outputs and all other plan observations remain fixed.

Existing alternates, presentation, argv, journals and constructor fixtures remain valid. The exact
pin contains the opaque executable role and total builder/view. The actual demo admits and labels
`/root/.local/bin/hostbootstrap` for argument four. The engineering doc distinguishes its purpose from
installation/readiness and leaves only two raw output paths. Production changes occupy two modules
and introduce only `GuestBootstrapperExe`; no live guest is claimed.

#### Remaining Work

None.

### Sprint 8.23: The guest built binary has its own role [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/GuestBootstrap.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/GuestBootstrapSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeGuestBootstrapStep.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`

#### Objective

Distinguish the native build output with one opaque `GuestBuiltBinary` over `GuestPath`, retained as
the build result and the binary-installation source.

#### Deliverables

- Add only `GuestBuiltBinary`, with construction from `GuestPath` and an ordinary path view. Type
  target argument five, its reader, the build-output payload and the install-source payload with that role.
- Adopt the actual demo build-output path immediately. Preserve its executable probe, comparison source
  and install source without changing the installed-binary coordinate or earlier role types.
- Update `ForgeGuestBootstrapStep` with a valid built-role payload so it still rejects only the hidden
  step constructor. Update the exact export pin and reader controls.
- An alternate built path changes only its declared probe/comparison/install positions. Preserve other
  literal argv, target admission, step order, journals and `Show` output.

#### Validation

On 2026-10-27, focused selections passed on native Windows 11 x86_64 and the native-filesystem
Ubuntu 24.04.4 x86_64 CPU container: `GuestBootstrapSpec` 61, `ForgeGuestBootstrapStep` 1, sealed
boundaries 60, inventory 54, and `DocValidatorSpec` 17. `cabal build all` from both `core/` and
`demo/` passed on both hosts, GHC 9.12.4/Cabal 3.16.1.0 with package `-Werror`.

Built-path admission and the typed fifth reader retain the coordinate boundary. The single remaining
raw installed-path refusal precedes empty pin and incompatible home checks without manufacturing
invalid typed values. The complete alternate-built control changes only literal build-output `test -x`,
comparison-source and install-source positions; every label, the build action and installed destination
remain unchanged. Existing presentation, other alternates and driver journals remain valid.

ForgeStep's first payload is now an admitted `GuestBuiltBinary`; its destination stays `GuestPath`
for the next adoption. Actual public-only GHC still rejects the hidden `InstallGuestProjectBinary`
constructor with GHC-10237, and its registered test passes on both hosts. Repoint remains correctly
typed. The exact export pin and actual demo retain the built role; the demo independently admits the
existing output spelling. The engineering doc leaves only the installed destination raw. Production
changes occupy two modules and introduce only `GuestBuiltBinary`; no live guest is claimed.

#### Remaining Work

None.

### Sprint 8.24: The guest installed binary has its own role [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Ensure/GuestBootstrap.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/GuestBootstrapSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`, `core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeGuestBootstrapStep.hs`,
`core/hostbootstrap-core/test/compile-fail/TransposeGuestBinaryRoles.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/engineering/ensure_reconcilers.md`,
`documents/architecture/build_and_run_model.md`, `DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`,
`DEVELOPMENT_PLAN/rationale.md`

#### Objective

Complete the six-coordinate boundary with one opaque `GuestInstalledBinary` over `GuestPath`.
The admitted target requires distinct roles for every coordinate, and the final install step retains
the built-source and installed-destination distinction.

#### Deliverables

- Add only `GuestInstalledBinary`, with construction from `GuestPath` and an ordinary path view. Type
  target argument six, its reader and the install-destination payload with that role.
- Adopt the actual demo installed-binary argument immediately. Preserve the install label, comparison
  destination and install destination, and retain pin/`.ghcup` validation in the target.
- Update `ForgeGuestBootstrapStep` to supply valid built and installed roles. Register genuine
  `TransposeGuestBinaryRoles`: all other inputs are well-typed, and an installed role in the built slot
  fails for that specific role mismatch under the actual public compiler.
- Update the exact export pin and reader controls. An alternate installed path changes only the
  declared label/comparison/install destinations, preserving other argv, order, journals and `Show`.
- Close the remaining coordinate-role gap in both governed docs and remove the raw-coordinate ledger
  row only when all six factory arguments and matching step payloads retain their distinct roles.

#### Validation

On 2026-10-27, focused selections passed on native Windows 11 x86_64 and the native-filesystem
Ubuntu 24.04.4 x86_64 CPU container: `GuestBootstrapSpec` 62, each of the three guest constructor/role
fixtures 1, sealed boundaries 60, inventory 54, and `DocValidatorSpec` 17. `cabal build all` from both
`core/` and `demo/` passed on both hosts, GHC 9.12.4/Cabal 3.16.1.0 with package `-Werror`.

All target arguments/readers now retain distinct admitted roles. Common installed-path admission
replaces the impossible raw-target failure case; pin-before-home controls remain. The complete
alternate-destination plan control changes only the independently specified final label, comparison
destination and install destination, preserving source, build argv and other roles. Existing spelling,
presentation, other alternates, literal argv and driver journals remain.

ForgeStep supplies both admitted binary roles and still rejects the hidden constructor with actual
public-only GHC-10237. Transpose admits all six valid paths, constructs the six explicitly typed
roles, calls the full current factory and swaps only arguments five and six. Both actual GHC-83865
expected/actual role-mismatch blocks are required independently by its registered test. Repoint remains
correctly typed. The exact export pin includes the final opaque role and total builder/view.

The actual demo admits and labels all six coordinates. The factory has no raw path slot or obsolete
admission machinery and retains empty-pin then `.ghcup` checks. Both governed docs and the rationale
match this boundary; signature verification allowed removal of the raw-slot ledger row. Production
changes occupy two modules and introduce only `GuestInstalledBinary`; no live guest is claimed.

#### Remaining Work

None.

### Sprint 8.25: Container config delivery runs no shell [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Transaction.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Handoff/Process/Route.hs`,
`core/hostbootstrap-core/test/LiftSpec.hs`, `core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`, `documents/engineering/derived_dockerfile.md`,
`documents/engineering/config_generation.md`, `DEVELOPMENT_PLAN/rationale.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`, `DEVELOPMENT_PLAN/development_plan_standards.md`

#### Objective

A delivering container receives its sibling configuration without an interpreter (§ KK). Its existing
image entry point starts only after a single-entry ustar projection reaches the stopped container through
`docker cp`. The actual runner executes the same described argument vectors that tests inspect.

#### Deliverables

- Extend the existing `LiftDispatch` sum with a real staged-delivery description holding the VM prefix,
  terminal container and inner argv. No synthetic executable represents the workflow. The single-command
  eliminator and descriptor-owning handoff explicitly refuse this multi-command description. The route's
  channel-contract comment describes its continuing delivery refusal without changing route behavior.
- Preserve the public stdin execution signatures. A production-used runner seam executes real folded
  `docker create`, `docker cp - <id>:<directory>`, then `docker start -a <id>` commands. Every command,
  including failure cleanup, crosses the same VM prefix and existing host-tool authority. Creation retains
  mounts, extra arguments, image, folded subcommand and `--rm` exactly when requested; no entry-point override.
- Encode the explicit supplied stdin, rather than substituting stored delivery metadata, as one regular
  ustar entry under the write path's basename. Validate path/name and octal-size bounds before creating
  anything. Header size and checksum count UTF-8 bytes; block padding and two zero trailer blocks are real
  bytes. Carry the valid UTF-8 archive through the existing binary-pipe UTF-8 runner without Char8 conversion.
  Creation and start receive empty stdin; only copy receives the archive.
- Require one full Docker container ID from successful creation before addressing copy/start. Refusal,
  nonzero status or malformed ID stops dependent steps. Hide successful intermediate chatter and return
  the attached start result, including a failing child status, with its original exit code and stdout.
- After a valid ID is known, `clRemoveAfter` requests a same-route `docker rm -f <id>` attempt on copy/start
  refusal, nonzero status or exception. A retained container requests no cleanup. Preserve the primary
  failure; append an actual cleanup refusal to its diagnostic, or report it before rethrowing the original
  exception. An already auto-removed container can refuse that attempt; this is not evidence of residue.
  Make no cleanup promise before a valid ID exists or a timeout guarantee absent from the existing runner.
- Delete the config-writing interpreter export/body and override, update the exact export pin and remove
  its verified ledger row. Governed architecture, image-init and stdin docs state the copied-before-start
  protocol and static evidence boundary. Sprint 8.26 owns the two-coordinate delivery description.

#### Validation

On 2026-10-27, `cabal test all --test-options=--hide-successes` passed on native Windows 11 x86_64
(3,271 cases, 496.40 seconds) and the native-filesystem Ubuntu 24.04.4 x86_64 CPU container
(3,273 cases, 379.23 seconds), GHC 9.12.4/Cabal 3.16.1.0. `cabal build all` from `demo/` passed on both
hosts with package `-Werror`. Focused selections also passed on both: frame-child entry 8, LiftSpec 71
(including 36 delivery cases), sealed boundaries 60, inventory 54 and DocValidatorSpec 17.

The actual runner controls pin create/copy/start and failure cleanup argv, all VM prefixes, explicit
stdin distinct from stored payload, final child results and ordinary single-command delivery absence.
Independent byte checks inspect the actual copy archive for empty/512/513-byte bodies, Unicode names
and payload, the exact 100-byte filename boundary, header/checksum, padding and trailer. Preflight and
malformed-ID refusals launch no dependent command. Stage failures, remove/retain policy, cleanup refusal,
active exceptions and interruption during normal cleanup retain the declared primary outcomes.

The real frame-transaction entry refuses staged delivery before resolving any host tool, both locally
and through a VM. Its scoped delegation guard holds one crossing and shared bracketed group cleanup;
argv classifier ordering and authority/environment absence remain covered. The exact export pin matches
actual source. Source checks reject the config-writing interpreter and override; verified absence allowed
its ledger row and standing inventory entry to be removed. All four governed protocol/image/stdin docs
and the rationale match. Production changes occupy three modules and 251 changed lines, with no new
type. Static controls prove commands, bytes and cleanup attempts, not live extraction, entry-point
execution or absence of container residue; the opt-in provider-live suite reports its declared
not-requested branch.

#### Remaining Work

None.

### Sprint 8.26: Container delivery describes only its filesystem projection [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`, `core/hostbootstrap-core/test/LiftSpec.hs`,
`core/hostbootstrap-core/test/LiftContextSpec.hs`, `core/hostbootstrap-core/test/ReconcileSpec.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`, `core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`, `DEVELOPMENT_PLAN/rationale.md`

#### Objective

`ConfigDelivery` describes its write destination and projection payload. Container invocation authority
belongs to the image entry point, so delivery carries no executable coordinate.

#### Deliverables

- Retain only write-path and payload coordinates in `ConfigDelivery`; adapt the actual demo constructor
  and corresponding tests. Delete the unused executable coordinate and its canonical binding member.
- Canonical delivery binding encodes the actual two-coordinate value, and the canonical parser consumes
  that same record shape. Advance canonical snapshot format 7 to 8 under its versioned-schema contract;
  reject version 7 rather than reinterpret it. Update the actual accessor/header/golden pins and test the
  intentional binding-byte change.
- Remove the ledger row only after no production definition, constructor argument or binding member remains.
  Keep this adoption to Context, Lifecycle.Plan and the one demo call site with no new named contract.

#### Validation

On 2026-10-27 (America/Toronto), focused selections passed on native Windows 11 x86_64 and the
native-filesystem Ubuntu 24.04.4 x86_64 CPU container, GHC 9.12.4/Cabal 3.16.1.0: LiftSpec 71,
LiftContextSpec 6, ReconcileSpec 106, the actual indexed project-plan foundation 95, its explicitly
selected two-coordinate recovery group 4, frame-child entry 8, sealed boundaries 60, inventory 54,
and DocValidatorSpec 17. The LifecycleSpec selection passed 158 cases on Windows and 160 on Linux.
`cabal build all` from both `core/` and `demo/` passed on both with package `-Werror`.

The independent oracle inspects the actual two-field record, its destination and pinned payload digest,
and the immediately following step boundary. Separate destination and payload substitutions change both
bytes and digest; raw projection bytes remain absent. The genuine two-step delivering plan persists and
recovers through public snapshot and recovered-profile APIs with exact canonical bytes and no protected
image mutation. Independently rehashed wrong-arity, complete legacy-v7 and header-only-v7 controls align
both lease and snapshot envelopes, yield the exact public malformed-record refusal, run neither callback
and preserve the complete key/version/bytes image after intentional corruption. The header-only case
retains the valid current body, so its result independently holds version refusal.

The actual accessor, framed header and golden bytes pin format 8; encoding and parsing share the new
record shape. Source inspection confirms no executable delivery coordinate in production definitions,
constructors or binding. The actual demo and every fixture use two arguments; the composition page and
rationale match, and verified removal allowed deletion of only the metadata ledger row. Changes occupy
three production modules and introduce no new named type. Complete phase gates remain owed at phase
closure; this evidence makes no live Docker or provider claim.

#### Remaining Work

None.

### Sprint 8.27: Lift contexts have one checked layer reconstruction [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`core/hostbootstrap-core/test/LiftContextSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

One checked reconstruction and view contract describes a legal stack of VM crossings followed by at
most one terminal container. These helpers retain their signatures when the context is sealed.

#### Deliverables

- Add `liftContextFromLayers :: [LiftLayer] -> Either String LiftContext`. Accept empty, VM-only and
  VM-prefix plus one last container lists without normalizing or reordering the original layers.
- Reject a VM after a container and a second container. A duplicate-container refusal takes precedence
  when both violations occur. The two descriptive refusals are stable and independently tested.
- Add ordinary `terminalContainer :: LiftContext -> Maybe ContainerLift` and
  `mapTerminalContainer :: (ContainerLift -> ContainerLift) -> LiftContext -> LiftContext`, backed by
  the same complete shape analysis. The view projects only a valid existing terminal container.
- While raw construction is public, the view returns Nothing for an invalid complete list. The map
  returns an invalid raw context or a valid VM-only context unchanged, without calling its function;
  it never normalizes a bad list into a valid route. Only the checked constructor establishes legality.
  A valid terminal map preserves every VM crossing and changes only that container.
- Reexport the retained helpers through Lift and update its actual export pin. Production work occupies
  only Context and Lift, introduces no new named type and adopts no independent consumer workflow.
- State the remaining public-constructor/record-update boundary in the composition page. Keep its
  standing ledger row through Sprint 8.39; these views do not claim final representation sealing.

#### Validation

On 2026-10-27 (America/Toronto), focused selections passed on native Windows 11 x86_64 and the
native-filesystem Ubuntu 24.04.4 x86_64 CPU container: LiftContextSpec 21, LiftSpec 71, sealed boundaries
60, inventory 54 and DocValidatorSpec 17. `cabal build all` from both `core/` and `demo/` passed on both
hosts, GHC 9.12.4/Cabal 3.16.1.0 with package `-Werror`.

Fifteen new context cases retain all six transport/mount/import controls. Seven legal shapes cover
empty, every VM provider, mixed and repeated crossings, container-only and composed terminal routes;
roundtrips hold exact equality, order and the established Show format. Six invalid shapes hold each
VM-after-container refusal, duplicate refusal and duplicate precedence. The whole invalid context has
no terminal projection and its map returns the original value without forcing an erroring mapper.
Empty and VM-only maps also leave that mapper uncalled; valid terminal maps retain the complete VM
prefix and change only the container. The actual Lift export pin includes the three retained helpers.

Production changes occupy only Context and Lift, about 50 added lines and no new type. One private
analysis serves construction and both views, with no normalization, throwing or replacement context on
invalid input. The composition page distinguishes checked admission from descriptive projection and
retains the public raw-constructor/record-update/old-appender gap. Its ledger row remains owned by
Sprint 8.39. These pure/build controls establish no provider effect or final representation sealing;
complete phase gates remain owed at phase closure.

#### Remaining Work

None.

### Sprint 8.28: Registry authentication adopts checked lift reconstruction [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Registry.hs`,
`core/hostbootstrap-core/test/RegistrySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

The one registryAuthLiftPlan workflow derives both nested routes through shared complete-context views
and checked singleton reconstruction, retaining its supported argument vectors and unsupported result.

#### Deliverables

- Read the original layer pair through liftLayers and require its complete terminalContainer view.
  Admit the container singleton and VM singleton through liftContextFromLayers before the existing
  two foldLeaf calls. An unsupported reconstruction returns Nothing, never a replacement context.
- Preserve the exact supported Incus, Lima and WSL credential script and argv, including their bare
  inner tool names. Preserve empty argv refusal, staged-delivery refusal and the single-VM-only shape;
  no argument-text policy or registry protocol change belongs to this adoption.
- Remove raw LiftContext construction and unchecked extraction only from this workflow. Production work
  occupies Registry alone and introduces no named contract. Keep existing independent literal-argv,
  credential non-leak and ordinary-fallback controls; add the three distinct unsupported controls.

#### Validation

On 2026-10-27 (America/Toronto), focused selections passed on native Windows 11 x86_64 and the
native-filesystem Ubuntu 24.04.4 x86_64 CPU container: the RegistrySpec selector 24, sealed boundaries
60, inventory 54 and DocValidatorSpec 17. The registry module contributes 23 cases; the selector also
includes the existing CoerceFinalizedServiceRegistrySpec compile-fail case. `cabal build all` from both
`core/` and `demo/` passed on both, GHC 9.12.4/Cabal 3.16.1.0 with package `-Werror`.

The three existing independent provider vectors retain exact credential-script and inner Docker argv.
Credential non-leak, unsupported-shape, ordinary-fallback and crossing-owner controls remain unchanged.
Three added cases hold empty-command, staged-delivery and valid multi-VM-prefix refusal in the actual
workflow. Complete pair validation and both checked singleton contexts feed the existing folds; source
review confirms no raw constructor or replacement context in that workflow. Source work occupies
Registry alone, about 15 changed lines and no new type/export or registry protocol change. The narrow
composition paragraph describes the checked adoption while retaining interpreter and raw-context gaps.
No live registry/provider behavior is claimed; complete phase gates remain owed at phase closure.

#### Remaining Work

None.

### Sprint 8.29: Reverse descent reconstructs a checked root-relative route [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Teardown/Internal.hs`,
`core/hostbootstrap-core/test/TeardownSpec.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`,
`core/hostbootstrap-core/test/SessionSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`DEVELOPMENT_PLAN/rationale.md`

#### Objective

The one reverse-descent route collector admits its complete root-relative layer sequence before
exposing a LiftContext, preserving plan order and the opaque prepared-descent boundary.

#### Deliverables

- In Teardown.Internal, read retained edge layers through ordinary liftLayers, keep the complete
  collection algorithm and order, then pass its result through liftContextFromLayers. No raw context
  construction, partial extraction, partially collected route or local fallback remains.
- Preserve parent/child/subtree/verb checks and cycle, missing-parent, missing-edge and duplicate-edge
  diagnostics. A checked-shape refusal becomes a descriptive Text refusal for the retained route.
  Production work occupies only Teardown.Internal and introduces no new named contract.
- Strengthen the existing public recursive down control through its existing native test proxy: record
  the actual received crossing argv in the fixture's owned temporary event artifact, then assert the
  root-relative Incus prefix precedes the inner Docker launch and reverse work remains child-first.
  Reuse the existing compiled proxy and registered family; add no executable or authority seam.
- Keep a scoped collector ownership/adoption control and existing public teardown/session regressions.
  The composition page states checked complete-route reconstruction and the actual evidence boundary.

#### Validation

On 2026-10-27 (America/Toronto), focused selections passed on native Windows 11 x86_64 and the
native-filesystem Ubuntu 24.04.4 x86_64 CPU container: RecursiveLifecycleSpec 9, TeardownSpec 41,
SessionSpec 127, LiftContextSpec 21, sealed boundaries 60, inventory 54 and DocValidatorSpec 17.
`cabal build all` from both `core/` and `demo/` passed on both hosts, GHC 9.12.4/Cabal 3.16.1.0 with
package `-Werror`.

The existing public down case records full argv received by the existing compiled native proxy in its
owned temporary crossing-events artifact. It preserves the up-event prefix, then independently pins the
VM launch and root-relative Incus-before-Docker launch, plus actual reverse callbacks container, VM,
root. The Linux fixture executes these authenticated public-process paths; Windows retains its declared
guest-row and canonical-root refusal. No family/leaf count, executable, Spec dispatch or public/private
authority API was added. This is proxy/process evidence, not live provider execution.

The scoped collector guard follows complete edge collection into checked reconstruction and its
returned continuation, checks the ordinary edge view and rejects raw context construction or a local
replacement route. It names the rationale entry. All previous parent/child/subtree/verb and graph
diagnostics and collection order remain. Malformed prepared-terminal runtime input is not claimed:
opaque rooted catalog admission rejects container descendants before producing that private package.
The public constructor's invalid-shape controls and actual caller ownership guard cover the stated
boundary without a synthetic producer.

Source work occupies Teardown.Internal alone, 9 added/6 removed lines and no new named contract. The
composition page and rationale distinguish complete-route checking, public proxy observations and the
remaining raw-context gap. Complete phase gates remain owed at phase closure.

#### Remaining Work

None.

### Sprint 8.30: Canonical lift binding reads the context layer view [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lifecycle/Plan.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

Canonical lifecycle binding reads the ordinary liftLayers view without depending on the LiftContext
constructor. The versioned representation is unchanged by this single-call-site adoption.

#### Deliverables

- Import LiftContext abstractly and liftLayers explicitly in Lifecycle.Plan. Render encodeLiftContext
  through that reader instead of a constructor pattern; no other production workflow changes.
- Preserve the lift-layers tag, list framing and order, all layer/member encoders, two-field delivery
  binding, canonical format 8 and parser behavior. No normalization, checked reconstruction or format
  transition belongs to this representation-read adoption.
- Reuse the actual canonical golden and independent coordinate/record-byte controls; add no test that
  merely repeats the getter implementation. Align the narrow composition description.

#### Validation

On 2026-10-27 (America/Toronto), focused selections passed on native Windows 11 x86_64 and the
native-filesystem Ubuntu 24.04.4 x86_64 CPU container: ReconcileSpec 106, the actual indexed project-plan
foundation 95, sealed boundaries 60, inventory 54 and DocValidatorSpec 17. `cabal build all` from both
`core/` and `demo/` passed on both, GHC 9.12.4/Cabal 3.16.1.0 with package `-Werror`.

Existing actual canonical controls retain determinism, delimiter framing, step order, provider and
implementation/reverse coordinates, exact config digest, separate destination/payload byte-and-digest
sensitivity and the independent two-field record boundary. The complete exact-root golden, format-8
header/accessor, callback exclusions, exact binding drift and four persisted shape/version recovery
cases retain their values. No getter-mirroring test was added.

Source work occupies Lifecycle.Plan alone, 3 added/2 removed lines. The abstract type and explicit
reader feed the same taggedList, layer/member encoders and retained list. Parser, version 8, counts,
order, bytes and digests remain unchanged. The narrow composition note matches this read adoption;
it claims no new admission policy or representation sealing. Complete phase gates remain owed at
phase closure.

#### Remaining Work

None.

### Sprint 8.31: The child command reads its direct-container target through the layer view [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/Child.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`, `core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

The one Command.Child targetBinary helper reads its exact direct-container distinction through the
ordinary context layer view, preserving the existing target text.

#### Deliverables

- Import LiftContext abstractly with liftLayers. Give the existing local targetBinary helper its
  concrete LiftContext-to-Text signature and inspect that reader instead of a constructor pattern.
- Preserve exactly one ViaContainer as the empty-target case and every other layer shape as the same
  guest binary coordinate. Change no route admission, marker, protocol, callback or placement policy.
- Keep this adoption to Command.Child alone. Reuse the actual public recursive and surrounding
  authenticated-child controls; no test-only target selector or implementation-mirroring test is needed.
  Align the narrow composition description and keep the raw context gap owned by Sprint 8.39.

#### Validation

On 2026-10-27 (America/Toronto), focused selections passed on native Windows 11 x86_64 and the
native-filesystem Ubuntu 24.04.4 x86_64 CPU container: RecursiveLifecycleSpec 9, HandoffSpec 113,
the actual indexed project-plan foundation 95, sealed boundaries 60, inventory 54 and DocValidatorSpec
17. `cabal build all` from both `core/` and `demo/` passed on both, GHC 9.12.4/Cabal 3.16.1.0 with
package `-Werror`.

The Linux public-up fixture reaches Command.Child in the VM child and its nested direct-container
route; sanitization requires the empty target for that launch. Windows retains the declared guest-row
and canonical-root refusal. Existing storeless-child, authenticated-process, marker and route guards
remain applicable. The initial root-to-VM decision is a different helper, so this result is not claimed
as runtime coverage of Command.Child's fallback arm. Source review holds the identical fallback guest
coordinate and exact singleton distinction.

The only production changes are the abstract context import, ordinary reader and typed local helper,
6 added/3 removed lines in Command.Child. No protocol, marker, callback, placement, authority API or
new type changes. Existing meaningful tests were reused without getter-mirroring additions. The
composition note states the actual branch boundary and keeps raw representation sealing owed by
Sprint 8.39. Complete phase gates remain owed at phase closure.

#### Remaining Work

None.

### Sprint 8.32: Forward lifecycle entry reads its child target through the layer view [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

The forward coordinator's one targetBinary helper reads its exact singleton-container distinction
through the ordinary layer view. Both existing callers retain the same target-selection behavior.

#### Deliverables

- Adopt liftLayers in this helper only, with its concrete LiftContext-to-Text signature. Preserve
  exactly one ViaContainer as empty target and every other shape as Text.pack (selfRefInVMPath self).
- Retain normal launchChild and failed-Up launchFailed caller behavior; this is one helper adoption,
  not a claim that the helper has only one caller. Keep the independent reverse-root helper untouched
  until Sprint 8.33 and retain the constructor import it still requires.
- Strengthen the existing public-up fixture using the native proxy's recorded events. Pin the literal
  root Incus vector and guest binary coordinate derived from the installed fixture identity, then the
  immediate Docker vector and image entry marker. Use no fold/renderer as the expected-value oracle.
  Reuse the existing observer, leaf, family and executable.
- Keep source work to LifecycleEntry alone and align the narrow composition description. No protocol,
  placement, admission or final context-sealing change belongs to this adoption.

#### Validation

On 2026-10-27 (America/Toronto), focused selections passed on native Windows 11 x86_64 and the
native-filesystem Ubuntu 24.04.4 x86_64 CPU container: RecursiveLifecycleSpec 9, HandoffSpec 113,
the indexed project-plan foundation 95, sealed boundaries 60, inventory 54 and DocValidatorSpec 17.
`cabal build all` from `core/` and `demo/` passed on both with GHC 9.12.4/Cabal 3.16.1.0 and `-Werror`.

The existing public-up leaf observes exactly the actual native proxy's root Incus argv and guest
coordinate derived independently from installed fixture identity, then the immediate Docker argv and
image entry marker. No fold oracle, helper, executable, leaf or family was added. The Linux fixture
executes those public-process observations; Windows keeps its declared guest-row/root refusal. The
nested container launch belongs to Command.Child, and is not relabelled as this helper's direct-root
container arm. Existing failed-Up/recovery cases regress the shared helper's second caller.

Source review holds both original target branches, both callers and the independent reverse helper.
The production patch is 5 added/2 removed lines in LifecycleEntry alone; no protocol, placement,
authority API or new type changes. The constructor import remains for the reverse helper. The
composition note states these distinctions and the raw-context gap. Complete phase gates remain owed
at phase closure.

#### Remaining Work

None.

### Sprint 8.33: Reverse lifecycle entry reads its terminal target through the layer view [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Command/LifecycleEntry.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

The independent reverse-root target selector reads the complete retained route's last layer through
the ordinary view, preserving root-relative target selection for Down, Destroy and nested descendants.

#### Deliverables

- Give this local targetBinary its LiftContext-to-Text signature and read reverse (liftLayers context).
  Preserve any terminal ViaContainer as empty target and the same SelfRef guest coordinate otherwise;
  do not substitute an exact-singleton test or introduce a new validation policy.
- Remove the module's final constructor dependency and import LiftContext abstractly. Keep the already
  adopted shared forward-coordinator helper and both of its callers unchanged.
- Change only this helper/import in LifecycleEntry. Reuse existing public-down observations of both
  meaningful branches, destroy/repeated-reverse and surrounding lineage/sanitization controls; add no
  getter-mirroring test or private authority seam. Align the narrow composition note.

#### Validation

On 2026-10-27 (America/Toronto), focused selections passed on native Windows 11 x86_64 and the
native-filesystem Ubuntu 24.04.4 x86_64 CPU container: RecursiveLifecycleSpec 9, HandoffSpec 113,
the indexed project-plan foundation 95, sealed boundaries 60, inventory 54 and DocValidatorSpec 17.
`cabal build all` from `core/` and `demo/` passed on both with GHC 9.12.4/Cabal 3.16.1.0 and `-Werror`.

Existing public down observations independently hold the singleton VM's exact guest coordinate and the
root-relative composed Incus/Docker image marker. Both meaningful reverse-selector branches execute on
the Linux fixture; destroy and repeated reverse cases regress the same recursive caller. Windows
retains its declared guest-row/root refusal. Existing lineage and sanitization guards need no change.

The production patch is 4 added/3 removed lines in LifecycleEntry alone: a typed local helper reads
reverse (liftLayers context), preserving the last-layer container rule and identical SelfRef fallback.
The module's final constructor import is abstract; the forward-coordinator helper and both callers
are unchanged. No tests, authority seams, protocol, placement or new type changes were needed. The
composition note matches the root-relative selector and retains final sealing for Sprint 8.39.
Complete phase gates remain owed at phase closure.

#### Remaining Work

None.

### Sprint 8.34: Immediate handoff reads the route layer view [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Handoff/Internal.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md`

#### Objective

The one immediate-edge handoff predicate reads cardinality through ordinary liftLayers, preserving
the exact-one-layer recheck on both the retained raw route and stripped launch route.

#### Deliverables

- Import LiftContext abstractly with liftLayers in ProjectPlan.Handoff.Internal. Retain the existing
  oneLayer signature and classify the reader's list: exactly one layer is True, every other arity False.
  No reconstruction, normalization or additional route policy belongs to this adoption.
- Preserve both caller rechecks, all preceding catalog/frame/configuration/payload/digest conditions,
  thirteen-field retention and forcing, callback boundaries and hidden inert ownership. Production
  changes occupy this one predicate/import in one module and introduce no new contract.
- Adapt the existing source cardinality pin and remeasure the frozen module's actual SHA-256 and
  significant line count after the reviewed reader-only change. Retain the whole-module freeze,
  hard below-400-line boundary and all other ownership/admission/forcing/import guards.
- Reuse actual public accepted-edge traversal and existing surrounding controls. Add no arbitrary
  catalog producer or getter-mirroring test. Align the narrow composition description.

#### Validation

On 2026-10-27 (America/Toronto), focused selections passed on native Windows 11 x86_64 and the
native-filesystem Ubuntu 24.04.4 x86_64 CPU container: RecursiveLifecycleSpec 9, HandoffSpec 113,
the indexed project-plan foundation 95, sealed boundaries 60, inventory 54 and DocValidatorSpec 17.
`cabal build all` from `core/` and `demo/` passed on both with GHC 9.12.4/Cabal 3.16.1.0 and `-Werror`.

The reader predicate retains exact-one cardinality and both raw/stripped caller rechecks. All prior
catalog/frame/configuration/payload/digest conditions, thirteen-field retention/forcing, callbacks,
inertness, hidden ownership and cycle/import checks remain. The module freeze is retained and
independently remeasured: SHA-256 e56df2633605bd76186b246881ff7b2a8f911c9f3c6cdd431008c7e63819c29d,
339 significant lines, with the existing hard below-400 boundary. Reversing only the intended import
and predicate edits in memory reproduces the prior pinned bytes/count; no other module bytes changed.
The later size-guard task's numeric reference is described without implementing that separate task.

Source work occupies ProjectPlan.Handoff.Internal alone, 4 added/3 removed lines and no new contract.
Public up executes admitted catalog edges on the Linux fixture; Windows retains its declared refusal.
Zero/multiple private catalog rechecks are source evidence, because earlier projection prevents those
malformed opaque inputs; no artificial runtime producer was added. The composition note keeps that
boundary explicit. Complete phase gates remain owed at phase closure.

#### Remaining Work

None.

### Sprint 8.35: Finalized child projection adopts shared context views [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/ProjectPlan/Projection/Internal.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`, `core/hostbootstrap-core/test/HandoffSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

The one finalized-child-projection admission workflow reads context shape through ordinary views and
uses the shared terminal map only within its existing exact-single-container stripping boundary.

#### Deliverables

- Import LiftContext abstractly with liftLayers and mapTerminalContainer. Remove raw constructor
  patterns and reconstruction from this workflow without introducing a new parser, policy or type.
- Preserve selectEdge and expectedChildContext exact-single-layer distinctions, the original raw-route
  value, child/config/frame/descriptor/ancestry checks and every refusal order and diagnostic.
- Preserve both singleton-container guards before direct-host rebasing in selectedLiftMatches, and the
  ordinary equality fallback. Keep singleton-only payload comparison and its existing other-shape result.
- In withoutConfigDelivery, require the original singleton ViaContainer shape before invoking
  mapTerminalContainer to clear only clConfigDelivery. All other shapes remain exactly unchanged;
  a VM-prefix-plus-container must not gain broader stripping behavior.
- Adapt only existing constructor-syntax pins and remeasure the projection module's full frozen SHA-256
  and exact significant-line count. Retain all other ownership, refusal, field and callback guards.
  Reuse meaningful existing controls instead of adding a getter mirror or authority producer.
- Keep production work to Projection.Internal, within the sprint budget, and align the narrow
  composition note. Final raw-context sealing remains owned by Sprint 8.39.

#### Validation

On 2026-10-27 (America/Toronto), focused selections passed on native Windows 11 x86_64 and the
native-filesystem Ubuntu 24.04.4 x86_64 CPU container: RecursiveLifecycleSpec 9, HandoffSpec 113,
the indexed project-plan foundation 95, LiftContextSpec 21, sealed boundaries 60, inventory 54 and
DocValidatorSpec 17. `cabal build all` from `core/` and `demo/` passed on both with GHC 9.12.4,
Cabal 3.16.1.0 and `-Werror`.

The six-site projection adoption occupies one production module, 51 added/44 removed lines and no
new contract. The whole-module freeze is retained and independently measured as SHA-256
252742d3ba09fa228f8ddc17ab7c1a099cc2bd0810a8aab0a1bfc2ccd9e17c8a and 281 significant lines.
Reversing only the intended import and six implementation edits in memory reproduces the prior
pinned bytes and 274-line count. All other ownership, admission, forcing, refusal and direct-rebase
guards remain. Both direct-rebase operands and delivery stripping retain exact singleton-container
guards; every other strip shape is the unchanged original value.

Linux public up traverses Host-to-VM and VM-to-container projection and payload stripping. Windows
retains its declared guest-row/root refusal. Direct-container rebasing and most malformed/refusal
branches remain source-guard evidence; no artificial input producer for opaque owners was added.
The composition note records those limits. Complete phase gates remain owed at phase closure.

#### Remaining Work

None.

### Sprint 8.36: Lifecycle process routes reconstruct checked sanitized contexts [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Handoff/Process/Route.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

The lifecycle process-route derivation reads shared context views and admits its already validated,
sanitized layer sequences through the checked constructor without changing route policy.

#### Deliverables

- Import LiftContext abstractly with liftLayers, mapTerminalContainer and liftContextFromLayers.
  Inspect the ordinary layer view in the existing six branch order: singleton container, three
  singleton VM variants, composed route and empty route. Preserve the same validators and errors.
- Use mapTerminalContainer to clear terminal delivery. On malformed raw multiple-container input,
  preserve rejection by the existing composed grammar before terminal delivery policy is inspected;
  do not add early whole-shape parsing that changes name, path or grammar refusal precedence.
- Have the existing private folded helper accept sanitized [LiftLayer]. Each branch passes its
  already validated layers; folded performs the one checked reconstruction, reports an impossible
  shape failure descriptively through routeFailure, then uses the same lifecycle leaf and fold.
- Preserve channel interactivity, phase/field grammar, mount and override policy, provider argv,
  opening order, caller privacy and all diagnostics. Remove raw context construction and patterns
  from this one workflow, with no new type, public seam or independent policy.
- Retain both existing hard below-400-significant-line guards on Route. Adapt only the affected
  constructor/folded source pins, reuse existing public accepted-route and refusal controls and
  align the narrow composition description and existing source Haddock.

#### Validation

On 2026-10-27 (America/Toronto), focused selections passed on native Windows 11 x86_64 and the
native-filesystem Ubuntu 24.04.4 x86_64 CPU container: RecursiveLifecycleSpec 9, HandoffSpec 113,
the indexed project-plan foundation 95, LiftContextSpec 21, sealed boundaries 60, inventory 54 and
DocValidatorSpec 17. `cabal build all` from `core/` and `demo/` passed on both with GHC 9.12.4,
Cabal 3.16.1.0 and `-Werror`.

One production module contains 38 added/37 removed lines, with 377 significant lines under both
retained hard below-400 guards. Shared layer inspection and terminal mapping replace raw context
construction; the existing private folded helper checks only already sanitized layer sequences.
All frame/phase/path/name/container/grammar validators, refusal priority, interactivity, provider
vectors, opening order, privacy and nominal roles remain. The new reconstruction error has no
fallback and is unreachable after the successful closed grammar. Independent pre-sprint comparison
confirms the change is confined to the intended import, map, branch view, reconstruction and Haddock.

The native Linux process fixture observes actual Incus/Docker command vectors across public up,
down, failed-up and recovery paths. Windows retains its declared guest-row/root refusal. Lima/WSL
and private malformed-route policy remain source or lower-layer vector evidence; invalid raw
multiple-container routes still refuse at the first nonterminal container after preceding VM-name
validation, before later terminal policy. Source pins retain both size caps and every unaffected
guard. The composition note records these evidence limits. Complete phase gates remain owed at closure.

#### Remaining Work

None.

### Sprint 8.37: Provider shell dispatch reconstructs a checked singleton route [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/test/ProviderSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`

#### Objective

The independent vmShellArgs workflow admits its singleton layer through shared checked
reconstruction and preserves the existing VM-only dispatch contract.

#### Deliverables

- Import LiftContext abstractly and liftContextFromLayers directly from Context. Retain the first
  empty-argv refusal; for nonempty argv, checked-reconstruct one layer into Maybe, then use the
  same RawCmd fold, DispatchTool result and VM-only guard. Failed reconstruction returns Nothing.
- Preserve every supported provider vector and container refusal. Add no partial extraction,
  fallback route, public export or new type. Provider VM builders retain their current signatures
  until Sprint 8.38; only this independent workflow changes.
- Extend the existing ProviderSpec interpreter case with literal Incus, Lima and WSL vectors,
  including a single unchanged argument containing spaces and shell metacharacters. Assert empty
  command refusal for each VM and nonempty-command refusal for both container placements. Retain
  the Windows mount assertion and avoid a shared-renderer oracle or unrelated executable policy.
- Align the narrow composition description. The raw-context boundary remains open until 8.39.

#### Validation

On 2026-10-27 (America/Toronto), native Windows 11 x86_64 and the native-filesystem Ubuntu
24.04.4 x86_64 CPU container passed ProviderSpec 27, LiftContextSpec 21, sealed boundaries 60,
inventory 54 and DocValidatorSpec 17. cabal build all from core/ and demo/ passed on both with
GHC 9.12.4/Cabal 3.16.1.0 and package -Werror.

The one-module production change is 5 added/3 removed lines: abstract type import, direct checked
constructor import and Maybe reconstruction before the unchanged fold and VM-only result guard.
The first empty-command refusal remains first. No new public export, type or fallback was added.

The existing interpreter case now independently pins actual Incus, Lima and WSL argv, each carrying
the same single spaces/metacharacters argument, and refuses empty commands for all three. Both
container placements refuse a nonempty command. Original WSL and native Windows mount assertions
are retained exactly; no test leaf or conditional family changed. Every singleton layer passes shared
shape validation, so its impossible failure branch is a source obligation, not fabricated runtime
coverage. The composition note states that boundary. Complete phase gates remain owed at closure.

#### Remaining Work

None.

### Sprint 8.38: VM-only lift builders retain an opaque open stack [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider/Ownership.hs`,
`core/hostbootstrap-core/test/LiftContextSpec.hs`,
`core/hostbootstrap-core/test/LiftSpec.hs`,
`core/hostbootstrap-core/test/ProviderSpec.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeVMStack.hs`,
`core/hostbootstrap-core/test/EffectSpec.hs`,
`core/hostbootstrap-core/test/CLISpec.hs`,
`core/hostbootstrap-core/test/ChainSpec.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`,
`core/hostbootstrap-core/test/RegistrySpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`

#### Objective

One opaque VMStack holds open VM crossings; existing provider construction and all actual builder
callers adopt that single contract immediately.

#### Deliverables

- Introduce only opaque VMStack, with emptyVMStack and vmContext. Retype inVM, inLimaVM and
  inWsl2VM to append VM crossings to VMStack in their existing order; vmContext closes a VM-only
  stack. No public constructor or additional layer vocabulary admits a container into the open stack.
- Adapt the actual providerLiftContext and owned-guest construction sites in Provider and
  Provider.Ownership. Import the new names directly from Context so this stage occupies exactly
  those three production modules; the Lift facade adds no new exports at this stage.
- Keep localContext as a closed LiftContext and the current container builder until Sprint 8.39.
  The raw representation and container appender remain an explicit open boundary.
- Adapt all existing VM-builder callers in the declared test files: close VM-only stacks with
  vmContext, including prefixes consumed by the current container appender. Retain malformed raw
  runtime controls through the still-public raw context where the VM-builder signature now refuses
  their expression; final constructor sealing and its genuine terminality fixture belong to 8.39.
- Register Context in the actual AuthoritySpec local-sealed supplement and add its exact export pin.
  Retain the unchanged Lift facade pin, module homes and existing ownership boundaries. Verify
  open-stack ordering and all provider closures without introducing a second public construction seam.
- Create and register genuine ForgeVMStack under § HH after its real private constructor exists.
  Apply that actual constructor to a well-typed container-layer list, require the actual public-GHC
  privacy diagnostic, and establish that exposing only the constructor makes the unchanged fixture
  compile. Add the fixture path to Implementation once it exists.
- Narrow composition and the core-library context row: VMStack is opaque now, while LiftContext,
  the container appender and descriptive target records retain their current construction boundary.

#### Validation

On 2026-10-27 (America/Toronto), complete cabal test all from core/ passed on native Windows 11
x86_64 (3,299 tests, 511.46 seconds) and the native-filesystem Ubuntu 24.04.4 x86_64 CPU container
(3,301 tests, 392.30 seconds). cabal build all from core/ and demo/ passed on both with GHC 9.12.4,
Cabal 3.16.1.0 and package -Werror. Both provider-live suites reported their declared not-requested
Unsupported result; these runs establish no live-provider acceptance.

The one new opaque VMStack contract occupies Context, Provider and Provider.Ownership, 27 added/
12 removed production lines. All four actual production VM-builder sites close through vmContext;
new names are imported directly from Context and the Lift facade export surface is unchanged.
Ten test callers adopt the new signatures. Three new open-stack cases hold empty closure, mixed
outermost-first order and each appender on an existing prefix. Existing argv, negative raw-context
and conditional-family controls remain; raw context/container construction stays open until 8.39.

The real public-only native GHC rejects ForgeVMStack with GHC-01928: Illegal term-level use of the
type constructor VMStack. The same unchanged fixture compiles successfully against a temporary copy
of the actual Context module differing only by exporting its real constructor; stderr is empty.
The fixture therefore supplies a well-typed container layer and fails specifically for privacy.
Context input SHA-256 is bda843ec76f4c71afe1bf99f881aca61584b6f70dd5ca573b987994493e2104d;
fixture SHA-256 is d4cd929ae38d6ceb4d3a3df857033a2b8bed0cb542b03f211128c0017e682e8c.
The proof leaves worktree source unchanged and automatically removes its temporary artifacts.

Context is in the actual local-sealed supplement and has an exact export pin; the existing Lift pin
is retained. In-memory reversal of just the supplement, export-row and fixture-registration patches
reproduces all three prior file hashes. The full suites validate the registered compiler expectation,
inventories and aligned architecture pages. Complete phase-closure gates remain owed.

#### Remaining Work

None.

### Sprint 8.39: A container closes the lift context by type [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
`demo/src/HostBootstrapDemo/Commands.hs`,
`core/hostbootstrap-core/test/LiftContextSpec.hs`,
`core/hostbootstrap-core/test/LiftSpec.hs`,
`core/hostbootstrap-core/test/CompileFailSpec.hs`,
`core/hostbootstrap-core/test/compile-fail/VMLayerAfterContainer.hs`,
`core/hostbootstrap-core/test/compile-fail/RecordUpdateLiftLayers.hs`,
`core/hostbootstrap-core/test/compile-fail/ForgeLiftContext.hs`,
`core/hostbootstrap-core/test/AuthoritySpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`,
`core/hostbootstrap-core/test/EffectSpec.hs`,
`core/hostbootstrap-core/test/ChainSpec.hs`,
`core/hostbootstrap-core/test/HandoffSpec.hs`,
`core/hostbootstrap-core/test/ReconcileSpec.hs`,
`core/hostbootstrap-core/test/RecursiveLifecycleSpec.hs`,
`core/hostbootstrap-core/test/RegistrySpec.hs`,
`core/hostbootstrap-core/test/ProjectPlanSpec.hs`,
`demo/test/CommandsSpec.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`,
`DEVELOPMENT_PLAN/rationale.md`, `DEVELOPMENT_PLAN/development_plan_standards.md`,
`documents/engineering/registry_credentials.md`,
`DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md`,
`DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md`

#### Objective

LiftContext is opaque and stores its VMStack plus one optional terminal container. The fold,
requested stdin, landed frame and delivery workflow consume that same structure.

#### Deliverables

- Seal LiftContext in both Context and the Lift facade. Provide ordinary liftLayers and liftVMStack
  readers rather than a public record label. Retain exact checked-list legality, refusal priority and
  diagnostics, ordered equality and record-style Show, including high-precedence nested parentheses.
- Retype inContainer to close a VMStack; localContext closes emptyVMStack. Expose the existing stack
  contract and ordinary readers through Lift. No new type contract or unchecked producer is added.
- Use the actual prefix vmContext (liftVMStack context) and terminalContainer consistently for folding,
  staged dispatch, stdin, frame and delivery. Remove malformed raw-context guards and the impossible
  missing-projection branch after sealing. Preserve all actual delivery argv, explicit input, archive,
  failure, cancellation and cleanup behavior without partial parsing, fallback or raw reconstruction.
- Adapt the actual three demo container constructions and two remaining patterns. Production work
  occupies only Context, Lift and demo; earlier consumer adoptions already use the final shared views.
- Adapt every declared test caller and retain all reachable literal argv, frame and delivery controls.
  Reconcile malformed raw-context assertions with exact checked-list refusals and the type proof;
  do not counterfeit an opaque context or claim an unreachable runtime branch was executed. Add a
  literal high-precedence/nested Show control and preserve legal unsupported registry behavior.
- Create and register genuine VMLayerAfterContainer: the inner inContainer c emptyVMStack is valid,
  and applying inVM vm to that closed context fails for VMStack versus LiftContext. Capture the
  actual public-GHC diagnostic and separately compile the legitimate inner closure. Add its fixture
  path to Implementation once it exists; retain ForgeVMStack and add genuine ForgeLiftContext
  using its actual well-typed private constructor. Capture its public privacy rejection and
  successful unchanged-fixture compile with only that constructor exposed in a module copy. Add a
  genuine RecordUpdateLiftLayers fixture using the in-scope ordinary getter as a record label:
  it must fail with the actual missing-record-field diagnostic, preventing a public field update from bypassing
  opacity. Capture the actual diagnostic and verify the same fixture against the actual earlier
  record-based Context module copy, where that boundary permits the update.
- Update actual Context/Lift export pins and constructor-boundary controls. Align composition,
  core-library, registry-credentials and standards U claims; add the named representation rationale.
  Remove the raw-context ledger row only after both facades hide the constructor and liftLayers
  is ordinary. Align the already implemented HH diagnostic-matcher description and future-plan
  API references without implementing their later work. The lifecycle-renderer gap remains in 8.40.

#### Validation

On 2026-10-27 (America/Toronto), native Windows 11 x86_64 and the native-filesystem Ubuntu 24.04.4
x86_64 CPU container passed LiftSpec 70, LiftContextSpec 25, RegistrySpec 24 (including its existing
compile-fail name match), ChainSpec 48, EffectSpec 44, HandoffSpec 113, indexed project-plan 95,
ReconcileSpec 106, RecursiveLifecycleSpec 9, each of the four named compiler fixtures 1, sealed
boundaries 60, inventory 54 and DocValidatorSpec 17. The demo CommandsSpec selection passed all
80 cases on each. cabal build all from core/ and demo/ passed on both with GHC 9.12.4/Cabal 3.16.1.0
and package -Werror.

The final representation change occupies Context, Lift and demo only. Comparing actual pre-sprint
bytes retained in the verified Linux mirror with the frozen worktree measures 80 added/58 removed
lines, 138 total, across those three modules. Both facades hide the positional constructor and expose
ordinary readers; the retained prefix and optional terminal drive fold, stdin, frame and staged
delivery. The real delivery stages, explicit input/archive/cleanup and all provider renderers are
unchanged. Equality and record-style Show, including precedence 10/11, suffix and nested Just, pass.

The actual public-only native compiler rejects VMLayerAfterContainer with GHC-83865 (expected
VMStack, actual LiftContext), RecordUpdateLiftLayers with GHC-22385 (missing record field liftLayers),
and ForgeLiftContext with GHC-01928 (private constructor). Genuine ForgeVMStack remains rejected.
Legal empty/VM/container composition compiles. The unchanged record-update fixture compiles
against the unmodified actual earlier record module, and the unchanged constructor-forgery fixture
compiles when only that constructor is exported in a temporary copy of the actual final module.
All positive controls exit 0 with empty stderr; proof scratch artifacts are removed automatically,
and no worktree source is mutated. Final Context input SHA-256 is
f766ad5b67406bd5a60b972cf56ad446ed1d43d56823bada557e6eed28725fc6.

All ten affected test files retain legal argv/frame/delivery and registry-unsupported controls.
The former malformed-delivery runtime leaf's three uninhabitable contexts are replaced by the
existing six exact checked-list refusal cases and the compiler terminality proof; no unreachable
runtime-refusal coverage is claimed. Context invalid-list tests retain every exact refusal/priority
while dropping impossible invalid closed-value view/map assertions. Delivery cases change 36 to 35,
context cases 24 to 25; conditional families are unchanged. No unchecked fixture producer is added.

The raw-context ledger row is removed after verifying both facades and the ordinary non-record
reader; the renderer row remains. Architecture/registry/standards U/rationale claims align. HH's
stale matcher paragraph now describes the already implemented Phase 5.10 contract; future plan
references use the real API without implementing their later tasks. Closing metadata and these
documentation-only corrections are checked again by DocValidatorSpec on both hosts before 8.40
source work starts. Complete phase gates and all four host-static commands remain owed.

#### Remaining Work

None.

### Sprint 8.40: The lifecycle crossing is a placement of the one VM renderer [Done]

**Status**: Done
**Implementation**: `core/hostbootstrap-core/src/HostBootstrap/Lift/Context.hs`,
`core/hostbootstrap-core/src/HostBootstrap/Lift.hs`, `core/hostbootstrap-core/test/LiftContextSpec.hs`,
`core/hostbootstrap-core/test/LiftSpec.hs`,
`core/hostbootstrap-core/test/SealedExportInventory.hs`
**Substrates**: linux-cpu
**Docs to update**: `documents/architecture/composition_methodology.md`,
`documents/architecture/hostbootstrap_core_library.md`,
`DEVELOPMENT_PLAN/legacy_tracking_for_deletion.md`,
`DEVELOPMENT_PLAN/development_plan_standards.md`, `DEVELOPMENT_PLAN/rationale.md`,
`documents/architecture/readiness.md`

#### Objective

A VM crossing has one renderer per provider (§ LL). Working directory, non-interactive execution
and root elevation are placement data. Ordinary and lifecycle leaves use the same renderer/fold,
and every WSL crossing delivers its unchanged argv through --exec.

#### Deliverables

- Context and the Lift facade export VMPlacement with placementWorkdir :: Maybe FilePath,
  placementNonInteractive :: Bool and placementElevated :: Bool, plus foldPlacement
  (VMPlacement Nothing False False) and lifecyclePlacement (VMPlacement (Just "/") True True).
- execVMArgsAt renders exec <vm>, optional --cwd <dir>, optional -T for non-interactive placement,
  -- and the unchanged argv. Incus already runs as root, so its elevation flag adds no argument.
- shellVMArgsAt renders shell, optional --workdir <dir>, <vm> --, the elevation prefix and argv.
  wslExecArgsAt renders -d <distro>, optional --cd <dir>, --exec, the same prefix and argv. On both,
  the whole sudo prefix exists only when elevated: sudo, optional -n when non-interactive, then -H.
  Workdir, non-interactivity and elevation remain independent placement fields.
- Existing wrappers preserve exact ordinary vectors: execVMArgs and wslExecArgs use foldPlacement;
  shellVMArgs uses foldPlacement with placementElevated = True because Lima's default user is not
  root. Direct shellVMArgsAt foldPlacement has no sudo prefix; the wrapper retains sudo -H.
- foldLeaf selects lifecyclePlacement for LifecycleProcessCmd and foldPlacement otherwise, once
  per leaf. Every outer and nested Lima renderer receives that placement with elevation enabled
  for its provider-root default; Incus/WSL receive the selected placement unchanged. One insideVM
  fold renders every crossing. Delete the six lifecycle build equations and insideLifecycleVM;
  Lift.hs contains none of the --cwd, --workdir, --cd, -T or sudo argument literals.
- Keep the final opaque context, shared prefix/terminal and delivery stages unchanged. Production
  work occupies only Context and Lift. Both module/fold descriptions state the one-renderer
  boundary, and exact public export pins include only the declared placement/rendering API.
- Pin independent literal argv for all eight combinations of optional workdir, non-interactivity
  and elevation on all three renderers, plus fold/lifecycle defaults and ordinary wrappers. Pin
  single/composed WSL lifecycle --exec, nested WSL-to-Incus placement and a&b;$c as one unchanged
  argument on every provider; retain ordinary Lima sudo -H vectors and add the source absence guard.
- Align composition/core-library and normative WSL examples with actual renderers and keep the
  distinct lifecycle authority channel explicit. Remove the renderer ledger row only after source
  deletion is verified, and align the named representation rationale for the absence guard.
  Align readiness and the completed native-runner/capacity inventory with the actual argv path.

#### Validation

On 2026-10-28, native Windows 11 x86_64 and the native-filesystem Ubuntu 24.04.4 x86_64 CPU
container passed focused LiftContextSpec 34, LiftSpec 74, sealed/export 60, inventory 54 and
DocValidatorSpec 17 selections. cabal build all from core/ and demo/ passed on both with
GHC 9.12.4/Cabal 3.16.1.0 and package -Werror.

The eight independent workdir/non-interactivity/elevation vectors, exact ordinary wrappers,
single/composed WSL --exec, nested WSL-to-Incus placement, all-provider metacharacter arguments
and absence guards passed. Independent snapshot comparison measures 88 added/47 removed lines,
135 total, across Context and Lift only. The new public export pins match both facades; reversing
only their intended edits reproduces the previous inventory bytes. The 8.39 context/delivery
structure and stages are unchanged. Implementation and focused validation are complete.

The complete, unfiltered core gate passed on 2026-10-28: native Windows 3,315 cases in 582.41
seconds; native-filesystem Linux 3,317 in 482.35 seconds. The full Linux demo workspace passed
its 164 demo cases and 3,317 dependency core cases. Python code checks passed and all 376 Python
tests passed with 100% coverage. Provider-live suites reported their declared not-requested refusal.

The full Windows demo workspace failed in its demo driver while Tasty printed an existing section
sign in a case name: stdout commitBuffer could not encode U+00A7. Its dependency core suite passed
3,315 cases. This is an independently scoped test-driver encoding defect; the VM-renderer contract
and its full core gate passed. Sprint 8.41 records the repaired driver and completed rerun of the identical full phase and
four-command host-static gates below. The initial demo run remains explicitly failed; no test name
or test output was suppressed to obtain the repaired passing result.

#### Remaining Work

None.

### Sprint 8.41: The demo suite establishes UTF-8 before running [Done]

**Status**: Done
**Implementation**: `demo/test/Spec.hs`
**Production modules**: none (test driver only)
**Sprint budget**: no production Haskell or new type contract; one driver entry and one runtime assertion.
**Substrates**: linux-cpu
**Docs to update**: `DEVELOPMENT_PLAN/development_plan_standards.md`,
`DEVELOPMENT_PLAN/phase-24-worked-demo.md`, `documents/engineering/testing.md`,
`documents/languages/haskell.md`

#### Objective

The demo test driver establishes UTF-8 before locale-dependent source reads or the first demand of
its standard handles, so the same complete host-static gate passes on Windows and Linux.

#### Deliverables

- Import setLocaleEncoding and utf8 from GHC.IO.Encoding and make setLocaleEncoding utf8 the first
  IO action in main, before the unchanged defaultMain tree. Retain the threaded-RTS component check
  and every existing case, including the Unicode ConfigSpec case name that exposed this failure.
- Add the runtime locale assertion already specified by the demo plan: textEncodingName from
  getLocaleEncoding is UTF-8 inside the suite. No source-token mirror, process wrapper, output
  suppression, case renaming or platform-specific skip replaces the actual reporter regression.
- Own only the locale-initialization/assertion obligation from the later demo test sprint. Leave its
  declaration-scoping, pure-extraction and unrelated test work Planned there; remove duplicate
  locale ownership and align the current encoding claims in standards, testing and Haskell docs.
- Run the complete phase gate and every canonical host-static command in its original spelling.
  The repaired plain cabal test all from demo/ must print and pass the existing Unicode case on
  native Windows; full core/demo gates run on both available hosts and Python checks/tests run
  from the native repository root. Record actual results before Phase 8 closes.

#### Validation

On 2026-10-28, the driver repair passed the same complete, unfiltered host-static routes with
GHC 9.12.4/Cabal 3.16.1.0:

- Native Windows 11 x86_64: cabal test all from core/ passed 3,315 cases in 488.14 seconds in the
  final serial run; the provider-live suite reported its declared not-requested Unsupported result.
- Native Windows demo workspace: plain cabal test all passed all 165 demo cases in 6.21 seconds
  and its dependency core suite's 3,315 cases in 589.18 seconds. The original ConfigSpec case
  "an orchestrator cannot be given a service role at all (§ 15.9)" printed and passed, and the new
  actual locale-state case passed. The threaded-RTS component contract is unchanged.
- Native-filesystem Ubuntu 24.04.4 x86_64 CPU container: core/ passed 3,317 cases in 606.75 seconds;
  the demo workspace passed 165 demo cases in 4.39 seconds and 3,317 dependency core cases in
  607.49 seconds. Provider-live suites reported their declared not-requested result.
- Native repository root: poetry run python -m hostbootstrap.check_code passed Ruff, Black and
  Mypy; poetry run python -m hostbootstrap.test_all passed all 376 tests with 100% coverage.

The test-driver change is 11 added/2 removed lines, with zero production modules. setLocaleEncoding
utf8 is the first main IO action; exactly one runtime locale assertion is added. Independent review
confirms the original test tree, Unicode title and complete RTS check remain. No skip, name change,
quiet test option, handle/console mutation or extra process entrypoint was introduced in the suite.
The moved locale task is removed from 24.57; its seven unrelated planned deliverables remain.
JJ, testing and Haskell encoding claims match both actual drivers.

A concurrent standalone Windows core run reported one failure out of 3,315, with the case detail
lost in tool and harness output truncation. The unchanged tree passed the same dependency core
suite in demo/ and then the exact standalone cabal test all command serially. The serial observer
retained failure context in memory and reported none; it supplied no selector or test option.
No cause or code correction is claimed for that isolated earlier core result. The final successful
unfiltered gates above establish this completion evidence; the earlier failed runs remain failed.

#### Remaining Work

None.


## Remaining Work

None.

## Documentation Requirements

**Architecture docs to create/update:**
- `documents/architecture/build_and_run_model.md` — where reconcilers sit between the host floor and the plan.
- `documents/architecture/hostbootstrap_core_library.md` — the generic Lift over the pure context vocabulary.
- `documents/architecture/composition_methodology.md` — resolved outer dispatch and nested command folding.

**Engineering docs to create/update:**
- `documents/engineering/ensure_reconcilers.md` — the reconciler contract and the applicability rule.
- `documents/engineering/derived_dockerfile.md`, `documents/engineering/config_generation.md` — the
  image entry point and ordinary configuration-copy channel.
- `documents/engineering/incus.md`, `documents/engineering/lima.md`, `documents/engineering/wsl2.md` — the
  provider reconcilers.
- `documents/engineering/accelerator_daemon.md` — the per-substrate accelerator toolchain matrix.

**Cross-references to add:**
- `development_plan_standards.md` § L names this phase as the owner of the reconciler contract.
- `development_plan_standards.md` § U names this phase as the owner of the provider-neutral resolved-tool
  self-reference Lift.
- The [cluster-lifecycle, budgets, and cordoning phase](phase-16-cluster-lifecycle-and-cordoning.md) owns the
  plan-bound direct-Colima adapter because it consumes project-plan and admitted-wall evidence.
