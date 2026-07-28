module Main (main) where

import qualified CLISpec
import qualified BudgetSpec
import qualified ChainSpec
import qualified ColimaSpec
import qualified CompileFailSpec
import qualified ContextSpec
import qualified CordonSpec
import qualified DhallGenSpec
import qualified DocValidatorSpec
import qualified EnsureSpec
import qualified HarnessSpec
import qualified HostToolSpec
import qualified IncusSpec
import qualified LifecycleSpec
import qualified LiftSpec
import qualified LimaSpec
import qualified ProjectRootSpec
import qualified ClusterReconcileSpec
import qualified ProviderSpec
import qualified ProviderAliasSpec
import qualified ReadinessSpec
import qualified ReconcileSpec
import qualified RegistrySpec
import qualified RoleLifecycleSpec
import qualified SchemaSpec
import qualified StepSpec
import qualified SubstrateSpec
import System.Environment (getArgs)
import Test.Tasty (defaultMain, localOption, testGroup)
import Test.Tasty.Runners (NumThreads (..))
import qualified Wsl2Spec
import qualified WslGlobalWallConfigBytesSpec
import qualified WslGlobalWallSpec
import qualified WslGlobalWallWindowsSpec

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["--hostbootstrap-schema-fixture", fixture] ->
            CLISpec.runSchemaFixture fixture
        _ -> do
            docTests <- DocValidatorSpec.tests
            -- The suite runs single-threaded because several groups drive
            -- process-global state that has no per-test scope: CLISpec,
            -- ContextSpec, HarnessSpec, and ProjectRootSpec bracket a
            -- 'withCurrentDirectory', and the harness/config ownership guards
            -- claim lock directories at paths relative to that working
            -- directory (@.test_data.hostbootstrap-run-owner@,
            -- @<project>.dhall.hostbootstrap-test-owner@). Run concurrently,
            -- one group's chdir is visible to every other group, so the guards
            -- collide, a bracket's cleanup deletes a path it no longer resolves
            -- to, and the leftover lock directories poison the *next* run as
            -- well. Those guards are the behaviour under test, so the fix is to
            -- stop scheduling them against each other rather than to weaken
            -- them. The whole suite is ~10s serially, so the ordering costs
            -- nothing worth reclaiming.
            defaultMain $
                localOption (NumThreads 1) $
                    testGroup
                        "hostbootstrap-core"
                        [ CLISpec.tests
                        , BudgetSpec.tests
                        , CompileFailSpec.tests
                        , SubstrateSpec.tests
                        , HostToolSpec.tests
                        , EnsureSpec.tests
                        , ColimaSpec.tests
                        , SchemaSpec.tests
                        , DhallGenSpec.tests
                        , CordonSpec.tests
                        , ProviderSpec.tests
                        , ProviderAliasSpec.tests
                        , ClusterReconcileSpec.tests
                        , ProjectRootSpec.tests
                        , ContextSpec.tests
                        , LifecycleSpec.tests
                        , HarnessSpec.tests
                        , IncusSpec.tests
                        , LimaSpec.tests
                        , Wsl2Spec.tests
                        , WslGlobalWallSpec.tests
                        , WslGlobalWallConfigBytesSpec.tests
                        , WslGlobalWallWindowsSpec.tests
                        , LiftSpec.tests
                        , StepSpec.tests
                        , ChainSpec.tests
                        , ReadinessSpec.tests
                        , ReconcileSpec.tests
                        , RegistrySpec.tests
                        , RoleLifecycleSpec.tests
                        , docTests
                        ]
