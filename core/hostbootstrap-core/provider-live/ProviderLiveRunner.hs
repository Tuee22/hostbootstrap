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

import Control.Concurrent (threadDelay)
import Control.Exception (
    IOException,
    SomeException,
    bracket,
    displayException,
    try,
 )
import Control.Monad (unless, when)
import Data.Char (isAlphaNum, isSpace, toLower)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (dropWhileEnd, isPrefixOf, isSuffixOf, stripPrefix)
import qualified Data.Text as Text
import HostBootstrap.Ensure (runTool)
import HostBootstrap.Ensure.Incus (
    IncusProviderStatus (IncusProviderReady),
    probeIncusProviderStatus,
 )
import HostBootstrap.HostConfig (HostConfig, buildHostConfig, resolveMaybe)
import HostBootstrap.HostTool (
    HostTool (Docker, Incus, Python3),
    absExePath,
 )
import HostBootstrap.Incus (IncusVM (IncusVM))
import HostBootstrap.Lima (LimaVM (LimaVM))
import HostBootstrap.Readiness (microsValue)
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
    ProviderBackendExec (..),
    ProviderBackendRequestView (ProviderBackendProcess),
    RawProviderOutcome (RawProviderExit, RawProviderFailure),
    discoverStrongProviderBackend,
    mkDirectHostBackendSpec,
    mkIncusBackendSpec,
    providerBackendRequestView,
 )
import HostBootstrap.Substrate.Provider.Reconcile (mkProviderShareSpec)
import HostBootstrap.Wsl2 (Wsl2VM (Wsl2VM))
import ProviderLiveAliasFixture (runLiveDirectRoute, runLiveIncusRoute)
import System.Directory (
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesPathExist,
    listDirectory,
    removePathForcibly,
 )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeFileName, (</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Temp (createTempDirectory)
import qualified System.Info as Info
import System.Posix.Files (fileAccess)
import System.Posix.IO (
    OpenFileFlags (cloexec, creat, exclusive),
    OpenMode (ReadOnly, ReadWrite),
    closeFd,
    defaultFileFlags,
    fdWrite,
    openFd,
 )
import System.Posix.Unistd (fileSynchronise)
import System.Process (readProcessWithExitCode)

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
            (mkIncusBackendSpec vmName incusImage config stateRoot 2 "2GiB" "12GiB")
    incusRequests <- newIORef []
    admittedIncus <-
        discoverStrongProviderBackend
            (realProviderExec incusRequests)
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
    assertProviderMetadataAbsent stateRoot vmName

    putStrLn "provider-live: exercise Direct prepared admission and sealed refusal boundary"
    directSpec <-
        expectReconcile
            "validate Direct backend"
            (mkDirectHostBackendSpec config shareRoot directEgressImage)
    directRequests <- newIORef []
    admittedDirect <-
        discoverStrongProviderBackend
            (realProviderExec directRequests)
            directSpec
            (\backend -> runLiveDirectRoute directPlanRoot config backend directProvider shareSpec)
    expectReconcile "run prepared Direct route" (admittedDirect >>= id)
    assertDirectReadOnlyRequests config shareRoot directRequests
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
    kvmReadWrite <- if kvmPresent then fileAccess "/dev/kvm" True True False else pure False
    unless (kvmPresent && kvmReadWrite) $
        failGate "/dev/kvm is absent or is not readable and writable by the invoking user"

realProviderExec :: IORef [ProviderBackendRequestView] -> ProviderBackendExec
realProviderExec requests =
    ProviderBackendExec
        { runProviderBackendExec = \request -> do
            let view@(ProviderBackendProcess executable argv) = providerBackendRequestView request
            modifyIORef' requests (<> [view])
            outcome <- try @IOException (readProcessWithExitCode executable argv "")
            pure $ case outcome of
                Left failure -> RawProviderFailure (displayException failure)
                Right (code, out, err) -> RawProviderExit code out err
        , waitProviderBackendExec = threadDelay . microsValue
        }

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

assertDirectReadOnlyRequests :: HostConfig -> FilePath -> IORef [ProviderBackendRequestView] -> IO ()
assertDirectReadOnlyRequests config root requestsRef = do
    python <- maybe (failGate "Direct audit has no resolved Python3") (pure . absExePath) (resolveMaybe config Python3)
    docker <- maybe (failGate "Direct audit has no resolved Docker") (pure . absExePath) (resolveMaybe config Docker)
    requests <- readIORef requestsRef
    let pythonRequests =
            [ argv
            | ProviderBackendProcess executable argv <- requests
            , executable == python
            ]
        dockerRequests =
            [ argv
            | ProviderBackendProcess executable argv <- requests
            , executable == docker
            ]
        validPython argv = case argv of
            ["-c", program, observedRoot] ->
                observedRoot == root
                    && "os.lstat(root)" `isInfix` program
                    && "os.path.realpath(root)==root" `isInfix` program
            _ -> False
        validDocker argv = argv == ["manifest", "inspect", directEgressImage]
    unless
        ( length requests == 4
            && length pythonRequests == 2
            && all validPython pythonRequests
            && length dockerRequests == 2
            && all validDocker dockerRequests
        )
        $ failGate ("Direct backend executed an unexpected or mutating request: " ++ show requests)

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

assertProviderMetadataAbsent :: FilePath -> String -> IO ()
assertProviderMetadataAbsent stateRoot vmName = do
    entries <- listDirectory stateRoot
    let originPrefix = vmName ++ ".provider.origin.json"
        residue = filter (originPrefix `isPrefixOf`) entries
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

writeDurableIntent :: FilePath -> String -> IO ()
writeDurableIntent root payload = do
    let path = root </> ".hostbootstrap-provider-live-intent-v2"
    bracket
        ( openFd
            path
            ReadWrite
            defaultFileFlags
                { creat = Just 0o600
                , exclusive = True
                , cloexec = True
                }
        )
        closeFd
        (\descriptor -> writeWhole descriptor payload >> fileSynchronise descriptor)
    bracket
        (openFd root ReadOnly defaultFileFlags{cloexec = True})
        closeFd
        fileSynchronise
  where
    writeWhole _ "" = pure ()
    writeWhole descriptor remaining = do
        written <- fdWrite descriptor remaining
        unless (written > 0) (failGate "short durable intent write")
        writeWhole descriptor (drop (fromIntegral written) remaining)

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
