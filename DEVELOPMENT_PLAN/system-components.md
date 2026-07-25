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
| `HostBootstrap.CLI` | Partial | Fixed `project` / `test` / `service` / `context` / `check-code` entrypoint; typed case/variant integration is Phase 19.6, production/harness config-scope integration is Phase 19.7, and opaque validated `ProjectSpec`/step/service-selection construction is Phase 19.8 |
| `HostBootstrap.Command` | Partial | Parser/dispatch and command gates; exact `test`/`context` grammar plus command-specific missing-config recovery are Phase 17.4, and validated service dispatch is Phase 18.6 |
| `HostBootstrap.HostTool` | Partial | Closed tool enumeration and `AbsExe`; remaining bare host call sites are Phase 2.5 |
| `HostBootstrap.HostConfig` | Implemented | Resolved host configuration |
| `HostBootstrap.HostPrereqs` | Partial | Haskell host prerequisites; alignment with the real pre-binary Python floor is Phase 2.5 |
| `HostBootstrap.Substrate` | Implemented | Apple/Linux/Windows CPU/GPU substrate classification |
| `HostBootstrap.Ensure*` | Partial | Reconciler families exist; typed changed/unchanged/foreign/unsupported results, applied Colima ownership, and total provider capability probes remain in Sprints 5.8, 9.10, and 11.10. The existing `fitsBudget` predicate is not the sole wired admission authority |
| `HostBootstrap.Cluster.Cordon` | Partial | Quantity/resource builders and preflight exist, but config/preflight/provider launch retain duplicate budget authority, small-input floor rounding can violate the intended contained slice, Incus/WSL launch builders do not uniformly consume the admitted wall, and existing provider walls are not fully reconciled. Sprint 9.10 owns the indexed pure `ProviderWallSpec`/`EffectiveBudget`/fit/`BudgetPartition` algebra plus journaled same-spec live wall authority; Sprint 9.4 the bare-Linux storage decision; Sprints 5.7–5.8 and 11.10 the provider walls; Sprint 13.18 the complete demo workload projection; and Sprint 19.8 the single plan/config authority. |
| `HostBootstrap.Cluster.Lifecycle` | Partial | Cluster planning/lifecycle; Sprint 5.7 owns receipt-aware backend storage operations, while Sprint 10.9 owns Production/Harness mode/profile opening over Sprint 15.9's root authority |
| `HostBootstrap.Step` / `Chain` | Partial | Pure step chain; ownership-/phase-indexed interpreter state and one opaque lifecycle plan are Phases 9.10/16.6, while Phase 19.8 removes replacement setters and invalid/shadowing step identities |
| `HostBootstrap.Readiness` | Partial | Initial phantom witness and retry loop; the witness is forgeable through exposed `HostBootstrap.Readiness.Internal`, not resource-instance-bound, and probe outcomes are incomplete. Phase 9.10 owns repair |
| `HostBootstrap.Readiness.Internal` | Partial, exposed implementation escape hatch | The library publicly exposes `MkReady`; production `HostBootstrap.Readiness` imports it, while tests do not need the internal module. Phase 9.10 must make the constructor module-private and move tests to injected probes |
| `HostBootstrap.Context` | Partial | Descriptive binary context and command capability checks; opaque authority/narrowing is Phase 15.9 |
| `HostBootstrap.Substrate.Provider` | Partial | Provider launch/share/alias data; direct alias totality and exclusive ownership are Phase 11.10 |
| `HostBootstrap.Lift` | Implemented, pending type integration | Provider-backed nested command dispatch; becomes the sole route after Phase 11.10 |
| `HostBootstrap.HostTarget` | Definition-only | Parallel `Local \| InVM` predecessor with no production ownership; removal/consolidation is Phase 11.10 |
| `HostBootstrap.Incus` / `Lima` / `Wsl2` | Partial | Provider argv/probes and launch builders exist with uneven budget wiring. WSL has an unused import builder and its utility-VM wall is shared global state, not a per-distro wall; exclusive lease/CAS ownership, existing-wall reconciliation, and conflict refusal are Phase 11.10 |
| `HostBootstrap.Harness` | Partial | Variant execution/reporting; Phase 10.9 replaces cooperative ownership and Phase 10.10 removes the unconsumed `RunModel` selector |
| `HostBootstrap.Service` | Partial | Config-selected leaf handlers exist, but current dispatch uses an arbitrary string selector and demo handlers reload the full config; Sprint 14.6 integrates the phase-indexed role lifecycle, Sprint 15.9 supplies opaque runtime authority/one config snapshot, and Sprint 18.6 supplies a prevalidated-draft, one-use admission/plan-open gate plus exact-set non-live predecessor recovery and fenced lease-transfer barrier before the existential typed selected-service package; native accelerator real-run evidence remains open |
| `HostBootstrap.RoleLifecycle` | Definition-only | Initial role phase skeleton has tests but no production consumer after the demo role removal; Sprint 14.6 integrates/hides it behind `service run`, while Sprint 18.6 makes admission Reserved→Consumed, lost plan-open acknowledgment, non-live predecessor recovery, and lease transfer typed rather than callback convention |
| `HostBootstrap.Config.*` | Partial | Generic config classes/vocabulary/schema; typed case/variant IDs and removal of dead `testSuites` are Phase 19.6, while scope-indexed `SecretRef`/project config is Phase 19.7 |
| `HostBootstrap.Dhall.*` | Partial | Dhall generation/hoisting exists; Sprint 8.7 adds one validated encoder/decoder schema witness and complete `Core.dhall` drift coverage |
| `HostBootstrap.Registry` | Partial | Docker Hub credential discovery/forwarding exists, but raw-text/substring classification and environment transport remain open in Sprints 15.9/19.7; schema/artifact registration lives in `HostBootstrap.Dhall.Gen` |
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
through `ProjectSpec cfg tcfg`; core does not own universal project defaults. Context fields describe
placement and requested roles but do not themselves mint mutation authority.

Current partial surfaces:

- capability and witness constructors/record updates are not fully opaque (Phase 15.9);
- `addRole` unions classes/capabilities even when the primary context kind is incompatible:
  `service run` separately rejects a non-leaf primary kind, while `project up` can accept a widened
  daemon/image-build leaf (Phase 15.9);
- topology validation follows only the selected parent chain and executes only supplied runtime
  witnesses; it does not reject every duplicate/cycle/disconnected frame or prove that the required
  witness set is complete (Phase 15.9);
- `project up` and demo service handlers reopen the sibling config after initial validation, so one
  invocation can mix config versions; Phase 15.9 threads one `ValidatedConfig` into plan construction
  and closed plan operations, while Phase 18.6 gives a service handler only the matching
  `ValidatedServiceRequest specDigest configId secretDigest fields service`/
  `RoleParams specDigest configId secretDigest fields service` through a
  closed `ServiceProgram`, never the snapshot or full config;
- `psServiceVariant` is an arbitrary string selector, service projection invents fallback
  ports/timeouts, and service/daemon configs retain unrelated fields; an opaque request/parameter/handler
  package, consumer-indexed field filter, effect-indexed authorization proof, and total role-specific
  projection are Sprints 18.6/19.8;
- `TestConfig.testSuites :: [Text]` is decoded but dead, while case/variant identity is stringly (Phase
  19.6);
- `SecretRef = < Vault | TransitKey | Prompt | TestPlaintext >` is unscoped, so a production project
  config can represent `TestPlaintext`; exclusion is only consumer/code-check policy (Phase 19.7);
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
| `build` | Partial | Explicit Cabal-file selection; one validated package/executable/config identity; offline/index and unchanged-copy behavior are Phase 6.7 |
| `run` | Partial | Build host-native and invoke (POSIX `exec`; Windows child subprocess); inherits the Phase 6.7 selection/idempotence work |
| `update` | Implemented | Explicit operator-invoked pipx self-update |
| `base build` | Partial | Native-architecture validation and reproducible input gate are Phase 6.7 |
| `base build-and-push` | Partial | Full Python+Haskell gate, digest record, pull, and derived validation are Phase 6.7 |
| `check-code` / `test-all` | Partial | Maintainer-only by intent; Phase 6.7 replaces dependency importability with verified repository-development authority |

Python does not own project Dhall, Docker/provider ensure, project-container construction, lifecycle, or
runtime cordons.

## Base Image and Warm Store

The base image contains the Haskell toolchain, build tools, Kubernetes/container tools, and layered Cabal
warm store. It contains no project binary and exposes no freeze-only integration `LABEL`/`ENTRYPOINT`.
Projects integrate by Cabal dependency plus `runHostBootstrapCLI`.

Open contracts:

- mutable base tags must become pulled, digest-qualified derived-build inputs (Phase 6.7);
- requested architecture must match the native host/engine before build or publish (Phase 6.7);
- maintainer parser construction must require verified repository-development provenance rather than
  importable dev dependencies (Phase 6.7);
- host-native and Linux-container Cabal projects must be distinct so only the container imports
  `/opt/basecontainer/.../*.freeze` (Phase 12.4);
- network-resolved installers/tools must be versioned or integrity-pinned (Phase 12.4); and
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

- thread one typed Production plan and a harness-only `TestComponent`;
- derive every cluster/root/port identity from the opaque lifecycle profile;
- pull and resolve the published base to a digest before derived build;
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
