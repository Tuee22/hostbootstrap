{-# LANGUAGE OverloadedStrings #-}

{- | Canonical, non-secret lifecycle-plan snapshots.

The encoder is deliberately independent of 'Show' instances and delimiter
joining. Every variable-width value is length-framed, every list carries an
explicit count, and the fixed header carries a format version. Executable
callbacks are not serializable and are never inspected or rendered. Instead,
the snapshot records closed implementation and reverse-adapter identities made
from the step's typed identity, declared reverse shape, and explicit positive
implementation/adapter revisions.

Configuration enters this representation only as a caller-supplied digest and
as the digest of an in-place child-config payload. The raw payload is never
present in the canonical bytes.
-}
module HostBootstrap.Lifecycle.Plan
    ( CanonicalPlanSnapshot
    , canonicalPlanSnapshot
    , canonicalPlanSnapshotFormatVersion
    , canonicalPlanSnapshotSpecDigest
    , canonicalPlanSnapshotConfigDigest
    , canonicalPlanSnapshotBytes
    , canonicalPlanSnapshotDigest
    , StepImplementationId
    , stepImplementationId
    , ReverseAdapterId
    , reverseAdapterId
    )
where

import qualified Crypto.Hash as Hash
import Data.Bits ((.&.), shiftR)
import qualified Data.ByteArray as ByteArray
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Config.Vocab (Mount (..))
import HostBootstrap.Incus (IncusVM (..))
import HostBootstrap.Lift
    ( ConfigDelivery (..)
    , ContainerLift (..)
    , LiftContext (..)
    , LiftLayer (..)
    )
import HostBootstrap.Lima (LimaVM (..))
import HostBootstrap.Step
    ( CoreStepId (..)
    , ReversePolicy (..)
    , Step
    , StepIdentity (..)
    , StepImplementationRevision
    , StepPlan
    , StepReverseAdapterRevision
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
    , stepPlanSteps
    , stepReversePolicy
    , stepReverseAdapterRevision
    , stepReverseAdapterRevisionNumber
    , stepReverses
    )
import HostBootstrap.Wsl2 (Wsl2VM (..))

-- | The current stable wire version. Changing the schema requires a new value;
-- old bytes must never be reinterpreted under a new schema.
canonicalPlanSnapshotFormatVersion :: Word64
canonicalPlanSnapshotFormatVersion = 1

{- | An exact canonical plan snapshot. Its constructor is private so the digest
always describes the retained bytes.
-}
data CanonicalPlanSnapshot = CanonicalPlanSnapshot
    { internalSnapshotSpecDigest :: Text
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

canonicalPlanSnapshotConfigDigest :: CanonicalPlanSnapshot -> Text
canonicalPlanSnapshotConfigDigest = internalSnapshotConfigDigest

canonicalPlanSnapshotBytes :: CanonicalPlanSnapshot -> ByteString
canonicalPlanSnapshotBytes = internalSnapshotBytes

canonicalPlanSnapshotDigest :: CanonicalPlanSnapshot -> Text
canonicalPlanSnapshotDigest = internalSnapshotDigest

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

{- | Encode a finalized specification identity, the exact admitted config
digest, and the validated step plan. The digest is domain-separated by the spec
identity while its cryptographic suffix covers the exact canonical bytes.
-}
canonicalPlanSnapshot :: Text -> Text -> StepPlan -> CanonicalPlanSnapshot
canonicalPlanSnapshot specDigest configDigest plan =
    CanonicalPlanSnapshot
        { internalSnapshotSpecDigest = specDigest
        , internalSnapshotConfigDigest = configDigest
        , internalSnapshotBytes = bytes
        , internalSnapshotDigest = specDigest <> ":" <> sha256Hex bytes
        }
  where
    bytes =
        LazyByteString.toStrict
            ( Builder.toLazyByteString
                ( Builder.byteString "HOSTBOOTSTRAP-PLAN"
                    <> Builder.word64BE canonicalPlanSnapshotFormatVersion
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

sha256Hex :: ByteString -> Text
sha256Hex payload =
    Text.pack (concatMap hex (ByteArray.unpack (Hash.hashWith Hash.SHA256 payload)))
  where
    hex byte = [hexDigit (byte `shiftR` 4), hexDigit (byte .&. 0x0f)]
    hexDigit nibble = ByteStringChar8.index "0123456789abcdef" (fromIntegral nibble)
