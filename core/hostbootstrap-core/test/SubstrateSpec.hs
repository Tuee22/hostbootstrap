module SubstrateSpec (tests) where

import Data.List (isInfixOf)
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Substrate
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "SubstrateSpec"
        [ testGroup "parseDockerArch" archCases
        , testGroup "classify" classifyCases
        , testGroup "predicates" predicateCases
        , testGroup "invocation-context seam" seamCases
        ]

archCases :: [TestTree]
archCases =
    [ testCase "x86_64 -> amd64" (parseDockerArch "x86_64" @?= Right Amd64)
    , testCase "amd64 -> amd64" (parseDockerArch "amd64" @?= Right Amd64)
    , testCase "aarch64 -> arm64" (parseDockerArch "aarch64" @?= Right Arm64)
    , testCase "ARM64 (case-insensitive) -> arm64" (parseDockerArch "ARM64" @?= Right Arm64)
    , testCase "unknown rejected" (isLeft (parseDockerArch "ppc64le") @?= True)
    ]

classifyCases :: [TestTree]
classifyCases =
    [ testCase "darwin arm64 -> apple-silicon" $
        classify "darwin" "arm64" False @?= Right (Substrate AppleSilicon Arm64)
    , testCase "darwin x86_64 rejected" $
        isLeft (classify "darwin" "x86_64" False) @?= True
    , testCase "linux x86_64 no gpu -> linux-cpu" $
        classify "linux" "x86_64" False @?= Right (Substrate LinuxCpu Amd64)
    , testCase "linux x86_64 gpu -> linux-gpu" $
        classify "linux" "x86_64" True @?= Right (Substrate LinuxGpu Amd64)
    , testCase "linux aarch64 no gpu -> linux-cpu arm64" $
        classify "linux" "aarch64" False @?= Right (Substrate LinuxCpu Arm64)
    , testCase "mingw32 x86_64 no gpu -> windows-cpu" $
        classify "mingw32" "x86_64" False @?= Right (Substrate WindowsCpu Amd64)
    , testCase "mingw32 x86_64 gpu -> windows-gpu" $
        classify "mingw32" "x86_64" True @?= Right (Substrate WindowsGpu Amd64)
    , testCase "unknown platform rejected" $
        isLeft (classify "windows" "x86_64" False) @?= True
    ]

predicateCases :: [TestTree]
predicateCases =
    [ testCase "apple-silicon is apple, not linux, no gpu" $ do
        let s = Substrate AppleSilicon Arm64
        (isAppleSilicon s, isLinux s, hasGpu s) @?= (True, False, False)
    , testCase "linux-gpu is linux with gpu" $ do
        let s = Substrate LinuxGpu Amd64
        (isAppleSilicon s, isLinux s, hasGpu s) @?= (False, True, True)
    , testCase "windows-gpu is not linux and has gpu" $ do
        let s = Substrate WindowsGpu Amd64
        (isAppleSilicon s, isLinux s, hasGpu s) @?= (False, False, True)
    , testCase "render names" $
        map renderSubstrateName [AppleSilicon, LinuxCpu, LinuxGpu, WindowsCpu, WindowsGpu]
            @?= ["apple-silicon", "linux-cpu", "linux-gpu", "windows-cpu", "windows-gpu"]
    , testCase "the accelerator answer is a case over the whole sum" $
        -- A total case is what makes a new substrate a compile error here rather
        -- than a silent "no accelerator"; this pins the answer it gives for each
        -- constructor the sum currently has.
        map (hasGpu . (`Substrate` Amd64)) [AppleSilicon, LinuxCpu, LinuxGpu, WindowsCpu, WindowsGpu]
            @?= [False, False, True, False, True]
    ]

seamCases :: [TestTree]
seamCases =
    [ testCase "no statement means classify this host" $
        parseStatedHost Nothing Nothing @?= Nothing
    , testCase "a complete statement is the host" $
        parseStatedHost (Just "linux-gpu") (Just "amd64")
            @?= Just (Right (Substrate LinuxGpu Amd64))
    , testCase "every rendered tag reads back" $
        map
            (\name -> parseStatedHost (Just (renderSubstrateName name)) (Just "arm64"))
            [AppleSilicon, LinuxCpu, LinuxGpu, WindowsCpu, WindowsGpu]
            @?= map (\name -> Just (Right (Substrate name Arm64))) [AppleSilicon, LinuxCpu, LinuxGpu, WindowsCpu, WindowsGpu]
    , testCase "half a statement is a refusal, not a fallback" $ do
        parseStatedHost (Just "linux-cpu") Nothing
            @?= Just (Left ("incomplete invocation context: " ++ archEnvVar ++ " is unset"))
        parseStatedHost Nothing (Just "amd64")
            @?= Just (Left ("incomplete invocation context: " ++ substrateEnvVar ++ " is unset"))
    , testCase "an unknown tag is refused" $
        fmap isLeft (parseStatedHost (Just "linux-tpu") (Just "amd64")) @?= Just True
    , testCase "the bootstrapper states this seam in the same words" $ do
        -- The seam has two ends in two languages, so the sender's spelling is read
        -- here rather than agreed by comment. § M makes the bootstrapper the one
        -- that detects; this asserts the binary is listening on the field it
        -- actually writes, with the vocabulary it actually writes.
        cwd <- getCurrentDirectory
        root <-
            findRepoRoot cwd
                >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
        bootstrapper <- readFile (root </> "hostbootstrap" </> "substrate.py")
        mapM_
            ( \spelling ->
                assertBool
                    ("hostbootstrap/substrate.py does not state " ++ spelling)
                    (show spelling `isInfixOf` bootstrapper)
            )
            ( [substrateEnvVar, archEnvVar]
                ++ map renderSubstrateName [AppleSilicon, LinuxCpu, LinuxGpu, WindowsCpu, WindowsGpu]
                ++ map renderArch [Amd64, Arm64]
            )
    ]

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
