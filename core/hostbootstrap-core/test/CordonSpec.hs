{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module CordonSpec (tests, nativeCapacitySupported, windowsCapacitySupported) where

import ConditionalCase (conditionalCase)
import Data.Int (Int64)
import Data.List (isInfixOf, isPrefixOf, nub, sort)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import qualified Dhall
import HostBootstrap.Cluster.Cordon
import qualified HostBootstrap.Cluster.Cordon.Foundation as Foundation
import qualified HostBootstrap.Cluster.Cordon.WindowsCapacity as WindowsCapacity
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.Context (ResourceEnvelope (..))
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Dhall.Gen (autoCodecWitness, renderValue)
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig)
import HostBootstrap.HostTool (HostTool (Sysctl), mkAbsExe)
import HostBootstrap.Substrate (Arch (..), Substrate (..), SubstrateName (..), classify, detectHere)
import Numeric.Natural (Natural)
import qualified SourceGuard
import System.Directory (getCurrentDirectory)
import System.Environment (getExecutablePath)
import System.FilePath ((</>))
import qualified System.Info as Info
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

gib :: Integer
gib = 1024 ^ (3 :: Integer)

mib :: Integer
mib = 1024 ^ (2 :: Integer)

demoResources :: ResourceEnvelope
demoResources = ResourceEnvelope{cpu = 4, memory = "8GiB", storage = "20GiB"}

tests :: TestTree
tests =
    testGroup
        "CordonSpec"
        [ testGroup "parseQuantity" quantityCases
        , testGroup "budget" budgetCases
        , testGroup "verifyBudget" verifyCases
        , testGroup "host capacity source" capacitySourceCases
        , testGroup "native capacity" nativeCapacityCases
        , testGroup "Windows capacity" windowsCapacityCases
        , testGroup "fitsBudget" fitsCases
        , testGroup "sizing + applied cordon" sizingCases
        , testGroup "Docker limit bounds" dockerLimitCases
        , testGroup "lower foundation boundary" foundationCases
        ]

foundationCases :: [TestTree]
foundationCases =
    [ testCase "facade envelope adapters equal the canonical budget renderers" $ do
        canonical <- either (assertFailure . Foundation.renderQuantityError) pure (Foundation.mkResourceBudget 4 (8 * gib) (20 * gib))
        budgetFromResources demoResources @?= Right canonical
        budgetFromVocabResources (V.Resources 4 "8GiB" "20GiB") @?= Right canonical
        colimaSizingArgs "demo" demoResources
            @?= Foundation.colimaSizingArgsForBudget "demo" canonical
        limaSizingArgs demoResources
            @?= Foundation.limaSizingArgsForBudget canonical
        incusSizingArgs demoResources
            @?= Foundation.incusSizingArgsForBudget canonical
        wsl2SizingArgs demoResources
            @?= Foundation.wsl2SizingArgsForBudget canonical
        kindNodeCordonArgsFor "demo-control-plane" demoResources
            @?= Foundation.kindNodeCordonArgsForBudget "demo-control-plane" canonical
        kindNodeCordonArgs "demo" demoResources
            @?= Foundation.kindNodeCordonArgsForBudget "demo-control-plane" canonical
    , testCase "facade parsing preserves exact refusals and field order" $ do
        let malformedMemory = ResourceEnvelope 4 "wat" "also-wat"
            malformedStorage = ResourceEnvelope 4 "8GiB" "wat"
            malformedVocab = V.Resources 4 "wat" "also-wat"
            ampleCapacity = Foundation.HostCapacity 8 (16 * gib) (100 * gib)
        Foundation.parseQuantity "wat" @?= Left (Foundation.QuantityNotANumber "wat")
        budgetFromResources malformedMemory @?= Left (Foundation.QuantityNotANumber "wat")
        budgetFromVocabResources malformedVocab @?= Left (Foundation.QuantityNotANumber "wat")
        preflightBudget malformedMemory ampleCapacity @?= Left "not a quantity: wat"
        preflightHostBudget malformedMemory ampleCapacity @?= Left "not a quantity: wat"
        budgetFromResources malformedStorage @?= Left (Foundation.QuantityNotANumber "wat")
        budgetFromVocabResources (V.Resources 4 "8GiB" "wat")
            @?= Left (Foundation.QuantityNotANumber "wat")
        [ colimaSizingArgs "demo" malformedMemory
            , limaSizingArgs malformedMemory
            , incusSizingArgs malformedMemory
            , wsl2SizingArgs malformedMemory
            , kindNodeCordonArgs "demo" malformedMemory
            ]
            @?= replicate 5 (Left "not a quantity: wat")
        [ colimaSizingArgs "demo" malformedStorage
            , limaSizingArgs malformedStorage
            , incusSizingArgs malformedStorage
            , wsl2SizingArgs malformedStorage
            , kindNodeCordonArgs "demo" malformedStorage
            ]
            @?= replicate 5 (Left "not a quantity: wat")
    , testCase "unknown and inexact quantities retain exact descriptive refusals" $ do
        Foundation.parseQuantity "8Qi"
            @?= Left (Foundation.QuantityUnknownUnit "Qi" "8Qi")
        Foundation.parseQuantity "0.1B"
            @?= Left (Foundation.QuantityNotWholeBytes "0.1B")
        -- The sum renders the sentence these refusals carried before it existed,
        -- so a closed answer and a legible diagnostic are the same value.
        map
            Foundation.renderQuantityError
            [ Foundation.QuantityNotANumber "wat"
            , Foundation.QuantityUnknownUnit "Qi" "8Qi"
            , Foundation.QuantityNotWholeBytes "0.1B"
            , Foundation.QuantityMalformedNumber "1.2.3"
            , Foundation.DimensionNotPositive Foundation.BudgetCpu
            , Foundation.DimensionAboveBound Foundation.BudgetMemory
            ]
            @?= [ "not a quantity: wat"
                , "unknown unit: Qi in quantity: 8Qi"
                , "quantity is not an exact whole-byte value: 0.1B"
                , "not a number: 1.2.3"
                , "resource budget: cpu must be positive"
                , "resource budget: memory exceeds the supported bound"
                ]
    , testCase "a refusal names its dimension without matching on rendered text" $ do
        -- The whole point of the closed answer: a caller asks which dimension
        -- was refused and gets a value, not a sentence it has to parse.
        let dimensionOf = either dimension (const Nothing)
            dimension err = case err of
                Foundation.DimensionNotPositive d -> Just d
                Foundation.DimensionAboveBound d -> Just d
                _ -> Nothing
        dimensionOf (Foundation.mkResourceBudget 0 gib gib) @?= Just Foundation.BudgetCpu
        dimensionOf (Foundation.mkResourceBudget 4 0 gib) @?= Just Foundation.BudgetMemory
        dimensionOf (Foundation.mkResourceBudget 4 gib 0) @?= Just Foundation.BudgetStorage
        dimensionOf (budgetFromResources (ResourceEnvelope 4 "0" "20GiB"))
            @?= Just Foundation.BudgetMemory
    , testCase "whole-GiB renderer failures equal the lower canonical renderers" $ do
        inexactMemory <- either (assertFailure . Foundation.renderQuantityError) pure (Foundation.mkResourceBudget 4 (8 * gib + 1) (20 * gib))
        inexactStorage <- either (assertFailure . Foundation.renderQuantityError) pure (Foundation.mkResourceBudget 4 (8 * gib) (20 * gib + 1))
        let memoryResources = ResourceEnvelope 4 "8589934593" "20GiB"
            storageResources = ResourceEnvelope 4 "8GiB" "21474836481"
        colimaSizingArgs "demo" memoryResources
            @?= Foundation.colimaSizingArgsForBudget "demo" inexactMemory
        colimaSizingArgs "demo" memoryResources
            @?= Left "Colima memory must be exactly representable as whole GiB; got 8589934593 bytes"
        limaSizingArgs memoryResources
            @?= Foundation.limaSizingArgsForBudget inexactMemory
        limaSizingArgs memoryResources
            @?= Left "Lima memory must be exactly representable as whole GiB; got 8589934593 bytes"
        incusSizingArgs memoryResources
            @?= Foundation.incusSizingArgsForBudget inexactMemory
        incusSizingArgs memoryResources
            @?= Left "Incus memory must be exactly representable as whole GiB; got 8589934593 bytes"
        wsl2SizingArgs memoryResources
            @?= Foundation.wsl2SizingArgsForBudget inexactMemory
        wsl2SizingArgs memoryResources
            @?= Left "WSL2 memory must be exactly representable as whole GiB; got 8589934593 bytes"
        colimaSizingArgs "demo" storageResources
            @?= Foundation.colimaSizingArgsForBudget "demo" inexactStorage
        colimaSizingArgs "demo" storageResources
            @?= Left "Colima storage must be exactly representable as whole GiB; got 21474836481 bytes"
        limaSizingArgs storageResources
            @?= Foundation.limaSizingArgsForBudget inexactStorage
        limaSizingArgs storageResources
            @?= Left "Lima storage must be exactly representable as whole GiB; got 21474836481 bytes"
        incusSizingArgs storageResources
            @?= Foundation.incusSizingArgsForBudget inexactStorage
        incusSizingArgs storageResources
            @?= Left "Incus storage must be exactly representable as whole GiB; got 21474836481 bytes"
        wsl2SizingArgs storageResources
            @?= Foundation.wsl2SizingArgsForBudget inexactStorage
        wsl2SizingArgs storageResources
            @?= Left "WSL2 VHDX storage must be exactly representable as whole GiB; got 21474836481 bytes"
    , testCase "both preflight facades preserve lower failures exactly" $ do
        canonical <- either (assertFailure . Foundation.renderQuantityError) pure (Foundation.mkResourceBudget 4 (8 * gib) (20 * gib))
        let reserveFreeCapacity = Foundation.HostCapacity 2 (16 * gib) (100 * gib)
            metalCapacity = Foundation.HostCapacity 2 (10 * gib) (100 * gib)
            cpuError = Left "resource budget exceeds host capacity: cpu wants 4 cores, host has 2 cores"
            reserveError = Left "resource budget plus host reserve exceeds host memory: wants 8 GiB + 4 GiB host reserve, host has 10 GiB"
        preflightBudget demoResources reserveFreeCapacity @?= Foundation.verifyBudget canonical reserveFreeCapacity
        preflightBudget demoResources reserveFreeCapacity @?= cpuError
        preflightHostBudget demoResources metalCapacity @?= Foundation.verifyHostBudget canonical metalCapacity
        preflightHostBudget demoResources metalCapacity @?= reserveError
    , testCase "foundation verifies canonical budgets without a configuration envelope" $ do
        canonical <- either (assertFailure . Foundation.renderQuantityError) pure (Foundation.mkResourceBudget 4 (8 * gib) (20 * gib))
        Foundation.verifyBudget canonical (Foundation.HostCapacity 8 (16 * gib) (100 * gib)) @?= Right ()
        leftHas "reserve" (Foundation.verifyHostBudget canonical (Foundation.HostCapacity 8 (10 * gib) (100 * gib)))
    , testCase "foundation owns quantity parsing and the pure storage policy" $ do
        Foundation.parseQuantity "0.5Ki" @?= Right 512
        Foundation.storageCordonPolicy Foundation.BareLinuxStorage
            @?= Foundation.StorageCordonUnsupported Foundation.BareLinuxQuotaAndImageGcUnavailable
    , testCase "configuration facade imports only the lower foundation and descriptive vocabularies" $ do
        cwd <- getCurrentDirectory
        root <- findRepoRoot cwd >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
        let packageRoot = root </> "core" </> "hostbootstrap-core"
        facadeSource <- TextIO.readFile (packageRoot </> "src" </> "HostBootstrap" </> "Cluster" </> "Cordon.hs")
        sort (nub (hostbootstrapImports facadeSource))
            @?= sort
                [ "HostBootstrap.Cluster.Cordon.Foundation"
                , "HostBootstrap.Config.Vocab"
                , "HostBootstrap.Context"
                ]
    , testCase "foundation imports only modules below the canonical-quantities boundary and is exposed" $ do
        cwd <- getCurrentDirectory
        root <- findRepoRoot cwd >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
        let packageRoot = root </> "core" </> "hostbootstrap-core"
        source <- TextIO.readFile (packageRoot </> "src" </> "HostBootstrap" </> "Cluster" </> "Cordon" </> "Foundation.hs")
        cabal <- TextIO.readFile (packageRoot </> "hostbootstrap-core.cabal")
        let importedModules = sort (hostbootstrapImports source)
        importedModules
            @?= sort
                [ "HostBootstrap.Cluster.Cordon.WindowsCapacity"
                , "HostBootstrap.Effect.Interpreter"
                , "HostBootstrap.Effect.Run"
                , "HostBootstrap.Effect.Vocabulary"
                , "HostBootstrap.HostConfig"
                , "HostBootstrap.HostTool"
                , "HostBootstrap.Substrate"
                ]
        exposedModules <- either assertFailure pure (mainLibraryExposedModules cabal)
        assertBool
            "Cordon.Foundation must be exposed by the unnamed main library"
            ("HostBootstrap.Cluster.Cordon.Foundation" `elem` exposedModules)
    , testCase "capacity observation uses described commands without interpreter text" $
        -- DEVELOPMENT_PLAN/rationale.md: "A script is a fork of the binary, and it is the fork nothing can check".
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            source <- readFile (packageRoot </> "src" </> "HostBootstrap" </> "Cluster" </> "Cordon" </> "Foundation.hs")
            assertBool "Foundation still invokes a PowerShell command" $
                all ((`notElem` SourceGuard.haskellTokens source) . show) (["-Command", "-NoProfile"] :: [String])
            SourceGuard.countHaskellIdentifier "PowerShell" source @?= 0
            SourceGuard.countHaskellIdentifier "runCaptured" source @?= 0
    , testCase "foundation import scanner covers every supported import decoration" $ do
        let sample =
                Text.unlines
                    [ "-- import HostBootstrap.Commented"
                    , "import HostBootstrap.Plain"
                    , "import qualified HostBootstrap.Qualified as Qualified"
                    , "import safe HostBootstrap.Safe"
                    , "import {-# SOURCE #-} HostBootstrap.Source"
                    , "import \"hostbootstrap-core\" HostBootstrap.PackageQualified"
                    , "import"
                    , "  safe"
                    , "  qualified"
                    , "  HostBootstrap.Multiline"
                    , "literal = \"import HostBootstrap.StringLiteral\""
                    ]
        sort (hostbootstrapImports sample)
            @?= sort
                [ "HostBootstrap.Multiline"
                , "HostBootstrap.PackageQualified"
                , "HostBootstrap.Plain"
                , "HostBootstrap.Qualified"
                , "HostBootstrap.Safe"
                , "HostBootstrap.Source"
                ]
    , testCase "cabal parser scopes exposure to the unnamed main library" $ do
        let sample =
                Text.unlines
                    [ "library helper"
                    , "  exposed-modules:"
                    , "      HostBootstrap.NotMain"
                    , "library"
                    , "  ExPoSeD-MoDuLeS: HostBootstrap.PublicInline,HostBootstrap.PublicSecond,"
                    , "      HostBootstrap.PublicContinuation"
                    , "  -- exposed-modules: HostBootstrap.Commented"
                    , "  other-modules:"
                    , "      HostBootstrap.NotExposed"
                    , "test-suite tests"
                    , "  main-is: Spec.hs"
                    ]
        mainLibraryExposedModules sample
            @?= Right ["HostBootstrap.PublicInline", "HostBootstrap.PublicSecond", "HostBootstrap.PublicContinuation"]
    , testCase "cabal exposure reader names a missing main library" $
        mainLibraryExposedModules "library helper\n  exposed-modules: HostBootstrap.Helper\n"
            @?= Left "hostbootstrap-core.cabal: unnamed main library stanza is missing"
    , testCase "cabal exposure reader names an absent exposure field" $
        mainLibraryExposedModules "library\n  other-modules: HostBootstrap.Hidden\n"
            @?= Left "hostbootstrap-core.cabal: main library exposed-modules field is missing"
    ]

hostbootstrapImports :: Text.Text -> [Text.Text]
hostbootstrapImports =
    filter ("HostBootstrap." `Text.isPrefixOf`)
        . map Text.pack
        . SourceGuard.haskellImports
        . Text.unpack

{- | The modules the unnamed main library exposes, or why they could not be read.

Reads through the shared toolkit, so this guard and every other guard over the
same field enumerate the same modules.
-}
mainLibraryExposedModules :: Text.Text -> Either String [Text.Text]
mainLibraryExposedModules cabal =
    case SourceGuard.mainLibraryStanza (Text.unpack cabal) of
        Nothing -> Left "hostbootstrap-core.cabal: unnamed main library stanza is missing"
        Just stanza ->
            case SourceGuard.fieldModules "exposed-modules:" stanza of
                [] -> Left "hostbootstrap-core.cabal: main library exposed-modules field is missing"
                modules -> Right (map Text.pack modules)

quantityCases :: [TestTree]
quantityCases =
    [ testCase "8Gi binary" (parseQuantity "8Gi" @?= Right (8 * gib))
    , testCase "8GiB binary (B suffix)" (parseQuantity "8GiB" @?= Right (8 * gib))
    , testCase "512Mi binary" (parseQuantity "512Mi" @?= Right (512 * mib))
    , testCase "1G decimal" (parseQuantity "1G" @?= Right 1000000000)
    , testCase "an exact fractional binary quantity is accepted" (parseQuantity "0.5Ki" @?= Right 512)
    , testCase "a fractional quantity that is not a whole byte is rejected" (isLeft (parseQuantity "0.1B") @?= True)
    , testCase "bare number is bytes" (parseQuantity "1024" @?= Right 1024)
    , testCase "whitespace tolerated" (parseQuantity "  4Gi " @?= Right (4 * gib))
    , testCase "unknown unit rejected" (isLeft (parseQuantity "8Qi") @?= True)
    , testCase "empty rejected" (isLeft (parseQuantity "") @?= True)
    ]

budgetCases :: [TestTree]
budgetCases =
    [ testCase "resources -> canonical byte budget" $
        fmap
            (\budget -> (budgetCpu budget, budgetMemoryBytes budget, budgetStorageBytes budget))
            (budgetFromResources demoResources)
            @?= Right (4, 8 * gib, 20 * gib)
    , testCase "gibibytes rounds up" $
        map gibibytes [gib, gib + 1, 8 * gib] @?= [1, 2, 8]
    , testCase "public budget construction rejects non-positive dimensions" $ do
        isLeft (mkResourceBudget 0 gib gib) @?= True
        isLeft (mkResourceBudget 1 0 gib) @?= True
        isLeft (mkResourceBudget 1 gib 0) @?= True
    , testCase "public budget construction refuses CPU above its supported bound" $
        mkResourceBudget (fromIntegral (maxBound :: Int) + 1) gib gib
            @?= Left (DimensionAboveBound BudgetCpu)
    , testCase "public budget construction refuses memory above its supported bound" $
        mkResourceBudget 1 (toInteger (maxBound :: Int64) + 1) gib
            @?= Left (DimensionAboveBound BudgetMemory)
    , testCase "public budget construction refuses storage above its supported bound" $
        mkResourceBudget 1 gib (toInteger (maxBound :: Int64) + 1)
            @?= Left (DimensionAboveBound BudgetStorage)
    , testCase "the resource envelope refuses an above-bound memory quantity" $
        budgetFromResources (ResourceEnvelope 1 "9000000Ti" "1Gi")
            @?= Left (DimensionAboveBound BudgetMemory)
    , testCase "opaque budget readers and Show retain the public record rendering" $ do
        budget <- either (assertFailure . renderQuantityError) pure (mkResourceBudget 4 8 20)
        let rendered = "ResourceBudget {budgetCpu = 4, budgetMemoryBytes = 8, budgetStorageBytes = 20}"
        (budgetCpu budget, budgetMemoryBytes budget, budgetStorageBytes budget) @?= (4, 8, 20)
        show budget @?= rendered
        showsPrec 10 budget "" @?= rendered
        showsPrec 11 budget "" @?= "(" <> rendered <> ")"
        show (Just budget) @?= "Just (" <> rendered <> ")"
    ]

verifyCases :: [TestTree]
verifyCases =
    [ testCase "within capacity passes (reserve-free — the in-VM slice check)" $
        verifyBudget budget (HostCapacity 8 (16 * gib) (100 * gib)) @?= Right ()
    , testCase "cpu over capacity fails naming cpu" $
        leftHas "cpu" (verifyBudget budget (HostCapacity 2 (16 * gib) (100 * gib)))
    , testCase "memory over capacity fails naming memory" $
        leftHas "memory" (verifyBudget budget (HostCapacity 8 (4 * gib) (100 * gib)))
    , testCase "storage over capacity fails naming storage" $
        leftHas "storage" (verifyBudget budget (HostCapacity 8 (16 * gib) (10 * gib)))
    , testCase "verifyBudget does NOT apply the host reserve (the in-VM slice fits available memory)" $
        -- an 8 GiB slice against 9 GiB available memory passes reserve-free: the real
        -- run's bug was re-reserving here (6 GiB slice + 4 GiB > 9 GiB avail) — the
        -- reserve belongs only to the metal preflight (verifyHostBudget).
        verifyBudget budget (HostCapacity 8 (9 * gib) (100 * gib)) @?= Right ()
    , testCase "verifyHostBudget (metal) DOES reserve: fits total but not total-minus-reserve → fails" $
        -- 8 GiB budget + 4 GiB host reserve = 12 GiB > 10 GiB total: a tight metal host
        -- is refused rather than silently over-committed.
        leftHas "reserve" (verifyHostBudget budget (HostCapacity 8 (10 * gib) (100 * gib)))
    , testCase "verifyHostBudget names host memory + the reserve" $
        leftHas "memory" (verifyHostBudget budget (HostCapacity 8 (10 * gib) (100 * gib)))
    , testCase "verifyHostBudget passes when the reserve fits" $
        verifyHostBudget budget (HostCapacity 8 (16 * gib) (100 * gib)) @?= Right ()
    ]
  where
    budget = either (error . show) id (mkResourceBudget 4 (8 * gib) (20 * gib))

capacitySourceCases :: [TestTree]
capacitySourceCases =
    [ testCase "apple-silicon reads CPU/memory from sysctl and free disk from df" $
        capacityReadPlan (Substrate AppleSilicon Arm64)
            @?= CapacityReadPlan (CpuSysctlKey "hw.ncpu") (MemorySysctlKey "hw.memsize") (PosixFreeStorage "/")
    , testCase "linux-cpu reads CPU/memory from procfs and free disk from df" $
        capacityReadPlan (Substrate LinuxCpu Amd64)
            @?= CapacityReadPlan ProcCpuinfo ProcMemAvailable (PosixFreeStorage "/")
    , testCase "linux-gpu reads CPU/memory from procfs and free disk from df" $
        capacityReadPlan (Substrate LinuxGpu Amd64)
            @?= CapacityReadPlan ProcCpuinfo ProcMemAvailable (PosixFreeStorage "/")
    , testCase "windows substrates select native CPU, memory, and system-volume sources" $ do
        capacityReadPlan (Substrate WindowsCpu Amd64)
            @?= CapacityReadPlan WindowsLogicalProcessors WindowsTotalMemory WindowsSystemDriveFreeSpace
        capacityReadPlan (Substrate WindowsGpu Amd64)
            @?= CapacityReadPlan WindowsLogicalProcessors WindowsTotalMemory WindowsSystemDriveFreeSpace
    , testCase "df -k output parses to the available-1K-blocks field" $ do
        parseDfAvailableKBytes "Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/disk1s1 500000000 100000000 400000000 20% /\n"
            @?= Just 400000000
        parseDfAvailableKBytes "" @?= Nothing
    , testCase "pure capacity preflight refuses a storage shortage" $
        leftHas "storage" $
            preflightBudget
                (ResourceEnvelope{cpu = 6, memory = "10GiB", storage = "80GiB"})
                (HostCapacity 16 (20 * gib) (40 * gib))
    , testCase "apple sysctl core count can satisfy a matching N-core budget" $
        preflightBudget
            (ResourceEnvelope{cpu = 10, memory = "8GiB", storage = "20GiB"})
            (HostCapacity 10 (16 * gib) petabyte)
            @?= Right ()
    , testCase "cpuinfo counts both logical processor entries" $
        Foundation.parseCpuinfoProcessors "processor\t: 0\nmodel name\t: fixture\nprocessor\t: 1\n"
            @?= Right 2
    , testCase "cpuinfo without processors returns its exact refusal" $
        Foundation.parseCpuinfoProcessors "model name\t: fixture\n"
            @?= Left "host capacity: no processors found in /proc/cpuinfo"
    , testCase "MemAvailable converts kernel kilobytes to bytes" $
        Foundation.parseMemAvailableBytes "MemTotal: 4096 kB\nMemAvailable: 1024 kB\n"
            @?= Right 1048576
    , testCase "missing MemAvailable returns its exact refusal" $
        Foundation.parseMemAvailableBytes "MemTotal: 4096 kB\n"
            @?= Left "host capacity: MemAvailable not found in /proc/meminfo"
    , testCase "malformed MemAvailable returns its exact refusal" $
        Foundation.parseMemAvailableBytes "MemAvailable: invalid kB\n"
            @?= Left "host capacity: MemAvailable not found in /proc/meminfo"
    , testCase "positive integer capacity strips CRLF before parsing" $
        Foundation.parsePositiveInteger "fixture" "16\r\n" @?= Right 16
    , testCase "zero integer capacity returns its exact refusal" $
        Foundation.parsePositiveInteger "fixture" "0"
            @?= Left "host capacity: fixture returned non-positive value 0"
    , testCase "non-integer capacity returns its exact refusal" $
        Foundation.parsePositiveInteger "fixture" "abc"
            @?= Left "host capacity: fixture returned non-integer value \"abc\""
    , testCase "native Windows capacity errors preserve their exact diagnostics" $ do
        WindowsCapacity.renderWindowsCapacityError WindowsCapacity.WindowsCapacityUnsupported
            @?= "native Windows capacity is unavailable on this host"
        WindowsCapacity.renderWindowsCapacityError (WindowsCapacity.WindowsCapacityApiFailure "GlobalMemoryStatusEx" "denied")
            @?= "GlobalMemoryStatusEx: denied"
        WindowsCapacity.renderWindowsCapacityError (WindowsCapacity.WindowsCapacityNonPositive "GetSystemInfo" 0)
            @?= "GetSystemInfo returned a non-positive capacity: 0"
    , testCase "an unresolved sysctl refuses before host capacity is available" $ do
        result <- resolveHostCapacity (HostConfig (Substrate AppleSilicon Arm64) Map.empty)
        result @?= Left "host capacity: sysctl is not resolved for apple-silicon"
    , testCase "an unresolved df refuses after the described sysctl reads" $ do
        executable <- getExecutablePath >>= either assertFailure pure . mkAbsExe
        let configuration = HostConfig (Substrate AppleSilicon Arm64) (Map.singleton Sysctl executable)
        result <- resolveHostCapacity configuration
        result @?= Left "host capacity: df is not resolved for apple-silicon"
    ]
  where
    petabyte = 1024 ^ (5 :: Integer)

-- The manifest imports these test-only declarations, so its branch count
-- follows the same platform decision as the actual callbacks.
nativeCapacitySupported :: Bool
nativeCapacitySupported = case classify Info.os Info.arch False of
    Right _ -> True
    Left _ -> False

windowsCapacitySupported :: Bool
windowsCapacitySupported = Info.os == "mingw32"

nativeCapacityCases :: [TestTree]
nativeCapacityCases =
    [ conditionalCase ["CordonSpec", "native capacity"] nativeCapacitySupported
        "the native host reports positive CPU, memory, and storage"
        (do
            substrate <- detectHere >>= either (assertFailure . ("supported native detection failed: " <>)) pure
            configuration <- buildHostConfig substrate
            capacity <- resolveHostCapacity configuration >>= either (assertFailure . ("supported native capacity failed: " <>)) pure
            assertPositiveCapacity capacity
        )
        (case classify Info.os Info.arch False of
            Left refusal -> detectHere >>= (@?= Left refusal)
            Right substrate -> assertFailure ("the supported host selected its refusal branch: " <> show substrate)
        )
    ]

windowsCapacityCases :: [TestTree]
windowsCapacityCases =
    [ kernelCase "native logical processor count" WindowsCapacity.readWindowsLogicalProcessors
    , kernelCase "native total physical memory" WindowsCapacity.readWindowsTotalMemory
    , kernelCase "native system-volume available bytes" WindowsCapacity.readWindowsSystemDriveFreeSpace
    , conditionalCase family windowsCapacitySupported
        "Windows capacity does not need any resolved PowerShell tool"
        (resolveHostCapacity noTools >>= either (assertFailure . ("native Windows capacity failed: " <>)) assertPositiveCapacity)
        (resolveHostCapacity noTools >>= (@?= Left (WindowsCapacity.renderWindowsCapacityError WindowsCapacity.WindowsCapacityUnsupported)))
    ]
  where
    family = ["CordonSpec", "Windows capacity"]
    noTools = HostConfig (Substrate WindowsCpu Amd64) Map.empty
    kernelCase label readCapacity = conditionalCase family windowsCapacitySupported label
        (readCapacity >>= either (\failure -> assertFailure (label <> ": " <> show failure)) (\value -> assertBool (label <> " must be positive") (value > 0)))
        (readCapacity >>= (@?= Left WindowsCapacity.WindowsCapacityUnsupported))

assertPositiveCapacity :: HostCapacity -> IO ()
assertPositiveCapacity capacity =
    assertBool ("expected positive CPU, memory, and storage, got " <> show capacity) $
        totalCpu capacity > 0 && totalMemoryBytes capacity > 0 && totalStorageBytes capacity > 0

fitsCases :: [TestTree]
fitsCases =
    [ testCase "a fitting pod set is accepted" $
        assertFitsBudgetParity (V.Budget 4 8 20) [V.PodResources 2 1 1 1 2] (Right ())
    , testCase "an over-cpu pod set is rejected naming cpu" $
        assertFitsBudgetParity (V.Budget 2 8 20) [V.PodResources 3 1 2 1 1] (Left (Overflow "cpu" 6 2))
    , testCase "an over-memory pod set is rejected naming memory" $
        assertFitsBudgetParity (V.Budget 8 4 20) [V.PodResources 3 1 1 1 4] (Left (Overflow "memory" 12 4))
    , testCase "a CPU request above its own limit is rejected naming cpuRequest" $
        assertFitsBudgetParity (V.Budget 4 8 20) [V.PodResources 1 4 1 1 1] (Left (Overflow "cpuRequest" 4 1))
    , testCase "a memory request above its own limit is rejected naming memoryRequest" $
        assertFitsBudgetParity (V.Budget 4 8 20) [V.PodResources 1 1 1 4 1] (Left (Overflow "memoryRequest" 4 1))
    , testCase "zero replicas do not admit a CPU request above its own limit" $
        assertFitsBudgetParity (V.Budget 4 8 20) [V.PodResources 0 4 1 1 1] (Left (Overflow "cpuRequest" 4 1))
    , testCase "zero replicas do not admit a memory request above its own limit" $
        assertFitsBudgetParity (V.Budget 4 8 20) [V.PodResources 0 1 1 4 1] (Left (Overflow "memoryRequest" 4 1))
    , testCase "preflightBudget passes within spare capacity" $
        preflightBudget demoResources (HostCapacity 8 (16 * gib) (100 * gib)) @?= Right ()
    , testCase "preflightBudget fails fast when short" $
        leftHas "cpu" (preflightBudget demoResources (HostCapacity 2 (16 * gib) (100 * gib)))
    ]

assertFitsBudgetParity :: V.Budget -> [V.PodResources] -> Either Overflow () -> IO ()
assertFitsBudgetParity budget pods expected = do
    fitsBudget budget pods @?= expected
    SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
        cwd <- getCurrentDirectory
        let relative = SourceGuard.repoRelativePath cwd (packageRoot </> "dhall" </> "Core.dhall")
            coreImport = if "." `Text.isPrefixOf` Text.pack relative then relative else "./" <> relative
        budgetCodec <- either (assertFailure . show) pure (autoCodecWitness @V.Budget)
        podsCodec <- either (assertFailure . show) pure (autoCodecWitness @[V.PodResources])
        observed <-
            Dhall.input Dhall.bool $
                "let C = " <> Text.pack coreImport
                    <> " in C.fitsWithin (" <> renderValue budgetCodec budget
                    <> ") (" <> renderValue podsCodec pods <> ")"
        observed @?= either (const False) (const True) expected

sizingCases :: [TestTree]
sizingCases =
    [ testCase "colima sizing splits one 40 GiB ceiling across fixed root and data disks" $
        colimaSizingArgs "demo" (ResourceEnvelope{cpu = 4, memory = "8GiB", storage = "40GiB"})
            @?= Right
                [ "start"
                , "--profile"
                , "demo"
                , "--runtime"
                , "docker"
                , "--activate=false"
                , "--template=false"
                , "--ssh-config=false"
                , "--mount"
                , "none"
                , "--kubernetes=false"
                , "--network-address=false"
                , "--mount-inotify=false"
                , "--cpus"
                , "4"
                , "--memory"
                , "8"
                , "--root-disk"
                , "20"
                , "--disk"
                , "20"
                ]
    , testCase "colima sizing rejects totals that cannot exceed the fixed writable root disk" $ do
        colimaSizingArgs "demo" (ResourceEnvelope{cpu = 4, memory = "8GiB", storage = "20GiB"})
            @?= Left "Colima storage must exceed the fixed 20 GiB writable root disk; got 20 GiB"
        colimaSizingArgs "demo" (ResourceEnvelope{cpu = 4, memory = "8GiB", storage = "19GiB"})
            @?= Left "Colima storage must exceed the fixed 20 GiB writable root disk; got 19 GiB"
    , testCase "colima sizing rejects an inexact total before splitting the disks" $
        colimaSizingArgs "demo" (ResourceEnvelope{cpu = 4, memory = "8GiB", storage = "42949672961"})
            @?= Left "Colima storage must be exactly representable as whole GiB; got 42949672961 bytes"
    , testCase "colima sizing closes ambient templates, host config, mounts, and network helpers" $ do
        args <-
            either
                assertFailure
                pure
                (colimaSizingArgs "demo" (ResourceEnvelope{cpu = 4, memory = "8GiB", storage = "40GiB"}))
        mapM_
            (\flag -> assertBool ("missing safe Colima flag: " ++ flag) (flag `elem` args))
            [ "--activate=false"
            , "--template=false"
            , "--ssh-config=false"
            , "--kubernetes=false"
            , "--network-address=false"
            , "--mount-inotify=false"
            ]
        assertBool "Colima home mounts must be disabled" (["--mount", "none"] `isInfixOf` args)
    , testCase "provider storage policy names each represented wall" $ do
        storageCordonPolicy ColimaVmStorage @?= StorageCordonSupported ColimaDiskFlag
        storageCordonPolicy LimaVmStorage @?= StorageCordonSupported LimaDiskFlag
        storageCordonPolicy IncusVmStorage @?= StorageCordonSupported IncusRootDiskLimit
        storageCordonPolicy Wsl2DistroStorage @?= StorageCordonSupported Wsl2VhdSize
    , testCase "bare Linux storage policy is explicitly unsupported" $
        storageCordonPolicy BareLinuxStorage
            @?= StorageCordonUnsupported BareLinuxQuotaAndImageGcUnavailable
    , testCase "Docker node storage policy is explicitly unsupported" $
        storageCordonPolicy DockerNodeStorage
            @?= StorageCordonUnsupported DockerUpdateStorageUnavailable
    , testCase "colima handles the bare 8Gi form" $
        colimaSizingArgs "demo" (ResourceEnvelope{cpu = 2, memory = "8Gi", storage = "40Gi"})
            @?= Right
                [ "start"
                , "--profile"
                , "demo"
                , "--runtime"
                , "docker"
                , "--activate=false"
                , "--template=false"
                , "--ssh-config=false"
                , "--mount"
                , "none"
                , "--kubernetes=false"
                , "--network-address=false"
                , "--mount-inotify=false"
                , "--cpus"
                , "2"
                , "--memory"
                , "8"
                , "--root-disk"
                , "20"
                , "--disk"
                , "20"
                ]
    , testCase "lima sizing emits VM resource flags" $
        limaSizingArgs demoResources
            @?= Right ["--cpus", "4", "--memory", "8", "--disk", "20"]
    , testCase "whole-GiB providers reject an inexact hard ceiling instead of rounding" $ do
        let inexact = ResourceEnvelope{cpu = 4, memory = "8589934593", storage = "20GiB"}
        isLeft (colimaSizingArgs "demo" inexact) @?= True
        isLeft (limaSizingArgs inexact) @?= True
        isLeft (incusSizingArgs inexact) @?= True
        isLeft (wsl2SizingArgs inexact) @?= True
    , testCase "wsl2 sizing emits the .wslconfig [general]+[wsl2] ceiling with swap + both idle timeouts (no vhdx-size key)" $
        wsl2SizingArgs demoResources
            @?= Right ["[general]", "instanceIdleTimeout=21600000", "[wsl2]", "processors=4", "memory=8GB", "swap=8GB", "vmIdleTimeout=21600000"]
    , testCase "both managed idle timeouts render a finite value" $ do
        -- The wall was previously pinned open with -1, which is why `project down`
        -- could leave the whole budget committed until the next reboot. A finite
        -- duration is the property that matters; the exact value is asserted above.
        body <- either assertFailure pure (wsl2SizingArgs demoResources)
        let timeouts = filter (\l -> "instanceIdleTimeout=" `isPrefixOf` l || "vmIdleTimeout=" `isPrefixOf` l) body
        length timeouts @?= 2
        all (\l -> not ("=-" `isInfixOf` l)) timeouts @?= True
    , testCase "applied Linux cordon caps the control-plane with 2x swap headroom" $
        kindNodeCordonArgs "demo-test-case1" demoResources
            @?= Right
                [ "update"
                , "--cpus"
                , "4"
                , "--memory"
                , show (8 * gib)
                , "--memory-swap"
                , show (2 * 8 * gib)
                , "demo-test-case1-control-plane"
                ]
    , testCase "the docker update cordon argv omits storage (no docker flag)" $
        assertBool "no storage in docker update argv" $
            case kindNodeCordonArgs "demo" demoResources of
                Right args -> show (20 * gib) `notElem` args
                Left _ -> False
    ]

dockerLimitCases :: [TestTree]
dockerLimitCases =
    [ dockerLimitCase "ordinary limits retain exact CPU, memory, and swap argv" 4 8589934592 $
        Right ["--cpus", "4", "--memory", "8589934592", "--memory-swap", "17179869184"]
    , dockerLimitCase "the largest whole NanoCPUs budget is accepted" 9223372036 6291456 $
        Right ["--cpus", "9223372036", "--memory", "6291456", "--memory-swap", "12582912"]
    , dockerLimitCase "one core above the NanoCPUs bound is refused" 9223372037 6291456 $
        Left "Docker CPU budget 9223372037 cores exceeds the signed 64-bit NanoCPUs limit of 9223372036 whole cores"
    , dockerLimitCase "the Linux daemon minimum memory is accepted" 4 6291456 $
        Right ["--cpus", "4", "--memory", "6291456", "--memory-swap", "12582912"]
    , dockerLimitCase "one byte below the Linux daemon minimum is refused" 4 6291455 $
        Left "Docker memory budget 6291455 bytes is below the Linux daemon minimum of 6291456 bytes"
    , dockerLimitCase "the largest CLI-exact memory below the signed swap bound is accepted" 4 4611686018427387392 $
        Right ["--cpus", "4", "--memory", "4611686018427387392", "--memory-swap", "9223372036854774784"]
    , dockerLimitCase "the raw half-Int64 memory bound loses CLI precision" 4 4611686018427387903 $
        Left "Docker memory budget 4611686018427387903 bytes is not exactly representable by the Docker CLI binary64 byte parser"
    , dockerLimitCase "one byte above the half-Int64 memory bound overflows signed swap" 4 4611686018427387904 $
        Left "Docker memory budget 4611686018427387904 bytes doubles to 9223372036854775808 bytes, exceeding the signed 64-bit --memory-swap limit of 9223372036854775807 bytes"
    , dockerLimitCase "two-to-the-53 plus one loses CLI precision" 4 9007199254740993 $
        Left "Docker memory budget 9007199254740993 bytes is not exactly representable by the Docker CLI binary64 byte parser"
    , dockerLimitCase "two-to-the-53 plus two remains exactly representable" 4 9007199254740994 $
        Right ["--cpus", "4", "--memory", "9007199254740994", "--memory-swap", "18014398509481988"]
    ]

dockerLimitCase :: String -> Natural -> Integer -> Either String [String] -> TestTree
dockerLimitCase label cores memoryBytes expected =
    testCase label $ do
        let resources = ResourceEnvelope cores (Text.pack (show memoryBytes)) "20GiB"
            expectedNamed = fmap (\limits -> ["update"] <> limits <> ["bounds-control-plane"]) expected
        canonical <- either (assertFailure . renderQuantityError) pure (budgetFromResources resources)
        Foundation.kindNodeCordonLimitsForBudget canonical @?= expected
        kindNodeCordonLimits canonical @?= expected
        Foundation.kindNodeCordonArgsForBudget "bounds-control-plane" canonical @?= expectedNamed
        kindNodeCordonArgsFor "bounds-control-plane" resources @?= expectedNamed
        kindNodeCordonArgs "bounds" resources @?= expectedNamed

leftHas :: String -> Either String a -> IO ()
leftHas needle e = case e of
    Left msg -> assertBool ("expected '" ++ needle ++ "' in: " ++ msg) (needle `isInfixOf` msg)
    Right _ -> assertBool ("expected Left mentioning " ++ needle) False

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
