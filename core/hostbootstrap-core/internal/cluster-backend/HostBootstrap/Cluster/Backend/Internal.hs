{-# LANGUAGE CPP #-}

{- | Cabal-private execution and provenance boundary for the cluster backend.

The main library re-exports only the abstract 'StrongClusterBackend'.  Its
production constructor verifies the canonical root-owned Linux tool paths
resolved through the public library's typed @HostConfig@/@HostTool@ boundary
and installs a bounded, closed-environment process runner. The injected constructor exists
only so the package's test component can execute the same protocol against fake
tools; downstream packages cannot depend on this private component.
-}
module HostBootstrap.Cluster.Backend.Internal
  ( ClusterExec (..),
    ClusterCommandResult (..),
    StrongClusterBackend (..),
    discoverInjectedStrongClusterBackend,
    discoverResolvedStrongClusterBackend,
    runStrongClusterCommand,
    runClosedClusterCommandForTest,
  )
where

import Control.Concurrent (MVar, forkIO, newEmptyMVar, putMVar, threadDelay, tryReadMVar)
import Control.Exception
  ( SomeAsyncException,
    SomeException,
    evaluate,
    fromException,
    mask,
    onException,
    throwIO,
    try,
    uninterruptibleMask_,
  )
import Data.IORef (IORef, newIORef)
import Data.List (intercalate, nub)
import Data.Word (Word64)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (takeDirectory)
import System.IO (Handle, hClose, hGetChar, hIsEOF)
import System.Process
  ( CreateProcess (create_group, cwd, env, std_err, std_in, std_out),
    ProcessHandle,
    Pid,
    StdStream (CreatePipe),
    createProcess,
    proc,
    getPid,
    waitForProcess,
  )

#if defined(mingw32_HOST_OS)
import System.Process (terminateProcess)
#endif

#if !defined(mingw32_HOST_OS)
import System.Posix.Signals (Signal, sigKILL, sigTERM, signalProcessGroup)
#endif

#if defined(linux_HOST_OS)
import System.Posix.Files
  ( FileStatus,
    fileMode,
    fileOwner,
    getSymbolicLinkStatus,
    groupWriteMode,
    intersectFileModes,
    isDirectory,
    isRegularFile,
    nullFileMode,
    otherWriteMode,
    ownerExecuteMode,
    unionFileModes,
  )
#endif

newtype ClusterExec = ClusterExec
  { runClusterCommand :: [String] -> IO ClusterCommandResult
  }

data ClusterCommandResult = ClusterCommandResult
  { clusterCommandOk :: Bool,
    clusterCommandStdout :: String,
    clusterCommandStderr :: String
  }
  deriving (Eq, Show)

data StrongClusterBackend =
  StrongClusterBackend
    ClusterExec
    FilePath
    FilePath
    FilePath
    FilePath
    FilePath
    FilePath
    (IORef Word64)

runStrongClusterCommand :: StrongClusterBackend -> [String] -> IO ClusterCommandResult
runStrongClusterCommand (StrongClusterBackend executor _ _ _ _ _ _ _) = runClusterCommand executor

{- | Test-only injected discovery.  Only this private component exports the raw
executor constructor, so a downstream consumer cannot turn chosen output into
a strong backend or an exact-indexed call result.
-}
discoverInjectedStrongClusterBackend ::
  ClusterExec ->
  FilePath ->
  FilePath ->
  FilePath ->
  IO (Either String StrongClusterBackend)
discoverInjectedStrongClusterBackend executor driver runtime kubectl
  | any (not . absolutePath) [driver, runtime, kubectl] = pure (Left "cluster tools must be absolute")
  | otherwise = do
      result <- runClusterCommand executor ["sh", "-c", ownershipToolProbe driver runtime kubectl]
      case resolvedOwnershipTools result of
        Nothing -> pure (Left "the injected frame did not prove the required ownership tools")
        Just (flock, python) -> Right <$> backend executor driver runtime kubectl flock python

{- | Closed production discovery for the Linux provider frame. Every path was
resolved through the typed host-tool configuration and enters this private
component, not a caller-supplied public constructor. Each file plus its
containing directory chain is root-owned and immutable to unprivileged users.
-}
discoverResolvedStrongClusterBackend :: FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> IO (Either String StrongClusterBackend)
#if defined(linux_HOST_OS)
discoverResolvedStrongClusterBackend driver runtime kubectl flock python
  | any (not . absolutePath) [driver, runtime, kubectl, flock, python] =
      pure (Left "resolved cluster tools must be absolute")
  | otherwise = do
      trusted <- traverse trustedStatus trustedDirectoriesAndTools
      case sequence trusted of
        Left reason -> pure (Left reason)
        Right statuses ->
          case validateTrusted statuses of
            Left reason -> pure (Left reason)
            Right () -> do
              let closedPath = closedToolPath driver runtime kubectl flock python
                  production = runClosedClusterCommandWithPath 225 closedPath
                  executor = ClusterExec production
              driverProbe <- production [driver, "version"]
              runtimeProbe <- production [runtime, "version", "--format", "{{.Client.Version}}"]
              kubectlProbe <- production [kubectl, "version", "--client=true", "--output=json"]
              flockProbe <- production [flock, "--version"]
              pythonProbe <- production [python, "-c", "import hashlib,json,os,secrets,signal,stat,subprocess,sys"]
              if clusterCommandOk driverProbe
                && "kind v" `contains` clusterCommandStdout driverProbe
                && clusterCommandOk runtimeProbe
                && not (null (clusterCommandStdout runtimeProbe))
                && clusterCommandOk kubectlProbe
                && "clientVersion" `contains` clusterCommandStdout kubectlProbe
                && clusterCommandOk flockProbe
                && "util-linux" `contains` clusterCommandStdout flockProbe
                && clusterCommandOk pythonProbe
                then Right <$> backend executor driver runtime kubectl flock python
                else pure (Left "the resolved Linux cluster ownership tools failed their closed discovery probes")
  where
    trustedDirectoriesAndTools =
      map (\path -> ("directory", path)) (nub (concatMap directoryChain [driver, runtime, kubectl, flock, python]))
        ++ map (\path -> ("executable", path)) [driver, runtime, kubectl, flock, python]
    validateTrusted entries = mapM_ validate entries
    validate ((kind, path), value)
      | fileOwner value /= 0 = Left ("cluster ownership tool path is not root-owned: " ++ path)
      | mutableByUnprivileged value = Left ("cluster ownership tool path is group/world writable: " ++ path)
      | kind == "directory" && isDirectory value = Right ()
      | kind == "executable" && isRegularFile value && executableByOwner value = Right ()
      | otherwise = Left ("cluster ownership tool path has the wrong filesystem kind: " ++ path)
#else
discoverResolvedStrongClusterBackend _ _ _ _ _ =
  let closedLinuxImplementation = (runClosedClusterCommandWithPath, contains)
   in closedLinuxImplementation `seq` pure (Left "the exact cluster ownership backend is available only inside the Linux provider frame")
#endif

backend :: ClusterExec -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> IO StrongClusterBackend
backend executor driver runtime kubectl flock python = do
  readinessVersion <- newIORef 0
  let closedPath = closedToolPath driver runtime kubectl flock python
  pure (StrongClusterBackend executor driver runtime kubectl flock python closedPath readinessVersion)

closedToolPath :: FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath
closedToolPath driver runtime kubectl flock python =
  intercalate
    ":"
    (nub (map takeDirectory [driver, runtime, kubectl, flock, python]))

#if defined(linux_HOST_OS)
directoryChain :: FilePath -> [FilePath]
directoryChain path = reverse (go (takeDirectory path))
  where
    go "/" = ["/"]
    go current = current : go (takeDirectory current)

trustedStatus :: (String, FilePath) -> IO (Either String ((String, FilePath), FileStatus))
trustedStatus entry@(_kind, path) = do
  observed <- trySynchronous (getSymbolicLinkStatus path)
  pure $ case observed of
    Left _ -> Left ("cluster ownership tool path is unavailable: " ++ path)
    Right value -> Right (entry, value)

mutableByUnprivileged :: FileStatus -> Bool
mutableByUnprivileged value =
  intersectFileModes
    (fileMode value)
    (unionFileModes groupWriteMode otherWriteMode)
    /= nullFileMode

executableByOwner :: FileStatus -> Bool
executableByOwner value =
  intersectFileModes (fileMode value) ownerExecuteMode /= nullFileMode
#endif

runClosedClusterCommandForTest :: Int -> [String] -> IO ClusterCommandResult
runClosedClusterCommandForTest seconds arguments =
  case arguments of
    [] -> pure (ClusterCommandResult False "" "empty cluster command")
    executable : _ -> runClosedClusterCommandWithPath (max 1 seconds) (takeDirectory executable) arguments

runClosedClusterCommandWithPath :: Int -> FilePath -> [String] -> IO ClusterCommandResult
runClosedClusterCommandWithPath _ _ [] = pure (ClusterCommandResult False "" "empty cluster command")
runClosedClusterCommandWithPath seconds toolPath (executable : arguments) = do
  attempted <-
    trySynchronous (runGroupedProcess seconds toolPath executable arguments)
  case attempted of
    Left failure -> pure (ClusterCommandResult False "" (show failure))
    Right Nothing -> pure (ClusterCommandResult False "" "cluster command exceeded the outer 240 second watchdog")
    Right (Just (exitCode, out, err)) -> pure (ClusterCommandResult (exitCode == ExitSuccess) out err)

runGroupedProcess :: Int -> FilePath -> FilePath -> [String] -> IO (Maybe (ExitCode, String, String))
runGroupedProcess seconds toolPath executable arguments =
  mask $ \restore -> do
    (input, output, errors, process) <- createProcess processSpec
    processId <- getPid process
    case (input, output, errors) of
      (Just inputHandle, Just outputHandle, Just errorHandle) -> do
        outputResult <- newEmptyMVar
        errorResult <- newEmptyMVar
        let cleanup = do
              terminateProcessGroup processId process
              closeQuietly inputHandle
              closeQuietly outputHandle
              closeQuietly errorHandle
              _ <- collectReadersFor 100 outputResult errorResult
              pure ()
            run = do
              hClose inputHandle
              _ <- forkIO (readPipe outputHandle >>= putMVar outputResult)
              _ <- forkIO (readPipe errorHandle >>= putMVar errorResult)
              collected <- collectReadersFor (max 1 seconds * 100) outputResult errorResult
              case collected of
                Nothing -> uninterruptibleMask_ cleanup >> pure Nothing
                Just (outcome, errorsOutcome) -> do
                  completed <- waitForProcessBounded 2 process
                  case completed of
                    Just (Right exitCode) -> do
                      closeQuietly outputHandle
                      closeQuietly errorHandle
                      out <- either throwIO pure outcome
                      err <- either throwIO pure errorsOutcome
                      pure (Just (exitCode, out, err))
                    Just (Left failure) -> throwIO failure
                    Nothing -> uninterruptibleMask_ cleanup >> pure Nothing
        restore run `onException` uninterruptibleMask_ cleanup
      _ -> do
        terminateProcessGroup processId process
        mapM_ closeQuietly [handle | Just handle <- [input, output, errors]]
        fail "the cluster backend did not create all requested pipes"
  where
    processCommand =
#if defined(darwin_HOST_OS)
      -- process-1.6.26 cannot combine @create_group@, an explicit environment,
      -- and @cwd@ on macOS.  Keep the same closed root working directory via
      -- an absolute shell that immediately execs the requested leader; the
      -- exec preserves the newly-created process-group identity.
      proc "/bin/sh" (["-c", "cd / && exec \"$@\"", "hostbootstrap-cluster-runner", executable] ++ arguments)
    processWorkingDirectory = Nothing
#else
      proc executable arguments
    processWorkingDirectory = Just "/"
#endif
    processSpec =
      processCommand
        { create_group = True,
          cwd = processWorkingDirectory,
          env = Just (closedEnvironment toolPath),
          std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe
        }

closedEnvironment :: FilePath -> [(String, String)]
closedEnvironment toolPath =
  [ ("PATH", toolPath),
    ("HOME", "/nonexistent"),
    ("XDG_CONFIG_HOME", "/nonexistent"),
    ("TMPDIR", "/tmp"),
    ("LANG", "C"),
    ("LC_ALL", "C"),
    ("DOCKER_HOST", "unix:///var/run/docker.sock"),
    ("DOCKER_CONTEXT", "default"),
    ("KIND_EXPERIMENTAL_PROVIDER", "docker")
  ]

readPipe :: Handle -> IO (Either SomeException String)
readPipe handle = trySynchronous (drainBounded 0 [])
  where
    outputLimit :: Int
    outputLimit = 1024 * 1024
    drainBounded :: Int -> String -> IO String
    drainBounded retained reversed = do
      done <- hIsEOF handle
      if done
        then do
          let contents = reverse reversed
          _ <- evaluate (length contents)
          pure contents
        else do
          character <- hGetChar handle
          if retained < outputLimit
            then drainBounded (retained + 1) (character : reversed)
            else drainBounded retained reversed

collectReadersFor ::
  Int ->
  MVar (Either SomeException String) ->
  MVar (Either SomeException String) ->
  IO (Maybe (Either SomeException String, Either SomeException String))
collectReadersFor attempts outputResult errorResult = go attempts Nothing Nothing
  where
    go remaining outputValue errorValue = do
      nextOutput <- maybe (tryReadMVar outputResult) (pure . Just) outputValue
      nextError <- maybe (tryReadMVar errorResult) (pure . Just) errorValue
      case (nextOutput, nextError) of
        (Just out, Just err) -> pure (Just (out, err))
        _
          | remaining <= 0 -> pure Nothing
          | otherwise -> threadDelay 10000 >> go (remaining - 1) nextOutput nextError

closeQuietly :: Handle -> IO ()
closeQuietly handle = do
  _ <- trySynchronous (hClose handle)
  pure ()

terminateProcessGroup :: Maybe Pid -> ProcessHandle -> IO ()
#if defined(mingw32_HOST_OS)
terminateProcessGroup _processId process = do
  _ <- trySynchronous (terminateProcess process)
  _ <- waitForProcessBounded 2 process
  pure ()
#else
terminateProcessGroup processId process = do
  signalTermGroup processId process
  threadDelay (2 * 1000 * 1000)
  signalKillGroup processId process
  _ <- waitForProcessBounded 2 process
  pure ()
#endif

waitForProcessBounded :: Int -> ProcessHandle -> IO (Maybe (Either SomeException ExitCode))
waitForProcessBounded seconds process = do
  exitResult <- newEmptyMVar
  _ <- forkIO (trySynchronous (waitForProcess process) >>= putMVar exitResult)
  waitForResultBounded seconds exitResult

waitForResultBounded :: Int -> MVar value -> IO (Maybe value)
waitForResultBounded seconds result = go (max 1 seconds * 100)
  where
    go remaining = do
      observed <- tryReadMVar result
      case observed of
        Just outcome -> pure (Just outcome)
        Nothing
          | remaining <= 0 -> pure Nothing
          | otherwise -> threadDelay 10000 >> go (remaining - 1)

signalTermGroup :: Maybe Pid -> ProcessHandle -> IO ()
#if !defined(mingw32_HOST_OS)
signalTermGroup processId _process = signalGroup sigTERM processId
#else
signalTermGroup _ process = do
  _ <- trySynchronous (terminateProcess process)
  pure ()
#endif

signalKillGroup :: Maybe Pid -> ProcessHandle -> IO ()
#if !defined(mingw32_HOST_OS)
signalKillGroup processId _process = signalGroup sigKILL processId
#else
signalKillGroup _ process = do
  _ <- trySynchronous (terminateProcess process)
  pure ()
#endif

#if !defined(mingw32_HOST_OS)
signalGroup :: Signal -> Maybe Pid -> IO ()
signalGroup signal processId = do
  case processId of
    Nothing -> pure ()
    Just value -> do
      _ <- trySynchronous (signalProcessGroup signal value)
      pure ()
#endif

trySynchronous :: IO value -> IO (Either SomeException value)
trySynchronous action = do
  result <- try action
  case result of
    Left failure
      | Just _ <- (fromException failure :: Maybe SomeAsyncException) -> throwIO failure
    _ -> pure result

absolutePath :: FilePath -> Bool
absolutePath ('/' : _) = True
absolutePath _ = False

resolvedOwnershipTools :: ClusterCommandResult -> Maybe (FilePath, FilePath)
resolvedOwnershipTools result
  | not (clusterCommandOk result) = Nothing
  | otherwise = case lines (clusterCommandStdout result) of
      ["HB_CLUSTER_TOOLS_V1", flock, python]
        | absolutePath flock && absolutePath python -> Just (flock, python)
      _ -> Nothing

ownershipToolProbe :: FilePath -> FilePath -> FilePath -> String
ownershipToolProbe driver runtime kubectl =
  unlines
    [ "set -eu",
      "flock_path=$(command -v flock) || exit 1",
      "python_path=$(command -v python3) || exit 1",
      "case \"$flock_path\" in /*) ;; *) exit 1;; esac",
      "case \"$python_path\" in /*) ;; *) exit 1;; esac",
      "test -x \"$flock_path\" || exit 1",
      "test -x \"$python_path\" || exit 1",
      "flock_version=$(\"$flock_path\" --version 2>/dev/null) || exit 1",
      "case \"$flock_version\" in *util-linux*) ;; *) exit 1;; esac",
      "\"$python_path\" -c 'import hashlib,json,os,secrets,stat,subprocess,sys' >/dev/null 2>&1 || exit 1",
      "test -x " ++ quoteShell driver ++ " || exit 1",
      "test -x " ++ quoteShell runtime ++ " || exit 1",
      "test -x " ++ quoteShell kubectl ++ " || exit 1",
      "printf 'HB_CLUSTER_TOOLS_V1\\n%s\\n%s\\n' \"$flock_path\" \"$python_path\""
    ]

quoteShell :: String -> String
quoteShell value = "'" ++ concatMap escape value ++ "'"
  where
    escape '\'' = "'\\''"
    escape character = [character]

contains :: String -> String -> Bool
contains needle haystack = any (needle `prefixOf`) (tails haystack)
  where
    tails [] = [[]]
    tails value@(_ : rest) = value : tails rest
    prefixOf [] _ = True
    prefixOf _ [] = False
    prefixOf (left : leftRest) (right : rightRest) = left == right && prefixOf leftRest rightRest
