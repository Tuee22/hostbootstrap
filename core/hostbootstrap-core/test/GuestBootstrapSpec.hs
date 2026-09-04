{- | The guest bootstrap vocabulary (§ KK).

Two things are worth asserting about a vocabulary whose whole purpose is to run
in a frame no gate can reach. First, that it is a vocabulary: the plan is a
value, ordered, and every step renders to an argument vector rather than to text
an interpreter re-splits — so the plan is checkable here even though the frame is
not. Second, that its paths are the guest's (§ MM), because the outer host this
suite runs on is exactly where a drive-qualified path would otherwise be handed
to a Linux process.

The driver's control flow is covered against an injected leaf runner, so
probe-first, act-on-absence, re-probe, and stop-at-the-first-unsettled step are
tested without a guest.
-}
module GuestBootstrapSpec (tests) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import HostBootstrap.Ensure.GuestBootstrap (
    GuestBootstrapStep (..),
    GuestBootstrapTarget,
    GuestPackage (Pipx),
    GuestStepOutcome (GuestStepInstalled, GuestStepSatisfied),
    PinnedToolchain (PinnedToolchain),
    allGuestPackages,
    guestBootstrapPlan,
    guestPackageName,
    mkGuestBootstrapTarget,
    runGuestBootstrapWith,
    stepActions,
    stepLabel,
    stepProbe,
 )
import HostBootstrap.Lift (LiftLeaf (RawCmd))
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import qualified System.FilePath.Windows as Windows
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "GuestBootstrapSpec"
        [ testGroup "the target admits only guest paths" targetCases
        , testGroup "the plan is ordered and total" planCases
        , testGroup "every rendering is an argument vector" renderingCases
        , testGroup "the driver is probe-first" driverCases
        ]

pinned :: PinnedToolchain
pinned = PinnedToolchain "9.12.4"

-- | The target every rendering case is written against.
target :: GuestBootstrapTarget
target = either error id validTarget

validTarget :: Either String GuestBootstrapTarget
validTarget =
    mkGuestBootstrapTarget
        "/root/hostbootstrap"
        "/root/hostbootstrap/demo"
        "/root/.ghcup"
        "/root/.local/bin/hostbootstrap"
        "/root/hostbootstrap/demo/.build/hostbootstrap-demo"
        "/usr/local/bin/hostbootstrap-demo"
        pinned

-- ---------------------------------------------------------------------------
-- The target
-- ---------------------------------------------------------------------------

targetCases :: [TestTree]
targetCases =
    [ testCase "a POSIX-absolute target is admitted" $
        fmap (const ()) validTarget @?= Right ()
    , testCase "a drive-qualified path is refused, and named" $ do
        let refused =
                mkGuestBootstrapTarget
                    "C:\\Users\\ci\\hostbootstrap"
                    "/root/hostbootstrap/demo"
                    "/root/.ghcup"
                    "/root/.local/bin/hostbootstrap"
                    "/root/build/pb"
                    "/usr/local/bin/pb"
                    pinned
        case refused of
            Right _ -> assertBool "a Windows host path is not a guest path" False
            Left message -> do
                assertBool
                    ("the refusal names the offending path: " ++ message)
                    ("C:\\Users\\ci\\hostbootstrap" `isInfixOf` message)
                assertBool
                    ("the refusal cites the path-grammar rule: " ++ message)
                    ("§ MM" `isInfixOf` message)
    , testCase "a relative path is refused" $ do
        let refused =
                mkGuestBootstrapTarget
                    "/root/hostbootstrap"
                    "demo"
                    "/root/.ghcup"
                    "/root/.local/bin/hostbootstrap"
                    "/root/build/pb"
                    "/usr/local/bin/pb"
                    pinned
        fmap (const ()) refused @?= Left "guest bootstrap: not a POSIX-absolute guest path (§ MM): demo"
    , testCase "an unpinned toolchain is refused before any path is rendered" $ do
        let refused =
                mkGuestBootstrapTarget
                    "/root/hostbootstrap"
                    "/root/hostbootstrap/demo"
                    "/root/.ghcup"
                    "/root/.local/bin/hostbootstrap"
                    "/root/build/pb"
                    "/usr/local/bin/pb"
                    (PinnedToolchain "")
        fmap (const ()) refused
            @?= Left "guest bootstrap: the pinned toolchain names no GHC version"
    ]

-- ---------------------------------------------------------------------------
-- The plan
-- ---------------------------------------------------------------------------

planCases :: [TestTree]
planCases =
    [ testCase "the five steps run in the one order the vocabulary declares" $
        map constructorOf (guestBootstrapPlan target)
            @?= [ "InstallGuestPackages"
                , "InstallPinnedToolchain"
                , "InstallGuestBootstrapper"
                , "BuildGuestProjectBinary"
                , "InstallGuestProjectBinary"
                ]
    , testCase "the package step carries the whole guest floor" $
        case guestBootstrapPlan target of
            (InstallGuestPackages packages : _) -> packages @?= allGuestPackages
            steps -> assertBool ("the plan opens with the package step: " ++ show steps) False
    , testCase "the floor names pipx, because the bootstrapper is installed with it" $
        assertBool "pipx is part of the guest floor" (Pipx `elem` allGuestPackages)
    , testCase "every package name is non-empty and distinct" $ do
        let names = map guestPackageName allGuestPackages
        assertBool "no package renders as an empty argument" (all (not . null) names)
        length names @?= length allGuestPackages
    , testCase "every step labels itself" $
        assertBool
            "no step reports itself as an empty label"
            (all (not . null . stepLabel) (guestBootstrapPlan target))
    ]
  where
    constructorOf step = case step of
        InstallGuestPackages{} -> "InstallGuestPackages"
        InstallPinnedToolchain{} -> "InstallPinnedToolchain"
        InstallGuestBootstrapper{} -> "InstallGuestBootstrapper"
        BuildGuestProjectBinary{} -> "BuildGuestProjectBinary"
        InstallGuestProjectBinary{} -> "InstallGuestProjectBinary"

-- ---------------------------------------------------------------------------
-- The renderings
-- ---------------------------------------------------------------------------

renderingCases :: [TestTree]
renderingCases =
    [ testCase "no rendering hands a program to an interpreter" $ do
        let leaves = concatMap (\step -> stepProbe step : stepActions step) plan
        mapM_ assertNoInterpreter leaves
    , testCase "no argument carries a Windows path separator" $ do
        -- Named through the platform module rather than spelled, so this case
        -- asserts the separator the outer host would have supplied rather than a
        -- character literal a reader has to recognise.
        let arguments = concatMap argvOf (concatMap (\s -> stepProbe s : stepActions s) plan)
        assertBool
            ("a guest argument is POSIX on every outer host: " ++ show arguments)
            (not (any (Windows.pathSeparator `elem`) arguments))
    , testCase "each probe answers with its exit status alone" $
        map (argvOf . stepProbe) plan
            @?= [ "dpkg-query" : "-W" : map guestPackageName allGuestPackages
                ,
                    [ "test"
                    , "-x"
                    , "/root/.ghcup/bin/ghcup"
                    , "-a"
                    , "-x"
                    , "/root/.ghcup/ghc/9.12.4/bin/ghc"
                    , "-a"
                    , "-x"
                    , "/root/.ghcup/bin/cabal"
                    ]
                , ["test", "-x", "/root/.local/bin/hostbootstrap"]
                , ["test", "-x", "/root/hostbootstrap/demo/.build/hostbootstrap-demo"]
                ,
                    [ "cmp"
                    , "-s"
                    , "/root/hostbootstrap/demo/.build/hostbootstrap-demo"
                    , "/usr/local/bin/hostbootstrap-demo"
                    ]
                ]
    , testCase "the toolchain step fetches the installer, then runs it" $
        case stepActions (plan !! 1) of
            [RawCmd fetch, RawCmd run] -> do
                assertBool ("the fetch names curl: " ++ show fetch) (take 1 fetch == ["curl"])
                assertBool
                    ("the run pins the GHC version: " ++ show run)
                    ("BOOTSTRAP_HASKELL_GHC_VERSION=9.12.4" `elem` run)
                assertBool
                    ("the run is non-interactive: " ++ show run)
                    ("BOOTSTRAP_HASKELL_NONINTERACTIVE=1" `elem` run)
            actions ->
                assertBool
                    ("a pipe is two steps, not one command: " ++ show actions)
                    False
    , testCase "the package step refreshes the index before it installs" $
        case map argvOf (stepActions (plan !! 0)) of
            [update, install] -> do
                assertBool ("the first action updates: " ++ show update) ("update" `elem` update)
                assertBool ("the second installs: " ++ show install) ("install" `elem` install)
                assertBool
                    ("both run non-interactively: " ++ show (update, install))
                    (all ("DEBIAN_FRONTEND=noninteractive" `elem`) [update, install])
            actions -> assertBool ("index then install: " ++ show actions) False
    , testCase "the build names its working directory rather than changing into one" $
        case map argvOf (stepActions (plan !! 3)) of
            [build] -> do
                assertBool ("the build is run under env: " ++ show build) (take 1 build == ["env"])
                assertBool
                    ("the project directory is an argument: " ++ show build)
                    (["-C", "/root/hostbootstrap/demo"] `isInfixOfList` build)
                assertBool
                    ("the pinned toolchain leads PATH: " ++ show build)
                    (any (\argument -> "PATH=/root/.ghcup/bin:" `isPrefixOfString` argument) build)
                assertBool
                    ("the bootstrapper builds: " ++ show build)
                    (build `endsWith` ["/root/.local/bin/hostbootstrap", "build"])
            actions -> assertBool ("one build command: " ++ show actions) False
    ]
  where
    plan = guestBootstrapPlan target

    assertNoInterpreter leaf = do
        let argv = argvOf leaf
        assertBool
            ("no step renders a program for an interpreter: " ++ show argv)
            (not (any (`elem` argv) ["-c", "-lc", "sh", "bash", "powershell.exe"]) || isToolchainRun argv)

    -- The toolchain installer is a downloaded file run by @sh@, which is a
    -- program the frame fetched rather than text this module composed: the
    -- argument beside @sh@ is a path, never a script body.
    isToolchainRun argv = case break (== "sh") argv of
        (_, "sh" : script : rest) -> null rest && take 1 script == "/"
        _ -> False

argvOf :: LiftLeaf -> [String]
argvOf (RawCmd argv) = argv
argvOf leaf = error ("the guest bootstrap renders raw argument vectors only: " ++ show leaf)

isInfixOfList :: (Eq a) => [a] -> [a] -> Bool
isInfixOfList needle haystack =
    any (\suffix -> take (length needle) suffix == needle) (suffixes haystack)
  where
    suffixes [] = [[]]
    suffixes xs@(_ : rest) = xs : suffixes rest

isPrefixOfString :: String -> String -> Bool
isPrefixOfString prefix value = take (length prefix) value == prefix

endsWith :: (Eq a) => [a] -> [a] -> Bool
endsWith value suffix = reverse (take (length suffix) (reverse value)) == suffix

-- ---------------------------------------------------------------------------
-- The driver
-- ---------------------------------------------------------------------------

{- | A leaf runner that answers from a table: a probe whose argv is in @present@
succeeds, every other probe fails until its step's actions have run, and every
action succeeds unless it is in @failing@.
-}
scriptedRunner ::
    IORef [[String]] ->
    [[String]] ->
    [[String]] ->
    LiftLeaf ->
    IO (Either String (ExitCode, String, String))
scriptedRunner journal satisfiedProbes failingActions leaf = do
    let argv = argvOf leaf
    modifyIORef' journal (++ [argv])
    ran <- readIORef journal
    pure $
        Right
            ( if isProbe argv
                then
                    if argv `elem` satisfiedProbes || probeSatisfiedByActions argv ran
                        then ExitSuccess
                        else ExitFailure 1
                else
                    if argv `elem` failingActions
                        then ExitFailure 2
                        else ExitSuccess
            , ""
            , ""
            )
  where
    isProbe argv = take 1 argv `elem` [["test"], ["dpkg-query"], ["cmp"]]

    -- A probe passes once any action ran after the probe's own first failure,
    -- which is exactly "the step settled".
    probeSatisfiedByActions argv ran =
        length (filter (== argv) ran) > 1
            && not (null [entry | entry <- ran, not (isProbe entry)])

driverCases :: [TestTree]
driverCases =
    [ testCase "a satisfied frame runs one probe per step and nothing else" $ do
        journal <- newIORef []
        let probes = map (argvOf . stepProbe) (guestBootstrapPlan target)
        outcome <- runGuestBootstrapWith (scriptedRunner journal probes []) target
        case outcome of
            Left err -> assertBool ("an already-bootstrapped frame settles: " ++ err) False
            Right results -> do
                length results @?= 5
                assertBool
                    ("every step is satisfied: " ++ show results)
                    (all isSatisfied results)
        ran <- readIORef journal
        ran @?= probes
    , testCase "an empty frame probes, acts, and re-probes each step in order" $ do
        journal <- newIORef []
        outcome <- runGuestBootstrapWith (scriptedRunner journal [] []) target
        case outcome of
            Left err -> assertBool ("an empty frame bootstraps: " ++ err) False
            Right results ->
                assertBool
                    ("every step is installed: " ++ show results)
                    (all (not . isSatisfied) results)
        ran <- readIORef journal
        let firstProbe = argvOf (stepProbe (guestBootstrapPlan target !! 0))
        assertBool "the first thing that runs is a probe" (take 1 ran == [firstProbe])
        assertBool
            "the probe is asked again after the actions ran"
            (length (filter (== firstProbe) ran) == 2)
    , testCase "a failed action stops the run at its own step" $ do
        journal <- newIORef []
        let failing = map argvOf (stepActions (guestBootstrapPlan target !! 1))
        outcome <- runGuestBootstrapWith (scriptedRunner journal [] failing) target
        case outcome of
            Right results -> assertBool ("a failing action refuses: " ++ show results) False
            Left message -> do
                assertBool
                    ("the refusal names the toolchain step: " ++ message)
                    ("pinned toolchain" `isInfixOf` message)
                assertBool
                    ("the refusal is the vocabulary's own: " ++ message)
                    ("guest bootstrap: " `isInfixOf` message)
        ran <- readIORef journal
        assertBool
            ("no later step ran: " ++ show ran)
            (argvOf (stepProbe (guestBootstrapPlan target !! 2)) `notElem` ran)
    , testCase "an unsettled probe after a successful action refuses" $ do
        -- Every action succeeds and the probe never does, which is exactly the
        -- case a package manager's own "nothing to do" exit hides.
        let neverSettles leaf =
                pure . Right $
                    ( if take 1 (argvOf leaf) `elem` [["test"], ["dpkg-query"], ["cmp"]]
                        then ExitFailure 1
                        else ExitSuccess
                    , ""
                    , ""
                    )
        outcome <- runGuestBootstrapWith neverSettles target
        case outcome of
            Right results -> assertBool ("a never-settling step refuses: " ++ show results) False
            Left message ->
                assertBool
                    ("the refusal says the step did not settle: " ++ message)
                    ("still not satisfied" `isInfixOf` message)
    , testCase "a runner error is reported against the step that issued it" $ do
        outcome <- runGuestBootstrapWith (const (pure (Left "incus is not resolved"))) target
        case outcome of
            Right results -> assertBool ("a transport failure refuses: " ++ show results) False
            Left message ->
                assertBool
                    ("the refusal carries the transport's own reason: " ++ message)
                    ("incus is not resolved" `isInfixOf` message)
    ]
  where
    isSatisfied GuestStepSatisfied{} = True
    isSatisfied GuestStepInstalled{} = False
