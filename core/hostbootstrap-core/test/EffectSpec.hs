{- | Absence guards for the one-effect-vocabulary boundary.

§ KK admits one shell quoter, one process runner, and one rendering of "cross
into this frame". A second copy of any of them is invisible to every gate that
exists, because each copy passes its own tests: two quoters agree on the inputs
both were written for and disagree on the first character only one of them ever
met, and nothing compares them.

So the guards here are lexical rather than behavioural. They assert that the
quoter has exactly one definition site in the package and that the spellings it
replaced name nothing, across the library, its private sublibraries, and the
consumer that composes commands against it.
-}
module EffectSpec (tests) where

import Control.Monad (forM_)
import Data.List (isSuffixOf, sort)
import qualified Data.Map.Strict as Map
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Effect (
    EffectFrame (CrossedInto, OuterHost),
    EffectTarget (SelfTarget, ToolTarget),
    FrameCrossing (CrossContainer, CrossLimaVM, CrossWsl2VM),
    HostCommand (commandFrame, commandTarget),
    PathGrammar (HostPathGrammar, PosixGuestGrammar),
    framePathGrammar,
    hostCommand,
    resolveLaunch,
 )
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (AbsExe, HostTool (Docker, Lima), mkAbsExe)
import HostBootstrap.Lift (
    ContainerLift (..),
    LiftLeaf (RawCmd),
    LimaVM (LimaVM),
    foldLeafCommand,
    inContainer,
    inLimaVM,
    liftContextFrame,
    localContext,
    selfCommand,
 )
import HostBootstrap.Substrate (Arch (Amd64), Substrate (Substrate), SubstrateName (LinuxCpu))
import PlatformPath (hostFixturePath)
import qualified SourceGuard
import System.Directory (doesDirectoryExist, getCurrentDirectory, listDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "EffectSpec"
        [ testCase "the shell quoter has exactly one definition site" $ do
            sources <- commandComposingSources
            let definitions =
                    [ (path, count)
                    | (path, source) <- sources
                    , let count = SourceGuard.countHaskellTokenSequence ["shellQuoteArg", "::"] source
                    , count > 0
                    ]
            definitions @?= [("core/hostbootstrap-core/internal/effect/HostBootstrap/Effect/Quote.hs", 1)]
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
                    , SourceGuard.countHaskellIdentifier "readProcessWithExitCode" source > 0
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
        , testCase "process-group teardown belongs to the three group owners" $ do
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
                    , any
                        (\spelling -> SourceGuard.countHaskellIdentifier spelling source > 0)
                        ["createProcess", "withCreateProcess"]
                    ]
            sort sites @?= sort launchBoundaries
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
            root <- repoRoot
            tracked <- trackedScriptFiles root
            sort tracked @?= sort remainingScripts
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
            liftContextFrame (inContainer container (inLimaVM (LimaVM "demo-vm") localContext))
                @?= CrossedInto (CrossLimaVM "demo-vm") [CrossContainer "demo:latest"]
        , testCase "a crossed command names a tool, and a local one names the binary" $ do
            let crossed = foldLeafCommand (inLimaVM (LimaVM "demo-vm") localContext) (RawCmd ["true"])
                local = foldLeafCommand localContext (RawCmd ["/bin/true"])
            commandTarget crossed @?= ToolTarget Lima
            commandFrame crossed @?= CrossedInto (CrossLimaVM "demo-vm") []
            commandTarget local @?= SelfTarget "/bin/true"
            commandFrame local @?= OuterHost
        ]
  where
    container =
        ContainerLift
            { clImage = "demo:latest"
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

{- | Every module allowed to signal a process group. Three, because three
boundaries own a group; a fourth would be a teardown nobody compared with
these.
-}
groupOwners :: [FilePath]
groupOwners = [runnerPath, handoffProcessPath, handoffTransactionPath]

-- | The one interpreter for the closed effect vocabulary (§ KK).
interpreterPath :: FilePath
interpreterPath = "core/hostbootstrap-core/src/HostBootstrap/Effect/Interpreter.hs"

{- | Every script file still in the tree, and the phase that removes each.

§ KK says the repository contains no script: a capability an operator or an
agent needs is a surface on the binary, and scaffolding that belongs to one
development harness lives in that harness's own configuration rather than here.
This list is what is left, so a new script cannot arrive unnamed — and each
entry is removed by the phase beside it, not by whoever notices it.

  * @scripts/run-live-cluster-gate.sh@ — the live kind/Helm gate, owned by the
    cluster-lifecycle, budgets, and cordoning phase.
-}
remainingScripts :: [FilePath]
remainingScripts = ["scripts/run-live-cluster-gate.sh"]

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
    ignored <- ignoredDirectoryNames root
    let collect directory = do
            entries <- listDirectory directory
            fmap concat . traverse (visit directory) $ sort entries

        visit directory entry
            | entry `elem` ignored = pure []
            | otherwise = do
                let path = directory </> entry
                nested <- doesDirectoryExist path
                if nested
                    then collect path
                    else
                        pure
                            [ SourceGuard.repoRelativePath root path
                            | any (`isSuffixOf` entry) scriptExtensions
                            ]
    collect root

{- | The directory names @.gitignore@ excludes, by their last segment, plus the
repository's own metadata directory.
-}
ignoredDirectoryNames :: FilePath -> IO [String]
ignoredDirectoryNames root = do
    patterns <- lines <$> readFile (root </> ".gitignore")
    pure (".git" : [lastSegment pattern | pattern <- map trim patterns, isDirectoryPattern pattern])
  where
    isDirectoryPattern pattern = case pattern of
        ('#' : _) -> False
        (_ : _) -> last pattern == '/'
        [] -> False

    lastSegment = reverse . takeWhile (/= '/') . drop 1 . reverse

    trim = dropWhile (== ' ') . reverse . dropWhile (`elem` (" \r\t" :: String)) . reverse

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
    fmap concat . traverse (readSourcesUnder root) $
        [ "core" </> "hostbootstrap-core" </> "src"
        , "core" </> "hostbootstrap-core" </> "internal"
        , "demo" </> "src"
        ]

readSourcesUnder :: FilePath -> FilePath -> IO [(FilePath, String)]
readSourcesUnder root relative = collect (root </> relative)
  where
    collect directory = do
        entries <- listDirectory directory
        fmap concat . traverse (visit directory) $ sort entries

    visit directory entry = do
        let path = directory </> entry
        nested <- doesDirectoryExist path
        if nested
            then collect path
            else
                if ".hs" `isSuffixOf` entry
                    then do
                        source <- readFile path
                        pure [(SourceGuard.repoRelativePath root path, source)]
                    else pure []

repoRoot :: IO FilePath
repoRoot = do
    cwd <- getCurrentDirectory
    findRepoRoot cwd >>= maybe (assertFailure "could not locate the repository root") pure
