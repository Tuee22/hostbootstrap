{-# LANGUAGE RankNTypes #-}

{- | Pure ownership and recovery model for WSL's per-user global
@%UserProfile%\\.wslconfig@ wall.

This module deliberately contains no filesystem, Registry, or Win32 calls. A
Windows adapter is responsible for holding a platform-authoritative reservation,
persisting each returned 'PersistedWallRecord' durably, and observing the target
through an identity-bound conditional file operation. The model supplies the
legal journal graph and refuses to turn a pathname, matching bytes, or a stale
receipt into authority.

The constructors of the owner, specification, reservation, receipt, fence, and
authority values are hidden. Stable byte identities are admitted through
rank-2 continuations so a caller cannot accidentally mix the evidence for two
owners or operations. 'PersistedWallRecord' is intentionally plain untrusted
data: a future protected Registry backend can encode and decode it, then
'claimOrResumeWall' validates it against the locally reconstructed reservation.

Every function that advances an existing record also consumes the current
active durable record. Fence comparison is performed before mutation, so an
old receipt cannot restore or release a newer acquisition.
-}
module HostBootstrap.Wsl2.GlobalWall
  ( -- * Opaque acquisition identity
    WallOwner,
    withWallOwner,
    WallSpec,
    withWallSpec,
    WallFence,
    withWallFence,
    wallFenceValue,
    WallReservation,
    withWallReservation,

    -- * Exact target observations
    FileIdentity,
    mkFileIdentity,
    fileIdentityBytes,
    WslConfigOrigin (..),
    WallObservation (..),
    ApplyObservation (..),
    RestoreObservation (..),

    -- * Durable journal model
    WallJournalPhase (..),
    PersistedWallRecord (..),
    WallConflict (..),
    WallModelError (..),
    StageCreateClassification (..),
    ApplyClassification (..),
    RestoreClassification (..),

    -- * Opaque receipt and authority
    WallReceipt,
    WallAuthority,
    claimOrResumeWall,
    wallReceiptRecord,
    wallReceiptFence,
    wallAuthorityFence,
    recordWallOrigin,
    beginWallStageCreation,
    classifyWallStageCreation,
    bindWallStage,
    beginWallApply,
    classifyWallApply,
    settleWallApply,
    withWallAuthority,
    beginWallRestore,
    classifyWallRestore,
    settleWallRestore,
    releaseWall,
    verifyWallReleased,
  )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Word (Word64)

-- | Stable owner identity, such as a verified plan/resource identity. Its
-- constructor is hidden; the bytes are identity only and never write authority.
newtype WallOwner ownerId = WallOwner ByteString

-- | Stable wall-specification identity plus the exact bytes the specification
-- wants written. A specification identifier may never be reused for different
-- desired bytes.
data WallSpec wallSpecId = WallSpec ByteString ByteString

-- | Durable, strictly positive fencing value allocated by the protected
-- backend.
newtype WallFence fenceId = WallFence Word64

-- | Same-owner/same-spec pre-call reservation. The reservation and receipt
-- identities are distinct so an acknowledged receipt cannot be confused with
-- the operation that requested it.
data WallReservation ownerId wallSpecId reservationId receiptId fenceId =
  WallReservation
    (WallOwner ownerId)
    (WallSpec wallSpecId)
    ByteString
    ByteString
    (WallFence fenceId)

-- | Admit a non-empty durable owner identity.
withWallOwner ::
  ByteString ->
  (forall ownerId. WallOwner ownerId -> result) ->
  Either WallModelError result
withWallOwner ownerIdentity consume
  | ByteString.null ownerIdentity =
      Left (InvalidWallIdentity "wall owner identity must not be empty")
  | otherwise = Right (consume (WallOwner ownerIdentity))

-- | Admit a non-empty stable specification identity and its exact desired
-- bytes. Empty desired bytes are legal; presence and absence remain distinct.
withWallSpec ::
  ByteString ->
  ByteString ->
  (forall wallSpecId. WallSpec wallSpecId -> result) ->
  Either WallModelError result
withWallSpec specIdentity desiredBytes consume
  | ByteString.null specIdentity =
      Left (InvalidWallIdentity "wall specification identity must not be empty")
  | otherwise = Right (consume (WallSpec specIdentity desiredBytes))

-- | Admit a durable positive fence.
withWallFence ::
  Word64 ->
  (forall fenceId. WallFence fenceId -> result) ->
  Either WallModelError result
withWallFence value consume
  | value == 0 = Left (InvalidWallFence value)
  | otherwise = Right (consume (WallFence value))

wallFenceValue :: WallFence fenceId -> Word64
wallFenceValue (WallFence value) = value

-- | Bind non-empty reservation and receipt identities to one owner, spec, and
-- fence. The protected backend chooses and persists these byte identities.
withWallReservation ::
  WallOwner ownerId ->
  WallSpec wallSpecId ->
  ByteString ->
  ByteString ->
  WallFence fenceId ->
  ( forall reservationId receiptId.
    WallReservation ownerId wallSpecId reservationId receiptId fenceId ->
    result
  ) ->
  Either WallModelError result
withWallReservation owner spec reservationIdentity receiptIdentity fence consume
  | ByteString.null reservationIdentity =
      Left (InvalidWallIdentity "wall reservation identity must not be empty")
  | ByteString.null receiptIdentity =
      Left (InvalidWallIdentity "wall receipt identity must not be empty")
  | otherwise =
      Right
        ( consume
            (WallReservation owner spec reservationIdentity receiptIdentity fence)
        )

-- | Platform-stable identity of the exact file object observed through an
-- authoritative handle. It is not a pathname or a content hash.
newtype FileIdentity = FileIdentity ByteString
  deriving (Eq, Ord)

instance Show FileIdentity where
  show (FileIdentity identity) =
    "FileIdentity<" ++ show (ByteString.length identity) ++ " bytes>"

mkFileIdentity :: ByteString -> Either WallModelError FileIdentity
mkFileIdentity identity
  | ByteString.null identity =
      Left (InvalidWallIdentity "file identity must not be empty")
  | otherwise = Right (FileIdentity identity)

fileIdentityBytes :: FileIdentity -> ByteString
fileIdentityBytes (FileIdentity identity) = identity

-- | Durable origin captured and flushed before the first content mutation.
-- Exact bytes are retained even when they are empty.
data WslConfigOrigin
  = OriginalAbsent
  | OriginalPresent FileIdentity ByteString
  deriving (Eq)

instance Show WslConfigOrigin where
  show OriginalAbsent = "OriginalAbsent"
  show (OriginalPresent identity bytes) =
    "OriginalPresent "
      ++ show identity
      ++ " <"
      ++ show (ByteString.length bytes)
      ++ " bytes>"

-- | Total target observation supplied by the future platform backend.
data WallObservation
  = ObservedAbsent
  | ObservedPresent FileIdentity ByteString
  deriving (Eq)

instance Show WallObservation where
  show ObservedAbsent = "ObservedAbsent"
  show (ObservedPresent identity bytes) =
    "ObservedPresent "
      ++ show identity
      ++ " <"
      ++ show (ByteString.length bytes)
      ++ " bytes>"

-- | Apply recovery observes both the public @.wslconfig@ target and the
-- identity-known staged object. The platform adapter prepares and flushes the
-- staged object first, journals its identity, and then publishes it atomically.
-- A present origin is retained under its exact identity by the replacement
-- primitive; an absent origin uses a no-replace rename. Keeping all three
-- observations explicit distinguishes "retry publication" from an unowned
-- newly appearing target.
data ApplyObservation = ApplyObservation
  { applyTargetObservation :: WallObservation,
    applyStagedObservation :: WallObservation,
    applyRetainedOriginObservation :: WallObservation
  }
  deriving (Eq, Show)

-- | Restore recovery observes the public target, the retained original object
-- used by a present-origin atomic swap, and the retired managed object produced
-- by the inverse swap. The latter must be deleted by exact identity before
-- restoration can settle.
data RestoreObservation = RestoreObservation
  { restoreTargetObservation :: WallObservation,
    restoreRetainedOriginObservation :: WallObservation,
    restoreRetiredManagedObservation :: WallObservation
  }
  deriving (Eq, Show)

-- | Durable phases. The two outcome-unknown phases are written and flushed
-- before their corresponding external file calls.
data WallJournalPhase
  = WallClaimed
  | WallOriginRecorded
  | WallStageCreateOutcomeUnknown
  | WallStageBound
  | WallApplyOutcomeUnknown
  | WallApplied
  | WallRestoreOutcomeUnknown
  | WallRestored
  | WallReleased
  deriving (Eq, Ord, Show)

-- | Registry-serialisable model record. This value is untrusted until
-- 'claimOrResumeWall' validates it against an opaque local reservation.
data PersistedWallRecord = PersistedWallRecord
  { persistedOwnerIdentity :: ByteString,
    persistedSpecIdentity :: ByteString,
    persistedReservationIdentity :: ByteString,
    persistedReceiptIdentity :: ByteString,
    persistedFenceValue :: Word64,
    persistedDesiredBytes :: ByteString,
    persistedWallPhase :: WallJournalPhase,
    persistedWallOrigin :: Maybe WslConfigOrigin,
    persistedStageCandidate :: Maybe ByteString,
    persistedTargetIdentity :: Maybe FileIdentity
  }
  deriving (Eq)

instance Show PersistedWallRecord where
  show record =
    "PersistedWallRecord {owner=<"
      ++ show (ByteString.length (persistedOwnerIdentity record))
      ++ " bytes>, spec=<"
      ++ show (ByteString.length (persistedSpecIdentity record))
      ++ " bytes>, reservation=<"
      ++ show (ByteString.length (persistedReservationIdentity record))
      ++ " bytes>, receipt=<"
      ++ show (ByteString.length (persistedReceiptIdentity record))
      ++ " bytes>, fence="
      ++ show (persistedFenceValue record)
      ++ ", desired=<"
      ++ show (ByteString.length (persistedDesiredBytes record))
      ++ " bytes>, phase="
      ++ show (persistedWallPhase record)
      ++ ", origin="
      ++ show (persistedWallOrigin record)
      ++ ", stageCandidate=<"
      ++ maybe
        "absent"
        (\candidate -> show (ByteString.length candidate) ++ " bytes")
        (persistedStageCandidate record)
      ++ ">"
      ++ ", target="
      ++ show (persistedTargetIdentity record)
      ++ "}"

-- | Structured refusal. No refusal branch authorizes a write, restore, delete,
-- release, or automatic takeover.
data WallConflict
  = ForeignWallOwner ByteString ByteString
  | IncompatibleWallSpec ByteString ByteString
  | ForeignWallReservation ByteString ByteString
  | ForeignWallReceipt ByteString ByteString
  | StaleWallFence Word64 Word64
  | StaleWallReceipt WallJournalPhase WallJournalPhase
  | TargetReplaced FileIdentity FileIdentity
  | TargetAmbiguous FileIdentity
  | InPlaceMutationUnsupported FileIdentity
  | UnboundStagePresent FileIdentity
  | ConflictingWallPathShare FileIdentity
  | UnexpectedTargetAbsent FileIdentity
  | UnexpectedTargetPresent FileIdentity
  | OriginStateChanged
  deriving (Eq, Show)

data WallModelError
  = InvalidWallIdentity String
  | InvalidWallFence Word64
  | InvalidWallJournal String
  | IllegalWallTransition WallJournalPhase String
  | WallConflictError WallConflict
  deriving (Eq, Show)

-- | Recovery classification for the gap between a durable create intent and
-- binding the FILE_ID from the still-open @CREATE_NEW@ handle. A present
-- pathname is deliberately ambiguous and cannot be adopted by name or bytes.
data StageCreateClassification
  = StageCreateRetry
  | StageCreateObservedBound
  | StageCreateBlocked WallConflict
  | StageCreateNotInProgress WallJournalPhase
  deriving (Eq, Show)

-- | Total apply/recovery classification. Only 'ApplyObservedDesired' and
-- 'ApplyAlreadyApplied' may settle to the applied phase.
data ApplyClassification
  = ApplyRetryFromOrigin
  | ApplyRetryPublication
  | ApplyObservedDesired
  | ApplyAlreadyApplied
  | ApplyBlocked WallConflict
  | ApplyNotInProgress WallJournalPhase
  deriving (Eq, Show)

-- | Total restore/recovery classification. Restoration may be retried only
-- while the exact applied object and bytes are still observed.
data RestoreClassification
  = RestoreRetryFromApplied
  | RestoreRetryOriginPublication
  | RestoreRetryManagedCleanup
  | RestoreObservedOrigin
  | RestoreAlreadyRestored
  | RestoreBlocked WallConflict
  | RestoreNotInProgress WallJournalPhase
  deriving (Eq, Show)

-- | Opaque, reservation-bound durable receipt.
newtype WallReceipt ownerId wallSpecId reservationId receiptId fenceId =
  WallReceipt PersistedWallRecord

-- | Opaque authority available only from a durably applied (or later teardown)
-- record with the same active receipt and fence.
newtype WallAuthority ownerId wallSpecId reservationId receiptId fenceId =
  WallAuthority PersistedWallRecord

-- | Create a claimed record when no active record exists, or recover the exact
-- same durable receipt. A released record may be recovered only so a backend
-- that crashed before clearing its active pointer can verify/finalise release;
-- it is never treated as a fresh acquisition.
claimOrResumeWall ::
  WallReservation ownerId wallSpecId reservationId receiptId fenceId ->
  Maybe PersistedWallRecord ->
  Either
    WallModelError
    (WallReceipt ownerId wallSpecId reservationId receiptId fenceId)
claimOrResumeWall reservation maybeActive =
  case maybeActive of
    Nothing -> Right (WallReceipt (recordFromReservation reservation))
    Just active -> do
      validatePersistedRecord active
      validateReservationAgainstRecord reservation active
      Right (WallReceipt active)

wallReceiptRecord ::
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  PersistedWallRecord
wallReceiptRecord (WallReceipt record) = record

wallReceiptFence ::
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  Word64
wallReceiptFence = persistedFenceValue . wallReceiptRecord

wallAuthorityFence ::
  WallAuthority ownerId wallSpecId reservationId receiptId fenceId ->
  Word64
wallAuthorityFence (WallAuthority record) = persistedFenceValue record

-- | Persist exact original bytes or exact absence. The returned
-- 'WallOriginRecorded' record must be durably flushed before beginning any file
-- content mutation.
recordWallOrigin ::
  PersistedWallRecord ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  WslConfigOrigin ->
  Either
    WallModelError
    (WallReceipt ownerId wallSpecId reservationId receiptId fenceId)
recordWallOrigin active receipt@(WallReceipt record) origin = do
  revalidateActiveReceipt active receipt
  case persistedWallPhase record of
    WallClaimed ->
      Right
        ( WallReceipt
            record
              { persistedWallPhase = WallOriginRecorded,
                persistedWallOrigin = Just origin
              }
        )
    WallOriginRecorded
      | persistedWallOrigin record == Just origin -> Right receipt
      | otherwise ->
          Left
            ( WallConflictError
                (originConflict (persistedWallOrigin record) origin)
            )
    phase ->
      Left
        ( IllegalWallTransition
            phase
            "the origin may only be recorded from a claimed wall"
        )

-- | Durably bind a non-empty stage candidate name before asking the
-- filesystem to create an armed, delete-on-close object. The candidate names
-- the later durable hard link; it is not file authority. If a process dies
-- before the still-open armed handle's identity is journaled, its sole link is
-- removed and recovery observes the candidate absent. A candidate that is
-- nevertheless present before identity binding remains ambiguous.
beginWallStageCreation ::
  PersistedWallRecord ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  ByteString ->
  Either
    WallModelError
    (WallReceipt ownerId wallSpecId reservationId receiptId fenceId)
beginWallStageCreation active receipt@(WallReceipt record) candidate = do
  revalidateActiveReceipt active receipt
  if ByteString.null candidate
    then
      Left
        (InvalidWallIdentity "wall stage candidate identity must not be empty")
    else
      case persistedWallPhase record of
        WallOriginRecorded ->
          Right
            ( WallReceipt
                record
                  { persistedWallPhase = WallStageCreateOutcomeUnknown,
                    persistedStageCandidate = Just candidate
                  }
            )
        WallStageCreateOutcomeUnknown
          | persistedStageCandidate record == Just candidate -> Right receipt
          | otherwise ->
              Left
                ( InvalidWallJournal
                    "stage-create retry proposed a different candidate identity"
                )
        phase ->
          Left
            ( IllegalWallTransition
                phase
                "stage creation may only begin from an origin record"
            )

-- | Classify recovery of the create-intent and durable-link gaps. Before an
-- armed handle has been bound, absence allows another @CREATE_NEW@ attempt and
-- any bound pathname is ambiguous. Once the handle's FILE_ID is durable,
-- absence allows a fresh armed object to be rebound (no public effect has yet
-- been authorised), while only the exact identity and bytes prove that the
-- durable hard-link handoff completed.
classifyWallStageCreation ::
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  WallObservation ->
  StageCreateClassification
classifyWallStageCreation (WallReceipt record) observation =
  case persistedWallPhase record of
    WallStageCreateOutcomeUnknown ->
      case observation of
        ObservedAbsent -> StageCreateRetry
        ObservedPresent identity _ ->
          StageCreateBlocked (UnboundStagePresent identity)
    WallStageBound ->
      case persistedTargetIdentity record of
        Nothing -> StageCreateNotInProgress WallStageBound
        Just expectedIdentity ->
          case observation of
            ObservedAbsent -> StageCreateRetry
            ObservedPresent observedIdentity observedBytes
              | observedIdentity /= expectedIdentity ->
                  StageCreateBlocked
                    (TargetReplaced expectedIdentity observedIdentity)
              | observedBytes /= persistedDesiredBytes record ->
                  StageCreateBlocked (TargetAmbiguous expectedIdentity)
              | otherwise -> StageCreateObservedBound
    phase -> StageCreateNotInProgress phase

-- | Bind the FILE_ID of an armed delete-on-close stage while its sole link is
-- still owned by the live handle. The backend must durably flush the returned
-- 'WallStageBound' record before creating the durable no-replace hard link.
-- If recovery observes the durable link absent, a newly armed object may
-- replace the old bound identity because neither identity has reached the
-- public target.
bindWallStage ::
  PersistedWallRecord ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  WallObservation ->
  FileIdentity ->
  Either
    WallModelError
    (WallReceipt ownerId wallSpecId reservationId receiptId fenceId)
bindWallStage active receipt@(WallReceipt record) boundObservation stagedIdentity = do
  revalidateActiveReceipt active receipt
  validateApplyTarget record stagedIdentity
  case persistedWallPhase record of
    WallStageCreateOutcomeUnknown ->
      case classifyWallStageCreation receipt boundObservation of
        StageCreateRetry -> binding
        StageCreateBlocked conflict -> Left (WallConflictError conflict)
        classification ->
          illegal classification
    WallStageBound ->
      case classifyWallStageCreation receipt boundObservation of
        StageCreateRetry -> binding
        StageCreateObservedBound ->
          requireJournaledTarget record stagedIdentity >> Right receipt
        StageCreateBlocked conflict -> Left (WallConflictError conflict)
        classification ->
          illegal classification
    phase ->
      Left
        ( IllegalWallTransition
            phase
            "an armed stage may only bind from create-intent or rebind from a bound-but-absent stage"
        )
  where
    binding =
      Right
        ( WallReceipt
            record
              { persistedWallPhase = WallStageBound,
                persistedTargetIdentity = Just stagedIdentity
              }
        )
    illegal classification =
      Left
        ( IllegalWallTransition
            (persistedWallPhase record)
            ("an armed stage cannot bind from " ++ show classification)
        )

-- | Journal an apply outcome-unknown intent after observing the exact origin
-- and obtaining the identity of the exact staged desired object. The staged
-- object must already contain the exact desired bytes. Present and absent
-- origins both use atomic publication; for a present origin the desired object
-- must have a distinct identity and publication must retain the exact original
-- object. Once outcome-unknown is journaled, retry may use only that same
-- desired-object identity.
beginWallApply ::
  PersistedWallRecord ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  ApplyObservation ->
  FileIdentity ->
  Either
    WallModelError
    (WallReceipt ownerId wallSpecId reservationId receiptId fenceId)
beginWallApply active receipt@(WallReceipt record) observation targetIdentity = do
  revalidateActiveReceipt active receipt
  case persistedWallPhase record of
    WallStageBound -> do
      requireJournaledTarget record targetIdentity
      validatePreparedApply record observation targetIdentity
      applying
    WallApplyOutcomeUnknown -> do
      requireJournaledTarget record targetIdentity
      case classifyWallApply receipt observation of
        ApplyRetryFromOrigin -> Right receipt
        ApplyRetryPublication -> Right receipt
        ApplyBlocked conflict -> Left (WallConflictError conflict)
        classification ->
          Left
            ( IllegalWallTransition
                WallApplyOutcomeUnknown
                ("apply cannot resume from observation classified as " ++ show classification)
            )
    phase ->
      Left
        ( IllegalWallTransition
            phase
            "apply may only bind a live staged handle after a durable create intent or resume its outcome-unknown intent"
        )
  where
    applying =
      Right
        ( WallReceipt
            record
              { persistedWallPhase = WallApplyOutcomeUnknown,
                persistedTargetIdentity = Just targetIdentity
              }
        )

-- | Classify every observation relevant to initial application and apply
-- recovery.
classifyWallApply ::
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  ApplyObservation ->
  ApplyClassification
classifyWallApply (WallReceipt record) observation =
  case persistedWallPhase record of
    WallClaimed -> ApplyNotInProgress WallClaimed
    WallOriginRecorded ->
      case persistedWallOrigin record of
        Nothing -> ApplyNotInProgress WallOriginRecorded
        Just origin -> classifyOriginForApply origin observation
    WallStageCreateOutcomeUnknown ->
      ApplyNotInProgress WallStageCreateOutcomeUnknown
    WallStageBound ->
      ApplyNotInProgress WallStageBound
    WallApplyOutcomeUnknown ->
      classifyApplyingRecord record observation ApplyObservedDesired
    WallApplied ->
      classifyApplyingRecord record observation ApplyAlreadyApplied
    phase -> ApplyNotInProgress phase

-- | Settle an apply only after observing the exact expected object and exact
-- desired bytes. This returns an applied receipt; authority is obtained through
-- 'withWallAuthority' only after the backend has durably installed that record
-- as the active one.
settleWallApply ::
  PersistedWallRecord ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  ApplyObservation ->
  Either
    WallModelError
    (WallReceipt ownerId wallSpecId reservationId receiptId fenceId)
settleWallApply active receipt@(WallReceipt record) observation = do
  revalidateActiveReceipt active receipt
  case classifyWallApply receipt observation of
    ApplyObservedDesired ->
      Right
        ( WallReceipt
            record {persistedWallPhase = WallApplied}
        )
    ApplyAlreadyApplied -> Right receipt
    ApplyBlocked conflict -> Left (WallConflictError conflict)
    classification ->
      Left
        ( IllegalWallTransition
            (persistedWallPhase record)
            ("apply cannot settle from observation classified as " ++ show classification)
        )

-- | Revalidate an installed active record and expose its authority only within
-- a continuation. Apply-outcome-unknown state cannot mint authority.
withWallAuthority ::
  PersistedWallRecord ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  (WallAuthority ownerId wallSpecId reservationId receiptId fenceId -> result) ->
  Either WallModelError result
withWallAuthority active receipt@(WallReceipt record) consume = do
  revalidateActiveReceipt active receipt
  case persistedWallPhase record of
    WallApplied -> Right (consume (WallAuthority record))
    WallRestoreOutcomeUnknown -> Right (consume (WallAuthority record))
    WallRestored -> Right (consume (WallAuthority record))
    phase ->
      Left
        ( IllegalWallTransition
            phase
            "live wall authority requires a durably applied wall"
        )

-- | Revalidate the same authority/receipt/fence and journal restoration intent
-- only while the exact applied object and bytes remain observed.
beginWallRestore ::
  PersistedWallRecord ->
  WallAuthority ownerId wallSpecId reservationId receiptId fenceId ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  RestoreObservation ->
  Either
    WallModelError
    (WallReceipt ownerId wallSpecId reservationId receiptId fenceId)
beginWallRestore active authority receipt@(WallReceipt record) observation = do
  revalidateAuthority active authority receipt
  case classifyWallRestore receipt observation of
    RestoreRetryFromApplied ->
      case persistedWallPhase record of
        WallApplied ->
          Right
            ( WallReceipt
                record {persistedWallPhase = WallRestoreOutcomeUnknown}
            )
        WallRestoreOutcomeUnknown -> Right receipt
        phase ->
          Left
            ( IllegalWallTransition
                phase
                "restore retry is not legal from this journal phase"
            )
    RestoreBlocked conflict -> Left (WallConflictError conflict)
    classification ->
      Left
        ( IllegalWallTransition
            (persistedWallPhase record)
            ("restore cannot begin from observation classified as " ++ show classification)
        )

-- | Classify every observation relevant to restoration and restore recovery.
classifyWallRestore ::
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  RestoreObservation ->
  RestoreClassification
classifyWallRestore (WallReceipt record) observation =
  case persistedWallPhase record of
    WallApplied ->
      classifyAppliedForRestore record observation
    WallRestoreOutcomeUnknown ->
      classifyRestoringRecord record observation
    WallRestored ->
      classifyRestoredRecord record observation
    WallReleased ->
      classifyRestoredRecord record observation
    phase -> RestoreNotInProgress phase

-- | Settle restoration only after exact original bytes or exact absence have
-- been observed.
settleWallRestore ::
  PersistedWallRecord ->
  WallAuthority ownerId wallSpecId reservationId receiptId fenceId ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  RestoreObservation ->
  Either
    WallModelError
    (WallReceipt ownerId wallSpecId reservationId receiptId fenceId)
settleWallRestore active authority receipt@(WallReceipt record) observation = do
  revalidateAuthority active authority receipt
  case classifyWallRestore receipt observation of
    RestoreObservedOrigin ->
      Right
        ( WallReceipt
            record {persistedWallPhase = WallRestored}
        )
    RestoreAlreadyRestored -> Right receipt
    RestoreBlocked conflict -> Left (WallConflictError conflict)
    classification ->
      Left
        ( IllegalWallTransition
            (persistedWallPhase record)
            ("restore cannot settle from observation classified as " ++ show classification)
        )

-- | Fence and condition the final release on a re-observation of the exact
-- original state. The backend persists 'WallReleased' before conditionally
-- clearing its active Registry pointer.
releaseWall ::
  PersistedWallRecord ->
  WallAuthority ownerId wallSpecId reservationId receiptId fenceId ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  RestoreObservation ->
  Either
    WallModelError
    (WallReceipt ownerId wallSpecId reservationId receiptId fenceId)
releaseWall active authority receipt@(WallReceipt record) observation = do
  revalidateAuthority active authority receipt
  case (persistedWallPhase record, classifyWallRestore receipt observation) of
    (WallRestored, RestoreAlreadyRestored) ->
      Right
        ( WallReceipt
            record {persistedWallPhase = WallReleased}
        )
    (WallReleased, RestoreAlreadyRestored) -> Right receipt
    (_, RestoreBlocked conflict) -> Left (WallConflictError conflict)
    (phase, classification) ->
      Left
        ( IllegalWallTransition
            phase
            ("wall cannot release from observation classified as " ++ show classification)
        )

-- | Verify a released record after a crash between persisting release and
-- clearing the active pointer. This creates no mutation authority.
verifyWallReleased ::
  PersistedWallRecord ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  RestoreObservation ->
  Either WallModelError ()
verifyWallReleased active receipt@(WallReceipt record) observation = do
  revalidateActiveReceipt active receipt
  case (persistedWallPhase record, classifyWallRestore receipt observation) of
    (WallReleased, RestoreAlreadyRestored) -> Right ()
    (_, RestoreBlocked conflict) -> Left (WallConflictError conflict)
    (phase, classification) ->
      Left
        ( IllegalWallTransition
            phase
            ("released wall did not verify as " ++ show classification)
        )

recordFromReservation ::
  WallReservation ownerId wallSpecId reservationId receiptId fenceId ->
  PersistedWallRecord
recordFromReservation
  ( WallReservation
      (WallOwner ownerIdentity)
      (WallSpec specIdentity desiredBytes)
      reservationIdentity
      receiptIdentity
      (WallFence fenceValue)
    ) =
    PersistedWallRecord
      { persistedOwnerIdentity = ownerIdentity,
        persistedSpecIdentity = specIdentity,
        persistedReservationIdentity = reservationIdentity,
        persistedReceiptIdentity = receiptIdentity,
        persistedFenceValue = fenceValue,
        persistedDesiredBytes = desiredBytes,
        persistedWallPhase = WallClaimed,
        persistedWallOrigin = Nothing,
        persistedStageCandidate = Nothing,
        persistedTargetIdentity = Nothing
      }

validateReservationAgainstRecord ::
  WallReservation ownerId wallSpecId reservationId receiptId fenceId ->
  PersistedWallRecord ->
  Either WallModelError ()
validateReservationAgainstRecord reservation active = do
  let expected = recordFromReservation reservation
  if persistedOwnerIdentity expected /= persistedOwnerIdentity active
    then
      Left
        ( WallConflictError
            ( ForeignWallOwner
                (persistedOwnerIdentity expected)
                (persistedOwnerIdentity active)
            )
        )
    else Right ()
  if persistedSpecIdentity expected /= persistedSpecIdentity active
    then
      Left
        ( WallConflictError
            ( IncompatibleWallSpec
                (persistedSpecIdentity expected)
                (persistedSpecIdentity active)
            )
        )
    else Right ()
  if persistedDesiredBytes expected /= persistedDesiredBytes active
    then
      Left
        ( InvalidWallJournal
            "wall specification identity was reused for different desired bytes"
        )
    else Right ()
  if persistedFenceValue expected /= persistedFenceValue active
    then
      Left
        ( WallConflictError
            ( StaleWallFence
                (persistedFenceValue expected)
                (persistedFenceValue active)
            )
        )
    else Right ()
  if persistedReservationIdentity expected /= persistedReservationIdentity active
    then
      Left
        ( WallConflictError
            ( ForeignWallReservation
                (persistedReservationIdentity expected)
                (persistedReservationIdentity active)
            )
        )
    else Right ()
  if persistedReceiptIdentity expected /= persistedReceiptIdentity active
    then
      Left
        ( WallConflictError
            ( ForeignWallReceipt
                (persistedReceiptIdentity expected)
                (persistedReceiptIdentity active)
            )
        )
    else Right ()

validatePersistedRecord :: PersistedWallRecord -> Either WallModelError ()
validatePersistedRecord record
  | ByteString.null (persistedOwnerIdentity record) =
      invalid "persisted owner identity is empty"
  | ByteString.null (persistedSpecIdentity record) =
      invalid "persisted specification identity is empty"
  | ByteString.null (persistedReservationIdentity record) =
      invalid "persisted reservation identity is empty"
  | ByteString.null (persistedReceiptIdentity record) =
      invalid "persisted receipt identity is empty"
  | persistedFenceValue record == 0 =
      invalid "persisted fence is zero"
  | otherwise =
      case persistedWallPhase record of
        WallClaimed ->
          requireShape Nothing Nothing Nothing
        WallOriginRecorded ->
          requireOriginWithoutTarget
        WallStageCreateOutcomeUnknown ->
          requireStageCreateIntent
        WallStageBound ->
          requireOriginAndTarget
        WallApplyOutcomeUnknown ->
          requireOriginAndTarget
        WallApplied ->
          requireOriginAndTarget
        WallRestoreOutcomeUnknown ->
          requireOriginAndTarget
        WallRestored ->
          requireOriginAndTarget
        WallReleased ->
          requireOriginAndTarget
  where
    invalid = Left . InvalidWallJournal
    requireShape expectedOrigin expectedCandidate expectedTarget
      | persistedWallOrigin record /= expectedOrigin =
          invalid "persisted origin is incompatible with the journal phase"
      | persistedStageCandidate record /= expectedCandidate =
          invalid "persisted stage candidate is incompatible with the journal phase"
      | persistedTargetIdentity record /= expectedTarget =
          invalid "persisted target identity is incompatible with the journal phase"
      | otherwise = Right ()
    requireOriginWithoutTarget =
      case persistedWallOrigin record of
        Nothing -> invalid "origin-recorded phase has no durable origin"
        Just _
          | persistedStageCandidate record /= Nothing ->
              invalid "origin-recorded phase already carries a stage candidate"
          | persistedTargetIdentity record /= Nothing ->
              invalid "origin-recorded phase already carries a target identity"
          | otherwise -> Right ()
    requireStageCreateIntent =
      case (persistedWallOrigin record, persistedStageCandidate record) of
        (Nothing, _) ->
          invalid "stage-create phase has no durable origin"
        (_, Nothing) ->
          invalid "stage-create phase has no durable candidate identity"
        (_, Just candidate)
          | ByteString.null candidate ->
              invalid "stage-create phase has an empty candidate identity"
          | persistedTargetIdentity record /= Nothing ->
              invalid "stage-create phase already carries a target identity"
          | otherwise -> Right ()
    requireOriginAndTarget =
      case
          ( persistedWallOrigin record,
            persistedStageCandidate record,
            persistedTargetIdentity record
          )
        of
        (Nothing, _, _) -> invalid "post-origin phase has no durable origin"
        (_, Nothing, _) -> invalid "post-origin phase has no durable stage candidate"
        (_, Just candidate, _)
          | ByteString.null candidate ->
              invalid "post-origin phase has an empty stage candidate"
        (_, _, Nothing) -> invalid "post-origin phase has no target identity"
        (Just OriginalAbsent, Just _, Just _) -> Right ()
        (Just (OriginalPresent originalIdentity _), Just _, Just targetIdentity)
          | originalIdentity /= targetIdentity -> Right ()
          | otherwise ->
              invalid
                "an originally present .wslconfig requires a distinct staged desired-object identity"

revalidateActiveReceipt ::
  PersistedWallRecord ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  Either WallModelError ()
revalidateActiveReceipt active (WallReceipt expected) = do
  validatePersistedRecord active
  validatePersistedRecord expected
  if persistedFenceValue expected /= persistedFenceValue active
    then
      Left
        ( WallConflictError
            ( StaleWallFence
                (persistedFenceValue expected)
                (persistedFenceValue active)
            )
        )
    else Right ()
  validateStableIdentity expected active
  if stablePayload expected /= stablePayload active
    then
      Left
        ( InvalidWallJournal
            "active record payload differs from the receipt under the same identity and fence"
        )
    else Right ()
  if persistedWallPhase expected /= persistedWallPhase active
    then
      Left
        ( WallConflictError
            ( StaleWallReceipt
                (persistedWallPhase expected)
                (persistedWallPhase active)
            )
        )
    else Right ()

revalidateAuthority ::
  PersistedWallRecord ->
  WallAuthority ownerId wallSpecId reservationId receiptId fenceId ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  Either WallModelError ()
revalidateAuthority active (WallAuthority authorityRecord) receipt = do
  revalidateActiveReceipt active receipt
  if persistedFenceValue authorityRecord /= persistedFenceValue active
    then
      Left
        ( WallConflictError
            ( StaleWallFence
                (persistedFenceValue authorityRecord)
                (persistedFenceValue active)
            )
        )
    else Right ()
  validateStableIdentity authorityRecord active
  if stablePayload authorityRecord /= stablePayload active
    then
      Left
        ( InvalidWallJournal
            "active record payload no longer matches the authority"
        )
    else Right ()

validateStableIdentity ::
  PersistedWallRecord ->
  PersistedWallRecord ->
  Either WallModelError ()
validateStableIdentity expected observed
  | persistedOwnerIdentity expected /= persistedOwnerIdentity observed =
      conflict
        ( ForeignWallOwner
            (persistedOwnerIdentity expected)
            (persistedOwnerIdentity observed)
        )
  | persistedSpecIdentity expected /= persistedSpecIdentity observed =
      conflict
        ( IncompatibleWallSpec
            (persistedSpecIdentity expected)
            (persistedSpecIdentity observed)
        )
  | persistedReservationIdentity expected /= persistedReservationIdentity observed =
      conflict
        ( ForeignWallReservation
            (persistedReservationIdentity expected)
            (persistedReservationIdentity observed)
        )
  | persistedReceiptIdentity expected /= persistedReceiptIdentity observed =
      conflict
        ( ForeignWallReceipt
            (persistedReceiptIdentity expected)
            (persistedReceiptIdentity observed)
        )
  | otherwise = Right ()
  where
    conflict = Left . WallConflictError

stablePayload ::
  PersistedWallRecord ->
  ( ByteString,
    Maybe WslConfigOrigin,
    Maybe ByteString,
    Maybe FileIdentity
  )
stablePayload record =
  ( persistedDesiredBytes record,
    persistedWallOrigin record,
    persistedStageCandidate record,
    persistedTargetIdentity record
  )

validateApplyTarget ::
  PersistedWallRecord ->
  FileIdentity ->
  Either WallModelError ()
validateApplyTarget record targetIdentity =
  case persistedWallOrigin record of
    Just OriginalAbsent -> Right ()
    Just (OriginalPresent originalIdentity _)
      | originalIdentity /= targetIdentity -> Right ()
      | otherwise ->
          Left
            (WallConflictError (InPlaceMutationUnsupported originalIdentity))
    Nothing ->
      Left
        ( InvalidWallJournal
            "apply target cannot be bound before the durable origin exists"
        )

validatePreparedApply ::
  PersistedWallRecord ->
  ApplyObservation ->
  FileIdentity ->
  Either WallModelError ()
validatePreparedApply record observation targetIdentity = do
  validateApplyTarget record targetIdentity
  case persistedWallOrigin record of
    Nothing ->
      Left
        ( InvalidWallJournal
            "prepared apply has no durable origin"
        )
    Just origin
      | not (observesOrigin origin (applyTargetObservation observation)) ->
          Left
            ( WallConflictError
                (unexpectedFromOriginOnly origin (applyTargetObservation observation))
            )
      | not (observesDesired record targetIdentity (applyStagedObservation observation)) ->
          Left
            ( WallConflictError
                (unexpectedFromExpected targetIdentity (applyStagedObservation observation))
            )
      | applyRetainedOriginObservation observation /= ObservedAbsent ->
          Left
            ( WallConflictError
                (unexpectedAbsentObservation (applyRetainedOriginObservation observation))
            )
      | otherwise -> Right ()

requireJournaledTarget ::
  PersistedWallRecord ->
  FileIdentity ->
  Either WallModelError ()
requireJournaledTarget record proposedIdentity =
  case persistedTargetIdentity record of
    Nothing ->
      Left
        ( InvalidWallJournal
            "apply outcome-unknown phase has no journaled target identity"
        )
    Just expectedIdentity
      | expectedIdentity == proposedIdentity -> Right ()
      | otherwise ->
          Left
            ( WallConflictError
                (TargetReplaced expectedIdentity proposedIdentity)
            )

classifyOriginForApply ::
  WslConfigOrigin ->
  ApplyObservation ->
  ApplyClassification
classifyOriginForApply origin observation
  | not (observesOrigin origin (applyTargetObservation observation)) =
      ApplyBlocked
        (unexpectedFromOriginOnly origin (applyTargetObservation observation))
  | applyStagedObservation observation /= ObservedAbsent =
      ApplyBlocked
        (unexpectedAbsentObservation (applyStagedObservation observation))
  | applyRetainedOriginObservation observation /= ObservedAbsent =
      ApplyBlocked
        (unexpectedAbsentObservation (applyRetainedOriginObservation observation))
  | otherwise = ApplyRetryFromOrigin

classifyApplyingRecord ::
  PersistedWallRecord ->
  ApplyObservation ->
  ApplyClassification ->
  ApplyClassification
classifyApplyingRecord record observation appliedClassification =
  case (persistedWallOrigin record, persistedTargetIdentity record) of
    (Just origin, Just targetIdentity)
      | observesAppliedLayout record origin targetIdentity observation ->
          appliedClassification
      | persistedWallPhase record == WallApplyOutcomeUnknown
          && observesPreparedLayout record origin targetIdentity observation ->
          ApplyRetryPublication
      | otherwise ->
          ApplyBlocked
            (unexpectedApplyLayout record origin targetIdentity observation)
    _ -> ApplyNotInProgress (persistedWallPhase record)

classifyAppliedForRestore ::
  PersistedWallRecord ->
  RestoreObservation ->
  RestoreClassification
classifyAppliedForRestore record observation =
  case (persistedWallOrigin record, persistedTargetIdentity record) of
    (Just origin, Just targetIdentity)
      | observesAppliedRestoreLayout record origin targetIdentity observation ->
          RestoreRetryFromApplied
      | otherwise ->
          RestoreBlocked
            (unexpectedRestoreLayout record origin targetIdentity observation)
    _ -> RestoreNotInProgress (persistedWallPhase record)

classifyRestoringRecord ::
  PersistedWallRecord ->
  RestoreObservation ->
  RestoreClassification
classifyRestoringRecord record observation =
  case (persistedWallOrigin record, persistedTargetIdentity record) of
    (Just origin, Just targetIdentity)
      | observesRestoredLayout origin observation ->
          RestoreObservedOrigin
      | observesAppliedRestoreLayout record origin targetIdentity observation ->
          RestoreRetryFromApplied
      | observesOriginPublicationLayout record origin targetIdentity observation ->
          RestoreRetryOriginPublication
      | observesManagedCleanupLayout record origin targetIdentity observation ->
          RestoreRetryManagedCleanup
      | otherwise ->
          RestoreBlocked
            (unexpectedRestoreLayout record origin targetIdentity observation)
    _ -> RestoreNotInProgress (persistedWallPhase record)

classifyRestoredRecord ::
  PersistedWallRecord ->
  RestoreObservation ->
  RestoreClassification
classifyRestoredRecord record observation =
  case (persistedWallOrigin record, persistedTargetIdentity record) of
    (Just origin, Just targetIdentity)
      | observesRestoredLayout origin observation -> RestoreAlreadyRestored
      | otherwise ->
          RestoreBlocked
            (unexpectedRestoreLayout record origin targetIdentity observation)
    _ -> RestoreNotInProgress (persistedWallPhase record)

observesOrigin :: WslConfigOrigin -> WallObservation -> Bool
observesOrigin OriginalAbsent ObservedAbsent = True
observesOrigin (OriginalPresent expectedIdentity expectedBytes) (ObservedPresent observedIdentity observedBytes) =
  expectedIdentity == observedIdentity && expectedBytes == observedBytes
observesOrigin _ _ = False

observesDesired ::
  PersistedWallRecord ->
  FileIdentity ->
  WallObservation ->
  Bool
observesDesired record expectedIdentity observation =
  case observation of
    ObservedAbsent -> False
    ObservedPresent observedIdentity observedBytes ->
      expectedIdentity == observedIdentity
        && persistedDesiredBytes record == observedBytes

observesPreparedLayout ::
  PersistedWallRecord ->
  WslConfigOrigin ->
  FileIdentity ->
  ApplyObservation ->
  Bool
observesPreparedLayout record origin targetIdentity observation =
  observesDesired record targetIdentity (applyStagedObservation observation)
    && case origin of
      OriginalAbsent ->
        applyTargetObservation observation == ObservedAbsent
          && applyRetainedOriginObservation observation == ObservedAbsent
      OriginalPresent _ _ ->
        ( observesOrigin origin (applyTargetObservation observation)
            && applyRetainedOriginObservation observation == ObservedAbsent
        )
          || ( applyTargetObservation observation == ObservedAbsent
                 && observesOrigin
                   origin
                   (applyRetainedOriginObservation observation)
             )

observesAppliedLayout ::
  PersistedWallRecord ->
  WslConfigOrigin ->
  FileIdentity ->
  ApplyObservation ->
  Bool
observesAppliedLayout record origin targetIdentity observation =
  observesDesired record targetIdentity (applyTargetObservation observation)
    && applyStagedObservation observation == ObservedAbsent
    && observesRetainedOrigin
      origin
      (applyRetainedOriginObservation observation)

observesAppliedRestoreLayout ::
  PersistedWallRecord ->
  WslConfigOrigin ->
  FileIdentity ->
  RestoreObservation ->
  Bool
observesAppliedRestoreLayout record origin targetIdentity observation =
  observesDesired record targetIdentity (restoreTargetObservation observation)
    && observesRetainedOrigin
      origin
      (restoreRetainedOriginObservation observation)
    && restoreRetiredManagedObservation observation == ObservedAbsent

observesManagedCleanupLayout ::
  PersistedWallRecord ->
  WslConfigOrigin ->
  FileIdentity ->
  RestoreObservation ->
  Bool
observesManagedCleanupLayout record origin targetIdentity observation =
  case origin of
    OriginalAbsent -> False
    OriginalPresent _ _ ->
      observesOrigin origin (restoreTargetObservation observation)
        && restoreRetainedOriginObservation observation == ObservedAbsent
        && observesDesired
          record
          targetIdentity
          (restoreRetiredManagedObservation observation)

observesOriginPublicationLayout ::
  PersistedWallRecord ->
  WslConfigOrigin ->
  FileIdentity ->
  RestoreObservation ->
  Bool
observesOriginPublicationLayout record origin targetIdentity observation =
  case origin of
    OriginalAbsent -> False
    OriginalPresent _ _ ->
      restoreTargetObservation observation == ObservedAbsent
        && observesOrigin
          origin
          (restoreRetainedOriginObservation observation)
        && observesDesired
          record
          targetIdentity
          (restoreRetiredManagedObservation observation)

observesRestoredLayout ::
  WslConfigOrigin ->
  RestoreObservation ->
  Bool
observesRestoredLayout origin observation =
  observesOrigin origin (restoreTargetObservation observation)
    && restoreRetainedOriginObservation observation == ObservedAbsent
    && restoreRetiredManagedObservation observation == ObservedAbsent

observesRetainedOrigin ::
  WslConfigOrigin ->
  WallObservation ->
  Bool
observesRetainedOrigin OriginalAbsent ObservedAbsent = True
observesRetainedOrigin origin@(OriginalPresent _ _) observation =
  observesOrigin origin observation
observesRetainedOrigin _ _ = False

originConflict ::
  Maybe WslConfigOrigin ->
  WslConfigOrigin ->
  WallConflict
originConflict Nothing proposed =
  case proposed of
    OriginalAbsent -> OriginStateChanged
    OriginalPresent identity _ -> UnexpectedTargetPresent identity
originConflict (Just OriginalAbsent) (OriginalPresent identity _) =
  UnexpectedTargetPresent identity
originConflict (Just (OriginalPresent identity _)) OriginalAbsent =
  UnexpectedTargetAbsent identity
originConflict
  (Just (OriginalPresent expectedIdentity _))
  (OriginalPresent observedIdentity _)
    | expectedIdentity /= observedIdentity =
        TargetReplaced expectedIdentity observedIdentity
    | otherwise = TargetAmbiguous expectedIdentity
originConflict (Just OriginalAbsent) OriginalAbsent =
  OriginStateChanged

unexpectedApplyLayout ::
  PersistedWallRecord ->
  WslConfigOrigin ->
  FileIdentity ->
  ApplyObservation ->
  WallConflict
unexpectedApplyLayout record origin targetIdentity observation
  | observesDesired record targetIdentity (applyTargetObservation observation) =
      if applyStagedObservation observation /= ObservedAbsent
        then unexpectedFromExpected targetIdentity (applyStagedObservation observation)
        else
          unexpectedRetainedOrigin
            origin
            (applyRetainedOriginObservation observation)
  | observesOrigin origin (applyTargetObservation observation) =
      if not (observesDesired record targetIdentity (applyStagedObservation observation))
        then unexpectedFromExpected targetIdentity (applyStagedObservation observation)
        else
          unexpectedAbsentObservation
            (applyRetainedOriginObservation observation)
  | otherwise =
      unexpectedTargetLayout
        origin
        targetIdentity
        (applyTargetObservation observation)

unexpectedRestoreLayout ::
  PersistedWallRecord ->
  WslConfigOrigin ->
  FileIdentity ->
  RestoreObservation ->
  WallConflict
unexpectedRestoreLayout record origin targetIdentity observation
  | observesDesired record targetIdentity (restoreTargetObservation observation) =
      if not
        ( observesRetainedOrigin
            origin
            (restoreRetainedOriginObservation observation)
        )
        then
          unexpectedRetainedOrigin
            origin
            (restoreRetainedOriginObservation observation)
        else
          unexpectedAbsentObservation
            (restoreRetiredManagedObservation observation)
  | observesOrigin origin (restoreTargetObservation observation) =
      if restoreRetainedOriginObservation observation /= ObservedAbsent
        then
          unexpectedAbsentObservation
            (restoreRetainedOriginObservation observation)
        else
          unexpectedFromExpected
            targetIdentity
            (restoreRetiredManagedObservation observation)
  | otherwise =
      unexpectedTargetLayout
        origin
        targetIdentity
        (restoreTargetObservation observation)

unexpectedTargetLayout ::
  WslConfigOrigin ->
  FileIdentity ->
  WallObservation ->
  WallConflict
unexpectedTargetLayout origin targetIdentity observation =
  case observation of
    ObservedAbsent ->
      case origin of
        OriginalAbsent -> UnexpectedTargetAbsent targetIdentity
        OriginalPresent originalIdentity _ ->
          UnexpectedTargetAbsent originalIdentity
    ObservedPresent observedIdentity _
      | observedIdentity == targetIdentity ->
          TargetAmbiguous targetIdentity
      | isOriginalIdentity origin observedIdentity ->
          TargetAmbiguous observedIdentity
      | otherwise -> TargetReplaced targetIdentity observedIdentity

isOriginalIdentity :: WslConfigOrigin -> FileIdentity -> Bool
isOriginalIdentity OriginalAbsent _ = False
isOriginalIdentity (OriginalPresent originalIdentity _) observedIdentity =
  originalIdentity == observedIdentity

unexpectedRetainedOrigin ::
  WslConfigOrigin ->
  WallObservation ->
  WallConflict
unexpectedRetainedOrigin OriginalAbsent observation =
  unexpectedAbsentObservation observation
unexpectedRetainedOrigin (OriginalPresent originalIdentity _) observation =
  case observation of
    ObservedAbsent -> UnexpectedTargetAbsent originalIdentity
    ObservedPresent observedIdentity _
      | observedIdentity /= originalIdentity ->
          TargetReplaced originalIdentity observedIdentity
      | otherwise -> TargetAmbiguous originalIdentity

unexpectedAbsentObservation :: WallObservation -> WallConflict
unexpectedAbsentObservation ObservedAbsent = OriginStateChanged
unexpectedAbsentObservation (ObservedPresent observedIdentity _) =
  UnexpectedTargetPresent observedIdentity

unexpectedFromExpected ::
  FileIdentity ->
  WallObservation ->
  WallConflict
unexpectedFromExpected expectedIdentity observation =
  case observation of
    ObservedAbsent -> UnexpectedTargetAbsent expectedIdentity
    ObservedPresent observedIdentity _
      | expectedIdentity /= observedIdentity ->
          TargetReplaced expectedIdentity observedIdentity
      | otherwise -> TargetAmbiguous expectedIdentity

unexpectedFromOriginOnly ::
  WslConfigOrigin ->
  WallObservation ->
  WallConflict
unexpectedFromOriginOnly OriginalAbsent observation =
  case observation of
    ObservedAbsent -> OriginStateChanged
    ObservedPresent observedIdentity _ ->
      UnexpectedTargetPresent observedIdentity
unexpectedFromOriginOnly (OriginalPresent expectedIdentity _) observation =
  case observation of
    ObservedAbsent -> UnexpectedTargetAbsent expectedIdentity
    ObservedPresent observedIdentity _
      | expectedIdentity /= observedIdentity ->
          TargetReplaced expectedIdentity observedIdentity
      | otherwise -> TargetAmbiguous expectedIdentity
