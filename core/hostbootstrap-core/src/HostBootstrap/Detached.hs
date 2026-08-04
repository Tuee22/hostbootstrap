{-# LANGUAGE RankNTypes #-}
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

'withDetachedChild' owns the /launch/, never the child's lifetime. Acquiring
the streams and spawning is total: it either succeeds or returns a typed
'DetachedLaunchError' having created no child. On exit the child is still
running and only the launcher's own handles have been released, so an
ownership-preserving abort path in the body keeps its behaviour — the body's
exceptions propagate unchanged.

What this does not buy: hidden constructors exclude construction by cooperating
code in this repository. They do not bind a caller who depends on @process@
directly, and they do not make a runtime disposition safe. Keeping this surface
sealed is a drift-guard obligation, not a property the type system maintains on
its own.
-}
module HostBootstrap.Detached
    ( -- * The sealed launch specification
      DetachedLaunch
    , detachedLaunch
    , detachedLaunchExecutable
    , detachedLaunchArguments
    , detachedLaunchCommandLine

      -- * Absolute-by-construction operands
    , DetachedWorkingDirectory
    , mkDetachedWorkingDirectory
    , detachedWorkingDirectoryPath
    , DetachedOutputSink
    , mkDetachedOutputSink
    , detachedOutputSinkPath

      -- * The launch bracket and its running child
    , DetachedChild
    , withDetachedChild
    , detachedChildPid
    , detachedChildOutput
    , terminateDetachedChild
    , awaitDetachedChild

      -- * Typed launch failure
    , DetachedLaunchError (..)
    , renderDetachedLaunchError
    )
where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.Encoding.Error as TextEncodingError
import HostBootstrap.HostTool (AbsExe, absExePath)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode)
import System.FilePath (isAbsolute, normalise, takeDirectory)
import System.IO (Handle, IOMode (AppendMode, ReadMode, WriteMode), hClose, openFile)
import System.Info (os)
import System.Process
    ( CreateProcess (close_fds, cwd, detach_console, env, new_session, std_err, std_in, std_out)
    , Pid
    , ProcessHandle
    , StdStream (UseHandle)
    , createProcess
    , getPid
    , proc
    , terminateProcess
    , waitForProcess
    )
import System.Timeout (timeout)

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

The bracket owns the launch, not the child: when @body@ returns the child is
still running and only the launcher's own handles have been released. Acquiring
the streams and spawning is total — on failure no child exists — while @body@'s
exceptions propagate unchanged.
-}
withDetachedChild ::
    DetachedLaunch ->
    (forall child. DetachedChild child -> IO a) ->
    IO (Either DetachedLaunchError a)
withDetachedChild launch body = do
    let sinkPath = detachedOutputSinkPath (dlOutputSink launch)
    truncated <-
        try
            ( do
                createDirectoryIfMissing True (takeDirectory sinkPath)
                openFile sinkPath WriteMode >>= hClose
            )
            :: IO (Either IOException ())
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
                    nullIn <- try (openFile nullDevicePath ReadMode) :: IO (Either IOException Handle)
                    case nullIn of
                        Left err -> do
                            closeQuietly sink
                            pure (Left (DetachedNullDeviceUnavailable nullDevicePath (show err)))
                        Right stdinHandle -> spawn stdinHandle sink
  where
    spawn stdinHandle sink = do
        spawned <-
            try (createProcess (detachedProcess launch stdinHandle sink))
                :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
        -- 'createProcess' closes the handles it was handed through @UseHandle@;
        -- closing them again is a no-op and keeps the failure path symmetric.
        mapM_ closeQuietly [stdinHandle, sink]
        case spawned of
            Left err ->
                pure (Left (DetachedSpawnFailed (absExePath (dlExecutable launch)) (show err)))
            Right (_, _, _, handle) ->
                Right <$> body (DetachedChild{dcHandle = handle, dcSink = dlOutputSink launch})

-- | The child's process id, or 'Nothing' once it has been reaped.
detachedChildPid :: DetachedChild child -> IO (Maybe Pid)
detachedChildPid = getPid . dcHandle

{- | Everything the child has written to either output stream so far, so a
launcher can quote the cause of a startup failure. Decoding is lenient: this is
a diagnostic, and a child that dies mid-write must not also break the report.
-}
detachedChildOutput :: DetachedChild child -> IO Text
detachedChildOutput child = do
    raw <-
        try (ByteString.readFile (detachedOutputSinkPath (dcSink child)))
            :: IO (Either IOException ByteString)
    pure (either (const Text.empty) decodeLenient raw)
  where
    decodeLenient = TextEncoding.decodeUtf8With TextEncodingError.lenientDecode

-- | Ask the child to terminate. The bracket never does this on its own.
terminateDetachedChild :: DetachedChild child -> IO ()
terminateDetachedChild = terminateProcess . dcHandle

{- | Wait up to @micros@ for the child to exit, returning 'Nothing' if it is
still running when the wait elapses.
-}
awaitDetachedChild :: Int -> DetachedChild child -> IO (Maybe ExitCode)
awaitDetachedChild micros child = timeout micros (waitForProcess (dcHandle child))

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
