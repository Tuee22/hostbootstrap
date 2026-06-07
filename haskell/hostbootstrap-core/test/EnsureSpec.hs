{-# LANGUAGE ScopedTypeVariables #-}

module EnsureSpec (tests) where

import Control.Exception (try)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import HostBootstrap.Command (allReconcilers)
import HostBootstrap.Ensure (Reconciler (..), decide, runReconciler)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.Substrate (Arch (..), Substrate (..), SubstrateName (..))
import System.Exit (ExitCode (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

apple, cpu, gpu :: Substrate
apple = Substrate AppleSilicon Arm64
cpu = Substrate LinuxCpu Amd64
gpu = Substrate LinuxGpu Amd64

findR :: String -> Reconciler
findR name = case filter ((== name) . reconcilerName) allReconcilers of
  (r : _) -> r
  [] -> error ("no reconciler named " ++ name)

tests :: TestTree
tests =
  testGroup
    "EnsureSpec"
    [ testGroup "applicability matrix" applicabilityCases,
      testGroup "decide" decideCases,
      testGroup "runReconciler" runCases
    ]

applicabilityCases :: [TestTree]
applicabilityCases =
  [ testCase "the six reconcilers are present" $
      map reconcilerName allReconcilers @?= ["docker", "colima", "cuda", "homebrew", "ghc", "tart"],
    testCase "docker applies to every substrate" $
      map (appliesTo (findR "docker")) [apple, cpu, gpu] @?= [True, True, True],
    testCase "colima applies to apple-silicon only" $
      map (appliesTo (findR "colima")) [apple, cpu, gpu] @?= [True, False, False],
    testCase "cuda applies to linux-gpu only" $
      map (appliesTo (findR "cuda")) [apple, cpu, gpu] @?= [False, False, True],
    testCase "homebrew applies to apple-silicon only" $
      map (appliesTo (findR "homebrew")) [apple, cpu, gpu] @?= [True, False, False],
    testCase "ghc applies to apple-silicon only" $
      map (appliesTo (findR "ghc")) [apple, cpu, gpu] @?= [True, False, False],
    testCase "tart applies to apple-silicon only" $
      map (appliesTo (findR "tart")) [apple, cpu, gpu] @?= [True, False, False]
  ]

decideCases :: [TestTree]
decideCases =
  [ testCase "decide is Right on the applicable host" $
      assertBool "colima applicable on apple" (isRight (decide (findR "colima") apple)),
    testCase "decide is Left with a one-line diagnostic on the wrong host" $
      case decide (findR "colima") cpu of
        Left msg ->
          assertBool ("diagnostic mentions host + requirement: " ++ msg) $
            "ensure colima" `isInfixOf` msg
              && "linux-cpu" `isInfixOf` msg
              && "apple-silicon" `isInfixOf` msg
        Right _ -> assertBool "expected Left for colima on linux-cpu" False
  ]

runCases :: [TestTree]
runCases =
  [ testCase "wrong host: exits non-zero WITHOUT performing the action" $ do
      ref <- newIORef False
      let r = (findR "colima") {reconcile = \_ -> writeIORef ref True}
          cfg = HostConfig {hcSubstrate = cpu, hcToolPaths = Map.empty}
      result <- try (runReconciler r cfg) :: IO (Either ExitCode ())
      ran <- readIORef ref
      result @?= Left (ExitFailure 1)
      ran @?= False,
    testCase "right host: performs the reconcile action" $ do
      ref <- newIORef False
      let r = (findR "homebrew") {reconcile = \_ -> writeIORef ref True}
          cfg = HostConfig {hcSubstrate = apple, hcToolPaths = Map.empty}
      runReconciler r cfg
      ran <- readIORef ref
      ran @?= True
  ]

isRight :: Either a b -> Bool
isRight = either (const False) (const True)
