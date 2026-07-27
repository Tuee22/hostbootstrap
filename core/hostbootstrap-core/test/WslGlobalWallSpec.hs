{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module WslGlobalWallSpec (tests) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Word (Word64)
import HostBootstrap.Wsl2.GlobalWall
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit
  ( Assertion,
    assertFailure,
    testCase,
    (@?=),
  )

desiredBytes :: ByteString
desiredBytes =
  "[general]\r\ninstanceIdleTimeout=-1\r\n[wsl2]\r\nprocessors=4\r\n"

originalBytes :: ByteString
originalBytes =
  ByteString.pack [0xEF, 0xBB, 0xBF]
    <> "[experimental]\r\nsparseVhd=true\r\n"
    <> ByteString.pack [0x00, 0xFF]

tests :: TestTree
tests =
  testGroup
    "WslGlobalWallSpec"
    [ testCase "opaque identity admission rejects empty identities and a zero fence" $ do
        withWallOwner "" (const ()) @?= Left (InvalidWallIdentity "wall owner identity must not be empty")
        withWallSpec "" desiredBytes (const ())
          @?= Left (InvalidWallIdentity "wall specification identity must not be empty")
        withWallFence 0 (const ()) @?= Left (InvalidWallFence 0)
        mkFileIdentity "" @?= Left (InvalidWallIdentity "file identity must not be empty"),
      testCase "present origin survives apply and restore byte-for-byte" $
        runReservation 11 "owner-a" "spec-a" "reservation-a" "receipt-a" $ \reservation -> do
          originalIdentity <- expectRight (mkFileIdentity "volume-7:file-42")
          managedIdentity <- expectRight (mkFileIdentity "volume-7:file-43")
          applying <-
            expectRight
              ( prepareApplying
                  reservation
                  (OriginalPresent originalIdentity originalBytes)
                  (ObservedPresent originalIdentity originalBytes)
                  managedIdentity
              )
          persistedWallOrigin (wallReceiptRecord applying)
            @?= Just (OriginalPresent originalIdentity originalBytes)
          persistedWallPhase (wallReceiptRecord applying)
            @?= WallApplyOutcomeUnknown
          applied <-
            expectRight
              ( settleWallApply
                  (wallReceiptRecord applying)
                  applying
                  ( appliedObservation
                      (OriginalPresent originalIdentity originalBytes)
                      managedIdentity
                  )
              )
          runAuthority (wallReceiptRecord applied) applied $ \authority -> do
            restoring <-
              expectRight
                ( beginWallRestore
                    (wallReceiptRecord applied)
                    authority
                    applied
                    ( restoreAppliedObservation
                        (OriginalPresent originalIdentity originalBytes)
                        managedIdentity
                    )
                )
            classifyWallRestore
              restoring
              ( restoreCleanupObservation
                  (OriginalPresent originalIdentity originalBytes)
                  managedIdentity
              )
              @?= RestoreRetryManagedCleanup
            restored <-
              expectRight
                ( settleWallRestore
                    (wallReceiptRecord restoring)
                    authority
                    restoring
                    (restoredObservation (OriginalPresent originalIdentity originalBytes))
                )
            released <-
              expectRight
                ( releaseWall
                    (wallReceiptRecord restored)
                    authority
                    restored
                    (restoredObservation (OriginalPresent originalIdentity originalBytes))
                )
            persistedWallPhase (wallReceiptRecord released) @?= WallReleased
            persistedWallOrigin (wallReceiptRecord released)
              @?= Just (OriginalPresent originalIdentity originalBytes)
            verifyWallReleased
              (wallReceiptRecord released)
              released
              (restoredObservation (OriginalPresent originalIdentity originalBytes))
              @?= Right (),
      testCase "absent origin is durable and teardown requires exact absence" $
        runReservation 12 "owner-a" "spec-a" "reservation-b" "receipt-b" $ \reservation -> do
          createdIdentity <- expectRight (mkFileIdentity "volume-7:file-99")
          applying <-
            expectRight
              ( prepareApplying
                  reservation
                  OriginalAbsent
                  ObservedAbsent
                  createdIdentity
              )
          persistedWallOrigin (wallReceiptRecord applying)
            @?= Just OriginalAbsent
          applied <-
            expectRight
              ( settleWallApply
                  (wallReceiptRecord applying)
                  applying
                  (appliedObservation OriginalAbsent createdIdentity)
              )
          runAuthority (wallReceiptRecord applied) applied $ \authority -> do
            restoring <-
              expectRight
                ( beginWallRestore
                    (wallReceiptRecord applied)
                    authority
                    applied
                    (restoreAppliedObservation OriginalAbsent createdIdentity)
                )
            classifyWallRestore restoring (restoredObservation OriginalAbsent)
              @?= RestoreObservedOrigin
            restored <-
              expectRight
                ( settleWallRestore
                    (wallReceiptRecord restoring)
                    authority
                    restoring
                    (restoredObservation OriginalAbsent)
                )
            released <-
              expectRight
                ( releaseWall
                    (wallReceiptRecord restored)
                    authority
                    restored
                    (restoredObservation OriginalAbsent)
                )
            persistedWallPhase (wallReceiptRecord released) @?= WallReleased
            persistedWallOrigin (wallReceiptRecord released)
              @?= Just OriginalAbsent,
      testCase "apply recovery is total for original, desired, replaced, absent, and ambiguous observations" $
        runReservation 21 "owner-a" "spec-a" "reservation-c" "receipt-c" $ \reservation -> do
          originalIdentity <- expectRight (mkFileIdentity "volume-7:file-100")
          managedIdentity <- expectRight (mkFileIdentity "volume-7:file-101")
          foreignIdentity <- expectRight (mkFileIdentity "volume-7:file-102")
          let origin = OriginalPresent originalIdentity originalBytes
          applying <-
            expectRight
              ( prepareApplying
                  reservation
                  origin
                  (ObservedPresent originalIdentity originalBytes)
                  managedIdentity
              )
          classifyWallApply
            applying
            (preparedObservation origin managedIdentity)
            @?= ApplyRetryPublication
          classifyWallApply applying (appliedObservation origin managedIdentity)
            @?= ApplyObservedDesired
          classifyWallApply
            applying
            ( ApplyObservation
                (ObservedPresent foreignIdentity desiredBytes)
                ObservedAbsent
                (ObservedPresent originalIdentity originalBytes)
            )
            @?= ApplyBlocked (TargetReplaced managedIdentity foreignIdentity)
          classifyWallApply
            applying
            ( ApplyObservation
                (ObservedPresent originalIdentity originalBytes)
                (ObservedPresent managedIdentity "partial-write")
                ObservedAbsent
            )
            @?= ApplyBlocked (TargetAmbiguous managedIdentity)
          classifyWallApply
            applying
            (ApplyObservation ObservedAbsent ObservedAbsent ObservedAbsent)
            @?= ApplyBlocked (UnexpectedTargetAbsent originalIdentity),
      testCase "absent-origin recovery retains the journaled staged-object identity" $
        runReservation 23 "owner-a" "spec-a" "reservation-stage" "receipt-stage" $ \reservation -> do
          stagedIdentity <- expectRight (mkFileIdentity "volume-7:file-110")
          replacementIdentity <- expectRight (mkFileIdentity "volume-7:file-111")
          applying <-
            expectRight
              ( prepareApplying
                  reservation
                  OriginalAbsent
                  ObservedAbsent
                  stagedIdentity
              )
          let stagedReady = preparedObservation OriginalAbsent stagedIdentity
          classifyWallApply applying stagedReady
            @?= ApplyRetryPublication
          resumed <-
            expectRight
              ( beginWallApply
                  (wallReceiptRecord applying)
                  applying
                  stagedReady
                  stagedIdentity
              )
          persistedTargetIdentity (wallReceiptRecord resumed)
            @?= Just stagedIdentity
          assertLeft
            (WallConflictError (TargetReplaced stagedIdentity replacementIdentity))
            ( beginWallApply
                (wallReceiptRecord applying)
                applying
                stagedReady
                replacementIdentity
            )
          classifyWallApply
            applying
            ( ApplyObservation
                ObservedAbsent
                (ObservedPresent replacementIdentity desiredBytes)
                ObservedAbsent
            )
            @?= ApplyBlocked (TargetReplaced stagedIdentity replacementIdentity)
          classifyWallApply
            applying
            (ApplyObservation ObservedAbsent ObservedAbsent ObservedAbsent)
            @?= ApplyBlocked (UnexpectedTargetAbsent stagedIdentity)
          classifyWallApply applying (appliedObservation OriginalAbsent stagedIdentity)
            @?= ApplyObservedDesired,
      testCase "armed-stage binding closes every durable-link crash gap" $
        runReservation 25 "owner-a" "spec-a" "reservation-create" "receipt-create" $ \reservation -> do
          unboundIdentity <- expectRight (mkFileIdentity "volume-7:file-113")
          reboundIdentity <- expectRight (mkFileIdentity "volume-7:file-114")
          claimed <- expectRight (claimOrResumeWall reservation Nothing)
          withOrigin <-
            expectRight
              ( recordWallOrigin
                  (wallReceiptRecord claimed)
                  claimed
                  OriginalAbsent
              )
          creating <-
            expectRight
              ( beginWallStageCreation
                  (wallReceiptRecord withOrigin)
                  withOrigin
                  "candidate-a"
              )
          persistedWallPhase (wallReceiptRecord creating)
            @?= WallStageCreateOutcomeUnknown
          persistedStageCandidate (wallReceiptRecord creating)
            @?= Just "candidate-a"
          classifyWallStageCreation creating ObservedAbsent
            @?= StageCreateRetry
          classifyWallStageCreation
            creating
            (ObservedPresent unboundIdentity desiredBytes)
            @?= StageCreateBlocked (UnboundStagePresent unboundIdentity)
          bound <-
            expectRight
              ( bindWallStage
                  (wallReceiptRecord creating)
                  creating
                  ObservedAbsent
                  unboundIdentity
              )
          persistedWallPhase (wallReceiptRecord bound)
            @?= WallStageBound
          persistedTargetIdentity (wallReceiptRecord bound)
            @?= Just unboundIdentity
          classifyWallStageCreation bound ObservedAbsent
            @?= StageCreateRetry
          rebound <-
            expectRight
              ( bindWallStage
                  (wallReceiptRecord bound)
                  bound
                  ObservedAbsent
                  reboundIdentity
              )
          persistedTargetIdentity (wallReceiptRecord rebound)
            @?= Just reboundIdentity
          classifyWallStageCreation
            rebound
            (ObservedPresent reboundIdentity desiredBytes)
            @?= StageCreateObservedBound
          classifyWallStageCreation
            rebound
            (ObservedPresent unboundIdentity desiredBytes)
            @?= StageCreateBlocked
              (TargetReplaced reboundIdentity unboundIdentity)
          assertLeft
            ( InvalidWallJournal
                "stage-create retry proposed a different candidate identity"
            )
            ( beginWallStageCreation
                (wallReceiptRecord creating)
                creating
                "candidate-b"
            ),
      testCase "present origin refuses a torn-write-prone in-place target identity" $
        runReservation 24 "owner-a" "spec-a" "reservation-atomic" "receipt-atomic" $ \reservation -> do
          originalIdentity <- expectRight (mkFileIdentity "volume-7:file-112")
          claimed <- expectRight (claimOrResumeWall reservation Nothing)
          withOrigin <-
            expectRight
              ( recordWallOrigin
                  (wallReceiptRecord claimed)
                  claimed
                  (OriginalPresent originalIdentity originalBytes)
              )
          creating <-
            expectRight
              ( beginWallStageCreation
                  (wallReceiptRecord withOrigin)
                  withOrigin
                  "candidate-in-place"
              )
          assertLeft
            (WallConflictError (InPlaceMutationUnsupported originalIdentity))
            ( bindWallStage
                (wallReceiptRecord creating)
                creating
                ObservedAbsent
                originalIdentity
            ),
      testCase "restore recovery retries only the exact applied object and refuses foreign or ambiguous state" $
        runReservation 22 "owner-a" "spec-a" "reservation-d" "receipt-d" $ \reservation -> do
          originalIdentity <- expectRight (mkFileIdentity "volume-7:file-103")
          managedIdentity <- expectRight (mkFileIdentity "volume-7:file-104")
          foreignIdentity <- expectRight (mkFileIdentity "volume-7:file-105")
          let origin = OriginalPresent originalIdentity originalBytes
          applied <-
            expectRight
              ( prepareApplied
                  reservation
                  origin
                  (ObservedPresent originalIdentity originalBytes)
                  managedIdentity
                  (ObservedPresent managedIdentity desiredBytes)
              )
          runAuthority (wallReceiptRecord applied) applied $ \authority -> do
            restoring <-
              expectRight
                ( beginWallRestore
                    (wallReceiptRecord applied)
                    authority
                    applied
                    (restoreAppliedObservation origin managedIdentity)
                )
            classifyWallRestore
              restoring
              (restoreAppliedObservation origin managedIdentity)
              @?= RestoreRetryFromApplied
            classifyWallRestore
              restoring
              (restoreOriginPublicationObservation origin managedIdentity)
              @?= RestoreRetryOriginPublication
            classifyWallRestore restoring (restoredObservation origin)
              @?= RestoreObservedOrigin
            classifyWallRestore
              restoring
              (restoreCleanupObservation origin managedIdentity)
              @?= RestoreRetryManagedCleanup
            classifyWallRestore
              restoring
              ( RestoreObservation
                  (ObservedPresent foreignIdentity originalBytes)
                  ObservedAbsent
                  ObservedAbsent
              )
              @?= RestoreBlocked (TargetReplaced managedIdentity foreignIdentity)
            classifyWallRestore
              restoring
              ( RestoreObservation
                  (ObservedPresent managedIdentity "operator-edit")
                  (ObservedPresent originalIdentity originalBytes)
                  ObservedAbsent
              )
              @?= RestoreBlocked (TargetAmbiguous managedIdentity)
            classifyWallRestore
              restoring
              (RestoreObservation ObservedAbsent ObservedAbsent ObservedAbsent)
              @?= RestoreBlocked (UnexpectedTargetAbsent originalIdentity),
      testCase "present-origin apply classifies every atomic publication fault point" $
        runReservation 26 "owner-a" "spec-a" "reservation-fault" "receipt-fault" $ \reservation -> do
          originalIdentity <- expectRight (mkFileIdentity "volume-7:file-114")
          managedIdentity <- expectRight (mkFileIdentity "volume-7:file-115")
          let origin = OriginalPresent originalIdentity originalBytes
          applying <-
            expectRight
              ( prepareApplying
                  reservation
                  origin
                  (ObservedPresent originalIdentity originalBytes)
                  managedIdentity
              )
          classifyWallApply applying (preparedObservation origin managedIdentity)
            @?= ApplyRetryPublication
          classifyWallApply
            applying
            (applyOriginQuarantinedObservation origin managedIdentity)
            @?= ApplyRetryPublication
          classifyWallApply applying (appliedObservation origin managedIdentity)
            @?= ApplyObservedDesired,
      testCase "retry hydrates the exact durable origin instead of inferring it from a path" $
        runReservation 31 "owner-a" "spec-a" "reservation-e" "receipt-e" $ \reservation -> do
          fileIdentity <- expectRight (mkFileIdentity "volume-7:file-104")
          claimed <- expectRight (claimOrResumeWall reservation Nothing)
          withOrigin <-
            expectRight
              ( recordWallOrigin
                  (wallReceiptRecord claimed)
                  claimed
                  (OriginalPresent fileIdentity originalBytes)
              )
          resumed <-
            expectRight
              ( claimOrResumeWall
                  reservation
                  (Just (wallReceiptRecord withOrigin))
              )
          wallReceiptRecord resumed @?= wallReceiptRecord withOrigin
          persistedWallOrigin (wallReceiptRecord resumed)
            @?= Just (OriginalPresent fileIdentity originalBytes),
      testCase "a different owner conflicts even when it requests the same-shaped wall" $
        runReservation 41 "owner-a" "spec-a" "reservation-f" "receipt-f" $ \firstReservation -> do
          first <- expectRight (claimOrResumeWall firstReservation Nothing)
          runReservation 42 "owner-b" "spec-a" "reservation-g" "receipt-g" $ \secondReservation ->
            assertLeft
              ( WallConflictError
                  (ForeignWallOwner "owner-b" "owner-a")
              )
              (claimOrResumeWall secondReservation (Just (wallReceiptRecord first))),
      testCase "a replaced absent-origin target is never deleted or restored" $
        runReservation 51 "owner-a" "spec-a" "reservation-h" "receipt-h" $ \reservation -> do
          createdIdentity <- expectRight (mkFileIdentity "volume-7:file-105")
          foreignIdentity <- expectRight (mkFileIdentity "volume-7:file-106")
          applied <-
            expectRight
              ( prepareApplied
                  reservation
                  OriginalAbsent
                  ObservedAbsent
                  createdIdentity
                  (ObservedPresent createdIdentity desiredBytes)
              )
          runAuthority (wallReceiptRecord applied) applied $ \authority ->
            assertLeft
              ( WallConflictError
                  (TargetReplaced createdIdentity foreignIdentity)
              )
              ( beginWallRestore
                  (wallReceiptRecord applied)
                  authority
                  applied
                  ( RestoreObservation
                      (ObservedPresent foreignIdentity desiredBytes)
                      ObservedAbsent
                      ObservedAbsent
                  )
              ),
      testCase "an old authority refuses a newer active fence before restoration" $
        runReservation 61 "owner-a" "spec-a" "reservation-i" "receipt-i" $ \oldReservation -> do
          originalIdentity <- expectRight (mkFileIdentity "volume-7:file-107")
          managedIdentity <- expectRight (mkFileIdentity "volume-7:file-108")
          let origin = OriginalPresent originalIdentity originalBytes
          oldApplied <-
            expectRight
              ( prepareApplied
                  oldReservation
                  origin
                  (ObservedPresent originalIdentity originalBytes)
                  managedIdentity
                  (ObservedPresent managedIdentity desiredBytes)
              )
          runAuthority (wallReceiptRecord oldApplied) oldApplied $ \oldAuthority ->
            runReservation 62 "owner-a" "spec-a" "reservation-j" "receipt-j" $ \newReservation -> do
              newClaimed <- expectRight (claimOrResumeWall newReservation Nothing)
              assertLeft
                (WallConflictError (StaleWallFence 61 62))
                ( beginWallRestore
                    (wallReceiptRecord newClaimed)
                    oldAuthority
                    oldApplied
                    (restoreAppliedObservation origin managedIdentity)
                ),
      testCase "malformed durable phase data cannot mint a receipt or authority" $
        runReservation 71 "owner-a" "spec-a" "reservation-k" "receipt-k" $ \reservation -> do
          claimed <- expectRight (claimOrResumeWall reservation Nothing)
          let malformed =
                (wallReceiptRecord claimed)
                  { persistedWallPhase = WallApplied
                  }
          assertLeft
            ( InvalidWallJournal
                "post-origin phase has no durable origin"
            )
            (claimOrResumeWall reservation (Just malformed))
    ]

prepareApplying ::
  WallReservation ownerId wallSpecId reservationId receiptId fenceId ->
  WslConfigOrigin ->
  WallObservation ->
  FileIdentity ->
  Either
    WallModelError
    (WallReceipt ownerId wallSpecId reservationId receiptId fenceId)
prepareApplying reservation origin originalObservation targetIdentity = do
  claimed <- claimOrResumeWall reservation Nothing
  withOrigin <-
    recordWallOrigin
      (wallReceiptRecord claimed)
      claimed
      origin
  creating <-
    beginWallStageCreation
      (wallReceiptRecord withOrigin)
      withOrigin
      "stage-candidate"
  bound <-
    bindWallStage
      (wallReceiptRecord creating)
      creating
      ObservedAbsent
      targetIdentity
  beginWallApply
    (wallReceiptRecord bound)
    bound
    ( ApplyObservation
        originalObservation
        (ObservedPresent targetIdentity desiredBytes)
        ObservedAbsent
    )
    targetIdentity

prepareApplied ::
  WallReservation ownerId wallSpecId reservationId receiptId fenceId ->
  WslConfigOrigin ->
  WallObservation ->
  FileIdentity ->
  WallObservation ->
  Either
    WallModelError
    (WallReceipt ownerId wallSpecId reservationId receiptId fenceId)
prepareApplied reservation origin originalObservation targetIdentity appliedTargetObservation = do
  applying <-
    prepareApplying
      reservation
      origin
      originalObservation
      targetIdentity
  settleWallApply
    (wallReceiptRecord applying)
    applying
    ( ApplyObservation
        appliedTargetObservation
        ObservedAbsent
        (originObservation origin)
    )

preparedObservation ::
  WslConfigOrigin ->
  FileIdentity ->
  ApplyObservation
preparedObservation origin targetIdentity =
  ApplyObservation
    (originObservation origin)
    (ObservedPresent targetIdentity desiredBytes)
    ObservedAbsent

applyOriginQuarantinedObservation ::
  WslConfigOrigin ->
  FileIdentity ->
  ApplyObservation
applyOriginQuarantinedObservation origin targetIdentity =
  ApplyObservation
    ObservedAbsent
    (ObservedPresent targetIdentity desiredBytes)
    (originObservation origin)

appliedObservation ::
  WslConfigOrigin ->
  FileIdentity ->
  ApplyObservation
appliedObservation origin targetIdentity =
  ApplyObservation
    (ObservedPresent targetIdentity desiredBytes)
    ObservedAbsent
    (originObservation origin)

restoreAppliedObservation ::
  WslConfigOrigin ->
  FileIdentity ->
  RestoreObservation
restoreAppliedObservation origin targetIdentity =
  RestoreObservation
    (ObservedPresent targetIdentity desiredBytes)
    (originObservation origin)
    ObservedAbsent

restoreCleanupObservation ::
  WslConfigOrigin ->
  FileIdentity ->
  RestoreObservation
restoreCleanupObservation origin targetIdentity =
  RestoreObservation
    (originObservation origin)
    ObservedAbsent
    (ObservedPresent targetIdentity desiredBytes)

restoreOriginPublicationObservation ::
  WslConfigOrigin ->
  FileIdentity ->
  RestoreObservation
restoreOriginPublicationObservation origin targetIdentity =
  RestoreObservation
    ObservedAbsent
    (originObservation origin)
    (ObservedPresent targetIdentity desiredBytes)

restoredObservation :: WslConfigOrigin -> RestoreObservation
restoredObservation origin =
  RestoreObservation
    (originObservation origin)
    ObservedAbsent
    ObservedAbsent

originObservation :: WslConfigOrigin -> WallObservation
originObservation OriginalAbsent = ObservedAbsent
originObservation (OriginalPresent identity bytes) =
  ObservedPresent identity bytes

runReservation ::
  Word64 ->
  ByteString ->
  ByteString ->
  ByteString ->
  ByteString ->
  ( forall ownerId wallSpecId reservationId receiptId fenceId.
    WallReservation ownerId wallSpecId reservationId receiptId fenceId ->
    Assertion
  ) ->
  Assertion
runReservation fenceValue ownerIdentity specIdentity reservationIdentity receiptIdentity consume =
  runEitherAssertion $
    joinModel $
      withWallOwner ownerIdentity $ \owner ->
        joinModel $
          withWallSpec specIdentity desiredBytes $ \spec ->
            joinModel $
              withWallFence fenceValue $ \fence ->
                withWallReservation
                  owner
                  spec
                  reservationIdentity
                  receiptIdentity
                  fence
                  consume

runAuthority ::
  PersistedWallRecord ->
  WallReceipt ownerId wallSpecId reservationId receiptId fenceId ->
  (WallAuthority ownerId wallSpecId reservationId receiptId fenceId -> Assertion) ->
  Assertion
runAuthority active receipt consume =
  runEitherAssertion (withWallAuthority active receipt consume)

runEitherAssertion :: Either WallModelError Assertion -> Assertion
runEitherAssertion result =
  case result of
    Left err -> assertFailure ("unexpected model error: " ++ show err)
    Right assertion -> assertion

expectRight :: Show err => Either err value -> IO value
expectRight result =
  case result of
    Left err -> assertFailure ("expected Right, got Left " ++ show err)
    Right value -> pure value

assertLeft :: (Eq err, Show err) => err -> Either err value -> Assertion
assertLeft expected result =
  case result of
    Left actual -> actual @?= expected
    Right _ -> assertFailure ("expected Left " ++ show expected ++ ", got Right")

joinModel :: Either error (Either error value) -> Either error value
joinModel = either Left id
