module CompileFailSpec (tests) where

import Data.List (isInfixOf, isPrefixOf, isSuffixOf, stripPrefix)
import Data.Maybe (listToMaybe)
import HostBootstrap.DocValidator (findRepoRoot)
import System.Directory (getCurrentDirectory, listDirectory, withCurrentDirectory)
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
        "EscapeProjectPlanIdentity.hs"
        ["Couldn't match type 'planId' with 'ChosenPlan'"]
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
        "LifecyclePlanAsTeardownPlanSource.hs"
        [ "Couldn't match expected type: ProjectPlan"
            ++ " Scope SpecificationDigest Plan ConfigurationIdentity Configuration"
            ++ " with actual type: LifecyclePlan Scope Plan"
        ]
    , rejects "OpenTeardownForestWithLifecyclePlan.hs"
    , rejects "OpenTeardownForestWithCurrentFrame.hs"
    , rejects "DuplicateCurrentFrameTeardown.hs"
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
    , rejects "ForeignClusterCleanup.hs"
    , rejects "CrossClusterReceipt.hs"
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
        [ "Couldn't match expected type: TeardownCursor"
        , "with actual type: LifecycleCursor"
        ]
    , rejects "ForgeProtectedSession.hs"
    , rejectsWith
        "ForgeProtocolMessage.hs"
        ["Illegal term-level use of the type constructor 'ProtocolMessage'"]
    , rejectsWith
        "ForgeChildProtocolState.hs"
        ["Data constructor not in scope: ChildRunning"]
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
        , "Illegal term-level use of the type constructor 'RootBroker'"
        , "Illegal term-level use of the type constructor 'BrokerRoute'"
        , "Illegal term-level use of the type constructor 'BrokerRelay'"
        , "Illegal term-level use of the type constructor 'HandoffOffer'"
        , "Illegal term-level use of the type constructor 'AuthenticatedConfigPayload'"
        , "Illegal term-level use of the type constructor 'ReceivedEdge'"
        , "Illegal term-level use of the type constructor 'BrokerLink'"
        , "Illegal term-level use of the type constructor 'VerifiedHandoff'"
        ]
    , rejectsWith
        "CoerceHandoffOpaqueRoles.hs"
        [ "Couldn't match type 'HandoffScopeA' with 'HandoffScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'BindingScopeA' with 'BindingScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'BindingBrokerA' with 'BindingBrokerB' arising from a use of 'coerce'"
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
        , "Couldn't match type 'ReceivedScopeA' with 'ReceivedScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'ReceivedBrokerA' with 'ReceivedBrokerB' arising from a use of 'coerce'"
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
        "CoerceBrokerLinkScope.hs"
        ["Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'"]
    , rejectsWith
        "CoerceBrokerLinkBroker.hs"
        ["Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"]
    , rejectsWith
        "CrossScopeBrokerRelay.hs"
        ["Couldn't match type: Harness projectId runId with: Production projectId"]
    , rejectsWith
        "CrossScopeAuthenticatedConfig.hs"
        ["Couldn't match type: Harness projectId runId with: Production projectId"]
    , rejectsWith
        "ImportHandoffReceiverInternal.hs"
        ["Could not load module 'HostBootstrap.Handoff.Receiver.Internal'. it is a hidden module"]
    , rejectsWith
        "ReadReceivedEdgeTransport.hs"
        [ "Module 'HostBootstrap.Handoff.Receiver' does not export 'receivedEdgeChannel'."
        , "Module 'HostBootstrap.Handoff.Receiver' does not export 'receivedEdgeRequestId'."
        ]
    , rejectsWith
        "EscapeReceivedEdgeBrokerGeneration.hs"
        ["Couldn't match type 'receivedGeneration' with 'CallerChosenReceivedGeneration'"]
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
    , rejectsWith
        "RelaySignsWithoutBroker.hs"
        ["Couldn't match expected type: RootBroker"]
    , rejects "ForgeSessionPermit.hs"
    , rejectsWith
        "ClosingPermitAsOpen.hs"
        [ "Couldn't match expected type: ProjectPermit"
        , "with actual type: ClosingProjectPermit"
        ]
    , rejectsWith
        "ConstructTransactionInterrupted.hs"
        ["Illegal term-level use of the type constructor"]
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
    , rejects "ForgeTeardownForest.hs"
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
    (pathCode, pathOutput, pathError) <-
        withCurrentDirectory coreRoot $
            readProcessWithExitCode "cabal" ["path"] ""
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
