# System Components

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [00-overview.md](00-overview.md),
[development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Inventory the host-management components the repository implements, identify partial or
> definition-only surfaces honestly, and point each open contract to its owning phase.

## Status and Evidence Rule

Current phase status is reported only by the
[README phase table](README.md#current-phase-status). This inventory contains no phase-status roll-up and
no mutable “current test count.” Dated validation evidence belongs in phase sprints.

`Implemented` below means the named module/surface exists. `Partial` means code exists but does not yet
satisfy the target contract. `Definition-only` means the exposed surface has no production consumer and is
a cleanup obligation. A target row is not an implementation claim.

## hostbootstrap-core Module Surface

| Module | State | Purpose / open contract |
|--------|-------|-------------------------|
| `HostBootstrap.CLI` | Implemented construction boundary | Fixed command entrypoint; scope-indexed Production/Harness integration, opaque `ProjectSpecBuilder`/`ProjectSpec`, additive streams, checked single-assignment slots, and finalized typed service registry are implemented. Receipt-aware lifecycle authority remains in its owning phases |
| `HostBootstrap.Command` | Partial | Parser/dispatch and command gates; exact `test`/`context` grammar plus command-specific missing-config recovery are Phase 17.4, and validated service dispatch is Phase 18.6 |
| `HostBootstrap.HostTool` | Implemented boundary | Closed tool enumeration and `AbsExe`; Sprint 2.5 closed the remaining governed bare-host call sites |
| `HostBootstrap.HostConfig` | Implemented | Resolved host configuration |
| `HostBootstrap.HostPrereqs` | Implemented floor | Haskell host prerequisites aligned with the real pre-binary Python floor by closed Sprint 2.5 |
| `HostBootstrap.Substrate` | Implemented | Apple/Linux/Windows CPU/GPU substrate classification |
| `HostBootstrap.Ensure*` | Partial | The nine config-free reconciler families remain; Colima is a separate plan-bound per-project adapter. Incus now converges and totally classifies daemon reachability, permission, VM capability, and required image-server egress, and only the ready branch mints its opaque capability. WSL global-state ownership and recursive command integration remain downstream. The existing `fitsBudget` predicate is not the sole wired admission authority |
| `HostBootstrap.Cluster.Cordon` | Implemented pure parser/builder boundary, partial live enforcement | Exact whole-byte quantity parsing, resource builders, capacity preflight, and the typed bare-Linux `StorageCordonUnsupported` policy exist. Whole-GiB providers reject inexact hard ceilings instead of rounding upward. Direct Colima has an exact observed project-wall adapter; Incus/WSL and existing Lima walls are not fully reconciled, while conditional cleanup remains Sprint 5.7 work |
| `HostBootstrap.Cluster.Budget` | Implemented Phase 9 foundation plus Colima adapter | Closed provider keys; plan-indexed validated/effective budget; workload fit; constructive partitions/slices; and journal-before-call wall reservation/preparation/settlement are opaque. WSL success returns its lease inseparably and uncertain acquisition returns no authority. Sprint 13.18 owns the complete demo workload projection; remaining provider phases own their live CAS/adapters |
| `HostBootstrap.Cluster.Lifecycle` | Partial | Cluster planning/lifecycle; Sprint 5.6.1 closed canonical project-root admission and the direct-host durable projection, Sprint 5.7 owns receipt-aware backend storage operations, and Sprint 10.9 owns Production/Harness mode/profile opening over Sprint 15.9's command authority |
| `HostBootstrap.Step` / `Chain` | Implemented forward-plan boundary, partial lifecycle | Opaque steps, disjoint typed identities, explicit reverse policy, operation keys/dependency prefixes, exact-order `StepPlan` validation, and one plan consumer are implemented; receipt-driven recursive interpretation remains Phase 16.6 |
| `HostBootstrap.Readiness` | Implemented Phase 9 foundation, partial live integration | Opaque validated polling and total results; closed backend probes require exact planned resources and mint generative plan/resource/dependency-indexed readiness. `ObservedReady` is explicitly non-authorizing compatibility evidence. Provider/interpreter phases own migration of live effects to prepared operations |
| `HostBootstrap.Reconcile` | Implemented Phase 9 foundation | Final-codec/step-plan lifecycle identity; opaque planned resources/edges, reconcile/adoption outcomes, prepared operation pairs, phase-indexed handles, and legal persisted journal transitions. Direct Colima acquisition is implemented; live protected-store and remaining adapter interpretation continue in Sprints 5.7, 10.9, 11.10, 15.9, and 16.6 |
| `HostBootstrap.Context` | Partial | Descriptive binary context and command capability checks; closed Sprint 5.6.1 resolves `sourceRoot` separately without rewriting the context, and opaque command authority/narrowing is Phase 15.9 |
| `HostBootstrap.ProjectRoot` | Implemented foundation | Private rank-2 canonical-root admission, same-root host durable projection, and the typed direct-host mount adapter are implemented; the final opaque plan and remaining boundary projections are owned by Sprints 10.9, 11.10, 16.6, and 19.8 |
| `HostBootstrap.Substrate.Provider` | Partial | Single provider launch/share/alias data route; direct-host aliases are removed. `Provider.Alias` supplies opaque prepared call/release and receipt-shaped definitions, but no provider-guest backend can yet supply the same-privilege-resistant conditional mutation/delete primitive, so production still uses the non-authorizing compatibility path |
| `HostBootstrap.Lift` | Implemented, pending operation integration | Sole provider-backed nested command dispatch; live provider mutations still need the plan-owned prepared-operation pair |
| `HostBootstrap.Incus` / `Lima` / `Wsl2` | Partial | Provider argv/probes and launch builders exist with uneven budget wiring. Incus has a total capability/egress classifier and the unused WSL import builder is gone. The production WSL utility-VM wall still follows the legacy backup path and has no platform-authoritative lease/CAS |
| `HostBootstrap.Wsl2.GlobalWall` | Implemented pure foundation, not production authority | Exact present/absent origin, durable unknown phases, FILE_ID-bound stage/apply/restore classification, opaque receipt/authority values, and conflict-only recovery are modeled and focused-tested; protected generation/fence/tombstone integration and distinct live-versus-teardown authority remain open |
| `HostBootstrap.Wsl2.GlobalWall.ConfigBytes` / `Windows` | Partial platform foundation | Strict bounded UTF-8/UTF-16 transformation and a bound-thread Win32 FILE_ID/hard-link/Registry adapter are focused-tested. HKCU plus an advisory named mutex is cooperative and cannot mint § EE authority; a protected service/broker, production integration, runtime-effective wall observation, and native/live fault gates remain open |
| `HostBootstrap.Harness` | Implemented typed foundation, partial ownership | Opaque typed case/variant matrix, selection, and reporting are implemented; Phase 10.9 replaces cooperative ownership |
| `HostBootstrap.Service` | Implemented typed codec/request boundary, partial runtime | Closed typed registry definitions bind identity/projection/role codec/handler; finalization shares one digest with the full codec, service dispatch verifies one snapshot, and handlers receive only typed role fields plus safe framework view. Sprint 18.6 replaces raw handler `IO` with one-use effect-indexed execution; Sprint 14.6 integrates the phase lifecycle; native accelerator real-run evidence remains open |
| `HostBootstrap.RoleLifecycle` | Definition-only | Initial role phase skeleton has tests but no production consumer after the demo role removal; Sprint 14.6 integrates/hides it behind `service run`, while Sprint 18.6 makes admission Reserved→Consumed, lost plan-open acknowledgment, non-live predecessor recovery, and lease transfer typed rather than callback convention |
| `HostBootstrap.Config.*` | Implemented root/config-role boundary, partial handoff | Generic scope-indexed config classes, opaque secret refs, canonical verification, common framework view, full-vs-role/scope discriminators, `RoleCodec`, request, and role parameters are implemented. Authenticated child handoff/command authority remain Phases 15.9/16.6 |
| `HostBootstrap.Dhall.*` | Implemented foundation | Opaque `CodecWitness` owns schema/decode/render, opaque artifacts require an admitted codec, literal schema commands are snapshotted, every current `Core.dhall` type export is equality-owned, and Phase 19's `ProjectCodec` supplies installed identity/scope/spec-digest binding |
| `HostBootstrap.Registry` | Partial | Docker Hub credential discovery/forwarding exists, but raw-text/substring classification and environment transport remain open in Sprints 15.9/19.7; schema/artifact registration lives in `HostBootstrap.Dhall.Gen` |
| `HostBootstrap.Network` / `HostBootstrap.RegistryPlan` | Target only | Sprint 14.7 owns scope-indexed endpoints/clients/exposures, proof-gated blob delivery, opaque finalized registry plans, and route-specific readiness; Sprint 13.20 consumes them in the demo |
| `HostBootstrap.DocValidator` | Implemented | Mechanical documentation checks; new drift floors are Phase 21.4 |

## Lifecycle Type Contract

The target lifecycle algebra is shared, not reimplemented by provider/demo code:

```text
opaque resource identity
  -> total ProbeResult
  -> generative Ready lifecycle-scope plan resource-instance dependency
  -> plan-internal complete-edge traversal + fresh OperationDependencySnapshot
  -> plan-owned closed OperationPreconditionSet (exact zero/one/many edges + probes + call digest)
  -> protected prepare revalidation
  -> matching PreparedOperation + PreparedPreconditions
  -> lifecycle-scope-, plan-, ownership-, and phase-indexed conditional backend transition
  -> Either ReconcileError
       (ReconcileResult scope planId id resource Observed targetPhase)

ReconcileResult
  = ManagedResult
      (opaque ManagedTransition binding, as one value:
         ResourceHandle ... Managed targetPhase
         + OwnershipReceipt ... id resource
         + ManagedOutcome ... Observed targetPhase)
  | ForeignResult
      (ResourceHandle ... Unmanaged targetPhase)
      (Observation ... id resource)

ReconcileError
  = Conflict ConflictReason
  | SafetyRefusal RefusalReason
  | Unsupported UnsupportedReason
  | Failure FailureContext RecoveryDisposition
```

A managed unchanged result preserves teardown authority. A foreign result grants an `Unmanaged` handle
that cannot be passed to mutation or teardown; explicit adoption requires matching opaque authority and
returns a managed handle plus receipt. Recursive teardown consumes only receipts acquired by that run.
The generative `planId` also prevents two Production plans from exchanging handles, journals, or
receipts. `Down` and `Destroy` have distinct teardown-plan types; the durable root remains in the plan
under `Preserve`.
Retained `Ready` values never enter a backend adapter. Prepare reruns the plan-owned probes and
identity/version checks; only the jointly returned prepared pair can call the effect, and a backend that
cannot condition the call on that prepared version is `Unsupported`.
Ordinary project teardown preserves it in both scopes; an exact settled/no-project-effects closure proof
plus the bound harness lease can mint a harness-only terminal close plan for that run's generated config
and `.test_data`.

The target execution profile is opaque:

```text
LifecycleProfile (Production projectId)
LifecycleProfile (Harness projectId runId)
RecoveredProductionLifecycleProfile projectId specDigest planDigest planId brokerGeneration
```

Phase 15.9's independent non-config gate mints only exact root invocation authority. Phase 10.9 owns all
profile opening: fresh Production/Harness profiles require their still-unbound lease, while configful
abandoned Production `ProjectUp` requires the exact root/mode/bound-lease/snapshot/recovery tuple and can
open only the indexed recovered profile. Exclusive harness ownership can open only its run-indexed fresh
profile; Harness/teardown recovery cannot inhabit the Production recovery type. Exact verb/frame/phase command
authority is derived later from that root, the validated plan/context, and the journal cursor.
`containerPlan` derives cluster
name, data root, ports, and ownership identity from the profile. A
`TestComponent` receives only harness-profile authority and cannot call the Production planner.
Successful Production `ProjectUp`/`ProjectDown` closes only its terminally acknowledged
`BoundRunLease`/broker invocation; Production mode, active snapshot/revision, Open-project state, and
resource records remain. Destroy/true-pre-effect project closure is the separate mode-release path.

## Ensure Reconcilers

| Reconciler family | Host applicability | Notes |
|-------------------|--------------------|-------|
| Docker | supported host substrates | Post-binary dependency |
| Homebrew / GHC | Apple Silicon | Core reconcilers are Apple-only; Linux/guest toolchain bootstrap follows the separate bootstrap/lift path |
| Colima / Lima | Apple Silicon | Provider-specific |
| Incus | Apple/Linux | Apple Incus is explicit-provider support; demo default uses Lima |
| WSL2 | Windows | Provider install/readiness; provisioning route consolidation is Phase 11.10 |
| CUDA | Linux GPU | Requires detected NVIDIA device/driver visibility |
| CUDA Windows | Windows GPU | Host-native build stack |
| Apple Metal | Apple Silicon | Host-native accelerator build stack |

Reconcilers must adopt the Phase 9 `ReconcileResult` contract. A mere executable-present Boolean is not
the final reconciler state model.

## Project Configuration

Each built project binary owns a sibling `<project>.dhall`. The current config type is project-defined
through `ProjectSpec projectId cfg tcfg`, where `cfg` is scope-indexed; core does not own universal
project defaults. One restricted `psAssemble` supplies Production and Harness configs, and matching
mapped codecs admit their distinct wire schemas. Context fields describe placement and requested roles
but do not themselves mint mutation authority.

Current partial surfaces:

- capability and witness constructors/record updates are not fully opaque (Phase 15.9);
- `addRole` unions classes/capabilities even when the primary context kind is incompatible:
  `service run` separately rejects a non-leaf primary kind, while `project up` can accept a widened
  daemon/image-build leaf (Phase 15.9);
- topology validation follows only the selected parent chain and executes only supplied runtime
  witnesses; it does not reject every duplicate/cycle/disconnected frame or prove that the required
  witness set is complete (Phase 15.9);
- `project up` step actions can still reopen the sibling config after initial validation, so one
  invocation can mix config versions; service dispatch no longer does—it canonically verifies one
  snapshot and closes the action over its request. Phase 15.9 threads one `ValidatedConfig` into plan
  construction and closed plan operations, while Phase 18.6 gives a service handler only the matching
  `ValidatedServiceRequest specDigest configId secretDigest fields service`/
  `RoleParams specDigest configId secretDigest fields service` through a
  closed `ServiceProgram`, never the snapshot or full config;
- the arbitrary string selector and fallback parameters are removed; role wires contain framework
  validation plus only selected service fields, while the full generated service/daemon config still
  retains unrelated plan fields. Effect-indexed authorization and one-use execution remain Sprint 18.6;
- typed `CaseId`/`VariantId` and the total `TestMatrix` relation are implemented, while the demo's
  concrete variants remain hard-coded until Phase 20.5;
- `SecretRef scope` is opaque; Production cannot represent `TestPlaintext`, and Harness plaintext
  requires the matching generative run authority. Cross-process child grants remain downstream;
- the demo variants are hard-coded rather than generated from `<project>.test.dhall` (Phase 20.5); and
- the current production/test profile can be selected without authority-indexed construction, and the
  self-invoked child receives no authenticated one-time authority handoff. Sprint 5.7 supplies the
  backend operations/receipts; Sprint 15.9 supplies the independent root and command gate; Sprint 10.9
  owns the mode/profile opener; and Sprint 16.6 consumes them in the recursive plan.

The target test configuration uses validated `CaseId` and `VariantId` values and a project-owned typed
projection from `tcfg` to labeled `cfg` variants. `all` is a parser selector over registered case IDs, not
stored configuration.

The target secret boundary uses `SecretRef scope` and a project-owned `ProjectConfig scope` (or equivalent
`cfg :: Type -> Type`, consumed as `cfg scope`). `SecretRef (Production projectId)` exposes only `Vault`,
`TransitKey`, and `Prompt`;
`TestPlaintext` requires matching `HarnessConfigAuthority projectId runId` and constructs only
`SecretRef (Harness projectId runId)`. Ordinary init/decode/dispatch remains project-indexed Production;
pure `psTestMatrix` validates stable variant drafts, then a fresh per-variant
`HarnessAuthority projectId runId` enters the shared `psAssemble`. Separate Dhall
schemas reject test plaintext on the production path before mutation. Harness Dhall decodes to an
untrusted wire type; exact `ConfigHandoff` grant/byte verification jointly produces the generic
`VerifiedConfigWire`, `VerifiedHandoff`, child-local config authority, and `ValidatedConfig` under one
fresh identity, including pointer-only configs. Controller restarts use a separately signed,
config-digest-bound runtime manifest rather than replaying that edge handoff. Raw wire cannot be promoted
merely because run authority exists, and no exported coercion can widen harness config into production
or another project/run.

## Thin Python Bootstrapper

| Surface | State | Contract / open work |
|---------|-------|----------------------|
| `doctor` | Implemented | Report the irreducible pre-binary host floor |
| `build` | Implemented | Explicit Cabal-file selection, one validated package/executable/artifact identity, conditional index refresh, explicit offline refusal, and unchanged-copy no-op |
| `run` | Implemented | The same idempotent host-native build followed by POSIX `exec` or a Windows child subprocess |
| `update` | Implemented | Explicit operator-invoked pipx self-update |
| `base build` | Implemented | Verified repository authority, native request/host/engine architecture equality, and the complete Python/core/demo source gate precede local inspection builds |
| `base build-and-push` | Implemented | Current-compatible resolution → source gate → native build → push rolling tag → pull → real-demo compatibility smoke; a digest may identify the pulled build without locking inputs |
| `check-code` / `test-all` | Implemented | Exposed only from the canonical checkout's in-project Poetry development interpreter through opaque maintainer authority |

Python does not own project Dhall, Docker/provider ensure, project-container construction, lifecycle, or
runtime cordons.

## Base Image and Warm Store

The rolling base image contains the Haskell toolchain, build tools, Kubernetes/container tools, and a
broad best-effort Cabal warm store selected from current compatible upstream versions at build time. It
contains no project binary and exposes no freeze-only integration `LABEL`/`ENTRYPOINT`. Projects
integrate by Cabal dependency plus `runHostBootstrapCLI`, use the same `cabal.project` on the host and in
a derived container, and may resolve/download/compile dependencies on a cache miss.

Open contracts:

- the demo's pulled rolling-base consumption remains Phase 13.18;
- one host-compatible consumer project and opportunistic cache reuse are Phase 12.4;
- rolling build-time discovery must select current compatible releases over TLS and retain available
  integrity checks without becoming a committed replay lock (Phase 12.4); and
- documented vanilla/dynamic shared-library ways must be mechanically matched to the artifacts actually
  present; profiling remains off unless explicitly enabled and validated (Phase 12.4).

## Command Tree

The supported top-level project-binary tree is:

```text
project init|up|down|destroy
test init
test run <case-id>|all
service init|schema|run
context ...
check-code
```

Phase 17.4 owns exact parser/gate reconciliation, including which `context` operations exist and which
commands may run without a sibling config. No project-appended verbs or standalone `ensure` command are
part of the target tree.

## hostbootstrap-demo

The demo is the worked consumer. Its current code includes VM/direct provider paths, kind/nvkind,
MinIO-backed registry storage, a web SPA, service ConfigMaps, and accelerator worker/daemon paths.

Open demo contracts:

- the host Docker client can currently receive a `307` redirect to cluster-only
  `minio.default.svc`; Sprint 13.20 replaces the raw topology and proves repeated push/pull plus
  registry-pod persistence;
- thread one typed Production plan and a harness-only `TestComponent`;
- derive every cluster/root/port identity from the opaque lifecycle profile;
- pull the published rolling base before a derived compatibility build; a resolved digest may identify
  that workflow input without becoming a consumer lock;
- reconcile stale Harbor/appended-verb metadata with the current registry/MinIO path;
- drive typed cases/variants from decoded test config;
- add the threaded RTS contract to the static demo test component and restore the canonical `cabal test all`
  gate (Sprint 13.19); and
- complete the named native accelerator and durability real-run gates.

Phase 13 owns demo wiring/provenance; Phase 20 owns config-driven variants; generic harness/type work
remains in Phases 10 and 19.

## Update Rule

When a component changes, update this inventory's state/purpose, the owning phase, the cleanup ledger, and
the governed canonical documentation together. Do not add a phase status or test-count roll-up here.
