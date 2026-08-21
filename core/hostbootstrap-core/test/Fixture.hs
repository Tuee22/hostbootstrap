{-# LANGUAGE CPP #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoMonoLocalBinds #-}

{- | A core-internal project-config instance used by the core test suite.

The core is generic over a project's config type (the 'ProjectCfg' class); the
concrete config record lives in a consumer (the demo). The core tests need a
concrete 'ProjectCfg' to exercise the generic command/CLI machinery and the
generic sibling loader, so this module supplies a faithful in-test instance
(the same four-field shape the demo's @ProjectConfig@ has, so its reflected
Dhall schema and decode round-trips are equivalent coverage of what moved out
of core).
-}
module Fixture (
    FixtureProject,
    SecretFixtureProject,
    ProjectConfig (..),
    SecretProjectConfig (..),
    DeployConfig (..),
    Resources (..),
    TestConfig (..),
    defaultProjectConfig,
    defaultTestConfig,
    renderProjectConfig,
    decodeProjectConfigText,
    decodeProjectConfigFile,
    renderTestConfig,
    decodeTestConfigText,
    projectConfigSchemaText,
    projectConfigCodec,
    testConfigCodec,
    refusingForwardChildPlan,
    projectingForwardChildPlan,
    deriveProjectConfigForKind,
    projectConfigForRole,
    initArgsFor,
    projectInit,
    fixtureExecutableName,
    withFixtureInstalledProject,
    withFixtureProjectRoot,
    withFixtureProjectPlan,
    withFixtureProjectPlanContext,
    withFixtureHarnessProjectPlan,
    withFixtureHarnessAuthority,
    newFakeTool,
    newExhaustingFakeTool,
    newRecordingFakeTool,
    newRefusingFakeTool,
)
where

import Control.Monad (foldM)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Dhall (FromDhall, ToDhall)
import GHC.Generics (Generic)
import qualified HostBootstrap.Authority as Authority
import HostBootstrap.Config.Class (
    InitArgs (..),
    ProjectCfg (..),
    TestCfg (..),
    withMappedProjectCodec,
    withProjectCodec,
 )
import HostBootstrap.Config.Schema (withValidatedConfig)
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.Context (BinaryContext)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen (
    CodecWitness,
    autoCodecWitness,
    codecSchemaText,
    decodeFile,
    decodeText,
    renderHoistedValue,
    renderValue,
    requireCodecWitness,
 )
import HostBootstrap.Harness (VariantId, mkTestMatrix, mkVariantId, runWithOwnedRun, variantDraft)
import HostBootstrap.Harness.Ownership (
    protectedProjectRunOwnership,
    withOwnedHarnessRoot,
 )
import HostBootstrap.Lift.Context (LiftContext)
import HostBootstrap.Lifecycle.Mode (
    harnessActiveMode,
    harnessRootAuthority,
    harnessRootHarnessAuthority,
    harnessRootModeLease,
    harnessRootRunId,
    harnessRootUnboundLease,
    productionActiveMode,
    productionRootAuthority,
    productionRootModeLease,
    productionRootUnboundLease,
    withProductionLifecycleProfile,
    withProductionRoot,
    withHarnessLifecycleProfile,
 )
import HostBootstrap.ProjectPlan (
    ProjectPlan,
    planDraftsFromValidatedBuilder,
 )
import HostBootstrap.ProjectPlan.Construct (withProjectPlan)
import HostBootstrap.ProjectRoot (
    CanonicalProjectRoot,
    canonicalProjectRootPath,
    withCanonicalProjectRoot,
 )
import HostBootstrap.Protected (openProtectedStore)
import HostBootstrap.Step (Step, StepPlan, mkStepPlan)
import Numeric.Natural (Natural)
import System.Directory (getPermissions, setOwnerExecutable, setPermissions)
import System.Environment (getExecutablePath)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

{- | Acquire a real protected generative Harness root for authority-sensitive
tests. The helper fails if acquisition or finalization does not settle; it never
mints authority from a caller-selected run name.
-}
withFixtureHarnessAuthority ::
    forall result.
    ( forall projectId runId.
      Authority.InstalledProjectIdentity projectId ->
      V.HarnessAuthority projectId runId ->
      IO result
    ) ->
    IO result
withFixtureHarnessAuthority use =
    withFixtureInstalledProject $ \project ->
        withSystemTempDirectory "hostbootstrap-harness-authority" $ \root -> do
            rooted <-
                withCanonicalProjectRoot root root $ \canonicalRoot ->
                    runWithOwnedRun
                        ( protectedProjectRunOwnership
                            project
                            canonicalRoot
                            root
                            (root </> ".test_data")
                        )
                        ( \owned ->
                            withOwnedHarnessRoot owned $ \_store _project harnessRoot _closeControl ->
                                use project (harnessRootHarnessAuthority harnessRoot)
                        )
            outcome <- either (ioError . userError . show) pure rooted
            case outcome of
                Left reason -> ioError (userError reason)
                Right (result, Nothing) -> pure result
                Right (_, Just failure) ->
                    ioError (userError ("harness authority cleanup failed: " ++ show failure))

-- | The executable-verified name used by the core test binary.
fixtureExecutableName :: IO Text
fixtureExecutableName = Authority.normalizeExecutableIdentity <$> getExecutablePath

{- | Admit the actual test executable identity without allowing its generative
@projectId@ to escape the continuation.
-}
withFixtureInstalledProject ::
    (forall projectId. Authority.InstalledProjectIdentity projectId -> IO result) ->
    IO result
withFixtureInstalledProject use = do
    name <- fixtureExecutableName
    admitted <- Authority.withInstalledProjectIdentity name use
    either
        (ioError . userError . T.unpack . Authority.authorityErrorMessage)
        pure
        admitted

{- | Admit one real Production project plan for projection/reconciliation
tests while keeping every generated identity inside the callback.
-}
withFixtureProjectPlan ::
    StepPlan ->
    ( forall projectId specDigest planId configId.
      ProjectPlan
        (V.Production projectId)
        specDigest
        planId
        configId
        ProjectConfig ->
      IO result
    ) ->
    IO result
withFixtureProjectPlan stepPlan use =
    withFixtureProjectPlanContext id stepPlan (\plan _context -> use plan)

{- | Admit one real generative Harness project plan.  This follows the same
protected ownership/profile/config/plan path as the command rather than
relabeling a Production fixture.
-}
withFixtureHarnessProjectPlan ::
    StepPlan ->
    ( forall projectId runId specDigest planId configId.
      ProjectPlan
        (V.Harness projectId runId)
        specDigest
        planId
        configId
        ProjectConfig ->
      IO result
    ) ->
    IO result
withFixtureHarnessProjectPlan stepPlan use =
    withFixtureInstalledProject $ \project ->
        withSystemTempDirectory "hostbootstrap-fixture-harness-plan" $ \directory -> do
            rooted <-
                withCanonicalProjectRoot directory directory $ \ownershipRoot ->
                    runWithOwnedRun
                        ( protectedProjectRunOwnership
                            project
                            ownershipRoot
                            directory
                            (directory </> ".test_data")
                        )
                        ( \owned ->
                            withOwnedHarnessRoot owned $ \_store _ownedProject harnessRoot _closeControl -> do
                                let authority = harnessRootHarnessAuthority harnessRoot
                                scoped <-
                                    withCanonicalProjectRoot directory directory $ \runRoot -> do
                                        opened <-
                                            withHarnessLifecycleProfile
                                                (Authority.rootScopeAuthority (harnessRootAuthority harnessRoot))
                                                authority
                                                (harnessRootRunId harnessRoot)
                                                (harnessActiveMode (harnessRootModeLease harnessRoot))
                                                (harnessRootUnboundLease harnessRoot)
                                                ( \profile ->
                                                    withHarnessProjectCodec @ProjectConfig
                                                        (V.harnessConfigAuthority authority)
                                                        ( \codec -> do
                                                            let value =
                                                                    defaultProjectConfig
                                                                        (Authority.installedProjectName project)
                                                                        (T.pack (canonicalProjectRootPath runRoot))
                                                                        Context.TestHarness
                                                            validated <-
                                                                withValidatedConfig codec value $ \_wire config -> do
                                                                    drafts <-
                                                                        either
                                                                            (fail . show)
                                                                            pure
                                                                            ( planDraftsFromValidatedBuilder
                                                                                runRoot
                                                                                config
                                                                                (\_ _ -> Right stepPlan)
                                                                            )
                                                                    action <-
                                                                        either
                                                                            (fail . show)
                                                                            pure
                                                                            (withProjectPlan profile runRoot config drafts (pure . use))
                                                                    action
                                                            either fail pure validated
                                                        )
                                                )
                                        either (fail . show) id opened
                                either (fail . show) id scoped
                        )
            ownershipResult <- either (fail . show) pure rooted
            case ownershipResult of
                Left reason -> fail reason
                Right (result, Nothing) -> pure result
                Right (_, Just failure) -> fail ("Harness fixture cleanup failed: " ++ show failure)

{- | Admit one real Production project plan whose validated configuration
retains the exact context selected from the fixture's canonical host context.

The selected context is returned beside the plan so a test can feed that exact
value to 'HostBootstrap.ProjectPlan.Frame.withCurrentFrame'.  Child-frame tests
select it with 'Context.deriveVMContext' and 'Context.deriveContainerContext';
the compatibility wrapper above selects the root context unchanged.
-}
withFixtureProjectPlanContext ::
    (BinaryContext -> BinaryContext) ->
    StepPlan ->
    ( forall projectId specDigest planId configId.
      ProjectPlan
        (V.Production projectId)
        specDigest
        planId
        configId
        ProjectConfig ->
      BinaryContext ->
      IO result
    ) ->
    IO result
withFixtureProjectPlanContext selectContext stepPlan use =
    withSystemTempDirectory "hostbootstrap-fixture-project-plan" $ \directory -> do
        store <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
        withFixtureInstalledProject $ \project -> do
            rooted <-
                withCanonicalProjectRoot
                    (directory </> "fixture.dhall")
                    "."
                    ( \root ->
                        withProductionRoot store project Authority.ProjectUp $ \productionRoot -> do
                            opened <-
                                withProductionLifecycleProfile
                                    (Authority.rootScopeAuthority (productionRootAuthority productionRoot))
                                    (productionActiveMode (productionRootModeLease productionRoot))
                                    (productionRootUnboundLease productionRoot)
                                    ( \profile ->
                                        withProductionProjectCodec @ProjectConfig $ \codec -> do
                                            let rootValue =
                                                    defaultProjectConfig
                                                        (Authority.installedProjectName project)
                                                        (T.pack (canonicalProjectRootPath root))
                                                        Context.HostOrchestrator
                                                exactContext = selectContext rootValue.context
                                                value = rootValue{context = exactContext}
                                            validated <-
                                                withValidatedConfig codec value $ \_wire config -> do
                                                    drafts <-
                                                        either
                                                            (fail . show)
                                                            pure
                                                            ( planDraftsFromValidatedBuilder
                                                                root
                                                                config
                                                                (\_ _ -> Right stepPlan)
                                                            )
                                                    action <-
                                                        either
                                                            (fail . show)
                                                            pure
                                                            ( withProjectPlan
                                                                profile
                                                                root
                                                                config
                                                                drafts
                                                                (\plan -> use plan exactContext)
                                                            )
                                                    action
                                            either fail pure validated
                                    )
                            result <- either (fail . show) id opened
                            pure (Right result)
                    )
            modeResult <- either (fail . show) pure rooted
            either (fail . show) pure modeResult

data Resources = Resources
    { cpu :: Natural
    , memory :: Text
    , storage :: Text
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

newtype DeployConfig = DeployConfig
    { haReplicas :: Natural
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

newtype TestConfig = TestConfig
    { testResources :: Resources
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

instance TestCfg TestConfig where
    type TestVariant TestConfig = Text
    projectTestMatrix caseIds _ =
        mkTestMatrix
            caseIds
            [variantDraft defaultVariant "fixture-default", variantDraft alternateVariant "fixture-alternate"]
            [(cid, [defaultVariant, alternateVariant]) | cid <- caseIds]
      where
        defaultVariant = literalVariantId "default"
        alternateVariant = literalVariantId "alternate"

-- | Type-level identity for the core test fixture project.
data FixtureProject

-- | A second installed-project identity used by scope/secret API tests.
data SecretFixtureProject

data ProjectConfig scope = ProjectConfig
    { dockerfile :: Text
    , resources :: Resources
    , context :: BinaryContext
    , deploy :: DeployConfig
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

instance ProjectCfg ProjectConfig where
    withProductionProjectCodec =
        withProjectCodec "fixture/Production" projectConfigCodec
    withHarnessProjectCodec _ =
        withProjectCodec "fixture/Harness" projectConfigCodec
    cfgContext = context

{- | A secrets-strict project-owned config family. The secret field carries the
same scope index as the whole config and the type itself has no direct Dhall
decoder.
-}
data SecretProjectConfig scope = SecretProjectConfig
    { secretContext :: BinaryContext
    , secret :: V.SecretRef scope
    }
    deriving (Eq, Show)

data ProductionSecretProjectWire = ProductionSecretProjectWire
    { secretContext :: BinaryContext
    , secret :: V.ProductionSecretRefWire
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

data HarnessSecretProjectWire = HarnessSecretProjectWire
    { secretContext :: BinaryContext
    , secret :: V.HarnessSecretRefWire
    }
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

productionSecretProjectWireCodec :: CodecWitness ProductionSecretProjectWire
productionSecretProjectWireCodec =
    requireCodecWitness "fixture ProductionSecretProjectWire" autoCodecWitness

harnessSecretProjectWireCodec :: CodecWitness HarnessSecretProjectWire
harnessSecretProjectWireCodec =
    requireCodecWitness "fixture HarnessSecretProjectWire" autoCodecWitness

instance ProjectCfg SecretProjectConfig where
    withProductionProjectCodec =
        withMappedProjectCodec
            "fixture secrets/Production"
            productionSecretProjectWireCodec
            ( \(SecretProjectConfig cfgContext' cfgSecret) ->
                ProductionSecretProjectWire
                    cfgContext'
                    (V.productionSecretRefWire cfgSecret)
            )
            ( \(ProductionSecretProjectWire cfgContext' cfgSecret) ->
                Right
                    ( SecretProjectConfig
                        cfgContext'
                        (V.productionSecretRef cfgSecret)
                    )
            )
    withHarnessProjectCodec authority =
        withMappedProjectCodec
            "fixture secrets/Harness"
            harnessSecretProjectWireCodec
            ( \(SecretProjectConfig cfgContext' cfgSecret) ->
                HarnessSecretProjectWire
                    cfgContext'
                    (V.harnessSecretRefWire cfgSecret)
            )
            ( \(HarnessSecretProjectWire cfgContext' cfgSecret) ->
                Right
                    ( SecretProjectConfig
                        cfgContext'
                        (V.harnessSecretRef authority cfgSecret)
                    )
            )
    cfgContext (SecretProjectConfig cfgContext' _) = cfgContext'

projectConfigCodec :: CodecWitness (ProjectConfig scope)
projectConfigCodec =
    requireCodecWitness "fixture ProjectConfig" autoCodecWitness

testConfigCodec :: CodecWitness TestConfig
testConfigCodec =
    requireCodecWitness "fixture TestConfig" (autoCodecWitness @TestConfig)

-- | An explicitly installed projector for tests whose subject never reaches
-- forward-child planning.  It preserves the production requirement that a
-- real ProjectSpec installs exactly one projector without inventing runtime
-- projection coverage in unrelated fixtures.
refusingForwardChildPlan ::
    ProjectConfig scope ->
    Text ->
    Text ->
    LiftContext ->
    Either String (FilePath, ProjectConfig scope, StepPlan)
refusingForwardChildPlan _ _ _ _ =
    Left "the fixture does not exercise forward-child projection"

{- | A forward-child projector that really projects one VM descent.

The project-owned projector is the only function the immediate-target kernel
calls to obtain a child descriptor, configuration, and step plan, so a suite
whose every fixture refuses can never reach admitted recursive descent.  This
one derives the child configuration from the parent's own retained context
exactly as the kernel's expected-context derivation does, roots it at the
supplied canonical POSIX descriptor, and rebuilds the same declared chain so
the projected plan's frame labels, parent edges, and descent lifts are the
parent's own.
-}
projectingForwardChildPlan ::
    FilePath ->
    [Step] ->
    ProjectConfig scope ->
    Text ->
    Text ->
    LiftContext ->
    Either String (FilePath, ProjectConfig scope, StepPlan)
projectingForwardChildPlan descriptor steps parent _parentFrame _childFrame _route = do
    childConfig <-
        deriveProjectConfigForKind Context.VMOrchestrator parent (T.pack descriptor)
    childPlan <- either (Left . show) Right (mkStepPlan steps)
    Right (descriptor, childConfig, childPlan)

defaultResources :: Resources
defaultResources = Resources{cpu = 4, memory = "8GiB", storage = "20GiB"}

defaultDeployConfig :: DeployConfig
defaultDeployConfig = DeployConfig{haReplicas = 1}

defaultDockerfile :: Text
defaultDockerfile = "docker/Dockerfile"

projectConfigForRole ::
    Text ->
    Text ->
    Text ->
    Text ->
    Resources ->
    DeployConfig ->
    Context.ContextKind ->
    ProjectConfig scope
projectConfigForRole projectName binaryName root cfgDockerfile cfgResources cfgDeploy kind =
    ProjectConfig
        { dockerfile = cfgDockerfile
        , resources = cfgResources
        , context =
            Context.contextForKind
                projectName
                binaryName
                root
                kind
        , deploy = cfgDeploy
        }

projectConfigFromContext :: Text -> Resources -> DeployConfig -> Context.BinaryContext -> ProjectConfig scope
projectConfigFromContext cfgDockerfile cfgResources cfgDeploy cfgContext' =
    ProjectConfig
        { dockerfile = cfgDockerfile
        , resources = cfgResources
        , context = cfgContext'
        , deploy = cfgDeploy
        }

defaultProjectConfig :: Text -> Text -> Context.ContextKind -> ProjectConfig scope
defaultProjectConfig projectName root =
    projectConfigForRole projectName projectName root defaultDockerfile defaultResources defaultDeployConfig

defaultTestConfig :: Resources -> TestConfig
defaultTestConfig res = TestConfig{testResources = res}

literalVariantId :: Text -> VariantId
literalVariantId value =
    either (error . ("invalid fixture variant id: " ++) . show) id (mkVariantId value)

renderProjectConfig :: ProjectConfig scope -> Text
renderProjectConfig = renderHoistedValue projectConfigCodec Context.vocabUnions

decodeProjectConfigText :: Text -> IO (ProjectConfig scope)
decodeProjectConfigText = decodeText projectConfigCodec

decodeProjectConfigFile :: FilePath -> IO (ProjectConfig scope)
decodeProjectConfigFile = decodeFile projectConfigCodec

renderTestConfig :: TestConfig -> Text
renderTestConfig = renderValue testConfigCodec

decodeTestConfigText :: Text -> IO TestConfig
decodeTestConfigText = decodeText testConfigCodec

projectConfigSchemaText :: Text
projectConfigSchemaText = codecSchemaText projectConfigCodec

deriveProjectConfigForKind ::
    Context.ContextKind ->
    ProjectConfig scope ->
    Text ->
    Either String (ProjectConfig scope)
deriveProjectConfigForKind kind parent root
    | kind `notElem` Context.childContextKinds parentContext =
        Left $
            "project config: child context "
                <> show kind
                <> " is not allowed in "
                <> show (Context.contextKind parentContext)
    | otherwise =
        case kind of
            Context.HostOrchestrator ->
                Left "project config: host-orchestrator is not a child context"
            Context.VMOrchestrator ->
                projected (Context.deriveVMContext parentContext root)
            Context.VMProjectContainer ->
                projected (Context.deriveContainerContext parentContext root)
            Context.ImageBuildContainer ->
                Left "project config: image-build-container is not a child context"
            Context.ClusterService ->
                projected (Context.deriveServiceContext parentContext root)
            Context.Daemon ->
                projected (Context.deriveDaemonContext parentContext root)
            Context.OneShotJob ->
                projected (Context.deriveOneShotContext parentContext root)
            Context.TestHarness ->
                projected (Context.deriveTestHarnessContext parentContext root)
  where
    ProjectConfig
        { dockerfile = parentDockerfile
        , resources = parentResources
        , context = parentContext
        , deploy = parentDeploy
        } = parent
    projected = Right . projectConfigFromContext parentDockerfile parentResources parentDeploy

{- | The fixture's @init@ builder (mirrors the demo's @demoInit@), the only
default-bearing function: interpret the parsed flags into a 'ProjectConfig',
filling omitted knobs from the fixture defaults.
-}
projectInit :: Text -> InitArgs -> ProjectConfig scope
projectInit projectName args =
    let cfgResources =
            Resources
                { cpu = fromMaybe defaultResources.cpu args.mCpu
                , memory = fromMaybe defaultResources.memory args.memory
                , storage = fromMaybe defaultResources.storage args.storage
                }
        cfgDeploy = DeployConfig{haReplicas = fromMaybe defaultDeployConfig.haReplicas args.haReplicas}
        cfgDockerfile = fromMaybe defaultDockerfile args.dockerfile
        root = fromMaybe "." args.sourceRoot
        baseCfg =
            projectConfigForRole
                projectName
                projectName
                (T.pack root)
                cfgDockerfile
                cfgResources
                cfgDeploy
                args.role
     in case foldM (flip Context.addRole) baseCfg.context args.alsoRoles of
            Left err -> error (Context.contextErrorMessage err)
            Right ctx -> baseCfg{context = ctx}

-- | A defaultless 'InitArgs' for a chosen role (used by the spec builders).
initArgsFor :: Context.ContextKind -> InitArgs
initArgsFor kind =
    InitArgs
        { role = kind
        , alsoRoles = []
        , output = Nothing
        , sourceRoot = Just "/workspace/demo"
        , mCpu = Nothing
        , memory = Nothing
        , storage = Nothing
        , dockerfile = Nothing
        , haReplicas = Nothing
        , force = False
        , ifMissing = False
        }

{- | Admit a throwaway 'CanonicalProjectRoot' for tests that need the root the
plan is built under (§ X). It goes through the production
'withCanonicalProjectRoot' bracket against a real directory rather than
fabricating the opaque value, which the type does not permit anyway.
-}
withFixtureProjectRoot ::
    (forall rootScope rootId. CanonicalProjectRoot rootScope rootId -> IO a) ->
    IO a
withFixtureProjectRoot action =
    withSystemTempDirectory "hostbootstrap-fixture-root" $ \dir -> do
        outcome <- withCanonicalProjectRoot (dir </> "fixture.dhall") "." action
        either (fail . show) pure outcome

-- ---------------------------------------------------------------------------
-- Real tools a described command can be interpreted against

{- | Write one real executable that reports exactly the given text and exits zero.

A described command reaches a process by launching the tool the host
configuration resolves (§ KK), so a suite that wants a provider to have said a
particular thing gives the interpreter a real program to launch rather than a
stand-in for launching it (§ NN). The program is a shell script on a POSIX host
and a batch file on a Windows one, because those are the two things those hosts'
own process creation runs, and the returned path is absolute on both.

An empty report is a tool that says nothing at all, which is what a probe
answering only through its exit status looks like.
-}
newFakeTool ::
    -- | the directory the tool is written into
    FilePath ->
    -- | its base name, without a host-specific extension
    String ->
    -- | exactly what it writes to standard output, one line, or nothing
    String ->
    IO FilePath
newFakeTool directory name reported = do
    let path = directory </> fakeToolFileName name
    writeFile path (fakeToolProgram reported)
    makeFakeToolExecutable path
    pure path

fakeToolFileName :: String -> String
fakeToolProgram :: String -> String
makeFakeToolExecutable :: FilePath -> IO ()
#if defined(mingw32_HOST_OS)
fakeToolFileName name = name <> ".bat"
fakeToolProgram "" = "@echo off\n"
fakeToolProgram reported = "@echo off\necho " <> reported <> "\n"
makeFakeToolExecutable _ = pure ()
#else
fakeToolFileName = id
fakeToolProgram "" = "#!/bin/sh\nexit 0\n"
fakeToolProgram reported = "#!/bin/sh\nprintf '%s\\n' " <> show reported <> "\n"
makeFakeToolExecutable path =
    getPermissions path >>= setPermissions path . setOwnerExecutable True
#endif

{- | Write one real executable that answers once and refuses every call after.

Some contracts are about what happens when a probe that answered a moment ago
stops answering. A tool that decides that from its own durable state needs no
substitution point in the code under test: the first call is the readiness
observation and the second is the reprobe, and both are real processes (§ NN).
-}
newExhaustingFakeTool ::
    -- | the directory the tool is written into
    FilePath ->
    -- | its base name, without a host-specific extension
    String ->
    -- | exactly what its one successful call writes to standard output
    String ->
    -- | the diagnostic every later call writes to standard error
    String ->
    IO FilePath
newExhaustingFakeTool directory name reported diagnostic = do
    let path = directory </> fakeToolFileName name
    writeFile path (exhaustingToolProgram reported diagnostic)
    makeFakeToolExecutable path
    pure path

exhaustingToolProgram :: String -> String -> String
#if defined(mingw32_HOST_OS)
exhaustingToolProgram reported diagnostic =
    unlines
        [ "@echo off"
        , "if exist \"%~f0.calls\" ("
        , "  echo " <> diagnostic <> " 1>&2"
        , "  exit /b 1"
        , ")"
        , "type nul > \"%~f0.calls\""
        , "echo " <> reported
        ]
#else
exhaustingToolProgram reported diagnostic =
    unlines
        [ "#!/bin/sh"
        , "calls=\"$0.calls\""
        , "if [ -f \"$calls\" ]; then"
        , "  printf '%s\\n' " <> show diagnostic <> " >&2"
        , "  exit 1"
        , "fi"
        , ": > \"$calls\""
        , "printf '%s\\n' " <> show reported
        ]
#endif

{- | Write one real executable that records that it ran, then answers as told.

Ordering is a contract: a readiness observation that reaches the provisioning
egress before it has admitted the root has taken a step it was not entitled to.
The tool writing its own name into a shared log makes that order an observation
of real processes rather than of a counter beside them (§ NN).
-}
newRecordingFakeTool ::
    -- | the directory the tool is written into
    FilePath ->
    -- | its base name, without a host-specific extension
    String ->
    -- | exactly what it writes to standard output, one line, or nothing
    String ->
    -- | the status it exits with
    Int ->
    -- | the log it appends its own name to
    FilePath ->
    IO FilePath
newRecordingFakeTool directory name reported status logPath = do
    let path = directory </> fakeToolFileName name
    writeFile path (recordingToolProgram name reported status logPath)
    makeFakeToolExecutable path
    pure path

recordingToolProgram :: String -> String -> Int -> FilePath -> String
#if defined(mingw32_HOST_OS)
recordingToolProgram name reported status logPath =
    unlines
        ( [ "@echo off"
          , "echo " <> name <> ">>\"" <> logPath <> "\""
          ]
            <> ["echo " <> reported | not (null reported)]
            <> ["exit /b " <> show status]
        )
#else
recordingToolProgram name reported status logPath =
    unlines
        ( [ "#!/bin/sh"
          , "printf '%s\\n' " <> show name <> " >> " <> show logPath
          ]
            <> ["printf '%s\\n' " <> show reported | not (null reported)]
            <> ["exit " <> show status]
        )
#endif

{- | Write one real executable that answers every verb but the named one.

A client whose provisioning egress is unavailable and one whose daemon has
stopped answering are different contracts, and both are properties of the
program the interpreter launches rather than of a seam beside it (§ NN). The
verb is matched against the first argument, which is where every command in this
project's provider vocabulary carries it.
-}
newRefusingFakeTool ::
    -- | the directory the tool is written into
    FilePath ->
    -- | its base name, without a host-specific extension
    String ->
    -- | the first argument it refuses
    String ->
    -- | the diagnostic it writes to standard error when it refuses
    String ->
    IO FilePath
newRefusingFakeTool directory name refused diagnostic = do
    let path = directory </> fakeToolFileName name
    writeFile path (refusingToolProgram refused diagnostic)
    makeFakeToolExecutable path
    pure path

refusingToolProgram :: String -> String -> String
#if defined(mingw32_HOST_OS)
refusingToolProgram refused diagnostic =
    unlines
        [ "@echo off"
        , "if \"%1\"==\"" <> refused <> "\" ("
        , "  echo " <> diagnostic <> " 1>&2"
        , "  exit /b 1"
        , ")"
        , "exit /b 0"
        ]
#else
refusingToolProgram refused diagnostic =
    unlines
        [ "#!/bin/sh"
        , "if [ \"$1\" = " <> show refused <> " ]; then"
        , "  printf '%s\\n' " <> show diagnostic <> " >&2"
        , "  exit 1"
        , "fi"
        , "exit 0"
        ]
#endif
