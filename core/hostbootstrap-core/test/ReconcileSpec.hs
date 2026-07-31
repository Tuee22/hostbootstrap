{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module ReconcileSpec (tests) where

import qualified Data.Text as Text
import qualified Fixture
import HostBootstrap.Config.Class (ProjectCfg (withProductionProjectCodec))
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import HostBootstrap.Reconcile
import HostBootstrap.Lift (localContext)
import HostBootstrap.Step
import PrepareFixture (gateFor)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ReconcileSpec"
    [ testCase "observed resources require stable positive identity versions" $
        withTestLifecyclePlan
          ( \plan ->
              joinReconcile $
                withPlannedResource plan "core:context-init" $ \planned ->
                  withObservedPlannedResource plan planned 0 0 (const ())
          )
          @?= Left
            (Failure (FailureDetail "observe resource" "generation must be positive" DoNotRetry)),
      testCase "prepared created result mints managed handle and receipt together" $ do
        gate <- contextInitGate
        createdSummary gate @?= Right (Changed Created, 7),
      testCase "foreign observation exposes only the unmanaged branch" $ do
        gate <- contextInitGate
        foreignSummary gate @?= Right "foreign:manual-vm",
      testCase "explicit matching foreign-origin authority is the only adoption path" $ do
        gate <- contextInitGate
        adoptionSummary gate @?= Right (Changed Adopted),
      testCase "journal verification rejects another plan digest" $
        journalMismatch @?= True,
      testCase "only a committed verified record can prove Unchanged" $ do
        gate <- contextInitGate
        unchangedSummary gate @?= Right Unchanged,
      testCase "managed phase transition retains receipt generation" $ do
        gate <- contextInitGate
        phaseSummary gate @?= Right 7,
      testCase "planned edges retain the exact target and dependency identities" $
        plannedEdgeSummary
          @?= Right ("core:context-init", "core:deploy-vm"),
      testCase "operation preparation rejects an omitted plan dependency" $ do
        gate <- gateFor dependentPlanDigest "core:context-init"
        case missingDependencyPreparation gate of
          Left (Conflict _) -> pure ()
          other -> fail ("expected dependency conflict, got " ++ show other),
      testCase "a gate recorded for another operation cannot prepare this one" $ do
        gate <- gateFor testPlanDigest "core:deploy-vm"
        case createdSummary gate of
          Left (Conflict _) -> pure ()
          other -> fail ("expected a wrong-operation refusal, got " ++ show other),
      testCase "a gate recorded in another plan's journal cannot prepare" $ do
        gate <- gateFor "some-other-plan-digest" "core:context-init"
        case createdSummary gate of
          Left (Conflict _) -> pure ()
          other -> fail ("expected a wrong-plan refusal, got " ++ show other),
      testCase "the plan edge set names only the resource-bearing prefix" $
        -- The demo's own project `ensure` fragment precedes `deploy-vm` and owns
        -- no plan resource, so it contributes no edge; including it would make
        -- `core:copy-source` unsatisfiable rather than stricter (§ CC).
        copySourceDependencies @?= Right ["core:deploy-vm"],
      testCase "the traversal seals the resource-bearing edge set it derived" $
        sealedCopySourceKeys >>= (@?= Right ["core:deploy-vm"]),
      testCase "the zero-dependency branch refuses an operation that declares edges" $
        case zeroBranchOnDependentOperation of
          Left (Conflict _) -> pure ()
          other -> fail ("expected a refusal of the zero-dependency branch, got " ++ show other),
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
        [ descendsVia localContext (deployVMStep "vm" (StepFrame "host" "Host") (const (pure ()))),
          contextInitStep "context" (StepFrame "vm" "VM") (const (pure ()))
        ]
    )

createdSummary :: PreparedGate -> Either ReconcileError (ChangeView, Word)
createdSummary gate =
  withTestLifecyclePlan $ \plan ->
    joinReconcile $
      withPlannedResource plan "core:context-init" $ \planned ->
        joinReconcile $
          withObservedPlannedResource plan planned 7 3 $ \handle -> do
            descriptor <- plannedOperation plan planned handle "call:one"
            preconditionSet <- zeroDependencyPreconditions descriptor
            joinReconcile $
              withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions -> do
                result <- completeReconcile handle prepared preconditions (BackendCreated 7)
                pure $
                  withReconcileResult
                    result
                    (\managed _receipt change -> (change, fromIntegral (resourceHandleGeneration managed)))
                    (\_ _ -> error "created resource must not be foreign")

foreignSummary :: PreparedGate -> Either ReconcileError String
foreignSummary gate =
  withTestLifecyclePlan $ \plan ->
    joinReconcile $
      withPlannedResource plan "core:context-init" $ \planned ->
        joinReconcile $
          withObservedPlannedResource plan planned 7 3 $ \handle -> do
            descriptor <- plannedOperation plan planned handle "call:one"
            preconditionSet <- zeroDependencyPreconditions descriptor
            joinReconcile $
              withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions -> do
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

adoptionSummary :: PreparedGate -> Either ReconcileError ChangeView
adoptionSummary gate =
  withTestLifecyclePlan $ \plan ->
    joinReconcile $
      withPlannedResource plan "core:context-init" $ \planned ->
        joinReconcile $
          withObservedPlannedResource plan planned 7 3 $ \handle -> do
            descriptor <- plannedOperation plan planned handle "call:observe-foreign"
            preconditionSet <- zeroDependencyPreconditions descriptor
            joinReconcile $
              withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions -> do
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

unchangedSummary :: PreparedGate -> Either ReconcileError ChangeView
unchangedSummary gate =
  withTestLifecyclePlan $ \plan ->
    joinReconcile $
      withPlannedResource plan "core:context-init" $ \planned ->
        joinReconcile $
          withObservedPlannedResource plan planned 7 3 $ \handle -> do
            descriptor <- plannedOperation plan planned handle "call:one"
            preconditionSet <- zeroDependencyPreconditions descriptor
            joinReconcile $
              withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions -> do
                verified <-
                  verifyPersistedJournalRecord
                    plan
                    handle
                    "acquire"
                    ( (journalRecord (Text.unpack (lifecyclePlanDigest plan)) Committed)
                        { persistedOperationKey = "core:context-init:call:one"
                        }
                    )
                joinReconcile $
                  withPriorCommitProof verified $ \proof -> do
                    result <-
                      completePreparedUnchanged
                        handle
                        prepared
                        preconditions
                        proof
                    pure $
                      withReconcileResult
                        result
                        (\_ _ change -> change)
                        (\_ _ -> error "committed unchanged resource must be managed")

phaseSummary :: PreparedGate -> Either ReconcileError Word
phaseSummary gate =
  withTestLifecyclePlan $ \plan ->
    joinReconcile $
      withPlannedResource plan "core:context-init" $ \planned ->
        joinReconcile $
          withObservedPlannedResource plan planned 7 3 $ \handle -> do
            descriptor <- plannedOperation plan planned handle "call:one"
            preconditionSet <- zeroDependencyPreconditions descriptor
            joinReconcile $
              withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions -> do
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

{- | A plan shaped like the worked demo's: a project-owned @ensure@ fragment that
carries no plan resource, then the provider, then the durable share.
-}
projectPrefixedPlan :: StepPlan
projectPrefixedPlan =
  either
    (error . show)
    id
    ( mkStepPlan
        [ projectStep
            (either error id (projectStepId "ensure-vm-provider"))
            PreserveOnReverse
            "ensure the VM provider"
            (StepFrame "host" "Host")
            (const (pure ())),
          descendsVia localContext (deployVMStep "vm" (StepFrame "host" "Host") (const (pure ()))),
          copySourceStep "durable share" (StepFrame "vm" "VM") (const (pure ()))
        ]
    )

-- | The exact ordered edge set the plan derives for @core:copy-source@.
copySourceDependencies :: Either ReconcileError [Text.Text]
copySourceDependencies =
  withTestLifecyclePlanFor projectPrefixedPlan $ \plan ->
    joinReconcile $
      withPlannedResourceOfKind plan DurableShareResourceKind "core:copy-source" $ \planned ->
        joinReconcile $
          withObservedPlannedResource plan planned 7 3 $ \handle ->
            operationDescriptorDependencies
              <$> plannedOperation plan planned handle "share:mount"

{- | The same edge set, sealed through the traversal against a snapshot holding
only the managed provider.  Before the resource-bearing filter this could not
succeed at all: the descriptor demanded an observation for the project's own
@ensure@ step, and no 'PlannedResource' — hence no managed handle — exists for it.
-}
sealedCopySourceKeys :: IO (Either ReconcileError [Text.Text])
sealedCopySourceKeys = do
  providerGate <- gateFor projectPrefixedPlanDigest "core:deploy-vm"
  either (pure . Left) id $
    withTestLifecyclePlanFor projectPrefixedPlan $ \plan ->
      joinReconcile $
        withPlannedResourceOfKind plan ProviderResourceKind "core:deploy-vm" $ \provider ->
          joinReconcile $
            withPlannedResourceOfKind plan DurableShareResourceKind "core:copy-source" $ \share ->
              joinReconcile $
                withManagedProvider providerGate plan provider $ \managedProvider ->
                  joinReconcile $
                    withObservedPlannedResource plan share 11 13 $ \shareHandle -> do
                      descriptor <- plannedOperation plan share shareHandle "share:mount"
                      pure
                        ( fmap operationPreconditionKeys
                            <$> withOperationPreconditions
                              descriptor
                              ( withDependencySnapshotEntry
                                  managedProvider
                                  (dependencyProbe (pure (Right 17)))
                                  emptyDependencySnapshot
                              )
                        )

-- | Own the provider so the share has a managed dependency to observe.
withManagedProvider ::
  PreparedGate ->
  LifecyclePlan (Production Fixture.FixtureProject) planId ->
  PlannedResource (Production Fixture.FixtureProject) planId providerId ProviderResource providerFrame ->
  ( ResourceHandle (Production Fixture.FixtureProject) planId providerId ProviderResource Managed Provisioned ->
    result
  ) ->
  Either ReconcileError result
withManagedProvider gate plan planned consume =
  joinReconcile $
    withObservedPlannedResource plan planned 5 7 $ \observed -> do
      descriptor <- plannedOperation plan planned observed "provider:create"
      preconditionSet <- zeroDependencyPreconditions descriptor
      joinReconcile $
        withPreparedOperation descriptor preconditionSet gate $ \prepared preconditions -> do
          reconciled <- completeReconcile observed prepared preconditions (BackendCreated 5)
          withReconcileResult
            reconciled
            (\managed _ _ -> Right (consume managed))
            (\_ _ -> Left (Failure (FailureDetail "test provider" "unexpected foreign provider" DoNotRetry)))

-- | The zero-dependency branch is not a route around the snapshot.
zeroBranchOnDependentOperation :: Either ReconcileError ()
zeroBranchOnDependentOperation =
  withTestLifecyclePlanFor projectPrefixedPlan $ \plan ->
    joinReconcile $
      withPlannedResourceOfKind plan DurableShareResourceKind "core:copy-source" $ \planned ->
        joinReconcile $
          withObservedPlannedResource plan planned 7 3 $ \handle -> do
            descriptor <- plannedOperation plan planned handle "share:mount"
            () <$ zeroDependencyPreconditions descriptor

missingDependencyPreparation :: PreparedGate -> Either ReconcileError ()
missingDependencyPreparation gate =
  withTestLifecyclePlanFor dependentTestPlan $ \plan ->
    joinReconcile $
      withPlannedResource plan "core:context-init" $ \planned ->
        joinReconcile $
          withObservedPlannedResource plan planned 7 3 $ \handle -> do
            descriptor <- plannedOperation plan planned handle "call:context"
            preconditionSet <- zeroDependencyPreconditions descriptor
            withPreparedOperation descriptor preconditionSet gate (\_ _ -> ())

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

-- | The digests of the three plans, so a spec can mint a gate in the same plan
-- journal the operation it prepares belongs to.
testPlanDigest :: Text.Text
testPlanDigest = withTestLifecyclePlan lifecyclePlanDigest

dependentPlanDigest :: Text.Text
dependentPlanDigest = withTestLifecyclePlanFor dependentTestPlan lifecyclePlanDigest

projectPrefixedPlanDigest :: Text.Text
projectPrefixedPlanDigest = withTestLifecyclePlanFor projectPrefixedPlan lifecyclePlanDigest

contextInitGate :: IO PreparedGate
contextInitGate = gateFor testPlanDigest "core:context-init"

withTestLifecyclePlan ::
  (forall planId. LifecyclePlan (Production Fixture.FixtureProject) planId -> result) ->
  result
withTestLifecyclePlan = withTestLifecyclePlanFor testPlan

withTestLifecyclePlanFor ::
  StepPlan ->
  (forall planId. LifecyclePlan (Production Fixture.FixtureProject) planId -> result) ->
  result
withTestLifecyclePlanFor plan consume =
  withProductionProjectCodec @Fixture.FixtureProject @Fixture.ProjectConfig $ \codec ->
    withLifecyclePlan codec plan consume
