# Binary Context Configuration

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [python_haskell_boundary](python_haskell_boundary.md), [composition_methodology](composition_methodology.md), [dhall_topology](../engineering/dhall_topology.md), [Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md)

> **Purpose**: Define the "know your place" authority contract every project binary uses to reason
> explicitly about where it is running in a composed host/VM/container/cluster topology, and the
> read-only `context` command that introspects it.

## TL;DR

- The runtime config file is the executable's sibling `<project>.dhall`. It carries three things:
  **parameters** (the user-owned root settings), **context** (the binary's place in the topology), and
  **witness** (locally checkable facts that prove the process is in that place).
- The role lives inside the Dhall value, not in the filename. The binary has one default lookup rule.
- The target recursive `project up` interpreter has one durable authority owner: the root coordinator
  process. It opens one `ProtectedStore`, one global lease/snapshot/acquisition lineage, recursively builds
  a `RootedPlanCatalog`, and owns every per-frame journal transition. A child process is a long-lived,
  storeless `FrameExecutor`: it verifies its delivered `.dhall`, reconstructs the catalog-selected local
  `ProjectPlan`/`ExecutionNode`, exact-compares a root-signed prepared response, performs only the local
  effect, and returns a bounded observation for root settlement. The decoded context remains descriptive.
  The implemented pure `withCurrentFrame` admission still jointly generates opaque `CurrentFrame`,
  `ProjectFrame`, and `ValidatedContext` evidence. `ValidatedLifecycleContext` is the root coordinator's
  parent-plan admission evidence; it retains the coordinator's already-open store but is never sent to or
  reconstructed by a child.
  Rank-2 selection on `RootedPlanCatalog` carries the target plan/configuration/current-frame relation
  structurally without a second evidence type or store authority. The [authenticated handoff and child admission
  phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md) owns the closed v1
  wire vocabulary. Its Handoff facade now implements the abstract root-signed `AuthenticatedRootScope`
  capsule and installed-identity/key verifier, and the existing four-field Offer/Relay/Receiver path carries
  it as the first framed authentication value. The root Relay mints it, nested links copy the exact root-issued
  bytes, and Receiver verifies it before key, binding, challenge/grant, or payload semantics. The rooted
  binding, generic recovery-package carrier, closed lifecycle codecs, and bounded keyless carrier are
  implemented; the live root semantic service remains a target.
  The [recursive lifecycle command
  phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) consumes it for rooted traversal.
- The `.dhall` describes parameters and context, never the lift chain shape — the chain is code. The model
  lives in [composition_methodology](composition_methodology.md); this doc defers to it.
- The static authoring value remains `ProjectSpec cfg tcfg`, with no runtime scope or specification
  phantom. Scope finalization yields `FinalizedProjectSpec scope specDigest cfg`; admission then yields an
  opaque `ProjectPlan` whose forward order, topology, stable snapshot, resources, and dependency edges are
  current pure projections.
- `sourceRoot` is descriptive input. Lifecycle root admission resolves it once against the config-owned
  project home and yields opaque canonical-root authority without replacing the field in
  `BinaryContext`. The admitted plan now retains that root, and its typed resource and dependency-edge
  projections are implemented. Production dispatch retains or reconstructs that exact plan for rendering,
  persistence, root-Up entry interpretation, and current-frame reverse work; Harness dispatch admits its
  separately scoped exact plan and drives the same fixed entry/reverse boundaries inside generated-config
  ownership. The hidden entry producer, not either dispatcher, derives journal/cursor admission and the raw
  lower Chain inputs.
- `context` is a **read-only** introspection/visualization command, but its inputs differ by subcommand:
  `inspect` decodes the sibling `.dhall`, `show [FILE]` decodes the selected/default file, and
  `path`/`schema`/`render` use only static binary-owned information. Child context delivery is internal
  `project up` work; no `context` verb does it. The demo's current `context-init` step is only an
  announcement while composite bootstrap/handoff code performs the actual writes; later plan-aware
  consumer adoption makes those one operation.
- The accelerator daemon reuses this context model: in-cluster Linux daemons receive service/daemon
  configs, while Apple Silicon and Windows GPU host daemons read host-resident daemon configs and connect
  through the exact runtime-resolved loopback exposure.

## The Contract

The project binary is not a blind command receiver. It is the local effect interpreter for one segment of a
pure, typed global composition. When the rooted interpreter lifts `project up` across a boundary, the callee
receives enough authenticated, catalog-derived information to prove which frame and node it may execute, but
it receives no lifecycle store or global mutation authority. Current Production interprets only the exact
current-frame segment and fails closed at nested entry.

The canonical lookup path is:

```text
<directory containing executable>/<project>.dhall
```

| Context | Binary location | Config file location |
|---|---|---|
| Host binary | `./.build/<project>` | `./.build/<project>.dhall` |
| VM host-native binary | VM-local `./.build/<project>` or installed path | sibling `<project>.dhall` |
| Project container binary | `/usr/local/bin/<project>` | `/usr/local/bin/<project>.dhall` |
| Cluster service or daemon binary | container entrypoint path | sibling path mounted or materialized by the controller |
| Host daemon binary | `./.build/<project>` or installed host path | sibling daemon-role `<project>.dhall` |

There are no alternate automatic filenames such as `<project>.host.dhall`: a role-encoding name would
require the binary to choose a role before reading the file that declares its role. An explicit
`--config FILE` may exist for inspection and testing, but normal dispatch defaults to the single sibling
path.

## The .dhall: Parameters, Context, And Witness

The sibling `<project>.dhall` carries three layers in one typed value:

| Layer | Owner | Purpose |
|---|---|---|
| **Parameters** | the user (root) | the root settings the plan fragments are pure functions of — CPU, memory, storage, HA replicas, structural flags such as "skip VM, go straight to Docker" |
| **Context** | the parent lifecycle's child projection/delivery | this binary's place in the topology: identity, frames, current frame, capabilities, allowed command classes, and the current raw resource envelope; the target envelope is plan/frame-indexed |
| **Witness** | the same child projection/delivery | locally checkable facts (`runtimeWitnesses`) that let this binary prove it really is in the declared frame |

The `.dhall` never encodes the lift plan itself. The
[step algebra and project plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)
finalizes the static
`ProjectSpec cfg tcfg` as `FinalizedProjectSpec scope specDigest cfg`, admits its non-empty drafts as one
opaque `ProjectPlan`, and derives `forward`, `topology`, `renderSnapshot`, resource, and dependency-edge
projections from that value. Its pure `withCurrentFrame` boundary also joins descriptive context to the
plan and generates the matching opaque frame-evidence package. `ValidatedLifecycleContext` joins that package
to the exact canonical root, already-open protected store, and freshly checked runtime witnesses without
authorizing it. It is created and consumed only inside the root coordinator, for either the root or a nested
parent-plan frame; no child process receives it. Ordinary root Up reaches this join through the
Cabal-private `LifecycleEntry` producer. Public `HostBootstrap.Chain` remains the lower
foundation consuming the exact `ProjectPlan` and its non-empty `forward` projection together
with matching execute-phase `CommandAuthority` and `LifecycleCursor` evidence. Before I/O, it verifies
that the authority belongs to the supplied protected store and compares the cursor's retained store plus
decoded acquisition project/store/broker origin with that authority; it then compares the retained
frame/verb/phase terms before any durable transition. It derives the operation session's epoch and
identity from the authority and derives descent from the plan's `DerivedTopology`. Every protected Chain
entry also revalidates the exact acquisition source and current cursor row under the same exclusive entry
before its dependent journal/session/prepare/settle/close action, so an execute cursor advanced to
teardown cannot remain usable through a stale in-memory value.
Reconciliation's exact descriptor producer consumes that same plan and one matching `PlannedStep`,
retaining the plan/configuration/node/frame/operation projections and nominal scope/plan indices (see
[composition_methodology](composition_methodology.md)). Production dispatch consumes those exact
boundaries directly, and Harness dispatch uses them with the exact
`Harness projectId runId` plan retained by its generated-config bracket.
Structural variation (for example, skipping the VM frame to go straight to a Docker frame) is a parameter
flag on the **root** `.dhall`, so plan construction stays a pure function of root parameters rather than a second
representation living in config.

### Context Shape

| Field family | Purpose |
|---|---|
| Project identity | project name, binary name, and descriptive source root; canonical host-root authority is resolved separately at root admission |
| Execution topology | a list of provider-backed frames, their parent links, and the current frame id |
| Context kind | host orchestrator, VM orchestrator, VM project container, image-build container, cluster service, daemon, one-shot job, or test harness |
| Role name(s) | the roles this config requests/declares — a single `<project>.dhall` may declare **more than one** (e.g. project *and* service); the existing-frame gate checks descriptive classes/capabilities, while the exact `ProjectUp` gate consumes independently derived opaque authority evidence; recursive child integration remains separate |
| Runtime witnesses | locally checkable facts proving the process is in the declared frame: provider profile, mounted socket, env value, config hash, or executable path |
| Local capabilities | tools and services this context may use: Docker socket, kind network, Kubernetes API, durable store |
| Allowed command classes | which command families are valid in this context |
| Resource envelope | Current raw parent-inherited envelope; target exact budget slice/cordon for this frame |

Project-specific logic may extend the value with its own **Parameters-layer** fields, but it must never
make a child reach back to the parent's config or treat a missing config as implicit authority. The demo's
`message : Text` is exactly such a project-extended Parameters-layer field — a typed, mandatory field on
the demo's **own** config type (not a core slot, and in particular not a generic `extra : Map Text Text`)
that the `Web` service reads and renders. A context's relationship to the others lives in the
pure execution-topology frame graph (the compositional lifts), not implicitly in the command line; the
read-only `context` command renders that graph uniformly for **every** `<project>.dhall`, whatever roles it
declares.

A **multi-role** config (one `<project>.dhall` that declares both project and `service` role data) is
generated by adding roles to a primary role: `project init --role host-orchestrator
--also-role service` (the repeatable `--also-role ROLE`) unions each added role's command classes and
capabilities into the one context (`HostBootstrap.Context.addRole`). The primary context kind and topology
frame are unchanged.

`addRole` is a **validating smart constructor**, not a union: it returns
`Either BinaryContextError BinaryContext` and consults the closed `roleAdditionAllowed` relation. A
non-leaf primary cannot acquire service-run authority, and a role may not contribute a command class the
primary's placement does not already justify — so a `Daemon` or `ImageBuildContainer` primary cannot
become a project/lifecycle authority by naming an extra role. The one legal shape is leaf-to-leaf: a
service placement may also serve another service role. `--also-role` is operator input, so a refused
addition stops assembly rather than being dropped.

Two checks are layered on top, because `allowedCommandClasses` is a **declared** list and the bytes on
disk belong to the operator: `addRole` governs how a config is *generated*, not what a hand-edited one
may claim. `service run` performs its own primary-kind check and accepts only `ClusterService` or
`Daemon`, which catches a config carrying `ServiceCommand` without having gone through `addRole`. The
project lifecycle verbs consult the closed `placementAllowsCommand` relation, which re-derives the answer
from the validated topology graph rather than from the declared list: `project up` runs only from an
orchestration placement (`isOrchestrationPlacement` — a service, daemon, one-shot, or image-build leaf
hosts no chain), and `project down|destroy` additionally require the exact **root-kind/empty-parent**
pair — `isRootFrame` plus `HostOrchestratorPlacement`. A forged leaf config that lists
`ClusterLifecycleCommand` or `HostOrchestratorCommand` is therefore refused by its placement rather than
believed.

That root-only pair governs the **operator** entry to a teardown verb. The second entry the child-first
unwind needs is descent-initiated: a
descent-initiated `down|destroy` runs in a nested frame, where the root-only pair correctly refuses it,
and is admitted instead by verifying the recovery wire its parent minted for that exact edge. The two
entries are two types rather than one command class asked to mean both, and a lifecycle verb names no
command class as a source constant chosen per call site — which is why `project up`, uniform across
orchestration frames, needs no such split while the teardown verbs do. The wire belongs to
[the authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)
and the descent-entry composition and traversal to
[the recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md).
The [Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md)
owns that relation; the role-specific opaque command authorities minted by validated transitions are the
[installed identity, operator verification, and authority kernels phase](../../DEVELOPMENT_PLAN/phase-5-installed-identity-and-authority-kernels.md)'s
lower vocabulary, which `project up|down|destroy` enter through the composite Production root transaction.
The [step algebra and project plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)
owns the pure plan-local frame package, root-owned snapshot/journal/cursor substrate, plan-owned resource
projections, and exact root current-frame `ProjectUp` authority composition. The
[recursive lifecycle command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
consumes that substrate; it does not own or regenerate the descriptive frame evidence.

### Installed identity and the lower authority kernel

Authority begins before configuration. `withInstalledProjectIdentity` compares the declared stable
project name with the invoked executable basename, treating a terminal `.exe` suffix
case-insensitively, and opens `InstalledProjectIdentity projectId` only under a rank-2 continuation. A
caller therefore cannot select `projectId` from a configuration family or reconstruct it from
`installedProjectName`.

`verifyOsPrincipal` asks the operating system whether the current principal may write the exact
protected store and retains that store's durable identity in opaque `VerifiedOsPrincipal`. The
package-private root kernel accepts only that same store, binds an unclaimed authority store to the
installed project with compare-and-swap, and mints
`RootInvocationAuthority scope brokerGeneration verb` with the exact project, store, fresh broker
generation, closed verb, and one of the closed Production/Harness scope witnesses. The safe facade
exports neither a raw generation reopener nor a standalone root opener. Recovery rehydrates recorded
state only through the later protected recovery transition that owns the record; an integer is never
epoch evidence.

`RootScopeAuthority scope` is only a projection of that root. It has no configuration- or
context-derived constructor, so descriptive bytes cannot select Production or Harness authority.
`CommandAuthority scope planId frame brokerGeneration verb phase` is likewise abstract. Its
package-private reservation kernel receives only stable members that an enclosing lifecycle gate has
already verified: installed project, protected-store identity, plan digest, frame key, broker epoch,
verb, and phase. Those fields are encoded canonically with length prefixes and a SHA-256 record key;
the full canonical bytes are stored and checked on collision. An exact absent-to-consumed
compare-and-swap happens before the authority is yielded, so identical contenders have one winner while
changing any member names another reservation.

The reservation kernel deliberately does not inspect a plan, lease, cursor, or context. It is a sealed
atomic primitive beneath the proof-complete project-up, authenticated-child, and teardown gates, not a
generic authorization decision. `HostBootstrap.Authority.Kernel` is a hidden Cabal module with an
allow-listed package-internal importer set and no configuration or reconciliation dependency.
`HostBootstrap.Authority.ProjectPlan` exposes generic, evidence-complete `authorizeRootProject`, whose
cursor and opaque lifecycle context must share the same hidden root frame. The broad safe
`HostBootstrap.Authority` facade remains command-authority-producer-free: it
exports the abstract authority vocabulary and safe projections, but neither a `CommandAuthority`
constructor nor a generic reservation entry point.

One target API sketch makes the exact invocation state explicit; it is not an implementation inventory. In the
[step algebra and project plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md), the
scope-finalized specification, opaque plan and pure projections, and jointly generated frame-evidence
package shown here, protected snapshot admission/persistence, acquisition journal, canonical cursor
record, lifecycle admission/transitions, plan-owned resources and edges, and exact current-frame
reservation foundation are implemented. Generic root-refined `authorizeRootProject` consumes the complete
root evidence, and Production reaches it only through the hidden root-Up entry.
Recursive child authorization and complete forward/reverse traversal
remain work in the
[recursive lifecycle command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md);
their target signatures appear here only to show how they consume the step-algebra substrate. Likewise, the
`RoleLifecycleAdmission`, admission/plan-open Unknown, and rehydration APIs below are the target of the
[composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md).
The current
[authenticated-handoff-and-child-admission phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)
boundary has the smaller `ReservedRoleAdmission`/`RoleAdmissionOutcome` API described after the sketch and
does not reconstruct a reservation or consumed plan after acknowledgement loss.

```haskell
data VerbUp
data VerbDown
data VerbDestroy
data ProjectVerb verb where
  ProjectUp :: ProjectVerb VerbUp
  ProjectDown :: ProjectVerb VerbDown
  ProjectDestroy :: ProjectVerb VerbDestroy
data ServiceRun
data CheckCode

data CurrentFrame scope planId frame
data ProjectFrame scope specDigest planId configId frame
data ValidatedContext scope planId frame
  -- hidden plan-local evidence; all three are generated together by pure admission
data ValidatedLifecycleContext scope specDigest planId configId frame
  -- hidden root-coordinator root/store/parent-plan/frame/context join; never serialized
data ServiceFrame frame -- hidden proof; only ClusterService and Daemon have constructors
data AcquisitionJournal scope planId brokerGeneration -- constructor hidden
data LifecycleCursor scope planId frame brokerGeneration verb phase -- constructor hidden
data RoleCursor scope planId frame instanceId phase -- constructor hidden
data BrokerEpoch brokerGeneration
data CommandAuthority scope planId frame brokerGeneration verb phase -- constructor hidden
data BuildCommandAuthority projectId specDigest configId -- constructor hidden
  -- build and runtime-service commands use their distinct authority families below
data PlanDigestBinding scope specDigest planDigest planId -- constructor hidden
data VerifiedConfigWire scope configDigest configId -- constructor hidden
data AuthenticatedRootScope scope -- constructor hidden; verified before scope introduction
data RootedPlanCatalog scope rootPlanId brokerGeneration catalogId -- constructor hidden; root-only
data RootedFrameSession scope planId frame verb -- constructor hidden; root-only
data PreparedNodeGrant scope planId frame node verb -- constructor hidden; root-signed
data RecoveryChildPackage
  -- constructor hidden; canonical two-frame non-empty child config plus adapter, complete bytes <= 8 MiB
data RootedLifecycleRequest -- constructor hidden; non-indexed
  = OpenFrame | NextNode | SettleNode | DescendResult | CloseFrame | ReceiptConfirm
data RootedLifecycleResponse -- constructor hidden; non-indexed
  = Opened | Prepared | Descend | Settled | FrameComplete | ReceiptRecorded | Refused
data HandoffToken -- constructor hidden
data HandoffGrant scope brokerGeneration -- constructor hidden
data VerifiedHandoff scope brokerGeneration -- constructor hidden transport proof
data VerifiedConfigHandoff
  scope planDigest brokerGeneration parentFrame childFrame configId verb phase
  -- constructor hidden; produced only by Config.Schema.withVerifiedConfigHandoff
data VerifiedRecoveryHandoff
  scope brokerGeneration planDigest parentFrame childFrame recoveryWireDigest recoveryWireId verb
  -- constructor hidden
data RecoveryWireDigest
data VerifiedRecoveryWire
  scope brokerGeneration verb planDigest frame recoveryWireDigest recoveryWireId -- constructor hidden
data RecoveryProjectionBinding
  scope brokerGeneration verb planDigest parentFrame childFrame recoveryWireDigest -- constructor hidden
data RuntimeRoleWire fields service
data RuntimeRoleWireBytes
data ProductionConfigWire
data LocalWireKind = FullProjectWire | RuntimeRoleWireKind
data FrameworkEnvelopeCodec scope specDigest fields -- constructor hidden
data LocalContextView scope specDigest wireKind frame -- constructor hidden; no role parameters or authority
data LocalWireBytes
data ProjectCodec scope specDigest cfg -- constructor hidden
data FinalizedProjectSpec scope specDigest cfg
  -- constructor hidden; retains the matching project codec, service registry, and plan builder
data FinalizedSchemaFamily projectId specDigest cfg fields
  -- constructor hidden; contains the named Production/Harness envelope+codec families
data DescriptiveScopeKind scope -- closed ProductionWire | HarnessWire discriminator in the envelope
data DisplayedScope scope -- constructor hidden; display-only, never authority
data RoleCodec scope specDigest fields -- constructor hidden
data ValidatedServiceRequest specDigest configId secretDigest fields service -- constructor hidden
data RoleParams specDigest configId secretDigest fields service -- constructor hidden
data FinalizedServiceRegistry scope specDigest config -- constructor hidden
data FinalizedRuntimeSpec scope specDigest fields
  -- constructor hidden; contains the matching RoleCodec and finalized registry
data VerifiedServicePlacement
  scope specDigest planId frame revision instanceId service permittedEffects -- constructor hidden
data EffectAuthorization
  scope specDigest planId frame revision instanceId service effects -- constructor hidden
data DurablePlacementAuthority
  scope specDigest planId frame revision instanceId service -- constructor hidden
data ServiceGenerationLease
  scope specDigest planId frame revision instanceId service fence -- constructor hidden
  -- required for exclusive/mutating effects and retained inseparably through Serve into Drain
data ServiceLeaseDisposition
  scope specDigest planId frame revision instanceId service -- constructor hidden
  -- closed sum: placement ceiling proves no exclusive/mutating effect is permitted
  --          | exists fence. HeldServiceGenerationLease ... fence
data RoleAdmissionKey
data RoleAdmissionPhase = AdmissionReserved | AdmissionConsumed
data RoleLifecycleAdmission
  scope planDigest specDigest binaryDigest planId configId frame revision instanceId
  configDigest secretDigest service rolePlanDigest permittedEffects invocationId
  admissionKey admissionVersion admissionPhase
  -- constructor hidden
  -- one-use AdmissionReserved record before any prerequisite/acquisition; plan construction CAS-consumes it
data RoleLifecycleAdmissionUnknown
  scope planDigest specDigest binaryDigest configId frame revision instanceId
  configDigest secretDigest service rolePlanDigest permittedEffects admissionKey admissionVersion
  -- constructor hidden; no planId, cursor, placement, lease, or effect authority
data RolePlanOpenUnknown
  scope planDigest specDigest binaryDigest planId configId frame revision instanceId
  configDigest secretDigest service rolePlanDigest permittedEffects invocationId
  admissionKey consumedAdmissionVersion planOpenVersion
  -- constructor hidden; Consumed admission, but plan/cursor delivery is unacknowledged
data RolePlacementKey
data VerifiedRolePlanDraft scope specDigest frame service rolePlanDigest -- constructor hidden
data VerifiedRoleInstanceNonLive
  scope placementKey oldRevision oldInstanceId livenessVersion -- constructor hidden
  -- authoritative controller/OS observation, revalidated at recovery close/transfer CAS
data VerifiedOldRoleInstanceManifest
  scope placementKey requiredOldInstanceSet oldRecordSetDigest
  -- constructor hidden; each heterogeneous member retains its full old plan/spec/binary/config/secret/
  -- role-plan/effect-ceiling/planId/configId/revision/instanceId/invocationId/journal/resource lineage
  -- plus matching VerifiedRoleInstanceNonLive
data RoleLifecycleRecoveryRequired
  scope planDigest specDigest binaryDigest configId frame revision instanceId
  configDigest secretDigest service rolePlanDigest permittedEffects
  placementKey requiredOldInstanceSet oldRecordSetDigest recoveryEpoch
  -- constructor hidden; no new-instance plan/admission/effect authority
data RecoveredRoleInstanceSet
  scope planDigest specDigest binaryDigest configId frame revision instanceId
  configDigest secretDigest service rolePlanDigest permittedEffects
  placementKey requiredOldInstanceSet oldRecordSetDigest recoveryVersion
  -- constructor hidden; every manifest member's exact journal/receipt/resource recovery is terminal
data ServiceLeaseTransferBarrier
  scope placementKey requiredOldInstanceSet oldRecordSetDigest newRevision newInstanceId
  predecessorFenceSet newFence transferVersion
  -- constructor hidden; every exclusive predecessor is backend-fenced or covered by retained-lock
  -- in-flight settlement before the successor fence is published
data VerifiedNoServiceLeaseTransfer
  scope placementKey requiredOldInstanceSet oldRecordSetDigest newRevision newInstanceId recoveryVersion
  -- constructor hidden; every manifest member permitted no exclusive/mutating effect
data RoleRecoveryClearance
  scope planDigest specDigest binaryDigest configId frame revision instanceId
  configDigest secretDigest service rolePlanDigest permittedEffects
  placementKey requiredOldInstanceSet oldRecordSetDigest recoveryVersion
  -- constructor hidden; closed sum of VerifiedNoServiceLeaseTransfer
  -- or exists predecessorFenceSet newFence transferVersion. ServiceLeaseTransferBarrier ...
data SettledRoleLifecycleRecovery
  scope planDigest specDigest binaryDigest configId frame revision instanceId
  configDigest secretDigest service rolePlanDigest permittedEffects
  placementKey requiredOldInstanceSet oldRecordSetDigest recoveryVersion
  -- constructor hidden; inseparably contains the matching RecoveredRoleInstanceSet + RoleRecoveryClearance
data RoleLifecycleRecoveryAdvance
  scope planDigest specDigest binaryDigest configId frame revision instanceId
  configDigest secretDigest service rolePlanDigest permittedEffects
  placementKey requiredOldInstanceSet oldRecordSetDigest recoveryEpoch
  -- constructor hidden; closed sum of no-lease settled, transfer-barrier settled, or unknown
data RoleLifecycleRecoveryUnknown
  scope planDigest specDigest binaryDigest configId frame revision instanceId
  configDigest secretDigest service rolePlanDigest permittedEffects
  placementKey requiredOldInstanceSet oldRecordSetDigest recoveryEpoch recoveryKey recoveryVersion
  -- constructor hidden; carries no plan, cursor, handle, receipt, lease, or effect authority
data RuntimeActivationAuthority
  scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest -- constructor hidden
data VerifiedRuntimeRolePlanProjection
  scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
  service rolePlanDigest permittedEffects
  -- constructor hidden
data VerifiedRuntimeRoleActivation
  scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
  service rolePlanDigest permittedEffects
  -- opaque package of matching authority, projection, and protected secret-channel locator
data VerifiedRuntimeWorkloadIdentity
  scope binaryDigest frame revision instanceId -- constructor hidden
  -- revision is the installed rollout; instanceId is pod UID + restart count or an OS invocation nonce
data ActivationVerificationKey -- constructor hidden; installed independently of handoff/build identities
data SignedRuntimeRoleManifestBytes
data VerifiedSecretBundle
  scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
  fields service rolePlanDigest permittedEffects -- constructor hidden
data RolePlanDigestBinding
  scope specDigest planDigest rolePlanDigest planId -- constructor hidden
data ServiceCommandAuthority
  scope specDigest planId configId secretDigest frame revision instanceId phase service effects -- constructor hidden
data ServiceSelection
  scope specDigest planId configId secretDigest frame revision instanceId phase service effects -- constructor hidden
data SelectedService
  scope specDigest planId configId secretDigest frame revision instanceId phase fields -- constructor hidden
data ServiceProgram
  scope specDigest planId configId secretDigest frame revision instanceId phase service effects result
data PrereqPhase
data AcquirePhase
data ReadyPhase
data ServePhase
data DrainPhase
data ExitPhase
data VerifiedNoRoleResources scope planId frame instanceId -- constructor hidden
data RoleAcquisitionPlan scope planId frame instanceId -- constructor hidden
data ManagedRoleHandles scope planId frame instanceId handleSet -- constructor hidden
data ReadyServiceHandles scope planId frame instanceId handleSet -- constructor hidden
data RetainedRoleResources scope planId frame instanceId -- constructor hidden
  -- contains every receipt/unknown plus the matching ServiceLeaseDisposition; neither can be projected
data RoleAdvance
  scope planId frame instanceId fromPhase toPhase result -- constructor hidden
data PrereqAdvance scope planId frame instanceId -- constructor hidden
data AcquireAdvance scope planId frame instanceId -- constructor hidden
data ReadinessAdvance scope planId frame instanceId handleSet -- constructor hidden
data PrereqFailure
data AcquireFailure
data ReadinessFailure
data ServiceDispatchResult
  -- closed selection failure | completed | typed serve failure | shutdown requested | interrupted
data DrainResult -- closed aggregate of all independent release outcomes
data ServiceEffectSession
  scope specDigest planId configId secretDigest frame revision instanceId
  service effects phase invocationId sessionId journalVersion effectState
  -- constructor hidden; opened from the one-use service command and advanced only by the journal
data SealedServiceEffectCall
  scope specDigest planId configId secretDigest frame revision instanceId
  service effects phase effect invocationId sessionId targetId operationKey callDigest
  -- constructor hidden; carries the exact target and arguments; adapters accept no separate raw request
data PreparedServiceEffect
  scope specDigest planId configId secretDigest frame revision instanceId
  service effects phase effect invocationId sessionId targetId operationKey callDigest
  fence attempt journalVersion
  -- constructor hidden; carries the sealed call plus whole retained resources after protected prepare
data ServiceEffectAdvance
  scope specDigest planId configId secretDigest frame revision instanceId
  service effects phase effect invocationId sessionId targetId operationKey callDigest fence attempt
  fromJournalVersion nextJournalVersion nextEffectState
  -- observed success | typed failure | unknown, paired with successor journal + retained resources
data ServiceEffectOutcome nextEffectState
  -- constructors hidden:
  -- ObservedSuccess/TypedFailure -> ServiceEffectReady
  -- OutcomeUnknown -> ServiceEffectUnknown effect targetId operationKey callDigest fence attempt
data ServiceEffectPrepareOutcome prepareFailureState
  -- constructors hidden:
  -- PrepareRejected -> ServiceEffectPrepareFailed effect targetId operationKey callDigest fence attempt
  -- PrepareUnknown -> ServiceEffectPrepareUnknown effect targetId operationKey callDigest fence attempt
data ServiceEffectReady
data ServiceEffectPrepareFailed effect targetId operationKey callDigest fence attempt
data ServiceEffectPrepareUnknown effect targetId operationKey callDigest fence attempt
data ServiceEffectUnknown effect targetId operationKey callDigest fence attempt
data VerifiedSameKeyRetry
  scope specDigest planId configId secretDigest frame revision instanceId
  service effects phase effect invocationId sessionId targetId operationKey callDigest fence
  previousAttempt nextAttempt unknownJournalVersion retryJournalVersion
  -- constructor hidden; exact-key/fence reprobe consumes only the full matching ServiceEffectUnknown
data ChildPlanAuthority
  scope specDigest planDigest brokerGeneration parentFrame frame
  planId configId verb phase -- constructor hidden
data RolePlan
  scope specDigest planId configId secretDigest frame revision instanceId -- constructor hidden
data RolePlanDraft scope specDigest frame service
data RuntimeRoleExitReport scope frame revision instanceId
  -- opaque terminal report; contains no live cursor, handle, receipt, lease, or effect authority
data BoundPlanSnapshot scope specDigest planDigest planId -- constructor hidden

-- Private core-interpreter transitions; none is exported to project code.
withPreparedServiceEffect
  :: ServiceEffectSession
       scope specDigest planId configId secretDigest frame revision instanceId
       service effects ServePhase invocationId sessionId journalVersion ServiceEffectReady %1
  -> RetainedRoleResources scope planId frame instanceId %1
  -> SealedServiceEffectCall
       scope specDigest planId configId secretDigest frame revision instanceId
       service effects ServePhase effect invocationId sessionId targetId operationKey callDigest %1
  -> (forall fence attempt nextJournalVersion.
        PreparedServiceEffect
          scope specDigest planId configId secretDigest frame revision instanceId
          service effects ServePhase effect invocationId sessionId targetId operationKey callDigest
          fence attempt nextJournalVersion %1
        -> IO
             (RoleAdvance
                scope planId frame instanceId ServePhase DrainPhase ServiceDispatchResult))
  -> (forall fence attempt nextJournalVersion prepareFailureState.
        ServiceEffectPrepareOutcome prepareFailureState
        -> ServiceEffectSession
             scope specDigest planId configId secretDigest frame revision instanceId
             service effects ServePhase invocationId sessionId nextJournalVersion
             prepareFailureState %1
        -> RetainedRoleResources scope planId frame instanceId %1
        -> IO
             (RoleAdvance
                scope planId frame instanceId ServePhase DrainPhase ServiceDispatchResult))
  -> IO
       (RoleAdvance
          scope planId frame instanceId ServePhase DrainPhase ServiceDispatchResult)

withServiceEffectAdvance
  :: ServiceEffectAdvance
       scope specDigest planId configId secretDigest frame revision instanceId
       service effects phase effect invocationId sessionId targetId operationKey callDigest fence attempt
       fromJournalVersion nextJournalVersion nextEffectState %1
  -> (ServiceEffectOutcome nextEffectState
        -> ServiceEffectSession
             scope specDigest planId configId secretDigest frame revision instanceId
             service effects phase invocationId sessionId nextJournalVersion nextEffectState %1
        -> RetainedRoleResources scope planId frame instanceId %1
        -> IO a)
  -> IO a

resumeVerifiedSameKeyRetry
  :: ServiceEffectSession
       scope specDigest planId configId secretDigest frame revision instanceId
       service effects ServePhase invocationId sessionId unknownJournalVersion
       (ServiceEffectUnknown effect targetId operationKey callDigest fence previousAttempt) %1
  -> RetainedRoleResources scope planId frame instanceId %1
  -> VerifiedSameKeyRetry
       scope specDigest planId configId secretDigest frame revision instanceId
       service effects ServePhase effect invocationId sessionId targetId operationKey callDigest fence
       previousAttempt nextAttempt unknownJournalVersion retryJournalVersion %1
  -> (ServiceEffectSession
        scope specDigest planId configId secretDigest frame revision instanceId
        service effects ServePhase invocationId sessionId retryJournalVersion ServiceEffectReady %1
      -> RetainedRoleResources scope planId frame instanceId %1
      -> SealedServiceEffectCall
           scope specDigest planId configId secretDigest frame revision instanceId
           service effects ServePhase effect invocationId sessionId targetId operationKey callDigest %1
      -> IO
           (RoleAdvance
              scope planId frame instanceId ServePhase DrainPhase ServiceDispatchResult))
  -> IO
       (RoleAdvance
          scope planId frame instanceId ServePhase DrainPhase ServiceDispatchResult)
data VerifiedPlanSnapshot scope specDigest planDigest -- constructor hidden
data BoundRunLease scope specDigest planDigest brokerGeneration -- constructor hidden
data RehydratedResourceSet
  scope planDigest planId brokerGeneration requiredResourceSet -- constructor hidden
data RecoveredProjectFrame scope planId frame -- constructor hidden
data RecoveredTeardownStepResource
  scope planDigest planId brokerGeneration frame id resource phase operation operationKey
  -- closed sum of owned managed evidence or a released tombstone
data TeardownAuthorizationPoint scope planId verb frame childSet next
  -- closed sum of an ordinary settled-child/cursor pair or destroy-only pre-descent step

withVerifiedRuntimeRoleActivation
  :: ActivationVerificationKey
  -> VerifiedRuntimeWorkloadIdentity scope binaryDigest frame revision instanceId
  -> SignedRuntimeRoleManifestBytes
  -> (forall planDigest specDigest configDigest secretDigest service rolePlanDigest permittedEffects.
        VerifiedRuntimeRoleActivation
          scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
          service rolePlanDigest permittedEffects
        -> a)
  -> Either ActivationError a

withLocalContextView
  :: InstalledProjectIdentity projectId
  -> FinalizedSchemaFamily projectId specDigest cfg fields
  -> LocalWireBytes
  -> (forall scope wireKind frame.
        DisplayedScope scope
        -> LocalContextView scope specDigest wireKind frame
        -> a)
  -> Either ContextError a

withVerifiedRuntimeSecretBundle
  :: VerifiedRuntimeRoleActivation
       scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
       service rolePlanDigest permittedEffects
  -> FinalizedRuntimeSpec scope specDigest fields
  -> (VerifiedSecretBundle
        scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
        fields service rolePlanDigest permittedEffects
        -> IO a)
  -> IO (Either SecretBundleError a)

runVerifiedRuntimeRole
  :: ActivationVerificationKey
  -> VerifiedRuntimeWorkloadIdentity scope binaryDigest frame revision instanceId
  -> SignedRuntimeRoleManifestBytes
  -> FinalizedRuntimeSpec scope specDigest fields
  -> RuntimeRoleWireBytes
  -> IO (RuntimeRoleExitReport scope frame revision instanceId)
```

`runVerifiedRuntimeRole` is the only public role runner. The transition functions below are an
implementation sketch for the core-owned masked interpreter; they are not exported to project code and
their continuations cannot escape a live cursor, handle, receipt, lease, or admission token.

```haskell

checkRolePrerequisites
  :: RoleCursor scope planId frame instanceId PrereqPhase %1
  -> IO (PrereqAdvance scope planId frame instanceId)

withPrereqAdvance
  :: PrereqAdvance scope planId frame instanceId %1
  -> (RoleCursor scope planId frame instanceId AcquirePhase %1 -> IO a)
  -> (PrereqFailure
        -> VerifiedNoRoleResources scope planId frame instanceId %1
        -> RoleCursor scope planId frame instanceId ExitPhase %1
        -> IO a)
  -> IO a

acquireRole
  :: RoleCursor scope planId frame instanceId AcquirePhase %1
  -> RoleAcquisitionPlan scope planId frame instanceId %1
  -> IO (AcquireAdvance scope planId frame instanceId)

withAcquireAdvance
  :: AcquireAdvance scope planId frame instanceId %1
  -> (forall handleSet.
        RoleCursor scope planId frame instanceId ReadyPhase %1
        -> ManagedRoleHandles scope planId frame instanceId handleSet %1
        -> RetainedRoleResources scope planId frame instanceId %1
        -> IO a)
  -> (AcquireFailure
        -> RoleCursor scope planId frame instanceId DrainPhase %1
        -> RetainedRoleResources scope planId frame instanceId %1
        -> IO a)
  -> IO a

awaitRoleReady
  :: RoleCursor scope planId frame instanceId ReadyPhase %1
  -> ManagedRoleHandles scope planId frame instanceId handleSet %1
  -> RetainedRoleResources scope planId frame instanceId %1
  -> IO (ReadinessAdvance scope planId frame instanceId handleSet)

withReadinessAdvance
  :: ReadinessAdvance scope planId frame instanceId handleSet %1
  -> (RoleCursor scope planId frame instanceId ServePhase %1
        -> ReadyServiceHandles scope planId frame instanceId handleSet %1
        -> RetainedRoleResources scope planId frame instanceId %1
        -> IO a)
  -> (ReadinessFailure
        -> RoleCursor scope planId frame instanceId DrainPhase %1
        -> RetainedRoleResources scope planId frame instanceId %1
        -> IO a)
  -> IO a

withCurrentFrame
  :: (ProjectCfg cfg)
  => ProjectPlan scope specDigest planId configId cfg
  -> BinaryContext
  -> (forall frame.
        CurrentFrame scope planId frame
        -> ProjectFrame scope specDigest planId configId frame
        -> ValidatedContext scope planId frame
        -> result)
  -> Either FrameError result

-- Implemented: the pure frame is necessary placement evidence but opens no
-- cursor without the matching broker-indexed acquisition journal.
withLifecycleCursor
  :: AcquisitionJournal scope planId brokerGeneration
  -> ProjectFrame scope specDigest planId configId frame
  -> ProjectVerb verb
  -> LifecyclePhase phase
  -> (LifecycleCursor scope planId frame brokerGeneration verb phase -> IO result)
  -> IO (Either LifecycleError result)

withCurrentLifecycleCursor
  :: AcquisitionJournal scope planId brokerGeneration
  -> ProjectFrame scope specDigest planId configId frame
  -> ProjectVerb verb
  -> (forall phase.
        LifecyclePhase phase
        -> LifecycleCursor scope planId frame brokerGeneration verb phase
        -> IO result)
  -> IO (Either LifecycleError result)

withRecoveredProjectFrame
  :: BoundPlanSnapshot scope specDigest planDigest planId
  -> PlanDigestBinding scope specDigest planDigest planId
  -> RehydratedResourceSet
       scope planDigest planId brokerGeneration requiredResourceSet
  -> TeardownAuthorizationPoint scope planId verb frame childSet next
  -> (RecoveredProjectFrame scope planId frame -> a)
  -> Either TeardownError a

-- Implemented by the specialized HostBootstrap.Authority.ProjectPlan facade;
-- ordinary root Up reaches it only through the hidden LifecycleEntry producer.
authorizeRootProject
  :: RootInvocationAuthority scope brokerGeneration verb
  -> ProjectVerb verb
  -> VerifiedPlanSnapshot scope specDigest planDigest
  -> BoundPlanSnapshot scope specDigest planDigest planId
  -> PlanDigestBinding scope specDigest planDigest planId
  -> BoundRunLease scope specDigest planDigest brokerGeneration
  -> ProjectPlan scope specDigest planId configId cfg
  -> AcquisitionJournal scope planId brokerGeneration
  -> LifecycleCursor scope planId frame brokerGeneration verb phase
  -> ValidatedLifecycleContext scope specDigest planId configId frame
  -> IO
       (Either
          AuthorityError
          (CommandAuthority
             scope planId frame brokerGeneration verb phase))

withVerifiedConfigHandoff
  :: ProjectVerb verb
  -> VerifiedHandoff scope brokerGeneration
  -> VerifiedConfigWire scope configDigest configId
  -> ValidatedConfig scope specDigest configId config
  -> (forall planDigest parentFrame childFrame phase.
        VerifiedConfigHandoff
          scope planDigest brokerGeneration parentFrame childFrame configId verb phase
        -> a)
  -> Either HandoffError a

withChildProjectPlan
  :: ProjectVerb verb
  -> VerifiedConfigHandoff
       scope planDigest brokerGeneration parentFrame frame configId verb phase
  -> VerifiedConfigWire scope configDigest configId
  -> ValidatedConfig scope specDigest configId (cfg scope)
  -> NonEmpty (PlanDraft scope specDigest (cfg scope))
  -> (forall planId.
        ChildPlanAuthority
          scope specDigest planDigest brokerGeneration parentFrame frame
          planId configId verb phase
        -> ProjectPlan scope specDigest planId configId cfg
        -> PlanDigestBinding scope specDigest planDigest planId
        -> a)
  -> Either AuthorityError a

-- There is deliberately no public raw child-command gate. ChildPlanAuthority is
-- consumed at the root while constructing the catalog; it is never delivered to
-- a child process and cannot open a child-local lifecycle store or cursor.

authorizeRecoveryTeardown
  :: ProjectVerb verb
  -> RootInvocationAuthority scope brokerGeneration verb
  -> BoundPlanSnapshot scope specDigest planDigest planId
  -> BoundRunLease scope specDigest planDigest brokerGeneration
  -> AcquisitionJournal scope planId brokerGeneration
  -> RecoveredProjectFrame scope planId frame
  -> LifecycleCursor scope planId frame brokerGeneration verb TeardownPhase
  -> TeardownAuthorizationPoint scope planId verb frame childSet next
  -> IO
       (Either
          AuthorityError
          (CommandAuthority
             scope planId frame brokerGeneration verb TeardownPhase))

withCatalogRecoveryTeardown
  :: ProjectVerb verb
  -> RootedPlanCatalog scope rootPlanId brokerGeneration catalogId
  -> RootedFrameSession scope targetPlanId frame verb
  -> RecoveryChildPackage
  -> (forall node. PreparedNodeGrant scope targetPlanId frame node verb -> result)
  -> IO (Either AuthorityError result)

withVerifiedRuntimeRoleWire
  :: VerifiedRuntimeRoleActivation
       scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
       service rolePlanDigest permittedEffects
  -> FinalizedRuntimeSpec scope specDigest fields
  -> VerifiedSecretBundle
       scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
       fields service rolePlanDigest permittedEffects
  -> RuntimeRoleWireBytes
  -> (forall configId.
        VerifiedConfigWire scope configDigest configId
        -> ValidatedServiceRequest specDigest configId secretDigest fields service
        -> a)
  -> Either ConfigError a

verifyRolePlanDraft
  :: VerifiedRuntimeRoleActivation
       scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
       service rolePlanDigest permittedEffects
  -> NonEmpty (RolePlanDraft scope specDigest frame service)
  -> Either
       AuthorityError
       (VerifiedRolePlanDraft scope specDigest frame service rolePlanDigest)

withRoleLifecycleAdmission
  :: VerifiedRuntimeRoleActivation
       scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
       service rolePlanDigest permittedEffects
  -> VerifiedConfigWire scope configDigest configId
  -> ValidatedServiceRequest specDigest configId secretDigest fields service
  -> VerifiedRolePlanDraft scope specDigest frame service rolePlanDigest
  -> (forall planId invocationId admissionKey admissionVersion.
        RoleLifecycleAdmission
          scope planDigest specDigest binaryDigest planId configId frame revision instanceId
          configDigest secretDigest service rolePlanDigest permittedEffects invocationId
          admissionKey admissionVersion AdmissionReserved
        -> IO a)
  -> (forall placementKey requiredOldInstanceSet oldRecordSetDigest recoveryEpoch.
        RoleLifecycleRecoveryRequired
          scope planDigest specDigest binaryDigest configId frame revision instanceId
          configDigest secretDigest service rolePlanDigest permittedEffects
          placementKey requiredOldInstanceSet oldRecordSetDigest recoveryEpoch
        -> VerifiedOldRoleInstanceManifest
             scope placementKey requiredOldInstanceSet oldRecordSetDigest
        -> IO a)
  -> (forall admissionKey admissionVersion.
        RoleLifecycleAdmissionUnknown
          scope planDigest specDigest binaryDigest configId frame revision instanceId
          configDigest secretDigest service rolePlanDigest permittedEffects
          admissionKey admissionVersion
        -> IO a)
  -> (forall planId invocationId admissionKey consumedAdmissionVersion planOpenVersion.
        RolePlanOpenUnknown
          scope planDigest specDigest binaryDigest planId configId frame revision instanceId
          configDigest secretDigest service rolePlanDigest permittedEffects invocationId
          admissionKey consumedAdmissionVersion planOpenVersion
        -> IO a)
  -> IO (Either AuthorityError a)

resumeRoleLifecycleAdmissionUnknown
  :: VerifiedRuntimeRoleActivation
       scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
       service rolePlanDigest permittedEffects
  -> VerifiedConfigWire scope configDigest configId
  -> ValidatedServiceRequest specDigest configId secretDigest fields service
  -> VerifiedRolePlanDraft scope specDigest frame service rolePlanDigest
  -> RoleLifecycleAdmissionUnknown
       scope planDigest specDigest binaryDigest configId frame revision instanceId
       configDigest secretDigest service rolePlanDigest permittedEffects
       admissionKey admissionVersion %1
  -> (forall planId invocationId currentAdmissionVersion.
        RoleLifecycleAdmission
          scope planDigest specDigest binaryDigest planId configId frame revision instanceId
          configDigest secretDigest service rolePlanDigest permittedEffects invocationId
          admissionKey currentAdmissionVersion AdmissionReserved
        -> IO a)
  -> (forall planId invocationId consumedAdmissionVersion planOpenVersion.
        RolePlanOpenUnknown
          scope planDigest specDigest binaryDigest planId configId frame revision instanceId
          configDigest secretDigest service rolePlanDigest permittedEffects invocationId
          admissionKey consumedAdmissionVersion planOpenVersion
        -> IO a)
  -> IO (Either AuthorityError a)

recoverRoleLifecycle
  :: RoleLifecycleRecoveryRequired
       scope planDigest specDigest binaryDigest configId frame revision instanceId
       configDigest secretDigest service rolePlanDigest permittedEffects
       placementKey requiredOldInstanceSet oldRecordSetDigest recoveryEpoch %1
  -> VerifiedOldRoleInstanceManifest
       scope placementKey requiredOldInstanceSet oldRecordSetDigest %1
  -> IO
       (RoleLifecycleRecoveryAdvance
          scope planDigest specDigest binaryDigest configId frame revision instanceId
          configDigest secretDigest service rolePlanDigest permittedEffects
          placementKey requiredOldInstanceSet oldRecordSetDigest recoveryEpoch)

withRoleLifecycleRecoveryAdvance
  :: RoleLifecycleRecoveryAdvance
       scope planDigest specDigest binaryDigest configId frame revision instanceId
       configDigest secretDigest service rolePlanDigest permittedEffects
       placementKey requiredOldInstanceSet oldRecordSetDigest recoveryEpoch %1
  -> (forall recoveryVersion.
        SettledRoleLifecycleRecovery
          scope planDigest specDigest binaryDigest configId frame revision instanceId
          configDigest secretDigest service rolePlanDigest permittedEffects
          placementKey requiredOldInstanceSet oldRecordSetDigest recoveryVersion %1
        -> IO a)
  -> (forall recoveryKey recoveryVersion.
        RoleLifecycleRecoveryUnknown
          scope planDigest specDigest binaryDigest configId frame revision instanceId
          configDigest secretDigest service rolePlanDigest permittedEffects
          placementKey requiredOldInstanceSet oldRecordSetDigest
          recoveryEpoch recoveryKey recoveryVersion %1
        -> IO a)
  -> IO a

resumeRoleLifecycleRecoveryUnknown
  :: VerifiedRuntimeRoleActivation
       scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
       service rolePlanDigest permittedEffects
  -> VerifiedConfigWire scope configDigest configId
  -> ValidatedServiceRequest specDigest configId secretDigest fields service
  -> VerifiedRolePlanDraft scope specDigest frame service rolePlanDigest
  -> RoleLifecycleRecoveryUnknown
       scope planDigest specDigest binaryDigest configId frame revision instanceId
       configDigest secretDigest service rolePlanDigest permittedEffects
       placementKey requiredOldInstanceSet oldRecordSetDigest
       recoveryEpoch recoveryKey recoveryVersion %1
  -> IO
       (RoleLifecycleRecoveryAdvance
          scope planDigest specDigest binaryDigest configId frame revision instanceId
          configDigest secretDigest service rolePlanDigest permittedEffects
          placementKey requiredOldInstanceSet oldRecordSetDigest recoveryEpoch)

resumeRoleLifecycleAdmission
  :: VerifiedRuntimeRoleActivation
       scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
       service rolePlanDigest permittedEffects
  -> VerifiedConfigWire scope configDigest configId
  -> ValidatedServiceRequest specDigest configId secretDigest fields service
  -> VerifiedRolePlanDraft scope specDigest frame service rolePlanDigest
  -> SettledRoleLifecycleRecovery
       scope planDigest specDigest binaryDigest configId frame revision instanceId
       configDigest secretDigest service rolePlanDigest permittedEffects
       placementKey requiredOldInstanceSet oldRecordSetDigest recoveryVersion %1
  -> (forall planId invocationId admissionKey admissionVersion.
        RoleLifecycleAdmission
          scope planDigest specDigest binaryDigest planId configId frame revision instanceId
          configDigest secretDigest service rolePlanDigest permittedEffects invocationId
          admissionKey admissionVersion AdmissionReserved
        -> IO a)
  -> IO (Either AuthorityError a)

withRuntimeRolePlan
  :: VerifiedRuntimeRoleActivation
       scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
       service rolePlanDigest permittedEffects
  -> VerifiedConfigWire scope configDigest configId
  -> ValidatedServiceRequest specDigest configId secretDigest fields service
  -> RoleLifecycleAdmission
       scope planDigest specDigest binaryDigest planId configId frame revision instanceId
       configDigest secretDigest service rolePlanDigest permittedEffects invocationId
       admissionKey admissionVersion AdmissionReserved %1
  -> VerifiedRolePlanDraft scope specDigest frame service rolePlanDigest
  -> (RolePlan scope specDigest planId configId secretDigest frame revision instanceId
        -> RolePlanDigestBinding scope specDigest planDigest rolePlanDigest planId
        -> VerifiedServicePlacement
             scope specDigest planId frame revision instanceId service permittedEffects
        -> RoleAcquisitionPlan scope planId frame instanceId
        -> RoleCursor scope planId frame instanceId PrereqPhase
        -> IO a)
  -> (forall consumedAdmissionVersion planOpenVersion.
        RolePlanOpenUnknown
          scope planDigest specDigest binaryDigest planId configId frame revision instanceId
          configDigest secretDigest service rolePlanDigest permittedEffects invocationId
          admissionKey consumedAdmissionVersion planOpenVersion
        -> IO a)
  -> IO (Either AuthorityError a)

resumeRuntimeRolePlanOpen
  :: VerifiedRuntimeRoleActivation
       scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
       service rolePlanDigest permittedEffects
  -> VerifiedConfigWire scope configDigest configId
  -> ValidatedServiceRequest specDigest configId secretDigest fields service
  -> VerifiedRolePlanDraft scope specDigest frame service rolePlanDigest
  -> RolePlanOpenUnknown
       scope planDigest specDigest binaryDigest planId configId frame revision instanceId
       configDigest secretDigest service rolePlanDigest permittedEffects invocationId
       admissionKey consumedAdmissionVersion planOpenVersion %1
  -> (RolePlan scope specDigest planId configId secretDigest frame revision instanceId
        -> RolePlanDigestBinding scope specDigest planDigest rolePlanDigest planId
        -> VerifiedServicePlacement
             scope specDigest planId frame revision instanceId service permittedEffects
        -> RoleAcquisitionPlan scope planId frame instanceId
        -> RoleCursor scope planId frame instanceId PrereqPhase
        -> IO a)
  -> IO (Either AuthorityError a)

selectAndRunService
  :: VerifiedRuntimeRoleActivation
       scope planDigest specDigest binaryDigest frame revision instanceId configDigest secretDigest
       service rolePlanDigest permittedEffects
  -> VerifiedConfigWire scope configDigest configId
  -> ValidatedServiceRequest specDigest configId secretDigest fields service
  -> RolePlanDigestBinding scope specDigest planDigest rolePlanDigest planId
  -> RolePlan scope specDigest planId configId secretDigest frame revision instanceId
  -> ServiceFrame frame
  -> RoleCursor scope planId frame instanceId ServePhase %1
  -> ReadyServiceHandles scope planId frame instanceId handleSet %1
  -> RetainedRoleResources scope planId frame instanceId %1
  -> ValidatedContext scope planId frame
  -> VerifiedServicePlacement
       scope specDigest planId frame revision instanceId service permittedEffects
  -> FinalizedRuntimeSpec scope specDigest fields
  -> IO
       (RoleAdvance
          scope planId frame instanceId ServePhase DrainPhase ServiceDispatchResult)

withServeAdvance
  :: RoleAdvance
       scope planId frame instanceId ServePhase DrainPhase ServiceDispatchResult %1
  -> (ServiceDispatchResult
        -> RoleCursor scope planId frame instanceId DrainPhase %1
        -> RetainedRoleResources scope planId frame instanceId %1
        -> IO a)
  -> IO a

drainRole
  :: RoleCursor scope planId frame instanceId DrainPhase %1
  -> RetainedRoleResources scope planId frame instanceId %1
  -> IO
       (RoleAdvance
          scope planId frame instanceId DrainPhase ExitPhase DrainResult)

withDrainAdvance
  :: RoleAdvance
       scope planId frame instanceId DrainPhase ExitPhase DrainResult %1
  -> (DrainResult
        -> RoleCursor scope planId frame instanceId ExitPhase %1
        -> IO a)
  -> IO a

verifyBuildInvocation
  :: BuildVerificationKey
  -> Text       -- locally verified project name
  -> Text       -- finalized Production specification digest
  -> Text       -- locally computed Production config digest
  -> Text       -- installed coordinator-binary identity
  -> FilePath   -- caller-supplied source root measured by the verifier
  -> FilePath   -- caller-supplied builder path measured by the verifier
  -> BuildChannel
  -> (forall projectId specDigest configId frame buildId sourceDigest builderBinaryDigest.
        ImageBuildFrame projectId specDigest configId frame
        -> BuildInvocationAuthority
             projectId specDigest configId buildId sourceDigest builderBinaryDigest
        -> IO a)
  -> IO (Either BuildError a)

authorizeCheckCode
  :: ImageBuildFrame projectId specDigest configId frame
  -> BuildInvocationAuthority
       projectId specDigest configId buildId sourceDigest builderBinaryDigest
  -> IO (Either BuildError (BuildCommandAuthority projectId specDigest configId))

authorizeBuildPhase
  :: ImageBuildFrame projectId specDigest configId frame
  -> BuildInvocationAuthority
       projectId specDigest configId buildId sourceDigest builderBinaryDigest
  -> IO (Either BuildError (BuildCommandAuthority projectId specDigest configId))

```

The parser returns the current shared `InitArgs`, and assembly validates every added role through the
closed placement relation. Added project metadata may coexist with service parameters, but `ServiceFrame`
and `ProjectFrame` are placement evidence rather than authority. Only the
matching effectful gate can authorize `ServiceRun` or a closed `ProjectVerb` after consuming every other
required input. `RootInvocationAuthority scope brokerGeneration verb` comes from the independent OS/project root
gate, not from decoded context, so there is no authority → lifecycle profile → transition → authority
cycle. The implemented `authorizeRootProject` boundary consumes one root authority and matching canonical
`ProjectVerb verb`, verified and bound snapshot, digest binding, bound lease, `ProjectPlan`,
`AcquisitionJournal`, `LifecycleCursor`, and opaque root-refined `ValidatedLifecycleContext`. The hidden root
eliminator derives its `ProjectFrame`/validated-context pair. Their indices bind the same scope,
specification and plan digests, local plan and configuration identities, frame, broker generation, verb, and
lifecycle phase. Journal and cursor both retain that same broker generation, so
neither can be paired with a root authority or lease from another broker. An `up` authority cannot call
`down`, a stale phase cannot call the same verb again, and another Production plan's context cannot be
substituted. The pure `CurrentFrame`, `ProjectFrame`, and `ValidatedContext` package grants none of that
command, journal, cursor, lease, or mutation authority by itself. Ordinary root Up supplies none of those raw
members: the Cabal-private `LifecycleEntry` producer derives them and retains the successful join for its fixed
interpreter.

Before entering protected state, `authorizeRootProject` checks the retained root, plan, verified/bound
snapshot, digest binding, lease, journal, root-refined frame, cursor, and context origins. That includes the canonical
specification/configuration/plan digests and bytes; project, protected-store, stable-scope, run, broker,
verb, and phase agreement; plan-topology frame membership; exact frame/cursor/context identity; and the
context's structural permission for `ClusterLifecycleCommand`. It also compares the opaque presented
`BoundRunLease` to the acquisition journal's complete hidden lease origin: mode, project, store, plan,
lease record key/version, run, specification and plan digests, and broker generation. Matching public
digest projections or matching phantom indices therefore cannot disguise a lease from another protected
origin.

The resulting command value carries a one-use invocation identity. Because ordinary Haskell values are
not linear, `authorizeRootProject` is effectful. One protected-store entry revalidates the live mode, exact
bound lease, and canonical snapshot; verifies the journal against the cursor's exact acquisition source;
rereads the exact current cursor key, version, bytes, binding, verb, and phase; and only then consumes the
sealed command reservation. Any live-evidence drift or stale cursor returns before an invocation record is
written. The later operation-session opener also requires the exact current broker's session-admission
proof before it changes that same record to Open, and the prepare dispatcher revalidates every index plus
the current journal/session versions; retaining the value cannot open two sessions or repeat an effect.

Transport verification alone yields only `VerifiedHandoff scope brokerGeneration` and therefore cannot
select plan, frame, configuration, verb, or phase indices. Before plan construction,
`Config.Schema.withVerifiedConfigHandoff` consumes that proof with the closed `ProjectVerb`, exact
`VerifiedConfigWire`, and matching `ValidatedConfig`; it checks the signed payload kind, wire/config digest,
specification digest, verb, and closed phase and yields fully indexed `VerifiedConfigHandoff` only inside a
rank-2 continuation.

`ProjectPlan.Construct.withChildProjectPlan` is used by the root while recursively constructing the
`RootedPlanCatalog`. It consumes the verified config refinement and exact draft, checks stable plan and
signed origin, and returns a target plan/binding under the catalog continuation. The root records that
target's canonical configuration, digest, current frame, ancestry, ordered nodes, dependencies, and operation
projections as exact storeless target-frame inputs selected from `RootedPlanCatalog`. `ChildPlanAuthority`
remains root-resident; the process boundary carries only the selected frame inputs.

There is no public raw child-command or record-access route. The child first sends a four-field `OpenFrame`
containing only its fixed domain/version/discriminator and nonce; the sealed external relay envelope is its
sole open-time requester ancestry, and attachment failure returns the outer refusal. It can construct a
`FrameExecutor` only after installed-key verification of the exact nine-field paired `Opened`, whose admitted
canonical path, root-selected opaque session/stage tokens, next nonzero ordinal, and complete-response digest
seed every later request. The root then selects the catalog entry, prepares the exact operation and projected
gates in its own journal, and signs the response. Only exact local node/gate-package comparison
permits hidden same-CAS gate reification and local effect execution. Completion is likewise a bounded report
settled by the root, not a child cursor transition. The authenticated-handoff phase owns the wire and binding
vocabulary; the recursive-lifecycle-command phase owns the catalog, coordinator, executor, and durable
parent-completion composition.
`authorizeRecoveryTeardown` is deliberately narrower still: it
accepts only `ProjectDown`/`ProjectDestroy`, a verified/bound stable plan snapshot, the new broker
generation's lease bound to that same digest, recovered frame, and a closed
`TeardownAuthorizationPoint`. The forest is its sole producer; the point contains either the exact
ordinary settled-child/cursor pair or the exact destroy-only pre-descent step, and only the private
point eliminator exposes a branch. `withRecoveredProjectFrame` can mint the required local frame proof
only from that point plus the matching bound snapshot/binding and complete rehydrated resource set.
For an ordinary recovered step, `withRecoveredTeardownStepResource` returns a closed disposition sum:
the owned branch alone carries a managed handle/receipt, while the released branch alone carries the
verified release tombstone and exact bindings. That released branch has no backend-call authority;
fresh-generation eligibility additionally requires the sole protected backend-absence verifier and a
distinct new acquisition key. The resulting `FreshGeneration` is not intent authority: its sole
exported consumer constructs the exact acquisition origin, and registration must atomically
revalidate/consume its release/absence version while writing the new-generation intent and session
membership.
Thus provider reachability can be authorized before its retained children are visited, while an ordinary
provider stop/delete still requires their later settlement.
The snapshot contains the non-secret adapter parameters required
to clean up its recorded resources, so missing old config/secrets cannot force reconstruction from the
current binary. This recovery gate cannot mint `ProjectUp`, service, or build authority.

`authorizeRecoveredChildTeardown` closes the same boundary for a delayed nested child. The bound
snapshot derives a signed, non-secret recovery wire and exact parent→child projection binding; a fresh
teardown handoff authenticates that payload to the recorded child. The gate requires all three values
plus the exact bound lease, recovered frame, and closed teardown authorization point, so a snapshot
payload for one edge cannot be
relabeled for another or used outside the exclusive recovery broker generation.
It needs neither the old `cfg` nor a normal `ProjectPlan ... configId cfg`, and it can mint only the
current `ProjectDown`/`ProjectDestroy` teardown phase.

`withVerifiedRuntimeRoleWire` is the internal restart-safe config gate for controller-managed services.
The root-signed deployment manifest binds installed project/run scope, parent-plan digest, frame,
immutable rollout `revision`, exact role-wire digest, finalized-spec digest, expected binary/image digest,
separate secret-bundle digest, selected service, narrowed role-plan digest, permitted-effect ceiling, and
the platform controller/template identity allowed to instantiate it. It cannot bind a Kubernetes pod UID
that does not exist yet. After creation, the independent platform verifier pairs that signed revision
with the measured concrete `instanceId`: pod UID plus container restart count for Kubernetes, or a fresh
protected OS-service invocation nonce. Role cursors, handles, journals, and one-use admission use that
instance identity, while rollout and lease policy retain the signed revision.

Runtime role-wire/ConfigMap bytes are always non-secret: Production carries only secret pointers, while
Harness cleartext fixtures travel only in the run-scoped Kubernetes Secret object or equivalent private
OS channel. `withVerifiedRuntimeSecretBundle` does not accept caller-supplied bytes or require
`HarnessConfigAuthority`. It uses the channel locator sealed into the activation package: Production
constructs only the canonical empty bundle, while Harness reads the activation-bound private channel,
hashes its actual bytes, and matches typed secret handles one-for-one. Missing, extra, duplicate,
wrong-run, wrong-revision, or wrong-instance entries are rejected. Only then does the verifier yield
`VerifiedSecretBundle scope planDigest specDigest binaryDigest frame revision instanceId configDigest
secretDigest fields service rolePlanDigest permittedEffects`. Its full activation lineage is a required
input to role-wire request construction, so a proof from another activation cannot be paired even when
its Secret and ConfigMap bytes have identical digests.

“Installed together” is provider-specific, not a claim of a multi-object filesystem transaction.
Kubernetes uses immutable revision/digest-addressed ConfigMap, Secret, and signed-activation-manifest
objects referenced by one pod-template revision; the Secret object is the sole secret-bearing object and
must never be rendered into logs or diagnostics. Startup hashes the actually mounted ConfigMap and Secret,
then verifies pod UID, restart count, controller revision, and image digest before admission, so every
old/new mixture refuses. A host daemon uses a same-filesystem revision directory (or equivalent OS
transaction) and one atomically switched current pointer; each start then mints a fresh invocation nonce
and measures the binary. Crash/race tests cover every partial publication. Key rotation/revocation and
spec/binary migration are explicit signed revisions, never acceptance of an old manifest by a new
executable.
The implemented
[authenticated-handoff-and-child-admission phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)
activation boundary is smaller and deliberately honest.
`verifyRuntimeRoleActivation` consumes the independently installed `ActivationVerificationKey`, the protected
store whose origin later admission must use, an independently selected exact manifest, the received manifest
and grant, and the process's measured binary/config/private-bundle/instance values. Only its rank-2 callback
receives opaque
`VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId`; service,
role-plan digest, effect ceiling, secret-channel locator, and protected-store origin remain private term-level
members of that inseparable package. The long-lived Activation identity is provisioned separately from the
handoff and Build identities; a runtime-closed broker signs only its exact closed policy under
`hostbootstrap/activation/v1`, and an escaped broker refuses. The current boundary does not yet produce the
target `RuntimeActivationAuthority`, `VerifiedRuntimeRolePlanProjection`, runtime role-wire request, or
private-bundle handle package; those consumers remain work of the
[composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md)
and [service-runtime phase](../../DEVELOPMENT_PLAN/phase-22-service-runtime.md).

Before any prerequisite or acquisition, current `verifyRolePlanDraft` checks the local draft and signed
`rolePlanDigest` without durable mutation and introduces
`VerifiedRolePlanDraft scope planDigest frame revision instanceId rolePlanDigest` under six nominal roles.
`withRoleLifecycleAdmission` is the sole one-use reservation. It first requires a `ProtectedSession` from the
activation's privately retained store, then uses the fixed 79-character legal key
`role-admission.<sha256>` over `frameWire`-framed, `hostbootstrap/role-admission/v1`-separated exact plan digest,
frame, revision, and measured instance kind/coordinates. A first attempt returns opaque
`ReservedRoleAdmission`; an existing row reports `RoleAdmissionRecoveryRequired`, and a returned store failure
whose reservation status cannot be classified reports `RoleAdmissionUnknown`. Neither branch rehydrates a
reservation. `withRuntimeRolePlan` repeats the store-origin check and CAS-consumes the exact reserved version,
jointly returning `RolePlan`, `RolePlanDigestBinding`, `VerifiedServicePlacement`, and the sole initial Prereq
cursor inside its rank-2 continuation. Only `ProtectedVersionMismatch` means
`RoleAdmissionAlreadyConsumed`; other protected-store failures remain `RoleAdmissionStoreFailure`.
`runRoleLifecycle` checks the retained origin again before liveness or callbacks. If reservation or plan
delivery is lost after a durable transition, this API prevents duplicate use but does not reconstruct the
reservation, plan, or cursor. Crash/lost-acknowledgement rehydration, including the richer
`RoleLifecycleAdmissionUnknown`/`RolePlanOpenUnknown` target sketched above, belongs to the
[composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md).

In the target shared by the
[composition-and-network-algebra phase](../../DEVELOPMENT_PLAN/phase-21-composition-and-network-algebra.md)
and [service-runtime phase](../../DEVELOPMENT_PLAN/phase-22-service-runtime.md), the role lifecycle then
acquires and probes instance-indexed managed listener/connection/worker handles; only a successful probe
yields opaque `ReadyServiceHandles` for those exact identities. A restartable worker is represented by a
stable, readiness-probed supervisor handle rather than a child PID. Only a core-owned, journal-prepared
supervisor transition may replace its child, and it must probe the successor child before routing another
request; handler code receives no spawn/rebind operation. `selectAndRunService` jointly consumes the role plan,
request, binding, Serve cursor, ready handles, retained receipts, activation package, compatible
placement proof, and finalized registry. Registry lookup reveals one exact handler effect row; the gate
can mint its private
`EffectAuthorization scope specDigest planId frame revision instanceId service effects` only when that row is permitted by
the verified placement. A `DurableStore` constructor additionally requires the opaque
`DurablePlacementAuthority` carried only by a verified durable placement—no decoded context label can
stand in for it. The gate atomically revalidates the exact workload instance and reserves a private
`ServiceCommandAuthority scope specDigest planId configId secretDigest frame revision instanceId
ServePhase service effects`; it transfers
that identity directly into the internal `SelectedService` and immediately interprets its closed program
under core-owned masking/bracketing. No arbitrary callback ever receives a package that embeds live
receipts. There is no public generic service `CommandAuthority`, pure finalizer, separable effect proof,
or independently callable package eliminator. A
plan/cursor values replayed in another workload instance, mismatched effect row or placement, consumed invocation, changed
ConfigMap, another project/run, or lifecycle request therefore cannot dispatch. Activation authority by
itself cannot construct or run a `SelectedService`. The public `runVerifiedRuntimeRole` owns this whole
masked Prereq-to-Exit region; all phase eliminators are private implementation details, so consumer code
cannot throw after receiving receipts and bypass Drain.

The role engine makes pre-Serve failures constructive too. A prerequisite failure can reach Exit only
with `VerifiedNoRoleResources`; once acquisition begins, every partial/unknown failure yields only a
Drain cursor plus `RetainedRoleResources` describing every owned or uncertain acquisition, never Ready
or Serve. Full acquisition yields Ready, `ManagedRoleHandles ... handleSet`, and the complete retained
set. `awaitRoleReady` consumes all three; success yields Serve plus
`ReadyServiceHandles ... handleSet` for those exact objects, while timeout/terminal failure yields Drain
plus the retained set. Before Acquire, the signed activation and verified placement derive the
acquisition plan's lease requirement conservatively from `permittedEffects`; a caller cannot select the
no-lease branch. The retained package inseparably contains every receipt/unknown and exactly one
`ServiceLeaseDisposition`: either a proof that the placement ceiling permits no exclusive/mutating
effect, or the live, matching `ServiceGenerationLease ... fence`. Serve later accepts only a registry
row proved to be within that same ceiling, so a mutating program cannot appear on the no-lease branch.
Neither the receipts nor lease can be projected away before Drain. Serve has no handler-visible
bind/spawn/reopen constructor and can use only the probed
handles. There is no generic ownership-to-Ready constructor, so readiness cannot race ahead of
registration, a replace/rebind after the probe cannot substitute a new endpoint, and no
post-acquisition failure can skip cleanup.

Admission is also the recovery barrier. The protected open transaction independently enumerates the
complete predecessor set for the stable `RolePlacementKey`. Every heterogeneous manifest member retains
its own full old plan/spec/binary/config/secret/role-plan/effect-ceiling, local plan/config,
revision/instance/invocation, journal, and resource lineage; it is not indexed by the new rollout's
digests. If that set is non-empty, `withRoleLifecycleAdmission` yields only
`RoleLifecycleRecoveryRequired` plus its exact
`VerifiedOldRoleInstanceManifest ... requiredOldInstanceSet oldRecordSetDigest`; no new admission,
`planId`, cursor, placement proof, or lease is available. Every recovery-manifest member also carries an
authoritative `VerifiedRoleInstanceNonLive`, revalidated at the final close/transfer CAS. Non-exclusive
overlapping live instances are legal and excluded from recovery; only an authoritatively non-live member
with incomplete/unclean terminal state enters the set. A live exclusive predecessor returns
Busy/Conflict or authoritative-liveness Unknown with no recovery authority, and an exclusive placement
cannot open a successor until **every** non-live predecessor is settled and fenced.
`recoverRoleLifecycle` folds the exact manifest and rejects missing, duplicate, extra, or substituted
members while totally settling or classifying every acquisition, service-effect, Drain, and Exit record
under each old instance's keys and fences. Its advance is exhaustive: an unresolved authoritative
outcome yields only full-new-lineage `RoleLifecycleRecoveryUnknown`;
`resumeRoleLifecycleRecoveryUnknown` is its sole consumer and re-probes the same stored manifest/key
into another exhaustive advance. A terminal exact-set result yields one
`SettledRoleLifecycleRecovery`, which inseparably contains a same-new-lineage
`RecoveredRoleInstanceSet` and `RoleRecoveryClearance`; service/plan/config/effect lineage cannot be
cross-paired at resume. The no-exclusive branch can construct that clearance only from
`VerifiedNoServiceLeaseTransfer` for every member. The exclusive/mutating branch
must produce
`ServiceLeaseTransferBarrier ... predecessorFenceSet newFence transferVersion` from backend-atomic
fences or retained nontransferable locks held until every prepared/in-flight old attempt is settled. A
local fence increment, omitted predecessor, missing receipt, or caller assertion cannot construct it.
`resumeRoleLifecycleAdmission` consumes that single settled recovery package while atomically
revalidating every non-live witness, recording every recovered invocation Exit/closed, and reserving the
new instance's first journal version.
A kill or lost acknowledgment before/after recovery or transfer resumes the same stable
recovery/transfer key; it cannot allocate a second new invocation. Unsupported fencing refuses without
a successor lease/admission. Thus old-instance crash recovery and lease transfer are typed prerequisites
to new plan construction rather than prose after an already-minted plan.

The effect row is permission to use an effect family, never mutation/idempotency authority. Every
mutating durable-store/process/backend operation is first sealed as
`SealedServiceEffectCall ... effect ... targetId operationKey callDigest`; that opaque value carries the
exact target and arguments, and the backend adapter accepts no separate raw request. The private
`withPreparedServiceEffect` consumes that sealed call, the exact `ServiceEffectReady` session, and the
whole retained resource/lease package. Successful prepare atomically records the in-flight journal state
and yields
`PreparedServiceEffect ... targetId operationKey callDigest fence attempt journalVersion`, which carries
the sealed call and retained package internally. A no-exclusive-effects branch, stale fence, wrong
session/version, detached effect row, or different target/arguments cannot mint or use it.

Prepare does not return a resource-dropping `Either`. A known pre-call rejection yields only
`ServiceEffectPrepareFailed effect targetId operationKey callDigest fence attempt`; an uncertain journal
commit yields only
`ServiceEffectPrepareUnknown effect targetId operationKey callDigest fence attempt`. In both branches the
private eliminator also returns the sole successor session and whole retained package directly to the
core-owned Serve→Drain/recovery path. Neither failure state is accepted by normal prepare, so a
pre-`PreparedServiceEffect` failure cannot lose cleanup authority or become a caller-selected retry.

Every backend call consumes the prepared value—with its enclosed sealed request—and returns
`ServiceEffectAdvance ... targetId operationKey callDigest ... fromJournalVersion nextJournalVersion
nextEffectState`. Its private eliminator exposes `ServiceEffectOutcome nextEffectState` only with the
sole fresh service-journal session under the same effect row/phase and the reconstituted whole
`RetainedRoleResources`; it never projects a bare lease away from receipts. Observed success/typed
failure index that session as `ServiceEffectReady`, while unknown indexes it as
`ServiceEffectUnknown effect targetId operationKey callDigest fence attempt`. Normal prepare accepts only
`ServiceEffectReady`. The only consumer of that exact parameterized unknown session is same-key/fence
recovery, which must produce an observed resolution or
`VerifiedSameKeyRetry ... configId secretDigest ... service effects phase effect invocationId sessionId
targetId operationKey callDigest fence previousAttempt nextAttempt unknownJournalVersion
retryJournalVersion`. Private `resumeVerifiedSameKeyRetry` jointly consumes the unknown session, whole
retained package, and full-lineage proof and feeds the exact successor Ready session plus reconstructed
sealed call only back into the same core interpreter. There is no public or prose-only
Unknown→Ready conversion. A same-shaped key/fence from another target, call digest, config, secret bundle,
effect row, phase, invocation, session, or journal version cannot cross-pair. A crash
after the backend call but before acknowledgment therefore cannot blindly duplicate the effect.
Read/listen operations and supervised use of already acquired handles are explicitly non-mutating;
adding a handler-visible open/bind/spawn escape hatch is not a valid effect contribution. Rollout
revisions may overlap: activating revision R2 does not magically invalidate a still-running non-exclusive
R1 instance I1. Cross-instance replay always fails, and after I1 terminates its authority is non-live.
Exclusive or mutating effects retain the fenced `ServiceGenerationLease` through Serve and all of Drain;
the successor lease is not published merely by rotating a local fence. Each exclusive backend must
either enforce the fence token atomically with its mutation, or the core must retain the nontransferable
lease/lock across the call and delay transfer until every prepared/in-flight old attempt is settled or
authoritatively fenced. A backend that can do neither is `Unsupported`. Only the typed
`ServiceLeaseTransferBarrier` produced by that recovery transition can enter
`RoleRecoveryClearance`; only consumption of the full-lineage `SettledRoleLifecycleRecovery` containing
that clearance may reserve R2/I2 and publish its successor lease. Every later R1/I1 prepare then fails
while I1 stops. Drain releases the lease only after all
dependent releases/reprobes are settled.

Internal selection is legal only at `ServePhase`. Selection rejection, completed service, typed serve failure,
catchable controller/OS shutdown, and caught interruption all return one opaque
`RoleAdvance ... ServePhase DrainPhase ServiceDispatchResult`; selection cannot consume/drop receipts on
an `Either` failure. The core-owned selection/run region is masked and bracketed so a catchable exception
before program start enters the same Drain path. Its private `withServeAdvance` eliminator yields the
result only together with the unique linear Drain cursor and retained resource/lease package. The drain interpreter
consumes both, attempts every independent release, and returns
`RoleAdvance ... DrainPhase ExitPhase DrainResult`; `withDrainAdvance` exposes the aggregate result only
with the sole Exit cursor, still inside the public runner. Thus catchable failure/shutdown cannot skip
cleanup, one release failure cannot short-circuit the remaining independent releases, and a stale Serve
or Drain cursor cannot be replayed or captured by project code. Uncatchable process death is outside the
in-process guarantee: controller/OS recovery must rehydrate the durable admission, receipts, lease, and
effect journal, clean up/reprobe, or refuse explicit unknowns.

`verifyBuildInvocation` checks a delivered `BuildChannel` against an independently installed
`BuildVerificationKey`, distinct from both the handoff project key and the runtime Activation key,
the locally supplied project/spec/config/coordinator identities, and fresh measurements of the caller-supplied
source-root and builder paths. This reusable verifier authenticates the selected bytes; it does not establish
that the paths name the build engine's actual context and running executable. Only its rank-2 continuation
receives the jointly generated `ImageBuildFrame` and `BuildInvocationAuthority`. `authorizeCheckCode` and
`authorizeBuildPhase` consume that exact pair and each phase can be authorized at most once on that returned
authority. A separate successful verification creates separate in-memory phase state, so global signed-channel
consumption is not a claim of the
[authenticated-handoff-and-child-admission phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md).
The long-lived Build signing identity is provisioned before the short-lived coordinator bracket; grants use
the dedicated `hostbootstrap/build/v1` signature domain, and an escaped coordinator refuses after its bracket
closes. A normal developer's `check-code` remains the existing sibling-config-gated, existing-frame,
non-attesting quality path. Its project-owned `psCheckCode :: IO ()`
action is non-lifecycle by contract/convention, not mechanically read-only or effect-restricted; it carries
no build attestation and cannot authorize lifecycle or release claims. The current static
`checkCodeCommand` does not consume `HostBootstrap.Build`; the
[worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md) owns that consumer seam, trusted derivation
of both measurement paths, single presentation/acknowledgement or durable `buildId` replay refusal, the
concrete Docker secret/session channel, and live container evidence. The
[authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)
keeps its public parser/eliminator phantom audit open rather than claiming the protocol gate is closed.

Overwrite behavior is one value rather than interacting Booleans. The target rejects
`--force` plus `--if-missing` as an invalid request; it cannot silently rely on flag precedence.
`project init` maps no flag to `RefuseExisting`, `--force` to `ReplaceExisting`, and `--if-missing` to
`KeepExisting`. Writer-specific `service init` and `test init` expose neither overwrite flag and always
use `RefuseExisting`.

The writer is one race-safe transition, not check-then-write. Every policy writes and flushes an
invocation-indexed same-directory temporary. Refuse/keep atomically install it only when the target is
absent; replace atomically replaces the target. An unavailable no-replace/replace primitive is
`Unsupported`, never a fallback that writes through a newly visible destination. The writer then flushes
the parent directory (or Windows durability equivalent). Only that completed sequence returns
`Written`/`Replaced`. Crash after publication but before acknowledgment returns/recoverably
classifies `PublicationUnknown`; an equal existing file may be `ObservedEquivalent` but never proves
which writer owns it. Every failure preserves a prior complete target, and retries never append or
truncate in place. Retry cleans only a verified orphan temp carrying its invocation identity; an
unsettled or foreign temp is a typed outcome, not something silently adopted or deleted.

For a service restart, `RolePlanDigestBinding` is minted only after the workload reconstructs its
narrowed local role plan inside a fresh generative `planId`, proves its `rolePlanDigest`, and verifies the
signed projection that binds that digest and `configDigest` to the parent `planDigest`. It is the bridge
between restart-stable platform identity and non-serializable local handles; a digest label or ConfigMap
field cannot construct it. Generic `PlanDigestBinding` remains the corresponding proof for a process
that actually possesses and validates the full lifecycle plan.

## Topology Shape

The topology is pure Dhall data carried inside the same local config. It is intentionally data, not a
runtime callback. The reflected schema carries these fields on the context record:

```dhall
let ContextKind =
      < HostOrchestrator
      | VMOrchestrator
      | VMProjectContainer
      | ImageBuildContainer
      | ClusterService
      | Daemon
      | OneShotJob
      | TestHarness
      >

let ProviderKind =
      < HostProvider
      | IncusVMProvider
      | LimaVMProvider
      | Wsl2VMProvider
      | DockerContainerProvider
      | KubernetesProvider
      | ExternalProvider
      >

let WitnessKind =
      < WitnessFileExists
      | WitnessUnixSocket
      | WitnessEnvEquals
      | WitnessExecutable
      >

let TopologyFrame =
      { topologyFrameId : Text
      , topologyParentId : Text
      , topologyProvider : ProviderKind
      , topologyKind : ContextKind
      , topologyRoleName : Text
      }

let RuntimeWitness =
      { witnessKind : WitnessKind
      , witnessName : Text
      , witnessValue : Text
      }

in  { context =
      { topologyFrames : List TopologyFrame
      , currentFrame : Text
      , runtimeWitnesses : List RuntimeWitness
      , capabilities : List Capability
      , allowedCommandClasses : List CommandClass
      , ...
      }
    }
```

A list of frames plus parent references is open enough for arbitrary composition depth without a closed
recursive type. It can express:

```text
host binary -> Lima VM -> Docker project container -> kind cluster -> service pod
host binary -> Incus VM -> Docker project container -> Pulumi role -> EKS cluster -> workload pod
host binary -> Docker project container -> nvkind cluster -> accelerator daemon pod
host binary -> kind cluster service endpoint + host-native accelerator daemon
```

`hostbootstrap-core` checks these invariants after decoding: the selected `currentFrame` must be found,
the complete topology graph must validate (see the graph validator below), the config must declare the
command class and required capabilities, and the declared `runtimeWitnesses` must be **exactly** the set
the frame's placement requires — each member of which is then verified against the local environment.
Higher layers extend `ProviderKind`, role payloads, and witness constructors when they introduce new
providers.

### The closed required-witness relation

A **placement** is the exact (primary kind, owning provider, structural position) triple a required
evidence set is indexed by — not a `ContextKind`. A Kubernetes daemon pod and a host-resident daemon
share a kind and have different placements; so do the VM-backed project container and the direct Linux
GPU one. `HostBootstrap.Context.placementFor` is the closed relation from a validated frame to its
`ContextPlacement`, and `requiredWitnesses` is the single definition of what that placement must be able
to prove locally:

| Placement | Required witnesses |
|-----------|--------------------|
| `HostOrchestratorPlacement` | none |
| `VMOrchestratorPlacement <provider>` | `/run/hostbootstrap/vm-provider` exists |
| `VMBackedProjectContainerPlacement` | `/var/run/docker.sock` is a socket; `/run/hostbootstrap/vm-provider` exists; `HOSTBOOTSTRAP_CURRENT_FRAME` equals this frame |
| `DirectLinuxGpuContainerPlacement` | `/var/run/docker.sock` is a socket; `HOSTBOOTSTRAP_CURRENT_FRAME` equals this frame; `HOSTBOOTSTRAP_DIRECT_CONTAINER` equals `linux-gpu` |
| `ImageBuildContainerPlacement` | none |
| `ClusterServicePlacement` | the service-account token file exists |
| `ClusterDaemonPlacement` | the service-account token file exists; `HOSTBOOTSTRAP_CURRENT_FRAME` equals this frame |
| `HostDaemonPlacement` | `HOSTBOOTSTRAP_CURRENT_FRAME` equals this frame |
| `OneShotJobPlacement`, `TestHarnessPlacement` | none |

The VM provider witness is deliberately ephemeral. Initial config delivery
creates it for guest bootstrap, but provider share attachment can stop/start the
VM (Incus virtiofs does so). The settled `copy-source` continuation therefore
re-mints the witness after share and guest-alias reconciliation, immediately
before descent. A pre-reboot witness is never treated as proof for the child.

The child-context constructors project that set into the generated config, and `validateContext`
re-derives it from the topology and compares exactly. A **missing**, **extra/irrelevant**, or
**empty** list is `ContextWitnessSetMismatch`; two entries sharing a witness kind and name — a
**duplicate**, or a **contradictory** pair demanding two values for one variable — is
`ContextWitnessDuplicate`. There is no second hand-written witness table to drift from this one.

The relation also makes the frame's provider load-bearing: a kind its provider cannot own (a
`ClusterService` frame claiming `HostProvider`) has no placement, and `validateTopology` refuses it with
`ContextTopologyIllegalProvider` rather than guessing a required set for it.

Because placement is derived from the graph, the direct Linux GPU lane cannot be **self-asserted**.
`isExplicitLinuxGpuContainer` answers the structural question "is this a Docker project container whose
parent is the host orchestrator?" The `HOSTBOOTSTRAP_DIRECT_CONTAINER` witness must prove that
placement; merely declaring the witness cannot select it.

These checks make invalid combinations explicit **runtime validation failures**; the decoded
`BinaryContext` itself still contains `Text` identifiers, ordinary lists, public capability constructors,
and record-update paths. A caller can therefore construct or hand-edit an invalid value, but
`validateContext` rejects wrong placement, parent/frame structure, command classes, capabilities, and a
missing, extra, duplicate, or contradictory required-witness declaration. The existing effectful runtime
gate separately verifies each required fact against the local environment before a command effect begins.

The
[step algebra and project plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)
provides an implemented pure plan-local boundary above that descriptive record.
`withCurrentFrame` consumes the exact
`ProjectPlan scope specDigest planId configId cfg` and a `BinaryContext`; it requires the supplied context
to equal the context retained by the plan's validated configuration, revalidates its topology, checks its
ordered frame/parent prefix against the plan-derived topology, and requires its declared current frame to
be that prefix's endpoint. Only then does one rank-2 continuation jointly receive
`CurrentFrame scope planId frame`, `ProjectFrame scope specDigest planId configId frame`, and
`ValidatedContext scope planId frame`, all with hidden constructors and the same fresh `frame` index.
This admission performs no runtime-witness I/O or protected-store transition. `CurrentFrame`,
`ProjectFrame`, and `ValidatedContext`, alone or together, grant no command, journal, cursor, lease, or
mutation authority.

`HostBootstrap.Lifecycle.Context.withValidatedLifecycleContext` is the effectful root-coordinator join above
that pure boundary. It consumes one `CanonicalProjectRoot`, the coordinator's exact already-open
`ProtectedStore`, the matching parent `ProjectPlan`, and the plan-retained `BinaryContext`; it does not reopen
a path. Before its rank-2
continuation runs, it requires the plan snapshot and context `sourceRoot` to equal the canonical root
exactly, derives expected project and binary identity from the root coordinator's installed identity, and
rechecks total topology, placement, the exact closed required-witness set, and fresh observations of every
required witness. It deliberately ignores `allowedCommandClasses` and `capabilities`: those descriptive
lists cannot grant lifecycle authority.

Success yields opaque
`ValidatedLifecycleContext scope specDigest planId configId frame`, which retains the canonical root, same
store object, `CurrentFrame`, `ProjectFrame`, and `ValidatedContext` under five nominal indices. Its constructor
and retained projections live in a hidden Cabal module. The value is parent-plan evidence for root-side
catalog construction and root or nested coordinator entry only. It is neither serialized nor supplied to a
child `FrameExecutor`, and the public facade exports no root Boolean, frame-name authority, store projection,
command, journal, or cursor.

The effectful cursor boundary consumes that exact `ProjectFrame` over the canonical cursor record without
changing the pure context contract. The semantic frame `Text` is retained unchanged; Session derives a digest key from
canonical length-framed acquisition-key and UTF-8 frame bytes, so delimiter and Unicode identifiers are
unambiguous. The strict cursor row binds the exact acquisition key/version/bytes, frame, immutable root
verb, and frame-local phase. The acquisition phase is only an absent-row seed. Once the row exists it is
authoritative for that frame, and `withCurrentLifecycleCursor` existentially recovers its closed phase
and matching cursor rather than trusting descriptive context or guessing from the old seed. All six
cursor indices are nominal, and distinct semantic frames advance in distinct rows.

A rank-2 fold on `RootedPlanCatalog` fixes the exact target plan, validated child configuration, current frame,
topology prefix, ordered node/dependency set, and projected operation keys without yielding a second entry
type or store. The root derives every record key and owns the only reads,
writes, and compare-and-swap transitions. A child may request the next ordinal but cannot select a record key,
snapshot, operation set, or journal phase.

Only `Prepare -> Execute -> Teardown` successor eliminators exist. Their CAS reservation is at-most-once;
the continuation runs after the protected entry closes and is at-least-once, so a retry or callback
exception may redeliver the already-durable cursor. Neither `ProjectFrame` nor `LifecycleCursor` alone is
command authority, and neither turns a runtime witness or decoded frame name into authority.

The generic `authorizeRootProject` boundary consumes the matching plan/snapshot/binding, presented lease,
journal, cursor, and opaque root lifecycle context alongside the exact root authority and matching canonical
verb. It checks their complete retained origins and structural placement before one protected entry
revalidates live mode, lease, snapshot, acquisition source, and exact cursor and consumes the one-use root
reservation. Production `project up` reaches this boundary and the root coordinator only inside the
Cabal-private root-Up `LifecycleEntry` producer/fixed interpreter. The
[recursive lifecycle command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
composes the local substrate with authenticated child admission,
proof-complete operator/descent authorization, and complete recursive forward/reverse traversal; it does
not own the pure frame admission itself.

Across a process boundary, the target does not serialize authority into sibling Dhall. The independently
authorized **root invocation** owns the profile-specific handoff broker, the only `ProtectedStore`, the
unbound/bound run lease, snapshot, acquisition, recursive `RootedPlanCatalog`, and per-frame journals. A
root signs only catalog-selected prepared grants. The child cannot select record keys or snapshots, and a
child-projected plan cannot reopen the root-plan-bound lease/snapshot as if it were the same plan.

Each child is instead a long-lived storeless `FrameExecutor`. The root sends and accepts only the closed,
canonical `RootedLifecycleRequest`/`RootedLifecycleResponse` protocol-v1 vocabulary owned by the
[authenticated handoff and child admission
phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md). The outer tags are already
reserved as stable bytes 18 and 19, each carries one bounded field, and the private protocol state permits
only one outstanding request with its exact response tag and request identity. Protocol stays byte-for-byte
frozen: the hidden non-indexed inner request lives only in `Handoff.Rooted`. Its exact
`hostbootstrap/rooted-lifecycle-request` wire uses four top-level frames for `OpenFrame`, nine for
`NextNode`/`CloseFrame`/`ReceiptConfirm`, and ten for `SettleNode`/`DescendResult`. The nested non-empty UTF-8
path has one to 256 root-nearest-to-leaf components of at most 4,096 bytes. `OpenFrame` carries only an exact
  32-byte nonce: it has no inner path, session, stage, ordinal, predecessor, verb, or body, and the sealed external
  relay envelope is its sole ancestry. The envelope uses the same component cardinality and byte bound.
The root resolves that envelope against scope, runtime, catalog, and an already-opened session before mutation;
failure before attachment uses Protocol's existing outer `Refused`. Exact nine-field `Opened` binds the
request digest and discloses only the admitted canonical path, root-issued opaque non-empty
session/stage tokens (at most 4,096 bytes), and the next nonzero ordinal; it contains no digest of itself. After
signing, the root hashes and durably reads back the complete canonical signed response field; that derived
lowercase SHA-256 digest becomes the first predecessor for the next request. Open replay is keyed by root lineage,
catalog, envelope path, and nonce rather than nonce/request bytes alone. Later
requests echo the path and tokens byte-exact and carry that ordinal, a 32-byte nonce, and the 64-byte lowercase
digest of the complete prior signed response; the root requires inner path = external envelope = session path
before mutation. Only the two ten-field variants add a
non-empty opaque body, bounded to 6 MiB. The complete inner request is bounded to 7 MiB, while Protocol's
independent 8 MiB total remains authoritative. Exact source guards validate this hidden request codec without
adding a facade export, testing companion, or semantic/process/durable importer; only a neutral
Receiver-internal path fold serves Relay transport. Strict canonical decode grants no semantics: the
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) validates
typed observation/descent-result bodies, freshness, correspondence, ordering, and replay.
The implemented neutral response codec has exactly nine fields for `Opened` and eleven for every post-open
response, with a 6 MiB body and 7 MiB total bound. Post-open responses exact-bind the request digest, echo
path/session/nonce, supply successor stage/ordinal, and admit only the request's closed family. `Prepared`
nests exactly node/dependencies/operation-gate/projected-gates; `FrameComplete` stays opaque until the Handoff
facade validates its canonical lifecycle report; `ReceiptRecorded` repeats the matching predecessor digest;
rooted `Refused` is post-open only. Seven checked unsigned builders and one signature-attaching decoder live
in the neutral owner. The implemented facade adds fixed-domain live-broker signing and installed-key CPS
verification without a second type; Relay's originating typed operation is its sole transport caller, after a
neutral Receiver-internal pair fold. The opaque signed response remains descriptive rather than authority. The
root chooses the catalog node and exact own/projected operation gates, durably prepares Unknown, and
signs a bounded `Prepared` response. Only after verified `Opened` may the child construct its executor,
reconstruct its local node, and exact-compare plan/config/frame/node/dependencies and projected gates before a
hidden allow-listed reifier mints the same-CAS `PreparedGate`. Root responses authenticate the root; route
coordinates protect a cooperating sealed interpreter from misrouting and replay, not a child against a
malicious launching parent. That stronger threat model requires independently provisioned per-frame identity
or attestation.

The root invocation's provisioned project signing key is the handoff trust root, while each binary has the matching project public
verification key installed independently of config. The independently provisioned Build and Activation
identities are separate long-lived trust domains and are not derived from that handoff broker. Each long-lived
key is provisioned before its short-lived capability bracket: `RootBroker`, `ActivationBroker`, and
`BuildCoordinator` refuse after their respective invocation/coordinator lifetime ends. Handoff grants frame
`hostbootstrap/handoff-grant` plus protocol version 1; recovery wires use
`hostbootstrap/recovery-wire/v1`, Activation uses `hostbootstrap/activation/v1`, and Build uses
`hostbootstrap/build/v1`. Immediate parents relay a private duplex session to the root broker; they receive no
signing or delegation key. **The root-scope primitive and its private transport adoption are implemented** as
a strict seven-frame capsule:
inner codec domain, fixed Word64BE version 1, installed project, closed Production/Harness kind, exact run
field, installed-key digest, and fixed 64-byte signature. Its live-broker producer derives every field from
the typed `HandoffScope`; the value deliberately carries no store, broker generation, verb, Offer, edge,
payload, or plan coordinate. The root `BrokerLink` mints one capsule from its live broker and matching scope;
each nested link copies only the exact capsule retained by its authenticated parent edge. Every unchanged
four-field Offer's authentication value begins with those framed capsule bytes. The Cabal-private
**binary receiver** first lets Protocol bound and split the four opaque outer fields, opens only the
authentication field's leading capsule, verifies it against the independently installed identity and project
key, and enters the rank-2 Production-or-Harness scope continuation before semantically parsing offered-key,
binding, challenge/grant, or payload data. Neither binding bytes, config text, nor caller input chooses that
phantom. The generic capsule primitive is owned by the
[authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md);
the [test-harness-and-run-ownership
phase](../../DEVELOPMENT_PLAN/phase-19-test-harness-and-run-ownership.md) supplies its exact generative Harness
run evidence and adopts the Harness producer call site.

Only inside the authenticated scope does the receiver semantically decode and compare the already bounded
four-field Offer containing the exact narrowed-config or complete recovery-package payload, one-time token,
canonical binding, and authentication field. It then mints the fresh challenge, verifies the ordinary grant
with the same independently installed key, and exhaustively classifies config or recovery. The receiver joins
the exact verified `RootedPayloadBinding` in both branches and, for recovery, retains the canonical
`RecoveryChildPackage` with its typed projection, grant, and verified adapter wire. The reverse-offer path
transmits only that complete package; it never relabels an adapter as one.

The target composite of the ordinary edge and rooted binding fixes the plan revision, protected-store identity,
broker generation, parent/child frames, verb/phase, payload kind, complete-payload digest, and separately framed
child-config digest claim. Recovery uses canonical `RecoveryChildPackage` bytes containing exactly two
non-empty frames for child configuration and adapter. Although the standalone package codec permits complete
bytes up to 8 MiB, Relay and Receiver impose a 7 MiB embedded Offer-payload sub-ceiling. That sub-ceiling is
not a whole-frame guarantee: Protocol's authoritative 8 MiB total-body check may still refuse after the other
Offer fields and framing overhead are included. The package-aware join recomputes the payload digest over the
complete canonical package and the child-config digest over its exact extracted configuration field. That check is the sole upgrade from
authenticated unequal digest claims to recovery package/config-field membership. `RecoveryAdmission`
independently authenticates only the extracted adapter; the recursive catalog's future `EdgeAdmission` owns
the complete package configuration and payload digest. In the config branch, exact-byte codec verification
separately creates a fresh child `configId`, `VerifiedConfigWire`, and matching `ValidatedConfig`;
only `Config.Schema.withVerifiedConfigHandoff` can refine those values into the fully indexed proof required
for child plan admission. A recorded transcript, replay, truncation, cross-kind evidence, or payload/token
mismatch cannot produce either classified branch. Neither payload appears in `argv` or the environment, and
the token is never a Dhall field.

**The scope capsule and its private transport adoption, lower transport, additive rooted binding, and
canonical recovery-package join are implemented** behind
the exposed `HostBootstrap.Handoff` facade. Its canonical ordinary `HandoffBinding` length-frames the
installed project, specification, payload kind, scope, protected-store identity, stable plan revision, broker
generation, parent→child frame pair, one complete-payload digest, verb, closed phase, and token commitment so
different edges cannot render to the same signed bytes. The opaque `RootedPayloadBinding` exact-binds those
byte-stable legacy edge bytes and separately frames complete-payload and child-config digest claims under its
fixed root signature domain. Config signing and verification still require the received payload and child
config to be the same non-empty exact bytes and their two digest claims to agree. The distinct hidden-capability
recovery-package signer instead accepts one exact recovery offer and opaque package, derives the
complete-package and extracted-config digests, and accepts no separately supplied config bytes or digest pair.
`withVerifiedRecoveryChildPackage` treats its supplied rooted value as untrusted signed data: it rerenders and
cryptographically reverifies that value against the exact authenticated handoff and installed key, decodes
only the authenticated payload, and recomputes both digests before exposing package fields. Neither package
bytes nor a signed rooted value alone admits those fields. The implemented package boundary adds no receiver
carrier or application producer.

The public facade retains the lower framing, binding, root-broker registration/grant, recovery-envelope codec,
and signature-verification operations; it does not reexport `HostBootstrap.Handoff.Protocol` and exposes no
independently usable recovery signer, channel/link producer, endpoint, or request identity. `withRootBroker`
narrows a separately provisioned
`ProjectSigningKey` to a verified `RootInvocationAuthority`; it neither generates nor exports the long-lived
identity. Every broker operation holds the bracket's live-state lock through its protected-store or signing
work, and an existentially retained broker refuses after the bracket closes. The receiver mints a fresh
challenge, and the root consumes the registered one-time edge by compare-and-swap before issuing its signed
grant. The child then verifies that grant against its independently installed key; a byte-identical retry at
the root converges on the recorded signature, while a different challenge is refused as token reuse. The
config digest is recomputed from the bytes actually received, and the verification key is a separately
installed input; a key carried in the envelope is never consulted. The config refinement refuses the wrong
wire/config/specification/verb/phase. Target root-catalog admission checks those coordinates against the
recursively projected plan and retains the relation structurally through rank-2 selection; no child process
receives a nested lifecycle context, acquisition, cursor, reservation, or store.

**The lower receiver and relay substrate is implemented behind a sealed package boundary.**
`HostBootstrap.Handoff` is the sole exposed handoff module; `HostBootstrap.Handoff.Protocol`,
`HostBootstrap.Handoff.Receiver`, and `HostBootstrap.Handoff.Relay` are Cabal-private. The private
stdio channel keeps protocol bytes on `stdin`/`stdout`, diagnostics on `stderr`, and sends every refusal.
Its fixed-unit rank-2 fold exposes no caller-chosen result, raw branch selector, channel, signing capability, or
request identity. The broker records each intended edge before granting it, consumes one-use registration
durably, and converges an identical retry on the recorded signature.

The dedicated child entry owns those descriptors rather than sharing them. Before any configuration, plan,
executor, or lifecycle continuation runs, the receiver duplicates the original standard input and output into
private handles and builds its binary channel from those, then redirects the global pair for the whole
callback: standard input to the host's null device, so an ordinary read sees EOF instead of a protocol frame,
and standard output to standard error, so an ordinary write becomes a diagnostic instead of a corrupted
length-framed message. Callback code needs to know none of it — it cannot steal or corrupt the channel even
by accident, because the handles it would use no longer name it. The redirection is a bracket, so it is
undone on success, on refusal, on exception, and on asynchronous cancellation alike, and every duplicate is
closed afterwards; both restores are attempted independently, so one failing does not strand the other. The
entry takes no channel and no handle, there is no ambient terminal or environment heuristic choosing
descriptors, and no testing seam exports the policy, so the duplication is the receiver's own and its only
one.

The receiver contract is scope-first. The current Relay frames the exact root-issued capsule first in the
unchanged four-field Offer's authentication value. Protocol structurally bounds and splits all four opaque
Offer fields before authentication but does not interpret their binding or payload semantics. The receiver
opens only the leading capsule and verifies it with the independently installed identity and project key.
Only inside that rank-2 Production-or-Harness continuation does it inspect the offered key, semantically parse
and compare binding/payload bytes, mint its fresh challenge, verify the ordinary grant, and classify the
authenticated payload. Offer bytes, config text, `argv`, and caller input cannot choose the scope phantom.
The fixed-result/refusal discipline remains intact around `AuthenticatedRootScope`.

The implemented neutral `RecoveryChildPackage` exact bytes frame non-empty child configuration and adapter as
two inseparable fields within the complete 8 MiB standalone bound; `payloadDigest` commits to the complete
package, while `childConfigDigest` independently commits to the configuration field. Relay and Receiver impose
a 7 MiB embedded Offer-payload sub-ceiling; the independent authoritative Protocol total-body check remains
free to refuse framing and the other fields. The codec, distinct live-broker recovery-package signer, and
package-aware verified join do not by themselves select plan-derived bytes. The authenticated-handoff phase
adopts only the generic rooted carrier and package-aware receiver, retaining typed
package/projection/grant/wire evidence and
deriving its legacy raw eliminator views. It adds no real package producer.
The recursive-lifecycle-command phase alone selects the child config and
adapter from the catalog, makes the complete
package the reverse input and Offer payload, admits its config/digest, and routes that exact Offer to the root
signer already installed behind the keyless relay. Neither a relay nor possession of package bytes grants
store, journal, cursor, command, or signing authority.

The authenticated-handoff phase's transport boundary implements only transport adoption. Its private
relay reconstructs a
sealed cooperating requester envelope at every hop in root-nearest-to-leaf order, checks the one-to-256
non-empty UTF-8 component grammar and 4,096-byte encoded component bound, preserves each singleton inner
request/response byte string, and checks only strict canonical shape, request/response pairing, authenticated
path suffixes at intermediate hops, and complete-envelope equality at the root. For `OpenFrame` the envelope
is the sole ancestry input. The originating typed operation alone verifies a returned signed response against
the exact request and independently installed key. Both the existing outer `Refused` and any exact signed
rooted `Refused` are uninterpreted transport outcomes. After that structural validation the root link runs
the rooted lifecycle service the recursive-lifecycle-command phase installs, so this boundary decides whether
a request is well formed and never what it is answered with; it constructs no recursive child and completes
no successful rooted process exchange. Intermediate frames retain only their package-private
keyless route.

Before any of that traffic moves, a frame installs the fixed dependencies it needs to take part: whose
signature to trust and whether it is the one that may sign. That installed runtime is a value, not a
capability. Its root arm derives every coordinate — installed project, scope tag, protected-store identity,
broker generation, verb, and installed verification-key digest — from the admitted root environment and the
live broker's own public half, and it requires a route with no authenticated current frame. Its nested arm
derives the same coordinates from an already authenticated parent edge and requires the relayed route to name
exactly that edge's child frame, so the two arms are mutually unreachable and a nested frame receives the
runtime only beside the keyless link derived from the same edge. The runtime retains no key, store, broker,
channel, catalog, session, or route, and names no protocol tag, activation manifest, or build material at
all: its lifecycle-only policy is the absence of any term with which another route could be expressed.

The recursive-lifecycle-command phase's rooted-relay-service increment installs the root endpoint. That phase
exact-matches post-open inner, external-envelope, and session-retained paths before mutation and owns plan admission,
response production and fixed-signer invocation, semantic freshness/replay classification, durable settlement and receipt
ordering, storeless frame execution, and process ownership. Sibling and ancestor splices then fail at root
admission; none of those semantic or durable claims belongs to the authenticated-handoff transport.

What is **not yet wired** is the live descent: `Lift.ConfigDelivery` still delivers the child config
with the `sh -c "cat > <sibling> && exec <binary>"` writer described above. Adopting the receiver and
relay at that call site lands with the recursive interpreter in the
[recursive lifecycle command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md).
Recovery request/response dispatch is implemented across the same repository-sealed requester path, including
a genuine multi-hop relay. Protocol, Receiver, and Relay remain Cabal-private; the authenticated-handoff
phase owns the complete v1 vocabulary and the recursive-lifecycle-command phase owns its rooted public
adopter, rather than adding a test-only channel or signer seam. Recursive
teardown/recovery call-site adoption remains work for the
[recursive lifecycle command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) and the
[recovery and migration phase](../../DEVELOPMENT_PLAN/phase-18-recovery-and-migration.md).
The implemented reverse substrate stays root-resident. A private verb-tagged intent records or resumes the
exact existing Up/root/Teardown source under one liveness extent, rebuilds only the same plan identity at the
target epoch, and seals a distinct Down/Destroy root entry. Durable Prepared and Bound reverse-descent rows
retain the exact plan-owned adapter, edge, continuation, canonical bytes, and record versions; exact retry and
token-free rehydration expose no child store, cursor, or command authority.

The lower handoff substrate also includes recoverable one-use opening and token repair, bounded six-branch
completion reports, ordered typed observations, sealed semantic completion, root-resident parent
acknowledgement, and keyless exact request/response routing. The route validates complete grant and request
correspondence plus cooperating-interpreter ancestry, but it has no process caller and makes no malicious
launching-parent identity claim. Root-owned receipt confirmation is the target durable order: Published →
signed `FrameComplete` → `ReceiptConfirm` → Received → signed `ReceiptRecorded`.

The finalized-project projector validates one exact project-owned child projection without exposing projector
bytes or a caller-polymorphic result. The inert `PlannedForwardHandoff` then joins that projection to the exact
topology edge, constructs the target plan and `PlanDigestBinding`, and retains only a sanitized process route,
canonical payload, and binding input. It contains no live broker, token, independently selectable executable,
journal, cursor, store, or effect authority and has no runtime caller.

The [recursive-lifecycle-command
phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) admits planned and recovery packages into
the root catalog before a sealed Process/Receiver bracket launches a storeless executor. The root owns the
frame session, durable Unknown publication, signed prepared grant, observation settlement, completion, receipt,
successful reverse terminalization/rearm, and failed-Up unwind. Structural refusal precedes root mutation, and
lawful rooted progress is signed, durable, and idempotent.

The root broker remains live through one recursive invocation. Its one-use command authority opens one
versioned operation session only with `CurrentBrokerSessionAdmission`. Clean activation can mint that
proof only after finding no older Open session. Abandoned activation instead consumes the exact
old-permit fence set and verifies the manifest pairing the independent complete session set—including
zero-operation Open sessions—with its independently complete operation set. Registering an operation's
initial intent consumes a closed first-generation or released-reacquisition origin, atomically adds it to
that exact session, and advances the session/project-journal versions, so neither an orphan intent nor a
recordless manifest member exists. An initial intent may have no fence record and cannot prepare; the
protected recovery interpreter idempotently completes the stable initial-fence protocol before it exposes
current-fence continuable authority. It
rebinds every existing stable session record and totally classifies unknown, the five pre-call
continuable phases, the closed already-observed retry whitelist, successful, and terminal records. It
yields admission only after those logical sessions are Closed and their operations are settled with the
sole successor state/permit chain. Session open and close themselves return that sole successor project
state/permit pair and contend on the same Open project-journal/revision record as migration freeze and
terminal close. Before every child backend
effect, one protected prepare
compare-and-swap
revalidates the broker/authority epoch, exact verb/phase/frame, bound lease, active plan revision,
Open-project state, session, current authoritative fence, and journal record. It also consumes the
plan-owned exact zero/one/many precondition set, reruns every target/dependency probe and observation
version, and obtains the conditional backend versions; stale/replaced/not-ready evidence returns no
permit. It durably records the exact unknown state and only then returns matching attempt-indexed
prepared operation and freshly prepared preconditions together with the
successor Open-session, successor Open-project operation state, and matching revision-permit authority
at one fresh journal version. The consumed journal version cannot authorize another prepare or close.
An adapter accepts only that jointly produced pair and no retained `Ready`/prerequisite bundle. Every
adapter terminal observation returns `OperationAdvance` on success or typed failure; its
eliminator yields the result only with the sole successor Open-project state/revision-permit pair.
Initial fence creation persists/resumes the same proposed epoch and returns the sole successor
session/state/permit pair; crash-time fence rotation is likewise durable and idempotent. A delayed old-session
permit is rejected or deduplicated. Terminal acknowledgment verifies that every outcome is already
settled and compare-and-swaps the exact session version Closed, so it cannot race a new prepare.
Generative handles/journals/receipts are never carried across processes. If a child launches another
child, it requests a fresh edge grant over the retained root relay. A later Production `down`/`destroy`
re-runs the independent OS/project root gate, binds the protected stable plan snapshot/journal/backend
identities, and opens a new broker generation rather than relying on the old `up` process. The config
remains descriptive after it is written. The
[authenticated-handoff phase](../../DEVELOPMENT_PLAN/phase-13-authenticated-handoff-and-child-admission.md)
coordinates this envelope, receiver, and installed trust anchor with the protected broker and lease
ownership from the
[lifecycle-modes phase](../../DEVELOPMENT_PLAN/phase-9-lifecycle-modes-and-run-leases.md). The
[step algebra and project plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)
owns the root plan-snapshot binding, acquisition journal, cursor, and current-frame authority substrate. The
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
composes it at recursive call sites and owns traversal, while the
[recovery phase](../../DEVELOPMENT_PLAN/phase-18-recovery-and-migration.md) owns migration and recovery
policy.

Canonical runtime dependency commitments do not change that rule. They contain only domain-separated plan,
scope, resource, frame, origin, generation, journal/receipt, bounded route, and expiry text. The corresponding
fresh reprobe closure is invocation-local state in a separate private live registry, never Dhall, handoff,
stable-plan, or dependency-package bytes. Opening a provider package as a cluster package—or changing any
commitment, route, generation, or lifetime—refuses before the live closure can be selected.

The authenticated handoff vocabulary reserves closed, singleton-field frames for a provider dependency
package, its probe request, and its probe response. The package field is the canonical provider-domain
`RuntimeDependencyPackage` rendering; the request adds one bounded nonce; and the response is either the
matching observed generation or a bounded non-empty refusal reason. Decoding enforces the exact version,
domain, field count, canonical length and integer encodings, complete re-render, 64-KiB package bound, and
128-KiB probe-frame bound. Consequently duplicate or trailing fields, changed package bytes, replayed nonces,
wrong domains, empty refusals, and oversized input fail closed. These tags carry data only: they install no
service, add no state-machine transition, and encode no backend command, handle, readiness witness, receipt
authority, closure, or reusable secret. The bracket-scoped service and relay remain separate live protocol
concerns rather than values a receiver can deserialize.

The owning frame's caller-free reprobe kernel brackets one lexical provider observation behind a data-only
request handler. Before backend access it opens the provider package against the exact plan, scope, resource,
frame, backend origin/generation, journal and Ready-receipt commitments, route, and current tick, then validates
the request's complete package commitment and nonce. Nonces are atomically consumed before observation, with
at most 64 accepted requests per bracket and a fixed 100-millisecond local probe deadline. Success requires the observed
generation to equal the admitted generation; replay, capacity exhaustion, timeout, provider closure/refusal,
or generation change yields a canonical nonce-bound refusal. A malformed or unauthenticated request yields no
backend access. The continuation receives only the bounded byte handler, never the lexical probe or authority.

`Handoff.Process` installs that handler by record-narrowing the existing live `BrokerLink` inside the same
provider-kernel and child-process brackets. An admitted child sends the closed request tag on its retained
duplex and accepts one response with the exact edge request identity and response tag. Its hidden client
allows one outstanding request, consumes at most 64 nonces, and returns only the verified observation/refusal
sum. Every intermediate `BrokerLink` forwards the unchanged field list over its already authenticated parent
channel; it has no endpoint, key, package interpreter, or result constructor. The upstream wait has a fixed
one-second deadline, while Protocol retains its 8-MiB frame ceiling and each codec retains its tighter bound.
Closing any Process, receiver, or provider-kernel continuation closes the only reachable endpoint. No socket,
environment value, argv term, config field, durable file, or generic carrier supplies another channel.

After authenticated child admission, a frame with cross-frame dependencies sends the closed package query on
that retained duplex. The parent answers with either the exact canonical provider package installed in its
lexical endpoint or the canonical empty absence; the child cannot name a package or route in the query. A
present package is decoded in the provider domain and registered in the new frame's invocation-wide
`ResourceCarrier`, then its hidden client is installed in the carrier's separate live-service registry. Every
`StepRuntime` built for that frame shares those two entries, and a deeper descent forwards the same canonical
package and fixed service. This admission performs no probe, calls no provider opener, and mints no managed,
Running, readiness, receipt, key, channel, or journal authority. Absence leaves both registries empty; malformed,
wrong-domain, duplicate, or changed packages refuse before the frame executor opens.

## Per-Frame Fail-Fast On Handoff

The target recursive interpreter descends frame by frame: each frame runs its chain steps, then hands off
`<project> project up` into the next frame (see [composition_methodology](composition_methodology.md) for
the fractal-bootstrap pattern). The binary-context gate is one precondition on each handoff. Current
Production runs the exact current-frame segment and fails closed at a declared descent until the
authenticated child package is consumed by the fixed recursive command entry; the package-private
journal/cursor bridge itself is implemented.

Commands that operate on an existing project frame — `project up|down|destroy`, `service run`, and
`check-code` — start by loading the sibling config and fail fast with exit code 1 when:

- `<project>.dhall` is absent;
- the Dhall does not decode against the binary's config/context schema;
- the config names a different project or binary;
- the config does not declare the requested command class;
- the context does not declare the capabilities the requested command requires;
- the declared `runtimeWitnesses` are not exactly the set this frame's placement requires;
- a required local runtime witness cannot be verified.

Validation covers the complete topology graph and the closed required-witness set, so an **omitted**
required witness is rejected. The pure `withCurrentFrame` admission carries the exact
plan/context join as jointly generated opaque frame-indexed evidence instead of letting a downstream
caller select the plan and frame indices independently. The root cursor boundary installs it over
the canonical record, and generic `authorizeRootProject` consumes the root lifecycle package with the
matching retained and live lifecycle evidence. Production `project up` uses that exact gate only through its
hidden root-Up entry.
The
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
uses that substrate for authenticated descent and recursive traversal.

The implemented config-input matrix is:

| Surface | Current config behavior |
|---|---|
| Help output | Config-free |
| `project init`, `service init`, `test init` | Config-free writers |
| `service schema`, `context path`, `context schema`, `context render` | Static and config-free |
| `context inspect` | Reads and decodes the executable-sibling `<project>.dhall`; no command-authority gate |
| `context show [FILE]` | Reads and decodes the selected file, or its parser default when `FILE` is omitted; no command-authority gate |
| `test run <case-id>\|all` | Reads `<project>.test.dhall`, then installs each run variant through `HostBootstrap.Harness.GeneratedConfig`, which holds all four [ownership_invariant](ownership_invariant.md) clauses over that file and removes it only on an exact re-observed identity and payload. The "an existing sibling config refuses" check is that protocol's own found-object refusal plus the post-sweep `harnessPreconditions`, so an interrupted run's config is reclaimed rather than blocking recovery. The [lifecycle-modes phase](../../DEVELOPMENT_PLAN/phase-9-lifecycle-modes-and-run-leases.md) owns the protected run/lease evidence, the [installed-identity and authority-kernel phase](../../DEVELOPMENT_PLAN/phase-5-installed-identity-and-authority-kernels.md) owns the lower opaque authority vocabulary, and the [recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) makes this parser route require proof-complete authority |
| `project up\|down\|destroy` | Admit the sibling `<project>.dhall` **once** into a `ValidatedConfig` snapshot, apply the existing-frame command gate, and run plan construction and every chain step against that one snapshot |
| `service run`, `check-code` | Read the sibling `<project>.dhall` and apply the existing-frame command gate |

This distinction matters: neither read-only inspection nor a config-free writer is evidence that the
whole `context` or init surface carries runtime authority. `service run` adds the leaf-kind check described
above. The
[Dhall configuration and project-model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md)
owns the exact placement relation. The
[step algebra and project plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)
joins that descriptive result to the exact plan as pure frame evidence. The root lifecycle-context join and
generic `authorizeRootProject` require the matching plan, lease, journal, cursor, and root authority
before reserving a command. Production dispatch consumes the resulting hidden root-Up entry, never the raw
gate inputs. The
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
composes that substrate with operator/descent evidence for proof-complete recursive
`project up|down|destroy` dispatch and traversal.

So when the parent hands off into a child frame, the child's first act before frame work is to prove — against its own
`.dhall` and the local runtime — that it is in the frame it was minted for. A frame that cannot witness its
declared place refuses the handoff loudly, and the lifting parent sees a non-zero exit. The same `project`
command tree exists in each frame, but each copy refuses work that does not belong to its place.

## The `context` Command: Read-Only Introspection

`context` is a **read-only** command. It mutates nothing and creates no files. Its subcommands —
`inspect`, `path`, `show`, `schema`, and `render` — form one introspection surface with distinct inputs:

- `context inspect` decodes the executable-sibling `<project>.dhall` and renders its global lift
  composition (`topologyFrames`/`parentChain`) with the **current frame highlighted**;
- `context show [FILE]` decodes and renders the selected file, or the parser's default file when `FILE`
  is omitted;
- `context path` prints the static canonical filename;
- `context schema` and `context render` print the binary-owned artifact schema and static examples.

Read-only does not mean config-free. `path`, `schema`, and `render` operate on static binary-owned
information and run without a sibling config. `inspect` decodes the sibling config; `show` decodes the
specified file or its default. Neither path applies the command-class/capability gate used by mutating
commands, but both require the file they inspect to exist and decode. No `context` subcommand projects
authority into a child frame.

Current child files are context-adjusted full configs, so the current full decoder happens to serve both
inspection routes. In the target, every full and role wire carries a closed wire-kind discriminator, a
closed descriptive Production/Harness scope-kind discriminator, and the same jointly derived framework
envelope. `withLocalContextView` validates only that envelope and lets
`inspect`/`show` render wire kind, identity, topology, current frame, and safe framework metadata for a
root full wire, cluster-service role wire, or daemon role wire; it exposes no `RoleParams`. The
config-free reader starts from the installed project's scope-erased `FinalizedSchemaFamily`, reads the
scope-kind tag, selects that one named Production/Harness envelope codec, and requires the codec to
validate the same tag before returning a `DisplayedScope`. A missing/unknown tag, disagreement, or
structurally overlapping untagged shape returns an explicit unknown/ambiguous display result; it never guesses by
trying structurally overlapping codecs. The witness is presentation-only and cannot mint Harness or
command authority. Existing-frame authority routing obtains scope only from the verified
root/handoff/activation package, then requires the descriptive tag to agree; it never derives authority
from the tag.
Existing-frame dispatch uses the same discriminator before its second-stage decoder. A project verb presented with a
valid role wire therefore receives a structured wrong-wire-kind/authority refusal, while `service run`
presented with a full wire receives matching service-init/parent-projection guidance; neither is reported
as syntactically malformed merely because the other codec was tried first.

### Context creation is internal lifecycle work, not a verb

The core algebra names a `context-init` step at the boundary where the next binary becomes meaningful,
but the current demo does not yet make that step the effect owner: its action body only announces the
boundary. VM config is rendered/streamed inside the composite VM bootstrap/build-pb action. The
container payload is bound to the announcing row: it rides the descent that same
`context-init` step declares with `descendsVia`, which `mkStepPlan` requires exactly one of per frame —
but the projection function is still computed outside the plan's own delivery operation. The opaque
`ProjectPlan` and topology projection now exist; later delivery/consumer adoption makes child projection,
authenticated delivery, and the single `context-init` node one validated operation:

1. Python validates one Cabal filename/package/executable identity, builds
   `./.build/<identity>`, and invokes the requested command (POSIX process replacement with `exec`;
   Windows child subprocess). It writes no Dhall and does **not** initialize config; it is the metal-frame
   instance of the fractal bootstrap. The Haskell entrypoint rejects a declared project/config name that
   differs from the invoked executable before dispatch. The
   [step algebra and project plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)
   provides opaque plan-local frame identity at the pure admission boundary and the exact local `ProjectUp`
   authority boundary. Production dispatch carries that evidence through the live lifecycle API.
2. `project init` is a config-free writer. With no role/output/policy flags it is the **fresh-root
   default**: write the executable-sibling `<project>.dhall` as a host orchestrator with no parent and
   refuse an existing output. The current parser also supports `--role ROLE`, repeatable
   `--also-role ROLE`, `--output FILE`, `--force`, and `--if-missing` (plus the project parameter
   overrides): `--force` overwrites, `--if-missing` leaves an existing file untouched, and when both are
   present the current implementation gives `--force` precedence. This shared `InitArgs` shape is the
   current parser contract. Role additions pass through `roleAdditionAllowed` and the validating `addRole`
   constructor, while the relevant effectful command gate still consumes independent authority. Because
   Python never creates config, an existing-frame command run before an initializer or harness-generated
   config finds no sibling file and **fails fast** (exit 1).
3. During current demo `project up`, composite bootstrap/handoff code generates the child
   `<project>.dhall` from passed/forwarded parameters; the separately rendered `context-init` node does
   not perform that effect. Later plan-aware delivery adoption makes the plan-owned node perform the
   parameterized child projection and authenticated handoff, name the child frame, and include only
   locally verifiable witnesses.
4. The project Dockerfile currently bakes a context-adjusted full `image-build-container` config at
   `/usr/local/bin/<project>.dhall` so build-time commands (`check-code`, static code generation, web
   asset compilation) can pass the descriptive context gate during the image build. The target does not
   treat that file as authority: the [worked-demo phase](../../DEVELOPMENT_PLAN/phase-24-worked-demo.md)'s
   authenticated derived-image sprint makes the build orchestrator supply an ephemeral
   `BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest`
   through the build engine's secret/session channel and record the terminal outcome. That consumer derives
   its measurement paths from the actual engine context and running executable and refuses a second channel
   presentation. This binds inputs known before the image exists; the resulting image digest is recorded
   afterward. Runtime parents currently stream a context-adjusted full config record in-place on launch
   `stdin`; the demo retains every project field and the full resource envelope. The target internal receiver
   accepts a role-specific payload only with a verified root-broker grant. A
   Kubernetes service or daemon pod instead receives descriptive config as a ConfigMap override plus the
   platform identity described below.
5. A current service or daemon receives a context-adjusted full demo config from the controller or
   launcher that owns identity and durable placement. The target receives a role-specific parameter
   payload. For stateful Kubernetes services that controller is usually a `StatefulSet`.

## Docker Defaults And Service Overrides

The Docker image carries a narrow default `ImageBuildContainer` config so the current build-time commands
can run during the Dockerfile. That baked config declares only build/code-quality and context-init
classes, but it is not a target authority token. The target command additionally requires the
project/spec/config/build/source/builder-bound `BuildInvocationAuthority`. Each returned authority permits
each narrow phase at most once; the concrete channel must separately acknowledge one presentation or durably
consume its `buildId` across verifier calls. An image or backend that cannot do so refuses the attesting build
command. The current derived build has not yet adopted this target seam.

A lifted runtime workflow must not gain authority merely because the image has a baked default file.
Currently, the parent handoff path streams a runtime child `<project>.dhall` into the container
in-place—piped on launch `stdin`, with the entrypoint writing it before dispatch and no host-side bind
mount—through the descent the `context-init` step itself declares. That step's action body still does
not perform the write. The target internal receiver folds both under the one plan node and requires the authenticated
handoff. A direct host invocation without the runtime context and authority fails fast instead of
silently creating a kind cluster on the wrong Docker daemon.

A long-running service has a restartable, non-lifecycle authority path: the chart's `deploy-chart` step
deploys a pod whose entrypoint is **`service run`**, and the pod's descriptive service-role
`<project>.dhall` arrives as a **ConfigMap that overrides the image's baked container config** at the
canonical path. In the target, the broker signs an immutable rollout revision before pods exist; the
platform verifier then pairs that revision with the concrete pod UID/restart count or OS invocation and
mints one inseparable `VerifiedRuntimeRoleActivation` containing the matching
`RuntimeActivationAuthority` and narrowed role-plan projection; the runtime verifier must
match the mounted role-wire bytes through `RoleCodec scope specDigest fields`, verify the private secret
channel, and produce a fresh local verified wire/request
before dispatch. It permits only the leaf `service run`
activation for that rollout revision and measured instance, so expected pod restarts do not require the original
`project up` broker and cannot authorize project lifecycle mutation. The config still must declare a compatible
service role/variant; it cannot mint the runtime authority. The same image therefore serves image-build,
ad-hoc runtime, and service contexts while each container instance reads exactly one local descriptive
file and obtains the matching out-of-band authority class.

The accelerator daemon adds two authority placements:

- in-cluster Linux CPU/GPU daemon pods receive daemon-role configs the same way service pods do, by
  ConfigMap override, and connect to the web service through `ClusterIP`;
- Apple Silicon and Windows GPU host daemons receive a host-resident daemon context and connect to the web
  service through its exact runtime-resolved loopback exposure after `project up` has made it available.

Both are intended leaf roles. A generated daemon context plus independently verified platform/OS-service
instance identity and signed deployment revision can run the daemon handler through
`service run` and lacks the classes intended for project lifecycle. `addRole` refuses to union
orchestration classes into a `Daemon` or `ImageBuildContainer` primary. `validateContext` also derives
placement from the checked topology and refuses a project-lifecycle class at an illegal frame, including
a hand-edited daemon config. That remains descriptive runtime validation, not authority: generic
`authorizeRootProject` independently requires the unique-root lifecycle refinement, rechecks structural
placement, and refuses the daemon shape.
The service-role authority gate and recursive authorization/traversal remain later work.

The test harness obeys the same authority rules without a distinct lifted "TestHarness" path. `test run`
owns a harness-generated root config, admits one exact
`ProjectPlan (Harness projectId runId) ...`, and invokes its fixed root-Up entry/reverse actions,
so assertions execute in the normal host/VM/container frames the plan mints without a lifecycle
subprocess or Production re-entry. A suite may declare **more than one config variant**; the harness stands
each exact plan up, asserts, and tears it down in turn (the demo runs `message = "Hello, world!"` then
`message = "Hello, Universe!"`, with the `message` flowing `<project>.dhall` → binary-rendered `ConfigMap` → the
`Web` service → the SPA `#message`, and the Playwright e2e-tabs assertion polymorphic over the exported
`EXPECTED_MESSAGE`). The five-field `TestSuite` contains only the safety precondition,
assertion-environment opener, case matrix, per-case assertion, and post-reverse absence assertion. The
opaque lifecycle constructor lives in a private Cabal component, so neither descriptive context nor
project assertion code can replace the plan-owned lifecycle actions. The harness refuses an existing
executable-sibling `<project>.dhall` or a running production cluster before mutation, and generated-config
cleanup rechecks both kernel identity and recorded payload before unlinking.

## Config Snapshot And Daemons

`service run` canonically verifies one sibling snapshot, structurally selects one typed role from a
registry finalized with that full codec, and closes the handler action over only its role fields plus a
safe framework view. Demo service handlers do not reopen the sibling file.

`project up|down|destroy` do the same. `withSiblingValidatedProjectConfigRoot` reads and admits the
sibling **once** per invocation and yields the verified wire, the
`ValidatedConfig scope specDigest configId (cfg scope)`, its context, and the canonical root together;
plan construction consumes that byte-stable snapshot, and the chain builder closes every step over it.
Every step keeps that admitted value even when the file changes underneath it; the next invocation
validates a new snapshot under a new `configId`.

The
[step algebra and project plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)'s
finalized-spec and opaque `ProjectPlan` admission path is the Production one-read boundary,
including its pure forward/topology/stable-snapshot, resource/edge, and current-frame projections plus the
exact command-reservation foundation. Generic root-refined `authorizeRootProject` and the hidden root-Up
`LifecycleEntry` are the only root command path. Production dispatch retains or reconstructs
that value and reaches public `HostBootstrap.Chain` plus total `Reconcile.stepExecutionFor` only through the
fixed entry interpreter; its reverse verbs derive work
from the matching plan/current-frame projection. Harness dispatch independently admits the matching
Harness-scoped value and retains it through generated-config ownership while the same common
forward/reverse interpreters run. Recursive children do not receive a parallel store-backed entry. The
[recursive-lifecycle-command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md) instead
adopts projected child plans through the root catalog and storeless frame executor.

What later lifecycle work still adds on top is the closed operation inputs: a
plan-owned projection renders only `RuntimeRoleWire fields service` fields authorized for the child and
binds those exact bytes to the deployment manifest. The child verifies the mounted wire through
`RoleCodec scope specDigest fields`, verifies the separately delivered secret bundle, mints a fresh local
`configId`, and only then obtains
`ValidatedServiceRequest specDigest configId secretDigest fields service` with its
`RoleParams specDigest configId secretDigest fields service`. The
[service runtime phase](../../DEVELOPMENT_PLAN/phase-22-service-runtime.md)'s core-owned
`selectAndRunService` target packages that request with a closed `ServiceProgram` handler and matching
revision/instance/Serve/effect proof;
the parent config identity, full config, unauthorized effect row, and config-read/raw-`IO` escape hatch
cannot cross the service-handler boundary. The current structural role boundary already excludes full
config and config-read authority; raw handler `IO` remains. Finalized plan actions likewise use the
closed effect/descriptors owned by the prepared-operation and cluster lifecycle boundaries rather than
arbitrary config-reading callbacks. No production action reopens the sibling file, and no public raw-root
loader permits it. On-disk
changes affect only a later invocation with a new `configId`; daemons require a new measured
`instanceId` or an explicit
safely designed reconcile, and authority fields are never live-reloaded.

Daemon startup logs should make the active context declaration obvious: project, binary, context kind, role name,
config path, config hash, source root, and resource envelope, plus any version/build metadata. Logs go to
stdout/stderr by default so systemd, Docker, Kubernetes, or incus can collect and rotate them.

## Demo Contexts

The worked demo runs across four execution contexts — the three descent frames (host, VM, project
container) plus the chart-launched service-role pod — each reading its own `<project>.dhall`:

| Context | Role |
|---|---|
| Host | metal-side orchestrator: select the VM provider, size and launch the VM, tear it down behind the guard |
| VM | fresh Linux host: Lima on Apple Silicon, Incus on native Linux, WSL2 on Windows; re-establish the host-native binary and build the project container |
| Container on the VM | lifted workload: interpret `deploy-kind` → `deploy-minio` → `deploy-registry` → `push-image` → `deploy-chart` → `expose-port`, then the topology-selected accelerator-daemon placement |
| Cluster service | chart-launched webservice pod: serve only the service role |
| Accelerator daemon | in-cluster Linux daemon pod or host-resident Apple/Windows daemon: read its daemon-role context, connect to the web service over CBOR WebSocket, and forward requests to the JIT-built worker |

The same `project` command tree exists in each copy of the binary. Each copy reads a different local
`<project>.dhall` and therefore accepts a different subset of commands; `context` visualizes which frame a
given copy occupies.

## Secrets Are Never In The Context

The context is generated, streamed between frames, and read for inspection (`context`), so it must
carry no secret. Docker Hub credentials in particular are **never** a context field: they are an
effect-only runtime capability forwarded ephemerally down the lift (piped on `stdin` / a forwarded
environment value), never represented in Dhall or retained in durable project/image state. See
[registry credentials](../engineering/registry_credentials.md).

## Current Status

[Dhall configuration and project model phase](../../DEVELOPMENT_PLAN/phase-7-dhall-configuration-and-project-model.md) governs the binary-context gate.
Python does not create runtime config. The built binary owns the three config-free writers, static
schema/help output, decode-only inspection, child-config projection, the harness-managed
`test run` config lifecycle under the four § EE ownership clauses of
`HostBootstrap.Harness.GeneratedConfig`, and the
existing-frame gate described in the matrix above. That gate checks project/binary identity, requested
command class/capabilities, selected ancestry, and the required runtime-witness set; observed checked
mismatches fail before command side effects.

The
[step algebra and project plan phase](../../DEVELOPMENT_PLAN/phase-12-step-algebra-and-project-plan.md)
provides a typed plan/context and local lifecycle-authority layer. Static
`ProjectSpec cfg tcfg` remains independent of scope and generative identities; scope finalization yields
`FinalizedProjectSpec scope specDigest cfg`, and admission yields an opaque
`ProjectPlan scope specDigest planId configId cfg`. Its `forward`, `topology`, and `renderSnapshot` views
are implemented pure projections, as are its opaque resource and dependency-edge views.
`withCurrentFrame` jointly generates the matching pure `CurrentFrame`, `ProjectFrame`, and
`ValidatedContext` evidence described above. `ValidatedLifecycleContext` retains their exact root/store and
parent-plan join, and generic `authorizeRootProject` consumes it with the complete matching root, plan,
snapshot, lease, journal, and cursor evidence. Public `HostBootstrap.Chain`
and `HostBootstrap.Reconcile` now consume the exact plan: Chain requires matching execute-phase command
authority and cursor evidence, checks both the authority-to-supplied-store relation and the cursor's
retained store plus decoded acquisition project/store/broker origin before I/O, uses the authority's epoch
and invocation, and derives descent from `DerivedTopology`. Production and Harness `Command` consume that
lower path only through the fixed hidden root-Up entry under their exact scopes.

The [recursive lifecycle command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
consumes `ValidatedLifecycleContext` only inside the root coordinator. It binds canonical root, the one
already-open store, and a root or nested parent plan to one plan-derived frame after command-independent fresh
witness validation. Recursive
catalog projection supplies each storeless target-frame relation structurally through a rank-2 fold; children
receive only authenticated config/recovery packages and rooted protocol responses, never this context or a
local lifecycle cursor.

It validates the complete topology **graph** before authorization
(`HostBootstrap.Context.validateTopology`): unique non-empty frame identifiers, exactly one root, every
non-root parent resolvable, no parent walk revisiting a frame, every frame reachable from the root, legal
child kinds, a provider that can own each frame's kind, and a `parentChain` that agrees with the edges.
The ancestor walk carries a visited set, so a config whose frames name each other as parents fails as a
cycle rather than recursing indefinitely. Validation also requires the declared witness list to be exactly
the closed required set for the current frame's placement; an empty or trimmed list fails.

`service run` additionally rejects a non-leaf primary kind. For project lifecycle verbs,
`validateContext` derives placement from the checked graph and refuses a declared command class at an
illegal frame, including a non-root operator entry. This remains descriptive runtime validation rather
than authority: the public `BinaryContext` record can still be constructed or updated, and
`CurrentFrame`/`ValidatedContext` alone remain non-authorizing. Protected snapshot binding, the
broker-indexed acquisition journal, its root cursor, and generic root `authorizeRootProject` are
implemented. The gate validates the complete retained origins and performs its live
mode/lease/snapshot/acquisition/cursor checks and one-use reservation atomically in one protected entry;
Production `project up` consumes it only through the hidden root-Up `LifecycleEntry`; recursive children use
the separate storeless executor boundary. The
[recursive lifecycle command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md)
composes that substrate with proof-complete
operator/descent authorization and recursive traversal. Dockerfiles bake the narrow
`image-build-container` role; runtime containers receive parent-generated `vm-project-container` configs
**streamed in-place** over the baked file.

**In-place delivery.** Child-config delivery streams the projection in place over the lift's `stdin`
channel, and the descending binary writes it to its own sibling before dispatch. Only the rendered
context-adjusted payload—not a parent-side file—crosses on `stdin`, with no parent-side intermediate
config or config bind-mount for the VM/container frames (the Kubernetes service pod keeps its ConfigMap
override). The payload retains the full demo record and parent envelope, and the child persists it at its
own inspectable sibling path. The target replaces it with a role-specific type.

The implemented context model includes:

- Public `HostBootstrap.Chain` interprets the current frame's exact `ProjectPlan.forward` segment and
  derives each next frame and `LiftContext` from `DerivedTopology`; the declared topologies are a 3-frame
  metal → VM → container VM-backed branch and a 2-frame metal → direct-container native Linux GPU
  branch. Production nested entry currently refuses before effects, so proof-complete traversal of those
  declared descendants remains work in the
  [recursive lifecycle command phase](../../DEVELOPMENT_PLAN/phase-17-recursive-lifecycle-command.md). Child
  creation is internal `project up` work: the VM composite bootstrap projects and delivers independently
  of the announcing `context-init` row, while the container path rides the descent that row itself
  declares. Harness lifecycle setup/teardown stays in-process at the command boundary; only plan-declared
  recursive child descent uses the self-reference lift. The
  default `project init` invocation writes the fresh root config; explicit role/output/policy flags support
  the other current writer uses.
- The read-only `context` command is the single introspection surface: `context inspect` reads the
  sibling, `context show` reads its selected/default file, and `context path` / `context schema` /
  `context render` are static and config-free.
- The `.dhall` is the explicit parameters + context + witness value of a root the chain is a pure function
  of, with structural variation expressed as a root parameter flag.

`project up` uses that context path in the live stack. Demo tests select the exact Harness profile and
`.test_data/<runId>`; their durable-readback case crosses an engine-owned fresh same-run lifecycle generation
without receiving command authority. The phase records in `DEVELOPMENT_PLAN/` own validation status; this
document describes the authority contract.

The accelerator-daemon context substrate is implemented in
`HostBootstrap.Context`: host-resident daemon contexts use host placement, in-cluster daemon contexts use
Kubernetes placement, and the Linux GPU direct container path is represented as an explicit
host-backed project-container topology with a direct Linux GPU witness. The normal VM-backed
project-container path still requires a VM ancestor. Remaining integration validation is tracked in
[the development-plan index](../../DEVELOPMENT_PLAN/README.md).

## See Also

- [composition_methodology](composition_methodology.md) — the canonical home of the chain-is-the-project
  model, the recursive interpreter, and fractal bootstrap that this doc defers to.
- [hostbootstrap_core_library](hostbootstrap_core_library.md) — the Step algebra and the `project`/`context`
  command tree.
- [registry_credentials](../engineering/registry_credentials.md) — why Docker Hub credentials are
  forwarded ephemerally and never placed in the context Dhall.
- [python_haskell_boundary](python_haskell_boundary.md) — Python as the metal-frame instance of the
  fractal bootstrap.
- [dhall_topology](../engineering/dhall_topology.md) — where the binary context fields fit in the Dhall
  configuration model.
