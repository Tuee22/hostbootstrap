module Main (main) where

import qualified AcceleratorRuntimeSpec
import qualified AcceleratorSpec
import qualified CommandsSpec
import qualified ConfigSpec
import Test.Tasty (defaultMain, testGroup)
import qualified WebServerSpec

main :: IO ()
main =
    defaultMain $
        testGroup
            "hostbootstrap-demo"
            [ AcceleratorSpec.tests
            , AcceleratorRuntimeSpec.tests
            , CommandsSpec.tests
            , ConfigSpec.tests
            , WebServerSpec.tests
            ]
