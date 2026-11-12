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
    mkLimaBackendSpec,
    mkWsl2BackendSpec,
    mkDirectHostBackendSpec,

    -- * The Direct realization's own admission
    DirectRootObservation (..),
    observeDirectRoot,
    directRootCanonicalFact,
    admitDirectRoot,
    directEgressCommand,

    -- * What a provider's own report means
    RawProviderOutcome (..),
    classifyProviderProvisionCall,
    classifyProviderReadyCall,
    classifyProviderStopCall,
    classifyProviderShareCall,
    classifyProviderDeleteCall,
    guestOutcome,

    -- * Clause-holding backend
    StrongProviderBackend,
    discoverStrongProviderBackend,
    providerBackendBinding,

    -- * Prepared backend calls
    runProviderProvisionCall,
    runProviderReadyCall,
    RunningProviderDependency,
    withRunningProviderDependency,
    runningProviderDependencyProbe,
    registerRunningProviderDependencyPackage,
    registerProviderShareDependencyPackage,
    withProviderShareDependency,
    providerShareDependencyProbe,
    runProviderStopCall,
    runProviderShareCall,
    runProviderDeleteCall,
    runRetainedProviderStop,
    runRetainedProviderReady,
    runRetainedProviderDelete,

    -- * Provider-bound discovery and guest execution
    withProviderBoundExec,
)
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Control.Monad (unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT, throwE)
import qualified Data.Bifunctor as Bifunctor
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString.Char8 as ByteString
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List (isPrefixOf, isSuffixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import HostBootstrap.Context (ResourceEnvelope)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Effect.Interpreter (interpretHostCommand)
import HostBootstrap.Effect.Run (CapturedRun (capturedExit, capturedStderr, capturedStdout))
import HostBootstrap.Effect.Vocabulary (HostCommand, hostCommand)
import HostBootstrap.HostConfig (HostConfig (hcSubstrate), resolveMaybe)
import HostBootstrap.HostTool (HostTool (Docker, Incus, Lima, Wsl), absExePath)
import HostBootstrap.Lifecycle.Dependency.Internal (
    RuntimeDependencyPackage,
    mkProviderRuntimeDependencyPackage,
    mkProviderShareRuntimeDependencyPackage,
    renderRuntimeDependencyProbeResponse,
    renderRuntimeDependencyProbeRefusal,
    withRuntimeDependencyProbeRequest,
 )
import HostBootstrap.Lifecycle.Execution.Internal (
    StepExecution,
    registerStepRuntimeDependencyPackage,
    registerStepRuntimeDependencyService,
    stepExecutionFrame,
    stepExecutionPlanDigest,
    stepExecutionRuntime,
 )
import HostBootstrap.Lifecycle.Prepared (
    PreparedGate,
    preparedGateCommitment,
    preparedGateOperation,
    preparedGatePlan,
 )
import HostBootstrap.Ownership.Object (
    ObjectIdentity,
    Origin (OriginAbsent, OriginPresent),
    objectIdentityText,
    ownershipFault,
 )
import qualified HostBootstrap.Ownership.Object as OwnedObject
import HostBootstrap.Ownership.Primitive (rowObserveIdentity, withOwnershipRow)
import HostBootstrap.Ownership.Row (ownershipRowForHost)
import HostBootstrap.Protected (
    ProtectedSession,
    RecordKey,
    openProtectedStore,
    protectedErrorMessage,
    withProtectedEntry,
 )
import HostBootstrap.Readiness (Micros, microsValue, seconds)
import HostBootstrap.Reconcile (
    ConflictDetail (..),
    FailureDetail (..),
    ForeignObservation (..),
    Provisioned,
    ReconcileError (..),
    RecoveryDisposition (DoNotRetry, ReprobeBeforeRetry),
    Running,
    UnsupportedDetail (..),
    resourceHandleGeneration,
    resourceHandleKey,
    validateOwnershipReceipt,
 )
import HostBootstrap.Substrate (HostFrame (WindowsFrame), SubstrateName (AppleSilicon, LinuxCpu), substrateFrame, substrateName)
import HostBootstrap.Substrate.Provider (
    HostPathShare,
    ProviderKind (ProviderDirectHost, ProviderIncus, ProviderLima, ProviderWsl2),
    SubstrateProvider,
    foldExistsProbe,
    hpsGuestPath,
    hpsHostPath,
    providerExistsProbe,
    providerKind,
    providerVmId,
    validConflictToken,
 )
import HostBootstrap.Substrate.Provider.Command (ProviderSizing (ProviderSizing))
import qualified HostBootstrap.Substrate.Provider.GuestVm as GuestVm
import HostBootstrap.Substrate.Provider.Dependency.Internal (
    RunningProviderDependency (..),
    ProviderShareDependency (..),
    runningProviderDependencyProbe,
    providerShareDependencyProbe,
    providerShareDependencyReprobe,
 )
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
    ManagedProviderShareHandle (..),
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
import HostBootstrap.Substrate.Provider.Ownership (
    OwnedProviderInstance (OwnedProviderInstance),
    OwnedProviderShare (OwnedProviderShare),
    ProviderDeleteOutcome (DeleteAlreadyRemoved, DeleteRemoved, DeleteStillPresent),
    ProviderOwnershipFault (
        ProviderOwnershipClause,
        ProviderOwnershipReport,
        ProviderOwnershipStanding,
        ProviderOwnershipStore,
        ProviderOwnershipSizing
    ),
    ProviderProvisionOutcome (ProvisionAlreadyOwned, ProvisionCreated, ProvisionRecovered),
    ProviderReadyOutcome (ReadyAlready, ReadyNotAnswering, ReadyStarted),
    ProviderShareOutcome (ShareAlreadyAttached, ShareAttached, ShareRepaired),
    ProviderStopOutcome (StopAlreadyStopped, StopStillRunning, StopStopped),
    attachOwnedShare,
    deleteOwnedInstance,
    deleteRetainedOwnedInstance,
    execInOwnedInstance,
    ownedInstanceRecordKey,
    ownedShareRecordKey,
    observeOwnedShare,
    provisionOwnedInstance,
    readyOwnedInstance,
    stopOwnedInstance,
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
    managedProviderObservationVersion,
    managedProviderShareGeneration,
    managedProviderShareObservationVersion,
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
    providerShareGuestPath,
    providerShareHostPath,
    withProviderPhaseAdvance,
 )
import HostBootstrap.Substrate.Provider.Report (
    identityObservationVersion,
    encodeProviderNativeObservation,
    encodeProviderNativeRefusal,
    incusQuantityBytes,
    declaredSizingText,
    observedSizingText,
    sizingConflictRemedy,
    ProviderReportFault (ProviderCommandExited, ProviderCommandUnrun),
    providerReportFaultMessage,
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
import System.Directory (
    Permissions (readable, searchable, writable),
    canonicalizePath,
    doesDirectoryExist,
    getPermissions,
    pathIsSymbolicLink,
 )
import System.Exit (ExitCode (..))
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
    | LimaBackendSpec SubstrateProvider ResourceEnvelope HostPathShare FilePath

instance Eq ProviderBackendSpec where
    left == right =
        backendSemanticFingerprint left == backendSemanticFingerprint right
            && backendRealizationFingerprint left == backendRealizationFingerprint right

instance Show ProviderBackendSpec where
    show spec =
        "ProviderBackendSpec "
            <> show (backendSemanticFingerprint spec)
            <> " "
            <> show (backendRealizationFingerprint spec)

{- | Validate the complete Incus instance declaration without probing the host.
The resolved executable and state directory must be absolute; the protected
store establishes the directory when a transaction enters it. Names use ASCII
hostnames and the share socket bounds their UTF-8 byte length. Quantities use
ASCII digits and an exact Incus byte suffix, within its signed 64-bit byte range.
Strong backend admission also requires the retained executable to match the
HostConfig that every later call uses.
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
    | ByteString.length (TextEncoding.encodeUtf8 (Text.pack name)) > maxIncusInstanceNameLength =
        invalid
            ( "the Incus instance name is longer than "
                <> Text.pack (show maxIncusInstanceNameLength)
                <> " UTF-8 bytes, so its share device socket path exceeds the platform limit"
            )
    | not (safeName name) = invalid "the Incus instance name must be an ASCII hostname: a-z, 0-9 and hyphen, starting with a letter and not ending with a hyphen"
    | not (safeGuardPrefix guardPrefix) = invalid "the destructive-delete guard prefix must be a non-empty ASCII hostname prefix starting with a letter"
    | not (guardPrefix `isPrefixOf` name) =
        invalid "the Incus instance name does not carry the project's destructive-delete guard prefix"
    | null image || '\0' `elem` image = invalid "the Incus image must be non-empty and contain no NUL"
    | not (hostAbsolutePath stateDirectory) = invalid "the provider state directory must be an absolute path on this host"
    | '\0' `elem` stateDirectory = invalid "the provider state directory must not contain NUL"
    | cpu == 0 = invalid "the provider CPU quantity must be positive"
    | not (safeQuantity memory) || not (safeQuantity storage) =
        invalid "provider memory and storage quantities must be ASCII digits with an Incus byte suffix and fit a signed 64-bit byte value"
    | otherwise = do
        executable <- requireTool Incus
        Right (IncusBackendSpec name image guardPrefix executable stateDirectory cpu memory storage)
  where
    invalid = Left . invalidBackend "Incus"
    requireTool tool = requireBackendTool "Incus" (Text.pack (show tool)) hostConfig tool

{- | Which guest-VM realization a backend construction is about.

Lima and WSL2 are one row of the frame table (§ LL), not two: the same guard
sequence over the same declaration, producing the same 'LimaBackendSpec'. What
actually differs is gathered here, so adding a third guest-VM provider is a new
value of this record rather than a third copy of the function beneath it.
-}
data GuestVmRealization = GuestVmRealization
    { guestVmLabel :: Text
    -- ^ how this realization is named in every refusal, e.g. @"Lima"@
    , guestVmHostAdmits :: HostConfig -> Bool
    -- ^ whether this host is the one that realizes it
    , guestVmHostRequirement :: Text
    -- ^ the host the refusal asks for, e.g. @"an apple-silicon HostConfig"@
    , guestVmKind :: ProviderKind
    -- ^ the closed provider realization this backend admits
    , guestVmNameNoun :: Text
    -- ^ what this realization calls the thing it names, e.g. @"instance name"@
    , guestVmTool :: HostTool
    -- ^ the host tool the backend needs resolved
    , guestVmToolLabel :: Text
    -- ^ how that tool is spelled in the refusal, e.g. @"WSL"@
    }

{- | The closed Lima realization used by the Apple host's universal @linux-cpu@
route.  The provider value owns its launch, existence, readiness, and
guest-shell vocabulary; callers supply no executable or argv.
-}
limaRealization :: GuestVmRealization
limaRealization =
    GuestVmRealization
        { guestVmLabel = "Lima"
        , guestVmHostAdmits = (== AppleSilicon) . substrateName . hcSubstrate
        , guestVmHostRequirement = "an apple-silicon HostConfig"
        , guestVmKind = ProviderLima
        , guestVmNameNoun = "instance name"
        , guestVmTool = Lima
        , guestVmToolLabel = "Lima"
        }

{- | The Windows WSL2 realization.  WSL's global wall remains owned by its typed host-effect
transaction. Distro creation and every readiness/share reprobe use the recorded
guest-VM transaction; the backend does not flatten the wall into an argv.
-}
wsl2Realization :: GuestVmRealization
wsl2Realization =
    GuestVmRealization
        { guestVmLabel = "WSL2"
        , -- The frame, not the accelerator row. Both Windows classifications
          -- realize the same WSL2 provider; keying on @WindowsGpu@ alone refused
          -- a @windows-cpu@ host outright, on the one substrate this project's
          -- own gates cannot observe. 'substrateFrame' is where the five
          -- classification tags collapse to the three frames, so asking it keeps
          -- that collapse in one place.
          guestVmHostAdmits = (== WindowsFrame) . substrateFrame . hcSubstrate
        , guestVmHostRequirement = "a Windows HostConfig"
        , guestVmKind = ProviderWsl2
        , guestVmNameNoun = "distro name"
        , guestVmTool = Wsl
        , guestVmToolLabel = "WSL"
        }

{- | Admit one guest-VM realization through the one closed guest-VM backend.

The exact resource envelope and writable share are retained in the backend
fingerprint, so the managed provider settlement cannot be rebound to another VM
budget or host root.
-}
mkGuestVmBackendSpec ::
    GuestVmRealization ->
    HostConfig ->
    SubstrateProvider ->
    ResourceEnvelope ->
    HostPathShare ->
    Either ReconcileError ProviderBackendSpec
mkGuestVmBackendSpec realization hostConfig provider envelope share
    | not (guestVmHostAdmits realization hostConfig) =
        invalid
            ("the " <> label <> " provider backend requires " <> guestVmHostRequirement realization)
    | providerKind provider /= guestVmKind realization =
        invalid ("the " <> label <> " backend requires the closed " <> label <> " provider realization")
    | null (providerVmId provider) || '\0' `elem` providerVmId provider =
        invalid
            ("the " <> label <> " " <> guestVmNameNoun realization <> " must be non-empty and contain no NUL")
    | not (hostAbsolutePath (hpsHostPath share)) || not (absolutePath (hpsGuestPath share)) =
        invalid ("the " <> label <> " writable share must have absolute host and guest paths")
    | otherwise = do
        executable <-
            requireBackendTool label (guestVmToolLabel realization) hostConfig (guestVmTool realization)
        Right (LimaBackendSpec provider envelope share executable)
  where
    label = guestVmLabel realization
    invalid = Left . invalidBackend label

-- | Admit the Lima realization. One application of 'mkGuestVmBackendSpec'.
mkLimaBackendSpec ::
    HostConfig ->
    SubstrateProvider ->
    ResourceEnvelope ->
    HostPathShare ->
    Either ReconcileError ProviderBackendSpec
mkLimaBackendSpec = mkGuestVmBackendSpec limaRealization

-- | Admit the WSL2 realization. The same row, a different application.
mkWsl2BackendSpec ::
    HostConfig ->
    SubstrateProvider ->
    ResourceEnvelope ->
    HostPathShare ->
    Either ReconcileError ProviderBackendSpec
mkWsl2BackendSpec = mkGuestVmBackendSpec wsl2Realization

-- | Admit the canonical already-local root.  No ownership is implied.
mkDirectHostBackendSpec :: HostConfig -> FilePath -> String -> Either ReconcileError ProviderBackendSpec
mkDirectHostBackendSpec hostConfig root egressImage
    | not (hostAbsolutePath root) =
        invalid "the direct-host root must be an absolute path on this host"
    | '\0' `elem` root = invalid "the direct-host root must not contain NUL"
    | null egressImage || '\0' `elem` egressImage =
        invalid "the Direct provider egress image must be non-empty and contain no NUL"
    | otherwise = do
        docker <- requireTool Docker
        Right (DirectHostBackendSpec root docker egressImage)
  where
    invalid = Left . invalidBackend "Direct"
    requireTool tool = requireBackendTool "Direct" (Text.pack (show tool)) hostConfig tool

{- | One backend construction's refusal of its own input.

All four constructors refuse in the same two shapes and differ only in which
backend they name, so the shapes are written here and the name is the argument.
-}
invalidBackend :: Text -> Text -> ReconcileError
invalidBackend label reason =
    Failure (FailureDetail ("validate " <> label <> " provider backend") reason DoNotRetry)

{- | The host tool a backend needs, or the refusal that it is not resolved.

An unresolved tool is 'Unsupported' rather than a 'Failure': the declaration was
well formed and this host simply cannot realize it.
-}
requireBackendTool ::
    -- | the backend's own label
    Text ->
    -- | how the tool is spelled in the refusal
    Text ->
    HostConfig ->
    HostTool ->
    Either ReconcileError FilePath
requireBackendTool label toolLabel hostConfig tool = case resolveMaybe hostConfig tool of
    Just executable -> Right (absExePath executable)
    Nothing ->
        Left
            ( Unsupported
                ( UnsupportedDetail
                    ("construct " <> label <> " provider backend")
                    ("the HostConfig has no resolved " <> toolLabel <> " executable")
                )
            )

safeName :: String -> Bool
safeName value = safeGuardPrefix value && not ("-" `isSuffixOf` value)

safeGuardPrefix :: String -> Bool
safeGuardPrefix [] = False
safeGuardPrefix (first : rest) =
    asciiLetter first && all (\character -> asciiLetter character || asciiDigit character || character == '-') rest
  where
    asciiLetter character = character >= 'a' && character <= 'z'

asciiDigit :: Char -> Bool
asciiDigit character = character >= '0' && character <= '9'

safeQuantity :: String -> Bool
safeQuantity = maybe False (const True) . incusQuantityBytes

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
    | StrongLimaBackend (ProviderBackendBinding backendId) HostConfig ProviderBackendSpec
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
    case retainedBackendClient spec of
        Left failure -> pure (Left failure)
        Right (label, tool, executable)
            | fmap absExePath (resolveMaybe cfg tool) /= Just executable ->
                pure (Left (invalidBackend label "the resolved client executable differs from the admitted provider backend"))
            | otherwise -> Right <$> consume (admitted spec)
  where
    binding = ProviderBackendBinding (backendSemanticFingerprint spec) (backendRealizationFingerprint spec)
    admitted DirectHostBackendSpec{} = StrongDirectHostBackend binding cfg spec
    admitted IncusBackendSpec{} = StrongIncusBackend binding cfg spec
    admitted LimaBackendSpec{} = StrongLimaBackend binding cfg spec

-- | Resolve every realization's retained client through the same closed rows.
retainedBackendClient :: ProviderBackendSpec -> Either ReconcileError (Text, HostTool, FilePath)
retainedBackendClient spec = case spec of
    IncusBackendSpec _ _ _ executable _ _ _ _ -> Right ("Incus", Incus, executable)
    DirectHostBackendSpec _ executable _ -> Right ("Direct", Docker, executable)
    LimaBackendSpec provider _ _ executable ->
        case filter ((== providerKind provider) . guestVmKind) [limaRealization, wsl2Realization] of
            [realization] -> Right (guestVmLabel realization, guestVmTool realization, executable)
            _ -> Left (invalidBackend "guest-VM" "the backend has no matching guest-VM realization")

providerBackendBinding :: StrongProviderBackend backendId -> ProviderBackendBinding backendId
providerBackendBinding backend = case backend of
    StrongIncusBackend binding _ _ -> binding
    StrongLimaBackend binding _ _ -> binding
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
    LimaBackendSpec provider envelope share _ ->
        framed
            [ "hostbootstrap/provider-backend/guest-vm/v1"
            , Text.pack (show (providerKind provider))
            , Text.pack (providerVmId provider)
            , Text.pack (show envelope)
            , Text.pack (hpsHostPath share)
            , Text.pack (hpsGuestPath share)
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
    LimaBackendSpec provider _ _ executable ->
        framed
            [ "hostbootstrap/provider-realization/guest-vm/v1"
            , Text.pack (show (providerKind provider))
            , Text.pack executable
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
    StrongLimaBackend _ cfg spec ->
        ProviderProvisionCallResult <$> runLimaProvision cfg spec binding
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
        RefusedForeign foreignGeneration observed _ _ ->
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
    StrongDirectHostBackend _ _ _ ->
        pure (ProviderReadyCallResult (ProviderReadyFailed (failed "reconcile Direct provider ready" "invalid Direct backend state")))
    StrongIncusBackend _ cfg spec ->
        ProviderReadyCallResult <$> pollProviderReady cfg spec binding 60
    StrongLimaBackend _ cfg spec ->
        ProviderReadyCallResult <$> pollLimaReady cfg spec binding 60
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
        RefusedForeign foreignGeneration observed _ _ ->
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
    ProviderPhaseAdvance scope planId backendId providerId fromPhase Running ->
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

{- | Publish the pending canonical provider commitment and its invocation-only
fresh-readiness service from one already-settled Ready transition.

The operation's own still-unacknowledged gate supplies the journal commitment:
this function runs inside the action, before @Chain@ acknowledges that gate.
The live closure captures the strong backend and exact managed handle only in
the separate service registry; neither can enter the canonical package.
-}
registerRunningProviderDependencyPackage ::
    StrongProviderBackend backendId ->
    StepExecution scope planId ->
    Text ->
    PreparedGate ->
    PreparedProviderReady scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion ->
    ProviderPhaseAdvance scope planId backendId providerId fromPhase Running ->
    Text ->
    Word64 ->
    IO (Either ReconcileError (RuntimeDependencyPackage scope planId))
registerRunningProviderDependencyPackage backend execution scopeCommitment gate prepared advance route expiry =
    withProviderPhaseAdvance advance $ \managed -> runExceptT $ do
        let binding = preparedProviderReadyBinding prepared
            runtime = stepExecutionRuntime execution
            refuse = Failure . failed "register provider runtime dependency"
        unless (preparedGatePlan gate == preparedProviderBindingPlanDigest binding)
            (throwE (refuse "the producer gate names another plan"))
        unless (preparedGateOperation gate == preparedProviderBindingOperationKey binding)
            (throwE (refuse "the producer gate names another operation"))
        native <- ExceptT (observeRunningProviderIdentity backend managed)
        stamp <- either (throwE . refuse . providerReportFaultMessage) pure
            (encodeProviderNativeObservation (providerReadyCommitment binding managed) native)
        package <- either (throwE . refuse) pure $
            mkProviderRuntimeDependencyPackage
                (stepExecutionPlanDigest execution) scopeCommitment
                (preparedProviderBindingResourceKey binding) (stepExecutionFrame execution)
                (preparedProviderBindingOwner binding) (managedProviderGeneration managed)
                (preparedGateCommitment gate) stamp route expiry
        ExceptT (fmap (Bifunctor.first (dependencyRegistrationConflict (preparedProviderBindingResourceKey binding)))
            (registerStepRuntimeDependencyPackage runtime package))
        usedNonces <- lift (newIORef [])
        installed <- lift $
            registerStepRuntimeDependencyService runtime package $ \request -> runExceptT $ do
                nonce <- ExceptT (pure (withRuntimeDependencyProbeRequest package request id))
                replay <- lift $ atomicModifyIORef' usedNonces $ \seen ->
                    if nonce `elem` seen then (seen, True) else (nonce : seen, False)
                when replay (throwE "runtime dependency probe nonce has already been consumed")
                observed <- lift (observeRunningProviderIdentity backend managed)
                let refuseNative failure = renderRuntimeDependencyProbeRefusal package nonce
                        (maybe (Text.pack (show failure)) id (encodeProviderNativeRefusal failure))
                ExceptT (pure (case observed of
                    Left failure -> refuseNative failure
                    Right actual
                        | actual /= native -> refuseNative (nativeIdentityConflict (managedProviderKey managed) native actual)
                        | otherwise -> Right (renderRuntimeDependencyProbeResponse package nonce
                            (identityObservationVersion (Text.unpack (objectIdentityText actual))))))

        either (throwE . dependencyRegistrationConflict (preparedProviderBindingResourceKey binding)) pure installed
        pure package

{- | Mint an opaque dependency from one exact settled share and its backend.
The retained action reobserves the backend when the dependency is used.
-}
withProviderShareDependency ::
    StrongProviderBackend backendId ->
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    ManagedProviderShareHandle scope planId backendId providerId shareId Provisioned ->
    (ProviderShareDependency scope planId shareId -> result) ->
    Either ReconcileError result
withProviderShareDependency backend prepared managed@(ManagedProviderShareHandle origin handle receipt settledCall) consume = do
    validateOwnershipReceipt handle receipt
    let binding = preparedProviderShareBinding prepared
        declared = preparedProviderShareHandle prepared
        key = resourceHandleKey handle
        mismatch = Conflict (ConflictDetail key "the exact prepared share and provider origin"
            "a different backend, origin, share declaration, key, or generation"
            "use the share settled from this backend and prepared operation")
    unless (sameBackendBinding (providerBackendBinding backend) (providerOriginBackendBinding origin)
        && providerOriginOwner origin == preparedProviderBindingOwner binding
        && settledCall == preparedProviderBindingCallDigest binding
        && key == resourceHandleKey declared
        && resourceHandleGeneration handle == resourceHandleGeneration declared)
        (Left mismatch)
    pure (consume (LocalProviderShareDependency managed
        (probeProviderShare backend prepared (resourceHandleGeneration handle))))

{- | Publish one settled provider-derived share and a nonce-bound fresh share
transaction for successor preconditions. The canonical package contains only
recovery coordinates; the strong backend, prepared call, and managed generation
remain exclusively in the invocation-local service closure.
-}
registerProviderShareDependencyPackage ::
    StrongProviderBackend backendId ->
    StepExecution scope planId ->
    Text ->
    PreparedGate ->
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    ManagedProviderShareHandle scope planId backendId providerId shareId Provisioned ->
    Text ->
    Word64 ->
    IO (Either ReconcileError (RuntimeDependencyPackage scope planId))
registerProviderShareDependencyPackage backend execution scopeCommitment gate prepared managed route expiry =
    case withProviderShareDependency backend prepared managed id of
        Left failure -> pure (Left failure)
        Right dependency -> register dependency
  where
    register dependency = do
        let binding = preparedProviderShareBinding prepared
            runtime = stepExecutionRuntime execution
        case () of
            _
                | preparedGatePlan gate /= preparedProviderBindingPlanDigest binding ->
                    pure (Left (Failure (failed "register provider share runtime dependency" "the producer gate names another plan")))
                | preparedGateOperation gate /= preparedProviderBindingOperationKey binding ->
                    pure (Left (Failure (failed "register provider share runtime dependency" "the producer gate names another operation")))
                | otherwise ->
                    case mkProviderShareRuntimeDependencyPackage
                        (stepExecutionPlanDigest execution)
                        scopeCommitment
                        (resourceHandleKey (preparedProviderShareHandle prepared))
                        (stepExecutionFrame execution)
                        (preparedProviderBindingOwner binding)
                        (managedProviderShareGeneration managed)
                        (preparedGateCommitment gate)
                        (providerShareCommitment binding managed)
                        route
                        expiry of
                        Left refusal -> pure (Left (Failure (failed "register provider share runtime dependency" refusal)))
                        Right package -> do
                            registered <- registerStepRuntimeDependencyPackage runtime package
                            case registered of
                                Left refusal -> pure (Left (dependencyRegistrationConflict (resourceHandleKey (preparedProviderShareHandle prepared)) refusal))
                                Right () -> do
                                    usedNonces <- newIORef []
                                    installed <-
                                        registerStepRuntimeDependencyService runtime package $ \request ->
                                            case withRuntimeDependencyProbeRequest package request id of
                                                Left refusal -> pure (Left refusal)
                                                Right nonce -> do
                                                    replay <-
                                                        atomicModifyIORef' usedNonces $ \seen ->
                                                            if nonce `elem` seen
                                                                then (seen, True)
                                                                else (nonce : seen, False)
                                                    if replay
                                                        then pure (Left "runtime dependency probe nonce has already been consumed")
                                                        else
                                                            either
                                                                (Left . Text.pack . show)
                                                                (Right . renderRuntimeDependencyProbeResponse package nonce)
                                                                <$> providerShareDependencyReprobe dependency
                                    pure $ case installed of
                                        Left refusal -> Left (dependencyRegistrationConflict (resourceHandleKey (preparedProviderShareHandle prepared)) refusal)
                                        Right () -> Right package

dependencyRegistrationConflict :: Text -> Text -> ReconcileError
dependencyRegistrationConflict key refusal = Conflict (ConflictDetail key
    "one exact canonical dependency package and retained live service" refusal
    "reuse the exact package, route and invocation")

providerReadyCommitment ::
    PreparedProviderBinding scope planId backendId providerId ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    Text
providerReadyCommitment binding managed =
    providerCommitment
        "ready"
        [ preparedProviderBindingCallDigest binding
        , Text.pack (show (managedProviderObservationVersion managed))
        ]

providerShareCommitment ::
    PreparedProviderBinding scope planId backendId providerId ->
    ManagedProviderShareHandle scope planId backendId providerId shareId Provisioned ->
    Text
providerShareCommitment binding managed =
    providerCommitment
        "share"
        [ preparedProviderBindingCallDigest binding
        , Text.pack (show (managedProviderShareObservationVersion managed))
        ]

providerCommitment :: Text -> [Text] -> Text
providerCommitment domain fields =
    Text.pack (ByteString.unpack (convertToBase Base16 digest))
  where
    framed value = Text.pack (show (Text.length value)) <> ":" <> value
    digest = hash (ByteString.pack (Text.unpack (Text.concat (map framed ("hostbootstrap/provider-runtime/" <> domain <> "/v1" : fields))))) :: Digest SHA256

-- The positive word is a native observation version, never a plan generation.
probeRunningProvider ::
    StrongProviderBackend backendId ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    IO (Either ReconcileError Word64)
probeRunningProvider backend managed =
    fmap (fmap (identityObservationVersion . Text.unpack . objectIdentityText))
        (observeRunningProviderIdentity backend managed)

observeRunningProviderIdentity ::
    StrongProviderBackend backendId ->
    ManagedProviderHandle scope planId backendId providerId Running ->
    IO (Either ReconcileError ObjectIdentity)
observeRunningProviderIdentity backend managed = case backend of
    StrongDirectHostBackend _ cfg (DirectHostBackendSpec root _ image) -> runExceptT $ do
        before <- ExceptT (observeDirectProviderIdentity key root)
        egress <- lift (interpretHostCommand cfg (directEgressCommand image))
        maybe (pure ()) (throwE . Failure)
            (directReadyProbeFailure "reprobe Direct provider provisioning egress" egress)
        after <- ExceptT (observeDirectProviderIdentity key root)
        unless (before == after) (throwE (nativeIdentityConflict key before after))
        pure after
    StrongDirectHostBackend _ _ _ ->
        pure (Left (Failure (failed "reprobe Direct provider" "invalid Direct backend state")))
    StrongIncusBackend _ cfg spec ->
        fmap (nativeReadyIdentity key) $
            withOwnedProviderTransaction cfg spec (managedOriginOwner managed) $
                \session record owned -> readyOwnedInstance cfg session record owned
    StrongLimaBackend _ cfg spec ->
        fmap (nativeReadyIdentity key)
            (withOwnedGuestVm spec (managedOriginOwner managed) (GuestVm.readyOwnedGuestVm cfg))
  where
    key = managedProviderKey managed

-- Observe the plan-local Direct root; this claims no ownership of the host.
observeDirectProviderIdentity :: Text -> FilePath -> IO (Either ReconcileError ObjectIdentity)
observeDirectProviderIdentity key root = do
    permission <- admitObservedDirectRoot "reprobe the exact Direct provider root" root
    case permission of
        Just failure -> pure (Left (Failure failure))
        Nothing -> do
            observed <- withOwnershipRow ownershipRowForHost (\row -> rowObserveIdentity row root)
            pure $ case observed of
                Left fault -> nativeReadyIdentity key (Left (ProviderOwnershipClause fault))
                Right Nothing -> Left (Failure (failed "reprobe Direct provider" "the admitted root is absent"))
                Right (Just identity) -> Right identity

nativeReadyIdentity ::
    Text -> Either ProviderOwnershipFault ProviderReadyOutcome -> Either ReconcileError ObjectIdentity
nativeReadyIdentity key outcome = case outcome of
    Right (ReadyStarted identity) -> Right identity
    Right (ReadyAlready identity) -> Right identity
    Right (ReadyNotAnswering reason) -> Left (Failure (failed "reprobe running provider" reason))
    Left fault -> case ownedRefusal "reconcile provider ready" key fault of
        RefusedForeign _ _ expected actual -> Left (Conflict (ConflictDetail key
            ("identity=" <> Text.pack (show expected)) ("identity=" <> Text.pack (show actual))
            "reconcile the replacement provider before any dependent mutation"))
        RefusedAbsent -> Left (Failure (failed "reprobe running provider" "the provider is absent"))
        RefusedConflict detail -> Left (Conflict detail)
        RefusedUnsupported detail -> Left (Unsupported detail)
        RefusedFailed detail -> Left (Failure detail)

nativeIdentityConflict :: Text -> ObjectIdentity -> ObjectIdentity -> ReconcileError
nativeIdentityConflict key expected actual = Conflict (ConflictDetail key
    ("identity=" <> objectIdentityText expected) ("identity=" <> objectIdentityText actual)
    "reconcile the provider identity before any dependent mutation")

managedOriginOwner :: ManagedProviderHandle scope planId backendId providerId phase -> Text
managedOriginOwner (ManagedProviderHandle origin _ _) = providerOriginOwner origin

{- | Whether an exact Direct probe answered at all.

An application of the one report classifier: a probe that produced no child,
exited non-zero, or complained on the wrong stream is a failure, and anything it
wrote on standard output is not read, because the probe's answer /is/ its exit
status.
-}
directReadyProbeFailure :: Text -> Either String CapturedRun -> Maybe FailureDetail
directReadyProbeFailure operation captured = case captured of
    Left refusal -> Just (failed operation ("the exact probe did not run: " <> Text.pack refusal))
    Right run -> case capturedExit run of
        ExitFailure code ->
            Just
                ( failed
                    operation
                    ( "the exact probe exited "
                        <> Text.pack (show code)
                        <> ": "
                        <> Text.pack (firstOutputLine (capturedStderr run))
                    )
                )
        ExitSuccess
            | not (null (capturedStderr run)) ->
                Just (failed operation ("the exact probe wrote stderr: " <> Text.pack (firstOutputLine (capturedStderr run))))
            | otherwise -> Nothing
  where
    firstOutputLine = takeWhile (/= '\n')

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

-- Every guest-VM operation reconstructs ordinary coordinates, then enters the
-- same recorded transaction. WSL's global wall remains its separate typed owner.
withOwnedGuestVm ::
    ProviderBackendSpec ->
    Text ->
    (GuestVm.OwnedGuestVm -> IO (Either ProviderOwnershipFault value)) ->
    IO (Either ProviderOwnershipFault value)
withOwnedGuestVm (LimaBackendSpec provider envelope share _) owner action
    | Context.cpu envelope > fromIntegral (maxBound :: Word64) =
        pure (Left (ProviderOwnershipClause (OwnedObject.OwnershipMalformed
            "the guest-VM CPU quantity exceeds its provider representation")))
    | otherwise =
        action (GuestVm.OwnedGuestVm provider
            (ProviderSizing (fromIntegral (Context.cpu envelope)) (Text.unpack (Context.memory envelope)) (Text.unpack (Context.storage envelope)))
            share owner)
withOwnedGuestVm _ _ _ = pure (Left (ProviderOwnershipReport
    (ProviderCommandUnrun "the guest-VM transaction received a non-VM backend")))

runLimaProvision ::
    HostConfig ->
    ProviderBackendSpec ->
    PreparedProviderBinding scope planId backendId providerId ->
    IO ProviderProvisionObservation
runLimaProvision cfg spec binding =
    provisionObservation binding <$> withOwnedGuestVm spec (preparedProviderBindingOwner binding)
        (GuestVm.provisionOwnedGuestVm cfg)

pollLimaReady ::
    HostConfig ->
    ProviderBackendSpec ->
    PreparedProviderBinding scope planId backendId providerId ->
    Int ->
    IO ProviderReadyObservation
pollLimaReady cfg spec binding remaining = do
    observation <- observeLimaReady cfg spec binding
    case observation of
        waiting@(ProviderReadyNotReady _)
            | remaining > 1 -> case seconds 1 of
                Left _ -> pure waiting
                Right delay -> providerBackendWait delay >> pollLimaReady cfg spec binding (remaining - 1)
        other -> pure other

observeLimaReady ::
    HostConfig ->
    ProviderBackendSpec ->
    PreparedProviderBinding scope planId backendId providerId ->
    IO ProviderReadyObservation
observeLimaReady cfg spec binding =
    readyObservation (preparedProviderBindingResourceKey binding) (preparedProviderBindingGeneration binding)
        <$> withOwnedGuestVm spec (preparedProviderBindingOwner binding) (GuestVm.readyOwnedGuestVm cfg)

observeGuestVmShare ::
    HostConfig ->
    ProviderBackendSpec ->
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    IO ProviderShareObservation
observeGuestVmShare cfg spec@(LimaBackendSpec _ _ retainedShare _) prepared
    | source /= hpsHostPath retainedShare || target /= hpsGuestPath retainedShare =
        pure
            ( ProviderShareConflict
                ( ConflictDetail
                    "guest-vm-provider-share"
                    (Text.pack (hpsHostPath retainedShare <> " -> " <> hpsGuestPath retainedShare))
                    (Text.pack (source <> " -> " <> target))
                    "use the writable share retained by this exact guest-VM provider backend"
                )
            )
    | otherwise = do
        directory <- runOwnedGuestVm cfg spec owner ["test", "-d", target]
        captured <- case directory of
            RawProviderExit ExitSuccess _ _ -> runOwnedGuestVm cfg spec owner ["test", "-w", target]
            refusal -> pure refusal
        pure $ case captured of
            RawProviderExit ExitSuccess _ _ -> ProviderShareAlreadyReady generation
            RawProviderExit (ExitFailure code) _ err ->
                ProviderShareFailed
                    (failed "reprobe guest-VM provider share" (providerReportFaultMessage (ProviderCommandExited code (Text.pack err))))
            RawProviderFailure refusal -> ProviderShareFailed (failed "reprobe guest-VM provider share" (Text.pack refusal))
  where
    owner = preparedProviderBindingOwner (preparedProviderShareBinding prepared)
    shareSpec = preparedProviderShareSpec prepared
    source = providerShareHostPath shareSpec
    target = providerShareGuestPath shareSpec
    generation = resourceHandleGeneration (preparedProviderShareHandle prepared)
observeGuestVmShare _ _ prepared =
    pure
        ( ProviderShareFailed
            (failed "reprobe guest-VM provider share" ("invalid guest-VM backend state for " <> resourceHandleKey (preparedProviderShareHandle prepared)))
        )

runOwnedGuestVm :: HostConfig -> ProviderBackendSpec -> Text -> [String] -> IO RawProviderOutcome
runOwnedGuestVm cfg spec owner argv =
    guestOutcome <$> withOwnedGuestVm spec owner (\owned -> GuestVm.execInOwnedGuestVm cfg owned argv)

-- ---------------------------------------------------------------------------
-- Owned provider transactions

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
withOwnedProviderTransaction _cfg spec owner transaction =
    case providerOwnershipAddress spec owner of
        Left fault -> pure (Left fault)
        Right (stateDirectory, key, owned) -> do
            opened <- openProtectedStore stateDirectory
            case opened of
                Left failure -> pure (Left (ProviderOwnershipStore failure))
                Right store -> do
                    outcome <-
                        withProtectedEntry
                            store
                            (\session -> Right <$> transaction session key owned)
                    pure (either (Left . ProviderOwnershipStore) id outcome)

-- | Admit the complete instance address without opening its store or a driver.
providerOwnershipAddress ::
    ProviderBackendSpec ->
    Text ->
    Either ProviderOwnershipFault (FilePath, RecordKey, OwnedProviderInstance)
providerOwnershipAddress (DirectHostBackendSpec{}) _owner =
    Left
        ( ProviderOwnershipReport
            (ProviderCommandUnrun "the Direct realization owns no provider instance to enter")
        )
providerOwnershipAddress (LimaBackendSpec{}) _owner =
    Left
        ( ProviderOwnershipReport
            (ProviderCommandUnrun "the Lima realization is journaled by the plan interpreter rather than the Incus ownership store")
        )
providerOwnershipAddress
    (IncusBackendSpec name image guardPrefix _executable stateDirectory cpu memory storage)
    owner = do
        let owned = OwnedProviderInstance name image guardPrefix (ProviderSizing cpu memory storage) owner
        key <- either (Left . ProviderOwnershipStore) Right (ownedInstanceRecordKey owned)
        pure (stateDirectory, key, owned)

{- | Run one owned-share transaction inside the instance's own store.

The share's record lives beside the instance's, under its own key, because a
share is an object of its own: a record that meant two things could not tell a
resumed entry which of them it had published. Admit the complete share address
before the instance transaction can create store metadata; that transaction
then attaches exactly the share and key admitted here.
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
    case providerOwnershipAddress spec owner of
        Left fault -> pure (Left fault)
        Right (_, _, owned) ->
            let share = OwnedProviderShare owned device source target binding
             in case ownedShareRecordKey share of
                    Left failure -> pure (Left (ProviderOwnershipStore failure))
                    Right shareKey ->
                        withOwnedProviderTransaction cfg spec owner $ \session _key _owned ->
                            attachOwnedShare cfg session shareKey share

{- | The five shapes a refused ownership transaction takes at a provider call.

Written once over the closed fault sum, because "the instance vanished", "a
different instance stands at the name", and "the record under this key is
somebody else's" mean the same thing to every verb; what differs per verb is only
which of its own constructors carries each, which is five lines rather than five
copies of this decision.
-}
data OwnedProviderRefusal
    = RefusedForeign Word64 ForeignObservation Origin ObjectIdentity
    | RefusedAbsent
    | RefusedConflict ConflictDetail
    | RefusedUnsupported UnsupportedDetail
    | RefusedFailed FailureDetail

ownedRefusal :: Text -> Text -> ProviderOwnershipFault -> OwnedProviderRefusal
ownedRefusal operation key fault = case fault of
    ProviderOwnershipStanding standing -> case standing of
        InstanceUnderNoRecord observed -> refusedForeign OriginAbsent observed
        InstanceUnderAnotherClaim expected observed ->
            RefusedConflict
                (conflict key expected observed "inspect the instance's own owner claim")
        InstanceReplaced expected observed -> refusedForeign (OriginPresent expected) observed
        InstanceVanished _ -> RefusedAbsent
        RecordNotAClaimedObject described ->
            RefusedConflict
                ( conflict
                    key
                    "a durable record about a provider instance"
                    described
                    "inspect the durable record under this instance's key"
                )
        RecordNamesAPriorInstance observed -> refusedForeign OriginAbsent observed
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
    ProviderOwnershipSizing declared observed ->
        RefusedConflict (ConflictDetail key (declaredSizingText declared) (observedSizingText observed) sizingConflictRemedy)
    ProviderOwnershipReport reportFault ->
        RefusedFailed (failed operation (providerReportFaultMessage reportFault))
    ProviderOwnershipStore storeFailure ->
        RefusedFailed (failed operation (protectedErrorMessage storeFailure))
  where
    refusedForeign expected observed =
        let rendered = Text.unpack (objectIdentityText observed)
         in RefusedForeign (identityObservationVersion rendered) (foreignObservation key rendered) expected observed

-- | One rendering of a conflict's side, so both sides read the same way.
originSide :: Origin -> Text
originSide OriginAbsent = "absent"
originSide (OriginPresent identity) = "identity=" <> objectIdentityText identity

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
    StrongLimaBackend _ _ _ ->
        pure
            ( ProviderStopCallResult
                ( ProviderStopUnsupported
                    (UnsupportedDetail "stop Lima provider through a forward handle" "Lima reverse is owned by the plan's retained step-declared adapter")
                )
            )
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
                RefusedForeign foreignGeneration observed _ _ ->
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
    StrongLimaBackend _ cfg spec ->
        ProviderShareCallResult <$> observeGuestVmShare cfg spec prepared
    StrongDirectHostBackend _ _ _ ->
        pure (ProviderShareCallResult (ProviderShareFailed (failed "reconcile provider share" "invalid Direct backend state")))
  where
    binding = preparedProviderShareBinding prepared
    shareGeneration = resourceHandleGeneration (preparedProviderShareHandle prepared)
    source = providerShareHostPath shareSpec
    target = providerShareGuestPath shareSpec
    shareSpec = preparedProviderShareSpec prepared

probeProviderShare ::
    StrongProviderBackend backendId ->
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    Word64 ->
    IO (Either ReconcileError Word64)
probeProviderShare backend prepared expectedGeneration = do
    ProviderShareCallResult observation <- case backend of
        StrongIncusBackend _ cfg spec -> do
            let binding = preparedProviderShareBinding prepared
                shareSpec = preparedProviderShareSpec prepared
                owner = preparedProviderBindingOwner binding
            outcome <- case providerOwnershipAddress spec owner of
                Left fault -> pure (Left fault)
                Right (_, _, owned) ->
                    let share = OwnedProviderShare owned (shareDeviceName prepared)
                            (providerShareHostPath shareSpec) (providerShareGuestPath shareSpec)
                            (preparedShareBinding prepared)
                     in withOwnedProviderTransaction cfg spec owner $ \session instanceKey ownedInstance -> do
                            first <- observeOwnedShare cfg session share
                            case first of
                                Left fault -> pure (Left fault)
                                Right identity -> do
                                    mount <- execInOwnedInstance cfg session instanceKey ownedInstance "findmnt"
                                        ["-n", "-o", "FSTYPE", "--mountpoint", providerShareGuestPath shareSpec]
                                    case mount of
                                        Left fault -> pure (Left fault)
                                        Right report
                                            | capturedExit report /= ExitSuccess
                                                || lines (capturedStdout report) /= ["virtiofs"]
                                                || not (null (capturedStderr report)) -> pure (Left guestShareNotReady)
                                            | otherwise -> do
                                                writeCheck <- execInOwnedInstance cfg session instanceKey ownedInstance "test"
                                                    ["-w", providerShareGuestPath shareSpec]
                                                case writeCheck of
                                                    Left fault -> pure (Left fault)
                                                    Right check
                                                        | capturedExit check /= ExitSuccess
                                                            || not (null (capturedStdout check))
                                                            || not (null (capturedStderr check)) -> pure (Left guestShareNotReady)
                                                        | otherwise -> do
                                                            second <- observeOwnedShare cfg session share
                                                            pure $ case second of
                                                                Right current | current == identity -> Right identity
                                                                Right _ -> Left guestShareNotReady
                                                                Left fault -> Left fault
            pure (classifyProviderShareCall prepared (ShareAlreadyAttached <$ outcome))
        _ -> runProviderShareCall backend prepared
    pure $ case observation of
        ProviderShareAttached generation -> accept generation
        ProviderShareRepaired generation -> accept generation
        ProviderShareAlreadyReady generation -> accept generation
        ProviderShareDirectLocal generation -> accept generation
        ProviderShareForeign generation foreignState ->
            Left (Conflict (ConflictDetail key ("generation=" <> Text.pack (show expectedGeneration)) ("foreign generation=" <> Text.pack (show generation) <> "; " <> foreignDetail foreignState) "restore the owned provider share before using its dependency"))
        ProviderShareAbsent -> Left (Failure (failed "reprobe provider share" "the exact provider share is absent"))
        ProviderShareProviderReplaced generation foreignState ->
            Left (Conflict (ConflictDetail key ("generation=" <> Text.pack (show expectedGeneration)) ("provider generation=" <> Text.pack (show generation) <> "; " <> foreignDetail foreignState) "reconcile the provider and share before using their dependency"))
        ProviderShareConflict detail -> Left (Conflict detail)
        ProviderShareUnsupported detail -> Left (Unsupported detail)
        ProviderShareFailed detail -> Left (Failure detail)
  where
    key = resourceHandleKey (preparedProviderShareHandle prepared)
    accept generation
        | generation == expectedGeneration = Right generation
        | otherwise =
            Left
                ( Conflict
                    ( ConflictDetail
                        key
                        ("generation=" <> Text.pack (show expectedGeneration))
                        ("fresh generation=" <> Text.pack (show generation))
                        "reconcile the provider share generation before using its dependency"
                    )
                )

guestShareNotReady :: ProviderOwnershipFault
guestShareNotReady = ProviderOwnershipClause
    (OwnedObject.OwnershipProbeFailed "observe the guest share mount"
        "the exact guest target is not a writable virtiofs mount")

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
                RefusedForeign foreignGeneration observed _ _ ->
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
    digest = hash (TextEncoding.encodeUtf8 (preparedShareBinding prepared)) :: Digest SHA256

{- | The share device is named from a bounded share-binding digest.
The same prepared share addresses the same device. A truncated digest does
not rule out collisions: the owned share transaction's exact device readback
refuses a same-named device carrying another binding before mutation.
The name is bounded because it is a component of a POSIX unix-domain socket
pathname (see 'maxIncusInstanceNameLength').
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
bounds the instance name's UTF-8 byte length by what remains.
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
    StrongLimaBackend _ _ _ ->
        pure
            ( ProviderDeleteCallResult
                ( ProviderDeleteUnsupported
                    (UnsupportedDetail "delete Lima provider through a forward handle" "Lima reverse is owned by the plan's retained step-declared adapter")
                )
            )
  where
    binding = preparedProviderDeleteBinding prepared

{- | Re-enter the provider's retained ownership record for reverse execution.

The recursive reverse command has the exact retained plan and journal, but no
forward action-local managed handle.  The protected provider record is the
durable clause-2/3 authority at this boundary, so these operations derive the
claim and identity from that record and refuse a replacement.  They are kept
separate from prepared forward calls: no caller-supplied generation or owner is
accepted here.
-}
runRetainedProviderStop ::
    StrongProviderBackend backendId ->
    IO (Either ReconcileError ())
runRetainedProviderStop backend = case backend of
    StrongDirectHostBackend _ _ _ ->
        pure (Left (Unsupported (UnsupportedDetail "stop Direct provider" "the local host is not project-owned and cannot be stopped")))
    StrongIncusBackend _ cfg spec@(IncusBackendSpec name _ _ _ _ _ _ _) -> do
        outcome <-
            withOwnedProviderTransaction cfg spec "" $
                \session key owned -> stopOwnedInstance cfg session key owned
        pure $ case outcome of
            Right (StopStopped _) -> Right ()
            Right (StopAlreadyStopped _) -> Right ()
            Right (StopStillRunning reason) -> Left (Failure (failed "stop retained provider" reason))
            Left fault -> Left (retainedProviderFault "stop retained provider" (Text.pack name) fault)
    StrongIncusBackend _ _ _ ->
        pure (Left (Failure (failed "stop retained provider" "invalid Incus backend state")))
    StrongLimaBackend _ _ _ ->
        pure (Left (Unsupported (UnsupportedDetail "stop retained Lima provider" "Lima reverse is owned by the plan's retained step-declared adapter")))

{- | Re-enter the retained ownership record and make the provider reachable.

The peer of 'runRetainedProviderStop', for the other direction. A @down@ stops
the provider and leaves its children retained inside it; the @destroy@ that
follows cannot unwind them through a stopped frame, so its pre-descent
reachability step comes here first. Like its peer it derives claim and identity
from the durable record alone and refuses a replacement, and like the forward
readiness path it re-observes before starting and then asks the guest itself
whether it answers — an instance that is running but not yet answering is polled
rather than assumed.
-}
runRetainedProviderReady ::
    StrongProviderBackend backendId ->
    IO (Either ReconcileError ())
runRetainedProviderReady backend = case backend of
    StrongDirectHostBackend _ _ _ ->
        pure (Left (Unsupported (UnsupportedDetail "start Direct provider" "the local host is not project-owned and is already reachable")))
    StrongIncusBackend _ cfg spec@(IncusBackendSpec name _ _ _ _ _ _ _) ->
        poll cfg spec (Text.pack name) (60 :: Int)
    StrongIncusBackend _ _ _ ->
        pure (Left (Failure (failed "start retained provider" "invalid Incus backend state")))
    StrongLimaBackend _ _ _ ->
        pure (Left (Unsupported (UnsupportedDetail "start retained Lima provider" "Lima reverse is owned by the plan's retained step-declared adapter")))
  where
    poll cfg spec name remaining = do
        outcome <-
            withOwnedProviderTransaction cfg spec "" $
                \session key owned -> readyOwnedInstance cfg session key owned
        case outcome of
            Right (ReadyStarted _) -> pure (Right ())
            Right (ReadyAlready _) -> pure (Right ())
            Right (ReadyNotAnswering reason)
                | remaining > 1 -> case seconds 1 of
                    Left _ -> pure (Left (Failure (failed "start retained provider" reason)))
                    Right delay -> providerBackendWait delay >> poll cfg spec name (remaining - 1)
                | otherwise -> pure (Left (Failure (failed "start retained provider" reason)))
            Left fault -> pure (Left (retainedProviderFault "start retained provider" name fault))

runRetainedProviderDelete ::
    StrongProviderBackend backendId ->
    IO (Either ReconcileError ())
runRetainedProviderDelete backend = case backend of
    StrongDirectHostBackend _ _ _ ->
        pure (Left (Unsupported (UnsupportedDetail "delete Direct provider" "the local host is not project-owned and cannot be deleted")))
    StrongIncusBackend _ cfg spec@(IncusBackendSpec name _ _ _ _ _ _ _) -> do
        outcome <-
            withOwnedProviderTransaction cfg spec "" $
                \session key owned -> deleteRetainedOwnedInstance cfg session key owned
        pure $ case outcome of
            Right DeleteRemoved -> Right ()
            Right DeleteAlreadyRemoved -> Right ()
            Right DeleteStillPresent -> Left (Failure (failed "delete retained provider" "the exact managed provider remains present"))
            Left fault -> Left (retainedProviderFault "delete retained provider" (Text.pack name) fault)
    StrongIncusBackend _ _ _ ->
        pure (Left (Failure (failed "delete retained provider" "invalid Incus backend state")))
    StrongLimaBackend _ _ _ ->
        pure (Left (Unsupported (UnsupportedDetail "delete retained Lima provider" "Lima reverse is owned by the plan's retained step-declared adapter")))

retainedProviderFault :: Text -> Text -> ProviderOwnershipFault -> ReconcileError
retainedProviderFault operation key fault = case ownedRefusal operation key fault of
    RefusedForeign _ observation _ _ ->
        Conflict
            ( ConflictDetail
                key
                "the identity bound by the retained provider record"
                (foreignDetail observation)
                "inspect the provider name and retained ownership record"
            )
    RefusedAbsent -> Failure (failed operation "the retained provider disappeared during the ownership transaction")
    RefusedConflict detail -> Conflict detail
    RefusedUnsupported detail -> Unsupported detail
    RefusedFailed detail -> Failure detail

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
                RefusedForeign foreignGeneration observed _ _ ->
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
    let (spec, run) = case backend of
            StrongDirectHostBackend _ cfg retained -> (retained, runBoundDirect cfg retained)
            StrongIncusBackend _ cfg retained -> (retained, runBoundIncus cfg retained (providerOriginOwner origin))
            StrongLimaBackend _ cfg retained -> (retained, runBoundLima cfg retained (providerOriginOwner origin))
    route <- providerBoundRouteFor spec
    pure (consume (bindProviderBoundExec route run providerBackendWait))

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
        StrongLimaBackend binding _ _ -> binding
        StrongDirectHostBackend binding _ _ -> binding

sameBackendBinding :: ProviderBackendBinding backendId -> ProviderBackendBinding backendId -> Bool
sameBackendBinding left right =
    providerBackendSemanticFingerprint left == providerBackendSemanticFingerprint right
        && providerBackendRealizationFingerprint left == providerBackendRealizationFingerprint right

-- | Only the two admitted guest kinds describe a guest-VM route. Keep this
-- closed match exhaustive so another provider kind requires an explicit route.
providerBoundRouteFor :: ProviderBackendSpec -> Either ReconcileError ProviderBoundRoute
providerBoundRouteFor spec = case spec of
    IncusBackendSpec name image _ _ _ _ _ _ -> Right (ProviderBoundIncusRoute name image)
    LimaBackendSpec provider _ _ _ -> case providerKind provider of
        ProviderLima -> Right (ProviderBoundLimaRoute (providerVmId provider))
        ProviderWsl2 -> Right (ProviderBoundWsl2Route (providerVmId provider))
        ProviderIncus -> invalidGuestKind
        ProviderDirectHost -> invalidGuestKind
    DirectHostBackendSpec root _ egressImage -> Right (ProviderBoundDirectRoute root egressImage)
  where
    invalidGuestKind =
        Left (Failure (failed "bind provider route" "the guest-VM backend retained a non-VM provider kind"))

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
    (LimaBackendSpec{}, _) ->
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
§ KK refuses.  Unavailable filesystem observations contribute refusing admission facts.
An uncertain link check refuses an unfollowed directory, and failed
canonicalization contributes no canonical-path fact.
-}
observeDirectRoot :: FilePath -> IO DirectRootObservation
observeDirectRoot root = do
    link <- quietly True (pathIsSymbolicLink root)
    directory <- quietly False (doesDirectoryExist root)
    canonical <- quietly Nothing (Just <$> canonicalizePath root)
    accessible <-
        if directory
            then quietly False (fmap admits (getPermissions root))
            else pure False
    pure
        DirectRootObservation
            { directRootAbsolute = isAbsolute root
            , directRootSymbolicLink = link
            , directRootDirectory = directory
            , directRootCanonical = directRootCanonicalFact root canonical
            , directRootAccessible = accessible
            }
  where
    admits permissions = readable permissions && writable permissions && searchable permissions
    quietly :: value -> IO value -> IO value
    quietly fallback action = do
        outcome <- try action
        pure (either (\failure -> const fallback (failure :: IOException)) id outcome)

-- | An unavailable canonicalization supplies no canonical-root fact.
directRootCanonicalFact :: FilePath -> Maybe FilePath -> Bool
directRootCanonicalFact root = maybe False (equalFilePath root)

{- | Whether the observed root is the exact canonical directory Direct admits.

Total, and one reason at a time, so an operator learns which of the five facts
refused rather than that "the root is invalid".  Direct still claims no
ownership of the host: this decides only whether an already-local frame may be
admitted, and it publishes no origin and holds no clause.
-}
admitDirectRoot :: FilePath -> DirectRootObservation -> Either Text ()
admitDirectRoot root observed
    | not (directRootAbsolute observed) = refuse "is not absolute on this host"
    | not (directRootDirectory observed) = refuse "is not a directory"
    | directRootSymbolicLink observed = refuse "is a symbolic link rather than the directory it names"
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
        LimaBackendSpec{} -> pure (RawProviderFailure "invalid Incus backend state")
    ProviderHostToolRequest _ _ ->
        pure (RawProviderFailure "the bound Incus backend refused a different host tool")
    ProviderDirectProbeRequest _ ->
        pure (RawProviderFailure "the bound Incus backend refused a Direct-host probe")
    ProviderProvisioningEgressProbe -> case spec of
        IncusBackendSpec _ image _ _ _ _ _ _ ->
            rawProviderOutcome <$> interpretHostCommand cfg (hostCommand Incus ["image", "info", image])
        DirectHostBackendSpec{} -> pure (RawProviderFailure "invalid Incus backend state")
        LimaBackendSpec{} -> pure (RawProviderFailure "invalid Incus backend state")
    ProviderGuestProbeRequest [] ->
        pure (RawProviderFailure "guest probe argv must be non-empty and contain no NUL")
    ProviderGuestProbeRequest argv@(exe : arguments)
        | any ('\0' `elem`) argv ->
            pure (RawProviderFailure "guest probe argv must be non-empty and contain no NUL")
        | otherwise -> do
            outcome <-
                withOwnedProviderTransaction cfg spec owner $
                    \session key owned -> execInOwnedInstance cfg session key owned exe arguments
            pure (guestOutcome outcome)

runBoundLima ::
    HostConfig ->
    ProviderBackendSpec ->
    Text ->
    ProviderProbeRequest ->
    IO RawProviderOutcome
runBoundLima cfg spec@(LimaBackendSpec provider _ _ _) owner request =
    case providerProbeRequestView request of
        ProviderHostToolRequest tool argv
            | foldExistsProbe False (\retainedTool retainedArgv _ -> tool == retainedTool && argv == retainedArgv)
                (providerExistsProbe provider) -> do
                    observed <- withOwnedGuestVm spec owner (GuestVm.observeOwnedGuestVm cfg)
                    pure $ case observed of
                        Right () -> RawProviderExit ExitSuccess "" ""
                        Left fault -> guestOutcome (Left fault)
            | elem (providerKind provider, tool) [(ProviderLima, Lima), (ProviderWsl2, Wsl)] ->
                pure (RawProviderFailure "the bound guest-VM backend refused an unknown host-tool vector")
        ProviderHostToolRequest _ _ ->
            pure (RawProviderFailure "the bound guest-VM backend refused a different host tool")
        ProviderDirectProbeRequest _ ->
            pure (RawProviderFailure "the bound guest-VM backend refused a Direct-host probe")
        ProviderProvisioningEgressProbe ->
            runOwnedGuestVm cfg spec owner ["getent", "hosts", "archive.ubuntu.com"]
        ProviderGuestProbeRequest argv
            | null argv || any (elem '\0') argv ->
                pure (RawProviderFailure "guest probe argv must be non-empty and contain no NUL")
            | otherwise -> runOwnedGuestVm cfg spec owner argv
runBoundLima _ _ _ _ = pure (RawProviderFailure "invalid Lima backend state")

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
        RefusedForeign _ _ expected observed ->
            RawProviderFailure
                ( providerConflictMarker
                    (originSide expected)
                    (originSide (OriginPresent observed))
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

providerConflictMarker :: Text -> Text -> Text -> String
providerConflictMarker expected observed reason =
    if all (validConflictToken . Text.unpack) [expected, observed, reason]
        then
            "HB_PROVIDER_CONFLICT "
                <> Text.unpack expected
                <> " "
                <> Text.unpack observed
                <> " "
                <> Text.unpack reason
        else "HB_PROVIDER_CONFLICT bounded-token invalid-token invalid-conflict-marker"

