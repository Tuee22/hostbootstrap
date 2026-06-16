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
    runHostBootstrapCLI,
    runBareHostBootstrapCLI,
)
where

import Control.Monad (join)
import Data.List (group, intercalate, sort)
import qualified Data.Text as T
import HostBootstrap.Command (coreCommandNames, coreCommands)
import HostBootstrap.Dhall.Gen (ConfigArtifact (..), coreArtifacts)
import HostBootstrap.Harness (TestSuite, emptySuite, testSuiteCaseCount, testSuiteCaseIds)
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
    }

projectSpec :: [ProjectCommand] -> TestSuite -> IO () -> [ConfigArtifact] -> ProjectSpec
projectSpec = ProjectSpec

{- | Run the host-bootstrap CLI for @progName@, extending the core command tree
with a validated project spec.
-}
runHostBootstrapCLI :: String -> ProjectSpec -> IO ()
runHostBootstrapCLI progName spec = do
    either die pure (validateProjectSpec spec)
    runCLI progName (projectCommands spec) (psArtifacts spec) (psTestSuite spec) (psCheckCode spec)

{- | Run the bare core binary. This is the only supported path that intentionally
has no project commands, no project checks, no project artifacts, and an empty
test matrix.
-}
runBareHostBootstrapCLI :: String -> IO ()
runBareHostBootstrapCLI progName =
    runCLI progName [] [] emptySuite (putStrLn "check-code: bare core binary has no project checks")

runCLI :: String -> [Mod CommandFields (IO ())] -> [ConfigArtifact] -> TestSuite -> IO () -> IO ()
runCLI progName projectCommandMods projectArtifacts testSuite checkCode =
    join (customExecParser (prefs showHelpOnEmpty) opts)
  where
    allCommands = coreCommands progName projectArtifacts testSuite checkCode ++ projectCommandMods
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
