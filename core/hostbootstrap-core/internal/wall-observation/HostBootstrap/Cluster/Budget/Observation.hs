-- | Shared descriptive provider facts, without settlement authority.
module HostBootstrap.Cluster.Budget.Observation (
    WallAcquireObservation (..),
)
where

import Data.Word (Word64)
import HostBootstrap.Reconcile.Error (ConflictDetail, FailureDetail)

{- | Descriptive provider facts.  These constructors are intentionally public;
no public function accepts one as settlement authority.
-}
data WallAcquireObservation
    = WallApplied Word64
    | WallAlreadyExact Word64
    | WallMigrated Word64 String
    | WallRefused ConflictDetail
    | WallAcquireFailed FailureDetail
    | WallAcquireUncertain String
    deriving (Eq, Show)

