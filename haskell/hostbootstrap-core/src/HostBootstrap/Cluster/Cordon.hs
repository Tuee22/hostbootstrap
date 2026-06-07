{-# LANGUAGE OverloadedStrings #-}

-- | Resource-budget verification and cordoning.
--
-- @hostbootstrap@ verifies the host has the spare budget declared in the
-- skeletal config's @resources@ and cordons it to the project: on Apple by
-- sizing a dedicated per-project Colima VM, on Linux by applying kind node
-- resource limits (see @development_plan_standards.md § O@). The quantity
-- parsing, budget verification, and the tool-argument derivations are pure so
-- they can be unit-tested; the IO driver resolves the host capacity and runs the
-- sized tools.
module HostBootstrap.Cluster.Cordon
  ( ResourceBudget (..),
    HostCapacity (..),
    parseQuantity,
    budgetFromResources,
    verifyBudget,
    colimaSizingArgs,
    kindNodeLimits,
    gibibytes,
  )
where

import Data.Char (isDigit)
import qualified Data.Text as T
import HostBootstrap.Config.Schema (Resources (..))
import Numeric.Natural (Natural)

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

-- | Parse a Kubernetes-style quantity to bytes. Accepts binary suffixes
-- (@Ki@, @Mi@, @Gi@, @Ti@, optionally followed by @B@) and decimal suffixes
-- (@K@, @M@, @G@, @T@); a bare number is bytes. Pure.
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

-- | Resolve a skeletal @resources@ block into a canonical byte budget.
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

-- | The @colima start@ arguments that size a per-project VM to the budget.
-- Memory and disk are rounded up to whole GiB (Colima's unit); CPU is the whole
-- core count.
colimaSizingArgs :: Resources -> Either String [String]
colimaSizingArgs r = do
  b <- budgetFromResources r
  pure
    [ "start",
      "--cpu",
      show (budgetCpu b),
      "--memory",
      show (gibibytes (budgetMemoryBytes b)),
      "--disk",
      show (gibibytes (budgetStorageBytes b))
    ]

-- | The kind node resource limits derived from the budget, as a list of
-- @key=value@ descriptors applied to the kind node (cpu cores, memory bytes,
-- storage bytes). kind has no native node sizing, so this is the descriptor the
-- Linux cordon applies to the node container.
kindNodeLimits :: Resources -> Either String [(String, String)]
kindNodeLimits r = do
  b <- budgetFromResources r
  pure
    [ ("cpus", show (budgetCpu b)),
      ("memory", show (budgetMemoryBytes b)),
      ("storage", show (budgetStorageBytes b))
    ]

-- | Bytes to whole gibibytes, rounded up.
gibibytes :: Integer -> Integer
gibibytes bytes = (bytes + gib - 1) `div` gib
  where
    gib = 1024 ^ (3 :: Integer)

showGiB :: Integer -> String
showGiB = show . gibibytes
