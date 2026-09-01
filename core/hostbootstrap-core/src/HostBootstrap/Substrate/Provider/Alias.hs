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
    guestAliasOwnershipTransaction,
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
    ShippedOwnership (..),
    shipOwnedTransaction,
 )
import HostBootstrap.Protected (mkRecordKey, protectedErrorMessage)
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
    dependencyProbe,
    emptyDependencySnapshot,
    plannedGuestAliasOperation,
    plannedResourceKey,
    plannedResourcePlanDigest,
    resourceHandleGeneration,
    resourceHandleKey,
    resourceHandleObservationVersion,
    validateOwnershipReceipt,
    withDependencySnapshotEntry,
    withNodeGuestAliasProjection,
    withNodeObservedResource,
    withOperationPreconditions,
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
import HostBootstrap.Substrate.Provider.Observation.Internal (
    ManagedProviderHandle (..),
    ManagedProviderShareHandle (..),
    ProviderOriginBinding (..),
    providerBackendRealizationFingerprint,
    providerBackendSemanticFingerprint,
    providerOriginOwner,
 )
import qualified System.FilePath.Posix as Posix

data GuestAliasSpec = GuestAliasSpec FilePath FilePath
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
    | otherwise = Right (GuestAliasSpec aliasPath target)
  where
    invalid reason =
        Left
            ( Failure
                (FailureDetail "validate provider guest alias" reason DoNotRetry)
            )

guestAliasPath :: GuestAliasSpec -> FilePath
guestAliasPath (GuestAliasSpec aliasPath _) = aliasPath

guestAliasTarget :: GuestAliasSpec -> FilePath
guestAliasTarget (GuestAliasSpec _ target) = target

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
        Text
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
    DependencyProbe scope planId shareId DurableShareResource ->
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
    managedShare@(ManagedProviderShareHandle shareOrigin shareHandle shareReceipt)
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
                        Right descriptor -> do
                            sealed <-
                                withOperationPreconditions
                                    descriptor
                                    ( withDependencySnapshotEntry
                                        shareHandle
                                        shareProbe
                                        emptyDependencySnapshot
                                    )
                            pure $ do
                                preconditionSet <- sealed
                                withPreparedOperation
                                    descriptor
                                    preconditionSet
                                    gate
                                    ( \prepared preconditions ->
                                        consume
                                            ( PreparedGuestAliasCall
                                                spec
                                                (aliasOwnerBinding providerOrigin shareHandle planned spec aliasHandle)
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
prepared operation.  A compatible link without prior commit proof is explicitly
foreign.
-}
data AliasCallObservation
    = AliasCallCreated Word64
    | AliasCallRepaired Word64
    | AliasCallAlreadyExact Word64
    | AliasCallForeign Word64 ForeignObservation
    | AliasCallConflict ConflictDetail
    | AliasCallUnsupported UnsupportedDetail
    | AliasCallFailed FailureDetail
    deriving (Eq, Show)

-- | Indexed proof that the strong backend ran this exact prepared call.
newtype AliasCallResult scope planId providerId backendId capabilityId aliasId shareId operationKey callDigest attempt journalVersion
    = AliasCallResult AliasCallObservation

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
aliasCallResultView (AliasCallResult observation) = case observation of
    AliasCallCreated generation -> AliasResultCreated generation
    AliasCallRepaired generation -> AliasResultRepaired generation
    AliasCallAlreadyExact generation -> AliasResultAlreadyExact generation
    AliasCallForeign generation foreignState -> AliasResultForeign generation foreignState
    AliasCallConflict detail -> AliasResultConflict detail
    AliasCallUnsupported detail -> AliasResultUnsupported detail
    AliasCallFailed detail -> AliasResultFailed detail

{- | Opaque managed alias authority retained after exact settlement.

The indices bind provider, backend, discovered capability, alias, and durable
share.  The constructor additionally retains the exact spec/owner plus the
generic managed handle and receipt, but none of those authorizing values is
projected publicly.
-}
data ManagedGuestAliasHandle scope planId providerId backendId capabilityId aliasId shareId phase
    = ManagedGuestAliasHandle
        GuestAliasSpec
        Text
        (ResourceHandle scope planId aliasId DurableAliasResource Managed phase)
        (OwnershipReceipt scope planId aliasId DurableAliasResource)

type role ManagedGuestAliasHandle nominal nominal nominal nominal nominal nominal nominal nominal

managedGuestAliasKey ::
    ManagedGuestAliasHandle scope planId providerId backendId capabilityId aliasId shareId phase ->
    Text
managedGuestAliasKey (ManagedGuestAliasHandle _ _ handle _) = resourceHandleKey handle

managedGuestAliasGeneration ::
    ManagedGuestAliasHandle scope planId providerId backendId capabilityId aliasId shareId phase ->
    Word64
managedGuestAliasGeneration (ManagedGuestAliasHandle _ _ handle _) = resourceHandleGeneration handle

managedGuestAliasObservationVersion ::
    ManagedGuestAliasHandle scope planId providerId backendId capabilityId aliasId shareId phase ->
    Word64
managedGuestAliasObservationVersion (ManagedGuestAliasHandle _ _ handle _) =
    resourceHandleObservationVersion handle

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
    (PreparedGuestAliasCall spec owner _ _ handle prepared preconditions)
    (AliasCallResult observation) = do
        reconciled <- case observation of
            AliasCallCreated generation ->
                completeReconcile handle prepared preconditions (BackendCreated generation)
            AliasCallRepaired generation ->
                completeReconcile handle prepared preconditions (BackendRepaired generation)
            AliasCallAlreadyExact generation
                | generation /= resourceHandleGeneration handle ->
                    Left
                        ( Conflict
                            ( ConflictDetail
                                (resourceHandleKey handle)
                                ("generation=" <> showText (resourceHandleGeneration handle))
                                ("generation=" <> showText generation)
                                "reprobe the alias before classifying the exact link"
                            )
                        )
                | Just proof <- priorProof ->
                    completePreparedUnchanged handle prepared preconditions proof
                | otherwise ->
                    completeReconcile
                        handle
                        prepared
                        preconditions
                        (BackendRepaired generation)
            AliasCallForeign generation foreignState ->
                completeReconcile
                    handle
                    prepared
                    preconditions
                    (BackendForeign generation foreignState)
            AliasCallConflict detail -> Left (Conflict detail)
            AliasCallUnsupported detail -> Left (Unsupported detail)
            AliasCallFailed detail -> Left (Failure detail)
        guestAliasSettlement spec owner reconciled

guestAliasSettlement ::
    GuestAliasSpec ->
    Text ->
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
guestAliasSettlement spec owner reconciled =
    withReconcileResult
        reconciled
        ( \handle receipt change -> do
            validateOwnershipReceipt handle receipt
            Right
                ( ManagedGuestAlias
                    (ManagedGuestAliasHandle spec owner handle receipt)
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
            _ <- requireObservation "provider permissions" (discoveryPermissions guest)
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

{- | Reconcile one prepared alias under the retained guest lock.

The durable record is keyed by a digest of the exact plan resource,
plan-assigned generation, alias, and target.  Its first no-replace publication
adds a fresh nonce.  A staging symlink named by that nonce is then hard-linked
to the final name without replacement; both names have the same measured
@device:inode@.  If the process dies before the managed record is published, a
retry can therefore distinguish its staging inode from an exact-looking foreign
link and finish the same generation rather than adopting by pathname.
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
    (PreparedGuestAliasCall spec _owner _ _ handle _ _) = do
        result <- shipOwnedTransaction config self context (guestAliasOwnershipTransaction spec (ShipTakeSymbolicLink (guestAliasTarget spec)))
        pure
            ( AliasCallResult
                (shippedAliasObservation spec (resourceHandleGeneration handle) result)
            )

{- | Exact persisted owner binding.  Length framing keeps this injective before
hashing and the complete binding is also stored in the record, so even a digest
collision is refused on readback rather than aliasing two owners.
-}
aliasOwnerBinding ::
    ProviderOriginBinding scope planId backendId providerId ->
    ResourceHandle scope planId shareId DurableShareResource Managed Provisioned ->
    PlannedResource scope planId aliasId DurableAliasResource aliasFrame ->
    GuestAliasSpec ->
    ResourceHandle scope planId aliasId DurableAliasResource ownership phase ->
    Text
aliasOwnerBinding origin share planned spec handle =
    Text.concat
        [ sizedText "hostbootstrap/guest-alias-origin/v2"
        , sizedText (providerOriginOwner origin)
        , sizedText (resourceHandleKey share)
        , sizedText (showText (resourceHandleGeneration share))
        , sizedText (plannedResourcePlanDigest planned)
        , sizedText (resourceHandleKey handle)
        , sizedText (showText (resourceHandleGeneration handle))
        , sizedText (Text.pack (guestAliasPath spec))
        , sizedText (Text.pack (guestAliasTarget spec))
        ]
  where
    sizedText value = showText (Text.length value) <> ":" <> value

-- | Bounded, collision-resistant filename under the durable target share.
aliasRecordName :: GuestAliasSpec -> Text
aliasRecordName spec =
    "guest-alias."
        <> digestText (Text.pack (guestAliasPath spec) <> "\0" <> Text.pack (guestAliasTarget spec))
        <> ".record"

guestAliasOwnershipTransaction :: GuestAliasSpec -> ShippedAct -> ShippedOwnership
guestAliasOwnershipTransaction spec act =
    ShippedOwnership
        { shippedAuthority = guestAliasTarget spec Posix.</> ".hostbootstrap-alias-authority-v1"
        , shippedRecord =
            either
                (error . Text.unpack . protectedErrorMessage)
                id
                (mkRecordKey (aliasRecordName spec))
        , shippedTarget = guestAliasPath spec
        , shippedAct = act
        }

shippedAliasObservation ::
    GuestAliasSpec ->
    Word64 ->
    Either OwnershipFault ShippedOutcome ->
    AliasCallObservation
shippedAliasObservation spec generation result = case result of
    Right (ShippedSymbolicLinkCreated _) -> AliasCallCreated generation
    Right (ShippedSymbolicLinkRetained _) -> AliasCallAlreadyExact generation
    Left (OwnershipOccupied reason) ->
        AliasCallForeign
            generation
            (ForeignObservation (Text.pack (guestAliasPath spec)) reason)
    Left (OwnershipConflict report) -> AliasCallConflict (ownershipConflictDetail spec report)
    Left (OwnershipUnsupported reason) ->
        AliasCallUnsupported (UnsupportedDetail "reconcile provider guest durable alias" reason)
    Left (OwnershipProbeFailed operation reason) ->
        AliasCallFailed
            (FailureDetail operation reason ReprobeBeforeRetry)
    Left (OwnershipMalformed reason) ->
        AliasCallFailed
            (FailureDetail "read provider guest alias ownership" reason DoNotRetry)
    Right other ->
        AliasCallFailed
            ( FailureDetail
                "reconcile provider guest durable alias"
                ("the shipped ownership row returned an inapplicable outcome: " <> Text.pack (show other))
                DoNotRetry
            )

shippedAliasRelease ::
    GuestAliasSpec ->
    Either OwnershipFault ShippedOutcome ->
    Either ReconcileError ()
shippedAliasRelease _spec (Right ShippedObjectGivenBack) = Right ()
shippedAliasRelease spec (Left (OwnershipConflict report)) =
    Left (Conflict (ownershipConflictDetail spec report))
shippedAliasRelease _spec (Left (OwnershipOccupied reason)) =
    Left
        ( Conflict
            (ConflictDetail "provider guest alias" "an absent or managed alias" reason "remove the foreign occupant before retrying")
        )
shippedAliasRelease _spec (Left (OwnershipUnsupported reason)) =
    Left (Unsupported (UnsupportedDetail "release provider guest durable alias" reason))
shippedAliasRelease _spec (Left (OwnershipProbeFailed operation reason)) =
    Left (Failure (FailureDetail operation reason ReprobeBeforeRetry))
shippedAliasRelease _spec (Left (OwnershipMalformed reason)) =
    Left (Failure (FailureDetail "read provider guest alias ownership" reason DoNotRetry))
shippedAliasRelease _spec (Right other) =
    Left
        ( Failure
            ( FailureDetail
                "release provider guest durable alias"
                ("the shipped ownership row returned an inapplicable outcome: " <> Text.pack (show other))
                DoNotRetry
            )
        )

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
        Text
        (ResourceHandle scope planId aliasId DurableAliasResource Managed phase)
        (OwnershipReceipt scope planId aliasId DurableAliasResource)
        Word64

type role PreparedGuestAliasRelease nominal nominal nominal nominal nominal nominal nominal nominal nominal

{- | Prepare conditional deletion.  A foreign/unmanaged handle does not type
check here, and the receipt must match the exact managed generation.  The
prepared reconcile call supplies the same plan-digest-bound owner text that was
used to publish the origin; release never reconstructs ownership from only a
pathname and generation.
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
    (ManagedGuestAliasHandle spec owner handle receipt)
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
                    (PreparedGuestAliasRelease spec owner handle receipt conditionalVersion)
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
    (PreparedGuestAliasRelease spec _owner _handle _ _conditionalVersion) = do
        result <- shipOwnedTransaction config self context (guestAliasOwnershipTransaction spec (ShipGiveBackSymbolicLink (guestAliasTarget spec)))
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

{- | Reconcile the guest alias from inside the step action that __claims__ it.

This is the production route, and it exists because every input it needs is now
on the node's own descriptor rather than in a plan the action cannot see:

* the provider and durable share are resolved out of this node's plan prefix and
  its own resource ('withNodeResourceOfKind'), so the relation is derived from
  what the plan ordered rather than from keys the call site spelled;
* the alias identity is the node's own declared projection
  ('withNodeGuestAliasProjection'), and its gate is the one the interpreter
  opened for exactly that projection — taken once, so one prepared call
  authorises one effect;
* the exact running provider handle is indexed with the retained strong backend,
  while the durable share's __managed__ handle is the one the acquiring node
  carried in process ('withCarriedManagedResource').  The plan-owned traversal
  runs @shareProbe@ at prepare time rather than trusting an observation taken
  earlier in the bring-up.

The step that calls this is the durable-share node: validation requires the
declaring node to be the last resource the projected key names, and the provider
is already behind it in the plan.
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
    -- | the durable share's readiness probe, run by the traversal at prepare time
    IO (Either ReconcileError Word64) ->
    IO (Either ReconcileError GuestAliasSettlement)
reconcileNodeGuestAlias
    execution
    backend
    plannedProvider
    managedProvider@(ManagedProviderHandle _ providerHandle _)
    plannedShare
    managedShare@(ManagedProviderShareHandle _ shareHandle _)
    spec
    (generation, observationVersion)
    shareProbe =
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
                    else joinAliasIO $
                        withNodeGuestAliasProjection execution plannedProvider plannedShare $ \alias edge ->
                            aliasCall alias edge
      where
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
                                        (dependencyProbe shareProbe)
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
