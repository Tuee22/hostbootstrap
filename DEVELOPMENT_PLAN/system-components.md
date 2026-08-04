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
| `HostBootstrap.CLI` | Implemented construction boundary | Fixed command entrypoint; scope-indexed Production/Harness integration, opaque `ProjectSpecBuilder`/`ProjectSpec`, additive root-bound step fragments and other additive streams, and finalized typed service registry are implemented. There is no lifecycle slot beside the plan: descent and reverse are declared on the step. Receipt-aware lifecycle authority remains in its owning phases |
| `HostBootstrap.Command` | Partial | Parser/dispatch and command gates; exact `test`/`context` grammar plus command-specific missing-config recovery are Phase 17.4, and validated service dispatch is Phase 18.6 |
| `HostBootstrap.Detached` | Implemented boundary | The closed boundary for spawning a child that outlives its launcher (§ HH, Sprint 2.7, landed 2026-08-03). Its assembled `CreateProcess` is private, and so are `DetachedLaunch`'s constructor and *every field accessor*, so the stdio disposition, descriptor inheritance, session, and console detachment are properties of the boundary rather than fields a call site fills in; the executable is an `AbsExe` and the working directory and output sink are absolute by construction. `withDetachedChild` is a rank-2 bracket over the launch, not the child's lifetime: acquire-and-spawn is total, and the body's exceptions propagate unchanged. Standard input is the host's null device (open, at EOF) and both output streams share one retained sink the launcher reads to quote a startup failure (§ CC). `ForgeDetachedLaunch.hs`/`RelabelDetachedLaunch.hs` pin the seals and `DetachedSpec` observes a real child through the boundary. Closed on the Apple Silicon lane 2026-08-03 at `10/10 passed`, where the host daemon reached readiness on all four bring-ups |
| `HostBootstrap.HostTool` | Implemented boundary | Closed tool enumeration and `AbsExe`; Sprint 2.5 closed the remaining governed bare-host call sites |
| `HostBootstrap.HostConfig` | Implemented | Resolved host configuration |
| `HostBootstrap.HostPrereqs` | Implemented floor | Haskell host prerequisites aligned with the real pre-binary Python floor by closed Sprint 2.5 |
| `HostBootstrap.Substrate` | Implemented | Apple/Linux/Windows CPU/GPU substrate classification |
| `HostBootstrap.Ensure*` | Partial | The nine config-free reconciler families remain; Colima is a separate plan-bound per-project adapter. Incus now converges and totally classifies daemon reachability, permission, VM capability, and required image-server egress, and only the ready branch mints its opaque capability. WSL global-state ownership and recursive command integration remain downstream. The existing `fitsBudget` predicate is not the sole wired admission authority |
| `HostBootstrap.Cluster.Cordon` | Implemented pure parser/builder boundary, partial live enforcement | Exact whole-byte quantity parsing, resource builders, capacity preflight, and the typed bare-Linux `StorageCordonUnsupported` policy exist. Whole-GiB providers reject inexact hard ceilings instead of rounding upward. Direct Colima has an exact observed project-wall adapter; Incus/WSL and existing Lima walls are not fully reconciled, while conditional cleanup remains Sprint 5.7 work |
| `HostBootstrap.Cluster.Budget` | Implemented Phase 9 foundation plus Colima adapter | Closed provider keys; plan-indexed validated/effective budget; workload fit; constructive partitions/slices; and journal-before-call wall reservation/preparation/settlement are opaque. WSL success returns its lease inseparably and uncertain acquisition returns no authority. Sprint 13.18 owns the complete demo workload projection; remaining provider phases own their live CAS/adapters |
| `HostBootstrap.Cluster.Lifecycle` | Partial | Cluster planning/lifecycle; Sprint 5.6.1 closed canonical project-root admission and the direct-host durable projection, Sprint 5.7 owns receipt-aware backend storage operations, and Sprint 10.9 owns Production/Harness mode/profile opening over Sprint 15.9's command authority |
| `HostBootstrap.Cluster.Backend` | Implemented clause-holding backend, call site open | The four § EE clauses for the kind/nvkind cluster over an injected `ClusterExec`, plus the loopback-bound exposure operation. Sprint 5.9 (2026-08-02) made the clause-1 front end **probed rather than assumed**: discovery accepts `flock(1)` or `lockf(1)` — two shell front ends for the same `flock(2)` on the same inode — reports which it found, retains it on the opaque capability, and fails closed on an unrecognized report, so the clause suite executes on a BSD userland as well as a GNU one. Wiring it at the live `deploy-kind` call site remains Sprints 5.7/16.6 |
| `HostBootstrap.Step` / `Chain` / `Teardown` | Implemented forward, descent, and reverse boundaries; partial lifecycle | Opaque steps, disjoint typed identities, explicit reverse policy, operation keys/dependency prefixes, exact-order `StepPlan` validation, the plan-owned per-frame descent (`descendsVia`/`frameDescent`, validated one-per-frame), the plan-owned reverse effect (`reversedBy`, driven by `runTeardownProjection` for both verbs), and one plan consumer are implemented. A step's forward action is `StepAction` — `forall scope planId. StepExecution scope planId -> IO ()` — as of 2026-08-02, so the interpreter hands each action the descriptor the plan minted for its own node (§ U) instead of a bare `HostConfig`; `Chain.runChainFromFrame` therefore takes the `LifecyclePlan`. The recursive child-first unwind — and with it the `TeardownForest`'s first production call site — and the *result* half of the § U signature remain Phase 16.6 |
| `HostBootstrap.Lifecycle.Execution` | Implemented | The opaque plan-minted execution descriptor a step's action receives: the host-tool configuration plus the exact plan digest, operation key, frame, and ordered dependency edge set the step runs under, indexed by the plan's `scope`/`planId`. Its sole producer is `Reconcile.stepExecutionFor`, which derives every field from the `LifecyclePlan` rather than from a caller, and its constructor is package-internal (`ForgeStepExecution.hs` pins that). Sealing the edge set into an `OperationPreconditionSet` and returning a structured result stay Sprint 16.6 |
| `HostBootstrap.Teardown` | Implemented projection/forest, call sites open | The verb-indexed reverse projection (Sprint 16.6, 2026-07-30). `teardownPlan` reads the validated `StepPlan` out of the `LifecyclePlan` itself, so forward traversal and reverse teardown provably name the same resources; `down` stops a provider frame and `destroy` deletes it, while both delete the kind cluster and neither can touch a `PreserveOnReverse` step. `openTeardownForest` is the sole initial producer; the forest enforces child-first recursion with a destroy-only pre-descent reachability step, returns a successor on every outcome, keeps a failed node's parent blocked while siblings drain, and never completes while a failure stands. `verifyDestroySettled` accepts only a completed `Destroy` forest and is the sole producer of `DestroySettled`, which `Lifecycle.Mode.destroySettledClosure` converts into `ProjectClosureEvidence SettledDestroyClose`. Driving it from the real `project down`/`destroy` call sites is Sprint 16.6 item 5 |
| `HostBootstrap.Readiness` | Implemented Phase 9 foundation, partial live integration | Opaque validated polling and total results; closed backend probes require exact planned resources and mint generative plan/resource/dependency-indexed readiness. `planDependencyProbe` registers a probe for the traversal to run at prepare time rather than binding a retained observation. `ObservedReady` is explicitly non-authorizing compatibility evidence. Provider/interpreter phases own migration of live effects to prepared operations |
| `HostBootstrap.Reconcile` | Implemented Phase 9 foundation | Final-codec/step-plan lifecycle identity; opaque planned resources/edges, reconcile/adoption outcomes, prepared operation pairs, phase-indexed handles, and legal persisted journal transitions. Sprint 16.6 added the plan-owned dependency-snapshot traversal: a descriptor's edge set is the exact ordered **resource-bearing** prefix, and the sealed `OperationPreconditionSet` the prepare consumes has one producer that runs each member's probe itself. It then removed the caller-supplied journal version: `withPreparedOperation` takes a `Lifecycle.Prepared.PreparedGate` instead of two `Word64`s and refuses one recorded under another plan digest or operation key. Direct Colima acquisition is implemented; live protected-store and remaining adapter interpretation continue in Sprints 5.7, 10.9, 11.10, 15.9, and 16.6 |
| `HostBootstrap.Protected` | Implemented | The protected, versioned record store every durable lifecycle decision compare-and-swaps against: portable OS-released exclusive entry (`hLock`), non-re-entrant sessions, atomic publish, expected-version writes/deletes, durable store identity, and a non-blocking `tryProtectedEntry` |
| `HostBootstrap.Authority` | Implemented root/command boundary, partial handoff | Type-indexed closed `ProjectVerb`/`LifecyclePhase`, installed project identity, the OS/operator check, monotonic broker generations, the non-config `RootInvocationAuthority` gate, one-use `CommandAuthority` reservation, and the root/verb half of Production closure. The broker-relayed cross-frame handoff and the prepare compare-and-swap remain Sprint 15.9 work |
| `HostBootstrap.Lifecycle.Mode` | Implemented mode/lease/profile boundary, partial recovery | Project-wide mode exclusion, unbound/bound run leases, fresh Production/Harness `LifecycleProfile` openers, composite root brackets, closure evidence, mode release, and the abandoned-run sweep. The sweep now takes separate unbound and bound fold callbacks, so an unbound run's owned state is reclaimed before its lease closes. Bound-lease recovery reports rather than resolves, and the bound-Production recovery profile remains Sprint 10.9 work |
| `HostBootstrap.Harness.Ownership` | Implemented | The production run-ownership bracket: abandoned-run sweep with separate unbound/bound fold callbacks, protected mode/lease acquisition, and data-root acquisition/release through `Harness.DataRoot`. It replaces the unrecoverable `.test_data.hostbootstrap-run-owner` lock directory |
| `HostBootstrap.Harness.DataRoot` | Implemented | All four § EE ownership clauses for the run's durable data root, and the first § EE backend wired into a production route: exclusive entry is the caller's `ProtectedSession`, the origin record names the exact prior identity-or-absence before the directory is created, ownership binds the created directory's stable kernel identity, and release/recovery re-observe that identity — refusing a replacement instead of deleting it. A host without a stable identity is `Unsupported` and mints no ownership |
| `HostBootstrap.Harness.DataRoot.Native` | Implemented; native Windows gate passed 2026-08-01 | The host identity backend behind that seam: POSIX `lstat` `(device, inode)`, and on Windows `GetFileInformationByHandle` over a handle opened with `FILE_FLAG_BACKUP_SEMANTICS` and locally defined `FILE_FLAG_OPEN_REPARSE_POINT`. Volume word first, little-endian, as the peer ownership backends encode it. `DataRootSpec` runs this backend directly and passed in the 782-test Windows core gate |
| `HostBootstrap.Handoff` | Implemented foundation | The authenticated cross-frame handoff transport: length-delimited framing, the length-prefixed `HandoffBinding`, the root-only Ed25519 `RootBroker` with its keyless `BrokerRelay`, fresh-challenge grants, protected one-time token consumption, `VerifiedHandoff`, and `ChildPlanAuthority`. Built and proved; wiring it into the live descent in place of `Lift.ConfigDelivery`'s shell writer is Sprint 16.6 |
| `HostBootstrap.Activation` | Implemented foundation | The broker-signed runtime role activation: an `ActivationManifest` binding the immutable rollout revision and every pre-instantiation index but deliberately no instance identity, startup's own `RuntimeMeasurement` (binary, mounted wire, private bundle, pod UID plus restart count or host invocation nonce), the inseparable `VerifiedRuntimeRoleActivation`, and the one-use `LifecycleAdmission` compare-and-swap. Secrets are representable only as digests. Sprints 14.6 and 18.6 own the consuming role lifecycle and service gate |
| `HostBootstrap.Build` | Implemented foundation | Ephemeral build-invocation authority for the in-Dockerfile gate: the signed `BuildBinding`, the coordinator's Ed25519 grant, independent source-context and builder-binary measurement, the coordinator channel (absent channel is an explicit refusal, not a fallback), `ImageBuildFrame`, and the narrow `CheckCodePhase`/`BuildPhase` authorities. No function accepts a `BinaryContext`, so the baked image-build config reaches none of it. Requiring it at `checkCodeCommand` and in the demo Dockerfile is Sprint 16.6 |
| `HostBootstrap.Lifecycle.Prepared` | Implemented | The shared lower module that owns the durable half of a prepare (Sprint 16.6, 2026-07-30). `PreparedGate` hides its constructor and its sole producer, `recordDurableUnknown`, performs the compare-and-swap that publishes an operation's unknown phase, so the plan, operation, fence, attempt, and journal version an adapter is prepared against are the store's rather than a caller's literals. It sits below both `Lifecycle.Session` and `Reconcile`, which the `Session -> Authority -> Reconcile` dependency would otherwise keep from naming each other |
| `HostBootstrap.Lifecycle.Session` | Implemented foundation | The protected operation session, durable idempotent fence rotation, the total recovery discriminator, and the prepare compare-and-swap that records the operation's unknown phase before an adapter can run — now minting the `Lifecycle.Prepared` gate `Reconcile.withPreparedOperation` requires. Built and proved; driving the pair from the live lifecycle call sites is Sprint 16.6 |
| `HostBootstrap.Context` | Partial | Descriptive binary context and command capability checks; the total topology-graph validator and the closed `ContextPlacement`/`requiredWitnesses` relation (exact required evidence set per placement) are landed; closed Sprint 5.6.1 resolves `sourceRoot` separately without rewriting the context, and opaque command authority/narrowing is Phase 15.9 |
| `HostBootstrap.ProjectRoot` | Implemented foundation | Private rank-2 canonical-root admission, same-root host durable projection, and the typed direct-host mount adapter are implemented; the final opaque plan and remaining boundary projections are owned by Sprints 10.9, 11.10, 16.6, and 19.8 |
| `HostBootstrap.Substrate.Provider` | Implemented backend, production call-site migration open | Single provider launch/share/alias data route; direct-host aliases are removed. `Provider.Alias` supplies the clause-holding guest backend and opaque prepared call/release receipts, while the demo alias action still awaits migration to that authority path. Its guest-userland assumptions became probed on 2026-08-02: discovery reports the guest's exclusive-lock front end (`flock`/`lockf`) and asks `stat` itself which identity dialect it speaks (`-c`/`-f`), both retained on the capability and passed to one byte-identical script, so the four clauses run on either userland — which matters in the ordinary case, since a macOS host drives a Linux guest. `spStop` and `spDestroy` release the production WSL2 global wall before the disclosed global `wsl --shutdown` effect |
| `HostBootstrap.Lift` | Implemented, pending operation integration | Sole provider-backed nested command dispatch; live provider mutations still need the plan-owned prepared-operation pair |
| `HostBootstrap.Incus` / `Lima` / `Wsl2` | Partial provider integration | Provider argv/probes and launch builders exist; Incus has a total capability/egress classifier and the unused WSL import builder is gone. The production WSL utility-VM wall now enters through the journalled host-wall driver and releases on teardown; prepared-operation adoption across every provider mutation and the remaining native lanes stay open in their owning sprints |
| `HostBootstrap.Wsl2.GlobalWall` | Implemented production authority and recovery driver | Exact present/absent origin, durable unknown phases, identity-bound stage/apply/restore classification, fencing, opaque receipt/authority values, and conflict-only recovery are consumed by the production `ApplyGlobalWslWall`/`ReleaseGlobalWslWall` route. The shared model/codec gate is portable, the full driver gate runs on POSIX, and a focused native Windows production-entrypoint gate passed 4/4 on 2026-08-01 |
| `HostBootstrap.Wsl2.GlobalWall.ConfigBytes` | Implemented, retained | Strict bounded UTF-8/UTF-16 transformation with idempotence fixtures. Portable and unaffected by the ownership restatement; carried forward unchanged |
| `HostBootstrap.Wsl2.GlobalWall.Windows` | Implemented production backend; focused native gate passed 2026-08-01 | Windows realization of the portable host-wall driver. Public `Win32` types/wrappers cover ordinary operations; a narrow direct `kernel32` FFI preserves exact status for ownership-critical handle and namespace calls. The superseded `cbits` shim, its `hb_wsl_*` wrapper imports, Cabal `c-sources` block, and threaded-RTS carve-out are removed; no private `Win32` module or C source remains |
| `HostBootstrap.Harness` | Implemented typed foundation, partial ownership | Opaque typed case/variant matrix, selection, and reporting are implemented. `CaseResult` distinguishes the project's own `Fail` from the engine-classified `Refused`, `LifecycleFailed`, and `TeardownFailed`, and the report card labels each distinctly; the `Conflict`/`Unsupported` rows arrive with the reconciler wiring of Sprints 5.7/16.6, since nothing produces those outcomes yet. Exclusive run ownership is an injected `HarnessRunOwnership` seam the command layer fills with `Harness.Ownership`; receipt-driven cleanup and the harness close projection remain Phase 10.9 |
| `HostBootstrap.Service` | Implemented typed codec/request boundary, partial runtime | Closed typed registry definitions bind identity/projection/role codec/handler; finalization shares one digest with the full codec, service dispatch verifies one snapshot, and handlers receive only typed role fields plus safe framework view. Sprint 18.6 replaces raw handler `IO` with one-use effect-indexed execution; Sprint 14.6 integrates the phase lifecycle; native accelerator real-run evidence remains open |
| `HostBootstrap.RoleLifecycle` | Implemented engine, call site open | The phase-indexed role lifecycle (Sprint 14.6, 2026-07-30). The public `RoleSpec`/`runRole` callback bag is deleted. A role now passes `verifyRolePlanDraft` (no durable mutation) → `withRoleLifecycleAdmission` (one-use reservation keyed on plan digest, frame, revision, and measured instance) → `withRuntimeRolePlan` (CAS-consumes that reservation, mints `RolePlan`/`RolePlanDigestBinding`/`VerifiedServicePlacement` and the sole `Prereq` cursor), after which the core-owned engine privately drives Prereq → Acquire → Ready → Serve → Drain → Exit and returns only `RoleExitReport`. The lease requirement is derived from the signed effect ceiling, and the exclusive branch holds a kernel lock across Acquire→Drain. `service run` does not yet enter through it: nothing in production can mint a `RootInvocationAuthority`, so no `ActivationManifest` can be signed (Sprint 16.6 item 1). Sprint 18.6 adds the effect-indexed selected-service package on top |
| `HostBootstrap.Config.*` | Implemented root/config-role boundary, partial handoff | Generic scope-indexed config classes, opaque secret refs, canonical verification, common framework view, full-vs-role/scope discriminators, `RoleCodec`, request, and role parameters are implemented. Authenticated child handoff/command authority remain Phases 15.9/16.6. The package-internal `Config.Install.Native` supplies the atomic no-replace publication primitive the authenticated sibling install requires — a **hard** link (`link(2)` / `CreateHardLinkW`), which publishes the written bytes under the final name and fails when the name is taken; the former symbolic link published a reference the inspector then refused, so the installed outcome was unreachable (repaired 2026-08-02, Sprint 15.9) |
| `HostBootstrap.Dhall.*` | Implemented foundation | Opaque `CodecWitness` owns schema/decode/render, opaque artifacts require an admitted codec, literal schema commands are snapshotted, every current `Core.dhall` type export is equality-owned, and Phase 19's `ProjectCodec` supplies installed identity/scope/spec-digest binding |
| `HostBootstrap.Registry` | Partial | Docker Hub credential discovery/forwarding exists, but raw-text/substring classification and environment transport remain open in Sprints 15.9/19.7; schema/artifact registration lives in `HostBootstrap.Dhall.Gen` |
| `HostBootstrap.Network` / `HostBootstrap.RegistryPlan` | Implemented generic algebra | Closed Sprint 14.7 landed scope-indexed endpoints/clients/exposures, proof-gated blob delivery, opaque finalized registry plans, and route-specific readiness; Sprint 13.20 consumes them in the demo |
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
