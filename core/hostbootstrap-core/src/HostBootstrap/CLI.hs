{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

{- | The fixed @optparse-applicative@ command tree and the generic entrypoints
project binaries use to extend it.

The command surface is **fixed and closed** (development_plan_standards § P):
every project binary — and the bare @hostbootstrap@ binary — surfaces the same
tree: @project@, @test@, @service@, @context@, and @check-code@. There are no
hidden commands. @hostbootstrap-core@ is a **library of composable tools**,
including the @ensure@ reconciler primitives a project runs as @ensure-*@ chain
steps, not a CLI topology, so a project never adds a command. A project extends
the core only through the checked builder streams finalized into 'ProjectSpec':
ordered steps, schema artifacts, its test suite, a typed service registry, its
@check-code@ action, and the project-owned restricted config assembler plus its
distinct test-config initializer.

A project binary calls 'runHostBootstrapCLI' with an already finalized opaque
'ProjectSpec'. Finalization validates the extension points (a non-empty test
suite and step contribution; unique test cases, artifacts, assembly inputs,
step identities, frames, and services) and then merges
the spec into the core command tree ('HostBootstrap.Command.coreCommands'). The
bare @hostbootstrap@ binary (built like any project binary, not baked into the
base image) uses the separate 'runBareHostBootstrapCLI'. See
@documents/architecture/hostbootstrap_core_library.md@.
-}
module HostBootstrap.CLI (
    ProjectSpec,
    ProjectSpecBuilder,
    ProjectSpecError (..),
    projectSpec,
    addArtifacts,
    addAssemblyInputs,
    addSteps,
    addServices,
    finalizeProjectSpec,
    projectServiceVariantNames,
    projectArtifactNames,
    projectStepPlan,
    runHostBootstrapCLI,
    runBareHostBootstrapCLI,
)
where

import Control.Monad (foldM, join, unless)
import Data.Char (toLower)
import Data.List (group, sort)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Dhall (FromDhall, ToDhall)
import GHC.Generics (Generic)
import HostBootstrap.Command (coreCommands)
import HostBootstrap.Config.Class (
    AssemblyRequest (..),
    ConfigAssembly,
    ConfigInput,
    configInputPath,
    InitArgs (..),
    ProjectCfg (..),
    ProjectCodec,
    TestCfg (..),
    failConfigAssembly,
    pureConfigAssembly,
    runConfigAssembly,
    withProjectCodec,
 )
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Config.Fields (ScopeKind (ProductionScope))
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen (
    CodecWitness,
    ConfigArtifact,
    artifactName,
    autoCodecWitness,
    coreArtifacts,
    requireCodecWitness,
 )
import HostBootstrap.Harness (TestSuite, caseIdText, emptySuite, testSuiteCaseCount, testSuiteCaseIds)
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)
import HostBootstrap.Service (
    FinalizedServiceRegistry,
    ServiceRegistry,
    ServiceRegistryError,
    emptyServiceRegistry,
    mergeServiceRegistries,
    serviceVariantNames,
    withFinalizedServiceRegistry,
 )
import HostBootstrap.Step (Step, StepPlan, StepPlanError (..), mkStepPlan)
import Options.Applicative
import System.Environment (getProgName)
import System.Exit (die)
import System.FilePath (dropExtension, takeExtension, takeFileName)
import System.IO (hSetEncoding, stderr, stdout, utf8)

{- | A derived project's required extension points, generic over the project's
config type @cfg@ and the project's test-config type @tcfg@. There are no
per-project commands: the surface is fixed (§ P). A project supplies its runtime
test suite, code-check action, schema artifact delta, lift chain (whose steps
carry their own descent and their own reverse effect, § W), service-handler
registry, one scope-aware restricted project-config assembler, and its
test-config initializer. The bare core binary uses 'runBareHostBootstrapCLI' instead.
-}
data ProjectSpec projectId cfg tcfg = ProjectSpec
    { psTestSuite :: TestSuite
    , psCheckCode :: IO ()
    , psArtifacts :: [ConfigArtifact]
    , psTestCodec :: CodecWitness tcfg
    , psAssemblyInputs :: [ConfigInput]
    , psServices :: ServiceRegistry (cfg (Production projectId))
    , psStepPlan ::
        forall rootScope rootId.
        CanonicalProjectRoot rootScope rootId ->
        cfg (Production projectId) ->
        Either StepPlanError StepPlan
    {- ^ The one validated plan. It is built under the admitted
    'CanonicalProjectRoot' (§ X), so every step — its forward action and the
    descent it declares — derives its project-relative paths from that one
    authority rather than from @cwd@ or a serialized path.
    -}
    , psTestInit :: InitArgs -> tcfg
    {- ^ Interpret the parsed @init@ flags into the project's test config
    (@test init@) — needs no pre-existing project config.
    -}
    , psAssemble ::
        forall scope.
        AssemblyRequest projectId tcfg (TestVariant tcfg) scope ->
        ConfigAssembly scope (cfg scope)
    {- ^ The sole default-bearing project-config assembler. Its closed request
    separates Production init from one exact generative Harness run; its
    restricted effect permits only declared config reads.
    -}
    }

newtype StepFragment projectId cfg = StepFragment
    { runStepFragment ::
        forall rootScope rootId.
        CanonicalProjectRoot rootScope rootId ->
        cfg (Production projectId) ->
        [Step]
    }

{- | Opaque unfinished project specification. It cannot be dispatched. Step and
service contributions are additive, and each step carries its own descent and
reverse effect, so there is no lifecycle slot beside the plan.
-}
data ProjectSpecBuilder projectId cfg tcfg = ProjectSpecBuilder
    { pbTestSuite :: TestSuite
    , pbCheckCode :: IO ()
    , pbArtifacts :: [ConfigArtifact]
    , pbTestCodec :: CodecWitness tcfg
    , pbAssemblyInputs :: [ConfigInput]
    , pbStepFragments :: [StepFragment projectId cfg]
    , pbServiceRegistries :: [ServiceRegistry (cfg (Production projectId))]
    , pbTestInit :: InitArgs -> tcfg
    , pbAssemble ::
        forall scope.
        AssemblyRequest projectId tcfg (TestVariant tcfg) scope ->
        ConfigAssembly scope (cfg scope)
    }

data ProjectSpecError
    = EmptyProjectTestSuite
    | DuplicateProjectCaseIds [T.Text]
    | CoreArtifactShadowing [String]
    | DuplicateProjectArtifacts [String]
    | DuplicateAssemblyInputs [FilePath]
    | MissingStepPlan
    | InvalidServiceRegistry ServiceRegistryError
    deriving (Eq, Show)

{- | Start an unfinished project spec from the streams that are intrinsically
single values. It still needs steps before finalization.
-}
projectSpec ::
    TestSuite ->
    IO () ->
    [ConfigArtifact] ->
    CodecWitness tcfg ->
    (InitArgs -> tcfg) ->
    ( forall scope.
      AssemblyRequest projectId tcfg (TestVariant tcfg) scope ->
      ConfigAssembly scope (cfg scope)
    ) ->
    ProjectSpecBuilder projectId cfg tcfg
projectSpec suite check arts testCodec testInit assemble =
    ProjectSpecBuilder
        { pbTestSuite = suite
        , pbCheckCode = check
        , pbArtifacts = arts
        , pbTestCodec = testCodec
        , pbAssemblyInputs = []
        , pbStepFragments = []
        , pbServiceRegistries = []
        , pbTestInit = testInit
        , pbAssemble = assemble
        }

-- | Add schema/artifact contributions without replacing prior layers.
addArtifacts ::
    [ConfigArtifact] ->
    ProjectSpecBuilder projectId cfg tcfg ->
    ProjectSpecBuilder projectId cfg tcfg
addArtifacts artifacts builder =
    builder{pbArtifacts = pbArtifacts builder ++ artifacts}

{- | Declare the complete read-only input allowlist available to
'psAssemble'. Repeated calls append in declaration order.
-}
addAssemblyInputs ::
    [ConfigInput] ->
    ProjectSpecBuilder projectId cfg tcfg ->
    ProjectSpecBuilder projectId cfg tcfg
addAssemblyInputs inputs builder =
    builder{pbAssemblyInputs = pbAssemblyInputs builder ++ inputs}

{- | Add one ordered step fragment. Repeated calls append rather than replace.
The combined list is validated into an opaque non-empty 'StepPlan' for each
decoded Production config before an interpreter can consume it.

The fragment receives the admitted 'CanonicalProjectRoot' so a step can derive
its project-relative paths — and the descent it declares with
'HostBootstrap.Step.descendsVia' — from that one authority (§ X).
-}
addSteps ::
    ( forall rootScope rootId.
      CanonicalProjectRoot rootScope rootId ->
      cfg (Production projectId) ->
      [Step]
    ) ->
    ProjectSpecBuilder projectId cfg tcfg ->
    ProjectSpecBuilder projectId cfg tcfg
addSteps fragment builder =
    builder{pbStepFragments = pbStepFragments builder ++ [StepFragment fragment]}

{- | Add a checked typed service registry. Repeated calls compose in declaration
order; duplicate identities are rejected by finalization.
-}
addServices ::
    ServiceRegistry (cfg (Production projectId)) ->
    ProjectSpecBuilder projectId cfg tcfg ->
    ProjectSpecBuilder projectId cfg tcfg
addServices registry builder =
    builder{pbServiceRegistries = pbServiceRegistries builder ++ [registry]}

finalizeProjectSpec ::
    ProjectSpecBuilder projectId cfg tcfg ->
    Either ProjectSpecError (ProjectSpec projectId cfg tcfg)
finalizeProjectSpec builder = do
    validateBase
    services <- foldServices
    pure
        ProjectSpec
            { psTestSuite = pbTestSuite builder
            , psCheckCode = pbCheckCode builder
            , psArtifacts = pbArtifacts builder
            , psTestCodec = pbTestCodec builder
            , psAssemblyInputs = pbAssemblyInputs builder
            , psServices = services
            , psStepPlan = \root cfg ->
                mkStepPlan
                    (concatMap (\fragment -> runStepFragment fragment root cfg) (pbStepFragments builder))
            , psTestInit = pbTestInit builder
            , psAssemble = pbAssemble builder
            }
  where
    validateBase
        | testSuiteCaseCount (pbTestSuite builder) == 0 = Left EmptyProjectTestSuite
        | not (null duplicateCases) =
            Left (DuplicateProjectCaseIds (map caseIdText duplicateCases))
        | not (null shadowedArtifacts) = Left (CoreArtifactShadowing shadowedArtifacts)
        | not (null duplicateArtifacts) = Left (DuplicateProjectArtifacts duplicateArtifacts)
        | not (null duplicateInputs) = Left (DuplicateAssemblyInputs duplicateInputs)
        | null (pbStepFragments builder) = Left MissingStepPlan
        | otherwise = Right ()
    caseIds = testSuiteCaseIds (pbTestSuite builder)
    duplicateCases = duplicates caseIds
    artifactNames = map (T.unpack . artifactName) (pbArtifacts builder)
    coreArtifactNames = map (T.unpack . artifactName) coreArtifacts
    shadowedArtifacts = filter (`elem` coreArtifactNames) artifactNames
    duplicateArtifacts = duplicates artifactNames
    duplicateInputs = duplicates (map configInputPath (pbAssemblyInputs builder))
    foldServices =
        foldl merge (Right emptyServiceRegistry) (pbServiceRegistries builder)
    merge accumulated next =
        accumulated >>= \current ->
            either (Left . InvalidServiceRegistry) Right (mergeServiceRegistries current next)

projectServiceVariantNames :: ProjectSpec projectId cfg tcfg -> [String]
projectServiceVariantNames = serviceVariantNames . psServices

projectArtifactNames :: ProjectSpec projectId cfg tcfg -> [T.Text]
projectArtifactNames = map artifactName . psArtifacts

-- | Project one decoded Production config through the finalized plan builder.
-- Observation cannot bypass validation: the result is still an opaque
-- 'StepPlan'.
projectStepPlan ::
    ProjectSpec projectId cfg tcfg ->
    CanonicalProjectRoot rootScope rootId ->
    cfg (Production projectId) ->
    Either StepPlanError StepPlan
projectStepPlan = psStepPlan

{- | Run the host-bootstrap CLI for @progName@, extending the core command tree
with a validated project spec.
-}
runHostBootstrapCLI ::
    forall projectId cfg tcfg.
    (ProjectCfg projectId cfg, TestCfg tcfg) =>
    String ->
    ProjectSpec projectId cfg tcfg ->
    IO ()
runHostBootstrapCLI progName spec = do
    let testCodec = psTestCodec spec
        initBuilder args = do
            assembled <-
                runConfigAssembly
                    (psAssemblyInputs spec)
                    (psAssemble spec (ProductionAssembly args))
            either die pure assembled
    configureUtf8Output
    validateRuntimeProjectIdentity progName
    withProductionProjectCodec @projectId @cfg $ \baseCodec ->
        withFinalizedServiceRegistry
            ProductionScope
            baseCodec
            (psServices spec)
            ( \cfgCodec services ->
                runCLI
                    cfgCodec
                    testCodec
                    progName
                    (psArtifacts spec)
                    (psTestSuite spec)
                    (psCheckCode spec)
                    services
                    (psStepPlan spec)
                    (psAssemblyInputs spec)
                    (psAssemble spec)
                    initBuilder
                    (psTestInit spec)
            )

validateRuntimeProjectIdentity :: String -> IO ()
validateRuntimeProjectIdentity declared = do
    runtime <- runtimeProjectIdentity <$> getProgName
    unless (runtime == declared) $
        die
            ( "project identity mismatch before command dispatch: declared "
                ++ show declared
                ++ ", runtime executable "
                ++ show runtime
            )

runtimeProjectIdentity :: FilePath -> String
runtimeProjectIdentity invoked =
    let filename = takeFileName invoked
     in if map toLower (takeExtension filename) == ".exe"
            then dropExtension filename
            else filename

{- | The bare core binary's trivial project config: a newtype over the universal
'Context.BinaryContext'. It carries no project fields (no resources, no
Dockerfile, no deploy), so the bare binary type-checks against the generic spec
without inventing a project config shape. The @init@/@test@ builders below give
it the minimal behaviour the bare surface needs.
-}
data BareProject

newtype BareConfig scope = BareConfig {bareContext :: Context.BinaryContext}
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

instance ProjectCfg BareProject BareConfig where
    withProductionProjectCodec =
        withProjectCodec
            (T.pack "BareConfig/Production")
            (requireCodecWitness "BareConfig" autoCodecWitness)
    withHarnessProjectCodec _ =
        withProjectCodec
            (T.pack "BareConfig/Harness")
            (requireCodecWitness "BareConfig" autoCodecWitness)
    cfgContext = bareContext

{- | Run the bare core binary. This is the only supported path that intentionally
has no project artifacts, an empty test matrix, and no service registry. Its
config builders interpret the parsed @init@ flags into a 'BareConfig' (just the
derived context) and a trivial test config (the bare binary ships no test cases).
-}
runBareHostBootstrapCLI :: String -> IO ()
runBareHostBootstrapCLI progName = do
    let testCodec = requireCodecWitness "bare test config" (autoCodecWitness @())
    configureUtf8Output
    validateRuntimeProjectIdentity progName
    withProductionProjectCodec @BareProject @BareConfig $ \baseCodec ->
        withFinalizedServiceRegistry
            ProductionScope
            baseCodec
            emptyServiceRegistry
            ( \cfgCodec services ->
                runCLI
                    cfgCodec
                    testCodec
                    progName
                    []
                    emptySuite
                    (putStrLn "check-code: bare core binary has no project checks")
                    services
                    (\_ _ -> Left EmptyStepPlan)
                    []
                    bareAssemble
                    (either fail pure . bareInit)
                    (const ())
            )
  where
    bareAssemble ::
        forall scope.
        AssemblyRequest BareProject () () scope ->
        ConfigAssembly scope (BareConfig scope)
    bareAssemble (ProductionAssembly args) =
        either failConfigAssembly pureConfigAssembly (bareInit args)
    bareAssemble (HarnessAssembly _ _ _) =
        either failConfigAssembly pureConfigAssembly (bareInit defaultBareArgs)
    defaultBareArgs =
        InitArgs
            { role = Context.HostOrchestrator
            , alsoRoles = []
            , output = Nothing
            , sourceRoot = Nothing
            , mCpu = Nothing
            , memory = Nothing
            , storage = Nothing
            , dockerfile = Nothing
            , haReplicas = Nothing
            , force = False
            , ifMissing = False
            }
    -- A refused extra role stops assembly: @--also-role@ is operator input, and
    -- silently dropping it would produce a config that looks authorized.
    bareInit :: InitArgs -> Either String (BareConfig scope)
    bareInit args =
        let baseCtx =
                Context.contextForKind
                    (T.pack progName)
                    (T.pack progName)
                    (T.pack (fromMaybe "." (sourceRoot args)))
                    (role args)
         in case foldM (flip Context.addRole) baseCtx (alsoRoles args) of
                Left err -> Left (Context.contextErrorMessage err)
                Right ctx -> Right (BareConfig ctx)

configureUtf8Output :: IO ()
configureUtf8Output = do
    hSetEncoding stdout utf8
    hSetEncoding stderr utf8

runCLI ::
    forall projectId cfg tcfg specDigest.
    (ProjectCfg projectId cfg, TestCfg tcfg) =>
    ProjectCodec (Production projectId) specDigest cfg ->
    CodecWitness tcfg ->
    String ->
    [ConfigArtifact] ->
    TestSuite ->
    IO () ->
    FinalizedServiceRegistry
        (Production projectId)
        specDigest
        (cfg (Production projectId)) ->
    ( forall rootScope rootId.
      CanonicalProjectRoot rootScope rootId ->
      cfg (Production projectId) ->
      Either StepPlanError StepPlan
    ) ->
    [ConfigInput] ->
    ( forall scope.
      AssemblyRequest projectId tcfg (TestVariant tcfg) scope ->
      ConfigAssembly scope (cfg scope)
    ) ->
    (InitArgs -> IO (cfg (Production projectId))) ->
    (InitArgs -> tcfg) ->
    IO ()
runCLI cfgCodec testCodec progName projectArtifacts testSuite checkCode services stepPlan assemblyInputs assemble initBuilder testInit =
    join (customExecParser (prefs showHelpOnEmpty) opts)
  where
    allCommands =
        coreCommands
            cfgCodec
            testCodec
            progName
            projectArtifacts
            testSuite
            checkCode
            services
            stepPlan
            assemblyInputs
            assemble
            initBuilder
            testInit
    opts =
        info
            (parser <**> helper)
            ( fullDesc
                <> header (progName ++ " - host bootstrap")
                <> progDesc
                    ( "Host-management commands for "
                        ++ progName
                        ++ ". The command surface is fixed; projects extend it through the extension streams, not new verbs."
                    )
            )
    parser :: Parser (IO ())
    parser = hsubparser (mconcat allCommands)

duplicates :: (Ord a) => [a] -> [a]
duplicates names = [name | name : _ : _ <- group (sort names)]
