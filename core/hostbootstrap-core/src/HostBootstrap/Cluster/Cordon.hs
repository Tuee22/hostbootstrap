{-# LANGUAGE OverloadedRecordDot #-}

{- | Configuration adapters for the lower cordon foundation.

The canonical budget, capacity, storage-policy, and provider-rendering
vocabulary lives in "HostBootstrap.Cluster.Cordon.Foundation".  This facade
retains the public @ResourceEnvelope@ and generated-vocabulary APIs by
parsing descriptive configuration once and delegating to that lower module.
-}
module HostBootstrap.Cluster.Cordon (
    ResourceBudget,
    mkResourceBudget,
    budgetCpu,
    budgetMemoryBytes,
    budgetStorageBytes,
    HostCapacity (..),
    CapacityReadSource (..),
    CapacityReadPlan (..),
    StorageCordonTarget (..),
    StorageCordonMechanism (..),
    StorageCordonUnsupportedReason (..),
    StorageCordonResult (..),
    capacityReadPlan,
    storageCordonPolicy,
    Overflow (..),
    parseQuantity,
    budgetFromResources,
    budgetFromVocabResources,
    verifyBudget,
    verifyHostBudget,
    hostMemoryReserveBytes,
    preflightBudget,
    preflightHostBudget,
    fitsBudget,
    colimaSizingArgs,
    limaSizingArgs,
    wsl2SizingArgs,
    managedWslIdleTimeoutHours,
    managedWslIdleTimeoutMillis,
    kindNodeCordonArgs,
    kindNodeCordonArgsFor,
    incusSizingArgs,
    resolveHostCapacity,
    parseDfAvailableKBytes,
    gibibytes,
)
where

import Data.Text (Text)
import qualified HostBootstrap.Cluster.Cordon.Foundation as Foundation
import HostBootstrap.Cluster.Cordon.Foundation
    ( CapacityReadPlan (..),
      CapacityReadSource (..),
      HostCapacity (..),
      ResourceBudget,
      StorageCordonMechanism (..),
      StorageCordonResult (..),
      StorageCordonTarget (..),
      StorageCordonUnsupportedReason (..),
      budgetCpu,
      budgetMemoryBytes,
      budgetStorageBytes,
      capacityReadPlan,
      gibibytes,
      hostMemoryReserveBytes,
      managedWslIdleTimeoutHours,
      managedWslIdleTimeoutMillis,
      mkResourceBudget,
      parseDfAvailableKBytes,
      parseQuantity,
      resolveHostCapacity,
      storageCordonPolicy,
      verifyBudget,
      verifyHostBudget,
    )
import qualified HostBootstrap.Config.Vocab as Vocab
import HostBootstrap.Context (ResourceEnvelope (..))
import Numeric.Natural (Natural)

{- | A workload overflow in the generated vocabulary's units.  This descriptive
adapter result grants no plan or mutation authority.
-}
data Overflow = Overflow
    { overflowDimension :: String,
      overflowWanted :: Natural,
      overflowAllowed :: Natural
    }
    deriving (Eq, Show)

-- | Resolve a descriptive resource envelope into one canonical byte budget.
budgetFromResources :: ResourceEnvelope -> Either String ResourceBudget
budgetFromResources resources =
    budgetFromFields resources.cpu resources.memory resources.storage

-- | Resolve the generated configuration vocabulary into one canonical budget.
budgetFromVocabResources :: Vocab.Resources -> Either String ResourceBudget
budgetFromVocabResources resources =
    budgetFromFields resources.cpu resources.memory resources.storage

budgetFromFields :: Natural -> Text -> Text -> Either String ResourceBudget
budgetFromFields cores memoryQuantity storageQuantity = do
    memoryBytes <- parseQuantity memoryQuantity
    storageBytes <- parseQuantity storageQuantity
    mkResourceBudget cores memoryBytes storageBytes

-- | Parse an envelope, then apply the reserve-free capacity fit check.
preflightBudget :: ResourceEnvelope -> HostCapacity -> Either String ()
preflightBudget resources capacity = do
    budget <- budgetFromResources resources
    verifyBudget budget capacity

-- | Parse an envelope, then apply the metal host fit check with its reserve.
preflightHostBudget :: ResourceEnvelope -> HostCapacity -> Either String ()
preflightHostBudget resources capacity = do
    budget <- budgetFromResources resources
    verifyHostBudget budget capacity

{- | Compatibility calculation over the generated Dhall vocabulary.  Exact,
plan-indexed workload admission lives in "HostBootstrap.Cluster.Budget".
-}
fitsBudget :: Vocab.Budget -> [Vocab.PodResources] -> Either Overflow ()
fitsBudget budget pods
    | wantedCpu > budget.cpu = Left (Overflow "cpu" wantedCpu budget.cpu)
    | wantedMemory > budget.memory = Left (Overflow "memory" wantedMemory budget.memory)
    | otherwise = Right ()
  where
    wantedCpu = foldl' (\total pod -> total + pod.replicas * pod.cpuLimit) 0 pods
    wantedMemory = foldl' (\total pod -> total + pod.replicas * pod.memoryLimit) 0 pods

-- | Parse a descriptive envelope and render a Colima wall.
colimaSizingArgs :: String -> ResourceEnvelope -> Either String [String]
colimaSizingArgs project resources =
    budgetFromResources resources >>= Foundation.colimaSizingArgsForBudget project

-- | Parse a descriptive envelope and render a Lima wall.
limaSizingArgs :: ResourceEnvelope -> Either String [String]
limaSizingArgs resources =
    budgetFromResources resources >>= Foundation.limaSizingArgsForBudget

-- | Parse a descriptive envelope and render a WSL2 wall.
wsl2SizingArgs :: ResourceEnvelope -> Either String [String]
wsl2SizingArgs resources =
    budgetFromResources resources >>= Foundation.wsl2SizingArgsForBudget

-- | Render the control-plane container wall for a cluster envelope.
kindNodeCordonArgs :: String -> ResourceEnvelope -> Either String [String]
kindNodeCordonArgs clusterName =
    kindNodeCordonArgsFor (clusterName ++ "-control-plane")

-- | Parse an envelope and render one explicitly named node-container wall.
kindNodeCordonArgsFor :: String -> ResourceEnvelope -> Either String [String]
kindNodeCordonArgsFor containerName resources =
    budgetFromResources resources
        >>= Foundation.kindNodeCordonArgsForBudget containerName

-- | Parse a descriptive envelope and render an Incus wall.
incusSizingArgs :: ResourceEnvelope -> Either String [String]
incusSizingArgs resources =
    budgetFromResources resources >>= Foundation.incusSizingArgsForBudget
