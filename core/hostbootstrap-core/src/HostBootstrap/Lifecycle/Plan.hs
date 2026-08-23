{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Canonical, non-secret lifecycle-plan snapshots.

The encoder is deliberately independent of 'Show' instances and delimiter
joining. Every variable-width value is length-framed, every list carries an
explicit count, and the fixed header carries a format version. Executable
callbacks are not serializable and are never inspected or rendered. Instead,
the snapshot records closed implementation and reverse-adapter identities made
from the step's typed identity, declared reverse shape, and explicit positive
implementation/adapter revisions.

The exact canonical project root is length-framed into the snapshot before the
plan identities. Configuration enters this representation only through the
specification and configuration digests retained by the validated config
evidence and as the digest of an in-place child-config payload. The raw payload
is never present in the canonical bytes.
-}
module HostBootstrap.Lifecycle.Plan
    ( PlanDraft
    , ProjectPlan
    , PlannedStep (..)
    , PlannedResource
    , ProviderResource
    , DurableShareResource
    , DurableAliasResource
    , DockerResource
    , MinioResource
    , RegistryResource
    , ClusterResource
    , ChartWorkloadResource
    , withProjectChartWorkloadResourceKernel
    , chartWorkloadResourceKeyKernel
    , chartWorkloadResourceFrameKernel
    , chartWorkloadReverseIdentityKernel
    , withChartWorkloadResourceDetailsKernel
    , PlannedResourceKind (..)
    , PlannedEdge
    , DerivedTopology (..)
    , StablePlanSnapshot (..)
    , IndexedPlanSnapshot (..)
    , PlanDigestBinding
    , BoundPlanSnapshot
    , PlanError (..)
    , planDraftsFromValidatedStepPlanKernel
    , canonicalProjectedRootKernel
    , withProjectPlanKernel
    , withProjectedProjectPlanKernel
    , withChildProjectPlanKernel
    , withRecoveredProjectPlanKernel
    , withProspectiveProjectPlanKernel
    , withCompletedMigrationProjectPlanKernel
    , forwardKernel
    , plannedStepLabelKernel
    , plannedStepFrameIdKernel
    , plannedStepFrameLabelKernel
    , plannedStepOperationKeyKernel
    , plannedStepDependencyOperationsKernel
    , plannedStepProjectedOperationKeysKernel
    , runPlannedStepKernel
    , plannedResourceKeyKernel
    , plannedResourceFrameKernel
    , plannedResourcePlanDigestKernel
    , plannedEdgeTargetKeyKernel
    , plannedEdgeDependencyKeyKernel
    , plannedResourceFamilyKeysKernel
    , withProjectPlannedResourceOfKindKernel
    , withProjectPlannedEdgeKernel
    , withProjectProviderGuestAliasProjectionKernel
    , withPlannedStepResourceOfKindKernel
    , withPlannedStepGuestAliasProjectionKernel
    , withCompatibilityNodeResourceOfKindKernel
    , withCompatibilityNodeGuestAliasProjectionKernel
    , topologyKernel
    , topologyFrameOrderKernel
    , topologyParentEdgesKernel
    , topologyDescentEdgesKernel
    , topologyContainsFrameKernel
    , topologyFrameLabelKernel
    , topologyParentFrameKernel
    , topologyDescentFromKernel
    , renderSnapshotKernel
    , stablePlanSnapshotFormatVersionKernel
    , stablePlanSnapshotRootKernel
    , stablePlanSnapshotSpecDigestKernel
    , stablePlanSnapshotConfigDigestKernel
    , stablePlanSnapshotBytesKernel
    , stablePlanSnapshotDigestKernel
    , projectPlanProfileNameKernel
    , projectPlanProfileEpochKernel
    , projectPlanProfileProjectNameKernel
    , projectPlanProfileStoreIdentityKernel
    , projectPlanValidatedConfigKernel
    , projectPlanStepPlanKernel
    , projectPlanCanonicalSnapshotKernel
    , projectPlanIndexedSnapshotKernel
    , projectPlanExecutionTermsKernel
    , withExecutionChartWorkloadResourceKernel
    , indexedPlanSnapshotCanonicalKernel
    , mintPlanDigestBindingKernel
    , planDigestBindingDigestKernel
    , mintBoundPlanSnapshotKernel
    , boundPlanSnapshotBytesKernel
    , ExistingBoundSnapshotAdmission
    , existingBoundSnapshotAdmissionKernel
    , consumeExistingBoundSnapshotAdmissionKernel
    , AcquisitionJournalAdmission
    , acquisitionJournalAdmissionKernel
    , consumeAcquisitionJournalAdmissionKernel
    , admitPersistedCanonicalPlanSnapshotKernel
    , withPersistedBoundPlanSnapshotKernel
    , CanonicalPlanSnapshot
    , canonicalPlanSnapshot
    , canonicalPlanSnapshotFormatVersion
    , compatibilityLifecyclePlanRoot
    , canonicalPlanSnapshotRoot
    , canonicalPlanSnapshotSpecDigest
    , canonicalPlanSnapshotConfigDigest
    , canonicalPlanSnapshotBytes
    , canonicalPlanSnapshotDigest
    , canonicalPlanResourceMembersKernel
    , canonicalPlanRecoveryFramesKernel
    , StepImplementationId
    , stepImplementationId
    , ReverseAdapterId
    , reverseAdapterId
    )
where

import qualified Crypto.Hash as Hash
import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import qualified Data.ByteArray as ByteArray
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Char (chr, ord)
import Data.List (find)
import qualified Data.List as List
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Kind (Type)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word32, Word64)
import HostBootstrap.Config.Vocab (Mount (..))
import HostBootstrap.Config.Schema
    ( ValidatedConfig
    , validatedConfigDigest
    , validatedConfigSpecDigest
    )
import HostBootstrap.Lifecycle.Execution (StepExecution)
import HostBootstrap.Lift.Context
    ( ConfigDelivery (..)
    , ContainerLift (..)
    , IncusVM (..)
    , LiftContext (..)
    , LiftLayer (..)
    , LimaVM (..)
    , Wsl2VM (..)
    )
import HostBootstrap.ProjectRoot
    ( CanonicalProjectRoot
    , canonicalProjectRootPath
    )
import HostBootstrap.Step
    ( CoreStepId (..)
    , OperationKey
    , ProviderResourceDeclaration
    , ReversePolicy (..)
    , Step
    , StepFrame
    , StepIdentity (..)
    , StepImplementationRevision
    , StepObservation
    , StepPlan
    , StepPlanError
    , StepReverseAdapterRevision
    , chainFrames
    , frameDescent
    , frameId
    , frameLabel
    , operationKeyText
    , stepDependencies
    , stepDescents
    , stepFrame
    , stepIdentity
    , stepImplementationRevision
    , stepImplementationRevisionNumber
    , stepLabel
    , stepOperationKey
    , stepProjectedOperations
    , stepProviderResourceDeclarations
    , stepChartWorkloadResourceDeclarations
    , providerResourceDeclarationTargetsChild
    , runStep
    , mkStepPlan
    , stepPlanSteps
    , stepReversePolicy
    , stepReverseAdapterRevision
    , stepReverseAdapterRevisionNumber
    , stepReverses
    )
import System.FilePath (isAbsolute)
import qualified System.FilePath.Posix as Posix

{- | One authored node before a local plan identity exists.

The constructor is private.  The retained root, specification digest, and
configuration digest all come from opaque evidence at the draft-construction
boundary; they are checked again when independently authored streams are
combined into one project plan.
-}
data PlanDraft scope specDigest config = PlanDraft
    { internalDraftRoot :: FilePath
    , internalDraftSpecDigest :: Text
    , internalDraftConfigDigest :: Text
    , internalDraftStep :: Step
    }

type role PlanDraft nominal nominal nominal

data ChartWorkloadResource scope planId resourceId frame = ChartWorkloadResource
    Text Text Text Text Text Text Text Text [Text] Text Text Text Text

type role ChartWorkloadResource nominal nominal nominal nominal

chartWorkloadResourceKeyKernel :: ChartWorkloadResource scope planId resourceId frame -> Text
chartWorkloadResourceKeyKernel (ChartWorkloadResource _ _ _ _ _ _ _ _ _ key _ _ _) = key

chartWorkloadResourceFrameKernel :: ChartWorkloadResource scope planId resourceId frame -> Text
chartWorkloadResourceFrameKernel (ChartWorkloadResource _ _ _ _ _ _ _ _ _ _ frame _ _) = frame

chartWorkloadReverseIdentityKernel :: ChartWorkloadResource scope planId resourceId frame -> (Text, Text, Text)
chartWorkloadReverseIdentityKernel (ChartWorkloadResource _ release namespace _ _ workloadKey _ _ _ _ _ _ _) = (release, namespace, workloadKey)

withChartWorkloadResourceDetailsKernel ::
    ChartWorkloadResource scope planId resourceId frame ->
    (Text -> Text -> Text -> Text -> Text -> Text -> Text -> Text -> [Text] -> Text -> Text -> result) ->
    result
withChartWorkloadResourceDetailsKernel
    (ChartWorkloadResource artifact release namespace values image workloadKey workloadDigest role effects _ _ planDigest clusterKey)
    consume = consume artifact release namespace values image workloadKey workloadDigest role effects planDigest clusterKey

{- | The sole admitted project graph.

Every field is retained only in this hidden representation kernel.  Public
consumers observe the graph through the typed projections introduced by the
subsequent projection sprints.
-}
data ProjectPlan scope specDigest planId configId (cfg :: Type -> Type)
    = ProjectPlan
        Text
        Word64
        Text
        Text
        FilePath
        (ValidatedConfig scope specDigest configId (cfg scope))
        StepPlan
        (DerivedTopology scope planId)
        (IndexedPlanSnapshot scope specDigest planId configId)

type role ProjectPlan nominal nominal nominal nominal nominal

{- | One forward node projected from an exact admitted plan.

The ordered dependency view is retained beside the opaque executable node so
later interpreters do not need the whole graph, or a second dependency
derivation, to mint the node's execution descriptor.
-}
data PlannedStep scope planId configId config
    = PlannedStep Text Step [(OperationKey, Text)]

type role PlannedStep nominal nominal nominal nominal

{- | One resource identity projected from an exact admitted plan.

The constructor is private to this kernel.  The stable operation key and frame
are always read from the validated graph, while the digest is retained only so
later reconciliation gates can reject a value from another interpretation.
-}
data PlannedResource scope planId resourceId resource frame
    = PlannedResource Text Text Text

type role PlannedResource nominal nominal nominal nominal nominal

data ProviderResource
data DurableShareResource
data DurableAliasResource
data DockerResource
data MinioResource
data RegistryResource
data ClusterResource

-- | The closed relation between a resource family and its plan operation.
data PlannedResourceKind resource where
    ProviderResourceKind :: PlannedResourceKind ProviderResource
    DurableShareResourceKind :: PlannedResourceKind DurableShareResource
    DockerResourceKind :: PlannedResourceKind DockerResource
    MinioResourceKind :: PlannedResourceKind MinioResource
    RegistryResourceKind :: PlannedResourceKind RegistryResource
    ClusterResourceKind :: PlannedResourceKind ClusterResource

type role PlannedResourceKind nominal

-- | One exact dependency edge between two resources of the same plan.
data PlannedEdge scope planId targetId target targetFrame dependencyId dependency dependencyFrame
    = PlannedEdge Text Text

type role PlannedEdge nominal nominal nominal nominal nominal nominal nominal nominal

-- | One internal frame and its exact chain edges.
data TopologyFrame = TopologyFrame
    { internalTopologyFrameId :: Text
    , internalTopologyFrameLabel :: Text
    , internalTopologyParent :: Maybe Text
    , internalTopologyDescent :: Maybe (Text, LiftContext)
    }

{- | The topology projected from an exact admitted plan.

The ordered membership is non-empty.  Parent and descent edges are retained in
the same nodes and were derived while the admitted 'StepPlan' was still in
scope, so no public caller can supply either graph independently.
-}
data DerivedTopology scope planId = DerivedTopology (NonEmpty TopologyFrame)

type role DerivedTopology nominal nominal

-- | Pure canonical bytes projected from an exact admitted plan.
newtype StablePlanSnapshot = StablePlanSnapshot CanonicalPlanSnapshot
    deriving (Eq)

instance Show StablePlanSnapshot where
    show (StablePlanSnapshot snapshot) = show snapshot

{- | The kernel-retained brand joining canonical bytes to the exact admitted
scope, specification, local plan identity, and validated configuration.

The public 'StablePlanSnapshot' remains an unindexed, non-authorizing byte
view.  Persistence and recovery leaves instead consume this internal branded
value through the exact 'ProjectPlan', so verified bytes cannot be relabelled
with a caller-selected phantom.
-}
newtype IndexedPlanSnapshot scope specDigest planId configId
    = IndexedPlanSnapshot CanonicalPlanSnapshot

type role IndexedPlanSnapshot nominal nominal nominal nominal

{- | The checked relation between one local plan identity and one stable plan
digest.

The constructor stays in this hidden kernel.  The value contains no command,
journal, cursor, lease, or mutation capability; the snapshot evidence leaf is
the only fresh public producer.
-}
newtype PlanDigestBinding scope specDigest planDigest planId
    = PlanDigestBinding Text

type role PlanDigestBinding nominal nominal nominal nominal

{- | Exact canonical snapshot bytes interpreted under one verified stable
digest and one local plan identity.

The constructor stays in this hidden kernel.  The fresh public evidence leaf
mints the value only after the indexed snapshot has passed protected
verification and only beside its matching 'PlanDigestBinding'.  The value is
descriptive evidence: it grants no lease, journal, cursor, command, or mutation
authority.
-}
newtype BoundPlanSnapshot scope specDigest planDigest planId
    = BoundPlanSnapshot CanonicalPlanSnapshot

type role BoundPlanSnapshot nominal nominal nominal nominal

-- | Hidden-leaf access to the exact lifecycle profile that admitted a plan.
projectPlanProfileNameKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    Text
projectPlanProfileNameKernel (ProjectPlan profileName _ _ _ _ _ _ _ _) = profileName

-- | Hidden-leaf access to the broker epoch retained at plan admission.
projectPlanProfileEpochKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    Word64
projectPlanProfileEpochKernel (ProjectPlan _ profileEpoch _ _ _ _ _ _ _) = profileEpoch

-- | Hidden-leaf access to the installed project retained at plan admission.
projectPlanProfileProjectNameKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    Text
projectPlanProfileProjectNameKernel (ProjectPlan _ _ projectName _ _ _ _ _ _) = projectName

-- | Hidden-leaf access to the protected store retained at plan admission.
projectPlanProfileStoreIdentityKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    Text
projectPlanProfileStoreIdentityKernel (ProjectPlan _ _ _ storeIdentity _ _ _ _ _) = storeIdentity

{- | Hidden-leaf access to the exact validated configuration retained by a
plan.  Evidence leaves use this projection to compare descriptive inputs with
the admitted configuration; the public pure facade does not expose it.
-}
projectPlanValidatedConfigKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    ValidatedConfig scope specDigest configId (cfg scope)
projectPlanValidatedConfigKernel (ProjectPlan _ _ _ _ _ config _ _ _) = config

-- | Package-private access to the exact validated graph retained by a plan.
projectPlanStepPlanKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    StepPlan
projectPlanStepPlanKernel (ProjectPlan _ _ _ _ _ _ plan _ _) = plan

{- | Project only canonical, backend-neutral execution terms from one exact
plan and one of its opaque forward nodes. Construction of the execution package
itself belongs solely to the reconciler, keeping this kernel independent of
the execution representation.
-}
projectPlanExecutionTermsKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    PlannedStep scope planId configId (cfg scope) ->
    ( (Text, Text, Text, Text)
    , (Text, Word64, Text, FilePath)
    , (Text, Text, [(Text, Text)], [Text], Maybe (Text, Text, Text, Text, Text, Text, Text, Text, [Text], Text))
    )
projectPlanExecutionTermsKernel plan plannedStep =
    ( ( validatedConfigSpecDigest (projectPlanValidatedConfigKernel plan)
      , canonicalPlanSnapshotDigest snapshot
      , canonicalPlanSnapshotConfigDigest snapshot
      , Text.pack (show (stepIdentity step))
      )
    , ( projectPlanProfileNameKernel plan
      , projectPlanProfileEpochKernel plan
      , projectPlanProfileProjectNameKernel plan
      , canonicalPlanSnapshotRoot snapshot
      )
    , ( Text.pack (operationKeyText (stepOperationKey step))
      , Text.pack (frameId (stepFrame step))
      , [(Text.pack (operationKeyText key), frame) | (key, frame) <- dependencies]
      , map (Text.pack . operationKeyText) (stepProjectedOperations step)
      , chartDeclaration
      )
    )
  where
    snapshot = projectPlanCanonicalSnapshotKernel plan
    PlannedStep _ step dependencies = plannedStep
    chartDeclaration =
        either (const Nothing) Just $
            withProjectChartWorkloadResourceKernel plan (stepOperationKey step) $ \chart ->
                withChartWorkloadResourceDetailsKernel chart $ \artifact release namespace values image workloadKey workloadDigest role effects _planDigest clusterKey ->
                    (artifact, release, namespace, values, image, workloadKey, workloadDigest, role, effects, clusterKey)

withExecutionChartWorkloadResourceKernel ::
    Text -> Text -> Text ->
    Maybe (Text, Text, Text, Text, Text, Text, Text, Text, [Text], Text) ->
    (forall resourceId frame. ChartWorkloadResource scope planId resourceId frame -> result) ->
    Either PlanError result
withExecutionChartWorkloadResourceKernel planDigest operation frame declaration consume =
    case declaration of
        Nothing -> Left (PlanResourceOperationMissing operation)
        Just (artifact, release, namespace, values, image, workloadKey, workloadDigest, role, effects, clusterKey) ->
            Right (consume (ChartWorkloadResource artifact release namespace values image workloadKey workloadDigest role effects operation frame planDigest clusterKey))

-- | Package-private access used by the transitional reconciliation consumer.
projectPlanCanonicalSnapshotKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    CanonicalPlanSnapshot
projectPlanCanonicalSnapshotKernel
    (ProjectPlan _ _ _ _ _ _ _ _ (IndexedPlanSnapshot snapshot)) = snapshot

-- | Hidden-leaf access to the exact branded snapshot retained by a plan.
projectPlanIndexedSnapshotKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    IndexedPlanSnapshot scope specDigest planId configId
projectPlanIndexedSnapshotKernel (ProjectPlan _ _ _ _ _ _ _ _ snapshot) = snapshot

-- | Hidden-leaf access to canonical bytes without weakening the snapshot's
-- indices at the function boundary.
indexedPlanSnapshotCanonicalKernel ::
    IndexedPlanSnapshot scope specDigest planId configId ->
    CanonicalPlanSnapshot
indexedPlanSnapshotCanonicalKernel (IndexedPlanSnapshot snapshot) = snapshot

{- | Trusted evidence-leaf constructor.

The indexed snapshot supplies the existing scope, specification, and local
plan identities.  The hidden caller may instantiate @planDigest@ only after
the lifecycle-mode verifier has read and matched the protected snapshot.
-}
mintPlanDigestBindingKernel ::
    IndexedPlanSnapshot scope specDigest planId configId ->
    Text ->
    PlanDigestBinding scope specDigest planDigest planId
mintPlanDigestBindingKernel _ digest = PlanDigestBinding digest

-- | Hidden-leaf access to the digest retained by an exact local binding.
planDigestBindingDigestKernel ::
    PlanDigestBinding scope specDigest planDigest planId ->
    Text
planDigestBindingDigestKernel (PlanDigestBinding digest) = digest

{- | Bind the exact indexed canonical bytes to the stable digest witnessed by
the matching local digest binding.

The public snapshot leaf calls this only inside the successful continuation of
the exact indexed verifier.  Taking the binding as an argument keeps
@planDigest@ and @planId@ identical in both values without introducing another
quantifier.
-}
mintBoundPlanSnapshotKernel ::
    IndexedPlanSnapshot scope specDigest planId configId ->
    PlanDigestBinding scope specDigest planDigest planId ->
    BoundPlanSnapshot scope specDigest planDigest planId
mintBoundPlanSnapshotKernel (IndexedPlanSnapshot snapshot) _ =
    BoundPlanSnapshot snapshot

-- | Non-authorizing projection of the exact verified canonical bytes.
boundPlanSnapshotBytesKernel ::
    BoundPlanSnapshot scope specDigest planDigest planId ->
    ByteString
boundPlanSnapshotBytesKernel (BoundPlanSnapshot snapshot) =
    canonicalPlanSnapshotBytes snapshot

{- | Unforgeable package-local witness for the existing-bound recovery leaf.

The lifecycle mode module is public for historical reasons, so its lower-level
kernel takes this hidden witness.  The public snapshot facade supplies the sole
real value and the mode kernel forces it before entering the protected store;
passing bottom therefore cannot turn that lower-level seam into a second
admission API.
-}
data ExistingBoundSnapshotAdmission = ExistingBoundSnapshotAdmission

existingBoundSnapshotAdmissionKernel :: ExistingBoundSnapshotAdmission
existingBoundSnapshotAdmissionKernel = ExistingBoundSnapshotAdmission

consumeExistingBoundSnapshotAdmissionKernel :: ExistingBoundSnapshotAdmission -> ()
consumeExistingBoundSnapshotAdmissionKernel ExistingBoundSnapshotAdmission = ()

{- | Unforgeable package-local witness for the sole public acquisition-journal
admission in "HostBootstrap.Lifecycle.Mode".

The cycle-free durable implementation is split between lifecycle Mode (which
owns the bound lease and its retained store) and Session (which owns the
dedicated protected acquisition record). Their lower kernels therefore need one value
that public callers cannot construct.  Both kernels force this witness before
reading or writing the protected store, so passing bottom cannot open a second
admission path.
-}
data AcquisitionJournalAdmission = AcquisitionJournalAdmission

acquisitionJournalAdmissionKernel :: AcquisitionJournalAdmission
acquisitionJournalAdmissionKernel = AcquisitionJournalAdmission

consumeAcquisitionJournalAdmissionKernel :: AcquisitionJournalAdmission -> ()
consumeAcquisitionJournalAdmissionKernel AcquisitionJournalAdmission = ()

{- | Reconstruct the descriptive canonical snapshot retained in a durable
record.

This proves the current header/version, the exact embedded canonical-root and
specification/configuration prefix, the complete canonical shape of every
encoded step, and the content-derived digest.  It does not reconstruct
executable callbacks or recover the graph's semantic evidence; full graph
reconstruction and equality remain a later admission phase.
-}
admitPersistedCanonicalPlanSnapshotKernel ::
    Text ->
    Text ->
    Maybe Text ->
    Maybe ByteString ->
    Either Text CanonicalPlanSnapshot
admitPersistedCanonicalPlanSnapshotKernel specDigest planDigest maybeConfig maybeBytes = do
    configDigest <-
        maybe (Left "the canonical configuration digest is missing") Right maybeConfig
    bytes <- maybe (Left "the canonical plan bytes are missing") Right maybeBytes
    require (not (Text.null specDigest)) "the canonical specification digest is empty"
    require (not (Text.null configDigest)) "the canonical configuration digest is empty"
    require (not (Text.null planDigest)) "the canonical plan digest is empty"
    require (not (ByteString.null bytes)) "the canonical plan bytes are empty"
    remainder0 <-
        maybe
            (Left "the canonical plan header is malformed")
            Right
            (ByteString.stripPrefix canonicalPlanMagic bytes)
    (formatVersion, remainder1) <-
        maybe (Left "the canonical plan version is malformed") Right (takeWord64BE remainder0)
    require
        (formatVersion == canonicalPlanSnapshotFormatVersion)
        "the canonical plan version is unsupported"
    remainderAfterRootTag <- consumeCanonicalTag "root" remainder1
    (rootBytes, remainder2) <-
        maybe
            (Left "the canonical project root is malformed")
            Right
            (takeLengthFrame remainderAfterRootTag)
    root <- decodeCanonicalRoot rootBytes
    require
        (root == compatibilityLifecyclePlanRoot || isAbsolute root)
        "the canonical project root is neither absolute nor the compatibility sentinel"
    remainder3 <- requireTaggedText "spec-digest" specDigest remainder2
    remainder4 <- requireTaggedText "config-digest" configDigest remainder3
    (stepsTag, remainder5) <-
        maybe (Left "the canonical steps tag is malformed") Right (takeLengthFrame remainder4)
    require (stepsTag == "steps") "the canonical steps tag is malformed"
    (stepCount, stepBytes) <-
        maybe (Left "the canonical step count is malformed") Right (takeWord64BE remainder5)
    require (stepCount > 0) "the canonical step stream is empty"
    require (not (ByteString.null stepBytes)) "the canonical step stream is truncated"
    trailing <- consumeCanonicalItems "step stream" stepCount consumeCanonicalStep stepBytes
    require (ByteString.null trailing) "the canonical plan has trailing bytes"
    let expectedDigest = specDigest <> ":" <> sha256Hex bytes
    require (planDigest == expectedDigest) "the canonical plan digest does not match its bytes"
    Right
        CanonicalPlanSnapshot
            { internalSnapshotRoot = root
            , internalSnapshotSpecDigest = specDigest
            , internalSnapshotConfigDigest = configDigest
            , internalSnapshotBytes = bytes
            , internalSnapshotDigest = planDigest
            }
  where
    require condition failure
        | condition = Right ()
        | otherwise = Left failure

{- | Decode the exact durable resource key space from a structurally admitted
snapshot.  A reverse-managed step contributes its own operation and every
projected relation contributes a member in the declaring frame.  The decoder
uses the snapshot's versioned grammar rather than caller-supplied lists.
-}
canonicalPlanResourceMembersKernel :: CanonicalPlanSnapshot -> Either Text [(Text, Text)]
canonicalPlanResourceMembersKernel snapshot = do
    remainder0 <-
        maybe (Left "the canonical plan header is malformed") Right $
            ByteString.stripPrefix canonicalPlanMagic (canonicalPlanSnapshotBytes snapshot)
    (formatVersion, remainder1) <-
        maybe (Left "the canonical plan version is malformed") Right (takeWord64BE remainder0)
    requireCanonical
        (formatVersion == canonicalPlanSnapshotFormatVersion)
        "the canonical plan version is unsupported"
    remainderAfterRoot <- consumeCanonicalTag "root" remainder1
    (_rootBytes, remainder2) <-
        maybe (Left "the canonical project root is malformed") Right (takeLengthFrame remainderAfterRoot)
    remainder3 <- consumeCanonicalTaggedText "spec-digest" remainder2
    remainder4 <- consumeCanonicalTaggedText "config-digest" remainder3
    remainder5 <- consumeCanonicalTag "steps" remainder4
    (count, stepBytes) <- takeCanonicalWord "steps count" remainder5
    (members, trailing) <- decodeMembers count stepBytes
    requireCanonical (ByteString.null trailing) "the canonical plan has trailing bytes"
    let sorted = List.sort members
    requireCanonical
        (length sorted == length (List.nub sorted))
        "the canonical resource member set contains a duplicate"
    Right sorted
  where
    decodeMembers 0 input = Right ([], input)
    decodeMembers remaining input = do
        (current, trailing) <- decodeStepMembers input
        (rest, final) <- decodeMembers (remaining - 1) trailing
        Right (current <> rest, final)

-- | Decode the non-secret frame and reverse-adapter coordinates needed by
-- configless recovery. The same strict canonical grammar and trailing-byte
-- check as resource membership applies.
canonicalPlanRecoveryFramesKernel :: CanonicalPlanSnapshot -> Either Text [(Text, Text, Word64)]
canonicalPlanRecoveryFramesKernel snapshot = do
    remainder0 <- maybe (Left "the canonical plan header is malformed") Right $
        ByteString.stripPrefix canonicalPlanMagic (canonicalPlanSnapshotBytes snapshot)
    (formatVersion, remainder1) <- maybe (Left "the canonical plan version is malformed") Right (takeWord64BE remainder0)
    requireCanonical (formatVersion == canonicalPlanSnapshotFormatVersion) "the canonical plan version is unsupported"
    remainderAfterRoot <- consumeCanonicalTag "root" remainder1
    (_rootBytes, remainder2) <- maybe (Left "the canonical project root is malformed") Right (takeLengthFrame remainderAfterRoot)
    remainder3 <- consumeCanonicalTaggedText "spec-digest" remainder2
    remainder4 <- consumeCanonicalTaggedText "config-digest" remainder3
    remainder5 <- consumeCanonicalTag "steps" remainder4
    (count, stepBytes) <- takeCanonicalWord "steps count" remainder5
    (frames, trailing) <- go count stepBytes
    requireCanonical (ByteString.null trailing) "the canonical plan has trailing bytes"
    Right frames
  where
    go 0 input = Right ([], input)
    go remaining input = do
        (frame, trailing) <- decodeRecoveryFrame input
        (rest, final) <- go (remaining - 1) trailing
        Right (frame : rest, final)

decodeRecoveryFrame :: ByteString -> Either Text ((Text, Text, Word64), ByteString)
decodeRecoveryFrame input = do
    remainder0 <- consumeCanonicalRecordHeader "step" 13 input
    (_ordinal, remainder1) <- consumeCanonicalTaggedWord "ordinal" remainder0
    remainder2 <- consumeCanonicalTag "identity" remainder1 >>= consumeCanonicalStepIdentity
    remainder3 <- consumeCanonicalTag "implementation" remainder2 >>= consumeCanonicalImplementation
    remainder4 <- consumeCanonicalTaggedText "operation" remainder3
    remainder5 <- consumeCanonicalTextList "projected-operations" remainder4
    remainder5a <- consumeCanonicalProviderResources remainder5
    remainder5b <- consumeCanonicalList "chart-workloads" consumeCanonicalChartWorkload remainder5a
    remainder6 <- consumeCanonicalTaggedText "label" remainder5b
    (frame, remainder7) <- takeCanonicalFrame remainder6
    remainder8 <- consumeCanonicalList "dependencies" consumeCanonicalDependencyIdentity remainder7
    remainder9 <- consumeCanonicalTag "reverse-policy" remainder8 >>= consumeCanonicalReversePolicy
    remainder10 <- consumeCanonicalTag "reverse-adapter" remainder9
    ((kind, revision), remainder11) <- takeCanonicalRecoveryAdapter remainder10
    trailing <- consumeCanonicalList "descents" consumeCanonicalLiftContext remainder11
    Right ((frame, kind, revision), trailing)

takeCanonicalRecoveryAdapter :: ByteString -> Either Text ((Text, Word64), ByteString)
takeCanonicalRecoveryAdapter input = do
    (kind, remainder0) <- takeCanonicalText "reverse adapter" input
    (fieldCount, remainder1) <- takeCanonicalWord "reverse adapter field count" remainder0
    requireCanonical (fieldCount == 2) "the canonical reverse adapter field count is malformed"
    remainder2 <- consumeCanonicalTag "implementation" remainder1
    remainder3 <- case kind of
        "preserve" -> consumeCanonicalAbsent "reverse adapter implementation" remainder2
        "core-managed" -> consumeCanonicalPresent "reverse adapter implementation" consumeCanonicalImplementation remainder2
        "project-managed" -> consumeCanonicalPresent "reverse adapter implementation" consumeCanonicalImplementation remainder2
        "step-declared" -> consumeCanonicalPresent "reverse adapter implementation" consumeCanonicalImplementation remainder2
        _ -> Left "the canonical reverse adapter is malformed"
    (revision, trailing) <- consumeCanonicalTaggedWord "revision" remainder3
    requireCanonical (revision > 0) "the canonical reverse adapter revision is malformed"
    Right ((kind, revision), trailing)

decodeStepMembers :: ByteString -> Either Text ([(Text, Text)], ByteString)
decodeStepMembers input = do
    remainder0 <- consumeCanonicalRecordHeader "step" 13 input
    (_ordinal, remainder1) <- consumeCanonicalTaggedWord "ordinal" remainder0
    remainder2 <- consumeCanonicalTag "identity" remainder1 >>= consumeCanonicalStepIdentity
    remainder3 <- consumeCanonicalTag "implementation" remainder2 >>= consumeCanonicalImplementation
    (operation, remainder4) <- takeCanonicalTaggedText "operation" remainder3
    (projected, remainder5) <- takeCanonicalTextList "projected-operations" remainder4
    remainder5a <- consumeCanonicalProviderResources remainder5
    remainder5b <- consumeCanonicalList "chart-workloads" consumeCanonicalChartWorkload remainder5a
    remainder6 <- consumeCanonicalTaggedText "label" remainder5b
    (frame, remainder7) <- takeCanonicalFrame remainder6
    remainder8 <- consumeCanonicalList "dependencies" consumeCanonicalDependencyIdentity remainder7
    remainder9 <- consumeCanonicalTag "reverse-policy" remainder8
    (reverseKind, remainder10) <- takeCanonicalText "reverse policy" remainder9
    remainder11 <- consumeCanonicalEmptyText "reverse policy" remainder10
    remainder12 <- consumeCanonicalTag "reverse-adapter" remainder11 >>= consumeCanonicalReverseAdapter
    trailing <- consumeCanonicalList "descents" consumeCanonicalLiftContext remainder12
    let own = [(frame, operation) | reverseKind /= "preserve"]
    Right (own <> map (\operationKey -> (frame, operationKey)) projected, trailing)

takeCanonicalTaggedText :: Text -> ByteString -> Either Text (Text, ByteString)
takeCanonicalTaggedText tag input =
    consumeCanonicalTag tag input >>= takeCanonicalText (tag <> " value")

takeCanonicalTextList :: Text -> ByteString -> Either Text ([Text], ByteString)
takeCanonicalTextList tag input = do
    remainder <- consumeCanonicalTag tag input
    (count, items) <- takeCanonicalWord (tag <> " count") remainder
    go count items
  where
    go 0 trailing = Right ([], trailing)
    go remaining bytes = do
        (value, trailing) <- takeCanonicalText (tag <> " item") bytes
        (rest, final) <- go (remaining - 1) trailing
        Right (value : rest, final)

consumeCanonicalProviderResources :: ByteString -> Either Text ByteString
consumeCanonicalProviderResources input = do
    remainder <- consumeCanonicalTag "provider-resources" input
    (count, items) <- takeCanonicalWord "provider-resources count" remainder
    go count items
  where
    go 0 trailing = Right trailing
    go remaining bytes = do
        (value, trailing) <- takeCanonicalText "provider-resources item" bytes
        requireCanonical
            (value == "current-frame" || value == "immediate-child")
            "the provider-resource target is malformed"
        go (remaining - 1) trailing

consumeCanonicalChartWorkload :: ByteString -> Either Text ByteString
consumeCanonicalChartWorkload input = do
    remainder0 <- consumeCanonicalRecordHeader "chart-workload" 9 input
    remainder1 <- consumeCanonicalTaggedText "artifact-digest" remainder0
    remainder2 <- consumeCanonicalTaggedText "release" remainder1
    remainder3 <- consumeCanonicalTaggedText "namespace" remainder2
    remainder4 <- consumeCanonicalTaggedText "values-digest" remainder3
    remainder5 <- consumeCanonicalTaggedText "image-identity" remainder4
    remainder6 <- consumeCanonicalTaggedText "workload-key" remainder5
    remainder7 <- consumeCanonicalTaggedText "workload-digest" remainder6
    remainder8 <- consumeCanonicalTaggedText "service-role" remainder7
    consumeCanonicalTextList "effects" remainder8

takeCanonicalFrame :: ByteString -> Either Text (Text, ByteString)
takeCanonicalFrame input = do
    remainder0 <- consumeCanonicalRecordHeader "frame" 2 input
    (frame, remainder1) <- takeCanonicalTaggedText "id" remainder0
    remainder2 <- consumeCanonicalTaggedText "label" remainder1
    Right (frame, remainder2)

{- | Consume exactly the structural grammar emitted by 'encodeStep'.

The decoder deliberately returns no reconstructed step.  Its only result is
the unconsumed suffix, which lets the enclosing list prove both its declared
count and the absence of trailing bytes without manufacturing callbacks or
semantic graph evidence from durable data.
-}
consumeCanonicalStep :: ByteString -> Either Text ByteString
consumeCanonicalStep input = do
    remainder0 <- consumeCanonicalRecordHeader "step" 13 input
    (ordinal, remainder1) <- consumeCanonicalTaggedWord "ordinal" remainder0
    requireCanonical (ordinal > 0) "the canonical step ordinal is malformed"
    remainder2 <- consumeCanonicalTag "identity" remainder1 >>= consumeCanonicalStepIdentity
    remainder3 <- consumeCanonicalTag "implementation" remainder2 >>= consumeCanonicalImplementation
    remainder4 <- consumeCanonicalTaggedText "operation" remainder3
    remainder5 <- consumeCanonicalTextList "projected-operations" remainder4
    remainder5a <- consumeCanonicalProviderResources remainder5
    remainder5b <- consumeCanonicalList "chart-workloads" consumeCanonicalChartWorkload remainder5a
    remainder6 <- consumeCanonicalTaggedText "label" remainder5b
    remainder7 <- consumeCanonicalFrame remainder6
    remainder8 <-
        consumeCanonicalList
            "dependencies"
            consumeCanonicalDependencyIdentity
            remainder7
    remainder9 <- consumeCanonicalTag "reverse-policy" remainder8 >>= consumeCanonicalReversePolicy
    remainder10 <- consumeCanonicalTag "reverse-adapter" remainder9 >>= consumeCanonicalReverseAdapter
    consumeCanonicalList "descents" consumeCanonicalLiftContext remainder10

consumeCanonicalStepIdentity :: ByteString -> Either Text ByteString
consumeCanonicalStepIdentity input = do
    (kind, remainder) <- takeCanonicalText "step identity" input
    case kind of
        "core-step" -> consumeCanonicalCoreStepId remainder
        "project-step" -> consumeCanonicalText "project step identity" remainder
        _ -> Left "the canonical step identity is malformed"

consumeCanonicalDependencyIdentity :: ByteString -> Either Text ByteString
consumeCanonicalDependencyIdentity input = do
    (kind, remainder) <- takeCanonicalText "dependency identity" input
    case kind of
        "core-step" -> consumeCanonicalCoreStepId remainder
        "project-step" -> consumeCanonicalText "project dependency identity" remainder
        _ -> Left "the canonical dependency identity is malformed"

consumeCanonicalCoreStepId :: ByteString -> Either Text ByteString
consumeCanonicalCoreStepId input = do
    (kind, remainder) <- takeCanonicalText "core step identity" input
    case kind of
        "ensure-tool" -> consumeCanonicalText "tool identity" remainder
        "post-handoff" -> consumeCanonicalText "handoff identity" remainder
        "deploy-vm" -> emptyValue remainder
        "copy-source" -> emptyValue remainder
        "build-pb" -> emptyValue remainder
        "build-image" -> emptyValue remainder
        "context-init" -> emptyValue remainder
        "deploy-kind" -> emptyValue remainder
        "deploy-chart" -> emptyValue remainder
        "expose-port" -> emptyValue remainder
        _ -> Left "the canonical core step identity is malformed"
  where
    emptyValue = consumeCanonicalEmptyText "core step identity"

consumeCanonicalImplementation :: ByteString -> Either Text ByteString
consumeCanonicalImplementation input = do
    (kind, remainder0) <- takeCanonicalText "step implementation" input
    (fieldCount, remainder1) <- takeCanonicalWord "step implementation field count" remainder0
    requireCanonical
        (fieldCount == 2)
        "the canonical step implementation field count is malformed"
    case kind of
        "core-implementation" -> do
            remainder2 <- consumeCanonicalTag "identity" remainder1 >>= consumeCanonicalCoreStepId
            consumeCanonicalPositiveTaggedWord "revision" remainder2
        "project-implementation" -> do
            remainder2 <- consumeCanonicalTaggedText "operation" remainder1
            consumeCanonicalPositiveTaggedWord "revision" remainder2
        _ -> Left "the canonical step implementation is malformed"

consumeCanonicalFrame :: ByteString -> Either Text ByteString
consumeCanonicalFrame input = do
    remainder0 <- consumeCanonicalRecordHeader "frame" 2 input
    remainder1 <- consumeCanonicalTaggedText "id" remainder0
    consumeCanonicalTaggedText "label" remainder1

consumeCanonicalReversePolicy :: ByteString -> Either Text ByteString
consumeCanonicalReversePolicy input = do
    (kind, remainder) <- takeCanonicalText "reverse policy" input
    case kind of
        "preserve" -> emptyValue remainder
        "core-managed" -> emptyValue remainder
        "project-managed" -> emptyValue remainder
        _ -> Left "the canonical reverse policy is malformed"
  where
    emptyValue = consumeCanonicalEmptyText "reverse policy"

consumeCanonicalReverseAdapter :: ByteString -> Either Text ByteString
consumeCanonicalReverseAdapter input = do
    (kind, remainder0) <- takeCanonicalText "reverse adapter" input
    (fieldCount, remainder1) <- takeCanonicalWord "reverse adapter field count" remainder0
    requireCanonical
        (fieldCount == 2)
        "the canonical reverse adapter field count is malformed"
    remainder2 <- consumeCanonicalTag "implementation" remainder1
    remainder3 <- case kind of
        "preserve" -> consumeCanonicalAbsent "reverse adapter implementation" remainder2
        "core-managed" -> consumePresentImplementation remainder2
        "project-managed" -> consumePresentImplementation remainder2
        "step-declared" -> consumePresentImplementation remainder2
        _ -> Left "the canonical reverse adapter is malformed"
    consumeCanonicalPositiveTaggedWord "revision" remainder3
  where
    consumePresentImplementation =
        consumeCanonicalPresent
            "reverse adapter implementation"
            consumeCanonicalImplementation

consumeCanonicalLiftContext :: ByteString -> Either Text ByteString
consumeCanonicalLiftContext = consumeCanonicalList "lift-layers" consumeCanonicalLiftLayer

consumeCanonicalLiftLayer :: ByteString -> Either Text ByteString
consumeCanonicalLiftLayer input = do
    (kind, remainder0) <- takeCanonicalText "lift layer" input
    (fieldCount, remainder1) <- takeCanonicalWord "lift layer field count" remainder0
    case kind of
        "incus" -> do
            requireFields 2 fieldCount
            remainder2 <- consumeCanonicalTaggedText "name" remainder1
            consumeCanonicalTaggedText "image" remainder2
        "lima" -> do
            requireFields 1 fieldCount
            consumeCanonicalTaggedText "name" remainder1
        "wsl2" -> do
            requireFields 1 fieldCount
            consumeCanonicalTaggedText "distro" remainder1
        "container" -> do
            requireFields 5 fieldCount
            consumeCanonicalContainer remainder1
        _ -> Left "the canonical lift layer is malformed"
  where
    requireFields expected observed =
        requireCanonical
            (observed == expected)
            "the canonical lift layer field count is malformed"

consumeCanonicalContainer :: ByteString -> Either Text ByteString
consumeCanonicalContainer input = do
    remainder0 <- consumeCanonicalTaggedText "image" input
    remainder1 <- consumeCanonicalList "mounts" consumeCanonicalMount remainder0
    remainder2 <- consumeCanonicalTextList "extra-args" remainder1
    remainder3 <- consumeCanonicalTaggedBool "remove-after" remainder2
    remainder4 <- consumeCanonicalTag "config-delivery" remainder3
    consumeCanonicalMaybe "config delivery" consumeCanonicalConfigDelivery remainder4

consumeCanonicalMount :: ByteString -> Either Text ByteString
consumeCanonicalMount input = do
    remainder0 <- consumeCanonicalRecordHeader "mount" 3 input
    remainder1 <- consumeCanonicalTaggedText "source" remainder0
    remainder2 <- consumeCanonicalTaggedText "target" remainder1
    consumeCanonicalTaggedBool "read-only" remainder2

consumeCanonicalConfigDelivery :: ByteString -> Either Text ByteString
consumeCanonicalConfigDelivery input = do
    remainder0 <- consumeCanonicalRecordHeader "config-delivery" 3 input
    remainder1 <- consumeCanonicalTaggedText "write-path" remainder0
    remainder2 <- consumeCanonicalTaggedText "exec-path" remainder1
    consumeCanonicalTaggedText "payload-digest" remainder2

consumeCanonicalRecordHeader :: Text -> Word64 -> ByteString -> Either Text ByteString
consumeCanonicalRecordHeader tag expectedFields input = do
    remainder <- consumeCanonicalTag tag input
    (observedFields, trailing) <- takeCanonicalWord (tag <> " field count") remainder
    requireCanonical
        (observedFields == expectedFields)
        ("the canonical " <> tag <> " field count is malformed")
    Right trailing

consumeCanonicalList ::
    Text ->
    (ByteString -> Either Text ByteString) ->
    ByteString ->
    Either Text ByteString
consumeCanonicalList tag consumeItem input = do
    remainder <- consumeCanonicalTag tag input
    (count, items) <- takeCanonicalWord (tag <> " count") remainder
    consumeCanonicalItems tag count consumeItem items

consumeCanonicalTextList :: Text -> ByteString -> Either Text ByteString
consumeCanonicalTextList tag = consumeCanonicalList tag (consumeCanonicalText (tag <> " item"))

consumeCanonicalItems ::
    Text ->
    Word64 ->
    (ByteString -> Either Text ByteString) ->
    ByteString ->
    Either Text ByteString
consumeCanonicalItems subject = go
  where
    go 0 _ input = Right input
    go remaining consumeItem input
        | ByteString.null input = Left ("the canonical " <> subject <> " is truncated")
        | otherwise =
            case consumeItem input of
                Left failure -> Left failure
                Right trailing
                    | ByteString.length trailing >= ByteString.length input ->
                        Left ("the canonical " <> subject <> " item is malformed")
                    | otherwise -> go (remaining - 1) consumeItem trailing

consumeCanonicalTag :: Text -> ByteString -> Either Text ByteString
consumeCanonicalTag expected input = do
    (observed, remainder) <- takeCanonicalText (expected <> " tag") input
    requireCanonical
        (observed == expected)
        ("the canonical " <> expected <> " tag is malformed")
    Right remainder

consumeCanonicalTaggedText :: Text -> ByteString -> Either Text ByteString
consumeCanonicalTaggedText tag input =
    consumeCanonicalTag tag input >>= consumeCanonicalText (tag <> " value")

consumeCanonicalTaggedWord :: Text -> ByteString -> Either Text (Word64, ByteString)
consumeCanonicalTaggedWord tag input = do
    remainder <- consumeCanonicalTag tag input
    takeCanonicalWord (tag <> " value") remainder

consumeCanonicalPositiveTaggedWord :: Text -> ByteString -> Either Text ByteString
consumeCanonicalPositiveTaggedWord tag input = do
    (value, remainder) <- consumeCanonicalTaggedWord tag input
    requireCanonical (value > 0) ("the canonical " <> tag <> " value is malformed")
    Right remainder

consumeCanonicalTaggedBool :: Text -> ByteString -> Either Text ByteString
consumeCanonicalTaggedBool tag input = do
    remainder <- consumeCanonicalTag tag input
    case ByteString.uncons remainder of
        Just (0, trailing) -> Right trailing
        Just (1, trailing) -> Right trailing
        _ -> Left ("the canonical " <> tag <> " boolean is malformed")

consumeCanonicalMaybe ::
    Text ->
    (ByteString -> Either Text ByteString) ->
    ByteString ->
    Either Text ByteString
consumeCanonicalMaybe subject consumePresent input =
    case ByteString.uncons input of
        Just (0, remainder) -> Right remainder
        Just (1, remainder) -> consumePresent remainder
        _ -> Left ("the canonical " <> subject <> " presence tag is malformed")

consumeCanonicalAbsent :: Text -> ByteString -> Either Text ByteString
consumeCanonicalAbsent subject input =
    case ByteString.uncons input of
        Just (0, remainder) -> Right remainder
        _ -> Left ("the canonical " <> subject <> " presence tag is malformed")

consumeCanonicalPresent ::
    Text ->
    (ByteString -> Either Text ByteString) ->
    ByteString ->
    Either Text ByteString
consumeCanonicalPresent subject consumePresent input =
    case ByteString.uncons input of
        Just (1, remainder) -> consumePresent remainder
        _ -> Left ("the canonical " <> subject <> " presence tag is malformed")

consumeCanonicalText :: Text -> ByteString -> Either Text ByteString
consumeCanonicalText subject input = snd <$> takeCanonicalText subject input

consumeCanonicalEmptyText :: Text -> ByteString -> Either Text ByteString
consumeCanonicalEmptyText subject input = do
    (value, remainder) <- takeCanonicalText subject input
    requireCanonical (Text.null value) ("the canonical " <> subject <> " value is malformed")
    Right remainder

takeCanonicalText :: Text -> ByteString -> Either Text (Text, ByteString)
takeCanonicalText subject input = do
    (bytes, remainder) <-
        maybe
            (Left ("the canonical " <> subject <> " is malformed"))
            Right
            (takeLengthFrame input)
    case TextEncoding.decodeUtf8' bytes of
        Left _ -> Left ("the canonical " <> subject <> " is not valid UTF-8")
        Right value -> Right (value, remainder)

takeCanonicalWord :: Text -> ByteString -> Either Text (Word64, ByteString)
takeCanonicalWord subject input =
    maybe
        (Left ("the canonical " <> subject <> " is malformed"))
        Right
        (takeWord64BE input)

requireCanonical :: Bool -> Text -> Either Text ()
requireCanonical condition failure
    | condition = Right ()
    | otherwise = Left failure

{- | Generate the local plan identity only after protected admission has
finished, and mint the exact bound snapshot/binding pair under that identity.
-}
withPersistedBoundPlanSnapshotKernel ::
    CanonicalPlanSnapshot ->
    ( forall planId.
      BoundPlanSnapshot scope specDigest planDigest planId ->
      PlanDigestBinding scope specDigest planDigest planId ->
      result
    ) ->
    result
withPersistedBoundPlanSnapshotKernel snapshot use =
    use
        (BoundPlanSnapshot snapshot)
        (PlanDigestBinding (canonicalPlanSnapshotDigest snapshot))

{- | A failure to admit an authored draft stream.

The structural failures are the existing closed 'StepPlanError' vocabulary;
the three draft-binding failures detect a stream assembled from evidence other
than the root and validated configuration supplied to this admission.
'PlanRecoveryEvidenceMismatch' reports which descriptive recovery term
disagreed without exposing canonical bytes.
-}
data PlanError
    = PlanDraftRootMismatch FilePath FilePath
    | PlanDraftSpecificationMismatch Text Text
    | PlanDraftConfigurationMismatch Text Text
    | PlanProjectedRootInvalid FilePath
    | PlanRecoveryEvidenceMismatch Text Text Text
    | PlanHandoffEvidenceMismatch Text Text Text
    | PlanResourceOperationMissing Text
    | PlanResourceKindMismatch Text Text
    | PlanDependencyEdgeMissing Text Text
    | PlanResourceBindingMismatch Text Text Text
    | PlanNodeResourceOutsidePrefix Text
    | PlanProjectedOperationMissing Text
    | InvalidProjectPlan StepPlanError
    deriving (Eq, Show)

{- | Narrow foundation seam for the finalized project-specification stream.

The caller supplies an already validated, non-empty 'StepPlan'; this function
only binds each node to the exact opaque root and validated configuration under
which the static project specification produced it.  The finalized
project-specification layer is responsible for invoking the project builder
with those same two values.
-}
planDraftsFromValidatedStepPlanKernel ::
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId config ->
    StepPlan ->
    NonEmpty (PlanDraft scope specDigest config)
planDraftsFromValidatedStepPlanKernel root config plan =
    planDraftsAtRoot (canonicalProjectRootPath root) config plan

planDraftsAtRoot ::
    FilePath -> ValidatedConfig scope specDigest configId config -> StepPlan -> NonEmpty (PlanDraft scope specDigest config)
planDraftsAtRoot root config plan =
    case stepPlanSteps plan of
        firstStep : remainingSteps ->
            makeDraft firstStep :| map makeDraft remainingSteps
        [] ->
            error "validated StepPlan invariant violated: empty plan"
  where
    makeDraft step =
        PlanDraft
            { internalDraftRoot = root
            , internalDraftSpecDigest = validatedConfigSpecDigest config
            , internalDraftConfigDigest = validatedConfigDigest config
            , internalDraftStep = step
            }

{- | Admit one exact draft stream and generate its local @planId@ only inside
the continuation.

The lifecycle-profile projections are supplied by the trusted construction
leaf, while specification and configuration identities are read directly from
the opaque 'ValidatedConfig'.  No independently supplied digest participates
in admission.
-}
withProjectPlanKernel ::
    Text ->
    Word64 ->
    Text ->
    Text ->
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    NonEmpty (PlanDraft scope specDigest (cfg scope)) ->
    (forall planId. ProjectPlan scope specDigest planId configId cfg -> a) ->
    Either PlanError a
withProjectPlanKernel profileName profileEpoch projectName storeIdentity root config drafts use = do
    admitted <-
        admitProjectPlanKernel
            profileName
            profileEpoch
            projectName
            storeIdentity
            root
            config
            drafts
    Right (use admitted)

-- | Build a migration-local plan from the root retained by its opaque drafts.
-- The returned digest binding is local to the same generative plan identity;
-- neither value is durable authority until Mode has persisted and read back
-- the canonical snapshot.
withProspectiveProjectPlanKernel ::
    Text ->
    Word64 ->
    Text ->
    Text ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    NonEmpty (PlanDraft scope specDigest (cfg scope)) ->
    ( forall planDigest planId.
      ProjectPlan scope specDigest planId configId cfg ->
      PlanDigestBinding scope specDigest planDigest planId ->
      CanonicalPlanSnapshot ->
      result
    ) ->
    Either PlanError result
withProspectiveProjectPlanKernel profileName profileEpoch projectName storeIdentity config drafts use = do
    admitted <-
        admitProjectPlanAtRootKernel
            profileName
            profileEpoch
            projectName
            storeIdentity
            (internalDraftRoot (NonEmpty.head drafts))
            config
            drafts
    let snapshot = projectPlanCanonicalSnapshotKernel admitted
    pure (use admitted (mintPlanDigestBindingKernel (projectPlanIndexedSnapshotKernel admitted) (canonicalPlanSnapshotDigest snapshot)) snapshot)

-- | Reconstruct a completed migration under its persisted plan-digest index.
-- Every canonical field is compared before the fixed digest binding is minted.
withCompletedMigrationProjectPlanKernel ::
    Text -> Word64 -> Text -> Text -> Text -> Text -> ByteString ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    NonEmpty (PlanDraft scope specDigest (cfg scope)) ->
    (ProjectPlan scope specDigest planId configId cfg -> PlanDigestBinding scope specDigest planDigest planId -> result) ->
    Either PlanError result
withCompletedMigrationProjectPlanKernel profileName profileEpoch projectName storeIdentity expectedPlan expectedConfig expectedBytes config drafts use = do
    admitted <- admitProjectPlanAtRootKernel profileName profileEpoch projectName storeIdentity (internalDraftRoot (NonEmpty.head drafts)) config drafts
    let snapshot = projectPlanCanonicalSnapshotKernel admitted
    requireEvidence "plan digest" expectedPlan (canonicalPlanSnapshotDigest snapshot)
    requireEvidence "configuration digest" expectedConfig (canonicalPlanSnapshotConfigDigest snapshot)
    if canonicalPlanSnapshotBytes snapshot /= expectedBytes
        then Left (PlanHandoffEvidenceMismatch "canonical snapshot bytes" "persisted bytes" "different bytes")
        else pure (use admitted (mintPlanDigestBindingKernel (projectPlanIndexedSnapshotKernel admitted) expectedPlan))
  where
    requireEvidence label expected observed
        | expected == observed = Right ()
        | otherwise = Left (PlanHandoffEvidenceMismatch label expected observed)

-- | Admit an independently projected plan at a canonical POSIX descriptor.
withProjectedProjectPlanKernel ::
    ProjectPlan scope specDigest parentPlanId parentConfigId cfg ->
    FilePath ->
    ValidatedConfig scope specDigest childConfigId (cfg scope) ->
    StepPlan ->
    ( forall childPlanDigest childPlanId.
      ProjectPlan scope specDigest childPlanId childConfigId cfg ->
      PlanDigestBinding scope specDigest childPlanDigest childPlanId ->
      result
    ) ->
    Either PlanError result
withProjectedProjectPlanKernel parent descriptor config plan use
    | not (canonicalProjectedRootKernel descriptor) =
        Left (PlanProjectedRootInvalid descriptor)
    | otherwise = do
        admitted <-
            admitProjectPlanAtRootKernel
                (projectPlanProfileNameKernel parent)
                (projectPlanProfileEpochKernel parent)
                (projectPlanProfileProjectNameKernel parent)
                (projectPlanProfileStoreIdentityKernel parent)
                descriptor
                config
                (planDraftsAtRoot descriptor config plan)
        let snapshot = projectPlanIndexedSnapshotKernel admitted
            digest = projectPlanDigestKernel admitted
        Right (use admitted (mintPlanDigestBindingKernel snapshot digest))
canonicalProjectedRootKernel :: FilePath -> Bool
canonicalProjectedRootKernel descriptor =
    Posix.isAbsolute descriptor
        && Posix.isValid descriptor
        && '\\' `notElem` descriptor
        && all (`notElem` [".", ".."]) (Posix.splitDirectories descriptor)
        && Posix.normalise descriptor == descriptor
        && (descriptor == "/" || not (Posix.hasTrailingPathSeparator descriptor))

{- | Admit a child-local plan directly from the constructor-hidden draft root.

The authenticated handoff supplies the root-owned lifecycle/profile fields and
stable plan digest.  The first opaque draft supplies the canonical root; the
ordinary draft validator proves every remaining draft has that same root,
specification, and configuration.  The stable digest is compared before the
matching local 'PlanDigestBinding' is minted, and both local identities remain
inside the continuation.
-}
withChildProjectPlanKernel ::
    Text ->
    Word64 ->
    Text ->
    Text ->
    Text ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    NonEmpty (PlanDraft scope specDigest (cfg scope)) ->
    ( forall planId.
      ProjectPlan scope specDigest planId configId cfg ->
      PlanDigestBinding scope specDigest planDigest planId ->
      a
    ) ->
    Either PlanError a
withChildProjectPlanKernel profileName profileEpoch projectName storeIdentity signedPlanDigest config drafts use = do
    admitted <-
        admitProjectPlanAtRootKernel
            profileName
            profileEpoch
            projectName
            storeIdentity
            (internalDraftRoot (NonEmpty.head drafts))
            config
            drafts
    let observedPlanDigest = projectPlanDigestKernel admitted
    if observedPlanDigest /= signedPlanDigest
        then
            Left
                ( PlanHandoffEvidenceMismatch
                    "stable plan digest"
                    signedPlanDigest
                    observedPlanDigest
                )
        else
            Right
                ( use
                    admitted
                    ( mintPlanDigestBindingKernel
                        (projectPlanIndexedSnapshotKernel admitted)
                        signedPlanDigest
                    )
                )

{- | Admit a recovered plan under the fixed @planId@ generated by existing
snapshot admission.

The shared candidate builder performs exactly the fresh path's root, draft,
configuration, and structural validation. This seam has no rank-2 local
identity quantifier; the public recovery leaf validates the candidate against
the protected evidence package before exposing it.
-}
withRecoveredProjectPlanKernel ::
    Text ->
    Word64 ->
    Text ->
    Text ->
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    NonEmpty (PlanDraft scope specDigest (cfg scope)) ->
    (ProjectPlan scope specDigest planId configId cfg -> a) ->
    Either PlanError a
withRecoveredProjectPlanKernel profileName profileEpoch projectName storeIdentity root config drafts use = do
    admitted <-
        admitProjectPlanKernel
            profileName
            profileEpoch
            projectName
            storeIdentity
            root
            config
            drafts
    Right (use admitted)

admitProjectPlanKernel ::
    Text ->
    Word64 ->
    Text ->
    Text ->
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    NonEmpty (PlanDraft scope specDigest (cfg scope)) ->
    Either PlanError (ProjectPlan scope specDigest planId configId cfg)
admitProjectPlanKernel profileName profileEpoch projectName storeIdentity root config drafts = do
    admitProjectPlanAtRootKernel
        profileName
        profileEpoch
        projectName
        storeIdentity
        (canonicalProjectRootPath root)
        config
        drafts

admitProjectPlanAtRootKernel ::
    Text ->
    Word64 ->
    Text ->
    Text ->
    FilePath ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    NonEmpty (PlanDraft scope specDigest (cfg scope)) ->
    Either PlanError (ProjectPlan scope specDigest planId configId cfg)
admitProjectPlanAtRootKernel profileName profileEpoch projectName storeIdentity expectedRoot config drafts = do
    validateDraftBindings
    plan <-
        case mkStepPlan (map internalDraftStep (NonEmpty.toList drafts)) of
            Left failure -> Left (InvalidProjectPlan failure)
            Right admitted -> Right admitted
    validateChartWorkloadDeclarations plan
    let admittedTopology = topologyFromAdmittedPlan plan
        snapshot =
            canonicalPlanSnapshot
                expectedRoot
                (validatedConfigSpecDigest config)
                (validatedConfigDigest config)
                plan
    Right
        ( ProjectPlan
            profileName
            profileEpoch
            projectName
            storeIdentity
            expectedRoot
            config
            plan
            admittedTopology
            (IndexedPlanSnapshot snapshot)
        )
  where
    expectedSpecDigest = validatedConfigSpecDigest config
    expectedConfigDigest = validatedConfigDigest config
    validateDraftBindings =
        case find ((/= expectedRoot) . internalDraftRoot) (NonEmpty.toList drafts) of
            Just draft ->
                Left
                    ( PlanDraftRootMismatch
                        expectedRoot
                        (internalDraftRoot draft)
                    )
            Nothing ->
                case find ((/= expectedSpecDigest) . internalDraftSpecDigest) (NonEmpty.toList drafts) of
                    Just draft ->
                        Left
                            ( PlanDraftSpecificationMismatch
                                expectedSpecDigest
                                (internalDraftSpecDigest draft)
                            )
                    Nothing ->
                        case find ((/= expectedConfigDigest) . internalDraftConfigDigest) (NonEmpty.toList drafts) of
                            Just draft ->
                                Left
                                    ( PlanDraftConfigurationMismatch
                                        expectedConfigDigest
                                        (internalDraftConfigDigest draft)
                                )
                            Nothing -> Right ()

validateChartWorkloadDeclarations :: StepPlan -> Either PlanError ()
validateChartWorkloadDeclarations plan = mapM_ validate (stepPlanSteps plan)
  where
    validate step = case stepChartWorkloadResourceDeclarations step of
        [] -> Right ()
        [declaration]
            | stepIdentity step /= CoreStepIdentity DeployChartId ->
                binding "chart operation" "core:deploy-chart" (Text.pack (operationKeyText (stepOperationKey step)))
            | otherwise -> do
                validateFields declaration
                let clusters =
                        [ dependency
                        | dependencyIdentity <- stepDependencies plan step
                        , Just dependency <- [find ((== dependencyIdentity) . stepIdentity) (stepPlanSteps plan)]
                        , stepIdentity dependency == CoreStepIdentity DeployKindId
                        , frameId (stepFrame dependency) == frameId (stepFrame step)
                        ]
                case clusters of
                    [_] -> Right ()
                    [] -> binding "chart cluster parent" "one same-frame cluster dependency" "none"
                    _ -> binding "chart cluster parent" "one same-frame cluster dependency" "duplicate"
        declarations -> binding "chart workload declaration count" "one" (Text.pack (show (length declarations)))
    validateFields (artifact, release, namespace, valuesDigest, imageIdentity, workloadKey, workloadDigest, serviceRole, effects) = do
        mapM_ (\(label, value) -> if Text.null value then binding label "non-empty" "empty" else Right ())
            [ ("chart artifact digest", artifact), ("chart release", release), ("chart namespace", namespace)
            , ("chart values digest", valuesDigest), ("chart image identity", imageIdentity)
            , ("chart workload declaration key", workloadKey), ("chart workload declaration digest", workloadDigest)
            , ("chart service role", serviceRole)
            ]
        if null effects || length effects /= length (List.nub effects) || any Text.null effects
            then binding "chart effects" "a non-empty unique set" "empty or duplicate"
            else Right ()
    binding field expected observed = Left (PlanResourceBindingMismatch field expected observed)

withProjectChartWorkloadResourceKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    OperationKey ->
    (forall resourceId frame. ChartWorkloadResource scope planId resourceId frame -> result) ->
    Either PlanError result
withProjectChartWorkloadResourceKernel plan operation consume = do
    step <- maybe (Left (PlanResourceOperationMissing key)) Right (findStep graph key)
    if stepIdentity step /= CoreStepIdentity DeployChartId
        then Left (PlanResourceKindMismatch key "chart workload")
        else case stepChartWorkloadResourceDeclarations step of
            [(artifact, release, namespace, valuesDigest, imageIdentity, workloadKey, workloadDigest, serviceRole, effects)] ->
                case
                    [ Text.pack (operationKeyText (stepOperationKey dependency))
                    | dependencyIdentity <- stepDependencies graph step
                    , Just dependency <- [find ((== dependencyIdentity) . stepIdentity) (stepPlanSteps graph)]
                    , stepIdentity dependency == CoreStepIdentity DeployKindId
                    , frameId (stepFrame dependency) == frameId (stepFrame step)
                    ] of
                    [clusterKey] ->
                        pure
                            ( consume
                                ( ChartWorkloadResource artifact release namespace valuesDigest imageIdentity workloadKey workloadDigest serviceRole effects key
                                    (Text.pack (frameId (stepFrame step)))
                                    (canonicalPlanSnapshotDigest snapshot)
                                    clusterKey
                                )
                            )
                    _ -> Left (PlanResourceBindingMismatch "chart cluster parent" "one same-frame cluster dependency" "not one")
            _ -> Left (PlanResourceBindingMismatch "chart workload declaration count" "one" "not one")
  where
    graph = projectPlanStepPlanKernel plan
    snapshot = case plan of ProjectPlan _ _ _ _ _ _ _ _ (IndexedPlanSnapshot retained) -> retained
    key = Text.pack (operationKeyText operation)

{- | Project the exact admitted graph in its validated dependency order.

The first node has an empty prefix.  Every later node retains the operation key
and frame of each earlier node, which is exactly the dependency relation
validated by 'mkStepPlan'.
-}
forwardKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    NonEmpty (PlannedStep scope planId configId (cfg scope))
forwardKernel
    (ProjectPlan _ _ _ _ _ _ plan _ (IndexedPlanSnapshot snapshot)) =
        case stepPlanSteps plan of
            firstStep : remainingSteps ->
                PlannedStep digest firstStep [] :| go [firstStep] remainingSteps
            [] -> error "validated StepPlan invariant violated: empty plan"
  where
    digest = canonicalPlanSnapshotDigest snapshot
    go _ [] = []
    go preceding (step : rest) =
        PlannedStep digest step (map dependencyView preceding)
            : go (preceding ++ [step]) rest
    dependencyView dependency =
        ( stepOperationKey dependency
        , Text.pack (frameId (stepFrame dependency))
        )

plannedStepLabelKernel :: PlannedStep scope planId configId config -> Text
plannedStepLabelKernel (PlannedStep _ step _) = Text.pack (stepLabel step)

plannedStepFrameIdKernel :: PlannedStep scope planId configId config -> Text
plannedStepFrameIdKernel (PlannedStep _ step _) = Text.pack (frameId (stepFrame step))

plannedStepFrameLabelKernel :: PlannedStep scope planId configId config -> Text
plannedStepFrameLabelKernel (PlannedStep _ step _) = Text.pack (frameLabel (stepFrame step))

plannedStepOperationKeyKernel :: PlannedStep scope planId configId config -> OperationKey
plannedStepOperationKeyKernel (PlannedStep _ step _) = stepOperationKey step

plannedStepDependencyOperationsKernel ::
    PlannedStep scope planId configId config ->
    [(OperationKey, Text)]
plannedStepDependencyOperationsKernel (PlannedStep _ _ dependencies) = dependencies

plannedStepProjectedOperationKeysKernel ::
    PlannedStep scope planId configId config ->
    [OperationKey]
plannedStepProjectedOperationKeysKernel (PlannedStep _ step _) =
    stepProjectedOperations step

plannedResourceKeyKernel ::
    PlannedResource scope planId resourceId resource frame ->
    Text
plannedResourceKeyKernel (PlannedResource _ key _) = key

plannedResourceFrameKernel ::
    PlannedResource scope planId resourceId resource frame ->
    Text
plannedResourceFrameKernel (PlannedResource _ _ frame) = frame

plannedResourcePlanDigestKernel ::
    PlannedResource scope planId resourceId resource frame ->
    Text
plannedResourcePlanDigestKernel (PlannedResource digest _ _) = digest

plannedEdgeTargetKeyKernel ::
    PlannedEdge scope planId targetId target targetFrame dependencyId dependency dependencyFrame ->
    Text
plannedEdgeTargetKeyKernel (PlannedEdge targetKey _) = targetKey

plannedEdgeDependencyKeyKernel ::
    PlannedEdge scope planId targetId target targetFrame dependencyId dependency dependencyFrame ->
    Text
plannedEdgeDependencyKeyKernel (PlannedEdge _ dependency) = dependency

plannedKindKey :: PlannedResourceKind resource -> Text
plannedKindKey resourceKind =
    case resourceKind of
        ProviderResourceKind -> "core:deploy-vm"
        DurableShareResourceKind -> "core:copy-source"
        DockerResourceKind -> "core:ensure-docker"
        MinioResourceKind -> "project:deploy-minio"
        RegistryResourceKind -> "project:deploy-registry"
        ClusterResourceKind -> "core:deploy-kind"

plannedKindName :: PlannedResourceKind resource -> Text
plannedKindName resourceKind =
    case resourceKind of
        ProviderResourceKind -> "provider"
        DurableShareResourceKind -> "durable share"
        DockerResourceKind -> "Docker daemon"
        MinioResourceKind -> "MinIO"
        RegistryResourceKind -> "registry"
        ClusterResourceKind -> "cluster"

data SomePlannedResourceKind where
    SomePlannedResourceKind :: PlannedResourceKind resource -> SomePlannedResourceKind

plannedResourceFamilyKeysKernel :: [Text]
plannedResourceFamilyKeysKernel =
    [ plannedKindKey resourceKind
    | SomePlannedResourceKind resourceKind <-
        [ SomePlannedResourceKind ProviderResourceKind
        , SomePlannedResourceKind DurableShareResourceKind
        , SomePlannedResourceKind DockerResourceKind
        , SomePlannedResourceKind MinioResourceKind
        , SomePlannedResourceKind RegistryResourceKind
        , SomePlannedResourceKind ClusterResourceKind
        ]
    ]

withProjectPlannedResourceOfKindKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    PlannedResourceKind resource ->
    OperationKey ->
    ( forall resourceId frame.
      PlannedResource scope planId resourceId resource frame ->
      result
    ) ->
    Either PlanError result
withProjectPlannedResourceOfKindKernel plan resourceKind operationKey consume =
    withGraphResourceOfKind
        (projectPlanDigestKernel plan)
        (projectPlanStepPlanKernel plan)
        resourceKind
        (Text.pack (operationKeyText operationKey))
        consume

withProjectPlannedEdgeKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    PlannedResource scope planId targetId target targetFrame ->
    PlannedResource scope planId dependencyId dependency dependencyFrame ->
    ( PlannedEdge
        scope
        planId
        targetId
        target
        targetFrame
        dependencyId
        dependency
        dependencyFrame ->
      result
    ) ->
    Either PlanError result
withProjectPlannedEdgeKernel plan targetResource dependency consume = do
    targetStep <- validateGraphResource digest graph targetResource
    dependencyStep <- validateGraphResource digest graph dependency
    if stepIdentity dependencyStep `elem` stepDependencies graph targetStep
        then
            Right
                ( consume
                    ( PlannedEdge
                        (plannedResourceKeyKernel targetResource)
                        (plannedResourceKeyKernel dependency)
                    )
                )
        else
            Left
                ( PlanDependencyEdgeMissing
                    (plannedResourceKeyKernel targetResource)
                    (plannedResourceKeyKernel dependency)
                )
  where
    digest = projectPlanDigestKernel plan
    graph = projectPlanStepPlanKernel plan

withProjectProviderGuestAliasProjectionKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    PlannedResource scope planId shareId DurableShareResource shareFrame ->
    ( forall aliasId.
      PlannedResource scope planId aliasId DurableAliasResource shareFrame ->
      PlannedEdge
        scope
        planId
        aliasId
        DurableAliasResource
        shareFrame
        shareId
        DurableShareResource
        shareFrame ->
      result
    ) ->
    Either PlanError result
withProjectProviderGuestAliasProjectionKernel plan provider share consume = do
    providerStep <- validateGraphResource digest graph provider
    shareStep <- validateGraphResource digest graph share
    requireKind ProviderResourceKind provider
    requireKind DurableShareResourceKind share
    requireDependency providerStep shareStep
    requireProjectedAlias shareStep aliasKey
    Right
        ( consume
            (PlannedResource digest aliasKey (plannedResourceFrameKernel share))
            (PlannedEdge aliasKey (plannedResourceKeyKernel share))
        )
  where
    digest = projectPlanDigestKernel plan
    graph = projectPlanStepPlanKernel plan
    aliasKey = guestAliasKey provider share
    requireDependency providerStep shareStep
        | stepIdentity providerStep `elem` stepDependencies graph shareStep = Right ()
        | otherwise =
            Left
                ( PlanDependencyEdgeMissing
                    (plannedResourceKeyKernel share)
                    (plannedResourceKeyKernel provider)
                )

withPlannedStepResourceOfKindKernel ::
    PlannedStep scope planId configId config ->
    PlannedResourceKind resource ->
    OperationKey ->
    ( forall resourceId frame.
      PlannedResource scope planId resourceId resource frame ->
      result
    ) ->
    Either PlanError result
withPlannedStepResourceOfKindKernel plannedStep resourceKind operationKey =
    withNodeResourceOfKind
        (plannedStepDigest plannedStep)
        (plannedStepResourcePrefix plannedStep)
        resourceKind
        (Text.pack (operationKeyText operationKey))

withPlannedStepGuestAliasProjectionKernel ::
    PlannedStep scope planId configId config ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    PlannedResource scope planId shareId DurableShareResource shareFrame ->
    ( forall aliasId.
      PlannedResource scope planId aliasId DurableAliasResource shareFrame ->
      PlannedEdge
        scope
        planId
        aliasId
        DurableAliasResource
        shareFrame
        shareId
        DurableShareResource
        shareFrame ->
      result
    ) ->
    Either PlanError result
withPlannedStepGuestAliasProjectionKernel plannedStep =
    withNodeGuestAliasProjection
        (plannedStepDigest plannedStep)
        (plannedStepResourcePrefix plannedStep)
        (map (Text.pack . operationKeyText) (plannedStepProjectedOperationKeysKernel plannedStep))

withCompatibilityNodeResourceOfKindKernel ::
    Text ->
    [(Text, Text)] ->
    PlannedResourceKind resource ->
    Text ->
    ( forall resourceId frame.
      PlannedResource scope planId resourceId resource frame ->
      result
    ) ->
    Either PlanError result
withCompatibilityNodeResourceOfKindKernel = withNodeResourceOfKind

withCompatibilityNodeGuestAliasProjectionKernel ::
    Text ->
    [(Text, Text)] ->
    [Text] ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    PlannedResource scope planId shareId DurableShareResource shareFrame ->
    ( forall aliasId.
      PlannedResource scope planId aliasId DurableAliasResource shareFrame ->
      PlannedEdge
        scope
        planId
        aliasId
        DurableAliasResource
        shareFrame
        shareId
        DurableShareResource
        shareFrame ->
      result
    ) ->
    Either PlanError result
withCompatibilityNodeGuestAliasProjectionKernel = withNodeGuestAliasProjection

withGraphResourceOfKind ::
    Text ->
    StepPlan ->
    PlannedResourceKind resource ->
    Text ->
    ( forall resourceId frame.
      PlannedResource scope planId resourceId resource frame ->
      result
    ) ->
    Either PlanError result
withGraphResourceOfKind digest graph resourceKind requestedKey consume
    | otherwise = case findStep graph requestedKey of
        Nothing -> Left (PlanResourceOperationMissing requestedKey)
        Just step -> do
            frame <- resourceFrame graph resourceKind step
            Right (consume (PlannedResource digest requestedKey frame))

withNodeResourceOfKind ::
    Text ->
    [(Text, Text)] ->
    PlannedResourceKind resource ->
    Text ->
    ( forall resourceId frame.
      PlannedResource scope planId resourceId resource frame ->
      result
    ) ->
    Either PlanError result
withNodeResourceOfKind digest resources resourceKind requestedKey consume
    | requestedKey /= plannedKindKey resourceKind =
        Left (PlanResourceKindMismatch requestedKey (plannedKindName resourceKind))
    | otherwise =
        case find ((== requestedKey) . fst) resources of
            Nothing -> Left (PlanNodeResourceOutsidePrefix requestedKey)
            Just (_, frame) -> Right (consume (PlannedResource digest requestedKey frame))

withNodeGuestAliasProjection ::
    Text ->
    [(Text, Text)] ->
    [Text] ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    PlannedResource scope planId shareId DurableShareResource shareFrame ->
    ( forall aliasId.
      PlannedResource scope planId aliasId DurableAliasResource shareFrame ->
      PlannedEdge
        scope
        planId
        aliasId
        DurableAliasResource
        shareFrame
        shareId
        DurableShareResource
        shareFrame ->
      result
    ) ->
    Either PlanError result
withNodeGuestAliasProjection digest resources projected provider share consume = do
    validateNodeResource digest resources provider
    validateNodeResource digest resources share
    requireKind ProviderResourceKind provider
    requireKind DurableShareResourceKind share
    if precedes (plannedResourceKeyKernel provider) (plannedResourceKeyKernel share) resources
        then Right ()
        else
            Left
                ( PlanDependencyEdgeMissing
                    (plannedResourceKeyKernel share)
                    (plannedResourceKeyKernel provider)
                )
    requireProjectedKey projected aliasKey
    Right
        ( consume
            (PlannedResource digest aliasKey (plannedResourceFrameKernel share))
            (PlannedEdge aliasKey (plannedResourceKeyKernel share))
        )
  where
    aliasKey = guestAliasKey provider share

validateGraphResource ::
    Text ->
    StepPlan ->
    PlannedResource scope planId resourceId resource frame ->
    Either PlanError Step
validateGraphResource digest graph resource = do
    requireBinding "plan digest" digest (plannedResourcePlanDigestKernel resource)
    step <-
        maybe
            (Left (PlanResourceOperationMissing (plannedResourceKeyKernel resource)))
            Right
            (findStep graph (plannedResourceKeyKernel resource))
    requireBinding
        "resource frame"
        (Text.pack (frameId (stepFrame step)))
        (plannedResourceFrameKernel resource)
    Right step

validateNodeResource ::
    Text ->
    [(Text, Text)] ->
    PlannedResource scope planId resourceId resource frame ->
    Either PlanError ()
validateNodeResource digest resources resource = do
    requireBinding "plan digest" digest (plannedResourcePlanDigestKernel resource)
    case find ((== plannedResourceKeyKernel resource) . fst) resources of
        Nothing -> Left (PlanNodeResourceOutsidePrefix (plannedResourceKeyKernel resource))
        Just (_, frame) -> requireBinding "resource frame" frame (plannedResourceFrameKernel resource)

requireKind ::
    PlannedResourceKind resource ->
    PlannedResource scope planId resourceId resource frame ->
    Either PlanError ()
requireKind resourceKind resource
    | providerKind resourceKind = Right ()
    | plannedResourceKeyKernel resource == plannedKindKey resourceKind = Right ()
    | otherwise =
        Left
            ( PlanResourceKindMismatch
                (plannedResourceKeyKernel resource)
                (plannedKindName resourceKind)
            )

providerKind :: PlannedResourceKind resource -> Bool
providerKind ProviderResourceKind = True
providerKind _ = False

resourceFrame :: StepPlan -> PlannedResourceKind resource -> Step -> Either PlanError Text
resourceFrame graph resourceKind step
    | not (providerKind resourceKind) =
        if Text.pack (operationKeyText (stepOperationKey step)) == plannedKindKey resourceKind
            then Right currentFrame
            else Left (PlanResourceKindMismatch (Text.pack (operationKeyText (stepOperationKey step))) (plannedKindName resourceKind))
    | otherwise =
        case stepProviderResourceDeclarations step of
            [declaration]
                | providerResourceDeclarationTargetsChild declaration ->
                    maybe
                        (Left (PlanResourceBindingMismatch "provider target frame" "one immediate child" "none"))
                        (Right . Text.pack . frameId)
                        (immediateChild graph step)
                | otherwise -> Right currentFrame
            []
                | Text.pack (operationKeyText (stepOperationKey step)) == plannedKindKey ProviderResourceKind ->
                    Right currentFrame
            _ -> Left (PlanResourceKindMismatch (Text.pack (operationKeyText (stepOperationKey step))) (plannedKindName resourceKind))
  where
    currentFrame = Text.pack (frameId (stepFrame step))

immediateChild :: StepPlan -> Step -> Maybe StepFrame
immediateChild graph author =
    case dropWhile ((/= frameId (stepFrame author)) . frameId) (chainFrames graph) of
        _current : child : _ -> Just child
        _ -> Nothing

requireProjectedAlias :: Step -> Text -> Either PlanError ()
requireProjectedAlias step =
    requireProjectedKey (map (Text.pack . operationKeyText) (stepProjectedOperations step))

requireProjectedKey :: [Text] -> Text -> Either PlanError ()
requireProjectedKey projected key
    | key `elem` projected = Right ()
    | otherwise = Left (PlanProjectedOperationMissing key)

requireBinding :: Text -> Text -> Text -> Either PlanError ()
requireBinding field expected observed
    | expected == observed = Right ()
    | otherwise = Left (PlanResourceBindingMismatch field expected observed)

findStep :: StepPlan -> Text -> Maybe Step
findStep graph requestedKey =
    find
        ((== Text.unpack requestedKey) . operationKeyText . stepOperationKey)
        (stepPlanSteps graph)

precedes :: Text -> Text -> [(Text, frame)] -> Bool
precedes earlier later ordered =
    case break ((== earlier) . fst) ordered of
        (_, _ : after) -> later `elem` map fst after
        (_, []) -> False

guestAliasKey ::
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    PlannedResource scope planId shareId DurableShareResource shareFrame ->
    Text
guestAliasKey provider share =
    plannedResourceKeyKernel provider
        <> "/"
        <> plannedResourceKeyKernel share
        <> "/guest-alias"

plannedStepDigest :: PlannedStep scope planId configId config -> Text
plannedStepDigest (PlannedStep digest _ _) = digest

plannedStepResourcePrefix ::
    PlannedStep scope planId configId config ->
    [(Text, Text)]
plannedStepResourcePrefix (PlannedStep _ step dependencies) =
    [ (Text.pack (operationKeyText key), frame)
    | (key, frame) <- dependencies
    ]
        ++ [ ( Text.pack (operationKeyText (stepOperationKey step))
             , Text.pack (frameId (stepFrame step))
             )
           ]

projectPlanDigestKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    Text
projectPlanDigestKernel = canonicalPlanSnapshotDigest . projectPlanCanonicalSnapshotKernel

{- | Execute only the callback retained by this exact projected node.

The descriptor's @scope@ and @planId@ must match the projected node.  This is
the public interpreter route used by later chain adoption; the raw 'Step'
never leaves the hidden kernel.
-}
runPlannedStepKernel ::
    PlannedStep scope planId configId config ->
    StepExecution scope planId ->
    IO StepObservation
runPlannedStepKernel (PlannedStep _ step _) = runStep step

-- | Project the exact frame graph retained by an admitted plan.
topologyKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    DerivedTopology scope planId
topologyKernel (ProjectPlan _ _ _ _ _ _ _ derived _) = derived

topologyFrameOrderKernel ::
    DerivedTopology scope planId ->
    NonEmpty (Text, Text)
topologyFrameOrderKernel (DerivedTopology frames) =
    fmap
        (\frame -> (internalTopologyFrameId frame, internalTopologyFrameLabel frame))
        frames

-- | Ordered @(parent, child)@ edges.
topologyParentEdgesKernel :: DerivedTopology scope planId -> [(Text, Text)]
topologyParentEdgesKernel (DerivedTopology frames) =
    [ (parent, internalTopologyFrameId frame)
    | frame <- NonEmpty.toList frames
    , Just parent <- [internalTopologyParent frame]
    ]

-- | Ordered @(parent, child, lift)@ descent edges.
topologyDescentEdgesKernel ::
    DerivedTopology scope planId ->
    [(Text, Text, LiftContext)]
topologyDescentEdgesKernel (DerivedTopology frames) =
    [ (internalTopologyFrameId frame, child, context)
    | frame <- NonEmpty.toList frames
    , Just (child, context) <- [internalTopologyDescent frame]
    ]

topologyContainsFrameKernel :: DerivedTopology scope planId -> Text -> Bool
topologyContainsFrameKernel (DerivedTopology frames) requested =
    any ((== requested) . internalTopologyFrameId) frames

topologyFrameLabelKernel :: DerivedTopology scope planId -> Text -> Maybe Text
topologyFrameLabelKernel (DerivedTopology frames) requested =
    internalTopologyFrameLabel
        <$> find ((== requested) . internalTopologyFrameId) (NonEmpty.toList frames)

topologyParentFrameKernel :: DerivedTopology scope planId -> Text -> Maybe Text
topologyParentFrameKernel (DerivedTopology frames) requested =
    internalTopologyParent
        =<< find ((== requested) . internalTopologyFrameId) (NonEmpty.toList frames)

topologyDescentFromKernel ::
    DerivedTopology scope planId ->
    Text ->
    Maybe (Text, LiftContext)
topologyDescentFromKernel (DerivedTopology frames) requested =
    internalTopologyDescent
        =<< find ((== requested) . internalTopologyFrameId) (NonEmpty.toList frames)

{- | Build the topology once from the same admitted graph used for every other
projection.  Validation guarantees that the frame list is non-empty, every
non-leaf frame has exactly one descent, and the innermost frame has none.
-}
topologyFromAdmittedPlan :: StepPlan -> DerivedTopology scope planId
topologyFromAdmittedPlan plan =
    case chainFrames plan of
        [] -> error "validated StepPlan invariant violated: empty frame topology"
        firstFrame : remainingFrames ->
            DerivedTopology
                ( makeFrame Nothing firstFrame remainingFrames
                    :| buildFrames firstFrame remainingFrames
                )
  where
    buildFrames _ [] = []
    buildFrames parent (frame : remaining) =
        makeFrame (Just parent) frame remaining
            : buildFrames frame remaining
    makeFrame parent frame remaining =
        TopologyFrame
            { internalTopologyFrameId = Text.pack (frameId frame)
            , internalTopologyFrameLabel = Text.pack (frameLabel frame)
            , internalTopologyParent = Text.pack . frameId <$> parent
            , internalTopologyDescent =
                case remaining of
                    child : _ ->
                        fmap
                            (\context -> (Text.pack (frameId child), context))
                            (frameDescent (frameId frame) plan)
                    [] -> Nothing
            }

-- | Render the sole stable canonical snapshot retained by this project plan.
renderSnapshotKernel ::
    ProjectPlan scope specDigest planId configId cfg ->
    StablePlanSnapshot
renderSnapshotKernel (ProjectPlan _ _ _ _ _ _ _ _ (IndexedPlanSnapshot snapshot)) =
    StablePlanSnapshot snapshot

stablePlanSnapshotFormatVersionKernel :: StablePlanSnapshot -> Word64
stablePlanSnapshotFormatVersionKernel _ = canonicalPlanSnapshotFormatVersion

stablePlanSnapshotRootKernel :: StablePlanSnapshot -> FilePath
stablePlanSnapshotRootKernel (StablePlanSnapshot snapshot) =
    canonicalPlanSnapshotRoot snapshot

stablePlanSnapshotSpecDigestKernel :: StablePlanSnapshot -> Text
stablePlanSnapshotSpecDigestKernel (StablePlanSnapshot snapshot) =
    canonicalPlanSnapshotSpecDigest snapshot

stablePlanSnapshotConfigDigestKernel :: StablePlanSnapshot -> Text
stablePlanSnapshotConfigDigestKernel (StablePlanSnapshot snapshot) =
    canonicalPlanSnapshotConfigDigest snapshot

stablePlanSnapshotBytesKernel :: StablePlanSnapshot -> ByteString
stablePlanSnapshotBytesKernel (StablePlanSnapshot snapshot) =
    canonicalPlanSnapshotBytes snapshot

stablePlanSnapshotDigestKernel :: StablePlanSnapshot -> Text
stablePlanSnapshotDigestKernel (StablePlanSnapshot snapshot) =
    canonicalPlanSnapshotDigest snapshot

-- | The current stable wire version. Changing the schema requires a new value;
-- old bytes must never be reinterpreted under a new schema.
canonicalPlanSnapshotFormatVersion :: Word64
canonicalPlanSnapshotFormatVersion = 5

{- | Reserved non-absolute root for the current compatibility plan algebra.

Real 'CanonicalProjectRoot' values are absolute, so structural admission can
distinguish this value from a canonically rooted project plan.
-}
compatibilityLifecyclePlanRoot :: FilePath
compatibilityLifecyclePlanRoot = "<hostbootstrap:unrooted-lifecycle-plan>"

canonicalPlanMagic :: ByteString
canonicalPlanMagic = "HOSTBOOTSTRAP-PLAN"

{- | An exact canonical plan snapshot. Its constructor is private so the digest
always describes the retained bytes.
-}
data CanonicalPlanSnapshot = CanonicalPlanSnapshot
    { internalSnapshotRoot :: FilePath
    , internalSnapshotSpecDigest :: Text
    , internalSnapshotConfigDigest :: Text
    , internalSnapshotBytes :: ByteString
    , internalSnapshotDigest :: Text
    }
    deriving (Eq)

instance Show CanonicalPlanSnapshot where
    show snapshot =
        "CanonicalPlanSnapshot<v"
            <> show canonicalPlanSnapshotFormatVersion
            <> ", "
            <> Text.unpack (canonicalPlanSnapshotDigest snapshot)
            <> ">"

canonicalPlanSnapshotSpecDigest :: CanonicalPlanSnapshot -> Text
canonicalPlanSnapshotSpecDigest = internalSnapshotSpecDigest

{- | The exact root descriptor encoded into this snapshot.

A project plan retains its admitted absolute canonical root. The current
lower `Reconcile.LifecyclePlan` compatibility algebra instead retains
'compatibilityLifecyclePlanRoot', the reserved non-absolute descriptor for a
plan constructor that receives no 'CanonicalProjectRoot'.
-}
canonicalPlanSnapshotRoot :: CanonicalPlanSnapshot -> FilePath
canonicalPlanSnapshotRoot = internalSnapshotRoot

canonicalPlanSnapshotConfigDigest :: CanonicalPlanSnapshot -> Text
canonicalPlanSnapshotConfigDigest = internalSnapshotConfigDigest

canonicalPlanSnapshotBytes :: CanonicalPlanSnapshot -> ByteString
canonicalPlanSnapshotBytes = internalSnapshotBytes

canonicalPlanSnapshotDigest :: CanonicalPlanSnapshot -> Text
canonicalPlanSnapshotDigest = internalSnapshotDigest

requireTaggedText :: Text -> Text -> ByteString -> Either Text ByteString
requireTaggedText expectedTag expectedValue input = do
    (observedTag, afterTag) <-
        maybe (Left ("the canonical " <> expectedTag <> " tag is malformed")) Right (takeLengthFrame input)
    if observedTag /= TextEncoding.encodeUtf8 expectedTag
        then Left ("the canonical " <> expectedTag <> " tag is malformed")
        else do
            (observedValue, remainder) <-
                maybe
                    (Left ("the canonical " <> expectedTag <> " value is malformed"))
                    Right
                    (takeLengthFrame afterTag)
            if observedValue == TextEncoding.encodeUtf8 expectedValue
                then Right remainder
                else Left ("the canonical " <> expectedTag <> " value does not match")

takeLengthFrame :: ByteString -> Maybe (ByteString, ByteString)
takeLengthFrame input = do
    (lengthWord, payload) <- takeWord64BE input
    if lengthWord > fromIntegral (ByteString.length payload)
        then Nothing
        else Just (ByteString.splitAt (fromIntegral lengthWord) payload)

takeWord64BE :: ByteString -> Maybe (Word64, ByteString)
takeWord64BE input
    | ByteString.length input < 8 = Nothing
    | otherwise =
        let (prefix, remainder) = ByteString.splitAt 8 input
            value =
                ByteString.foldl'
                    (\accumulator byte -> shiftL accumulator 8 .|. fromIntegral byte)
                    0
                    prefix
         in Just (value, remainder)

takeWord32BE :: ByteString -> Maybe (Word32, ByteString)
takeWord32BE input
    | ByteString.length input < 4 = Nothing
    | otherwise =
        let (prefix, remainder) = ByteString.splitAt 4 input
            value =
                ByteString.foldl'
                    (\accumulator byte -> shiftL accumulator 8 .|. fromIntegral byte)
                    0
                    prefix
         in Just (value, remainder)

decodeCanonicalRoot :: ByteString -> Either Text FilePath
decodeCanonicalRoot bytes
    | ByteString.null bytes = Left "the canonical project root is empty"
    | ByteString.length bytes > maxCanonicalRootBytes =
        Left "the canonical project root exceeds the size limit"
    | ByteString.length bytes `mod` 4 /= 0 =
        Left "the canonical project root has a partial code point"
    | otherwise = go [] bytes
  where
    go reversed remaining
        | ByteString.null remaining = Right (reverse reversed)
        | otherwise = do
            (codePoint, trailing) <-
                maybe
                    (Left "the canonical project root has a partial code point")
                    Right
                    (takeWord32BE remaining)
            character <- decodeCodePoint codePoint
            go (character : reversed) trailing
    decodeCodePoint codePoint
        | codePoint == 0 = Left "the canonical project root contains NUL"
        | codePoint > 0x10FFFF =
            Left "the canonical project root code point is out of range"
        | otherwise = Right (chr (fromIntegral codePoint))

maxCanonicalRootBytes :: Int
maxCanonicalRootBytes = 131072

{- | Closed identity for the step's forward implementation. It deliberately
does not pretend to hash the opaque @IO@ callback: core implementations are
named by their closed core constructor and project implementations by their
validated project operation identity, with the explicit revision attached by
the step vocabulary.
-}
data StepImplementationId
    = CoreStepImplementation CoreStepId StepImplementationRevision
    | ProjectStepImplementation Text StepImplementationRevision
    deriving (Eq)

-- | Closed identity for the adapter used by the reverse projection.
data ReverseAdapterId
    = PreserveReverseAdapter StepReverseAdapterRevision
    | CoreManagedReverseAdapter StepImplementationId StepReverseAdapterRevision
    | ProjectManagedReverseAdapter StepImplementationId StepReverseAdapterRevision
    | DeclaredReverseAdapter StepImplementationId StepReverseAdapterRevision
    deriving (Eq)

stepImplementationId :: Step -> StepImplementationId
stepImplementationId step =
    case stepIdentity step of
        CoreStepIdentity identity ->
            CoreStepImplementation identity (stepImplementationRevision step)
        ProjectStepIdentity _ ->
            ProjectStepImplementation
                (Text.pack (operationKeyText (stepOperationKey step)))
                (stepImplementationRevision step)

reverseAdapterId :: Step -> ReverseAdapterId
reverseAdapterId step
    | not (null (stepReverses step)) =
        DeclaredReverseAdapter implementation revision
    | otherwise =
        case stepReversePolicy step of
            PreserveOnReverse -> PreserveReverseAdapter revision
            CoreManagedReverse -> CoreManagedReverseAdapter implementation revision
            ProjectManagedReverse -> ProjectManagedReverseAdapter implementation revision
  where
    implementation = stepImplementationId step
    revision = stepReverseAdapterRevision step

{- | Encode the exact canonical root, a finalized specification identity, the
exact admitted config digest, and the validated step plan. The digest is
domain-separated by the spec identity while its cryptographic suffix covers
the exact canonical bytes.
-}
canonicalPlanSnapshot :: FilePath -> Text -> Text -> StepPlan -> CanonicalPlanSnapshot
canonicalPlanSnapshot root specDigest configDigest plan =
    CanonicalPlanSnapshot
        { internalSnapshotRoot = root
        , internalSnapshotSpecDigest = specDigest
        , internalSnapshotConfigDigest = configDigest
        , internalSnapshotBytes = bytes
        , internalSnapshotDigest = specDigest <> ":" <> sha256Hex bytes
        }
  where
    bytes =
        LazyByteString.toStrict
            ( Builder.toLazyByteString
                ( Builder.byteString canonicalPlanMagic
                    <> Builder.word64BE canonicalPlanSnapshotFormatVersion
                    <> taggedBuilder "root" (encodeCanonicalRoot root)
                    <> taggedText "spec-digest" specDigest
                    <> taggedText "config-digest" configDigest
                    <> taggedList "steps" (encodeStep (stepPlanSteps plan) plan) (stepPlanSteps plan)
                )
            )

encodeStep :: [Step] -> StepPlan -> Step -> Builder.Builder
encodeStep allSteps plan step =
    taggedRecord
        "step"
        [ taggedWord "ordinal" ordinal
        , taggedBuilder "identity" (encodeStepIdentity step)
        , taggedBuilder "implementation" (encodeImplementationId (stepImplementationId step))
        , taggedText "operation" (Text.pack (operationKeyText (stepOperationKey step)))
        , taggedList
            "projected-operations"
            (encodeText . Text.pack . operationKeyText)
            (stepProjectedOperations step)
        , taggedList
            "provider-resources"
            encodeProviderResourceDeclaration
            (stepProviderResourceDeclarations step)
        , taggedList
            "chart-workloads"
            encodeChartWorkloadDeclaration
            (stepChartWorkloadResourceDeclarations step)
        , taggedText "label" (Text.pack (stepLabel step))
        , taggedRecord
            "frame"
            [ taggedText "id" (Text.pack (frameId (stepFrame step)))
            , taggedText "label" (Text.pack (frameLabel (stepFrame step)))
            ]
        , taggedList
            "dependencies"
            (encodeDependency allSteps)
            (stepDependencies plan step)
        , taggedBuilder "reverse-policy" (encodeReversePolicy (stepReversePolicy step))
        , taggedBuilder "reverse-adapter" (encodeReverseAdapterId (reverseAdapterId step))
        , taggedList "descents" encodeLiftContext (stepDescents step)
        ]
  where
    ordinal =
        fromIntegral
            ( length
                (takeWhile ((/= stepIdentity step) . stepIdentity) allSteps)
                + 1
            )

encodeProviderResourceDeclaration :: ProviderResourceDeclaration -> Builder.Builder
encodeProviderResourceDeclaration declaration =
    encodeText
        ( if providerResourceDeclarationTargetsChild declaration
            then "immediate-child"
            else "current-frame"
        )

encodeChartWorkloadDeclaration :: (Text, Text, Text, Text, Text, Text, Text, Text, [Text]) -> Builder.Builder
encodeChartWorkloadDeclaration (artifact, release, namespace, valuesDigest, imageIdentity, workloadKey, workloadDigest, serviceRole, effects) =
    taggedRecord "chart-workload"
        [ taggedText "artifact-digest" artifact
        , taggedText "release" release
        , taggedText "namespace" namespace
        , taggedText "values-digest" valuesDigest
        , taggedText "image-identity" imageIdentity
        , taggedText "workload-key" workloadKey
        , taggedText "workload-digest" workloadDigest
        , taggedText "service-role" serviceRole
        , taggedList "effects" encodeText effects
        ]

encodeDependency :: [Step] -> StepIdentity -> Builder.Builder
encodeDependency allSteps identity =
    case find ((== identity) . stepIdentity) allSteps of
        Just dependency -> encodeStepIdentity dependency
        Nothing -> taggedText "invalid-missing-dependency" ""

encodeStepIdentity :: Step -> Builder.Builder
encodeStepIdentity step =
    case stepIdentity step of
        CoreStepIdentity identity ->
            taggedBuilder "core-step" (encodeCoreStepId identity)
        ProjectStepIdentity _ ->
            taggedText "project-step" (Text.pack (operationKeyText (stepOperationKey step)))

encodeImplementationId :: StepImplementationId -> Builder.Builder
encodeImplementationId implementation =
    case implementation of
        CoreStepImplementation identity revision ->
            taggedRecord
                "core-implementation"
                [ taggedBuilder "identity" (encodeCoreStepId identity)
                , taggedWord "revision" (stepImplementationRevisionNumber revision)
                ]
        ProjectStepImplementation operation revision ->
            taggedRecord
                "project-implementation"
                [ taggedText "operation" operation
                , taggedWord "revision" (stepImplementationRevisionNumber revision)
                ]

encodeReverseAdapterId :: ReverseAdapterId -> Builder.Builder
encodeReverseAdapterId adapter =
    case adapter of
        PreserveReverseAdapter revision ->
            encodeVersionedReverseAdapter "preserve" Nothing revision
        CoreManagedReverseAdapter implementation revision ->
            encodeVersionedReverseAdapter "core-managed" (Just implementation) revision
        ProjectManagedReverseAdapter implementation revision ->
            encodeVersionedReverseAdapter "project-managed" (Just implementation) revision
        DeclaredReverseAdapter implementation revision ->
            encodeVersionedReverseAdapter "step-declared" (Just implementation) revision

encodeVersionedReverseAdapter ::
    Text ->
    Maybe StepImplementationId ->
    StepReverseAdapterRevision ->
    Builder.Builder
encodeVersionedReverseAdapter kind implementation revision =
    taggedRecord
        kind
        [ taggedMaybe "implementation" encodeImplementationId implementation
        , taggedWord "revision" (stepReverseAdapterRevisionNumber revision)
        ]

encodeCoreStepId :: CoreStepId -> Builder.Builder
encodeCoreStepId identity =
    case identity of
        DeployVMId -> taggedText "deploy-vm" ""
        EnsureToolId tool -> taggedText "ensure-tool" (Text.pack tool)
        CopySourceId -> taggedText "copy-source" ""
        BuildPbId -> taggedText "build-pb" ""
        BuildImageId -> taggedText "build-image" ""
        ContextInitId -> taggedText "context-init" ""
        DeployKindId -> taggedText "deploy-kind" ""
        DeployChartId -> taggedText "deploy-chart" ""
        ExposePortId -> taggedText "expose-port" ""
        PostHandoffId name -> taggedText "post-handoff" (Text.pack name)

encodeReversePolicy :: ReversePolicy -> Builder.Builder
encodeReversePolicy policy =
    case policy of
        PreserveOnReverse -> taggedText "preserve" ""
        CoreManagedReverse -> taggedText "core-managed" ""
        ProjectManagedReverse -> taggedText "project-managed" ""

encodeLiftContext :: LiftContext -> Builder.Builder
encodeLiftContext (LiftContext layers) = taggedList "lift-layers" encodeLiftLayer layers

encodeLiftLayer :: LiftLayer -> Builder.Builder
encodeLiftLayer layer =
    case layer of
        ViaVM vm ->
            taggedRecord
                "incus"
                [ taggedText "name" (Text.pack (vmName vm))
                , taggedText "image" (Text.pack (vmImage vm))
                ]
        ViaLimaVM vm ->
            taggedRecord "lima" [taggedText "name" (Text.pack (limaName vm))]
        ViaWsl2VM vm ->
            taggedRecord "wsl2" [taggedText "distro" (Text.pack (wsl2Distro vm))]
        ViaContainer container -> encodeContainer container

encodeContainer :: ContainerLift -> Builder.Builder
encodeContainer container =
    taggedRecord
        "container"
        [ taggedText "image" (Text.pack (clImage container))
        , taggedList "mounts" encodeMount (clMounts container)
        , taggedList "extra-args" (encodeText . Text.pack) (clExtraArgs container)
        , taggedBool "remove-after" (clRemoveAfter container)
        , taggedMaybe "config-delivery" encodeConfigDelivery (clConfigDelivery container)
        ]

encodeMount :: Mount -> Builder.Builder
encodeMount mount =
    taggedRecord
        "mount"
        [ taggedText "source" (source mount)
        , taggedText "target" (target mount)
        , taggedBool "read-only" (readOnly mount)
        ]

encodeConfigDelivery :: ConfigDelivery -> Builder.Builder
encodeConfigDelivery delivery =
    taggedRecord
        "config-delivery"
        [ taggedText "write-path" (Text.pack (cdWritePath delivery))
        , taggedText "exec-path" (Text.pack (cdExecPath delivery))
        , taggedText
            "payload-digest"
            (sha256Hex (TextEncoding.encodeUtf8 (cdPayload delivery)))
        ]

taggedBuilder :: Text -> Builder.Builder -> Builder.Builder
taggedBuilder tag value = encodeText tag <> value

taggedText :: Text -> Text -> Builder.Builder
taggedText tag value = taggedBuilder tag (encodeText value)

taggedWord :: Text -> Word64 -> Builder.Builder
taggedWord tag value = encodeText tag <> Builder.word64BE value

taggedBool :: Text -> Bool -> Builder.Builder
taggedBool tag value =
    encodeText tag <> Builder.word8 (if value then 1 else 0)

taggedRecord :: Text -> [Builder.Builder] -> Builder.Builder
taggedRecord tag fields =
    encodeText tag
        <> Builder.word64BE (fromIntegral (length fields))
        <> mconcat fields

taggedList :: Text -> (value -> Builder.Builder) -> [value] -> Builder.Builder
taggedList tag encodeValue values =
    encodeText tag
        <> Builder.word64BE (fromIntegral (length values))
        <> foldMap encodeValue values

taggedMaybe :: Text -> (value -> Builder.Builder) -> Maybe value -> Builder.Builder
taggedMaybe tag encodeValue value =
    encodeText tag
        <> case value of
            Nothing -> Builder.word8 0
            Just present -> Builder.word8 1 <> encodeValue present

encodeText :: Text -> Builder.Builder
encodeText value =
    let bytes = TextEncoding.encodeUtf8 value
     in Builder.word64BE (fromIntegral (ByteStringChar8.length bytes))
            <> Builder.byteString bytes

encodeCanonicalRoot :: FilePath -> Builder.Builder
encodeCanonicalRoot root =
    Builder.word64BE (fromIntegral (length root) * 4)
        <> foldMap (Builder.word32BE . fromIntegral . ord) root

sha256Hex :: ByteString -> Text
sha256Hex payload =
    Text.pack (concatMap hex (ByteArray.unpack (Hash.hashWith Hash.SHA256 payload)))
  where
    hex byte = [hexDigit (byte `shiftR` 4), hexDigit (byte .&. 0x0f)]
    hexDigit nibble = ByteStringChar8.index "0123456789abcdef" (fromIntegral nibble)
