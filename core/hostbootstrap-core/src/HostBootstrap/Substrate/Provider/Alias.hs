{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Portable, plan-indexed reconciliation for a provider-guest durable alias.

The preparation and settlement algebra is pure; the backend that observes and
mutates the guest comes only from a provider-bound retained capability, so it
runs against the exact managed guest generation that discovery proved.

The backend holds the four Locked-Origin Identity Ownership clauses of
@development_plan_standards.md § EE@ by shipping one closed symbolic-link act
to the project binary already installed in the guest.  That far-side binary
opens the shared protected store, records absence before publication, publishes
through a no-replace hard link, binds the symlink's own kernel identity, and
conditionally releases only that identity.  The record lives inside the
host-backed durable target and uses the shared origin-record codec.  There is no
guest interpreter program and no discovered @flock@, @stat@, or Python front
end: the ownership row and kernel in the frame that owns the link answer every
clause.
-}
module HostBootstrap.Substrate.Provider.Alias (
    GuestAliasSpec,
    mkGuestAliasSpec,
    guestAliasPath,
    guestAliasTarget,
    guestAliasLinkTarget,
    guestAliasOwnershipTransaction,
    shippedAliasFailureRecovery,
    PreparedGuestAliasCall,
    withPreparedGuestAliasCall,
    AliasCallObservation,
    AliasCallResult,
    AliasCallResultView (..),
    aliasCallResultView,
    ManagedGuestAliasHandle,
    managedGuestAliasKey,
    managedGuestAliasGeneration,
    managedGuestAliasObservationVersion,
    managedGuestAliasOperationKey,
    GuestAliasCallSettlement,
    withGuestAliasCallSettlement,
    settlePreparedGuestAliasCall,
    StrongAliasBackend,
    discoverStrongAliasBackend,
    runPreparedGuestAliasCall,
    PreparedGuestAliasRelease,
    withPreparedGuestAliasRelease,
    runPreparedGuestAliasRelease,

    -- * The node's route
    GuestAliasSettlement (..),
    reconcileNodeGuestAlias,
)
where

import qualified Crypto.Hash as Hash
import Data.Bits (shiftR, (.&.))
import qualified Data.ByteArray as ByteArray
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Execution (
    StepExecution,
    stepExecutionTakeProjectedGate,
 )
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.Lift (LiftContext, SelfRef)
import HostBootstrap.Ownership.Object (
    ConflictReport,
    Origin (..),
    OwnershipFault (..),
 )
import qualified HostBootstrap.Ownership.Object as Ownership
import HostBootstrap.Ownership.Shipped (
    ShippedAct (..),
    ShippedOutcome (..),
    ShippedFailure (..),
    ShippedAuthorityPath,
    ShippedTargetPath,
    ShippedLinkTargetPath,
    ShippedOwnership,
    mkShippedAuthorityPath,
    mkShippedTargetPath,
    mkShippedLinkTargetPath,
    shippedLinkTargetPath,
    shippedTargetPath,
    mkShippedOwnership,
    shipOwnedTransaction,
 )
import HostBootstrap.Protected (RecordKey, mkRecordKey, protectedErrorMessage)
import HostBootstrap.Reconcile (
    BackendReconcileObservation (..),
    ChangeView,
    ConflictDetail (..),
    DependencyProbe,
    DurableAliasResource,
    DurableShareResource,
    FailureDetail (..),
    ForeignObservation (..),
    Managed,
    Observed,
    OwnershipReceipt,
    PlannedEdge,
    PlannedResource,
    PreparedOperation,
    PreparedPreconditions,
    PriorCommitProof,
    ProviderResource,
    Provisioned,
    ReconcileError (..),
    ReconcileResult,
    RecoveryDisposition (DoNotRetry, ReprobeBeforeRetry),
    ResourceHandle,
    Running,
    Unclassified,
    UnsupportedDetail (..),
    completePreparedUnchanged,
    completeReconcile,
    emptyDependencySnapshot,
    plannedGuestAliasOperation,
    plannedResourceKey,
    plannedResourcePlanDigest,
    ownershipReceiptOperationKey,
    resourceHandleGeneration,
    resourceHandleKey,
    resourceHandleObservationVersion,
    validateOwnershipReceipt,
    withDependencySnapshotEntry,
    withNodeGuestAliasProjection,
    withNodeObservedResource,
    withPreparedOperation,
    withReconcileResult,
 )
import HostBootstrap.Substrate.Provider (
    GuestProviderDiscovery (..),
    ProviderCapability,
    ProviderDiscovery (..),
    ProviderObservation (..),
    providerCapabilityDiscovery,
    providerCapabilityGeneration,
    providerCapabilityLiftContext,
 )
import HostBootstrap.Substrate.Provider.Dependency.Internal (
    ProviderShareDependency,
    providerShareDependencyProbe,
    withLocalProviderShareDependency,
 )
import HostBootstrap.Substrate.Provider.Observation.Internal (
    ManagedProviderHandle (..),
    ManagedProviderShareHandle (..),
    ProviderOriginBinding (..),
    providerBackendRealizationFingerprint,
    providerBackendSemanticFingerprint,
    providerOriginOwner,
 )
import qualified System.FilePath.Posix as Posix

data GuestAliasSpec = GuestAliasSpec ShippedTargetPath ShippedLinkTargetPath ShippedAuthorityPath RecordKey
    deriving (Eq, Show)

mkGuestAliasSpec :: FilePath -> FilePath -> Either ReconcileError GuestAliasSpec
mkGuestAliasSpec aliasPath target
    | not (guestAbsolute aliasPath) =
        invalid "alias path must be an absolute POSIX guest path"
    | not (guestAbsolute target) =
        invalid "alias target must be an absolute POSIX guest path"
    | '\0' `elem` aliasPath || '\0' `elem` target =
        invalid "alias path and target must not contain NUL"
    | aliasPath == "/" =
        invalid "alias path must name a non-root guest entry"
    | last aliasPath == '/' =
        invalid "alias path must not have a trailing slash"
    | not (guestLexicallyUnambiguous aliasPath) || not (guestLexicallyUnambiguous target) =
        invalid "alias path and target must not contain empty, dot, or dot-dot segments"
    | trimGuestPath aliasPath == trimGuestPath target =
        invalid "alias path and target must differ"
    | aliasSegments `isPrefixOf` targetSegments =
        invalid "alias path must not be an ancestor of its target"
    | (targetSegments <> [".hostbootstrap-alias-authority-v1"]) `isPrefixOf` aliasSegments =
        invalid "alias path must not overlap the target alias authority directory"
    | otherwise = do
        admittedAlias <- either (invalid . Text.pack . show) Right (mkShippedTargetPath aliasPath)
        admittedTarget <- either (invalid . Text.pack . show) Right (mkShippedLinkTargetPath target)
        authority <-
            either
                (invalid . Text.pack . show)
                Right
                (mkShippedAuthorityPath (target Posix.</> ".hostbootstrap-alias-authority-v1"))
        key <- either (invalid . protectedErrorMessage) Right (mkRecordKey (aliasRecordName aliasPath target))
        Right (GuestAliasSpec admittedAlias admittedTarget authority key)
  where
    aliasSegments = filter (not . null) (splitSegments aliasPath)
    targetSegments = filter (not . null) (splitSegments target)
    invalid reason =
        Left
            ( Failure
                (FailureDetail "validate provider guest alias" reason DoNotRetry)
            )

guestAliasPath :: GuestAliasSpec -> FilePath
guestAliasPath (GuestAliasSpec aliasPath _ _ _) = shippedTargetPath aliasPath

guestAliasTarget :: GuestAliasSpec -> FilePath
guestAliasTarget (GuestAliasSpec _ target _ _) = shippedLinkTargetPath target

guestAliasLinkTarget :: GuestAliasSpec -> ShippedLinkTargetPath
guestAliasLinkTarget (GuestAliasSpec _ target _ _) = target

guestAbsolute :: FilePath -> Bool
guestAbsolute ('/' : _) = True
guestAbsolute _ = False

guestLexicallyUnambiguous :: FilePath -> Bool
guestLexicallyUnambiguous "/" = True
guestLexicallyUnambiguous ('/' : rest) =
    not (null rest) && all validSegment (splitSegments rest)
  where
    validSegment segment = not (null segment) && segment /= "." && segment /= ".."
guestLexicallyUnambiguous _ = False

splitSegments :: String -> [String]
splitSegments value = case break (== '/') value of
    (segment, []) -> [segment]
    (segment, _ : rest) -> segment : splitSegments rest

trimGuestPath :: FilePath -> FilePath
trimGuestPath "/" = "/"
trimGuestPath value = reverse (dropWhile (== '/') (reverse value))

aliasCallDigest ::
    ProviderOriginBinding scope planId backendId providerId ->
    ResourceHandle scope planId shareId DurableShareResource Managed Provisioned ->
    GuestAliasSpec ->
    Text
aliasCallDigest origin share spec =
    "guest-alias:"
        <> sizedText (providerOriginOwner origin)
        <> ":"
        <> sizedText (resourceHandleKey share)
        <> ":"
        <> sizedText (showText (resourceHandleGeneration share))
        <> ":"
        <> sized (guestAliasPath spec)
        <> ":"
        <> sized (guestAliasTarget spec)
  where
    sized value = Text.pack (show (length value)) <> ":" <> Text.pack value
    sizedText value = showText (Text.length value) <> ":" <> value

data PreparedGuestAliasCall scope planId providerId backendId capabilityId aliasId shareId operationKey callDigest attempt journalVersion
    = PreparedGuestAliasCall
        GuestAliasSpec
        (ManagedProviderHandle scope planId backendId providerId Running)
        (ManagedProviderShareHandle scope planId backendId providerId shareId Provisioned)
        (ResourceHandle scope planId aliasId DurableAliasResource Unclassified Observed)
        (PreparedOperation scope planId aliasId DurableAliasResource operationKey callDigest attempt journalVersion)
        (PreparedPreconditions scope planId aliasId DurableAliasResource operationKey callDigest attempt journalVersion)

type role PreparedGuestAliasCall nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

withPreparedGuestAliasCall ::
    StrongAliasBackend scope planId providerId backendId capabilityId ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    ManagedProviderShareHandle scope planId backendId providerId shareId Provisioned ->
    PlannedResource scope planId aliasId DurableAliasResource aliasFrame ->
    PlannedEdge
        scope
        planId
        aliasId
        DurableAliasResource
        aliasFrame
        shareId
        DurableShareResource
        shareFrame ->
    ResourceHandle scope planId aliasId DurableAliasResource Unclassified Observed ->
    DependencyProbe scope planId shareId DurableShareResource readiness ->
    GuestAliasSpec ->
    PreparedGate ->
    ( forall operationKey callDigest attempt journalVersion.
      PreparedGuestAliasCall
        scope
        planId
        providerId
        backendId
        capabilityId
        aliasId
        shareId
        operationKey
        callDigest
        attempt
        journalVersion ->
      result
    ) ->
    IO (Either ReconcileError result)
withPreparedGuestAliasCall
    backend
    managedProvider@(ManagedProviderHandle providerOrigin providerHandle providerReceipt)
    managedShare@(ManagedProviderShareHandle shareOrigin shareHandle shareReceipt _)
    planned
    edge
    aliasHandle
    shareProbe
    spec
    gate
    consume
        | strongAliasProviderGeneration backend /= resourceHandleGeneration providerHandle =
            pure
                ( Left
                    ( Conflict
                        ( ConflictDetail
                            (resourceHandleKey providerHandle)
                            ("provider-generation=" <> showText (strongAliasProviderGeneration backend))
                            ("provider-generation=" <> showText (resourceHandleGeneration providerHandle))
                            "rediscover the alias backend from this exact managed provider generation"
                        )
                    )
                )
        | not (sameProviderOrigin providerOrigin shareOrigin) =
            pure
                ( Left
                    ( Conflict
                        ( ConflictDetail
                            (resourceHandleKey shareHandle)
                            "a share derived from this exact provider origin"
                            "a share derived from another provider origin"
                            "use the provider share settled through this managed provider authority"
                        )
                    )
                )
        | providerOriginPlanDigest providerOrigin /= plannedResourcePlanDigest planned =
            pure
                ( Left
                    ( Conflict
                        ( ConflictDetail
                            (resourceHandleKey aliasHandle)
                            ("provider origin plan=" <> providerOriginPlanDigest providerOrigin)
                            ("alias plan=" <> plannedResourcePlanDigest planned)
                            "prepare the alias from the provider origin plan"
                        )
                    )
                )
        | otherwise = case validateOwnershipReceipt providerHandle providerReceipt of
            Left err -> pure (Left err)
            Right () -> case validateOwnershipReceipt shareHandle shareReceipt of
                Left err -> pure (Left err)
                Right () ->
                    case plannedGuestAliasOperation
                        planned
                        edge
                        aliasHandle
                        (aliasCallDigest providerOrigin shareHandle spec) of
                        Left err -> pure (Left err)
                        Right descriptor ->
                            withPreparedOperation
                                descriptor
                                ( withDependencySnapshotEntry
                                    shareHandle
                                    shareProbe
                                    emptyDependencySnapshot
                                )
                                gate
                                ( \prepared preconditions ->
                                    consume
                                        ( PreparedGuestAliasCall
                                            spec
                                            managedProvider
                                            managedShare
                                            aliasHandle
                                            prepared
                                            preconditions
                                        )
                                )

sameProviderOrigin ::
    ProviderOriginBinding scope planId backendId providerId ->
    ProviderOriginBinding scope planId backendId providerId ->
    Bool
sameProviderOrigin left right =
    providerOriginPlanDigest left == providerOriginPlanDigest right
        && providerOriginResourceKey left == providerOriginResourceKey right
        && providerOriginGeneration left == providerOriginGeneration right
        && providerBackendSemanticFingerprint (providerOriginBackendBinding left)
            == providerBackendSemanticFingerprint (providerOriginBackendBinding right)
        && providerBackendRealizationFingerprint (providerOriginBackendBinding left)
            == providerBackendRealizationFingerprint (providerOriginBackendBinding right)

{- | Structured result from the protected backend boundary.  Created/repaired
observations authorize ownership only after settlement against the exact
prepared operation. A retained recorded link settles Repaired without a prior
commit proof and Unchanged with a matching one; an unrecorded link is foreign.
-}
data AliasCallObservation
    = AliasCallCreated
    | AliasCallRepaired
    | AliasCallAlreadyExact
    | AliasCallForeign ForeignObservation
    | AliasCallConflict ConflictDetail
    | AliasCallUnsupported UnsupportedDetail
    | AliasCallFailed FailureDetail
    deriving (Eq, Show)

-- | Indexed proof that the strong backend ran this exact prepared call.
-- The generation is descriptive view metadata; settlement takes its generation
-- from the retained prepared handle.
data AliasCallResult scope planId providerId backendId capabilityId aliasId shareId operationKey callDigest attempt journalVersion
    = AliasCallResult Word64 AliasCallObservation

type role AliasCallResult nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

-- | Descriptive, non-authorizing view of an indexed backend result.
data AliasCallResultView
    = AliasResultCreated Word64
    | AliasResultRepaired Word64
    | AliasResultAlreadyExact Word64
    | AliasResultForeign Word64 ForeignObservation
    | AliasResultConflict ConflictDetail
    | AliasResultUnsupported UnsupportedDetail
    | AliasResultFailed FailureDetail
    deriving (Eq, Show)

aliasCallResultView ::
    AliasCallResult scope planId providerId backendId capabilityId aliasId shareId operationKey callDigest attempt journalVersion ->
    AliasCallResultView
aliasCallResultView (AliasCallResult generation observation) = case observation of
    AliasCallCreated -> AliasResultCreated generation
    AliasCallRepaired -> AliasResultRepaired generation
    AliasCallAlreadyExact -> AliasResultAlreadyExact generation
    AliasCallForeign foreignState -> AliasResultForeign generation foreignState
    AliasCallConflict detail -> AliasResultConflict detail
    AliasCallUnsupported detail -> AliasResultUnsupported detail
    AliasCallFailed detail -> AliasResultFailed detail

{- | Opaque managed alias authority retained after exact settlement.

The indices bind provider, backend, discovered capability, alias, and durable
share. The constructor retains the exact alias/target specification plus the
generic managed handle and receipt, but none of those authorizing values is
projected publicly.
-}
data ManagedGuestAliasHandle scope planId providerId backendId capabilityId aliasId shareId phase
    = ManagedGuestAliasHandle
        GuestAliasSpec
        (ResourceHandle scope planId aliasId DurableAliasResource Managed phase)
        (OwnershipReceipt scope planId aliasId DurableAliasResource)

type role ManagedGuestAliasHandle nominal nominal nominal nominal nominal nominal nominal nominal

managedGuestAliasKey ::
    ManagedGuestAliasHandle scope planId providerId backendId capabilityId aliasId shareId phase ->
    Text
managedGuestAliasKey (ManagedGuestAliasHandle _ handle _) = resourceHandleKey handle

managedGuestAliasGeneration ::
    ManagedGuestAliasHandle scope planId providerId backendId capabilityId aliasId shareId phase ->
    Word64
managedGuestAliasGeneration (ManagedGuestAliasHandle _ handle _) = resourceHandleGeneration handle

managedGuestAliasObservationVersion ::
    ManagedGuestAliasHandle scope planId providerId backendId capabilityId aliasId shareId phase ->
    Word64
managedGuestAliasObservationVersion (ManagedGuestAliasHandle _ handle _) =
    resourceHandleObservationVersion handle

-- | Descriptive journal metadata of this settled acquisition. The receipt and
-- generic managed handle remain private; verifying a prior commit still needs
-- the exact admitted plan, resource, generation and committed journal record.
managedGuestAliasOperationKey ::
    ManagedGuestAliasHandle scope planId providerId backendId capabilityId aliasId shareId phase ->
    Text
managedGuestAliasOperationKey (ManagedGuestAliasHandle _ _ receipt) =
    ownershipReceiptOperationKey receipt

data GuestAliasCallSettlement scope planId providerId backendId capabilityId aliasId shareId
    = ManagedGuestAlias
        ( ManagedGuestAliasHandle
            scope
            planId
            providerId
            backendId
            capabilityId
            aliasId
            shareId
            Provisioned
        )
        ChangeView
    | ForeignGuestAlias Text Word64 Word64 ForeignObservation

type role GuestAliasCallSettlement nominal nominal nominal nominal nominal nominal nominal

withGuestAliasCallSettlement ::
    GuestAliasCallSettlement scope planId providerId backendId capabilityId aliasId shareId ->
    ( ManagedGuestAliasHandle
        scope
        planId
        providerId
        backendId
        capabilityId
        aliasId
        shareId
        Provisioned ->
      ChangeView ->
      result
    ) ->
    (Text -> Word64 -> Word64 -> ForeignObservation -> result) ->
    result
withGuestAliasCallSettlement settlement consumeManaged consumeForeign = case settlement of
    ManagedGuestAlias managed change -> consumeManaged managed change
    ForeignGuestAlias key generation version observation ->
        consumeForeign key generation version observation

settlePreparedGuestAliasCall ::
    Maybe (PriorCommitProof scope planId aliasId DurableAliasResource) ->
    PreparedGuestAliasCall
        scope
        planId
        providerId
        backendId
        capabilityId
        aliasId
        shareId
        operationKey
        callDigest
        attempt
        journalVersion ->
    AliasCallResult
        scope
        planId
        providerId
        backendId
        capabilityId
        aliasId
        shareId
        operationKey
        callDigest
        attempt
        journalVersion ->
    Either
        ReconcileError
        ( GuestAliasCallSettlement
            scope
            planId
            providerId
            backendId
            capabilityId
            aliasId
            shareId
        )
settlePreparedGuestAliasCall
    priorProof
    (PreparedGuestAliasCall spec _ _ handle prepared preconditions)
    (AliasCallResult _ observation) = do
        let generation = resourceHandleGeneration handle
        reconciled <- case observation of
            AliasCallCreated ->
                completeReconcile handle prepared preconditions (BackendCreated generation)
            AliasCallRepaired ->
                completeReconcile handle prepared preconditions (BackendRepaired generation)
            AliasCallAlreadyExact
                | Just proof <- priorProof ->
                    completePreparedUnchanged handle prepared preconditions proof
                | otherwise ->
                    completeReconcile
                        handle
                        prepared
                        preconditions
                        (BackendRepaired generation)
            AliasCallForeign foreignState ->
                completeReconcile
                    handle
                    prepared
                    preconditions
                    (BackendForeign generation foreignState)
            AliasCallConflict detail -> Left (Conflict detail)
            AliasCallUnsupported detail -> Left (Unsupported detail)
            AliasCallFailed detail -> Left (Failure detail)
        guestAliasSettlement spec reconciled

guestAliasSettlement ::
    GuestAliasSpec ->
    ReconcileResult scope planId aliasId DurableAliasResource Provisioned ->
    Either
        ReconcileError
        ( GuestAliasCallSettlement
            scope
            planId
            providerId
            backendId
            capabilityId
            aliasId
            shareId
        )
guestAliasSettlement spec reconciled =
    withReconcileResult
        reconciled
        ( \handle receipt change -> do
            validateOwnershipReceipt handle receipt
            Right
                ( ManagedGuestAlias
                    (ManagedGuestAliasHandle spec handle receipt)
                    change
                )
        )
        ( \foreignHandle observation ->
            Right
                ( ForeignGuestAlias
                    (resourceHandleKey foreignHandle)
                    (resourceHandleGeneration foreignHandle)
                    (resourceHandleObservationVersion foreignHandle)
                    observation
                )
        )

showText :: (Show value) => value -> Text
showText = Text.pack . show

{- | Capability for a backend that holds the four Locked-Origin Identity
Ownership clauses for a provider-guest durable alias.  Its constructor is
private: it is minted only by 'discoverStrongAliasBackend' after that verifies
the capability names a ready managed guest.  It retains the exact host
configuration, project-binary identity, and lift context that carry the shipped
transaction to that guest generation.
-}
data StrongAliasBackend scope planId providerId backendId capabilityId
    = StrongAliasBackend
        Word64
        HostConfig
        SelfRef
        LiftContext

type role StrongAliasBackend nominal nominal nominal nominal nominal

strongAliasProviderGeneration :: StrongAliasBackend scope planId providerId backendId capabilityId -> Word64
strongAliasProviderGeneration (StrongAliasBackend generation _ _ _) = generation

{- | Narrow one opaque provider capability to the alias backend.

Discovery has already run at the provider boundary.  This function performs no
second probe and accepts no descriptive tool names. Failed discovery
observations remain descriptive and prevent this narrower capability from being
minted.
-}
discoverStrongAliasBackend ::
    HostConfig ->
    SelfRef ->
    ProviderCapability scope planId providerId backendId capabilityId ->
    Either ReconcileError (StrongAliasBackend scope planId providerId backendId capabilityId)
discoverStrongAliasBackend config self capability = do
    retainedGuestFrame (providerCapabilityDiscovery capability)
    Right
        ( StrongAliasBackend
            (providerCapabilityGeneration capability)
            config
            self
            (providerCapabilityLiftContext capability)
        )
  where
    retainedGuestFrame discovery = case discovery of
        ProviderDirectDiscovery _ ->
            Left
                ( Unsupported
                    ( UnsupportedDetail
                        "reconcile provider guest durable alias"
                        "the direct host has no guest alias frame"
                    )
                )
        ProviderGuestDiscovery guest -> do
            _ <- requireObservation "provider daemon" (discoveryDaemon guest)
            _ <- requireObservation "provider VM capability" (discoveryVmCapability guest)
            requireNonTerminalEgress (discoveryEgress guest)

    requireNonTerminalEgress observed = case observed of
        ProviderObservedReady () -> Right ()
        ProviderObservedNotReady _ -> Right ()
        ProviderObservedUnavailable _ -> Right ()
        ProviderObservedConflict conflict ->
            () <$ requireObservation "provider provisioning egress" (ProviderObservedConflict conflict)
        ProviderObservedFailure failure ->
            () <$ requireObservation "provider provisioning egress" (ProviderObservedFailure failure)

requireObservation :: Text -> ProviderObservation value -> Either ReconcileError value
requireObservation _ (ProviderObservedReady value) = Right value
requireObservation label (ProviderObservedNotReady reason) =
    Left (Failure (FailureDetail label (Text.pack reason) ReprobeBeforeRetry))
requireObservation label (ProviderObservedUnavailable reason) =
    Left (Unsupported (UnsupportedDetail label (Text.pack reason)))
requireObservation label (ProviderObservedConflict conflict) =
    Left
        ( Conflict
            ( ConflictDetail
                label
                "the provider-owned discovery expectation"
                (Text.pack (show conflict))
                "resolve the discovery conflict and rediscover the exact provider"
            )
        )
requireObservation label (ProviderObservedFailure failure) =
    Left (Failure (FailureDetail label (Text.pack (show failure)) DoNotRetry))

{- | Ship this prepared call's symbolic-link ownership transaction to its
retained guest frame.

The strong backend supplies the host configuration, project binary self
reference and capability lift context. The shared shipped program performs
object ownership in that frame; this adapter supplies the exact alias and
target declaration and classifies the returned crossing or ownership outcome.
The indexed result belongs to this prepared call and still requires settlement.
-}
runPreparedGuestAliasCall ::
    StrongAliasBackend scope planId providerId backendId capabilityId ->
    PreparedGuestAliasCall
        scope
        planId
        providerId
        backendId
        capabilityId
        aliasId
        shareId
        operationKey
        callDigest
        attempt
        journalVersion ->
    IO
        ( AliasCallResult
            scope
            planId
            providerId
            backendId
            capabilityId
            aliasId
            shareId
            operationKey
            callDigest
            attempt
            journalVersion
        )
runPreparedGuestAliasCall
    (StrongAliasBackend _ config self context)
    (PreparedGuestAliasCall spec _ _ handle _ _) = do
        result <- shipOwnedTransaction config self context (guestAliasOwnershipTransaction spec (ShipTakeSymbolicLink (guestAliasLinkTarget spec)))
        pure
            ( AliasCallResult
                (resourceHandleGeneration handle)
                (shippedAliasObservation spec result)
            )

-- | Bounded, collision-resistant filename under the durable target share.
aliasRecordName :: FilePath -> FilePath -> Text
aliasRecordName aliasPath target =
    "guest-alias."
        <> digestText (Text.pack aliasPath <> "\0" <> Text.pack target)
        <> ".record"

guestAliasOwnershipTransaction :: GuestAliasSpec -> ShippedAct -> ShippedOwnership
guestAliasOwnershipTransaction (GuestAliasSpec aliasPath _ authority key) act =
    mkShippedOwnership authority key aliasPath act

{- | Recovery when a shipped response is classified as an alias failure.

Only the owning frame's decoded malformed-input refusal is permanent.
Transport uncertainty, unreadable answers and inapplicable outcomes require a
fresh observation before retry.
-}
shippedAliasFailureRecovery :: Either ShippedFailure ShippedOutcome -> RecoveryDisposition
shippedAliasFailureRecovery (Left (ShippedFrameRefused (OwnershipMalformed _))) = DoNotRetry
shippedAliasFailureRecovery _ = ReprobeBeforeRetry

shippedAliasObservation ::
    GuestAliasSpec ->
    Either ShippedFailure ShippedOutcome ->
    AliasCallObservation
shippedAliasObservation spec result = case result of
    Right (ShippedSymbolicLinkCreated _) -> AliasCallCreated
    Right (ShippedSymbolicLinkRetained _) -> AliasCallAlreadyExact
    Left (ShippedFrameRefused (OwnershipOccupied reason)) ->
        AliasCallForeign
            (ForeignObservation (Text.pack (guestAliasPath spec)) reason)
    Left (ShippedFrameRefused (OwnershipConflict report)) -> AliasCallConflict (ownershipConflictDetail spec report)
    Left (ShippedFrameRefused (OwnershipUnsupported reason)) ->
        AliasCallUnsupported (UnsupportedDetail "reconcile provider guest durable alias" reason)
    Left (ShippedFrameRefused (OwnershipProbeFailed operation reason)) ->
        failed operation reason
    Left (ShippedFrameRefused (OwnershipMalformed reason)) ->
        failed "read provider guest alias ownership" reason
    Left (ShippedCrossingFailed reason) ->
        failed "cross into provider guest alias frame" reason
    Left (ShippedOutcomeUndecodable reason) ->
        failed "decode provider guest alias ownership" reason
    Right other ->
        failed
            "reconcile provider guest durable alias"
            ("the shipped ownership row returned an inapplicable outcome: " <> Text.pack (show other))
  where
    failed operation reason =
        AliasCallFailed (FailureDetail operation reason (shippedAliasFailureRecovery result))

shippedAliasRelease ::
    GuestAliasSpec ->
    Either ShippedFailure ShippedOutcome ->
    Either ReconcileError ()
shippedAliasRelease spec result = case result of
    Right ShippedObjectGivenBack -> Right ()
    Left (ShippedFrameRefused (OwnershipConflict report)) ->
        Left (Conflict (ownershipConflictDetail spec report))
    Left (ShippedFrameRefused (OwnershipOccupied reason)) ->
        Left
            ( Conflict
                (ConflictDetail "provider guest alias" "an absent or managed alias" reason "remove the foreign occupant before retrying")
            )
    Left (ShippedFrameRefused (OwnershipUnsupported reason)) ->
        Left (Unsupported (UnsupportedDetail "release provider guest durable alias" reason))
    Left (ShippedFrameRefused (OwnershipProbeFailed operation reason)) ->
        failed operation reason
    Left (ShippedFrameRefused (OwnershipMalformed reason)) ->
        failed "read provider guest alias ownership" reason
    Left (ShippedCrossingFailed reason) ->
        failed "cross into provider guest alias frame" reason
    Left (ShippedOutcomeUndecodable reason) ->
        failed "decode provider guest alias ownership" reason
    Right other ->
        failed
            "release provider guest durable alias"
            ("the shipped ownership row returned an inapplicable outcome: " <> Text.pack (show other))
  where
    failed operation reason =
        Left (Failure (FailureDetail operation reason (shippedAliasFailureRecovery result)))

ownershipConflictDetail :: GuestAliasSpec -> ConflictReport -> ConflictDetail
ownershipConflictDetail spec report =
    ConflictDetail
        (Text.pack (guestAliasPath spec))
        ("identity=" <> renderOrigin (Ownership.conflictExpected report))
        ("identity=" <> renderOrigin (Ownership.conflictObserved report))
        ("restore the managed symbolic link before retrying (" <> Ownership.conflictSubject report <> ")")
  where
    renderOrigin OriginAbsent = "absent"
    renderOrigin (OriginPresent identity) = Text.pack (show identity)

digestText :: Text -> Text
digestText value =
    Text.pack
        ( concatMap
            hexByte
            (ByteArray.unpack (Hash.hashWith Hash.SHA256 (TextEncoding.encodeUtf8 value)))
        )
  where
    hexByte byte = [hexDigit (byte `shiftR` 4), hexDigit (byte .&. 0x0f)]
    hexDigit nibble = ByteStringChar8.index "0123456789abcdef" (fromIntegral nibble)

data PreparedGuestAliasRelease scope planId providerId backendId capabilityId aliasId shareId phase releaseId
    = PreparedGuestAliasRelease
        GuestAliasSpec
        (ResourceHandle scope planId aliasId DurableAliasResource Managed phase)
        (OwnershipReceipt scope planId aliasId DurableAliasResource)
        Word64

type role PreparedGuestAliasRelease nominal nominal nominal nominal nominal nominal nominal nominal nominal

{- | Prepare conditional deletion.  A foreign/unmanaged handle does not type
check here, and the receipt must match the exact managed generation and
observation version. The retained alias/target specification selects the shared
origin record; the guest transaction rechecks its recorded link identity before
conditional release.
-}
withPreparedGuestAliasRelease ::
    ManagedGuestAliasHandle
        scope
        planId
        providerId
        backendId
        capabilityId
        aliasId
        shareId
        phase ->
    Word64 ->
    ( forall releaseId.
      PreparedGuestAliasRelease scope planId providerId backendId capabilityId aliasId shareId phase releaseId ->
      result
    ) ->
    Either ReconcileError result
withPreparedGuestAliasRelease
    (ManagedGuestAliasHandle spec handle receipt)
    conditionalVersion
    consume
        | conditionalVersion == 0 =
            Left
                ( Failure
                    (FailureDetail "prepare guest alias release" "conditional version must be positive" DoNotRetry)
                )
        | conditionalVersion /= resourceHandleObservationVersion handle =
            Left
                ( Conflict
                    ( ConflictDetail
                        (resourceHandleKey handle)
                        ("observation-version=" <> showText (resourceHandleObservationVersion handle))
                        ("conditional-version=" <> showText conditionalVersion)
                        "reobserve the managed alias and prepare release with its exact observation version"
                    )
                )
        | otherwise = do
            validateOwnershipReceipt handle receipt
            Right
                ( consume
                    (PreparedGuestAliasRelease spec handle receipt conditionalVersion)
                )

{- | Conditional release (clause 4): ship the release act back to the exact
guest frame, where the binary re-observes the alias's kernel identity under the
same protected-store entry and unlinks only the binding in the shared origin
record. Any other observation is a structured 'Conflict' and is left untouched.
-}
runPreparedGuestAliasRelease ::
    StrongAliasBackend scope planId providerId backendId capabilityId ->
    PreparedGuestAliasRelease scope planId providerId backendId capabilityId aliasId shareId phase releaseId ->
    IO (Either ReconcileError ())
runPreparedGuestAliasRelease
    (StrongAliasBackend _ config self context)
    (PreparedGuestAliasRelease spec _handle _ _conditionalVersion) = do
        result <- shipOwnedTransaction config self context (guestAliasOwnershipTransaction spec (ShipGiveBackSymbolicLink (guestAliasLinkTarget spec)))
        pure (shippedAliasRelease spec result)

-- ---------------------------------------------------------------------------
-- The node's route

{- | What one node's alias reconcile settled to.

A managed settlement carries the change the backend observed; a foreign one
carries what was found instead.  Neither leaks the handle or receipt: releasing
the alias is the reverse projection's, and a handle that escaped the settlement
would be ownership a later caller never proved.
-}
data GuestAliasSettlement
    = GuestAliasReconciled ChangeView
    | GuestAliasForeignRetained ForeignObservation
    deriving (Eq, Show)

{- | Reconcile the guest alias from the durable-share node that claims it.

The caller supplies the planned provider and share with their exact managed
handles. This route compares their resource keys, derives the alias projection
from the node descriptor, and takes its interpreter-opened gate once.
'withPreparedGuestAliasCall' checks provider generation, provider/share origin
and alias plan agreement, then runs the fresh share probe while sealing the
preconditions. No retained observation substitutes for that probe.

The node returns a descriptive managed change or foreign observation. It passes
no prior commit proof, so a retained recorded link settles Repaired.
-}
reconcileNodeGuestAlias ::
    StepExecution scope planId ->
    StrongAliasBackend scope planId providerId backendId capabilityId ->
    PlannedResource scope planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    PlannedResource scope planId shareId DurableShareResource shareFrame ->
    ManagedProviderShareHandle scope planId backendId providerId shareId Provisioned ->
    GuestAliasSpec ->
    -- | the alias's plan-assigned generation and observation version
    (Word64, Word64) ->
    -- | the exact backend-minted share dependency, reobserved at prepare time
    ProviderShareDependency scope planId shareId ->
    IO (Either ReconcileError GuestAliasSettlement)
reconcileNodeGuestAlias
    execution
    backend
    plannedProvider
    managedProvider@(ManagedProviderHandle _ providerHandle _)
    plannedShare
    managedShare@(ManagedProviderShareHandle shareOrigin shareHandle shareReceipt shareCall)
    spec
    (generation, observationVersion)
    shareDependency =
        if plannedResourceKey plannedProvider /= resourceHandleKey providerHandle
            then
                pure
                    ( Left
                        ( Conflict
                            ( ConflictDetail
                                (resourceHandleKey providerHandle)
                                (plannedResourceKey plannedProvider)
                                (resourceHandleKey providerHandle)
                                "use the running provider authority for this exact planned provider"
                            )
                        )
                    )
            else
                if plannedResourceKey plannedShare /= resourceHandleKey shareHandle
                    then
                        pure
                            ( Left
                                ( Conflict
                                    ( ConflictDetail
                                        (resourceHandleKey shareHandle)
                                        (plannedResourceKey plannedShare)
                                        (resourceHandleKey shareHandle)
                                        "use the provider-derived share authority for this exact planned share"
                                    )
                                )
                            )
                    else if not matchingShareDependency
                        then pure (Left (Conflict (ConflictDetail (resourceHandleKey shareHandle)
                            "the exact local provider share dependency"
                            "a carried or different share dependency"
                            "use the dependency minted from this managed share")))
                    else joinAliasIO $
                        withNodeGuestAliasProjection execution plannedProvider plannedShare $ \alias edge ->
                            aliasCall alias edge
      where
        matchingShareDependency = withLocalProviderShareDependency shareDependency matches == Just True
        matches (ManagedProviderShareHandle origin handle receipt callDigest) =
            providerOriginOwner origin == providerOriginOwner shareOrigin
                && providerBackendSemanticFingerprint (providerOriginBackendBinding origin)
                    == providerBackendSemanticFingerprint (providerOriginBackendBinding shareOrigin)
                && providerBackendRealizationFingerprint (providerOriginBackendBinding origin)
                    == providerBackendRealizationFingerprint (providerOriginBackendBinding shareOrigin)
                && resourceHandleKey handle == resourceHandleKey shareHandle
                && resourceHandleGeneration handle == resourceHandleGeneration shareHandle
                && resourceHandleObservationVersion handle == resourceHandleObservationVersion shareHandle
                && ownershipReceiptOperationKey receipt == ownershipReceiptOperationKey shareReceipt
                && callDigest == shareCall

        aliasCall alias edge = do
            taken <- stepExecutionTakeProjectedGate execution (plannedResourceKey alias)
            case taken of
                Nothing ->
                    pure
                        ( Left
                            ( Conflict
                                ( ConflictDetail
                                    (plannedResourceKey alias)
                                    "an open gate for this node's declared projection"
                                    "no gate is available for it"
                                    "declare the projection on this step and take its gate once"
                                )
                            )
                        )
                Just gate ->
                    joinAliasIO $
                        withNodeObservedResource execution alias generation observationVersion $
                            \aliasHandle -> do
                                prepared <-
                                    withPreparedGuestAliasCall
                                        backend
                                        managedProvider
                                        managedShare
                                        alias
                                        edge
                                        aliasHandle
                                        (providerShareDependencyProbe shareDependency)
                                        spec
                                        gate
                                        (runAndSettle backend)
                                case prepared of
                                    Left err -> pure (Left err)
                                    Right run -> run

        runAndSettle strong call = do
            observed <- runPreparedGuestAliasCall strong call
            pure $ case settlePreparedGuestAliasCall Nothing call observed of
                Left err -> Left err
                Right settled ->
                    Right
                        ( withGuestAliasCallSettlement
                            settled
                            (\_ change -> GuestAliasReconciled change)
                            (\_ _ _ foreignState -> GuestAliasForeignRetained foreignState)
                        )

joinAliasIO ::
    Either ReconcileError (IO (Either ReconcileError value)) ->
    IO (Either ReconcileError value)
joinAliasIO = either (pure . Left) id
