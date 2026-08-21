{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Clause-holding realization boundary for a plan-owned host provider.

Every process this boundary starts is a described command run through the one
interpreter (§ KK), and the backend carries the typed host configuration that
interpreter resolves tools from.  There is no execution seam here to substitute
and no program written in another language to review: what a transaction
answered is a value, and what it /means/ is a total function of that value, so
every branch below is reachable by application rather than by arranging for a
stand-in to have been reached (§ NN).

What this module owns is the /translation/.  A prepared call carries the plan's
own indices; a transaction carries the ownership vocabulary's.  Each @run@ below
is one transaction followed by one total classification, and the classification
is exported beside it so a suite can apply it to an answer without a provider
being present at all.

For Incus, the four clauses are the seam's
("HostBootstrap.Substrate.Provider.Ownership"): clause 1 is the protected
store's exclusive entry under the provider's own state directory, clause 2 that
store's compare-and-swap, clause 3 the @volatile.uuid@ the provider answers
with, and clause 4 the identity-conditional release.  The owner claim rides on
@incus launch@ itself through @user.hostbootstrap.owner@, which is what closes
the window between the launch and the identity binding.  Delete is conditional
and leaves a same-named replacement untouched.

The Direct realization is structurally different: it admits an already-local
frame by observing it and deciding, without publishing an origin, holding a
clause, or claiming ownership of the host.  Stop and delete are therefore
'Unsupported'.
-}
module HostBootstrap.Substrate.Provider.Backend (
    -- * Descriptive provider request
    ProviderBackendSpec,
    mkIncusBackendSpec,
    mkDirectHostBackendSpec,

    -- * The Direct realization's own admission
    DirectRootObservation (..),
    observeDirectRoot,
    admitDirectRoot,
    directEgressCommand,

    -- * What a provider's own report means
    RawProviderOutcome (..),
    classifyProviderProvisionCall,
    classifyProviderReadyCall,
    classifyProviderStopCall,
    classifyProviderShareCall,
    classifyProviderDeleteCall,

    -- * Clause-holding backend
    StrongProviderBackend,
    discoverStrongProviderBackend,
    providerBackendBinding,

    -- * Prepared backend calls
    runProviderProvisionCall,
    runProviderReadyCall,
    RunningProviderDependency,
    withRunningProviderDependency,
    runProviderStopCall,
    runProviderShareCall,
    runProviderDeleteCall,

    -- * Provider-bound discovery and guest execution
    withProviderBoundExec,
)
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Bits (xor)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString.Char8 as ByteString
import Data.Char (isAlphaNum)
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Effect.Interpreter (interpretHostCommand)
import HostBootstrap.Effect.Run (CapturedRun (capturedExit, capturedStderr, capturedStdout))
import HostBootstrap.Effect.Vocabulary (HostCommand, hostCommand)
import HostBootstrap.HostConfig (HostConfig (hcSubstrate), resolveMaybe)
import HostBootstrap.HostTool (HostTool (Docker, Incus), absExePath)
import HostBootstrap.Readiness (Micros, microsValue, seconds)
import HostBootstrap.Reconcile (
    ConflictDetail (..),
    FailureDetail (..),
    ForeignObservation (..),
    ReconcileError (..),
    RecoveryDisposition (DoNotRetry, ReprobeBeforeRetry),
    Running,
    UnsupportedDetail (..),
    resourceHandleGeneration,
    resourceHandleKey,
    validateOwnershipReceipt,
 )
import HostBootstrap.Substrate (SubstrateName (LinuxCpu), substrateName)
import HostBootstrap.Substrate.Provider.Internal (
    DirectProbe (..),
    ProviderBoundExec,
    ProviderBoundRoute (..),
    ProviderProbeRequest,
    ProviderProbeRequestView (..),
    RawProviderOutcome (..),
    bindProviderBoundExec,
    providerProbeRequestView,
 )
import HostBootstrap.Substrate.Provider.Observation.Internal (
    ManagedProviderHandle (..),
    ProviderBackendBinding (..),
    ProviderDeleteCallResult (..),
    ProviderDeleteObservation (..),
    ProviderOriginBinding (..),
    ProviderProvisionCallResult (..),
    ProviderProvisionObservation (..),
    ProviderReadyCallResult (..),
    ProviderReadyObservation (..),
    ProviderShareCallResult (..),
    ProviderShareObservation (..),
    ProviderStopCallResult (..),
    ProviderStopObservation (..),
    providerOriginOwner,
 )
import HostBootstrap.Substrate.Provider.Dependency.Internal
  ( RunningProviderDependency (..),
  )
import HostBootstrap.Ownership.Object (
    Origin (OriginAbsent, OriginPresent),
    objectIdentityText,
    ownershipFault,
 )
import qualified HostBootstrap.Ownership.Object as OwnedObject
import HostBootstrap.Protected (
    ProtectedSession,
    RecordKey,
    openProtectedStore,
    protectedErrorMessage,
    withProtectedEntry,
 )
import HostBootstrap.Substrate.Provider.Command (ProviderSizing (ProviderSizing))
import HostBootstrap.Substrate.Provider.Ownership (
    OwnedProviderInstance (OwnedProviderInstance),
    OwnedProviderShare (OwnedProviderShare),
    ProviderOwnershipFault (
        ProviderOwnershipClause,
        ProviderOwnershipReport,
        ProviderOwnershipStanding,
        ProviderOwnershipStore
    ),
    ProviderDeleteOutcome (DeleteAlreadyRemoved, DeleteRemoved, DeleteStillPresent),
    ProviderProvisionOutcome (ProvisionAlreadyOwned, ProvisionCreated, ProvisionRecovered),
    ProviderReadyOutcome (ReadyAlready, ReadyNotAnswering, ReadyStarted),
    ProviderShareOutcome (ShareAlreadyAttached, ShareAttached, ShareRepaired),
    ProviderStopOutcome (StopAlreadyStopped, StopStillRunning, StopStopped),
    attachOwnedShare,
    deleteOwnedInstance,
    execInOwnedInstance,
    ownedInstanceRecordKey,
    ownedShareRecordKey,
    provisionOwnedInstance,
    readyOwnedInstance,
    stopOwnedInstance,
 )
import HostBootstrap.Substrate.Provider.Resume (
    ProviderStandingConflict (
        InstanceReplaced,
        InstanceUnderAnotherClaim,
        InstanceUnderNoRecord,
        InstanceVanished,
        RecordNamesAPriorInstance,
        RecordNotAClaimedObject
    ),
 )
import HostBootstrap.Substrate.Provider.Report (
    ProviderReportFault (ProviderCommandUnrun),
    classifyProviderReport,
    providerReportFaultMessage,
    providerReportLineBound,
 )
import HostBootstrap.Substrate.Provider.Reconcile (
    PreparedProviderBinding,
    PreparedProviderDelete,
    PreparedProviderProvision,
    PreparedProviderReady,
    PreparedProviderShare,
    PreparedProviderStop,
    ProviderPhaseAdvance,
    managedProviderGeneration,
    managedProviderKey,
    preparedProviderBindingCallDigest,
    preparedProviderBindingGeneration,
    preparedProviderBindingOperationKey,
    preparedProviderBindingOwner,
    preparedProviderBindingPlanDigest,
    preparedProviderBindingResourceKey,
    preparedProviderDeleteBinding,
    preparedProviderProvisionBinding,
    preparedProviderReadyBinding,
    preparedProviderShareBinding,
    preparedProviderShareHandle,
    preparedProviderShareSpec,
    preparedProviderStopBinding,
    withProviderPhaseAdvance,
    providerShareGuestPath,
    providerShareHostPath,
 )
import System.Exit (ExitCode (..))
import System.Directory (
    Permissions (readable, searchable, writable),
    canonicalizePath,
    doesDirectoryExist,
    getPermissions,
    pathIsSymbolicLink,
 )
import System.FilePath (equalFilePath, isAbsolute)

-- Descriptive request ---------------------------------------------------------

{- | A validated provider declaration.

Neither realization names an interpreter or a locking front end: every clause
this boundary holds is the seam's and every effect it performs is a described
command (§ KK).
-}
data ProviderBackendSpec
    = IncusBackendSpec
        String
        String
        String
        FilePath
        FilePath
        Word64
        String
        String
    | DirectHostBackendSpec FilePath FilePath String
    deriving (Eq, Show)

{- | Validate the complete Incus instance declaration.  The executable and
state directory must already be absolute; discovery proves their usability.
Resource quantities are passed as single argv values and therefore accept only
the bounded alphanumeric unit vocabulary used by the provider.
-}
mkIncusBackendSpec ::
    -- | the instance's own name
    String ->
    -- | the image a first launch creates it from
    String ->
    -- | the project's destructive-delete guard prefix (§ LL)
    String ->
    HostConfig ->
    FilePath ->
    Word64 ->
    String ->
    String ->
    Either ReconcileError ProviderBackendSpec
mkIncusBackendSpec name image guardPrefix hostConfig stateDirectory cpu memory storage
    | substrateName (hcSubstrate hostConfig) /= LinuxCpu = invalid "the Incus provider backend requires a linux-cpu HostConfig"
    | not (safeName name) = invalid "the Incus instance name is empty or contains a non-portable character"
    | not (safeName guardPrefix) = invalid "the destructive-delete guard prefix is empty or contains a non-portable character"
    | not (guardPrefix `isPrefixOf` name) =
        invalid "the Incus instance name does not carry the project's destructive-delete guard prefix"
    | length name > maxIncusInstanceNameLength =
        invalid
            ( "the Incus instance name is longer than "
                <> Text.pack (show maxIncusInstanceNameLength)
                <> " characters, so its share device socket path exceeds the platform limit"
            )
    | null image || '\0' `elem` image = invalid "the Incus image must be non-empty and contain no NUL"
    | not (hostAbsolutePath stateDirectory) = invalid "the provider state directory must be an absolute path on this host"
    | cpu == 0 = invalid "the provider CPU quantity must be positive"
    | not (safeQuantity memory) || not (safeQuantity storage) =
        invalid "provider memory and storage quantities must be non-empty alphanumeric values"
    | otherwise = do
        executable <- requireTool Incus
        Right (IncusBackendSpec name image guardPrefix executable stateDirectory cpu memory storage)
  where
    invalid reason = Left (Failure (FailureDetail "validate Incus provider backend" reason DoNotRetry))
    requireTool tool = case resolveMaybe hostConfig tool of
        Just executable -> Right (absExePath executable)
        Nothing ->
            Left
                ( Unsupported
                    ( UnsupportedDetail
                        "construct Incus provider backend"
                        (Text.pack ("the HostConfig has no resolved " <> show tool <> " executable"))
                    )
                )
-- | Admit the canonical already-local root.  No ownership is implied.
mkDirectHostBackendSpec :: HostConfig -> FilePath -> String -> Either ReconcileError ProviderBackendSpec
mkDirectHostBackendSpec hostConfig root egressImage
    | not (hostAbsolutePath root) =
        Left
            ( Failure
                ( FailureDetail
                    "validate Direct provider backend"
                    "the direct-host root must be an absolute path on this host"
                    DoNotRetry
                )
            )
    | '\0' `elem` root =
        Left
            ( Failure
                ( FailureDetail
                    "validate Direct provider backend"
                    "the direct-host root must not contain NUL"
                    DoNotRetry
                )
            )
    | null egressImage || '\0' `elem` egressImage =
        Left
            ( Failure
                ( FailureDetail
                    "validate Direct provider backend"
                    "the Direct provider egress image must be non-empty and contain no NUL"
                    DoNotRetry
                )
            )
    | otherwise = do
        docker <- requireTool Docker
        Right (DirectHostBackendSpec root docker egressImage)
  where
    requireTool tool = case resolveMaybe hostConfig tool of
        Just executable -> Right (absExePath executable)
        Nothing ->
            Left
                ( Unsupported
                    ( UnsupportedDetail
                        "construct Direct provider backend"
                        (Text.pack ("the HostConfig has no resolved " <> show tool <> " executable"))
                    )
                )

safeName :: String -> Bool
safeName value =
    not (null value)
        && all (\character -> isAlphaNum character || character `elem` ("-_." :: String)) value
        && '\0' `notElem` value

safeQuantity :: String -> Bool
safeQuantity value = not (null value) && all isAlphaNum value && '\0' `notElem` value

absolutePath :: FilePath -> Bool
absolutePath ('/' : _) = True
absolutePath _ = False

{- | Whether a path this process will itself open is absolute.

The provider's state directory holds the protected store this binary enters, so
the process that interprets it is this one and its grammar is this host's
(§ MM).  A POSIX-only check over it would admit the intended path on a POSIX
outer host and refuse the equivalent one everywhere else.
-}
hostAbsolutePath :: FilePath -> Bool
hostAbsolutePath = isAbsolute

-- Execution -------------------------------------------------------------------

{- | Wait the bounded interval a readiness poll asked for.

The one place this boundary sleeps.  A non-positive interval is not a wait at
all, so it is the identity rather than a call into the runtime.
-}
providerBackendWait :: Micros -> IO ()
providerBackendWait delay
    | microsValue delay > 0 = threadDelay (microsValue delay)
    | otherwise = pure ()

data
    StrongProviderBackend
        backendId
    = StrongIncusBackend (ProviderBackendBinding backendId) HostConfig ProviderBackendSpec
    | StrongDirectHostBackend (ProviderBackendBinding backendId) HostConfig ProviderBackendSpec

{- | Admit the declared backend.

Neither realization probes anything here.  What a discovery once proved — that a
writable state directory and a lock front end exist — is now the protected
store's own to establish when a transaction enters it, and clause 1 is that
entry rather than a front end this module resolves (§ EE).  A backend is
therefore a value the declaration decides, and the first transaction is where
the host answers for it.
-}
discoverStrongProviderBackend ::
    HostConfig ->
    ProviderBackendSpec ->
    (forall backendId. StrongProviderBackend backendId -> IO result) ->
    IO (Either ReconcileError result)
discoverStrongProviderBackend cfg spec consume =
    Right <$> consume (admitted spec)
  where
    binding = ProviderBackendBinding (backendSemanticFingerprint spec) (backendRealizationFingerprint spec)
    admitted DirectHostBackendSpec{} = StrongDirectHostBackend binding cfg spec
    admitted IncusBackendSpec{} = StrongIncusBackend binding cfg spec

providerBackendBinding :: StrongProviderBackend backendId -> ProviderBackendBinding backendId
providerBackendBinding backend = case backend of
    StrongIncusBackend binding _ _ -> binding
    StrongDirectHostBackend binding _ _ -> binding

backendSemanticFingerprint :: ProviderBackendSpec -> Text
backendSemanticFingerprint spec = case spec of
    IncusBackendSpec name image _ _ stateDirectory cpu memory storage ->
        framed
            [ "hostbootstrap/provider-backend/incus/v1"
            , Text.pack name
            , Text.pack image
            , Text.pack stateDirectory
            , Text.pack (show cpu)
            , Text.pack memory
            , Text.pack storage
            ]
    DirectHostBackendSpec root _ egressImage ->
        framed
            [ "hostbootstrap/provider-backend/direct/v1"
            , Text.pack root
            , Text.pack egressImage
            ]
  where
    framed = Text.concat . map (\value -> Text.pack (show (Text.length value)) <> ":" <> value)

backendRealizationFingerprint :: ProviderBackendSpec -> Text
backendRealizationFingerprint spec = case spec of
    IncusBackendSpec _ _ _ executable _ _ _ _ ->
        framed
            [ "hostbootstrap/provider-realization/incus/v1"
            , Text.pack executable
            ]
    DirectHostBackendSpec _ docker _ ->
        framed
            [ "hostbootstrap/provider-realization/direct/v1"
            , Text.pack docker
            ]
  where
    framed = Text.concat . map (\value -> Text.pack (show (Text.length value)) <> ":" <> value)

-- Prepared call seam ----------------------------------------------------------

runProviderProvisionCall ::
    StrongProviderBackend backendId ->
    PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    IO (ProviderProvisionCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion)
runProviderProvisionCall backend prepared = case backend of
    StrongDirectHostBackend _ _ _ ->
        pure (ProviderProvisionCallResult (ProviderProvisionDirectLocal (preparedProviderBindingGeneration binding)))
    StrongIncusBackend _ cfg spec -> do
        outcome <-
            withOwnedProviderTransaction cfg spec (preparedProviderBindingOwner binding) $
                \session key owned -> provisionOwnedInstance cfg session key owned
        pure (ProviderProvisionCallResult (provisionObservation binding outcome))
  where
    binding = preparedProviderProvisionBinding prepared

{- | What one provisioning transaction means, as a total function of its answer.

Exported beside the call that produces it, because the call is exactly the
transaction followed by this function: a suite whose subject is what an /answer/
means applies it to the answers a transaction can give and needs no stand-in for
the transaction (§ NN).
-}
classifyProviderProvisionCall ::
    PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    Either ProviderOwnershipFault ProviderProvisionOutcome ->
    ProviderProvisionCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion
classifyProviderProvisionCall prepared outcome =
    ProviderProvisionCallResult
        (provisionObservation (preparedProviderProvisionBinding prepared) outcome)

provisionObservation ::
    PreparedProviderBinding scope planId backendId providerId ->
    Either ProviderOwnershipFault ProviderProvisionOutcome ->
    ProviderProvisionObservation
provisionObservation binding outcome = case outcome of
    Right (ProvisionCreated _) -> ProviderProvisionCreated generation
    Right (ProvisionRecovered _) -> ProviderProvisionRepaired generation
    Right (ProvisionAlreadyOwned _) -> ProviderProvisionAlreadyOwned generation
    Left fault -> case ownedRefusal "provision provider" key fault of
        RefusedForeign foreignGeneration observed ->
            ProviderProvisionForeign foreignGeneration observed
        RefusedAbsent -> ProviderProvisionAbsent
        RefusedConflict detail -> ProviderProvisionConflict detail
        RefusedUnsupported detail -> ProviderProvisionUnsupported detail
        RefusedFailed detail -> ProviderProvisionFailed detail
  where
    generation = preparedProviderBindingGeneration binding
    key = preparedProviderBindingResourceKey binding

runProviderReadyCall ::
    StrongProviderBackend backendId ->
    PreparedProviderReady scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion ->
    IO (ProviderReadyCallResult scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion)
runProviderReadyCall backend prepared = case backend of
    StrongDirectHostBackend _ cfg (DirectHostBackendSpec root _ image) -> do
        permission <- admitObservedDirectRoot "validate the exact Direct provider root" root
        case permission of
            Just failure -> pure (ProviderReadyCallResult (ProviderReadyFailed failure))
            Nothing -> do
                egress <- interpretHostCommand cfg (directEgressCommand image)
                pure
                    ( ProviderReadyCallResult
                        ( case directReadyProbeFailure "validate Direct provider provisioning egress" egress of
                            Just failure -> ProviderReadyFailed failure
                            Nothing -> ProviderReadyObserved (preparedProviderBindingGeneration binding)
                        )
                    )
    StrongDirectHostBackend _ _ (IncusBackendSpec{}) ->
        pure (ProviderReadyCallResult (ProviderReadyFailed (failed "reconcile Direct provider ready" "invalid Direct backend state")))
    StrongIncusBackend _ cfg spec ->
        ProviderReadyCallResult <$> pollProviderReady cfg spec binding 60
  where
    binding = preparedProviderReadyBinding prepared

-- | What one readiness transaction means, as a total function of its answer.
classifyProviderReadyCall ::
    PreparedProviderReady scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion ->
    Either ProviderOwnershipFault ProviderReadyOutcome ->
    ProviderReadyCallResult scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion
classifyProviderReadyCall prepared outcome =
    ProviderReadyCallResult
        ( readyObservation
            (preparedProviderBindingResourceKey binding)
            (preparedProviderBindingGeneration binding)
            outcome
        )
  where
    binding = preparedProviderReadyBinding prepared

readyObservation ::
    Text ->
    Word64 ->
    Either ProviderOwnershipFault ProviderReadyOutcome ->
    ProviderReadyObservation
readyObservation key generation outcome = case outcome of
    Right (ReadyStarted _) -> ProviderReadyObserved generation
    Right (ReadyAlready _) -> ProviderReadyAlready generation
    Right (ReadyNotAnswering reason) -> ProviderReadyNotReady reason
    Left fault -> case ownedRefusal "reconcile provider ready" key fault of
        RefusedForeign foreignGeneration observed ->
            ProviderReadyReplaced foreignGeneration observed
        RefusedAbsent -> ProviderReadyAbsent
        RefusedConflict detail -> ProviderReadyConflict detail
        RefusedUnsupported detail -> ProviderReadyUnsupported detail
        RefusedFailed detail -> ProviderReadyFailed detail

{- | Seal a successful Running transition to the exact backend that minted it.
The retained reprobe is executed afresh by dependent-operation preconditions;
public callers can neither supply a probe nor recover the generic handle.
-}
withRunningProviderDependency ::
    StrongProviderBackend backendId ->
    ProviderPhaseAdvance scope planId backendId providerId Running ->
    (RunningProviderDependency scope planId providerId -> result) ->
    Either ReconcileError result
withRunningProviderDependency backend advance consume =
    withProviderPhaseAdvance advance $ \managed -> do
        validateProviderOrigin backend managed
        Right
            ( consume
                ( RunningProviderDependency
                    managed
                    (probeRunningProvider backend managed)
                )
            )

probeRunningProvider ::
    StrongProviderBackend backendId ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    IO (Either ReconcileError Word64)
probeRunningProvider backend managed = do
    observation <- case backend of
        StrongDirectHostBackend _ cfg (DirectHostBackendSpec root _ image) -> do
            permission <- admitObservedDirectRoot "reprobe the exact Direct provider root" root
            case permission of
                Just failure -> pure (ProviderReadyFailed failure)
                Nothing -> do
                    egress <- interpretHostCommand cfg (directEgressCommand image)
                    pure $ case directReadyProbeFailure "reprobe Direct provider provisioning egress" egress of
                        Just failure -> ProviderReadyFailed failure
                        Nothing -> ProviderReadyAlready (managedProviderGeneration managed)
        StrongDirectHostBackend _ _ (IncusBackendSpec{}) ->
            pure (ProviderReadyFailed (failed "reprobe Direct provider" "invalid Direct backend state"))
        StrongIncusBackend _ cfg spec -> do
            outcome <-
                withOwnedProviderTransaction cfg spec (managedOriginOwner managed) $
                    \session key owned -> readyOwnedInstance cfg session key owned
            pure
                ( readyObservation
                    (managedProviderKey managed)
                    (managedProviderGeneration managed)
                    outcome
                )
    pure (settleRunningProbe managed observation)

managedOriginOwner :: ManagedProviderHandle scope planId backendId providerId phase -> Text
managedOriginOwner (ManagedProviderHandle origin _ _) = providerOriginOwner origin

settleRunningProbe ::
    ManagedProviderHandle scope planId backendId providerId Running ->
    ProviderReadyObservation ->
    Either ReconcileError Word64
settleRunningProbe managed observation = case observation of
    ProviderReadyObserved generation -> matching generation
    ProviderReadyAlready generation -> matching generation
    ProviderReadyNotReady reason ->
        Left (Failure (FailureDetail "reprobe running provider" reason ReprobeBeforeRetry))
    ProviderReadyAbsent ->
        Left (Failure (FailureDetail "reprobe running provider" "the provider is absent" ReprobeBeforeRetry))
    ProviderReadyReplaced generation foreignState ->
        Left
            ( Conflict
                ( ConflictDetail
                    (managedProviderKey managed)
                    ("generation=" <> Text.pack (show (managedProviderGeneration managed)))
                    ("replacement generation=" <> Text.pack (show generation) <> "; " <> Text.pack (show foreignState))
                    "reconcile the replacement provider before any dependent mutation"
                )
            )
    ProviderReadyConflict detail -> Left (Conflict detail)
    ProviderReadyUnsupported detail -> Left (Unsupported detail)
    ProviderReadyFailed detail -> Left (Failure detail)
  where
    matching generation
        | generation == managedProviderGeneration managed = Right generation
        | otherwise =
            Left
                ( Conflict
                    ( ConflictDetail
                        (managedProviderKey managed)
                        ("generation=" <> Text.pack (show (managedProviderGeneration managed)))
                        ("generation=" <> Text.pack (show generation))
                        "reconcile the provider identity before any dependent mutation"
                    )
                )

{- | Whether an exact Direct probe answered at all.

An application of the one report classifier: a probe that produced no child,
exited non-zero, or complained on the wrong stream is a failure, and anything it
wrote on standard output is not read, because the probe's answer /is/ its exit
status.
-}
directReadyProbeFailure :: Text -> Either String CapturedRun -> Maybe FailureDetail
directReadyProbeFailure operation captured =
    case classifyProviderReport providerReportLineBound captured of
        Right _ -> Nothing
        Left fault ->
            Just (failed operation ("the exact probe " <> providerReportFaultMessage fault))

pollProviderReady ::
    HostConfig ->
    ProviderBackendSpec ->
    PreparedProviderBinding scope planId backendId providerId ->
    Int ->
    IO ProviderReadyObservation
pollProviderReady cfg spec binding remaining = do
    outcome <-
        withOwnedProviderTransaction cfg spec (preparedProviderBindingOwner binding) $
            \session key owned -> readyOwnedInstance cfg session key owned
    case readyObservation
        (preparedProviderBindingResourceKey binding)
        (preparedProviderBindingGeneration binding)
        outcome of
        observation@(ProviderReadyNotReady _)
            | remaining > 1 -> case seconds 1 of
                Left _ -> pure observation
                Right delay ->
                    providerBackendWait delay
                        >> pollProviderReady cfg spec binding (remaining - 1)
        observation -> pure observation

-- The clause-holding transactions ---------------------------------------------

{- | Run one owned-instance transaction inside the store its state directory
names.

Clause 1 is opened here and released when this call returns, because one
exclusive entry covers one whole transaction: a per-step entry would let another
process act between a record and the mutation it authorizes. The Direct
realization owns no instance at all, so it has no transaction to run and says so
rather than opening a store it would never write to.
-}
withOwnedProviderTransaction ::
    HostConfig ->
    ProviderBackendSpec ->
    Text ->
    ( forall session.
      ProtectedSession session ->
      RecordKey ->
      OwnedProviderInstance ->
      IO (Either ProviderOwnershipFault result)
    ) ->
    IO (Either ProviderOwnershipFault result)
withOwnedProviderTransaction _cfg (DirectHostBackendSpec{}) _owner _transaction =
    pure
        ( Left
            ( ProviderOwnershipReport
                ( ProviderCommandUnrun
                    "the Direct realization owns no provider instance to enter"
                )
            )
        )
withOwnedProviderTransaction
    _cfg
    (IncusBackendSpec name image guardPrefix _executable stateDirectory cpu memory storage)
    owner
    transaction = do
        let owned =
                OwnedProviderInstance name image guardPrefix (ProviderSizing cpu memory storage) owner
        case ownedInstanceRecordKey owned of
            Left failure -> pure (Left (ProviderOwnershipStore failure))
            Right key -> do
                opened <- openProtectedStore stateDirectory
                case opened of
                    Left failure -> pure (Left (ProviderOwnershipStore failure))
                    Right store -> do
                        outcome <-
                            withProtectedEntry
                                store
                                (\session -> Right <$> transaction session key owned)
                        pure (either (Left . ProviderOwnershipStore) id outcome)

{- | Run one owned-share transaction inside the instance's own store.

The share's record lives beside the instance's, under its own key, because a
share is an object of its own: a record that meant two things could not tell a
resumed entry which of them it had published.
-}
withOwnedShareTransaction ::
    HostConfig ->
    ProviderBackendSpec ->
    Text ->
    String ->
    Text ->
    FilePath ->
    FilePath ->
    IO (Either ProviderOwnershipFault ProviderShareOutcome)
withOwnedShareTransaction cfg spec owner device binding source target =
    withOwnedProviderTransaction cfg spec owner $ \session _key owned -> do
        let share = OwnedProviderShare owned device source target binding
        case ownedShareRecordKey share of
            Left failure -> pure (Left (ProviderOwnershipStore failure))
            Right shareKey -> attachOwnedShare cfg session shareKey share

{- | The five shapes a refused ownership transaction takes at a provider call.

Written once over the closed fault sum, because "the instance vanished", "a
different instance stands at the name", and "the record under this key is
somebody else's" mean the same thing to every verb; what differs per verb is only
which of its own constructors carries each, which is five lines rather than five
copies of this decision.
-}
data OwnedProviderRefusal
    = RefusedForeign Word64 ForeignObservation
    | RefusedAbsent
    | RefusedConflict ConflictDetail
    | RefusedUnsupported UnsupportedDetail
    | RefusedFailed FailureDetail

ownedRefusal :: Text -> Text -> ProviderOwnershipFault -> OwnedProviderRefusal
ownedRefusal operation key fault = case fault of
    ProviderOwnershipStanding standing -> case standing of
        InstanceUnderNoRecord observed -> refusedForeign observed
        InstanceUnderAnotherClaim expected observed ->
            RefusedConflict
                (conflict key expected observed "inspect the instance's own owner claim")
        InstanceReplaced _ observed -> refusedForeign observed
        InstanceVanished _ -> RefusedAbsent
        RecordNotAClaimedObject described ->
            RefusedConflict
                ( conflict
                    key
                    "a durable record about a provider instance"
                    described
                    "inspect the durable record under this instance's key"
                )
        RecordNamesAPriorInstance observed -> refusedForeign observed
    ProviderOwnershipClause clause ->
        ownershipFault
            (RefusedUnsupported . unsupported operation)
            (\attempted reason -> RefusedFailed (failed operation ("could not " <> attempted <> ": " <> reason)))
            (RefusedFailed . failed operation)
            ( \reason ->
                RefusedConflict
                    (conflict key "an unowned provider name" reason "inspect the object at this name")
            )
            ( \report ->
                RefusedConflict
                    ( conflict
                        key
                        (originSide (OwnedObject.conflictExpected report))
                        (originSide (OwnedObject.conflictObserved report))
                        (OwnedObject.conflictSubject report)
                    )
            )
            clause
    ProviderOwnershipReport reportFault ->
        RefusedFailed (failed operation (providerReportFaultMessage reportFault))
    ProviderOwnershipStore storeFailure ->
        RefusedFailed (failed operation (protectedErrorMessage storeFailure))
  where
    refusedForeign observed =
        let rendered = Text.unpack (objectIdentityText observed)
         in RefusedForeign (identityGeneration rendered) (foreignObservation key rendered)

-- | One rendering of a conflict's side, so both sides read the same way.
originSide :: Origin -> Text
originSide OriginAbsent = "absent"
originSide (OriginPresent identity) = "identity " <> objectIdentityText identity

runProviderStopCall ::
    StrongProviderBackend backendId ->
    PreparedProviderStop scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    IO (ProviderStopCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion)
runProviderStopCall backend prepared = case backend of
    StrongDirectHostBackend _ _ _ ->
        pure
            ( ProviderStopCallResult
                ( ProviderStopUnsupported
                    (UnsupportedDetail "stop Direct provider" "the local host is not project-owned and cannot be stopped")
                )
            )
    StrongIncusBackend _ cfg spec -> do
        outcome <-
            withOwnedProviderTransaction cfg spec (preparedProviderBindingOwner binding) $
                \session key owned -> stopOwnedInstance cfg session key owned
        pure (classifyProviderStopCall prepared outcome)
  where
    binding = preparedProviderStopBinding prepared

-- | What one stop transaction means, as a total function of its answer.
classifyProviderStopCall ::
    PreparedProviderStop scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    Either ProviderOwnershipFault ProviderStopOutcome ->
    ProviderStopCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion
classifyProviderStopCall prepared outcome =
    ProviderStopCallResult
        ( case outcome of
            Right (StopStopped _) -> ProviderStopped generation
            Right (StopAlreadyStopped _) -> ProviderAlreadyStopped generation
            Right (StopStillRunning reason) -> ProviderStopStillRunning reason
            Left fault -> case ownedRefusal "stop provider" key fault of
                RefusedForeign foreignGeneration observed ->
                    ProviderStopReplaced foreignGeneration observed
                RefusedAbsent -> ProviderStopAbsent
                RefusedConflict detail -> ProviderStopConflict detail
                RefusedUnsupported detail -> ProviderStopUnsupported detail
                RefusedFailed detail -> ProviderStopFailed detail
        )
  where
    binding = preparedProviderStopBinding prepared
    generation = preparedProviderBindingGeneration binding
    key = preparedProviderBindingResourceKey binding

runProviderShareCall ::
    StrongProviderBackend backendId ->
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    IO (ProviderShareCallResult scope planId backendId providerId shareId operationKey callDigest attempt journalVersion)
runProviderShareCall backend prepared = case backend of
    StrongDirectHostBackend _ _ (DirectHostBackendSpec root _ _)
        | source == root ->
            pure (ProviderShareCallResult (ProviderShareDirectLocal shareGeneration))
        | otherwise ->
            pure
                ( ProviderShareCallResult
                    ( ProviderShareConflict
                        ( ConflictDetail
                            "direct-host-share"
                            (Text.pack root)
                            (Text.pack (source <> " -> " <> target))
                            "the direct host exposes its one canonical root and mounts nothing"
                        )
                    )
                )
    StrongIncusBackend _ cfg spec
        | not (hostAbsolutePath source) || not (absolutePath target) || '\0' `elem` source || '\0' `elem` target ->
            pure
                ( ProviderShareCallResult
                    ( ProviderShareFailed
                        (FailureDetail "reconcile provider share" "share paths must be absolute and contain no NUL" DoNotRetry)
                    )
                )
        | otherwise -> do
            outcome <-
                withOwnedShareTransaction
                    cfg
                    spec
                    (preparedProviderBindingOwner binding)
                    (shareDeviceName prepared)
                    (preparedShareBinding prepared)
                    source
                    target
            pure (classifyProviderShareCall prepared outcome)
    StrongDirectHostBackend _ _ (IncusBackendSpec{}) ->
        pure (ProviderShareCallResult (ProviderShareFailed (failed "reconcile provider share" "invalid Direct backend state")))
  where
    binding = preparedProviderShareBinding prepared
    shareGeneration = resourceHandleGeneration (preparedProviderShareHandle prepared)
    source = providerShareHostPath shareSpec
    target = providerShareGuestPath shareSpec
    shareSpec = preparedProviderShareSpec prepared

-- | What one share transaction means, as a total function of its answer.
classifyProviderShareCall ::
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    Either ProviderOwnershipFault ProviderShareOutcome ->
    ProviderShareCallResult scope planId backendId providerId shareId operationKey callDigest attempt journalVersion
classifyProviderShareCall prepared outcome =
    ProviderShareCallResult
        ( case outcome of
            Right ShareAttached -> ProviderShareAttached shareGeneration
            Right ShareRepaired -> ProviderShareRepaired shareGeneration
            Right ShareAlreadyAttached -> ProviderShareAlreadyReady shareGeneration
            Left fault -> case ownedRefusal "reconcile provider share" key fault of
                RefusedForeign foreignGeneration observed ->
                    ProviderShareProviderReplaced foreignGeneration observed
                RefusedAbsent -> ProviderShareAbsent
                RefusedConflict detail -> ProviderShareConflict detail
                RefusedUnsupported detail -> ProviderShareUnsupported detail
                RefusedFailed detail -> ProviderShareFailed detail
        )
  where
    shareGeneration = resourceHandleGeneration (preparedProviderShareHandle prepared)
    key = preparedProviderBindingResourceKey (preparedProviderShareBinding prepared)

shareDeviceName ::
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    String
shareDeviceName prepared =
    shareDevicePrefix
        <> take shareDeviceDigestLength (ByteString.unpack (convertToBase Base16 digest))
  where
    digest = hash (ByteString.pack (Text.unpack (preparedShareBinding prepared))) :: Digest SHA256

{- | The share device is named from the share binding digest, so the same
prepared share always addresses the same device and a different binding never
addresses it.  The name is bounded because it is a component of a POSIX
unix-domain socket pathname (see 'maxIncusInstanceNameLength'); a truncated
binding digest still names the device from the binding rather than from a
pathname, and a same-named device carrying a different binding is refused by
the share manifest before any mutation.
-}
shareDevicePrefix :: String
shareDevicePrefix = "hb-share-"

shareDeviceDigestLength :: Int
shareDeviceDigestLength = 12

shareDeviceNameLength :: Int
shareDeviceNameLength = length shareDevicePrefix + shareDeviceDigestLength

{- | Incus's default state directory.  It opens one virtio-fs control socket per
attached share device at
@\<incusVarPath\>\/devices\/\<instance\>\/virtio-fs.\<device\>.sock@.
-}
incusVarPath :: FilePath
incusVarPath = "/var/lib/incus"

{- | A POSIX @sun_path@ holds 108 bytes including the terminating NUL, so a
socket pathname has 107 usable bytes.  @connect(2)@ answers @EINVAL@ for a
longer one, which surfaces as an unattachable share rather than as a bad
declaration, so the bound belongs to backend admission.
-}
unixSocketPathLimit :: Int
unixSocketPathLimit = 107

{- | The instance name and the share device name share the one socket-pathname
budget, and the device name is fixed by 'shareDeviceNameLength', so admission
bounds the instance name by what remains.
-}
maxIncusInstanceNameLength :: Int
maxIncusInstanceNameLength =
    unixSocketPathLimit
        - length (incusVarPath <> "/devices/" <> "/virtio-fs." <> ".sock")
        - shareDeviceNameLength

preparedShareBinding ::
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    Text
preparedShareBinding prepared =
    Text.concat
        [ sized "hostbootstrap/provider-share/v1"
        , sized (preparedProviderBindingPlanDigest binding)
        , sized (preparedProviderBindingResourceKey binding)
        , sized (Text.pack (show (preparedProviderBindingGeneration binding)))
        , sized (resourceHandleKey shareHandle)
        , sized (Text.pack (show (resourceHandleGeneration shareHandle)))
        , sized (preparedProviderBindingOperationKey binding)
        , sized (preparedProviderBindingCallDigest binding)
        ]
  where
    binding = preparedProviderShareBinding prepared
    shareHandle = preparedProviderShareHandle prepared
    sized value = Text.pack (show (Text.length value)) <> ":" <> value

runProviderDeleteCall ::
    StrongProviderBackend backendId ->
    PreparedProviderDelete scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    IO (ProviderDeleteCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion)
runProviderDeleteCall backend prepared = case backend of
    StrongDirectHostBackend _ _ _ ->
        pure
            ( ProviderDeleteCallResult
                ( ProviderDeleteUnsupported
                    (UnsupportedDetail "delete Direct provider" "the local host is not project-owned and cannot be deleted")
                )
            )
    StrongIncusBackend _ cfg spec -> do
        outcome <-
            withOwnedProviderTransaction cfg spec (preparedProviderBindingOwner binding) $
                \session key owned -> deleteOwnedInstance cfg session key owned
        pure (classifyProviderDeleteCall prepared outcome)
  where
    binding = preparedProviderDeleteBinding prepared

-- | What one delete transaction means, as a total function of its answer.
classifyProviderDeleteCall ::
    PreparedProviderDelete scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    Either ProviderOwnershipFault ProviderDeleteOutcome ->
    ProviderDeleteCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion
classifyProviderDeleteCall prepared outcome =
    ProviderDeleteCallResult
        ( case outcome of
            Right DeleteRemoved -> ProviderDeleted
            Right DeleteAlreadyRemoved -> ProviderAlreadyDeleted
            Right DeleteStillPresent -> ProviderDeleteStillPresent generation
            Left fault -> case ownedRefusal "delete provider" key fault of
                RefusedForeign foreignGeneration observed ->
                    ProviderDeleteReplaced foreignGeneration observed
                RefusedAbsent ->
                    ProviderDeleteFailed
                        ( failed
                            "delete provider"
                            "the provider disappeared during conditional deletion; retry to reconcile durable cleanup"
                        )
                RefusedConflict detail -> ProviderDeleteConflict detail
                RefusedUnsupported detail -> ProviderDeleteUnsupported detail
                RefusedFailed detail -> ProviderDeleteFailed detail
        )
  where
    binding = preparedProviderDeleteBinding prepared
    generation = preparedProviderBindingGeneration binding
    key = preparedProviderBindingResourceKey binding

-- Provider-bound discovery and guest execution ------------------------------

withProviderBoundExec ::
    StrongProviderBackend backendId ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    (ProviderBoundExec scope planId providerId Running backendId -> result) ->
    Either ReconcileError result
withProviderBoundExec backend managed@(ManagedProviderHandle origin handle receipt) consume = do
    validateOwnershipReceipt handle receipt
    validateProviderOrigin backend managed
    case backend of
        StrongDirectHostBackend _ cfg spec ->
            Right
                ( consume
                    ( bindProviderBoundExec
                        (providerBoundRouteFor spec)
                        (runBoundDirect cfg spec)
                        providerBackendWait
                    )
                )
        StrongIncusBackend _ cfg spec ->
            Right
                ( consume
                    ( bindProviderBoundExec
                        (providerBoundRouteFor spec)
                        (runBoundIncus cfg spec (providerOriginOwner origin))
                        providerBackendWait
                    )
                )

validateProviderOrigin ::
    StrongProviderBackend backendId ->
    ManagedProviderHandle scope planId backendId providerId phase ->
    Either ReconcileError ()
validateProviderOrigin backend (ManagedProviderHandle origin handle _)
    | providerOriginResourceKey origin /= resourceHandleKey handle =
        Left
            ( Conflict
                ( ConflictDetail
                    (resourceHandleKey handle)
                    (providerOriginResourceKey origin)
                    (resourceHandleKey handle)
                    "use the provider authority settled from this exact origin"
                )
            )
    | providerOriginGeneration origin /= resourceHandleGeneration handle =
        Left
            ( Conflict
                ( ConflictDetail
                    (resourceHandleKey handle)
                    (Text.pack (show (providerOriginGeneration origin)))
                    (Text.pack (show (resourceHandleGeneration handle)))
                    "use the provider authority settled from this exact generation"
                )
            )
    | not (sameBackendBinding expected (providerOriginBackendBinding origin)) =
        Left
            ( Conflict
                ( ConflictDetail
                    (resourceHandleKey handle)
                    "the retained provider backend realization"
                    "a different provider backend realization"
                    "use the strong backend that minted this managed provider authority"
                )
            )
    | otherwise = Right ()
  where
    expected = case backend of
        StrongIncusBackend binding _ _ -> binding
        StrongDirectHostBackend binding _ _ -> binding

sameBackendBinding :: ProviderBackendBinding backendId -> ProviderBackendBinding backendId -> Bool
sameBackendBinding left right =
    providerBackendSemanticFingerprint left == providerBackendSemanticFingerprint right
        && providerBackendRealizationFingerprint left == providerBackendRealizationFingerprint right

providerBoundRouteFor :: ProviderBackendSpec -> ProviderBoundRoute
providerBoundRouteFor spec = case spec of
    IncusBackendSpec name image _ _ _ _ _ _ -> ProviderBoundIncusRoute name image
    DirectHostBackendSpec root _ egressImage -> ProviderBoundDirectRoute root egressImage

runBoundDirect :: HostConfig -> ProviderBackendSpec -> ProviderProbeRequest -> IO RawProviderOutcome
runBoundDirect cfg spec request = case (spec, providerProbeRequestView request) of
    (DirectHostBackendSpec root _ _, ProviderDirectProbeRequest DirectPermissionProbe) -> do
        admitted <- admitObservedDirectRoot "admit the exact Direct provider root" root
        pure
            ( case admitted of
                Nothing -> RawProviderExit ExitSuccess "" ""
                Just refusal -> RawProviderFailure (Text.unpack (failureCause refusal))
            )
    (DirectHostBackendSpec _ _ image, ProviderProvisioningEgressProbe) ->
        rawProviderOutcome <$> interpretHostCommand cfg (directEgressCommand image)
    (IncusBackendSpec{}, _) ->
        pure (RawProviderFailure "invalid Direct backend state")
    (_, ProviderHostToolRequest _ _) ->
        pure (RawProviderFailure "the Direct provider has no host-tool or guest route")
    (_, ProviderGuestProbeRequest _) ->
        pure (RawProviderFailure "the Direct provider has no guest route")

{- | What this host answers about the Direct realization's declared root.

Five independent facts, read once, because the admission is a decision over all
five together and asking them at the point of decision would make the decision
an effect.  Every field is what this host said, so the decision below is a total
function of a value and every branch of it is reachable by application (§ NN).
-}
data DirectRootObservation = DirectRootObservation
    { directRootAbsolute :: Bool
    -- ^ absolute in this host's own grammar (§ MM)
    , directRootSymbolicLink :: Bool
    -- ^ a link, which is a different object from the one it names
    , directRootDirectory :: Bool
    -- ^ a directory rather than a file or a device
    , directRootCanonical :: Bool
    -- ^ the path this host resolves it to is the path itself
    , directRootAccessible :: Bool
    -- ^ readable, writable, and searchable by this process
    }
    deriving (Eq, Show)

{- | Take the observation against the real kernel.

The only effect the admission has, and this binary's own: a delegated program
would answer the same five questions in another language, which is the fork
§ KK refuses.  A path that cannot be inspected at all is observed as the absence
it is rather than as an exception, because "there is nothing there" is one of
the answers the decision is written over.
-}
observeDirectRoot :: FilePath -> IO DirectRootObservation
observeDirectRoot root = do
    link <- quietly False (pathIsSymbolicLink root)
    directory <- quietly False (doesDirectoryExist root)
    canonical <- quietly root (canonicalizePath root)
    accessible <-
        if directory
            then quietly False (fmap admits (getPermissions root))
            else pure False
    pure
        DirectRootObservation
            { directRootAbsolute = isAbsolute root
            , directRootSymbolicLink = link
            , directRootDirectory = directory
            , directRootCanonical = equalFilePath canonical root
            , directRootAccessible = accessible
            }
  where
    admits permissions = readable permissions && writable permissions && searchable permissions
    quietly :: value -> IO value -> IO value
    quietly fallback action = do
        outcome <- try action
        pure (either (\failure -> const fallback (failure :: IOException)) id outcome)

{- | Whether the observed root is the exact canonical directory Direct admits.

Total, and one reason at a time, so an operator learns which of the five facts
refused rather than that "the root is invalid".  Direct still claims no
ownership of the host: this decides only whether an already-local frame may be
admitted, and it publishes no origin and holds no clause.
-}
admitDirectRoot :: FilePath -> DirectRootObservation -> Either Text ()
admitDirectRoot root observed
    | not (directRootAbsolute observed) = refuse "is not absolute on this host"
    | directRootSymbolicLink observed = refuse "is a symbolic link rather than the directory it names"
    | not (directRootDirectory observed) = refuse "is not a directory"
    | not (directRootCanonical observed) = refuse "is not the canonical path this host resolves it to"
    | not (directRootAccessible observed) = refuse "is not readable, writable, and searchable"
    | otherwise = Right ()
  where
    refuse reason = Left ("the Direct provider root " <> Text.pack root <> " " <> reason)

-- | Observe the Direct root and decide, as the one step a caller takes.
admitObservedDirectRoot :: Text -> FilePath -> IO (Maybe FailureDetail)
admitObservedDirectRoot operation root = do
    observed <- observeDirectRoot root
    pure (either (Just . failed operation) (const Nothing) (admitDirectRoot root observed))

-- | Ask this host whether the declared provisioning image is reachable.
directEgressCommand :: String -> HostCommand
directEgressCommand image = hostCommand Docker ["manifest", "inspect", image]

{- | Carry an interpreted outcome to the bound route's own vocabulary.

The bound route reports bytes to a guest-execution caller rather than a
classification, so the two shapes meet exactly here.
-}
rawProviderOutcome :: Either String CapturedRun -> RawProviderOutcome
rawProviderOutcome (Left refusal) = RawProviderFailure refusal
rawProviderOutcome (Right run) =
    RawProviderExit (capturedExit run) (capturedStdout run) (capturedStderr run)

runBoundIncus ::
    HostConfig ->
    ProviderBackendSpec ->
    Text ->
    ProviderProbeRequest ->
    IO RawProviderOutcome
runBoundIncus cfg spec owner request = case providerProbeRequestView request of
    ProviderHostToolRequest Incus argv -> case spec of
        IncusBackendSpec{} -> rawProviderOutcome <$> interpretHostCommand cfg (hostCommand Incus argv)
        DirectHostBackendSpec{} -> pure (RawProviderFailure "invalid Incus backend state")
    ProviderHostToolRequest _ _ ->
        pure (RawProviderFailure "the bound Incus backend refused a different host tool")
    ProviderDirectProbeRequest _ ->
        pure (RawProviderFailure "the bound Incus backend refused a Direct-host probe")
    ProviderProvisioningEgressProbe -> case spec of
        IncusBackendSpec _ image _ _ _ _ _ _ ->
            rawProviderOutcome <$> interpretHostCommand cfg (hostCommand Incus ["image", "info", image])
        DirectHostBackendSpec{} -> pure (RawProviderFailure "invalid Incus backend state")
    ProviderGuestProbeRequest argv
        | null argv || any ('\0' `elem`) argv ->
            pure (RawProviderFailure "guest probe argv must be non-empty and contain no NUL")
        | otherwise -> do
            outcome <-
                withOwnedProviderTransaction cfg spec owner $
                    \session key owned -> execInOwnedInstance cfg session key owned argv
            pure (guestOutcome outcome)

{- | What a command run inside the owned instance produced.

A conflict travels as the marker the layers above this one already read, so a
provider replaced under the guest command is reported as a conflict rather than
as an ordinary failure; everything else is the failure it is.
-}
guestOutcome :: Either ProviderOwnershipFault CapturedRun -> RawProviderOutcome
guestOutcome (Right run) =
    RawProviderExit (capturedExit run) (capturedStdout run) (capturedStderr run)
guestOutcome (Left fault) =
    case ownedRefusal "run a command in the provider guest" "provider-guest" fault of
        RefusedForeign _ observed ->
            RawProviderFailure
                ( providerConflictMarker
                    "managed-provider-identity"
                    (foreignDetail observed)
                    "provider-replaced"
                )
        RefusedAbsent -> RawProviderFailure "the managed provider is absent"
        RefusedConflict detail ->
            RawProviderFailure
                ( providerConflictMarker
                    (conflictExpected detail)
                    (conflictObserved detail)
                    "provider-conflict"
                )
        RefusedUnsupported detail -> RawProviderFailure (Text.unpack (unsupportedReason detail))
        RefusedFailed detail -> RawProviderFailure (Text.unpack (failureCause detail))

foreignObservation :: Text -> String -> ForeignObservation
foreignObservation key identity =
    ForeignObservation key ("provider stable identity=" <> Text.pack identity)

conflict :: Text -> Text -> Text -> Text -> ConflictDetail
conflict key expected observed reason =
    ConflictDetail
        key
        expected
        observed
        ("inspect the provider origin and stable identity before retrying (" <> reason <> ")")

unsupported :: Text -> Text -> UnsupportedDetail
unsupported = UnsupportedDetail

failed :: Text -> Text -> FailureDetail
failed operation reason = FailureDetail operation reason ReprobeBeforeRetry


validWireToken :: String -> Bool
validWireToken value =
    not (null value)
        && length value <= 240
        && all (\character -> isAlphaNum character || character `elem` (":._/=-" :: String)) value

providerConflictMarker :: Text -> Text -> Text -> String
providerConflictMarker expected observed reason =
    if all (validWireToken . Text.unpack) [expected, observed, reason]
        then
            "HB_PROVIDER_CONFLICT "
                <> Text.unpack expected
                <> " "
                <> Text.unpack observed
                <> " "
                <> Text.unpack reason
        else "HB_PROVIDER_CONFLICT bounded-token invalid-token invalid-conflict-marker"

identityGeneration :: String -> Word64
identityGeneration = max 1 . foldl step 1469598103934665603
  where
    step acc character = (acc `xor` fromIntegral (fromEnum character)) * 1099511628211

