{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The one process runner.

§ K fixes /which/ executable an invocation names, § HH the /shape/ it is
launched with, and § KK that a host-level command is a value rather than text.
This module is the last of those three: the single place in the package where a
child process is started to be captured.

Spawning looks like one line and is not. Every site that writes its own decides,
alone and invisibly, what happens to the child's three streams, which exception
class it catches, whether an asynchronous exception is swallowed along with the
@ENOENT@ it meant to handle, how long a hung child is waited for, and what a
failure to start is called. Written a dozen times those answers diverge, and the
divergence shows only on the host where one of them was wrong — which is why
§ KK admits one runner and a fix lands once.

Two dispositions are offered, because two are genuinely distinct rather than one
with a flag:

  * 'runCaptured' is the plain capture. Standard input is the supplied string
    and closes, and both output streams are read to end and returned whole. It
    is what every probe, reconciler, and lifted invocation wants, because each
    of them reads what the child said.

  * 'runBoundedGrouped' is the capture a driver needs when the child may hang,
    may talk forever, or may leave descendants behind: the child leads its own
    process group, receives a complete environment and working directory rather
    than inheriting the launcher's, is bounded by a wall clock and a per-stream
    output ceiling, and is torn down by group signal rather than by terminating
    one process. The difference from the plain capture is not stylistic — an
    ungrouped teardown leaves the grandchildren a VM driver spawns.

The two other lawful shapes are separately sealed and are not this module's:
"HostBootstrap.Detached" owns a child that outlives its launcher, and the
handoff process route owns a child holding an inherited descriptor pair.

Failure to /start/ is not failure to /succeed/. A child that runs and exits
non-zero returns 'Right' with that exit code, because its own diagnostic is in
the streams it wrote; only a child that never existed returns 'Left'. Callers
that collapse the two lose the distinction between "the tool refused" and "the
tool is not there", which are different problems with different fixes.

Every catch here is synchronous-only: an asynchronous exception delivered to the
launching thread propagates instead of being reported as a failure of the child.
-}
module HostBootstrap.Effect.Run
    ( -- * What a captured run produced
      CapturedRun (..)
    , capturedTriple

      -- * Why a child never existed
    , RunFailure (..)
    , renderRunFailure

      -- * The plain capture
    , runCaptured

      -- * The bounded, group-leading capture
    , RunNamespace (..)
    , RunBounds (..)
    , BoundedRun (..)
    , runBoundedGrouped
    , runBoundedGroupedWithInput
    , workingDirectoryEntryArguments
    , runWorkingDirectoryEntry
    )
where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Exception
    ( SomeAsyncException
    , SomeException
    , fromException
    , onException
    , throwIO
    , try
    )
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import GHC.Clock (getMonotonicTimeNSec)
import System.Exit (ExitCode (..), exitWith)
import System.IO (Handle, hClose, hFlush, hPutStrLn, hSetBinaryMode, stderr)
import System.IO.Error (isResourceVanishedError, tryIOError)
#if defined(darwin_HOST_OS)
import System.Environment (getExecutablePath)
#endif
#if !defined(mingw32_HOST_OS)
import System.Directory (setCurrentDirectory)
import System.Posix.Process (executeFile)
import System.Posix.Signals (Signal, nullSignal, sigKILL, sigTERM, signalProcessGroup)
#endif
import System.Process
    ( CreateProcess (close_fds, create_group, cwd, env, std_err, std_in, std_out)
    , Pid
    , ProcessHandle
    , StdStream (CreatePipe)
    , getPid
    , getProcessExitCode
    , proc
    , terminateProcess
    , withCreateProcess
    , waitForProcess
    )
#if defined(mingw32_HOST_OS)
import System.Process (use_process_jobs)
#endif
import System.Timeout (timeout)

-- ---------------------------------------------------------------------------
-- What a run produced
-- ---------------------------------------------------------------------------

{- | What a child that ran produced: its exit status and both output streams,
each read to end.
-}
data CapturedRun = CapturedRun
    { capturedExit :: ExitCode
    , capturedStdout :: String
    , capturedStderr :: String
    }
    deriving (Eq, Show)

{- | The positional view of a captured run, for the call sites that still match
on the @process@ triple.
-}
capturedTriple :: CapturedRun -> (ExitCode, String, String)
capturedTriple run = (capturedExit run, capturedStdout run, capturedStderr run)

{- | Why no child exists. The executable is named separately from the cause so a
caller can report the one without parsing the other.
-}
data RunFailure = RunFailure
    { failedExecutable :: FilePath
    , failedCause :: String
    }
    deriving (Eq, Show)

-- | The one rendering of a spawn failure.
renderRunFailure :: RunFailure -> String
renderRunFailure failure =
    "could not exec " ++ failedExecutable failure ++ ": " ++ failedCause failure

-- ---------------------------------------------------------------------------
-- The plain capture
-- ---------------------------------------------------------------------------

{- | Run @executable@ with exactly @arguments@, feeding @input@ on standard
input and capturing both output streams.

The argument vector is passed through unchanged: it is an @argv@, never a
command line, so no element is re-split, glob-expanded, or interpreted. A caller
that must embed one of these arguments in text an interpreter will re-split
quotes it first with "HostBootstrap.Effect.Quote".
-}
runCaptured :: FilePath -> [String] -> String -> IO (Either RunFailure CapturedRun)
runCaptured executable arguments input = do
    result <- trySynchronous $
        withCreateProcess
            (proc executable arguments){std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
            $ \inputPipe outputPipe errorPipe process -> case (inputPipe, outputPipe, errorPipe) of
                (Just inputHandle, Just outputHandle, Just errorHandle) -> do
                    mapM_ (`hSetBinaryMode` True) [inputHandle, outputHandle, errorHandle]
                    events <- newChan
                    _ <- forkIO (readPipe maxBound outputHandle >>= writeChan events . PipeEvent StandardOutput)
                    _ <- forkIO (readPipe maxBound errorHandle >>= writeChan events . PipeEvent StandardError)
                    writeRequest inputHandle (TextEncoding.encodeUtf8 (Text.pack input))
                    closeQuietly inputHandle
                    drained <- awaitPipes events
                    case drained of
                        PipesComplete out err -> do
                            code <- waitForProcess process
                            pure CapturedRun{capturedExit = code, capturedStdout = out, capturedStderr = err}
                        PipesLimitExceeded -> ioError (userError "captured output exceeds the host's addressable size")
                _ -> ioError (userError "the captured runner did not create all requested pipes")
    pure (either (\cause -> Left RunFailure{failedExecutable = executable, failedCause = show cause}) Right result)

-- ---------------------------------------------------------------------------
-- The bounded, group-leading capture
-- ---------------------------------------------------------------------------

{- | The complete frame a bounded child is given. Neither field is optional and
neither is inherited: a driver that leaves the launcher's environment in place
has no idea what its child read, and a driver that leaves the launcher's working
directory in place resolves the child's relative paths somewhere nobody chose.
-}
data RunNamespace = RunNamespace
    { runWorkingDirectory :: FilePath
    , runEnvironment :: [(String, String)]
    }
    deriving (Eq, Show)

{- | The three numbers a bounded run differs by. They are the whole table: a
caller that needs a longer wall, a larger transcript, or a slower teardown
supplies a different row, not a different runner.
-}
data RunBounds = RunBounds
    { boundWallMicros :: Int
    -- ^ how long the child may take in total
    , boundOutputBytes :: Int
    -- ^ per-stream ceiling; exceeding it is 'BoundedOutputLimit', not truncation
    , boundTerminationGraceMicros :: Int
    -- ^ how long the group is given to answer @SIGTERM@ before @SIGKILL@
    }
    deriving (Eq, Show)

{- | What a bounded run produced. The three non-completions are distinct on
purpose: a caller that folds them together cannot tell a tool that refused from
one that hung from one that never started.
-}
data BoundedRun
    = BoundedCompleted CapturedRun
    | BoundedTimedOut
    | BoundedOutputLimit
    | BoundedFailed String
    deriving (Eq, Show)

{- | Run @executable@ as the leader of its own process group, inside @namespace@
and within @bounds@, capturing both output streams.

On a wall-clock overrun or an output-ceiling breach the /group/ is torn down,
not just the leader, so a driver's grandchildren do not survive the driver. The
teardown is @SIGTERM@, then the grace period, then @SIGKILL@; on Windows, where
there is no group signal, it is 'terminateProcess' followed by a bounded wait.
-}
runBoundedGrouped :: RunBounds -> RunNamespace -> FilePath -> [String] -> IO BoundedRun
runBoundedGrouped bounds namespace executable arguments =
    runBoundedGroupedWithInput bounds namespace executable arguments ByteString.empty

-- | The bounded group runner with a request written to the leader's standard
-- input while the pipe remains open. A shipped command supervisor consumes
-- the framed request, then treats EOF as proof that its owning launcher died.
runBoundedGroupedWithInput :: RunBounds -> RunNamespace -> FilePath -> [String] -> ByteString.ByteString -> IO BoundedRun
runBoundedGroupedWithInput bounds namespace executable arguments request = do
    attempted <- trySynchronous (groupedProcess bounds namespace executable arguments request)
    pure (either (BoundedFailed . show) id attempted)

groupedProcess :: RunBounds -> RunNamespace -> FilePath -> [String] -> ByteString.ByteString -> IO BoundedRun
groupedProcess bounds namespace executable arguments request = do
    started <- getMonotonicTimeNSec
#if defined(darwin_HOST_OS)
    self <- getExecutablePath
    let processCommand = proc self (workingDirectoryEntryArguments ++ runWorkingDirectory namespace : executable : arguments)
        processWorkingDirectory = Nothing
#else
    let processCommand = proc executable arguments
        processWorkingDirectory = Just (runWorkingDirectory namespace)
#endif
        processSpec =
            processCommand
                { create_group = True
                , close_fds = True
                , cwd = processWorkingDirectory
                , env = Just (runEnvironment namespace)
                , std_in = CreatePipe
                , std_out = CreatePipe
                , std_err = CreatePipe
#if defined(mingw32_HOST_OS)
                , use_process_jobs = True
#endif
                }
        remainingWall = do
            now <- getMonotonicTimeNSec
            pure (max 0 (boundWallMicros bounds - fromIntegral ((now - started) `div` 1000)))
    withCreateProcess processSpec $ \input output errors process -> do
        processGroup <- getPid process
        let tearDown = terminateProcessGroup (boundTerminationGraceMicros bounds) processGroup process
            runProcess =
                case (input, output, errors) of
                    (Just inputHandle, Just outputHandle, Just errorHandle) -> do
                        mapM_ (`hSetBinaryMode` True) [inputHandle, outputHandle, errorHandle]
                        events <- newChan
                        _ <- forkIO (readPipe ceiling' outputHandle >>= writeChan events . PipeEvent StandardOutput)
                        _ <- forkIO (readPipe ceiling' errorHandle >>= writeChan events . PipeEvent StandardError)
                        budget <- remainingWall
                        drained <- timeout budget (writeRequest inputHandle request >> awaitPipes events)
                        let closeAll = mapM_ closeQuietly [inputHandle, outputHandle, errorHandle]
                        case drained of
                            Nothing -> tearDown >> closeAll >> pure BoundedTimedOut
                            Just PipesLimitExceeded -> tearDown >> closeAll >> pure BoundedOutputLimit
                            Just (PipesComplete out err) -> do
                                -- Both streams are at end, so the child is
                                -- almost always already gone; the wall still
                                -- bounds the wait, because a child that closes
                                -- its streams and then refuses to leave is
                                -- exactly what the bound is for.
                                remaining <- remainingWall
                                exited <- awaitProcessExit remaining process
                                case exited of
                                    Nothing -> tearDown >> closeAll >> pure BoundedTimedOut
                                    Just code -> do
                                        closeAll
                                        pure (completed code out err)
                    _ -> pure (BoundedFailed "the bounded runner did not create all requested pipes")
        runProcess `onException` tearDown
  where
    ceiling' = boundOutputBytes bounds

    completed code out err =
#if defined(darwin_HOST_OS)
        if code == ExitFailure 126 && cwdEntryRefusal `Text.isPrefixOf` Text.pack err
            then BoundedFailed err
            else
#endif
                BoundedCompleted (CapturedRun code out err)

-- | The binary's native cwd-and-exec entry, before ordinary command parsing.
workingDirectoryEntryArguments :: [String]
workingDirectoryEntryArguments = ["--hostbootstrap-working-directory-entry"]

cwdEntryRefusal :: Text.Text
cwdEntryRefusal = Text.pack "hostbootstrap working-directory entry: "

-- | Consume @cwd : executable : arguments@ without re-splitting any argument.
runWorkingDirectoryEntry :: [String] -> IO ()
runWorkingDirectoryEntry arguments = do
    attempted <- trySynchronous $ case arguments of
#if !defined(mingw32_HOST_OS)
        directory : executable : argv -> setCurrentDirectory directory >> executeFile executable False argv Nothing
#else
        _ : _ : _ -> ioError (userError "native cwd-and-exec is unavailable on Windows")
#endif
        _ -> ioError (userError "expected a working directory and executable")
    either
        (\failure -> hPutStrLn stderr (Text.unpack cwdEntryRefusal ++ show failure) >> exitWith (ExitFailure 126))
        pure
        attempted

writeRequest :: Handle -> ByteString.ByteString -> IO ()
writeRequest handle request = do
    written <- tryIOError (ByteString.hPut handle request >> hFlush handle)
    case written of
        Left failure | not (isResourceVanishedError failure) -> ioError failure
        _ -> pure ()

-- ---------------------------------------------------------------------------
-- Reading both pipes without deadlocking on either
-- ---------------------------------------------------------------------------

data PipeResult
    = PipeComplete String
    | PipeLimitExceeded

data PipeSide = StandardOutput | StandardError

data PipeEvent = PipeEvent PipeSide (Either SomeException PipeResult)

data PipesResult
    = PipesComplete String String
    | PipesLimitExceeded

{- | Drain one pipe to end, in chunks, refusing rather than truncating once the
ceiling is passed. A truncated transcript reads as a complete one.
-}
readPipe :: Int -> Handle -> IO (Either SomeException PipeResult)
readPipe ceilingBytes handle = trySynchronous (drain 0 [])
  where
    drain total chunks = do
        chunk <- ByteString.hGetSome handle pipeChunkBytes
        if ByteString.null chunk
            then pure (PipeComplete (Text.unpack (TextEncoding.decodeUtf8With lenientDecode (ByteString.concat (reverse chunks)))))
            else
                let nextTotal = total + ByteString.length chunk
                 in if nextTotal > ceilingBytes
                        then pure PipeLimitExceeded
                        else drain nextTotal (chunk : chunks)

-- | Await both readers, pairing them by the side each reported.
awaitPipes :: Chan PipeEvent -> IO PipesResult
awaitPipes events = do
    first <- readChan events >>= checked
    case first of
        (_, PipeLimitExceeded) -> pure PipesLimitExceeded
        (firstSide, PipeComplete firstValue) -> do
            second <- readChan events >>= checked
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

-- ---------------------------------------------------------------------------
-- Teardown
-- ---------------------------------------------------------------------------

terminateProcessGroup :: Int -> Maybe Pid -> ProcessHandle -> IO ()
terminateProcessGroup graceMicros processGroup process = do
#if defined(mingw32_HOST_OS)
    let _ = processGroup
    _ <- trySynchronous (terminateProcess process)
    _ <- awaitGroupExit graceMicros processGroup process
    _ <- awaitGroupExit reapMicros processGroup process
    pure ()
#else
    signalGroup sigTERM processGroup
    settled <- awaitGroupExit graceMicros processGroup process
    if settled
        then pure ()
        else do
            signalGroup sigKILL processGroup
            _ <- trySynchronous (terminateProcess process)
            _ <- awaitGroupExit reapMicros processGroup process
            pure ()
#endif

-- | How long a torn-down leader is waited for before the launcher gives up.
reapMicros :: Int
reapMicros = 2 * 1000 * 1000

-- | How often the teardown looks again while it waits out a grace period.
teardownPollMicros :: Int
teardownPollMicros = 25 * 1000

{- | Wait, within a budget, for the leader to exit and its group to empty.

Polled rather than blocked, and that is the whole point. @waitForProcess@ enters
a foreign call, and the gate builds this suite with the non-threaded runtime,
where such a call cannot be interrupted: a @timeout@ around it therefore waits
for a child that is refusing to leave rather than for the budget, and the
escalation to @SIGKILL@ below it never runs at all. Polling
'getProcessExitCode' reaps the leader without ever entering a call the launcher
cannot come back from, so the grace period is a bound the launcher actually
holds on every host.

The /group/ is what is waited for, not the leader alone. A driver whose leader
exits immediately and leaves a grandchild holding the pipes has not finished
just because the leader has: the descendants are exactly what a grouped teardown
exists to reach.
-}
awaitGroupExit :: Int -> Maybe Pid -> ProcessHandle -> IO Bool
awaitGroupExit budgetMicros processGroup process = go budgetMicros
  where
    go remaining = do
        exited <- trySynchronous (getProcessExitCode process)
        present <- groupPresent processGroup
        case exited of
            Right (Just _) | not present -> pure True
            _
                | remaining <= 0 -> pure False
                | otherwise -> do
                    threadDelay teardownPollMicros
                    go (remaining - teardownPollMicros)

{- | Wait, within a budget, for the leader alone to exit, and report its status.

The same polled shape as 'awaitGroupExit' and for the same reason: the exit
status must be readable without entering a call the launcher cannot be brought
back out of. The first look happens before any delay, so a child that has
already exited costs nothing.
-}
awaitProcessExit :: Int -> ProcessHandle -> IO (Maybe ExitCode)
awaitProcessExit budgetMicros process = go budgetMicros
  where
    go remaining = do
        exited <- trySynchronous (getProcessExitCode process)
        case exited of
            Right (Just code) -> pure (Just code)
            _
                | remaining <= 0 -> pure Nothing
                | otherwise -> do
                    threadDelay teardownPollMicros
                    go (remaining - teardownPollMicros)

{- | Whether any member of the process group is still there.

The probe is the null signal, which asks the kernel about the group without
delivering anything. A group whose leader has been reaped keeps its identifier
for exactly as long as it still has members, so this answers about the
descendants a teardown is trying to reach rather than about the leader alone.
-}
groupPresent :: Maybe Pid -> IO Bool
#if defined(mingw32_HOST_OS)
-- The Windows process handle owns a job object; terminateProcess ends its
-- descendants, and getProcessExitCode observes the leader's completed teardown.
groupPresent _ = pure False
#else
groupPresent Nothing = pure False
groupPresent (Just processGroup) = do
    probed <- trySynchronous (signalProcessGroup nullSignal processGroup)
    pure (either (const False) (const True) probed)
#endif

#if !defined(mingw32_HOST_OS)
signalGroup :: Signal -> Maybe Pid -> IO ()
signalGroup _ Nothing = pure ()
signalGroup signal (Just processGroup) = do
    _ <- trySynchronous (signalProcessGroup signal processGroup)
    pure ()
#endif

closeQuietly :: Handle -> IO ()
closeQuietly handle = do
    result <- trySynchronous (hClose handle)
    either (const (pure ())) pure result

{- | Catch synchronous exceptions only. An asynchronous exception delivered to
this thread is a cancellation of the launcher, not a failure of the child, and
reporting it as one is how a cancelled run reads as a broken tool.
-}
trySynchronous :: IO value -> IO (Either SomeException value)
trySynchronous action = do
    attempted <- try action
    case attempted of
        Left failure
            | Just asynchronous <- (fromException failure :: Maybe SomeAsyncException) ->
                throwIO asynchronous
            | otherwise -> pure (Left failure)
        Right value -> pure (Right value)
