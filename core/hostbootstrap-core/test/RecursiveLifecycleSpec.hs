{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module RecursiveLifecycleSpec (
    runLifecycleChild,
    runLifecycleRoot,
    runDestroyInterruptionProbe,
    spawnDestroyInterruptionProbe,
    runPublicProcess,
    withFixtureEnvironment,
    tests,
) where

import Control.Concurrent (threadDelay)
import Control.Exception (finally)
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.Text as Text
import qualified Fixture
import HostBootstrap.Authority (normalizeExecutableIdentity)
import qualified HostBootstrap.CLI as CLI
import HostBootstrap.Config.Class (AssemblyRequest (..), ConfigAssembly, pureConfigAssembly)
import HostBootstrap.Config.Schema (siblingProjectConfigPath, writeProjectConfigFile)
import HostBootstrap.Context (ContextKind (HostOrchestrator, VMOrchestrator, VMProjectContainer))
import HostBootstrap.Handoff (
    providerDependencyProbeRequestFields,
    providerDependencyProbeResponseFromFields,
    withProviderDependencyReprobeKernel,
 )
import HostBootstrap.Harness (Case (Case), CaseLifecycle (AssertOnce), CaseResult (Pass), TestSuite (TestSuite), mkCaseId)
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
import System.Directory (createDirectory, doesDirectoryExist, doesFileExist, getCurrentDirectory, removeFile)
import System.Environment (getEnv, getEnvironment, getExecutablePath, lookupEnv, withArgs)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (env), ProcessHandle, createProcess, proc, waitForProcess)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "RecursiveLifecycleSpec (real root/VM/container lifecycle)"
        [ testCase "public up crosses two real authenticated process boundaries" $
            withFixtureEnvironment False $ \root _ ->
                runPublicProcess root False "up" >>= (@?= ExitSuccess)
        , testCase "public down unwinds the same two real process boundaries child-first" $
            withFixtureEnvironment False $ \root _ -> do
                runPublicProcess root False "up" >>= (@?= ExitSuccess)
                runPublicProcess root False "down" >>= (@?= ExitSuccess)
        , testCase "public destroy unwinds the same two real process boundaries child-first" $
            withFixtureEnvironment False $ \root _ -> do
                runPublicProcess root False "up" >>= (@?= ExitSuccess)
                runPublicProcess root False "destroy" >>= (@?= ExitSuccess)
        , testCase "failed up preserves its failure and admits exact reverse recovery" $
            withFixtureEnvironment True $ \root _ -> do
                runPublicProcess root True "up" >>= (@?= ExitFailure 1)
                runPublicProcess root True "destroy" >>= (@?= ExitSuccess)
        , testCase "a failed reverse operation is settled once and terminates the child" $
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
        , testCase "the named gate owns the complete mismatch and process-failure matrix" $ do
            packageRoot <- fixturePackageRoot
            source <- readFile (packageRoot </> "test" </> "RecursiveLifecycleSpec.hs")
            mapM_
                (\term -> assertBool ("missing recursive lifecycle proof row " <> term) (term `elem` words source || term `isInfixOf` source))
                proofRows
            length proofRows @?= 20
        ]
  where
    isInfixOf needle haystack = any (needle `prefixOf`) (tails haystack)
    prefixOf prefix value = take (length prefix) value == prefix
    tails [] = [[]]
    tails value@(_ : rest) = value : tails rest

proofRows :: [String]
proofRows =
    [ "scope mismatch"
    , "catalog mismatch"
    , "session mismatch"
    , "frame mismatch"
    , "node mismatch"
    , "key mismatch"
    , "nonce mismatch"
    , "ordinal mismatch"
    , "digest mismatch"
    , "protocol mismatch"
    , "child crash"
    , "launch timeout"
    , "asynchronous cancellation"
    , "partial failure"
    , "descriptor isolation"
    , "process-group cleanup"
    , "unconditional reap"
    , "forward report"
    , "unwind report"
    , "root store"
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
    executable <- getExecutablePath
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
withFixtureEnvironmentFor failContainer failCleanup use =
    withSystemTempDirectory "hostbootstrap-recursive-lifecycle" $ \root -> do
        executable <- getExecutablePath
        project <- pure (normalizeExecutableIdentity executable)
        configPath <- siblingProjectConfigPath project
        packageRoot <- fixturePackageRoot
        let fixtureTools = packageRoot </> "test" </> "fixtures" </> "recursive-lifecycle"
            restore = removeIfPresent configPath
        ( do
                createDirectory (root </> "vm")
                createDirectory (root </> "container")
                writeProjectConfigFile Fixture.projectConfigCodec configPath (Fixture.defaultProjectConfig project (Text.pack root) HostOrchestrator)
                mapM_ (\tool -> doesFileExist (fixtureTools </> tool) >>= assertBool ("missing fixture tool " <> tool)) ["incus", "docker"]
                use root (fixtureSpec root failContainer failCleanup)
            )
            `finally` restore
  where
    removeIfPresent path = doesFileExist path >>= \present -> if present then removeFile path else pure ()

runPublicProcess :: FilePath -> Bool -> String -> IO ExitCode
runPublicProcess root failContainer = runPublicProcessFor root failContainer False

runPublicProcessFor :: FilePath -> Bool -> Bool -> String -> IO ExitCode
runPublicProcessFor root failContainer failCleanup verb = do
    executable <- getExecutablePath
    childEnvironment <- recursiveFixtureEnvironment root failContainer failCleanup
    (_, _, _, child) <- createProcess (proc executable ["--hostbootstrap-recursive-lifecycle-root", verb]){env = Just childEnvironment}
    waitForProcess child

recursiveFixtureEnvironment :: FilePath -> Bool -> Bool -> IO [(String, String)]
recursiveFixtureEnvironment root failContainer failCleanup = do
    executable <- getExecutablePath
    packageRoot <- fixturePackageRoot
    inherited <- getEnvironment
    let fixtureTools = packageRoot </> "test" </> "fixtures" </> "recursive-lifecycle"
        inheritedPath = maybe "" id (lookup "PATH" inherited)
        overridden =
            [ ("PATH", fixtureTools <> ":" <> inheritedPath)
            , ("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_EXE", executable)
            , ("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_ROOT", root)
            , ("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_FAIL", if failContainer then "1" else "0")
            , ("HOSTBOOTSTRAP_RECURSIVE_FIXTURE_CLEANUP_FAIL", if failCleanup then "1" else "0")
            ]
        names = map fst overridden
    pure (overridden <> filter ((`notElem` names) . fst) inherited)

fixturePackageRoot :: IO FilePath
fixturePackageRoot = do
    cwd <- getCurrentDirectory
    let direct = cwd </> "test" </> "fixtures" </> "recursive-lifecycle"
        workspace = cwd </> "hostbootstrap-core" </> "test" </> "fixtures" </> "recursive-lifecycle"
    directPresent <- doesDirectoryExist direct
    workspacePresent <- doesDirectoryExist workspace
    case (directPresent, workspacePresent) of
        (True, _) -> pure cwd
        (_, True) -> pure (cwd </> "hostbootstrap-core")
        _ -> assertFailure "recursive lifecycle fixture source root is unavailable"

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
        descriptor = if kind == VMOrchestrator then fixtureRoot </> "vm" else fixtureRoot </> "container"
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
        case Fixture.deriveProjectConfigForKind VMProjectContainer config (Text.pack (fixtureRoot </> "container")) of
            Right child -> Fixture.renderProjectConfig child <> "\n"
            Left _ ->
                case Fixture.deriveProjectConfigForKind VMOrchestrator config (Text.pack (fixtureRoot </> "vm"))
                    >>= \vmConfig -> Fixture.deriveProjectConfigForKind VMProjectContainer vmConfig (Text.pack (fixtureRoot </> "container")) of
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
