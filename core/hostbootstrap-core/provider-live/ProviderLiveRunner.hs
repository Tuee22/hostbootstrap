{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- | Explicitly confirmed, native Linux/x86_64 Incus lifecycle evidence.

This component is deliberately absent from the ordinary test graph.  It
creates one collision-resistant VM name and host-backed share, admits the
production Incus and Direct backends, and reaches lifecycle mutation only
through plan-prepared calls and opaque managed provider authority.
-}
module ProviderLiveRunner (
    runProviderLiveGate,
) where

import Control.Exception (
    SomeException,
    displayException,
    try,
 )
import Control.Monad (unless, when)
import Data.Char (isAlphaNum, isSpace, toLower)
import Data.List (dropWhileEnd, isPrefixOf, isSuffixOf, stripPrefix)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.Effect.Interpreter (resolveLaunch)
import HostBootstrap.Ensure (runTool)
import HostBootstrap.Ensure.Incus (
    IncusProviderStatus (IncusProviderReady),
    probeIncusProviderStatus,
 )
import HostBootstrap.HostConfig (HostConfig, buildHostConfig, resolveMaybe)
import HostBootstrap.HostTool (
    HostTool (Docker, Incus),
    absExePath,
 )
import HostBootstrap.Incus (IncusVM (IncusVM))
import HostBootstrap.Ownership.Object (ownershipFaultMessage)
import HostBootstrap.Ownership.Primitive (
    OwnershipPrimitive (rowCreateFile, rowSyncParent),
    withOwnershipRow,
 )
import HostBootstrap.Ownership.Row (ownershipRowForHost)
import HostBootstrap.Lima (LimaVM (LimaVM))
import HostBootstrap.Reconcile (
    FailureDetail (FailureDetail),
    ReconcileError (Failure),
    RecoveryDisposition (ReprobeBeforeRetry),
 )
import HostBootstrap.Substrate (
    Arch (Amd64),
    Substrate (Substrate),
    SubstrateName (LinuxCpu),
 )
import HostBootstrap.Substrate.Provider (
    ProviderKind (ProviderDirectHost, ProviderIncus),
    VMHandles (VMHandles),
    selectProviderKind,
 )
import HostBootstrap.Substrate.Provider.Alias (mkGuestAliasSpec)
import HostBootstrap.Substrate.Provider.Backend (
    DirectRootObservation (..),
    admitDirectRoot,
    directEgressCommand,
    discoverStrongProviderBackend,
    mkDirectHostBackendSpec,
    mkIncusBackendSpec,
    observeDirectRoot,
 )
import HostBootstrap.Substrate.Provider.Reconcile (mkProviderShareSpec)
import HostBootstrap.Wsl2 (Wsl2VM (Wsl2VM))
import ProviderLiveAliasFixture (runLiveDirectRoute, runLiveIncusRoute)
import System.Directory (
    Permissions (readable, writable),
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesPathExist,
    getPermissions,
    listDirectory,
    removePathForcibly,
 )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeFileName, (</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Temp (createTempDirectory)
import qualified System.Info as Info

confirmationVariable :: String
confirmationVariable = "HOSTBOOTSTRAP_PROVIDER_LIVE_CONFIRM"

confirmationValue :: String
confirmationValue = "incus-direct-host"

managedPrefix :: String
managedPrefix = "hostbootstrap-provider-live-"

incusImage :: String
incusImage = "images:ubuntu/24.04"

directEgressImage :: String
directEgressImage = "docker.io/library/alpine:3.22"

runProviderLiveGate :: IO ()
runProviderLiveGate = do
    requirePlatformAndConfirmation
    root <- createTempDirectory "/var/tmp" managedPrefix
    let token = liveToken root
        vmName = managedPrefix ++ token
    outcome <- try @SomeException (runConfirmedGate root token vmName)
    case outcome of
        Right () ->
            putStrLn
                "provider-live: PASS — prepared Incus lifecycle/share/alias/restart/delete and mutation-free Direct refusal"
        Left exception -> do
            hPutStrLn stderr (cleanupRemedy root vmName (displayException exception))
            failGate ("provider-live failed: " ++ displayException exception)

runConfirmedGate :: FilePath -> String -> String -> IO ()
runConfirmedGate root token vmName = do
    let shareRoot = root </> "share"
        stateRoot = root </> "provider-state"
        incusPlanRoot = root </> "incus-plan"
        directPlanRoot = root </> "direct-plan"
        aliasPath = "/var/tmp/" ++ vmName ++ "-alias"
        handles =
            VMHandles
                (IncusVM vmName incusImage)
                (LimaVM vmName)
                (Wsl2VM vmName)
                managedPrefix
        incusProvider = selectProviderKind ProviderIncus handles
        directProvider = selectProviderKind ProviderDirectHost handles
    createDirectoryIfMissing True shareRoot
    createDirectoryIfMissing True stateRoot
    createDirectoryIfMissing True incusPlanRoot
    createDirectoryIfMissing True directPlanRoot
    config <- buildHostConfig (Substrate LinuxCpu Amd64)

    putStrLn "provider-live: preflight native Linux/x86_64 Incus and KVM"
    requireIncusPreflight config
    initiallyPresent <- observeIncusPresence config vmName
    when initiallyPresent $
        failGate ("collision: generated Incus VM already exists: " ++ vmName)
    writeDurableIntent
        root
        ( unlines
            [ "format=hostbootstrap-provider-live-intent-v2"
            , "vm=" ++ vmName
            , "root=" ++ root
            , "token=" ++ token
            , "preflight=absent"
            ]
        )

    shareSpec <- expectReconcile "validate Incus share" (mkProviderShareSpec shareRoot shareRoot)
    aliasSpec <- expectReconcile "validate guest alias" (mkGuestAliasSpec aliasPath shareRoot)
    incusSpec <-
        expectReconcile
            "validate Incus backend"
            (mkIncusBackendSpec vmName incusImage managedPrefix config stateRoot 2 "2GiB" "12GiB")
    admittedIncus <-
        discoverStrongProviderBackend
            config
            incusSpec
            ( \backend ->
                runLiveIncusRoute
                    incusPlanRoot
                    config
                    backend
                    incusProvider
                    shareSpec
                    aliasSpec
                    (asReconcileFailure "verify live alias before restart" (verifyOwnedState config vmName shareRoot))
                    (asReconcileFailure "verify live alias after restart" (verifyOwnedState config vmName shareRoot))
            )
    expectReconcile "run prepared Incus route" (admittedIncus >>= id)
    absentAfterDelete <- observeIncusPresence config vmName
    when absentAfterDelete $
        failGate "the prepared delete returned without proving VM absence"
    assertAliasOriginState shareRoot 0
    assertProviderRecordForgotten stateRoot vmName

    putStrLn "provider-live: exercise Direct prepared admission and sealed refusal boundary"
    directSpec <-
        expectReconcile
            "validate Direct backend"
            (mkDirectHostBackendSpec config shareRoot directEgressImage)
    admittedDirect <-
        discoverStrongProviderBackend
            config
            directSpec
            (\backend -> runLiveDirectRoute directPlanRoot config backend directProvider shareSpec)
    expectReconcile "run prepared Direct route" (admittedDirect >>= id)
    assertDirectAdmissionIsReadOnly config shareRoot
    stillAbsent <- observeIncusPresence config vmName
    when stillAbsent $
        failGate "the mutation-free Direct route recreated the Incus VM"

    removePathForcibly root
    residue <- doesPathExist root
    when residue $
        failGate ("provider-live root remained after successful teardown: " ++ root)

requireIncusPreflight :: HostConfig -> IO ()
requireIncusPreflight config = do
    status <- probeIncusProviderStatus config
    unless (status == IncusProviderReady) $
        failGate ("Incus read-only provider preflight is not ready: " ++ show status)
    kvmPresent <- doesPathExist "/dev/kvm"
    kvmReadWrite <-
        if kvmPresent
            then (\held -> readable held && writable held) <$> getPermissions "/dev/kvm"
            else pure False
    unless (kvmPresent && kvmReadWrite) $
        failGate "/dev/kvm is absent or is not readable and writable by the invoking user"

verifyOwnedState :: HostConfig -> String -> FilePath -> IO ()
verifyOwnedState config vmName shareRoot = do
    verifyIncusSizing config vmName
    state <- requireCommand config Incus ["list", vmName, "--format", "csv", "-c", "s"]
    assertEqual "Incus managed state" "RUNNING" (trim state)
    assertAliasOriginState shareRoot 1

verifyIncusSizing :: HostConfig -> String -> IO ()
verifyIncusSizing config vmName = do
    cpu <- requireCommand config Incus ["config", "get", vmName, "limits.cpu"]
    memory <- requireCommand config Incus ["config", "get", vmName, "limits.memory"]
    storage <- requireCommand config Incus ["config", "device", "get", vmName, "root", "size"]
    assertEqual "Incus actual CPU limit" "2" (trim cpu)
    assertEqual "Incus actual memory limit" "2GiB" (trim memory)
    assertEqual "Incus actual root size" "12GiB" (trim storage)

observeIncusPresence :: HostConfig -> String -> IO Bool
observeIncusPresence config vmName = do
    output <- requireCommand config Incus ["list", vmName, "--format", "csv", "-c", "n"]
    pure (vmName `elem` filter (not . null) (map trim (lines output)))

requireCommand :: HostConfig -> HostTool -> [String] -> IO String
requireCommand config tool args = do
    result <- runTool config tool args
    case result of
        Left failure -> failGate (commandLabel tool args ++ ": " ++ failure)
        Right (ExitSuccess, out, "") -> pure out
        Right (ExitSuccess, out, err) ->
            failGate (commandLabel tool args ++ " wrote stderr: " ++ firstDiagnostic out err)
        Right (ExitFailure code, out, err) ->
            failGate
                ( commandLabel tool args
                    ++ " exited "
                    ++ show code
                    ++ ": "
                    ++ firstDiagnostic out err
                )

{- | The Direct realization admits a frame and mutates nothing, and its whole
effect surface says so by construction.

The admission is this binary's own observation of the kernel followed by a total
decision over it, so the audit takes that observation against the live root and
applies the same decision — there is no program to compare and no seam to record
through.  The one command Direct still issues is a value this binary can resolve
without launching anything, so the audit applies the one resolver to it and
compares the exact executable and argument vector production would launch
(§ NN).
-}
assertDirectAdmissionIsReadOnly :: HostConfig -> FilePath -> IO ()
assertDirectAdmissionIsReadOnly config root = do
    docker <- maybe (failGate "Direct audit has no resolved Docker") (pure . absExePath) (resolveMaybe config Docker)
    observation <- observeDirectRoot root
    unless
        ( directRootAbsolute observation
            && not (directRootSymbolicLink observation)
            && directRootDirectory observation
            && directRootCanonical observation
            && directRootAccessible observation
        )
        $ failGate ("the live Direct root is not the admissible canonical directory: " ++ show observation)
    case admitDirectRoot root observation of
        Left refusal -> failGate ("the live Direct root was refused: " ++ Text.unpack refusal)
        Right () -> pure ()
    egress <- case resolveLaunch config (directEgressCommand directEgressImage) of
        Left refusal -> failGate ("Direct audit could not resolve the egress probe: " ++ refusal)
        Right launch -> pure launch
    unless (egress == (docker, ["manifest", "inspect", directEgressImage])) $
        failGate ("the Direct egress probe is not the read-only manifest inspect: " ++ show egress)

assertAliasOriginState :: FilePath -> Int -> IO ()
assertAliasOriginState shareRoot expected = do
    let directory = shareRoot </> ".hostbootstrap-alias-origin-v1"
    present <- doesDirectoryExist directory
    entries <- if present then listDirectory directory else pure []
    let records = filter (".json" `isSuffixOf`) entries
        staging = filter (".prepared-" `isInfix`) entries
    assertEqual "host-visible alias origin-record count" expected (length records)
    unless (null staging) $
        failGate ("alias origin staging residue remained: " ++ show staging)
    when (expected == 0 && present) $
        failGate ("alias origin directory remained after conditional release: " ++ show entries)

assertProviderRecordForgotten :: FilePath -> String -> IO ()
assertProviderRecordForgotten stateRoot vmName = do
    let records = stateRoot </> "records"
    present <- doesDirectoryExist records
    entries <- if present then listDirectory records else pure []
    let residue = filter ((vmName ++ ".rec") `isPrefixOf`) entries
    unless (null residue) $
        failGate ("provider origin or staging metadata remained: " ++ show residue)

asReconcileFailure :: Text.Text -> IO () -> IO (Either ReconcileError ())
asReconcileFailure operation action = do
    outcome <- try @SomeException action
    pure $ case outcome of
        Right () -> Right ()
        Left exception ->
            Left
                ( Failure
                    ( FailureDetail
                        operation
                        (Text.pack (displayException exception))
                        ReprobeBeforeRetry
                    )
                )

expectReconcile :: String -> Either ReconcileError value -> IO value
expectReconcile operation = either (failGate . ((operation ++ ": ") ++) . show) pure

{- | Publish this run's durable intent through the host's own ownership row.

The intent is the breadcrumb a crashed gate leaves behind, so it has to be
created at a name nothing else holds and made durable together with the
directory that names it.  Both are primitives the binary already owns (§ EE,
§ LL), and reaching them through the row rather than spelling them again here is
what keeps this gate from carrying a second, host-specific copy of an operation
the project holds once — and what lets every gate host compile it.
-}
writeDurableIntent :: FilePath -> String -> IO ()
writeDurableIntent root payload =
    withOwnershipRow ownershipRowForHost $ \row -> do
        rowCreateFile row path (TextEncoding.encodeUtf8 (Text.pack payload))
            >>= expectRow "publish the provider-live durable intent"
        rowSyncParent row path
            >>= expectRow "make the provider-live intent directory durable"
  where
    path = root </> ".hostbootstrap-provider-live-intent-v2"
    expectRow operation =
        either
            (\fault -> failGate (operation ++ ": " ++ Text.unpack (ownershipFaultMessage fault)))
            pure

cleanupRemedy :: FilePath -> String -> String -> String
cleanupRemedy root vmName reason =
    unlines
        [ "provider-live preserved its durable intent, state, and share directory"
        , "reason: " ++ reason
        , "VM: " ++ vmName
        , "state/share/intent: " ++ root
        , "inspect the origin before acting: incus list " ++ vmName ++ " && incus config show " ++ vmName
        , "the prepared route deletes only the exact origin-bound VM; do not delete a same-named replacement"
        ]

requirePlatformAndConfirmation :: IO ()
requirePlatformAndConfirmation = do
    unless (map toLower Info.os == "linux" && map toLower Info.arch `elem` ["x86_64", "amd64"]) $
        failGate
            ( "provider-live requires native Linux/x86_64; observed "
                ++ Info.os
                ++ "/"
                ++ Info.arch
            )
    confirmation <- lookupEnv confirmationVariable
    unless (confirmation == Just confirmationValue) $
        failGate
            ( "provider-live is destructive and requires "
                ++ confirmationVariable
                ++ "="
                ++ confirmationValue
            )

liveToken :: FilePath -> String
liveToken root =
    let base = takeFileName root
        suffix = maybe base id (stripPrefix managedPrefix base)
        cleaned = map normalize suffix
     in take 48 (dropWhile (== '-') cleaned)
  where
    normalize character
        | isAlphaNum character = toLower character
        | otherwise = '-'

commandLabel :: HostTool -> [String] -> String
commandLabel tool args = show tool ++ " " ++ unwords args

firstDiagnostic :: String -> String -> String
firstDiagnostic out err =
    let diagnostic = trim (if null (trim err) then out else err)
     in if null diagnostic then "no diagnostic" else takeWhile (`notElem` ("\r\n" :: String)) diagnostic

trim :: String -> String
trim = dropWhile isSpace . dropWhileEnd isSpace

isInfix :: String -> String -> Bool
isInfix needle haystack = any (needle `isPrefixOf`) (tailsOf haystack)

tailsOf :: [value] -> [[value]]
tailsOf [] = [[]]
tailsOf whole@(_ : rest) = whole : tailsOf rest

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
    unless (actual == expected) $
        failGate
            ( label
                ++ ": expected "
                ++ show expected
                ++ ", observed "
                ++ show actual
            )

failGate :: String -> IO value
failGate = ioError . userError
