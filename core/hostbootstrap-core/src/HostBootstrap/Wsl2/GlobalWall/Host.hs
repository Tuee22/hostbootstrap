{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Portable host adapter for the per-user WSL global wall.

The production entry points deliberately accept no pathname. The target is
always derived by the platform backend from the current user's profile and the
literal @.wslconfig@ name.  All namespace changes and conditional deletions
operate through a previously identity-verified handle.

This module owns the complete recovery driver, the durable record codec, and
the ownership arithmetic.  Everything platform-specific is reached through
'HostWallBackend', whose four ownership obligations are the ones
[ownership_invariant](../documents/architecture/ownership_invariant.md) states:

1. an OS-released exclusive lock spans observe → mutate → settle
   (@'wallWithExclusiveEntry'@ — POSIX @fcntl@ write lock, Windows
   @LockFileEx@);
2. a durable origin record naming exact bytes or absence is flushed before the
   first mutation (the journal operations plus 'HostBootstrap.Wsl2.GlobalWall');
3. every observation carries the object's stable kernel identity
   (@device:inode@ on POSIX, @BY_HANDLE_FILE_INFORMATION@ on Windows), never a
   pathname;
4. release is conditioned on re-observing that identity under the same lock.

Staging uses two links.  On a backend whose armed link is volatile
(@'wallArmedStageIsVolatile'@ — Windows @FILE_FLAG_DELETE_ON_CLOSE@) the first
link cannot survive an ordinary process death, so an armed object observed in
the create-outcome-unknown phase is foreign and refused.  On a backend whose
armed link is durable (POSIX), the same observation is our own fence-private
leftover: it is deleted under the same exclusive lock and the create is
retried, so its unknown bytes are never published.
-}
module HostBootstrap.Wsl2.GlobalWall.Host
  ( -- * The portable platform seam
    HostWallBackend (..),
    SomeHostWallBackend (..),
    WallObject (..),

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

import Control.Exception (mask, onException)
import Control.Monad (void)
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Word (Word32, Word64, Word8)
import HostBootstrap.Wsl2.GlobalWall
import HostBootstrap.Wsl2.GlobalWall.ConfigBytes

-- | An exactly identified file object held open by the platform backend. The
-- handle is backend-private; the driver may only pass it back to the same
-- backend.
data WallObject handle = WallObject
  { wallObjectHandle :: handle,
    wallObjectIdentity :: FileIdentity,
    wallObjectBytes :: ByteString
  }

-- | The complete platform seam. A backend supplies primitives only; it never
-- interprets the wall state machine, and it never chooses a target pathname
-- from caller input.
data HostWallBackend handle = HostWallBackend
  { -- | Diagnostic name of the platform lane, e.g. @"posix"@ or @"windows"@.
    wallBackendName :: String,
    -- | Derive the current user's @.wslconfig@ target. No caller input.
    wallTargetPath :: IO (Either HostWallError FilePath),
    -- | Clause 1: run the complete action under an OS-released exclusive lock.
    wallWithExclusiveEntry ::
      forall result.
      IO (Either HostWallError result) ->
      IO (Either HostWallError result),
    -- | Open an existing object for exact observation, or report absence.
    -- Never follows a symbolic link and never opens a directory.
    wallOpenExclusive ::
      FilePath ->
      IO (Either HostWallError (Maybe (WallObject handle))),
    -- | Read only a path's kernel identity without asking for data or
    -- mutation access.
    wallProbeIdentity :: FilePath -> IO (Either HostWallError (Maybe FileIdentity)),
    -- | Create the private armed stage exclusively and return its identity.
    wallCreateArmedStage ::
      FilePath ->
      ByteString ->
      IO (Either HostWallError (WallObject handle)),
    -- | Publish a second, durable link to the already identified armed object.
    wallLinkArmedStage ::
      WallObject handle ->
      FilePath ->
      FilePath ->
      IO (Either HostWallError ()),
    -- | Move the exact open object to a destination that must not exist.
    wallRenameNoReplace ::
      WallObject handle ->
      FilePath ->
      IO (Either HostWallError ()),
    -- | Clause 4: remove the object only while it still has the observed
    -- identity.
    wallDeleteObject :: WallObject handle -> IO (Either HostWallError ()),
    wallCloseObject :: WallObject handle -> IO (Either HostWallError ()),
    -- | 'True' when the armed stage link dies with the process, so an armed
    -- object observed before its identity was journalled must be foreign.
    wallArmedStageIsVolatile :: Bool,
    -- | Classify a native status as an exclusive-observation collision.
    wallIsSharingFailure :: Word32 -> Bool,
    -- | Classify a native status as a benign collision/contention race.
    wallIsRaceFailure :: Word32 -> Bool,
    -- | Classify a native status as "this filesystem has no hard links".
    wallIsHardLinkUnsupported :: Word32 -> Bool,
    -- | Clause 2: the durable journal. Load returns the encoded active record.
    wallJournalLoad :: IO (Either HostWallError (Maybe ByteString)),
    -- | Allocate a strictly monotonic, never-reused fence.
    wallJournalAllocateFence :: IO (Either HostWallError Word64),
    wallJournalStore :: ByteString -> IO (Either HostWallError ()),
    -- | Conditionally clear the active record, only when it is byte-equal.
    wallJournalDeleteIfEqual :: ByteString -> IO (Either HostWallError Bool)
  }

-- | A backend with its handle representation hidden, so a caller can select a
-- platform lane without naming its private handle type.
data SomeHostWallBackend
  = forall handle. SomeHostWallBackend (HostWallBackend handle)

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
  | HostWallNativeFailure String Word32
  | HostWallConfigurationFailure ConfigBytesError
  | HostWallJournalFailure String
  | HostWallModelFailure WallModelError
  | HostWallConflict WallConflict
  | HostWallNoActiveRecord
  deriving (Eq, Show)

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

data OpenLayoutApply handle = OpenLayoutApply
  { layoutApplyTarget :: Maybe (WallObject handle),
    layoutApplyStage :: Maybe (WallObject handle),
    layoutApplyRetained :: Maybe (WallObject handle)
  }

data OpenLayoutRestore handle = OpenLayoutRestore
  { layoutRestoreTarget :: Maybe (WallObject handle),
    layoutRestoreRetained :: Maybe (WallObject handle),
    layoutRestoreRetired :: Maybe (WallObject handle)
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
  HostWallBackend handle ->
  CurrentUserWallRequest ->
  IO (Either HostWallError AppliedWslConfigFile)
applyGlobalWall backend request =
  wallWithExclusiveEntry backend $ do
    targetResult <- wallTargetPath backend
    case targetResult of
      Left err -> pure (Left err)
      Right target -> do
        activeResult <- loadActiveRecord backend
        case activeResult of
          Left err -> pure (Left err)
          Right Nothing -> do
            fenceResult <- wallJournalAllocateFence backend
            case fenceResult of
              Left err -> pure (Left err)
              Right fenceValue -> do
                prepared <-
                  prepareFreshReceipt backend request target fenceValue
                case prepared of
                  Left err -> pure (Left err)
                  Right (SomeWallReceipt claimed) ->
                    fmap AppliedWslConfigFile
                      <$> driveApply backend target claimed
          Right (Just active) ->
            resumeReceipt backend request active $ \receipt ->
              fmap AppliedWslConfigFile
                <$> driveApply backend target receipt

restoreGlobalWall ::
  HostWallBackend handle ->
  CurrentUserWallRequest ->
  IO (Either HostWallError ())
restoreGlobalWall backend request =
  wallWithExclusiveEntry backend $ do
    targetResult <- wallTargetPath backend
    case targetResult of
      Left err -> pure (Left err)
      Right target -> do
        activeResult <- loadActiveRecord backend
        case activeResult of
          Left err -> pure (Left err)
          Right Nothing -> pure (Left HostWallNoActiveRecord)
          Right (Just active) ->
            resumeReceipt backend request active (driveRestore backend target)

prepareFreshReceipt ::
  HostWallBackend handle ->
  CurrentUserWallRequest ->
  FilePath ->
  Word64 ->
  IO (Either HostWallError SomeWallReceipt)
prepareFreshReceipt backend request target fenceValue =
  withOpenPath backend target $ \targetFile -> do
    let origin =
          case targetFile of
            Nothing -> OriginalAbsent
            Just file ->
              OriginalPresent
                (wallObjectIdentity file)
                (wallObjectBytes file)
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
                  originStored <- storeReceipt backend withOrigin
                  pure
                    ( originStored
                        >> Right (SomeWallReceipt withOrigin)
                    )

resumeReceipt ::
  HostWallBackend handle ->
  CurrentUserWallRequest ->
  PersistedWallRecord ->
  ( forall ownerId wallSpecId reservationId receiptId fenceId.
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either HostWallError result)
  ) ->
  IO (Either HostWallError result)
resumeReceipt _ request active consume =
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
  HostWallBackend handle ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError PersistedWallRecord)
driveApply backend target = go (0 :: Int)
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
                          stored <- storeReceipt backend creating
                          case stored of
                            Left err -> pure (Left err)
                            Right () -> go (steps + 1) creating
                WallStageCreateOutcomeUnknown ->
                  driveStage backend steps go target receipt
                WallStageBound ->
                  driveStage backend steps go target receipt
                WallApplyOutcomeUnknown ->
                  driveApplying backend steps go target receipt
                WallApplied ->
                  withApplyLayout backend target active $ \layout ->
                    case
                      settleWallApply
                        active
                        receipt
                        (applyObservation layout)
                      of
                      Left err -> pure (Left (fromModelError err))
                      Right applied -> do
                        stored <- storeReceipt backend applied
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
  HostWallBackend handle ->
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either HostWallError PersistedWallRecord)
  ) ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError PersistedWallRecord)
driveStage backend steps continueApply target receipt =
  case checkedStagePaths target active of
    Left err -> pure (Left err)
    Right (boundPath, armedPath) -> do
      classificationResult <-
        withOpenPath backend boundPath $ \boundFile ->
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
            backend
            steps
            continueApply
            target
            armedPath
            receipt
        Right StageCreateRetry ->
          recoverMissingBound
            backend
            steps
            continueApply
            boundPath
            armedPath
            receipt
  where
    active = wallReceiptRecord receipt

recoverMissingBound ::
  HostWallBackend handle ->
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either HostWallError PersistedWallRecord)
  ) ->
  FilePath ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError PersistedWallRecord)
recoverMissingBound backend steps continueApply boundPath armedPath receipt =
  do
    recovered <-
      withOpenPath backend armedPath $ \armedFile ->
        case armedFile of
          Just file ->
            fmap (True <$)
              ( recoverDurablyBoundArmed
                  backend
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
          backend
          steps
          continueApply
          boundPath
          armedPath
          receipt

{- | Recover an armed object that is still present while the durable stage name
is not.

In @WallStageCreateOutcomeUnknown@ the identity of the armed object was never
journalled, so it cannot be checked against the receipt.  A backend whose armed
link dies with its creator therefore proves the object is foreign and refuses.
A backend whose armed link is durable proves nothing of the sort: the armed
name embeds this receipt's never-reused fence, so the leftover is this owner's
own interrupted attempt.  It is removed by exact identity under the same
exclusive lock and the create is retried, which never publishes its bytes.
-}
recoverDurablyBoundArmed ::
  HostWallBackend handle ->
  FilePath ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  WallObject handle ->
  IO (Either HostWallError ())
recoverDurablyBoundArmed backend boundPath armedPath receipt armedFile =
  case persistedWallPhase active of
    WallStageCreateOutcomeUnknown
      | wallArmedStageIsVolatile backend ->
          pure
            ( Left
                (HostWallConflict (UnboundStagePresent (wallObjectIdentity armedFile)))
            )
      | otherwise -> do
          deleted <- wallDeleteObject backend armedFile
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
              backend
              armedFile
              armedPath
              boundPath
          case linkResult of
            Left err -> pure (Left err)
            Right () -> wallDeleteObject backend armedFile
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
  HostWallBackend handle ->
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either HostWallError PersistedWallRecord)
  ) ->
  FilePath ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError PersistedWallRecord)
createBindAndLink backend steps continueApply boundPath armedPath receipt =
  mask $ \restore -> do
    createdResult <-
      createArmedStage backend armedPath (persistedDesiredBytes active)
    case createdResult of
      Left err -> pure (Left err)
      Right armedFile -> do
        operation <-
          restore (bindAndLink armedFile)
            `onException` void (wallCloseObject backend armedFile)
        closeResult <- wallCloseObject backend armedFile
        case (operation, closeResult) of
          (Left err, _) -> pure (Left err)
          (Right _, Left err) -> pure (Left err)
          (Right boundReceipt, Right ()) ->
            continueApply (steps + 1) boundReceipt
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
              stored <- storeReceipt backend boundReceipt
              case stored of
                Left err -> pure (Left err)
                Right () -> do
                  linked <-
                    linkArmedStage
                      backend
                      armedFile
                      armedPath
                      boundPath
                  case linked of
                    Left err -> pure (Left err)
                    Right () ->
                      pure (Right boundReceipt)

recoverObservedBound ::
  HostWallBackend handle ->
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either HostWallError PersistedWallRecord)
  ) ->
  FilePath ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError PersistedWallRecord)
recoverObservedBound backend steps continueApply target armedPath receipt =
  do
    cleanupResult <-
      withOpenPath backend armedPath $ \armedFile ->
        case armedFile of
          Nothing -> pure (Right ())
          Just file
            | fileObservation (Just file) == expectedStagedObservation active ->
                wallDeleteObject backend file
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
      withApplyLayout backend target active $ \layout ->
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
                stored <- storeReceipt backend applying
                pure (stored >> Right applying)

driveApplying ::
  HostWallBackend handle ->
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either HostWallError PersistedWallRecord)
  ) ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError PersistedWallRecord)
driveApplying backend steps continueApply target receipt =
  do
    recoveryStep <-
      withApplyLayout backend target active $ \layout ->
        case classifyWallApply receipt (applyObservation layout) of
          ApplyObservedDesired ->
            case settleWallApply active receipt (applyObservation layout) of
              Left err -> pure (Left (fromModelError err))
              Right applied -> do
                stored <- storeReceipt backend applied
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
          renamed <- renameOpenFile backend stage target
          pure (renamed >> Right ApplyRecoveryContinue)
    retainOrigin layout =
      case layoutApplyTarget layout of
        Nothing ->
          pure
            (Left (HostWallJournalFailure "origin vanished before retention"))
        Just origin -> do
          renamed <- renameOpenFile backend origin (retainedPath target active)
          pure (renamed >> Right ApplyRecoveryContinue)

driveRestore ::
  HostWallBackend handle ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError ())
driveRestore backend target = go (0 :: Int)
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
                      withRestoreLayout backend target active $ \layout ->
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
                              stored <- storeReceipt backend restoring
                              pure (stored >> Right restoring)
                    case beginResult of
                      Left err -> pure (Left err)
                      Right restoring -> go (steps + 1) restoring
                WallRestoreOutcomeUnknown ->
                  driveRestoring backend steps go target receipt
                WallRestored ->
                  withRestoreLayout backend target active $ \layout ->
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
                          stored <- storeReceipt backend released
                          case stored of
                            Left err -> pure (Left err)
                            Right () -> clearReleased backend released
                WallReleased ->
                  withRestoreLayout backend target active $ \layout ->
                    case
                      verifyWallReleased
                        active
                        receipt
                        (restoreObservation layout)
                      of
                      Left err -> pure (Left (fromModelError err))
                      Right () -> clearReleased backend receipt
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
  HostWallBackend handle ->
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either HostWallError ())
  ) ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError ())
driveRestoring backend steps continueRestore target receipt =
  do
    recoveryStep <-
      withRestoreLayout backend target active $ \layout ->
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
                  stored <- storeReceipt backend restored
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
          deleted <- wallDeleteObject backend managed
          pure (deleted >> Right RestoreRecoverySame)
    retireManagedTarget layout =
      case layoutRestoreTarget layout of
        Nothing ->
          pure
            (Left (HostWallJournalFailure "managed target vanished before retirement"))
        Just managed -> do
          renamed <- renameOpenFile backend managed (retiredPath target active)
          pure (renamed >> Right RestoreRecoverySame)
    publishOrigin layout =
      case layoutRestoreRetained layout of
        Nothing ->
          pure
            (Left (HostWallJournalFailure "retained origin vanished before publication"))
        Just origin -> do
          renamed <- renameOpenFile backend origin target
          pure (renamed >> Right RestoreRecoverySame)
    deleteRetiredManaged layout =
      case layoutRestoreRetired layout of
        Nothing ->
          pure
            (Left (HostWallJournalFailure "retired managed object vanished before delete"))
        Just managed -> do
          deleted <- wallDeleteObject backend managed
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
  HostWallBackend handle ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError ())
clearReleased backend receipt = do
  cleared <- deleteActiveIfEqual backend (wallReceiptRecord receipt)
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
  HostWallBackend handle ->
  FilePath ->
  PersistedWallRecord ->
  (OpenLayoutApply handle -> IO (Either HostWallError result)) ->
  IO (Either HostWallError result)
withApplyLayout backend target record consume =
  case checkedStagePaths target record of
    Left err -> pure (Left err)
    Right (stage, _) ->
      withOpenPath backend target $ \targetFile -> do
        stageResult <-
          withOpenPath backend stage $ \stageFile -> do
            let retained = retainedPath target record
            retainedResult <-
              withOpenPath backend retained $ \retainedFile ->
                consume
                  OpenLayoutApply
                    { layoutApplyTarget = targetFile,
                      layoutApplyStage = stageFile,
                      layoutApplyRetained = retainedFile
                    }
            resolveSharingFailure
              backend
              [targetFile, stageFile]
              retained
              retainedResult
        resolveSharingFailure backend [targetFile] stage stageResult

withRestoreLayout ::
  HostWallBackend handle ->
  FilePath ->
  PersistedWallRecord ->
  (OpenLayoutRestore handle -> IO (Either HostWallError result)) ->
  IO (Either HostWallError result)
withRestoreLayout backend target record consume =
  withOpenPath backend target $ \targetFile -> do
    let retained = retainedPath target record
        retired = retiredPath target record
    retainedResult <-
      withOpenPath backend retained $ \retainedFile -> do
        retiredResult <-
          withOpenPath backend retired $ \retiredFile ->
            consume
              OpenLayoutRestore
                { layoutRestoreTarget = targetFile,
                  layoutRestoreRetained = retainedFile,
                  layoutRestoreRetired = retiredFile
                }
        resolveSharingFailure
          backend
          [targetFile, retainedFile]
          retired
          retiredResult
    resolveSharingFailure backend [targetFile] retained retainedResult

-- | Re-observe the path with a zero-access metadata probe before classifying a
-- sharing violation.  Opening several recovery names exclusively can fail
-- because two names are links to the same already-open object.  It can also
-- fail because an unrelated process holds an unrelated file.  Assigning the
-- first prior identity to every such failure would invent identity evidence; a
-- matching probe proves the alias, while every non-matching or unstable layout
-- remains a non-mutating Busy refusal.
resolveSharingFailure ::
  HostWallBackend handle ->
  [Maybe (WallObject handle)] ->
  FilePath ->
  Either HostWallError result ->
  IO (Either HostWallError result)
resolveSharingFailure backend prior path result =
  case result of
    Left (HostWallNativeFailure _ status)
      | wallIsSharingFailure backend status -> do
          probed <- wallProbeIdentity backend path
          pure $
            case probed of
              Right (Just observed)
                | observed `elem` map wallObjectIdentity [file | Just file <- prior] ->
                    Left
                      ( HostWallConflict
                          (ConflictingWallPathShare observed)
                      )
              _ ->
                Left
                  ( HostWallBusy
                      ( "could not exclusively observe "
                          ++ path
                          ++ " because another handle is active"
                      )
                  )
    _ -> pure result

applyObservation :: OpenLayoutApply handle -> ApplyObservation
applyObservation layout =
  ApplyObservation
    { applyTargetObservation = fileObservation (layoutApplyTarget layout),
      applyStagedObservation = fileObservation (layoutApplyStage layout),
      applyRetainedOriginObservation =
        fileObservation (layoutApplyRetained layout)
    }

restoreObservation :: OpenLayoutRestore handle -> RestoreObservation
restoreObservation layout =
  RestoreObservation
    { restoreTargetObservation = fileObservation (layoutRestoreTarget layout),
      restoreRetainedOriginObservation =
        fileObservation (layoutRestoreRetained layout),
      restoreRetiredManagedObservation =
        fileObservation (layoutRestoreRetired layout)
    }

fileObservation :: Maybe (WallObject handle) -> WallObservation
fileObservation Nothing = ObservedAbsent
fileObservation (Just file) =
  ObservedPresent (wallObjectIdentity file) (wallObjectBytes file)

expectedStagedObservation :: PersistedWallRecord -> WallObservation
expectedStagedObservation record =
  case persistedTargetIdentity record of
    Nothing -> ObservedAbsent
    Just identity -> ObservedPresent identity (persistedDesiredBytes record)

observesExactOrigin :: WslConfigOrigin -> Maybe (WallObject handle) -> Bool
observesExactOrigin OriginalAbsent Nothing = True
observesExactOrigin (OriginalPresent identity bytes) (Just file) =
  identity == wallObjectIdentity file && bytes == wallObjectBytes file
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
  FileIdentity ->
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

identityVolume :: FileIdentity -> ByteString
identityVolume = ByteString.take 8 . fileIdentityBytes

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

withOpenPath ::
  HostWallBackend handle ->
  FilePath ->
  (Maybe (WallObject handle) -> IO (Either HostWallError result)) ->
  IO (Either HostWallError result)
withOpenPath backend path consume =
  mask $ \restore -> do
    opened <- wallOpenExclusive backend path
    case opened of
      Left err -> pure (Left err)
      Right Nothing -> restore (consume Nothing)
      Right (Just file) -> do
        result <-
          restore (consume (Just file))
            `onException` void (wallCloseObject backend file)
        closed <- wallCloseObject backend file
        pure $
          case (result, closed) of
            (Left err, _) -> Left err
            (Right _, Left err) -> Left err
            (Right value, Right ()) -> Right value

createArmedStage ::
  HostWallBackend handle ->
  FilePath ->
  ByteString ->
  IO (Either HostWallError (WallObject handle))
createArmedStage backend path bytes = do
  created <- wallCreateArmedStage backend path bytes
  case created of
    Right object -> pure (Right object)
    Left err@(HostWallNativeFailure _ status) ->
      classifyPrivatePathRace backend "create armed stage" path status err
    Left err -> pure (Left err)

linkArmedStage ::
  HostWallBackend handle ->
  WallObject handle ->
  FilePath ->
  FilePath ->
  IO (Either HostWallError ())
linkArmedStage backend file armed bound = do
  linked <- wallLinkArmedStage backend file armed bound
  case linked of
    Right () -> pure (Right ())
    Left err@(HostWallNativeFailure _ status)
      | wallIsHardLinkUnsupported backend status ->
          pure
            ( Left
                ( HostWallUnsupported
                    ( "hard-link stage handoff is unavailable (native status "
                        ++ show status
                        ++ ")"
                    )
                )
            )
      | otherwise -> do
          observed <- wallProbeIdentity backend bound
          pure $
            case observed of
              Right (Just identity)
                | identity == wallObjectIdentity file -> Right ()
                | otherwise ->
                    Left
                      ( HostWallConflict
                          (UnboundStagePresent identity)
                      )
              Right Nothing
                | wallIsRaceFailure backend status ->
                    Left
                      ( HostWallBusy
                          "the durable stage destination changed during hard-link publication"
                      )
              Left probeError
                | wallIsRaceFailure backend status ->
                    Left
                      ( HostWallBusy
                          ( "the durable stage destination could not be safely reprobed: "
                              ++ show probeError
                          )
                      )
              _ -> Left err
    Left err -> pure (Left err)

renameOpenFile ::
  HostWallBackend handle ->
  WallObject handle ->
  FilePath ->
  IO (Either HostWallError ())
renameOpenFile backend file destination = do
  renamed <- wallRenameNoReplace backend file destination
  case renamed of
    Right () -> pure (Right ())
    Left err@(HostWallNativeFailure _ status) -> do
      -- No-replace moves do not report destination collisions consistently
      -- across supported platform/filesystem combinations.  Reprobe the
      -- destination for identity evidence instead of guessing from one
      -- numeric status.
      observed <- wallProbeIdentity backend destination
      pure $
        case observed of
          Right (Just identity) ->
            Left
              ( HostWallConflict
                  (UnexpectedTargetPresent identity)
              )
          Right Nothing
            | wallIsRaceFailure backend status ->
                Left
                  ( HostWallBusy
                      ( "the no-replace rename destination changed while reprobed: "
                          ++ destination
                      )
                  )
          Left probeError
            | wallIsRaceFailure backend status ->
                Left
                  ( HostWallBusy
                      ( "the no-replace rename destination could not be safely reprobed: "
                          ++ show probeError
                      )
                  )
          _ -> Left err
    Left err -> pure (Left err)

loadActiveRecord ::
  HostWallBackend handle ->
  IO (Either HostWallError (Maybe PersistedWallRecord))
loadActiveRecord backend = do
  loaded <- wallJournalLoad backend
  pure $
    case loaded of
      Left err -> Left err
      Right Nothing -> Right Nothing
      Right (Just bytes) -> Just <$> decodeWallRecord bytes

storeReceipt ::
  HostWallBackend handle ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either HostWallError ())
storeReceipt backend = storeRecord backend . wallReceiptRecord

storeRecord ::
  HostWallBackend handle ->
  PersistedWallRecord ->
  IO (Either HostWallError ())
storeRecord backend record =
  let bytes = encodeWallRecord record
   in if ByteString.length bytes > maximumWallBytes
        then
          pure
            ( Left
                ( HostWallUnsupported
                    "encoded active wall record exceeds the 16 MiB recoverable limit"
                )
            )
        else wallJournalStore backend bytes

deleteActiveIfEqual ::
  HostWallBackend handle ->
  PersistedWallRecord ->
  IO (Either HostWallError Bool)
deleteActiveIfEqual backend record =
  wallJournalDeleteIfEqual backend (encodeWallRecord record)

-- | Conservatively classify a failed create-exclusive operation.  A present
-- object is exact identity evidence of an unowned private-stage collision.  If
-- a known collision/contention status races with disappearance or prevents a
-- safe probe, callers may retry later but may not adopt or overwrite anything.
classifyPrivatePathRace ::
  HostWallBackend handle ->
  String ->
  FilePath ->
  Word32 ->
  HostWallError ->
  IO (Either HostWallError result)
classifyPrivatePathRace backend operation path status fallback = do
  observed <- wallProbeIdentity backend path
  pure $
    case observed of
      Right (Just identity) ->
        Left
          ( HostWallConflict
              (UnboundStagePresent identity)
          )
      Right Nothing
        | wallIsRaceFailure backend status ->
            Left
              ( HostWallBusy
                  (operation ++ " raced with a changing destination at " ++ path)
              )
      Left probeError
        | wallIsRaceFailure backend status ->
            Left
              ( HostWallBusy
                  ( operation
                      ++ " could not safely re-observe its destination: "
                      ++ show probeError
                  )
              )
      _ -> Left fallback

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

putMaybeIdentity :: Maybe FileIdentity -> Builder.Builder
putMaybeIdentity Nothing = Builder.word8 0
putMaybeIdentity (Just identity) =
  Builder.word8 1 <> putSized (fileIdentityBytes identity)

putOrigin :: Maybe WslConfigOrigin -> Builder.Builder
putOrigin Nothing = Builder.word8 0
putOrigin (Just OriginalAbsent) = Builder.word8 1
putOrigin (Just (OriginalPresent identity bytes)) =
  Builder.word8 2
    <> putSized (fileIdentityBytes identity)
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

getMaybeIdentity :: Decoder (Maybe FileIdentity)
getMaybeIdentity = do
  tag <- getWord8
  case tag of
    0 -> pure Nothing
    1 -> Just <$> getIdentity
    _ -> decoderFailure "active wall record has an unknown optional-identity tag"

-- | Kernel identity evidence is a bounded opaque byte string: 16 bytes of
-- @device:inode@ on POSIX and 24 bytes of @FILE_ID_INFO@ on Windows. The codec
-- bounds it rather than fixing one platform's width.
getIdentity :: Decoder FileIdentity
getIdentity = do
  bytes <- getSized
  if ByteString.length bytes < 8 || ByteString.length bytes > 64
    then
      decoderFailure
        "kernel identity evidence must be between 8 and 64 bytes"
    else case mkFileIdentity bytes of
      Left err -> decoderFailure (show err)
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
