{-# LANGUAGE CPP #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Windows adapter for the per-user WSL global wall.

The production entry points deliberately accept no pathname. The target is
always derived from @FOLDERID_Profile@ and the literal @.wslconfig@ by the
native shim. All namespace changes and conditional deletions operate through a
previously identity-verified handle.

Staging uses two links. The first is created with delete-on-close and cannot
survive an ordinary process death. Its 128-bit FILE_ID plus volume serial is
flushed to the protected HKCU journal before a no-replace hard link is created
at the durable stage name. Closing the armed handle removes only its first
link. This removes the otherwise unavoidable gap between @CREATE_NEW@ and
durably learning the new file identity.
-}
module HostBootstrap.Wsl2.GlobalWall.Windows
  ( CurrentUserWallRequest,
    mkCurrentUserWallRequest,
    AppliedWslConfigFile,
    appliedWslConfigRecord,
    WindowsWallError (..),
    windowsGlobalWallSupported,
    applyCurrentUserGlobalWall,
    restoreCurrentUserGlobalWall,
  )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Word (Word32)
import HostBootstrap.Wsl2.GlobalWall
import HostBootstrap.Wsl2.GlobalWall.ConfigBytes

#if defined(mingw32_HOST_OS)
import Control.Concurrent (runInBoundThread)
import Control.Exception (bracket, mask, onException)
import Control.Monad (void)
import Data.Bits ((.|.), shiftL)
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Foreign.C.String (peekCWString, withCWString)
import Foreign.C.Types (CInt (..), CSize (..), CWchar)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek)
import Data.Word (Word8, Word64)
#endif

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

data WindowsWallError
  = WindowsWallUnsupported String
  | WindowsWallBusy String
  | WindowsWallNativeFailure String Word32
  | WindowsWallConfigurationFailure ConfigBytesError
  | WindowsWallJournalFailure String
  | WindowsWallModelFailure WallModelError
  | WindowsWallConflict WallConflict
  | WindowsWallNoActiveRecord
  deriving (Eq, Show)

-- | File-scoped proof that the exact managed object and bytes are currently at
-- @.wslconfig@. This does /not/ claim that the WSL runtime has shut down,
-- reloaded the file, or made CPU/memory/swap settings effective.
newtype AppliedWslConfigFile = AppliedWslConfigFile PersistedWallRecord
  deriving (Eq, Show)

appliedWslConfigRecord :: AppliedWslConfigFile -> PersistedWallRecord
appliedWslConfigRecord (AppliedWslConfigFile record) = record

-- | Construct a pathname-free request and reject identities that the pure
-- wall model cannot admit. The native shim applies a 16 MiB defensive bound to
-- both Registry records and @.wslconfig@ bytes.
mkCurrentUserWallRequest ::
  ByteString ->
  ByteString ->
  ByteString ->
  ByteString ->
  [ByteString] ->
  Either WindowsWallError CurrentUserWallRequest
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
        ( WindowsWallUnsupported
            "a wall identity exceeds the 16 MiB Registry-field limit"
        )
  | sum (map ByteString.length managedBody) > maximumWallBytes =
      Left
        ( WindowsWallUnsupported
            "the managed .wslconfig body exceeds the 16 MiB adapter limit"
        )
  | otherwise = do
      managedSpec <-
        either
          (Left . WindowsWallConfigurationFailure)
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
    invalid = Left . WindowsWallModelFailure . InvalidWallIdentity

maximumWallBytes :: Int
maximumWallBytes = 16 * 1024 * 1024

#if !defined(mingw32_HOST_OS)

windowsGlobalWallSupported :: Bool
windowsGlobalWallSupported = False

applyCurrentUserGlobalWall ::
  CurrentUserWallRequest ->
  IO (Either WindowsWallError AppliedWslConfigFile)
applyCurrentUserGlobalWall _ =
  pure
    ( Left
        (WindowsWallUnsupported "the WSL global wall requires Windows")
    )

restoreCurrentUserGlobalWall ::
  CurrentUserWallRequest ->
  IO (Either WindowsWallError ())
restoreCurrentUserGlobalWall _ =
  pure
    ( Left
        (WindowsWallUnsupported "the WSL global wall requires Windows")
    )

#else

windowsGlobalWallSupported :: Bool
windowsGlobalWallSupported = True

foreign import ccall safe "hb_wsl_get_target_path"
  cGetTargetPath :: Ptr (Ptr CWchar) -> IO Word32

foreign import ccall unsafe "hb_wsl_free"
  cFree :: Ptr value -> IO ()

foreign import ccall safe "hb_wsl_mutex_acquire"
  cMutexAcquire :: Ptr (Ptr ()) -> Ptr CInt -> IO Word32

foreign import ccall safe "hb_wsl_mutex_release"
  cMutexRelease :: Ptr () -> IO Word32

foreign import ccall safe "hb_wsl_open_exclusive"
  cOpenExclusive ::
    Ptr CWchar ->
    Ptr (Ptr ()) ->
    Ptr Word8 ->
    Ptr (Ptr Word8) ->
    Ptr CSize ->
    Ptr CInt ->
    IO Word32

foreign import ccall safe "hb_wsl_probe_identity"
  cProbeIdentity ::
    Ptr CWchar ->
    Ptr Word8 ->
    Ptr CInt ->
    IO Word32

foreign import ccall safe "hb_wsl_create_stage"
  cCreateStage ::
    Ptr CWchar ->
    Ptr Word8 ->
    CSize ->
    Ptr (Ptr ()) ->
    Ptr Word8 ->
    IO Word32

foreign import ccall safe "hb_wsl_link_armed_stage"
  cLinkArmedStage ::
    Ptr () ->
    Ptr CWchar ->
    Ptr CWchar ->
    IO Word32

foreign import ccall safe "hb_wsl_rename_handle_noreplace"
  cRenameHandleNoReplace :: Ptr () -> Ptr CWchar -> IO Word32

foreign import ccall safe "hb_wsl_delete_handle"
  cDeleteHandle :: Ptr () -> IO Word32

foreign import ccall safe "hb_wsl_close_handle"
  cCloseHandle :: Ptr () -> IO Word32

foreign import ccall safe "hb_wsl_registry_load_active"
  cRegistryLoadActive ::
    Ptr (Ptr Word8) ->
    Ptr CSize ->
    Ptr CInt ->
    IO Word32

foreign import ccall safe "hb_wsl_registry_allocate_fence"
  cRegistryAllocateFence :: Ptr Word64 -> IO Word32

foreign import ccall safe "hb_wsl_registry_store_active"
  cRegistryStoreActive :: Ptr Word8 -> CSize -> IO Word32

foreign import ccall safe "hb_wsl_registry_delete_active_if_equal"
  cRegistryDeleteActiveIfEqual ::
    Ptr Word8 ->
    CSize ->
    Ptr CInt ->
    IO Word32

data OpenFile = OpenFile
  { openFileHandle :: Ptr (),
    openFileIdentity :: FileIdentity,
    openFileBytes :: ByteString
  }

data ApplyLayout = ApplyLayout
  { layoutApplyTarget :: Maybe OpenFile,
    layoutApplyStage :: Maybe OpenFile,
    layoutApplyRetained :: Maybe OpenFile
  }

data RestoreLayout = RestoreLayout
  { layoutRestoreTarget :: Maybe OpenFile,
    layoutRestoreRetained :: Maybe OpenFile,
    layoutRestoreRetired :: Maybe OpenFile
  }

data ApplyRecoveryStep
  = ApplyRecoveryContinue
  | ApplyRecoveryDone PersistedWallRecord

data RestoreRecoveryStep ownerId wallSpecId reservationId receiptId fenceId
  = RestoreRecoverySame
  | RestoreRecoveryWith
      (WallReceipt ownerId wallSpecId reservationId receiptId fenceId)

data SomeWallReceipt =
  forall ownerId wallSpecId reservationId receiptId fenceId.
  SomeWallReceipt
    (WallReceipt ownerId wallSpecId reservationId receiptId fenceId)

applyCurrentUserGlobalWall ::
  CurrentUserWallRequest ->
  IO (Either WindowsWallError AppliedWslConfigFile)
applyCurrentUserGlobalWall request =
  withGlobalMutex $ do
    targetResult <- getCurrentUserTarget
    case targetResult of
      Left err -> pure (Left err)
      Right target -> do
        activeResult <- loadActiveRecord
        case activeResult of
          Left err -> pure (Left err)
          Right Nothing -> do
            fenceResult <- allocateFence
            case fenceResult of
              Left err -> pure (Left err)
              Right fenceValue -> do
                prepared <-
                  prepareFreshReceipt request target fenceValue
                case prepared of
                  Left err -> pure (Left err)
                  Right (SomeWallReceipt claimed) ->
                    fmap AppliedWslConfigFile
                      <$> driveApply target claimed
          Right (Just active) ->
            resumeReceipt request active $ \receipt ->
              fmap AppliedWslConfigFile
                <$> driveApply target receipt

restoreCurrentUserGlobalWall ::
  CurrentUserWallRequest ->
  IO (Either WindowsWallError ())
restoreCurrentUserGlobalWall request =
  withGlobalMutex $ do
    targetResult <- getCurrentUserTarget
    case targetResult of
      Left err -> pure (Left err)
      Right target -> do
        activeResult <- loadActiveRecord
        case activeResult of
          Left err -> pure (Left err)
          Right Nothing -> pure (Left WindowsWallNoActiveRecord)
          Right (Just active) ->
            resumeReceipt request active (driveRestore target)

prepareFreshReceipt ::
  CurrentUserWallRequest ->
  FilePath ->
  Word64 ->
  IO (Either WindowsWallError SomeWallReceipt)
prepareFreshReceipt request target fenceValue =
  withOpenPath target $ \targetFile -> do
    let origin =
          case targetFile of
            Nothing -> OriginalAbsent
            Just file ->
              OriginalPresent
                (openFileIdentity file)
                (openFileBytes file)
    case desiredFromOrigin request origin of
      Left err -> pure (Left err)
      Right desired ->
        withRequestReservation request desired fenceValue $ \reservation ->
          case claimOrResumeWall reservation Nothing of
            Left err -> pure (Left (fromModelError err))
            Right claimed -> do
              case
                  recordWallOrigin
                    (wallReceiptRecord claimed)
                    claimed
                    origin
                of
                  Left err -> pure (Left (fromModelError err))
                  Right withOrigin -> do
                    originStored <- storeReceipt withOrigin
                    pure
                      ( originStored
                          >> Right (SomeWallReceipt withOrigin)
                      )

resumeReceipt ::
  CurrentUserWallRequest ->
  PersistedWallRecord ->
  ( forall ownerId wallSpecId reservationId receiptId fenceId.
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either WindowsWallError result)
  ) ->
  IO (Either WindowsWallError result)
resumeReceipt request active consume = do
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
  Either WindowsWallError ()
precheckActiveRequest request active
  | requestOwnerIdentity request /= persistedOwnerIdentity active =
      Left
        ( WindowsWallConflict
            ( ForeignWallOwner
                (requestOwnerIdentity request)
                (persistedOwnerIdentity active)
            )
        )
  | effectiveSpecIdentity request /= persistedSpecIdentity active =
      Left
        ( WindowsWallConflict
            ( IncompatibleWallSpec
                (effectiveSpecIdentity request)
                (persistedSpecIdentity active)
            )
        )
  | otherwise = Right ()

withGlobalMutex ::
  IO (Either WindowsWallError result) ->
  IO (Either WindowsWallError result)
withGlobalMutex action =
  -- A Win32 mutex belongs to the OS thread that successfully waited for it,
  -- not merely to the process or the numeric HANDLE.  A normal lightweight
  -- Haskell thread may migrate between capabilities around a safe FFI call.
  -- Keep acquisition, the complete protected action, exception cleanup, and
  -- normal release inside one bound Haskell thread so ReleaseMutex always
  -- executes on the acquiring OS thread.
  runInBoundThread $
    mask $ \restore ->
      alloca $ \mutexPointer ->
        alloca $ \abandonedPointer -> do
          status <- cMutexAcquire mutexPointer abandonedPointer
          if status /= 0
            then
              pure
                ( Left
                    ( if status == errorBusy
                        then
                          WindowsWallBusy
                            "the per-user WSL global-wall mutex was not acquired within 30 seconds"
                        else
                          nativeFailure
                            "acquire the per-user global mutex"
                            status
                    )
                )
            else do
              mutex <- peek mutexPointer
              _ <- peek abandonedPointer
              result <-
                restore action
                  `onException` void (cMutexRelease mutex)
              releaseStatus <- cMutexRelease mutex
              pure $
                if releaseStatus /= 0
                  then
                    case result of
                      Left err -> Left err
                      Right _ ->
                        Left
                          (nativeFailure "release the per-user global mutex" releaseStatus)
                  else result

getCurrentUserTarget :: IO (Either WindowsWallError FilePath)
getCurrentUserTarget =
  mask $ \_ ->
    alloca $ \pathPointer -> do
      status <- cGetTargetPath pathPointer
      if status /= 0
        then pure (Left (nativeFailure "derive FOLDERID_Profile\\.wslconfig" status))
        else do
          path <- peek pathPointer
          if path == nullPtr
            then
              pure
                ( Left
                    (nativeFailure "derive FOLDERID_Profile\\.wslconfig" errorInvalidData)
                )
            else
              bracket
                (pure path)
                cFree
                (fmap Right . peekCWString)

withRequestReservation ::
  CurrentUserWallRequest ->
  ByteString ->
  Word64 ->
  ( forall ownerId wallSpecId reservationId receiptId fenceId.
    WallReservation ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either WindowsWallError result)
  ) ->
  IO (Either WindowsWallError result)
withRequestReservation request desired fenceValue consume =
  case
      joinModel
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
        )
    of
    Left err -> pure (Left (fromModelError err))
    Right operation -> operation

desiredForActive ::
  CurrentUserWallRequest ->
  PersistedWallRecord ->
  Either WindowsWallError ByteString
desiredForActive request active =
  case persistedWallOrigin active of
    Nothing ->
      Left
        ( WindowsWallJournalFailure
            "an active Windows wall has no durable origin"
        )
    Just origin -> do
      expected <- desiredFromOrigin request origin
      if expected == persistedDesiredBytes active
        then Right (persistedDesiredBytes active)
        else
          Left
            ( WindowsWallJournalFailure
                "managed spec does not reproduce the desired bytes from the durable origin"
            )

desiredFromOrigin ::
  CurrentUserWallRequest ->
  WslConfigOrigin ->
  Either WindowsWallError ByteString
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
        ( WindowsWallUnsupported
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
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either WindowsWallError PersistedWallRecord)
driveApply target = go (0 :: Int)
  where
    go steps receipt
      | steps > 24 =
          pure
            ( Left
                (WindowsWallJournalFailure "apply recovery exceeded its phase bound")
            )
      | otherwise =
          let active = wallReceiptRecord receipt
           in case persistedWallPhase active of
                WallClaimed ->
                  pure
                    ( Left
                        ( WindowsWallJournalFailure
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
                          stored <- storeReceipt creating
                          case stored of
                            Left err -> pure (Left err)
                            Right () -> go (steps + 1) creating
                WallStageCreateOutcomeUnknown ->
                  driveStage steps go target receipt
                WallStageBound ->
                  driveStage steps go target receipt
                WallApplyOutcomeUnknown ->
                  driveApplying steps go target receipt
                WallApplied ->
                  withApplyLayout target active $ \layout ->
                    case
                        settleWallApply
                          active
                          receipt
                          (applyObservation layout)
                      of
                        Left err -> pure (Left (fromModelError err))
                        Right applied -> do
                          stored <- storeReceipt applied
                          pure (stored >> Right (wallReceiptRecord applied))
                phase ->
                  pure
                    ( Left
                        ( WindowsWallModelFailure
                            ( IllegalWallTransition
                                phase
                                "apply cannot take over a wall already in teardown"
                            )
                        )
                    )

driveStage ::
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either WindowsWallError PersistedWallRecord)
  ) ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either WindowsWallError PersistedWallRecord)
driveStage steps continueApply target receipt =
  case checkedStagePaths target active of
    Left err -> pure (Left err)
    Right (boundPath, armedPath) -> do
      classificationResult <-
        withOpenPath boundPath $ \boundFile ->
          pure
            (Right (classifyWallStageCreation receipt (fileObservation boundFile)))
      case classificationResult of
        Left err -> pure (Left err)
        Right (StageCreateBlocked conflict) ->
          pure (Left (WindowsWallConflict conflict))
        Right (StageCreateNotInProgress phase) ->
          pure
            ( Left
                ( WindowsWallModelFailure
                    ( IllegalWallTransition
                        phase
                        "stage recovery was requested outside a stage phase"
                    )
                )
            )
        Right StageCreateObservedBound ->
          recoverObservedBound
            steps
            continueApply
            target
            armedPath
            receipt
        Right StageCreateRetry ->
          recoverMissingBound
            steps
            continueApply
            boundPath
            armedPath
            receipt
  where
    active = wallReceiptRecord receipt

recoverMissingBound ::
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either WindowsWallError PersistedWallRecord)
  ) ->
  FilePath ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either WindowsWallError PersistedWallRecord)
recoverMissingBound steps continueApply boundPath armedPath receipt =
  do
    recovered <-
      withOpenPath armedPath $ \armedFile ->
        case armedFile of
          Just file ->
            fmap (True <$)
              ( recoverDurablyBoundArmed
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
          steps
          continueApply
          boundPath
          armedPath
          receipt

recoverDurablyBoundArmed ::
  FilePath ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  OpenFile ->
  IO (Either WindowsWallError ())
recoverDurablyBoundArmed boundPath armedPath receipt armedFile =
  case persistedWallPhase active of
    WallStageCreateOutcomeUnknown ->
      pure
        ( Left
            (WindowsWallConflict (UnboundStagePresent (openFileIdentity armedFile)))
        )
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
              armedFile
              armedPath
              boundPath
          case linkResult of
            Left err -> pure (Left err)
            Right () -> do
              deleteOpenFile armedFile
    phase ->
      pure
        ( Left
            ( WindowsWallModelFailure
                (IllegalWallTransition phase "unexpected armed-stage recovery phase")
            )
        )
  where
    active = wallReceiptRecord receipt

createBindAndLink ::
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either WindowsWallError PersistedWallRecord)
  ) ->
  FilePath ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either WindowsWallError PersistedWallRecord)
createBindAndLink steps continueApply boundPath armedPath receipt =
  mask $ \restore -> do
    createdResult <-
      createArmedStage armedPath (persistedDesiredBytes active)
    case createdResult of
      Left err -> pure (Left err)
      Right armedFile -> do
        operation <-
          restore (bindAndLink armedFile)
            `onException` void (closeOpenFile armedFile)
        closeResult <- closeOpenFile armedFile
        case (operation, closeResult) of
          (Left err, _) -> pure (Left err)
          (Right _, Left err) -> pure (Left err)
          (Right boundReceipt, Right ()) ->
            continueApply (steps + 1) boundReceipt
  where
    active = wallReceiptRecord receipt
    bindAndLink armedFile =
      case validateStageVolume active (openFileIdentity armedFile) of
        Left err -> pure (Left err)
        Right () ->
          case
              bindWallStage
                active
                receipt
                ObservedAbsent
                (openFileIdentity armedFile)
            of
              Left err -> pure (Left (fromModelError err))
              Right boundReceipt -> do
                stored <- storeReceipt boundReceipt
                case stored of
                  Left err -> pure (Left err)
                  Right () -> do
                    linked <-
                      linkArmedStage
                        armedFile
                        armedPath
                        boundPath
                    case linked of
                      Left err -> pure (Left err)
                      Right () ->
                        pure (Right boundReceipt)

recoverObservedBound ::
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either WindowsWallError PersistedWallRecord)
  ) ->
  FilePath ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either WindowsWallError PersistedWallRecord)
recoverObservedBound steps continueApply target armedPath receipt =
  do
    cleanupResult <-
      withOpenPath armedPath $ \armedFile ->
        case armedFile of
          Nothing -> pure (Right ())
          Just file
            | fileObservation (Just file) == expectedStagedObservation active ->
                deleteOpenFile file
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
      withApplyLayout target active $ \layout ->
        case persistedTargetIdentity active of
          Nothing ->
            pure
              ( Left
                  (WindowsWallJournalFailure "bound stage has no FILE_ID")
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
                  stored <- storeReceipt applying
                  pure (stored >> Right applying)

driveApplying ::
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either WindowsWallError PersistedWallRecord)
  ) ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either WindowsWallError PersistedWallRecord)
driveApplying steps continueApply target receipt =
  do
    recoveryStep <-
      withApplyLayout target active $ \layout ->
        case classifyWallApply receipt (applyObservation layout) of
          ApplyObservedDesired ->
            case settleWallApply active receipt (applyObservation layout) of
              Left err -> pure (Left (fromModelError err))
              Right applied -> do
                stored <- storeReceipt applied
                pure
                  ( stored
                      >> Right
                        (ApplyRecoveryDone (wallReceiptRecord applied))
                  )
          ApplyRetryPublication ->
            case persistedWallOrigin active of
              Nothing ->
                pure
                  (Left (WindowsWallJournalFailure "applying record has no origin"))
              Just OriginalAbsent ->
                publishStage layout
              Just origin@(OriginalPresent _ _) ->
                if observesExactOrigin origin (layoutApplyTarget layout)
                  then retainOrigin layout
                  else publishStage layout
          ApplyBlocked conflict ->
            pure (Left (WindowsWallConflict conflict))
          classification ->
            pure
              ( Left
                  ( WindowsWallModelFailure
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
            (Left (WindowsWallJournalFailure "stage vanished before publication"))
        Just stage -> do
          renamed <- renameOpenFile stage target
          pure (renamed >> Right ApplyRecoveryContinue)
    retainOrigin layout =
      case layoutApplyTarget layout of
        Nothing ->
          pure
            (Left (WindowsWallJournalFailure "origin vanished before retention"))
        Just origin -> do
          renamed <- renameOpenFile origin (retainedPath target active)
          pure (renamed >> Right ApplyRecoveryContinue)

driveRestore ::
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either WindowsWallError ())
driveRestore target = go (0 :: Int)
  where
    go steps receipt
      | steps > 24 =
          pure
            ( Left
                (WindowsWallJournalFailure "restore recovery exceeded its phase bound")
            )
      | otherwise =
          let active = wallReceiptRecord receipt
           in case persistedWallPhase active of
                WallApplied ->
                  do
                    beginResult <-
                      withRestoreLayout target active $ \layout ->
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
                                stored <- storeReceipt restoring
                                pure (stored >> Right restoring)
                    case beginResult of
                      Left err -> pure (Left err)
                      Right restoring -> go (steps + 1) restoring
                WallRestoreOutcomeUnknown ->
                  driveRestoring steps go target receipt
                WallRestored ->
                  withRestoreLayout target active $ \layout ->
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
                            stored <- storeReceipt released
                            case stored of
                              Left err -> pure (Left err)
                              Right () -> clearReleased released
                WallReleased ->
                  withRestoreLayout target active $ \layout ->
                    case
                        verifyWallReleased
                          active
                          receipt
                          (restoreObservation layout)
                      of
                        Left err -> pure (Left (fromModelError err))
                        Right () -> clearReleased receipt
                phase ->
                  pure
                    ( Left
                        ( WindowsWallModelFailure
                            ( IllegalWallTransition
                                phase
                                "restore requires a durably applied wall"
                            )
                        )
                    )

driveRestoring ::
  Int ->
  ( Int ->
    WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either WindowsWallError ())
  ) ->
  FilePath ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either WindowsWallError ())
driveRestoring steps continueRestore target receipt =
  do
    recoveryStep <-
      withRestoreLayout target active $ \layout ->
        case classifyWallRestore receipt (restoreObservation layout) of
          RestoreRetryFromApplied ->
            case persistedWallOrigin active of
              Nothing ->
                pure
                  (Left (WindowsWallJournalFailure "restoring record has no origin"))
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
                    stored <- storeReceipt restored
                    pure (stored >> Right (RestoreRecoveryWith restored))
          RestoreBlocked conflict ->
            pure (Left (WindowsWallConflict conflict))
          classification ->
            pure
              ( Left
                  ( WindowsWallModelFailure
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
            (Left (WindowsWallJournalFailure "managed target vanished before delete"))
        Just managed -> do
          deleted <- deleteOpenFile managed
          pure (deleted >> Right RestoreRecoverySame)
    retireManagedTarget layout =
      case layoutRestoreTarget layout of
        Nothing ->
          pure
            (Left (WindowsWallJournalFailure "managed target vanished before retirement"))
        Just managed -> do
          renamed <- renameOpenFile managed (retiredPath target active)
          pure (renamed >> Right RestoreRecoverySame)
    publishOrigin layout =
      case layoutRestoreRetained layout of
        Nothing ->
          pure
            (Left (WindowsWallJournalFailure "retained origin vanished before publication"))
        Just origin -> do
          renamed <- renameOpenFile origin target
          pure (renamed >> Right RestoreRecoverySame)
    deleteRetiredManaged layout =
      case layoutRestoreRetired layout of
        Nothing ->
          pure
            (Left (WindowsWallJournalFailure "retired managed object vanished before delete"))
        Just managed -> do
          deleted <- deleteOpenFile managed
          pure (deleted >> Right RestoreRecoverySame)

runWithAuthority ::
  PersistedWallRecord ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  ( WallAuthority ownerId wallSpecId reservationId receiptId fenceId ->
    IO (Either WindowsWallError result)
  ) ->
  IO (Either WindowsWallError result)
runWithAuthority active receipt consume =
  case
      joinModel
        (withWallAuthority active receipt (Right . consume))
    of
    Left err -> pure (Left (fromModelError err))
    Right operation -> operation

clearReleased ::
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either WindowsWallError ())
clearReleased receipt = do
  cleared <- deleteActiveIfEqual (wallReceiptRecord receipt)
  pure $
    case cleared of
      Left err -> Left err
      Right True -> Right ()
      Right False ->
        Left
          ( WindowsWallJournalFailure
              "released active record changed before conditional clear"
          )

withApplyLayout ::
  FilePath ->
  PersistedWallRecord ->
  (ApplyLayout -> IO (Either WindowsWallError result)) ->
  IO (Either WindowsWallError result)
withApplyLayout target record consume =
  case checkedStagePaths target record of
    Left err -> pure (Left err)
    Right (stage, _) ->
      withOpenPath target $ \targetFile -> do
        stageResult <-
          withOpenPath stage $ \stageFile -> do
            let retained = retainedPath target record
            retainedResult <-
              withOpenPath retained $ \retainedFile ->
                consume
                  ApplyLayout
                    { layoutApplyTarget = targetFile,
                      layoutApplyStage = stageFile,
                      layoutApplyRetained = retainedFile
                    }
            resolveSharingFailure
              [targetFile, stageFile]
              retained
              retainedResult
        resolveSharingFailure [targetFile] stage stageResult

withRestoreLayout ::
  FilePath ->
  PersistedWallRecord ->
  (RestoreLayout -> IO (Either WindowsWallError result)) ->
  IO (Either WindowsWallError result)
withRestoreLayout target record consume =
  withOpenPath target $ \targetFile -> do
    let retained = retainedPath target record
        retired = retiredPath target record
    retainedResult <-
      withOpenPath retained $ \retainedFile -> do
        retiredResult <-
          withOpenPath retired $ \retiredFile ->
            consume
              RestoreLayout
                { layoutRestoreTarget = targetFile,
                  layoutRestoreRetained = retainedFile,
                  layoutRestoreRetired = retiredFile
                }
        resolveSharingFailure
          [targetFile, retainedFile]
          retired
          retiredResult
    resolveSharingFailure [targetFile] retained retainedResult

-- | Re-observe the path with a zero-access metadata probe before classifying a
-- sharing violation.  Opening several recovery names with share mode zero can
-- fail because two names are hard links to the same already-open object.  It
-- can also fail because an unrelated process holds an unrelated file.  The
-- old implementation assigned the first prior FILE_ID to every such failure;
-- that invented identity evidence.  A matching probe now proves the alias,
-- while every non-matching or unstable layout remains a non-mutating Busy
-- refusal.
resolveSharingFailure ::
  [Maybe OpenFile] ->
  FilePath ->
  Either WindowsWallError result ->
  IO (Either WindowsWallError result)
resolveSharingFailure prior path result =
  case result of
    Left (WindowsWallNativeFailure _ status)
      | isSharingStatus status -> do
          probed <- probePathIdentity path
          pure $
            case probed of
              Right (Just observed)
                | observed `elem` map openFileIdentity [file | Just file <- prior] ->
                    Left
                      ( WindowsWallConflict
                          (ConflictingWallPathShare observed)
                      )
              _ ->
                Left
                  ( WindowsWallBusy
                      ( "could not exclusively observe "
                          ++ path
                          ++ " because another handle is active"
                      )
                  )
    _ -> pure result

applyObservation :: ApplyLayout -> ApplyObservation
applyObservation layout =
  ApplyObservation
    { applyTargetObservation = fileObservation (layoutApplyTarget layout),
      applyStagedObservation = fileObservation (layoutApplyStage layout),
      applyRetainedOriginObservation =
        fileObservation (layoutApplyRetained layout)
    }

restoreObservation :: RestoreLayout -> RestoreObservation
restoreObservation layout =
  RestoreObservation
    { restoreTargetObservation = fileObservation (layoutRestoreTarget layout),
      restoreRetainedOriginObservation =
        fileObservation (layoutRestoreRetained layout),
      restoreRetiredManagedObservation =
        fileObservation (layoutRestoreRetired layout)
    }

fileObservation :: Maybe OpenFile -> WallObservation
fileObservation Nothing = ObservedAbsent
fileObservation (Just file) =
  ObservedPresent (openFileIdentity file) (openFileBytes file)

expectedStagedObservation :: PersistedWallRecord -> WallObservation
expectedStagedObservation record =
  case persistedTargetIdentity record of
    Nothing -> ObservedAbsent
    Just identity -> ObservedPresent identity (persistedDesiredBytes record)

observesExactOrigin :: WslConfigOrigin -> Maybe OpenFile -> Bool
observesExactOrigin OriginalAbsent Nothing = True
observesExactOrigin (OriginalPresent identity bytes) (Just file) =
  identity == openFileIdentity file && bytes == openFileBytes file
observesExactOrigin _ _ = False

stageMismatch :: PersistedWallRecord -> WallObservation -> WindowsWallError
stageMismatch record observation =
  case (persistedTargetIdentity record, observation) of
    (Just expected, ObservedPresent observed _)
      | expected /= observed ->
          WindowsWallConflict (TargetReplaced expected observed)
      | otherwise ->
          WindowsWallConflict (TargetAmbiguous expected)
    (Just expected, ObservedAbsent) ->
      WindowsWallConflict (UnexpectedTargetAbsent expected)
    (Nothing, ObservedPresent observed _) ->
      WindowsWallConflict (UnboundStagePresent observed)
    (Nothing, ObservedAbsent) ->
      WindowsWallJournalFailure "stage mismatch has no bound identity"

validateStageVolume ::
  PersistedWallRecord ->
  FileIdentity ->
  Either WindowsWallError ()
validateStageVolume record stagedIdentity =
  case persistedWallOrigin record of
    Just (OriginalPresent originalIdentity _)
      | identityVolume originalIdentity /= identityVolume stagedIdentity ->
          Left
            ( WindowsWallUnsupported
                "the staged .wslconfig is not on the origin volume"
            )
    _ -> Right ()

identityVolume :: FileIdentity -> ByteString
identityVolume = ByteString.take 8 . fileIdentityBytes

checkedStagePaths ::
  FilePath ->
  PersistedWallRecord ->
  Either WindowsWallError (FilePath, FilePath)
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
                ( WindowsWallJournalFailure
                    "persisted stage candidate is not the adapter-derived name"
                )
        Nothing ->
          Left
            (WindowsWallJournalFailure "stage phase has no candidate name")

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
  FilePath ->
  (Maybe OpenFile -> IO (Either WindowsWallError result)) ->
  IO (Either WindowsWallError result)
withOpenPath path consume =
  mask $ \restore -> do
    opened <- openPath path
    case opened of
      Left err -> pure (Left err)
      Right Nothing -> restore (consume Nothing)
      Right (Just file) -> do
        result <-
          restore (consume (Just file))
            `onException` void (closeOpenFile file)
        closed <- closeOpenFile file
        pure $
          case (result, closed) of
            (Left err, _) -> Left err
            (Right _, Left err) -> Left err
            (Right value, Right ()) -> Right value

openPath :: FilePath -> IO (Either WindowsWallError (Maybe OpenFile))
openPath path =
  withCWString path $ \widePath ->
    alloca $ \handlePointer ->
      allocaBytes 24 $ \identityPointer ->
        alloca $ \bytesPointer ->
          alloca $ \lengthPointer ->
            alloca $ \presentPointer -> do
              status <-
                cOpenExclusive
                  widePath
                  handlePointer
                  identityPointer
                  bytesPointer
                  lengthPointer
                  presentPointer
              if status /= 0
                then pure (Left (nativeFailure ("open " ++ path) status))
                else do
                  CInt present <- peek presentPointer
                  if present == 0
                    then pure (Right Nothing)
                    else do
                      handle <- peek handlePointer
                      ( do
                          identityBytes <-
                            ByteString.packCStringLen
                              (castPtr identityPointer, 24)
                          nativeBytes <- peek bytesPointer
                          CSize nativeLength <- peek lengthPointer
                          bytes <-
                            if nativeLength == 0
                              then pure ByteString.empty
                              else
                                ByteString.packCStringLen
                                  (castPtr nativeBytes, fromIntegral nativeLength)
                          if nativeBytes /= nullPtr
                            then cFree nativeBytes
                            else pure ()
                          case mkFileIdentity identityBytes of
                            Left err -> do
                              _ <- cCloseHandle handle
                              pure (Left (fromModelError err))
                            Right identity ->
                              pure
                                ( Right
                                    ( Just
                                        OpenFile
                                          { openFileHandle = handle,
                                            openFileIdentity = identity,
                                            openFileBytes = bytes
                                          }
                                    )
                                )
                        )
                        `onException` void (cCloseHandle handle)

-- | Read only a path's FILE_ID without asking for data or mutation access.
-- This observation never authorizes a filesystem operation: it is used solely
-- to turn no-replace and sharing races into conservative conflicts or Busy
-- results.  The native probe follows neither reparse points nor directories.
probePathIdentity ::
  FilePath ->
  IO (Either WindowsWallError (Maybe FileIdentity))
probePathIdentity path =
  withCWString path $ \widePath ->
    allocaBytes 24 $ \identityPointer ->
      alloca $ \presentPointer -> do
        status <- cProbeIdentity widePath identityPointer presentPointer
        if status /= 0
          then
            pure
              ( Left
                  ( if status == errorNotSupported
                      then
                        WindowsWallUnsupported
                          ("identity probing refused a directory or reparse point at " ++ path)
                      else nativeFailure ("probe identity of " ++ path) status
                  )
              )
          else do
            CInt present <- peek presentPointer
            if present == 0
              then pure (Right Nothing)
              else do
                identityBytes <-
                  ByteString.packCStringLen
                    (castPtr identityPointer, 24)
                pure
                  ( either
                      (Left . fromModelError)
                      (Right . Just)
                      (mkFileIdentity identityBytes)
                  )

createArmedStage ::
  FilePath ->
  ByteString ->
  IO (Either WindowsWallError OpenFile)
createArmedStage path bytes =
  withCWString path $ \widePath ->
    ByteString.useAsCStringLen bytes $ \(bytePointer, byteLength) ->
      alloca $ \handlePointer ->
        allocaBytes 24 $ \identityPointer -> do
          status <-
            cCreateStage
              widePath
              (castPtr bytePointer)
              (fromIntegral byteLength)
              handlePointer
              identityPointer
          if status /= 0
            then classifyPrivatePathRace "create armed stage" path status
            else do
              handle <- peek handlePointer
              ( do
                  identityBytes <-
                    ByteString.packCStringLen
                      (castPtr identityPointer, 24)
                  case mkFileIdentity identityBytes of
                    Left err -> do
                      _ <- cCloseHandle handle
                      pure (Left (fromModelError err))
                    Right identity ->
                      pure
                        ( Right
                            OpenFile
                              { openFileHandle = handle,
                                openFileIdentity = identity,
                                openFileBytes = bytes
                              }
                        )
                )
                `onException` void (cCloseHandle handle)

linkArmedStage ::
  OpenFile ->
  FilePath ->
  FilePath ->
  IO (Either WindowsWallError ())
linkArmedStage file armed bound =
  withCWString armed $ \armedPath ->
    withCWString bound $ \boundPath -> do
      status <-
        cLinkArmedStage
          (openFileHandle file)
          armedPath
          boundPath
      if status == 0
        then pure (Right ())
        else
          if status `elem` hardLinkUnsupportedStatuses
            then
              pure
                ( Left
                    ( WindowsWallUnsupported
                        ( "NTFS hard-link stage handoff is unavailable (Windows error "
                            ++ show status
                            ++ ")"
                        )
                    )
                )
            else do
              observed <- probePathIdentity bound
              pure $
                case observed of
                  Right (Just identity)
                    | identity == openFileIdentity file -> Right ()
                    | otherwise ->
                        Left
                          ( WindowsWallConflict
                              (UnboundStagePresent identity)
                          )
                  Right Nothing
                    | isRaceStatus status ->
                        Left
                          ( WindowsWallBusy
                              "the durable stage destination changed during hard-link publication"
                          )
                  Left err
                    | isRaceStatus status ->
                        Left
                          ( WindowsWallBusy
                              ( "the durable stage destination could not be safely reprobed: "
                                  ++ show err
                              )
                          )
                  _ ->
                    Left
                      (nativeFailure "create the durable stage hard link" status)

renameOpenFile :: OpenFile -> FilePath -> IO (Either WindowsWallError ())
renameOpenFile file destination =
  withCWString destination $ \wideDestination -> do
    status <-
      cRenameHandleNoReplace
        (openFileHandle file)
        wideDestination
    if status == 0
      then pure (Right ())
      else do
        -- SetFileInformationByHandle does not report destination collisions
        -- consistently across supported Windows/filesystem combinations.
        -- Reprobe the no-replace destination for identity evidence instead of
        -- guessing from one numeric status (or returning a generic native
        -- failure for ERROR_ALREADY_EXISTS).
        observed <- probePathIdentity destination
        pure $
          case observed of
            Right (Just identity) ->
              Left
                ( WindowsWallConflict
                    (UnexpectedTargetPresent identity)
                )
            Right Nothing
              | isRaceStatus status ->
                  Left
                    ( WindowsWallBusy
                        ( "the no-replace rename destination changed while reprobed: "
                            ++ destination
                        )
                    )
            Left err
              | isRaceStatus status ->
                  Left
                    ( WindowsWallBusy
                        ( "the no-replace rename destination could not be safely reprobed: "
                            ++ show err
                        )
                    )
            _ -> Left (nativeFailure ("rename to " ++ destination) status)

deleteOpenFile :: OpenFile -> IO (Either WindowsWallError ())
deleteOpenFile file = do
  status <- cDeleteHandle (openFileHandle file)
  pure
    ( if status == 0
        then Right ()
        else Left (nativeFailure "conditionally delete an exact file handle" status)
    )

closeOpenFile :: OpenFile -> IO (Either WindowsWallError ())
closeOpenFile file = do
  status <- cCloseHandle (openFileHandle file)
  pure
    ( if status == 0
        then Right ()
        else Left (nativeFailure "close an exact file handle" status)
    )

loadActiveRecord ::
  IO (Either WindowsWallError (Maybe PersistedWallRecord))
loadActiveRecord =
  mask $ \_ ->
    alloca $ \bytesPointer ->
      alloca $ \lengthPointer ->
        alloca $ \presentPointer -> do
          status <-
            cRegistryLoadActive
              bytesPointer
              lengthPointer
              presentPointer
          if status /= 0
            then pure (Left (nativeFailure "load the active wall record" status))
            else do
              CInt present <- peek presentPointer
              if present == 0
                then pure (Right Nothing)
                else do
                  nativeBytes <- peek bytesPointer
                  CSize nativeLength <- peek lengthPointer
                  if nativeBytes == nullPtr || nativeLength == 0
                    then
                      pure
                        ( Left
                            ( nativeFailure
                                "load the active wall record"
                                errorInvalidData
                            )
                        )
                    else
                      bracket
                        (pure nativeBytes)
                        cFree
                        ( \ownedBytes -> do
                            bytes <-
                              ByteString.packCStringLen
                                (castPtr ownedBytes, fromIntegral nativeLength)
                            pure (Just <$> decodeWallRecord bytes)
                        )

allocateFence :: IO (Either WindowsWallError Word64)
allocateFence =
  alloca $ \fencePointer -> do
    status <- cRegistryAllocateFence fencePointer
    if status /= 0
      then pure (Left (nativeFailure "allocate the next wall fence" status))
      else Right <$> peek fencePointer

storeReceipt ::
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  IO (Either WindowsWallError ())
storeReceipt = storeRecord . wallReceiptRecord

storeRecord :: PersistedWallRecord -> IO (Either WindowsWallError ())
storeRecord record =
  let bytes = encodeWallRecord record
   in if ByteString.length bytes > maximumWallBytes
        then
          pure
            ( Left
                ( WindowsWallUnsupported
                    "encoded active wall record exceeds the 16 MiB recoverable limit"
                )
            )
        else
          ByteString.useAsCStringLen bytes $ \(pointer, encodedLength) -> do
            status <-
              cRegistryStoreActive
                (castPtr pointer)
                (fromIntegral encodedLength)
            pure
              ( if status == 0
                  then Right ()
                  else Left (nativeFailure "flush the active wall record" status)
              )

deleteActiveIfEqual ::
  PersistedWallRecord ->
  IO (Either WindowsWallError Bool)
deleteActiveIfEqual record =
  let bytes = encodeWallRecord record
   in ByteString.useAsCStringLen bytes $ \(pointer, encodedLength) ->
        alloca $ \deletedPointer -> do
          status <-
            cRegistryDeleteActiveIfEqual
              (castPtr pointer)
              (fromIntegral encodedLength)
              deletedPointer
          if status /= 0
            then
              pure
                (Left (nativeFailure "conditionally clear the active wall record" status))
            else do
              CInt deleted <- peek deletedPointer
              pure (Right (deleted /= 0))

-- | Conservatively classify a failed CREATE_NEW-style operation.  A present
-- object is exact identity evidence of an unowned private-stage collision.  If
-- a known collision/contention status races with disappearance or prevents a
-- safe probe, callers may retry later but may not adopt or overwrite anything.
classifyPrivatePathRace ::
  String ->
  FilePath ->
  Word32 ->
  IO (Either WindowsWallError result)
classifyPrivatePathRace operation path status = do
  observed <- probePathIdentity path
  pure $
    case observed of
      Right (Just identity) ->
        Left
          ( WindowsWallConflict
              (UnboundStagePresent identity)
          )
      Right Nothing
        | isRaceStatus status ->
            Left
              ( WindowsWallBusy
                  (operation ++ " raced with a changing destination at " ++ path)
              )
      Left err
        | isRaceStatus status ->
            Left
              ( WindowsWallBusy
                  ( operation
                      ++ " could not safely re-observe its destination: "
                      ++ show err
                  )
              )
      _ -> Left (nativeFailure (operation ++ " " ++ path) status)

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
wallRecordMagic = "HBWSLW02"

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

decodeWallRecord :: ByteString -> Either WindowsWallError PersistedWallRecord
decodeWallRecord bytes =
  case runDecoder wallRecordDecoder bytes of
    Left err -> Left (WindowsWallJournalFailure err)
    Right (_, trailing)
      | not (ByteString.null trailing) ->
          Left
            (WindowsWallJournalFailure "active wall record has trailing bytes")
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

getIdentity :: Decoder FileIdentity
getIdentity = do
  bytes <- getSized
  if ByteString.length bytes /= 24
    then decoderFailure "Windows FILE_ID_INFO evidence must be exactly 24 bytes"
    else
      case mkFileIdentity bytes of
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

nativeFailure :: String -> Word32 -> WindowsWallError
nativeFailure operation status =
  WindowsWallNativeFailure operation status

errorBusy :: Word32
errorBusy = 170

errorInvalidData :: Word32
errorInvalidData = 13

errorNotSupported :: Word32
errorNotSupported = 50

isSharingStatus :: Word32 -> Bool
isSharingStatus status =
  status == errorSharingViolation || status == errorLockViolation

isRaceStatus :: Word32 -> Bool
isRaceStatus status =
  isSharingStatus status
    || status == errorBusy
    || status == errorFileExists
    || status == errorAlreadyExists

errorSharingViolation :: Word32
errorSharingViolation = 32

errorLockViolation :: Word32
errorLockViolation = 33

errorFileExists :: Word32
errorFileExists = 80

errorAlreadyExists :: Word32
errorAlreadyExists = 183

hardLinkUnsupportedStatuses :: [Word32]
hardLinkUnsupportedStatuses = [1, 17, 50]

fromModelError :: WallModelError -> WindowsWallError
fromModelError (WallConflictError conflict) = WindowsWallConflict conflict
fromModelError err = WindowsWallModelFailure err

fromConfigError :: ConfigBytesError -> WindowsWallError
fromConfigError = WindowsWallConfigurationFailure

joinModel :: Either error (Either error value) -> Either error value
joinModel = either Left id

#endif
