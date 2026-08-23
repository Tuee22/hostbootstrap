{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The direct-Colima clause-1/2 entry over the shared protected store.

One entry covers the stage record and every artifact-origin record.  The keys
are derived from the fixed provider profile; callers cannot select an unrelated
record while holding this transaction.
-}
module HostBootstrap.Ensure.Colima.Ownership
  ( ColimaOwnershipKeys,
    colimaStageKey,
    colimaHomeKey,
    colimaContextKey,
    colimaDiskKey,
    colimaProfileKey,
    colimaManifestKey,
    withColimaOwnershipEntry,
    ColimaNativeObservationFault (..),
    observeColimaProfiles,
    ColimaNativeOwnershipFault (..),
    prepareColimaNamespaces,
    ColimaStartedObservation (..),
    ColimaArtifactObservation (..),
    ColimaManagedObservation (..),
    ColimaManagedOutcome (..),
    ColimaProfileMutationFault (..),
    startPreparedColimaProfile,
    startPreparedColimaProfileWith,
    observeColimaArtifacts,
    observeColimaArtifactsWith,
    publishPreparedColimaManifest,
    acquireManagedColimaProfile,
    acquireManagedColimaProfileWith,
    bindColimaCreationIdentities,
    settleManagedColimaProfile,
    cleanupManagedColimaProfile,
    cleanupManagedColimaProfileWith,
    runManagedColimaDocker,
    runManagedColimaDockerWith,
    readColimaStage,
    writeColimaStage,
    acquireColimaDirectory,
    ensureColimaDirectory,
    releaseColimaDirectory,
  )
where

import Data.Bifunctor (first)
import Control.Exception (IOException, try)
import qualified Data.Text as Text
import Data.Word (Word64)
import qualified Data.ByteString.Char8 as ByteString.Char8
import HostBootstrap.Protected
  ( Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    RecordVersion,
    ProtectedSession,
    RecordKey,
    mkRecordKey,
    openProtectedStore,
    protectedErrorMessage,
    withProtectedEntry,
    readProtectedRecord,
    compareAndSwapProtectedRecord,
    compareAndDeleteProtectedRecord,
  )
import HostBootstrap.Ensure.Colima.Command
  ( deleteColimaProfileCommand,
    inspectDockerContextCommand,
    listLimaDisksCommand,
    listColimaProfilesCommand,
    removeDockerContextCommand,
    readColimaMachineIdCommand,
    routedDockerCommand,
    startColimaProfileCommand,
  )
import HostBootstrap.Ensure.Colima.Backend.Stage
  ( ColimaStage (..),
    ColimaStageRecord,
    ColimaManagedEvidence (..),
    advanceSettledColimaStageRecord,
    beginColimaReleaseRecord,
    colimaStageRecordCleanupInvocation,
    colimaStageRecordInvocation,
    colimaStageRecordLineage,
    colimaStageRecordOwner,
    colimaStageRecordEvidence,
    mkColimaManagedEvidence,
    advanceColimaStage,
    colimaStageRecordStage,
    mkColimaStageRecord,
    parseColimaStageRecord,
    renderColimaStageRecord,
    settleColimaStageRecord,
  )
import HostBootstrap.Ensure.Colima.Report
  ( ColimaInstance,
    ColimaReportFault,
    classifyColimaListing,
    classifyDockerContextInspect,
    classifyLimaDiskListing,
    classifyMachineIdentity,
    ciCpus,
    ciDiskBytes,
    ciMemoryBytes,
    ciName,
    ciRuntime,
    ciStatus,
    dockerContextFingerprint,
    limaDiskDirectory,
    limaDiskInstance,
    limaDiskInstanceDirectory,
    limaDiskName,
    limaDiskSize,
  )
import HostBootstrap.Effect.Interpreter (interpretHostCommand)
import HostBootstrap.Effect.Run (CapturedRun (capturedExit))
import HostBootstrap.Effect.Vocabulary (HostCommand)
import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Ownership.Clause (enteredEvidence, recordedEvidence)
import HostBootstrap.Ownership.Object
  ( ObjectIdentity,
    ObjectKind (OwnedDirectory, ReportedObject),
    Origin (OriginAbsent, OriginPresent),
    OwnershipFault (..),
    originRecordOrigin,
    originRecordBinding,
    mkOwnerClaim,
    originRecord,
    originRecordKind,
    parseObjectIdentityHex,
    parseOriginRecord,
    renderOriginRecord,
  )
import HostBootstrap.Ownership.Manifest
  ( OwnershipManifest,
    mergeOwnershipManifests,
    ownershipDirectoryChainDigest,
    ownershipManifestDigest,
    parseOwnershipManifest,
    prefixOwnershipManifest,
    renderOwnershipManifest,
  )
import HostBootstrap.Ownership.Primitive
  ( bindOwnedIdentity,
    bindReportedIdentity,
    createOwnedDirectory,
    enterOwnedObject,
    enterReportedObject,
    recordOwnedOrigin,
    recordReportedOrigin,
    reenterOwnedObject,
    reobserveReportedIdentity,
    releaseReportedObject,
    reobserveOwnedIdentity,
    releaseOwnedObject,
  )
import HostBootstrap.Ownership.Row (observeOwnershipManifestForHost, ownershipRowForHost)
import System.Exit (ExitCode (ExitSuccess))
import System.Directory (listDirectory, removeDirectory)
import System.IO.Error (isDoesNotExistError)
import System.FilePath ((</>))

data ColimaOwnershipKeys = ColimaOwnershipKeys
  { colimaStageKey :: RecordKey,
    colimaHomeKey :: RecordKey,
    colimaContextKey :: RecordKey,
    colimaDiskKey :: RecordKey,
    colimaProfileKey :: RecordKey,
    colimaManifestKey :: RecordKey
  }

data ColimaNativeObservationFault
  = ColimaNativeEntryRefused String
  | ColimaNativeCommandUnavailable String
  | ColimaNativeReportRefused ColimaReportFault
  deriving (Eq, Show)

data ColimaNativeOwnershipFault
  = ColimaNativeStoreRefused String
  | ColimaNativeStageRefused String
  | ColimaNativeOwnershipRefused OwnershipFault
  deriving (Eq, Show)

data ColimaStartedObservation = ColimaStartedObservation
  { startedMachineIdentity :: String,
    startedMachineEpoch :: Word64
  }
  deriving (Eq, Show)

data ColimaArtifactObservation = ColimaArtifactObservation
  { artifactDiskPath :: FilePath,
    artifactDiskIdentity :: ObjectIdentity,
    artifactContextDigest :: String,
    artifactOwnershipManifest :: OwnershipManifest
  }
  deriving (Eq, Show)

data ColimaManagedObservation = ColimaManagedObservation
  { managedStartObservation :: ColimaStartedObservation,
    managedArtifactObservation :: ColimaArtifactObservation
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

-- | Interpret the described total-profile observation while the shared entry
-- is held. This is the native transaction's read-only face; mutation uses the
-- same entry and command vocabulary.
observeColimaProfiles :: HostConfig -> FilePath -> String -> IO (Either ColimaNativeObservationFault [ColimaInstance])
observeColimaProfiles config stateRoot profile = do
  entered <-
    withColimaOwnershipEntry stateRoot profile $ \_session _keys -> do
      interpreted <- interpretHostCommand config listColimaProfilesCommand
      pure (Right interpreted)
  pure $ case entered of
    Left refusal -> Left (ColimaNativeEntryRefused refusal)
    Right (Left refusal) -> Left (ColimaNativeCommandUnavailable refusal)
    Right (Right run) -> either (Left . ColimaNativeReportRefused) Right (classifyColimaListing run)

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

-- | Native acquisition through the prepared boundary: publish the lineage,
-- acquire the isolated home and Docker-config directories through clauses
-- 1–3, and leave the durable state at Prepared. Every restart re-enters exact
-- bound identities and continues from the retained adjacent stage.
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
        Right outcome -> either (Left . ColimaNativeOwnershipRefused) Right outcome

prepareColimaNamespacesInside :: ProtectedSession session -> ColimaOwnershipKeys -> String -> String -> String -> FilePath -> FilePath -> ColimaStageRecord -> IO (Either OwnershipFault ())
prepareColimaNamespacesInside session keys owner lineage invocation home context reserved = do
      initial <- readColimaStage session keys
      started <- case initial of
        Left fault -> pure (Left fault)
        Right Nothing -> fmap (fmap (const ())) (writeColimaStage session keys ExpectAbsent reserved)
        Right (Just _) -> pure (Right ())
      case started of
        Left fault -> pure (Left fault)
        Right () -> drive
  where
    mkRecord stage = mkColimaStageRecord stage owner lineage invocation

    drive = do
      current <- readColimaStage session keys
      case current of
        Left fault -> pure (Left fault)
        Right Nothing -> pure (Left (OwnershipMalformed "Colima stage vanished inside its entry"))
        Right (Just (version, record)) ->
          case mkRecord (colimaStageRecordStage record) of
            Left refusal -> pure (Left (OwnershipMalformed (Text.pack refusal)))
            Right expected
              | record /= expected -> pure (Left (OwnershipMalformed "Colima stage lineage does not match this invocation"))
              | otherwise -> case colimaStageRecordStage record of
                  ColimaReserved -> ensureThenAdvance session keys version home (colimaHomeKey keys) ColimaHomeStaged
                  ColimaHomeStaged -> advanceThenDrive session keys version ColimaHomeReady
                  ColimaHomeReady -> ensureThenAdvance session keys version context (colimaContextKey keys) ColimaContextStaged
                  ColimaContextStaged -> advanceThenDrive session keys version ColimaPrepared
                  ColimaPrepared -> do
                    homeResult <- ensureColimaDirectory session (colimaHomeKey keys) home
                    case homeResult of
                      Left fault -> pure (Left fault)
                      Right _ -> fmap (fmap (const ())) (ensureColimaDirectory session (colimaContextKey keys) context)
                  _ -> pure (Left (OwnershipMalformed "Colima namespace preparation reached a non-acquisition stage"))

    ensureThenAdvance _session _keys version target key successor = do
      ensured <- ensureColimaDirectory session key target
      case ensured of
        Left fault -> pure (Left fault)
        Right _ -> advanceThenDrive session keys version successor

    advanceThenDrive _session _keys version successor =
      case mkRecord successor of
        Left refusal -> pure (Left (OwnershipMalformed (Text.pack refusal)))
        Right successorRecord -> do
          current <- readColimaStage session keys
          case current of
            Right (Just (_, record)) -> case advanceColimaStage (colimaStageRecordStage record) successor of
              Left refusal -> pure (Left (OwnershipMalformed (Text.pack refusal)))
              Right _ -> do
                written <- writeColimaStage session keys (ExpectVersion version) successorRecord
                case written of
                  Left fault -> pure (Left fault)
                  Right _ -> drive
            Left fault -> pure (Left fault)
            Right Nothing -> pure (Left (OwnershipMalformed "Colima stage vanished before advancement"))

-- | Perform the outcome-unknown start window while the Prepared record and
-- both namespace identities remain live. The function deliberately does not
-- publish Managed: disk and context settlement must still succeed under this
-- same entry before that successor is durable.
startPreparedColimaProfile ::
  HostConfig ->
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
  [String] ->
  IO (Either ColimaProfileMutationFault ColimaStartedObservation)
startPreparedColimaProfile config = startPreparedColimaProfileWith (interpretHostCommand config)

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
  [String] ->
  IO (Either ColimaProfileMutationFault ColimaStartedObservation)
startPreparedColimaProfileWith interpret stateRoot profile owner lineage invocation home context diskPath expectedCpu expectedMemory expectedDisk startArguments = do
  entered <-
    withColimaOwnershipEntry stateRoot profile $ \session keys ->
      Right <$> startPreparedColimaProfileInside interpret session keys profile owner lineage invocation home context diskPath expectedCpu expectedMemory expectedDisk startArguments
  pure $ case entered of
    Left refusal -> Left (ColimaMutationEntryRefused refusal)
    Right outcome -> outcome

startPreparedColimaProfileInside ::
  (HostCommand -> IO (Either String CapturedRun)) -> ProtectedSession session -> ColimaOwnershipKeys ->
  String -> String -> String -> String -> FilePath -> FilePath -> FilePath -> Integer -> Integer -> Integer -> [String] ->
  IO (Either ColimaProfileMutationFault ColimaStartedObservation)
startPreparedColimaProfileInside interpret session keys profile owner lineage invocation home context diskPath expectedCpu expectedMemory expectedDisk startArguments = mutateInside
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
                  homeResult <- ensureColimaDirectory session (colimaHomeKey keys) home
                  contextResult <- ensureColimaDirectory session (colimaContextKey keys) context
                  case (homeResult, contextResult) of
                    (Left fault, _) -> pure (Left (ColimaMutationOwnershipRefused fault))
                    (_, Left fault) -> pure (Left (ColimaMutationOwnershipRefused fault))
                    (Right _, Right _) -> observeOrStart

    observeOrStart = do
      before <- observeProfiles
      case before >>= exactProfile of
        Left fault -> pure (Left fault)
        Right Nothing -> do
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
        Right (Just _) -> do
          retained <- creationRecordsPresent
          case retained of
            Left fault -> pure (Left (ColimaMutationOwnershipRefused fault))
            Right () -> settleRunning

    settleRunning = do
      after <- observeProfiles
      case after >>= exactProfile of
        Left fault -> pure (Left fault)
        Right Nothing -> pure (Left (ColimaMutationProfileConflict "profile remained absent after start"))
        Right (Just _) -> do
          machine <- runCommand (readColimaMachineIdCommand profile)
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

    creationRecordsPresent = do
      profileRecord <- requireReportedOrigin (colimaProfileKey keys) ("colima-profile:" ++ profile)
      case profileRecord of
        Left fault -> pure (Left fault)
        Right () -> requireReportedOrigin (colimaDiskKey keys) diskPath

    claim = mkOwnerClaim (ByteString.Char8.pack owner)

    expectedOrigin = originRecord (ReportedObject claim) OriginAbsent

    ensureReportedOrigin key target =
      enterReportedObject session target OriginAbsent $ \entered -> do
        recorded <- recordReportedOrigin entered (ReportedObject claim) publish
        pure $ case recorded of
          Left fault -> Left fault
          Right token -> recordedEvidence (\_ _ -> Right ()) token
      where
        publish record = do
          current <- readProtectedRecord session key
          case current of
            Left failure -> pure (Left (storeFault "read reported origin" failure))
            Right Nothing -> do
              written <- compareAndSwapProtectedRecord session key ExpectAbsent (renderOriginRecord record)
              pure (either (Left . storeFault "publish reported origin") (const (Right ())) written)
            Right (Just stored)
              | protectedRecordBytes stored == renderOriginRecord record -> pure (Right ())
              | otherwise -> pure (Left (OwnershipMalformed "reported origin belongs to another object"))

    requireReportedOrigin key _target = do
      current <- readProtectedRecord session key
      pure $ case current of
        Left failure -> Left (storeFault "read reported origin" failure)
        Right Nothing -> Left (OwnershipMalformed "reported origin is absent")
        Right (Just stored)
          | protectedRecordBytes stored == renderOriginRecord expectedOrigin -> Right ()
          | otherwise -> Left (OwnershipMalformed "reported origin does not match this prepared creation")

-- | Join authoritative Lima and Docker reports to the kernel identities of
-- the Prepared transaction's owned namespaces.
observeColimaArtifacts ::
  HostConfig -> FilePath -> String -> String -> String -> String -> FilePath -> FilePath -> Integer ->
  IO (Either ColimaProfileMutationFault ColimaArtifactObservation)
observeColimaArtifacts config = observeColimaArtifactsWith (interpretHostCommand config)

observeColimaArtifactsWith ::
  (HostCommand -> IO (Either String CapturedRun)) ->
  FilePath -> String -> String -> String -> String -> FilePath -> FilePath -> Integer ->
  IO (Either ColimaProfileMutationFault ColimaArtifactObservation)
observeColimaArtifactsWith interpret stateRoot profile owner lineage invocation home context expectedDisk = do
  entered <-
    withColimaOwnershipEntry stateRoot profile $ \session keys ->
      Right <$> observeColimaArtifactsInside interpret session keys profile owner lineage invocation home context expectedDisk
  pure $ case entered of
    Left refusal -> Left (ColimaMutationEntryRefused refusal)
    Right outcome -> outcome
observeColimaArtifactsInside ::
  (HostCommand -> IO (Either String CapturedRun)) -> ProtectedSession session -> ColimaOwnershipKeys ->
  String -> String -> String -> String -> FilePath -> FilePath -> Integer ->
  IO (Either ColimaProfileMutationFault ColimaArtifactObservation)
observeColimaArtifactsInside interpret session keys profile owner lineage invocation home context expectedDisk = observeInside
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
              inspected <- runClassified (inspectDockerContextCommand ("colima-" ++ profile)) classifyDockerContextInspect
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
                      | limaDiskDirectory disk == expectedDiskDirectory,
                        limaDiskInstance disk == diskName,
                        limaDiskInstanceDirectory disk == expectedInstanceDirectory,
                        limaDiskSize disk == expectedDisk -> do
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
          (\_ origin -> pure $ case origin of
              OriginAbsent -> Left (OwnershipProbeFailed "observe Colima data disk" "data disk is absent")
              OriginPresent identity -> Right identity)
          entered

    runClassified command classify = do
      raw <- interpret command
      pure $ case raw of
        Left refusal -> Left (ColimaMutationCommandUnavailable refusal)
        Right captured -> either (Left . ColimaMutationReportRefused) Right (classify captured)

-- | Persist the complete shared manifest while Prepared is still the durable
-- stage. Re-entry accepts only the byte-identical canonical value.
publishPreparedColimaManifest ::
  FilePath -> String -> String -> String -> String -> OwnershipManifest ->
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

-- | Bind the machine identity reported by Colima and the data disk identity
-- reported by the kernel to the origins published before start. The stage
-- remains Prepared until context and wall settlement also succeed.
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
          (\_ origin -> pure $ case origin of
              OriginAbsent -> Left (OwnershipProbeFailed "observe created Colima artifact" "artifact is absent")
              OriginPresent identity -> Right identity)
          entered

    claim = mkOwnerClaim (ByteString.Char8.pack owner)

    bindReportedRecord key target identity =
      enterReportedObject session target OriginAbsent $ \entered -> do
        recorded <- recordReportedOrigin entered (ReportedObject claim) verifyOrigin
        case recorded of
          Left fault -> pure (Left fault)
          Right token -> do
            bound <- bindReportedIdentity token identity publishBinding
            pure (fmap (const ()) bound)
      where
        expected = originRecord (ReportedObject claim) OriginAbsent
        verifyOrigin record = do
          current <- readProtectedRecord session key
          pure $ case current of
            Left failure -> Left (storeFault "read reported origin for binding" failure)
            Right (Just stored)
              | protectedRecordBytes stored == renderOriginRecord record,
                record == expected -> Right ()
            _ -> Left (OwnershipMalformed "reported origin cannot be re-entered for binding")
        publishBinding record = do
          current <- readProtectedRecord session key
          case current of
            Left failure -> pure (Left (storeFault "read reported binding version" failure))
            Right Nothing -> pure (Left (OwnershipMalformed "reported origin vanished before binding"))
            Right (Just stored) -> do
              written <-
                compareAndSwapProtectedRecord
                  session
                  key
                  (ExpectVersion (protectedRecordVersion stored))
                  (renderOriginRecord record)
              pure (either (Left . storeFault "publish reported identity binding") (const (Right ())) written)

-- | Publish Managed only after the profile and disk origins are identity-bound,
-- the context directory re-enters exactly, and the complete managed evidence
-- validates. This is the sole Prepared → Managed publication.
settleManagedColimaProfile :: FilePath -> String -> String -> String -> String -> String -> Word64 -> String -> Integer -> Integer -> Integer -> Integer -> FilePath -> FilePath -> IO (Either ColimaProfileMutationFault ())
settleManagedColimaProfile stateRoot profile owner lineage invocation machine epoch contextDigest cpu memory disk rootDisk homePath contextPath = do
  entered <-
    withColimaOwnershipEntry stateRoot profile $ \session keys ->
      Right <$> settleManagedColimaProfileInside session keys profile owner lineage invocation machine epoch contextDigest cpu memory disk rootDisk homePath contextPath
  pure $ case entered of
    Left refusal -> Left (ColimaMutationEntryRefused refusal)
    Right outcome -> outcome
settleManagedColimaProfileInside ::
  ProtectedSession session -> ColimaOwnershipKeys -> String -> String -> String -> String -> String -> Word64 -> String -> Integer -> Integer -> Integer -> Integer -> FilePath -> FilePath ->
  IO (Either ColimaProfileMutationFault ())
settleManagedColimaProfileInside session keys _profile owner lineage invocation machine epoch contextDigest cpu memory disk rootDisk homePath contextPath = settleInside
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
              contextIdentity <- ensureColimaDirectory session (colimaContextKey keys) contextPath
              manifest <- revalidateColimaManifest session keys homePath contextPath
              case (machineIdentity, profileBinding, diskBinding, contextIdentity, manifest) of
                (Left fault, _, _, _, _) -> pure (Left (ColimaMutationOwnershipRefused fault))
                (_, Left fault, _, _, _) -> pure (Left (ColimaMutationOwnershipRefused fault))
                (_, _, Left fault, _, _) -> pure (Left (ColimaMutationOwnershipRefused fault))
                (_, _, _, Left fault, _) -> pure (Left (ColimaMutationOwnershipRefused fault))
                (_, _, _, _, Left fault) -> pure (Left (ColimaMutationOwnershipRefused fault))
                (Right expectedMachine, Right actualMachine, Right _, Right _, Right retainedManifest)
                  | expectedMachine /= actualMachine -> pure (Left (ColimaMutationProfileConflict "machine binding differs from settlement"))
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
      current <- readProtectedRecord session key
      pure $ case current of
        Left failure -> Left (storeFault "read reported identity binding" failure)
        Right Nothing -> Left (OwnershipMalformed "reported identity binding is absent")
        Right (Just stored) -> do
          record <- parseOriginRecord (protectedRecordBytes stored)
          if originRecordKind record /= ReportedObject claim
            then Left (OwnershipMalformed "reported identity claim differs")
            else case originRecordBinding record of
              Nothing -> Left (OwnershipMalformed "reported identity remains unbound")
              Just identity -> Right identity

-- | The complete acquisition transaction under one protected entry. Every
-- external result is classified and joined to the shared origin/manifest
-- vocabulary before the evidence-bearing Managed successor is published.
acquireManagedColimaProfile ::
  HostConfig -> FilePath -> String -> String -> String -> String -> FilePath -> FilePath ->
  Integer -> Integer -> Integer -> Integer -> [String] ->
  IO (Either ColimaProfileMutationFault ColimaManagedOutcome)
acquireManagedColimaProfile config = acquireManagedColimaProfileWith (interpretHostCommand config)

acquireManagedColimaProfileWith ::
  (HostCommand -> IO (Either String CapturedRun)) ->
  FilePath -> String -> String -> String -> String -> FilePath -> FilePath ->
  Integer -> Integer -> Integer -> Integer -> [String] ->
  IO (Either ColimaProfileMutationFault ColimaManagedOutcome)
acquireManagedColimaProfileWith interpret stateRoot profile owner lineage invocation home context cpu memory disk rootDisk startArguments =
  case mkColimaStageRecord ColimaReserved owner lineage invocation of
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
        Right (Just (_, record))
          | colimaStageRecordStage record > ColimaPrepared ->
              pure (Left (ColimaMutationProfileConflict "managed stage belongs to another lineage"))
        _ -> applyAcquisition session keys reserved

    applyAcquisition session keys reserved = do
      prepared <- prepareColimaNamespacesInside session keys owner lineage invocation home context reserved
      case prepared of
        Left fault -> pure (Left (ColimaMutationOwnershipRefused fault))
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
                                  session keys profile owner lineage invocation
                                  (startedMachineIdentity startObservation) (startedMachineEpoch startObservation)
                                  (artifactContextDigest artifactObservation)
                                  cpu memory disk rootDisk home context
                              pure (ColimaManagedApplied (ColimaManagedObservation startObservation artifactObservation) <$ settled)

    isMatchingManaged record =
      colimaStageRecordStage record == ColimaManaged
        && colimaStageRecordOwner record == owner
        && colimaStageRecordLineage record == lineage
        && colimaStageRecordInvocation record == invocation

    validateExact session keys record = case colimaStageRecordEvidence record of
      Nothing -> pure (Left (ColimaMutationProfileConflict "managed stage lacks evidence"))
      Just evidence
        | managedCpu evidence /= cpu
            || managedMemoryBytes evidence /= memory
            || managedDiskBytes evidence /= disk
            || managedRootDiskBytes evidence /= rootDisk ->
            pure (Left (ColimaMutationProfileConflict "managed wall differs from the requested wall"))
        | otherwise -> do
            profiles <- runClassifiedExact listColimaProfilesCommand classifyColimaListing
            machine <- runClassifiedExact (readColimaMachineIdCommand profile) classifyMachineIdentity
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
                else if expectedMachine /= actualMachine || artifactDiskIdentity artifact /= actualDisk
                  then Left (ColimaMutationProfileConflict "managed identity binding differs")
                  else if artifactContextDigest artifact /= managedContextDigest evidence
                    then Left (ColimaMutationProfileConflict "managed context evidence differs")
                    else if ownershipManifestDigest (artifactOwnershipManifest artifact) /= managedManifestDigest evidence
                      || ownershipDirectoryChainDigest (artifactOwnershipManifest artifact) /= managedDirectoryChainDigest evidence
                      then Left (ColimaMutationProfileConflict "managed manifest evidence differs")
                      else Right (ColimaManagedAlreadyExact (ColimaManagedObservation (ColimaStartedObservation machineIdentity machineEpoch) artifact))

    requireExactProfile values = case filter ((== profile) . ciName) values of
      [value]
        | map lowerAscii (ciStatus value) == "running",
          map lowerAscii (ciRuntime value) == "docker",
          ciCpus value == cpu,
          ciMemoryBytes value == memory,
          ciDiskBytes value == disk -> Right ()
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
      current <- readProtectedRecord session key
      pure $ case current of
        Left failure -> Left (ColimaMutationOwnershipRefused (storeFault "read managed identity binding" failure))
        Right Nothing -> Left (ColimaMutationProfileConflict "managed identity binding is absent")
        Right (Just stored) -> case parseOriginRecord (protectedRecordBytes stored) of
          Left fault -> Left (ColimaMutationOwnershipRefused fault)
          Right record -> case originRecordBinding record of
            Nothing -> Left (ColimaMutationProfileConflict "managed identity remains unbound")
            Just identity -> Right identity

-- | Clause-4 cleanup for one evidence-bearing Managed profile. The cleanup
-- invocation is durable before the destructive command; both reported
-- artifacts are forgotten only after the command's authority and the kernel
-- independently report them absent. The isolated namespaces are then released
-- by exact identity in durable stage order.
cleanupManagedColimaProfile ::
  HostConfig -> FilePath -> String -> String -> String -> String -> String -> FilePath -> FilePath -> FilePath ->
  IO (Either ColimaProfileMutationFault ())
cleanupManagedColimaProfile config = cleanupManagedColimaProfileWith (interpretHostCommand config)

cleanupManagedColimaProfileWith ::
  (HostCommand -> IO (Either String CapturedRun)) ->
  FilePath -> String -> String -> String -> String -> String -> FilePath -> FilePath -> FilePath ->
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
          | not (sameManagedLineage record) -> pure (conflict "managed stage belongs to another lineage")
          | colimaStageRecordStage record == ColimaReleased,
            colimaStageRecordCleanupInvocation record == Just cleanupInvocation -> pure (Right ())
          | otherwise -> do
              releasing <- case colimaStageRecordStage record of
                ColimaManaged -> case beginColimaReleaseRecord record cleanupInvocation of
                  Left refusal -> pure (Left (OwnershipMalformed (Text.pack refusal)))
                  Right successor -> fmap (fmap (const successor)) (writeColimaStage session keys (ExpectVersion version) successor)
                ColimaReleasing
                  | colimaStageRecordCleanupInvocation record == Just cleanupInvocation -> pure (Right record)
                _ -> pure (Left (OwnershipMalformed "Colima cleanup stage is not resumable"))
              case releasing of
                Left fault -> pure (ownershipFailure fault)
                Right releasingRecord -> do
                  manifest <- revalidateColimaManifest session keys home context
                  case manifest of
                    Left fault -> pure (ownershipFailure fault)
                    Right _ -> releaseProfile session keys releasingRecord

    sameManagedLineage record =
      colimaStageRecordOwner record == owner
        && colimaStageRecordLineage record == lineage
        && colimaStageRecordInvocation record == invocation

    releaseProfile session keys releasingRecord = do
      before <- observeProfiles
      case before >>= exactPresent of
        Left fault -> pure (Left fault)
        Right () -> do
          machine <- runCommand (readColimaMachineIdCommand profile)
          case machine >>= either (Left . ColimaMutationReportRefused) Right . classifyMachineIdentity of
            Left fault -> pure (Left fault)
            Right (machineHex, _) -> do
              profileRecord <- readBoundRecord session (colimaProfileKey keys)
              diskRecord <- readBoundRecord session (colimaDiskKey keys)
              case (profileRecord, diskRecord, parseObjectIdentityHex (Text.pack machineHex)) of
                (Left fault, _, _) -> pure (ownershipFailure fault)
                (_, Left fault, _) -> pure (ownershipFailure fault)
                (_, _, Left fault) -> pure (ownershipFailure fault)
                (Right (profileVersion, profileOrigin), Right (diskVersion, diskOrigin), Right machineIdentity)
                  | originRecordBinding profileOrigin /= Just machineIdentity -> pure (conflict "profile identity changed before delete")
                  | otherwise ->
                      do
                        released <-
                          reenterOwnedObject ownershipRowForHost session ("colima-profile:" ++ profile) profileOrigin $ \profileBound ->
                            case reobserveReportedIdentity profileBound (OriginPresent machineIdentity) of
                              Left fault -> pure (Left fault)
                              Right profileReleasable ->
                                reenterOwnedObject ownershipRowForHost session diskPath diskOrigin $ \diskBound -> do
                                  diskObserved <- observeKernelOrigin session diskPath
                                  case diskObserved >>= reobserveReportedIdentity diskBound of
                                    Left fault -> pure (Left fault)
                                    Right diskReleasable ->
                                      Right <$> do
                                        deleted <- runCommand (deleteColimaProfileCommand profile)
                                        case deleted of
                                          Left fault -> pure (Left fault)
                                          Right run | capturedExit run /= ExitSuccess -> pure (Left ColimaMutationDeleteFailed)
                                          Right _ -> settleAbsence session keys releasingRecord profileVersion profileReleasable diskVersion diskReleasable
                        pure (either ownershipFailure id released)

    settleAbsence session keys releasingRecord profileVersion profileReleasable diskVersion diskReleasable = do
      after <- observeProfiles
      diskAfter <- observeKernelOrigin session diskPath
      case (after >>= exactAbsent, diskAfter) of
        (Left fault, _) -> pure (Left fault)
        (_, Left fault) -> pure (ownershipFailure fault)
        (Right (), Right diskOrigin) -> do
          profileReleased <- releaseReportedObject profileReleasable OriginAbsent (const (forget session (colimaProfileKey keys) profileVersion))
          diskReleased <- releaseReportedObject diskReleasable diskOrigin (const (forget session (colimaDiskKey keys) diskVersion))
          case (profileReleased, diskReleased) of
            (Left fault, _) -> pure (ownershipFailure fault)
            (_, Left fault) -> pure (ownershipFailure fault)
            (Right (), Right ()) -> finishNamespaces session keys releasingRecord

    finishNamespaces session keys releasingRecord =
      case advanceSettledColimaStageRecord releasingRecord ColimaContextReleased of
        Left refusal -> pure (conflict refusal)
        Right contextReleased -> do
          removed <- runCommand (removeDockerContextCommand ("colima-" ++ profile))
          case removed of
            Left fault -> pure (Left fault)
            Right run | capturedExit run /= ExitSuccess -> pure (Left ColimaMutationDeleteFailed)
            Right _ -> do
              current <- readColimaStage session keys
              case current of
                Right (Just (version, _)) -> do
                  written <- writeColimaStage session keys (ExpectVersion version) contextReleased
                  case written of
                    Left fault -> pure (ownershipFailure fault)
                    Right nextVersion -> do
                      releasedContext <- releaseColimaDirectory session (colimaContextKey keys) context
                      case releasedContext of
                        Left fault -> pure (ownershipFailure fault)
                        Right () -> case advanceSettledColimaStageRecord contextReleased ColimaReleased of
                          Left refusal -> pure (conflict refusal)
                          Right released -> do
                            final <- writeColimaStage session keys (ExpectVersion nextVersion) released
                            case final of
                              Left fault -> pure (ownershipFailure fault)
                              Right _ -> do
                                pruned <- pruneEmptyColimaScaffolding home
                                case pruned of
                                  Left fault -> pure (Left fault)
                                  Right () -> do
                                    releasedHome <- releaseColimaDirectory session (colimaHomeKey keys) home
                                    case releasedHome of
                                      Left fault -> pure (ownershipFailure fault)
                                      Right () -> do
                                        retained <- readProtectedRecord session (colimaManifestKey keys)
                                        case retained of
                                          Left failure -> pure (ownershipFailure (storeFault "read released Colima manifest" failure))
                                          Right Nothing -> pure (conflict "released Colima manifest is absent")
                                          Right (Just stored) -> do
                                            forgotten <- compareAndDeleteProtectedRecord session (colimaManifestKey keys) (ExpectVersion (protectedRecordVersion stored))
                                            pure (either (ownershipFailure . storeFault "forget released Colima manifest") (const (Right ())) forgotten)
                Left fault -> pure (ownershipFailure fault)
                Right Nothing -> pure (conflict "cleanup stage vanished")

    observeProfiles = do
      result <- runCommand listColimaProfilesCommand
      pure (result >>= either (Left . ColimaMutationReportRefused) Right . classifyColimaListing)

    exactPresent values = case filter ((== profile) . ciName) values of
      [_] -> Right ()
      [] -> Left (ColimaMutationProfileConflict "profile is absent before delete")
      _ -> Left (ColimaMutationProfileConflict "profile listing is duplicated")
    exactAbsent values = case filter ((== profile) . ciName) values of
      [] -> Right ()
      _ -> Left (ColimaMutationProfileConflict "profile remained present after delete")

    runCommand command = first ColimaMutationCommandUnavailable <$> interpret command
    conflict = Left . ColimaMutationProfileConflict
    ownershipFailure = Left . ColimaMutationOwnershipRefused

    pruneEmptyColimaScaffolding root = prune
      [ root </> "_lima" </> "_disks",
        root </> "_lima",
        root </> "_store",
        root </> "cache",
        root </> "tmp"
      ]
      where
        prune [] = pure (Right ())
        prune (target : remaining) = do
          attempted <- try (listDirectory target) :: IO (Either IOException [FilePath])
          case attempted of
            Left failure
              | isDoesNotExistError failure -> prune remaining
              | otherwise -> pure (Left (ColimaMutationProfileConflict ("cannot inspect Colima scaffold: " ++ show failure)))
            Right [] -> do
              removed <- try (removeDirectory target) :: IO (Either IOException ())
              case removed of
                Left failure -> pure (Left (ColimaMutationProfileConflict ("cannot remove empty Colima scaffold: " ++ show failure)))
                Right () -> prune remaining
            Right _ -> pure (Left (ColimaMutationProfileConflict ("Colima scaffold remains nonempty: " ++ target)))

    readBoundRecord session key = do
      current <- readProtectedRecord session key
      pure $ case current of
        Left failure -> Left (storeFault "read cleanup binding" failure)
        Right Nothing -> Left (OwnershipMalformed "cleanup binding is absent")
        Right (Just stored) -> do
          record <- parseOriginRecord (protectedRecordBytes stored)
          case originRecordBinding record of
            Nothing -> Left (OwnershipMalformed "cleanup binding is unbound")
            Just _ -> Right (protectedRecordVersion stored, record)

    observeKernelOrigin session target =
      enterOwnedObject ownershipRowForHost session target $ \entered ->
        enteredEvidence (\_ origin -> pure (Right origin)) entered

    forget session key version = do
      deleted <- compareAndDeleteProtectedRecord session key (ExpectVersion version)
      pure (either (Left . storeFault "forget cleanup binding") Right deleted)

-- | Run one Docker command through the fixed profile route while the same
-- ownership entry proves the Managed stage, machine binding, and context
-- directory on both sides of the effect.
runManagedColimaDocker ::
  HostConfig -> FilePath -> String -> String -> String -> String -> FilePath -> FilePath -> [String] ->
  IO (Either ColimaProfileMutationFault CapturedRun)
runManagedColimaDocker config = runManagedColimaDockerWith (interpretHostCommand config)

runManagedColimaDockerWith ::
  (HostCommand -> IO (Either String CapturedRun)) ->
  FilePath -> String -> String -> String -> String -> FilePath -> FilePath -> [String] ->
  IO (Either ColimaProfileMutationFault CapturedRun)
runManagedColimaDockerWith interpret stateRoot profile owner lineage invocation home context arguments =
  case routedDockerCommand profile arguments of
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
              pure (captured <$ retained)

    validateStanding session keys = do
      stage <- readColimaStage session keys
      contextStanding <- ensureColimaDirectory session (colimaContextKey keys) context
      manifestStanding <- revalidateColimaManifest session keys home context
      profileRecord <- readProtectedRecord session (colimaProfileKey keys)
      listing <- runCommand listColimaProfilesCommand
      machine <- runCommand (readColimaMachineIdCommand profile)
      pure $ do
        (_, record) <- either (Left . ColimaMutationOwnershipRefused) maybeStage stage
        if colimaStageRecordStage record /= ColimaManaged
            || colimaStageRecordOwner record /= owner
            || colimaStageRecordLineage record /= lineage
            || colimaStageRecordInvocation record /= invocation
          then Left (ColimaMutationProfileConflict "Docker route is not owned by this Managed lineage")
          else Right ()
        _ <- either (Left . ColimaMutationOwnershipRefused) Right contextStanding
        _ <- either (Left . ColimaMutationOwnershipRefused) Right manifestStanding
        stored <- either (Left . ColimaMutationOwnershipRefused . storeFault "read Docker profile binding") maybeProfile profileRecord
        origin <- either (Left . ColimaMutationOwnershipRefused) Right (parseOriginRecord (protectedRecordBytes stored))
        binding <- maybe (Left (ColimaMutationProfileConflict "Docker profile binding is absent")) Right (originRecordBinding origin)
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

    maybeStage Nothing = Left (ColimaMutationProfileConflict "Managed stage is absent")
    maybeStage (Just value) = Right value
    maybeProfile Nothing = Left (ColimaMutationProfileConflict "Docker profile binding is absent")
    maybeProfile (Just value) = Right value
    runCommand command = first ColimaMutationCommandUnavailable <$> interpret command
    lowerAscii character
      | character >= 'A' && character <= 'Z' = toEnum (fromEnum character + 32)
      | otherwise = character

-- | Clauses 1–3 for one Colima-owned directory. Existing objects are never
-- adopted; recovery from a retained origin is handled by the stage driver.
acquireColimaDirectory :: ProtectedSession session -> RecordKey -> FilePath -> IO (Either OwnershipFault ObjectIdentity)
acquireColimaDirectory session key target = do
  existing <- readProtectedRecord session key
  case existing of
    Left failure -> pure (Left (storeFault "read directory origin" failure))
    Right (Just _) -> pure (Left (OwnershipOccupied (Text.pack target)))
    Right Nothing ->
      enterOwnedObject ownershipRowForHost session target $ \entered -> do
        recorded <- recordOwnedOrigin ownershipRowForHost entered OwnedDirectory publishOrigin
        case recorded of
          Left fault -> pure (Left fault)
          Right token ->
            recordedEvidence
              (\_ record -> case originRecordOrigin record of
                  OriginPresent _ -> pure (Left (OwnershipOccupied (Text.pack target)))
                  OriginAbsent -> do
                    created <- createOwnedDirectory ownershipRowForHost token
                    case created of
                      Left fault -> pure (Left fault)
                      Right identity -> do
                        bound <- bindOwnedIdentity ownershipRowForHost token identity publishBinding
                        pure (fmap (const identity) bound))
              token
  where
    publishOrigin record = do
      written <- compareAndSwapProtectedRecord session key ExpectAbsent (renderOriginRecord record)
      pure (either (Left . storeFault "publish directory origin") (const (Right ())) written)
    publishBinding record = do
      current <- readProtectedRecord session key
      case current of
        Left failure -> pure (Left (storeFault "read directory origin for binding" failure))
        Right Nothing -> pure (Left (OwnershipProbeFailed "bind directory identity" "origin record vanished"))
        Right (Just stored) -> do
          written <-
            compareAndSwapProtectedRecord
              session
              key
              (ExpectVersion (protectedRecordVersion stored))
              (renderOriginRecord record)
          pure (either (Left . storeFault "publish directory binding") (const (Right ())) written)

storeFault :: Text.Text -> ProtectedError -> OwnershipFault
storeFault operation failure = OwnershipProbeFailed operation (protectedErrorMessage failure)

revalidateColimaManifest :: ProtectedSession session -> ColimaOwnershipKeys -> FilePath -> FilePath -> IO (Either OwnershipFault OwnershipManifest)
revalidateColimaManifest session keys home context = do
  retained <- readProtectedRecord session (colimaManifestKey keys)
  homeObserved <- observeOwnershipManifestForHost True home
  contextObserved <- observeOwnershipManifestForHost False context
  pure $ do
    stored <- either (Left . storeFault "read retained Colima manifest") maybeManifest retained
    expected <- parseOwnershipManifest (protectedRecordBytes stored)
    actualHome <- homeObserved
    actualContext <- contextObserved
    prefixedHome <- prefixOwnershipManifest "colima" actualHome
    prefixedContext <- prefixOwnershipManifest "docker" actualContext
    actual <- mergeOwnershipManifests [prefixedHome, prefixedContext]
    if actual == expected
      then Right actual
      else Left (OwnershipMalformed "the current Colima namespace manifest differs from its retained authority")
  where
    maybeManifest Nothing = Left (OwnershipMalformed "retained Colima manifest is absent")
    maybeManifest (Just value) = Right value

-- | Acquire a missing directory or re-enter the exact identity already bound
-- by this record. A replaced or unbound object is a typed refusal.
ensureColimaDirectory :: ProtectedSession session -> RecordKey -> FilePath -> IO (Either OwnershipFault ObjectIdentity)
ensureColimaDirectory session key target = do
  current <- readProtectedRecord session key
  case current of
    Left failure -> pure (Left (storeFault "read directory binding" failure))
    Right Nothing -> acquireColimaDirectory session key target
    Right (Just stored) ->
      case parseOriginRecord (protectedRecordBytes stored) of
        Left fault -> pure (Left fault)
        Right record -> case originRecordBinding record of
          Nothing -> pure (Left (OwnershipMalformed "directory origin is not identity-bound"))
          Just identity ->
            reenterOwnedObject ownershipRowForHost session target record $ \bound -> do
              observed <- reobserveOwnedIdentity ownershipRowForHost bound
              pure (fmap (const identity) observed)

-- | Clause 4 for an empty Colima-owned directory. The caller first validates
-- and removes the directory's admitted manifest; this operation then proves
-- the directory identity, removes that exact object, and forgets its record.
releaseColimaDirectory :: ProtectedSession session -> RecordKey -> FilePath -> IO (Either OwnershipFault ())
releaseColimaDirectory session key target = do
  current <- readProtectedRecord session key
  case current of
    Left failure -> pure (Left (storeFault "read directory binding" failure))
    Right Nothing -> pure (Left (OwnershipMalformed "directory ownership record is absent"))
    Right (Just stored) ->
      case parseOriginRecord (protectedRecordBytes stored) of
        Left fault -> pure (Left fault)
        Right record ->
          reenterOwnedObject ownershipRowForHost session target record $ \bound -> do
            observed <- reobserveOwnedIdentity ownershipRowForHost bound
            case observed of
              Left fault -> pure (Left fault)
              Right releasable ->
                releaseOwnedObject ownershipRowForHost releasable $ \_ -> do
                  deleted <-
                    compareAndDeleteProtectedRecord
                      session
                      key
                      (ExpectVersion (protectedRecordVersion stored))
                  pure (either (Left . storeFault "forget directory binding") Right deleted)

ownershipKeys :: String -> Either String ColimaOwnershipKeys
ownershipKeys profile
  | not (validProfile profile) = Left "invalid direct-Colima profile"
  | otherwise =
      ColimaOwnershipKeys
        <$> key "stage"
        <*> key "home"
        <*> key "context"
        <*> key "disk"
        <*> key "profile"
        <*> key "manifest"
  where
    key suffix =
      first (Text.unpack . protectedErrorMessage)
        (mkRecordKey (Text.pack ("colima-" ++ profile ++ "-" ++ suffix)))
    validProfile value =
      length value == 8
        && take 2 value == "h-"
        && all isLowerHex (drop 2 value)
    isLowerHex value = value >= '0' && value <= '9' || value >= 'a' && value <= 'f'
