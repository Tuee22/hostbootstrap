{- | The fixed @optparse-applicative@ command tree and the generic entrypoints
project binaries use to extend it.

The command surface is **fixed and closed** (development_plan_standards § P):
every project binary — and the bare @hostbootstrap@ binary — surfaces the same
tree (@project@ / @test@ / @service@ / @context@ / @check-code@, plus the hidden
@ensure@ debug surface). @hostbootstrap-core@ is a **library of composable
tools**, not a CLI topology, so a project never adds a command. A project extends
the core only through the parallel extension streams carried by 'ProjectSpec':
its lift chain ('withChain'), its Dhall-vocabulary artifacts, its test suite, its
service-handler registry ('withServices'), and its @check-code@ action.

A project binary calls 'runHostBootstrapCLI' with a 'ProjectSpec'. The entrypoint
validates the extension points (a non-empty test suite, no duplicate test
cases/artifacts/service variants, a supplied @check-code@ action) and then merges
the spec into the core command tree ('HostBootstrap.Command.coreCommands'). The
bare @hostbootstrap@ binary (built like any project binary, not baked into the
base image) uses the separate 'runBareHostBootstrapCLI'. See
@documents/architecture/hostbootstrap_core_library.md@.
-}
module HostBootstrap.CLI (
    ProjectSpec,
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
import qualified Data.Text as T
import HostBootstrap.Command (coreCommands)
import HostBootstrap.Config.Schema (ProjectConfig)
import HostBootstrap.Dhall.Gen (ConfigArtifact (..), coreArtifacts)
import HostBootstrap.Harness (TestSuite, emptySuite, testSuiteCaseCount, testSuiteCaseIds)
import HostBootstrap.Lift (LiftContext, localContext)
import HostBootstrap.Service (ServiceRegistry, duplicateServiceVariants, emptyServiceRegistry)
import HostBootstrap.Step (Step, StepFrame)
import Options.Applicative
import System.Exit (die)

{- | A derived project's required extension points. There are no per-project
commands: the surface is fixed (§ P). A project supplies its runtime test suite,
code-check action, schema artifact delta, lift chain, per-frame lift context,
chain-frame teardown, and service-handler registry. The bare core binary uses
'runBareHostBootstrapCLI' instead.
-}
data ProjectSpec = ProjectSpec
    { psTestSuite :: TestSuite
    , psCheckCode :: IO ()
    , psArtifacts :: [ConfigArtifact]
    , psServices :: ServiceRegistry
    , psChain :: ProjectConfig -> [Step]
    , psFrameContext :: ProjectConfig -> StepFrame -> LiftContext
    , -- | The chain-frame teardown the @project down@ / @project destroy@
      -- lifecycle runs after the recursive cluster teardown: stop (@False@) or
      -- delete (@True@) the project-provisioned frames (e.g. the VM). Best-effort
      -- and idempotent; the never-delete-@.data@ invariant (§ O) is the cluster
      -- teardown's responsibility. Attach with 'withTeardown'.
      psTeardown :: ProjectConfig -> Bool -> IO ()
    }

{- | Build a project spec. The project's lift chain (§ Y), per-frame lift-context
builder, chain-frame teardown, and service registry default to empty/local;
attach them with 'withChain' / 'withFrameContext' / 'withTeardown' / 'withServices'.
-}
projectSpec :: TestSuite -> IO () -> [ConfigArtifact] -> ProjectSpec
projectSpec suite check arts =
    ProjectSpec suite check arts emptyServiceRegistry (const []) (const (const localContext)) (\_ _ -> pure ())

{- | Attach the project's lift chain: a pure function from the root
@<project>.dhall@ config to the ordered @[Step]@ the core @project@ lifecycle
interprets (§ Y). The chain is the project's primary deploy contribution.
-}
withChain :: (ProjectConfig -> [Step]) -> ProjectSpec -> ProjectSpec
withChain f spec = spec{psChain = f}

{- | Attach the per-frame lift-context builder the recursive interpreter uses to
cross into a nested frame — the project supplies the provider VM/container
identity for each frame (§ U).
-}
withFrameContext :: (ProjectConfig -> StepFrame -> LiftContext) -> ProjectSpec -> ProjectSpec
withFrameContext f spec = spec{psFrameContext = f}

{- | Attach the project's chain-frame teardown: how @project down@ (stop, @False@)
and @project destroy@ (delete, @True@) tear down the frames the chain provisioned
(for the demo: stop/delete the VM). Runs after the core's recursive cluster
teardown (which preserves host @.data@, § O), so the outermost frame — the VM — is
stopped or deleted last. Best-effort and idempotent: a missing frame is not an
error, so a partial stack always tears down.
-}
withTeardown :: (ProjectConfig -> Bool -> IO ()) -> ProjectSpec -> ProjectSpec
withTeardown f spec = spec{psTeardown = f}

{- | Attach the project's service-handler registry (one of the extension streams,
§ T, § AA): the long-running roles @service run \<variant\>@ dispatches over. The
registry may be empty (not every project ships a service); the fixed @service@
surface is unchanged either way.
-}
withServices :: ServiceRegistry -> ProjectSpec -> ProjectSpec
withServices svcs spec = spec{psServices = svcs}

{- | Run the host-bootstrap CLI for @progName@, extending the core command tree
with a validated project spec.
-}
runHostBootstrapCLI :: String -> ProjectSpec -> IO ()
runHostBootstrapCLI progName spec = do
    either die pure (validateProjectSpec spec)
    runCLI progName (psArtifacts spec) (psTestSuite spec) (psCheckCode spec) (psServices spec) (psChain spec) (psFrameContext spec) (psTeardown spec)

{- | Run the bare core binary. This is the only supported path that intentionally
has no project artifacts, an empty test matrix, and no service registry.
-}
runBareHostBootstrapCLI :: String -> IO ()
runBareHostBootstrapCLI progName =
    runCLI
        progName
        []
        emptySuite
        (putStrLn "check-code: bare core binary has no project checks")
        emptyServiceRegistry
        (const [])
        (const (const localContext))
        (\_ _ -> pure ())

runCLI ::
    String ->
    [ConfigArtifact] ->
    TestSuite ->
    IO () ->
    ServiceRegistry ->
    (ProjectConfig -> [Step]) ->
    (ProjectConfig -> StepFrame -> LiftContext) ->
    (ProjectConfig -> Bool -> IO ()) ->
    IO ()
runCLI progName projectArtifacts testSuite checkCode services chain frameCtx teardown =
    join (customExecParser (prefs showHelpOnEmpty) opts)
  where
    allCommands = coreCommands progName projectArtifacts testSuite checkCode services chain frameCtx teardown
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

validateProjectSpec :: ProjectSpec -> Either String ()
validateProjectSpec spec
    | testSuiteCaseCount (psTestSuite spec) == 0 =
        Left "project test suite is empty; use runBareHostBootstrapCLI only for the bare core binary"
    | not (null duplicateCases) =
        Left ("project test case ids are duplicated: " ++ comma duplicateCases)
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
