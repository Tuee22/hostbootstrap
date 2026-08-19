{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Portable host adapter for the per-user WSL global wall.

The production entry points deliberately accept no pathname. The target is
derived once, where the wall lives, from the current user's profile and the
literal @.wslconfig@ name; every namespace change and conditional deletion runs
against an identity this adapter re-observed under the same exclusive entry.

This module owns the complete recovery driver, the durable record codec, and
the ownership arithmetic — the policy that is genuinely the wall's own. It owns
no platform primitive at all. The four clauses of
@development_plan_standards.md § EE@ are one transaction written once in
"HostBootstrap.Ownership.Primitive", and what differs between a POSIX host and
a Windows host is the row beneath it (§ LL), so this driver consumes that row
rather than a platform seam of its own:

1. clause 1 is the wall's own 'ProtectedStore' entry, taken beside the target
   and released by the kernel when the process dies. It is the same exclusive
   entry the run's data root and generated config take, so there is one
   exclusive open beneath every host-local owner;
2. clause 2 is that store's compare-and-swap. The active record and the
   strictly monotonic fence are two protected records, so the durable origin is
   flushed before the first mutation without a second durable state beside the
   store;
3. clause 3 is the row's identity read — @device:inode@ on POSIX, the volume
   serial number and file index on Windows — read once, in one place;
4. clause 4 re-observes that identity through the same row before every removal
   or move, and refuses a replacement.

Staging uses two links, because the armed object's identity has to be journalled
before a durable name for it exists: the armed name is created exclusively, its
identity is recorded, and only then is the durable stage name linked to it. Both
rows publish a link rather than a move, so an armed object observed in the
create-outcome-unknown phase is this owner's own leftover on either host — its
name embeds this receipt's never-reused fence — and it is removed under the same
exclusive entry and the create retried, so its unknown bytes are never
published.
-}
module HostBootstrap.Wsl2.GlobalWall.Host
  ( -- * Where the one wall lives
    HostWallLocation,
    openHostWallLocation,
    hostWallTargetPath,
    hostWallProtectedStore,
    hostWallActiveRecordKey,

    -- * Requests and results
    CurrentUserWallRequest,
    mkCurrentUserWallRequest,
    requestManagedSpecIdentity,
    AppliedWslConfigFile,
    appliedWslConfigRecord,
    HostWallError (..),
    maximumWallBytes,

    -- * The recovery driver
    applyGlobalWall,
    restoreGlobalWall,

    -- * The durable record codec
    encodeWallRecord,
    decodeWallRecord,
  )
where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import qualified Data.Text as Text
import Data.Word (Word32, Word64, Word8)
import HostBootstrap.Ownership.Object
  ( ObjectIdentity,
    OwnershipFault (OwnershipConflict),
    mkObjectIdentity,
    objectIdentityBytes,
    ownershipFault,
    ownershipFaultMessage,
  )
import HostBootstrap.Ownership.Primitive
  ( OwnershipPrimitive
      ( rowCloseHandle,
        rowCreateFile,
        rowLinkNoReplace,
        rowObserveIdentity,
        rowOpenExclusive,
        rowReadObject,
        rowRemoveObject,
        rowSyncParent
      ),
    OwnershipRow,
    withOwnershipRow,
  )
import HostBootstrap.Protected
  ( Expectation (ExpectAbsent, ExpectVersion),
    ProtectedError,
    ProtectedRecord (protectedRecordBytes, protectedRecordVersion),
    ProtectedSession,
    ProtectedStore,
    RecordKey,
    compareAndDeleteProtectedRecord,
    compareAndSwapProtectedRecord,
    mkRecordKey,
    openProtectedStore,
    protectedErrorMessage,
    readProtectedRecord,
    recordVersionWord,
    withProtectedEntry,
  )
import HostBootstrap.Wsl2.GlobalWall
import HostBootstrap.Wsl2.GlobalWall.ConfigBytes

-- Where the wall lives ------------------------------------------------------------

{- | The one managed @.wslconfig@ and the protected store that holds its
clauses 1 and 2.

The target is settled here rather than by the driver, so no caller input ever
reaches a pathname and the driver never derives one.
-}
data HostWallLocation = HostWallLocation
  { hostWallTarget :: FilePath,
    hostWallStore :: ProtectedStore,
    hostWallActiveKey :: RecordKey,
    hostWallFenceKey :: RecordKey
  }

hostWallTargetPath :: HostWallLocation -> FilePath
hostWallTargetPath = hostWallTarget

{- | The store the wall's clauses 1 and 2 are made of.

Disclosed because the durable state an interruption leaves is a /value/: a
fixture that needs to enter a crash-resume branch writes that value through this
store and re-enters the ordinary entry point, rather than the driver carrying a
branch that exists for a test (§ NN).
-}
hostWallProtectedStore :: HostWallLocation -> ProtectedStore
hostWallProtectedStore = hostWallStore

-- | The record key the active wall record lives under.
hostWallActiveRecordKey :: HostWallLocation -> RecordKey
hostWallActiveRecordKey = hostWallActiveKey

{- | Open the wall's durable state beside the target it manages.

The state directory is ordinary scaffolding; what is owned is the target, and
the store is what clause 1 and clause 2 are made of.
-}
openHostWallLocation ::
  -- | the managed @.wslconfig@
  FilePath ->
  -- | the directory the wall keeps its protected store in
  FilePath ->
  IO (Either HostWallError HostWallLocation)
openHostWallLocation target stateDirectory = do
  opened <- openProtectedStore stateDirectory
  pure $ do
    store <- storeResult opened
    active <- storeResult (mkRecordKey wallActiveRecordKey)
    fence <- storeResult (mkRecordKey wallFenceRecordKey)
    Right
      HostWallLocation
        { hostWallTarget = target,
          hostWallStore = store,
          hostWallActiveKey = active,
          hostWallFenceKey = fence
        }

storeResult :: Either ProtectedError value -> Either HostWallError value
storeResult = either (Left . fromStoreError) Right

wallActiveRecordKey :: Text.Text
wallActiveRecordKey = "wall.hostbootstrap-global.active"

wallFenceRecordKey :: Text.Text
wallFenceRecordKey = "wall.hostbootstrap-global.fence"

{- | Everything one transaction of the driver is entitled to: the row that holds
the clauses, the target it is about, and the exclusive entry it runs inside.

The @session@ index is the protected entry's own, so nothing in the driver can
outlive the entry that authorized it.
-}
data WallEntry session = WallEntry
  { entryRow :: OwnershipRow,
    entryLocation :: HostWallLocation,
    entrySession :: ProtectedSession session
  }

entryTarget :: WallEntry session -> FilePath
entryTarget = hostWallTarget . entryLocation

{- | One object this driver has observed: where it is, which object the kernel
says it is, and the bytes it held at that observation.

There is no handle here. A row's handle cannot outlive the continuation that
minted it, and every namespace act below re-observes the identity through the
row immediately before it acts — which is what clause 4 asks for anyway.
-}
data WallFile = WallFile
  { wallFilePath :: FilePath,
    wallObjectIdentity :: ObjectIdentity,
    wallFileBytes :: ByteString
  }

-- | Identity-only request for the current user's one global wall. No target
-- path is accepted or stored.
data CurrentUserWallRequest = CurrentUserWallRequest
  { requestOwnerIdentity :: ByteString,
    requestSpecIdentity :: ByteString,
    requestReservationIdentity :: ByteString,
    requestReceiptIdentity :: ByteString,
    requestManagedSpec :: ManagedWslConfigSpec
  }
  deriving (Eq)

instance Show CurrentUserWallRequest where
  show request =
    "CurrentUserWallRequest {owner=<"
      ++ show (ByteString.length (requestOwnerIdentity request))
      ++ " bytes>, spec=<"
      ++ show (ByteString.length (requestSpecIdentity request))
      ++ " bytes>, reservation=<"
      ++ show (ByteString.length (requestReservationIdentity request))
      ++ " bytes>, receipt=<"
      ++ show (ByteString.length (requestReceiptIdentity request))
      ++ " bytes>, managed-lines="
      ++ show (managedSpecLineCount (requestManagedSpec request))
      ++ "}"

data HostWallError
  = HostWallUnsupported String
  | HostWallBusy String
  | -- | The row could not complete a kernel operation: @(what, why)@.
    HostWallFailure String String
  | HostWallConfigurationFailure ConfigBytesError
  | HostWallJournalFailure String
  | HostWallModelFailure WallModelError
  | HostWallConflict WallConflict
  | HostWallNoActiveRecord
  deriving (Eq, Show)

{- | Carry the row's closed fault sum into this driver's vocabulary.

Through the total eliminator, so a case added to the seam's sum is a compile
error here rather than a branch that quietly falls through. An /occupied/
observation is a refusal rather than a failure: the object at the name — a
symbolic link, a directory, something another owner holds — is not one this
driver may treat as the wall, and it is left exactly as it was found.
-}
fromOwnershipFault :: OwnershipFault -> HostWallError
fromOwnershipFault =
  ownershipFault
    (HostWallUnsupported . Text.unpack)
    (\operation reason -> HostWallFailure (Text.unpack operation) (Text.unpack reason))
    (HostWallJournalFailure . Text.unpack)
    (HostWallUnsupported . Text.unpack)
    ( \report ->
        HostWallFailure
          "own the host wall"
          (Text.unpack (ownershipFaultMessage (OwnershipConflict report)))
    )

fromStoreError :: ProtectedError -> HostWallError
fromStoreError = HostWallJournalFailure . Text.unpack . protectedErrorMessage

-- | File-scoped proof that the exact managed object and bytes are currently at
-- @.wslconfig@. This does /not/ claim that the WSL runtime has shut down,
-- reloaded the file, or made CPU/memory/swap settings effective.
newtype AppliedWslConfigFile = AppliedWslConfigFile PersistedWallRecord
  deriving (Eq, Show)

appliedWslConfigRecord :: AppliedWslConfigFile -> PersistedWallRecord
appliedWslConfigRecord (AppliedWslConfigFile record) = record

-- | Construct a pathname-free request and reject identities the pure wall
-- model cannot admit. Every backend applies a 16 MiB defensive bound to both
-- journal records and @.wslconfig@ bytes.
mkCurrentUserWallRequest ::
  ByteString ->
  ByteString ->
  ByteString ->
  ByteString ->
  [ByteString] ->
  Either HostWallError CurrentUserWallRequest
mkCurrentUserWallRequest owner spec reservation receipt managedBody
  | ByteString.null owner =
      invalid "wall owner identity must not be empty"
  | ByteString.null spec =
      invalid "wall specification identity must not be empty"
  | ByteString.null reservation =
      invalid "wall reservation identity must not be empty"
  | ByteString.null receipt =
      invalid "wall receipt identity must not be empty"
  | any
      ((> maximumWallBytes) . ByteString.length)
      [owner, spec, reservation, receipt] =
      Left
        ( HostWallUnsupported
            "a wall identity exceeds the 16 MiB journal-field limit"
        )
  | sum (map ByteString.length managedBody) > maximumWallBytes =
      Left
        ( HostWallUnsupported
            "the managed .wslconfig body exceeds the 16 MiB adapter limit"
        )
  | otherwise = do
      managedSpec <-
        either
          (Left . HostWallConfigurationFailure)
          Right
          (mkManagedWslConfigSpec managedBody)
      Right
        CurrentUserWallRequest
          { requestOwnerIdentity = owner,
            requestSpecIdentity = spec,
            requestReservationIdentity = reservation,
            requestReceiptIdentity = receipt,
            requestManagedSpec = managedSpec
          }
  where
    invalid = Left . HostWallModelFailure . InvalidWallIdentity

-- | The wall-spec identity actually recorded: the caller's spec identity bound
-- inseparably to the exact managed body it asked for.
requestManagedSpecIdentity :: CurrentUserWallRequest -> ByteString
requestManagedSpecIdentity = effectiveSpecIdentity

maximumWallBytes :: Int
maximumWallBytes = 16 * 1024 * 1024

data OpenLayoutApply = OpenLayoutApply
  { layoutApplyTarget :: Maybe WallFile,
    layoutApplyStage :: Maybe WallFile,
    layoutApplyRetained :: Maybe WallFile
  }

data OpenLayoutRestore = OpenLayoutRestore
  { layoutRestoreTarget :: Maybe WallFile,
    layoutRestoreRetained :: Maybe WallFile,
    layoutRestoreRetired :: Maybe WallFile
  }

data ApplyRecoveryStep
  = ApplyRecoveryContinue
  | ApplyRecoveryDone PersistedWallRecord

data RestoreRecoveryStep ownerId wallSpecId reservationId receiptId fenceId
  = RestoreRecoverySame
  | RestoreRecoveryWith
      (WallReceipt ownerId wallSpecId reservationId receiptId fenceId)

data SomeWallReceipt
  = forall ownerId wallSpecId reservationId receiptId fenceId.
    SomeWallReceipt
      (WallReceipt ownerId wallSpecId reservationId receiptId fenceId)

applyGlobalWall ::
  OwnershipRow ->
  HostWallLocation ->
  CurrentUserWallRequest ->
  IO (Either HostWallError AppliedWslConfigFile)
applyGlobalWall row location request =
  inWallEntry row location $ \entry -> do
    activeResult <- loadActiveRecord entry
    case activeResult of
      Left err -> pure (Left err)
      Right Nothing -> do
        fenceResult <- allocateFence entry
        case fenceResult of
          Left err -> pure (Left err)
          Right fenceValue -> do
            prepared <- prepareFreshReceipt entry request (entryTarget entry) fenceValue
            case prepared of
              Left err -> pure (Left err)
              Right (SomeWallReceipt claimed) ->
                fmap AppliedWslConfigFile <$> driveApply entry (entryTarget entry) claimed
      Right (Just active) ->
        resumeReceipt request active $ \receipt ->
          fmap AppliedWslConfigFile <$> driveApply entry (entryTarget entry) receipt

restoreGlobalWall ::
  OwnershipRow ->
  HostWallLocation ->
  CurrentUserWallRequest ->
  IO (Either HostWallError ())
restoreGlobalWall row location request =
  inWallEntry row location $ \entry -> do
    activeResult <- loadActiveRecord entry
    case activeResult of
      Left err -> pure (Left err)
      Right Nothing -> pure (Left HostWallNoActiveRecord)
      Right (Just active) ->
        resumeReceipt request active (driveRestore entry (entryTarget entry))

{- | Clause 1, once: run the whole transaction inside the wall store's own
exclusive entry.

The entry is the protected store's, so it is the same OS-released exclusive
open every other host-local owner takes, and a process that dies inside the
bracket releases it without leaving a lock behind.
-}
inWallEntry ::
  OwnershipRow ->
  HostWallLocation ->
  ( forall session.
    WallEntry session ->
    IO (Either HostWallError result)
  ) ->
  IO (Either HostWallError result)
inWallEntry row location use = do
  outcome <-
    withProtectedEntry (hostWallStore location) $ \session ->
      Right <$> use (WallEntry row location session)
  pure $ case outcome of
    Left failure -> Left (fromStoreError failure)
    Right inner -> inner

prepareFreshReceipt ::
  WallEntry session ->
  CurrentUserWallRequest ->
  FilePath ->
  Word64 ->
  IO (Either HostWallError SomeWallReceipt)
prepareFreshReceipt entry request target fenceValue =
  withObservedPath entry target $ \targetFile -> do
    let origin =
          case targetFile of
            Nothing -> OriginalAbsent
            Just file ->
              OriginalPresent
                (wallObjectIdentity file)
                (wallFileBytes file)
    case desiredFromOrigin request origin of
      Left err -> pure (Left err)
      Right desired ->
        withRequestReservation request desired fenceValue $ \reservation ->
          case claimOrResumeWall reservation Nothing of
            Left err -> pure (Left (fromModelError err))
            Right claimed ->
              case
                recordWallOrigin
                  (wallReceiptRecord claimed)
                  claimed
                  origin
                of
                Left err -> pure (Left (fromModelError err))
                Right withOrigin -> do
                  originStored <- storeReceipt entry withOrigin
                  pure
                    ( originStored
                        >> Right (SomeWallReceipt withOrigin)
                    )

resumeReceipt ::
  CurrentUserWallRequest ->
  PersistedWallRecord ->
  ( forall ownerId wallSpecId reservationId receiptId fenceId.
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either HostWallError result)
  ) ->
  IO (Either HostWallError result)
resumeReceipt request active consume =
  case precheckActiveRequest request active of
    Left err -> pure (Left err)
    Right () ->
      case desiredForActive request active of
        Left err -> pure (Left err)
        Right desired ->
          withRequestReservation
            request
            desired
            (persistedFenceValue active)
            $ \reservation ->
              case claimOrResumeWall reservation (Just active) of
                Left err -> pure (Left (fromModelError err))
                Right receipt -> consume receipt

-- | Reject a foreign owner or effective managed specification before parsing
-- or merging the durable origin.  A caller that does not own an active wall
-- must receive a conflict even when that wall's origin bytes would be invalid
-- under the caller's requested merge.  Reversing this order would leak an
-- unrelated configuration error and, more importantly, obscure the ownership
-- refusal that prevents takeover.
precheckActiveRequest ::
  CurrentUserWallRequest ->
  PersistedWallRecord ->
  Either HostWallError ()
precheckActiveRequest request active
  | requestOwnerIdentity request /= persistedOwnerIdentity active =
      Left
        ( HostWallConflict
            ( ForeignWallOwner
                (requestOwnerIdentity request)
                (persistedOwnerIdentity active)
            )
        )
  | effectiveSpecIdentity request /= persistedSpecIdentity active =
      Left
        ( HostWallConflict
            ( IncompatibleWallSpec
                (effectiveSpecIdentity request)
                (persistedSpecIdentity active)
            )
        )
  | otherwise = Right ()

withRequestReservation ::
  CurrentUserWallRequest ->
  ByteString ->
  Word64 ->
  ( forall ownerId wallSpecId reservationId receiptId fenceId.
    WallReservation ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either HostWallError result)
  ) ->
  IO (Either HostWallError result)
withRequestReservation request desired fenceValue consume =
  case joinModel
    ( withWallOwner (requestOwnerIdentity request) $ \owner ->
        joinModel
          ( withWallSpec
              (effectiveSpecIdentity request)
              desired
              $ \spec ->
                joinModel
                  ( withWallFence fenceValue $ \fence ->
                      withWallReservation
                        owner
                        spec
                        (requestReservationIdentity request)
                        (requestReceiptIdentity request)
                        fence
                        consume
                  )
          )
    ) of
    Left err -> pure (Left (fromModelError err))
    Right operation -> operation

desiredForActive ::
  CurrentUserWallRequest ->
  PersistedWallRecord ->
  Either HostWallError ByteString
desiredForActive request active =
  case persistedWallOrigin active of
    Nothing ->
      Left
        ( HostWallJournalFailure
            "an active host wall has no durable origin"
        )
    Just origin -> do
      expected <- desiredFromOrigin request origin
      if expected == persistedDesiredBytes active
        then Right (persistedDesiredBytes active)
        else
          Left
            ( HostWallJournalFailure
                "managed spec does not reproduce the desired bytes from the durable origin"
            )

desiredFromOrigin ::
  CurrentUserWallRequest ->
  WslConfigOrigin ->
  Either HostWallError ByteString
desiredFromOrigin request origin = do
  let originalBytes =
        case origin of
          OriginalAbsent -> ByteString.empty
          OriginalPresent _ bytes -> bytes
  desired <-
    either
      (Left . fromConfigError)
      Right
      (mergeManagedWslConfig originalBytes (requestManagedSpec request))
  if ByteString.length desired > maximumWallBytes
    then
      Left
        ( HostWallUnsupported
            "merged .wslconfig exceeds the 16 MiB adapter limit"
        )
    else Right desired

effectiveSpecIdentity :: CurrentUserWallRequest -> ByteString
effectiveSpecIdentity request =
  LazyByteString.toStrict . Builder.toLazyByteString $
    Builder.byteString "HBWSL-MANAGED-SPEC02"
      <> putSized (requestSpecIdentity request)
      <> putSized (managedSpecIdentityBytes (requestManagedSpec request))

driveApply ::
  WallEntry session ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError PersistedWallRecord)
driveApply entry target = go (0 :: Int)
  where
    go steps receipt
      | steps > 24 =
          pure
            ( Left
                (HostWallJournalFailure "apply recovery exceeded its phase bound")
            )
      | otherwise =
          let active = wallReceiptRecord receipt
           in case persistedWallPhase active of
                WallClaimed ->
                  pure
                    ( Left
                        ( HostWallJournalFailure
                            "durable claimed-only records are unsupported; origin must be the first active record"
                        )
                    )
                WallOriginRecorded ->
                  let candidate = stageCandidate active
                   in case
                        beginWallStageCreation
                          active
                          receipt
                          candidate
                        of
                        Left err -> pure (Left (fromModelError err))
                        Right creating -> do
                          stored <- storeReceipt entry creating
                          case stored of
                            Left err -> pure (Left err)
                            Right () -> go (steps + 1) creating
                WallStageCreateOutcomeUnknown ->
                  driveStage entry steps go target receipt
                WallStageBound ->
                  driveStage entry steps go target receipt
                WallApplyOutcomeUnknown ->
                  driveApplying entry steps go target receipt
                WallApplied ->
                  withApplyLayout entry target active $ \layout ->
                    case
                      settleWallApply
                        active
                        receipt
                        (applyObservation layout)
                      of
                      Left err -> pure (Left (fromModelError err))
                      Right applied -> do
                        stored <- storeReceipt entry applied
                        pure (stored >> Right (wallReceiptRecord applied))
                phase ->
                  pure
                    ( Left
                        ( HostWallModelFailure
                            ( IllegalWallTransition
                                phase
                                "apply cannot take over a wall already in teardown"
                            )
                        )
                    )

driveStage ::
  WallEntry session ->
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either HostWallError PersistedWallRecord)
  ) ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError PersistedWallRecord)
driveStage entry steps continueApply target receipt =
  case checkedStagePaths target active of
    Left err -> pure (Left err)
    Right (boundPath, armedPath) -> do
      classificationResult <-
        withObservedPath entry boundPath $ \boundFile ->
          pure
            (Right (classifyWallStageCreation receipt (fileObservation boundFile)))
      case classificationResult of
        Left err -> pure (Left err)
        Right (StageCreateBlocked conflict) ->
          pure (Left (HostWallConflict conflict))
        Right (StageCreateNotInProgress phase) ->
          pure
            ( Left
                ( HostWallModelFailure
                    ( IllegalWallTransition
                        phase
                        "stage recovery was requested outside a stage phase"
                    )
                )
            )
        Right StageCreateObservedBound ->
          recoverObservedBound
            entry
            steps
            continueApply
            target
            armedPath
            receipt
        Right StageCreateRetry ->
          recoverMissingBound
            entry
            steps
            continueApply
            boundPath
            armedPath
            receipt
  where
    active = wallReceiptRecord receipt

recoverMissingBound ::
  WallEntry session ->
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either HostWallError PersistedWallRecord)
  ) ->
  FilePath ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError PersistedWallRecord)
recoverMissingBound entry steps continueApply boundPath armedPath receipt =
  do
    recovered <-
      withObservedPath entry armedPath $ \armedFile ->
        case armedFile of
          Just file ->
            fmap (True <$)
              ( recoverDurablyBoundArmed
                  entry
                  boundPath
                  armedPath
                  receipt
                  file
              )
          Nothing -> pure (Right False)
    case recovered of
      Left err -> pure (Left err)
      Right True -> continueApply (steps + 1) receipt
      Right False ->
        createBindAndLink
          entry
          steps
          continueApply
          boundPath
          armedPath
          receipt

{- | Recover an armed object that is still present while the durable stage name
is not.

In @WallStageCreateOutcomeUnknown@ the identity of the armed object was never
journalled, so it cannot be checked against the receipt.  What can be checked is
the name: the armed name embeds this receipt's never-reused fence, so a leftover
there is this owner's own interrupted attempt and nobody else's.  It is removed
by exact identity under the same exclusive entry and the create is retried,
which never publishes its bytes.  Both rows create a durable armed object, so
this reading is the same one on every host rather than a per-platform fork.
-}
recoverDurablyBoundArmed ::
  WallEntry session ->
  FilePath ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  WallFile ->
  IO (Either HostWallError ())
recoverDurablyBoundArmed entry boundPath armedPath receipt armedFile =
  case persistedWallPhase active of
    WallStageCreateOutcomeUnknown -> do
      deleted <- deleteWallFile entry armedFile
      pure (deleted >> Right ())
    WallStageBound
      | fileObservation (Just armedFile)
          /= expectedStagedObservation active ->
          pure
            ( Left
                ( stageMismatch
                    active
                    (fileObservation (Just armedFile))
                )
            )
      | otherwise -> do
          linkResult <-
            linkArmedStage
              entry
              armedFile
              armedPath
              boundPath
          case linkResult of
            Left err -> pure (Left err)
            Right () -> deleteWallFile entry armedFile
    phase ->
      pure
        ( Left
            ( HostWallModelFailure
                (IllegalWallTransition phase "unexpected armed-stage recovery phase")
            )
        )
  where
    active = wallReceiptRecord receipt

createBindAndLink ::
  WallEntry session ->
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either HostWallError PersistedWallRecord)
  ) ->
  FilePath ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError PersistedWallRecord)
createBindAndLink entry steps continueApply boundPath armedPath receipt = do
  createdResult <-
    createArmedStage entry armedPath (persistedDesiredBytes active)
  case createdResult of
    Left err -> pure (Left err)
    Right armedFile -> do
      operation <- bindAndLink armedFile
      case operation of
        Left err -> pure (Left err)
        Right boundReceipt -> continueApply (steps + 1) boundReceipt
  where
    active = wallReceiptRecord receipt
    bindAndLink armedFile =
      case validateStageVolume active (wallObjectIdentity armedFile) of
        Left err -> pure (Left err)
        Right () ->
          case
            bindWallStage
              active
              receipt
              ObservedAbsent
              (wallObjectIdentity armedFile)
            of
            Left err -> pure (Left (fromModelError err))
            Right boundReceipt -> do
              stored <- storeReceipt entry boundReceipt
              case stored of
                Left err -> pure (Left err)
                Right () -> do
                  linked <-
                    linkArmedStage
                      entry
                      armedFile
                      armedPath
                      boundPath
                  case linked of
                    Left err -> pure (Left err)
                    Right () ->
                      pure (Right boundReceipt)

recoverObservedBound ::
  WallEntry session ->
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either HostWallError PersistedWallRecord)
  ) ->
  FilePath ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError PersistedWallRecord)
recoverObservedBound entry steps continueApply target armedPath receipt =
  do
    cleanupResult <-
      withObservedPath entry armedPath $ \armedFile ->
        case armedFile of
          Nothing -> pure (Right ())
          Just file
            | fileObservation (Just file) == expectedStagedObservation active ->
                deleteWallFile entry file
            | otherwise ->
                pure
                  ( Left
                      (stageMismatch active (fileObservation (Just file)))
                  )
    case cleanupResult of
      Left err -> pure (Left err)
      Right () -> do
        intentResult <- bindApplyIntent
        case intentResult of
          Left err -> pure (Left err)
          Right applying -> continueApply (steps + 1) applying
  where
    active = wallReceiptRecord receipt
    bindApplyIntent =
      withApplyLayout entry target active $ \layout ->
        case persistedTargetIdentity active of
          Nothing ->
            pure
              ( Left
                  (HostWallJournalFailure "bound stage has no kernel identity")
              )
          Just stageIdentity ->
            case
              beginWallApply
                active
                receipt
                (applyObservation layout)
                stageIdentity
              of
              Left err -> pure (Left (fromModelError err))
              Right applying -> do
                stored <- storeReceipt entry applying
                pure (stored >> Right applying)

driveApplying ::
  WallEntry session ->
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either HostWallError PersistedWallRecord)
  ) ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError PersistedWallRecord)
driveApplying entry steps continueApply target receipt =
  do
    recoveryStep <-
      withApplyLayout entry target active $ \layout ->
        case classifyWallApply receipt (applyObservation layout) of
          ApplyObservedDesired ->
            case settleWallApply active receipt (applyObservation layout) of
              Left err -> pure (Left (fromModelError err))
              Right applied -> do
                stored <- storeReceipt entry applied
                pure
                  ( stored
                      >> Right
                        (ApplyRecoveryDone (wallReceiptRecord applied))
                  )
          ApplyRetryPublication ->
            case persistedWallOrigin active of
              Nothing ->
                pure
                  (Left (HostWallJournalFailure "applying record has no origin"))
              Just OriginalAbsent ->
                publishStage layout
              Just origin@(OriginalPresent _ _) ->
                if observesExactOrigin origin (layoutApplyTarget layout)
                  then retainOrigin layout
                  else publishStage layout
          ApplyBlocked conflict ->
            pure (Left (HostWallConflict conflict))
          classification ->
            pure
              ( Left
                  ( HostWallModelFailure
                      ( IllegalWallTransition
                          WallApplyOutcomeUnknown
                          ("unexpected apply recovery classification " ++ show classification)
                      )
                  )
              )
    case recoveryStep of
      Left err -> pure (Left err)
      Right ApplyRecoveryContinue ->
        continueApply (steps + 1) receipt
      Right (ApplyRecoveryDone record) -> pure (Right record)
  where
    active = wallReceiptRecord receipt
    publishStage layout =
      case layoutApplyStage layout of
        Nothing ->
          pure
            (Left (HostWallJournalFailure "stage vanished before publication"))
        Just stage -> do
          renamed <- renameOpenFile entry stage target
          pure (renamed >> Right ApplyRecoveryContinue)
    retainOrigin layout =
      case layoutApplyTarget layout of
        Nothing ->
          pure
            (Left (HostWallJournalFailure "origin vanished before retention"))
        Just origin -> do
          renamed <- renameOpenFile entry origin (retainedPath target active)
          pure (renamed >> Right ApplyRecoveryContinue)

driveRestore ::
  WallEntry session ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError ())
driveRestore entry target = go (0 :: Int)
  where
    go steps receipt
      | steps > 24 =
          pure
            ( Left
                (HostWallJournalFailure "restore recovery exceeded its phase bound")
            )
      | otherwise =
          let active = wallReceiptRecord receipt
           in case persistedWallPhase active of
                WallApplied ->
                  do
                    beginResult <-
                      withRestoreLayout entry target active $ \layout ->
                        runWithAuthority active receipt $ \authority ->
                          case
                            beginWallRestore
                              active
                              authority
                              receipt
                              (restoreObservation layout)
                            of
                            Left err -> pure (Left (fromModelError err))
                            Right restoring -> do
                              stored <- storeReceipt entry restoring
                              pure (stored >> Right restoring)
                    case beginResult of
                      Left err -> pure (Left err)
                      Right restoring -> go (steps + 1) restoring
                WallRestoreOutcomeUnknown ->
                  driveRestoring entry steps go target receipt
                WallRestored ->
                  withRestoreLayout entry target active $ \layout ->
                    runWithAuthority active receipt $ \authority ->
                      case
                        releaseWall
                          active
                          authority
                          receipt
                          (restoreObservation layout)
                        of
                        Left err -> pure (Left (fromModelError err))
                        Right released -> do
                          stored <- storeReceipt entry released
                          case stored of
                            Left err -> pure (Left err)
                            Right () -> clearReleased entry released
                WallReleased ->
                  withRestoreLayout entry target active $ \layout ->
                    case
                      verifyWallReleased
                        active
                        receipt
                        (restoreObservation layout)
                      of
                      Left err -> pure (Left (fromModelError err))
                      Right () -> clearReleased entry receipt
                phase ->
                  pure
                    ( Left
                        ( HostWallModelFailure
                            ( IllegalWallTransition
                                phase
                                "restore requires a durably applied wall"
                            )
                        )
                    )

driveRestoring ::
  WallEntry session ->
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either HostWallError ())
  ) ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError ())
driveRestoring entry steps continueRestore target receipt =
  do
    recoveryStep <-
      withRestoreLayout entry target active $ \layout ->
        case classifyWallRestore receipt (restoreObservation layout) of
          RestoreRetryFromApplied ->
            case persistedWallOrigin active of
              Nothing ->
                pure
                  (Left (HostWallJournalFailure "restoring record has no origin"))
              Just OriginalAbsent -> deleteManagedTarget layout
              Just (OriginalPresent _ _) -> retireManagedTarget layout
          RestoreRetryOriginPublication ->
            publishOrigin layout
          RestoreRetryManagedCleanup ->
            deleteRetiredManaged layout
          RestoreObservedOrigin ->
            runWithAuthority active receipt $ \authority ->
              case
                settleWallRestore
                  active
                  authority
                  receipt
                  (restoreObservation layout)
                of
                Left err -> pure (Left (fromModelError err))
                Right restored -> do
                  stored <- storeReceipt entry restored
                  pure (stored >> Right (RestoreRecoveryWith restored))
          RestoreBlocked conflict ->
            pure (Left (HostWallConflict conflict))
          classification ->
            pure
              ( Left
                  ( HostWallModelFailure
                      ( IllegalWallTransition
                          WallRestoreOutcomeUnknown
                          ("unexpected restore recovery classification " ++ show classification)
                      )
                  )
              )
    case recoveryStep of
      Left err -> pure (Left err)
      Right RestoreRecoverySame ->
        continueRestore (steps + 1) receipt
      Right (RestoreRecoveryWith nextReceipt) ->
        continueRestore (steps + 1) nextReceipt
  where
    active = wallReceiptRecord receipt
    deleteManagedTarget layout =
      case layoutRestoreTarget layout of
        Nothing ->
          pure
            (Left (HostWallJournalFailure "managed target vanished before delete"))
        Just managed -> do
          deleted <- deleteWallFile entry managed
          pure (deleted >> Right RestoreRecoverySame)
    retireManagedTarget layout =
      case layoutRestoreTarget layout of
        Nothing ->
          pure
            (Left (HostWallJournalFailure "managed target vanished before retirement"))
        Just managed -> do
          renamed <- renameOpenFile entry managed (retiredPath target active)
          pure (renamed >> Right RestoreRecoverySame)
    publishOrigin layout =
      case layoutRestoreRetained layout of
        Nothing ->
          pure
            (Left (HostWallJournalFailure "retained origin vanished before publication"))
        Just origin -> do
          renamed <- renameOpenFile entry origin target
          pure (renamed >> Right RestoreRecoverySame)
    deleteRetiredManaged layout =
      case layoutRestoreRetired layout of
        Nothing ->
          pure
            (Left (HostWallJournalFailure "retired managed object vanished before delete"))
        Just managed -> do
          deleted <- deleteWallFile entry managed
          pure (deleted >> Right RestoreRecoverySame)

runWithAuthority ::
  PersistedWallRecord ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  ( WallAuthority ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either HostWallError result)
  ) ->
  IO (Either HostWallError result)
runWithAuthority active receipt consume =
  case joinModel
    (withWallAuthority active receipt (Right . consume)) of
    Left err -> pure (Left (fromModelError err))
    Right operation -> operation

clearReleased ::
  WallEntry session ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError ())
clearReleased entry receipt = do
  cleared <- deleteActiveIfEqual entry (wallReceiptRecord receipt)
  pure $
    case cleared of
      Left err -> Left err
      Right True -> Right ()
      Right False ->
        Left
          ( HostWallJournalFailure
              "released active record changed before conditional clear"
          )

withApplyLayout ::
  WallEntry session ->
  FilePath ->
  PersistedWallRecord ->
  (OpenLayoutApply -> IO (Either HostWallError result)) ->
  IO (Either HostWallError result)
withApplyLayout entry target record consume =
  case checkedStagePaths target record of
    Left err -> pure (Left err)
    Right (stage, _) ->
      withObservedPath entry target $ \targetFile -> do
        withObservedPath entry stage $ \stageFile -> do
          let retained = retainedPath target record
          withObservedPath entry retained $ \retainedFile ->
            consume
              OpenLayoutApply
                { layoutApplyTarget = targetFile,
                  layoutApplyStage = stageFile,
                  layoutApplyRetained = retainedFile
                }

withRestoreLayout ::
  WallEntry session ->
  FilePath ->
  PersistedWallRecord ->
  (OpenLayoutRestore -> IO (Either HostWallError result)) ->
  IO (Either HostWallError result)
withRestoreLayout entry target record consume =
  withObservedPath entry target $ \targetFile -> do
    let retained = retainedPath target record
        retired = retiredPath target record
    withObservedPath entry retained $ \retainedFile ->
      withObservedPath entry retired $ \retiredFile ->
        consume
          OpenLayoutRestore
            { layoutRestoreTarget = targetFile,
              layoutRestoreRetained = retainedFile,
              layoutRestoreRetired = retiredFile
            }

applyObservation :: OpenLayoutApply -> ApplyObservation
applyObservation layout =
  ApplyObservation
    { applyTargetObservation = fileObservation (layoutApplyTarget layout),
      applyStagedObservation = fileObservation (layoutApplyStage layout),
      applyRetainedOriginObservation =
        fileObservation (layoutApplyRetained layout)
    }

restoreObservation :: OpenLayoutRestore -> RestoreObservation
restoreObservation layout =
  RestoreObservation
    { restoreTargetObservation = fileObservation (layoutRestoreTarget layout),
      restoreRetainedOriginObservation =
        fileObservation (layoutRestoreRetained layout),
      restoreRetiredManagedObservation =
        fileObservation (layoutRestoreRetired layout)
    }

fileObservation :: Maybe WallFile -> WallObservation
fileObservation Nothing = ObservedAbsent
fileObservation (Just file) =
  ObservedPresent (wallObjectIdentity file) (wallFileBytes file)

expectedStagedObservation :: PersistedWallRecord -> WallObservation
expectedStagedObservation record =
  case persistedTargetIdentity record of
    Nothing -> ObservedAbsent
    Just identity -> ObservedPresent identity (persistedDesiredBytes record)

observesExactOrigin :: WslConfigOrigin -> Maybe WallFile -> Bool
observesExactOrigin OriginalAbsent Nothing = True
observesExactOrigin (OriginalPresent identity bytes) (Just file) =
  identity == wallObjectIdentity file && bytes == wallFileBytes file
observesExactOrigin _ _ = False

stageMismatch :: PersistedWallRecord -> WallObservation -> HostWallError
stageMismatch record observation =
  case (persistedTargetIdentity record, observation) of
    (Just expected, ObservedPresent observed _)
      | expected /= observed ->
          HostWallConflict (TargetReplaced expected observed)
      | otherwise ->
          HostWallConflict (TargetAmbiguous expected)
    (Just expected, ObservedAbsent) ->
      HostWallConflict (UnexpectedTargetAbsent expected)
    (Nothing, ObservedPresent observed _) ->
      HostWallConflict (UnboundStagePresent observed)
    (Nothing, ObservedAbsent) ->
      HostWallJournalFailure "stage mismatch has no bound identity"

-- | Both supported identity encodings put the volume/device word first, so the
-- staged object can be proved to share a volume with the origin without the
-- driver knowing which platform produced the bytes.
validateStageVolume ::
  PersistedWallRecord ->
  ObjectIdentity ->
  Either HostWallError ()
validateStageVolume record stagedIdentity =
  case persistedWallOrigin record of
    Just (OriginalPresent originalIdentity _)
      | identityVolume originalIdentity /= identityVolume stagedIdentity ->
          Left
            ( HostWallUnsupported
                "the staged .wslconfig is not on the origin volume"
            )
    _ -> Right ()

identityVolume :: ObjectIdentity -> ByteString
identityVolume = ByteString.take 8 . objectIdentityBytes

checkedStagePaths ::
  FilePath ->
  PersistedWallRecord ->
  Either HostWallError (FilePath, FilePath)
checkedStagePaths target record =
  let expected = stageCandidate record
   in case persistedStageCandidate record of
        Just observed
          | observed == expected ->
              Right
                ( target ++ ByteStringChar8.unpack observed,
                  target ++ ByteStringChar8.unpack observed ++ ".armed"
                )
          | otherwise ->
              Left
                ( HostWallJournalFailure
                    "persisted stage candidate is not the adapter-derived name"
                )
        Nothing ->
          Left
            (HostWallJournalFailure "stage phase has no candidate name")

stageCandidate :: PersistedWallRecord -> ByteString
stageCandidate record =
  ByteStringChar8.pack
    ( ".hostbootstrap."
        ++ show (persistedFenceValue record)
        ++ ".stage"
    )

retainedPath :: FilePath -> PersistedWallRecord -> FilePath
retainedPath target record =
  target
    ++ ".hostbootstrap."
    ++ show (persistedFenceValue record)
    ++ ".origin"

retiredPath :: FilePath -> PersistedWallRecord -> FilePath
retiredPath target record =
  target
    ++ ".hostbootstrap."
    ++ show (persistedFenceValue record)
    ++ ".managed"

-- The row beneath the driver --------------------------------------------------------

{- | Run one primitive of the entry's row.

Rank-2 in the handle, so no handle a row mints can leave the continuation that
minted it — which is why this driver holds observations rather than handles.
-}
onRow ::
  WallEntry session ->
  (forall handle. OwnershipPrimitive handle -> IO (Either OwnershipFault result)) ->
  IO (Either HostWallError result)
onRow entry use = do
  outcome <- withOwnershipRow (entryRow entry) use
  pure (either (Left . fromOwnershipFault) Right outcome)

{- | Observe one name: which object the kernel says is there, and the bytes it
holds.

An absence is authoritative; anything the row calls occupied — a symbolic link,
a directory, an object another owner holds — is a refusal rather than an
observation, so the driver never treats such an object as its wall.
-}
withObservedPath ::
  WallEntry session ->
  FilePath ->
  (Maybe WallFile -> IO (Either HostWallError result)) ->
  IO (Either HostWallError result)
withObservedPath entry path consume = do
  observed <- observeWallFile entry path
  case observed of
    Left err -> pure (Left err)
    Right file -> consume file

observeWallFile ::
  WallEntry session ->
  FilePath ->
  IO (Either HostWallError (Maybe WallFile))
observeWallFile entry path = do
  probed <- probeWallIdentity entry path
  case probed of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right Nothing)
    Right (Just identity) -> do
      contents <- readWholeObject entry path
      pure $ case contents of
        Left err -> Left err
        Right bytes
          | ByteString.length bytes > maximumWallBytes ->
              Left
                ( HostWallUnsupported
                    (path ++ " exceeds the 16 MiB adapter limit")
                )
          | otherwise ->
              Right
                ( Just
                    WallFile
                      { wallFilePath = path,
                        wallObjectIdentity = identity,
                        wallFileBytes = bytes
                      }
                )

-- | Clause 3's identity read, once, through the row.
probeWallIdentity ::
  WallEntry session ->
  FilePath ->
  IO (Either HostWallError (Maybe ObjectIdentity))
probeWallIdentity entry path =
  onRow entry (\row -> rowObserveIdentity row path)

-- | Read one whole object through the row's exclusive open, closing the handle
-- however the read went.
readWholeObject ::
  WallEntry session ->
  FilePath ->
  IO (Either HostWallError ByteString)
readWholeObject entry path =
  onRow entry $ \row -> do
    opened <- rowOpenExclusive row path
    case opened of
      Left fault -> pure (Left fault)
      Right handle -> do
        contents <- rowReadObject row handle
        closed <- rowCloseHandle row handle
        pure $ case (contents, closed) of
          (Left fault, _) -> Left fault
          (_, Left fault) -> Left fault
          (Right bytes, Right ()) -> Right bytes

{- | Clause 4: remove an object only while the kernel still says it is the one
observed.

The re-observation is the whole of the condition, and it runs inside the same
exclusive entry as the observation it is checked against.
-}
deleteWallFile ::
  WallEntry session ->
  WallFile ->
  IO (Either HostWallError ())
deleteWallFile entry file =
  withConfirmedIdentity entry file $
    onRow entry (\row -> rowRemoveObject row (wallFilePath file))

{- | Move the exact observed object to a destination that must not exist.

The kernel primitive beneath is a link, so the move is a link followed by the
withdrawal of the source name. A refused link is reprobed for identity evidence
rather than read off a status: a destination that is already there is an
unexpected object, one that is not there is contention this caller may retry.
-}
renameOpenFile ::
  WallEntry session ->
  WallFile ->
  FilePath ->
  IO (Either HostWallError ())
renameOpenFile entry file destination =
  withConfirmedIdentity entry file $ do
    linked <- onRow entry (\row -> rowLinkNoReplace row (wallFilePath file) destination)
    case linked of
      Right () -> onRow entry (\row -> rowRemoveObject row (wallFilePath file))
      Left err -> do
        observed <- probeWallIdentity entry destination
        pure $ case observed of
          Right (Just identity)
            | identity == wallObjectIdentity file -> Right ()
            | otherwise ->
                Left (HostWallConflict (UnexpectedTargetPresent identity))
          Right Nothing ->
            Left
              ( HostWallBusy
                  ( "the no-replace move destination changed while reprobed: "
                      ++ destination
                  )
              )
          Left _ -> Left err

{- | Re-observe an object's identity and refuse anything but the one this
driver bound, then act.

Every namespace act below goes through this, so clause 4 is written once rather
than once per act.
-}
withConfirmedIdentity ::
  WallEntry session ->
  WallFile ->
  IO (Either HostWallError result) ->
  IO (Either HostWallError result)
withConfirmedIdentity entry file act = do
  observed <- probeWallIdentity entry (wallFilePath file)
  case observed of
    Left err -> pure (Left err)
    Right (Just identity)
      | identity == wallObjectIdentity file -> act
      | otherwise ->
          pure
            ( Left
                ( HostWallConflict
                    (TargetReplaced (wallObjectIdentity file) identity)
                )
            )
    Right Nothing ->
      pure
        ( Left
            ( HostWallConflict
                (UnexpectedTargetAbsent (wallObjectIdentity file))
            )
        )

{- | Create the private armed stage exclusively and read its identity.

A name that is already taken is exact evidence of an unowned collision at this
receipt's own never-reused stage name, so it is a conflict rather than
something to adopt.
-}
createArmedStage ::
  WallEntry session ->
  FilePath ->
  ByteString ->
  IO (Either HostWallError WallFile)
createArmedStage entry path bytes = do
  created <- onRow entry (\row -> rowCreateFile row path bytes)
  case created of
    Left err -> do
      observed <- probeWallIdentity entry path
      pure $ case observed of
        Right (Just identity) ->
          Left (HostWallConflict (UnboundStagePresent identity))
        _ -> Left err
    Right () -> do
      synced <- onRow entry (\row -> rowSyncParent row path)
      case synced of
        Left err -> pure (Left err)
        Right () -> do
          observed <- probeWallIdentity entry path
          pure $ case observed of
            Left err -> Left err
            Right Nothing ->
              Left
                ( HostWallJournalFailure
                    "the armed stage this transaction created is no longer there"
                )
            Right (Just identity) ->
              Right
                WallFile
                  { wallFilePath = path,
                    wallObjectIdentity = identity,
                    wallFileBytes = bytes
                  }

{- | Give the already identified armed object a second, durable name.

This is the one place the driver needs a link rather than a move: the armed
object's identity is journalled before any durable name for it exists, which is
what makes the create-outcome-unknown phase resolvable.
-}
linkArmedStage ::
  WallEntry session ->
  WallFile ->
  FilePath ->
  FilePath ->
  IO (Either HostWallError ())
linkArmedStage entry file armed bound = do
  linked <- onRow entry (\row -> rowLinkNoReplace row armed bound)
  case linked of
    Right () -> onRow entry (\row -> rowSyncParent row bound)
    Left err -> do
      observed <- probeWallIdentity entry bound
      pure $ case observed of
        Right (Just identity)
          | identity == wallObjectIdentity file -> Right ()
          | otherwise ->
              Left (HostWallConflict (UnboundStagePresent identity))
        Right Nothing ->
          Left
            ( HostWallBusy
                "the durable stage destination changed during hard-link publication"
            )
        Left _ -> Left err

-- Clause 2, in the wall's own protected store ---------------------------------------

loadActiveRecord ::
  WallEntry session ->
  IO (Either HostWallError (Maybe PersistedWallRecord))
loadActiveRecord entry = do
  loaded <- readWallRecord entry (hostWallActiveKey (entryLocation entry))
  pure $ case loaded of
    Left err -> Left err
    Right Nothing -> Right Nothing
    Right (Just stored) -> Just <$> decodeWallRecord (protectedRecordBytes stored)

readWallRecord ::
  WallEntry session ->
  RecordKey ->
  IO (Either HostWallError (Maybe ProtectedRecord))
readWallRecord entry key = do
  observed <- readProtectedRecord (entrySession entry) key
  pure (either (Left . fromStoreError) Right observed)

storeReceipt ::
  WallEntry session ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError ())
storeReceipt entry = storeRecord entry . wallReceiptRecord

{- | Publish the active record against the exact version just read back inside
this entry, so the store stays the one place a version lives.
-}
storeRecord ::
  WallEntry session ->
  PersistedWallRecord ->
  IO (Either HostWallError ())
storeRecord entry record =
  let bytes = encodeWallRecord record
      key = hostWallActiveKey (entryLocation entry)
   in if ByteString.length bytes > maximumWallBytes
        then
          pure
            ( Left
                ( HostWallUnsupported
                    "encoded active wall record exceeds the 16 MiB recoverable limit"
                )
            )
        else do
          current <- readWallRecord entry key
          case current of
            Left err -> pure (Left err)
            Right observed -> do
              written <-
                compareAndSwapProtectedRecord
                  (entrySession entry)
                  key
                  (expectationOf observed)
                  bytes
              pure (either (Left . fromStoreError) (const (Right ())) written)

{- | Clear the active record, and only while it is still byte-for-byte the one
this settlement released.
-}
deleteActiveIfEqual ::
  WallEntry session ->
  PersistedWallRecord ->
  IO (Either HostWallError Bool)
deleteActiveIfEqual entry record = do
  let key = hostWallActiveKey (entryLocation entry)
  current <- readWallRecord entry key
  case current of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right False)
    Right (Just stored)
      | protectedRecordBytes stored /= encodeWallRecord record -> pure (Right False)
      | otherwise -> do
          deleted <-
            compareAndDeleteProtectedRecord
              (entrySession entry)
              key
              (ExpectVersion (protectedRecordVersion stored))
          pure (either (Left . fromStoreError) (const (Right True)) deleted)

{- | Allocate a strictly monotonic fence that is never reused.

The store's own record version is that counter: it increases on every write to
one record and the record is never deleted, so a fence this driver hands out is
strictly greater than every fence it ever handed out before.
-}
allocateFence ::
  WallEntry session ->
  IO (Either HostWallError Word64)
allocateFence entry = do
  let key = hostWallFenceKey (entryLocation entry)
  current <- readWallRecord entry key
  case current of
    Left err -> pure (Left err)
    Right observed -> do
      written <-
        compareAndSwapProtectedRecord
          (entrySession entry)
          key
          (expectationOf observed)
          wallFencePayload
      pure
        ( either
            (Left . fromStoreError)
            (Right . recordVersionWord)
            written
        )

-- | What the fence record holds. Only its version carries meaning.
wallFencePayload :: ByteString
wallFencePayload = "hostbootstrap-global-wall-fence\n"

expectationOf :: Maybe ProtectedRecord -> Expectation
expectationOf Nothing = ExpectAbsent
expectationOf (Just stored) = ExpectVersion (protectedRecordVersion stored)

encodeWallRecord :: PersistedWallRecord -> ByteString
encodeWallRecord record =
  LazyByteString.toStrict . Builder.toLazyByteString $
    Builder.byteString wallRecordMagic
      <> Builder.word8 (phaseTag (persistedWallPhase record))
      <> Builder.word64LE (persistedFenceValue record)
      <> putSized (persistedOwnerIdentity record)
      <> putSized (persistedSpecIdentity record)
      <> putSized (persistedReservationIdentity record)
      <> putSized (persistedReceiptIdentity record)
      <> putSized (persistedDesiredBytes record)
      <> putOrigin (persistedWallOrigin record)
      <> putMaybeBytes (persistedStageCandidate record)
      <> putMaybeIdentity (persistedTargetIdentity record)

wallRecordMagic :: ByteString
wallRecordMagic = "HBWSLH03"

phaseTag :: WallJournalPhase -> Word8
phaseTag WallClaimed = 0
phaseTag WallOriginRecorded = 1
phaseTag WallStageCreateOutcomeUnknown = 2
phaseTag WallStageBound = 3
phaseTag WallApplyOutcomeUnknown = 4
phaseTag WallApplied = 5
phaseTag WallRestoreOutcomeUnknown = 6
phaseTag WallRestored = 7
phaseTag WallReleased = 8

putSized :: ByteString -> Builder.Builder
putSized bytes =
  Builder.word32LE (fromIntegral (ByteString.length bytes))
    <> Builder.byteString bytes

putMaybeBytes :: Maybe ByteString -> Builder.Builder
putMaybeBytes Nothing = Builder.word8 0
putMaybeBytes (Just bytes) = Builder.word8 1 <> putSized bytes

putMaybeIdentity :: Maybe ObjectIdentity -> Builder.Builder
putMaybeIdentity Nothing = Builder.word8 0
putMaybeIdentity (Just identity) =
  Builder.word8 1 <> putSized (objectIdentityBytes identity)

putOrigin :: Maybe WslConfigOrigin -> Builder.Builder
putOrigin Nothing = Builder.word8 0
putOrigin (Just OriginalAbsent) = Builder.word8 1
putOrigin (Just (OriginalPresent identity bytes)) =
  Builder.word8 2
    <> putSized (objectIdentityBytes identity)
    <> putSized bytes

newtype Decoder value = Decoder
  { runDecoder :: ByteString -> Either String (value, ByteString)
  }

instance Functor Decoder where
  fmap transform (Decoder decode) =
    Decoder $ \input -> do
      (value, rest) <- decode input
      Right (transform value, rest)

instance Applicative Decoder where
  pure value = Decoder (\input -> Right (value, input))
  Decoder decodeFunction <*> Decoder decodeValue =
    Decoder $ \input -> do
      (function, afterFunction) <- decodeFunction input
      (value, afterValue) <- decodeValue afterFunction
      Right (function value, afterValue)

instance Monad Decoder where
  Decoder decodeValue >>= next =
    Decoder $ \input -> do
      (value, rest) <- decodeValue input
      runDecoder (next value) rest

decodeWallRecord :: ByteString -> Either HostWallError PersistedWallRecord
decodeWallRecord bytes =
  case runDecoder wallRecordDecoder bytes of
    Left err -> Left (HostWallJournalFailure err)
    Right (_, trailing)
      | not (ByteString.null trailing) ->
          Left
            (HostWallJournalFailure "active wall record has trailing bytes")
    Right (record, _) -> Right record

wallRecordDecoder :: Decoder PersistedWallRecord
wallRecordDecoder = do
  magic <- getBytes (ByteString.length wallRecordMagic)
  if magic /= wallRecordMagic
    then decoderFailure "active wall record has an unknown format"
    else pure ()
  phase <- getWord8 >>= decodePhase
  fence <- getWord64LE
  owner <- getSized
  spec <- getSized
  reservation <- getSized
  receipt <- getSized
  desired <- getSized
  origin <- getOrigin
  candidate <- getMaybeBytes
  target <- getMaybeIdentity
  pure
    PersistedWallRecord
      { persistedOwnerIdentity = owner,
        persistedSpecIdentity = spec,
        persistedReservationIdentity = reservation,
        persistedReceiptIdentity = receipt,
        persistedFenceValue = fence,
        persistedDesiredBytes = desired,
        persistedWallPhase = phase,
        persistedWallOrigin = origin,
        persistedStageCandidate = candidate,
        persistedTargetIdentity = target
      }

decodePhase :: Word8 -> Decoder WallJournalPhase
decodePhase 0 = pure WallClaimed
decodePhase 1 = pure WallOriginRecorded
decodePhase 2 = pure WallStageCreateOutcomeUnknown
decodePhase 3 = pure WallStageBound
decodePhase 4 = pure WallApplyOutcomeUnknown
decodePhase 5 = pure WallApplied
decodePhase 6 = pure WallRestoreOutcomeUnknown
decodePhase 7 = pure WallRestored
decodePhase 8 = pure WallReleased
decodePhase _ = decoderFailure "active wall record has an unknown phase"

getOrigin :: Decoder (Maybe WslConfigOrigin)
getOrigin = do
  tag <- getWord8
  case tag of
    0 -> pure Nothing
    1 -> pure (Just OriginalAbsent)
    2 -> do
      identity <- getIdentity
      bytes <- getSized
      pure (Just (OriginalPresent identity bytes))
    _ -> decoderFailure "active wall record has an unknown origin tag"

getMaybeBytes :: Decoder (Maybe ByteString)
getMaybeBytes = do
  tag <- getWord8
  case tag of
    0 -> pure Nothing
    1 -> Just <$> getSized
    _ -> decoderFailure "active wall record has an unknown optional-bytes tag"

getMaybeIdentity :: Decoder (Maybe ObjectIdentity)
getMaybeIdentity = do
  tag <- getWord8
  case tag of
    0 -> pure Nothing
    1 -> Just <$> getIdentity
    _ -> decoderFailure "active wall record has an unknown optional-identity tag"

-- | Kernel identity evidence is a bounded opaque byte string: 16 bytes of
-- @device:inode@ on POSIX and 24 bytes of @FILE_ID_INFO@ on Windows. The codec
-- bounds it rather than fixing one platform's width.
getIdentity :: Decoder ObjectIdentity
getIdentity = do
  bytes <- getSized
  if ByteString.length bytes < 8 || ByteString.length bytes > 64
    then
      decoderFailure
        "kernel identity evidence must be between 8 and 64 bytes"
    else case mkObjectIdentity bytes of
      Left err -> decoderFailure (Text.unpack (ownershipFaultMessage err))
      Right identity -> pure identity

getSized :: Decoder ByteString
getSized = do
  lengthValue <- getWord32LE
  if lengthValue > fromIntegral maximumWallBytes
    then decoderFailure "active wall record field exceeds the 16 MiB limit"
    else getBytes (fromIntegral lengthValue)

getWord8 :: Decoder Word8
getWord8 = do
  bytes <- getBytes 1
  pure (ByteString.index bytes 0)

getWord32LE :: Decoder Word32
getWord32LE = do
  bytes <- getBytes 4
  pure
    ( fromIntegral (ByteString.index bytes 0)
        .|. shiftL (fromIntegral (ByteString.index bytes 1)) 8
        .|. shiftL (fromIntegral (ByteString.index bytes 2)) 16
        .|. shiftL (fromIntegral (ByteString.index bytes 3)) 24
    )

getWord64LE :: Decoder Word64
getWord64LE = do
  bytes <- getBytes 8
  pure
    ( fromIntegral (ByteString.index bytes 0)
        .|. shiftL (fromIntegral (ByteString.index bytes 1)) 8
        .|. shiftL (fromIntegral (ByteString.index bytes 2)) 16
        .|. shiftL (fromIntegral (ByteString.index bytes 3)) 24
        .|. shiftL (fromIntegral (ByteString.index bytes 4)) 32
        .|. shiftL (fromIntegral (ByteString.index bytes 5)) 40
        .|. shiftL (fromIntegral (ByteString.index bytes 6)) 48
        .|. shiftL (fromIntegral (ByteString.index bytes 7)) 56
    )

getBytes :: Int -> Decoder ByteString
getBytes count =
  Decoder $ \input ->
    if count < 0 || ByteString.length input < count
      then Left "active wall record is truncated"
      else Right (ByteString.take count input, ByteString.drop count input)

decoderFailure :: String -> Decoder value
decoderFailure message = Decoder (const (Left message))

fromModelError :: WallModelError -> HostWallError
fromModelError (WallConflictError conflict) = HostWallConflict conflict
fromModelError err = HostWallModelFailure err

fromConfigError :: ConfigBytesError -> HostWallError
fromConfigError = HostWallConfigurationFailure

joinModel :: Either error (Either error value) -> Either error value
joinModel = either Left id
