{-# LANGUAGE OverloadedStrings #-}

module AcceleratorSpec (tests) where

import Data.List (isInfixOf)
import qualified Data.Text as T
import HostBootstrapDemo.Accelerator
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
    testGroup
        "AcceleratorSpec"
        [ testGroup "backend selection" backendCases
        , testGroup "source generation" sourceCases
        , testGroup "build argv" buildArgCases
        , testGroup "artifact hash" hashCases
        ]

backendCases :: [TestTree]
backendCases =
    [ testCase "apple uses Swift/Metal" $
        backendWorkerKind AppleMetalBackend @?= SwiftMetalWorker
    , testCase "linux-cpu uses C++" $
        backendWorkerKind LinuxCpuBackend @?= CppWorker
    , testCase "linux-gpu and windows-gpu use CUDA" $ do
        backendWorkerKind LinuxGpuBackend @?= CudaWorker
        backendWorkerKind WindowsGpuBackend @?= CudaWorker
    ]

sourceCases :: [TestTree]
sourceCases =
    [ testCase "Swift/Metal source probes a Metal device" $
        assertText "MTLCreateSystemDefaultDevice" (workerSource AppleMetalBackend)
    , testCase "CUDA source contains the real kernel" $
        assertText "__global__ void hostbootstrap_add" (workerSource LinuxGpuBackend)
    , testCase "C++ source performs the worker add outside the web server" $
        assertText "std::cin >> left >> right" (workerSource LinuxCpuBackend)
    ]

buildArgCases :: [TestTree]
buildArgCases =
    [ testCase "clang++ args compile the C++ worker" $
        cppBuildArgs "/src/add_worker.cpp" "/out/add-worker"
            @?= ["-O2", "-std=c++17", "/src/add_worker.cpp", "-o", "/out/add-worker"]
    , testCase "nvcc args compile the CUDA worker" $
        cudaBuildArgs "/src/add_worker.cu" "/out/add-worker"
            @?= ["/src/add_worker.cu", "-o", "/out/add-worker"]
    , testCase "swiftc args include explicit SDK and Metal framework" $
        swiftMetalBuildArgs "/SDK" "/src/AddWorker.swift" "/out/add-worker"
            @?= ["-O", "-sdk", "/SDK", "/src/AddWorker.swift", "-o", "/out/add-worker", "-framework", "Metal"]
    ]

hashCases :: [TestTree]
hashCases =
    [ testCase "source hashes are deterministic" $
        stableSourceHash (workerSource LinuxGpuBackend) @?= stableSourceHash (workerSource WindowsGpuBackend)
    , testCase "workerSpec paths include backend and hash" $ do
        let spec = workerSpec "/tmp/accel" LinuxCpuBackend
            hash = T.unpack (workerArtifactHash spec)
        workerSourcePath spec @?= "/tmp/accel" </> "linux-cpu" </> hash </> "add_worker.cpp"
        workerExecutablePath spec @?= "/tmp/accel" </> "linux-cpu" </> hash </> "accelerator-worker"
        assertBool "hash is fixed-width hex" (length hash == 16 && all (`elem` (['0' .. '9'] ++ ['a' .. 'f'])) hash)
    ]

assertText :: String -> T.Text -> IO ()
assertText needle hay =
    assertBool ("expected " ++ show needle ++ " in generated source") (needle `isInfixOf` T.unpack hay)
