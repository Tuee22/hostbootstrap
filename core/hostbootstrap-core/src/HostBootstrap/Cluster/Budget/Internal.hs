{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Package-private authority kernel for provider-wall acquisition.

The public budget algebra may describe a wall and its partition, but only this
hidden module can join a journal-prepared operation to a successful result from
the closed owning backend.  Keeping the settlement permit here prevents a raw
provider observation from becoming plan-indexed authority by itself.
-}
module HostBootstrap.Cluster.Budget.Internal
  ( ProviderBackend (..),
    ColimaProvider,
    LimaProvider,
    IncusProvider,
    Wsl2Provider,
    DockerNodeProvider,
    BareLinuxProvider,
    ProviderKey (..),
    providerBackend,
    withProviderKeyForBackend,
    ProviderWallReservation (..),
    PreparedProviderWallCall (..),
    samePreparedProviderWallCall,
    WallAcquireObservation (..),
    ProviderWallSettlementPermit,
    withProviderWallSettlementPermitFromObservation,
    withProviderWallSettlementPermit,
  )
where

import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Lifecycle.Prepared
  ( PreparedGate,
    preparedGateAttempt,
    preparedGateFence,
    preparedGateJournalVersion,
    preparedGateOperation,
    preparedGatePlan,
    preparedGateSession,
  )
import HostBootstrap.Reconcile
  ( ConflictDetail (..),
    FailureDetail (..),
    PreparedOperation,
    PreparedPreconditions,
    ProviderResource,
    ReconcileError (..),
    RecoveryDisposition (DoNotRetry),
  )

data ProviderBackend
  = ColimaBackend
  | LimaBackend
  | IncusBackend
  | Wsl2Backend
  | DockerNodeBackend
  | BareLinuxBackend
  deriving (Eq, Show)

data ColimaProvider
data LimaProvider
data IncusProvider
data Wsl2Provider
data DockerNodeProvider
data BareLinuxProvider

-- | Closed provider/type relation.
data ProviderKey provider where
  ColimaProviderKey :: ProviderKey ColimaProvider
  LimaProviderKey :: ProviderKey LimaProvider
  IncusProviderKey :: ProviderKey IncusProvider
  Wsl2ProviderKey :: ProviderKey Wsl2Provider
  DockerNodeProviderKey :: ProviderKey DockerNodeProvider
  BareLinuxProviderKey :: ProviderKey BareLinuxProvider

providerBackend :: ProviderKey provider -> ProviderBackend
providerBackend key =
  case key of
    ColimaProviderKey -> ColimaBackend
    LimaProviderKey -> LimaBackend
    IncusProviderKey -> IncusBackend
    Wsl2ProviderKey -> Wsl2Backend
    DockerNodeProviderKey -> DockerNodeBackend
    BareLinuxProviderKey -> BareLinuxBackend

withProviderKeyForBackend ::
  ProviderBackend ->
  (forall provider. ProviderKey provider -> result) ->
  result
withProviderKeyForBackend backend consume =
  case backend of
    ColimaBackend -> consume ColimaProviderKey
    LimaBackend -> consume LimaProviderKey
    IncusBackend -> consume IncusProviderKey
    Wsl2Backend -> consume Wsl2ProviderKey
    DockerNodeBackend -> consume DockerNodeProviderKey
    BareLinuxBackend -> consume BareLinuxProviderKey

-- | Runtime lineage copied only from the durable prepare gate.
data ProviderWallReservation scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence =
  ProviderWallReservation Text.Text Text.Text Text.Text Word64 Word64 Word64

type role ProviderWallReservation nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

-- | The exact call plus the journal lineage that admitted it.
data PreparedProviderWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence =
  PreparedProviderWallCall
    (ProviderKey provider)
    [String]
    Text.Text
    Text.Text
    Text.Text
    Word64
    Word64
    Word64

type role PreparedProviderWallCall nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

samePreparedProviderWallCall ::
  PreparedProviderWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  PreparedProviderWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  Bool
samePreparedProviderWallCall
  (PreparedProviderWallCall leftProvider leftArgs leftPlan leftOperation leftSession leftFence leftAttempt leftVersion)
  (PreparedProviderWallCall rightProvider rightArgs rightPlan rightOperation rightSession rightFence rightAttempt rightVersion) =
    providerBackend leftProvider == providerBackend rightProvider
      && leftArgs == rightArgs
      && leftPlan == rightPlan
      && leftOperation == rightOperation
      && leftSession == rightSession
      && leftFence == rightFence
      && leftAttempt == rightAttempt
      && leftVersion == rightVersion

-- | Descriptive provider facts.  These constructors are intentionally public;
-- no public function accepts one as settlement authority.
data WallAcquireObservation
  = WallApplied Word64
  | WallAlreadyExact Word64
  | WallMigrated Word64 String
  | WallRefused ConflictDetail
  | WallAcquireFailed FailureDetail
  | WallAcquireUncertain String
  deriving (Eq, Show)

{- | A permit produced only by the package-private owning-backend bridge.

The operation/precondition pair is retained, not projected to descriptive
numbers.  Its four generative journal indices and the provider resource remain
nominal parameters of the permit, while the exact reservation/fence call and
authorized observation are enclosed as values.
-}
data
  ProviderWallSettlementPermit
    scope
    planId
    providerResourceId
    budgetId
    provider
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence
    operationKey
    callDigest
    attempt
    journalVersion
  where
  ProviderWallSettlementPermit ::
    PreparedOperation
      scope
      planId
      providerResourceId
      ProviderResource
      operationKey
      callDigest
      attempt
      journalVersion ->
    PreparedPreconditions
      scope
      planId
      providerResourceId
      ProviderResource
      operationKey
      callDigest
      attempt
      journalVersion ->
    PreparedProviderWallCall
      scope
      planId
      budgetId
      provider
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence ->
    WallAcquireObservation ->
    ProviderWallSettlementPermit
      scope
      planId
      providerResourceId
      budgetId
      provider
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence
      operationKey
      callDigest
      attempt
      journalVersion

type role ProviderWallSettlementPermit nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

{- | Package-private provider-neutral settlement mint.

An owning adapter must first validate its opaque backend result and project
only a successful descriptive observation into this function.  Public code
cannot import this module, so possessing a prepared pair or a raw observation
does not expose a settlement path.
-}
withProviderWallSettlementPermitFromObservation ::
  PreparedProviderWallCall
    scope
    planId
    budgetId
    provider
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence ->
  PreparedGate ->
  PreparedOperation
    scope
    planId
    providerResourceId
    ProviderResource
    operationKey
    callDigest
    attempt
    journalVersion ->
  PreparedPreconditions
    scope
    planId
    providerResourceId
    ProviderResource
    operationKey
    callDigest
    attempt
    journalVersion ->
  WallAcquireObservation ->
  ( ProviderWallSettlementPermit
      scope
      planId
      providerResourceId
      budgetId
      provider
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence
      operationKey
      callDigest
      attempt
      journalVersion ->
    result
  ) ->
  Either ReconcileError result
withProviderWallSettlementPermitFromObservation prepared gate operation preconditions observation consume
  | not (gateMatchesPreparedCall gate prepared) =
      Left
        ( Conflict
            ( ConflictDetail
                (preparedGateOperation gate)
                "the reservation lineage retained by the exact prepared provider call"
                "a different plan, operation, session, fence, attempt, or journal version"
                "use the backend result produced for this journal-prepared call"
            )
        )
  | otherwise =
      case observation of
        WallApplied epoch | epoch > 0 -> successful
        WallAlreadyExact epoch | epoch > 0 -> successful
        WallMigrated _ _ -> nonOwning "migrated"
        WallRefused _ -> nonOwning "conflict"
        WallAcquireFailed _ -> nonOwning "failure"
        WallAcquireUncertain _ -> nonOwning "uncertain"
        _ -> nonOwning "invalid epoch"
  where
    successful =
      Right
        ( consume
            (ProviderWallSettlementPermit operation preconditions prepared observation)
        )
    nonOwning branch =
      Left
        ( Failure
            ( FailureDetail
                "settle provider wall"
                ("the owning provider adapter returned a non-owning " <> Text.pack branch <> " observation")
                DoNotRetry
            )
        )

gateMatchesPreparedCall ::
  PreparedGate ->
  PreparedProviderWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  Bool
gateMatchesPreparedCall
  gate
  (PreparedProviderWallCall _provider _args plan operation session fenceValue attemptValue journalVersion) =
    preparedGatePlan gate == plan
      && preparedGateOperation gate == operation
      && preparedGateSession gate == session
      && preparedGateFence gate == fenceValue
      && preparedGateAttempt gate == attemptValue
      && preparedGateJournalVersion gate == journalVersion
      && not (Text.null session)
      && fenceValue > 0
      && attemptValue > 0
      && journalVersion > 0

withProviderWallSettlementPermit ::
  ProviderWallSettlementPermit
    scope
    planId
    providerResourceId
    budgetId
    provider
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence
    operationKey
    callDigest
    attempt
    journalVersion ->
  ( PreparedProviderWallCall
      scope
      planId
      budgetId
      provider
      capabilityId
      wallSpecId
      workloadSetId
      partitionId
      reservationId
      fence ->
    WallAcquireObservation ->
    result
  ) ->
  result
withProviderWallSettlementPermit
  (ProviderWallSettlementPermit _operation _preconditions prepared observation)
  consume = consume prepared observation
