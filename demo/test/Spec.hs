module Main (main) where

import qualified ConfigSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
    defaultMain $
        testGroup
            "hostbootstrap-demo"
            [ ConfigSpec.tests
            ]
