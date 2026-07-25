# Binary Context Configuration

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: [documents-index](../README.md), [python_haskell_boundary](python_haskell_boundary.md), [composition_methodology](composition_methodology.md), [dhall_topology](../engineering/dhall_topology.md), [development plan](../../DEVELOPMENT_PLAN/phase-15-binary-context-config.md)

> **Purpose**: Define the "know your place" authority contract every project binary uses to reason
> explicitly about where it is running in a composed host/VM/container/cluster topology, and the
> read-only `context` command that introspects it.

## TL;DR

- The runtime config file is the executable's sibling `<project>.dhall`. It carries three things:
  **parameters** (the user-owned root settings), **context** (the binary's place in the topology), and
  **witness** (locally checkable facts that prove the process is in that place).
- The role lives inside the Dhall value, not in the filename. The binary has one default lookup rule.
- The recursive `project up` interpreter hands a subcommand off into the next frame; on each handoff the
  child checks its own `.dhall` frame against the runtime and known mismatches **fail fast** (exit code 1)
  before command side effects. The decoded context/capability fields are not yet opaque authority; Phase
  15.9 closes that construction/widening gap.
- The `.dhall` describes parameters and context, never the lift chain shape — the chain is code. The model
  lives in [composition_methodology](composition_methodology.md); this doc defers to it.
- `context` is a **read-only** introspection/visualization command, but its inputs differ by subcommand:
  `inspect` decodes the sibling `.dhall`, `show [FILE]` decodes the selected/default file, and
  `path`/`schema`/`render` use only static binary-owned information. Child context delivery is internal
  `project up` work; no `context` verb does it. The demo's current `context-init` step is only an
  announcement while composite bootstrap/handoff code performs the actual writes; the target plan makes
  those one operation.
- The accelerator daemon reuses this context model: in-cluster Linux daemons receive service/daemon
  configs, while Apple Silicon and Windows GPU host daemons read host-resident daemon configs and connect
  to the cluster through a local-only NodePort.

## The Contract

The project binary is not a blind command receiver. It is the local interpreter of one segment of a pure,
typed global composition. When the recursive interpreter lifts `project up` across a boundary, the callee
still has enough typed information to know which frame of the chain it is responsible for.

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
| **Parameters** | the user (root) | the root settings the chain is a pure function of — CPU, memory, storage, HA replicas, structural flags such as "skip VM, go straight to Docker" |
| **Context** | the parent lifecycle's child projection/delivery | this binary's place in the topology: identity, frames, current frame, capabilities, allowed command classes, and the current raw resource envelope; the target envelope is plan/frame-indexed |
| **Witness** | the same child projection/delivery | locally checkable facts (`runtimeWitnesses`) that let this binary prove it really is in the declared frame |

The `.dhall` never encodes the lift chain itself. The current forward ordering is
`chain :: cfg -> [Step]`, a Haskell value. Frame context and teardown remain separate current inputs; the
target opaque lifecycle plan derives them from the same validated representation (see
[composition_methodology](composition_methodology.md)).
Structural variation (for example, skipping the VM frame to go straight to a Docker frame) is a parameter
flag on the **root** `.dhall`, so the chain stays a pure function of root parameters rather than a second
representation living in config.

### Context Shape

| Field family | Purpose |
|---|---|
| Project identity | project name, binary name, and source root |
| Execution topology | a list of provider-backed frames, their parent links, and the current frame id |
| Context kind | host orchestrator, VM orchestrator, VM project container, image-build container, cluster service, daemon, one-shot job, or test harness |
| Role name(s) | the roles this config requests/declares — a single `<project>.dhall` may declare **more than one** (e.g. project *and* service); the current gate checks descriptive classes/capabilities and the target gate consumes separate opaque authority |
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
frame are unchanged; `addRole` is currently an unchecked union of descriptive classes/capabilities, not
an opaque proof that the resulting combination is coherent. In particular, `service run` still performs
an explicit primary-kind check and accepts only `ClusterService` or `Daemon`, so a host-orchestrator
primary widened with `ServiceCommand` is rejected. `project up`, `project down`, and `project destroy`
have no matching root-kind/empty-parent check: their class-only gates let a `Daemon`,
`ImageBuildContainer`, or other leaf widened with the relevant orchestration class pass. Active
[Phase 15's opaque-authority repair](../../DEVELOPMENT_PLAN/phase-15-binary-context-config.md)
replaces raw widening with opaque role-specific command authorities and smart constructors that reject
incompatible primary-kind/command-class combinations.

One target API shape makes the compatibility relation and exact invocation state explicit:

```haskell
data ProjectUp
data ProjectDown
data ProjectDestroy
data ServiceRun
data CheckCode
data ProjectVerb verb -- closed singleton

data ProjectFrame scope specDigest planId configId frame
  -- hidden plan-local proof; only legal orchestration frame kinds have constructors
data ServiceFrame frame -- hidden proof; only ClusterService and Daemon have constructors
data LifecycleCursor scope planId frame verb phase -- constructor hidden
data RoleCursor scope planId frame instanceId phase -- constructor hidden
data BrokerEpoch brokerGeneration
data BuildEpoch buildId
data CommandAuthority scope planId frame authorityEpoch verb phase -- constructor hidden
  -- project/build commands use BrokerEpoch or BuildEpoch; runtime services use the distinct
  -- VerifiedRuntimeRoleActivation + RoleLifecycleAdmission + ServiceCommandAuthority path below
data PlanDigestBinding scope specDigest planDigest planId -- constructor hidden
data VerifiedConfigWire scope configDigest configId -- constructor hidden
data ConfigHandoff
data RecoveryHandoff
data VerifiedHandoff
  scope planDigest brokerGeneration parentFrame childFrame
  payloadKind payloadId verb phase -- constructor hidden
data RecoveryWireDigest
data VerifiedRecoveryWire
  scope planDigest frame recoveryWireDigest recoveryWireId -- constructor hidden
data RecoveryProjectionBinding
  scope planDigest parentFrame childFrame recoveryWireDigest -- constructor hidden
data RuntimeRoleWire fields service
data RuntimeRoleWireBytes
data ProductionConfigWire
data LocalWireKind = FullProjectWire | RuntimeRoleWireKind
data FrameworkEnvelopeCodec scope specDigest fields -- constructor hidden
data LocalContextView scope specDigest wireKind frame -- constructor hidden; no role parameters or authority
data LocalWireBytes
data ProjectCodec scope specDigest cfg -- constructor hidden
data FinalizedProjectSpec scope specDigest cfg fields
  -- constructor hidden; contains matching project/envelope/runtime codecs and registries
data FinalizedSchemaFamily projectId specDigest cfg fields
  -- constructor hidden; contains the named Production/Harness envelope+codec families
data DescriptiveScopeKind scope -- closed ProductionWire | HarnessWire discriminator in the envelope
data DisplayedScope scope -- constructor hidden; display-only, never authority
data RoleCodec scope specDigest fields -- constructor hidden
data ValidatedServiceRequest specDigest configId secretDigest fields service -- constructor hidden
data RoleParams specDigest configId secretDigest fields service -- constructor hidden
data FinalizedServiceRegistry specDigest fields -- constructor hidden
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
data PinnedProjectVerificationKey scope -- constructor hidden
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
  :: PinnedProjectVerificationKey scope
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
  :: PinnedProjectVerificationKey scope
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

withRecoveredProjectFrame
  :: BoundPlanSnapshot scope specDigest planDigest planId
  -> PlanDigestBinding scope specDigest planDigest planId
  -> RehydratedResourceSet
       scope planDigest planId brokerGeneration requiredResourceSet
  -> TeardownAuthorizationPoint scope planId verb frame childSet next
  -> (RecoveredProjectFrame scope planId frame -> a)
  -> Either TeardownError a

authorizeProjectUp
  :: RootInvocationAuthority scope brokerGeneration ProjectUp
  -> ProjectVerb ProjectUp
  -> VerifiedPlanSnapshot scope specDigest planDigest
  -> PlanDigestBinding scope specDigest planDigest planId
  -> BoundRunLease scope specDigest planDigest brokerGeneration
  -> ProjectPlan scope specDigest planId configId cfg
  -> ProjectFrame scope specDigest planId configId frame
  -> LifecycleCursor scope planId frame ProjectUp phase
  -> ValidatedContext scope planId frame
  -> IO
       (Either
          AuthorityError
          (CommandAuthority
             scope planId frame (BrokerEpoch brokerGeneration) ProjectUp phase))

withChildProjectPlan
  :: ProjectVerb verb
  -> VerifiedHandoff
       scope planDigest brokerGeneration parentFrame frame
       ConfigHandoff configId verb phase
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

authorizeChildProject
  :: ProjectVerb verb
  -> ChildPlanAuthority
       scope specDigest planDigest brokerGeneration parentFrame frame
       planId configId verb phase
  -> ProjectPlan scope specDigest planId configId cfg
  -> ProjectFrame scope specDigest planId configId frame
  -> LifecycleCursor scope planId frame verb phase
  -> ValidatedContext scope planId frame
  -> IO
       (Either
          AuthorityError
          (CommandAuthority
             scope planId frame (BrokerEpoch brokerGeneration) verb phase))

authorizeRecoveryTeardown
  :: TeardownVerb verb
  -> RootInvocationAuthority scope brokerGeneration verb
  -> BoundPlanSnapshot scope specDigest planDigest planId
  -> BoundRunLease scope specDigest planDigest brokerGeneration
  -> RecoveredProjectFrame scope planId frame
  -> TeardownAuthorizationPoint scope planId verb frame childSet next
  -> IO
       (Either
          AuthorityError
          (CommandAuthority
             scope planId frame (BrokerEpoch brokerGeneration) verb TeardownPhase))

authorizeRecoveredChildTeardown
  :: TeardownVerb verb
  -> VerifiedHandoff
       scope planDigest brokerGeneration parentFrame frame
       RecoveryHandoff recoveryWireId verb TeardownPhase
  -> VerifiedRecoveryWire
       scope planDigest frame recoveryWireDigest recoveryWireId
  -> RecoveryProjectionBinding
       scope planDigest parentFrame frame recoveryWireDigest
  -> BoundPlanSnapshot scope specDigest planDigest planId
  -> BoundRunLease scope specDigest planDigest brokerGeneration
  -> RecoveredProjectFrame scope planId frame
  -> TeardownAuthorizationPoint scope planId verb frame childSet next
  -> IO
       (Either
          AuthorityError
          (CommandAuthority
             scope planId frame (BrokerEpoch brokerGeneration) verb TeardownPhase))

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

authorizeBuild
  :: BuildSessionGrant
       projectId specDigest coordinatorBinaryDigest builderBinaryDigest
       configDigest buildId sourceDigest
  -> ProjectCodec (Production projectId) specDigest cfg
  -> ProductionConfigWire
  -> VerifiedBuildBinaryIdentity
       projectId coordinatorBinaryDigest builderBinaryDigest
  -> VerifiedSourceContext projectId sourceDigest
  -> BuildCursor buildId BuildPhase
  -> (forall configId frame.
        VerifiedConfigWire (Production projectId) configDigest configId
        -> ValidatedConfig
             (Production projectId) specDigest configId (cfg (Production projectId))
        -> ImageBuildFrame projectId specDigest configId frame
        -> BuildInvocationAuthority
             projectId specDigest configId buildId sourceDigest builderBinaryDigest
        -> IO a)
  -> IO (Either AuthorityError a)

authorizeBuildCheck
  :: BuildInvocationAuthority
       projectId specDigest configId buildId sourceDigest builderBinaryDigest
  -> ImageBuildFrame projectId specDigest configId frame
  -> IO
       (Either
          AuthorityError
          (CommandAuthority
             (ImageBuildScope projectId) buildId frame (BuildEpoch buildId)
             CheckCode BuildPhase))

data OverwritePolicy
  = RefuseExisting
  | KeepExisting
  | ReplaceExisting

data InitRequest frame -- constructor hidden
rootProjectInit  :: RootInitArgs -> InitRequest HostOrchestrator
imageBuildInit   :: ImageBuildArgs -> InitRequest ImageBuildContainer
data ServiceInitRequest scope specDigest fields
  -- constructor hidden; existential service plus legal leaf placement under one finalized field row
clusterServiceInit
  :: FinalizedProjectSpec scope specDigest cfg fields
  -> ServiceInitArgs
  -> Either InitError (ServiceInitRequest scope specDigest fields)
daemonServiceInit
  :: FinalizedProjectSpec scope specDigest cfg fields
  -> ServiceInitArgs
  -> Either InitError (ServiceInitRequest scope specDigest fields)
data TestInitRequest -- constructor hidden
```

The parser may return an existential validated request, but there is no public generic record containing
arbitrary primary kind + role list + command-class list. Added project metadata may coexist with service
parameters, yet only `ServiceFrame` can authorize `ServiceRun` and only `ProjectFrame` can authorize a
closed `ProjectVerb`. `RootInvocationAuthority scope brokerGeneration verb` comes from the independent
OS/project root
gate, not from decoded context, so there is no authority → lifecycle profile → transition → authority
cycle. The plan/cursor/context parameters bind the exact plan, frame, authority epoch, verb, and
lifecycle phase; an `up` authority cannot call `down`, a stale phase cannot call the same verb again,
and another Production plan's context cannot be substituted. Its broker-generation index must match the
bound lease, so an authority retained from one opener cannot be paired with another invocation's lease.
Each hidden value also carries a one-use invocation identity. Because ordinary Haskell values are not
linear, each `authorize*` gate is effectful: it atomically reserves the exact unconsumed invocation
record while checking the live cursor/epoch. The operation-session opener also requires the exact
current broker's session-admission proof before it changes that same record to Open, and the prepare
dispatcher revalidates every index plus the current journal/session versions; retaining the value
cannot open two sessions or repeat an effect.

`withChildProjectPlan` is the normal recursive child planning gate. It consumes the closed
`ProjectVerb`, exact config-kind verified handoff/wire, validated child config, and project plan draft;
inside one rank-2 continuation it verifies the stable plan digest and jointly returns the fresh local
plan, binding, and exact `ChildPlanAuthority`. It never yields `RootScopeAuthority`,
`HarnessAuthority`, a Production value from a Harness handoff, or signing/delegation authority.
`authorizeChildProject` consumes that child-plan authority with the matching frame/cursor/context, so
plan construction no longer requires authority that only the later command gate could mint.
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
`withVerifiedRuntimeRoleActivation` consumes a pinned project verification key, independently measured
platform workload/OS-service and binary/image identity, and the signed manifest bytes; only its rank-2
continuation receives one opaque
`VerifiedRuntimeRoleActivation scope planDigest specDigest binaryDigest frame revision instanceId
configDigest secretDigest service rolePlanDigest permittedEffects`. Its matching
`RuntimeActivationAuthority`, `VerifiedRuntimeRolePlanProjection`, and private-channel locator cannot be
separated or paired from different manifests/instances. Each restart verifies the actual narrowed mounted
bytes through the matching
`FinalizedRuntimeSpec scope specDigest fields` (which inseparably carries its
`RoleCodec scope specDigest fields` and registry) and the matching verified secret bundle, creates a fresh local
`configId`, and returns the generic verified wire plus an existential
`ValidatedServiceRequest specDigest configId secretDigest fields service` in one continuation. Runtime
promotion mints no `HarnessConfigAuthority`; that authority remains confined to root assembly and normal
config handoff. The restart neither replays a consumed edge handoff nor requires the old CLI broker. The
activation package's signed manifest member contains a narrowed, non-secret role-plan projection
with its own `rolePlanDigest` and a proof binding it to the parent `planDigest`; the child never claims it
can recompute the full lifecycle-plan digest from narrowed inputs. Platform/manifest verification yields
`VerifiedRuntimeRolePlanProjection scope planDigest specDigest binaryDigest frame revision instanceId
configDigest secretDigest service rolePlanDigest permittedEffects`. Before any prerequisite or acquisition,
`verifyRolePlanDraft` first validates the non-empty local draft and its signed `rolePlanDigest` without
opening durable state. `withRoleLifecycleAdmission` is then the sole protected producer of a role
admission. It binds that verified draft, the exact activation, fresh local `configId`, request, signed
plan/effect ceiling, service, revision, and measured instance to fresh rank-2
`planId`/`invocationId` identities, and atomically writes the first durable role-journal version before returning
`RoleLifecycleAdmission ... planId configId ... invocationId admissionKey admissionVersion`.
`admissionKey` is deterministically bound to the verified activation/request/draft identity; the
protected row moves only `AdmissionReserved → AdmissionConsumed`. A lost reservation acknowledgment
yields `RoleLifecycleAdmissionUnknown`, and either
`resumeRoleLifecycleAdmissionUnknown` or the same exact opener rehydrates the already stored
`planId`/`invocationId` under that key rather than allocating another. The current instance's own
Reserved row is never classified as a non-live predecessor. `withRuntimeRolePlan` linearly consumes the
exact Reserved admission and verified draft in a CAS to Consumed; concurrent duplicate rehydrated tokens
have one winner. If that CAS commits before plan/cursor delivery is acknowledged, the only result is
`RolePlanOpenUnknown`; `resumeRuntimeRolePlanOpen` rehydrates the same stored
`planId`/`invocationId`/plan-open version and delivers its sole cursor rather than consuming a new
admission. The exact opener also classifies a same-activation Consumed row into that branch, so a crash
does not strand it or misclassify it as predecessor recovery. The gate performs no independent
reservation, has no remaining draft/digest failure, and its callback is fixed to the admission's
`planId`. Retaining the activation, wire, request, or raw draft therefore cannot mint another
plan/cursor. The gate
reconstructs only a
`RolePlan scope specDigest planId configId secretDigest frame revision instanceId`, checks the local
role-plan digest, and jointly returns
`RolePlanDigestBinding scope specDigest planDigest rolePlanDigest planId` plus
`VerifiedServicePlacement scope specDigest planId frame revision instanceId service permittedEffects`
and the sole initial Prereq cursor inside the fresh `planId`; it cannot construct a lifecycle
`ProjectPlan`. The role lifecycle then acquires and probes instance-indexed managed
listener/connection/worker handles; only a successful probe yields opaque `ReadyServiceHandles` for those
exact identities. A restartable worker is represented by a stable, readiness-probed supervisor handle
rather than a child PID. Only a core-owned, journal-prepared supervisor transition may replace its child,
and it must probe the successor child before routing another request; handler code receives no
spawn/rebind operation. `selectAndRunService` jointly consumes the role plan,
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

`authorizeBuild` verifies the supplied bytes with the project-owned, pointer-only Production
`ProjectCodec`, bridges the signed
build session's stable config digest to a fresh local `configId`, and checks the independently measured,
project-indexed source/context digest. The signed grant also binds the finalized `specDigest`, coordinator
binary identity, and exact builder binary/image identity; those indices remain on the image-build frame
and invocation authority, so an upgraded codec or builder cannot replay a same-config/source grant. It
returns the verified wire, validated Production config, and
matching validated image-build frame, and build authority only inside one rank-2 continuation.
`ImageBuildScope projectId` is the command-authority
scope, not a third secret/config scope; the grant and `Production projectId` wire keep identical bytes
from another installed project from satisfying it. `authorizeBuildCheck`
can then mint only
the image-build-frame `CheckCode`/`BuildPhase` command authority. A normal developer's `check-code`
remains the existing sibling-config-gated, existing-frame, non-attesting quality path. Its project-owned
`psCheckCode :: IO ()` action is non-lifecycle by contract/convention, not mechanically read-only or
effect-restricted; it carries no build attestation and cannot authorize lifecycle or release claims.
Positive construction tests must pass the jointly returned frame to `authorizeBuildCheck`; negative
fixtures substitute the same-role frame from another config/project or a non-image-build role and prove
neither type-checks or dispatches. Cross-spec and cross-builder same-config/source fixtures fail too.

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
      , resourceEnvelope : { cpu : Natural, memory : Text, storage : Text }
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

`hostbootstrap-core` currently checks a subset of invariants after decoding: the selected `currentFrame`
must be found, the ancestry traversed from it must resolve, the config must declare the command class and
required capabilities, and each **supplied** witness must pass its local verifier. It does not reject
duplicate IDs, disconnected/orphan frames, `parentChain` disagreement, illegal child/provider/role
relations, or all cycles, and it does not require a provider/kind-specific witness set. An empty witness
list can therefore pass vacuously. Higher layers extend `ProviderKind`, role payloads, and witness
constructors when they introduce new providers.

These checks make invalid combinations explicit **runtime validation failures**; they do not make those
combinations unrepresentable. The decoded representation still contains `Text` identifiers and ordinary
lists, its capability constructors are public data, and a caller can construct or hand-edit a context that
claims classes/capabilities it did not acquire. A workflow that declares itself to be a VM project
container is rejected when a supplied parent/frame reference or Docker/container witness is checked and
fails, but omission is not currently rejected.

The target decodes into an untrusted `BinaryContextDraft`, validates the complete graph, and returns an
opaque `ValidatedContext scope planId frame` whose constructor is unavailable to consumers. Frame
identifiers are typed, topology is non-empty and derived from the same opaque
`ProjectPlan scope specDigest planId configId cfg` as the lifecycle, and command authority is minted only from the
independent root/runtime authority plus the exact plan cursor and validated context, then consumed by the
command gate and matching journal transition. Commands accept the opaque validated value rather than raw
decoded fields. At that boundary a missing parent, widened capability, production/test-profile mismatch,
wrong verb/phase, or authority for a different plan/frame cannot be supplied as an input.
Negative API fixtures must also prove the recursive child gate cannot be instantiated with `ServiceRun`
or `CheckCode`, even if an internal cursor or malformed draft carries the same textual label.
Validation requires unique IDs, one root, one resolvable parent per non-root, connectivity, acyclicity
with terminating traversal, exact `parentChain` agreement, one reachable current frame, and legal
child-kind/provider/role relations. A closed required-witness function derives the exact evidence set
for that placement; missing, duplicate, irrelevant, contradictory, or false witnesses cannot mint
`ValidatedContext`.

Across a process boundary, the target does not serialize authority into sibling Dhall. The independently
authorized **root invocation** owns the profile-specific broker and unbound/bound run lease; its protected private signing
key is the trust root, while each binary has the project public verification key installed independently
of config. Immediate parents relay a private duplex session to that root broker; they receive no signing
or delegation key. The root sends a length-delimited offer containing the narrowed config wire and
one-time token bound to the exact plan revision, broker generation, child identity/frame, verb/phase,
and child config digest. The **binary's internal receiver**, replacing the current container shell writer, returns a
fresh challenge. The root broker consumes the lease nonce and authenticates a grant over that challenge
and all bound fields; grant plus byte verification creates a fresh child `configId`, generic
`VerifiedConfigWire`, and exact `VerifiedHandoff ... ConfigHandoff ...` required for
promotion/dispatch. A recorded transcript,
replay, truncation, or config/token mismatch cannot produce those values. Neither payload appears in
`argv` or the environment, and the token is never a Dhall field.

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
remains descriptive after it is written. Phase 15.9 coordinates this envelope/receiver and
installed trust anchor with Phase 10.9's broker/lease ownership and Phase 16.6's recursive persistence
and recovery.

## Per-Frame Fail-Fast On Handoff

The recursive interpreter descends frame by frame: each frame runs its chain steps, then hands off
`<project> project up` into the next frame (see [composition_methodology](composition_methodology.md) for
the fractal-bootstrap pattern). The binary-context gate is the precondition on each handoff.

Commands that operate on an existing project frame — `project up|down|destroy`, `service run`, and
`check-code` — start by loading the sibling config and fail fast with exit code 1 when:

- `<project>.dhall` is absent;
- the Dhall does not decode against the binary's config/context schema;
- the config names a different project or binary;
- the config does not declare the requested command class;
- the context does not declare the capabilities the requested command requires;
- a supplied local runtime witness cannot be verified.

Current validation does not reject an omitted required witness because it has no closed required-set
relation. It also validates only the selected ancestry, not the complete topology graph; those are
Sprint 15.9 targets.

The implemented config-input matrix is:

| Surface | Current config behavior |
|---|---|
| Help output | Config-free |
| `project init`, `service init`, `test init` | Config-free writers |
| `service schema`, `context path`, `context schema`, `context render` | Static and config-free |
| `context inspect` | Reads and decodes the executable-sibling `<project>.dhall`; no command-authority gate |
| `context show [FILE]` | Reads and decodes the selected file, or its parser default when `FILE` is omitted; no command-authority gate |
| `test run <case-id>\|all` | Reads `<project>.test.dhall`, refuses an existing sibling `<project>.dhall`, then writes each run variant behind the current cooperative sidecar lock and removes it only when the bytes still match; Phase 10.9 owns resource-authoritative reservations and verified receipts, Sprint 15.9 owns opaque root/command authority, and Sprint 17.4 makes this parser route require it |
| `project up\|down\|destroy`, `service run`, `check-code` | Read the sibling `<project>.dhall` and apply the existing-frame command gate |

This distinction matters: neither read-only inspection nor a config-free writer is evidence that the
whole `context` or init surface carries runtime authority. `service run` adds the leaf-kind check described
above; `project up|down|destroy` rely on declared command classes without the exact root-placement gate,
which is the widening defect owned by Sprint 15.9.

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
legacy overlapping shape returns an explicit unknown/ambiguous display result; it never guesses by
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
but the current demo does not yet make that step the effect owner: its action only announces the
boundary. VM config is rendered/streamed inside the composite VM bootstrap/build-pb action, while the
container payload is derived through `psFrameContext` and delivered during handoff. That independent
representation can drift. The target opaque plan makes child projection, authenticated delivery, and the
single `context-init` node one validated operation:

1. Python currently discovers the Cabal-file stem and sole executable stanza separately, builds
   `./.build/<executable>`, and invokes the requested command (POSIX process replacement with `exec`;
   Windows child subprocess). It writes no Dhall and does **not** initialize config; it is the metal-frame
   instance of the fractal bootstrap. The program/config identity is supplied independently by the
   Haskell entrypoint until the opaque identity repair lands.
2. `project init` is a config-free writer. With no role/output/policy flags it is the **fresh-root
   default**: write the executable-sibling `<project>.dhall` as a host orchestrator with no parent and
   refuse an existing output. The current parser also supports `--role ROLE`, repeatable
   `--also-role ROLE`, `--output FILE`, `--force`, and `--if-missing` (plus the project parameter
   overrides): `--force` overwrites, `--if-missing` leaves an existing file untouched, and when both are
   present the current implementation gives `--force` precedence. This shared, permissive `InitArgs`
   shape is descriptive current behavior, not the target authority boundary. Active
   [Phase 17's exact-command-semantics repair](../../DEVELOPMENT_PLAN/phase-17-chain-driven-test-and-context-introspection.md)
   owns opaque writer-specific init requests and an explicit overwrite-policy type; Sprint 15.9 owns
   validation that requested role combinations can mint only compatible command authorities. Because
   Python never creates config, an existing-frame command run before an initializer or harness-generated
   config finds no sibling file and **fails fast** (exit 1).
3. During current demo `project up`, composite bootstrap/handoff code generates the child
   `<project>.dhall` from passed/forwarded parameters; the separately rendered `context-init` node does
   not perform that effect. In the target, the plan-owned node performs the parameterized child
   projection and authenticated handoff, names the child frame, and includes only locally verifiable
   witnesses.
4. The project Dockerfile currently bakes a context-adjusted full `image-build-container` config at
   `/usr/local/bin/<project>.dhall` so build-time commands (`check-code`, static code generation, web
   asset compilation) can pass the descriptive context gate during the image build. The target does not
   treat that file as authority: the build orchestrator also supplies an ephemeral
   `BuildInvocationAuthority projectId specDigest configId buildId sourceDigest builderBinaryDigest`
   through the build engine's
   secret/session channel and records the terminal outcome. This binds inputs known before the image
exists; the resulting image digest is recorded afterward. Runtime parents currently stream a
context-adjusted full config record in-place on launch `stdin`; the demo retains every project field and
the full resource envelope. The target internal receiver accepts a
role-specific payload only with a verified root-broker grant. A
   Kubernetes service or daemon pod instead receives descriptive config as a ConfigMap override plus the
   platform identity described below.
5. A current service or daemon receives a context-adjusted full demo config from the controller or
   launcher that owns identity and durable placement. The target receives a role-specific parameter
   payload. For stateful Kubernetes services that controller is usually a `StatefulSet`.

## Docker Defaults And Service Overrides

The Docker image carries a narrow default `ImageBuildContainer` config so the current build-time commands
can run during the Dockerfile. That baked config declares only build/code-quality and context-init
classes, but it is not a target authority token. The target command additionally requires the
single-use, project/spec/config/build/source/builder-bound `BuildInvocationAuthority`; an image or backend that
cannot receive and acknowledge it refuses the build command.

A lifted runtime workflow must not gain authority merely because the image has a baked default file.
Currently, the parent handoff path derives through `psFrameContext` and streams a runtime child
`<project>.dhall` into the container in-place—piped on launch `stdin`, with the entrypoint writing it
before dispatch and no host-side bind mount. The separately named `context-init` action does not own that
write. The target internal receiver folds both under the one plan node and requires the authenticated
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
  service through a local-only NodePort after `project up` has made the endpoint available.

Both are intended leaf roles. A generated daemon context plus independently verified platform/OS-service
instance identity and signed deployment revision can run the daemon handler through
`service run` and lacks the classes intended for project lifecycle. That is not yet an unforgeable invariant:
`addRole` can union orchestration classes into a `Daemon` or `ImageBuildContainer` primary, and
`project up|down|destroy` currently have no exact root-placement check. Sprint 15.9 closes that widening path with opaque
role-specific authority and compatible-role smart constructors.

The test harness obeys the same authority rules without a distinct lifted "TestHarness" path: `test run`
runs the **real `project up`** under a harness-generated root config, so its assertions execute in the
normal host/VM/container frames the chain mints. A suite may declare **more than one config variant**; the
harness stands each up, asserts, and tears it down in turn (the demo runs `message = "Hello, world!"` then
`message = "Hello, Universe!"`, with the `message` flowing `<project>.dhall` → binary-rendered `ConfigMap` → the
`Web` service → the SPA `#message`, and the Playwright e2e-tabs assertion polymorphic over the exported
`EXPECTED_MESSAGE`). Two preconditions reduce known collision risk — the harness refuses if the
executable-sibling `<project>.dhall` (`siblingProjectConfigPath`, i.e. `.build/<project>.dhall`) already
exists (it would overwrite a real config) or if a production cluster is running (it would touch production
state). They do not establish isolation: demo plan resolution currently selects Production/`.data`, and
the parser does not enforce the documented root gate. Generated-config compare-before-delete is
implemented; complete lifecycle ownership is not.

## Config Snapshot And Daemons

The core gate reads a config for initial dispatch, but current execution is not a read-once snapshot.
`project up` derives `chain`/frame context from that first value while many demo `Step` actions reopen the
sibling path; `service run` selects a handler from its first value while both handlers reopen the file.
A replacement can therefore combine plan/selector A with resources or handler settings B.

The target canonicalizes the parent config once and mints
`ValidatedConfig scope specDigest configId (cfg scope)` plus its digest, then injects that exact value into plan
construction and closed operations that need it. A
plan-owned projection renders only `RuntimeRoleWire fields service` fields authorized for the child and
binds those exact bytes to the deployment manifest. The child verifies the mounted wire through
`RoleCodec scope specDigest fields`, verifies the separately delivered secret bundle, mints a fresh local
`configId`, and only then obtains
`ValidatedServiceRequest specDigest configId secretDigest fields service` with its
`RoleParams specDigest configId secretDigest fields service`. The core-owned
`selectAndRunService` packages that request with a closed `ServiceProgram` handler and matching
revision/instance/Serve/effect proof;
the parent config identity, full config, unauthorized effect row, and config-read/raw-`IO` escape hatch
cannot cross the service-handler boundary. Finalized plan actions likewise use the closed effect/descriptors owned by
Sprints 9.10/16.6/19.8 rather than arbitrary config-reading callbacks. No production action can reopen
the sibling file through the target public API. On-disk
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

[Phase 15](../../DEVELOPMENT_PLAN/phase-15-binary-context-config.md) governs the binary-context gate.
Python does not create runtime config. The built binary owns the three config-free writers, static
schema/help output, decode-only inspection, child-config projection, the harness-managed
`test run` config lifecycle under its current cooperative sidecar/matching-byte guard, and the
existing-frame gate described in the matrix above. That gate checks project/binary identity, requested
command class/capabilities, selected ancestry, and supplied runtime witnesses; observed checked
mismatches fail before command side effects. It does not validate the complete graph or require a
complete witness set. `service run` additionally rejects a non-leaf primary kind.
`project up|down|destroy` do not perform the exact root-placement check, so unchecked `addRole` widening
can let a leaf primary pass incorrectly. Because capability/witness constructors and record-update paths are not yet fully
hidden, this is not an unforgeable proof of authority. Sprint 15.9 makes command gates consume opaque
role-specific capabilities minted by validated transitions and prevents incompatible role/class
construction. Dockerfiles bake the narrow `image-build-container` role; runtime containers receive
parent-generated `vm-project-container` configs **streamed in-place** over the baked file.

**In-place delivery.** Child-config **delivery** was refined from build-then-copy
(the VM's host-side `.vm.dhall` copied in) and build-then-mount (the VM's `.runtime-container.dhall`
bind-mounted in) to **streaming the projection in-place over the lift's `stdin` channel**, written by the
descending binary to its own sibling before dispatch. Only the rendered context-adjusted payload—not a
parent-side file—crosses on `stdin`, with no parent-side intermediate config or config bind-mount for the
VM/container frames (the Kubernetes service pod keeps its ConfigMap override). That current payload
retains the full demo record and parent envelope, and the child persists it at its own inspectable sibling
path. The target replaces it with a role-specific type. The superseded
build-then-copy/mount surfaces are tracked in
[legacy-tracking-for-deletion.md](../../DEVELOPMENT_PLAN/legacy-tracking-for-deletion.md).

The implemented context model includes:

- The recursive `project up` interpreter interprets the selected `[Step]` chain across a 3-frame
  metal → VM → container descent on VM-backed branches or a 2-frame metal → direct-container descent on
  native Linux GPU. Child creation is internal `project up` work: VM composite bootstrap and container
  `psFrameContext`/lift paths currently project and deliver independently of the announcing
  `context-init` row. The target plan unifies those paths. The default `project init` invocation writes
  the fresh root config; explicit role/output/policy flags support the other current writer uses.
- The read-only `context` command is the single introspection surface: `context inspect` reads the
  sibling, `context show` reads its selected/default file, and `context path` / `context schema` /
  `context render` are static and config-free.
- The `.dhall` is the explicit parameters + context + witness value of a root the chain is a pure function
  of, with structural variation expressed as a root parameter flag.

`project up` uses that context path in the live stack. Current `down`/`destroy` are not recursive
child-to-parent interpretations, and current demo tests select Production/`.data`. The phase records in
`DEVELOPMENT_PLAN/` own validation status; this document describes the authority contract.

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
