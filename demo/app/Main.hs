{- | The hostbootstrap-demo metal-orchestrator binary.

It calls 'runHostBootstrapCLI' with the demo's project spec, so the demo binary
surfaces exactly the fixed core command tree (@project@ / @test@ / @service@ /
@context@ / @check-code@) — it adds no verbs. The demo extends the core only
through the extension streams threaded into its opaque project builder: its
ordered steps ('addSteps', each carrying its own frame descent and its own
reverse effect), typed service registry ('addServices'), test suite, schema
artifacts, and @check-code@ action. See @documents/operations/demo_runbook.md@.
-}
module Main (main) where

import HostBootstrap.CLI (addServices, addSteps, finalizeProjectSpec, projectSpec, runHostBootstrapCLI)
import HostBootstrap.Registry (withForwardedRegistryAuth)
import HostBootstrap.Substrate (detect)
import HostBootstrapDemo.Commands (demoArtifacts, demoChainFor, demoCheckCode, demoServices, demoTestSuite)
import HostBootstrapDemo.Config (demoAssemble, demoTestInit, testConfigCodec)
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
        -- Detect the host substrate once so the chain's declared metal→VM
        -- descent folds to the right provider shell (Incus on Linux, Lima on
        -- Apple Silicon).
        substrate <- detect >>= either die pure
        let builder =
                addSteps
                    (demoChainFor substrate)
                    ( addServices
                        demoServices
                        (projectSpec demoTestSuite demoCheckCode demoArtifacts testConfigCodec demoTestInit demoAssemble)
                    )
        spec <- either (die . show) pure (finalizeProjectSpec builder)
        runHostBootstrapCLI "hostbootstrap-demo" spec
