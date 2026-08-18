
module CompileFailSpec (tests) where

import Data.List (isInfixOf, isPrefixOf, isSuffixOf, stripPrefix)
import Data.Maybe (listToMaybe)
import HostBootstrap.DocValidator (findRepoRoot)
import System.Directory (
    findExecutable,
    getCurrentDirectory,
    listDirectory,
    withCurrentDirectory,
 )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import Test.Tasty (TestTree, testGroup, withResource)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

tests :: TestTree
tests =
    withResource resolvePublicCompiler (const (pure ())) $ \getCompiler ->
        testGroup
            "public compile-fail boundaries"
            (compileFailCases (rejectsUsing getCompiler) (rejectsWithUsing getCompiler))

compileFailCases ::
    (FilePath -> TestTree) ->
    (FilePath -> [String] -> TestTree) ->
    [TestTree]
compileFailCases rejects rejectsWith =
    [ rejects "RawStep.hs"
    , rejectsWith
        "ForgeValidatedConfig.hs"
        ["Illegal term-level use of the type constructor 'ValidatedConfig'"]
    , rejectsWith
        "ForgePlanDraft.hs"
        ["Illegal term-level use of the type constructor 'PlanDraft'"]
    , rejectsWith
        "ForgeIndexedProjectPlan.hs"
        ["Illegal term-level use of the type constructor 'ProjectPlan'"]
    , rejectsWith
        "CoercePlanDraftScope.hs"
        ["Couldn't match type 'ScopeA' with 'ScopeB'"]
    , rejectsWith
        "CoercePlanDraftSpec.hs"
        ["Couldn't match type 'SpecA' with 'SpecB'"]
    , rejectsWith
        "CoerceProjectPlanScope.hs"
        ["Couldn't match type 'ScopeA' with 'ScopeB'"]
    , rejectsWith
        "CoerceProjectPlanSpec.hs"
        ["Couldn't match type 'SpecA' with 'SpecB'"]
    , rejectsWith
        "CoerceProjectPlanIdentity.hs"
        ["Couldn't match type 'PlanA' with 'PlanB'"]
    , rejectsWith
        "CoerceProjectPlanConfig.hs"
        ["Couldn't match type 'ConfigA' with 'ConfigB'"]
    , rejectsWith
        "CoerceFinalizedProjectSpec.hs"
        ["Couldn't match type 'SpecA' with 'SpecB'"]
    , rejectsWith
        "ImportProjectPlanConstructInternal.hs"
        ["Could not load module 'HostBootstrap.ProjectPlan.Construct.Internal'. it is a hidden module"]
    , rejectsWith
        "ImportProjectPlanHandoffInternal.hs"
        ["Could not load module 'HostBootstrap.ProjectPlan.Handoff.Internal'. it is a hidden module"]
    , rejectsWith
        "ImportProjectPlanProjectionInternal.hs"
        ["Could not load module 'HostBootstrap.ProjectPlan.Projection.Internal'. it is a hidden module"]
    , rejectsWith
        "ImportLifecycleRootedPlan.hs"
        ["Could not load module 'HostBootstrap.Lifecycle.RootedPlan'. it is a hidden module"]
    , rejectsWith
        "ImportLifecycleFrameExecutor.hs"
        ["Could not load module 'HostBootstrap.Lifecycle.FrameExecutor'. it is a hidden module"]
    , rejectsWith
        "ImportHandoffProcessRoute.hs"
        ["Could not load module 'HostBootstrap.Handoff.Process.Route'. it is a hidden module"]
    , -- The lifecycle process owner is a platform row, and a row is built on
      -- every gate host and refuses where it cannot apply (§ JJ). It is
      -- therefore unreachable from a public importer for the same reason
      -- everywhere — the package builds it privately — and the fixture expects
      -- one diagnostic rather than one per host.
      rejectsWith
        "ImportHandoffProcess.hs"
        ["Could not load module 'HostBootstrap.Handoff.Process'. it is a hidden module"]
    , rejectsWith
        "RenderLifecycleProcessRouteArgv.hs"
        [ "Module 'HostBootstrap.Lift' does not export 'sanitizedLaunch'"
        , "Module 'HostBootstrap.Lift' does not export 'withLifecycleProcessRouteLaunchKernel'"
        ]
    , rejectsWith
        "OpenFrameExecutorGate.hs"
        [ "Module 'HostBootstrap.Lifecycle.Prepared' does not export 'mintPreparedGate'"
        , "Module 'HostBootstrap.Lifecycle.Prepared' does not export 'readPreparedGatePackageKernel'"
        , "Module 'HostBootstrap.Lifecycle.Prepared' does not export 'readPreparedGatePackagesKernel'"
        , "Module 'HostBootstrap.Lifecycle.Prepared' does not export 'renderPreparedNodeKeysKernel'"
        ]
    , rejectsWith
        "OpenImmediateTargetProjection.hs"
        ["Module 'HostBootstrap.ProjectPlan' does not export 'withImmediateTargetKernel'"]
    , rejectsWith
        "OpenRootedPlanCatalog.hs"
        [ "Module 'HostBootstrap.Lifecycle.Session' does not export 'RootedPlanCatalog'"
        , "Module 'HostBootstrap.Lifecycle.Session' does not export 'rootedPlanCatalogManifestKernel'"
        , "Module 'HostBootstrap.Lifecycle.Session' does not export 'rootedPlanCatalogManifestMatchesKernel'"
        , "Module 'HostBootstrap.Lifecycle.Session' does not export 'rootedPlanCatalogRecordIdentityKernel'"
        , "Module 'HostBootstrap.Lifecycle.Session' does not export 'withRootedPlanCatalogEdgeKernel'"
        , "Module 'HostBootstrap.Lifecycle.Session' does not export 'withRootedPlanCatalogEntriesKernel'"
        , "Module 'HostBootstrap.Lifecycle.Session' does not export 'withRootedPlanCatalogEntryKernel'"
        , "Module 'HostBootstrap.Lifecycle.Session' does not export 'withRootedPlanCatalogFrameKernel'"
        , "Module 'HostBootstrap.Lifecycle.Session' does not export 'withRootedPlanCatalogKernel'"
        , "Module 'HostBootstrap.Lifecycle.Session' does not export 'withRootedPlanCatalogRootKernel'"
        ]
    , rejectsWith
        "OpenPlannedForwardHandoff.hs"
        [ "Module 'HostBootstrap.ProjectPlan' does not export 'PlannedForwardHandoff'"
        , "Module 'HostBootstrap.ProjectPlan' does not export 'withPlannedForwardHandoffKernel'"
        , "Module 'HostBootstrap.ProjectPlan' does not export 'withPlannedForwardProcessInputsKernel'"
        ]
    , rejectsWith
        "OpenCatalogForwardHandoff.hs"
        [ "Module 'HostBootstrap.ProjectPlan' does not export 'CatalogForwardHandoff'"
        , "Module 'HostBootstrap.ProjectPlan' does not export 'withCatalogForwardHandoffKernel'"
        , "Module 'HostBootstrap.ProjectPlan' does not export 'withCatalogForwardProcessInputsKernel'"
        ]
    , rejectsWith
        "OpenFinalizedForwardChildProjector.hs"
        [ "an item called 'FinalizedProjectSpec' is exported"
        , "it does not export any children"
        , "called 'FinalizedProjectSpec'"
        , "Module 'HostBootstrap.ProjectPlan.Construct' does not export 'withFinalizedForwardChildProjectionKernel'"
        ]
    , rejectsWith
        "EscapeProjectPlanIdentity.hs"
        ["Couldn't match type 'planId' with 'ChosenPlan'"]
    , rejectsWith
        "ForgeValidatedLifecycleContext.hs"
        ["Illegal term-level use of the type constructor 'ValidatedLifecycleContext'"]
    , rejectsWith
        "CoerceValidatedLifecycleContextRoles.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'SpecificationA' with 'SpecificationB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ConfigurationA' with 'ConfigurationB' arising from a use of 'coerce'"
        , "Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "CrossValidatedLifecycleContextIndices.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB'"
        , "Couldn't match type 'SpecificationA' with 'SpecificationB'"
        , "Couldn't match type 'PlanA' with 'PlanB'"
        , "Couldn't match type 'ConfigurationA' with 'ConfigurationB'"
        , "Couldn't match type 'FrameA' with 'FrameB'"
        ]
    , rejectsWith
        "EscapeValidatedLifecycleContextFrame.hs"
        ["Couldn't match type 'frame' with 'SelectedFrame'"]
    , rejectsWith
        "OpenValidatedLifecycleContextAuthority.hs"
        [ "does not export 'validatedLifecycleContextCurrentFrame'"
        , "does not export 'validatedLifecycleContextFrameName'"
        , "does not export 'validatedLifecycleContextIsRoot'"
        , "does not export 'validatedLifecycleContextProjectFrame'"
        , "does not export 'validatedLifecycleContextStore'"
        ]
    , rejectsWith
        "ValidatedLifecycleContextAsAuthority.hs"
        [ "Couldn't match expected type: AcquisitionJournal Scope Plan Broker"
        , "Couldn't match expected type: LifecycleCursor Scope Plan Frame Broker VerbUp ExecutePhase"
        , "Couldn't match expected type: CommandAuthority Scope Plan Frame Broker VerbUp ExecutePhase"
        ]
    , rejectsWith
        "ImportLifecycleContextInternal.hs"
        ["Could not load module 'HostBootstrap.Lifecycle.Context.Internal'. it is a hidden module"]
    , rejectsWith
        "ImportAuthorityProjectPlanInternal.hs"
        ["Could not load module 'HostBootstrap.Authority.ProjectPlan.Internal'. it is a hidden module"]
    , rejectsWith
        "OpenChildRecoveryOrigin.hs"
        [ "Module 'HostBootstrap.Authority.ProjectPlan' does not export 'ChildRecoveryOrigin'"
        , "Module 'HostBootstrap.Authority.ProjectPlan' does not export 'withChildRecoveryOriginKernel'"
        , "Module 'HostBootstrap.Authority.ProjectPlan' does not export 'childRecoveryOriginFrameNameKernel'"
        , "Module 'HostBootstrap.Authority.ProjectPlan' does not export 'childRecoveryOriginVerbNameKernel'"
        , "Module 'HostBootstrap.Authority.ProjectPlan' does not export 'withChildRecoveryTerminalOriginKernel'"
        , "Module 'HostBootstrap.ProjectPlan.Construct' does not export 'withReceivedRecoveryChildOriginKernel'"
        ]
    , rejectsWith
        "ForgeLifecycleEntry.hs"
        ["Illegal term-level use of the type constructor 'LifecycleEntry'"]
    , rejectsWith
        "CoerceLifecycleEntryRoles.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbUp' with 'VerbDown' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "CrossLifecycleEntryIndices.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB'"
        , "Couldn't match type 'PlanA' with 'PlanB'"
        , "Couldn't match type 'FrameA' with 'FrameB'"
        , "Couldn't match type 'BrokerA' with 'BrokerB'"
        , "Couldn't match type 'VerbUp' with 'VerbDown'"
        ]
    , rejectsWith
        "ImportCommandLifecycleEntry.hs"
        ["Could not load module 'HostBootstrap.Command.LifecycleEntry'. it is a hidden module"]
    , rejectsWith
        "OpenLifecycleEntryProducer.hs"
        [ "Module 'HostBootstrap.Command' does not export 'AuthorizedChildCursor'"
        , "Module 'HostBootstrap.Command' does not export 'ChildRecoveryLifecycleEntry'"
        , "Module 'HostBootstrap.Command' does not export 'renderForwardTerminalOrigin'"
        , "Module 'HostBootstrap.Command' does not export 'runChildProjectUpLifecycleEntry'"
        , "Module 'HostBootstrap.Command' does not export 'runRootProjectUpLifecycleEntry'"
        , "Module 'HostBootstrap.Command' does not export 'settleRootedPlanCatalog'"
        , "Module 'HostBootstrap.Command' does not export 'withChildRecoveryTerminalOrigin'"
        , "Module 'HostBootstrap.Command' does not export 'withChildProjectUpLifecycleEntry'"
        , "Module 'HostBootstrap.Command' does not export 'withReceivedRecoveryChildLifecycleEntry'"
        , "Module 'HostBootstrap.Command' does not export 'withRootProjectUpLifecycleEntry'"
        , "Module 'HostBootstrap.Command' does not export 'withRootProjectReverseLifecycleEntry'"
        ]
    , rejectsWith
        "OpenPreparedRootReverseDescentProducer.hs"
        ["Module 'HostBootstrap.Command' does not export 'withPreparedRootReverseDescentKernel'"]
    , rejectsWith
        "OpenLifecycleEntryEvidence.hs"
        [ "does not export 'lifecycleEntryAuthority'"
        , "does not export 'lifecycleEntryConfig'"
        , "does not export 'lifecycleEntryContext'"
        , "does not export 'lifecycleEntryCursor'"
        , "does not export 'lifecycleEntryJournal'"
        , "does not export 'lifecycleEntryPlan'"
        , "does not export 'lifecycleEntryRecoveryDescent'"
        , "does not export 'lifecycleEntryRecoveryOrigin'"
        , "does not export 'lifecycleEntryStore'"
        ]
    , rejectsWith
        "ValidatedLifecycleContextAsLifecycleEntry.hs"
        ["Couldn't match expected type: LifecycleEntry Scope Plan Frame Broker VerbUp"]
    , rejectsWith
        "LifecycleEntryAsRawEvidence.hs"
        [ "Couldn't match expected type: CommandAuthority Scope Plan Frame Broker VerbUp ExecutePhase"
        , "Couldn't match expected type: AcquisitionJournal Scope Plan Broker"
        , "Couldn't match expected type: LifecycleCursor Scope Plan Frame Broker VerbUp ExecutePhase"
        ]
    , rejectsWith
        "RawReverseInputsAsLifecycleEntry.hs"
        [ "Couldn't match expected type: LifecycleEntry Scope Plan Frame Broker VerbDown"
        , "with actual type: RootInvocationAuthority Scope Broker VerbDown"
        , "with actual type: AcquisitionJournal Scope SourcePlan SourceBroker"
        , "with actual type: LifecycleCursor Scope SourcePlan SourceFrame SourceBroker VerbUp TeardownPhase"
        , "with actual type: AcquisitionJournal Scope Plan Broker"
        , "with actual type: LifecycleCursor Scope Plan Frame Broker VerbDown TeardownPhase"
        , "with actual type: CommandAuthority Scope Plan Frame Broker VerbDown TeardownPhase"
        ]
    , rejectsWith
        "ImportFormerAuthorizeProjectUp.hs"
        ["Module 'HostBootstrap.Authority.ProjectPlan' does not export 'authorizeProjectUp'"]
    , rejectsWith
        "ImportFormerAuthorizeChildProject.hs"
        ["Module 'HostBootstrap.Authority.ProjectPlan' does not export 'authorizeChildProject'"]
    , rejectsWith
        "RawFrameAuthorizeRootProject.hs"
        ["Couldn't match type: ProjectFrame scope spec plan config frame with: LifecycleCursor scope plan frame0 broker VerbUp phase0"]
    , rejectsWith
        "OpenCommandReservation.hs"
        [ "Module 'HostBootstrap.Authority' does not export 'CommandReservation'"
        , "Module 'HostBootstrap.Authority' does not export 'childCommandReservationKernel'"
        , "Module 'HostBootstrap.Authority' does not export 'commandReservationKernel'"
        , "Module 'HostBootstrap.Authority' does not export 'reserveCommandInvocationKernel'"
        ]
    , rejectsWith
        "ForgePlannedStep.hs"
        ["Illegal term-level use of the type constructor 'PlannedStep'"]
    , rejectsWith
        "ForgeDerivedTopology.hs"
        ["Illegal term-level use of the type constructor 'DerivedTopology'"]
    , rejectsWith
        "ForgeStablePlanSnapshot.hs"
        ["Illegal term-level use of the type constructor 'StablePlanSnapshot'"]
    , rejectsWith
        "CoercePlannedStepPlan.hs"
        ["Couldn't match type 'PlanA' with 'PlanB'"]
    , rejectsWith
        "CoercePlannedStepConfig.hs"
        ["Couldn't match type 'ConfigA' with 'ConfigB'"]
    , rejectsWith
        "CoercePlannedStepObservationRoles.hs"
        [ "Couldn't match type 'ObservationScopeA' with 'ObservationScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'ObservationPlanA' with 'ObservationPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ObservationConfigA' with 'ObservationConfigB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "ForgePlanResourceProjection.hs"
        [ "Illegal term-level use of the type constructor 'PlannedResource'"
        , "Illegal term-level use of the type constructor 'PlannedEdge'"
        ]
    , rejectsWith
        "CoercePlannedResourceRoles.hs"
        [ "Couldn't match type 'ResourceScopeA' with 'ResourceScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'ResourcePlanA' with 'ResourcePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ResourceIdentityA' with 'ResourceIdentityB' arising from a use of 'coerce'"
        , "Couldn't match type 'ResourceKindA' with 'ResourceKindB' arising from a use of 'coerce'"
        , "Couldn't match type 'ResourceFrameA' with 'ResourceFrameB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "CoercePlannedEdgeRoles.hs"
        [ "Couldn't match type 'EdgeScopeA' with 'EdgeScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'EdgePlanA' with 'EdgePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'TargetIdentityA' with 'TargetIdentityB' arising from a use of 'coerce'"
        , "Couldn't match type 'TargetKindA' with 'TargetKindB' arising from a use of 'coerce'"
        , "Couldn't match type 'TargetFrameA' with 'TargetFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'DependencyIdentityA' with 'DependencyIdentityB' arising from a use of 'coerce'"
        , "Couldn't match type 'DependencyKindA' with 'DependencyKindB' arising from a use of 'coerce'"
        , "Couldn't match type 'DependencyFrameA' with 'DependencyFrameB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "CrossPlanFramePlannedProjection.hs"
        [ "Couldn't match type 'ForeignProjectionPlan' with 'ProjectionPlan'"
        , "Couldn't match type 'ForeignTargetFrame' with 'TargetFrame'"
        , "Couldn't match type 'ForeignDependencyFrame' with 'DependencyFrame'"
        ]
    , rejectsWith
        "EscapePlannedResourceIndices.hs"
        [ "Couldn't match type 'resourceId' with 'ChosenResourceIdentity'"
        , "Couldn't match type 'frame' with 'ChosenResourceFrame'"
        ]
    , rejectsWith
        "LifecyclePlanAsResourceProjectionSource.hs"
        [ "Couldn't match expected type: ProjectPlan ProjectionScope SpecificationDigest PlanIdentity ConfigurationIdentity Configuration with actual type: LifecyclePlan ProjectionScope PlanIdentity"
        ]
    , rejectsWith
        "CrossPlanConfigStepExecution.hs"
        [ "Couldn't match type 'PlanB' with 'PlanA'"
        , "Couldn't match type 'ConfigurationB' with 'ConfigurationA'"
        ]
    , rejectsWith
        "CompatibilityInputsAsStepExecutionSource.hs"
        [ "Couldn't match expected type: ProjectPlan"
        , "with actual type: LifecyclePlan Scope Plan"
        , "Couldn't match expected type 'PlannedStep"
        , "with actual type 'Step'"
        ]
    , rejectsWith
        "CrossAuthorityChain.hs"
        [ "Couldn't match type 'ForeignScope' with 'Scope'"
        , "Couldn't match type 'AuthorityPlan' with 'Plan'"
        , "Couldn't match type 'Frame' with 'AuthorityFrame'"
        , "Couldn't match type 'Broker' with 'AuthorityBroker'"
        , "Couldn't match type 'VerbDown' with 'VerbUp'"
        , "Couldn't match type 'PreparePhase' with 'ExecutePhase'"
        ]
    , rejectsWith
        "CrossCursorChain.hs"
        [ "Couldn't match type 'ForeignScope' with 'Scope'"
        , "Couldn't match type 'CursorPlan' with 'Plan'"
        , "Couldn't match type 'CursorFrame' with 'Frame'"
        , "Couldn't match type 'CursorBroker' with 'Broker'"
        , "Couldn't match type 'VerbDown' with 'VerbUp'"
        , "Couldn't match type 'PreparePhase' with 'ExecutePhase'"
        ]
    , rejectsWith
        "CrossPlanCurrentFrameTeardown.hs"
        ["Couldn't match type 'PlanB' with 'PlanA'"]
    , rejectsWith
        "CrossFrameTeardownPlan.hs"
        ["Couldn't match type 'FrameA' with 'FrameB'"]
    , rejectsWith
        "CoerceTeardownPlanFrame.hs"
        ["Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"]
    , rejectsWith
        "ImportLegacyTeardownVerb.hs"
        [ "does not export 'DownVerb'"
        , "does not export 'DestroyVerb'"
        , "does not export 'TeardownVerb'"
        , "does not export 'downVerb'"
        , "does not export 'destroyVerb'"
        , "does not export 'teardownVerbName'"
        ]
    , rejectsWith
        "CoerceProjectVerb.hs"
        ["Couldn't match type 'VerbDown' with 'VerbDestroy' arising from a use of 'coerce'"]
    , rejectsWith
        "CrossVerbTeardownWork.hs"
        ["Couldn't match type 'VerbDestroy' with 'VerbDown'"]
    , rejectsWith
        "ProjectUpCannotVerifyDestroy.hs"
        [ "HostBootstrap.Authority.Kernel.VerbDestroy"
        , "with 'VerbUp'"
        ]
    , rejectsWith
        "DownCannotVerifyDestroy.hs"
        [ "HostBootstrap.Authority.Kernel.VerbDestroy"
        , "with 'VerbDown'"
        ]
    , rejectsWith
        "ForgeSubtreeSettlement.hs"
        [ "Illegal term-level use of the type constructor 'SubtreeSettled'"
        , "Illegal term-level use of the type constructor 'DestroySettled'"
        ]
    , rejectsWith
        "CoerceSubtreeSettlementRoles.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbA' with 'VerbB' arising from a use of 'coerce'"
        , "Couldn't match type 'DestroyScopeA' with 'DestroyScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'DestroyPlanA' with 'DestroyPlanB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "CrossSubtreeDescentSettlement.hs"
        [ "Couldn't match type 'PlanA' with 'PlanB'"
        , "Couldn't match type 'ParentA' with 'ParentB'"
        , "Couldn't match type 'ChildA' with 'ChildB'"
        , "Couldn't match type 'ChildA' with 'ParentA'"
        , "Couldn't match type 'VerbDestroy' with 'VerbDown'"
        , "Couldn't match expected type 'SubtreeSettled Scope PlanA ChildA VerbDestroy'"
        , "with actual type 'TeardownOutcome'"
        ]
    , rejectsWith
        "CallerSelectedDescentSubtree.hs"
        [ "Couldn't match expected type: TeardownPlan"
        , "with actual type: CurrentFrame Scope Plan Child"
        , "Couldn't match type: [Char]"
        , "TeardownPlan Scope Plan Child VerbDestroy"
        ]
    , rejectsWith
        "SubtreeAsDestroySettled.hs"
        [ "Couldn't match expected type: DestroySettled Scope Plan"
        , "with actual type: SubtreeSettled Scope Plan NestedFrame VerbDestroy"
        ]
    , rejectsWith
        "SubtreeAsDestroyClosure.hs"
        [ "HostBootstrap.Teardown.DestroySettled Scope Plan"
        , "with actual type: SubtreeSettled Scope Plan Frame VerbDestroy"
        ]
    , rejectsWith
        "FramedDestroySettled.hs"
        [ "Expected kind '* -> *'"
        , "but 'DestroySettled Scope Plan' has kind '*'"
        ]
    , rejectsWith
        "LegacyRootDestroyVerifier.hs"
        [ "HostBootstrap.Lifecycle.Plan.ProjectPlan"
        , "with: TeardownPlan Scope Plan Frame VerbDestroy"
        , "'verifyDestroySettled' is applied to too few arguments"
        ]
    , rejectsWith
        "CallerTextAsProjectVerb.hs"
        [ "Couldn't match type: [Char]"
        , "HostBootstrap.Authority.Kernel.ProjectVerb"
        ]
    , rejectsWith
        "CrossFrameTeardownPipeline.hs"
        [ "Couldn't match type 'OpenFrameA' with 'OpenFrameB'"
        , "Couldn't match type 'SuccessorFrameA' with 'SuccessorFrameB'"
        , "Couldn't match type 'WorkFrameB' with 'WorkFrameA'"
        , "Couldn't match type 'SettlementFrameB' with 'SettlementFrameA'"
        ]
    , rejectsWith
        "CoerceTeardownFrameRoles.hs"
        [ "Couldn't match type 'ForestFrameA' with 'ForestFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'ProgressFrameA' with 'ProgressFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'CompletedFrameA' with 'CompletedFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'AuthorizationFrameA' with 'AuthorizationFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreDescentFrameA' with 'PreDescentFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'ChildrenFrameA' with 'ChildrenFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'WorkFrameA' with 'WorkFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'SettledFrameA' with 'SettledFrameB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "ForgeTeardownWork.hs"
        [ "Illegal term-level use of the type constructor 'LocalWork'"
        , "Illegal term-level use of the type constructor 'DescentWork'"
        , "Data constructor not in scope: LocalTeardownWork"
        , "Data constructor not in scope: DescentTeardownWork"
        ]
    , rejectsWith
        "LocalWorkAsDescentWork.hs"
        [ "Couldn't match type: DescentWork Scope Plan Frame ChildFrame VerbDestroy"
        , "with: LocalWork Scope Plan Frame VerbDestroy"
        ]
    , rejectsWith
        "DescentWorkAsLocalRunner.hs"
        [ "Couldn't match type: LocalWork Scope Plan Frame VerbDestroy"
        , "with: DescentWork Scope Plan Frame ChildFrame VerbDestroy"
        ]
    , rejectsWith
        "CrossFrameLocalWork.hs"
        ["Couldn't match type 'FrameB' with 'FrameA'"]
    , rejectsWith
        "CrossFrameDescentWork.hs"
        [ "Couldn't match type 'ParentB' with 'ParentA'"
        , "Couldn't match type 'ChildB' with 'ChildA'"
        ]
    , rejectsWith
        "EscapeDescentChildFrame.hs"
        ["Couldn't match type 'childFrame' with 'ChosenChild'"]
    , rejectsWith
        "OpenTeardownWorkAgainstForeignForest.hs"
        [ "is applied to three visible arguments"
        , "has only two"
        ]
    , rejectsWith
        "ImportFormerTeardownCursor.hs"
        [ "does not export 'TeardownCursor'"
        , "does not export 'teardownCursorAction'"
        , "does not export 'teardownCursorFrame'"
        , "does not export 'teardownCursorKey'"
        , "does not export 'teardownCursorPolicy'"
        , "does not export 'teardownCursorRun'"
        ]
    , rejectsWith
        "ImportDirectTeardownAdvance.hs"
        [ "does not export 'attemptDescentWork'"
        , "does not export 'attemptTeardownStep'"
        , "does not export 'authorizationPointKey'"
        ]
    , rejectsWith
        "GenericPointTeardownDriver.hs"
        [ "Couldn't match type: TeardownAuthorizationPoint Scope Plan Frame VerbDestroy"
        , "with: PreDescentStep Scope Plan Frame VerbDestroy"
        ]
    , rejectsWith
        "ImportTeardownPlanNodeProjections.hs"
        [ "does not export 'runTeardownProjection'"
        , "does not export 'teardownPlanActions'"
        , "does not export 'teardownPlanOperationKeys'"
        , "does not export 'teardownPlanStepIdentities'"
        , "does not export 'teardownPlanStepKeys'"
        ]
    , rejectsWith
        "CoerceTeardownWorkRoles.hs"
        [ "Couldn't match type 'WorkScopeA' with 'WorkScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'WorkPlanA' with 'WorkPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'WorkFrameA' with 'WorkFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'WorkVerbA' with 'WorkVerbB' arising from a use of 'coerce'"
        , "Couldn't match type 'LocalScopeA' with 'LocalScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'LocalPlanA' with 'LocalPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'LocalFrameA' with 'LocalFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'LocalVerbA' with 'LocalVerbB' arising from a use of 'coerce'"
        , "Couldn't match type 'DescentScopeA' with 'DescentScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'DescentPlanA' with 'DescentPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'DescentParentA' with 'DescentParentB' arising from a use of 'coerce'"
        , "Couldn't match type 'DescentChildA' with 'DescentChildB' arising from a use of 'coerce'"
        , "Couldn't match type 'DescentVerbA' with 'DescentVerbB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "ImportTeardownInternal.hs"
        ["Could not load module 'HostBootstrap.Teardown.Internal'. it is a hidden module"]
    , rejectsWith
        "OpenReverseDescentSubstrate.hs"
        [ "Module 'HostBootstrap.Teardown' does not export 'BoundReverseDescent'"
        , "Module 'HostBootstrap.Teardown' does not export 'PreparedReverseDescent'"
        , "Module 'HostBootstrap.Teardown' does not export 'ReverseDescent'"
        , "Module 'HostBootstrap.Teardown' does not export 'withBoundReverseDescentKernel'"
        , "Module 'HostBootstrap.Teardown' does not export 'withPreparedReverseDescentKernel'"
        , "Module 'HostBootstrap.Teardown' does not export 'withRehydratedBoundReverseDescentKernel'"
        , "Module 'HostBootstrap.Teardown' does not export 'withReverseDescentLiftContextKernel'"
        , "Module 'HostBootstrap.Teardown' does not export 'withVerifiedBoundReverseDescentObservationsKernel'"
        , "Module 'HostBootstrap.Teardown' does not export 'withVerifiedBoundReverseDescentReportKernel'"
        , "Module 'HostBootstrap.Teardown' does not export 'withVerifiedReverseAdapterKernel'"
        ]
    , rejectsWith
        "LifecyclePlanAsTeardownPlanSource.hs"
        [ "Couldn't match expected type: ProjectPlan"
            ++ " Scope SpecificationDigest Plan ConfigurationIdentity Configuration"
            ++ " with actual type: LifecyclePlan Scope Plan"
        ]
    , rejectsWith
        "OpenTeardownForestWithLifecyclePlan.hs"
        ["with: LifecyclePlan Scope Plan"]
    , rejectsWith
        "OpenTeardownForestWithCurrentFrame.hs"
        ["with: CurrentFrame Scope Plan Frame"]
    , rejectsWith
        "DuplicateCurrentFrameTeardown.hs"
        [ "Couldn't match expected type: CurrentFrame Scope Plan Frame"
            ++ " -> TeardownPlan Scope Plan Frame VerbDown"
        ]
    , rejectsWith
        "CallerFrameNameTeardown.hs"
        ["Couldn't match type: [Char]"]
    , rejectsWith
        "ForgeTeardownPlan.hs"
        ["Illegal term-level use of the type constructor 'TeardownPlan'"]
    , rejectsWith
        "ForgeInitialTeardownForest.hs"
        ["Illegal term-level use of the type constructor 'TeardownForest'"]
    , rejectsWith
        "OpenReconcilePlanProjectionProducers.hs"
        [ "Module 'HostBootstrap.Reconcile' does not export 'withPlannedEdge'"
        , "Module 'HostBootstrap.Reconcile' does not export 'withPlannedResourceOfKind'"
        , "Module 'HostBootstrap.Reconcile' does not export 'withProviderGuestAliasProjection'"
        ]
    , rejectsWith
        "CoerceDerivedTopologyPlan.hs"
        ["Couldn't match type 'PlanA' with 'PlanB'"]
    , rejectsWith
        "ForgeCurrentFrame.hs"
        ["Illegal term-level use of the type constructor 'CurrentFrame'"]
    , rejectsWith
        "CoerceCurrentFramePlan.hs"
        ["Couldn't match type 'PlanA' with 'PlanB'"]
    , rejectsWith
        "CoerceCurrentFrameIdentity.hs"
        ["Couldn't match type 'FrameA' with 'FrameB'"]
    , rejectsWith
        "CoerceProjectFrameConfig.hs"
        ["Couldn't match type 'ConfigA' with 'ConfigB'"]
    , rejectsWith
        "ForgePlanDigestBinding.hs"
        ["Illegal term-level use of the type constructor 'PlanDigestBinding'"]
    , rejectsWith
        "CoercePlanDigestBindingDigest.hs"
        ["Couldn't match type 'DigestA' with 'DigestB'"]
    , rejectsWith
        "CoercePlanDigestBindingPlan.hs"
        ["Couldn't match type 'PlanA' with 'PlanB'"]
    , rejectsWith
        "ForgeBoundPlanSnapshot.hs"
        ["Illegal term-level use of the type constructor 'BoundPlanSnapshot'"]
    , rejectsWith
        "CoerceBoundPlanSnapshotScope.hs"
        ["Couldn't match type 'ScopeA' with 'ScopeB'"]
    , rejectsWith
        "CoerceBoundPlanSnapshotSpec.hs"
        ["Couldn't match type 'SpecA' with 'SpecB'"]
    , rejectsWith
        "CoerceBoundPlanSnapshotDigest.hs"
        ["Couldn't match type 'DigestA' with 'DigestB'"]
    , rejectsWith
        "CoerceBoundPlanSnapshotPlan.hs"
        ["Couldn't match type 'PlanA' with 'PlanB'"]
    , rejectsWith
        "CoerceNormalActiveRecoveryScope.hs"
        ["Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceNormalActiveRecoverySpec.hs"
        ["Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceNormalActiveRecoveryPlan.hs"
        ["Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceNormalActiveRecoveryDigest.hs"
        ["Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceNormalActiveRecoveryBroker.hs"
        ["Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"]
    , rejectsWith
        "ForgeBoundInvocationRecovery.hs"
        ["Illegal term-level use of the type constructor 'BoundInvocationRecovery'"]
    , rejectsWith
        "CoerceBoundInvocationRecoveryScope.hs"
        ["Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceBoundInvocationRecoverySpec.hs"
        ["Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceBoundInvocationRecoveryDigest.hs"
        ["Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceBoundInvocationRecoveryPlan.hs"
        ["Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceBoundInvocationRecoveryBroker.hs"
        ["Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"]
    , rejectsWith
        "OpenBoundSnapshotAdmissionToken.hs"
        ["Module 'HostBootstrap.Lifecycle.Mode' does not export 'existingBoundSnapshotAdmissionKernel'"]
    , rejectsWith
        "OpenObservedBoundInvocationRecovery.hs"
        ["Module 'HostBootstrap.Lifecycle.Mode' does not export 'ObservedBoundInvocationRecovery'"]
    , rejectsWith
        "OpenReverseRootIntent.hs"
        ["Module 'HostBootstrap.Lifecycle.Mode' does not export 'ReverseRootIntent'"]
    , rejectsWith
        "PassRawAdmissionToResumedReverseRoot.hs"
        [ "ExistingBoundSnapshotAdmission' with actual type '()'"
        , "first argument of 'withResumedExistingBoundReverseRootKernel'"
        ]
    , rejectsWith
        "PassRawAdmissionToFreshReverseRoot.hs"
        [ "ExistingBoundSnapshotAdmission' with actual type '()'"
        , "first argument of 'withFreshExistingBoundReverseRootKernel'"
        ]
    , rejectsWith
        "PassRawAdmissionToReauthorizedBoundSnapshot.hs"
        [ "ExistingBoundSnapshotAdmission' with actual type '()'"
        , "first argument of 'withReauthorizedBoundPlanSnapshotKernel'"
        ]
    , rejectsWith
        "PassFreshEvidenceToBoundSnapshot.hs"
        [ "Couldn't match expected type: InvocationCloseKey -> IO () with actual type: UnboundRunLease"
        , "Couldn't match expected type: InvocationCloseKey -> IO () with actual type: VerifiedPlanSnapshot"
        ]
    , rejectsWith
        "TerminalReceivesBoundPlanSnapshot.hs"
        ["Couldn't match expected type: IO () with actual type: BoundPlanSnapshot"]
    , rejectsWith
        "EscapeBoundSnapshotPlanIdentity.hs"
        ["Couldn't match type 'planId' with 'ChosenPlan'"]
    , rejectsWith
        "ForgeRecoveredProductionLifecycleProfile.hs"
        ["Illegal term-level use of the type constructor 'RecoveredProductionLifecycleProfile'"]
    , rejectsWith
        "CoerceRecoveredProductionProfileProject.hs"
        ["Couldn't match type 'ProjectA' with 'ProjectB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceRecoveredProductionProfileSpec.hs"
        ["Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceRecoveredProductionProfileDigest.hs"
        ["Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceRecoveredProductionProfilePlan.hs"
        ["Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceRecoveredProductionProfileBroker.hs"
        ["Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"]
    , rejectsWith
        "HarnessRecoveryAsRecoveredProductionProfile.hs"
        ["Couldn't match type: Harness Project Run with: Production Project"]
    , rejectsWith
        "TeardownRecoveryAsRecoveredProductionProfile.hs"
        ["Couldn't match type 'VerbDestroy' with 'VerbUp'"]
    , rejectsWith
        "QuantifyRecoveredProductionPlanIdentity.hs"
        [ "Couldn't match type: forall freshPlanId. RecoveredProductionLifecycleProfile"
            ++ " projectId specDigest planDigest freshPlanId brokerGeneration with:"
            ++ " RecoveredProductionLifecycleProfile projectId specDigest planDigest planId"
            ++ " brokerGeneration"
        ]
    , rejectsWith
        "CrossIndexedRecoveredProductionProfile.hs"
        ["Couldn't match type 'SpecB' with 'SpecA'"]
    , rejectsWith
        "CrossPlanDigestRecoveredProductionProfile.hs"
        ["Couldn't match type 'DigestB' with 'DigestA'"]
    , rejectsWith
        "CrossPlanIdRecoveredProductionProfile.hs"
        ["Couldn't match type 'PlanB' with 'PlanA'"]
    , rejectsWith
        "CrossBrokerRecoveredProductionProfile.hs"
        ["Couldn't match type 'BrokerB' with 'BrokerA'"]
    , rejectsWith
        "HarnessRootAsRecoveredProjectPlan.hs"
        ["Couldn't match type: Harness Project Run with: Production Project"]
    , rejectsWith
        "QuantifyRecoveredProjectPlanIdentity.hs"
        [ "Couldn't match type: forall freshPlanId. ProjectPlan"
            ++ " (Production projectId) specDigest freshPlanId configId cfg with:"
            ++ " ProjectPlan (Production projectId) specDigest planId configId cfg"
        ]
    , rejectsWith
        "ReselectReturnedRecoveredProjectPlan.hs"
        ["Couldn't match type 'planId' with 'ChosenPlan'"]
    , rejectsWith
        "CrossProfileSpecRecoveredProjectPlan.hs"
        ["Couldn't match type 'SpecA' with 'SpecB'"]
    , rejectsWith
        "CrossProfileDigestRecoveredProjectPlan.hs"
        ["Couldn't match type 'DigestA' with 'DigestB'"]
    , rejectsWith
        "CrossProfilePlanIdRecoveredProjectPlan.hs"
        ["Couldn't match type 'PlanA' with 'PlanB'"]
    , rejectsWith
        "CrossBoundSnapshotRecoveredProjectPlan.hs"
        ["Couldn't match type 'PlanB' with 'PlanA'"]
    , rejectsWith
        "CrossBindingRecoveredProjectPlan.hs"
        ["Couldn't match type 'DigestB' with 'DigestA'"]
    , rejectsWith
        "CrossConfigSpecRecoveredProjectPlan.hs"
        ["Couldn't match type 'CandidateSpecB' with 'CandidateSpecA'"]
    , rejectsWith
        "CrossRecoveredConfigSpecRecoveredProjectPlan.hs"
        ["Couldn't match type 'SpecB' with 'SpecA'"]
    , rejectsWith
        "HarnessDraftsAsRecoveredProjectPlan.hs"
        ["Couldn't match type: Harness Project Run with: Production Project"]
    , rejectsWith
        "HarnessCandidateAsRecoveredProjectPlanInputs.hs"
        ["Couldn't match type: Harness Project Run with: Production Project"]
    , rejectsWith
        "ImportConfigSchemaInternal.hs"
        ["Could not load module 'HostBootstrap.Config.Schema.Internal'. it is a hidden module"]
    , rejectsWith
        "ImportConfigClassInternal.hs"
        ["Could not load module 'HostBootstrap.Config.Class.Internal'. it is a hidden module"]
    , rejectsWith
        "ImportServiceInternal.hs"
        ["Could not load module 'HostBootstrap.Service.Internal'. it is a hidden module"]
    , rejectsWith
        "OpenProjectCodecReindex.hs"
        [ "an item called 'ProjectCodec' is exported, but it does not export any children"
        , "called 'ProjectCodec'"
        , "Module 'HostBootstrap.Config.Class' does not export 'installedCodecSpecDigest'"
        , "Module 'HostBootstrap.Config.Class' does not export 'reindexProjectCodecKernel'"
        ]
    , rejectsWith
        "OpenFinalizedServiceRegistryReindex.hs"
        [ "Module 'HostBootstrap.Service' does not export 'FinalizedServiceDefinition'"
        , "an item called 'FinalizedServiceRegistry' is exported, but it does not export any children"
        , "called 'FinalizedServiceRegistry'"
        , "Module 'HostBootstrap.Service' does not export 'reindexFinalizedServiceRegistryKernel'"
        ]
    , rejectsWith
        "CoerceProjectCodecSpec.hs"
        ["Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceFinalizedServiceRegistrySpec.hs"
        ["Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'"]
    , rejects "RawProjectSpec.hs"
    , rejects "ForgeProjectStepIdentity.hs"
    , rejects "ReplaceProjectContribution.hs"
    , rejects "DispatchUnfinishedBuilder.hs"
    , rejects "CrossFinalizationCodec.hs"
    , rejects "ForgeRoleParams.hs"
    , rejects "RawReadiness.hs"
    , rejects "RawBudget.hs"
    , rejectsWith
        "CrossPlanBudgetWorkload.hs"
        ["Couldn't match type 'PlanB' with 'PlanA'"]
    , rejectsWith
        "CrossPlanBudgetSlice.hs"
        ["Couldn't match type 'PlanB' with 'PlanA'"]
    , rejectsWith
        "CrossPlanBudgetProviderCapability.hs"
        ["Couldn't match type 'PlanB' with 'PlanA'"]
    , rejectsWith
        "CallerFenceProviderWallReservation.hs"
        ["'withProviderWallReservation' is applied to too few arguments"]
    , rejectsWith
        "CrossPartitionProviderWallReservation.hs"
        ["Couldn't match type 'partitionA' with 'partitionB'"]
    , rejectsWith
        "ImportBudgetInternal.hs"
        ["Could not load module 'HostBootstrap.Cluster.Budget.Internal'. it is a hidden module"]
    , rejectsWith
        "ImportColimaSettlementInternal.hs"
        ["Could not load module 'HostBootstrap.Ensure.Colima.Settlement.Internal'. it is a hidden module"]
    , rejectsWith
        "ImportColimaBackendInternal.hs"
        ["Could not load module 'HostBootstrap.Ensure.Colima.Backend.Internal'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:colima-backend-internal'"]
    , rejectsWith
        "ImportColimaResolverOverride.hs"
        ["Could not load module 'HostBootstrap.Ensure.Colima.Backend.Resolver.Override'. it is a hidden module in the package 'hostbootstrap-core-0.1.0.0:colima-backend-internal'"]
    , rejectsWith
        "ImportColimaResolverTesting.hs"
        ["Could not load module 'HostBootstrap.Ensure.Colima.Backend.Resolver.Testing'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:colima-backend-internal'"]
    , rejectsWith
        "ImportColimaResolverInstall.hs"
        ["Could not load module 'HostBootstrap.Ensure.Colima.Backend.Resolver.Install'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:colima-backend-internal'"]
    , rejectsWith
        "ImportProviderStartInternal.hs"
        ["Could not load module 'HostBootstrap.Reconcile.ProviderStart.Internal'. it is a hidden module"]
    , rejectsWith
        "ForgePreparedProviderStart.hs"
        ["Illegal term-level use of the type constructor 'PreparedProviderStart'"]
    , rejectsWith
        "CoercePreparedProviderStartRoles.hs"
        [ "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'CallDigestA' with 'CallDigestB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "ForgeProviderWallSettlementPermit.hs"
        ["Illegal term-level use of the type constructor 'ProviderWallSettlementPermit'"]
    , rejectsWith
        "RawObservationProviderWallSettlement.hs"
        ["Couldn't match expected type 'ProviderWallSettlementPermit"]
    , rejectsWith
        "CoerceProviderWallSettlementPermitRoles.hs"
        [ "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'OperationA' with 'OperationB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "CrossPlanColimaConsumer.hs"
        [ "Couldn't match type 'ForeignProviderPlan' with 'ColimaPlan'"
        , "Couldn't match type 'ForeignTopologyPlan' with 'ColimaPlan'"
        , "Couldn't match type 'ForeignPartitionPlan' with 'ColimaPlan'"
        , "Couldn't match type 'ForeignReservationPlan' with 'ColimaPlan'"
        ]
    , rejectsWith
        "ForgeColimaAuthorities.hs"
        [ "Illegal term-level use of the type constructor 'PreparedColimaWallCall'"
        , "Illegal term-level use of the type constructor 'LiveColimaWall'"
        , "Illegal term-level use of the type constructor 'ColimaCleanupAuthority'"
        , "Illegal term-level use of the type constructor 'PreparedColimaCleanupCall'"
        , "Data constructor not in scope: ColimaOwnedWallObservation"
        ]
    , rejectsWith
        "CoerceColimaAuthorityRoles.hs"
        [ "Couldn't match type 'PreparedScopeA' with 'PreparedScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedSpecificationDigestA' with 'PreparedSpecificationDigestB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedPlanA' with 'PreparedPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedConfigurationA' with 'PreparedConfigurationB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedProviderResourceA' with 'PreparedProviderResourceB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedProviderFrameA' with 'PreparedProviderFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedBudgetA' with 'PreparedBudgetB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedCapabilityA' with 'PreparedCapabilityB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedWallA' with 'PreparedWallB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedWorkloadsA' with 'PreparedWorkloadsB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedPartitionA' with 'PreparedPartitionB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedReservationA' with 'PreparedReservationB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedFenceA' with 'PreparedFenceB' arising from a use of 'coerce'"
        , "Couldn't match type 'LiveScopeA' with 'LiveScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'LiveSpecificationDigestA' with 'LiveSpecificationDigestB' arising from a use of 'coerce'"
        , "Couldn't match type 'LivePlanA' with 'LivePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'LiveConfigurationA' with 'LiveConfigurationB' arising from a use of 'coerce'"
        , "Couldn't match type 'LiveProviderResourceA' with 'LiveProviderResourceB' arising from a use of 'coerce'"
        , "Couldn't match type 'LiveProviderFrameA' with 'LiveProviderFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'LiveWallA' with 'LiveWallB' arising from a use of 'coerce'"
        , "Couldn't match type 'LiveEpochA' with 'LiveEpochB' arising from a use of 'coerce'"
        , "Couldn't match type 'LiveFenceA' with 'LiveFenceB' arising from a use of 'coerce'"
        , "Couldn't match type 'CleanupScopeA' with 'CleanupScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'CleanupSpecificationDigestA' with 'CleanupSpecificationDigestB' arising from a use of 'coerce'"
        , "Couldn't match type 'CleanupPlanA' with 'CleanupPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'CleanupConfigurationA' with 'CleanupConfigurationB' arising from a use of 'coerce'"
        , "Couldn't match type 'CleanupProviderResourceA' with 'CleanupProviderResourceB' arising from a use of 'coerce'"
        , "Couldn't match type 'CleanupProviderFrameA' with 'CleanupProviderFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'CleanupWallA' with 'CleanupWallB' arising from a use of 'coerce'"
        , "Couldn't match type 'CleanupEpochA' with 'CleanupEpochB' arising from a use of 'coerce'"
        , "Couldn't match type 'CleanupFenceA' with 'CleanupFenceB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedCleanupScopeA' with 'PreparedCleanupScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedCleanupSpecificationDigestA' with 'PreparedCleanupSpecificationDigestB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedCleanupPlanA' with 'PreparedCleanupPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedCleanupConfigurationA' with 'PreparedCleanupConfigurationB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedCleanupProviderResourceA' with 'PreparedCleanupProviderResourceB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedCleanupProviderFrameA' with 'PreparedCleanupProviderFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedCleanupWallA' with 'PreparedCleanupWallB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedCleanupEpochA' with 'PreparedCleanupEpochB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedCleanupFenceA' with 'PreparedCleanupFenceB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "ColimaAcquireCallAsCleanupGate.hs"
        ["Couldn't match expected type 'PreparedGate' with actual type 'PreparedColimaWallCall"]
    , rejectsWith
        "WrongColimaCleanupPhase.hs"
        ["Couldn't match type 'HostBootstrap.Reconcile.Destroyed' with 'Running'"]
    , rejectsWith
        "OpenColimaOwnershipBackend.hs"
        ["Module 'HostBootstrap.Ensure.Colima' does not export 'ColimaOwnershipBackend'"]
    , rejectsWith
        "OpenPreparedColimaMutationArgs.hs"
        ["Module 'HostBootstrap.Ensure.Colima' does not export 'preparedColimaWallArgs'"]
    , rejectsWith
        "CrossPlanClusterConsumer.hs"
        [ "Couldn't match type 'ForeignClusterPlan' with 'ClusterPlan'"
        , "Couldn't match type 'ForeignProviderPlan' with 'ClusterPlan'"
        , "Couldn't match type 'ForeignTopologyPlan' with 'ClusterPlan'"
        , "Couldn't match type 'ForeignSlicePlan' with 'ClusterPlan'"
        ]
    , rejectsWith
        "CompatibilityClusterInputs.hs"
        [ "with actual type: LifecyclePlan scope planId"
        , "with actual type: DependencySnapshot scope planId"
        ]
    , rejectsWith
        "CallerForgedClusterProbe.hs"
        ["with actual type: DependencyProbe scope planId providerId ProviderResource"]
    , rejectsWith
        "ProvisionedProviderClusterDependency.hs"
        ["Couldn't match type 'Provisioned' with 'HostBootstrap.Reconcile.Running'"]
    , rejectsWith
        "ForgeClusterAuthorities.hs"
        [ "Illegal term-level use of the type constructor 'PlanOwnedCluster'"
        , "Illegal term-level use of the type constructor 'PreparedClusterReconcile'"
        , "Illegal term-level use of the type constructor 'ClusterReconcileSettlement'"
        , "Illegal term-level use of the type constructor 'ClusterReconcileCallResult'"
        , "Illegal term-level use of the type constructor 'PreparedClusterCordon'"
        , "Illegal term-level use of the type constructor 'ClusterCordonCallResult'"
        , "Illegal term-level use of the type constructor 'AppliedClusterCordon'"
        , "Illegal term-level use of the type constructor 'ClusterReadiness'"
        , "Illegal term-level use of the type constructor 'ClusterReadinessCallResult'"
        , "Illegal term-level use of the type constructor 'PreparedClusterCleanup'"
        , "Illegal term-level use of the type constructor 'ClusterCleanupCallResult'"
        , "Illegal term-level use of the type constructor 'ManagedClusterHandle'"
        , "Illegal term-level use of the type constructor 'RunningProviderDependency'"
        ]
    , rejectsWith
        "CoerceClusterAuthorityRoles.hs"
        [ "Couldn't match type 'PackagePlanA' with 'PackagePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ReconcilePlanA' with 'ReconcilePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'SettlementPlanA' with 'SettlementPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ReconcileResultPlanA' with 'ReconcileResultPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedCordonPlanA' with 'PreparedCordonPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'CordonResultPlanA' with 'CordonResultPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'AppliedCordonPlanA' with 'AppliedCordonPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ReadinessPlanA' with 'ReadinessPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ReadinessResultPlanA' with 'ReadinessResultPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'CleanupPlanA' with 'CleanupPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'CleanupResultPlanA' with 'CleanupResultPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ManagedPlanA' with 'ManagedPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'DependencyPlanA' with 'DependencyPlanB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "ImportClusterObservationInternal.hs"
        ["Could not load module 'HostBootstrap.Cluster.Observation.Internal'. it is a hidden module"]
    , rejectsWith
        "ImportClusterBackendInternal.hs"
        ["Could not load module 'HostBootstrap.Cluster.Backend.Internal'"]
    , rejectsWith
        "OpenClusterBackendExecutor.hs"
        [ "Module 'HostBootstrap.Cluster.Backend' does not export 'ClusterCommandResult(..)'"
        , "Module 'HostBootstrap.Cluster.Backend' does not export 'ClusterExec(..)'"
        ]
    , rejectsWith
        "ForgeStrongClusterBackend.hs"
        ["Illegal term-level use of the type constructor 'StrongClusterBackend'"]
    , rejectsWith
        "CoerceBudgetEvidenceRoles.hs"
        [ "Couldn't match type 'WorkloadPlanA' with 'WorkloadPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'SlicePlanA' with 'SlicePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'CapabilityPlanA' with 'CapabilityPlanB' arising from a use of 'coerce'"
        ]
    , rejects "RawReconcile.hs"
    , rejectsWith
        "ForgeProviderCapability.hs"
        ["Illegal term-level use of the type constructor 'ProviderCapability'"]
    , rejectsWith
        "EscapeProviderCapabilityIdentity.hs"
        ["Couldn't match type 'capabilityId' with 'ChosenCapability'"]
    , rejectsWith
        "CoerceProviderCapabilityIdentity.hs"
        ["Couldn't match type 'CapabilityA' with 'CapabilityB' arising from a use of 'coerce'"]
    , rejects "ForgeStrongAliasBackend.hs"
    , rejects "ForgePreparedGuestAliasCall.hs"
    , rejects "ObservedReadyGuestAlias.hs"
    , rejects "ForeignGuestAliasRelease.hs"
    , rejects "CrossAliasReceipt.hs"
    , rejects "ForgePreparedProviderProvision.hs"
    , rejects "ForgePreparedProviderShare.hs"
    , rejectsWith
        "ForgeManagedProviderHandles.hs"
        [ "Illegal term-level use of the type constructor 'ManagedProviderHandle'"
        , "Illegal term-level use of the type constructor 'ManagedProviderShareHandle'"
        ]
    , rejectsWith
        "ForgeProviderPhaseAdvance.hs"
        ["Illegal term-level use of the type constructor 'ProviderPhaseAdvance'"]
    , rejectsWith
        "CoerceProviderPhaseAdvanceRoles.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'BackendA' with 'BackendB' arising from a use of 'coerce'"
        , "Couldn't match type 'ProviderA' with 'ProviderB' arising from a use of 'coerce'"
        , "Couldn't match type 'PhaseA' with 'PhaseB' arising from a use of 'coerce'"
        ]
    , rejects "ForgeProviderShareSpec.hs"
    , rejects "ForgeProviderObservation.hs"
    , rejects "ForgeProviderCallResult.hs"
    , rejects "ForgeProviderBackendBinding.hs"
    , rejects "CrossPreparedProviderResult.hs"
    , rejects "CrossBackendProviderCall.hs"
    , rejectsWith
        "CrossBackendProviderResult.hs"
        ["Couldn't match type 'backendB' with 'backendA'"]
    , rejectsWith
        "CoerceManagedProviderHandleRoles.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'BackendA' with 'BackendB' arising from a use of 'coerce'"
        , "Couldn't match type 'ProviderA' with 'ProviderB' arising from a use of 'coerce'"
        , "Couldn't match type 'PhaseA' with 'PhaseB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "CoerceManagedProviderShareHandleRoles.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'BackendA' with 'BackendB' arising from a use of 'coerce'"
        , "Couldn't match type 'ProviderA' with 'ProviderB' arising from a use of 'coerce'"
        , "Couldn't match type 'ShareA' with 'ShareB' arising from a use of 'coerce'"
        , "Couldn't match type 'PhaseA' with 'PhaseB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "GenericProviderHandleAsManaged.hs"
        ["ResourceHandle"]
    , rejectsWith
        "GenericProviderHandleAsBoundExec.hs"
        ["ResourceHandle"]
    , rejectsWith
        "GenericShareHandleAsAliasAuthority.hs"
        ["ResourceHandle"]
    , rejectsWith
        "ImportProviderObservationInternal.hs"
        ["Could not load module 'HostBootstrap.Substrate.Provider.Observation.Internal'. it is a hidden module"]
    , rejects "ForeignProviderStop.hs"
    , rejects "CrossProviderReceipt.hs"
    , rejects "UnstartableProviderPhase.hs"
    , rejects "BootNonProviderResource.hs"
    , rejects "ForgeSubstrateProvider.hs"
    , rejects "UpdateSubstrateProvider.hs"
    , rejects "OpenSubstrateProviderMutationSelectors.hs"
    , rejects "ForgeAliasCallObservation.hs"
    , rejects "CrossAliasCallResult.hs"
    , rejects "CrossBackendAliasCall.hs"
    , rejectsWith
        "ForeignClusterCleanup.hs"
        [ "with actual type: ResourceHandle scope planId clusterId ClusterResource Unmanaged Observed"
        , "Couldn't match expected type: ManagedClusterHandle scope planId clusterId"
        ]
    , rejectsWith
        "CrossClusterReceipt.hs"
        [ "Couldn't match type 'clusterB' with 'clusterA'"
        , "Expected: OwnershipReceipt scope planId clusterA ClusterResource"
        ]
    , rejects "HostLocalClusterRedirect.hs"
    , rejects "EndpointScopeSubstitution.hs"
    , rejects "RawRegistryPlan.hs"
    , rejects "ForgeReadyBlobRoute.hs"
    , rejectsWith
        "ForgeCommandAuthority.hs"
        ["Illegal term-level use of the type constructor ‘CommandAuthority’"]
    , rejectsWith
        "ForgeRootInvocationAuthority.hs"
        ["Illegal term-level use of the type constructor ‘RootInvocationAuthority’"]
    , rejectsWith
        "ForgeBrokerEpoch.hs"
        ["Illegal term-level use of the type constructor ‘BrokerEpoch’"]
    , rejectsWith
        "ForgeVerifiedOsPrincipal.hs"
        ["Illegal term-level use of the type constructor ‘VerifiedOsPrincipal’"]
    , rejectsWith
        "ForgeInvocationId.hs"
        ["Illegal term-level use of the type constructor ‘InvocationId’"]
    , rejectsWith
        "EscapeInstalledProjectIdentity.hs"
        ["Couldn't match type 'projectId' with 'ChosenProject'"]
    , rejectsWith
        "ForgeInstalledProjectIdentity.hs"
        ["Illegal term-level use of the type constructor 'InstalledProjectIdentity'"]
    , rejectsWith
        "OpenInstalledProjectAlias.hs"
        ["Module 'HostBootstrap.Authority' does not export 'InstalledProject'"]
    , rejectsWith
        "ImportInstalledProjectCompatibility.hs"
        ["Could not find module 'HostBootstrap.Config.InstalledProject'"]
    , rejectsWith
        "CrossRootScopeAuthority.hs"
        ["Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"]
    , rejectsWith
        "CrossRootInvocationAuthority.hs"
        ["Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"]
    , rejectsWith
        "ForgeRootScopeAuthority.hs"
        ["Illegal term-level use of the type constructor 'RootScopeAuthority'"]
    , rejectsWith
        "OpenRecordedBrokerEpoch.hs"
        ["Module 'HostBootstrap.Authority' does not export 'withRecordedBrokerEpoch'"]
    , rejectsWith
        "OpenRootInvocationAuthority.hs"
        ["Module 'HostBootstrap.Authority' does not export 'withVerifiedRootInvocation'"]
    , rejectsWith
        "OpenGenericCommandAuthority.hs"
        ["Module 'HostBootstrap.Authority' does not export 'authorizeProjectCommand'"]
    , rejectsWith
        "CrossScopeProjectUpAuthority.hs"
        ["Couldn't match type 'ScopeB' with 'ScopeA'"]
    , rejectsWith
        "CrossSpecProjectUpAuthority.hs"
        ["Couldn't match type 'SpecB' with 'SpecA'"]
    , rejectsWith
        "CrossPlanDigestProjectUpAuthority.hs"
        ["Couldn't match type 'PlanDigestB' with 'PlanDigestA'"]
    , rejectsWith
        "CrossPlanProjectUpAuthority.hs"
        ["Couldn't match type 'PlanB' with 'PlanA'"]
    , rejectsWith
        "CrossConfigProjectUpAuthority.hs"
        ["Couldn't match type 'ConfigB' with 'ConfigA'"]
    , rejectsWith
        "CrossFrameProjectUpAuthority.hs"
        ["Couldn't match type 'FrameB' with 'FrameA'"]
    , rejectsWith
        "CrossBrokerProjectUpAuthority.hs"
        ["Couldn't match type 'BrokerB' with 'BrokerA'"]
    , rejectsWith
        "CrossVerbProjectUpAuthority.hs"
        ["Couldn't match type 'VerbDown' with 'VerbUp'"]
    , rejectsWith
        "ImportAuthorityKernel.hs"
        ["Could not load module 'HostBootstrap.Authority.Kernel'. it is a hidden module"]
    , rejectsWith
        "CoerceInstalledProjectIdentity.hs"
        ["Couldn't match type 'ProjectA' with 'ProjectB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceBrokerEpoch.hs"
        ["Couldn't match type 'EpochA' with 'EpochB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceCommandAuthorityEpoch.hs"
        ["Couldn't match type 'EpochA' with 'EpochB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceCommandAuthorityVerb.hs"
        ["Couldn't match type 'VerbUp' with 'VerbDown' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceCommandAuthorityPhase.hs"
        ["Couldn't match type 'PreparePhase' with 'ExecutePhase' arising from a use of 'coerce'"]
    , rejectsWith
        "CrossScopeCommandAuthority.hs"
        ["Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"]
    , rejectsWith
        "CrossPlanCommandAuthority.hs"
        ["Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"]
    , rejectsWith
        "CrossFrameCommandAuthority.hs"
        ["Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"]
    , rejectsWith
        "CurrentFrameAsCommandAuthority.hs"
        [ "Couldn't match expected type: CommandAuthority"
        , "with actual type: CurrentFrame"
        ]
    , rejectsWith
        "ProjectFrameAsCommandAuthority.hs"
        [ "Couldn't match expected type: CommandAuthority"
        , "with actual type: ProjectFrame"
        ]
    , rejectsWith
        "ValidatedContextAsCommandAuthority.hs"
        [ "Couldn't match expected type: CommandAuthority"
        , "with actual type: ValidatedContext"
        ]
    , rejects "WrongVerbCloseRoot.hs"
    , rejectsWith
        "ForgeHarnessAuthority.hs"
        ["does not export any children"]
    , rejectsWith
        "OpenHarnessAuthorityFromText.hs"
        ["does not export", "withHarnessAuthority"]
    , rejectsWith
        "HarnessConfigAsProduction.hs"
        ["Expected: SecretRef (Production Project)"]
    , rejectsWith
        "CrossRunPlaintext.hs"
        [ "Expected: HarnessConfigAuthority Project runB"
        , "Actual: HarnessConfigAuthority Project runA"
        ]
    , rejectsWith
        "ProductionPlaintext.hs"
        ["Expected: SecretRef (Production Project)"]
    , rejectsWith
        "ForgeProductionMode.hs"
        ["Illegal term-level use of the type constructor 'ProductionMode'"]
    , rejectsWith
        "ForgeHarnessMode.hs"
        ["Illegal term-level use of the type constructor 'HarnessMode'"]
    , rejectsWith
        "ForgeProjectModeLease.hs"
        ["Illegal term-level use of the type constructor 'ProjectModeLease'"]
    , rejectsWith
        "CoerceHarnessModeRun.hs"
        ["Couldn't match type 'RunA' with 'RunB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceProjectModeLease.hs"
        ["Couldn't match type 'ProductionMode' with 'HarnessMode Run' arising from a use of 'coerce'"]
    , rejectsWith
        "OpenGenericProjectModeMutation.hs"
        ["Module 'HostBootstrap.Lifecycle.Mode' does not export 'acquireMode'"]
    , rejectsWith
        "ForgeRunId.hs"
        ["Illegal term-level use of the type constructor 'RunId'"]
    , rejectsWith
        "OpenRunIdFromText.hs"
        ["Module 'HostBootstrap.Lifecycle.Mode' does not export 'mkRunId'"]
    , rejectsWith
        "CoerceRunId.hs"
        ["Couldn't match type 'RunA' with 'RunB' arising from a use of 'coerce'"]
    , rejectsWith
        "ProductionLeaseAsHarnessSnapshot.hs"
        ["Couldn't match type: Harness Project Run with: Production Project Expected: VerifiedPlanSnapshot"]
    , rejectsWith
        "CrossRunLeaseBinding.hs"
        ["Couldn't match type 'RunB' with 'RunA' Expected: VerifiedPlanSnapshot"]
    , rejectsWith
        "CrossDigestLeaseBinding.hs"
        ["Couldn't match type 'SpecDigestB' with 'SpecDigestA' Expected: BoundRunLease"]
    , rejectsWith
        "ForgeActiveProjectMode.hs"
        ["Illegal term-level use of the type constructor 'ActiveProjectMode'"]
    , rejectsWith
        "ProductionActiveModeAsHarness.hs"
        ["Couldn't match type: Production Project with: Harness Project Run arising from a use of 'coerce'"]
    , rejectsWith
        "CrossRunActiveProjectMode.hs"
        ["Couldn't match type 'RunA' with 'RunB' arising from a use of 'coerce'"]
    , rejectsWith
        "HarnessLeaseAsProduction.hs"
        ["Couldn't match type: Harness Project Run with: Production Project Expected: RootScopeAuthority (Production Project)"]
    , rejectsWith
        "CrossBrokerProductionProfile.hs"
        ["Couldn't match type 'BrokerB' with 'BrokerA' Expected: UnboundRunLease (Production Project) BrokerA"]
    , rejectsWith
        "ProductionEvidenceAsHarnessProfile.hs"
        ["Couldn't match type: Production Project with: Harness Project Run Expected: RootScopeAuthority (Harness Project Run)"]
    , rejectsWith
        "CrossRunHarnessProfile.hs"
        ["Couldn't match type 'RunB' with 'RunA' Expected: ActiveProjectMode (Harness Project RunA) BrokerGeneration"]
    , rejectsWith
        "CrossBrokerHarnessProfile.hs"
        ["Couldn't match type 'BrokerB' with 'BrokerA' Expected: UnboundRunLease (Harness Project Run) BrokerA"]
    , rejectsWith
        "ProductionProjectPlanAsHarnessChain.hs"
        ["Couldn't match type: Harness Project Run with: Production Project"]
    , rejectsWith
        "CrossRunHarnessProjectPlanChain.hs"
        ["Couldn't match type 'RunB' with 'RunA'"]
    , rejectsWith
        "ForgeHarnessLifecycle.hs"
        [ "an item called 'HarnessLifecycle' is exported"
        , "it does not export any children"
        ]
    , rejectsWith
        "ImportHarnessLifecycleInternal.hs"
        ["Could not load module 'HostBootstrap.Harness.Lifecycle.Internal'"]
    , rejectsWith
        "ImportRawHarnessCloseAction.hs"
        ["Module 'HostBootstrap.Harness.Ownership' does not export 'stageOwnedHarnessClose'"]
    , rejectsWith
        "AuthorizeHarnessCloseWithoutClosure.hs"
        ["Couldn't match expected type 'HostBootstrap.Lifecycle.Mode.ProjectClosureEvidence (Harness Project Run)' with actual type 'Word64'"]
    , rejectsWith
        "ForgeRunLease.hs"
        [ "Illegal term-level use of the type constructor 'UnboundRunLease'"
        , "Illegal term-level use of the type constructor 'BoundRunLease'"
        ]
    , rejectsWith
        "ForgeAcquisitionJournal.hs"
        ["Illegal term-level use of the type constructor 'AcquisitionJournal'"]
    , rejectsWith
        "CoerceAcquisitionJournalScope.hs"
        ["Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceAcquisitionJournalPlan.hs"
        ["Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceAcquisitionJournalBroker.hs"
        ["Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"]
    , rejectsWith
        "CrossPlanAcquisitionJournal.hs"
        ["Couldn't match type 'PlanA' with 'PlanB'"]
    , rejectsWith
        "CrossBrokerAcquisitionJournal.hs"
        ["Couldn't match type 'BrokerA' with 'BrokerB'"]
    , rejectsWith
        "ImportAcquisitionJournalAdmission.hs"
        ["Could not load module 'HostBootstrap.Lifecycle.Plan'. it is a hidden module"]
    , rejectsWith
        "CoerceAcquisitionJournalAdmission.hs"
        [ "Couldn't match representation of type '()'"
        , "HostBootstrap.Lifecycle.Plan.AcquisitionJournalAdmission"
        ]
    , rejectsWith
        "PassRawAdmissionToReverseRootTargetCursor.hs"
        [ "AcquisitionJournalAdmission' with actual type '()'"
        , "first argument of 'withReverseRootTargetLifecycleCursorKernel'"
        ]
    , rejectsWith
        "PassRawAdmissionToReverseAcquisitionJournal.hs"
        [ "AcquisitionJournalAdmission' with actual type '()'"
        , "first argument of 'reopenExistingReverseAcquisitionJournalKernel'"
        ]
    , rejectsWith
        "AcquisitionJournalAsCommandAuthority.hs"
        [ "Couldn't match expected type: CommandAuthority"
        , "with actual type: AcquisitionJournal"
        ]
    , rejectsWith
        "ForgeLifecycleCursor.hs"
        ["Illegal term-level use of the type constructor 'LifecycleCursor'"]
    , rejectsWith
        "CoerceLifecycleCursorScope.hs"
        ["Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceLifecycleCursorPlan.hs"
        ["Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceLifecycleCursorFrame.hs"
        ["Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceLifecycleCursorBroker.hs"
        ["Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceLifecycleCursorVerb.hs"
        ["Couldn't match type 'VerbUp' with 'VerbDown' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceLifecycleCursorPhase.hs"
        ["Couldn't match type 'PreparePhase' with 'ExecutePhase' arising from a use of 'coerce'"]
    , rejectsWith
        "CrossScopeLifecycleCursorOpen.hs"
        ["Couldn't match type 'ScopeB' with 'ScopeA'"]
    , rejectsWith
        "CrossPlanLifecycleCursorOpen.hs"
        ["Couldn't match type 'PlanB' with 'PlanA'"]
    , rejectsWith
        "CrossFrameLifecycleCursor.hs"
        ["Couldn't match type 'FrameA' with 'FrameB'"]
    , rejectsWith
        "CrossBrokerLifecycleCursor.hs"
        ["Couldn't match type 'BrokerA' with 'BrokerB'"]
    , rejectsWith
        "CrossVerbLifecycleCursor.hs"
        ["Couldn't match type 'VerbUp' with 'VerbDown'"]
    , rejectsWith
        "CrossPhaseLifecycleCursor.hs"
        ["Couldn't match type 'PreparePhase' with 'ExecutePhase'"]
    , rejectsWith
        "EscapeLifecycleCursorFrame.hs"
        ["Couldn't match type 'frame' with 'ChosenFrame'"]
    , rejectsWith
        "SkipLifecycleCursorExecute.hs"
        ["Couldn't match type 'PreparePhase' with 'ExecutePhase'"]
    , rejectsWith
        "AdvanceTerminalLifecycleCursor.hs"
        ["Couldn't match type 'TeardownPhase' with 'ExecutePhase'"]
    , rejectsWith
        "LifecycleCursorAsCommandAuthority.hs"
        [ "Couldn't match expected type: CommandAuthority"
        , "with actual type: LifecycleCursor"
        ]
    , rejectsWith
        "LifecycleCursorAsTeardownCursor.hs"
        [ "Couldn't match expected type: LocalWork"
        , "with actual type: LifecycleCursor"
        ]
    , rejects "ForgeProtectedSession.hs"
    , rejectsWith
        "ForgeProjectSigningKey.hs"
        ["Illegal term-level use of the type constructor 'ProjectSigningKey'"]
    , rejectsWith
        "ForgeProjectVerificationKey.hs"
        ["Illegal term-level use of the type constructor 'ProjectVerificationKey'"]
    , rejectsWith
        "ProjectSigningKeyAsVerificationKey.hs"
        ["Couldn't match type 'ProjectSigningKey' with 'ProjectVerificationKey'"]
    , rejectsWith
        "CrossProtocolSigningKeys.hs"
        [ "Couldn't match type 'ProjectSigningKey' with 'BuildSigningKey'"
        , "Couldn't match type 'ProjectSigningKey' with 'ActivationSigningKey'"
        , "Couldn't match type 'BuildSigningKey' with 'ProjectSigningKey'"
        , "Couldn't match type 'BuildSigningKey' with 'ActivationSigningKey'"
        , "Couldn't match type 'ActivationSigningKey' with 'ProjectSigningKey'"
        , "Couldn't match type 'ActivationSigningKey' with 'BuildSigningKey'"
        ]
    , rejectsWith
        "ForgeHandoffOpaqueAuthorities.hs"
        [ "Data constructor not in scope: ProductionHandoffScope"
        , "Illegal term-level use of the type constructor 'HandoffBinding'"
        , "Illegal term-level use of the type constructor 'RootedPayloadBinding'"
        , "Illegal term-level use of the type constructor 'RecoveryChildPackage'"
        , "Illegal term-level use of the type constructor 'AuthenticatedRootScope'"
        , "Illegal term-level use of the type constructor 'RootBroker'"
        , "Illegal term-level use of the type constructor 'BrokerRoute'"
        , "Illegal term-level use of the type constructor 'BrokerRelay'"
        , "Illegal term-level use of the type constructor 'HandoffOffer'"
        , "Illegal term-level use of the type constructor 'AuthenticatedConfigPayload'"
        , "Illegal term-level use of the type constructor 'VerifiedHandoff'"
        ]
    , rejectsWith
        "CoerceHandoffOpaqueRoles.hs"
        [ "Couldn't match type 'HandoffScopeA' with 'HandoffScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'BindingScopeA' with 'BindingScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'BindingBrokerA' with 'BindingBrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'RootedBindingScopeA' with 'RootedBindingScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'RootedBindingBrokerA' with 'RootedBindingBrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'AuthenticatedScopeA' with 'AuthenticatedScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'RootScopeA' with 'RootScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'RootBrokerA' with 'RootBrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'RootVerbA' with 'RootVerbB' arising from a use of 'coerce'"
        , "Couldn't match type 'RouteScopeA' with 'RouteScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'RouteBrokerA' with 'RouteBrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'RelayScopeA' with 'RelayScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'RelayBrokerA' with 'RelayBrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'OfferScopeA' with 'OfferScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'OfferBrokerA' with 'OfferBrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'PayloadScopeA' with 'PayloadScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'PayloadBrokerA' with 'PayloadBrokerB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "EscapeParsedHandoffGeneration.hs"
        ["Couldn't match type 'brokerGeneration' with 'CallerChosenGeneration'"]
    , rejectsWith
        "CoerceVerifiedHandoffScope.hs"
        ["Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceVerifiedHandoffBroker.hs"
        ["Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"]
    , rejectsWith
        "CrossScopeBrokerRelay.hs"
        ["Couldn't match type: Harness projectId runId with: Production projectId"]
    , rejectsWith
        "CrossScopeAuthenticatedConfig.hs"
        ["Couldn't match type: Harness projectId runId with: Production projectId"]
    , rejectsWith
        "ImportHandoffReceiver.hs"
        ["Could not load module 'HostBootstrap.Handoff.Receiver'. it is a hidden module"]
    , rejectsWith
        "ImportHandoffReceiverInternal.hs"
        ["Could not load module 'HostBootstrap.Handoff.Receiver.Internal'. it is a hidden module"]
    , rejectsWith
        "ImportHandoffInternal.hs"
        ["Could not load module 'HostBootstrap.Handoff.Internal'. it is a hidden module"]
    , rejectsWith
        "ImportHandoffProtocol.hs"
        ["Could not load module 'HostBootstrap.Handoff.Protocol'. it is a hidden module"]
    , rejectsWith
        "ImportHandoffRooted.hs"
        ["Could not load module 'HostBootstrap.Handoff.Rooted'. it is a hidden module"]
    , rejectsWith
        "ImportHandoffRecovery.hs"
        ["Could not load module 'HostBootstrap.Handoff.Recovery'. it is a hidden module"]
    , rejectsWith
        "OpenRecoveryChildPackageDecoder.hs"
        [ "Variable not in scope: recoveryChildPackageFromWire"
        , "Variable not in scope: withRecoveryChildPackageFields"
        ]
    , rejectsWith
        "CallerFixedAuthenticatedRootScopeParser.hs"
        ["Variable not in scope: authenticatedRootScopeFromWire"]
    , rejectsWith
        "EscapeAuthenticatedRootScopeRun.hs"
        ["Couldn't match type 'runId' with 'CallerChosenRun'"]
    , rejectsWith
        "ImportHandoffRelay.hs"
        ["Could not load module 'HostBootstrap.Handoff.Relay'. it is a hidden module"]
    , rejectsWith
        "ImportHandoffRuntime.hs"
        ["Could not load module 'HostBootstrap.Handoff.Runtime'. it is a hidden module"]
    , rejectsWith
        "ImportLifecycleRooted.hs"
        ["Could not load module 'HostBootstrap.Lifecycle.Rooted'. it is a hidden module"]
    , rejectsWith
        "ImportLifecycleRootedReceipt.hs"
        ["Could not load module 'HostBootstrap.Lifecycle.Rooted.Receipt'. it is a hidden module"]
    , rejectsWith
        "ImportHandoffCompletion.hs"
        ["Could not load module 'HostBootstrap.Handoff.Completion'. it is a hidden module"]
    , rejectsWith
        "ImportHandoffLifecycle.hs"
        ["Could not load module 'HostBootstrap.Handoff.Lifecycle'. it is a hidden module"]
    , rejectsWith
        "HandoffLifecycleCompletionType.hs"
        [ "Module 'HostBootstrap.Handoff' does not export 'ForwardLifecycleCompletion'"
        , "Module 'HostBootstrap.Handoff' does not export 'LifecycleCompletion'"
        , "Module 'HostBootstrap.Handoff' does not export 'ReverseLifecycleCompletion'"
        ]
    , rejectsWith
        "HandoffLifecycleProducers.hs"
        [ "Module 'HostBootstrap.Handoff' does not export 'withAcknowledgedBoundReverseLifecycleCompletionKernel'"
        , "Module 'HostBootstrap.Handoff' does not export 'withAcknowledgedForwardLifecycleCompletionKernel'"
        , "Module 'HostBootstrap.Handoff' does not export 'withForwardLifecycleReportKernel'"
        , "Module 'HostBootstrap.Handoff' does not export 'withRehydratedAcknowledgedReverseLifecycleCompletionKernel'"
        , "Module 'HostBootstrap.Handoff' does not export 'withReverseLifecycleReportKernel'"
        ]
    , rejectsWith
        "HandoffLifecycleFold.hs"
        ["Module 'HostBootstrap.Handoff' does not export 'withLifecycleCompletionKernel'"]
    , rejectsWith
        "HandoffFormerRecoverySigners.hs"
        [ "Module 'HostBootstrap.Handoff' does not export 'signAdmittedRecoveryWire'"
        , "Module 'HostBootstrap.Handoff' does not export 'signRecoveryWire'"
        ]
    , rejectsWith
        "HandoffFormerProtocolReexport.hs"
        [ "Module 'HostBootstrap.Handoff' does not export 'BrokerLink'"
        , "Module 'HostBootstrap.Handoff' does not export 'ChildProtocolState'"
        , "Module 'HostBootstrap.Handoff' does not export 'ProtocolError'"
        , "Module 'HostBootstrap.Handoff' does not export 'ProtocolMessage'"
        , "Module 'HostBootstrap.Handoff' does not export 'ProtocolTag'"
        , "Module 'HostBootstrap.Handoff' does not export 'adoptLifecycleAcknowledgementThroughLink'"
        , "Module 'HostBootstrap.Handoff' does not export 'prepareLifecycleAcknowledgementThroughLink'"
        , "Module 'HostBootstrap.Handoff' does not export 'protocolMessage'"
        , "Module 'HostBootstrap.Handoff' does not export 'withReceivedLifecycleAcknowledgementKernel'"
        , "Module 'HostBootstrap.Handoff' does not export 'withReceivedRecoveryLifecycleAcknowledgementKernel'"
        ]
    , rejectsWith
        "HandoffFormerChannelProducers.hs"
        [ "Module 'HostBootstrap.Handoff' does not export 'HandoffChannel'"
        , "Module 'HostBootstrap.Handoff' does not export 'channelReceive'"
        , "Module 'HostBootstrap.Handoff' does not export 'channelSend'"
        , "Module 'HostBootstrap.Handoff' does not export 'handoffChannel'"
        , "Module 'HostBootstrap.Handoff' does not export 'protocolMessageRequestId'"
        , "Module 'HostBootstrap.Handoff' does not export 'readProtocolMessage'"
        , "Module 'HostBootstrap.Handoff' does not export 'stdioHandoffChannel'"
        , "Module 'HostBootstrap.Handoff' does not export 'writeProtocolMessage'"
        ]
    , rejectsWith
        "HandoffRecoverySigningCapability.hs"
        [ "Module 'HostBootstrap.Handoff' does not export 'RecoverySigningKernel'"
        , "Module 'HostBootstrap.Handoff' does not export 'consumeRecoverySigningKernel'"
        , "Module 'HostBootstrap.Handoff' does not export 'recoverySigningKernel'"
        ]
    , rejectsWith
        "CoerceHandoffRecoverySigningCapability.hs"
        [ "Couldn't match representation of type '()'"
        , "HostBootstrap.Handoff.Internal.RecoverySigningKernel"
        , "signRootedPayloadBindingKernel"
        , "signRootedLifecycleResponseKernel"
        , "signRecoveryChildPackageBindingKernel"
        , "signAuthenticatedRootScopeKernel"
        , "publishLifecycleReportKernel"
        , "receiveLifecycleAcknowledgementKernel"
        , "prepareLifecycleAcknowledgementKernel"
        , "adoptLifecycleAcknowledgementKernel"
        , "registerRecoverableAdmittedHandoffEdgeKernel"
        ]
    , rejectsWith
        "HandoffFormerReceiverSurface.hs"
        [ "Module 'HostBootstrap.Handoff' does not export 'ReceivedEdge'"
        , "Module 'HostBootstrap.Handoff' does not export 'ReceivedRecoveryDescent'"
        , "Module 'HostBootstrap.Handoff' does not export 'ReceiverError'"
        , "Module 'HostBootstrap.Handoff' does not export 'ReceiverExpectation'"
        , "Module 'HostBootstrap.Handoff' does not export 'mkReceivedEdge'"
        , "Module 'HostBootstrap.Handoff' does not export 'mkReceivedRecoveryDescent'"
        , "Module 'HostBootstrap.Handoff' does not export 'receivedEdgeBinding'"
        , "Module 'HostBootstrap.Handoff' does not export 'receivedEdgeChannel'"
        , "Module 'HostBootstrap.Handoff' does not export 'receivedEdgeConfig'"
        , "Module 'HostBootstrap.Handoff' does not export 'receivedEdgeAuthenticatedRootScope'"
        , "Module 'HostBootstrap.Handoff' does not export 'receivedEdgeHandoff'"
        , "Module 'HostBootstrap.Handoff' does not export 'receivedEdgeRequestId'"
        , "Module 'HostBootstrap.Handoff' does not export 'receiverErrorMessage'"
        , "Module 'HostBootstrap.Handoff' does not export 'withReceivedHandoffEdge'"
        , "Module 'HostBootstrap.Handoff' does not export 'withReceivedRecoveryDescent'"
        ]
    , rejectsWith
        "ForgeVerifiedConfigWire.hs"
        ["Illegal term-level use of the type constructor 'VerifiedConfigWire'"]
    , rejectsWith
        "CoerceVerifiedConfigWireRoles.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'"
        , "Couldn't match type 'ConfigA' with 'ConfigB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "EscapeVerifiedConfigWireIdentity.hs"
        [ "Couldn't match type 'configDigest' with 'ChosenWireDigest'"
        , "Couldn't match type 'configId' with 'ChosenConfigIdentity'"
        ]
    , rejectsWith
        "ForgeVerifiedConfigHandoff.hs"
        ["Illegal term-level use of the type constructor 'VerifiedConfigHandoff'"]
    , rejectsWith
        "CoerceVerifiedConfigHandoffRoles.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'ParentA' with 'ParentB' arising from a use of 'coerce'"
        , "Couldn't match type 'ChildA' with 'ChildB' arising from a use of 'coerce'"
        , "Couldn't match type 'ConfigA' with 'ConfigB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbA' with 'VerbB' arising from a use of 'coerce'"
        , "Couldn't match type 'PhaseA' with 'PhaseB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "EscapeVerifiedConfigHandoffIndices.hs"
        [ "Couldn't match type 'planDigest' with 'ChosenHandoffPlan'"
        , "Couldn't match type 'parentFrame' with 'ChosenHandoffParent'"
        , "Couldn't match type 'childFrame' with 'ChosenHandoffChild'"
        , "Couldn't match type 'phase' with 'ChosenHandoffPhase'"
        ]
    , rejectsWith
        "ImportProjectPlanChildInternal.hs"
        ["Could not load module 'HostBootstrap.ProjectPlan.Child.Internal'. it is a hidden module"]
    , rejectsWith
        "OpenAuthenticatedChildCursor.hs"
        [ "Module 'HostBootstrap.ProjectPlan.Construct' does not export 'AuthenticatedChildCursor'"
        , "Module 'HostBootstrap.ProjectPlan.Construct' does not export 'withAuthenticatedChildCursor'"
        ]
    , rejectsWith
        "OpenAuthenticatedChildCursorEvidence.hs"
        [ "does not export 'authenticatedChildCursorAuthority'"
        , "does not export 'authenticatedChildCursorContext'"
        , "does not export 'authenticatedChildCursorCursor'"
        , "does not export 'authenticatedChildCursorJournal'"
        , "does not export 'authenticatedChildCursorPlan'"
        , "does not export 'authenticatedChildCursorStore'"
        ]
    , rejectsWith
        "OpenAuthorizedChildCursor.hs"
        [ "Module 'HostBootstrap.ProjectPlan.Construct' does not export 'AuthorizedChildCursor'"
        , "Module 'HostBootstrap.ProjectPlan.Construct' does not export 'authorizeAuthenticatedChildCursorKernel'"
        , "Module 'HostBootstrap.ProjectPlan.Construct' does not export 'renderForwardTerminalOriginKernel'"
        , "Module 'HostBootstrap.ProjectPlan.Construct' does not export 'runAuthorizedChildCursorKernel'"
        ]
    , rejectsWith
        "ForgeChildPlanAuthority.hs"
        ["Illegal term-level use of the type constructor 'ChildPlanAuthority'"]
    , rejectsWith
        "CoerceChildPlanAuthorityRoles.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'"
        , "Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'"
        , "Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'ParentA' with 'ParentB' arising from a use of 'coerce'"
        , "Couldn't match type 'ChildA' with 'ChildB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ConfigA' with 'ConfigB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbA' with 'VerbB' arising from a use of 'coerce'"
        , "Couldn't match type 'PhaseA' with 'PhaseB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "EscapeChildProjectPlanIdentity.hs"
        ["Couldn't match type 'planId' with 'ChosenPlan'"]
    , rejectsWith
        "ForgeRecoveryProjectionInput.hs"
        ["Illegal term-level use of the type constructor 'RecoveryProjectionBindingInput'"]
    , rejectsWith
        "CoerceRecoveryProjectionBindingInputRoles.hs"
        [ "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ParentA' with 'ParentB' arising from a use of 'coerce'"
        , "Couldn't match type 'ChildA' with 'ChildB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "EscapeRecoveryProjectionInput.hs"
        [ "Couldn't match type 'planDigest' with 'CallerChosenRecoveryPlan'"
        , "Couldn't match type 'parentFrame' with 'CallerChosenRecoveryParent'"
        , "Couldn't match type 'childFrame' with 'CallerChosenRecoveryChild'"
        ]
    , rejectsWith
        "ForgeRecoveryProjectionBinding.hs"
        ["Illegal term-level use of the type constructor 'RecoveryProjectionBinding'"]
    , rejectsWith
        "CoerceRecoveryProjectionBindingRoles.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbA' with 'VerbB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ParentA' with 'ParentB' arising from a use of 'coerce'"
        , "Couldn't match type 'ChildA' with 'ChildB' arising from a use of 'coerce'"
        , "Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "EscapeRecoveryProjectionWireDigest.hs"
        ["Couldn't match type 'recoveryWireDigest' with 'CallerChosenRecoveryWireDigest'"]
    , rejectsWith
        "ForgeRecoveryWireGrant.hs"
        ["Illegal term-level use of the type constructor 'RecoveryWireGrant'"]
    , rejectsWith
        "CoerceRecoveryWireGrantRoles.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbA' with 'VerbB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ParentA' with 'ParentB' arising from a use of 'coerce'"
        , "Couldn't match type 'ChildA' with 'ChildB' arising from a use of 'coerce'"
        , "Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "ForgeVerifiedRecoveryWire.hs"
        ["Illegal term-level use of the type constructor 'VerifiedRecoveryWire'"]
    , rejectsWith
        "CoerceVerifiedRecoveryWireRoles.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbA' with 'VerbB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'"
        , "Couldn't match type 'WireA' with 'WireB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "EscapeVerifiedRecoveryWireIdentity.hs"
        ["Couldn't match type 'recoveryWireId' with 'CallerChosenVerifiedRecoveryWire'"]
    , rejectsWith
        "ForgeVerifiedRecoveryHandoff.hs"
        ["Illegal term-level use of the type constructor 'VerifiedRecoveryHandoff'"]
    , rejectsWith
        "CoerceVerifiedRecoveryHandoffRoles.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ParentA' with 'ParentB' arising from a use of 'coerce'"
        , "Couldn't match type 'ChildA' with 'ChildB' arising from a use of 'coerce'"
        , "Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'"
        , "Couldn't match type 'WireA' with 'WireB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbA' with 'VerbB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "EscapeVerifiedRecoveryHandoffIdentity.hs"
        ["Couldn't match type 'recoveryWireId' with 'CallerChosenVerifiedRecoveryHandoff'"]
    , rejectsWith
        "RecoveryProjectionWrongVerbJoin.hs"
        ["Couldn't match type 'VerbDestroy' with 'VerbDown'"]
    , rejectsWith
        "RecoveryGrantWrongVerbJoin.hs"
        ["Couldn't match type 'VerbDestroy' with 'VerbDown'"]
    , rejectsWith
        "ConfigGrantAsRecoveryGrant.hs"
        ["Couldn't match expected type: RecoveryWireGrant"]
    , rejectsWith
        "HandoffGrantAsActivationGrant.hs"
        ["Couldn't match type 'HandoffGrant scope broker' with 'ActivationGrant'"]
    , rejectsWith
        "RecoveryWireGrantAsActivationGrant.hs"
        ["Couldn't match type 'RecoveryWireGrant scope broker verb plan parent child digest' with 'ActivationGrant'"]
    , rejects "CrossScopeProjectRoot.hs"
    , rejectsWith
        "RawCanonicalHostMount.hs"
        ["Couldn't match type: [Char] with: HostBootstrap.ProjectRoot.CanonicalHostPath"]
    , rejectsWith
        "CrossRootCanonicalHostMount.hs"
        ["Couldn't match type 'RootB' with 'RootA'"]
    , rejectsWith
        "SignHandoffWithoutRootStore.hs"
        ["Variable not in scope: signHandoffGrant"]
    , rejects "ForgeSessionPermit.hs"
    , rejectsWith
        "ClosingPermitAsOpen.hs"
        [ "Couldn't match expected type: ProjectPermit"
        , "with actual type: ClosingProjectPermit"
        ]
    , rejectsWith
        "ForgeTransactionPermitFromDescriptor.hs"
        ["Data constructor not in scope: TransactionPermit"]
    , rejectsWith
        "ForgeBuildSigningKey.hs"
        ["Illegal term-level use of the type constructor 'BuildSigningKey'"]
    , rejectsWith
        "ForgeBuildVerificationKey.hs"
        ["Illegal term-level use of the type constructor 'BuildVerificationKey'"]
    , rejectsWith
        "ForgeBuildCoordinator.hs"
        ["Illegal term-level use of the type constructor 'BuildCoordinator'"]
    , rejectsWith
        "ForgeBuildGrant.hs"
        ["Illegal term-level use of the type constructor 'BuildGrant'"]
    , rejectsWith
        "ForgeImageBuildFrame.hs"
        ["Illegal term-level use of the type constructor 'ImageBuildFrame'"]
    , rejectsWith
        "ForgeBuildInvocationAuthority.hs"
        ["Illegal term-level use of the type constructor 'BuildInvocationAuthority'"]
    , rejectsWith
        "ForgeBuildCommandAuthority.hs"
        ["Illegal term-level use of the type constructor 'BuildCommandAuthority'"]
    , rejectsWith
        "EscapeProvisionedBuildCoordinator.hs"
        ["Couldn't match type 'coordinatorId' with 'ChosenCoordinator'"]
    , rejectsWith
        "EscapeVerifiedBuildInvocation.hs"
        [ "Couldn't match type 'project' with 'ChosenBuildProject'"
        , "Couldn't match type 'spec' with 'ChosenBuildSpec'"
        , "Couldn't match type 'config' with 'ChosenBuildConfig'"
        , "Couldn't match type 'frame' with 'ChosenBuildFrame'"
        , "Couldn't match type 'build' with 'ChosenBuildIdentity'"
        , "Couldn't match type 'source' with 'ChosenBuildSource'"
        , "Couldn't match type 'builder' with 'ChosenBuildBuilder'"
        ]
    , rejectsWith
        "BuildCoordinatorCannotExportVerificationKey.hs"
        ["Variable not in scope: buildCoordinatorKey"]
    , rejectsWith
        "BuildSigningKeyAsVerificationKey.hs"
        ["Couldn't match type 'BuildSigningKey' with 'BuildVerificationKey'"]
    , rejectsWith
        "ProjectVerificationKeyAsBuildVerificationKey.hs"
        ["Couldn't match type 'ProjectVerificationKey' with 'BuildVerificationKey'"]
    , rejectsWith
        "CoerceBuildCoordinatorIdentity.hs"
        ["Couldn't match type 'CoordinatorA' with 'CoordinatorB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceImageBuildFrameRoles.hs"
        [ "Couldn't match type 'ProjectA' with 'ProjectB' arising from a use of 'coerce'"
        , "Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'"
        , "Couldn't match type 'ConfigA' with 'ConfigB' arising from a use of 'coerce'"
        , "Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "CoerceBuildInvocationAuthorityRoles.hs"
        [ "Couldn't match type 'ProjectA' with 'ProjectB' arising from a use of 'coerce'"
        , "Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'"
        , "Couldn't match type 'ConfigA' with 'ConfigB' arising from a use of 'coerce'"
        , "Couldn't match type 'BuildA' with 'BuildB' arising from a use of 'coerce'"
        , "Couldn't match type 'SourceA' with 'SourceB' arising from a use of 'coerce'"
        , "Couldn't match type 'BuilderA' with 'BuilderB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "CoerceBuildCommandAuthorityRoles.hs"
        [ "Couldn't match type 'ProjectA' with 'ProjectB' arising from a use of 'coerce'"
        , "Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'"
        , "Couldn't match type 'ConfigA' with 'ConfigB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "ForgeActivationSigningKey.hs"
        ["Illegal term-level use of the type constructor 'ActivationSigningKey'"]
    , rejectsWith
        "ForgeActivationVerificationKey.hs"
        ["Illegal term-level use of the type constructor 'ActivationVerificationKey'"]
    , rejectsWith
        "ForgeActivationSigningPolicy.hs"
        ["Illegal term-level use of the type constructor 'ActivationSigningPolicy'"]
    , rejectsWith
        "ForgeActivationBroker.hs"
        ["Illegal term-level use of the type constructor 'ActivationBroker'"]
    , rejectsWith
        "ForgeVerifiedRuntimeRoleActivation.hs"
        ["Illegal term-level use of the type constructor 'VerifiedRuntimeRoleActivation'"]
    , rejectsWith
        "ForgeActivationSecretDigest.hs"
        ["Illegal term-level use of the type constructor 'ActivationSecretDigest'"]
    , rejectsWith
        "ReadActivationBrokerVerificationKey.hs"
        ["Variable not in scope: activationBrokerKey"]
    , rejectsWith
        "ActivationSigningKeyAsVerificationKey.hs"
        ["Couldn't match type 'ActivationSigningKey' with 'ActivationVerificationKey'"]
    , rejectsWith
        "ProjectVerificationKeyAsActivationVerificationKey.hs"
        ["Couldn't match type 'ProjectVerificationKey' with 'ActivationVerificationKey'"]
    , rejectsWith
        "BuildVerificationKeyAsActivationVerificationKey.hs"
        ["Couldn't match type 'BuildVerificationKey' with 'ActivationVerificationKey'"]
    , rejectsWith
        "CoerceActivationBrokerRoles.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbA' with 'VerbB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "CoerceVerifiedRuntimeRoleActivationRoles.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'"
        , "Couldn't match type 'BinaryA' with 'BinaryB' arising from a use of 'coerce'"
        , "Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'RevisionA' with 'RevisionB' arising from a use of 'coerce'"
        , "Couldn't match type 'InstanceA' with 'InstanceB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "EscapeVerifiedRuntimeRoleActivationFrame.hs"
        [ "Couldn't match type 'scope' with 'CallerActivationScope'"
        , "Couldn't match type 'planDigest' with 'CallerActivationPlan'"
        , "Couldn't match type 'specDigest' with 'CallerActivationSpec'"
        , "Couldn't match type 'binaryDigest' with 'CallerActivationBinary'"
        , "Couldn't match type 'frame' with 'CallerActivationFrame'"
        , "Couldn't match type 'revision' with 'CallerActivationRevision'"
        , "Couldn't match type 'instanceId' with 'CallerActivationInstance'"
        ]
    , rejectsWith
        "ForgeReservedRoleAdmission.hs"
        ["Illegal term-level use of the type constructor 'ReservedRoleAdmission'"]
    , rejectsWith
        "CoerceReservedRoleAdmissionRoles.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'RevisionA' with 'RevisionB' arising from a use of 'coerce'"
        , "Couldn't match type 'InstanceA' with 'InstanceB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "ForgeVerifiedRolePlanDraft.hs"
        ["Illegal term-level use of the type constructor 'VerifiedRolePlanDraft'"]
    , rejectsWith
        "CoerceVerifiedRolePlanDraftRoles.hs"
        [ "Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'RevisionA' with 'RevisionB' arising from a use of 'coerce'"
        , "Couldn't match type 'InstanceA' with 'InstanceB' arising from a use of 'coerce'"
        , "Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "ForgeRoleCursor.hs"
        [ "Illegal term-level use of the type constructor 'RoleCursor'"
        , "Illegal term-level use of the type constructor 'RolePlan'"
        , "Illegal term-level use of the type constructor 'VerifiedServicePlacement'"
        , "Illegal term-level use of the type constructor 'VerifiedNoRoleResources'"
        , "Illegal term-level use of the type constructor 'ReadyRoleHandles'"
        , "Illegal term-level use of the type constructor 'RolePlanDigestBinding'"
        ]
    , rejectsWith
        "ForgeTeardownForest.hs"
        [ "Couldn't match type 'VerbDown' with 'VerbDestroy'"
        , "Illegal term-level use of the type constructor 'TeardownForest'"
        , "Illegal term-level use of the type constructor 'DestroySettled'"
        ]
    , rejects "ForgePreconditionSet.hs"
    , rejects "ForgePreparedGate.hs"
    , -- A role performs only the effects its declared row names. 'HasEffect'
      -- has no empty-row equation, so the diagnostic names the effect the
      -- row lacks rather than reporting a generic mismatch.
      rejectsWith
        "UndeclaredServiceEffect.hs"
        ["Could not solve: \8216HasEffect DurableStore '[]\8217"]
    , rejectsWith
        "ForgeStepExecution.hs"
        [ "Illegal term-level use of the type constructor 'StepExecution'"
        , "Data constructor not in scope: ExecutionNode"
        ]
    , rejectsWith
        "CoerceExecutionRoles.hs"
        [ "Couldn't match type 'ExecutionScopeA' with 'ExecutionScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'ExecutionPlanA' with 'ExecutionPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'RuntimeScopeA' with 'RuntimeScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'RuntimePlanA' with 'RuntimePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'CarrierScopeA' with 'CarrierScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'CarrierPlanA' with 'CarrierPlanB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "CoerceResourceHandleRoles.hs"
        [ "Couldn't match type 'HandleScopeA' with 'HandleScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'HandlePlanA' with 'HandlePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'HandleIdentityA' with 'HandleIdentityB' arising from a use of 'coerce'"
        , "Couldn't match type 'HandleResourceA' with 'HandleResourceB' arising from a use of 'coerce'"
        , "Couldn't match type 'HandleOwnershipA' with 'HandleOwnershipB' arising from a use of 'coerce'"
        , "Couldn't match type 'HandlePhaseA' with 'HandlePhaseB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "CoerceReconcilePlanRoles.hs"
        [ "Couldn't match type 'LifecyclePlanA' with 'LifecyclePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ReceiptPlanA' with 'ReceiptPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ForeignOriginPlanA' with 'ForeignOriginPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'AdoptionPlanA' with 'AdoptionPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'DescriptorPlanA' with 'DescriptorPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ProbePlanA' with 'ProbePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'SnapshotPlanA' with 'SnapshotPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreconditionsPlanA' with 'PreconditionsPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedOperationPlanA' with 'PreparedOperationPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedPreconditionsPlanA' with 'PreparedPreconditionsPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ResultPlanA' with 'ResultPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'JournalRecordPlanA' with 'JournalRecordPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'CommitProofPlanA' with 'CommitProofPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'TransitionPlanA' with 'TransitionPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerifiedPhasePlanA' with 'VerifiedPhasePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'AdvancePlanA' with 'AdvancePlanB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "CoerceReconcileEvidenceRoles.hs"
        [ "Couldn't match type 'LifecycleScopeA' with 'LifecycleScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'LifecyclePlanA' with 'LifecyclePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ReceiptIdentityA' with 'ReceiptIdentityB' arising from a use of 'coerce'"
        , "Couldn't match type 'ReceiptResourceA' with 'ReceiptResourceB' arising from a use of 'coerce'"
        , "Couldn't match type 'DescriptorFromA' with 'DescriptorFromB' arising from a use of 'coerce'"
        , "Couldn't match type 'DescriptorToA' with 'DescriptorToB' arising from a use of 'coerce'"
        , "Couldn't match type 'TransitionFromA' with 'TransitionFromB' arising from a use of 'coerce'"
        , "Couldn't match type 'TransitionToA' with 'TransitionToB' arising from a use of 'coerce'"
        , "Couldn't match type 'ResultPhaseA' with 'ResultPhaseB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "CoerceReconcileSemanticRoles.hs"
        [ "Couldn't match type 'ForeignOriginA' with 'ForeignOriginB' arising from a use of 'coerce'"
        , "Couldn't match type 'AdoptionOriginA' with 'AdoptionOriginB' arising from a use of 'coerce'"
        , "Couldn't match type 'AdoptionOperationA' with 'AdoptionOperationB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedOperationKeyA' with 'PreparedOperationKeyB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedOperationCallA' with 'PreparedOperationCallB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedOperationAttemptA' with 'PreparedOperationAttemptB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedOperationJournalA' with 'PreparedOperationJournalB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedPreconditionsKeyA' with 'PreparedPreconditionsKeyB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedPreconditionsCallA' with 'PreparedPreconditionsCallB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedPreconditionsAttemptA' with 'PreparedPreconditionsAttemptB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedPreconditionsJournalA' with 'PreparedPreconditionsJournalB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerifiedPhaseA' with 'VerifiedPhaseB' arising from a use of 'coerce'"
        , "Couldn't match type 'AdvancePhaseA' with 'AdvancePhaseB' arising from a use of 'coerce'"
        ]
    , rejectsWith
        "MismatchPreparedPairRoles.hs"
        [ "Couldn't match type 'PairOperationB' with 'PairOperationA'"
        , "Couldn't match type 'PairAttemptB' with 'PairAttemptA'"
        ]
    , rejectsWith
        "ForgeDetachedLaunch.hs"
        [ "Illegal term-level use of the type constructor 'DetachedLaunch'"
        , "Illegal term-level use of the type constructor 'DetachedChild'"
        , "Illegal term-level use of the type constructor 'DetachedWorkingDirectory'"
        , "Illegal term-level use of the type constructor 'DetachedOutputSink'"
        , "Variable not in scope: detachedProcess :: DetachedLaunch -> CreateProcess"
        ]
    , rejectsWith
        "RelabelDetachedLaunch.hs"
        ["Not in scope: record field 'dlArguments'"]
    ]

data PublicCompiler = PublicCompiler FilePath [String]

rejectsUsing :: IO PublicCompiler -> FilePath -> TestTree
rejectsUsing getCompiler fixture = rejectsWithUsing getCompiler fixture []

rejectsWithUsing :: IO PublicCompiler -> FilePath -> [String] -> TestTree
rejectsWithUsing getCompiler fixture expectedDiagnostics =
    testCase fixture $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        cwd <- getCurrentDirectory
        root <- findRepoRoot cwd >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
        let coreRoot = root </> "core"
            fixturePath = "hostbootstrap-core" </> "test" </> "compile-fail" </> fixture
        (code, _, err) <-
            withCurrentDirectory coreRoot $
                readProcessWithExitCode
                    compiler
                    (compilerArgs ++ [fixturePath])
                    ""
        case code of
            ExitFailure _ -> do
                assertBool
                    ("compile-fail fixture produced no diagnostic: " ++ fixture)
                    (not (null err))
                mapM_
                    ( \expected ->
                        assertBool
                            ( "compile-fail fixture produced the wrong diagnostic: "
                                ++ fixture
                                ++ "; expected to find "
                                ++ show expected
                                ++ " in:\n"
                                ++ err
                            )
                            (normalizeDiagnostic expected `isInfixOf` normalizeDiagnostic err)
                    )
                    expectedDiagnostics
            _ -> assertFailure ("compile-fail fixture unexpectedly compiled: " ++ fixture)

{- | Resolve a compiler environment that has exactly the public main library
exposed.

The test component also depends on the Cabal-private Harness lifecycle
sublibrary so HarnessSpec can exercise the engine. A nested @cabal exec ghc@
therefore sees privileged component packages and is not a downstream consumer:
it can import that constructor module, and Cabal may select either local library
for @-package hostbootstrap-core@. We instead ask Cabal for the pinned compiler
and store paths, expose the main in-place unit explicitly, and leave the private
sublibrary hidden. Public compile-fail fixtures now run in the same package
visibility shape a real consumer receives.
-}
resolvePublicCompiler :: IO PublicCompiler
resolvePublicCompiler = do
    cwd <- getCurrentDirectory
    root <- findRepoRoot cwd >>= maybe (fail ("could not locate repo root from " ++ cwd)) pure
    let coreRoot = root </> "core"
    cabalExecutable <-
        findExecutable "cabal"
            >>= maybe (fail "could not resolve cabal while resolving the public compiler") pure
    (pathCode, pathOutput, pathError) <-
        withCurrentDirectory coreRoot $
            readProcessWithExitCode cabalExecutable ["path"] ""
    case pathCode of
        ExitSuccess -> pure ()
        ExitFailure _ ->
            fail ("cabal path failed while resolving the public compiler:\n" ++ pathError)
    compiler <- requiredCabalPathField "compiler-path" pathOutput
    compilerId <- requiredCabalPathField "compiler-id" pathOutput
    compilerStore <- requiredCabalPathField "compiler-store-path" pathOutput
    let localPackageDb = coreRoot </> "dist-newstyle" </> "packagedb" </> compilerId
        storePackageDb = compilerStore </> "package.db"
    packageConfs <- listDirectory localPackageDb
    mainConf <-
        case [ name
             | name <- packageConfs
             , "hostbootstrap-core-" `isPrefixOf` name
             , "-inplace.conf" `isSuffixOf` name
             ] of
            [name] -> pure name
            observed ->
                fail
                    ( "expected exactly one main hostbootstrap-core package registration in "
                        ++ localPackageDb
                        ++ ", observed "
                        ++ show observed
                    )
    registration <- readFile (localPackageDb </> mainConf)
    mainUnit <-
        case listToMaybe
            [ unitId
            | line <- lines registration
            , "id:" : unitId : _ <- [words line]
            ] of
            Just unitId -> pure unitId
            Nothing -> fail ("main package registration has no unit id: " ++ mainConf)
    pure
        ( PublicCompiler
            compiler
            [ "-package-env"
            , "-"
            , "-clear-package-db"
            , "-global-package-db"
            , "-package-db"
            , storePackageDb
            , "-package-db"
            , localPackageDb
            , "-hide-all-packages"
            , "-package"
            , "base"
            , "-package"
            , "bytestring"
            , "-package"
            , "process"
            , "-package"
            , "text"
            , "-package-id"
            , mainUnit
            , "-fno-code"
            ]
        )

requiredCabalPathField :: String -> String -> IO String
requiredCabalPathField field output =
    case listToMaybe
        [ value
        | line <- lines output
        , Just value <- [stripPrefix (field ++ ": ") line]
        ] of
        Just value -> pure value
        Nothing -> fail ("cabal path did not report " ++ field)

{- | Normalise a diagnostic to the axes an expectation is allowed to depend on:
its words, in order, and the identifiers it quotes.

Two renderings vary without the rejection changing. GHC breaks a diagnostic
across continuation lines when the rendered type is wide, so the same rejection
reads @"Variable not in scope: f"@ for a short signature and
@"Variable not in scope:\\n    f\\n      :: ..."@ for a long one; and it quotes
an identifier with typographic quotes when the handle encoding admits them and
ASCII quotes when it does not, so the same rejection names @DetachedLaunch@
differently under a UTF-8 and a C locale.

Neither axis says whether the fixture was rejected for the intended reason, so
both are normalised away. That is what lets an expectation stay **one
contiguous phrase** including the identifier it names — the shape
@documents/architecture/unrepresentable_state.md@ requires, because a phrase
split into separately-matched tokens can be satisfied by an unrelated in-scope
error on the same line. Normalisation cannot admit an unrelated compiler
failure: the fixture must still fail to compile, and the whole phrase must
still appear.
-}
normalizeDiagnostic :: String -> String
normalizeDiagnostic = unwords . words . map normalizeQuote
  where
    normalizeQuote c
        | c `elem` typographicQuotes = '\''
        | otherwise = c
    -- U+2018/U+2019 single and U+201C/U+201D double typographic quotes, plus
    -- the backtick GHC's ASCII rendering pairs with a closing apostrophe.
    typographicQuotes :: String
    typographicQuotes = ['\8216', '\8217', '\8220', '\8221', '`']
