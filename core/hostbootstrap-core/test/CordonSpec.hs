{-# LANGUAGE OverloadedStrings #-}

module CordonSpec (tests) where

import Data.Char (isAlphaNum, isSpace, isUpper)
import Data.List (isInfixOf, isPrefixOf, nub, sort)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import HostBootstrap.Cluster.Cordon
import qualified HostBootstrap.Cluster.Cordon.Foundation as Foundation
import HostBootstrap.Context (ResourceEnvelope (..))
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (Df, Sysctl), mkAbsExe)
import HostBootstrap.Substrate (Arch (..), Substrate (..), SubstrateName (..))
import System.Directory (findExecutable, getCurrentDirectory)
import System.FilePath ((</>))
import qualified System.Info as Info
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

gib :: Integer
gib = 1024 ^ (3 :: Integer)

mib :: Integer
mib = 1024 ^ (2 :: Integer)

demoResources :: ResourceEnvelope
demoResources = ResourceEnvelope {cpu = 4, memory = "8GiB", storage = "20GiB"}

tests :: TestTree
tests =
  testGroup
    "CordonSpec"
    [ testGroup "parseQuantity" quantityCases,
      testGroup "budget" budgetCases,
      testGroup "verifyBudget" verifyCases,
      testGroup "host capacity source" capacitySourceCases,
      testGroup "fitsBudget" fitsCases,
      testGroup "sizing + applied cordon" sizingCases,
      testGroup "lower foundation boundary" foundationCases
    ]

foundationCases :: [TestTree]
foundationCases =
  [ testCase "facade envelope adapters equal the canonical budget renderers" $ do
      canonical <- either assertFailure pure (Foundation.mkResourceBudget 4 (8 * gib) (20 * gib))
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
        @?= Foundation.kindNodeCordonArgsForBudget "demo-control-plane" canonical,
    testCase "facade parsing preserves exact refusals and field order" $ do
      let malformedMemory = ResourceEnvelope 4 "wat" "also-wat"
          malformedStorage = ResourceEnvelope 4 "8GiB" "wat"
          malformedVocab = V.Resources 4 "wat" "also-wat"
          ampleCapacity = Foundation.HostCapacity 8 (16 * gib) (100 * gib)
      Foundation.parseQuantity "wat" @?= Left "not a quantity: wat"
      budgetFromResources malformedMemory @?= Left "not a quantity: wat"
      budgetFromVocabResources malformedVocab @?= Left "not a quantity: wat"
      preflightBudget malformedMemory ampleCapacity @?= Left "not a quantity: wat"
      preflightHostBudget malformedMemory ampleCapacity @?= Left "not a quantity: wat"
      budgetFromResources malformedStorage @?= Left "not a quantity: wat"
      budgetFromVocabResources (V.Resources 4 "8GiB" "wat") @?= Left "not a quantity: wat"
      [ colimaSizingArgs "demo" malformedMemory,
        limaSizingArgs malformedMemory,
        incusSizingArgs malformedMemory,
        wsl2SizingArgs malformedMemory,
        kindNodeCordonArgs "demo" malformedMemory
        ]
        @?= replicate 5 (Left "not a quantity: wat")
      [ colimaSizingArgs "demo" malformedStorage,
        limaSizingArgs malformedStorage,
        incusSizingArgs malformedStorage,
        wsl2SizingArgs malformedStorage,
        kindNodeCordonArgs "demo" malformedStorage
        ]
        @?= replicate 5 (Left "not a quantity: wat"),
    testCase "unknown and inexact quantities retain exact descriptive refusals" $ do
      Foundation.parseQuantity "8Qi"
        @?= Left "unknown unit: Qi in quantity: 8Qi"
      Foundation.parseQuantity "0.1B"
        @?= Left "quantity is not an exact whole-byte value: 0.1B",
    testCase "whole-GiB renderer failures equal the lower canonical renderers" $ do
      inexactMemory <- either assertFailure pure (Foundation.mkResourceBudget 4 (8 * gib + 1) (20 * gib))
      inexactStorage <- either assertFailure pure (Foundation.mkResourceBudget 4 (8 * gib) (20 * gib + 1))
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
        @?= Left "WSL2 VHDX storage must be exactly representable as whole GiB; got 21474836481 bytes",
    testCase "both preflight facades preserve lower failures exactly" $ do
      canonical <- either assertFailure pure (Foundation.mkResourceBudget 4 (8 * gib) (20 * gib))
      let reserveFreeCapacity = Foundation.HostCapacity 2 (16 * gib) (100 * gib)
          metalCapacity = Foundation.HostCapacity 2 (10 * gib) (100 * gib)
          cpuError = Left "resource budget exceeds host capacity: cpu wants 4 cores, host has 2 cores"
          reserveError = Left "resource budget plus host reserve exceeds host memory: wants 8 GiB + 4 GiB host reserve, host has 10 GiB"
      preflightBudget demoResources reserveFreeCapacity @?= Foundation.verifyBudget canonical reserveFreeCapacity
      preflightBudget demoResources reserveFreeCapacity @?= cpuError
      preflightHostBudget demoResources metalCapacity @?= Foundation.verifyHostBudget canonical metalCapacity
      preflightHostBudget demoResources metalCapacity @?= reserveError,
    testCase "foundation verifies canonical budgets without a configuration envelope" $ do
      canonical <- either assertFailure pure (Foundation.mkResourceBudget 4 (8 * gib) (20 * gib))
      Foundation.verifyBudget canonical (Foundation.HostCapacity 8 (16 * gib) (100 * gib)) @?= Right ()
      leftHas "reserve" (Foundation.verifyHostBudget canonical (Foundation.HostCapacity 8 (10 * gib) (100 * gib))),
    testCase "foundation owns quantity parsing and the pure storage policy" $ do
      Foundation.parseQuantity "0.5Ki" @?= Right 512
      Foundation.storageCordonPolicy Foundation.BareLinuxStorage
        @?= Foundation.StorageCordonUnsupported Foundation.BareLinuxQuotaAndImageGcUnavailable,
    testCase "configuration facade imports only the lower foundation and descriptive vocabularies" $ do
      cwd <- getCurrentDirectory
      root <- findRepoRoot cwd >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
      let packageRoot = root </> "core" </> "hostbootstrap-core"
      facadeSource <- TextIO.readFile (packageRoot </> "src" </> "HostBootstrap" </> "Cluster" </> "Cordon.hs")
      sort (nub (hostbootstrapImports facadeSource))
        @?= sort
          [ "HostBootstrap.Cluster.Cordon.Foundation",
            "HostBootstrap.Config.Vocab",
            "HostBootstrap.Context"
          ],
    testCase "foundation imports only modules below the canonical-quantities boundary and is exposed" $ do
      cwd <- getCurrentDirectory
      root <- findRepoRoot cwd >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
      let packageRoot = root </> "core" </> "hostbootstrap-core"
      source <- TextIO.readFile (packageRoot </> "src" </> "HostBootstrap" </> "Cluster" </> "Cordon" </> "Foundation.hs")
      cabal <- TextIO.readFile (packageRoot </> "hostbootstrap-core.cabal")
      let importedModules = sort (hostbootstrapImports source)
      importedModules
        @?= sort
          [ "HostBootstrap.HostConfig",
            "HostBootstrap.HostTool",
            "HostBootstrap.Substrate"
          ]
      exposedModules <- either assertFailure pure (mainLibraryExposedModules cabal)
      assertBool
        "Cordon.Foundation must be exposed by the unnamed main library"
        ("HostBootstrap.Cluster.Cordon.Foundation" `elem` exposedModules),
    testCase "foundation import scanner covers every supported import decoration" $ do
      let sample =
            Text.unlines
              [ "-- import HostBootstrap.Commented",
                "import HostBootstrap.Plain",
                "import qualified HostBootstrap.Qualified as Qualified",
                "import safe HostBootstrap.Safe",
                "import {-# SOURCE #-} HostBootstrap.Source",
                "import \"hostbootstrap-core\" HostBootstrap.PackageQualified",
                "import",
                "  safe",
                "  qualified",
                "  HostBootstrap.Multiline",
                "literal = \"import HostBootstrap.StringLiteral\""
              ]
      sort (hostbootstrapImports sample)
        @?= sort
          [ "HostBootstrap.Multiline",
            "HostBootstrap.PackageQualified",
            "HostBootstrap.Plain",
            "HostBootstrap.Qualified",
            "HostBootstrap.Safe",
            "HostBootstrap.Source"
          ],
    testCase "cabal parser scopes exposure to the unnamed main library" $ do
      let sample =
            Text.unlines
              [ "library helper",
                "  exposed-modules:",
                "      HostBootstrap.NotMain",
                "library",
                "  exposed-modules: HostBootstrap.PublicInline,",
                "      HostBootstrap.PublicContinuation",
                "  other-modules:",
                "      HostBootstrap.NotExposed",
                "test-suite tests",
                "  main-is: Spec.hs"
              ]
      mainLibraryExposedModules sample
        @?= Right ["HostBootstrap.PublicInline", "HostBootstrap.PublicContinuation"]
  ]

hostbootstrapImports :: Text.Text -> [Text.Text]
hostbootstrapImports = collect . haskellTokens . Text.unpack
  where
    collect [] = []
    collect ("import" : remaining) =
      case importedModule remaining of
        Just moduleName
          | "HostBootstrap." `Text.isPrefixOf` moduleName ->
              moduleName : collect remaining
        _ -> collect remaining
    collect (_ : remaining) = collect remaining

haskellTokens :: String -> [String]
haskellTokens source =
  case dropWhile isSpace source of
    "" -> []
    '-' : '-' : remaining -> haskellTokens (dropLineComment remaining)
    '{' : '-' : '#' : remaining ->
      "{" : "-#" : haskellTokens remaining
    '{' : '-' : remaining -> haskellTokens (dropBlockComment 1 remaining)
    significant ->
      case lex significant of
        [(token, remaining)]
          | not (null token) && remaining /= significant -> token : haskellTokens remaining
        _ -> haskellTokens (drop 1 significant)

dropLineComment :: String -> String
dropLineComment source =
  case dropWhile (/= '\n') source of
    _newline : remaining -> remaining
    [] -> []

dropBlockComment :: Int -> String -> String
dropBlockComment _depth [] = []
dropBlockComment depth ('{' : '-' : remaining) =
  dropBlockComment (depth + 1) remaining
dropBlockComment depth ('-' : '}' : remaining)
  | depth == 1 = remaining
  | otherwise = dropBlockComment (depth - 1) remaining
dropBlockComment depth (_ : remaining) = dropBlockComment depth remaining

importedModule :: [String] -> Maybe Text.Text
importedModule = parseModuleName . dropImportDecorators

dropImportDecorators :: [String] -> [String]
dropImportDecorators ("safe" : remaining) = dropImportDecorators remaining
dropImportDecorators ("qualified" : remaining) = dropImportDecorators remaining
dropImportDecorators ("{" : "-#" : remaining) =
  dropImportDecorators (dropImportPragma remaining)
dropImportDecorators (packageName : remaining)
  | isQuotedToken packageName = dropImportDecorators remaining
dropImportDecorators remaining = remaining

dropImportPragma :: [String] -> [String]
dropImportPragma ("#-" : "}" : remaining) = remaining
dropImportPragma (_ : remaining) = dropImportPragma remaining
dropImportPragma [] = []

isQuotedToken :: String -> Bool
isQuotedToken ('"' : remaining) =
  case reverse remaining of
    '"' : _ -> True
    _ -> False
isQuotedToken _ = False

parseModuleName :: [String] -> Maybe Text.Text
parseModuleName (firstSegment : remaining)
  | isModuleSegment firstSegment =
      Just (Text.intercalate "." (fmap Text.pack (reverse segments)))
  where
    (segments, _afterModule) = gather [firstSegment] remaining
    gather collected ("." : segment : rest)
      | isModuleSegment segment = gather (segment : collected) rest
    gather collected rest = (collected, rest)
parseModuleName _ = Nothing

isModuleSegment :: String -> Bool
isModuleSegment segment =
  case segment of
    firstCharacter : remaining ->
      isUpper firstCharacter
        && all (\character -> isAlphaNum character || character == '_' || character == '\'') remaining
    [] -> False

mainLibraryExposedModules :: Text.Text -> Either String [Text.Text]
mainLibraryExposedModules cabal =
  case dropWhile (not . isMainLibraryHeader) (Text.lines cabal) of
    [] -> Left "hostbootstrap-core.cabal: unnamed main library stanza is missing"
    _header : remaining ->
      exposedModulesFromStanza (takeWhile (not . isTopLevelDeclaration) remaining)

isMainLibraryHeader :: Text.Text -> Bool
isMainLibraryHeader line =
  Text.strip line == "library" && Text.stripStart line == line

isTopLevelDeclaration :: Text.Text -> Bool
isTopLevelDeclaration line =
  let stripped = Text.strip line
   in not (Text.null stripped)
        && not ("--" `Text.isPrefixOf` stripped)
        && Text.stripStart line == line

exposedModulesFromStanza :: [Text.Text] -> Either String [Text.Text]
exposedModulesFromStanza [] =
  Left "hostbootstrap-core.cabal: main library exposed-modules field is missing"
exposedModulesFromStanza (line : remaining)
  | "exposed-modules:" `Text.isPrefixOf` Text.stripStart line =
      let fieldIndent = leadingWhitespace line
          inlineValue = Text.drop 1 (Text.dropWhile (/= ':') line)
          continuation = takeWhile (isFieldContinuation fieldIndent) remaining
       in Right (concatMap cabalModuleWords (inlineValue : continuation))
  | otherwise = exposedModulesFromStanza remaining

leadingWhitespace :: Text.Text -> Int
leadingWhitespace line = Text.length (Text.takeWhile isSpace line)

isFieldContinuation :: Int -> Text.Text -> Bool
isFieldContinuation fieldIndent line =
  let stripped = Text.strip line
   in Text.null stripped
        || "--" `Text.isPrefixOf` stripped
        || leadingWhitespace line > fieldIndent

cabalModuleWords :: Text.Text -> [Text.Text]
cabalModuleWords line =
  Text.words
    ( Text.map
        (\character -> if character == ',' then ' ' else character)
        (fst (Text.breakOn "--" line))
    )

quantityCases :: [TestTree]
quantityCases =
  [ testCase "8Gi binary" (parseQuantity "8Gi" @?= Right (8 * gib)),
    testCase "8GiB binary (B suffix)" (parseQuantity "8GiB" @?= Right (8 * gib)),
    testCase "512Mi binary" (parseQuantity "512Mi" @?= Right (512 * mib)),
    testCase "1G decimal" (parseQuantity "1G" @?= Right 1000000000),
    testCase "an exact fractional binary quantity is accepted" (parseQuantity "0.5Ki" @?= Right 512),
    testCase "a fractional quantity that is not a whole byte is rejected" (isLeft (parseQuantity "0.1B") @?= True),
    testCase "bare number is bytes" (parseQuantity "1024" @?= Right 1024),
    testCase "whitespace tolerated" (parseQuantity "  4Gi " @?= Right (4 * gib)),
    testCase "unknown unit rejected" (isLeft (parseQuantity "8Qi") @?= True),
    testCase "empty rejected" (isLeft (parseQuantity "") @?= True)
  ]

budgetCases :: [TestTree]
budgetCases =
  [ testCase "resources -> canonical byte budget" $
      fmap
        (\budget -> (budgetCpu budget, budgetMemoryBytes budget, budgetStorageBytes budget))
        (budgetFromResources demoResources)
        @?= Right (4, 8 * gib, 20 * gib),
    testCase "gibibytes rounds up" $
      map gibibytes [gib, gib + 1, 8 * gib] @?= [1, 2, 8],
    testCase "public budget construction rejects non-positive dimensions" $ do
      isLeft (mkResourceBudget 0 gib gib) @?= True
      isLeft (mkResourceBudget 1 0 gib) @?= True
      isLeft (mkResourceBudget 1 gib 0) @?= True
  ]

verifyCases :: [TestTree]
verifyCases =
  [ testCase "within capacity passes (reserve-free — the in-VM slice check)" $
      verifyBudget budget (HostCapacity 8 (16 * gib) (100 * gib)) @?= Right (),
    testCase "cpu over capacity fails naming cpu" $
      leftHas "cpu" (verifyBudget budget (HostCapacity 2 (16 * gib) (100 * gib))),
    testCase "memory over capacity fails naming memory" $
      leftHas "memory" (verifyBudget budget (HostCapacity 8 (4 * gib) (100 * gib))),
    testCase "storage over capacity fails naming storage" $
      leftHas "storage" (verifyBudget budget (HostCapacity 8 (16 * gib) (10 * gib))),
    testCase "verifyBudget does NOT apply the host reserve (the in-VM slice fits available memory)" $
      -- an 8 GiB slice against 9 GiB available memory passes reserve-free: the real
      -- run's bug was re-reserving here (6 GiB slice + 4 GiB > 9 GiB avail) — the
      -- reserve belongs only to the metal preflight (verifyHostBudget).
      verifyBudget budget (HostCapacity 8 (9 * gib) (100 * gib)) @?= Right (),
    testCase "verifyHostBudget (metal) DOES reserve: fits total but not total-minus-reserve → fails" $
      -- 8 GiB budget + 4 GiB host reserve = 12 GiB > 10 GiB total: a tight metal host
      -- is refused rather than silently over-committed.
      leftHas "reserve" (verifyHostBudget budget (HostCapacity 8 (10 * gib) (100 * gib))),
    testCase "verifyHostBudget names host memory + the reserve" $
      leftHas "memory" (verifyHostBudget budget (HostCapacity 8 (10 * gib) (100 * gib))),
    testCase "verifyHostBudget passes when the reserve fits" $
      verifyHostBudget budget (HostCapacity 8 (16 * gib) (100 * gib)) @?= Right ()
  ]
  where
    budget = either (error . show) id (mkResourceBudget 4 (8 * gib) (20 * gib))

capacitySourceCases :: [TestTree]
capacitySourceCases =
    [ testCase "apple-silicon reads CPU/memory from sysctl and free disk from df" $
      capacityReadPlan (Substrate AppleSilicon Arm64)
        @?= CapacityReadPlan (SysctlKey "hw.ncpu") (SysctlKey "hw.memsize") (PosixFreeStorage "/"),
    testCase "linux-cpu reads CPU/memory from procfs and free disk from df" $
      capacityReadPlan (Substrate LinuxCpu Amd64)
        @?= CapacityReadPlan ProcCpuinfo ProcMemAvailable (PosixFreeStorage "/"),
    testCase "linux-gpu reads CPU/memory from procfs and free disk from df" $
      capacityReadPlan (Substrate LinuxGpu Amd64)
        @?= CapacityReadPlan ProcCpuinfo ProcMemAvailable (PosixFreeStorage "/"),
    testCase "windows substrates read CPU, total memory, and storage from PowerShell/CIM" $ do
      capacityReadPlan (Substrate WindowsCpu Amd64)
        @?= CapacityReadPlan WindowsLogicalProcessors WindowsTotalMemory WindowsSystemDriveFreeSpace
      capacityReadPlan (Substrate WindowsGpu Amd64)
        @?= CapacityReadPlan WindowsLogicalProcessors WindowsTotalMemory WindowsSystemDriveFreeSpace,
    testCase "df -k output parses to the available-1K-blocks field" $ do
      parseDfAvailableKBytes "Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/disk1s1 500000000 100000000 400000000 20% /\n"
        @?= Just 400000000
      parseDfAvailableKBytes "" @?= Nothing,
    testCase "windows storage shortage fails before WSL2 VHDX pressure" $
      leftHas "storage" $
        preflightBudget
          (ResourceEnvelope {cpu = 6, memory = "10GiB", storage = "80GiB"})
          (HostCapacity 16 (20 * gib) (40 * gib)),
    testCase "apple sysctl core count can satisfy a matching N-core budget" $
      preflightBudget
        (ResourceEnvelope {cpu = 10, memory = "8GiB", storage = "20GiB"})
        (HostCapacity 10 (16 * gib) petabyte)
        @?= Right (),
    testCase "live apple-silicon sysctl read resolves positive capacity" $ do
      if Info.os == "darwin" && Info.arch `elem` ["aarch64", "arm64"]
        then do
          sysctl <- findExecutable "sysctl"
          df <- findExecutable "df"
          let resolvedTools =
                ( sysctl >>= either (const Nothing) Just . mkAbsExe,
                  df >>= either (const Nothing) Just . mkAbsExe
                )
          case resolvedTools of
            (Nothing, _) -> assertBool "expected sysctl to resolve to an absolute path" False
            (_, Nothing) -> assertBool "expected df to resolve to an absolute path" False
            (Just sysctlExe, Just dfExe) -> do
              result <-
                resolveHostCapacity
                  HostConfig
                    { hcSubstrate = Substrate AppleSilicon Arm64,
                      hcToolPaths = Map.fromList [(Sysctl, sysctlExe), (Df, dfExe)]
                    }
              case result of
                Right capacity ->
                  assertBool "expected positive CPU and memory capacity" $
                    totalCpu capacity > 0 && totalMemoryBytes capacity > 0
                Left err -> assertBool ("expected sysctl capacity read to succeed, got: " ++ err) False
        else pure ()
  ]
  where
    petabyte = 1024 ^ (5 :: Integer)

fitsCases :: [TestTree]
fitsCases =
  [ testCase "a fitting pod set is accepted" $
      fitsBudget (V.Budget 4 8 20) [V.PodResources 2 1 1 1 2] @?= Right (),
    testCase "an over-cpu pod set is rejected naming cpu" $
      fitsBudget (V.Budget 2 8 20) [V.PodResources 3 1 2 1 1]
        @?= Left (Overflow "cpu" 6 2),
    testCase "an over-memory pod set is rejected naming memory" $
      fitsBudget (V.Budget 8 4 20) [V.PodResources 3 1 1 1 4]
        @?= Left (Overflow "memory" 12 4),
    testCase "preflightBudget passes within spare capacity" $
      preflightBudget demoResources (HostCapacity 8 (16 * gib) (100 * gib)) @?= Right (),
    testCase "preflightBudget fails fast when short" $
      leftHas "cpu" (preflightBudget demoResources (HostCapacity 2 (16 * gib) (100 * gib)))
  ]

sizingCases :: [TestTree]
sizingCases =
  [ testCase "colima sizing splits one 40 GiB ceiling across fixed root and data disks" $
      colimaSizingArgs "demo" (ResourceEnvelope {cpu = 4, memory = "8GiB", storage = "40GiB"})
        @?= Right
          [ "start",
            "--profile",
            "demo",
            "--runtime",
            "docker",
            "--activate=false",
            "--template=false",
            "--ssh-config=false",
            "--mount",
            "none",
            "--kubernetes=false",
            "--network-address=false",
            "--mount-inotify=false",
            "--cpus",
            "4",
            "--memory",
            "8",
            "--root-disk",
            "20",
            "--disk",
            "20"
          ],
    testCase "colima sizing rejects totals that cannot exceed the fixed writable root disk" $ do
      colimaSizingArgs "demo" (ResourceEnvelope {cpu = 4, memory = "8GiB", storage = "20GiB"})
        @?= Left "Colima storage must exceed the fixed 20 GiB writable root disk; got 20 GiB"
      colimaSizingArgs "demo" (ResourceEnvelope {cpu = 4, memory = "8GiB", storage = "19GiB"})
        @?= Left "Colima storage must exceed the fixed 20 GiB writable root disk; got 19 GiB",
    testCase "colima sizing rejects an inexact total before splitting the disks" $
      colimaSizingArgs "demo" (ResourceEnvelope {cpu = 4, memory = "8GiB", storage = "42949672961"})
        @?= Left "Colima storage must be exactly representable as whole GiB; got 42949672961 bytes",
    testCase "colima sizing closes ambient templates, host config, mounts, and network helpers" $ do
      args <-
        either
          assertFailure
          pure
          (colimaSizingArgs "demo" (ResourceEnvelope {cpu = 4, memory = "8GiB", storage = "40GiB"}))
      mapM_
        (\flag -> assertBool ("missing safe Colima flag: " ++ flag) (flag `elem` args))
        [ "--activate=false",
          "--template=false",
          "--ssh-config=false",
          "--kubernetes=false",
          "--network-address=false",
          "--mount-inotify=false"
        ]
      assertBool "Colima home mounts must be disabled" (["--mount", "none"] `isInfixOf` args),
    testCase "provider storage policy names each represented wall" $ do
      storageCordonPolicy ColimaVmStorage @?= StorageCordonSupported ColimaDiskFlag
      storageCordonPolicy LimaVmStorage @?= StorageCordonSupported LimaDiskFlag
      storageCordonPolicy IncusVmStorage @?= StorageCordonSupported IncusRootDiskLimit
      storageCordonPolicy Wsl2DistroStorage @?= StorageCordonSupported Wsl2VhdSize,
    testCase "bare Linux storage policy is explicitly unsupported" $
      storageCordonPolicy BareLinuxStorage
        @?= StorageCordonUnsupported BareLinuxQuotaAndImageGcUnavailable,
    testCase "colima handles the bare 8Gi form" $
      colimaSizingArgs "demo" (ResourceEnvelope {cpu = 2, memory = "8Gi", storage = "40Gi"})
        @?= Right
          [ "start",
            "--profile",
            "demo",
            "--runtime",
            "docker",
            "--activate=false",
            "--template=false",
            "--ssh-config=false",
            "--mount",
            "none",
            "--kubernetes=false",
            "--network-address=false",
            "--mount-inotify=false",
            "--cpus",
            "2",
            "--memory",
            "8",
            "--root-disk",
            "20",
            "--disk",
            "20"
          ],
    testCase "lima sizing emits VM resource flags" $
      limaSizingArgs demoResources
        @?= Right ["--cpus", "4", "--memory", "8", "--disk", "20"],
    testCase "whole-GiB providers reject an inexact hard ceiling instead of rounding" $ do
      let inexact = ResourceEnvelope {cpu = 4, memory = "8589934593", storage = "20GiB"}
      isLeft (colimaSizingArgs "demo" inexact) @?= True
      isLeft (limaSizingArgs inexact) @?= True
      isLeft (incusSizingArgs inexact) @?= True
      isLeft (wsl2SizingArgs inexact) @?= True,
    testCase "wsl2 sizing emits the .wslconfig [general]+[wsl2] ceiling with swap + both idle timeouts (no vhdx-size key)" $
      wsl2SizingArgs demoResources
        @?= Right ["[general]", "instanceIdleTimeout=21600000", "[wsl2]", "processors=4", "memory=8GB", "swap=8GB", "vmIdleTimeout=21600000"],
    testCase "both managed idle timeouts are finite, so the host always recovers the balloon" $ do
      -- The wall was previously pinned open with -1, which is why `project down`
      -- could leave the whole budget committed until the next reboot. A finite
      -- duration is the property that matters; the exact value is asserted above.
      managedWslIdleTimeoutMillis > 0 @?= True
      managedWslIdleTimeoutMillis @?= managedWslIdleTimeoutHours * 60 * 60 * 1000
      body <- either assertFailure pure (wsl2SizingArgs demoResources)
      let timeouts = filter (\l -> "instanceIdleTimeout=" `isPrefixOf` l || "vmIdleTimeout=" `isPrefixOf` l) body
      length timeouts @?= 2
      all (\l -> not ("=-" `isInfixOf` l)) timeouts @?= True,
    testCase "applied Linux cordon caps the control-plane with 2x swap headroom" $
      kindNodeCordonArgs "demo-test-case1" demoResources
        @?= Right
          [ "update",
            "--cpus",
            "4",
            "--memory",
            show (8 * gib),
            "--memory-swap",
            show (2 * 8 * gib),
            "demo-test-case1-control-plane"
          ],
    testCase "the docker update cordon argv omits storage (no docker flag)" $
      assertBool "no storage in docker update argv" $
        case kindNodeCordonArgs "demo" demoResources of
          Right args -> show (20 * gib) `notElem` args
          Left _ -> False
  ]

leftHas :: String -> Either String a -> IO ()
leftHas needle e = case e of
  Left msg -> assertBool ("expected '" ++ needle ++ "' in: " ++ msg) (needle `isInfixOf` msg)
  Right _ -> assertBool ("expected Left mentioning " ++ needle) False

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
