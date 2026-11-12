{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ImpredicativeTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module LifecycleSpec (tests) where

import Control.Exception (SomeException, bracket_, displayException, evaluate, try)
import Data.Bits ((.&.), shiftR)
import qualified Crypto.Hash as Hash
import qualified Data.ByteArray as ByteArray
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Char (ord)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (findIndex, isInfixOf, isPrefixOf, sort, tails)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Authority
    ( AuthorityError (..)
    , InstalledProjectIdentity
    , ProjectVerb (ProjectUp)
    , RootInvocationAuthority
    , VerbUp
    , brokerEpochWord
    , commandAuthorityEpoch
    , commandAuthorityFrame
    , installedProjectName
    , rootAuthorityEpoch
    , rootAuthorityVerb
    , rootScopeAuthority
    )
import qualified HostBootstrap.Authority as Authority
import qualified HostBootstrap.Authority.Testing as AuthorityFixture
import qualified HostBootstrap.Chain as Chain
import HostBootstrap.Cluster.Lifecycle
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Config.Schema (ValidatedConfig, withValidatedConfig)
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Config.Vocab as V
import HostBootstrap.Context (ResourceEnvelope (..))
import qualified HostBootstrap.Context as Context
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.Lift (ContainerLift (..), ContainerPlacement (ProviderGuestContainer), InVMSelfPath (InVMSelfPath), currentSelfRef, emptyVMStack, inContainer, localContext)
import qualified HostBootstrap.Lifecycle.Execution as Execution
import qualified HostBootstrap.Lifecycle.Execution.Core as ExecutionCore
import HostBootstrap.Lifecycle.Mode
    ( BoundInvocationRecovery
    , BoundRunLease
    , LeaseConflict
    , LifecycleProfile
    , ModeError (..)
    , NormalActiveRecovery
    , OpenRevisionKind (..)
    , ProductionMode
    , ProjectModeLease
    , UnboundRunLease
    , VerifiedPlanSnapshot
    , bindRunLease
    , bindRunLeaseWithPlanRecovery
    , boundInvocationRecoveryRevisionKind
    , boundInvocationRecoveryRunText
    , boundRunLeasePlanDigest
    , boundRunLeaseRunText
    , boundRunLeaseSpecDigest
    , normalActiveRecoveryRunText
    , invocationCloseKeyText
    , leaseConflictMessage
    , mkInvocationCloseKey
    , modeErrorMessage
    , planSnapshotCanonicalBytes
    , planSnapshotPlanDigest
    , planSnapshotRevision
    , planSnapshotRunText
    , planSnapshotSpecDigest
    , productionActiveMode
    , productionRootAuthority
    , productionRootModeLease
    , productionRootUnboundLease
    , projectModeLeaseEpoch
    , recordProductionInvocationAcknowledgment
    , recoveredProductionProfileCanonicalBytes
    , recoveredProductionProfileConfigDigest
    , recoveredProductionProfileEpoch
    , recoveredProductionProfilePlanDigest
    , recoveredProductionProfileProjectName
    , recoveredProductionProfileRevision
    , recoveredProductionProfileRevisionKind
    , recoveredProductionProfileRunText
    , recoveredProductionProfileSpecDigest
    , recoveredProductionProfileStoreIdentity
    , unboundRunLeaseRunText
    , withProductionLifecycleProfile
    , withProductionRoot
    , withBoundPlanSnapshotKernel
    , withFreshExistingBoundReverseRootKernel
    , withResumedExistingBoundReverseRootKernel
    , withRecoveredProductionLifecycleProfile
    )
import HostBootstrap.Lifecycle.Prepared (decodeFields, encodeFields, preparedGateJournalVersion)
import qualified HostBootstrap.Lifecycle.Session as Session
import qualified HostBootstrap.Lifecycle.Session.Testing as Transaction
import HostBootstrap.ProjectPlan
    ( ProjectPlan
    , StablePlanSnapshot
    , planDraftsFromValidatedBuilder
    , forward
    , renderSnapshot
    , stablePlanSnapshotBytes
    , stablePlanSnapshotConfigDigest
    , stablePlanSnapshotDigest
    , stablePlanSnapshotSpecDigest
    )
import HostBootstrap.ProjectPlan.Construct (withProjectPlan)
import HostBootstrap.ProjectPlan.Snapshot
    ( BoundPlanSnapshot
    , PlanDigestBinding
    , SnapshotError (..)
    , boundPlanSnapshotBytes
    , withPlanDigestBinding
    , withPersistedPlanSnapshot
    , withBoundPlanSnapshot
    , withReauthorizedBoundPlanSnapshotKernel
    )
import HostBootstrap.ProjectRoot
    ( CanonicalProjectRoot
    , canonicalProjectRootPath
    , withCanonicalProjectRoot
    )
import HostBootstrap.Protected
    ( Expectation (ExpectAbsent, ExpectVersion)
    , ProtectedError (ProtectedIOFailure)
    , ProtectedRecord (protectedRecordBytes, protectedRecordVersion)
    , ProtectedStore
    , RecordKey
    , compareAndDeleteProtectedRecord
    , compareAndSwapProtectedRecord
    , listProtectedRecords
    , mkRecordKey
    , mkRecordName
    , openProtectedStore
    , protectedStoreIdentity
    , protectedStoreIdentityText
    , protectedStoreRoot
    , readProtectedRecord
    , recordKeyText
    , recordTupleSeparator
    , recordVersionWord
    , tryProtectedEntry
    , withProtectedEntry
    )
import HostBootstrap.Step
    ( StepFrame (StepFrame)
    , StepObservation (StepChanged)
    , StepPlan
    , contextInitStep
    , ensureStep
    , declaresProviderResource
    , deployVMStep
    , descendsVia
    , mkStepPlan
    , providerResourceAtCurrentFrame
    )
import HostBootstrap.Reconcile (stepExecutionFor)
import HostBootstrap.Substrate (Arch (..), Substrate (..), SubstrateName (..))
import qualified SourceGuard
import System.Directory
    ( createDirectory
    , doesDirectoryExist
    , removeDirectory
    , removeFile
    , renameDirectory
    , renameFile
    )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (<.>), (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Unsafe.Coerce (unsafeCoerce)

rootPath :: FilePath
rootPath = rootDir </> "demo"

rootDir :: FilePath
#ifdef mingw32_HOST_OS
rootDir = "C:\\srv"
#else
rootDir = "/srv"
#endif

prod :: ClusterPlan
prod = resolvePlan "demo" rootPath Production

test1 :: ClusterPlan
test1 = resolvePlan "demo" rootPath (fixtureHarnessProfile "case1")

fixtureHarnessProfile :: String -> ClusterProfile
fixtureHarnessProfile = either (error . show) id . mkTestCaseProfile . Text.pack

tests :: TestTree
tests =
    testGroup
        "LifecycleSpec"
        [ testGroup "resolvePlan" planCases
        , testGroup "cluster drivers" driverCases
        , testGroup "profiles are distinct" profileCases
        , testGroup "accelerator ingress" acceleratorIngressCases
        , testGroup "NVIDIA runtime probe" nvidiaRuntimeCases
        , testGroup "NVIDIA device plugin" nvidiaDevicePluginCases
        , testGroup "multi-node cordon" nodeCordonCases
        , testGroup "never-delete-.data" dataInvariantCases
        , testGroup "persisted project snapshots" snapshotPersistenceCases
        , testGroup "existing bound Production snapshots" existingBoundSnapshotCases
        , testGroup "recovered Production lifecycle profile" recoveredProductionProfileCases
        , testGroup "recovery journal bookkeeping" recoveryJournalBookkeepingCases
        , testGroup "live lifecycle prepare" livePrepareCases
        ]

livePrepareCases :: [TestTree]
livePrepareCases =
    [ testCase "matching retained lifecycle evidence permits an actual journal prepare" $
        withLivePrepareFixture livePrepareGraph 0 $ \store _plan _authority _cursor _execution callbacks prepare -> do
            prepared <- prepare
            version <- either (assertFailure . show) pure prepared
            readIORef callbacks >>= (@?= 1)
            (key, physicalVersion, _) <- solePrepareRecord store "op."
            physicalVersion @?= version
            observed <- withProtectedEntry store $ \session -> Right <$> Transaction.readTransactionRecord session key
            durable <- either (fail . show) (either (fail . show) (maybe (assertFailure "the prepared operation disappeared") pure)) observed
            recordVersionWord (Transaction.transactionRecordVersion durable) @?= version
            decodeFields (Transaction.transactionRecordPayload durable) @?= ["EffectOutcomeUnknown", "live-prepare", "1", "1"]
    , testCase "prepare refuses a changed project mode epoch before registration" $
        withLivePrepareFixture livePrepareGraph 0 $ \store _plan authority _cursor _execution callbacks prepare -> do
            expected <- changePrepareModeEpoch store authority
            assertPrepareRefusal store callbacks prepare expected
    , testCase "prepare refuses a real broker allocation rotation before registration" $
        withLivePrepareFixture livePrepareGraph 0 $ \store _plan authority _cursor _execution callbacks prepare -> do
            Fixture.withFixtureInstalledProject $ \project -> do
                allocated <- withProtectedEntry store $ \session -> fmap Right $ do
                    fresh <- AuthorityFixture.withFreshBrokerEpochKernel session project $ \epoch -> do
                        brokerEpochWord epoch @?= brokerEpochWord (commandAuthorityEpoch authority) + 1
                        pure (Right ())
                    either (fail . show) pure fresh
                either (fail . show) pure allocated
            assertPrepareRefusal store callbacks prepare
                (Session.SessionAuthorityFailure (AuthorityInvalidIdentity "the recorded broker generation does not match the allocated counter"))
    , testCase "prepare refuses a missing bound lease before registration" $
        withLivePrepareFixture livePrepareGraph 0 $ \store _plan _authority _cursor _execution callbacks prepare -> do
            (key, _, _) <- solePrepareRecord store "lease."
            deleteRecord store key
            assertPrepareRefusal store callbacks prepare
                (Session.SessionAcquisitionBindingMismatch "live lease record" (recordKeyText key) "absent")
    , testCase "prepare refuses a newer same-byte bound lease before registration" $
        withLivePrepareFixture livePrepareGraph 0 $ \store _plan _authority _cursor _execution callbacks prepare -> do
            (key, originalVersion, originalBytes) <- solePrepareRecord store "lease."
            advanceRecordVersion store key
            changed <- requireRecord store key
            protectedRecordBytes changed @?= originalBytes
            let observedVersion = recordVersionWord (protectedRecordVersion changed)
            observedVersion @?= originalVersion + 1
            assertPrepareRefusal store callbacks prepare
                (Session.SessionAcquisitionBindingMismatch "live lease record version" (Text.pack (show originalVersion)) (Text.pack (show observedVersion)))
    , testCase "prepare refuses observed frozen lease data before registration" $
        withLivePrepareFixture livePrepareGraph 0 $ \store _plan _authority _cursor _execution callbacks prepare -> do
            (key, _, bytes) <- solePrepareRecord store "lease."
            frozen <- case decodeFields bytes of
                ["bound", epoch, spec, digest] ->
                    pure (encodeFields ["frozen", epoch, "observed-freeze", "observed-resource-set", spec, digest, spec, digest])
                fields -> assertFailure ("expected the genuine bound lease, got " <> show fields)
            replaceRawRecord store key frozen
            assertPrepareRefusal store callbacks prepare
                (Session.SessionAcquisitionBindingMismatch "live lease state" "bound" "frozen")
    , testCase "prepare refuses a changed real snapshot binding before registration" $
        withLivePrepareFixture livePrepareGraph 0 $ \store plan _authority _cursor _execution callbacks prepare ->
            Fixture.withFixtureRootChainEvidence livePrepareGraph $ \otherStore otherPlan _otherAuthority _otherCursor -> do
                let retained = renderSnapshot plan
                    replacement = renderSnapshot otherPlan
                stablePlanSnapshotSpecDigest replacement @?= stablePlanSnapshotSpecDigest retained
                assertBool "the independently persisted plan really differs" (stablePlanSnapshotDigest replacement /= stablePlanSnapshotDigest retained)
                (key, _, _) <- solePrepareRecord store "snapshot."
                (_, _, replacementBytes) <- solePrepareRecord otherStore "snapshot."
                replaceRawRecord store key replacementBytes
                assertPrepareRefusal store callbacks prepare
                    (Session.SessionAcquisitionBindingMismatch "live snapshot plan digest" (stablePlanSnapshotDigest retained) (stablePlanSnapshotDigest replacement))
    , testCase "prepare refuses another actual descriptor frame in the same plan before registration" $
        withLivePrepareFixture livePrepareTwoFrameGraph 1 $ \store _plan authority _cursor execution callbacks prepare -> do
            let retainedFrame = commandAuthorityFrame authority
                observedFrame = Execution.stepExecutionFrame execution
            assertBool "the real descriptor belongs to the other admitted frame" (observedFrame /= retainedFrame)
            assertPrepareRefusal store callbacks prepare
                (Session.SessionCursorBindingMismatch "descriptor frame" retainedFrame observedFrame)
    , testCase "an initially stale Chain request creates no journal bookkeeping" $ do
        callbacks <- newIORef (0 :: Int)
        let graph _store frame = either (error . show) id $ mkStepPlan
                [contextInitStep "stale entry" frame (\_ -> modifyIORef' callbacks (+ 1) >> pure StepChanged)]
        Fixture.withFixtureRootChainEvidence graph $ \store plan authority cursor -> do
            expected <- changePrepareModeEpoch store authority
            before <- protectedRecordImage store
            self <- currentSelfRef (InVMSelfPath "/usr/local/bin/hostbootstrap-demo")
            result <- fmap (either (\(reason, _, _) -> Left reason) Right) (Chain.runChainFromFrameWithDescentFailure livePrepareHost self store plan authority cursor (\_ _ _ _ -> pure (Right ())))
            result @?= Left (Session.sessionErrorMessage expected)
            readIORef callbacks >>= (@?= 0)
            protectedRecordImage store >>= (@?= before)
    , testCase "prepare entry validates before journal and operation writes" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            -- DEVELOPMENT_PLAN/rationale.md#prepare-admission-rechecks-the-retained-live-binding
            description <- SourceGuard.readPackageDescription
            let readModule name = do
                    path <- SourceGuard.libraryModulePath packageRoot description name
                    Text.unpack . TextEncoding.decodeUtf8 <$> ByteString.readFile path
                body name source = either assertFailure pure (SourceGuard.haskellDefinitionTokens name source)
                retains label fragment tokens = assertBool label (SourceGuard.haskellTokens fragment `isInfixOf` tokens)
            session <- readModule "HostBootstrap.Lifecycle.Session"
            mode <- readModule "HostBootstrap.Lifecycle.Mode"
            chain <- readModule "HostBootstrap.Chain"
            sessionExports <- maybe (assertFailure "Session has no explicit export list") pure (SourceGuard.moduleExportTokens "HostBootstrap.Lifecycle.Session" session)
            modeExports <- maybe (assertFailure "Mode has no explicit export list") pure (SourceGuard.moduleExportTokens "HostBootstrap.Lifecycle.Mode" mode)
            retains "Session exports the fixed entry" "withLifecyclePrepareEntry" sessionExports
            retains "Mode reexports the same fixed entry" "withLifecyclePrepareEntry" modeExports
            retains "the cursor stays abstract" "LifecycleCursor ," sessionExports
            assertBool "no cursor constructor is public" (not (SourceGuard.haskellTokens "LifecycleCursor (" `isInfixOf` sessionExports))
            definitions <- either assertFailure pure (SourceGuard.haskellDefinitionNames mode)
            assertBool "Mode owns no duplicate entry" ("withLifecyclePrepareEntry" `notElem` definitions)
            retains "Mode imports the actual fixed Session entry" "withLifecyclePrepareEntry" =<< maybe (assertFailure "Mode has no explicit Session import") pure (SourceGuard.moduleImportTokens "HostBootstrap.Lifecycle.Session" mode)
            let sessionTokens = SourceGuard.haskellTokens session
            retains "the fixed entry links authority and cursor indices"
                "withLifecyclePrepareEntry :: ProtectedSession session -> CommandAuthority scope planId frame brokerGeneration verb ExecutePhase -> LifecycleCursor scope planId frame brokerGeneration verb ExecutePhase -> Text -> IO (Either SessionError result) -> IO (Either SessionError result)"
                sessionTokens
            retains "the private cursor retains the rank-2 original validator"
                "LifecyclePhase phase -> (forall session. ProtectedSession session -> IO (Either SessionError ())) -> LifecycleCursor scope planId frame brokerGeneration verb phase"
                sessionTokens
            admission <- body "withAcquisitionJournal" mode
            retains "acquisition admission retains its actual Mode validator"
                "openAcquisitionJournalKernel admission store session validateLiveBinding coordinates" admission
            retains "the retained validator checks the actual allocated broker"
                "allocated <- validateAllocatedBrokerEpochKernel session epoch" admission
            entry <- body "withLifecyclePrepareEntry" session
            retains "live checks refuse before the continuation"
                "live <- validateLive session case live of Left failure -> pure (Left failure) Right () -> do current <- validateCurrentLifecycleCursor session cursor case current of Left failure -> pure (Left failure) Right () -> action" entry
            mapM_
                ( \(name, fragment) -> do
                    tokens <- body name session
                    retains (name <> " retains the original validator") fragment tokens
                )
                [ ("openCurrentLifecycleCursorInEntry", "binding verb sourcePhase validateLive")
                , ("openLifecycleCursorInEntry", "binding recordedVerb requestedPhase validateLive")
                , ("resumeCurrentLifecycleCursor", "recorded verb recordedPhase validateLive")
                , ("advanceLifecycleCursorInEntry", "binding verb successorPhase validateLive")
                ]
            interpreter <- body "runChainFromFrameWithDescentObserved" chain
            retains "the opening validates before recovery or bookkeeping"
                "openChainJournal = inPrepareEntry current $ \\protected -> do swept <- recoverAbandonedSessions" interpreter
            retains "each node validates its actual descriptor before registration"
                "runNode session fence permit planned execution runtime = do prepared <- inPrepareEntry (stepExecutionFrame execution) $ \\protected -> do registered <- registerAll" interpreter
            retains "the shared entry stays inside the same protected action"
                "inPrepareEntry frame action = inEntry $ \\protected -> withLifecyclePrepareEntry protected authority cursor frame (action protected)" interpreter
            length (filter (== "withStepPreparedGate") interpreter) @?= 1
            length (filter (== "withPreparedGate") interpreter) @?= 1
            retains "the projected prepare remains under the checked node entry"
                "Right afterRegistration -> openProjections protected session commandEpoch fence runtime afterRegistration" interpreter
    ]

withLivePrepareFixture ::
    (ProtectedStore -> StepFrame -> StepPlan) ->
    Int ->
    ( forall projectId specDigest planId configId frame brokerGeneration.
      ProtectedStore ->
      ProjectPlan (Production projectId) specDigest planId configId Fixture.ProjectConfig ->
      Authority.CommandAuthority (Production projectId) planId frame brokerGeneration VerbUp Authority.ExecutePhase ->
      Session.LifecycleCursor (Production projectId) planId frame brokerGeneration VerbUp Authority.ExecutePhase ->
      Execution.StepExecution (Production projectId) planId ->
      IORef Int ->
      IO (Either Session.SessionError Word64) ->
      IO result
    ) ->
    IO result
withLivePrepareFixture graph selected use =
    Fixture.withFixtureRootChainEvidence graph $ \store plan authority cursor -> do
        callbacks <- newIORef (0 :: Int)
        carrier <- ExecutionCore.newResourceCarrierCore
        runtime <- ExecutionCore.newStepRuntimeCore carrier
        planned <- case drop selected (NonEmpty.toList (forward plan)) of
            first : _ -> pure first
            [] -> assertFailure "the selected genuine plan node is absent"
        let execution = stepExecutionFor plan livePrepareHost runtime planned
            digest = stablePlanSnapshotDigest (renderSnapshot plan)
            epoch = commandAuthorityEpoch authority
        opened <- withProtectedEntry store $ \session -> do
            permit <- either (fail . show) pure =<< Session.openProjectJournal session digest
            (operationSession, afterOpen) <- either (fail . show) pure =<< Session.openOperationSession session epoch digest "live-prepare" permit
            fence <- either (fail . show) pure =<< Session.establishInitialFence session afterOpen 1
            pure (Right (operationSession, fence, afterOpen))
        (operationSession, fence, permit) <- either (fail . show) pure opened
        let prepare = do
                entered <- withProtectedEntry store $ \session ->
                    fmap Right $
                        Session.withLifecyclePrepareEntry session authority cursor (Execution.stepExecutionFrame execution) $ do
                            registered <- Session.registerOperationIntent session operationSession (Execution.stepExecutionOperationKey execution) Session.NoHistory permit
                            case registered of
                                Left failure -> pure (Left failure)
                                Right afterIntent ->
                                    Session.withStepPreparedGate session operationSession epoch fence execution "EffectOutcomeUnknown" afterIntent $ \gate _next -> do
                                        modifyIORef' callbacks (+ 1)
                                        pure (Right (preparedGateJournalVersion gate))
                either (fail . show) pure entered
        use store plan authority cursor execution callbacks prepare

livePrepareHost :: HostConfig
livePrepareHost = HostConfig (Substrate LinuxCpu Amd64) Map.empty

livePrepareGraph :: ProtectedStore -> StepFrame -> StepPlan
livePrepareGraph _store frame = either (error . show) id $ mkStepPlan
    [contextInitStep "live prepare" frame (const (pure StepChanged))]

livePrepareTwoFrameGraph :: ProtectedStore -> StepFrame -> StepPlan
livePrepareTwoFrameGraph _store frame = either (error . show) id $ mkStepPlan
    [ descendsVia localContext (contextInitStep "live prepare root" frame (const (pure StepChanged)))
    , ensureStep "live-prepare-child" "live prepare child" (StepFrame "live-prepare-child" "Child") (const (pure StepChanged))
    ]

assertPrepareRefusal :: ProtectedStore -> IORef Int -> IO (Either Session.SessionError Word64) -> Session.SessionError -> IO ()
assertPrepareRefusal store callbacks prepare expected = do
    before <- protectedRecordImage store
    prepare >>= (@?= Left expected)
    readIORef callbacks >>= (@?= 0)
    protectedRecordImage store >>= (@?= before)

solePrepareRecord :: ProtectedStore -> Text.Text -> IO (RecordKey, Word64, ByteString.ByteString)
solePrepareRecord store prefix = do
    image <- protectedRecordImage store
    case [(exactRecordKey key, version, bytes) | (key, version, bytes) <- image, prefix `Text.isPrefixOf` key] of
        [row] -> pure row
        rows -> assertFailure ("expected exactly one " <> Text.unpack prefix <> " record, got " <> show rows)

changePrepareModeEpoch :: ProtectedStore -> Authority.CommandAuthority scope planId frame brokerGeneration verb phase -> IO Session.SessionError
changePrepareModeEpoch store authority = do
    (key, _, bytes) <- solePrepareRecord store "mode."
    let held = brokerEpochWord (commandAuthorityEpoch authority)
        changed = held + 1
    decodeFields bytes @?= ["production", Text.pack (show held)]
    replaceRawRecord store key (encodeFields ["production", Text.pack (show changed)])
    pure (Session.SessionAcquisitionBindingMismatch "live mode broker epoch" (Text.pack (show held)) (Text.pack (show changed)))

-- These exercise the public journal kernel. The source check below holds its
-- adoption by Mode; no later migration or abandoned-run API is invoked here.
recoveryJournalBookkeepingCases :: [TestTree]
recoveryJournalBookkeepingCases =
    [ testCase "journal bookkeeping creates only the coordinator and project once" $
        withRecoveryJournalStore $ \store -> do
            let coordinate = "recovery-journal-coordinate"
                projectKey = exactRecordKey ("project." <> fixtureRecordName coordinate)
            coordinator <- either (fail . show) pure (Transaction.coordinatorKey coordinate)
            readRecord store projectKey >>= (@?= Nothing)
            readRecord store coordinator >>= (@?= Nothing)
            opened <- withProtectedEntry store (\session -> Right <$> Session.openProjectJournal session coordinate)
            permit <- either (fail . show) (either (fail . show) pure) opened
            project <- requireRecord store projectKey
            committed <- requireRecord store coordinator
            protectedRecordBytes project @?= Transaction.stampTarget 1 (encodeFields ["open"])
            recordVersionWord (protectedRecordVersion project) @?= 1
            Transaction.decodeCoordinator (protectedRecordBytes committed) @?= Right (Transaction.CoordinatorIdle 1)
            recordVersionWord (protectedRecordVersion committed) @?= 3
            Session.projectPermitVersion permit @?= recordVersionWord (protectedRecordVersion committed)
            before <- protectedRecordImage store
            sort [key | (key, _, _) <- before] @?= sort (map recordKeyText [coordinator, projectKey])
            reopened <- withProtectedEntry store (\session -> Right <$> Session.openProjectJournal session coordinate)
            fmap (fmap Session.projectPermitVersion) reopened @?= Right (Right (Session.projectPermitVersion permit))
            protectedRecordImage store >>= (@?= before)
    , testCase "journal bookkeeping replays a published project-open transaction once" $
        withRecoveryJournalStore $ \store -> do
            let coordinate = "recovery-journal-coordinate"
                projectKey = exactRecordKey ("project." <> fixtureRecordName coordinate)
                descriptor =
                    Transaction.TransactionDescriptor
                        { Transaction.descriptorSequence = 1
                        , Transaction.descriptorPlan = coordinate
                        , Transaction.descriptorKind = Transaction.TxnOpenProject
                        , Transaction.descriptorTargets =
                            [Transaction.projectTransactionTarget projectKey Nothing (encodeFields ["open"])]
                        }
            coordinator <- either (fail . show) pure (Transaction.coordinatorKey coordinate)
            writeRawRecord store coordinator (Transaction.encodeCoordinator (Transaction.CoordinatorApplying descriptor))
            published <- requireRecord store coordinator
            readRecord store projectKey >>= (@?= Nothing)
            opened <- withProtectedEntry store (\session -> Right <$> Session.openProjectJournal session coordinate)
            permit <- either (fail . show) (either (fail . show) pure) opened
            project <- requireRecord store projectKey
            committed <- requireRecord store coordinator
            protectedRecordBytes project @?= Transaction.stampTarget 1 (encodeFields ["open"])
            recordVersionWord (protectedRecordVersion project) @?= 1
            Transaction.decodeCoordinator (protectedRecordBytes committed) @?= Right (Transaction.CoordinatorIdle 1)
            recordVersionWord (protectedRecordVersion committed)
                @?= recordVersionWord (protectedRecordVersion published) + 1
            Session.projectPermitVersion permit @?= recordVersionWord (protectedRecordVersion committed)
            before <- protectedRecordImage store
            sort [key | (key, _, _) <- before] @?= sort (map recordKeyText [coordinator, projectKey])
            reopened <- withProtectedEntry store (\session -> Right <$> Session.openProjectJournal session coordinate)
            fmap (fmap Session.projectPermitVersion) reopened @?= Right (Right (Session.projectPermitVersion permit))
            protectedRecordImage store >>= (@?= before)
    , testCase "a Closing journal refuses bookkeeping without changing an existing fence" $
        withRecoveryJournalStore $ \store -> do
            let coordinate = "recovery-journal-coordinate"
                fenceKey = exactRecordKey ("fence." <> fixtureRecordName coordinate)
            opened <- withProtectedEntry store (\session -> Right <$> Session.openProjectJournal session coordinate)
            permit <- either (fail . show) (either (fail . show) pure) opened
            closing <- withProtectedEntry store (\session -> Right <$> Session.beginClosingProject session coordinate 7 permit)
            either (fail . show) (either (fail . show) (const (pure ()))) closing
            writeRawRecord store fenceKey (encodeFields ["FenceObserved", "18446744073709551615"])
            before <- protectedRecordImage store
            refused <- withProtectedEntry store (\session -> Right <$> Session.openProjectJournal session coordinate)
            fmap (fmap Session.projectPermitVersion) refused @?= Right (Left (Session.SessionProjectClosing coordinate))
            protectedRecordImage store >>= (@?= before)
    , testCase "Mode obtains its internal fence witness before the recovery protocol" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            -- DEVELOPMENT_PLAN/rationale.md#fence-producers-follow-the-held-permit
            description <- SourceGuard.readPackageDescription
            path <- SourceGuard.libraryModulePath packageRoot description "HostBootstrap.Lifecycle.Mode"
            source <- Text.unpack . TextEncoding.decodeUtf8 <$> ByteString.readFile path
            mapM_
                ( \name -> do
                    body <- either assertFailure pure (SourceGuard.haskellDefinitionTokens name source)
                    let opening =
                            SourceGuard.haskellTokens
                                "journalForFence <- openProjectJournal session planDigest fenced <- case journalForFence of Left failure -> pure (Left failure) Right permit -> fenceOldPermits session permit"
                        markers =
                            map
                                SourceGuard.haskellTokens
                                [ "journalForFence <- openProjectJournal session planDigest"
                                , "fenced <- case journalForFence"
                                , "manifested <- verifySessionManifest session planDigest"
                                , "journal <- openProjectJournal session planDigest"
                                , "interpretRecordedSessions session epoch manifest fencedPermits permit"
                                , "admitCurrentBroker session epoch manifest fencedPermits interpreted"
                                ]
                    assertBool (name <> " lost early journal refusal propagation") (opening `isInfixOf` body)
                    positions <-
                        mapM
                            ( \marker ->
                                maybe
                                    (assertFailure (name <> " lost recovery stage " <> show marker))
                                    pure
                                    (findIndex (isPrefixOf marker) (tails body))
                            )
                            markers
                    assertBool (name <> " changed recovery protocol order") (and (zipWith (<) positions (drop 1 positions)))
                )
                ["settleAndAdmit", "withAbandonedHarnessRun"]
    ]

withRecoveryJournalStore :: (ProtectedStore -> IO ()) -> IO ()
withRecoveryJournalStore use =
    withSystemTempDirectory "hostbootstrap-recovery-journal" $ \directory -> do
        opened <- openProtectedStore (directory </> "protected")
        store <- either (fail . show) pure opened
        use store

planCases :: [TestTree]
planCases =
    [ testCase "production: fixed name and .data path" $ do
        clusterName prod @?= "demo"
        dataPath prod @?= rootPath </> ".data"
        derivedStatePath prod @?= rootPath </> ".cluster" </> "demo"
        clusterDriver prod @?= KindDriver
        clusterConfigFile prod @?= Nothing
        clusterNodeSuffixes prod @?= ["control-plane"]
    , testCase "test: per-case isolated name and path" $ do
        clusterName test1 @?= "demo-test-case1"
        dataPath test1 @?= rootPath </> ".test_data" </> "case1"
        derivedStatePath test1 @?= rootPath </> ".cluster" </> "demo-test-case1"
        clusterConfigFile test1 @?= Nothing
        clusterNodeSuffixes test1 @?= ["control-plane"]
    , testCase "production maps host, VM, and container roots to their canonical .data child" $ do
        let vmRoot = rootDir </> "vm" </> "demo"
            containerRoot = rootDir </> "workspace" </> "demo"
            resolvedData root = dataPath (resolvePlan "demo" root Production)
        resolvedData rootPath @?= durableDataPath rootPath
        resolvedData vmRoot @?= durableDataPath vmRoot
        resolvedData containerRoot @?= durableDataPath containerRoot
    ]

driverCases :: [TestTree]
driverCases =
    [ testCase "Linux GPU accelerator plan selects nvkind" $ do
        let plan = resolveAcceleratorPlan "demo" rootPath Production (Substrate LinuxGpu Amd64)
        clusterDriver plan @?= NvkindDriver
        clusterConfigFile plan @?= Nothing
        clusterNodeSuffixes plan @?= ["control-plane", "worker"]
    , testCase "Linux CPU accelerator plan keeps kind" $ do
        let plan = resolveAcceleratorPlan "demo" rootPath Production (Substrate LinuxCpu Amd64)
        clusterDriver plan @?= KindDriver
    , testCase "a resolved plan names no template, so the library chooses none" $ do
        clusterConfigFile (resolvePlanWithDriver "demo" rootPath Production KindDriver) @?= Nothing
        clusterConfigFile (resolvePlanWithDriver "demo" rootPath Production NvkindDriver) @?= Nothing
    ]

profileCases :: [TestTree]
profileCases =
    [ testCase "production and test resolve distinct cluster names" $
        assertBool "names differ" (clusterName prod /= clusterName test1)
    , testCase "production and test resolve distinct host data paths" $
        assertBool "data paths differ" (dataPath prod /= dataPath test1)
    ]

acceleratorIngressCases :: [TestTree]
acceleratorIngressCases =
    [ testCase "in-cluster daemon uses ClusterIP with no host mapping" $
        acceleratorIngressPlan InClusterDaemon 8081 30081
            @?= ClusterIpIngress 8081
    , testCase "host daemon uses local-only NodePort" $
        acceleratorIngressPlan HostResidentDaemon 8081 30081
            @?= NodePortIngress 8081 30081 "127.0.0.1"
    ]

nvidiaRuntimeCases :: [TestTree]
nvidiaRuntimeCases =
    [ testCase "NVIDIA runtime probe uses nvkind's volume-mount injection" $
        nvidiaRuntimeProbeArgs
            @?= [ "run"
                , "--rm"
                , "-v"
                , "/dev/null:/var/run/nvidia-container-devices/all"
                , "ubuntu:20.04"
                , "nvidia-smi"
                , "-L"
                ]
    , testCase "NVIDIA runtime probe accepts a GPU listing" $
        nvidiaRuntimeProbeReady (Right (ExitSuccess, "GPU 0: NVIDIA RTX 5090\n", "")) @?= True
    , testCase "NVIDIA runtime probe rejects empty or failed output" $ do
        nvidiaRuntimeProbeReady (Right (ExitSuccess, "", "")) @?= False
        nvidiaRuntimeProbeReady (Right (ExitFailure 1, "", "nvidia runtime missing")) @?= False
    ]

nvidiaDevicePluginCases :: [TestTree]
nvidiaDevicePluginCases =
    [ testCase "requires nvkind's exact NVIDIA RuntimeClass" $ do
        nvidiaRuntimeClassProbeArgs
            @?= ["get", "runtimeclass", "nvidia", "--ignore-not-found", "-o", "jsonpath={.handler}"]
        nvidiaRuntimeClassObserved (Right (ExitSuccess, "", "")) @?= Right False
        nvidiaRuntimeClassObserved (Right (ExitSuccess, "nvidia", "")) @?= Right True
        case nvidiaRuntimeClassObserved (Right (ExitSuccess, "foreign", "")) of
            Left _ -> pure ()
            Right _ -> assertFailure "a foreign RuntimeClass handler was accepted"
        case nvidiaRuntimeClassObserved (Right (ExitFailure 1, "", "API unavailable")) of
            Left _ -> pure ()
            Right _ -> assertFailure "a failed RuntimeClass probe was accepted as absence"
    , testCase "pins and installs the NVIDIA device-plugin chart through nvkind's runtime" $
        nvidiaDevicePluginHelmArgs
            @?= [ "upgrade"
                , "--install"
                , "nvidia-device-plugin"
                , "nvdp/nvidia-device-plugin"
                , "--version"
                , "0.19.3"
                , "--namespace"
                , "nvidia"
                , "--create-namespace"
                , "--set"
                , "runtimeClassName=nvidia"
                , "--wait"
                , "--timeout"
                , "3m"
                ]
    , testCase "waits for the reconciled DaemonSet rollout and queries allocatable GPUs" $ do
        nvidiaDevicePluginReadyArgs
            @?= [ "rollout"
                , "status"
                , "daemonset/nvidia-device-plugin"
                , "-n"
                , "nvidia"
                , "--timeout=120s"
                ]
        nvidiaAllocatableProbeArgs
            @?= [ "get"
                , "nodes"
                , "-o"
                , "jsonpath={range .items[*]}{.status.allocatable.nvidia\\.com/gpu}{\"\\n\"}{end}"
                ]
    , testCase "requires at least one positive allocatable GPU" $ do
        nvidiaAllocatableReady (Right (ExitSuccess, "1\n", "")) @?= True
        nvidiaAllocatableReady (Right (ExitSuccess, "0\n\n", "")) @?= False
        nvidiaAllocatableReady (Right (ExitFailure 1, "", "not found")) @?= False
    , testCase "positive allocatable pre-probe is a verified no-op" $ do
        events <- newIORef ([] :: [String])
        let record event = modifyIORef' events (event :)
        ensureNvidiaDevicePluginWith
            NvidiaDevicePluginOps
                { ndpProbeAllocatable = record "probe-allocatable" >> pure True
                , ndpReconcilePlugin = record "reconcile-plugin"
                , ndpWaitPluginReady = record "wait-plugin-ready"
                , ndpRequireAllocatable = record "require-allocatable"
                }
        seen <- reverse <$> readIORef events
        seen @?= ["probe-allocatable"]
    , testCase "missing allocation reconciles, waits, then requires positive allocation" $ do
        events <- newIORef ([] :: [String])
        let record event = modifyIORef' events (event :)
        ensureNvidiaDevicePluginWith
            NvidiaDevicePluginOps
                { ndpProbeAllocatable = record "probe-allocatable" >> pure False
                , ndpReconcilePlugin = record "reconcile-plugin"
                , ndpWaitPluginReady = record "wait-plugin-ready"
                , ndpRequireAllocatable = record "require-allocatable"
                }
        seen <- reverse <$> readIORef events
        seen
            @?= [ "probe-allocatable"
                , "reconcile-plugin"
                , "wait-plugin-ready"
                , "require-allocatable"
                ]
    ]

nodeCordonCases :: [TestTree]
nodeCordonCases =
    [ testCase "kind has one cordoned control-plane" $
        clusterNodeNames prod @?= ["demo-control-plane"]
    , testCase "nvkind splits the one slice across control-plane and GPU worker" $ do
        let plan = resolvePlanWithDriver "demo" rootPath Production NvkindDriver
            resources = ResourceEnvelope 6 "8GiB" "20GiB"
            perNodeMemoryBytes = (4 * 1024 ^ (3 :: Int) :: Integer)
            perNodeMemory = show perNodeMemoryBytes
            perNodeSwap = show (2 * perNodeMemoryBytes)
        clusterNodeNames plan @?= ["demo-control-plane", "demo-worker"]
        clusterNodeCordonArgs plan resources
            @?= Right
                [ ["update", "--cpus", "3", "--memory", perNodeMemory, "--memory-swap", perNodeSwap, "demo-control-plane"]
                , ["update", "--cpus", "3", "--memory", perNodeMemory, "--memory-swap", perNodeSwap, "demo-worker"]
                ]
    , testCase "multi-node cordon refuses a CPU slice smaller than its node count" $
        clusterNodeCordonArgs (resolvePlanWithDriver "demo" rootPath Production NvkindDriver) (ResourceEnvelope 1 "8GiB" "20GiB")
            @?= Left "cluster node cordon: CPU slice is smaller than the node count"
    , testCase "the plan owns node topology instead of inferring it from the driver" $ do
        let plan = prod{clusterNodeSuffixes = ["control-plane", "worker", "worker2"]}
        clusterNodeNames plan @?= ["demo-control-plane", "demo-worker", "demo-worker2"]
    , testCase "cordoning rejects an empty declared topology" $
        clusterNodeCordonArgs (prod{clusterNodeSuffixes = []}) (ResourceEnvelope 6 "8GiB" "20GiB")
            @?= Left "cluster node cordon: the plan declares no nodes"
    ]

dataInvariantCases :: [TestTree]
dataInvariantCases =
    [ testCase "unchecked Harness profile construction is not exported" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            let path = packageRoot </> "src" </> "HostBootstrap" </> "Cluster" </> "Lifecycle.hs"
            source <- Text.unpack . TextEncoding.decodeUtf8 <$> ByteString.readFile path
            exports <- maybe (assertFailure "cluster lifecycle exports are missing") pure
                (SourceGuard.moduleExportTokens "HostBootstrap.Cluster.Lifecycle" source)
            assertBool "Harness constructor is exported" ("TestCase" `notElem` exports)
            assertBool "validated constructor is missing" ("mkTestCaseProfile" `elem` exports)
    , testCase "Harness profiles admit only bounded ASCII run keys" $ do
        let invalid = ClusterPackageMismatch "the admitted Harness profile carries an invalid run key"
        mapM_ (\key -> do
            mkTestCaseProfile key @?= Left invalid
            profileFromPlanName ("harness:" <> key) @?= Left invalid)
            ["", "x/../../..", Text.replicate 49 "a", "\x4e00", "bad_key"]
        profile <- either (assertFailure . show) pure (mkTestCaseProfile "run-42")
        clusterProfileRunKey profile @?= Just "run-42"
        clusterProfileRunKey Production @?= Nothing
        profileFromPlanName "harness:run-42" @?= Right profile
    , testCase "ensuring the durable root is idempotent and leaves existing content intact" $
        withSystemTempDirectory "hostbootstrap-durable-root" $ \root -> do
            first <- ensureDurableDataPath root
            first @?= root </> ".data"
            doesDirectoryExist first >>= (@?= True)
            let marker = first </> "marker"
            writeFile marker "durable-content"
            second <- ensureDurableDataPath root
            second @?= first
            readFile marker >>= (@?= "durable-content")
    , testCase "down removes nothing on disk and preserves .data" $ do
        (remove, preserve) <- either (assertFailure . show) pure (teardown Down prod)
        remove @?= []
        assertBool ".data preserved" (dataPath prod `elem` preserve)
    , testCase "delete removes derived state but never .data" $ do
        (remove, preserve) <- either (assertFailure . show) pure (teardown Delete prod)
        assertBool ".data not in removal set" (dataPath prod `notElem` remove)
        assertBool "derived state removed" ([derivedStatePath prod] == remove)
        assertBool ".data preserved" (dataPath prod `elem` preserve)
    , testCase "test profile also never deletes its .data" $ do
        (removeDown, _) <- either (assertFailure . show) pure (teardown Down test1)
        (removeDel, _) <- either (assertFailure . show) pure (teardown Delete test1)
        assertBool "down keeps test .data" (dataPath test1 `notElem` removeDown)
        assertBool "delete keeps test .data" (dataPath test1 `notElem` removeDel)
    , testCase "delete refuses the durable root and its ancestors" $ do
        let durable = dataPath prod
            refusal = Left "cluster teardown: derived state may contain the durable root"
        teardown Delete (prod{derivedStatePath = durable}) @?= refusal
        teardown Delete (prod{derivedStatePath = takeDirectory durable}) @?= refusal
        teardown Delete (prod{derivedStatePath = takeDirectory durable </> "."}) @?= refusal
        teardown Delete (prod{derivedStatePath = durable </> ".."}) @?= refusal
    , testCase "delete refuses ambiguous relative and absolute roots" $ do
        let refusal = Left "cluster teardown: derived state may contain the durable root"
        teardown Delete (prod{derivedStatePath = "relative", dataPath = rootPath </> ".data"}) @?= refusal
        teardown Delete (prod{derivedStatePath = ""}) @?= refusal
    ]

snapshotPersistenceCases :: [TestTree]
snapshotPersistenceCases =
    [ testCase "fresh admission persists, verifies, and binds one exact indexed snapshot" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            continued <- newIORef (0 :: Int)
            let stable = renderSnapshot plan
            outcome <-
                withPersistedPlanSnapshot root unbound plan $ \verified bound binding lease active -> do
                    modifyIORef' continued (+ 1)
                    observed <- readRecord store (snapshotKey project unbound)
                    assertBool "continuation runs after the protected entries close" (observed /= Nothing)
                    exactPersistedEvidence verified bound binding lease active
            outcome
                @?= Right
                    ( stablePlanSnapshotSpecDigest stable
                    , stablePlanSnapshotDigest stable
                    , stablePlanSnapshotBytes stable
                    , unboundRunLeaseRunText unbound
                    )
            readIORef continued >>= (@?= 1)
            snapshot <- requireRecord store (snapshotKey project unbound)
            recordVersionWord (protectedRecordVersion snapshot) @?= 1
            lease <- requireRecord store (leaseKey project unbound)
            recordVersionWord (protectedRecordVersion lease) @?= 2
            assertNoPreparedOrEffectRecords store
    , testCase "an exact snapshot-persisted unbound retry is idempotent" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            let stable = renderSnapshot plan
                key = snapshotKey project unbound
            writeStableSnapshot store project unbound stable
            before <- requireRecord store key
            outcome <-
                withPersistedPlanSnapshot root unbound plan $ \_ _ _ _ _ -> pure ()
            outcome @?= Right ()
            after <- requireRecord store key
            protectedRecordVersion after @?= protectedRecordVersion before
            protectedRecordBytes after @?= protectedRecordBytes before
            assertNoPreparedOrEffectRecords store
    , testCase "immutable canonical-byte substitution is refused without continuation work" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            continued <- newIORef (0 :: Int)
            let stable = renderSnapshot plan
            writeRawPlanSnapshot
                store
                project
                (unboundRunLeaseRunText unbound)
                (stablePlanSnapshotSpecDigest stable)
                (stablePlanSnapshotDigest stable)
                (stablePlanSnapshotConfigDigest stable)
                (stablePlanSnapshotBytes stable <> ByteString.singleton 0)
            original <- requireRecord store (snapshotKey project unbound)
            outcome <-
                withPersistedPlanSnapshot root unbound plan $ \_ _ _ _ _ ->
                    modifyIORef' continued (+ 1)
            assertSnapshotMismatch outcome
            readIORef continued >>= (@?= 0)
            retained <- requireRecord store (snapshotKey project unbound)
            retained @?= original
            assertLeaseVersion store project unbound 1
            assertNoPreparedOrEffectRecords store
    , testCase "a malformed immutable snapshot is refused without lease or continuation work" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            continued <- newIORef (0 :: Int)
            writeRawRecord store (snapshotKey project unbound) "malformed-snapshot"
            outcome <-
                withPersistedPlanSnapshot root unbound plan $ \_ _ _ _ _ ->
                    modifyIORef' continued (+ 1)
            outcome
                @?= Left
                    ( SnapshotVerificationError
                        (ModeMalformedRecord (recordKeyText (snapshotKey project unbound)))
                    )
            readIORef continued >>= (@?= 0)
            assertLeaseVersion store project unbound 1
            assertNoPreparedOrEffectRecords store
    , testCase "a missing lease after snapshot persistence refuses before rewriting the snapshot" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            continued <- newIORef (0 :: Int)
            writeStableSnapshot store project unbound (renderSnapshot plan)
            snapshot <- requireRecord store (snapshotKey project unbound)
            deleteRecord store (leaseKey project unbound)
            outcome <-
                withPersistedPlanSnapshot root unbound plan $ \_ _ _ _ _ ->
                    modifyIORef' continued (+ 1)
            outcome
                @?= Left
                    ( SnapshotVerificationError
                        (ModeLeaseMissing (unboundRunLeaseRunText unbound))
                    )
            requireRecord store (snapshotKey project unbound) >>= (@?= snapshot)
            readIORef continued >>= (@?= 0)
            assertNoPreparedOrEffectRecords store
    , testCase "a stale retained lease after snapshot persistence refuses without rewriting it" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            continued <- newIORef (0 :: Int)
            writeStableSnapshot store project unbound (renderSnapshot plan)
            snapshot <- requireRecord store (snapshotKey project unbound)
            advanceRecordVersion store (leaseKey project unbound)
            outcome <-
                withPersistedPlanSnapshot root unbound plan $ \_ _ _ _ _ ->
                    modifyIORef' continued (+ 1)
            case outcome of
                Left (SnapshotVerificationError (ModeLeaseNotBindable run reason)) -> do
                    run @?= unboundRunLeaseRunText unbound
                    assertBool "reports the stale retained version" ("stale" `Text.isInfixOf` reason)
                other -> assertFailure ("expected stale-lease refusal, observed " <> show other)
            requireRecord store (snapshotKey project unbound) >>= (@?= snapshot)
            readIORef continued >>= (@?= 0)
            assertNoPreparedOrEffectRecords store
    , testCase "the exposed binding seam forces its private indexed witness" $
        withPersistedSnapshotPlan $ \store project _root unbound plan -> do
            continued <- newIORef (0 :: Int)
            writeStableSnapshot store project unbound (renderSnapshot plan)
            snapshot <- requireRecord store (snapshotKey project unbound)
            attempted <-
                try
                    ( withPlanDigestBinding unbound plan $ \verified binding ->
                        bindRunLeaseWithPlanRecovery
                            unbound
                            (error "bottom private indexed snapshot")
                            verified
                            binding
                            (\_ _ -> modifyIORef' continued (+ 1))
                    ) ::
                    IO
                        ( Either
                            SomeException
                            (Either SnapshotError (Either LeaseConflict ()))
                        )
            case attempted of
                Left failure ->
                    assertBool
                        "the private indexed witness itself was forced"
                        ("bottom private indexed snapshot" `isInfixOf` displayException failure)
                Right other ->
                    assertFailure
                        ("the bottom private indexed witness was not forced: " <> show other)
            requireRecord store (snapshotKey project unbound) >>= (@?= snapshot)
            assertLeaseVersion store project unbound 1
            readIORef continued >>= (@?= 0)
            assertNoPreparedOrEffectRecords store
    , testCase "a real protected snapshot read failure leaves the lease unbound" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            continued <- newIORef (0 :: Int)
            createDirectory (recordPath store (snapshotKey project unbound))
            outcome <-
                withPersistedPlanSnapshot root unbound plan $ \_ _ _ _ _ ->
                    modifyIORef' continued (+ 1)
            case outcome of
                Left (SnapshotVerificationError (ModeStoreFailure (ProtectedIOFailure "read a protected record" diagnostic))) ->
                    assertBool
                        "the read failure names the obstructed snapshot record"
                        (recordKeyText (snapshotKey project unbound) `Text.isInfixOf` diagnostic)
                other -> assertFailure ("expected protected read failure, observed " <> show other)
            readIORef continued >>= (@?= 0)
            assertLeaseVersion store project unbound 1
            assertNoPreparedOrEffectRecords store
    , testCase "a real public fresh-binding read failure preserves the verified snapshot and unbound lease" $
        withPersistedSnapshotPlan $ \store project _root unbound plan -> do
            let stable = renderSnapshot plan
            writeStableSnapshot store project unbound stable
            snapshot <- requireRecord store (snapshotKey project unbound)
            lease <- requireRecord store (leaseKey project unbound)
            verifiedEntries <- newIORef (0 :: Int)
            continued <- newIORef (0 :: Int)
            outcome <-
                withPlanDigestBinding unbound plan $ \verified _binding -> do
                    modifyIORef' verifiedEntries (+ 1)
                    planSnapshotCanonicalBytes verified @?= Just (stablePlanSnapshotBytes stable)
                    withBlockedRecordPath store (leaseKey project unbound) $ do
                        observed <-
                            withProtectedEntry store $ \session ->
                                readProtectedRecord session (leaseKey project unbound)
                        readFailure <- case observed of
                            Left failure@(ProtectedIOFailure "read a protected record" diagnostic) -> do
                                assertBool
                                    "the read failure names the obstructed lease record"
                                    (recordKeyText (leaseKey project unbound) `Text.isInfixOf` diagnostic)
                                pure failure
                            other -> assertFailure ("expected the obstructed lease read to fail, observed " <> show other)
                        bound <-
                            bindRunLease
                                unbound
                                verified
                                (\_ -> modifyIORef' continued (+ 1))
                        case bound of
                            Left conflict ->
                                leaseConflictMessage conflict @?= modeErrorMessage (ModeStoreFailure readFailure)
                            Right () -> assertFailure "the binding read failure yielded a bound lease"
            outcome @?= Right ()
            readIORef verifiedEntries >>= (@?= 1)
            readIORef continued >>= (@?= 0)
            requireRecord store (snapshotKey project unbound) >>= (@?= snapshot)
            requireRecord store (leaseKey project unbound) >>= (@?= lease)
            assertLeaseVersion store project unbound 1
            assertNoPreparedOrEffectRecords store
    , testCase "same project and epoch in another store is rejected before any snapshot write" $
        withPersistedSnapshotPlan $ \_storeA project _rootA _unboundA plan ->
            withSystemTempDirectory "hostbootstrap-plan-origin-store-b" $ \directory -> do
                storeB <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
                second <-
                    withProductionRoot storeB project ProjectUp $ \productionRoot -> do
                        let unboundB = productionRootUnboundLease productionRoot
                        continued <- newIORef (0 :: Int)
                        outcome <-
                            withPersistedPlanSnapshot
                                (productionRootAuthority productionRoot)
                                unboundB
                                plan
                                (\_ _ _ _ _ -> modifyIORef' continued (+ 1))
                        absent <- readRecord storeB (snapshotKey project unboundB)
                        count <- readIORef continued
                        pure (Right (outcome, absent, count))
                (outcome, observed, count) <- either (fail . show) pure second
                case outcome of
                    Left
                        ( SnapshotVerificationError
                            (ModeEvidenceMismatch "plan store" expected observedStore)
                            ) -> assertBool "the two protected stores have distinct identities" (expected /= observedStore)
                    other -> assertFailure ("expected plan-store refusal, observed " <> show other)
                observed @?= Nothing
                count @?= 0
                assertNoPreparedOrEffectRecords storeB
    , testCase "a stale plan epoch is rejected before any snapshot write" $
        withPersistedSnapshotPlan $ \_storeA project _rootA _unboundA plan ->
            withSystemTempDirectory "hostbootstrap-plan-origin-epoch-b" $ \directory -> do
                storeB <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
                writeRawRecord storeB (brokerGenerationKey project) "1"
                second <-
                    withProductionRoot storeB project ProjectUp $ \productionRoot -> do
                        let unboundB = productionRootUnboundLease productionRoot
                        continued <- newIORef (0 :: Int)
                        outcome <-
                            withPersistedPlanSnapshot
                                (productionRootAuthority productionRoot)
                                unboundB
                                plan
                                (\_ _ _ _ _ -> modifyIORef' continued (+ 1))
                        absent <- readRecord storeB (snapshotKey project unboundB)
                        count <- readIORef continued
                        pure (Right (outcome, absent, count))
                (outcome, observed, count) <- either (fail . show) pure second
                outcome
                    @?= Left
                        ( SnapshotVerificationError
                            (ModeEvidenceMismatch "plan epoch" "2" "1")
                        )
                observed @?= Nothing
                count @?= 0
                assertNoPreparedOrEffectRecords storeB
    ]
        <> snapshotFilesystemFailureCases

existingBoundSnapshotCases :: [TestTree]
existingBoundSnapshotCases =
    [ testCase "terminal admission yields only the exact close key after unlocking" $
        withExistingBoundSnapshotFixture $ \store project unbound bound _stable -> do
            closeKey <- either (fail . show) pure (mkInvocationCloseKey "production-up-close")
            recorded <-
                withProtectedEntry store $ \session ->
                    fmap Right
                        ( recordProductionInvocationAcknowledgment
                            session
                            project
                            bound
                            closeKey
                        )
            either (fail . show) (either (fail . show) pure) recorded
            -- Terminal classification must not inspect Open revision state.
            writeRawRecord store (migrationKey project) "malformed-migration"
            let keys = productionAdmissionKeys project unbound
            before <- mapM (readRecord store) keys
            terminalCount <- newIORef (0 :: Int)
            openCount <- newIORef (0 :: Int)
            outcome <-
                withBoundPlanSnapshot
                    store
                    project
                    ( \observed -> do
                        assertProtectedEntryReleased store
                        modifyIORef' terminalCount (+ 1)
                        invocationCloseKeyText observed @?= "production-up-close"
                        pure ("terminal" :: Text.Text)
                    )
                    ( \_ _ _ _ _ _ _ -> do
                        modifyIORef' openCount (+ 1)
                        pure "open"
                    )
            outcome @?= Right "terminal"
            readIORef terminalCount >>= (@?= 1)
            readIORef openCount >>= (@?= 0)
            mapM (readRecord store) keys >>= (@?= before)
    , testCase "Open admission jointly propagates the exact indexed evidence after unlocking" $
        withExistingBoundSnapshotFixture $ \store project unbound _bound stable -> do
            let keys = productionAdmissionKeys project unbound
            before <- mapM (readRecord store) keys
            outcome <-
                withBoundPlanSnapshot
                    store
                    project
                    (\_ -> assertFailure "the Open invocation entered the terminal callback")
                    ( \root modeLease boundLease verified boundSnapshot binding recovery -> do
                        assertProtectedEntryReleased store
                        exactBoundAdmissionEvidence
                            root
                            modeLease
                            boundLease
                            verified
                            boundSnapshot
                            binding
                            recovery
                    )
            outcome
                @?= Right
                    ( stablePlanSnapshotSpecDigest stable
                    , stablePlanSnapshotDigest stable
                    , stablePlanSnapshotBytes stable
                    , 1
                    , NormalRevision
                    )
            mapM (readRecord store) keys >>= (@?= before)
    , testCase "two Open admissions preserve durable bytes and are re-enterable" $
        withExistingBoundSnapshotFixture $ \store project unbound _bound _stable -> do
            let keys = productionAdmissionKeys project unbound
            before <- mapM (readRecord store) keys
            continued <- newIORef (0 :: Int)
            let open _ _ _ _ _ _ _ = modifyIORef' continued (+ 1)
            first <- withBoundPlanSnapshot store project (\_ -> pure ()) open
            second <- withBoundPlanSnapshot store project (\_ -> pure ()) open
            first @?= Right ()
            second @?= Right ()
            readIORef continued >>= (@?= 2)
            mapM (readRecord store) keys >>= (@?= before)
    , testCase "an Open callback exception releases admission for exact re-entry" $
        withExistingBoundSnapshotFixture $ \store project unbound _bound _stable -> do
            let keys = productionAdmissionKeys project unbound
            before <- mapM (readRecord store) keys
            attempted <-
                try
                    ( withBoundPlanSnapshot
                        store
                        project
                        (\_ -> pure ())
                        (\_ _ _ _ _ _ _ -> ioError (userError "Open callback interrupted"))
                    ) ::
                    IO (Either SomeException (Either SnapshotError ()))
            case attempted of
                Left failure ->
                    assertBool
                        "the callback exception escaped the already-released bracket"
                        ("Open callback interrupted" `isInfixOf` displayException failure)
                Right other -> assertFailure ("the callback interruption was swallowed: " <> show other)
            resumed <-
                withBoundPlanSnapshot
                    store
                    project
                    (\_ -> assertFailure "the Open re-entry entered the terminal callback")
                    (\_ _ _ _ _ _ _ -> pure ())
            resumed @?= Right ()
            mapM (readRecord store) keys >>= (@?= before)
    , testCase "the package-gated lower seam forces its hidden admission witness" $
        withExistingBoundSnapshotFixture $ \store project unbound _bound _stable -> do
            let keys = productionAdmissionKeys project unbound
            before <- mapM (readRecord store) keys
            terminalCount <- newIORef (0 :: Int)
            openCount <- newIORef (0 :: Int)
            attempted <-
                try
                    ( withBoundPlanSnapshotKernel
                        (error "bottom existing-bound admission witness")
                        store
                        project
                        (\_ -> modifyIORef' terminalCount (+ 1))
                        (\_ _ _ _ _ _ _ -> modifyIORef' openCount (+ 1))
                    ) ::
                    IO (Either SomeException (Either ModeError ()))
            case attempted of
                Left failure ->
                    assertBool
                        "the hidden package witness was forced before store access"
                        ("bottom existing-bound admission witness" `isInfixOf` displayException failure)
                Right other ->
                    assertFailure ("the bottom admission witness was accepted: " <> show other)
            readIORef terminalCount >>= (@?= 0)
            readIORef openCount >>= (@?= 0)
            mapM (readRecord store) keys >>= (@?= before)
    , testCase "the reverse-root wrappers force their hidden token when only it is applied" $ do
        let assertForced :: String -> Either SomeException () -> IO ()
            assertForced label attempted = case attempted of
                Left failure ->
                    assertBool
                        (label <> " forced its admission before returning the remaining function")
                        (("bottom " <> label) `isInfixOf` displayException failure)
                Right () -> assertFailure (label <> " returned its remaining function without forcing the admission")
        resumed <-
            try @SomeException
                (evaluate (case withResumedExistingBoundReverseRootKernel (error "bottom partial resume admission") of !_ -> ()))
        assertForced "partial resume admission" resumed
        fresh <-
            try @SomeException
                (evaluate (case withFreshExistingBoundReverseRootKernel (error "bottom partial fresh admission") of !_ -> ()))
        assertForced "partial fresh admission" fresh
        reauthorized <-
            try @SomeException
                (evaluate (case withReauthorizedBoundPlanSnapshotKernel (error "bottom partial Snapshot admission") of !_ -> ()))
        assertForced "partial Snapshot admission" reauthorized
    , testCase "reverse-root resume forces its hidden admission on partial application" $ do
        attempted <-
            try @SomeException
                ( withResumedExistingBoundReverseRootKernel
                    (error "bottom reverse-root resume admission")
                    (error "reverse-root resume forced the store")
                    (error "reverse-root resume forced the project")
                    (error "reverse-root resume forced the verb")
                    (error "reverse-root resume forced the target callback") ::
                    IO (Either ModeError ())
                )
        case attempted of
            Left failure ->
                assertBool
                    "the reverse-root resume admission was forced before any other argument"
                    ("bottom reverse-root resume admission" `isInfixOf` displayException failure)
            Right _ -> assertFailure "the reverse-root resume accepted a bottom admission"
    , testCase "reverse-root fresh admission forces its hidden token on partial application" $ do
        attempted <-
            try @SomeException
                ( withFreshExistingBoundReverseRootKernel
                    (error "bottom reverse-root fresh admission")
                    (error "reverse-root fresh admission forced the store")
                    (error "reverse-root fresh admission forced the project")
                    (error "reverse-root fresh admission forced the verb")
                    (error "reverse-root fresh admission forced the source root")
                    (error "reverse-root fresh admission forced the source mode")
                    (error "reverse-root fresh admission forced the bound lease")
                    (error "reverse-root fresh admission forced the verified snapshot")
                    (error "reverse-root fresh admission forced the bound snapshot")
                    (error "reverse-root fresh admission forced the digest binding")
                    (error "reverse-root fresh admission forced the source recovery")
                    (error "reverse-root fresh admission forced the source plan")
                    (error "reverse-root fresh admission forced the lifecycle context")
                    (error "reverse-root fresh admission forced the source journal")
                    (error "reverse-root fresh admission forced the source cursor")
                    (error "reverse-root fresh admission forced the target callback") ::
                    IO (Either ModeError ())
                )
        case attempted of
            Left failure ->
                assertBool
                    "the fresh admission token was forced before the remaining function"
                    ("bottom reverse-root fresh admission" `isInfixOf` displayException failure)
            Right _ -> assertFailure "the reverse-root fresh wrapper accepted a bottom admission"
    , testCase "the reverse-root Snapshot facade forces its hidden token on partial application" $ do
        attempted <-
            try @SomeException
                ( withReauthorizedBoundPlanSnapshotKernel
                    (error "bottom reverse-root Snapshot admission")
                    (error "reverse-root Snapshot admission forced the store")
                    (error "reverse-root Snapshot admission forced the project")
                    (error "reverse-root Snapshot admission forced the verb")
                    (\_ _ _ _ _ _ _ _ -> pure (Left SnapshotReverseRootTerminal))
                    (\_ _ _ _ _ _ _ _ -> pure ()) ::
                    IO (Either SnapshotError ())
                )
        case attempted of
            Left failure ->
                assertBool
                    "the Snapshot admission token was forced before the remaining function"
                    ("bottom reverse-root Snapshot admission" `isInfixOf` displayException failure)
            Right _ -> assertFailure "the reverse-root Snapshot facade accepted a bottom admission"
    , refusalCase
        "a recomputed digest cannot bless the reserved non-absolute root"
        ( \store project unbound stable ->
            replaceRehashedCanonicalSnapshot store project unbound stable
                (replaceCanonicalRoot "<hostbootstrap:unrooted-lifecycle-plan>" (stablePlanSnapshotBytes stable))
        )
        ( \project unbound failure ->
            failure
                == ModeMalformedCanonicalSnapshot
                    (recordKeyText (snapshotKey project unbound))
                    "the canonical project root is not absolute"
        )
    , testCase "a canonical root holding a lone surrogate code point is admitted" $ do
        _ <- admitCanonicalRootMutation (rootDir </> ['\xD800'])
        pure ()
    , testCase "a canonical root at the 131072-byte boundary is admitted" $ do
        let root = canonicalRootAtPayloadSize 131072
        ByteString.length (encodedRootPayload root) @?= 131072
        _ <- admitCanonicalRootMutation root
        pure ()
    ]
        <> existingOpenRevisionCases
        <> existingBoundRefusalCases

admitCanonicalRootMutation :: FilePath -> IO ByteString.ByteString
admitCanonicalRootMutation root =
    withExistingBoundSnapshotFixture $ \store project unbound _bound stable -> do
        let specDigest = stablePlanSnapshotSpecDigest stable
            changedBytes = replaceCanonicalRoot root (stablePlanSnapshotBytes stable)
            changedPlan = canonicalPlanDigestForTest specDigest changedBytes
        replaceRawRecord
            store
            (leaseKey project unbound)
            (encodeExactFields ["bound", "1", specDigest, changedPlan])
        replaceRawRecord
            store
            (snapshotKey project unbound)
            ( rawPlanSnapshotPayloadWithConfig
                1
                specDigest
                changedPlan
                (stablePlanSnapshotConfigDigest stable)
                changedBytes
            )
        outcome <-
            withBoundPlanSnapshot
                store
                project
                (\_ -> assertFailure "the mutated Open snapshot entered the terminal callback")
                (\_ _ _ _ boundSnapshot _ _ -> pure (boundPlanSnapshotBytes boundSnapshot))
        admitted <- either (fail . show) pure outcome
        admitted @?= changedBytes
        pure admitted

canonicalRootAtPayloadSize :: Int -> FilePath
canonicalRootAtPayloadSize byteCount =
    rootDir <> replicate (byteCount `div` 4 - length rootDir) 'a'

existingOpenRevisionCases :: [TestTree]
existingOpenRevisionCases =
    [ testCase "a refused fresh Up preserves the existing Open bound run at its recorded epoch" $
        withExistingBoundSnapshotFixtureAtCounter (Just 40) $ \store project _unbound _bound stable -> do
            before <- protectedRecordImage store
            freshEntries <- newIORef (0 :: Int)
            refused <- withProductionRoot store project ProjectUp $ \_ -> do
                modifyIORef' freshEntries (+ 1)
                pure (Right ())
            refused @?= Left (ModeLeaseNotBindable "production" "bound")
            readIORef freshEntries >>= (@?= 0)
            protectedRecordImage store >>= (@?= before)
            terminalEntries <- newIORef (0 :: Int)
            openEntries <- newIORef (0 :: Int)
            admitted <-
                withBoundPlanSnapshot
                    store
                    project
                    (\_ -> modifyIORef' terminalEntries (+ 1) >> pure Nothing)
                    ( \root modeLease _lease _verified boundSnapshot _binding _recovery -> do
                        modifyIORef' openEntries (+ 1)
                        brokerEpochWord (projectModeLeaseEpoch modeLease) @?= 41
                        pure (Just (boundPlanSnapshotBytes boundSnapshot, brokerEpochWord (rootAuthorityEpoch root)))
                    )
            admitted @?= Right (Just (stablePlanSnapshotBytes stable, 41))
            readIORef terminalEntries >>= (@?= 0)
            readIORef openEntries >>= (@?= 1)
            protectedRecordImage store >>= (@?= before)
    , revisionCase
        "Open admission retains an incomplete migration revision"
        "incomplete\tmigration-12-18"
        (IncompleteMigration "migration-12-18")
    , revisionCase
        "Open admission retains a completed migration revision"
        "completed\tmigration-12-18"
        (CompletedMigration "migration-12-18")
    ]
  where
    revisionCase label payload expected =
        testCase label $
            withExistingBoundSnapshotFixture $ \store project unbound _bound _stable -> do
                writeRawRecord store (migrationKey project) payload
                let keys = productionAdmissionKeys project unbound
                before <- mapM (readRecord store) keys
                outcome <-
                    withBoundPlanSnapshot
                        store
                        project
                        (\_ -> assertFailure "an Open revision entered the terminal callback")
                        (\_ _ _ _ _ _ recovery -> pure (boundInvocationRecoveryRevisionKind recovery))
                outcome @?= Right expected
                mapM (readRecord store) keys >>= (@?= before)

existingBoundRefusalCases :: [TestTree]
existingBoundRefusalCases =
    [ refusalCase
        "an advanced broker counter is exact-generation drift"
        (\store project _ _ -> replaceRawRecord store (brokerGenerationKey project) "2")
        (\_ _ failure -> case failure of ModeAuthorityFailure (AuthorityInvalidIdentity _) -> True; _ -> False)
    , brokerCounterRefusalCase
        "broker counter deleted"
        deleteRecord
        "the recorded broker generation has no allocation counter"
    , brokerCounterRefusalCase
        "broker counter malformed"
        (\store key -> replaceRawRecord store key "not-a-counter")
        "the broker generation counter is malformed"
    , refusalCase
        "a missing authority binding is refused read-only"
        (\store _ _ _ -> deleteRecord store authorityBindingKey)
        (\_ _ failure -> case failure of ModeAuthorityFailure (AuthorityMalformedBinding _) -> True; _ -> False)
    , refusalCase
        "a missing Production mode is refused"
        (\store project _ _ -> deleteRecord store (productionModeKey project))
        (\_ _ failure -> case failure of ModeWrongMode "production" "absent" -> True; _ -> False)
    , refusalCase
        "a missing bound lease is refused"
        (\store project unbound _ -> deleteRecord store (leaseKey project unbound))
        (\_ _ failure -> case failure of ModeLeaseMissing "production" -> True; _ -> False)
    , refusalCase
        "a missing immutable snapshot is refused"
        (\store project unbound _ -> deleteRecord store (snapshotKey project unbound))
        (\_ _ failure -> case failure of ModeSnapshotMissing "production" -> True; _ -> False)
    , refusalCase
        "bound lease epoch drift is refused"
        ( \store project unbound stable ->
            replaceRawRecord
                store
                (leaseKey project unbound)
                ( encodeExactFields
                    [ "bound"
                    , "2"
                    , stablePlanSnapshotSpecDigest stable
                    , stablePlanSnapshotDigest stable
                    ]
                )
        )
        (\_ _ failure -> case failure of ModeEpochMismatch 2 1 -> True; _ -> False)
    , refusalCase
        "empty bound lease digests are malformed"
        ( \store project unbound stable ->
            replaceRawRecord
                store
                (leaseKey project unbound)
                (encodeExactFields ["bound", "1", "", stablePlanSnapshotDigest stable])
        )
        (\project unbound failure -> failure == ModeMalformedRecord (recordKeyText (leaseKey project unbound)))
    , refusalCase
        "lease and snapshot digest drift is refused"
        ( \store project unbound stable ->
            replaceRawRecord
                store
                (leaseKey project unbound)
                ( encodeExactFields
                    [ "bound"
                    , "1"
                    , stablePlanSnapshotSpecDigest stable
                    , "different-plan-digest"
                    ]
                )
        )
        (\_ _ failure -> case failure of ModeSnapshotMismatch _ _ -> True; _ -> False)
    , refusalCase
        "an unsupported snapshot envelope version is refused"
        ( \store project unbound stable ->
            replaceRawRecord
                store
                (snapshotKey project unbound)
                (rawPlanSnapshotPayload 2 stable (stablePlanSnapshotBytes stable))
        )
        (\project unbound failure -> failure == ModeMalformedRecord (recordKeyText (snapshotKey project unbound)))
    , refusalCase
        "the rootless version-2 canonical plan is refused"
        ( \store project unbound stable ->
            replaceRehashedCanonicalSnapshot store project unbound stable
                (replaceCanonicalVersion 2 (stablePlanSnapshotBytes stable))
        )
        (canonicalRefusalReason "the canonical plan version is unsupported")
    , refusalCase
        "malformed canonical plan bytes are refused"
        ( \store project unbound stable ->
            replaceRawRecord
                store
                (snapshotKey project unbound)
                (rawPlanSnapshotPayload 1 stable "not-a-canonical-plan")
        )
        (canonicalRefusalReason "the canonical plan header is malformed")
    , refusalCase
        "canonical content-digest drift is refused"
        ( \store project unbound stable -> do
            let original = stablePlanSnapshotBytes stable
            changed <-
                replaceUniqueCanonicalFragment
                    (canonicalTextFrame "label" <> canonicalTextFrame "context")
                    (canonicalTextFrame "label" <> canonicalTextFrame "Context")
                    original
            ByteString.length changed @?= ByteString.length original
            replaceRawRecord
                store
                (snapshotKey project unbound)
                (rawPlanSnapshotPayload 1 stable changed)
        )
        (canonicalRefusalReason "the canonical plan digest does not match its bytes")
    , refusalCase
        "a recomputed digest cannot bless a relative canonical root"
        ( \store project unbound stable -> do
            let specDigest = stablePlanSnapshotSpecDigest stable
                changedBytes = replaceCanonicalRoot "relative-root" (stablePlanSnapshotBytes stable)
                changedPlan = canonicalPlanDigestForTest specDigest changedBytes
            replaceRawRecord
                store
                (leaseKey project unbound)
                (encodeExactFields ["bound", "1", specDigest, changedPlan])
            replaceRawRecord
                store
                (snapshotKey project unbound)
                ( rawPlanSnapshotPayloadWithConfig
                    1
                    specDigest
                    changedPlan
                    (stablePlanSnapshotConfigDigest stable)
                    changedBytes
                )
        )
        (canonicalRefusalReason "the canonical project root is not absolute")
    , refusalCase
        "the outer and embedded canonical configuration digests must agree"
        ( \store project unbound stable ->
            replaceRawRecord
                store
                (snapshotKey project unbound)
                ( rawPlanSnapshotPayloadWithConfig
                    1
                    (stablePlanSnapshotSpecDigest stable)
                    (stablePlanSnapshotDigest stable)
                    "different-config-digest"
                    (stablePlanSnapshotBytes stable)
                )
        )
        (canonicalRefusalReason "the canonical config-digest value does not match")
    , refusalCase
        "coordinated lease/envelope drift cannot relabel the embedded specification"
        ( \store project unbound stable -> do
            let changedSpec = "different-spec-digest"
                digestSuffix = Text.dropWhile (/= ':') (stablePlanSnapshotDigest stable)
                changedPlan = changedSpec <> digestSuffix
            replaceRawRecord
                store
                (leaseKey project unbound)
                (encodeExactFields ["bound", "1", changedSpec, changedPlan])
            replaceRawRecord
                store
                (snapshotKey project unbound)
                ( rawPlanSnapshotPayloadWithConfig
                    1
                    changedSpec
                    changedPlan
                    (stablePlanSnapshotConfigDigest stable)
                    (stablePlanSnapshotBytes stable)
                )
        )
        (canonicalRefusalReason "the canonical spec-digest value does not match")
    , refusalCase
        "a recomputed digest cannot bless a structurally corrupt canonical step stream"
        ( \store project unbound stable -> do
            let specDigest = stablePlanSnapshotSpecDigest stable
                changedBytes = replaceCanonicalStepCount 2 (stablePlanSnapshotBytes stable)
                changedPlan = canonicalPlanDigestForTest specDigest changedBytes
            replaceRawRecord
                store
                (leaseKey project unbound)
                (encodeExactFields ["bound", "1", specDigest, changedPlan])
            replaceRawRecord
                store
                (snapshotKey project unbound)
                ( rawPlanSnapshotPayloadWithConfig
                    1
                    specDigest
                    changedPlan
                    (stablePlanSnapshotConfigDigest stable)
                    changedBytes
                )
        )
        (canonicalRefusalReason "the canonical step stream is truncated")
    , refusalCase
        "a legacy digest-only snapshot cannot mint bound plan evidence"
        ( \store project unbound stable ->
            replaceRawRecord
                store
                (snapshotKey project unbound)
                ( encodeExactFields
                    [ "1"
                    , stablePlanSnapshotSpecDigest stable
                    , stablePlanSnapshotDigest stable
                    ]
                )
        )
        (\project unbound failure -> failure == ModeMalformedRecord (recordKeyText (snapshotKey project unbound)))
    , refusalCase
        "an invalid terminal close key is never normalized or surfaced"
        (\store project _ _ -> writeRawRecord store (productionInvocationKey project) "ack\tbad/key")
        (\project _ failure -> failure == ModeMalformedRecord (recordKeyText (productionInvocationKey project)))
    , malformedBoundTextRecordCase
        "invalid UTF-8 in a terminal close key refuses its exact invocation record"
        productionInvocationKey
        ("ack\t" <> ByteString.singleton 0xff)
    , refusalCase
        "terminal close-key whitespace is never stripped"
        (\store project _ _ -> writeRawRecord store (productionInvocationKey project) "ack\tvalid-key ")
        (\project _ failure -> failure == ModeMalformedRecord (recordKeyText (productionInvocationKey project)))
    , refusalCase
        "a Harness Closing disposition cannot enter Production recovery"
        (\store project _ _ -> writeRawRecord store (productionInvocationKey project) "closing\t1")
        (\_ _ failure -> case failure of ModeWrongRecoveryScope "production" _ -> True; _ -> False)
    , refusalCase
        "malformed Open revision state is refused before the callback"
        (\store project _ _ -> writeRawRecord store (migrationKey project) "incomplete\t")
        (\project _ failure -> failure == ModeMalformedRecord (recordKeyText (migrationKey project)))
    , malformedBoundTextRecordCase
        "invalid UTF-8 in an incomplete migration refuses its exact migration record"
        migrationKey
        ("incomplete\t" <> ByteString.singleton 0xff)
    ]
        <> canonicalRootParserRefusalCases
        <> intraStepRefusalCases

canonicalRefusalReason ::
    Text.Text ->
    InstalledProjectIdentity projectId ->
    UnboundRunLease scope brokerGeneration ->
    ModeError ->
    Bool
canonicalRefusalReason expectedReason _ _ failure = case failure of
    ModeMalformedCanonicalSnapshot _ reason -> reason == expectedReason
    _ -> False

intraStepRefusalCases :: [TestTree]
intraStepRefusalCases =
    [ intraStepRefusalCase
        "a recomputed digest cannot bless an unknown first-step reverse policy"
        "the canonical reverse policy is malformed"
        ( replaceUniqueCanonicalFragment
            (canonicalTextFrame "reverse-policy" <> canonicalTextFrame "project-managed")
            (canonicalTextFrame "reverse-policy" <> canonicalTextFrame "unknown-policy")
        )
    , intraStepRefusalCase
        "a recomputed digest cannot bless a first-step mount boolean of two"
        "the canonical read-only boolean is malformed"
        ( replaceUniqueCanonicalFragment
            (canonicalTextFrame "read-only" <> ByteString.singleton 1)
            (canonicalTextFrame "read-only" <> ByteString.singleton 2)
        )
    , intraStepRefusalCase
        "a recomputed digest cannot bless a zero first-step implementation revision"
        "the canonical revision value is malformed"
        ( \step -> do
            let (implementation, operation) = ByteString.breakSubstring (canonicalTextFrame "operation") step
            assertBool "the first step has no operation after its implementation" (not (ByteString.null operation))
            changed <-
                replaceUniqueCanonicalFragment
                    (canonicalTextFrame "revision" <> encodedWord 1)
                    (canonicalTextFrame "revision" <> encodedWord 0)
                    implementation
            pure (changed <> operation)
        )
    , intraStepRefusalCase
        "a recomputed digest cannot bless an unknown first-step lift kind"
        "the canonical lift layer is malformed"
        ( replaceUniqueCanonicalFragment
            (canonicalTextFrame "container" <> encodedWord 5)
            (canonicalTextFrame "unknown-layer" <> encodedWord 5)
        )
    , intraStepRefusalCase
        "a recomputed digest cannot bless an unknown first-step provider target"
        "the provider-resource target is malformed"
        ( replaceUniqueCanonicalFragment
            (canonicalTextFrame "provider-resources" <> encodedWord 1 <> canonicalTextFrame "current-frame")
            (canonicalTextFrame "provider-resources" <> encodedWord 1 <> canonicalTextFrame "unknown-target")
        )
    ]

intraStepRefusalCase ::
    String ->
    Text.Text ->
    (ByteString.ByteString -> IO ByteString.ByteString) ->
    TestTree
intraStepRefusalCase label reason mutate =
    refusalCaseWithPlan richSnapshotPlan label
        ( \store project unbound stable -> do
            original <-
                withBoundPlanSnapshot store project
                    (\_ -> assertFailure "the original rich fixture entered the terminal callback")
                    (\_ _ _ _ bound _ _ -> pure (boundPlanSnapshotBytes bound))
            original @?= Right (stablePlanSnapshotBytes stable)
            changed <- mutateFirstCanonicalStep mutate (stablePlanSnapshotBytes stable)
            replaceRehashedCanonicalSnapshot store project unbound stable changed
        )
        (canonicalRefusalReason reason)

-- The rich fixture has exactly two steps. Scope each mutation before the
-- second outer step header so a later step cannot supply its target field.
mutateFirstCanonicalStep ::
    (ByteString.ByteString -> IO ByteString.ByteString) ->
    ByteString.ByteString ->
    IO ByteString.ByteString
mutateFirstCanonicalStep mutate bytes = do
    countOffset <- maybe (assertFailure "the canonical step count is absent") pure (canonicalStepCountOffset bytes)
    canonicalWordAt bytes countOffset @?= Just 2
    let firstOffset = countOffset + 8
        secondHeader = canonicalTextFrame "step" <> encodedWord 14 <> canonicalTextFrame "ordinal" <> encodedWord 2
        firstHeader = canonicalTextFrame "step" <> encodedWord 14 <> canonicalTextFrame "ordinal" <> encodedWord 1
        (first, remainder) = ByteString.breakSubstring secondHeader (ByteString.drop firstOffset bytes)
    assertBool "the rich fixture's first step header changed" (firstHeader `ByteString.isPrefixOf` first)
    assertBool "the rich fixture has no second outer step" (not (ByteString.null remainder))
    assertBool "the second step header is not unique" (not (secondHeader `ByteString.isInfixOf` ByteString.drop (ByteString.length secondHeader) remainder))
    changed <- mutate first
    assertBool "the intra-step mutation changed no bytes" (changed /= first)
    pure (ByteString.take firstOffset bytes <> changed <> remainder)

replaceUniqueCanonicalFragment ::
    ByteString.ByteString ->
    ByteString.ByteString ->
    ByteString.ByteString ->
    IO ByteString.ByteString
replaceUniqueCanonicalFragment old new bytes =
    case ByteString.breakSubstring old bytes of
        (_, remainder) | ByteString.null remainder -> assertFailure "the canonical mutation target is absent"
        (prefix, remainder) -> do
            let suffix = ByteString.drop (ByteString.length old) remainder
            assertBool "the canonical mutation target is not unique" (not (old `ByteString.isInfixOf` suffix))
            pure (prefix <> new <> suffix)

replaceRehashedCanonicalSnapshot ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    UnboundRunLease scope brokerGeneration ->
    StablePlanSnapshot ->
    ByteString.ByteString ->
    IO ()
replaceRehashedCanonicalSnapshot store project unbound stable changedBytes = do
    assertBool "the canonical mutation changed no bytes" (changedBytes /= stablePlanSnapshotBytes stable)
    let specDigest = stablePlanSnapshotSpecDigest stable
        changedPlan = canonicalPlanDigestForTest specDigest changedBytes
    replaceRawRecord store (leaseKey project unbound) (encodeExactFields ["bound", "1", specDigest, changedPlan])
    replaceRawRecord store (snapshotKey project unbound)
        (rawPlanSnapshotPayloadWithConfig 1 specDigest changedPlan (stablePlanSnapshotConfigDigest stable) changedBytes)

canonicalRootParserRefusalCases :: [TestTree]
canonicalRootParserRefusalCases =
    [ canonicalRootParserRefusalCase
        "an empty canonical root is refused"
        ByteString.empty
        "the canonical project root is empty"
    , canonicalRootParserRefusalCase
        "a partial canonical-root code point is refused"
        (ByteString.singleton 0)
        "the canonical project root has a partial code point"
    , canonicalRootParserRefusalCase
        "an out-of-range canonical-root code point is refused"
        (ByteString.pack [0, 17, 0, 0])
        "the canonical project root code point is out of range"
    , canonicalRootParserRefusalCase
        "a NUL canonical-root code point is refused"
        (ByteString.replicate 4 0)
        "the canonical project root contains NUL"
    , canonicalRootParserRefusalCase
        "an oversized canonical root is refused"
        (encodedRootPayload (canonicalRootAtPayloadSize 131076))
        "the canonical project root exceeds the size limit"
    ]

canonicalRootParserRefusalCase :: String -> ByteString.ByteString -> Text.Text -> TestTree
canonicalRootParserRefusalCase label rootPayload expectedReason =
    refusalCase
        label
        ( \store project unbound stable -> do
            let specDigest = stablePlanSnapshotSpecDigest stable
                changedBytes =
                    replaceCanonicalRootPayload rootPayload (stablePlanSnapshotBytes stable)
                changedPlan = canonicalPlanDigestForTest specDigest changedBytes
            replaceRawRecord
                store
                (leaseKey project unbound)
                (encodeExactFields ["bound", "1", specDigest, changedPlan])
            replaceRawRecord
                store
                (snapshotKey project unbound)
                ( rawPlanSnapshotPayloadWithConfig
                    1
                    specDigest
                    changedPlan
                    (stablePlanSnapshotConfigDigest stable)
                    changedBytes
                )
        )
        (\_ _ failure -> case failure of ModeMalformedCanonicalSnapshot _ reason -> reason == expectedReason; _ -> False)

recoveredProductionProfileCases :: [TestTree]
recoveredProductionProfileCases =
    [ testCase "the exact seven-value Open package refines without selecting another plan identity" $
        withExistingBoundSnapshotFixture $ \store project unbound _bound stable -> do
            let keys = productionAdmissionKeys project unbound
            before <- mapM (readRecord store) keys
            outcome <-
                withBoundPlanSnapshot
                    store
                    project
                    (\_ -> assertFailure "the Open profile fixture entered the terminal callback")
                    (\root modeLease boundLease verified boundSnapshot binding recovery ->
                        pure
                            ( exactRecoveredProductionProfileEvidence
                                root
                                modeLease
                                boundLease
                                verified
                                boundSnapshot
                                binding
                                recovery
                            )
                    )
            case outcome of
                Right
                    ( Right
                            ( run
                                , profileProject
                                , profileStore
                                , revision
                                , specDigest
                                , planDigest
                                , configDigest
                                , canonicalBytes
                                , epoch
                                , revisionKind
                                )
                        ) -> do
                            run @?= "production"
                            profileProject @?= installedProjectName project
                            profileStore @?= protectedStoreIdentityText (protectedStoreIdentity store)
                            revision @?= 1
                            specDigest @?= stablePlanSnapshotSpecDigest stable
                            planDigest @?= stablePlanSnapshotDigest stable
                            configDigest @?= stablePlanSnapshotConfigDigest stable
                            canonicalBytes @?= stablePlanSnapshotBytes stable
                            epoch @?= 1
                            revisionKind @?= NormalRevision
                other -> assertFailure ("expected exact recovered profile, observed " <> show other)
            mapM (readRecord store) keys >>= (@?= before)
    , testCase "a fresh-bound lease cannot substitute for the exact existing binding" $
        withExistingBoundSnapshotFixture $ \store project unbound freshBound _stable -> do
            let keys = productionAdmissionKeys project unbound
            before <- mapM (readRecord store) keys
            outcome <-
                withBoundPlanSnapshot
                    store
                    project
                    (\_ -> assertFailure "the Open profile fixture entered the terminal callback")
                    (\root modeLease _existingBound verified boundSnapshot binding recovery ->
                        pure
                            ( withRecoveredProductionLifecycleProfile
                                root
                                modeLease
                                (unsafeCoerce freshBound)
                                verified
                                boundSnapshot
                                binding
                                recovery
                                (const ())
                            )
                    )
            case outcome of
                Right
                    ( Left
                            ( ModeEvidenceMismatch
                                    "lease binding origin"
                                    "existing"
                                    "fresh"
                                )
                        ) -> pure ()
                other -> assertFailure ("expected fresh-binding refusal, observed " <> show other)
            mapM (readRecord store) keys >>= (@?= before)
    ]
        <> recoveredProductionRevisionCases
        <> recoveredProductionProfileDriftCases

recoveredProductionRevisionCases :: [TestTree]
recoveredProductionRevisionCases =
    [ revisionCase
        "the recovered profile retains an incomplete migration classification"
        "incomplete\tmigration-12-19"
        (IncompleteMigration "migration-12-19")
    , revisionCase
        "the recovered profile preserves a UTF-8 incomplete migration key"
        (TextEncoding.encodeUtf8 "incomplete\tmigration-ő")
        (IncompleteMigration "migration-ő")
    , revisionCase
        "the recovered profile retains a completed migration classification"
        "completed\tmigration-12-19"
        (CompletedMigration "migration-12-19")
    ]
  where
    revisionCase label payload expected =
        testCase label $
            withExistingBoundSnapshotFixture $ \store project _unbound _bound _stable -> do
                writeRawRecord store (migrationKey project) payload
                before <- protectedRecordImage store
                outcome <-
                    withBoundPlanSnapshot
                        store
                        project
                        (\_ -> assertFailure "the Open profile fixture entered the terminal callback")
                        (\root modeLease boundLease verified boundSnapshot binding recovery ->
                            pure
                                ( withRecoveredProductionLifecycleProfile
                                    root
                                    modeLease
                                    boundLease
                                    verified
                                    boundSnapshot
                                    binding
                                    recovery
                                    recoveredProductionProfileRevisionKind
                                )
                        )
                outcome @?= Right (Right expected)
                protectedRecordImage store >>= (@?= before)

data RecoveredProductionProfileDrift
    = RecoveredRootDrift
    | RecoveredModeDrift
    | RecoveredLeaseDrift
    | RecoveredVerifiedSnapshotDrift
    | RecoveredBoundSnapshotDrift
    | RecoveredDigestBindingDrift
    | RecoveredRecoveryDrift
    | RecoveredRecoveryEpochDrift
    | RecoveredRootEpochDrift
    | RecoveredModeEpochDrift

recoveredProductionProfileDriftCases :: [TestTree]
recoveredProductionProfileDriftCases =
    [ mismatchCase
        "root origin drift is refused"
        RecoveredRootDrift
        Nothing
        (\failure -> case failure of ModeEvidenceMismatch "root store" _ _ -> True; _ -> False)
    , mismatchCase
        "Production mode origin drift is refused"
        RecoveredModeDrift
        Nothing
        (\failure -> case failure of ModeEvidenceMismatch "mode store" _ _ -> True; _ -> False)
    , mismatchCase
        "bound lease origin drift is refused"
        RecoveredLeaseDrift
        Nothing
        (\failure -> case failure of ModeEvidenceMismatch "root store" _ _ -> True; _ -> False)
    , mismatchCase
        "verified snapshot origin drift is refused"
        RecoveredVerifiedSnapshotDrift
        Nothing
        (\failure -> case failure of ModeEvidenceMismatch "snapshot store" _ _ -> True; _ -> False)
    , mismatchCase
        "stable canonical-byte drift is refused"
        RecoveredBoundSnapshotDrift
        Nothing
        (\failure -> case failure of ModeEvidenceMismatch "canonical bytes" _ _ -> True; _ -> False)
    , mismatchCase
        "stable plan-digest binding drift is refused"
        RecoveredDigestBindingDrift
        Nothing
        (\failure -> case failure of ModeEvidenceMismatch "digest binding" _ _ -> True; _ -> False)
    , mismatchCase
        "recovery broker generation drift is refused"
        RecoveredRecoveryEpochDrift
        (Just 1)
        (\failure -> case failure of ModeEpochMismatch 1 2 -> True; _ -> False)
    , mismatchCase
        "root broker generation drift is refused"
        RecoveredRootEpochDrift
        (Just 1)
        (== ModeEpochMismatch 1 2)
    , mismatchCase
        "Production mode broker generation drift is refused"
        RecoveredModeEpochDrift
        (Just 1)
        (== ModeEpochMismatch 1 2)
    , mismatchCase
        "bound-invocation recovery origin drift is refused"
        RecoveredRecoveryDrift
        Nothing
        (\failure -> case failure of ModeEvidenceMismatch "recovery store" _ _ -> True; _ -> False)
    , testCase "root project-name drift is refused" $
        withExistingBoundOpenPackage Nothing $ \_outerStore outerProject outer -> do
            let foreignName =
                    if installedProjectName outerProject == "foreign-project"
                        then "another-project"
                        else "foreign-project"
            -- The existing private name validator supplies a foreign identity
            -- for this pure compatibility-kernel backstop. The Mode, plan,
            -- persistence, and Open producers mint its complete real package.
            case AuthorityFixture.withInstalledProjectKernel foreignName $ \foreignProject ->
                withExistingBoundOpenPackageForProject foreignProject Nothing $ \_foreignStore _ foreignPackage ->
                    refineRecoveredProductionProfileWithDrift RecoveredRootDrift outer foreignPackage
                        @?= Left
                            ( ModeEvidenceMismatch
                                "root project"
                                (installedProjectName outerProject)
                                (installedProjectName foreignProject)
                            ) of
                Left failure -> assertFailure (show failure)
                Right action -> action
    ]
  where
    mismatchCase label drift initialForeignCounter accepts =
        testCase label $
            withExistingBoundOpenPackage Nothing $ \_outerStore _outerProject outer ->
                withExistingBoundOpenPackage initialForeignCounter $ \_foreignStore _foreignProject foreignPackage ->
                    case refineRecoveredProductionProfileWithDrift drift outer foreignPackage of
                        Left failure | accepts failure -> pure ()
                        other -> assertFailure ("expected recovered-profile refusal, observed " <> show other)

brokerCounterRefusalCase ::
    String ->
    (ProtectedStore -> RecordKey -> IO ()) ->
    Text.Text ->
    TestTree
brokerCounterRefusalCase label mutate reason =
    testCase label $
        withExistingBoundSnapshotFixture $ \store project _unbound _bound _stable -> do
            mutate store (brokerGenerationKey project)
            before <- protectedRecordImage store
            terminalCount <- newIORef (0 :: Int)
            openCount <- newIORef (0 :: Int)
            outcome <-
                withBoundPlanSnapshot
                    store
                    project
                    (\_ -> modifyIORef' terminalCount (+ 1))
                    (\_ _ _ _ _ _ _ -> modifyIORef' openCount (+ 1))
            outcome
                @?= Left
                    (SnapshotVerificationError (ModeAuthorityFailure (AuthorityInvalidIdentity reason)))
            readIORef terminalCount >>= (@?= 0)
            readIORef openCount >>= (@?= 0)
            protectedRecordImage store >>= (@?= before)

protectedRecordImage :: ProtectedStore -> IO [(Text.Text, Word64, ByteString.ByteString)]
protectedRecordImage store = do
    listed <- withProtectedEntry store listProtectedRecords
    keys <- either (fail . show) pure listed
    mapM
        ( \key -> do
            record <- requireRecord store key
            pure
                ( recordKeyText key
                , recordVersionWord (protectedRecordVersion record)
                , protectedRecordBytes record
                )
        )
        keys

malformedBoundTextRecordCase ::
    String ->
    (forall projectId. InstalledProjectIdentity projectId -> RecordKey) ->
    ByteString.ByteString ->
    TestTree
malformedBoundTextRecordCase label recordKey payload =
    testCase label $
        withExistingBoundSnapshotFixture $ \store project _unbound _bound _stable -> do
            let key = recordKey project
            writeRawRecord store key payload
            before <- protectedRecordImage store
            terminalCount <- newIORef (0 :: Int)
            openCount <- newIORef (0 :: Int)
            outcome <-
                withBoundPlanSnapshot
                    store
                    project
                    (\_ -> modifyIORef' terminalCount (+ 1))
                    (\_ _ _ _ _ _ _ -> modifyIORef' openCount (+ 1))
            outcome @?= Left (SnapshotVerificationError (ModeMalformedRecord (recordKeyText key)))
            readIORef terminalCount >>= (@?= 0)
            readIORef openCount >>= (@?= 0)
            protectedRecordImage store >>= (@?= before)

refusalCase ::
    String ->
    ( forall projectId brokerGeneration.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      StablePlanSnapshot ->
      IO ()
    ) ->
    ( forall projectId brokerGeneration.
      InstalledProjectIdentity projectId ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      ModeError ->
      Bool
    ) ->
    TestTree
refusalCase = refusalCaseWithPlan (const snapshotStepPlan)

refusalCaseWithPlan ::
    (FilePath -> StepPlan) ->
    String ->
    ( forall projectId brokerGeneration.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      StablePlanSnapshot ->
      IO ()
    ) ->
    ( forall projectId brokerGeneration.
      InstalledProjectIdentity projectId ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      ModeError ->
      Bool
    ) ->
    TestTree
refusalCaseWithPlan planBuilder label mutate accepts =
    testCase label $
        withExistingBoundSnapshotFixtureUsing Nothing planBuilder $ \store project unbound _bound stable -> do
            mutate store project unbound stable
            let keys = productionAdmissionKeys project unbound
            before <- mapM (readRecord store) keys
            terminalCount <- newIORef (0 :: Int)
            openCount <- newIORef (0 :: Int)
            outcome <-
                withBoundPlanSnapshot
                    store
                    project
                    (\_ -> modifyIORef' terminalCount (+ 1))
                    (\_ _ _ _ _ _ _ -> modifyIORef' openCount (+ 1))
            case outcome of
                Left (SnapshotVerificationError failure)
                    | accepts project unbound failure -> case failure of
                        ModeMalformedCanonicalSnapshot key reason -> do
                            key @?= recordKeyText (snapshotKey project unbound)
                            let diagnostic = modeErrorMessage failure
                            assertBool
                                "the canonical snapshot diagnostic retains its key and reason"
                                (key `Text.isInfixOf` diagnostic && reason `Text.isInfixOf` diagnostic)
                        _ -> pure ()
                other -> assertFailure ("expected existing-bound refusal, observed " <> show other)
            readIORef terminalCount >>= (@?= 0)
            readIORef openCount >>= (@?= 0)
            mapM (readRecord store) keys >>= (@?= before)

snapshotFilesystemFailureCases :: [TestTree]
snapshotFilesystemFailureCases =
    [ testCase "an unavailable records directory before the snapshot write leaves the lease unbound" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            lease <- requireRecord store (leaseKey project unbound)
            continued <- newIORef (0 :: Int)
            outcome <-
                withBlockedRecordsPath store $
                    withPersistedPlanSnapshot root unbound plan $ \_ _ _ _ _ ->
                        modifyIORef' continued (+ 1)
            assertUnavailableRecordsFailure store outcome
            readIORef continued >>= (@?= 0)
            readRecord store (snapshotKey project unbound) >>= (@?= Nothing)
            requireRecord store (leaseKey project unbound) >>= (@?= lease)
            assertLeaseVersion store project unbound 1
            assertNoPreparedOrEffectRecords store
    , testCase "an unavailable records directory before re-verification preserves the snapshot and unbound lease" $
        withPersistedSnapshotPlan $ \store project root unbound plan -> do
            continued <- newIORef (0 :: Int)
            writeStableSnapshot store project unbound (renderSnapshot plan)
            snapshot <- requireRecord store (snapshotKey project unbound)
            lease <- requireRecord store (leaseKey project unbound)
            outcome <-
                withBlockedRecordsPath store $
                    withPersistedPlanSnapshot root unbound plan $ \_ _ _ _ _ ->
                        modifyIORef' continued (+ 1)
            assertUnavailableRecordsFailure store outcome
            requireRecord store (snapshotKey project unbound) >>= (@?= snapshot)
            requireRecord store (leaseKey project unbound) >>= (@?= lease)
            assertLeaseVersion store project unbound 1
            readIORef continued >>= (@?= 0)
            assertNoPreparedOrEffectRecords store
    ]

assertUnavailableRecordsFailure :: ProtectedStore -> Either SnapshotError () -> IO ()
#ifdef mingw32_HOST_OS
assertUnavailableRecordsFailure _ outcome =
    outcome @?= Left (SnapshotVerificationError (ModeLeaseMissing "production"))
#else
assertUnavailableRecordsFailure store outcome = case outcome of
    Left (SnapshotVerificationError (ModeStoreFailure (ProtectedIOFailure "read a protected record" diagnostic))) ->
        assertBool
            "the read failure names the unavailable records directory"
            (Text.pack (protectedStoreRoot store </> "records") `Text.isInfixOf` diagnostic)
    other -> assertFailure ("expected the unavailable-records read to fail, observed " <> show other)
#endif

withBlockedRecordsPath :: ProtectedStore -> IO result -> IO result
withBlockedRecordsPath store action =
    bracket_
        (renameDirectory records unavailable)
        (renameDirectory unavailable records)
        (bracket_ (writeFile records "blocked") (removeFile records) action)
  where
    records = protectedStoreRoot store </> "records"
    unavailable = records <> ".filesystem-refusal"

withBlockedRecordPath :: ProtectedStore -> RecordKey -> IO result -> IO result
withBlockedRecordPath store key action =
    bracket_
        (renameFile path unavailable)
        (renameFile unavailable path)
        (bracket_ (createDirectory path) (removeDirectory path) action)
  where
    path = recordPath store key
    unavailable = path <> ".filesystem-refusal"

exactPersistedEvidence ::
    VerifiedPlanSnapshot scope specDigest planDigest ->
    BoundPlanSnapshot scope specDigest planDigest planId ->
    PlanDigestBinding scope specDigest planDigest planId ->
    BoundRunLease scope specDigest planDigest brokerGeneration ->
    NormalActiveRecovery scope specDigest planDigest planId brokerGeneration ->
    IO (Text.Text, Text.Text, ByteString.ByteString, Text.Text)
exactPersistedEvidence verified bound _binding lease active = do
    planSnapshotRevision verified @?= 1
    planSnapshotCanonicalBytes verified @?= Just (boundPlanSnapshotBytes bound)
    boundRunLeaseSpecDigest lease @?= planSnapshotSpecDigest verified
    boundRunLeasePlanDigest lease @?= planSnapshotPlanDigest verified
    boundRunLeaseRunText lease @?= planSnapshotRunText verified
    normalActiveRecoveryRunText active @?= planSnapshotRunText verified
    pure
        ( planSnapshotSpecDigest verified
        , planSnapshotPlanDigest verified
        , boundPlanSnapshotBytes bound
        , planSnapshotRunText verified
        )

exactBoundAdmissionEvidence ::
    RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
    ProjectModeLease projectId ProductionMode brokerGeneration ->
    BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
    VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
    BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
    PlanDigestBinding (Production projectId) specDigest planDigest planId ->
    BoundInvocationRecovery
        (Production projectId)
        specDigest
        planDigest
        planId
        brokerGeneration ->
    IO (Text.Text, Text.Text, ByteString.ByteString, Word64, OpenRevisionKind)
exactBoundAdmissionEvidence root modeLease lease verified bound _binding recovery = do
    rootAuthorityVerb root @?= ProjectUp
    let rootEpoch = brokerEpochWord (rootAuthorityEpoch root)
    brokerEpochWord (projectModeLeaseEpoch modeLease) @?= rootEpoch
    planSnapshotRevision verified @?= 1
    planSnapshotCanonicalBytes verified @?= Just (boundPlanSnapshotBytes bound)
    boundRunLeaseSpecDigest lease @?= planSnapshotSpecDigest verified
    boundRunLeasePlanDigest lease @?= planSnapshotPlanDigest verified
    boundRunLeaseRunText lease @?= planSnapshotRunText verified
    boundInvocationRecoveryRunText recovery @?= planSnapshotRunText verified
    pure
        ( planSnapshotSpecDigest verified
        , planSnapshotPlanDigest verified
        , boundPlanSnapshotBytes bound
        , rootEpoch
        , boundInvocationRecoveryRevisionKind recovery
        )

exactRecoveredProductionProfileEvidence ::
    RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
    ProjectModeLease projectId ProductionMode brokerGeneration ->
    BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
    VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
    BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
    PlanDigestBinding (Production projectId) specDigest planDigest planId ->
    BoundInvocationRecovery
        (Production projectId)
        specDigest
        planDigest
        planId
        brokerGeneration ->
    Either
        ModeError
        ( Text.Text
        , Text.Text
        , Text.Text
        , Word64
        , Text.Text
        , Text.Text
        , Text.Text
        , ByteString.ByteString
        , Word64
        , OpenRevisionKind
        )
exactRecoveredProductionProfileEvidence root modeLease lease verified bound binding recovery =
    withRecoveredProductionLifecycleProfile
        root
        modeLease
        lease
        verified
        bound
        binding
        recovery
        ( \profile ->
            ( recoveredProductionProfileRunText profile
            , recoveredProductionProfileProjectName profile
            , recoveredProductionProfileStoreIdentity profile
            , recoveredProductionProfileRevision profile
            , recoveredProductionProfileSpecDigest profile
            , recoveredProductionProfilePlanDigest profile
            , recoveredProductionProfileConfigDigest profile
            , recoveredProductionProfileCanonicalBytes profile
            , recoveredProductionProfileEpoch profile
            , recoveredProductionProfileRevisionKind profile
            )
        )

data RecoveredProductionProfileInputs projectId specDigest planDigest planId brokerGeneration
    = RecoveredProductionProfileInputs
        (RootInvocationAuthority (Production projectId) brokerGeneration VerbUp)
        (ProjectModeLease projectId ProductionMode brokerGeneration)
        (BoundRunLease (Production projectId) specDigest planDigest brokerGeneration)
        (VerifiedPlanSnapshot (Production projectId) specDigest planDigest)
        (BoundPlanSnapshot (Production projectId) specDigest planDigest planId)
        (PlanDigestBinding (Production projectId) specDigest planDigest planId)
        ( BoundInvocationRecovery
            (Production projectId)
            specDigest
            planDigest
            planId
            brokerGeneration
        )

refineRecoveredProductionProfileWithDrift ::
    forall
        projectId
        specDigest
        planDigest
        planId
        brokerGeneration
        otherProjectId
        otherSpecDigest
        otherPlanDigest
        otherPlanId
        otherBrokerGeneration.
    RecoveredProductionProfileDrift ->
    RecoveredProductionProfileInputs
        projectId specDigest planDigest planId brokerGeneration ->
    RecoveredProductionProfileInputs
        otherProjectId otherSpecDigest otherPlanDigest otherPlanId otherBrokerGeneration ->
    Either ModeError ()
refineRecoveredProductionProfileWithDrift
    drift
    (RecoveredProductionProfileInputs root modeLease lease verified bound binding recovery)
    ( RecoveredProductionProfileInputs
            otherRoot
            otherModeLease
            otherLease
            otherVerified
            otherBound
            otherBinding
            otherRecovery
        ) =
        -- Ordinary callers cannot construct these cross-index packages: the
        -- compile-fail suite proves that boundary.  Deliberate test-only
        -- unsafe coercion reaches the runtime backstops against compromised or
        -- package-private evidence without weakening the public API.
        case drift of
            RecoveredRootDrift -> apply (unsafeCoerce otherRoot) modeLease lease verified bound binding recovery
            RecoveredModeDrift -> apply root (unsafeCoerce otherModeLease) lease verified bound binding recovery
            RecoveredLeaseDrift -> apply root modeLease (unsafeCoerce otherLease) verified bound binding recovery
            RecoveredVerifiedSnapshotDrift ->
                apply root modeLease lease (unsafeCoerce otherVerified) bound binding recovery
            RecoveredBoundSnapshotDrift ->
                apply root modeLease lease verified (unsafeCoerce otherBound) binding recovery
            RecoveredDigestBindingDrift ->
                apply root modeLease lease verified bound (unsafeCoerce otherBinding) recovery
            RecoveredRecoveryDrift ->
                apply root modeLease lease verified bound binding (unsafeCoerce otherRecovery)
            RecoveredRecoveryEpochDrift ->
                apply root modeLease lease verified bound binding (unsafeCoerce otherRecovery)
            RecoveredRootEpochDrift -> apply (unsafeCoerce otherRoot) modeLease lease verified bound binding recovery
            RecoveredModeEpochDrift -> apply root (unsafeCoerce otherModeLease) lease verified bound binding recovery
  where
    apply ::
        RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
        ProjectModeLease projectId ProductionMode brokerGeneration ->
        BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
        VerifiedPlanSnapshot (Production projectId) specDigest planDigest ->
        BoundPlanSnapshot (Production projectId) specDigest planDigest planId ->
        PlanDigestBinding (Production projectId) specDigest planDigest planId ->
        BoundInvocationRecovery
            (Production projectId)
            specDigest
            planDigest
            planId
            brokerGeneration ->
        Either ModeError ()
    apply exactRoot exactMode exactLease exactVerified exactBound exactBinding exactRecovery =
        withRecoveredProductionLifecycleProfile
            exactRoot
            exactMode
            exactLease
            exactVerified
            exactBound
            exactBinding
            exactRecovery
            (const ())

withExistingBoundOpenPackage ::
    Maybe Word64 ->
    ( forall projectId specDigest planDigest planId brokerGeneration.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RecoveredProductionProfileInputs
        projectId specDigest planDigest planId brokerGeneration ->
      IO result
    ) ->
    IO result
withExistingBoundOpenPackage initialCounter use =
    Fixture.withFixtureInstalledProject $ \project ->
        withExistingBoundOpenPackageForProject project initialCounter use

withExistingBoundOpenPackageForProject ::
    forall projectId result.
    InstalledProjectIdentity projectId ->
    Maybe Word64 ->
    ( forall specDigest planDigest planId brokerGeneration.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RecoveredProductionProfileInputs
        projectId specDigest planDigest planId brokerGeneration ->
      IO result
    ) ->
    IO result
withExistingBoundOpenPackageForProject project initialCounter use =
    withPersistedSnapshotPlanForProject project initialCounter (const snapshotStepPlan) $ \store _ freshRoot unbound plan -> do
        persisted <- withPersistedPlanSnapshot freshRoot unbound plan (\_ _ _ _ _ -> pure ())
        either (fail . show) pure persisted
        admitted <-
            withBoundPlanSnapshot
                store
                project
                (\_ -> assertFailure "the Open package fixture entered the terminal callback")
                (\root modeLease lease verified bound binding recovery ->
                    use
                        store
                        project
                        ( RecoveredProductionProfileInputs
                            root
                            modeLease
                            lease
                            verified
                            bound
                            binding
                            recovery
                        )
                )
        either (fail . show) pure admitted

withExistingBoundSnapshotFixture ::
    ( forall projectId brokerGeneration specDigest planDigest.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      BoundRunLease
        (Production projectId)
        specDigest
        planDigest
        brokerGeneration ->
      StablePlanSnapshot ->
      IO result
    ) ->
    IO result
withExistingBoundSnapshotFixture use =
    withExistingBoundSnapshotFixtureAtCounter Nothing use

withExistingBoundSnapshotFixtureAtCounter ::
    Maybe Word64 ->
    ( forall projectId brokerGeneration specDigest planDigest.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      BoundRunLease
        (Production projectId)
        specDigest
        planDigest
        brokerGeneration ->
      StablePlanSnapshot ->
      IO result
    ) ->
    IO result
withExistingBoundSnapshotFixtureAtCounter initialCounter use =
    withExistingBoundSnapshotFixtureUsing initialCounter (const snapshotStepPlan) use

withExistingBoundSnapshotFixtureUsing ::
    Maybe Word64 ->
    (FilePath -> StepPlan) ->
    ( forall projectId brokerGeneration specDigest planDigest.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      BoundRunLease (Production projectId) specDigest planDigest brokerGeneration ->
      StablePlanSnapshot ->
      IO result
    ) ->
    IO result
withExistingBoundSnapshotFixtureUsing initialCounter planBuilder use =
    withPersistedSnapshotPlanUsing initialCounter planBuilder $ \store project root unbound plan -> do
        let stable = renderSnapshot plan
        admitted <-
            withPersistedPlanSnapshot root unbound plan $ \_ _ _ bound _ ->
                use store project unbound bound stable
        either (fail . show) pure admitted

assertProtectedEntryReleased :: ProtectedStore -> IO ()
assertProtectedEntryReleased store = do
    attempted <- tryProtectedEntry store (\_ -> pure (Right ()))
    case attempted of
        Right (Just ()) -> pure ()
        other -> assertFailure ("snapshot callback ran before protected unlock: " <> show other)

productionAdmissionKeys ::
    InstalledProjectIdentity projectId ->
    UnboundRunLease scope brokerGeneration ->
    [RecordKey]
productionAdmissionKeys project unbound =
    [ authorityBindingKey
    , brokerGenerationKey project
    , productionModeKey project
    , leaseKey project unbound
    , snapshotKey project unbound
    , productionInvocationKey project
    , migrationKey project
    ]

authorityBindingKey :: RecordKey
authorityBindingKey = exactRecordKey "authority.binding"

productionModeKey :: InstalledProjectIdentity projectId -> RecordKey
productionModeKey project = exactRecordKey ("mode." <> fixtureRecordName (installedProjectName project))

productionInvocationKey :: InstalledProjectIdentity projectId -> RecordKey
productionInvocationKey project =
    exactRecordKey ("invocation." <> fixtureRecordName (installedProjectName project) <> recordTupleSeparator <> "production")

migrationKey :: InstalledProjectIdentity projectId -> RecordKey
migrationKey project =
    exactRecordKey ("migration." <> fixtureRecordName (installedProjectName project) <> recordTupleSeparator <> "production")

fixtureRecordName :: Text.Text -> Text.Text
fixtureRecordName = either (error . show) id . mkRecordName

exactRecordKey :: Text.Text -> RecordKey
exactRecordKey = either (error . show) id . mkRecordKey

encodeExactFields :: [Text.Text] -> ByteString.ByteString
encodeExactFields = TextEncoding.encodeUtf8 . Text.intercalate "\t"

rawPlanSnapshotPayload ::
    Word64 ->
    StablePlanSnapshot ->
    ByteString.ByteString ->
    ByteString.ByteString
rawPlanSnapshotPayload envelopeVersion stable canonicalBytes =
    rawPlanSnapshotPayloadWithConfig
        envelopeVersion
        (stablePlanSnapshotSpecDigest stable)
        (stablePlanSnapshotDigest stable)
        (stablePlanSnapshotConfigDigest stable)
        canonicalBytes

rawPlanSnapshotPayloadWithConfig ::
    Word64 ->
    Text.Text ->
    Text.Text ->
    Text.Text ->
    ByteString.ByteString ->
    ByteString.ByteString
rawPlanSnapshotPayloadWithConfig envelopeVersion specDigest planDigest configDigest canonicalBytes =
    LazyByteString.toStrict
        ( Builder.toLazyByteString
            ( Builder.byteString "HOSTBOOTSTRAP-SNAPSHOT"
                <> Builder.word64BE envelopeVersion
                <> Builder.word64BE 1
                <> encodeSnapshotText specDigest
                <> encodeSnapshotText planDigest
                <> Builder.word8 1
                <> encodeSnapshotText configDigest
                <> encodeSnapshotBytes canonicalBytes
            )
        )

replaceCanonicalVersion :: Word64 -> ByteString.ByteString -> ByteString.ByteString
replaceCanonicalVersion version bytes =
    planMagic
        <> LazyByteString.toStrict (Builder.toLazyByteString (Builder.word64BE version))
        <> ByteString.drop (ByteString.length planMagic + 8) bytes
  where
    planMagic = "HOSTBOOTSTRAP-PLAN"

replaceCanonicalRoot :: FilePath -> ByteString.ByteString -> ByteString.ByteString
replaceCanonicalRoot root bytes =
    replaceCanonicalRootPayload (encodedRootPayload root) bytes

replaceCanonicalRootPayload :: ByteString.ByteString -> ByteString.ByteString -> ByteString.ByteString
replaceCanonicalRootPayload rootPayload bytes =
    case rootFrameOffsets bytes of
        Nothing -> error "the fixture canonical root prefix is malformed"
        Just (rootValueOffset, afterRoot) ->
            ByteString.take rootValueOffset bytes
                <> LazyByteString.toStrict
                    (Builder.toLazyByteString (encodeSnapshotBytes rootPayload))
                <> ByteString.drop afterRoot bytes

rootFrameOffsets :: ByteString.ByteString -> Maybe (Int, Int)
rootFrameOffsets bytes = do
    let afterVersion = ByteString.length ("HOSTBOOTSTRAP-PLAN" :: ByteString.ByteString) + 8
    rootValueOffset <- skipCanonicalFrame bytes afterVersion
    afterRoot <- skipCanonicalFrame bytes rootValueOffset
    pure (rootValueOffset, afterRoot)

encodedRootPayload :: FilePath -> ByteString.ByteString
encodedRootPayload root =
    LazyByteString.toStrict
        ( Builder.toLazyByteString
            (foldMap (Builder.word32BE . fromIntegral . ord) root)
        )

replaceCanonicalStepCount :: Word64 -> ByteString.ByteString -> ByteString.ByteString
replaceCanonicalStepCount count bytes =
    case canonicalStepCountOffset bytes of
        Nothing -> error "the fixture canonical plan prefix is malformed"
        Just offset ->
            ByteString.take offset bytes
                <> encodedWord count
                <> ByteString.drop (offset + 8) bytes

canonicalStepCountOffset :: ByteString.ByteString -> Maybe Int
canonicalStepCountOffset bytes = do
    let afterVersion = ByteString.length ("HOSTBOOTSTRAP-PLAN" :: ByteString.ByteString) + 8
    afterRootTag <- skipCanonicalFrame bytes afterVersion
    afterRoot <- skipCanonicalFrame bytes afterRootTag
    afterSpecTag <- skipCanonicalFrame bytes afterRoot
    afterSpec <- skipCanonicalFrame bytes afterSpecTag
    afterConfigTag <- skipCanonicalFrame bytes afterSpec
    afterConfig <- skipCanonicalFrame bytes afterConfigTag
    skipCanonicalFrame bytes afterConfig

skipCanonicalFrame :: ByteString.ByteString -> Int -> Maybe Int
skipCanonicalFrame bytes offset = do
    frameLength <- canonicalWordAt bytes offset
    let payloadOffset = offset + 8
    if payloadOffset > ByteString.length bytes
        || frameLength > fromIntegral (ByteString.length bytes - payloadOffset)
        then Nothing
        else Just (payloadOffset + fromIntegral frameLength)

canonicalWordAt :: ByteString.ByteString -> Int -> Maybe Word64
canonicalWordAt bytes offset =
    let wordBytes = ByteString.take 8 (ByteString.drop offset bytes)
     in if ByteString.length wordBytes /= 8
            then Nothing
            else Just (ByteString.foldl' (\value byte -> value * 256 + fromIntegral byte) 0 wordBytes)

encodedWord :: Word64 -> ByteString.ByteString
encodedWord = LazyByteString.toStrict . Builder.toLazyByteString . Builder.word64BE

canonicalTextFrame :: Text.Text -> ByteString.ByteString
canonicalTextFrame = LazyByteString.toStrict . Builder.toLazyByteString . encodeSnapshotText

canonicalPlanDigestForTest :: Text.Text -> ByteString.ByteString -> Text.Text
canonicalPlanDigestForTest specDigest bytes = specDigest <> ":" <> sha256HexForTest bytes

sha256HexForTest :: ByteString.ByteString -> Text.Text
sha256HexForTest payload =
    Text.pack (concatMap hex (ByteArray.unpack (Hash.hashWith Hash.SHA256 payload)))
  where
    hex byte = [hexDigit (byte `shiftR` 4), hexDigit (byte .&. 0x0f)]
    hexDigit nibble = ByteStringChar8.index "0123456789abcdef" (fromIntegral nibble)

withPersistedSnapshotPlan ::
    ( forall projectId brokerGeneration specDigest configId planId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      IO result
    ) ->
    IO result
withPersistedSnapshotPlan = withPersistedSnapshotPlanAtCounter Nothing

withPersistedSnapshotPlanAtCounter ::
    Maybe Word64 ->
    ( forall projectId brokerGeneration specDigest configId planId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      IO result
    ) ->
    IO result
withPersistedSnapshotPlanAtCounter initialCounter use =
    withPersistedSnapshotPlanUsing initialCounter (const snapshotStepPlan) use

withPersistedSnapshotPlanUsing ::
    Maybe Word64 ->
    (FilePath -> StepPlan) ->
    ( forall projectId brokerGeneration specDigest configId planId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      ProjectPlan (Production projectId) specDigest planId configId Fixture.ProjectConfig ->
      IO result
    ) ->
    IO result
withPersistedSnapshotPlanUsing initialCounter planBuilder use =
    Fixture.withFixtureInstalledProject $ \project ->
        withPersistedSnapshotPlanForProject project initialCounter planBuilder use

withPersistedSnapshotPlanForProject ::
    forall projectId result.
    InstalledProjectIdentity projectId ->
    Maybe Word64 ->
    (FilePath -> StepPlan) ->
    ( forall brokerGeneration specDigest configId planId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      ProjectPlan (Production projectId) specDigest planId configId Fixture.ProjectConfig ->
      IO result
    ) ->
    IO result
withPersistedSnapshotPlanForProject project initialCounter planBuilder use =
    withSystemTempDirectory "hostbootstrap-persisted-project-plan" $ \directory -> do
        store <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
        case initialCounter of
            Nothing -> pure ()
            Just counter ->
                writeRawRecord
                    store
                    (brokerGenerationKey project)
                    (ByteStringChar8.pack (show counter))
        rooted <-
            withCanonicalProjectRoot
                (directory </> "fixture.dhall")
                "."
                ( \(canonicalRoot :: CanonicalProjectRoot (Production projectId) rootId) ->
                    withProductionRoot store project ProjectUp $ \productionRoot -> do
                        let unbound = productionRootUnboundLease productionRoot
                        opened <-
                            withProductionLifecycleProfile
                                (rootScopeAuthority (productionRootAuthority productionRoot))
                                (productionActiveMode (productionRootModeLease productionRoot))
                                unbound
                                ( \profile ->
                                    withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \codec -> do
                                        let value =
                                                Fixture.defaultProjectConfig
                                                    (installedProjectName project)
                                                    (Text.pack (canonicalProjectRootPath canonicalRoot))
                                                    Context.HostOrchestrator
                                        validated <-
                                            withValidatedConfig codec value $ \_wire config ->
                                                withAdmittedSnapshotPlan
                                                    (planBuilder (canonicalProjectRootPath canonicalRoot))
                                                    profile
                                                    canonicalRoot
                                                    config
                                                    ( use
                                                        store
                                                        project
                                                        (productionRootAuthority productionRoot)
                                                        unbound
                                                    )
                                        either fail pure validated
                                )
                        case opened of
                            Left failure -> pure (Left (ModeAuthorityFailure failure))
                            Right action -> Right <$> action
                )
        admitted <- either (fail . show) pure rooted
        either (fail . show) pure admitted

withAdmittedSnapshotPlan ::
    StepPlan ->
    LifecycleProfile scope ->
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    (forall planId. ProjectPlan scope specDigest planId configId cfg -> IO result) ->
    IO result
withAdmittedSnapshotPlan steps profile canonicalRoot config use = do
    drafts <-
        either (fail . show) pure
            (planDraftsFromValidatedBuilder canonicalRoot config (\_ _ -> Right steps))
    action <- either (fail . show) pure (withProjectPlan profile canonicalRoot config drafts use)
    action

snapshotStepPlan :: StepPlan
snapshotStepPlan =
    case
        mkStepPlan
            [ contextInitStep
                "context"
                (StepFrame "host" "Host")
                (const (pure StepChanged))
            ]
    of
        Left failure -> error (show failure)
        Right plan -> plan

richSnapshotPlan :: FilePath -> StepPlan
richSnapshotPlan parentRoot =
    either (error . show) id $
        mkStepPlan
            [ declaresProviderResource providerResourceAtCurrentFrame $
                descendsVia (inContainer container emptyVMStack) $
                    deployVMStep "provider with a mounted child" (StepFrame "host" "Host") (const (pure StepChanged))
            , contextInitStep "child" (StepFrame "container" "Container") (const (pure StepChanged))
            ]
  where
    container =
        ContainerLift
            { clImage = "snapshot-fixture:latest"
            , clPlacement = ProviderGuestContainer
            , clMounts = [V.Mount{V.source = Text.pack parentRoot, V.target = "/snapshot-fixture", V.readOnly = True}]
            , clExtraArgs = []
            , clRemoveAfter = True
            , clConfigDelivery = Nothing
            }

snapshotKey ::
    InstalledProjectIdentity projectId ->
    UnboundRunLease scope brokerGeneration ->
    RecordKey
snapshotKey project unbound =
    either (error . show) id
        ( mkRecordKey
            ( "snapshot."
                <> fixtureRecordName (installedProjectName project)
                <> recordTupleSeparator
                <> fixtureRecordName (unboundRunLeaseRunText unbound)
            )
        )

leaseKey ::
    InstalledProjectIdentity projectId ->
    UnboundRunLease scope brokerGeneration ->
    RecordKey
leaseKey project unbound =
    either (error . show) id
        ( mkRecordKey
            ( "lease."
                <> fixtureRecordName (installedProjectName project)
                <> recordTupleSeparator
                <> fixtureRecordName (unboundRunLeaseRunText unbound)
            )
        )

brokerGenerationKey :: InstalledProjectIdentity projectId -> RecordKey
brokerGenerationKey project =
    either (error . show) id
        (mkRecordKey ("broker." <> fixtureRecordName (installedProjectName project) <> ".generation"))

recordPath :: ProtectedStore -> RecordKey -> FilePath
recordPath store key =
    protectedStoreRoot store
        </> "records"
        </> Text.unpack (recordKeyText key)
        <.> "rec"

readRecord :: ProtectedStore -> RecordKey -> IO (Maybe ProtectedRecord)
readRecord store key = do
    entered <- withProtectedEntry store (\session -> readProtectedRecord session key)
    either (fail . show) pure entered

requireRecord :: ProtectedStore -> RecordKey -> IO ProtectedRecord
requireRecord store key = do
    observed <- readRecord store key
    maybe (assertFailure ("missing protected record " <> Text.unpack (recordKeyText key))) pure observed

writeRawRecord :: ProtectedStore -> RecordKey -> ByteString.ByteString -> IO ()
writeRawRecord store key bytes = do
    entered <-
        withProtectedEntry store $ \session ->
            compareAndSwapProtectedRecord session key ExpectAbsent bytes
    either (fail . show) (const (pure ())) entered

replaceRawRecord :: ProtectedStore -> RecordKey -> ByteString.ByteString -> IO ()
replaceRawRecord store key bytes = do
    record <- requireRecord store key
    entered <-
        withProtectedEntry store $ \session ->
            compareAndSwapProtectedRecord
                session
                key
                (ExpectVersion (protectedRecordVersion record))
                bytes
    either (fail . show) (const (pure ())) entered

deleteRecord :: ProtectedStore -> RecordKey -> IO ()
deleteRecord store key = do
    record <- requireRecord store key
    entered <-
        withProtectedEntry store $ \session ->
            compareAndDeleteProtectedRecord
                session
                key
                (ExpectVersion (protectedRecordVersion record))
    either (fail . show) pure entered

advanceRecordVersion :: ProtectedStore -> RecordKey -> IO ()
advanceRecordVersion store key = do
    record <- requireRecord store key
    entered <-
        withProtectedEntry store $ \session ->
            compareAndSwapProtectedRecord
                session
                key
                (ExpectVersion (protectedRecordVersion record))
                (protectedRecordBytes record)
    either (fail . show) (const (pure ())) entered

assertLeaseVersion ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    UnboundRunLease scope brokerGeneration ->
    Word64 ->
    IO ()
assertLeaseVersion store project unbound expected = do
    record <- requireRecord store (leaseKey project unbound)
    recordVersionWord (protectedRecordVersion record) @?= expected

assertNoPreparedOrEffectRecords :: ProtectedStore -> IO ()
assertNoPreparedOrEffectRecords store = do
    entered <- withProtectedEntry store listProtectedRecords
    keys <- either (fail . show) pure entered
    let forbidden key =
            any
                (`Text.isPrefixOf` recordKeyText key)
                ["session.", "effect.", "operation.", "prepared."]
    assertBool
        "snapshot admission created no session, prepared operation, or effect record"
        (not (any forbidden keys))

writeStableSnapshot ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    UnboundRunLease scope brokerGeneration ->
    StablePlanSnapshot ->
    IO ()
writeStableSnapshot store project unbound stable =
    writeRawPlanSnapshot
        store
        project
        (unboundRunLeaseRunText unbound)
        (stablePlanSnapshotSpecDigest stable)
        (stablePlanSnapshotDigest stable)
        (stablePlanSnapshotConfigDigest stable)
        (stablePlanSnapshotBytes stable)

writeRawPlanSnapshot ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    Text.Text ->
    Text.Text ->
    Text.Text ->
    Text.Text ->
    ByteString.ByteString ->
    IO ()
writeRawPlanSnapshot store project runName specDigest planDigest configDigest canonicalBytes =
    writeRawRecord store key payload
  where
    key =
        either (error . show) id
            (mkRecordKey ("snapshot." <> fixtureRecordName (installedProjectName project) <> recordTupleSeparator <> fixtureRecordName runName))
    payload =
        LazyByteString.toStrict
            ( Builder.toLazyByteString
                ( Builder.byteString "HOSTBOOTSTRAP-SNAPSHOT"
                    <> Builder.word64BE 1
                    <> Builder.word64BE 1
                    <> encodeSnapshotText specDigest
                    <> encodeSnapshotText planDigest
                    <> Builder.word8 1
                    <> encodeSnapshotText configDigest
                    <> encodeSnapshotBytes canonicalBytes
                )
            )

encodeSnapshotText :: Text.Text -> Builder.Builder
encodeSnapshotText = encodeSnapshotBytes . TextEncoding.encodeUtf8

encodeSnapshotBytes :: ByteString.ByteString -> Builder.Builder
encodeSnapshotBytes bytes =
    Builder.word64BE (fromIntegral (ByteString.length bytes))
        <> Builder.byteString bytes

assertSnapshotMismatch :: Show result => Either SnapshotError result -> IO ()
assertSnapshotMismatch outcome =
    case outcome of
        Left (SnapshotVerificationError (ModeSnapshotMismatch _ _)) -> pure ()
        other -> assertFailure ("expected immutable snapshot mismatch, observed " <> show other)
