-- | Descriptive reconciler refusals shared by private policy and public consumers.
-- These values carry no lifecycle or effect authority.
module HostBootstrap.Reconcile.Error (
    ReconcileError (..),
    ConflictDetail (..),
    SafetyDetail (..),
    UnsupportedDetail (..),
    FailureDetail (..),
    RecoveryDisposition (..),
)
where

import Data.Text (Text)

data ConflictDetail = ConflictDetail
    { conflictResource :: Text
    , conflictExpected :: Text
    , conflictObserved :: Text
    , conflictRemedy :: Text
    }
    deriving (Eq, Show)

data SafetyDetail = SafetyDetail
    { refusedOperation :: Text
    , refusalReason :: Text
    }
    deriving (Eq, Show)

data UnsupportedDetail = UnsupportedDetail
    { unsupportedOperation :: Text
    , unsupportedReason :: Text
    }
    deriving (Eq, Show)

data RecoveryDisposition
    = ReprobeBeforeRetry
    | RetrySameOperationKeyAfterFencing
    | OperatorResolutionRequired
    | DoNotRetry
    deriving (Eq, Show)

data FailureDetail = FailureDetail
    { failedOperation :: Text
    , failureCause :: Text
    , recoveryDisposition :: RecoveryDisposition
    }
    deriving (Eq, Show)

data ReconcileError
    = Conflict ConflictDetail
    | SafetyRefusal SafetyDetail
    | Unsupported UnsupportedDetail
    | Failure FailureDetail
    deriving (Eq, Show)

