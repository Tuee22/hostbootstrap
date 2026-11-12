{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The direct-Colima clause-1/2 entry over the shared protected store.

One entry covers the stage record and every artifact-origin record.  The keys
are derived from the fixed provider profile; callers cannot select an unrelated
record while holding this transaction.
-}
module HostBootstrap.Ensure.Colima.Ownership (
    ColimaOwnershipKeys,
    colimaStageKey,
    colimaHomeKey,
    colimaContextKey,
    colimaDiskKey,
    colimaProfileKey,
    colimaManifestKey,
    withColimaOwnershipEntry,
    ColimaNativeOwnershipFault (..),
    prepareColimaNamespaces,
    ColimaStartedObservation (..),
    ColimaArtifactObservation (..),
    ColimaManagedObservation (..),
    ColimaManagedOutcome (..),
    ColimaProfileMutationFault (..),
    colimaMutationAcquireObservation,
    colimaContextAcquisitionNeedsProbe,
    admitColimaContextAcquisition,
    colimaContextRemovalNeeded,
    admitColimaContextFingerprint,
    admitColimaContextRemovalAbsence,
    startPreparedColimaProfileWith,
    observeColimaArtifactsWith,
    publishPreparedColimaManifest,
    acquireManagedColimaProfileWith,
    bindColimaCreationIdentities,
    settleManagedColimaProfile,
    refreshManagedColimaManifest,
    cleanupManagedColimaProfileWith,
    admitColimaCleanupLineage,
    ColimaCleanupResume (..),
    admitColimaCleanupResume,
    ColimaCleanupProfileObservation (..), classifyColimaCleanupProfile, admitColimaCleanupMachine, colimaCleanupDeleteResult, admitColimaCleanupProfileAbsence, admitColimaReleaseManifest,
    runManagedColimaDockerWith,
    admitColimaManagedDockerRoute,
    colimaDockerCommandResult,
    readColimaStage,
    writeColimaStage,
    acquireColimaDirectory,
    ensureColimaDirectory,
    releaseColimaDirectory,
    colimaDirectoryBinding,
    admitStoredColimaDockerRoute,
    releaseColimaContextNamespace,
    releaseColimaReleasedNamespaces,
    colimaCacheKey,
    colimaTemporaryKey,
)
where

import Data.Bifunctor (first)
import qualified Crypto.Hash as Hash
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as LazyByteString
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString.Char8
import Data.List (inits, sortOn)
import Data.Ord (Down (Down))
import qualified Data.Text as Text
import Data.Word (Word64)
import HostBootstrap.Cluster.Budget.Observation (WallAcquireObservation (..))
import HostBootstrap.Reconcile.Error (ConflictDetail (..), FailureDetail (..), RecoveryDisposition (ReprobeBeforeRetry))
import HostBootstrap.Effect.Run (CapturedRun (capturedExit))
import HostBootstrap.Effect.Vocabulary (HostCommand)
import HostBootstrap.Ensure.Colima.Backend.Stage (
    managedMachineIdentity,
    managedMachineEpoch,
    managedContextDigest,
    managedManifestDigest,
    managedDirectoryChainDigest,
    managedCpu,
    managedMemoryBytes,
    managedDiskBytes,
    managedRootDiskBytes,
    ColimaStage (..),
    ColimaStageIntent (AcquireColima, ReleaseColima),
    ColimaStageObservation (ColimaNamespaceAbsent, ColimaHomeStageExact, ColimaHomeExact, ColimaContextStageExact, ColimaProfileAbsent, ColimaProfileExact, ColimaReleasedNamespaceExact),
    ColimaStageDecision (AdvanceColimaStage, BeginColimaLineage, KeepColimaStage, StartColimaProfile, DeleteColimaProfile, ReleaseColimaNamespace),
    decideColimaStage,
    ColimaStageRecord,
    advanceSettledColimaStageRecord,
    beginColimaReleaseRecord,
    colimaStageRecordCleanupInvocation,
    colimaStageRecordEvidence,
    colimaStageRecordInvocation,
    colimaStageRecordLineage,
    colimaStageRecordOwner,
    colimaStageRecordStage,
    mkColimaManagedEvidence,
    mkColimaStageRecord,
    parseColimaStageRecord,
    renderColimaStageRecord,
    settleColimaStageRecord,
    refreshColimaManifestRecord,
 )
import HostBootstrap.Ensure.Colima.Command (
    ColimaProfile,
    ColimaStartArguments,
    colimaStartProfile,
    mkColimaProfile,
    dockerContextForProfile,
    dockerContextNameText,
    deleteColimaProfileCommand,
    inspectDockerContextCommand,
    listColimaProfilesCommand,
    listDockerContextsCommand,
    listLimaDisksCommand,
    readColimaMachineIdCommand,
    removeDockerContextCommand,
    routedDockerCommand,
    startColimaProfileCommand,
 )
import HostBootstrap.Ensure.Colima.Report (
    ColimaReportFault,
    ColimaInstance,
    ciCpus,
    ciDiskBytes,
    ciMemoryBytes,
    ciName,
    ciRuntime,
    ciStatus,
    classifyColimaListing,
    classifyDockerContextInspect,
    classifyDockerContextListing,
    classifyLimaDiskListing,
    classifyMachineIdentity,
    dockerContextFingerprint,
    limaDiskDirectory,
    limaDiskInstance,
    limaDiskInstanceDirectory,
    limaDiskName,
    limaDiskSize,
 )
import HostBootstrap.Ownership.Clause (enteredEvidence, recordedEvidence)
import HostBootstrap.Ownership.Manifest (
    OwnershipManifest,
    admitOwnershipManifestRemainders,
    projectOwnershipManifest,
    manifestEntryPath,
    mergeOwnershipManifests,
    ownershipDirectoryChainDigest,
    ownershipManifestDigest,
    ownershipManifestEntries,
    parseOwnershipManifest,
    prefixOwnershipManifest,
    renderOwnershipManifest,
 )
import HostBootstrap.Ownership.Object (
    ConflictReport (..),
    ObjectIdentity,
    OriginRecord,
    ObjectKind (OwnedDirectory, ReportedObject),
    Origin (OriginAbsent, OriginPresent),
    OwnershipFault (..),
    mkOwnerClaim,
    originRecord,
    originRecordBinding,
    originRecordKind,
    originRecordOrigin,
    parseObjectIdentityHex,
    storeFault,
 )
import HostBootstrap.Ownership.Primitive (
    OwnershipClause (ClauseRecord, ClauseRelease),
    clauseRefusal,
    rowCapabilities,
    withOwnershipRow,
    bindOwnedIdentity,
    bindReportedIdentity,
    createOwnedDirectory,
    enterOwnedObject,
    enterReportedObject,
    recordOwnedOrigin,
    recordReportedOrigin,
    reenterStoredOwnedObject,
    reenterStoredReportedObject,
    releaseOwnedObject,
    resumeOwnedRemoval,
    releaseReportedObject,
    resumeReportedRemoval,
    reobserveOwnedIdentity,
    reobserveReportedIdentity,
 )
import HostBootstrap.Ownership.Remainder (releaseManifestRemainder)
import HostBootstrap.Ownership.Row (observeOwnershipManifestForHost, ownershipRowForHost)
import HostBootstrap.Ownership.Tape (
    RecordSubject (RecordSubject, subjectBinding, subjectRecord),
    RecordTape,
    forgetRecordAtVersion,
    readRawRecordUnder,
    readRecordUnder,
    readStoredRecordUnder,
    storedOriginRecord,
    storedRecordVersion,
    publishBoundRecord,
    publishFreshRecord,
    recordTape,
 )
import HostBootstrap.Protected (
    Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    RecordKey,
    RecordVersion,
    compareAndDeleteProtectedRecord,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    openProtectedStore,
    protectedErrorMessage,
    readProtectedRecord,
    sessionStoreRoot,
    withProtectedEntry,
 )
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (dropTrailingPathSeparator, isAbsolute, makeRelative, splitDirectories, takeDirectory, takeFileName, (</>))

data ColimaOwnershipKeys = ColimaOwnershipKeys
    { colimaCommandProfile :: ColimaProfile
    , colimaStageKey :: RecordKey
    , colimaHomeKey :: RecordKey
    , colimaCacheKey :: RecordKey
    , colimaTemporaryKey :: RecordKey
    , colimaContextKey :: RecordKey
    , colimaDiskKey :: RecordKey
    , colimaProfileKey :: RecordKey
    , colimaManifestKey :: RecordKey
    }

data ColimaNativeOwnershipFault
    = ColimaNativeStoreRefused String
    | ColimaNativeStageRefused String
    | ColimaNativeOwnershipRefused OwnershipFault
    deriving (Eq, Show)

data ColimaStartedObservation = ColimaStartedObservation
    { startedMachineIdentity :: String
    , startedMachineEpoch :: Word64
    }
    deriving (Eq, Show)

data ColimaArtifactObservation = ColimaArtifactObservation
    { artifactDiskPath :: FilePath
    , artifactDiskIdentity :: ObjectIdentity
    , artifactContextDigest :: String
    , artifactOwnershipManifest :: OwnershipManifest
    }
    deriving (Eq, Show)

data ColimaManagedObservation = ColimaManagedObservation
    { managedStartObservation :: ColimaStartedObservation
    , managedArtifactObservation :: ColimaArtifactObservation
    }
    deriving (Eq, Show)

data ColimaManagedOutcome
    = ColimaManagedApplied ColimaManagedObservation
    | ColimaManagedAlreadyExact ColimaManagedObservation
    deriving (Eq, Show)

data ColimaProfileMutationFault
    = ColimaMutationEntryRefused String
    | ColimaMutationOwnershipRefused OwnershipFault
    | ColimaMutationCommandUnavailable String
    | ColimaMutationReportRefused ColimaReportFault
    | ColimaMutationProfileConflict String
    | ColimaMutationStartFailed
    | ColimaMutationDeleteFailed
    deriving (Eq, Show)

-- | Classify an acquisition fault without granting ownership or settlement authority.
colimaMutationAcquireObservation :: Text.Text -> ColimaProfileMutationFault -> WallAcquireObservation
colimaMutationAcquireObservation expected fault =
    case fault of
        ColimaMutationProfileConflict{} -> conflict
        ColimaMutationOwnershipRefused{} -> conflict
        _ ->
            WallAcquireFailed
                ( FailureDetail
                    "acquire Colima provider wall"
                    (Text.pack (show fault))
                    ReprobeBeforeRetry
                )
  where
    conflict =
        WallRefused
            ( ConflictDetail
                "reconcile Colima provider wall"
                expected
                (Text.pack (show fault))
                "leave the conflicting profile untouched and resolve its owner or sizing explicitly"
            )

withColimaOwnershipEntry ::
    FilePath ->
    String ->
    (forall session. ProtectedSession session -> ColimaOwnershipKeys -> IO (Either ProtectedError value)) ->
    IO (Either String value)
withColimaOwnershipEntry stateRoot profile action =
    case ownershipKeys profile of
        Left refusal -> pure (Left refusal)
        Right keys -> do
            opened <- openProtectedStore stateRoot
            case opened of
                Left failure -> pure (Left (Text.unpack (protectedErrorMessage failure)))
                Right store ->
                    first (Text.unpack . protectedErrorMessage)
                        <$> withProtectedEntry store (\session -> action session keys)

readColimaStage :: ProtectedSession session -> ColimaOwnershipKeys -> IO (Either OwnershipFault (Maybe (RecordVersion, ColimaStageRecord)))
readColimaStage session keys = do
    observed <- readProtectedRecord session (colimaStageKey keys)
    pure $ case observed of
        Left failure -> Left (storeFault "read Colima stage" failure)
        Right Nothing -> Right Nothing
        Right (Just stored) ->
            case parseColimaStageRecord (protectedRecordBytes stored) of
                Left refusal -> Left (OwnershipMalformed (Text.pack refusal))
                Right record -> Right (Just (protectedRecordVersion stored, record))

writeColimaStage :: ProtectedSession session -> ColimaOwnershipKeys -> Expectation -> ColimaStageRecord -> IO (Either OwnershipFault RecordVersion)
writeColimaStage session keys expectation record = do
    written <-
        compareAndSwapProtectedRecord
            session
            (colimaStageKey keys)
            expectation
            (renderColimaStageRecord record)
    pure (either (Left . storeFault "publish Colima stage") Right written)

{- | Native acquisition through the prepared boundary: publish the lineage,
acquire the isolated home and Docker-config directories through clauses
1–3, and leave the durable state at Prepared. Every restart re-enters exact
bound identities and continues from the retained adjacent stage.
-}
prepareColimaNamespaces :: FilePath -> String -> String -> String -> String -> FilePath -> FilePath -> IO (Either ColimaNativeOwnershipFault ())
prepareColimaNamespaces stateRoot profile owner lineage invocation home context =
    case mkColimaStageRecord ColimaReserved owner lineage invocation of
        Left refusal -> pure (Left (ColimaNativeStageRefused refusal))
        Right reserved -> do
            entered <-
                withColimaOwnershipEntry stateRoot profile $ \session keys ->
                    Right <$> prepareColimaNamespacesInside session keys owner lineage invocation home context reserved
            pure $ case entered of
                Left refusal -> Left (ColimaNativeStoreRefused refusal)
                Right outcome -> outcome

prepareColimaNamespacesInside :: ProtectedSession session -> ColimaOwnershipKeys -> String -> String -> String -> FilePath -> FilePath -> ColimaStageRecord -> IO (Either ColimaNativeOwnershipFault ())
prepareColimaNamespacesInside session keys owner lineage invocation home context reserved = do
    initial <- owned (readColimaStage session keys)
    started <- case initial of
        Left fault -> pure (Left fault)
        Right Nothing -> do
            vacant <- owned (observeVacantColimaNamespaces session keys home context)
            case vacant of
                Left fault -> pure (Left fault)
                Right observation -> case decision reserved observation of
                    Right (AdvanceColimaStage ColimaHomeStaged) ->
                        fmap (fmap (const ())) (owned (writeColimaStage session keys ExpectAbsent reserved))
                    Left fault -> pure (Left fault)
                    Right _ -> pure (Left (ColimaNativeStageRefused "the vacant namespace did not authorize preparation"))
        Right (Just _) -> pure (Right ())
    case started of
        Left fault -> pure (Left fault)
        Right () -> drive
  where
    owned action = first ColimaNativeOwnershipRefused <$> action
    mkRecord stage = first ColimaNativeStageRefused (mkColimaStageRecord stage owner lineage invocation)
    decision record observation = first ColimaNativeStageRefused $
        decideColimaStage AcquireColima (colimaStageRecordStage record) observation

    drive = do
        current <- owned (readColimaStage session keys)
        case current of
            Left fault -> pure (Left fault)
            Right Nothing -> pure (Left (ColimaNativeStageRefused "Colima stage vanished inside its entry"))
            Right (Just (version, record)) -> case mkRecord (colimaStageRecordStage record) of
                Left fault -> pure (Left fault)
                Right expected
                    | record /= expected -> pure (Left (ColimaNativeStageRefused "Colima stage lineage does not match this invocation"))
                    | otherwise -> do
                        parents <- owned $
                            if colimaStageRecordStage record == ColimaReserved
                                then ensureColimaContextParents session context
                                else revalidateColimaContextParents session context
                        case parents of
                            Left fault -> pure (Left fault)
                            Right () -> case colimaStageRecordStage record of
                                ColimaReserved -> do
                                    before <- owned (observeKernelOrigin session home)
                                    case before of
                                        Left fault -> pure (Left fault)
                                        Right OriginAbsent ->
                                            advance version record ColimaNamespaceAbsent (ensureHome home (colimaHomeKey keys))
                                        Right (OriginPresent _) -> do
                                            exact <- verify [(colimaHomeKey keys, home)]
                                            case exact of
                                                Left fault -> pure (Left fault)
                                                Right () -> advance version record ColimaHomeStageExact (pure (Right ()))
                                ColimaHomeStaged -> do
                                    exact <- verify [(colimaHomeKey keys, home)]
                                    case exact of
                                        Left fault -> pure (Left fault)
                                        Right () -> advance version record ColimaHomeStageExact (pure (Right ()))
                                ColimaHomeReady -> do
                                    exact <- verify [(colimaHomeKey keys, home)]
                                    case exact of
                                        Left fault -> pure (Left fault)
                                        Right () -> advance version record ColimaHomeExact $ do
                                            auxiliaries <- owned (ensureAuxiliaryDirectories session keys home)
                                            case auxiliaries of
                                                Left fault -> pure (Left fault)
                                                Right () -> ensureHome context (colimaContextKey keys)
                                ColimaContextStaged -> do
                                    exact <- verify namespaces
                                    case exact of
                                        Left fault -> pure (Left fault)
                                        Right () -> advance version record ColimaContextStageExact (pure (Right ()))
                                ColimaPrepared -> do
                                    exact <- verify namespaces
                                    pure $ do
                                        () <- exact
                                        chosen <- decision record ColimaContextStageExact
                                        case chosen of
                                            KeepColimaStage -> Right ()
                                            _ -> Left (ColimaNativeStageRefused "the prepared namespace did not retain its stage")
                                _ -> pure (Left (ColimaNativeStageRefused "Colima namespace preparation reached a non-acquisition stage"))

    namespaces =
        [ (colimaHomeKey keys, home), (colimaCacheKey keys, home </> "cache")
        , (colimaTemporaryKey keys, home </> "tmp"), (colimaContextKey keys, context)
        ]
    verify [] = pure (Right ())
    verify ((key, target) : remaining) = do
        present <- owned (readRetainedColimaDirectoryIdentity session key target)
        case present of
            Left fault -> pure (Left fault)
            Right _ -> verify remaining
    ensureHome target key = fmap (fmap (const ())) (owned (ensureColimaDirectory session key target))
    advance version record observation apply = case decision record observation of
        Left fault -> pure (Left fault)
        Right (AdvanceColimaStage successor) -> do
            applied <- apply
            case applied of
                Left fault -> pure (Left fault)
                Right () -> case mkRecord successor of
                    Left fault -> pure (Left fault)
                    Right next -> do
                        written <- owned (writeColimaStage session keys (ExpectVersion version) next)
                        case written of
                            Left fault -> pure (Left fault)
                            Right _ -> drive
        Right _ -> pure (Left (ColimaNativeStageRefused "the namespace observation did not advance its stage"))

ensureAuxiliaryDirectories :: ProtectedSession session -> ColimaOwnershipKeys -> FilePath -> IO (Either OwnershipFault ())
ensureAuxiliaryDirectories session keys home = do
    cache <- ensureColimaDirectory session (colimaCacheKey keys) (home </> "cache")
    case cache of
        Left fault -> pure (Left fault)
        Right _ -> fmap (fmap (const ())) (ensureColimaDirectory session (colimaTemporaryKey keys) (home </> "tmp"))

{- | Perform the outcome-unknown start window while the Prepared record and
both namespace identities remain live. The function deliberately does not
publish Managed: disk and context settlement must still succeed under this
same entry before that successor is durable.
-}
startPreparedColimaProfileWith ::
    (HostCommand -> IO (Either String CapturedRun)) ->
    FilePath ->
    String ->
    String ->
    String ->
    String ->
    FilePath ->
    FilePath ->
    FilePath ->
    Integer ->
    Integer ->
    Integer ->
    ColimaStartArguments ->
    IO (Either ColimaProfileMutationFault ColimaStartedObservation)
startPreparedColimaProfileWith interpret stateRoot profile owner lineage invocation home context diskPath expectedCpu expectedMemory expectedDisk startArguments
    | mkColimaProfile profile /= Right (colimaStartProfile startArguments) = pure (Left (ColimaMutationEntryRefused "start arguments do not match the owned profile"))
    | otherwise = do
    entered <-
        withColimaOwnershipEntry stateRoot profile $ \session keys ->
            Right <$> startPreparedColimaProfileInside interpret session keys profile owner lineage invocation home context diskPath expectedCpu expectedMemory expectedDisk startArguments
    pure $ case entered of
        Left refusal -> Left (ColimaMutationEntryRefused refusal)
        Right outcome -> outcome

startPreparedColimaProfileInside ::
    (HostCommand -> IO (Either String CapturedRun)) ->
    ProtectedSession session ->
    ColimaOwnershipKeys ->
    String ->
    String ->
    String ->
    String ->
    FilePath ->
    FilePath ->
    FilePath ->
    Integer ->
    Integer ->
    Integer ->
    ColimaStartArguments ->
    IO (Either ColimaProfileMutationFault ColimaStartedObservation)
startPreparedColimaProfileInside interpret session keys profile owner lineage invocation home context diskPath expectedCpu expectedMemory expectedDisk startArguments = withValidatedColimaContextParents session context mutateInside
  where
    mutateInside = do
        stage <- readColimaStage session keys
        case stage of
            Left fault -> pure (Left (ColimaMutationOwnershipRefused fault))
            Right Nothing -> pure (Left (ColimaMutationProfileConflict "prepared stage is absent"))
            Right (Just (_, observed)) ->
                case mkColimaStageRecord ColimaPrepared owner lineage invocation of
                    Left refusal -> pure (Left (ColimaMutationProfileConflict refusal))
                    Right expected
                        | observed /= expected -> pure (Left (ColimaMutationProfileConflict "prepared stage belongs to another lineage"))
                        | otherwise -> do
                            directories <- traverse (uncurry (readRetainedColimaDirectoryIdentity session))
                                [ (colimaHomeKey keys, home), (colimaContextKey keys, context)
                                , (colimaCacheKey keys, home </> "cache"), (colimaTemporaryKey keys, home </> "tmp")
                                ]
                            case sequence directories of
                                Left fault -> pure (Left (ColimaMutationOwnershipRefused fault))
                                Right _ -> observeOrStart

    observeOrStart = do
        before <- observeProfiles
        case before >>= exactProfile of
            Left fault -> pure (Left fault)
            Right Nothing -> case decideColimaStage AcquireColima ColimaPrepared ColimaProfileAbsent of
                Left refusal -> pure (Left (ColimaMutationProfileConflict refusal))
                Right StartColimaProfile -> do
                    prepared <- prepareCreationRecords
                    case prepared of
                        Left fault -> pure (Left (ColimaMutationOwnershipRefused fault))
                        Right () -> do
                            started <- runCommand (startColimaProfileCommand startArguments)
                            case started of
                                Left fault -> pure (Left fault)
                                Right run
                                    | capturedExit run /= ExitSuccess -> pure (Left ColimaMutationStartFailed)
                                    | otherwise -> settleRunning
                Right _ -> pure (Left (ColimaMutationProfileConflict "the absent Prepared profile did not authorize start"))
            Right (Just _) ->
                case decideColimaStage AcquireColima ColimaPrepared ColimaProfileExact of
                    Right KeepColimaStage -> recoverBoundProfile
                    _ -> pure (Left (ColimaMutationProfileConflict "the stage table refused Prepared recovery"))

    recoverBoundProfile = do
        retained <- readRecordUnder (reportedTape session) (colimaProfileKey keys)
        case retained of
            Left fault -> pure (Left (ColimaMutationOwnershipRefused fault))
            Right (Just record)
                | originRecordKind record == ReportedObject claim
                , originRecordOrigin record == OriginAbsent
                , Just expected <- originRecordBinding record -> do
                    observed <- runCommand (readColimaMachineIdCommand (colimaCommandProfile keys))
                    pure $ do
                        run <- observed
                        (identity, epoch) <- first ColimaMutationReportRefused (classifyMachineIdentity run)
                        actual <- first ColimaMutationOwnershipRefused (parseObjectIdentityHex (Text.pack identity))
                        if actual == expected
                            then Right (ColimaStartedObservation identity epoch)
                            else Left (ColimaMutationProfileConflict "the bound Prepared profile identity changed")
            _ -> pure (Left (ColimaMutationProfileConflict
                ("profile " ++ profile ++ " is already present under Prepared; its start outcome is unknown")))

    settleRunning = do
        after <- observeProfiles
        case after >>= exactProfile of
            Left fault -> pure (Left fault)
            Right Nothing -> pure (Left (ColimaMutationProfileConflict "profile remained absent after start"))
            Right (Just _) -> do
                machine <- runCommand (readColimaMachineIdCommand (colimaCommandProfile keys))
                pure $ case machine of
                    Left fault -> Left fault
                    Right run ->
                        case classifyMachineIdentity run of
                            Left refusal -> Left (ColimaMutationReportRefused refusal)
                            Right (identity, epoch) -> Right (ColimaStartedObservation identity epoch)

    observeProfiles = do
        result <- runCommand listColimaProfilesCommand
        pure $ case result of
            Left fault -> Left fault
            Right run -> either (Left . ColimaMutationReportRefused) Right (classifyColimaListing run)

    exactProfile values =
        case filter ((== profile) . ciName) values of
            [] -> Right Nothing
            [value]
                | map lowerAscii (ciStatus value) /= "running" -> Left (ColimaMutationProfileConflict "profile is not running")
                | map lowerAscii (ciRuntime value) /= "docker" -> Left (ColimaMutationProfileConflict "profile runtime is not Docker")
                | ciCpus value /= expectedCpu || ciMemoryBytes value /= expectedMemory || ciDiskBytes value /= expectedDisk ->
                    Left (ColimaMutationProfileConflict "profile wall differs from the prepared wall")
                | otherwise -> Right (Just value)
            _ -> Left (ColimaMutationProfileConflict "profile listing is duplicated")

    runCommand command = do
        interpreted <- interpret command
        pure (either (Left . ColimaMutationCommandUnavailable) Right interpreted)

    lowerAscii character
        | character >= 'A' && character <= 'Z' = toEnum (fromEnum character + 32)
        | otherwise = character

    prepareCreationRecords = do
        profileRecord <- ensureReportedOrigin (colimaProfileKey keys) ("colima-profile:" ++ profile)
        case profileRecord of
            Left fault -> pure (Left fault)
            Right () -> ensureReportedOrigin (colimaDiskKey keys) diskPath

    claim = mkOwnerClaim (ByteString.Char8.pack owner)

    ensureReportedOrigin key target =
        enterReportedObject session target OriginAbsent $ \entered -> do
            recorded <- recordReportedOrigin entered claim publish
            pure $ case recorded of
                Left fault -> Left fault
                Right token -> recordedEvidence (\_ _ -> Right ()) token
      where
        publish = publishFreshRecord (reportedTape session) key

{- | Join authoritative Lima and Docker reports to the kernel identities of
the Prepared transaction's owned namespaces.
-}
observeColimaArtifactsWith ::
    (HostCommand -> IO (Either String CapturedRun)) ->
    FilePath ->
    String ->
    String ->
    String ->
    String ->
    FilePath ->
    FilePath ->
    Integer ->
    IO (Either ColimaProfileMutationFault ColimaArtifactObservation)
observeColimaArtifactsWith interpret stateRoot profile owner lineage invocation home context expectedDisk = do
    entered <-
        withColimaOwnershipEntry stateRoot profile $ \session keys ->
            Right <$> observeColimaArtifactsInside interpret session keys profile owner lineage invocation home context expectedDisk
    pure $ case entered of
        Left refusal -> Left (ColimaMutationEntryRefused refusal)
        Right outcome -> outcome
observeColimaArtifactsInside ::
    (HostCommand -> IO (Either String CapturedRun)) ->
    ProtectedSession session ->
    ColimaOwnershipKeys ->
    String ->
    String ->
    String ->
    String ->
    FilePath ->
    FilePath ->
    Integer ->
    IO (Either ColimaProfileMutationFault ColimaArtifactObservation)
observeColimaArtifactsInside interpret session keys profile owner lineage invocation home context expectedDisk = withValidatedColimaContextParents session context observeInside
  where
    observeInside = do
        stage <- readColimaStage session keys
        case (stage, mkColimaStageRecord ColimaPrepared owner lineage invocation) of
            (Left fault, _) -> pure (Left (ColimaMutationOwnershipRefused fault))
            (_, Left refusal) -> pure (Left (ColimaMutationProfileConflict refusal))
            (Right (Just (_, actual)), Right expected)
                | actual == expected || managedLineage actual -> do
                    contextIdentity <- ensureColimaDirectory session (colimaContextKey keys) context
                    disks <- runClassified listLimaDisksCommand classifyLimaDiskListing
                    inspected <- runClassified (inspectDockerContextCommand (dockerContextForProfile (colimaCommandProfile keys))) classifyDockerContextInspect
                    homeManifest <- observeOwnershipManifestForHost True home
                    contextManifest <- observeOwnershipManifestForHost False context
                    case (contextIdentity, disks, inspected, homeManifest, contextManifest) of
                        (Left fault, _, _, _, _) -> pure (Left (ColimaMutationOwnershipRefused fault))
                        (_, Left fault, _, _, _) -> pure (Left fault)
                        (_, _, Left fault, _, _) -> pure (Left fault)
                        (_, _, _, Left fault, _) -> pure (Left (ColimaMutationOwnershipRefused fault))
                        (_, _, _, _, Left fault) -> pure (Left (ColimaMutationOwnershipRefused fault))
                        (Right contextObject, Right values, Right contextValue, Right observedHome, Right observedContext) ->
                            case filter ((== diskName) . limaDiskName) values of
                                [disk]
                                    | limaDiskDirectory disk == expectedDiskDirectory
                                    , limaDiskInstance disk == diskName
                                    , limaDiskInstanceDirectory disk == expectedInstanceDirectory
                                    , limaDiskSize disk == expectedDisk -> do
                                        identity <- observeDiskIdentity expectedDataFile
                                        pure $ do
                                            diskIdentity <- first ColimaMutationOwnershipRefused identity
                                            prefixedHome <- first ColimaMutationOwnershipRefused (prefixOwnershipManifest "colima" observedHome)
                                            prefixedContext <- first ColimaMutationOwnershipRefused (prefixOwnershipManifest "docker" observedContext)
                                            complete <- first ColimaMutationOwnershipRefused (mergeOwnershipManifests [prefixedHome, prefixedContext])
                                            Right (ColimaArtifactObservation expectedDataFile diskIdentity (dockerContextFingerprint contextObject contextValue) complete)
                                [] -> pure (Left (ColimaMutationProfileConflict "owned Lima disk is absent"))
                                _ -> pure (Left (ColimaMutationProfileConflict "owned Lima disk topology differs"))
                | otherwise -> pure (Left (ColimaMutationProfileConflict "prepared stage belongs to another lineage"))
            _ -> pure (Left (ColimaMutationProfileConflict "prepared stage is absent"))

    managedLineage actual =
        colimaStageRecordStage actual == ColimaManaged
            && colimaStageRecordOwner actual == owner
            && colimaStageRecordLineage actual == lineage
            && colimaStageRecordInvocation actual == invocation
            && colimaStageRecordEvidence actual /= Nothing

    diskName = "colima-" ++ profile
    expectedDiskDirectory = home </> "_lima" </> "_disks" </> diskName
    expectedInstanceDirectory = home </> "_lima" </> diskName
    expectedDataFile = expectedDiskDirectory </> "datadisk"

    observeDiskIdentity target =
        enterOwnedObject ownershipRowForHost session target $ \entered ->
            enteredEvidence
                ( \_ origin -> pure $ case origin of
                    OriginAbsent -> Left (OwnershipProbeFailed "observe Colima data disk" "data disk is absent")
                    OriginPresent identity -> Right identity
                )
                entered

    runClassified command classify = do
        raw <- interpret command
        pure $ case raw of
            Left refusal -> Left (ColimaMutationCommandUnavailable refusal)
            Right captured -> either (Left . ColimaMutationReportRefused) Right (classify captured)

{- | Persist the complete shared manifest while Prepared is still the durable
stage. Re-entry accepts only the byte-identical canonical value.
-}
publishPreparedColimaManifest ::
    FilePath ->
    String ->
    String ->
    String ->
    String ->
    OwnershipManifest ->
    IO (Either ColimaProfileMutationFault ())
publishPreparedColimaManifest stateRoot profile owner lineage invocation manifest = do
    entered <-
        withColimaOwnershipEntry stateRoot profile $ \session keys ->
            Right <$> publishPreparedColimaManifestInside session keys owner lineage invocation manifest
    pure $ case entered of
        Left refusal -> Left (ColimaMutationEntryRefused refusal)
        Right outcome -> outcome

publishPreparedColimaManifestInside :: ProtectedSession session -> ColimaOwnershipKeys -> String -> String -> String -> OwnershipManifest -> IO (Either ColimaProfileMutationFault ())
publishPreparedColimaManifestInside session keys owner lineage invocation manifest = publishInside
  where
    bytes = renderOwnershipManifest manifest
    publishInside = do
        stage <- readColimaStage session keys
        case (stage, mkColimaStageRecord ColimaPrepared owner lineage invocation) of
            (Left fault, _) -> pure (Left (ColimaMutationOwnershipRefused fault))
            (_, Left refusal) -> pure (Left (ColimaMutationProfileConflict refusal))
            (Right (Just (_, actual)), Right expected)
                | actual == expected -> do
                    current <- readProtectedRecord session (colimaManifestKey keys)
                    case current of
                        Left failure -> pure (Left (ColimaMutationOwnershipRefused (storeFault "read Colima manifest" failure)))
                        Right Nothing -> do
                            written <- compareAndSwapProtectedRecord session (colimaManifestKey keys) ExpectAbsent bytes
                            pure (either (Left . ColimaMutationOwnershipRefused . storeFault "publish Colima manifest") (const (Right ())) written)
                        Right (Just stored)
                            | protectedRecordBytes stored == bytes -> pure (Right ())
                            | otherwise -> pure (Left (ColimaMutationProfileConflict "retained Colima manifest differs"))
                | otherwise -> pure (Left (ColimaMutationProfileConflict "prepared stage belongs to another lineage"))
            _ -> pure (Left (ColimaMutationProfileConflict "prepared stage is absent"))

{- | Bind the machine identity reported by Colima and the data disk identity
reported by the kernel to the origins published before start. The stage
remains Prepared until context and wall settlement also succeed.
-}
bindColimaCreationIdentities :: FilePath -> String -> String -> String -> String -> String -> FilePath -> IO (Either ColimaProfileMutationFault (ObjectIdentity, ObjectIdentity))
bindColimaCreationIdentities stateRoot profile owner lineage invocation machine diskPath = do
    entered <-
        withColimaOwnershipEntry stateRoot profile $ \session keys ->
            Right <$> bindColimaCreationIdentitiesInside session keys profile owner lineage invocation machine diskPath
    pure $ case entered of
        Left refusal -> Left (ColimaMutationEntryRefused refusal)
        Right outcome -> outcome

bindColimaCreationIdentitiesInside :: ProtectedSession session -> ColimaOwnershipKeys -> String -> String -> String -> String -> String -> FilePath -> IO (Either ColimaProfileMutationFault (ObjectIdentity, ObjectIdentity))
bindColimaCreationIdentitiesInside session keys profile owner lineage invocation machine diskPath = bindInside
  where
    bindInside = do
        stage <- readColimaStage session keys
        case (stage, mkColimaStageRecord ColimaPrepared owner lineage invocation) of
            (Left fault, _) -> pure (Left (ColimaMutationOwnershipRefused fault))
            (_, Left refusal) -> pure (Left (ColimaMutationProfileConflict refusal))
            (Right (Just (_, observed)), Right expected)
                | observed == expected -> case parseObjectIdentityHex (Text.pack machine) of
                    Left fault -> pure (Left (ColimaMutationOwnershipRefused fault))
                    Right machineIdentity -> do
                        diskIdentity <- observeIdentity diskPath
                        case diskIdentity of
                            Left fault -> pure (Left (ColimaMutationOwnershipRefused fault))
                            Right observedDisk -> do
                                profileBound <- bindReportedRecord (colimaProfileKey keys) ("colima-profile:" ++ profile) machineIdentity
                                diskBound <- bindReportedRecord (colimaDiskKey keys) diskPath observedDisk
                                pure $ case (profileBound, diskBound) of
                                    (Left fault, _) -> Left (ColimaMutationOwnershipRefused fault)
                                    (_, Left fault) -> Left (ColimaMutationOwnershipRefused fault)
                                    (Right (), Right ()) -> Right (machineIdentity, observedDisk)
                | otherwise -> pure (Left (ColimaMutationProfileConflict "prepared stage belongs to another lineage"))
            _ -> pure (Left (ColimaMutationProfileConflict "prepared stage is absent"))

    observeIdentity target =
        enterOwnedObject ownershipRowForHost session target $ \entered ->
            enteredEvidence
                ( \_ origin -> pure $ case origin of
                    OriginAbsent -> Left (OwnershipProbeFailed "observe created Colima artifact" "artifact is absent")
                    OriginPresent identity -> Right identity
                )
                entered

    claim = mkOwnerClaim (ByteString.Char8.pack owner)

    bindReportedRecord key target identity =
        enterReportedObject session target OriginAbsent $ \entered -> do
            recorded <- recordReportedOrigin entered claim verifyOrigin
            case recorded of
                Left fault -> pure (Left fault)
                Right token -> do
                    bound <- bindReportedIdentity token identity publishBinding
                    pure (fmap (const ()) bound)
      where
        expected = originRecord (ReportedObject claim) OriginAbsent
        verifyOrigin record = do
            current <- readRecordUnder (reportedTape session) key
            pure $ case current of
                Left fault -> Left fault
                Right (Just held)
                    | record == expected
                    , originRecordKind held == originRecordKind expected
                    , originRecordOrigin held == originRecordOrigin expected ->
                        Right ()
                _ -> Left (OwnershipMalformed "reported origin cannot be re-entered for binding")
        publishBinding = publishBoundRecord (reportedTape session) key

-- | Reconcile only a Managed lineage's manifest under its actual protected entry.
-- Publish the canonical manifest first, then its evidence at the exact stage
-- version. A crash between these writes leaves Managed and can be reconciled;
-- every ordinary reader refuses incoherent proof until that repair completes.
refreshManagedColimaManifest ::
    ProtectedSession session -> ColimaOwnershipKeys -> RecordVersion -> ColimaStageRecord ->
    FilePath -> FilePath -> IO (Either OwnershipFault (RecordVersion, ColimaStageRecord))
refreshManagedColimaManifest session keys version record home context =
    withOwnershipRow ownershipRowForHost $ \primitives ->
        case clauseRefusal (rowCapabilities primitives) ClauseRelease of
            Just refusal -> pure (Left refusal)
            Nothing -> case clauseRefusal (rowCapabilities primitives) ClauseRecord of
                Just refusal -> pure (Left refusal)
                Nothing -> case request of
                    Left fault -> pure (Left fault)
                    Right _ -> do
                        parents <- revalidateColimaContextParents session context
                        case parents of
                            Left fault -> pure (Left fault)
                            Right () -> refreshInside
  where
    request = case colimaStageRecordEvidence record of
        Nothing -> Left (OwnershipMalformed "the manifest refresh lacks Managed evidence")
        Just evidence -> first (OwnershipMalformed . Text.pack) $
            refreshColimaManifestRecord record (managedManifestDigest evidence) (managedDirectoryChainDigest evidence)
    roots =
        [ (colimaHomeKey keys, home), (colimaContextKey keys, context)
        , (colimaCacheKey keys, home </> "cache"), (colimaTemporaryKey keys, home </> "tmp")
        ]
    readRoots = sequence <$> traverse (uncurry (readRetainedColimaDirectoryIdentity session)) roots
    refreshInside = do
        stage <- readColimaStage session keys
        retained <- readRetainedColimaManifest session keys
        case (stage, retained) of
            (Left fault, _) -> pure (Left fault)
            (_, Left fault) -> pure (Left fault)
            (Right Nothing, _) -> pure (Left (OwnershipMalformed "the Managed stage is absent during manifest refresh"))
            (Right (Just actual), Right (stored, _))
                | actual /= (version, record) -> pure (Left (OwnershipOccupied "the Managed stage version or lineage changed before manifest refresh"))
                | otherwise -> do
                    before <- readRoots
                    case before of
                        Left fault -> pure (Left fault)
                        Right expectedRoots -> do
                            observed <- observeColimaNamespaceManifest home context
                            after <- readRoots
                            parents <- revalidateColimaContextParents session context
                            case (observed, after, parents) of
                                (Left fault, _, _) -> pure (Left fault)
                                (_, Left fault, _) -> pure (Left fault)
                                (_, _, Left fault) -> pure (Left fault)
                                (Right manifest, Right actualRoots, Right ())
                                    | actualRoots /= expectedRoots -> pure (Left (OwnershipOccupied "a Colima directory binding changed during manifest refresh"))
                                    | otherwise ->
                                        case refreshColimaManifestRecord record (ownershipManifestDigest manifest) (ownershipDirectoryChainDigest manifest) of
                                            Left refusal -> pure (Left (OwnershipMalformed (Text.pack refusal)))
                                            Right successor -> do
                                                published <-
                                                    if protectedRecordBytes stored == renderOwnershipManifest manifest
                                                        then pure (Right ())
                                                        else do
                                                            written <- compareAndSwapProtectedRecord session (colimaManifestKey keys)
                                                                (ExpectVersion (protectedRecordVersion stored)) (renderOwnershipManifest manifest)
                                                            pure (either (Left . storeFault "refresh the Managed Colima manifest") (const (Right ())) written)
                                                case published of
                                                    Left fault -> pure (Left fault)
                                                    Right ()
                                                        | successor == record -> pure (Right (version, record))
                                                        | otherwise -> fmap (fmap (\next -> (next, successor)))
                                                            (writeColimaStage session keys (ExpectVersion version) successor)

{- | Publish Managed only after the profile and disk origins are identity-bound,
the context directory re-enters exactly, and the complete managed evidence
validates. This is the sole Prepared → Managed publication.
-}
settleManagedColimaProfile :: FilePath -> String -> String -> String -> String -> String -> Word64 -> String -> ObjectIdentity -> Integer -> Integer -> Integer -> Integer -> FilePath -> FilePath -> IO (Either ColimaProfileMutationFault ())
settleManagedColimaProfile stateRoot profile owner lineage invocation machine epoch contextDigest expectedDisk cpu memory disk rootDisk homePath contextPath = do
    entered <-
        withColimaOwnershipEntry stateRoot profile $ \session keys ->
            Right <$> settleManagedColimaProfileInside session keys profile owner lineage invocation machine epoch contextDigest expectedDisk cpu memory disk rootDisk homePath contextPath
    pure $ case entered of
        Left refusal -> Left (ColimaMutationEntryRefused refusal)
        Right outcome -> outcome

settleManagedColimaProfileInside ::
    ProtectedSession session ->
    ColimaOwnershipKeys ->
    String ->
    String ->
    String ->
    String ->
    String ->
    Word64 ->
    String ->
    ObjectIdentity ->
    Integer ->
    Integer ->
    Integer ->
    Integer ->
    FilePath ->
    FilePath ->
    IO (Either ColimaProfileMutationFault ())
settleManagedColimaProfileInside session keys _profile owner lineage invocation machine epoch contextDigest expectedDisk cpu memory disk rootDisk homePath contextPath = withValidatedColimaContextParents session contextPath settleInside
  where
    claim = mkOwnerClaim (ByteString.Char8.pack owner)

    settleInside = do
        current <- readColimaStage session keys
        case (current, mkColimaStageRecord ColimaPrepared owner lineage invocation) of
            (Left fault, _) -> pure (Left (ColimaMutationOwnershipRefused fault))
            (_, Left refusal) -> pure (Left (ColimaMutationProfileConflict refusal))
            (Right (Just (version, observed)), Right expected)
                | observed == expected -> do
                    machineIdentity <- pure (parseObjectIdentityHex (Text.pack machine))
                    profileBinding <- readReportedBinding (colimaProfileKey keys)
                    diskBinding <- readReportedBinding (colimaDiskKey keys)
                    auxiliaryDirectories <- ensureAuxiliaryDirectories session keys homePath
                    contextIdentity <- readRetainedColimaDirectoryIdentity session (colimaContextKey keys) contextPath
                    manifest <- revalidateColimaManifest session keys homePath contextPath
                    case (machineIdentity, profileBinding, diskBinding, auxiliaryDirectories, contextIdentity, manifest) of
                        (Left fault, _, _, _, _, _) -> pure (Left (ColimaMutationOwnershipRefused fault))
                        (_, Left fault, _, _, _, _) -> pure (Left (ColimaMutationOwnershipRefused fault))
                        (_, _, Left fault, _, _, _) -> pure (Left (ColimaMutationOwnershipRefused fault))
                        (_, _, _, Left fault, _, _) -> pure (Left (ColimaMutationOwnershipRefused fault))
                        (_, _, _, _, Left fault, _) -> pure (Left (ColimaMutationOwnershipRefused fault))
                        (_, _, _, _, _, Left fault) -> pure (Left (ColimaMutationOwnershipRefused fault))
                        (Right expectedMachine, Right actualMachine, Right actualDisk, Right (), Right _, Right retainedManifest)
                            | expectedMachine /= actualMachine -> pure (Left (ColimaMutationProfileConflict "machine binding differs from settlement"))
                            | expectedDisk /= actualDisk -> pure (Left (ColimaMutationProfileConflict "data disk binding differs from settlement"))
                            | otherwise -> case mkColimaManagedEvidence machine epoch contextDigest (ownershipManifestDigest retainedManifest) (ownershipDirectoryChainDigest retainedManifest) cpu memory disk rootDisk of
                                Left refusal -> pure (Left (ColimaMutationProfileConflict refusal))
                                Right evidence -> case settleColimaStageRecord observed evidence of
                                    Left refusal -> pure (Left (ColimaMutationProfileConflict refusal))
                                    Right managed -> do
                                        written <- writeColimaStage session keys (ExpectVersion version) managed
                                        pure (either (Left . ColimaMutationOwnershipRefused) (const (Right ())) written)
                | otherwise -> pure (Left (ColimaMutationProfileConflict "prepared stage belongs to another lineage"))
            _ -> pure (Left (ColimaMutationProfileConflict "prepared stage is absent"))

    readReportedBinding key = do
        current <- readRecordUnder (reportedTape session) key
        pure $ case current of
            Left fault -> Left fault
            Right Nothing -> Left (OwnershipMalformed "reported identity binding is absent")
            Right (Just record)
                | originRecordKind record /= ReportedObject claim ->
                    Left (OwnershipMalformed "reported identity claim differs")
                | otherwise -> case originRecordBinding record of
                    Nothing -> Left (OwnershipMalformed "reported identity remains unbound")
                    Just identity -> Right identity

-- These decisions describe admission only; they mint no resource authority.
colimaContextAcquisitionNeedsProbe :: Maybe ColimaStage -> Bool
colimaContextAcquisitionNeedsProbe Nothing = True
colimaContextAcquisitionNeedsProbe (Just stage) = stage < ColimaContextStaged

admitColimaContextAcquisition :: ColimaProfile -> [String] -> Either ColimaProfileMutationFault ()
admitColimaContextAcquisition profile names
    | colimaContextIsListed profile names =
        Left (ColimaMutationProfileConflict ("the Docker context " ++ contextName ++ " is already present before acquisition"))
    | otherwise = Right ()
  where
    contextName = dockerContextNameText (dockerContextForProfile profile)

colimaContextIsListed :: ColimaProfile -> [String] -> Bool
colimaContextIsListed profile = elem (dockerContextNameText (dockerContextForProfile profile))

colimaContextRemovalNeeded :: ColimaProfile -> [String] -> Bool
colimaContextRemovalNeeded = colimaContextIsListed

admitColimaContextFingerprint :: String -> String -> Either ColimaProfileMutationFault ()
admitColimaContextFingerprint expected actual
    | actual == expected = Right ()
    | otherwise = Left (ColimaMutationProfileConflict "the Docker context fingerprint differs from its retained release authority")

admitColimaContextRemovalAbsence :: ColimaProfile -> [String] -> Either ColimaProfileMutationFault ()
admitColimaContextRemovalAbsence profile names
    | colimaContextIsListed profile names =
        Left (ColimaMutationProfileConflict ("the Docker context " ++ dockerContextNameText (dockerContextForProfile profile) ++ " remains listed after removal"))
    | otherwise = Right ()

{- | The complete acquisition transaction under one protected entry. Every
external result is classified and joined to the shared origin/manifest
vocabulary before the evidence-bearing Managed successor is published.
-}
acquireManagedColimaProfileWith ::
    (HostCommand -> IO (Either String CapturedRun)) ->
    FilePath ->
    String ->
    String ->
    String ->
    String ->
    FilePath ->
    FilePath ->
    Integer ->
    Integer ->
    Integer ->
    Integer ->
    ColimaStartArguments ->
    IO (Either ColimaProfileMutationFault ColimaManagedOutcome)
acquireManagedColimaProfileWith interpret stateRoot profile owner lineage invocation home context cpu memory disk rootDisk startArguments
    | mkColimaProfile profile /= Right (colimaStartProfile startArguments) = pure (Left (ColimaMutationEntryRefused "start arguments do not match the owned profile"))
    | otherwise = case mkColimaStageRecord ColimaReserved owner lineage invocation of
        Left refusal -> pure (Left (ColimaMutationProfileConflict refusal))
        Right reserved -> do
            entered <-
                withColimaOwnershipEntry stateRoot profile $ \session keys ->
                    Right <$> acquireInside session keys reserved
            pure $ case entered of
                Left refusal -> Left (ColimaMutationEntryRefused refusal)
                Right outcome -> outcome
  where
    diskPath = home </> "_lima" </> "_disks" </> ("colima-" ++ profile) </> "datadisk"

    acquireInside session keys reserved = do
        current <- readColimaStage session keys
        case current of
            Left fault -> pure (Left (ColimaMutationOwnershipRefused fault))
            Right (Just (_, record))
                | isMatchingManaged record -> validateExact session keys record
            Right (Just (version, record))
                | colimaStageRecordStage record == ColimaReleased ->
                    if colimaStageRecordInvocation record == invocation
                        then pure (Left (ColimaMutationProfileConflict "a released acquisition invocation cannot be replayed"))
                        else do
                            observed <- releasedNamespaceObservation session keys
                            case observed of
                                Left fault -> pure (Left (ColimaMutationOwnershipRefused fault))
                                Right observation -> case decideColimaStage AcquireColima ColimaReleased observation of
                                    Left refusal -> pure (Left (ColimaMutationProfileConflict refusal))
                                    Right BeginColimaLineage -> do
                                        written <- writeColimaStage session keys (ExpectVersion version) reserved
                                        case written of
                                            Left fault -> pure (Left (ColimaMutationOwnershipRefused fault))
                                            Right _ -> applyAcquisition session keys reserved
                                    Right _ -> pure (Left (ColimaMutationProfileConflict "the released observation did not open a new lineage"))
            Right (Just (_, record))
                | colimaStageRecordStage record > ColimaPrepared ->
                    pure (Left (ColimaMutationProfileConflict "managed stage belongs to another lineage"))
            _ -> applyAcquisition session keys reserved

    releasedNamespaceObservation session keys = observeVacantColimaNamespaces session keys home context

    applyAcquisition session keys reserved = do
        current <- readColimaStage session keys
        case current of
            Left fault -> pure (Left (ColimaMutationOwnershipRefused fault))
            Right retained
                | colimaContextAcquisitionNeedsProbe (fmap (colimaStageRecordStage . snd) retained) -> do
                    reported <- runClassifiedExact listDockerContextsCommand classifyDockerContextListing
                    case reported >>= admitColimaContextAcquisition (colimaCommandProfile keys) of
                        Left fault -> pure (Left fault)
                        Right () -> applyOwnedAcquisition session keys reserved
                | otherwise -> applyOwnedAcquisition session keys reserved

    applyOwnedAcquisition session keys reserved = do
        prepared <- prepareColimaNamespacesInside session keys owner lineage invocation home context reserved
        case prepared of
            Left (ColimaNativeOwnershipRefused fault) -> pure (Left (ColimaMutationOwnershipRefused fault))
            Left (ColimaNativeStageRefused refusal) -> pure (Left (ColimaMutationProfileConflict refusal))
            Left (ColimaNativeStoreRefused refusal) -> pure (Left (ColimaMutationEntryRefused refusal))
            Right () -> do
                started <- startPreparedColimaProfileInside interpret session keys profile owner lineage invocation home context diskPath cpu memory disk startArguments
                case started of
                    Left fault -> pure (Left fault)
                    Right startObservation -> do
                        artifacts <- observeColimaArtifactsInside interpret session keys profile owner lineage invocation home context disk
                        case artifacts of
                            Left fault -> pure (Left fault)
                            Right artifactObservation -> do
                                published <- publishPreparedColimaManifestInside session keys owner lineage invocation (artifactOwnershipManifest artifactObservation)
                                case published of
                                    Left fault -> pure (Left fault)
                                    Right () -> do
                                        bound <- bindColimaCreationIdentitiesInside session keys profile owner lineage invocation (startedMachineIdentity startObservation) (artifactDiskPath artifactObservation)
                                        case bound of
                                            Left fault -> pure (Left fault)
                                            Right (_, diskIdentity)
                                                | diskIdentity /= artifactDiskIdentity artifactObservation ->
                                                    pure (Left (ColimaMutationProfileConflict "data disk identity changed between manifest and binding"))
                                                | otherwise -> do
                                                    settled <-
                                                        settleManagedColimaProfileInside
                                                            session
                                                            keys
                                                            profile
                                                            owner
                                                            lineage
                                                            invocation
                                                            (startedMachineIdentity startObservation)
                                                            (startedMachineEpoch startObservation)
                                                            (artifactContextDigest artifactObservation)
                                                            (artifactDiskIdentity artifactObservation)
                                                            cpu
                                                            memory
                                                            disk
                                                            rootDisk
                                                            home
                                                            context
                                                    pure (ColimaManagedApplied (ColimaManagedObservation startObservation artifactObservation) <$ settled)

    isMatchingManaged record =
        colimaStageRecordStage record == ColimaManaged
            && colimaStageRecordOwner record == owner
            && colimaStageRecordLineage record == lineage
            && colimaStageRecordInvocation record == invocation

    validateExact session keys record = withValidatedColimaContextParents session context $ case colimaStageRecordEvidence record of
        Nothing -> pure (Left (ColimaMutationProfileConflict "managed stage lacks evidence"))
        Just evidence
            | managedCpu evidence /= cpu
                || managedMemoryBytes evidence /= memory
                || managedDiskBytes evidence /= disk
                || managedRootDiskBytes evidence /= rootDisk ->
                pure (Left (ColimaMutationProfileConflict "managed wall differs from the requested wall"))
            | otherwise -> do
                profiles <- runClassifiedExact listColimaProfilesCommand classifyColimaListing
                machine <- runClassifiedExact (readColimaMachineIdCommand (colimaCommandProfile keys)) classifyMachineIdentity
                artifacts <- observeColimaArtifactsInside interpret session keys profile owner lineage invocation home context disk
                profileBinding <- readBinding session keys (colimaProfileKey keys)
                diskBinding <- readBinding session keys (colimaDiskKey keys)
                pure $ do
                    values <- profiles
                    requireExactProfile values
                    (machineIdentity, machineEpoch) <- machine
                    artifact <- artifacts
                    expectedMachine <- first ColimaMutationOwnershipRefused (parseObjectIdentityHex (Text.pack machineIdentity))
                    actualMachine <- profileBinding
                    actualDisk <- diskBinding
                    if machineIdentity /= managedMachineIdentity evidence || machineEpoch /= managedMachineEpoch evidence
                        then Left (ColimaMutationProfileConflict "managed machine evidence differs")
                        else
                            if expectedMachine /= actualMachine || artifactDiskIdentity artifact /= actualDisk
                                then Left (ColimaMutationProfileConflict "managed identity binding differs")
                                else
                                    if artifactContextDigest artifact /= managedContextDigest evidence
                                        then Left (ColimaMutationProfileConflict "managed context evidence differs")
                                        else
                                            if ownershipManifestDigest (artifactOwnershipManifest artifact) /= managedManifestDigest evidence
                                                || ownershipDirectoryChainDigest (artifactOwnershipManifest artifact) /= managedDirectoryChainDigest evidence
                                                then Left (ColimaMutationProfileConflict "managed manifest evidence differs")
                                                else case decideColimaStage AcquireColima (colimaStageRecordStage record) ColimaProfileExact of
                                                    Left refusal -> Left (ColimaMutationProfileConflict refusal)
                                                    Right KeepColimaStage -> Right (ColimaManagedAlreadyExact (ColimaManagedObservation (ColimaStartedObservation machineIdentity machineEpoch) artifact))
                                                    Right _ -> Left (ColimaMutationProfileConflict "the exact Managed observation did not retain its stage")

    requireExactProfile values = case filter ((== profile) . ciName) values of
        [value]
            | map lowerAscii (ciStatus value) == "running"
            , map lowerAscii (ciRuntime value) == "docker"
            , ciCpus value == cpu
            , ciMemoryBytes value == memory
            , ciDiskBytes value == disk ->
                Right ()
        _ -> Left (ColimaMutationProfileConflict "managed profile wall differs")

    lowerAscii character
        | character >= 'A' && character <= 'Z' = toEnum (fromEnum character + 32)
        | otherwise = character

    runClassifiedExact command classify = do
        result <- interpret command
        pure $ case result of
            Left refusal -> Left (ColimaMutationCommandUnavailable refusal)
            Right captured -> first ColimaMutationReportRefused (classify captured)

    readBinding session _keys key = do
        current <- readRecordUnder (reportedTape session) key
        pure $ case current of
            Left fault -> Left (ColimaMutationOwnershipRefused fault)
            Right Nothing -> Left (ColimaMutationProfileConflict "managed identity binding is absent")
            Right (Just record) -> case originRecordBinding record of
                Nothing -> Left (ColimaMutationProfileConflict "managed identity remains unbound")
                Just identity -> Right identity

-- | The acquisition lineage has one comparison for Docker and cleanup policies.
colimaManagedLineageMatches :: String -> String -> String -> ColimaStageRecord -> Bool
colimaManagedLineageMatches owner lineage invocation record =
    colimaStageRecordOwner record == owner
        && colimaStageRecordLineage record == lineage
        && colimaStageRecordInvocation record == invocation

-- | Pure lineage admission precedes every cleanup replay or mutation branch.
-- It grants no cleanup authority and leaves stage policy to the driver.
admitColimaCleanupLineage :: String -> String -> String -> ColimaStageRecord -> Either ColimaProfileMutationFault ()
admitColimaCleanupLineage owner lineage invocation record
    | colimaManagedLineageMatches owner lineage invocation record = Right ()
    | otherwise = Left (ColimaMutationProfileConflict "managed stage belongs to another lineage")

-- | Profile facts are descriptive; only the owning entry can act on them.
data ColimaCleanupProfileObservation = ColimaCleanupProfilePresent | ColimaCleanupProfileAbsent
    deriving (Eq, Show)

classifyColimaCleanupProfile :: String -> ColimaStageRecord -> [ColimaInstance] -> Either ColimaProfileMutationFault ColimaCleanupProfileObservation
classifyColimaCleanupProfile profile record values = case filter ((== profile) . ciName) values of
    [value] -> case colimaStageRecordEvidence record of
        Just evidence
            | ciCpus value == managedCpu evidence
            , ciMemoryBytes value == managedMemoryBytes evidence
            , ciDiskBytes value == managedDiskBytes evidence
            , ciRuntime value == "docker" -> Right ColimaCleanupProfilePresent
        _ -> Left (ColimaMutationProfileConflict "managed profile wall or runtime changed before delete")
    [] | colimaStageRecordStage record == ColimaReleasing -> Right ColimaCleanupProfileAbsent
       | otherwise -> Left (ColimaMutationProfileConflict "profile is absent before delete")
    _ -> Left (ColimaMutationProfileConflict "profile listing is duplicated")

admitColimaCleanupMachine :: ColimaStageRecord -> Maybe ObjectIdentity -> String -> Word64 -> Either ColimaProfileMutationFault ObjectIdentity
admitColimaCleanupMachine record binding machine epoch = do
    case colimaStageRecordEvidence record of
        Just evidence | managedMachineIdentity evidence == machine && managedMachineEpoch evidence == epoch -> Right ()
        _ -> Left (ColimaMutationProfileConflict "managed machine evidence changed before delete")
    identity <- first ColimaMutationOwnershipRefused (parseObjectIdentityHex (Text.pack machine))
    if binding == Just identity then Right identity
        else Left (ColimaMutationProfileConflict "profile identity changed before delete")

colimaCleanupDeleteResult :: Either ColimaProfileMutationFault CapturedRun -> Either ColimaProfileMutationFault ()
colimaCleanupDeleteResult result = do
    captured <- result
    if capturedExit captured == ExitSuccess then Right () else Left ColimaMutationDeleteFailed

admitColimaCleanupProfileAbsence :: String -> [ColimaInstance] -> Either ColimaProfileMutationFault ColimaStageObservation
admitColimaCleanupProfileAbsence profile values
    | any ((== profile) . ciName) values = Left (ColimaMutationProfileConflict "profile remained present after delete")
    | otherwise = Right ColimaProfileAbsent

-- | A frozen release may lose retained entries, never gain or replace them.
admitColimaReleaseManifest :: ColimaStageRecord -> OwnershipManifest -> OwnershipManifest -> Either OwnershipFault OwnershipManifest
admitColimaReleaseManifest record retained current = do
    case colimaStageRecordEvidence record of
        Just evidence
            | colimaStageRecordStage record `elem` [ColimaReleasing, ColimaContextReleased, ColimaReleased]
            , managedManifestDigest evidence == ownershipManifestDigest retained
            , managedDirectoryChainDigest evidence == ownershipDirectoryChainDigest retained -> Right ()
        _ -> Left (OwnershipMalformed "the frozen Colima release manifest differs from its committed evidence")
    _ <- admitOwnershipManifestRemainders [] retained current
    Right retained

-- | Descriptive retry choice; none of these values grants deletion authority.
data ColimaCleanupResume
    = ColimaCleanupFromManaged
    | ColimaCleanupFromReleasing
    | ColimaCleanupFromContextReleased
    | ColimaCleanupReleasedReplay
    deriving (Eq, Show)

admitColimaCleanupResume :: String -> ColimaStageRecord -> Either ColimaProfileMutationFault ColimaCleanupResume
admitColimaCleanupResume cleanupInvocation record = case colimaStageRecordStage record of
    ColimaManaged -> Right ColimaCleanupFromManaged
    ColimaReleasing | sameRelease -> Right ColimaCleanupFromReleasing
    ColimaContextReleased | sameRelease -> Right ColimaCleanupFromContextReleased
    ColimaReleased | sameRelease -> Right ColimaCleanupReleasedReplay
    _ -> Left (ColimaMutationOwnershipRefused (OwnershipMalformed "Colima cleanup stage is not resumable"))
  where
    sameRelease = colimaStageRecordCleanupInvocation record == Just cleanupInvocation

{- | Clause-4 cleanup for one evidence-bearing Managed profile. The cleanup
invocation is durable before the destructive command; both reported
artifacts are forgotten only after the command's authority and the kernel
independently report them absent. The isolated namespaces are then released
by exact identity in durable stage order.
-}
cleanupManagedColimaProfileWith ::
    (HostCommand -> IO (Either String CapturedRun)) ->
    FilePath ->
    String ->
    String ->
    String ->
    String ->
    String ->
    FilePath ->
    FilePath ->
    FilePath ->
    IO (Either ColimaProfileMutationFault ())
cleanupManagedColimaProfileWith interpret stateRoot profile owner lineage invocation cleanupInvocation home context diskPath = do
    entered <-
        withColimaOwnershipEntry stateRoot profile $ \session keys ->
            Right <$> cleanupInside session keys
    pure $ case entered of
        Left refusal -> Left (ColimaMutationEntryRefused refusal)
        Right outcome -> outcome
  where
    cleanupInside session keys = do
        current <- readColimaStage session keys
        case current of
            Left fault -> pure (ownershipFailure fault)
            Right Nothing -> pure (conflict "managed stage is absent")
            Right (Just (version, record))
                | Left fault <- admitColimaCleanupLineage owner lineage invocation record -> pure (Left fault)
                | otherwise -> case admitColimaCleanupResume cleanupInvocation record of
                    Left fault -> pure (Left fault)
                    Right ColimaCleanupReleasedReplay -> replayCompletedRelease session keys version record
                    Right ColimaCleanupFromManaged -> withValidatedColimaContextParents session context $ do
                        refreshed <- refreshManagedColimaManifest session keys version record home context
                        continueRelease session keys refreshed
                    Right ColimaCleanupFromReleasing -> withValidatedColimaContextParents session context $
                        continueRelease session keys (Right (version, record))
                    Right ColimaCleanupFromContextReleased -> withValidatedColimaContextParents session context $
                        finishContextRelease session keys version record

    continueRelease session keys releasing = case releasing of
        Left fault -> pure (ownershipFailure fault)
        Right (heldVersion, heldRecord) -> do
            manifest <- case colimaStageRecordStage heldRecord of
                ColimaReleasing -> releaseManifest session keys heldRecord
                _ -> revalidateColimaManifest session keys home context
            case manifest of
                Left fault -> pure (ownershipFailure fault)
                Right retainedManifest -> releaseProfile session keys heldVersion heldRecord retainedManifest

    releaseManifest session keys record = do
        retained <- readRetainedColimaManifest session keys
        observed <- observeColimaNamespaceManifest home context
        roots <- traverse (uncurry (readRetainedColimaDirectoryIdentity session))
            [(colimaHomeKey keys, home), (colimaContextKey keys, context)]
        pure $ do
            (_, expected) <- retained
            _ <- sequence roots
            actual <- observed
            admitColimaReleaseManifest record expected actual

    resumeAbsentProfile session keys heldVersion heldRecord retainedManifest = do
        after <- observeProfiles
        case after >>= admitColimaCleanupProfileAbsence profile of
            Left fault -> pure (Left fault)
            Right observation -> do
                current <- readColimaStage session keys
                diskAfter <- observeKernelOrigin session diskPath
                case (current, diskAfter) of
                    (Left fault, _) -> pure (ownershipFailure fault)
                    (_, Left fault) -> pure (ownershipFailure fault)
                    (Right (Just (version, record)), Right OriginAbsent)
                        | version == heldVersion && record == heldRecord
                        , admitColimaCleanupResume cleanupInvocation record == Right ColimaCleanupFromReleasing -> do
                            profileRecord <- readStoredRecordUnder (reportedTape session) (colimaProfileKey keys)
                            diskRecord <- readStoredRecordUnder (reportedTape session) (colimaDiskKey keys)
                            case (profileRecord, diskRecord) of
                                (Left fault, _) -> pure (ownershipFailure fault)
                                (_, Left fault) -> pure (ownershipFailure fault)
                                (Right profileOrigin, Right diskOrigin) ->
                                    case (validateRetainedReported profileOrigin >> validateRetainedReported diskOrigin,
                                          colimaStageRecordEvidence heldRecord) of
                                        (Left fault, _) -> pure (ownershipFailure fault)
                                        (_, Nothing) -> pure (conflict "the committed release lacks machine evidence")
                                        (Right (), Just evidence) ->
                                            case parseObjectIdentityHex (Text.pack (managedMachineIdentity evidence)) of
                                                Left fault -> pure (ownershipFailure fault)
                                                Right identity
                                                    | maybe False ((/= Just identity) . originRecordBinding . storedOriginRecord) profileOrigin ->
                                                        pure (conflict "profile identity changed before origin recovery")
                                                    | otherwise -> do
                                                        profileReleased <- resumeOrigin session (colimaProfileKey keys) ("colima-profile:" ++ profile) profileOrigin
                                                        case profileReleased of
                                                            Left fault -> pure (ownershipFailure fault)
                                                            Right () -> do
                                                                diskReleased <- resumeOrigin session (colimaDiskKey keys) diskPath diskOrigin
                                                                case diskReleased of
                                                                    Left fault -> pure (ownershipFailure fault)
                                                                    Right () -> finishReleasedProfile session keys heldVersion heldRecord retainedManifest observation
                    (Right _, Right OriginAbsent) -> pure (conflict "cleanup stage changed before origin recovery")
                    (_, Right present) -> pure (ownershipFailure (OwnershipConflict (ConflictReport (Text.pack diskPath) OriginAbsent present)))

    validateRetainedReported Nothing = Right ()
    validateRetainedReported (Just stored) = case (originRecordKind record, originRecordBinding record) of
        (ReportedObject _, Just _) -> Right ()
        _ -> Left (OwnershipMalformed "a retained cleanup origin is not a bound reported object")
      where
        record = storedOriginRecord stored

    resumeOrigin _session _key _target Nothing = pure (Right ())
    resumeOrigin session key target (Just stored) =
        reenterStoredReportedObject session target stored $ \bound ->
            resumeReportedRemoval bound OriginAbsent
                (const (forgetRecordAtVersion (reportedTape session) key (storedRecordVersion stored)))

    releaseDecision record observation =
        first ColimaMutationProfileConflict (decideColimaStage ReleaseColima (colimaStageRecordStage record) observation)

    freezeAndChooseDelete session keys version record observation =
        case releaseDecision record observation of
            Left fault -> pure (Left fault)
            Right (AdvanceColimaStage ColimaReleasing) -> case beginColimaReleaseRecord record cleanupInvocation of
                Left refusal -> pure (conflict refusal)
                Right successor -> do
                    written <- writeColimaStage session keys (ExpectVersion version) successor
                    case written of
                        Left fault -> pure (ownershipFailure fault)
                        Right nextVersion -> freezeAndChooseDelete session keys nextVersion successor observation
            Right DeleteColimaProfile -> pure (Right (version, record))
            Right _ -> pure (conflict "the stage table did not authorize profile deletion")

    advanceRelease record observation successor = do
        decision <- decideColimaStage ReleaseColima (colimaStageRecordStage record) observation
        case decision of
            AdvanceColimaStage expected | expected == successor -> advanceSettledColimaStageRecord record expected
            _ -> Left "the stage table did not authorize cleanup settlement"

    replayCompletedRelease session keys version record = do
        vacant <- observeVacantColimaNamespaces session keys home context
        case vacant of
            Left fault -> pure (ownershipFailure fault)
            Right ColimaNamespaceAbsent -> first ColimaMutationOwnershipRefused <$>
                releaseColimaReleasedNamespaces session keys version record home context
            Right _ -> pure (ownershipFailure (OwnershipMalformed "released namespaces are not vacant"))

    -- An observation becomes ProfileExact only after the live wall, machine,
    -- retained origins and kernel disk identity agree. Freeze is downstream.
    releaseProfile session keys heldVersion heldRecord retainedManifest = do
        before <- observeProfiles
        case before >>= classifyColimaCleanupProfile profile heldRecord of
            Left fault -> pure (Left fault)
            Right ColimaCleanupProfileAbsent -> resumeAbsentProfile session keys heldVersion heldRecord retainedManifest
            Right ColimaCleanupProfilePresent -> do
                machine <- runCommand (readColimaMachineIdCommand (colimaCommandProfile keys))
                case machine >>= either (Left . ColimaMutationReportRefused) Right . classifyMachineIdentity of
                    Left fault -> pure (Left fault)
                    Right (machineHex, machineEpoch) -> do
                        profileRecord <- readBoundRecord session (colimaProfileKey keys)
                        diskRecord <- readBoundRecord session (colimaDiskKey keys)
                        case (profileRecord, diskRecord) of
                            (Left fault, _) -> pure (ownershipFailure fault)
                            (_, Left fault) -> pure (ownershipFailure fault)
                            (Right profileOrigin, Right diskOrigin) ->
                                case admitColimaCleanupMachine heldRecord (originRecordBinding (storedOriginRecord profileOrigin)) machineHex machineEpoch of
                                    Left fault -> pure (Left fault)
                                    Right machineIdentity -> do
                                        released <-
                                            reenterStoredReportedObject session ("colima-profile:" ++ profile) profileOrigin $ \profileBound ->
                                                case reobserveReportedIdentity profileBound (OriginPresent machineIdentity) of
                                                    Left fault -> pure (Left fault)
                                                    Right profileReleasable ->
                                                        reenterStoredReportedObject session diskPath diskOrigin $ \diskBound -> do
                                                            diskObserved <- observeKernelOrigin session diskPath
                                                            case diskObserved >>= reobserveReportedIdentity diskBound of
                                                                Left fault -> pure (Left fault)
                                                                Right diskReleasable ->
                                                                    Right <$> do
                                                                        choice <- freezeAndChooseDelete session keys heldVersion heldRecord ColimaProfileExact
                                                                        case choice of
                                                                            Left fault -> pure (Left fault)
                                                                            Right (releaseVersion, releasingRecord) -> do
                                                                                deleted <- runCommand (deleteColimaProfileCommand (colimaCommandProfile keys))
                                                                                case colimaCleanupDeleteResult deleted of
                                                                                    Left fault -> pure (Left fault)
                                                                                    Right () -> settleAbsence session keys releaseVersion releasingRecord retainedManifest (storedRecordVersion profileOrigin) profileReleasable (storedRecordVersion diskOrigin) diskReleasable
                                        pure (either ownershipFailure id released)

    settleAbsence session keys releaseVersion releasingRecord retainedManifest profileVersion profileReleasable diskVersion diskReleasable = do
        after <- observeProfiles
        diskAfter <- observeKernelOrigin session diskPath
        case (after >>= admitColimaCleanupProfileAbsence profile, diskAfter) of
            (Left fault, _) -> pure (Left fault)
            (_, Left fault) -> pure (ownershipFailure fault)
            (Right observation, Right diskOrigin) -> do
                profileReleased <- releaseReportedObject profileReleasable OriginAbsent (const (forgetRecordAtVersion (reportedTape session) (colimaProfileKey keys) profileVersion))
                diskReleased <- releaseReportedObject diskReleasable diskOrigin (const (forgetRecordAtVersion (reportedTape session) (colimaDiskKey keys) diskVersion))
                case (profileReleased, diskReleased) of
                    (Left fault, _) -> pure (ownershipFailure fault)
                    (_, Left fault) -> pure (ownershipFailure fault)
                    (Right (), Right ()) -> finishReleasedProfile session keys releaseVersion releasingRecord retainedManifest observation

    finishReleasedProfile session keys releaseVersion releasingRecord retainedManifest observation = do
        releasedRemainders <- releaseNamespaceRemainders session (colimaHomeKey keys) home True "colima" ["cache", "tmp"] retainedManifest
        case releasedRemainders of
            Left fault -> pure (ownershipFailure fault)
            Right () -> finishNamespaces session keys releaseVersion releasingRecord observation

    finishNamespaces session keys releaseVersion releasingRecord observation =
        case advanceRelease releasingRecord observation ColimaContextReleased of
            Left refusal -> pure (conflict refusal)
            Right contextReleased -> do
                removed <- removeOwnedContext session keys releasingRecord
                case removed of
                    Left fault -> pure (Left fault)
                    Right () -> do
                        current <- readColimaStage session keys
                        case current of
                            Right (Just (version, currentRecord))
                              | version /= releaseVersion || currentRecord /= releasingRecord -> pure (conflict "cleanup stage changed before namespace settlement")
                              | otherwise -> do
                                written <- writeColimaStage session keys (ExpectVersion version) contextReleased
                                case written of
                                    Left fault -> pure (ownershipFailure fault)
                                    Right nextVersion -> finishContextRelease session keys nextVersion contextReleased
                            Left fault -> pure (ownershipFailure fault)
                            Right Nothing -> pure (conflict "cleanup stage vanished")

    finishContextRelease session keys nextVersion contextReleased = do
        vacant <- observeVacantColimaNamespaces session keys home context
        settled <- case vacant of
            Right ColimaNamespaceAbsent -> pure (Right ())
            _ -> releaseColimaContextNamespace session keys nextVersion contextReleased context
        case settled of
            Left fault -> pure (ownershipFailure fault)
            Right () -> do
                namespaces <- releaseColimaReleasedNamespaces session keys nextVersion contextReleased home context
                case namespaces of
                    Left fault -> pure (ownershipFailure fault)
                    Right () -> case advanceRelease contextReleased ColimaNamespaceAbsent ColimaReleased of
                        Left refusal -> pure (conflict refusal)
                        Right released -> do
                            final <- writeColimaStage session keys (ExpectVersion nextVersion) released
                            case final of
                                Left fault -> pure (ownershipFailure fault)
                                Right releasedVersion -> replayCompletedRelease session keys releasedVersion released

    removeOwnedContext session keys releaseRecord = do
        listed <- observeContextNames
        case listed of
            Left fault -> pure (Left fault)
            Right names
                | not (colimaContextRemovalNeeded (colimaCommandProfile keys) names) -> pure (Right ())
                | otherwise -> case colimaStageRecordEvidence releaseRecord of
                    Nothing -> pure (conflict "the releasing record lacks context evidence")
                    Just evidence -> do
                        before <- readRetainedColimaContextIdentity session keys context
                        case before of
                            Left fault -> pure (ownershipFailure fault)
                            Right contextBefore -> do
                                inspected <- runCommand (inspectDockerContextCommand (dockerContextForProfile (colimaCommandProfile keys)))
                                case inspected >>= either (Left . ColimaMutationReportRefused) Right . classifyDockerContextInspect of
                                    Left fault -> pure (Left fault)
                                    Right value -> do
                                        after <- readRetainedColimaContextIdentity session keys context
                                        case after of
                                            Left fault -> pure (ownershipFailure fault)
                                            Right contextAfter
                                                | contextAfter /= contextBefore ->
                                                    pure (ownershipFailure (OwnershipConflict (ConflictReport "the Docker-config binding changed during context inspection" (OriginPresent (fst contextBefore)) (OriginPresent (fst contextAfter)))))
                                                | otherwise ->
                                                    case admitColimaContextFingerprint (managedContextDigest evidence) (dockerContextFingerprint (fst contextAfter) value) of
                                                        Left fault -> pure (Left fault)
                                                        Right () -> do
                                                            removed <- runCommand (removeDockerContextCommand (dockerContextForProfile (colimaCommandProfile keys)))
                                                            case colimaCleanupDeleteResult removed of
                                                                Left fault -> pure (Left fault)
                                                                Right () -> do
                                                                    remaining <- observeContextNames
                                                                    pure (remaining >>= admitColimaContextRemovalAbsence (colimaCommandProfile keys))

    observeContextNames = do
        result <- runCommand listDockerContextsCommand
        pure (result >>= either (Left . ColimaMutationReportRefused) Right . classifyDockerContextListing)

    observeProfiles = do
        result <- runCommand listColimaProfilesCommand
        pure (result >>= either (Left . ColimaMutationReportRefused) Right . classifyColimaListing)

    runCommand command = first ColimaMutationCommandUnavailable <$> interpret command
    conflict = Left . ColimaMutationProfileConflict
    ownershipFailure = Left . ColimaMutationOwnershipRefused

    readBoundRecord session key = do
        current <- readStoredRecordUnder (reportedTape session) key
        pure $ case current of
            Left fault -> Left fault
            Right Nothing -> Left (OwnershipMalformed "cleanup binding is absent")
            Right (Just record) -> case originRecordBinding (storedOriginRecord record) of
                Nothing -> Left (OwnershipMalformed "cleanup binding is unbound")
                Just _ -> Right record



-- | Settle only the retained roots of the exact Released stage, including retries.
releaseColimaReleasedNamespaces :: ProtectedSession session -> ColimaOwnershipKeys -> RecordVersion -> ColimaStageRecord -> FilePath -> FilePath -> IO (Either OwnershipFault ())
releaseColimaReleasedNamespaces session keys heldVersion heldRecord home context = do
    stage <- readColimaStage session keys
    artifacts <- traverse (readProtectedRecord session) [colimaContextKey keys, colimaProfileKey keys, colimaDiskKey keys]
    contextOrigin <- observeKernelOrigin session context
    retained <- readProtectedRecord session (colimaManifestKey keys)
    let admitted = do
            current <- stage
            case current of
                Just (version, record)
                    | version == heldVersion && record == heldRecord
                    , colimaStageRecordStage record `elem` [ColimaContextReleased, ColimaReleased] -> Right ()
                _ -> Left (OwnershipMalformed "the held Released stage changed before namespace settlement")
            records <- first (storeFault "read released Colima bindings") (sequence artifacts)
            origin <- contextOrigin
            if origin == OriginAbsent && all missing records
                then first (storeFault "read released Colima manifest") retained
                else Left (OwnershipOccupied "released artifacts still carry objects or bindings")
    case admitted of
        Left fault -> pure (Left fault)
        Right Nothing -> completed
        Right (Just stored) -> case parseOwnershipManifest (protectedRecordBytes stored)
            >>= (\manifest -> admitColimaReleaseManifest heldRecord manifest manifest) of
                Left fault -> pure (Left fault)
                Right manifest -> do
                    roots <- traverse verifyRoot namespaceRoots
                    case sequence roots >> choose ColimaReleasedNamespaceExact ReleaseColimaNamespace of
                        Left fault -> pure (Left fault)
                        Right () -> do
                            observed <- observeKernelOrigin session home
                            cleared <- case observed of
                                Left fault -> pure (Left fault)
                                Right OriginAbsent -> pure (Right ())
                                Right (OriginPresent _) -> releaseNamespaceRemainders session (colimaHomeKey keys) home True "colima" [] manifest
                            case cleared of
                                Left fault -> pure (Left fault)
                                Right () -> do
                                    released <- releaseRoots (reverse namespaceRoots)
                                    case released of
                                        Left fault -> pure (Left fault)
                                        Right () -> do
                                            forgotten <- compareAndDeleteProtectedRecord session (colimaManifestKey keys) (ExpectVersion (protectedRecordVersion stored))
                                            case forgotten of
                                                Left fault -> pure (Left (storeFault "forget released Colima manifest" fault))
                                                Right () -> completed
  where
    namespaceRoots = [(colimaHomeKey keys, home), (colimaCacheKey keys, home </> "cache"), (colimaTemporaryKey keys, home </> "tmp")]
    missing Nothing = True
    missing (Just _) = False
    choose observation expected = do
        decision <- first (OwnershipMalformed . Text.pack) (decideColimaStage ReleaseColima (colimaStageRecordStage heldRecord) observation)
        if decision == expected then Right () else Left (OwnershipMalformed "the stage table refused namespace settlement")
    completed = do
        vacant <- observeVacantColimaNamespaces session keys home context
        case vacant >>= (\observation -> choose observation expectedVacancy) of
            Left fault -> pure (Left fault)
            Right () -> if colimaStageRecordStage heldRecord == ColimaReleased
                then releaseColimaContextParents session context
                else pure (Right ())
    expectedVacancy = case colimaStageRecordStage heldRecord of
        ColimaContextReleased -> AdvanceColimaStage ColimaReleased
        _ -> KeepColimaStage
    verifyRoot (key, target) = do
        retained <- readStoredRecordUnder (directoryTape session) key
        observed <- observeKernelOrigin session target
        case (retained, observed) of
            (Left fault, _) -> pure (Left fault)
            (_, Left fault) -> pure (Left fault)
            (Right Nothing, Right OriginAbsent) -> pure (Right ())
            (Right Nothing, Right (OriginPresent _)) -> pure (Left (OwnershipOccupied "an unrecorded Colima namespace root remains present"))
            (Right (Just stored), Right OriginAbsent) -> pure (() <$ colimaDirectoryBinding (storedOriginRecord stored))
            (Right (Just _), Right (OriginPresent _)) -> (() <$) <$> readRetainedColimaDirectoryIdentity session key target
    releaseRoots [] = pure (Right ())
    releaseRoots ((key, target) : remaining) = do
        released <- releaseColimaDirectory session key target
        case released of
            Left fault -> pure (Left fault)
            Right () -> releaseRoots remaining

-- | Complete only the kernel context namespace of the exact held release.
releaseColimaContextNamespace :: ProtectedSession session -> ColimaOwnershipKeys -> RecordVersion -> ColimaStageRecord -> FilePath -> IO (Either OwnershipFault ())
releaseColimaContextNamespace session keys heldVersion heldRecord context = do
    stage <- readColimaStage session keys
    retained <- readRetainedColimaManifest session keys
    parents <- revalidateColimaContextParents session context
    let admitted = do
            actual <- stage
            case actual of
                Just (version, record)
                    | version == heldVersion && record == heldRecord
                    , colimaStageRecordStage record == ColimaContextReleased -> Right ()
                _ -> Left (OwnershipMalformed "the held ContextReleased stage changed before namespace settlement")
            (_, manifest) <- retained
            _ <- admitColimaReleaseManifest heldRecord manifest manifest
            _ <- parents
            Right manifest
    case admitted of
        Left fault -> pure (Left fault)
        Right manifest -> do
            observed <- observeKernelOrigin session context
            cleared <- case observed of
                Left fault -> pure (Left fault)
                Right OriginAbsent -> pure (Right ())
                Right (OriginPresent _) -> releaseNamespaceRemainders session (colimaContextKey keys) context False "docker" [] manifest
            case cleared of
                Left fault -> pure (Left fault)
                Right () -> releaseColimaDirectory session (colimaContextKey keys) context

-- The pre-delete manifest bounds admission; a fresh observation can only
-- prove which retained entries remain, never grant new release authority.
releaseNamespaceRemainders :: ProtectedSession session -> RecordKey -> FilePath -> Bool -> ByteString.ByteString -> [ByteString.ByteString] -> OwnershipManifest -> IO (Either OwnershipFault ())
releaseNamespaceRemainders session key root mutable namespace exclusions retainedManifest = do
    retained <- readStoredRecordUnder (directoryTape session) key
    case retained of
        Left fault -> pure (Left fault)
        Right Nothing -> pure (Left (OwnershipMalformed "namespace directory ownership record is absent"))
        Right (Just record)
            | originRecordKind (storedOriginRecord record) /= OwnedDirectory
                || originRecordOrigin (storedOriginRecord record) /= OriginAbsent ->
                pure (Left (OwnershipOccupied "the namespace directory was not created by this owner"))
            | otherwise ->
                reenterStoredOwnedObject ownershipRowForHost session root record $ \parent -> do
                    present <- reobserveOwnedIdentity ownershipRowForHost parent
                    case present of
                        Left fault -> pure (Left fault)
                        Right _ -> do
                            current <- observeOwnershipManifestForHost mutable root
                            case current of
                                Left fault -> pure (Left fault)
                                Right observed ->
                                    case projectOwnershipManifest namespace retainedManifest
                                        >>= (\expected -> admitOwnershipManifestRemainders exclusions expected observed) of
                                        Left fault -> pure (Left fault)
                                        Right admitted -> releaseEntries parent (sortOn (Down . ByteString.count 47 . manifestEntryPath) admitted)
  where
    releaseEntries _parent [] = pure (Right ())
    releaseEntries parent (entry : remaining) = do
        released <- releaseManifestRemainder parent entry
        case released of
            Left fault -> pure (Left fault)
            Right () -> releaseEntries parent remaining

-- | Pure route admission; refusal precedes the routed command.
admitColimaManagedDockerRoute :: String -> String -> String -> ColimaStageRecord -> Either ColimaProfileMutationFault ()
admitColimaManagedDockerRoute owner lineage invocation record
    | colimaStageRecordStage record /= ColimaManaged
        || not (colimaManagedLineageMatches owner lineage invocation record) =
        Left (ColimaMutationProfileConflict "Docker route is not owned by this Managed lineage")
    | otherwise = Right ()

-- | An unavailable command has no captured run, including a native timeout.
colimaDockerCommandResult :: Either String CapturedRun -> Either ColimaProfileMutationFault CapturedRun
colimaDockerCommandResult = first ColimaMutationCommandUnavailable

-- | Read-only standing admission precedes namespace or command effects.
admitStoredColimaDockerRoute :: ProtectedSession session -> ColimaOwnershipKeys -> String -> String -> String -> IO (Either ColimaProfileMutationFault ())
admitStoredColimaDockerRoute session keys owner lineage invocation = do
    current <- readColimaStage session keys
    pure $ do
        stored <- first ColimaMutationOwnershipRefused current
        case stored of
            Nothing -> Left (ColimaMutationProfileConflict "Managed stage is absent")
            Just (_, record) -> admitColimaManagedDockerRoute owner lineage invocation record

{- | Run one Docker command through the fixed profile route while the same
ownership entry proves the Managed stage, machine binding, and context
directory on both sides of the effect.
-}
runManagedColimaDockerWith ::
    (HostCommand -> IO (Either String CapturedRun)) ->
    FilePath ->
    String ->
    String ->
    String ->
    String ->
    FilePath ->
    FilePath ->
    [String] ->
    IO (Either ColimaProfileMutationFault (CapturedRun, Maybe ColimaProfileMutationFault))
runManagedColimaDockerWith interpret stateRoot profile owner lineage invocation home context arguments =
    case mkColimaProfile profile of
        Left refusal -> pure (Left (ColimaMutationEntryRefused refusal))
        Right commandProfile -> case routedDockerCommand (dockerContextForProfile commandProfile) arguments of
          Left refusal -> pure (Left (ColimaMutationProfileConflict refusal))
          Right dockerCommand -> do
            entered <-
                withColimaOwnershipEntry stateRoot profile $ \session keys ->
                    Right <$> runInside session keys dockerCommand
            pure $ case entered of
                Left refusal -> Left (ColimaMutationEntryRefused refusal)
                Right outcome -> outcome
  where
    runInside session keys dockerCommand = do
        admitted <- validateStanding session keys
        case admitted of
            Left fault -> pure (Left fault)
            Right () -> do
                result <- runCommand dockerCommand
                case result of
                    Left fault -> pure (Left fault)
                    Right captured -> do
                        retained <- validateStanding session keys
                        pure (Right (captured, either Just (const Nothing) retained))

    validateStanding session keys = do
        stageAdmission <- admitStoredColimaDockerRoute session keys owner lineage invocation
        case stageAdmission of
            Left fault -> pure (Left fault)
            Right () -> withValidatedColimaContextParents session context $ do
                contextStanding <- readRetainedColimaDirectoryIdentity session (colimaContextKey keys) context
                manifestStanding <- revalidateColimaManifest session keys home context
                profileRecord <- readRecordUnder (reportedTape session) (colimaProfileKey keys)
                let admitted = do
                        _ <- either (Left . ColimaMutationOwnershipRefused) Right contextStanding
                        _ <- either (Left . ColimaMutationOwnershipRefused) Right manifestStanding
                        origin <- either (Left . ColimaMutationOwnershipRefused) maybeProfile profileRecord
                        maybe (Left (ColimaMutationProfileConflict "Docker profile binding is absent")) Right (originRecordBinding origin)
                case admitted of
                    Left fault -> pure (Left fault)
                    Right binding -> do
                        listing <- runCommand listColimaProfilesCommand
                        machine <- runCommand (readColimaMachineIdCommand (colimaCommandProfile keys))
                        pure $ do
                            values <- listing >>= either (Left . ColimaMutationReportRefused) Right . classifyColimaListing
                            case filter ((== profile) . ciName) values of
                                [value]
                                    | map lowerAscii (ciStatus value) == "running" && map lowerAscii (ciRuntime value) == "docker" -> Right ()
                                _ -> Left (ColimaMutationProfileConflict "Docker profile is not uniquely running")
                            (machineHex, _) <- machine >>= either (Left . ColimaMutationReportRefused) Right . classifyMachineIdentity
                            observed <- either (Left . ColimaMutationOwnershipRefused) Right (parseObjectIdentityHex (Text.pack machineHex))
                            if observed == binding
                                then Right ()
                                else Left (ColimaMutationProfileConflict "Docker profile identity changed")

    maybeProfile Nothing = Left (ColimaMutationProfileConflict "Docker profile binding is absent")
    maybeProfile (Just value) = Right value
    runCommand command = colimaDockerCommandResult <$> interpret command
    lowerAscii character
        | character >= 'A' && character <= 'Z' = toEnum (fromEnum character + 32)
        | otherwise = character

{- | What this module calls the two kinds of record it publishes.

The reported origin is answered for by Colima itself; the directory origin is a
host object this process created. They are two subjects rather than one because
their refusals name different things, and everything else about publishing them
is the shared tape's.
-}
reportedTape :: ProtectedSession session -> RecordTape session
reportedTape session =
    recordTape
        session
        RecordSubject
            { subjectRecord = "the reported Colima origin record"
            , subjectBinding = "bind the reported Colima identity"
            }

directoryTape :: ProtectedSession session -> RecordTape session
directoryTape session =
    recordTape
        session
        RecordSubject
            { subjectRecord = "the Colima directory origin record"
            , subjectBinding = "bind the Colima directory identity"
            }

{- | Clauses 1–3 for one Colima-owned directory. Existing objects are never
adopted; recovery from a retained origin is handled by the stage driver.
-}
acquireColimaDirectory :: ProtectedSession session -> RecordKey -> FilePath -> IO (Either OwnershipFault ObjectIdentity)
acquireColimaDirectory session key target = do
    existing <- readRawRecordUnder (directoryTape session) key
    case existing of
        Left fault -> pure (Left fault)
        Right (Just _) -> pure (Left (OwnershipOccupied (Text.pack target)))
        Right Nothing ->
            enterOwnedObject ownershipRowForHost session target $ \entered -> do
                recorded <- recordOwnedOrigin ownershipRowForHost entered OwnedDirectory publishOrigin
                case recorded of
                    Left fault -> pure (Left fault)
                    Right token ->
                        recordedEvidence
                            ( \_ record -> case originRecordOrigin record of
                                OriginPresent _ -> pure (Left (OwnershipOccupied (Text.pack target)))
                                OriginAbsent -> do
                                    created <- createOwnedDirectory ownershipRowForHost token
                                    case created of
                                        Left fault -> pure (Left fault)
                                        Right identity -> do
                                            bound <- bindOwnedIdentity ownershipRowForHost token identity publishBinding
                                            pure (fmap (const identity) bound)
                            )
                            token
  where
    publishOrigin = publishFreshRecord (directoryTape session) key
    publishBinding = publishBoundRecord (directoryTape session) key

-- An unclaimed or completely released profile owns no residual artifacts.
observeVacantColimaNamespaces :: ProtectedSession session -> ColimaOwnershipKeys -> FilePath -> FilePath -> IO (Either OwnershipFault ColimaStageObservation)
observeVacantColimaNamespaces session keys home context = do
    namespaces <- traverse (observeKernelOrigin session) [home, context]
    records <- traverse (readProtectedRecord session)
        [ colimaHomeKey keys, colimaContextKey keys, colimaCacheKey keys
        , colimaTemporaryKey keys, colimaProfileKey keys, colimaDiskKey keys, colimaManifestKey keys
        ]
    pure $ do
        origins <- sequence namespaces
        retained <- first (storeFault "read vacant Colima artifact records") (sequence records)
        if all (== OriginAbsent) origins && all absent retained
            then Right ColimaNamespaceAbsent
            else Left (OwnershipOccupied "the Colima namespace still carries objects or artifact records")
  where
    absent Nothing = True
    absent (Just _) = False

-- Read through the real row and live entry without acquiring an origin.
observeKernelOrigin :: ProtectedSession session -> FilePath -> IO (Either OwnershipFault Origin)
observeKernelOrigin session target =
    enterOwnedObject ownershipRowForHost session target $ \entered ->
        enteredEvidence (\_ origin -> pure (Right origin)) entered

readRetainedColimaManifest :: ProtectedSession session -> ColimaOwnershipKeys -> IO (Either OwnershipFault (ProtectedRecord, OwnershipManifest))
readRetainedColimaManifest session keys = do
    retained <- readProtectedRecord session (colimaManifestKey keys)
    pure $ case retained of
        Left failure -> Left (storeFault "read retained Colima manifest" failure)
        Right Nothing -> Left (OwnershipMalformed "retained Colima manifest is absent")
        Right (Just stored) -> (,) stored <$> parseOwnershipManifest (protectedRecordBytes stored)

observeColimaNamespaceManifest :: FilePath -> FilePath -> IO (Either OwnershipFault OwnershipManifest)
observeColimaNamespaceManifest home context = do
    homeObserved <- observeOwnershipManifestForHost True home
    contextObserved <- observeOwnershipManifestForHost False context
    pure $ do
        actualHome <- homeObserved
        actualContext <- contextObserved
        prefixedHome <- prefixOwnershipManifest "colima" actualHome
        prefixedContext <- prefixOwnershipManifest "docker" actualContext
        mergeOwnershipManifests [prefixedHome, prefixedContext]

revalidateColimaManifest :: ProtectedSession session -> ColimaOwnershipKeys -> FilePath -> FilePath -> IO (Either OwnershipFault OwnershipManifest)
revalidateColimaManifest session keys home context = do
    retained <- readRetainedColimaManifest session keys
    stage <- readColimaStage session keys
    observed <- observeColimaNamespaceManifest home context
    pure $ do
        (_, expected) <- retained
        current <- stage >>= maybe (Left (OwnershipMalformed "the Colima manifest stage is absent")) Right
        let record = snd current
        case colimaStageRecordEvidence record of
            Nothing
                | colimaStageRecordStage record <= ColimaPrepared -> Right ()
            Just evidence
                | managedManifestDigest evidence == ownershipManifestDigest expected
                    && managedDirectoryChainDigest evidence == ownershipDirectoryChainDigest expected -> Right ()
            _ -> Left (OwnershipMalformed "the retained Colima manifest differs from its managed evidence")
        actual <- observed
        if actual == expected
            then Right expected
            else Left (OwnershipMalformed "the current Colima namespace manifest differs from its retained authority")

{- | Acquire a missing directory, resume its unbound absence, or re-enter the
exact identity already bound by this record. Present unbound objects refuse.
-}
ensureColimaDirectory :: ProtectedSession session -> RecordKey -> FilePath -> IO (Either OwnershipFault ObjectIdentity)
ensureColimaDirectory session key target = do
    current <- readStoredRecordUnder (directoryTape session) key
    case current of
        Left fault -> pure (Left fault)
        Right Nothing -> acquireColimaDirectory session key target
        Right (Just record) -> case originRecordBinding (storedOriginRecord record) of
            Nothing -> resumeUnbound record
            Just identity ->
                reenterStoredOwnedObject ownershipRowForHost session target record $ \bound -> do
                    observed <- reobserveOwnedIdentity ownershipRowForHost bound
                    pure (fmap (const identity) observed)
  where
    resumeUnbound stored
        | originRecordKind (storedOriginRecord stored) /= OwnedDirectory =
            pure (Left (OwnershipOccupied (Text.pack target)))
        | otherwise = enterOwnedObject ownershipRowForHost session target $ \entered ->
            enteredEvidence (\_ observed -> case observed of
                OriginPresent _ -> pure (Left (OwnershipOccupied (Text.pack target)))
                OriginAbsent -> case originRecordOrigin (storedOriginRecord stored) of
                    OriginPresent _ -> do
                        forgotten <- forgetRecordAtVersion (directoryTape session) key (storedRecordVersion stored)
                        case forgotten of
                            Left fault -> pure (Left fault)
                            Right () -> acquireColimaDirectory session key target
                    OriginAbsent -> do
                        recorded <- recordOwnedOrigin ownershipRowForHost entered OwnedDirectory (publishFreshRecord (directoryTape session) key)
                        case recorded of
                            Left fault -> pure (Left fault)
                            Right token -> do
                                created <- createOwnedDirectory ownershipRowForHost token
                                case created of
                                    Left fault -> pure (Left fault)
                                    Right identity -> do
                                        bound <- bindOwnedIdentity ownershipRowForHost token identity (publishBoundRecord (directoryTape session) key)
                                        pure (identity <$ bound)) entered

{- | Clause 4 for an empty Colima-owned directory. The caller first validates
and removes the directory's admitted manifest; this operation then proves
the directory identity, removes that exact object, and forgets its record.
-}
-- | The same created-directory policy is used by readers and release.
colimaDirectoryBinding :: OriginRecord -> Either OwnershipFault ObjectIdentity
colimaDirectoryBinding record
    | originRecordKind record /= OwnedDirectory || originRecordOrigin record /= OriginAbsent =
        Left (OwnershipOccupied "the directory was not created by this owner")
    | otherwise = case originRecordBinding record of
        Nothing -> Left (OwnershipMalformed "the directory origin is not identity-bound")
        Just identity -> Right identity

releaseColimaDirectory :: ProtectedSession session -> RecordKey -> FilePath -> IO (Either OwnershipFault ())
releaseColimaDirectory session key target =
    withOwnershipRow ownershipRowForHost $ \primitives ->
        case clauseRefusal (rowCapabilities primitives) ClauseRelease of
            Just refusal -> pure (Left refusal)
            Nothing -> case clauseRefusal (rowCapabilities primitives) ClauseRecord of
                Just refusal -> pure (Left refusal)
                Nothing -> do
                    current <- readStoredRecordUnder (directoryTape session) key
                    case current of
                        Left fault -> pure (Left fault)
                        Right Nothing -> do
                            observed <- observeKernelOrigin session target
                            pure $ case observed of
                                Left fault -> Left fault
                                Right OriginAbsent -> Right ()
                                Right _ -> Left (OwnershipOccupied "an unrecorded Colima directory remains present")
                        Right (Just record) -> case colimaDirectoryBinding (storedOriginRecord record) of
                            Left fault -> pure (Left fault)
                            Right _ ->
                                reenterStoredOwnedObject ownershipRowForHost session target record $ \bound -> do
                                    observed <- observeKernelOrigin session target
                                    case observed of
                                        Left fault -> pure (Left fault)
                                        Right OriginAbsent -> resumeOwnedRemoval ownershipRowForHost bound forget
                                        Right (OriginPresent _) -> do
                                            retained <- reobserveOwnedIdentity ownershipRowForHost bound
                                            case retained of
                                                Left fault -> pure (Left fault)
                                                Right releasable -> releaseOwnedObject ownershipRowForHost releasable forget
                                  where
                                    forget _ = forgetRecordAtVersion (directoryTape session) key (storedRecordVersion record)

-- A listed context can be inspected/removed only through its existing origin.
-- Both identity and stored-record version are retained across inspection.
readRetainedColimaContextIdentity :: ProtectedSession session -> ColimaOwnershipKeys -> FilePath -> IO (Either OwnershipFault (ObjectIdentity, RecordVersion))
readRetainedColimaContextIdentity session keys context = do
    parents <- revalidateColimaContextParents session context
    case parents of
        Left fault -> pure (Left fault)
        Right () -> readRetainedColimaDirectoryIdentity session (colimaContextKey keys) context

readRetainedColimaDirectoryIdentity :: ProtectedSession session -> RecordKey -> FilePath -> IO (Either OwnershipFault (ObjectIdentity, RecordVersion))
readRetainedColimaDirectoryIdentity session key target = do
    current <- readStoredRecordUnder (directoryTape session) key
    case current of
        Left fault -> pure (Left fault)
        Right Nothing -> pure (Left (OwnershipMalformed "the owned directory origin record is absent"))
        Right (Just record) -> case colimaDirectoryBinding (storedOriginRecord record) of
            Left fault -> pure (Left fault)
            Right identity ->
                reenterStoredOwnedObject ownershipRowForHost session target record $ \bound -> do
                    observed <- reobserveOwnedIdentity ownershipRowForHost bound
                    pure ((identity, storedRecordVersion record) <$ observed)

-- Parent keys belong to the protected root, so profiles sharing a directory
-- re-enter the same origin. Length-prefixed character words keep the key input
-- lossless even when a FilePath contains filesystem-decoding escape characters.
colimaContextParentRecords :: ProtectedSession session -> FilePath -> Either OwnershipFault [(RecordKey, FilePath)]
colimaContextParentRecords session context
    | not (isAbsolute target) || isAbsolute relative || elem '\NUL' target
        || elem (takeFileName target) ["", ".", ".."]
        || any (\part -> elem part ["", ".", ".."] || elem '\NUL' part) components =
        Left (OwnershipMalformed "the Docker-config namespace must be strictly below its protected plan root")
    | otherwise = traverse parentRecord (zip (drop 1 (inits components)) (drop 1 (scanl (</>) root components)))
  where
    root = sessionStoreRoot session
    target = dropTrailingPathSeparator context
    relative = makeRelative root (takeDirectory target)
    components = if relative == "." then [] else splitDirectories relative
    parentRecord (parts, path) = do
        let bytes = LazyByteString.toStrict . Builder.toLazyByteString $
                foldMap (\part -> Builder.word64BE (fromIntegral (length part))
                    <> foldMap (Builder.word32BE . fromIntegral . fromEnum) part) parts
            name = "colima-parent-" <> Text.pack (show (Hash.hashWith Hash.SHA256 bytes))
        key <- either (Left . storeFault "derive Colima parent record") Right (mkRecordKey name)
        pure (key, path)

ensureColimaContextParents :: ProtectedSession session -> FilePath -> IO (Either OwnershipFault ())
ensureColimaContextParents session context =
    either (pure . Left) walk (colimaContextParentRecords session context)
  where
    walk [] = pure (Right ())
    walk ((key, path) : rest) = do
        ensured <- ensureColimaDirectory session key path
        case ensured of
            Left fault -> pure (Left fault)
            Right _ -> walk rest

revalidateColimaContextParents :: ProtectedSession session -> FilePath -> IO (Either OwnershipFault ())
revalidateColimaContextParents session context =
    either (pure . Left) walk (colimaContextParentRecords session context)
  where
    walk [] = pure (Right ())
    walk ((key, path) : rest) = do
        current <- readStoredRecordUnder (directoryTape session) key
        case current of
            Left fault -> pure (Left fault)
            Right Nothing -> pure (Left (OwnershipMalformed "a retained context-parent origin record is absent"))
            Right (Just record) ->
                reenterStoredOwnedObject ownershipRowForHost session path record $ \bound -> do
                    observed <- reobserveOwnedIdentity ownershipRowForHost bound
                    case observed of
                        Left fault -> pure (Left fault)
                        Right _ -> walk rest

withValidatedColimaContextParents ::
    ProtectedSession session ->
    FilePath ->
    IO (Either ColimaProfileMutationFault value) ->
    IO (Either ColimaProfileMutationFault value)
withValidatedColimaContextParents session context action = do
    current <- revalidateColimaContextParents session context
    case current of
        Left fault -> pure (Left (ColimaMutationOwnershipRefused fault))
        Right () -> action

-- Empty owned parents release child-first. Shared or foreign contents retain
-- the directory and its origin. No missing/replaced retained identity is adopted.
releaseColimaContextParents :: ProtectedSession session -> FilePath -> IO (Either OwnershipFault ())
releaseColimaContextParents session context =
    either (pure . Left) (walk . reverse) (colimaContextParentRecords session context)
  where
    walk [] = pure (Right ())
    walk ((key, path) : rest) = do
        current <- readStoredRecordUnder (directoryTape session) key
        case current of
            Left fault -> pure (Left fault)
            Right Nothing -> walk rest
            Right (Just record) -> do
                released <- reenterStoredOwnedObject ownershipRowForHost session path record $ \bound -> do
                    before <- reobserveOwnedIdentity ownershipRowForHost bound
                    case before of
                        Left fault -> do
                            observed <- observeKernelOrigin session path
                            case observed of
                                Right OriginAbsent -> resumeOwnedRemoval ownershipRowForHost bound $ \_ ->
                                    forgetRecordAtVersion (directoryTape session) key (storedRecordVersion record)
                                _ -> pure (Left fault)
                        Right _ -> do
                            contents <- observeOwnershipManifestForHost True path
                            case contents of
                                Left fault -> pure (Left fault)
                                Right manifest -> do
                                    after <- reobserveOwnedIdentity ownershipRowForHost bound
                                    case after of
                                        Left fault -> pure (Left fault)
                                        Right releasable
                                            | null (ownershipManifestEntries manifest) ->
                                                releaseOwnedObject ownershipRowForHost releasable $ \_ ->
                                                    forgetRecordAtVersion (directoryTape session) key (storedRecordVersion record)
                                            | otherwise -> pure (Right ())
                case released of
                    Left fault -> pure (Left fault)
                    Right () -> walk rest

ownershipKeys :: String -> Either String ColimaOwnershipKeys
ownershipKeys profile = do
    commandProfile <- mkColimaProfile profile
    ColimaOwnershipKeys commandProfile
        <$> key "stage"
        <*> key "home"
        <*> key "cache"
        <*> key "temporary"
        <*> key "context"
        <*> key "disk"
        <*> key "profile"
        <*> key "manifest"
  where
    key suffix =
        first
            (Text.unpack . protectedErrorMessage)
            (mkRecordKey (Text.pack ("colima-" ++ profile ++ "-" ++ suffix)))
