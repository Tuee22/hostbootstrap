{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

{- | The fixed @optparse-applicative@ command tree and the generic entrypoints
project binaries use to extend it.

The command surface is **fixed and closed** (development_plan_standards § P):
every project binary — and the bare @hostbootstrap@ binary — surfaces the same
tree: @project@, @test@, @service@, @context@, and @check-code@. There are no
hidden commands. @hostbootstrap-core@ is a **library of composable tools**,
including the @ensure@ reconciler primitives a project runs as @ensure-*@ chain
steps, not a CLI topology, so a project never adds a command. A project extends
the core only through the parallel extension streams carried by 'ProjectSpec':
its lift chain ('withChain'), its Dhall-vocabulary artifacts, its test suite, its
service-handler registry ('withServices'), its @check-code@ action, and the
project-owned config builders ('psInit' / 'psTestInit' / 'psTestConfig') — the
**only** place config defaults live, since the core ships none.

A project binary calls 'runHostBootstrapCLI' with a 'ProjectSpec'. The entrypoint
validates the extension points (a non-empty test suite, no duplicate test
cases/artifacts/service variants, a supplied @check-code@ action) and then merges
the spec into the core command tree ('HostBootstrap.Command.coreCommands'). The
bare @hostbootstrap@ binary (built like any project binary, not baked into the
base image) uses the separate 'runBareHostBootstrapCLI'. See
@documents/architecture/hostbootstrap_core_library.md@.
-}
module HostBootstrap.CLI (
    ProjectSpec (..),
    projectSpec,
    withChain,
    withFrameContext,
    withTeardown,
    withServices,
    runHostBootstrapCLI,
    runBareHostBootstrapCLI,
)
where

import Control.Monad (join)
import Data.List (group, intercalate, sort)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Dhall (FromDhall, ToDhall)
import GHC.Generics (Generic)
import HostBootstrap.Command (coreCommands)
import HostBootstrap.Config.Class (InitArgs (..), ProjectCfg (..))
import qualified HostBootstrap.Context as Context
import HostBootstrap.Dhall.Gen (ConfigArtifact (..), coreArtifacts)
import HostBootstrap.Harness (TestSuite, allCasesSelector, emptySuite, testSuiteCaseCount, testSuiteCaseIds)
import HostBootstrap.Lift (LiftContext, localContext)
import HostBootstrap.Service (ServiceRegistry, duplicateServiceVariants, emptyServiceRegistry)
import HostBootstrap.Step (Step, StepFrame)
import Options.Applicative
import System.Exit (die)
import System.IO (hSetEncoding, stderr, stdout, utf8)

{- | A derived project's required extension points, generic over the project's
config type @cfg@ and the project's test-config type @tcfg@. There are no
per-project commands: the surface is fixed (§ P). A project supplies its runtime
test suite, code-check action, schema artifact delta, lift chain, per-frame lift
context, chain-frame teardown, service-handler registry, and the project-owned
config builders ('psInit' / 'psTestInit' / 'psTestConfig'). The bare core binary
uses 'runBareHostBootstrapCLI' instead.
-}
data ProjectSpec cfg tcfg = ProjectSpec
    { psTestSuite :: TestSuite
    , psCheckCode :: IO ()
    , psArtifacts :: [ConfigArtifact]
    , psServices :: ServiceRegistry
    , psChain :: cfg -> [Step]
    , psFrameContext :: cfg -> StepFrame -> LiftContext
    , -- | The chain-frame teardown the @project down@ / @project destroy@
      -- lifecycle runs after the recursive cluster teardown: stop (@False@) or
      -- delete (@True@) the project-provisioned frames (e.g. the VM). Best-effort
      -- and idempotent; the never-delete-@.data@ invariant (§ O) is the cluster
      -- teardown's responsibility. Attach with 'withTeardown'.
      psTeardown :: cfg -> Bool -> IO ()
    , -- | The **only** default-bearing function: interpret the parsed @init@
      -- flags into a concrete project config, supplying the project's defaults
      -- for any omitted knob. Drives @project init@ / @service init@.
      psInit :: InitArgs -> cfg
    , -- | Interpret the parsed @init@ flags into the project's test config
      -- (@test init@) — needs no pre-existing project config.
      psTestInit :: InitArgs -> tcfg
    , -- | Build the run's labeled project-config variants from the test config
      -- (@test run@): a **non-empty** list of @(label, cfg)@ the harness loops
      -- over, generating the sibling config, driving the stack, and tearing it
      -- down once per variant. The label is the variant's expected message
      -- (threaded into the per-variant assertion env).
      psTestConfig :: tcfg -> IO [(T.Text, cfg)]
    }

{- | Build a project spec from the required streams (the test suite, code-check
action, schema-artifact delta) plus the project-owned config builders. The
project's lift chain (§ Y), per-frame lift-context builder, chain-frame teardown,
and service registry default to empty/local; attach them with 'withChain' /
'withFrameContext' / 'withTeardown' / 'withServices'.
-}
projectSpec ::
    TestSuite ->
    IO () ->
    [ConfigArtifact] ->
    (InitArgs -> cfg) ->
    (InitArgs -> tcfg) ->
    (tcfg -> IO [(T.Text, cfg)]) ->
    ProjectSpec cfg tcfg
projectSpec suite check arts initBuilder testInit testConfig =
    ProjectSpec
        { psTestSuite = suite
        , psCheckCode = check
        , psArtifacts = arts
        , psServices = emptyServiceRegistry
        , psChain = const []
        , psFrameContext = const (const localContext)
        , psTeardown = \_ _ -> pure ()
        , psInit = initBuilder
        , psTestInit = testInit
        , psTestConfig = testConfig
        }

{- | Attach the project's lift chain: a pure function from the root
@<project>.dhall@ config to the ordered @[Step]@ the core @project@ lifecycle
interprets (§ Y). The chain is the project's primary deploy contribution.
-}
withChain :: (cfg -> [Step]) -> ProjectSpec cfg tcfg -> ProjectSpec cfg tcfg
withChain f spec = spec{psChain = f}

{- | Attach the per-frame lift-context builder the recursive interpreter uses to
cross into a nested frame — the project supplies the provider VM/container
identity for each frame (§ U).
-}
withFrameContext :: (cfg -> StepFrame -> LiftContext) -> ProjectSpec cfg tcfg -> ProjectSpec cfg tcfg
withFrameContext f spec = spec{psFrameContext = f}

{- | Attach the project's chain-frame teardown: how @project down@ (stop, @False@)
and @project destroy@ (delete, @True@) tear down the frames the chain provisioned
(for the demo: stop/delete the VM). Runs after the core's recursive cluster
teardown (which preserves host @.data@, § O), so the outermost frame — the VM — is
stopped or deleted last. Best-effort and idempotent: a missing frame is not an
error, so a partial stack always tears down.
-}
withTeardown :: (cfg -> Bool -> IO ()) -> ProjectSpec cfg tcfg -> ProjectSpec cfg tcfg
withTeardown f spec = spec{psTeardown = f}

{- | Attach the project's service-handler registry (one of the extension streams,
§ T, § AA): the long-running roles @service run \<variant\>@ dispatches over. The
registry may be empty (not every project ships a service); the fixed @service@
surface is unchanged either way.
-}
withServices :: ServiceRegistry -> ProjectSpec cfg tcfg -> ProjectSpec cfg tcfg
withServices svcs spec = spec{psServices = svcs}

{- | Run the host-bootstrap CLI for @progName@, extending the core command tree
with a validated project spec.
-}
runHostBootstrapCLI ::
    (ProjectCfg cfg, FromDhall tcfg, ToDhall tcfg) =>
    String ->
    ProjectSpec cfg tcfg ->
    IO ()
runHostBootstrapCLI progName spec = do
    configureUtf8Output
    either die pure (validateProjectSpec spec)
    runCLI
        progName
        (psArtifacts spec)
        (psTestSuite spec)
        (psCheckCode spec)
        (psServices spec)
        (psChain spec)
        (psFrameContext spec)
        (psTeardown spec)
        (psInit spec)
        (psTestInit spec)
        (psTestConfig spec)

{- | The bare core binary's trivial project config: a newtype over the universal
'Context.BinaryContext'. It carries no project fields (no resources, no
Dockerfile, no deploy), so the bare binary type-checks against the generic spec
without inventing a project config shape. The @init@/@test@ builders below give
it the minimal behaviour the bare surface needs.
-}
newtype BareConfig = BareConfig {bareContext :: Context.BinaryContext}
    deriving (Eq, Show, Generic, FromDhall, ToDhall)

instance ProjectCfg BareConfig where
    cfgContext = bareContext
    cfgWithContext ctx _ = BareConfig ctx

{- | Run the bare core binary. This is the only supported path that intentionally
has no project artifacts, an empty test matrix, and no service registry. Its
config builders interpret the parsed @init@ flags into a 'BareConfig' (just the
derived context) and a trivial test config (the bare binary ships no test cases).
-}
runBareHostBootstrapCLI :: String -> IO ()
runBareHostBootstrapCLI progName = do
    configureUtf8Output
    runCLI
        progName
        []
        emptySuite
        (putStrLn "check-code: bare core binary has no project checks")
        emptyServiceRegistry
        (const [])
        (const (const localContext))
        (\_ _ -> pure ())
        bareInit
        (const ())
        (const (pure [(T.pack "bare", bareInit defaultBareArgs)]))
  where
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
    bareInit args =
        let baseCtx =
                Context.contextForKind
                    (T.pack progName)
                    (T.pack progName)
                    (T.pack (fromMaybe "." (sourceRoot args)))
                    Context.defaultResourceEnvelope
                    (role args)
         in BareConfig (foldr Context.addRole baseCtx (alsoRoles args))

configureUtf8Output :: IO ()
configureUtf8Output = do
    hSetEncoding stdout utf8
    hSetEncoding stderr utf8

runCLI ::
    (ProjectCfg cfg, FromDhall tcfg, ToDhall tcfg) =>
    String ->
    [ConfigArtifact] ->
    TestSuite ->
    IO () ->
    ServiceRegistry ->
    (cfg -> [Step]) ->
    (cfg -> StepFrame -> LiftContext) ->
    (cfg -> Bool -> IO ()) ->
    (InitArgs -> cfg) ->
    (InitArgs -> tcfg) ->
    (tcfg -> IO [(T.Text, cfg)]) ->
    IO ()
runCLI progName projectArtifacts testSuite checkCode services chain frameCtx teardown initBuilder testInit testConfig =
    join (customExecParser (prefs showHelpOnEmpty) opts)
  where
    allCommands =
        coreCommands
            progName
            projectArtifacts
            testSuite
            checkCode
            services
            chain
            frameCtx
            teardown
            initBuilder
            testInit
            testConfig
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

validateProjectSpec :: ProjectSpec cfg tcfg -> Either String ()
validateProjectSpec spec
    | testSuiteCaseCount (psTestSuite spec) == 0 =
        Left "project test suite is empty; use runBareHostBootstrapCLI only for the bare core binary"
    | not (null duplicateCases) =
        Left ("project test case ids are duplicated: " ++ comma duplicateCases)
    | allCasesSelector `elem` caseIds =
        Left
            ( "project test case id '"
                ++ allCasesSelector
                ++ "' is reserved (the always-injected whole-matrix selector) and cannot name a case"
            )
    | not (null shadowedArtifacts) =
        Left ("project artifacts shadow core artifacts: " ++ comma shadowedArtifacts)
    | not (null duplicateArtifacts) =
        Left ("project artifact names are duplicated: " ++ comma duplicateArtifacts)
    | not (null duplicateServices) =
        Left ("project service variants are duplicated: " ++ comma duplicateServices)
    | otherwise = Right ()
  where
    caseIds = testSuiteCaseIds (psTestSuite spec)
    duplicateCases = duplicates caseIds
    artifactNames = map (T.unpack . artifactName) (psArtifacts spec)
    coreArtifactNames = map (T.unpack . artifactName) coreArtifacts
    shadowedArtifacts = filter (`elem` coreArtifactNames) artifactNames
    duplicateArtifacts = duplicates artifactNames
    duplicateServices = duplicateServiceVariants (psServices spec)

duplicates :: [String] -> [String]
duplicates names = [name | name : _ : _ <- group (sort names)]

comma :: [String] -> String
comma = intercalate ", "
