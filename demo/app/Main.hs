-- | The hostbootstrap-demo metal-orchestrator binary.
--
-- It calls 'runHostBootstrapCLI' with the demo's project commands, so the demo
-- binary shows the inherited core verbs (@ensure@, @config@, @cluster@, @test@,
-- @check-code@) alongside its own noun-first verbs (@incus@/@vm@/@harbor@/@web@)
-- without re-implementing any core verb. See
-- @documents/operations/demo_runbook.md@.
module Main (main) where

import HostBootstrap.CLI (runHostBootstrapCLI)
import HostBootstrap.Harness (TestSuite (TestSuite))
import HostBootstrapDemo.Commands (demoCases, demoCommands, demoSeams)

main :: IO ()
main = runHostBootstrapCLI "hostbootstrap-demo" demoCommands (TestSuite demoSeams demoCases)
