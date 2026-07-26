{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module ReconcileSpec (tests) where

import qualified Data.Text as Text
import qualified Fixture
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Reconcile
import HostBootstrap.Step
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ReconcileSpec"
    [ testCase "observed resources require stable positive identity versions" $
        ( withTestLifecyclePlan $ \plan ->
            joinReconcile $
              withPlannedResource plan "core:context-init" $ \planned ->
                withObservedPlannedResource plan planned 0 0 (const ())
        )
          @?= Left
            (Failure (FailureDetail "observe resource" "generation must be positive" DoNotRetry)),
      testCase "prepared created result mints managed handle and receipt together" $
        createdSummary @?= Right (Changed Created, 7),
      testCase "foreign observation exposes only the unmanaged branch" $
        foreignSummary @?= Right "foreign:manual-vm",
      testCase "explicit matching foreign-origin authority is the only adoption path" $
        adoptionSummary @?= Right (Changed Adopted),
      testCase "journal verification rejects another plan digest" $
        journalMismatch @?= True,
      testCase "only a committed verified record can prove Unchanged" $
        unchangedSummary @?= Right Unchanged,
      testCase "managed phase transition retains receipt generation" $
        phaseSummary @?= Right 7,
      testCase "planned edges retain the exact target and dependency identities" $
        plannedEdgeSummary
          @?= Right ("core:context-init", "core:deploy-vm"),
      testCase "operation preparation rejects an omitted plan dependency" $
        case missingDependencyPreparation of
          Left (Conflict _) -> pure ()
          other -> fail ("expected dependency conflict, got " ++ show other),
      testCase "journal graphs admit only observed success into commit" $ do
        legalJournalTransition ObservedManaged Committed @?= True
        legalJournalTransition ReservationAbsent Committed @?= False
        legalJournalTransition AdoptionObservedManaged AdoptionCommitted @?= True
        legalJournalTransition AdoptionObservedForeign AdoptionCommitted @?= False
        legalJournalTransition RepairObservedTarget RepairCommitted @?= True
        legalJournalTransition RepairObservedOriginal RepairCommitted @?= False
        legalJournalTransition PhaseObservedTo PhaseCommitted @?= True
        legalJournalTransition PhaseObservedFrom PhaseCommitted @?= False,
      testCase "journal advancement increments the durable version and refuses illegal edges" $ do
        let initial = journalRecord "spec" IntentRecorded
        fmap persistedRecordVersion (advancePersistedJournalRecord initial ReservationOutcomeUnknown)
          @?= Right 5
        case advancePersistedJournalRecord initial Committed of
          Left (SafetyRefusal _) -> pure ()
          other -> fail ("expected illegal-transition refusal, got " ++ show other)
    ]

testPlan :: StepPlan
testPlan =
  either
    (error . show)
    id
    (mkStepPlan [contextInitStep "context" (StepFrame "host" "Host") (const (pure ()))])

dependentTestPlan :: StepPlan
dependentTestPlan =
  either
    (error . show)
    id
    ( mkStepPlan
        [ deployVMStep "vm" (StepFrame "host" "Host") (const (pure ())),
          contextInitStep "context" (StepFrame "vm" "VM") (const (pure ()))
        ]
    )

createdSummary :: Either ReconcileError (ChangeView, Word)
createdSummary =
  withTestLifecyclePlan $ \plan ->
    joinReconcile $
      withPlannedResource plan "core:context-init" $ \planned ->
        joinReconcile $
          withObservedPlannedResource plan planned 7 3 $ \handle -> do
            descriptor <- plannedOperation plan planned handle "call:one"
            joinReconcile $
              withPreparedOperation descriptor [] 1 4 $ \prepared preconditions -> do
                result <- completeReconcile handle prepared preconditions (BackendCreated 7)
                pure $
                  withReconcileResult
                    result
                    (\managed _receipt change -> (change, fromIntegral (resourceHandleGeneration managed)))
                    (\_ _ -> error "created resource must not be foreign")

foreignSummary :: Either ReconcileError String
foreignSummary =
  withTestLifecyclePlan $ \plan ->
    joinReconcile $
      withPlannedResource plan "core:context-init" $ \planned ->
        joinReconcile $
          withObservedPlannedResource plan planned 7 3 $ \handle -> do
            descriptor <- plannedOperation plan planned handle "call:one"
            joinReconcile $
              withPreparedOperation descriptor [] 1 4 $ \prepared preconditions -> do
                result <-
                  completeReconcile
                    handle
                    prepared
                    preconditions
                    (BackendForeign 9 (ForeignObservation "manual-vm" "not owned"))
                pure $
                  withReconcileResult
                    result
                    (\_ _ _ -> error "foreign resource must not be managed")
                    (\_ observation -> "foreign:" ++ Text.unpack (foreignIdentity observation))

adoptionSummary :: Either ReconcileError ChangeView
adoptionSummary =
  withTestLifecyclePlan $ \plan ->
    joinReconcile $
      withPlannedResource plan "core:context-init" $ \planned ->
        joinReconcile $
          withObservedPlannedResource plan planned 7 3 $ \handle -> do
            descriptor <- plannedOperation plan planned handle "call:observe-foreign"
            joinReconcile $
              withPreparedOperation descriptor [] 1 4 $ \prepared preconditions -> do
                foreignResult <-
                  completeReconcile
                    handle
                    prepared
                    preconditions
                    (BackendForeign 7 (ForeignObservation "manual-vm" "not owned"))
                withReconcileResult
                  foreignResult
                  (\_ _ _ -> Left (Failure (FailureDetail "test adoption" "expected foreign observation" DoNotRetry)))
                  ( \unmanaged observation ->
                      withVerifiedForeignOrigin unmanaged observation $ \origin ->
                        joinReconcile $
                          withAdoptionAuthority plan planned unmanaged origin "vm:adopt" $ \authority -> do
                            adopted <-
                              completeAdoption
                                unmanaged
                                origin
                                authority
                                (BackendRepaired 7)
                            pure $
                              withReconcileResult
                                adopted
                                (\_ _ change -> change)
                                (\_ _ -> error "adoption must return managed ownership")
                  )

journalMismatch :: Bool
journalMismatch =
  withTestLifecyclePlan $ \plan ->
    case
      withPlannedResource plan "core:context-init"
        ( \planned ->
            withObservedPlannedResource plan planned 7 3
              ( \handle ->
                  case
                    verifyPersistedJournalRecord
                      plan
                      handle
                      "acquire"
                      (journalRecord "other" Committed) of
                    Left _ -> True
                    Right _ -> False
              )
        ) of
      Left _ -> True
      Right (Left _) -> True
      Right (Right mismatched) -> mismatched

unchangedSummary :: Either ReconcileError ChangeView
unchangedSummary =
  withTestLifecyclePlan $ \plan ->
    joinReconcile $
      withPlannedResource plan "core:context-init" $ \planned ->
        joinReconcile $
          withObservedPlannedResource plan planned 7 3 $ \handle -> do
            verified <-
              verifyPersistedJournalRecord
                plan
                handle
                "acquire"
                (journalRecord (Text.unpack (lifecyclePlanDigest plan)) Committed)
            joinReconcile $
              withPriorCommitProof verified $ \proof ->
                withReconcileResult
                  (completeUnchanged handle proof)
                  (\_ _ change -> Right change)
                  (\_ _ -> error "committed unchanged resource must be managed")

phaseSummary :: Either ReconcileError Word
phaseSummary =
  withTestLifecyclePlan $ \plan ->
    joinReconcile $
      withPlannedResource plan "core:context-init" $ \planned ->
        joinReconcile $
          withObservedPlannedResource plan planned 7 3 $ \handle -> do
            descriptor <- plannedOperation plan planned handle "call:one"
            joinReconcile $
              withPreparedOperation descriptor [] 1 4 $ \prepared preconditions -> do
                result <- completeReconcile handle prepared preconditions (BackendCreated 7)
                withReconcileResult
                  result
                  ( \managed receipt _ -> do
                      transition <- planMarkReady managed
                      advance <- verifyPhaseTransition managed receipt transition 7
                      pure $
                        withPhaseAdvance advance $ \readyHandle _ _ ->
                          fromIntegral (resourceHandleGeneration readyHandle)
                  )
                  (\_ _ -> error "created resource must be managed")

plannedEdgeSummary :: Either ReconcileError (Text.Text, Text.Text)
plannedEdgeSummary =
  withTestLifecyclePlanFor dependentTestPlan $ \plan ->
    withPlannedEdge
      plan
      "core:context-init"
      "core:deploy-vm"
      ( \target dependency _edge ->
          (plannedResourceKey target, plannedResourceKey dependency)
      )

missingDependencyPreparation :: Either ReconcileError ()
missingDependencyPreparation =
  withTestLifecyclePlanFor dependentTestPlan $ \plan ->
    joinReconcile $
      withPlannedResource plan "core:context-init" $ \planned ->
        joinReconcile $
          withObservedPlannedResource plan planned 7 3 $ \handle -> do
            descriptor <- plannedOperation plan planned handle "call:context"
            withPreparedOperation descriptor [] 1 4 (\_ _ -> ())

journalRecord :: String -> PersistedJournalPhase -> PersistedJournalRecord
journalRecord digest phase =
  PersistedJournalRecord
    { persistedPlanDigest = text digest,
      persistedFrameKey = "metal",
      persistedResourceKey = "core:context-init",
      persistedGeneration = 7,
      persistedOperation = "acquire",
      persistedOperationKey = "vm:create",
      persistedRecordVersion = 4,
      persistedPhase = phase
    }

joinReconcile :: Either ReconcileError (Either ReconcileError a) -> Either ReconcileError a
joinReconcile = either Left id

text :: String -> Text.Text
text = Text.pack

withTestLifecyclePlan ::
  (forall planId. LifecyclePlan (Production Fixture.FixtureProject) planId -> result) ->
  result
withTestLifecyclePlan consume =
  withTestLifecyclePlanFor testPlan consume

withTestLifecyclePlanFor ::
  StepPlan ->
  (forall planId. LifecyclePlan (Production Fixture.FixtureProject) planId -> result) ->
  result
withTestLifecyclePlanFor plan consume =
  withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
    withLifecyclePlan codec plan consume
