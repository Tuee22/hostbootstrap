{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Resource-budget verification and cordoning.
--
-- @hostbootstrap@ verifies the host has the spare budget declared in the
-- static-base config's @resources@ and cordons it to the project: on Apple by
-- sizing a dedicated per-project Colima VM, on Linux by applying a @docker
-- update@ cap to the kind control-plane node (see
-- @development_plan_standards.md § O@). There is **one** canonical quantity
-- parser ('parseQuantity') feeding every argument builder, so the one declared
-- budget number is interpreted identically everywhere. The parsing, budget
-- verification, the fits-within proof, and the tool-argument derivations are pure
-- so they can be unit-tested; the IO driver resolves the host capacity and runs
-- the sized tools.
module HostBootstrap.Cluster.Cordon
  ( ResourceBudget (..),
    HostCapacity (..),
    Overflow (..),
    parseQuantity,
    budgetFromResources,
    verifyBudget,
    preflightBudget,
    fitsBudget,
    colimaSizingArgs,
    kindNodeCordonArgs,
    incusSizingArgs,
    resolveHostCapacity,
    gibibytes,
  )
where

import Control.Exception (SomeException)
import Control.Exception.Safe (try)
import Data.Char (isDigit)
import qualified Data.Text as T
import HostBootstrap.Config.Schema (Resources (..))
import qualified HostBootstrap.Config.Vocab as Vocab
import Numeric.Natural (Natural)
import System.Directory (doesFileExist)

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
-- grammar (the old Python @_gib@ mishandled the bare @"8Gi"@ form; this does
-- not). Pure.
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

-- | Resolve a static-base @resources@ block into a canonical byte budget.
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
-- (the canonical arg-builder; the Python bootstrapper no longer builds this).
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

-- | Resolve spare host capacity for the preflight: CPU cores and available
-- memory from @/proc@ on Linux; a permissive default when @/proc@ is absent
-- (e.g. macOS, where the Colima VM wall is the real cordon). Storage is reported
-- generously so it does not false-fail the preflight — the applied storage
-- cordon (Colima @--disk@ / incus @root,size@ / hostPath quota) is the real
-- storage wall. Exercised live during bring-up.
resolveHostCapacity :: IO HostCapacity
resolveHostCapacity = do
  cores <- readCores
  mem <- readAvailableMemory
  pure (HostCapacity cores mem (petabyte))
  where
    petabyte = 1024 ^ (5 :: Integer)

-- | Count CPU cores from @/proc/cpuinfo@; default to 1 if unreadable.
readCores :: IO Natural
readCores = do
  exists <- doesFileExist "/proc/cpuinfo"
  if not exists
    then pure 1
    else do
      result <- try (readFile "/proc/cpuinfo") :: IO (Either SomeException String)
      pure $ case result of
        Right contents ->
          let n = length (filter ("processor" `isPrefixOf'`) (lines contents))
           in if n > 0 then fromIntegral n else 1
        Left _ -> 1

-- | Read @MemAvailable@ (kB) from @/proc/meminfo@ as bytes; default generously
-- if unreadable so memory does not false-fail off-Linux.
readAvailableMemory :: IO Integer
readAvailableMemory = do
  exists <- doesFileExist "/proc/meminfo"
  if not exists
    then pure (1024 ^ (5 :: Integer))
    else do
      result <- try (readFile "/proc/meminfo") :: IO (Either SomeException String)
      pure $ case result of
        Right contents -> case findMemAvailable (lines contents) of
          Just kb -> kb * 1024
          Nothing -> 1024 ^ (5 :: Integer)
        Left _ -> 1024 ^ (5 :: Integer)

findMemAvailable :: [String] -> Maybe Integer
findMemAvailable ls = case [w | l <- ls, "MemAvailable:" `isPrefixOf'` l, w <- take 1 (drop 1 (words l))] of
  (kb : _) -> case reads kb of
    [(n, "")] -> Just n
    _ -> Nothing
  [] -> Nothing

isPrefixOf' :: String -> String -> Bool
isPrefixOf' p s = take (length p) s == p

-- | Bytes to whole gibibytes, rounded up.
gibibytes :: Integer -> Integer
gibibytes bytes = (bytes + gib - 1) `div` gib
  where
    gib = 1024 ^ (3 :: Integer)

showGiB :: Integer -> String
showGiB = show . gibibytes
