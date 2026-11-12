{-# LANGUAGE OverloadedStrings #-}

module CompileFailSpec (tests, assertNativeLinkNoReplacePreservesDestination, withPrivateBudgetKernel) where

import Control.Exception (onException)
import Control.Monad (forM, forM_, unless)
import qualified Data.Aeson as Aeson
import Data.Aeson ((.:), (.:?), (.!=))
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString as ByteString
import Data.Char (isAlphaNum, isDigit, isSpace, isUpper, toUpper)
import Data.List (group, isInfixOf, isPrefixOf, isSuffixOf, sort, stripPrefix)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (listToMaybe)
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HostBootstrap.DocValidator (findRepoRoot)
import qualified ProviderBackendSpec
import qualified SourceGuard
import System.Directory (
    canonicalizePath,
    copyFile,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    findExecutable,
    getCurrentDirectory,
    getModificationTime,
    listDirectory,
    removeDirectoryRecursive,
    getTemporaryDirectory,
    withCurrentDirectory,
 )
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (equalFilePath, pathSeparator, takeBaseName, takeDirectory, takeFileName, (<.>), (</>))
import System.IO.Temp (createTempDirectory, withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import qualified System.Process as Process
import Test.Tasty (TestTree, testGroup, withResource)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
    withResource resolveCompilerPaths (const (pure ())) $ \getPaths ->
        withResource (getPaths >>= resolvePublicCompiler) (const (pure ())) $ \getCompiler ->
            testGroup
                "public compile-fail boundaries"
                ( [ testGroup "diagnostic matcher" diagnosticMatcherCases
                  , testGroup "fixture inventory" fixtureInventoryCases
                  , operationAdvancePayloadControl getCompiler
                  , verifiedConfigHandoffPairControl getCompiler
                  , sameBrokerGenerationGrantControl getCompiler
                  , recoveryProjectionGetterControl getCompiler
                  , activationManifestPublicControl getCompiler
                  , measuredInstancePublicControl getCompiler
                  , selectedActivationManifestPublicControl getCompiler
                  , receivedActivationManifestPublicControl getCompiler
                  , buildProjectNamePublicControl getCompiler
                  , buildSpecDigestPublicControl getCompiler
                  , buildConfigDigestPublicControl getCompiler
                  , buildIdentifierPublicControl getCompiler
                  , buildSourceDigestPublicControl getCompiler
                  , coordinatorDigestPublicControl getCompiler
                  , builderDigestPublicControl getCompiler
                  , buildFrameNamePublicControl getCompiler
                  , buildSourceRootPublicControl getCompiler
                  , builderPathPublicControl getCompiler
                  , wallReservationPublicControl getCompiler
                  , storedOriginPublicControl getCompiler
                  , directoryLeasePublicControl getCompiler
                  , withResource (getPaths >>= resolveTestingCompiler) (const (pure ())) $ \getTestingCompiler ->
                        testGroup
                            "private transaction testing unit"
                            ( transactionDataVocabularyControl getTestingCompiler
                                : privateCompileFailCases (rejectsWithUsing getTestingCompiler)
                            )
                  , withResource (getPaths >>= resolveRepresentationCompiler) (const (pure ())) $ \getRepresentationCompiler ->
                        testGroup
                            "private lifecycle representation unit"
                            ( [ executionCoreVocabularyControl getRepresentationCompiler
                              , runtimeCoreVocabularyControl getRepresentationCompiler
                              ]
                                <> representationCompileFailCases (rejectsWithUsing getRepresentationCompiler)
                            )
                  , withResource (getPaths >>= resolveOwnershipCompiler) (const (pure ())) $ \getOwnershipCompiler ->
                        testGroup "private ownership unit" (ownershipCompileFailCases (rejectsWithUsing getOwnershipCompiler))
                  , withResource (getPaths >>= resolveHandoffTestCompiler) (const (pure ())) handoffTestContextCases
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

ownershipCompileFailCases :: (FilePath -> NonEmpty String -> result) -> [result]
ownershipCompileFailCases rejectsWith =
    [ rejectsWith "UpdateOwnershipManifestEntry.hs" ("Not in scope: record field 'manifestEntryPath'" :| [])
    ]

-- These role controls expose the actual private production unit, never main.
representationCompileFailCases :: (FilePath -> NonEmpty String -> result) -> [result]
representationCompileFailCases rejectsWith =
    [ rejectsWith
        "CoerceResourceCarrierCoreRoles.hs"
        ( "Couldn't match type 'CoreScopeA' with 'CoreScopeB' arising from a use of 'coerce'"
            :| [ "Couldn't match type 'CorePlanA' with 'CorePlanB' arising from a use of 'coerce'"
               , "Couldn't match type 'CorePayloadA' with 'CorePayloadB' arising from a use of 'coerce'"
               ]
        )
    , rejectsWith
        "CoerceStepRuntimeCoreRoles.hs"
        ( "Couldn't match type 'RuntimeCoreScopeA' with 'RuntimeCoreScopeB' arising from a use of 'coerce'"
            :| [ "Couldn't match type 'RuntimeCorePlanA' with 'RuntimeCorePlanB' arising from a use of 'coerce'"
               , "Couldn't match type 'RuntimeCoreGateA' with 'RuntimeCoreGateB' arising from a use of 'coerce'"
               , "Couldn't match type 'RuntimeCorePayloadA' with 'RuntimeCorePayloadB' arising from a use of 'coerce'"
               ]
        )
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
        "ImportProtectedPublication.hs"
        ("Could not load module 'HostBootstrap.Protected.Publication'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:ownership-internal'" :| [])
    , rejectsWith
        "ImportClusterOwnership.hs"
        ("Could not load module 'HostBootstrap.Cluster.Ownership'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:cluster-ownership-internal'" :| [])
    , rejectsWith
        "ForgeWallReceiptAndAuthority.hs"
        ("Illegal term-level use of the type constructor 'WallReceipt'"
            :| ["Illegal term-level use of the type constructor 'WallAuthority'"])
    , rejectsWith
        "ImportRawHostWallLocation.hs"
        ( "Module 'HostBootstrap.Wsl2.GlobalWall.Host' does not export 'openHostWallLocation'"
            :| [ "Module 'HostBootstrap.Wsl2.GlobalWall.Host' does not export 'hostWallProtectedStore'"
               , "Module 'HostBootstrap.Wsl2.GlobalWall.Host' does not export 'hostWallActiveRecordKey'"
               ]
        )
    , rejectsWith
        "CrossWallReservationAuthority.hs"
        ("Couldn't match type 'reservationId1' with 'reservationId'" :| [])
    , rejectsWith
        "EscapeWallReservation.hs"
        ("Couldn't match type 'reservationId' with 'Outside'" :| [])
    , rejectsWith
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
        "CoerceProbeReadiness.hs"
        ("Couldn't match type 'ClusterApiReady' with 'GpuPluginReady'" :| [])
    , rejectsWith
        "ReportedOriginAsDirectory.hs"
        ("Couldn't match expected type 'HostBootstrap.Ownership.Object.OwnerClaim' with actual type 'ObjectKind'" :| [])
    , rejectsWith
        "ImportRawDependencyProbe.hs"
        ("Module 'HostBootstrap.Reconcile' does not export 'dependencyProbe'" :| [])
    , rejectsWith
        "RawCallbackAsShareDependency.hs"
        ("Couldn't match type" :| [])
    , rejectsWith
        "ImportLifecycleDependencyInternal.hs"
        ("Could not load module 'HostBootstrap.Lifecycle.Dependency.Internal'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:lifecycle-dependency-internal'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
    , rejectsWith
        "ImportLifecycleSnapshotCore.hs"
        ("Could not load module 'HostBootstrap.Lifecycle.Snapshot.Core'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:lifecycle-representation-internal'" :| [])
    , rejectsWith
        "ImportLifecycleExecutionCore.hs"
        ("Could not load module 'HostBootstrap.Lifecycle.Execution.Core'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:lifecycle-representation-internal'" :| [])
    , rejectsWith
        "ImportResourceCarrierAllocator.hs"
        ("Module 'HostBootstrap.Lifecycle.Execution' does not export 'newResourceCarrier'" :| [])
    , rejectsWith
        "ImportLifecycleRuntimeCore.hs"
        ("Could not load module 'HostBootstrap.Lifecycle.Execution.Core'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:lifecycle-representation-internal'" :| [])
    , rejectsWith
        "ImportStepRuntimeAllocator.hs"
        ("Module 'HostBootstrap.Lifecycle.Execution' does not export 'newStepRuntime'" :| [])
    , rejectsWith
        "AssembleStepExecutionWithPublicRuntime.hs"
        ("Module 'HostBootstrap.Lifecycle.Execution' does not export 'newStepRuntime'" :| [])
    , rejectsWith
        "ImportReconcilePlanProducer.hs"
        ("Not in scope: 'HostBootstrap.Reconcile.withLifecyclePlan' Note: The module 'HostBootstrap.Reconcile' does not export 'withLifecyclePlan'." :| [])
    , rejectsWith
        "ImportPlannedStepRefusalObservation.hs"
        ("Not in scope: 'HostBootstrap.ProjectPlan.plannedStepRefusalObservation' Note: The module 'HostBootstrap.ProjectPlan' does not export 'plannedStepRefusalObservation'." :| [])
    , rejectsWith
        "ImportVerifyPhaseTransition.hs"
        ("The module 'HostBootstrap.Reconcile' does not export 'verifyPhaseTransition'." :| [])
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
        "EscapeOwnedObjectIndex.hs"
        ("Couldn't match type 'object' with 'escaped'" :| [])
    , rejectsWith
        "EscapeReportedObjectIndex.hs"
        ("Couldn't match type 'object' with 'escaped'" :| [])
    , rejectsWith
        "EscapeReenteredOwnershipEntry.hs"
        (("Couldn't match type 'session' with 'escaped'") :| [])
    , rejectsWith
        "ReenterInMemoryOwnershipRecord.hs"
        ("Couldn't match expected type 'StoredOriginRecord session' with actual type 'HostBootstrap.Ownership.Object.OriginRecord'" :| [])
    , rejectsWith
        "ReenterInMemoryReportedRecord.hs"
        ("Couldn't match expected type 'StoredOriginRecord session' with actual type 'HostBootstrap.Ownership.Object.OriginRecord'" :| [])
    , rejectsWith
        "EscapeStoredOwnershipRecord.hs"
        ("Couldn't match type 'session' with 'other'" :| [])
    , rejectsWith
        "ConstructShippedDirectoryLease.hs"
        ("Illegal term-level use of the type constructor 'ShippedDirectoryLease'" :| [])
    , rejectsWith
        "UpdateShippedDirectoryLease.hs"
        ("Not in scope: record field 'directoryLeaseRow'" :| [])
    , rejectsWith
        "CoerceShippedDirectoryLease.hs"
        ("Couldn't match type 'First' with 'Second' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "EscapeShippedDirectoryLease.hs"
        ("Couldn't match type 'lease' with 'escaped'" :| [])
    , rejectsWith
        "CoerceStoredOwnershipRecord.hs"
        ("Couldn't match type 'First' with 'Second' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "UpdateStoredOwnershipRecord.hs"
        ("Not in scope: record field 'storedOriginRecord'" :| [])
    , rejectsWith
        "UpdateStoredOwnershipVersion.hs"
        ("Not in scope: record field 'storedRecordVersion'" :| [])
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
        ("Could not load module 'HostBootstrap.ProjectPlan.Construct.Internal'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
    , rejectsWith
        "ImportProjectPlanHandoffInternal.hs"
        (("Could not load module 'HostBootstrap.ProjectPlan.Handoff.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "ImportProjectPlanProjectionInternal.hs"
        ("Could not load module 'HostBootstrap.ProjectPlan.Projection.Internal'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
    , rejectsWith
        "ImportLifecycleRootedPlan.hs"
        ("Could not load module 'HostBootstrap.Lifecycle.RootedPlan'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
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
        ("Could not load module 'HostBootstrap.Lifecycle.Context.Internal'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
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
        "CrossPlanConfigStepExecution.hs"
        (("Couldn't match type 'PlanB' with 'PlanA'") :| ["Couldn't match type 'ConfigurationB' with 'ConfigurationA'"])
    , rejectsWith
        "RawStepAsExecutionSource.hs"
        (("Couldn't match expected type 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Lifecycle.Plan.PlannedStep Scope Plan ConfigurationIdentity (Configuration Scope)' with actual type 'Step'") :| [])
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
        ("Couldn't match type: hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Lifecycle.Plan.ProjectPlan scope0 specDigest0 planId0 configId0 cfg0 with: TeardownPlan Scope Plan Frame VerbDestroy" :| [])
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
        ("Could not load module 'HostBootstrap.Teardown.Internal'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
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
        "CoerceValidatedContextRoles.hs"
        ( "Couldn't match type 'ContextScopeA' with 'ContextScopeB' arising from a use of 'coerce'"
            :| [ "Couldn't match type 'ContextPlanA' with 'ContextPlanB' arising from a use of 'coerce'"
               , "Couldn't match type 'ContextFrameA' with 'ContextFrameB' arising from a use of 'coerce'"
               ]
        )
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
        "ReplaceHarnessPreconditionProbe.hs"
        (("Not in scope: record field 'harnessPreconditionProbe'") :| [])
    , rejectsWith
        "PassRawAdmissionToResumedReverseRoot.hs"
        ("Couldn't match expected type 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Lifecycle.Plan.ExistingBoundSnapshotAdmission' with actual type '()'" :| [])
    , rejectsWith
        "PassRawAdmissionToFreshReverseRoot.hs"
        ("Couldn't match expected type 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Lifecycle.Plan.ExistingBoundSnapshotAdmission' with actual type '()'" :| [])
    , rejectsWith
        "PassRawAdmissionToReauthorizedBoundSnapshot.hs"
        ("Couldn't match expected type 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Lifecycle.Plan.ExistingBoundSnapshotAdmission' with actual type '()'" :| [])
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
        ("Could not load module 'HostBootstrap.Config.Schema.Internal'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
    , rejectsWith
        "ImportConfigClassInternal.hs"
        ("Could not load module 'HostBootstrap.Config.Class.Internal'. it is a hidden module in the package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'" :| [])
    , rejectsWith
        "ImportServiceInternal.hs"
        ("Could not load module 'HostBootstrap.Service.Internal'. it is a hidden module in the package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'" :| [])
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
        ("Couldn't match expected type: hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Lifecycle.Plan.ProjectPlan scope0 specDigest0 planId0 configId0 cfg0 with actual type: ProviderWallSpec scope planId budgetId provider capabilityId wallSpecId" :| [])
    , rejectsWith
        "CrossPartitionProviderWallReservation.hs"
        (("Couldn't match type 'partitionA' with 'partitionB'") :| [])
    , rejectsWith
        "ForgeProviderWallReservation.hs"
        ("Illegal term-level use of the type constructor 'ProviderWallReservation'" :| [])
    , rejectsWith
        "CoerceProviderWallReservationRoles.hs"
        ( "Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
            :| ["Couldn't match type 'FenceA' with 'FenceB' arising from a use of 'coerce'"]
        )
    , rejectsWith
        "ImportBudgetInternal.hs"
        (("Could not load module 'HostBootstrap.Cluster.Budget.Internal'. it is a hidden module") :| [])
    , rejectsWith
        "ImportColimaSettlementInternal.hs"
        (("Could not load module 'HostBootstrap.Ensure.Colima.Settlement.Internal'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:colima-ownership-internal'") :| [])
    , rejectsWith
        "ImportWallObservation.hs"
        (("Could not load module 'HostBootstrap.Cluster.Budget.Observation'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:wall-observation-internal'") :| [])
    , rejectsWith
        "ImportReconcileError.hs"
        (("Could not load module 'HostBootstrap.Reconcile.Error'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:reconcile-error-internal'") :| [])
    , rejectsWith
        "ImportColimaIdentity.hs"
        (("Could not load module 'HostBootstrap.Ensure.Colima.Backend.Identity'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:colima-backend-internal'") :| [])
    , rejectsWith
        "ImportColimaNames.hs"
        (("Could not load module 'HostBootstrap.Ensure.Colima.Backend.Names'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:colima-backend-internal'") :| [])
    , rejectsWith
        "ImportColimaObservation.hs"
        (("Could not load module 'HostBootstrap.Ensure.Colima.Observation'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:colima-ownership-internal'") :| [])
    , rejectsWith
        "RawStorageWallObservation.hs"
        (("Data constructor not in scope: StorageWallApplied") :| [])
    , rejectsWith
        "ForgeColimaStartArguments.hs"
        (("Illegal term-level use of the type constructor 'ColimaStartArguments'") :| [])
    , rejectsWith
        "ForgeDockerContext.hs"
        (("Illegal term-level use of the type constructor 'DockerContextName'") :| [])
    , rejectsWith
        "ImportColimaCommand.hs"
        (("Illegal term-level use of the type constructor 'ColimaProfile'") :| [])
    , rejectsWith
        "ImportColimaOwnership.hs"
        (("Could not load module 'HostBootstrap.Ensure.Colima.Ownership'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:colima-ownership-internal'") :| [])
    , rejectsWith
        "ImportColimaBackendRunner.hs"
        (("Could not load module 'HostBootstrap.Ensure.Colima.Backend.Runner'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:colima-backend-internal'") :| [])
    , rejectsWith
        "ImportColimaResolverTesting.hs"
        (("Could not load module 'HostBootstrap.Ensure.Colima.Backend.Resolver.Testing'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:colima-backend-internal'") :| [])
    , rejectsWith
        "ImportColimaResolverInstall.hs"
        (("Could not load module 'HostBootstrap.Ensure.Colima.Backend.Resolver.Install'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:colima-backend-internal'") :| [])
    , rejectsWith
        "ReboundHandleChoosesPhase.hs"
        (("Couldn't match type 'Provisioned' with 'Running'") :| [])
    , rejectsWith
        "ProjectManagedPhaseWithoutAuthority.hs"
        (("Couldn't match expected type 'hostbootstrap-core-0.1.0.0:provider-start-internal:HostBootstrap.Reconcile.ProviderStart.Internal.FreshManagedPhaseAuthority' with actual type '()'") :| [])
    , rejectsWith
        "ImportProviderStartInternal.hs"
        (("Could not load module 'HostBootstrap.Reconcile.ProviderStart.Internal'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:provider-start-internal'") :| [])
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
        "RawPlanAsClusterReconcileSource.hs"
        ( "Couldn't match expected type: PlanOwnedClusterConfig scope specDigest0 planId configId0 cfg0 clusterId0 clusterFrame0 providerId providerFrame0 budgetId0 provider0 capabilityId0 wallSpecId0 workloadSetId0 partitionId0 with actual type: ProjectPlan scope specDigest planId configId cfg"
            :| [ "Couldn't match expected type: RunningProviderDependency scope planId providerId with actual type: DependencySnapshot scope planId"
               ]
        )
    , rejectsWith
        "CallerForgedClusterProbe.hs"
        ("Expected: hostbootstrap-core-0.1.0.0:HostBootstrap.Substrate.Provider.Dependency.Internal.RunningProviderDependency scope planId providerId Actual: DependencyProbe scope planId providerId ProviderResource" :| [])
    , rejectsWith
        "ProvisionedProviderClusterDependency.hs"
        (("Couldn't match type 'Provisioned' with 'HostBootstrap.Reconcile.Running'") :| [])
    , rejectsWith
        "ImportRecoveredClusterReadiness.hs"
        ("Module 'HostBootstrap.Cluster.Reconcile' does not export 'withRecoveredClusterReadiness'" :| [])
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
        ("Could not load module 'HostBootstrap.Cluster.Exposure.Internal'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:cluster-exposure-internal'." :| [])
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
        "CoerceResolvedExposureRoles.hs"
        (("Couldn't match type 'ResolvedScopeA' with 'ResolvedScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'ResolvedPlanA' with 'ResolvedPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ResolvedClusterA' with 'ResolvedClusterB' arising from a use of 'coerce'"
        , "Couldn't match type 'ResolvedServiceA' with 'ResolvedServiceB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedScopeA' with 'PreparedScopeB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedPlanA' with 'PreparedPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedClusterA' with 'PreparedClusterB' arising from a use of 'coerce'"
        , "Couldn't match type 'PreparedFrameA' with 'PreparedFrameB' arising from a use of 'coerce'"])
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
        ("Couldn't match expected type: ghc-internal-9.1204.0:GHC.Internal.Base.NonEmpty (hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Lifecycle.Plan.PlanDraft (Production Project) NewSpecDigest (Config (Production Project))) with actual type: [a0]" :| [])
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
        "ConstructProviderProbeRequest.hs"
        (("Illegal term-level use of the type constructor 'ProviderProbeRequest'") :| [])
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
        (("Expected: DependencyProbe scope planId shareId DurableShareResource readiness0 Actual: ObservedReady DurableShareReady") :| [])
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
        "CarryCreatedRestartedProvider.hs"
        (("Couldn't match type 'Stopped' with 'Provisioned'") :| [])
    , rejectsWith
        "ForgeProviderPhaseAdvance.hs"
        (("Illegal term-level use of the type constructor 'ProviderPhaseAdvance'") :| [])
    , rejectsWith
        "CoerceProviderPhaseAdvanceRoles.hs"
        (("Couldn't match type 'ScopeA' with 'ScopeB' arising from a use of 'coerce'") :| ["Couldn't match type 'PlanA' with 'PlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'BackendA' with 'BackendB' arising from a use of 'coerce'"
        , "Couldn't match type 'ProviderA' with 'ProviderB' arising from a use of 'coerce'"
        , "Couldn't match type 'SourcePhaseA' with 'SourcePhaseB' arising from a use of 'coerce'"
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
        ("Could not load module 'HostBootstrap.Lifecycle.Plan'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
    , rejectsWith
        "CoerceAcquisitionJournalAdmission.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Lifecycle.Plan.AcquisitionJournalAdmission' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "ForgeAcquisitionJournalAdmission.hs"
        ("Module 'HostBootstrap.Lifecycle.Session' does not export 'AcquisitionJournalAdmission'" :| [])
    , rejectsWith
        "ForgeExistingBoundSnapshotAdmission.hs"
        ("Module 'HostBootstrap.Lifecycle.Mode' does not export 'ExistingBoundSnapshotAdmission'" :| [])
    , rejectsWith
        "PassRawAdmissionToReverseRootTargetCursor.hs"
        ("Couldn't match expected type 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Lifecycle.Plan.AcquisitionJournalAdmission' with actual type '()'" :| [])
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
        "UpdateHandoffBindingField.hs"
        ("Not in scope: record field 'handoffChildFrame'" :| [])
    , rejectsWith
        "RelabelHandoffBindingGeneration.hs"
        ("Not in scope: record field 'handoffPhase'" :| [])
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
        "CrossBrokerGenerationGrant.hs"
        ("Couldn't match type 'brokerGenerationB' with 'brokerGenerationA' Expected: HandoffOffer scope brokerGenerationA Actual: HandoffOffer scope brokerGenerationB" :| [])
    , rejectsWith
        "CrossScopeAuthenticatedConfig.hs"
        (("Couldn't match type: Harness projectId runId with: Production projectId") :| [])
    , rejectsWith
        "ImportHandoffReceiver.hs"
        ("Could not load module 'HostBootstrap.Handoff.Receiver'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
    , rejectsWith
        "ImportHandoffReceiverInternal.hs"
        ("Could not load module 'HostBootstrap.Handoff.Receiver.Internal'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
    , rejectsWith
        "ImportHandoffInternal.hs"
        ("Could not load module 'HostBootstrap.Handoff.Internal'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
    , rejectsWith
        "ImportHandoffProtocol.hs"
        ("Could not load module 'HostBootstrap.Handoff.Protocol'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
    , rejectsWith
        "ImportHandoffRooted.hs"
        ("Could not load module 'HostBootstrap.Handoff.Rooted'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
    , rejectsWith
        "ImportHandoffRecovery.hs"
        ("Could not load module 'HostBootstrap.Handoff.Recovery'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
    , rejectsWith
        "OpenRecoveryChildPackageDecoder.hs"
        ("Module 'HostBootstrap.Handoff' does not export 'recoveryChildPackageFromWireKernel'" :| [])
    , rejectsWith
        "EscapeAuthenticatedRootScopeRun.hs"
        (("Couldn't match type 'runId' with 'CallerChosenRun'") :| [])
    , rejectsWith
        "ImportHandoffRelay.hs"
        ("Could not load module 'HostBootstrap.Handoff.Relay'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
    , rejectsWith
        "ImportHandoffRuntime.hs"
        ("Could not load module 'HostBootstrap.Handoff.Runtime'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
    , rejectsWith
        "ImportLifecycleRooted.hs"
        ("Could not load module 'HostBootstrap.Lifecycle.Rooted'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
    , rejectsWith
        "ImportLifecycleRootedReceipt.hs"
        ("Could not load module 'HostBootstrap.Lifecycle.Rooted.Receipt'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'." :| [])
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
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffSignRootedPayloadBindingCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffSignRecoveryChildPackageBindingCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffSignRootedLifecycleResponseCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffSignAuthenticatedRootScopeCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffRegisterRecoverableAdmittedEdgeCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffPublishLifecycleReportCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffReceiveLifecycleAcknowledgementCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffPrepareLifecycleAcknowledgementCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "CoerceHandoffAdoptLifecycleAcknowledgementCapability.hs"
        ("Couldn't match representation of type '()' with that of 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Handoff.Internal.RecoverySigningKernel' arising from a use of 'coerce'" :| [])
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
        "CrossVerifiedConfigHandoffPair.hs"
        ("Couldn't match type 'configIdB' with 'configIdA' Expected: ValidatedConfig scope specDigest configIdA config Actual: ValidatedConfig scope specDigest configIdB config" :| [])
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
        "UpdateRecoveryProjectionInputField.hs"
        ("Not in scope: record field 'requestedRecoveryPlanDigest'" :| [])
    , rejectsWith
        "UpdateRecoveryProjectionParentField.hs"
        ("Not in scope: record field 'requestedRecoveryParentFrame'" :| [])
    , rejectsWith
        "UpdateRecoveryProjectionChildField.hs"
        ("Not in scope: record field 'requestedRecoveryChildFrame'" :| [])
    , rejectsWith
        "RetagRecoveryProjectionInput.hs"
        ("Not in scope: record field 'requestedRecoveryPlanDigest'" :| [])
    , rejectsWith
        "RetagRecoveryProjectionParentInput.hs"
        ("Not in scope: record field 'requestedRecoveryParentFrame'" :| [])
    , rejectsWith
        "RetagRecoveryProjectionChildInput.hs"
        ("Not in scope: record field 'requestedRecoveryChildFrame'" :| [])
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
        "FenceEpochFromOtherPermit.hs"
        ("Couldn't match type 'PlanA' with 'PlanB' Expected: ProjectPermit Scope PlanB Actual: ProjectPermit Scope PlanA" :| [])
    , rejectsWith
        "CrossFenceEpochPreparedSession.hs"
        ("Couldn't match type 'PlanA' with 'PlanB' Expected: FenceEpoch Scope PlanB Actual: FenceEpoch Scope PlanA" :| [])
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
        "ConstructActivationManifest.hs"
        ("Illegal term-level use of the type constructor 'ActivationManifest'" :| [])
    , rejectsWith
        "UpdateActivationManifest.hs"
        ("Not in scope: record field 'manifestRevision'" :| [])
    , rejectsWith
        "ConstructKubernetesInstance.hs"
        ("an item called 'MeasuredInstance' is exported, but it does not export any children (constructors, class methods or field names) called 'KubernetesInstance'." :| [])
    , rejectsWith
        "ConstructHostServiceInstance.hs"
        ("an item called 'MeasuredInstance' is exported, but it does not export any children (constructors, class methods or field names) called 'HostServiceInstance'." :| [])
    , rejectsWith
        "RawManifestAsSelectedActivation.hs"
        ("Couldn't match expected type 'HostBootstrap.Activation.SelectedActivationManifest' with actual type 'ActivationManifest'" :| [])
    , rejectsWith
        "ConstructSelectedActivationManifest.hs"
        ("Illegal term-level use of the type constructor 'SelectedActivationManifest'" :| [])
    , rejectsWith
        "CoerceSelectedActivationManifest.hs"
        ("Couldn't match representation of type 'ActivationManifest' with that of 'SelectedActivationManifest' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "RawManifestAsReceivedActivation.hs"
        ("Couldn't match expected type 'HostBootstrap.Activation.ReceivedActivationManifest' with actual type 'ActivationManifest'" :| [])
    , rejectsWith
        "ConstructReceivedActivationManifest.hs"
        ("Illegal term-level use of the type constructor 'ReceivedActivationManifest'" :| [])
    , rejectsWith
        "CoerceReceivedActivationManifest.hs"
        ("Couldn't match representation of type 'ActivationManifest' with that of 'ReceivedActivationManifest' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "SwapActivationManifests.hs"
        ("Couldn't match expected type 'SelectedActivationManifest' with actual type 'ReceivedActivationManifest'" :| ["Couldn't match expected type 'ReceivedActivationManifest' with actual type 'SelectedActivationManifest'"])
    , rejectsWith
        "RawTextAsBuildProjectName.hs"
        ("Couldn't match expected type 'HostBootstrap.Build.BuildProjectName' with actual type 'Text'" :| [])
    , rejectsWith
        "ConstructBuildProjectName.hs"
        ("Illegal term-level use of the type constructor 'BuildProjectName'" :| [])
    , rejectsWith
        "CoerceBuildProjectName.hs"
        ("Couldn't match representation of type 'Text' with that of 'BuildProjectName' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "RawTextAsBuildSpecDigest.hs"
        ("Couldn't match expected type 'HostBootstrap.Build.BuildSpecDigest' with actual type 'Text'" :| [])
    , rejectsWith
        "ConstructBuildSpecDigest.hs"
        ("Illegal term-level use of the type constructor 'BuildSpecDigest'" :| [])
    , rejectsWith
        "CoerceBuildSpecDigest.hs"
        ("Couldn't match representation of type 'Text' with that of 'BuildSpecDigest' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "RawTextAsBuildConfigDigest.hs"
        ("Couldn't match expected type 'HostBootstrap.Build.BuildConfigDigest' with actual type 'Text'" :| [])
    , rejectsWith
        "ConstructBuildConfigDigest.hs"
        ("Illegal term-level use of the type constructor 'BuildConfigDigest'" :| [])
    , rejectsWith
        "CoerceBuildConfigDigest.hs"
        ("Couldn't match representation of type 'Text' with that of 'BuildConfigDigest' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "RawTextAsBuildIdentifier.hs"
        ("Couldn't match expected type 'HostBootstrap.Build.BuildIdentifier' with actual type 'Text'" :| [])
    , rejectsWith
        "ConstructBuildIdentifier.hs"
        ("Illegal term-level use of the type constructor 'BuildIdentifier'" :| [])
    , rejectsWith
        "CoerceBuildIdentifier.hs"
        ("Couldn't match representation of type 'Text' with that of 'BuildIdentifier' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "RawTextAsBuildSourceDigest.hs"
        ("Couldn't match expected type 'HostBootstrap.Build.BuildSourceDigest' with actual type 'Text'" :| [])
    , rejectsWith
        "ConstructBuildSourceDigest.hs"
        ("Illegal term-level use of the type constructor 'BuildSourceDigest'" :| [])
    , rejectsWith
        "CoerceBuildSourceDigest.hs"
        ("Couldn't match representation of type 'Text' with that of 'BuildSourceDigest' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "RawTextAsCoordinatorDigest.hs"
        ("Couldn't match expected type 'HostBootstrap.Build.CoordinatorDigest' with actual type 'Text'" :| [])
    , rejectsWith
        "ConstructCoordinatorDigest.hs"
        ("Illegal term-level use of the type constructor 'CoordinatorDigest'" :| [])
    , rejectsWith
        "CoerceCoordinatorDigest.hs"
        ("Couldn't match representation of type 'Text' with that of 'CoordinatorDigest' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "RawTextAsBuilderDigest.hs"
        ("Couldn't match expected type 'HostBootstrap.Build.BuilderDigest' with actual type 'Text'" :| [])
    , rejectsWith
        "ConstructBuilderDigest.hs"
        ("Illegal term-level use of the type constructor 'BuilderDigest'" :| [])
    , rejectsWith
        "CoerceBuilderDigest.hs"
        ("Couldn't match representation of type 'Text' with that of 'BuilderDigest' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "RawTextAsBuildFrameName.hs"
        ("Couldn't match expected type 'HostBootstrap.Build.BuildFrameName' with actual type 'Text'" :| [])
    , rejectsWith
        "ConstructBuildFrameName.hs"
        ("Illegal term-level use of the type constructor 'BuildFrameName'" :| [])
    , rejectsWith
        "CoerceBuildFrameName.hs"
        ("Couldn't match representation of type 'Text' with that of 'BuildFrameName' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "TransposeShippedObjectLinkTarget.hs"
        ("Couldn't match expected type 'ShippedLinkTargetPath' with actual type 'ShippedTargetPath'" :| [])
    , rejectsWith
        "TransposeShippedAuthorityLinkTarget.hs"
        ("Couldn't match expected type 'ShippedAuthorityPath' with actual type 'ShippedLinkTargetPath'" :| [])
    , rejectsWith
        "TransposeShippedAuthorityTarget.hs"
        ("Couldn't match expected type 'ShippedAuthorityPath' with actual type 'ShippedTargetPath'" :| [])
    , rejectsWith
        "ConstructEmptyProviderConfigValue.hs"
        ("Illegal term-level use of the type constructor 'ProviderConfigValue'" :| [])
    , rejectsWith
        "RawFilePathAsShippedAuthority.hs"
        ("Couldn't match type '[Char]' with 'ShippedAuthorityPath'" :| [])
    , rejectsWith
        "RawFilePathAsBuildSourceRoot.hs"
        ("Couldn't match type '[Char]' with 'HostBootstrap.Build.BuildSourceRoot'" :| [])
    , rejectsWith
        "ConstructBuildSourceRoot.hs"
        ("Illegal term-level use of the type constructor 'BuildSourceRoot'" :| [])
    , rejectsWith
        "CoerceBuildSourceRoot.hs"
        ("Couldn't match representation of type '[Char]' with that of 'BuildSourceRoot' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "RawFilePathAsBuilderPath.hs"
        ("Couldn't match type '[Char]' with 'HostBootstrap.Build.BuilderPath'" :| [])
    , rejectsWith
        "ConstructBuilderPath.hs"
        ("Illegal term-level use of the type constructor 'BuilderPath'" :| [])
    , rejectsWith
        "CoerceBuilderPath.hs"
        ("Couldn't match representation of type '[Char]' with that of 'BuilderPath' arising from a use of 'coerce'" :| [])
    , rejectsWith
        "SwapBuildPaths.hs"
        ("Couldn't match expected type 'BuildSourceRoot' with actual type 'BuilderPath'" :| ["Couldn't match expected type 'BuilderPath' with actual type 'BuildSourceRoot'"])
    , rejectsWith
        "SwapBuildDigests.hs"
        ("Couldn't match expected type 'BuildSpecDigest' with actual type 'BuildConfigDigest'" :| ["Couldn't match expected type 'BuildConfigDigest' with actual type 'BuildSpecDigest'"])
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
        "ForgeTeardownAuthorizationPoint.hs"
        ("Illegal term-level use of the type constructor 'TeardownAuthorizationPoint'" :| [])
    , rejectsWith
        "ForgeCompletedTeardownForest.hs"
        ("Illegal term-level use of the type constructor 'CompletedTeardownForest'" :| [])
    , rejectsWith
        "ForgeSettledTeardownChildren.hs"
        ("Illegal term-level use of the type constructor 'SettledChildren'" :| [])
    , rejectsWith
        "ForgePreDescentStep.hs"
        ("Illegal term-level use of the type constructor 'PreDescentStep'" :| [])
    , rejectsWith
        "ForgeTeardownProgressCompleted.hs"
        ("Data constructor not in scope: ProgressCompleted" :| [])
    , rejectsWith
        "ImportOperationPreconditions.hs"
        ("Module 'HostBootstrap.Reconcile' does not export 'withOperationPreconditions'" :| [])
    , rejectsWith
        "ForgePreconditionSet.hs"
        ("Module 'HostBootstrap.Reconcile' does not export 'OperationPreconditionSet'" :| [])
    , rejectsWith
        "ForgeDependencySnapshot.hs"
        ("Illegal term-level use of the type constructor 'DependencySnapshot'" :| [])
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
        (("Couldn't match type 'ReceiptPlanA' with 'ReceiptPlanB' arising from a use of 'coerce'") :| ["Couldn't match type 'ForeignOriginPlanA' with 'ForeignOriginPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'AdoptionPlanA' with 'AdoptionPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'DescriptorPlanA' with 'DescriptorPlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'ProbePlanA' with 'ProbePlanB' arising from a use of 'coerce'"
        , "Couldn't match type 'SnapshotPlanA' with 'SnapshotPlanB' arising from a use of 'coerce'"
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
        (("Couldn't match type 'ReceiptIdentityA' with 'ReceiptIdentityB' arising from a use of 'coerce'") :| ["Couldn't match type 'ReceiptResourceA' with 'ReceiptResourceB' arising from a use of 'coerce'"
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
            registrationProblems files
                ( compileFailCases (\name _ -> name)
                    <> privateCompileFailCases (\name _ -> name)
                    <> representationCompileFailCases (\name _ -> name)
                    <> ownershipCompileFailCases (\name _ -> name)
                    <> handoffNewCompileFailCases (\name _ -> name)
                ) @?= []
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

-- This context is Cabal's actual test component, not the public-consumer context.
-- Its package arguments are read intact from that component's build-info file.
data HandoffTestCompiler = HandoffTestCompiler
    { handoffCompilerPath :: FilePath
    , handoffCompilerArguments :: [String]
    , handoffCompilerDirectory :: FilePath
    , handoffImplementationUnit :: String
    , handoffDependencyDataUnit :: String
    , handoffMainUnit :: String
    , handoffMainInterfaceDirectory :: FilePath
    , handoffPlanResourceUnit :: String
    }

data ExposurePlanUnit = ExposurePlanUnit String String (Maybe FilePath) (Maybe FilePath)

data ExposurePlan = ExposurePlan String String [ExposurePlanUnit]

data ExposureBuildComponent = ExposureBuildComponent String String FilePath FilePath [String]

data ExposureBuildInfo = ExposureBuildInfo String String FilePath [ExposureBuildComponent]

parseExposurePlan :: Aeson.Value -> Parser ExposurePlan
parseExposurePlan = Aeson.withObject "Cabal plan" $ \object -> do
    compilerId <- object .: "compiler-id"
    libraryVersion <- object .: "cabal-lib-version"
    values <- object .: "install-plan"
    units <- traverse parseUnit values
    pure (ExposurePlan compilerId libraryVersion [unit | Just unit <- units])
  where
    parseUnit = Aeson.withObject "Cabal plan unit" $ \object -> do
        packageName <- object .:? "pkg-name" .!= ""
        if packageName /= ("hostbootstrap-core" :: String)
            then pure Nothing
            else do
                unitId <- object .: "id"
                component <- object .: "component-name"
                binary <- object .:? "bin-file"
                buildInfo <- object .:? "build-info"
                pure (Just (ExposurePlanUnit unitId component binary buildInfo))

parseExposureBuildInfo :: Aeson.Value -> Parser ExposureBuildInfo
parseExposureBuildInfo = Aeson.withObject "Cabal build information" $ \object -> do
    libraryVersion <- object .: "cabal-lib-version"
    compiler <- object .: "compiler"
    (compilerId, compilerPath) <- Aeson.withObject "build-information compiler"
        (\value -> (,) <$> value .: "compiler-id" <*> value .: "path") compiler
    components <- object .: "components" >>= traverse parseComponent
    pure (ExposureBuildInfo libraryVersion compilerId compilerPath components)
  where
    parseComponent = Aeson.withObject "build-information component" $ \object ->
        ExposureBuildComponent
            <$> object .: "name"
            <*> object .: "unit-id"
            <*> object .: "src-dir"
            <*> object .: "cabal-file"
            <*> object .: "compiler-args"

readExposureJson :: FilePath -> (Aeson.Value -> Parser value) -> IO value
readExposureJson path parseValue = do
    bytes <- ByteString.readFile path
    case Aeson.eitherDecodeStrict' bytes >>= parseEither parseValue of
        Left failure -> fail (path <> ": " <> failure)
        Right value -> pure value

onlyExposureValue :: String -> [value] -> IO value
onlyExposureValue _ [value] = pure value
onlyExposureValue label values =
    fail ("expected one " <> label <> ", observed " <> show (length values))

-- GHCup's versioned and selected Windows launchers are different shim files.
-- The real compiler version and canonical library directory identify their installation.
compilerInstallationIdentity :: FilePath -> IO (String, FilePath)
compilerInstallationIdentity compiler = do
    version <- query "--numeric-version"
    library <- query "--print-libdir" >>= canonicalizePath
    pure ("ghc-" <> version, library)
  where
    query flag = do
        (code, output, diagnostic) <- readProcessWithExitCode compiler [flag] ""
        case (code, lines output) of
            (ExitSuccess, [value]) | not (null value) -> pure value
            _ -> fail ("could not identify fixture compiler " <> compiler <> ": " <> diagnostic)

resolveHandoffTestCompiler :: CompilerPaths -> IO HandoffTestCompiler
resolveHandoffTestCompiler (CompilerPaths pinnedCompiler _ _) = do
    cwd <- getCurrentDirectory
    root <- findRepoRoot cwd >>= maybe (fail ("could not locate repo root from " <> cwd)) pure
    executable <- getExecutablePath >>= canonicalizePath
    candidates <- fmap concat $ forM [root </> "core", root </> "demo"] $ \projectRoot -> do
        let planPath = projectRoot </> "dist-newstyle" </> "cache" </> "plan.json"
        present <- doesFileExist planPath
        if not present
            then pure []
            else do
                plan@(ExposurePlan _ _ units) <- readExposureJson planPath parseExposurePlan
                fmap concat $ forM units $ \unit@(ExposurePlanUnit _ component binary _) ->
                    case (component, binary) of
                        ("test:hostbootstrap-core-test", Just path) -> do
                            actualBinary <- canonicalizePath path
                            pure [(projectRoot, plan, unit) | equalFilePath actualBinary executable]
                        _ -> pure []
    (projectRoot, ExposurePlan planCompiler planLibrary units, ExposurePlanUnit testUnit component _ infoPath) <-
        onlyExposureValue "plan row for the running core-test executable" candidates
    path <- maybe (fail "the running test component has no build-info path in its plan") pure infoPath
    present <- doesFileExist path
    unless present (fail ("actual test build information is missing: " <> path))
    ExposureBuildInfo infoLibrary infoCompiler compiler components <- readExposureJson path parseExposureBuildInfo
    ExposureBuildComponent _ infoUnit sourceDirectory cabalFile arguments <-
        onlyExposureValue "matching test build-information component"
            [entry | entry@(ExposureBuildComponent name _ _ _ _) <- components, name == component]
    unless (infoUnit == testUnit && infoCompiler == planCompiler && infoLibrary == planLibrary)
        (fail "test build information disagrees with its current plan compiler, Cabal library, or unit identity")
    actualCompiler <- canonicalizePath compiler
    (actualVersion, actualLibrary) <- compilerInstallationIdentity actualCompiler
    (pinnedVersion, pinnedLibrary) <- compilerInstallationIdentity pinnedCompiler
    unless (actualVersion == pinnedVersion && actualVersion == planCompiler && equalFilePath actualLibrary pinnedLibrary)
        (fail "test build information selects a compiler different from the pinned fixture compiler")
    packageRoot <- canonicalizePath (root </> "core" </> "hostbootstrap-core")
    actualSource <- canonicalizePath sourceDirectory
    actualCabal <- canonicalizePath (sourceDirectory </> cabalFile)
    unless (equalFilePath actualSource packageRoot && equalFilePath actualCabal (packageRoot </> "hostbootstrap-core.cabal"))
        (fail "test build information names a different package source or Cabal description")
    infoTime <- getModificationTime path
    configuredTime <- getModificationTime (takeDirectory path </> "setup-config")
    unless (infoTime >= configuredTime)
        (fail "test build information predates its actual configured component")
    unless ("-hide-all-packages" `elem` arguments && "-no-user-package-db" `elem` arguments)
        (fail "actual test compiler arguments do not carry Cabal's explicit package isolation")
    let packageDbs = exposureOptionValues "-package-db" arguments
        localPackageDb = projectRoot </> "dist-newstyle" </> "packagedb" </> planCompiler
    canonicalDbs <- traverse canonicalizePath packageDbs
    canonicalLocal <- canonicalizePath localPackageDb
    unless (any (`equalFilePath` canonicalLocal) canonicalDbs)
        (fail "actual test compiler arguments omit their current project's package database")
    ExposurePlanUnit mainUnit _ _ mainInfo <- onlyExposureValue "actual Main library plan row"
        [entry | entry@(ExposurePlanUnit _ name _ _) <- units, name == "lib"]
    mainInfoPath <- maybe (fail "the Main library has no actual build-information path") pure mainInfo
    ExposureBuildInfo mainLibrary mainCompiler mainCompilerPath mainComponents <- readExposureJson mainInfoPath parseExposureBuildInfo
    ExposureBuildComponent _ mainInfoUnit mainSource mainCabal _ <-
        onlyExposureValue "actual Main library build-information component"
            [entry | entry@(ExposureBuildComponent name _ _ _ _) <- mainComponents, name == "lib"]
    canonicalMainCompiler <- canonicalizePath mainCompilerPath
    canonicalMainSource <- canonicalizePath mainSource
    canonicalMainCabal <- canonicalizePath (mainSource </> mainCabal)
    unless
        ( mainInfoUnit == mainUnit && mainLibrary == planLibrary && mainCompiler == planCompiler
            && equalFilePath canonicalMainCompiler actualCompiler
            && equalFilePath canonicalMainSource packageRoot
            && equalFilePath canonicalMainCabal (packageRoot </> "hostbootstrap-core.cabal")
        )
        (fail "Main library build information disagrees with its actual compiler, unit, or package source")
    let mainInterfaces = takeDirectory mainInfoPath </> "build"
    interfacesPresent <- doesDirectoryExist mainInterfaces
    unless interfacesPresent (fail "the actual Main library interface directory is missing")
    implementation <- unitFor "lib:handoff-implementation-internal" units
    dependencyData <- unitFor "lib:lifecycle-dependency-internal" units
    planResource <- unitFor "lib:plan-resource-internal" units
    let implementationSelections =
            [value | value <- exposureOptionValues "-package-id" arguments, takeWhile (not . isSpace) value == implementation]
    _ <- onlyExposureValue "actual implementation-unit package selection" implementationSelections
    pure
        HandoffTestCompiler
            { handoffCompilerPath = compiler
            , handoffCompilerArguments = arguments
            , handoffCompilerDirectory = sourceDirectory
            , handoffImplementationUnit = implementation
            , handoffDependencyDataUnit = dependencyData
            , handoffMainUnit = mainUnit
            , handoffMainInterfaceDirectory = mainInterfaces
            , handoffPlanResourceUnit = planResource
            }
  where
    unitFor name units =
        onlyExposureValue ("configured unit " <> name)
            [unitId | ExposurePlanUnit unitId component _ _ <- units, component == name]

exposureOptionValues :: String -> [String] -> [String]
exposureOptionValues option = go
  where
    go (flag : value : rest)
        | flag == option = value : go rest
    go (_ : rest) = go rest
    go [] = []

compileHandoffSource :: HandoffTestCompiler -> String -> String -> [String] -> IO (ExitCode, String, String)
compileHandoffSource context name source extraArguments =
    withSystemTempDirectory "hostbootstrap-handoff-component-proof" $ \directory -> do
        let path = directory </> name <> ".hs"
        ByteString.writeFile path (TextEncoding.encodeUtf8 (Text.pack source))
        runHandoffCompiler context directory path extraArguments

-- This runtime assertion deliberately selects only the native primitive for
-- one temporary executable. The ordinary test-component mixin stays intact.
assertNativeLinkNoReplacePreservesDestination :: IO ()
assertNativeLinkNoReplacePreservesDestination = do
    context <- resolveCompilerPaths >>= resolveHandoffTestCompiler
    withSystemTempDirectory "hostbootstrap-native-link-proof" $ \directory -> do
        let path = directory </> "NativeLinkProof.hs"
            executable = directory </> "native-link-proof.exe"
            sourcePath = directory </> "source"
            destination = directory </> "destination"
            source = unlines
                [ "{-# LANGUAGE TypeApplications #-}"
                , "module Main (main) where"
                , "import Control.Exception (IOException, try)"
                , "import qualified Data.ByteString as ByteString"
                , "import HostBootstrap.Config.Install.Native (linkNoReplace)"
                , "import System.Environment (getArgs)"
                , "main :: IO ()"
                , "main = do"
                , "    paths <- getArgs"
                , "    case paths of"
                , "        [source,destination] -> do"
                , "            outcome <- try @IOException (linkNoReplace source destination)"
                , "            original <- ByteString.readFile source"
                , "            kept <- ByteString.readFile destination"
                , "            case outcome of"
                , "                Left _ | original == ByteString.pack [110,101,119]"
                , "                    && kept == ByteString.pack [111,108,100] -> pure ()"
                , "                _ -> fail (\"taken destination changed or publication succeeded: \" ++ show outcome)"
                , "        _ -> fail \"expected source and destination\""
                ]
            outputs = concatMap (\flag -> [flag, directory])
                ["-outputdir", "-odir", "-hidir", "-hiedir", "-stubdir", "-tmpdir"]
            arguments = handoffCompilerArguments context
                <> [ "-package-id"
                   , handoffImplementationUnit context <> " (HostBootstrap.Config.Install.Native)"
                   , "--make", "-main-is", "Main", "-o", executable
                   ]
                <> outputs <> [path]
        ByteString.writeFile path (TextEncoding.encodeUtf8 (Text.pack source))
        ByteString.writeFile sourcePath (ByteString.pack [110, 101, 119])
        ByteString.writeFile destination (ByteString.pack [111, 108, 100])
        (compiled, output, diagnostic) <-
            withCurrentDirectory (handoffCompilerDirectory context) $
                readProcessWithExitCode (handoffCompilerPath context) arguments ""
        assertEqual "actual native-link probe compiles" ExitSuccess compiled
        assertBool (output <> diagnostic) (null diagnostic)
        (executed, observed, failure) <- readProcessWithExitCode executable [sourcePath, destination] ""
        assertEqual (observed <> failure) ExitSuccess executed
        assertBool (observed <> failure) (null failure)


-- Link the actual hidden Budget kernel into a temporary Main-unit control.
-- The regular test component and public hidden-module refusals stay intact.
withPrivateBudgetKernel :: String -> (IO FilePath -> TestTree) -> TestTree
withPrivateBudgetKernel source use =
    withResource build cleanup (\getProgram -> use ((\(_, _, executable) -> executable) <$> getProgram))
  where
    build = do
        context <- resolveCompilerPaths >>= resolveHandoffTestCompiler
        parent <- getTemporaryDirectory >>= canonicalizePath
        directory <- createTempDirectory parent "hostbootstrap-budget-settlement-control"
        let executable = directory </> "budget-settlement-control.exe"
            resource = (parent, directory, executable)
        compilePrivateBudgetKernel context directory executable source `onException` cleanup resource
        pure resource
    cleanup (parent, directory, _) = do
        actual <- canonicalizePath directory
        unless (equalFilePath (takeDirectory actual) parent && "hostbootstrap-budget-settlement-control" `isPrefixOf` takeFileName actual)
            (fail "budget settlement control cleanup escaped its exact temporary parent")
        removeDirectoryRecursive actual

compilePrivateBudgetKernel :: HandoffTestCompiler -> FilePath -> FilePath -> String -> IO ()
compilePrivateBudgetKernel context directory executable source = do
    description <- SourceGuard.readPackageDescription
    stanza <- maybe (fail "the budget settlement control has no Main library stanza") pure (SourceGuard.mainLibraryStanza description)
    let modules = Set.toList . Set.fromList $
            SourceGuard.fieldModules "exposed-modules" stanza
                <> SourceGuard.fieldModules "other-modules" stanza
                <> SourceGuard.fieldModules "autogen-modules" stanza
                <> ["Paths_hostbootstrap_core"]
        interfaces = directory </> "interfaces"
        objects = directory </> "objects"
        compilerTemp = directory </> "compiler-temp"
        modulePath name = map (\character -> if character == '.' then pathSeparator else character) name
    mapM_ (createDirectoryIfMissing True) [interfaces, objects, compilerTemp]
    forM_ modules $ \name ->
        forM_ ["hi", "dyn_hi"] $ \suffix -> do
            let relative = modulePath name <.> suffix
                original = handoffMainInterfaceDirectory context </> relative
                copied = interfaces </> relative
            present <- doesFileExist original
            if not present
                then pure ()
                else do
                    createDirectoryIfMissing True (takeDirectory copied)
                    copyFile original copied
                    before <- ByteString.readFile original
                    after <- ByteString.readFile copied
                    assertBool ("copied Main interface changed: " <> name) (before == after)
    required <- doesFileExist (interfaces </> modulePath "HostBootstrap.Cluster.Budget.Internal" <.> "hi")
    assertBool "the actual hidden Budget interface is present" required
    inherited <- getEnvironment
    let compilerEnvironment =
            [("TEMP", compilerTemp), ("TMP", compilerTemp), ("TMPDIR", compilerTemp), ("GHC_CHARENC", "UTF-8")]
                <> [(key, value) | (key, value) <- inherited, map toUpper key `notElem` ["TEMP", "TMP", "TMPDIR", "GHC_CHARENC"]]
        flags =
            handoffCompilerArguments context
                <> ["-this-unit-id", handoffMainUnit context, "-i", "-i" <> interfaces]
                <> concatMap (\flag -> [flag, objects]) ["-outputdir", "-odir", "-hiedir", "-stubdir", "-tmpdir"]
                <> ["-hidir", interfaces]
        runCompiler arguments = do
            (code, output, diagnostic) <-
                Process.readCreateProcessWithExitCode
                    ( (Process.proc (handoffCompilerPath context) arguments)
                        { Process.cwd = Just (handoffCompilerDirectory context)
                        , Process.env = Just compilerEnvironment
                        }
                    )
                    ""
            assertEqual (output <> diagnostic) ExitSuccess code
            assertBool (output <> diagnostic) (null diagnostic)
        path = directory </> "BudgetSettlementControl.hs"
        inputs = [handoffCompilerDirectory context </> "test" </> name <.> "hs" | name <- ["Expect", "PlatformPath", "Fixture", "PrepareFixture"]] <> [path]
        outputs = [objects </> takeBaseName input <.> "o" | input <- inputs]
    ByteString.writeFile path (TextEncoding.encodeUtf8 (Text.pack source))
    forM_ (zip inputs outputs) $ \(input, output) -> runCompiler (flags <> ["-c", input, "-o", output])
    runCompiler (flags <> ["-o", executable] <> outputs)

-- Select the private execution module for this one temporary executable only.
-- The regular test mixin and its independently checked refusals remain intact.
shareDescriptorRuntimeControl :: IO HandoffTestCompiler -> TestTree
shareDescriptorRuntimeControl getCompiler =
    testCase "a share without its provider dependency refuses before probing" $ do
        context <- getCompiler
        withSystemTempDirectory "hostbootstrap-provider-share-descriptor-proof" $ \directory -> do
            let path = directory </> "ProviderShareDescriptorProof.hs"
                executable = directory </> "provider-share-descriptor-proof.exe"
                source = unlines
                    [ "{-# LANGUAGE RankNTypes #-}"
                    , "module Main (main) where"
                    , ""
                    , "import qualified HostBootstrap.Lifecycle.Execution.Internal as Internal"
                    , "import ProviderReconcileSpec (shareDescriptorRefusalCaseWith)"
                    , "import qualified FakeProvider"
                    , "import System.Environment (getArgs, lookupEnv)"
                    , "import GHC.IO.Encoding (setLocaleEncoding, utf8)"
                    , ""
                    , "withoutProviderDependency ::"
                    , "    Internal.StepExecution scope planId ->"
                    , "    Internal.StepExecution scope planId"
                    , "withoutProviderDependency execution ="
                    , "    Internal.mintStepExecution"
                    , "        (Internal.stepExecutionHostConfig execution)"
                    , "        changedPackage"
                    , "        (Internal.stepExecutionRuntime execution)"
                    , "  where"
                    , "    package = Internal.stepExecutionPackage execution"
                    , "    node = Internal.planExecutionPackageNode package"
                    , "    changedPackage ="
                    , "        Internal.mintPlanExecutionPackage"
                    , "            (Internal.planExecutionPackageSpecDigest package)"
                    , "            (Internal.planExecutionPackagePlanDigest package)"
                    , "            (Internal.planExecutionPackageConfigDigest package)"
                    , "            (Internal.planExecutionPackageNodeIdentity package)"
                    , "            (Internal.planExecutionPackageProfile package)"
                    , "            (Internal.planExecutionPackageGeneration package)"
                    , "            (Internal.planExecutionPackageProject package)"
                    , "            (Internal.planExecutionPackageRoot package)"
                    , "            node{Internal.executionNodeDependencies = []}"
                    , ""
                    , "main :: IO ()"
                    , "main = do"
                    , "    setLocaleEncoding utf8"
                    , "    arguments <- getArgs"
                    , "    fixture <- lookupEnv FakeProvider.fakeProviderVariable"
                    , "    case fixture of"
                    , "        Just root -> FakeProvider.runFakeProviderClient FakeProvider.aliasGuest root arguments"
                    , "        Nothing -> shareDescriptorRefusalCaseWith withoutProviderDependency"
                    ]
                outputs = concatMap (\flag -> [flag, directory])
                    ["-outputdir", "-odir", "-hidir", "-hiedir", "-stubdir", "-tmpdir"]
                arguments = handoffCompilerArguments context
                    <> [ "-package-id"
                       , handoffImplementationUnit context <> " (HostBootstrap.Lifecycle.Execution.Internal)"
                       , "--make", "-main-is", "Main", "-o", executable
                       ]
                    <> outputs <> [path]
                    <> ["test" </> name <> ".hs" | name <- ["Expect", "Fixture", "PlatformPath", "PrepareFixture", "FakeProvider", "ProviderReconcileSpec", "SourceGuard"]]
            ByteString.writeFile path (TextEncoding.encodeUtf8 (Text.pack source))
            (compiled, output, diagnostic) <-
                withCurrentDirectory (handoffCompilerDirectory context) $
                    readProcessWithExitCode (handoffCompilerPath context) arguments ""
            assertEqual ("share descriptor probe failed to compile:\n" <> output <> diagnostic) ExitSuccess compiled
            assertBool (output <> diagnostic) (null diagnostic)
            (executed, observed, failure) <- readProcessWithExitCode executable [] ""
            assertEqual (observed <> failure) ExitSuccess executed
            assertBool (observed <> failure) (null failure)


providerOriginRuntimeControls :: IO HandoffTestCompiler -> TestTree
providerOriginRuntimeControls getCompiler =
    withResource (getCompiler >>= buildProviderOriginProgram) cleanupProviderOriginProgram $ \getProgram ->
        testGroup "provider-bound origin runtime controls"
            [ testCase label $ do
                (_, _, executable) <- getProgram
                (code, output, diagnostic) <- readProcessWithExitCode executable [argument] ""
                assertEqual (output <> diagnostic) ExitSuccess code
                assertBool (output <> diagnostic) (null output && null diagnostic)
            | (label, argument) <-
                [ ("an origin resource-key mismatch refuses bound execution", "resource-key")
                , ("an origin generation mismatch refuses bound execution", "generation")
                , ("another backend realization refuses bound execution", "realization")
                ]
            ]

providerAliasPlanRuntimeControl :: IO HandoffTestCompiler -> TestTree
providerAliasPlanRuntimeControl getCompiler =
    withResource (getCompiler >>= buildProviderOriginProgram) cleanupProviderOriginProgram $ \getProgram ->
        testCase "an alias from another plan refuses before probing" $ do
            (_, _, executable) <- getProgram
            (code, output, diagnostic) <- readProcessWithExitCode executable ["alias-plan"] ""
            assertEqual (output <> diagnostic) ExitSuccess code
            assertBool (output <> diagnostic) (null output && null diagnostic)

nodeAliasRuntimeControls :: IO HandoffTestCompiler -> TestTree
nodeAliasRuntimeControls getCompiler =
    withResource (getCompiler >>= buildProviderOriginProgram) cleanupProviderOriginProgram $ \getProgram ->
        testGroup "node guest alias refusal runtime controls"
            [ testCase label $ do
                (_, _, executable) <- getProgram
                (code, output, diagnostic) <- readProcessWithExitCode executable ["node-alias", argument] ""
                assertEqual (output <> diagnostic) ExitSuccess code
                let expected =
                        "  [host-orchestrator-0] copy-source — refusing managed guest alias node: refused: "
                            <> show (ProviderBackendSpec.nodeAliasRefusalExpected argument) <> "\n"
                assertEqual "the Chain reports the exact terminal refusal" expected (output <> diagnostic)
            | (label, argument) <-
                [ ("the Chain alias node refuses a missing provider dependency", "missing-provider")
                , ("the Chain alias node refuses a missing share dependency", "missing-share")
                , ("the Chain alias node refuses another planned provider key", "provider-key")
                , ("the Chain alias node refuses another planned share key", "share-key")
                , ("the Chain alias node refuses a stale backend generation", "stale-generation")
                , ("the Chain alias node refuses another share origin", "share-origin")
                ]
            ]

buildProviderOriginProgram :: HandoffTestCompiler -> IO (FilePath, FilePath, FilePath)
buildProviderOriginProgram context = do
    parent <- getTemporaryDirectory >>= canonicalizePath
    directory <- createTempDirectory parent "hostbootstrap-provider-origin-control"
    let executable = directory </> "provider-origin-control.exe"
        resource = (parent, directory, executable)
    compileProviderOriginProgram context directory executable `onException` cleanupProviderOriginProgram resource
    pure resource

cleanupProviderOriginProgram :: (FilePath, FilePath, FilePath) -> IO ()
cleanupProviderOriginProgram (parent, directory, _) = do
    actual <- canonicalizePath directory
    unless
        (equalFilePath (takeDirectory actual) parent && "hostbootstrap-provider-origin-control" `isPrefixOf` takeFileName actual)
        (fail "provider-origin compiler cleanup escaped its exact temporary parent")
    removeDirectoryRecursive actual

compileProviderOriginProgram :: HandoffTestCompiler -> FilePath -> FilePath -> IO ()
compileProviderOriginProgram context directory executable = do
    description <- SourceGuard.readPackageDescription
    stanza <- maybe (fail "the provider-origin control has no Main library stanza") pure (SourceGuard.mainLibraryStanza description)
    let modules = Set.toList . Set.fromList $
            SourceGuard.fieldModules "exposed-modules" stanza
                <> SourceGuard.fieldModules "other-modules" stanza
                <> SourceGuard.fieldModules "autogen-modules" stanza
                <> ["Paths_hostbootstrap_core"]
        interfaces = directory </> "interfaces"
        objects = directory </> "objects"
        compilerTemp = directory </> "compiler-temp"
        modulePath name = map (\character -> if character == '.' then pathSeparator else character) name
    mapM_ (createDirectoryIfMissing True) [interfaces, objects, compilerTemp]
    forM_ modules $ \name ->
        forM_ ["hi", "dyn_hi"] $ \suffix -> do
            let relative = modulePath name <.> suffix
                original = handoffMainInterfaceDirectory context </> relative
                copied = interfaces </> relative
            present <- doesFileExist original
            if not present
                then pure ()
                else do
                    createDirectoryIfMissing True (takeDirectory copied)
                    copyFile original copied
                    before <- ByteString.readFile original
                    after <- ByteString.readFile copied
                    assertBool ("copied Main interface changed: " <> name) (before == after)
    required <- doesFileExist (interfaces </> modulePath "HostBootstrap.Substrate.Provider.Observation.Internal" <.> "hi")
    assertBool "the actual private provider interface is present" required
    inherited <- getEnvironment
    let compilerEnvironment =
            [("TEMP", compilerTemp), ("TMP", compilerTemp), ("TMPDIR", compilerTemp), ("GHC_CHARENC", "UTF-8")]
                <> [(key, value) | (key, value) <- inherited, map toUpper key `notElem` ["TEMP", "TMP", "TMPDIR", "GHC_CHARENC"]]
        flags =
            handoffCompilerArguments context
                <> ["-this-unit-id", handoffMainUnit context, "-i", "-i" <> interfaces]
                <> ["-package-id", handoffPlanResourceUnit context <> " (HostBootstrap.Plan.Resource)"]
                <> ["-package-id", handoffImplementationUnit context <> " (HostBootstrap.Lifecycle.Execution.Internal)"]
                <> concatMap (\flag -> [flag, objects]) ["-outputdir", "-odir", "-hiedir", "-stubdir", "-tmpdir"]
                <> ["-hidir", interfaces]
        runCompiler arguments = do
            (code, output, diagnostic) <-
                Process.readCreateProcessWithExitCode
                    ( (Process.proc (handoffCompilerPath context) arguments)
                        { Process.cwd = Just (handoffCompilerDirectory context)
                        , Process.env = Just compilerEnvironment
                        }
                    )
                    ""
            assertEqual (output <> diagnostic) ExitSuccess code
            assertBool (output <> diagnostic) (null diagnostic)
        source = unlines
            [ "{-# LANGUAGE OverloadedStrings #-}"
            , "{-# LANGUAGE RankNTypes #-}"
            , "module Main (main) where"
            , ""
            , "import HostBootstrap.Reconcile (ConflictDetail (ConflictDetail))"
            , "import HostBootstrap.Substrate.Provider.Observation.Internal"
            , "    ( ManagedProviderHandle (ManagedProviderHandle)"
            , "    , ProviderBackendBinding (ProviderBackendBinding)"
            , "    , ProviderOriginBinding (providerOriginResourceKey, providerOriginGeneration, providerOriginBackendBinding)"
            , "    )"
            , "import ProviderBackendSpec (providerOriginRefusalCaseWith, aliasPlanRefusalCaseWith, nodeAliasRefusalCaseWith, backendGuest)"
            , "import qualified FakeProvider"
            , "import qualified HostBootstrap.Lifecycle.Execution.Internal as Execution"
            , "import HostBootstrap.Plan.Resource (PlannedResource (PlannedResource))"
            , "import System.Environment (getArgs, lookupEnv)"
            , "import GHC.IO.Encoding (setLocaleEncoding, utf8)"
            , ""
            , "main :: IO ()"
            , "main = do"
            , "    setLocaleEncoding utf8"
            , "    arguments <- getArgs"
            , "    fixture <- lookupEnv FakeProvider.fakeProviderVariable"
            , "    case fixture of"
            , "        Just root -> FakeProvider.runFakeProviderClient backendGuest root arguments"
            , "        Nothing -> runCase arguments"
            , ""
            , "runCase :: [String] -> IO ()"
            , "runCase arguments ="
            , "    case arguments of"
            , "        [\"resource-key\"] ->"
            , "            providerOriginRefusalCaseWith"
            , "                (\\(ProviderBackendBinding semantic realization) -> (semantic, realization))"
            , "                (ConflictDetail \"core:deploy-vm\" \"other-provider\" \"core:deploy-vm\""
            , "                    \"use the provider authority settled from this exact origin\")"
            , "                (\\_ (ManagedProviderHandle origin handle receipt) ->"
            , "                    ManagedProviderHandle (origin{providerOriginResourceKey = \"other-provider\"}) handle receipt)"
            , "        [\"generation\"] ->"
            , "            providerOriginRefusalCaseWith"
            , "                (\\(ProviderBackendBinding semantic realization) -> (semantic, realization))"
            , "                (ConflictDetail \"core:deploy-vm\" \"18\" \"17\""
            , "                    \"use the provider authority settled from this exact generation\")"
            , "                (\\_ (ManagedProviderHandle origin handle receipt) ->"
            , "                    ManagedProviderHandle (origin{providerOriginGeneration = 18}) handle receipt)"
            , "        [\"realization\"] ->"
            , "            providerOriginRefusalCaseWith"
            , "                (\\(ProviderBackendBinding semantic realization) -> (semantic, realization))"
            , "                (ConflictDetail \"core:deploy-vm\" \"the retained provider backend realization\""
            , "                    \"a different provider backend realization\""
            , "                    \"use the strong backend that minted this managed provider authority\")"
            , "                (\\(semantic, realization) (ManagedProviderHandle origin handle receipt) ->"
            , "                    ManagedProviderHandle"
            , "                        (origin{providerOriginBackendBinding = ProviderBackendBinding semantic realization})"
            , "                        handle receipt)"
            , "        [\"alias-plan\"] ->"
            , "            aliasPlanRefusalCaseWith"
            , "                (\\(PlannedResource _ key frame) -> PlannedResource \"another-alias-plan\" key frame)"
            , "        [\"node-alias\", \"missing-provider\"] ->"
            , "            nodeAliasRefusalCaseWith \"missing-provider\""
            , "                (changeNode (\\node -> node{Execution.executionNodeDependencies ="
            , "                    filter ((/= \"core:deploy-vm\") . fst) (Execution.executionNodeDependencies node)})) id id asProvider"
            , "        [\"node-alias\", \"missing-share\"] ->"
            , "            nodeAliasRefusalCaseWith \"missing-share\""
            , "                (changeNode (\\node -> node{Execution.executionNodeOperationKey = \"project:unrelated\"})) id id asProvider"
            , "        [\"node-alias\", \"provider-key\"] ->"
            , "            nodeAliasRefusalCaseWith \"provider-key\" id"
            , "                (\\(PlannedResource digest _ frame) -> PlannedResource digest \"project:other-provider\" frame) id asProvider"
            , "        [\"node-alias\", \"share-key\"] ->"
            , "            nodeAliasRefusalCaseWith \"share-key\" id id"
            , "                (\\(PlannedResource digest _ frame) -> PlannedResource digest \"project:other-share\" frame) asProvider"
            , "        [\"node-alias\", \"stale-generation\"] ->"
            , "            nodeAliasRefusalCaseWith \"stale-generation\" id id id asProvider"
            , "        [\"node-alias\", \"share-origin\"] ->"
            , "            nodeAliasRefusalCaseWith \"share-origin\" id id id asProvider"
            , "        _ -> fail \"expected one provider authority control case\""
            , ""
            , "changeNode :: (Execution.ExecutionNode -> Execution.ExecutionNode) ->"
            , "    Execution.StepExecution scope planId -> Execution.StepExecution scope planId"
            , "changeNode change execution ="
            , "    let package = Execution.stepExecutionPackage execution"
            , "        changed = Execution.mintPlanExecutionPackage"
            , "            (Execution.planExecutionPackageSpecDigest package)"
            , "            (Execution.planExecutionPackagePlanDigest package)"
            , "            (Execution.planExecutionPackageConfigDigest package)"
            , "            (Execution.planExecutionPackageNodeIdentity package)"
            , "            (Execution.planExecutionPackageProfile package)"
            , "            (Execution.planExecutionPackageGeneration package)"
            , "            (Execution.planExecutionPackageProject package)"
            , "            (Execution.planExecutionPackageRoot package)"
            , "            (change (Execution.planExecutionPackageNode package))"
            , "    in Execution.mintStepExecution (Execution.stepExecutionHostConfig execution) changed"
            , "        (Execution.stepExecutionRuntime execution)"
            , ""
            , "asProvider :: Execution.StepExecution scope planId -> Execution.StepExecution scope planId"
            , "asProvider = changeNode (\\node -> node"
            , "    { Execution.executionNodeOperationKey = \"core:deploy-vm\""
            , "    , Execution.executionNodeDependencies = []"
            , "    , Execution.executionNodeProjectedKeys = []"
            , "    })"
            ]
        path = directory </> "ProviderOriginControl.hs"
        helpers = ["ConditionalCase", "Expect", "PlatformPath", "SourceGuard", "FakeProvider", "Fixture", "PrepareFixture", "ProviderBackendSpec"]
    ByteString.writeFile path (TextEncoding.encodeUtf8 (Text.pack source))
    let inputs = [handoffCompilerDirectory context </> "test" </> name <.> "hs" | name <- helpers] <> [path]
        outputs = [objects </> takeBaseName input <.> "o" | input <- inputs]
    forM_ (zip inputs outputs) $ \(input, output) ->
        runCompiler (flags <> ["-c", input, "-o", output])
    runCompiler (flags <> ["-o", executable] <> outputs)

runHandoffCompiler :: HandoffTestCompiler -> FilePath -> FilePath -> [String] -> IO (ExitCode, String, String)
runHandoffCompiler context directory path extraArguments =
    withCurrentDirectory (handoffCompilerDirectory context) $
        readProcessWithExitCode
            (handoffCompilerPath context)
            ( handoffCompilerArguments context
                <> [ "-fno-code", "-fno-diagnostics-show-caret"
                   , "-outputdir", directory, "-odir", directory, "-hidir", directory
                   , "-hiedir", directory, "-stubdir", directory
                   ]
                <> extraArguments <> [path]
            )
            ""

rejectsHandoffFixture :: IO HandoffTestCompiler -> FilePath -> NonEmpty String -> TestTree
rejectsHandoffFixture getCompiler fixture expectedDiagnostics =
    testCase fixture $ do
        context <- getCompiler
        SourceGuard.withPackageSourceIn [] $ \packageRoot _ ->
            withSystemTempDirectory "hostbootstrap-handoff-context-refusal" $ \directory -> do
                let path = packageRoot </> "test" </> "compile-fail" </> fixture
                    category = case fixture of
                        "DataDependencyAsProductionCarrier.hs" -> "GHC-83865"
                        "RawTextAsRootedPayloadDigest.hs" -> "GHC-83865"
                        "CoerceRootedPayloadDigest.hs" -> "GHC-18872"
                        "ForgeRootedPayloadDigest.hs" -> "GHC-01928"
                        "SwapRootedPayloadDigests.hs" -> "GHC-83865"
                        "CoerceRootedChildConfigDigest.hs" -> "GHC-18872"
                        "ForgeRootedChildConfigDigest.hs" -> "GHC-01928"
                        "RawTextAsRootedRequestDigest.hs" -> "GHC-83865"
                        "PayloadDigestAsRootedRequestDigest.hs" -> "GHC-83865"
                        "CoerceRootedRequestDigest.hs" -> "GHC-18872"
                        "ForgeRootedRequestDigest.hs" -> "GHC-01928"
                        "RawTextAsRootedLifecycleSession.hs" -> "GHC-83865"
                        "CoerceRootedLifecycleSession.hs" -> "GHC-18872"
                        "ForgeRootedLifecycleSession.hs" -> "GHC-01928"
                        "SwapLifecycleSessionStage.hs" -> "GHC-83865"
                        "RawTextAsRootedLifecycleStage.hs" -> "GHC-83865"
                        "CoerceRootedLifecycleStage.hs" -> "GHC-18872"
                        "ForgeRootedLifecycleStage.hs" -> "GHC-01928"
                        "RawWord64AsRootedLifecycleOrdinal.hs" -> "GHC-83865"
                        "CoerceRootedLifecycleOrdinal.hs" -> "GHC-18872"
                        "ForgeRootedLifecycleOrdinal.hs" -> "GHC-01928"
                        "RawTextAsRootedPredecessorDigest.hs" -> "GHC-83865"
                        "RequestDigestAsRootedPredecessorDigest.hs" -> "GHC-83865"
                        "CoerceRootedPredecessorDigest.hs" -> "GHC-18872"
                        "ForgeRootedPredecessorDigest.hs" -> "GHC-01928"
                        _ -> "GHC-87110"
                (code, output, diagnostic) <- runHandoffCompiler context directory path []
                case code of
                    ExitSuccess -> assertFailure ("actual test-context negative compiled: " <> fixture <> "\n" <> output)
                    ExitFailure _ -> do
                        assertBool ("wrong compiler category for " <> fixture <> ":\n" <> diagnostic)
                            (category `isInfixOf` diagnostic)
                        either
                            (\failure -> assertFailure (fixture <> ": " <> failure <> "\n" <> diagnostic))
                            pure
                            (matchDiagnosticPhrases expectedDiagnostics diagnostic)

handoffTestContextCases :: IO HandoffTestCompiler -> TestTree
handoffTestContextCases getCompiler =
    testGroup "actual handoff implementation test exposure"
        ( [ testCase name $ do
            context <- getCompiler
            (code, output, diagnostic) <- compileHandoffSource context name source []
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("actual test-component positive failed:\n" <> output <> diagnostic)
          | (name, source) <- handoffExposurePositives
          ]
            <> [ testGroup "selected compiler fixture successes"
                    [ testCase "ImportHandoffRooted.hs" $ do
                        context <- getCompiler
                        SourceGuard.withPackageSourceIn [] $ \packageRoot _ ->
                            withSystemTempDirectory "hostbootstrap-rooted-context-success" $ \directory -> do
                                let path = packageRoot </> "test" </> "compile-fail" </> "ImportHandoffRooted.hs"
                                (code, output, diagnostic) <- runHandoffCompiler context directory path []
                                case code of
                                    ExitSuccess -> pure ()
                                    ExitFailure _ -> assertFailure ("the selected context rejected the unchanged Rooted import:\n" <> output <> diagnostic)
                    ]
               ]
            <> [testGroup "wrapped module-map parser" moduleMapParserCases]
            <> [shareDescriptorRuntimeControl getCompiler, providerOriginRuntimeControls getCompiler, providerAliasPlanRuntimeControl getCompiler, nodeAliasRuntimeControls getCompiler]
            <> [testGroup "exact thinned compiler refusals"
                    ( handoffExistingCompileFailCases (rejectsHandoffFixture getCompiler)
                        <> handoffNewCompileFailCases (rejectsHandoffFixture getCompiler)
                    )]
            <> [ withResource (getCompiler >>= actualHandoffModuleMap) (const (pure ())) $ \getMap ->
                    testGroup "actual per-unit module origins"
                        [ testCase name $ do
                            context <- getCompiler
                            actualMap <- getMap
                            annotations <- either assertFailure pure $
                                moduleOriginAnnotations name (handoffImplementationUnit context) actualMap
                            assertBool
                                (name <> " exposes the Main-only implementation origin: " <> show annotations)
                                (not (moduleOriginSelected annotations))
                        | name <- handoffMainOnlyModules
                        ]
               ]
        )

handoffExposurePositives :: [(String, String)]
handoffExposurePositives =
    [ ( "HandoffProtocolSharedChannel"
      , unlines
            [ "module HandoffProtocolSharedChannel (retained) where"
            , "import HostBootstrap.Handoff.Protocol (HandoffChannel, handoffChannel)"
            , "import System.IO (Handle)"
            , "retained :: Handle -> Handle -> IO HandoffChannel"
            , "retained = handoffChannel"
            ]
      )
    , ( "HandoffReceiverSharesPublicInputs"
      , unlines
            [ "{-# LANGUAGE RankNTypes #-}"
            , "module HandoffReceiverSharesPublicInputs (retained) where"
            , "import HostBootstrap.Authority (InstalledProjectIdentity)"
            , "import HostBootstrap.Handoff (ProjectVerificationKey)"
            , "import HostBootstrap.Handoff.Protocol (HandoffChannel)"
            , "import HostBootstrap.Handoff.Receiver (ReceiverError, withReceivedHandoffEdge)"
            , "retained :: InstalledProjectIdentity projectId -> HandoffChannel -> ProjectVerificationKey -> IO (Either ReceiverError ())"
            , "retained project channel key = withReceivedHandoffEdge project channel key"
            , "    (\\_ _ _ -> pure (Right ())) (\\_ _ -> pure (Right ()))"
            , "    (\\_ _ _ -> pure (Right ())) (\\_ _ -> pure (Right ()))"
            ]
      )
    , ( "HandoffRelaySharesPublicOffer"
      , unlines
            [ "module HandoffRelaySharesPublicOffer (retained) where"
            , "import Data.ByteString (ByteString)"
            , "import Data.Word (Word64)"
            , "import HostBootstrap.Handoff (HandoffBindingInput)"
            , "import HostBootstrap.Handoff.Protocol (HandoffChannel)"
            , "import HostBootstrap.Handoff.Relay (BrokerLink, offerHandoffEdge)"
            , "retained :: BrokerLink scope generation -> HandoffChannel -> Word64 -> HandoffBindingInput -> ByteString -> ()"
            , "retained link channel request input payload = seq (offerHandoffEdge link channel request input payload) ()"
            ]
      )
    , ( "HandoffInternalSharesPublicResponse"
      , unlines
            [ "module HandoffInternalSharesPublicResponse (retained) where"
            , "import Data.ByteString (ByteString)"
            , "import HostBootstrap.Handoff (RootedLifecycleResponse)"
            , "import HostBootstrap.Handoff.Internal (RecoverySigningKernel, consumeRootedLifecycleResponseSigningKernel)"
            , "retained :: RecoverySigningKernel -> (broker -> ByteString -> ByteString -> IO (Either failure RootedLifecycleResponse)) -> broker -> ByteString -> ByteString -> IO (Either failure RootedLifecycleResponse)"
            , "retained = consumeRootedLifecycleResponseSigningKernel"
            ]
      )
    , ( "HandoffRootedSharesPublicOpaqueValues"
      , unlines
            [ "module HandoffRootedSharesPublicOpaqueValues (binding, response) where"
            , "import HostBootstrap.Handoff (RootedPayloadBinding, RootedLifecycleResponse)"
            , "import qualified HostBootstrap.Handoff.Rooted as Rooted"
            , "binding :: Rooted.RootedPayloadBinding scope generation -> RootedPayloadBinding scope generation"
            , "binding = id"
            , "response :: Rooted.RootedLifecycleResponse -> RootedLifecycleResponse"
            , "response = id"
            ]
      )
    , ( "RootedPayloadDigestTypedInput"
      , unlines
            [ "module RawTextAsRootedPayloadDigest (bind, PayloadDigest) where"
            , ""
            , "import Data.ByteString (ByteString)"
            , "import Data.Text (Text)"
            , "import HostBootstrap.Handoff.Rooted (ChildConfigDigest, PayloadDigest, RootedPayloadBinding, rootedPayloadBindingKernel)"
            , ""
            , "bind :: ByteString -> PayloadDigest -> ChildConfigDigest -> ByteString -> Either Text (RootedPayloadBinding scope generation)"
            , "bind edge payload config signature ="
            , "    rootedPayloadBindingKernel edge payload config signature"
            ]
      )
    , ( "RootedPayloadChildConfigTypedInputs"
      , unlines
            [ "module SwapRootedPayloadDigests where"
            , ""
            , "import Data.ByteString (ByteString)"
            , "import Data.Text (Text)"
            , "import HostBootstrap.Handoff.Rooted (ChildConfigDigest, PayloadDigest, RootedPayloadBinding, rootedPayloadBindingKernel)"
            , ""
            , "swapped :: ByteString -> PayloadDigest -> ChildConfigDigest -> ByteString -> Either Text (RootedPayloadBinding scope generation)"
            , "swapped edge payload child signature ="
            , "    rootedPayloadBindingKernel edge payload child signature"
            ]
      )
    , ( "RootedRequestDigestTypedInput"
      , unlines
            [ "module RawTextAsRootedRequestDigest (build, RequestDigest) where"
            , ""
            , "import Data.ByteString (ByteString)"
            , "import Data.Text (Text)"
            , "import HostBootstrap.Handoff.Rooted (LifecycleOrdinal, LifecycleSession, LifecycleStage, RequestDigest, rootedDescendResponseUnsignedKernel)"
            , ""
            , "build :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> ByteString -> Either Text ByteString"
            , "build digest = rootedDescendResponseUnsignedKernel digest"
            ]
      )
    , ( "RootedRequestDigestDistinctPayloadInput"
      , unlines
            [ "module PayloadDigestAsRootedRequestDigest (build, PayloadDigest, RequestDigest) where"
            , ""
            , "import Data.ByteString (ByteString)"
            , "import Data.Text (Text)"
            , "import HostBootstrap.Handoff.Rooted (LifecycleOrdinal, LifecycleSession, LifecycleStage, PayloadDigest, RequestDigest, rootedDescendResponseUnsignedKernel)"
            , ""
            , "build :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> ByteString -> Either Text ByteString"
            , "build digest = rootedDescendResponseUnsignedKernel digest"
            ]
      )
    , ( "RootedLifecycleSessionTypedInput"
      , unlines
            [ "module RawTextAsRootedLifecycleSession (build, LifecycleSession) where"
            , ""
            , "import Data.ByteString (ByteString)"
            , "import Data.Text (Text)"
            , "import HostBootstrap.Handoff.Rooted (LifecycleOrdinal, LifecycleSession, LifecycleStage, RequestDigest, rootedDescendResponseUnsignedKernel)"
            , ""
            , "build :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> ByteString -> Either Text ByteString"
            , "build digest path session = rootedDescendResponseUnsignedKernel digest path session"
            ]
      )
    , ( "RootedLifecycleSessionStageTypedInputs"
      , unlines
            [ "module SwapLifecycleSessionStage where"
            , ""
            , "import Data.ByteString (ByteString)"
            , "import Data.Text (Text)"
            , "import HostBootstrap.Handoff.Rooted (LifecycleOrdinal, LifecycleSession, LifecycleStage, RequestDigest, rootedSettledResponseUnsignedKernel)"
            , ""
            , "swapped :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> ByteString -> Either Text ByteString"
            , "swapped digest path session stage ordinal nonce body ="
            , "    rootedSettledResponseUnsignedKernel digest path session stage ordinal nonce body"
            ]
      )
    , ( "RootedLifecycleStageTypedInput"
      , unlines
            [ "module RawTextAsRootedLifecycleStage (build, LifecycleStage) where"
            , ""
            , "import Data.ByteString (ByteString)"
            , "import Data.Text (Text)"
            , "import HostBootstrap.Handoff.Rooted (LifecycleOrdinal, LifecycleSession, LifecycleStage, RequestDigest, rootedSettledResponseUnsignedKernel)"
            , ""
            , "build :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> ByteString -> Either Text ByteString"
            , "build digest path session stage = rootedSettledResponseUnsignedKernel digest path session stage"
            ]
      )
    , ( "RootedLifecycleOrdinalTypedInput"
      , unlines
            [ "module RawWord64AsRootedLifecycleOrdinal (build, LifecycleOrdinal, Word64) where"
            , ""
            , "import Data.ByteString (ByteString)"
            , "import Data.Text (Text)"
            , "import Data.Word (Word64)"
            , "import HostBootstrap.Handoff.Rooted (LifecycleOrdinal, LifecycleSession, LifecycleStage, RequestDigest, rootedDescendResponseUnsignedKernel)"
            , ""
            , "build :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> ByteString -> Either Text ByteString"
            , "build digest path session stage ordinal = rootedDescendResponseUnsignedKernel digest path session stage ordinal"
            ]
      )
    , ( "RootedPredecessorDigestTypedInput"
      , unlines
            [ "module RawTextAsRootedPredecessorDigest (build, PredecessorDigest) where"
            , ""
            , "import Data.ByteString (ByteString)"
            , "import Data.Text (Text)"
            , "import HostBootstrap.Handoff.Rooted (LifecycleOrdinal, LifecycleSession, LifecycleStage, PredecessorDigest, RequestDigest, rootedReceiptRecordedResponseUnsignedKernel)"
            , ""
            , "build :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> PredecessorDigest -> Either Text ByteString"
            , "build digest path session stage ordinal nonce completion ="
            , "    rootedReceiptRecordedResponseUnsignedKernel digest path session stage ordinal nonce completion"
            ]
      )
    , ( "RootedPredecessorDigestDistinctRequestInput"
      , unlines
            [ "module RequestDigestAsRootedPredecessorDigest (build, PredecessorDigest) where"
            , ""
            , "import Data.ByteString (ByteString)"
            , "import Data.Text (Text)"
            , "import HostBootstrap.Handoff.Rooted (LifecycleOrdinal, LifecycleSession, LifecycleStage, PredecessorDigest, RequestDigest, rootedReceiptRecordedResponseUnsignedKernel)"
            , ""
            , "build :: RequestDigest -> [Text] -> LifecycleSession -> LifecycleStage -> LifecycleOrdinal -> ByteString -> PredecessorDigest -> Either Text ByteString"
            , "build digest path session stage ordinal nonce completion ="
            , "    rootedReceiptRecordedResponseUnsignedKernel digest path session stage ordinal nonce completion"
            ]
      )
    , ( "MainCarrierUsesProductionDependency"
      , unlines
            [ "module MainCarrierUsesProductionDependency (retained) where"
            , "import Data.Text (Text)"
            , "import HostBootstrap.Lifecycle.Execution (ResourceCarrier, carriedResourceKeys)"
            , "retained :: ResourceCarrier scope planId -> IO [Text]"
            , "retained = carriedResourceKeys"
            ]
      )
    ]

-- Existing subjects retain their one canonical inventory registration above;
-- these additional context checks reuse their unchanged files.
handoffExistingCompileFailCases :: (FilePath -> NonEmpty String -> result) -> [result]
handoffExistingCompileFailCases rejectsWith =
    [ rejectsWith fixture (handoffHiddenImportDiagnostic moduleName :| [])
    | (fixture, moduleName) <-
        [ ("ImportConfigSchemaInternal.hs", "HostBootstrap.Config.Schema.Internal")
        , ("ImportHandoffReceiverInternal.hs", "HostBootstrap.Handoff.Receiver.Internal")
        , ("ImportHandoffRecovery.hs", "HostBootstrap.Handoff.Recovery")
        , ("ImportHandoffRuntime.hs", "HostBootstrap.Handoff.Runtime")
        , ("ImportLifecycleContextInternal.hs", "HostBootstrap.Lifecycle.Context.Internal")
        , ("ImportAcquisitionJournalAdmission.hs", "HostBootstrap.Lifecycle.Plan")
        , ("ImportLifecycleRooted.hs", "HostBootstrap.Lifecycle.Rooted")
        , ("ImportLifecycleRootedReceipt.hs", "HostBootstrap.Lifecycle.Rooted.Receipt")
        , ("ImportLifecycleRootedPlan.hs", "HostBootstrap.Lifecycle.RootedPlan")
        , ("ImportProjectPlanConstructInternal.hs", "HostBootstrap.ProjectPlan.Construct.Internal")
        , ("ImportProjectPlanProjectionInternal.hs", "HostBootstrap.ProjectPlan.Projection.Internal")
        , ("ImportTeardownInternal.hs", "HostBootstrap.Teardown.Internal")
        ]
    ]

handoffNewCompileFailCases :: (FilePath -> NonEmpty String -> result) -> [result]
handoffNewCompileFailCases rejectsWith =
    [ rejectsWith fixture (handoffHiddenImportDiagnostic moduleName :| [])
    | (fixture, moduleName) <-
        [ ("ImportConfigAuthorityFromHandoffTest.hs", "HostBootstrap.Config.Authority.Internal")
        , ("ImportConfigInstallFromHandoffTest.hs", "HostBootstrap.Config.Install.Native")
        , ("ImportExecutionInternalFromHandoffTest.hs", "HostBootstrap.Lifecycle.Execution.Internal")
        , ("ImportPreparedInternalFromHandoffTest.hs", "HostBootstrap.Lifecycle.Prepared.Internal")
        , ("ImportResourceRecordFromHandoffTest.hs", "HostBootstrap.Lifecycle.ResourceRecord")
        ]
    ]
        <> [ rejectsWith "DataDependencyAsProductionCarrier.hs"
                ( "Note: 'RuntimeDependencyPackage' is defined in 'HostBootstrap.Lifecycle.Dependency.Internal' in package 'hostbootstrap-core-0.1.0.0:lifecycle-dependency-internal' 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal:HostBootstrap.Lifecycle.Dependency.Internal.RuntimeDependencyPackage' is defined in 'HostBootstrap.Lifecycle.Dependency.Internal' in package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'."
                    :| []
                )
           , rejectsWith "RawTextAsRootedPayloadDigest.hs"
                ("Couldn't match expected type 'PayloadDigest' with actual type 'Text'" :| [])
           , rejectsWith "CoerceRootedPayloadDigest.hs"
                ( "Couldn't match representation of type 'Text' with that of 'PayloadDigest' arising from a use of 'coerce' The data constructor 'HostBootstrap.Handoff.Rooted.PayloadDigest' of newtype 'PayloadDigest' is not in scope"
                    :| []
                )
           , rejectsWith "ForgeRootedPayloadDigest.hs"
                ("Illegal term-level use of the type constructor 'PayloadDigest'" :| [])
           , rejectsWith "SwapRootedPayloadDigests.hs"
                ( "Couldn't match expected type 'PayloadDigest' with actual type 'ChildConfigDigest'"
                    :| ["Couldn't match expected type 'ChildConfigDigest' with actual type 'PayloadDigest'"]
                )
           , rejectsWith "CoerceRootedChildConfigDigest.hs"
                ( "Couldn't match representation of type 'Text' with that of 'ChildConfigDigest' arising from a use of 'coerce' The data constructor 'HostBootstrap.Handoff.Rooted.ChildConfigDigest' of newtype 'ChildConfigDigest' is not in scope"
                    :| []
                )
           , rejectsWith "ForgeRootedChildConfigDigest.hs"
                ("Illegal term-level use of the type constructor 'ChildConfigDigest'" :| [])
           , rejectsWith "RawTextAsRootedRequestDigest.hs"
                ("Couldn't match expected type 'RequestDigest' with actual type 'Text'" :| [])
           , rejectsWith "PayloadDigestAsRootedRequestDigest.hs"
                ("Couldn't match expected type 'RequestDigest' with actual type 'PayloadDigest'" :| [])
           , rejectsWith "CoerceRootedRequestDigest.hs"
                ( "Couldn't match representation of type 'Text' with that of 'RequestDigest' arising from a use of 'coerce' The data constructor 'HostBootstrap.Handoff.Rooted.RequestDigest' of newtype 'RequestDigest' is not in scope"
                    :| []
                )
           , rejectsWith "ForgeRootedRequestDigest.hs"
                ("Illegal term-level use of the type constructor 'RequestDigest'" :| [])
           , rejectsWith "RawTextAsRootedLifecycleSession.hs"
                ("Couldn't match expected type 'LifecycleSession' with actual type 'Text'" :| [])
           , rejectsWith "CoerceRootedLifecycleSession.hs"
                ( "Couldn't match representation of type 'Text' with that of 'LifecycleSession' arising from a use of 'coerce' The data constructor 'HostBootstrap.Handoff.Rooted.LifecycleSession' of newtype 'LifecycleSession' is not in scope"
                    :| []
                )
           , rejectsWith "ForgeRootedLifecycleSession.hs"
                ("Illegal term-level use of the type constructor 'LifecycleSession'" :| [])
           , rejectsWith "SwapLifecycleSessionStage.hs"
                ( "Couldn't match expected type 'LifecycleSession' with actual type 'LifecycleStage'"
                    :| ["Couldn't match expected type 'LifecycleStage' with actual type 'LifecycleSession'"]
                )
           , rejectsWith "RawTextAsRootedLifecycleStage.hs"
                ("Couldn't match expected type 'LifecycleStage' with actual type 'Text'" :| [])
           , rejectsWith "CoerceRootedLifecycleStage.hs"
                ( "Couldn't match representation of type 'Text' with that of 'LifecycleStage' arising from a use of 'coerce' The data constructor 'HostBootstrap.Handoff.Rooted.LifecycleStage' of newtype 'LifecycleStage' is not in scope"
                    :| []
                )
           , rejectsWith "ForgeRootedLifecycleStage.hs"
                ("Illegal term-level use of the type constructor 'LifecycleStage'" :| [])
           , rejectsWith "RawWord64AsRootedLifecycleOrdinal.hs"
                ("Couldn't match expected type 'LifecycleOrdinal' with actual type 'Word64'" :| [])
           , rejectsWith "CoerceRootedLifecycleOrdinal.hs"
                ( "Couldn't match representation of type 'Word64' with that of 'LifecycleOrdinal' arising from a use of 'coerce' The data constructor 'HostBootstrap.Handoff.Rooted.LifecycleOrdinal' of newtype 'LifecycleOrdinal' is not in scope"
                    :| []
                )
           , rejectsWith "ForgeRootedLifecycleOrdinal.hs"
                ("Illegal term-level use of the type constructor 'LifecycleOrdinal'" :| [])
           , rejectsWith "RawTextAsRootedPredecessorDigest.hs"
                ("Couldn't match expected type 'PredecessorDigest' with actual type 'Text'" :| [])
           , rejectsWith "RequestDigestAsRootedPredecessorDigest.hs"
                ("Couldn't match expected type 'PredecessorDigest' with actual type 'RequestDigest'" :| [])
           , rejectsWith "CoerceRootedPredecessorDigest.hs"
                ( "Couldn't match representation of type 'Text' with that of 'PredecessorDigest' arising from a use of 'coerce' The data constructor 'HostBootstrap.Handoff.Rooted.PredecessorDigest' of newtype 'PredecessorDigest' is not in scope"
                    :| []
                )
           , rejectsWith "ForgeRootedPredecessorDigest.hs"
                ("Illegal term-level use of the type constructor 'PredecessorDigest'" :| [])
           ]

handoffHiddenImportDiagnostic :: String -> String
handoffHiddenImportDiagnostic moduleName =
    "Could not load module '" <> moduleName
        <> "'. It is a member of the hidden package 'hostbootstrap-core-0.1.0.0:handoff-implementation-internal'."

handoffMainOnlyModules :: [String]
handoffMainOnlyModules =
    [ "HostBootstrap.Config.Authority.Internal"
    , "HostBootstrap.Config.Install.Native"
    , "HostBootstrap.Config.Schema.Internal"
    , "HostBootstrap.Handoff.Receiver.Internal"
    , "HostBootstrap.Handoff.Recovery"
    , "HostBootstrap.Handoff.Runtime"
    , "HostBootstrap.Lifecycle.Context.Internal"
    , "HostBootstrap.Lifecycle.Dependency.Internal"
    , "HostBootstrap.Lifecycle.Execution.Internal"
    , "HostBootstrap.Lifecycle.Plan"
    , "HostBootstrap.Lifecycle.Prepared.Internal"
    , "HostBootstrap.Lifecycle.ResourceRecord"
    , "HostBootstrap.Lifecycle.Rooted"
    , "HostBootstrap.Lifecycle.Rooted.Receipt"
    , "HostBootstrap.Lifecycle.RootedPlan"
    , "HostBootstrap.ProjectPlan.Construct.Internal"
    , "HostBootstrap.ProjectPlan.Projection.Internal"
    , "HostBootstrap.Teardown.Internal"
    ]

actualHandoffModuleMap :: HandoffTestCompiler -> IO [(String, String)]
actualHandoffModuleMap context = do
    (code, output, diagnostic) <-
        compileHandoffSource context "HandoffComponentModuleMap"
            "module HandoffComponentModuleMap (retained) where\nretained :: ()\nretained = ()\n"
            ["-ddump-mod-map"]
    case code of
        ExitFailure _ -> assertFailure ("actual component module-map probe failed:\n" <> output <> diagnostic)
        ExitSuccess -> do
            let actualMap = moduleMapBlocks (output <> "\n" <> diagnostic)
            forM_
                [ "HostBootstrap.Handoff.Protocol", "HostBootstrap.Handoff.Receiver"
                , "HostBootstrap.Handoff.Relay", "HostBootstrap.Handoff.Internal"
                , "HostBootstrap.Handoff.Rooted"
                ] $ \name -> do
                    annotations <- either assertFailure pure $
                        moduleOriginAnnotations name (handoffImplementationUnit context) actualMap
                    assertBool (name <> " lacks the actual selected private origin: " <> show annotations)
                        (moduleOriginSelected annotations)
            dataAnnotations <- either assertFailure pure $
                moduleOriginAnnotations "HostBootstrap.Lifecycle.Dependency.Internal" (handoffDependencyDataUnit context) actualMap
            assertBool "the independent same-name dependency DATA origin is not actually selected"
                (moduleOriginSelected dataAnnotations)
            pure actualMap

-- Module names start records; their indented unit origins and annotations may wrap.
-- We retain the actual body, then parse each unit's complete parenthesized origin.
moduleMapBlocks :: String -> [(String, String)]
moduleMapBlocks = reverse . finish . foldl step (Nothing, []) . lines
  where
    step (current, completed) line = case words line of
        name : rest
            | moduleName name -> (Just (name, unwords rest), finish (current, completed))
        _
            | first : _ <- line, not (isSpace first) -> (Nothing, finish (current, completed))
            | otherwise -> (fmap (\(name, body) -> (name, body <> " " <> line)) current, completed)
    finish (Nothing, completed) = completed
    finish (Just entry, completed) = entry : completed
    moduleName value = case value of
        first : _ -> isUpper first && all (\character -> isAlphaNum character || character `elem` ("._'" :: String)) value
        [] -> False

moduleOriginAnnotations :: String -> String -> [(String, String)] -> Either String [String]
moduleOriginAnnotations name unitId actualMap = do
    body <- case [value | (moduleName, value) <- actualMap, moduleName == name] of
        [value] -> Right value
        values -> Left ("expected one actual module-map record for " <> name <> ", observed " <> show (length values))
    origins <- parseOrigins (unwords (words body))
    case [annotations | (origin, annotations) <- origins, origin == unitId] of
        [annotations] -> Right annotations
        values -> Left ("expected one origin for " <> name <> " in " <> unitId <> ", observed " <> show (length values))
  where
    parseOrigins value = case dropWhile isSpace value of
        [] -> Right []
        remaining -> do
            let (origin, afterOrigin) = break isSpace remaining
            afterOpening <- case dropWhile isSpace afterOrigin of
                '(' : rest -> Right rest
                _ -> Left ("unsupported unit origin in module map for " <> name)
            (annotation, rest) <- closeAnnotation 1 [] afterOpening
            let annotations = map (unwords . words) (commaFields annotation)
            unless (all knownAnnotation annotations)
                (Left ("unsupported origin annotation in module map for " <> name))
            others <- parseOrigins rest
            pure ((origin, annotations) : others)
    closeAnnotation _ _ [] = Left ("unterminated unit origin in module map for " <> name)
    closeAnnotation depth reversed (character : remaining)
        | character == '(' = closeAnnotation (depth + 1) (character : reversed) remaining
        | character == ')' && depth == (1 :: Int) = Right (reverse reversed, remaining)
        | character == ')' = closeAnnotation (depth - 1) (character : reversed) remaining
        | otherwise = closeAnnotation depth (character : reversed) remaining
    commaFields value = case break (== ',') value of
        (field, []) -> [field]
        (field, _ : rest) -> field : commaFields rest
    knownAnnotation annotation =
        annotation `elem` ["hidden module", "unusable module", "hidden package", "exposed package", "package flag"]
            || "reexport by " `isPrefixOf` annotation
            || "hidden reexport by " `isPrefixOf` annotation

moduleOriginSelected :: [String] -> Bool
moduleOriginSelected = any selected
  where
    selected annotation = annotation == "exposed package" || annotation == "package flag"
        || "reexport by " `isPrefixOf` annotation

moduleMapParserCases :: [TestTree]
moduleMapParserCases =
    [ testCase "wrapped package-flag origins remain selected even when the package is hidden" $ do
        let actualMap = moduleMapBlocks "HostBootstrap.One\n    implementation (hidden package,\n                    package flag)\n"
        annotations <- either assertFailure pure (moduleOriginAnnotations "HostBootstrap.One" "implementation" actualMap)
        annotations @?= ["hidden package", "package flag"]
        moduleOriginSelected annotations @?= True
    , testCase "a same-name DATA origin does not expose its hidden production identity" $ do
        let actualMap = moduleMapBlocks "HostBootstrap.One implementation (hidden package)\n    data-unit (exposed package)\n"
        production <- either assertFailure pure (moduleOriginAnnotations "HostBootstrap.One" "implementation" actualMap)
        descriptive <- either assertFailure pure (moduleOriginAnnotations "HostBootstrap.One" "data-unit" actualMap)
        moduleOriginSelected production @?= False
        moduleOriginSelected descriptive @?= True
    , testCase "an exposed reexport differs from a hidden reexport" $ do
        moduleOriginSelected ["hidden package", "reexport by main-unit"] @?= True
        moduleOriginSelected ["hidden package", "hidden reexport by other-unit"] @?= False
    , testCase "origin lookup does not accept another unit with the same prefix" $
        assertLeft (moduleOriginAnnotations "HostBootstrap.One" "implementation"
            (moduleMapBlocks "HostBootstrap.One implementation-extra (hidden package)\n"))
    , testCase "duplicate and incomplete origins refuse instead of becoming hidden evidence" $ do
        assertLeft (moduleOriginAnnotations "HostBootstrap.One" "implementation"
            (moduleMapBlocks "HostBootstrap.One implementation (hidden package) implementation (package flag)\n"))
        assertLeft (moduleOriginAnnotations "HostBootstrap.One" "implementation"
            (moduleMapBlocks "HostBootstrap.One implementation (hidden package\n"))
        assertLeft (moduleOriginAnnotations "HostBootstrap.One" "implementation"
            (moduleMapBlocks "HostBootstrap.One implementation (unrecognized availability)\n"))
    ]

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

verifiedConfigHandoffPairControl :: IO PublicCompiler -> TestTree
verifiedConfigHandoffPairControl getCompiler =
    testCase "config handoff refinement accepts a jointly indexed wire and config" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-config-handoff-pair" $ \directory -> do
            let path = directory </> "CrossVerifiedConfigHandoffPair.hs"
                source = unlines
                    [ "{-# LANGUAGE RankNTypes #-}"
                    , ""
                    , "module CrossVerifiedConfigHandoffPair (retained) where"
                    , ""
                    , "import HostBootstrap.Authority (ProjectVerb)"
                    , "import HostBootstrap.Config.Schema ("
                    , "    ValidatedConfig,"
                    , "    VerifiedConfigWire,"
                    , "    withVerifiedConfigHandoff,"
                    , " )"
                    , "import HostBootstrap.Handoff (HandoffError, VerifiedHandoff)"
                    , ""
                    , "retained ::"
                    , "    ProjectVerb verb ->"
                    , "    VerifiedHandoff scope generation ->"
                    , "    VerifiedConfigWire scope digest configIdA ->"
                    , "    ValidatedConfig scope specDigest configIdA config ->"
                    , "    Either HandoffError ()"
                    , "retained verb handoff wire config ="
                    , "    withVerifiedConfigHandoff verb handoff wire config (\\_ -> ())"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("a matching config handoff pair failed:\n" ++ output ++ diagnostic)

sameBrokerGenerationGrantControl :: IO PublicCompiler -> TestTree
sameBrokerGenerationGrantControl getCompiler =
    testCase "grant issuance accepts a broker and offer from the same generation" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-same-generation-grant" $ \directory -> do
            let path = directory </> "CrossBrokerGenerationGrant.hs"
                source = unlines
                    [ "module CrossBrokerGenerationGrant (grantForeignGeneration) where"
                    , ""
                    , "import HostBootstrap.Handoff"
                    , ""
                    , "grantForeignGeneration ::"
                    , "    RootBroker scope brokerGenerationA verb ->"
                    , "    HandoffOffer scope brokerGenerationA ->"
                    , "    HandoffChallenge ->"
                    , "    IO (Either HandoffError (HandoffGrant scope brokerGenerationA))"
                    , "grantForeignGeneration broker offer challenge ="
                    , "    HostBootstrap.Handoff.grantHandoff broker offer challenge"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("a matching broker-generation grant failed:\n" ++ output ++ diagnostic)

recoveryProjectionGetterControl :: IO PublicCompiler -> TestTree
recoveryProjectionGetterControl getCompiler =
    testCase "public recovery projection input getters remain available" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-recovery-projection-getters" $ \directory -> do
            let path = directory </> "RecoveryProjectionGetterControl.hs"
                source = unlines
                    [ "module RecoveryProjectionGetterControl where"
                    , "import Data.Text (Text)"
                    , "import HostBootstrap.Handoff"
                    , ""
                    , "observe :: RecoveryProjectionBindingInput plan parent child -> (Text, Text, Text)"
                    , "observe value = (requestedRecoveryPlanDigest value, requestedRecoveryParentFrame value, requestedRecoveryChildFrame value)"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public recovery projection getters failed:\n" ++ output ++ diagnostic)

directoryLeasePublicControl :: IO PublicCompiler -> TestTree
directoryLeasePublicControl getCompiler =
    testCase "public directory lease retains scoped acquisition and effect-bearing use" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-directory-lease-public" $ \directory -> do
            let path = directory </> "DirectoryLeasePublicControl.hs"
                source = unlines
                    [ "{-# LANGUAGE RankNTypes #-}"
                    , "module DirectoryLeasePublicControl (acquire, use) where"
                    , "import HostBootstrap.Ownership.Object (OwnershipFault)"
                    , "import HostBootstrap.Ownership.Primitive (OwnershipRow)"
                    , "import HostBootstrap.Ownership.Shipped (ShippedDirectoryLease, ShippedOwnership, withShippedDirectoryLease, useShippedDirectoryLease)"
                    , "acquire :: OwnershipRow -> ShippedOwnership -> IO (Either OwnershipFault (Either OwnershipFault ()))"
                    , "acquire row transaction = withShippedDirectoryLease row transaction (\\lease -> useShippedDirectoryLease lease (pure ()))"
                    , "use :: ShippedDirectoryLease lease -> IO value -> IO (Either OwnershipFault value)"
                    , "use = useShippedDirectoryLease"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public directory lease contract failed:\n" ++ output ++ diagnostic)

storedOriginPublicControl :: IO PublicCompiler -> TestTree
storedOriginPublicControl getCompiler =
    testCase "public stored origin read and both strict re-entry routes remain available" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-stored-origin-public" $ \directory -> do
            let path = directory </> "StoredOriginPublicControl.hs"
                source = unlines
                    [ "{-# LANGUAGE RankNTypes #-}"
                    , "module StoredOriginPublicControl (readBack, kernel, reported, describe) where"
                    , "import HostBootstrap.Ownership.Object (OriginRecord, OwnershipFault)"
                    , "import HostBootstrap.Ownership.Primitive (OwnershipRow, reenterStoredOwnedObject, reenterStoredReportedObject)"
                    , "import HostBootstrap.Ownership.Tape (RecordSubject, StoredOriginRecord, recordTape, readStoredRecordUnder, storedOriginRecord, storedRecordVersion)"
                    , "import HostBootstrap.Protected (ProtectedSession, RecordKey, RecordVersion)"
                    , "readBack :: ProtectedSession session -> RecordSubject -> RecordKey -> IO (Either OwnershipFault (Maybe (StoredOriginRecord session)))"
                    , "readBack session subject = readStoredRecordUnder (recordTape session subject)"
                    , "kernel :: OwnershipRow -> ProtectedSession session -> StoredOriginRecord session -> IO (Either OwnershipFault ())"
                    , "kernel row session stored = reenterStoredOwnedObject row session \"/kernel\" stored (\\_ -> pure (Right ()))"
                    , "reported :: ProtectedSession session -> StoredOriginRecord session -> IO (Either OwnershipFault ())"
                    , "reported session stored = reenterStoredReportedObject session \"/reported\" stored (\\_ -> pure (Right ()))"
                    , "describe :: StoredOriginRecord session -> (OriginRecord, RecordVersion)"
                    , "describe stored = (storedOriginRecord stored, storedRecordVersion stored)"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public stored origin contract failed:\n" ++ output ++ diagnostic)

wallReservationPublicControl :: IO PublicCompiler -> TestTree
wallReservationPublicControl getCompiler =
    testCase "public wall reservation admission and same-reservation authority remain available" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-wall-public-control" $ \directory -> do
            let path = directory </> "WallPublicControl.hs"
                source = unlines
                    [ "{-# LANGUAGE OverloadedStrings #-}"
                    , "module WallPublicControl (admit, restore) where"
                    , "import HostBootstrap.Wsl2.GlobalWall"
                    , "admit :: WallOwner owner -> WallSpec spec -> WallFence fence -> Either WallModelError ()"
                    , "admit owner spec fence = () <$ withWallReservation owner spec \"reservation\" \"receipt\" fence"
                    , "    (\\reservation -> () <$ claimOrResumeWall reservation Nothing)"
                    , "restore :: PersistedWallRecord -> WallAuthority owner spec reservation receipt fence ->"
                    , "    WallReceipt owner spec reservation receipt fence -> RestoreObservation -> Either WallModelError ()"
                    , "restore active authority receipt observation = () <$ beginWallRestore active authority receipt observation"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public wall admission or same-reservation authority failed:\n" ++ output ++ diagnostic)

activationManifestPublicControl :: IO PublicCompiler -> TestTree
activationManifestPublicControl getCompiler =
    testCase "public activation manifest factory and all getters remain available" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-activation-manifest-public" $ \directory -> do
            let path = directory </> "ActivationManifestPublicControl.hs"
                source = unlines
                    [ "{-# LANGUAGE OverloadedStrings #-}"
                    , "module ActivationManifestPublicControl (make, describe) where"
                    , "import Data.Text (Text)"
                    , "import HostBootstrap.Activation"
                    , "    ( ActivationError, ActivationManifest, ActivationManifestInput (..), ActivationSecretDigest"
                    , "    , activationManifest, manifestScope, manifestPlanDigest, manifestSpecDigest"
                    , "    , manifestBinaryDigest, manifestFrame, manifestRevision, manifestConfigDigest"
                    , "    , manifestSecretDigest, manifestService, manifestRolePlanDigest"
                    , "    , manifestPermittedEffects, manifestSecretChannel )"
                    , "make :: ActivationSecretDigest -> Either ActivationError ActivationManifest"
                    , "make secret = activationManifest"
                    , "    (ActivationManifestInput \"Production\" \"plan\" \"spec\" \"binary\" \"frame\" \"revision\""
                    , "        \"config\" secret \"service\" \"roles\" [\"network\"] \"/secret\")"
                    , "describe :: ActivationManifest -> ([Text], ActivationSecretDigest, [Text])"
                    , "describe value ="
                    , "    ( [ manifestScope value, manifestPlanDigest value, manifestSpecDigest value"
                    , "      , manifestBinaryDigest value, manifestFrame value, manifestRevision value"
                    , "      , manifestConfigDigest value, manifestService value, manifestRolePlanDigest value"
                    , "      , manifestSecretChannel value ]"
                    , "    , manifestSecretDigest value, manifestPermittedEffects value )"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public activation manifest factory or getters failed:\n" ++ output ++ diagnostic)

measuredInstancePublicControl :: IO PublicCompiler -> TestTree
measuredInstancePublicControl getCompiler =
    testCase "public measured instance producers, fold and identity remain available" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-measured-instance-public" $ \directory -> do
            let path = directory </> "MeasuredInstancePublicControl.hs"
                source = unlines
                    [ "module MeasuredInstancePublicControl (pod, host, describe, observe) where"
                    , "import Data.Text (Text)"
                    , "import Data.Word (Word64)"
                    , "import HostBootstrap.Activation"
                    , "    ( ActivationError, MeasuredInstance, kubernetesInstance, hostServiceInstance, instanceIdentityText, foldMeasuredInstance )"
                    , "pod :: Text -> Word64 -> Either ActivationError MeasuredInstance"
                    , "pod = kubernetesInstance"
                    , "host :: Text -> Either ActivationError MeasuredInstance"
                    , "host = hostServiceInstance"
                    , "describe :: MeasuredInstance -> Text"
                    , "describe = instanceIdentityText"
                    , "observe :: MeasuredInstance -> Either (Text, Word64) Text"
                    , "observe value = foldMeasuredInstance (\\uid restarts -> Left (uid, restarts)) Right value"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public measured instance producers, fold or identity failed:\n" ++ output ++ diagnostic)

selectedActivationManifestPublicControl :: IO PublicCompiler -> TestTree
selectedActivationManifestPublicControl getCompiler =
    testCase "public selected manifest assignment, elimination and verifier position remain available" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-selected-activation-public" $ \directory -> do
            let path = directory </> "SelectedActivationManifestPublicControl.hs"
                source = unlines
                    [ "module SelectedActivationManifestPublicControl (assign, readBack, verifySelected) where"
                    , "import HostBootstrap.Activation"
                    , "    ( ActivationError, ActivationGrant, ActivationManifest, ActivationVerificationKey"
                    , "    , RuntimeMeasurement, SelectedActivationManifest, selectedActivationManifest"
                    , "    , selectedActivationManifestValue, receivedActivationManifest, verifyRuntimeRoleActivation )"
                    , "import HostBootstrap.Protected (ProtectedStore)"
                    , "assign :: ActivationManifest -> SelectedActivationManifest"
                    , "assign = selectedActivationManifest"
                    , "readBack :: SelectedActivationManifest -> ActivationManifest"
                    , "readBack = selectedActivationManifestValue"
                    , "verifySelected ::"
                    , "    ActivationVerificationKey -> ProtectedStore -> ActivationManifest -> ActivationManifest ->"
                    , "    ActivationGrant -> RuntimeMeasurement -> IO (Either ActivationError ())"
                    , "verifySelected key store manifest received grant measurement ="
                    , "    verifyRuntimeRoleActivation key store (selectedActivationManifest manifest) (receivedActivationManifest received) grant measurement (\\_ -> pure ())"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public selected manifest role failed:\n" ++ output ++ diagnostic)

receivedActivationManifestPublicControl :: IO PublicCompiler -> TestTree
receivedActivationManifestPublicControl getCompiler =
    testCase "public received manifest assignment, elimination and ordered verifier roles remain available" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-received-activation-public" $ \directory -> do
            let path = directory </> "ReceivedActivationManifestPublicControl.hs"
                source = unlines
                    [ "module ReceivedActivationManifestPublicControl (assign, readBack, ordered, fromRaw) where"
                    , "import HostBootstrap.Activation"
                    , "    ( ActivationError, ActivationGrant, ActivationManifest, ActivationVerificationKey, RuntimeMeasurement"
                    , "    , SelectedActivationManifest, ReceivedActivationManifest, selectedActivationManifest"
                    , "    , receivedActivationManifest, receivedActivationManifestValue, verifyRuntimeRoleActivation )"
                    , "import HostBootstrap.Protected (ProtectedStore)"
                    , "assign :: ActivationManifest -> ReceivedActivationManifest"
                    , "assign = receivedActivationManifest"
                    , "readBack :: ReceivedActivationManifest -> ActivationManifest"
                    , "readBack = receivedActivationManifestValue"
                    , "ordered ::"
                    , "    ActivationVerificationKey -> ProtectedStore -> SelectedActivationManifest -> ReceivedActivationManifest ->"
                    , "    ActivationGrant -> RuntimeMeasurement -> IO (Either ActivationError ())"
                    , "ordered key store selected received grant measurement ="
                    , "    verifyRuntimeRoleActivation key store selected received grant measurement (\\_ -> pure ())"
                    , "fromRaw ::"
                    , "    ActivationVerificationKey -> ProtectedStore -> ActivationManifest -> ActivationManifest ->"
                    , "    ActivationGrant -> RuntimeMeasurement -> IO (Either ActivationError ())"
                    , "fromRaw key store selected received grant measurement ="
                    , "    ordered key store (selectedActivationManifest selected) (receivedActivationManifest received) grant measurement"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public received manifest role failed:\n" ++ output ++ diagnostic)

buildProjectNamePublicControl :: IO PublicCompiler -> TestTree
buildProjectNamePublicControl getCompiler =
    testCase "public build project assignment, field, elimination and verifier position remain available" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-build-project-public" $ \directory -> do
            let path = directory </> "BuildProjectNamePublicControl.hs"
                source = unlines
                    [ "module BuildProjectNamePublicControl (assign, readBack, field, update, verifyProject) where"
                    , "import Data.Text (Text)"
                    , "import HostBootstrap.Build"
                    , "    ( BuildBinding (..), BuildProjectName, BuildChannel, BuildError, BuildVerificationKey, CoordinatorDigest, BuildSourceRoot, BuilderPath"
                    , "    , buildProjectNameFromText, buildProjectNameText, buildSpecDigestFromText, buildConfigDigestFromText, verifyBuildInvocation )"
                    , "assign :: Text -> BuildProjectName"
                    , "assign = buildProjectNameFromText"
                    , "readBack :: BuildProjectName -> Text"
                    , "readBack = buildProjectNameText"
                    , "field :: BuildBinding -> BuildProjectName"
                    , "field = buildProjectName"
                    , "update :: BuildProjectName -> BuildBinding -> BuildBinding"
                    , "update project binding = binding{buildProjectName = project}"
                    , "verifyProject ::"
                    , "    BuildVerificationKey -> Text -> Text -> Text -> CoordinatorDigest -> BuildSourceRoot -> BuilderPath ->"
                    , "    BuildChannel -> IO (Either BuildError ())"
                    , "verifyProject key project spec config coordinator sourceRoot builder channel ="
                    , "    verifyBuildInvocation key (buildProjectNameFromText project) (buildSpecDigestFromText spec) (buildConfigDigestFromText config) coordinator sourceRoot builder channel (\\_ _ -> pure ())"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public build project role failed:\n" ++ output ++ diagnostic)

buildSpecDigestPublicControl :: IO PublicCompiler -> TestTree
buildSpecDigestPublicControl getCompiler =
    testCase "public build specification assignment, field, elimination and verifier position remain available" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-build-spec-public" $ \directory -> do
            let path = directory </> "BuildSpecDigestPublicControl.hs"
                source = unlines
                    [ "module BuildSpecDigestPublicControl (assign, readBack, field, update, verifySpec) where"
                    , "import Data.Text (Text)"
                    , "import HostBootstrap.Build"
                    , "    ( BuildBinding (..), BuildProjectName, BuildSpecDigest, BuildChannel, BuildError, BuildVerificationKey, CoordinatorDigest, BuildSourceRoot, BuilderPath"
                    , "    , buildSpecDigestFromText, buildSpecDigestText, buildConfigDigestFromText, verifyBuildInvocation )"
                    , "assign :: Text -> BuildSpecDigest"
                    , "assign = buildSpecDigestFromText"
                    , "readBack :: BuildSpecDigest -> Text"
                    , "readBack = buildSpecDigestText"
                    , "field :: BuildBinding -> BuildSpecDigest"
                    , "field = buildSpecDigest"
                    , "update :: BuildSpecDigest -> BuildBinding -> BuildBinding"
                    , "update spec binding = binding{buildSpecDigest = spec}"
                    , "verifySpec ::"
                    , "    BuildVerificationKey -> BuildProjectName -> Text -> Text -> CoordinatorDigest -> BuildSourceRoot -> BuilderPath ->"
                    , "    BuildChannel -> IO (Either BuildError ())"
                    , "verifySpec key project spec config coordinator sourceRoot builder channel ="
                    , "    verifyBuildInvocation key project (buildSpecDigestFromText spec) (buildConfigDigestFromText config) coordinator sourceRoot builder channel (\\_ _ -> pure ())"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public build specification role failed:\n" ++ output ++ diagnostic)

buildConfigDigestPublicControl :: IO PublicCompiler -> TestTree
buildConfigDigestPublicControl getCompiler =
    testCase "public build config assignment, field, elimination and ordered verifier positions remain available" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-build-config-public" $ \directory -> do
            let path = directory </> "BuildConfigDigestPublicControl.hs"
                source = unlines
                    [ "module BuildConfigDigestPublicControl (assign, readBack, field, update, ordered, fromRaw) where"
                    , "import Data.Text (Text)"
                    , "import HostBootstrap.Build"
                    , "    ( BuildBinding (..), BuildProjectName, BuildSpecDigest, BuildConfigDigest, BuildChannel, BuildError, BuildVerificationKey, CoordinatorDigest, BuildSourceRoot, BuilderPath"
                    , "    , buildConfigDigestFromText, buildConfigDigestText, verifyBuildInvocation )"
                    , "assign :: Text -> BuildConfigDigest"
                    , "assign = buildConfigDigestFromText"
                    , "readBack :: BuildConfigDigest -> Text"
                    , "readBack = buildConfigDigestText"
                    , "field :: BuildBinding -> BuildConfigDigest"
                    , "field = buildConfigDigest"
                    , "update :: BuildConfigDigest -> BuildBinding -> BuildBinding"
                    , "update config binding = binding{buildConfigDigest = config}"
                    , "ordered ::"
                    , "    BuildVerificationKey -> BuildProjectName -> BuildSpecDigest -> BuildConfigDigest ->"
                    , "    CoordinatorDigest -> BuildSourceRoot -> BuilderPath -> BuildChannel -> IO (Either BuildError ())"
                    , "ordered key project spec config coordinator sourceRoot builder channel ="
                    , "    verifyBuildInvocation key project spec config coordinator sourceRoot builder channel (\\_ _ -> pure ())"
                    , "fromRaw ::"
                    , "    BuildVerificationKey -> BuildProjectName -> BuildSpecDigest -> Text ->"
                    , "    CoordinatorDigest -> BuildSourceRoot -> BuilderPath -> BuildChannel -> IO (Either BuildError ())"
                    , "fromRaw key project spec config coordinator sourceRoot builder channel ="
                    , "    ordered key project spec (buildConfigDigestFromText config) coordinator sourceRoot builder channel"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public build config role failed:\n" ++ output ++ diagnostic)

buildIdentifierPublicControl :: IO PublicCompiler -> TestTree
buildIdentifierPublicControl getCompiler =
    testCase "public build identifier assignment, field, elimination and authority description remain available" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-build-identifier-public" $ \directory -> do
            let path = directory </> "BuildIdentifierPublicControl.hs"
                source = unlines
                    [ "module BuildIdentifierPublicControl (assign, readBack, field, update, description) where"
                    , "import Data.Text (Text)"
                    , "import HostBootstrap.Build"
                    , "    ( BuildBinding (..), BuildIdentifier, BuildInvocationAuthority"
                    , "    , buildIdentifierFromText, buildIdentifierText, buildAuthorityBuildId )"
                    , "assign :: Text -> BuildIdentifier"
                    , "assign = buildIdentifierFromText"
                    , "readBack :: BuildIdentifier -> Text"
                    , "readBack = buildIdentifierText"
                    , "field :: BuildBinding -> BuildIdentifier"
                    , "field = buildIdentifier"
                    , "update :: BuildIdentifier -> BuildBinding -> BuildBinding"
                    , "update identifier binding = binding{buildIdentifier = identifier}"
                    , "description :: BuildInvocationAuthority project spec config build source builder -> Text"
                    , "description = buildAuthorityBuildId"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public build identifier role failed:\n" ++ output ++ diagnostic)

buildSourceDigestPublicControl :: IO PublicCompiler -> TestTree
buildSourceDigestPublicControl getCompiler =
    testCase "public build source-digest assignment, field, elimination and authority description remain available" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-build-source-digest-public" $ \directory -> do
            let path = directory </> "BuildSourceDigestPublicControl.hs"
                source = unlines
                    [ "module BuildSourceDigestPublicControl (assign, readBack, field, update, description) where"
                    , "import Data.Text (Text)"
                    , "import HostBootstrap.Build"
                    , "    ( BuildBinding (..), BuildSourceDigest, BuildInvocationAuthority"
                    , "    , buildSourceDigestFromText, buildSourceDigestText, buildAuthoritySourceDigest )"
                    , "assign :: Text -> BuildSourceDigest"
                    , "assign = buildSourceDigestFromText"
                    , "readBack :: BuildSourceDigest -> Text"
                    , "readBack = buildSourceDigestText"
                    , "field :: BuildBinding -> BuildSourceDigest"
                    , "field = buildSourceDigest"
                    , "update :: BuildSourceDigest -> BuildBinding -> BuildBinding"
                    , "update identifier binding = binding{buildSourceDigest = identifier}"
                    , "description :: BuildInvocationAuthority project spec config build source builder -> Text"
                    , "description = buildAuthoritySourceDigest"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public build source-digest role failed:\n" ++ output ++ diagnostic)

coordinatorDigestPublicControl :: IO PublicCompiler -> TestTree
coordinatorDigestPublicControl getCompiler =
    testCase "public build coordinator assignment, field, elimination, signing and verifier positions remain available" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-build-coordinator-public" $ \directory -> do
            let path = directory </> "CoordinatorDigestPublicControl.hs"
                source = unlines
                    [ "module CoordinatorDigestPublicControl (assign, readBack, field, update, ordered, fromRaw, signing) where"
                    , "import Data.Text (Text)"
                    , "import HostBootstrap.Build"
                    , "    ( BuildBinding (..), CoordinatorDigest, BuildSigningKey, BuildVerificationKey, BuildProjectName, BuildSpecDigest, BuildConfigDigest, BuildSourceRoot, BuilderPath, BuildChannel, BuildError"
                    , "    , coordinatorDigestFromText, coordinatorDigestText, withBuildCoordinator, verifyBuildInvocation )"
                    , "assign :: Text -> CoordinatorDigest"
                    , "assign = coordinatorDigestFromText"
                    , "readBack :: CoordinatorDigest -> Text"
                    , "readBack = coordinatorDigestText"
                    , "field :: BuildBinding -> CoordinatorDigest"
                    , "field = buildCoordinatorDigest"
                    , "update :: CoordinatorDigest -> BuildBinding -> BuildBinding"
                    , "update digest binding = binding{buildCoordinatorDigest = digest}"
                    , "ordered ::"
                    , "    BuildVerificationKey -> BuildProjectName -> BuildSpecDigest -> BuildConfigDigest -> CoordinatorDigest ->"
                    , "    BuildSourceRoot -> BuilderPath -> BuildChannel -> IO (Either BuildError ())"
                    , "ordered key project spec config coordinator sourceRoot builder channel ="
                    , "    verifyBuildInvocation key project spec config coordinator sourceRoot builder channel (\\_ _ -> pure ())"
                    , "fromRaw ::"
                    , "    BuildVerificationKey -> BuildProjectName -> BuildSpecDigest -> BuildConfigDigest -> Text ->"
                    , "    BuildSourceRoot -> BuilderPath -> BuildChannel -> IO (Either BuildError ())"
                    , "fromRaw key project spec config coordinator sourceRoot builder channel ="
                    , "    ordered key project spec config (coordinatorDigestFromText coordinator) sourceRoot builder channel"
                    , "signing :: BuildSigningKey -> CoordinatorDigest -> IO ()"
                    , "signing key digest = withBuildCoordinator key digest (\\_ -> pure ())"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public build coordinator role failed:\n" ++ output ++ diagnostic)

builderDigestPublicControl :: IO PublicCompiler -> TestTree
builderDigestPublicControl getCompiler =
    testCase "public builder digest assignment, field and elimination remain available" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-builder-digest-public" $ \directory -> do
            let path = directory </> "BuilderDigestPublicControl.hs"
                source = unlines
                    [ "module BuilderDigestPublicControl (assign, readBack, field, update) where"
                    , "import Data.Text (Text)"
                    , "import HostBootstrap.Build"
                    , "    ( BuildBinding (..), BuilderDigest, builderDigestFromText, builderDigestText )"
                    , "assign :: Text -> BuilderDigest"
                    , "assign = builderDigestFromText"
                    , "readBack :: BuilderDigest -> Text"
                    , "readBack = builderDigestText"
                    , "field :: BuildBinding -> BuilderDigest"
                    , "field = buildBuilderDigest"
                    , "update :: BuilderDigest -> BuildBinding -> BuildBinding"
                    , "update digest binding = binding{buildBuilderDigest = digest}"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public builder digest role failed:\n" ++ output ++ diagnostic)

buildFrameNamePublicControl :: IO PublicCompiler -> TestTree
buildFrameNamePublicControl getCompiler =
    testCase "public build frame assignment, field, elimination and description remain available" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-build-frame-public" $ \directory -> do
            let path = directory </> "BuildFrameNamePublicControl.hs"
                source = unlines
                    [ "module BuildFrameNamePublicControl (assign, readBack, field, update, description) where"
                    , "import Data.Text (Text)"
                    , "import HostBootstrap.Build"
                    , "    ( BuildBinding (..), BuildFrameName, ImageBuildFrame, buildFrameNameFromText, buildFrameNameText, imageBuildFrameName )"
                    , "assign :: Text -> BuildFrameName"
                    , "assign = buildFrameNameFromText"
                    , "readBack :: BuildFrameName -> Text"
                    , "readBack = buildFrameNameText"
                    , "field :: BuildBinding -> BuildFrameName"
                    , "field = buildFrameName"
                    , "update :: BuildFrameName -> BuildBinding -> BuildBinding"
                    , "update name binding = binding{buildFrameName = name}"
                    , "description :: ImageBuildFrame project spec config frame -> Text"
                    , "description = imageBuildFrameName"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public build frame role failed:\n" ++ output ++ diagnostic)

buildSourceRootPublicControl :: IO PublicCompiler -> TestTree
buildSourceRootPublicControl getCompiler =
    testCase "public build source-root assignment, elimination, verifier input and generic measurement remain available" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-build-source-root-public" $ \directory -> do
            let path = directory </> "BuildSourceRootPublicControl.hs"
                source = unlines
                    [ "module BuildSourceRootPublicControl (assign, readBack, ordered, fromRaw, measurement) where"
                    , "import Data.Text (Text)"
                    , "import HostBootstrap.Build"
                    , "    ( BuildSourceRoot, BuilderPath, BuildVerificationKey, BuildProjectName, BuildSpecDigest, BuildConfigDigest, CoordinatorDigest, BuildChannel, BuildError"
                    , "    , buildSourceRootFromFilePath, buildSourceRootFilePath, verifyBuildInvocation, measureSourceDigest )"
                    , "assign :: FilePath -> BuildSourceRoot"
                    , "assign = buildSourceRootFromFilePath"
                    , "readBack :: BuildSourceRoot -> FilePath"
                    , "readBack = buildSourceRootFilePath"
                    , "ordered ::"
                    , "    BuildVerificationKey -> BuildProjectName -> BuildSpecDigest -> BuildConfigDigest -> CoordinatorDigest ->"
                    , "    BuildSourceRoot -> BuilderPath -> BuildChannel -> IO (Either BuildError ())"
                    , "ordered key project spec config coordinator sourceRoot builder channel ="
                    , "    verifyBuildInvocation key project spec config coordinator sourceRoot builder channel (\\_ _ -> pure ())"
                    , "fromRaw ::"
                    , "    BuildVerificationKey -> BuildProjectName -> BuildSpecDigest -> BuildConfigDigest -> CoordinatorDigest ->"
                    , "    FilePath -> BuilderPath -> BuildChannel -> IO (Either BuildError ())"
                    , "fromRaw key project spec config coordinator sourceRoot builder channel ="
                    , "    ordered key project spec config coordinator (buildSourceRootFromFilePath sourceRoot) builder channel"
                    , "measurement :: FilePath -> IO (Either BuildError Text)"
                    , "measurement = measureSourceDigest"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public build source-root role failed:\n" ++ output ++ diagnostic)

builderPathPublicControl :: IO PublicCompiler -> TestTree
builderPathPublicControl getCompiler =
    testCase "public builder-path assignment, elimination, verifier input and generic measurement remain available" $ do
        PublicCompiler compiler compilerArgs <- getCompiler
        withSystemTempDirectory "hostbootstrap-builder-path-public" $ \directory -> do
            let path = directory </> "BuilderPathPublicControl.hs"
                source = unlines
                    [ "module BuilderPathPublicControl (assign, readBack, ordered, fromRaw, measurement) where"
                    , "import Data.Text (Text)"
                    , "import HostBootstrap.Build"
                    , "    ( BuilderPath, BuildSourceRoot, BuildVerificationKey, BuildProjectName, BuildSpecDigest, BuildConfigDigest, CoordinatorDigest, BuildChannel, BuildError"
                    , "    , builderPathFromFilePath, builderPathFilePath, verifyBuildInvocation, measureBinaryDigest )"
                    , "assign :: FilePath -> BuilderPath"
                    , "assign = builderPathFromFilePath"
                    , "readBack :: BuilderPath -> FilePath"
                    , "readBack = builderPathFilePath"
                    , "ordered ::"
                    , "    BuildVerificationKey -> BuildProjectName -> BuildSpecDigest -> BuildConfigDigest -> CoordinatorDigest ->"
                    , "    BuildSourceRoot -> BuilderPath -> BuildChannel -> IO (Either BuildError ())"
                    , "ordered key project spec config coordinator sourceRoot builder channel ="
                    , "    verifyBuildInvocation key project spec config coordinator sourceRoot builder channel (\\_ _ -> pure ())"
                    , "fromRaw ::"
                    , "    BuildVerificationKey -> BuildProjectName -> BuildSpecDigest -> BuildConfigDigest -> CoordinatorDigest ->"
                    , "    BuildSourceRoot -> FilePath -> BuildChannel -> IO (Either BuildError ())"
                    , "fromRaw key project spec config coordinator sourceRoot builder channel ="
                    , "    ordered key project spec config coordinator sourceRoot (builderPathFromFilePath builder) channel"
                    , "measurement :: FilePath -> IO (Either BuildError Text)"
                    , "measurement = measureBinaryDigest"
                    ]
            writeFile path source
            (code, output, diagnostic) <- readProcessWithExitCode compiler (compilerArgs ++ [path]) ""
            case code of
                ExitSuccess -> pure ()
                ExitFailure _ -> assertFailure ("public builder-path role failed:\n" ++ output ++ diagnostic)

transactionDataVocabularyControl :: IO PublicCompiler -> TestTree
transactionDataVocabularyControl getCompiler =
    testCase "the testing unit compiles the existing descriptor DATA fixture" $ do
        (code, output, diagnostic) <- compileFixtureUsing getCompiler "ForgeTransactionPermitFromDescriptor.hs"
        case code of
            ExitSuccess -> pure ()
            ExitFailure _ -> assertFailure ("the testing unit rejected its descriptor DATA vocabulary:\n" ++ output ++ diagnostic)

executionCoreVocabularyControl :: IO PublicCompiler -> TestTree
executionCoreVocabularyControl getCompiler =
    testCase "the private representation unit compiles the actual execution core fixture" $ do
        (code, output, diagnostic) <- compileFixtureUsing getCompiler "ImportLifecycleExecutionCore.hs"
        case code of
            ExitSuccess -> pure ()
            ExitFailure _ -> assertFailure ("the production representation unit rejected its execution core:\n" ++ output ++ diagnostic)

runtimeCoreVocabularyControl :: IO PublicCompiler -> TestTree
runtimeCoreVocabularyControl getCompiler =
    testCase "the private representation unit compiles the actual runtime core fixture" $ do
        (code, output, diagnostic) <- compileFixtureUsing getCompiler "ImportLifecycleRuntimeCore.hs"
        case code of
            ExitSuccess -> pure ()
            ExitFailure _ -> assertFailure ("the production representation unit rejected its runtime core:\n" ++ output ++ diagnostic)

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
The representation controls likewise select only the production representation
unit, so its nominal-role checks cannot be masked by a hidden-package failure.
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

resolveRepresentationCompiler :: CompilerPaths -> IO PublicCompiler
resolveRepresentationCompiler paths@(CompilerPaths _ localPackageDb _) = do
    representationConf <-
        uniqueRegistration localPackageDb "lifecycle-representation-internal" $ \name ->
            "hostbootstrap-core-" `isPrefixOf` name
                && "-inplace-lifecycle-representation-internal.conf" `isSuffixOf` name
    registration <- readFile (localPackageDb </> representationConf)
    representationUnit <- case SourceGuard.fieldValues "id" registration of
        [unitId] -> pure unitId
        observed ->
            fail ("expected exactly one representation-unit id in " ++ representationConf ++ ", observed " ++ show observed)
    pure (compilerForUnit paths representationUnit)

resolveOwnershipCompiler :: CompilerPaths -> IO PublicCompiler
resolveOwnershipCompiler paths@(CompilerPaths _ localPackageDb _) = do
    ownershipConf <-
        uniqueRegistration localPackageDb "ownership-internal" $ \name ->
            "hostbootstrap-core-" `isPrefixOf` name
                && "-inplace-ownership-internal.conf" `isSuffixOf` name
    registration <- readFile (localPackageDb </> ownershipConf)
    ownershipUnit <- case SourceGuard.fieldValues "id" registration of
        [unitId] -> pure unitId
        observed -> fail ("expected exactly one ownership-unit id in " ++ ownershipConf ++ ", observed " ++ show observed)
    pure (compilerForUnit paths ownershipUnit)

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
