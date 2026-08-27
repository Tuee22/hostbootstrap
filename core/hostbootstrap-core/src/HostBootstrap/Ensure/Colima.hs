{-# LANGUAGE CPP #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}

{- | The prepared, per-project Colima provider wall used by direct Apple Docker
lanes.

The shared @default@ profile is never an authority source.  This module derives
one provider-local profile from the installed-project identity retained by an
exact 'ProjectPlan'.  The only start argv accepted by the live adapter is the
opaque prepared Colima wall call produced by joining that plan, its provider
resource and topology, and the complete admitted budget/fit/partition/reservation
package.

The adapter holds one OS-released profile lock across observation, durable
origin recording, mutation, and settlement.  An exact running profile is a
no-op only when its durable origin record and stable machine identity match;
an unowned or incompatible same-name profile is refused, and an absent profile
is recorded before it is created.  The resulting opaque observation still has
to pass 'settleProviderWallCall' before live wall authority exists.
-}
module HostBootstrap.Ensure.Colima
  ( ColimaInstance (..),
    parseColimaInstances,
    ColimaWallDecision (..),
    ColimaWallObservation,
    PreparedColimaWallCall,
    prepareColimaWallCall,
    preparedColimaProfileName,
    classifyColimaWall,
    runPreparedColimaWallCall,
    LiveColimaWall,
    settleColimaWallCall,
    liveColimaWallEpoch,
    liveColimaWallChange,
    liveColimaProviderChange,
    liveColimaDockerContext,
    liveColimaDockerArgs,
    runLiveColimaDocker,
    ColimaCleanupAuthority,
    withColimaCleanupAuthority,
    PreparedColimaCleanupCall,
    prepareColimaCleanupCall,
    runColimaCleanup,
    validColimaProjectProfileName,
  )
where

#if !defined(mingw32_HOST_OS)
import Control.Exception (IOException, try)
#endif
import qualified Crypto.Hash as Hash
import Data.Bifunctor (first)
import qualified Data.ByteString as ByteString.Strict
import Data.Char (isAlphaNum, isAsciiLower, isDigit, toLower)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text.Encoding
import Data.Word (Word64)
import HostBootstrap.Cluster.Budget
  ( BudgetError,
    BudgetPartition,
    ColimaProvider,
    PreparedProviderWallCall,
    ProviderBudgetCapability,
    ProviderWallAuthority,
    ProviderWallReservation,
    ProviderWallSpec,
    ValidatedBudget,
    VerifiedWorkloadFit,
    WallAcquireObservation (..),
    preparePlanOwnedProviderWallCall,
    providerWallEpoch,
    providerWallCallArgs,
    providerWallCallFence,
  )
import HostBootstrap.Ensure.Colima.Settlement.Internal (ColimaWallSettlementObservation (..), withColimaWallSettlement)
import HostBootstrap.Ensure.Colima.Ownership
  ( ColimaArtifactObservation (..),
    ColimaManagedObservation (..),
    ColimaManagedOutcome (..),
    ColimaProfileMutationFault (..),
    ColimaStartedObservation (..),
    acquireManagedColimaProfileWith,
    cleanupManagedColimaProfileWith,
    runManagedColimaDockerWith,
  )
import HostBootstrap.Ensure.Colima.Report (ColimaInstance (..), parseColimaInstances)
import HostBootstrap.Ensure.Colima.Backend.Runner (BackendNamespace (..), BoundedToolResult (..), runBoundedTool, runShippedCommand)
import HostBootstrap.Effect.Interpreter (resolveLaunch)
import HostBootstrap.Effect.Run (CapturedRun (..))
import HostBootstrap.Effect.Vocabulary (HostCommand)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (Colima, Docker, Lima), mkAbsExe)
import HostBootstrap.Ensure.Colima.Backend.Resolver
  ( TrustedAppleBrew,
    TrustedAppleToolchain,
    TrustedResolverResult (..),
    currentTrustedResolverOverrideHomeForTesting,
    revalidateTrustedAppleBrew,
    revalidateTrustedAppleToolchain,
    resolveTrustedAppleToolchain,
    trustedAppleBrewHelperPath,
    trustedAppleBrewPath,
    trustedAppleColimaPath,
    trustedAppleDockerPath,
    trustedAppleHelperPath,
    trustedAppleLimaPath,
    trustedApplePythonPath,
    trustedAppleToolchainFingerprint,
  )
import HostBootstrap.Ensure.Colima.Backend.Resolver.Install
  ( TrustedInstallActions (..),
    TrustedInstallResult (..),
    runTrustedInstallRediscovery,
  )
import HostBootstrap.Lifecycle.Prepared
  ( PreparedGate,
    preparedGateAttempt,
    preparedGateFence,
    preparedGateJournalVersion,
    preparedGateOperation,
    preparedGatePlan,
    preparedGateSession,
  )
import HostBootstrap.ProjectPlan
  ( DerivedTopology,
    PlannedResource,
    ProjectPlan,
    ProviderResource,
    projectPlanProfileName,
    projectPlanProjectName,
    plannedResourceFrame,
    plannedResourceKey,
    renderSnapshot,
    stablePlanSnapshotDigest,
    stablePlanSnapshotRoot,
  )
import HostBootstrap.Reconcile
  ( ChangeView (..),
    ConflictDetail (..),
    Destroyed,
    FailureDetail (..),
    Managed,
    Observed,
    OwnershipReceipt,
    PhaseAdvance,
    PreparedProviderStart,
    PreparedPhaseTransition,
    ReconcileError (..),
    RecoveryDisposition (..),
    ResourceHandle,
    Running,
    Unclassified,
    UnsupportedDetail (..),
    completePreparedPhaseTransition,
    planProviderForceDestroy,
    plannedProjectPhaseOperation,
    resourceHandleGeneration,
    ownershipReceiptOperationKey,
    withPreparedProviderStart,
    withPreparedPhaseTransition,
    zeroDependencyPreconditions,
  )
import HostBootstrap.Substrate (detect, isAppleSilicon)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, takeDirectory, (</>))
#if !defined(mingw32_HOST_OS)
import System.Posix.User (getEffectiveUserID, getUserEntryForID, homeDirectory)
#endif

-- | The project-name policy is observable for tests and diagnostics, but it
-- cannot mint a profile.  Only 'prepareColimaWallCall' can do that, from the
-- project identity retained by an admitted plan.
validColimaProjectProfileName :: Text.Text -> Bool
validColimaProjectProfileName projectName =
  let name = Text.unpack projectName
   in validProfileName name && name /= "default"

validateProfileName :: Text.Text -> Either ReconcileError String
validateProfileName projectName
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
  | otherwise = Right name
  where
    name = Text.unpack projectName

deriveColimaNames :: Text.Text -> Text.Text -> Text.Text -> Text.Text -> FilePath -> Either ReconcileError (String, String)
deriveColimaNames projectName lifecycleProfile resourceKey resourceFrame stateRoot = do
  _ <- validateProfileName projectName
  case lifecycleProfile of
    "production" -> Right derived
    profile ->
      case Text.stripPrefix "harness:" profile of
        Just runKey
          | validHarnessRunKey runKey ->
              Right derived
          | otherwise -> invalid "the admitted Harness profile carries an invalid run key"
        Nothing -> invalid "the admitted plan carries an unknown lifecycle profile"
  where
    -- The 128-bit home key is the profile-global authority namespace.  The
    -- short profile is local to that isolated home, keeping Lima's Darwin
    -- socket path below 104 bytes without weakening the home/lock identity.
    digest =
      Text.unpack
        ( sha256Text
            ( Text.intercalate
                "\NUL"
                [ "direct-colima-provider-namespace-v1",
                  projectName,
                  lifecycleProfile,
                  resourceKey,
                  resourceFrame,
                  Text.pack stateRoot
                ]
            )
        )
    derived = ("h-" ++ take 6 (drop 32 digest), take 32 digest)
    validHarnessRunKey runKey =
      not (Text.null runKey)
        && Text.length runKey <= 48
        && Text.all (\character -> isAlphaNum character || character == '-') runKey
    invalid detail =
      Left
        ( Failure
            ( FailureDetail
                "derive Colima profile"
                detail
                DoNotRetry
            )
        )

sha256Text :: Text.Text -> Text.Text
sha256Text value =
  Text.pack
    ( show
        (Hash.hashWith Hash.SHA256 (Text.Encoding.encodeUtf8 value))
    )

validProfileName :: String -> Bool
validProfileName [] = False
validProfileName (initial : rest) =
  validInitial initial
    && all validRest rest
    && length (initial : rest) <= 63
  where
    validInitial char = isAsciiLower char || isDigit char
    validRest char = validInitial char || char `elem` ("._-" :: String)

data ColimaWallDecision
  = CreateColimaWall
  | StartStoppedColimaWall
  | KeepExactColimaWall
  | RefuseColimaWall ConflictDetail
  deriving (Eq, Show)

-- | Raw backend facts remain deliberately plan-independent.  A successful
-- owned observation carries only the durable origin-record path created by the
-- lock-held backend; settlement against the exact prepared call is still what
-- introduces plan indices and live authority.
data ColimaWallObservation
  = ColimaOwnedWallObservation ColimaOwnedObservation
  | ColimaUnownedWallObservation WallAcquireObservation
  | ColimaWallOwnershipUnsupported UnsupportedDetail
  deriving (Eq, Show)

data ColimaOwnedObservation = ColimaOwnedObservation
  { ownedToolchain :: TrustedAppleToolchain,
    ownedNamespaceKey :: String,
    ownedNamespace :: BackendNamespace,
    ownedStateRoot :: FilePath,
    ownedRecordPath :: FilePath,
    ownedOwner :: String,
    ownedLineage :: String,
    ownedMachineId :: String,
    ownedContextDigest :: String,
    ownedExpectedWall :: ExpectedColimaWall,
    ownedInvocationDigest :: String,
    ownedSettlementObservation :: ColimaWallSettlementObservation
  }
  deriving (Eq, Show)

-- | The exact plan-owned Colima call.  The provider profile is retained only
-- inside this sealed value; there is no independently constructible or
-- caller-selected profile term.
data PreparedColimaWallCall
  scope
  specDigest
  planId
  configId
  providerResourceId
  providerFrame
  budgetId
  capabilityId
  wallSpecId
  workloadSetId
  partitionId
  reservationId
  fence =
  PreparedColimaWallCall
    String
    String
    String
    FilePath
    FilePath
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
    (PreparedColimaOperation scope planId providerResourceId)

type role PreparedColimaWallCall nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal nominal

-- | The acquisition journal lineage is existential only in the journal's
-- generative operation/call/attempt/version identities.  Its plan and provider
-- resource remain the same nominal indices as the prepared wall call.
data PreparedColimaOperation scope planId providerResourceId where
  PreparedColimaOperation ::
    String ->
    PreparedProviderStart
      scope
      planId
      providerResourceId
      operationKey
      callDigest
      attempt
      journalVersion ->
    PreparedColimaOperation scope planId providerResourceId

prepareColimaWallCall ::
  ProjectPlan scope specDigest planId configId cfg ->
  PlannedResource scope planId providerResourceId ProviderResource providerFrame ->
  ResourceHandle scope planId providerResourceId ProviderResource Unclassified Observed ->
  DerivedTopology scope planId ->
  ValidatedBudget scope planId budgetId ->
  ProviderBudgetCapability scope planId ColimaProvider capabilityId ->
  ProviderWallSpec scope planId budgetId ColimaProvider capabilityId wallSpecId ->
  VerifiedWorkloadFit scope planId budgetId ColimaProvider capabilityId wallSpecId workloadSetId ->
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
  PreparedGate ->
  IO
    ( Either
        ReconcileError
        ( PreparedColimaWallCall
            scope
            specDigest
            planId
            configId
            providerResourceId
            providerFrame
            budgetId
            capabilityId
            wallSpecId
            workloadSetId
            partitionId
            reservationId
            fence
        )
    )
prepareColimaWallCall plan providerResource providerHandle derivedTopology validated capability wall fit partition reservation gate =
  case prepareBudgetCall of
    Left err -> pure (Left err)
    Right (profileName, namespaceKey, ownerToken, stateRoot, recordPath, prepared) -> do
      let callDigest = colimaAcquireCallDigest profileName namespaceKey ownerToken recordPath prepared
      if preparedGateFence gate /= providerWallCallFence prepared
        then
          pure
            ( Left
                ( Conflict
                    ( ConflictDetail
                        (plannedResourceKey providerResource)
                        ("prepared provider fence " <> Text.pack (show (providerWallCallFence prepared)))
                        ("journal gate fence " <> Text.pack (show (preparedGateFence gate)))
                        "record this exact provider wall operation at the reservation fence"
                    )
                )
            )
        else
          let invocationDigest = colimaInvocationDigest callDigest gate
           in pure $
                withPreparedProviderStart plan providerResource providerHandle callDigest gate $ \start ->
                  PreparedColimaWallCall
                    profileName
                    namespaceKey
                    ownerToken
                    stateRoot
                    recordPath
                    prepared
                    (PreparedColimaOperation invocationDigest start)
  where
    prepareBudgetCall = do
      let snapshot = renderSnapshot plan
          stateRoot = stablePlanSnapshotRoot snapshot
      (profileName, namespaceKey) <-
        deriveColimaNames
          (projectPlanProjectName plan)
          (projectPlanProfileName plan)
          (plannedResourceKey providerResource)
          (plannedResourceFrame providerResource)
          stateRoot
      planDigest <- validateOriginToken (stablePlanSnapshotDigest snapshot)
      if isAbsolute stateRoot
        then pure ()
        else
          Left
            ( Failure
                ( FailureDetail
                    "prepare Colima ownership record"
                    "the retained canonical project root is not absolute"
                    DoNotRetry
                )
            )
      prepared <-
        first budgetReconcileError $
          preparePlanOwnedProviderWallCall
            plan
            providerResource
            derivedTopology
            validated
            capability
            wall
            fit
            partition
            reservation
            profileName
      ownerToken <-
        validateOwnerToken
          ( colimaOwnerToken
              profileName
              (projectPlanProjectName plan)
              (projectPlanProfileName plan)
              planDigest
              (plannedResourceKey providerResource)
              (plannedResourceFrame providerResource)
              (providerWallCallFence prepared)
          )
      let recordPath =
            stateRoot
              </> ".hostbootstrap"
              </> "colima"
              </> originRecordName ownerToken
      pure (profileName, namespaceKey, ownerToken, stateRoot, recordPath, prepared)

colimaAcquireCallDigest ::
  String ->
  String ->
  String ->
  FilePath ->
  PreparedProviderWallCall scope planId budgetId ColimaProvider capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  Text.Text
colimaAcquireCallDigest profileName namespaceKey owner recordPath prepared =
  Text.pack
    ( show
        ( Hash.hashWith
            Hash.SHA256
            ( Text.Encoding.encodeUtf8
                ( Text.intercalate
                    "\NUL"
                    ( map Text.pack
                        ( "direct-colima-acquire-v1"
                            : profileName
                            : namespaceKey
                            : owner
                            : recordPath
                            : show (providerWallCallFence prepared)
                            : providerWallCallArgs prepared
                        )
                    )
                )
            )
        )
    )

colimaInvocationDigest :: Text.Text -> PreparedGate -> String
colimaInvocationDigest callDigest gate =
  show
    ( Hash.hashWith
        Hash.SHA256
        ( Text.Encoding.encodeUtf8
            ( Text.intercalate
                "\NUL"
                [ "direct-colima-invocation-v1",
                  callDigest,
                  preparedGatePlan gate,
                  preparedGateOperation gate,
                  preparedGateSession gate,
                  Text.pack (show (preparedGateFence gate)),
                  Text.pack (show (preparedGateAttempt gate)),
                  Text.pack (show (preparedGateJournalVersion gate))
                ]
            )
        )
    )

colimaOwnerToken :: String -> Text.Text -> Text.Text -> String -> Text.Text -> Text.Text -> Word64 -> String
colimaOwnerToken profileName projectName lifecycleProfile planDigest resourceKey resourceFrame fenceValue =
  "v2-"
    ++ hexText (Text.pack profileName)
    ++ "-"
    ++ hexText projectName
    ++ "-"
    ++ hexText lifecycleProfile
    ++ "-"
    ++ hexText (Text.pack planDigest)
    ++ "-"
    ++ hexText resourceKey
    ++ "-"
    ++ hexText resourceFrame
    ++ "-"
    ++ show fenceValue

hexText :: Text.Text -> String
hexText = concatMap hexByte . ByteString.Strict.unpack . Text.Encoding.encodeUtf8
  where
    digits = "0123456789abcdef"
    hexByte byte =
      [ digits !! fromIntegral (byte `div` 16),
        digits !! fromIntegral (byte `mod` 16)
      ]

validateOwnerToken :: String -> Either ReconcileError String
validateOwnerToken owner
  | null owner || length owner > 4096 || any unsafe owner =
      Left
        ( Failure
            ( FailureDetail
                "prepare Colima ownership record"
                "the exact profile/plan/resource/fence owner cannot be represented canonically"
                DoNotRetry
            )
        )
  | otherwise = Right owner
  where
    unsafe character =
      not (isAsciiLower character || isDigit character || character == '-')

validateOriginToken :: Text.Text -> Either ReconcileError String
validateOriginToken digest
  | Text.null digest || Text.length digest > 128 || Text.any unsafe digest =
      Left
        ( Failure
            ( FailureDetail
                "prepare Colima ownership record"
                "the retained stable plan digest is not a safe origin-record token"
                DoNotRetry
            )
        )
  | otherwise = Right (Text.unpack digest)
  where
    unsafe character =
      not
        ( isAsciiLower character
            || isDigit character
            || character `elem` ("._:-" :: String)
        )

budgetReconcileError :: BudgetError -> ReconcileError
budgetReconcileError budgetError =
  Failure
    ( FailureDetail
        "prepare plan-owned Colima wall"
        (Text.pack (show budgetError))
        DoNotRetry
    )

preparedColimaProfileName ::
  PreparedColimaWallCall
    scope
    specDigest
    planId
    configId
    providerResourceId
    providerFrame
    budgetId
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence ->
  String
preparedColimaProfileName (PreparedColimaWallCall profileName _ _ _ _ _ _) = profileName

preparedColimaNamespaceKey ::
  PreparedColimaWallCall
    scope
    specDigest
    planId
    configId
    providerResourceId
    providerFrame
    budgetId
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence ->
  String
preparedColimaNamespaceKey (PreparedColimaWallCall _ namespaceKey _ _ _ _ _) = namespaceKey

preparedColimaWallArgs ::
  PreparedColimaWallCall
    scope
    specDigest
    planId
    configId
    providerResourceId
    providerFrame
    budgetId
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence ->
  [String]
preparedColimaWallArgs (PreparedColimaWallCall _ _ _ _ _ prepared _) =
  providerWallCallArgs prepared

data ExpectedColimaWall = ExpectedColimaWall
  { expectedCpus :: Integer,
    expectedMemoryBytes :: Integer,
    expectedDiskBytes :: Integer,
    expectedRootDiskBytes :: Integer
  }
  deriving (Eq, Show)

classifyColimaWall ::
  PreparedColimaWallCall
    scope
    specDigest
    planId
    configId
    providerResourceId
    providerFrame
    budgetId
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence ->
  [ColimaInstance] ->
  Either ReconcileError ColimaWallDecision
classifyColimaWall call@(PreparedColimaWallCall profileName _ _ _ _ _ _) instances = do
  expected <- expectedWall call
  case filter ((== profileName) . ciName) instances of
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
        ++ " root-disk="
        ++ show (expectedRootDiskBytes expected)
    )

expectedWall ::
  PreparedColimaWallCall
    scope
    specDigest
    planId
    configId
    providerResourceId
    providerFrame
    budgetId
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence ->
  Either ReconcileError ExpectedColimaWall
expectedWall call = do
  cpus <- flagInteger "--cpus"
  memoryGiB <- flagInteger "--memory"
  diskGiB <- flagInteger "--disk"
  rootDiskGiB <- flagInteger "--root-disk"
  pure
    ExpectedColimaWall
      { expectedCpus = cpus,
        expectedMemoryBytes = memoryGiB * gib,
        expectedDiskBytes = diskGiB * gib,
        expectedRootDiskBytes = rootDiskGiB * gib
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
  PreparedColimaWallCall
    scope
    specDigest
    planId
    configId
    providerResourceId
    providerFrame
    budgetId
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence ->
  IO ColimaWallObservation
runPreparedColimaWallCall call = do
  backendResult <- discoverDirectColimaBackend call
  case backendResult of
    Left (Unsupported detail) -> pure (ColimaWallOwnershipUnsupported detail)
    Left err -> pure (reconcileErrorObservation err)
    Right backend -> do
      unchanged <- revalidateOwnershipBackend backend
      case (unchanged, expectedWall call) of
        (Left err, _) -> pure (reconcileErrorObservation err)
        (_, Left err) -> pure (reconcileErrorObservation err)
        (Right (), Right expected) -> do
          let profileName = preparedColimaProfileName call
              stateRoot = preparedColimaStateRoot call
              recordPath = preparedColimaRecordPath call
              namespace = ownershipNamespace backend
              owner = bindColimaOwner (preparedColimaOwner call) backend
              lineage = Text.unpack (sha256Text (Text.pack (ownershipNamespaceKey backend)))
          configured <- nativeHostConfig backend
          case configured of
            Left err -> pure (reconcileErrorObservation err)
            Right config -> do
              createDirectoryIfMissing True (takeDirectory (namespaceDockerConfig namespace))
              result <-
                acquireManagedColimaProfileWith (interpretNativeColima config namespace)
                  stateRoot profileName owner lineage (preparedColimaInvocation call)
                  (namespaceColimaHome namespace) (namespaceDockerConfig namespace)
                  (expectedCpus expected) (expectedMemoryBytes expected) (expectedDiskBytes expected)
                  (expectedRootDiskBytes expected) (preparedColimaWallArgs call)
              postCall <- revalidateOwnershipBackend backend
              pure $ case postCall of
                Left err -> reconcileErrorObservation err
                Right () -> acquireObservation backend owner (preparedColimaInvocation call) stateRoot recordPath expected result

revalidateOwnershipBackend :: ColimaOwnershipBackend -> IO (Either ReconcileError ())
revalidateOwnershipBackend backend = do
  unchanged <- revalidateTrustedAppleToolchain (ownershipToolchain backend)
  pure $ first (cleanupFailure "revalidate direct-Colima toolchain") unchanged

nativeHostConfig :: ColimaOwnershipBackend -> IO (Either ReconcileError HostConfig)
nativeHostConfig backend = do
  substrate <- detect
  pure $ do
    host <- first (cleanupFailure "detect direct-Colima substrate") substrate
    colima <- first (cleanupFailure "resolve direct-Colima executable") (mkAbsExe (ownershipColimaPath backend))
    docker <- first (cleanupFailure "resolve direct-Docker executable") (mkAbsExe (ownershipDockerPath backend))
    lima <- first (cleanupFailure "resolve direct-Lima executable") (mkAbsExe (ownershipLimaPath backend))
    Right (HostConfig host (Map.fromList [(Colima, colima), (Docker, docker), (Lima, lima)]))

nativeHostConfigForOwned :: ColimaOwnedObservation -> IO (Either ReconcileError HostConfig)
nativeHostConfigForOwned owned =
  nativeHostConfig
    ColimaOwnershipBackend
      { ownershipToolchain = ownedToolchain owned,
        ownershipNamespaceKey = ownedNamespaceKey owned,
        ownershipPythonPath = trustedApplePythonPath (ownedToolchain owned),
        ownershipColimaPath = trustedAppleColimaPath (ownedToolchain owned),
        ownershipDockerPath = trustedAppleDockerPath (ownedToolchain owned),
        ownershipLimaPath = trustedAppleLimaPath (ownedToolchain owned),
        ownershipNamespace = ownedNamespace owned
      }

interpretNativeColima :: HostConfig -> BackendNamespace -> HostCommand -> IO (Either String CapturedRun)
interpretNativeColima config namespace command = case resolveLaunch config command of
  Left refusal -> pure (Left refusal)
  Right (executable, arguments) -> do
    outcome <- runShippedCommand 300 namespace executable arguments
    pure $ case outcome of
      BoundedToolCompleted code out err -> Right (CapturedRun code out err)
      BoundedToolTimedOut -> Left "native Colima command timed out"
      BoundedToolFailed refusal -> Left refusal

data ColimaOwnershipBackend = ColimaOwnershipBackend
  { ownershipToolchain :: TrustedAppleToolchain,
    ownershipNamespaceKey :: String,
    ownershipPythonPath :: FilePath,
    ownershipColimaPath :: FilePath,
    ownershipDockerPath :: FilePath,
    ownershipLimaPath :: FilePath,
    ownershipNamespace :: BackendNamespace
  }

discoverDirectColimaBackend ::
  PreparedColimaWallCall scope specDigest planId configId providerResourceId providerFrame budgetId capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  IO (Either ReconcileError ColimaOwnershipBackend)
discoverDirectColimaBackend call = do
  discoverDirectColimaBackendAt
    (preparedColimaRecordPath call)
    (preparedColimaProfileName call)
    (preparedColimaNamespaceKey call)

discoverDirectColimaBackendAt :: FilePath -> String -> String -> IO (Either ReconcileError ColimaOwnershipBackend)
discoverDirectColimaBackendAt recordPath profileName namespaceKey = do
  fixtureHome <- currentTrustedResolverOverrideHomeForTesting
  case fixtureHome of
    Just home -> do
      resolved <- resolveTrustedAppleToolchain home
      settleTrustedResolution home recordPath profileName namespaceKey resolved
    Nothing -> do
      substrateResult <- detect
      case substrateResult of
        Left err -> pure (Left (cleanupFailure "detect direct-Colima substrate" err))
        Right substrate
          | not (isAppleSilicon substrate) ->
              pure
                ( Left
                    ( Unsupported
                        ( UnsupportedDetail
                            "reconcile Colima provider wall"
                            "direct Colima is supported only on a freshly detected Apple-silicon host"
                        )
                    )
                )
          | otherwise -> do
              homeResult <- effectiveHomeDirectory
              case homeResult of
                Left err -> pure (Left (cleanupFailure "resolve effective-user home" err))
                Right home -> do
                  resolved <- resolveTrustedAppleToolchain home
                  settleTrustedResolution home recordPath profileName namespaceKey resolved

settleTrustedResolution ::
  FilePath ->
  FilePath ->
  String ->
  String ->
  TrustedResolverResult ->
  IO (Either ReconcileError ColimaOwnershipBackend)
settleTrustedResolution home recordPath profileName namespaceKey resolved =
  case resolved of
    TrustedResolverReady toolchain ->
      pure (ownershipBackendFromToolchain toolchain home recordPath profileName namespaceKey)
    TrustedResolverUnsupported reason ->
      pure
        ( Left
            ( Unsupported
                ( UnsupportedDetail
                    "resolve direct-Colima toolchain"
                    (Text.pack reason)
                )
            )
        )
    TrustedResolverMissingColima brew -> installAndRediscover home recordPath profileName namespaceKey brew

installAndRediscover ::
  FilePath ->
  FilePath ->
  String ->
  String ->
  TrustedAppleBrew ->
  IO (Either ReconcileError ColimaOwnershipBackend)
installAndRediscover home recordPath profileName namespaceKey brew = do
  installed <-
    runTrustedInstallRediscovery
      TrustedInstallActions
        { trustedInstallRevalidateBrew = revalidateTrustedAppleBrew brew,
          trustedInstallRunBrew =
            runBoundedTool
              900
              (brewInstallNamespace home recordPath profileName brew)
              (trustedAppleBrewPath brew)
              ["install", "colima"],
          trustedInstallRediscover = resolveTrustedAppleToolchain home
        }
  pure $ case installed of
    TrustedInstallReady toolchain ->
      ownershipBackendFromToolchain toolchain home recordPath profileName namespaceKey
    TrustedInstallBrewChanged reason ->
      Left (cleanupFailure "install direct Colima" reason)
    TrustedInstallExitFailure (ExitFailure code) errOut ->
      Left (cleanupFailure "install direct Colima" ("Homebrew exited " ++ show code ++ ": " ++ errOut))
    TrustedInstallExitFailure ExitSuccess _ ->
      Left (cleanupFailure "install direct Colima" "the bounded Homebrew install returned an inconsistent success result")
    TrustedInstallTimedOut ->
      Left (cleanupFailure "install direct Colima" "the bounded Homebrew install timed out and its process group was terminated")
    TrustedInstallExecutionFailed reason ->
      Left (cleanupFailure "install direct Colima" reason)
    TrustedInstallStillMissing ->
      Left (cleanupFailure "install direct Colima" "Colima remains absent after the bounded Homebrew install")
    TrustedInstallResolverUnsupported reason ->
      Left (cleanupFailure "install direct Colima" reason)

ownershipBackendFromToolchain :: TrustedAppleToolchain -> FilePath -> FilePath -> String -> String -> Either ReconcileError ColimaOwnershipBackend
ownershipBackendFromToolchain toolchain home recordPath profileName namespaceKey =
  if socketPathBytes >= 104
    then
      Left
        ( Unsupported
            ( UnsupportedDetail
                "resolve direct-Colima namespace"
                "the effective-user home is too long for Lima's Darwin Unix-domain socket ceiling"
            )
        )
    else
      Right
        ColimaOwnershipBackend
          { ownershipToolchain = toolchain,
            ownershipNamespaceKey = namespaceKey,
            ownershipPythonPath = trustedApplePythonPath toolchain,
            ownershipColimaPath = trustedAppleColimaPath toolchain,
            ownershipDockerPath = trustedAppleDockerPath toolchain,
            ownershipLimaPath = trustedAppleLimaPath toolchain,
            ownershipNamespace = ownershipNamespaceFor toolchain home recordPath namespaceKey
          }
  where
    socketPathBytes =
      ByteString.Strict.length
        ( Text.Encoding.encodeUtf8
            ( Text.pack
                ( colimaHomePath home namespaceKey
                    </> "_lima"
                    </> ("colima-" ++ profileName)
                    </> "ssh.sock.0123456789abcdef"
                )
            )
        )

ownershipNamespaceFor :: TrustedAppleToolchain -> FilePath -> FilePath -> String -> BackendNamespace
ownershipNamespaceFor toolchain home recordPath namespaceKey =
  BackendNamespace
    { namespaceHomeDirectory = home,
      namespaceColimaHome = colimaHomePath home namespaceKey,
      namespaceLimaHome = colimaHomePath home namespaceKey </> "_lima",
      namespaceColimaCacheHome = colimaHomePath home namespaceKey </> "cache",
      namespaceTemporaryDirectory = colimaHomePath home namespaceKey </> "tmp",
      namespaceDockerConfig = recordPath ++ ".docker",
      namespaceWorkingDirectory = home,
      namespaceExecutablePath = trustedAppleHelperPath toolchain
    }

brewInstallNamespace :: FilePath -> FilePath -> String -> TrustedAppleBrew -> BackendNamespace
brewInstallNamespace home _recordPath _profileName brew =
  BackendNamespace
    { namespaceHomeDirectory = home,
      namespaceColimaHome = home,
      namespaceLimaHome = home,
      namespaceColimaCacheHome = home,
      namespaceTemporaryDirectory = home,
      namespaceDockerConfig = home,
      namespaceWorkingDirectory = home,
      namespaceExecutablePath = trustedAppleBrewHelperPath brew
    }

colimaHomePath :: FilePath -> String -> FilePath
colimaHomePath home namespaceKey = home </> (".h" ++ namespaceKey)

effectiveHomeDirectory :: IO (Either String FilePath)
#if defined(mingw32_HOST_OS)
effectiveHomeDirectory = pure (Left "direct Colima has no Windows effective-user namespace")
#else
effectiveHomeDirectory = do
  attempted <- tryEffectiveHome
  pure $ case attempted of
    Left err -> Left (show err)
    Right resolvedHome
      | isAbsolute resolvedHome -> Right resolvedHome
      | otherwise -> Left "the effective user's passwd home is not absolute"
  where
    tryEffectiveHome :: IO (Either IOException FilePath)
    tryEffectiveHome = try $ do
      userId <- getEffectiveUserID
      homeDirectory <$> getUserEntryForID userId
#endif

preparedColimaStateRoot ::
  PreparedColimaWallCall
    scope
    specDigest
    planId
    configId
    providerResourceId
    providerFrame
    budgetId
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence ->
  FilePath
preparedColimaStateRoot (PreparedColimaWallCall _ _ _ stateRoot _ _ _) = stateRoot

preparedColimaRecordPath ::
  PreparedColimaWallCall
    scope
    specDigest
    planId
    configId
    providerResourceId
    providerFrame
    budgetId
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence ->
  FilePath
preparedColimaRecordPath (PreparedColimaWallCall _ _ _ _ recordPath _ _) = recordPath

preparedColimaOwner ::
  PreparedColimaWallCall
    scope
    specDigest
    planId
    configId
    providerResourceId
    providerFrame
    budgetId
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence ->
  String
preparedColimaOwner (PreparedColimaWallCall _ _ owner _ _ _ _) = owner

bindColimaOwner :: String -> ColimaOwnershipBackend -> String
bindColimaOwner ownerSeed backend =
  ownerSeed
    ++ "-"
    ++ digestFields
      [ Text.pack (namespaceColimaHome namespace),
        Text.pack (namespaceLimaHome namespace),
        Text.pack (namespaceColimaCacheHome namespace),
        Text.pack (namespaceTemporaryDirectory namespace)
      ]
    ++ "-"
    ++ digestFields [Text.pack (namespaceDockerConfig namespace)]
    ++ "-"
    ++ digestFields [Text.pack (namespaceExecutablePath namespace)]
    ++ "-"
    ++ digestFields [Text.pack (trustedAppleToolchainFingerprint toolchain)]
  where
    namespace = ownershipNamespace backend
    toolchain = ownershipToolchain backend
    digestFields = Text.unpack . sha256Text . Text.intercalate "\NUL"

acquireObservation ::
  ColimaOwnershipBackend ->
  String ->
  String ->
  FilePath ->
  FilePath ->
  ExpectedColimaWall ->
  Either ColimaProfileMutationFault ColimaManagedOutcome ->
  ColimaWallObservation
acquireObservation backend owner invocationDigest stateRoot recordPath expected result =
  case result of
    Right (ColimaManagedApplied observation) -> owned observation (ColimaWallSettlementApplied (startedMachineEpoch (managedStartObservation observation)))
    Right (ColimaManagedAlreadyExact observation) -> owned observation (ColimaWallSettlementAlreadyExact (startedMachineEpoch (managedStartObservation observation)))
    Left reason@ColimaMutationProfileConflict {} ->
      ColimaUnownedWallObservation
        ( WallRefused
            ( ConflictDetail
                "reconcile Colima provider wall"
                (renderExpected expected)
                (Text.pack (show reason))
                "leave the conflicting profile untouched and resolve its owner or sizing explicitly"
            )
        )
    Left reason ->
      ColimaUnownedWallObservation
        ( WallAcquireFailed
            ( FailureDetail
                "acquire Colima provider wall"
                (Text.pack (show reason))
                ReprobeBeforeRetry
            )
        )
  where
    owned observation settlementObservation =
      ColimaOwnedWallObservation
        ColimaOwnedObservation
          { ownedToolchain = ownershipToolchain backend,
            ownedNamespaceKey = ownershipNamespaceKey backend,
            ownedNamespace = ownershipNamespace backend,
            ownedStateRoot = stateRoot,
            ownedRecordPath = recordPath,
            ownedOwner = owner,
            ownedLineage = Text.unpack (sha256Text (Text.pack (ownershipNamespaceKey backend))),
            ownedMachineId = startedMachineIdentity (managedStartObservation observation),
            ownedContextDigest = artifactContextDigest (managedArtifactObservation observation),
            ownedExpectedWall = expected,
            ownedInvocationDigest = invocationDigest,
            ownedSettlementObservation = settlementObservation
          }

preparedColimaInvocation ::
  PreparedColimaWallCall scope specDigest planId configId providerResourceId providerFrame budgetId capabilityId wallSpecId workloadSetId partitionId reservationId fence ->
  String
preparedColimaInvocation (PreparedColimaWallCall _ _ _ _ _ _ (PreparedColimaOperation digest _)) = digest

-- | A settled Colima wall.  Unlike the raw observation, this value retains the
-- exact plan, configuration, provider-resource, wall, epoch, and reservation
-- fence lineage that authorized the call.
data LiveColimaWall
  scope
  specDigest
  planId
  configId
  providerResourceId
  providerFrame
  wallSpecId
  wallEpoch
  fence =
  LiveColimaWall
    String
    ColimaOwnedObservation
    Word64
    (ProviderWallAuthority scope planId ColimaProvider wallSpecId wallEpoch fence)
    (ResourceHandle scope planId providerResourceId ProviderResource Managed Running)
    (OwnershipReceipt scope planId providerResourceId ProviderResource)
    ChangeView
    ChangeView

type role LiveColimaWall nominal nominal nominal nominal nominal nominal nominal nominal nominal

settleColimaWallCall ::
  PreparedColimaWallCall
    scope
    specDigest
    planId
    configId
    providerResourceId
    providerFrame
    budgetId
    capabilityId
    wallSpecId
    workloadSetId
    partitionId
    reservationId
    fence ->
  ColimaWallObservation ->
  ( forall wallEpoch.
    LiveColimaWall
      scope
      specDigest
      planId
      configId
      providerResourceId
      providerFrame
      wallSpecId
      wallEpoch
      fence ->
    result
  ) ->
  Either ReconcileError result
settleColimaWallCall (PreparedColimaWallCall profileName expectedNamespaceKey expectedOwnerSeed stateRoot expectedRecordPath prepared preparedOperation) observation consume =
  case observation of
    ColimaWallOwnershipUnsupported detail -> Left (Unsupported detail)
    ColimaUnownedWallObservation raw -> settleUnowned raw
    ColimaOwnedWallObservation owned
      | ownedStateRoot owned /= stateRoot
          || ownedNamespaceKey owned /= expectedNamespaceKey
          || ownedRecordPath owned /= expectedRecordPath
          || namespaceDockerConfig (ownedNamespace owned) /= expectedRecordPath ++ ".docker"
          || ownedOwner owned /= expectedBoundOwnerFor owned
          || ownedInvocationDigest owned /= preparedColimaInvocationDigest preparedOperation ->
          Left
            ( Failure
                ( FailureDetail
                    "settle Colima provider wall"
                    "the ownership backend returned a record outside the exact plan/fence namespace"
                    DoNotRetry
                )
            )
      | otherwise -> case preparedOperation of
          PreparedColimaOperation _invocationDigest start ->
            withColimaWallSettlement
              prepared
              start
              (ownedSettlementObservation owned)
              ( \authority runningHandle receipt wallChange providerChange ->
                  consume
                    ( LiveColimaWall
                        profileName
                        owned
                        (providerWallCallFence prepared)
                        authority
                        runningHandle
                        receipt
                        wallChange
                        providerChange
                    )
              )
  where
    expectedBoundOwnerFor owned =
      bindColimaOwner
        expectedOwnerSeed
        ColimaOwnershipBackend
          { ownershipToolchain = ownedToolchain owned,
            ownershipNamespaceKey = ownedNamespaceKey owned,
            ownershipPythonPath = trustedApplePythonPath (ownedToolchain owned),
            ownershipColimaPath = trustedAppleColimaPath (ownedToolchain owned),
            ownershipDockerPath = trustedAppleDockerPath (ownedToolchain owned),
            ownershipLimaPath = trustedAppleLimaPath (ownedToolchain owned),
            ownershipNamespace = ownedNamespace owned
          }
    settleUnowned raw = case raw of
      WallRefused detail -> Left (Conflict detail)
      WallAcquireFailed detail -> Left (Failure detail)
      WallAcquireUncertain detail ->
        Left
          ( Failure
              (FailureDetail "acquire Colima provider wall" (Text.pack detail) ReprobeBeforeRetry)
          )
      _ ->
        Left
          ( Unsupported
              ( UnsupportedDetail
                  "settle Colima provider wall"
                  "an unowned Colima observation cannot mint live wall authority"
              )
          )

preparedColimaInvocationDigest :: PreparedColimaOperation scope planId providerResourceId -> String
preparedColimaInvocationDigest (PreparedColimaOperation digest _) = digest

originRecordName :: String -> FilePath
originRecordName ownerSeed =
  ".hostbootstrap-colima-"
    ++ take 32 (Text.unpack (sha256Text (Text.pack ownerSeed)))
    ++ ".origin"

liveColimaWallEpoch ::
  LiveColimaWall scope specDigest planId configId providerResourceId providerFrame wallSpecId wallEpoch fence ->
  Word64
liveColimaWallEpoch (LiveColimaWall _ _ _ authority _ _ _ _) = providerWallEpoch authority

liveColimaWallChange ::
  LiveColimaWall scope specDigest planId configId providerResourceId providerFrame wallSpecId wallEpoch fence ->
  ChangeView
liveColimaWallChange (LiveColimaWall _ _ _ _ _ _ change _) = change

liveColimaProviderChange ::
  LiveColimaWall scope specDigest planId configId providerResourceId providerFrame wallSpecId wallEpoch fence ->
  ChangeView
liveColimaProviderChange (LiveColimaWall _ _ _ _ _ _ _ change) = change

liveColimaDockerContext ::
  LiveColimaWall scope specDigest planId configId providerResourceId providerFrame wallSpecId wallEpoch fence ->
  String
liveColimaDockerContext (LiveColimaWall profileName _ _ _ _ _ _ _) = "colima-" ++ profileName

liveColimaDockerArgs ::
  LiveColimaWall scope specDigest planId configId providerResourceId providerFrame wallSpecId wallEpoch fence ->
  [String] ->
  [String]
liveColimaDockerArgs live args = ["--context", liveColimaDockerContext live] ++ args

-- | Run Docker only through a settled wall's named context.  No code path
-- activates a process-global Docker context.
runLiveColimaDocker ::
  LiveColimaWall scope specDigest planId configId providerResourceId providerFrame wallSpecId wallEpoch fence ->
  [String] ->
  IO (Either String (ExitCode, String, String))
runLiveColimaDocker live args = do
  let LiveColimaWall profileName owned _ _ _ _ _ _ = live
  unchanged <- revalidateTrustedAppleToolchain (ownedToolchain owned)
  case unchanged of
    Left reason -> pure (Left ("live Docker toolchain changed: " ++ reason))
    Right () -> do
      configured <- nativeHostConfigForOwned owned
      result <- case configured of
        Left err -> pure (Left (show err))
        Right config -> fmap (first show) $
          runManagedColimaDockerWith (interpretNativeColima config (ownedNamespace owned))
            (ownedStateRoot owned) profileName (ownedOwner owned) (ownedLineage owned)
            (ownedInvocationDigest owned) (namespaceColimaHome (ownedNamespace owned))
            (namespaceDockerConfig (ownedNamespace owned)) args
      postCall <- revalidateTrustedAppleToolchain (ownedToolchain owned)
      pure $ case postCall of
        Left reason -> Left ("live Docker toolchain changed after execution: " ++ reason)
        Right () -> fmap (\captured -> (capturedExit captured, capturedStdout captured, capturedStderr captured)) result

-- | Conditional cleanup authority exists only for a live wall whose exact
-- plan/fence origin record was established before the profile's first write.
-- Merely observing a compatible same-name profile never grants deletion
-- authority.
data ColimaCleanupAuthority
  scope
  specDigest
  planId
  configId
  providerResourceId
  providerFrame
  wallSpecId
  wallEpoch
  fence =
  ColimaCleanupAuthority
    String
    ColimaOwnedObservation
    Word64
    (ResourceHandle scope planId providerResourceId ProviderResource Managed Running)
    (OwnershipReceipt scope planId providerResourceId ProviderResource)
    Word64

type role ColimaCleanupAuthority nominal nominal nominal nominal nominal nominal nominal nominal nominal

withColimaCleanupAuthority ::
  LiveColimaWall scope specDigest planId configId providerResourceId providerFrame wallSpecId wallEpoch fence ->
  ( ColimaCleanupAuthority
      scope
      specDigest
      planId
      configId
      providerResourceId
      providerFrame
      wallSpecId
      wallEpoch
      fence ->
    result
  ) ->
  Maybe result
withColimaCleanupAuthority
  (LiveColimaWall profileName owned fenceValue authority runningHandle receipt _wallChange _providerChange)
  consume =
  Just
    ( consume
        ( ColimaCleanupAuthority
            profileName
            owned
            (providerWallEpoch authority)
            runningHandle
            receipt
            fenceValue
        )
    )

-- | One independently journaled Running -> Destroyed force-delete call.  The
-- original live origin/epoch authority and the current teardown gate are both
-- retained; acquisition's gate cannot be replayed as cleanup permission.
data PreparedColimaCleanupCall
  scope
  specDigest
  planId
  configId
  providerResourceId
  providerFrame
  wallSpecId
  wallEpoch
  fence where
  PreparedColimaCleanupCall ::
    ColimaCleanupAuthority scope specDigest planId configId providerResourceId providerFrame wallSpecId wallEpoch fence ->
    PreparedGate ->
    PreparedPhaseTransition
      scope
      planId
      providerResourceId
      ProviderResource
      Running
      Destroyed
      operationKey
      callDigest
      attempt
      journalVersion ->
    String ->
    PreparedColimaCleanupCall scope specDigest planId configId providerResourceId providerFrame wallSpecId wallEpoch fence

type role PreparedColimaCleanupCall nominal nominal nominal nominal nominal nominal nominal nominal nominal

prepareColimaCleanupCall ::
  ProjectPlan scope specDigest planId configId cfg ->
  PlannedResource scope planId providerResourceId ProviderResource providerFrame ->
  PreparedGate ->
  ColimaCleanupAuthority scope specDigest planId configId providerResourceId providerFrame wallSpecId wallEpoch fence ->
  IO
    ( Either
        ReconcileError
        (PreparedColimaCleanupCall scope specDigest planId configId providerResourceId providerFrame wallSpecId wallEpoch fence)
    )
prepareColimaCleanupCall plan planned gate authority@(ColimaCleanupAuthority _ _ _machineEpoch handle receipt fenceValue)
  | preparedGateFence gate /= fenceValue =
      pure
        ( Left
            ( Conflict
                ( ConflictDetail
                    (plannedResourceKey planned)
                    ("cleanup gate fence " <> Text.pack (show fenceValue))
                    ("cleanup gate fence " <> Text.pack (show (preparedGateFence gate)))
                    "journal the exact force-destroy operation at the retained wall fence"
                )
            )
        )
  | otherwise =
      case planProviderForceDestroy handle of
        Left err -> pure (Left err)
        Right transition ->
          case plannedProjectPhaseOperation plan planned handle receipt transition (colimaCleanupCallDigest authority) of
            Left err -> pure (Left err)
            Right descriptor ->
              pure $ do
                sealed <- zeroDependencyPreconditions descriptor
                withPreparedPhaseTransition handle receipt transition descriptor sealed gate $ \prepared ->
                  PreparedColimaCleanupCall
                    authority
                    gate
                    prepared
                    (colimaCleanupInvocationDigest (colimaCleanupCallDigest authority) gate)

colimaCleanupInvocationDigest :: Text.Text -> PreparedGate -> String
colimaCleanupInvocationDigest callDigest gate =
  show
    ( Hash.hashWith
        Hash.SHA256
        ( Text.Encoding.encodeUtf8
            ( Text.intercalate
                "\NUL"
                [ "direct-colima-cleanup-invocation-v1",
                  callDigest,
                  preparedGatePlan gate,
                  preparedGateOperation gate,
                  preparedGateSession gate,
                  Text.pack (show (preparedGateFence gate)),
                  Text.pack (show (preparedGateAttempt gate)),
                  Text.pack (show (preparedGateJournalVersion gate))
                ]
            )
        )
    )

colimaCleanupCallDigest ::
  ColimaCleanupAuthority scope specDigest planId configId providerResourceId providerFrame wallSpecId wallEpoch fence ->
  Text.Text
colimaCleanupCallDigest (ColimaCleanupAuthority profileName owned epoch handle receipt fenceValue) =
  Text.pack
    ( show
        ( Hash.hashWith
            Hash.SHA256
            ( Text.Encoding.encodeUtf8
                ( Text.intercalate
                    "\NUL"
                    [ "direct-colima-force-destroy-v1",
                      Text.pack profileName,
                      Text.pack (ownedOwner owned),
                      Text.pack (ownedLineage owned),
                      Text.pack (ownedMachineId owned),
                      Text.pack (ownedContextDigest owned),
                      Text.pack (show epoch),
                      Text.pack (show (resourceHandleGeneration handle)),
                      ownershipReceiptOperationKey receipt,
                      Text.pack (show fenceValue)
                    ]
                )
            )
        )
    )

-- | Delete a profile only after re-observing the stable identity retained by
-- the exact create receipt.  One kernel-held exclusion process spans the
-- observe, compare, and delete calls, so a cooperating same-name replacement
-- cannot enter their interval.  A replacement is a structured conflict and is
-- left untouched.
runColimaCleanup ::
  PreparedColimaCleanupCall scope specDigest planId configId providerResourceId providerFrame wallSpecId wallEpoch fence ->
  IO
    ( Either
        ReconcileError
        (PhaseAdvance scope planId providerResourceId ProviderResource Destroyed)
    )
runColimaCleanup
  (PreparedColimaCleanupCall (ColimaCleanupAuthority profileName owned _expectedEpoch handle _receipt _fenceValue) _gate preparedTransition cleanupInvocation) = do
      backendResult <- discoverDirectColimaBackendAt (ownedRecordPath owned) profileName (ownedNamespaceKey owned)
      case backendResult of
        Left err -> pure (Left err)
        Right backend
          | not (backendMatchesOwned backend owned) ->
              pure
                ( Left
                    ( Failure
                        ( FailureDetail
                            "release Colima profile"
                            "the freshly resolved tool/namespace route differs from the retained live ownership route"
                            DoNotRetry
                        )
                    )
                )
          | otherwise -> do
              configured <- nativeHostConfig backend
              result <- case configured of
                Left err -> pure (Left err)
                Right config -> do
                  let namespace = ownedNamespace owned
                      diskPath = namespaceColimaHome namespace </> "_lima" </> "_disks" </> ("colima-" ++ profileName) </> "datadisk"
                  fmap (first cleanupMutationError) $
                    cleanupManagedColimaProfileWith (interpretNativeColima config namespace)
                      (ownedStateRoot owned) profileName (ownedOwner owned) (ownedLineage owned)
                      (ownedInvocationDigest owned) cleanupInvocation (namespaceColimaHome namespace)
                      (namespaceDockerConfig namespace) diskPath
              postCall <- revalidateOwnershipBackend backend
              pure $ do
                case postCall of
                  Left err -> Left err
                  Right () -> Right ()
                result
                completePreparedPhaseTransition preparedTransition (resourceHandleGeneration handle)

cleanupMutationError :: ColimaProfileMutationFault -> ReconcileError
cleanupMutationError fault@ColimaMutationProfileConflict {} = cleanupConflict fault
cleanupMutationError fault@ColimaMutationOwnershipRefused {} = cleanupConflict fault
cleanupMutationError fault = cleanupFailure "run native Colima cleanup" (show fault)

cleanupConflict :: ColimaProfileMutationFault -> ReconcileError
cleanupConflict fault =
  Conflict
    ( ConflictDetail
        "release Colima profile"
        "the retained native Managed lineage and cleanup invocation"
        (Text.pack (show fault))
        "leave mismatched ownership state untouched and resume its original cleanup invocation"
    )

backendMatchesOwned :: ColimaOwnershipBackend -> ColimaOwnedObservation -> Bool
backendMatchesOwned backend owned =
  ownershipToolchain backend == ownedToolchain owned
    && ownershipNamespaceKey backend == ownedNamespaceKey owned
    && ownershipNamespace backend == ownedNamespace owned

cleanupFailure :: Text.Text -> String -> ReconcileError
cleanupFailure operation message =
  Failure
    ( FailureDetail
        operation
        (Text.pack message)
        ReprobeBeforeRetry
    )

failed :: String -> RecoveryDisposition -> WallAcquireObservation
failed message recovery =
  WallAcquireFailed
    (FailureDetail "acquire Colima provider wall" (Text.pack message) recovery)

reconcileErrorObservation :: ReconcileError -> ColimaWallObservation
reconcileErrorObservation err =
  case err of
    Conflict detail -> ColimaUnownedWallObservation (WallRefused detail)
    SafetyRefusal detail ->
      ColimaUnownedWallObservation (failed (show detail) DoNotRetry)
    Unsupported detail ->
      ColimaWallOwnershipUnsupported detail
    Failure detail ->
      ColimaUnownedWallObservation (WallAcquireFailed detail)
