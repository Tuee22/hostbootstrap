{- | The hostbootstrap-demo metal-orchestrator binary.

It calls 'runHostBootstrapCLI' with the demo's project spec, so the demo binary
shows the inherited core verbs (@ensure@, @config@, @cluster@, @test@,
@check-code@) alongside its own noun-first verbs (@incus@/@vm@/@harbor@/@web@)
without re-implementing any core verb. See
@documents/operations/demo_runbook.md@.
-}
module Main (main) where

import HostBootstrap.CLI (projectSpec, runHostBootstrapCLI, withChain, withFrameContext, withTeardown)
import HostBootstrap.Harness (TestSuite (TestSuite))
import HostBootstrap.Registry (withForwardedRegistryAuth)
import HostBootstrap.Substrate (detect)
import HostBootstrapDemo.Commands (demoArtifacts, demoCases, demoChain, demoCheckCode, demoCommands, demoFrameContext, demoSeams, demoTeardown)
import System.Exit (die)

main :: IO ()
main =
    -- Every copy of the binary, at every level, consumes a forwarded Docker Hub
    -- credential (if a parent set HOSTBOOTSTRAP_REGISTRY_AUTH) into an ephemeral
    -- DOCKER_CONFIG for the run, so its nested kind/docker pulls authenticate;
    -- a no-op on the host and when there is no host login. See
    -- "HostBootstrap.Registry".
    withForwardedRegistryAuth $ do
        -- Detect the host substrate once so the per-frame resolver folds the
        -- metal→VM handoff to the right provider shell (Incus on Linux, Lima on
        -- Apple Silicon).
        substrate <- detect >>= either die pure
        runHostBootstrapCLI
            "hostbootstrap-demo"
            ( withChain
                demoChain
                ( withFrameContext
                    (demoFrameContext substrate)
                    (withTeardown demoTeardown (projectSpec demoCommands (TestSuite demoSeams demoCases) demoCheckCode demoArtifacts))
                )
            )
