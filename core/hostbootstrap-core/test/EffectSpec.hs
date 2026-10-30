{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Guards and real-process cases for the one-effect-vocabulary boundary.

§ KK admits one shell quoter, one process runner, and one rendering of "cross
into this frame". A second copy of any of them is invisible to every gate that
exists, because each copy passes its own tests: two quoters agree on the inputs
both were written for and disagree on the first character only one of them ever
met, and nothing compares them.

The guards here are lexical. A renamed copy is outside their reach. They assert that the
quoter has exactly one definition site in the package and that the spellings it
replaced name nothing, across the library, its private sublibraries, and the
consumer that composes commands against it.
-}
module EffectSpec (tests, runEffectProbe) where

import ConditionalCase (conditionalCase)
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), IOException, SomeException, bracket, fromException, try)
import Control.Monad (forM_)
import qualified Data.ByteString as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, isSuffixOf, sort, tails)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import GHC.Clock (getMonotonicTimeNSec)
import GHC.IO.Encoding (getLocaleEncoding, mkTextEncoding, setLocaleEncoding)
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Effect (
    BoundedRun (..),
    CapturedRun (..),
    EffectEnvironment (..),
    EffectFailure (..),
    EffectFailurePolicy (..),
    EffectFrame (CrossedInto, OuterHost),
    EffectTarget (SelfTarget, ToolTarget),
    FrameCrossing (CrossContainer, CrossLimaVM, CrossWsl2VM),
    HostCommand (commandFrame, commandTarget),
    HostEffect (..),
    PathGrammar (HostPathGrammar, PosixGuestGrammar),
    RunBounds (..),
    RunNamespace (..),
    framePathGrammar,
    hostCommand,
    interpretHostEffects,
    powerShellQuoteArg,
    resolveLaunch,
    runBoundedGrouped,
    runBoundedGroupedWithInput,
    runCaptured,
    workingDirectoryEntryArguments,
 )
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (AbsExe, HostTool (Curl, Docker, Lima, Wsl), hostToolProcessArguments, mkAbsExe)
import HostBootstrap.Lift (
    ContainerLift (..),
    ContainerPlacement (ProviderGuestContainer),
    InVMSelfPath (InVMSelfPath),
    LiftLeaf (RawCmd, SelfSub),
    LimaVM (LimaVM),
    LocalSelfPath (LocalSelfPath),
    foldLeafCommand,
    inContainer,
    inLimaVM,
    liftContextFrame,
    localContext,
    mkSelfRef,
    selfCommand,
 )
import HostBootstrap.Substrate (Arch (Amd64), Substrate (Substrate), SubstrateName (LinuxCpu))
import HostBootstrap.Lift.Context (emptyVMStack, vmContext)
import HostBootstrap.Ownership.Posix (posixOwnershipSupported)
import PlatformPath (hostFixturePath)
import qualified SourceGuard
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getCurrentDirectory, listDirectory)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), hFlush, hPutStr, stderr, stdin, stdout, withBinaryFile)
import System.IO.Error (ioeGetErrorString)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Read (readMaybe)
#if !defined(mingw32_HOST_OS)
import Control.Monad (forever)
import System.IO (hClose)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Process (forkProcess, getProcessID)
import System.Posix.Signals (Handler (Ignore), installHandler, nullSignal, sigTERM, signalProcess)
#endif

tests :: TestTree
tests =
    testGroup
        "EffectSpec"
        [ testCase "the shell quoter has exactly one definition site" $ do
            sources <- commandComposingSources
            let definitions =
                    [ (path, count)
                    | (path, source) <- sources
                    , let count = quoterDefinitions source
                    , count > 0
                    ]
            definitions @?= [("core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/Quote.hs", 2)]
        , testCase "a where binding cannot hide a second shell quoter" $
            quoterDefinitions "f = value\n  where shellQuoteArg x = x\n" @?= 1
        , testGroup "PowerShell single quotes"
            [ testCase ("U+" ++ show (fromEnum quote)) $
                powerShellQuoteArg ['O', quote, 'N'] @?= ['\'', 'O', quote, quote, 'N', '\'']
            | quote <- ['\'', '\x2018', '\x2019', '\x201a', '\x201b']
            ]
        , testCase "an empty PowerShell argument stays present" $ powerShellQuoteArg "" @?= "''"
        , testCase "the PowerShell quoter has exactly one definition site" $ do
            sources <- commandComposingSources
            let definitions =
                    [ (path, count)
                    | (path, source) <- sources
                    , let count = SourceGuard.countHaskellTokenSequence ["powerShellQuoteArg", "::"] source
                    , count > 0
                    ]
            definitions @?= [("core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/Quote.hs", 1)]
        , testCase "no module carries a quoter of its own" $ do
            sources <- commandComposingSources
            forM_ retiredQuoterSpellings $ \spelling ->
                forM_ sources $ \(path, source) -> do
                    let observed = SourceGuard.countHaskellIdentifier spelling source
                    if observed == 0
                        then pure ()
                        else
                            assertFailure
                                ( path
                                    ++ " names "
                                    ++ spelling
                                    ++ " "
                                    ++ show observed
                                    ++ " times; § KK admits one quoter per grammar, so"
                                    ++ " use HostBootstrap.Effect.Quote"
                                )
        , testCase "the captured-run primitive has exactly one definition site" $ do
            sources <- commandComposingSources
            let sites =
                    [ path
                    | (path, source) <- sources
                    , SourceGuard.countHaskellTokenSequence ["runCaptured", "::"] source > 0
                    ]
            sites @?= [runnerPath]
        , testCase "the bounded group-leading runner has exactly one definition site" $ do
            sources <- commandComposingSources
            let sites =
                    [ path
                    | (path, source) <- sources
                    , SourceGuard.countHaskellTokenSequence ["runBoundedGrouped", "::"] source > 0
                    ]
            sites @?= [runnerPath]
        , testCase "process-group teardown belongs to the declared group owners" $ do
            sources <- commandComposingSources
            let sites =
                    [ path
                    | (path, source) <- sources
                    , SourceGuard.countHaskellIdentifier "signalProcessGroup" source > 0
                    ]
            sort sites @?= sort groupOwners
        , testCase "only the declared launch boundaries assemble a child process" $ do
            sources <- commandComposingSources
            let sites =
                    [ path
                    | (path, source) <- sources
                    , hasLaunch source
                    ]
            sort sites @?= sort launchBoundaries
        , testCase "launch detection includes callProcess" $ assertBool "a direct call is a launch" (hasLaunch "callProcess executable arguments")
        , testCase "WSL launches directly with every vector element preserved" $ do
            let path = hostFixturePath "tools/wsl.exe"
                arguments = ["-d", "demo", "--", "", "a \"b\"", "O\x2019Neil"]
                absolute = either error id (mkAbsExe path)
            resolveLaunch (resolvedConfig [(Wsl, path)]) (hostCommand Wsl arguments)
                @?= Right (path, hostToolProcessArguments Wsl absolute arguments)
            resolveLaunch (resolvedConfig []) (hostCommand Wsl arguments) @?= Left "wsl not found on this host"
        , testCase "the interpreter contains no WSL interpreter-text route" $ do
            root <- repoRoot
            source <- readFile (root </> interpreterPath)
            forM_ ["powerShellQuoteArg", "HostBootstrap.Effect.Quote", "powershell"] $ \spelling ->
                assertBool ("unexpected interpreter dependency: " ++ spelling) (not (spelling `isInfixOf` source))
        , testCase "the effect interpreter has exactly one definition site" $ do
            sources <- commandComposingSources
            let sites =
                    [ path
                    | (path, source) <- sources
                    , SourceGuard.countHaskellTokenSequence ["interpretHostEffects", "::"] source > 0
                    ]
            sites @?= [interpreterPath]
        , testCase "the described-command interpreter has exactly one definition site" $ do
            sources <- commandComposingSources
            let sites =
                    [ path
                    | (path, source) <- sources
                    , SourceGuard.countHaskellTokenSequence ["interpretHostCommand", "::"] source > 0
                    ]
            sites @?= [interpreterPath]
        , testCase "no consumer carries an effect interpreter of its own" $ do
            sources <- commandComposingSources
            forM_ retiredInterpreterSpellings $ \spelling ->
                forM_ sources $ \(path, source) -> do
                    let observed = SourceGuard.countHaskellIdentifier spelling source
                    if observed == 0
                        then pure ()
                        else
                            assertFailure
                                ( path
                                    ++ " names "
                                    ++ spelling
                                    ++ " "
                                    ++ show observed
                                    ++ " times; § KK admits one interpreter, beside the"
                                    ++ " vocabulary it runs"
                                )
        , testCase "the tree carries no script" $ do
            -- rationale.md: repository scripts split the execution model. A
            -- filename without an extension must not evade this boundary.
            withSystemTempDirectory "hostbootstrap-script-guard" $ \fixture -> do
                writeFile (fixture </> ".gitignore") ""
                writeFile (fixture </> "extension.sh") "true\n"
                writeFile (fixture </> "no-extension") "#!/bin/sh\ntrue\n"
                trackedScriptFiles fixture >>= (@?= ["extension.sh", "no-extension"])
            root <- repoRoot
            tracked <- trackedScriptFiles root
            tracked @?= []
        , testCase "a described command resolves to the executable and argv the host launches" $ do
            let dockerPath = hostFixturePath "/usr/bin/docker"
                selfPath = hostFixturePath "/opt/hb/bin/hostbootstrap"
                cfg = resolvedConfig [(Docker, dockerPath)]
            resolveLaunch cfg (hostCommand Docker ["ps", "--all"])
                @?= Right (dockerPath, ["ps", "--all"])
            resolveLaunch cfg (selfCommand selfPath ["project", "up"])
                @?= Right (selfPath, ["project", "up"])
        , testCase "an unresolved tool refuses by name before any child exists" $
            resolveLaunch (resolvedConfig []) (hostCommand Docker ["ps"])
                @?= Left "docker not found on this host"
        , testCase "a command's frame decides its paths' grammar" $ do
            framePathGrammar OuterHost @?= HostPathGrammar
            framePathGrammar (CrossedInto (CrossLimaVM "demo-vm") []) @?= PosixGuestGrammar
            framePathGrammar (CrossedInto (CrossWsl2VM "Ubuntu-24.04") [CrossContainer "img"])
                @?= PosixGuestGrammar
        , testCase "the lift fold reports the frame it crossed into, outermost first" $ do
            liftContextFrame localContext @?= OuterHost
            liftContextFrame (inContainer container (inLimaVM (LimaVM "demo-vm") emptyVMStack))
                @?= CrossedInto (CrossLimaVM "demo-vm") [CrossContainer "demo:latest"]
        , testCase "a crossed command names a tool, and a local one names the binary" $ do
            executable <- getExecutablePath
            let self = mkSelfRef (LocalSelfPath executable) (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
                crossed = foldLeafCommand (vmContext (inLimaVM (LimaVM "demo-vm") emptyVMStack)) (RawCmd "true" [])
                local = foldLeafCommand localContext (SelfSub self [])
            fmap commandTarget crossed @?= Right (ToolTarget Lima)
            fmap commandFrame crossed @?= Right (CrossedInto (CrossLimaVM "demo-vm") [])
            fmap commandTarget local @?= Right (SelfTarget executable)
            fmap commandFrame local @?= Right OuterHost
        , testCase "a local raw command names a registered tool and refuses an absolute executable" $ do
            executable <- getExecutablePath
            let registered = foldLeafCommand localContext (RawCmd "curl" ["--version"])
            fmap commandTarget registered @?= Right (ToolTarget Curl)
            fmap commandFrame registered @?= Right OuterHost
            foldLeafCommand localContext (RawCmd executable [])
                @?= Left ("local executable is not a registered host tool: " <> executable)
        , testGroup "bounded POSIX behavior" boundedPosixCases
        , testGroup "captured and bounded behavior" portableProcessCases
        , testGroup "effect failure policies" effectPolicyCases
        , testCase "script ignores apply only to directories at their declared scope" scriptIgnoreCase
        ]
  where
    container =
        ContainerLift
            { clImage = "demo:latest"
            , clPlacement = ProviderGuestContainer
            , clMounts = []
            , clExtraArgs = []
            , clRemoveAfter = True
            , clConfigDelivery = Nothing
            }

-- | The one process runner (§ KK).
runnerPath :: FilePath
runnerPath = "core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/Run.hs"

{- | Every module allowed to assemble a child process, and why each is its own
boundary rather than a copy of another.

  * the one runner owns the captured and the bounded group-leading shapes;
  * "HostBootstrap.Detached" owns a child that outlives its launcher (§ HH),
    whose disposition is fixed rather than parameterised;
  * the handoff process route owns a child holding an inherited descriptor pair,
    which is the one shape neither of the others can express;
  * the demo's accelerator daemon owns a long-lived worker session whose two
    pipes stay open across many requests, which is a session rather than a run.

A path leaving this list is a new spawn site deciding its own descriptor and
stdio disposition, which is exactly what § KK admits one runner to prevent.
-}
launchBoundaries :: [FilePath]
launchBoundaries =
    [ runnerPath
    , colimaRunnerPath
    , "core/hostbootstrap-core/src/HostBootstrap/Detached.hs"
    , handoffProcessPath
    , handoffTransactionPath
    , "demo/src/HostBootstrapDemo/Accelerator/Daemon.hs"
    ]

{- | The bracketed POSIX owner of one child, its group, and its descriptors for
exactly one authenticated edge. It signals a group for the same reason the
runner does — a leader's descendants must not survive it — and it is a separate
boundary because its child holds an inherited descriptor pair the runner's two
dispositions cannot express.
-}
handoffProcessPath :: FilePath
handoffProcessPath = "core/hostbootstrap-core/src/HostBootstrap/Handoff/Process.hs"

{- | The bracketed owner of one child, its group, and its descriptors for
exactly one frame crossing. It is a separate boundary from the edge owner above
because what it holds is one transaction rather than an authenticated
admission, and it is compiled on every host with only its signal call sites
conditionalized, so no host family loses the far side of a crossing (§ JJ).
-}
handoffTransactionPath :: FilePath
handoffTransactionPath = "core/hostbootstrap-core/src/HostBootstrap/Handoff/Transaction.hs"

{- | The one module the handoff transports share for ending a child group.

Both of them held byte-identical copies of the escalation and its three
timeouts. Sharing it means the group teardown they perform is the same
teardown by construction rather than by two authors agreeing.
-}
childGroupPath :: FilePath
childGroupPath = "core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/ChildGroup.hs"

{- | Every module allowed to signal a process group. Each listed boundary owns
the group it terminates; another site would be a teardown nobody compared with
these.

The handoff transports are no longer listed: they call the shared boundary and
signal nothing themselves, which is what removed the second copy this guard used
to have to compare.
-}
groupOwners :: [FilePath]
groupOwners = [runnerPath, colimaRunnerPath, childGroupPath]

-- | The shipped Colima command transaction owns the group it kills on parent death.
colimaRunnerPath :: FilePath
colimaRunnerPath = "core/hostbootstrap-core/internal/colima-backend/HostBootstrap/Ensure/Colima/Backend/Runner.hs"

-- | The one interpreter for the closed effect vocabulary (§ KK).
interpreterPath :: FilePath
interpreterPath = "core/hostbootstrap-core/src/HostBootstrap/Effect/Interpreter.hs"

-- | The extensions § KK names as scripts.
scriptExtensions :: [String]
scriptExtensions = [".sh", ".ps1", ".bat", ".cmd", ".psm1"]

{- | Every script file the tree carries.

The directories it does not descend into come from the repository's own
@.gitignore@ rather than from a list here, so a new build-output directory does
not silently become a place a script can hide, and a hand-maintained exclusion
list cannot drift away from what the repository actually tracks.
-}
trackedScriptFiles :: FilePath -> IO [FilePath]
trackedScriptFiles root = do
    ignored <- ignoredDirectoryPatterns root
    let collect directory = do
            entries <- listDirectory directory
            fmap concat . traverse (visit directory) $ sort entries

        visit directory entry = do
            let path = directory </> entry
                relative = SourceGuard.repoRelativePath root path
            nested <- doesDirectoryExist path
            if nested
                then if any (ignoredDirectory relative entry) ignored then pure [] else collect path
                else do
                    header <- withBinaryFile path ReadMode (`ByteString.hGet` 2)
                    pure
                        [ relative
                        | any (`isSuffixOf` entry) scriptExtensions || header == ByteString.pack [35, 33]
                        ]
    collect root

{- | Directory-only exclusions, retaining repository-relative anchored paths.
-}
ignoredDirectoryPatterns :: FilePath -> IO [String]
ignoredDirectoryPatterns root = do
    patterns <- lines <$> readFile (root </> ".gitignore")
    pure (".git" : [init pattern | pattern <- map trim patterns, isDirectoryPattern pattern])
  where
    isDirectoryPattern pattern = case pattern of
        ('#' : _) -> False
        (_ : _) -> last pattern == '/'
        [] -> False

    trim = dropWhile (== ' ') . reverse . dropWhile (`elem` (" \r\t" :: String)) . reverse

ignoredDirectory :: FilePath -> FilePath -> String -> Bool
ignoredDirectory relative name pattern
    | '/' `elem` pattern = dropWhile (== '/') pattern == relative
    | otherwise = pattern == name

{- | The spellings a consumer-resident effect interpreter is written under.

Named rather than described, so the guard fails on the name rather than on a
shape a reader must recognise.
-}
retiredInterpreterSpellings :: [String]
retiredInterpreterSpellings = ["runDirectHostAction"]

{- | A host configuration with exactly these tools resolved, for the pure
resolution cases.
-}
resolvedConfig :: [(HostTool, FilePath)] -> HostConfig
resolvedConfig entries =
    HostConfig
        (Substrate LinuxCpu Amd64)
        (Map.fromList [(tool, absolute path) | (tool, path) <- entries])
  where
    absolute :: FilePath -> AbsExe
    absolute path = either error id (mkAbsExe path)

{- | The spellings a per-module quoter is written under.

Named here rather than described, so the guard fails on the name rather than on
a shape a reader must recognise.
-}
retiredQuoterSpellings :: [String]
retiredQuoterSpellings = ["quoteShell", "psQuote", "shellQuote"]

{- | Every Haskell source that may compose a host command.

The library, the private sublibraries beneath it, and the consumer that builds
commands against it are one boundary for this purpose: a quoter copied into the
consumer is the same defect as one copied within the library, because both
answer the same question in two places.
-}
commandComposingSources :: IO [(FilePath, String)]
commandComposingSources = do
    root <- repoRoot
    sources <- fmap concat . traverse (SourceGuard.readHaskellSources . (root </>)) $
        [ "core" </> "hostbootstrap-core" </> "src"
        , "core" </> "hostbootstrap-core" </> "internal"
        , "demo" </> "src"
        ]
    pure [(SourceGuard.repoRelativePath root path, source) | (path, source) <- sources]

quoterDefinitions :: String -> Int
quoterDefinitions source =
    SourceGuard.countHaskellTokenSequence ["shellQuoteArg", "::"] source
        + length
            [ ()
            | line <- lines source
            , let tokens = SourceGuard.haskellTokens line
            , candidate <- tokens : [rest | "where" : rest <- tails tokens]
            , "shellQuoteArg" : rest <- [candidate]
            , "=" `elem` takeWhile (/= "::") rest
            ]

hasLaunch :: String -> Bool
hasLaunch source =
    any
        (\name -> SourceGuard.countHaskellIdentifier name source > 0)
        [ "createProcess", "withCreateProcess", "spawnProcess", "spawnCommand", "callProcess"
        , "callCommand", "readProcess", "readProcessWithExitCode", "readCreateProcess"
        , "readCreateProcessWithExitCode", "rawSystem", "system", "executeFile", "forkProcess", "startProcess"
        ]

repoRoot :: IO FilePath
repoRoot = do
    cwd <- getCurrentDirectory
    findRepoRoot cwd >>= maybe (assertFailure "could not locate the repository root") pure

-- | Re-enter this executable without a fake tool or an interpreter program.
runEffectProbe :: [String] -> IO ()
runEffectProbe arguments = case arguments of
    ["exit", value, out, err] -> do
        ByteString.hPut stdout (TextEncoding.encodeUtf8 (Text.pack out))
        ByteString.hPut stderr (TextEncoding.encodeUtf8 (Text.pack err))
        case readMaybe value of
            Just 0 -> exitWith ExitSuccess
            Just code -> exitWith (ExitFailure code)
            Nothing -> ioError (userError "invalid effect probe exit code")
    ["invalid-utf8"] -> do
        ByteString.hPut stdout (ByteString.pack [129, 141, 143, 144, 157])
        ByteString.hPut stderr (ByteString.pack [255])
    ["flood"] -> ByteString.hPut stdout (ByteString.replicate (256 * 1024) 120)
    ["exit-unread"] -> exitWith (ExitFailure 7)
    ["duplex"] -> do
        ByteString.hPut stdout (ByteString.replicate (128 * 1024) 120)
        hFlush stdout
        incoming <- ByteString.hGet stdin (128 * 1024)
        hPutStr stderr (show (ByteString.length incoming))
    ["cwd"] -> getCurrentDirectory >>= hPutStr stdout
    "arguments" : values -> hPutStr stdout (show values)
    [mode, path] -> runPosixEffectProbe mode path
    _ -> ioError (userError ("unknown effect probe: " ++ show arguments))

runPosixEffectProbe :: String -> FilePath -> IO ()
#if defined(mingw32_HOST_OS)
runPosixEffectProbe _ _ = ioError (userError "POSIX process probes are unavailable on Windows")
#else
runPosixEffectProbe mode path = do
    process <- getProcessID
    case mode of
        "sleep" -> writeFile path (show process) >> linger
        "close-then-sleep" -> do
            writeFile path (show process)
            hClose stdout
            hClose stderr
            linger
        "ignore-term-and-fork" -> do
            _ <- installHandler sigTERM Ignore Nothing
            child <- forkProcess linger
            writeFile path (show process ++ " " ++ show child)
            linger
        _ -> ioError (userError ("unknown POSIX effect probe: " ++ mode))
  where
    linger = forever (threadDelay 1000000)
#endif

probeArguments :: [String] -> [String]
probeArguments = ("--hostbootstrap-effect-probe" :)

smallBounds :: RunBounds
smallBounds = RunBounds 500000 (64 * 1024) 100000

withRunFixture :: (RunNamespace -> FilePath -> FilePath -> IO ()) -> IO ()
withRunFixture use = withSystemTempDirectory "hostbootstrap-effect" $ \root -> do
    executable <- getExecutablePath
    environment <- getEnvironment
    use (RunNamespace root environment) executable (root </> "processes")

boundedPosixCases :: [TestTree]
boundedPosixCases =
    [ rowCase "the wall terminates the child and reaps its pid" $
        withRunFixture $ \namespace executable pids -> do
            runBoundedGrouped smallBounds namespace executable (probeArguments ["sleep", pids]) >>= (@?= BoundedTimedOut)
            assertPidsGone pids
    , rowCase "closing the streams does not grant a second wall budget" $
        withRunFixture $ \namespace executable pids -> do
            started <- getMonotonicTimeNSec
            runBoundedGrouped smallBounds{boundWallMicros = 1000000} namespace executable (probeArguments ["close-then-sleep", pids]) >>= (@?= BoundedTimedOut)
            ended <- getMonotonicTimeNSec
            assertBool "one wall plus grace and scheduling allowance" ((ended - started) `div` 1000 < 1700000)
            assertPidsGone pids
    , rowCase "escalation kills a SIGTERM-ignoring leader and grandchild" $
        withRunFixture $ \namespace executable pids -> do
            runBoundedGrouped smallBounds namespace executable (probeArguments ["ignore-term-and-fork", pids]) >>= (@?= BoundedTimedOut)
            assertPidsGone pids
    , rowCase "cancelling the launcher rethrows ThreadKilled and removes the child" $
        withRunFixture $ \namespace executable pids -> do
            completed <- newEmptyMVar
            launcher <- forkIO $ do
                result <- try (runBoundedGrouped smallBounds{boundWallMicros = 10000000} namespace executable (probeArguments ["sleep", pids])) :: IO (Either SomeException BoundedRun)
                putMVar completed result
            awaitPidFile pids
            killThread launcher
            result <- takeMVar completed
            case result of
                Left failure -> (fromException failure :: Maybe AsyncException) @?= Just ThreadKilled
                Right value -> assertFailure ("cancelled launcher completed: " ++ show value)
            assertPidsGone pids
    , cwdCase "the native cwd entry execs the unchanged target vector" $
        withRunFixture $ \namespace executable _ -> do
            outcome <- runCaptured executable (workingDirectoryEntryArguments ++ [runWorkingDirectory namespace, executable] ++ probeArguments ["cwd"]) ""
            case outcome of
                Right run -> do
                    capturedExit run @?= ExitSuccess
                    capturedStdout run @?= runWorkingDirectory namespace
                Left failure -> assertFailure (show failure)
            let values = ["", "a \"b\"", "O\x2019Neil"]
            roundTrip <- runCaptured executable (workingDirectoryEntryArguments ++ [runWorkingDirectory namespace, executable] ++ probeArguments ("arguments" : values)) ""
            roundTrip @?= Right (CapturedRun ExitSuccess (show values) "")
            refused <- runCaptured executable (workingDirectoryEntryArguments ++ [runWorkingDirectory namespace </> "missing-directory", executable] ++ probeArguments ["cwd"]) ""
            case refused of
                Right run -> do
                    capturedExit run @?= ExitFailure 126
                    capturedStdout run @?= ""
                    assertBool "native cwd entry reports its own refusal" ("hostbootstrap working-directory entry:" `isInfixOf` capturedStderr run)
                Left failure -> assertFailure (show failure)
    ]
  where
    rowCase name action = conditionalCase ["EffectSpec", "bounded POSIX behavior"] posixOwnershipSupported name action $ do
        outcome <- try (processAlive 0) :: IO (Either IOException Bool)
        case outcome of
            Left failure -> ioeGetErrorString failure @?= "POSIX liveness probing is unavailable on Windows"
            Right value -> assertFailure ("expected unavailable POSIX liveness instrumentation, got " ++ show value)
    cwdCase name action = conditionalCase ["EffectSpec", "bounded POSIX behavior"] posixOwnershipSupported name action $
        withRunFixture $ \namespace executable _ -> do
            outcome <- runCaptured executable (workingDirectoryEntryArguments ++ [runWorkingDirectory namespace, executable] ++ probeArguments ["cwd"]) ""
            case outcome of
                Right run -> do
                    capturedExit run @?= ExitFailure 126
                    capturedStdout run @?= ""
                    assertBool "the native cwd entry asserts its actual platform refusal" ("native cwd-and-exec is unavailable on Windows" `isInfixOf` capturedStderr run)
                Left failure -> assertFailure ("the entry did not run: " ++ show failure)

portableProcessCases :: [TestTree]
portableProcessCases =
    [ testCase "output beyond the per-stream ceiling is refused" $
        withRunFixture $ \namespace executable _ ->
            runBoundedGrouped smallBounds namespace executable (probeArguments ["flood"]) >>= (@?= BoundedOutputLimit)
    , testCase "a missing executable is a launch failure" $
        withRunFixture $ \namespace executable _ -> do
            outcome <- runBoundedGrouped smallBounds namespace (runWorkingDirectory namespace </> "missing-executable") []
            case outcome of
                BoundedFailed _ -> pure ()
                other -> assertFailure ("expected spawn failure, got " ++ show other)
            missingDirectory <- runBoundedGrouped smallBounds namespace{runWorkingDirectory = runWorkingDirectory namespace </> "missing-directory"} executable (probeArguments ["cwd"])
            case missingDirectory of
                BoundedFailed _ -> pure ()
                other -> assertFailure ("expected cwd launch failure, got " ++ show other)
    , testCase "an unread large request preserves the child's completed exit" $
        withRunFixture $ \namespace executable _ -> do
            outcome <- runBoundedGroupedWithInput smallBounds namespace executable (probeArguments ["exit-unread"]) (ByteString.replicate (256 * 1024) 120)
            outcome @?= BoundedCompleted (CapturedRun (ExitFailure 7) "" "")
    , testCase "readers start before a large request can block its writer" $
        withRunFixture $ \namespace executable _ -> do
            let bounds = smallBounds{boundWallMicros = 3000000, boundOutputBytes = 512 * 1024}
            outcome <- runBoundedGroupedWithInput bounds namespace executable (probeArguments ["duplex"]) (ByteString.replicate (128 * 1024) 120)
            case outcome of
                BoundedCompleted run -> do
                    capturedExit run @?= ExitSuccess
                    capturedStdout run @?= replicate (128 * 1024) 'x'
                    capturedStderr run @?= show (128 * 1024 :: Int)
                other -> assertFailure ("duplex pipes failed: " ++ show other)
    , testCase "captured bytes decode as UTF-8 while the process locale is ASCII" $
        withRunFixture $ \namespace executable _ ->
            bracket getLocaleEncoding setLocaleEncoding $ \_ -> do
                mkTextEncoding "ASCII" >>= setLocaleEncoding
                outcome <- runCaptured executable (probeArguments ["invalid-utf8"]) ""
                outcome @?= Right (CapturedRun ExitSuccess (replicate 5 '\xfffd') "\xfffd")
                bounded <- runBoundedGrouped smallBounds namespace executable (probeArguments ["invalid-utf8"])
                bounded @?= BoundedCompleted (CapturedRun ExitSuccess (replicate 5 '\xfffd') "\xfffd")
    ]

awaitPidFile :: FilePath -> IO ()
awaitPidFile path = go (200 :: Int)
  where
    go 0 = assertFailure ("the child never published its pid: " ++ path)
    go remaining = do
        exists <- doesFileExist path
        ready <- if exists then fmap (not . ByteString.null) (ByteString.readFile path) else pure False
        if ready then pure () else threadDelay 25000 >> go (remaining - 1)

assertPidsGone :: FilePath -> IO ()
assertPidsGone path = do
    values <- words <$> readFile path
    assertBool "the probe published at least one pid" (not (null values))
    processes <- traverse (maybe (assertFailure "invalid probe pid") pure . readMaybe) values
    forM_ processes (awaitGone (80 :: Int))
  where
    awaitGone remaining process = do
        alive <- processAlive process
        if not alive then pure () else
            if remaining == 0 then assertFailure ("process survived group teardown: " ++ show process)
            else threadDelay 25000 >> awaitGone (remaining - 1) process

processAlive :: Int -> IO Bool
#if defined(mingw32_HOST_OS)
processAlive _ = ioError (userError "POSIX liveness probing is unavailable on Windows")
#else
processAlive process = do
    observed <- try (signalProcess nullSignal (fromIntegral process)) :: IO (Either IOException ())
    case observed of
        Right () -> pure True
        Left failure | isDoesNotExistError failure -> pure False
        Left failure -> ioError failure
#endif

effectPolicyCases :: [TestTree]
effectPolicyCases =
    [ testCase "FailFast preserves the command failure and stops before remaining effects" $
        withPolicyFixture $ \environment events executable -> do
            let argv = probeArguments ["exit", "7", "out", "first diagnostic\nsecond"]
                effects = [ApplyGlobalWslWall ["wall"], RunHostCommand (selfCommand executable argv), ReleaseGlobalWslWall ["wall"]]
            outcome <- interpretHostEffects environment FailFast (resolvedConfig []) effects
            outcome @?= Left (EffectCommandFailed executable argv 7 "out" "first diagnostic\nsecond")
            events >>= (@?= ["acquire wall"])
    , testCase "BestEffort announces once and releases after a command refusal" $
        withPolicyFixture $ \environment events executable -> do
            let effects = [ApplyGlobalWslWall ["wall"], RunHostCommand (selfCommand executable (probeArguments ["exit", "7", "", "first diagnostic\r\nsecond"])), RunHostCommand (selfCommand executable (probeArguments ["exit", "0", "tail", ""])), ReleaseGlobalWslWall ["wall"]]
            interpretHostEffects environment (BestEffort "teardown") (resolvedConfig []) effects >>= (@?= Right ())
            events >>= (@?= ["acquire wall", "echo teardown\n", "echo   (skipped: first diagnostic)\n", "echo tail", "release wall"])
    , testCase "an unavailable described tool stops before remaining effects" $
        withPolicyFixture $ \environment events _ -> do
            interpretHostEffects environment FailFast (resolvedConfig []) [RunHostCommand (hostCommand Docker ["ps"]), ReleaseGlobalWslWall ["wall"]]
                >>= (@?= Left (EffectCommandUnavailable "docker" "docker not found on this host"))
            events >>= (@?= [])
    , testGroup "BestEffort skip reasons"
        [ testCase name $
            withPolicyFixture $ \environment events executable -> do
                interpretHostEffects environment (BestEffort "teardown") (resolvedConfig []) [RunHostCommand (selfCommand executable (probeArguments ["exit", "7", out, err]))] >>= (@?= Right ())
                events >>= (@?= ["echo teardown\n", "echo   (skipped: " ++ reason ++ ")\n"])
        | (name, out, err, reason) <- [("stdout fallback", "output first\r\nsecond", "", "output first"), ("exit fallback", "", "", "exit 7")]
        ]
    ]

withPolicyFixture :: (EffectEnvironment -> IO [String] -> FilePath -> IO ()) -> IO ()
withPolicyFixture use = do
    journal <- newIORef []
    executable <- getExecutablePath
    let record event = modifyIORef' journal (++ [event])
        environment = EffectEnvironment (record . ("acquire " ++) . unwords) (record . ("release " ++) . unwords) (record . ("echo " ++))
    use environment (readIORef journal) executable

scriptIgnoreCase :: IO ()
scriptIgnoreCase = withSystemTempDirectory "hostbootstrap-ignore-guard" $ \root -> do
    writeFile (root </> ".gitignore") "build/\ndemo/web/public/\n"
    writeFile (root </> "build") "#!/bin/sh\n"
    forM_ ["docker/public", "demo/web/public", "nested/build"] $ \directory -> do
        createDirectoryIfMissing True (root </> directory)
        writeFile (root </> directory </> "setup.sh") "true\n"
    trackedScriptFiles root >>= (@?= ["build", "docker/public/setup.sh"])
    withSystemTempDirectory "hostbootstrap-ignore-directory" $ \second -> do
        writeFile (second </> ".gitignore") "build/\ndemo/web/public/\n"
        createDirectoryIfMissing True (second </> "build")
        writeFile (second </> "build" </> "setup.sh") "true\n"
        trackedScriptFiles second >>= (@?= [])
