{- | The composable @optparse-applicative@ command tree and the generic
entrypoints project binaries use to extend it.

A project binary calls 'runHostBootstrapCLI' with a 'ProjectSpec'. The
entrypoint validates that the project appended distinct command names, supplied
a non-empty test matrix, provided its @check-code@ action, and then merges it
with the core command tree ('HostBootstrap.Command.coreCommands'). The bare
@hostbootstrap@ binary (built like any project binary, not baked into the base
image) uses the separate 'runBareHostBootstrapCLI'. See
@documents/architecture/hostbootstrap_core_library.md@.
-}
module HostBootstrap.CLI (
    ProjectCommand,
    ProjectSpec,
    projectCommand,
    projectSpec,
    withChain,
    withFrameContext,
    withTeardown,
    runHostBootstrapCLI,
    runBareHostBootstrapCLI,
)
where

import Control.Monad (join)
import Data.List (group, intercalate, sort)
import qualified Data.Text as T
import HostBootstrap.Command (coreCommandNames, coreCommands)
import HostBootstrap.Config.Schema (ProjectConfig)
import HostBootstrap.Dhall.Gen (ConfigArtifact (..), coreArtifacts)
import HostBootstrap.Harness (TestSuite, emptySuite, testSuiteCaseCount, testSuiteCaseIds)
import HostBootstrap.Lift (LiftContext, localContext)
import HostBootstrap.Step (Step, StepFrame)
import Options.Applicative
import System.Exit (die)

{- | One top-level project command. The name is carried with the parser info so the
CLI layer can reject shadowing before constructing the final parser.
-}
data ProjectCommand = ProjectCommand String (ParserInfo (IO ()))

-- | Build a named project command.
projectCommand :: String -> ParserInfo (IO ()) -> ProjectCommand
projectCommand = ProjectCommand

{- | A derived project's required extension points. There are no ambient project
defaults here: the project must supply its own command delta, runtime test
suite, code-check action, and schema artifact delta. The bare core binary uses
'runBareHostBootstrapCLI' instead.
-}
data ProjectSpec = ProjectSpec
    { psCommands :: [ProjectCommand]
    , psTestSuite :: TestSuite
    , psCheckCode :: IO ()
    , psArtifacts :: [ConfigArtifact]
    , psChain :: ProjectConfig -> [Step]
    , psFrameContext :: ProjectConfig -> StepFrame -> LiftContext
    , -- | The chain-frame teardown the @project down@ / @project destroy@
      -- lifecycle runs after the recursive cluster teardown: stop (@False@) or
      -- delete (@True@) the project-provisioned frames (e.g. the VM). Best-effort
      -- and idempotent; the never-delete-@.data@ invariant (§ O) is the cluster
      -- teardown's responsibility. Attach with 'withTeardown'.
      psTeardown :: ProjectConfig -> Bool -> IO ()
    }

{- | Build a project spec. The project's lift chain (its primary CLI
contribution, § Y) and per-frame lift-context builder default to empty/local;
attach them with 'withChain' / 'withFrameContext'.
-}
projectSpec :: [ProjectCommand] -> TestSuite -> IO () -> [ConfigArtifact] -> ProjectSpec
projectSpec cmds suite check arts =
    ProjectSpec cmds suite check arts (const []) (const (const localContext)) (\_ _ -> pure ())

{- | Attach the project's lift chain: a pure function from the root
@<project>.dhall@ config to the ordered @[Step]@ the core @project@ lifecycle
interprets (§ Y). The chain is the project's primary CLI contribution.
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

{- | Run the host-bootstrap CLI for @progName@, extending the core command tree
with a validated project spec.
-}
runHostBootstrapCLI :: String -> ProjectSpec -> IO ()
runHostBootstrapCLI progName spec = do
    either die pure (validateProjectSpec spec)
    runCLI progName (projectCommands spec) (psArtifacts spec) (psTestSuite spec) (psCheckCode spec) (psChain spec) (psFrameContext spec) (psTeardown spec)

{- | Run the bare core binary. This is the only supported path that intentionally
has no project commands, no project checks, no project artifacts, and an empty
test matrix.
-}
runBareHostBootstrapCLI :: String -> IO ()
runBareHostBootstrapCLI progName =
    runCLI
        progName
        []
        []
        emptySuite
        (putStrLn "check-code: bare core binary has no project checks")
        (const [])
        (const (const localContext))
        (\_ _ -> pure ())

runCLI ::
    String ->
    [Mod CommandFields (IO ())] ->
    [ConfigArtifact] ->
    TestSuite ->
    IO () ->
    (ProjectConfig -> [Step]) ->
    (ProjectConfig -> StepFrame -> LiftContext) ->
    (ProjectConfig -> Bool -> IO ()) ->
    IO ()
runCLI progName projectCommandMods projectArtifacts testSuite checkCode chain frameCtx teardown =
    join (customExecParser (prefs showHelpOnEmpty) opts)
  where
    allCommands = coreCommands progName projectArtifacts testSuite checkCode chain frameCtx teardown ++ projectCommandMods
    opts =
        info
            (parser <**> helper)
            ( fullDesc
                <> header (progName ++ " - host bootstrap")
                <> progDesc
                    ( "Host-management commands for "
                        ++ progName
                        ++ ". Project binaries extend this tree with their own subcommands."
                    )
            )
    parser :: Parser (IO ())
    parser = hsubparser (mconcat allCommands)

projectCommands :: ProjectSpec -> [Mod CommandFields (IO ())]
projectCommands spec = [command name info' | ProjectCommand name info' <- psCommands spec]

validateProjectSpec :: ProjectSpec -> Either String ()
validateProjectSpec spec
    | not (null shadowedCommands) =
        Left ("project commands shadow core commands: " ++ comma shadowedCommands)
    | not (null duplicateCommands) =
        Left ("project command names are duplicated: " ++ comma duplicateCommands)
    | testSuiteCaseCount (psTestSuite spec) == 0 =
        Left "project test suite is empty; use runBareHostBootstrapCLI only for the bare core binary"
    | not (null duplicateCases) =
        Left ("project test case ids are duplicated: " ++ comma duplicateCases)
    | not (null shadowedArtifacts) =
        Left ("project artifacts shadow core artifacts: " ++ comma shadowedArtifacts)
    | not (null duplicateArtifacts) =
        Left ("project artifact names are duplicated: " ++ comma duplicateArtifacts)
    | otherwise = Right ()
  where
    commandNames = [name | ProjectCommand name _ <- psCommands spec]
    shadowedCommands = filter (`elem` coreCommandNames) commandNames
    duplicateCommands = duplicates commandNames
    caseIds = testSuiteCaseIds (psTestSuite spec)
    duplicateCases = duplicates caseIds
    artifactNames = map (T.unpack . artifactName) (psArtifacts spec)
    coreArtifactNames = map (T.unpack . artifactName) coreArtifacts
    shadowedArtifacts = filter (`elem` coreArtifactNames) artifactNames
    duplicateArtifacts = duplicates artifactNames

duplicates :: [String] -> [String]
duplicates names = [name | name : _ : _ <- group (sort names)]

comma :: [String] -> String
comma = intercalate ", "
