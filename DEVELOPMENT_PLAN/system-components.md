# System Components

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md), [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Map the implemented component families to their responsibilities and owning phases.

## Status and Evidence Rule

The [README phase table](README.md) is the sole cross-phase status roll-up. Dated test totals and live
acceptance evidence belong in the owning phase. This inventory describes boundaries; the linked source and
canonical topic documents supply their detailed contracts.

## hostbootstrap-core Module Surface

Every Haskell module under `core/hostbootstrap-core/src` and `core/hostbootstrap-core/internal` (the
Cabal-private sublibraries) is listed in the Modules column of exactly one row below, and every row names
exactly one owning phase: the constructive phase whose sprints build that module's contract. Names omit the
`HostBootstrap.` prefix.
Where a later phase extends a module, the row names that phase and what it adds; the extending phase
consumes the module and does not own it.

| Modules | Responsibility | Owning phase |
|---|---|---|
| `DocValidator`, `Digest` | Governed metadata, links, plan doctrine, status harmony, architecture drift, cited-path resolution, and gate-evidence currency checks. `Digest` supplies a SHA-256 spelling, `frameWire`, and the sorted, length-prefixed path-set measurement `measurePathSetDigest`; `DocValidator` measures `**Evidence covers**` sets with it, and `Lifecycle.Prepared` imports its hash and framing. `Build` keeps its own SHA-256 helper and its own source measurement, and several other modules keep local SHA-256 helpers, so `Digest` is one SHA-256 spelling among several. [Documentation reconciliation](phase-25-documentation-reconciliation.md) extends `DocValidator` with the drift guards and the identifier, anchor, header field-set, and gate-evidence checks | [Governance](phase-0-governance-and-documentation-standards.md) |
| `CLI` | The identity-parametric `ProjectSpec` and the generic `runCLI` entrypoint, which recognizes the private argv entries before the optparse parser runs and otherwise dispatches the command tree `Command` builds | [Core scaffolding](phase-2-haskell-core-scaffolding.md) |
| `HostTool`, `HostConfig`, `HostPrereqs`, `Substrate`, `Detached`, `ProjectRoot` | Absolute tool resolution, host classification, prerequisite floor, sealed detached process launch, and the private canonical project root | [Host tools and substrate detection](phase-3-host-tools-and-substrate-detection.md) |
| `Effect`, `Effect.Quote`, `Effect.Run`, `Effect.Vocabulary`, `Effect.Interpreter` | One quoter per grammar, the process runner, the described effect vocabulary, and its interpreter. `Effect.Run` carries its own bounded process-group termination (SIGTERM, bounded grace, SIGKILL) and does not use `Effect.ChildGroup` | [Host tools and substrate detection](phase-3-host-tools-and-substrate-detection.md) |
| `Protected` | Exact protected-store identity, exclusive entries, canonical records, and compare-and-swap | [Protected store](phase-4-protected-store.md) |
| `Authority`, `Authority.Kernel`, `Identity.Install`, `ProjectScope` | Executable-bound installed identity and its private installation entry, root liveness, the phantom `Production` and `Harness` scope indices, and closed invocation authority | [Installed identity and authority kernels](phase-5-installed-identity-and-authority-kernels.md) |
| `Readiness`, `Reconcile`, `Cluster.Cordon.Foundation` | Opaque readiness, total observations and ownership-indexed results, canonical quantities, and exact provider-neutral capacity, sizing, and storage-cordon policy. The [step algebra and project plan](phase-12-step-algebra-and-project-plan.md) extends `Reconcile` with indexed resource identity, handles, canonical membership, and legal journal transitions | [Canonical quantities and reconcile results](phase-6-canonical-quantities-and-reconcile-results.md) |
| `Config.Class`, `Config.Fields`, `Config.Fields.Internal`, `Config.Install.Native`, `Config.Schema`, `Config.Vocab`, `Config.Authority.Internal`, `Dhall.Gen`, `Dhall.Hoist`, `Context`, `Lift.Context`, `Cluster.Cordon` | Scope-indexed codecs and configuration, private Harness configuration authority, atomic no-replace config publication, reflected and de-duplicated Dhall schemas, descriptive topology, pure lift records, and config-facing budget adapters | [Dhall configuration and project model](phase-7-dhall-configuration-and-project-model.md) |
| `Ensure`, `Ensure.AppleMetal`, `Ensure.Cuda`, `Ensure.CudaWin`, `Ensure.Docker`, `Ensure.Ghc`, `Ensure.Homebrew`, `Ensure.Incus`, `Ensure.Lima`, `Ensure.Wsl2`, `Ensure.GuestBootstrap`, `Lift` | The reconciler contract and the nine config-free `allReconcilers` rows, the closed pre-binary guest bootstrap, and the shared self-reference crossing fold | [Ensure reconcilers](phase-8-ensure-reconcilers.md) |
| `Lifecycle.Mode` | Production/Harness exclusion, run leases, and one-use profile admission. [Recovery and migration](phase-18-recovery-and-migration.md) extends it with the Production release boundary that consumes `ProductionClosureAuthorization` | [Lifecycle modes and leases](phase-9-lifecycle-modes-and-run-leases.md) |
| `Lifecycle.Session`, `Lifecycle.Session.Testing`, `Lifecycle.Transaction` | Versioned sessions, the single-writer project journal, durable fences, and canonical multi-record redo. [Recovery and migration](phase-18-recovery-and-migration.md) extends them with migration freeze and activation | [Sessions, journal, and fences](phase-10-sessions-journal-and-fences.md) |
| `Lifecycle.Prepared`, `Lifecycle.Prepared.Internal`, `Lifecycle.Execution`, `Lifecycle.Execution.Internal` | Fresh complete dependency checks, the prepare compare-and-swap, fenced operation permits and settlement, and the plan-minted opaque `StepExecution` authority | [Prepared operations](phase-11-prepared-operations.md) |
| `Step`, `Chain`, `ProjectPlan`, `ProjectPlan.Construct`, `ProjectPlan.Frame`, `ProjectPlan.Snapshot`, `Lifecycle.Plan`, `Authority.ProjectPlan`, `Config.Schema.Internal`, `Cluster.Budget` | One admitted graph, exact finalization and frame joins, forward/topology/reverse projections, the current-frame Chain, snapshots, current-frame command authority, the digest-equality join between recovered and fresh specifications, and plan-indexed budget admission | [Step algebra and project plan](phase-12-step-algebra-and-project-plan.md) |
| `Handoff`, `Handoff.Internal`, `Handoff.Protocol`, `Handoff.Receiver`, `Handoff.Receiver.Internal`, `Handoff.Recovery`, `Handoff.Relay`, `Handoff.Rooted`, `Handoff.Transaction`, `Effect.ChildGroup`, `ProjectPlan.Child.Internal`, `Build`, `Activation` | Root-signed scope capsules, exact payload and recovery bindings, the bounded canonical wire, keyless relay, the frame-child transaction entry, child-plan authority, the bounded process-group escalation shared by the handoff process and frame-transaction transports, and the Build and Activation invocation authorities | [Authenticated handoff](phase-13-authenticated-handoff-and-child-admission.md) |
| `Ownership.Clause`, `Ownership.Internal`, `Ownership.Object`, `Ownership.Posix`, `Ownership.Primitive`, `Ownership.Row`, `Ownership.Tape`, `Ownership.Windows`, `Wire.LittleEndian`, `Harness.DataRoot`, `Harness.GeneratedConfig`, `Wsl2.GlobalWall`, `Wsl2.GlobalWall.ConfigBytes`, `Wsl2.GlobalWall.Host`, `Wsl2.GlobalWall.Windows` | Four-clause ownership primitives, the POSIX and Windows rows, the shared origin-record tape, little-endian wire words, and host-local transactions over exact kernel identities | [Ownership clauses and reservations](phase-14-ownership-clauses-and-reservations.md) |
| `Substrate.Frame`, `Substrate.Provider`, `Substrate.Provider.Alias`, `Substrate.Provider.Backend`, `Substrate.Provider.Command`, `Substrate.Provider.Internal`, `Substrate.Provider.Observation.Internal`, `Substrate.Provider.Ownership`, `Substrate.Provider.Reconcile`, `Substrate.Provider.Report`, `Substrate.Provider.Resume`, `Ownership.Shipped`, `Lifecycle.Dependency.Internal`, `Incus`, `Lima`, `Wsl2` | Closed provider rows, shared lifecycle operations, prepared provider/share/alias authority, invocation-local runtime-dependency commitments, and frame-local ownership transport | [Host providers and lift](phase-15-host-providers-and-the-lift.md) |
| `Cluster.Backend`, `Cluster.Backend.Internal`, `Cluster.Budget.Internal`, `Cluster.Command`, `Cluster.Exposure.Internal`, `Cluster.Lifecycle`, `Cluster.Observation.Internal`, `Cluster.Ownership`, `Cluster.Reconcile`, `Cluster.Report`, `Cluster.Resume`, `CLI.Bare`, `Reconcile.ProviderStart.Internal`, `Substrate.Provider.Dependency.Internal` | Exact provider/cluster/budget binding, journal-bound provider-wall reservation, backend identity, applied cordon, fresh readiness, owned exposure, conditional cleanup, exact prepared provider start, and the Docker loopback-allocation case | [Cluster lifecycle and cordoning](phase-16-cluster-lifecycle-and-cordoning.md) |
| `Ensure.Colima`, `Ensure.Colima.Command`, `Ensure.Colima.Ownership`, `Ensure.Colima.Report`, `Ensure.Colima.Settlement.Internal`, `Ensure.Colima.Backend.Resolver`, `Ensure.Colima.Backend.Resolver.Authority`, `Ensure.Colima.Backend.Resolver.Install`, `Ensure.Colima.Backend.Resolver.Native`, `Ensure.Colima.Backend.Resolver.Override`, `Ensure.Colima.Backend.Resolver.Protocol`, `Ensure.Colima.Backend.Resolver.Testing`, `Ensure.Colima.Backend.Routing`, `Ensure.Colima.Backend.Runner`, `Ensure.Colima.Backend.Stage`, `Ownership.Manifest` | The plan-owned direct-Colima adapter: tool resolver and its native Apple toolchain layouts (refused off Apple Silicon), bounded runner, routed-Docker argument refusal, descriptor-held ownership transaction, the canonical namespace manifest that is cleanup's allow-list and revalidation's record (the POSIX row and `Ownership.Row` consume it), opaque managed state, settlement bridge, and conditional force cleanup | [Cluster lifecycle and cordoning](phase-16-cluster-lifecycle-and-cordoning.md) |
| `Command`, `Command.LifecycleEntry`, `Command.Child`, `Lifecycle.Context`, `Lifecycle.Context.Internal`, `Lifecycle.FrameExecutor`, `Lifecycle.Rooted`, `Lifecycle.Rooted.Node`, `Lifecycle.Rooted.Receipt`, `Lifecycle.RootedPlan`, `Authority.FailedUp.Internal`, `ProjectPlan.Construct.Internal`, `ProjectPlan.Handoff.Internal`, `ProjectPlan.Projection.Internal`, `Config.Class.Internal`, `Service.Internal`, `Harness.Ownership.Internal` | The fixed command tree (`coreCommands`) and `allReconcilers`; one root catalog and store, inert lifecycle-context admission, storeless frame execution, authenticated descent, failed-Up cleanup authority, digest-proven reindex of the codec and service registry, and generation-correct Harness close. [Test and context commands](phase-20-test-and-context-commands.md) extends `Command` with the `test` and `context` semantics, and the [service runtime](phase-22-service-runtime.md) with `service` | [Recursive lifecycle command](phase-17-recursive-lifecycle-command.md) |
| `Handoff.Completion`, `Handoff.Process`, `Handoff.Process.Route`, `Handoff.Runtime`, `Handoff.TerminalReport`, `Teardown`, `Teardown.Internal`, `Teardown.Executor.Internal` | The lifecycle process route, per-frame handoff runtime, semantic completion and terminal-report admission, child-first reverse, and receipt confirmation | [Recursive lifecycle command](phase-17-recursive-lifecycle-command.md) |
| `Lifecycle.Recovery`, `Lifecycle.ResourceRecord`, `Lifecycle.Closure` | Root-only parent-to-child recovery adapter construction, canonical value-bound resource records and complete rehydration, and the two closed Production close kinds (settled destroy, pre-effect refusal) | [Recovery and migration](phase-18-recovery-and-migration.md) |
| `Harness`, `Harness.Ownership`, `Harness.Lifecycle.Internal` | Exact generative run ownership, the assertion engine, report persistence, and same-run recreate | [Test harness and run ownership](phase-19-test-harness-and-run-ownership.md) |
| `Network`, `Network.Port`, `Registry`, `RegistryPlan`, `RoleLifecycle`, `Cluster.Shipped` | Scope-indexed reachability, finalized blob routes, stdin credential policy over shared Lift, the opaque role phase machine, and read-only far-frame exposure observation | [Composition and network algebra](phase-21-composition-and-network-algebra.md) |
| `Service`, `Service.Program` | Immutable narrowed role revisions, one typed handler path, and the closed effect-indexed `ServiceProgram` interpreted inside Serve. The [Dhall configuration phase](phase-7-dhall-configuration-and-project-model.md) supplies the config-family service registry inside `Service` | [Service runtime](phase-22-service-runtime.md) |
| `Cluster.Workload`, `Cluster.Workload.Binding`, `Command.Child.Reverse` | The prepared and settled chart/workload backend, the pure chart-declaration-to-workload binding, and core-managed reverse release of a child cluster | [Worked demo](phase-24-worked-demo.md) |

The [Python pre-binary floor](phase-1-python-pre-binary-floor.md), [test and context
commands](phase-20-test-and-context-commands.md), and [base image and warm
store](phase-23-base-image-and-warm-store.md) phases own no `hostbootstrap-core` module; their surfaces are
the Python bootstrapper, the `Command` extensions named above, and the base image, described below.

Public constructors and import boundaries are pinned by compile-fail and lexical source guards. A
descriptive wire value, backend result, or stable digest cannot substitute for the opaque authority its
owning boundary produces.

## Lifecycle Type Contract

Each contract below belongs to the owning phase of its module in the table above: specification
finalization and the plan to the [step algebra and project plan](phase-12-step-algebra-and-project-plan.md),
root entry, the root coordinator, and frame execution to the
[recursive lifecycle command](phase-17-recursive-lifecycle-command.md), and Production release, recovery, and
migration to [recovery and migration](phase-18-recovery-and-migration.md).

- Static authoring is `ProjectSpec cfg tcfg`; scope finalization creates an exact `FinalizedProjectSpec`.
  `ProjectPlan` retains the matching configuration, canonical root, topology, and non-empty forward graph.
- `CurrentFrame`, `ProjectFrame`, and `ValidatedContext` are pure plan/context evidence. Root command entry
  joins them to installed identity, store, lease, and verb authority before effects.
- The root coordinator alone retains the project's lifecycle `ProtectedStore` (journal, leases, mode, and
  sessions), the global snapshot/acquisition state, recursive catalog, and durable frame sessions. Child plan
  authority proves correspondence and grants no access to that store. The ownership stores of providers,
  clusters, the direct-Colima wall, the host wall, Harness runs, and a shipped frame-local ownership
  transaction are separate protected stores, each scoped to its own owner's transactions.
- A `FrameExecutor` exists only after authenticated admission. It exact-compares a signed prepared package
  against its local node and returns an observation for root settlement; it cannot select arbitrary store work.
- Reverse work derives from the same plan. Exact child settlement advances the parent forest, and only a
  complete destroy yields `DestroySettled`.
- Production release consumes `ProductionClosureAuthorization`, which has exactly two cases:
  - settled destroy: root invocation authority for the destroy verb, **and** the bound run lease, **and**
    proof that all sessions are closed, **and** `DestroySettled`; or
  - pre-effect refusal: a Production root whose unbound lease the release re-validates, under the protected
    entry, as having recorded no effects.

  Either case commits one redo transaction that closes the project journal, writes the lease as closed, and
  deletes the Production mode record as its last target; interrupted and exact repeated finalization
  converge.
- Recovery verifies complete canonical resource membership and rebinds it to a fresh broker. Migration stages
  the exact candidate, freezes the old revision, and activates only a complete settled set.

The canonical [lifecycle state model](../documents/architecture/lifecycle_state_model.md) links these contracts
to their exact source owners and validation suites.

## Ensure Reconcilers

The [ensure reconcilers phase](phase-8-ensure-reconcilers.md) owns the nine config-free `allReconcilers`
rows. Each probes, installs where its frame row supports installation, and re-probes; a missing
non-installable prerequisite produces a diagnostic. Each reconciler is a row over the closed host-frame
table, and that row is its host applicability:

| Reconciler | Host frames it applies to |
|---|---|
| `Ensure.Docker` | Linux (installs); Apple Silicon and Windows (provided elsewhere: the project Colima wall and the WSL2/provider path) |
| `Ensure.Incus` | Apple Silicon and Linux |
| `Ensure.Lima`, `Ensure.Homebrew`, `Ensure.Ghc`, `Ensure.AppleMetal` | Apple Silicon |
| `Ensure.Cuda` | Linux with an NVIDIA GPU |
| `Ensure.CudaWin` | Windows with an NVIDIA GPU |
| `Ensure.Wsl2` | Windows |

`Ensure.Colima` is a separate exact plan-owned adapter, not an additional entry in that registry. Its
resolver, bounded runner, descriptor-held ownership transaction, opaque managed state, and conditional force
cleanup belong to the [cluster lifecycle phase](phase-16-cluster-lifecycle-and-cordoning.md).

The [ensure guide](../documents/engineering/ensure_reconcilers.md#reconciler-inventory) is canonical for
each reconciler's applicability diagnostics, probe strength, and installation policy. The demo calls
`runEnsure` from composite provider/build actions instead of registering every call as an independent
`ensureStep`.

## Project Configuration

The [Dhall configuration and project model phase](phase-7-dhall-configuration-and-project-model.md) owns
this surface. The project-local `<project>.dhall` schema is canonical in
[schema.md](../documents/engineering/schema.md), and the runtime binary-context fields in
[binary_context_config.md](../documents/architecture/binary_context_config.md); this section summarizes them.

Core owns no project config type or default values. Production and Harness assembly share one restricted
read-only `ConfigAssembly`; test-init supplies the separate thin test configuration. `CodecWitness` joins
encoder/decoder schema agreement, and finalized `ProjectCodec` and `RoleCodec` retain scope and specification.
`SecretRef` is scope-indexed: plaintext requires exact Harness authority and has no Production constructor.

Descriptive context names a frame and its witnesses. Independent installed, handoff, build, or activation
evidence supplies authority. The root catalog derives and validates each child configuration against its
exact plan edge. Services receive only their narrowed `RoleParams` through `ProgramServiceHandler`, which
returns a closed `ServiceProgram`. The registry keeps the declared effect row, resource draft, backend, and
handler together through finalization and selection.

## Thin Python Bootstrapper

The [Python pre-binary floor phase](phase-1-python-pre-binary-floor.md) owns this surface. The root Poetry
project owns `hostbootstrap/` and `tests/`, and its one installed entry point is the `hostbootstrap` Click
application. Its commands fall into two groups:

- Operator commands, present in every install including the pipx one: `doctor` asserts the fail-fast host
  minimums; `build` establishes the pre-binary host floor and builds the project executable natively into
  `./.build/`; `run` does the same and then executes it with the forwarded arguments; and `update` is the
  explicit pipx self-update of the installed wrapper.
- Maintainer commands, registered only in this repository's Poetry development environment and refused
  elsewhere: `base build` and `base build-and-push` (owned by the
  [base image and warm store phase](phase-23-base-image-and-warm-store.md)), `check-code`, and `test-all`.

Python does not initialize project Dhall or provision the project's VM, image, cluster, workload, or teardown.
See the [Python/Haskell boundary](../documents/architecture/python_haskell_boundary.md).

## Base Image and Warm Store

The [base image and warm store phase](phase-23-base-image-and-warm-store.md) owns this surface. The
published rolling base tags are the source of truth for derived images. The base supplies the pinned
compiler and compatible warmed dependencies. Core and demo have their own host-compatible Cabal projects;
consumers do not swap projects or import a container-only freeze. Warm-store misses resolve normally.
Changing base inputs requires the directed rebuild/republish/pull workflow described by the
[base image guide](../documents/engineering/base_image.md).

## Command Tree

`CLI` belongs to the [core scaffolding phase](phase-2-haskell-core-scaffolding.md) and `Command` to the
[recursive lifecycle command phase](phase-17-recursive-lifecycle-command.md); the
[test and context commands phase](phase-20-test-and-context-commands.md) owns the `test` and `context`
semantics and the [service runtime phase](phase-22-service-runtime.md) the `service` semantics. The
[command-tree extension contract](../documents/architecture/hostbootstrap_core_library.md#command-tree-extension-contract)
is canonical for every verb, flag, and pre-parser entry.

Project binaries expose the fixed `project`, `test`, `service`, `context`, and `check-code` families.
`project up|down|destroy` enter the root coordinator. Nested lifecycle execution enters through
`Command.Child`'s fixed private argv marker, which `runCLI` recognizes before the optparse parser runs; it is
not a command-tree verb, does not appear in `--help`, and admits only an authenticated handoff.
`service run` verifies platform-installed immutable activation coordinates and never loads sibling full config.
`context` is read-only; `test` selects compiled cases and validated configuration variants through one matrix.
Projects extend typed registries and steps, not the verb tree.

## hostbootstrap-demo

The [worked demo](phase-24-worked-demo.md) composes the shared provider, durable share, guest alias, cluster,
registry, image, chart, exposure, and service surfaces. The universal CPU floor is `linux-cpu`. The
terminal acceptance phases confirm the rest on real hardware: the
[Apple Silicon substrate](phase-26-apple-silicon-substrate.md), [NVIDIA GPU
substrate](phase-27-nvidia-gpu-substrate.md), and [Windows and WSL2
substrate](phase-28-windows-and-wsl2-substrate.md) phases confirm each context's capabilities and placement,
and the [host-portability acceptance phase](phase-29-host-portability-acceptance.md) confirms that the
host static gate passes host-native on every supported gate host.
The [demo runbook](../documents/operations/demo_runbook.md) owns operator instructions.

## Update Rule

Change this inventory when a component's responsibility changes. Correct the owning constructive phase and
canonical topic document in the same change. Do not add a parallel status table, dated test total, or
prospective API sketch here.
