{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Clause-holding realization boundary for a plan-owned host provider.

The injected seam is deliberately byte-level: a 'ProviderExec' can report only
an exit verdict and captured streams.  It cannot claim that a daemon is ready,
that an instance belongs to this plan, or that a mutation succeeded.  This
module owns every argv and every total parser.

For Incus, every mutation runs below one kernel-held @flock(2)@ front end.  A
fresh-nonce origin record is staged, fsynced, atomically linked without
replacement, directory-fsynced and read back byte-for-byte before @incus
launch@ is first invoked.  The nonce
is also written into the instance's @user.hostbootstrap.owner@ configuration,
which closes the crash window between launch and stable-identity binding.  The
provider-reported @volatile.uuid@ is then atomically bound into the record.
Every start, share, stop, guest execution and delete re-observes both that UUID
and nonce under the same lock before it may mutate.  Delete is conditional and
leaves a same-named replacement untouched.

The Direct realization is structurally different: it admits an already-local
frame without running a command, publishing an origin, or claiming ownership
of the host.  Stop and delete are therefore 'Unsupported'.
-}
module HostBootstrap.Substrate.Provider.Backend (
    -- * Descriptive provider request
    ProviderBackendSpec,
    mkIncusBackendSpec,
    mkDirectHostBackendSpec,

    -- * Raw injected execution only
    ProviderBackendExec (..),
    ProviderBackendRequest,
    ProviderBackendRequestView (..),
    providerBackendRequestView,
    RawProviderOutcome (..),

    -- * Clause-holding backend
    StrongProviderBackend,
    discoverStrongProviderBackend,
    providerBackendBinding,

    -- * Prepared backend calls
    runProviderProvisionCall,
    runProviderReadyCall,
    runProviderStopCall,
    runProviderShareCall,
    runProviderDeleteCall,

    -- * Provider-bound discovery and guest execution
    withProviderBoundExec,
)
where

import Crypto.Hash (Digest, SHA256, hash)
import Data.Bits (xor)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString.Char8 as ByteString
import Data.Char (isAlphaNum)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.HostConfig (HostConfig (hcSubstrate), resolveMaybe)
import HostBootstrap.HostTool (HostTool (Docker, Flock, Incus, Python3), absExePath)
import HostBootstrap.Readiness (Micros, seconds)
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
import HostBootstrap.Substrate.Provider.Reconcile (
    PreparedProviderBinding,
    PreparedProviderDelete,
    PreparedProviderProvision,
    PreparedProviderReady,
    PreparedProviderShare,
    PreparedProviderStop,
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
 )
import System.Exit (ExitCode (..))

-- Descriptive request ---------------------------------------------------------

data ProviderLockPrimitive
    = ProviderFlock
    deriving (Eq, Show)

data ProviderBackendSpec
    = IncusBackendSpec
        String
        String
        FilePath
        FilePath
        ProviderLockPrimitive
        FilePath
        FilePath
        Word64
        String
        String
    | DirectHostBackendSpec FilePath FilePath FilePath String
    deriving (Eq, Show)

{- | Validate the complete Incus instance declaration.  The executable and
state directory must already be absolute; discovery proves their usability.
Resource quantities are passed as single argv values and therefore accept only
the bounded alphanumeric unit vocabulary used by the provider.
-}
mkIncusBackendSpec ::
    String ->
    String ->
    HostConfig ->
    FilePath ->
    Word64 ->
    String ->
    String ->
    Either ReconcileError ProviderBackendSpec
mkIncusBackendSpec name image hostConfig stateDirectory cpu memory storage
    | substrateName (hcSubstrate hostConfig) /= LinuxCpu = invalid "the Incus provider backend requires a linux-cpu HostConfig"
    | not (safeName name) = invalid "the Incus instance name is empty or contains a non-portable character"
    | length name > maxIncusInstanceNameLength =
        invalid
            ( "the Incus instance name is longer than "
                <> Text.pack (show maxIncusInstanceNameLength)
                <> " characters, so its share device socket path exceeds the platform limit"
            )
    | null image || '\0' `elem` image = invalid "the Incus image must be non-empty and contain no NUL"
    | not (absolutePath stateDirectory) = invalid "the provider state directory must be an absolute path"
    | cpu == 0 = invalid "the provider CPU quantity must be positive"
    | not (safeQuantity memory) || not (safeQuantity storage) =
        invalid "provider memory and storage quantities must be non-empty alphanumeric values"
    | otherwise = do
        executable <- requireTool Incus
        python <- requireTool Python3
        lockExecutable <- requireLock
        Right
            (IncusBackendSpec name image executable python ProviderFlock lockExecutable stateDirectory cpu memory storage)
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
    requireLock = case resolveMaybe hostConfig Flock of
        Just executable -> Right (absExePath executable)
        Nothing ->
            Left
                ( Unsupported
                    ( UnsupportedDetail
                        "construct Incus provider backend"
                        "the Linux Incus backend requires a resolved Flock executable; lockf is a distinct kernel lock namespace on Linux"
                    )
                )

-- | Admit the canonical already-local root.  No ownership is implied.
mkDirectHostBackendSpec :: HostConfig -> FilePath -> String -> Either ReconcileError ProviderBackendSpec
mkDirectHostBackendSpec hostConfig root egressImage
    | not (absolutePath root) =
        Left
            ( Failure
                ( FailureDetail
                    "validate Direct provider backend"
                    "the direct-host root must be an absolute path"
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
        python <- requireTool Python3
        docker <- requireTool Docker
        Right (DirectHostBackendSpec root python docker egressImage)
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

-- Raw execution ---------------------------------------------------------------

{- | A request is constructed only by this module.  Production and tests may
inspect its read-only view in order to execute it, but cannot turn the injected
runner into an arbitrary process oracle.
-}
newtype ProviderBackendRequest = ProviderBackendRequest ProviderBackendRequestView

data ProviderBackendRequestView
    = ProviderBackendProcess FilePath [String]
    deriving (Eq, Show)

providerBackendRequestView :: ProviderBackendRequest -> ProviderBackendRequestView
providerBackendRequestView (ProviderBackendRequest request) = request

data ProviderBackendExec = ProviderBackendExec
    { runProviderBackendExec :: ProviderBackendRequest -> IO RawProviderOutcome
    , waitProviderBackendExec :: Micros -> IO ()
    }

data ExclusionTool
    = UseFlock FilePath FilePath
    deriving (Eq, Show)

data
    StrongProviderBackend
        backendId
    = StrongIncusBackend (ProviderBackendBinding backendId) ProviderBackendExec ProviderBackendSpec ExclusionTool
    | StrongDirectHostBackend (ProviderBackendBinding backendId) ProviderBackendExec ProviderBackendSpec

{- | Run the backend-owned discovery plan.  Direct is structurally applicable
and invokes no executor.  Incus accepts success only when the raw report names
the exact lock front end the later bracket will use.
-}
discoverStrongProviderBackend ::
    ProviderBackendExec ->
    ProviderBackendSpec ->
    (forall backendId. StrongProviderBackend backendId -> IO result) ->
    IO (Either ReconcileError result)
discoverStrongProviderBackend exec spec consume = case spec of
    DirectHostBackendSpec{} ->
        Right
            <$> consume
                ( StrongDirectHostBackend
                    (ProviderBackendBinding (backendSemanticFingerprint spec) (backendRealizationFingerprint spec))
                    exec
                    spec
                )
    IncusBackendSpec name _ executable python lockPrimitive lockExecutable stateDirectory _ _ _ -> do
        let candidate = case lockPrimitive of
                ProviderFlock -> UseFlock lockExecutable python
            (lockCommand, _, lockArgs) = exclusionProcess candidate (providerLockPath name stateDirectory)
        raw <-
            runBackendProcess
                exec
                lockCommand
                ( lockArgs
                    <> [ python
                       , "-c"
                       , ownershipToolProbe
                       , executable
                       , lockCommand
                       , stateDirectory
                       , lockPrimitiveName lockPrimitive
                       ]
                )
        case parseExclusionTool lockPrimitive raw of
            True ->
                Right
                    <$> consume
                        ( StrongIncusBackend
                            (ProviderBackendBinding (backendSemanticFingerprint spec) (backendRealizationFingerprint spec))
                            exec
                            spec
                            candidate
                        )
            False ->
                pure
                    ( Left
                        ( Unsupported
                            ( UnsupportedDetail
                                "discover Incus provider ownership backend"
                                "the host did not prove a writable state directory, Python 3, Incus executable, and the required flock namespace"
                            )
                        )
                    )

providerBackendBinding :: StrongProviderBackend backendId -> ProviderBackendBinding backendId
providerBackendBinding backend = case backend of
    StrongIncusBackend binding _ _ _ -> binding
    StrongDirectHostBackend binding _ _ -> binding

backendSemanticFingerprint :: ProviderBackendSpec -> Text
backendSemanticFingerprint spec = case spec of
    IncusBackendSpec name image _ _ _ _ stateDirectory cpu memory storage ->
        framed
            [ "hostbootstrap/provider-backend/incus/v1"
            , Text.pack name
            , Text.pack image
            , Text.pack stateDirectory
            , Text.pack (show cpu)
            , Text.pack memory
            , Text.pack storage
            ]
    DirectHostBackendSpec root _ _ egressImage ->
        framed
            [ "hostbootstrap/provider-backend/direct/v1"
            , Text.pack root
            , Text.pack egressImage
            ]
  where
    framed = Text.concat . map (\value -> Text.pack (show (Text.length value)) <> ":" <> value)

backendRealizationFingerprint :: ProviderBackendSpec -> Text
backendRealizationFingerprint spec = case spec of
    IncusBackendSpec _ _ executable python lockPrimitive lockExecutable _ _ _ _ ->
        framed
            [ "hostbootstrap/provider-realization/incus/v1"
            , Text.pack executable
            , Text.pack python
            , Text.pack (lockPrimitiveName lockPrimitive)
            , Text.pack lockExecutable
            ]
    DirectHostBackendSpec _ python docker _ ->
        framed
            [ "hostbootstrap/provider-realization/direct/v1"
            , Text.pack python
            , Text.pack docker
            ]
  where
    framed = Text.concat . map (\value -> Text.pack (show (Text.length value)) <> ":" <> value)

lockPrimitiveName :: ProviderLockPrimitive -> String
lockPrimitiveName ProviderFlock = "flock"

ownershipToolProbe :: String
ownershipToolProbe =
    unlines
        [ "import os,sys"
        , "provider,lock,state,kind=sys.argv[1:]"
        , "ok=(kind=='flock' and all(os.path.isabs(p) and os.path.isfile(p) and os.access(p,os.X_OK) for p in (provider,lock)) and os.path.isabs(state) and os.path.isdir(state) and os.access(state,os.W_OK))"
        , "print('PROVED '+kind if ok else 'REFUSED')"
        , "raise SystemExit(0 if ok else 1)"
        ]

parseExclusionTool :: ProviderLockPrimitive -> RawProviderOutcome -> Bool
parseExclusionTool lockPrimitive raw = case raw of
    RawProviderExit ExitSuccess out "" -> case lines out of
        ["PROVED flock"] -> lockPrimitive == ProviderFlock
        _ -> False
    _ -> False

runBackendProcess :: ProviderBackendExec -> FilePath -> [String] -> IO RawProviderOutcome
runBackendProcess exec executable argv =
    runProviderBackendExec exec (ProviderBackendRequest (ProviderBackendProcess executable argv))

-- Prepared call seam ----------------------------------------------------------

runProviderProvisionCall ::
    StrongProviderBackend backendId ->
    PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
    IO (ProviderProvisionCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion)
runProviderProvisionCall backend prepared = case backend of
    StrongDirectHostBackend _ _ _ ->
        pure (ProviderProvisionCallResult (ProviderProvisionDirectLocal (preparedProviderBindingGeneration binding)))
    StrongIncusBackend _ exec spec tool -> do
        raw <- runExclusive exec spec tool "provision" (preparedProviderBindingOwner binding) []
        pure (ProviderProvisionCallResult (parseProvisionReport binding raw))
  where
    binding = preparedProviderProvisionBinding prepared

runProviderReadyCall ::
    StrongProviderBackend backendId ->
    PreparedProviderReady scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion ->
    IO (ProviderReadyCallResult scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion)
runProviderReadyCall backend prepared = case backend of
    StrongDirectHostBackend _ exec (DirectHostBackendSpec root python docker image) -> do
        permission <- runBackendProcess exec python ["-c", directPermissionProgram, root]
        case directReadyProbeFailure "validate the exact Direct provider root" permission of
            Just failure -> pure (ProviderReadyCallResult (ProviderReadyFailed failure))
            Nothing -> do
                egress <- runBackendProcess exec docker ["manifest", "inspect", image]
                pure
                    ( ProviderReadyCallResult
                        ( case directReadyProbeFailure "validate Direct provider provisioning egress" egress of
                            Just failure -> ProviderReadyFailed failure
                            Nothing -> ProviderReadyObserved (preparedProviderBindingGeneration binding)
                        )
                    )
    StrongDirectHostBackend _ _ (IncusBackendSpec{}) ->
        pure (ProviderReadyCallResult (ProviderReadyFailed (failed "reconcile Direct provider ready" "invalid Direct backend state")))
    StrongIncusBackend _ exec spec tool ->
        ProviderReadyCallResult <$> pollProviderReady exec spec tool binding 60
  where
    binding = preparedProviderReadyBinding prepared

directReadyProbeFailure :: Text -> RawProviderOutcome -> Maybe FailureDetail
directReadyProbeFailure operation raw = case raw of
    RawProviderExit ExitSuccess _ "" -> Nothing
    RawProviderExit ExitSuccess _ err -> Just (failed operation ("the exact probe wrote stderr: " <> firstLineText err))
    RawProviderExit (ExitFailure code) out err ->
        Just
            ( failed
                operation
                ( "the exact probe exited "
                    <> Text.pack (show code)
                    <> ": "
                    <> firstLineText (if null err then out else err)
                )
            )
    RawProviderFailure reason -> Just (failed operation (Text.pack reason))

pollProviderReady ::
    ProviderBackendExec ->
    ProviderBackendSpec ->
    ExclusionTool ->
    PreparedProviderBinding scope planId backendId providerId ->
    Int ->
    IO ProviderReadyObservation
pollProviderReady exec spec tool binding remaining = do
    raw <- runExclusive exec spec tool "ready" (preparedProviderBindingOwner binding) []
    case parseReadyReport binding raw of
        observation@(ProviderReadyNotReady _)
            | remaining > 1 -> case seconds 1 of
                Left _ -> pure observation
                Right delay -> waitProviderBackendExec exec delay >> pollProviderReady exec spec tool binding (remaining - 1)
        observation -> pure observation

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
    StrongIncusBackend _ exec spec tool -> do
        raw <- runExclusive exec spec tool "stop" (preparedProviderBindingOwner binding) []
        pure (ProviderStopCallResult (parseStopReport binding raw))
  where
    binding = preparedProviderStopBinding prepared

runProviderShareCall ::
    StrongProviderBackend backendId ->
    PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
    IO (ProviderShareCallResult scope planId backendId providerId shareId operationKey callDigest attempt journalVersion)
runProviderShareCall backend prepared = case backend of
    StrongDirectHostBackend _ _ (DirectHostBackendSpec root _ _ _)
        | source == root && target == root ->
            pure (ProviderShareCallResult (ProviderShareDirectLocal shareGeneration))
        | otherwise ->
            pure
                ( ProviderShareCallResult
                    ( ProviderShareConflict
                        ( ConflictDetail
                            "direct-host-share"
                            (Text.pack root)
                            (Text.pack (source <> " -> " <> target))
                            "the direct host projects its one canonical root and performs no mount mutation"
                        )
                    )
                )
    StrongIncusBackend _ exec spec tool
        | not (absolutePath source) || not (absolutePath target) || '\0' `elem` source || '\0' `elem` target ->
            pure
                ( ProviderShareCallResult
                    ( ProviderShareFailed
                        (FailureDetail "reconcile provider share" "share paths must be absolute and contain no NUL" DoNotRetry)
                    )
                )
        | otherwise -> do
            raw <-
                runExclusive
                    exec
                    spec
                    tool
                    "share"
                    (preparedProviderBindingOwner binding)
                    [shareDeviceName prepared, Text.unpack (preparedShareBinding prepared), source, target]
            pure (ProviderShareCallResult (parseShareReport binding shareGeneration raw))
    StrongDirectHostBackend _ _ (IncusBackendSpec{}) ->
        pure (ProviderShareCallResult (ProviderShareFailed (failed "reconcile provider share" "invalid Direct backend state")))
  where
    binding = preparedProviderShareBinding prepared
    shareGeneration = resourceHandleGeneration (preparedProviderShareHandle prepared)
    source = providerShareHostPath shareSpec
    target = providerShareGuestPath shareSpec
    shareSpec = preparedProviderShareSpec prepared

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
    StrongIncusBackend _ exec spec tool -> do
        raw <- runExclusive exec spec tool "delete" (preparedProviderBindingOwner binding) []
        pure (ProviderDeleteCallResult (parseDeleteReport binding raw))
  where
    binding = preparedProviderDeleteBinding prepared

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
        StrongDirectHostBackend _ exec spec ->
            Right
                ( consume
                    ( bindProviderBoundExec
                        (providerBoundRouteFor spec)
                        (runBoundDirect exec spec)
                        (waitProviderBackendExec exec)
                    )
                )
        StrongIncusBackend _ exec spec tool ->
            Right
                ( consume
                    ( bindProviderBoundExec
                        (providerBoundRouteFor spec)
                        (runBoundIncus exec spec tool (providerOriginOwner origin))
                        (waitProviderBackendExec exec)
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
        StrongIncusBackend binding _ _ _ -> binding
        StrongDirectHostBackend binding _ _ -> binding

sameBackendBinding :: ProviderBackendBinding backendId -> ProviderBackendBinding backendId -> Bool
sameBackendBinding left right =
    providerBackendSemanticFingerprint left == providerBackendSemanticFingerprint right
        && providerBackendRealizationFingerprint left == providerBackendRealizationFingerprint right

providerBoundRouteFor :: ProviderBackendSpec -> ProviderBoundRoute
providerBoundRouteFor spec = case spec of
    IncusBackendSpec name image _ _ _ _ _ _ _ _ -> ProviderBoundIncusRoute name image
    DirectHostBackendSpec root _ _ egressImage -> ProviderBoundDirectRoute root egressImage

runBoundDirect :: ProviderBackendExec -> ProviderBackendSpec -> ProviderProbeRequest -> IO RawProviderOutcome
runBoundDirect exec spec request = case (spec, providerProbeRequestView request) of
    (DirectHostBackendSpec root python _ _, ProviderDirectProbeRequest DirectPermissionProbe) ->
        runBackendProcess exec python ["-c", directPermissionProgram, root]
    (DirectHostBackendSpec _ _ docker image, ProviderProvisioningEgressProbe) ->
        runBackendProcess exec docker ["manifest", "inspect", image]
    (IncusBackendSpec{}, _) ->
        pure (RawProviderFailure "invalid Direct backend state")
    (_, ProviderHostToolRequest _ _) ->
        pure (RawProviderFailure "the Direct provider has no host-tool or guest route")
    (_, ProviderGuestProbeRequest _) ->
        pure (RawProviderFailure "the Direct provider has no guest route")

directPermissionProgram :: String
directPermissionProgram =
    unlines
        [ "import os,stat,sys"
        , "root=sys.argv[1]; ok=False"
        , "try:"
        , "    observed=os.lstat(root)"
        , "    ok=(os.path.isabs(root) and os.path.realpath(root)==root and stat.S_ISDIR(observed.st_mode) and os.access(root,os.R_OK|os.W_OK|os.X_OK))"
        , "except OSError: pass"
        , "raise SystemExit(0 if ok else 1)"
        ]

runBoundIncus ::
    ProviderBackendExec ->
    ProviderBackendSpec ->
    ExclusionTool ->
    Text ->
    ProviderProbeRequest ->
    IO RawProviderOutcome
runBoundIncus exec spec tool owner request = case providerProbeRequestView request of
    ProviderHostToolRequest Incus argv -> case spec of
        IncusBackendSpec _ _ executable _ _ _ _ _ _ _ -> runBackendProcess exec executable argv
        DirectHostBackendSpec{} -> pure (RawProviderFailure "invalid Incus backend state")
    ProviderHostToolRequest _ _ ->
        pure (RawProviderFailure "the bound Incus backend refused a different host tool")
    ProviderDirectProbeRequest _ ->
        pure (RawProviderFailure "the bound Incus backend refused a Direct-host probe")
    ProviderProvisioningEgressProbe -> case spec of
        IncusBackendSpec _ image executable _ _ _ _ _ _ _ ->
            runBackendProcess exec executable ["image", "info", image]
        DirectHostBackendSpec{} -> pure (RawProviderFailure "invalid Incus backend state")
    ProviderGuestProbeRequest argv
        | null argv || any ('\0' `elem`) argv ->
            pure (RawProviderFailure "guest probe argv must be non-empty and contain no NUL")
        | otherwise -> do
            raw <- runExclusive exec spec tool "guest" owner argv
            pure (parseGuestOutcome owner raw)

-- Locked protocol -------------------------------------------------------------

runExclusive ::
    ProviderBackendExec ->
    ProviderBackendSpec ->
    ExclusionTool ->
    String ->
    Text ->
    [String] ->
    IO RawProviderOutcome
runExclusive exec spec tool mode owner extra =
    let (executable, argv) = exclusiveProcess spec tool mode owner extra
     in runBackendProcess exec executable argv

exclusiveProcess :: ProviderBackendSpec -> ExclusionTool -> String -> Text -> [String] -> (FilePath, [String])
exclusiveProcess spec tool mode owner extra = case spec of
    DirectHostBackendSpec{} -> ("", [])
    IncusBackendSpec name image executable _ _ _ stateDirectory cpu memory storage ->
        let (lockExecutable, pythonExecutable, prefix) = exclusionProcess tool (providerLockPath name stateDirectory)
         in ( lockExecutable
            , prefix
                <> [ pythonExecutable
                   , "-c"
                   , providerOwnershipProgram
                   , mode
                   , name
                   , image
                   , executable
                   , providerRecordPath name stateDirectory
                   , Text.unpack owner
                   , show cpu
                   , memory
                   , storage
                   ]
                <> extra
            )

exclusionProcess :: ExclusionTool -> FilePath -> (FilePath, FilePath, [String])
exclusionProcess (UseFlock executable python) lock = (executable, python, ["-x", lock])

providerLockPath :: String -> FilePath -> FilePath
providerLockPath name stateDirectory = stateDirectory <> "/" <> name <> ".provider.lock"

providerRecordPath :: String -> FilePath -> FilePath
providerRecordPath name stateDirectory = stateDirectory <> "/" <> name <> ".provider.origin.json"

{- | The provider-owned driver.  It contains no shell and receives all values
as positional arguments.  All reports are single-line, bounded tokens; guest
stdout/stderr are hex encoded so arbitrary guest bytes cannot forge a control
report.
-}
providerOwnershipProgram :: String
providerOwnershipProgram =
    unlines
        [ "import errno"
        , "import json"
        , "import os"
        , "import re"
        , "import secrets"
        , "import stat"
        , "import subprocess"
        , "import sys"
        , "mode,name,image,provider,record_path,owner,cpu,memory,storage,*extra = sys.argv[1:]"
        , "identity_re = re.compile(r'[A-Za-z0-9:._-]{1,240}')"
        , "token_re = re.compile(r'[A-Za-z0-9:._/=-]{1,240}')"
        , "class Conflict(Exception):"
        , "    def __init__(self, expected, observed, reason): self.expected=expected; self.observed=observed; self.reason=reason"
        , "class Unsupported(Exception): pass"
        , "class Absent(Exception): pass"
        , "class Replaced(Exception):"
        , "    def __init__(self, identity): self.identity=identity"
        , "def token(value):"
        , "    value = str(value)"
        , "    return value if token_re.fullmatch(value) else 'invalid-token'"
        , "def diagnostic(value):"
        , "    folded = re.sub(r'[^A-Za-z0-9:._/=-]', '-', str(value))[:200].strip('-')"
        , "    return folded if folded else 'no-diagnostic'"
        , "def emit(tag,*fields):"
        , "    print(' '.join([tag]+[token(field) for field in fields]), flush=True)"
        , "    raise SystemExit(0)"
        , "def run(args):"
        , "    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)"
        , "def require(result, operation):"
        , "    if result.returncode != 0: raise OSError(operation+'-exit-'+str(result.returncode)+'-'+diagnostic(result.stderr.splitlines()[0] if result.stderr else 'no-diagnostic'))"
        , "    return result.stdout.strip()"
        , "def fsync_dir(path):"
        , "    fd=os.open(path,os.O_RDONLY|getattr(os,'O_DIRECTORY',0))"
        , "    try: os.fsync(fd)"
        , "    except OSError as failure:"
        , "        if failure.errno in (errno.EINVAL,getattr(errno,'ENOTSUP',errno.EINVAL)): raise Unsupported('directory-fsync-unavailable')"
        , "        raise"
        , "    finally: os.close(fd)"
        , "def read_path(path,limit,oversized_reason):"
        , "    if not os.path.lexists(path): return None"
        , "    if not hasattr(os,'O_NOFOLLOW'): raise Unsupported('O_NOFOLLOW-unavailable')"
        , "    try: fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|getattr(os,'O_NONBLOCK',0))"
        , "    except OSError as failure:"
        , "        if failure.errno==getattr(errno,'ELOOP',-1): raise Conflict('regular-file','symlink',oversized_reason+'-kind')"
        , "        raise"
        , "    raw=b''"
        , "    try:"
        , "        observed=os.fstat(fd)"
        , "        if not stat.S_ISREG(observed.st_mode): raise Conflict('regular-file','different-file-kind',oversized_reason+'-kind')"
        , "        if observed.st_size>limit: raise Conflict('bounded-record','oversized',oversized_reason)"
        , "        while True:"
        , "            chunk=os.read(fd,65536)"
        , "            if not chunk: break"
        , "            raw+=chunk"
        , "            if len(raw)>limit: raise Conflict('bounded-record','oversized',oversized_reason)"
        , "    finally: os.close(fd)"
        , "    return raw"
        , "def revalidate_path(path,expected,reason):"
        , "    if not hasattr(os,'O_NOFOLLOW'): raise Unsupported('O_NOFOLLOW-unavailable')"
        , "    try: fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|getattr(os,'O_NONBLOCK',0))"
        , "    except OSError as failure:"
        , "        if failure.errno==getattr(errno,'ELOOP',-1): raise Conflict('regular-file','symlink',reason+'-kind')"
        , "        raise"
        , "    try:"
        , "        observed=os.fstat(fd)"
        , "        if not stat.S_ISREG(observed.st_mode): raise Conflict('regular-file','different-file-kind',reason+'-kind')"
        , "        try: os.fsync(fd)"
        , "        except OSError as failure:"
        , "            if failure.errno in (errno.EINVAL,getattr(errno,'ENOTSUP',errno.EINVAL)): raise Unsupported('file-fsync-unavailable')"
        , "            raise"
        , "    finally: os.close(fd)"
        , "    fsync_dir(os.path.dirname(path))"
        , "    observed=read_path(path,65536,reason+'-size')"
        , "    if observed!=expected: raise Conflict('exact-durable-record','different-bytes',reason)"
        , "    return observed"
        , "def write_all(fd,payload):"
        , "    view=memoryview(payload)"
        , "    while view:"
        , "        count=os.write(fd,view)"
        , "        if count<=0: raise OSError('short-origin-write')"
        , "        view=view[count:]"
        , "def stage_candidates(path):"
        , "    directory=os.path.dirname(path); prefix=os.path.basename(path)+'.prepare-'"
        , "    found=[]"
        , "    for entry in os.listdir(directory):"
        , "        if entry.startswith(prefix) and re.fullmatch(r'[0-9a-f]{64}',entry[len(prefix):]): found.append((os.path.join(directory,entry),entry[len(prefix):]))"
        , "    return sorted(found)"
        , "def stage_exact(path,expected,size_reason,durability_reason,mismatch_reason):"
        , "    staged=read_path(path,65536,size_reason)"
        , "    if staged is not None and staged!=expected:"
        , "        if not expected.startswith(staged): raise Conflict('exact-staged-record','different-bytes',mismatch_reason)"
        , "        fd=os.open(path,os.O_WRONLY|os.O_TRUNC|os.O_NOFOLLOW|getattr(os,'O_NONBLOCK',0))"
        , "        try:"
        , "            if not stat.S_ISREG(os.fstat(fd).st_mode): raise Conflict('regular-file','different-file-kind',mismatch_reason+'-kind')"
        , "            write_all(fd,expected); os.fsync(fd)"
        , "        finally: os.close(fd)"
        , "        staged=read_path(path,65536,size_reason)"
        , "    if staged is None:"
        , "        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,'O_NOFOLLOW',0),0o600)"
        , "        try: write_all(fd,expected); os.fsync(fd)"
        , "        finally: os.close(fd)"
        , "        staged=read_path(path,65536,size_reason)"
        , "    if staged!=expected: raise Conflict('exact-staged-record','different-bytes',mismatch_reason)"
        , "    revalidate_path(path,staged,durability_reason)"
        , "    return staged"
        , "def publish_no_replace(staging,target,expected,reason):"
        , "    try: os.link(staging,target,follow_symlinks=False)"
        , "    except FileExistsError:"
        , "        if read_path(target,65536,reason+'-size')!=expected: raise Conflict('absent-or-exact-published-record','different-bytes',reason)"
        , "    except (AttributeError,NotImplementedError): raise Unsupported('hard-link-publication-unavailable')"
        , "    fsync_dir(os.path.dirname(target))"
        , "    if read_path(target,65536,reason+'-size')!=expected: raise Conflict('exact-published-record','different-bytes',reason)"
        , "    staged=read_path(staging,65536,reason+'-staging-size')"
        , "    if staged is not None:"
        , "        if staged!=expected: raise Conflict('exact-published-staging','different-bytes',reason+'-staging')"
        , "        os.unlink(staging); fsync_dir(os.path.dirname(target))"
        , "def payload(nonce,state,origin,managed_identity=None,shares=None):"
        , "    value={'magic':'hb-provider-origin-v1','name':name,'nonce':nonce,'origin':origin,'owner':owner,'shares':shares if shares is not None else {},'state':state}"
        , "    if managed_identity is not None: value['managed_identity']=managed_identity"
        , "    return (json.dumps(value,sort_keys=True,separators=(',',':'))+'\\n').encode('utf-8')"
        , "def decode(raw):"
        , "    try: value=json.loads(raw.decode('utf-8'))"
        , "    except Exception: raise Conflict('well-formed-origin-record','malformed','record-codec')"
        , "    for key,expected in [('magic','hb-provider-origin-v1'),('name',name),('owner',owner)]:"
        , "        if value.get(key)!=expected: raise Conflict(token(expected),token(value.get(key)),'record-'+key)"
        , "    nonce=value.get('nonce')"
        , "    if not isinstance(nonce,str) or not re.fullmatch(r'[0-9a-f]{64}',nonce): raise Conflict('fresh-nonce',token(nonce),'record-nonce')"
        , "    if value.get('origin')!='absent': raise Conflict('origin-absent',token(value.get('origin')),'record-origin')"
        , "    shares=value.get('shares')"
        , "    if not isinstance(shares,dict): raise Conflict('share-manifest','invalid','record-shares')"
        , "    for device,entry in shares.items():"
        , "        if not re.fullmatch(r'"
            <> shareDevicePrefix
            <> "[0-9a-f]{"
            <> show shareDeviceDigestLength
            <> "}',str(device)): raise Conflict('bounded-share-device',token(device),'record-share-device')"
        , "        if not isinstance(entry,dict) or set(entry)!={'binding','source','target'} or not all(isinstance(entry.get(key),str) for key in ('binding','source','target')): raise Conflict('complete-share-binding','invalid','record-share-entry')"
        , "    state=value.get('state')"
        , "    if state=='prepared' and set(value)=={'magic','name','nonce','origin','owner','shares','state'}: return value"
        , "    if state=='managed' and set(value)=={'magic','managed_identity','name','nonce','origin','owner','shares','state'} and identity_re.fullmatch(str(value.get('managed_identity',''))): return value"
        , "    raise Conflict('prepared-or-managed-record',token(state),'record-state')"
        , "def read_record():"
        , "    raw=read_path(record_path,65536,'record-size')"
        , "    if raw is None: return None,None"
        , "    return decode(raw),raw"
        , "def revalidate_record(current,raw):"
        , "    revalidate_path(record_path,raw,'origin-record-durability')"
        , "    observed,readback=read_record()"
        , "    if readback!=raw: raise Conflict('exact-origin-record','different-bytes','origin-record-revalidation')"
        , "    return observed,readback"
        , "def initial_record_payload(nonce): return payload(nonce,'prepared','absent',shares={})"
        , "def clear_initial_record_stage(current):"
        , "    candidates=stage_candidates(record_path)"
        , "    if not candidates: return"
        , "    if len(candidates)!=1 or candidates[0][1]!=current['nonce']: raise Conflict('one-matching-origin-staging-record','different-staging-set','origin-staging-set')"
        , "    path,nonce=candidates[0]; staged=read_path(path,65536,'origin-initial-staging-size'); expected=initial_record_payload(nonce)"
        , "    if staged is None: return"
        , "    if not expected.startswith(staged): raise Conflict('exact-initial-origin-staging','different-bytes','origin-initial-staging')"
        , "    os.unlink(path); fsync_dir(os.path.dirname(record_path))"
        , "def prepare_record():"
        , "    existing,raw=read_record()"
        , "    if existing is not None:"
        , "        existing,raw=revalidate_record(existing,raw); clear_initial_record_stage(existing); return existing,raw"
        , "    candidates=stage_candidates(record_path)"
        , "    if len(candidates)>1: raise Conflict('at-most-one-origin-staging-record','multiple','origin-staging-set')"
        , "    nonce=candidates[0][1] if candidates else secrets.token_hex(32); raw=initial_record_payload(nonce)"
        , "    staging=record_path+'.prepare-'+nonce"
        , "    stage_exact(staging,raw,'origin-initial-staging-size','origin-initial-staging-durability','origin-initial-staging')"
        , "    publish_no_replace(staging,record_path,raw,'origin-publication')"
        , "    observed,readback=read_record()"
        , "    if readback!=raw: raise Conflict('exact-origin-readback','different-bytes','record-readback')"
        , "    return observed,readback"
        , "def bind_record(current,identity):"
        , "    if current['state']=='managed':"
        , "        if current['managed_identity']!=identity: raise Conflict(current['managed_identity'],identity,'managed-record')"
        , "        return current"
        , "    expected=payload(current['nonce'],'prepared','absent',shares=current['shares'])"
        , "    _,raw=read_record()"
        , "    if raw!=expected: raise Conflict('exact-prepared-record','changed-record','record-version')"
        , "    updated=payload(current['nonce'],'managed','absent',managed_identity=identity,shares=current['shares'])"
        , "    temporary=record_path+'.tmp-'+current['nonce']"
        , "    stage_exact(temporary,updated,'record-staging-size','record-staging-durability','record-staging')"
        , "    os.replace(temporary,record_path); fsync_dir(os.path.dirname(record_path))"
        , "    rebound,readback=read_record()"
        , "    if readback!=updated: raise Conflict('exact-managed-readback','different-bytes','record-readback')"
        , "    return rebound"
        , "def add_share_manifest(current,device,binding,source,target):"
        , "    if current.get('state')!='managed': raise Conflict('managed-provider-record',token(current.get('state')),'share-provider-state')"
        , "    entry={'binding':binding,'source':source,'target':target}; existing=current['shares'].get(device)"
        , "    if existing is not None:"
        , "        if existing!=entry: raise Conflict(token(entry),token(existing),'share-device-collision')"
        , "        return current"
        , "    expected=payload(current['nonce'],'managed','absent',managed_identity=current['managed_identity'],shares=current['shares'])"
        , "    _,raw=read_record()"
        , "    if raw!=expected: raise Conflict('exact-provider-record','changed-record','share-manifest-version')"
        , "    shares=dict(current['shares']); shares[device]=entry"
        , "    updated=payload(current['nonce'],'managed','absent',managed_identity=current['managed_identity'],shares=shares)"
        , "    temporary=record_path+'.tmp-'+current['nonce']"
        , "    stage_exact(temporary,updated,'share-manifest-staging-size','share-manifest-staging-durability','share-manifest-staging')"
        , "    os.replace(temporary,record_path); fsync_dir(os.path.dirname(record_path))"
        , "    rebound,readback=read_record()"
        , "    if readback!=updated: raise Conflict('exact-share-manifest-readback','different-bytes','share-manifest-readback')"
        , "    return rebound"
        , "def instances():"
        , "    result=run([provider,'list',name,'--format','csv','-c','n'])"
        , "    require(result,'list')"
        , "    return [line.strip() for line in result.stdout.splitlines() if line.strip()]"
        , "def present(): return name in instances()"
        , "def config(key): return require(run([provider,'config','get',name,key]),'config-get-'+key)"
        , "def identity():"
        , "    value=config('volatile.uuid')"
        , "    if not identity_re.fullmatch(value): raise Unsupported('provider-returned-no-stable-uuid')"
        , "    return value"
        , "def verify(current):"
        , "    if current is None or current.get('state')!='managed': raise Conflict('managed-origin-record','absent-or-prepared','ownership-state')"
        , "    if not present(): raise Absent()"
        , "    observed=identity()"
        , "    if observed!=current['managed_identity']: raise Replaced(observed)"
        , "    if config('user.hostbootstrap.owner')!=current['nonce']: raise Replaced(observed)"
        , "    return observed"
        , "def confirm_absent(current):"
        , "    try: verify(current)"
        , "    except Absent: return"
        , "    emit('STILL_PRESENT')"
        , "def bind_after_launch(current):"
        , "    if not present(): raise OSError('launch-returned-without-instance')"
        , "    if config('user.hostbootstrap.owner')!=current['nonce']: raise Conflict(current['nonce'],'different-owner-tag','post-launch-owner-tag')"
        , "    return bind_record(current,identity())"
        , "def provision():"
        , "    current,_=read_record()"
        , "    if current is None and present(): emit('FOREIGN',identity())"
        , "    current,_=prepare_record()"
        , "    if current['state']=='managed': verify(current); emit('OWNED',current['managed_identity'])"
        , "    if present():"
        , "        observed_tag=config('user.hostbootstrap.owner')"
        , "        if observed_tag!=current['nonce']: raise Conflict(current['nonce'],token(observed_tag),'prepared-owner-tag')"
        , "        managed=bind_after_launch(current); emit('RECOVERED',managed['managed_identity'])"
        , "    args=[provider,'launch',image,name,'--vm','-c','limits.cpu='+cpu,'-c','limits.memory='+memory,'-c','user.hostbootstrap.owner='+current['nonce'],'-d','root,size='+storage]"
        , "    require(run(args),'launch')"
        , "    managed=bind_after_launch(current); emit('CREATED',managed['managed_identity'])"
        , "def ready():"
        , "    current,raw=read_record()"
        , "    if current is not None: current,raw=revalidate_record(current,raw)"
        , "    verify(current)"
        , "    state=require(run([provider,'list',name,'--format','csv','-c','s']),'state')"
        , "    changed=False"
        , "    if state=='STOPPED': verify(current); require(run([provider,'start',name]),'start'); verify(current); changed=True"
        , "    elif state!='RUNNING': raise Conflict('RUNNING-or-STOPPED',token(state or 'unknown-state'),'ready-provider-state')"
        , "    probe=run([provider,'exec',name,'--','true'])"
        , "    verify(current)"
        , "    if probe.returncode!=0: emit('NOTREADY',token(probe.stderr.splitlines()[0] if probe.stderr else 'guest-not-answering'))"
        , "    emit('READY' if changed else 'READY_ALREADY')"
        , "def stop():"
        , "    current,raw=read_record()"
        , "    if current is not None: current,raw=revalidate_record(current,raw)"
        , "    verify(current)"
        , "    state=require(run([provider,'list',name,'--format','csv','-c','s']),'state')"
        , "    verify(current)"
        , "    if state=='STOPPED': emit('STOPPED_ALREADY')"
        , "    if state!='RUNNING': emit('STILL_RUNNING',token(state or 'unknown-state'))"
        , "    verify(current); require(run([provider,'stop',name]),'stop'); verify(current)"
        , "    observed=require(run([provider,'list',name,'--format','csv','-c','s']),'state-after-stop')"
        , "    verify(current)"
        , "    if observed!='STOPPED': emit('STILL_RUNNING',token(observed or 'unknown-state'))"
        , "    emit('STOPPED')"
        , "def share_payload(device,binding,source,target,provider_identity,nonce,state):"
        , "    value={'magic':'hb-provider-share-origin-v1','binding':binding,'device':device,'managed_identity':provider_identity,'nonce':nonce,'origin':'absent','owner':owner,'source':source,'state':state,'target':target}"
        , "    return (json.dumps(value,sort_keys=True,separators=(',',':'))+'\\n').encode('utf-8')"
        , "def share_path(device): return record_path+'.'+device+'.share.json'"
        , "def read_exact_path(path):"
        , "    return read_path(path,65536,'share-record-size')"
        , "def decode_share(raw,device,binding,source,target,provider_identity):"
        , "    try: value=json.loads(raw.decode('utf-8'))"
        , "    except Exception: raise Conflict('well-formed-share-record','malformed','share-record-codec')"
        , "    expected={'magic':'hb-provider-share-origin-v1','binding':binding,'device':device,'managed_identity':provider_identity,'origin':'absent','owner':owner,'source':source,'target':target}"
        , "    for key,want in expected.items():"
        , "        if value.get(key)!=want: raise Conflict(token(want),token(value.get(key)),'share-record-'+key)"
        , "    nonce=value.get('nonce'); state=value.get('state')"
        , "    if not isinstance(nonce,str) or not re.fullmatch(r'[0-9a-f]{64}',nonce): raise Conflict('fresh-nonce',token(nonce),'share-record-nonce')"
        , "    if state not in ('prepared','managed') or set(value)!=set(expected)|{'nonce','state'}: raise Conflict('prepared-or-managed-share',token(state),'share-record-state')"
        , "    return value"
        , "def prepare_share(device,binding,source,target,provider_identity):"
        , "    path=share_path(device); raw=read_exact_path(path)"
        , "    if raw is not None:"
        , "        revalidate_path(path,raw,'share-record-durability')"
        , "        decoded=decode_share(raw,device,binding,source,target,provider_identity)"
        , "        candidates=stage_candidates(path)"
        , "        if candidates:"
        , "            if len(candidates)!=1 or candidates[0][1]!=decoded['nonce']: raise Conflict('one-matching-share-staging-record','different-staging-set','share-initial-staging-set')"
        , "            staging,_=candidates[0]; staged=read_exact_path(staging); expected=share_payload(device,binding,source,target,provider_identity,decoded['nonce'],'prepared')"
        , "            if staged is None or not expected.startswith(staged): raise Conflict('exact-initial-share-staging','different-bytes','share-initial-staging')"
        , "            os.unlink(staging); fsync_dir(os.path.dirname(path))"
        , "        return decoded,raw"
        , "    candidates=stage_candidates(path)"
        , "    if len(candidates)>1: raise Conflict('at-most-one-share-staging-record','multiple','share-initial-staging-set')"
        , "    nonce=candidates[0][1] if candidates else secrets.token_hex(32); raw=share_payload(device,binding,source,target,provider_identity,nonce,'prepared')"
        , "    staging=path+'.prepare-'+nonce"
        , "    stage_exact(staging,raw,'share-initial-staging-size','share-initial-staging-durability','share-initial-staging')"
        , "    publish_no_replace(staging,path,raw,'share-origin-publication')"
        , "    readback=read_exact_path(path)"
        , "    if readback!=raw: raise Conflict('exact-share-origin-readback','different-bytes','share-record-readback')"
        , "    return decode_share(readback,device,binding,source,target,provider_identity),readback"
        , "def bind_share(current,device,binding,source,target,provider_identity):"
        , "    if current['state']=='managed': return current"
        , "    path=share_path(device); expected=share_payload(device,binding,source,target,provider_identity,current['nonce'],'prepared')"
        , "    if read_exact_path(path)!=expected: raise Conflict('exact-prepared-share-record','changed-record','share-record-version')"
        , "    updated=share_payload(device,binding,source,target,provider_identity,current['nonce'],'managed')"
        , "    temporary=path+'.tmp-'+current['nonce']"
        , "    stage_exact(temporary,updated,'share-record-staging-size','share-record-staging-durability','share-record-staging')"
        , "    os.replace(temporary,path); fsync_dir(os.path.dirname(path))"
        , "    if read_exact_path(path)!=updated: raise Conflict('exact-managed-share-readback','different-bytes','share-record-readback')"
        , "    return decode_share(updated,device,binding,source,target,provider_identity)"
        , "def device_value(device,key): return require(run([provider,'config','device','get',name,device,key]),'device-get-'+key)"
        , "def verify_device(device,source,target):"
        , "    observed={'type':device_value(device,'type'),'source':device_value(device,'source'),'path':device_value(device,'path')}"
        , "    expected={'type':'disk','source':source,'path':target}"
        , "    if observed!=expected: raise Conflict(token(expected),token(observed),'share-device-shape')"
        , "def share():"
        , "    if len(extra)!=4: raise OSError('share-needs-device-binding-source-and-target')"
        , "    device,binding,source,target=extra; current,raw=read_record()"
        , "    if current is not None: current,raw=revalidate_record(current,raw)"
        , "    provider_identity=verify(current)"
        , "    devices=require(run([provider,'config','device','list',name]),'device-list').splitlines()"
        , "    verify(current)"
        , "    expected_entry={'binding':binding,'source':source,'target':target}; manifest_entry=current['shares'].get(device)"
        , "    if device in devices:"
        , "        if manifest_entry is None: raise Conflict('owned-share-manifest','absent','share-adoption-refused')"
        , "        if manifest_entry!=expected_entry: raise Conflict(token(expected_entry),token(manifest_entry),'share-device-collision')"
        , "        raw=read_exact_path(share_path(device))"
        , "        if raw is None: raise Conflict('owned-share-origin-record','absent','share-adoption-refused')"
        , "        revalidate_path(share_path(device),raw,'share-record-durability')"
        , "        share_record=decode_share(raw,device,binding,source,target,provider_identity); verify_device(device,source,target); verify(current)"
        , "        if share_record['state']=='prepared': bind_share(share_record,device,binding,source,target,provider_identity); verify(current); emit('SHARE_REPAIRED')"
        , "        emit('SHARE_ALREADY')"
        , "    current=add_share_manifest(current,device,binding,source,target)"
        , "    share_record,_=prepare_share(device,binding,source,target,provider_identity)"
        , "    verify(current); require(run([provider,'config','device','add',name,device,'disk','source='+source,'path='+target]),'device-add'); verify(current)"
        , "    verify_device(device,source,target); bind_share(share_record,device,binding,source,target,provider_identity); verify(current); emit('SHARE_ATTACHED')"
        , "def validated_main_staging(current):"
        , "    path=record_path+'.tmp-'+current['nonce']; staged=read_path(path,65536,'delete-main-staging-size')"
        , "    if staged is None: return []"
        , "    revalidate_path(path,staged,'delete-main-staging-durability')"
        , "    return [(path,staged)]"
        , "def validated_share_files(current,provider_devices):"
        , "    files=[]; expected_paths=set(); provider_identity=current.get('managed_identity')"
        , "    for device,entry in sorted(current.get('shares',{}).items()):"
        , "        path=share_path(device); raw=read_exact_path(path)"
        , "        expected_paths.add(path)"
        , "        for staging,_ in stage_candidates(path):"
        , "            staged=read_exact_path(staging); expected_paths.add(staging)"
        , "            if staged is not None: revalidate_path(staging,staged,'delete-share-initial-staging-durability'); files.append((staging,staged))"
        , "        if raw is None:"
        , "            if provider_devices is not None and device in provider_devices: raise Conflict('recorded-share-origin','absent','delete-share-record-with-present-device')"
        , "            continue"
        , "        revalidate_path(path,raw,'delete-share-record-durability')"
        , "        share_record=decode_share(raw,device,entry['binding'],entry['source'],entry['target'],provider_identity)"
        , "        temporary=path+'.tmp-'+share_record['nonce']; staged=read_exact_path(temporary)"
        , "        expected_paths.add(temporary)"
        , "        if staged is not None:"
        , "            revalidate_path(temporary,staged,'delete-share-staging-durability')"
        , "            decode_share(staged,device,entry['binding'],entry['source'],entry['target'],provider_identity)"
        , "            files.append((temporary,staged))"
        , "        files.append((path,raw))"
        , "    directory=os.path.dirname(record_path); prefix=os.path.basename(record_path)+'.hb-share-'"
        , "    observed_paths={os.path.join(directory,entry) for entry in os.listdir(directory) if entry.startswith(prefix) and '.share.json' in entry}"
        , "    extras=observed_paths-expected_paths"
        , "    if extras: raise Conflict('manifested-share-records',token(os.path.basename(sorted(extras)[0])),'unmanifested-share-record')"
        , "    return files"
        , "def orphan_metadata_paths():"
        , "    directory=os.path.dirname(record_path); base=os.path.basename(record_path); found=[]"
        , "    for entry in os.listdir(directory):"
        , "        if entry.startswith(base+'.hb-share-') and '.share.json' in entry: found.append(os.path.join(directory,entry))"
        , "        elif entry.startswith(base+'.prepare-') or entry.startswith(base+'.tmp-'): found.append(os.path.join(directory,entry))"
        , "    return sorted(found)"
        , "def remove_validated_files(files):"
        , "    for path,expected in files:"
        , "        if read_exact_path(path)!=expected: raise Conflict('exact-record-for-release','replaced','provider-metadata-release')"
        , "        os.unlink(path)"
        , "    if files: fsync_dir(os.path.dirname(record_path))"
        , "def delete():"
        , "    current,raw=read_record()"
        , "    if current is None and not present():"
        , "        fsync_dir(os.path.dirname(record_path))"
        , "        if read_path(record_path,65536,'delete-record-size') is not None or present(): raise Conflict('durably-absent-provider','reappeared','delete-absence-revalidation')"
        , "        orphans=orphan_metadata_paths()"
        , "        if orphans: raise Conflict('no-orphan-provider-metadata',token(os.path.basename(orphans[0])),'delete-orphan-metadata')"
        , "        emit('DELETED_ALREADY')"
        , "    if current is None: raise Conflict('managed-origin-record','absent','delete-record')"
        , "    current,raw=revalidate_record(current,raw)"
        , "    is_present=present()"
        , "    provider_devices=None"
        , "    if is_present:"
        , "        verify(current)"
        , "        provider_devices=set(require(run([provider,'config','device','list',name]),'delete-device-list').splitlines()); verify(current)"
        , "    files=validated_main_staging(current)+validated_share_files(current,provider_devices)"
        , "    if not is_present:"
        , "        confirm_absent(current)"
        , "        remove_validated_files(files)"
        , "        confirm_absent(current)"
        , "        if read_path(record_path,65536,'delete-record-size')!=raw: raise Conflict('exact-record-for-release','replaced','record-release')"
        , "        os.unlink(record_path); fsync_dir(os.path.dirname(record_path)); emit('DELETED')"
        , "    state=require(run([provider,'list',name,'--format','csv','-c','s']),'delete-state')"
        , "    verify(current)"
        , "    if state!='STOPPED': emit('STILL_PRESENT')"
        , "    require(run([provider,'delete',name,'--force']),'delete')"
        , "    confirm_absent(current)"
        , "    remove_validated_files(files)"
        , "    confirm_absent(current)"
        , "    if read_path(record_path,65536,'delete-record-size')!=raw: raise Conflict('exact-record-for-release','replaced','record-release')"
        , "    os.unlink(record_path); fsync_dir(os.path.dirname(record_path)); emit('DELETED')"
        , "def guest():"
        , "    if not extra: raise OSError('guest-command-empty')"
        , "    current,raw=read_record()"
        , "    if current is not None: current,raw=revalidate_record(current,raw)"
        , "    verify(current)"
        , "    result=run([provider,'exec',name,'--']+extra); verify(current)"
        , "    emit('GUEST',str(result.returncode),result.stdout.encode().hex() or '-',result.stderr.encode().hex() or '-')"
        , "try:"
        , "    {'provision':provision,'ready':ready,'stop':stop,'share':share,'delete':delete,'guest':guest}[mode]()"
        , "except Absent: emit('ABSENT')"
        , "except Replaced as failure: emit('REPLACED',failure.identity)"
        , "except Conflict as failure: emit('CONFLICT',failure.expected,failure.observed,failure.reason)"
        , "except Unsupported as failure: emit('UNSUPPORTED',str(failure))"
        , "except Exception as failure: emit('FAILED',token(str(failure)))"
        ]

-- Total private parsers -------------------------------------------------------

data WireReport
    = WireCreated String
    | WireRecovered String
    | WireOwned String
    | WireForeign String
    | WireReadyChanged
    | WireReadyAlready
    | WireNotReady Text
    | WireStopped
    | WireStoppedAlready
    | WireStillRunning Text
    | WireShareAttached
    | WireShareRepaired
    | WireShareAlready
    | WireDeleted
    | WireDeletedAlready
    | WireStillPresent
    | WireAbsent
    | WireReplaced String
    | WireGuest Int String String
    | WireConflict Text Text Text
    | WireUnsupported Text
    | WireFailed Text
    deriving (Eq, Show)

parseWireReport :: RawProviderOutcome -> WireReport
parseWireReport raw = case raw of
    RawProviderFailure reason -> WireFailed (Text.pack reason)
    RawProviderExit exitCode out err
        | exitCode /= ExitSuccess ->
            WireFailed ("the exclusive provider command failed: " <> firstLineText err)
        | not (null err) ->
            WireFailed ("the successful exclusive provider command wrote stderr: " <> firstLineText err)
        | otherwise -> case lines out of
            [line] -> parseWireTokens line
            _ -> WireFailed "the provider backend report was not exactly one line"

parseWireTokens :: String -> WireReport
parseWireTokens line
    | length line > providerWireLengthBound = WireFailed "the provider backend report exceeded the closed wire bound"
    | line /= unwords fields = WireFailed "the provider backend report did not use canonical token spacing"
    | otherwise = case fields of
        ["CREATED", identity] | validIdentity identity -> WireCreated identity
        ["RECOVERED", identity] | validIdentity identity -> WireRecovered identity
        ["OWNED", identity] | validIdentity identity -> WireOwned identity
        ["FOREIGN", identity] | validIdentity identity -> WireForeign identity
        ["READY"] -> WireReadyChanged
        ["READY_ALREADY"] -> WireReadyAlready
        ["NOTREADY", reason] | validWireToken reason -> WireNotReady (Text.pack reason)
        ["STOPPED"] -> WireStopped
        ["STOPPED_ALREADY"] -> WireStoppedAlready
        ["STILL_RUNNING", reason] | validWireToken reason -> WireStillRunning (Text.pack reason)
        ["SHARE_ATTACHED"] -> WireShareAttached
        ["SHARE_REPAIRED"] -> WireShareRepaired
        ["SHARE_ALREADY"] -> WireShareAlready
        ["DELETED"] -> WireDeleted
        ["DELETED_ALREADY"] -> WireDeletedAlready
        ["STILL_PRESENT"] -> WireStillPresent
        ["ABSENT"] -> WireAbsent
        ["REPLACED", identity] | validIdentity identity -> WireReplaced identity
        ["GUEST", guestExit, guestOut, guestErr]
            | validWireToken guestExit
            , [(code, "")] <- reads guestExit
            , validHexField guestOut
            , validHexField guestErr ->
                WireGuest code guestOut guestErr
        ["CONFLICT", expected, observed, reason]
            | all validWireToken [expected, observed, reason] ->
                WireConflict (Text.pack expected) (Text.pack observed) (Text.pack reason)
        ["UNSUPPORTED", reason] | validWireToken reason -> WireUnsupported (Text.pack reason)
        ["FAILED", reason] | validWireToken reason -> WireFailed (Text.pack reason)
        _ -> WireFailed ("unparseable provider backend report: " <> Text.pack line)
  where
    fields = words line

parseProvisionReport :: PreparedProviderBinding scope planId backendId providerId -> RawProviderOutcome -> ProviderProvisionObservation
parseProvisionReport binding raw = case parseWireReport raw of
    WireCreated _ -> ProviderProvisionCreated generation
    WireRecovered _ -> ProviderProvisionRepaired generation
    WireOwned _ -> ProviderProvisionAlreadyOwned generation
    WireForeign identity -> ProviderProvisionForeign (identityGeneration identity) (foreignObservation key identity)
    WireReplaced identity -> ProviderProvisionForeign (identityGeneration identity) (foreignObservation key identity)
    WireAbsent -> ProviderProvisionAbsent
    WireConflict expected observed reason -> ProviderProvisionConflict (conflict key expected observed reason)
    WireUnsupported reason -> ProviderProvisionUnsupported (unsupported "provision provider" reason)
    WireFailed reason -> ProviderProvisionFailed (failed "provision provider" reason)
    other -> ProviderProvisionFailed (failed "provision provider" (unexpected other))
  where
    generation = preparedProviderBindingGeneration binding
    key = preparedProviderBindingResourceKey binding

parseReadyReport :: PreparedProviderBinding scope planId backendId providerId -> RawProviderOutcome -> ProviderReadyObservation
parseReadyReport binding raw = case parseWireReport raw of
    WireReadyChanged -> ProviderReadyObserved generation
    WireReadyAlready -> ProviderReadyAlready generation
    WireNotReady reason -> ProviderReadyNotReady reason
    WireAbsent -> ProviderReadyAbsent
    WireReplaced identity -> ProviderReadyReplaced (identityGeneration identity) (foreignObservation key identity)
    WireConflict expected observed reason -> ProviderReadyConflict (conflict key expected observed reason)
    WireUnsupported reason -> ProviderReadyUnsupported (unsupported "reconcile provider ready" reason)
    WireFailed reason -> ProviderReadyFailed (failed "reconcile provider ready" reason)
    other -> ProviderReadyFailed (failed "reconcile provider ready" (unexpected other))
  where
    generation = preparedProviderBindingGeneration binding
    key = preparedProviderBindingResourceKey binding

parseStopReport :: PreparedProviderBinding scope planId backendId providerId -> RawProviderOutcome -> ProviderStopObservation
parseStopReport binding raw = case parseWireReport raw of
    WireStopped -> ProviderStopped generation
    WireStoppedAlready -> ProviderAlreadyStopped generation
    WireStillRunning reason -> ProviderStopStillRunning reason
    WireAbsent -> ProviderStopAbsent
    WireReplaced identity -> ProviderStopReplaced (identityGeneration identity) (foreignObservation key identity)
    WireConflict expected observed reason -> ProviderStopConflict (conflict key expected observed reason)
    WireUnsupported reason -> ProviderStopUnsupported (unsupported "stop provider" reason)
    WireFailed reason -> ProviderStopFailed (failed "stop provider" reason)
    other -> ProviderStopFailed (failed "stop provider" (unexpected other))
  where
    generation = preparedProviderBindingGeneration binding
    key = preparedProviderBindingResourceKey binding

parseShareReport :: PreparedProviderBinding scope planId backendId providerId -> Word64 -> RawProviderOutcome -> ProviderShareObservation
parseShareReport binding shareGeneration raw = case parseWireReport raw of
    WireShareAttached -> ProviderShareAttached shareGeneration
    WireShareRepaired -> ProviderShareRepaired shareGeneration
    WireShareAlready -> ProviderShareAlreadyReady shareGeneration
    WireAbsent -> ProviderShareAbsent
    WireReplaced identity -> ProviderShareProviderReplaced (identityGeneration identity) (foreignObservation key identity)
    WireConflict expected observed reason -> ProviderShareConflict (conflict key expected observed reason)
    WireUnsupported reason -> ProviderShareUnsupported (unsupported "reconcile provider share" reason)
    WireFailed reason -> ProviderShareFailed (failed "reconcile provider share" reason)
    other -> ProviderShareFailed (failed "reconcile provider share" (unexpected other))
  where
    key = preparedProviderBindingResourceKey binding

parseDeleteReport :: PreparedProviderBinding scope planId backendId providerId -> RawProviderOutcome -> ProviderDeleteObservation
parseDeleteReport binding raw = case parseWireReport raw of
    WireDeleted -> ProviderDeleted
    WireDeletedAlready -> ProviderAlreadyDeleted
    WireStillPresent -> ProviderDeleteStillPresent (preparedProviderBindingGeneration binding)
    WireAbsent -> ProviderDeleteFailed (failed "delete provider" "the provider disappeared during conditional deletion; retry to reconcile durable cleanup")
    WireReplaced identity -> ProviderDeleteReplaced (identityGeneration identity) (foreignObservation key identity)
    WireConflict expected observed reason -> ProviderDeleteConflict (conflict key expected observed reason)
    WireUnsupported reason -> ProviderDeleteUnsupported (unsupported "delete provider" reason)
    WireFailed reason -> ProviderDeleteFailed (failed "delete provider" reason)
    other -> ProviderDeleteFailed (failed "delete provider" (unexpected other))
  where
    key = preparedProviderBindingResourceKey binding

parseGuestOutcome :: Text -> RawProviderOutcome -> RawProviderOutcome
parseGuestOutcome _key raw = case parseWireReport raw of
    WireGuest code out err ->
        case (decodeHexField out, decodeHexField err) of
            (Just stdout, Just stderr) -> RawProviderExit (toExitCode code) stdout stderr
            _ -> RawProviderFailure "the backend returned invalid guest hex output"
    WireConflict expected observed reason ->
        RawProviderFailure (providerConflictMarker expected observed reason)
    WireUnsupported reason -> RawProviderFailure (Text.unpack reason)
    WireFailed reason -> RawProviderFailure (Text.unpack reason)
    WireAbsent -> RawProviderFailure "the managed provider is absent"
    WireReplaced identity ->
        RawProviderFailure (providerConflictMarker "managed-provider-identity" (Text.pack identity) "provider-replaced")
    other -> RawProviderFailure (Text.unpack (unexpected other))

toExitCode :: Int -> ExitCode
toExitCode 0 = ExitSuccess
toExitCode code = ExitFailure code

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

unexpected :: WireReport -> Text
unexpected report = "unexpected provider backend report: " <> Text.pack (show report)

validIdentity :: String -> Bool
validIdentity value =
    not (null value)
        && length value <= 240
        && all (\character -> isAlphaNum character || character `elem` (":._-" :: String)) value

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

validHexField :: String -> Bool
validHexField "-" = True
validHexField value =
    length value <= guestHexFieldLengthBound
        && even (length value)
        && not (null value)
        && all (`elem` ("0123456789abcdef" :: String)) value

-- A guest stream is independently capped at the alias protocol's 1024-byte
-- report bound.  Hex encoding doubles that payload; the outer envelope allows
-- two such streams plus the fixed GUEST tag, exit code, and separators.
guestHexFieldLengthBound :: Int
guestHexFieldLengthBound = 2 * 1024

providerWireLengthBound :: Int
providerWireLengthBound = 32 + (2 * guestHexFieldLengthBound)

decodeHexField :: String -> Maybe String
decodeHexField "-" = Just ""
decodeHexField value
    | not (validHexField value) = Nothing
    | otherwise = traverse decodePair (pairs value)
  where
    pairs [] = []
    pairs (left : right : rest) = [left, right] : pairs rest
    pairs _ = []
    decodePair [left, right] =
        Just (toEnum (hexValue left * 16 + hexValue right))
    decodePair _ = Nothing
    hexValue character
        | character >= '0' && character <= '9' = fromEnum character - fromEnum '0'
        | otherwise = fromEnum character - fromEnum 'a' + 10

firstLine :: String -> String
firstLine value = case lines value of
    line : _ -> line
    [] -> ""

firstLineText :: String -> Text
firstLineText = Text.pack . firstLine
