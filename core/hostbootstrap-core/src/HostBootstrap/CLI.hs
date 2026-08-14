{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
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
    addForwardChildPlan,
    finalizeProjectSpec,
    projectServiceVariantNames,
    projectArtifactNames,
    projectStepPlan,
    runHostBootstrapCLI,
    runBareHostBootstrapCLI,
)
where

import Control.Monad (foldM, join)
import Data.List (group, sort)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Dhall (FromDhall, ToDhall)
import GHC.Generics (Generic)
import HostBootstrap.Authority (
    InstalledProjectIdentity,
    authorityErrorMessage,
    withInstalledProjectIdentity,
 )
import HostBootstrap.Command (coreCommands)
import HostBootstrap.Config.Class (
    AssemblyRequest (..),
    ConfigAssembly,
    ConfigInput,
    InitArgs (..),
    ProjectCfg (..),
    TestCfg (..),
    configInputPath,
    failConfigAssembly,
    pureConfigAssembly,
    runConfigAssembly,
    withProjectCodec,
 )
import HostBootstrap.Config.Fields (ScopeKind (ProductionScope))
import HostBootstrap.Config.Vocab (Production)
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
import HostBootstrap.Lift.Context (LiftContext)
import HostBootstrap.ProjectPlan.Construct
    ( FinalizedProjectSpec
    , withFinalizedProjectSpec
    )
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)
import HostBootstrap.Service (
    ServiceRegistry,
    ServiceRegistryError,
    emptyServiceRegistry,
    mergeServiceRegistries,
    serviceVariantNames,
 )
import HostBootstrap.Step (Step, StepPlan, StepPlanError (..), mkStepPlan)
import Options.Applicative
import System.Exit (die)
import System.IO (hSetEncoding, stderr, stdout, utf8)

{- | A derived project's required extension points, generic over the project's
config type @cfg@ and the project's test-config type @tcfg@. There are no
per-project commands: the surface is fixed (§ P). A project supplies its runtime
test suite, code-check action, schema artifact delta, lift chain (whose steps
carry their own descent and their own reverse effect, § W), service-handler
registry, one scope-aware restricted project-config assembler, and its
test-config initializer. The bare core binary uses 'runBareHostBootstrapCLI' instead.
-}
data ProjectSpec cfg tcfg = ProjectSpec
    { psTestSuite :: TestSuite
    , psCheckCode :: IO ()
    , psArtifacts :: [ConfigArtifact]
    , psTestCodec :: CodecWitness tcfg
    , psAssemblyInputs :: [ConfigInput]
    , psServices :: ServiceRegistry cfg
    , psStepPlan ::
        forall scope rootId.
        CanonicalProjectRoot scope rootId ->
        cfg scope ->
        Either StepPlanError StepPlan
    {- ^ The one validated plan. It is built under the admitted
    'CanonicalProjectRoot' (§ X), so every step — its forward action and the
    descent it declares — derives its project-relative paths from that one
    authority rather than from @cwd@ or a serialized path.
    -}
    , psForwardChildPlan ::
        forall scope.
        cfg scope ->
        Text ->
        Text ->
        LiftContext ->
        Either String (FilePath, cfg scope, StepPlan)
    , psTestInit :: InitArgs -> tcfg
    {- ^ Interpret the parsed @init@ flags into the project's test config
    (@test init@) — needs no pre-existing project config.
    -}
    , psAssemble ::
        forall projectId scope.
        AssemblyRequest projectId tcfg (TestVariant tcfg) scope ->
        ConfigAssembly scope (cfg scope)
    {- ^ The sole default-bearing project-config assembler. Its closed request
    separates Production init from one exact generative Harness run; its
    restricted effect permits only declared config reads.
    -}
    }

newtype StepFragment cfg = StepFragment
    { runStepFragment ::
        forall scope rootId.
        CanonicalProjectRoot scope rootId ->
        cfg scope ->
        [Step]
    }

{- | Opaque unfinished project specification. It cannot be dispatched. Step and
service contributions are additive, and each step carries its own descent and
reverse effect, so there is no lifecycle slot beside the plan.
-}
data ProjectSpecBuilder cfg tcfg = ProjectSpecBuilder
    { pbTestSuite :: TestSuite
    , pbCheckCode :: IO ()
    , pbArtifacts :: [ConfigArtifact]
    , pbTestCodec :: CodecWitness tcfg
    , pbAssemblyInputs :: [ConfigInput]
    , pbStepFragments :: [StepFragment cfg]
    , pbServiceRegistries :: [ServiceRegistry cfg]
    , pbForwardChildPlan ::
        forall scope.
        cfg scope ->
        Text ->
        Text ->
        LiftContext ->
        Either String (FilePath, cfg scope, StepPlan)
    , pbForwardChildPlanCount :: Int
    , pbTestInit :: InitArgs -> tcfg
    , pbAssemble ::
        forall projectId scope.
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
    | MissingForwardChildPlan
    | DuplicateForwardChildPlan
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
    ( forall projectId scope.
      AssemblyRequest projectId tcfg (TestVariant tcfg) scope ->
      ConfigAssembly scope (cfg scope)
    ) ->
    ProjectSpecBuilder cfg tcfg
projectSpec suite check arts testCodec testInit assemble =
    ProjectSpecBuilder
        { pbTestSuite = suite
        , pbCheckCode = check
        , pbArtifacts = arts
        , pbTestCodec = testCodec
        , pbAssemblyInputs = []
        , pbStepFragments = []
        , pbServiceRegistries = []
        , pbForwardChildPlan = refuseForwardChildPlan
        , pbForwardChildPlanCount = 0
        , pbTestInit = testInit
        , pbAssemble = assemble
        }

-- | Add schema/artifact contributions without replacing prior layers.
addArtifacts ::
    [ConfigArtifact] ->
    ProjectSpecBuilder cfg tcfg ->
    ProjectSpecBuilder cfg tcfg
addArtifacts artifacts builder =
    builder{pbArtifacts = pbArtifacts builder ++ artifacts}

{- | Declare the complete read-only input allowlist available to
'psAssemble'. Repeated calls append in declaration order.
-}
addAssemblyInputs ::
    [ConfigInput] ->
    ProjectSpecBuilder cfg tcfg ->
    ProjectSpecBuilder cfg tcfg
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
    ( forall scope rootId.
      CanonicalProjectRoot scope rootId ->
      cfg scope ->
      [Step]
    ) ->
    ProjectSpecBuilder cfg tcfg ->
    ProjectSpecBuilder cfg tcfg
addSteps fragment builder =
    builder{pbStepFragments = pbStepFragments builder ++ [StepFragment fragment]}

{- | Add a checked typed service registry. Repeated calls compose in declaration
order; duplicate identities are rejected by finalization.
-}
addServices ::
    ServiceRegistry cfg ->
    ProjectSpecBuilder cfg tcfg ->
    ProjectSpecBuilder cfg tcfg
addServices registry builder =
    builder{pbServiceRegistries = pbServiceRegistries builder ++ [registry]}

{- | Install the one project-specific forward-child projector.

The builder retains a refusing function even before installation, avoiding an
impredicative optional field.  The separate count saturates at two so duplicate
installation remains a closed validation state rather than unbounded input.
-}
addForwardChildPlan ::
    ( forall scope.
      cfg scope ->
      Text ->
      Text ->
      LiftContext ->
      Either String (FilePath, cfg scope, StepPlan)
    ) ->
    ProjectSpecBuilder cfg tcfg ->
    ProjectSpecBuilder cfg tcfg
addForwardChildPlan projector builder =
    builder
        { pbForwardChildPlan = projector
        , pbForwardChildPlanCount = case pbForwardChildPlanCount builder of
            0 -> 1
            _ -> 2
        }

finalizeProjectSpec ::
    ProjectSpecBuilder cfg tcfg ->
    Either ProjectSpecError (ProjectSpec cfg tcfg)
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
            , psForwardChildPlan = pbForwardChildPlan builder
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
        | pbForwardChildPlanCount builder == 0 = Left MissingForwardChildPlan
        | pbForwardChildPlanCount builder /= 1 = Left DuplicateForwardChildPlan
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

projectServiceVariantNames :: ProjectSpec cfg tcfg -> [String]
projectServiceVariantNames = serviceVariantNames . psServices

projectArtifactNames :: ProjectSpec cfg tcfg -> [T.Text]
projectArtifactNames = map artifactName . psArtifacts

{- | Project one scope-indexed config through the finalized plan builder.

Production and each generative Harness run instantiate the same builder at
different config scopes. Observation cannot bypass validation: the result is
still an opaque 'StepPlan'.
-}
projectStepPlan ::
    ProjectSpec cfg tcfg ->
    CanonicalProjectRoot scope rootId ->
    cfg scope ->
    Either StepPlanError StepPlan
projectStepPlan = psStepPlan

refuseForwardChildPlan ::
    cfg scope ->
    Text ->
    Text ->
    LiftContext ->
    Either String (FilePath, cfg scope, StepPlan)
refuseForwardChildPlan _ _ _ _ =
    Left "forward-child projection is unavailable"

{- | Run the host-bootstrap CLI for @progName@, extending the core command tree
with a validated project spec.
-}
runHostBootstrapCLI ::
    forall cfg tcfg.
    (ProjectCfg cfg, TestCfg tcfg) =>
    String ->
    ProjectSpec cfg tcfg ->
    IO ()
runHostBootstrapCLI progName spec = do
    configureUtf8Output
    admitted <-
        withInstalledProjectIdentity (T.pack progName) $
            \(project :: InstalledProjectIdentity projectId) -> do
                let testCodec = psTestCodec spec
                    initBuilder args = do
                        assembled <-
                            runConfigAssembly
                                (psAssemblyInputs spec)
                                (psAssemble spec (ProductionAssembly args))
                        either die pure assembled
                withProductionProjectCodec @cfg @projectId $ \baseCodec ->
                    withFinalizedProjectSpec
                        ProductionScope
                        baseCodec
                        (psServices spec)
                        (psStepPlan spec)
                        (psForwardChildPlan spec)
                        ( \finalizedSpec ->
                            runCLI
                                project
                                finalizedSpec
                                testCodec
                                progName
                                (psArtifacts spec)
                                (psTestSuite spec)
                                (psCheckCode spec)
                                (psAssemblyInputs spec)
                                (psAssemble spec)
                                initBuilder
                                (psTestInit spec)
                        )
    either (die . T.unpack . authorityErrorMessage) pure admitted

{- | The bare core binary's trivial project config: a newtype over the universal
'Context.BinaryContext'. It carries no project fields (no resources, no
Dockerfile, no deploy), so the bare binary type-checks against the generic spec
without inventing a project config shape. The @init@/@test@ builders below give
it the minimal behaviour the bare surface needs.
-}
newtype BareConfig scope = BareConfig {bareContext :: Context.BinaryContext}
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

instance ProjectCfg BareConfig where
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
    admitted <-
        withInstalledProjectIdentity (T.pack progName) $
            \(project :: InstalledProjectIdentity projectId) ->
                withProductionProjectCodec @BareConfig @projectId $ \baseCodec ->
                    withFinalizedProjectSpec
                        ProductionScope
                        baseCodec
                        emptyServiceRegistry
                        (\_ _ -> Left EmptyStepPlan)
                        refuseForwardChildPlan
                        ( \finalizedSpec ->
                            runCLI
                                project
                                finalizedSpec
                                testCodec
                                progName
                                []
                                emptySuite
                                (putStrLn "check-code: bare core binary has no project checks")
                                []
                                bareAssemble
                                (either fail pure . bareInit)
                                (const ())
                        )
    either (die . T.unpack . authorityErrorMessage) pure admitted
  where
    bareAssemble ::
        forall projectId scope.
        AssemblyRequest projectId () () scope ->
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
    (ProjectCfg cfg, TestCfg tcfg) =>
    InstalledProjectIdentity projectId ->
    FinalizedProjectSpec (Production projectId) specDigest cfg ->
    CodecWitness tcfg ->
    String ->
    [ConfigArtifact] ->
    TestSuite ->
    IO () ->
    [ConfigInput] ->
    ( forall scope.
      AssemblyRequest projectId tcfg (TestVariant tcfg) scope ->
      ConfigAssembly scope (cfg scope)
    ) ->
    (InitArgs -> IO (cfg (Production projectId))) ->
    (InitArgs -> tcfg) ->
    IO ()
runCLI project finalizedSpec testCodec progName projectArtifacts testSuite checkCode assemblyInputs assemble initBuilder testInit =
    join (customExecParser (prefs showHelpOnEmpty) opts)
  where
    allCommands =
        coreCommands
            project
            finalizedSpec
            testCodec
            progName
            projectArtifacts
            testSuite
            checkCode
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
