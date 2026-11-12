{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}

module HostBootstrap.Ensure.Colima.Backend.Runner (
    BackendNamespace (..),
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
import Control.Exception (IOException, mask, onException, try)
import Control.Monad (unless)
import GHC.Clock (getMonotonicTimeNSec)
#endif
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
#if !defined(mingw32_HOST_OS)
import Data.Bits (shiftL, (.|.))
import Data.Word (Word32)
#endif
import HostBootstrap.Effect.Run (
    BoundedRun (..),
    CapturedRun (capturedExit, capturedStderr, capturedStdout),
    RunBounds (..),
    RunNamespace (..),
    runBoundedGroupedWithInput,
 )
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, splitSearchPath)
#if !defined(mingw32_HOST_OS)
import System.Exit (exitWith)
import System.IO (stdin)
import System.IO.Error (isDoesNotExistError)
import Foreign.C.Error (eBADF, eINTR, getErrno)
import Foreign.C.Types (CInt (..))
import System.Posix.Process (ProcessStatus (..), exitImmediately, forkProcess, getParentProcessID, getProcessGroupIDOf, getProcessID, getProcessStatus, joinProcessGroup)
import qualified System.Posix.Process.ByteString as PosixProcess
import System.Posix.Unistd (SysVar (OpenFileLimit), getSysVar)
import System.Posix.Signals (nullSignal, sigKILL, signalProcess, signalProcessGroup)
import System.Posix.IO (FdOption (NonBlockingRead), OpenMode (ReadOnly), closeFd, defaultFileFlags, dupTo, openFd, setFdOption, stdInput)
import qualified System.Posix.IO.ByteString as PosixByteString

-- F_SETFD and FD_CLOEXEC are 2 and 1 on both supported POSIX hosts.
foreign import ccall unsafe "fcntl" markDescriptor :: CInt -> CInt -> CInt -> IO CInt
#endif

data BackendNamespace = BackendNamespace
    { namespaceHomeDirectory :: FilePath
    , namespaceColimaHome :: FilePath
    , namespaceLimaHome :: FilePath
    , namespaceColimaCacheHome :: FilePath
    , namespaceTemporaryDirectory :: FilePath
    , namespaceDockerConfig :: FilePath
    , namespaceWorkingDirectory :: FilePath
    , namespaceExecutablePath :: String
    }
    deriving (Eq, Show)

validNamespace :: BackendNamespace -> Bool
validNamespace namespace =
    all
        validAbsolute
        [ namespaceHomeDirectory namespace
        , namespaceColimaHome namespace
        , namespaceLimaHome namespace
        , namespaceColimaCacheHome namespace
        , namespaceTemporaryDirectory namespace
        , namespaceDockerConfig namespace
        , namespaceWorkingDirectory namespace
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

{- | Run a command through this installed binary's parent-death transaction.
The supervisor is a shipped Haskell entry, not interpreter text: its stdin
remains open exactly while the owning launcher lives, and EOF kills the
complete transaction process group in the kernel.
-}
runShippedCommand :: Int -> BackendNamespace -> FilePath -> [String] -> IO BoundedToolResult
runShippedCommand timeoutSeconds namespace executable args
    | timeoutSeconds <= 0 || timeoutSeconds > 900 = pure (BoundedToolFailed "invalid-timeout")
    | not (validNamespace namespace) = pure (BoundedToolFailed "invalid-namespace")
    | not (isAbsolute executable) = pure (BoundedToolFailed "non-absolute-executable")
    | otherwise = case encodeCommand executable args of
        Left refusal -> pure (BoundedToolFailed refusal)
        Right wire -> do
            self <- getExecutablePath
            outcome <-
                runBoundedGroupedWithInput
                    (colimaBounds (timeoutSeconds * 1000 * 1000))
                    (colimaNamespace namespace)
                    self
                    shippedCommandEntryArguments
                    wire
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
      process <- getProcessID
      group <- getProcessGroupIDOf process
      unless (group == process) (ioError (userError "the Colima transaction requires its own process group"))
      ownerGroup <- getProcessGroupIDOf owner
      setFdOption stdInput NonBlockingRead True
      descriptorLimit <- getSysVar OpenFileLimit
      unless (descriptorLimit > 3 && descriptorLimit <= fromIntegral (maxBound :: CInt))
        (ioError (userError "the Colima transaction cannot bound inherited descriptors"))
      code <- mask $ \restore -> do
        child <- forkProcess $ do
          _ <- try (launchRaw (fromIntegral descriptorLimit) executable arguments) :: IO (Either IOException ())
          exitImmediately (ExitFailure 127)
        -- The child keeps the original group while the supervisor reserves its
        -- identifier from the owning parent's group.
        (joinProcessGroup ownerGroup >> restore (awaitChild owner process group child))
          `onException` stopTransaction process group
      exitWith code
  where
    awaitChild owner process group child = do
      probeParent owner process group
      observed <- getProcessStatus False False child
      case observed of
        Just status -> do
          let code = case status of
                Exited result -> result
                Terminated signal _ -> ExitFailure (128 + fromIntegral signal)
                Stopped signal -> ExitFailure (128 + fromIntegral signal)
          killRetainedGroup group
          started <- getMonotonicTimeNSec
          awaitEmpty owner process group (started + 2 * 1000 * 1000 * 1000)
          pure code
        Nothing -> threadDelay 10000 >> awaitChild owner process group child

    awaitEmpty owner process group deadline = do
      probeParent owner process group
      observed <- try (signalProcessGroup nullSignal group) :: IO (Either IOException ())
      case observed of
        Left failure | isDoesNotExistError failure -> pure ()
        _ -> do
          now <- getMonotonicTimeNSec
          if now >= deadline
            then ioError (userError "the Colima transaction process group did not quiesce")
            else threadDelay 10000 >> awaitEmpty owner process group deadline

    probeParent owner process group = do
      currentOwner <- getParentProcessID
      observed <- try (PosixByteString.fdRead stdInput 1) :: IO (Either IOException ByteString.ByteString)
      if currentOwner /= owner || either (const False) ByteString.null observed
        then stopTransaction process group
        else pure ()

    stopTransaction process group = do
      killRetainedGroup group
      signalProcess sigKILL process

    killRetainedGroup group = do
      _ <- try (signalProcessGroup sigKILL group) :: IO (Either IOException ())
      pure ()

    launchRaw descriptorLimit executable arguments = do
      nullInput <- openFd "/dev/null" ReadOnly defaultFileFlags
      _ <- dupTo nullInput stdInput
      closeFd nullInput
      markRemaining 3 descriptorLimit
      PosixProcess.executeFile executable False arguments Nothing

    -- The launcher uses close_fds, so every descriptor opened by this
    -- supervisor lies below its current open-file limit.
    markRemaining descriptor limit
      | descriptor >= limit = pure ()
      | otherwise = do
          result <- markDescriptor descriptor 2 1
          if result >= 0
            then markRemaining (descriptor + 1) limit
            else do
              failure <- getErrno
              if failure == eBADF
                then markRemaining (descriptor + 1) limit
                else if failure == eINTR
                  then markRemaining descriptor limit
                  else ioError (userError "the Colima transaction could not protect a descriptor")
#endif

encodeCommand :: FilePath -> [String] -> Either String ByteString.ByteString
encodeCommand executable arguments
    | any (any invalidCharacter) (executable : arguments) = Left "invalid-command-encoding"
    | length fields > 65536 || any ((> 16777216) . ByteString.length) fields = Left "command-frame-too-large"
    | otherwise = Right . LazyByteString.toStrict . Builder.toLazyByteString $
        Builder.byteString commandMagic
            <> Builder.word32BE (fromIntegral (length fields))
            <> foldMap sized fields
  where
    fields = map (TextEncoding.encodeUtf8 . Text.pack) (executable : arguments)
    invalidCharacter character = character == '\0' || (character >= '\xD800' && character <= '\xDFFF')
    sized value = Builder.word32BE (fromIntegral (ByteString.length value)) <> Builder.byteString value

#if !defined(mingw32_HOST_OS)
readCommand :: IO (Either String (ByteString.ByteString, [ByteString.ByteString]))
readCommand = do
  magic <- ByteString.hGet stdin (ByteString.length commandMagic)
  countBytes <- ByteString.hGet stdin 4
  if magic /= commandMagic || ByteString.length countBytes /= 4 || word32 countBytes > 65536
    then pure (Left "invalid shipped command header")
    else do
      fields <- readFields (word32 countBytes) []
      pure $ case fields of
        Left refusal -> Left refusal
        Right [] -> Left "shipped command has no executable"
        Right (executable : arguments)
          | ByteString.isPrefixOf "/" executable -> Right (executable, arguments)
          | otherwise -> Left "shipped command executable is not absolute"
  where
    readFields 0 values = pure (Right (reverse values))
    readFields remaining values = do
      sizeBytes <- ByteString.hGet stdin 4
      if ByteString.length sizeBytes /= 4
        then pure (Left "truncated shipped command field")
        else if word32 sizeBytes > 16777216
          then pure (Left "shipped command field is too large")
          else do
            value <- ByteString.hGet stdin (fromIntegral (word32 sizeBytes))
            if ByteString.length value /= fromIntegral (word32 sizeBytes) || ByteString.elem 0 value
              then pure (Left "invalid shipped command field")
              else readFields (remaining - 1) (value : values)

word32 :: ByteString.ByteString -> Word32
word32 value =
  foldl (\total byte -> shiftL total 8 .|. fromIntegral byte) 0 (ByteString.unpack value)

#endif

commandMagic :: ByteString.ByteString
commandMagic = "hb-colima-command-1"

{- | Colima's row of the bounded-run table uses the caller's timeout as given,
without a multiplier or minimum floor, a 16 MiB transcript ceiling, and six
seconds of grace before the group is killed. The numbers are Colima's; the
runner is not.
-}
colimaBounds :: Int -> RunBounds
colimaBounds wallMicros =
    RunBounds
        { boundWallMicros = wallMicros
        , boundOutputBytes = 16 * 1024 * 1024
        , boundTerminationGraceMicros = 6 * 1000 * 1000
        }

colimaNamespace :: BackendNamespace -> RunNamespace
colimaNamespace namespace =
    RunNamespace
        { runWorkingDirectory = namespaceWorkingDirectory namespace
        , runEnvironment = closedEnvironment namespace
        }

closedEnvironment :: BackendNamespace -> [(String, String)]
closedEnvironment namespace =
    [ ("HOME", namespaceHomeDirectory namespace)
    , ("COLIMA_HOME", namespaceColimaHome namespace)
    , ("LIMA_HOME", namespaceLimaHome namespace)
    , ("COLIMA_CACHE_HOME", namespaceColimaCacheHome namespace)
    , ("TMPDIR", namespaceTemporaryDirectory namespace)
    , ("DOCKER_CONFIG", namespaceDockerConfig namespace)
    , ("PATH", namespaceExecutablePath namespace)
    , ("LANG", "C")
    , ("LC_ALL", "C")
    ]
