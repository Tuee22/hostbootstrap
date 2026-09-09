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

| Component family | Responsibility | Owning phase |
|---|---|---|
| `DocValidator` | Governed metadata, links, plan doctrine, status harmony, architecture drift, cited-path resolution, and gate-evidence currency checks | [Governance](phase-0-governance-and-documentation-standards.md), [documentation reconciliation](phase-29-documentation-reconciliation.md) |
| `Digest` | The one SHA-256 spelling and the sorted, length-prefixed path-set measurement gate evidence and build authority both use | [Governance](phase-0-governance-and-documentation-standards.md), [base image and warm store](phase-23-base-image-and-warm-store.md) |
| `CLI`, `Command` | Closed command tree and identity-parametric project specification | [Core scaffolding](phase-2-haskell-core-scaffolding.md), [recursive lifecycle](phase-17-recursive-lifecycle-command.md) |
| `HostTool`, `HostConfig`, `HostPrereqs`, `Substrate`, `Detached` | Absolute tool resolution, host classification, prerequisite floor, and sealed detached process launch | [Host tools and substrate detection](phase-3-host-tools-and-substrate-detection.md) |
| `Effect.Quote`, `Effect.Run`, `Effect.Vocabulary`, `Effect.Interpreter`, `Effect.ChildGroup` | One quoter per grammar, process runner, described effect vocabulary, interpreter, and the one bounded escalation that ends a child process group | [Host tools and substrate detection](phase-3-host-tools-and-substrate-detection.md), [authenticated handoff](phase-13-authenticated-handoff-and-child-admission.md) |
| `Protected` | Exact protected-store identity, exclusive entries, canonical records, and compare-and-swap | [Protected store](phase-4-protected-store.md) |
| `Authority`, `Identity.Install` | Executable-bound installed identity, root liveness, scope, and closed invocation authority | [Installed identity and authority kernels](phase-5-installed-identity-and-authority-kernels.md) |
| `Readiness`, `Reconcile`, `Cluster.Cordon.Foundation` | Opaque readiness, total observations and results, canonical quantities, and exact capacity/sizing policy | [Canonical quantities and reconcile results](phase-6-canonical-quantities-and-reconcile-results.md) |
| `Config.*`, `Dhall.Gen`, `Context`, `Lift.Context`, `Cluster.Cordon` | Scope-indexed codecs and configuration, reflected schemas, descriptive topology, pure lift records, and config-facing budget adapters | [Dhall configuration and project model](phase-7-dhall-configuration-and-project-model.md) |
| `Ensure.*`, `Ensure.GuestBootstrap`, `Lift` | Config-free probe/install/reprobe reconcilers, closed pre-binary guest bootstrap, and shared crossing fold | [Ensure reconcilers](phase-8-ensure-reconcilers.md) |
| `Lifecycle.Mode` | Production/Harness exclusion, run leases, and one-use profile admission | [Lifecycle modes and leases](phase-9-lifecycle-modes-and-run-leases.md) |
| `Reconcile`, `Lifecycle.ResourceRecord`, `Lifecycle.Plan` | Indexed resource identity, handles, canonical membership, and legal journal transitions | [Step algebra and project plan](phase-12-step-algebra-and-project-plan.md) |
| `Lifecycle.Prepared`, `Lifecycle.Session`, `Lifecycle.Transaction` | Fresh complete dependency checks, fenced operation permits, settlement, and canonical multi-record redo | [Sessions, journal, and fences](phase-10-sessions-journal-and-fences.md), [prepared operations](phase-11-prepared-operations.md), [recovery and migration](phase-18-recovery-and-migration.md) |
| `Step`, `ProjectPlan`, `ProjectPlan.Construct`, `ProjectPlan.Frame`, `ProjectPlan.Snapshot`, `Cluster.Budget` | One admitted graph, exact finalization and frame joins, forward/topology/reverse projections, snapshots, and plan-indexed budget admission | [Step algebra and project plan](phase-12-step-algebra-and-project-plan.md) |
| `Handoff`, private Protocol/Receiver/Relay | Root-signed scope capsules, exact payload and recovery bindings, bounded canonical wire, and keyless relay | [Authenticated handoff](phase-13-authenticated-handoff-and-child-admission.md) |
| `Ownership.*`, `Harness.DataRoot`, `Harness.GeneratedConfig`, `Wsl2.GlobalWall` | Four-clause ownership primitives and host-local transactions over exact kernel identities | [Ownership clauses and reservations](phase-14-ownership-clauses-and-reservations.md) |
| `Substrate.Frame`, `Substrate.Provider.*`, `Ownership.Shipped`, `Incus`, `Lima`, `Wsl2` | Closed provider rows, shared lifecycle operations, prepared provider/share/alias authority, and frame-local ownership transport | [Host providers and lift](phase-15-host-providers-and-the-lift.md) |
| `Cluster.Backend`, `Cluster.Ownership`, `Cluster.Lifecycle`, `Cluster.Resume`, `Ensure.Colima` | Exact provider/cluster/budget binding, backend identity, applied cordon, fresh readiness, owned exposure, and conditional cleanup | [Cluster lifecycle and cordoning](phase-16-cluster-lifecycle-and-cordoning.md) |
| `Command.LifecycleEntry`, `Command.Child`, `Lifecycle.RootedPlan`, `Lifecycle.Rooted`, `Handoff.Process`, `Teardown` | One root catalog/store, storeless frame execution, authenticated descent, child-first reverse, and receipt confirmation | [Recursive lifecycle command](phase-17-recursive-lifecycle-command.md) |
| `Lifecycle.Mode`, `Lifecycle.Session`, `Lifecycle.Transaction` recovery consumers | Complete resource rehydration, migration freeze/activation, exact reverse intent, and proof-complete terminal closure | [Recovery and migration](phase-18-recovery-and-migration.md) |
| `Harness`, `Harness.Ownership.Internal` | Exact generative run ownership, assertion engine, report persistence, and same-run recreate | [Test harness and run ownership](phase-19-test-harness-and-run-ownership.md) |
| `test` and `context` command consumers | Closed case/variant matrix and read-only config/artifact introspection | [Test and context commands](phase-20-test-and-context-commands.md) |
| `Network`, `Registry`, `RegistryPlan`, `RoleLifecycle` | Scope-indexed reachability, finalized blob routes, stdin credential policy over shared Lift, and opaque role phase machine | [Composition and network algebra](phase-21-composition-and-network-algebra.md) |
| `Service`, `Service.Program`, `Activation` | Immutable narrowed role revisions, signed activation, one typed handler path, and effect-indexed Serve | [Service runtime](phase-22-service-runtime.md) |
| `Build` | Attested build inputs, measured source identity, and one-use build authority | [Base image and warm store](phase-23-base-image-and-warm-store.md) |

Module families include Cabal-private representation and backend modules. Public constructors and import
boundaries are pinned by compile-fail and lexical source guards. A descriptive wire value, backend result,
or stable digest cannot substitute for the opaque authority its owning boundary produces.

## Lifecycle Type Contract

- Static authoring is `ProjectSpec cfg tcfg`; scope finalization creates an exact `FinalizedProjectSpec`.
  `ProjectPlan` retains the matching configuration, canonical root, topology, and non-empty forward graph.
- `CurrentFrame`, `ProjectFrame`, and `ValidatedContext` are pure plan/context evidence. Root command entry
  joins them to installed identity, store, lease, and verb authority before effects.
- The root coordinator alone retains `ProtectedStore`, the global snapshot/acquisition state, recursive
  catalog, and durable frame sessions. Child plan authority proves correspondence and grants no durable access.
- A `FrameExecutor` exists only after authenticated admission. It exact-compares a signed prepared package
  against its local node and returns an observation for root settlement; it cannot select arbitrary store work.
- Reverse work derives from the same plan. Exact child settlement advances the parent forest, and only a
  complete destroy yields `DestroySettled`.
- Production release consumes `ProductionClosureAuthorization`: either exact destroy, bound lease, closed
  sessions and settled proof, or an independently verified unbound pre-effect root. Durable redo closes the
  project journal and lease before deleting mode; interrupted and exact repeated finalization converge.
- Recovery verifies complete canonical resource membership and rebinds it to a fresh broker. Migration stages
  the exact candidate, freezes the old revision, and activates only a complete settled set.

The canonical [lifecycle state model](../documents/architecture/lifecycle_state_model.md) links these contracts
to their exact source owners and validation suites.

## Ensure Reconcilers

The nine config-free `allReconcilers` families probe, install where supported, and re-probe. A missing
non-installable prerequisite produces a diagnostic. `Ensure.Colima` is a separate exact plan-owned adapter,
not an additional entry in that registry. Its resolver, bounded runner, descriptor-held ownership transaction,
opaque managed state, and conditional force cleanup belong to the cluster phase.

The [ensure guide](../documents/engineering/ensure_reconcilers.md) records each probe's actual strength and
installation policy. The demo calls `runEnsure` from composite provider/build actions instead of registering
every call as an independent `ensureStep`.

## Project Configuration

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

The root Poetry project owns `hostbootstrap/`, `tests/`, and `stubs/`. Ordinary `doctor`/`build`/`run`
establish the pre-binary host floor, build the project executable natively into `./.build/`, and execute it.
Python does not initialize project Dhall or provision the project's VM, image, cluster, workload, or teardown.
See the [Python/Haskell boundary](../documents/architecture/python_haskell_boundary.md).

## Base Image and Warm Store

The published rolling base tags are the source of truth for derived images. The base supplies the pinned
compiler and compatible warmed dependencies. Core and demo have their own host-compatible Cabal projects;
consumers do not swap projects or import a container-only freeze. Warm-store misses resolve normally.
Changing base inputs requires the directed rebuild/republish/pull workflow described by the
[base image guide](../documents/engineering/base_image.md).

## Command Tree

Project binaries expose the fixed `project`, `test`, `service`, `context`, and `check-code` families.
`project up|down|destroy` enter the root coordinator; nested execution uses the authenticated private entry.
`service run` verifies platform-installed immutable activation coordinates and never loads sibling full config.
`context` is read-only; `test` selects compiled cases and validated configuration variants through one matrix.
Projects extend typed registries and steps, not the verb tree.

## hostbootstrap-demo

The [worked demo](phase-24-worked-demo.md) composes the shared provider, durable share, guest alias, cluster,
registry, image, chart, exposure, and service surfaces. The universal CPU floor is `linux-cpu`; Apple,
NVIDIA, and Windows capabilities and placement are confirmed by their respective terminal acceptance phases.
The [demo runbook](../documents/operations/demo_runbook.md) owns operator instructions.

## Update Rule

Change this inventory when a component's responsibility changes. Correct the owning constructive phase and
canonical topic document in the same change. Do not add a parallel status table, dated test total, or
prospective API sketch here.
