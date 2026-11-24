{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The opaque validated step/plan algebra.

A project may construct steps only through the smart constructors below and may
hand an interpreter only a validated 'StepPlan'. Core and project identities are
different constructors, rendered labels never select behavior, every step
carries an explicit reverse policy, and validation preserves the declared order
or rejects the plan before effects.

The plan is also where the chain's **descent** and its **reverse** live (§ W).

A step declares with 'descendsVia' how its frame reaches the next frame, and
that one 'LiftContext' carries both the provider dispatch and the child-config
projection streamed on the handoff @stdin@ (§ X). Because exactly one step of
every frame but the innermost must declare it, the step that announces the child
config and the value that delivers it are the same plan node — a @context-init@
label can no longer disagree with an independently supplied projection.

A step declares with 'reversedBy' the effect that releases what it acquired, so
the node that creates a resource is the node that removes it. @project down@ and
@project destroy@ are then two verb-indexed projections of this same plan
("HostBootstrap.Teardown") rather than a whole-project hook beside it, and a
@PreserveOnReverse@ step enters neither.
-}
module HostBootstrap.Step (
    -- * Frames
    StepFrame (..),

    -- * Identities and policies
    CoreStepId (..),
    ProjectStepId,
    projectStepId,
    StepIdentity (..),
    ReversePolicy (..),
    StepImplementationRevision,
    mkStepImplementationRevision,
    stepImplementationRevisionNumber,
    initialStepImplementationRevision,
    implementedAt,
    stepImplementationRevision,
    StepReverseAdapterRevision,
    mkStepReverseAdapterRevision,
    stepReverseAdapterRevisionNumber,
    initialStepReverseAdapterRevision,
    reverseAdapterAt,
    stepReverseAdapterRevision,
    OperationKey,
    operationKeyText,

    -- * Plan-owned projected operations
    projectsOperation,
    stepProjectedOperations,

    -- * Plan-authored provider resources
    ProviderResourceDeclaration,
    providerResourceAtCurrentFrame,
    providerResourceAtImmediateChild,
    declaresProviderResource,
    stepProviderResourceDeclarations,
    providerResourceDeclarationTargetsChild,
    ProviderProbeDescription (..),
    declaresProviderProbe,
    stepProviderProbeDescriptions,
    ShareProbeDescription (..),
    declaresShareProbe,
    stepShareProbeDescriptions,
    AliasProbeDescription (..),
    declaresAliasProbe,
    stepAliasProbeDescriptions,
    ClusterObjectProbeDescription (..),
    declaresClusterObjectProbe,
    stepClusterObjectProbeDescriptions,
    declaresEmptyChildFrame,
    stepEmptyChildFrames,
    DelayedEffectGuarantee (..),
    RecoveryObservation (..),
    RecoveryObserver,
    mkRecoveryObserver,
    recoveryObserverIdentity,
    recoveryObserverRevision,
    observesRecoveryWith,
    stepRecoveryObserver,
    BoundRecoveryObservation,
    boundRecoveryObservationResult,
    observeStepRecovery,
    admitRecoveryObservation,

    -- * Plan-authored chart workload declaration
    declaresChartWorkloadResource,
    stepChartWorkloadResourceDeclarations,

    -- * Plan-authored service activation declarations
    declaresServiceActivation,
    stepServiceActivationDeclarations,

    -- * Opaque steps
    Step,
    StepAction,
    EffectPreflight,
    declaresEffectPreflight,
    stepEffectPreflight,
    StepObservation (..),
    observationSucceeded,
    observationDetail,
    conflictObservationMarker,
    unsupportedObservationMarker,
    refusedObservationMarker,
    StepKind,
    stepLabel,
    stepFrame,
    stepKind,
    stepKindName,
    stepIdentity,
    stepReversePolicy,
    stepOperationKey,
    runStep,
    isDeployKindStep,
    isDeployVMStep,
    isPostHandoffStep,
    renderStep,

    -- * Plan-owned descent
    descendsVia,
    stepDescents,
    frameDescent,

    -- * Plan-owned reverse
    TeardownAction (..),
    TeardownOutcome (..),
    reversedBy,
    reversedByAt,
    stepReverses,
    stepReverse,

    -- * Opaque validated plans
    StepPlan,
    StepPlanError (..),
    mkStepPlan,
    stepPlanSteps,
    renderChainPlan,
    stepsForFrame,
    preHandoffStepsForFrame,
    postHandoffStepsForFrame,
    chainFrames,
    stepDependencies,

    -- * Core host-management step constructors
    deployVMStep,
    ensureStep,
    copySourceStep,
    buildPbStep,
    buildImageStep,
    contextInitStep,
    deployKindStep,
    deployChartStep,
    exposePortStep,
    postHandoffStep,

    -- * Project-extension seam
    projectStep,
)
where

import Data.Kind (Type)
import Data.List (elemIndex, group, isPrefixOf, sort)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.List.NonEmpty as NonEmpty
import Control.Exception (SomeException, displayException, try)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Execution (StepExecution)
import HostBootstrap.Lift.Context (LiftContext)
import System.FilePath (isAbsolute)
import qualified System.FilePath.Posix as Posix

{- | What a step's forward action receives (§ U).

Not a bare 'HostConfig'. The action is handed the plan-minted
'StepExecution' — the host-tool configuration together with the exact plan,
operation, and frame identities the step is running under — so a step that must
prepare an effect can name its own node instead of reconstructing it. The
descriptor has no public constructor, so an action can only run inside a real
interpretation of a real validated plan.

The @scope@ and @planId@ indices are universally quantified here, so an action
sees them as skolems it cannot choose. The descriptor's nominal indices connect
it to plan-scoped resource and preparation operations. Its gate reader still
returns an unindexed @PreparedGate@: @Lifecycle.Session.acknowledgeOutcome@
compares the gate's plan and session text with the operation session at runtime,
refusing @SessionPreparedGateMismatch@ when they disagree. It then checks the
live project permit, open session, fence, journal version and durable operation
fields before settling. The descriptor carries the plan's own identities, while
this gate/session pairing is enforced by those runtime checks (§ U).
-}
type StepAction =
    forall (scope :: Type) (planId :: Type).
    StepExecution scope planId -> IO StepObservation

-- | Pure descriptive preparation; the result does not authorize an effect.
type EffectPreflight = HostConfig -> Either Text [(Text, Text, Text)]

{- | What one step's action observed about its own node.

Every action reports whether its resource was already exact, changed, conflicted
with foreign state, unsupported by the backend, or refused by ownership policy.
The interpreter retains that distinction instead of reducing every returned
value to one undifferentiated success.

The observation is deliberately **plan-independent**: it carries no resource
handle, no ownership receipt, and no plan index. Those exist only on the far
side of a prepare (§ CC), and a step that has not passed one has nothing to
retain — so an action can describe what it saw without being able to claim
ownership it did not acquire. Turning an observation into a
'HostBootstrap.Reconcile.ReconcileResult' row is the interpreter's job, because
only the interpreter can pair it with the handle and receipt the prepare path
mints.

'StepRefused' is the safety refusal in observation form. The harness boundary
also supports an exception-form refusal; returning this constructor records the
same terminal category without unwinding the action callback.
-}
data StepObservation
    = -- | the node was already in its target state; nothing was changed
      StepUnchanged
    | -- | the node moved the resource to its target state
      StepChanged
    | -- | expected, observed, and how an operator resolves it
      StepConflict Text Text Text
    | -- | this backend cannot represent this node
      StepUnsupported Text
    | -- | acting would destroy state this run does not own
      StepRefused Text
    deriving (Eq, Show)

{- | Whether an observation is one the chain may continue past.

A conflict, an unsupported backend, and a refusal are all *terminal for the
chain*: the node did not reach its target state, so a later node that depends on
it would act on a precondition that does not hold. They differ in what an
operator must do about it, which is why they stay distinct rows rather than one
failure.
-}
observationSucceeded :: StepObservation -> Bool
observationSucceeded StepUnchanged = True
observationSucceeded StepChanged = True
observationSucceeded (StepConflict _ _ _) = False
observationSucceeded (StepUnsupported _) = False
observationSucceeded (StepRefused _) = False

{- | Stable prefixes for the three terminal observation categories.

They are owned beside 'StepObservation' because 'observationDetail' is their
producer. Higher-level reporting layers may re-export and classify these same
constants without introducing an upward dependency from the step algebra.
-}
conflictObservationMarker :: String
conflictObservationMarker = "conflict:"

unsupportedObservationMarker :: String
unsupportedObservationMarker = "unsupported:"

refusedObservationMarker :: String
refusedObservationMarker = "refused:"

-- | A one-line diagnostic for a node that did not reach its target state.
observationDetail :: StepObservation -> Text
observationDetail observation = case observation of
    StepUnchanged -> "unchanged"
    StepChanged -> "changed"
    StepConflict expected observed resolution ->
        marker conflictObservationMarker
            <> " expected "
            <> expected
            <> ", observed "
            <> observed
            <> "; "
            <> resolution
    StepUnsupported reason -> marker unsupportedObservationMarker <> " " <> reason
    StepRefused reason -> marker refusedObservationMarker <> " " <> reason
  where
    -- The markers live with this observation algebra; reporting consumers use
    -- the same exports so rendered and classified rows cannot drift apart.
    marker = Text.pack

{- | One execution frame. The id is semantic; the label is presentation only.
Validation rejects two labels for the same id.
-}
data StepFrame = StepFrame
    { frameId :: String
    , frameLabel :: String
    }
    deriving (Eq, Show)

-- | Closed identities owned by core.
data CoreStepId
    = DeployVMId
    | EnsureToolId String
    | CopySourceId
    | BuildPbId
    | BuildImageId
    | ContextInitId
    | DeployKindId
    | DeployChartId
    | ExposePortId
    | PostHandoffId String
    deriving (Eq, Ord, Show)

-- | A validated project-owned identity. Its constructor is hidden.
newtype ProjectStepId = ProjectStepId String
    deriving (Eq, Ord, Show)

{- | Validate a project identity. It need not avoid core spellings because its
namespace is disjoint, but it must be a stable non-empty token.
-}
projectStepId :: String -> Either String ProjectStepId
projectStepId raw
    | null raw = Left "project step identity must not be empty"
    | any invalidStepTokenCharacter raw = Left ("project step identity is not a stable token: " ++ show raw)
    | otherwise = Right (ProjectStepId raw)

invalidStepTokenCharacter :: Char -> Bool
invalidStepTokenCharacter c = not (c == '-' || c == '_' || c == '.' || c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z')

-- | Core and project identities cannot collide even when they render alike.
data StepIdentity
    = CoreStepIdentity CoreStepId
    | ProjectStepIdentity ProjectStepId
    deriving (Eq, Ord, Show)

{- | What one reverse step does to its resource.

'StopFrame' and 'DeleteFrame' distinguish the provider actions: @down@ stops
the frame so the guest and its disk survive, while @destroy@ deletes it.
'RetainResource' keeps the provider's durable share and alias across that stop.
'DeleteCluster' is used by __both__, because kind has no
reliable stop contract. Which one a step gets is derived by
"HostBootstrap.Teardown" from the plan and the verb; the step's own reverse
action receives it rather than choosing it.
-}
data TeardownAction
    = -- | provider frame: stop it, keeping the guest and its disk
      StopFrame
    | -- | provider frame: delete it and its disk
      DeleteFrame
    | -- | the ephemeral kind cluster; its removal set is empty
      DeleteCluster
    | -- | keep the provider's durable share and alias across stop/restart
      RetainResource
    | -- | any other acquired resource this run owns
      ReleaseResource
    | {- | provider frame: start it again so its retained children can be
      reached. Never produced by the reverse projection's own action table and
      never declarable by a step: it is supplied only by the destroy-only
      pre-descent reachability step, to the same callback the node already
      declared with 'reversedBy'. A @down@ stops a provider and leaves its
      children retained inside it; the @destroy@ that follows has to open that
      frame before it can unwind them.
      -}
      ReachFrame
    deriving (Eq, Ord, Show)

{- | What one reverse attempt observed. Only 'TeardownFailed' blocks completion:
compatible unowned state and a policy refusal both leave the object untouched
and are recorded rather than retried (§ Y).
-}
data TeardownOutcome
    = TeardownReleased
    | -- | compatible unowned state; not ours, so not torn down
      TeardownForeignRetained String
    | -- | an otherwise legal transition declined by policy
      TeardownRefused String
    | TeardownFailed String
    deriving (Eq, Show)

{- | The declared reverse behavior for a step. It is the classification the
verb-indexed reverse projection reads; requiring it prevents a mutating step
from entering a finalized plan without an explicit reverse decision. The
__effect__ that carries it out is attached separately with 'reversedBy', and
'mkStepPlan' permits at most one reverse effect and none on a preserved node.
A managed node may declare no effect: a core-managed node uses its core adapter,
while a project-managed node records 'TeardownForeignRetained' because it
acquired nothing this frame must release.
-}
data ReversePolicy
    = PreserveOnReverse
    | CoreManagedReverse
    | ProjectManagedReverse
    deriving (Eq, Ord, Show)

{- | Explicit revision of the forward implementation attached to a closed step
identity. The callback itself is opaque @IO@ and is never rendered or hashed;
changing its durable semantics therefore requires a new positive revision.
-}
newtype StepImplementationRevision = StepImplementationRevision Word64
    deriving (Eq, Ord, Show)

mkStepImplementationRevision :: Word64 -> Either String StepImplementationRevision
mkStepImplementationRevision 0 = Left "a step implementation revision must be positive"
mkStepImplementationRevision revision = Right (StepImplementationRevision revision)

stepImplementationRevisionNumber :: StepImplementationRevision -> Word64
stepImplementationRevisionNumber (StepImplementationRevision revision) = revision

initialStepImplementationRevision :: StepImplementationRevision
initialStepImplementationRevision = StepImplementationRevision 1

{- | Explicit revision of the reverse adapter selected for a step. It covers
both a core/project policy adapter and a callback attached with 'reversedBy'.
-}
newtype StepReverseAdapterRevision = StepReverseAdapterRevision Word64
    deriving (Eq, Ord, Show)

mkStepReverseAdapterRevision :: Word64 -> Either String StepReverseAdapterRevision
mkStepReverseAdapterRevision 0 = Left "a step reverse-adapter revision must be positive"
mkStepReverseAdapterRevision revision = Right (StepReverseAdapterRevision revision)

stepReverseAdapterRevisionNumber :: StepReverseAdapterRevision -> Word64
stepReverseAdapterRevisionNumber (StepReverseAdapterRevision revision) = revision

initialStepReverseAdapterRevision :: StepReverseAdapterRevision
initialStepReverseAdapterRevision = StepReverseAdapterRevision 1

-- | Stable namespaced operation key derived only from the typed identity.
newtype OperationKey = OperationKey String
    deriving (Eq, Ord, Show)

operationKeyText :: OperationKey -> String
operationKeyText (OperationKey value) = value

-- | Render-only kind view. The constructor is hidden.
data StepKind
    = CoreKind CoreStepId
    | ProjectKind ProjectStepId
    deriving (Eq, Show)

-- | One opaque step.
data Step = Step
    { internalStepLabel :: String
    , internalStepFrame :: StepFrame
    , internalStepKind :: StepKind
    , internalStepReversePolicy :: ReversePolicy
    , internalStepImplementationRevision :: StepImplementationRevision
    , internalStepReverseAdapterRevision :: StepReverseAdapterRevision
    , internalStepRun :: StepAction
    , internalStepDescent :: [LiftContext]
    {- ^ The descent this step declares out of its own frame. A list rather than
    a 'Maybe' so a second declaration is /retained/ as a construction
    conflict and rejected by 'mkStepPlan', instead of silently replacing the
    first.
    -}
    , internalStepReverse :: [HostConfig -> TeardownAction -> IO TeardownOutcome]
    -- ^ The reverse effect this step declares, retained the same way.
    , internalStepProjections :: [String]
    {- ^ The operations this step projects out of its own. Retained as declared
    so 'mkStepPlan' can reject one that does not live under this step's own
    operation key, or one two steps claim.
    -}
    , internalProviderResourceDeclarations :: [ProviderResourceDeclaration]
    , internalProviderProbeDescriptions :: [ProviderProbeDescription]
    , internalShareProbeDescriptions :: [ShareProbeDescription]
    , internalAliasProbeDescriptions :: [AliasProbeDescription]
    , internalClusterObjectProbeDescriptions :: [ClusterObjectProbeDescription]
    , internalEmptyChildFrames :: [StepFrame]
    , internalChartWorkloadResourceDeclarations :: [(Text, Text, Text, Text, Text, Text, Text, Text, Text, [Text])]
    , internalServiceActivationDeclarations :: [(Text, Text, [Text])]
    , internalEffectPreflight :: Maybe EffectPreflight
    , internalRecoveryObserver :: Maybe RecoveryObserver
    -- ^ The step's optional read-only recovery observer; absent leaves an interrupted effect unresolved.
    }

{- | A closed provider-resource declaration attached to its authoring
operation. It targets only that operation's current frame or its unique
immediate child; callers supply neither frame text nor a resource key.
-}
data ProviderResourceDeclaration
    = ProviderResourceAtCurrentFrame
    | ProviderResourceAtImmediateChild
    deriving (Eq, Show)

providerResourceAtCurrentFrame :: ProviderResourceDeclaration
providerResourceAtCurrentFrame = ProviderResourceAtCurrentFrame

providerResourceAtImmediateChild :: ProviderResourceDeclaration
providerResourceAtImmediateChild = ProviderResourceAtImmediateChild

declaresProviderResource :: ProviderResourceDeclaration -> Step -> Step
declaresProviderResource declaration step =
    step
        { internalProviderResourceDeclarations =
            internalProviderResourceDeclarations step ++ [declaration]
        }

stepProviderResourceDeclarations :: Step -> [ProviderResourceDeclaration]
stepProviderResourceDeclarations = internalProviderResourceDeclarations

providerResourceDeclarationTargetsChild :: ProviderResourceDeclaration -> Bool
providerResourceDeclarationTargetsChild declaration =
    case declaration of
        ProviderResourceAtCurrentFrame -> False
        ProviderResourceAtImmediateChild -> True

{- | Closed, non-secret provider inputs retained for a root-owned probe.

These descriptions are plan data, not a backend, observation, or authority.
The host tool itself is discovered in the frame that performs the probe.
-}
data ProviderProbeDescription
    = DirectProviderProbe FilePath Text
    | IncusProviderProbe Text Text Text FilePath Word64 Text Text
    | LimaProviderProbe Text Word64 Text Text FilePath FilePath
    | Wsl2ProviderProbe Text Word64 Text Text FilePath FilePath
    deriving (Eq, Show)

declaresProviderProbe :: ProviderProbeDescription -> Step -> Step
declaresProviderProbe description step =
    step{internalProviderProbeDescriptions = internalProviderProbeDescriptions step ++ [description]}

stepProviderProbeDescriptions :: Step -> [ProviderProbeDescription]
stepProviderProbeDescriptions = internalProviderProbeDescriptions

-- | Descriptive host and guest paths for one plan-owned durable share.
data ShareProbeDescription = ShareProbeDescription FilePath FilePath
    deriving (Eq, Show)

declaresShareProbe :: ShareProbeDescription -> Step -> Step
declaresShareProbe description step =
    step{internalShareProbeDescriptions = internalShareProbeDescriptions step ++ [description]}

stepShareProbeDescriptions :: Step -> [ShareProbeDescription]
stepShareProbeDescriptions = internalShareProbeDescriptions

-- | The guest alias path and its exact link target for one plan-owned share.
-- Both are guest paths; the target is the declaring share's guest path.
data AliasProbeDescription = AliasProbeDescription FilePath FilePath
    deriving (Eq, Show)

declaresAliasProbe :: AliasProbeDescription -> Step -> Step
declaresAliasProbe description step =
    step{internalAliasProbeDescriptions = internalAliasProbeDescriptions step ++ [description]}

stepAliasProbeDescriptions :: Step -> [AliasProbeDescription]
stepAliasProbeDescriptions = internalAliasProbeDescriptions

{- | The one cluster workload object a plan-owned in-cluster resource is: the
cluster's runtime state directory and name in the frame that holds it, and the
object's namespace, closed kind (@deployment@ or @statefulset@) and name.
-}
data ClusterObjectProbeDescription = ClusterObjectProbeDescription FilePath Text Text Text Text
    deriving (Eq, Show)

declaresClusterObjectProbe :: ClusterObjectProbeDescription -> Step -> Step
declaresClusterObjectProbe description step =
    step{internalClusterObjectProbeDescriptions = internalClusterObjectProbeDescriptions step ++ [description]}

stepClusterObjectProbeDescriptions :: Step -> [ClusterObjectProbeDescription]
stepClusterObjectProbeDescriptions = internalClusterObjectProbeDescriptions

{- | Name the terminal child frame this descending step enters, when that frame
has no step of its own. Only the innermost step-bearing frame's descending step
may declare one; the frame then has no node and no descent, and the plan digest
binds its identity.
-}
declaresEmptyChildFrame :: StepFrame -> Step -> Step
declaresEmptyChildFrame frame step =
    step{internalEmptyChildFrames = internalEmptyChildFrames step ++ [frame]}

stepEmptyChildFrames :: Step -> [StepFrame]
stepEmptyChildFrames = internalEmptyChildFrames

{- | Whether an effect's own execution mechanism proves that nothing it started
can still land after the observation. Ordinary process exit proves nothing.
-}
data DelayedEffectGuarantee
    = -- | the mechanism rules out a delayed effect, so an observed absence is real
      NoDelayedEffect
    | -- | an effect may still land later, so absence can only be inconclusive
      DelayedEffectPossible
    deriving (Eq, Show)

-- | What a recovery observer reports about its exact operation's effect.
data RecoveryObservation
    = RecoveryEffectAbsent
    | -- | the effect is present, carrying its managed identity
      RecoveryEffectPresent Text
    | -- | something is present that the plan does not own
      RecoveryEffectForeign Text
    | RecoveryInconclusive Text
    deriving (Eq, Show)

{- | A plan-bound, read-only recovery observer. It is identified and revised so
the admitted plan binds exactly which observer may speak for the step; its
check receives only the step's operation key and frame, never an execution,
gate, store or reverse authority, so it cannot perform an effect or mint
settlement.
-}
data RecoveryObserver = RecoveryObserver Text Word64 DelayedEffectGuarantee (Text -> Text -> IO RecoveryObservation)

mkRecoveryObserver ::
    Text -> Word64 -> DelayedEffectGuarantee -> (Text -> Text -> IO RecoveryObservation) -> Either String RecoveryObserver
mkRecoveryObserver identity revision guarantee check
    | Text.null identity = Left "a recovery observer needs a non-empty identity"
    | revision == 0 = Left "a recovery observer revision must be positive"
    | otherwise = Right (RecoveryObserver identity revision guarantee check)

recoveryObserverIdentity :: RecoveryObserver -> Text
recoveryObserverIdentity (RecoveryObserver identity _ _ _) = identity

recoveryObserverRevision :: RecoveryObserver -> Word64
recoveryObserverRevision (RecoveryObserver _ revision _ _) = revision

-- | Attach one pure effect description without running the step action.
declaresEffectPreflight :: EffectPreflight -> Step -> Step
declaresEffectPreflight preflight step = case internalEffectPreflight step of
    Nothing -> step{internalEffectPreflight = Just preflight}
    Just _ -> error "a step declares at most one effect preflight"

-- | An absent preflight is explicit; evaluating a present one grants no authority.
stepEffectPreflight :: Step -> HostConfig -> Maybe (Either Text [(Text, Text, Text)])
stepEffectPreflight step host = ($ host) <$> internalEffectPreflight step

-- | Attach the step's one recovery observer; a second is a construction conflict.
observesRecoveryWith :: RecoveryObserver -> Step -> Step
observesRecoveryWith observer step = case internalRecoveryObserver step of
    Nothing -> step{internalRecoveryObserver = Just observer}
    Just _ -> error "a step declares at most one recovery observer"

stepRecoveryObserver :: Step -> Maybe RecoveryObserver
stepRecoveryObserver = internalRecoveryObserver

{- | One observation bound to the exact operation, frame, observer identity and
revision that produced it. It grants nothing: only 'admitRecoveryObservation'
against the admitted step yields its result.
-}
data BoundRecoveryObservation = BoundRecoveryObservation Text Text Text Word64 RecoveryObservation
    deriving (Eq, Show)

boundRecoveryObservationResult :: BoundRecoveryObservation -> RecoveryObservation
boundRecoveryObservationResult (BoundRecoveryObservation _ _ _ _ result) = result

{- | Run the step's observer for its own operation and frame. A step without an
observer stays unresolved ('Nothing'). An absence from an observer whose
mechanism cannot rule out a delayed effect, and any exception, are
inconclusive.
-}
observeStepRecovery :: Step -> IO (Maybe BoundRecoveryObservation)
observeStepRecovery step = case internalRecoveryObserver step of
    Nothing -> pure Nothing
    Just (RecoveryObserver identity revision guarantee check) -> do
        let operation = Text.pack (operationKeyText (stepOperationKey step))
            frame = Text.pack (frameId (stepFrame step))
        attempted <- try (check operation frame)
        let observed = case attempted of
                Left exception -> RecoveryInconclusive (Text.pack ("the recovery observer raised: " <> displayException (exception :: SomeException)))
                Right RecoveryEffectAbsent
                    | guarantee == DelayedEffectPossible -> RecoveryInconclusive "the effect may still land after the observation"
                Right result -> result
        pure (Just (BoundRecoveryObservation operation frame identity revision observed))

{- | Admit an observation only for the exact admitted step that declares the same
observer identity and revision; another operation or frame is foreign, another
observer or revision is stale, and a step without an observer has none to admit.
-}
admitRecoveryObservation :: Step -> BoundRecoveryObservation -> Either Text RecoveryObservation
admitRecoveryObservation step (BoundRecoveryObservation operation frame identity revision observed) =
    case internalRecoveryObserver step of
        Nothing -> Left "the step has no recovery observer"
        Just (RecoveryObserver expectedIdentity expectedRevision _ _)
            | operation /= Text.pack (operationKeyText (stepOperationKey step))
                || frame /= Text.pack (frameId (stepFrame step)) ->
                Left "the recovery observation names another operation or frame"
            | identity /= expectedIdentity || revision /= expectedRevision ->
                Left "the recovery observation came from another observer or revision"
            | otherwise -> Right observed

validProviderProbe :: ProviderProbeDescription -> Bool
validProviderProbe description = case description of
    DirectProviderProbe root image -> nativePath root && field image
    IncusProviderProbe name image guardPrefix state cpu memory storage ->
        all field [name, image, guardPrefix, memory, storage] && nativePath state && cpu > 0
    LimaProviderProbe name cpu memory storage host guest -> guestVm name cpu memory storage host guest
    Wsl2ProviderProbe name cpu memory storage host guest -> guestVm name cpu memory storage host guest
  where
    field value = not (Text.null value) && Text.length value <= 32768 && not (Text.any (== '\0') value)
    nativePath path = isAbsolute path && length path <= 32768 && '\0' `notElem` path
    guestVm name cpu memory storage host guest =
        all field [name, memory, storage]
            && cpu > 0
            && nativePath host
            && Posix.isAbsolute guest
            && length guest <= 32768
            && '\0' `notElem` guest

declaresChartWorkloadResource ::
    Text -> Text -> Text -> Text -> Text -> Text -> Text -> Text -> Text -> [Text] -> Step -> Step
declaresChartWorkloadResource artifactDigest release namespace valuesDigest imageIdentity workloadKey workloadDigest activationFrame serviceRole effects step =
    step
        { internalChartWorkloadResourceDeclarations =
            internalChartWorkloadResourceDeclarations step
                ++ [(artifactDigest, release, namespace, valuesDigest, imageIdentity, workloadKey, workloadDigest, activationFrame, serviceRole, effects)]
        }

stepChartWorkloadResourceDeclarations :: Step -> [(Text, Text, Text, Text, Text, Text, Text, Text, Text, [Text])]
stepChartWorkloadResourceDeclarations = internalChartWorkloadResourceDeclarations

{- | Declare one service activation placement authored by this plan step.

The declaration contains only the service frame, selected role, and permitted
effect names. Runtime image, binary, config, secret, and instance measurements
remain outside canonical plan bytes and must still satisfy the root signing
policy when the step requests a grant.
-}
declaresServiceActivation :: Text -> Text -> [Text] -> Step -> Step
declaresServiceActivation activationFrame serviceRole effects step =
    step
        { internalServiceActivationDeclarations =
            internalServiceActivationDeclarations step
                ++ [(activationFrame, serviceRole, effects)]
        }

stepServiceActivationDeclarations :: Step -> [(Text, Text, [Text])]
stepServiceActivationDeclarations = internalServiceActivationDeclarations

stepLabel :: Step -> String
stepLabel = internalStepLabel

stepFrame :: Step -> StepFrame
stepFrame = internalStepFrame

stepKind :: Step -> StepKind
stepKind = internalStepKind

stepIdentity :: Step -> StepIdentity
stepIdentity step =
    case internalStepKind step of
        CoreKind identity -> CoreStepIdentity identity
        ProjectKind identity -> ProjectStepIdentity identity

stepReversePolicy :: Step -> ReversePolicy
stepReversePolicy = internalStepReversePolicy

-- | Replace the explicit forward-implementation revision for this step.
implementedAt :: StepImplementationRevision -> Step -> Step
implementedAt revision step = step{internalStepImplementationRevision = revision}

stepImplementationRevision :: Step -> StepImplementationRevision
stepImplementationRevision = internalStepImplementationRevision

{- | Replace the explicit reverse-adapter revision for this step. This applies
whether the adapter is policy-provided or attached with 'reversedBy'.
-}
reverseAdapterAt :: StepReverseAdapterRevision -> Step -> Step
reverseAdapterAt revision step = step{internalStepReverseAdapterRevision = revision}

stepReverseAdapterRevision :: Step -> StepReverseAdapterRevision
stepReverseAdapterRevision = internalStepReverseAdapterRevision

stepOperationKey :: Step -> OperationKey
stepOperationKey step =
    OperationKey $
        case stepIdentity step of
            CoreStepIdentity identity -> "core:" ++ stepKindName (CoreKind identity)
            ProjectStepIdentity identity -> "project:" ++ stepKindName (ProjectKind identity)

{- | Declare an operation this step __projects__ out of its own node.

A resource that /relates/ two others has an operation key derived from the keys
it relates — the provider guest alias is
@\<provider\>\/\<share\>\/guest-alias@ — so it is not any node's own key, and a
node that may reach only its own gate can never prepare it. Declaring the
projection here puts it in the same validated plan the forward traversal, the
descent, and the reverse projection are taken from, so the operation an adapter
prepares is a node of the plan rather than a key it composed at the call site.

'mkStepPlan' requires the projected key to be exactly

@\<zero or more of this step's dependency keys, in plan order\>\/\<this step's own key\>\/\<suffix\>@

with a non-empty separator-free suffix, and requires it to be claimed once across
the whole plan. The declaring node is therefore the /last/ resource the key
relates — the suffix names the relation, not another resource — which
is the only node that can perform the relation: every other resource named in
the key is already behind it in the plan. The guest alias is claimed by the
durable-share node, whose prefix contains the provider. The interpreter then
registers the projection with that node, opens its gate with the node's, and
settles it with the node.
-}
projectsOperation :: String -> Step -> Step
projectsOperation key step =
    step{internalStepProjections = internalStepProjections step ++ [key]}

{- | The operations this step projects, in declared order. Each is validated by
'mkStepPlan', so an 'OperationKey' read out of a plan step is one the plan
admitted rather than one a caller spelled.
-}
stepProjectedOperations :: Step -> [OperationKey]
stepProjectedOperations = map OperationKey . internalStepProjections

{- | Run one step's forward action against the descriptor the interpreter minted
for it. A caller cannot supply a 'StepExecution' of its own: the type has no
public constructor (§ U).
-}
runStep :: Step -> StepExecution (scope :: Type) (planId :: Type) -> IO StepObservation
runStep step execution = internalStepRun step execution

{- | Declare how this step's frame descends into the next frame of the chain
(§ U): the provider dispatch and, for a boundary that delivers one, the child
config streamed in place on the handoff @stdin@ (§ X).

Exactly one step of every frame but the innermost declares this, so the descent
is a node of the same validated plan the forward traversal and the reverse
projection are taken from (§ W) rather than a separately supplied per-frame
resolver. A second declaration — on this step or on a sibling in the same frame
— is a plan error, not a silent replacement.
-}
descendsVia :: LiftContext -> Step -> Step
descendsVia context step =
    step{internalStepDescent = internalStepDescent step ++ [context]}

-- | The descents this step declares. More than one is a construction conflict.
stepDescents :: Step -> [LiftContext]
stepDescents = internalStepDescent

{- | Declare the effect that releases what this step acquired.

The reverse projection already knew /that/ a step must be undone and in what
order (its 'ReversePolicy' and frame position); this is the effect itself, so
the node that acquires a resource is the node that releases it rather than a
separately supplied whole-project hook. The action receives the verb-derived
'TeardownAction', which is the only thing that differs between @down@ and
@destroy@ for a given node.

A @PreserveOnReverse@ step may not declare one: it never enters a reverse
projection at all, so the effect would be dead code rather than a policy, and
'mkStepPlan' rejects it. A @CoreManagedReverse@ node /may/ declare one, and it
then takes precedence over the core adapter for that node — the demo's direct
Linux GPU lane needs exactly that, because its @deploy-kind@ cluster lives in a
frame the metal host has no kube toolchain for and is reached instead through
the project image.

Declaring none is legal and means the step acquired nothing this frame must
release — @build-pb@, for instance, leaves a binary inside a frame that its own
parent releases.

Attaching the effect preserves the step's declared reverse-adapter revision.
Use 'reversedByAt' to select a different revision explicitly.
-}
reversedBy ::
    (HostConfig -> TeardownAction -> IO TeardownOutcome) ->
    Step ->
    Step
reversedBy action step =
    step{internalStepReverse = internalStepReverse step ++ [action]}

-- | Attach a reverse effect under an explicit stable adapter revision.
reversedByAt ::
    StepReverseAdapterRevision ->
    (HostConfig -> TeardownAction -> IO TeardownOutcome) ->
    Step ->
    Step
reversedByAt revision action step =
    reversedBy action (reverseAdapterAt revision step)

{- | The reverse effects this step declares. More than one is a construction
conflict.
-}
stepReverses :: Step -> [HostConfig -> TeardownAction -> IO TeardownOutcome]
stepReverses = internalStepReverse

{- | The single reverse effect a validated step declares, if any. Total because
'mkStepPlan' has already rejected a second declaration.
-}
stepReverse :: Step -> Maybe (HostConfig -> TeardownAction -> IO TeardownOutcome)
stepReverse step = case internalStepReverse step of
    (action : _) -> Just action
    [] -> Nothing

isDeployKindStep :: Step -> Bool
isDeployKindStep step =
    case internalStepKind step of
        CoreKind DeployKindId -> True
        _ -> False

{- | Whether this step provisions a provider frame. The reverse projection needs
it because the provider is the one resource whose teardown action differs
between @down@ (stop, keeping the guest and its disk) and @destroy@ (delete).
-}
isDeployVMStep :: Step -> Bool
isDeployVMStep step =
    case internalStepKind step of
        CoreKind DeployVMId -> True
        _ -> False

-- | Stable presentation name; it is never used as identity.
stepKindName :: StepKind -> String
stepKindName kind =
    case kind of
        CoreKind identity ->
            case identity of
                DeployVMId -> "deploy-vm"
                EnsureToolId tool -> "ensure-" ++ tool
                CopySourceId -> "copy-source"
                BuildPbId -> "build-pb"
                BuildImageId -> "build-image"
                ContextInitId -> "context-init"
                DeployKindId -> "deploy-kind"
                DeployChartId -> "deploy-chart"
                ExposePortId -> "expose-port"
                PostHandoffId name -> "post-handoff-" ++ name
        ProjectKind (ProjectStepId name) -> name

renderStep :: Step -> String
renderStep step =
    "["
        ++ frameId (stepFrame step)
        ++ "] "
        ++ stepKindName (stepKind step)
        ++ " — "
        ++ stepLabel step

{- | An opaque non-empty plan whose declared order and frame traversal agree.

Non-empty in the type, not only in the constructor: an accessor that answered
with a plain list threw the fact away, and three call sites rebuilt it and
crashed on the branch 'mkStepPlan' had already excluded.
-}
newtype StepPlan = StepPlan (NonEmpty Step)

data StepPlanError
    = EmptyStepPlan
    | EmptyFrameId Int
    | EmptyStepLabel Int
    | DuplicateStepIdentities [StepIdentity]
    | ConflictingFrameLabels String [String]
    | InvalidCoreStepName StepIdentity
    | NonContiguousFrameReturn String [String]
    | PostHandoffBeforeDescentComplete Int
    | PostHandoffForUnknownFrame Int String
    | PostHandoffOutOfDescentOrder Int String String
    | -- | a frame that descends into another declared no 'descendsVia'
      MissingFrameDescent String
    | -- | more than one 'descendsVia' was declared for the same frame
      DuplicateFrameDescent String Int
    | -- | the innermost frame has nowhere to descend to
      DescentFromInnermostFrame String
    | -- | an empty child frame is declared other than once on the innermost frame's descending step
      MisplacedEmptyChildFrame Int
    | -- | the declared empty child frame reuses a frame identity or has an empty one
      InvalidEmptyChildFrame String
    | -- | a post-handoff hook runs after the descent; it cannot declare one
      DescentOnPostHandoffStep Int
    | -- | more than one 'reversedBy' was declared for the same step
      DuplicateStepReverse StepIdentity Int
    | -- | the step never enters a reverse projection, so its effect is dead
      ReverseOnPreservedStep StepIdentity
    | -- | a projected operation that does not live under the declaring node
      ProjectionOutsideStep StepIdentity String
    | -- | a projected operation claimed twice, or already a node's own
      DuplicateProjectedOperation String
    | DuplicateProviderResourceDeclaration StepIdentity Int
    | ProviderResourceChildWithoutUniqueDescent StepIdentity
    | DuplicateProviderProbeDescription StepIdentity Int
    | ProviderProbeWithoutResource StepIdentity
    | InvalidProviderProbeDescription StepIdentity
    | DuplicateShareProbeDescription StepIdentity Int
    | ShareProbeWithoutResource StepIdentity
    | InvalidShareProbeDescription StepIdentity
    | DuplicateAliasProbeDescription StepIdentity Int
    | AliasProbeWithoutShare StepIdentity
    | InvalidAliasProbeDescription StepIdentity
    | DuplicateClusterObjectProbeDescription StepIdentity Int
    | ClusterObjectProbeWithoutResource StepIdentity
    | InvalidClusterObjectProbeDescription StepIdentity
    deriving (Eq, Show)

{- | Validate the exact declared sequence. Normal steps must form contiguous
frame segments. Post-handoff hooks may appear only as a final suffix, may refer
only to a frame already present in the descent sequence, and are ordered from
the deepest participating frame back toward the root. Every frame but the
innermost declares exactly one descent, and the innermost declares none, so the
interpreter's handoff context is a projection of this plan rather than a
separate resolver.
-}
mkStepPlan :: [Step] -> Either StepPlanError StepPlan
mkStepPlan [] = Left EmptyStepPlan
mkStepPlan steps@(firstStep : remainingSteps)
    | Just (index, _) <- firstIndexed (null . frameId . stepFrame) steps =
        Left (EmptyFrameId index)
    | Just (index, _) <- firstIndexed (null . stepLabel) steps =
        Left (EmptyStepLabel index)
    | not (null duplicateIdentities) =
        Left (DuplicateStepIdentities duplicateIdentities)
    | Just (fid, labels) <- conflictingLabels =
        Left (ConflictingFrameLabels fid labels)
    | Just (_, step) <- firstIndexed invalidCoreStepName steps =
        Left (InvalidCoreStepName (stepIdentity step))
    | Just index <- postBeforeNormal =
        Left (PostHandoffBeforeDescentComplete index)
    | Just (index, fid) <- unknownPostFrame =
        Left (PostHandoffForUnknownFrame index fid)
    | Just failure <- postHandoffOrderFailure =
        Left failure
    | Just fid <- returnedFrame =
        Left (NonContiguousFrameReturn fid normalFrameIds)
    | Just index <- postHandoffDescent =
        Left (DescentOnPostHandoffStep index)
    | Just failure <- emptyChildFailure =
        Left failure
    | Just failure <- descentFailure =
        Left failure
    | Just failure <- reverseFailure =
        Left failure
    | Just failure <- projectionFailure =
        Left failure
    | Just failure <- providerDeclarationFailure =
        Left failure
    | Just failure <- providerProbeFailure =
        Left failure
    | Just failure <- shareProbeFailure =
        Left failure
    | Just failure <- aliasProbeFailure =
        Left failure
    | Just failure <- clusterObjectProbeFailure =
        Left failure
    | otherwise = Right (StepPlan (firstStep :| remainingSteps))
  where
    invalidCoreStepName step = case stepIdentity step of
        CoreStepIdentity (EnsureToolId name) -> invalidToken name
        CoreStepIdentity (PostHandoffId name) -> invalidToken name
        _ -> False
    invalidToken name = null name || any invalidStepTokenCharacter name
    duplicateIdentities = duplicates (map stepIdentity steps)
    framePairs = [(frameId frame, frameLabel frame) | frame <- map stepFrame steps]
    conflictingLabels =
        firstJust
            [ let labels = unique [label | (candidate, label) <- framePairs, candidate == fid]
               in if length labels > 1 then Just (fid, labels) else Nothing
            | fid <- unique (map fst framePairs)
            ]
    (normalSteps, postSteps) = break isPostHandoffStep steps
    postBeforeNormal =
        case firstIndexed (not . isPostHandoffStep) postSteps of
            Nothing -> Nothing
            Just (offset, _) -> Just (length normalSteps + offset)
    normalFrameIds = map (frameId . stepFrame) normalSteps
    descentFrameIds = unique normalFrameIds
    unknownPostFrame =
        firstJust
            [ if frameId (stepFrame step) `elem` descentFrameIds
                then Nothing
                else Just (index, frameId (stepFrame step))
            | (index, step) <- zip [length normalSteps + 1 ..] postSteps
            ]
    postFrameIds = map (frameId . stepFrame) postSteps
    postHandoffOrderFailure =
        firstJust
            [ case (elemIndex previous descentFrameIds, elemIndex next descentFrameIds) of
                (Just previousPosition, Just nextPosition)
                    | nextPosition > previousPosition ->
                        Just
                            ( PostHandoffOutOfDescentOrder
                                (length normalSteps + offset)
                                previous
                                next
                            )
                _ -> Nothing
            | (offset, (previous, next)) <-
                zip [2 :: Int ..] (zip postFrameIds (drop 1 postFrameIds))
            ]
    returnedFrame = firstReturnedFrame normalFrameIds
    postHandoffDescent =
        fmap
            (\(offset, _) -> length normalSteps + offset)
            (firstIndexed (not . null . stepDescents) postSteps)
    {- Every frame that has a successor declares exactly one descent; the
    innermost declares none, because there is nothing below it to name. -}
    {- A declared reverse effect must be able to run, and there must be at most
    one of it. A preserved step is never projected, so an effect declared there
    could never fire. -}
    reverseFailure =
        firstJust
            [ case (stepReversePolicy step, length (stepReverses step)) of
                (_, 0) -> Nothing
                (PreserveOnReverse, _) -> Just (ReverseOnPreservedStep (stepIdentity step))
                (_, 1) -> Nothing
                (_, declared) -> Just (DuplicateStepReverse (stepIdentity step) declared)
            | step <- steps
            ]
    {- A projected operation is the relation the declaring node completes, and it
    is claimed exactly once in the whole plan. The shape rule is what makes the
    projection reachable from its declaring node and unreachable from a sibling:
    every resource the key names before the declaring node is one the plan
    already ordered ahead of it, so the node holds every input the relation
    needs. The uniqueness rule is what stops two nodes registering, gating, and
    settling the same durable operation record. -}
    ownOperationKeys = map (operationKeyText . stepOperationKey) steps
    declaredProjections =
        [ (step, take index ownOperationKeys, key)
        | (index, step) <- zip [0 ..] steps
        , key <- internalStepProjections step
        ]
    projectionFailure =
        firstJust
            ( [ if relates dependencyKeys (operationKeyText (stepOperationKey step)) key
                    then Nothing
                    else Just (ProjectionOutsideStep (stepIdentity step) key)
              | (step, dependencyKeys, key) <- declaredProjections
              ]
                ++ [ if claimed > 1 || key `elem` ownOperationKeys
                        then Just (DuplicateProjectedOperation key)
                        else Nothing
                   | key <- unique [key | (_, _, key) <- declaredProjections]
                   , let claimed = length [() | (_, _, candidate) <- declaredProjections, candidate == key]
                   ]
            )
    providerDeclarationFailure =
        firstJust
            [ case declarations of
                [] -> Nothing
                [ProviderResourceAtCurrentFrame] -> Nothing
                [ProviderResourceAtImmediateChild]
                    | frameDescentCount (frameId (stepFrame step)) == 1 -> Nothing
                    | otherwise -> Just (ProviderResourceChildWithoutUniqueDescent (stepIdentity step))
                _ -> Just (DuplicateProviderResourceDeclaration (stepIdentity step) (length declarations))
            | step <- steps
            , let declarations = stepProviderResourceDeclarations step
            ]
    providerProbeFailure =
        firstJust
            [ case stepProviderProbeDescriptions step of
                [] -> Nothing
                [description]
                    | null (stepProviderResourceDeclarations step) && stepIdentity step /= CoreStepIdentity DeployVMId ->
                        Just (ProviderProbeWithoutResource (stepIdentity step))
                    | not (validProviderProbe description) -> Just (InvalidProviderProbeDescription (stepIdentity step))
                    | otherwise -> Nothing
                descriptions -> Just (DuplicateProviderProbeDescription (stepIdentity step) (length descriptions))
            | step <- steps
            ]
    shareProbeFailure =
        firstJust
            [ case stepShareProbeDescriptions step of
                [] -> Nothing
                [ShareProbeDescription host guest]
                    | stepIdentity step /= CoreStepIdentity CopySourceId -> Just (ShareProbeWithoutResource (stepIdentity step))
                    | not (validSharePath isAbsolute host && validSharePath Posix.isAbsolute guest) -> Just (InvalidShareProbeDescription (stepIdentity step))
                    | otherwise -> Nothing
                descriptions -> Just (DuplicateShareProbeDescription (stepIdentity step) (length descriptions))
            | step <- steps
            ]
    validSharePath absolute path = absolute path && length path <= 32768 && '\0' `notElem` path
    -- The alias links to its own share's guest path, so it is declared only beside that share.
    -- Only the in-cluster object-store and registry resources are cluster objects.
    clusterObjectProbeFailure =
        firstJust
            [ case stepClusterObjectProbeDescriptions step of
                [] -> Nothing
                [ClusterObjectProbeDescription state cluster namespace kind name]
                    | operationKeyText (stepOperationKey step) `notElem` ["project:deploy-object-store", "project:deploy-registry", "core:deploy-kind", "core:deploy-chart"] ->
                        Just (ClusterObjectProbeWithoutResource (stepIdentity step))
                    | not (validSharePath Posix.isAbsolute state)
                        || not (dnsLabel cluster) || not (dnsLabel namespace) || not (dnsLabel name)
                        || not (closedKind step (operationKeyText (stepOperationKey step)) kind namespace name) ->
                        Just (InvalidClusterObjectProbeDescription (stepIdentity step))
                    | otherwise -> Nothing
                descriptions -> Just (DuplicateClusterObjectProbeDescription (stepIdentity step) (length descriptions))
            | step <- steps
            ]
    -- A cluster node names one namespace (its own name in its namespace field);
    -- a chart node names one workload its own admitted chart declares as an
    -- effect, in the chart's namespace; any other workload node names a workload.
    closedKind step key kind namespace name
        | key == "core:deploy-kind" = kind == "namespace" && namespace == name
        | key == "core:deploy-chart" = case stepChartWorkloadResourceDeclarations step of
            [(_, _, chartNamespace, _, _, _, _, _, _, effects)] ->
                kind `elem` ["deployment", "statefulset"] && namespace == chartNamespace && (kind <> ":" <> name) `elem` effects
            _ -> False
        | otherwise = kind `elem` ["deployment", "statefulset"]
    dnsLabel value =
        not (Text.null value) && Text.length value <= 63
            && Text.all (\character -> character `elem` ['a' .. 'z'] || character `elem` ['0' .. '9'] || character == '-') value
            && Text.head value /= '-' && Text.last value /= '-'
    aliasProbeFailure =
        firstJust
            [ case (stepAliasProbeDescriptions step, stepShareProbeDescriptions step) of
                ([], _) -> Nothing
                ([AliasProbeDescription alias target], [ShareProbeDescription _ guest])
                    | not (validSharePath Posix.isAbsolute alias && validSharePath Posix.isAbsolute target)
                        || target /= guest || alias == target ->
                        Just (InvalidAliasProbeDescription (stepIdentity step))
                    | otherwise -> Nothing
                ([_], _) -> Just (AliasProbeWithoutShare (stepIdentity step))
                (descriptions, _) -> Just (DuplicateAliasProbeDescription (stepIdentity step) (length descriptions))
            | step <- steps
            ]
    frameDescentCount fid =
        length
            [ context
            | candidate <- normalSteps
            , frameId (stepFrame candidate) == fid
            , context <- stepDescents candidate
            ]
    {- Consume each dependency key the projection names, left to right and in
    plan order, then the declaring node's own key, then require a non-empty
    suffix. Operation keys are unique and a segment is only consumed when the
    separator follows it, so the scan is unambiguous. -}
    relates dependencyKeys owner key =
        case stripSegment owner (foldl consume key dependencyKeys) of
            Nothing -> False
            Just suffix -> not (null suffix) && '/' `notElem` suffix
      where
        consume remaining dependencyKey =
            maybe remaining id (stripSegment dependencyKey remaining)
    stripSegment segment value
        | (segment ++ "/") `isPrefixOf` value = Just (drop (length segment + 1) value)
        | otherwise = Nothing
    -- An empty child frame belongs only to a descending step of the innermost
    -- step-bearing frame, once, under an identity no step-bearing frame uses.
    emptyChildDeclarations = [(index, step, frame) | (index, step) <- zip [1 :: Int ..] steps, frame <- stepEmptyChildFrames step]
    innermostFrameId = last descentFrameIds
    emptyChildFailure = case emptyChildDeclarations of
        [] -> Nothing
        [(index, declaring, frame)]
            | isPostHandoffStep declaring || frameId (stepFrame declaring) /= innermostFrameId || null (stepDescents declaring) ->
                Just (MisplacedEmptyChildFrame index)
            | null (frameId frame) || null (frameLabel frame) || frameId frame `elem` descentFrameIds ->
                Just (InvalidEmptyChildFrame (frameId frame))
            | otherwise -> Nothing
        (_ : (index, _, _) : _) -> Just (MisplacedEmptyChildFrame index)
    descentFailure = firstJust (map descentFailureFor (zip [1 :: Int ..] descentFrameIds))
    descentFailureFor (position, fid)
        | position == length descentFrameIds =
            if declared > 0 && (declared > 1 || null emptyChildDeclarations) then Just (DescentFromInnermostFrame fid) else Nothing
        | declared == 0 = Just (MissingFrameDescent fid)
        | declared > 1 = Just (DuplicateFrameDescent fid declared)
        | otherwise = Nothing
      where
        declared =
            length
                [ context
                | step <- normalSteps
                , frameId (stepFrame step) == fid
                , context <- stepDescents step
                ]

stepPlanSteps :: StepPlan -> NonEmpty Step
stepPlanSteps (StepPlan steps) = steps

renderChainPlan :: StepPlan -> String
renderChainPlan plan = unlines (zipWith line [1 :: Int ..] (NonEmpty.toList (stepPlanSteps plan)))
  where
    line number step = show number ++ ". " ++ renderStep step

stepsForFrame :: String -> StepPlan -> [Step]
stepsForFrame fid = filter ((== fid) . frameId . stepFrame) . NonEmpty.toList . stepPlanSteps

preHandoffStepsForFrame :: String -> StepPlan -> [Step]
preHandoffStepsForFrame fid = filter (not . isPostHandoffStep) . stepsForFrame fid

postHandoffStepsForFrame :: String -> StepPlan -> [Step]
postHandoffStepsForFrame fid = filter isPostHandoffStep . stepsForFrame fid

{- | The descent context frame @fid@ declared, or 'Nothing' for the innermost
frame (and for a frame the chain never enters). Validation guarantees at most
one, so this is total rather than a first-wins choice.
-}
frameDescent :: String -> StepPlan -> Maybe LiftContext
frameDescent fid plan =
    case concatMap stepDescents (preHandoffStepsForFrame fid plan) of
        (context : _) -> Just context
        [] -> Nothing

{- | The frames the plan traverses, outermost first.

Non-empty for the plan's own reason: the first step is never a post-handoff one,
because 'mkStepPlan' refuses a post-handoff step naming a frame no normal step
declared — so a plan of nothing but post-handoff steps does not exist.
-}
chainFrames :: StepPlan -> NonEmpty StepFrame
chainFrames plan = stepFrame firstStep :| (foldl addFrame [] normalRest ++ emptyChild)
  where
    firstStep :| rest = stepPlanSteps plan
    normalRest = takeWhile (not . isPostHandoffStep) rest
    -- Admission allows at most one, on the innermost frame's descending step.
    emptyChild = take 1 (concatMap stepEmptyChildFrames (firstStep : normalRest))
    addFrame frames step
        | frameId (stepFrame step) `elem` map frameId (stepFrame firstStep : frames) = frames
        | otherwise = frames ++ [stepFrame step]

{- | The exact validated prefix a step depends on. Because plan identities are
unique, the target is unambiguous; a step outside the plan has no dependency
witness.
-}
stepDependencies :: StepPlan -> Step -> [StepIdentity]
stepDependencies plan target =
    case break ((== stepIdentity target) . stepIdentity) (NonEmpty.toList (stepPlanSteps plan)) of
        (before, _ : _) -> map stepIdentity before
        (_, []) -> []

-- | The shared post-descent classification for validation and interpretation.
isPostHandoffStep :: Step -> Bool
isPostHandoffStep step =
    case stepKind step of
        CoreKind DeployVMId -> False
        CoreKind (EnsureToolId _) -> False
        CoreKind CopySourceId -> False
        CoreKind BuildPbId -> False
        CoreKind BuildImageId -> False
        CoreKind ContextInitId -> False
        CoreKind DeployKindId -> False
        CoreKind DeployChartId -> False
        CoreKind ExposePortId -> False
        CoreKind (PostHandoffId _) -> True
        ProjectKind _ -> False

firstIndexed :: (a -> Bool) -> [a] -> Maybe (Int, a)
firstIndexed predicate values =
    case filter (predicate . snd) (zip [1 ..] values) of
        [] -> Nothing
        found : _ -> Just found

firstJust :: [Maybe a] -> Maybe a
firstJust [] = Nothing
firstJust (Nothing : rest) = firstJust rest
firstJust (Just value : _) = Just value

unique :: (Eq a) => [a] -> [a]
unique = foldl add []
  where
    add seen value
        | value `elem` seen = seen
        | otherwise = seen ++ [value]

duplicates :: (Ord a) => [a] -> [a]
duplicates values = [value | value : _ : _ <- group (sort values)]

firstReturnedFrame :: [String] -> Maybe String
firstReturnedFrame [] = Nothing
firstReturnedFrame (firstFrame : rest) = go firstFrame [] rest
  where
    go _ _ [] = Nothing
    go current closed (next : remaining)
        | next == current = go current closed remaining
        | next `elem` closed = Just next
        | otherwise = go next (current : closed) remaining

coreStep ::
    CoreStepId ->
    ReversePolicy ->
    String ->
    StepFrame ->
    StepAction ->
    Step
coreStep identity reversePolicy label frame action =
    Step
        label
        frame
        (CoreKind identity)
        reversePolicy
        initialStepImplementationRevision
        initialStepReverseAdapterRevision
        action
        []
        []
        []
        []
        []
        []
        []
        []
        []
        []
        []
        Nothing
        Nothing

deployVMStep :: String -> StepFrame -> StepAction -> Step
deployVMStep = coreStep DeployVMId ProjectManagedReverse

ensureStep :: String -> String -> StepFrame -> StepAction -> Step
ensureStep tool = coreStep (EnsureToolId tool) PreserveOnReverse

copySourceStep :: String -> StepFrame -> StepAction -> Step
copySourceStep = coreStep CopySourceId ProjectManagedReverse

buildPbStep :: String -> StepFrame -> StepAction -> Step
buildPbStep = coreStep BuildPbId ProjectManagedReverse

buildImageStep :: String -> StepFrame -> StepAction -> Step
buildImageStep = coreStep BuildImageId ProjectManagedReverse

contextInitStep :: String -> StepFrame -> StepAction -> Step
contextInitStep = coreStep ContextInitId ProjectManagedReverse

deployKindStep :: String -> StepFrame -> StepAction -> Step
deployKindStep = coreStep DeployKindId CoreManagedReverse

deployChartStep :: String -> StepFrame -> StepAction -> Step
deployChartStep = coreStep DeployChartId CoreManagedReverse

exposePortStep :: String -> StepFrame -> StepAction -> Step
exposePortStep = coreStep ExposePortId CoreManagedReverse

postHandoffStep :: String -> String -> StepFrame -> StepAction -> Step
postHandoffStep name = coreStep (PostHandoffId name) ProjectManagedReverse

projectStep ::
    ProjectStepId ->
    ReversePolicy ->
    String ->
    StepFrame ->
    StepAction ->
    Step
projectStep identity reversePolicy label frame action =
    Step
        label
        frame
        (ProjectKind identity)
        reversePolicy
        initialStepImplementationRevision
        initialStepReverseAdapterRevision
        action
        []
        []
        []
        []
        []
        []
        []
        []
        []
        []
        []
        Nothing
        Nothing
