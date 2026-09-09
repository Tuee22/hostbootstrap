{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module RecursiveLifecycleSpec (
    runLifecycleChild,
    runLifecycleFixtureClient,
    runLifecycleRoot,
    runDestroyInterruptionProbe,
    spawnDestroyInterruptionProbe,
    runPublicProcess,
    withFixtureEnvironment,
    withLocalGuestFrame,
    tests,
) where

import Control.Concurrent (threadDelay)
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.Char (toUpper)
import Data.IORef (modifyIORef', newIORef, readIORef)
import qualified Data.Text as Text
import qualified Fixture
import HostBootstrap.Authority (normalizeExecutableIdentity)
import qualified HostBootstrap.CLI as CLI
import HostBootstrap.Config.Class (AssemblyRequest (..), ConfigAssembly, pureConfigAssembly)
import HostBootstrap.Config.Schema (writeProjectConfigFile)
import HostBootstrap.Context (ContextKind (HostOrchestrator, VMOrchestrator, VMProjectContainer))
import HostBootstrap.Handoff (
    providerDependencyProbeRequestFields,
    providerDependencyProbeResponseFromFields,
    withProviderDependencyReprobeKernel,
 )
import HostBootstrap.Harness (Case (Case), CaseLifecycle (AssertOnce), CaseResult (Pass), TestSuite (TestSuite), mkCaseId)
import HostBootstrap.Identity.Install (provisionInstalledIdentity)
import HostBootstrap.Lift.Context (
    ConfigDelivery (ConfigDelivery),
    ContainerLift (ContainerLift),
    ContainerPlacement (ProviderGuestContainer),
    IncusVM (IncusVM),
    LiftContext,
    inContainer,
    inVM,
    localContext,
 )
import HostBootstrap.Ownership.Object (OwnershipFault (OwnershipUnsupported))
import HostBootstrap.Ownership.Posix (posixOwnershipRow, posixOwnershipSupported)
import HostBootstrap.Ownership.Primitive (OwnershipPrimitive (rowObserveIdentity), withOwnershipRow)
import HostBootstrap.Step (
    ProjectStepId,
    ReversePolicy (ProjectManagedReverse),
    Step,
    StepFrame (StepFrame),
    StepObservation (StepChanged, StepConflict),
    StepPlan,
    TeardownOutcome (TeardownFailed, TeardownReleased),
    descendsVia,
    mkStepPlan,
    projectStep,
    projectStepId,
    reversedBy,
 )
import PlatformPath (hostPathAsPosixDescriptor)
import System.Directory (copyFile, createDirectory, createDirectoryIfMissing, doesFileExist)
import System.Environment (getEnv, getEnvironment, getExecutablePath, lookupEnv, withArgs)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitWith)
import System.FilePath (searchPathSeparator, takeFileName, (<.>), (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Info (os)
import System.Process (CreateProcess (env), ProcessHandle, createProcess, proc, rawSystem, readCreateProcessWithExitCode, waitForProcess)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "RecursiveLifecycleSpec (real root/VM/container lifecycle)"
        [ testCase "public up crosses two real authenticated process boundaries" $
            withLocalGuestFrame $
                withFixtureEnvironment False $ \root _ ->
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
        , testCase "public down unwinds the same two real process boundaries child-first" $
            withLocalGuestFrame $
                withFixtureEnvironment False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    runPublicProcess root False "down" >>= (@?= ExitSuccess)
        , testCase "public destroy unwinds the same two real process boundaries child-first" $
            withLocalGuestFrame $
                withFixtureEnvironment False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    runPublicProcess root False "destroy" >>= (@?= ExitSuccess)
        , testCase "public down then destroy preserves the recursive source across separate root processes" $
            withLocalGuestFrame $
                withFixtureEnvironment False $ \root _ -> do
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    runPublicProcess root False "down" >>= (@?= ExitSuccess)
                    runPublicProcess root False "down" >>= (@?= ExitSuccess)
                    runPublicProcess root False "destroy" >>= (@?= ExitSuccess)
                    runPublicProcess root False "destroy" >>= (@?= ExitSuccess)
                    runPublicProcess root False "up" >>= (@?= ExitSuccess)
                    runPublicProcess root False "destroy" >>= (@?= ExitSuccess)
        , testCase "failed up preserves its failure and admits exact reverse recovery" $
            withLocalGuestFrame $
                withFixtureEnvironment True $ \root _ -> do
                    runPublicProcess root True "up" >>= (@?= ExitFailure 1)
                    runPublicProcess root True "destroy" >>= (@?= ExitSuccess)
        , testCase "a failed reverse operation is settled once and terminates the child" $
            withLocalGuestFrame $
                withFixtureEnvironmentFor False True $ \root _ -> do
                    runPublicProcessFor root False True "up" >>= (@?= ExitSuccess)
                    runPublicProcessFor root False True "destroy" >>= (@?= ExitFailure 1)
                    attempts <- lines <$> readFile (root </> "reverse-attempts")
                    length (filter (== "container") attempts) @?= 1
        , testCase "the local provider reprobe kernel returns only nonce-bound observation data" $ do
            let package = ByteStringChar8.pack "35:hostbootstrap/runtime-dependency/v18:provider4:plan5:scope8:resource5:frame6:origin1:77:journal7:receipt26:runtime://provider/reprobe3:100"
            request <- either (assertFailure . Text.unpack) pure (providerDependencyProbeRequestFields package "recursive-nonce")
            withProviderDependencyReprobeKernel
                package
                "plan"
                "scope"
                "resource"
                "frame"
                "origin"
                7
                "journal"
                "receipt"
                "runtime://provider/reprobe"
                99
                (pure (Right 7))
                $ \answer -> do
                    response <- answer request >>= either (assertFailure . Text.unpack) pure
                    providerDependencyProbeResponseFromFields package "recursive-nonce" response @?= Right (Right 7)
        , testCase "a replayed provider nonce refuses before another live observation" $ do
            calls <- newIORef (0 :: Int)
            let package = ByteStringChar8.pack "35:hostbootstrap/runtime-dependency/v18:provider4:plan5:scope8:resource5:frame6:origin1:77:journal7:receipt26:runtime://provider/reprobe3:100"
            request <- either (assertFailure . Text.unpack) pure (providerDependencyProbeRequestFields package "one-use-nonce")
            withProviderDependencyReprobeKernel
                package "plan" "scope" "resource" "frame" "origin" 7 "journal" "receipt"
                "runtime://provider/reprobe" 99
                (modifyIORef' calls (+ 1) >> pure (Right 7))
                $ \answer -> do
                    first <- answer request >>= either (assertFailure . Text.unpack) pure
                    providerDependencyProbeResponseFromFields package "one-use-nonce" first @?= Right (Right 7)
                    second <- answer request >>= either (assertFailure . Text.unpack) pure
                    providerDependencyProbeResponseFromFields package "one-use-nonce" second
                        @?= Right (Left "provider dependency probe nonce was replayed")
                    readIORef calls >>= (@?= 1)
        ]

-- | The actual test executable is also the installed child binary.
runLifecycleChild :: IO ()
runLifecycleChild = do
    project <- normalizeExecutableIdentity <$> getExecutablePath
    root <- getEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_ROOT"
    failContainer <- (== Just "1") <$> lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_FAIL"
    failCleanup <- (== Just "1") <$> lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_CLEANUP_FAIL"
    withArgs ["--hostbootstrap-lifecycle-child"] $
        CLI.runHostBootstrapCLI (Text.unpack project) (fixtureSpec root failContainer failCleanup)

{- | Re-enter the public command in a process whose host-tool discovery sees
only the fixture's explicit environment, leaving the suite process alone.
-}
runLifecycleRoot :: String -> IO ()
runLifecycleRoot verb = do
    project <- normalizeExecutableIdentity <$> getExecutablePath
    root <- getEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_ROOT"
    failContainer <- (== Just "1") <$> lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_FAIL"
    failCleanup <- (== Just "1") <$> lookupEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_CLEANUP_FAIL"
    withArgs ["project", verb] $
        CLI.runHostBootstrapCLI (Text.unpack project) (fixtureSpec root failContainer failCleanup)

runDestroyInterruptionProbe :: FilePath -> IO ()
runDestroyInterruptionProbe readyPath = do
    runLifecycleRoot "destroy"
    writeFile readyPath "destroy-settled"
    threadDelay 600000000

spawnDestroyInterruptionProbe :: FilePath -> FilePath -> IO ProcessHandle
spawnDestroyInterruptionProbe root readyPath = do
    executable <- fixtureExecutable root
    childEnvironment <- recursiveFixtureEnvironment root False False
    (_, _, _, child) <-
        createProcess
            (proc executable ["--hostbootstrap-destroy-interruption-probe", readyPath])
                { env = Just childEnvironment
                }
    pure child

withFixtureEnvironment :: Bool -> (FilePath -> CLI.ProjectSpec Fixture.ProjectConfig Fixture.TestConfig -> IO result) -> IO result
withFixtureEnvironment failContainer = withFixtureEnvironmentFor failContainer False

withFixtureEnvironmentFor :: Bool -> Bool -> (FilePath -> CLI.ProjectSpec Fixture.ProjectConfig Fixture.TestConfig -> IO result) -> IO result
withFixtureEnvironmentFor failContainer failCleanup use = do
    source <- getExecutablePath
    -- Keep the installed fixture and its project root together, outside the
    -- deeply nested Cabal output path and within every child's native anchor.
    withSystemTempDirectory "hostbootstrap-recursive" $ \root -> do
        executable <- fixtureExecutable root
        copyFile source executable
        provisionInstalledIdentity executable >>= either assertFailure pure
        let project = normalizeExecutableIdentity executable
            configPath = root </> Text.unpack project <.> "dhall"
        fixtureTools <- prepareRecursiveFixtureTools root
        createDirectory (root </> "vm")
        createDirectory (root </> "container")
        writeProjectConfigFile Fixture.projectConfigCodec configPath (Fixture.defaultProjectConfig project (Text.pack root) HostOrchestrator)
        let suffix = if os == "mingw32" then ".exe" else ""
        mapM_ (\tool -> doesFileExist (fixtureTools </> (tool <> suffix)) >>= assertBool ("missing fixture tool " <> tool)) ["incus", "docker"]
        use root (fixtureSpec root failContainer failCleanup)

fixtureExecutable :: FilePath -> IO FilePath
fixtureExecutable root = (root </>) . takeFileName <$> getExecutablePath

runPublicProcess :: FilePath -> Bool -> String -> IO ExitCode
runPublicProcess root failContainer = runPublicProcessFor root failContainer False

runPublicProcessFor :: FilePath -> Bool -> Bool -> String -> IO ExitCode
runPublicProcessFor root failContainer failCleanup verb = do
    executable <- fixtureExecutable root
    childEnvironment <- recursiveFixtureEnvironment root failContainer failCleanup
    (_, _, _, child) <- createProcess (proc executable ["--hostbootstrap-recursive-lifecycle-root", verb]){env = Just childEnvironment}
    waitForProcess child

recursiveFixtureEnvironment :: FilePath -> Bool -> Bool -> IO [(String, String)]
recursiveFixtureEnvironment root failContainer failCleanup = do
    executable <- fixtureExecutable root
    inherited <- getEnvironment
    fixtureTools <- prepareRecursiveFixtureTools root
    let
        inheritedPath = maybe "" id (lookup "PATH" [(map toUpper name, value) | (name, value) <- inherited])
        overridden =
            [ ("PATH", fixtureTools <> [searchPathSeparator] <> inheritedPath)
            , ("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_EXE", executable)
            , ("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_ROOT", root)
            , ("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_FAIL", if failContainer then "1" else "0")
            , ("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_CLEANUP_FAIL", if failCleanup then "1" else "0")
            ]
        names = map (map toUpper . fst) overridden
    pure (overridden <> filter ((`notElem` names) . map toUpper . fst) inherited)

prepareRecursiveFixtureTools :: FilePath -> IO FilePath
prepareRecursiveFixtureTools root = do
    let tools = root </> "fixture-tools"
        suffix = if os == "mingw32" then ".exe" else ""
    createDirectoryIfMissing True tools
    executable <- getExecutablePath
    mapM_
        ( \tool -> do
            let path = tools </> (tool <> suffix)
            present <- doesFileExist path
            if present then pure () else copyFile executable path
        )
        ["incus", "docker"]
    pure tools

{- | A native client proxy keeps the installed binary's identity and inherited
protocol pipes intact. It exercises transport, not a live provider substrate.
-}
runLifecycleFixtureClient :: IO ()
runLifecycleFixtureClient = do
    executable <- getEnv "HOSTBOOTSTRAP_RECURSIVE_FIXTURE_EXE"
    rawSystem executable ["--hostbootstrap-recursive-lifecycle-child"] >>= exitWith

fixtureSpec :: FilePath -> Bool -> Bool -> CLI.ProjectSpec Fixture.ProjectConfig Fixture.TestConfig
fixtureSpec fixtureRoot failContainer failCleanup =
    either (error . show) id $
        CLI.finalizeProjectSpec $
            CLI.addSteps (\_ config -> fixtureSteps fixtureRoot failContainer failCleanup config) $
                CLI.addForwardChildPlan (projectChild fixtureRoot failContainer failCleanup) $
                    CLI.projectSpec passingSuite (pure ()) [] Fixture.testConfigCodec fixtureTestInit fixtureAssemble

projectChild :: FilePath -> Bool -> Bool -> Fixture.ProjectConfig scope -> Text.Text -> Text.Text -> LiftContext -> Either String (FilePath, Fixture.ProjectConfig scope, StepPlan)
projectChild fixtureRoot failContainer failCleanup parent _parent child _route = do
    let kind = if child == "vm-orchestrator-1" then VMOrchestrator else VMProjectContainer
        descriptor = projectDescriptorRoot fixtureRoot <> if kind == VMOrchestrator then "/vm" else "/container"
    config <- Fixture.deriveProjectConfigForKind kind parent (Text.pack descriptor)
    plan <- either (Left . show) Right (mkStepPlan (fixtureSteps fixtureRoot failContainer failCleanup config))
    pure (descriptor, config, plan)

fixtureSteps :: FilePath -> Bool -> Bool -> Fixture.ProjectConfig scope -> [Step]
fixtureSteps fixtureRoot failContainer failCleanup config =
    [ reversible "root" $ descendsVia (inVM (IncusVM "fixture-vm" "fixture:image") localContext) (node "root" "host-orchestrator-0" StepChanged)
    , reversible "vm" $ descendsVia (inContainer _container localContext) (node "vm" "vm-orchestrator-1" StepChanged)
    , reversible "container" $ node "container" "vm-project-container-2" (if failContainer then StepConflict "ready" "failed" "fixture failure" else StepChanged)
    ]
  where
    reversible name = reversedBy $ \_ _ -> do
        appendFile (fixtureRoot </> "reverse-attempts") (name <> "\n")
        pure $
            if failCleanup && name == "container"
                then TeardownFailed "fixture cleanup failure"
                else TeardownReleased
    deliveryPayload =
        case Fixture.deriveProjectConfigForKind VMProjectContainer config (Text.pack (projectDescriptorRoot fixtureRoot <> "/container")) of
            Right child -> Fixture.renderProjectConfig child <> "\n"
            Left _ ->
                case Fixture.deriveProjectConfigForKind VMOrchestrator config (Text.pack (projectDescriptorRoot fixtureRoot <> "/vm"))
                    >>= \vmConfig -> Fixture.deriveProjectConfigForKind VMProjectContainer vmConfig (Text.pack (projectDescriptorRoot fixtureRoot <> "/container")) of
                    Right child -> Fixture.renderProjectConfig child <> "\n"
                    Left _ -> Fixture.renderProjectConfig config <> "\n"
    _container =
        ContainerLift
            "fixture:image"
            ProviderGuestContainer
            []
            []
            True
            (Just (ConfigDelivery "/workspace/container/project.dhall" "/workspace/container/pb" deliveryPayload))

projectDescriptorRoot :: FilePath -> FilePath
projectDescriptorRoot = hostPathAsPosixDescriptor

{- | The local process fixture represents POSIX guest frames. Where that row
cannot execute locally, assert its actual refusal and then prove that the
native receiver rejects the incompatible canonical root before child work.
CoverageManifest reports these outcomes separately from recursive execution.
-}
withLocalGuestFrame :: IO () -> IO ()
withLocalGuestFrame action
    | posixOwnershipSupported = action
    | otherwise = withFixtureEnvironment False $ \root _ -> do
        observed <- withOwnershipRow posixOwnershipRow $ \row -> rowObserveIdentity row (root </> "vm")
        case observed of
            Left (OwnershipUnsupported _) -> pure ()
            other -> assertFailure ("expected the guest row's declared refusal, got " ++ show other)
        executable <- fixtureExecutable root
        childEnvironment <- recursiveFixtureEnvironment root False False
        (status, _, diagnostic) <-
            readCreateProcessWithExitCode
                (proc executable ["--hostbootstrap-recursive-lifecycle-root", "up"]){env = Just childEnvironment}
                ""
        status @?= ExitFailure 1
        assertBool
            "the native receiver refuses the different guest-root snapshot"
            ( "PlanHandoffEvidenceMismatch" `Text.isInfixOf` Text.pack diagnostic
                && "stable plan digest" `Text.isInfixOf` Text.pack diagnostic
            )

node :: String -> String -> StepObservation -> Step
node name frame observation =
    projectStep (stepId name) ProjectManagedReverse name (StepFrame frame frame) (const (pure observation))

stepId :: String -> ProjectStepId
stepId = either error id . projectStepId

passingSuite :: TestSuite
passingSuite = TestSuite (pure (Right ())) (\_ _ -> pure ()) [Case (either (error . show) id (mkCaseId "ok")) 1 False AssertOnce] (\_ _ -> pure Pass) (pure ())

fixtureTestInit :: a -> Fixture.TestConfig
fixtureTestInit _ = Fixture.defaultTestConfig (Fixture.Resources 1 "1GiB" "1GiB")

fixtureAssemble :: forall projectId scope. AssemblyRequest projectId Fixture.TestConfig Text.Text scope -> ConfigAssembly scope (Fixture.ProjectConfig scope)
fixtureAssemble request = case request of
    ProductionAssembly args -> pureConfigAssembly (Fixture.projectInit "recursive" args)
    HarnessAssembly _ _ _ _ -> pureConfigAssembly (Fixture.defaultProjectConfig "recursive" "/workspace" HostOrchestrator)
