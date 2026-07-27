{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Total polling plus sealed, resource-indexed readiness evidence.

The ordinary polling functions return payloads or 'ObservedReady'.  The latter is
deliberately non-authorizing compatibility evidence for lifecycle code that has
not yet entered a generative plan.  Authoritative 'Ready' values are available
only through the closed 'BackendProbeKey' relation and retain scope, plan,
resource identity, resource type, dependency type, generation, phase, and
observation version indices.
-}
module HostBootstrap.Readiness
  ( -- * Validated delay and policy
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
    drivePure,

    -- * Non-authorizing compatibility observation
    ObservedReady,
    awaitObservedReady,
    awaitObservedReadyWith,

    -- * Plan/resource-indexed readiness
    BackendProbeKey (..),
    DurableShareReady,
    ProbeConstructionError (..),
    Probe,
    withBackendProbe,
    Ready,
    readyGeneration,
    readyPhaseVersion,
    readyObservationVersion,
    dependencyObservationFromReady,
    awaitPlanReady,
    awaitPlanReadyWith,
  )
where

import Control.Concurrent (threadDelay)
import Data.Int (Int64)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Reconcile
  ( ClusterResource,
    ConflictDetail (ConflictDetail),
    DependencyObservation,
    DockerResource,
    DurableShareResource,
    FailureDetail (FailureDetail),
    Managed,
    MinioResource,
    PlannedResource,
    ProviderResource,
    ReconcileError (Conflict, Failure),
    RecoveryDisposition (DoNotRetry),
    ResourceHandle,
    RegistryResource,
    dependencyObservation,
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
  { policyAttempts :: Natural,
    policyDelay :: Micros
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

namedPolicy :: Natural -> Integer -> PollPolicy
namedPolicy attempts delaySeconds =
  case seconds delaySeconds >>= mkPollPolicy attempts of
    Right policy -> policy
    Left err -> error ("invalid built-in poll policy: " ++ show err)

rolloutPoll, pushPoll, reachPoll, vmBootPoll, networkPoll, dockerPoll, nodePoll :: PollPolicy
rolloutPoll = namedPolicy 6 5
pushPoll = namedPolicy 4 5
reachPoll = namedPolicy 24 5
vmBootPoll = namedPolicy 60 2
networkPoll = namedPolicy 20 3
dockerPoll = namedPolicy 30 2
nodePoll = namedPolicy 10 3

data ProbeConflict = ProbeConflict
  { conflictExpected :: String,
    conflictObserved :: String,
    conflictRemedy :: String
  }
  deriving (Eq, Show)

data ProbeFailure = ProbeFailure
  { failedOperation :: String,
    failureCause :: String
  }
  deriving (Eq, Show)

-- | Exhaustive probe observation. Only 'ProbeReady' is readiness.
data ProbeResult a
  = ProbeReady a
  | NotReady String
  | Unavailable String
  | ProbeConflicted ProbeConflict
  | Failed ProbeFailure
  deriving (Eq, Show)

data PollError
  = PollTimeout String String
  | PollUnavailable String String
  | PollConflict String ProbeConflict
  | PollFailed String ProbeFailure
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

drivePure :: PollPolicy -> String -> [ProbeResult a] -> (Either PollError a, [Micros])
drivePure policy label = go 0 []
  where
    go _ delays [] =
      (Left (PollTimeout label "probe sequence ended"), reverse delays)
    go attempt delays (result : rest) =
      case pollStep policy label attempt result of
        Yield value -> (Right value, reverse delays)
        GiveUp err -> (Left err, reverse delays)
        Retry delay -> go (attempt + 1) (delay : delays) rest

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

-- Closed resource/dependency pairs. A caller can inject observations for tests,
-- but cannot choose an unrelated dependency phantom for a key.
data BackendProbeKey resource dependency where
  ProviderRespondingProbe :: BackendProbeKey ProviderResource ProviderResponding
  ProviderNetworkProbe :: BackendProbeKey ProviderResource ProviderNetworkReady
  DurableShareProbe :: BackendProbeKey DurableShareResource DurableShareReady
  DockerDaemonProbe :: BackendProbeKey DockerResource DockerDaemonReady
  MinioRolloutProbe :: BackendProbeKey MinioResource MinioRolloutReady
  RegistryServingProbe :: BackendProbeKey RegistryResource RegistryReady
  ClusterApiProbe :: BackendProbeKey ClusterResource ClusterApiReady
  GpuPluginProbe :: BackendProbeKey ClusterResource GpuPluginReady

data ProviderResponding
data ProviderNetworkReady
data DurableShareReady
data DockerDaemonReady
data MinioRolloutReady
data RegistryReady
data ClusterApiReady
data GpuPluginReady

data Probe scope planId id resource dependency probeId a =
  Probe
    (HostConfig -> IO (ProbeResult a))
    Word64
    Word64
    Word64

data ProbeConstructionError
  = ZeroProbeGeneration
  | ZeroProbePhaseVersion
  | ZeroProbeObservationVersion
  deriving (Eq, Show)

-- | Inject a backend observation under a closed resource/dependency key. The
-- fresh @probeId@ cannot escape except through the continuation.
withBackendProbe ::
  BackendProbeKey resource dependency ->
  PlannedResource scope planId id resource frame ->
  Word64 ->
  Word64 ->
  Word64 ->
  (HostConfig -> IO (ProbeResult a)) ->
  (forall probeId. Probe scope planId id resource dependency probeId a -> r) ->
  Either ProbeConstructionError r
withBackendProbe _ _planned generation phaseVersion observationVersion runProbe consume
  | generation == 0 = Left ZeroProbeGeneration
  | phaseVersion == 0 = Left ZeroProbePhaseVersion
  | observationVersion == 0 = Left ZeroProbeObservationVersion
  | otherwise =
      Right (consume (Probe runProbe generation phaseVersion observationVersion))

data Ready scope planId id resource dependency = Ready Word64 Word64 Word64

readyGeneration :: Ready scope planId id resource dependency -> Word64
readyGeneration (Ready generation _ _) = generation

readyPhaseVersion :: Ready scope planId id resource dependency -> Word64
readyPhaseVersion (Ready _ phaseVersion _) = phaseVersion

readyObservationVersion :: Ready scope planId id resource dependency -> Word64
readyObservationVersion (Ready _ _ observationVersion) = observationVersion

{- | Bind readiness to the exact managed dependency snapshot consumed by a
prepared operation.  The shared indices reject another plan/resource at compile
time; equality of generation and observation version rejects stale evidence.
-}
dependencyObservationFromReady ::
  ResourceHandle scope planId id resource Managed phase ->
  Ready scope planId id resource dependency ->
  Either
    ReconcileError
    (DependencyObservation scope planId id resource)
dependencyObservationFromReady handle ready
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
  | readyPhaseVersion ready == 0 =
      Left
        ( Failure
            (FailureDetail "bind readiness" "phase version must be positive" DoNotRetry)
        )
  | otherwise = dependencyObservation handle (readyPhaseVersion ready)

awaitPlanReady ::
  PollPolicy ->
  String ->
  Probe scope planId id resource dependency probeId a ->
  HostConfig ->
  IO (Either PollError (Ready scope planId id resource dependency))
awaitPlanReady policy label =
  awaitPlanReadyWith policy label (const (pure ()))

awaitPlanReadyWith ::
  PollPolicy ->
  String ->
  (HostConfig -> IO ()) ->
  Probe scope planId id resource dependency probeId a ->
  HostConfig ->
  IO (Either PollError (Ready scope planId id resource dependency))
awaitPlanReadyWith policy label recover (Probe runProbe generation phaseVersion observationVersion) cfg =
  fmap (const (Ready generation phaseVersion observationVersion))
    <$> pollUntilReadyWith policy label recover runProbe cfg
