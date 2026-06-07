module Main (main) where

import qualified CordonSpec
import qualified DocValidatorSpec
import qualified EnsureSpec
import qualified HostToolSpec
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
        CordonSpec.tests,
        LifecycleSpec.tests,
        docTests
      ]
