module Main (main) where

import qualified CLISpec
import qualified ChainSpec
import qualified ContextSpec
import qualified CordonSpec
import qualified DhallGenSpec
import qualified DocValidatorSpec
import qualified EnsureSpec
import qualified HarnessSpec
import qualified HostToolSpec
import qualified IncusSpec
import qualified LimaSpec
import qualified LifecycleSpec
import qualified LiftSpec
import qualified RegistrySpec
import qualified RoleLifecycleSpec
import qualified SchemaSpec
import qualified StepSpec
import qualified SubstrateSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = do
    docTests <- DocValidatorSpec.tests
    defaultMain $
        testGroup
            "hostbootstrap-core"
            [ CLISpec.tests
            , SubstrateSpec.tests
            , HostToolSpec.tests
            , EnsureSpec.tests
            , SchemaSpec.tests
            , DhallGenSpec.tests
            , CordonSpec.tests
            , ContextSpec.tests
            , LifecycleSpec.tests
            , HarnessSpec.tests
            , IncusSpec.tests
            , LimaSpec.tests
            , LiftSpec.tests
            , StepSpec.tests
            , ChainSpec.tests
            , RegistrySpec.tests
            , RoleLifecycleSpec.tests
            , docTests
            ]
