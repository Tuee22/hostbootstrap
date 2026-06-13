-- | The composable @optparse-applicative@ command tree and the generic
-- entrypoint project binaries use to extend it.
--
-- A project binary calls 'runHostBootstrapCLI' with its own subcommands; the
-- entrypoint merges them with the core command tree
-- ('HostBootstrap.Command.coreCommands') and runs the resulting parser. The
-- bare @hostbootstrap@ binary (built like any project binary, not baked
-- into the base image) passes no project commands. See
-- @documents/architecture/hostbootstrap_core_library.md@.
module HostBootstrap.CLI
  ( runHostBootstrapCLI,
  )
where

import Control.Monad (join)
import qualified Data.Text as T
import HostBootstrap.Command (coreCommands)
import HostBootstrap.Context (defaultResourceEnvelope, standaloneContainerContext, writeContextFile)
import HostBootstrap.Harness (TestSuite)
import Options.Applicative
import System.Directory (getCurrentDirectory)

-- | Run the host-bootstrap CLI for @progName@, extending the core command tree
-- with @projectCommands@ and threading the project's @testSuite@ into the
-- inherited @test@ verb (so the project's cases run under @test@). The bare
-- binary passes no project commands and 'HostBootstrap.Harness.emptySuite'.
runHostBootstrapCLI :: String -> [Mod CommandFields (IO ())] -> TestSuite -> IO ()
runHostBootstrapCLI progName projectCommands testSuite =
  join (customExecParser (prefs showHelpOnEmpty) opts)
  where
    allCommands = coreCommands progName testSuite ++ projectCommands
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
    parser = case allCommands of
      [] -> createContainerShortcut <|> pure (putStrLn (progName ++ ": no commands available"))
      cs -> createContainerShortcut <|> hsubparser (mconcat cs)

    createContainerShortcut :: Parser (IO ())
    createContainerShortcut =
      writeDefaultContainerConfig
        <$> strOption
          ( long "create-container-config"
              <> metavar "OUTPUT"
              <> help "bootstrap-only shortcut: create a project-container binary-context config"
          )

    writeDefaultContainerConfig :: FilePath -> IO ()
    writeDefaultContainerConfig out = do
      root <- getCurrentDirectory
      let ctx =
            standaloneContainerContext
              (T.pack progName)
              (T.pack progName)
              (T.pack root)
              defaultResourceEnvelope
      writeContextFile out ctx
