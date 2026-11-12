{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module ColimaSpec (colimaLiveAvailable, contextNamespaceSupported, directoryReleaseSupported, tests, runShippedOwnerProbe, runResolverDescriptorLimitProbe) where

import ConditionalCase (conditionalAction, conditionalCase)
import SealedExportInventory (pinnedPrivateExportLists)
import qualified Expect as OwnershipFixture
import Control.Concurrent (forkFinally, forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), IOException, SomeException, bracket, bracket_, displayException, finally, fromException, try)
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.Foldable (for_)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (intercalate, isInfixOf, isPrefixOf, nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text.Encoding
import HostBootstrap.Digest (sha256Hex)
import qualified HostBootstrap.Ensure.Colima.Backend.Names as ColimaNames
import qualified HostBootstrap.Ensure.Colima.Backend.Identity as ColimaIdentity
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Cluster.Budget
import HostBootstrap.Cluster.Cordon (mkResourceBudget)
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Context as Context
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Effect.Run (CapturedRun (..))
import HostBootstrap.Effect.Interpreter (resolveLaunch)
import HostBootstrap.Effect.Vocabulary (
    EffectTarget (ToolTarget),
    HostCommand (commandArguments, commandTarget),
 )
import HostBootstrap.Ensure.Colima
import qualified HostBootstrap.Ensure.Colima.Backend.Resolver as Resolver
import HostBootstrap.Ensure.Colima.Backend.Resolver.Testing
import HostBootstrap.Ensure.Colima.Backend.Runner (BackendNamespace (..), BoundedToolResult (..), runShippedCommand, runShippedCommandEntry)
import HostBootstrap.Ensure.Colima.Backend.Stage
import HostBootstrap.Ensure.Colima.Command
import HostBootstrap.Ensure.Colima.Ownership (
    ColimaOwnershipKeys,
    colimaDirectoryBinding,
    ColimaArtifactObservation (..),
    ColimaManagedObservation (..),
    ColimaManagedOutcome (..),
    ColimaNativeOwnershipFault (ColimaNativeOwnershipRefused),
    ColimaProfileMutationFault (..),
    colimaMutationAcquireObservation,
    colimaContextAcquisitionNeedsProbe,
    admitColimaContextAcquisition,
    colimaContextRemovalNeeded,
    admitColimaContextFingerprint,
    admitColimaContextRemovalAbsence,
    ColimaStartedObservation (..),
    acquireColimaDirectory,
    acquireManagedColimaProfileWith,
    bindColimaCreationIdentities,
    cleanupManagedColimaProfileWith,
    admitColimaCleanupLineage,
    ColimaCleanupResume (..),
    admitColimaCleanupResume,
    ColimaCleanupProfileObservation (..), classifyColimaCleanupProfile, admitColimaCleanupMachine, colimaCleanupDeleteResult, admitColimaCleanupProfileAbsence, admitColimaReleaseManifest,
    colimaDiskKey,
    colimaContextKey,
    colimaHomeKey,
    colimaManifestKey,
    colimaProfileKey,
    ensureColimaDirectory,
    observeColimaArtifactsWith,
    prepareColimaNamespaces,
    publishPreparedColimaManifest,
    readColimaStage,
    releaseColimaDirectory,
    runManagedColimaDockerWith,
    admitColimaManagedDockerRoute,
    admitStoredColimaDockerRoute,
    releaseColimaContextNamespace,
    releaseColimaReleasedNamespaces,
    colimaCacheKey,
    colimaTemporaryKey,
    colimaStageKey,
    colimaDockerCommandResult,
    settleManagedColimaProfile,
    refreshManagedColimaManifest,
    startPreparedColimaProfileWith,
    withColimaOwnershipEntry,
    writeColimaStage,
 )
import qualified HostBootstrap.Ensure.Colima.Observation as ColimaObservation
import HostBootstrap.Ensure.Colima.Settlement.Internal (ColimaWallSettlementObservation (..), withColimaWallSettlement)
import HostBootstrap.Reconcile.ProviderStart.Internal (ProviderStartBackendResult (..), ProviderStartProjectionAuthority (..))
import HostBootstrap.Ensure.Colima.Report (
    ColimaReportFault (..),
    colimaDockerRunResult,
    ColimaInstallPolicy (..),
    ColimaResolutionChoice (..),
    colimaResolutionChoice,
    colimaCleanupCompletion,
    LimaDisk (..),
    classifyColimaListing,
    classifyDockerContextInspect,
    classifyDockerContextListing,
    classifyLimaDiskListing,
    classifyMachineIdentity,
    dockerContextFingerprint,
 )
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (HostTool (Colima, Docker, Lima))
import HostBootstrap.Lifecycle.Prepared (PreparedGate, preparedGatePlan, preparedGateOperation, preparedGateSession, preparedGateFence, preparedGateAttempt, preparedGateJournalVersion)
import HostBootstrap.Lift (localContext)
import HostBootstrap.Ownership.Object (ObjectKind (OwnedDirectory, ReportedObject), bindOriginRecord, originRecord, renderOriginRecord, parseOriginRecord, originRecordBinding, originRecordOrigin, Origin (..), mkOwnerClaim, parseObjectIdentityHex, ObjectIdentity, OwnershipFault (OwnershipConflict, OwnershipMalformed, OwnershipOccupied, OwnershipProbeFailed, OwnershipUnsupported))
import HostBootstrap.Ownership.Posix (posixOwnershipSupported, posixOwnershipRow, posixObserveOwnershipManifest)
import HostBootstrap.Ownership.Primitive (OwnershipClause (ClauseRecord, ClauseRelease), clauseRefusal, rowCapabilities, OwnershipPrimitive (rowObserveIdentity), withOwnershipRow)
import qualified HostBootstrap.Ownership.Row as ManifestRow
import HostBootstrap.Ownership.Row (ownershipRowForHost)
import qualified HostBootstrap.Ownership.Manifest as Manifest
import HostBootstrap.Ownership.Manifest (
    mkOwnershipManifest,
    mutableManifestEntry,
    ownershipManifestDigest,
    renderOwnershipManifest,
 )
import HostBootstrap.ProjectPlan (
    ClusterResource,
    PlannedResource,
    PlannedResourceKind (ClusterResourceKind, ProviderResourceKind),
    ProjectPlan,
    ProviderResource,
    forward,
    plannedResourceKey,
    plannedResourceFrame,
    projectPlanProjectName,
    projectPlanProfileName,
    stablePlanSnapshotRoot,
    plannedStepOperationKey,
    renderSnapshot,
    stablePlanSnapshotDigest,
    topology,
    withPlannedResourceOfKind,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    compareAndSwapProtectedRecord,
    compareAndDeleteProtectedRecord,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    recordKeyText,
    recordVersionWord,
    sessionStoreRoot,
    readProtectedRecord,
    listProtectedRecords,
 )
import qualified HostBootstrap.Reconcile as Reconcile
import HostBootstrap.Reconcile (ReconcileError (Conflict, Failure), ConflictDetail (ConflictDetail), FailureDetail (FailureDetail), RecoveryDisposition (DoNotRetry, ReprobeBeforeRetry), withObservedProjectResource)
import HostBootstrap.Step (
    StepFrame (StepFrame),
    StepObservation (StepChanged),
    StepPlan,
    deployKindStep,
    deployVMStep,
    descendsVia,
    mkStepPlan,
 )
import HostBootstrap.Substrate (Arch (Amd64), Substrate (..), SubstrateName (LinuxCpu))
import PrepareFixture (withSuccessorGate, gateForValues)
import SourceGuard (repoRelativePath)
import qualified SourceGuard
import System.Directory (
    Permissions (executable),
    createDirectoryIfMissing,
    createDirectory,
    removeDirectory,
    withCurrentDirectory,
    createFileLink,
    doesDirectoryExist,
    doesPathExist,
    listDirectory,
    doesFileExist,
    findExecutable,
    getCurrentDirectory,
    getPermissions,
    removeFile,
    renameFile,
    removePathForcibly,
    renameDirectory,
    renameDirectory,
    setPermissions,
 )
import System.Environment (getExecutablePath, lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (searchPathSeparator, takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Info (arch, os)
import System.IO.Unsafe (unsafePerformIO)
#if !defined(mingw32_HOST_OS)
import System.Posix.Files (setFileMode)
import qualified System.Posix.Resource as PosixResource
#endif
import System.Process (createProcess, proc, readProcessWithExitCode, terminateProcess, waitForProcess)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

gib :: Integer
gib = 1024 ^ (3 :: Integer)

profileName :: String
profileName = "h-012345"

ownerToken :: String
ownerToken =
    "v2-68-70-72-66-63-64-1-65-74-75-76"

acquireInvocation :: String
acquireInvocation = replicate 64 'a'

cleanupInvocation :: String
cleanupInvocation = replicate 64 'b'

exactResources :: Fixture.Resources
exactResources = Fixture.Resources 8 "16GiB" "100GiB"

selectResources :: Fixture.Resources -> Fixture.ProjectConfig scope -> Fixture.ProjectConfig scope
selectResources resources value = value{Fixture.resources = resources}

canonicalStartArgs :: [String]
canonicalStartArgs =
    [ "start"
    , "--profile"
    , profileName
    , "--runtime"
    , "docker"
    , "--activate=false"
    , "--template=false"
    , "--ssh-config=false"
    , "--mount"
    , "none"
    , "--kubernetes=false"
    , "--network-address=false"
    , "--mount-inotify=false"
    , "--cpus"
    , "8"
    , "--memory"
    , "16"
    , "--root-disk"
    , "20"
    , "--disk"
    , "80"
    ]

canonicalTypedStartArgs :: ColimaStartArguments
canonicalTypedStartArgs = either error id (mkColimaStartArguments contextFixtureProfile canonicalStartArgs)

data CleanupScenario = NormalCleanup | ParentReplaced | ProfileVersionChanged | SharedParents
    | ContextAbsent | ContextReplaced | ContextStillListed | ContextBindingMissing | ContextDirectoryReplaced
    | NamespaceEntryAdded | ContextMetadataRemoved | PostDeleteInterrupted | PostContextReleased | BlockedNamespace | PostCleanupBeforeCommit | BoundAcquisitionRetry
    | ManagedManifestDrift | InterruptedManifestRefresh | FrozenManifestDrift
    deriving (Eq, Show)

namespaceAdmissionTests :: TestTree
namespaceAdmissionTests = testGroup "namespace admission"
    [ testCase "the socket ceiling admits 103 bytes and refuses 104" $ do
        let key = replicate 32 'a'
        -- The fixed namespace/socket suffix is 83 ASCII bytes.
        colimaSocketNamespaceFits ('/' : replicate 19 'x') key profileName @?= True
        colimaSocketNamespaceFits ('/' : replicate 20 'x') key profileName @?= False
    , testCase "the socket ceiling counts UTF-8 bytes rather than characters" $ do
        let key = replicate 32 'a'
        colimaSocketNamespaceFits ("/" <> replicate 17 'x' <> "é") key profileName @?= True
        colimaSocketNamespaceFits ("/" <> replicate 18 'x' <> "é") key profileName @?= False
    , conditionalCase ["ColimaSpec", "namespace admission"] posixOwnershipSupported
        "a pre-planted home link refuses acquisition without touching its target"
        (withSystemTempDirectory "hb-colima-home-link" $ \root -> do
            let foreignHome = root </> "foreign-home"
                home = root </> "isolated-home"
                context = root </> "docker-config"
            createDirectoryIfMissing True foreignHome
            ByteString.writeFile (foreignHome </> "keep") "foreign bytes"
            createFileLink foreignHome home
            prepared <- prepareColimaNamespaces root profileName ownerToken (replicate 64 'c') acquireInvocation home context
            case prepared of
                Left (ColimaNativeOwnershipRefused (OwnershipOccupied _)) -> pure ()
                other -> assertFailure ("expected the actual home-link ownership refusal, got " <> show other)
            listDirectory foreignHome >>= (@?= ["keep"])
            ByteString.readFile (foreignHome </> "keep") >>= (@?= "foreign bytes")
            doesPathExist context >>= (@?= False))
        (pure ())
    ]

colimaNamePolicyTests :: TestTree
colimaNamePolicyTests = testGroup "private name policy"
    [ testCase "the same full inputs retain the known namespace and local profile" $ do
        namesFor "demo" "production" "host-root" "frame" "/plan"
            @?= Right ("h-ee9512", "70a0e377c7a43863fd0e75dfb0558180")
        firstNames <- exactNames "production"
        exactNames "production" >>= (@?= firstNames)
        let (localProfile, namespaceKey) = firstNames
        take 2 localProfile @?= "h-"
        length localProfile @?= 8
        assertBool "local profile has six lowercase hex digits" (all lowerHex (drop 2 localProfile))
        length namespaceKey @?= 32
        assertBool "home key has 128 lowercase hex bits" (all lowerHex namespaceKey)
    , testCase "Production and Harness use distinct namespace keys and actual home projections" $ do
        productionNames <- exactNames "production"
        harnessNames <- exactNames "harness:run-one"
        distinctHomes productionNames harnessNames
    , testCase "two admitted Harness run keys have distinct homes" $ do
        firstNames <- exactNames "harness:run-one"
        secondNames <- exactNames "harness:run-two"
        distinctHomes firstNames secondNames
    , testCase "project resource frame and canonical root each affect the namespace" $ do
        original <- exactNames "production"
        for_ [ namesFor "other" "production" "host-root" "frame" "/plan"
             , namesFor "demo" "production" "other-root" "frame" "/plan"
             , namesFor "demo" "production" "host-root" "other-frame" "/plan"
             , namesFor "demo" "production" "host-root" "frame" "/other-plan"
             ] $ \derived -> do
            alternative <- OwnershipFixture.expectRight derived
            distinctHomes original alternative
        otherProject <- OwnershipFixture.expectRight (namesFor "other" "production" "host-root" "frame" "/plan")
        assertBool "a second fixture project has a different local profile" (fst original /= fst otherProject)
    , testCase "default returns the production Conflict detail" $
        namesFor "default" "production" "host-root" "frame" "/plan"
            @?= Left (Conflict (ConflictDetail "colima profile identity" "a project-specific profile" "default" "the shared default Colima profile is never project authority"))
    , testCase "an invalid project returns its named Failure" $
        namesFor "INVALID" "production" "host-root" "frame" "/plan"
            @?= Left (Failure (FailureDetail "derive Colima profile" "invalid project profile name: \"INVALID\"" DoNotRetry))
    , testCase "an unknown lifecycle profile returns its named Failure" $
        namesFor "demo" "preview" "host-root" "frame" "/plan"
            @?= Left (Failure (FailureDetail "derive Colima profile" "the admitted plan carries an unknown lifecycle profile" DoNotRetry))
    , testCase "invalid Harness run keys refuse before any backend exists" $
        for_ ["harness:", "harness:bad/run", "harness:bad run", "harness:" <> Text.replicate 49 "a"] $ \profile ->
            namesFor "demo" profile "host-root" "frame" "/plan"
                @?= Left (Failure (FailureDetail "derive Colima profile" "the admitted Harness profile carries an invalid run key" DoNotRetry))
    , testCase "the public predicate shares production project admission" $
        for_ ["demo", "other", "a-1", "default", "", "INVALID", "bad/name"] $ \project ->
            validColimaProjectProfileName project
                @?= either (const False) (const True) (namesFor project "production" "host-root" "frame" "/plan")
    , testCase "direct Colima sources do not discover Python" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            let backend = packageRoot </> "internal" </> "colima-backend"
                adapter = packageRoot </> "src" </> "HostBootstrap" </> "Ensure" </> "Colima.hs"
            sources <- SourceGuard.readHaskellSources backend
            public <- strictReadFile adapter
            assertBool "the backend source inventory is nonempty" (not (null sources))
            for_ ((adapter, public) : sources) $ \(path, source) ->
                assertBool (path <> " names python3") (not ("python3" `isInfixOf` source))
    , testCase "the actual prepared and namespace consumers use the private policy" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            description <- strictReadFile (packageRoot </> "hostbootstrap-core.cabal")
            public <- strictReadFile (packageRoot </> "src" </> "HostBootstrap" </> "Ensure" </> "Colima.hs")
            policy <- strictReadFile (packageRoot </> "internal" </> "colima-backend" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Backend" </> "Names.hs")
            let policyModule = "HostBootstrap.Ensure.Colima.Backend.Names"
            exposed <- OwnershipFixture.expectRight (SourceGuard.effectiveMainExposedModules description)
            assertBool "naming policy remains private" (notElem policyModule exposed)
            private <- maybe (assertFailure "the private Colima backend library is absent") pure
                (SourceGuard.namedStanza "library colima-backend-internal" description)
            assertBool "the existing private backend owns naming policy" (elem policyModule (SourceGuard.fieldModules "exposed-modules" private))
            assertBool "policy shares the leaf refusal vocabulary"
                (elem "hostbootstrap-core:reconcile-error-internal" (SourceGuard.fieldValues "build-depends" private))
            expected <- maybe (assertFailure "the private naming export pin is absent") pure
                (lookup policyModule pinnedPrivateExportLists)
            SourceGuard.moduleExportTokens policyModule policy @?= Just (SourceGuard.haskellTokens expected)
            publicExports <- maybe (assertFailure "the public Colima header is absent") pure
                (SourceGuard.moduleExportTokens "HostBootstrap.Ensure.Colima" public)
            publicDefinitions <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionNames public)
            for_ ["deriveColimaNames", "colimaHomePath"] $ \name ->
                assertBool ("the public surface does not expose " <> name) (notElem name publicExports)
            for_ ["deriveColimaNames", "validProfileName", "validateProfileName", "validColimaProjectProfileName", "colimaHomePath"] $ \name ->
                assertBool ("the public module has no duplicate " <> name) (notElem name publicDefinitions)
            predicate <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "validColimaProjectProfileName" policy)
            for_ ["isRight", "validateProfileName"] $ \name ->
                assertBool ("the actual predicate delegates through " <> name) (elem name predicate)
            prepared <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "prepareColimaWallCall" public)
            for_ ["deriveColimaNames", "projectPlanProjectName", "projectPlanProfileName", "plannedResourceKey", "plannedResourceFrame", "stablePlanSnapshotRoot"] $ \name ->
                assertBool ("the actual prepared consumer projects " <> name) (elem name prepared)
            for_ ["ownershipNamespaceFor", "colimaSocketNamespaceFits"] $ \consumer -> do
                tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens consumer public)
                assertBool (consumer <> " consumes the actual home projection") (elem "colimaHomePath" tokens)
    ]
  where
    namesFor = ColimaNames.deriveColimaNames
    exactNames profile = OwnershipFixture.expectRight (namesFor "demo" profile "host-root" "frame" "/plan")
    lowerHex character = elem character ("0123456789abcdef" :: String)
    distinctHomes firstNames secondNames = do
        assertBool "namespace keys differ" (snd firstNames /= snd secondNames)
        assertBool "actual projected homes differ"
            (ColimaNames.colimaHomePath "effective-home" (snd firstNames) /= ColimaNames.colimaHomePath "effective-home" (snd secondNames))

contextParentTests :: TestTree
contextParentTests = testGroup "context parents"
    [ testCase "the prepared driver never creates context parents outside ownership entry" $ do
        current <- getCurrentDirectory
        root <- findRepoRoot current >>= maybe (assertFailure "could not find repository root") pure
        source <- strictReadFile (root </> "core" </> "hostbootstrap-core" </> "src" </> "HostBootstrap" </> "Ensure" </> "Colima.hs")
        tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "runPreparedColimaWallCall" source)
        assertBool "the driver delegates to the owned namespace transaction" (elem "acquireManagedColimaProfileWith" tokens)
        SourceGuard.countHaskellIdentifier "createDirectoryIfMissing" source @?= 0
        SourceGuard.countHaskellIdentifier "createDirectoryIfMissing" "createDirectoryIfMissing True parent" @?= 1
    , parentCase "missing context parents are created through owned records and re-enter exactly" $ \root -> do
        let home = root </> "owned-home"
            firstParent = root </> ".hostbootstrap"
            parent = firstParent </> "colima"
            context = parent </> "docker-config"
            prepare = prepareColimaNamespaces root profileName ownerToken (replicate 64 'c') acquireInvocation home context
        prepare >>= (@?= Right ())
        identities <- traverse observedNamespaceIdentity [firstParent, parent, context]
        recordNames <- parentRecordNames root
        length recordNames @?= 2
        before <- posixObserveOwnershipManifest False (root </> "records") >>= OwnershipFixture.expectRight
        prepare >>= (@?= Right ())
        traverse observedNamespaceIdentity [firstParent, parent, context] >>= (@?= identities)
        posixObserveOwnershipManifest False (root </> "records") >>= (@?= Right before)
    , parentCase "an existing unrecorded context parent refuses adoption" $ \root -> do
        let parent = root </> ".hostbootstrap" </> "colima"
            context = parent </> "docker-config"
        createDirectoryIfMissing True parent
        ByteString.writeFile (parent </> "keep") "foreign parent bytes"
        before <- posixObserveOwnershipManifest False parent >>= OwnershipFixture.expectRight
        prepared <- prepareColimaNamespaces root profileName ownerToken (replicate 64 'c') acquireInvocation (root </> "home") context
        expectParentOccupied prepared
        posixObserveOwnershipManifest False parent >>= (@?= Right before)
        doesPathExist context >>= (@?= False)
    , parentCase "a context parent link cannot create a child behind it" $ \root -> do
        let outside = root </> "foreign"
            linked = root </> ".hostbootstrap"
            context = linked </> "colima" </> "docker-config"
        createDirectory outside
        ByteString.writeFile (outside </> "keep") "outside bytes"
        createFileLink outside linked
        before <- posixObserveOwnershipManifest False outside >>= OwnershipFixture.expectRight
        prepared <- prepareColimaNamespaces root profileName ownerToken (replicate 64 'c') acquireInvocation (root </> "home") context
        expectParentOccupied prepared
        posixObserveOwnershipManifest False outside >>= (@?= Right before)
        doesPathExist (outside </> "colima") >>= (@?= False)
    , parentCase "a missing owned context parent refuses without being recreated" $ \root -> do
        let home = root </> "home"
            firstParent = root </> ".hostbootstrap"
            parent = firstParent </> "colima"
            context = parent </> "docker-config"
            parked = root </> "parked"
            prepare = prepareColimaNamespaces root profileName ownerToken (replicate 64 'c') acquireInvocation home context
        prepare >>= (@?= Right ())
        identity <- observedNamespaceIdentity firstParent
        bracket_ (renameDirectory firstParent parked) (renameDirectory parked firstParent) $ do
            prepared <- prepare
            expectParentConflict prepared
            doesPathExist firstParent >>= (@?= False)
            observedNamespaceIdentity parked >>= (@?= identity)
    , parentCase "a replaced parent refuses even when the owned child identities survive" $ \root -> do
        let home = root </> "home"
            firstParent = root </> ".hostbootstrap"
            parent = firstParent </> "colima"
            context = parent </> "docker-config"
            parked = root </> "parked"
            prepare = prepareColimaNamespaces root profileName ownerToken (replicate 64 'c') acquireInvocation home context
            replaceParent = do
                renameDirectory firstParent parked
                createDirectory firstParent
                renameDirectory (parked </> "colima") parent
            restoreParent = do
                renameDirectory parent (parked </> "colima")
                removeDirectory firstParent
                renameDirectory parked firstParent
        prepare >>= (@?= Right ())
        oldParent <- observedNamespaceIdentity firstParent
        childIdentities <- traverse observedNamespaceIdentity [parent, context]
        bracket_ replaceParent restoreParent $ do
            replacement <- observedNamespaceIdentity firstParent
            assertBool "the replacement parent is a different actual inode" (replacement /= oldParent)
            traverse observedNamespaceIdentity [parent, context] >>= (@?= childIdentities)
            prepare >>= expectParentConflict
            traverse observedNamespaceIdentity [parent, context] >>= (@?= childIdentities)
    , parentCase "profiles share the same bound context parents" $ \root -> do
        let firstParent = root </> ".hostbootstrap"
            parent = firstParent </> "colima"
            prepare profile home context = prepareColimaNamespaces root profile ownerToken (replicate 64 'c') acquireInvocation home context
        prepare profileName (root </> "home-one") (parent </> "context-one") >>= (@?= Right ())
        identities <- traverse observedNamespaceIdentity [firstParent, parent]
        names <- parentRecordNames root
        length names @?= 2
        recordBytes <- traverse (ByteString.readFile . ((root </> "records") </>)) names
        prepare "h-123456" (root </> "home-two") (parent </> "context-two") >>= (@?= Right ())
        traverse observedNamespaceIdentity [firstParent, parent] >>= (@?= identities)
        parentRecordNames root >>= (@?= names)
        traverse (ByteString.readFile . ((root </> "records") </>)) names >>= (@?= recordBytes)
    , parentCase "a context outside the protected plan root refuses before creation" $ \root ->
        withSystemTempDirectory "hb-colima-outside-context" $ \outside -> do
            ByteString.writeFile (outside </> "keep") "foreign root"
            before <- posixObserveOwnershipManifest False outside >>= OwnershipFixture.expectRight
            prepared <- prepareColimaNamespaces root profileName ownerToken (replicate 64 'c') acquireInvocation (root </> "home") (outside </> "docker-config")
            expectParentInvalid prepared
            posixObserveOwnershipManifest False outside >>= (@?= Right before)
            doesPathExist (root </> "home") >>= (@?= False)
    ]
  where
    parentCase name body =
        conditionalCase ["ColimaSpec", "context parents"] posixOwnershipSupported name
            (withSystemTempDirectory "hb-colima-context-parents" body)
            (pure ())

parentRecordNames :: FilePath -> IO [FilePath]
parentRecordNames root =
    sort . filter (isPrefixOf "colima-parent-") <$> listDirectory (root </> "records")

observedNamespaceIdentity :: FilePath -> IO ObjectIdentity
observedNamespaceIdentity path = do
    observed <- withOwnershipRow posixOwnershipRow (\row -> rowObserveIdentity row path)
    case observed of
        Right (Just identity) -> pure identity
        other -> assertFailure ("expected an actual namespace identity, got " <> show other)

expectParentOccupied :: Either ColimaNativeOwnershipFault () -> IO ()
expectParentOccupied prepared = case prepared of
    Left (ColimaNativeOwnershipRefused (OwnershipOccupied _)) -> pure ()
    other -> assertFailure ("expected an occupied parent refusal, got " <> show other)

expectParentConflict :: Either ColimaNativeOwnershipFault () -> IO ()
expectParentConflict prepared = case prepared of
    Left (ColimaNativeOwnershipRefused (OwnershipConflict _)) -> pure ()
    other -> assertFailure ("expected a changed parent identity refusal, got " <> show other)

expectParentInvalid :: Either ColimaNativeOwnershipFault () -> IO ()
expectParentInvalid prepared = case prepared of
    Left (ColimaNativeOwnershipRefused (OwnershipMalformed _)) -> pure ()
    other -> assertFailure ("expected an invalid parent path refusal, got " <> show other)


contextFixtureProfile :: ColimaProfile
contextFixtureProfile = either error id (mkColimaProfile profileName)

contextAcquisitionAdmissionTests :: TestTree
contextAcquisitionAdmissionTests = testGroup "context acquisition admission" $
    [ testCase "an empty context listing admits acquisition" $
        admitColimaContextAcquisition contextFixtureProfile [] @?= Right ()
    , testCase "unrelated names and partial matches do not collide" $
        for_ [["default"], ["colima-h-123456"], ["colima-" ++ profileName ++ "-extra"], ["prefix-colima-" ++ profileName]] $ \names ->
            admitColimaContextAcquisition contextFixtureProfile names @?= Right ()
    , testCase "the exact context name refuses at any listing position" $
        for_ [[target], ["default", target], [target, "default"]] $ \names ->
            admitColimaContextAcquisition contextFixtureProfile names
                @?= Left (ColimaMutationProfileConflict ("the Docker context " ++ target ++ " is already present before acquisition"))
    , testCase "an absent stage requires the context probe" $
        colimaContextAcquisitionNeedsProbe Nothing @?= True
    ]
    ++ [ testCase ("the probe boundary at " ++ show stage) $
            colimaContextAcquisitionNeedsProbe (Just stage) @?= expected
       | (stage, expected) <-
            [ (ColimaReserved, True), (ColimaHomeStaged, True), (ColimaHomeReady, True)
            , (ColimaContextStaged, False), (ColimaPrepared, False), (ColimaManaged, False)
            , (ColimaReleasing, False), (ColimaContextReleased, False), (ColimaReleased, False)
            ]
       ]
    ++ [ testCase "the acquisition consumer checks context admission before namespace preparation" $ do
            current <- getCurrentDirectory
            root <- findRepoRoot current >>= maybe (assertFailure "could not find repository root") pure
            source <- strictReadFile (root </> "core" </> "hostbootstrap-core" </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
            tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "acquireManagedColimaProfileWith" source)
            let beforePreparation = takeWhile (/= "prepareColimaNamespacesInside") tokens
            assertBool "the actual consumer reaches namespace preparation" (elem "prepareColimaNamespacesInside" tokens)
            for_ ["colimaContextAcquisitionNeedsProbe", "listDockerContextsCommand",
                  "classifyDockerContextListing", "admitColimaContextAcquisition"] $ \name ->
                assertBool ("admission precedes preparation through " <> name) (elem name beforePreparation)
       ]
  where
    target = "colima-" ++ profileName

manifestRefreshTests :: TestTree
manifestRefreshTests = testGroup "managed manifest refresh" $
    map stageCase [minBound .. maxBound] <>
    [ testCase "refresh preserves identity wall lineage and the Managed stage" $ do
        record <- forStage ColimaManaged
        prepared <- forStage ColimaPrepared
        evidence <- OwnershipFixture.expectRight $
            mkColimaManagedEvidence (replicate 32 'd') 42 (replicate 64 'e') newManifest newChain 8 (16 * gib) (80 * gib) (20 * gib)
        expected <- OwnershipFixture.expectRight (settleColimaStageRecord prepared evidence)
        refreshColimaManifestRecord record newManifest newChain @?= Right expected
    , testCase "an unchanged proof refresh is the identical record" $ do
        record <- forStage ColimaManaged
        refreshColimaManifestRecord record (replicate 64 'f') (replicate 64 'a') @?= Right record
    , testCase "malformed refreshed digests refuse before a successor exists" $ do
        record <- forStage ColimaManaged
        refreshColimaManifestRecord record "bad" newChain @?= Left "stage-manifest"
        refreshColimaManifestRecord record newManifest "bad" @?= Left "stage-directory-chain"
    , testCase "the consumer refreshes before freeze and publishes manifest before stage evidence" $ do
        current <- getCurrentDirectory
        root <- findRepoRoot current >>= maybe (assertFailure "could not find repository root") pure
        source <- strictReadFile (root </> "core" </> "hostbootstrap-core" </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
        SourceGuard.countHaskellTokenSequence
            (SourceGuard.haskellTokens "ColimaManaged -> Right ColimaCleanupFromManaged")
            source @?= 1
        SourceGuard.countHaskellTokenSequence
            (SourceGuard.haskellTokens "Right ColimaCleanupFromManaged -> withValidatedColimaContextParents session context $ do refreshed <- refreshManagedColimaManifest")
            source @?= 1
        tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "refreshManagedColimaManifest" source)
        assertBool "manifest publication precedes stage evidence"
            (elem "compareAndSwapProtectedRecord" (takeWhile (/= "writeColimaStage") tokens))
        for_ ["ClauseRelease", "ClauseRecord", "readColimaStage", "readRetainedColimaManifest",
              "readRetainedColimaDirectoryIdentity", "observeColimaNamespaceManifest",
              "refreshColimaManifestRecord", "ExpectVersion", "protectedRecordVersion"] $ \name ->
            assertBool ("the owned refresh retains " <> name) (elem name tokens)
        for_ ["ensureColimaDirectory", "acquireColimaDirectory", "recordOwnedOrigin"] $ \name ->
            assertBool ("refresh cannot acquire through " <> name) (notElem name tokens)
        standing <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "revalidateColimaManifest" source)
        for_ ["readColimaStage", "managedManifestDigest", "managedDirectoryChainDigest"] $ \name ->
            assertBool ("ordinary readers require coherent " <> name) (elem name standing)
    , testCase "the selected host declares refresh capabilities or returns its actual refusal" $
        withOwnershipRow ownershipRowForHost $ \primitives ->
            case clauseRefusal (rowCapabilities primitives) ClauseRelease of
                Nothing -> clauseRefusal (rowCapabilities primitives) ClauseRecord @?= Nothing
                Just refusal -> withSystemTempDirectory "hb-refresh-refusal" $ \root -> do
                    record <- forStage ColimaPrepared
                    entered <- withColimaOwnershipEntry root profileName $ \session keys -> do
                        version <- writeColimaStage session keys ExpectAbsent record >>= OwnershipFixture.expectRight
                        refreshManagedColimaManifest session keys version record (root </> "home") (root </> "context")
                            >>= (@?= Left refusal)
                        readColimaStage session keys >>= (@?= Right (Just (version, record)))
                        doesPathExist (root </> "home") >>= (@?= False)
                        doesPathExist (root </> "context") >>= (@?= False)
                        pure (Right ())
                    entered @?= Right ()
    ]
  where
    newManifest = replicate 64 'b'
    newChain = replicate 64 'd'
    stageCase stage = testCase ("refresh policy at " <> renderColimaStage stage) $ do
        record <- forStage stage
        case stage of
            ColimaManaged -> do
                successor <- OwnershipFixture.expectRight (refreshColimaManifestRecord record newManifest newChain)
                colimaStageRecordStage successor @?= ColimaManaged
                fmap managedManifestDigest (colimaStageRecordEvidence successor) @?= Just newManifest
                fmap managedDirectoryChainDigest (colimaStageRecordEvidence successor) @?= Just newChain
            _ -> refreshColimaManifestRecord record newManifest newChain @?= Left "stage-manifest-refresh"
    forStage stage
        | stage <= ColimaPrepared = OwnershipFixture.expectRight (mkColimaStageRecord stage ownerToken (replicate 64 'c') acquireInvocation)
        | otherwise = do
            prepared <- OwnershipFixture.expectRight (mkColimaStageRecord ColimaPrepared ownerToken (replicate 64 'c') acquireInvocation)
            evidence <- OwnershipFixture.expectRight $
                mkColimaManagedEvidence (replicate 32 'd') 42 (replicate 64 'e') (replicate 64 'f') (replicate 64 'a') 8 (16 * gib) (80 * gib) (20 * gib)
            managed <- OwnershipFixture.expectRight (settleColimaStageRecord prepared evidence)
            let releasing = beginColimaReleaseRecord managed cleanupInvocation
                contextReleased = releasing >>= (\record -> advanceSettledColimaStageRecord record ColimaContextReleased)
            OwnershipFixture.expectRight $ case stage of
                ColimaManaged -> Right managed
                ColimaReleasing -> releasing
                ColimaContextReleased -> contextReleased
                ColimaReleased -> contextReleased >>= (\record -> advanceSettledColimaStageRecord record ColimaReleased)
                _ -> Left "the earlier pure stage takes the constructor branch"

retainedRemainderTests :: TestTree
retainedRemainderTests = testGroup "retained namespace remainders"
    [ testCase "cleanup carries pre-delete authority into the private release producer" $ do
        current <- getCurrentDirectory
        root <- findRepoRoot current >>= maybe (assertFailure "could not find repository root") pure
        source <- strictReadFile (root </> "core" </> "hostbootstrap-core" </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
        tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "cleanupManagedColimaProfileWith" source)
        namespace <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "releaseNamespaceRemainders" source)
        assertBool "cleanup delegates retained namespace release to its shared private walker" ("releaseNamespaceRemainders" `elem` tokens)
        assertBool "the manifest is read before external deletion"
            (elem "revalidateColimaManifest" (takeWhile (/= "deleteColimaProfileCommand") tokens))
        SourceGuard.countHaskellTokenSequence
            (SourceGuard.haskellTokens "Right retainedManifest -> releaseProfile session keys heldVersion heldRecord retainedManifest")
            source @?= 1
        SourceGuard.countHaskellTokenSequence
            (SourceGuard.haskellTokens "settleAbsence session keys releaseVersion releasingRecord retainedManifest")
            source @?= 2
        for_ ["projectOwnershipManifest", "admitOwnershipManifestRemainders", "retainedManifest",
              "releaseManifestRemainder", "Down"] $ \name ->
            assertBool ("the actual cleanup retains " <> name) (elem name (tokens <> namespace))
        SourceGuard.countHaskellTokenSequence
            (SourceGuard.haskellTokens "sortOn (Down . ByteString.count 47 . manifestEntryPath)")
            source @?= 1
        SourceGuard.countHaskellIdentifier "posixReleaseManifestEntry" source @?= 0
    ]

contextConditionalRemovalTests :: TestTree
contextConditionalRemovalTests = testGroup "context conditional removal"
    [ testCase "mismatched start arguments refuse before entering ownership" $ do
        let noCommand _ = assertFailure "a mismatched start must run no command"
        result <- startPreparedColimaProfileWith noCommand "unused" "h-ffffff" ownerToken
            (replicate 64 'c') acquireInvocation "unused" "unused" "unused" 8 (16 * gib) (80 * gib) canonicalTypedStartArgs
        result @?= Left (ColimaMutationEntryRefused "start arguments do not match the owned profile")
    , testCase "an unlisted context skips removal" $
        colimaContextRemovalNeeded contextFixtureProfile [] @?= False
    , testCase "unrelated and partial names do not require removal" $
        for_ [["default"], ["colima-h-123456"], [target ++ "-extra"]] $ \names ->
            colimaContextRemovalNeeded contextFixtureProfile names @?= False
    , testCase "the exact listed name requires fingerprint inspection" $
        for_ [[target], ["default", target], [target, "default"]] $ \names ->
            colimaContextRemovalNeeded contextFixtureProfile names @?= True
    , testCase "an exact retained fingerprint admits conditional removal" $
        admitColimaContextFingerprint retainedDigest retainedDigest @?= Right ()
    , testCase "a changed fingerprint refuses conditional removal" $
        admitColimaContextFingerprint retainedDigest (replicate 64 'b')
            @?= Left (ColimaMutationProfileConflict "the Docker context fingerprint differs from its retained release authority")
    , testCase "an empty absence readback permits stage advancement" $
        admitColimaContextRemovalAbsence contextFixtureProfile [] @?= Right ()
    , testCase "unrelated readback names permit stage advancement" $
        admitColimaContextRemovalAbsence contextFixtureProfile ["default", "colima-h-123456"] @?= Right ()
    , testCase "a still-listed owned name refuses stage advancement" $
        for_ [[target], ["default", target]] $ \names ->
            admitColimaContextRemovalAbsence contextFixtureProfile names
                @?= Left (ColimaMutationProfileConflict ("the Docker context " ++ target ++ " remains listed after removal"))
    , testCase "the removal consumer retains stored identity and absence boundaries" $ do
        current <- getCurrentDirectory
        root <- findRepoRoot current >>= maybe (assertFailure "could not find repository root") pure
        source <- strictReadFile (root </> "core" </> "hostbootstrap-core" </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
        tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "cleanupManagedColimaProfileWith" source)
        let beforeRemoval = takeWhile (/= "removeDockerContextCommand") tokens
            afterRemoval = dropWhile (/= "removeDockerContextCommand") tokens
        for_ ["colimaContextRemovalNeeded", "inspectDockerContextCommand", "readRetainedColimaContextIdentity",
              "dockerContextFingerprint", "managedContextDigest", "admitColimaContextFingerprint"] $ \name ->
            assertBool ("the conditional removal retains " <> name) (elem name beforeRemoval)
        assertBool "removal has an authoritative absence readback" (elem "admitColimaContextRemovalAbsence" afterRemoval)
        contextTokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "readRetainedColimaContextIdentity" source)
        for_ ["revalidateColimaContextParents", "readRetainedColimaDirectoryIdentity"] $ \name ->
            assertBool ("context identity delegates through " <> name) (elem name contextTokens)
        identityTokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "readRetainedColimaDirectoryIdentity" source)
        for_ ["readStoredRecordUnder", "reenterStoredOwnedObject", "reobserveOwnedIdentity", "storedRecordVersion"] $ \name ->
            assertBool ("context identity retains " <> name) (elem name identityTokens)
        assertBool "a missing context binding is not acquired" (notElem "ensureColimaDirectory" (contextTokens <> identityTokens))
    ]
  where
    target = "colima-" ++ profileName
    retainedDigest = replicate 64 'a'

tests :: TestTree
tests =
    testGroup
        "ColimaSpec"
        [ exactCleanupCompletionCases
        , nativeResolverInstallPolicyCases
        , nativeReleasedNamespaceCases
        , releasedNamespaceProtocolCases
        , nativeContextNamespaceCases
        , contextNamespaceRetryCases
        , nativeDockerPreflightCases
        , contextReleaseDecisionCases
        , nativeDirectoryReleaseCases
        , directoryReleasePolicyCases
        , pureDockerRouteCases
        , namespaceAdmissionTests
        , colimaNamePolicyTests
        , contextParentTests
        , contextAcquisitionAdmissionTests
        , contextConditionalRemovalTests
        , retainedRemainderTests
        , manifestRefreshTests
        , testCase "the owning driver is private and exposes no HostConfig wrapper" $
            SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                description <- strictReadFile (packageRoot </> "hostbootstrap-core.cabal")
                let driverModule = "HostBootstrap.Ensure.Colima.Ownership"
                    privateRoot = packageRoot </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima"
                driver <- strictReadFile (privateRoot </> "Ownership.hs")
                exposed <- OwnershipFixture.expectRight (SourceGuard.effectiveMainExposedModules description)
                assertBool "the owning driver is absent from the public package" (notElem driverModule exposed)
                for_ ["HostBootstrap.Ensure.Colima.Command", "HostBootstrap.Ensure.Colima.Report"] $ \name ->
                    assertBool ("the descriptive API remains public: " <> name) (elem name exposed)
                private <- maybe (assertFailure "the private owning-driver unit is absent") pure
                    (SourceGuard.namedStanza "library colima-ownership-internal" description)
                SourceGuard.fieldValues "visibility" private @?= ["private"]
                SourceGuard.fieldValues "hs-source-dirs" private @?= ["internal/colima-ownership"]
                SourceGuard.fieldModules "exposed-modules" private
                    @?= [driverModule, "HostBootstrap.Ensure.Colima.Command", "HostBootstrap.Ensure.Colima.Report", "HostBootstrap.Ensure.Colima.Observation", "HostBootstrap.Ensure.Colima.Settlement.Internal"]
                assertBool "the private driver uses the shared command vocabulary"
                    (elem "hostbootstrap-core:effect-command-internal" (SourceGuard.fieldValues "build-depends" private))
                expected <- maybe (assertFailure "the private driver export pin is absent") pure
                    (lookup driverModule pinnedPrivateExportLists)
                SourceGuard.moduleExportTokens driverModule driver @?= Just (SourceGuard.haskellTokens expected)
                for_ ["HostConfig", "interpretHostCommand", "ColimaNativeObservationFault",
                      "observeColimaProfiles", "startPreparedColimaProfile", "observeColimaArtifacts",
                      "acquireManagedColimaProfile", "cleanupManagedColimaProfile", "runManagedColimaDocker"] $ \name ->
                    SourceGuard.countHaskellIdentifier name driver @?= 0
                for_ ["Ownership", "Command", "Report"] $ \name -> do
                    doesFileExist (packageRoot </> "src" </> "HostBootstrap" </> "Ensure" </> "Colima" </> (name ++ ".hs")) >>= (@?= False)
                    doesFileExist (privateRoot </> (name ++ ".hs")) >>= (@?= True)
                public <- maybe (assertFailure "the main library is absent") pure
                    (SourceGuard.mainLibraryStanza description)
                assertBool "the public adapter depends on the private driver"
                    (elem "hostbootstrap-core:colima-ownership-internal" (SourceGuard.fieldValues "build-depends" public))
                testComponent <- maybe (assertFailure "the core test component is absent") pure
                    (SourceGuard.namedStanza "test-suite hostbootstrap-core-test" description)
                assertBool "native ownership checks use the private driver"
                    (elem "hostbootstrap-core:colima-ownership-internal" (SourceGuard.fieldValues "build-depends" testComponent))
        , conditionalProfileReleaseCases
        , cleanupResumeAdmissionCases
        , cleanupRetryIdentityCases
        , cleanupLineageCases
        , staticOwnedSettlementCases
        , staticUnownedSettlementCases
        , testCase "the owned join retains the generic managed handle and matching receipt" $
            SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                adapter <- strictReadFile (packageRoot </> "src" </> "HostBootstrap" </> "Ensure" </> "Colima.hs")
                reconcile <- strictReadFile (packageRoot </> "src" </> "HostBootstrap" </> "Reconcile.hs")
                SourceGuard.countHaskellTokenSequence
                    (SourceGuard.haskellTokens "Right (consume authority handle receipt wallChange providerChange)") adapter @?= 1
                SourceGuard.countHaskellTokenSequence
                    (SourceGuard.haskellTokens "LiveColimaWall (profileName, dockerContextForProfile commandProfile) owned (providerWallCallFence prepared) authority runningHandle receipt wallChange providerChange") adapter @?= 1
                completed <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "completePreparedProviderStart" reconcile)
                for_ ["resourceHandleGeneration", "handle", "ProviderStartBackendCreated", "ProviderStartBackendRepaired", "BackendCreated", "BackendRepaired", "generation"] $ \name ->
                    assertBool ("the generic start retains " <> name) (name `elem` completed)
        , nativeFixtureResolutionCases
        , testCase "the native fixture retains one actual result before descriptive projection" $
            SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                let moduleName = "HostBootstrap.Ensure.Colima.Backend.Resolver.Testing"
                description <- strictReadFile (packageRoot </> "hostbootstrap-core.cabal")
                source <- strictReadFile (packageRoot </> "internal" </> "colima-backend" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Backend" </> "Resolver" </> "Testing.hs")
                exposed <- OwnershipFixture.expectRight (SourceGuard.effectiveMainExposedModules description)
                assertBool "the native fixture API remains private" (moduleName `notElem` exposed)
                expected <- maybe (assertFailure "the private resolver testing export pin is absent") pure
                    (lookup moduleName pinnedPrivateExportLists)
                SourceGuard.moduleExportTokens moduleName source @?= Just (SourceGuard.haskellTokens expected)
                tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "executeNativeResolverFixtureWithSettlement" source)
                SourceGuard.countHaskellTokenSequence
                    (SourceGuard.haskellTokens "executeNativeResolverFixtureWithSettlement :: FilePath -> FilePath -> IO (ResolverExecutionFixture, TrustedResolverResult)") source @?= 1
                for_ ["resolveNativeResolverFixture", "settleTrustedResolverProtocolForFixtureTesting", "renderTrustedResolverProtocol"] $ \name ->
                    assertBool ("the existing native pipeline retains " <> name) (name `elem` tokens)
                assertBool "the native entry returns before view projection" ("settlementView" `notElem` tokens)
                projection <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "settlementView" source)
                for_ ["TrustedResolverReady", "TrustedResolverMissingColima", "TrustedResolverUnsupported"] $ \name ->
                    assertBool ("the same pure projection handles " <> name) (name `elem` projection)
        , privateColimaIdentityCases
        , testCase "the prepared adapter projects into one private identity algebra" $
            SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                let moduleName = "HostBootstrap.Ensure.Colima.Backend.Identity"
                description <- strictReadFile (packageRoot </> "hostbootstrap-core.cabal")
                public <- strictReadFile (packageRoot </> "src" </> "HostBootstrap" </> "Ensure" </> "Colima.hs")
                private <- strictReadFile (packageRoot </> "internal" </> "colima-backend" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Backend" </> "Identity.hs")
                exposed <- OwnershipFixture.expectRight (SourceGuard.effectiveMainExposedModules description)
                assertBool "identity serialization is not a public module" (moduleName `notElem` exposed)
                owner <- maybe (assertFailure "the private backend library is absent") pure
                    (SourceGuard.namedStanza "library colima-backend-internal" description)
                assertBool "the backend owns the actual identity module" (moduleName `elem` SourceGuard.fieldModules "exposed-modules" owner)
                expected <- maybe (assertFailure "the private identity export pin is absent") pure
                    (lookup moduleName pinnedPrivateExportLists)
                SourceGuard.moduleExportTokens moduleName private @?= Just (SourceGuard.haskellTokens expected)
                definitions <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionNames public)
                for_ ["colimaOwnerToken", "hexText", "originRecordName"] $ \name ->
                    assertBool ("the adapter contains no duplicate encoding: " <> name) (name `notElem` definitions)
                for_ [("colimaAcquireCallDigest", ["colimaAcquireCallDigest", "providerWallCallFence", "providerWallCallArgs"]),
                      ("colimaInvocationDigest", ["colimaInvocationDigest", "preparedGatePlan", "preparedGateOperation", "preparedGateSession", "preparedGateFence", "preparedGateAttempt", "preparedGateJournalVersion"]),
                      ("bindColimaOwner", ["bindColimaOwner", "ownershipNamespace", "ownershipToolchain", "trustedAppleToolchainFingerprint"])] $ \(name, required) -> do
                    tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens name public)
                    assertBool ("the actual adapter delegates " <> name) ("ColimaIdentity" `elem` tokens)
                    for_ required $ \item -> assertBool ("the adapter projects " <> item) (item `elem` tokens)
                for_ ["direct-colima-acquire-v1", "direct-colima-invocation-v1"] $ \domain ->
                    assertBool ("only the private algebra serializes " <> domain) (not (domain `isInfixOf` public) && domain `isInfixOf` private)
        , privateSettlementProducerCases
        , testCase "the private settlement producer feeds one unexported generic join" $
            SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                let moduleName = "HostBootstrap.Ensure.Colima.Settlement.Internal"
                    privatePath = packageRoot </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Settlement" </> "Internal.hs"
                description <- strictReadFile (packageRoot </> "hostbootstrap-core.cabal")
                source <- strictReadFile privatePath
                public <- strictReadFile (packageRoot </> "src" </> "HostBootstrap" </> "Ensure" </> "Colima.hs")
                exposed <- OwnershipFixture.expectRight (SourceGuard.effectiveMainExposedModules description)
                assertBool "the settlement producer is not public" (moduleName `notElem` exposed)
                expected <- maybe (assertFailure "the settlement producer export pin is absent") pure
                    (lookup moduleName pinnedPrivateExportLists)
                SourceGuard.moduleExportTokens moduleName source @?= Just (SourceGuard.haskellTokens expected)
                doesFileExist (packageRoot </> "src" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Settlement" </> "Internal.hs") >>= (@?= False)
                producer <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "withColimaWallSettlement" source)
                for_ ["ColimaWallSettlementApplied", "ColimaWallSettlementAlreadyExact", "ProviderStartProjectionAuthority", "WallApplied", "WallAlreadyExact", "ProviderStartBackendCreated", "ProviderStartBackendRepaired"] $ \name ->
                    assertBool ("the closed producer retains " <> name) (name `elem` producer)
                for_ ["HostBootstrap.Reconcile", "HostBootstrap.Cluster.Budget", "HostBootstrap.Ensure.Colima"] $ \name ->
                    assertBool ("the private producer imports no public authority implementation: " <> name)
                        (not (SourceGuard.importsModule name source))
                joined <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "withColimaProviderSettlement" public)
                for_ ["withColimaWallSettlement", "withPreparedProviderStartParts", "withProviderWallSettlementPermitFromObservation", "settleProviderWallCall", "withLiveProviderWall", "completePreparedProviderStart", "withReconcileResult"] $ \name ->
                    assertBool ("the actual generic join consumes " <> name) (name `elem` joined)
                for_ ["ProviderStartProjectionAuthority", "ProviderStartBackendCreated", "ProviderStartBackendRepaired", "ColimaWallSettlementApplied", "ColimaWallSettlementAlreadyExact"] $ \name ->
                    assertBool ("the generic continuation makes no second backend decision: " <> name) (name `notElem` joined)
                exports <- maybe (assertFailure "the public Colima export list is absent") pure
                    (SourceGuard.moduleExportTokens "HostBootstrap.Ensure.Colima" public)
                assertBool "the generic join remains unexported" ("withColimaProviderSettlement" `notElem` exports)
                settled <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "settleColimaWallCall" public)
                assertBool "owned settlement consumes the actual generic join" ("withColimaProviderSettlement" `elem` settled)
        , testCase "owned Colima observations have one private declaration home" $
            SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                let moduleName = "HostBootstrap.Ensure.Colima.Observation"
                description <- strictReadFile (packageRoot </> "hostbootstrap-core.cabal")
                public <- strictReadFile (packageRoot </> "src" </> "HostBootstrap" </> "Ensure" </> "Colima.hs")
                bridge <- strictReadFile (packageRoot </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Settlement" </> "Internal.hs")
                private <- strictReadFile (packageRoot </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Observation.hs")
                exposed <- OwnershipFixture.expectRight (SourceGuard.effectiveMainExposedModules description)
                assertBool "the raw observations are not a public module" (moduleName `notElem` exposed)
                expected <- maybe (assertFailure "the private observation export pin is absent") pure
                    (lookup moduleName pinnedPrivateExportLists)
                SourceGuard.moduleExportTokens moduleName private @?= Just (SourceGuard.haskellTokens expected)
                for_ ["ColimaWallObservation", "ColimaOwnedObservation", "ExpectedColimaWall", "ColimaWallSettlementObservation"] $ \name -> do
                    let declaration = SourceGuard.haskellTokens ("data " <> name)
                    SourceGuard.countHaskellTokenSequence declaration private @?= 1
                    SourceGuard.countHaskellTokenSequence declaration public @?= 0
                    SourceGuard.countHaskellTokenSequence declaration bridge @?= 0
                assertBool "the public adapter imports the closed observations" (SourceGuard.importsModule moduleName public)
                assertBool "the settlement bridge uses the same declaration owner" (SourceGuard.importsModule moduleName bridge)
                for_ ["HostBootstrap.Reconcile", "HostBootstrap.Cluster.Budget", "HostBootstrap.Ensure.Colima", "HostBootstrap.Ensure.Colima.Settlement.Internal"] $ \name ->
                    assertBool ("the private data cannot depend on the public authority implementation: " <> name)
                        (not (SourceGuard.importsModule name private))
        , testCase "missing Colima is refused by the shared pure launch resolver" $
            resolveLaunch HostConfig{hcSubstrate = Substrate LinuxCpu Amd64, hcToolPaths = Map.empty}
                listColimaProfilesCommand @?= Left "colima not found on this host"
        , testCase "routed Docker admission distinguishes global options and subcommands" $ do
            profile <- either assertFailure pure (mkColimaProfile profileName)
            let context = dockerContextForProfile profile
                routeRefusal = Left "Docker command may not override the owned Colima route"
                subcommandRefusal = Left "Docker subcommand is forbidden on the owned Colima route"
                missingRefusal = Left "Docker command requires a subcommand"
                flags = ["-c", "-H", "--context", "--host", "--config", "--tls", "--tlsverify", "--tlscacert", "--tlscert", "--tlskey",
                         "-Hunix://x", "--host=tcp://x", "--context=other", "--config=/x", "--tlscert=/x"]
            routedDockerCommand context [] @?= missingRefusal
            routedDockerCommand context [""] @?= missingRefusal
            for_ flags $ \flag -> routedDockerCommand context [flag, "ps"] @?= routeRefusal
            for_ ["context", "login", "logout", "buildx"] $ \command ->
                routedDockerCommand context [command] @?= subcommandRefusal
            for_ [["exec", "ctr", "sh", "-c", "echo hi"], ["run", "--rm", "alpine", "grep", "-H", "x", "/etc/hosts"],
                  ["inspect", "my-context-volume"], ["run", "image", "--config=/x"]] $ \arguments ->
                case routedDockerCommand context arguments of
                    Right command -> commandArguments command @?= ["--context", "colima-" ++ profileName] ++ arguments
                    Left refusal -> assertFailure ("safe subcommand was refused: " <> refusal)
        , testCase "profile commands require the admitted ownership profile" $ do
            for_ ["", "h-a", "h-01234A", "h-012345/extra", "h-01234g"] $ \value ->
                mkColimaProfile value @?= Left "invalid direct-Colima profile"
            profile <- either assertFailure pure (mkColimaProfile profileName)
            commandArguments (deleteColimaProfileCommand profile) @?= ["delete", "--profile", profileName, "--force", "--data"]
            commandArguments (readColimaMachineIdCommand profile) @?= ["ssh", "--profile", profileName, "--", "cat", "/etc/machine-id"]
        , testCase "the described Colima commands use the expected tools" $ do
            profile <- either assertFailure pure (mkColimaProfile profileName)
            for_ [[], ["start", "--profile", "h-ffffff"], canonicalStartArgs ++ ["--profile", "h-ffffff"], canonicalStartArgs ++ ["--profile=h-ffffff"], canonicalStartArgs ++ ["-ph-ffffff"]] $ \arguments ->
                mkColimaStartArguments profile arguments @?= Left "invalid direct-Colima start arguments"
            let commandContext = dockerContextForProfile profile
            routed <- either assertFailure pure (routedDockerCommand commandContext ["ps"])
            let commands =
                    [ listColimaProfilesCommand
                    , startColimaProfileCommand canonicalTypedStartArgs
                    , deleteColimaProfileCommand profile
                    , readColimaMachineIdCommand profile
                    , listLimaDisksCommand
                    , inspectDockerContextCommand commandContext
                    , listDockerContextsCommand
                    , removeDockerContextCommand commandContext
                    , routed
                    ]
            nub (map commandTarget commands) @?= [ToolTarget Colima, ToolTarget Lima, ToolTarget Docker]
        , testCase "the direct driver describes every tool effect without running it" $ do
            profile <- either assertFailure pure (mkColimaProfile profileName)
            let commandContext = dockerContextForProfile profile
                view command = (commandTarget command, commandArguments command)
            map
                view
                [ listColimaProfilesCommand
                , startColimaProfileCommand canonicalTypedStartArgs
                , deleteColimaProfileCommand profile
                , readColimaMachineIdCommand profile
                , listLimaDisksCommand
                , inspectDockerContextCommand commandContext
                , listDockerContextsCommand
                , removeDockerContextCommand commandContext
                ]
                @?= [ (ToolTarget Colima, ["list", "--json"])
                    , (ToolTarget Colima, canonicalStartArgs)
                    , (ToolTarget Colima, ["delete", "--profile", profileName, "--force", "--data"])
                    , (ToolTarget Colima, ["ssh", "--profile", profileName, "--", "cat", "/etc/machine-id"])
                    , (ToolTarget Lima, ["disk", "list", "--json"])
                    , (ToolTarget Docker, ["context", "inspect", "colima-" ++ profileName])
                    , (ToolTarget Docker, ["context", "ls", "--format", "{{json .}}"])
                    , (ToolTarget Docker, ["context", "rm", "--force", "colima-" ++ profileName])
                    ]
            fmap view (routedDockerCommand commandContext ["ps", "--all"])
                @?= Right (ToolTarget Docker, ["--context", "colima-" ++ profileName, "ps", "--all"])
            fmap view (routedDockerCommand commandContext ["ps", "--context", "foreign"])
                @?= Right (ToolTarget Docker, ["--context", "colima-" ++ profileName, "ps", "--context", "foreign"])
            let listing = CapturedRun ExitSuccess "{\"name\":\"h-a\",\"status\":\"Running\",\"cpus\":8,\"memory\":17179869184,\"disk\":85899345920,\"runtime\":\"docker\"}\n" ""
            fmap (map ciName) (classifyColimaListing listing) @?= Right ["h-a"]
            classifyColimaListing listing{capturedStdout = capturedStdout listing ++ "\n"}
                @?= Left ColimaReportFraming
            classifyColimaListing listing{capturedStderr = "warning"}
                @?= Left ColimaToolStderr
            fmap fst (classifyMachineIdentity (CapturedRun ExitSuccess (replicate 32 'a' ++ "\n") ""))
                @?= Right (replicate 32 'a')
            classifyMachineIdentity (CapturedRun ExitSuccess (replicate 32 'A' ++ "\n") "")
                @?= Left ColimaReportShape
            fmap (map limaDiskName) (classifyLimaDiskListing (CapturedRun ExitSuccess "{\"name\":\"colima-h-a\",\"dir\":\"/owned/disk\",\"instance\":\"colima-h-a\",\"instanceDir\":\"/owned/instance\",\"format\":\"raw\",\"mountPoint\":\"\",\"size\":80}\n" ""))
                @?= Right ["colima-h-a"]
            classifyDockerContextListing (CapturedRun ExitSuccess "{\"Name\":\"colima-h-a\"}\n{\"Name\":\"colima-h-a\"}\n" "")
                @?= Left ColimaReportDuplicate
            for_ ["", "bad name", replicate 256 'a'] $ \name ->
                classifyDockerContextListing (CapturedRun ExitSuccess ("{\"Name\":\"" <> name <> "\"}\n") "")
                    @?= Left ColimaReportShape
            let inspectA = classifyDockerContextInspect (CapturedRun ExitSuccess "[{\"Name\":\"colima-h-a\",\"Endpoints\":{\"docker\":{\"Host\":\"unix:///owned.sock\"}}}]\n" "")
                inspectB = classifyDockerContextInspect (CapturedRun ExitSuccess "[ { \"Endpoints\" : { \"docker\" : { \"Host\" : \"unix:///owned.sock\" } }, \"Name\" : \"colima-h-a\" } ]" "")
                inspectC = classifyDockerContextInspect (CapturedRun ExitSuccess "[{\"Name\":\"colima-h-a\",\"Endpoints\":{\"docker\":{\"Host\":\"unix:///changed.sock\"}}}]" "")
            firstIdentity <- OwnershipFixture.expectRight (OwnershipFixture.kernelIdentityWords 1 2)
            secondIdentity <- OwnershipFixture.expectRight (OwnershipFixture.kernelIdentityWords 3 4)
            valueA <- OwnershipFixture.expectRight inspectA
            valueB <- OwnershipFixture.expectRight inspectB
            valueC <- OwnershipFixture.expectRight inspectC
            dockerContextFingerprint firstIdentity valueA @?= dockerContextFingerprint firstIdentity valueB
            assertBool "context endpoint changes its fingerprint" (dockerContextFingerprint firstIdentity valueA /= dockerContextFingerprint firstIdentity valueC)
            assertBool "directory identity changes its fingerprint" (dockerContextFingerprint firstIdentity valueA /= dockerContextFingerprint secondIdentity valueA)
        , testCase "Colima report classifiers refuse malformed, duplicate, and failed results" $ do
            let captured value = CapturedRun ExitSuccess value ""
                failed = CapturedRun (ExitFailure 1) "" ""
                disk directory size = "{\"name\":\"colima-h-a\",\"dir\":\"" ++ directory ++ "\",\"instance\":\"colima-h-a\",\"instanceDir\":\"/owned/instance\",\"format\":\"raw\",\"mountPoint\":\"\",\"size\":" ++ show (size :: Integer) ++ "}\n"
                colima name = "{\"name\":\"" ++ name ++ "\",\"status\":\"Running\",\"cpus\":8,\"memory\":17179869184,\"disk\":85899345920,\"runtime\":\"docker\"}\n"
            for_ [disk "relative/disk" 80, disk "/a/../b" 80, disk "/owned/disk" 0] $ \row ->
                classifyLimaDiskListing (captured row) @?= Left ColimaReportShape
            classifyLimaDiskListing (captured (disk "/owned/disk" 80 ++ disk "/owned/other" 80)) @?= Left ColimaReportDuplicate
            classifyLimaDiskListing (captured "not json\n") @?= Left ColimaReportDecode
            classifyLimaDiskListing failed @?= Left ColimaToolExit
            classifyLimaDiskListing (captured (init (disk "/owned/disk" 80))) @?= Left ColimaReportFraming
            classifyLimaDiskListing (CapturedRun ExitSuccess "" "warning") @?= Left ColimaToolStderr
            classifyDockerContextListing failed @?= Left ColimaToolExit
            classifyDockerContextListing (captured "not json\n") @?= Left ColimaReportDecode
            classifyDockerContextListing (captured "{}") @?= Left ColimaReportFraming
            classifyDockerContextListing (CapturedRun ExitSuccess "" "warning") @?= Left ColimaToolStderr
            for_ ["[]", "[{},{}]"] $ \value -> classifyDockerContextInspect (captured value) @?= Left ColimaReportShape
            classifyDockerContextInspect (captured "not json") @?= Left ColimaReportDecode
            classifyDockerContextInspect failed @?= Left ColimaToolExit
            classifyColimaListing (captured (colima "bad name")) @?= Left ColimaReportShape
            classifyColimaListing failed @?= Left ColimaToolExit
            classifyColimaListing (captured "not json\n") @?= Left ColimaReportDecode
            classifyColimaListing (captured (colima "h-a" ++ colima "h-a")) @?= Left ColimaReportDuplicate
            classifyMachineIdentity failed @?= Left ColimaToolExit
            classifyMachineIdentity (CapturedRun ExitSuccess "" "warning") @?= Left ColimaToolStderr
            for_ [replicate 31 'a' ++ "\n", replicate 33 'a' ++ "\n", replicate 32 'a'] $ \value ->
                assertBool "malformed machine identity is refused" (case classifyMachineIdentity (captured value) of Left _ -> True; Right _ -> False)
        , testCase "the native ownership backend explicitly refuses Windows" assertWindowsOwnershipRefusal
        , testCase "the owning driver retains native profile and context authority" $ onOwnershipHost $ do
            withSystemTempDirectory "hostbootstrap-colima-authority" $ \root -> do
                case mkColimaStageRecord ColimaReserved ownerToken (replicate 64 'c') acquireInvocation of
                    Left failure -> assertFailure failure
                    Right stageRecord -> do
                        owned <-
                            withColimaOwnershipEntry root profileName $ \session keys ->
                                Right <$> do
                                    written <- writeColimaStage session keys ExpectAbsent stageRecord
                                    case written of
                                        Left failure -> pure (Left failure)
                                        Right _ -> fmap (fmap (fmap (colimaStageRecordStage . snd))) (readColimaStage session keys)
                        owned @?= Right (Right (Just ColimaReserved))
                let home = root </> "owned-home"
                acquired <-
                    withColimaOwnershipEntry root profileName $ \session keys ->
                        Right <$> acquireColimaDirectory session (colimaHomeKey keys) home
                case acquired of
                    Right (Right _) -> do
                        doesDirectoryExist home >>= (@?= True)
                        reentered <-
                            withColimaOwnershipEntry root profileName $ \session keys ->
                                Right <$> ensureColimaDirectory session (colimaHomeKey keys) home
                        case reentered of
                            Right (Right _) -> pure ()
                            other -> assertFailure ("expected exact shared-clause re-entry, got " ++ show other)
                        released <-
                            withColimaOwnershipEntry root profileName $ \session keys ->
                                Right <$> releaseColimaDirectory session (colimaHomeKey keys) home
                        released @?= Right (Right ())
                        doesDirectoryExist home >>= (@?= False)
                    other -> assertFailure ("expected shared-clause directory acquisition, got " ++ show other)
            refused <- withColimaOwnershipEntry "/unused" "default" (\_ _ -> pure (Right ()))
            refused @?= Left "invalid direct-Colima profile"
            withSystemTempDirectory "hostbootstrap-colima-unbound-retry" $ \root -> do
                let parent = root </> "missing-parent"
                    home = parent </> "home"
                    context = root </> "docker-config"
                    prepare = prepareColimaNamespaces root profileName ownerToken (replicate 64 'c') acquireInvocation home context
                initialPreparation <- prepare
                case initialPreparation of
                    Left _ -> pure ()
                    other -> assertFailure ("expected missing parent refusal, got " <> show other)
                origin <- withColimaOwnershipEntry root profileName (\session keys -> readProtectedRecord session (colimaHomeKey keys))
                assertBool "the failed creation must retain its origin record" (either (const False) isJust origin)
                createDirectory parent
                prepare >>= (@?= Right ())
                stage <- withColimaOwnershipEntry root profileName (\session keys -> Right <$> readColimaStage session keys)
                fmap (fmap (fmap (colimaStageRecordStage . snd))) stage @?= Right (Right (Just ColimaPrepared))
            withSystemTempDirectory "hostbootstrap-colima-unbound-occupied" $ \root -> do
                let parent = root </> "missing-parent"
                    target = parent </> "home"
                withColimaOwnershipEntry root profileName (\session keys -> Right <$> ensureColimaDirectory session (colimaHomeKey keys) target) >>= \result ->
                    case result of
                        Right (Left _) -> pure ()
                        other -> assertFailure ("expected initial create failure, got " <> show other)
                createDirectory parent
                createDirectory target
                before <- withColimaOwnershipEntry root profileName (\session keys -> readProtectedRecord session (colimaHomeKey keys))
                withColimaOwnershipEntry root profileName (\session keys -> Right <$> ensureColimaDirectory session (colimaHomeKey keys) target) >>= \result ->
                    case result of
                        Right (Left (OwnershipOccupied _)) -> pure ()
                        other -> assertFailure ("expected occupied unbound refusal, got " <> show other)
                doesDirectoryExist target >>= (@?= True)
                withColimaOwnershipEntry root profileName (\session keys -> readProtectedRecord session (colimaHomeKey keys)) >>= (@?= before)
            withSystemTempDirectory "hostbootstrap-colima-stale-origin" $ \root -> do
                let target = root </> "home"
                createDirectory target
                priorIdentity <- observedNamespaceIdentity target
                withColimaOwnershipEntry root profileName (\session keys -> do
                    _ <- compareAndSwapProtectedRecord session (colimaHomeKey keys) ExpectAbsent
                        (renderOriginRecord (originRecord OwnedDirectory (OriginPresent priorIdentity))) >>= OwnershipFixture.expectRight
                    pure (Right ())) >>= (@?= Right ())
                removeDirectory target
                recovered <- withColimaOwnershipEntry root profileName
                    (\session keys -> Right <$> ensureColimaDirectory session (colimaHomeKey keys) target)
                case recovered of
                    Right (Right _) -> pure ()
                    other -> assertFailure ("expected stale present origin recovery, got " <> show other)
                doesDirectoryExist target >>= (@?= True)
            for_ [NormalCleanup, ParentReplaced, ProfileVersionChanged, SharedParents,
                  ContextAbsent, ContextReplaced, ContextStillListed, ContextBindingMissing, ContextDirectoryReplaced,
                  NamespaceEntryAdded, ContextMetadataRemoved, ManagedManifestDrift,
                  InterruptedManifestRefresh, FrozenManifestDrift, PostDeleteInterrupted, PostContextReleased, BlockedNamespace, PostCleanupBeforeCommit, BoundAcquisitionRetry] $ \scenario ->
              withSystemTempDirectory "hostbootstrap-colima-prepare" $ \root -> do
                scenarioCommands <- newIORef []
                let recordCommand command = atomicModifyIORef' scenarioCommands (\commands -> (commands ++ [(commandTarget command, commandArguments command)], ()))
                    home = root </> "isolated-home"
                    contextParent = root </> ".hostbootstrap" </> "colima"
                    context = contextParent </> "docker-config"
                    instanceDirectory = home </> "_lima" </> ("colima-" ++ profileName)
                    diskDirectory = home </> "_lima" </> "_disks" </> ("colima-" ++ profileName)
                    diskPath = diskDirectory </> "datadisk"
                    prepare = prepareColimaNamespaces root profileName ownerToken (replicate 64 'c') acquireInvocation home context
                prepare >>= (@?= Right ())
                prepare >>= (@?= Right ())
                doesDirectoryExist home >>= (@?= True)
                doesDirectoryExist context >>= (@?= True)
                parentIdentities <- traverse observedNamespaceIdentity [takeDirectory contextParent, contextParent]
                stage <-
                    withColimaOwnershipEntry root profileName $ \session keys ->
                        Right <$> readColimaStage session keys
                fmap (fmap (fmap (colimaStageRecordStage . snd))) stage @?= Right (Right (Just ColimaPrepared))
                scripted <-
                    newIORef
                        [ Right (CapturedRun ExitSuccess "" "")
                        , Right (CapturedRun ExitSuccess "started\n" "")
                        , Right (CapturedRun ExitSuccess ("{\"name\":\"" ++ profileName ++ "\",\"status\":\"Running\",\"cpus\":8,\"memory\":" ++ show (16 * gib) ++ ",\"disk\":" ++ show (80 * gib) ++ ",\"runtime\":\"docker\"}\n") "")
                        , Right (CapturedRun ExitSuccess (replicate 32 'd' ++ "\n") "")
                        ]
                scriptedCalls <- newIORef (0 :: Int)
                scriptedCommands <- newIORef []
                let interpret command = do
                        recordCommand command
                        index <- atomicModifyIORef' scriptedCalls (\count -> (count + 1, count))
                        let arguments = commandArguments command
                            machineRead = ["ssh", "--profile", profileName, "--", "cat", "/etc/machine-id"]
                            expected = case index of
                                0 -> [["list", "--json"]]
                                1 -> [canonicalStartArgs, machineRead]
                                2 -> [["list", "--json"]]
                                3 -> [machineRead]
                                _ -> []
                        atomicModifyIORef' scriptedCommands (\commands -> (commands ++ [arguments], ()))
                        if arguments `notElem` expected || commandTarget command /= ToolTarget Colima
                            then pure (Left ("unexpected start command " ++ show arguments))
                            else atomicModifyIORef' scripted $ \outcomes -> case outcomes of
                                outcome : remaining -> (remaining, outcome)
                                [] -> ([], Left "unexpected command")
                startOutcomes <- readIORef scripted
                let existingProfile = "{\"name\":\"" ++ profileName ++ "\",\"status\":\"Running\",\"cpus\":8,\"memory\":" ++ show (16 * gib) ++ ",\"disk\":" ++ show (80 * gib) ++ ",\"runtime\":\"docker\"}\n"
                writeIORef scripted [Right (CapturedRun ExitSuccess existingProfile "")]
                outcomeUnknown <- startPreparedColimaProfileWith interpret root profileName ownerToken
                    (replicate 64 'c') acquireInvocation home context diskPath 8 (16 * gib) (80 * gib) canonicalTypedStartArgs
                case outcomeUnknown of
                    Left (ColimaMutationProfileConflict message) -> do
                        assertBool "the conflict names the exact profile" (profileName `isInfixOf` message)
                        assertBool "the conflict names the retained Prepared state" ("Prepared" `isInfixOf` message)
                    other -> assertFailure ("expected outcome-unknown Prepared profile refusal, got " <> show other)
                readIORef scriptedCalls >>= (@?= 1)
                afterOutcomeUnknown <- withColimaOwnershipEntry root profileName (\session keys -> Right <$> readColimaStage session keys)
                afterOutcomeUnknown @?= stage
                absentCreation <- withColimaOwnershipEntry root profileName $ \session keys -> do
                    priorProfile <- readProtectedRecord session (colimaProfileKey keys)
                    priorDisk <- readProtectedRecord session (colimaDiskKey keys)
                    pure (Right (priorProfile, priorDisk))
                absentCreation @?= Right (Right Nothing, Right Nothing)
                let runStart failureRoot failureHome failureContext failureDisk =
                        startPreparedColimaProfileWith interpret failureRoot profileName ownerToken
                            (replicate 64 'c') acquireInvocation failureHome failureContext failureDisk 8 (16 * gib) (80 * gib) canonicalTypedStartArgs
                    failedStart = CapturedRun (ExitFailure 7) "" "start refused"
                    successfulStart = CapturedRun ExitSuccess "started\n" ""
                    emptyReport = CapturedRun ExitSuccess "" ""
                    postStartReport status cpu runtime = CapturedRun ExitSuccess
                        ("{\"name\":\"" ++ profileName ++ "\",\"status\":\"" ++ status ++ "\",\"cpus\":" ++ show (cpu :: Integer) ++ ",\"memory\":" ++ show (16 * gib) ++ ",\"disk\":" ++ show (80 * gib) ++ ",\"runtime\":\"" ++ runtime ++ "\"}\n") ""
                    refusalCases =
                        [ ([emptyReport, failedStart], ColimaMutationStartFailed)
                        , ([emptyReport, successfulStart, emptyReport], ColimaMutationProfileConflict "profile remained absent after start")
                        , ([emptyReport, successfulStart, postStartReport "Running" 4 "docker"], ColimaMutationProfileConflict "profile wall differs from the prepared wall")
                        , ([emptyReport, successfulStart, postStartReport "Stopped" 8 "docker"], ColimaMutationProfileConflict "profile is not running")
                        , ([emptyReport, successfulStart, postStartReport "Running" 8 "containerd"], ColimaMutationProfileConflict "profile runtime is not Docker")
                        , ([emptyReport, successfulStart, CapturedRun ExitSuccess (existingProfile ++ existingProfile) ""], ColimaMutationReportRefused ColimaReportDuplicate)
                        ]
                for_ refusalCases $ \(reports, expectedRefusal) ->
                    withSystemTempDirectory "hb-colima-start-refusal" $ \failureRoot -> do
                        let failureHome = failureRoot </> "home"
                            failureContext = failureRoot </> "docker-config"
                            failureDisk = failureHome </> "_lima" </> "_disks" </> ("colima-" ++ profileName) </> "datadisk"
                            readFailureStage = withColimaOwnershipEntry failureRoot profileName
                                (\session keys -> Right <$> readColimaStage session keys)
                        prepareColimaNamespaces failureRoot profileName ownerToken (replicate 64 'c')
                            acquireInvocation failureHome failureContext >>= (@?= Right ())
                        beforeFailure <- readFailureStage
                        writeIORef scripted (map Right reports)
                        writeIORef scriptedCalls 0
                        runStart failureRoot failureHome failureContext failureDisk >>= (@?= Left expectedRefusal)
                        readIORef scriptedCalls >>= (@?= length reports)
                        readFailureStage >>= (@?= beforeFailure)
                        fmap (fmap (fmap (colimaStageRecordStage . snd))) beforeFailure @?= Right (Right (Just ColimaPrepared))
                        doesPathExist failureDisk >>= (@?= False)
                        doesPathExist (failureHome </> "_lima" </> ("colima-" ++ profileName)) >>= (@?= False)
                        when (expectedRefusal == ColimaMutationStartFailed) $ do
                            prior <- withColimaOwnershipEntry failureRoot profileName $ \session keys -> do
                                profileRecord <- readProtectedRecord session (colimaProfileKey keys)
                                diskRecord <- readProtectedRecord session (colimaDiskKey keys)
                                pure (Right (profileRecord, diskRecord))
                            (profileRecord, diskRecord) <- OwnershipFixture.expectRight prior
                            for_ [profileRecord, diskRecord] $ \storedResult -> do
                                stored <- OwnershipFixture.expectRight storedResult >>= maybe (assertFailure "prior absence record is missing") pure
                                origin <- OwnershipFixture.expectRight (parseOriginRecord (protectedRecordBytes stored))
                                originRecordOrigin origin @?= OriginAbsent
                                originRecordBinding origin @?= Nothing
                writeIORef scripted []
                writeIORef scriptedCalls 0
                startPreparedColimaProfileWith interpret root profileName ownerToken (replicate 64 'e')
                    acquireInvocation home context diskPath 8 (16 * gib) (80 * gib) canonicalTypedStartArgs
                    >>= (@?= Left (ColimaMutationProfileConflict "prepared stage belongs to another lineage"))
                readIORef scriptedCalls >>= (@?= 0)
                retainedOtherLineage <- withColimaOwnershipEntry root profileName (\session keys -> Right <$> readColimaStage session keys)
                retainedOtherLineage @?= stage
                writeIORef scripted startOutcomes
                writeIORef scriptedCalls 0
                started <-
                    startPreparedColimaProfileWith
                        interpret
                        root
                        profileName
                        ownerToken
                        (replicate 64 'c')
                        acquireInvocation
                        home
                        context
                        diskPath
                        8
                        (16 * gib)
                        (80 * gib)
                        canonicalTypedStartArgs
                allStartCommands <- readIORef scriptedCommands
                assertBool "the start interpreter recorded each command" (not (null allStartCommands))
                startedObservation <- case started of
                    Right observation -> do
                        startedMachineIdentity observation @?= replicate 32 'd'
                        pure observation
                    other -> assertFailure ("expected value-driven native start settlement, got " ++ show other)
                createDirectoryIfMissing True diskDirectory
                writeFile diskPath "owned disk"
                case scenario of
                    ContextMetadataRemoved -> ByteString.writeFile (context </> "meta.json") "{}\n"
                    FrozenManifestDrift -> ByteString.writeFile (context </> "meta.json") "{}\n"
                    _ -> pure ()
                artifactScript <- newIORef (0 :: Int)
                let artifactInterpret command = do
                        recordCommand command
                        step <- atomicModifyIORef' artifactScript (\current -> (current + 1, current))
                        case (step, commandArguments command) of
                            (0, ["disk", "list", "--json"]) ->
                                pure (Right (CapturedRun ExitSuccess ("{\"name\":\"colima-" ++ profileName ++ "\",\"dir\":" ++ show diskDirectory ++ ",\"instance\":\"colima-" ++ profileName ++ "\",\"instanceDir\":" ++ show instanceDirectory ++ ",\"format\":\"raw\",\"mountPoint\":\"\",\"size\":" ++ show (80 * gib) ++ "}\n") ""))
                            (1, ["context", "inspect", commandContext]) | commandContext == "colima-" ++ profileName -> pure (Right (CapturedRun ExitSuccess ("[{\"Name\":\"colima-" ++ profileName ++ "\",\"Endpoints\":{\"docker\":{\"Host\":\"unix:///owned.sock\"}}}]\n") ""))
                            _ -> pure (Left "unexpected artifact observation command")
                artifacts <-
                    observeColimaArtifactsWith artifactInterpret root profileName ownerToken (replicate 64 'c') acquireInvocation home context (80 * gib)
                observedArtifacts <- case artifacts of
                    Right observed -> do
                        artifactDiskPath observed @?= diskPath
                        pure observed
                    other -> assertFailure ("expected authoritative artifact observation, got " ++ show other)
                publishPreparedColimaManifest root profileName ownerToken (replicate 64 'c') acquireInvocation (artifactOwnershipManifest observedArtifacts)
                    >>= (@?= Right ())
                bound <-
                    bindColimaCreationIdentities
                        root
                        profileName
                        ownerToken
                        (replicate 64 'c')
                        acquireInvocation
                        (replicate 32 'd')
                        diskPath
                case bound of
                    Right _ -> pure ()
                    other -> assertFailure ("expected shared profile/disk identity binding, got " ++ show other)
                writeIORef scripted
                    [ Right (CapturedRun ExitSuccess existingProfile "")
                    , Right (CapturedRun ExitSuccess (replicate 32 'd' ++ "\n") "")
                    ]
                writeIORef scriptedCalls 0
                recovered <- runStart root home context diskPath
                case recovered of
                    Right observation -> startedMachineIdentity observation @?= replicate 32 'd'
                    other -> assertFailure ("expected bound Prepared recovery, got " <> show other)
                readIORef scriptedCalls >>= (@?= 2)
                bindColimaCreationIdentities root profileName ownerToken (replicate 64 'c') acquireInvocation (replicate 32 'd') diskPath >>= (@?= bound)
                writeIORef scripted
                    [ Right (CapturedRun ExitSuccess existingProfile "")
                    , Right (CapturedRun ExitSuccess (replicate 32 'e' ++ "\n") "")
                    ]
                writeIORef scriptedCalls 0
                runStart root home context diskPath >>= (@?= Left (ColimaMutationProfileConflict "the bound Prepared profile identity changed"))
                readIORef scriptedCalls >>= (@?= 2)
                differentBinding <- bindColimaCreationIdentities root profileName ownerToken (replicate 64 'c') acquireInvocation (replicate 32 'e') diskPath
                case differentBinding of
                    Left (ColimaMutationOwnershipRefused _) -> pure ()
                    other -> assertFailure ("expected different bound identity refusal, got " <> show other)
                let settleWith expectedDisk = settleManagedColimaProfile root profileName ownerToken
                        (replicate 64 'c') acquireInvocation (startedMachineIdentity startedObservation)
                        (startedMachineEpoch startedObservation) (artifactContextDigest observedArtifacts)
                        expectedDisk 8 (16 * gib) (80 * gib) (20 * gib) home context
                    readPrepared = withColimaOwnershipEntry root profileName
                        (\session keys -> Right <$> readColimaStage session keys)
                preparedBefore <- readPrepared
                replacementDisk <- observedNamespaceIdentity home
                assertBool "the alternative disk identity is distinct" (replacementDisk /= artifactDiskIdentity observedArtifacts)
                settleWith replacementDisk >>= (@?= Left (ColimaMutationProfileConflict "data disk binding differs from settlement"))
                readPrepared >>= (@?= preparedBefore)
                retainedSettlementContext <- withColimaOwnershipEntry root profileName
                    (\session keys -> readProtectedRecord session (colimaContextKey keys))
                    >>= OwnershipFixture.expectRight
                    >>= maybe (assertFailure "the settlement context origin is absent") pure
                let parkedSettlementContext = root </> "settlement-context-parked"
                    hideSettlementContext = do
                        withColimaOwnershipEntry root profileName
                            (\session keys -> compareAndDeleteProtectedRecord session (colimaContextKey keys)
                                (ExpectVersion (protectedRecordVersion retainedSettlementContext)))
                            >>= OwnershipFixture.expectRight
                        renameDirectory context parkedSettlementContext
                    restoreSettlementContext = do
                        renameDirectory parkedSettlementContext context
                        _ <- withColimaOwnershipEntry root profileName
                            (\session keys -> compareAndSwapProtectedRecord session (colimaContextKey keys)
                                ExpectAbsent (protectedRecordBytes retainedSettlementContext))
                            >>= OwnershipFixture.expectRight
                        pure ()
                bracket_ hideSettlementContext restoreSettlementContext $ do
                    missing <- settleWith (artifactDiskIdentity observedArtifacts)
                    case missing of
                        Left (ColimaMutationOwnershipRefused _) -> pure ()
                        other -> assertFailure ("expected missing settlement context refusal, got " <> show other)
                    doesPathExist context >>= (@?= False)
                    withColimaOwnershipEntry root profileName
                        (\session keys -> readProtectedRecord session (colimaContextKey keys))
                        >>= OwnershipFixture.expectRight >>= (@?= Nothing)
                    readPrepared >>= (@?= preparedBefore)
                settled <- if scenario == BoundAcquisitionRetry then do
                    starts <- newIORef (0 :: Int)
                    retryEndpoint <- newIORef "unix:///owned.sock"
                    let retryInterpret command = do
                            recordCommand command
                            case commandArguments command of
                                ["list", "--json"] -> pure (Right (CapturedRun ExitSuccess existingProfile ""))
                                ["ssh", "--profile", commandProfile, "--", "cat", "/etc/machine-id"] | commandProfile == profileName -> pure (Right (CapturedRun ExitSuccess (replicate 32 'd' ++ "\n") ""))
                                ["disk", "list", "--json"] -> pure (Right (CapturedRun ExitSuccess ("{\"name\":\"colima-" ++ profileName ++ "\",\"dir\":" ++ show diskDirectory ++ ",\"instance\":\"colima-" ++ profileName ++ "\",\"instanceDir\":" ++ show instanceDirectory ++ ",\"format\":\"raw\",\"mountPoint\":\"\",\"size\":" ++ show (80 * gib) ++ "}\n") ""))
                                ["context", "inspect", commandContext] | commandContext == "colima-" ++ profileName -> do
                                    endpoint <- readIORef retryEndpoint
                                    pure (Right (CapturedRun ExitSuccess ("[{\"Name\":\"colima-" ++ profileName ++ "\",\"Endpoints\":{\"docker\":{\"Host\":\"" ++ endpoint ++ "\"}}}]\n") ""))
                                "start" : _ -> atomicModifyIORef' starts (\count -> (count + 1, ())) >> pure (Left "unexpected second start")
                                _ -> pure (Left "unexpected retry command")
                        retry = acquireManagedColimaProfileWith retryInterpret root profileName ownerToken
                            (replicate 64 'c') acquireInvocation home context 8 (16 * gib) (80 * gib) (20 * gib) canonicalTypedStartArgs
                        drift = home </> "retry-drift"
                    ByteString.writeFile drift "unsettled manifest change"
                    failed <- retry
                    case failed of
                        Left _ -> pure ()
                        other -> assertFailure ("expected bound acquisition manifest refusal, got " <> show other)
                    staged <- withColimaOwnershipEntry root profileName (\session keys -> Right <$> readColimaStage session keys)
                    fmap (fmap (fmap (colimaStageRecordStage . snd))) staged @?= Right (Right (Just ColimaPrepared))
                    removeFile drift
                    retried <- retry
                    case retried of
                        Right (ColimaManagedApplied _) -> pure ()
                        other -> assertFailure ("expected bound acquisition retry, got " <> show other)
                    readIORef starts >>= (@?= 0)
                    writeIORef retryEndpoint "unix:///changed.sock"
                    retry >>= (@?= Left (ColimaMutationProfileConflict "managed context evidence differs"))
                    writeIORef retryEndpoint "unix:///owned.sock"
                    pure (Right ())
                    else do
                        settleManagedColimaProfile
                            root
                            profileName
                            ownerToken
                            (replicate 64 'c')
                            acquireInvocation
                            (startedMachineIdentity startedObservation)
                            (startedMachineEpoch startedObservation)
                            (artifactContextDigest observedArtifacts)
                            (artifactDiskIdentity observedArtifacts)
                            8
                            (16 * gib)
                            (80 * gib)
                            (20 * gib)
                            home
                            context

                settled @?= Right ()
                origins <-
                    withColimaOwnershipEntry root profileName $ \session keys -> do
                        profileOrigin <- readProtectedRecord session (colimaProfileKey keys)
                        diskOrigin <- readProtectedRecord session (colimaDiskKey keys)
                        pure ((,) <$> profileOrigin <*> diskOrigin)
                fmap (\(profileOrigin, diskOrigin) -> (isJust profileOrigin, isJust diskOrigin)) origins
                    @?= Right (True, True)
                stageAfterSettlement <-
                    withColimaOwnershipEntry root profileName $ \session keys ->
                        Right <$> readColimaStage session keys
                fmap (fmap (fmap (colimaStageRecordStage . snd))) stageAfterSettlement @?= Right (Right (Just ColimaManaged))
                let driftPath = context </> "foreign.json"
                writeFile driftPath "{}\n"
                driftCommands <- newIORef []
                drifted <-
                    runManagedColimaDockerWith (\command -> do
                        atomicModifyIORef' driftCommands (\commands -> (commands ++ [commandArguments command], ()))
                        pure (Left "a drifted manifest must run no command")) root profileName ownerToken (replicate 64 'c') acquireInvocation home context ["ps"]
                drifted @?= Left (ColimaMutationOwnershipRefused (OwnershipMalformed "the current Colima namespace manifest differs from its retained authority"))
                receivedDriftCommands <- readIORef driftCommands
                assertBool "manifest drift never invokes routed Docker" (all (not . isPrefixOf ["--context"]) receivedDriftCommands)
                removeFile driftPath
                dockerScript <- newIORef (0 :: Int)
                let runningListing = "{\"name\":\"" ++ profileName ++ "\",\"status\":\"Running\",\"cpus\":8,\"memory\":" ++ show (16 * gib) ++ ",\"disk\":" ++ show (80 * gib) ++ ",\"runtime\":\"docker\"}\n"
                    dockerInterpret command = do
                        recordCommand command
                        step <- atomicModifyIORef' dockerScript (\current -> (current + 1, current))
                        case (step, commandArguments command) of
                            (0, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess runningListing ""))
                            (1, ["ssh", "--profile", commandProfile, "--", "cat", "/etc/machine-id"]) | commandProfile == profileName -> pure (Right (CapturedRun ExitSuccess (replicate 32 'd' ++ "\n") ""))
                            (2, ["--context", contextName, "ps", "--all"])
                                | contextName == "colima-" ++ profileName -> pure (Right (CapturedRun ExitSuccess "container-row\n" ""))
                            (3, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess runningListing ""))
                            (4, ["ssh", "--profile", commandProfile, "--", "cat", "/etc/machine-id"]) | commandProfile == profileName -> pure (Right (CapturedRun ExitSuccess (replicate 32 'd' ++ "\n") ""))
                            _ -> pure (Left "unexpected Docker transaction command")
                dockerRun <-
                    runManagedColimaDockerWith dockerInterpret root profileName ownerToken (replicate 64 'c') acquireInvocation home context ["ps", "--all"]
                fmap (capturedStdout . fst) dockerRun @?= Right "container-row\n"
                changedScript <- newIORef (0 :: Int)
                let changedInterpret command = do
                        recordCommand command
                        step <- atomicModifyIORef' changedScript (\current -> (current + 1, current))
                        case (step, commandArguments command) of
                            (0, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess runningListing ""))
                            (1, ["ssh", "--profile", commandProfile, "--", "cat", "/etc/machine-id"]) | commandProfile == profileName -> pure (Right (CapturedRun ExitSuccess (replicate 32 'd' ++ "\n") ""))
                            (2, ["--context", commandContext, "version"]) | commandContext == "colima-" ++ profileName -> pure (Right (CapturedRun ExitSuccess "version\n" ""))
                            (3, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess runningListing ""))
                            (4, ["ssh", "--profile", commandProfile, "--", "cat", "/etc/machine-id"]) | commandProfile == profileName -> pure (Right (CapturedRun ExitSuccess (replicate 32 'f' ++ "\n") ""))
                            _ -> pure (Left "unexpected replacement command")
                replaced <-
                    runManagedColimaDockerWith changedInterpret root profileName ownerToken (replicate 64 'c') acquireInvocation home context ["version"]
                case replaced of
                    Right (captured, Just (ColimaMutationProfileConflict "Docker profile identity changed")) -> captured @?= CapturedRun ExitSuccess "version\n" ""
                    other -> assertFailure ("expected post-command identity refusal, got " ++ show other)
                -- The managed stage and its directory bindings already come from
                -- the fixture above. Keep the inode live while making its path absent.
                callsBeforeMissing <- readIORef changedScript
                let parkedHome = root </> "temporarily-absent-home"
                bracket_ (renameDirectory home parkedHome) (renameDirectory parkedHome home) $ do
                    missing <- runManagedColimaDockerWith changedInterpret root profileName ownerToken (replicate 64 'c') acquireInvocation home context ["version"]
                    case missing of
                        Left (ColimaMutationOwnershipRefused _) -> pure ()
                        other -> assertFailure ("expected missing owned home refusal, got " <> show other)
                    readIORef changedScript >>= (@?= callsBeforeMissing)
                    doesPathExist home >>= (@?= False)
                -- A Managed route cannot acquire a replacement context if its binding is lost.
                retainedContext <- withColimaOwnershipEntry root profileName
                    (\session keys -> readProtectedRecord session (colimaContextKey keys))
                    >>= OwnershipFixture.expectRight
                    >>= maybe (assertFailure "the context origin is absent") pure
                let parkedContext = root </> "temporarily-absent-context"
                    hideContext = do
                        withColimaOwnershipEntry root profileName
                            (\session keys -> compareAndDeleteProtectedRecord session (colimaContextKey keys) (ExpectVersion (protectedRecordVersion retainedContext)))
                            >>= OwnershipFixture.expectRight
                        renameDirectory context parkedContext
                    restoreContext = do
                        renameDirectory parkedContext context
                        _ <- withColimaOwnershipEntry root profileName
                            (\session keys -> compareAndSwapProtectedRecord session (colimaContextKey keys) ExpectAbsent (protectedRecordBytes retainedContext))
                            >>= OwnershipFixture.expectRight
                        pure ()
                bracket_ hideContext restoreContext $ do
                    missing <- runManagedColimaDockerWith changedInterpret root profileName ownerToken (replicate 64 'c') acquireInvocation home context ["version"]
                    case missing of
                        Left (ColimaMutationOwnershipRefused _) -> pure ()
                        other -> assertFailure ("expected absent context binding refusal, got " <> show other)
                    readIORef changedScript >>= (@?= callsBeforeMissing)
                    doesPathExist context >>= (@?= False)
                    withColimaOwnershipEntry root profileName
                        (\session keys -> readProtectedRecord session (colimaContextKey keys))
                        >>= OwnershipFixture.expectRight >>= (@?= Nothing)
                -- Both candidate envelopes come from actual protected-store reads/writes.
                -- The later raw swap simulates a non-cooperating writer during the command.
                callsBeforeParentChecks <- readIORef changedScript
                let firstParent = takeDirectory contextParent
                    absentParent = root </> "temporarily-absent-context-parent"
                bracket_ (renameDirectory firstParent absentParent) (renameDirectory absentParent firstParent) $ do
                    missing <- runManagedColimaDockerWith changedInterpret root profileName ownerToken (replicate 64 'c') acquireInvocation home context ["version"]
                    case missing of
                        Left (ColimaMutationOwnershipRefused (OwnershipConflict _)) -> pure ()
                        other -> assertFailure ("expected missing parent refusal, got " <> show other)
                    readIORef changedScript >>= (@?= callsBeforeParentChecks)
                    doesPathExist firstParent >>= (@?= False)
                childIdentities <- traverse observedNamespaceIdentity [contextParent, context]
                let parkedParent = root </> "parked-context-parent"
                    replaceContextParent = do
                        renameDirectory firstParent parkedParent
                        createDirectory firstParent
                        renameDirectory (parkedParent </> "colima") contextParent
                    restoreContextParent = do
                        renameDirectory contextParent (parkedParent </> "colima")
                        removeDirectory firstParent
                        renameDirectory parkedParent firstParent
                bracket_ replaceContextParent restoreContextParent $ do
                    traverse observedNamespaceIdentity [contextParent, context] >>= (@?= childIdentities)
                    parentChangedResult <- runManagedColimaDockerWith changedInterpret root profileName ownerToken (replicate 64 'c') acquireInvocation home context ["version"]
                    case parentChangedResult of
                        Left (ColimaMutationOwnershipRefused (OwnershipConflict _)) -> pure ()
                        other -> assertFailure ("expected replaced parent refusal, got " <> show other)
                    readIORef changedScript >>= (@?= callsBeforeParentChecks)
                    traverse observedNamespaceIdentity [contextParent, context] >>= (@?= childIdentities)
                authority <- withColimaOwnershipEntry root profileName $ \session keys -> do
                    profileFound <- readProtectedRecord session (colimaProfileKey keys) >>= OwnershipFixture.expectRight
                    homeFound <- readProtectedRecord session (colimaHomeKey keys) >>= OwnershipFixture.expectRight
                    profileStored <- maybe (assertFailure "fixture profile record is absent") pure profileFound
                    homeStored <- maybe (assertFailure "fixture home record is absent") pure homeFound
                    let profilePath = sessionStoreRoot session </> "records" </> (Text.unpack (recordKeyText (colimaProfileKey keys)) ++ ".rec")
                    original <- ByteString.readFile profilePath
                    (intervening, envelope) <- if scenario == ProfileVersionChanged
                        then do
                            _ <- compareAndSwapProtectedRecord session (colimaProfileKey keys)
                                (ExpectVersion (protectedRecordVersion profileStored)) (protectedRecordBytes profileStored)
                                >>= OwnershipFixture.expectRight
                            advanced <- readProtectedRecord session (colimaProfileKey keys) >>= OwnershipFixture.expectRight
                            actual <- maybe (assertFailure "advanced profile record is absent") pure advanced
                            bytes <- ByteString.readFile profilePath
                            ByteString.writeFile profilePath original
                            pure (actual, bytes)
                        else pure (profileStored, original)
                    pure (Right (profilePath, intervening, envelope, homeStored))
                (profilePath, intervening, interveningEnvelope, homeStored) <- OwnershipFixture.expectRight authority
                let siblingHome = root </> "sibling-home"
                    siblingContext = contextParent </> "sibling-context"
                siblingBefore <- if scenario == SharedParents
                    then do
                        prepareColimaNamespaces root "h-123456" ownerToken (replicate 64 'c') acquireInvocation siblingHome siblingContext >>= (@?= Right ())
                        identities <- traverse observedNamespaceIdentity [siblingHome, siblingContext]
                        siblingStageBefore <- withColimaOwnershipEntry root "h-123456" $ \session keys -> Right <$> readColimaStage session keys
                        fmap (fmap (fmap (colimaStageRecordStage . snd))) siblingStageBefore @?= Right (Right (Just ColimaPrepared))
                        names <- parentRecordNames root
                        bytes <- traverse (ByteString.readFile . ((root </> "records") </>)) names
                        pure (Just (identities, siblingStageBefore, names, bytes))
                    else pure Nothing
                case scenario of
                    ManagedManifestDrift ->
                        ByteString.writeFile (context </> "managed-drift.json") "legitimate Managed metadata"
                    InterruptedManifestRefresh -> do
                        let metadata = context </> "managed-refresh.json"
                            readRefreshState session keys = do
                                stageValue <- readColimaStage session keys >>= OwnershipFixture.expectRight
                                    >>= maybe (assertFailure "refresh stage is absent") pure
                                manifestValue <- readProtectedRecord session (colimaManifestKey keys) >>= OwnershipFixture.expectRight
                                    >>= maybe (assertFailure "refresh manifest is absent") pure
                                homeValue <- readProtectedRecord session (colimaHomeKey keys) >>= OwnershipFixture.expectRight
                                contextValue <- readProtectedRecord session (colimaContextKey keys) >>= OwnershipFixture.expectRight
                                pure (fst stageValue, snd stageValue, manifestValue, homeValue, contextValue)
                        firstRefresh <- withColimaOwnershipEntry root profileName (\session keys -> do
                            (oldVersion, oldStage, oldManifest, homeOrigin, contextOrigin) <- readRefreshState session keys
                            ByteString.writeFile metadata "first Managed metadata"
                            refreshed <- refreshManagedColimaManifest session keys oldVersion oldStage home context
                                >>= OwnershipFixture.expectRight
                            after@(newVersion, newStage, newManifest, homeAfter, contextAfter) <- readRefreshState session keys
                            refreshed @?= (newVersion, newStage)
                            recordVersionWord newVersion @?= recordVersionWord oldVersion + 1
                            recordVersionWord (protectedRecordVersion newManifest) @?= recordVersionWord (protectedRecordVersion oldManifest) + 1
                            homeAfter @?= homeOrigin
                            contextAfter @?= contextOrigin
                            fmap managedContextDigest (colimaStageRecordEvidence newStage)
                                @?= fmap managedContextDigest (colimaStageRecordEvidence oldStage)
                            colimaStageRecordStage newStage @?= ColimaManaged
                            pure (Right after)) >>= OwnershipFixture.expectRight
                        interruptedRefresh <- withColimaOwnershipEntry root profileName (\session keys -> do
                            before@(oldVersion, oldStage, oldManifest, homeOrigin, contextOrigin) <- readRefreshState session keys
                            before @?= firstRefresh
                            ByteString.writeFile metadata "second Managed metadata"
                            homeManifest <- posixObserveOwnershipManifest True home >>= OwnershipFixture.expectRight
                            contextManifest <- posixObserveOwnershipManifest False context >>= OwnershipFixture.expectRight
                            prefixedHome <- OwnershipFixture.expectRight (Manifest.prefixOwnershipManifest "colima" homeManifest)
                            prefixedContext <- OwnershipFixture.expectRight (Manifest.prefixOwnershipManifest "docker" contextManifest)
                            manifest <- OwnershipFixture.expectRight (Manifest.mergeOwnershipManifests [prefixedHome, prefixedContext])
                            version <- compareAndSwapProtectedRecord session (colimaManifestKey keys)
                                (ExpectVersion (protectedRecordVersion oldManifest)) (renderOwnershipManifest manifest)
                                >>= OwnershipFixture.expectRight
                            after@(stageVersion, stageRecord, retainedManifest, homeAfter, contextAfter) <- readRefreshState session keys
                            (stageVersion, stageRecord) @?= (oldVersion, oldStage)
                            protectedRecordVersion retainedManifest @?= version
                            homeAfter @?= homeOrigin
                            contextAfter @?= contextOrigin
                            pure (Right after)) >>= OwnershipFixture.expectRight
                        callsBeforeInterrupted <- readIORef changedScript
                        incoherent <- runManagedColimaDockerWith changedInterpret root profileName ownerToken
                            (replicate 64 'c') acquireInvocation home context ["version"]
                        case incoherent of
                            Left (ColimaMutationOwnershipRefused (OwnershipMalformed _)) -> pure ()
                            other -> assertFailure ("expected incoherent manifest proof refusal, got " <> show other)
                        readIORef changedScript >>= (@?= callsBeforeInterrupted)
                        recoveredRefresh <- withColimaOwnershipEntry root profileName (\session keys -> do
                            before@(oldVersion, oldStage, retainedManifest, homeOrigin, contextOrigin) <- readRefreshState session keys
                            before @?= interruptedRefresh
                            refreshed <- refreshManagedColimaManifest session keys oldVersion oldStage home context
                                >>= OwnershipFixture.expectRight
                            after@(newVersion, newStage, manifestAfter, homeAfter, contextAfter) <- readRefreshState session keys
                            refreshed @?= (newVersion, newStage)
                            recordVersionWord newVersion @?= recordVersionWord oldVersion + 1
                            manifestAfter @?= retainedManifest
                            homeAfter @?= homeOrigin
                            contextAfter @?= contextOrigin
                            refreshManagedColimaManifest session keys newVersion newStage home context
                                >>= (@?= Right (newVersion, newStage))
                            readRefreshState session keys >>= (@?= after)
                            stale <- refreshManagedColimaManifest session keys oldVersion oldStage home context
                            OwnershipFixture.expectOccupied "a stale Managed refresh version" stale
                            readRefreshState session keys >>= (@?= after)
                            pure (Right ())) >>= OwnershipFixture.expectRight
                        recoveredRefresh @?= ()
                    FrozenManifestDrift -> do
                        frozen <- withColimaOwnershipEntry root profileName (\session keys -> do
                            (version, record) <- readColimaStage session keys >>= OwnershipFixture.expectRight
                                >>= maybe (assertFailure "freeze stage is absent") pure
                            releasing <- OwnershipFixture.expectRight (beginColimaReleaseRecord record cleanupInvocation)
                            next <- writeColimaStage session keys (ExpectVersion version) releasing >>= OwnershipFixture.expectRight
                            proof <- readProtectedRecord session (colimaManifestKey keys) >>= OwnershipFixture.expectRight
                            pure (Right (next, releasing, proof))) >>= OwnershipFixture.expectRight
                        let metadata = context </> "meta.json"
                            parked = root </> "parked-frozen-metadata"
                        originalIdentity <- observedNamespaceIdentity metadata
                        renameFile metadata parked
                        ByteString.writeFile metadata "foreign replacement metadata"
                        observedNamespaceIdentity metadata >>= \replacementIdentity ->
                            assertBool "frozen metadata replacement has a distinct live inode" (replacementIdentity /= originalIdentity)
                        withColimaOwnershipEntry root profileName (\session keys -> do
                            let (version, record, proof) = frozen
                            refreshManagedColimaManifest session keys version record home context
                                >>= (@?= Left (OwnershipMalformed "stage-manifest-refresh"))
                            readColimaStage session keys >>= (@?= Right (Just (version, record)))
                            readProtectedRecord session (colimaManifestKey keys) >>= (@?= Right proof)
                            pure (Right ())) >>= (@?= Right ())
                        observedNamespaceIdentity parked >>= (@?= originalIdentity)
                    _ -> pure ()
                retainedCleanupManifest <- withColimaOwnershipEntry root profileName
                    (\session keys -> readProtectedRecord session (colimaManifestKey keys))
                contextIdentityBeforeCleanup <- observedNamespaceIdentity context
                contextStoredBeforeCleanup <- withColimaOwnershipEntry root profileName
                    (\session keys -> readProtectedRecord session (colimaContextKey keys))
                    >>= OwnershipFixture.expectRight
                    >>= maybe (assertFailure "context origin is absent before the cleanup fixture") pure
                case scenario of
                    ContextBindingMissing ->
                        withColimaOwnershipEntry root profileName
                            (\session keys -> compareAndDeleteProtectedRecord session (colimaContextKey keys)
                                (ExpectVersion (protectedRecordVersion contextStoredBeforeCleanup)))
                            >>= (@?= Right ())
                    ContextDirectoryReplaced -> do
                        renameDirectory context (root </> "parked-context-directory")
                        createDirectory context
                    _ -> pure ()
                contextIdentityAtCleanup <- observedNamespaceIdentity context
                let cleanupContextListing = "{\"Name\":\"colima-" ++ profileName ++ "\"}\n"
                    cleanupContextEndpoint = if scenario == ContextReplaced then "unix:///foreign.sock" else "unix:///owned.sock"
                cleanupScript <- newIORef (0 :: Int)
                cleanupListing <- newIORef runningListing
                cleanupMachine <- newIORef (replicate 32 'd' ++ "\n")
                let cleanupInterpret command = do
                        recordCommand command
                        step <- atomicModifyIORef' cleanupScript (\current -> (current + 1, current))
                        case (step, commandArguments command) of
                            (0, ["list", "--json"]) -> (\value -> Right (CapturedRun ExitSuccess value "")) <$> readIORef cleanupListing
                            (1, ["ssh", "--profile", commandProfile, "--", "cat", "/etc/machine-id"]) | commandProfile == profileName -> (\value -> Right (CapturedRun ExitSuccess value "")) <$> readIORef cleanupMachine
                            (2, ["delete", "--profile", commandProfile, "--force", "--data"]) | commandProfile == profileName -> do
                                removePathForcibly (home </> "_lima")
                                case scenario of
                                    NormalCleanup -> pure ()
                                    PostDeleteInterrupted -> pure ()
                                    PostContextReleased -> pure ()
                                    BlockedNamespace -> pure ()
                                    PostCleanupBeforeCommit -> pure ()
                                    BoundAcquisitionRetry -> pure ()
                                    SharedParents -> pure ()
                                    ContextAbsent -> pure ()
                                    ContextReplaced -> pure ()
                                    ContextStillListed -> pure ()
                                    ContextBindingMissing -> pure ()
                                    ContextDirectoryReplaced -> pure ()
                                    ContextMetadataRemoved -> pure ()
                                    ManagedManifestDrift -> pure ()
                                    InterruptedManifestRefresh -> pure ()
                                    FrozenManifestDrift -> pure ()
                                    NamespaceEntryAdded -> ByteString.writeFile (home </> "late.txt") "introduced during delete"
                                    ParentReplaced -> do
                                        renameDirectory home (root </> "parked-owned-home")
                                        createDirectoryIfMissing True home
                                        writeFile (home </> "foreign.txt") "foreign namespace bytes"
                                    ProfileVersionChanged -> ByteString.writeFile profilePath interveningEnvelope
                                pure (Right (CapturedRun ExitSuccess "deleted\n" ""))
                            (3, ["list", "--json"]) | scenario == PostDeleteInterrupted -> pure (Left "post-delete listing interrupted")
                            (3, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess "" ""))
                            (4, ["list", "--json"]) | scenario == PostDeleteInterrupted -> pure (Right (CapturedRun ExitSuccess "" ""))
                            (5, ["list", "--json"]) | scenario == PostDeleteInterrupted -> pure (Right (CapturedRun ExitSuccess "" ""))
                            (6, ["context", "ls", "--format", "{{json .}}"]) | scenario == PostDeleteInterrupted -> pure (Right (CapturedRun ExitSuccess "" ""))
                            (4, ["context", "ls", "--format", "{{json .}}"]) ->
                                pure (Right (CapturedRun ExitSuccess (if scenario == ContextAbsent then "" else cleanupContextListing) ""))
                            (5, ["context", "inspect", commandContext]) | commandContext == "colima-" ++ profileName ->
                                pure (Right (CapturedRun ExitSuccess ("[{\"Name\":\"colima-" ++ profileName ++ "\",\"Endpoints\":{\"docker\":{\"Host\":\"" ++ cleanupContextEndpoint ++ "\"}}}]\n") ""))
                            (6, ["context", "rm", "--force", commandContext]) | commandContext == "colima-" ++ profileName -> do
                                case scenario of
                                    ContextMetadataRemoved -> removeFile (context </> "meta.json")
                                    _ -> pure ()
                                pure (Right (CapturedRun ExitSuccess "" ""))
                            (7, ["context", "ls", "--format", "{{json .}}"]) ->
                                pure (Right (CapturedRun ExitSuccess (if scenario == ContextStillListed then cleanupContextListing else "") ""))
                            _ -> pure (Left "unexpected cleanup command")
                let performCleanup = cleanupManagedColimaProfileWith cleanupInterpret root profileName ownerToken
                        (replicate 64 'c') acquireInvocation cleanupInvocation home context diskPath
                    readCleanupStage = withColimaOwnershipEntry root profileName
                        (\session keys -> Right <$> readColimaStage session keys)
                if scenario == NormalCleanup then do
                    unchangedStage <- readCleanupStage
                    let cleanupWallListing cpu memory disk runtime = "{\"name\":\"" ++ profileName ++ "\",\"status\":\"Running\",\"cpus\":" ++ show (cpu :: Integer) ++ ",\"memory\":" ++ show memory ++ ",\"disk\":" ++ show disk ++ ",\"runtime\":\"" ++ runtime ++ "\"}\n"
                        refusedCleanup commands = do
                            cleanupRefusal <- performCleanup
                            case cleanupRefusal of
                                Left (ColimaMutationProfileConflict _) -> pure ()
                                other -> assertFailure ("expected pre-delete cleanup conflict, got " <> show other)
                            readIORef cleanupScript >>= (@?= commands)
                            readCleanupStage >>= (@?= unchangedStage)
                            doesFileExist diskPath >>= (@?= True)
                    for_ ["",
                          cleanupWallListing 4 (16 * gib) (80 * gib) "docker",
                          cleanupWallListing 8 (8 * gib) (80 * gib) "docker",
                          cleanupWallListing 8 (16 * gib) (40 * gib) "docker",
                          cleanupWallListing 8 (16 * gib) (80 * gib) "containerd"] $ \value -> do
                        writeIORef cleanupListing value
                        writeIORef cleanupScript 0
                        refusedCleanup 1
                    writeIORef cleanupListing (runningListing ++ runningListing)
                    writeIORef cleanupScript 0
                    performCleanup >>= (@?= Left (ColimaMutationReportRefused ColimaReportDuplicate))
                    readIORef cleanupScript >>= (@?= 1)
                    readCleanupStage >>= (@?= unchangedStage)
                    writeIORef cleanupListing runningListing
                    writeIORef cleanupMachine (replicate 32 'e' ++ "\n")
                    writeIORef cleanupScript 0
                    refusedCleanup 2
                    writeIORef cleanupMachine (replicate 32 'd' ++ "\n")
                    writeIORef cleanupScript 0
                    -- Persist a genuine same-invocation release intent over the
                    -- existing Managed proof; resume must retain its frozen scope.
                    withColimaOwnershipEntry root profileName (\session keys -> do
                        current <- readColimaStage session keys >>= OwnershipFixture.expectRight
                            >>= maybe (assertFailure "the managed cleanup fixture stage is absent") pure
                        releasing <- OwnershipFixture.expectRight (beginColimaReleaseRecord (snd current) cleanupInvocation)
                        _ <- writeColimaStage session keys (ExpectVersion (fst current)) releasing >>= OwnershipFixture.expectRight
                        pure (Right ())) >>= (@?= Right ())
                else pure ()
                if scenario `elem` [PostContextReleased, BlockedNamespace, PostCleanupBeforeCommit] then do
                    removePathForcibly (home </> "_lima")
                    withColimaOwnershipEntry root profileName (\session keys -> do
                        for_ [colimaProfileKey keys, colimaDiskKey keys] $ \key -> do
                            held <- readProtectedRecord session key >>= OwnershipFixture.expectRight
                                >>= maybe (assertFailure "the reported origin is absent") pure
                            compareAndDeleteProtectedRecord session key (ExpectVersion (protectedRecordVersion held)) >>= OwnershipFixture.expectRight
                        current <- readColimaStage session keys >>= OwnershipFixture.expectRight
                            >>= maybe (assertFailure "the managed cleanup fixture stage is absent") pure
                        releasing <- OwnershipFixture.expectRight (beginColimaReleaseRecord (snd current) cleanupInvocation)
                        contextReleased <- OwnershipFixture.expectRight (advanceSettledColimaStageRecord releasing ColimaContextReleased)
                        _ <- writeColimaStage session keys (ExpectVersion (fst current)) contextReleased >>= OwnershipFixture.expectRight
                        pure (Right ())) >>= (@?= Right ())
                    else pure ()
                if scenario == PostCleanupBeforeCommit then do
                    removePathForcibly home
                    removePathForcibly context
                    withColimaOwnershipEntry root profileName (\session keys -> do
                        for_ [colimaHomeKey keys, colimaCacheKey keys, colimaTemporaryKey keys, colimaContextKey keys, colimaManifestKey keys] $ \key -> do
                            held <- readProtectedRecord session key >>= OwnershipFixture.expectRight
                                >>= maybe (assertFailure "the namespace record is absent") pure
                            compareAndDeleteProtectedRecord session key (ExpectVersion (protectedRecordVersion held)) >>= OwnershipFixture.expectRight
                        pure (Right ())) >>= (@?= Right ())
                    else pure ()
                if scenario == BlockedNamespace then do
                    createDirectory (home </> "_lima")
                    ByteString.writeFile (home </> "_lima" </> "foreign") "occupied"
                    else pure ()
                firstCleanup <- performCleanup
                cleaned <- if scenario == BlockedNamespace then do
                    case firstCleanup of
                        Left (ColimaMutationOwnershipRefused _) -> pure ()
                        other -> assertFailure ("expected occupied namespace refusal, got " <> show other)
                    blockedStage <- readCleanupStage
                    fmap (fmap (fmap (colimaStageRecordStage . snd))) blockedStage @?= Right (Right (Just ColimaContextReleased))
                    retained <- withColimaOwnershipEntry root profileName $ \session keys -> do
                        records <- traverse (readProtectedRecord session)
                            [colimaHomeKey keys, colimaCacheKey keys, colimaTemporaryKey keys, colimaManifestKey keys]
                        pure (Right records)
                    case retained of
                        Right records -> map (fmap isJust) records @?= replicate 4 (Right True)
                        Left refusal -> assertFailure refusal
                    removeFile (home </> "_lima" </> "foreign")
                    removeDirectory (home </> "_lima")
                    performCleanup
                    else if scenario == PostDeleteInterrupted then do
                    case firstCleanup of
                        Left _ -> pure ()
                        other -> assertFailure ("expected interrupted post-delete listing, got " <> show other)
                    interruptedStage <- readCleanupStage
                    fmap (fmap (fmap (colimaStageRecordStage . snd))) interruptedStage @?= Right (Right (Just ColimaReleasing))
                    readIORef cleanupScript >>= (@?= 4)
                    performCleanup
                    else pure firstCleanup
                let expectReleased = do
                        cleaned @?= Right ()
                        doesDirectoryExist home >>= (@?= False)
                        doesDirectoryExist context >>= (@?= False)
                        cleanupState <-
                            withColimaOwnershipEntry root profileName $ \session keys -> do
                                profileOrigin <- readProtectedRecord session (colimaProfileKey keys)
                                diskOrigin <- readProtectedRecord session (colimaDiskKey keys)
                                finalStage <- readColimaStage session keys
                                pure (Right (profileOrigin, diskOrigin, finalStage))
                        fmap (\(profileOrigin, diskOrigin, finalStage) -> (fmap isJust profileOrigin, fmap isJust diskOrigin, fmap (fmap (colimaStageRecordStage . snd)) finalStage)) cleanupState
                            @?= Right (Right False, Right False, Right (Just ColimaReleased))
                        commandsBeforeRepeat <- readIORef cleanupScript
                        cleanupManagedColimaProfileWith cleanupInterpret root profileName ownerToken (replicate 64 'c') acquireInvocation cleanupInvocation home context diskPath >>= (@?= Right ())
                        readIORef cleanupScript >>= (@?= commandsBeforeRepeat)
                case scenario of
                    BoundAcquisitionRetry -> do
                        expectReleased
                        readIORef cleanupScript >>= (@?= 8)
                    PostCleanupBeforeCommit -> do
                        expectReleased
                        readIORef cleanupScript >>= (@?= 0)
                    BlockedNamespace -> do
                        expectReleased
                        readIORef cleanupScript >>= (@?= 0)
                    PostContextReleased -> do
                        expectReleased
                        createDirectory home
                        residual <- performCleanup
                        case residual of
                            Left (ColimaMutationOwnershipRefused (OwnershipOccupied _)) -> pure ()
                            other -> assertFailure ("expected non-vacant Released replay refusal, got " <> show other)
                        readIORef cleanupScript >>= (@?= 0)
                        removeDirectory home
                    PostDeleteInterrupted -> do
                        expectReleased
                        readIORef cleanupScript >>= (@?= 7)
                    NormalCleanup -> do
                        expectReleased
                        doesPathExist contextParent >>= (@?= False)
                        doesPathExist (takeDirectory contextParent) >>= (@?= False)
                        parentRecordNames root >>= (@?= [])
                    SharedParents -> do
                        expectReleased
                        traverse observedNamespaceIdentity [takeDirectory contextParent, contextParent] >>= (@?= parentIdentities)
                        case siblingBefore of
                            Nothing -> assertFailure "the shared-parent fixture was not prepared"
                            Just (identities, retainedSiblingStage, names, bytes) -> do
                                traverse observedNamespaceIdentity [siblingHome, siblingContext] >>= (@?= identities)
                                stageAfter <- withColimaOwnershipEntry root "h-123456" $ \session keys -> Right <$> readColimaStage session keys
                                stageAfter @?= retainedSiblingStage
                                parentRecordNames root >>= (@?= names)
                                traverse (ByteString.readFile . ((root </> "records") </>)) names >>= (@?= bytes)
                    ContextAbsent -> do
                        expectReleased
                        readIORef cleanupScript >>= (@?= 5)
                    ContextReplaced -> do
                        case cleaned of
                            Left (ColimaMutationProfileConflict _) -> pure ()
                            other -> assertFailure ("expected foreign context fingerprint refusal, got " <> show other)
                        readIORef cleanupScript >>= (@?= 6)
                        observedNamespaceIdentity context >>= (@?= contextIdentityBeforeCleanup)
                        contextStage <- withColimaOwnershipEntry root profileName $ \session keys -> Right <$> readColimaStage session keys
                        fmap (fmap (fmap (colimaStageRecordStage . snd))) contextStage @?= Right (Right (Just ColimaReleasing))
                    ContextStillListed -> do
                        case cleaned of
                            Left (ColimaMutationProfileConflict _) -> pure ()
                            other -> assertFailure ("expected still-listed context refusal, got " <> show other)
                        readIORef cleanupScript >>= (@?= 8)
                        observedNamespaceIdentity context >>= (@?= contextIdentityBeforeCleanup)
                        readbackStage <- withColimaOwnershipEntry root profileName $ \session keys -> Right <$> readColimaStage session keys
                        fmap (fmap (fmap (colimaStageRecordStage . snd))) readbackStage @?= Right (Right (Just ColimaReleasing))
                    ContextBindingMissing -> do
                        case cleaned of
                            Left (ColimaMutationOwnershipRefused (OwnershipMalformed _)) -> pure ()
                            other -> assertFailure ("expected missing context binding refusal, got " <> show other)
                        readIORef cleanupScript >>= (@?= 0)
                        observedNamespaceIdentity context >>= (@?= contextIdentityBeforeCleanup)
                        missingContextOrigin <- withColimaOwnershipEntry root profileName
                            (\session keys -> readProtectedRecord session (colimaContextKey keys))
                        missingContextOrigin @?= Right Nothing
                    ContextDirectoryReplaced -> do
                        case cleaned of
                            Left (ColimaMutationOwnershipRefused (OwnershipConflict _)) -> pure ()
                            other -> assertFailure ("expected replaced context directory refusal, got " <> show other)
                        readIORef cleanupScript >>= (@?= 0)
                        assertBool "replacement context has a distinct live inode" (contextIdentityAtCleanup /= contextIdentityBeforeCleanup)
                        observedNamespaceIdentity context >>= (@?= contextIdentityAtCleanup)
                        observedNamespaceIdentity (root </> "parked-context-directory") >>= (@?= contextIdentityBeforeCleanup)
                        replacedContextOrigin <- withColimaOwnershipEntry root profileName
                            (\session keys -> readProtectedRecord session (colimaContextKey keys))
                        replacedContextOrigin @?= Right (Just contextStoredBeforeCleanup)
                    NamespaceEntryAdded -> do
                        case cleaned of
                            Left (ColimaMutationOwnershipRefused (OwnershipOccupied _)) -> pure ()
                            other -> assertFailure ("expected unretained namespace entry refusal, got " <> show other)
                        readIORef cleanupScript >>= (@?= 4)
                        ByteString.readFile (home </> "late.txt") >>= (@?= "introduced during delete")
                        currentReleaseManifest <- withColimaOwnershipEntry root profileName
                            (\session keys -> readProtectedRecord session (colimaManifestKey keys))
                        currentReleaseManifest @?= retainedCleanupManifest
                        introducedStage <- withColimaOwnershipEntry root profileName $ \session keys -> Right <$> readColimaStage session keys
                        fmap (fmap (fmap (colimaStageRecordStage . snd))) introducedStage @?= Right (Right (Just ColimaReleasing))
                    ContextMetadataRemoved -> do
                        expectReleased
                        readIORef cleanupScript >>= (@?= 8)
                    ManagedManifestDrift -> do
                        expectReleased
                        readIORef cleanupScript >>= (@?= 8)
                    InterruptedManifestRefresh -> do
                        expectReleased
                        readIORef cleanupScript >>= (@?= 8)
                    FrozenManifestDrift -> do
                        cleaned @?= Left (ColimaMutationOwnershipRefused
                            (OwnershipOccupied "a namespace remainder differs from its retained authority: 646f636b65722f6d6574612e6a736f6e"))
                        readIORef cleanupScript >>= (@?= 0)
                        ByteString.readFile (context </> "meta.json") >>= (@?= "foreign replacement metadata")
                        ByteString.readFile (root </> "parked-frozen-metadata") >>= (@?= "{}\n")
                        finalFrozenProof <- withColimaOwnershipEntry root profileName
                            (\session keys -> readProtectedRecord session (colimaManifestKey keys))
                        finalFrozenProof @?= retainedCleanupManifest
                    ParentReplaced -> do
                        case cleaned of
                            Left (ColimaMutationOwnershipRefused (OwnershipConflict _)) -> pure ()
                            other -> assertFailure ("expected stored-parent identity refusal, got " ++ show other)
                        readFile (home </> "foreign.txt") >>= (@?= "foreign namespace bytes")
                        doesDirectoryExist (root </> "parked-owned-home") >>= (@?= True)
                        retained <- withColimaOwnershipEntry root profileName $ \session keys ->
                            readProtectedRecord session (colimaHomeKey keys)
                        retained @?= Right (Just homeStored)
                    ProfileVersionChanged -> do
                        case cleaned of
                            Left (ColimaMutationOwnershipRefused (OwnershipProbeFailed _ _)) -> pure ()
                            other -> assertFailure ("expected captured-version refusal, got " ++ show other)
                        retained <- withColimaOwnershipEntry root profileName $ \session keys ->
                            readProtectedRecord session (colimaProfileKey keys)
                        retained @?= Right (Just intervening)
                        ByteString.readFile profilePath >>= (@?= interveningEnvelope)
                        doesDirectoryExist home >>= (@?= True)
                        doesDirectoryExist context >>= (@?= True)
            withSystemTempDirectory "hostbootstrap-colima-one-entry" $ \root -> do
                let home = root </> "isolated-home"
                    context = root </> "docker-config"
                    instanceDirectory = home </> "_lima" </> ("colima-" ++ profileName)
                    diskDirectory = home </> "_lima" </> "_disks" </> ("colima-" ++ profileName)
                    diskPath = diskDirectory </> "datadisk"
                    runningListing = "{\"name\":\"" ++ profileName ++ "\",\"status\":\"Running\",\"cpus\":8,\"memory\":" ++ show (16 * gib) ++ ",\"disk\":" ++ show (80 * gib) ++ ",\"runtime\":\"docker\"}\n"
                firstDerived <- OwnershipFixture.expectRight
                    (ColimaNames.deriveColimaNames "demo" "production" "host-root" "frame" root)
                secondDerived <- OwnershipFixture.expectRight
                    (ColimaNames.deriveColimaNames "demo" "harness:run-collision" "host-root" "frame" root)
                let namespaceLineage = Text.unpack . sha256Hex . Text.Encoding.encodeUtf8 . Text.pack . snd
                    initialLineage = namespaceLineage firstDerived
                    collisionLineage = namespaceLineage secondDerived
                assertBool "two actual namespace keys are forced through the same short profile"
                    (snd firstDerived /= snd secondDerived && initialLineage /= collisionLineage)
                oneEntryCommands <- newIORef []
                oneEntryScript <- newIORef (0 :: Int)
                oneEntryStarts <- newIORef (0 :: Int)
                firstEntryCommand <- newEmptyMVar
                releaseFirstEntry <- newEmptyMVar
                let oneEntryInterpret command = do
                        atomicModifyIORef' oneEntryCommands (\commands -> (commands ++ [(commandTarget command, commandArguments command)], ()))
                        step <- atomicModifyIORef' oneEntryScript (\current -> (current + 1, current))
                        let acquisitionStep = if step >= 19 then step - 19 else step
                        case (acquisitionStep, commandArguments command) of
                            (0, ["context", "ls", "--format", "{{json .}}"]) -> do
                                if step == 0 then putMVar firstEntryCommand () >> takeMVar releaseFirstEntry else pure ()
                                pure (Right (CapturedRun ExitSuccess "" ""))
                            (1, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess "" ""))
                            (2, arguments) | arguments == canonicalStartArgs -> do
                                atomicModifyIORef' oneEntryStarts (\count -> (count + 1, ()))
                                createDirectoryIfMissing True diskDirectory
                                createDirectoryIfMissing True instanceDirectory
                                writeFile diskPath "owned disk"
                                writeFile (context </> "meta.json") "{}\n"
                                pure (Right (CapturedRun ExitSuccess "started\n" ""))
                            (3, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess runningListing ""))
                            (4, ["ssh", "--profile", commandProfile, "--", "cat", "/etc/machine-id"]) | commandProfile == profileName -> pure (Right (CapturedRun ExitSuccess (replicate 32 'd' ++ "\n") ""))
                            (5, ["disk", "list", "--json"]) -> pure (Right (CapturedRun ExitSuccess ("{\"name\":\"colima-" ++ profileName ++ "\",\"dir\":\"" ++ diskDirectory ++ "\",\"instance\":\"colima-" ++ profileName ++ "\",\"instanceDir\":\"" ++ instanceDirectory ++ "\",\"format\":\"raw\",\"mountPoint\":\"\",\"size\":" ++ show (80 * gib) ++ "}\n") ""))
                            (6, ["context", "inspect", commandContext]) | commandContext == "colima-" ++ profileName -> pure (Right (CapturedRun ExitSuccess ("[{\"Name\":\"colima-" ++ profileName ++ "\"}]\n") ""))
                            (7, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess runningListing ""))
                            (8, ["ssh", "--profile", commandProfile, "--", "cat", "/etc/machine-id"]) | commandProfile == profileName -> pure (Right (CapturedRun ExitSuccess (replicate 32 'd' ++ "\n") ""))
                            (9, ["disk", "list", "--json"]) -> pure (Right (CapturedRun ExitSuccess ("{\"name\":\"colima-" ++ profileName ++ "\",\"dir\":\"" ++ diskDirectory ++ "\",\"instance\":\"colima-" ++ profileName ++ "\",\"instanceDir\":\"" ++ instanceDirectory ++ "\",\"format\":\"raw\",\"mountPoint\":\"\",\"size\":" ++ show (80 * gib) ++ "}\n") ""))
                            (10, ["context", "inspect", commandContext]) | commandContext == "colima-" ++ profileName -> pure (Right (CapturedRun ExitSuccess ("[{\"Name\":\"colima-" ++ profileName ++ "\"}]\n") ""))
                            (11, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess runningListing ""))
                            (12, ["ssh", "--profile", commandProfile, "--", "cat", "/etc/machine-id"]) | commandProfile == profileName -> pure (Right (CapturedRun ExitSuccess (replicate 32 'd' ++ "\n") ""))
                            (13, ["delete", "--profile", commandProfile, "--force", "--data"]) | commandProfile == profileName -> do
                                removePathForcibly (home </> "_lima")
                                pure (Right (CapturedRun ExitSuccess "" ""))
                            (14, ["list", "--json"]) -> pure (Right (CapturedRun ExitSuccess "" ""))
                            (15, ["context", "ls", "--format", "{{json .}}"]) ->
                                pure (Right (CapturedRun ExitSuccess ("{\"Name\":\"colima-" ++ profileName ++ "\"}\n") ""))
                            (16, ["context", "inspect", commandContext]) | commandContext == "colima-" ++ profileName -> pure (Right (CapturedRun ExitSuccess ("[{\"Name\":\"colima-" ++ profileName ++ "\"}]\n") ""))
                            (17, ["context", "rm", "--force", commandContext]) | commandContext == "colima-" ++ profileName -> do
                                removeFile (context </> "meta.json")
                                pure (Right (CapturedRun ExitSuccess "" ""))
                            (18, ["context", "ls", "--format", "{{json .}}"]) -> pure (Right (CapturedRun ExitSuccess "" ""))
                            _ -> pure (Left "unexpected one-entry acquisition command")
                let acquireOnce = acquireManagedColimaProfileWith oneEntryInterpret root profileName ownerToken
                        initialLineage acquireInvocation home context 8 (16 * gib) (80 * gib) (20 * gib) canonicalTypedStartArgs
                firstAcquisition <- newEmptyMVar
                secondAcquisition <- newEmptyMVar
                secondEntered <- newEmptyMVar
                concurrentOutcomes <-
                    bracket (forkFinally acquireOnce (putMVar firstAcquisition)) killThread $ \_ -> do
                        firstReady <- timeout 15000000 (takeMVar firstEntryCommand)
                        firstReady @?= Just ()
                        bracket (forkFinally (putMVar secondEntered () >> acquireOnce) (putMVar secondAcquisition)) killThread $ \_ -> do
                            takeMVar secondEntered
                            putMVar releaseFirstEntry ()
                            settledPair <- timeout 15000000 ((,) <$> takeMVar firstAcquisition <*> takeMVar secondAcquisition)
                            case settledPair of
                                Nothing -> assertFailure "concurrent Colima acquisitions did not settle within their bound"
                                Just (firstOutcome, secondOutcome) -> do
                                    firstResult <- OwnershipFixture.expectRight firstOutcome
                                    secondResult <- OwnershipFixture.expectRight secondOutcome
                                    pure [firstResult, secondResult]
                let appliedOutcomes = [outcome | outcome@(Right (ColimaManagedApplied _)) <- concurrentOutcomes]
                    exactOutcomes = [outcome | outcome@(Right (ColimaManagedAlreadyExact _)) <- concurrentOutcomes]
                    entryRefusals = [refusal | Left (ColimaMutationEntryRefused refusal) <- concurrentOutcomes]
                length appliedOutcomes @?= 1
                length exactOutcomes + length entryRefusals @?= 1
                readIORef oneEntryStarts >>= (@?= 1)
                acquired <- case appliedOutcomes of
                    [outcome] -> pure outcome
                    other -> assertFailure ("expected exactly one Applied acquisition, got " <> show other)
                case acquired of
                    Right (ColimaManagedApplied managedObservation) -> startedMachineIdentity (managedStartObservation managedObservation) @?= replicate 32 'd'
                    other -> assertFailure ("expected one-entry native Managed acquisition, got " ++ show other)
                repeated <- case exactOutcomes of
                    [outcome] -> pure outcome
                    [] -> acquireOnce
                    other -> assertFailure ("expected at most one exact concurrent acquisition, got " <> show other)
                case repeated of
                    Right (ColimaManagedAlreadyExact managedObservation) -> startedMachineIdentity (managedStartObservation managedObservation) @?= replicate 32 'd'
                    other -> assertFailure ("expected exact one-entry native acquisition, got " ++ show other)
                retained <-
                    withColimaOwnershipEntry root profileName $ \session keys -> do
                        stage <- readColimaStage session keys
                        manifest <- readProtectedRecord session (colimaManifestKey keys)
                        pure (Right (stage, manifest))
                fmap (\(stage, manifest) -> (fmap (fmap (colimaStageRecordStage . snd)) stage, fmap isJust manifest)) retained
                    @?= Right (Right (Just ColimaManaged), Right True)
                collision <- acquireManagedColimaProfileWith oneEntryInterpret root profileName ownerToken
                    collisionLineage acquireInvocation home context 8 (16 * gib) (80 * gib) (20 * gib) canonicalTypedStartArgs
                collision @?= Left (ColimaMutationProfileConflict "managed stage belongs to another lineage")
                afterCollision <- withColimaOwnershipEntry root profileName $ \session keys -> do
                    currentStage <- readColimaStage session keys
                    currentManifest <- readProtectedRecord session (colimaManifestKey keys)
                    pure (Right (currentStage, currentManifest))
                afterCollision @?= retained
                readIORef oneEntryScript >>= (@?= 11)
                ByteString.readFile diskPath >>= (@?= "owned disk")
                retainedHome <- withColimaOwnershipEntry root profileName
                    (\session keys -> readProtectedRecord session (colimaHomeKey keys))
                    >>= OwnershipFixture.expectRight
                    >>= maybe (assertFailure "the actual acquired home origin is absent") pure
                cleanupManagedColimaProfileWith oneEntryInterpret root profileName ownerToken initialLineage
                    acquireInvocation cleanupInvocation home context diskPath >>= (@?= Right ())
                let readCycleStage = withColimaOwnershipEntry root profileName
                        (\session keys -> Right <$> readColimaStage session keys)
                        >>= OwnershipFixture.expectRight >>= OwnershipFixture.expectRight
                        >>= maybe (assertFailure "the cycle stage is absent") pure
                    freshInvocation = replicate 64 'e'
                    reacquire invocation = acquireManagedColimaProfileWith oneEntryInterpret root profileName ownerToken
                        initialLineage invocation home context 8 (16 * gib) (80 * gib) (20 * gib) canonicalTypedStartArgs
                releasedCycle <- readCycleStage
                colimaStageRecordStage (snd releasedCycle) @?= ColimaReleased
                readIORef oneEntryScript >>= (@?= 19)
                cleanupManagedColimaProfileWith oneEntryInterpret root profileName ownerToken initialLineage
                    acquireInvocation cleanupInvocation home context diskPath >>= (@?= Right ())
                readIORef oneEntryScript >>= (@?= 19)
                replayed <- reacquire acquireInvocation
                replayed @?= Left (ColimaMutationProfileConflict "a released acquisition invocation cannot be replayed")
                readCycleStage >>= (@?= releasedCycle)
                doesPathExist home >>= (@?= False)
                doesPathExist context >>= (@?= False)
                readIORef oneEntryScript >>= (@?= 19)
                releasedDocker <- runManagedColimaDockerWith oneEntryInterpret root profileName ownerToken initialLineage
                    acquireInvocation home context ["version"]
                case releasedDocker of
                    Left (ColimaMutationProfileConflict _) -> pure ()
                    other -> assertFailure ("expected Released Docker route refusal, got " <> show other)
                readIORef oneEntryScript >>= (@?= 19)
                doesPathExist context >>= (@?= False)
                withColimaOwnershipEntry root profileName
                    (\session keys -> readProtectedRecord session (colimaContextKey keys))
                    >>= OwnershipFixture.expectRight >>= (@?= Nothing)
                createDirectory home
                ByteString.writeFile (home </> "foreign.txt") "foreign released namespace"
                foreignIdentity <- observedNamespaceIdentity home
                occupiedCycle <- reacquire freshInvocation
                case occupiedCycle of
                    Left (ColimaMutationOwnershipRefused (OwnershipOccupied _)) -> pure ()
                    other -> assertFailure ("expected retained Released namespace refusal, got " <> show other)
                foreignCleanup <- cleanupManagedColimaProfileWith oneEntryInterpret root profileName ownerToken
                    initialLineage acquireInvocation cleanupInvocation home context diskPath
                case foreignCleanup of
                    Left (ColimaMutationOwnershipRefused (OwnershipOccupied _)) -> pure ()
                    other -> assertFailure ("expected completed cleanup to preserve foreign roots, got " <> show other)
                observedNamespaceIdentity home >>= (@?= foreignIdentity)
                ByteString.readFile (home </> "foreign.txt") >>= (@?= "foreign released namespace")
                readCycleStage >>= (@?= releasedCycle)
                readIORef oneEntryScript >>= (@?= 19)
                removeFile (home </> "foreign.txt")
                removeDirectory home
                residualVersion <- withColimaOwnershipEntry root profileName
                    (\session keys -> compareAndSwapProtectedRecord session (colimaHomeKey keys) ExpectAbsent (protectedRecordBytes retainedHome))
                    >>= OwnershipFixture.expectRight
                residualCycle <- reacquire freshInvocation
                case residualCycle of
                    Left (ColimaMutationOwnershipRefused (OwnershipOccupied _)) -> pure ()
                    other -> assertFailure ("expected residual released-origin refusal, got " <> show other)
                residualCleanup <- cleanupManagedColimaProfileWith oneEntryInterpret root profileName ownerToken
                    initialLineage acquireInvocation cleanupInvocation home context diskPath
                case residualCleanup of
                    Left (ColimaMutationOwnershipRefused (OwnershipOccupied _)) -> pure ()
                    other -> assertFailure ("expected completed cleanup to preserve residual bindings, got " <> show other)
                readCycleStage >>= (@?= releasedCycle)
                readIORef oneEntryScript >>= (@?= 19)
                withColimaOwnershipEntry root profileName (\session keys ->
                    compareAndDeleteProtectedRecord session (colimaHomeKey keys) (ExpectVersion residualVersion))
                    >>= (@?= Right ())
                reacquired <- reacquire freshInvocation
                case reacquired of
                    Right (ColimaManagedApplied observation) ->
                        startedMachineIdentity (managedStartObservation observation) @?= replicate 32 'd'
                    other -> assertFailure ("expected fresh invocation to reacquire Released scope, got " <> show other)
                freshCycle <- readCycleStage
                colimaStageRecordStage (snd freshCycle) @?= ColimaManaged
                colimaStageRecordInvocation (snd freshCycle) @?= freshInvocation
                assertBool "new lineage advances the retained stage version"
                    (recordVersionWord (fst freshCycle) > recordVersionWord (fst releasedCycle))
                ByteString.readFile diskPath >>= (@?= "owned disk")
                readIORef oneEntryScript >>= (@?= 26)
                readIORef oneEntryStarts >>= (@?= 2)
                staleCleanup <- cleanupManagedColimaProfileWith oneEntryInterpret root profileName ownerToken
                    initialLineage acquireInvocation cleanupInvocation home context diskPath
                case staleCleanup of
                    Left (ColimaMutationProfileConflict _) -> pure ()
                    other -> assertFailure ("expected old cleanup to refuse the new acquisition, got " <> show other)
                readCycleStage >>= (@?= freshCycle)
                readIORef oneEntryScript >>= (@?= 26)
                receivedOneEntryCommands <- readIORef oneEntryCommands
                length receivedOneEntryCommands @?= 26
        , testCase "the shipped command transaction kills its group on hard parent death" $
            onOwnershipHost $
                withSystemTempDirectory "hostbootstrap-colima-shipped-death" $ \directory -> do
                    python <- requireExecutable "python3" =<< findExecutable "python3"
                    self <- getExecutablePath
                    let pidPath = directory </> "child.pid"
                    (_, _, _, ownerProcess) <-
                        createProcess (proc self ["--hostbootstrap-colima-shipped-owner-probe", directory, pidPath, python])
                    waitForPath pidPath
                    childPid <- strictReadFile pidPath
                    terminateProcess ownerProcess
                    _ <- waitForProcess ownerProcess
                    waitForPidGone python childPid
        , boundedShippedRunnerTests
        , testCase "production Colima resolution carries no test override" $ do
            current <- getCurrentDirectory
            root <- findRepoRoot current >>= maybe (assertFailure "could not find repository root") pure
            let package = root </> "core" </> "hostbootstrap-core"
                sourceRoots = [package </> "internal" </> "colima-backend", package </> "internal" </> "colima-ownership", package </> "src" </> "HostBootstrap" </> "Ensure"]
            for_ sourceRoots $ \sourceRoot -> do
                sources <- SourceGuard.readHaskellSources sourceRoot
                assertBool ("production source root is nonempty: " <> sourceRoot) (not (null sources))
                for_ sources $ \(path, source) ->
                    for_ ["ResolverOverride", "currentTrustedResolverOverrideHomeForTesting"] $ \forbidden ->
                        assertBool
                            (repoRelativePath root path <> " contains a resolver test branch: " <> forbidden)
                            (not (forbidden `isInfixOf` source))
        , testCase "removed Colima program and crash-point stand-ins stay absent" $ do
            current <- getCurrentDirectory
            root <- findRepoRoot current >>= maybe (assertFailure "could not find repository root") pure
            let backend = root </> "core" </> "hostbootstrap-core" </> "internal" </> "colima-backend" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Backend"
            doesDirectoryExist (backend </> "Program") >>= (@?= False)
            doesFileExist (backend </> "Resolver" </> "Program.hs") >>= (@?= False)
            doesFileExist (backend </> "Internal.hs") >>= (@?= False)
            sources <- readEveryTestFile (root </> "core" </> "hostbootstrap-core" </> "test")
            assertBool "the test source tree is nonempty" (not (null sources))
            for_ sources $ \(path, source) ->
                for_ [ "fake" ++ "Colima" ++ "Program"
                     , "fake" ++ "Docker" ++ "Program"
                     , "fake" ++ "Lima" ++ "Program"
                     , "Acquire" ++ "Backend" ++ "CrashPoint"
                     , "Cleanup" ++ "Backend" ++ "CrashPoint"
                     ] $ \forbidden ->
                    assertBool (repoRelativePath root path ++ " contains removed Colima stand-in: " ++ forbidden) (not (forbidden `isInfixOf` source))
        , testCase "the public exact consumer derives a fixed opaque provider profile" $ do
            result <-
                withPreparedTestCall $ \expectedProject call ->
                    (Text.unpack expectedProject, preparedColimaProfileName call)
            case result of
                Left failure -> assertFailure failure
                Right (project, profile) -> do
                    assertBool "the provider profile is not the caller-visible project name" (profile /= project)
                    assertBool "the provider profile is a fixed lowercase local label" (isPrefixOf "h-" profile && length profile == 8)
        , testCase "the shared default profile is outside the exact boundary" $
            assertBool
                "default must never become project authority"
                (not (validColimaProjectProfileName "default"))
        , -- A case whose subject this gate host may not have says which it did, in
          -- the run's own output. Returning @pure ()@ when the lane is not requested
          -- made a host that never touched Colima report the same green line as one
          -- that acquired a profile, refused a conflicting plan, and cleaned up --
          -- the silently-shrinking evidence § JJ's fifth rule exists to prevent.
          testGroup "direct-Colima live lane"
            [ conditionalCase ["ColimaSpec", "direct-Colima live lane"] colimaLiveAvailable
                "acquires, refuses conflict, and cleans up without activating default"
                runNativeColimaAcceptance
                reportColimaLiveUnavailable
            ]
        , testGroup
            "trusted resolver"
            [ testCase "the native fixture observer and strict facade settle one closed ready toolchain" $
                onOwnershipHost $
                    withResolverHarness "ready" $ \harness -> do
                        execution <- executeResolverFixture harness
                        (output, protocol) <- requireReadyResolver harness execution
                        repeated <- executeResolverFixture harness
                        (_, repeatedProtocol) <- requireReadyResolver harness repeated
                        repeatedProtocol @?= protocol
                        case protocol of
                            ResolverProtocolReadyV2View
                                (ResolverToolView colimaPath _ _)
                                (ResolverToolView dockerPath _ _)
                                (ResolverToolView limaPath _ _)
                                helperPath
                                _helperFingerprint -> do
                                    let layout = resolverHarnessLayout harness
                                    colimaPath @?= resolverFixtureColimaTarget layout
                                    dockerPath @?= resolverFixtureDockerTarget layout
                                    limaPath @?= resolverFixtureLimaTarget layout
                                    assertBool "the ready helper path is closed and nonempty" (not (null helperPath))
                                    case settleResolverFixtureExecutionView
                                        (resolverFixtureRoot layout)
                                        (resolverFixtureHome layout)
                                        (ResolverExecutionCompleted ExitSuccess output "") of
                                        ResolverSettlementReady settledColima settledDocker settledLima settledPath fingerprint -> do
                                            settledColima @?= colimaPath
                                            settledDocker @?= dockerPath
                                            settledLima @?= limaPath
                                            settledPath @?= helperPath
                                            nativeFingerprint <- nativeFixtureFingerprint harness
                                            fingerprint @?= nativeFingerprint
                                        other -> assertFailure ("expected ready resolver settlement, got " ++ show other)
                            other -> assertFailure ("expected ready resolver protocol, got " ++ show other)
            , testCase "native resolver remains ready without the fixture Python executable" $
                onOwnershipHost $
                    withResolverHarness "without-python" $ \harness -> do
                        before <- nativeFixtureFingerprint harness
                        let layout = resolverHarnessLayout harness
                        let pythonPath = resolverFixtureRoot layout </> "usr" </> "bin" </> "python3"
                        doesPathExist pythonPath >>= (@?= False)
                        execution <- executeResolverFixture harness
                        (wire, _) <- requireReadyResolver harness execution
                        assertBool "native wire has no Python candidate" (not (pythonPath `isInfixOf` wire))
                        nativeFixtureFingerprint harness >>= (@?= before)
            , testCase "native admission refuses when the kernel cannot open a descriptor" $
                onOwnershipHost $
                    withResolverHarness "descriptor-limit" $ \harness -> do
                        ready <- executeResolverFixture harness
                        _ <- requireReadyResolver harness ready
                        self <- getExecutablePath
                        let layout = resolverHarnessLayout harness
                        (code, out, err) <- readProcessWithExitCode self
                            ["--hostbootstrap-colima-resolver-fd-limit-probe", resolverFixtureRoot layout, resolverFixtureHome layout] ""
                        (code, out, err) @?= (ExitSuccess, "resolver-descriptor-refused\n", "")
            , testCase "the resolver rejects malformed, decorated, truncated, and cross-branch reports" $
                withResolverProtocolWires $ \layout output _missing -> do
                    let malformed =
                            [ ("resolver-protocol-framing", "")
                            , ("resolver-protocol-framing", init output)
                            , ("resolver-protocol-framing", "noise\n" ++ output)
                            , ("resolver-protocol-framing", output ++ "noise\n")
                            , ("resolver-protocol-framing", map (\character -> if character == '\n' then '\r' else character) output)
                            , ("resolver-protocol-shape", takeWhile (/= '\t') output ++ "\n")
                            , ("resolver-protocol-shape", "MISSING_COLIMA" ++ dropWhile (/= '\t') output)
                            , ("resolver-protocol-shape", init output ++ "\textra\n")
                            , ("resolver-protocol-framing", output ++ output)
                            , ("resolver-protocol-framing", output ++ "\n")
                            , ("resolver-protocol-framing", init output ++ "\r\n")
                            ]
                    mapM_ (\(reason, wire) -> assertResolverRejected (resolverFixtureRoot layout) reason wire) malformed
            , testCase "Python-free wire settles tools and rejects legacy reports" $
                withResolverProtocolWires $ \layout ready missing -> do
                    let settle wire = settleResolverFixtureExecutionView (resolverFixtureRoot layout)
                            (resolverFixtureHome layout) (ResolverExecutionCompleted ExitSuccess wire "")
                        fields = splitProtocolField '\t' (init ready)
                        legacy = intercalate "\t" (["READY", "/usr/bin/python3", "1", "2"] <> drop 1 fields) <> "\n"
                    assertBool "READY has no Python candidate" (not ("python3" `isInfixOf` ready))
                    parseResolverFixtureProtocolView (resolverFixtureRoot layout) legacy @?= Left "resolver-protocol-shape"
                    onOwnershipHost $ do
                        case settle ready of
                            ResolverSettlementReady{} -> pure ()
                            other -> assertFailure ("expected Python-free ready settlement, got " <> show other)
                        case settle missing of
                            ResolverSettlementMissingColima{} -> pure ()
                            other -> assertFailure ("expected Python-free missing settlement, got " <> show other)
                        settle legacy @?= ResolverSettlementUnsupported "resolver-protocol-shape"
                    let malformed = intercalate "\t" (replaceProtocolField 2 "0" fields) <> "\n"
                    parseResolverFixtureProtocolView (resolverFixtureRoot layout) malformed @?= Left "resolver-tool-identity"
            , protocolContentCases
            , resolverOwnerModeCases
            , resolverRevalidationTests
            , testCase "native settlement rejects a colon in the Colima helper directory" $
                onOwnershipHost $
                    withResolverHarness "native-content" $ \harness -> do
                        let layout = resolverHarnessLayout harness
                            target = resolverFixtureRoot layout </> "opt" </> "homebrew" </> "Cellar" </> "colima" </> "1:x" </> "bin" </> "colima"
                        createDirectoryIfMissing True (takeDirectory target)
                        writeResolverTool target
                        removeFile (resolverFixtureColimaAlias layout)
                        createRelativeFileLink target (resolverFixtureColimaAlias layout)
                        (execution, settled) <- executeNativeResolverFixtureView (resolverFixtureRoot layout) (resolverFixtureHome layout)
                        case execution of
                            ResolverExecutionCompleted ExitSuccess output "" -> takeWhile (/= '\t') output @?= "READY_V2"
                            other -> assertFailure ("expected the native fixture's ready observation, got " <> show other)
                        settled @?= ResolverSettlementUnsupported "resolver-helper-path"
            , testCase "missing Colima retains only the trusted bounded Brew install route" $
                onOwnershipHost $
                    withResolverHarness "missing" $ \harness -> do
                        let layout = resolverHarnessLayout harness
                        removeFile (resolverFixtureColimaAlias layout)
                        execution <- executeResolverFixture harness
                        case execution of
                            BoundedToolCompleted ExitSuccess output "" ->
                                case parseResolverFixtureProtocolView (resolverFixtureRoot layout) output of
                                    Right
                                        (ResolverProtocolMissingColimaV2View (ResolverToolView brewPath _ _) helperPath _helperFingerprint) -> do
                                            brewPath @?= resolverFixtureBrew layout
                                            assertBool "install helper path is closed" (not (null helperPath))
                                            executeResolverFixture harness >>= (@?= execution)
                                            settleResolverFixtureExecutionView
                                                (resolverFixtureRoot layout)
                                                (resolverFixtureHome layout)
                                                (ResolverExecutionCompleted ExitSuccess output "")
                                                @?= ResolverSettlementMissingColima brewPath helperPath
                                    other -> assertFailure ("expected missing-Colima report, got " ++ show other)
                            other -> assertFailure ("expected completed missing-Colima resolver, got " ++ show other)
            , testCase "the trusted install kernel revalidates, installs, and rediscovers in one closed order" $
                onOwnershipHost $
                    withResolverHarness "install" $ \harness -> do
                        let layout = resolverHarnessLayout harness
                        readyExecution <- executeResolverFixture harness
                        (readyOutput, _readyProtocol) <- requireReadyResolver harness readyExecution
                        expectedFingerprint <- nativeFixtureFingerprint harness
                        removeFile (resolverFixtureColimaAlias layout)
                        missingExecution <- executeResolverFixture harness
                        missingOutput <-
                            case missingExecution of
                                BoundedToolCompleted ExitSuccess output "" ->
                                    case parseResolverFixtureProtocolView (resolverFixtureRoot layout) output of
                                        Right ResolverProtocolMissingColimaV2View{} ->
                                            pure output
                                        other -> assertFailure ("expected a strict missing-Colima install input, got " ++ show other)
                                other -> assertFailure ("expected completed missing-Colima resolution, got " ++ show other)
                        createFileLink (resolverFixtureColimaTarget layout) (resolverFixtureColimaAlias layout)
                        let runScenario revalidation installExecution rediscoveryExecution =
                                runResolverInstallScenario
                                    (resolverFixtureRoot layout)
                                    (resolverFixtureHome layout)
                                    missingOutput
                                    revalidation
                                    installExecution
                                    rediscoveryExecution
                            completed = ResolverExecutionCompleted ExitSuccess "" ""
                        installed <-
                            runScenario
                                (Right ())
                                completed
                                (ResolverExecutionCompleted ExitSuccess readyOutput "")
                        case resolverInstallOutcome installed of
                            ResolverInstallReadyView fingerprint ->
                                fingerprint @?= expectedFingerprint
                            other -> assertFailure ("expected installed ready toolchain, got " ++ show other)
                        resolverInstallTrace installed @?= ["revalidate", "install", "rediscover"]
                        brewChanged <- runScenario (Left "brew-drift") completed ResolverExecutionTimedOut
                        brewChanged
                            @?= ResolverInstallScenarioView
                                (ResolverInstallBrewChangedView "brew-drift")
                                ["revalidate"]
                        exitFailed <-
                            runScenario
                                (Right ())
                                (ResolverExecutionCompleted (ExitFailure 9) "" "brew-error")
                                ResolverExecutionTimedOut
                        exitFailed
                            @?= ResolverInstallScenarioView
                                (ResolverInstallExitFailureView (ExitFailure 9) "brew-error")
                                ["revalidate", "install"]
                        timedOut <- runScenario (Right ()) ResolverExecutionTimedOut completed
                        timedOut
                            @?= ResolverInstallScenarioView
                                ResolverInstallTimedOutView
                                ["revalidate", "install"]
                        executionFailed <- runScenario (Right ()) (ResolverExecutionFailed "launch") completed
                        executionFailed
                            @?= ResolverInstallScenarioView
                                (ResolverInstallExecutionFailedView "launch")
                                ["revalidate", "install"]
                        stillMissing <-
                            runScenario
                                (Right ())
                                completed
                                (ResolverExecutionCompleted ExitSuccess missingOutput "")
                        stillMissing
                            @?= ResolverInstallScenarioView
                                ResolverInstallStillMissingView
                                ["revalidate", "install", "rediscover"]
                        unsupported <-
                            runScenario
                                (Right ())
                                completed
                                (ResolverExecutionCompleted ExitSuccess "UNSUPPORTED\trediscovery-layout\n" "")
                        unsupported
                            @?= ResolverInstallScenarioView
                                (ResolverInstallUnsupportedView "rediscovery-layout")
                                ["revalidate", "install", "rediscover"]
            , testCase "the fixed resolver refuses an effective home outside its admitted user root" $
                onOwnershipHost $
                    withResolverHarness "home-shape" $ \harness -> do
                        let outsideHome = resolverFixtureRoot (resolverHarnessLayout harness) </> "outside-home"
                        createDirectoryIfMissing True outsideHome
                        execution <- executeResolverFixtureAt harness outsideHome
                        requireUnsupportedResolver harness execution "home-shape"
            , testCase "fixed candidates ignore hostile ambient home, path, and working directory" $
                onOwnershipHost $
                    withResolverHarness "ambient" runHostileResolverFixture
            , testCase "formula, mode, Docker fallback, and helper-directory identity changes are explicit" $
                onOwnershipHost $ do
                    withResolverHarness "bad-formula" $ \harness -> do
                        let layout = resolverHarnessLayout harness
                        removeFile (resolverFixtureColimaAlias layout)
                        createFileLink (resolverFixtureBrew layout) (resolverFixtureColimaAlias layout)
                        execution <- executeResolverFixture harness
                        requireUnsupportedResolver harness execution "colima-formula-root"
                    withResolverHarness "bad-mode" $ \harness -> do
                        let layout = resolverHarnessLayout harness
                        chmodPath harness (resolverFixtureColimaTarget layout) "0777"
                        execution <- executeResolverFixture harness
                        requireUnsupportedResolver harness execution "executable-write-mode"
                    withResolverHarness "docker-app" $ \harness -> do
                        let layout = resolverHarnessLayout harness
                        removeFile (resolverFixtureDockerAlias layout)
                        execution <- executeResolverFixture harness
                        (_output, protocol) <- requireReadyResolver harness execution
                        case protocol of
                            ResolverProtocolReadyV2View _ (ResolverToolView dockerPath _ _) _ _ _ ->
                                dockerPath @?= resolverFixtureDockerApp layout
                            other -> assertFailure ("expected Docker Desktop fallback, got " ++ show other)
                    withResolverHarness "helper-drift" $ \harness -> do
                        firstExecution <- executeResolverFixture harness
                        (_firstOutput, firstProtocol) <- requireReadyResolver harness firstExecution
                        let layout = resolverHarnessLayout harness
                            helper = last (resolverFixtureSystemHelpers layout)
                            moved = helper ++ ".old"
                        renameDirectory helper moved
                        createDirectoryIfMissing True helper
                        secondExecution <- executeResolverFixture harness
                        (_secondOutput, secondProtocol) <- requireReadyResolver harness secondExecution
                        assertBool
                            "same-path helper-directory replacement changes the retained fingerprint"
                            (resolverFingerprint firstProtocol /= resolverFingerprint secondProtocol)
            , testCase "timeout, execution failure, stderr, and exit failure mint no facade" $
                onOwnershipHost $
                    withResolverHarness "settlement-errors" $ \harness -> do
                        execution <- executeResolverFixture harness
                        (output, _protocol) <- requireReadyResolver harness execution
                        let layout = resolverHarnessLayout harness
                            settle =
                                settleResolverFixtureExecutionView
                                    (resolverFixtureRoot layout)
                                    (resolverFixtureHome layout)
                        settle ResolverExecutionTimedOut @?= ResolverSettlementUnsupported "resolver-timeout"
                        settle (ResolverExecutionFailed "fixture") @?= ResolverSettlementUnsupported "resolver-execution-failed"
                        settle (ResolverExecutionCompleted ExitSuccess output "stderr") @?= ResolverSettlementUnsupported "resolver-stderr"
                        settle (ResolverExecutionCompleted (ExitFailure 7) output "") @?= ResolverSettlementUnsupported "resolver-exit-failure"
                        case settle (ResolverExecutionCompleted ExitSuccess output "") of
                            ResolverSettlementReady{} -> pure ()
                            other -> assertFailure ("expected Python-free settlement, got " <> show other)
            ]
        , testCase "released-record reuse observes absence and compare-and-swaps the exact stage" $ do
            current <- getCurrentDirectory
            root <- findRepoRoot current >>= maybe (assertFailure "could not find repository root") pure
            source <- strictReadFile (root </> "core" </> "hostbootstrap-core" </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
            acquisition <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "acquireManagedColimaProfileWith" source)
            vacant <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "observeVacantColimaNamespaces" source)
            let tokens = acquisition <> vacant
            for_ ["decideColimaStage", "BeginColimaLineage", "AcquireColima", "ColimaReleased",
                  "ColimaNamespaceAbsent", "releasedNamespaceObservation", "observeKernelOrigin",
                  "readProtectedRecord", "colimaStageRecordInvocation", "colimaHomeKey",
                  "colimaContextKey", "colimaCacheKey", "colimaTemporaryKey", "colimaProfileKey",
                  "colimaDiskKey", "colimaManifestKey"] $ \name ->
                assertBool ("the actual released-record consumer retains " <> name) (elem name tokens)
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "writeColimaStage session keys (ExpectVersion version) reserved")
                source @?= 1
            observed <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "observeKernelOrigin" source)
            for_ ["enterOwnedObject", "enteredEvidence"] $ \name ->
                assertBool ("namespace absence uses the live kernel through " <> name) (elem name observed)
            assertBool "observing release completion never acquires an origin" (notElem "recordOwnedOrigin" observed)
        , testCase "acquisition preparation start and settlement consume the stage table" $ do
            current <- getCurrentDirectory
            root <- findRepoRoot current >>= maybe (assertFailure "could not find repository root") pure
            source <- strictReadFile (root </> "core" </> "hostbootstrap-core" </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
            prepare <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "prepareColimaNamespacesInside" source)
            for_ ["decideColimaStage", "AdvanceColimaStage", "KeepColimaStage", "observeKernelOrigin",
                  "observeVacantColimaNamespaces", "readRetainedColimaDirectoryIdentity", "ExpectVersion"] $ \name ->
                assertBool ("namespace preparation consumes " <> name) (elem name prepare)
            start <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "startPreparedColimaProfileInside" source)
            for_ ["decideColimaStage", "ColimaProfileAbsent", "ColimaProfileExact", "StartColimaProfile",
                  "readRetainedColimaDirectoryIdentity"] $ \name ->
                assertBool ("the actual Prepared start consumes " <> name) (elem name start)
            for_ ["ensureColimaDirectory", "ensureAuxiliaryDirectories", "creationRecordsPresent"] $ \name ->
                assertBool ("Prepared start cannot reconstruct or adopt through " <> name) (notElem name start)
            acquisition <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "acquireManagedColimaProfileWith" source)
            assertBool "exact Managed re-entry consumes KeepColimaStage" (elem "KeepColimaStage" acquisition)
            stageSource <- strictReadFile (root </> "core" </> "hostbootstrap-core" </> "internal" </> "colima-backend" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Backend" </> "Stage.hs")
            settlement <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "settleColimaStageRecord" stageSource)
            for_ ["decideColimaStage", "ColimaCreatedProfileExact", "AdvanceColimaStage"] $ \name ->
                assertBool ("evidence-bearing settlement consumes " <> name) (elem name settlement)
        , testCase "provider-start capabilities have one private base-only declaration home" $
            SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                let moduleName = "HostBootstrap.Reconcile.ProviderStart.Internal"
                    oldHome = packageRoot </> "src" </> "HostBootstrap" </> "Reconcile" </> "ProviderStart" </> "Internal.hs"
                    privateHome = packageRoot </> "internal" </> "provider-start" </> "HostBootstrap" </> "Reconcile" </> "ProviderStart" </> "Internal.hs"
                description <- strictReadFile (packageRoot </> "hostbootstrap-core.cabal")
                source <- strictReadFile privateHome
                exposed <- OwnershipFixture.expectRight (SourceGuard.effectiveMainExposedModules description)
                assertBool "the capability declaration owner is not public" (moduleName `notElem` exposed)
                private <- maybe (assertFailure "the provider-start leaf is absent") pure
                    (SourceGuard.namedStanza "library provider-start-internal" description)
                SourceGuard.fieldValues "visibility" private @?= ["private"]
                SourceGuard.fieldValues "hs-source-dirs" private @?= ["internal/provider-start"]
                SourceGuard.fieldModules "exposed-modules" private @?= [moduleName]
                SourceGuard.fieldValues "build-depends" private @?= ["base", ">=4.18", "&&", "<5"]
                expected <- maybe (assertFailure "the provider-start export pin is absent") pure
                    (lookup moduleName pinnedPrivateExportLists)
                SourceGuard.moduleExportTokens moduleName source @?= Just (SourceGuard.haskellTokens expected)
                for_ ["ProviderStartBackendResult", "ProviderStartProjectionAuthority", "FreshManagedPhaseAuthority"] $ \name ->
                    SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens ("data " <> name)) source @?= 1
                doesFileExist oldHome >>= (@?= False)
                doesFileExist privateHome >>= (@?= True)
                public <- maybe (assertFailure "the main library is absent") pure
                    (SourceGuard.mainLibraryStanza description)
                assertBool "the generic lifecycle uses the private declaration leaf"
                    ("hostbootstrap-core:provider-start-internal" `elem` SourceGuard.fieldValues "build-depends" public)
        , testCase "shared reconciler refusals have one private leaf declaration home" $
            SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                description <- strictReadFile (packageRoot </> "hostbootstrap-core.cabal")
                public <- strictReadFile (packageRoot </> "src" </> "HostBootstrap" </> "Reconcile.hs")
                vocabulary <- strictReadFile (packageRoot </> "internal" </> "reconcile-error" </> "HostBootstrap" </> "Reconcile" </> "Error.hs")
                let vocabularyModule = "HostBootstrap.Reconcile.Error"
                exposed <- OwnershipFixture.expectRight (SourceGuard.effectiveMainExposedModules description)
                assertBool "the declaration module is not a public module" (notElem vocabularyModule exposed)
                private <- maybe (assertFailure "the private refusal vocabulary library is absent") pure
                    (SourceGuard.namedStanza "library reconcile-error-internal" description)
                SourceGuard.fieldModules "exposed-modules" private @?= [vocabularyModule]
                SourceGuard.fieldValues "visibility" private @?= ["private"]
                expected <- maybe (assertFailure "the refusal vocabulary export pin is absent") pure
                    (lookup vocabularyModule pinnedPrivateExportLists)
                SourceGuard.moduleExportTokens vocabularyModule vocabulary @?= Just (SourceGuard.haskellTokens expected)
                for_ ["ReconcileError", "ConflictDetail", "SafetyDetail", "UnsupportedDetail", "FailureDetail", "RecoveryDisposition"] $ \name -> do
                    SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens ("data " <> name)) public @?= 0
                    SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens ("data " <> name)) vocabulary @?= 1
                assertBool "public consumers import the leaf declaration owner"
                    (SourceGuard.countHaskellTokenSequence (SourceGuard.haskellTokens "import HostBootstrap.Reconcile.Error") public == 1)
                for_ ["HostBootstrap.Effect", "HostBootstrap.ProjectPlan", "HostBootstrap.Ownership", "HostBootstrap.Lifecycle"] $ \name ->
                    assertBool ("the leaf vocabulary cannot depend on " <> name) (not (name `isInfixOf` vocabulary))
                SourceGuard.fieldValues "build-depends" private @?= ["base", ">=4.18", "&&", "<5", "text"]
        , testCase "cleanup deletion settlement and replay consume the stage table" $ do
            current <- getCurrentDirectory
            root <- findRepoRoot current >>= maybe (assertFailure "could not find repository root") pure
            source <- strictReadFile (root </> "core" </> "hostbootstrap-core" </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
            cleanup <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "cleanupManagedColimaProfileWith" source)
            released <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "releaseColimaReleasedNamespaces" source)
            assertBool "cleanup delegates fresh and replayed Released settlement" ("releaseColimaReleasedNamespaces" `elem` cleanup)
            let tokens = cleanup <> released
            for_ ["decideColimaStage", "ReleaseColima", "freezeAndChooseDelete", "DeleteColimaProfile",
                  "advanceRelease", "ColimaContextReleased", "ColimaReleased", "releaseColimaReleasedNamespaces",
                  "ReleaseColimaNamespace", "ColimaReleasedNamespaceExact", "replayCompletedRelease",
                  "observeVacantColimaNamespaces", "KeepColimaStage", "readRetainedColimaDirectoryIdentity",
                  "classifyColimaCleanupProfile", "admitColimaCleanupMachine", "colimaCleanupDeleteResult",
                  "releaseVersion", "ExpectVersion"] $ \name ->
                assertBool ("the actual cleanup consumes " <> name) (elem name tokens)
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "case before >>= classifyColimaCleanupProfile profile heldRecord of") source @?= 1
            profile <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "classifyColimaCleanupProfile" source)
            for_ ["managedCpu", "managedMemoryBytes", "managedDiskBytes"] $ \name ->
                assertBool ("the actual profile decision retains " <> name) (name `elem` profile)
            machine <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "admitColimaCleanupMachine" source)
            for_ ["managedMachineIdentity", "managedMachineEpoch", "parseObjectIdentityHex"] $ \name ->
                assertBool ("the actual machine decision retains " <> name) (name `elem` machine)
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "choice <- freezeAndChooseDelete session keys heldVersion heldRecord ColimaProfileExact") source @?= 1
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "case advanceRelease releasingRecord observation ColimaContextReleased of") source @?= 1
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "case advanceRelease contextReleased ColimaNamespaceAbsent ColimaReleased of") source @?= 1
        , testCase "the durable Colima stage graph admits only idempotence and one successor" $ do
            let stages = [minBound .. maxBound] :: [ColimaStage]
            mapM_ (\stage -> parseColimaStage (renderColimaStage stage) @?= Right stage) stages
            for_ stages $ \current -> for_ stages $ \observed -> do
                let allowed = observed == current || (current, observed) `elem` zip stages (drop 1 stages)
                advanceColimaStage current observed @?= if allowed then Right observed else Left "stage-transition"
            let decisions =
                    [ (AcquireColima, ColimaReserved, ColimaNamespaceAbsent, AdvanceColimaStage ColimaHomeStaged)
                    , (AcquireColima, ColimaReserved, ColimaHomeStageExact, AdvanceColimaStage ColimaHomeStaged)
                    , (AcquireColima, ColimaHomeStaged, ColimaHomeStageExact, AdvanceColimaStage ColimaHomeReady)
                    , (AcquireColima, ColimaHomeReady, ColimaHomeExact, AdvanceColimaStage ColimaContextStaged)
                    , (AcquireColima, ColimaContextStaged, ColimaContextStageExact, AdvanceColimaStage ColimaPrepared)
                    , (AcquireColima, ColimaPrepared, ColimaContextStageExact, KeepColimaStage)
                    , (AcquireColima, ColimaPrepared, ColimaProfileAbsent, StartColimaProfile)
                    , (AcquireColima, ColimaPrepared, ColimaProfileExact, KeepColimaStage)
                    , (AcquireColima, ColimaPrepared, ColimaCreatedProfileExact, AdvanceColimaStage ColimaManaged)
                    , (AcquireColima, ColimaManaged, ColimaProfileExact, KeepColimaStage)
                    , (AcquireColima, ColimaReleased, ColimaNamespaceAbsent, BeginColimaLineage)
                    , (ReleaseColima, ColimaManaged, ColimaProfileExact, AdvanceColimaStage ColimaReleasing)
                    , (ReleaseColima, ColimaReleasing, ColimaProfileExact, DeleteColimaProfile)
                    , (ReleaseColima, ColimaReleasing, ColimaProfileAbsent, AdvanceColimaStage ColimaContextReleased)
                    , (ReleaseColima, ColimaContextReleased, ColimaNamespaceAbsent, AdvanceColimaStage ColimaReleased)
                    , (ReleaseColima, ColimaContextReleased, ColimaReleasedNamespaceExact, ReleaseColimaNamespace)
                    , (ReleaseColima, ColimaReleased, ColimaReleasedNamespaceExact, ReleaseColimaNamespace)
                    , (ReleaseColima, ColimaReleased, ColimaNamespaceAbsent, KeepColimaStage)
                    ]
            mapM_
                (\(intent, stage, observation, decision) -> decideColimaStage intent stage observation @?= Right decision)
                decisions
            let admitted = [(intent, stage, observation) | (intent, stage, observation, _) <- decisions]
                allInputs =
                    [ (intent, stage, observation)
                    | intent <- [AcquireColima, ReleaseColima]
                    , stage <- stages
                    , observation <- [minBound .. maxBound]
                    ]
            mapM_
                ( \input@(intent, stage, observation) ->
                    unless (input `elem` admitted) (decideColimaStage intent stage observation @?= Left "stage-observation")
                )
                allInputs
            for_ ["owner-\x100", "owner-\xe9", "owner with space"] $ \invalidOwner ->
                mkColimaStageRecord ColimaPrepared invalidOwner (replicate 64 'c') acquireInvocation @?= Left "stage-owner"
            for_ ["owner-\xe9", "owner with space"] $ \invalidOwner ->
                parseColimaStageRecord (ByteStringChar8.pack (unlines
                    [ "colima-stage-v1", "stage " <> renderColimaStage ColimaPrepared
                    , "owner " <> invalidOwner, "lineage " <> replicate 64 'c'
                    , "invocation " <> acquireInvocation
                    ])) @?= Left "stage-owner"
            let stageRecord = mkColimaStageRecord ColimaPrepared ownerToken (replicate 64 'c') acquireInvocation
            fmap (parseColimaStageRecord . renderColimaStageRecord) stageRecord @?= fmap Right stageRecord
            fmap colimaStageRecordStage stageRecord @?= Right ColimaPrepared
            (stageRecord >>= parseColimaStageRecord . ByteString.init . renderColimaStageRecord)
                @?= Left "stage-record"
            let evidence = mkColimaManagedEvidence (replicate 32 'd') 42 (replicate 64 'e') (replicate 64 'f') (replicate 64 'a') 8 (16 * gib) (80 * gib) (20 * gib)
                managed = stageRecord >>= \record -> evidence >>= settleColimaStageRecord record
            fmap (parseColimaStageRecord . renderColimaStageRecord) managed @?= fmap Right managed
            fmap colimaStageRecordStage managed @?= Right ColimaManaged
            let releasing = managed >>= (`beginColimaReleaseRecord` cleanupInvocation)
            fmap (parseColimaStageRecord . renderColimaStageRecord) releasing @?= fmap Right releasing
            fmap colimaStageRecordStage releasing
                @?= Right ColimaReleasing
            fmap colimaStageRecordStage (releasing >>= (`advanceSettledColimaStageRecord` ColimaContextReleased))
                @?= Right ColimaContextReleased
            mkColimaStageRecord ColimaManaged ownerToken (replicate 64 'c') acquireInvocation
                @?= Left "stage-evidence"
            parseColimaStage "unknown" @?= Left "record-state"
        , testCase "raw Colima JSONL remains plan-independent observation data" $
            classifyColimaListing
                ( CapturedRun ExitSuccess
                    ( unlines
                        [ "{\"name\":\"demo\",\"status\":\"Running\",\"cpus\":8,\"memory\":17179869184,\"disk\":107374182400,\"runtime\":\"docker\"}"
                        , "{\"name\":\"other\",\"status\":\"Stopped\",\"cpus\":2,\"memory\":2147483648,\"disk\":107374182400,\"runtime\":\"incus\"}"
                        ]
                    )
                    ""
                )
                @?= Right
                    [ ColimaInstance "demo" "Running" 8 (16 * gib) (100 * gib) "docker"
                    , ColimaInstance "other" "Stopped" 2 (2 * gib) (100 * gib) "incus"
                    ]
        , testGroup "acquisition mutation refusal classification"
            [ testCase label $
                colimaMutationAcquireObservation expected fault @?= result
            | let expected = "runtime=docker cpu=8 memory=17179869184 disk=85899345920 root-disk=21474836480"
            , (label, fault, result) <-
                let refused fault = WallRefused
                        (ConflictDetail "reconcile Colima provider wall" expected (Text.pack (show fault))
                            "leave the conflicting profile untouched and resolve its owner or sizing explicitly")
                    failed fault = WallAcquireFailed
                        (FailureDetail "acquire Colima provider wall" (Text.pack (show fault)) ReprobeBeforeRetry)
                    profile = ColimaMutationProfileConflict "same name has another owner"
                    ownership = ColimaMutationOwnershipRefused (OwnershipMalformed "origin mismatch")
                 in [ ("a profile conflict is refused", profile, refused profile)
                    , ("an ownership-origin mismatch is refused", ownership, refused ownership)
                    , ("an entry refusal needs a fresh probe", ColimaMutationEntryRefused "busy", failed (ColimaMutationEntryRefused "busy"))
                    , ("a start failure needs a fresh probe", ColimaMutationStartFailed, failed ColimaMutationStartFailed)
                    , ("a refused report needs a fresh probe", ColimaMutationReportRefused ColimaReportDecode, failed (ColimaMutationReportRefused ColimaReportDecode))
                    , ("an unavailable command needs a fresh probe", ColimaMutationCommandUnavailable "missing", failed (ColimaMutationCommandUnavailable "missing"))
                    , ("a delete failure needs a fresh probe", ColimaMutationDeleteFailed, failed ColimaMutationDeleteFailed)
                    ]
            ]
        , testCase "the public acquisition adapter consumes the private refusal classification" $
            SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
                source <- strictReadFile (packageRoot </> "src" </> "HostBootstrap" </> "Ensure" </> "Colima.hs")
                tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "acquireObservation" source)
                for_ ["colimaMutationAcquireObservation", "renderExpected"] $ \name ->
                    assertBool ("acquisition consumes " <> name) (name `elem` tokens)
                for_ ["WallRefused", "WallAcquireFailed", "ColimaMutationProfileConflict", "ColimaMutationOwnershipRefused"] $ \name ->
                    assertBool ("the adapter contains no second refusal decision: " <> name) (name `notElem` tokens)
                for_ ["classifyColimaWall", "ColimaWallDecision", "matchesExpected", "wallConflict"] $ \name ->
                    SourceGuard.countHaskellIdentifier name source @?= 0
        ]


-- Descriptive binding inputs and a projection through the actual generic start kernel.
-- No production resolver, journal or authority constructor is supplied by this fixture.
data TestColimaEnvelope = TestColimaEnvelope
    { testEnvelopeRoot :: FilePath
    , testEnvelopeNamespaceKey :: String
    , testEnvelopeOwnerSeed :: String
    , testEnvelopeRecordPath :: FilePath
    , testEnvelopeCallDigest :: Text.Text
    , testEnvelopeInvocation :: String
    , testEnvelopeCompleteStart :: ColimaWallSettlementObservation -> Either Reconcile.ReconcileError (Word64, Reconcile.ChangeView)
    }

data StaticOwnedScenario = OwnedApplied | OwnedExact | OwnedCleanupAuthority | OwnedCleanupPrepared | OwnedCleanupWrongFence | WrongSession | WrongAttempt | WrongVersion
    | WrongRoot | WrongNamespace | WrongRecord | WrongDockerConfig | WrongOwner

testColimaInvocation :: Text.Text -> PreparedGate -> String
testColimaInvocation digest gate =
    ColimaIdentity.colimaInvocationDigest digest (preparedGatePlan gate) (preparedGateOperation gate)
        (preparedGateSession gate) (preparedGateFence gate) (preparedGateAttempt gate) (preparedGateJournalVersion gate)







directoryReleaseRefusal :: Maybe OwnershipFault
directoryReleaseRefusal = withOwnershipRow ownershipRowForHost $ \row ->
    case clauseRefusal (rowCapabilities row) ClauseRelease of
        Just fault -> Just fault
        Nothing -> clauseRefusal (rowCapabilities row) ClauseRecord

directoryReleaseSupported :: Bool
directoryReleaseSupported = case directoryReleaseRefusal of
    Nothing -> True
    Just _ -> False

withNativeDirectoryRelease :: (forall session. ProtectedSession session -> ColimaOwnershipKeys -> FilePath -> IO ()) -> IO ()
withNativeDirectoryRelease consume = withSystemTempDirectory "hostbootstrap-directory-release" $ \root -> do
    outcome <- withColimaOwnershipEntry root profileName $ \session keys -> do
        consume session keys (root </> "owned")
        pure (Right ())
    outcome @?= Right ()

assertDirectoryReleaseUnsupported :: IO ()
assertDirectoryReleaseUnsupported = withNativeDirectoryRelease $ \session keys target ->
    case directoryReleaseRefusal of
        Nothing -> assertFailure "the native row declares directory release support"
        Just fault -> releaseColimaDirectory session (colimaHomeKey keys) target >>= (@?= Left fault)

exactCleanupCompletionCases :: TestTree
exactCleanupCompletionCases = testGroup "exact cleanup completion"
    [ testCase "committed release with unchanged standing completes" $
        colimaCleanupCompletion (Right () :: Either Reconcile.ReconcileError ()) (Right () :: Either Reconcile.ReconcileError ())
            @?= Right Nothing
    , testCase "committed release retains its post-call standing failure" $
        colimaCleanupCompletion (Right () :: Either Reconcile.ReconcileError ()) (Left postFault) @?= Right (Just postFault)
    , testCase "failed release never completes when standing is unchanged" $
        colimaCleanupCompletion (Left driverFault) (Right () :: Either Reconcile.ReconcileError ()) @?= Left driverFault
    , testCase "failed release retains its own failure when standing also fails" $
        colimaCleanupCompletion (Left driverFault) (Left postFault) @?= Left driverFault
    , testCase "unsupported discovery remains a typed refusal under either policy" $
        for_ [ColimaMayInstall, ColimaMustExist] $ \policy ->
            case colimaResolutionChoice policy (Resolver.TrustedResolverUnsupported "native resolver refusal") of
                Left fault -> fault @?= Reconcile.Unsupported (Reconcile.UnsupportedDetail "resolve direct-Colima toolchain" "native resolver refusal")
                Right _ -> assertFailure "unsupported discovery selected a toolchain"
    , testCase "the actual adapter completes committed cleanup and prohibits cleanup installation" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            adapter <- strictReadFile (packageRoot </> "src" </> "HostBootstrap" </> "Ensure" </> "Colima.hs")
            cleanup <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "runColimaCleanup" adapter)
            for_ ["ColimaMustExist", "discoverDirectColimaBackendAt", "backendMatchesOwned", "cleanupManagedColimaProfileWith", "revalidateOwnershipBackend", "colimaCleanupCompletion", "completePreparedPhaseTransition", "resourceHandleGeneration"] $ \name ->
                assertBool ("cleanup retains " <> name) (name `elem` cleanup)
            assertBool "the driver decision precedes exact typed completion and retains diagnostics"
                (SourceGuard.haskellTokens "diagnostic <- colimaCleanupCompletion result postCall advance <- completePreparedPhaseTransition preparedTransition (resourceHandleGeneration handle) Right (advance, diagnostic)" `isInfixOf` cleanup)
            acquisition <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "discoverDirectColimaBackend" adapter)
            assertBool "acquisition explicitly selects its install policy" ("ColimaMayInstall" `elem` acquisition)
            settlement <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "settleTrustedResolution" adapter)
            for_ ["colimaResolutionChoice", "ColimaUseResolved", "ColimaInstallResolved", "installAndRediscover", "ownershipBackendFromToolchain"] $ \name ->
                assertBool ("actual discovery delegates through " <> name) (name `elem` settlement)
            docker <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "runLiveColimaDocker" adapter)
            assertBool "Docker revalidates its actual retained toolchain" ("revalidateTrustedAppleToolchain" `elem` docker)
            for_ ["discoverDirectColimaBackendAt", "installAndRediscover", "runTrustedInstallRediscovery"] $ \name ->
                assertBool ("a live Docker route cannot install through " <> name) (name `notElem` docker)
    ]
  where
    driverFault = Failure (FailureDetail "release Colima profile" "delete refused before commit" ReprobeBeforeRetry)
    postFault = Failure (FailureDetail "revalidate Colima toolchain" "identity changed after commit" DoNotRetry)

nativeResolverInstallPolicyCases :: TestTree
nativeResolverInstallPolicyCases = testGroup "native resolver install policy"
    [ native "actual ready evidence remains the same under both policies" $
        withResolverHarness "policy-ready" $ \harness -> do
            let layout = resolverHarnessLayout harness
            (_, result) <- executeNativeResolverFixtureWithSettlement (resolverFixtureRoot layout) (resolverFixtureHome layout)
            for_ [ColimaMayInstall, ColimaMustExist] $ \policy ->
                case colimaResolutionChoice policy result of
                    Right (ColimaUseResolved toolchain) -> do
                        Resolver.trustedAppleColimaPath toolchain @?= resolverFixtureColimaTarget layout
                        Resolver.trustedAppleDockerPath toolchain @?= resolverFixtureDockerTarget layout
                    _ -> assertFailure "actual ready evidence did not retain its route"
    , native "actual missing evidence installs only under acquisition policy" $
        withResolverHarness "policy-missing" $ \harness -> do
            let layout = resolverHarnessLayout harness
            removeFile (resolverFixtureColimaAlias layout)
            (_, result) <- executeNativeResolverFixtureWithSettlement (resolverFixtureRoot layout) (resolverFixtureHome layout)
            case colimaResolutionChoice ColimaMayInstall result of
                Right (ColimaInstallResolved brew) -> Resolver.trustedAppleBrewPath brew @?= resolverFixtureBrew layout
                _ -> assertFailure "actual missing evidence did not choose acquisition installation"
            case colimaResolutionChoice ColimaMustExist result of
                Left fault -> fault @?= Failure (FailureDetail "resolve direct-Colima toolchain" "Colima is missing and this operation cannot install it" ReprobeBeforeRetry)
                Right _ -> assertFailure "cleanup admitted a missing Colima installation"
    ]
  where
    native name action = conditionalCase ["ColimaSpec", "native resolver install policy"] posixOwnershipSupported
        name action assertNativeFixtureUnsupported

data ReleasedNamespaceScenario = ReleasedAllPresent | ReleasedTemporaryRemoved | ReleasedTemporarySettled
    | ReleasedChildrenSettled | ReleasedHomeRemoved | ReleasedRootsSettled | ReleasedReplay
    | ReleasedHomeReplaced | ReleasedCacheReplaced | ReleasedAdded | ReleasedMetadataReplaced
    | ReleasedStageChanged | ReleasedManifestMissing | ReleasedParentRemoved | ReleasedParentShared | ReleasedParentReplaced

nativeReleasedNamespaceCases :: TestTree
nativeReleasedNamespaceCases = testGroup "native Released namespace recovery"
    [ native "owned cache, temporary data and scaffolding settle" ReleasedAllPresent
    , native "removed temporary root settles its origin" ReleasedTemporaryRemoved
    , native "settled temporary root remains absent" ReleasedTemporarySettled
    , native "settled child roots retain only home work" ReleasedChildrenSettled
    , native "removed home settles its retained origin" ReleasedHomeRemoved
    , native "settled roots still settle the retained manifest" ReleasedRootsSettled
    , native "completed replay returns success without recreation" ReleasedReplay
    , native "a replacement home preserves both roots and records" ReleasedHomeReplaced
    , native "a replacement cache refuses before namespace deletion" ReleasedCacheReplaced
    , native "new entries and scaffolding remain foreign" ReleasedAdded
    , native "replaced cache metadata keeps both files" ReleasedMetadataReplaced
    , native "a changed held stage refuses before namespace effects" ReleasedStageChanged
    , native "missing manifest grants no remaining root deletion" ReleasedManifestMissing
    , native "a removed parent settles its retained origin" ReleasedParentRemoved
    , native "a shared nonempty parent and origin remain" ReleasedParentShared
    , native "a replacement parent preserves both parents and its origin" ReleasedParentReplaced
    ]
  where
    native name scenario = conditionalCase ["ColimaSpec", "native Released namespace recovery"] contextNamespaceSupported
        name (runNativeReleasedNamespace scenario) unsupported
    unsupported
        | posixOwnershipSupported = assertDirectoryReleaseUnsupported
        | otherwise = withSystemTempDirectory "hostbootstrap-released-manifest-unsupported" $ \root ->
            ManifestRow.observeOwnershipManifestForHost True root
                >>= (@?= Left (OwnershipUnsupported "the direct-Colima manifest row is unavailable on Windows"))

runNativeReleasedNamespace :: ReleasedNamespaceScenario -> IO ()
runNativeReleasedNamespace scenario = withSystemTempDirectory "hostbootstrap-released-namespace" $ \root -> do
    let home = root </> "home"
        parent = root </> "contexts"
        context = parent </> "profile"
        cache = home </> "cache"
        temporary = home </> "tmp"
    prepareColimaNamespaces root profileName ownerToken (replicate 64 'c') acquireInvocation home context >>= (@?= Right ())
    case scenario of
        ReleasedAllPresent -> do
            ByteString.writeFile (cache </> "data") "owned cache\n"
            ByteString.writeFile (temporary </> "data") "owned temporary\n"
            createDirectoryIfMissing True (home </> "_lima" </> "_disks")
            createDirectory (home </> "_store")
        ReleasedMetadataReplaced -> ByteString.writeFile (cache </> "data") "retained cache\n"
        _ -> pure ()
    outcome <- withColimaOwnershipEntry root profileName $ \session keys -> do
        homeManifest <- posixObserveOwnershipManifest True home >>= OwnershipFixture.expectRight
        contextManifest <- posixObserveOwnershipManifest False context >>= OwnershipFixture.expectRight
        firstManifest <- OwnershipFixture.expectRight (Manifest.prefixOwnershipManifest "colima" homeManifest)
        secondManifest <- OwnershipFixture.expectRight (Manifest.prefixOwnershipManifest "docker" contextManifest)
        manifest <- OwnershipFixture.expectRight (Manifest.mergeOwnershipManifests [firstManifest, secondManifest])
        manifestVersion <- compareAndSwapProtectedRecord session (colimaManifestKey keys) ExpectAbsent (renderOwnershipManifest manifest) >>= OwnershipFixture.expectRight
        preparedStage <- readColimaStage session keys >>= OwnershipFixture.expectRight
        (preparedVersion, prepared) <- maybe (assertFailure "the prepared stage is absent") pure preparedStage
        evidence <- OwnershipFixture.expectRight $ mkColimaManagedEvidence (replicate 32 'd') 73 (replicate 64 'e')
            (ownershipManifestDigest manifest) (Manifest.ownershipDirectoryChainDigest manifest) 8 (16 * gib) (80 * gib) (20 * gib)
        managed <- OwnershipFixture.expectRight (settleColimaStageRecord prepared evidence)
        releasing <- OwnershipFixture.expectRight (beginColimaReleaseRecord managed cleanupInvocation)
        contextReleased <- OwnershipFixture.expectRight (advanceSettledColimaStageRecord releasing ColimaContextReleased)
        record <- OwnershipFixture.expectRight (advanceSettledColimaStageRecord contextReleased ColimaReleased)
        version <- writeColimaStage session keys (ExpectVersion preparedVersion) record >>= OwnershipFixture.expectRight
        releaseColimaDirectory session (colimaContextKey keys) context >>= (@?= Right ())
        let artifactKeys = [colimaHomeKey keys, colimaCacheKey keys, colimaTemporaryKey keys, colimaContextKey keys, colimaProfileKey keys, colimaDiskKey keys, colimaManifestKey keys]
            childRoots = [(colimaTemporaryKey keys, temporary), (colimaCacheKey keys, cache)]
            settleChildren = for_ childRoots $ \(key, target) -> releaseColimaDirectory session key target >>= (@?= Right ())
        initialKeys <- listProtectedRecords session >>= OwnershipFixture.expectRight
        let parentKeys = filter (`notElem` (colimaStageKey keys : artifactKeys)) initialKeys
        length parentKeys @?= 1
        parentBefore <- traverse (readProtectedRecord session) parentKeys
        case scenario of
            ReleasedTemporaryRemoved -> removeDirectory temporary
            ReleasedTemporarySettled -> releaseColimaDirectory session (colimaTemporaryKey keys) temporary >>= (@?= Right ())
            ReleasedChildrenSettled -> settleChildren
            ReleasedHomeRemoved -> settleChildren >> removeDirectory home
            ReleasedRootsSettled -> settleChildren >> (releaseColimaDirectory session (colimaHomeKey keys) home >>= (@?= Right ()))
            ReleasedHomeReplaced -> renameDirectory home (home ++ "-retained") >> createDirectory home
            ReleasedCacheReplaced -> renameDirectory cache (home </> "retained-cache") >> createDirectory cache
            ReleasedAdded -> createDirectory (home </> "_lima") >> ByteString.writeFile (cache </> "foreign") "foreign\n"
            ReleasedMetadataReplaced -> renameFile (cache </> "data") (root </> "old-cache-data") >> ByteString.writeFile (cache </> "data") "replacement\n"
            ReleasedStageChanged -> do
                _ <- writeColimaStage session keys (ExpectVersion version) contextReleased >>= OwnershipFixture.expectRight
                pure ()
            ReleasedManifestMissing -> compareAndDeleteProtectedRecord session (colimaManifestKey keys) (ExpectVersion manifestVersion) >>= (@?= Right ())
            ReleasedParentRemoved -> removeDirectory parent
            ReleasedParentShared -> ByteString.writeFile (parent </> "foreign") "shared parent\n"
            ReleasedParentReplaced -> renameDirectory parent (parent ++ "-retained") >> createDirectory parent
            _ -> pure ()
        beforeStage <- readProtectedRecord session (colimaStageKey keys)
        before <- traverse (readProtectedRecord session) (colimaStageKey keys : artifactKeys)
        result <- releaseColimaReleasedNamespaces session keys version record home context
        let unchanged = traverse (readProtectedRecord session) (colimaStageKey keys : artifactKeys) >>= (@?= before)
            settled = do
                result @?= Right ()
                traverse (readProtectedRecord session) artifactKeys >>= (@?= replicate 7 (Right Nothing))
                for_ [home, context] $ \target -> doesPathExist target >>= (@?= False)
                readProtectedRecord session (colimaStageKey keys) >>= (@?= beforeStage)
        case scenario of
            ReleasedHomeReplaced -> do
                expectNamespaceConflict "replacement home" result
                unchanged
                doesDirectoryExist (home ++ "-retained") >>= (@?= True)
                doesDirectoryExist home >>= (@?= True)
            ReleasedCacheReplaced -> do
                expectNamespaceConflict "replacement cache" result
                unchanged
                doesDirectoryExist (home </> "retained-cache") >>= (@?= True)
                doesDirectoryExist cache >>= (@?= True)
            ReleasedAdded -> do
                OwnershipFixture.expectOccupied "new namespace entries" result
                unchanged
                ByteString.readFile (cache </> "foreign") >>= (@?= "foreign\n")
                doesDirectoryExist (home </> "_lima") >>= (@?= True)
            ReleasedMetadataReplaced -> do
                OwnershipFixture.expectOccupied "replaced cache metadata" result
                unchanged
                ByteString.readFile (cache </> "data") >>= (@?= "replacement\n")
                ByteString.readFile (root </> "old-cache-data") >>= (@?= "retained cache\n")
            ReleasedStageChanged -> do
                result @?= Left (OwnershipMalformed "the held Released stage changed before namespace settlement")
                unchanged
            ReleasedManifestMissing -> do
                OwnershipFixture.expectOccupied "missing retained release manifest" result
                unchanged
            ReleasedParentShared -> do
                settled
                doesDirectoryExist parent >>= (@?= True)
                ByteString.readFile (parent </> "foreign") >>= (@?= "shared parent\n")
                traverse (readProtectedRecord session) parentKeys >>= (@?= parentBefore)
                releaseColimaReleasedNamespaces session keys version record home context >>= (@?= Right ())
            ReleasedParentReplaced -> do
                expectNamespaceConflict "replacement namespace parent" result
                doesDirectoryExist parent >>= (@?= True)
                doesDirectoryExist (parent ++ "-retained") >>= (@?= True)
                traverse (readProtectedRecord session) parentKeys >>= (@?= parentBefore)
            ReleasedReplay -> do
                settled
                releaseColimaReleasedNamespaces session keys version record home context >>= (@?= Right ())
                doesPathExist parent >>= (@?= False)
            _ -> settled >> (doesPathExist parent >>= (@?= False))
        pure (Right ())
    outcome @?= Right ()
  where
    expectNamespaceConflict label result = case result of
        Left OwnershipConflict{} -> pure ()
        other -> assertFailure (label <> ": expected identity conflict, got " <> show other)

releasedNamespaceProtocolCases :: TestTree
releasedNamespaceProtocolCases = testGroup "private Released namespace protocol"
    [ testCase "fresh completion and replay consume the same retained kernel helper" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            driver <- strictReadFile (packageRoot </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
            cleanup <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "cleanupManagedColimaProfileWith" driver)
            assertBool "the newly written Released version reaches the replay helper"
                (SourceGuard.haskellTokens "Right releasedVersion -> replayCompletedRelease session keys releasedVersion released" `isInfixOf` cleanup)
            released <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "releaseColimaReleasedNamespaces" driver)
            for_ ["readColimaStage", "heldVersion", "heldRecord", "ColimaReleased", "observeKernelOrigin", "readStoredRecordUnder", "admitColimaReleaseManifest", "releaseNamespaceRemainders", "releaseColimaDirectory", "protectedRecordVersion", "observeVacantColimaNamespaces", "decideColimaStage", "ReleaseColimaNamespace", "KeepColimaStage", "releaseColimaContextParents"] $ \name ->
                assertBool ("retained Released settlement includes " <> name) (name `elem` released)
            for_ ["interpret", "runCommand", "ensureColimaDirectory", "writeColimaStage", "pruneEmptyColimaScaffolding"] $ \name ->
                assertBool ("Released settlement cannot recreate, execute or prune unbound paths through " <> name) (name `notElem` released)
            parents <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "releaseColimaContextParents" driver)
            for_ ["observeKernelOrigin", "resumeOwnedRemoval", "storedRecordVersion", "ownershipManifestEntries", "releaseOwnedObject"] $ \name ->
                assertBool ("parent settlement retains " <> name) (name `elem` parents)
    , testCase "a Released manifest retains the committed digest and directory chain" $ do
        manifest <- OwnershipFixture.expectRight (mkOwnershipManifest [])
        prepared <- OwnershipFixture.expectRight (mkColimaStageRecord ColimaPrepared ownerToken (replicate 64 'c') acquireInvocation)
        evidence <- OwnershipFixture.expectRight $ mkColimaManagedEvidence (replicate 32 'd') 73 (replicate 64 'e')
            (ownershipManifestDigest manifest) (Manifest.ownershipDirectoryChainDigest manifest) 8 (16 * gib) (80 * gib) (20 * gib)
        managed <- OwnershipFixture.expectRight (settleColimaStageRecord prepared evidence)
        releasing <- OwnershipFixture.expectRight (beginColimaReleaseRecord managed cleanupInvocation)
        contextReleased <- OwnershipFixture.expectRight (advanceSettledColimaStageRecord releasing ColimaContextReleased)
        released <- OwnershipFixture.expectRight (advanceSettledColimaStageRecord contextReleased ColimaReleased)
        admitColimaReleaseManifest released manifest manifest @?= Right manifest
        admitColimaReleaseManifest managed manifest manifest
            @?= Left (OwnershipMalformed "the frozen Colima release manifest differs from its committed evidence")
    ]

contextNamespaceSupported :: Bool
contextNamespaceSupported = posixOwnershipSupported && directoryReleaseSupported

data ContextNamespaceScenario = NamespaceOwnedPresent | NamespaceRemoved | NamespaceAlreadySettled
    | NamespaceReplaced | NamespaceAdded | NamespaceMetadataReplaced | NamespaceStageChanged | NamespaceManifestChanged

nativeContextNamespaceCases :: TestTree
nativeContextNamespaceCases = testGroup "native context namespace recovery"
    [ native "retained metadata and its directory release conditionally" NamespaceOwnedPresent
    , native "a removed directory settles its retained origin" NamespaceRemoved
    , native "settled absence is idempotent" NamespaceAlreadySettled
    , native "a replacement directory preserves both objects and its origin" NamespaceReplaced
    , native "an added entry refuses before removing retained entries" NamespaceAdded
    , native "replaced metadata preserves both versions and its origins" NamespaceMetadataReplaced
    , native "a changed held stage refuses before namespace effects" NamespaceStageChanged
    , native "a changed manifest refuses before namespace effects" NamespaceManifestChanged
    ]
  where
    native name scenario = conditionalCase ["ColimaSpec", "native context namespace recovery"] contextNamespaceSupported
        name (runNativeContextNamespace scenario) unsupported
    unsupported
        | posixOwnershipSupported = assertDirectoryReleaseUnsupported
        | otherwise = withSystemTempDirectory "hostbootstrap-context-manifest-unsupported" $ \root ->
            ManifestRow.observeOwnershipManifestForHost False root
                >>= (@?= Left (OwnershipUnsupported "the direct-Colima manifest row is unavailable on Windows"))

runNativeContextNamespace :: ContextNamespaceScenario -> IO ()
runNativeContextNamespace scenario = withNativeDirectoryRelease $ \session keys context -> do
    _ <- acquireColimaDirectory session (colimaContextKey keys) context >>= OwnershipFixture.expectRight
    let metadata = context </> "meta.json"
    case scenario of
        NamespaceRemoved -> pure ()
        NamespaceAlreadySettled -> pure ()
        _ -> ByteString.writeFile metadata "retained metadata\n"
    observed <- posixObserveOwnershipManifest False context >>= OwnershipFixture.expectRight
    manifest <- OwnershipFixture.expectRight (Manifest.prefixOwnershipManifest "docker" observed)
    manifestVersion <- compareAndSwapProtectedRecord session (colimaManifestKey keys) ExpectAbsent (renderOwnershipManifest manifest) >>= OwnershipFixture.expectRight
    prepared <- OwnershipFixture.expectRight (mkColimaStageRecord ColimaPrepared ownerToken (replicate 64 'c') acquireInvocation)
    evidence <- OwnershipFixture.expectRight $ mkColimaManagedEvidence (replicate 32 'd') 73 (replicate 64 'e')
        (ownershipManifestDigest manifest) (Manifest.ownershipDirectoryChainDigest manifest) 8 (16 * gib) (80 * gib) (20 * gib)
    managed <- OwnershipFixture.expectRight (settleColimaStageRecord prepared evidence)
    releasing <- OwnershipFixture.expectRight (beginColimaReleaseRecord managed cleanupInvocation)
    record <- OwnershipFixture.expectRight (advanceSettledColimaStageRecord releasing ColimaContextReleased)
    version <- writeColimaStage session keys ExpectAbsent record >>= OwnershipFixture.expectRight
    case scenario of
        NamespaceRemoved -> removeDirectory context
        NamespaceAlreadySettled -> releaseColimaDirectory session (colimaContextKey keys) context >>= (@?= Right ())
        NamespaceReplaced -> renameDirectory context (context ++ "-retained") >> createDirectory context
        NamespaceAdded -> ByteString.writeFile (context </> "foreign") "foreign contents\n"
        NamespaceMetadataReplaced -> renameFile metadata (context ++ "-old-metadata") >> ByteString.writeFile metadata "replacement\n"
        NamespaceStageChanged -> do
            released <- OwnershipFixture.expectRight (advanceSettledColimaStageRecord record ColimaReleased)
            _ <- writeColimaStage session keys (ExpectVersion version) released >>= OwnershipFixture.expectRight
            pure ()
        NamespaceManifestChanged -> do
            changed <- OwnershipFixture.expectRight (mkOwnershipManifest [])
            _ <- compareAndSwapProtectedRecord session (colimaManifestKey keys) (ExpectVersion manifestVersion) (renderOwnershipManifest changed) >>= OwnershipFixture.expectRight
            pure ()
        NamespaceOwnedPresent -> pure ()
    beforeStage <- readProtectedRecord session (colimaStageKey keys)
    beforeManifest <- readProtectedRecord session (colimaManifestKey keys)
    beforeOrigin <- readProtectedRecord session (colimaContextKey keys)
    result <- releaseColimaContextNamespace session keys version record context
    readProtectedRecord session (colimaStageKey keys) >>= (@?= beforeStage)
    readProtectedRecord session (colimaManifestKey keys) >>= (@?= beforeManifest)
    case scenario of
        NamespaceOwnedPresent -> assertSettled session keys context result
        NamespaceRemoved -> assertSettled session keys context result
        NamespaceAlreadySettled -> assertSettled session keys context result
        _ -> do
            case result of
                Left OwnershipConflict{} | NamespaceReplaced <- scenario -> pure ()
                Left OwnershipOccupied{} | NamespaceAdded <- scenario -> pure ()
                Left OwnershipOccupied{} | NamespaceMetadataReplaced <- scenario -> pure ()
                Left OwnershipMalformed{} | NamespaceStageChanged <- scenario -> pure ()
                Left OwnershipMalformed{} | NamespaceManifestChanged <- scenario -> pure ()
                other -> assertFailure ("expected exact namespace refusal class: " <> show other)
            readProtectedRecord session (colimaContextKey keys) >>= (@?= beforeOrigin)
            doesDirectoryExist context >>= (@?= True)
            case scenario of
                NamespaceReplaced -> doesDirectoryExist (context ++ "-retained") >>= (@?= True)
                NamespaceAdded -> ByteString.readFile metadata >>= (@?= "retained metadata\n")
                NamespaceMetadataReplaced -> do
                    ByteString.readFile metadata >>= (@?= "replacement\n")
                    ByteString.readFile (context ++ "-old-metadata") >>= (@?= "retained metadata\n")
                _ -> ByteString.readFile metadata >>= (@?= "retained metadata\n")
  where
    assertSettled session keys context result = do
        result @?= Right ()
        readProtectedRecord session (colimaContextKey keys) >>= (@?= Right Nothing)
        doesPathExist context >>= (@?= False)

contextNamespaceRetryCases :: TestTree
contextNamespaceRetryCases = testGroup "private context namespace retry"
    [ testCase "fresh and resumed context settlement share the actual kernel helper" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            driver <- strictReadFile (packageRoot </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
            tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "cleanupManagedColimaProfileWith" driver)
            assertBool "the admitted ContextReleased retry reaches the common finisher"
                (SourceGuard.haskellTokens "Right ColimaCleanupFromContextReleased -> withValidatedColimaContextParents session context $ finishContextRelease session keys version record" `isInfixOf` tokens)
            assertBool "the finisher consumes the kernel helper before advancing Released"
                (SourceGuard.haskellTokens "namespaces <- releaseColimaReleasedNamespaces session keys nextVersion contextReleased home context case namespaces of Left fault -> pure (ownershipFailure fault) Right () -> case advanceRelease contextReleased ColimaNamespaceAbsent ColimaReleased of" `isInfixOf` tokens)
            kernel <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "releaseColimaContextNamespace" driver)
            for_ ["readColimaStage", "heldVersion", "heldRecord", "ColimaContextReleased", "readRetainedColimaManifest", "admitColimaReleaseManifest", "revalidateColimaContextParents", "observeKernelOrigin", "releaseNamespaceRemainders", "releaseColimaDirectory"] $ \name ->
                assertBool ("actual context recovery retains " <> name) (name `elem` kernel)
            for_ ["interpret", "runCommand", "ensureColimaDirectory", "writeColimaStage"] $ \name ->
                assertBool ("kernel recovery cannot recreate or execute through " <> name) (name `notElem` kernel)
    ]

nativeDockerPreflightCases :: TestTree
nativeDockerPreflightCases = testGroup "native Docker standing preflight"
    [ testCase "an exact Managed stage is admitted without namespace creation" $
        check (Just ColimaManaged) ownerToken lineage acquireInvocation (Right ())
    , testCase "Released refuses without recreating a directory or origin" $
        check (Just ColimaReleased) ownerToken lineage acquireInvocation (Left refusal)
    , testCase "in-progress release stages refuse without namespace creation" $
        for_ [ColimaReleasing, ColimaContextReleased] $ \value ->
            check (Just value) ownerToken lineage acquireInvocation (Left refusal)
    , testCase "each mismatched lineage coordinate refuses without mutation" $
        for_ [("other-owner", lineage, acquireInvocation), (ownerToken, replicate 64 'e', acquireInvocation), (ownerToken, lineage, replicate 64 'f')] $
            \(owner, expectedLineage, invocation) -> check (Just ColimaManaged) owner expectedLineage invocation (Left refusal)
    , testCase "an absent Managed stage remains absent" $
        check Nothing ownerToken lineage acquireInvocation (Left (ColimaMutationProfileConflict "Managed stage is absent"))
    ]
  where
    lineage = replicate 64 'c'
    refusal = ColimaMutationProfileConflict "Docker route is not owned by this Managed lineage"
    check stage owner expectedLineage invocation expected =
        withNativeDirectoryRelease $ \session keys context -> do
            for_ stage $ \value -> do
                prepared <- OwnershipFixture.expectRight (mkColimaStageRecord ColimaPrepared ownerToken lineage acquireInvocation)
                evidence <- OwnershipFixture.expectRight $ mkColimaManagedEvidence (replicate 32 'd') 73 (replicate 64 'e') (replicate 64 'f') (replicate 64 'a') 8 (16 * gib) (80 * gib) (20 * gib)
                managed <- OwnershipFixture.expectRight (settleColimaStageRecord prepared evidence)
                let releasing = beginColimaReleaseRecord managed cleanupInvocation
                    contextReleased = releasing >>= (\record -> advanceSettledColimaStageRecord record ColimaContextReleased)
                record <- OwnershipFixture.expectRight $ case value of
                    ColimaManaged -> Right managed
                    ColimaReleasing -> releasing
                    ColimaContextReleased -> contextReleased
                    ColimaReleased -> contextReleased >>= (\current -> advanceSettledColimaStageRecord current ColimaReleased)
                    _ -> Left "the preflight case names an unsupported test stage"
                _ <- writeColimaStage session keys ExpectAbsent record >>= OwnershipFixture.expectRight
                pure ()
            let retainedKeys = [colimaStageKey keys, colimaContextKey keys, colimaHomeKey keys, colimaProfileKey keys, colimaDiskKey keys, colimaManifestKey keys]
            before <- traverse (readProtectedRecord session) retainedKeys
            admitStoredColimaDockerRoute session keys owner expectedLineage invocation >>= (@?= expected)
            traverse (readProtectedRecord session) retainedKeys >>= (@?= before)
            doesPathExist context >>= (@?= False)
            readProtectedRecord session (colimaContextKey keys) >>= (@?= Right Nothing)

contextReleaseDecisionCases :: TestTree
contextReleaseDecisionCases = testGroup "private context release decisions"
    [ testCase "failed and unavailable context removal cannot reach readback" $ do
        colimaCleanupDeleteResult (Left (ColimaMutationCommandUnavailable "context removal unavailable"))
            @?= Left (ColimaMutationCommandUnavailable "context removal unavailable")
        colimaCleanupDeleteResult (Right (CapturedRun (ExitFailure 19) "partial context removal" "failed"))
            @?= Left ColimaMutationDeleteFailed
        colimaCleanupDeleteResult (Right (CapturedRun ExitSuccess "removed context" "")) @?= Right ()
    , testCase "the actual context removal gates strict readback and durable settlement" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            driver <- strictReadFile (packageRoot </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
            tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "cleanupManagedColimaProfileWith" driver)
            assertBool "context exit classification precedes strict readback"
                (SourceGuard.haskellTokens "removed <- runCommand (removeDockerContextCommand (dockerContextForProfile (colimaCommandProfile keys))) case colimaCleanupDeleteResult removed of Left fault -> pure (Left fault) Right () -> do remaining <- observeContextNames pure (remaining >>= admitColimaContextRemovalAbsence (colimaCommandProfile keys))" `isInfixOf` tokens)
            assertBool "failed removal returns before committing ContextReleased"
                (SourceGuard.haskellTokens "removed <- removeOwnedContext session keys releasingRecord case removed of Left fault -> pure (Left fault) Right () -> do current <- readColimaStage" `isInfixOf` tokens)
    , testCase "stage evidence and records expose no record update labels" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            source <- strictReadFile (packageRoot </> "internal" </> "colima-backend" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Backend" </> "Stage.hs")
            let tokens = SourceGuard.haskellTokens source
                exports = takeWhile (/= "where") tokens
            assertBool "managed evidence is exported abstractly"
                (SourceGuard.haskellTokens "ColimaManagedEvidence ," `isInfixOf` exports)
            for_ ["ColimaStageRecord", "ColimaManagedEvidence"] $ \typeName -> do
                assertBool (typeName <> " has a positional constructor")
                    (SourceGuard.haskellTokens ("data " <> typeName <> " = " <> typeName) `isInfixOf` tokens)
                assertBool (typeName <> " has no record fields")
                    (not (SourceGuard.haskellTokens ("data " <> typeName <> " = " <> typeName <> " {") `isInfixOf` tokens))
    , testCase "the actual Docker driver admits retained standing before namespace effects" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            driver <- strictReadFile (packageRoot </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
            tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "runManagedColimaDockerWith" driver)
            assertBool "retained stage admission precedes parents and context re-entry"
                (SourceGuard.haskellTokens "stageAdmission <- admitStoredColimaDockerRoute session keys owner lineage invocation case stageAdmission of Left fault -> pure (Left fault) Right () -> withValidatedColimaContextParents session context $ do contextStanding <- readRetainedColimaDirectoryIdentity" `isInfixOf` tokens)
            gate <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "admitStoredColimaDockerRoute" driver)
            for_ ["readColimaStage", "admitColimaManagedDockerRoute"] $ \name ->
                assertBool ("the actual preflight delegates to " <> name) (name `elem` gate)
            for_ ["ensureColimaDirectory", "writeColimaStage", "compareAndSwapProtectedRecord", "interpret"] $ \name ->
                assertBool ("the preflight remains read-only: " <> name) (name `notElem` gate)
    ]

nativeDirectoryReleaseCases :: TestTree
nativeDirectoryReleaseCases = testGroup "native directory release recovery"
    [ native "a removed bound directory forgets its retained origin" $
        withNativeDirectoryRelease $ \session keys target -> do
            _ <- acquireColimaDirectory session (colimaHomeKey keys) target >>= OwnershipFixture.expectRight
            removeDirectory target
            releaseColimaDirectory session (colimaHomeKey keys) target >>= (@?= Right ())
            readProtectedRecord session (colimaHomeKey keys) >>= (@?= Right Nothing)
            doesPathExist target >>= (@?= False)
    , native "an already absent unrecorded directory remains absent" $
        withNativeDirectoryRelease $ \session keys target -> do
            releaseColimaDirectory session (colimaHomeKey keys) target >>= (@?= Right ())
            readProtectedRecord session (colimaHomeKey keys) >>= (@?= Right Nothing)
            doesPathExist target >>= (@?= False)
    , native "an unrecorded present directory is never removed" $
        withNativeDirectoryRelease $ \session keys target -> do
            createDirectory target
            releaseColimaDirectory session (colimaHomeKey keys) target
                >>= (@?= Left (OwnershipOccupied "an unrecorded Colima directory remains present"))
            doesDirectoryExist target >>= (@?= True)
            readProtectedRecord session (colimaHomeKey keys) >>= (@?= Right Nothing)
    , native "a replacement directory keeps both objects and the old origin" $
        withNativeDirectoryRelease $ \session keys target -> do
            _ <- acquireColimaDirectory session (colimaHomeKey keys) target >>= OwnershipFixture.expectRight
            before <- readProtectedRecord session (colimaHomeKey keys)
            renameDirectory target (target ++ "-retained")
            createDirectory target
            refused <- releaseColimaDirectory session (colimaHomeKey keys) target
            case refused of
                Left OwnershipConflict{} -> pure ()
                other -> assertFailure ("expected replacement refusal: " <> show other)
            readProtectedRecord session (colimaHomeKey keys) >>= (@?= before)
            doesDirectoryExist target >>= (@?= True)
            doesDirectoryExist (target ++ "-retained") >>= (@?= True)
    ]
  where
    native name run = conditionalCase ["ColimaSpec", "native directory release recovery"] directoryReleaseSupported
        name run assertDirectoryReleaseUnsupported

directoryReleasePolicyCases :: TestTree
directoryReleasePolicyCases = testGroup "created directory release policy"
    [ testCase "only an absent-origin bound directory is admitted" $ do
        identity <- OwnershipFixture.expectRight (OwnershipFixture.kernelIdentityWords 1 7)
        owned <- OwnershipFixture.expectRight (bindOriginRecord identity (originRecord OwnedDirectory OriginAbsent))
        colimaDirectoryBinding owned @?= Right identity
        colimaDirectoryBinding (originRecord OwnedDirectory OriginAbsent)
            @?= Left (OwnershipMalformed "the directory origin is not identity-bound")
        for_ [originRecord OwnedDirectory (OriginPresent identity), originRecord (ReportedObject (mkOwnerClaim "reported")) OriginAbsent] $ \record ->
            colimaDirectoryBinding record @?= Left (OwnershipOccupied "the directory was not created by this owner")
    , testCase "directory recovery delegates to the sole live kernel producer" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            driver <- strictReadFile (packageRoot </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
            primitive <- strictReadFile (packageRoot </> "internal" </> "ownership" </> "HostBootstrap" </> "Ownership" </> "Primitive.hs")
            tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "releaseColimaDirectory" driver)
            for_ ["colimaDirectoryBinding", "reenterStoredOwnedObject", "observeKernelOrigin", "resumeOwnedRemoval", "releaseOwnedObject", "storedRecordVersion"] $ \name ->
                assertBool ("the actual directory release retains " <> name) (name `elem` tokens)
            resumed <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "resumeOwnedRemoval" primitive)
            for_ ["ClauseRelease", "ClauseRecord", "withLiveOwnershipEntry", "boundEvidenceOf", "rowObserveIdentity", "rowSyncParent", "forget"] $ \name ->
                assertBool ("the shared recovery retains " <> name) (name `elem` resumed)
            assertBool "an already absent object is not removed again" ("rowRemoveObject" `notElem` resumed)
            assertBool "parent synchronization precedes forgetting the retained record"
                (SourceGuard.haskellTokens "synced <- rowSyncParent primitives target case synced of Left fault -> pure (Left fault) Right () -> forget record" `isInfixOf` resumed)
    ]

conditionalProfileReleaseCases :: TestTree
conditionalProfileReleaseCases = testGroup "private conditional profile release"
    [ testCase "the exact retained profile reaches machine admission" $
        classifyColimaCleanupProfile profileName managed [exact] @?= Right ColimaCleanupProfilePresent
    , testCase "changed wall or runtime refuses before deletion" $
        for_ [exact{ciCpus = 9}, exact{ciMemoryBytes = 17 * gib}, exact{ciDiskBytes = 81 * gib}, exact{ciRuntime = "containerd"}] $ \changed ->
            classifyColimaCleanupProfile profileName managed [changed]
                @?= Left (ColimaMutationProfileConflict "managed profile wall or runtime changed before delete")
    , testCase "a duplicated profile cannot authorize release" $
        classifyColimaCleanupProfile profileName managed [exact, exact]
            @?= Left (ColimaMutationProfileConflict "profile listing is duplicated")
    , testCase "absence before a release is committed grants nothing" $
        classifyColimaCleanupProfile profileName managed [] @?= Left (ColimaMutationProfileConflict "profile is absent before delete")
    , testCase "a committed release can classify a freshly absent profile" $
        classifyColimaCleanupProfile profileName releasing [] @?= Right ColimaCleanupProfileAbsent
    , testCase "the exact machine evidence and origin binding agree" $
        admitColimaCleanupMachine managed (Just machine) machineHex 73 @?= Right machine
    , testCase "changed machine or epoch refuses before deletion" $
        for_ [(replicate 32 'e', 73), (machineHex, 74)] $ \(identity, epoch) ->
            admitColimaCleanupMachine managed (Just machine) identity epoch
                @?= Left (ColimaMutationProfileConflict "managed machine evidence changed before delete")
    , testCase "missing or different retained profile bindings refuse" $
        for_ [Nothing, Just otherMachine] $ \binding ->
            admitColimaCleanupMachine managed binding machineHex 73
                @?= Left (ColimaMutationProfileConflict "profile identity changed before delete")
    , testCase "delete availability and exit decide whether readback is reached" $ do
        let timeoutFault = ColimaMutationCommandUnavailable "native Colima command timed out"
        colimaCleanupDeleteResult (Left timeoutFault) @?= Left timeoutFault
        colimaCleanupDeleteResult (Right (CapturedRun (ExitFailure 17) "partial" "failed")) @?= Left ColimaMutationDeleteFailed
        colimaCleanupDeleteResult (Right (CapturedRun ExitSuccess "deleted" "")) @?= Right ()
    , testCase "strict absence refuses a retained profile and ignores other profiles" $ do
        admitColimaCleanupProfileAbsence profileName [] @?= Right ColimaProfileAbsent
        admitColimaCleanupProfileAbsence profileName [exact{ciName = "other"}] @?= Right ColimaProfileAbsent
        for_ [[exact], [exact, exact]] $ \present ->
            admitColimaCleanupProfileAbsence profileName present
                @?= Left (ColimaMutationProfileConflict "profile remained present after delete")
    , testCase "a frozen release permits only retained manifest remainders" $ do
        admitColimaReleaseManifest releasing retained retained @?= Right retained
        admitColimaReleaseManifest releasing retained empty @?= Right retained
    , testCase "new namespace entries refuse release recovery" $
        case admitColimaReleaseManifest releasing retained foreignManifest of
            Left OwnershipOccupied{} -> pure ()
            other -> assertFailure ("expected a new-entry refusal: " <> show other)
    , testCase "replacement namespace identities refuse release recovery" $
        case admitColimaReleaseManifest releasing retained replaced of
            Left OwnershipOccupied{} -> pure ()
            other -> assertFailure ("expected a replacement refusal: " <> show other)
    , testCase "release remainders require the committed stage and manifest digest" $ do
        let refusal = Left (OwnershipMalformed "the frozen Colima release manifest differs from its committed evidence")
        admitColimaReleaseManifest managed retained retained @?= refusal
        admitColimaReleaseManifest releasing empty empty @?= refusal
    , testCase "the actual cleanup consumes profile decisions and the shared absence recovery" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            driver <- strictReadFile (packageRoot </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
            tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "cleanupManagedColimaProfileWith" driver)
            for_ ["classifyColimaCleanupProfile", "admitColimaCleanupMachine", "colimaCleanupDeleteResult",
                  "admitColimaCleanupProfileAbsence", "admitColimaReleaseManifest", "resumeReportedRemoval",
                  "readRetainedColimaDirectoryIdentity", "observeKernelOrigin", "storedRecordVersion"] $ \name ->
                assertBool ("the actual release retains " <> name) (name `elem` tokens)
            for_ ["exactPresent", "exactAbsent"] $ \name ->
                assertBool ("there is no duplicate profile classifier: " <> name) (name `notElem` tokens)
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "Right ColimaCleanupProfileAbsent -> resumeAbsentProfile session keys heldVersion heldRecord retainedManifest") driver @?= 1
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "case colimaCleanupDeleteResult deleted of Left fault -> pure (Left fault) Right () -> settleAbsence") driver @?= 1
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "resumeReportedRemoval bound OriginAbsent") driver @?= 1
    ]
  where
    exact = ColimaInstance profileName "Running" 8 (16 * gib) (80 * gib) "docker"
    machineHex = replicate 32 'd'
    machine = either (error . show) id (parseObjectIdentityHex (Text.pack machineHex))
    otherMachine = either (error . show) id (parseObjectIdentityHex (Text.pack (replicate 32 'e')))
    retained = makeManifest "colima/file" 1
    foreignManifest = makeManifest "colima/foreign" 1
    replaced = makeManifest "colima/file" 2
    empty = either (error . show) id (mkOwnershipManifest [])
    makeManifest name inode = either (error . show) id $ do
        identity <- OwnershipFixture.kernelIdentityWords 1 inode
        entry <- mutableManifestEntry name identity 0o600
        mkOwnershipManifest [entry]
    prepared = either error id (mkColimaStageRecord ColimaPrepared ownerToken (replicate 64 'c') acquireInvocation)
    evidence = either error id $ mkColimaManagedEvidence machineHex 73 (replicate 64 'e')
        (ownershipManifestDigest retained) (Manifest.ownershipDirectoryChainDigest retained) 8 (16 * gib) (80 * gib) (20 * gib)
    managed = either error id (settleColimaStageRecord prepared evidence)
    releasing = either error id (beginColimaReleaseRecord managed cleanupInvocation)

cleanupResumeAdmissionCases :: TestTree
cleanupResumeAdmissionCases = testGroup "private cleanup resume admission"
    [ testCase "Managed begins a release" $
        admitColimaCleanupResume cleanupInvocation managed @?= Right ColimaCleanupFromManaged
    , testCase "the committed invocation resumes Releasing" $
        admitColimaCleanupResume cleanupInvocation releasing @?= Right ColimaCleanupFromReleasing
    , testCase "the committed invocation resumes ContextReleased" $
        admitColimaCleanupResume cleanupInvocation contextReleased @?= Right ColimaCleanupFromContextReleased
    , testCase "another invocation cannot resume ContextReleased" $
        admitColimaCleanupResume (replicate 64 'e') contextReleased @?= Left refusal
    , testCase "the committed invocation replays Released" $
        admitColimaCleanupResume cleanupInvocation released @?= Right ColimaCleanupReleasedReplay
    , testCase "another invocation cannot resume Releasing" $
        admitColimaCleanupResume (replicate 64 'e') releasing @?= Left refusal
    , testCase "another invocation cannot replay Released" $
        admitColimaCleanupResume (replicate 64 'e') released @?= Left refusal
    , testCase "other cleanup stages refuse before a retry is selected" $
        for_ earlier $ \record -> admitColimaCleanupResume cleanupInvocation record @?= Left refusal
    , testCase "the real cleanup admits its retry before context or deletion work" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            driver <- strictReadFile (packageRoot </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
            tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "cleanupManagedColimaProfileWith" driver)
            for_ ["admitColimaCleanupLineage", "admitColimaCleanupResume", "ColimaCleanupReleasedReplay", "replayCompletedRelease"] $ \name ->
                assertBool ("the actual cleanup selects " <> name) (name `elem` tokens)
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "otherwise -> case admitColimaCleanupResume cleanupInvocation record of Left fault -> pure (Left fault) Right ColimaCleanupReleasedReplay -> replayCompletedRelease session keys version record Right ColimaCleanupFromManaged -> withValidatedColimaContextParents") driver @?= 1
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "admitColimaCleanupResume :: String -> ColimaStageRecord -> Either ColimaProfileMutationFault ColimaCleanupResume") driver @?= 1
    ]
  where
    refusal = ColimaMutationOwnershipRefused (OwnershipMalformed "Colima cleanup stage is not resumable")
    prepared = either error id (mkColimaStageRecord ColimaPrepared ownerToken (replicate 64 'c') acquireInvocation)
    evidence = either error id $ mkColimaManagedEvidence (replicate 32 'd') 73 (replicate 64 'e') (replicate 64 'f') (replicate 64 'a') 8 (16 * gib) (80 * gib) (20 * gib)
    managed = either error id (settleColimaStageRecord prepared evidence)
    releasing = either error id (beginColimaReleaseRecord managed cleanupInvocation)
    contextReleased = either error id (advanceSettledColimaStageRecord releasing ColimaContextReleased)
    released = either error id (advanceSettledColimaStageRecord contextReleased ColimaReleased)
    earlier = [either error id (mkColimaStageRecord value ownerToken (replicate 64 'c') acquireInvocation) | value <- [ColimaReserved .. ColimaPrepared]]

cleanupRetryIdentityCases :: TestTree
cleanupRetryIdentityCases = testGroup "stable cleanup invocation identity"
    [ testCase "the cleanup invocation has canonical stable-field framing" $
        ColimaIdentity.colimaCleanupInvocationDigest "cleanup:call" "plan:one" "provider:destroy" 7 @?= "bd8c1eb157f3bdb87e749a5f7da051ea1792df12273de1915a571b92146857ec"
    , testCase "every stable cleanup coordinate changes the identity" $ do
        let baseline = ColimaIdentity.colimaCleanupInvocationDigest "cleanup:call" "plan:one" "provider:destroy" 7
        for_ [ ColimaIdentity.colimaCleanupInvocationDigest "cleanup:other" "plan:one" "provider:destroy" 7
             , ColimaIdentity.colimaCleanupInvocationDigest "cleanup:call" "plan:other" "provider:destroy" 7
             , ColimaIdentity.colimaCleanupInvocationDigest "cleanup:call" "plan:one" "provider:other" 7
             , ColimaIdentity.colimaCleanupInvocationDigest "cleanup:call" "plan:one" "provider:destroy" 8
             ] $ \changed -> assertBool "a stable cleanup coordinate remains bound" (changed /= baseline)
    , testCase "real session attempt and physical journal-version changes retain release identity" $
        withTestProjectResources $ \plan _project providerResource _clusterResource -> do
            let digest = stablePlanSnapshotDigest (renderSnapshot plan)
                operation = plannedResourceKey providerResource
                identity actual = ColimaIdentity.colimaCleanupInvocationDigest "cleanup:call"
                    (preparedGatePlan actual) (preparedGateOperation actual) (preparedGateFence actual)
                coordinates actual =
                    [ Text.unpack (preparedGatePlan actual), Text.unpack (preparedGateOperation actual)
                    , Text.unpack (preparedGateSession actual), show (preparedGateFence actual)
                    , show (preparedGateAttempt actual), show (preparedGateJournalVersion actual)
                    ]
            withSuccessorGate digest operation "session-1" 1 1 1 $ \_store gate nextVersion -> do
                sessionGate <- gateForValues digest operation "session-2" 1 1
                attemptGate <- gateForValues digest operation "session-1" 1 2
                versionGate <- nextVersion
                for_ [(sessionGate, 2), (attemptGate, 4), (versionGate, 5)] $ \(changed, field) -> do
                    zipWith (/=) (coordinates gate) (coordinates changed) @?= [i == field | i <- [0 :: Int .. 5]]
                    identity changed @?= identity gate
    , testCase "the cleanup adapter projects only stable coordinates into the private algebra" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            adapter <- strictReadFile (packageRoot </> "src" </> "HostBootstrap" </> "Ensure" </> "Colima.hs")
            private <- strictReadFile (packageRoot </> "internal" </> "colima-backend" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Backend" </> "Identity.hs")
            tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "colimaCleanupInvocationDigest" adapter)
            for_ ["ColimaIdentity", "colimaCleanupInvocationDigest", "preparedGatePlan", "preparedGateOperation", "preparedGateFence"] $ \name ->
                assertBool ("the actual cleanup adapter retains " <> name) (name `elem` tokens)
            for_ ["preparedGateSession", "preparedGateAttempt", "preparedGateJournalVersion", "hashWith", "intercalate"] $ \name ->
                assertBool ("cleanup retry coordinates and serializers stay out of the adapter: " <> name) (name `notElem` tokens)
            assertBool "the private algebra owns the cleanup domain"
                ("direct-colima-cleanup-invocation-v1" `isInfixOf` private && not ("direct-colima-cleanup-invocation-v1" `isInfixOf` adapter))
    ]

cleanupLineageCases :: TestTree
cleanupLineageCases = testGroup "private cleanup lineage admission"
    [ testCase "the exact managed lineage admits cleanup classification" $ do
        record <- managedRecord
        admitColimaCleanupLineage ownerToken lineage acquireInvocation record @?= Right ()
    , testCase "another owner refuses before cleanup" $ refusal "other-owner" lineage acquireInvocation
    , testCase "another lineage refuses before cleanup" $ refusal ownerToken (replicate 64 'e') acquireInvocation
    , testCase "another acquisition invocation refuses before cleanup" $ refusal ownerToken lineage (replicate 64 'f')
    , testCase "cleanup authority retains the exact live ownership package" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            adapter <- strictReadFile (packageRoot </> "src" </> "HostBootstrap" </> "Ensure" </> "Colima.hs")
            driver <- strictReadFile (packageRoot </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "ColimaCleanupAuthority profileName owned (providerWallEpoch authority) runningHandle receipt fenceValue") adapter @?= 1
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "Left fault <- admitColimaCleanupLineage owner lineage invocation record -> pure (Left fault)") driver @?= 1
            tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "cleanupManagedColimaProfileWith" driver)
            assertBool "the actual cleanup consumes the pure lineage admission" ("admitColimaCleanupLineage" `elem` tokens)
            assertBool "there is no second cleanup lineage predicate" ("sameManagedLineage" `notElem` tokens)
            for_ ["admitColimaCleanupLineage", "admitColimaManagedDockerRoute"] $ \name -> do
                admitted <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens name driver)
                assertBool ("both policies share one lineage comparison: " <> name) ("colimaManagedLineageMatches" `elem` admitted)
            for_ ["colimaStageRecordOwner", "colimaStageRecordLineage", "colimaStageRecordInvocation"] $ \name ->
                assertBool ("cleanup does not duplicate " <> name) (name `notElem` tokens)
    ]
  where
    lineage = replicate 64 'c'
    managedRecord = do
        prepared <- OwnershipFixture.expectRight (mkColimaStageRecord ColimaPrepared ownerToken lineage acquireInvocation)
        evidence <- OwnershipFixture.expectRight $
            mkColimaManagedEvidence (replicate 32 'd') 73 (replicate 64 'e') (replicate 64 'f') (replicate 64 'a') 8 (16 * gib) (80 * gib) (20 * gib)
        OwnershipFixture.expectRight (settleColimaStageRecord prepared evidence)
    refusal owner expectedLineage invocation = do
        record <- managedRecord
        admitColimaCleanupLineage owner expectedLineage invocation record
            @?= Left (ColimaMutationProfileConflict "managed stage belongs to another lineage")

pureDockerRouteCases :: TestTree
pureDockerRouteCases = testGroup "pure managed Docker route"
    [ testCase "the exact Managed record admits the route" $ do
        record <- stage ColimaManaged
        admitColimaManagedDockerRoute ownerToken lineage acquireInvocation record @?= Right ()
    , testCase "a different owner refuses the route" $ refuse "other-owner" lineage acquireInvocation
    , testCase "a different lineage refuses the route" $ refuse ownerToken (replicate 64 'e') acquireInvocation
    , testCase "a different acquisition invocation refuses the route" $ refuse ownerToken lineage (replicate 64 'f')
    , testCase "every non-Managed stage including Released refuses the route" $
        for_ (filter (/= ColimaManaged) [minBound .. maxBound]) $ \value -> do
            record <- stage value
            admitColimaManagedDockerRoute ownerToken lineage acquireInvocation record @?= Left routeRefusal
    , testCase "a native timeout is an unavailable command without a captured run" $
        colimaDockerCommandResult (Left "native Colima command timed out")
            @?= Left (ColimaMutationCommandUnavailable "native Colima command timed out")
    , testCase "completed commands retain their actual exit and both streams" $
        for_ [ExitSuccess, ExitFailure 17] $ \code -> do
            let captured = CapturedRun code "stdout\n" "stderr\n"
            colimaDockerCommandResult (Right captured) @?= Right captured
    , testCase "a completed run keeps its capture when the toolchain recheck fails" $
        colimaDockerRunResult (Right (capture, Nothing)) (Left "changed identity")
            @?= Right (ColimaDockerRun capture (Just "live Docker toolchain changed after execution: changed identity"))
    , testCase "a command refusal stays not-run for either recheck answer" $
        for_ [Right (), Left "changed identity"] $ \answer ->
            colimaDockerRunResult (Left "command unavailable") answer @?= Left "command unavailable"
    , testCase "a completed run with valid standing has no post-call failure" $
        colimaDockerRunResult (Right (capture, Nothing)) (Right ()) @?= Right (ColimaDockerRun capture Nothing)
    , testCase "a completed run keeps its ownership recheck failure" $
        colimaDockerRunResult (Right (capture, Just "ownership changed")) (Right ())
            @?= Right (ColimaDockerRun capture (Just "ownership changed"))
    , testCase "both post-call failures remain beside the completed run" $
        colimaDockerRunResult (Right (capture, Just "ownership changed")) (Left "changed identity")
            @?= Right (ColimaDockerRun capture (Just "ownership changed; live Docker toolchain changed after execution: changed identity"))
    , testCase "the real Docker driver consumes the pure admission and preserves a completed capture" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            driver <- strictReadFile (packageRoot </> "internal" </> "colima-ownership" </> "HostBootstrap" </> "Ensure" </> "Colima" </> "Ownership.hs")
            adapter <- strictReadFile (packageRoot </> "src" </> "HostBootstrap" </> "Ensure" </> "Colima.hs")
            tokens <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "runManagedColimaDockerWith" driver)
            for_ ["admitStoredColimaDockerRoute", "colimaDockerCommandResult", "routedDockerCommand", "runCommand", "validateStanding"] $ \name ->
                assertBool ("the actual driver retains " <> name) (name `elem` tokens)
            for_ ["writeColimaStage", "colimaStageRecordOwner", "colimaStageRecordLineage", "colimaStageRecordInvocation"] $ \name ->
                assertBool ("the route makes no stage write or duplicate identity decision: " <> name) (name `notElem` tokens)
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "pure (Right (captured, either Just (const Nothing) retained))") driver @?= 1
            SourceGuard.countHaskellTokenSequence
                (SourceGuard.haskellTokens "Right () -> do result <- runCommand dockerCommand") driver @?= 1
            live <- OwnershipFixture.expectRight (SourceGuard.haskellDefinitionTokens "runLiveColimaDocker" adapter)
            for_ ["revalidateTrustedAppleToolchain", "runManagedColimaDockerWith", "colimaDockerRunResult"] $ \name ->
                assertBool ("the sealed adapter retains " <> name) (name `elem` live)
    ]
  where
    lineage = replicate 64 'c'
    capture = CapturedRun (ExitFailure 17) "retained stdout\n" "retained stderr\n"
    routeRefusal = ColimaMutationProfileConflict "Docker route is not owned by this Managed lineage"
    refuse owner expectedLineage invocation = do
        record <- stage ColimaManaged
        admitColimaManagedDockerRoute owner expectedLineage invocation record @?= Left routeRefusal
    stage value
        | value <= ColimaPrepared = OwnershipFixture.expectRight (mkColimaStageRecord value ownerToken lineage acquireInvocation)
        | otherwise = do
            prepared <- OwnershipFixture.expectRight (mkColimaStageRecord ColimaPrepared ownerToken lineage acquireInvocation)
            evidence <- OwnershipFixture.expectRight $
                mkColimaManagedEvidence (replicate 32 'd') 73 (replicate 64 'e') (replicate 64 'f') (replicate 64 'a') 8 (16 * gib) (80 * gib) (20 * gib)
            managed <- OwnershipFixture.expectRight (settleColimaStageRecord prepared evidence)
            let releasing = beginColimaReleaseRecord managed cleanupInvocation
                contextReleased = releasing >>= (\record -> advanceSettledColimaStageRecord record ColimaContextReleased)
            OwnershipFixture.expectRight $ case value of
                ColimaManaged -> Right managed
                ColimaReleasing -> releasing
                ColimaContextReleased -> contextReleased
                ColimaReleased -> contextReleased >>= (\record -> advanceSettledColimaStageRecord record ColimaReleased)
                _ -> Left "an earlier stage uses the constructor branch"

staticOwnedSettlementCases :: TestTree
staticOwnedSettlementCases =
    testGroup "native fixture backed owned settlement"
        [ conditionalCase ["ColimaSpec", "native fixture backed owned settlement"] posixOwnershipSupported name
            (runStaticOwnedScenario scenario) assertNativeFixtureUnsupported
        | (name, scenario) <-
            [ ("applied joins live wall and Created provider at the observed generation", OwnedApplied)
            , ("exact joins live wall and Repaired provider at the observed generation", OwnedExact)
            , ("the exact live wall introduces cleanup authority", OwnedCleanupAuthority)
            , ("a cleanup gate at the retained fence prepares teardown", OwnedCleanupPrepared)
            , ("a cleanup gate at another fence refuses teardown", OwnedCleanupWrongFence)
            , ("a different session cannot settle the prepared call", WrongSession)
            , ("a different attempt cannot settle the prepared call", WrongAttempt)
            , ("a different journal version cannot settle the prepared call", WrongVersion)
            , ("a different state root cannot settle the prepared call", WrongRoot)
            , ("a different namespace key cannot settle the prepared call", WrongNamespace)
            , ("a different record path cannot settle the prepared call", WrongRecord)
            , ("a different Docker config cannot settle the prepared call", WrongDockerConfig)
            , ("a different bound owner cannot settle the prepared call", WrongOwner)
            ]
        ]

runStaticOwnedScenario :: StaticOwnedScenario -> IO ()
runStaticOwnedScenario scenario =
    withResolverHarness "static-owned-settlement" $ \harness -> do
        let layout = resolverHarnessLayout harness
        (_, resolution) <- executeNativeResolverFixtureWithSettlement (resolverFixtureRoot layout) (resolverFixtureHome layout)
        toolchain <- case resolution of
            Resolver.TrustedResolverReady actual -> pure actual
            _ -> assertFailure ("expected an actual ready fixture toolchain: " <> show (settlementView resolution))
        accepted <- withTestProjectResources $ \plan _project providerResource clusterResource -> do
            let digest = stablePlanSnapshotDigest (renderSnapshot plan)
                operation = plannedResourceKey providerResource
            -- Keeping the same attempt on the successor changes only the physical journal version.
            withSuccessorGate digest operation "session-1" 1 1 1 $ \_store gate nextVersion ->
                withPreparedTestCallForGateAndEnvelope plan providerResource clusterResource gate $ \call envelope -> do
                    let namespace = (resolverHarnessNamespace harness){namespaceDockerConfig = testEnvelopeRecordPath envelope ++ ".docker"}
                        owned = ColimaObservation.ColimaOwnedObservation
                            { ColimaObservation.ownedToolchain = toolchain
                            , ColimaObservation.ownedNamespaceKey = testEnvelopeNamespaceKey envelope
                            , ColimaObservation.ownedNamespace = namespace
                            , ColimaObservation.ownedStateRoot = testEnvelopeRoot envelope
                            , ColimaObservation.ownedRecordPath = testEnvelopeRecordPath envelope
                            , ColimaObservation.ownedOwner = ColimaIdentity.bindColimaOwner (testEnvelopeOwnerSeed envelope) namespace
                                (Resolver.trustedAppleToolchainFingerprint toolchain)
                            , ColimaObservation.ownedLineage = Text.unpack (sha256Hex (Text.Encoding.encodeUtf8 (Text.pack (testEnvelopeNamespaceKey envelope))))
                            , ColimaObservation.ownedMachineId = "static-fixture-machine"
                            , ColimaObservation.ownedContextDigest = replicate 64 'a'
                            , ColimaObservation.ownedExpectedWall = ColimaObservation.ExpectedColimaWall 8 (16 * gib) (80 * gib) (20 * gib)
                            , ColimaObservation.ownedInvocationDigest = testEnvelopeInvocation envelope
                            , ColimaObservation.ownedSettlementObservation = ColimaWallSettlementApplied 73
                            }
                        settle value = settleColimaWallCall call (ColimaObservation.ColimaOwnedWallObservation value)
                            (\live -> (liveColimaWallEpoch live, liveColimaWallChange live, liveColimaProviderChange live))
                        positive backend wallChange providerChange = do
                            let candidate = owned{ColimaObservation.ownedSettlementObservation = backend}
                            settle candidate @?= Right (73, wallChange, providerChange)
                            let expectedContext = "colima-" ++ preparedColimaProfileName call
                            settleColimaWallCall call (ColimaObservation.ColimaOwnedWallObservation candidate)
                                (\live -> (liveColimaDockerContext live, liveColimaDockerArgs live ["ps"]))
                                @?= Right (expectedContext, ["--context", expectedContext, "ps"])
                            -- This is the actual private producer and generic start completion;
                            -- validateOwnershipReceipt checks the retained receipt against its handle.
                            testEnvelopeCompleteStart envelope backend @?= Right (17, providerChange)
                        checkCleanupGate requestedFence = do
                            cleanupGate <- gateForValues digest operation "cleanup-session" requestedFence 1
                            let settled = settleColimaWallCall call (ColimaObservation.ColimaOwnedWallObservation owned) $ \live ->
                                    case withColimaCleanupAuthority live $ \authority -> do
                                        prepared <- prepareColimaCleanupCall plan providerResource cleanupGate authority
                                        case prepared of
                                            Right _ | requestedFence == preparedGateFence gate -> pure ()
                                            Left failure | requestedFence /= preparedGateFence gate ->
                                                failure @?= Reconcile.Conflict (ConflictDetail operation
                                                    ("cleanup gate fence " <> Text.pack (show (preparedGateFence gate)))
                                                    ("cleanup gate fence " <> Text.pack (show requestedFence))
                                                    "journal the exact force-destroy operation at the retained wall fence")
                                            Left failure -> assertFailure ("matching cleanup preparation refused: " <> show failure)
                                            Right _ -> assertFailure "a different cleanup fence prepared teardown" of
                                        Nothing -> assertFailure "the exact live wall supplied no cleanup authority"
                                        Just action -> action
                            either (assertFailure . show) id settled
                    case scenario of
                        OwnedApplied -> positive (ColimaWallSettlementApplied 73) (Reconcile.Changed Reconcile.Created) (Reconcile.Changed Reconcile.Created)
                        OwnedExact -> positive (ColimaWallSettlementAlreadyExact 73) Reconcile.Unchanged (Reconcile.Changed Reconcile.Repaired)
                        OwnedCleanupPrepared -> checkCleanupGate 1
                        OwnedCleanupWrongFence -> checkCleanupGate 2
                        OwnedCleanupAuthority ->
                            settleColimaWallCall call (ColimaObservation.ColimaOwnedWallObservation owned)
                                (\live -> withColimaCleanupAuthority live (const ())) @?= Right (Just ())
                        _ -> do
                            candidate <- case scenario of
                                WrongRoot -> pure owned{ColimaObservation.ownedStateRoot = testEnvelopeRoot envelope </> "other-root"}
                                WrongNamespace -> pure owned{ColimaObservation.ownedNamespaceKey = testEnvelopeNamespaceKey envelope ++ "-other"}
                                WrongRecord -> pure owned{ColimaObservation.ownedRecordPath = testEnvelopeRecordPath envelope ++ "-other"}
                                WrongDockerConfig -> pure owned{ColimaObservation.ownedNamespace = namespace{namespaceDockerConfig = namespaceDockerConfig namespace ++ "-other"}}
                                WrongOwner -> pure owned{ColimaObservation.ownedOwner = ColimaObservation.ownedOwner owned ++ "-other"}
                                _ -> do
                                    (foreignGate, changedField) <- case scenario of
                                        WrongSession -> do
                                            other <- gateForValues digest operation "session-2" 1 1
                                            pure (other, 2)
                                        WrongAttempt -> do
                                            other <- gateForValues digest operation "session-1" 1 2
                                            pure (other, 4)
                                        _ -> do
                                            other <- nextVersion
                                            pure (other, 5)
                                    let coordinates actual =
                                            [ Text.unpack (preparedGatePlan actual), Text.unpack (preparedGateOperation actual)
                                            , Text.unpack (preparedGateSession actual), show (preparedGateFence actual)
                                            , show (preparedGateAttempt actual), show (preparedGateJournalVersion actual)
                                            ]
                                    zipWith (/=) (coordinates gate) (coordinates foreignGate) @?= [i == changedField | i <- [0 :: Int .. 5]]
                                    matched <- withPreparedTestCallForGateAndEnvelope plan providerResource clusterResource foreignGate $ \foreignCall foreignEnvelope -> do
                                        testEnvelopeCallDigest foreignEnvelope @?= testEnvelopeCallDigest envelope
                                        assertBool "the actual prepared invocation differs" (testEnvelopeInvocation foreignEnvelope /= testEnvelopeInvocation envelope)
                                        let candidate = owned{ColimaObservation.ownedInvocationDigest = testEnvelopeInvocation foreignEnvelope}
                                        settleColimaWallCall foreignCall (ColimaObservation.ColimaOwnedWallObservation candidate)
                                            liveColimaProviderChange @?= Right (Reconcile.Changed Reconcile.Created)
                                        pure candidate
                                    either assertFailure pure matched
                            settle candidate @?= Left (Failure (FailureDetail "settle Colima provider wall"
                                "the ownership backend returned a record outside the exact plan/fence namespace" DoNotRetry))
        either assertFailure pure accepted

staticUnownedSettlementCases :: TestTree
staticUnownedSettlementCases =
    testGroup "static unowned settlement"
        [ testCase "a refusal stays Conflict" $
            check (ColimaObservation.ColimaUnownedWallObservation (WallRefused conflict)) (Reconcile.Conflict conflict)
        , testCase "an acquisition failure stays Failure" $
            check (ColimaObservation.ColimaUnownedWallObservation (WallAcquireFailed failure)) (Reconcile.Failure failure)
        , testCase "an unsupported observation stays Unsupported" $
            check (ColimaObservation.ColimaWallOwnershipUnsupported unsupported) (Reconcile.Unsupported unsupported)
        ]
  where
    conflict = ConflictDetail "fixture provider" "owned" "foreign" "reprobe"
    failure = FailureDetail "fixture acquisition" "unavailable" ReprobeBeforeRetry
    unsupported = Reconcile.UnsupportedDetail "fixture wall" "unsupported host"
    check observation expected = do
        result <- withPreparedTestCall (\_ call -> settleColimaWallCall call observation (const ()))
        result @?= Right (Left expected)

nativeFixtureResolutionCases :: TestTree
nativeFixtureResolutionCases =
    testGroup "native fixture resolution result"
        [ conditionalCase family posixOwnershipSupported
            "a ready result retains the real private toolchain"
            (withResolverHarness "retained-ready" $ \harness -> do
                let layout = resolverHarnessLayout harness
                (_, result) <- executeNativeResolverFixtureWithSettlement (resolverFixtureRoot layout) (resolverFixtureHome layout)
                case result of
                    Resolver.TrustedResolverReady toolchain -> do
                        Resolver.trustedAppleColimaPath toolchain @?= resolverFixtureColimaTarget layout
                        Resolver.trustedAppleDockerPath toolchain @?= resolverFixtureDockerTarget layout
                        Resolver.trustedAppleLimaPath toolchain @?= resolverFixtureLimaTarget layout
                        assertBool "the observed fingerprint is retained" (not (null (Resolver.trustedAppleToolchainFingerprint toolchain)))
                        settlementView result @?= ResolverSettlementReady
                            (resolverFixtureColimaTarget layout)
                            (resolverFixtureDockerTarget layout) (resolverFixtureLimaTarget layout)
                            (Resolver.trustedAppleHelperPath toolchain) (Resolver.trustedAppleToolchainFingerprint toolchain)
                    _ -> assertFailure ("expected native ready result, got " <> show (settlementView result)))
            assertNativeFixtureUnsupported
        , conditionalCase family posixOwnershipSupported
            "a missing result retains the real private Brew evidence"
            (withResolverHarness "retained-missing" $ \harness -> do
                let layout = resolverHarnessLayout harness
                removeFile (resolverFixtureColimaAlias layout)
                (_, result) <- executeNativeResolverFixtureWithSettlement (resolverFixtureRoot layout) (resolverFixtureHome layout)
                case result of
                    Resolver.TrustedResolverMissingColima brew -> do
                        Resolver.trustedAppleBrewPath brew @?= resolverFixtureBrew layout
                        settlementView result @?= ResolverSettlementMissingColima
                            (resolverFixtureBrew layout) (Resolver.trustedAppleBrewHelperPath brew)
                    _ -> assertFailure ("expected native missing result, got " <> show (settlementView result)))
            assertNativeFixtureUnsupported
        ]
  where
    family = ["ColimaSpec", "native fixture resolution result"]

assertNativeFixtureUnsupported :: IO ()
assertNativeFixtureUnsupported =
    withSystemTempDirectory "hostbootstrap-native-fixture-unsupported" $ \root -> do
        (execution, result) <- executeNativeResolverFixtureWithSettlement root (root </> "home")
        settlementView result @?= ResolverSettlementUnsupported "apple-silicon-required"
        case execution of
            ResolverExecutionCompleted ExitSuccess wire "" ->
                parseResolverFixtureProtocolView root wire @?= Right (ResolverProtocolUnsupportedView "apple-silicon-required")
            other -> assertFailure ("expected the native unsupported result, got " <> show other)

executeNativeResolverFixtureView :: FilePath -> FilePath -> IO (ResolverExecutionFixture, ResolverSettlementView)
executeNativeResolverFixtureView root home = do
    (execution, result) <- executeNativeResolverFixtureWithSettlement root home
    pure (execution, settlementView result)

privateColimaIdentityCases :: TestTree
privateColimaIdentityCases =
    testGroup "private Colima identity algebra"
        [ testCase "owner tokens retain canonical UTF-8 hex fields" $
            ColimaIdentity.colimaOwnerToken "h-012345" "prøject" "production" "plan:abc" "provider:one" "host-root" 7 @?= owner
        , testCase "every owner-token field changes the identity independently" $
            distinct
                [ ColimaIdentity.colimaOwnerToken "h-012345" project "production" "plan:abc" "provider:one" "host-root" 7
                , ColimaIdentity.colimaOwnerToken "h-123456" project "production" "plan:abc" "provider:one" "host-root" 7
                , ColimaIdentity.colimaOwnerToken "h-012345" "other-project" "production" "plan:abc" "provider:one" "host-root" 7
                , ColimaIdentity.colimaOwnerToken "h-012345" project "harness" "plan:abc" "provider:one" "host-root" 7
                , ColimaIdentity.colimaOwnerToken "h-012345" project "production" "other-plan" "provider:one" "host-root" 7
                , ColimaIdentity.colimaOwnerToken "h-012345" project "production" "plan:abc" "other-provider" "host-root" 7
                , ColimaIdentity.colimaOwnerToken "h-012345" project "production" "plan:abc" "provider:one" "other-frame" 7
                , ColimaIdentity.colimaOwnerToken "h-012345" project "production" "plan:abc" "provider:one" "host-root" 8
                ]
        , testCase "origin filenames retain the first 128 digest bits" $ do
            assertBool "a different owner changes its origin filename"
                (ColimaIdentity.originRecordName (owner ++ "x") /= ColimaIdentity.originRecordName owner)
            ColimaIdentity.originRecordName owner @?= ".hostbootstrap-colima-b9ad086cf21363c02c3451d475ef3ec6.origin"
        , testCase "acquisition digests retain canonical domain and argument order" $
            acquire "h-012345" namespaceKey owner record 7 arguments @?= "1dd6d383090e7d8cccc91f5337b7fe2b79aafb39e14cbd5d8dc3da420f0e7f9e"
        , testCase "invocation digests retain the exact gate tuple" $
            invoke "1dd6d383090e7d8cccc91f5337b7fe2b79aafb39e14cbd5d8dc3da420f0e7f9e" "plan:abc" "provider-up" "s-1" 7 2 3 @?= "1aa23a0f74a8bda16f26578c2e0a35e897b0a67b1936dc545877c0155ea0f15d"
        , testCase "bound owners retain all four canonical digest groups" $
            bind owner namespace "toolchain-fingerprint" @?= owner ++ "-" ++ "bf79289cbe4a4252a0b2b449897c5e60e50cd70ca44f0aae0e0053e71eac2d2f-d582a66eb2457019dc01df8517059cc4db43e5432d47d13337d0f3901ca5c9bc-6bf26fdad5687b4ddce0fcb22b5deb2c6069ec70c9cbbd3f4f77aec108c863f2-fb94dd6d5b6eddd46fdc90dc4114edcd8791fd94679562d5d89744781f5fb675"
        , testCase "every bound owner input changes the identity independently" $
            distinct
                [ bind owner namespace "toolchain-fingerprint"
                , bind (owner ++ "x") namespace "toolchain-fingerprint"
                , bind owner namespace{namespaceColimaHome = "/other-colima"} "toolchain-fingerprint"
                , bind owner namespace{namespaceLimaHome = "/other-lima"} "toolchain-fingerprint"
                , bind owner namespace{namespaceColimaCacheHome = "/other-cache"} "toolchain-fingerprint"
                , bind owner namespace{namespaceTemporaryDirectory = "/other-tmp"} "toolchain-fingerprint"
                , bind owner namespace{namespaceDockerConfig = "/other-docker"} "toolchain-fingerprint"
                , bind owner namespace{namespaceExecutablePath = "/other-bin"} "toolchain-fingerprint"
                , bind owner namespace "other-fingerprint"
                ]
        , testCase "every acquisition input and argv order changes the digest" $
            distinct
                [ acquire "h-012345" namespaceKey owner record 7 arguments
                , acquire "h-123456" namespaceKey owner record 7 arguments
                , acquire "h-012345" "other-namespace" owner record 7 arguments
                , acquire "h-012345" namespaceKey (owner ++ "x") record 7 arguments
                , acquire "h-012345" namespaceKey owner (record ++ "x") 7 arguments
                , acquire "h-012345" namespaceKey owner record 8 arguments
                , acquire "h-012345" namespaceKey owner record 7 (arguments ++ ["extra"])
                , acquire "h-012345" namespaceKey owner record 7 (reverse arguments)
                ]
        , testCase "every invocation gate field changes the digest" $
            distinct
                [ invoke "1dd6d383090e7d8cccc91f5337b7fe2b79aafb39e14cbd5d8dc3da420f0e7f9e" "plan:abc" "provider-up" "s-1" 7 2 3
                , invoke "other-call" "plan:abc" "provider-up" "s-1" 7 2 3
                , invoke "1dd6d383090e7d8cccc91f5337b7fe2b79aafb39e14cbd5d8dc3da420f0e7f9e" "plan:other" "provider-up" "s-1" 7 2 3
                , invoke "1dd6d383090e7d8cccc91f5337b7fe2b79aafb39e14cbd5d8dc3da420f0e7f9e" "plan:abc" "provider-other" "s-1" 7 2 3
                , invoke "1dd6d383090e7d8cccc91f5337b7fe2b79aafb39e14cbd5d8dc3da420f0e7f9e" "plan:abc" "provider-up" "s-2" 7 2 3
                , invoke "1dd6d383090e7d8cccc91f5337b7fe2b79aafb39e14cbd5d8dc3da420f0e7f9e" "plan:abc" "provider-up" "s-1" 8 2 3
                , invoke "1dd6d383090e7d8cccc91f5337b7fe2b79aafb39e14cbd5d8dc3da420f0e7f9e" "plan:abc" "provider-up" "s-1" 7 3 3
                , invoke "1dd6d383090e7d8cccc91f5337b7fe2b79aafb39e14cbd5d8dc3da420f0e7f9e" "plan:abc" "provider-up" "s-1" 7 2 4
                ]
        ]
  where
    project = "prøject"
    owner = "v2-682d303132333435-7072c3b86a656374-70726f64756374696f6e-706c616e3a616263-70726f76696465723a6f6e65-686f73742d726f6f74-7"
    namespaceKey = "0123456789abcdef0123456789abcdef"
    record = "/state/.hostbootstrap/colima/.hostbootstrap-colima-b9ad086cf21363c02c3451d475ef3ec6.origin"
    arguments = ["start", "--profile", "h-012345", "--cpu", "8", "--memory", "16", "--disk", "80", "--root-disk", "20"]
    namespace = BackendNamespace "/home" "/home/.hns" "/home/.hns-lima" "/home/.hns/cache" "/home/.hns/tmp" "/state/.docker" "/work" "/trusted/bin"
    bind = ColimaIdentity.bindColimaOwner
    acquire = ColimaIdentity.colimaAcquireCallDigest
    invoke = ColimaIdentity.colimaInvocationDigest
    distinct values = length (nub values) @?= length values

privateSettlementProducerCases :: TestTree
privateSettlementProducerCases =
    testGroup "private Colima settlement producer"
        [ testCase "an applied result supplies created and the same wall epoch" $
            view (ColimaWallSettlementApplied 7) @?= (WallApplied 7, "created")
        , testCase "an exact result supplies repaired and the same wall epoch" $
            view (ColimaWallSettlementAlreadyExact 11) @?= (WallAlreadyExact 11, "repaired")
        ]
  where
    view :: ColimaWallSettlementObservation -> (WallAcquireObservation, String)
    view observation =
        withColimaWallSettlement observation $ \projection wall startResult ->
            case projection of
                ProviderStartProjectionAuthority ->
                    ( wall
                    , case startResult of
                        ProviderStartBackendCreated -> "created"
                        ProviderStartBackendRepaired -> "repaired"
                    )

resolverOwnerModeCases :: TestTree
resolverOwnerModeCases =
    testGroup "resolver owner/mode policy"
        [ testGroup label
            [ testCase "production layout" $
                resolverOwnerModePolicyView Nothing directory path owner mode 1000 @?= production
            , testCase "fixture layout" $
                resolverOwnerModePolicyView (Just "/fixture") directory ("/fixture" <> path) owner mode 1000 @?= fixture
            ]
        | (label, directory, path, owner, mode, production, fixture) <-
            [ ("root-owned system directory", True, "/usr/local/bin", 0, 0o755, Right (), Left "directory-owner")
            , ("user-owned system directory", True, "/usr/local/bin", 1000, 0o755, Left "directory-owner", Right ())
            , ("root-owned system executable", False, "/usr/local/bin/colima", 0, 0o755, Right (), Left "executable-owner")
            , ("user-owned system executable", False, "/usr/local/bin/colima", 1000, 0o755, Left "executable-owner", Right ())
            , ("root-owned Homebrew Cellar executable", False, "/opt/homebrew/Cellar/colima/1/bin/colima", 0, 0o755, Left "executable-owner", Left "executable-owner")
            , ("user-owned Homebrew Cellar executable", False, "/opt/homebrew/Cellar/colima/1/bin/colima", 1000, 0o755, Right (), Right ())
            , ("root-owned Docker Desktop executable", False, "/Applications/Docker.app/Contents/Resources/bin/docker", 0, 0o755, Right (), Left "executable-owner")
            , ("user-owned Docker Desktop executable", False, "/Applications/Docker.app/Contents/Resources/bin/docker", 1000, 0o755, Right (), Right ())
            , ("root-owned Docker Desktop directory", True, "/Applications/Docker.app/Contents/Resources/bin", 0, 0o755, Right (), Left "directory-owner")
            , ("user-owned Docker Desktop directory", True, "/Applications/Docker.app/Contents/Resources/bin", 1000, 0o755, Right (), Right ())
            , ("group-writable formula directory", True, "/opt/homebrew/Cellar/colima/1/bin", 1000, 0o775, Left "directory-group-write-homebrew", Left "directory-group-write")
            , ("group-writable Homebrew administrative directory", True, "/opt/homebrew/bin", 1000, 0o775, Right (), Right ())
            , ("group-writable executable", False, "/opt/homebrew/Cellar/colima/1/bin/colima", 1000, 0o775, Left "executable-write-mode", Left "executable-write-mode")
            , ("world-writable directory", True, "/opt/homebrew/Cellar/colima/1/bin", 1000, 0o757, Left "directory-world-write", Left "directory-world-write")
            , ("non-executable file", False, "/opt/homebrew/Cellar/colima/1/bin/colima", 1000, 0o644, Left "executable-mode", Left "executable-mode")
            , ("foreign-owned executable", False, "/opt/homebrew/Cellar/colima/1/bin/colima", 2000, 0o755, Left "executable-owner", Left "executable-owner")
            ]
        ]

-- Pure reports use the same layout as the native harness, on every host.
withResolverProtocolWires :: (ResolverFixtureLayout -> String -> String -> IO a) -> IO a
withResolverProtocolWires use =
    withSystemTempDirectory "hostbootstrap-resolver-protocol" $ \root -> do
        let layout = resolverFixtureLayout root
            bin = root </> "opt" </> "homebrew" </> "bin"
            readyTools = [resolverFixtureColimaTarget layout, resolverFixtureDockerTarget layout, resolverFixtureLimaTarget layout]
            readyHelpers = nub (map takeDirectory [resolverFixtureColimaTarget layout, resolverFixtureLimaTarget layout, resolverFixtureDockerTarget layout] ++ [bin] ++ resolverFixtureSystemHelpers layout)
            missingHelpers = bin : resolverFixtureSystemHelpers layout
            tool path = [path, "1", "2"]
            helperFields paths = [intercalate [searchPathSeparator] paths, intercalate ";" (map (intercalate "," . tool) paths)]
            ready = intercalate "\t" (["READY_V2"] ++ concatMap tool readyTools ++ helperFields readyHelpers) ++ "\n"
            missing = intercalate "\t" (["MISSING_COLIMA_V2"] ++ concatMap tool [resolverFixtureBrew layout] ++ helperFields missingHelpers) ++ "\n"
        case parseResolverFixtureProtocolView root ready of
            Right ResolverProtocolReadyV2View{} -> pure ()
            other -> assertFailure ("the valid READY fixture was not admitted: " <> show other)
        case parseResolverFixtureProtocolView root missing of
            Right ResolverProtocolMissingColimaV2View{} -> pure ()
            other -> assertFailure ("the valid MISSING_COLIMA fixture was not admitted: " <> show other)
        use layout ready missing

protocolContentCases :: TestTree
protocolContentCases =
    testGroup "exact content refusals"
        [ testCase label $
            withResolverProtocolWires $ \layout ready missing -> do
                let original = if useMissing then missing else ready
                    fields = splitProtocolField '\t' (init original)
                    wire = intercalate "\t" (mutate layout fields) ++ "\n"
                assertResolverRejected (resolverFixtureRoot layout) reason wire
        | (label, useMissing, reason, mutate) <-
            [ ("Colima outside the Cellar", False, "resolver-colima-path", \layout -> replaceProtocolField 1 (resolverFixtureRoot layout </> "outside" </> "colima"))
            , ("Colima parent version segment", False, "resolver-colima-path", \layout -> replaceProtocolField 1 (resolverFixtureRoot layout </> "opt" </> "homebrew" </> "Cellar" </> "colima" </> ".." </> "bin" </> "colima"))
            , ("Docker outside formula and app", False, "resolver-docker-path", \layout -> replaceProtocolField 4 (resolverFixtureRoot layout </> "outside" </> "docker"))
            , ("Lima wrong binary name", False, "resolver-lima-path", \layout -> replaceProtocolField 7 (takeDirectory (resolverFixtureLimaTarget layout) </> "wrong"))
            , ("Brew path mismatch", True, "resolver-brew-path", \layout -> replaceProtocolField 1 (resolverFixtureRoot layout </> "outside" </> "brew"))
            , ("relative tool path", False, "resolver-tool-path", \_ -> replaceProtocolField 1 "relative")
            , ("tool path delimiter", False, "resolver-tool-path", \layout -> replaceProtocolField 1 (resolverFixtureColimaTarget layout ++ ",decorated"))
            , ("malformed device", False, "resolver-tool-device", \_ -> replaceProtocolField 2 "x")
            , ("noncanonical device", False, "resolver-tool-device", \_ -> replaceProtocolField 2 "01")
            , ("malformed inode", False, "resolver-tool-inode", \_ -> replaceProtocolField 3 "x")
            , ("noncanonical inode", False, "resolver-tool-inode", \_ -> replaceProtocolField 3 "2 ")
            , ("zero device identity", False, "resolver-tool-identity", \_ -> replaceProtocolField 2 "0")
            , ("zero inode identity", False, "resolver-tool-identity", \_ -> replaceProtocolField 3 "0")
            , ("helper path mismatch", False, "resolver-helper-path", \_ -> replaceProtocolField 10 "")
            , ("reordered helper bindings", False, "resolver-helper-binding-paths", \_ fields -> replaceProtocolField 11 (intercalate ";" (reverse (splitProtocolField ';' (last fields)))) fields)
            , ("malformed helper binding", False, "resolver-helper-binding-shape", \_ -> replaceProtocolField 11 "path,1")
            , ("invalid unsupported reason", False, "resolver-invalid-reason", \_ _ -> ["UNSUPPORTED", "Invalid reason"])
            ]
        ]

replaceProtocolField :: Int -> String -> [String] -> [String]
replaceProtocolField index value = zipWith (\position old -> if position == index then value else old) [0 ..]

splitProtocolField :: Char -> String -> [String]
splitProtocolField separator value = case break (== separator) value of
    (field, []) -> [field]
    (field, _ : rest) -> field : splitProtocolField separator rest

resolverRevalidationTests :: TestTree
resolverRevalidationTests = testGroup "retained resolver revalidation"
    [ revalidationCase "unchanged ready evidence is admitted" False $ \harness retained ->
        assertNativeRevalidation harness retained (Right ())
    , revalidationCase "a new Colima inode refuses the retained ready toolchain" False $ \harness retained -> do
        replaceResolverTool (resolverFixtureColimaTarget (resolverHarnessLayout harness))
        assertNativeRevalidation harness retained (Left "trusted-apple-toolchain-changed")
    , revalidationCase "missing Colima refuses the retained ready toolchain" False $ \harness retained -> do
        removeFile (resolverFixtureColimaAlias (resolverHarnessLayout harness))
        assertNativeRevalidation harness retained (Left "trusted-colima-missing")
    , revalidationCase "unchanged missing-Colima evidence is admitted" True $ \harness retained ->
        assertNativeRevalidation harness retained (Right ())
    , revalidationCase "a new Brew inode refuses the retained missing branch" True $ \harness retained -> do
        replaceResolverTool (resolverFixtureBrew (resolverHarnessLayout harness))
        assertNativeRevalidation harness retained (Left "trusted-apple-brew-changed")
    , revalidationCase "newly present Colima refuses the retained missing branch" True $ \harness retained -> do
        let layout = resolverHarnessLayout harness
        createRelativeFileLink (resolverFixtureColimaTarget layout) (resolverFixtureColimaAlias layout)
        assertNativeRevalidation harness retained (Left "trusted-colima-now-present")
    , revalidationCase "ready revalidation preserves the native refusal reason" False $ \harness retained -> do
        chmodPath harness (resolverFixtureColimaTarget (resolverHarnessLayout harness)) "0777"
        assertNativeRevalidation harness retained (Left "executable-write-mode")
    , revalidationCase "Brew revalidation preserves the native refusal reason" True $ \harness retained -> do
        chmodPath harness (resolverFixtureBrew (resolverHarnessLayout harness)) "0777"
        assertNativeRevalidation harness retained (Left "executable-write-mode")
    , testCase "the native fingerprint is stable until a tool identity changes" $ onOwnershipHost $
        withResolverHarness "fingerprint" $ \harness -> do
            original <- nativeFixtureFingerprint harness
            repeated <- nativeFixtureFingerprint harness
            repeated @?= original
            replaceResolverTool (resolverFixtureColimaTarget (resolverHarnessLayout harness))
            changed <- nativeFixtureFingerprint harness
            assertBool "the changed tool identity changes the complete fingerprint" (changed /= original)
    ]
  where
    revalidationCase label missing action = testCase label $ onOwnershipHost $
        withResolverHarness "revalidation" $ \harness -> do
            if missing then removeFile (resolverFixtureColimaAlias (resolverHarnessLayout harness)) else pure ()
            (retained, view) <- observeNativeFixture harness
            case (missing, view) of
                (False, ResolverProtocolReadyV2View{}) -> pure ()
                (True, ResolverProtocolMissingColimaV2View{}) -> pure ()
                _ -> assertFailure ("the fixture did not produce the retained branch: " <> show view)
            action harness retained

observeNativeFixture :: ResolverHarness -> IO (ResolverExecutionFixture, ResolverProtocolView)
observeNativeFixture harness = do
    let layout = resolverHarnessLayout harness
    execution <- executeNativeResolverFixture (resolverFixtureRoot layout) (resolverFixtureHome layout)
    case execution of
        ResolverExecutionCompleted ExitSuccess wire "" -> do
            view <- either (assertFailure . ("native fixture protocol: " <>)) pure
                (parseResolverFixtureProtocolView (resolverFixtureRoot layout) wire)
            pure (execution, view)
        other -> assertFailure ("expected a native fixture observation: " <> show other)

assertNativeRevalidation :: ResolverHarness -> ResolverExecutionFixture -> Either String () -> IO ()
assertNativeRevalidation harness retained expected = do
    let layout = resolverHarnessLayout harness
    (fresh, _) <- observeNativeFixture harness
    revalidateResolverFixtureView (resolverFixtureRoot layout) (resolverFixtureHome layout)
        retained fresh @?= expected

-- Keep the original object alive under another name, excluding inode reuse.
replaceResolverTool :: FilePath -> IO ()
replaceResolverTool path = do
    renameFile path (path <> ".retained")
    writeResolverTool path

nativeFixtureFingerprint :: ResolverHarness -> IO String
nativeFixtureFingerprint harness = do
    let layout = resolverHarnessLayout harness
    (_, settled) <- executeNativeResolverFixtureView (resolverFixtureRoot layout) (resolverFixtureHome layout)
    case settled of
        ResolverSettlementReady _ _ _ _ fingerprint -> pure fingerprint
        other -> assertFailure ("expected a native ready fingerprint: " <> show other)

data ResolverHarness = ResolverHarness
    { resolverHarnessLayout :: ResolverFixtureLayout
    , resolverHarnessNamespace :: BackendNamespace
    }

-- The single bracketed ambient-state probe; PortabilitySpec pins its PATH binding.
runHostileResolverFixture :: ResolverHarness -> IO ()
runHostileResolverFixture harness = do
    let layout = resolverHarnessLayout harness
        namespace = resolverHarnessNamespace harness
        directories = [namespaceExecutablePath namespace, namespaceHomeDirectory namespace, namespaceWorkingDirectory namespace]
    mapM_ (\directory -> mapM_ (writeResolverTool . (directory </>)) ["colima", "docker", "limactl"]) directories
    (execution, settled) <-
        bracket
            (mapM (\name -> (,) name <$> lookupEnv name) ["PATH", "HOME"])
            (mapM_ (\(name, value) -> maybe (unsetEnv name) (setEnv name) value))
            (\_ -> do
                setEnv "PATH" (namespaceExecutablePath namespace)
                setEnv "HOME" (namespaceHomeDirectory namespace)
                lookupEnv "PATH" >>= (@?= Just (namespaceExecutablePath namespace))
                lookupEnv "HOME" >>= (@?= Just (namespaceHomeDirectory namespace))
                withCurrentDirectory (namespaceWorkingDirectory namespace) $
                    executeNativeResolverFixtureView (resolverFixtureRoot layout) (resolverFixtureHome layout)
            )
    case execution of
        ResolverExecutionCompleted ExitSuccess _ "" -> pure ()
        other -> assertFailure ("hostile ambient resolution did not complete: " <> show other)
    case settled of
        ResolverSettlementReady colima docker lima _ _ -> do
            colima @?= resolverFixtureColimaTarget layout
            docker @?= resolverFixtureDockerTarget layout
            lima @?= resolverFixtureLimaTarget layout
        other -> assertFailure ("hostile ambient resolution changed its fixed candidates: " <> show other)

-- Restrict only this real child, after its runtime and ready fixture are warm.
-- lstat still succeeds at this limit; open(2) must refuse a new descriptor.
runResolverDescriptorLimitProbe :: FilePath -> FilePath -> IO ()
#if defined(mingw32_HOST_OS)
runResolverDescriptorLimitProbe _ _ = assertFailure "descriptor limits are unavailable on Windows"
#else
runResolverDescriptorLimitProbe root home = do
    warm <- executeNativeResolverFixture root home
    case warm of
        ResolverExecutionCompleted ExitSuccess wire "" ->
            case parseResolverFixtureProtocolView root wire of
                Right ResolverProtocolReadyV2View{} -> pure ()
                other -> assertFailure ("descriptor probe requires a ready fixture: " <> show other)
        other -> assertFailure ("descriptor probe warmup failed: " <> show other)
    limits <- PosixResource.getResourceLimit PosixResource.ResourceOpenFiles
    let constrained = limits{PosixResource.softLimit = PosixResource.ResourceLimit 0}
    observed <-
        (PosixResource.setResourceLimit PosixResource.ResourceOpenFiles constrained
            >> executeNativeResolverFixture root home)
            `finally` PosixResource.setResourceLimit PosixResource.ResourceOpenFiles limits
    case observed of
        ResolverExecutionCompleted ExitSuccess wire "" ->
            parseResolverFixtureProtocolView root wire
                @?= Right (ResolverProtocolUnsupportedView "resolver-system-error")
        other -> assertFailure ("expected descriptor access refusal: " <> show other)
    putStrLn "resolver-descriptor-refused"
#endif

withResolverHarness :: String -> (ResolverHarness -> IO a) -> IO a
withResolverHarness label action =
    withSystemTempDirectory ("hostbootstrap-colima-resolver-" ++ label) $ \root ->
        setupResolverHarness root >>= action

setupResolverHarness :: FilePath -> IO ResolverHarness
setupResolverHarness root = do
    let layout = resolverFixtureLayout root
        ambient = root </> "ambient"
        namespace =
            BackendNamespace
                { namespaceHomeDirectory = ambient </> "home"
                , namespaceColimaHome = ambient </> "colima"
                , namespaceLimaHome = ambient </> "lima"
                , namespaceColimaCacheHome = ambient </> "cache"
                , namespaceTemporaryDirectory = ambient </> "tmp"
                , namespaceDockerConfig = ambient </> "docker"
                , namespaceWorkingDirectory = ambient </> "cwd"
                , namespaceExecutablePath = ambient </> "bin"
                }
        directories =
            [ resolverFixtureHome layout
            , takeDirectory (resolverFixtureBrew layout)
            , takeDirectory (resolverFixtureColimaTarget layout)
            , takeDirectory (resolverFixtureDockerTarget layout)
            , takeDirectory (resolverFixtureLimaTarget layout)
            , takeDirectory (resolverFixtureDockerApp layout)
            , namespaceHomeDirectory namespace
            , namespaceColimaHome namespace
            , namespaceLimaHome namespace
            , namespaceColimaCacheHome namespace
            , namespaceTemporaryDirectory namespace
            , namespaceDockerConfig namespace
            , namespaceWorkingDirectory namespace
            , namespaceExecutablePath namespace
            ]
                ++ resolverFixtureSystemHelpers layout
    mapM_ (createDirectoryIfMissing True) directories
    mapM_
        writeResolverTool
        [ resolverFixtureBrew layout
        , resolverFixtureColimaTarget layout
        , resolverFixtureDockerTarget layout
        , resolverFixtureLimaTarget layout
        , resolverFixtureDockerApp layout
        ]
    createRelativeFileLink (resolverFixtureColimaTarget layout) (resolverFixtureColimaAlias layout)
    createRelativeFileLink (resolverFixtureDockerTarget layout) (resolverFixtureDockerAlias layout)
    createRelativeFileLink (resolverFixtureLimaTarget layout) (resolverFixtureLimaAlias layout)
    pure
        ResolverHarness
            { resolverHarnessLayout = layout
            , resolverHarnessNamespace = namespace
            }

createRelativeFileLink :: FilePath -> FilePath -> IO ()
createRelativeFileLink target alias =
    createFileLink (repoRelativePath (takeDirectory alias) target) alias

writeResolverTool :: FilePath -> IO ()
writeResolverTool path = do
    writeFile path "resolver-candidate\n"
    makeExecutable path

executeResolverFixture :: ResolverHarness -> IO BoundedToolResult
executeResolverFixture harness =
    executeResolverFixtureAt harness (resolverFixtureHome (resolverHarnessLayout harness))

executeResolverFixtureAt :: ResolverHarness -> FilePath -> IO BoundedToolResult
executeResolverFixtureAt harness effectiveHome = do
    execution <- executeNativeResolverFixture (resolverFixtureRoot (resolverHarnessLayout harness)) effectiveHome
    pure $ case execution of
        ResolverExecutionCompleted code out err -> BoundedToolCompleted code out err
        ResolverExecutionTimedOut -> BoundedToolTimedOut
        ResolverExecutionFailed refusal -> BoundedToolFailed refusal

requireReadyResolver :: ResolverHarness -> BoundedToolResult -> IO (String, ResolverProtocolView)
requireReadyResolver harness execution =
    case execution of
        BoundedToolCompleted ExitSuccess output "" -> do
            protocol <-
                either
                    (assertFailure . ("fixture resolver report failed strict decoding: " ++))
                    pure
                    (parseResolverFixtureProtocolView (resolverFixtureRoot (resolverHarnessLayout harness)) output)
            case parseResolverProtocolView output of
                Left _ -> pure ()
                Right _ -> assertFailure "the production-layout parser accepted fixture-root authority"
            case protocol of
                ResolverProtocolReadyV2View{} -> pure (output, protocol)
                other -> assertFailure ("expected ready fixture resolver, got " ++ show other)
        other -> assertFailure ("expected a successful fixture resolver, got " ++ show other)

requireUnsupportedResolver :: ResolverHarness -> BoundedToolResult -> String -> IO ()
requireUnsupportedResolver harness execution reason =
    case execution of
        BoundedToolCompleted ExitSuccess output "" ->
            parseResolverFixtureProtocolView (resolverFixtureRoot (resolverHarnessLayout harness)) output
                @?= Right (ResolverProtocolUnsupportedView reason)
        other -> assertFailure ("expected a structured unsupported resolver report, got " ++ show other)

assertResolverRejected :: FilePath -> String -> String -> IO ()
assertResolverRejected root reason output =
    parseResolverFixtureProtocolView root output @?= Left reason

resolverFingerprint :: ResolverProtocolView -> String
resolverFingerprint protocol = case protocol of
    ResolverProtocolReadyV2View _ _ _ _ fingerprint -> fingerprint
    ResolverProtocolMissingColimaV2View _ _ fingerprint -> fingerprint
    ResolverProtocolUnsupportedView reason -> "unsupported:" ++ reason

chmodPath :: ResolverHarness -> FilePath -> String -> IO ()
#if defined(mingw32_HOST_OS)
chmodPath _ _ _ = assertFailure "resolver chmod is unavailable on Windows"
#else
chmodPath _ path "0777" = setFileMode path 0o777
chmodPath _ _ mode = assertFailure ("unsupported fixture chmod mode: " ++ mode)
#endif

makeExecutable :: FilePath -> IO ()
makeExecutable path = do
    permissions <- getPermissions path
    setPermissions path permissions{executable = True}

onOwnershipHost :: IO () -> IO ()
onOwnershipHost action = conditionalAction ["ColimaSpec"] posixOwnershipSupported action (pure ())

assertWindowsOwnershipRefusal :: IO ()
assertWindowsOwnershipRefusal
    | os /= "mingw32" = pure ()
    | otherwise = withSystemTempDirectory "hostbootstrap-colima-unsupported" $ \root -> do
        -- rationale.md: a skipped case cannot prove the frame's declared refusal.
        observed <- executeNativeResolverFixture root (root </> "Users" </> "fixture")
        case observed of
            ResolverExecutionCompleted ExitSuccess wire "" ->
                parseResolverFixtureProtocolView root wire
                    @?= Right (ResolverProtocolUnsupportedView "apple-silicon-required")
            other -> assertFailure ("expected the native resolver's Windows refusal, got " ++ show other)
        shipped <- try runShippedCommandEntry :: IO (Either IOException ())
        case shipped of
            Left failure ->
                assertBool
                    "the shipped entry names its Windows refusal"
                    ("the Colima command transaction is unavailable on Windows" `isInfixOf` displayException failure)
            Right () -> assertFailure "the shipped entry accepted a Windows transaction"

readEveryTestFile :: FilePath -> IO [(FilePath, String)]
readEveryTestFile directory = do
    names <- listDirectory directory
    nested <- traverse readEntry names
    pure (concat nested)
  where
    readEntry name = do
        let path = directory </> name
        isDirectory <- doesDirectoryExist path
        if isDirectory
            then readEveryTestFile path
            else do
                source <- strictReadFile path
                pure [(path, source)]

strictReadFile :: FilePath -> IO String
strictReadFile path = do
    contents <- readFile path
    seq (length contents) (pure contents)

validProcessId :: String -> Bool
validProcessId pid = case pid of
    leading : digits -> leading `elem` ['1' .. '9'] && all (`elem` ['0' .. '9']) digits
    [] -> False

waitForPidGone :: FilePath -> String -> IO ()
waitForPidGone python pid = do
    assertBool "the child publishes a positive ASCII decimal PID" (validProcessId pid)
    result <- timeout 5000000 loop
    case result of
        Just () -> pure ()
        Nothing -> assertFailure ("runner left process " ++ pid ++ " alive")
  where
    loop = do
        observed <-
            readProcessWithExitCode
                python
                [ "-c"
                , "import os,sys\ntry: os.kill(int(sys.argv[1]),0)\nexcept ProcessLookupError: sys.exit(3)"
                , pid
                ]
                ""
        case observed of
            (ExitFailure 3, "", "") -> pure ()
            (ExitSuccess, "", "") -> threadDelay 10000 >> loop
            other -> assertFailure ("the child PID probe failed: " <> show other)

waitForPath :: FilePath -> IO ()
waitForPath target = do
    observed <- timeout 5000000 loop
    case observed of
        Just () -> pure ()
        Nothing -> assertFailure ("timed out waiting for a positive PID in " ++ target)
  where
    loop = do
        present <- doesFileExist target
        if present
            then do
                contents <- strictReadFile target
                if validProcessId contents then pure () else threadDelay 10000 >> loop
            else threadDelay 10000 >> loop

boundedShippedRunnerTests :: TestTree
boundedShippedRunnerTests = testGroup "bounded shipped runner"
    [ runnerCase "non-ASCII arguments reach the supervised child unchanged" $ \_ python namespace -> do
        observed <- runShippedCommand 3 namespace python
            ["-c", "import sys; sys.stdout.buffer.write(sys.argv[1].encode('utf-8'))", "\x00e9\x015c"]
        observed @?= BoundedToolCompleted ExitSuccess "\x00e9\x015c" ""
    , runnerCase "unencodable command arguments are refused" $ \_ python namespace -> do
        runShippedCommand 3 namespace python ["\xD800"] >>= (@?= BoundedToolFailed "invalid-command-encoding")
        -- The wire cannot carry an embedded NUL either.
        runShippedCommand 3 namespace python ["bad\0argument"] >>= (@?= BoundedToolFailed "invalid-command-encoding")
    , runnerCase "timeout kills a TERM-ignoring descendant" $ \directory python namespace -> do
        let pidPath = directory </> "descendant.pid"
        observed <- runShippedCommand 1 namespace python ["-c", runnerDescendantProgram False False, pidPath]
        observed @?= BoundedToolTimedOut
        strictReadFile pidPath >>= waitForPidGone python
    , runnerCase "output beyond the retention ceiling is an explicit failure" $ \_ python namespace -> do
        observed <- runShippedCommand 5 namespace python
            ["-c", "import sys; sys.stdout.buffer.write(b'x' * (16 * 1024 * 1024 + 1)); sys.stdout.buffer.flush()"]
        observed @?= BoundedToolFailed "output-limit"
    , runnerCase "leader exit quiesces a descendant retaining both pipes" $ \directory python namespace ->
        assertLeaderDescendant directory python namespace False
    , runnerCase "leader exit quiesces a descendant that has closed both pipes" $ \directory python namespace ->
        assertLeaderDescendant directory python namespace True
    , runnerCase "an escaped pipe writer cannot extend the capture deadline" $ \directory python namespace -> do
        let pidPath = directory </> "escaped.pid"
            releaseWriter = do
                writeFile (pidPath <> ".cleanup") "release\n"
                published <- doesFileExist pidPath
                if published then strictReadFile pidPath >>= waitForPidGone python else pure ()
        observed <- timeout 5000000
            (runShippedCommand 1 namespace python ["-c", runnerEscapedWriterProgram, pidPath])
            `finally` releaseWriter
        observed @?= Just BoundedToolTimedOut
        waitForPath pidPath
        strictReadFile pidPath >>= waitForPidGone python
    , runnerCase "thread cancellation propagates ThreadKilled and quiesces descendants" $ \directory python namespace -> do
        let pidPath = directory </> "descendant.pid"
        finished <- newEmptyMVar
        thread <- forkIO $ do
            observed <- try (runShippedCommand 15 namespace python ["-c", runnerDescendantProgram False False, pidPath])
                :: IO (Either SomeException BoundedToolResult)
            putMVar finished observed
        waitForPath pidPath
        pid <- strictReadFile pidPath
        killThread thread
        settled <- timeout 15000000 (takeMVar finished)
        case settled of
            Just (Left failure) -> fromException failure @?= Just ThreadKilled
            other -> assertFailure ("expected unchanged ThreadKilled within the teardown bound: " <> show other)
        waitForPidGone python pid
    , runnerCase "the tool reads zero bytes from its null-device standard input" $ \_ python namespace -> do
        observed <- runShippedCommand 3 namespace python ["-c", "import sys; print(len(sys.stdin.buffer.read()))"]
        observed @?= BoundedToolCompleted ExitSuccess "0\n" ""
    ]
  where
    runnerCase label action = testCase label $ onOwnershipHost $
        withSystemTempDirectory "hostbootstrap-colima-runner" $ \directory -> do
            python <- requireExecutable "python3" =<< findExecutable "python3"
            bounded <- timeout 20000000 (action directory python (runnerFixtureNamespace directory))
            case bounded of
                Just () -> pure ()
                Nothing -> assertFailure "shipped runner exceeded the command and teardown bounds"

assertLeaderDescendant :: FilePath -> FilePath -> BackendNamespace -> Bool -> IO ()
assertLeaderDescendant directory python namespace closePipes = do
    let pidPath = directory </> "descendant.pid"
    observed <- runShippedCommand 3 namespace python ["-c", runnerDescendantProgram True closePipes, pidPath]
    observed @?= BoundedToolCompleted ExitSuccess "leader-complete\n" ""
    strictReadFile pidPath >>= waitForPidGone python

-- Both processes are real OS children. The descendant installs its TERM handler
-- before publishing its PID, and has a finite lifetime even for a failing probe.
runnerDescendantProgram :: Bool -> Bool -> String
runnerDescendantProgram leaderExits closePipes = unlines
    [ "import os,subprocess,sys,time"
    , "path=sys.argv[1]"
    , "descendant=" <> show ("import os,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); path=sys.argv[1]; stream=open(path+'.pending','w'); stream.write(str(os.getpid())); stream.close(); os.replace(path+'.pending',path); time.sleep(10)" :: String)
    , "sink=" <> if closePipes then "subprocess.DEVNULL" else "None"
    , "subprocess.Popen([sys.executable,'-c',descendant,path],stdout=sink,stderr=sink,close_fds=True)"
    , "while not os.path.exists(path): time.sleep(0.001)"
    , "print('leader-complete',flush=True)"
    , if leaderExits then "sys.exit(0)" else "time.sleep(10)"
    ]

-- This writer deliberately leaves the retained group. Its private cleanup
-- marker lets the fixture stop it without sending a signal to a bare PID.
runnerEscapedWriterProgram :: String
runnerEscapedWriterProgram = unlines
    [ "import os,subprocess,sys,time"
    , "path=sys.argv[1]"
    , "descendant=" <> show descendant
    , "subprocess.Popen([sys.executable,'-c',descendant,path],start_new_session=True,close_fds=True)"
    , "while not os.path.exists(path): time.sleep(0.001)"
    ]
  where
    descendant = unlines
        [ "import os,signal,sys,time"
        , "signal.signal(signal.SIGTERM,signal.SIG_IGN)"
        , "path=sys.argv[1]"
        , "stream=open(path+'.pending','w'); stream.write(str(os.getpid())); stream.close(); os.replace(path+'.pending',path)"
        , "deadline=time.monotonic()+30"
        , "while time.monotonic()<deadline and not os.path.exists(path+'.cleanup'): time.sleep(0.01)"
        ]

runnerFixtureNamespace :: FilePath -> BackendNamespace
runnerFixtureNamespace directory =
    BackendNamespace
        { namespaceHomeDirectory = directory
        , namespaceColimaHome = directory
        , namespaceLimaHome = directory
        , namespaceColimaCacheHome = directory
        , namespaceTemporaryDirectory = directory
        , namespaceDockerConfig = directory
        , namespaceWorkingDirectory = directory
        , namespaceExecutablePath = "/usr/bin:/bin"
        }

runShippedOwnerProbe :: FilePath -> FilePath -> FilePath -> IO ()
runShippedOwnerProbe directory pidPath python = do
    let namespace =
            BackendNamespace
                { namespaceHomeDirectory = directory
                , namespaceColimaHome = directory
                , namespaceLimaHome = directory
                , namespaceColimaCacheHome = directory
                , namespaceTemporaryDirectory = directory
                , namespaceDockerConfig = directory
                , namespaceWorkingDirectory = directory
                , namespaceExecutablePath = "/usr/bin:/bin"
                }
        program =
            "import os,signal,sys,time\n"
                ++ "signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
                ++ "path=sys.argv[1]; stream=open(path+'.pending','w'); stream.write(str(os.getpid())); stream.close(); os.replace(path+'.pending',path)\n"
                ++ "time.sleep(30)\n"
    _ <- runShippedCommand 60 namespace python ["-c", program, pidPath]
    pure ()

requireExecutable :: String -> Maybe FilePath -> IO FilePath
requireExecutable _label (Just path) = pure path
requireExecutable label Nothing = assertFailure ("missing test executable: " ++ label)

withPreparedPublicTestCallM ::
    ( forall
        projectId
        specDigest
        planId
        configId
        providerResourceId
        providerFrame
        clusterResourceId
        clusterFrame
        budgetId
        capabilityId
        wallSpecId
        workloadSetId
        partitionId
        reservationId
        fence.
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      PlannedResource
        (Production projectId)
        planId
        providerResourceId
        ProviderResource
        providerFrame ->
      PlannedResource
        (Production projectId)
        planId
        clusterResourceId
        ClusterResource
        clusterFrame ->
      PreparedGate ->
      IO PreparedGate ->
      Text.Text ->
      PreparedColimaWallCall
        (Production projectId)
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
      IO result
    ) ->
    IO (Either String result)
withPreparedPublicTestCallM consume = do
    withTestProjectResources $ \plan expectedProject providerResource clusterResource -> do
        let planDigest = stablePlanSnapshotDigest (renderSnapshot plan)
            operation = plannedResourceKey providerResource
        withSuccessorGate planDigest operation "session-1" 1 1 2 $ \_store gate nextGate ->
            withPreparedTestCallForGate plan providerResource clusterResource gate $
                consume plan providerResource clusterResource gate nextGate expectedProject

withPreparedTestCallForGate ::
    ProjectPlan scope specDigest planId configId Fixture.ProjectConfig ->
    PlannedResource scope planId providerResourceId ProviderResource providerFrame ->
    PlannedResource scope planId clusterResourceId ClusterResource clusterFrame ->
    PreparedGate ->
    ( forall
        budgetId
        capabilityId
        wallSpecId
        workloadSetId
        partitionId
        reservationId
        fence.
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
      IO result
    ) ->
    IO (Either String result)
withPreparedTestCallForGate plan providerResource clusterResource gate consume =
    withPreparedTestCallForGateAndEnvelope plan providerResource clusterResource gate (\call _ -> consume call)

withPreparedTestCallForGateAndEnvelope ::
    ProjectPlan scope specDigest planId configId Fixture.ProjectConfig ->
    PlannedResource scope planId providerResourceId ProviderResource providerFrame ->
    PlannedResource scope planId clusterResourceId ClusterResource clusterFrame ->
    PreparedGate ->
    ( forall
        budgetId
        capabilityId
        wallSpecId
        workloadSetId
        partitionId
        reservationId
        fence.
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
      TestColimaEnvelope ->
      IO result
    ) ->
    IO (Either String result)
withPreparedTestCallForGateAndEnvelope plan providerResource clusterResource gate consume = do
    let prepared = do
            workload <- first show (mkWorkload clusterResource 1 1 gib gib)
            overhead <- first show (mkResourceBudget 1 gib gib)
            sliceBudget <- first show (mkResourceBudget 6 (10 * gib) (80 * gib))
            minimumBudget <- first show (mkResourceBudget 1 gib gib)
            request <- first show (mkSliceRequest providerResource sliceBudget minimumBudget)
            flattenBudget $
                withValidatedBudget plan $ \validated ->
                    withProviderBudgetCapability plan providerResource ColimaProviderKey $ \capability ->
                        flattenBudget $
                            admitProviderBudget validated capability $ \wall effective ->
                                flattenBudget $
                                    withPlannedWorkloadSet plan [workload] $ \workloads -> do
                                        fit <- first show (verifyPlannedWorkloadFit effective workloads)
                                        flattenBudget $
                                            withBudgetPartition effective fit overhead (request :| []) $ \partition _ ->
                                                flattenBudget $
                                                    withProviderWallReservation plan providerResource wall partition gate $ \reservation ->
                                                        first show $
                                                            withObservedProjectResource plan providerResource 17 7 $ \providerHandle -> do
                                                                result <-
                                                                    prepareColimaWallCall
                                                                        plan
                                                                        providerResource
                                                                        providerHandle
                                                                        (topology plan)
                                                                        validated
                                                                        capability
                                                                        wall
                                                                        fit
                                                                        partition
                                                                        reservation
                                                                        gate
                                                                case result of
                                                                    Left failure -> pure (Left (show failure))
                                                                    Right call -> do
                                                                        let snapshot = renderSnapshot plan
                                                                            stateRoot = stablePlanSnapshotRoot snapshot
                                                                        (profile, namespaceKey) <- OwnershipFixture.expectRight $
                                                                            ColimaNames.deriveColimaNames (projectPlanProjectName plan) (projectPlanProfileName plan)
                                                                                (plannedResourceKey providerResource) (plannedResourceFrame providerResource) stateRoot
                                                                        generic <- OwnershipFixture.expectRight $
                                                                            preparePlanOwnedProviderWallCall plan providerResource (topology plan)
                                                                                validated capability wall fit partition reservation profile
                                                                        profile @?= preparedColimaProfileName call
                                                                        let ownerSeed = ColimaIdentity.colimaOwnerToken profile (projectPlanProjectName plan)
                                                                                (projectPlanProfileName plan) (Text.unpack (stablePlanSnapshotDigest snapshot))
                                                                                (plannedResourceKey providerResource) (plannedResourceFrame providerResource)
                                                                                (providerWallCallFence generic)
                                                                            recordPath = stateRoot </> ".hostbootstrap" </> "colima" </> ColimaIdentity.originRecordName ownerSeed
                                                                            callDigest = ColimaIdentity.colimaAcquireCallDigest profile namespaceKey ownerSeed recordPath
                                                                                (providerWallCallFence generic) (providerWallCallArgs generic)
                                                                            complete observation = do
                                                                                nested <- Reconcile.withPreparedProviderStart plan providerResource providerHandle callDigest gate $ \start ->
                                                                                    withColimaWallSettlement observation $ \_ _ outcome -> do
                                                                                        reconciled <- Reconcile.completePreparedProviderStart start outcome
                                                                                        Reconcile.withReconcileResult reconciled
                                                                                            (\handle receipt change -> do
                                                                                                Reconcile.validateOwnershipReceipt handle receipt
                                                                                                pure (Reconcile.resourceHandleGeneration handle, change))
                                                                                            (\_ _ -> Left (Failure (FailureDetail "fixture provider start" "foreign provider result" DoNotRetry)))
                                                                                nested
                                                                            envelope = TestColimaEnvelope stateRoot namespaceKey ownerSeed recordPath callDigest
                                                                                (testColimaInvocation callDigest gate) complete
                                                                        Right <$> consume call envelope
    case prepared of
        Left failure -> pure (Left failure)
        Right action -> action

withPreparedTestCallM ::
    ( forall
        projectId
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
        fence.
      Text.Text ->
      PreparedColimaWallCall
        (Production projectId)
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
      IO result
    ) ->
    IO (Either String result)
withPreparedTestCallM consume =
    withPreparedPublicTestCallM (\_plan _provider _cluster _gate _nextGate project call -> consume project call)

withPreparedTestCall ::
    ( forall
        projectId
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
        fence.
      Text.Text ->
      PreparedColimaWallCall
        (Production projectId)
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
      result
    ) ->
    IO (Either String result)
withPreparedTestCall consume =
    withPreparedTestCallM (\project call -> pure (consume project call))

-- The coverage manifest and its case share one process-wide gate decision.
{-# NOINLINE colimaLiveAvailable #-}
colimaLiveAvailable :: Bool
colimaLiveAvailable = unsafePerformIO $ do
    requested <- lookupEnv "HOSTBOOTSTRAP_COLIMA_LIVE"
    colimaBinary <- findExecutable "colima"
    pure (requested == Just "1" && os == "darwin" && arch == "aarch64" && isJust colimaBinary)

reportColimaLiveUnavailable :: IO ()
reportColimaLiveUnavailable = do
    requested <- lookupEnv "HOSTBOOTSTRAP_COLIMA_LIVE"
    case requested of
        Nothing -> putStrLn "direct-Colima live lane not requested"
        Just "1"
            | os /= "darwin" || arch /= "aarch64" -> putStrLn "Unsupported: direct-Colima live lane requires Apple Silicon"
            | otherwise -> putStrLn "Unsupported: Colima is not installed"
        Just value -> assertFailure ("HOSTBOOTSTRAP_COLIMA_LIVE must be unset or 1, got " ++ show value)

runNativeColimaAcceptance :: IO ()
runNativeColimaAcceptance = do
    colima <- requireExecutable "colima" =<< findExecutable "colima"
    docker <- requireExecutable "docker" =<< findExecutable "docker"
    ambientProfilesBefore <- requireNativeCommand colima ["list", "--json"]
    ambientContextBefore <- requireNativeCommand docker ["context", "show"]
    let conflictingResources = Fixture.Resources 9 "16GiB" "100GiB"
    accepted <-
        Fixture.withFixtureProjectPlanConfigPair
            (selectResources exactResources)
            (selectResources conflictingResources)
            testPlan $ \plan value conflictingPlan conflictingValue -> do
                Fixture.resources value @?= exactResources
                Fixture.resources conflictingValue @?= conflictingResources
                let expectedProject = Context.project (Fixture.context value)
                    planDigest = stablePlanSnapshotDigest (renderSnapshot plan)
                    conflictingDigest = stablePlanSnapshotDigest (renderSnapshot conflictingPlan)
                Context.project (Fixture.context conflictingValue) @?= expectedProject
                assertBool "the admitted budget alternatives have different plan digests" (planDigest /= conflictingDigest)
                withTestPlanResources plan $ \providerResource clusterResource ->
                    withTestPlanResources conflictingPlan $ \conflictingProvider conflictingCluster ->
                        withSuccessorGate planDigest (plannedResourceKey providerResource) "session-1" 1 1 2 $ \_store gate nextGate ->
                            withSuccessorGate conflictingDigest (plannedResourceKey conflictingProvider) "session-1" 1 1 2 $ \_conflictingStore conflictingGate _nextConflictingGate ->
                                withPreparedTestCallForGate plan providerResource clusterResource gate $ \call -> do
                                    preparedConflict <- withPreparedTestCallForGate conflictingPlan conflictingProvider conflictingCluster conflictingGate $ \conflictingCall -> do
                                        let profile = preparedColimaProfileName call
                                        preparedColimaProfileName conflictingCall @?= profile
                                        putStrLn ("direct-colima-live: project=" ++ Text.unpack expectedProject ++ " profile=" ++ profile)
                                        observation <- runPreparedColimaWallCall call
                                        case settleColimaWallCall call observation $ \live -> do
                                            cleanupResult <- newIORef (Left "native direct-Colima cleanup did not run")
                                            let cleanup = do
                                                    result <-
                                                        case withColimaCleanupAuthority live $ \authority -> do
                                                            cleanupGate <- nextGate
                                                            prepared <- prepareColimaCleanupCall plan providerResource cleanupGate authority
                                                            case prepared of
                                                                Left failure -> pure (Left (show failure))
                                                                Right cleanupCall -> fmap ((>>= \(_, diagnostic) -> maybe (Right ()) (Left . show) diagnostic) . first show) (runColimaCleanup cleanupCall) of
                                                            Nothing -> pure (Left "live direct-Colima wall did not retain cleanup authority")
                                                            Just action -> action
                                                    writeIORef cleanupResult result
                                                verify = do
                                                    assertBool "the exact native profile is derived, not caller-selected" (isPrefixOf "h-" profile && length profile == 8)
                                                    assertBool "the exact Docker context cannot be the shared default" (liveColimaDockerContext live /= "default")
                                                    dockerResult <- runLiveColimaDocker live ["version", "--format", "{{.Server.Version}}"]
                                                    case dockerResult of
                                                        Right (ColimaDockerRun (CapturedRun ExitSuccess version "") Nothing) ->
                                                            assertBool "the routed native Docker server returned a version" (not (null version))
                                                        other -> assertFailure ("the routed native Docker probe failed: " ++ show other)
                                                    conflictingObservation <- runPreparedColimaWallCall conflictingCall
                                                    case settleColimaWallCall conflictingCall conflictingObservation (const ()) of
                                                        Left Conflict{} -> pure ()
                                                        other -> assertFailure ("the incompatible same-name native profile was not refused: " ++ show other)
                                            verify `finally` cleanup
                                            cleaned <- readIORef cleanupResult
                                            cleaned @?= Right () of
                                            Left failure -> assertFailure ("the native direct-Colima wall did not settle: " ++ show failure)
                                            Right action -> action
                                    either assertFailure pure preparedConflict
    case accepted of
        Left failure -> assertFailure failure
        Right () -> pure ()
    ambientProfilesAfter <- requireNativeCommand colima ["list", "--json"]
    ambientContextAfter <- requireNativeCommand docker ["context", "show"]
    ambientProfilesAfter @?= ambientProfilesBefore
    ambientContextAfter @?= ambientContextBefore
    putStrLn "direct-colima-live: conflict refused; exact profile/context/data cleaned; ambient default unchanged"

requireNativeCommand :: FilePath -> [String] -> IO String
requireNativeCommand executablePath arguments = do
    (code, out, errOut) <- readProcessWithExitCode executablePath arguments ""
    case (code, errOut) of
        (ExitSuccess, "") -> pure out
        _ -> assertFailure ("native acceptance command failed: " ++ show (executablePath, arguments, code, errOut))

flattenBudget :: Either BudgetError (Either String a) -> Either String a
flattenBudget = either (Left . show) id

testPlan :: StepPlan
testPlan =
    either
        (error . show)
        id
        ( mkStepPlan
            [ descendsVia
                localContext
                (deployVMStep "provider" (StepFrame "host" "Host") (const (pure StepChanged)))
            , deployKindStep "cluster" (StepFrame "provider" "Provider") (const (pure StepChanged))
            ]
        )

withTestProjectResources ::
    ( forall projectId specDigest planId configId providerId providerFrame clusterId clusterFrame.
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      Text.Text ->
      PlannedResource
        (Production projectId)
        planId
        providerId
        ProviderResource
        providerFrame ->
      PlannedResource
        (Production projectId)
        planId
        clusterId
        ClusterResource
        clusterFrame ->
      IO result
    ) ->
    IO result
withTestProjectResources consume =
    Fixture.withFixtureProjectPlanConfig (selectResources exactResources) testPlan $ \plan value -> do
        Fixture.resources value @?= exactResources
        withTestPlanResources plan (consume plan (Context.project (Fixture.context value)))

withTestPlanResources ::
    ProjectPlan scope specDigest planId configId Fixture.ProjectConfig ->
    ( forall providerId providerFrame clusterId clusterFrame.
      PlannedResource scope planId providerId ProviderResource providerFrame ->
      PlannedResource scope planId clusterId ClusterResource clusterFrame ->
      IO result
    ) ->
    IO result
withTestPlanResources plan consume =
    case NonEmpty.toList (forward plan) of
        [providerNode, clusterNode] ->
            case withPlannedResourceOfKind
                plan
                ProviderResourceKind
                (plannedStepOperationKey providerNode)
                ( \providerResource ->
                    withPlannedResourceOfKind
                        plan
                        ClusterResourceKind
                        (plannedStepOperationKey clusterNode)
                        (consume providerResource)
                ) of
                Left failure -> fail ("provider projection failed: " ++ show failure)
                Right (Left failure) -> fail ("cluster projection failed: " ++ show failure)
                Right (Right action) -> action
        nodes -> fail ("expected provider and cluster plan nodes, got " ++ show (length nodes))
