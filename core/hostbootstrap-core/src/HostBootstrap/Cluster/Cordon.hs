{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Resource-budget verification and cordoning.
--
-- @hostbootstrap@ verifies the host has the spare budget declared in the
-- active project-local config's @resources@ and cordons it to the project: on
-- Apple by sizing a dedicated per-project Colima VM, on Linux by applying a
-- @docker update@ cap to the kind control-plane node (see
-- @development_plan_standards.md § O@). There is **one** canonical quantity
-- parser ('parseQuantity') feeding every argument builder, so the one declared
-- budget number is interpreted identically everywhere. The parsing, budget
-- verification, the fits-within proof, and the tool-argument derivations are pure
-- so they can be unit-tested; the IO driver resolves the host capacity and runs
-- the sized tools.
module HostBootstrap.Cluster.Cordon
  ( ResourceBudget (..),
    HostCapacity (..),
    CapacityReadSource (..),
    CapacityReadPlan (..),
    capacityReadPlan,
    Overflow (..),
    parseQuantity,
    budgetFromResources,
    verifyBudget,
    preflightBudget,
    fitsBudget,
    colimaSizingArgs,
    limaSizingArgs,
    kindNodeCordonArgs,
    incusSizingArgs,
    resolveHostCapacity,
    gibibytes,
  )
where

import Control.Exception (SomeException, displayException)
import Control.Exception.Safe (try)
import Data.Char (isDigit)
import Data.List (isPrefixOf)
import qualified Data.Text as T
import HostBootstrap.Config.Schema (Resources (..))
import qualified HostBootstrap.Config.Vocab as Vocab
import HostBootstrap.HostConfig (HostConfig (..), resolveMaybe)
import HostBootstrap.HostTool (HostTool (Sysctl), absExePath)
import HostBootstrap.Substrate (Substrate, SubstrateName (..), renderSubstrateName, substrateName)
import Numeric.Natural (Natural)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

-- | A resolved resource budget in canonical units: whole CPU cores, and memory
-- / storage in bytes.
data ResourceBudget = ResourceBudget
  { budgetCpu :: Natural,
    budgetMemoryBytes :: Integer,
    budgetStorageBytes :: Integer
  }
  deriving (Eq, Show)

-- | Spare host capacity, in the same canonical units.
data HostCapacity = HostCapacity
  { spareCpu :: Natural,
    spareMemoryBytes :: Integer,
    spareStorageBytes :: Integer
  }
  deriving (Eq, Show)

-- | The concrete source used to read a capacity dimension.
data CapacityReadSource
  = ProcCpuinfo
  | ProcMemAvailable
  | SysctlKey String
  deriving (Eq, Show)

-- | The substrate-specific host-capacity read plan. Pure so the source mapping
-- stays unit-tested without executing host tools.
data CapacityReadPlan = CapacityReadPlan
  { cpuCapacitySource :: CapacityReadSource,
    memoryCapacitySource :: CapacityReadSource
  }
  deriving (Eq, Show)

-- | A budget overflow: which dimension, what the pods want, and the budget cap
-- (in the vocabulary's units).
data Overflow = Overflow
  { overflowDimension :: String,
    overflowWanted :: Natural,
    overflowAllowed :: Natural
  }
  deriving (Eq, Show)

-- | Parse a Kubernetes-style quantity to bytes. Accepts binary suffixes
-- (@Ki@, @Mi@, @Gi@, @Ti@, optionally followed by @B@) and decimal suffixes
-- (@K@, @M@, @G@, @T@); a bare number is bytes. The one canonical quantity
-- grammar. Pure.
parseQuantity :: T.Text -> Either String Integer
parseQuantity raw =
  let t = T.strip raw
      (numText, unitText) = T.span (\c -> isDigit c || c == '.') t
      unit = T.unpack (T.strip unitText)
   in if T.null numText
        then Left ("not a quantity: " ++ T.unpack raw)
        else case readNumber (T.unpack numText) of
          Nothing -> Left ("not a number: " ++ T.unpack numText)
          Just n -> case multiplier unit of
            Nothing -> Left ("unknown unit: " ++ unit)
            Just m -> Right (round (n * fromIntegral m :: Double))

readNumber :: String -> Maybe Double
readNumber s = case reads s of
  [(n, "")] -> Just n
  _ -> Nothing

-- | The byte multiplier for a quantity unit. @""@ is bytes.
multiplier :: String -> Maybe Integer
multiplier unit = case unit of
  "" -> Just 1
  "B" -> Just 1
  "Ki" -> Just (k 1)
  "KiB" -> Just (k 1)
  "Mi" -> Just (k 2)
  "MiB" -> Just (k 2)
  "Gi" -> Just (k 3)
  "GiB" -> Just (k 3)
  "Ti" -> Just (k 4)
  "TiB" -> Just (k 4)
  "K" -> Just (d 1)
  "M" -> Just (d 2)
  "G" -> Just (d 3)
  "T" -> Just (d 4)
  _ -> Nothing
  where
    k n = 1024 ^ (n :: Integer)
    d n = 1000 ^ (n :: Integer)

-- | Resolve a project-local @resources@ block into a canonical byte budget.
budgetFromResources :: Resources -> Either String ResourceBudget
budgetFromResources r = do
  mem <- parseQuantity (memory r)
  sto <- parseQuantity (storage r)
  pure (ResourceBudget (cpu r) mem sto)

-- | Verify the host has the spare budget. Fails fast with a one-line diagnostic
-- naming the first dimension that exceeds spare capacity.
verifyBudget :: ResourceBudget -> HostCapacity -> Either String ()
verifyBudget b cap
  | budgetCpu b > spareCpu cap =
      Left (overMsg "cpu" (show (budgetCpu b)) (show (spareCpu cap)) "cores")
  | budgetMemoryBytes b > spareMemoryBytes cap =
      Left (overMsg "memory" (showGiB (budgetMemoryBytes b)) (showGiB (spareMemoryBytes cap)) "GiB")
  | budgetStorageBytes b > spareStorageBytes cap =
      Left (overMsg "storage" (showGiB (budgetStorageBytes b)) (showGiB (spareStorageBytes cap)) "GiB")
  | otherwise = Right ()
  where
    overMsg dim want have unit =
      "resource budget exceeds spare host capacity: "
        ++ dim
        ++ " wants "
        ++ want
        ++ " "
        ++ unit
        ++ ", host has "
        ++ have
        ++ " "
        ++ unit
        ++ " spare"

-- | The spare-capacity preflight as a single fail-fast gate: parse the budget,
-- then verify it against resolved spare host capacity. Pure (the IO that resolves
-- capacity is 'resolveHostCapacity').
preflightBudget :: Resources -> HostCapacity -> Either String ()
preflightBudget r cap = budgetFromResources r >>= \b -> verifyBudget b cap

-- | Prove a concurrent pod set fits within the (vocabulary) budget — the Haskell
-- mirror of @Core.dhall@ @fitsWithin@, used as the bring-up ring before the
-- generated config's Dhall-time assert. Pure.
fitsBudget :: Vocab.Budget -> [Vocab.PodResources] -> Either Overflow ()
fitsBudget b pods
  | wantCpu > b.cpu = Left (Overflow "cpu" wantCpu b.cpu)
  | wantMem > b.memory = Left (Overflow "memory" wantMem b.memory)
  | otherwise = Right ()
  where
    wantCpu = foldl' (\acc p -> acc + p.replicas * p.cpuLimit) 0 pods
    wantMem = foldl' (\acc p -> acc + p.replicas * p.memoryLimit) 0 pods

-- | The complete @colima start@ argv that sizes a per-project VM to the budget
-- (the canonical arg-builder; the Python bootstrapper does not size VMs).
-- Memory and disk are rounded up to whole GiB (Colima's unit); CPU is the whole
-- core count. Storage is cordoned here via @--disk@.
colimaSizingArgs :: String -> Resources -> Either String [String]
colimaSizingArgs project r = do
  b <- budgetFromResources r
  pure
    [ "start",
      "--profile",
      project,
      "--cpu",
      show (budgetCpu b),
      "--memory",
      show (gibibytes (budgetMemoryBytes b)),
      "--disk",
      show (gibibytes (budgetStorageBytes b))
    ]

-- | The Lima VM sizing flags derived from the same canonical resource parser.
limaSizingArgs :: Resources -> Either String [String]
limaSizingArgs r = do
  b <- budgetFromResources r
  pure
    [ "--cpus",
      show (budgetCpu b),
      "--memory",
      show (gibibytes (budgetMemoryBytes b)),
      "--disk",
      show (gibibytes (budgetStorageBytes b))
    ]

-- | The applied Linux kind-node cordon argv: a @docker update@ cap on the
-- resolved control-plane container. @--memory-swap == --memory@ so an
-- over-budget cluster self-limits rather than swapping. Storage carries **no**
-- @docker update@ flag, so it is omitted here and cordoned per-substrate
-- elsewhere (Colima @--disk@, incus @root,size@, a quota'd hostPath on bare
-- Linux).
kindNodeCordonArgs :: String -> Resources -> Either String [String]
kindNodeCordonArgs clusterName r = do
  b <- budgetFromResources r
  pure
    [ "update",
      "--cpus",
      show (budgetCpu b),
      "--memory",
      show (budgetMemoryBytes b),
      "--memory-swap",
      show (budgetMemoryBytes b),
      clusterName ++ "-control-plane"
    ]

-- | The incus VM sizing args from the one canonical parser: @limits.cpu@,
-- @limits.memory@, and @root,size@. Unlike @docker update@, incus cordons
-- storage at the VM wall, so storage **is** included here (via @root,size@). The
-- form is a list of @incus@ config arguments the caller applies to the VM.
incusSizingArgs :: Resources -> Either String [String]
incusSizingArgs r = do
  b <- budgetFromResources r
  pure
    [ "limits.cpu=" ++ show (budgetCpu b),
      "limits.memory=" ++ show (gibibytes (budgetMemoryBytes b)) ++ "GiB",
      "root,size=" ++ show (gibibytes (budgetStorageBytes b)) ++ "GiB"
    ]

-- | Select the host-capacity read sources for a detected substrate.
capacityReadPlan :: Substrate -> CapacityReadPlan
capacityReadPlan sub = case substrateName sub of
  AppleSilicon -> CapacityReadPlan (SysctlKey "hw.ncpu") (SysctlKey "hw.memsize")
  LinuxCpu -> linuxReadPlan
  LinuxGpu -> linuxReadPlan
  where
    linuxReadPlan = CapacityReadPlan ProcCpuinfo ProcMemAvailable

-- | Resolve spare host capacity for the preflight. CPU and memory come from the
-- substrate-specific sources selected by 'capacityReadPlan': @sysctl@ on
-- apple-silicon and @/proc@ on linux. Storage is reported generously so it does
-- not false-fail the preflight — the applied storage cordon (Colima @--disk@ /
-- incus @root,size@ / hostPath quota) is the real storage wall. Exercised live
-- during bring-up.
resolveHostCapacity :: HostConfig -> IO (Either String HostCapacity)
resolveHostCapacity cfg = do
  let plan = capacityReadPlan (hcSubstrate cfg)
  cores <- readCores cfg (cpuCapacitySource plan)
  mem <- readAvailableMemory cfg (memoryCapacitySource plan)
  pure $ do
    c <- cores
    m <- mem
    pure (HostCapacity c m petabyte)

petabyte :: Integer
petabyte = 1024 ^ (5 :: Integer)

-- | Count CPU cores from the substrate-selected source.
readCores :: HostConfig -> CapacityReadSource -> IO (Either String Natural)
readCores _ ProcCpuinfo = do
  exists <- doesFileExist "/proc/cpuinfo"
  if not exists
    then pure (Left "host capacity: /proc/cpuinfo is not available")
    else do
      result <- try (readFile "/proc/cpuinfo") :: IO (Either SomeException String)
      pure $ case result of
        Right contents ->
          let n = length (filter ("processor" `isPrefixOf`) (lines contents))
           in if n > 0
                then Right (fromIntegral n)
                else Left "host capacity: no processors found in /proc/cpuinfo"
        Left e -> Left ("host capacity: failed to read /proc/cpuinfo: " ++ displayException e)
readCores cfg (SysctlKey key) = fmap (fmap fromInteger) (readSysctlPositiveInteger cfg key)
readCores _ source =
  pure (Left ("host capacity: unsupported CPU source " ++ show source))

-- | Read available memory from the substrate-selected source, in bytes.
readAvailableMemory :: HostConfig -> CapacityReadSource -> IO (Either String Integer)
readAvailableMemory _ ProcMemAvailable = do
  exists <- doesFileExist "/proc/meminfo"
  if not exists
    then pure (Left "host capacity: /proc/meminfo is not available")
    else do
      result <- try (readFile "/proc/meminfo") :: IO (Either SomeException String)
      pure $ case result of
        Right contents -> case findMemAvailable (lines contents) of
          Just kb -> Right (kb * 1024)
          Nothing -> Left "host capacity: MemAvailable not found in /proc/meminfo"
        Left e -> Left ("host capacity: failed to read /proc/meminfo: " ++ displayException e)
readAvailableMemory cfg (SysctlKey key) = readSysctlPositiveInteger cfg key
readAvailableMemory _ source =
  pure (Left ("host capacity: unsupported memory source " ++ show source))

readSysctlPositiveInteger :: HostConfig -> String -> IO (Either String Integer)
readSysctlPositiveInteger cfg key = do
  value <- readSysctl cfg key
  pure $ do
    raw <- value
    n <- parsePositiveInteger ("sysctl " ++ key) raw
    if n > 0
      then Right n
      else Left ("host capacity: sysctl " ++ key ++ " returned non-positive value " ++ show n)

readSysctl :: HostConfig -> String -> IO (Either String String)
readSysctl cfg key = case resolveMaybe cfg Sysctl of
  Nothing ->
    pure $
      Left
        ( "host capacity: sysctl is not resolved for "
            ++ renderSubstrateName (substrateName (hcSubstrate cfg))
        )
  Just exe -> do
    result <-
      try (readProcessWithExitCode (absExePath exe) ["-n", key] "") ::
        IO (Either SomeException (ExitCode, String, String))
    pure $ case result of
      Right (ExitSuccess, out, _) -> Right (T.unpack (T.strip (T.pack out)))
      Right (ExitFailure n, _, err) ->
        Left
          ( "host capacity: sysctl "
              ++ key
              ++ " failed (exit "
              ++ show n
              ++ "): "
              ++ T.unpack (T.strip (T.pack err))
          )
      Left e ->
        Left ("host capacity: failed to run sysctl " ++ key ++ ": " ++ displayException e)

parsePositiveInteger :: String -> String -> Either String Integer
parsePositiveInteger label raw = case reads raw of
  [(n, "")] -> Right n
  _ -> Left ("host capacity: " ++ label ++ " returned non-integer value " ++ show raw)

findMemAvailable :: [String] -> Maybe Integer
findMemAvailable ls = case [w | l <- ls, "MemAvailable:" `isPrefixOf` l, w <- take 1 (drop 1 (words l))] of
  (kb : _) -> case reads kb of
    [(n, "")] -> Just n
    _ -> Nothing
  [] -> Nothing

-- | Bytes to whole gibibytes, rounded up.
gibibytes :: Integer -> Integer
gibibytes bytes = (bytes + gib - 1) `div` gib
  where
    gib = 1024 ^ (3 :: Integer)

showGiB :: Integer -> String
showGiB = show . gibibytes
