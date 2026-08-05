# Development Plan

**Status**: Governed orientation document
**Supersedes**: N/A
**Canonical homes**: [development_plan_standards.md](development_plan_standards.md),
[00-overview.md](00-overview.md), [system-components.md](system-components.md)

> **Purpose**: Name the phases in execution order, provide the single current cross-phase status table,
> and link to detailed ownership, validation, and component documentation.

## Foundation

`hostbootstrap` is a Haskell `hostbootstrap-core` library plus a thin Python pre-binary bootstrapper.
The Haskell library owns host/provider operations, configuration, lifecycle, test, service, and project
extension contracts. Python asserts the irreducible host floor, prepares the native Haskell toolchain,
builds the project binary host-native, and invokes it (POSIX process replacement with `exec`; Windows
child subprocess); it also owns the explicit operator-invoked base-image and pipx self-update surfaces.

The target command tree is fixed to `project`, `test`, `service`, `context`, and `check-code`.
Project behavior is supplied through typed extension streams, including one lifecycle chain, project
configuration, test components, and service handlers. The active repair program is intended to make those
boundaries enforceable through one opaque `ProjectPlan scope specDigest planId configId cfg`, plan/resource-indexed capabilities,
ownership- and phase-indexed lifecycle state, dependency-indexed total probes, structured
reconciliation, § EE clause-holding reservations with verified ownership receipts, authenticated
one-time cross-process authority handoffs and operation sessions, durable delayed-permit fencing,
project-wide Production/Harness exclusion, exhaustive bound-run/migration/close recovery,
native rolling-base publication with real-consumer compatibility smoke, and typed test case/variant
configuration. The same repair program separates
production and harness config scope so test-only plaintext secrets are unrepresentable in production
configuration rather than excluded only by consumer policy. These are target contracts until their named
sprints close, not current implementation claims.

Ownership across every substrate is governed by one invariant — the four **Locked-Origin Identity
Ownership** clauses in [development_plan_standards.md § EE](development_plan_standards.md), explained in
[ownership_invariant](../documents/architecture/ownership_invariant.md). It was restated 2026-07-27: the
previous rule demanded a platform primitive no substrate supplies, so no backend satisfied it and the
typed ownership path was unreachable on Lima, Incus and WSL2 alike. The restated clauses are met with
dependencies already present, on every provider lane rather than one.

Historical test counts and real-run results live as dated validation evidence in the phase sprint that
produced them. They are not copied here as a mutable “current suite” claim.

## Current Phase Status

This table is the **sole cross-phase status source of truth**. Phase-local status and sprint ownership must
match it. `00-overview.md` and `system-components.md` describe responsibilities and inventory only; they
defer status to this table.

Phase numbers remain the stable reporting and closure focus, not an execution schedule. The executable
order follows the open sprint dependency graph, including higher-numbered producer work required by a
lower-numbered consumer.

| Phase | Title | Status | Current open owner |
|-------|-------|--------|--------------------|
| 0 | [Documentation and governance](phase-0-documentation-and-governance.md) | Done | — |
| 1 | [hostbootstrap-core scaffolding](phase-1-hostbootstrap-core-scaffolding.md) | Done | — |
| 2 | [Host floor, tools, and config](phase-2-host-tools-and-config.md) | Done | — |
| 3 | [Ensure reconcilers](phase-3-ensure-reconcilers.md) | Done | — |
| 4 | [Project-local Dhall and command tree](phase-4-skeletal-dhall-and-command-tree.md) | Done | — |
| 5 | [Cluster lifecycle and resource cordoning](phase-5-cluster-lifecycle-and-resource-cordoning.md) | Done | — |
| 6 | [Base image and Python CLI surface](phase-6-base-image-and-thin-python-bootstrapper.md) | Done | — |
| 7 | [Consumer adoption](phase-7-consumer-migration.md) | Done | — |
| 8 | [Dhall generation and extension contract](phase-8-dhall-generation-and-extension.md) | Done | — |
| 9 | [Applied budget cordon and one canonical parser](phase-9-applied-cordon-and-one-parser.md) | Done | — |
| 10 | [Standardized test harness and execution shapes](phase-10-standardized-test-harness.md) | Active | Sprint 10.10 done; 10.9's project-wide mode/lease exclusion, fresh profile openers, abandoned-run sweep, and the recoverable run reservation that replaces the lock directory landed 2026-07-29, and the **four § EE clauses for the data root** and the **structured report-card outcomes** landed with it — the data root is the first § EE backend wired into a production route. The per-run `.test_data/<runId>` generation and the bound-Production recovery tranche (persisted/verified plan snapshots, the classified `bindRunLease`, both scope-exclusive recovery eliminators, and `RecoveredProductionLifecycleProfile`) landed 2026-07-29 at a clean 737/737 core gate. The two close transactions, the `ClosingProject` journal state, the complete-session proof, and the four-process reservation race landed 2026-07-30 at a clean 744/744 core gate — the race exposed and fixed a real defect: with no liveness established, a starting run swept a **live** run's lease and stole its mode, so two runs owned the project at once. **`verifyDestroySettled` landed 2026-07-30 with Sprint 16.6's teardown forest**, and `destroySettledClosure` converts it plus the complete-session proof into `SettledDestroyClose` closure evidence, closing that item. On 2026-08-01 the live harness path was narrowed to its exact owned store/project/root authority, snapshot persistence became immutable and byte-identically idempotent before lease binding, and every Session-owned multi-record transition moved behind the crash-consistent redo coordinator. On 2026-08-02 the first complete core-suite pass on Apple Silicon was recorded (**882/882**), after repairing two of this sprint's own gates that had stopped observing what they assert: the bound-snapshot assertion carried a second, stale copy of the snapshot wire format and now reads it back through the production decoder, and the compile-fail matcher compared GHC's line wrapping rather than its content. A live Apple Silicon reproduction on 2026-08-03 then **added an item and gave the known bound-recovery item a real failure to point at**: the generated sibling config was still claimed by a bare `<config>.hostbootstrap-test-owner` directory holding none of the four § EE clauses, and `test run`'s existence refusal fired *before* the abandoned-run sweep, so after an interrupted run the recovery machinery that did land was unreachable and both the config and the bound lease had to be cleared by hand. **Both halves closed 2026-08-04** at a clean 923/923 core gate: the new `Harness.GeneratedConfig` holds all four clauses over the file (origin record naming the intended payload digest, create-if-absent publication, bound kernel identity, identity-and-payload-conditional release) and shares one `Harness.Identity` layer with the data root so the two cannot drift; the three existence refusals are reconciled to the single post-sweep copy derived from installed project identity; and `classifyAbandonedBoundRun` gives the bound half a producer, so a bound abandoned run that `verifyNoProjectResourcesAcquired` proves acquired nothing is reclaimed and closed instead of only named. The same clean-tree gate exposed and fixed a pre-existing `-Werror` defect warm build trees had hidden (`HostTool`'s unconditional `(</>)` import). **Live-validated on Apple Silicon 2026-08-04 at `10/10 passed`** over four bring-ups and three destroys: the new config ownership acquired and released on every one, and the post-run audit found both leases `closed`, no `mode`/`config`/`dataroot` record left, `.test_data` empty with its parent preserved, and `demo/.data` intact — which also discharges the § C live re-run Sprint 16.6's plan-minted step descriptor owed on this lane. Open for the rest of the `withAbandonedHarnessRun` opener (fresh-broker-generation close authority, the persisted-`Closing` and migration branches, child-first teardown), for authenticated child admission and the live prepared/reconciler/terminal-recovery path, the receipt-carrying `Conflict`/`Unsupported` rows, and the remaining concurrency matrix |
| 11 | [Incus first-class host-provider](phase-11-incus-host-provider.md) | Active | Sprint 11.10's portable host-wall backend, C-shim and `.bak` retirement, and clause-holding guest-alias backend landed. **The native Incus gate closed 2026-07-29 at `10/10`**. On 2026-08-01 the repaired production Win32 adapter built against pinned `Win32-2.14.2.1`, passed its focused 4/4 entrypoint gate, and passed inside the complete 782/782 Windows core suite. Open: the demo guest-alias production migration — still **`Blocked by` Sprint 16.6 open item 3**, but narrowed on 2026-08-02: the plan-minted step descriptor landed, so a step action now names its own operation; what it still cannot reach is a `PreparedGate`, and therefore the `Managed` share handle — plus the current WSL2 provider lifecycle lane. **The Apple/Lima lifecycle lane closed 2026-08-03** at `10/10` — `ensure lima`, `vm up` at budget, the durable share and guest alias, and VM deletion on every teardown. Also on 2026-08-02 the guest-alias backend's userland assumptions became probed rather than assumed (`flock`/`lockf` and GNU/BSD `stat`, both reported by the discovery probe and retained on the capability), so its four § EE clauses execute on a BSD userland for the first time |
| 12 | [Opportunistic warm store](phase-12-layered-warm-store.md) | Done | — |
| 13 | [hostbootstrap-demo worked app](phase-13-hostbootstrap-demo.md) | Active | **Sprint 13.17 is Done: the Apple Silicon lane closed 2026-08-03 at `10/10 passed`, the last of its four substrate lanes.** It had reported `0/10` on 2026-08-02/03 against a named defect — the host-resident accelerator daemon exited before readiness with its own cause written to closed descriptors — which Phase 2 Sprint 2.7 sealed under § HH the same day. Re-run against the sealed boundary, the daemon reached readiness on all four bring-ups and **`e2e-tabs` passed on both variants**, so Apple Metal ensure, the Swift/Metal worker build, the WebSocket connect, and the CBOR round trip are proved live rather than merely started; `durable-readback` also passed, and teardown left nothing behind. That run additionally discharges the § C live re-run owed on this lane by every static-only change before it, including Sprint 16.6's plan-minted step descriptor. Sprint 13.17 holds the canonical evidence. Sprint 13.19 done; **13.20 closed 2026-07-30** at `10/10` on the native Linux CPU lane — one finalized registry plan renders `redirect: disable: true` as output, and `push-image` now requires a settled `ReadyBlobRoute` rather than `/v2/` liveness; a live negative fixture proves the pre-fix config answers `307` to cluster-only MinIO. 13.18 waits on the integration chain |
| 14 | [Composition methodology](phase-14-composition-methodology.md) | Active | Sprint 14.7 done 2026-07-29 (scope-indexed endpoint/reachability + proof-gated blob delivery), unblocking Sprint 13.20. **Sprint 14.6's engine landed 2026-07-30** at a clean 769/769 core gate: the public `RoleSpec`/`runRole` callback bag is deleted, replaced by the opaque `RolePlan`/`RoleCursor` phase machine reached only through a verified activation → verified role-plan draft → one-use lifecycle admission, with the lease requirement derived from the signed effect ceiling and the exclusive branch holding a real kernel lock across Acquire→Drain. It stays Active for the `service run` call-site adoption, which is **`Blocked by` Sprint 16.6**: the root authority gate now has a production consumer, but 16.6's internal receiver/root relay does not yet carry it to the nested deploy call site that must sign the `ActivationManifest` |
| 15 | [Binary context config and command gating](phase-15-binary-context-config.md) | Active | **Sprint 15.8 is Done**: its Linux GPU (2026-07-28) and Linux CPU (2026-07-29) in-cluster delivery/connect lanes closed, and the Apple host-daemon lane closed 2026-08-03 at `10/10` once Sprint 2.7's sealed launch let the daemon start, read its delivered projection, and connect. 15.9's context-validation, protected-store/root/command-authority, required-witness, validated-config, handoff, prepare, build-authority, and runtime-activation producer foundations are landed and gated. On 2026-08-02 the authenticated sibling install was repaired: it published a **symbolic** link, which its own inspector then refused, so the installed outcome was unreachable on every platform and the failure left a dangling destination; the new package-internal `Config.Install.Native` supplies the hard-link no-replace primitive the operation needs. Sprint 15.9 remains co-active with 16.6 for production receiver/prepare/build call-site consumption and its schema/golden/negative gates; 14.6 and 18.6 are downstream consumers, not prerequisites for 15.9 closure |
| 16 | [Project lifecycle command](phase-16-project-lifecycle-command.md) | Active | **Sprint 16.5 is Done**: its Linux GPU (2026-07-28) and Linux CPU `ClusterIP` (2026-07-29) lanes closed, and the Apple host-daemon lane closed 2026-08-03 at `10/10` — the hook ordering, the local-only NodePort path, and the singleton daemon lifecycle all completed cleanly on four bring-ups. **Sprint 16.6 is the current co-active producer root**: the prerequisite foundations from closed Sprints 5.7, 9.10, and 19.7–19.8 and active Sprints 10.9 and 15.9 have landed, while 10.9/15.9/16.6 remain Active until their live call sites and owned validation close. Its verb-indexed reverse projection and teardown forest (`HostBootstrap.Teardown`) landed at a clean 786/786 core gate, giving `verifyDestroySettled` and `destroySettledClosure` their first producers, so `ProjectClosureEvidence`'s `SettledDestroyClose` branch is no longer uninhabited. The **independent root gate** landed the same day at 787/787: `project up|down|destroy` now run behind `verifyOperatorAuthorization` → `withVerifiedRootInvocation` → `authorizeProjectCommand` instead of context class membership, giving `withVerifiedRootInvocation` its first production consumer. It is root-frame-only and static-gated; the native demo lane should be re-run before Phase 16 closes. The **plan-owned dependency-snapshot traversal landed 2026-07-30** at a clean 794/794 core gate: an operation's edge set is now the exact ordered resource-bearing prefix, and the sealed `OperationPreconditionSet` the prepare consumes has one producer, which runs each member's probe itself — so a caller can no longer select, omit, or retain a dependency observation. That removed the first of the two obstructions on Sprint 11.10's demo alias migration; the remaining one is open item 3. The **prepare gate** landed 2026-07-30 at a clean 797/797 core gate: the new lower `HostBootstrap.Lifecycle.Prepared` owns an unforgeable `PreparedGate` whose sole producer performs the durable unknown-phase compare-and-swap, `withPreparedOperation` reads the attempt and journal version off it instead of taking two `Word64`s, and it refuses a gate recorded under another plan digest or operation key. The **plan-owned frame descent** landed 2026-07-30 at a clean 801/801 core gate, closing the first half of open item 3: a step declares its boundary with `descendsVia`, `mkStepPlan` requires exactly one per frame that has a successor and none from the innermost, `Chain.runChainFromFrame` reads the context off the plan, and `setFrameContext`/`psFrameContext` are deleted — so the `context-init` row that announces a child config is now the node that carries it. Step fragments are also rank-2 in the canonical root, so the whole plan is root-bound (§ X). The **plan-owned reverse effect** landed the same day at a clean 807/807 core gate, deleting `setTeardown`/`psTeardown`: an acquiring step declares the effect that releases it with `reversedBy`, and `project down`, `project destroy`, and a failed `project up`'s unwind are three verb-indexed projections of that one plan with structured per-node outcomes. All three formerly independent lifecycle views are therefore plan nodes. Both halves are **native-run-validated on the Linux GPU direct lane 2026-07-30**: `project up` reached a live web service answering HTTP 200 (with the in-Dockerfile `check-code` gate passing), `project down` printed exactly the plan's own reverse nodes deepest-frame-first and left nothing behind, `project destroy` was idempotent, and `demo/.data` survived both — which also discharges the root gate's owed re-run. The **plan-minted step descriptor landed 2026-08-02** at a clean 888/888 core gate, closing the § U half of open item 3: a step's action is `forall scope planId. StepExecution scope planId -> IO ()`, minted only by the plan (`Reconcile.stepExecutionFor`) and carrying the plan digest, the step's own operation key and frame, and its exact ordered edge set — so a step names its node instead of reconstructing it, and the previously producer-less and consumer-less `Lifecycle.Execution` descriptor now has one of each. It is static-gated, and every dated lane result in this plan predates it, so § C owes a live re-run on each lane. The plan-minted descriptor's owed § C live re-run is **discharged on the Apple Silicon lane 2026-08-04** (`10/10 passed`); the Linux CPU/GPU and Windows lanes still owe theirs. Open: the `copy-source` demo call site, the handoff receiver/build channel, the recursive child-first unwind and the *result* half of the step signature (the rest of item 3), and the migration/recovery gates |
| 17 | [Chain-driven test and context introspection](phase-17-chain-driven-test-and-context-introspection.md) | Blocked | Sprint 17.4: waiting on Sprints 10.9 and 15.9 |
| 18 | [Service runtime command](phase-18-service-runtime-command.md) | Active | **Sprint 18.5 is Done**: its native Linux GPU (2026-07-28) and CPU in-cluster (2026-07-29) lanes closed, and the Apple Silicon host-daemon lane closed 2026-08-03 at `10/10`, where `e2e-tabs` asserted the daemon-returned sum, backend, and artifact hash through the browser — so the real socket, CBOR round trip, and private-listener contract are proved on that substrate. Sprint 18.6 runtime authority/effects blocked by 14.6, 15.9, and 17.4 |
| 19 | [Generic project model](phase-19-generic-project-model.md) | Done | — |
| 20 | [Config-driven demo worked example](phase-20-config-driven-demo-worked-example.md) | Blocked | Sprint 20.5: waiting on Sprints 10.9 and 18.6; Sprints 19.7–19.8 are done |
| 21 | [Documentation/code consistency reconciliation](phase-21-documentation-code-consistency-reconciliation.md) | Blocked | Sprint 21.4: waiting on all named implementation owners |

**Every substrate lane is now closed.** Windows GPU is dated, accepted evidence for Phase 18; native
Linux GPU closed 2026-07-28 and native Linux CPU 2026-07-29; and Apple Silicon — the last one — closed
2026-08-03 at `10/10 passed` once Phase 2 Sprint 2.7 sealed the host-invocation shape boundary. That one
run closed the Apple lane in Sprints 13.17, 15.8, 16.5, and 18.5 together, and each of those sprints is
now Done. No open live-lane work remains anywhere in this plan.

Phases 13, 15, 16, and 18 stay Active for implementation sprints that were never lane-gated — 13.18,
15.9, 16.6, and 18.6 — and the other reopened phases own implementation defects that cannot be closed by
replaying any dated run.

## Ownership Map

- Phase 2 owns host-tool resolution and the pre-binary host floor.
- Phases 5, 9, 10, 11, 15, and 16 split lifecycle work: backend storage operations/receipts; core state
  types; project-wide mode/profile opening; provider dispatch; independent root/command authority; and
  recursive plan interpretation/teardown.
- Phases 6 and 12 split base work: rolling publication/native/source-gate/pull enforcement and the
  single-project opportunistic warm-store policy.
- Phases 10, 17, 19, and 20 split test work: engine isolation plus the Harness mode/profile opener;
  command semantics; generic typed case/variant and production/harness secret-scope contracts; and demo
  config consumption.
- Phase 13 owns the worked demo's Production plan, test component, pulled base, and concrete
  reachability-safe registry/MinIO renderer and live route proof.
- Phase 14 owns the generic scope-indexed endpoint and proof-gated blob-delivery algebra; Phase 9 owns
  the identity-bound readiness/precondition value it consumes.
- Phase 21 follows the implementation phases and reconciles governed documentation, comments/help, and
  mechanical drift guards.

## Validation Policy

`Done` requires implementation, the phase's static gates, any named native real-run/build/publish gates,
aligned governed documentation, and no remaining work. A dated run validates only the behavior and
substrate it exercised. It cannot stand in for a different provider, architecture, concurrency race,
negative parser path, or newly introduced type boundary.

Exact test counts may be recorded in a sprint's validation evidence with a date. They must not be promoted
to a repository-wide “current count.” The operator publication workflow follows current-compatible
resolution → native build → complete quality gate → publish rolling tag → pull → real-consumer
compatibility smoke. A digest may identify that one pulled build, but does not imply locked inputs.

## Governance

- [development_plan_standards.md](development_plan_standards.md) defines plan structure and durable
  doctrine.
- [00-overview.md](00-overview.md) explains phase responsibilities and dependency flow without duplicating
  status.
- [system-components.md](system-components.md) inventories implementation surfaces and explicitly marks
  target-only/open contracts.
- [legacy-tracking-for-deletion.md](legacy-tracking-for-deletion.md) records obsolete, duplicate, and
  definition-only surfaces.
- Each phase file owns its deliverables, validation, and remaining work.

## Authority

This directory is authoritative for development sequencing and completion state. Governed architecture
and engineering documents describe supported behavior only after the owning phase closes.
