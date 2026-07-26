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
import qualified ProviderSpec
import qualified ReadinessSpec
import qualified ReconcileSpec
import qualified RegistrySpec
import qualified RoleLifecycleSpec
import qualified SchemaSpec
import qualified StepSpec
import qualified SubstrateSpec
import System.Environment (getArgs)
import Test.Tasty (defaultMain, testGroup)
import qualified Wsl2Spec

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["--hostbootstrap-schema-fixture", fixture] ->
            CLISpec.runSchemaFixture fixture
        _ -> do
            docTests <- DocValidatorSpec.tests
            defaultMain $
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
                    , ProjectRootSpec.tests
                    , ContextSpec.tests
                    , LifecycleSpec.tests
                    , HarnessSpec.tests
                    , IncusSpec.tests
                    , LimaSpec.tests
                    , Wsl2Spec.tests
                    , LiftSpec.tests
                    , StepSpec.tests
                    , ChainSpec.tests
                    , ReadinessSpec.tests
                    , ReconcileSpec.tests
                    , RegistrySpec.tests
                    , RoleLifecycleSpec.tests
                    , docTests
                    ]
