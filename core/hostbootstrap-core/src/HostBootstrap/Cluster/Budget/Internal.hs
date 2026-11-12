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
module HostBootstrap.Cluster.Budget.Internal (
    ProviderBackend (..),
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
    ProviderWallAuthority (..),
    PreparedStorageWallCall (..),
    StorageWallObservation (..),
    StorageWallSettlementPermit,
    withStorageWallSettlementPermitFromObservation,
    withStorageWallSettlementPermit,
    samePreparedStorageWallCall,
    PreparedProviderWallCall (..),
    samePreparedProviderWallCall,
    WallAcquireObservation (..),
    SettledWallObservation (..),
    ProviderWallSettlementPermit,
    withProviderWallSettlementPermitFromObservation,
    withProviderWallSettlementPermit,
)
where

import qualified Data.Text as Text
import Data.Word (Word64)
import qualified HostBootstrap.Cluster.Cordon.Foundation as Cordon
import HostBootstrap.Cluster.Budget.Observation (WallAcquireObservation (..))
import HostBootstrap.Lifecycle.Prepared (
    PreparedGate,
    preparedGateAttempt,
    preparedGateFence,
    preparedGateJournalVersion,
    preparedGateOperation,
    preparedGatePlan,
    preparedGateSession,
 )
import HostBootstrap.Reconcile (
    ConflictDetail (..),
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
data ProviderWallReservation scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence
    = ProviderWallReservation Text.Text Text.Text Text.Text Word64 Word64 Word64

type role ProviderWallReservation nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

-- | The live provider wall's generative epoch and fence.
data ProviderWallAuthority scope planId provider wallSpecId wallEpoch fence
    = ProviderWallAuthority Word64 Word64

type role ProviderWallAuthority nominal nominal nominal nominal nominal nominal

-- | The exact storage invocation and its journal reservation.
data PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence
    = PreparedStorageWallCall Cordon.StorageCordonMechanism [String] Integer
        (ProviderWallReservation scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence)

type role PreparedStorageWallCall nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

data StorageWallObservation
    = StorageWallApplied Word64 Integer
    | StorageWallAlreadyExact Word64 Integer
    | StorageWallRefused ConflictDetail
    | StorageWallFailed FailureDetail
    | StorageWallUncertain String
    deriving (Eq, Show)

data StorageWallSettlementPermit scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence wallEpoch
    = StorageWallSettlementPermit
        (PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence)
        (ProviderWallAuthority scope planId provider wallSpecId wallEpoch fence)
        StorageWallObservation

type role StorageWallSettlementPermit nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

samePreparedStorageWallCall ::
    PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
    PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
    Bool
samePreparedStorageWallCall
    (PreparedStorageWallCall leftMechanism leftArgs leftCeiling (ProviderWallReservation lp lo ls lf la lv))
    (PreparedStorageWallCall rightMechanism rightArgs rightCeiling (ProviderWallReservation rp ro rs rf ra rv)) =
        leftMechanism == rightMechanism && leftArgs == rightArgs && leftCeiling == rightCeiling
            && lp == rp && lo == ro && ls == rs && lf == rf && la == ra && lv == rv

withStorageWallSettlementPermitFromObservation ::
    PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
    PreparedGate ->
    ProviderWallAuthority scope planId provider wallSpecId wallEpoch fence ->
    StorageWallObservation ->
    (StorageWallSettlementPermit scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence wallEpoch -> result) ->
    Either ReconcileError result
withStorageWallSettlementPermitFromObservation prepared@(PreparedStorageWallCall _ _ _ (ProviderWallReservation plan operation session fence attempt version)) gate authority@(ProviderWallAuthority _ wallFence) observation consume
    | preparedGatePlan gate /= plan || preparedGateOperation gate /= operation || preparedGateSession gate /= session
        || preparedGateFence gate /= fence || preparedGateAttempt gate /= attempt || preparedGateJournalVersion gate /= version
        || Text.null session || fence == 0 || attempt == 0 || version == 0 || wallFence /= fence =
        Left (Conflict (ConflictDetail (preparedGateOperation gate) "the prepared storage call and live wall fence" "a different journal lineage or wall fence" "use the exact prepared call and live wall"))
    | otherwise = Right (consume (StorageWallSettlementPermit prepared authority observation))

withStorageWallSettlementPermit ::
    StorageWallSettlementPermit scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence wallEpoch ->
    (PreparedStorageWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
     ProviderWallAuthority scope planId provider wallSpecId wallEpoch fence -> StorageWallObservation -> result) ->
    result
withStorageWallSettlementPermit (StorageWallSettlementPermit prepared authority observation) consume = consume prepared authority observation

-- | The exact call plus the journal lineage that admitted it.
data PreparedProviderWallCall scope planId budgetId provider capabilityId wallSpecId workloadSetId partitionId reservationId fence
    = PreparedProviderWallCall
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

-- | Successful observations admitted only with a positive epoch by the mint.
data SettledWallObservation
    = SettledApplied Word64
    | SettledAlreadyExact Word64
    | SettledMigrated Word64 String

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
        SettledWallObservation ->
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
            WallApplied epoch | epoch > 0 -> successful (SettledApplied epoch)
            WallAlreadyExact epoch | epoch > 0 -> successful (SettledAlreadyExact epoch)
            WallMigrated epoch receipt | epoch > 0 -> successful (SettledMigrated epoch receipt)
            WallRefused _ -> nonOwning "conflict"
            WallAcquireFailed _ -> nonOwning "failure"
            WallAcquireUncertain _ -> nonOwning "uncertain"
            WallApplied _ -> nonOwning "invalid epoch"
            WallAlreadyExact _ -> nonOwning "invalid epoch"
            WallMigrated _ _ -> nonOwning "invalid epoch"
  where
    successful settled =
        Right
            ( consume
                (ProviderWallSettlementPermit operation preconditions prepared settled)
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
      SettledWallObservation ->
      result
    ) ->
    result
withProviderWallSettlementPermit
    (ProviderWallSettlementPermit _operation _preconditions prepared observation)
    consume = consume prepared observation
