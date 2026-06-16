module Main (main) where

import qualified CLISpec
import qualified ContainerSpec
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
import qualified RoleLifecycleSpec
import qualified SchemaSpec
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
            , RoleLifecycleSpec.tests
            , ContainerSpec.tests
            , docTests
            ]
