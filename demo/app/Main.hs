{- | The hostbootstrap-demo metal-orchestrator binary.

It calls 'runHostBootstrapCLI' with the demo's project spec, so the demo binary
shows the inherited core verbs (@ensure@, @config@, @cluster@, @test@,
@check-code@) alongside its own noun-first verbs (@incus@/@vm@/@harbor@/@web@)
without re-implementing any core verb. See
@documents/operations/demo_runbook.md@.
-}
module Main (main) where

import HostBootstrap.CLI (projectSpec, runHostBootstrapCLI)
import HostBootstrap.Harness (TestSuite (TestSuite))
import HostBootstrapDemo.Commands (demoArtifacts, demoCases, demoCheckCode, demoCommands, demoSeams)

main :: IO ()
main =
    runHostBootstrapCLI
        "hostbootstrap-demo"
        (projectSpec demoCommands (TestSuite demoSeams demoCases) demoCheckCode demoArtifacts)
