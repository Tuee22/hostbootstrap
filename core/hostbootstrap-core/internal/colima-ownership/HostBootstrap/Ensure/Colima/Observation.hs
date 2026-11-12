-- | Plan-independent backend facts, private until the exact owning settlement join.
module HostBootstrap.Ensure.Colima.Observation (
    ColimaWallObservation (..),
    ColimaOwnedObservation (..),
    ExpectedColimaWall (..),
    ColimaWallSettlementObservation (..),
)
where

import Data.Word (Word64)
import HostBootstrap.Cluster.Budget.Observation (WallAcquireObservation)
import HostBootstrap.Ensure.Colima.Backend.Resolver (TrustedAppleToolchain)
import HostBootstrap.Ensure.Colima.Backend.Runner (BackendNamespace)
import HostBootstrap.Reconcile.Error (UnsupportedDetail)

{- | Raw backend facts remain deliberately plan-independent.  A successful
owned observation retains the native backend identities and durable origin record
created by the lock-held backend; settlement against the exact prepared call is still what
introduces plan indices and live authority.
-}
data ColimaWallObservation
    = ColimaOwnedWallObservation ColimaOwnedObservation
    | ColimaUnownedWallObservation WallAcquireObservation
    | ColimaWallOwnershipUnsupported UnsupportedDetail
    deriving (Eq, Show)

data ColimaOwnedObservation = ColimaOwnedObservation
    { ownedToolchain :: TrustedAppleToolchain
    , ownedNamespaceKey :: String
    , ownedNamespace :: BackendNamespace
    , ownedStateRoot :: FilePath
    , ownedRecordPath :: FilePath
    , ownedOwner :: String
    , ownedLineage :: String
    , ownedMachineId :: String
    , ownedContextDigest :: String
    , ownedExpectedWall :: ExpectedColimaWall
    , ownedInvocationDigest :: String
    , ownedSettlementObservation :: ColimaWallSettlementObservation
    }
    deriving (Eq, Show)

data ExpectedColimaWall = ExpectedColimaWall
    { expectedCpus :: Integer
    , expectedMemoryBytes :: Integer
    , expectedDiskBytes :: Integer
    , expectedRootDiskBytes :: Integer
    }
    deriving (Eq, Show)

data ColimaWallSettlementObservation
    = ColimaWallSettlementApplied Word64
    | ColimaWallSettlementAlreadyExact Word64
    deriving (Eq, Show)

