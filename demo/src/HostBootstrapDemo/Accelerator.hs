{-# LANGUAGE OverloadedStrings #-}

{- | Demo accelerator worker source generation.

The daemon runtime is owned by the later service/runtime phases. This module is
the Phase-13 demo-owned static substrate: deterministic worker source templates,
artifact hashes, and pure build-command builders for the four accelerator lanes.
-}
module HostBootstrapDemo.Accelerator (
    AcceleratorBackend (..),
    WorkerKind (..),
    WorkerSpec (..),
    backendName,
    backendWorkerKind,
    workerSource,
    workerSpec,
    cppBuildArgs,
    cudaBuildArgs,
    swiftMetalBuildArgs,
    stableSourceHash,
)
where

import Data.Bits (xor)
import Data.Char (ord)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word64)
import Numeric (showHex)
import System.FilePath ((</>))

data AcceleratorBackend
    = AppleMetalBackend
    | LinuxCpuBackend
    | LinuxGpuBackend
    | WindowsGpuBackend
    deriving (Eq, Show)

data WorkerKind = SwiftMetalWorker | CppWorker | CudaWorker
    deriving (Eq, Show)

data WorkerSpec = WorkerSpec
    { workerBackend :: AcceleratorBackend
    , workerKind :: WorkerKind
    , workerSourcePath :: FilePath
    , workerExecutablePath :: FilePath
    , workerArtifactHash :: Text
    , workerSourceText :: Text
    }
    deriving (Eq, Show)

backendName :: AcceleratorBackend -> Text
backendName AppleMetalBackend = "apple-metal"
backendName LinuxCpuBackend = "linux-cpu"
backendName LinuxGpuBackend = "linux-gpu"
backendName WindowsGpuBackend = "windows-gpu"

backendWorkerKind :: AcceleratorBackend -> WorkerKind
backendWorkerKind AppleMetalBackend = SwiftMetalWorker
backendWorkerKind LinuxCpuBackend = CppWorker
backendWorkerKind LinuxGpuBackend = CudaWorker
backendWorkerKind WindowsGpuBackend = CudaWorker

workerSpec :: FilePath -> AcceleratorBackend -> WorkerSpec
workerSpec root backend =
    WorkerSpec
        { workerBackend = backend
        , workerKind = kind
        , workerSourcePath = sourcePath
        , workerExecutablePath = exePath
        , workerArtifactHash = stableSourceHash source
        , workerSourceText = source
        }
  where
    kind = backendWorkerKind backend
    source = workerSource backend
    dir = root </> T.unpack (backendName backend) </> T.unpack (stableSourceHash source)
    sourcePath = dir </> workerSourceFile kind
    exePath = dir </> "accelerator-worker"

workerSourceFile :: WorkerKind -> FilePath
workerSourceFile SwiftMetalWorker = "AddWorker.swift"
workerSourceFile CppWorker = "add_worker.cpp"
workerSourceFile CudaWorker = "add_worker.cu"

workerSource :: AcceleratorBackend -> Text
workerSource AppleMetalBackend = swiftMetalSource
workerSource LinuxCpuBackend = cppSource
workerSource LinuxGpuBackend = cudaSource
workerSource WindowsGpuBackend = cudaSource

cppBuildArgs :: FilePath -> FilePath -> [String]
cppBuildArgs sourcePath exePath = ["-O2", "-std=c++17", sourcePath, "-o", exePath]

cudaBuildArgs :: FilePath -> FilePath -> [String]
cudaBuildArgs sourcePath exePath = [sourcePath, "-o", exePath]

swiftMetalBuildArgs :: FilePath -> FilePath -> FilePath -> [String]
swiftMetalBuildArgs sdkPath sourcePath exePath =
    ["-O", "-sdk", sdkPath, sourcePath, "-o", exePath, "-framework", "Metal"]

stableSourceHash :: Text -> Text
stableSourceHash =
    T.pack . pad16 . (`showHex` "") . foldl' step offsetBasis . T.unpack
  where
    offsetBasis :: Word64
    offsetBasis = 14695981039346656037

    prime :: Word64
    prime = 1099511628211

    step :: Word64 -> Char -> Word64
    step h c = (h `xor` fromIntegral (ord c)) * prime

    pad16 s = replicate (max 0 (16 - length s)) '0' ++ s

cppSource :: Text
cppSource =
    T.unlines
        [ "#include <iomanip>"
        , "#include <iostream>"
        , ""
        , "int main() {"
        , "  float left = 0.0f;"
        , "  float right = 0.0f;"
        , "  while (std::cin >> left >> right) {"
        , "    std::cout << std::setprecision(9) << (left + right) << std::endl;"
        , "  }"
        , "  return std::cin.eof() ? 0 : 2;"
        , "}"
        ]

cudaSource :: Text
cudaSource =
    T.unlines
        [ "#include <cstdio>"
        , "#include <cstdlib>"
        , "#include <cuda_runtime.h>"
        , ""
        , "#define CUDA_CHECK(call) do { const cudaError_t status = (call); if (status != cudaSuccess) { std::fprintf(stderr, \"CUDA error: %s\\n\", cudaGetErrorString(status)); return 5; } } while (0)"
        , ""
        , "__global__ void hostbootstrap_add(const float* left, const float* right, float* out) {"
        , "  *out = *left + *right;"
        , "}"
        , ""
        , "int main() {"
        , "  float left = 0.0f;"
        , "  float right = 0.0f;"
        , "  float *dLeft = nullptr, *dRight = nullptr, *dOut = nullptr;"
        , "  float out = 0.0f;"
        , "  CUDA_CHECK(cudaMalloc(&dLeft, sizeof(float)));"
        , "  CUDA_CHECK(cudaMalloc(&dRight, sizeof(float)));"
        , "  CUDA_CHECK(cudaMalloc(&dOut, sizeof(float)));"
        , "  while (true) {"
        , "    const int scanned = std::scanf(\"%f %f\", &left, &right);"
        , "    if (scanned == EOF) {"
        , "      break;"
        , "    }"
        , "    if (scanned != 2) {"
        , "      return 2;"
        , "    }"
        , "    CUDA_CHECK(cudaMemcpy(dLeft, &left, sizeof(float), cudaMemcpyHostToDevice));"
        , "    CUDA_CHECK(cudaMemcpy(dRight, &right, sizeof(float), cudaMemcpyHostToDevice));"
        , "    hostbootstrap_add<<<1, 1>>>(dLeft, dRight, dOut);"
        , "    CUDA_CHECK(cudaGetLastError());"
        , "    CUDA_CHECK(cudaDeviceSynchronize());"
        , "    CUDA_CHECK(cudaMemcpy(&out, dOut, sizeof(float), cudaMemcpyDeviceToHost));"
        , "    std::printf(\"%.9g\\n\", out);"
        , "    std::fflush(stdout);"
        , "  }"
        , "  CUDA_CHECK(cudaFree(dLeft));"
        , "  CUDA_CHECK(cudaFree(dRight));"
        , "  CUDA_CHECK(cudaFree(dOut));"
        , "  return 0;"
        , "}"
        ]

swiftMetalSource :: Text
swiftMetalSource =
    T.unlines
        [ "import Foundation"
        , "import Metal"
        , ""
        , "// readLine() consumes newline-delimited requests from FileHandle.standardInput."
        , "guard let device = MTLCreateSystemDefaultDevice() else { exit(3) }"
        , "let source = \"\"\""
        , "#include <metal_stdlib>"
        , "using namespace metal;"
        , "kernel void add(device const float* left [[buffer(0)]], device const float* right [[buffer(1)]], device float* out [[buffer(2)]]) {"
        , "  out[0] = left[0] + right[0];"
        , "}"
        , "\"\"\""
        , "let library = try device.makeLibrary(source: source, options: nil)"
        , "let function = library.makeFunction(name: \"add\")!"
        , "let pipeline = try device.makeComputePipelineState(function: function)"
        , "let queue = device.makeCommandQueue()!"
        , "while let input = readLine() {"
        , "  let parts = input.split { $0 == \" \" || $0 == \"\\t\" }"
        , "  guard parts.count >= 2, let leftInput = Float(parts[0]), let rightInput = Float(parts[1]) else { exit(2) }"
        , "  var left = leftInput"
        , "  var right = rightInput"
        , "  var output = Float(0)"
        , "  let leftBuffer = device.makeBuffer(bytes: &left, length: MemoryLayout<Float>.size, options: [])!"
        , "  let rightBuffer = device.makeBuffer(bytes: &right, length: MemoryLayout<Float>.size, options: [])!"
        , "  let outputBuffer = device.makeBuffer(bytes: &output, length: MemoryLayout<Float>.size, options: [])!"
        , "  let commandBuffer = queue.makeCommandBuffer()!"
        , "  let encoder = commandBuffer.makeComputeCommandEncoder()!"
        , "  encoder.setComputePipelineState(pipeline)"
        , "  encoder.setBuffer(leftBuffer, offset: 0, index: 0)"
        , "  encoder.setBuffer(rightBuffer, offset: 0, index: 1)"
        , "  encoder.setBuffer(outputBuffer, offset: 0, index: 2)"
        , "  encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))"
        , "  encoder.endEncoding()"
        , "  commandBuffer.commit()"
        , "  commandBuffer.waitUntilCompleted()"
        , "  if commandBuffer.error != nil { exit(4) }"
        , "  let result = outputBuffer.contents().bindMemory(to: Float.self, capacity: 1).pointee"
        , "  let response = String(format: \"%.9g\\n\", result)"
        , "  FileHandle.standardOutput.write(response.data(using: .utf8)!)"
        , "}"
        ]
