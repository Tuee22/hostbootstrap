-- | A worked example of a project binary that extends the core command tree.
--
-- It calls 'runHostBootstrapCLI' with its own subcommands; the core verbs
-- (@ensure@, @config@) appear alongside the project verb (@greet@) without the
-- project re-implementing any core verb. See
-- @documents/engineering/derived_project_standards.md@.
module Main (main) where

import HostBootstrap.CLI (runHostBootstrapCLI)
import Options.Applicative

main :: IO ()
main = runHostBootstrapCLI "hostbootstrap-example" projectCommands

projectCommands :: [Mod CommandFields (IO ())]
projectCommands =
  [ command
      "greet"
      ( info
          (pure (putStrLn "hello from the project binary"))
          (progDesc "A project-specific verb that extends the core tree")
      )
  ]
