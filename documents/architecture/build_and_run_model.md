# Build and Run Model

**Status**: Authoritative source
**Supersedes**: the `HostTarget` runtime narrative, the claim that teardown is not recursive, and the
two-project/freeze consumer claim
**Referenced by**: [documents index](../README.md), [Python/Haskell boundary](python_haskell_boundary.md), [composition methodology](composition_methodology.md), [base image](../engineering/base_image.md), [lifecycle state model](lifecycle_state_model.md)

> **Purpose**: Describe how the host-native project binary and Linux project image are built, and how
> that binary currently drives the persistent stack.

## TL;DR

The host binary and Linux image use the same Cabal project. The Python host build retains its explicit
offline option, while image builds are ordinary online distribution builds and may compile Cabal cache
misses. Published rolling bases are explicitly pulled before compatibility smoke-testing. Lifecycle
readiness and child-first teardown consume one retained exact plan, and the Harness owns its run-scoped
profile, generated config, and durable root through terminal release.

## Current Status

The sections below describe the working one-project build chain, provider dispatch, recursive lifecycle,
and Harness ownership. Delivery status and dated substrate evidence live in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

One gap stands against the [one-quoter rule](#one-quoter): the worked demo consumer defines its own
PowerShell quoter, `powerShellQuote` in `HostBootstrapDemo.Commands`, and uses it to build the host
accelerator daemon's PowerShell command line instead of `powerShellQuoteArg` from `HostBootstrap.Effect`;
the guard does not catch it because the name is neither a guarded definition site nor a listed retired
spelling. The [worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owes deleting that
copy, widening the `EffectSpec` guard to refuse a PowerShell quoter under any name, and listing
`powerShellQuote` among the retired spellings; the [host tools and substrate detection
phase](../../DEVELOPMENT_PLAN/phase-3-host-tools-and-substrate-detection.md) owns the quoter module and its
single definition site.

Two gaps stand in the durable and test state (see [durable and test state](#durable-and-test-state)): the
demo's cluster, provider, mount, and teardown consumers derive the run profile and durable root
independently from the config and the process working directory rather than from one projection of the
retained plan, and the guest-alias, kind-node, and pod durable paths are fixed demo constants rather than
plan projections. The [worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns both;
[durable state](durable_state.md#current-status) states them canonically.

## One universal floor, multiple hardware contexts

`linux-cpu` is the universal project baseline. It is a Linux/container contract, not a synonym for a
physically Linux host. It is also not the complete execution model: hostbootstrap is a DSL that lifts an
arbitrary application into a plan-selected hardware context. The outer
host-native binary first classifies the host so it can select the realization:

| Outer host classification | Provider realization of `linux-cpu` |
|---|---|
| Linux CPU (`LinuxCpu`) | Incus Linux VM and container path |
| Linux GPU (`LinuxGpu`) | direct host: no provider VM; the project container runs on the host with GPU access |
| Apple Silicon (`AppleSilicon`) | Lima Linux VM and container path |
| Windows CPU and Windows GPU (`WindowsCpu`, `WindowsGpu`) | WSL2 Linux VM and container path |

The direct Colima adapter is not a row of this table: it is a separate Apple adapter outside the demo's
provider path (see [the direct-Colima adapter](#the-direct-colima-adapter)).

Where this page writes "substrate" alone it means the glossary's detected-outer-host sense (the
`SubstrateName` vocabulary). A "`linux-cpu` substrate gate" uses the hardware-context sense: a gate run
inside the realized `linux-cpu` environment. See [the glossary](../README.md#glossary).

The selected hardware context combines the detected outer host, accelerator, provider, topology,
placement, and typed capabilities. GPU or Metal contexts are genuine targets for lifted application roles; they add behavior to
the applicable host realization without weakening or replacing the CPU floor. Host-native work is limited
to bootstrap, provider ownership, transport, and roles the context explicitly places on the host. Project
compilation, baseline gates, and ordinary CPU workload effects re-enter the project binary in the realized
Linux environment.

The existing closed `SubstrateName` vocabulary is therefore an outer-host/provider dispatch vocabulary.
`providerKindForSubstrate` maps `LinuxCpu` to the Incus provider and `LinuxGpu` to the direct-host
branch, the only branch with no provider VM. The `LinuxCpu` spelling names an outer host, not the
baseline; it does not make the universal baseline unavailable when the outer classifier returns
`AppleSilicon` or `WindowsCpu`.

## Three builds and one Cabal project

The outer Python bootstrap builds the first project executable **host-native** into
`<project-root>/.build/<executable>` and hands the requested arguments to it. That binary establishes the
host's `linux-cpu` realization and re-establishes the same project binary inside the Linux environment;
the Linux-side binary then builds the project image from the same source. In this repository,
`demo/cabal.project` includes
the demo package and local `hostbootstrap-core`; the Docker build copies both packages into matching
relative locations and uses that same file unchanged. A VM-backed lane therefore compiles the project
three times from one project file: on the outer host, inside the provider VM, and in the image build.
The direct Linux GPU lane has no provider VM, so its host-native binary is already the Linux-side binary
and the middle row does not occur.

| Build | Project file | Store/pins |
|---|---|---|
| Host-native bootstrap/provider binary | `demo/cabal.project` | host `.build/cabal-store`; local core source |
| Realized `linux-cpu` binary | `demo/cabal.project` | realization-local Cabal store; local core source |
| Linux project image | `demo/cabal.project` | inherited `/opt/cache/cabal`; local core source; online misses allowed |

No project file imports `/opt/basecontainer/...`, and the Dockerfile does not swap in a
container-specific configuration. The inherited store improves performance when keys match; it does not
control the consumer solver.

Because the first build in that table is host-native on every supported outer host — macOS, Linux, and
Windows — the sources it compiles are host-portable, and so are the suites that gate them. That is the
**host static gate**: the fast Haskell and Python suites run as ordinary processes of the outer host and
are expected to pass on each of them. It is a separate thing from a **`linux-cpu` substrate gate**, whose
process and POSIX/container effects execute inside the realized Linux environment established in the next
row. Running the static suites natively on Windows is an outer-host run (the `WindowsCpu` or `WindowsGpu`
outer host), not a `linux-cpu` substrate gate, and it proves nothing about a provider, a container, or a
real POSIX process boundary. The gate kinds and
the portability rules the harness holds are canonical in [testing](../engineering/testing.md).

## Network behavior

The ordinary online bootstrap probes tools first, downloads a pinned/digest-verified GHCup binary only
when absent, refreshes a missing/stale Cabal index, and lets Cabal resolve uncached build inputs.
`--offline` instead requires every tool and the index to be present, adds Cabal's `--offline` mode, and
fails clearly when the local index/store cannot satisfy the build. An unchanged located binary is not
recopied to `.build/`.

Base and derived image builds remain online distribution operations: they pull images and may download
toolchains/packages. The rolling base workflow queries authoritative release metadata for current
compatible inputs; it has no committed replay lock. Its selection contract is documented in
[Python/Haskell boundary](python_haskell_boundary.md) and
[base image](../engineering/base_image.md).

## Project image source

Derived compatibility smoke builds consume the **published** rolling base, never a same-named local
image left in a Docker daemon. The publisher explicitly pulls the tag and may use the resolved digest to
bind that one smoke to the pulled artifact. Ordinary consumers use the rolling tag and pull it through
the normal published-base workflow; the digest is not a permanent configuration or reproducibility
contract.

See [base image](../engineering/base_image.md) and [build and release](../engineering/build_release.md).

## Persistent-stack chain

The VM-backed demo chain currently descends through host, VM, and project-container frames. Its workload
segment is:

```text
deploy-kind
  -> deploy-object-store
  -> deploy-registry
  -> push-image
  -> deploy-chart
  -> expose-port
  -> accelerator-daemon placement (host or in-cluster; absent on Windows CPU)
```

The direct Linux GPU lane skips the provider VM, builds the CUDA project image on the host, enters that
container with GPU access, creates nvkind, and deploys the in-cluster GPU daemon.

`deploy-object-store` is not optional narrative detail: it creates the S3 backing and bucket used by the
registry. The last step depends on the outer host:

| Outer host | Accelerator daemon |
|---|---|
| Linux CPU, Linux GPU | in-cluster daemon deployed after the web service |
| Apple Silicon, Windows GPU | host daemon started after the private ingress is reachable |
| Windows CPU | none: the chain ends at `expose-port`, and its reverse has no daemon step |

## One quoter

Three axes are separate boundaries: *which* executable an invocation names, the *shape* it is launched
with, and *how the command is expressed*. Quoting belongs to the third. The rule is that an argument
that crosses into a shell is quoted by `HostBootstrap.Effect.Quote` and by nothing else. The module lives
in the private `effect-internal` leaf sublibrary, which the libraries that compose or run commands (the
main library and `colima-backend-internal`) and the test suite depend on, and it is re-exported to
consumers as `HostBootstrap.Effect`.

Two grammars are there because two interpreters read them. POSIX `sh` closes a single-quoted string at the
first quote and offers no escape inside it, so `shellQuoteArg` leaves and re-enters the quoting; Windows
PowerShell doubles the quote in place, so `powerShellQuoteArg` is a separate function rather than a flag.
`shellQuoteArgs` joins a quoted argv, so an argv built in Haskell reaches the far side as the same argv.

A second copy is the defect the rule exists to prevent. Two quoters agree on every input both were
written for and disagree on the first character only one of them met, and no gate compares them, because
each passes its own test. `EffectSpec` guards the rule over the library, its private sublibraries, and
the demo consumer's sources, but the guard is a name check, not a structural one: it requires exactly one
definition site for `shellQuoteArg` and for `powerShellQuoteArg`, and it refuses three listed retired
spellings. A quoter defined under any other name passes it; the demo's `powerShellQuote` is such a copy
(see [Current Status](#current-status)). The
[host-tools-and-substrate-detection phase](../../DEVELOPMENT_PLAN/phase-3-host-tools-and-substrate-detection.md)
owns the quoter and its single definition site; the [worked demo
phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns removing the demo's copy and widening the guard.

## One command vocabulary, one interpreter, one runner

The third axis is more than quoting. A host-level command is a value: `HostCommand` names the target, the
exact argument vector, the stdio disposition, and the frame whose process will interpret it. The type is
pure and names no runner, so building an argument vector and running one are different things a caller
cannot confuse. There is no constructor for a bare command name; a target is a resolved `HostTool` or the
binary's own path — the latter being how the binary reaches itself at another frame, which is a
self-invocation the lift fold produces rather than a verb an operator types (see
[hostbootstrap core library](hostbootstrap_core_library.md)).

`HostToolSpec` pins the enumeration by exact equality with the complete delegated-tool list. Operations
the binary implements itself are absent from that list, as are tools used only inside a provider guest;
the latter cross the provider boundary through one already-resolved host command and remain part of the
guest's local capability vocabulary.

`HostBootstrap.Effect.Interpreter` is the one interpreter. `resolveLaunch` is pure and total: it turns a
described command into the executable and argument vector the host launches, and it is where the single
outer-host reframing lives — on Windows a WSL command is launched through PowerShell, built with the one
PowerShell quoter. `interpretHostEffects` runs an effect list under one of two failure policies:
`FailFast` stops a launch or staging list at the first failure, and `BestEffort` continues an idempotent
teardown, printing the policy's intent line before each command and a `(skipped: …)` line for each
failure. A consumer supplies only what a library cannot know — the global WSL wall's project-owned
ownership identity, and where a run's transcript goes.

The names a consumer uses, all re-exported by `HostBootstrap.Effect`:

| Name | Role |
|---|---|
| `resolveLaunch` | pure: described command to the executable and argument vector the host launches |
| `interpretHostCommand` | run one described command through the plain capture |
| `interpretHostEffects` | run an effect list under one `EffectFailurePolicy` |
| `EffectFailurePolicy` | `FailFast` or `BestEffort` carrying the intent line |
| `EffectEnvironment` | the consumer's seams: `effectAcquireGlobalWall`, `effectReleaseGlobalWall`, `effectEcho` |
| `EffectFailure` | why a list stopped: the command ran and refused, or no child existed |
| `runCaptured` | the plain capture |
| `runBoundedGrouped`, `RunBounds`, `RunNamespace` | the bounded, group-leading capture and its inputs |
| `BoundedRun` | `BoundedCompleted`, `BoundedTimedOut`, `BoundedOutputLimit`, or `BoundedFailed` |

`runBoundedGroupedWithInput`, the bounded capture that writes a request to the leader's standard input,
is exported by `HostBootstrap.Effect.Run` inside `effect-internal` and is not re-exported to consumers.

`HostBootstrap.Effect.Run` is the one process runner, and it offers exactly two dispositions because two
are genuinely distinct. `runCaptured` feeds a stdin string and reads both output streams. `runBoundedGrouped`
is what a driver needs when its child may hang, talk forever, or leave descendants: the child leads its own
process group, receives a complete environment and working directory rather than inheriting the launcher's,
and is bounded by a wall clock, a per-stream output ceiling, and a termination grace. A caller that needs
different numbers supplies a different `RunBounds` row, not a different runner. No bound wraps a process
wait in a timeout, because a process wait is a foreign call an asynchronous exception cannot bring the
launcher back out of under the non-threaded runtime. The wall clock times out the interruptible drain of
the two pipes; the per-stream ceiling is enforced by the pipe readers; and the child's exit after the
drain and the termination grace are polled with `getProcessExitCode`. On POSIX hosts the termination
grace ends when the child's whole process *group* is empty, so a leader that exits leaving a grandchild
on the pipes still reaches the escalation to a group `SIGKILL`. On Windows there is no process-group
probe or group signal: teardown calls `terminateProcess` on the leader and waits a bounded grace, and the
leader's descendants are not guaranteed to be reaped. On macOS the child is started through `/bin/sh`,
which changes to the requested working directory and then execs the leader, because the process library
cannot combine a new process group, an explicit environment, and a working directory there; the exec
keeps the new group identity. The two other lawful shapes
are separately sealed: `HostBootstrap.Detached` owns a child that outlives its launcher, and the handoff
process route owns a child holding an inherited descriptor pair.

Failure to *start* stays distinct from failure to *succeed*. A child that ran and exited non-zero carries
its own diagnostic in the streams it wrote; only a child that never existed is a launch failure. Collapsing
the two loses the difference between "the tool refused" and "the tool is not there".

## Which frame reads a path

A described command's frame is not decoration. `framePathGrammar` answers, from the frame alone, whether a
path in that command obeys the outer host's grammar — drive-qualified on Windows — or the POSIX grammar
every frame reached through a host-provider command uses. The deciding question is which process will
interpret the path, never which frame constructed the string: a path derived from a host value is still a
guest path when a guest process reads it.

The crossing itself is rendered once. `foldLeafCommand` pairs the lift fold's own dispatch with
`liftContextFrame`'s description of where it lands, so nothing re-derives a frame-crossing argument vector
in order to explain it.

## Provider dispatch

The provider axis has four one-way layers. Public pure `HostBootstrap.Lift.Context` describes target
records, the nested stack, canonical mounts, and inner transport argv. Generic `HostBootstrap.Lift`
resolves only the outer host tool and folds a self-reference command without importing provider or Registry
policy. `HostBootstrap.Incus`/`Lima`/`Wsl2` provide lifecycle-specific builders over those lower records,
and the abstract `SubstrateProvider` selects their pure operation plans without exposing its constructor or
record fields. Network/registry code may add leaf helpers by importing generic Lift; generic Lift never
imports it.

A provider is a **row** rather than a workflow. What genuinely differs between frames is small and
enumerable — the tool that reaches the frame and its argument shape, the frame's path grammar, its sizing
vocabulary, and its ownership primitive — and a behaviour true of every frame is written once and
instantiated from that table. `HostBootstrap.Substrate.Frame` holds the shared computations; the guarded
destructive delete is one of them, so a provider module supplies only the noun its refusal reads in and the
argument vector for a name the guard has already admitted. Anything that differs and is not in the table is
either an explicit typed `Unsupported`/`Conflict` at the point of use, or a second copy of a workflow that
will drift where no gate looks.

The **ownership primitive** is the table's most consequential column, and it has exactly three rows: POSIX,
Windows, and one that runs a transaction at the frame owning the object. The third is a transport rather
than a third implementation: what executes at the far side is this binary's own host row for that frame,
carried by a process of this same binary. Under a one-layer lift context that is a Linux guest, so the
POSIX row runs there; under an empty context the transaction is a local self-fork and the outer host's own
row runs — on Darwin a symbolic link is published by `renamex_np(RENAME_EXCL)`, and on Windows the
symbolic-link acts answer `OwnershipUnsupported`. [Ownership seam](ownership_seam.md) is its canonical
home.

The lifecycle provider kind, `ProviderKind` in `HostBootstrap.Substrate.Provider`, is a closed, total
four-way sum: Incus, Lima, WSL2, or Direct. It is distinct from the wider, deliberately open topology
`ProviderKind` in `HostBootstrap.Context`, into which `providerTopologyKind` projects it. Colima is a
member of neither. A selected
opaque descriptor retains a complete `LiftContext`; the three guest providers contribute exactly one VM
layer and Direct contributes `localContext`. Provider discovery owns its closed request order and accepts
only raw exit status, stdout, stderr, or transport failure. Private total parsers require exact one-line
reports where a marker or identity is expected, preserve structured conflict, and poll only bounded
`NotReady`. Discovery then becomes a generative, backend-indexed descriptive capability tied to the exact
opaque managed Running provider; it is not mutation authority and Direct exposes no guest executor.

Provider mutation enters through exact prepared calls. Opaque nominal `ManagedProviderHandle` and
`ManagedProviderShareHandle` values retain the provider origin and backend realization without exposing a
generic handle/receipt escape. The Incus backend holds the four ownership clauses around provision,
readiness, share, stop, bound guest execution, and conditional delete, and it holds them the way every
other owner does: inside the protected store's exclusive entry, over described commands run by the one
interpreter, with each answer classified by a total function. It resolves only the provider client; it
constructs no interpreter or locking front end of its own and uses the shared ones, and it starts no
process of its own, which a source guard holds. Direct instead settles a plan-local reservation and identity share without publishing an origin or
claiming the physical host; its root admission is this binary's own observation of the kernel followed by
a total decision over it — absolute, unfollowed, a directory, canonical, accessible — and stop, delete,
guest routing, and guest alias are structured refusals rather than empty effects or a fabricated VM. The
demo VM lanes open the exact plan-owned provider and share resources, and the guest alias executes the
shipped POSIX ownership row inside the admitted guest frame. Native provider evidence is recorded by the
applicable substrate phase.

The pure Context and lower generic-Lift separations and source guards are closed by the
[Dhall-configuration-and-generic-project-model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md),
[ensure-reconcilers phase](../../DEVELOPMENT_PLAN/phase-8-ensure-reconcilers.md). The
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
owns the independent native Linux provider gate, and the
[composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md)
owns the additive registry leaf coverage and its complete gate.
See [Incus](../engineering/incus.md), [Lima](../engineering/lima.md), and [WSL2](../engineering/wsl2.md).

## Lifecycle truth

Bring-up has several bounded waits and fail-closed command checks. Three terms recur below. A
**prepared gate** (`PreparedGate`) is the proof that one operation's unknown phase was durably journaled
before its backend call ([lifecycle state model](lifecycle_state_model.md)). A **self-bound** record
carries the identities it was written for, so a copied or replaced record does not match. A **wall** is
the resource ceiling the budget renderer produced and a provider or cordon applies
([applied cordon](../engineering/applied_cordon.md)). The four ownership clauses (exclusive entry, durable
origin record before the first write, identity binding, conditional release) are canonical in
[ownership invariant](ownership_invariant.md#the-four-clauses).

### The exact cluster consumer

The [cluster-lifecycle, budgets, and cordoning
phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md) owns the exact cluster consumer,
which is plan-indexed end to end.

- **Preconditions.** It requires backend-minted Running-provider dependency authority and applies the
  exact retained resource slice under identity-checked exclusion. The prepared journal generation and the
  backend container identity are distinct retained facts.
- **Readiness.** It mints readiness only from a real API and node probe of the same control-plane
  identity.
- **Tools and process.** The production backend resolves the exact cluster tools through typed
  `HostConfig`/`HostTool`; command injection is Cabal-private. The runner closes the working directory,
  environment, helper `PATH`, process-group lifetime, and strict output framing.
- **Durable records.** The backend publishes self-bound `prepared`, `executing`, and `managed` records under
  one no-follow state and lock namespace. The executing record binds the exact config and
  private-kubeconfig snapshot identities before Kind runs.
- **Refusals.** A restart repairs only the origin-verified identity; it refuses copied records and
  replaced snapshots.
- **Consumers.** The demo consumer opens that exact package at the child frame, and far-frame clients
  receive only freshly re-observed resolved exposures.

### The direct-Colima adapter

The direct-Colima adapter is **not used by the demo**: the Apple demo's provider is Lima, and the
[Apple Silicon acceptance phase](../../DEVELOPMENT_PLAN/phase-26-apple-silicon-substrate.md) exercises
the public exact-plan adapter against native Colima in a separate lane. The [cluster-lifecycle, budgets,
and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md) owns its source
boundary.

- **Prepared start.** It joins one plan, provider, and topology with the complete budget partition and the
  current prepared gate. It renders the fixed Colima start call with `--activate=false`, so no
  process-global Docker context is activated, and with the CPU and memory wall, a 20-GiB root disk, and a
  data disk of the total minus 20 GiB. It derives one 128-bit
  namespace for the isolated home and the reusable lock, with a socket-safe local profile.
- **Tools and process.** A private fixed Apple resolver and a bounded runner and supervisor close tools,
  helper `PATH`, environment, working directory, process groups, and output framing.
- **Ordering before mutation.** Under the descriptor-held reusable `flock(2)` lock, the self-bound durable
  protocol records the absence of the namespace, profile, and context before any mutation, then retains
  the exact machine, context, directory chain, disk objects, and complete artifact manifest.
- **Settlement.** Only the matching validated backend result can jointly settle the journal-bound provider
  start and the wall into `LiveColimaWall`; `runLiveColimaDocker` is the sole Docker route through that
  exact wall.
- **Teardown order.** Cleanup opens its own current teardown gate, durably enters `releasing`, runs
  `colima delete --force --data`, proves the profile, data, and context absent, then completes the exact
  managed provider `Running` to `Destroyed` transition, and only then conditionally releases its private
  cache, temporary, home, data, and context namespaces and origins.
- **Refusals.** A prepared-but-present, replaced, partial, or invocation-mismatched state grants no
  authority.

### Recursive teardown

Teardown is recursive and child-first. Root `project down`/`destroy` projects the retained plan into a
typed reverse forest, authenticates each child entry, cleans cluster-local resources only in their owning
frame, then runs every remaining node's declared reverse. Independent failures are aggregated after all
eligible siblings run, and an unsettled node remains available for the exact retry. The recursive reverse
and its authenticated handoff are canonical in [composition methodology](composition_methodology.md).

The typed transitions, opaque capabilities, ownership tokens, and validation gates are specified in
[lifecycle state model](lifecycle_state_model.md).

## Durable and test state

Durable carry is implemented from host `.data` through provider share,
`/var/tmp/hostbootstrap-demo-data`, kind/nvkind, and the pod. The Harness `durable-readback` case writes a
marker, performs engine-owned settled destroy, rotates to a fresh protected invocation, rebinds the retained
snapshot, brings the same run forward again, and reads the exact marker from the recreated workload.

The demo test runner assembles a config whose `runProfile` is `HarnessRun` carrying the run's name, and
an exact Harness-scoped plan; it owns
`.test_data/<runId>`, and selects a run-scoped cluster name. Terminal close removes the generated child and
its ownership records while preserving the empty `.test_data` parent. The demo's cluster, provider, mount,
teardown, and data-root consumers take their managed resource nodes from the exact plan's step execution,
but compute the cluster profile as `clusterProfileOf` of the working configuration and the durable root
through `ensureProfileDataPath` over the process working directory (`runVmUp`, `runCopySource`, and
`withHostAcceleratorExposure` each do both), and the guest-alias, kind-node, and pod paths are fixed demo
constants. The target makes every one of those terms a projection of the retained plan and run authority;
the [worked demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns that gap (see
[Current Status](#current-status)). See
[durable state](durable_state.md) and
[harness workflow](harness_workflow.md).

## Command surface

The fixed top-level command groups are `project`, `test`, `service`, `context`, and `check-code`.
`context` has five read-only subcommands:

```text
context inspect
context path
context show [FILE]
context schema
context render [--artifact NAME]
```

`test init` and `test run` are admitted only through the rooted Harness entry. The actual demo
`<project>.test.dhall` contains resources and stable variant values; compiled Haskell owns the case bodies
and the selector (one case ID or `all`).

That surface is the whole of the parsed command tree, and it is not the whole of how this binary is
started. Before the parser runs, `runCLI` checks the argument vector against five private entries, none
of which appears in `--help`:

| Entry | Launched by | Precondition |
|---|---|---|
| `--hostbootstrap-install-identity` (whole argument vector) | the thin builder, after stable installation | none on stdio: it provisions the installed identity of the invoked executable |
| the exposure relay marker followed by relay targets | the cluster backend, inside the relay container it creates | well-formed targets; malformed input refuses rather than falling through |
| the Colima command-transaction marker (whole argument vector) | the Colima bounded runner, through its own bounded capture | a framed request on standard input; refused on Windows |
| `--hostbootstrap-lifecycle-child` (whole argument vector) | the root lifecycle's crossing into a child frame | the installed handoff public key and the isolated protocol channel |
| `--hostbootstrap-frame-child` (whole argument vector) | a frame-crossing transaction folded from the lift context | standard input and output are the handoff protocol channel |

The lifecycle-child and frame-child entries refuse outside a protocol channel, and the Colima entry
refuses without a framed request. The install-identity entry needs neither, so it is reachable from an
operator's shell, and the relay entry needs only its targets. The near side of a frame crossing folds the lift context to the
invocation that performs it, so the argument vector, the executable, and the frame all come from the one
fold rather than from a caller. The command surface and every pre-parser entry are canonical in
[hostbootstrap core library](hostbootstrap_core_library.md); see also
[the core library's frame-child entry](hostbootstrap_core_library.md#the-frame-child-entry).

## Validation

Static unit suites validate the builders, classifiers, ownership rows, authority boundaries, and compile-time
seals. They are the host static gate and are expected to pass host-native on every supported outer host; see
[testing](../engineering/testing.md#gate-kinds). They do not prove a provider, accelerator, browser, or
container runtime on hardware where the live gate did not run. Those dated acceptance results remain in the
development-plan phase for each substrate.

Status and sequencing belong in [the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Related

- [composition methodology](composition_methodology.md) — frame/chain model.
- [Python/Haskell boundary](python_haskell_boundary.md) — outer bootstrap.
- [derived Dockerfile](../engineering/derived_dockerfile.md) — image build.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — kind/nvkind behavior.
