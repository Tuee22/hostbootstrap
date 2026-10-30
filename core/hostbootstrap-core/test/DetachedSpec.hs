{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The host-invocation *shape* boundary (§ HH).

These are deliberately **behavioural** assertions. The disposition this boundary
replaced was pinned by a test that asserted the current value of an unsealed
field, so every gate agreed with the defect for as long as the defect existed
(@documents/architecture/unrepresentable_state.md@). An assertion that a
launched child /does the lawful thing/ cannot be satisfied by an unlawful shape:
@NoStream@ closes the child's standard input so it cannot read to EOF,
@Inherit@ sends the child's output to this test runner rather than to the
retained sink, and @CreatePipe@ does not typecheck because the disposition is
not a parameter at all.

The child is this test executable re-invoked through 'runDetachedChildProbe' —
the same separate-process idiom the protected-entry and harness-reservation
probes use, so the boundary is exercised by a real child on every platform
rather than by a shell that exists on only one.
-}
module DetachedSpec (tests, runDetachedChildProbe) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, try)
import Control.Monad (filterM, forM, forM_)
import qualified Data.ByteString as ByteString
import Data.List (isInfixOf, sort)
import Data.Maybe (isJust)
import qualified Data.Text as Text
import GHC.Clock (getMonotonicTimeNSec)
import HostBootstrap.Detached (
    DetachedLaunch,
    DetachedLaunchError (DetachedNullDeviceUnavailable, DetachedOutputSinkUnavailable, DetachedSpawnFailed),
    awaitDetachedChild,
    detachedChildOutput,
    detachedChildPid,
    detachedLaunch,
    detachedLaunchCommandLine,
    detachedOutputSinkPath,
    detachedWorkingDirectoryPath,
    mkDetachedOutputSink,
    mkDetachedWorkingDirectory,
    liftDetachedIO,
    renderDetachedLaunchError,
    terminateDetachedChild,
    withDetachedChild,
 )
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.HostTool (AbsExe, absExePath, mkAbsExe)
import qualified SourceGuard
import System.Directory (
    canonicalizePath,
    doesDirectoryExist,
    doesFileExist,
    getCurrentDirectory,
    makeAbsolute,
 )
import System.Environment (getArgs, getEnvironment, getExecutablePath, lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO (Handle, hFlush, hPutStrLn, stderr, stdin, stdout)
import System.IO.Temp (withSystemTempDirectory)
import System.Info (os)
import System.Process (proc, readCreateProcessWithExitCode)
#if !defined(mingw32_HOST_OS)
import System.Posix.Signals (Handler (Ignore), installHandler, sigTERM)
#endif
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

-- | The argv this test executable answers as a detached child.
childProbeFlag :: String
childProbeFlag = "--hostbootstrap-detached-child-probe"

stdinEofMarker :: String
stdinEofMarker = "detached-probe: standard input reached EOF after 0 bytes"

stdoutMarker :: String
stdoutMarker = "detached-probe: wrote this on standard output"

stderrMarker :: String
stderrMarker = "detached-probe: wrote this on standard error"

tickMarker :: String
tickMarker = "detached-probe: still running"

stoppedMarker :: String
stoppedMarker = "detached-probe: observed shutdown request"

{- | The detached child this suite launches.

@stdio@ reports what it observed about its own standard input, writes one line
to each output stream, and exits. @linger@ does the same and then appends a tick
every 100ms until a shutdown file appears, so a caller can prove the child
outlived the launch bracket from outside it — the rank-2 index refuses to let
the child value escape, which is exactly the property under test.
-}
runDetachedChildProbe :: [String] -> IO ()
runDetachedChildProbe ("stdio" : _) = reportStreams
runDetachedChildProbe ("pending-stdin" : _) =
    withProbeLaunch ["stdio"] $ \launch _ -> do
        outcome <- withDetachedChild launch $ \child -> do
            _ <- awaitDetachedChild childWaitMicros child
            detachedChildOutput child
        either (ioError . userError . renderDetachedLaunchError) (putStrLn . Text.unpack) outcome
runDetachedChildProbe ("context" : _) = do
    reportStreams
    directory <- getCurrentDirectory >>= canonicalizePath
    present <- lookupEnv "HOSTBOOTSTRAP_DETACHED_SENTINEL"
    omitted <- lookupEnv "HOSTBOOTSTRAP_DETACHED_OMITTED"
    say stdout ("detached-probe: directory=" <> show directory)
    say stdout ("detached-probe: sentinel=" <> show present)
    say stdout ("detached-probe: omitted=" <> show omitted)
runDetachedChildProbe ("linger" : shutdownPath : options) = do
    if "ignore-termination" `elem` options then ignoreSoftTermination else pure ()
    reportStreams
    tick (1200 :: Int)
  where
    tick 0 = pure ()
    tick remaining = do
        say stdout tickMarker
        stop <- doesFileExist shutdownPath
        if stop
            then say stdout stoppedMarker
            else threadDelay 100000 >> tick (remaining - 1)
runDetachedChildProbe other =
    say stderr ("detached-probe: unknown mode " ++ show other)

-- Windows termination is already hard; POSIX can require the escalation.
ignoreSoftTermination :: IO ()
#if defined(mingw32_HOST_OS)
ignoreSoftTermination = pure ()
#else
ignoreSoftTermination = do
    _ <- installHandler sigTERM Ignore Nothing
    pure ()
#endif

{- | Report what the child observed about its own standard input, then write one
line to each output stream. A child whose standard input was /closed/ rather
than left open at EOF cannot produce 'stdinEofMarker': the read raises instead.
-}
reportStreams :: IO ()
reportStreams = do
    consumed <- try (ByteString.hGetContents stdin) :: IO (Either IOException ByteString.ByteString)
    case consumed of
        Left err -> say stdout ("detached-probe: standard input unusable: " ++ show err)
        Right payload
            | ByteString.null payload -> say stdout stdinEofMarker
            | otherwise ->
                say
                    stdout
                    ("detached-probe: standard input carried " ++ show (ByteString.length payload) ++ " bytes")
    say stdout stdoutMarker
    say stderr stderrMarker
    args <- getArgs
    say stdout ("detached-probe: arguments=" <> show args)

say :: Handle -> String -> IO ()
say handle message = hPutStrLn handle message >> hFlush handle

tests :: TestTree
tests =
    testGroup
        "detached launch shape"
        [ absoluteByConstruction
        , launchedChildDoesTheLawfulThing
        , launchUsesItsOwnInput
        , launchUsesItsOwnContext
        , boundedChildWait
        , terminationIsObserved
        , childOutlivesTheBracket
        , totalAcquireAndSpawn
        , bodyExceptionsPropagate
        , bodyExceptionStopsChild
        , noProductionModuleClosesADescriptor
        ]

absoluteByConstruction :: TestTree
absoluteByConstruction =
    testGroup
        "operands are absolute by construction"
        [ testCase "a relative working directory is rejected" $
            assertBool "relative accepted" (isLeft (mkDetachedWorkingDirectory (relativeish "dir")))
        , testCase "a relative output sink is rejected" $
            assertBool "relative accepted" (isLeft (mkDetachedOutputSink (relativeish "sink")))
        , testCase "an absolute working directory is retained" $
            fmap detachedWorkingDirectoryPath (mkDetachedWorkingDirectory (absoluteish "work"))
                @?= Right (absoluteish "work")
        , testCase "an absolute output sink is retained" $
            fmap detachedOutputSinkPath (mkDetachedOutputSink (absoluteish "sink"))
                @?= Right (absoluteish "sink")
        ]
  where
    isLeft = either (const True) (const False)

{- | The load-bearing assertion: it observes the three properties the sealed
shape exists to guarantee, and no unlawful disposition satisfies it.
-}
launchedChildDoesTheLawfulThing :: TestTree
launchedChildDoesTheLawfulThing =
    testCase "a launched child has standard input open at EOF and both outputs in one place" $
        withProbeLaunch ["stdio"] $ \launch sinkPath -> do
            outcome <- withDetachedChild launch $ \child -> do
                pid <- detachedChildPid child
                exited <- awaitDetachedChild childWaitMicros child
                retained <- detachedChildOutput child
                pure (pid, exited, Text.unpack retained)
            case outcome of
                Left err -> assertFailure ("launch failed: " ++ renderDetachedLaunchError err)
                Right (pid, exited, retained) -> do
                    assertBool "the launch reported no process id" (isJust pid)
                    assertEqual "the child did not exit cleanly" (Just ExitSuccess) exited
                    assertBool
                        ("standard input was not open at EOF; retained output was:\n" ++ retained)
                        (stdinEofMarker `isInfixOf` retained)
                    assertBool
                        ("standard output did not reach the sink; retained output was:\n" ++ retained)
                        (stdoutMarker `isInfixOf` retained)
                    assertBool
                        ("standard error did not reach the sink; retained output was:\n" ++ retained)
                        (stderrMarker `isInfixOf` retained)
                    assertBool "the child received different arguments"
                        (("detached-probe: arguments=" <> show [childProbeFlag, "stdio"]) `isInfixOf` retained)
                    onDisk <- readFile sinkPath
                    assertBool
                        "the retained output disagrees with the sink on disk"
                        (stdoutMarker `isInfixOf` onDisk && stderrMarker `isInfixOf` onDisk)

launchUsesItsOwnInput :: TestTree
launchUsesItsOwnInput =
    testCase "the child sees EOF while its launcher has pending standard-input bytes" $ do
        exe <- probeExecutable
        (status, output, diagnostic) <-
            readCreateProcessWithExitCode
                (proc (absExePath exe) [childProbeFlag, "pending-stdin"])
                "pending launcher input that the detached child must never read\n"
        assertEqual diagnostic ExitSuccess status
        assertBool ("the child inherited the launcher's input:\n" <> output) (stdinEofMarker `isInfixOf` output)

launchUsesItsOwnContext :: TestTree
launchUsesItsOwnContext =
    testCase "the child reports only the supplied environment, working directory, and arguments" $
        withSystemTempDirectory "hostbootstrap-detached-context" $ \tmp -> do
            root <- canonicalizePath tmp
            exe <- probeExecutable
            environment <- getEnvironment
            work <- either assertFailure pure (mkDetachedWorkingDirectory root)
            sink <- either assertFailure pure (mkDetachedOutputSink (root </> "child.out"))
            let supplied =
                    ("HOSTBOOTSTRAP_DETACHED_SENTINEL", "present")
                        : filter (\(name, _) -> name `elem` ["SystemRoot", "SYSTEMROOT", "WINDIR"]) environment
                arguments = [childProbeFlag, "context", "an argument with spaces", ""]
                launch = detachedLaunch exe arguments supplied work sink
                restoreOmitted Nothing = unsetEnv "HOSTBOOTSTRAP_DETACHED_OMITTED"
                restoreOmitted (Just value) = setEnv "HOSTBOOTSTRAP_DETACHED_OMITTED" value
            bracket (lookupEnv "HOSTBOOTSTRAP_DETACHED_OMITTED") restoreOmitted $ \_ -> do
                setEnv "HOSTBOOTSTRAP_DETACHED_OMITTED" "launcher-only"
                outcome <- withDetachedChild launch $ \child -> do
                    code <- awaitDetachedChild childWaitMicros child
                    output <- detachedChildOutput child
                    pure (code, Text.unpack output)
                case outcome of
                    Left err -> assertFailure (renderDetachedLaunchError err)
                    Right (code, output) -> do
                        code @?= Just ExitSuccess
                        forM_ ["directory=" <> show root, "sentinel=Just \"present\"", "omitted=Nothing", "arguments=" <> show arguments] $ \expected ->
                            assertBool ("missing child observation " <> expected <> ":\n" <> output) (("detached-probe: " <> expected) `isInfixOf` output)

boundedChildWait :: TestTree
boundedChildWait =
    testCase "a lingering child's 200ms wait is bounded under the suite runtime" $
        withLingerLaunch $ \launch _ _ -> do
            outcome <- withDetachedChild launch $ \child -> do
                started <- liftDetachedIO getMonotonicTimeNSec
                code <- awaitDetachedChild 200000 child
                finished <- liftDetachedIO getMonotonicTimeNSec
                terminateDetachedChild child
                stopped <- awaitDetachedChild childWaitMicros child
                pure (code, (finished - started) `div` 1000, stopped)
            case outcome of
                Left err -> assertFailure (renderDetachedLaunchError err)
                Right (code, elapsed, stopped) -> do
                    code @?= Nothing
                    assertBool ("200ms wait took " <> show elapsed <> "us") (elapsed < 500000)
                    assertBool "the child could not be reaped after timeout cleanup" (isJust stopped)

terminationIsObserved :: TestTree
terminationIsObserved =
    testCase "terminating a lingering child is observed by the bounded wait" $
        withLingerLaunch $ \launch _ _ -> do
            outcome <- withDetachedChild launch $ \child -> do
                terminateDetachedChild child
                awaitDetachedChild childWaitMicros child
            case outcome of
                Left err -> assertFailure (renderDetachedLaunchError err)
                Right code -> assertBool "terminated child did not report an exit" (isJust code)

{- | The bracket owns the launch, not the child. This is proved from outside the
bracket: the child keeps appending after the bracket returns, and stops only
when it is asked to.
-}
childOutlivesTheBracket :: TestTree
childOutlivesTheBracket =
    testCase "the bracket releases only the launcher's own handles" $
        withLingerLaunch $ \launch sinkPath shutdownPath -> do
            outcome <- withDetachedChild launch detachedChildPid
            case outcome of
                Left err -> assertFailure ("launch failed: " ++ renderDetachedLaunchError err)
                Right pid -> do
                    assertBool "the launch reported no process id" (isJust pid)
                    before <- ByteString.readFile sinkPath
                    grew <- awaitGrowth sinkPath (ByteString.length before) 100
                    assertBool
                        "the child stopped writing when the launch bracket returned"
                        grew
                    ticked <- awaitContent sinkPath tickMarker 100
                    assertBool "the child never reported a tick" ticked
                    writeFile shutdownPath "stop\n"
                    stopped <- awaitContent sinkPath stoppedMarker 200
                    assertBool "the child never observed its shutdown request" stopped

totalAcquireAndSpawn :: TestTree
totalAcquireAndSpawn =
    testGroup
        "acquire-and-spawn is total"
        [ testCase "a missing executable returns a typed failure and no child" $
            withSystemTempDirectory "hostbootstrap-detached" $ \tmp -> do
                root <- makeAbsolute tmp
                exe <- requireAbsExe (root </> "definitely-not-a-binary")
                launch <- probeLaunchWith exe [] root (root </> "child.out")
                outcome <- withDetachedChild launch (const (pure ()))
                case outcome of
                    Right () -> assertFailure "a missing executable produced a child"
                    Left err@(DetachedSpawnFailed reported _) -> do
                        assertEqual "the failure named the wrong executable" (absExePath exe) reported
                        assertBool
                            "the failure did not render"
                            (not (null (renderDetachedLaunchError err)))
                    Left other ->
                        assertFailure
                            ("expected a spawn failure, got: " ++ renderDetachedLaunchError other)
        , testCase "an unusable output sink returns a typed failure and no child" $
            withSystemTempDirectory "hostbootstrap-detached" $ \tmp -> do
                root <- makeAbsolute tmp
                -- A regular file where the sink's parent directory would go, so
                -- the sink cannot be created for a reason the launch owns.
                writeFile (root </> "occupied") "not a directory\n"
                exe <- probeExecutable
                let sinkPath = root </> "occupied" </> "child.out"
                launch <- probeLaunchWith exe ["stdio"] root sinkPath
                outcome <- withDetachedChild launch (const (pure ()))
                case outcome of
                    Right () -> assertFailure "an unusable sink produced a child"
                    Left (DetachedOutputSinkUnavailable reported _) ->
                        assertEqual "the failure named the wrong sink" sinkPath reported
                    Left other ->
                        assertFailure
                            ("expected a sink failure, got: " ++ renderDetachedLaunchError other)
        , testCase "every launch failure renders" $
            assertBool
                "a launch failure rendered empty"
                ( all
                    (not . null . renderDetachedLaunchError)
                    [ DetachedOutputSinkUnavailable "/sink" "why"
                    , DetachedNullDeviceUnavailable "/dev/null" "why"
                    , DetachedSpawnFailed "/exe" "why"
                    ]
                )
        ]

{- | The existing ownership-preserving abort paths run inside the body and rely
on their exception reaching the caller unchanged.
-}
bodyExceptionsPropagate :: TestTree
bodyExceptionsPropagate =
    testCase "a body exception propagates unchanged" $
        withProbeLaunch ["stdio"] $ \launch _ -> do
            outcome <-
                try (withDetachedChild launch (const (liftDetachedIO (ioError (userError "abort from the body"))))) ::
                    IO (Either IOException (Either DetachedLaunchError ()))
            case outcome of
                Left err ->
                    assertBool
                        ("the body's exception was rewritten: " ++ show err)
                        ("abort from the body" `isInfixOf` show err)
                Right (Left err) ->
                    assertFailure
                        ("the body never ran; the launch failed: " ++ renderDetachedLaunchError err)
                Right (Right ()) -> assertFailure "the bracket swallowed the body's exception"

bodyExceptionStopsChild :: TestTree
bodyExceptionStopsChild =
    testCase "a body exception hard-stops its lingering child and retains the original exception" $
        withLingerLaunchWith ["ignore-termination"] $ \launch sinkPath _ -> do
            outcome <-
                try
                    ( withDetachedChild launch $ \_ -> do
                        ticking <- liftDetachedIO (awaitContent sinkPath tickMarker 100)
                        liftDetachedIO (assertBool "the child did not start before the body failed" ticking)
                        liftDetachedIO (ioError (userError "abort a live child"))
                    ) ::
                    IO (Either IOException (Either DetachedLaunchError ()))
            case outcome of
                Left err -> assertBool ("body exception changed: " <> show err) ("abort a live child" `isInfixOf` show err)
                Right other -> assertFailure ("expected the body exception, got " <> show other)
            before <- ByteString.readFile sinkPath
            threadDelay 300000
            after <- ByteString.readFile sinkPath
            assertEqual "the child kept writing after exceptional cleanup returned" before after

{- | The drift guard. @NoStream@ is the disposition that /closes/ the
descriptor, which is what wedged the host accelerator daemon. Only the sealed
boundary may name it, and it names it in prose to say why it is wrong.

The scan is textual on purpose: a production module that so much as spells the
constructor has either reassembled a detached launch outside the boundary or is
documenting one, and both are drift worth reporting. Keeping a sealed surface
sealed is an obligation, not a property the type system maintains on its own.
-}
noProductionModuleClosesADescriptor :: TestTree
noProductionModuleClosesADescriptor =
    testCase "no production module outside the boundary names the descriptor-closing disposition" $ do
        cwd <- getCurrentDirectory
        root <-
            findRepoRoot cwd
                >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
        sources <- fmap concat . forM productionSourceRoots $ \relative -> do
            let directory = root </> relative
            present <- doesDirectoryExist directory
            assertBool ("production source root is absent: " <> relative) present
            paths <- SourceGuard.listHaskellSources directory
            assertBool ("production source root contains no Haskell modules: " <> relative) (not (null paths))
            pure paths
        offenders <-
            filterM
                (fmap (isInfixOf "NoStream") . readFile)
                (filter (not . admitted root) sources)
        assertEqual
            "a production module outside HostBootstrap.Detached names NoStream"
            []
            (sort (map (SourceGuard.repoRelativePath root) offenders))
  where
    admitted root path =
        SourceGuard.repoRelativePath root path
            `elem` [ "core/hostbootstrap-core/src/HostBootstrap/Detached.hs"
                   , "core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs"
                   ]

productionSourceRoots :: [FilePath]
productionSourceRoots =
    [ "core" </> "hostbootstrap-core" </> "src"
    , "core" </> "hostbootstrap-core" </> "internal"
    , "core" </> "hostbootstrap-core" </> "app"
    , "demo" </> "src"
    , "demo" </> "app"
    ]

-- Wiring -------------------------------------------------------------------

childWaitMicros :: Int
childWaitMicros = 60 * 1000000

absoluteish :: FilePath -> FilePath
absoluteish leaf
    | os == "mingw32" = "C:\\hostbootstrap-detached\\" ++ leaf
    | otherwise = "/hostbootstrap-detached/" ++ leaf

relativeish :: FilePath -> FilePath
relativeish leaf = "hostbootstrap-detached" </> leaf

probeExecutable :: IO AbsExe
probeExecutable = getExecutablePath >>= makeAbsolute >>= requireAbsExe

requireAbsExe :: FilePath -> IO AbsExe
requireAbsExe path =
    either (assertFailure . ("not an absolute executable: " ++)) pure (mkAbsExe path)

probeLaunchWith :: AbsExe -> [String] -> FilePath -> FilePath -> IO DetachedLaunch
probeLaunchWith exe modeArgs workingDirectory sinkPath = do
    environment <- getEnvironment
    workDir <-
        either
            (assertFailure . ("bad working directory: " ++))
            pure
            (mkDetachedWorkingDirectory workingDirectory)
    sink <- either (assertFailure . ("bad output sink: " ++)) pure (mkDetachedOutputSink sinkPath)
    let args = if null modeArgs then [] else childProbeFlag : modeArgs
    pure (detachedLaunch exe args environment workDir sink)

withProbeLaunch :: [String] -> (DetachedLaunch -> FilePath -> IO ()) -> IO ()
withProbeLaunch modeArgs body =
    withSystemTempDirectory "hostbootstrap-detached" $ \tmp -> do
        root <- makeAbsolute tmp
        exe <- probeExecutable
        let sinkPath = root </> "child.out"
        launch <- probeLaunchWith exe modeArgs root sinkPath
        assertBool
            "the rendered command line dropped the executable"
            (absExePath exe `isInfixOf` detachedLaunchCommandLine launch)
        body launch sinkPath

withLingerLaunch :: (DetachedLaunch -> FilePath -> FilePath -> IO ()) -> IO ()
withLingerLaunch = withLingerLaunchWith []

withLingerLaunchWith :: [String] -> (DetachedLaunch -> FilePath -> FilePath -> IO ()) -> IO ()
withLingerLaunchWith options body =
    withSystemTempDirectory "hostbootstrap-detached" $ \tmp -> do
        root <- makeAbsolute tmp
        exe <- probeExecutable
        let sinkPath = root </> "child.out"
            shutdownPath = root </> "child.shutdown"
        launch <- probeLaunchWith exe (["linger", shutdownPath] <> options) root sinkPath
        body launch sinkPath shutdownPath

awaitGrowth :: FilePath -> Int -> Int -> IO Bool
awaitGrowth _ _ 0 = pure False
awaitGrowth path baseline attempts = do
    threadDelay 100000
    current <- ByteString.readFile path
    if ByteString.length current > baseline
        then pure True
        else awaitGrowth path baseline (attempts - 1)

awaitContent :: FilePath -> String -> Int -> IO Bool
awaitContent _ _ 0 = pure False
awaitContent path needle attempts = do
    body <- ByteString.readFile path
    if needle `isInfixOf` map (toEnum . fromIntegral) (ByteString.unpack body)
        then pure True
        else do
            threadDelay 100000
            awaitContent path needle (attempts - 1)
