{-# LANGUAGE CPP #-}

module HostBootstrap.Ensure.Colima.Backend.Runner
  ( BackendNamespace (..),
    validNamespace,
    BoundedProcessResult (..),
    runBoundedPython,
    BoundedToolResult (..),
    runBoundedTool,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Exception
  ( SomeAsyncException,
    SomeException,
    fromException,
    onException,
    throwIO,
    try,
  )
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import HostBootstrap.Ensure.Colima.Backend.Program.Supervisor (commandSupervisorProgram)
import System.Exit (ExitCode)
import System.FilePath (isAbsolute, splitSearchPath)
import System.IO (Handle, hClose)
#if !defined(mingw32_HOST_OS)
import System.Posix.Signals (Signal, sigKILL, sigTERM, signalProcessGroup)
import System.Posix.Types (CPid)
#endif
import System.Process
  ( CreateProcess (create_group, cwd, env, std_err, std_in, std_out),
    ProcessHandle,
    StdStream (CreatePipe),
    getPid,
    proc,
    terminateProcess,
    waitForProcess,
    withCreateProcess,
  )
import System.Timeout (timeout)

data BackendNamespace = BackendNamespace
  { namespaceHomeDirectory :: FilePath,
    namespaceColimaHome :: FilePath,
    namespaceLimaHome :: FilePath,
    namespaceColimaCacheHome :: FilePath,
    namespaceTemporaryDirectory :: FilePath,
    namespaceDockerConfig :: FilePath,
    namespaceWorkingDirectory :: FilePath,
    namespaceExecutablePath :: String
  }
  deriving (Eq, Show)

validNamespace :: BackendNamespace -> Bool
validNamespace namespace =
  all validAbsolute
    [ namespaceHomeDirectory namespace,
      namespaceColimaHome namespace,
      namespaceLimaHome namespace,
      namespaceColimaCacheHome namespace,
      namespaceTemporaryDirectory namespace,
      namespaceDockerConfig namespace,
      namespaceWorkingDirectory namespace
    ]
    && not (null executableDirectories)
    && all validAbsolute executableDirectories
  where
    executableDirectories = splitSearchPath (namespaceExecutablePath namespace)
    validAbsolute path = isAbsolute path && not (null path) && not (any (== '\0') path)

data BoundedProcessResult
  = BoundedProcessCompleted ExitCode String String
  | BoundedProcessTimedOut
  | BoundedProcessOutputLimit
  | BoundedProcessException String

data BoundedToolResult
  = BoundedToolCompleted ExitCode String String
  | BoundedToolTimedOut
  | BoundedToolFailed String
  deriving (Eq, Show)

runBoundedTool :: Int -> BackendNamespace -> FilePath -> FilePath -> [String] -> IO BoundedToolResult
runBoundedTool timeoutSeconds namespace supervisorPython executable args
  | timeoutSeconds <= 0 || timeoutSeconds > 900 = pure (BoundedToolFailed "invalid-timeout")
  | not (validNamespace namespace) = pure (BoundedToolFailed "invalid-namespace")
  | not (isAbsolute supervisorPython) || not (isAbsolute executable) = pure (BoundedToolFailed "non-absolute-executable")
  | otherwise = do
      attempted <-
        try
          ( runGroupedProcess
              (timeoutSeconds * 1000 * 1000)
              namespace
              supervisorPython
              (["-I", "-S", "-c", commandSupervisorProgram, executable] ++ args)
          ) ::
          IO (Either SomeException GroupedProcessResult)
      case attempted of
        Left err
          | Just asynchronous <- (fromException err :: Maybe SomeAsyncException) -> throwIO asynchronous
          | otherwise -> pure (BoundedToolFailed (show err))
        Right GroupedProcessTimedOut -> pure BoundedToolTimedOut
        Right GroupedProcessOutputLimit -> pure (BoundedToolFailed "output-limit")
        Right (GroupedProcessCompleted exitCode out errOut) -> pure (BoundedToolCompleted exitCode out errOut)

runBoundedPython :: Int -> BackendNamespace -> FilePath -> [String] -> IO BoundedProcessResult
runBoundedPython commandTimeoutSeconds namespace executable args = do
  attempted <-
    try
      (runGroupedProcess (backendTimeoutMicros commandTimeoutSeconds) namespace executable args) ::
      IO (Either SomeException GroupedProcessResult)
  case attempted of
    Left err
      | Just asynchronous <- (fromException err :: Maybe SomeAsyncException) -> throwIO asynchronous
      | otherwise -> pure (BoundedProcessException (show err))
    Right GroupedProcessTimedOut -> pure BoundedProcessTimedOut
    Right GroupedProcessOutputLimit -> pure BoundedProcessOutputLimit
    Right (GroupedProcessCompleted exitCode out errOut) -> pure (BoundedProcessCompleted exitCode out errOut)

data GroupedProcessResult
  = GroupedProcessCompleted ExitCode String String
  | GroupedProcessTimedOut
  | GroupedProcessOutputLimit

runGroupedProcess :: Int -> BackendNamespace -> FilePath -> [String] -> IO GroupedProcessResult
runGroupedProcess timeoutMicros namespace executable args =
  withCreateProcess processSpec $ \input output errors process -> do
    processGroup <- getPid process
    let runProcess =
          case (input, output, errors) of
            (Just inputHandle, Just outputHandle, Just errorHandle) -> do
              pipeResults <- newChan
              _ <- forkIO (readPipe outputHandle >>= writeChan pipeResults . PipeEvent StandardOutput)
              _ <- forkIO (readPipe errorHandle >>= writeChan pipeResults . PipeEvent StandardError)
              completed <-
                timeout timeoutMicros $ do
                  outputs <- awaitPipes pipeResults
                  case outputs of
                    PipesLimitExceeded -> pure GroupedProcessOutputLimit
                    PipesComplete completeOut completeErr -> do
                      exitCode <- waitForProcess process
                      pure (GroupedProcessCompleted exitCode completeOut completeErr)
              case completed of
                Nothing -> do
                  terminateProcessGroup processGroup process
                  closeQuietly inputHandle
                  closeQuietly outputHandle
                  closeQuietly errorHandle
                  pure GroupedProcessTimedOut
                Just GroupedProcessOutputLimit -> do
                  terminateProcessGroup processGroup process
                  closeQuietly inputHandle
                  closeQuietly outputHandle
                  closeQuietly errorHandle
                  pure GroupedProcessOutputLimit
                Just result@(GroupedProcessCompleted _ _ _) -> do
                  closeQuietly inputHandle
                  closeQuietly outputHandle
                  closeQuietly errorHandle
                  pure result
                Just GroupedProcessTimedOut -> pure GroupedProcessTimedOut
            _ -> fail "the grouped Colima backend did not create all requested pipes"
    runProcess `onException` terminateProcessGroup processGroup process
  where
    processSpec =
      (proc executable args)
        { std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True,
          cwd = Just (namespaceWorkingDirectory namespace),
          env = Just (closedEnvironment namespace)
        }

closedEnvironment :: BackendNamespace -> [(String, String)]
closedEnvironment namespace =
  [ ("HOME", namespaceHomeDirectory namespace),
    ("COLIMA_HOME", namespaceColimaHome namespace),
    ("LIMA_HOME", namespaceLimaHome namespace),
    ("COLIMA_CACHE_HOME", namespaceColimaCacheHome namespace),
    ("TMPDIR", namespaceTemporaryDirectory namespace),
    ("DOCKER_CONFIG", namespaceDockerConfig namespace),
    ("PATH", namespaceExecutablePath namespace),
    ("LANG", "C"),
    ("LC_ALL", "C")
  ]

data PipeResult
  = PipeComplete String
  | PipeLimitExceeded

data PipeSide = StandardOutput | StandardError

data PipeEvent = PipeEvent PipeSide (Either SomeException PipeResult)

data PipesResult
  = PipesComplete String String
  | PipesLimitExceeded

readPipe :: Handle -> IO (Either SomeException PipeResult)
readPipe handle = try (drain 0 [])
  where
    drain total chunks = do
      chunk <- BS.hGetSome handle pipeChunkBytes
      if BS.null chunk
        then pure (PipeComplete (BS8.unpack (BS.concat (reverse chunks))))
        else
          let nextTotal = total + BS.length chunk
           in if nextTotal > pipeLimitBytes
                then pure PipeLimitExceeded
                else drain nextTotal (chunk : chunks)

awaitPipes :: Chan PipeEvent -> IO PipesResult
awaitPipes results = do
  first <- readChan results >>= checked
  case first of
    (_, PipeLimitExceeded) -> pure PipesLimitExceeded
    (firstSide, PipeComplete firstValue) -> do
      second <- readChan results >>= checked
      pure $ case second of
        (_, PipeLimitExceeded) -> PipesLimitExceeded
        (secondSide, PipeComplete secondValue) ->
          case (firstSide, secondSide) of
            (StandardOutput, StandardError) -> PipesComplete firstValue secondValue
            (StandardError, StandardOutput) -> PipesComplete secondValue firstValue
            _ -> PipesLimitExceeded
  where
    checked (PipeEvent side value) = do
      result <- either throwIO pure value
      pure (side, result)

pipeChunkBytes :: Int
pipeChunkBytes = 32 * 1024

pipeLimitBytes :: Int
pipeLimitBytes = 16 * 1024 * 1024

closeQuietly :: Handle -> IO ()
closeQuietly handle = do
  result <- trySynchronous (hClose handle)
  either (const (pure ())) pure result

terminateProcessGroup :: Maybe ProcessGroupId -> ProcessHandle -> IO ()
terminateProcessGroup processGroup process = do
#if defined(mingw32_HOST_OS)
  _ <- trySynchronous (terminateProcess process)
  _ <- timeout (2 * 1000 * 1000) (waitForProcess process)
  pure ()
#else
  signalGroup sigTERM processGroup
  graceful <- timeout (6 * 1000 * 1000) (waitForProcess process)
  case graceful of
    Just _ -> pure ()
    Nothing -> do
      signalGroup sigKILL processGroup
      _ <- trySynchronous (terminateProcess process)
      _ <- timeout (2 * 1000 * 1000) (waitForProcess process)
      pure ()
#endif

#if defined(mingw32_HOST_OS)
type ProcessGroupId = Int
#else
type ProcessGroupId = CPid

signalGroup :: Signal -> Maybe ProcessGroupId -> IO ()
signalGroup _ Nothing = pure ()
signalGroup signal (Just processGroup) = do
  _ <- trySynchronous (signalProcessGroup signal processGroup)
  pure ()
#endif

trySynchronous :: IO value -> IO (Either SomeException value)
trySynchronous action = do
  attempted <- try action
  case attempted of
    Left err
      | Just asynchronous <- (fromException err :: Maybe SomeAsyncException) -> throwIO asynchronous
      | otherwise -> pure (Left err)
    Right value -> pure (Right value)

backendTimeoutMicros :: Int -> Int
backendTimeoutMicros commandTimeoutSeconds =
  (5 * commandTimeoutSeconds + 30) * 1000 * 1000
