module Main (main) where

import qualified AcceleratorRuntimeSpec
import qualified AcceleratorSpec
import qualified CommandsSpec
import qualified ConfigSpec
import Data.List (isInfixOf)
import HostBootstrap.DocValidator (findRepoRoot)
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)
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
            , componentContract
            ]

componentContract :: TestTree
componentContract =
    testCase "the Warp test component retains the threaded RTS contract" $ do
        cwd <- getCurrentDirectory
        root <- findRepoRoot cwd >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
        cabalFile <- readFile (root </> "demo" </> "hostbootstrap-demo.cabal")
        let stanza =
                unlines
                    . takeWhile isStanzaLine
                    . drop 1
                    . dropWhile (/= "test-suite hostbootstrap-demo-test")
                    $ lines cabalFile
        assertBool
            "hostbootstrap-demo-test must use -threaded, -rtsopts, and -with-rtsopts=-N while WebServerSpec starts Warp"
            ("ghc-options: -threaded -rtsopts \"-with-rtsopts=-N\"" `isInfixOf` stanza)
  where
    isStanzaLine [] = True
    isStanzaLine (' ' : _) = True
    isStanzaLine _ = False
