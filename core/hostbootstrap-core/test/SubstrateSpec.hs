module SubstrateSpec (tests) where

import HostBootstrap.Substrate
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "SubstrateSpec"
    [ testGroup "parseDockerArch" archCases,
      testGroup "classify" classifyCases,
      testGroup "predicates" predicateCases
    ]

archCases :: [TestTree]
archCases =
  [ testCase "x86_64 -> amd64" (parseDockerArch "x86_64" @?= Right Amd64),
    testCase "amd64 -> amd64" (parseDockerArch "amd64" @?= Right Amd64),
    testCase "aarch64 -> arm64" (parseDockerArch "aarch64" @?= Right Arm64),
    testCase "ARM64 (case-insensitive) -> arm64" (parseDockerArch "ARM64" @?= Right Arm64),
    testCase "unknown rejected" (isLeft (parseDockerArch "ppc64le") @?= True)
  ]

classifyCases :: [TestTree]
classifyCases =
  [ testCase "darwin arm64 -> apple-silicon" $
      classify "darwin" "arm64" False @?= Right (Substrate AppleSilicon Arm64),
    testCase "darwin x86_64 rejected" $
      isLeft (classify "darwin" "x86_64" False) @?= True,
    testCase "linux x86_64 no gpu -> linux-cpu" $
      classify "linux" "x86_64" False @?= Right (Substrate LinuxCpu Amd64),
    testCase "linux x86_64 gpu -> linux-gpu" $
      classify "linux" "x86_64" True @?= Right (Substrate LinuxGpu Amd64),
    testCase "linux aarch64 no gpu -> linux-cpu arm64" $
      classify "linux" "aarch64" False @?= Right (Substrate LinuxCpu Arm64),
    testCase "unknown platform rejected" $
      isLeft (classify "windows" "x86_64" False) @?= True
  ]

predicateCases :: [TestTree]
predicateCases =
  [ testCase "apple-silicon is apple, not linux, no gpu" $ do
      let s = Substrate AppleSilicon Arm64
      (isAppleSilicon s, isLinux s, hasGpu s) @?= (True, False, False),
    testCase "linux-gpu is linux with gpu" $ do
      let s = Substrate LinuxGpu Amd64
      (isAppleSilicon s, isLinux s, hasGpu s) @?= (False, True, True),
    testCase "render names" $
      map renderSubstrateName [AppleSilicon, LinuxCpu, LinuxGpu]
        @?= ["apple-silicon", "linux-cpu", "linux-gpu"]
  ]

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
