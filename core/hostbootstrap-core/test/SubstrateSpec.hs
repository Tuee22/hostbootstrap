module SubstrateSpec (tests) where

import Data.Char (isSpace)
import Data.List (isPrefixOf)
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Effect (BoundedRun (..), CapturedRun (..))
import HostBootstrap.Substrate
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Read (readMaybe)

tests :: TestTree
tests =
    testGroup
        "SubstrateSpec"
        [ testGroup "parseDockerArch" archCases
        , testGroup "classify" classifyCases
        , testGroup "predicates" predicateCases
        , testGroup "NVIDIA evidence" nvidiaCases
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
    , testCase "every tag has exactly one frame and its derived predicates" $
        map
            (\name -> let s = Substrate name Arm64 in (substrateFrame s, isAppleSilicon s, isLinux s, isWindows s))
            [AppleSilicon, LinuxCpu, LinuxGpu, WindowsCpu, WindowsGpu]
            @?= [ (AppleFrame, True, False, False)
                , (LinuxFrame, False, True, False)
                , (LinuxFrame, False, True, False)
                , (WindowsFrame, False, False, True)
                , (WindowsFrame, False, False, True)
                ]
    ]

nvidiaCases :: [TestTree]
nvidiaCases =
    [ testCase "only Linux reads kernel markers" $
        map nvidiaMarkerPathsFor allHostFrames @?= [nvidiaMarkerPaths, [], []]
    , testCase "a Linux marker settles the answer without a listing" $ do
        nvidiaProbePlan LinuxFrame True @?= NvidiaPresent
        nvidiaProbeAnswer (nvidiaProbePlan LinuxFrame True) Nothing @?= True
    , testCase "Linux without a marker requires a successful device listing" $ do
        nvidiaProbePlan LinuxFrame False @?= NvidiaListing
        nvidiaProbeAnswer (nvidiaProbePlan LinuxFrame False) (Just listing) @?= True
    , testCase "Windows ignores a Linux marker and a missing tool is no GPU" $ do
        nvidiaProbePlan WindowsFrame True @?= NvidiaListing
        nvidiaProbeAnswer (nvidiaProbePlan WindowsFrame True) Nothing @?= False
    , testCase "macOS asks for neither marker nor listing" $ do
        nvidiaProbePlan AppleFrame True @?= NvidiaAbsent
        nvidiaProbeAnswer (nvidiaProbePlan AppleFrame True) (Just listing) @?= False
    , testCase "a timeout is no GPU" $
        nvidiaProbeAnswer NvidiaListing (Just BoundedTimedOut) @?= False
    , testCase "other unsuccessful outcomes are no GPU" $
        map (nvidiaProbeAnswer NvidiaListing . Just)
            [ BoundedOutputLimit
            , BoundedFailed "unavailable"
            , BoundedCompleted (CapturedRun (ExitFailure 1) "GPU 0" "")
            , BoundedCompleted (CapturedRun ExitSuccess "no devices" "")
            ]
            @?= replicate 4 False
    ]
  where
    listing = BoundedCompleted (CapturedRun ExitSuccess "GPU 0: NVIDIA" "")

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
    , testCase "an Apple amd64 statement has the same refusal as direct classification" $
        parseStatedHost (Just "apple-silicon") (Just "amd64")
            @?= Just (classify "darwin" "x86_64" False)
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
        assertBool "the Python definitions disagree with the receiving vocabulary" (seamDefinitionsAgree bootstrapper)
    , testCase "comments and docstrings cannot satisfy the seam agreement" $ do
        let definitions = unlines [name ++ " = " ++ show value | (name, value) <- seamDefinitions]
        seamDefinitionsAgree definitions @?= True
        seamDefinitionsAgree (unlines (map ("# " ++) (lines definitions))) @?= False
        seamDefinitionsAgree ("\"\"\"\n" ++ definitions ++ "\"\"\"\n") @?= False
        seamDefinitionsAgree ("'''\n" ++ definitions ++ "'''\n") @?= False
    ]

seamDefinitions :: [(String, String)]
seamDefinitions =
    [ ("SUBSTRATE_ENV_VAR: Final[str]", substrateEnvVar)
    , ("ARCH_ENV_VAR: Final[str]", archEnvVar)
    , ("APPLE_SILICON", renderSubstrateName AppleSilicon)
    , ("LINUX_CPU", renderSubstrateName LinuxCpu)
    , ("LINUX_GPU", renderSubstrateName LinuxGpu)
    , ("WINDOWS_CPU", renderSubstrateName WindowsCpu)
    , ("WINDOWS_GPU", renderSubstrateName WindowsGpu)
    , ("AMD64", renderArch Amd64)
    , ("ARM64", renderArch Arm64)
    ]

seamDefinitionsAgree :: String -> Bool
seamDefinitionsAgree source = all (`elem` assignments) seamDefinitions
  where
    assignments =
        [ (trim name, value)
        | line <- definitionLines Nothing (lines source)
        , let (name, rest) = break (== '=') line
        , '=' : rhs <- [rest]
        , Just value <- [readMaybe (trim (takeWhile (/= '#') rhs))]
        ]

-- This guard reads literal assignments, excluding comments and multiline
-- docstrings. It does not treat mentions elsewhere as definitions.
definitionLines :: Maybe String -> [String] -> [String]
definitionLines _ [] = []
definitionLines delimiter (line : rest) = case delimiter of
    Just marker -> definitionLines (if odd (occurrences marker line) then Nothing else delimiter) rest
    Nothing
        | "#" `isPrefixOf` trim line -> definitionLines Nothing rest
        | any (\marker -> occurrences marker line > 0) ["\"\"\"", "'''"] ->
            let open = [marker | marker <- ["\"\"\"", "'''"], odd (occurrences marker line)]
             in definitionLines (case open of marker : _ -> Just marker; [] -> Nothing) rest
        | otherwise -> line : definitionLines Nothing rest

occurrences :: String -> String -> Int
occurrences [] _ = 0
occurrences _ [] = 0
occurrences marker text
    | marker `isPrefixOf` text = 1 + occurrences marker (drop (length marker) text)
occurrences marker (_ : rest) = occurrences marker rest

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
