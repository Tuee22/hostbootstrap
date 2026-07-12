{- | The hostbootstrap-demo metal-orchestrator binary.

It calls 'runHostBootstrapCLI' with the demo's project spec, so the demo binary
surfaces exactly the fixed core command tree (@project@ / @test@ / @service@ /
@context@ / @check-code@) — it adds no verbs. The demo extends the core only
through the extension streams threaded into its 'projectSpec': its lift chain
('withChain'), per-frame lift context ('withFrameContext'), chain-frame teardown
('withTeardown'), service-handler registry ('withServices'), test suite, schema
artifacts, and @check-code@ action. See @documents/operations/demo_runbook.md@.
-}
module Main (main) where

import HostBootstrap.CLI (projectSpec, runHostBootstrapCLI, withChain, withFrameContext, withServiceConfig, withServices, withTeardown)
import HostBootstrap.Registry (withForwardedRegistryAuth)
import HostBootstrap.Substrate (detect)
import HostBootstrapDemo.Commands (demoArtifacts, demoChainFor, demoCheckCode, demoFrameContext, demoServices, demoTeardown, demoTestSuite)
import HostBootstrapDemo.Config (configuredServiceVariant, demoInit, demoTestConfig, demoTestInit)
import System.Exit (die)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stderr, stdout)

main :: IO ()
main = do
    -- Line-buffer stdout/stderr so every step announcement (and any failure `die`)
    -- streams live through a pipe instead of sitting in the default block buffer —
    -- essential for observing a long, lifted `project up`/`test run` in real time.
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
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
                (demoChainFor substrate)
                ( withFrameContext
                    (demoFrameContext substrate)
                    ( withTeardown
                        demoTeardown
                        ( withServiceConfig
                            configuredServiceVariant
                            ( withServices
                                demoServices
                                (projectSpec demoTestSuite demoCheckCode demoArtifacts demoInit demoTestInit demoTestConfig)
                            )
                        )
                    )
                )
            )
