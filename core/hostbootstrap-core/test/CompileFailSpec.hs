module CompileFailSpec (tests) where

import Data.Char (isDigit, isSpace)
import Data.List (group, isInfixOf, isPrefixOf, isSuffixOf, sort, stripPrefix)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (listToMaybe)
import qualified Data.Set as Set
import HostBootstrap.DocValidator (findRepoRoot)
import qualified SourceGuard
import System.Directory (
    findExecutable,
    getCurrentDirectory,
    listDirectory,
    withCurrentDirectory,
 )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty (TestTree, testGroup, withResource)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    withResource resolveCompilerPaths (const (pure ())) $ \getPaths ->
        withResource (getPaths >>= resolvePublicCompiler) (const (pure ())) $ \getCompiler ->
            testGroup
                "public compile-fail boundaries"
                ( [ testGroup "diagnostic matcher" diagnosticMatcherCases
                  , testGroup "fixture inventory" fixtureInventoryCases
                  , operationAdvancePayloadControl getCompiler
                  , withResource (getPaths >>= resolveTestingCompiler) (const (pure ())) $ \getTestingCompiler ->
                        testGroup
                            "private transaction testing unit"
                            ( transactionDataVocabularyControl getTestingCompiler
                                : privateCompileFailCases (rejectsWithUsing getTestingCompiler)
                            )
                  ]
                    <> compileFailCases (rejectsWithUsing getCompiler)
                )

-- The testing unit exposes descriptive data while its transaction runner stays hidden.
privateCompileFailCases :: (FilePath -> NonEmpty String -> result) -> [result]
privateCompileFailCases rejectsWith =
    [ rejectsWith
        "ImportTransactionRunnerFromTestingUnit.hs"
        ("Could not load module 'HostBootstrap.Lifecycle.Transaction'. it is a hidden module in the package 'hostbootstrap-core-0.1.0.0:lifecycle-transaction-internal'" :| [])
    ]

{- | Every registered fixture, each with the diagnostic it expects.

There is one combinator and it takes an expectation, so a fixture cannot be
registered without stating why it is expected to fail. § HH's first rule —
"it must fail for the named reason" — is therefore held by the shape of this
list rather than asked of whoever adds to it.
-}
compileFailCases ::
    (FilePath -> NonEmpty String -> result) ->
    [result]
compileFailCases rejectsWith =
    [ rejectsWith
        "RawStep.hs"
        (("Illegal term-level use of the type constructor 'Step'") :| [])
    , rejectsWith
        "ForgeVMStack.hs"
        ("Illegal term-level use of the type constructor 'VMStack'" :| [])
    , rejectsWith
        "ForgeLiftContext.hs"
        ("Illegal term-level use of the type constructor 'LiftContext'" :| [])
    , rejectsWith
        "VMLayerAfterContainer.hs"
        ("Couldn't match expected type 'VMStack' with actual type 'LiftContext'" :| [])
    , rejectsWith
        "RecordUpdateLiftLayers.hs"
        ("Not in scope: record field 'liftLayers'" :| [])
    , rejectsWith
        "RepointGuestBootstrapTarget.hs"
        ("Not in scope: record field 'guestSourceRoot'" :| [])
    , rejectsWith
        "ForgeGuestBootstrapStep.hs"
        ("an item called 'GuestBootstrapStep' is exported, but it does not export any children (constructors, class methods or field names) called 'InstallGuestProjectBinary'" :| [])
    , rejectsWith
        "TransposeGuestBinaryRoles.hs"
        ( "Couldn't match expected type 'GuestBuiltBinary' with actual type 'GuestInstalledBinary'"
            :| ["Couldn't match expected type 'GuestInstalledBinary' with actual type 'GuestBuiltBinary'"]
        )
    , rejectsWith
        "ImportLifecycleDependencyInternal.hs"
        ("Could not load module 'HostBootstrap.Lifecycle.Dependency.Internal'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:lifecycle-dependency-internal'" :| [])
    , rejectsWith
        "ImportPlanResource.hs"
        ("Could not load module 'HostBootstrap.Plan.Resource'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:plan-resource-internal'" :| [])
    , rejectsWith
        "EscapeFreshRunningProviderDependency.hs"
        (("Couldn't match type 'providerId' with 'FixedProvider'") :| [])
    , rejectsWith
        "ForgeValidatedConfig.hs"
        (("Illegal term-level use of the type constructor 'ValidatedConfig'") :| [])
    , rejectsWith
        "ForgePlanDraft.hs"
        (("Illegal term-level use of the type constructor 'PlanDraft'") :| [])
    , -- The owned-object vocabulary the four ownership clauses are written in.
      -- An identity is what a kernel answered, a payload digest is computed
      -- from the bytes a run intends to install, and a record's identity
      -- binding is attached by its own producer — so none of the three has a
      -- term a caller can write, and the record has no field a caller can
      -- update.
      rejectsWith
        "ForgeObjectIdentity.hs"
        (("Illegal term-level use of the type constructor 'ObjectIdentity'") :| [])
    , rejectsWith
        "ForgeOwnershipPayloadDigest.hs"
        (("Illegal term-level use of the type constructor 'PayloadDigest'") :| [])
    , rejectsWith
        "ForgeOwnershipOriginRecord.hs"
        (("Illegal term-level use of the type constructor 'OriginRecord'") :| [])
    , rejectsWith
        "RebindOwnershipOriginRecord.hs"
        (("Not in scope: record field 'originRecordBinding'") :| [])
    , -- The four clause tokens. Each is minted by a clause actually being held,
      -- so none has a term a caller can write; both indices are nominal, so
      -- evidence cannot be moved between entries or between objects; and the
      -- entry index is the protected session's own rank-2 variable, so a token
      -- cannot be carried out of the entry that authorized it.
      rejectsWith
        "ForgeOwnershipEntered.hs"
        (("Illegal term-level use of the type constructor 'Entered'") :| [])
    , rejectsWith
        "ForgeOwnershipRecorded.hs"
        (("Illegal term-level use of the type constructor 'Recorded'") :| [])
    , rejectsWith
        "ForgeOwnershipBound.hs"
        (("Illegal term-level use of the type constructor 'Bound'") :| [])
    , rejectsWith
        "ForgeOwnershipReleasable.hs"
        (("Illegal term-level use of the type constructor 'Releasable'") :| [])
    , rejectsWith
        "CoerceOwnershipClauseSession.hs"
        (("Couldn't match type 'SessionA' with 'SessionB'") :| [])
    , rejectsWith
        "CoerceOwnershipClauseObject.hs"
        (("Couldn't match type 'ObjA' with 'ObjB'") :| [])
    , rejectsWith
        "EscapeOwnershipClauseEntry.hs"
        (("Couldn't match type 'session' with 'escaped'") :| [])
    , rejectsWith
        "ImportOwnershipInternal.hs"
        (("Could not load module 'HostBootstrap.Ownership.Internal'. it is a hidden module") :| [])
    , -- The seam that mints those tokens. The clause order is the producers'
      -- own types, so a mutation before the origin record and a release without
      -- the re-observation are terms that do not exist; and the handle a row
      -- mints is sealed inside it, so it can neither be carried out nor handed
      -- to another row.
      rejectsWith
        "MutateBeforeOwnershipRecord.hs"
        ("Couldn't match expected type: hostbootstrap-core-0.1.0.0:ownership-internal:HostBootstrap.Ownership.Internal.Recorded session0 object0 with actual type: Entered session object" :| [])
    , rejectsWith
        "ReleaseWithoutOwnershipBinding.hs"
        (("Couldn't match expected type: hostbootstrap-core-0.1.0.0:ownership-internal:HostBootstrap.Ownership.Internal.Releasable session0 object0 with actual type: Bound session object") :| [])
    , rejectsWith
        "EscapeOwnershipRowHandle.hs"
        (("Couldn't match type 'handle1' with 'handle'") :| [])
    , rejectsWith
        "CrossOwnershipRowHandle.hs"
        (("Couldn't match expected type 'handle1' with actual type 'handle'") :| [])
    , rejectsWith
        "EscapeReenteredOwnershipEntry.hs"
        (("Couldn't match type 'session' with 'escaped'") :| [])
    , rejectsWith
        "ForgeIndexedProjectPlan.hs"
        (("Illegal term-level use of the type constructor 'ProjectPlan'") :| [])
    , rejectsWith
        "CoercePlanDraftScope.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB'") :| [])
    , rejectsWith
        "CoercePlanDraftSpec.hs"
        (("Couldn't match type 'SpecA' with 'SpecB'") :| [])
    , rejectsWith
        "CoerceProjectPlanScope.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB'") :| [])
    , rejectsWith
        "CoerceProjectPlanSpec.hs"
        (("Couldn't match type 'SpecA' with 'SpecB'") :| [])
    , rejectsWith
        "CoerceProjectPlanIdentity.hs"
        (("Couldn't match type 'PlanA' with 'PlanB'") :| [])
    , rejectsWith
        "CoerceProjectPlanConfig.hs"
        (("Couldn't match type 'ConfigA' with 'ConfigB'") :| [])
    , rejectsWith
        "CoerceFinalizedProjectSpec.hs"
        (("Couldn't match type 'SpecA' with 'SpecB'") :| [])
    , rejectsWith
        "ImportProjectPlanConstructInternal.hs"
        (("Could not load module 'HostBootstrap.ProjectPlan.Construct.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "ImportProjectPlanHandoffInternal.hs"
        (("Could not load module 'HostBootstrap.ProjectPlan.Handoff.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "ImportProjectPlanProjectionInternal.hs"
        (("Could not load module 'HostBootstrap.ProjectPlan.Projection.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "ImportLifecycleRootedPlan.hs"
        (("Could not load module 'HostBootstrap.Lifecycle.RootedPlan'. it is a hidden module") :| [])
    , rejectsWith
        "ImportLifecycleFrameExecutor.hs"
        (("Could not load module 'HostBootstrap.Lifecycle.FrameExecutor'. it is a hidden module") :| [])
    , rejectsWith
        "ImportTeardownExecutorInternal.hs"
        (("Could not load module 'HostBootstrap.Teardown.Executor.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "ImportHandoffProcessRoute.hs"
        (("Could not load module 'HostBootstrap.Handoff.Process.Route'. it is a hidden module") :| [])
    , -- The lifecycle process owner is a platform row, and a row is built on
      -- every gate host and refuses where it cannot apply (§ JJ). It is
      -- therefore unreachable from a public importer for the same reason
      -- everywhere — the package builds it privately — and the fixture expects
      -- one diagnostic rather than one per host.
      rejectsWith
        "ImportHandoffProcess.hs"
        (("Could not load module 'HostBootstrap.Handoff.Process'. it is a hidden module") :| [])
    , rejectsWith
        "RenderLifecycleProcessRouteArgv.hs"
        (("Module 'HostBootstrap.Lift' does not export 'sanitizedLaunch'") :| ["Module 'HostBootstrap.Lift' does not export 'withLifecycleProcessRouteLaunchKernel'"])
    , rejectsWith
        "OpenFrameExecutorGate.hs"
        (("Module 'HostBootstrap.Lifecycle.Prepared' does not export 'mintPreparedGate'") :| ["Module 'HostBootstrap.Lifecycle.Prepared' does not export 'readPreparedGatePackageKernel'"
        , "Module 'HostBootstrap.Lifecycle.Prepared' does not export 'readPreparedGatePackagesKernel'"
        , "Module 'HostBootstrap.Lifecycle.Prepared' does not export 'renderPreparedNodeKeysKernel'"])
    , rejectsWith
        "OpenImmediateTargetProjection.hs"
        (("Module 'HostBootstrap.ProjectPlan' does not export 'withImmediateTargetKernel'") :| [])
    , rejectsWith
        "OpenRootedPlanCatalog.hs"
        (("Module 'HostBootstrap.Lifecycle.Session' does not export 'RootedPlanCatalog'") :| ["Module 'HostBootstrap.Lifecycle.Session' does not export 'rootedPlanCatalogManifestKernel'"
        , "Module 'HostBootstrap.Lifecycle.Session' does not export 'rootedPlanCatalogManifestMatchesKernel'"
        , "Module 'HostBootstrap.Lifecycle.Session' does not export 'rootedPlanCatalogRecordIdentityKernel'"
        , "Module 'HostBootstrap.Lifecycle.Session' does not export 'withRootedPlanCatalogEdgeKernel'"
        , "Module 'HostBootstrap.Lifecycle.Session' does not export 'withRootedPlanCatalogEntriesKernel'"
        , "Module 'HostBootstrap.Lifecycle.Session' does not export 'withRootedPlanCatalogEntryKernel'"
        , "Module 'HostBootstrap.Lifecycle.Session' does not export 'withRootedPlanCatalogFrameKernel'"
        , "Module 'HostBootstrap.Lifecycle.Session' does not export 'withRootedPlanCatalogKernel'"
        , "Module 'HostBootstrap.Lifecycle.Session' does not export 'withRootedPlanCatalogRootKernel'"])
    , rejectsWith
        "OpenPlannedForwardHandoff.hs"
        (("Module 'HostBootstrap.ProjectPlan' does not export 'PlannedForwardHandoff'") :| ["Module 'HostBootstrap.ProjectPlan' does not export 'withPlannedForwardHandoffKernel'"
        , "Module 'HostBootstrap.ProjectPlan' does not export 'withPlannedForwardProcessInputsKernel'"])
    , rejectsWith
        "OpenCatalogForwardHandoff.hs"
        (("Module 'HostBootstrap.ProjectPlan' does not export 'CatalogForwardHandoff'") :| ["Module 'HostBootstrap.ProjectPlan' does not export 'withCatalogForwardHandoffKernel'"
        , "Module 'HostBootstrap.ProjectPlan' does not export 'withCatalogForwardProcessInputsKernel'"])
    , rejectsWith
        "OpenFinalizedForwardChildProjector.hs"
        (("an item called 'FinalizedProjectSpec' is exported, but it does not export any children (constructors, class methods or field names) called 'FinalizedProjectSpec'") :| ["Module 'HostBootstrap.ProjectPlan.Construct' does not export 'withFinalizedForwardChildProjectionKernel'"])
    , rejectsWith
        "ForgeProviderResourceDeclaration.hs"
        (("an item called 'ProviderResourceDeclaration' is exported, but it does not export any children (constructors, class methods or field names) called 'ProviderResourceAtCurrentFrame'") :| [])
    , rejectsWith
        "ForgeChartWorkloadResource.hs"
        (("an item called 'ChartWorkloadResource' is exported, but it does not export any children (constructors, class methods or field names) called 'ChartWorkloadResource'") :| [])
    , rejectsWith
        "ForgePlanExecutionPackage.hs"
        (("Module 'HostBootstrap.Lifecycle.Execution' does not export 'PlanExecutionPackage'") :| ["Module 'HostBootstrap.Lifecycle.Execution' does not export 'mintPlanExecutionPackage'"])
    , rejectsWith
        "EscapeProjectPlanIdentity.hs"
        (("Couldn't match type 'planId' with 'ChosenPlan'") :| [])
    , rejectsWith
        "ForgeValidatedLifecycleContext.hs"
        (("Illegal term-level use of the type constructor 'ValidatedLifecycleContext'") :| [])
    , rejectsWith
        "CoerceValidatedLifecycleContextRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'SpecificationA' with 'SpecificationB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ConfigurationA' with 'ConfigurationB' arising from a use of 'coerce'"
        , "Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"])
    , rejectsWith
        "CrossValidatedLifecycleContextIndices.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB'") :| ["Couldn't match type 'SpecificationA' with 'SpecificationB'"
        , "Couldn't match type 'PlanA' with 'PlanB'"
        , "Couldn't match type 'ConfigurationA' with 'ConfigurationB'"
        , "Couldn't match type 'FrameA' with 'FrameB'"])
    , rejectsWith
        "EscapeValidatedLifecycleContextFrame.hs"
        (("Couldn't match type 'frame' with 'SelectedFrame'") :| [])
    , rejectsWith
        "OpenValidatedLifecycleContextAuthority.hs"
        ("Module 'HostBootstrap.Lifecycle.Context' does not export 'mintValidatedLifecycleContext'" :| ["Module 'HostBootstrap.Lifecycle.Context' does not export 'withValidatedRootLifecycleContext'"])
    , rejectsWith
        "ValidatedLifecycleContextAsAuthority.hs"
        (("Couldn't match expected type: AcquisitionJournal Scope Plan Broker") :| ["Couldn't match expected type: LifecycleCursor Scope Plan Frame Broker VerbUp ExecutePhase"
        , "Couldn't match expected type: CommandAuthority Scope Plan Frame Broker VerbUp ExecutePhase"])
    , rejectsWith
        "ImportLifecycleContextInternal.hs"
        (("Could not load module 'HostBootstrap.Lifecycle.Context.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "CoerceLifecycleEntryRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbUp' with 'VerbDown' arising from a use of 'coerce'"])
    , rejectsWith
        "CrossLifecycleEntryIndices.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB'") :| ["Couldn't match type 'PlanA' with 'PlanB'"
        , "Couldn't match type 'FrameA' with 'FrameB'"
        , "Couldn't match type 'BrokerA' with 'BrokerB'"
        , "Couldn't match type 'VerbUp' with 'VerbDown'"])
    , rejectsWith
        "ImportCommandLifecycleEntry.hs"
        (("Could not load module 'HostBootstrap.Command.LifecycleEntry'. it is a hidden module") :| [])
    , rejectsWith
        "OpenLifecycleEntryProducer.hs"
        ("Module 'HostBootstrap.Command' does not export 'runRootProjectUpLifecycleEntry'" :| ["Module 'HostBootstrap.Command' does not export 'runRootProjectReverseLifecycleEntry'", "Module 'HostBootstrap.Command' does not export 'settleRootedPlanCatalog'", "Module 'HostBootstrap.Command' does not export 'withBoundProjectDestroyLifecycleEntry'", "Module 'HostBootstrap.Command' does not export 'withRootProjectReverseLifecycleEntry'", "Module 'HostBootstrap.Command' does not export 'withRootProjectUpLifecycleEntry'"])
    , rejectsWith
        "OpenPreparedRootReverseDescentProducer.hs"
        (("Module 'HostBootstrap.Command' does not export 'withPreparedRootReverseDescentKernel'") :| [])
    , rejectsWith
        "OpenLifecycleEntryEvidence.hs"
        ("an item called 'LifecycleEntry' is exported, but it does not export any children (constructors, class methods or field names) called 'RootUpLifecycleEntry'" :| ["an item called 'LifecycleEntry' is exported, but it does not export any children (constructors, class methods or field names) called 'RootDownLifecycleEntry'", "an item called 'LifecycleEntry' is exported, but it does not export any children (constructors, class methods or field names) called 'RootDestroyLifecycleEntry'"])
    , rejectsWith
        "ValidatedLifecycleContextAsLifecycleEntry.hs"
        (("Couldn't match expected type: LifecycleEntry Scope Plan Frame Broker VerbUp") :| [])
    , rejectsWith
        "LifecycleEntryAsRawEvidence.hs"
        (("Couldn't match expected type: CommandAuthority Scope Plan Frame Broker VerbUp ExecutePhase") :| ["Couldn't match expected type: AcquisitionJournal Scope Plan Broker"
        , "Couldn't match expected type: LifecycleCursor Scope Plan Frame Broker VerbUp ExecutePhase"])
    , rejectsWith
        "RawReverseInputsAsLifecycleEntry.hs"
        ( "Couldn't match expected type: LifecycleEntry Scope Plan Frame Broker VerbDown with actual type: RootInvocationAuthority Scope Broker VerbDown"
            :| [ "Couldn't match expected type: LifecycleEntry Scope Plan Frame Broker VerbDown with actual type: AcquisitionJournal Scope SourcePlan SourceBroker"
               , "Couldn't match expected type: LifecycleEntry Scope Plan Frame Broker VerbDown with actual type: LifecycleCursor Scope SourcePlan SourceFrame SourceBroker VerbUp TeardownPhase"
               , "Couldn't match expected type: LifecycleEntry Scope Plan Frame Broker VerbDown with actual type: AcquisitionJournal Scope Plan Broker"
               , "Couldn't match expected type: LifecycleEntry Scope Plan Frame Broker VerbDown with actual type: LifecycleCursor Scope Plan Frame Broker VerbDown TeardownPhase"
               , "Couldn't match expected type: LifecycleEntry Scope Plan Frame Broker VerbDown with actual type: CommandAuthority Scope Plan Frame Broker VerbDown TeardownPhase"
               ]
        )
    , rejectsWith
        "RawFrameAuthorizeRootProject.hs"
        (("Couldn't match type: ProjectFrame scope spec plan config frame with: LifecycleCursor scope plan frame0 broker VerbUp phase0") :| [])
    , rejectsWith
        "OpenCommandReservation.hs"
        ("Module 'HostBootstrap.Authority' does not export 'CommandReservation'" :| ["Module 'HostBootstrap.Authority' does not export 'commandReservationKernel'", "Module 'HostBootstrap.Authority' does not export 'reserveCommandInvocationKernel'"])
    , rejectsWith
        "ForgePlannedStep.hs"
        (("Illegal term-level use of the type constructor 'PlannedStep'") :| [])
    , rejectsWith
        "ForgeDerivedTopology.hs"
        (("Illegal term-level use of the type constructor 'DerivedTopology'") :| [])
    , rejectsWith
        "ForgeStablePlanSnapshot.hs"
        (("Illegal term-level use of the type constructor 'StablePlanSnapshot'") :| [])
    , rejectsWith
        "CoercePlannedStepPlan.hs"
        (("Couldn't match type 'PlanA' with 'PlanB'") :| [])
    , rejectsWith
        "CoercePlannedStepConfig.hs"
        (("Couldn't match type 'ConfigA' with 'ConfigB'") :| [])
    , rejectsWith
        "CoercePlannedStepObservationRoles.hs"
        (("Couldn't match type 'ObservationScopeA' with 'ObservationScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'ObservationPlanA' with 'ObservationPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ObservationConfigA' with 'ObservationConfigB' arising from a use of 'coerce'"])
    , rejectsWith
        "ForgePlanResourceProjection.hs"
        (("Illegal term-level use of the type constructor 'PlannedResource'") :| ["Illegal term-level use of the type constructor 'PlannedEdge'"])
    , rejectsWith
        "CoercePlannedResourceRoles.hs"
        (("Couldn't match type 'ResourceScopeA' with 'ResourceScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'ResourcePlanA' with 'ResourcePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ResourceIdentityA' with 'ResourceIdentityB' arising from a use of 'coerce'"
        , "Couldn't match type 'ResourceKindA' with 'ResourceKindB' arising from a use of 'coerce'"
        , "Couldn't match type 'ResourceFrameA' with 'ResourceFrameB' arising from a use of 'coerce'"])
    , rejectsWith
        "CoercePlannedEdgeRoles.hs"
        (("Couldn't match type 'EdgeScopeA' with 'EdgeScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'EdgePlanA' with 'EdgePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'TargetIdentityA' with 'TargetIdentityB' arising from a use of 'coerce'"
        , "Couldn't match type 'TargetKindA' with 'TargetKindB' arising from a use of 'coerce'"
        , "Couldn't match type 'TargetFrameA' with 'TargetFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'DependencyIdentityA' with 'DependencyIdentityB' arising from a use of 'coerce'"
        , "Couldn't match type 'DependencyKindA' with 'DependencyKindB' arising from a use of 'coerce'"
        , "Couldn't match type 'DependencyFrameA' with 'DependencyFrameB' arising from a use of 'coerce'"])
    , rejectsWith
        "CrossPlanFramePlannedProjection.hs"
        (("Couldn't match type 'ForeignProjectionPlan' with 'ProjectionPlan'") :| ["Couldn't match type 'ForeignTargetFrame' with 'TargetFrame'"
        , "Couldn't match type 'ForeignDependencyFrame' with 'DependencyFrame'"])
    , rejectsWith
        "EscapePlannedResourceIndices.hs"
        (("Couldn't match type 'resourceId' with 'ChosenResourceIdentity'") :| ["Couldn't match type 'frame' with 'ChosenResourceFrame'"])
    , rejectsWith
        "LifecyclePlanAsResourceProjectionSource.hs"
        (("Couldn't match expected type: ProjectPlan ProjectionScope SpecificationDigest PlanIdentity ConfigurationIdentity Configuration with actual type: LifecyclePlan ProjectionScope PlanIdentity") :| [])
    , rejectsWith
        "CrossPlanConfigStepExecution.hs"
        (("Couldn't match type 'PlanB' with 'PlanA'") :| ["Couldn't match type 'ConfigurationB' with 'ConfigurationA'"])
    , rejectsWith
        "CompatibilityInputsAsStepExecutionSource.hs"
        (("Couldn't match expected type: ProjectPlan Scope specDigest0 Plan ConfigurationIdentity Configuration with actual type: LifecyclePlan Scope Plan") :| ["Couldn't match expected type 'PlannedStep Scope Plan ConfigurationIdentity (Configuration Scope)' with actual type 'Step'"])
    , rejectsWith
        "CrossAuthorityChain.hs"
        (("Couldn't match type 'ForeignScope' with 'Scope'") :| ["Couldn't match type 'AuthorityPlan' with 'Plan'"
        , "Couldn't match type 'Frame' with 'AuthorityFrame'"
        , "Couldn't match type 'Broker' with 'AuthorityBroker'"
        , "Couldn't match type 'VerbDown' with 'VerbUp'"
        , "Couldn't match type 'PreparePhase' with 'ExecutePhase'"])
    , rejectsWith
        "CrossCursorChain.hs"
        (("Couldn't match type 'ForeignScope' with 'Scope'") :| ["Couldn't match type 'CursorPlan' with 'Plan'"
        , "Couldn't match type 'CursorFrame' with 'Frame'"
        , "Couldn't match type 'CursorBroker' with 'Broker'"
        , "Couldn't match type 'VerbDown' with 'VerbUp'"
        , "Couldn't match type 'PreparePhase' with 'ExecutePhase'"])
    , rejectsWith
        "CrossPlanCurrentFrameTeardown.hs"
        (("Couldn't match type 'PlanB' with 'PlanA'") :| [])
    , rejectsWith
        "CrossFrameTeardownPlan.hs"
        (("Couldn't match type 'FrameA' with 'FrameB'") :| [])
    , rejectsWith
        "CoerceTeardownPlanFrame.hs"
        (("Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceProjectVerb.hs"
        (("Couldn't match type 'VerbDown' with 'VerbDestroy' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CrossVerbTeardownWork.hs"
        (("Couldn't match type 'VerbDestroy' with 'VerbDown'") :| [])
    , rejectsWith
        "ProjectUpCannotVerifyDestroy.hs"
        (("Couldn't match type 'hostbootstrap-core-0.1.0.0:authority-internal:HostBootstrap.Authority.Kernel.VerbDestroy' with 'VerbUp'") :| [])
    , rejectsWith
        "DownCannotVerifyDestroy.hs"
        (("Couldn't match type 'hostbootstrap-core-0.1.0.0:authority-internal:HostBootstrap.Authority.Kernel.VerbDestroy' with 'VerbDown'") :| [])
    , rejectsWith
        "ForgeSubtreeSettlement.hs"
        (("Illegal term-level use of the type constructor 'SubtreeSettled'") :| ["Illegal term-level use of the type constructor 'DestroySettled'"])
    , rejectsWith
        "CoerceSubtreeSettlementRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbA' with 'VerbB' arising from a use of 'coerce'"
        , "Couldn't match type 'DestroyScopeA' with 'DestroyScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'DestroyPlanA' with 'DestroyPlanB' arising from a use of 'coerce'"])
    , rejectsWith
        "CrossSubtreeDescentSettlement.hs"
        ( "Couldn't match type 'PlanA' with 'PlanB'"
            :| [ "Couldn't match type 'ParentA' with 'ParentB'"
               , "Couldn't match type 'ChildA' with 'ChildB'"
               , "Couldn't match type 'ChildA' with 'ParentA'"
               , "Couldn't match type 'VerbDestroy' with 'VerbDown'"
               , "Couldn't match expected type 'SubtreeSettled Scope PlanA ChildA VerbDestroy' with actual type 'TeardownOutcome'"
               ]
        )
    , rejectsWith
        "CallerSelectedDescentSubtree.hs"
        ("Couldn't match expected type: TeardownPlan Scope Plan Child VerbDestroy -> (TeardownPlan Scope Plan Child VerbDestroy -> result) -> result with actual type: CurrentFrame Scope Plan Child" :| ["Couldn't match type: [Char] with: TeardownPlan Scope Plan Child VerbDestroy -> String"])
    , rejectsWith
        "SubtreeAsDestroySettled.hs"
        ("Couldn't match expected type: DestroySettled Scope Plan with actual type: SubtreeSettled Scope Plan NestedFrame VerbDestroy" :| [])
    , rejectsWith
        "SubtreeAsDestroyClosure.hs"
        ("Couldn't match expected type: HostBootstrap.Teardown.DestroySettled Scope Plan with actual type: SubtreeSettled Scope Plan Frame VerbDestroy" :| [])
    , rejectsWith
        "FramedDestroySettled.hs"
        (("Expected kind '* -> *', but 'DestroySettled Scope Plan' has kind '*'") :| [])
    , rejectsWith
        "LegacyRootDestroyVerifier.hs"
        ("Couldn't match type: hostbootstrap-core-0.1.0.0:HostBootstrap.Lifecycle.Plan.ProjectPlan scope0 specDigest0 planId0 configId0 cfg0 with: TeardownPlan Scope Plan Frame VerbDestroy" :| [])
    , rejectsWith
        "CallerTextAsProjectVerb.hs"
        ("Couldn't match type: [Char] with: hostbootstrap-core-0.1.0.0:authority-internal:HostBootstrap.Authority.Kernel.ProjectVerb Verb" :| [])
    , rejectsWith
        "CrossFrameTeardownPipeline.hs"
        (("Couldn't match type 'OpenFrameA' with 'OpenFrameB'") :| ["Couldn't match type 'SuccessorFrameA' with 'SuccessorFrameB'"
        , "Couldn't match type 'WorkFrameB' with 'WorkFrameA'"
        , "Couldn't match type 'SettlementFrameB' with 'SettlementFrameA'"])
    , rejectsWith
        "CoerceTeardownFrameRoles.hs"
        (("Couldn't match type 'ForestFrameA' with 'ForestFrameB' arising from a use of 'coerce'") :| ["Couldn't match type 'ProgressFrameA' with 'ProgressFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'CompletedFrameA' with 'CompletedFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'AuthorizationFrameA' with 'AuthorizationFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreDescentFrameA' with 'PreDescentFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'ChildrenFrameA' with 'ChildrenFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'WorkFrameA' with 'WorkFrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'SettledFrameA' with 'SettledFrameB' arising from a use of 'coerce'"])
    , rejectsWith
        "ForgeTeardownWork.hs"
        (("Illegal term-level use of the type constructor 'LocalWork'") :| ["Illegal term-level use of the type constructor 'DescentWork'"
        , "Data constructor not in scope: LocalTeardownWork"
        , "Data constructor not in scope: DescentTeardownWork"])
    , rejectsWith
        "LocalWorkAsDescentWork.hs"
        ("Couldn't match type: DescentWork Scope Plan Frame ChildFrame VerbDestroy with: LocalWork Scope Plan Frame VerbDestroy" :| [])
    , rejectsWith
        "DescentWorkAsLocalRunner.hs"
        ("Couldn't match type: LocalWork Scope Plan Frame VerbDestroy with: DescentWork Scope Plan Frame ChildFrame VerbDestroy" :| [])
    , rejectsWith
        "CrossFrameLocalWork.hs"
        (("Couldn't match type 'FrameB' with 'FrameA'") :| [])
    , rejectsWith
        "CrossFrameDescentWork.hs"
        (("Couldn't match type 'ParentB' with 'ParentA'") :| ["Couldn't match type 'ChildB' with 'ChildA'"])
    , rejectsWith
        "EscapeDescentChildFrame.hs"
        (("Couldn't match type 'childFrame' with 'ChosenChild'") :| [])
    , rejectsWith
        "OpenTeardownWorkAgainstForeignForest.hs"
        (("The function 'attemptLocalWork' is applied to three visible arguments, but its type 'LocalWork scope planId frame verb -> TeardownOutcome -> TeardownForest scope planId frame verb' has only two") :| [])
    , rejectsWith
        "ImportFormerTeardownCursor.hs"
        ("Module 'HostBootstrap.Teardown' does not export 'TeardownCursor'" :| [])
    , rejectsWith
        "ImportDirectTeardownAdvance.hs"
        ("Module 'HostBootstrap.Teardown' does not export 'authorizationPointKey'" :| [])
    , rejectsWith
        "GenericPointTeardownDriver.hs"
        ("Couldn't match type: TeardownAuthorizationPoint Scope Plan Frame VerbDestroy with: PreDescentStep Scope Plan Frame VerbDestroy" :| [])
    , rejectsWith
        "CoerceTeardownWorkRoles.hs"
        (("Couldn't match type 'WorkScopeA' with 'WorkScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'WorkPlanA' with 'WorkPlanB' arising from a use of 'coerce'"
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
        , "Couldn't match type 'DescentVerbA' with 'DescentVerbB' arising from a use of 'coerce'"])
    , rejectsWith
        "ImportTeardownInternal.hs"
        (("Could not load module 'HostBootstrap.Teardown.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "OpenReverseDescentSubstrate.hs"
        (("Module 'HostBootstrap.Teardown' does not export 'BoundReverseDescent'") :| ["Module 'HostBootstrap.Teardown' does not export 'PreparedReverseDescent'"
        , "Module 'HostBootstrap.Teardown' does not export 'ReverseDescent'"
        , "Module 'HostBootstrap.Teardown' does not export 'withBoundReverseDescentKernel'"
        , "Module 'HostBootstrap.Teardown' does not export 'withPreparedReverseDescentKernel'"
        , "Module 'HostBootstrap.Teardown' does not export 'withRehydratedBoundReverseDescentKernel'"
        , "Module 'HostBootstrap.Teardown' does not export 'withReverseDescentLiftContextKernel'"
        , "Module 'HostBootstrap.Teardown' does not export 'withVerifiedBoundReverseDescentObservationsKernel'"
        , "Module 'HostBootstrap.Teardown' does not export 'withVerifiedBoundReverseDescentReportKernel'"
        , "Module 'HostBootstrap.Teardown' does not export 'withVerifiedReverseAdapterKernel'"])
    , rejectsWith
        "LifecyclePlanAsTeardownPlanSource.hs"
        (("Couldn't match expected type: ProjectPlan"
            ++ " Scope SpecificationDigest Plan ConfigurationIdentity Configuration"
            ++ " with actual type: LifecyclePlan Scope Plan") :| [])
    , rejectsWith
        "OpenTeardownForestWithLifecyclePlan.hs"
        (("Couldn't match type: TeardownPlan scope0 planId0 frame0 verb0 with: LifecyclePlan Scope Plan") :| [])
    , rejectsWith
        "OpenTeardownForestWithCurrentFrame.hs"
        (("Couldn't match type: TeardownPlan scope0 planId0 frame0 verb0 with: CurrentFrame Scope Plan Frame") :| [])
    , rejectsWith
        "DuplicateCurrentFrameTeardown.hs"
        (("Couldn't match expected type: CurrentFrame Scope Plan Frame"
            ++ " -> TeardownPlan Scope Plan Frame VerbDown") :| [])
    , rejectsWith
        "CallerFrameNameTeardown.hs"
        ("Couldn't match type: [Char] with: HostBootstrap.ProjectPlan.Frame.CurrentFrame Scope Plan Frame" :| [])
    , rejectsWith
        "ForgeTeardownPlan.hs"
        (("Illegal term-level use of the type constructor 'TeardownPlan'") :| [])
    , rejectsWith
        "ForgeInitialTeardownForest.hs"
        (("Illegal term-level use of the type constructor 'TeardownForest'") :| [])
    , rejectsWith
        "OpenReconcilePlanProjectionProducers.hs"
        (("Module 'HostBootstrap.Reconcile' does not export 'withPlannedEdge'") :| ["Module 'HostBootstrap.Reconcile' does not export 'withPlannedResourceOfKind'"
        , "Module 'HostBootstrap.Reconcile' does not export 'withProviderGuestAliasProjection'"])
    , rejectsWith
        "CoerceDerivedTopologyPlan.hs"
        (("Couldn't match type 'PlanA' with 'PlanB'") :| [])
    , rejectsWith
        "ForgeCurrentFrame.hs"
        (("Illegal term-level use of the type constructor 'CurrentFrame'") :| [])
    , rejectsWith
        "CoerceCurrentFramePlan.hs"
        (("Couldn't match type 'PlanA' with 'PlanB'") :| [])
    , rejectsWith
        "CoerceCurrentFrameIdentity.hs"
        (("Couldn't match type 'FrameA' with 'FrameB'") :| [])
    , rejectsWith
        "CoerceProjectFrameConfig.hs"
        (("Couldn't match type 'ConfigA' with 'ConfigB'") :| [])
    , rejectsWith
        "ForgePlanDigestBinding.hs"
        (("Illegal term-level use of the type constructor 'PlanDigestBinding'") :| [])
    , rejectsWith
        "CoercePlanDigestBindingDigest.hs"
        (("Couldn't match type 'DigestA' with 'DigestB'") :| [])
    , rejectsWith
        "CoercePlanDigestBindingPlan.hs"
        (("Couldn't match type 'PlanA' with 'PlanB'") :| [])
    , rejectsWith
        "ForgeBoundPlanSnapshot.hs"
        (("Illegal term-level use of the type constructor 'BoundPlanSnapshot'") :| [])
    , rejectsWith
        "CoerceBoundPlanSnapshotScope.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB'") :| [])
    , rejectsWith
        "CoerceBoundPlanSnapshotSpec.hs"
        (("Couldn't match type 'SpecA' with 'SpecB'") :| [])
    , rejectsWith
        "CoerceBoundPlanSnapshotDigest.hs"
        (("Couldn't match type 'DigestA' with 'DigestB'") :| [])
    , rejectsWith
        "CoerceBoundPlanSnapshotPlan.hs"
        (("Couldn't match type 'PlanA' with 'PlanB'") :| [])
    , rejectsWith
        "CoerceNormalActiveRecoveryScope.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceNormalActiveRecoverySpec.hs"
        (("Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceNormalActiveRecoveryPlan.hs"
        (("Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceNormalActiveRecoveryDigest.hs"
        (("Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceNormalActiveRecoveryBroker.hs"
        (("Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "ForgeBoundInvocationRecovery.hs"
        (("Illegal term-level use of the type constructor 'BoundInvocationRecovery'") :| [])
    , rejectsWith
        "CoerceBoundInvocationRecoveryScope.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceBoundInvocationRecoverySpec.hs"
        (("Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceBoundInvocationRecoveryDigest.hs"
        (("Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceBoundInvocationRecoveryPlan.hs"
        (("Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceBoundInvocationRecoveryBroker.hs"
        (("Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "OpenBoundSnapshotAdmissionToken.hs"
        (("Module 'HostBootstrap.Lifecycle.Mode' does not export 'existingBoundSnapshotAdmissionKernel'") :| [])
    , rejectsWith
        "OpenObservedBoundInvocationRecovery.hs"
        (("Module 'HostBootstrap.Lifecycle.Mode' does not export 'ObservedBoundInvocationRecovery'") :| [])
    , rejectsWith
        "OpenReverseRootIntent.hs"
        (("Module 'HostBootstrap.Lifecycle.Mode' does not export 'ReverseRootIntent'") :| [])
    , rejectsWith
        "PassRawAdmissionToResumedReverseRoot.hs"
        ("Couldn't match expected type 'hostbootstrap-core-0.1.0.0:HostBootstrap.Lifecycle.Plan.ExistingBoundSnapshotAdmission' with actual type '()'" :| [])
    , rejectsWith
        "PassRawAdmissionToFreshReverseRoot.hs"
        ("Couldn't match expected type 'hostbootstrap-core-0.1.0.0:HostBootstrap.Lifecycle.Plan.ExistingBoundSnapshotAdmission' with actual type '()'" :| [])
    , rejectsWith
        "PassRawAdmissionToReauthorizedBoundSnapshot.hs"
        ("Couldn't match expected type 'hostbootstrap-core-0.1.0.0:HostBootstrap.Lifecycle.Plan.ExistingBoundSnapshotAdmission' with actual type '()'" :| [])
    , rejectsWith
        "PassFreshEvidenceToBoundSnapshot.hs"
        ("The function 'withBoundPlanSnapshot' is applied to five visible arguments, but its type" :| ["The function 'withBoundPlanSnapshot' is applied to five visible arguments, but its type"])
    , rejectsWith
        "TerminalReceivesBoundPlanSnapshot.hs"
        (("Couldn't match expected type: IO () with actual type: BoundPlanSnapshot") :| [])
    , rejectsWith
        "EscapeBoundSnapshotPlanIdentity.hs"
        (("Couldn't match type 'planId' with 'ChosenPlan'") :| [])
    , rejectsWith
        "ForgeRecoveredProductionLifecycleProfile.hs"
        (("Illegal term-level use of the type constructor 'RecoveredProductionLifecycleProfile'") :| [])
    , rejectsWith
        "CoerceRecoveredProductionProfileProject.hs"
        (("Couldn't match type 'ProjectA' with 'ProjectB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceRecoveredProductionProfileSpec.hs"
        (("Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceRecoveredProductionProfileDigest.hs"
        (("Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceRecoveredProductionProfilePlan.hs"
        (("Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceRecoveredProductionProfileBroker.hs"
        (("Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "HarnessRecoveryAsRecoveredProductionProfile.hs"
        (("Couldn't match type: Harness Project Run with: Production Project") :| [])
    , rejectsWith
        "TeardownRecoveryAsRecoveredProductionProfile.hs"
        (("Couldn't match type 'VerbDestroy' with 'VerbUp'") :| [])
    , rejectsWith
        "QuantifyRecoveredProductionPlanIdentity.hs"
        (("Couldn't match type: forall freshPlanId. RecoveredProductionLifecycleProfile"
            ++ " projectId specDigest planDigest freshPlanId brokerGeneration with:"
            ++ " RecoveredProductionLifecycleProfile projectId specDigest planDigest planId"
            ++ " brokerGeneration") :| [])
    , rejectsWith
        "CrossIndexedRecoveredProductionProfile.hs"
        (("Couldn't match type 'SpecB' with 'SpecA'") :| [])
    , rejectsWith
        "CrossPlanDigestRecoveredProductionProfile.hs"
        (("Couldn't match type 'DigestB' with 'DigestA'") :| [])
    , rejectsWith
        "CrossPlanIdRecoveredProductionProfile.hs"
        (("Couldn't match type 'PlanB' with 'PlanA'") :| [])
    , rejectsWith
        "CrossBrokerRecoveredProductionProfile.hs"
        (("Couldn't match type 'BrokerB' with 'BrokerA'") :| [])
    , rejectsWith
        "HarnessRootAsRecoveredProjectPlan.hs"
        (("Couldn't match type: Harness Project Run with: Production Project") :| [])
    , rejectsWith
        "QuantifyRecoveredProjectPlanIdentity.hs"
        (("Couldn't match type: forall freshPlanId. ProjectPlan"
            ++ " (Production projectId) specDigest freshPlanId configId cfg with:"
            ++ " ProjectPlan (Production projectId) specDigest planId configId cfg") :| [])
    , rejectsWith
        "ReselectReturnedRecoveredProjectPlan.hs"
        (("Couldn't match type 'planId' with 'ChosenPlan'") :| [])
    , rejectsWith
        "CrossProfileSpecRecoveredProjectPlan.hs"
        (("Couldn't match type 'SpecA' with 'SpecB'") :| [])
    , rejectsWith
        "CrossProfileDigestRecoveredProjectPlan.hs"
        (("Couldn't match type 'DigestA' with 'DigestB'") :| [])
    , rejectsWith
        "CrossProfilePlanIdRecoveredProjectPlan.hs"
        (("Couldn't match type 'PlanA' with 'PlanB'") :| [])
    , rejectsWith
        "CrossBoundSnapshotRecoveredProjectPlan.hs"
        (("Couldn't match type 'PlanB' with 'PlanA'") :| [])
    , rejectsWith
        "CrossBindingRecoveredProjectPlan.hs"
        (("Couldn't match type 'DigestB' with 'DigestA'") :| [])
    , rejectsWith
        "CrossConfigSpecRecoveredProjectPlan.hs"
        (("Couldn't match type 'CandidateSpecB' with 'CandidateSpecA'") :| [])
    , rejectsWith
        "CrossRecoveredConfigSpecRecoveredProjectPlan.hs"
        (("Couldn't match type 'SpecB' with 'SpecA'") :| [])
    , rejectsWith
        "HarnessDraftsAsRecoveredProjectPlan.hs"
        (("Couldn't match type: Harness Project Run with: Production Project") :| [])
    , rejectsWith
        "HarnessCandidateAsRecoveredProjectPlanInputs.hs"
        (("Couldn't match type: Harness Project Run with: Production Project") :| [])
    , rejectsWith
        "ImportConfigSchemaInternal.hs"
        (("Could not load module 'HostBootstrap.Config.Schema.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "ImportConfigClassInternal.hs"
        (("Could not load module 'HostBootstrap.Config.Class.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "ImportServiceInternal.hs"
        (("Could not load module 'HostBootstrap.Service.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "OpenProjectCodecReindex.hs"
        (("an item called 'ProjectCodec' is exported, but it does not export any children (constructors, class methods or field names) called 'ProjectCodec'") :| ["Module 'HostBootstrap.Config.Class' does not export 'installedCodecSpecDigest'"
        , "Module 'HostBootstrap.Config.Class' does not export 'reindexProjectCodecKernel'"])
    , rejectsWith
        "OpenFinalizedServiceRegistryReindex.hs"
        (("Module 'HostBootstrap.Service' does not export 'FinalizedServiceDefinition'") :| ["an item called 'FinalizedServiceRegistry' is exported, but it does not export any children (constructors, class methods or field names) called 'FinalizedServiceRegistry'"
        , "Module 'HostBootstrap.Service' does not export 'reindexFinalizedServiceRegistryKernel'"])
    , rejectsWith
        "CoerceProjectCodecSpec.hs"
        (("Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceFinalizedServiceRegistrySpec.hs"
        (("Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "RawProjectSpec.hs"
        (("Illegal term-level use of the type constructor 'ProjectSpec'") :| [])
    , rejectsWith
        "EmptyValidatedStepPlan.hs"
        (("Couldn't match type: NonEmpty Step with: [Step] Expected: StepPlan -> [Step] Actual: StepPlan -> NonEmpty Step") :| [])
    , rejectsWith
        "RepointSelfReference.hs"
        ("an item called 'SelfRef' is exported, but it does not export any children (constructors, class methods or field names) called 'SelfRef'" :| [])
    , rejectsWith
        "ForgeProjectStepIdentity.hs"
        (("Illegal term-level use of the type constructor 'ProjectStepId'") :| [])
    , rejectsWith
        "ReplaceProjectContribution.hs"
        ("Module 'HostBootstrap.CLI' does not export 'pbStepFragments'" :| ["Module 'HostBootstrap.CLI' does not export 'pbServiceRegistries'", "Module 'HostBootstrap.CLI' does not export 'pbForwardChildPlan'"])
    , rejectsWith
        "DispatchUnfinishedBuilder.hs"
        (("Couldn't match type: ProjectSpec cfg0 tcfg0 with: ProjectSpecBuilder cfg tcfg") :| [])
    , rejectsWith
        "CrossFinalizationCodec.hs"
        (("Couldn't match type 'rightDigest' with 'leftDigest' Expected: ProjectCodec scope leftDigest cfg Actual: ProjectCodec scope rightDigest cfg") :| [])
    , rejectsWith
        "ForgeRoleParams.hs"
        (("Illegal term-level use of the type constructor 'RoleParams'") :| [])
    , rejectsWith
        "RawReadiness.hs"
        ("Illegal term-level use of the type constructor 'PollPolicy'" :| ["Illegal term-level use of the type constructor 'Micros'", "Illegal term-level use of the type constructor 'Ready'"])
      , rejectsWith
          "RawProbe.hs"
          ("Illegal term-level use of the type constructor 'Probe'" :| [])
      , rejectsWith
          "EscapeProbe.hs"
          ("Couldn't match type 'probeId' with 'EscapedProbe' arising from a use of 'coerce'" :| [])
      , rejectsWith
          "DockerProbeForCluster.hs"
          ("Couldn't match type 'DockerResource' with 'ClusterResource'" :| [])
      , rejectsWith
          "CallerMintedBackendProbe.hs"
          ("Variable not in scope: withBackendProbe" :| [])
      , rejectsWith
          "ImportReadinessKernel.hs"
          ("Could not load module 'HostBootstrap.Readiness.Kernel'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:readiness-internal'" :| [])
      , rejectsWith
          "CoerceReadyPlan.hs"
          ("Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'" :| [])
      , rejectsWith
          "CoerceProbePlan.hs"
          ("Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "RawBudget.hs"
        (("Illegal term-level use of the type constructor 'ResourceBudget'") :| [])
      , rejectsWith
          "RecordUpdateBudget.hs"
          ("Not in scope: record field 'budgetCpu'" :| [])
      , rejectsWith
          "UpdateConfigArtifactSchema.hs"
          ("Not in scope: record field 'schemaText'" :| [])
      , rejectsWith
          "MemorySourceAsCpu.hs"
          ("Couldn't match expected type 'CpuSource' with actual type 'MemorySource'" :| [])
      , rejectsWith
          "ImportWindowsCapacity.hs"
          ("Could not load module 'HostBootstrap.Cluster.Cordon.WindowsCapacity'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:capacity-internal'" :| [])
    , rejectsWith
        "CrossPlanBudgetWorkload.hs"
        (("Couldn't match type 'PlanB' with 'PlanA'") :| [])
    , rejectsWith
        "CrossPlanBudgetSlice.hs"
        (("Couldn't match type 'PlanB' with 'PlanA'") :| [])
    , rejectsWith
        "CrossPlanBudgetProviderCapability.hs"
        (("Couldn't match type 'PlanB' with 'PlanA'") :| [])
    , rejectsWith
        "CallerFenceProviderWallReservation.hs"
        ("Couldn't match expected type: hostbootstrap-core-0.1.0.0:HostBootstrap.Lifecycle.Plan.ProjectPlan scope0 specDigest0 planId0 configId0 cfg0 with actual type: ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId" :| [])
    , rejectsWith
        "CrossPartitionProviderWallReservation.hs"
        (("Couldn't match type 'partitionA' with 'partitionB'") :| [])
    , rejectsWith
        "ImportBudgetInternal.hs"
        (("Could not load module 'HostBootstrap.Cluster.Budget.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "ImportColimaSettlementInternal.hs"
        (("Could not load module 'HostBootstrap.Ensure.Colima.Settlement.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "ImportColimaBackendRunner.hs"
        (("Could not load module 'HostBootstrap.Ensure.Colima.Backend.Runner'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:colima-backend-internal'") :| [])
    , rejectsWith
        "ImportColimaResolverOverride.hs"
        (("Could not load module 'HostBootstrap.Ensure.Colima.Backend.Resolver.Override'. it is a hidden module in the package 'hostbootstrap-core-0.1.0.0:colima-backend-internal'") :| [])
    , rejectsWith
        "ImportColimaResolverTesting.hs"
        (("Could not load module 'HostBootstrap.Ensure.Colima.Backend.Resolver.Testing'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:colima-backend-internal'") :| [])
    , rejectsWith
        "ImportColimaResolverInstall.hs"
        (("Could not load module 'HostBootstrap.Ensure.Colima.Backend.Resolver.Install'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:colima-backend-internal'") :| [])
    , rejectsWith
        "ImportProviderStartInternal.hs"
        (("Could not load module 'HostBootstrap.Reconcile.ProviderStart.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "ForgePreparedProviderStart.hs"
        (("Illegal term-level use of the type constructor 'PreparedProviderStart'") :| [])
    , rejectsWith
        "ForgePreparedChartWorkload.hs"
        (("Illegal term-level use of the type constructor 'PreparedChartWorkload'") :| [])
    , rejectsWith
        "CoercePreparedProviderStartRoles.hs"
        (("Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'") :| ["Couldn't match type 'CallDigestA' with 'CallDigestB' arising from a use of 'coerce'"])
    , rejectsWith
        "ForgeProviderWallSettlementPermit.hs"
        (("Illegal term-level use of the type constructor 'ProviderWallSettlementPermit'") :| [])
    , rejectsWith
        "RawObservationProviderWallSettlement.hs"
        (("Couldn't match expected type 'ProviderWallSettlementPermit") :| [])
    , rejectsWith
        "CoerceProviderWallSettlementPermitRoles.hs"
        (("Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'") :| ["Couldn't match type 'OperationA' with 'OperationB' arising from a use of 'coerce'"])
    , rejectsWith
        "CrossPlanColimaConsumer.hs"
        (("Couldn't match type 'ForeignProviderPlan' with 'ColimaPlan'") :| ["Couldn't match type 'ForeignTopologyPlan' with 'ColimaPlan'"
        , "Couldn't match type 'ForeignPartitionPlan' with 'ColimaPlan'"
        , "Couldn't match type 'ForeignReservationPlan' with 'ColimaPlan'"])
    , rejectsWith
        "ForgeColimaAuthorities.hs"
        (("Illegal term-level use of the type constructor 'PreparedColimaWallCall'") :| ["Illegal term-level use of the type constructor 'LiveColimaWall'"
        , "Illegal term-level use of the type constructor 'ColimaCleanupAuthority'"
        , "Illegal term-level use of the type constructor 'PreparedColimaCleanupCall'"
        , "Data constructor not in scope: ColimaOwnedWallObservation"])
    , rejectsWith
        "CoerceColimaAuthorityRoles.hs"
        (("Couldn't match type 'PreparedScopeA' with 'PreparedScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'PreparedSpecificationDigestA' with 'PreparedSpecificationDigestB' arising from a use of 'coerce'"
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
        , "Couldn't match type 'PreparedCleanupFenceA' with 'PreparedCleanupFenceB' arising from a use of 'coerce'"])
    , rejectsWith
        "ColimaAcquireCallAsCleanupGate.hs"
        (("Couldn't match expected type 'PreparedGate' with actual type 'PreparedColimaWallCall") :| [])
    , rejectsWith
        "WrongColimaCleanupPhase.hs"
        (("Couldn't match type 'HostBootstrap.Reconcile.Destroyed' with 'Running'") :| [])
    , rejectsWith
        "OpenColimaOwnershipBackend.hs"
        (("Module 'HostBootstrap.Ensure.Colima' does not export 'ColimaOwnershipBackend'") :| [])
    , rejectsWith
        "OpenPreparedColimaMutationArgs.hs"
        (("Module 'HostBootstrap.Ensure.Colima' does not export 'preparedColimaWallArgs'") :| [])
    , rejectsWith
        "CrossPlanClusterConsumer.hs"
        (("Couldn't match type 'ForeignClusterPlan' with 'ClusterPlan'") :| ["Couldn't match type 'ForeignProviderPlan' with 'ClusterPlan'"
        , "Couldn't match type 'ForeignTopologyPlan' with 'ClusterPlan'"
        , "Couldn't match type 'ForeignSlicePlan' with 'ClusterPlan'"])
    , rejectsWith
        "CompatibilityClusterInputs.hs"
        ( "Couldn't match expected type: HostBootstrap.Cluster.Lifecycle.PlanOwnedClusterConfig scope0 specDigest0 planId0 configId0 cfg0 clusterId0 clusterFrame0 providerId0 providerFrame0 budgetId0 provider0 capabilityId0 wallSpecId0 workloadSetId0 partitionId0 with actual type: LifecyclePlan scope planId"
            :| [ "Couldn't match expected type 'PreparedGate' with actual type 'DependencySnapshot scope planId'"
               ]
        )
    , rejectsWith
        "CallerForgedClusterProbe.hs"
        ("Couldn't match expected type: hostbootstrap-core-0.1.0.0:HostBootstrap.Substrate.Provider.Dependency.Internal.RunningProviderDependency scope planId providerId with actual type: DependencyProbe scope planId providerId ProviderResource" :| [])
    , rejectsWith
        "ProvisionedProviderClusterDependency.hs"
        (("Couldn't match type 'Provisioned' with 'HostBootstrap.Reconcile.Running'") :| [])
    , rejectsWith
        "ForgeClusterAuthorities.hs"
        (("Illegal term-level use of the type constructor 'PlanOwnedCluster'") :| ["Illegal term-level use of the type constructor 'PlanOwnedClusterConfig'"
        , "Illegal term-level use of the type constructor 'PreparedClusterReconcile'"
        , "Data constructor not in scope: ManagedClusterProvision"
        , "Data constructor not in scope: ForeignClusterProvision"
        , "Illegal term-level use of the type constructor 'ClusterReconcileCallResult'"
        , "Illegal term-level use of the type constructor 'PreparedClusterCordon'"
        , "Illegal term-level use of the type constructor 'ClusterCordonCallResult'"
        , "Illegal term-level use of the type constructor 'AppliedClusterCordon'"
        , "Illegal term-level use of the type constructor 'ClusterReadiness'"
        , "Illegal term-level use of the type constructor 'ClusterReadinessCallResult'"
        , "Illegal term-level use of the type constructor 'PreparedClusterCleanup'"
        , "Illegal term-level use of the type constructor 'ClusterCleanupCallResult'"
        , "Illegal term-level use of the type constructor 'ManagedClusterHandle'"
        , "Illegal term-level use of the type constructor 'RunningProviderDependency'"])
    , rejectsWith
        "CoerceClusterAuthorityRoles.hs"
        (("Couldn't match type 'PackagePlanA' with 'PackagePlanB' arising from a use of 'coerce'") :| ["Couldn't match type 'ReconcilePlanA' with 'ReconcilePlanB' arising from a use of 'coerce'"
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
        , "Couldn't match type 'DependencyPlanA' with 'DependencyPlanB' arising from a use of 'coerce'"])
    , rejectsWith
        "ImportClusterObservationInternal.hs"
        (("Could not load module 'HostBootstrap.Cluster.Observation.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "ImportClusterBackendInternal.hs"
        ("Could not load module 'HostBootstrap.Cluster.Backend.Internal'. it is a hidden module in the package 'hostbootstrap-core-0.1.0.0'" :| [])
    , rejectsWith
        "ImportClusterExposureInternal.hs"
        ("Could not load module 'HostBootstrap.Cluster.Exposure.Internal'. it is a hidden module in the package 'hostbootstrap-core-0.1.0.0'" :| [])
    , rejectsWith
        "ForgeResolvedExposure.hs"
        (("an item called 'ResolvedExposure' is exported, but it does not export any children (constructors, class methods or field names) called 'ResolvedExposure'") :| [])
    , rejectsWith
        "ConstructRawLocalExposure.hs"
        ("an item called 'Exposure' is exported, but it does not export any children (constructors, class methods or field names) called 'ResolvedLocalExposure'" :| [])
    , rejectsWith
        "ConstructRawHostEndpoint.hs"
        ("Module 'HostBootstrap.Network' does not export 'mkEndpoint'" :| [])
    , rejectsWith
        "CoerceExposureAuthorityRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ClusterA' with 'ClusterB' arising from a use of 'coerce'"
        , "Couldn't match type 'ServiceA' with 'ServiceB' arising from a use of 'coerce'"])
    , rejectsWith
        "OpenClusterBackendExecutor.hs"
        ("Module 'HostBootstrap.Cluster.Backend' does not export 'mkStrongClusterBackend'" :| [])
    , rejectsWith
        "ForgeStrongClusterBackend.hs"
        (("Illegal term-level use of the type constructor 'StrongClusterBackend'") :| [])
    , rejectsWith
        "CoerceBudgetEvidenceRoles.hs"
        (("Couldn't match type 'WorkloadPlanA' with 'WorkloadPlanB' arising from a use of 'coerce'") :| ["Couldn't match type 'SlicePlanA' with 'SlicePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'CapabilityPlanA' with 'CapabilityPlanB' arising from a use of 'coerce'"])
    , rejectsWith
        "RawReconcile.hs"
        (("Illegal term-level use of the type constructor 'ResourceHandle'") :| [])
    , rejectsWith
        "ForgeVerifiedResourceRecordBundle.hs"
        (("Illegal term-level use of the type constructor 'VerifiedResourceRecordBundle'") :| [])
    , rejectsWith
        "ForgeVerifiedResourceRecordSet.hs"
        (("Illegal term-level use of the type constructor 'VerifiedResourceRecordSet'") :| [])
    , rejectsWith
        "CrossSnapshotResourceRecordSet.hs"
        (("Couldn't match type 'secondPlanDigest' with 'firstPlanDigest'") :| [])
    , rejectsWith
        "ForgeRehydratedResourceSet.hs"
        (("Illegal term-level use of the type constructor 'RehydratedResourceSet'") :| [])
    , rejectsWith
        "RawReceiptAsRehydratedReceipt.hs"
        (("Couldn't match expected type: RehydratedOwnershipReceipt") :| [])
    , rejectsWith
        "CoerceRehydratedResourceSetBroker.hs"
        (("Couldn't match type 'firstBroker' with 'secondBroker' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "EmptyProspectiveMigrationDrafts.hs"
        ("Couldn't match expected type: ghc-internal-9.1204.0:GHC.Internal.Base.NonEmpty (hostbootstrap-core-0.1.0.0:HostBootstrap.Lifecycle.Plan.PlanDraft (Production Project) NewSpecDigest (Config (Production Project))) with actual type: [a0]" :| [])
    , rejectsWith
        "CrossConfigProspectiveMigration.hs"
        (("Couldn't match type 'secondConfigId' with 'firstConfigId'") :| [])
    , rejectsWith
        "ForgeCompletedMigrationRecoveryProfile.hs"
        (("Illegal term-level use of the type constructor 'CompletedMigrationRecoveryProfile'") :| [])
    , rejectsWith
        "ForgeRecoveredProjectFrame.hs"
        (("Illegal term-level use of the type constructor 'RecoveredProjectFrame'") :| [])
    , rejectsWith
        "ResourceRecordTombstoneAsReceipt.hs"
        (("Couldn't match expected type 'OwnershipReceipt scope planId id resource' with actual type '()'") :| [])
    , rejectsWith
        "ForgeProviderCapability.hs"
        (("Illegal term-level use of the type constructor 'ProviderCapability'") :| [])
    , rejectsWith
        "ForgeIncusProviderCapability.hs"
        ("an item called 'IncusProviderCapability' is exported, but it does not export any children (constructors, class methods or field names) called 'IncusProviderCapability'" :| [])
    , rejectsWith
        "ForgeIncusProviderReady.hs"
        ("an item called 'IncusProviderStatus' is exported, but it does not export any children (constructors, class methods or field names) called 'IncusProviderReady'" :| [])
    , rejectsWith
        "EscapeProviderCapabilityIdentity.hs"
        (("Couldn't match type 'capabilityId' with 'ChosenCapability'") :| [])
    , rejectsWith
        "CoerceProviderCapabilityIdentity.hs"
        (("Couldn't match type 'CapabilityA' with 'CapabilityB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "ForgeStrongAliasBackend.hs"
        (("Illegal term-level use of the type constructor 'StrongAliasBackend'") :| [])
    , rejectsWith
        "ForgePreparedGuestAliasCall.hs"
        (("Illegal term-level use of the type constructor 'PreparedGuestAliasCall'") :| [])
    , rejectsWith
        "ObservedReadyGuestAlias.hs"
        (("Couldn't match expected type: DependencyProbe scope planId shareId DurableShareResource with actual type: ObservedReady DurableShareReady") :| [])
    , rejectsWith
        "ForeignGuestAliasRelease.hs"
        (("Couldn't match expected type: ManagedGuestAliasHandle scope0 planId0 providerId0 backendId0 capabilityId0 aliasId0 shareId0 phase0 with actual type: ResourceHandle scope planId aliasId DurableAliasResource Unmanaged Observed") :| [])
    , rejectsWith
        "CrossAliasReceipt.hs"
        (("Couldn't match type 'aliasB' with 'aliasA'") :| [])
    , rejectsWith
        "ForgePreparedProviderProvision.hs"
        (("Illegal term-level use of the type constructor 'PreparedProviderProvision'") :| [])
    , rejectsWith
        "ForgePreparedProviderShare.hs"
        (("Illegal term-level use of the type constructor 'PreparedProviderShare'") :| [])
    , rejectsWith
        "ForgeManagedProviderHandles.hs"
        (("Illegal term-level use of the type constructor 'ManagedProviderHandle'") :| ["Illegal term-level use of the type constructor 'ManagedProviderShareHandle'"])
    , rejectsWith
        "ForgeProviderPhaseAdvance.hs"
        (("Illegal term-level use of the type constructor 'ProviderPhaseAdvance'") :| [])
    , rejectsWith
        "CoerceProviderPhaseAdvanceRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'BackendA' with 'BackendB' arising from a use of 'coerce'"
        , "Couldn't match type 'ProviderA' with 'ProviderB' arising from a use of 'coerce'"
        , "Couldn't match type 'PhaseA' with 'PhaseB' arising from a use of 'coerce'"])
    , rejectsWith
        "ForgeProviderShareSpec.hs"
        (("Illegal term-level use of the type constructor 'ProviderShareSpec'") :| [])
    , rejectsWith
        "ForgeProviderObservation.hs"
        (("Data constructor not in scope: ProviderProvisionCreated") :| [])
    , rejectsWith
        "ForgeProviderCallResult.hs"
        (("Illegal term-level use of the type constructor 'ProviderProvisionCallResult'") :| [])
    , rejectsWith
        "ForgeProviderBackendBinding.hs"
        (("Illegal term-level use of the type constructor 'ProviderBackendBinding'") :| [])
    , rejectsWith
        "CrossPreparedProviderResult.hs"
        (("Couldn't match type 'attemptB' with 'attemptA'") :| [])
    , rejectsWith
        "CrossBackendProviderCall.hs"
        (("Couldn't match type 'backendB' with 'backendA' Expected: StrongProviderBackend backendA Actual: StrongProviderBackend backendB") :| [])
    , rejectsWith
        "CrossBackendProviderResult.hs"
        (("Couldn't match type 'backendB' with 'backendA'") :| [])
    , rejectsWith
        "CoerceManagedProviderHandleRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'BackendA' with 'BackendB' arising from a use of 'coerce'"
        , "Couldn't match type 'ProviderA' with 'ProviderB' arising from a use of 'coerce'"
        , "Couldn't match type 'PhaseA' with 'PhaseB' arising from a use of 'coerce'"])
    , rejectsWith
        "CoerceManagedProviderShareHandleRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'BackendA' with 'BackendB' arising from a use of 'coerce'"
        , "Couldn't match type 'ProviderA' with 'ProviderB' arising from a use of 'coerce'"
        , "Couldn't match type 'ShareA' with 'ShareB' arising from a use of 'coerce'"
        , "Couldn't match type 'PhaseA' with 'PhaseB' arising from a use of 'coerce'"])
    , rejectsWith
        "GenericProviderHandleAsManaged.hs"
        (("Couldn't match type: ManagedProviderHandle scope planId backendId providerId Provisioned with: ResourceHandle scope planId providerId ProviderResource Managed Provisioned") :| [])
    , rejectsWith
        "GenericProviderHandleAsBoundExec.hs"
        (("Couldn't match expected type: hostbootstrap-core-0.1.0.0:HostBootstrap.Substrate.Provider.Observation.Internal.ManagedProviderHandle scope0 planId0 backendId providerId0 Running with actual type: ResourceHandle scope planId providerId ProviderResource Managed Running") :| [])
    , rejectsWith
        "GenericShareHandleAsAliasAuthority.hs"
        (("Couldn't match expected type: ManagedProviderShareHandle scope planId backendId providerId shareId Provisioned with actual type: ResourceHandle scope planId shareId DurableShareResource Managed Provisioned") :| [])
    , rejectsWith
        "ImportProviderObservationInternal.hs"
        (("Could not load module 'HostBootstrap.Substrate.Provider.Observation.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "ForeignProviderStop.hs"
        (("Couldn't match expected type: ManagedProviderHandle scope planId backendId0 providerId Running with actual type: ResourceHandle scope planId providerId ProviderResource Unmanaged Observed") :| [])
    , rejectsWith
        "CrossProviderReceipt.hs"
        (("Couldn't match type 'providerB' with 'providerA' Expected: ManagedProviderHandle scope planId backendId providerA Running Actual: ManagedProviderHandle scope planId backendId providerB Running") :| [])
    , rejectsWith
        "UnstartableProviderPhase.hs"
        (("Couldn't match type 'Provisioned' with 'Running'") :| [])
    , rejectsWith
        "BootNonProviderResource.hs"
        (("Couldn't match type 'ProviderResource' with 'DurableShareResource'") :| [])
    , rejectsWith
        "ForgeSubstrateProvider.hs"
        (("Illegal term-level use of the type constructor 'SubstrateProvider'") :| [])
    , rejectsWith
        "UpdateSubstrateProvider.hs"
        (("Not in scope: record field 'spLaunch'") :| [])
    , rejectsWith
        "OpenSubstrateProviderMutationSelectors.hs"
        (("Module 'HostBootstrap.Substrate.Provider' does not export 'spDestroy'") :| [])
    , rejectsWith
        "ForgeAliasCallObservation.hs"
        (("Data constructor not in scope: AliasCallCreated") :| [])
    , rejectsWith
        "CrossAliasCallResult.hs"
        (("Couldn't match type: GuestAliasCallSettlement scope planId providerId backendId capabilityId aliasA shareId with: ReconcileResult scope planId aliasA DurableAliasResource Provisioned") :| [])
    , rejectsWith
        "CrossBackendAliasCall.hs"
        (("Couldn't match type 'backendA' with 'backendB' Expected: StrongAliasBackend scope planId providerId backendA capabilityId") :| [])
    , rejectsWith
        "ForeignClusterCleanup.hs"
        ("Couldn't match expected type: ManagedClusterHandle scope planId clusterId phase0 with actual type: ResourceHandle scope planId clusterId ClusterResource Unmanaged Observed" :| [])
    , rejectsWith
        "CrossClusterReceipt.hs"
        ("Couldn't match type 'clusterB' with 'clusterA' Expected: OwnershipReceipt scope planId clusterA ClusterResource Actual: OwnershipReceipt scope planId clusterB ClusterResource" :| [])
    , rejectsWith
        "HostLocalClusterRedirect.hs"
        (("Couldn't match type 'ClusterOnly' with 'HostLocal' Expected: Endpoint HostLocal Actual: Endpoint ClusterOnly") :| [])
    , rejectsWith
        "EndpointScopeSubstitution.hs"
        ("Couldn't match type 'ClusterOnly' with 'HostLocal' Expected: Endpoint ClusterOnly -> Endpoint HostLocal Actual: Endpoint ClusterOnly -> Endpoint ClusterOnly" :| [])
    , rejectsWith
        "RawRegistryPlan.hs"
        ("Illegal term-level use of the type constructor 'RegistryPlan'" :| [])
    , rejectsWith
        "ForgeReadyBlobRoute.hs"
        ("Illegal term-level use of the type constructor 'ReadyBlobRoute'" :| [])
    , rejectsWith
        "ForgeCommandAuthority.hs"
        (("Illegal term-level use of the type constructor ‘CommandAuthority’") :| [])
    , rejectsWith
        "ForgeRootInvocationAuthority.hs"
        (("Illegal term-level use of the type constructor ‘RootInvocationAuthority’") :| [])
    , rejectsWith
        "ForgeBrokerEpoch.hs"
        (("Illegal term-level use of the type constructor ‘BrokerEpoch’") :| [])
    , rejectsWith
        "ForgeVerifiedOsPrincipal.hs"
        (("Illegal term-level use of the type constructor ‘VerifiedOsPrincipal’") :| [])
    , rejectsWith
        "ForgeInvocationId.hs"
        (("Illegal term-level use of the type constructor ‘InvocationId’") :| [])
    , rejectsWith
        "EscapeInstalledProjectIdentity.hs"
        (("Couldn't match type 'projectId' with 'ChosenProject'") :| [])
    , rejectsWith
        "ForgeInstalledProjectIdentity.hs"
        (("Illegal term-level use of the type constructor 'InstalledProjectIdentity'") :| [])
    , rejectsWith
        "CrossRootScopeAuthority.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CrossRootInvocationAuthority.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "ForgeRootScopeAuthority.hs"
        (("Illegal term-level use of the type constructor 'RootScopeAuthority'") :| [])
    , rejectsWith
        "OpenRecordedBrokerEpoch.hs"
        (("Module 'HostBootstrap.Authority' does not export 'withReifiedAllocatedBrokerEpochKernel'") :| ["Module 'HostBootstrap.Lifecycle.Mode' does not export 'withReifiedAllocatedBrokerEpochKernel'"])
    , rejectsWith
        "OpenRootInvocationAuthority.hs"
        ("Module 'HostBootstrap.Authority' does not export 'withVerifiedRootInvocationKernel'" :| [])
    , rejectsWith
        "CrossScopeProjectUpAuthority.hs"
        (("Couldn't match type 'ScopeB' with 'ScopeA'") :| [])
    , rejectsWith
        "CrossSpecProjectUpAuthority.hs"
        (("Couldn't match type 'SpecB' with 'SpecA'") :| [])
    , rejectsWith
        "CrossPlanDigestProjectUpAuthority.hs"
        (("Couldn't match type 'PlanDigestB' with 'PlanDigestA'") :| [])
    , rejectsWith
        "CrossPlanProjectUpAuthority.hs"
        (("Couldn't match type 'PlanB' with 'PlanA'") :| [])
    , rejectsWith
        "CrossConfigProjectUpAuthority.hs"
        (("Couldn't match type 'ConfigB' with 'ConfigA'") :| [])
    , rejectsWith
        "CrossFrameProjectUpAuthority.hs"
        (("Couldn't match type 'FrameB' with 'FrameA'") :| [])
    , rejectsWith
        "CrossBrokerProjectUpAuthority.hs"
        (("Couldn't match type 'BrokerB' with 'BrokerA'") :| [])
    , rejectsWith
        "CrossVerbProjectUpAuthority.hs"
        (("Couldn't match type 'VerbDown' with 'VerbUp'") :| [])
    , rejectsWith
        "ImportAuthorityKernel.hs"
        (("It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:authority-internal'") :| [])
    , rejectsWith
        "ImportAuthorityTesting.hs"
        (("It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:authority-internal'") :| [])
    , rejectsWith
        "CoerceInstalledProjectIdentity.hs"
        (("Couldn't match type 'ProjectA' with 'ProjectB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceBrokerEpoch.hs"
        (("Couldn't match type 'EpochA' with 'EpochB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceCommandAuthorityEpoch.hs"
        (("Couldn't match type 'EpochA' with 'EpochB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceCommandAuthorityVerb.hs"
        (("Couldn't match type 'VerbUp' with 'VerbDown' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceCommandAuthorityPhase.hs"
        (("Couldn't match type 'PreparePhase' with 'ExecutePhase' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CrossScopeCommandAuthority.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CrossPlanCommandAuthority.hs"
        (("Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CrossFrameCommandAuthority.hs"
        (("Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CurrentFrameAsCommandAuthority.hs"
        (("Couldn't match expected type: CommandAuthority Scope PlanId Frame BrokerGeneration VerbUp PreparePhase with actual type: CurrentFrame Scope PlanId Frame") :| [])
    , rejectsWith
        "ProjectFrameAsCommandAuthority.hs"
        (("Couldn't match expected type: CommandAuthority Scope PlanId Frame BrokerGeneration VerbUp PreparePhase with actual type: ProjectFrame Scope SpecDigest PlanId ConfigId Frame") :| [])
    , rejectsWith
        "ValidatedContextAsCommandAuthority.hs"
        (("Couldn't match expected type: CommandAuthority Scope PlanId Frame BrokerGeneration VerbUp PreparePhase with actual type: ValidatedContext Scope PlanId Frame") :| [])
    , rejectsWith
        "WrongVerbCloseRoot.hs"
        (("Couldn't match type 'VerbDestroy' with 'VerbUp' Expected: RootInvocationAuthority (Production project) generation VerbUp") :| [])
    , rejectsWith
        "ForgeProductionClosureAuthorization.hs"
        (("an item called 'ProductionClosureAuthorization' is exported, but it does not export any children (constructors, class methods or field names) called 'SettledProductionClosure'") :| [])
    , rejectsWith "CoerceProductionClosureAuthorization.hs" ("Couldn't match type 'FirstGeneration' with 'SecondGeneration' arising from a use of 'coerce'" :| ["Couldn't match type 'FirstProject' with 'SecondProject' arising from a use of 'coerce'"])
    , rejectsWith
        "ForgeHarnessAuthority.hs"
        (("an item called 'HarnessConfigAuthority' is exported, but it does not export any children (constructors, class methods or field names) called 'HarnessConfigAuthority'") :| [])
    , rejectsWith
        "HarnessConfigAsProduction.hs"
        ("Expected: SecretRef (Production Project) Actual: SecretRef (Harness Project runId)" :| [])
    , rejectsWith
        "CrossRunPlaintext.hs"
        ("Couldn't match type 'runA' with 'runB' Expected: HarnessConfigAuthority Project runB Actual: HarnessConfigAuthority Project runA" :| [])
      , rejectsWith
          "CoerceHarnessAuthorityRun.hs"
          ("Couldn't match type 'RunA' with 'RunB' arising from a use of 'coerce'" :| [])
      , rejectsWith
          "CoerceHarnessConfigAuthorityRun.hs"
          ("Couldn't match type 'RunA' with 'RunB' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "ProductionPlaintext.hs"
        ("Couldn't match type: HostBootstrap.ProjectScope.Harness Project runId with: Production Project Expected: SecretRef (Production Project) Actual: SecretRef (HostBootstrap.ProjectScope.Harness Project runId)" :| [])
    , rejectsWith
        "ForgeProjectModeLease.hs"
        ("an item called 'ProjectModeLease' is exported, but it does not export any children (constructors, class methods or field names) called 'ProjectModeLease'" :| [])
    , rejectsWith
        "CoerceHarnessModeRun.hs"
        (("Couldn't match type 'RunA' with 'RunB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceProjectModeLease.hs"
        (("Couldn't match type 'ProductionMode' with 'HarnessMode Run' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "OpenGenericProjectModeMutation.hs"
        ("Module 'HostBootstrap.Lifecycle.Mode' does not export 'acquireModeWire'" :| [])
    , rejectsWith
        "ForgeRunId.hs"
        ("an item called 'RunId' is exported, but it does not export any children (constructors, class methods or field names) called 'RunId'" :| [])
    , rejectsWith
        "OpenRunKeyParser.hs"
        ("Module 'HostBootstrap.Lifecycle.Mode' does not export 'parseRunKey'" :| [])
    , rejectsWith
        "OpenRunIdFromText.hs"
        ("Module 'HostBootstrap.Lifecycle.Mode' does not export 'withReifiedRunId'" :| [])
    , rejectsWith
        "CoerceRunId.hs"
        (("Couldn't match type 'RunA' with 'RunB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "ProductionLeaseAsHarnessSnapshot.hs"
        (("Couldn't match type: Harness Project Run with: Production Project Expected: VerifiedPlanSnapshot") :| [])
    , rejectsWith
        "CrossRunLeaseBinding.hs"
        (("Couldn't match type 'RunB' with 'RunA' Expected: VerifiedPlanSnapshot") :| [])
    , rejectsWith
        "CrossDigestLeaseBinding.hs"
        (("Couldn't match type 'SpecDigestB' with 'SpecDigestA' Expected: BoundRunLease") :| [])
    , rejectsWith
        "ForgeActiveProjectMode.hs"
        ("an item called 'ActiveProjectMode' is exported, but it does not export any children (constructors, class methods or field names) called 'ActiveProjectMode'" :| [])
    , rejectsWith
        "ProductionActiveModeAsHarness.hs"
        (("Couldn't match type: Production Project with: Harness Project Run arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CrossRunActiveProjectMode.hs"
        (("Couldn't match type 'RunA' with 'RunB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "HarnessLeaseAsProduction.hs"
        (("Couldn't match type: Harness Project Run with: Production Project Expected: RootScopeAuthority (Production Project)") :| [])
    , rejectsWith
        "CrossBrokerProductionProfile.hs"
        (("Couldn't match type 'BrokerB' with 'BrokerA' Expected: UnboundRunLease (Production Project) BrokerA") :| [])
    , rejectsWith
        "ForgeLifecycleProfile.hs"
        ("an item called 'LifecycleProfile' is exported, but it does not export any children (constructors, class methods or field names) called 'LifecycleProfile'" :| [])
    , rejectsWith
        "CoerceLifecycleProfileScope.hs"
        ("Couldn't match type 'ScopeAlias' with 'Production Project' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "ProductionEvidenceAsHarnessProfile.hs"
        (("Couldn't match type: Production Project with: Harness Project Run Expected: RootScopeAuthority (Harness Project Run)") :| [])
    , rejectsWith
        "CrossRunHarnessProfile.hs"
        (("Couldn't match type 'RunB' with 'RunA' Expected: ActiveProjectMode (Harness Project RunA) BrokerGeneration") :| [])
    , rejectsWith
        "CrossBrokerHarnessProfile.hs"
        (("Couldn't match type 'BrokerB' with 'BrokerA' Expected: UnboundRunLease (Harness Project Run) BrokerA") :| [])
    , rejectsWith
        "ProductionProjectPlanAsHarnessChain.hs"
        (("Couldn't match type: Harness Project Run with: Production Project") :| [])
    , rejectsWith
        "CrossRunHarnessProjectPlanChain.hs"
        (("Couldn't match type 'RunB' with 'RunA'") :| [])
    , rejectsWith
        "ForgeHarnessLifecycle.hs"
        (("an item called 'HarnessLifecycle' is exported, but it does not export any children (constructors, class methods or field names) called 'HarnessLifecycle'") :| [])
    , rejectsWith
        "ImportHarnessLifecycleInternal.hs"
        (("Could not load module 'HostBootstrap.Harness.Lifecycle.Internal'") :| [])
    , rejectsWith
        "ImportRawHarnessCloseAction.hs"
        ("Module 'HostBootstrap.Harness.Ownership' does not export 'newOwnedHarnessCloseControl'" :| ["Module 'HostBootstrap.Harness.Ownership' does not export 'consumeOwnedHarnessClose'"])
    , rejectsWith
        "ImportHarnessOwnershipInternal.hs"
        ("Could not load module 'HostBootstrap.Harness.Ownership.Internal'. it is a hidden module in the package 'hostbootstrap-core-0.1.0.0'" :| [])
    , rejectsWith
        "AuthorizeHarnessCloseWithoutClosure.hs"
        (("Couldn't match expected type 'HostBootstrap.Lifecycle.Mode.ProjectClosureEvidence (Harness Project Run)' with actual type 'Word64'") :| [])
    , rejectsWith
        "ForgeRunLease.hs"
        ("an item called 'UnboundRunLease' is exported, but it does not export any children (constructors, class methods or field names) called 'UnboundRunLease'" :| [])
    , rejectsWith
        "ForgeBoundRunLease.hs"
        ("an item called 'BoundRunLease' is exported, but it does not export any children (constructors, class methods or field names) called 'BoundRunLease'" :| [])
    , rejectsWith
        "ForgeVerifiedPlanSnapshot.hs"
        ("an item called 'VerifiedPlanSnapshot' is exported, but it does not export any children (constructors, class methods or field names) called 'VerifiedPlanSnapshot'" :| [])
    , rejectsWith
        "ForgeAcquisitionJournal.hs"
        (("Illegal term-level use of the type constructor 'AcquisitionJournal'") :| [])
    , rejectsWith
        "CoerceAcquisitionJournalScope.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceAcquisitionJournalPlan.hs"
        (("Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceAcquisitionJournalBroker.hs"
        (("Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CrossPlanAcquisitionJournal.hs"
        (("Couldn't match type 'PlanA' with 'PlanB'") :| [])
    , rejectsWith
        "CrossBrokerAcquisitionJournal.hs"
        (("Couldn't match type 'BrokerA' with 'BrokerB'") :| [])
    , rejectsWith
        "ImportAcquisitionJournalAdmission.hs"
        (("Could not load module 'HostBootstrap.Lifecycle.Plan'. it is a hidden module") :| [])
    , rejectsWith
        "CoerceAcquisitionJournalAdmission.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:HostBootstrap.Lifecycle.Plan.AcquisitionJournalAdmission' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "ForgeAcquisitionJournalAdmission.hs"
        ("Module 'HostBootstrap.Lifecycle.Session' does not export 'AcquisitionJournalAdmission'" :| [])
    , rejectsWith
        "ForgeExistingBoundSnapshotAdmission.hs"
        ("Module 'HostBootstrap.Lifecycle.Mode' does not export 'ExistingBoundSnapshotAdmission'" :| [])
    , rejectsWith
        "PassRawAdmissionToReverseRootTargetCursor.hs"
        ("Couldn't match expected type 'hostbootstrap-core-0.1.0.0:HostBootstrap.Lifecycle.Plan.AcquisitionJournalAdmission' with actual type '()'" :| [])
    , rejectsWith
        "PassRawAdmissionToReverseAcquisitionJournal.hs"
        ("Couldn't match expected type 'hostbootstrap-core-0.1.0.0:HostBootstrap.Lifecycle.Plan.AcquisitionJournalAdmission' with actual type '()'" :| [])
    , rejectsWith
        "AcquisitionJournalAsCommandAuthority.hs"
        (("Couldn't match expected type: CommandAuthority Scope PlanId Frame BrokerGeneration VerbUp ExecutePhase with actual type: AcquisitionJournal Scope PlanId BrokerGeneration") :| [])
    , rejectsWith
        "ForgeLifecycleCursor.hs"
        (("Illegal term-level use of the type constructor 'LifecycleCursor'") :| [])
    , rejectsWith
        "CoerceLifecycleCursorScope.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceLifecycleCursorPlan.hs"
        (("Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceLifecycleCursorFrame.hs"
        (("Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceLifecycleCursorBroker.hs"
        (("Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceLifecycleCursorVerb.hs"
        (("Couldn't match type 'VerbUp' with 'VerbDown' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceLifecycleCursorPhase.hs"
        (("Couldn't match type 'PreparePhase' with 'ExecutePhase' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CrossScopeLifecycleCursorOpen.hs"
        (("Couldn't match type 'ScopeB' with 'ScopeA'") :| [])
    , rejectsWith
        "CrossPlanLifecycleCursorOpen.hs"
        (("Couldn't match type 'PlanB' with 'PlanA'") :| [])
    , rejectsWith
        "CrossFrameLifecycleCursor.hs"
        (("Couldn't match type 'FrameA' with 'FrameB'") :| [])
    , rejectsWith
        "CrossBrokerLifecycleCursor.hs"
        (("Couldn't match type 'BrokerA' with 'BrokerB'") :| [])
    , rejectsWith
        "CrossVerbLifecycleCursor.hs"
        (("Couldn't match type 'VerbUp' with 'VerbDown'") :| [])
    , rejectsWith
        "CrossPhaseLifecycleCursor.hs"
        (("Couldn't match type 'PreparePhase' with 'ExecutePhase'") :| [])
    , rejectsWith
        "EscapeLifecycleCursorFrame.hs"
        (("Couldn't match type 'frame' with 'ChosenFrame'") :| [])
    , rejectsWith
        "SkipLifecycleCursorExecute.hs"
        (("Couldn't match type 'PreparePhase' with 'ExecutePhase'") :| [])
    , rejectsWith
        "AdvanceTerminalLifecycleCursor.hs"
        (("Couldn't match type 'TeardownPhase' with 'ExecutePhase'") :| [])
    , rejectsWith
        "LifecycleCursorAsCommandAuthority.hs"
        (("Couldn't match expected type: CommandAuthority Scope PlanId Frame BrokerGeneration VerbUp PreparePhase with actual type: LifecycleCursor Scope PlanId Frame BrokerGeneration VerbUp PreparePhase") :| [])
    , rejectsWith
        "LifecycleCursorAsTeardownCursor.hs"
        (("Couldn't match expected type: LocalWork Scope PlanId Frame VerbDown with actual type: LifecycleCursor Scope PlanId Frame BrokerGeneration VerbDown TeardownPhase") :| [])
    , rejectsWith
        "ForgeProtectedSession.hs"
        (("Illegal term-level use of the type constructor 'ProtectedSession'") :| [])
    , rejectsWith
        "CoerceProtectedSession.hs"
        (("Couldn't match type 'SessionA' with 'SessionB'") :| [])
    , rejectsWith
        "ForgeRecordKey.hs"
        (("Illegal term-level use of the type constructor 'RecordKey'") :| [])
    , rejectsWith
        "ForgeProtectedStore.hs"
        (("Illegal term-level use of the type constructor 'ProtectedStore'") :| [])
    , rejectsWith
        "ForgeProtectedStoreIdentity.hs"
        (("Illegal term-level use of the type constructor 'ProtectedStoreIdentity'") :| [])
    , rejectsWith
        "ForgeProjectSigningKey.hs"
        (("Illegal term-level use of the type constructor 'ProjectSigningKey'") :| [])
    , rejectsWith
        "ForgeProjectVerificationKey.hs"
        (("Illegal term-level use of the type constructor 'ProjectVerificationKey'") :| [])
    , rejectsWith
        "ProjectSigningKeyAsVerificationKey.hs"
        (("Couldn't match type 'ProjectSigningKey' with 'ProjectVerificationKey'") :| [])
    , rejectsWith
        "CrossProtocolSigningKeys.hs"
        (("Couldn't match type 'ProjectSigningKey' with 'BuildSigningKey'") :| ["Couldn't match type 'ProjectSigningKey' with 'ActivationSigningKey'"
        , "Couldn't match type 'BuildSigningKey' with 'ProjectSigningKey'"
        , "Couldn't match type 'BuildSigningKey' with 'ActivationSigningKey'"
        , "Couldn't match type 'ActivationSigningKey' with 'ProjectSigningKey'"
        , "Couldn't match type 'ActivationSigningKey' with 'BuildSigningKey'"])
    , rejectsWith
        "ForgeHandoffOpaqueAuthorities.hs"
        (("Data constructor not in scope: ProductionHandoffScope") :| ["Illegal term-level use of the type constructor 'HandoffBinding'"
        , "Illegal term-level use of the type constructor 'RootedPayloadBinding'"
        , "Illegal term-level use of the type constructor 'RecoveryChildPackage'"
        , "Illegal term-level use of the type constructor 'AuthenticatedRootScope'"
        , "Illegal term-level use of the type constructor 'RootBroker'"
        , "Illegal term-level use of the type constructor 'BrokerRoute'"
        , "Illegal term-level use of the type constructor 'BrokerRelay'"
        , "Illegal term-level use of the type constructor 'HandoffOffer'"
        , "Illegal term-level use of the type constructor 'AuthenticatedConfigPayload'"
        , "Illegal term-level use of the type constructor 'VerifiedHandoff'"])
    , rejectsWith
        "CoerceHandoffOpaqueRoles.hs"
        (("Couldn't match type 'HandoffScopeA' with 'HandoffScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'BindingScopeA' with 'BindingScopeB' arising from a use of 'coerce'"
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
        , "Couldn't match type 'PayloadBrokerA' with 'PayloadBrokerB' arising from a use of 'coerce'"])
    , rejectsWith
        "EscapeParsedHandoffGeneration.hs"
        (("Couldn't match type 'brokerGeneration' with 'CallerChosenGeneration'") :| [])
    , rejectsWith
        "CoerceVerifiedHandoffScope.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceVerifiedHandoffBroker.hs"
        (("Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CrossScopeBrokerRelay.hs"
        (("Couldn't match type: Harness projectId runId with: Production projectId") :| [])
    , rejectsWith
        "CrossScopeAuthenticatedConfig.hs"
        (("Couldn't match type: Harness projectId runId with: Production projectId") :| [])
    , rejectsWith
        "ImportHandoffReceiver.hs"
        (("Could not load module 'HostBootstrap.Handoff.Receiver'. it is a hidden module") :| [])
    , rejectsWith
        "ImportHandoffReceiverInternal.hs"
        (("Could not load module 'HostBootstrap.Handoff.Receiver.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "ImportHandoffInternal.hs"
        (("Could not load module 'HostBootstrap.Handoff.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "ImportHandoffProtocol.hs"
        (("Could not load module 'HostBootstrap.Handoff.Protocol'. it is a hidden module") :| [])
    , rejectsWith
        "ImportHandoffRooted.hs"
        (("Could not load module 'HostBootstrap.Handoff.Rooted'. it is a hidden module") :| [])
    , rejectsWith
        "ImportHandoffRecovery.hs"
        (("Could not load module 'HostBootstrap.Handoff.Recovery'. it is a hidden module") :| [])
    , rejectsWith
        "OpenRecoveryChildPackageDecoder.hs"
        ("Module 'HostBootstrap.Handoff' does not export 'recoveryChildPackageFromWireKernel'" :| [])
    , rejectsWith
        "EscapeAuthenticatedRootScopeRun.hs"
        (("Couldn't match type 'runId' with 'CallerChosenRun'") :| [])
    , rejectsWith
        "ImportHandoffRelay.hs"
        (("Could not load module 'HostBootstrap.Handoff.Relay'. it is a hidden module") :| [])
    , rejectsWith
        "ImportHandoffRuntime.hs"
        (("Could not load module 'HostBootstrap.Handoff.Runtime'. it is a hidden module") :| [])
    , rejectsWith
        "ImportLifecycleRooted.hs"
        (("Could not load module 'HostBootstrap.Lifecycle.Rooted'. it is a hidden module") :| [])
    , rejectsWith
        "ImportLifecycleRootedReceipt.hs"
        (("Could not load module 'HostBootstrap.Lifecycle.Rooted.Receipt'. it is a hidden module") :| [])
    , rejectsWith
        "ImportHandoffCompletion.hs"
        (("Could not load module 'HostBootstrap.Handoff.Completion'. it is a hidden module") :| [])
    , rejectsWith
        "ImportHandoffTerminalReport.hs"
        (("Could not load module 'HostBootstrap.Handoff.TerminalReport'. it is a hidden module") :| [])
    , rejectsWith
        "HandoffLifecycleCompletionType.hs"
        (("Module 'HostBootstrap.Handoff' does not export 'ForwardLifecycleCompletion'") :| ["Module 'HostBootstrap.Handoff' does not export 'LifecycleCompletion'"
        , "Module 'HostBootstrap.Handoff' does not export 'ReverseLifecycleCompletion'"])
    , rejectsWith
        "HandoffLifecycleProducers.hs"
        ("Module 'HostBootstrap.Handoff' does not export 'withAcknowledgedBoundReverseLifecycleCompletionKernel'" :| ["Module 'HostBootstrap.Handoff' does not export 'withAcknowledgedForwardLifecycleCompletionKernel'", "Module 'HostBootstrap.Handoff' does not export 'withRehydratedAcknowledgedReverseLifecycleCompletionKernel'"])
    , rejectsWith
        "HandoffLifecycleFold.hs"
        (("Module 'HostBootstrap.Handoff' does not export 'withLifecycleCompletionKernel'") :| [])
    , rejectsWith
        "HandoffFormerProtocolReexport.hs"
        ("Module 'HostBootstrap.Handoff' does not export 'BrokerLink'" :| ["Module 'HostBootstrap.Handoff' does not export 'ChildProtocolState'", "Module 'HostBootstrap.Handoff' does not export 'ProtocolError'", "Module 'HostBootstrap.Handoff' does not export 'ProtocolMessage'", "Module 'HostBootstrap.Handoff' does not export 'ProtocolTag'", "Module 'HostBootstrap.Handoff' does not export 'adoptLifecycleAcknowledgementThroughLink'", "Module 'HostBootstrap.Handoff' does not export 'prepareLifecycleAcknowledgementThroughLink'", "Module 'HostBootstrap.Handoff' does not export 'protocolMessage'"])
    , rejectsWith
        "HandoffFormerChannelProducers.hs"
        (("Module 'HostBootstrap.Handoff' does not export 'HandoffChannel'") :| ["Module 'HostBootstrap.Handoff' does not export 'channelReceive'"
        , "Module 'HostBootstrap.Handoff' does not export 'channelSend'"
        , "Module 'HostBootstrap.Handoff' does not export 'handoffChannel'"
        , "Module 'HostBootstrap.Handoff' does not export 'protocolMessageRequestId'"
        , "Module 'HostBootstrap.Handoff' does not export 'readProtocolMessage'"
        , "Module 'HostBootstrap.Handoff' does not export 'stdioHandoffChannel'"
        , "Module 'HostBootstrap.Handoff' does not export 'writeProtocolMessage'"])
    , rejectsWith
        "HandoffRecoverySigningCapability.hs"
        (("Module 'HostBootstrap.Handoff' does not export 'RecoverySigningKernel'") :| ["Module 'HostBootstrap.Handoff' does not export 'consumeRecoverySigningKernel'"
        , "Module 'HostBootstrap.Handoff' does not export 'recoverySigningKernel'"])
    , rejectsWith
        "CoerceHandoffRecoverySigningCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffSignRootedPayloadBindingCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffSignRecoveryChildPackageBindingCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffSignRootedLifecycleResponseCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffSignAuthenticatedRootScopeCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffRegisterRecoverableAdmittedEdgeCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffPublishLifecycleReportCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffReceiveLifecycleAcknowledgementCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffPrepareLifecycleAcknowledgementCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffAdoptLifecycleAcknowledgementCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "HandoffFormerReceiverSurface.hs"
        ("Module 'HostBootstrap.Handoff' does not export 'ReceivedEdge'" :| ["Module 'HostBootstrap.Handoff' does not export 'ReceivedRecoveryDescent'", "Module 'HostBootstrap.Handoff' does not export 'ReceiverError'", "Module 'HostBootstrap.Handoff' does not export 'mkReceivedEdge'", "Module 'HostBootstrap.Handoff' does not export 'mkReceivedRecoveryDescent'", "Module 'HostBootstrap.Handoff' does not export 'receivedEdgeChannel'", "Module 'HostBootstrap.Handoff' does not export 'receivedEdgeAuthenticatedRootScope'", "Module 'HostBootstrap.Handoff' does not export 'receivedEdgeHandoff'", "Module 'HostBootstrap.Handoff' does not export 'receivedEdgeRequestId'", "Module 'HostBootstrap.Handoff' does not export 'receiverErrorMessage'", "Module 'HostBootstrap.Handoff' does not export 'withReceivedHandoffEdge'", "Module 'HostBootstrap.Handoff' does not export 'withReceivedRecoveryDescent'"])
    , rejectsWith
        "ForgeVerifiedConfigWire.hs"
        (("Illegal term-level use of the type constructor 'VerifiedConfigWire'") :| [])
    , rejectsWith
        "CoerceVerifiedConfigWireRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'"
        , "Couldn't match type 'ConfigA' with 'ConfigB' arising from a use of 'coerce'"])
    , rejectsWith
        "EscapeVerifiedConfigWireIdentity.hs"
        (("Couldn't match type 'configDigest' with 'ChosenWireDigest'") :| ["Couldn't match type 'configId' with 'ChosenConfigIdentity'"])
    , rejectsWith
        "ForgeVerifiedConfigHandoff.hs"
        (("Illegal term-level use of the type constructor 'VerifiedConfigHandoff'") :| [])
    , rejectsWith
        "CoerceVerifiedConfigHandoffRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'ParentA' with 'ParentB' arising from a use of 'coerce'"
        , "Couldn't match type 'ChildA' with 'ChildB' arising from a use of 'coerce'"
        , "Couldn't match type 'ConfigA' with 'ConfigB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbA' with 'VerbB' arising from a use of 'coerce'"
        , "Couldn't match type 'PhaseA' with 'PhaseB' arising from a use of 'coerce'"])
    , rejectsWith
        "EscapeVerifiedConfigHandoffIndices.hs"
        (("Couldn't match type 'planDigest' with 'ChosenHandoffPlan'") :| ["Couldn't match type 'parentFrame' with 'ChosenHandoffParent'"
        , "Couldn't match type 'childFrame' with 'ChosenHandoffChild'"
        , "Couldn't match type 'phase' with 'ChosenHandoffPhase'"])
    , rejectsWith
        "ImportProjectPlanChildInternal.hs"
        (("Could not load module 'HostBootstrap.ProjectPlan.Child.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "OpenAuthenticatedChildCursorEvidence.hs"
        ("Module 'HostBootstrap.ProjectPlan.Construct' does not export 'mintChildPlanAuthorityKernel'" :| ["Module 'HostBootstrap.ProjectPlan.Construct' does not export 'childPlanAuthorityBindingKernel'"])
    , rejectsWith
        "ForgeChildPlanAuthority.hs"
        (("Illegal term-level use of the type constructor 'ChildPlanAuthority'") :| [])
    , rejectsWith
        "CoerceChildPlanAuthorityRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'"
        , "Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'"
        , "Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'ParentA' with 'ParentB' arising from a use of 'coerce'"
        , "Couldn't match type 'ChildA' with 'ChildB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ConfigA' with 'ConfigB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbA' with 'VerbB' arising from a use of 'coerce'"
        , "Couldn't match type 'PhaseA' with 'PhaseB' arising from a use of 'coerce'"])
    , rejectsWith
        "EscapeChildProjectPlanIdentity.hs"
        (("Couldn't match type 'planId' with 'ChosenPlan'") :| [])
    , rejectsWith
        "ForgeRecoveryProjectionInput.hs"
        (("Illegal term-level use of the type constructor 'RecoveryProjectionBindingInput'") :| [])
    , rejectsWith
        "CoerceRecoveryProjectionBindingInputRoles.hs"
        (("Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'") :| ["Couldn't match type 'ParentA' with 'ParentB' arising from a use of 'coerce'"
        , "Couldn't match type 'ChildA' with 'ChildB' arising from a use of 'coerce'"])
    , rejectsWith
        "EscapeRecoveryProjectionInput.hs"
        (("Couldn't match type 'planDigest' with 'CallerChosenRecoveryPlan'") :| ["Couldn't match type 'parentFrame' with 'CallerChosenRecoveryParent'"
        , "Couldn't match type 'childFrame' with 'CallerChosenRecoveryChild'"])
    , rejectsWith
        "ForgeRecoveryProjectionBinding.hs"
        (("Illegal term-level use of the type constructor 'RecoveryProjectionBinding'") :| [])
    , rejectsWith
        "CoerceRecoveryProjectionBindingRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbA' with 'VerbB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ParentA' with 'ParentB' arising from a use of 'coerce'"
        , "Couldn't match type 'ChildA' with 'ChildB' arising from a use of 'coerce'"
        , "Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'"])
    , rejectsWith
        "EscapeRecoveryProjectionWireDigest.hs"
        (("Couldn't match type 'recoveryWireDigest' with 'CallerChosenRecoveryWireDigest'") :| [])
    , rejectsWith
        "ForgeRecoveryWireGrant.hs"
        (("Illegal term-level use of the type constructor 'RecoveryWireGrant'") :| [])
    , rejectsWith
        "CoerceRecoveryWireGrantRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbA' with 'VerbB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ParentA' with 'ParentB' arising from a use of 'coerce'"
        , "Couldn't match type 'ChildA' with 'ChildB' arising from a use of 'coerce'"
        , "Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'"])
    , rejectsWith
        "ForgeVerifiedRecoveryWire.hs"
        (("Illegal term-level use of the type constructor 'VerifiedRecoveryWire'") :| [])
    , rejectsWith
        "CoerceVerifiedRecoveryWireRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbA' with 'VerbB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'"
        , "Couldn't match type 'WireA' with 'WireB' arising from a use of 'coerce'"])
    , rejectsWith
        "EscapeVerifiedRecoveryWireIdentity.hs"
        (("Couldn't match type 'recoveryWireId' with 'CallerChosenVerifiedRecoveryWire'") :| [])
    , rejectsWith
        "ForgeVerifiedRecoveryHandoff.hs"
        (("Illegal term-level use of the type constructor 'VerifiedRecoveryHandoff'") :| [])
    , rejectsWith
        "CoerceVerifiedRecoveryHandoffRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ParentA' with 'ParentB' arising from a use of 'coerce'"
        , "Couldn't match type 'ChildA' with 'ChildB' arising from a use of 'coerce'"
        , "Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'"
        , "Couldn't match type 'WireA' with 'WireB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbA' with 'VerbB' arising from a use of 'coerce'"])
    , rejectsWith
        "EscapeVerifiedRecoveryHandoffIdentity.hs"
        (("Couldn't match type 'recoveryWireId' with 'CallerChosenVerifiedRecoveryHandoff'") :| [])
    , rejectsWith
        "RecoveryProjectionWrongVerbJoin.hs"
        (("Couldn't match type 'VerbDestroy' with 'VerbDown'") :| [])
    , rejectsWith
        "RecoveryGrantWrongVerbJoin.hs"
        (("Couldn't match type 'VerbDestroy' with 'VerbDown'") :| [])
    , rejectsWith
        "ConfigGrantAsRecoveryGrant.hs"
        (("Couldn't match expected type: RecoveryWireGrant") :| [])
    , rejectsWith
        "HandoffGrantAsActivationGrant.hs"
        (("Couldn't match type 'HandoffGrant scope broker' with 'ActivationGrant'") :| [])
    , rejectsWith
        "RecoveryWireGrantAsActivationGrant.hs"
        (("Couldn't match type 'RecoveryWireGrant scope broker verb plan parent child digest' with 'ActivationGrant'") :| [])
    , rejectsWith
        "CrossScopeProjectRoot.hs"
        (("Couldn't match type 'ConfigScope' with 'ForeignScope' Expected: CanonicalProjectRoot ConfigScope rootId Actual: CanonicalProjectRoot ForeignScope rootId") :| [])
    , rejectsWith
        "RawCanonicalHostMount.hs"
        (("Couldn't match type: [Char] with: HostBootstrap.ProjectRoot.CanonicalHostPath") :| [])
    , rejectsWith
        "CrossRootCanonicalHostMount.hs"
        (("Couldn't match type 'RootB' with 'RootA'") :| [])
    , rejectsWith
        "SignHandoffWithoutRootStore.hs"
        ("Couldn't match expected type: HandoffGrant scope brokerGeneration with actual type: IO (Either HandoffError (HandoffGrant scope brokerGeneration))" :| [])
    , rejectsWith
        "CoerceProjectPermitScope.hs"
        ("Couldn't match type 'ScopeAlias' with 'Scope' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceProjectPermitPlan.hs"
        ("Couldn't match type 'PlanAlias' with 'Plan' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceClosingProjectPermitScope.hs"
        ("Couldn't match type 'ScopeAlias' with 'Scope' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceClosingProjectPermitPlan.hs"
        ("Couldn't match type 'PlanAlias' with 'Plan' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceClosedProjectPermitScope.hs"
        ("Couldn't match type 'ScopeAlias' with 'Scope' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceClosedProjectPermitPlan.hs"
        ("Couldn't match type 'PlanAlias' with 'Plan' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceOperationSessionScope.hs"
        ("Couldn't match type 'ScopeAlias' with 'Scope' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceOperationSessionPlan.hs"
        ("Couldn't match type 'PlanAlias' with 'Plan' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceOperationAdvanceScope.hs"
        ("Couldn't match type 'ScopeAlias' with 'Scope' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceOperationAdvancePlan.hs"
        ("Couldn't match type 'PlanAlias' with 'Plan' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "ForgeReleasedIntentOrigin.hs"
        ("an item called 'IntentOrigin' is exported, but it does not export any children (constructors, class methods or field names) called 'ReleasedReacquisition'" :| [])
    , rejectsWith
        "ForgeSessionPermit.hs"
        ("Illegal term-level use of the type constructor 'ProjectPermit'" :| [])
    , rejectsWith
        "ForgeOperationSession.hs"
        ("Illegal term-level use of the type constructor 'OperationSession'" :| [])
    , rejectsWith
        "ForgeSessionId.hs"
        ("Illegal term-level use of the type constructor 'SessionId'" :| [])
    , rejectsWith
        "CoerceFenceEpochScope.hs"
        ("Couldn't match type 'Scope' with 'ScopeAlias' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceFenceEpochPlan.hs"
        ("Couldn't match type 'Plan' with 'PlanAlias' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceOldPermitsFencedScope.hs"
        ("Couldn't match type 'Scope' with 'ScopeAlias' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceOldPermitsFencedPlan.hs"
        ("Couldn't match type 'Plan' with 'PlanAlias' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceVerifiedAllSessionsClosedScope.hs"
        ("Couldn't match type 'Scope' with 'ScopeAlias' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceVerifiedAllSessionsClosedPlan.hs"
        ("Couldn't match type 'Plan' with 'PlanAlias' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "ForgeFenceEpoch.hs"
        ("Illegal term-level use of the type constructor 'FenceEpoch'" :| [])
    , rejectsWith
        "ForgeOperationAdvance.hs"
        ("Illegal term-level use of the type constructor 'OperationAdvance'" :| [])
    , rejectsWith
        "ClosingPermitAsOpen.hs"
        (("Couldn't match expected type: ProjectPermit scope0 planId0 with actual type: ClosingProjectPermit scope planId") :| [])
    , rejectsWith
        "ForgeTransactionPermitFromDescriptor.hs"
        (("Could not load module 'HostBootstrap.Lifecycle.Session.Testing'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:lifecycle-transaction-internal'") :| [])
    , rejectsWith
        "ForgeBuildSigningKey.hs"
        (("Illegal term-level use of the type constructor 'BuildSigningKey'") :| [])
    , rejectsWith
        "ForgeBuildVerificationKey.hs"
        (("Illegal term-level use of the type constructor 'BuildVerificationKey'") :| [])
    , rejectsWith
        "ForgeBuildCoordinator.hs"
        (("Illegal term-level use of the type constructor 'BuildCoordinator'") :| [])
    , rejectsWith
        "ForgeBuildGrant.hs"
        (("Illegal term-level use of the type constructor 'BuildGrant'") :| [])
    , rejectsWith
        "ForgeImageBuildFrame.hs"
        (("Illegal term-level use of the type constructor 'ImageBuildFrame'") :| [])
    , rejectsWith
        "ForgeBuildInvocationAuthority.hs"
        (("Illegal term-level use of the type constructor 'BuildInvocationAuthority'") :| [])
    , rejectsWith
        "ForgeBuildCommandAuthority.hs"
        (("Illegal term-level use of the type constructor 'BuildCommandAuthority'") :| [])
    , rejectsWith
        "EscapeProvisionedBuildCoordinator.hs"
        (("Couldn't match type 'coordinatorId' with 'ChosenCoordinator'") :| [])
    , rejectsWith
        "EscapeVerifiedBuildInvocation.hs"
        (("Couldn't match type 'project' with 'ChosenBuildProject'") :| ["Couldn't match type 'spec' with 'ChosenBuildSpec'"
        , "Couldn't match type 'config' with 'ChosenBuildConfig'"
        , "Couldn't match type 'frame' with 'ChosenBuildFrame'"
        , "Couldn't match type 'build' with 'ChosenBuildIdentity'"
        , "Couldn't match type 'source' with 'ChosenBuildSource'"
        , "Couldn't match type 'builder' with 'ChosenBuildBuilder'"])
    , rejectsWith
        "BuildCoordinatorCannotExportVerificationKey.hs"
        ("Module 'HostBootstrap.Build' does not export 'coordinatorSigningKey'" :| [])
    , rejectsWith
        "BuildSigningKeyAsVerificationKey.hs"
        (("Couldn't match type 'BuildSigningKey' with 'BuildVerificationKey'") :| [])
    , rejectsWith
        "ProjectVerificationKeyAsBuildVerificationKey.hs"
        (("Couldn't match type 'ProjectVerificationKey' with 'BuildVerificationKey'") :| [])
    , rejectsWith
        "CoerceBuildCoordinatorIdentity.hs"
        (("Couldn't match type 'CoordinatorA' with 'CoordinatorB' arising from a use of 'coerce'") :| [])
    , rejectsWith
        "CoerceImageBuildFrameRoles.hs"
        (("Couldn't match type 'ProjectA' with 'ProjectB' arising from a use of 'coerce'") :| ["Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'"
        , "Couldn't match type 'ConfigA' with 'ConfigB' arising from a use of 'coerce'"
        , "Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"])
    , rejectsWith
        "CoerceBuildInvocationAuthorityRoles.hs"
        (("Couldn't match type 'ProjectA' with 'ProjectB' arising from a use of 'coerce'") :| ["Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'"
        , "Couldn't match type 'ConfigA' with 'ConfigB' arising from a use of 'coerce'"
        , "Couldn't match type 'BuildA' with 'BuildB' arising from a use of 'coerce'"
        , "Couldn't match type 'SourceA' with 'SourceB' arising from a use of 'coerce'"
        , "Couldn't match type 'BuilderA' with 'BuilderB' arising from a use of 'coerce'"])
    , rejectsWith
        "CoerceBuildCommandAuthorityRoles.hs"
        (("Couldn't match type 'ProjectA' with 'ProjectB' arising from a use of 'coerce'") :| ["Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'"
        , "Couldn't match type 'ConfigA' with 'ConfigB' arising from a use of 'coerce'"])
    , rejectsWith
        "ForgeActivationSigningKey.hs"
        (("Illegal term-level use of the type constructor 'ActivationSigningKey'") :| [])
    , rejectsWith
        "ForgeActivationVerificationKey.hs"
        (("Illegal term-level use of the type constructor 'ActivationVerificationKey'") :| [])
    , rejectsWith
        "ForgeActivationSigningPolicy.hs"
        (("Illegal term-level use of the type constructor 'ActivationSigningPolicy'") :| [])
    , rejectsWith
        "ForgeActivationBroker.hs"
        (("Illegal term-level use of the type constructor 'ActivationBroker'") :| [])
    , rejectsWith
        "ForgeVerifiedRuntimeRoleActivation.hs"
        (("Illegal term-level use of the type constructor 'VerifiedRuntimeRoleActivation'") :| [])
    , rejectsWith
        "ForgeActivationSecretDigest.hs"
        (("Illegal term-level use of the type constructor 'ActivationSecretDigest'") :| [])
    , rejectsWith
        "ReadActivationBrokerVerificationKey.hs"
        ("Module 'HostBootstrap.Activation' does not export 'brokerPublic'" :| [])
    , rejectsWith
        "ActivationSigningKeyAsVerificationKey.hs"
        (("Couldn't match type 'ActivationSigningKey' with 'ActivationVerificationKey'") :| [])
    , rejectsWith
        "ProjectVerificationKeyAsActivationVerificationKey.hs"
        (("Couldn't match type 'ProjectVerificationKey' with 'ActivationVerificationKey'") :| [])
    , rejectsWith
        "BuildVerificationKeyAsActivationVerificationKey.hs"
        (("Couldn't match type 'BuildVerificationKey' with 'ActivationVerificationKey'") :| [])
    , rejectsWith
        "CoerceActivationBrokerRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'BrokerA' with 'BrokerB' arising from a use of 'coerce'"
        , "Couldn't match type 'VerbA' with 'VerbB' arising from a use of 'coerce'"])
    , rejectsWith
        "CoerceVerifiedRuntimeRoleActivationRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'SpecA' with 'SpecB' arising from a use of 'coerce'"
        , "Couldn't match type 'BinaryA' with 'BinaryB' arising from a use of 'coerce'"
        , "Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'RevisionA' with 'RevisionB' arising from a use of 'coerce'"
        , "Couldn't match type 'InstanceA' with 'InstanceB' arising from a use of 'coerce'"])
    , rejectsWith
        "EscapeVerifiedRuntimeRoleActivationFrame.hs"
        (("Couldn't match type 'scope' with 'CallerActivationScope'") :| ["Couldn't match type 'planDigest' with 'CallerActivationPlan'"
        , "Couldn't match type 'specDigest' with 'CallerActivationSpec'"
        , "Couldn't match type 'binaryDigest' with 'CallerActivationBinary'"
        , "Couldn't match type 'frame' with 'CallerActivationFrame'"
        , "Couldn't match type 'revision' with 'CallerActivationRevision'"
        , "Couldn't match type 'instanceId' with 'CallerActivationInstance'"])
    , rejectsWith
        "ForgeReservedRoleAdmission.hs"
        (("Illegal term-level use of the type constructor 'ReservedRoleAdmission'") :| [])
    , rejectsWith
        "CoerceReservedRoleAdmissionRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'RevisionA' with 'RevisionB' arising from a use of 'coerce'"
        , "Couldn't match type 'InstanceA' with 'InstanceB' arising from a use of 'coerce'"])
    , rejectsWith
        "ForgeVerifiedRolePlanDraft.hs"
        (("Illegal term-level use of the type constructor 'VerifiedRolePlanDraft'") :| [])
    , rejectsWith
        "CoerceVerifiedRolePlanDraftRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'FrameA' with 'FrameB' arising from a use of 'coerce'"
        , "Couldn't match type 'RevisionA' with 'RevisionB' arising from a use of 'coerce'"
        , "Couldn't match type 'InstanceA' with 'InstanceB' arising from a use of 'coerce'"
        , "Couldn't match type 'DigestA' with 'DigestB' arising from a use of 'coerce'"])
    , rejectsWith
        "ForgeRoleCursor.hs"
        (("Illegal term-level use of the type constructor 'RoleCursor'") :| ["Illegal term-level use of the type constructor 'RolePlan'"
        , "Illegal term-level use of the type constructor 'VerifiedServicePlacement'"
        , "Illegal term-level use of the type constructor 'VerifiedNoRoleResources'"
        , "Illegal term-level use of the type constructor 'ReadyRoleHandles'"
        , "Illegal term-level use of the type constructor 'RolePlanDigestBinding'"])
    , rejectsWith
        "CoerceRoleLifecycleAuthorityRoles.hs"
        ("Couldn't match type 'CursorScopeA' with 'CursorScopeB' arising from a use of 'coerce'" :| ["Couldn't match type 'CursorPlanA' with 'CursorPlanB' arising from a use of 'coerce'", "Couldn't match type 'CursorFrameA' with 'CursorFrameB' arising from a use of 'coerce'", "Couldn't match type 'CursorInstanceA' with 'CursorInstanceB' arising from a use of 'coerce'", "Couldn't match type 'CursorPhaseA' with 'CursorPhaseB' arising from a use of 'coerce'", "Couldn't match type 'PlanScopeA' with 'PlanScopeB' arising from a use of 'coerce'", "Couldn't match type 'PlanSpecA' with 'PlanSpecB' arising from a use of 'coerce'", "Couldn't match type 'PlanIdentityA' with 'PlanIdentityB' arising from a use of 'coerce'", "Couldn't match type 'PlanConfigA' with 'PlanConfigB' arising from a use of 'coerce'", "Couldn't match type 'PlanSecretA' with 'PlanSecretB' arising from a use of 'coerce'", "Couldn't match type 'PlanFrameA' with 'PlanFrameB' arising from a use of 'coerce'", "Couldn't match type 'PlanRevisionA' with 'PlanRevisionB' arising from a use of 'coerce'", "Couldn't match type 'PlanInstanceA' with 'PlanInstanceB' arising from a use of 'coerce'", "Couldn't match type 'BindingScopeA' with 'BindingScopeB' arising from a use of 'coerce'", "Couldn't match type 'BindingSpecA' with 'BindingSpecB' arising from a use of 'coerce'", "Couldn't match type 'BindingPlanDigestA' with 'BindingPlanDigestB' arising from a use of 'coerce'", "Couldn't match type 'BindingRoleDigestA' with 'BindingRoleDigestB' arising from a use of 'coerce'", "Couldn't match type 'BindingPlanA' with 'BindingPlanB' arising from a use of 'coerce'", "Couldn't match type 'PlacementScopeA' with 'PlacementScopeB' arising from a use of 'coerce'", "Couldn't match type 'PlacementSpecA' with 'PlacementSpecB' arising from a use of 'coerce'", "Couldn't match type 'PlacementPlanA' with 'PlacementPlanB' arising from a use of 'coerce'", "Couldn't match type 'PlacementFrameA' with 'PlacementFrameB' arising from a use of 'coerce'", "Couldn't match type 'PlacementRevisionA' with 'PlacementRevisionB' arising from a use of 'coerce'", "Couldn't match type 'PlacementInstanceA' with 'PlacementInstanceB' arising from a use of 'coerce'", "Couldn't match type 'PlacementServiceA' with 'PlacementServiceB' arising from a use of 'coerce'", "Couldn't match type 'PlacementEffectsA' with 'PlacementEffectsB' arising from a use of 'coerce'", "Couldn't match type 'AuthorizationScopeA' with 'AuthorizationScopeB' arising from a use of 'coerce'", "Couldn't match type 'AuthorizationSpecA' with 'AuthorizationSpecB' arising from a use of 'coerce'", "Couldn't match type 'AuthorizationPlanA' with 'AuthorizationPlanB' arising from a use of 'coerce'", "Couldn't match type 'AuthorizationFrameA' with 'AuthorizationFrameB' arising from a use of 'coerce'", "Couldn't match type 'AuthorizationRevisionA' with 'AuthorizationRevisionB' arising from a use of 'coerce'", "Couldn't match type 'AuthorizationInstanceA' with 'AuthorizationInstanceB' arising from a use of 'coerce'", "Couldn't match type 'AuthorizationServiceA' with 'AuthorizationServiceB' arising from a use of 'coerce'", "Couldn't match type 'authorizationEffectsA' with 'authorizationEffectsB' arising from a use of 'coerce'"])
    , rejectsWith
        "ForgeTeardownForest.hs"
        (("Couldn't match type 'VerbDown' with 'VerbDestroy'") :| ["Illegal term-level use of the type constructor 'TeardownForest'"
        , "Illegal term-level use of the type constructor 'DestroySettled'"])
    , rejectsWith
        "ForgePreconditionSet.hs"
        (("Illegal term-level use of the type constructor 'OperationPreconditionSet'") :| [])
    , rejectsWith
        "ForgePreparedGate.hs"
        ("an item called 'PreparedGate' is exported, but it does not export any children (constructors, class methods or field names) called 'PreparedGate'" :| [])
    , rejectsWith
        "RecordUpdatePreparedGatePlan.hs"
        ("Not in scope: record field 'preparedGatePlan'" :| [])
    , rejectsWith
        "RecordUpdatePreparedGateOperation.hs"
        ("Not in scope: record field 'preparedGateOperation'" :| [])
    , rejectsWith
        "RecordUpdatePreparedGateSession.hs"
        ("Not in scope: record field 'preparedGateSession'" :| [])
    , rejectsWith
        "RecordUpdatePreparedGateFence.hs"
        ("Not in scope: record field 'preparedGateFence'" :| [])
    , rejectsWith
        "RecordUpdatePreparedGateAttempt.hs"
        ("Not in scope: record field 'preparedGateAttempt'" :| [])
    , rejectsWith
        "RecordUpdatePreparedGateJournalVersion.hs"
        ("Not in scope: record field 'preparedGateJournalVersion'" :| [])
    , -- A role performs only the effects its declared row names. 'HasEffect'
      -- has no empty-row equation, so the diagnostic names the effect the
      -- row lacks rather than reporting a generic mismatch.
      rejectsWith
        "UndeclaredServiceEffect.hs"
        (("Could not solve: \8216HasEffect DurableStore '[]\8217") :| [])
    , rejectsWith
        "IOServiceHandler.hs"
        (("Couldn't match expected type: HostBootstrap.Service.Program.ServiceProgram Payload service '[] () with actual type: IO ()") :| [])
    , rejectsWith
        "ForgeStepExecution.hs"
        (("Illegal term-level use of the type constructor 'StepExecution'") :| ["Data constructor not in scope: ExecutionNode"])
    , rejectsWith
        "CoerceExecutionRoles.hs"
        (("Couldn't match type 'ExecutionScopeA' with 'ExecutionScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'ExecutionPlanA' with 'ExecutionPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'RuntimeScopeA' with 'RuntimeScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'RuntimePlanA' with 'RuntimePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'CarrierScopeA' with 'CarrierScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'CarrierPlanA' with 'CarrierPlanB' arising from a use of 'coerce'"])
    , rejectsWith
        "CoerceResourceHandleRoles.hs"
        (("Couldn't match type 'HandleScopeA' with 'HandleScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'HandlePlanA' with 'HandlePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'HandleIdentityA' with 'HandleIdentityB' arising from a use of 'coerce'"
        , "Couldn't match type 'HandleResourceA' with 'HandleResourceB' arising from a use of 'coerce'"
        , "Couldn't match type 'HandleOwnershipA' with 'HandleOwnershipB' arising from a use of 'coerce'"
        , "Couldn't match type 'HandlePhaseA' with 'HandlePhaseB' arising from a use of 'coerce'"])
    , rejectsWith
        "CoerceReconcilePlanRoles.hs"
        (("Couldn't match type 'LifecyclePlanA' with 'LifecyclePlanB' arising from a use of 'coerce'") :| ["Couldn't match type 'ReceiptPlanA' with 'ReceiptPlanB' arising from a use of 'coerce'"
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
        , "Couldn't match type 'AdvancePlanA' with 'AdvancePlanB' arising from a use of 'coerce'"])
    , rejectsWith
        "CoerceReconcileEvidenceRoles.hs"
        (("Couldn't match type 'LifecycleScopeA' with 'LifecycleScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'LifecyclePlanA' with 'LifecyclePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ReceiptIdentityA' with 'ReceiptIdentityB' arising from a use of 'coerce'"
        , "Couldn't match type 'ReceiptResourceA' with 'ReceiptResourceB' arising from a use of 'coerce'"
        , "Couldn't match type 'DescriptorFromA' with 'DescriptorFromB' arising from a use of 'coerce'"
        , "Couldn't match type 'DescriptorToA' with 'DescriptorToB' arising from a use of 'coerce'"
        , "Couldn't match type 'TransitionFromA' with 'TransitionFromB' arising from a use of 'coerce'"
        , "Couldn't match type 'TransitionToA' with 'TransitionToB' arising from a use of 'coerce'"
        , "Couldn't match type 'ResultPhaseA' with 'ResultPhaseB' arising from a use of 'coerce'"])
    , rejectsWith
        "CoerceReconcileSemanticRoles.hs"
        (("Couldn't match type 'ForeignOriginA' with 'ForeignOriginB' arising from a use of 'coerce'") :| ["Couldn't match type 'AdoptionOriginA' with 'AdoptionOriginB' arising from a use of 'coerce'"
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
        , "Couldn't match type 'AdvancePhaseA' with 'AdvancePhaseB' arising from a use of 'coerce'"])
    , rejectsWith
        "MismatchPreparedPairRoles.hs"
        (("Couldn't match type 'PairOperationB' with 'PairOperationA'") :| ["Couldn't match type 'PairAttemptB' with 'PairAttemptA'"])
    , rejectsWith
        "ForgeDetachedLaunch.hs"
        (("Illegal term-level use of the type constructor 'DetachedLaunch'") :| ["Illegal term-level use of the type constructor 'DetachedChild'"
        , "Illegal term-level use of the type constructor 'DetachedWorkingDirectory'"
        , "Illegal term-level use of the type constructor 'DetachedOutputSink'"
        , "Variable not in scope: detachedProcess :: DetachedLaunch -> CreateProcess"])
    , rejectsWith
        "RelabelDetachedLaunch.hs"
        (("Not in scope: record field 'dlArguments'") :| [])
    , rejectsWith
        "RelabelAbsExe.hs"
        (("Not in scope: record field 'absExePath'") :| [])
    , rejectsWith
        "EscapeDetachedChild.hs"
        (("Couldn't match type 'child' with 'escaped'") :| [])
    , rejectsWith
        "CoerceDetachedChildRole.hs"
        (("Couldn't match type 'ChildA' with 'ChildB'") :| [])
    , rejectsWith
        "CoerceDetachedIORole.hs"
        (("Couldn't match type 'ChildA' with 'ChildB'") :| [])
    , rejectsWith
        "EscapeCanonicalProjectRoot.hs"
        (("Couldn't match type 'rootId' with 'escapedRoot'") :| [])
    , rejectsWith
        "ForgeCanonicalProjectRoot.hs"
        (("Illegal term-level use of the type constructor 'CanonicalProjectRoot'") :| [])
    , rejectsWith
        "CoerceCanonicalProjectRootScope.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB'") :| [])
    , rejectsWith
        "CoerceCanonicalHostPathScope.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB'") :| [])
    , rejectsWith
        "CoerceCanonicalProjectRootId.hs"
        (("Couldn't match type 'RootA' with 'RootB'") :| [])
    , rejectsWith
        "CoerceCanonicalHostPathRootId.hs"
        (("Couldn't match type 'RootA' with 'RootB'") :| [])
    ]

fixtureInventoryCases :: [TestTree]
fixtureInventoryCases =
    [ testCase "every fixture is registered exactly once" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            let directory = packageRoot </> "test" </> "compile-fail"
            files <- map (SourceGuard.repoRelativePath directory) <$> SourceGuard.listHaskellSources directory
            registrationProblems files (compileFailCases (\name _ -> name) <> privateCompileFailCases (\name _ -> name)) @?= []
    , testCase "every first-party import probes live library definitions" $
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ -> do
            description <- SourceGuard.readPackageDescription
            sources <- SourceGuard.readLibrarySources packageRoot description
            definitions <- traverse (definitionNames packageRoot) sources
            let names = Set.fromList (concat definitions)
                modules = Set.fromList [name | (name, _, _) <- sources]
                directory = packageRoot </> "test" </> "compile-fail"
            fixtures <- SourceGuard.readHaskellSources directory
            problems <- traverse (importProblems directory modules names) fixtures
            concat problems @?= []
    , testCase "registration inventory admits only the exact file set" $
        registrationProblems ["One.hs", "Two.hs"] ["Two.hs", "One.hs"] @?= []
    , testCase "registration inventory reports duplicates, missing and unregistered files" $
        registrationProblems ["One.hs", "Two.hs"] ["One.hs", "One.hs", "Ghost.hs"]
            @?= ["duplicate registration: One.hs", "registered file missing: Ghost.hs", "unregistered file: Two.hs"]
    ]
        <> importInventoryCases
        <> definitionInventoryCases
  where
    definitionNames packageRoot (name, path, source) =
        either (assertFailure . ((name <> " (" <> SourceGuard.repoRelativePath packageRoot path <> "): ") <>)) pure
            (SourceGuard.haskellDefinitionNames source)
    importProblems directory modules names (path, source) = do
        imports <- either (assertFailure . ((SourceGuard.repoRelativePath directory path <> ": ") <>)) pure
            (SourceGuard.firstPartyImportItems source)
        pure
            [ SourceGuard.repoRelativePath directory path <> ": " <> imported <> ": " <> problem
            | (imported, items) <- imports
            , problem <- ["module has no library source" | imported `Set.notMember` modules]
                <> ["identifier has no library definition: " <> name | name <- items, name `Set.notMember` names]
            ]

registrationProblems :: [FilePath] -> [FilePath] -> [String]
registrationProblems files registered =
    ["duplicate registration: " <> name | name : rest <- group (sort registered), not (null rest)]
        <> ["registered file missing: " <> name | name <- Set.toList (registeredSet Set.\\ fileSet)]
        <> ["unregistered file: " <> name | name <- Set.toList (fileSet Set.\\ registeredSet)]
  where
    fileSet = Set.fromList files
    registeredSet = Set.fromList registered

importInventoryCases :: [TestTree]
importInventoryCases =
    [ testCase "plain import items preserve parent and child identifiers" $
        SourceGuard.firstPartyImportItems
            "import HostBootstrap.One (f, T, Parent (Child, field), Other (..))"
            @?= Right [("HostBootstrap.One", ["f", "T", "Parent", "Child", "field", "Other"])]
    , testCase "multiline imports and trailing commas preserve every item" $
        SourceGuard.firstPartyImportItems
            "import HostBootstrap.One (\nf,\nParent (Child, field,),\n)\nimport HostBootstrap.Two"
            @?= Right [("HostBootstrap.One", ["f", "Parent", "Child", "field"]), ("HostBootstrap.Two", [])]
    , testCase "external prefixes, comments and literals do not manufacture first-party imports" $
        SourceGuard.firstPartyImportItems (unlines
            [ "import qualified Data.Text as Text"
            , "import HostBootstrapper.Fake (Ghost)"
            , "-- import HostBootstrap.Fake (Ghost)"
            , "{- nested {- import HostBootstrap.Fake (Ghost) -} comment -}"
            , "text = \"import HostBootstrap.Fake (Ghost)\""
            ]) @?= Right []
    ]
        <> [ testCase ("unsupported first-party import " <> label) $
                assertLeft (SourceGuard.firstPartyImportItems source)
           | (label, source) <-
                [ ("qualified", "import qualified HostBootstrap.One (T)")
                , ("postpositive qualified", "import HostBootstrap.One qualified (T)")
                , ("alias", "import HostBootstrap.One as One")
                , ("hiding", "import HostBootstrap.One hiding (T)")
                , ("package", "import \"hostbootstrap-core\" HostBootstrap.One (T)")
                , ("source pragma", "import {-# SOURCE #-} HostBootstrap.One (T)")
                , ("operator", "import HostBootstrap.One ((+))")
                , ("type namespace", "import HostBootstrap.One (type T)")
                , ("pattern namespace", "import HostBootstrap.One (pattern P)")
                , ("empty middle item", "import HostBootstrap.One (T,,f)")
                , ("nested child", "import HostBootstrap.One (T(Child(..)))")
                , ("unbalanced", "import HostBootstrap.One (T(Child)")
                , ("CPP import header", "import\n#ifdef PICK_A\n HostBootstrap.One (f)\n#endif")
                ]
           ]

definitionInventoryCases :: [TestTree]
definitionInventoryCases =
    [ testCase ("definition positions: " <> label) $
        SourceGuard.haskellDefinitionNames source @?= Right (sort expected)
    | (label, source, expected) <-
        [ ("empty and existential data", "data Empty\ndata Wrapped a = forall hidden. Wrap hidden | Other a", ["Empty", "Wrapped", "Wrap", "Other"])
        , ("newtype and record labels", "newtype New = New { first, second :: Proxy (Ghost :: Type), third :: Int }", ["New", "first", "second", "third"])
        , ("GADT constructors and record labels", "data G where\n  First, Second :: Proxy (Ghost :: Type) -> G\n  Record :: { field :: Proxy (Ghost :: Type) } -> G", ["G", "First", "Second", "Record", "field"])
        , ("type alias and closed family", "type Alias a = Ghost a\ntype family Family a where\n  Family (Ghost a) = Other a", ["Alias", "Family"])
        , ("class methods and associated types", "class Class a where\n  type Associated a\n  first, second :: Proxy (Ghost :: Type) -> a\n  first value = local value\n    where\n      local value = value", ["Class", "Associated", "first", "second"])
        , ("foreign Haskell binder", "foreign import capi unsafe \"header.h Ghost\"\n  c_actual :: Proxy (Ghost :: Type) -> IO ()", ["c_actual"])
        , ("prefix equations and guarded patterns", "actual (Ghost left :*: right) input@(Other value)\n  | left == right = value\n  | otherwise = input\nactual _ _ = missing", ["actual"])
        , ("both CPP branches", "#if FLAG\nfirst = True\n#else\nsecond = False\n#endif", ["first", "second"])
        , ("CPP macro continuation", "#define UNUSED \\\ndata Ghost = Phantom\nactual = ()", ["actual"])
        , ("signatures and role annotations alone", "missing :: Ghost\ntype role Phantom nominal", [])
        , ("module imports and exports", "module Fixture (Ghost)\nwhere\nimport HostBootstrap.Ghost (Ghost)", [])
        , ("comments and strings", "{- data Ghost = Ghost -}\n-- ghost = Ghost\ntext = \"data Ghost = Ghost\"", ["text"])
        , ("function patterns", "actual (Ghost value) = value", ["actual"])
        , ("case patterns", "actual value = case value of\n  Ghost inner -> inner", ["actual"])
        , ("lambda patterns", "actual = \\(Ghost value) -> value", ["actual"])
        , ("view patterns", "actual (view -> Ghost value) = value", ["actual"])
        , ("shadowed pure pattern", "pure (Left (Ghost reason)) = reason", ["pure"])
        , ("local definitions", "actual = local\n  where\n    local = Ghost", ["actual"])
        , ("instance methods are not fresh definitions", "instance Class Ghost where\n  absent value = value", [])
        ]
    ]
        <> [ testCase ("unsupported definition shape: " <> label) $
                assertLeft (SourceGuard.haskellDefinitionNames source)
           | (label, source) <-
                [ ("symbolic infix operands", "left <+> right = left")
                , ("backticked infix operands", "left `combine` right = left")
                , ("operator binding", "(<+>) left right = left")
                , ("pattern synonym", "pattern Ghost value = Actual value")
                , ("pattern binding", "(left, right) = pair")
                , ("infix constructor", "data Pair a b = a :*: b")
                , ("splice", "$(makeGhost)")
                , ("unbalanced declaration", "data T = T { field :: Int")
                , ("class context", "class Eq a => Class a where\n  method :: a -> a")
                , ("constructor context", "data T = forall a. Eq a => Exists a")
                , ("inline class body", "class Class a where method :: a -> a")
                , ("inline GADT body", "data G where Constructor :: G")
                ]
           ]

assertLeft :: Show result => Either String result -> IO ()
assertLeft (Left _) = pure ()
assertLeft result = assertFailure ("unsupported syntax was accepted: " <> show result)

diagnosticMatcherCases :: [TestTree]
diagnosticMatcherCases =
    [ testCase "wrapped text and typographic quotes preserve the diagnostic" $
        matchDiagnosticPhrases ("Couldn't match type 'A' with 'B'" :| [])
            (diagnostic "Fixture.hs:1:2" "Couldn't match type \8216A\8217\n    with \8216B\8217") @?= Right ()
    , testCase "phrases cannot cross diagnostic boundaries" $
        assertBool "a split phrase matched separate errors" $
            isLeft (matchDiagnosticPhrases ("alpha beta" :| []) (diagnostic "A.hs:1:2" "alpha" <> diagnostic "A.hs:2:2" "beta"))
    , testCase "two phrases cannot consume the same diagnostic" $
        assertBool "one error satisfied two expectations" $
            isLeft (matchDiagnosticPhrases ("alpha" :| ["beta"]) (diagnostic "A.hs:1:2" "alpha beta"))
    , testCase "assignment backtracks instead of choosing greedily" $
        matchDiagnosticPhrases ("alpha" :| ["beta", "gamma"])
            (diagnostic "A.hs:1:2" "alpha beta gamma" <> diagnostic "A.hs:2:2" "alpha" <> diagnostic "A.hs:3:2" "beta gamma") @?= Right ()
    , testCase "blank phrases refuse before matching" $
        matchDiagnosticPhrases (" \n\t" :| ["alpha"]) (diagnostic "A.hs:1:2" "alpha")
            @?= Left "an expected diagnostic phrase is blank"
    , testCase "a warning cannot satisfy a rejection expectation" $
        assertBool "a warning counted as a rejection" $
            isLeft (matchDiagnosticPhrases ("wanted" :| []) "A.hs:1:2: warning: wanted\nA.hs:2:2: error: unrelated\n")
    , testCase "preamble and source paths cannot satisfy a phrase" $
        assertBool "header text counted as a rejection" $
            isLeft (matchDiagnosticPhrases ("wanted" :| []) ("wanted\n" <> diagnostic "wanted.hs:1:2" "unrelated"))
    , testCase "unrecognized header shapes fail closed" $
        assertBool "an arbitrary marker was accepted as a compiler header" $
            isLeft (matchDiagnosticPhrases ("wanted" :| []) "unrelated: error: wanted\n")
    ]
        <> [testCase ("diagnostic location " <> location) $
                matchDiagnosticPhrases ("wanted" :| []) (diagnostic location "wanted") @?= Right ()
           | location <- ["A.hs:1:2", "A.hs:1:2-8", "A.hs:1:2-3:8", "A.hs:(1,2)-(3,8)", "C:\\work dir\\A.hs:1:2", "C:\\work dir\\A.hs:(1,2)-(3,8)", "<no location info>"]]
  where
    diagnostic location body = location <> ": error: [GHC-00000]\n    " <> body <> "\n"
    isLeft (Left _) = True
    isLeft _ = False

-- Split before normalization: a phrase must belong to one error diagnostic,
-- and every phrase must have its own block. Candidate assignment backtracks.
matchDiagnosticPhrases :: NonEmpty String -> String -> Either String ()
matchDiagnosticPhrases expected stderr
    | any null phrases = Left "an expected diagnostic phrase is blank"
    | null blocks = Left "the compiler produced no recognized error diagnostic"
    | assign candidates [] = Right ()
    | otherwise = Left ("no distinct diagnostic-block assignment; candidates " <> show candidates)
  where
    phrases = map normalizeDiagnostic (NonEmpty.toList expected)
    blocks = map normalizeDiagnostic (errorDiagnosticBlocks stderr)
    candidates = [[index | (index, block) <- zip [0 :: Int ..] blocks, phrase `isInfixOf` block] | phrase <- phrases]
    assign [] _used = True
    assign (choices : remaining) used = any try choices
      where
        try index = index `notElem` used && assign remaining (index : used)

errorDiagnosticBlocks :: String -> [String]
errorDiagnosticBlocks = go Nothing [] . lines
  where
    go current completed [] = reverse (finish current completed)
    go current completed (line : remaining) = case diagnosticHeader line of
        Just (isError, body) -> go (Just (isError, [body])) (finish current completed) remaining
        Nothing -> go (fmap (\(isError, body) -> (isError, line : body)) current) completed remaining
    finish (Just (True, body)) completed = unlines (reverse body) : completed
    finish _ completed = completed

diagnosticHeader :: String -> Maybe (Bool, String)
diagnosticHeader [] = Nothing
diagnosticHeader line@(first : _)
    | isSpace first = Nothing
    | otherwise = listToMaybe
        [(isError, body)
        | (marker, isError) <- [(": error:", True), (": warning:", False)]
        , Just (location, body) <- [splitMarker marker line]
        , validLocation location]
  where
    validLocation location = location `elem` ["<no location info>", "<command line>", "ghc"]
        || any validSpan (colonSuffixes location)
    colonSuffixes [] = []
    colonSuffixes (':' : remaining) = remaining : colonSuffixes remaining
    colonSuffixes (_ : remaining) = colonSuffixes remaining
    validSpan spanText = numeric spanText || tuple spanText
    digits input = let (number, rest) = span isDigit input in if null number then Nothing else Just rest
    numeric input = case digits input of
        Just [] -> True
        Just (':' : column) -> case digits column of
            Just [] -> True
            Just ('-' : end) -> case digits end of
                Just [] -> True
                Just (':' : endColumn) -> digits endColumn == Just []
                _ -> False
            _ -> False
        _ -> False
    tuple input = doTuple input == Just ""
    doTuple input = do
        start <- stripPrefix "(" input
        column <- digits start >>= stripPrefix ","
        end <- digits column >>= stripPrefix ")-("
        endColumn <- digits end >>= stripPrefix ","
        digits endColumn >>= stripPrefix ")"

splitMarker :: String -> String -> Maybe (String, String)
splitMarker marker = search []
  where
    search reversed source
        | Just rest <- stripPrefix marker source = Just (reverse reversed, rest)
    search reversed (character : remaining) = search (character : reversed) remaining
    search _ [] = Nothing

data PublicCompiler = PublicCompiler FilePath [String]

operationAdvancePayloadControl :: IO PublicCompiler -> TestTree
operationAdvancePayloadControl getCompiler =
    testCase "OperationAdvance permits a newtype coercion of its result payload" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-operation-advance-payload" $ \directory -> do
            let path = directory </> "OperationAdvancePayloadControl.hs"
                source = unlines
                    [ "{-# LANGUAGE EmptyDataDecls #-}"
                    , "module OperationAdvancePayloadControl where"
                    , "import Data.Coerce (coerce)"
                    , "import HostBootstrap.Lifecycle.Session (OperationAdvance)"
                    , "data Scope"
                    , "data Plan"
                    , "newtype Payload = Payload Int"
                    , "unwrap :: OperationAdvance Scope Plan Payload -> OperationAdvance Scope Plan Int"
                    , "unwrap = coerce"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("valid result-payload coercion failed:\n" ++ output ++ diagnostic)

transactionDataVocabularyControl :: IO PublicCompiler -> TestTree
transactionDataVocabularyControl getCompiler =
    testCase "the testing unit compiles the existing descriptor DATA fixture" $ do
        (code, output, diagnostic) <- compileFixtureUsing getCompiler "ForgeTransactionPermitFromDescriptor.hs"
        case code of
            ExitSuccess -> pure ()
            ExitFailure _ -> assertFailure ("the testing unit rejected its descriptor DATA vocabulary:\n" ++ output ++ diagnostic)

compileFixtureUsing :: IO PublicCompiler -> FilePath -> IO (ExitCode, String, String)
compileFixtureUsing getCompiler fixture = do
    PublicCompiler compiler compilerArgs <- getCompiler
    cwd <- getCurrentDirectory
    root <- findRepoRoot cwd >>= maybe (assertFailure ("could not locate repo root from " ++ cwd)) pure
    let coreRoot = root </> "core"
        fixturePath = "hostbootstrap-core" </> "test" </> "compile-fail" </> fixture
    withCurrentDirectory coreRoot $
        readProcessWithExitCode compiler (compilerArgs ++ [fixturePath]) ""

rejectsWithUsing :: IO PublicCompiler -> FilePath -> NonEmpty String -> TestTree
rejectsWithUsing getCompiler fixture expectedDiagnostics =
    testCase fixture $ do
        (code, _, err) <- compileFixtureUsing getCompiler fixture
        case code of
            ExitFailure _ -> do
                assertBool
                    ("compile-fail fixture produced no diagnostic: " ++ fixture)
                    (not (null err))
                case matchDiagnosticPhrases expectedDiagnostics err of
                    Right () -> pure ()
                    Left reason -> assertFailure
                        ( "compile-fail fixture produced the wrong diagnostic: " ++ fixture
                            ++ "; " ++ reason ++ "; expected " ++ show (NonEmpty.toList expectedDiagnostics)
                            ++ " in:\n" ++ err
                        )
            _ -> assertFailure ("compile-fail fixture unexpectedly compiled: " ++ fixture)

{- | Resolve the pinned compiler and explicit package databases once. Each
fixture context selects one local unit using the same base arguments.

The test component also depends on the Cabal-private Harness lifecycle
sublibrary so HarnessSpec can exercise the engine. A nested @cabal exec ghc@
therefore sees privileged component packages and is not a downstream consumer:
it can import that constructor module, and Cabal may select either local library
for @-package hostbootstrap-core@. We instead ask Cabal for the pinned compiler
and store paths, expose the main in-place unit explicitly, and leave the private
sublibrary hidden. Public compile-fail fixtures now run in the same package
visibility shape a real consumer receives.

The private DATA/runner control selects the testing unit instead of the main
unit; it never exposes both local units to the same compiler invocation.
-}
data CompilerPaths = CompilerPaths FilePath FilePath [String]

resolveCompilerPaths :: IO CompilerPaths
resolveCompilerPaths = do
    cwd <- getCurrentDirectory
    root <- findRepoRoot cwd >>= maybe (fail ("could not locate repo root from " ++ cwd)) pure
    let coreRoot = root </> "core"
    cabalExecutable <-
        findExecutable "cabal"
            >>= maybe (fail "could not resolve cabal while resolving the fixture compiler") pure
    (pathCode, pathOutput, pathError) <-
        withCurrentDirectory coreRoot $
            readProcessWithExitCode cabalExecutable ["path"] ""
    case pathCode of
        ExitSuccess -> pure ()
        ExitFailure _ ->
            fail ("cabal path failed while resolving the fixture compiler:\n" ++ pathError)
    compiler <- requiredCabalPathField "compiler-path" pathOutput
    compilerId <- requiredCabalPathField "compiler-id" pathOutput
    compilerStore <- requiredCabalPathField "compiler-store-path" pathOutput
    let localPackageDb = coreRoot </> "dist-newstyle" </> "packagedb" </> compilerId
        storePackageDb = compilerStore </> "package.db"
    pure
        ( CompilerPaths
            compiler
            localPackageDb
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
            ]
        )

resolvePublicCompiler :: CompilerPaths -> IO PublicCompiler
resolvePublicCompiler paths@(CompilerPaths _ localPackageDb _) = do
    mainConf <-
        uniqueRegistration localPackageDb "main hostbootstrap-core" $ \name ->
            "hostbootstrap-core-" `isPrefixOf` name && "-inplace.conf" `isSuffixOf` name
    registration <- readFile (localPackageDb </> mainConf)
    mainUnit <-
        case listToMaybe
            [ unitId
            | line <- lines registration
            , "id:" : unitId : _ <- [words line]
            ] of
            Just unitId -> pure unitId
            Nothing -> fail ("main package registration has no unit id: " ++ mainConf)
    pure (compilerForUnit paths mainUnit)

resolveTestingCompiler :: CompilerPaths -> IO PublicCompiler
resolveTestingCompiler paths@(CompilerPaths _ localPackageDb _) = do
    testingConf <-
        uniqueRegistration localPackageDb "lifecycle-transaction-internal" $ \name ->
            "hostbootstrap-core-" `isPrefixOf` name
                && "-inplace-lifecycle-transaction-internal.conf" `isSuffixOf` name
    registration <- readFile (localPackageDb </> testingConf)
    testingUnit <- case SourceGuard.fieldValues "id" registration of
        [unitId] -> pure unitId
        observed ->
            fail ("expected exactly one testing-unit id in " ++ testingConf ++ ", observed " ++ show observed)
    pure (compilerForUnit paths testingUnit)

uniqueRegistration :: FilePath -> String -> (FilePath -> Bool) -> IO FilePath
uniqueRegistration localPackageDb label matches = do
    packageConfs <- listDirectory localPackageDb
    case filter matches packageConfs of
        [name] -> pure name
        observed ->
            fail
                ( "expected exactly one " ++ label ++ " package registration in "
                    ++ localPackageDb ++ ", observed " ++ show observed
                )

compilerForUnit :: CompilerPaths -> String -> PublicCompiler
compilerForUnit (CompilerPaths compiler _ baseArguments) unitId =
    PublicCompiler compiler
        (baseArguments ++ ["-package-id", unitId, "-fno-code", "-fno-diagnostics-show-caret"])

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
