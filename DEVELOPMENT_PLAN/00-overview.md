# Development Plan Overview

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md),
[system-components.md](system-components.md)

> **Purpose**: Explain stable phase responsibilities and the explicit execution dependency graph without
> duplicating current phase statuses or mutable validation counts.

## Status Authority

The [README phase table](README.md#current-phase-status) is the sole cross-phase status source of truth.
This overview deliberately contains no phase-status roll-up and no “current suite” count. Dated validation
evidence belongs in the owning phase sprint.

## Current Architecture and Target Corrections

The repository contains a Haskell `hostbootstrap-core` library and a thin Python bootstrapper. Python
establishes the irreducible pre-binary floor, builds a project binary host-native, and invokes it (POSIX
process replacement with `exec`; Windows child subprocess). Haskell owns provider/tool resolution, typed
project configuration, lifecycle, testing, service roles, and the fixed project command tree.

The current repair program targets the following enforceable architecture. Until an owning sprint closes,
each item below is a target contract rather than a claim about the current implementation:

- every host tool resolves through a closed absolute-path boundary;
- capabilities/readiness are opaque, generative, and bound to lifecycle scope, resource instance, and
  the dependency selected by a hidden probe/transition;
- lifecycle state is scope-, ownership-, and phase-indexed; managed reconcile results retain a typed
  handle and receipt, while foreign results expose only a non-authorizing unmanaged handle;
- target execution profile is opaque and project/scope-indexed as `Production projectId` or
  `Harness projectId runId`, so a test component
  cannot select production names, roots, ports, or identities;
- secret references and project-owned config are production/harness-indexed, so `TestPlaintext` cannot
  inhabit production configuration;
- tests reserve every resource they mutate through that resource's authoritative backend, rehydrate
  authority across process boundaries only through authenticated one-time handoffs, and recursively tear
  down only their verified receipts;
- base publication is native-architecture, fully gated, rolling, and pulled before compatibility
  smoke-testing against a real consumer;
- host and container builds use one Cabal project and inherit the base Cabal store as an opportunistic
  cache;
- network endpoints and clients are scope-indexed, and redirect delivery requires a proof that the
  client can reach the backing endpoint;
- test case/variant identity is typed and the demo matrix is generated from decoded config; and
- governed status has one authority, while historical counts remain dated evidence.

## Phase Responsibilities

### Phase 0 — Documentation and governance

Defines metadata, plan structure, documentation taxonomy, validators, and authority rules.

### Phase 1 — hostbootstrap-core scaffolding

Establishes the Cabal library/executable/test layout and the generic CLI entrypoint.

### Phase 2 — Host floor, tools, and config

Owns the pre-binary host floor, native Haskell toolchain preparation, substrate detection, and the closed
`HostTool`/`AbsExe` boundary. Sprint 2.5 owns the remaining bare-host-call inventory and Linux/Windows
bootstrap prerequisite reconciliation.

### Phase 3 — Ensure reconcilers

Owns idempotent host dependency reconcilers and their substrate applicability after the project binary
exists.

### Phase 4 — Project-local Dhall and command tree

Establishes binary-owned project configuration and the initial fixed command grammar.

### Phase 5 — Cluster lifecycle and resource cordoning

Owns cluster plans, resource/storage walls, readiness ordering at cluster boundaries, durable-root
behavior, and the provider/storage operations consumed by the generic opaque lifecycle profile.
Sprint 10.9 owns the fresh `LifecycleProfile (Production projectId)` /
`LifecycleProfile (Harness projectId runId)` openers and the exact bound-Production recovery-profile
opener; Phase 5's `containerPlan` consumes the resulting plan to
derive cluster name, data root, ports, and ownership identity together. Phase 5 also owns the remaining
native accelerator cluster lanes and application of the declared budget to a project-specific Colima
provider.

### Phase 6 — Base image and Python CLI surface

Owns native rolling base build/publish, current-compatible upstream discovery, the full pre-publish
Python/Haskell gate, architecture validation, publish→pull→real-consumer compatibility smoke,
deterministic project selection, and idempotent native binary build/copy. A recorded digest identifies a
particular publication but is not a locked-input or consumer-pinning contract.

### Phase 7 — Consumer adoption

Owns downstream migration onto the reusable library and Python bootstrap contract.

### Phase 8 — Dhall generation and extension contract

Owns generated schemas/artifacts and the project extension-stream shape. Closed Sprint 8.7 provides one
validated lower-layer codec witness, opaque artifact construction, exact schema-command snapshots, and
complete judgmental-equality ownership of every current `Core.dhall` type export.

### Phase 9 — Applied budget cordon and one canonical parser

Owns canonical quantity/resource types, opaque resource-instance readiness, total probes,
ownership- and phase-indexed lifecycle state, `ReconcileResult`, structured
conflict/safety/failure, and managed receipts for both changed and unchanged reconciliation.

### Phase 10 — Standardized test harness and execution shapes

Owns resource-authoritative test reservations/receipts, per-variant failure isolation, structured report
outcomes, and receipt-driven cleanup. Sprint 10.9 opens the Production/Harness lifecycle mode and profile
over Phase 9/19's scope foundation, Phase 5's backend planning/receipt operations, and Phase 15.9's root
authority. It exposes to a `TestComponent` no Production constructor and owns the harness run lease/
one-time cross-process handoff protocol with Phases 15 and 16. It also removes the unconsumed
detached Haskell/Dhall execution selectors; Sprint 10.10 is complete, so execution shape is expressed
only by the lifecycle plan.

### Phase 11 — Incus first-class host-provider

Owns one `SubstrateProvider`/`Lift` dispatch path for Incus, Lima, WSL2, and direct-host operations,
including durable aliases and exclusive global WSL state. The definition-only `HostTarget` and WSL
import surfaces have been removed; strong provider-guest alias ownership and global WSL CAS remain open.

### Phase 12 — Opportunistic warm store

Owns one host-compatible consumer Cabal project for host and container builds, broad best-effort
warm-store population, aligned build ways where practical, and graceful online cache misses. It does not
own consumer freeze imports, offline completeness, or version-lock replayability.

### Phase 13 — hostbootstrap-demo worked app

Owns the demo's scope-polymorphic plan shape instantiated separately for Production and each Harness run,
the harness-only test component, pulled rolling-base consumption, current registry/MinIO
metadata, reachability-safe rendering and persistence proof, the threaded static test component, plus the remaining native
accelerator demo lanes.

### Phase 14 — Composition methodology

Owns the reusable operation algebra, scope-indexed network endpoints and proof-gated blob delivery, and
the rule that one representation drives deployment. The current
chain is the single forward ordering; Phase 16 owns replacing its independent context/teardown callbacks
with one scoped opaque plan. Sprint 14.6 owns integrating the definition-only role phase skeleton into
the fixed service runtime.

### Phase 15 — Binary context config and command gating

Owns descriptive context versus opaque role-specific root/command authority, capability narrowing, safe
init requests, durable-placement enforcement, and the transport envelope for one-time child authority
handoff. Phase 10 consumes that independent root authority in the sole Production/Harness mode/profile
opener. Phase 15 also owns remaining native accelerator context validation.

### Phase 16 — Project lifecycle command

Owns a single `ProjectPlan scope specDigest planId configId cfg`, recursive interpretation, authenticated authority
rehydration, and
scope/receipt-preserving reverse teardown after failure, interruption, down, or destroy. It also owns
remaining native accelerator lifecycle validation.

### Phase 17 — Chain-driven test and context introspection

Owns the exact grammar and side-effect gates for `test init`, `test run <case-id>|all`, and read-only
`context` behavior.

### Phase 18 — Service runtime command

Owns config-selected long-running service/daemon roles. Sprint 18.6 now owns typed service selection,
one immutable config-derived handler payload, least-authority role parameters, and service-specific
missing-config recovery. The remaining live-evidence scope is Apple Silicon and native Linux CPU/GPU
accelerator lanes; the Windows GPU host-daemon lane is dated accepted evidence, not open work.

### Phase 19 — Generic project model

Owns generic `ProjectSpec projectId cfg tcfg`, the one restricted project-config assembler, validated
`CaseId`/`VariantId`, and the typed test-config-to-variant projection. It also owns scope-indexed
`SecretRef scope` and project-owned `cfg scope`, in which `TestPlaintext` exists only for exact Harness
configuration. It does not own harness execution or demo-specific values.

### Phase 20 — Config-driven demo worked example

Owns the demo's decoded typed case/variant values and config-driven `TestMatrix`/`VariantDraft`
construction consumed by `psAssemble`. Changing the variant matrix must not require a Haskell source
edit.

### Phase 21 — Documentation/code consistency reconciliation

Owns the governed sweep after implementation lands, drift guards for obsolete surfaces, and enforcement
that the README phase table is the only cross-phase status roll-up.

## Execution Dependencies

Sprint `Blocked by` metadata is the execution authority. Phase ownership above explains where contracts
live; it does not make every cross-phase reference a start dependency. The strict landing order is:

1. Sprints 2.5, 5.6.1, 5.8, 6.7, 8.7, 9.4, 9.10, 10.10, 12.4, 13.19, and 19.6–19.8 are closed.
   Sprint 11.10 is the next phase-ordered dependency root; Sprint 14.7 is also dependency-ready.
2. Closed Sprints 8.7 and 19.6 enabled Sprint 19.7; closed Sprint 19.7 enabled Sprint 19.8. Closed
   Sprints 19.7–19.8 enabled Sprint 9.10, whose opaque capabilities are now minted only from the scoped
   codec and finalized plan.
3. Closed Sprint 5.6.1 enables Sprint 5.6's direct-host durability gate. Closed Sprint 9.10 enabled
   closed Sprint 5.8 and enables Sprint 11.10. Sprint 11.10 then enables Sprint 5.7's
   all-provider storage/ownership gate.
4. After Sprint 5.7 and Sprints 9.10 and 19.7–19.8 close, Sprint 15.9 supplies the independent root/command
   authority. Sprint 10.9 consumes it with the mode/lease state to implement fresh and bound-recovery
   profile openers; Sprint 16.6 then consumes both in the recursive interpreter. They remain one
   coordinated integration tranche, but the explicit 15.9 → 10.9 → 16.6 order prevents a circular
   prerequisite.
5. Sprints 14.6 and 17.4 are separate downstream branches once their own blockers close: Sprint 14.6
   consumes lifecycle admission plus signed-revision/measured-instance activation authority, while
   Sprint 17.4 consumes typed cases, command authority, and structured harness outcomes. Sprint 18.6
   joins Sprints 14.6, 15.9, 17.4, and 19.8 for validated service dispatch. Sprint 20.5 then consumes
   Sprints 10.9, 18.6, and 19.7–19.8 for scoped config and harness-indexed execution.
6. Closed Sprints 9.10 and 19.8 enable Sprint 14.7's generic reachability/delivery algebra; Sprint 14.7
   enables Sprint 13.20's concrete demo renderer and live blob-route proof.
7. Sprint 13.18 lands only after Sprints 5.7, 10.9, 13.20, 14.6, 15.9, 16.6, 17.4, and 20.5.
   It is the worked-demo integration gate, not a foundation for those APIs.
8. Sprint 21.4 performs the governed final sweep after every named implementation owner closes.

The real-run lanes owned by Phases 5, 13, 15, 16, and 18 are independent unless a sprint's exact
`Blocked by` line names one. A run on one provider/architecture closes only that named lane.

## Non-Goals

- Git history remains user-controlled.
- The Python bootstrapper does not become a second project lifecycle/configuration implementation.
- A mutable base tag, local unpublished image, test count, or run on another provider is not substitute
  evidence.
- Definition-only exports and aspirational integration modes are not retained as supported API.
