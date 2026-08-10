{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Portable, plan-indexed reconciliation for a provider-guest durable alias.

The preparation and settlement algebra is pure; the backend that observes and
mutates the guest comes only from a provider-bound retained capability, so it
runs against the exact managed guest generation that discovery proved.

The backend holds the four Locked-Origin Identity Ownership clauses of
@development_plan_standards.md § EE@ with the guest realization from
@documents/architecture/ownership_invariant.md@.  One retained guest lock spans
origin publication, observation, mutation, identity binding, and readback.  The
origin record lives inside the mounted durable target, so it is host-backed
rather than a guest-local pathname sidecar.  A narrow Python helper publishes
that record create-if-absent, flushes the file and parent directory, reads it
back exactly, and atomically replaces it when the managed symlink identity has
been measured.  Alias publication itself is an atomic no-replace hard link from
a nonce-named staging symlink.  This makes a crash before identity binding
recoverable without adopting a merely exact-looking pathname.

The alias object's identity is its symlink's own @(device, inode)@ pair, read
with the exact @stat@ dialect retained by provider discovery.  Conditional
release re-observes that identity and unlinks only on an exact match, under the
same retained lock front end.  This excludes crash/retry and cooperating races
and /detects/ foreign mutation; it does not exclude a hostile same-privilege
process, and no substrate supplies that exclusion.  A provider capability that
did not retain a guest lock, stat dialect, and Python 3 is 'Unsupported' and
mints no alias backend.
-}
module HostBootstrap.Substrate.Provider.Alias (
    GuestAliasSpec,
    mkGuestAliasSpec,
    guestAliasPath,
    guestAliasTarget,
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
import Data.Bits ((.&.), shiftR, xor)
import qualified Data.ByteArray as ByteArray
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Lifecycle.Execution (
    StepExecution,
    stepExecutionTakeProjectedGate,
 )
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
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
    Provisioned,
    ProviderResource,
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
    plannedResourcePlanDigest,
    plannedResourceKey,
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
    GuestLockPrimitive (..),
    GuestProviderDiscovery (..),
    GuestPythonCapability (..),
    GuestStatDialect (..),
    ProviderCapability,
    ProviderDiscovery (..),
    ProviderObservation (..),
    providerCapabilityDiscovery,
    providerCapabilityGeneration,
    providerCapabilityGuestExecutor,
 )
import HostBootstrap.Substrate.Provider.Internal (
    ProviderGuestExecutor,
    RawProviderOutcome (..),
    runProviderGuestExecutor,
 )
import HostBootstrap.Substrate.Provider.Observation.Internal (
    ManagedProviderHandle (..),
    ManagedProviderShareHandle (..),
    ProviderOriginBinding (..),
    providerBackendRealizationFingerprint,
    providerBackendSemanticFingerprint,
    providerOriginOwner,
 )
import System.Exit (ExitCode (ExitSuccess))

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
                case
                    plannedGuestAliasOperation
                        planned
                        edge
                        aliasHandle
                        (aliasCallDigest providerOrigin shareHandle spec)
                of
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
data ManagedGuestAliasHandle scope planId providerId backendId capabilityId aliasId shareId phase =
    ManagedGuestAliasHandle
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

{- | The captured outcome of one guest command.  @guestCommandOk@ is the
exit-zero verdict; the streams carry the parseable backend report and any
diagnostic.
-}
data GuestCommandResult = GuestCommandResult
    { guestCommandOk :: Bool
    , guestCommandStdout :: String
    , guestCommandStderr :: String
    , guestCommandProviderConflict :: Maybe (String, String, String)
    }
    deriving (Eq, Show)

guestCommandResult :: RawProviderOutcome -> GuestCommandResult
guestCommandResult outcome = case outcome of
    RawProviderExit code out err -> GuestCommandResult (code == ExitSuccess) out err Nothing
    RawProviderFailure reason ->
        GuestCommandResult
            False
            ""
            reason
            (providerConflictMarker reason)

providerConflictMarker :: String -> Maybe (String, String, String)
providerConflictMarker raw = case words raw of
    ["HB_PROVIDER_CONFLICT", expected, observed, reason]
        | unwords ["HB_PROVIDER_CONFLICT", expected, observed, reason] == raw
        , all validConflictToken [expected, observed, reason] ->
            Just (expected, observed, reason)
    _ -> Nothing

validConflictToken :: String -> Bool
validConflictToken value =
    not (null value)
        && length value <= 240
        && all
            (\character ->
                (character >= 'A' && character <= 'Z')
                    || (character >= 'a' && character <= 'z')
                    || (character >= '0' && character <= '9')
                    || character `elem` (":._/=-" :: String)
            )
            value

{- | The one admitted guest lock namespace: util-linux @flock(1)@ backed by
@flock(2)@.  A discovered @lockf(1)@ is descriptive only; on Linux it commonly
uses fcntl locks and therefore does not mutually exclude this protocol.  Alias
authority refuses it rather than realizing two lock namespaces over one
origin.
-}
newtype ExclusionTool = Flock FilePath
    deriving (Eq, Show)

{- | How the guest's @stat@ reports an object's @device:inode@ identity.  GNU
coreutils uses @-c FORMAT@, the BSD userland uses @-f FORMAT@; neither follows
a symlink by default, which is what clause 3 requires — the identity bound is
the link's own, not its target's.
-}
data StatFlavor = GnuStat FilePath | BsdStat FilePath
    deriving (Eq, Show)

-- | The exact ownership front ends retained by provider discovery.
data GuestOwnershipTools = GuestOwnershipTools ExclusionTool StatFlavor FilePath
    deriving (Eq, Show)

{- | Capability for a backend that holds the four Locked-Origin Identity
Ownership clauses for a provider-guest durable alias.  Its constructor is
private: it is minted only by 'discoverStrongAliasBackend' after that verifies
the guest exposes the POSIX ownership tools.  It retains the exact front ends
that probe observed, so no bracket can be built from a tool the guest was never
shown to have.
-}
data StrongAliasBackend scope planId providerId backendId capabilityId
    = StrongAliasBackend
        Word64
        (ProviderGuestExecutor scope planId providerId Running backendId capabilityId)
        GuestOwnershipTools

type role StrongAliasBackend nominal nominal nominal nominal nominal

strongAliasProviderGeneration :: StrongAliasBackend scope planId providerId backendId capabilityId -> Word64
strongAliasProviderGeneration (StrongAliasBackend generation _ _) = generation

{- | Narrow one opaque provider capability to the alias backend.

Discovery has already run at the provider boundary.  This function performs no
second probe and accepts no descriptive tool names: it consumes the exact lock,
@stat@, Python, and provider-bound guest executor retained by
'ProviderCapability'.  Failed discovery observations remain descriptive and
prevent this narrower capability from being minted.
-}
discoverStrongAliasBackend ::
    ProviderCapability scope planId providerId backendId capabilityId ->
    Either ReconcileError (StrongAliasBackend scope planId providerId backendId capabilityId)
discoverStrongAliasBackend capability = do
    tools <- retainedOwnershipTools (providerCapabilityDiscovery capability)
    executor <- mapProviderFailure (providerCapabilityGuestExecutor capability)
    Right (StrongAliasBackend (providerCapabilityGeneration capability) executor tools)
  where
    mapProviderFailure result = case result of
        Right value -> Right value
        Left failure ->
            Left
                ( Unsupported
                    ( UnsupportedDetail
                        "reconcile provider guest durable alias"
                        (Text.pack (show failure))
                    )
                )

retainedOwnershipTools :: ProviderDiscovery -> Either ReconcileError GuestOwnershipTools
retainedOwnershipTools discovery = case discovery of
    ProviderDirectDiscovery _ -> unavailable "the direct host has no guest ownership protocol"
    ProviderGuestDiscovery guest -> do
        _ <- requireObservation "provider daemon" (discoveryDaemon guest)
        _ <- requireObservation "provider permissions" (discoveryPermissions guest)
        _ <- requireObservation "provider VM capability" (discoveryVmCapability guest)
        requireNonTerminalEgress (discoveryEgress guest)
        retainedLock <- requireObservation "guest lock frontend" (discoveryGuestLock guest)
        retainedStat <- requireObservation "guest stat dialect" (discoveryGuestStat guest)
        retainedPython <- requireObservation "guest Python 3" (discoveryGuestPython guest)
        lock <- case retainedLock of
            GuestFlock executable -> Right (Flock executable)
            GuestLockf _ -> unavailable "guest lockf is a different lock namespace from the required flock protocol"
        let statFlavor = case retainedStat of
                GuestGnuStat executable -> GnuStat executable
                GuestBsdStat executable -> BsdStat executable
            pythonExecutable = case retainedPython of
                GuestPython3 executable -> executable
        Right (GuestOwnershipTools lock statFlavor pythonExecutable)
  where
    unavailable reason =
        Left
            ( Unsupported
                ( UnsupportedDetail
                    "reconcile provider guest durable alias"
                    ( "the retained provider capability cannot hold the alias ownership protocol: "
                        <> reason
                    )
                )
            )

    -- Alias reconciliation operates in an already-running managed guest and
    -- therefore does not require the provisioning endpoint to remain reachable.
    -- An unavailable/not-ready egress observation is descriptive here, while a
    -- retained conflict or parser/transport failure remains terminal.
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
    (StrongAliasBackend _ exec tools)
    (PreparedGuestAliasCall spec owner _ _ handle _ _) = do
        result <-
            runProviderGuestExecutor
                exec
                ( exclusiveWrapped
                    tools
                    spec
                    "reconcile"
                    owner
                    (resourceHandleGeneration handle)
                    0
                )
        pure
            ( AliasCallResult
                (parseReconcileReport spec (resourceHandleGeneration handle) (guestCommandResult result))
            )

{- | Wrap the ownership helper in the exact lock front end discovery retained.

@flock -x@ blocks until it holds the protocol's one lock namespace, passes the
remaining words to Python unchanged, returns Python's exit status, and leaves
the lock file in place.

The @stat@ dialect travels as positional arguments rather than being baked into
the helper.  There is no shell and no redirection in this mutation path.
-}
exclusiveWrapped :: GuestOwnershipTools -> GuestAliasSpec -> String -> Text -> Word64 -> Word64 -> [String]
exclusiveWrapped (GuestOwnershipTools lockTool statFlavor pythonExecutable) spec mode owner generation conditionalVersion =
    exclusionArgv lockTool (aliasLockPath spec)
        <> [ pythonExecutable
           , "-c"
           , aliasOwnershipProgram
           , mode
           , guestAliasPath spec
           , guestAliasTarget spec
           , Text.unpack (aliasRecordName owner)
           , Text.unpack owner
           , show generation
           , show conditionalVersion
           ]
        <> statArgv statFlavor

exclusionArgv :: ExclusionTool -> FilePath -> [String]
exclusionArgv (Flock executable) lock = [executable, "-x", lock]

-- | Exact retained @stat@ executable, identity-format flag, and format.
statArgv :: StatFlavor -> [String]
statArgv (GnuStat executable) = [executable, "-c", "%d:%i"]
statArgv (BsdStat executable) = [executable, "-f", "%d:%i"]

aliasLockPath :: GuestAliasSpec -> FilePath
aliasLockPath spec = guestAliasPath spec ++ ".hb-alias.lock"

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
aliasRecordName :: Text -> Text
aliasRecordName owner = "guest-alias." <> digestText owner <> ".json"

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

{- | The lock-held ownership driver.  Python is retained by provider discovery,
not guessed here.  Its filesystem calls provide the portable operations shell
redirection cannot: O_EXCL origin publication, full writes, file and directory
fsync, no-follow readback, atomic replacement, and hard-link no-replace alias
publication.  @stat@ remains an external call so the exact retained GNU/BSD
dialect is the authority for the symlink's stable identity.

The @HB_ALIAS_...@ checkpoint comments are inert in production and give the
test seam exact kill points without adding a runtime fault flag.
-}
aliasOwnershipProgram :: String
aliasOwnershipProgram =
    unlines
        [ "import errno"
        , "import json"
        , "import os"
        , "import re"
        , "import secrets"
        , "import stat"
        , "import subprocess"
        , "import sys"
        , "mode, alias_path, target, record_name, owner, generation, conditional_version, stat_executable, sflag, sfmt = sys.argv[1:]"
        , "state_name = '.hostbootstrap-alias-origin-v1'"
        , "identity_re = re.compile(r'[0-9]+:[0-9]+')"
        , "nonce_re = re.compile(r'[0-9a-f]{64}')"
        , "class Unsupported(Exception): pass"
        , "class Conflict(Exception):"
        , "    def __init__(self, expected, observed, reason):"
        , "        self.expected = expected; self.observed = observed; self.reason = reason"
        , "def token(value):"
        , "    return re.sub(r'[^A-Za-z0-9:._-]', '_', str(value))[:240] or 'unknown'"
        , "def emit(tag, *fields):"
        , "    print(' '.join([tag] + [token(field) for field in fields]), flush=True)"
        , "    raise SystemExit(0)"
        , "def fsync_dir(path):"
        , "    flags = os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0)"
        , "    fd = os.open(path, flags)"
        , "    try:"
        , "        try: os.fsync(fd)"
        , "        except OSError as failure:"
        , "            if failure.errno in (errno.EINVAL, getattr(errno, 'ENOTSUP', errno.EINVAL)): raise Unsupported('directory-fsync-unavailable')"
        , "            raise"
        , "    finally: os.close(fd)"
        , "def write_all(fd, payload):"
        , "    view = memoryview(payload)"
        , "    while view:"
        , "        count = os.write(fd, view)"
        , "        if count <= 0: raise OSError('short origin-record write')"
        , "        view = view[count:]"
        , "def read_bytes(path):"
        , "    if not hasattr(os, 'O_NOFOLLOW'): raise Unsupported('O_NOFOLLOW unavailable')"
        , "    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)"
        , "    try:"
        , "        if not stat.S_ISREG(os.fstat(fd).st_mode): raise Conflict('regular-origin-record', 'non-regular', 'record-kind')"
        , "        try: os.fsync(fd)"
        , "        except OSError as failure:"
        , "            if failure.errno in (errno.EINVAL, getattr(errno, 'ENOTSUP', errno.EINVAL)): raise Unsupported('record-fsync-unavailable')"
        , "            raise"
        , "        chunks = []; size = 0"
        , "        while size <= 65536:"
        , "            chunk = os.read(fd, min(65536, 65537 - size))"
        , "            if not chunk: break"
        , "            chunks.append(chunk); size += len(chunk)"
        , "        if size > 65536: raise Conflict('bounded-origin-record', 'oversized', 'record-size')"
        , "        return b''.join(chunks)"
        , "    finally: os.close(fd)"
        , "def record_payload(nonce, state_value, managed=None, fence=None):"
        , "    value = {'alias': alias_path, 'generation': generation, 'magic': 'hbao1', 'nonce': nonce, 'origin': 'absent', 'owner': owner, 'state': state_value, 'target': target}"
        , "    if managed is not None: value['managed'] = managed"
        , "    if fence is not None: value['conditional_version'] = fence"
        , "    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\\n').encode('utf-8')"
        , "def decode_record(raw):"
        , "    try: value = json.loads(raw.decode('utf-8'))"
        , "    except Exception: raise Conflict('well-formed-origin-record', 'malformed', 'record-codec')"
        , "    if not isinstance(value, dict): raise Conflict('origin-record-object', token(type(value).__name__), 'record-codec')"
        , "    for key, expected in [('alias', alias_path), ('generation', generation), ('magic', 'hbao1'), ('origin', 'absent'), ('owner', owner), ('target', target)]:"
        , "        if value.get(key) != expected: raise Conflict(token(expected), token(value.get(key)), 'record-' + key)"
        , "    nonce = value.get('nonce')"
        , "    if not isinstance(nonce, str) or not nonce_re.fullmatch(nonce): raise Conflict('fresh-nonce', token(nonce), 'record-nonce')"
        , "    state_value = value.get('state')"
        , "    if state_value == 'prepared' and set(value) == {'alias','generation','magic','nonce','origin','owner','state','target'}: return value"
        , "    if state_value == 'managed' and set(value) == {'alias','generation','magic','managed','nonce','origin','owner','state','target'} and isinstance(value.get('managed'), str) and identity_re.fullmatch(value['managed']): return value"
        , "    if state_value == 'releasing' and set(value) == {'alias','conditional_version','generation','magic','managed','nonce','origin','owner','state','target'} and isinstance(value.get('managed'), str) and identity_re.fullmatch(value['managed']) and isinstance(value.get('conditional_version'), str) and value['conditional_version'].isdigit() and int(value['conditional_version']) > 0: return value"
        , "    raise Conflict('prepared-managed-or-releasing-record', token(state_value), 'record-state')"
        , "def decode_exact_record(raw):"
        , "    value = decode_record(raw)"
        , "    expected = record_payload(value['nonce'], value['state'], value.get('managed'), value.get('conditional_version'))"
        , "    if raw != expected: raise Conflict('canonical-origin-record', 'different-bytes', 'record-readback')"
        , "    return value"
        , "def complete_partial(path, raw, payload, label):"
        , "    if not payload.startswith(raw): raise Conflict('exact-' + label, 'changed-bytes', label)"
        , "    if raw == payload: return"
        , "    if not hasattr(os, 'O_NOFOLLOW'): raise Unsupported('O_NOFOLLOW unavailable')"
        , "    fd = os.open(path, os.O_WRONLY | os.O_NOFOLLOW)"
        , "    try:"
        , "        if not stat.S_ISREG(os.fstat(fd).st_mode): raise Conflict('regular-' + label, 'non-regular', label)"
        , "        os.lseek(fd, len(raw), os.SEEK_SET); write_all(fd, payload[len(raw):]); os.fsync(fd)"
        , "    finally: os.close(fd)"
        , "    if read_bytes(path) != payload: raise Conflict('exact-' + label, 'different-bytes', label + '-readback')"
        , "def create_full(path, payload, label):"
        , "    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0)"
        , "    fd = os.open(path, flags, 0o600)"
        , "    try: write_all(fd, payload); os.fsync(fd)"
        , "    finally: os.close(fd)"
        , "    if read_bytes(path) != payload: raise Conflict('exact-' + label, 'different-bytes', label + '-readback')"
        , "def ensure_record_dir():"
        , "    info = os.lstat(target)"
        , "    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode): raise Unsupported('durable-target-is-not-a-real-directory')"
        , "    directory = os.path.join(target, state_name)"
        , "    try:"
        , "        os.mkdir(directory, 0o755)"
        , "    except FileExistsError:"
        , "        found = os.lstat(directory)"
        , "        if not stat.S_ISDIR(found.st_mode) or stat.S_ISLNK(found.st_mode): raise Unsupported('origin-record-directory-is-not-a-real-directory')"
        , "    fsync_dir(target); fsync_dir(directory)"
        , "    return directory"
        , "def prepared_stages(directory):"
        , "    prefix = record_name + '.prepared-'"
        , "    found = []"
        , "    for name in os.listdir(directory):"
        , "        if not name.startswith(prefix): continue"
        , "        nonce = name[len(prefix):]"
        , "        if not nonce_re.fullmatch(nonce): raise Conflict('owner-bound-prepared-stage', token(name), 'prepared-stage-name')"
        , "        path = os.path.join(directory, name); raw = read_bytes(path); payload = record_payload(nonce, 'prepared')"
        , "        if not payload.startswith(raw): raise Conflict('exact-prepared-stage', 'changed-bytes', 'prepared-stage')"
        , "        found.append((path, nonce, raw, payload))"
        , "    return found"
        , "def cleanup_prepared_stages(directory):"
        , "    changed = False"
        , "    for path, _, raw, payload in prepared_stages(directory):"
        , "        if not payload.startswith(raw): raise Conflict('exact-prepared-stage', 'changed-bytes', 'prepared-stage')"
        , "        os.unlink(path); changed = True"
        , "    if changed: fsync_dir(directory)"
        , "def prepare_record():"
        , "    directory = ensure_record_dir(); path = os.path.join(directory, record_name)"
        , "    if os.path.lexists(path):"
        , "        raw = read_bytes(path); record = decode_exact_record(raw); cleanup_prepared_stages(directory)"
        , "        return False, path, directory, record, raw"
        , "    stages = prepared_stages(directory); recovering = bool(stages)"
        , "    if len(stages) > 1: raise Conflict('one-prepared-stage', str(len(stages)), 'prepared-stage-count')"
        , "    if stages:"
        , "        stage, nonce, raw, payload = stages[0]; complete_partial(stage, raw, payload, 'prepared-stage')"
        , "    else:"
        , "        nonce = secrets.token_hex(32); stage = os.path.join(directory, record_name + '.prepared-' + nonce); payload = record_payload(nonce, 'prepared')"
        , "        create_full(stage, payload, 'prepared-stage')"
        , "    fsync_dir(directory)"
        , "    try:"
        , "        os.link(stage, path, follow_symlinks=False); fsync_dir(directory); created = True"
        , "    except FileExistsError:"
        , "        created = False"
        , "    final_raw = read_bytes(path); record = decode_exact_record(final_raw)"
        , "    if created and final_raw != payload: raise Conflict('exact-published-origin', 'different-bytes', 'record-publish-readback')"
        , "    stage_raw = read_bytes(stage)"
        , "    if stage_raw != payload: raise Conflict('exact-prepared-stage', 'changed-bytes', 'prepared-stage-readback')"
        , "    os.unlink(stage); fsync_dir(directory)"
        , "    cleanup_prepared_stages(directory)"
        , "    return created and not recovering, path, directory, record, final_raw"
        , "def existing_record():"
        , "    info = os.lstat(target)"
        , "    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode): raise Unsupported('durable-target-is-not-a-real-directory')"
        , "    directory = os.path.join(target, state_name)"
        , "    if not os.path.lexists(directory): return None"
        , "    found = os.lstat(directory)"
        , "    if not stat.S_ISDIR(found.st_mode) or stat.S_ISLNK(found.st_mode): raise Unsupported('origin-record-directory-is-not-a-real-directory')"
        , "    fsync_dir(target); fsync_dir(directory)"
        , "    path = os.path.join(directory, record_name)"
        , "    if not os.path.lexists(path):"
        , "        cleanup_prepared_stages(directory)"
        , "        if os.path.lexists(path): raise Conflict('absent-origin-record', 'appeared', 'release-record-race')"
        , "        return None"
        , "    raw = read_bytes(path); record = decode_exact_record(raw); cleanup_prepared_stages(directory)"
        , "    if read_bytes(path) != raw: raise Conflict('exact-origin-record', 'changed-record', 'record-version')"
        , "    return path, directory, record, raw"
        , "def transition_record(path, directory, current, state_value, identity, fence=None):"
        , "    expected_current = record_payload(current['nonce'], current['state'], current.get('managed'), current.get('conditional_version'))"
        , "    if read_bytes(path) != expected_current: raise Conflict('exact-origin-record', 'changed-record', 'record-version')"
        , "    payload = record_payload(current['nonce'], state_value, identity, fence)"
        , "    temporary = path + '.tmp-' + current['nonce'] + ('' if state_value == 'managed' else '-releasing')"
        , "    try: raw = read_bytes(temporary)"
        , "    except FileNotFoundError:"
        , "        create_full(temporary, payload, state_value + '-temp')"
        , "    else: complete_partial(temporary, raw, payload, state_value + '-temp')"
        , "    fsync_dir(directory); os.replace(temporary, path); fsync_dir(directory)"
        , "    final_raw = read_bytes(path)"
        , "    if final_raw != payload: raise Conflict('exact-' + state_value + '-readback', 'different-bytes', 'record-readback')"
        , "    return decode_exact_record(final_raw)"
        , "def bind_record(path, directory, current, identity):"
        , "    if current['state'] == 'managed':"
        , "        if current['managed'] != identity: raise Conflict(current['managed'], identity, 'managed-record')"
        , "        return current"
        , "    if current['state'] != 'prepared': raise Conflict('prepared-origin-record', current['state'], 'managed-transition')"
        , "    return transition_record(path, directory, current, 'managed', identity)"
        , "def release_record(path, directory, current, identity):"
        , "    if current['state'] == 'releasing':"
        , "        if current['managed'] != identity: raise Conflict(current['managed'], identity, 'releasing-record')"
        , "        if current['conditional_version'] != conditional_version: raise Conflict(current['conditional_version'], conditional_version, 'release-fence')"
        , "        return current"
        , "    if current['state'] != 'managed': raise Conflict('managed-origin-record', current['state'], 'release-record')"
        , "    return transition_record(path, directory, current, 'releasing', identity, conditional_version)"
        , "def drop_record(path, directory, current):"
        , "    if decode_exact_record(read_bytes(path)) != current: raise Conflict('exact-origin-record', 'changed-record', 'record-version')"
        , "    os.unlink(path); fsync_dir(directory)"
        , "    if os.path.lexists(path): raise Conflict('absent-origin-record', 'still-present', 'record-delete-readback')"
        , "def reclaim_record_dir(directory):"
        , "    try: os.rmdir(directory)"
        , "    except OSError as failure:"
        , "        if failure.errno in (errno.ENOTEMPTY, errno.EEXIST, errno.ENOENT): return"
        , "        raise"
        , "    fsync_dir(os.path.dirname(directory))"
        , "def stable_identity(path):"
        , "    result = subprocess.run([stat_executable, sflag, sfmt, path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)"
        , "    if result.returncode != 0: raise OSError('stat-failed-' + token(result.stderr))"
        , "    if result.stderr != '': raise Unsupported('stat-returned-stderr')"
        , "    if '\\r' in result.stdout or result.stdout.count('\\n') != 1 or not result.stdout.endswith('\\n'): raise Unsupported('stat-returned-nonexact-output')"
        , "    value = result.stdout[:-1]"
        , "    if not identity_re.fullmatch(value): raise Unsupported('stat-returned-no-stable-device-inode')"
        , "    return value"
        , "def observation(path):"
        , "    if not os.path.lexists(path): return 'absent', 'absent'"
        , "    identity = stable_identity(path)"
        , "    if os.path.islink(path):"
        , "        return identity, ('exact' if os.readlink(path) == target else 'repoint')"
        , "    return identity, 'occupied'"
        , "def sync_alias_parent(): fsync_dir(os.path.dirname(alias_path) or '/')"
        , "def alias_stages():"
        , "    parent = os.path.dirname(alias_path) or '/'; prefix = os.path.basename(alias_path) + '.hb-alias-stage-'"
        , "    found = []"
        , "    with os.scandir(parent) as entries:"
        , "        for entry in entries:"
        , "            if not entry.name.startswith(prefix): continue"
        , "            nonce = entry.name[len(prefix):]"
        , "            if not nonce_re.fullmatch(nonce): raise Conflict('owner-bound-alias-stage', token(entry.name), 'alias-stage-name')"
        , "            found.append(os.path.join(parent, entry.name))"
        , "            if len(found) > 2: raise Conflict('bounded-alias-stages', str(len(found)), 'alias-stage-count')"
        , "    return found"
        , "def prove_released_absent():"
        , "    info = os.lstat(target)"
        , "    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode): raise Unsupported('durable-target-is-not-a-real-directory')"
        , "    directory = os.path.join(target, state_name); path = os.path.join(directory, record_name)"
        , "    if os.path.lexists(directory):"
        , "        found = os.lstat(directory)"
        , "        if not stat.S_ISDIR(found.st_mode) or stat.S_ISLNK(found.st_mode): raise Unsupported('origin-record-directory-is-not-a-real-directory')"
        , "        fsync_dir(target); fsync_dir(directory); cleanup_prepared_stages(directory)"
        , "        if os.path.lexists(path): raise Conflict('absent-origin-record', 'present', 'release-record-reappeared')"
        , "        if prepared_stages(directory): raise Conflict('absent-prepared-stage', 'present', 'release-stage-reappeared')"
        , "    else:"
        , "        fsync_dir(target)"
        , "        if os.path.lexists(directory): raise Conflict('absent-origin-directory', 'present', 'release-directory-reappeared')"
        , "    stages = alias_stages()"
        , "    if stages: raise Conflict('absent-alias-stage', token(os.path.basename(stages[0])), 'release-stage-residue')"
        , "    sync_alias_parent()"
        , "    if os.path.lexists(alias_path): raise Conflict('absent-managed-alias', 'present', 'release-alias-reappeared')"
        , "def cleanup_stage(stage, identity):"
        , "    if not os.path.lexists(stage): return"
        , "    observed, kind = observation(stage)"
        , "    if observed != identity or kind != 'exact': raise Conflict(identity, observed, 'staging-identity')"
        , "    os.unlink(stage); sync_alias_parent()"
        , "def reconcile():"
        , "    if conditional_version != '0': raise Conflict('conditional-version-0', conditional_version, 'reconcile-fence')"
        , "    fresh, record_path, record_dir, record, _ = prepare_record()"
        , "    pass  # HB_ALIAS_AFTER_ORIGIN"
        , "    nonce = record['nonce']; stage = alias_path + '.hb-alias-stage-' + nonce"
        , "    unexpected = [path for path in alias_stages() if path != stage]"
        , "    if unexpected: raise Conflict('one-owner-bound-alias-stage', token(os.path.basename(unexpected[0])), 'alias-stage-residue')"
        , "    if record['state'] == 'releasing': raise Conflict('prepared-or-managed-origin-record', record['state'], 'reconcile-record')"
        , "    if record['state'] == 'managed':"
        , "        observed, kind = observation(alias_path)"
        , "        if observed != record['managed'] or kind != 'exact': raise Conflict(record['managed'], observed, 'managed-alias-' + kind)"
        , "        cleanup_stage(stage, observed); emit('ALREADY', observed)"
        , "    if os.path.lexists(stage):"
        , "        staged, stage_kind = observation(stage)"
        , "        if stage_kind != 'exact': raise Conflict('nonce-staging-link', staged, 'staging-' + stage_kind)"
        , "    else:"
        , "        os.symlink(target, stage); sync_alias_parent(); staged = stable_identity(stage)"
        , "    observed, kind = observation(alias_path)"
        , "    if observed == 'absent':"
        , "        try: os.link(stage, alias_path, follow_symlinks=False); sync_alias_parent()"
        , "        except FileExistsError: pass"
        , "        observed, kind = observation(alias_path)"
        , "    if observed != staged or kind != 'exact':"
        , "        cleanup_stage(stage, staged)"
        , "        pass  # HB_ALIAS_AFTER_FOREIGN_CLEANUP"
        , "        drop_record(record_path, record_dir, record); reclaim_record_dir(record_dir); emit('FOREIGN', observed, kind)"
        , "    pass  # HB_ALIAS_AFTER_PUBLISH"
        , "    bind_record(record_path, record_dir, record, observed)"
        , "    cleanup_stage(stage, observed)"
        , "    emit('CREATED' if fresh else 'REPAIRED', observed)"
        , "def release():"
        , "    if not conditional_version.isdigit() or int(conditional_version) <= 0: raise Conflict('positive-conditional-version', token(conditional_version), 'release-fence')"
        , "    existing = existing_record()"
        , "    if existing is None:"
        , "        observed, kind = observation(alias_path)"
        , "        if observed != 'absent': raise Conflict('absent-managed-alias', observed, 'release-without-record-' + kind)"
        , "        prove_released_absent(); emit('RELEASED_ALREADY')"
        , "    record_path, record_dir, record, _ = existing"
        , "    if record['state'] == 'prepared': raise Conflict('managed-origin-record', record['state'], 'release-record')"
        , "    identity = record['managed']; stage = alias_path + '.hb-alias-stage-' + record['nonce']"
        , "    unexpected = [path for path in alias_stages() if path != stage]"
        , "    if unexpected: raise Conflict('one-owner-bound-alias-stage', token(os.path.basename(unexpected[0])), 'release-stage-residue')"
        , "    if os.path.lexists(stage):"
        , "        staged, stage_kind = observation(stage)"
        , "        if staged != identity or stage_kind != 'exact': raise Conflict(identity, staged, 'release-staging-' + stage_kind)"
        , "    observed, kind = observation(alias_path)"
        , "    if record['state'] == 'managed' and observed == 'absent': raise Conflict(identity, observed, 'managed-alias-absent-before-release-intent')"
        , "    if observed != 'absent' and (observed != identity or kind != 'exact'): raise Conflict(identity, observed, 'release-alias-' + kind)"
        , "    record = release_record(record_path, record_dir, record, identity)"
        , "    pass  # HB_ALIAS_AFTER_RELEASE_INTENT"
        , "    observed, kind = observation(alias_path)"
        , "    if observed != 'absent' and (observed != identity or kind != 'exact'): raise Conflict(identity, observed, 'release-alias-after-intent-' + kind)"
        , "    if observed == identity: os.unlink(alias_path); sync_alias_parent()"
        , "    pass  # HB_ALIAS_AFTER_RELEASE_UNLINK"
        , "    cleanup_stage(stage, identity)"
        , "    drop_record(record_path, record_dir, record)"
        , "    reclaim_record_dir(record_dir)"
        , "    prove_released_absent()"
        , "    emit('RELEASED', identity)"
        , "try:"
        , "    if mode == 'reconcile': reconcile()"
        , "    elif mode == 'release': release()"
        , "    else: raise Unsupported('unknown-operation')"
        , "except Conflict as failure: emit('CONFLICT', failure.expected, failure.observed, failure.reason)"
        , "except Unsupported as failure: emit('UNSUPPORTED', failure)"
        , "except SystemExit: raise"
        , "except Exception as failure: emit('FAILED', type(failure).__name__, failure)"
        ]

parseReconcileReport ::
    GuestAliasSpec ->
    Word64 ->
    GuestCommandResult ->
    AliasCallObservation
parseReconcileReport spec generation result =
    case guestCommandProviderConflict result of
        Just (expected, observed, reason) ->
            AliasCallConflict
                (providerConflictDetail "reconcile provider guest durable alias" spec expected observed reason)
        Nothing ->
            case exactGuestReport result of
                Left diagnostic ->
                    AliasCallFailed
                        ( FailureDetail
                            "reconcile provider guest durable alias"
                            diagnostic
                            ReprobeBeforeRetry
                        )
                Right report -> parseReport report
  where
    parseReport report = case report of
        ["CREATED", identity]
            | validIdentity identity -> AliasCallCreated generation
        ["REPAIRED", identity]
            | validIdentity identity -> AliasCallRepaired generation
        ["ALREADY", identity]
            | validIdentity identity -> AliasCallAlreadyExact generation
        ["FOREIGN", identity, kind]
            | validObservedIdentity identity && validForeignKind kind ->
                AliasCallForeign
                    (identityGeneration identity)
                    ( ForeignObservation
                        (Text.pack (guestAliasPath spec))
                        (foreignReason kind)
                    )
        ["CONFLICT", expected, observed, reason]
            | all validConflictToken [expected, observed, reason] ->
            AliasCallConflict
                ( ConflictDetail
                    (Text.pack (guestAliasPath spec))
                    ("device:inode=" <> Text.pack expected)
                    ("device:inode=" <> Text.pack observed)
                    ("inspect the durable alias ownership record (" <> Text.pack reason <> ")")
                )
        ["UNSUPPORTED", reason]
            | validConflictToken reason ->
            AliasCallUnsupported
                ( UnsupportedDetail
                    "reconcile provider guest durable alias"
                    (Text.pack reason)
                )
        ["FAILED", failureKind, reason]
            | all validConflictToken [failureKind, reason] ->
            AliasCallFailed
                ( FailureDetail
                    "reconcile provider guest durable alias"
                    ( "the lock-held ownership helper failed ("
                        <> Text.pack failureKind
                        <> "): "
                        <> Text.pack reason
                    )
                    ReprobeBeforeRetry
                )
        _ ->
            AliasCallFailed
                ( FailureDetail
                    "reconcile provider guest durable alias"
                    ( "unparseable backend report: "
                        <> firstLineText (guestCommandStdout result)
                    )
                    ReprobeBeforeRetry
                )
    foreignReason "repoint" =
        "the alias is a symlink to a different target"
    foreignReason "exact" =
        "the alias has the correct target but not this generation's stable identity"
    foreignReason "occupied" =
        "the alias path is occupied by a non-symlink object"
    foreignReason "absent" = "the alias disappeared before ownership could be bound"
    foreignReason _ = "the alias is not the managed link"

    validForeignKind kind = kind `elem` ["absent", "exact", "occupied", "repoint"]

validIdentity :: String -> Bool
validIdentity value = case break (== ':') value of
    (device, ':' : inode) -> allDigits device && allDigits inode
    _ -> False
  where
    allDigits digits = not (null digits) && all (`elem` ['0' .. '9']) digits

validObservedIdentity :: String -> Bool
validObservedIdentity "absent" = True
validObservedIdentity value = validIdentity value

-- | Parse exactly one newline-terminated, single-space-delimited report.  A
-- successful helper that also writes diagnostics is not an authorizing
-- response: extra output can otherwise hide a second or ambiguous verdict.
exactGuestReport :: GuestCommandResult -> Either Text [String]
exactGuestReport result
    | not (guestCommandOk result) =
        Left
            ( "the guest exclusive-entry command failed: "
                <> firstLineText (guestCommandStderr result)
            )
    | not (null (guestCommandStderr result)) =
        Left
            ( "the guest exclusive-entry command wrote stderr: "
                <> firstLineText (guestCommandStderr result)
            )
    | length stdout > 1024 = malformed
    | '\r' `elem` stdout = malformed
    | null stdout || last stdout /= '\n' = malformed
    | length (filter (== '\n') stdout) /= 1 = malformed
    | null fields || unwords fields /= line = malformed
    | otherwise = Right fields
  where
    stdout = guestCommandStdout result
    line = if null stdout then "" else init stdout
    fields = words line
    malformed =
        Left
            ( "the guest exclusive-entry command returned a non-exact report: "
                <> firstLineText stdout
            )

{- | Fold a @device:inode@ identity to a positive generation for a foreign
observation (a foreign generation must be strictly positive; § EE).
-}
identityGeneration :: String -> Word64
identityGeneration = max 1 . foldl step 1469598103934665603
  where
    step acc c = (acc `xor` fromIntegral (fromEnum c)) * 1099511628211

firstLine :: String -> String
firstLine value = case lines value of
    (l : _) -> l
    [] -> ""

firstLineText :: String -> Text
firstLineText = Text.pack . firstLine

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

{- | Conditional release (clause 4): re-observe the alias's identity under the
same exclusive @flock@ and @unlink@ only on an exact @device:inode@ match
against the managed identity recorded in the guest origin record (clause 2).
Any other observation is a structured 'Conflict', the alias is left
untouched, and no receipt is consumed.
-}
runPreparedGuestAliasRelease ::
    StrongAliasBackend scope planId providerId backendId capabilityId ->
    PreparedGuestAliasRelease scope planId providerId backendId capabilityId aliasId shareId phase releaseId ->
    IO (Either ReconcileError ())
runPreparedGuestAliasRelease
    (StrongAliasBackend _ exec tools)
    (PreparedGuestAliasRelease spec owner handle _ conditionalVersion) = do
        result <-
            runProviderGuestExecutor
                exec
                ( exclusiveWrapped
                    tools
                    spec
                    "release"
                    owner
                    (resourceHandleGeneration handle)
                    conditionalVersion
                )
        pure (parseReleaseReport spec (guestCommandResult result))

parseReleaseReport :: GuestAliasSpec -> GuestCommandResult -> Either ReconcileError ()
parseReleaseReport spec result =
    case guestCommandProviderConflict result of
        Just (expected, observed, reason) ->
            Left
                ( Conflict
                    (providerConflictDetail "release provider guest durable alias" spec expected observed reason)
                )
        Nothing ->
            case exactGuestReport result of
                Left diagnostic ->
                    Left
                        ( Failure
                            ( FailureDetail
                                "release provider guest durable alias"
                                diagnostic
                                ReprobeBeforeRetry
                            )
                        )
                Right report -> parseReport report
  where
    parseReport report = case report of
        ["RELEASED", identity]
            | validIdentity identity -> Right ()
        ["RELEASED_ALREADY"] -> Right ()
        ["CONFLICT", expected, observed, reason]
            | all validConflictToken [expected, observed, reason] ->
            Left
                ( Conflict
                    ( ConflictDetail
                        (Text.pack (guestAliasPath spec))
                        ("device:inode=" <> Text.pack expected)
                        ("device:inode=" <> Text.pack observed)
                        ("reprobe the alias identity before releasing it (" <> Text.pack reason <> ")")
                    )
                )
        ["UNSUPPORTED", reason]
            | validConflictToken reason ->
            Left
                ( Unsupported
                    ( UnsupportedDetail
                        "release provider guest durable alias"
                        (Text.pack reason)
                    )
                )
        ["FAILED", failureKind, reason]
            | all validConflictToken [failureKind, reason] ->
            Left
                ( Failure
                    ( FailureDetail
                        "release provider guest durable alias"
                        ( "the lock-held ownership helper failed ("
                            <> Text.pack failureKind
                            <> "): "
                            <> Text.pack reason
                        )
                        ReprobeBeforeRetry
                    )
                )
        _ ->
            Left
                ( Failure
                    ( FailureDetail
                        "release provider guest durable alias"
                        ( "unparseable backend report: "
                            <> firstLineText (guestCommandStdout result)
                        )
                    ReprobeBeforeRetry
                    )
                )

providerConflictDetail :: String -> GuestAliasSpec -> String -> String -> String -> ConflictDetail
providerConflictDetail operation spec expected observed reason =
    ConflictDetail
        (Text.pack (guestAliasPath spec))
        ("provider expectation=" <> Text.pack expected)
        ("provider observation=" <> Text.pack observed)
        (Text.pack operation <> " must resolve the provider identity conflict before retrying (" <> Text.pack reason <> ")")

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
                else
                    joinAliasIO $
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
