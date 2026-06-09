module Main (main) where

import qualified CordonSpec
import qualified DhallGenSpec
import qualified DocValidatorSpec
import qualified EnsureSpec
import qualified HarnessSpec
import qualified HostToolSpec
import qualified IncusSpec
import qualified LifecycleSpec
import qualified SchemaSpec
import qualified SubstrateSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = do
  docTests <- DocValidatorSpec.tests
  defaultMain $
    testGroup
      "hostbootstrap-core"
      [ SubstrateSpec.tests,
        HostToolSpec.tests,
        EnsureSpec.tests,
        SchemaSpec.tests,
        DhallGenSpec.tests,
        CordonSpec.tests,
        LifecycleSpec.tests,
        HarnessSpec.tests,
        IncusSpec.tests,
        docTests
      ]
