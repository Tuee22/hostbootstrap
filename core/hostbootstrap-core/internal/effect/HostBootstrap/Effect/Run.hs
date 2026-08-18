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
    )
where

import Control.Concurrent (forkIO)
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
import qualified Data.ByteString.Char8 as ByteStringChar
import System.Exit (ExitCode)
import System.IO (Handle, hClose)
#if !defined(mingw32_HOST_OS)
import System.Posix.Signals (Signal, sigKILL, sigTERM, signalProcessGroup)
#endif
import System.Process
    ( CreateProcess (create_group, cwd, env, std_err, std_in, std_out)
    , Pid
    , ProcessHandle
    , StdStream (CreatePipe)
    , getPid
    , proc
    , readProcessWithExitCode
    , terminateProcess
    , waitForProcess
    , withCreateProcess
    )
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
    result <- trySynchronous (readProcessWithExitCode executable arguments input)
    pure $ case result of
        Right (code, out, err) ->
            Right CapturedRun{capturedExit = code, capturedStdout = out, capturedStderr = err}
        Left cause ->
            Left RunFailure{failedExecutable = executable, failedCause = show cause}

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
runBoundedGrouped bounds namespace executable arguments = do
    attempted <- trySynchronous (groupedProcess bounds namespace executable arguments)
    pure (either (BoundedFailed . show) id attempted)

groupedProcess :: RunBounds -> RunNamespace -> FilePath -> [String] -> IO BoundedRun
groupedProcess bounds namespace executable arguments =
    withCreateProcess processSpec $ \input output errors process -> do
        processGroup <- getPid process
        let tearDown = terminateProcessGroup (boundTerminationGraceMicros bounds) processGroup process
            runProcess =
                case (input, output, errors) of
                    (Just inputHandle, Just outputHandle, Just errorHandle) -> do
                        events <- newChan
                        _ <- forkIO (readPipe ceiling' outputHandle >>= writeChan events . PipeEvent StandardOutput)
                        _ <- forkIO (readPipe ceiling' errorHandle >>= writeChan events . PipeEvent StandardError)
                        completed <-
                            timeout (boundWallMicros bounds) $ do
                                pipes <- awaitPipes events
                                case pipes of
                                    PipesLimitExceeded -> pure BoundedOutputLimit
                                    PipesComplete out err -> do
                                        code <- waitForProcess process
                                        pure (BoundedCompleted (CapturedRun code out err))
                        let closeAll = mapM_ closeQuietly [inputHandle, outputHandle, errorHandle]
                        case completed of
                            Nothing -> tearDown >> closeAll >> pure BoundedTimedOut
                            Just BoundedOutputLimit -> tearDown >> closeAll >> pure BoundedOutputLimit
                            Just result -> closeAll >> pure result
                    _ -> pure (BoundedFailed "the bounded runner did not create all requested pipes")
        runProcess `onException` tearDown
  where
    ceiling' = boundOutputBytes bounds

#if defined(darwin_HOST_OS)
    -- process-1.6.26 cannot combine @create_group@, an explicit environment,
    -- and @cwd@ on macOS. The working directory is therefore established by an
    -- absolute shell that immediately execs the requested leader: the exec
    -- preserves the newly created process-group identity, and the shell reads
    -- no text of its own beyond this fixed positional form. This is the one
    -- platform-limitation seam § KK leaves the runner, and it is here rather
    -- than in a caller so both drivers get the same answer.
    processCommand =
        proc
            "/bin/sh"
            ( [ "-c"
              , "cd \"$1\" && shift && exec \"$@\""
              , "hostbootstrap-bounded-runner"
              , runWorkingDirectory namespace
              , executable
              ]
                ++ arguments
            )
    processWorkingDirectory = Nothing
#else
    processCommand = proc executable arguments
    processWorkingDirectory = Just (runWorkingDirectory namespace)
#endif

    processSpec =
        processCommand
            { create_group = True
            , cwd = processWorkingDirectory
            , env = Just (runEnvironment namespace)
            , std_in = CreatePipe
            , std_out = CreatePipe
            , std_err = CreatePipe
            }

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
            then pure (PipeComplete (ByteStringChar.unpack (ByteString.concat (reverse chunks))))
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
    let _ = (graceMicros, processGroup)
    _ <- trySynchronous (terminateProcess process)
    _ <- timeout reapMicros (waitForProcess process)
    pure ()
#else
    signalGroup sigTERM processGroup
    graceful <- timeout graceMicros (waitForProcess process)
    case graceful of
        Just _ -> pure ()
        Nothing -> do
            signalGroup sigKILL processGroup
            _ <- trySynchronous (terminateProcess process)
            _ <- timeout reapMicros (waitForProcess process)
            pure ()
#endif

-- | How long a torn-down leader is waited for before the launcher gives up.
reapMicros :: Int
reapMicros = 2 * 1000 * 1000

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
