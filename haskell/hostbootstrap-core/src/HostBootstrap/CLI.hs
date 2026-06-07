-- | The composable @optparse-applicative@ command tree and the generic
-- entrypoint project binaries use to extend it.
--
-- A project binary calls 'runHostBootstrapCLI' with its own subcommands; the
-- entrypoint merges them with the core command tree
-- ('HostBootstrap.Command.coreCommands') and runs the resulting parser. The
-- skeletal @hostbootstrap@ binary baked into the base image passes no project
-- commands. See @documents/architecture/hostbootstrap_core_library.md@.
module HostBootstrap.CLI
  ( runHostBootstrapCLI,
  )
where

import Control.Monad (join)
import HostBootstrap.Command (coreCommands)
import Options.Applicative

-- | Run the host-bootstrap CLI for @progName@, extending the core command tree
-- with @projectCommands@.
runHostBootstrapCLI :: String -> [Mod CommandFields (IO ())] -> IO ()
runHostBootstrapCLI progName projectCommands =
  join (customExecParser (prefs showHelpOnEmpty) opts)
  where
    allCommands = coreCommands ++ projectCommands
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
      [] -> pure (putStrLn (progName ++ ": no commands available"))
      cs -> hsubparser (mconcat cs)
