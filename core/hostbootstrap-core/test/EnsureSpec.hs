{-# LANGUAGE ScopedTypeVariables #-}

module EnsureSpec (tests) where

import Control.Exception (try)
import Data.Either (isLeft)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import HostBootstrap.Command (allReconcilers)
import HostBootstrap.Ensure (InstallStep (..), Reconciler (..), decide, runReconciler)
import qualified HostBootstrap.Ensure.Colima as Colima
import qualified HostBootstrap.Ensure.Cuda as Cuda
import qualified HostBootstrap.Ensure.Docker as Docker
import qualified HostBootstrap.Ensure.Ghc as Ghc
import qualified HostBootstrap.Ensure.Homebrew as Homebrew
import qualified HostBootstrap.Ensure.Incus as EIncus
import qualified HostBootstrap.Ensure.Lima as Lima
import qualified HostBootstrap.Ensure.Tart as Tart
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (..))
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
      testGroup "runReconciler" runCases,
      testGroup "install plans" installPlanCases
    ]

applicabilityCases :: [TestTree]
applicabilityCases =
  [ testCase "the eight reconcilers are present (incl. cross-substrate incus)" $
      map reconcilerName allReconcilers
        @?= ["docker", "colima", "cuda", "homebrew", "ghc", "tart", "lima", "incus"],
    testCase "docker applies to every substrate" $
      map (appliesTo (findR "docker")) [apple, cpu, gpu] @?= [True, True, True],
    testCase "incus applies to apple AND linux (the first cross-substrate reconciler)" $
      map (appliesTo (findR "incus")) [apple, cpu, gpu] @?= [True, True, True],
    testCase "colima applies to apple-silicon only" $
      map (appliesTo (findR "colima")) [apple, cpu, gpu] @?= [True, False, False],
    testCase "cuda applies to linux-gpu only" $
      map (appliesTo (findR "cuda")) [apple, cpu, gpu] @?= [False, False, True],
    testCase "homebrew applies to apple-silicon only" $
      map (appliesTo (findR "homebrew")) [apple, cpu, gpu] @?= [True, False, False],
    testCase "ghc applies to apple-silicon only" $
      map (appliesTo (findR "ghc")) [apple, cpu, gpu] @?= [True, False, False],
    testCase "tart applies to apple-silicon only" $
      map (appliesTo (findR "tart")) [apple, cpu, gpu] @?= [True, False, False],
    testCase "lima applies to apple-silicon only" $
      map (appliesTo (findR "lima")) [apple, cpu, gpu] @?= [True, False, False]
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

-- | The pure, substrate-branched install planners (install-and-verify, § L):
-- Homebrew formulae on apple-silicon; apt/ghcup/container-toolkit on linux. The
-- IO driver is exercised during real bootstrap runs; these assert the plans.
installPlanCases :: [TestTree]
installPlanCases =
  [ testCase "colima: brew install + start on apple, Left elsewhere" $ do
      Colima.installSteps apple
        @?= Right [InstallStep Brew ["install", "colima"], InstallStep Colima ["start"]]
      assertBool "colima Left on linux-cpu" (isLeft (Colima.installSteps cpu)),
    testCase "tart: brew install cirruslabs/cli/tart on apple" $
      Tart.installSteps apple @?= Right [InstallStep Brew ["install", "cirruslabs/cli/tart"]],
    testCase "lima: brew install lima on apple" $
      Lima.installSteps apple @?= Right [InstallStep Brew ["install", "lima"]],
    testCase "ghc: brew ghcup then ghcup install ghc on apple" $
      Ghc.installSteps apple
        @?= Right [InstallStep Brew ["install", "ghcup"], InstallStep Ghcup ["install", "ghc"]],
    testCase "homebrew: no resolved-tool plan (toolchain root)" $
      assertBool "homebrew Left on apple" (isLeft (Homebrew.installSteps apple)),
    testCase "docker: apt install on linux, defer to colima on apple" $ do
      let linux = Right [InstallStep Sudo ["apt-get", "install", "-y", "docker.io", "acl"], InstallStep Sudo ["systemctl", "enable", "--now", "docker"]]
      Docker.installSteps cpu @?= linux
      Docker.installSteps gpu @?= linux
      assertBool "docker Left on apple" (isLeft (Docker.installSteps apple)),
    testCase "docker: linux socket user prefers the invoking sudo user and skips root" $ do
      Docker.targetDockerUser [("SUDO_USER", "matt"), ("USER", "root")] @?= Just "matt"
      Docker.targetDockerUser [("SUDO_USER", "root"), ("LOGNAME", "matt"), ("USER", "root")]
        @?= Just "matt"
      Docker.targetDockerUser [("SUDO_USER", "root"), ("USER", "root")] @?= Nothing
      Docker.targetDockerUser [("USER", "")] @?= Nothing,
    testCase "cuda: container toolkit on linux-gpu, Left elsewhere" $ do
      Cuda.installSteps gpu
        @?= Right
          [ InstallStep Sudo ["apt-get", "install", "-y", "nvidia-container-toolkit"],
            InstallStep Sudo ["nvidia-ctk", "runtime", "configure", "--runtime=docker"],
            InstallStep Sudo ["systemctl", "restart", "docker"]
          ]
      assertBool "cuda Left on linux-cpu" (isLeft (Cuda.installSteps cpu)),
    testCase "incus: Colima-backed provider on apple, native daemon on linux" $ do
      EIncus.installSteps apple
        @?= Right
          [ InstallStep Brew ["install", "incus"],
            InstallStep Brew ["install", "colima"],
            InstallStep Colima ["start", EIncus.appleIncusProfile, "--runtime", "incus"]
          ]
      let linux =
            Right
              [ InstallStep Sudo ["apt-get", "install", "-y", "incus"],
                InstallStep Sudo ["incus", "admin", "init", "--minimal"]
              ]
      EIncus.installSteps cpu @?= linux
      EIncus.installSteps gpu @?= linux,
    testCase "incus: linux admin user prefers the invoking sudo user and skips root" $ do
      EIncus.targetIncusAdminUser [("SUDO_USER", "matt"), ("USER", "root")] @?= Just "matt"
      EIncus.targetIncusAdminUser [("SUDO_USER", "root"), ("LOGNAME", "matt"), ("USER", "root")]
        @?= Just "matt"
      EIncus.targetIncusAdminUser [("SUDO_USER", "root"), ("USER", "root")] @?= Nothing
      EIncus.targetIncusAdminUser [("USER", "")] @?= Nothing
  ]

isRight :: Either a b -> Bool
isRight = either (const False) (const True)
