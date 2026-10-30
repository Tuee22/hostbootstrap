{-# LANGUAGE CPP #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The sealed host-invocation *shape* boundary for a child that outlives its
launcher.

@development_plan_standards.md § K@ fixes *which* executable a host invocation
names; this module fixes the *shape* every such invocation is allowed to take
(@§ HH@, explained in @documents/architecture/unrepresentable_state.md@).
Resolving a path absolutely says nothing about the stdio disposition,
descriptor inheritance, session, environment, or working directory the child is
handed, and a child that outlives its launcher is where the two axes come apart
most sharply.

Such a child has exactly one lawful shape, so the unlawful shapes have no
constructor here: 'DetachedLaunch' hides its record constructor and every field
accessor, so no module outside this one assembles a
'System.Process.CreateProcess' for a detached child, and the stdio disposition
is not a parameter. Each of 'System.Process.StdStream'\'s other constructors is
wrong for its own reason:

  * @Inherit@ retains the launcher's capture pipe, so nothing reading the
    launcher ever observes EOF;
  * @CreatePipe@ leaves the parent blocked on an EOF that never arrives, or
    delivering @SIGPIPE@ after it closes the read end;
  * @NoStream@ /closes/ the descriptor, which the @process@ documentation
    restricts to a child that never uses it — and which a threaded-RTS child
    answers by claiming the freed descriptors for its own IO-manager control
    channel.

The lawful shape is therefore @UseHandle@ on all three streams: standard input
is the host's null device, so the child sees an open descriptor already at EOF,
and both output streams are appended to one retained sink so a startup failure
names its own cause instead of collapsing to \"the process is gone\"
(@§ CC@).

'withDetachedChild' owns the /launch/: normal return leaves the child running
and releases only the launcher's handles. Acquiring the streams and spawning
either succeeds or returns a typed 'DetachedLaunchError' having created no
child. Exceptional handoff or body exit aborts the exact child through bounded
termination and polling, while the body's original exception propagates.

What this does not buy: hidden constructors exclude construction by cooperating
code in this repository. They do not bind a caller who depends on @process@
directly, and they do not make a runtime disposition safe. Keeping this surface
sealed is a drift-guard obligation, not a property the type system maintains on
its own.
-}
module HostBootstrap.Detached (
    -- * The sealed launch specification
    DetachedLaunch,
    detachedLaunch,
    detachedLaunchExecutable,
    detachedLaunchArguments,
    detachedLaunchCommandLine,

    -- * Absolute-by-construction operands
    DetachedWorkingDirectory,
    mkDetachedWorkingDirectory,
    detachedWorkingDirectoryPath,
    DetachedOutputSink,
    mkDetachedOutputSink,
    detachedOutputSinkPath,

    -- * The launch bracket and its running child
    DetachedChild,
    DetachedIO,
    liftDetachedIO,
    tryDetachedIO,
    onDetachedException,
    withDetachedChild,
    detachedChildPid,
    detachedChildOutput,
    terminateDetachedChild,
    awaitDetachedChild,

    -- * Typed launch failure
    DetachedLaunchError (..),
    renderDetachedLaunchError,
)
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, SomeException, evaluate, finally, mask, onException, try, uninterruptibleMask_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.Encoding.Error as TextEncodingError
import GHC.Clock (getMonotonicTimeNSec)
import HostBootstrap.HostTool (AbsExe, absExePath)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode)
import System.FilePath (isAbsolute, normalise, takeDirectory)
import System.IO (Handle, IOMode (AppendMode, ReadMode, WriteMode), hClose, openFile, withFile)
import System.Info (os)
import System.Process (
    CreateProcess (close_fds, cwd, detach_console, env, new_session, std_err, std_in, std_out),
    Pid,
    ProcessHandle,
    StdStream (UseHandle),
    createProcess,
    getPid,
    getProcessExitCode,
    proc,
    terminateProcess,
 )
#if !defined(mingw32_HOST_OS)
import System.Posix.Signals (sigKILL, signalProcess)
#endif

{- | An absolute working directory for a detached child. The constructor is
private, so the directory is absolute by construction.
-}
newtype DetachedWorkingDirectory = DetachedWorkingDirectory FilePath
    deriving (Eq, Ord, Show)

{- | The absolute path both of a detached child's output streams are appended
to. The constructor is private.
-}
newtype DetachedOutputSink = DetachedOutputSink FilePath
    deriving (Eq, Ord, Show)

{- | A complete launch specification for a child that outlives its launcher.
The record constructor and every field accessor are private to this module: the
stdio disposition, descriptor inheritance, session, and console detachment each
have exactly one lawful value for such a child and are fixed inside
'detachedProcess' rather than offered as parameters.
-}
data DetachedLaunch = DetachedLaunch
    { dlExecutable :: AbsExe
    , dlArguments :: [String]
    , dlEnvironment :: [(String, String)]
    , dlWorkingDirectory :: DetachedWorkingDirectory
    , dlOutputSink :: DetachedOutputSink
    }

{- | A child that is running now. The @child@ index is bound by
'withDetachedChild', so the value cannot outlive the launch that produced it.
The constructor and field accessors are private.
-}
data DetachedChild child = DetachedChild
    { dcHandle :: ProcessHandle
    , dcSink :: DetachedOutputSink
    }

type role DetachedChild nominal

{- | Actions bound to the child admitted by one 'withDetachedChild' body.

Only the launch bracket interprets this monad. Ordinary IO may be lifted into
it, but no action that retains the child can be unwrapped or run after the
body returns.
-}
newtype DetachedIO child a = DetachedIO (IO a)
    deriving (Functor, Applicative, Monad)

type role DetachedIO nominal representational

liftDetachedIO :: IO a -> DetachedIO child a
liftDetachedIO = DetachedIO

tryDetachedIO :: DetachedIO child a -> DetachedIO child (Either SomeException a)
tryDetachedIO (DetachedIO action) = DetachedIO (try action)

onDetachedException :: DetachedIO child a -> DetachedIO child b -> DetachedIO child a
onDetachedException (DetachedIO action) (DetachedIO cleanup) =
    DetachedIO (action `onException` cleanup)

-- | Why a launch produced no child. Closed, with a total renderer.
data DetachedLaunchError
    = -- | The retained output sink could not be created or opened.
      DetachedOutputSinkUnavailable FilePath String
    | -- | The host's null device could not be opened for reading.
      DetachedNullDeviceUnavailable FilePath String
    | -- | The child could not be spawned.
      DetachedSpawnFailed FilePath String
    deriving (Eq, Show)

renderDetachedLaunchError :: DetachedLaunchError -> String
renderDetachedLaunchError (DetachedOutputSinkUnavailable path detail) =
    "detached launch: output sink unavailable at " ++ path ++ ": " ++ detail
renderDetachedLaunchError (DetachedNullDeviceUnavailable path detail) =
    "detached launch: null device unavailable at " ++ path ++ ": " ++ detail
renderDetachedLaunchError (DetachedSpawnFailed exe detail) =
    "detached launch: could not spawn " ++ exe ++ ": " ++ detail

{- | Build an absolute working directory, rejecting anything that is not an
absolute path.
-}
mkDetachedWorkingDirectory :: FilePath -> Either String DetachedWorkingDirectory
mkDetachedWorkingDirectory path
    | isAbsolute path = Right (DetachedWorkingDirectory (normalise path))
    | otherwise = Left ("detached working directory is not an absolute path: " ++ path)

detachedWorkingDirectoryPath :: DetachedWorkingDirectory -> FilePath
detachedWorkingDirectoryPath (DetachedWorkingDirectory path) = path

{- | Build an absolute output sink, rejecting anything that is not an absolute
path.
-}
mkDetachedOutputSink :: FilePath -> Either String DetachedOutputSink
mkDetachedOutputSink path
    | isAbsolute path = Right (DetachedOutputSink (normalise path))
    | otherwise = Left ("detached output sink is not an absolute path: " ++ path)

detachedOutputSinkPath :: DetachedOutputSink -> FilePath
detachedOutputSinkPath (DetachedOutputSink path) = path

{- | The only producer of a 'DetachedLaunch'. The executable is an 'AbsExe'
(@§ K@), the working directory and output sink are absolute by construction,
and the environment supplied here is the child's /complete/ environment — a
detached child never inherits the launcher's.
-}
detachedLaunch ::
    AbsExe ->
    [String] ->
    [(String, String)] ->
    DetachedWorkingDirectory ->
    DetachedOutputSink ->
    DetachedLaunch
detachedLaunch exe args environment workingDirectory sink =
    DetachedLaunch
        { dlExecutable = exe
        , dlArguments = args
        , dlEnvironment = environment
        , dlWorkingDirectory = workingDirectory
        , dlOutputSink = sink
        }

detachedLaunchExecutable :: DetachedLaunch -> AbsExe
detachedLaunchExecutable = dlExecutable

detachedLaunchArguments :: DetachedLaunch -> [String]
detachedLaunchArguments = dlArguments

-- | The launch rendered for a diagnostic. Not an invocation target.
detachedLaunchCommandLine :: DetachedLaunch -> String
detachedLaunchCommandLine launch =
    unwords (absExePath (dlExecutable launch) : dlArguments launch)

{- | Launch a detached child and run @body@ while it is running.

When @body@ returns normally the child is still running and only the launcher's
handles have been released. An exceptional handoff or body exit requests
termination of that exact child, escalating after a bounded grace and polling
again, without replacing the original exception. Acquisition, spawn, and body
construction are masked; the body action runs with the caller's masking state.
-}
withDetachedChild ::
    DetachedLaunch ->
    (forall child. DetachedChild child -> DetachedIO child a) ->
    IO (Either DetachedLaunchError a)
withDetachedChild launch body = mask $ \restore -> do
    let sinkPath = detachedOutputSinkPath (dlOutputSink launch)
    truncated <-
        try
            ( do
                createDirectoryIfMissing True (takeDirectory sinkPath)
                withFile sinkPath WriteMode (const (pure ()))
            ) ::
            IO (Either IOException ())
    case truncated of
        Left err -> pure (Left (DetachedOutputSinkUnavailable sinkPath (show err)))
        Right () -> do
            -- One handle carries both output streams. That is the boundary's
            -- "both outputs reach one place" made literal, and it is also the
            -- only shape the runtime allows: GHC's single-writer handle lock
            -- refuses a second writable handle on the same file in one process.
            opened <- try (openFile sinkPath AppendMode) :: IO (Either IOException Handle)
            case opened of
                Left err -> pure (Left (DetachedOutputSinkUnavailable sinkPath (show err)))
                Right sink -> do
                    ( do
                        nullIn <- try (openFile nullDevicePath ReadMode) :: IO (Either IOException Handle)
                        case nullIn of
                            Left err -> do
                                closeQuietly sink
                                pure (Left (DetachedNullDeviceUnavailable nullDevicePath (show err)))
                            Right stdinHandle -> spawn restore stdinHandle sink
                        ) `onException` closeQuietly sink
  where
    spawn restore stdinHandle sink = do
        let closeHandles = closeQuietly stdinHandle `finally` closeQuietly sink
        spawned <-
            (try (createProcess (detachedProcess launch stdinHandle sink)) ::
                IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle)))
                `onException` closeHandles
        -- 'createProcess' closes the handles it was handed through @UseHandle@;
        -- closing them again is a no-op and keeps the failure path symmetric.
        case spawned of
            Left err -> do
                closeHandles
                pure (Left (DetachedSpawnFailed (absExePath (dlExecutable launch)) (show err)))
            Right (_, _, _, handle) -> do
                -- Apply the body while masked: a child whose hand-off fails
                -- is terminated before the exception can leave the launch.
                DetachedIO action <-
                    (closeHandles >> evaluate (body (DetachedChild{dcHandle = handle, dcSink = dlOutputSink launch})))
                        `onException` cleanupExactChild handle
                Right <$> (restore action `onException` cleanupExactChild handle)

-- | The child's process id, or 'Nothing' once it has been reaped.
detachedChildPid :: DetachedChild child -> DetachedIO child (Maybe Pid)
detachedChildPid = DetachedIO . getPid . dcHandle

{- | Everything the child has written to either output stream so far, so a
launcher can quote the cause of a startup failure. Decoding is lenient: this is
a diagnostic, and a child that dies mid-write must not also break the report.
-}
detachedChildOutput :: DetachedChild child -> DetachedIO child Text
detachedChildOutput child = DetachedIO $ do
    raw <-
        try (ByteString.readFile (detachedOutputSinkPath (dcSink child))) ::
            IO (Either IOException ByteString)
    pure (either (const Text.empty) decodeLenient raw)
  where
    decodeLenient = TextEncoding.decodeUtf8With TextEncodingError.lenientDecode

{- | Ask the child to terminate explicitly. Normal return leaves it running;
exceptional handoff or body exit invokes the bracket's bounded cleanup.
-}
terminateDetachedChild :: DetachedChild child -> DetachedIO child ()
terminateDetachedChild = DetachedIO . terminateProcess . dcHandle

{- | Wait up to @micros@ for the child to exit, returning 'Nothing' if it is
still running when the wait elapses.
-}
awaitDetachedChild :: Int -> DetachedChild child -> DetachedIO child (Maybe ExitCode)
awaitDetachedChild micros = DetachedIO . awaitProcessExit micros . dcHandle

awaitProcessExit :: Int -> ProcessHandle -> IO (Maybe ExitCode)
awaitProcessExit micros handle = do
    started <- getMonotonicTimeNSec
    poll (toInteger started + toInteger (max 0 micros) * 1000)
  where
    poll deadline = do
        exited <- getProcessExitCode handle
        case exited of
            Just code -> pure (Just code)
            Nothing -> do
                now <- getMonotonicTimeNSec
                let remaining = deadline - toInteger now
                if remaining <= 0
                    then pure Nothing
                    else do
                        threadDelay (fromInteger (min 10000 ((remaining + 999) `div` 1000)))
                        poll deadline

{- | Abort only this exact child when construction or execution of its body
fails. Cleanup is bounded and cannot replace the body's original exception.
The second signal is a hard termination on each platform; no process-group or
descendant lifetime is claimed here.
-}
cleanupExactChild :: ProcessHandle -> IO ()
cleanupExactChild handle = uninterruptibleMask_ $ do
    _ <- try (terminateProcess handle) :: IO (Either SomeException ())
    graceful <- try (awaitProcessExit 500000 handle) :: IO (Either SomeException (Maybe ExitCode))
    case graceful of
        Right (Just _) -> pure ()
        _ -> do
            _ <- try forceTermination :: IO (Either SomeException ())
            _ <- try (awaitProcessExit 500000 handle) :: IO (Either SomeException (Maybe ExitCode))
            pure ()
  where
#if defined(mingw32_HOST_OS)
    forceTermination = terminateProcess handle
#else
    forceTermination = getPid handle >>= maybe (pure ()) (signalProcess sigKILL)
#endif

{- | The one assembled process specification for a detached child. It is
private: the stdio disposition, descriptor inheritance, session, and console
detachment are fixed here and are not parameters.

@close_fds@ closes every descriptor above the three standard streams, so the
child inherits no other handle of the launcher's. @new_session@ puts the child
in its own POSIX session, so it is not in the launcher's process group and has
no controlling terminal; @detach_console@ is its Windows counterpart. Both are
ignored on the platform they do not apply to, and @process@ honours @close_fds@
on Windows only when all three streams are inherited — which is why the Windows
host-daemon lane uses its own hidden launch rather than this one.
-}
detachedProcess :: DetachedLaunch -> Handle -> Handle -> CreateProcess
detachedProcess launch stdinHandle sink =
    (proc (absExePath (dlExecutable launch)) (dlArguments launch))
        { env = Just (dlEnvironment launch)
        , cwd = Just (detachedWorkingDirectoryPath (dlWorkingDirectory launch))
        , std_in = UseHandle stdinHandle
        , std_out = UseHandle sink
        , std_err = UseHandle sink
        , close_fds = True
        , new_session = True
        , detach_console = True
        }

-- | The host's null device: an open descriptor that is already at EOF.
nullDevicePath :: FilePath
nullDevicePath
    | os == "mingw32" = "\\\\.\\NUL"
    | otherwise = "/dev/null"

closeQuietly :: Handle -> IO ()
closeQuietly handle = do
    closed <- try (hClose handle) :: IO (Either IOException ())
    either (const (pure ())) pure closed
