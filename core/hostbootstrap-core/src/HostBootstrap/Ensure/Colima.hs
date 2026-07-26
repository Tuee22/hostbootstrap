{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The prepared, per-project Colima provider wall used by direct Apple Docker
lanes.

The former generic reconciler probed and started Colima's mutable @default@
profile without a project identity or budget.  This module has no such
fallback.  A profile is derived from the validated binary context under an
exact lifecycle plan, and the only start argv accepted by the live adapter is
the opaque prepared Colima wall call produced from Phase 9's admitted budget,
partition, and journal-before-call reservation.

The adapter observes @colima list --json@ before mutation.  An exact running
profile is a no-op, an exact stopped profile is started, an incompatible
same-name profile is refused, and an absent profile is created.  After a call
it re-observes the wall and reads the VM's stable machine id before returning a
wall observation.  The resulting observation still has to pass
'settleProviderWallCall' before live wall authority exists.
-}
module HostBootstrap.Ensure.Colima
  ( ColimaProfile,
    withColimaProfile,
    colimaProfileName,
    colimaDockerContext,
    colimaDockerArgs,
    runColimaDocker,
    ColimaInstance (..),
    parseColimaInstances,
    ColimaWallDecision (..),
    PreparedColimaWallCall,
    prepareColimaWallCall,
    preparedColimaWallArgs,
    classifyColimaWall,
    runPreparedColimaWallCall,
  )
where

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Char8 as ByteString
import Data.Bits (xor)
import Data.Char (isAsciiLower, isDigit, toLower)
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Cluster.Budget
  ( BudgetError,
    BudgetPartition,
    ColimaProvider,
    PreparedProviderWallCall,
    ProviderWallReservation,
    ProviderWallSpec,
    WallAcquireObservation (..),
    prepareProviderWallCall,
    providerWallCallArgs,
  )
import HostBootstrap.Context (BinaryContext)
import qualified HostBootstrap.Context as Context
import HostBootstrap.Ensure (runTool, toolPresent)
import HostBootstrap.HostConfig (HostConfig (..), buildHostConfig)
import HostBootstrap.HostTool (HostTool (Brew, Colima, Docker))
import HostBootstrap.Reconcile
  ( ConflictDetail (..),
    FailureDetail (..),
    LifecyclePlan,
    ReconcileError (..),
    RecoveryDisposition (..),
  )
import HostBootstrap.Substrate (isAppleSilicon)
import System.Exit (ExitCode (..))

-- | Opaque plan-bound profile identity. The phantom prevents use with another
-- lifecycle plan even when the textual project name is the same.
newtype ColimaProfile scope planId profileId = ColimaProfile String

withColimaProfile ::
  LifecyclePlan scope planId ->
  BinaryContext ->
  (forall profileId. ColimaProfile scope planId profileId -> result) ->
  Either ReconcileError result
withColimaProfile _plan context consume
  | Context.project context /= Context.binary context =
      Left
        ( Conflict
            ( ConflictDetail
                "colima profile identity"
                (Context.project context)
                (Context.binary context)
                "use a config whose validated project and binary identities agree"
            )
        )
  | not (validProfileName name) =
      Left
        ( Failure
            ( FailureDetail
                "derive Colima profile"
                ("invalid project profile name: " <> Text.pack (show name))
                DoNotRetry
            )
        )
  | name == "default" =
      Left
        ( Conflict
            ( ConflictDetail
                "colima profile identity"
                "a project-specific profile"
                "default"
                "the shared default Colima profile is never project authority"
            )
        )
  | otherwise = Right (consume (ColimaProfile name))
  where
    name = Text.unpack (Context.project context)

validProfileName :: String -> Bool
validProfileName [] = False
validProfileName (first : rest) =
  validInitial first
    && all validRest rest
    && length (first : rest) <= 63
  where
    validInitial char = isAsciiLower char || isDigit char
    validRest char = validInitial char || char `elem` ("._-" :: String)

colimaProfileName :: ColimaProfile scope planId profileId -> String
colimaProfileName (ColimaProfile name) = name

-- | Named Colima Docker contexts use this stable spelling. Callers pass it to
-- @docker --context@; the adapter never changes the process-global active
-- Docker context.
colimaDockerContext :: ColimaProfile scope planId profileId -> String
colimaDockerContext (ColimaProfile name) = "colima-" ++ name

colimaDockerArgs ::
  ColimaProfile scope planId profileId ->
  [String] ->
  [String]
colimaDockerArgs profile args =
  ["--context", colimaDockerContext profile] ++ args

-- | Run Docker against this profile's named context without changing the
-- process-global active context.
runColimaDocker ::
  HostConfig ->
  ColimaProfile scope planId profileId ->
  [String] ->
  IO (Either String (ExitCode, String, String))
runColimaDocker cfg profile =
  runTool cfg Docker . colimaDockerArgs profile

data ColimaInstance = ColimaInstance
  { ciName :: String,
    ciStatus :: String,
    ciCpus :: Integer,
    ciMemoryBytes :: Integer,
    ciDiskBytes :: Integer,
    ciRuntime :: String
  }
  deriving (Eq, Show)

instance Aeson.FromJSON ColimaInstance where
  parseJSON =
    Aeson.withObject "ColimaInstance" $ \object ->
      ColimaInstance
        <$> object Aeson..: "name"
        <*> object Aeson..: "status"
        <*> object Aeson..: "cpus"
        <*> object Aeson..: "memory"
        <*> object Aeson..: "disk"
        <*> object Aeson..: "runtime"

-- | Colima emits one JSON object per line, not a surrounding JSON array.
parseColimaInstances :: String -> Either String [ColimaInstance]
parseColimaInstances output =
  traverse parseLine (filter (not . null) (lines output))
  where
    parseLine line =
      Aeson.eitherDecodeStrict' (ByteString.pack line)

data ColimaWallDecision
  = CreateColimaWall
  | StartStoppedColimaWall
  | KeepExactColimaWall
  | RefuseColimaWall ConflictDetail
  deriving (Eq, Show)

-- | The generic prepared call paired inseparably with the profile identity used
-- to prepare it.
data PreparedColimaWallCall
  scope
  planId
  budgetId
  capabilityId
  wallSpecId
  workloadSetId
  partitionId
  reservationId
  fence
  profileId =
  PreparedColimaWallCall
    (ColimaProfile scope planId profileId)
    ( PreparedProviderWallCall
        scope
        planId
        budgetId
        ColimaProvider
        capabilityId
        wallSpecId
        workloadSetId
        partitionId
        reservationId
        fence
    )

prepareColimaWallCall ::
  ColimaProfile scope planId profileId ->
  ProviderWallSpec scope planId budgetId ColimaProvider capabilityId wallSpecId ->
  BudgetPartition scope planId budgetId ColimaProvider capabilityId wallSpecId workloadSetId partitionId ->
  ProviderWallReservation
    scope
    planId
    budgetId
    ColimaProvider
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence ->
  Either
    BudgetError
    ( PreparedColimaWallCall
        scope
        planId
        budgetId
        capabilityId
        wallSpecId
        workloadSetId
        partitionId
        reservationId
        fence
        profileId
    )
prepareColimaWallCall profile wall partition reservation =
  PreparedColimaWallCall profile
    <$> prepareProviderWallCall
      (colimaProfileName profile)
      wall
      partition
      reservation

preparedColimaWallArgs ::
  PreparedColimaWallCall
    scope
    planId
    budgetId
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence
    profileId ->
  [String]
preparedColimaWallArgs (PreparedColimaWallCall _ prepared) =
  providerWallCallArgs prepared

data ExpectedColimaWall = ExpectedColimaWall
  { expectedCpus :: Integer,
    expectedMemoryBytes :: Integer,
    expectedDiskBytes :: Integer
  }

classifyColimaWall ::
  PreparedColimaWallCall
    scope
    planId
    budgetId
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence
    profileId ->
  [ColimaInstance] ->
  Either ReconcileError ColimaWallDecision
classifyColimaWall call@(PreparedColimaWallCall profile _) instances = do
  expected <- expectedWall call
  case filter ((== colimaProfileName profile) . ciName) instances of
    [] -> Right CreateColimaWall
    [observed]
      | not (matchesExpected expected observed) ->
          Right (RefuseColimaWall (wallConflict expected observed))
      | map toLower (ciRuntime observed) /= "docker" ->
          Right (RefuseColimaWall (wallConflict expected observed))
      | map toLower (ciStatus observed) == "running" ->
          Right KeepExactColimaWall
      | map toLower (ciStatus observed) == "stopped" ->
          Right StartStoppedColimaWall
      | otherwise ->
          Right (RefuseColimaWall (wallConflict expected observed))
    observed ->
      Left
        ( Conflict
            ( ConflictDetail
                "observe Colima profile"
                "one profile record"
                (Text.pack (show (length observed)) <> " records")
                "repair the duplicate provider observation before retrying"
            )
        )

matchesExpected :: ExpectedColimaWall -> ColimaInstance -> Bool
matchesExpected expected observed =
  ciCpus observed == expectedCpus expected
    && ciMemoryBytes observed == expectedMemoryBytes expected
    && ciDiskBytes observed == expectedDiskBytes expected

wallConflict :: ExpectedColimaWall -> ColimaInstance -> ConflictDetail
wallConflict expected observed =
  ConflictDetail
    "reconcile Colima provider wall"
    (renderExpected expected)
    ( Text.pack
        ( ciName observed
            ++ " status="
            ++ ciStatus observed
            ++ " runtime="
            ++ ciRuntime observed
            ++ " cpu="
            ++ show (ciCpus observed)
            ++ " memory="
            ++ show (ciMemoryBytes observed)
            ++ " disk="
            ++ show (ciDiskBytes observed)
        )
    )
    "stop and explicitly resize the owned profile, or choose another project identity"

renderExpected :: ExpectedColimaWall -> Text.Text
renderExpected expected =
  Text.pack
    ( "runtime=docker cpu="
        ++ show (expectedCpus expected)
        ++ " memory="
        ++ show (expectedMemoryBytes expected)
        ++ " disk="
        ++ show (expectedDiskBytes expected)
    )

expectedWall ::
  PreparedColimaWallCall
    scope
    planId
    budgetId
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence
    profileId ->
  Either ReconcileError ExpectedColimaWall
expectedWall call = do
  cpus <- flagInteger "--cpus"
  memoryGiB <- flagInteger "--memory"
  diskGiB <- flagInteger "--disk"
  pure
    ExpectedColimaWall
      { expectedCpus = cpus,
        expectedMemoryBytes = memoryGiB * gib,
        expectedDiskBytes = diskGiB * gib
      }
  where
    args = preparedColimaWallArgs call
    gib = 1024 ^ (3 :: Integer)
    flagInteger flag =
      case dropWhile (/= flag) args of
        _ : value : _ ->
          case reads value of
            [(parsed, "")] -> Right parsed
            _ -> malformed flag
        _ -> malformed flag
    malformed flag =
      Left
        ( Failure
            ( FailureDetail
                "decode prepared Colima wall"
                ("prepared call is missing a valid " <> Text.pack flag)
                DoNotRetry
            )
        )

runPreparedColimaWallCall ::
  HostConfig ->
  PreparedColimaWallCall
    scope
    planId
    budgetId
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence
    profileId ->
  IO WallAcquireObservation
runPreparedColimaWallCall initialCfg call
  | not (isAppleSilicon (hcSubstrate initialCfg)) =
      pure (failed "Colima wall is only supported on Apple silicon" DoNotRetry)
  | otherwise = do
      cfgResult <- ensureColimaTool initialCfg
      case cfgResult of
        Left err -> pure (failed err ReprobeBeforeRetry)
        Right cfg -> do
          observed <- observeInstances cfg
          case observed >>= classifyColimaWall call of
            Left err -> pure (reconcileErrorObservation err)
            Right (RefuseColimaWall detail) -> pure (WallRefused detail)
            Right KeepExactColimaWall -> observeExactEpoch cfg WallAlreadyExact
            Right CreateColimaWall ->
              applyAndVerify cfg CreatedWall
            Right StartStoppedColimaWall ->
              applyAndVerify cfg RestartedWall
  where
    applyAndVerify cfg change = do
      result <- runTool cfg Colima (preparedColimaWallArgs call)
      case result of
        Left err -> pure (failed err ReprobeBeforeRetry)
        Right (ExitFailure code, _, errOut) -> do
          -- Colima serializes profile work internally. Another invocation may
          -- have won the create/start race, so re-observe before reporting a
          -- failure. Exact state converges; incompatible state is refused.
          afterRace <- observeInstances cfg
          case afterRace >>= classifyColimaWall call of
            Right KeepExactColimaWall -> observeExactEpoch cfg WallAlreadyExact
            Right (RefuseColimaWall detail) -> pure (WallRefused detail)
            _ ->
              pure
                ( failed
                    ("colima start failed (exit " ++ show code ++ "): " ++ errOut)
                    ReprobeBeforeRetry
                )
        Right (ExitSuccess, _, _) -> do
          observed <- observeInstances cfg
          case observed >>= classifyColimaWall call of
            Right KeepExactColimaWall ->
              observeExactEpoch cfg $ \epoch ->
                case change of
                  CreatedWall -> WallApplied epoch
                  RestartedWall -> WallMigrated epoch "started exact stopped profile"
            Right decision ->
              pure
                ( failed
                    ("Colima wall did not settle to running exact state: " ++ show decision)
                    ReprobeBeforeRetry
                )
            Left err -> pure (reconcileErrorObservation err)
    observeExactEpoch cfg consume = do
      epochResult <- observeEpoch cfg call
      pure $ case epochResult of
        Left err -> failed err ReprobeBeforeRetry
        Right epoch -> consume epoch

data AppliedChange = CreatedWall | RestartedWall

ensureColimaTool :: HostConfig -> IO (Either String HostConfig)
ensureColimaTool cfg
  | toolPresent cfg Colima = pure (Right cfg)
  | not (toolPresent cfg Brew) =
      pure (Left "neither colima nor Homebrew is available")
  | otherwise = do
      installed <- runTool cfg Brew ["install", "colima"]
      case installed of
        Left err -> pure (Left err)
        Right (ExitFailure code, _, errOut) ->
          pure (Left ("brew install colima failed (exit " ++ show code ++ "): " ++ errOut))
        Right (ExitSuccess, _, _) -> do
          refreshed <- buildHostConfig (hcSubstrate cfg)
          if toolPresent refreshed Colima
            then pure (Right refreshed)
            else pure (Left "colima is still unavailable after Homebrew installation")

observeInstances :: HostConfig -> IO (Either ReconcileError [ColimaInstance])
observeInstances cfg = do
  result <- runTool cfg Colima ["list", "--json"]
  pure $ case result of
    Left err -> failure err
    Right (ExitFailure code, _, errOut) ->
      failure ("colima list failed (exit " ++ show code ++ "): " ++ errOut)
    Right (ExitSuccess, out, _) ->
      case parseColimaInstances out of
        Left err -> failure ("could not decode colima list JSON: " ++ err)
        Right instances -> Right instances
  where
    failure message =
      Left
        ( Failure
            (FailureDetail "observe Colima profiles" (Text.pack message) ReprobeBeforeRetry)
        )

observeEpoch ::
  HostConfig ->
  PreparedColimaWallCall
    scope
    planId
    budgetId
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence
    profileId ->
  IO (Either String Word64)
observeEpoch cfg (PreparedColimaWallCall profile _) = do
  result <-
    runTool
      cfg
      Colima
      ["ssh", "--profile", colimaProfileName profile, "--", "cat", "/etc/machine-id"]
  pure $ case result of
    Left err -> Left err
    Right (ExitFailure code, _, errOut) ->
      Left
        ( "could not read Colima profile identity (exit "
            ++ show code
            ++ "): "
            ++ errOut
        )
    Right (ExitSuccess, out, _) ->
      case filter (`notElem` ("\r\n" :: String)) out of
        [] -> Left "Colima profile returned an empty machine identity"
        machineId -> Right (positiveHash machineId)

positiveHash :: String -> Word64
positiveHash value =
  let hashed = foldl' step 14695981039346656037 value
   in if hashed == 0 then 1 else hashed
  where
    step acc char = (acc `xor` fromIntegral (fromEnum char)) * 1099511628211

failed :: String -> RecoveryDisposition -> WallAcquireObservation
failed message recovery =
  WallAcquireFailed
    (FailureDetail "acquire Colima provider wall" (Text.pack message) recovery)

reconcileErrorObservation :: ReconcileError -> WallAcquireObservation
reconcileErrorObservation err =
  case err of
    Conflict detail -> WallRefused detail
    SafetyRefusal detail ->
      failed (show detail) DoNotRetry
    Unsupported detail ->
      failed (show detail) DoNotRetry
    Failure detail ->
      WallAcquireFailed detail
