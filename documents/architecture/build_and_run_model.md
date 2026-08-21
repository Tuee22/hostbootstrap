# Build and Run Model

**Status**: Authoritative source
**Supersedes**: the `HostTarget` runtime narrative, recursive-teardown claim, and two-project/freeze
consumer claim
**Referenced by**: [documents index](../README.md), [Python/Haskell boundary](python_haskell_boundary.md), [composition methodology](composition_methodology.md), [base image](../engineering/base_image.md), [lifecycle state model](lifecycle_state_model.md)

> **Purpose**: Describe how the host-native project binary and Linux project image are built, and how
> that binary currently drives the persistent stack.

## TL;DR

The host binary and Linux image use the same Cabal project. The Python host build retains its explicit
offline option, while image builds are ordinary online distribution builds and may compile Cabal cache
misses. Published rolling bases are explicitly pulled before compatibility smoke-testing; lifecycle
readiness/teardown remain incomplete, and demo Harness consumers still need exact plan-owned
profile/root projection.

## Current Status

The sections below describe the working two-build chain and identify its open lifecycle defects.
Delivery status and closure evidence live in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## One universal floor, multiple hardware contexts

`linux-cpu` is the universal project baseline. It is a Linux/container contract, not a synonym for a
physically Linux host. It is also not the complete execution model: hostbootstrap is a DSL that lifts an
arbitrary application into a plan-selected hardware context. The outer
host-native binary first classifies the host so it can select the realization:

| Outer host classification | Provider realization of `linux-cpu` |
|---|---|
| Linux CPU | native Linux container/runtime path |
| Apple Silicon | Lima/Colima Linux VM and container path |
| Windows CPU | WSL2 Linux VM and container path |

The selected hardware context combines substrate, accelerator, provider, topology, placement, and typed
capabilities. GPU or Metal contexts are genuine targets for lifted application roles; they add behavior to
the applicable host realization without weakening or replacing the CPU floor. Host-native work is limited
to bootstrap, provider ownership, transport, and roles the context explicitly places on the host. Project
compilation, baseline gates, and ordinary CPU workload effects re-enter the project binary in the realized
Linux environment.

The existing closed `SubstrateName` vocabulary is therefore an outer-host/provider dispatch vocabulary.
Its `LinuxCpu` spelling describes the native realization branch; it does not make the universal baseline
unavailable when the outer classifier returns `AppleSilicon` or `WindowsCpu`.

## Two builds and one Cabal project

The outer Python bootstrap builds the first project executable **host-native** into
`<project-root>/.build/<executable>` and hands the requested arguments to it. That binary establishes the
host's `linux-cpu` realization and re-establishes the same project binary inside the Linux environment;
the Linux-side binary then builds the project image from the same source. In this repository,
`demo/cabal.project` includes
the demo package and local `hostbootstrap-core`; the Docker build copies both packages into matching
relative locations and uses that same file unchanged.

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
row. Running the static suites natively on Windows is an outer host realization rather than a substrate,
and it proves nothing about a provider, a container, or a real POSIX process boundary. The gate kinds and
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
  -> deploy-minio
  -> deploy-registry
  -> push-image
  -> deploy-chart
  -> expose-port
  -> host or in-cluster accelerator-daemon placement
```

The direct Linux GPU lane skips the provider VM, builds the CUDA project image on the host, enters that
container with GPU access, creates nvkind, and deploys the in-cluster GPU daemon.

`deploy-minio` is not optional narrative detail: it creates the S3 backing and bucket used by the
registry. Linux CPU/GPU deploy an in-cluster daemon after the web service; Apple Silicon/Windows GPU start
a host daemon after the private ingress is reachable.

## One quoter

Three axes are separate boundaries: *which* executable an invocation names, the *shape* it is launched
with, and *how the command is expressed*. Quoting belongs to the third. An argument that crosses into a
shell is quoted by `HostBootstrap.Effect.Quote`, and by nothing else — the private leaf sublibrary every
library in the package depends on, re-exported to consumers as `HostBootstrap.Effect`.

Two grammars are there because two interpreters read them. POSIX `sh` closes a single-quoted string at the
first quote and offers no escape inside it, so `shellQuoteArg` leaves and re-enters the quoting; Windows
PowerShell doubles the quote in place, so `powerShellQuoteArg` is a separate function rather than a flag.
`shellQuoteArgs` joins a quoted argv, so an argv built in Haskell reaches the far side as the same argv.

A second copy is what the guards refuse. Two quoters agree on every input both were written for and
disagree on the first character only one of them met, and no gate compares them, because each passes its
own test. The [host-tools-and-substrate-detection phase](../../DEVELOPMENT_PLAN/phase-3-host-tools-and-substrate-detection.md)
owns the quoter and its single definition site.

## One command vocabulary, one interpreter, one runner

The third axis is more than quoting. A host-level command is a value: `HostCommand` names the target, the
exact argument vector, the stdio disposition, and the frame whose process will interpret it. The type is
pure and names no runner, so building an argument vector and running one are different things a caller
cannot confuse. There is no constructor for a bare command name; a target is a resolved `HostTool` or the
binary's own path — the latter being how the binary reaches itself at another frame, which is a
self-invocation the lift fold produces rather than a verb an operator types (see
[hostbootstrap core library](hostbootstrap_core_library.md)).

`HostBootstrap.Effect.Interpreter` is the one interpreter. `resolveLaunch` is pure and total: it turns a
described command into the executable and argument vector the host launches, and it is where the single
outer-host reframing lives — on Windows a WSL command is launched through PowerShell, built with the one
PowerShell quoter. `interpretHostEffects` runs an effect list under one of two failure policies: a launch
or staging list stops at the first failure, an idempotent teardown continues under one intent line. A
consumer supplies only what a library cannot know — the global WSL wall's project-owned ownership
identity, and where a run's transcript goes.

`HostBootstrap.Effect.Run` is the one process runner, and it offers exactly two dispositions because two
are genuinely distinct. `runCaptured` feeds a stdin string and reads both output streams. `runBoundedGrouped`
is what a driver needs when its child may hang, talk forever, or leave descendants: the child leads its own
process group, receives a complete environment and working directory rather than inheriting the launcher's,
and is bounded by a wall clock, a per-stream output ceiling, and a termination grace. A caller that needs
different numbers supplies a different `RunBounds` row, not a different runner. Each of those bounds is
waited out by polling the child's status rather than by wrapping a blocking wait in a timeout, because a
process wait is a foreign call an asynchronous exception cannot bring the launcher back out of under the
non-threaded runtime; and the termination grace ends when the child's whole process *group* is empty, so
a leader that exits leaving a grandchild on the pipes still reaches the escalation to a group `SIGKILL`. The two other lawful shapes
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
than a third implementation — every frame this project reaches is Linux, so what executes there is the
POSIX row, carried by a process of this same binary. [Ownership seam](ownership_seam.md) is its canonical
home.

The lifecycle provider kind is a closed, total four-way sum: Incus, Lima, WSL2, or Direct. A selected
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
interpreter, with each answer classified by a total function. It resolves the provider client and nothing
else — no interpreter, no locking front end — and it starts no process of its own, which a source guard
holds. Direct instead settles a plan-local reservation and identity share without publishing an origin or
claiming the physical host; its root admission is this binary's own observation of the kernel followed by
a total decision over it — absolute, unfollowed, a directory, canonical, accessible — and stop, delete,
guest routing, and guest alias are structured refusals rather than empty effects or a fabricated VM. The
static gate is closed; native validation remains open until the Linux/x86_64 KVM/Incus gate of the
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
pass. The [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) separately owns replacing the
demo's compatibility provider and pathname-alias call sites with this route.

The pure Context and lower generic-Lift separations and source guards are closed by the
[Dhall-configuration-and-generic-project-model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md),
[ensure-reconcilers phase](../../DEVELOPMENT_PLAN/phase-8-ensure-reconcilers.md). The
[host-providers-and-self-reference-lift phase](../../DEVELOPMENT_PLAN/phase-15-host-providers-and-the-lift.md)
owns the independent native Linux provider gate, and the
[composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md)
owns the additive registry leaf coverage and its complete gate.
See [Incus](../engineering/incus.md), [Lima](../engineering/lima.md), and [WSL2](../engineering/wsl2.md).

## Lifecycle truth

Bring-up has several bounded waits and fail-closed command checks. The exact cluster consumer owned by the
[cluster-lifecycle, budgets, and cordoning phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md)
is plan-indexed end to end: it requires backend-minted Running-provider dependency authority, applies the
exact retained resource slice under identity-checked exclusion, and mints readiness only from a real API/node
probe of the same control-plane identity. The prepared journal generation and backend container identity are
distinct retained facts. Its production backend resolves the exact cluster tools through typed
`HostConfig`/`HostTool`, while command injection remains Cabal-private; the runner closes cwd, environment,
helper `PATH`, process-group lifetime, and strict output framing. The durable backend publishes self-bound
`prepared`/`executing`/`managed` records under one no-follow state/lock namespace. The executing record binds
the exact config and private-kubeconfig snapshot identities before Kind, so a restart can repair only the
origin-verified identity and must refuse copied records or replaced snapshots. Legacy/demo consumers are
intentionally not relabelled through that boundary;
adoption remains with the
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) and
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md). Other live effects are not universally
type-gated and several still return `IO ()` or consume non-authorizing compatibility observations.

The same [cluster-lifecycle, budgets, and cordoning
phase](../../DEVELOPMENT_PLAN/phase-16-cluster-lifecycle-and-cordoning.md) owns the implemented exact
direct-Colima source boundary. Its prepared start joins one
plan/provider/topology with the complete budget partition and current journal gate, renders the fixed
non-activating CPU/memory plus 20-GiB-root/`total-20`-GiB-data call, and derives one 128-bit isolated-home and
reusable-lock namespace with a socket-safe local profile. A private fixed Apple resolver and bounded
runner/supervisor close tools, helper `PATH`, environment, cwd, process groups, and output framing. Under the
descriptor-held reusable `flock(2)` lock, the self-bound durable protocol records namespace/profile/context
absence before mutation and retains the exact machine, context, directory chain, disk objects, and complete
artifact manifest. Only the matching closed-backend result can jointly settle the journal-bound provider
start and wall into `LiveColimaWall`; `runLiveColimaDocker` is the sole Docker route through that exact wall.
Cleanup has a distinct current teardown gate, durably enters `releasing`, executes
`colima delete --force --data`, proves profile/data/context absence, and only then completes the exact managed
provider `Running` to `Destroyed` transition and conditionally releases its namespaces and origin. A
prepared-but-present, replaced, partial, or invocation-mismatched state grants no authority. The source
phase's focused/full gates are closed; the [recursive-lifecycle-command
phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) and
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) own the remaining command adopters.

Teardown is also not recursive. Root `project down`/`destroy` cleans the current cluster only when that
frame owns it, and every other node runs the reverse its own step declared. VM deletion or
direct-container cleanup handles
nested resources without dispatching the verb through every child frame first.

The target typed transitions, opaque capabilities, ownership tokens, and validation gates live in
[lifecycle state model](lifecycle_state_model.md).

## Durable and test state

Durable carry is implemented from host `.data` through provider share,
`/var/tmp/hostbootstrap-demo-data`, kind/nvkind, and the pod. It has not passed a workload write →
destroy → up → host-and-workload readback gate.

The demo test runner assembles a `HarnessRun` config and an exact Harness-scoped plan, owns
`.test_data/<runId>`, and selects a run-scoped cluster name. Cluster/provider/mount/teardown consumers
still receive independently config-derived profile and root terms rather than projections from that
retained plan, so exact consumer continuity remains open. See [durable state](durable_state.md) and
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

The test-group help describes `test run` as root-only, but neither `test init` nor `test run` currently
applies a root context gate. The actual demo `<project>.test.dhall` contains a suite-name list and
resources; compiled Haskell owns the case bodies and the selector (currently one case ID or `all`, despite
the source help's stale suite terminology).

That surface is the whole of what an operator can type, and it is not the whole of how this binary is
started. A frame crossing launches this binary in the target frame with one marker argument vector,
which `runCLI` classifies before the parser ever runs. The marker is absent from `--help`, is the whole
argument vector or nothing, and refuses unless standard input and output are the handoff protocol
channel — so it adds no verb to the surface above and nothing an operator can usefully type reaches it.
The near side of the crossing folds the lift context to the invocation that performs it, so the argument
vector, the executable, and the frame all come from the one fold rather than from a caller. See
[the core library's frame-child entry](hostbootstrap_core_library.md#the-frame-child-entry).

## Validation

Static unit suites validate many pure builders and classifiers. They are the host static gate and are
expected to pass host-native on every supported outer host; see
[testing](../engineering/testing.md#gate-kinds). They do not close:

- remaining native rolling-base publication/compatibility lanes;
- universal readiness/ownership typing;
- recursive teardown;
- target `Harness projectId runId` isolation;
- native Linux CPU/GPU daemon gates;
- durable destroy/up/readback.

Status and sequencing belong in [the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## Related

- [composition methodology](composition_methodology.md) — frame/chain model.
- [Python/Haskell boundary](python_haskell_boundary.md) — outer bootstrap.
- [derived Dockerfile](../engineering/derived_dockerfile.md) — image build.
- [cluster lifecycle](../engineering/cluster_lifecycle.md) — kind/nvkind behavior.
