{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module HostBootstrap.Ensure.Colima.Backend.Runner
  ( BackendNamespace (..),
    validNamespace,
    BoundedToolResult (..),
    runBoundedTool,
    runShippedCommand,
    shippedCommandEntryArguments,
    runShippedCommandEntry,
  )
where

#if !defined(mingw32_HOST_OS)
import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
#endif
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Bits (shiftL, (.|.))
import Data.Word (Word32)
import HostBootstrap.Effect.Run
  ( BoundedRun (..),
    CapturedRun (capturedExit, capturedStderr, capturedStdout),
    RunBounds (..),
    RunNamespace (..),
    runBoundedGroupedWithInput,
  )
import System.Environment (getExecutablePath)
import System.Exit (ExitCode, exitWith)
import System.FilePath (isAbsolute, splitSearchPath)
import System.IO (stdin)
import System.Process (StdStream (Inherit, NoStream), getProcessExitCode, proc, std_err, std_in, std_out, withCreateProcess)
#if !defined(mingw32_HOST_OS)
import System.Posix.Process (getParentProcessID, getProcessGroupIDOf, getProcessID)
import System.Posix.Signals (sigKILL, signalProcessGroup)
import System.Posix.IO (FdOption (NonBlockingRead), setFdOption, stdInput)
import qualified System.Posix.IO.ByteString as PosixByteString
#endif

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

data BoundedToolResult
  = BoundedToolCompleted ExitCode String String
  | BoundedToolTimedOut
  | BoundedToolFailed String
  deriving (Eq, Show)

runBoundedTool :: Int -> BackendNamespace -> FilePath -> [String] -> IO BoundedToolResult
runBoundedTool timeoutSeconds namespace executable args
  | timeoutSeconds <= 0 || timeoutSeconds > 900 = pure (BoundedToolFailed "invalid-timeout")
  | not (validNamespace namespace) = pure (BoundedToolFailed "invalid-namespace")
  | not (isAbsolute executable) = pure (BoundedToolFailed "non-absolute-executable")
  | otherwise = runShippedCommand timeoutSeconds namespace executable args

-- | Run a command through this installed binary's parent-death transaction.
-- The supervisor is a shipped Haskell entry, not interpreter text: its stdin
-- remains open exactly while the owning launcher lives, and EOF kills the
-- complete transaction process group in the kernel.
runShippedCommand :: Int -> BackendNamespace -> FilePath -> [String] -> IO BoundedToolResult
runShippedCommand timeoutSeconds namespace executable args
  | timeoutSeconds <= 0 || timeoutSeconds > 900 = pure (BoundedToolFailed "invalid-timeout")
  | not (validNamespace namespace) = pure (BoundedToolFailed "invalid-namespace")
  | not (isAbsolute executable) = pure (BoundedToolFailed "non-absolute-executable")
  | otherwise = do
      self <- getExecutablePath
      outcome <-
        runBoundedGroupedWithInput
          (colimaBounds (timeoutSeconds * 1000 * 1000))
          (colimaNamespace namespace)
          self
          shippedCommandEntryArguments
          (encodeCommand executable args)
      pure $ case outcome of
        BoundedFailed err -> BoundedToolFailed err
        BoundedTimedOut -> BoundedToolTimedOut
        BoundedOutputLimit -> BoundedToolFailed "output-limit"
        BoundedCompleted run ->
          BoundedToolCompleted (capturedExit run) (capturedStdout run) (capturedStderr run)

shippedCommandEntryArguments :: [String]
shippedCommandEntryArguments = ["__hostbootstrap-colima-command-transaction-v1"]

runShippedCommandEntry :: IO ()
#if defined(mingw32_HOST_OS)
runShippedCommandEntry = ioError (userError "the Colima command transaction is unavailable on Windows")
#else
runShippedCommandEntry = do
  request <- readCommand
  case request of
    Left refusal -> ioError (userError refusal)
    Right (executable, arguments) -> do
      owner <- getParentProcessID
      setFdOption stdInput NonBlockingRead True
      withCreateProcess
        (proc executable arguments) {std_in = NoStream, std_out = Inherit, std_err = Inherit}
        (\_ _ _ child -> awaitChild owner child >>= exitWith)
  where
    awaitChild owner child = do
      probeParent owner
      observed <- getProcessExitCode child
      case observed of
        Just code -> pure code
        Nothing -> threadDelay 10000 >> awaitChild owner child

    probeParent owner = do
      currentOwner <- getParentProcessID
      observed <- try (PosixByteString.fdRead stdInput 1) :: IO (Either IOException ByteString.ByteString)
      if currentOwner /= owner || either (const False) ByteString.null observed
        then do
            process <- getProcessID
            getProcessGroupIDOf process >>= signalProcessGroup sigKILL
        else pure ()
#endif

encodeCommand :: FilePath -> [String] -> ByteString.ByteString
encodeCommand executable arguments =
  LazyByteString.toStrict . Builder.toLazyByteString $
    Builder.byteString commandMagic
      <> Builder.word32BE (fromIntegral (length fields))
      <> foldMap sized fields
  where
    fields = map bytes (executable : arguments)
    bytes = ByteString.pack . map (fromIntegral . fromEnum)
    sized value = Builder.word32BE (fromIntegral (ByteString.length value)) <> Builder.byteString value

readCommand :: IO (Either String (FilePath, [String]))
readCommand = do
  magic <- ByteString.hGet stdin (ByteString.length commandMagic)
  countBytes <- ByteString.hGet stdin 4
  if magic /= commandMagic || ByteString.length countBytes /= 4
    then pure (Left "invalid shipped command header")
    else do
      fields <- readFields (word32 countBytes) []
      pure $ case fields of
        Left refusal -> Left refusal
        Right [] -> Left "shipped command has no executable"
        Right (executable : arguments)
          | isAbsolute executable -> Right (executable, arguments)
          | otherwise -> Left "shipped command executable is not absolute"
  where
    readFields 0 values = pure (Right (reverse values))
    readFields remaining values = do
      sizeBytes <- ByteString.hGet stdin 4
      if ByteString.length sizeBytes /= 4
        then pure (Left "truncated shipped command field")
        else do
          value <- ByteString.hGet stdin (fromIntegral (word32 sizeBytes))
          if ByteString.length value /= fromIntegral (word32 sizeBytes) || ByteString.elem 0 value
            then pure (Left "invalid shipped command field")
            else readFields (remaining - 1) (map (toEnum . fromIntegral) (ByteString.unpack value) : values)

word32 :: ByteString.ByteString -> Word32
word32 value =
  foldl (\total byte -> shiftL total 8 .|. fromIntegral byte) 0 (ByteString.unpack value)

commandMagic :: ByteString.ByteString
commandMagic = "hb-colima-command-1"

-- | Colima's row of the bounded-run table: a five-times command budget with a
-- thirty second floor, a 16 MiB transcript ceiling, and six seconds of grace
-- before the group is killed. The numbers are Colima's; the runner is not.
colimaBounds :: Int -> RunBounds
colimaBounds wallMicros =
  RunBounds
    { boundWallMicros = wallMicros,
      boundOutputBytes = 16 * 1024 * 1024,
      boundTerminationGraceMicros = 6 * 1000 * 1000
    }

colimaNamespace :: BackendNamespace -> RunNamespace
colimaNamespace namespace =
  RunNamespace
    { runWorkingDirectory = namespaceWorkingDirectory namespace,
      runEnvironment = closedEnvironment namespace
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
