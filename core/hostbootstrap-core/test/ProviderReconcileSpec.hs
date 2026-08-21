{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module ProviderReconcileSpec (tests) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Config.Vocab (Production)
import HostBootstrap.HostConfig (HostConfig (..))
import HostBootstrap.HostTool (AbsExe, HostTool (..), mkAbsExe)
import HostBootstrap.Ownership.Object (ObjectIdentity, mkObjectIdentity)
import qualified HostBootstrap.Lifecycle.Execution as Execution
import HostBootstrap.Lifecycle.Prepared (PreparedGate)
import qualified HostBootstrap.ProjectPlan as ProjectPlan
import HostBootstrap.Reconcile
import HostBootstrap.Step
import HostBootstrap.Substrate (Arch (Arm64), Substrate (..), SubstrateName (LinuxCpu))
import HostBootstrap.Substrate.Provider.Backend
import HostBootstrap.Substrate.Provider.Ownership (
  ProviderDeleteOutcome (DeleteAlreadyRemoved, DeleteRemoved),
  ProviderOwnershipFault (ProviderOwnershipStanding),
  ProviderProvisionOutcome (ProvisionAlreadyOwned, ProvisionCreated, ProvisionRecovered),
  ProviderReadyOutcome (ReadyAlready, ReadyStarted),
  ProviderShareOutcome (ShareAlreadyAttached, ShareAttached, ShareRepaired),
  ProviderStopOutcome (StopAlreadyStopped, StopStopped),
 )
import HostBootstrap.Substrate.Provider.Reconcile
import HostBootstrap.Substrate.Provider.Resume (
  ProviderStandingConflict (InstanceReplaced, InstanceUnderNoRecord),
 )
import PrepareFixture (gateFor)
import PlatformPath (hostFixturePath)
import System.Directory (canonicalizePath, createDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ProviderReconcileSpec"
    [ testCase "a prepared provider creation returns its exact backend-indexed wrapper" $
        withIncusProviderFixture 17 createdBackendReport (settledProvision NoPrior)
          >>= \case
            Right (Changed Created, "core:deploy-vm", 17, 7, owner) ->
              assertBool
                "the wrapper retains the provider origin"
                ("hostbootstrap/provider-origin/v2" `Text.isInfixOf` owner)
            other -> assertFailure ("expected a managed provider creation, got " ++ show other)
    , testCase "an explicitly recovered provider settles Repaired" $
        withIncusProviderFixture 17 repairedProvisionBackendReport (settledProvision NoPrior)
          >>= \case
            Right (Changed Repaired, "core:deploy-vm", 17, 7, _) -> pure ()
            other -> assertFailure ("expected a repaired provider wrapper, got " ++ show other)
    , testCase "a backend-proved same-origin provider without prior proof settles Repaired" $
        withIncusProviderFixture 17 ownedProvisionBackendReport (settledProvision NoPrior)
          >>= \case
            Right (Changed Repaired, "core:deploy-vm", 17, 7, _) -> pure ()
            other -> assertFailure ("expected recovered managed provider authority, got " ++ show other)
    , testCase "a backend-proved same-origin provider with matching proof settles Unchanged" $
        withIncusProviderFixture 17 ownedProvisionBackendReport (settledProvision MatchingPrior)
          >>= \case
            Right (Unchanged, "core:deploy-vm", 17, 7, _) -> pure ()
            other -> assertFailure ("expected unchanged provider authority, got " ++ show other)
    , testCase "a foreign provider remains descriptive and grants no wrapper" $
        withIncusProviderFixture 17 foreignProvisionBackendReport foreignProvision
          >>= (@?= Right "core:deploy-vm")
    , testCase "Direct admission owns only its plan-local journal reservation" $
        withDirectProviderFixture 17 (directAdmission NoPrior) >>= \case
          Right (Changed Created, owner, resourceKey) -> do
            assertBool "the owner is a framed provider-origin binding" ("hostbootstrap/provider-origin/v2" `Text.isInfixOf` owner)
            resourceKey @?= "core:deploy-vm"
          other -> assertFailure ("expected a Direct local admission, got " ++ show other)
    , testCase "Direct admission with matching proof settles Unchanged" $
        withDirectProviderFixture 17 (directAdmission MatchingPrior)
          >>= \case
            Right (Unchanged, _, "core:deploy-vm") -> pure ()
            other -> assertFailure ("expected an unchanged Direct reservation, got " ++ show other)
    , testCase "stop, restart-to-ready, stop, and delete preserve one managed generation" $
        ( withIncusBackend createdBackendReport $ \backend ->
            withManagedProviderFixture backend lifecycleSequence
        )
          >>= (@?= Right (17, 12))
    , testCase "already-ready/stopped/deleted reports traverse the same wrapper phase path" $
        ( withIncusBackend alreadyPhaseBackendReport $ \backend ->
            withManagedProviderFixture backend lifecycleSequence
        )
          >>= (@?= Right (17, 12))
    , testCase "a replacement cannot settle a prepared stop" $
        ( withIncusBackend replacementStopBackendReport $ \backend ->
            withManagedProviderFixture backend replacedStop
        )
          >>= \case
          Left (Conflict detail) -> conflictResource detail @?= "core:deploy-vm"
          other -> assertFailure ("expected a replacement conflict, got " ++ show other)
    , testCase "a Direct stop refusal mints no successor phase" $
        ( withDirectBackend $ \backend _root ->
            withManagedProviderFixture backend unsupportedStop
        )
          >>= (@?= Right True)
    , testCase "the host-side share seals its managed provider and exact path declaration" $
        withDirectBackend
          ( \backend root ->
              (fmap . fmap) ((,) root) (withShareFixture backend root (Right 31) (settledShare NoPrior backend))
          )
          >>= \case
            Right (root, (Changed Created, "core:copy-source", 29, 11, hostPath, guestPath, providerGeneration)) -> do
              hostPath @?= root
              guestPath @?= shareGuestPath
              providerGeneration @?= 17
            other -> assertFailure ("expected a prepared Direct share admission, got " ++ show other)
    , testCase "a Direct share with matching prior proof settles Unchanged" $
        withDirectBackend (\backend root -> withShareFixture backend root (Right 31) (settledShare MatchingPrior backend))
          >>= \case
            Right (Unchanged, "core:copy-source", 29, 11, _, _, 17) -> pure ()
            other -> assertFailure ("expected an unchanged Direct share, got " ++ show other)
    , testCase "an attached provider share settles Created" $
        ( withIncusBackend createdBackendReport $ \backend ->
            withShareFixture backend shareHostPath (Right 31) (settledShare NoPrior backend)
        )
          >>= \case
            Right (Changed Created, "core:copy-source", 29, 11, _, _, 17) -> pure ()
            other -> assertFailure ("expected a created provider share, got " ++ show other)
    , testCase "an explicitly repaired provider share settles Repaired" $
        ( withIncusBackend repairedShareBackendReport $ \backend ->
            withShareFixture backend shareHostPath (Right 31) (settledShare NoPrior backend)
        )
          >>= \case
            Right (Changed Repaired, "core:copy-source", 29, 11, _, _, 17) -> pure ()
            other -> assertFailure ("expected a repaired provider share, got " ++ show other)
    , testCase "a backend-proved ready share without prior proof settles Repaired" $
        ( withIncusBackend readyShareBackendReport $ \backend ->
            withShareFixture backend shareHostPath (Right 31) (settledShare NoPrior backend)
        )
          >>= \case
            Right (Changed Repaired, "core:copy-source", 29, 11, _, _, 17) -> pure ()
            other -> assertFailure ("expected recovered share authority, got " ++ show other)
    , testCase "a backend-proved ready share with matching proof settles Unchanged" $
        ( withIncusBackend readyShareBackendReport $ \backend ->
            withShareFixture backend shareHostPath (Right 31) (settledShare MatchingPrior backend)
        )
          >>= \case
            Right (Unchanged, "core:copy-source", 29, 11, _, _, 17) -> pure ()
            other -> assertFailure ("expected unchanged share authority, got " ++ show other)
    , testCase "a failed fresh provider probe refuses share preparation" $
        withDirectBackend
          ( \backend root ->
              withShareFixture
                backend
                root
                (Left (Failure (FailureDetail "probe provider" "provider stopped answering" ReprobeBeforeRetry)))
                (\_ _ _ -> pure (Right ()))
          )
          >>= \case
            Left (Failure detail) -> failedOperation detail @?= "probe provider"
            other -> assertFailure ("expected the dependency probe failure, got " ++ show other)
    , testCase "provider share declarations reject relative paths before preparation" $
        case mkProviderShareSpec "relative/source" "/guest/target" of
          Left (Failure detail) -> failedOperation detail @?= "validate provider share"
          other -> assertFailure ("expected absolute-path validation, got " ++ show other)
    ]

data PriorMode = NoPrior | MatchingPrior

type ProvisionSummary = (ChangeView, Text.Text, Word64, Word64, Text.Text)

settledProvision ::
  PriorMode ->
  ProviderUnderTest backendId ->
  LifecyclePlan scope planId ->
  Execution.StepExecution scope planId ->
  PlannedResource scope planId providerId ProviderResource providerFrame ->
  ResourceHandle scope planId providerId ProviderResource Unclassified Observed ->
  PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
  IO (Either ReconcileError ProvisionSummary)
settledProvision priorMode backend plan _ _ observed prepared = do
  callResult <- provisionCall backend prepared
  pure $ do
    settled <- settleProvisionWithPrior priorMode plan observed prepared callResult
    pure $
      withProviderProvisionSettlement
        settled
        ( \managed change ->
            ( change
            , managedProviderKey managed
            , managedProviderGeneration managed
            , managedProviderObservationVersion managed
            , preparedProviderBindingOwner (preparedProviderProvisionBinding prepared)
            )
        )
        (\_ _ _ _ -> error "a created provider must be managed")

settleProvisionWithPrior ::
  PriorMode ->
  LifecyclePlan scope planId ->
  ResourceHandle scope planId providerId ProviderResource Unclassified Observed ->
  PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
  ProviderProvisionCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion ->
  Either ReconcileError (ProviderProvisionSettlement scope planId backendId providerId)
settleProvisionWithPrior priorMode plan observed prepared callResult =
  case priorMode of
    NoPrior -> settleProviderProvision Nothing prepared callResult
    MatchingPrior ->
      joinReconcile $
        withMatchingPriorCommit
          plan
          observed
          (preparedOperationKey observed (preparedProviderProvisionBinding prepared))
          (\proof -> settleProviderProvision (Just proof) prepared callResult)

foreignProvision ::
  ProviderUnderTest backendId ->
  LifecyclePlan scope planId ->
  Execution.StepExecution scope planId ->
  PlannedResource scope planId providerId ProviderResource providerFrame ->
  ResourceHandle scope planId providerId ProviderResource Unclassified Observed ->
  PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
  IO (Either ReconcileError Text.Text)
foreignProvision backend _ _ _ _ prepared = do
  callResult <- provisionCall backend prepared
  pure $ do
    settled <- settleProviderProvision Nothing prepared callResult
    pure $
      withProviderProvisionSettlement
        settled
        (\_ _ -> error "a foreign observation must not establish ownership")
        (\_ _ _ foreignState -> foreignIdentity foreignState)

directAdmission ::
  PriorMode ->
  ProviderUnderTest backendId ->
  LifecyclePlan scope planId ->
  Execution.StepExecution scope planId ->
  PlannedResource scope planId providerId ProviderResource providerFrame ->
  ResourceHandle scope planId providerId ProviderResource Unclassified Observed ->
  PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
  IO (Either ReconcileError (ChangeView, Text.Text, Text.Text))
directAdmission priorMode backend plan _ _ observed prepared = do
  callResult <- provisionCall backend prepared
  pure $ do
    settled <- settleProvisionWithPrior priorMode plan observed prepared callResult
    pure $
      withProviderProvisionSettlement
        settled
        ( \_ change ->
            ( change
            , preparedProviderBindingOwner (preparedProviderProvisionBinding prepared)
            , preparedProviderBindingResourceKey (preparedProviderProvisionBinding prepared)
            )
        )
        (\_ _ _ _ -> error "a Direct admission must own its local reservation")

lifecycleSequence ::
  ProviderUnderTest backendId ->
  LifecyclePlan scope planId ->
  Execution.StepExecution scope planId ->
  PlannedResource scope planId providerId ProviderResource providerFrame ->
  ManagedProviderHandle scope planId backendId providerId Provisioned ->
  IO (Either ReconcileError (Word64, Word64))
lifecycleSequence backend _ execution planned provisioned =
  bootProvider backend execution planned provisioned >>= \case
    Left failure -> pure (Left failure)
    Right bootedAdvance ->
      withProviderPhaseAdvance bootedAdvance $ \running -> do
        stopGate <- providerGate execution
        stoppedResult <-
          joinIO $
            withPreparedProviderStop execution planned running stopGate $ \prepared -> do
              callResult <- stopCall backend prepared
              pure (settleProviderStop prepared callResult)
        case stoppedResult of
            Left failure -> pure (Left failure)
            Right stoppedAdvance ->
              withProviderPhaseAdvance stoppedAdvance $ \stopped -> do
                readyGate <- providerGate execution
                runningResult <-
                  joinIO $
                    withPreparedProviderReady
                      execution
                      planned
                      stopped
                      (providerStartableAfterStop stopped)
                      readyGate
                      ( \prepared -> do
                          callResult <- readyCall backend prepared
                          pure (settleProviderReady prepared callResult)
                      )
                case runningResult of
                    Left failure -> pure (Left failure)
                    Right runningAdvance ->
                      withProviderPhaseAdvance runningAdvance $ \runningAgain -> do
                        secondStopGate <- providerGate execution
                        secondStopResult <-
                          joinIO $
                            withPreparedProviderStop
                              execution
                              planned
                              runningAgain
                              secondStopGate
                              ( \prepared -> do
                                  callResult <- stopCall backend prepared
                                  pure (settleProviderStop prepared callResult)
                              )
                        case secondStopResult of
                            Left failure -> pure (Left failure)
                            Right secondStoppedAdvance ->
                              withProviderPhaseAdvance secondStoppedAdvance $ \stoppedAgain -> do
                                deleteGate <- providerGate execution
                                joinIO $
                                  withPreparedProviderDelete
                                    execution
                                    planned
                                    stoppedAgain
                                    deleteGate
                                    ( \prepared -> do
                                        callResult <- deleteCall backend prepared
                                        pure $ do
                                          destroyed <- settleProviderDelete prepared callResult
                                          pure $
                                            withProviderPhaseAdvance destroyed $ \destroyedHandle ->
                                              ( managedProviderGeneration destroyedHandle
                                              , managedProviderObservationVersion destroyedHandle
                                              )
                                    )

replacedStop ::
  ProviderUnderTest backendId ->
  LifecyclePlan scope planId ->
  Execution.StepExecution scope planId ->
  PlannedResource scope planId providerId ProviderResource providerFrame ->
  ManagedProviderHandle scope planId backendId providerId Provisioned ->
  IO (Either ReconcileError ())
replacedStop backend _ execution planned provisioned =
  bootProvider backend execution planned provisioned >>= \case
    Left failure -> pure (Left failure)
    Right bootedAdvance ->
      withProviderPhaseAdvance bootedAdvance $ \running -> do
        gate <- providerGate execution
        joinIO $
          withPreparedProviderStop
            execution
            planned
            running
            gate
            ( \prepared -> do
                callResult <- stopCall backend prepared
                pure (() <$ settleProviderStop prepared callResult)
            )

unsupportedStop ::
  ProviderUnderTest backendId ->
  LifecyclePlan scope planId ->
  Execution.StepExecution scope planId ->
  PlannedResource scope planId providerId ProviderResource providerFrame ->
  ManagedProviderHandle scope planId backendId providerId Provisioned ->
  IO (Either ReconcileError Bool)
unsupportedStop backend _ execution planned provisioned =
  bootProvider backend execution planned provisioned >>= \case
    Left failure -> pure (Left failure)
    Right bootedAdvance ->
      withProviderPhaseAdvance bootedAdvance $ \running -> do
        stopGate <- providerGate execution
        stopRefusal <-
          joinIO $
            withPreparedProviderStop
              execution
              planned
              running
              stopGate
              ( \prepared -> do
                  callResult <- stopCall backend prepared
                  pure (settleProviderStop prepared callResult)
              )
        pure $
          Right $ case stopRefusal of
            Left (Unsupported _) -> True
            _ -> False

bootProvider ::
  ProviderUnderTest backendId ->
  Execution.StepExecution scope planId ->
  PlannedResource scope planId providerId ProviderResource providerFrame ->
  ManagedProviderHandle scope planId backendId providerId Provisioned ->
  IO (Either ReconcileError (ProviderPhaseAdvance scope planId backendId providerId Running))
bootProvider backend execution planned provisioned = do
  gate <- providerGate execution
  joinIO $
    withPreparedProviderReady
      execution
      planned
      provisioned
      (providerStartableAfterProvision provisioned)
      gate
      ( \prepared -> do
          callResult <- readyCall backend prepared
          pure (settleProviderReady prepared callResult)
      )

type ShareSummary = (ChangeView, Text.Text, Word64, Word64, FilePath, FilePath, Word64)

settledShare ::
  PriorMode ->
  ProviderUnderTest backendId ->
  LifecyclePlan scope planId ->
  ResourceHandle scope planId shareId DurableShareResource Unclassified Observed ->
  PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
  IO (Either ReconcileError ShareSummary)
settledShare priorMode backend plan observed prepared = do
  callResult <- shareCall backend prepared
  pure $ do
    settled <- settleShareWithPrior priorMode plan observed prepared callResult
    pure $
      withProviderShareSettlement
        settled
        ( \managed change ->
            let spec = preparedProviderShareSpec prepared
             in ( change
                , managedProviderShareKey managed
                , managedProviderShareGeneration managed
                , managedProviderShareObservationVersion managed
                , providerShareHostPath spec
                , providerShareGuestPath spec
                , preparedProviderBindingGeneration (preparedProviderShareBinding prepared)
                )
        )
        (\_ _ _ _ -> error "a Direct share admission must own its plan-local projection")

settleShareWithPrior ::
  PriorMode ->
  LifecyclePlan scope planId ->
  ResourceHandle scope planId shareId DurableShareResource Unclassified Observed ->
  PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
  ProviderShareCallResult scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
  Either ReconcileError (ProviderShareSettlement scope planId backendId providerId shareId)
settleShareWithPrior priorMode plan observed prepared callResult =
  case priorMode of
    NoPrior -> settleProviderShare Nothing prepared callResult
    MatchingPrior ->
      joinReconcile $
        withMatchingPriorCommit
          plan
          observed
          (preparedOperationKey observed (preparedProviderShareBinding prepared))
          (\proof -> settleProviderShare (Just proof) prepared callResult)

preparedOperationKey ::
  ResourceHandle scope planId resourceId resource Unclassified Observed ->
  PreparedProviderBinding scope planId backendId providerId ->
  Text.Text
preparedOperationKey handle binding =
  resourceHandleKey handle <> ":" <> preparedProviderBindingCallDigest binding

withMatchingPriorCommit ::
  LifecyclePlan scope planId ->
  ResourceHandle scope planId resourceId resource Unclassified Observed ->
  Text.Text ->
  (PriorCommitProof scope planId resourceId resource -> result) ->
  Either ReconcileError result
withMatchingPriorCommit plan handle operationKey consume = do
  verified <-
    verifyPersistedJournalRecord
      plan
      handle
      "acquire"
      PersistedJournalRecord
        { persistedPlanDigest = lifecyclePlanDigest plan
        , persistedFrameKey = "host"
        , persistedResourceKey = resourceHandleKey handle
        , persistedGeneration = resourceHandleGeneration handle
        , persistedOperation = "acquire"
        , persistedOperationKey = operationKey
        , persistedRecordVersion = 1
        , persistedPhase = Committed
        }
  withPriorCommitProof verified consume

type ProviderFixtureConsumer summary =
  forall backendId projectId planId providerId providerFrame operationKey callDigest attempt journalVersion.
  ProviderUnderTest backendId ->
  LifecyclePlan (Production projectId) planId ->
  Execution.StepExecution (Production projectId) planId ->
  PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
  ResourceHandle (Production projectId) planId providerId ProviderResource Unclassified Observed ->
  PreparedProviderProvision
    (Production projectId)
    planId
    backendId
    providerId
    operationKey
    callDigest
    attempt
    journalVersion ->
  IO (Either ReconcileError summary)

withIncusProviderFixture ::
  Word64 ->
  ProviderAnswers ->
  ProviderFixtureConsumer summary ->
  IO (Either ReconcileError summary)
withIncusProviderFixture generation answers consume =
  withIncusBackend answers $ \backend ->
    withProviderFixture backend generation consume

withDirectProviderFixture ::
  Word64 ->
  ProviderFixtureConsumer summary ->
  IO (Either ReconcileError summary)
withDirectProviderFixture generation consume =
  withDirectBackend $ \backend _root ->
    withProviderFixture backend generation consume

withProviderFixture ::
  ProviderUnderTest backendId ->
  Word64 ->
  ( forall projectId planId providerId providerFrame operationKey callDigest attempt journalVersion.
    ProviderUnderTest backendId ->
    LifecyclePlan (Production projectId) planId ->
    Execution.StepExecution (Production projectId) planId ->
    PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
    ResourceHandle (Production projectId) planId providerId ProviderResource Unclassified Observed ->
    PreparedProviderProvision
      (Production projectId)
      planId
      backendId
      providerId
      operationKey
      callDigest
      attempt
      journalVersion ->
    IO (Either ReconcileError summary)
  ) ->
  IO (Either ReconcileError summary)
withProviderFixture backend generation consume =
  Fixture.withFixtureProjectPlan providerPlan $ \projectPlan ->
    case NonEmpty.toList (ProjectPlan.forward projectPlan) of
      [providerNode] -> do
        carrier <- Execution.newResourceCarrier
        runtime <- Execution.newStepRuntime carrier
        let plan = lifecyclePlanFromProjectPlan projectPlan
            execution = stepExecutionFor projectPlan testHostConfig runtime providerNode
            operationKey = Execution.stepExecutionOperationKey execution
        gate <- providerGate execution
        joinIO $
          joinReconcile $
            withNodeResourceOfKind execution ProviderResourceKind operationKey $ \planned ->
              joinReconcile $
                withNodeObservedResource execution planned generation 7 $ \observed ->
                  withPreparedProviderProvision execution (providerBackendBinding (underTestBackend backend)) planned observed gate $
                    consume backend plan execution planned observed
      nodes -> fail ("expected one provider node, got " ++ show (length nodes))

withManagedProviderFixture ::
  ProviderUnderTest backendId ->
  ( forall projectId planId providerId providerFrame.
    ProviderUnderTest backendId ->
    LifecyclePlan (Production projectId) planId ->
    Execution.StepExecution (Production projectId) planId ->
    PlannedResource (Production projectId) planId providerId ProviderResource providerFrame ->
    ManagedProviderHandle (Production projectId) planId backendId providerId Provisioned ->
    IO (Either ReconcileError summary)
  ) ->
  IO (Either ReconcileError summary)
withManagedProviderFixture backend consume =
  withProviderFixture backend 17 $ \exactBackend plan execution planned _ prepared -> do
    callResult <- provisionCall exactBackend prepared
    case settleProviderProvision Nothing prepared callResult of
      Left failure -> pure (Left failure)
      Right settled ->
        withProviderProvisionSettlement
          settled
          (\managed _ -> consume exactBackend plan execution planned managed)
          (\_ _ _ _ -> pure (Left (Failure (FailureDetail "provider fixture" "unexpected foreign provider" DoNotRetry))))

withShareFixture ::
  ProviderUnderTest backendId ->
  FilePath ->
  Either ReconcileError Word64 ->
  ( forall projectId planId providerId shareId operationKey callDigest attempt journalVersion.
    LifecyclePlan (Production projectId) planId ->
    ResourceHandle (Production projectId) planId shareId DurableShareResource Unclassified Observed ->
    PreparedProviderShare
      (Production projectId)
      planId
      backendId
      providerId
      shareId
      operationKey
      callDigest
      attempt
      journalVersion ->
    IO (Either ReconcileError summary)
  ) ->
  IO (Either ReconcileError summary)
withShareFixture backend hostPath providerProbe consume =
  Fixture.withFixtureProjectPlan providerSharePlan $ \projectPlan ->
    case NonEmpty.toList (ProjectPlan.forward projectPlan) of
      [providerNode, shareNode] -> do
        carrier <- Execution.newResourceCarrier
        providerRuntime <- Execution.newStepRuntime carrier
        shareRuntime <- Execution.newStepRuntime carrier
        let providerExecution = stepExecutionFor projectPlan testHostConfig providerRuntime providerNode
            shareExecution = stepExecutionFor projectPlan testHostConfig shareRuntime shareNode
            providerKey = Execution.stepExecutionOperationKey providerExecution
            shareKey = Execution.stepExecutionOperationKey shareExecution
        providerPrepareGate <- providerGate providerExecution
        sharePrepareGate <- providerGate shareExecution
        spec <- either (fail . show) pure (mkProviderShareSpec hostPath shareGuestPath)
        joinIO $
          joinReconcile $
            withNodeResourceOfKind providerExecution ProviderResourceKind providerKey $ \plannedProvider ->
              joinReconcile $
                withNodeObservedResource providerExecution plannedProvider 17 7 $ \observedProvider ->
                  withPreparedProviderProvision providerExecution (providerBackendBinding (underTestBackend backend)) plannedProvider observedProvider providerPrepareGate $ \preparedProvider -> do
                    provisionResult <- provisionCall backend preparedProvider
                    case settleProviderProvision Nothing preparedProvider provisionResult of
                      Left failure -> pure (Left failure)
                      Right providerResult ->
                        withProviderProvisionSettlement
                          providerResult
                          ( \managedProvider _ ->
                              bootProvider backend providerExecution plannedProvider managedProvider >>= \case
                                Left failure -> pure (Left failure)
                                Right bootedAdvance ->
                                  withProviderPhaseAdvance bootedAdvance $ \runningProvider ->
                                    joinIO $
                                      joinReconcile $
                                        withNodeResourceOfKind shareExecution DurableShareResourceKind shareKey $ \plannedShare ->
                                          withNodeObservedResource shareExecution plannedShare 29 11 $ \observedShare ->
                                            flattenIO $
                                              withPreparedProviderShare
                                                shareExecution
                                                plannedShare
                                                observedShare
                                                runningProvider
                                                (dependencyProbe (pure providerProbe))
                                                spec
                                                sharePrepareGate
                                                (consume (lifecyclePlanFromProjectPlan projectPlan) observedShare)
                          )
                          (\_ _ _ _ -> pure (Left (Failure (FailureDetail "share fixture" "unexpected foreign provider" DoNotRetry))))
      nodes -> fail ("expected provider/share nodes, got " ++ show (length nodes))

providerGate :: Execution.StepExecution scope planId -> IO PreparedGate
providerGate execution =
  gateFor
    (Execution.stepExecutionPlanDigest execution)
    (Execution.stepExecutionOperationKey execution)

providerPlan :: StepPlan
providerPlan =
  either
    (error . show)
    id
    (mkStepPlan [deployVMStep "provider" testFrame (const (pure StepChanged))])

providerSharePlan :: StepPlan
providerSharePlan =
  either
    (error . show)
    id
    ( mkStepPlan
        [ deployVMStep "provider" testFrame (const (pure StepChanged))
        , copySourceStep "durable share" testFrame (const (pure StepChanged))
        ]
    )

testFrame :: StepFrame
testFrame = StepFrame "host" "Host"

testHostConfig :: HostConfig
testHostConfig =
  HostConfig
    { hcSubstrate = Substrate{substrateName = LinuxCpu, substrateArch = Arm64}
    , hcToolPaths = Map.empty
    }

fixtureExe :: FilePath -> AbsExe
fixtureExe = either error id . mkAbsExe

-- | The discovered backend, beside the reports its provider produces.
--
-- The backend itself holds no execution seam: it carries the typed host
-- configuration and reaches every process through the one interpreter.  What a
-- suite about /settlement/ still needs is a provider's answer, and an answer is
-- a value, so the reports arrive as one total function of the verb and are read
-- through the exported classifiers (§ NN).  A backend whose reports are
-- 'Nothing' answers through the production call itself, which is what the Direct
-- realization's structural refusals are about.
data ProviderUnderTest backendId = ProviderUnderTest
  { underTestBackend :: StrongProviderBackend backendId
  , underTestAnswers :: Maybe ProviderAnswers
  }

{- | What one provider answers, for a suite whose subject is settlement.

Every verb is a clause-holding /transaction/ and answers in the transaction
vocabulary, so each case below is reached by applying the exported classifier to
an answer rather than by arranging for a stand-in to have been reached (§ NN).
-}
data ProviderAnswers = ProviderAnswers
  { answeredProvision :: Either ProviderOwnershipFault ProviderProvisionOutcome
  , answeredReady :: Either ProviderOwnershipFault ProviderReadyOutcome
  , answeredStop :: Either ProviderOwnershipFault ProviderStopOutcome
  , answeredShare :: Either ProviderOwnershipFault ProviderShareOutcome
  , answeredDelete :: Either ProviderOwnershipFault ProviderDeleteOutcome
  }

provisionCall ::
  ProviderUnderTest backendId ->
  PreparedProviderProvision scope planId backendId providerId operationKey callDigest attempt journalVersion ->
  IO (ProviderProvisionCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion)
provisionCall underTest prepared = case underTestAnswers underTest of
  Nothing -> runProviderProvisionCall (underTestBackend underTest) prepared
  Just answers -> pure (classifyProviderProvisionCall prepared (answeredProvision answers))

readyCall ::
  ProviderUnderTest backendId ->
  PreparedProviderReady scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion ->
  IO (ProviderReadyCallResult scope planId backendId providerId fromPhase operationKey callDigest attempt journalVersion)
readyCall underTest prepared = case underTestAnswers underTest of
  Nothing -> runProviderReadyCall (underTestBackend underTest) prepared
  Just answers -> pure (classifyProviderReadyCall prepared (answeredReady answers))

stopCall ::
  ProviderUnderTest backendId ->
  PreparedProviderStop scope planId backendId providerId operationKey callDigest attempt journalVersion ->
  IO (ProviderStopCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion)
stopCall underTest prepared = case underTestAnswers underTest of
  Nothing -> runProviderStopCall (underTestBackend underTest) prepared
  Just answers -> pure (classifyProviderStopCall prepared (answeredStop answers))

shareCall ::
  ProviderUnderTest backendId ->
  PreparedProviderShare scope planId backendId providerId shareId operationKey callDigest attempt journalVersion ->
  IO (ProviderShareCallResult scope planId backendId providerId shareId operationKey callDigest attempt journalVersion)
shareCall underTest prepared = case underTestAnswers underTest of
  Nothing -> runProviderShareCall (underTestBackend underTest) prepared
  Just answers -> pure (classifyProviderShareCall prepared (answeredShare answers))

deleteCall ::
  ProviderUnderTest backendId ->
  PreparedProviderDelete scope planId backendId providerId operationKey callDigest attempt journalVersion ->
  IO (ProviderDeleteCallResult scope planId backendId providerId operationKey callDigest attempt journalVersion)
deleteCall underTest prepared = case underTestAnswers underTest of
  Nothing -> runProviderDeleteCall (underTestBackend underTest) prepared
  Just answers -> pure (classifyProviderDeleteCall prepared (answeredDelete answers))

withDirectBackend ::
  (forall backendId. ProviderUnderTest backendId -> FilePath -> IO (Either ReconcileError summary)) ->
  IO (Either ReconcileError summary)
withDirectBackend consume =
  withRealHostTools $ \config root ->
    case mkDirectHostBackendSpec config root "alpine:3.22" of
      Left failure -> pure (Left failure)
      Right spec ->
        joinReconcile
          <$> discoverStrongProviderBackend config spec (\backend -> consume (ProviderUnderTest backend Nothing) root)

withIncusBackend ::
  ProviderAnswers ->
  (forall backendId. ProviderUnderTest backendId -> IO (Either ReconcileError summary)) ->
  IO (Either ReconcileError summary)
withIncusBackend answers consume =
  withRealHostTools $ \config _root ->
    case mkIncusBackendSpec "provider" "images:ubuntu/24.04" "provider" config (hostFixturePath "/test/provider-state") 4 "8GiB" "40GiB" of
      Left failure -> pure (Left failure)
      Right spec ->
        joinReconcile
          <$> discoverStrongProviderBackend config spec (\backend -> consume (ProviderUnderTest backend (Just answers)))

-- | Real host tools, and a real directory the Direct realization may admit.
--
-- The Direct probes are this binary's own observation and one described
-- command, so what a suite supplies is a root the kernel really answers for and
-- a program the interpreter really launches (§ NN); what the /provider/ answers
-- is a separate question and arrives as a value.
withRealHostTools :: (HostConfig -> FilePath -> IO result) -> IO result
withRealHostTools use =
  withSystemTempDirectory "hostbootstrap-provider-tools" $ \temporary -> do
    root <- canonicalizePath temporary
    let admissible = root </> "data"
    createDirectory admissible
    python <- Fixture.newFakeTool root "python3" ""
    docker <- Fixture.newFakeTool root "docker" ""
    incus <- Fixture.newFakeTool root "incus" ""
    use
      testHostConfig
        { hcToolPaths =
            Map.fromList
              [ (Python3, fixtureExe python),
                (Docker, fixtureExe docker),
                (Incus, fixtureExe incus)
              ]
        }
      admissible

{- | The one host directory this suite's share exposes.

Rendered onto the host that runs the suite, because the provider client that
would mount it runs there; the guest side of the same declaration stays POSIX,
because the process that reads it is inside the realized Linux substrate (§ MM).
-}
shareHostPath :: FilePath
shareHostPath = hostFixturePath "/srv/hostbootstrap/data"

shareGuestPath :: FilePath
shareGuestPath = "/srv/hostbootstrap/data"

-- | The identity a provider answers with for this suite's instance.
managedIdentity :: ObjectIdentity
managedIdentity = either (error . show) id (mkObjectIdentity "provider-17")

-- | The identity of an instance this project's records do not claim.
unclaimedIdentity :: ObjectIdentity
unclaimedIdentity = either (error . show) id (mkObjectIdentity "foreign-provider")

createdBackendReport :: ProviderAnswers
createdBackendReport =
  ProviderAnswers
    { answeredProvision = Right (ProvisionCreated managedIdentity)
    , answeredReady = Right (ReadyStarted managedIdentity)
    , answeredStop = Right (StopStopped managedIdentity)
    , answeredShare = Right ShareAttached
    , answeredDelete = Right DeleteRemoved
    }

ownedProvisionBackendReport :: ProviderAnswers
ownedProvisionBackendReport =
  createdBackendReport{answeredProvision = Right (ProvisionAlreadyOwned managedIdentity)}

repairedProvisionBackendReport :: ProviderAnswers
repairedProvisionBackendReport =
  createdBackendReport{answeredProvision = Right (ProvisionRecovered managedIdentity)}

foreignProvisionBackendReport :: ProviderAnswers
foreignProvisionBackendReport =
  createdBackendReport
    { answeredProvision =
        Left (ProviderOwnershipStanding (InstanceUnderNoRecord unclaimedIdentity))
    }

repairedShareBackendReport :: ProviderAnswers
repairedShareBackendReport = createdBackendReport{answeredShare = Right ShareRepaired}

readyShareBackendReport :: ProviderAnswers
readyShareBackendReport = createdBackendReport{answeredShare = Right ShareAlreadyAttached}

alreadyPhaseBackendReport :: ProviderAnswers
alreadyPhaseBackendReport =
  ProviderAnswers
    { answeredProvision = Right (ProvisionCreated managedIdentity)
    , answeredReady = Right (ReadyAlready managedIdentity)
    , answeredStop = Right (StopAlreadyStopped managedIdentity)
    , answeredShare = Right ShareAlreadyAttached
    , answeredDelete = Right DeleteAlreadyRemoved
    }

replacementStopBackendReport :: ProviderAnswers
replacementStopBackendReport =
  createdBackendReport
    { answeredStop =
        Left (ProviderOwnershipStanding (InstanceReplaced managedIdentity replacementIdentity))
    }

-- | The identity of an instance that replaced this run's under the same name.
replacementIdentity :: ObjectIdentity
replacementIdentity = either (error . show) id (mkObjectIdentity "replacement-vm")

joinReconcile :: Either ReconcileError (Either ReconcileError value) -> Either ReconcileError value
joinReconcile = either Left id

joinIO :: Either ReconcileError (IO (Either ReconcileError value)) -> IO (Either ReconcileError value)
joinIO = either (pure . Left) id

flattenIO :: IO (Either ReconcileError (IO (Either ReconcileError value))) -> IO (Either ReconcileError value)
flattenIO action = action >>= joinIO
