{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RoleAnnotations #-}

{- | Total polling plus sealed, resource-indexed readiness evidence.

The ordinary polling functions return payloads or 'ObservedReady'.  The latter is
deliberately non-authorizing compatibility evidence for lifecycle code that has
not yet entered a generative plan.  Indexed 'Ready' observations are available
only through the closed 'BackendProbeKey' relation and retain scope, plan,
resource identity, resource type, and dependency type indices, together with
the generation, phase version, and observation version reported by the backend.
Holding an observation does not authorize an effect.
-}
module HostBootstrap.Readiness (
    -- * Validated delay and policy
    Micros,
    microsValue,
    seconds,
    PollPolicy,
    PollPolicyError (..),
    mkPollPolicy,
    withAttempts,
    pollAttempts,
    pollDelay,
    pollSchedule,

    -- * Named policies
    rolloutPoll,
    pushPoll,
    reachPoll,
    vmBootPoll,
    networkPoll,
    dockerPoll,
    nodePoll,

    -- * Total observations
    ProbeResult (..),
    ProbeConflict (..),
    ProbeFailure (..),
    PollError (..),
    renderPollError,
    Decision (..),
    pollStep,
    pollUntilReady,
    pollUntilReadyWith,

    -- * Non-authorizing compatibility observation
    ObservedReady,
    awaitObservedReady,
    awaitObservedReadyWith,

    -- * Plan/resource-indexed readiness
    BackendProbeKey (..),
    DurableShareReady,
    BackendReady (..),
    ProbeVersionError (..),
    Probe,
    Ready,
    readyGeneration,
    readyPhaseVersion,
    readyObservationVersion,
    planDependencyProbe,
    awaitPlanReady,
    awaitPlanReadyWith,
)
where

import Control.Concurrent (threadDelay)
import Data.Int (Int64)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Readiness.Kernel (
    BackendProbeKey (..),
    BackendReady (..),
    DurableShareReady,
    ProbeConflict (..),
    ProbeFailure (..),
    ProbeResult (..),
 )
import qualified HostBootstrap.Readiness.Kernel as ProbeKernel
import HostBootstrap.Reconcile (
    ConflictDetail (ConflictDetail),
    DependencyProbe,
    FailureDetail (FailureDetail),
    Managed,
    ReconcileError (Conflict, Failure),
    RecoveryDisposition (ReprobeBeforeRetry),
    ResourceHandle,
    dependencyProbe,
    resourceHandleGeneration,
    resourceHandleKey,
    resourceHandleObservationVersion,
 )
import Numeric.Natural (Natural)

-- | Microseconds accepted by 'threadDelay'. The constructor is private.
newtype Micros = Micros Int
    deriving (Eq, Ord, Show)

microsValue :: Micros -> Int
microsValue (Micros value) = value

-- | Validate a whole number of seconds. Negative and overflowing values fail.
seconds :: Integer -> Either PollPolicyError Micros
seconds value
    | value < 0 = Left (NegativeDelay value)
    | value > fromIntegral (maxBound :: Int) `div` 1000000 =
        Left (DelayOverflow value)
    | otherwise = Right (Micros (fromInteger value * 1000000))

data PollPolicyError
    = ZeroAttempts
    | AttemptsTooLarge Natural
    | NegativeDelay Integer
    | DelayOverflow Integer
    | TotalDurationOverflow
    | TotalDurationTooLarge Integer
    deriving (Eq, Show)

data PollPolicy = PollPolicy
    { policyAttempts :: Natural
    , policyDelay :: Micros
    }
    deriving (Eq, Show)

-- A deliberately generous upper bound which keeps accidental multi-day polling
-- out of command construction while preserving every named policy.
maxAttempts :: Natural
maxAttempts = 1000000

maxPollMicros :: Integer
maxPollMicros = 24 * 60 * 60 * 1000000

mkPollPolicy :: Natural -> Micros -> Either PollPolicyError PollPolicy
mkPollPolicy attempts delay
    | attempts == 0 = Left ZeroAttempts
    | attempts > maxAttempts = Left (AttemptsTooLarge attempts)
    | total > fromIntegral (maxBound :: Int64) = Left TotalDurationOverflow
    | total > maxPollMicros = Left (TotalDurationTooLarge total)
    | otherwise = Right (PollPolicy attempts delay)
  where
    total = toInteger (attempts - 1) * toInteger (microsValue delay)

withAttempts :: PollPolicy -> Natural -> Either PollPolicyError PollPolicy
withAttempts policy attempts = mkPollPolicy attempts (policyDelay policy)

pollAttempts :: PollPolicy -> Natural
pollAttempts = policyAttempts

pollDelay :: PollPolicy -> Micros
pollDelay = policyDelay

pollSchedule :: PollPolicy -> [Micros]
pollSchedule policy =
    replicate (fromIntegral (policyAttempts policy - 1)) (policyDelay policy)

rolloutPoll, pushPoll, reachPoll, vmBootPoll, networkPoll, dockerPoll, nodePoll :: PollPolicy
rolloutPoll = PollPolicy 6 (Micros 5000000)
pushPoll = PollPolicy 4 (Micros 5000000)
reachPoll = PollPolicy 24 (Micros 5000000)
vmBootPoll = PollPolicy 60 (Micros 2000000)
networkPoll = PollPolicy 20 (Micros 3000000)
dockerPoll = PollPolicy 30 (Micros 2000000)
nodePoll = PollPolicy 10 (Micros 3000000)

data PollError
    = PollTimeout String String
    | PollUnavailable String String
    | PollConflict String ProbeConflict
    | PollFailed String ProbeFailure
    | PollInvalidReady String ProbeVersionError
    deriving (Eq, Show)

renderPollError :: PollError -> String
renderPollError err = case err of
    PollTimeout label lastObservation ->
        label ++ ": did not become ready within the poll budget (" ++ lastObservation ++ ")"
    PollUnavailable label reason -> label ++ ": unavailable: " ++ reason
    PollConflict label conflict ->
        label
            ++ ": conflict: expected "
            ++ conflictExpected conflict
            ++ ", observed "
            ++ conflictObserved conflict
            ++ "; "
            ++ conflictRemedy conflict
    PollFailed label failure ->
        label ++ ": " ++ failedOperation failure ++ ": " ++ failureCause failure
    PollInvalidReady label failure ->
        label ++ ": invalid backend readiness: " ++ case failure of
            ZeroProbeGeneration -> "generation must be positive"
            ZeroProbePhaseVersion -> "phase version must be positive"
            ZeroProbeObservationVersion -> "observation version must be positive"

data Decision a
    = Yield a
    | Retry Micros
    | GiveUp PollError
    deriving (Eq, Show)

pollStep :: PollPolicy -> String -> Natural -> ProbeResult a -> Decision a
pollStep _ _ _ (ProbeReady value) = Yield value
pollStep _ label _ (Unavailable reason) =
    GiveUp (PollUnavailable label reason)
pollStep _ label _ (ProbeConflicted conflict) =
    GiveUp (PollConflict label conflict)
pollStep _ label _ (Failed failure) =
    GiveUp (PollFailed label failure)
pollStep policy label attempt (NotReady observation)
    | attempt + 1 >= policyAttempts policy =
        GiveUp (PollTimeout label observation)
    | otherwise = Retry (policyDelay policy)

{- | Run the bounded polling loop. Backend actions classify expected observation
failures as 'ProbeResult' values; exceptions from those actions or recovery,
including cancellation and programming failures, propagate to the caller.
-}
pollUntilReadyWith ::
    PollPolicy ->
    String ->
    (HostConfig -> IO ()) ->
    (HostConfig -> IO (ProbeResult a)) ->
    HostConfig ->
    IO (Either PollError a)
pollUntilReadyWith policy label recover runProbe cfg = go 0
  where
    go attempt = do
        observation <- runProbe cfg
        case pollStep policy label attempt observation of
            Yield value -> pure (Right value)
            GiveUp err -> pure (Left err)
            Retry delay -> recover cfg >> threadDelay (microsValue delay) >> go (attempt + 1)

pollUntilReady ::
    PollPolicy ->
    String ->
    (HostConfig -> IO (ProbeResult a)) ->
    HostConfig ->
    IO (Either PollError a)
pollUntilReady policy label =
    pollUntilReadyWith policy label (const (pure ()))

-- | A successful observation that is not lifecycle authority.
data ObservedReady dependency = ObservedReady

awaitObservedReady ::
    PollPolicy ->
    String ->
    (HostConfig -> IO (ProbeResult a)) ->
    HostConfig ->
    IO (Either PollError (ObservedReady dependency))
awaitObservedReady policy label =
    awaitObservedReadyWith policy label (const (pure ()))

awaitObservedReadyWith ::
    PollPolicy ->
    String ->
    (HostConfig -> IO ()) ->
    (HostConfig -> IO (ProbeResult a)) ->
    HostConfig ->
    IO (Either PollError (ObservedReady dependency))
awaitObservedReadyWith policy label recover runProbe cfg =
    fmap (const ObservedReady)
        <$> pollUntilReadyWith policy label recover runProbe cfg

{- | A backend-owned probe specialized to the host configuration. Its six
identity indices retain the private kernel's nominal roles.
-}
type Probe scope planId id resource dependency probeId a =
    ProbeKernel.Probe scope planId id resource dependency probeId HostConfig a

data ProbeVersionError
    = ZeroProbeGeneration
    | ZeroProbePhaseVersion
    | ZeroProbeObservationVersion
    deriving (Eq, Show)

data Ready scope planId id resource dependency = Ready Word64 Word64 Word64

type role Ready nominal nominal nominal nominal nominal

readyGeneration :: Ready scope planId id resource dependency -> Word64
readyGeneration (Ready generation _ _) = generation

readyPhaseVersion :: Ready scope planId id resource dependency -> Word64
readyPhaseVersion (Ready _ phaseVersion _) = phaseVersion

readyObservationVersion :: Ready scope planId id resource dependency -> Word64
readyObservationVersion (Ready _ _ observationVersion) = observationVersion

{- | The plan-owned dependency probe for one managed resource (§ CC).

The probe is /not/ run here: it is stored beside the managed handle in the
plan's dependency snapshot and run by 'HostBootstrap.Reconcile.withOperationPreconditions'
at prepare time. Each run polls the supplied backend observation function and
then rechecks its freshly reported versions against the managed handle it is
registered for — the shared indices reject another plan or resource at compile
time, and equality of generation and observation version rejects stale evidence.
-}
planDependencyProbe ::
    PollPolicy ->
    String ->
    ResourceHandle scope planId id resource Managed phase ->
    Probe scope planId id resource dependency probeId a ->
    HostConfig ->
    DependencyProbe scope planId id resource
planDependencyProbe policy label handle probe cfg =
    dependencyProbe $ do
        outcome <- awaitPlanReady policy label probe cfg
        pure $ case outcome of
            Left err ->
                Left
                    ( Failure
                        ( FailureDetail
                            ("probe dependency " <> Text.pack label)
                            (Text.pack (renderPollError err))
                            ReprobeBeforeRetry
                        )
                    )
            Right ready -> readyPhaseVersionFor handle ready

{- | Recheck a freshly observed 'Ready' against the managed handle it was
registered for, and yield the phase version the sealed observation carries.
-}
readyPhaseVersionFor ::
    ResourceHandle scope planId id resource Managed phase ->
    Ready scope planId id resource dependency ->
    Either ReconcileError Word64
readyPhaseVersionFor handle ready
    | readyGeneration ready /= resourceHandleGeneration handle =
        Left
            ( Conflict
                ( ConflictDetail
                    (resourceHandleKey handle)
                    ("generation=" <> Text.pack (show (resourceHandleGeneration handle)))
                    ("ready generation=" <> Text.pack (show (readyGeneration ready)))
                    "reprobe readiness for the exact managed generation"
                )
            )
    | readyObservationVersion ready /= resourceHandleObservationVersion handle =
        Left
            ( Conflict
                ( ConflictDetail
                    (resourceHandleKey handle)
                    ("observation version=" <> Text.pack (show (resourceHandleObservationVersion handle)))
                    ("ready observation version=" <> Text.pack (show (readyObservationVersion ready)))
                    "reprobe the dependency and readiness from one snapshot"
                )
            )
    | otherwise = Right (readyPhaseVersion ready)

awaitPlanReady ::
    PollPolicy ->
    String ->
    Probe scope planId id resource dependency probeId a ->
    HostConfig ->
    IO (Either PollError (Ready scope planId id resource dependency))
awaitPlanReady policy label =
    awaitPlanReadyWith policy label (const (pure ()))

{- | Poll for backend-reported readiness and refuse any zero version before
constructing the indexed observation.
-}
awaitPlanReadyWith ::
    PollPolicy ->
    String ->
    (HostConfig -> IO ()) ->
    Probe scope planId id resource dependency probeId a ->
    HostConfig ->
    IO (Either PollError (Ready scope planId id resource dependency))
awaitPlanReadyWith policy label recover probe cfg = do
    outcome <- pollUntilReadyWith policy label recover (ProbeKernel.observeBackendProbe probe) cfg
    pure $ case outcome of
        Left err -> Left err
        Right (BackendReady generation phaseVersion observationVersion _)
            | generation == 0 -> Left (PollInvalidReady label ZeroProbeGeneration)
            | phaseVersion == 0 -> Left (PollInvalidReady label ZeroProbePhaseVersion)
            | observationVersion == 0 -> Left (PollInvalidReady label ZeroProbeObservationVersion)
            | otherwise -> Right (Ready generation phaseVersion observationVersion)
