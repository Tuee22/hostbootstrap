{- | The guest bootstrap vocabulary (§ KK).

Two things are worth asserting about a vocabulary whose whole purpose is to run
in a frame no gate can reach. First, that it is a vocabulary: the plan is a
value, ordered, and every step renders to an argument vector rather than to text
an interpreter re-splits — so the plan is checkable here even though the frame is
not. Second, that its paths are the guest's (§ MM), because the outer host this
suite runs on is exactly where a drive-qualified path would otherwise be handed
to a Linux process.

The driver's control flow is covered against an injected leaf runner: ordinary
steps probe, act on absence, and re-probe; the staged bootstrapper always
reinstalls and verifies. Both stop at the first unsettled step without a guest.
-}
module GuestBootstrapSpec (tests) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, nub)
import qualified Data.Map.Strict as Map
import HostBootstrap.Ensure.GuestBootstrap (
    GuestBootstrapperExe,
    GuestBootstrapStep,
    GuestBootstrapTarget,
    GuestBuiltBinary,
    GuestInstalledBinary,
    GuestPackage (Pipx),
    GuestProjectDir,
    GuestSourceRoot,
    GuestToolchainHome,
    GuestStepKind (..),
    GuestStepOutcome (GuestStepInstalled, GuestStepSatisfied),
    PinnedToolchain (PinnedToolchain),
    allGuestPackages,
    floorPackagesSatisfied,
    guestBootstrapPlan,
    guestBootstrapperExe,
    guestBootstrapperExePath,
    guestBuiltBinary,
    guestBuiltBinaryPath,
    guestInstalledBinary,
    guestInstalledBinaryPath,
    guestPackageName,
    guestPathValue,
    guestProjectDir,
    guestProjectDirPath,
    guestSourceRoot,
    guestSourceRootPath,
    guestToolchain,
    guestToolchainHome,
    guestToolchainHomePath,
    mkGuestBootstrapTarget,
    mkGuestBootstrapperExe,
    mkGuestBuiltBinary,
    mkGuestInstalledBinary,
    mkGuestPath,
    mkGuestProjectDir,
    mkGuestSourceRoot,
    mkGuestToolchainHome,
    runGuestBootstrapWith,
    stepActions,
    stepKind,
    stepLabel,
    stepProbe,
 )
import HostBootstrap.Lift (LiftLeaf (RawCmd))
import qualified SourceGuard
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import qualified System.FilePath.Windows as Windows
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "GuestBootstrapSpec"
        [ testGroup "GuestPath admission" pathCases
        , testGroup "the target admits only guest paths" targetCases
        , testGroup "the plan is ordered and total" planCases
        , testGroup "every rendering is an argument vector" renderingCases
        , testGroup "the floor reads installed package states" floorCases
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
        sourceRoot
        projectDir
        toolchainHome
        bootstrapperExe
        builtBinary
        installedBinary
        pinned

sourceRoot :: GuestSourceRoot
sourceRoot = mkGuestSourceRoot (either error id (mkGuestPath "/root/hostbootstrap"))

projectDir :: GuestProjectDir
projectDir = mkGuestProjectDir (either error id (mkGuestPath "/root/hostbootstrap/demo"))

toolchainHome :: GuestToolchainHome
toolchainHome = mkGuestToolchainHome (either error id (mkGuestPath "/root/.ghcup"))

bootstrapperExe :: GuestBootstrapperExe
bootstrapperExe = mkGuestBootstrapperExe (either error id (mkGuestPath "/root/.local/bin/hostbootstrap"))

builtBinary :: GuestBuiltBinary
builtBinary = mkGuestBuiltBinary (either error id (mkGuestPath "/root/hostbootstrap/demo/.build/hostbootstrap-demo"))

installedBinary :: GuestInstalledBinary
installedBinary = mkGuestInstalledBinary (either error id (mkGuestPath "/usr/local/bin/hostbootstrap-demo"))

-- ---------------------------------------------------------------------------
-- The target
-- ---------------------------------------------------------------------------

pathCases :: [TestTree]
pathCases =
    [ testCase ("a POSIX-absolute path keeps its original spelling: " ++ show path) $
        fmap guestPathValue (mkGuestPath path) @?= Right path
    | path <- ["/", "/root/hostbootstrap", "/root/path with spaces", "/root/café/../source//", "/root/.ghcup/"]
    ]
        <> [ testCase ("a non-absolute guest path is refused: " ++ show path) $
                fmap guestPathValue (mkGuestPath path)
                    @?= Left ("guest bootstrap: not a POSIX-absolute guest path (§ MM): " ++ path)
           | path <- ["", "demo", "./demo", "../demo", "C:\\Users\\ci\\hostbootstrap", "C:/Users/ci/hostbootstrap", "\\\\server\\share"]
           ]
        <> [ testCase "GuestPath Show preserves the original FilePath representation" $ do
                let raw = "/root/a path/../source//"
                path <- either assertFailure pure (mkGuestPath raw)
                show path @?= show raw
                showsPrec 10 path "" @?= showsPrec 10 raw ""
                showsPrec 11 path "" @?= showsPrec 11 raw ""
           ]

targetCases :: [TestTree]
targetCases =
    [ testCase "a POSIX-absolute target is admitted" $
        fmap (const ()) validTarget @?= Right ()
    , testCase "source-root admission refuses and names a drive-qualified path" $ do
        let refused =
                mkGuestSourceRoot <$> mkGuestPath "C:\\Users\\ci\\hostbootstrap"
        case refused of
            Right _ -> assertBool "a Windows host path is not a guest path" False
            Left message -> do
                assertBool
                    ("the refusal names the offending path: " ++ message)
                    ("C:\\Users\\ci\\hostbootstrap" `isInfixOf` message)
                assertBool
                    ("the refusal cites the path-grammar rule: " ++ message)
                    ("§ MM" `isInfixOf` message)
    , testCase "project-directory admission refuses a relative path" $ do
        let refused =
                mkGuestProjectDir <$> mkGuestPath "demo"
        fmap (const ()) refused @?= Left "guest bootstrap: not a POSIX-absolute guest path (§ MM): demo"
    , testCase "toolchain-home admission refuses a relative path" $
        fmap (const ()) (mkGuestToolchainHome <$> mkGuestPath ".ghcup")
            @?= Left "guest bootstrap: not a POSIX-absolute guest path (§ MM): .ghcup"
    , testCase "bootstrapper-executable admission refuses a relative path" $
        fmap (const ()) (mkGuestBootstrapperExe <$> mkGuestPath ".local/bin/hostbootstrap")
            @?= Left "guest bootstrap: not a POSIX-absolute guest path (§ MM): .local/bin/hostbootstrap"
    , testCase "built-binary admission refuses a relative path" $
        fmap (const ()) (mkGuestBuiltBinary <$> mkGuestPath ".build/hostbootstrap-demo")
            @?= Left "guest bootstrap: not a POSIX-absolute guest path (§ MM): .build/hostbootstrap-demo"
    , testCase "an unpinned toolchain is refused before any path is rendered" $ do
        let refused =
                mkGuestBootstrapTarget
                    sourceRoot
                    projectDir
                    toolchainHome
                    bootstrapperExe
                    builtBinary
                    installedBinary
                    (PinnedToolchain "")
        fmap (const ()) refused
            @?= Left "guest bootstrap: the pinned toolchain names no GHC version"
    , testCase "the toolchain home must name the directory the installer creates" $
        mapM_
            ( \home -> do
                admitted <- either assertFailure pure (mkGuestPath home)
                fmap (const ())
                    ( mkGuestBootstrapTarget
                        sourceRoot
                        projectDir
                        (mkGuestToolchainHome admitted)
                        bootstrapperExe
                        builtBinary
                        installedBinary
                        pinned
                    )
                    @?= Left ("guest bootstrap: the toolchain home must end in .ghcup without a trailing separator: " ++ home)
            )
            ["/opt/ghcup", "/root/.ghcup/"]
    , testCase "installed-binary admission refuses a relative path" $
        fmap (const ()) (mkGuestInstalledBinary <$> mkGuestPath "bad-installed")
            @?= Left "guest bootstrap: not a POSIX-absolute guest path (§ MM): bad-installed"
    , testCase "the empty pin is refused before an absolute but incompatible toolchain home" $ do
        home <- either assertFailure pure (mkGuestPath "/opt/ghcup")
        fmap (const ())
            ( mkGuestBootstrapTarget
                sourceRoot
                projectDir
                (mkGuestToolchainHome home)
                bootstrapperExe
                builtBinary
                installedBinary
                (PinnedToolchain "")
            )
            @?= Left "guest bootstrap: the pinned toolchain names no GHC version"
    , testCase "ordinary target readers retain all six admitted path proofs and the pin" $ do
        source <- either assertFailure pure (mkGuestPath "/root/source//repo/..")
        project <- either assertFailure pure (mkGuestPath "/root/source/./demo")
        home <- either assertFailure pure (mkGuestPath "/root//.ghcup")
        bootstrapper <- either assertFailure pure (mkGuestPath "/root//.local/bin/hostbootstrap")
        built <- either assertFailure pure (mkGuestPath "/root/demo/.build/../.build/pb")
        installed <- either assertFailure pure (mkGuestPath "/usr/local//bin/pb")
        admitted <-
            either assertFailure pure $
                mkGuestBootstrapTarget
                    (mkGuestSourceRoot source)
                    (mkGuestProjectDir project)
                    (mkGuestToolchainHome home)
                    (mkGuestBootstrapperExe bootstrapper)
                    (mkGuestBuiltBinary built)
                    (mkGuestInstalledBinary installed)
                    pinned
        map guestPathValue
            [ guestSourceRootPath (guestSourceRoot admitted)
            , guestProjectDirPath (guestProjectDir admitted)
            , guestToolchainHomePath (guestToolchainHome admitted)
            , guestBootstrapperExePath (guestBootstrapperExe admitted)
            , guestBuiltBinaryPath (guestBuiltBinary admitted)
            , guestInstalledBinaryPath (guestInstalledBinary admitted)
            ]
            @?= [ "/root/source//repo/.."
                , "/root/source/./demo"
                , "/root//.ghcup"
                , "/root//.local/bin/hostbootstrap"
                , "/root/demo/.build/../.build/pb"
                , "/usr/local//bin/pb"
                ]
        guestToolchain admitted @?= pinned
    , testCase "an alternate source root changes only the bootstrapper source label and pipx argument" $ do
        source <- either assertFailure pure (mkGuestPath "/alternate/source")
        alternate <-
            either assertFailure pure $
                mkGuestBootstrapTarget
                    (mkGuestSourceRoot source)
                    projectDir
                    toolchainHome
                    bootstrapperExe
                    builtBinary
                    installedBinary
                    pinned
        guestPathValue (guestSourceRootPath (guestSourceRoot alternate)) @?= "/alternate/source"
        let original = guestBootstrapPlan target
            changed = guestBootstrapPlan alternate
            originalLabels = map stepLabel original
            originalActions = map (map argvOf . stepActions) original
        map stepKind changed @?= map stepKind original
        map (argvOf . stepProbe) changed @?= map (argvOf . stepProbe) original
        map stepLabel changed
            @?= take 2 originalLabels
                ++ ["install the Python bootstrapper from /alternate/source"]
                ++ drop 3 originalLabels
        map (map argvOf . stepActions) changed
            @?= take 2 originalActions
                ++ [[["pipx", "install", "--force", "/alternate/source"]]]
                ++ drop 3 originalActions
    , testCase "an alternate project directory changes only the build label and env working directory" $ do
        project <- either assertFailure pure (mkGuestPath "/alternate/project")
        alternate <-
            either assertFailure pure $
                mkGuestBootstrapTarget
                    sourceRoot
                    (mkGuestProjectDir project)
                    toolchainHome
                    bootstrapperExe
                    builtBinary
                    installedBinary
                    pinned
        guestPathValue (guestProjectDirPath (guestProjectDir alternate)) @?= "/alternate/project"
        let original = guestBootstrapPlan target
            changed = guestBootstrapPlan alternate
            originalLabels = map stepLabel original
            originalActions = map (map argvOf . stepActions) original
        map stepKind changed @?= map stepKind original
        map (argvOf . stepProbe) changed @?= map (argvOf . stepProbe) original
        map stepLabel changed
            @?= take 3 originalLabels
                ++ ["build the project binary host-native in /alternate/project"]
                ++ drop 4 originalLabels
        map (map argvOf . stepActions) changed
            @?= take 3 originalActions
                ++ [ [ [ "env", "-C", "/alternate/project"
                       , "PATH=/root/.ghcup/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                       , "/root/.local/bin/hostbootstrap", "build"
                       ]
                     ]
                   ]
                ++ drop 4 originalActions
    , testCase "an alternate toolchain home changes only its probe, installer paths, and build PATH" $ do
        home <- either assertFailure pure (mkGuestPath "/alternate/.ghcup")
        alternate <-
            either assertFailure pure $
                mkGuestBootstrapTarget
                    sourceRoot
                    projectDir
                    (mkGuestToolchainHome home)
                    bootstrapperExe
                    builtBinary
                    installedBinary
                    pinned
        guestPathValue (guestToolchainHomePath (guestToolchainHome alternate)) @?= "/alternate/.ghcup"
        let original = guestBootstrapPlan target
            changed = guestBootstrapPlan alternate
            originalProbes = map (argvOf . stepProbe) original
            originalActions = map (map argvOf . stepActions) original
            toolchainActions =
                [ ["curl", "--proto", "=https", "--tlsv1.2", "-sSf", "-o", "/alternate/.ghcup-install.sh", "https://get-ghcup.haskell.org"]
                , [ "env", "BOOTSTRAP_HASKELL_NONINTERACTIVE=1", "BOOTSTRAP_HASKELL_INSTALL_NO_STACK=1"
                  , "BOOTSTRAP_HASKELL_GHC_VERSION=9.12.4", "GHCUP_INSTALL_BASE_PREFIX=/alternate", "sh", "/alternate/.ghcup-install.sh"
                  ]
                ]
            buildActions =
                [ [ "env", "-C", "/root/hostbootstrap/demo"
                  , "PATH=/alternate/.ghcup/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                  , "/root/.local/bin/hostbootstrap", "build"
                  ]
                ]
        map stepKind changed @?= map stepKind original
        map stepLabel changed @?= map stepLabel original
        map (argvOf . stepProbe) changed
            @?= take 1 originalProbes
                ++ [ [ "test", "-x", "/alternate/.ghcup/bin/ghcup", "-a", "-x"
                     , "/alternate/.ghcup/ghc/9.12.4/bin/ghc", "-a", "-x", "/alternate/.ghcup/bin/cabal"
                     ]
                   ]
                ++ drop 2 originalProbes
        case originalActions of
            [floorActions, _, bootstrapperActions, _, installActions] ->
                map (map argvOf . stepActions) changed
                    @?= [floorActions, toolchainActions, bootstrapperActions, buildActions, installActions]
            actions -> assertFailure ("expected the five original step action groups, got " ++ show actions)
    , testCase "an alternate bootstrapper changes only its executable probe and build executable with PATH parent" $ do
        bootstrapper <- either assertFailure pure (mkGuestPath "/alternate/tools/hostbootstrap")
        alternate <-
            either assertFailure pure $
                mkGuestBootstrapTarget
                    sourceRoot
                    projectDir
                    toolchainHome
                    (mkGuestBootstrapperExe bootstrapper)
                    builtBinary
                    installedBinary
                    pinned
        guestPathValue (guestBootstrapperExePath (guestBootstrapperExe alternate)) @?= "/alternate/tools/hostbootstrap"
        let original = guestBootstrapPlan target
            changed = guestBootstrapPlan alternate
            originalProbes = map (argvOf . stepProbe) original
            originalActions = map (map argvOf . stepActions) original
        map stepKind changed @?= map stepKind original
        map stepLabel changed @?= map stepLabel original
        map (argvOf . stepProbe) changed
            @?= take 2 originalProbes
                ++ [["test", "-x", "/alternate/tools/hostbootstrap"]]
                ++ drop 3 originalProbes
        map (map argvOf . stepActions) changed
            @?= take 3 originalActions
                ++ [ [ [ "env", "-C", "/root/hostbootstrap/demo"
                       , "PATH=/root/.ghcup/bin:/alternate/tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                       , "/alternate/tools/hostbootstrap", "build"
                       ]
                     ]
                   ]
                ++ drop 4 originalActions
    , testCase "an alternate built binary changes only its executable probe, comparison source, and install source" $ do
        built <- either assertFailure pure (mkGuestPath "/alternate/build/hostbootstrap-demo")
        alternate <-
            either assertFailure pure $
                mkGuestBootstrapTarget
                    sourceRoot
                    projectDir
                    toolchainHome
                    bootstrapperExe
                    (mkGuestBuiltBinary built)
                    installedBinary
                    pinned
        guestPathValue (guestBuiltBinaryPath (guestBuiltBinary alternate)) @?= "/alternate/build/hostbootstrap-demo"
        let original = guestBootstrapPlan target
            changed = guestBootstrapPlan alternate
            originalProbes = map (argvOf . stepProbe) original
            originalActions = map (map argvOf . stepActions) original
        map stepKind changed @?= map stepKind original
        map stepLabel changed @?= map stepLabel original
        map (argvOf . stepProbe) changed
            @?= take 3 originalProbes
                ++ [ ["test", "-x", "/alternate/build/hostbootstrap-demo"]
                   , ["cmp", "-s", "/alternate/build/hostbootstrap-demo", "/usr/local/bin/hostbootstrap-demo"]
                   ]
        map (map argvOf . stepActions) changed
            @?= take 4 originalActions
                ++ [[["sudo", "-n", "install", "-m", "0755", "/alternate/build/hostbootstrap-demo", "/usr/local/bin/hostbootstrap-demo"]]]
    , testCase "an alternate installed binary changes only its label and comparison and install destinations" $ do
        installed <- either assertFailure pure (mkGuestPath "/alternate/bin/hostbootstrap-demo")
        alternate <-
            either assertFailure pure $
                mkGuestBootstrapTarget
                    sourceRoot
                    projectDir
                    toolchainHome
                    bootstrapperExe
                    builtBinary
                    (mkGuestInstalledBinary installed)
                    pinned
        guestPathValue (guestInstalledBinaryPath (guestInstalledBinary alternate)) @?= "/alternate/bin/hostbootstrap-demo"
        let original = guestBootstrapPlan target
            changed = guestBootstrapPlan alternate
            originalLabels = map stepLabel original
            originalProbes = map (argvOf . stepProbe) original
            originalActions = map (map argvOf . stepActions) original
        map stepKind changed @?= map stepKind original
        map stepLabel changed
            @?= take 4 originalLabels
                ++ ["install the project binary at /alternate/bin/hostbootstrap-demo"]
        map (argvOf . stepProbe) changed
            @?= take 4 originalProbes
                ++ [["cmp", "-s", "/root/hostbootstrap/demo/.build/hostbootstrap-demo", "/alternate/bin/hostbootstrap-demo"]]
        map (map argvOf . stepActions) changed
            @?= take 4 originalActions
                ++ [[["sudo", "-n", "install", "-m", "0755", "/root/hostbootstrap/demo/.build/hostbootstrap-demo", "/alternate/bin/hostbootstrap-demo"]]]
    , testCase "target and step Show preserve original labels, payloads, and precedence" $ do
        let targetText =
                "GuestBootstrapTarget {guestSourceRoot = \"/root/hostbootstrap\", guestProjectDir = \"/root/hostbootstrap/demo\", guestToolchainHome = \"/root/.ghcup\", guestBootstrapperExe = \"/root/.local/bin/hostbootstrap\", guestBuiltBinary = \"/root/hostbootstrap/demo/.build/hostbootstrap-demo\", guestInstalledBinary = \"/usr/local/bin/hostbootstrap-demo\", guestToolchain = PinnedToolchain {toolchainGhcVersion = \"9.12.4\"}}"
            install = stepOf InstallBinaryStep
            stepText = "InstallGuestProjectBinary \"/root/hostbootstrap/demo/.build/hostbootstrap-demo\" \"/usr/local/bin/hostbootstrap-demo\""
        show target @?= targetText
        showsPrec 10 target "" @?= targetText
        showsPrec 11 target "" @?= "(" ++ targetText ++ ")"
        show (Just target) @?= "Just (" ++ targetText ++ ")"
        show install @?= stepText
        showsPrec 10 install "" @?= stepText
        showsPrec 11 install "" @?= "(" ++ stepText ++ ")"
        show (Just install) @?= "Just (" ++ stepText ++ ")"
    , testCase "target readers are ordinary definitions over private record labels" $
        -- DEVELOPMENT_PLAN/rationale.md: "Guest bootstrap steps come from admitted targets".
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            description <- SourceGuard.readPackageDescription
            path <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Ensure.GuestBootstrap"
            source <- readFile path
            SourceGuard.recordFieldNames "GuestBootstrapTarget" source
                @?= Right
                    [ "targetSourceRoot", "targetProjectDir", "targetToolchainHome"
                    , "targetBootstrapperExe", "targetBuiltBinary", "targetInstalledBinary", "targetToolchain"
                    ]
            mapM_
                (\name -> either assertFailure (const (pure ())) (SourceGuard.haskellDefinitionTokens name source))
                [ "guestSourceRoot", "guestProjectDir", "guestToolchainHome"
                , "guestBootstrapperExe", "guestBuiltBinary", "guestInstalledBinary", "guestToolchain"
                ]
    ]

-- ---------------------------------------------------------------------------
-- The plan
-- ---------------------------------------------------------------------------

planCases :: [TestTree]
planCases =
    [ testCase "the five steps run in the one order the vocabulary declares" $ do
        let kinds = map stepKind (guestBootstrapPlan target)
        kinds @?= [FloorStep, ToolchainStep, BootstrapperStep, BuildStep, InstallBinaryStep]
        kinds @?= [minBound .. maxBound]
    , testCase "the package step carries the whole guest floor" $
        case guestBootstrapPlan target of
            (step : _) -> do
                stepKind step @?= FloorStep
                argvOf (stepProbe step) @?= ["dpkg-query", "-W", "-f", dpkgFormat] ++ expectedFloorNames
            steps -> assertBool ("the plan opens with the package step: " ++ show steps) False
    , testCase "the floor names pipx, because the bootstrapper is installed with it" $
        assertBool "pipx is part of the guest floor" (Pipx `elem` allGuestPackages)
    , testCase "every package name is non-empty and distinct" $ do
        let names = map guestPackageName allGuestPackages
        assertBool "no package renders as an empty argument" (all (not . null) names)
        length (nub names) @?= length names
    , testCase "every step labels itself" $
        assertBool
            "no step reports itself as an empty label"
            (all (not . null . stepLabel) (guestBootstrapPlan target))
    ]

expectedFloorNames :: [String]
expectedFloorNames =
    [ "pipx", "python3-venv", "build-essential", "curl", "git", "pkg-config"
    , "ca-certificates", "libgmp-dev", "libtinfo-dev", "libncurses-dev", "zlib1g-dev"
    ]

dpkgFormat :: String
dpkgFormat = "${db:Status-Abbrev}\\n"

-- ---------------------------------------------------------------------------
-- The renderings
-- ---------------------------------------------------------------------------

renderingCases :: [TestTree]
renderingCases =
    [ testCase "no rendering hands a program to an interpreter" $ do
        let leaves = concatMap (\step -> stepProbe step : stepActions step) plan
        mapM_ assertNoInterpreter leaves
    , testCase "no guest path argument carries a Windows path separator" $ do
        -- Only the exact dpkg format in its known slot is an escape sequence;
        -- every other argument keeps the existing Windows-separator guard.
        let arguments = concatMap withoutDpkgFormat (concatMap (\s -> stepProbe s : stepActions s) plan)
        assertBool
            ("a guest argument is POSIX on every outer host: " ++ show arguments)
            (not (any (Windows.pathSeparator `elem`) arguments))
    , testCase "each probe uses the observation its step declares" $
        map (argvOf . stepProbe) plan
            @?= [ ["dpkg-query", "-W", "-f", "${db:Status-Abbrev}\\n"] ++ expectedFloorNames
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
            [RawCmd fetchExe fetchArgs, RawCmd runExe runTail] -> do
                let run = runExe : runTail
                fetchExe : fetchArgs
                    @?= ["curl", "--proto", "=https", "--tlsv1.2", "-sSf", "-o", "/root/.ghcup-install.sh", "https://get-ghcup.haskell.org"]
                run
                    @?= [ "env", "BOOTSTRAP_HASKELL_NONINTERACTIVE=1", "BOOTSTRAP_HASKELL_INSTALL_NO_STACK=1"
                        , "BOOTSTRAP_HASKELL_GHC_VERSION=9.12.4", "GHCUP_INSTALL_BASE_PREFIX=/root", "sh", "/root/.ghcup-install.sh"
                        ]
                case (break (== "-o") fetchArgs, break (== "sh") run) of
                    ((_, "-o" : fetched : _), (_, ["sh", installed])) -> fetched @?= installed
                    other -> assertFailure ("the installer fetch and run paths are missing: " ++ show other)
            actions ->
                assertBool
                    ("a pipe is two steps, not one command: " ++ show actions)
                    False
    , testCase "the package step refreshes the index before it installs" $
        map argvOf (stepActions (plan !! 0))
            @?= [ ["sudo", "-n", "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "update", "-q"]
                , ["sudo", "-n", "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y", "-q"] ++ expectedFloorNames
                ]
    , testCase "the bootstrapper is forcibly installed from the staged source" $
        map argvOf (stepActions (plan !! 2)) @?= [["pipx", "install", "--force", "/root/hostbootstrap"]]
    , testCase "binary installation pins privilege, mode, source, and destination" $
        map argvOf (stepActions (plan !! 4))
            @?= [["sudo", "-n", "install", "-m", "0755", "/root/hostbootstrap/demo/.build/hostbootstrap-demo", "/usr/local/bin/hostbootstrap-demo"]]
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

    withoutDpkgFormat leaf = case argvOf leaf of
        "dpkg-query" : "-W" : "-f" : format : packages | format == dpkgFormat ->
            ["dpkg-query", "-W", "-f"] ++ packages
        arguments -> arguments

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
argvOf (RawCmd exe argv) = exe : argv
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

floorCases :: [TestTree]
floorCases =
    [ testCase "every expected package must report the installed state" $
        floorPackagesSatisfied allGuestPackages (ExitSuccess, installedFloorOutput, "") @?= True
    , testCase "a removed package with retained config is not installed" $
        floorPackagesSatisfied allGuestPackages (ExitSuccess, removedFloorOutput, "") @?= False
    , testCase "a half-configured package is not installed" $
        floorPackagesSatisfied allGuestPackages (ExitSuccess, unlines ("iU " : drop 1 installedStates), "") @?= False
    , testCase "a nonzero query for an unknown package is not installed" $
        floorPackagesSatisfied allGuestPackages (ExitFailure 1, installedFloorOutput, "unknown package") @?= False
    , testCase "an empty successful query cannot satisfy the floor" $
        floorPackagesSatisfied allGuestPackages (ExitSuccess, "", "") @?= False
    , testCase "a query missing one package cannot satisfy the floor" $
        floorPackagesSatisfied allGuestPackages (ExitSuccess, unlines (drop 1 installedStates), "") @?= False
    , testCase "a query with an extra package cannot satisfy the exact floor" $
        floorPackagesSatisfied allGuestPackages (ExitSuccess, unlines ("ii " : installedStates), "") @?= False
    , testCase "an empty expected floor is refused" $
        floorPackagesSatisfied [] (ExitSuccess, "", "") @?= False
    ]

installedStates :: [String]
installedStates = replicate (length allGuestPackages) "ii "

installedFloorOutput :: String
installedFloorOutput = unlines installedStates

removedFloorOutput :: String
removedFloorOutput = unlines ("rc " : drop 1 installedStates)

-- ---------------------------------------------------------------------------
-- The driver
-- ---------------------------------------------------------------------------

{- | Exact probe identities retain their own readiness and remaining actions.
After a failed probe, only its complete ordered action sequence can settle it;
the unconditional bootstrapper is armed before its first verification.
-}
scriptedRunner ::
    IORef [[String]] ->
    [[String]] ->
    [[String]] ->
    IO (LiftLeaf -> IO (Either String (ExitCode, String, String)))
scriptedRunner journal satisfiedProbes failingActions = do
    progress <-
        newIORef $
            Map.fromList
                [ (probe, (probe `elem` satisfiedProbes, if stepKind step == BootstrapperStep then Just (actions step) else Nothing))
                | (probe, step) <- probes
                ]
    pure $ \leaf -> do
        let argv = argvOf leaf
        modifyIORef' journal (++ [argv])
        case lookup argv probes of
            Just step -> do
                states <- readIORef progress
                let (ready, remaining) = Map.findWithDefault (False, Nothing) argv states
                    settled = ready || remaining == Just []
                modifyIORef' progress $
                    Map.insert argv (settled, if settled then Nothing else Just (actions step))
                pure $ Right $ case stepKind step of
                    FloorStep -> (ExitSuccess, if settled then installedFloorOutput else removedFloorOutput, "")
                    _ -> (if settled then ExitSuccess else ExitFailure 1, "", "")
            Nothing
                | argv `elem` failingActions -> pure (Right (ExitFailure 2, "", "scripted action failed"))
                | argv `elem` allActions -> do
                    modifyIORef' progress (Map.mapWithKey (advance argv))
                    pure (Right (ExitSuccess, "", ""))
                | otherwise -> pure (Left ("unexpected scripted leaf: " ++ show argv))
  where
    probes = [(argvOf (stepProbe step), step) | step <- guestBootstrapPlan target]
    actions = map argvOf . stepActions
    allActions = concatMap (actions . snd) probes
    advance argv probe state@(ready, remaining) = case remaining of
        Just (next : rest) | argv == next -> (ready, Just rest)
        Just _ | Just step <- lookup probe probes, argv `elem` actions step -> (False, Just (actions step))
        _ -> state

stepOf :: GuestStepKind -> GuestBootstrapStep
stepOf kind = case filter ((== kind) . stepKind) (guestBootstrapPlan target) of
    [step] -> step
    other -> error ("expected one step of kind " ++ show kind ++ ", got " ++ show other)

installedJournal :: GuestBootstrapStep -> [[String]]
installedJournal step = case stepKind step of
    BootstrapperStep -> actions ++ [probe]
    _ -> [probe] ++ actions ++ [probe]
  where
    probe = argvOf (stepProbe step)
    actions = map argvOf (stepActions step)

satisfiedJournal :: GuestBootstrapStep -> [[String]]
satisfiedJournal step = case stepKind step of
    BootstrapperStep -> installedJournal step
    _ -> [argvOf (stepProbe step)]

driverCases :: [TestTree]
driverCases =
    [ testCase "a satisfied frame still reinstalls and verifies the staged bootstrapper on every run" $ do
        journal <- newIORef []
        let steps = guestBootstrapPlan target
            probes = map (argvOf . stepProbe) steps
            expectedResults =
                [ if stepKind step == BootstrapperStep then GuestStepInstalled step else GuestStepSatisfied step
                | step <- steps
                ]
            expectedJournal = concatMap satisfiedJournal steps
        run <- scriptedRunner journal probes []
        first <- runGuestBootstrapWith run target
        first @?= Right expectedResults
        readIORef journal >>= (@?= expectedJournal)
        second <- runGuestBootstrapWith run target
        second @?= Right expectedResults
        readIORef journal >>= (@?= expectedJournal ++ expectedJournal)
    , testCase "an empty frame runs every step's exact probe-action-verification journal" $ do
        journal <- newIORef []
        run <- scriptedRunner journal [] []
        outcome <- runGuestBootstrapWith run target
        outcome @?= Right (map GuestStepInstalled (guestBootstrapPlan target))
        readIORef journal >>= (@?= concatMap installedJournal (guestBootstrapPlan target))
    , testCase "an exit-zero rc floor report runs the package actions" $ do
        journal <- newIORef []
        let steps = guestBootstrapPlan target
            floorStep = stepOf FloorStep
            satisfied = [argvOf (stepProbe step) | step <- steps, stepKind step /= FloorStep]
            expected =
                [ if stepKind step `elem` [FloorStep, BootstrapperStep] then GuestStepInstalled step else GuestStepSatisfied step
                | step <- steps
                ]
        run <- scriptedRunner journal satisfied []
        outcome <- runGuestBootstrapWith run target
        outcome @?= Right expected
        readIORef journal
            >>= (@?= installedJournal floorStep ++ concatMap satisfiedJournal (drop 1 steps))
    , testCase "a failed action stops the run at its own step" $ do
        journal <- newIORef []
        let step = stepOf ToolchainStep
            failing = case map argvOf (stepActions step) of
                first : _ -> first
                [] -> error "the toolchain fixture has no action"
        run <- scriptedRunner journal [] [failing]
        outcome <- runGuestBootstrapWith run target
        outcome @?= Left ("guest bootstrap: " ++ stepLabel step ++ ": " ++ unwords failing ++ " exited ExitFailure 2 scripted action failed")
        readIORef journal
            >>= (@?= installedJournal (stepOf FloorStep) ++ [argvOf (stepProbe step), failing])
    , testCase "an unsettled probe after a successful action refuses" $ do
        journal <- newIORef []
        let step = stepOf FloorStep
            probe = argvOf (stepProbe step)
            neverSettles leaf = do
                modifyIORef' journal (++ [argvOf leaf])
                pure (Right (if argvOf leaf == probe then ExitFailure 1 else ExitSuccess, "", ""))
        outcome <- runGuestBootstrapWith neverSettles target
        outcome @?= Left ("guest bootstrap: " ++ stepLabel step ++ ": still not satisfied after its actions ran")
        readIORef journal >>= (@?= installedJournal step)
    , testCase "scripted probes settle only after their own ordered actions since their last failure" $ do
        journal <- newIORef []
        run <- scriptedRunner journal [] []
        let probe = stepProbe (stepOf FloorStep)
            missing = Right (ExitSuccess, removedFloorOutput, "")
            installed = Right (ExitSuccess, installedFloorOutput, "")
        run probe >>= (@?= missing)
        mapM_ run (stepActions (stepOf ToolchainStep))
        run probe >>= (@?= missing)
        case stepActions (stepOf FloorStep) of
            [update, install] -> do
                run update >> run probe >>= (@?= missing)
                run install >> run update >> run probe >>= (@?= missing)
                run update >> run install >> run probe >>= (@?= installed)
            other -> assertFailure ("expected two floor actions, got " ++ show other)
    , runnerErrorCase "a first-probe runner error retains the prefix and owning step" FloorStep 1
        (argvOf (stepProbe (stepOf FloorStep))) [argvOf (stepProbe (stepOf FloorStep))]
    , runnerErrorCase "a re-probe runner error retains the prefix and owning step" ToolchainStep 2
        (argvOf (stepProbe (stepOf ToolchainStep)))
        (installedJournal (stepOf FloorStep) ++ installedJournal (stepOf ToolchainStep))
    , runnerErrorCase "an action runner error retains the prefix and owning step" BootstrapperStep 1
        ["pipx", "install", "--force", "/root/hostbootstrap"]
        ( installedJournal (stepOf FloorStep) ++ installedJournal (stepOf ToolchainStep)
            ++ [["pipx", "install", "--force", "/root/hostbootstrap"]]
        )
    ]

runnerErrorCase :: String -> GuestStepKind -> Int -> [String] -> [[String]] -> TestTree
runnerErrorCase name owner occurrence failing expectedJournal =
    testCase name $ do
        journal <- newIORef []
        calls <- newIORef (0 :: Int)
        base <- scriptedRunner journal [] []
        let reason = "transport unavailable at " ++ name
            run leaf = do
                let argv = argvOf leaf
                if argv /= failing
                    then base leaf
                    else do
                        modifyIORef' calls (+ 1)
                        count <- readIORef calls
                        if count == occurrence
                            then do
                                modifyIORef' journal (++ [argv])
                                pure (Left reason)
                            else base leaf
        outcome <- runGuestBootstrapWith run target
        outcome @?= Left ("guest bootstrap: " ++ stepLabel (stepOf owner) ++ ": " ++ reason)
        readIORef journal >>= (@?= expectedJournal)
