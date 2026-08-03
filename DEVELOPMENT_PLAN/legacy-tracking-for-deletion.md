# Legacy Tracking for Deletion

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [README.md](README.md), [development_plan_standards.md](development_plan_standards.md)

> **Purpose**: Current cleanup ledger for obsolete compatibility surfaces. `Pending` is the active
> cleanup list; `Removed Surfaces` records names that are intentionally absent from the supported
> architecture.

## Pending

- **Raw registry reachability, independently selected redirect behavior, and `/v2/`-only readiness**
  (`demo/src/HostBootstrapDemo/Commands.hs`, `demo/test/RegistrySpec.hs`,
  `demo/test/HarnessSpec.hs`) — the demo separately renders a host-facing NodePort, the cluster-only
  `minio.default.svc` endpoint, and Distribution's implicit redirect default. A repeated blob `HEAD`
  can therefore return `307` to a name the host Docker client cannot resolve, while Deployment Ready or
  `/v2/` can still be mistaken for route readiness. Replacement: opaque scope-indexed endpoint/client/
  exposure values, proof-gated `BlobDelivery`, one finalized registry plan whose renderer derives
  `storage.redirect.disable`, and an exact revision-/registry-/store-indexed `ReadyBlobRoute` required
  before push. Delete raw endpoint/redirect assembly and tests that treat initial push or `/v2/` as
  persistence proof. **Sprint 14.7's generic algebra landed 2026-07-29**: scope is a type index,
  `Reachability` has no host-local→cluster-only constructor, the redirecting `BlobDelivery` constructor
  consumes that witness, `RegistryPlan` is opaque behind topology-specific constructors,
  `storage.redirect` is derived from the delivery, and `ReadyBlobRoute` is minted only from a real blob
  probe on the plan's exact exposure and revision. What remains is the demo's own assembly — the
  NodePort, `minio.default.svc`, and a `registryConfigYaml` with no `storage.redirect` stanza at all —
  plus the live route proof. Owning sprints: 9.10 (plan-owned readiness/preconditions, closed), 14.7
  (generic algebra, closed), and 13.20 (demo migration/live proof, open).
- **Provider-guest durable compatibility alias and remaining raw root reconstruction**
  (`core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
  `demo/src/HostBootstrapDemo/Commands.hs`) — closed Sprint 5.6.1 now resolves root config against its
  stable project-home anchor, yields `CanonicalProjectRoot scope rootId` without rewriting descriptive
  context, and makes direct-host Docker consume only the matching canonical absolute host `.data`.
  `/var/tmp/hostbootstrap-demo-data` remains a guest-local projection for VM-backed Docker daemons, and
  other lifecycle adapters still accept raw path values while the final opaque `ProjectPlan` is open.
  `HostBootstrap.Substrate.Provider.Alias` now supplies both the typed prepared call/release algebra
  and a real `StrongAliasBackend` holding all four clauses in the guest (`flock -x` across the bracket,
  a guest origin record, a `stat` `device:inode` identity guard, and compare-before-`unlink` release).
  All three provider guests run the same Linux image, so that one backend covers WSL2, Lima and Incus
  together. What remains is **production consumption**: the demo still mints the alias with a bare
  `ln -s` over `classifyAlias`/`planAliasEnsure` facts, which mints no receipt. Replacement: route
  `mintDurableAlias` through the plan-owned prepared operation over that backend, building its
  `GuestExec` from the provider lift, and then make the finalized plan derive and retain distinct guest,
  container, kind-node, and pod projections. Delete the remaining alias-fact bypasses and raw adapter
  inputs that allow path-kind substitution. Owning sprints: 11.10 (provider guest alias consolidation), 15.9
  (root/config binding), 16.6 (recursive plan consumption), and 19.8 (finalized plan projections).
- **Definition-only public `HostBootstrap.RoleLifecycle` callback engine**
  (`core/hostbootstrap-core/src/HostBootstrap/RoleLifecycle.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Service.hs`) — **the callback bag itself was deleted
  2026-07-30 by Sprint 14.6**: `RoleSpec`, `roleAcquire`, `roleServe`, `roleDrain`, and `runRole` no
  longer exist, and their removal is recorded under **Removed Surfaces**. The opaque
  `RolePlan`/`RoleCursor`/`VerifiedServicePlacement` engine, the pre-cursor draft/admission gate chain,
  the derived lease requirement, and the masked run-to-Exit operation described below all landed with it.
  What remains open in this entry is the **production consumption** half: `HostBootstrap.Service` /
  `service run` still calls the registry-selected action directly rather than entering through the
  activation package and the engine, because nothing in production can yet produce a
  `RootInvocationAuthority` to sign an `ActivationManifest` (see
  [phase-14-composition-methodology.md](phase-14-composition-methodology.md) Sprint 14.6 `Remaining
  Work`). The predecessor-manifest recovery, `ServiceLeaseTransferBarrier`, and
  `resumeRoleLifecycleAdmission` clauses below likewise remain open. Historical description of the
  removed shape: `runRole` was consumed only by its test module
  after the demo `HostBootstrapDemo.Role` consumer and appended role verbs were removed, and its arbitrary
  callback/CPS shape could throw after receiving live resources without constructively reaching Drain.
  Replacement: one opaque
  `RolePlan scope specDigest planId configId secretDigest frame revision instanceId` and
  `RoleCursor scope planId frame instanceId phase` consumed only inside
  `HostBootstrap.Service`. Validate the role draft/digest before durable state, then make
  `withRoleLifecycleAdmission` the sole one-use durable admission producer and require
  `withRuntimeRolePlan` to linearly consume that exact admission/verified draft under its already-fixed
  `planId`; its activation-bound key moves only Reserved→Consumed, lost acknowledgment rehydrates the
  stored identities, duplicate tokens have one CAS winner, and commit-before-cursor-delivery resumes only
  through `RolePlanOpenUnknown`. Retained activation/request values cannot open another plan. Before admission, independently
  enumerate the complete non-live predecessor manifest with every member's full old
  plan/spec/binary/config/secret/role-plan/effect-ceiling and local
  plan/config/revision/instance/invocation/journal/resource lineage plus authoritative
  `VerifiedRoleInstanceNonLive`. Exact-set recovery yields no new plan authority; exclusive transfer must
  produce a `ServiceLeaseTransferBarrier` covering every predecessor, and only
  `resumeRoleLifecycleAdmission` may consume the single full-new-lineage settled recovery package to
  close old invocations and reserve the new one. Recovery Unknown retains that same new lineage and has
  an exact resume/reprobe consumer. Live non-exclusive instances remain outside recovery; live exclusive instances
  yield no recovery authority. The sole public masked run-to-Exit operation hides all phase eliminators and retains every
  receipt/unknown plus either verified absence of exclusive effects or the matching live
  `ServiceGenerationLease` through Drain. Ready restartable workers expose stable supervisor handles;
  only a journal-prepared core transition may replace/reprobe a child. Hide/delete the parallel public
  callback path. Owning phase: Phase 14 Sprint 14.6.
- **Unjournaled `IO ()` lifecycle effects and blind retry after uncertain outcome**
  (`core/hostbootstrap-core/src/HostBootstrap/Ensure.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
  `demo/src/HostBootstrapDemo/Commands.hs`) — most current
  reconcilers neither reserve a generation before an external effect nor persist whether an interrupted
  create/delete was absent, observed, committed, pending, or released. A retry can therefore reconstruct
  intent from names and callbacks instead of recovering the exact attempt. Replacement: the private
  scope/generation/resource-indexed acquisition journal, separate
  `ReservationOutcomeUnknown`/`EffectOutcomeUnknown`/`TeardownOutcomeUnknown` states, total reprobe,
  stable same-generation operation keys, separate adoption/repair/non-release phase graphs, exact
  released-generation rollover, one-use versioned operation sessions, durable initial/rotated fence
  records that reject delayed permits, and a recovery gate over independently complete session and
  operation sets that includes zero-operation Open sessions and withholds current-broker admission until
  every old logical session is rebound/settled/Closed and every operation is settled. Its total operation
  discriminator separates unknown, continuable pre-call/intermediate, the closed fenced same-key retry
  whitelist, successful, and terminal states. Only continuable phases can receive current-fence prepare
  authority and only the retry whitelist can receive fenced same-key retry authority; success and terminal
  branches receive neither. Operation
  registration consumes the exact closed first-generation or released-reacquisition origin and
  atomically records its generation, initial phase, and session membership before prepare. A valid
  initial intent may have no fence but cannot prepare; recovery idempotently completes the stable
  initial-fence protocol and threads its sole successor state/permit before exposing current-fence
  authority. Prepare consumes the exact plan-owned closed precondition set, reruns every dependency/
  target version, and returns only the jointly fresh prepared pair; retained readiness and either half
  have no effect entry point. The recovery
  gate also verifies the complete required resource-record set and derives either exact owned
  frame/managed-handle/receipt/resource/operation evidence or the exact verified release-record
  tombstone for every released forest member. Only a later protected absence probe over that tombstone
  may produce exact released-absence evidence and a distinct-key `FreshGeneration`. That token is only
  eligibility: its sole consumer constructs the exact reacquisition origin, and registration must
  revalidate/consume it atomically with the new intent/session membership. Permit-bound
  backend adapters, lease-bound plan migration whose freeze revokes session admission and waits for every
  session (including zero-operation sessions) to close before activation, harness-terminal-close recovery,
  and receipt-driven recursive resume complete the replacement. Owning sprints: 5.7 (backend operations and
  receipts), 9.10 (state/reconcile algebra), 10.9
  (run/mode leases, recorded-session admission, and Harness close), 15.9 (session/fence/prepare authority),
  and 16.6 (snapshot-bound recursive interpreter and migration/teardown recovery).
- **Public/self-asserted `BinaryContext` capability authority and unchecked role widening**
  (`core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`) —
  `HostBootstrap.Context` exports `BinaryContext (..)`, `Capability (..)`, role/context constructors, and
  record-update fields; decoded context labels plus `addRole` can therefore assert or widen the same
  values command gates currently treat as authority. `service run` still rejects a widened non-leaf
  primary kind, while `project up` can accept a widened daemon/image-build leaf, so the same union is
  neither sufficient nor safely restrictive. The former `cfgWithContext` updater is removed; the
  remaining replacement is to keep placement/context descriptive, mint opaque capability tokens only through
  validated transitions, enforce compatible role composition, and narrow authority at every child
  handoff. Owning phase: Phase 15 Sprint 15.9 (opaque transition tokens from Phase 9 Sprint 9.10).
- **Partial topology validation and an open supplied-witness list**
  (`core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`) — current validation finds the selected
  `currentFrame`, compares its kind, follows that frame's parent links, checks declared class/capability
  membership, and executes each supplied witness. It does not reject every duplicate ID, cycle,
  disconnected frame, `parentChain` disagreement, provider/role/child-kind mismatch, or missing required
  witness; an empty witness list is therefore vacuously accepted, and ancestry traversal has no visited
  set. Replacement: derive one opaque `ValidatedContext scope planId frame` from the finalized plan,
  validate a unique connected acyclic graph with a terminating visited traversal, and compute a closed
  frame/kind/provider-indexed required-witness relation that callers cannot omit or extend as authority.
  Owning phases: Phase 15 Sprint 15.9, Phase 16 Sprint 16.6, and Phase 19 Sprint 19.8.
- **Raw service-handler IO and incomplete runtime authority/effect binding**
  (`core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
  `core/hostbootstrap-core/test/CLISpec.hs`,
  `core/hostbootstrap-core/test/Spec.hs`,
  `demo/app/Main.hs`,
  `demo/hostbootstrap-demo.cabal`,
  `demo/src/HostBootstrapDemo/Commands.hs`,
  `demo/src/HostBootstrapDemo/Config.hs`,
  `demo/src/HostBootstrapDemo/Web/Server.hs`,
  `demo/src/HostBootstrapDemo/Accelerator/Daemon.hs`,
  `demo/test/ConfigSpec.hs`,
  `demo/test/WebServerSpec.hs`,
  `demo/test/AcceleratorSpec.hs`) — Sprint 19.8 removed arbitrary string selection, split sibling-config
  reads, fallback ports/timeouts, and full-record handler delivery. The current finalized registry binds
  typed service definitions and role codecs to the full codec's canonical `specDigest`; `service run`
  canonically verifies one sibling snapshot, structurally selects exactly one definition, and closes the
  action over only its typed role fields plus a safe framework view. That action is still raw `IO`, and
  service/daemon child config delivery still carries the broader project record before local role-wire
  projection. The shared missing-config loader also recommends root `project init`, which fails a
  service-leaf gate. Replacement: pair the signed rollout revision at startup with a concrete process
  `instanceId`; the activation-bound private channel
  separately yields the exact `VerifiedSecretBundle`. Child-local wire verification produces opaque
  `ValidatedServiceRequest specDigest configId secretDigest fields service`, inseparably containing
  `RoleParams specDigest configId secretDigest fields service`, under a fresh identity distinct from the
  parent `configId`; neither request nor parent identity is serialized. Inside the sole core-owned
  run-to-Exit operation, package that request with the exact one-use revision/instance/Serve command
  authority, matching
  `ServiceSelection scope specDigest planId configId secretDigest frame revision instanceId ServePhase
  service effects`, and closed `ServiceProgram` registry handler as one internal existential
  `SelectedService scope specDigest planId configId secretDigest frame revision instanceId ServePhase
  fields`. The handler receives neither full config nor raw `IO`/config-read/bind/spawn authority.
  Every mutating program effect is sealed with its exact target/arguments as
  `SealedServiceEffectCall ... targetId operationKey callDigest`; only exact Ready-session/package prepare
  can yield
  `PreparedServiceEffect ... targetId operationKey callDigest fence attempt journalVersion`. Prepare
  rejection/unknown returns only an indexed non-Ready successor plus the whole package to Drain/recovery,
  never an `Either` that loses resources. The backend returns
  `ServiceEffectAdvance ... targetId operationKey callDigest ... fromJournalVersion nextJournalVersion
  nextEffectState`. The result is visible only with the sole same-row/phase successor session and
  reconstituted whole retained package; no bare lease can detach from receipts. Observed outcomes yield
  `ServiceEffectReady`; unknown yields
  `ServiceEffectUnknown effect targetId operationKey callDigest fence attempt`, accepted only by
  exact-key/fence recovery
  that resolves it or mints
  `VerifiedSameKeyRetry ... configId secretDigest ... service effects phase effect invocationId sessionId
  targetId operationKey callDigest fence previousAttempt nextAttempt unknownJournalVersion
  retryJournalVersion` with the complete consumed unknown-session lineage. Only the private joint resume
  eliminator can consume that Unknown session/package/proof and reconstruct the exact sealed call.
  Effect-row permission alone cannot retry or mutate. No independently
  substitutable key/payload/action/config ID/field row/revision/instance/phase/effect row crosses the
  boundary, and neither lifecycle acquisition nor handler execution can start twice.
  Add total role-specific
  Add command-specific recovery guidance. Owning phases: Phase 15 Sprint 15.9, Phase 17 Sprint 17.4, and
  Phase 18 Sprint 18.6.
- **Config-only self-reference handoff with no authenticated authority transfer**
  (`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Lift.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Context.hs`) — the lift streams a
  context-adjusted full child config, but the self-invoked process has no atomic run lease or one-time token from which
  to rehydrate the exact Production/Harness scope; treating the descriptive config as authority would
  make scope widening and replay representable. Replacement: persist and verify a versioned
  `StablePlanSnapshot` binding the plan/config digests, open a root-owned broker with an exclusive
  `UnboundRunLease scope brokerGeneration`, then bind it to the verified plan digest as
  `BoundRunLease scope specDigest planDigest brokerGeneration`. Mint a one-use **per-edge**
  `ConfigHandoff` token/
  grant for normal config delivery or a distinct `RecoveryHandoff` for signed snapshot-derived teardown
  adapter wire; both bind the exact scope, plan, parent/child frames, receiver challenge, payload digest,
  verb, and phase. The child must jointly verify the payload and matching handoff kind before local
  authority exists. Each command/grant also carries a one-use invocation identity which atomically opens
  one versioned operation session. Before each external effect, one protected prepare compare-and-swap
  revalidates exact mode/lease/revision/authority/Open-session/fence/journal state, persists the
  operation-specific unknown phase, consumes/reruns the exact plan-owned zero/one/many precondition set,
  and jointly yields a target/generation/operation/precondition-set/call-digest/session/fence/attempt/
  journal-indexed `PreparedOperation` plus matching fresh `PreparedPreconditions` and the successor
  Open-session, Open-project state, and
  revision-permit authority; the initial operation phase and membership in that session are recorded by one
  atomic transition before prepare using the exact first/reacquisition generation origin. Session open,
  operation registration, session close, prepare, and
  settlement all advance the same protected project journal. The `PreparedOperation` is the sole
  attempt/fence-indexed effect authorization and can call the adapter only with its matching
  `PreparedPreconditions`; a mismatched descriptor/binding/teardown step, retained `Ready`, either
  prepared half, or raw authority cannot call it. Every terminal observation
  returns `OperationAdvance` on success or typed failure and exposes its result only with the sole successor
  state/permit pair. Initial intent without a fence is explicit and non-authorizing; initial fence
  creation and crash-time rotation persist/resume the same proposed epoch and return the sole successor
  state/permit pair, while delayed old permits are rejected or
  deduplicated, and a terminal ACK compare-and-swaps only after all registered outcomes settle. A fresh
  broker cannot open another command session until clean activation proves no old Open session or the
  protected recovery interpreter verifies the independent session/operation manifest, rebinds and
  closes every recorded logical session (including zero-operation sessions), and settles every
  operation through a total unknown/continuable/retryable/successful/terminal discriminator; omitted/
  duplicate/wrong-membership records yield no admission. The same gate verifies the complete rehydrated
  resource set, and recovered teardown yields a closed sum: exact snapshot-derived frame, managed handle,
  receipt, resource binding, operation binding, and forest-produced teardown point/step for owned work, or
  the exact verified release-record tombstone for released work. Only a later protected absence probe
  can turn that tombstone into released-absence and generation-rollover evidence; the rollover token
  still must pass through its sole origin consumer and atomic intent/session registration. Completed migration
  first freezes new session admission,
  then yields new-revision admission only after all prior sessions settle. No
  authority-bearing material enters Dhall/`argv`/environment, and every later edge gets a fresh
  handoff. Restartable controller services use a signed revision/config/spec/binary/secret-digest-bound
  runtime manifest paired after creation with a measured per-process instance ID, not replay of either
  edge kind. Owning phases: Phase 10 Sprint 10.9 (broker,
  lease/mode/recovery), Phase 15 Sprint 15.9 (receiver/transport/session/fence gate), and Phase 16 Sprint 16.6
  (snapshot-bound recursive consumption).
- **Successful Production `up`/`down` has no typed ordinary invocation close**
  (`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`) — closing per-command operation sessions does
  not close the root `BoundRunLease`/broker invocation. Treating every successful exit as abandoned
  recovery leaks invocation authority, while reusing terminal project finalizers would incorrectly clear
  Production mode or claim active snapshot/resources released. Replacement: the core recursive
  interpreter mints opaque `ProductionInvocationCompleted` only for successful `ProjectUp`/
  `ProjectDown`, from the independently complete Closed-session and terminal-operation sets with no live
  permits, while revoking broker admission at the exact journal version. A protected CAS consumes that
  proof and closes only the exact bound lease/broker invocation. Its closed branch preserves
  `ProjectModeLease ... ProductionMode`, the bound snapshot/binding, active revision and journal/resource
  records, complete rehydrated set, and `OpenProject`, and returns no bound lease/admission/permit
  authority. Unknown acknowledgment exposes only a stable close key; bound recovery selects a narrow
  incomplete-close branch that may reprobe/resume that same idempotent key but cannot reopen a session.
  `ProjectDestroy` and verified true-pre-effect refusal remain the separate
  `releaseProductionMode` paths. Owning phases: Phase 10 Sprint 10.9 and Phase 16 Sprint 16.6.
- **ConfigMap/baked-config dispatch without restart/build config authority**
  (`core/hostbootstrap-core/src/HostBootstrap/Service.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
  `demo/src/HostBootstrapDemo/Commands.hs`,
  `demo/docker/Dockerfile`) — controller restarts trust the mounted descriptive config and current
  service/context gates without a signed project/run/plan/frame/revision/spec/binary/config/secret-digest
  manifest or a measured process instance, while
  Dockerfile-time checks run from a baked image-build config without a single-use
  project/spec/config/build/source/builder session. A changed same-path ConfigMap, Secret, binary, or
  copied same-byte frame proof is not linked to one fresh local config/instance identity. Replacement:
  the root signs an immutable rollout revision/controller template; startup independently measures pod
  UID plus restart count or an OS invocation nonce and binary/image identity. Provider-specific immutable
  revision installation plus exact mounted-byte/private-channel verification jointly yields
  `VerifiedRuntimeRoleActivation`, `VerifiedSecretBundle`, `VerifiedConfigWire`, and
  `ValidatedServiceRequest specDigest configId secretDigest fields service` before the one-use lifecycle
  admission constructs
  `RolePlan scope specDigest planId configId secretDigest frame revision instanceId`,
  `RoleCursor scope planId frame instanceId phase`,
  `RolePlanDigestBinding scope specDigest planDigest rolePlanDigest planId`, and matching placement.
  Build-session verification jointly yields a Production-validated config,
  `ImageBuildFrame projectId specDigest configId frame`, measured source/context and coordinator/builder
  identities, and
  `BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest`.
  Owning phases: Phase 14 Sprint 14.6 and Phase 15 Sprint 15.9.
- **Cooperative generated-config sidecar and byte-equality ownership convention**
  (`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`) — sidecar acquisition
  and destination creation are separate, so a non-cooperating writer can win the check-to-write race;
  matching bytes support cautious cleanup but are not an exclusive identity-bearing receipt.
  Replacement: acquire a generation/project/run-scoped reservation in a protected namespace and use an
  identity-bound conditional kernel mutation or OS-enforced lock/lease for publication and cleanup.
  Exclusive create/rename or compare-then-unlink alone does not exclude same-privilege replacement;
  backends without a strong primitive return `Unsupported` and mint no receipt. Owning phase: Phase 10
  Sprint 10.9.
- **Check-then-act Production/Harness exclusion with no project-wide mode lease**
  (`core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
  `demo/src/HostBootstrapDemo/Commands.hs`) — the harness probes sibling config/production-cluster state,
  but those observations are not one versioned transaction with run ownership; a Production invocation
  can race the gap, and current teardown has no exact mode epoch to retain across `down` or release last.
  Replacement: a verifier that derives its total probe from installed project identity plus one shared
  `ProjectModeLease projectId mode brokerGeneration` compare-and-swap used by both root openers.
  Production `down` retains its mode. Production release consumes a closed
  `ProductionClosureAuthorization`: settled closure requires exact `ProjectDestroy` plus
  `DestroySettled`, while any verb's true-pre-effect closure requires
  `VerifiedNoProjectResourcesAcquired`. Both paths require the independently complete session manifest to
  prove every session Closed, including zero-operation sessions. The final compare-and-swap contends with
  session opening and atomically records `ClosedProject`, closes the exact invocation lease, and releases
  the exact mode; no check-to-close gap remains. Harness close releases its mode only after close effects
  and lease settlement. Owning phase: Phase 10 Sprint 10.9.
- **Bound-run reopening exposes no exhaustive operation/revision recovery discriminator**
  (`core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`) — current cleanup reconstructs behavior from
  callbacks/config/path state rather than eliminating one protected sum that distinguishes Open normal,
  incomplete old-active migration, completed new-active migration, and an exact persisted Harness
  Closing epoch. A generic rebound journal can therefore conceal which revision/state is authoritative.
  Replacement: effectful snapshot/lease binding that yields `BoundInvocationRecovery`, followed by
  exhaustive operation-state and `BoundRevisionRecovery` eliminators; only the matching activation gate
  returns an active-revision proof, complete rehydrated owned/released resource set, Open state, journal,
  permit authority, and current-broker session admission. Recovered operation state is likewise a total
  closed sum over unknown, continuable pre-call/intermediate, explicitly retryable, successful, and
  terminal records rather than a partial “unknown only” path. Its initial-intent branch explicitly
  handles verified fence absence by completing the sole durable initial-fence protocol before exposing
  `OperationFence`; it never assumes a fence exists. The admission capability is absent during
  freeze and terminal close. Configful abandoned Production `ProjectUp` additionally requires a separate
  protected bound-recovery profile opener over the exact new root/broker authority, active Production
  mode, bound lease, verified/bound snapshot/binding, and `BoundInvocationRecovery`; it cannot misuse the
  unbound-only fresh-profile opener. Owning phases: Phase 10 Sprint 10.9 and Phase 16 Sprint 16.6.
- **Unversioned terminal harness cleanup without Open→Closing crash recovery**
  (`core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Command.hs`) — generated config/data-root cleanup and lease
  release are best-effort callback effects with no exact closure-evidence version, atomic close epoch,
  close-operation journal, or restart gate. Prepare can race cleanup, a retained pre-destroy proof can be
  reused after destroy→up, and a kill can strand partial close effects. Replacement:
  sole complete-forest and true-no-effect verifiers whose closed conversions mint same-journal-version
  `ProjectClosureEvidence`, an atomic Open→Closing compare-and-swap after every normal session is Closed,
  close-specific intent/unknown/reprobe/fence permits, `HarnessCloseAdvance` returning the successor
  close journal on success or typed failure, exact persisted Closing recovery, and a final atomic
  `ClosedProject`/bound-lease/Harness-mode release. Owning phases: Phase 10 Sprint 10.9 and Phase 16
  Sprint 16.6.
- **No complete-set active-revision migration/freeze/activation protocol**
  (`core/hostbootstrap-core/src/HostBootstrap/Chain.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Command.hs`) — current delayed lifecycle behavior has no
  protected old/new active-revision state, cannot prove a complete heterogeneous owned/released record
  set, and has no barrier between copied records and permit issuance. A config revision can therefore be
  inferred from current inputs or partially rebound without a durable all-or-nothing transition.
  The target must also remove the current documentation's uninhabited plan/snapshot ordering: a new
  verified snapshot cannot be required before the new plan that renders it, nor may that plan first be
  reconstructed after the old revision is frozen.
  Replacement: the sole `ProjectUp` migration-profile producer revalidates the active mode and exact
  old-bound lease/snapshot/binding/recovery without a new plan. A pre-freeze rank-2 builder then creates
  one non-authorizing candidate plan/prospective snapshot package. Its only consumer persists/fsyncs and
  authoritatively reads back those exact bytes under a stable migration key before atomically freezing
  prepare and revoking session admission. It derives the exact old record set internally, drains/fences
  old permits, closes every old logical session (including zero-operation sessions), and folds every
  manifest member with its owned receipt or released tombstone. Freeze replaces the old bound lease with
  one stable-keyed frozen capability; the final active old→new compare-and-swap consumes it and returns
  only the new-bound lease, so dual lease authority is unrepresentable. Pre-CAS recovery may
  resume/cancel under old without reopening normal admission, but must load the exact persisted
  prospective snapshot by stable key before reconstructing a local plan. Post-CAS recovery likewise
  loads that snapshot before configful forward activation or configless teardown; current config cannot
  infer a target. Both normal activation and completed recovery prove
  all old sessions Closed and yield the new revision's `CurrentBrokerSessionAdmission`; neither the frozen
  old state nor the committed-new window can open a session.
  Owning phase: Phase 16 Sprint 16.6.
- **Hard-coded demo variants** (`demo/src/HostBootstrapDemo/Config.hs`) — the generic typed matrix is
  implemented, but the demo's two message drafts still live in Haskell rather than decoded
  `<project>.test.dhall`. Replacement: Phase 20's typed config-driven variant mapping, including proof
  that a config-only third variant runs without a Haskell edit. Owning phase: Phase 20 Sprint 20.5.
- **Frame-local teardown that does not descend into the frames it acquired**
  (`core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`) — **narrowed 2026-07-30 (Sprint 16.6).** The
  three formerly independent lifecycle views are gone: Sprint 19.8 validates the exact forward
  sequence, identities, frame contiguity, dependencies, operation keys, and per-step reverse policies;
  the per-frame descent is declared on its own plan node (`descendsVia`); and the reverse effect is
  declared on the acquiring node (`reversedBy`), with both teardown verbs driven as projections of that
  one plan. What remains is that `project down`/`project destroy` clean only the frames the current
  binary can reach — they do not hand the verb into each descendant frame first — so the landed
  `TeardownForest` has no production call site and deeper nodes are released with their parent rather
  than visited. Replacement: the recursive child-first unwind, after which the acquisition ledger and
  reverse teardown are projections of the same resource identities in every frame. Its destroy forest exposes a
  separate pre-descent reachability step for an exact stopped provider before retained children, then
  exposes the ordinary provider stop/delete step only after those children settle; the two orders cannot
  be conflated. Owning phase: Phase 16 Sprint 16.6.
- **Hard-coded Production cluster/profile projection inside harness-driven demo runs**
  (`demo/src/HostBootstrapDemo/Commands.hs`, especially `containerPlan`,
  `demoTestUp`, `demoTestDown`, and direct-plan construction;
  `core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`, especially
  `ClusterProfile`, `resolvePlan`, and `durableDataPath`) — container-frame work unconditionally calls
  `resolvePlan ... Production`, deriving the fixed cluster name and `.data` root independently of the
  harness run. A generated test config therefore cannot make production identity collision
  unrepresentable. Replacement: construct one scope-indexed `ProjectPlan` per Production invocation or
  fresh harness variant, derive `containerPlan`/cluster/root/port identities only from that exact plan,
  and retain its verified receipts through cleanup. Sprint 5.7 owns only the scope-agnostic backend
  operations and receipts; Sprint 15.9 owns the root scope authority, Sprint 10.9 opens the matching
  lifecycle profile, Sprint 16.6 consumes it in the recursive plan, and Sprints 13.18/20.5 wire the demo.
  Owning phases: Phase 5 Sprint 5.7, Phase 10 Sprint 10.9, Phase 13 Sprint 13.18, Phase 15 Sprint 15.9,
  Phase 16 Sprint 16.6, and Phase 20 Sprint 20.5.
- **Incomplete/static workload budget disconnected from the applied topology**
  (`demo/src/HostBootstrapDemo/Web/Api.hs`, `demo/src/HostBootstrapDemo/Commands.hs`,
  `demo/chart/templates/deployment.yaml`) — the user-visible `fitsBudget` call checks the static
  one-element `demoPods = [demoWebPod]`, while cluster preflight consumes a coarse envelope and the
  registry, MinIO, accelerator, web replicas, and chart requests/limits do not come from one complete
  plan-derived workload set. Passing either check therefore does not prove that the manifests about to
  run fit the declared ceiling. Replacement: Sprint 13.18 derives the non-empty complete workload resource
  set and every Kubernetes request/limit from the demo plan. The generic lifecycle layers in Sprints
  9.10/15.9/10.9/16.6 validate, carry, and require its proof before the first mutation permit; Sprint
  5.7 owns only the budget-aware backend operation. Owning phases: Phase 5 Sprint 5.7, Phase 9 Sprint
  9.10, Phase 10 Sprint 10.9, Phase 13 Sprint 13.18, Phase 15 Sprint 15.9, and Phase 16 Sprint 16.6.
- **Unconsumed budget partitions and unchanged child-resource projection**
  (`demo/src/HostBootstrapDemo/Config.hs`, `demo/src/HostBootstrapDemo/Commands.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Cluster/Budget.hs`) — the duplicate context budget and
  public scalar-constructor bypasses are removed, but child projection still copies the sole full
  project `resources` value unchanged and live consumers do not use the plan-indexed slice. The locally
  computed cluster slice therefore never reaches every service leaf. Replacement: consume the delivered
  pure exact
  `ProviderBudgetCapability` → `ProviderWallSpec`/`EffectiveBudget` → `VerifiedWorkloadFit` →
  `BudgetPartition` → `ResourceSlice` lineage that projects each frame/resource slice before effects.
  A later same-`wallSpecId` live wall authority is tracked by the provider-reconciliation entry below.
  Complete demo workload derivation is the preceding entry. Owning phases: Phase 13 Sprint 13.18 and the
  consuming provider/interpreter Sprints 5.7, 10.9, 11.10, 15.9, and 16.6. Sprint 5.8 has consumed the
  lineage for direct Colima acquisition but does not close the remaining child-slice consumers.
- **Same-name kind cluster adoption and destructive unhealthy recovery without ownership evidence**
  (`core/hostbootstrap-core/src/HostBootstrap/Cluster/Lifecycle.hs`, `ensureCluster`) — a healthy
  same-name cluster is silently reused and an unhealthy/unverifiable one is deleted and recreated without
  a plan/generation receipt, so foreign state can be adopted or destroyed. Replacement: total
  absent/owned/foreign/conflict classification; only a matching verified ownership receipt may authorize
  mutation or cleanup, while explicit adoption requires separate opaque authority and an unsupported
  backend mints no receipt. Owning phases: Phase 5 Sprint 5.7 and Phase 9 Sprint 9.10.
- **No-op `context-init` step separated from the child-config delivery operation**
  (`demo/src/HostBootstrapDemo/Commands.hs`, `contextInitAnnounce`,
  `contextInitDirectAnnounce`, and `containerConfigPayload`;
  `core/hostbootstrap-core/src/HostBootstrap/Chain.hs`) — the named step's body only prints an
  announcement. **Narrowed 2026-07-30 (Sprint 16.6):** the delivery is no longer *independent* of the
  row — the payload rides the `descendsVia` that same step declares, which `mkStepPlan` requires
  exactly one of per frame — so the plan can no longer describe a boundary whose config came from
  somewhere else. What remains is that the step's own action does not perform or authorize the
  projection. Replacement:
  one plan node owns child projection, fresh child config identity, authenticated delivery, durable
  operation state, the exact `ConfigHandoff` grant consumed by the receiver, and the target/operation/
  precondition-set/call-digest/journal-indexed `PreparedOperation` plus matching
  `PreparedPreconditions` jointly returned after durable prepare; its terminal observation
  returns the only successor state/permit pair through `OperationAdvance`. Owning phases: Phase 15
  Sprint 15.9 and Phase 16 Sprint 16.6.
- **Public, anonymous demo endpoints and source-hard-coded MinIO credentials**
  (`demo/kind.yaml`, `demo/kind-in-cluster.yaml`,
  `demo/src/HostBootstrapDemo/Commands.hs`, especially `minioAccessKey`,
  `minioSecretKey`, `registryManifest`, and `minioManifest`) — registry, web, and MinIO host mappings bind
  `0.0.0.0`; the registry serves anonymous HTTP; and fixed source credentials are rendered into a
  Kubernetes Secret. These are not loopback-only or per-run/project secret capabilities. Replacement:
  Sprint 5.7 supplies the scope-agnostic loopback-binding primitive; Sprint 13.18 derives the complete demo
  endpoint/secret manifest and plan/run-scoped credentials over the opaque root authority from Sprint 15.9
  and secret representation from Sprint 19.7. Those credentials are delivered only to the exact workload
  identities. Owning phases: Phase 5 Sprint 5.7, Phase 13 Sprint 13.18, Phase 15 Sprint 15.9, and Phase 19
  Sprint 19.7.
- **Registry credential transport exposes raw text and relies on weak origin/lifetime boundaries**
  (`core/hostbootstrap-core/src/HostBootstrap/Registry.hs`,
  `demo/src/HostBootstrapDemo/Commands.hs`) — public `registryConfigPayload` unwraps the credential to
  `Text`, `isDockerHubKey` uses substring matching, one forwarding lane carries the payload through
  `HOSTBOOTSTRAP_REGISTRY_AUTH`, and trap/bracket cleanup cannot guarantee removal after process kill or
  host failure. Environment and Docker-container metadata can expose the value to same-user observers
  while a transient config exists. Replacement: exact normalized registry-origin matching, an opaque
  non-exporting secret capability, and an authenticated scope/plan/operation-bound child handoff over a
  protected descriptor or platform credential facility with recoverable cleanup. Owning phases: Phase 15
  Sprint 15.9 and Phase 19 Sprint 19.7.
- **Bare host process invocations outside the closed `HostTool` boundary**
  (`demo/src/HostBootstrapDemo/Commands.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Command.hs`) — host call sites that resolve a
  literal command through `PATH` contradict the absolute `AbsExe` doctrine. Nested guest payload commands
  are explicitly separate. Replacement: enumerate/resolve every production host tool and mechanically
  reject bare host calls. Owning phase: Phase 2 Sprint 2.5.
- **Stale appended verbs and Harbor-era demo metadata**
  (`demo/hostbootstrap-demo.cabal`, `core/hostbootstrap-core/test/StepSpec.hs`, `demo/test/CommandsSpec.hs`,
  `demo/src/HostBootstrapDemo/Commands.hs`) — generic fixtures, step examples, help/docs, and
  test metadata still append project verbs or name `deploy-harbor` after the fixed command tree and current
  registry/MinIO path replaced those surfaces. Replacement: the fixed command surface plus the demo's
  typed Production plan/current registry-object-store metadata. Owning phases: Phase 13 Sprint 13.18 and
  Phase 21 Sprint 21.4.
- **Source comments/help that assert superseded guarantees**
  (`core/hostbootstrap-core/src/HostBootstrap/Dhall/Gen.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Step.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/CLI.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Ensure/Homebrew.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Readiness/Internal.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Readiness.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Harness.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/HostPrereqs.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
  `demo/src/HostBootstrapDemo/Commands.hs`,
  `demo/src/HostBootstrapDemo/Config.hs`,
  `demo/src/HostBootstrapDemo/Web/Api.hs`,
  `demo/src/HostBootstrapDemo/Web/Server.hs`,
  `demo/src/HostBootstrapDemo/Accelerator/Daemon.hs`, `hostbootstrap/bootstrap.py`, and
  `hostbootstrap/cli.py`) — closed Sprint 8.7 reconciled the lower-layer codec/schema and
  surface-specific snapshot claims. Remaining comments/help claim contiguous frame grouping despite
  first-appearance regrouping, best-effort teardown idempotence despite swallowed failures, and Python
  installation of Homebrew despite the bootstrapper only requiring it. Additional stale claims call the
  compiled test-case selector a `SUITE`/suite and already root-only; say `project down` removes no
  filesystem path despite the Windows host-file restore; place `.data` inside a frame destroyed with
  “everything” provisioned and call best-effort `project up` idempotent; describe publicly exposed
  `MkReady` as test-only while production imports it;
  call cooperative harness checks mechanically exclusive, say test storage is always one literal path,
  describe demo safety probes as mutual exclusion; claim a POSIX `exec` handoff on Windows and that the
  permanent thin Python pre-binary floor is temporary; and describe maintainer commands as Poetry-only
  despite the importability-only Python dispatch gate. Resource comments also claim `fitsBudget` is wired
  to cluster bring-up and agrees with the applied slice; place every Linux lane behind Incus; give bare
  Linux a storage wall; use the wrong host-reserve example; and call real `df` storage generous.
  Service comments/help also reopen config inside handlers despite one-snapshot intent and
  unconditionally recommend root `project init` for a missing service-leaf config.
  Replacement:
  after the owning implementations land, make Haddock/help describe the exact validated codec, plan
  topology, structured teardown outcome, host-root durability boundary, case-ID/parser authority,
  constructor visibility, clause-holding Harness ownership/profile derivation, reflected
  vocabulary ownership, actual harness consumers, substrate-specific binary handoff, permanent pre-binary
  prerequisite ownership, and real Python dispatch surface; add drift checks for every retired phrase. Owning
  phase: Phase 21 Sprint 21.4, after the complete `Blocked by` set in that sprint closes.
- **Demo derived build can consume a stale same-named local base**
  (`demo/src/HostBootstrapDemo/Commands.hs`) — the consumer path still needs to pull the selected
  published rolling tag before its derived build. A digest may identify/bind that one pull-to-build
  invocation, but digest pinning is not the replacement contract. Owning phase: Phase 13 Sprint 13.18
  (demo consumption).
- **Unpinned Windows GHCup download and unasserted Linux `curl` bootstrap dependency**
  (`hostbootstrap/bootstrap.py`, `hostbootstrap/prereqs.py`) — the Windows bootstrap executes a current
  upstream executable without an expected digest, while Linux can pass `doctor` and fail later because
  the GHCup path assumes `curl`. Replacement: closed host-tool resolution plus a reviewed
  version/URL/digest manifest and an exact prerequisite/install plan. Owning phase: Phase 2 Sprint 2.5.
- **Duplicate runtime-capability gates in `HostBootstrap.HostPrereqs`**
  (`core/hostbootstrap-core/src/HostBootstrap/HostPrereqs.hs`) — the Haskell mirror reasserts Docker
  reachability, Linux KVM, and NVIDIA-container-runtime state even though those are mutable
  binary-owned `ensure docker` / `ensure incus` / `ensure cuda` transitions, not irreducible pre-binary
  facts. Replacement: retain the module but narrow it to the exact Python pre-binary floor; delete these
  duplicate checks so each runtime capability has one probe/reconcile authority. Owning phase: Phase 2
  Sprint 2.5.
- **Provider-wall rounding/reconcile gaps and success labels that claim unapplied reconciliation**
  (`core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Substrate/Provider.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Incus.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Lima.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Wsl2.hs`,
  `demo/src/HostBootstrapDemo/Commands.hs`) — preflight, slice rounding, and provider launch builders can
  disagree; small inputs can round a cluster slice beyond strict containment, Incus/WSL do not uniformly
  consume one admitted wall, and existing walls are not fully reconciled. WSL's memory/CPU wall belongs to
  the shared utility VM, not one distro. Messages such as “launch the budget-sized VM” or “re-applying the
  cordon” can therefore report work that did not apply/reconcile the authoritative limit. Replacement:
  pure provider-capability admission yields one exact `ProviderWallSpec`/`EffectiveBudget`, and a
  constructive `BudgetPartition` proves every positive slice plus overhead is within it before effects.
  A journaled same-spec `ProviderWallReservation` authorizes the initial create/apply adapter, which mints
  `ProviderWallAuthority ... wallEpoch fence` only after authoritative observation; later
  builders/runtime mutations require it plus the exact partition projection. WSL's same-spec reservation
  retains the exclusive pre-call lock/CAS across initial apply; observed completion consumes it and
  jointly returns the epoch-indexed global-state lease with the authority, and
  refuses conflicting owners; no-op probes verify the existing applied wall. Structured outcomes
  distinguish applied, unchanged, conflict, unsupported, unknown/recovery-required, and failure, and
  messages derive from those outcomes. The duplicate config authority and workload-set defects are
  separate entries above. Owning phases: Phase 9 Sprint 9.10 and Phase 11 Sprint 11.10.
- **Shared boolean `InitArgs` write policy and role widening**
  (`core/hostbootstrap-core/src/HostBootstrap/Config/Class.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
  `demo/src/HostBootstrapDemo/Config.hs`) — independent `force`/`ifMissing` booleans represent the
  contradictory combination and the shared request admits role/command combinations that later gates
  must reject. Current writers also use check-then-write/truncating publication, so another process can
  win between observation and write; a crash after replacement but before acknowledgment has no typed
  outcome. Replacement: opaque writer-specific request types with one `OverwritePolicy`; project init
  selects `RefuseExisting`, `ReplaceExisting` (`--force`), or `KeepExisting` (`--if-missing`) and rejects
  both flags, while service/test init expose only `RefuseExisting`. Every policy writes and flushes an
  invocation-indexed same-directory temporary; refuse/keep use atomic no-replace installation and
  replace uses atomic replacement, followed by parent-directory flush (or the Windows durability
  equivalent). Missing atomic primitives yield `Unsupported`, never a partially visible destination.
  Retry classifies/cleans only its verified orphan temp. The writer returns a closed `WriteOutcome`
  including `PublicationUnknown`; an equal observed target may be `ObservedEquivalent` but never proves
  ownership, and retries never append/truncate in place. Owning phase: Phase 17 Sprint 17.4, with
  command-authority construction in Phase 15 Sprint 15.9.
- **`Capability.DurableStore` required only by a late Web-handler reread and still self-asserted**
  (`core/hostbootstrap-core/src/HostBootstrap/Context.hs`,
  `core/hostbootstrap-core/src/HostBootstrap/Command.hs`,
  `demo/src/HostBootstrapDemo/Web/Server.hs`,
  `demo/src/HostBootstrapDemo/Accelerator/Daemon.hs`,
  granted by `capabilitiesForKind` for `ClusterService` and `Daemon`, reflected into the golden
  `core/hostbootstrap-core/test/golden/service_schema_consumer.txt` and
  `core/hostbootstrap-core/dhall/example.dhall`) — the host-root share/alias and nested carry have
  landed. Initial `service run` dispatch and the accelerator handler pass no required capability; the
  Web handler alone reopens the sibling config after selection and asks `validateContext` for
  `[DurableStore]`. The check is therefore variant-specific, late, vulnerable to the split snapshot,
  and based on an editable declaration rather than verified authority. Replacement: after Phase 5
  Sprint 5.6's live durability proof, derive the exact durable requirement from the selected service's
  authorized effect row, require opaque durable-placement authority before dispatch/mutation, and refuse
  an unverified declaration. The proof is a handoff prerequisite; the code change is owned by Phase 15
  Sprint 15.9 (opaque gate), Phase 18 Sprint 18.6 (selected-service/effect proof), and Phase 19 Sprint
  19.8 (closed program/registry).
The seven 2026-07-21-reopening cleanup entries (the ad-hoc `set -eu` alias, the triplicated alias state
machine, the stderr-folding `die` collapse, the ungated in-guest steps, the `Text` memory/storage quantities,
the unbounded `Natural` config fields, and the never-attached `Budget/fitsWithin` assert) **landed / were
reconciled and moved to Removed Surfaces** on 2026-07-23 (validated by the live Windows/WSL2 `test run all`
**`8/8`**). That removal does not close the separate Pending defect above: the replacement
`fitsBudget`/provider builders still do not consume one exact `EffectiveBudget` authority end to end.

The in-cluster-registry doctrine switch (Harbor → single-binary `registry:2`, phase-13 Sprint 13.16) was the
previous pending cleanup; it **closed 2026-07-05** on a live decoupled Windows/WSL2 `test run all` reporting
**`test report: 6/6 passed`** (`REALRUN_EXIT=0`) standing up `registry:2` and pushing the project image, so
its four Harbor surfaces **and** the removed `kind load registry:2` pre-load moved to **Removed Surfaces**
below.

The in-place child-config delivery correction (development_plan_standards § U, § X) landed in phase-15
Sprint 15.7 / phase-13 Sprint 13.15 (2026-07-02); its two former entries are in **Removed Surfaces** below.
The earlier generic-project-model correction (development_plan_standards § BB) landed in phase-19
(2026-06-23); its three former entries are in **Removed Surfaces** below.

## Retained Current Surfaces

These surfaces are intentionally present and are not cleanup obligations.

- **`hostbootstrap/prereqs.py`** — the Python host-prerequisite checks retained for the pre-binary
  bootstrapper. The fail-fast host minimums are the irreducible pre-binary subset (Linux: Ubuntu 24.04 +
  passwordless sudo — one floor for `build`/`doctor`/`run`, with `/dev/kvm` and the `linux-gpu` NVIDIA
  container runtime owned by the binary's `ensure incus` / `ensure cuda`; Apple: passwordless sudo +
  Xcode CLT + Homebrew; Windows: winget + Windows PowerShell), dispatched by substrate alone.
  `HostBootstrap.HostPrereqs` remains the typed
  Haskell mirror but is pending Phase 2.5 alignment with this same floor; richer runtime transitions live
  only in the `ensure` reconcilers.
- **Demo VM/provider chain-step IO** (`runVmEnsure` / `runVmUp` / `runVmBootstrap` in
  `demo/src/HostBootstrapDemo/Commands.hs`) — the IO that the dissolved `vm` /
  `incus` verbs used to expose is **retained as the metal chain's step actions** the core `project up`
  interprets. Only the verbs were removed (see **Removed Surfaces**), not the provider step IO. The
  former separate `ensureIncusProvider` remediation branch has now been deleted in favor of the core
  Incus capability transition recorded under **Removed Surfaces**.
- **Demo web behavior + bridge IO** (`serveWebWithConfig` / `writeBridge`) — the Web business behavior/entrypoint
  remains selected when `service run` starts, and `writeBridge` remains the bridge codegen the
  build-image chain step runs before the image build. The handler now receives exact assembled Web fields
  and does not reload sibling config. Its remaining raw-`IO` execution wrapper is **not** a retained
  target surface; it remains Pending replacement by the config-ID-bound, one-use
  `RoleParams`/`ServiceProgram` authority package above. Only the old `web` verb was removed.
- **`HostBootstrap.Wsl2.GlobalWall` and `.ConfigBytes`** — retained through the 2026-07-27 ownership
  restatement, and easy to mistake for cleanup work because their sibling `.Windows` adapter and the C
  shim are Pending deletion above. They are not. `GlobalWall` is the pure exact-origin/crash state
  machine, and `ConfigBytes` is the bounded byte-exact UTF-8/UTF-16 `.wslconfig` transformer with
  idempotence fixtures — both are portable, hold no platform assumption, and are consumed unchanged by
  the replacement backend. Only the native adapter beneath them is superseded.
- **`core/hostbootstrap-core/dhall/example.dhall`** — retained as a live project-config fixture decoded
  by `SchemaSpec` and guarded against renderer drift. `service schema` exposes the validated-codec
  project-local shape; `context schema` exposes the separate static-artifact registry. Literal
  surface-specific snapshots keep the project config out of both bare and consumer `context schema`
  expectations. This file remains an example value, not a hand-maintained type.

## Removed Surfaces

### The public role-lifecycle callback bag (removed 2026-07-30, Sprint 14.6)

`HostBootstrap.RoleLifecycle` no longer exports `RoleSpec`, its `roleAcquire` / `roleServe` /
`roleDrain` fields, or `runRole`. A caller could previously assemble any phase sequence it liked, receive
the acquired environment directly, and — because the driver was one `finally` — throw out of Serve while
still holding live resources. They must stay absent: the replacement is the opaque
`RolePlan`/`RoleCursor` engine reached only through a verified activation, a verified role-plan draft,
and a one-use lifecycle admission, whose per-resource callbacks never see a cursor, a receipt, or the
generation lease. `ForgeRoleCursor.hs` pins nine of those constructors as unreachable. The descriptive
`RolePhase` enum (including the historical `Load` label) and `rolePhases` are **retained** for reporting;
they carry no authority.

### The whole-project teardown hook (removed 2026-07-30, Sprint 16.6)

`HostBootstrap.CLI` no longer exports `setTeardown`, no longer carries a `psTeardown` field, and
`ProjectSpecError` no longer has `MissingTeardown` or `DuplicateTeardownAssignments`; the demo's
`demoTeardown` is gone. One `root -> cfg -> Bool -> IO ()` function stood for the reverse of the
**entire** project, with a `Bool` choosing stop-or-delete and the implementation re-deriving the
substrate and branching internally. Nothing tied it to the plan node that acquired anything, so a step
could acquire what the hook never released and the hook could release what no step acquired — neither
visible at construction. They must stay absent: the replacement is `HostBootstrap.Step.reversedBy`,
which attaches `HostConfig -> TeardownAction -> IO TeardownOutcome` to the acquiring node, plus
`Command.reverseProjection`, which drives `Teardown.teardownPlan` for the verb — so `project down`,
`project destroy`, and a failed `project up`'s unwind are three projections of one plan (§ W). The
verb-derived `TeardownAction` replaces the `Bool`, and outcomes are structured per operation key
(§ Y). `mkStepPlan` rejects a second reverse on one step and a reverse on a `PreserveOnReverse` step,
which no projection reaches. Owning phase: phase-16.

### The independently supplied per-frame lift-context resolver (removed 2026-07-30, Sprint 16.6)

`HostBootstrap.CLI` no longer exports `setFrameContext`, no longer carries a `psFrameContext` field, and
`ProjectSpecError` no longer has `MissingFrameContext` or `DuplicateFrameContextAssignments`;
`HostBootstrap.Chain.runChainFromFrame` no longer takes a `StepFrame -> LiftContext` argument, and the
demo's `demoFrameContext` is gone. A project previously assigned one resolver *beside* its chain, so the
frame the validated plan announced and the context the interpreter descended through were two
independently supplied values — visible by name in the demo, whose `context-init` step announced a child
config that a different value actually delivered. They must stay absent: the replacement is
`HostBootstrap.Step.descendsVia`, which attaches the boundary's `LiftContext` — provider dispatch and
the child config streamed on the handoff `stdin` — to the plan node that owns it, read back by
`frameDescent`. `mkStepPlan` requires exactly one descent per frame with a successor, none from the
innermost frame, and none on a post-handoff hook, so the pairing is validated rather than conventional
(§ W, § X). Owning phase: phase-16.

### Caller-assembled operation dependency observations (removed 2026-07-30, Sprint 16.6)

`HostBootstrap.Reconcile` no longer exports `DependencyObservation`, `dependencyObservation`, or
`withPreparedSingleDependencyOperation`, and `HostBootstrap.Readiness` no longer exports
`dependencyObservationFromReady`. `withPreparedOperation` previously took a caller-built
`[SomeDependencyObservation]`, so the caller chose which edges to present and could present an
observation taken arbitrarily earlier in the bring-up. They must stay absent: the replacement is the
plan-owned dependency-snapshot traversal (`withOperationPreconditions`), the sole producer of the sealed
`OperationPreconditionSet` the prepare now consumes, plus the explicitly-refusing
`zeroDependencyPreconditions` branch for descriptors that declare no edges (§ CC).
`ForgePreconditionSet.hs` pins the sealed set and the snapshot as unconstructible.

### Raw registry/store endpoint assembly (removed 2026-07-30, Sprint 13.20)

The demo no longer assembles registry or object-store addresses independently. `minioClusterEndpoint`,
`registryEndpoint`, and the registry chart's NodePort are projections of the one `demoRegistryPlan`, and
the `storage.redirect` stanza is rendered from that plan's delivery strategy. The previously hand-written
`storage` stanza carried **no** `redirect` key, which left Distribution's redirect-to-store default in
force; there is now no independent redirect flag to set or omit, because the boolean is output (§ GG).


These surfaces are not part of the current repository state. Reintroducing one is a regression unless
a plan update creates a new current owner for it.

- **The per-step sibling-config reload** (`HostBootstrap.Config.Schema.requireSiblingProjectConfig`, the
  public `withSiblingProjectConfigRoot` export, and the demo's reloading `demoConfigContext`) — every
  chain step independently reopened and re-decoded `<project>.dhall`, so one `project up` ran across as
  many separately-decoded configs as it had steps and a file replaced between two steps silently split
  the run. `requireSiblingProjectConfig` additionally had no consumer at all. Removed 2026-07-29; owner:
  Phase 15 Sprint 15.9. Replacement:
  `HostBootstrap.Config.Schema.withSiblingValidatedProjectConfigRoot` admits the sibling once and the
  chain builder closes every step over that one `ValidatedConfig` snapshot; the demo's
  `demoConfigContext` now gates the **injected** snapshot instead of reading the file. Regression:
  `CLISpec` "chain steps see the snapshot admitted at project up, not a replaced sibling".

- **The two parallel runtime-witness tables** (`HostBootstrap.Context.runtimeWitnessesForKind` plus the
  inline witness lists in `childDaemonContext` and `deriveLinuxGpuContainerContext`, and the
  witness-list parameter of `childContextWith`) — the generated set and the validated set were written
  twice and could drift, and validation honored whatever the decoded config declared, so an empty list
  verified nothing. Removed 2026-07-29; owner: Phase 15 Sprint 15.9. Replacement: the single closed
  `HostBootstrap.Context.placementFor`/`requiredWitnesses` relation, projected by the child-context
  constructors and re-derived for exact comparison by `validateContext` (see
  [binary_context_config](../documents/architecture/binary_context_config.md)).

- **`HostBootstrap.Harness.withSelfCreatedTestData` and the `.test_data.hostbootstrap-run-owner` lock
  directory** — the harness's cooperative ownership claim was a bare `createDirectory`. It bound a
  pathname, recorded no owner identity and no phase, and satisfied none of the four § EE clauses, so a
  crashed run left both `.test_data` and the lock directory behind and the next run refused with
  `test data ownership is already active` until an operator removed both by hand (reproduced on the
  native Linux GPU run, 2026-07-28). Removed 2026-07-29; owner: Phase 10 Sprint 10.9.
  Replacement: `HostBootstrap.Harness.Ownership.protectedRunOwnership` over
  `HostBootstrap.Lifecycle.Mode` — a protected, versioned mode/lease record plus a durable data-root
  origin recorded before the first write, swept and closed by `recoverAbandonedHarnessRuns`. The pure
  `selfCreatedTestDataRemoval` guard is retained and still decides the removal set.

- **Root-level ownership/host-collision analysis scratch files** (`DO_WE_NEED_C_CODE.md`,
  `HD2_GAMEGUARD_ISSUE.md`) — two ungoverned root documents that carried the analysis behind the
  2026-07-27 ownership restatement and the WSL2 wall-release defect. They had no metadata block, no
  canonical home, and ALL-CAPS names that
  [documentation_standards.md](../documents/documentation_standards.md) reserves for
  `README`/`AGENTS`/`CLAUDE`/`LICENSE`, so they were a parallel status authority by construction. Their
  durable content moved to [ownership_invariant](../documents/architecture/ownership_invariant.md)
  (the four clauses, the per-substrate realization, and why the platform-primitive rule was replaced),
  [wsl2](../documents/engineering/wsl2.md) § Wall release,
  [durable_windows_runs](../documents/engineering/durable_windows_runs.md) (a detached run keeps holding
  the wall), and [demo_runbook](../documents/operations/demo_runbook.md). Machine-specific measurements
  and the third-party application diagnosis were host findings, not repository contracts, and were
  deliberately not carried. Removed 2026-07-27; owner: Phase 9 Sprint 9.11.
- **Unsized shared Colima default-profile reconciler** — Sprint 5.8 removed `colima` from the
  config-free `allReconcilers` set and replaced it with a prepared, plan-bound direct-Apple adapter.
  The adapter derives a validated project profile, consumes Phase 9's exact wall/partition/reservation,
  observes JSONL state, refuses incompatible same-name state, disables global context activation, and
  routes Docker through `colima-<project>`. Pure tests cover exact argv, identity separation, conflicts,
  and observation parsing; a disposable Apple profile verified exact 2 CPU / 4 GiB / 20 GiB state,
  named-context Docker, idempotent restart, preserved active context, and exact cleanup. Conditional
  generation-safe lifecycle cleanup remains the separate Sprint 5.7 obligation. Removed 2026-07-26;
  owner: Phase 5 Sprint 5.8.
- **Parallel provider dispatch, dead provider classifiers/builders, and demo-local Incus
  remediation** — Sprint 11.10 deleted the public `HostBootstrap.HostTarget` module and its reboot loop;
  removed unconsumed Incus/WSL readiness classifiers, the unused Incus restart builder, and
  `wslImportArgs`; retained `wslInstallArgs` as the sole production/tested registration route; and made
  `SubstrateProvider`/`Lift` the single dispatch fold. Core Incus now owns Linux daemon initialization,
  permission, QEMU/OVMF, bridge forwarding, and image-server egress remediation behind a total status
  table whose ready branch alone mints `IncusProviderCapability`, so the demo-local
  `ensureIncusProvider` branch was deleted. Strong guest-alias and global-WSL ownership remain separate
  Pending Sprint 11.10 obligations. Removed 2026-07-26; owner: Phase 11 Sprint 11.10.
- **Exposed `HostBootstrap.Readiness.Internal`, forgeable phantom readiness, and raw polling
  constructors** — Sprint 9.10 removed the exposed internal module and `MkReady`, made `Probe`, `Ready`,
  `Micros`, and `PollPolicy` opaque, validated bounded polling, and bound backend probes to closed
  planned-resource families plus positive generation/phase/observation versions. Public tests now drive
  the real transition and compile-fail fixtures protect constructor opacity. `ObservedReady` remains
  only as named non-authorizing compatibility evidence; live effect migration is tracked by the
  lifecycle entries still Pending above. Removed 2026-07-25; owner: Phase 9 Sprint 9.10.
- **Duplicate `BinaryContext.resourceEnvelope` and public demo scalar/resource construction
  bypasses** — Sprint 9.10 removed the context budget field so `ProjectConfig.resources` is the sole
  editable budget and child projection preserves the already-refined project value. `Resources`,
  `Quantity`, `HaReplicas`, `Port`, and `TimeoutSeconds` constructors are private, total smart
  constructors replace them, and `Num`/`IsString` bypasses are gone. Exact whole-byte parsing and
  provider admission reject inexact ceilings instead of rounding them upward. Per-frame slice
  consumption remains separately Pending above. Removed 2026-07-25; owner: Phase 9 Sprint 9.10.
- **Non-threaded demo test component** — `hostbootstrap-demo-test` now carries
  `-threaded -rtsopts "-with-rtsopts=-N"`, matching the executable because its unchanged
  `WebServerSpec` starts Warp/WebSocket listeners. A test reads the exact Cabal component stanza and
  fails if that runtime contract is removed. The canonical demo workspace gate most recently passed all
  104 demo and 397 embedded core tests under `-Werror` on 2026-07-25. Owner: Phase 13 Sprint 13.19.
- **Unconsumed parallel `RunModel` representations** — `HostBootstrap.Harness` formerly exported
  `RunModel`/`RunModelKey`/`selectRunModel` and tested the selector, while `Core.dhall` independently
  exported the same four alternatives; no production path consumed either representation to drive
  `project up`. The audit also found definition/test-only `oneShotSeams`, `defaultSeams`, `sliceBudget`,
  `guardTestDelete`, `testCaseProfile`, and `oneShotRunArgs`. Sprint 10.10 deleted the Haskell
  selector/key/topology surface, the Dhall union and codec, and every audited helper because repository
  search found no typed lifecycle-plan consumer. The four names remain only as derived behavior
  taxonomy. Removed 2026-07-25; owner: Phase 10 Sprint 10.10.
- **Dead `TestConfig.testSuites`, parallel case-id list, and stringly/possibly-empty variant
  projection** — Sprint 19.6 removed the decoded suite list from demo and fixture schemas and made `all`
  only a typed parser selector. Opaque validated `CaseId`/`VariantId`, pure `VariantDraft`, and the total
  `TestMatrix` constructor now reject empty/duplicate/missing/unknown/ambiguous/orphan relations before
  mutation. `TestCfg` projects `tcfg` plus the executable registry into that matrix. Sprint 19.7 later
  replaced the historical `psTestConfig` callback with scope-indexed `psAssemble`.
  Matrix/source regressions and the canonical demo workspace gate passed 382 core plus 101 demo tests
  under `-Werror` on 2026-07-25. The demo's still-hard-coded concrete messages remain separately tracked
  above for Phase 20 Sprint 20.5. Owner: Phase 19 Sprint 19.6.
- **Unscoped secrets, raw context update, unscoped project codec, and parallel config builders** —
  Sprint 19.7 removed the unscoped `SecretRef` union, `cfgWithContext`, `psInit`, and `psTestConfig`.
  `SecretRef scope` now requires exact `HarnessConfigAuthority projectId runId` for fixture plaintext;
  the Production schema has no plaintext alternative. `ProjectCfg projectId cfg` installs mapped
  `ProjectCodec scope specDigest cfg` values, allowing a secrets-strict config to decode untrusted
  Production/Harness wire without exporting direct `FromDhall` for `cfg scope`. One restricted
  `psAssemble :: AssemblyRequest ... scope -> ConfigAssembly scope (cfg scope)` owns defaults for both
  scopes, and its interpreter permits only declared text reads. Secret-free and secrets-strict fixtures,
  runtime decode/verification tests, API drift assertions, and four compile-fail fixtures cover the
  boundary. Removed 2026-07-25; owner: Phase 19 Sprint 19.7.
- **Public invalid/lossy `ProjectSpec` and `Step` construction** — Sprint 19.8 hid raw constructors
  behind `ProjectSpecBuilder`, `finalizeProjectSpec`, and `mkStepPlan`. Additive fragments preserve
  declaration order; frame-context and teardown are checked single-assignment contributions; typed core
  and project identities cannot shadow one another; and validation rejects empty plans, duplicate
  identities, label conflicts, invalid post-handoff placement, and non-contiguous `A/B/A` frame returns.
  Every accepted step has an explicit reverse policy, namespaced operation key, and exact validated
  dependency prefix. Compile-fail fixtures cover raw construction, forged project identity, replacement,
  unfinished dispatch, and cross-finalization use; generated frame-sequence tests prove exact-order
  preservation or pre-effect rejection. Removed 2026-07-25; owner: Phase 19 Sprint 19.8.
- **String selector, split service snapshot, fallback role values, and full-record handler delivery** —
  Sprint 19.8 removed `psServiceVariant`/`withServiceConfig` and jointly finalizes the full project codec,
  typed service registry, and structural role codecs under one canonical `specDigest`. `service run`
  canonically verifies one sibling snapshot, selects exactly one typed definition, and mints an opaque
  validated request before invoking an action closed over only its role fields and safe
  `LocalContextView`; demo Web/Accelerator handlers no longer reopen config. Both role parameter records
  are mandatory and survive child projection without fallback literals. Full-config and role-wire
  schema families are separately named for Production and Harness, including structured empty registry
  results. The core and demo gates passed 397 and 104 tests respectively under `-Werror` on 2026-07-25.
  Raw handler `IO` and runtime placement/effect authority remain separately Pending above for Sprint
  18.6. Removed 2026-07-25; owner: Phase 19 Sprint 19.8.
- **Phase 6 thin-build/publication defects** — the importability-only maintainer parser, mismatched
  requested/native Docker architecture path, Python-only base preflight, unconditional Cabal-index
  refresh, absent explicit offline refusal, unchanged-binary recopy, ambiguous Cabal selection, and
  unconstrained Cabal-stem/package/executable identities were removed on 2026-07-25. The publisher now
  requires canonical checkout/Poetry authority, validates request/host/engine architecture, runs all
  Python/core/demo source gates, and orders native build → push → pull → compatibility validation. The
  bootstrapper validates one selected Cabal identity, passes Cabal `--offline` only
  after local-tool/index proof, refreshes only missing/stale indexes, and copies only changed bytes.
  `runHostBootstrapCLI` also rejects a declared project name that differs from the invoked executable
  identity before command dispatch. An outward-facing CPU/arm64 publication completed on 2026-07-25 at
  `docker.io/tuee22/hostbootstrap@sha256:303193124924bdd27c1e1d3bb66dd3254f83ffdcecd3d91aa4896e61645a02a6`;
  the digest identifies that historical build only. Sprint 12.4 replaced its synthetic offline
  validator with a real-demo compatibility smoke and rolling input selection. Demo-specific published
  pull remains a separate Pending item above. Owning phase: Phase 6 Sprint 6.7.
- **Duplicated cross-phase “current” status and suite-count authorities** — removed from
  `DEVELOPMENT_PLAN/00-overview.md` and `DEVELOPMENT_PLAN/system-components.md`; the phase table in
  `DEVELOPMENT_PLAN/README.md` is the sole cross-phase status source, while exact counts remain only as
  dated evidence in the owning sprint. Historical phase narratives may retain dated results but cannot
  present them as a repository-wide current count. Owning phase: Phase 21 Sprint 21.4; documentation
  reconciliation recorded 2026-07-24.
- **Pre-share, guest-only `.data` doctrine and stale resource-budget citations** — removed from current
  governed prose after the code created the host project-root `.data` and carried it through provider
  share/alias and nested mounts. `documents/architecture/durable_state.md` and the lifecycle contract now
  own the exact implemented transport plus the still-open write → destroy → up → read-back and exclusive
  ownership gates; resource-budget doctrine is not cited as durability authority. The residual hard-coded
  Production plan/root defect is a separate Pending code item above. Owning phase: Phase 21 Sprint 21.4;
  documentation reconciliation recorded 2026-07-24.
- **Freeze-only base-image `LABEL`/`ENTRYPOINT` integration mode** — the unrealized
  no-Cabal-dependency proposal has been removed from the governed consumer contract. The base carries no
  reusable project binary/entrypoint; supported consumers declare a Cabal dependency and call
  `runHostBootstrapCLI`. A freeze constrains the solver only. Reintroducing the proposal as a supported
  mode is a regression.
- **Container-only Cabal project and base-owned freeze imports** —
  `demo/docker/container.cabal.project`, `core/warm-deps/{core,daemon}.project`, generated
  `core.freeze`/`daemon.freeze`, the Dockerfile project swap, and `/opt/basecontainer/...` imports were
  removed. The demo now uses one host-compatible `demo/cabal.project` unchanged on the host and in the
  container. Owning phase: Phase 12 Sprint 12.4; rolling-policy correction recorded 2026-07-25.
- **Committed reproducible-base lock and synthetic offline/full-hit validator** —
  `docker/base-inputs.json`, `templates/cabal/`,
  `docker/base-validation.Dockerfile`, and `core/warm-deps/verify_store.py` were introduced for a
  short-lived doctrine and then removed. The replacement resolves current compatible inputs during each
  rolling build, treats the inherited Cabal store as opportunistic, permits online cache misses, and
  uses the real demo Dockerfile for post-publish compatibility smoke. The resulting digest identifies a
  publication but is not a replay or consumer-freeze contract. Owning phase: Phase 12 Sprint 12.4.
- **The demo-local compound `set -eu` durable-alias step** (`prepareVMDurableAlias` in
  `demo/src/HostBootstrapDemo/Commands.hs`, including the inline `test` / shell `if` / nested
  `readlink` / `ln -s` program) — removed after it raced the provider mount and collapsed the
  Windows/WSL2 gate to a bare `ExitFailure 1`. Replacement: `awaitDurableShareMounted` performs a
  retrying trivial mount probe and `mintDurableAlias` runs trivial fact probes before executing the pure
  alias plan. Owning phase: Phase 11 Sprint 11.9; validated 2026-07-23 by the live Windows/WSL2
  `test run all` `8/8`.
- **Triplicated durable-alias state logic** (the shell branches in `prepareVMDurableAlias` and the separate
  `System.Directory` branches in `prepareLocalDurableAlias` / `removeLocalDurableAliasIfOwned`) — removed
  by `HostBootstrap.Substrate.Provider.AliasState`, `classifyAlias`, `planAliasEnsure`, and
  `planAliasRemove`; VM and direct lanes now feed facts into the same classifier/planners. Phase 11
  The later direct-host removal is tracked separately under Pending; this removed item records only the
  historical deduplication. Owning phase: Phase 11 Sprint 11.9.
- **The stderr-folding `die` / message-less `ExitFailure 1` lifecycle collapse** (`runOrDieStdin` folding
  captured output into `System.Exit.die`, `runSelfOrDie` rethrowing a plain exit failure, and
  `runSuiteSelection` rendering the resulting `ExitCode`) — removed by structured `LifecycleFailure`,
  stream-then-die subprocess handling, marker round-tripping, and `displayException` in the report card.
  Owning phase: Phase 10 Sprint 10.8; validated 2026-07-23 by the final Windows/WSL2 `8/8` and the
  intermediate `6/8` whose two failures named their causes.
- **Witness-free mutating in-guest step signatures** (`stageSource`, `streamVMConfig`, the
  `runVmBootstrap` install/build calls, and the durable-alias mutation) — removed from the named call
  graph by threading `Ready VMReady`, `Ready NetworkReady`, and `Ready DurableShareMounted` through the
  dependent functions. That historical phantom witness was later replaced by Sprint 9.10's opaque
  plan/resource-indexed foundation; these live call paths currently receive only its explicitly
  non-authorizing compatibility observation until their provider/interpreter migration. Owning phases:
  Phase 9 Sprints 9.8/9.10 and Phase 11 Sprint 11.9.
- **Raw `Text` memory/storage fields in the demo's decoded project/test resources**
  (`HostBootstrapDemo.Config.Resources.memory` / `.storage`) — removed by the transparent `Quantity`
  newtype, whose `FromDhall` validates units at decode through the canonical `parseQuantity`. Sprint 9.10
  then removed the generic binary-context envelope, hid resource/quantity constructors, and made the
  project value the lifecycle input. Per-frame slice consumption remains Pending above. Owning phase:
  Phase 9 Sprints 9.9/9.10.
- **Unbounded `Natural` lifecycle config fields** (`DeployConfig.haReplicas`,
  `WebServiceConfig.publicPort` / `.acceleratorPort`, and
  `AcceleratorServiceConfig.requestTimeoutSeconds`, plus an accepted-below-floor `Resources.cpu`) —
  narrowed at the Dhall boundary by decode-validating `HaReplicas`, `Port`, and `TimeoutSeconds` newtypes
  and the validating top-level `Resources` decoder. Sprint 9.10 hid the constructors, removed `Num`/
  `IsString` bypasses and the raw applied envelope, and retained transparent encoding so the Dhall schema
  shape remains stable. Owning phase: Phase 9 Sprints 9.9/9.10.
- **The generated-config `Budget/fitsWithin` assertion requirement** — removed/reconciled because no such
  assertion was ever attached: generated project configs carry Kubernetes quantity `Text` and no resolved
  pod set, so the assertion had no operands it could honestly compare. `Core.dhall`'s standalone
  `Budget/fitsWithin` function is retained; selected decode-validating newtypes form a partial decode
  ring. Haskell `fitsBudget` exists but is not called by bring-up with the real pod set; that wiring
  remains Pending above. Owning phase: Phase 9 Sprint 9.9.
- **CPU base flavor hard-coded for every demo image** — removed by substrate-aware
  `demoBaseImageFor`: Linux GPU selects the CUDA base, while Linux CPU/Apple/Windows select the appropriate
  CPU/native path. Remaining work is immutable pulled-digest consumption (Phase 13.18), not flavor
  selection.
- **VM-only project-container topology** — removed by the explicit direct Linux-GPU context and
  `host -> project container -> nvkind` plan. Remaining native live evidence stays in the accelerator
  sprints; the topology itself is present.
- **Web-only final demo surface** — removed by the Accelerator tab, CBOR WebSocket daemon path, and native
  worker metadata/result flow. Remaining work is the named native live matrix, not implementation of the
  UI/protocol surface.
- **The 8-pod Harbor in-cluster registry and its dual-arch mirror** — the `harbor/harbor` Helm chart + its
  8-pod stack (`deployHarborAction`, `helm upgrade --install harbor`, NodePort 30500), the dual-arch
  `ghcr.io/octohelm/harbor/*:v2.14.0` override set (`harborImageOverrides`, pinning the chart to `1.18.3`),
  the trivy scanner override, and `harborAdminPassword` / `waitHarborLogin` (all in
  `demo/src/HostBootstrapDemo/Commands.hs`) — removed by the phase-13 Sprint 13.16 switch to a single-binary
  `registry:2` (CNCF `distribution`), which is natively multi-arch (no mirror), anonymous/insecure in-cluster
  (no admin password / login-wait), and ships no scanner. Replacement: `deployRegistryAction` applies a single
  `registry:2` Deployment + NodePort-30500 Service with `kubectl`. Owning phase: phase-13 Sprint 13.16 (step
  kind also phase-16); validated 2026-07-05 by a live Windows/WSL2 `test run all` **`6/6`** (`deploy-registry:
  in-cluster registry rollout complete`).
- **The `kind load docker-image registry:2` pre-load** (the `docker pull registryImage` + `runOrDie cfg Kind
  ["load", "docker-image", registryImage, …]` in `deployRegistryAction`) — removed 2026-07-05 because
  `kind load docker-image` (a `docker save` + `ctr import --all-platforms`) cannot import a **multi-arch**
  image (it fails `content digest … not found`), and `registry:2` publishes a multi-arch manifest.
  Replacement: the registry pod pulls `registry:2` itself (`imagePullPolicy: IfNotPresent`), so containerd on
  the node selects the node platform; the demo's own single-arch project image is still delivered locally by
  `push-image`'s `kind load`. Reintroducing the `kind load` of a multi-arch image is a regression. Owning
  phase: phase-13 Sprint 13.16; validated 2026-07-05 by the same `6/6` run (`push-image: kind-loaded … and
  pushed localhost:30500/…`).
- **Build-then-copy VM child config** (`writeAndCopyVMConfig` writing the host-side
  `demo/.build/hostbootstrap-demo.vm.dhall`, and `copyFileToDemoVM`, in
  `demo/src/HostBootstrapDemo/Commands.hs`) — removed 2026-07-02 by the in-place child-config delivery
  landing (development_plan_standards § U, § X). Replacement: `streamVMConfig` renders the
  context-adjusted full VM projection and streams it over the VM shell's `stdin` (via
  `runInDemoVMStdin`), where the in-VM binary
  writes its own sibling `<project>.dhall`; no host-side `.vm.dhall` is written. `copyFileToDemoVM` is
  deleted (`stageSource` uses `stageFileEffects` directly — **retained**). Owning phase: phase-13
  Sprint 13.15, phase-15 Sprint 15.7; validated 2026-07-02 by `cabal test all` (280) and a live
  Windows/WSL2 `test run all` `6/6` (the `streamed parent-derived VM config …` marker; no `.vm.dhall`
  produced).
- **Build-then-mount container child config** (`mintContainerConfig` + `vmRuntimeContainerConfigPath`
  writing `hostbootstrap-demo.runtime-container.dhall`, and the config `Mount` in `demoDeployImage`
  bind-mounting it over `/usr/local/bin/hostbootstrap-demo.dhall`, in
  `demo/src/HostBootstrapDemo/Commands.hs`) — removed 2026-07-02. Replacement: `containerConfigPayload`
  renders the context-adjusted full projection, folded into `demoDeployImage`'s `clConfigDelivery` and
  streamed on the container handoff `stdin` (core `HostBootstrap.Lift.ConfigDelivery` + the `HostBootstrap.Chain`
  `liftStdin`/`liftSubcommandWithStdin` handoff), with an entrypoint wrapper
  (`sh -c 'cat > <sibling> && exec <pb> project up'`) writing the sibling before dispatch; the docker-socket
  and `/run/hostbootstrap` witness mounts are **retained**. `mintContainerConfig` is now
  `contextInitAnnounce` (a frame anchor keeping `vm-orchestrator-1` a real frame). Owning phase: phase-13
  Sprint 13.15, phase-15 Sprint 15.7; validated 2026-07-02 by `cabal test all` (280, incl. `LiftSpec`
  config-delivery cases asserting the projection is absent from `argv`) and a live Windows/WSL2
  `test run all` `6/6` (no `-v …hostbootstrap-demo.dhall` on the container `docker run`).

- **The hand-branched `DemoVMProvider` sum and its per-substrate lifecycle branches**
  (`data DemoVMProvider = AppleLimaVM | LinuxIncusVM | WindowsWsl2VM`, `demoVMProvider`, `demoVMName`, and
  the `case provider of` arms in `runVmUp` / `demoTeardown` / `stageSource` / `copyFileToDemoVM` /
  `runInDemoVMStdin` plus the duplicate substrate guard in `demoVMFrameContext`, all in
  `demo/src/HostBootstrapDemo/Commands.hs`; and the `limaInstanceExists` / `incusInstanceExists` /
  `wsl2DistroExists` / `waitVMAgent` / `waitLimaVM` / `waitWsl2VM` helpers) — removed when the per-substrate
  VM lifecycle was unified behind one pure lift. Replacement: `HostBootstrap.Substrate.Provider`
  (`SubstrateProvider`, `selectSubstrateProvider`, the `HostEffect` launch list, and the generic demo
  interpreters `demoProvider` / `substrateExists` / `substrateWait` / `runEffects`). The chain-step IO
  (`runVmUp` etc.) is **retained** (see **Retained Current Surfaces**); only the hand-branched dispatch was
  removed. Owning phase: phase-9, sprint 9.7; validated 2026-06-30 by `cabal test all` (274 tests, incl.
  `ProviderSpec` byte-for-byte Lima/Incus equivalence) and the demo binary build.
- **The volatile Windows memory-capacity predicate** (`WindowsAvailableMemory` `CapacityReadSource`
  reading `Win32_OperatingSystem.FreePhysicalMemory` in
  `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`) — removed because momentary free RAM let
  the preflight pass on transient post-reboot memory and an undersized host reach the build. Replacement:
  `WindowsTotalMemory` reading stable `Win32_ComputerSystem.TotalPhysicalMemory` (mirroring Apple
  `hw.memsize`). Owning phase: phase-9, sprint 9.7; validated 2026-06-30 by `cabal test all` (`CordonSpec`).
- **The `vhdx-size` line in the WSL2 `.wslconfig` body** (the `"vhdx-size=…GB"` element formerly emitted by
  `wsl2SizingArgs` in `Cordon.hs`) — removed because `.wslconfig` `[wsl2]` has no `vhdx-size` key; the
  per-distro VHDX cap is the `wsl --install --vhd-size` flag. Replacement: the `[wsl2]` body now emits
  `processors`/`memory`/`swap` (swap for OOM headroom) and the storage cap rides the install argv. Owning
  phase: phase-9, sprint 9.7; validated 2026-06-30 by `cabal test all` (`CordonSpec`).
- **The `ensure-tart` reconciler and `HostBootstrap.Ensure.Tart` module** (`core/hostbootstrap-core/src/HostBootstrap/Ensure/Tart.hs`; the `Tart` import + `allReconcilers` entry in `Command.hs`; the `Tart` constructor + `toolCommandName Tart = "tart"` in `HostTool.hs`; the exposed-module in `hostbootstrap-core.cabal`; the import + reconciler-name + `appliesTo` + `installSteps` cases in `test/EnsureSpec.hs`; the `Tart` entry in `test/HostToolSpec.hs`) — removed when Windows joined as the third metal substrate and the headless host-build pattern replaced Tart's build-VM shape. Tart was core-only and latent. Replacement: the `ensure-cudawin` reconciler. Owning phase: phase-3, sprint 3.5; validated 2026-06-26 by `cabal build all` and `cabal test all`.
- **Composition pattern #7 as a build-only VM (the `ensure tart` shape)** — removed by the phase-3
  re-anchoring. Replacement: pattern #7 "Headless host build for platform-locked artifacts" — build on the
  bare host, stage into the cluster through the project chain, never run the workload in a VM — with
  CUDA-on-Windows (`ensure-cudawin`) as its first worked instance. Owning phase: phase-3, sprint 3.5;
  validated 2026-06-26 by `cabal build all` and `cabal test all`.
- **Core-owned config defaults** (`defaultResources` / `defaultDeployConfig` / `defaultProjectConfig` in
  `core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`, plus the `fromMaybe (cpu
  defaultResources)` / `value (memory defaultResources)` / `value (storage defaultResources)` flag
  defaults in `HostBootstrap.Command.initAction`) — removed 2026-06-23 by the phase-19 genericization.
  `hostbootstrap-core` owns **no** default config values. Sprint 19.1 initially moved defaults to
  project-owned callbacks; Sprint 19.7 subsequently replaced the project-config callbacks with the
  single scope-aware restricted `psAssemble`. `psTestInit` remains separate because it constructs
  `tcfg`. Demo service-projection fallbacks remain a separate Pending defect above. Owning phase:
  phase-19, sprints 19.1 and 19.7.
- **The fixed universal `ProjectConfig` / `Resources` / `DeployConfig` / `TestConfig` types as core types**
  (`core/hostbootstrap-core/src/HostBootstrap/Config/Schema.hs`) — removed 2026-06-23 by the phase-19
  genericization. Core owns no config type. Sprint 19.7 further parameterized the boundary as
  `ProjectSpec projectId cfg tcfg`, with `cfg :: Type -> Type`, and removed the temporary
  `cfgWithContext` compatibility method. The universal types became the demo's concrete
  scope-indexed `cfg`/`tcfg`.
  **Rejected alternative (recorded as rejected, not a cleanup obligation):** a core-owned generic
  `extra : Map Text Text` slot on a universal config type — rejected because core owns no project-specific
  field and no generic extra slot. Owning phase: phase-19, sprint 19.2.
- **The `test init` reads-existing-config / `test run` reuses-existing-config flow** (`runTestInit` in
  `HostBootstrap.Command` copying `resources cfg` from a pre-existing `<project>.dhall`; the demo's
  `demoTestUp` driving `project up` against that pre-existing config) — removed 2026-06-23 by the phase-19
  genericization. The initial replacement used the project-owned `psTestConfig`; Sprint 19.7 then
  replaced it with the Harness request of the single scope-aware restricted `psAssemble`. The harness
  never shells the CLI, runs the real `project up`, asserts, and runs `project destroy`. The later
  path/byte-based claim that this proves safe deletion of generated config
  and `.test_data` is superseded by Phase 10.9: only § EE ownership clauses plus verified
  identity-bearing ownership receipts authorize deletion; changed bytes remain quarantined with
  ownership retained.
  `test init` requires no pre-existing `<project>.dhall`, the fail-fast existence precondition checks
  `siblingProjectConfigPath`, and a suite may declare more than one config variant. Owning phase: phase-19,
  sprint 19.3.
- **Flat `config init` top-level verb** — config generation is now `project init` (the shared init parser
  is reused). The Python bootstrapper does **not** trigger it: it builds and invokes the host-native
  binary (POSIX `exec`; Windows child subprocess), and the binary fails fast when no sibling
  `<project>.dhall` exists (the former post-build auto-init trigger is removed — see **The Python config
  auto-init trigger** below). Owning phase: phase-4.
- **Flat `cluster up|down|delete|status` top-level verb** — superseded by `project up` / `project down` /
  `project destroy`; the `clusterDown` / `clusterDelete` reconcilers remain, invoked by the lifecycle
  command. Owning phase: phase-4.
- **`context create vm|container|service` mutation verb** — removed in favor of internal `project up`
  child-projection/delivery work. Current effects live in the composite VM bootstrap and in the descent
  the plan's own `context-init` node declares, carried by the lift; Sprint 16.6 owns the remaining
  unification in one plan operation. The `context` command is now read-only introspection
  (`inspect` / `show` / `schema` / `render` / `path`), absorbing the former
  `config show|schema|render` inspection surfaces. Owning phase: phase-4.
- **Standalone `ensure <tool>` top-level command** — removed by the
  [Phase 21](phase-21-documentation-code-consistency-reconciliation.md) command-surface reconciliation.
  `ensure` is a library of probe-first reconciler primitives composed as `ensure-*` chain steps; typed
  receipt-preserving idempotent outcomes remain later lifecycle work. The fixed user-facing command
  surface is `project`, `test`, `service`, `context`, and `check-code`, with no hidden commands. Owning
  phase: phase-3.
- **Demo `deploy` / `harbor` / `role` verbs and the Op-based `HostBootstrapDemo.Chain`** — the demo has one
  canonical deploy: the contributed `demoChainFor :: Substrate -> ProjectConfig -> [Step]` function
  (`demo/src/HostBootstrapDemo/Commands.hs`) interpreted recursively by the core `project up`. The
  hand-written `demoDeployChain` / `renderPlan` / `runDeploy` module and the `deploy` (its interpreter),
  `harbor` (`runHarborInstall` / `runHarborPush`), and `role` (`HostBootstrapDemo.Role`) verbs were deleted
  on 2026-06-18; the later `deploy-harbor` chain step was itself replaced by the current
  `deploy-registry` step, while `push-image` remains a chain step. The demo does not maintain a second
  standalone deploy path beside the core chain interpreter. Owning phases: phase-13 and phase-16.
- **Dockerfile-baked `vm-project-container` runtime authority** — Dockerfiles now bake
  `image-build-container` authority only. Runtime workflows receive parent-generated configs streamed
  in-place for the exact frame they run in (§ X).
- **Flat binary context without execution topology witness fields** — `HostBootstrap.Context` now
  encodes provider-backed frames, current-frame identity, parent links, and local runtime-witness values
  inside `<project>.dhall`. Total graph validation and a non-omissible required-witness relation remain
  Pending above.
- **Unmarked direct host/container fallback for generated VM-scoped kind workflows** — generated
  VM-project-container configs declare a VM-orchestrator ancestor and local runtime witnesses; the
  explicit direct Linux-GPU shape carries its distinct marker, and local smokes use a test-harness
  context. Current validation follows only selected ancestry and supplied witnesses, so completeness
  remains Pending above.
- **Independent Dhall encoder/decoder schema claims, partially ungated `Core.dhall`, and the synthetic
  schema fixture** — removed by Phase 8 Sprint 8.7 on 2026-07-25. Opaque `CodecWitness a` owns
  schema/decode/render, `ConfigArtifact` construction requires it, every current `Core.dhall` type export
  is judgmentally equality-owned, and literal bare/consumer `context schema` plus consumer
  `service schema` snapshots replace the synthetic `config_schema.dhall`.
- **`core/hostbootstrap-core/dhall/Type.dhall`** — deleted by
  [Phase 21](phase-21-documentation-code-consistency-reconciliation.md). The validated-codec
  project-local shape exposed by `service schema` and the separate registry exposed by `context schema`
  replace a hand-maintained type file. Owning phase: phase-8.
- **Python Dhall provisioning** (`hostbootstrap/dhall_tool.py`, `hostbootstrap/spec.py`, and
  `hostbootstrap/dhall/package.dhall`) — Python discovers the Cabal file/executable build metadata and
  never reads or writes Dhall. The current parallel-name defect is tracked separately under Pending.
- **Python host-context writer in `hostbootstrap/bootstrap.py`** — the built project binary owns
  sibling `<project>.dhall` initialization and child projection.
- **The Python config auto-init trigger** (the post-build `project init --if-missing` in
  `hostbootstrap/bootstrap.py`) — the bootstrapper built the binary then triggered its idempotent config
  init so a default `<project>.dhall` always existed. Removed (2026-06-23, phase-19 sprint 19.5): Python
  builds and invokes the host-native binary (POSIX `exec`; Windows child subprocess); it does not
  initialize or trigger config creation, and a
  normal command fails fast (exit 1) when no sibling `<project>.dhall` exists — the config is created by an
  explicit `project init` or generated by the test harness through `psAssemble`. Owning phase: phase-19,
  sprints 19.5 and 19.7.
- **`StaticBase` compatibility API in `HostBootstrap.Config.Schema`** (`StaticBase`,
  `decodeStaticBaseText`, `decodeStaticBaseFile`, `renderStaticBase`) — the core replacement is generic:
  `ProjectCfg projectId cfg`, generic sibling-config IO/validation in `HostBootstrap.Config.Schema`,
  `ProjectSpec projectId cfg tcfg`, explicit `project init`, and the sibling `<project>.dhall` command
  gate. Concrete
  `ProjectConfig` / `TestConfig` records and their decode/render helpers live in
  `demo/src/HostBootstrapDemo/Config.hs`, not in core.
- **`project-binary-context-config.dhall` artifact name** — host, VM, container, daemon, and service
  copies use the sibling `<project>.dhall` filename rule, with role/capability context inside the file.
- **`--create-container-config` Dockerfile shortcut** — container images create image-build config through
  `<project> project init --role image-build-container --output /usr/local/bin/<project>.dhall`; runtime
  contexts are parent-generated and streamed in-place at launch (§ X), except the Kubernetes service pod,
  whose config arrives as a ConfigMap override.
- **`demo/hostbootstrap.dhall`** — the demo uses `hostbootstrap-demo.dhall` at each execution context.
- **`core/hostbootstrap-core/example/Main.hs` and the `hostbootstrap-example` executable** — the
  worked consumer is `demo/`.
- **Pre-binary container orchestration in `hostbootstrap/bootstrap.py`** — Python asserts host
  minimums, ensures the host build toolchain, builds the project binary host-native, and invokes the
  binary using the platform-specific handoff above; it does **not** initialize config (the binary fails
  fast when no sibling `<project>.dhall`
  exists — see **The Python config auto-init trigger** above). Docker ensure, container builds, VM
  sizing, and cluster operations belong to the project binary.
- **Legacy pipx `#egg=hostbootstrap` install/update specs** — downstream install and update guidance
  uses the direct VCS requirement form
  `hostbootstrap @ git+https://github.com/Tuee22/hostbootstrap.git@main`. Reintroducing `#egg`
  fragments is a regression unless a future packaging plan makes them necessary again.
- **`pipx upgrade hostbootstrap` as the canonical update path** — the project currently has no
  versioned Python release channel, so self-update is a forced pipx reinstall from the canonical VCS
  source, not a version-based upgrade.
- **Automatic latest-version gating in normal Python commands** — `doctor`, `build`, `run`, and `base`
  do not auto-update, auto-check GitHub freshness, or fail merely because a newer wrapper commit exists.
  The update path is explicit.
- **Duplicate Python budget interpretation** (`_gib` and Python-side Colima sizing) — the canonical
  quantity parser and VM/container arg builders live in `HostBootstrap.Cluster.Cordon`.
- **`hostbootstrap/models/*`** (`container.py`, `host_binary.py`, `host_daemon.py`, `__init__.py`) —
  every project has one substrate-driven build/run path through `hostbootstrap/bootstrap.py`.
- **Three-execution-model Dhall schema** (`Container`/`HostBinary`/`HostDaemon`, `Cluster`/`NoCluster`,
  `Mount`, and target-selection fields) — each project binary owns its concrete `cfg` schema; core is
  generic over `ProjectCfg cfg`.
- **Model dataclasses in `hostbootstrap/spec.py`** (`Model`, `Lifecycle`, `Mount`,
  `ContainerArtifact`, `ContainerModel`, `HostBinaryModel`, `HostDaemonModel`, `TargetSpec`,
  `ResolvedTarget`, `target_for`) — no model dispatch exists in the Python bootstrapper.
- **`--force-target` model dispatch in `hostbootstrap/cli.py`** — the Python CLI surface is
  `doctor` / `build` / `run` / `base`.
- **Python model/Dhall tests and fixtures** (`python/tests/test_models.py`,
  `python/tests/test_spec_dhall.py`, `python/tests/fixtures/dhall/*`) — the Python test suite covers
  the thin bootstrapper surface.
- **Hollow demo harness seams** (`demoSeams` without per-case assertions) — the demo uses real
  per-case seams (`assertClusterLive`, `assertWebBundle`, `assertE2E`) behind the standardized harness.
- **Demo `vm test` subcommand** — the inherited core `test` verb runs the project matrix through the
  `TestSuite` hook.
- **Non-substrate-aware off-Linux capacity fallbacks in
  `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`** — `readCores`'s unconditional
  single-core default and `readAvailableMemory`'s unconditional petabyte default when `/proc` was absent
  are removed. Replacement: substrate-aware `resolveHostCapacity` reads resolved `sysctl`
  `hw.ncpu` / `hw.memsize` on Apple silicon and retains `/proc/cpuinfo` plus `/proc/meminfo`
  `MemAvailable` on Linux.
- **The `GenerousStorage` (1 PB) capacity source in
  `core/hostbootstrap-core/src/HostBootstrap/Cluster/Cordon.hs`** — the unconditional petabyte free-storage
  reading for Apple/Linux (which made the storage preflight a no-op off Windows) is removed. Replacement:
  `PosixFreeStorage "/"` read via a real `df -P -k` (the new `Df` host tool + the pure
  `parseDfAvailableKBytes`), so the storage ring gates on real free disk on all three substrates. Owning
  phase: phase-9 (reopened 2026-07-05); validated by `cabal test all` (`CordonSpec` — the `df` parser and the
  Apple/Linux `PosixFreeStorage` read plan).
- **The full-file `WriteHostFile` clobber of the global `.wslconfig`** (the WSL2 launch effect in
  `HostBootstrap.Substrate.Provider` and its `writeHostFileWithBackup` interpreter overwriting the whole
  `.wslconfig`) — removed for the WSL2 cordon. Its first replacement, the `MergeWslConfig` effect over
  pure `HostBootstrap.Wsl2.mergeWslConfig`, stopped the clobber but still inferred ownership from a
  backup pathname; it is itself removed by the entry below. Owning phase: phase-9 (reopened 2026-07-05).
- **The backup-existence global WSL wall: `WriteHostFile`, `MergeWslConfig`, `RestoreHostFile`,
  `HostBootstrap.Wsl2.mergeWslConfig`, `VMHandles.vmhWslConfigPath`, and the demo's
  `.hostbootstrap-demo.bak` interpreter** (`writeHostFileWithBackup`, `mergeWslConfigWithBackup`,
  `backupHostFileOnce`, `restoreHostFile`) — the production utility-VM wall merged a global user file
  after checking only a cooperative backup pathname, which records no *absent* original, admits no
  identity evidence, and lets a second run adopt the first run's state. Replacement: the pathname-free
  `ApplyGlobalWslWall`/`ReleaseGlobalWslWall` effects interpreted by
  `HostBootstrap.Wsl2.GlobalWall.Windows` over the portable host-wall backend, which journals an exact
  origin record (bytes **or** absence) before its first mutation and conditions release on re-observing
  the same kernel identity. `spStop`/`spDestroy` now take the same `ResourceEnvelope` as `spLaunch`, so
  teardown releases exactly the wall bring-up applied. The byte-exact
  `HostBootstrap.Wsl2.GlobalWall.ConfigBytes` merge supersedes the line-oriented `String` merge.
  Removed 2026-07-28; owner: Phase 11 Sprint 11.10. Validated by `cabal test all` (core **520**,
  `ProviderSpec` wall-effect and release-body cases; demo **105**).
- **The native Windows wall C shim and its FFI surface** (`core/hostbootstrap-core/cbits/wsl_global_wall.c`,
  the `if os(windows)` `c-sources`/`extra-libraries: advapi32, ole32, shell32` block, the test-suite
  `-threaded` carve-out, and the seven `hb_wsl_*` wrapper `foreign import`s) — written against the
  superseded platform-primitive ownership rule. The removed surface is specifically the C shim and
  those wrapper imports. Replacement:
  `HostBootstrap.Wsl2.GlobalWall.Host` (the portable driver, record codec, and `HostWallBackend` seam),
  `HostBootstrap.Wsl2.GlobalWall.Posix` (`fcntl` exclusive entry, a journal file, `device:inode`
  identity), and a rewritten `HostBootstrap.Wsl2.GlobalWall.Windows` using public `Win32` APIs plus a
  narrow direct `kernel32` FFI where exact status is required. The replacement has no C source, Cabal
  `c-sources`, or private `Win32` dependency. `LockFileEx` is not affine to the acquiring OS thread,
  which is why the threaded-RTS carve-out could go. No `.c` remains in the repository. On non-Windows,
  `test/WslGlobalWallHostSpec.hs` runs the complete driver against the POSIX backend and a real kernel;
  on Windows, the current `test/WslGlobalWallWindowsSpec.hs` gates the production entrypoint and native
  identity/apply/restore/conflict behavior. Removed 2026-07-28; owner: Phase 11 Sprint 11.10. Focused
  native Windows evidence: 4/4 cases passed 2026-08-01.

## Rules

Per [development_plan_standards.md § I](development_plan_standards.md):

- If an obsolete or duplicate surface still exists, it must appear in the **Pending** section above.
  Each entry names its location, the reason for removal, and the owning phase or sprint.
- If a surface looks similar to a legacy cleanup item but is intentionally retained, it belongs in
  **Retained Current Surfaces**, not **Pending**.
- When cleanup lands, move the entry from **Pending** to **Removed Surfaces** in the same change.
- Empty `Pending` and `Removed Surfaces` sections are valid. The ledger exists as a stable home so
  cleanup obligations are never lost; absence of pending items reflects current reality, not an
  incomplete file.

## Entry format

When a future entry is added, use this shape:

```markdown
- `path/to/obsolete/file` — short reason for removal. Owning phase: phase-N.
```

For more complex entries:

```markdown
- **`path/to/obsolete/surface`** — reason for removal. Owning phase: phase-N, sprint X.Y.
  Replacement: `path/to/new/surface` (see `documents/...`).
```
