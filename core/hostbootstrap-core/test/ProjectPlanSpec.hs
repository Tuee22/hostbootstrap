{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module ProjectPlanSpec (tests) where

import qualified Crypto.Hash as Hash
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Char (isSpace, ord)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (intercalate, isInfixOf, isPrefixOf, sort, stripPrefix)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import qualified Fixture
import HostBootstrap.Authority
    ( AuthorityError (AuthorityMalformedBinding)
    , InstalledProjectIdentity
    , ProjectVerb (ProjectUp)
    , RootInvocationAuthority
    , VerbUp
    , brokerEpochWord
    , installedProjectName
    , rootAuthorityEpoch
    , rootScopeAuthority
    )
import HostBootstrap.Config.Class
    ( ProjectCfg (withProductionProjectCodec)
    , ProjectCodec
    , projectCodecSpecDigest
    )
import HostBootstrap.Config.Fields (ScopeKind (ProductionScope))
import HostBootstrap.Config.Schema
    ( ValidatedConfig
    , renderScopedProjectConfigBytes
    , validatedConfigDigest
    , validatedConfigSpecDigest
    , validatedConfigValue
    , withValidatedConfig
    , withAuthenticatedConfigWire
    , withVerifiedConfigHandoff
    )
import HostBootstrap.Config.Vocab (Production)
import qualified HostBootstrap.Config.Vocab as V
import qualified HostBootstrap.Context as Context
import HostBootstrap.DocValidator (findRepoRoot)
import HostBootstrap.Handoff
    ( HandoffBindingInput (..)
    , HandoffPayloadKind (NarrowedProjectConfig)
    , childConfigDigest
    , freshChallenge
    , grantHandoff
    , handoffOfferWire
    , mkHandoffOffer
    , productionHandoffScope
    , projectSigningKeyFromBytes
    , registerHandoffEdge
    , relayBinding
    , rootBrokerVerificationKey
    , verifiedConfigPayload
    , verifyHandoff
    , withRootBroker
    )
import HostBootstrap.Lifecycle.Mode
    ( LifecycleProfile
    , ModeError (ModeAuthorityFailure, ModeEvidenceMismatch, ModeSnapshotMismatch)
    , RecoveredProductionLifecycleProfile
    , UnboundRunLease
    , VerifiedPlanSnapshot
    , planSnapshotCanonicalBytes
    , planSnapshotPlanDigest
    , planSnapshotSpecDigest
    , productionActiveMode
    , productionRootAuthority
    , productionRootModeLease
    , productionRootUnboundLease
    , recoveredProductionProfileCanonicalBytes
    , recoveredProductionProfileConfigDigest
    , recoveredProductionProfilePlanDigest
    , recoveredProductionProfileSpecDigest
    , unboundRunLeaseRunText
    , withRecoveredProductionLifecycleProfile
    , withProductionLifecycleProfile
    , withProductionRoot
    )
import HostBootstrap.ProjectPlan
    ( PlanDraft
    , PlanError (..)
    , PlannedResourceKind
        ( ClusterResourceKind
        , DockerResourceKind
        , DurableShareResourceKind
        , MinioResourceKind
        , ProviderResourceKind
        , RegistryResourceKind
        )
    , ProjectPlan
    , StablePlanSnapshot
    , forward
    , planDraftsFromValidatedBuilder
    , plannedStepDependencyOperations
    , plannedStepFrameId
    , plannedStepOperationKey
    , plannedStepProjectedOperationKeys
    , plannedEdgeDependencyKey
    , plannedEdgeTargetKey
    , plannedResourceFrame
    , plannedResourceKey
    , operationKeyText
    , renderSnapshot
    , stablePlanSnapshotBytes
    , stablePlanSnapshotConfigDigest
    , stablePlanSnapshotDigest
    , stablePlanSnapshotFormatVersion
    , stablePlanSnapshotRoot
    , stablePlanSnapshotSpecDigest
    , topology
    , topologyContainsFrame
    , topologyDescentEdges
    , topologyDescentFrom
    , topologyFrameLabel
    , topologyFrameOrder
    , topologyParentEdges
    , topologyParentFrame
    , withPlannedEdge
    , withPlannedResourceOfKind
    , withPlannedStepGuestAliasProjection
    , withPlannedStepResourceOfKind
    , withProviderGuestAliasProjection
    )
import HostBootstrap.ProjectPlan.Construct
    ( FinalizedProjectSpec
    , finalizedProjectCodec
    , finalizedProjectServices
    , projectPlanDrafts
    , projectPlanStepPlan
    , childPlanAuthorityBinding
    , withChildProjectPlan
    , withFinalizedProjectSpec
    , withHarnessFinalizedProjectSpec
    , withProjectPlan
    , withRecoveredProductionProjectPlan
    , withRecoveredProductionProjectPlanInputs
    )
import HostBootstrap.ProjectPlan.Snapshot
    ( BoundPlanSnapshot
    , PlanDigestBinding
    , SnapshotError (SnapshotVerificationError)
    , boundPlanSnapshotBytes
    , withBoundPlanSnapshot
    , withFreshBoundPlanSnapshot
    , withPlanDigestBinding
    , withPersistedPlanSnapshot
    )
import HostBootstrap.ProjectRoot
    ( CanonicalProjectRoot
    , canonicalProjectRootPath
    , withCanonicalProjectRoot
    )
import HostBootstrap.Protected
    ( Expectation (ExpectAbsent)
    , ProtectedRecord
    , ProtectedStore
    , RecordKey
    , compareAndSwapProtectedRecord
    , listProtectedRecords
    , mkRecordKey
    , openProtectedStore
    , readProtectedRecord
    , withProtectedEntry
    )
import HostBootstrap.RoleLifecycle (DeclaredEffects (NoEffects))
import HostBootstrap.Lift (localContext)
import HostBootstrap.Service
    ( ServiceRegistry
    , finalizedServiceVariantNames
    , serviceDefinition
    , serviceId
    , singletonServiceRegistry
    )
import HostBootstrap.Step
    ( CoreStepId (ContextInitId)
    , ReversePolicy (PreserveOnReverse)
    , Step
    , StepFrame (StepFrame)
    , StepIdentity (CoreStepIdentity)
    , StepObservation (StepChanged, StepUnchanged)
    , StepPlan
    , StepPlanError (..)
    , contextInitStep
    , copySourceStep
    , descendsVia
    , deployKindStep
    , deployVMStep
    , ensureStep
    , mkStepPlan
    , postHandoffStep
    , projectStep
    , projectStepId
    , projectsOperation
    , stepPlanSteps
    )
import qualified SourceGuard
import System.Directory (doesDirectoryExist, getCurrentDirectory, listDirectory)
import System.FilePath
    ( dropExtension
    , makeRelative
    , splitDirectories
    , takeExtension
    , (</>)
    )
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit
    ( assertBool
    , assertFailure
    , testCase
    , (@?=)
    )
import Unsafe.Coerce (unsafeCoerce)

tests :: TestTree
tests =
    testGroup
        "indexed project-plan foundation"
        [ testCase "Production and exact Harness runs jointly finalize one static project definition" $
            Fixture.withFixtureHarnessAuthority $ \(_project :: InstalledProjectIdentity projectId) authority ->
                withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \baseCodec ->
                    withFinalizedProjectSpec
                        ProductionScope
                        baseCodec
                        fixtureServiceRegistry
                        (\_ _ -> Right singletonPlan)
                        ( \productionSpec ->
                            withSystemTempDirectory "hostbootstrap-finalized-project-spec" $ \directory -> do
                                productionDigest <-
                                    exerciseFinalizedSpec
                                        productionSpec
                                        directory
                                        ( Fixture.defaultProjectConfig
                                            "finalized-production"
                                            (Text.pack directory)
                                            Context.HostOrchestrator
                                        )
                                harnessDigest <-
                                    withHarnessFinalizedProjectSpec
                                        (V.harnessConfigAuthority authority)
                                        productionSpec
                                        ( \harnessSpec ->
                                            exerciseFinalizedSpec
                                                harnessSpec
                                                directory
                                                ( Fixture.defaultProjectConfig
                                                    "finalized-harness"
                                                    (Text.pack directory)
                                                    Context.TestHarness
                                                )
                                        )
                                assertBool
                                    "Production and Harness codec families receive distinct final specification digests"
                                    (productionDigest /= harnessDigest)
                        )
        , testCase "the draft builder receives the exact root and validated value" $
            withFoundation $ \_codec profile root config -> do
                let expectedRoot = canonicalProjectRootPath root
                    expectedConfig = validatedConfigValue config
                    build seenRoot seenConfig
                        | canonicalProjectRootPath seenRoot /= expectedRoot = Left EmptyStepPlan
                        | seenConfig /= expectedConfig = Left EmptyStepPlan
                        | otherwise = Right singletonPlan
                drafts <- expectRight (planDraftsFromValidatedBuilder root config build)
                expectPlanAccepted (withProjectPlan profile root config drafts (const ()))
        , testCase "fresh admission accepts the same authoritative graph deterministically" $
            withFoundation $ \_codec profile root config -> do
                drafts <- draftsFor root config singletonPlan
                expectPlanAccepted (withProjectPlan profile root config drafts (const ()))
                expectPlanAccepted (withProjectPlan profile root config drafts (const ()))
        , testCase "an authenticated config edge jointly admits the exact child plan and authority" $
            withSnapshotPlan singletonPlan $
                \store project rootAuthority _unbound spec root parentConfig _parentDrafts parentPlan -> do
                    let codec = finalizedProjectCodec spec
                        payload =
                            renderScopedProjectConfigBytes
                                codec
                                (validatedConfigValue parentConfig)
                        planDigest = stablePlanSnapshotDigest (renderSnapshot parentPlan)
                        input =
                            HandoffBindingInput
                                { requestedSpecDigest = validatedConfigSpecDigest parentConfig
                                , requestedPayloadKind = NarrowedProjectConfig
                                , requestedPlanRevision = planDigest
                                , requestedParentFrame = "parent-frame"
                                , requestedChildFrame = "host"
                                , requestedChildConfigDigest = childConfigDigest payload
                                , requestedPhase = "execute"
                                }
                    signingKey <-
                        expectRight
                            (projectSigningKeyFromBytes (ByteString.replicate 32 201))
                    brokered <-
                        withRootBroker
                            (productionHandoffScope project)
                            store
                            signingKey
                            rootAuthority
                            ( \broker -> do
                                (relay, token) <- expectRight =<< registerHandoffEdge broker input
                                offer <- expectRight (mkHandoffOffer relay payload token)
                                challenge <- freshChallenge
                                grant <- expectRight =<< grantHandoff broker offer challenge
                                handoff <-
                                    expectRight
                                        ( verifyHandoff
                                            (rootBrokerVerificationKey broker)
                                            (handoffOfferWire offer)
                                            (relayBinding relay)
                                            challenge
                                            grant
                                        )
                                authenticated <- expectRight (verifiedConfigPayload handoff)
                                configAdmission <-
                                    withAuthenticatedConfigWire codec authenticated $ \wire childConfig -> do
                                        childDrafts <- expectRight (projectPlanDrafts spec root childConfig)
                                        refined <-
                                            expectRight
                                                ( withVerifiedConfigHandoff
                                                    ProjectUp
                                                    handoff
                                                    wire
                                                    childConfig
                                                    ( \configHandoff ->
                                                        withChildProjectPlan
                                                            ProjectUp
                                                            configHandoff
                                                            wire
                                                            childConfig
                                                            childDrafts
                                                            ( \authority childPlan _digestBinding -> do
                                                                childPlanAuthorityBinding authority
                                                                    @?= relayBinding relay
                                                                stablePlanSnapshotDigest (renderSnapshot childPlan)
                                                                    @?= planDigest
                                                            )
                                                    )
                                                )
                                        expectRight refined
                                _ <- expectRight configAdmission
                                pure ()
                            )
                    _ <- expectRight brokered
                    pure ()
        , testCase "child admission refuses a signed revision other than the stable child plan digest" $
            withSnapshotPlan singletonPlan $
                \store project rootAuthority _unbound spec root parentConfig _parentDrafts parentPlan -> do
                    let codec = finalizedProjectCodec spec
                        payload =
                            renderScopedProjectConfigBytes
                                codec
                                (validatedConfigValue parentConfig)
                        childPlanDigest = stablePlanSnapshotDigest (renderSnapshot parentPlan)
                        signedRevision = "signed-but-not-the-child-plan"
                        input =
                            HandoffBindingInput
                                { requestedSpecDigest = validatedConfigSpecDigest parentConfig
                                , requestedPayloadKind = NarrowedProjectConfig
                                , requestedPlanRevision = signedRevision
                                , requestedParentFrame = "parent-frame"
                                , requestedChildFrame = "host"
                                , requestedChildConfigDigest = childConfigDigest payload
                                , requestedPhase = "execute"
                                }
                    assertBool
                        "the negative fixture uses a different signed revision"
                        (signedRevision /= childPlanDigest)
                    signingKey <-
                        expectRight
                            (projectSigningKeyFromBytes (ByteString.replicate 32 202))
                    brokered <-
                        withRootBroker
                            (productionHandoffScope project)
                            store
                            signingKey
                            rootAuthority
                            ( \broker -> do
                                (relay, token) <- expectRight =<< registerHandoffEdge broker input
                                offer <- expectRight (mkHandoffOffer relay payload token)
                                challenge <- freshChallenge
                                grant <- expectRight =<< grantHandoff broker offer challenge
                                handoff <-
                                    expectRight
                                        ( verifyHandoff
                                            (rootBrokerVerificationKey broker)
                                            (handoffOfferWire offer)
                                            (relayBinding relay)
                                            challenge
                                            grant
                                        )
                                authenticated <- expectRight (verifiedConfigPayload handoff)
                                configAdmission <-
                                    withAuthenticatedConfigWire codec authenticated $ \wire childConfig -> do
                                        childDrafts <- expectRight (projectPlanDrafts spec root childConfig)
                                        expectRight
                                            ( withVerifiedConfigHandoff
                                                ProjectUp
                                                handoff
                                                wire
                                                childConfig
                                                ( \configHandoff ->
                                                    withChildProjectPlan
                                                        ProjectUp
                                                        configHandoff
                                                        wire
                                                        childConfig
                                                        childDrafts
                                                        (\_authority _childPlan _digestBinding -> ())
                                                )
                                            )
                                refused <- expectRight configAdmission
                                case refused of
                                    Left (AuthorityMalformedBinding detail) ->
                                        assertBool
                                            "the refusal identifies the stable plan digest"
                                            ("stable plan digest" `Text.isInfixOf` detail)
                                    other ->
                                        assertFailure
                                            ( "expected a signed-revision child-plan refusal, got "
                                                <> show other
                                            )
                            )
                    _ <- expectRight brokered
                    pure ()
        , testCase "admission rejects drafts stamped by another canonical root" $
            withFoundation $ \_codec profile root config -> do
                drafts <- draftsFor root config singletonPlan
                withSystemTempDirectory "hostbootstrap-project-plan-other-root" $ \otherRootPath -> do
                    rooted <-
                        withCanonicalProjectRoot
                            (otherRootPath </> "fixture.dhall")
                            otherRootPath
                            ( \otherRoot ->
                                pure
                                    ( canonicalProjectRootPath otherRoot
                                    , withProjectPlan
                                        profile
                                        otherRoot
                                        config
                                        drafts
                                        (const ())
                                    )
                            )
                    (expectedRoot, outcome) <- either (fail . show) pure rooted
                    case outcome of
                        Left (PlanDraftRootMismatch expected observed) -> do
                            expected @?= expectedRoot
                            observed @?= canonicalProjectRootPath root
                        other -> assertFailure ("expected a root mismatch, got " <> show other)
        , testCase "admission rejects drafts from another validated config identity" $
            withFoundation $ \codec profile root config -> do
                drafts <- draftsFor root config singletonPlan
                let replacement =
                        Fixture.defaultProjectConfig
                            "different-project"
                            "/different-root"
                            Context.HostOrchestrator
                validated <-
                    withValidatedConfig codec replacement $ \_wire otherConfig ->
                        pure (withProjectPlan profile root otherConfig drafts (const ()))
                outcome <- either fail pure validated
                case outcome of
                    Left (PlanDraftConfigurationMismatch _ _) -> pure ()
                    other -> assertFailure ("expected a config mismatch, got " <> show other)
        , testCase "admission revalidates duplicate node and resource identities" $
            withFoundation $ \_codec profile root config -> do
                drafts <- draftsFor root config singletonPlan
                let outcome = withProjectPlan profile root config (drafts <> drafts) (const ())
                outcome
                    @?= Left
                        ( InvalidProjectPlan
                            (DuplicateStepIdentities [CoreStepIdentity ContextInitId])
                        )
        , testCase "admission rejects a frame whose parent has no descent" $
            withFoundation $ \_codec profile root config -> do
                hostDrafts <- draftsFor root config singletonPlan
                guestDrafts <- draftsFor root config guestOnlyPlan
                withProjectPlan profile root config (hostDrafts <> guestDrafts) (const ())
                    @?= Left (InvalidProjectPlan (MissingFrameDescent "host"))
        , testCase "admission rejects conflicting declarations for one frame identity" $
            withFoundation $ \_codec profile root config -> do
                hostDrafts <- draftsFor root config singletonPlan
                relabelledDrafts <- draftsFor root config relabelledHostPlan
                withProjectPlan profile root config (hostDrafts <> relabelledDrafts) (const ())
                    @?= Left
                        ( InvalidProjectPlan
                            (ConflictingFrameLabels "host" ["Host", "Relabelled host"])
                        )
        , testCase "admission rejects normal work placed after a handoff suffix" $
            withFoundation $ \_codec profile root config -> do
                handoffDrafts <- draftsFor root config hostWithPostHandoffPlan
                guestDrafts <- draftsFor root config guestOnlyPlan
                withProjectPlan profile root config (handoffDrafts <> guestDrafts) (const ())
                    @?= Left (InvalidProjectPlan (PostHandoffBeforeDescentComplete 3))
        , testCase "forward is non-empty and preserves exact admitted dependency order" $
            withFoundation $ \_codec profile root config ->
                withAdmittedProjectPlan profile root config topologyFixturePlan $ \plan -> do
                    let projected = forward plan
                        nodes = NonEmpty.toList projected
                    NonEmpty.length projected @?= 2
                    map (Text.pack . operationKeyText . plannedStepOperationKey) nodes
                        @?= ["core:context-init", "core:ensure-ghc"]
                    map plannedStepFrameId nodes @?= ["host", "guest"]
                    map
                        ( map
                            (\(operation, frame) -> (Text.pack (operationKeyText operation), frame))
                            . plannedStepDependencyOperations
                        )
                        nodes
                        @?= [[], [("core:context-init", "host")]]
        , testCase "the closed resource relation projects all six admitted families" $
            withFoundation $ \_codec profile root config ->
                withAdmittedProjectPlan profile root config closedResourceFamilyPlan $ \plan ->
                    case NonEmpty.toList (forward plan) of
                        [providerNode, shareNode, dockerNode, minioNode, registryNode, clusterNode] ->
                            sequence
                                [ withPlannedResourceOfKind
                                    plan
                                    ProviderResourceKind
                                    (plannedStepOperationKey providerNode)
                                    plannedResourceKey
                                , withPlannedResourceOfKind
                                    plan
                                    DurableShareResourceKind
                                    (plannedStepOperationKey shareNode)
                                    plannedResourceKey
                                , withPlannedResourceOfKind
                                    plan
                                    DockerResourceKind
                                    (plannedStepOperationKey dockerNode)
                                    plannedResourceKey
                                , withPlannedResourceOfKind
                                    plan
                                    MinioResourceKind
                                    (plannedStepOperationKey minioNode)
                                    plannedResourceKey
                                , withPlannedResourceOfKind
                                    plan
                                    RegistryResourceKind
                                    (plannedStepOperationKey registryNode)
                                    plannedResourceKey
                                , withPlannedResourceOfKind
                                    plan
                                    ClusterResourceKind
                                    (plannedStepOperationKey clusterNode)
                                    plannedResourceKey
                                ]
                                @?= Right
                                    [ "core:deploy-vm"
                                    , "core:copy-source"
                                    , "core:ensure-docker"
                                    , "project:deploy-minio"
                                    , "project:deploy-registry"
                                    , "core:deploy-kind"
                                    ]
                        other -> assertFailure ("expected six resource nodes, got " <> show (length other))
        , testCase "resource projection refuses wrong kinds, absent keys, and reversed edges" $
            withFoundation $ \_codec profile root config -> do
                providerKey <-
                    withAdmittedProjectPlan profile root config resourceProjectionPlan $ \plan ->
                        pure (plannedStepOperationKey (NonEmpty.head (forward plan)))
                withAdmittedProjectPlan profile root config singletonPlan $ \plan ->
                    withPlannedResourceOfKind
                        plan
                        ProviderResourceKind
                        providerKey
                        (const ())
                        @?= Left (PlanResourceOperationMissing "core:deploy-vm")
                withAdmittedProjectPlan profile root config resourceProjectionPlan $ \plan ->
                    case NonEmpty.toList (forward plan) of
                        [providerNode, shareNode, _clusterNode] -> do
                            withPlannedResourceOfKind
                                plan
                                ClusterResourceKind
                                (plannedStepOperationKey providerNode)
                                (const ())
                                @?= Left (PlanResourceKindMismatch "core:deploy-vm" "cluster")
                            let reversedEdge =
                                    joinPlan $
                                        withPlannedResourceOfKind
                                            plan
                                            ProviderResourceKind
                                            (plannedStepOperationKey providerNode)
                                            ( \provider ->
                                                joinPlan $
                                                    withPlannedResourceOfKind
                                                        plan
                                                        DurableShareResourceKind
                                                        (plannedStepOperationKey shareNode)
                                                        ( \share ->
                                                            withPlannedEdge plan provider share (const ())
                                                        )
                                            )
                            reversedEdge
                                @?= Left
                                    ( PlanDependencyEdgeMissing
                                        "core:deploy-vm"
                                        "core:copy-source"
                                    )
                        other -> assertFailure ("expected three projected nodes, got " <> show (length other))
        , testCase "closed resource families and edges project only from the exact plan" $
            withFoundation $ \_codec profile root config ->
                withAdmittedProjectPlan profile root config resourceProjectionPlan $ \plan ->
                    case NonEmpty.toList (forward plan) of
                        [providerNode, shareNode, _clusterNode] -> do
                            let projected =
                                    joinPlan $
                                        withPlannedResourceOfKind
                                            plan
                                            ProviderResourceKind
                                            (plannedStepOperationKey providerNode)
                                            ( \provider ->
                                                joinPlan $
                                                    withPlannedResourceOfKind
                                                        plan
                                                        DurableShareResourceKind
                                                        (plannedStepOperationKey shareNode)
                                                        ( \share ->
                                                            withPlannedEdge plan share provider $ \edge ->
                                                                ( plannedResourceKey provider
                                                                , plannedResourceFrame provider
                                                                , plannedResourceKey share
                                                                , plannedResourceFrame share
                                                                , plannedEdgeTargetKey edge
                                                                , plannedEdgeDependencyKey edge
                                                                )
                                                        )
                                            )
                            projected
                                @?= Right
                                    ( "core:deploy-vm"
                                    , "host"
                                    , "core:copy-source"
                                    , "provider"
                                    , "core:copy-source"
                                    , "core:deploy-vm"
                                    )
                        other -> assertFailure ("expected three projected nodes, got " <> show (length other))
        , testCase "a PlannedStep reaches only its own resource and dependency prefix" $
            withFoundation $ \_codec profile root config ->
                withAdmittedProjectPlan profile root config resourceProjectionPlan $ \plan ->
                    case NonEmpty.toList (forward plan) of
                        [providerNode, shareNode, clusterNode] -> do
                            let localAlias =
                                    joinPlan $
                                        withPlannedStepResourceOfKind
                                            shareNode
                                            ProviderResourceKind
                                            (plannedStepOperationKey providerNode)
                                            ( \provider ->
                                                joinPlan $
                                                    withPlannedStepResourceOfKind
                                                        shareNode
                                                        DurableShareResourceKind
                                                        (plannedStepOperationKey shareNode)
                                                        ( \share ->
                                                            withPlannedStepGuestAliasProjection
                                                                shareNode
                                                                provider
                                                                share
                                                                (\alias edge -> (plannedResourceKey alias, plannedEdgeDependencyKey edge))
                                                        )
                                            )
                                laterResource =
                                    withPlannedStepResourceOfKind
                                        shareNode
                                        ClusterResourceKind
                                        (plannedStepOperationKey clusterNode)
                                        (const ())
                            localAlias
                                @?= Right
                                    ( "core:deploy-vm/core:copy-source/guest-alias"
                                    , "core:copy-source"
                                    )
                            laterResource
                                @?= Left (PlanNodeResourceOutsidePrefix "core:deploy-kind")
                        other -> assertFailure ("expected three projected nodes, got " <> show (length other))
        , testCase "provider guest alias projection requires the share node declaration" $
            withFoundation $ \_codec profile root config ->
                withAdmittedProjectPlan profile root config unprojectedResourcePlan $ \plan ->
                    case NonEmpty.toList (forward plan) of
                        [providerNode, shareNode, _clusterNode] -> do
                            let projected =
                                    joinPlan $
                                        withPlannedResourceOfKind
                                            plan
                                            ProviderResourceKind
                                            (plannedStepOperationKey providerNode)
                                            ( \provider ->
                                                joinPlan $
                                                    withPlannedResourceOfKind
                                                        plan
                                                        DurableShareResourceKind
                                                        (plannedStepOperationKey shareNode)
                                                        ( \share ->
                                                            withProviderGuestAliasProjection
                                                                plan
                                                                provider
                                                                share
                                                                (\_ _ -> ())
                                                        )
                                            )
                            projected
                                @?= Left
                                    ( PlanProjectedOperationMissing
                                        "core:deploy-vm/core:copy-source/guest-alias"
                                    )
                        other -> assertFailure ("expected three projected nodes, got " <> show (length other))
        , testCase "topology retains ordered membership and matching parent/descent edges" $
            withFoundation $ \_codec profile root config ->
                withAdmittedProjectPlan profile root config topologyFixturePlan $ \plan -> do
                    let derived = topology plan
                    topologyFrameOrder derived
                        @?= NonEmpty.fromList
                            [("host", "Host"), ("guest", "Guest")]
                    topologyParentEdges derived @?= [("host", "guest")]
                    topologyDescentEdges derived
                        @?= [("host", "guest", localContext)]
                    topologyContainsFrame derived "host" @?= True
                    topologyContainsFrame derived "absent" @?= False
                    topologyFrameLabel derived "guest" @?= Just "Guest"
                    topologyParentFrame derived "host" @?= Nothing
                    topologyParentFrame derived "guest" @?= Just "host"
                    topologyDescentFrom derived "host"
                        @?= Just ("guest", localContext)
                    topologyDescentFrom derived "guest" @?= Nothing
        , testCase "renderSnapshot is deterministic across fresh local plan identities" $
            withFoundation $ \_codec profile root config -> do
                first <- snapshotFor profile root config topologyFixturePlan
                second <- snapshotFor profile root config topologyFixturePlan
                first @?= second
        , testCase "stable snapshot accessors expose exact admitted identities and derived digest" $
            withFoundation $ \_codec profile root config -> do
                snapshot <- snapshotFor profile root config topologyFixturePlan
                stablePlanSnapshotFormatVersion snapshot @?= 3
                stablePlanSnapshotRoot snapshot
                    @?= canonicalProjectRootPath root
                stablePlanSnapshotSpecDigest snapshot
                    @?= validatedConfigSpecDigest config
                stablePlanSnapshotConfigDigest snapshot
                    @?= validatedConfigDigest config
                stablePlanSnapshotDigest snapshot
                    @?= ( validatedConfigSpecDigest config
                            <> ":"
                            <> sha256Text (stablePlanSnapshotBytes snapshot)
                        )
        , testCase "coordinated canonical-root and draft substitution changes the stable snapshot" $
            withFoundation $ \_codec profile root config -> do
                original <- snapshotFor profile root config singletonPlan
                withSystemTempDirectory "hostbootstrap-project-plan-other-canonical-root" $ \directory -> do
                    rooted <-
                        withCanonicalProjectRoot
                            (directory </> "fixture.dhall")
                            directory
                            ( \otherRoot -> do
                                substituted <- snapshotFor profile otherRoot config singletonPlan
                                stablePlanSnapshotRoot substituted
                                    @?= canonicalProjectRootPath otherRoot
                                assertBool
                                    "a coordinated root-and-draft substitution retained canonical bytes"
                                    ( stablePlanSnapshotBytes original
                                        /= stablePlanSnapshotBytes substituted
                                    )
                                assertBool
                                    "a coordinated root-and-draft substitution retained the stable digest"
                                    ( stablePlanSnapshotDigest original
                                        /= stablePlanSnapshotDigest substituted
                                    )
                            )
                    either (fail . show) pure rooted
        , testCase "canonical bytes carry the header, version, and explicit collection counts" $
            withFoundation $ \_codec profile root config -> do
                snapshot <- snapshotFor profile root config projectedOperationPlan
                let bytes = stablePlanSnapshotBytes snapshot
                ByteString.take 18 bytes @?= ByteStringChar8.pack "HOSTBOOTSTRAP-PLAN"
                ByteString.take 8 (ByteString.drop 18 bytes)
                    @?= encodedWord64 3
                assertBool
                    "the step collection lacked its explicit count"
                    (framedCount "steps" 1 `ByteString.isInfixOf` bytes)
                assertBool
                    "the projected-operation collection lacked its explicit count"
                    (framedCount "projected-operations" 1 `ByteString.isInfixOf` bytes)
        , testCase "projected stable operation keys are snapshot material" $
            withFoundation $ \_codec profile root config -> do
                ordinary <- snapshotFor profile root config singletonPlan
                projected <- snapshotFor profile root config projectedOperationPlan
                assertBool
                    "a projected operation did not change canonical bytes"
                    ( stablePlanSnapshotBytes ordinary
                        /= stablePlanSnapshotBytes projected
                    )
                assertBool
                    "a projected operation did not change the stable digest"
                    ( stablePlanSnapshotDigest ordinary
                        /= stablePlanSnapshotDigest projected
                    )
                withAdmittedProjectPlan profile root config projectedOperationPlan $ \plan ->
                    map
                        (map (Text.pack . operationKeyText) . plannedStepProjectedOperationKeys)
                        (NonEmpty.toList (forward plan))
                        @?= [["core:context-init/relation"]]
        , testCase "executable callbacks are absent from stable snapshot bytes" $
            withFoundation $ \_codec profile root config -> do
                changed <- snapshotFor profile root config singletonPlan
                unchanged <- snapshotFor profile root config callbackReplacementPlan
                stablePlanSnapshotBytes changed
                    @?= stablePlanSnapshotBytes unchanged
                stablePlanSnapshotDigest changed
                    @?= stablePlanSnapshotDigest unchanged
        , testCase "length framing separates delimiter-shaped labels" $
            withFoundation $ \_codec profile root config -> do
                first <- snapshotFor profile root config framedLabelPlanA
                second <- snapshotFor profile root config framedLabelPlanB
                assertBool
                    "distinct length-framed labels collapsed"
                    (stablePlanSnapshotBytes first /= stablePlanSnapshotBytes second)
        , testCase "fixed admitted input has golden canonical bytes under its exact root" $
            withFoundation $ \codec profile root _config -> do
                let fixedValue =
                        Fixture.defaultProjectConfig
                            "golden-project"
                            "/golden-root"
                            Context.HostOrchestrator
                admitted <-
                    withValidatedConfig codec fixedValue $ \_wire fixedConfig -> do
                        snapshot <- snapshotFor profile root fixedConfig projectedOperationPlan
                        hexBytes (stablePlanSnapshotBytes snapshot)
                            @?= goldenSnapshotBytesHex (canonicalProjectRootPath root)
                either fail pure admitted
        , testCase "verified exact snapshot mints a same-spec local plan-digest binding" $
            withSnapshotPlan singletonPlan $ \store project _root unbound _spec _canonicalRoot _config _drafts plan -> do
                let stable = renderSnapshot plan
                writeRawPlanSnapshot
                    store
                    project
                    (unboundRunLeaseRunText unbound)
                    (stablePlanSnapshotSpecDigest stable)
                    (stablePlanSnapshotDigest stable)
                    (stablePlanSnapshotConfigDigest stable)
                    (stablePlanSnapshotBytes stable)
                bound <-
                    withPlanDigestBinding unbound plan $ \verified _binding ->
                        pure
                            ( planSnapshotSpecDigest verified
                            , planSnapshotPlanDigest verified
                            )
                bound
                    @?= Right
                        ( stablePlanSnapshotSpecDigest stable
                        , stablePlanSnapshotDigest stable
                        )
        , testCase "a locally bound snapshot preserves the verified canonical bytes" $
            withSnapshotPlan singletonPlan $ \store project _root unbound _spec _canonicalRoot _config _drafts plan -> do
                let stable = renderSnapshot plan
                writeRawPlanSnapshot
                    store
                    project
                    (unboundRunLeaseRunText unbound)
                    (stablePlanSnapshotSpecDigest stable)
                    (stablePlanSnapshotDigest stable)
                    (stablePlanSnapshotConfigDigest stable)
                    (stablePlanSnapshotBytes stable)
                produced <-
                    withFreshBoundPlanSnapshot unbound plan $ \verified bound _binding ->
                        pure
                            ( planSnapshotCanonicalBytes verified
                            , boundPlanSnapshotBytes bound
                            )
                produced
                    @?= Right
                        ( Just (stablePlanSnapshotBytes stable)
                        , stablePlanSnapshotBytes stable
                        )
        , testCase "a verified snapshot and its local bound evidence are produced as one indexed triple" $
            withSnapshotPlan singletonPlan $ \store project _root unbound _spec _canonicalRoot _config _drafts plan -> do
                let stable = renderSnapshot plan
                writeRawPlanSnapshot
                    store
                    project
                    (unboundRunLeaseRunText unbound)
                    (stablePlanSnapshotSpecDigest stable)
                    (stablePlanSnapshotDigest stable)
                    (stablePlanSnapshotConfigDigest stable)
                    (stablePlanSnapshotBytes stable)
                produced <-
                    withFreshBoundPlanSnapshot unbound plan pairedSnapshotEvidence
                produced
                    @?= Right
                        ( stablePlanSnapshotSpecDigest stable
                        , stablePlanSnapshotDigest stable
                        , stablePlanSnapshotBytes stable
                        )
        , testCase "binding rejects a verified snapshot with another specification digest" $
            withSnapshotPlan singletonPlan $ \store project _root unbound _spec _canonicalRoot _config _drafts plan -> do
                let stable = renderSnapshot plan
                writeRawPlanSnapshot
                    store
                    project
                    (unboundRunLeaseRunText unbound)
                    "other-specification"
                    (stablePlanSnapshotDigest stable)
                    (stablePlanSnapshotConfigDigest stable)
                    (stablePlanSnapshotBytes stable)
                bound <- withPlanDigestBinding unbound plan (\_ _ -> pure ())
                bound
                    @?= Left
                        ( SnapshotVerificationError
                            ( ModeSnapshotMismatch
                                (stablePlanSnapshotSpecDigest stable)
                                "other-specification"
                            )
                        )
        , testCase "binding rejects a verified snapshot with another configuration digest" $
            withSnapshotPlan singletonPlan $ \store project _root unbound _spec _canonicalRoot _config _drafts plan -> do
                let stable = renderSnapshot plan
                writeRawPlanSnapshot
                    store
                    project
                    (unboundRunLeaseRunText unbound)
                    (stablePlanSnapshotSpecDigest stable)
                    (stablePlanSnapshotDigest stable)
                    "other-configuration"
                    (stablePlanSnapshotBytes stable)
                bound <- withPlanDigestBinding unbound plan (\_ _ -> pure ())
                bound
                    @?= Left
                        ( SnapshotVerificationError
                            ( ModeSnapshotMismatch
                                (stablePlanSnapshotConfigDigest stable)
                                "other-configuration"
                            )
                        )
        , testCase "binding rejects different canonical bytes under matching digest terms" $
            withSnapshotPlan singletonPlan $ \store project _root unbound _spec _canonicalRoot _config _drafts plan -> do
                let stable = renderSnapshot plan
                writeRawPlanSnapshot
                    store
                    project
                    (unboundRunLeaseRunText unbound)
                    (stablePlanSnapshotSpecDigest stable)
                    (stablePlanSnapshotDigest stable)
                    (stablePlanSnapshotConfigDigest stable)
                    (stablePlanSnapshotBytes stable <> ByteString.singleton 0)
                bound <- withPlanDigestBinding unbound plan (\_ _ -> pure ())
                bound
                    @?= Left
                        ( SnapshotVerificationError
                            ( ModeSnapshotMismatch
                                "the indexed plan's exact canonical bytes"
                                "different canonical bytes"
                            )
                        )
        , testCase "binding rejects another stable plan digest under matching canonical bytes" $
            withSnapshotPlan singletonPlan $ \store project _root unbound _spec _canonicalRoot _config _drafts plan -> do
                let stable = renderSnapshot plan
                writeRawPlanSnapshot
                    store
                    project
                    (unboundRunLeaseRunText unbound)
                    (stablePlanSnapshotSpecDigest stable)
                    "other-plan-digest"
                    (stablePlanSnapshotConfigDigest stable)
                    (stablePlanSnapshotBytes stable)
                bound <- withPlanDigestBinding unbound plan (\_ _ -> pure ())
                bound
                    @?= Left
                        ( SnapshotVerificationError
                            ( ModeSnapshotMismatch
                                (stablePlanSnapshotDigest stable)
                                "other-plan-digest"
                            )
                        )
        , testCase "plan admission rejects the same project and epoch from another protected store before writing" $
            withSnapshotPlan singletonPlan $ \_storeA project rootA _unboundA _spec _canonicalRoot _config _drafts plan ->
                withSystemTempDirectory "hostbootstrap-plan-origin-store-b" $ \directory -> do
                    storeB <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
                    continued <- newIORef (0 :: Int)
                    second <-
                        withProductionRoot storeB project ProjectUp $ \productionRoot -> do
                            let unboundB = productionRootUnboundLease productionRoot
                                epochA = brokerEpochWord (rootAuthorityEpoch rootA)
                                epochB =
                                    brokerEpochWord
                                        (rootAuthorityEpoch (productionRootAuthority productionRoot))
                            epochB @?= epochA
                            outcome <-
                                withPersistedPlanSnapshot
                                    (productionRootAuthority productionRoot)
                                    unboundB
                                    plan
                                    (\_ _ _ _ _ -> modifyIORef' continued (+ 1))
                            pure (Right (outcome, unboundRunLeaseRunText unboundB))
                    (outcome, runName) <- either (fail . show) pure second
                    case outcome of
                        Left
                            ( SnapshotVerificationError
                                (ModeEvidenceMismatch "plan store" expected observed)
                                ) -> assertBool "store identities differ" (expected /= observed)
                        other -> assertFailure ("expected plan-store refusal, observed " <> show other)
                    key <-
                        either (fail . show) pure
                            (mkRecordKey ("snapshot." <> installedProjectName project <> "." <> runName))
                    observed <-
                        withProtectedEntry storeB $ \session ->
                            readProtectedRecord session key
                    either (fail . show) pure observed >>= (@?= Nothing)
                    readIORef continued >>= (@?= 0)
        , testGroup
            "exact recovered Production project plan"
            recoveredProductionProjectPlanCases
        , sourceBoundaryTests
        ]

recoveredProductionProjectPlanCases :: [TestTree]
recoveredProductionProjectPlanCases =
    [ testCase "exact reconstruction retains one admitted plan identity and is pure" $
        withRecoveredProjectPlanFixture $ \store _project inputs -> do
            before <- readAllProtectedRecords store
            let first = recoverProjectPlan inputs recoveredSnapshot
                second = recoverProjectPlan inputs recoveredSnapshot
            case (inputs, first) of
                ( RecoveredProjectPlanInputs profile root _verified _bound _binding _config _drafts
                    , Right snapshot
                    ) -> do
                        stablePlanSnapshotRoot snapshot
                            @?= canonicalProjectRootPath root
                        stablePlanSnapshotSpecDigest snapshot
                            @?= recoveredProductionProfileSpecDigest profile
                        stablePlanSnapshotConfigDigest snapshot
                            @?= recoveredProductionProfileConfigDigest profile
                        stablePlanSnapshotBytes snapshot
                            @?= recoveredProductionProfileCanonicalBytes profile
                        stablePlanSnapshotDigest snapshot
                            @?= recoveredProductionProfilePlanDigest profile
                (_, other) -> assertFailure ("expected exact recovered plan, observed " <> show other)
            second @?= first
            readAllProtectedRecords store >>= (@?= before)
    , testCase "a different independently finalized specification is refused before refinement" $
        withRecoveredProjectPlanCandidateFixture
            singletonPlan
            alternateFixtureServiceRegistry
            ( \store _project profile root _verified _bound _binding candidateSpec candidateConfig -> do
                before <- readAllProtectedRecords store
                assertRecoveryMismatch
                    "finalized specification"
                    ( withRecoveredProductionProjectPlanInputs
                        profile
                        root
                        candidateSpec
                        candidateConfig
                        (\_refined _drafts -> error "recovered-input callback entered")
                    )
                readAllProtectedRecords store >>= (@?= before)
            )
    , testCase "different independently validated config bytes are refused before refinement" $
        withRecoveredProjectPlanCandidateFixture
            singletonPlan
            fixtureServiceRegistry
            ( \store project profile root _verified _bound _binding candidateSpec _candidateConfig -> do
                before <- readAllProtectedRecords store
                let driftedValue =
                        Fixture.defaultProjectConfig
                            (installedProjectName project <> "-drift")
                            (Text.pack (canonicalProjectRootPath root))
                            Context.HostOrchestrator
                validated <-
                    withValidatedConfig
                        (finalizedProjectCodec candidateSpec)
                        driftedValue
                        ( \_wire driftedConfig ->
                            assertRecoveryMismatch
                                "validated configuration digest"
                                ( withRecoveredProductionProjectPlanInputs
                                    profile
                                    root
                                    candidateSpec
                                    driftedConfig
                                    (\_refined _drafts -> error "recovered-input callback entered")
                                )
                        )
                either fail pure validated
                readAllProtectedRecords store >>= (@?= before)
            )
    , testCase "same-spec candidate builder drift is regenerated then refused by canonical bytes" $
        withRecoveredProjectPlanCandidateFixture
            projectedOperationPlan
            fixtureServiceRegistry
            ( \_store _project profile root verified bound binding candidateSpec candidateConfig ->
                assertRecoveryMismatch
                    "candidate canonical bytes"
                    ( withRecoveredProductionProjectPlanInputs
                        profile
                        root
                        candidateSpec
                        candidateConfig
                        ( \recoveredConfig recoveredDrafts ->
                            withRecoveredProductionProjectPlan
                                profile
                                root
                                verified
                                bound
                                binding
                                recoveredConfig
                                recoveredDrafts
                                (const (error "recovered-plan callback entered"))
                        )
                        >>= id
                    )
            )
    , testCase "coordinated canonical-root and draft drift is refused" $
        withRecoveredProjectPlanFixture $ \_store _project inputs ->
            case inputs of
                RecoveredProjectPlanInputs profile _root verified bound binding config _drafts ->
                    withSystemTempDirectory "hostbootstrap-recovered-plan-root-drift" $ \directory -> do
                        rooted <-
                            withCanonicalProjectRoot
                                (directory </> "fixture.dhall")
                                directory
                                ( \otherRoot -> do
                                    otherDrafts <- draftsFor otherRoot config singletonPlan
                                    pure
                                        ( withRecoveredProductionProjectPlan
                                            profile
                                            otherRoot
                                            verified
                                            bound
                                            binding
                                            config
                                            otherDrafts
                                            (const (error "recovered-plan callback entered"))
                                        )
                                )
                        either (fail . show) pure rooted
                            >>= assertRecoveryMismatch "candidate canonical bytes"
    , testCase "configuration drift is refused before candidate admission" $
        withRecoveredProjectPlanFixture $ \_store _project inputs ->
            withRecoveredProjectPlanFixture $ \_foreignStore _foreignProject foreignInputs ->
                case (inputs, foreignInputs) of
                    ( RecoveredProjectPlanInputs profile root verified bound binding _config _drafts
                        , RecoveredProjectPlanInputs _foreignProfile _foreignRoot _foreignVerified _foreignBound _foreignBinding foreignConfig _foreignDrafts
                        ) -> do
                            -- The coercion deliberately models independently decoded opaque
                            -- evidence at a compromised package boundary. Public callers cannot
                            -- erase these nominal indices; the compile-fail suite proves that.
                            let driftedConfig = unsafeCoerce foreignConfig
                            driftedDrafts <- draftsFor root driftedConfig singletonPlan
                            assertRecoveryMismatch
                                "validated configuration digest"
                                ( withRecoveredProductionProjectPlan
                                    profile
                                    root
                                    verified
                                    bound
                                    binding
                                    driftedConfig
                                    driftedDrafts
                                    (const (error "recovered-plan callback entered"))
                                )
    , testCase "draft graph drift is refused by exact canonical bytes" $
        withRecoveredProjectPlanFixture $ \_store _project inputs ->
            case inputs of
                RecoveredProjectPlanInputs profile root verified bound binding config _drafts -> do
                    driftedDrafts <- draftsFor root config projectedOperationPlan
                    assertRecoveryMismatch
                        "candidate canonical bytes"
                        ( withRecoveredProductionProjectPlan
                            profile
                            root
                            verified
                            bound
                            binding
                            config
                            driftedDrafts
                            (const (error "recovered-plan callback entered"))
                        )
    , testCase "verified-snapshot origin drift is refused" $
        withRecoveredProjectPlanFixture $ \_store _project inputs ->
            withRecoveredProjectPlanFixture $ \_foreignStore _foreignProject foreignInputs ->
                case (inputs, foreignInputs) of
                    ( RecoveredProjectPlanInputs profile root _verified bound binding config drafts
                        , RecoveredProjectPlanInputs _foreignProfile _foreignRoot foreignVerified _foreignBound _foreignBinding _foreignConfig _foreignDrafts
                        ) ->
                            assertRecoveryMismatch
                                "verified snapshot store"
                                ( withRecoveredProductionProjectPlan
                                    profile
                                    root
                                    (unsafeCoerce foreignVerified)
                                    bound
                                    binding
                                    config
                                    drafts
                                    (const (error "recovered-plan callback entered"))
                                )
    , testCase "bound-snapshot byte drift is refused" $
        withRecoveredProjectPlanFixture $ \_store _project inputs ->
            withRecoveredProjectPlanFixture $ \_foreignStore _foreignProject foreignInputs ->
                case (inputs, foreignInputs) of
                    ( RecoveredProjectPlanInputs profile root verified _bound binding config drafts
                        , RecoveredProjectPlanInputs _foreignProfile _foreignRoot _foreignVerified foreignBound _foreignBinding _foreignConfig _foreignDrafts
                        ) ->
                            assertRecoveryMismatch
                                "bound snapshot canonical bytes"
                                ( withRecoveredProductionProjectPlan
                                    profile
                                    root
                                    verified
                                    (unsafeCoerce foreignBound)
                                    binding
                                    config
                                    drafts
                                    (const (error "recovered-plan callback entered"))
                                )
    , testCase "plan-digest binding drift is refused" $
        withRecoveredProjectPlanFixture $ \_store _project inputs ->
            withRecoveredProjectPlanFixture $ \_foreignStore _foreignProject foreignInputs ->
                case (inputs, foreignInputs) of
                    ( RecoveredProjectPlanInputs profile root verified bound _binding config drafts
                        , RecoveredProjectPlanInputs _foreignProfile _foreignRoot _foreignVerified _foreignBound foreignBinding _foreignConfig _foreignDrafts
                        ) ->
                            assertRecoveryMismatch
                                "plan digest binding"
                                ( withRecoveredProductionProjectPlan
                                    profile
                                    root
                                    verified
                                    bound
                                    (unsafeCoerce foreignBinding)
                                    config
                                    drafts
                                    (const (error "recovered-plan callback entered"))
                                )
    , testCase "recovered-profile origin drift is refused" $
        withRecoveredProjectPlanFixture $ \_store _project inputs ->
            withRecoveredProjectPlanFixture $ \_foreignStore _foreignProject foreignInputs ->
                case (inputs, foreignInputs) of
                    ( RecoveredProjectPlanInputs _profile root verified bound binding config drafts
                        , RecoveredProjectPlanInputs foreignProfile _foreignRoot _foreignVerified _foreignBound _foreignBinding _foreignConfig _foreignDrafts
                        ) ->
                            assertRecoveryMismatch
                                "verified snapshot store"
                                ( withRecoveredProductionProjectPlan
                                    (unsafeCoerce foreignProfile)
                                    root
                                    verified
                                    bound
                                    binding
                                    config
                                    drafts
                                    (const (error "recovered-plan callback entered"))
                                )
    ]

sourceBoundaryTests :: TestTree
sourceBoundaryTests =
    testGroup
        "public and representation boundaries"
        [ testCase "Cabal exposes the facade and evidence leaves but hides the plan kernel" $
            withPackageSourceRoot $ \packageRoot _sourceRoot -> do
                cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
                librarySource <-
                    maybe
                        (assertFailure "hostbootstrap-core.cabal has no main library stanza")
                        pure
                        (mainLibraryStanza cabalSource)
                let exposed = fieldModules "exposed-modules:" librarySource
                    privateModules = fieldModules "other-modules:" librarySource
                    allExposed = fieldModules "exposed-modules:" cabalSource
                    requiredPublic =
                        [ "HostBootstrap.ProjectPlan"
                        , "HostBootstrap.ProjectPlan.Construct"
                        , "HostBootstrap.ProjectPlan.Frame"
                        , "HostBootstrap.ProjectPlan.Snapshot"
                        , "HostBootstrap.Authority.ProjectPlan"
                        ]
                assertRequiredMembers "main-library exposed modules" requiredPublic exposed
                assertBool
                    "HostBootstrap.Lifecycle.Plan is not a main-library other-module"
                    ("HostBootstrap.Lifecycle.Plan" `elem` privateModules)
                assertBool
                    "HostBootstrap.Lifecycle.Plan is exposed by a Cabal component"
                    ("HostBootstrap.Lifecycle.Plan" `notElem` allExposed)
                fieldModules
                    "exposed-modules:"
                    "library\n  exposed-modules: HostBootstrap.Lifecycle.Plan\n"
                    @?= ["HostBootstrap.Lifecycle.Plan"]
        , testCase "exactly the audited production modules import the plan kernel" $
            withPackageSourceRoot $ \_packageRoot sourceRoot -> do
                sources <- readProductionSources sourceRoot
                let importerSources =
                        [ (moduleName, source)
                        | (moduleName, _path, source) <- sources
                        , SourceGuard.importsModule "HostBootstrap.Lifecycle.Plan" source
                        ]
                    importers =
                        sort
                            (map fst importerSources)
                    allowed =
                        sort
                            [ "HostBootstrap.ProjectPlan"
                            , "HostBootstrap.ProjectPlan.Construct"
                            , "HostBootstrap.ProjectPlan.Frame"
                            , "HostBootstrap.ProjectPlan.Snapshot"
                            , "HostBootstrap.Authority.ProjectPlan"
                            , "HostBootstrap.Lifecycle.Mode"
                            , "HostBootstrap.Lifecycle.Session"
                            , "HostBootstrap.Reconcile"
                            ]
                importers @?= allowed
                mapM_
                    ( \(moduleName, source) ->
                        assertBool
                            (moduleName <> " imports the effectful HostBootstrap.Lift module")
                            (not (SourceGuard.importsModule "HostBootstrap.Lift" source))
                    )
                    importerSources
        , testCase "the plan foundation depends only on the pure lift-context vocabulary" $
            withPackageSourceRoot $ \_packageRoot sourceRoot -> do
                let foundationalPaths =
                        [ ("Step", sourceRoot </> "HostBootstrap" </> "Step.hs")
                        , ("ProjectPlan", sourceRoot </> "HostBootstrap" </> "ProjectPlan.hs")
                        ,
                            ( "Lifecycle.Plan"
                            , sourceRoot
                                </> "HostBootstrap"
                                </> "Lifecycle"
                                </> "Plan.hs"
                            )
                        ]
                foundationalSources <-
                    traverse
                        ( \(label, path) -> do
                            source <- readFile path
                            pure (label, source)
                        )
                        foundationalPaths
                mapM_
                    ( \(label, source) -> do
                        assertBool
                            (label <> " does not import HostBootstrap.Lift.Context")
                            (SourceGuard.importsModule "HostBootstrap.Lift.Context" source)
                        assertBool
                            (label <> " imports the effectful HostBootstrap.Lift module")
                            (not (SourceGuard.importsModule "HostBootstrap.Lift" source))
                        mapM_
                            ( \providerModule ->
                                assertBool
                                    (label <> " imports provider realization " <> providerModule)
                                    (not (SourceGuard.importsModule providerModule source))
                            )
                            [ "HostBootstrap.Incus"
                            , "HostBootstrap.Lima"
                            , "HostBootstrap.Wsl2"
                            ]
                    )
                    foundationalSources
                chainSource <- readFile (sourceRoot </> "HostBootstrap" </> "Chain.hs")
                assertBool
                    "Chain does not import the effectful HostBootstrap.Lift module"
                    (SourceGuard.importsModule "HostBootstrap.Lift" chainSource)
        , testCase "static and finalized project specifications retain their exact indices" $
            withPackageSourceRoot $ \_packageRoot sourceRoot -> do
                cliSource <- readFile (sourceRoot </> "HostBootstrap" </> "CLI.hs")
                constructSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "ProjectPlan" </> "Construct.hs")
                let cli = normalizeWhitespace cliSource
                    construct = normalizeWhitespace constructSource
                assertContains
                    "the static ProjectSpec authoring-family header"
                    "data ProjectSpec cfg tcfg = ProjectSpec"
                    cli
                assertContains
                    "the finalized scope/specification header"
                    "data FinalizedProjectSpec scope specDigest cfg = FinalizedProjectSpec"
                    construct
                assertContains
                    "the finalized specification's nominal roles"
                    "type role FinalizedProjectSpec nominal nominal nominal"
                    construct
        , testCase "the pure facade exposes only the abstract stable snapshot view" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                facadeSource <- readFile (sourceRoot </> "HostBootstrap" </> "ProjectPlan.hs")
                exportTokens <-
                    requiredModuleExports
                        "HostBootstrap.ProjectPlan"
                        facadeSource
                assertBool
                    "StablePlanSnapshot is absent from the ProjectPlan export list"
                    ("StablePlanSnapshot" `elem` exportTokens)
                assertBool
                    "StablePlanSnapshot constructors are public"
                    (not (containsTokenSequence ["StablePlanSnapshot", "("] exportTokens))
                assertBool
                    "CanonicalPlanSnapshot is public through the pure facade"
                    ("CanonicalPlanSnapshot" `notElem` exportTokens)
                assertBool
                    "IndexedPlanSnapshot is public through the pure facade"
                    ("IndexedPlanSnapshot" `notElem` exportTokens)
                assertBool
                    "canonicalPlanSnapshot is public through the pure facade"
                    ("canonicalPlanSnapshot" `notElem` exportTokens)

                publicExports <- readPublicModuleExports packageRoot sourceRoot
                modulesExporting "IndexedPlanSnapshot" publicExports @?= []
                modulesExporting "canonicalPlanSnapshot" publicExports @?= []
                let planKernelReexports =
                        sort
                            [ moduleName
                            | (moduleName, exports) <- publicExports
                            , containsTokenSequence
                                [ "module"
                                , "HostBootstrap"
                                , "."
                                , "Lifecycle"
                                , "."
                                , "Plan"
                                ]
                                exports
                            ]
                planKernelReexports @?= []
                let exposedKernelImporters =
                        [ "HostBootstrap.ProjectPlan"
                        , "HostBootstrap.ProjectPlan.Construct"
                        , "HostBootstrap.ProjectPlan.Frame"
                        , "HostBootstrap.ProjectPlan.Snapshot"
                        , "HostBootstrap.Authority.ProjectPlan"
                        , "HostBootstrap.Lifecycle.Mode"
                        , "HostBootstrap.Lifecycle.Session"
                        , "HostBootstrap.Reconcile"
                        ]
                    moduleReexportingKernelImporters =
                        sort
                            [ moduleName
                            | (moduleName, exports) <- publicExports
                            , moduleName `elem` exposedKernelImporters
                            , "module" `elem` exports
                            ]
                moduleReexportingKernelImporters @?= []

                sources <- readProductionSources sourceRoot
                let canonicalSignatureSites =
                        [ (moduleName, count)
                        | (moduleName, _path, source) <- sources
                        , let count =
                                SourceGuard.countHaskellTokenSequence
                                    ["canonicalPlanSnapshot", "::"]
                                    source
                        , count > 0
                        ]
                canonicalSignatureSites
                    @?= [("HostBootstrap.Lifecycle.Plan", 1)]
        , testCase "resource and budget admission stays plan-owned and exactly indexed" $
            withPackageSourceRoot $ \packageRoot sourceRoot -> do
                facadeSource <- readFile (sourceRoot </> "HostBootstrap" </> "ProjectPlan.hs")
                budgetSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Cluster" </> "Budget.hs")
                exportTokens <-
                    requiredModuleExports
                        "HostBootstrap.ProjectPlan"
                        facadeSource
                let facade = normalizeWhitespace facadeSource
                    budget = normalizeWhitespace budgetSource
                assertBool
                    "PlannedResource is absent from the ProjectPlan export list"
                    ("PlannedResource" `elem` exportTokens)
                assertBool
                    "PlannedResource constructors are public"
                    (not (containsTokenSequence ["PlannedResource", "("] exportTokens))
                assertRequiredMembers
                    "plan-owned resource projection exports"
                    ["withPlannedResourceOfKind", "withPlannedStepResourceOfKind"]
                    exportTokens
                mapM_
                    (\(label, fragment) -> assertContains label fragment facade)
                    [ ( "the exact topology projection"
                      , "topology :: ProjectPlan scope specDigest planId configId cfg -> DerivedTopology scope planId"
                      )
                    ]
                mapM_
                    (\(label, fragment) -> assertContains label fragment budget)
                    [ ( "the exact budget admission plan"
                      , "withValidatedBudget :: ProjectPlan scope specDigest planId configId cfg -> ResourceEnvelope ->"
                      )
                    , ( "the exact provider resource projection"
                      , "withProviderBudgetCapability :: ProjectPlan scope specDigest planId configId cfg -> PlannedResource scope planId resourceId ProviderResource frame ->"
                      )
                    , ( "the exact workload resource projection"
                      , "mkWorkload :: PlannedResource scope planId resourceId resource frame ->"
                      )
                    , ( "the exact workload topology source"
                      , "withPlannedWorkloadSet :: ProjectPlan scope specDigest planId configId cfg -> [Workload scope planId] ->"
                      )
                    , ( "the exact slice resource projection"
                      , "mkSliceRequest :: PlannedResource scope planId resourceId resource frame ->"
                      )
                    , ("plan-derived topology use", "derivedTopology = topology plan")
                    ]
                assertAbsent
                    "Budget imports or accepts the LifecyclePlan compatibility type"
                    "LifecyclePlan"
                    budgetSource
                assertBool
                    "Budget imports the hidden lifecycle-plan representation kernel"
                    (not (SourceGuard.importsModule "HostBootstrap.Lifecycle.Plan" budgetSource))
                publicExports <- readPublicModuleExports packageRoot sourceRoot
                let constructorExporters =
                        sort
                            [ moduleName
                            | (moduleName, exports) <- publicExports
                            , containsTokenSequence ["PlannedResource", "("] exports
                            ]
                constructorExporters @?= []
                mapM_
                    ( \producer ->
                        modulesExporting producer publicExports
                            @?= ["HostBootstrap.ProjectPlan"]
                    )
                    [ "withPlannedResourceOfKind"
                    , "withPlannedEdge"
                    , "withProviderGuestAliasProjection"
                    , "withPlannedStepResourceOfKind"
                    , "withPlannedStepGuestAliasProjection"
                    ]
        , testCase "Production commands admit exactly one fresh or recovered plan identity" $
            withPackageSourceRoot $ \_packageRoot sourceRoot -> do
                commandSource <- readFile (sourceRoot </> "HostBootstrap" </> "Command.hs")
                let command = commandSource
                freshAdmission <-
                    requiredSourceSection
                        "fresh Production plan admission"
                        "withFreshProductionPlan store root validated ctx verb use = do"
                        "withRecoveredProductionPlan ::"
                        command
                recoveredAdmission <-
                    requiredSourceSection
                        "recovered Production plan admission"
                        "withRecoveredProductionPlan store root candidateConfig ctx use ="
                        "startsFreshProductionInvocation ::"
                        command
                upCommand <-
                    requiredSourceSection
                        "project up command"
                        "runUp dryRun ="
                        "failChain ::"
                        command
                teardownCommand <-
                    requiredSourceSection
                        "Production teardown command"
                        "runProductionTeardown root validated ctx cfg commandVerb teardownVerb clusterEffect = do"
                        "reverseProjection ::"
                        command

                SourceGuard.countHaskellIdentifier "withProjectPlan" freshAdmission @?= 1
                SourceGuard.countHaskellIdentifier "withCurrentFrame" freshAdmission @?= 1
                SourceGuard.countHaskellIdentifier "withRecoveredProductionProjectPlanInputs" recoveredAdmission @?= 1
                SourceGuard.countHaskellIdentifier "withRecoveredProductionProjectPlan" recoveredAdmission @?= 1
                SourceGuard.countHaskellIdentifier "withCurrentFrame" recoveredAdmission @?= 1
                SourceGuard.countHaskellIdentifier "withProjectPlan" recoveredAdmission @?= 0
                SourceGuard.countHaskellIdentifier "withRecoveredProductionPlan" upCommand @?= 1
                SourceGuard.countHaskellIdentifier "withFreshProductionPlan" upCommand @?= 1
                SourceGuard.countHaskellIdentifier "withRecoveredProductionPlan" teardownCommand @?= 1
                SourceGuard.countHaskellIdentifier "withFreshProductionPlan" teardownCommand @?= 1
        , testCase "descriptive context and nominal authorities retain broker continuity" $
            withPackageSourceRoot $ \_packageRoot sourceRoot -> do
                frameSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "ProjectPlan" </> "Frame.hs")
                sessionSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Lifecycle" </> "Session.hs")
                authorityKernelSource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Authority" </> "Kernel.hs")
                projectAuthoritySource <-
                    readFile
                        (sourceRoot </> "HostBootstrap" </> "Authority" </> "ProjectPlan.hs")
                let frame = normalizeWhitespace frameSource
                    session = normalizeWhitespace sessionSource
                    authorityKernel = normalizeWhitespace authorityKernelSource
                    projectAuthority = normalizeWhitespace projectAuthoritySource
                mapM_
                    (\(label, fragment, source) -> assertContains label fragment source)
                    [ ( "the exact descriptive context indices"
                      , "newtype ValidatedContext scope planId frame = ValidatedContext Context.BinaryContext"
                      , frame
                      )
                    , ( "the descriptive context's nominal roles"
                      , "type role ValidatedContext nominal nominal nominal"
                      , frame
                      )
                    , ( "the acquisition journal indices"
                      , "data AcquisitionJournal scope planId brokerGeneration where"
                      , session
                      )
                    , ( "the acquisition journal's nominal roles"
                      , "type role AcquisitionJournal nominal nominal nominal"
                      , session
                      )
                    , ( "the lifecycle cursor indices"
                      , "data LifecycleCursor scope planId frame brokerGeneration verb phase where"
                      , session
                      )
                    , ( "the lifecycle cursor's nominal roles"
                      , "type role LifecycleCursor nominal nominal nominal nominal nominal nominal"
                      , session
                      )
                    , ( "the command authority indices"
                      , "data CommandAuthority scope planId frame brokerGeneration verb phase"
                      , authorityKernel
                      )
                    , ( "the command authority's nominal roles"
                      , "type role CommandAuthority nominal nominal nominal nominal nominal nominal"
                      , authorityKernel
                      )
                    , ( "the journal broker carried into project-up admission"
                      , "AcquisitionJournal scope planId brokerGeneration ->"
                      , projectAuthority
                      )
                    , ( "the cursor broker carried into project-up admission"
                      , "LifecycleCursor scope planId frame brokerGeneration VerbUp phase ->"
                      , projectAuthority
                      )
                    , ( "the context remains broker-free at project-up admission"
                      , "ValidatedContext scope planId frame ->"
                      , projectAuthority
                      )
                    , ( "the exact broker reaches command authority"
                      , "CommandAuthority scope planId frame brokerGeneration VerbUp phase"
                      , projectAuthority
                      )
                    ]
        ]

withPackageSourceRoot :: (FilePath -> FilePath -> IO result) -> IO result
withPackageSourceRoot use = do
    cwd <- getCurrentDirectory
    repoRoot <-
        findRepoRoot cwd
            >>= maybe
                (assertFailure ("could not locate repo root from " <> cwd))
                pure
    let packageRoot = repoRoot </> "core" </> "hostbootstrap-core"
    use packageRoot (packageRoot </> "src")

readProductionSources :: FilePath -> IO [(String, FilePath, String)]
readProductionSources sourceRoot = do
    paths <- listHaskellSources sourceRoot
    traverse
        ( \path -> do
            source <- readFile path
            pure (moduleNameFromPath sourceRoot path, path, source)
        )
        paths

readPublicModuleExports :: FilePath -> FilePath -> IO [(String, [String])]
readPublicModuleExports packageRoot sourceRoot = do
    cabalSource <- readFile (packageRoot </> "hostbootstrap-core.cabal")
    librarySource <-
        maybe
            (assertFailure "hostbootstrap-core.cabal has no main library stanza" >> pure "")
            pure
            (mainLibraryStanza cabalSource)
    sources <- readProductionSources sourceRoot
    let exposed = sort (fieldModules "exposed-modules:" librarySource)
        sourceByModule =
            [ (moduleName, source)
            | (moduleName, _path, source) <- sources
            ]
        missing =
            filter
                (\moduleName -> moduleName `notElem` map fst sourceByModule)
                exposed
    assertBool
        ("main-library exposed module source(s) missing: " <> show missing)
        (null missing)
    traverse
        ( \moduleName -> do
            source <-
                maybe
                    (assertFailure ("source missing for exposed module " <> moduleName) >> pure "")
                    pure
                    (lookup moduleName sourceByModule)
            exports <- requiredModuleExports moduleName source
            pure (moduleName, exports)
        )
        exposed

requiredModuleExports :: String -> String -> IO [String]
requiredModuleExports moduleName source =
    case SourceGuard.moduleExportTokens moduleName source of
        Nothing ->
            assertFailure
                (moduleName <> " has no lexically visible explicit export list")
                >> pure []
        Just exports -> pure exports

modulesExporting :: String -> [(String, [String])] -> [String]
modulesExporting exported =
    sort
        . map fst
        . filter (elem exported . snd)

containsTokenSequence :: Eq token => [token] -> [token] -> Bool
containsTokenSequence [] _observed = True
containsTokenSequence _expected [] = False
containsTokenSequence expected observed@(_ : rest) =
    tokenPrefix expected observed || containsTokenSequence expected rest
  where
    tokenPrefix [] _ = True
    tokenPrefix _ [] = False
    tokenPrefix (wanted : wantedRest) (actual : actualRest) =
        wanted == actual && tokenPrefix wantedRest actualRest

listHaskellSources :: FilePath -> IO [FilePath]
listHaskellSources directory = do
    entries <- sort <$> listDirectory directory
    fmap concat $
        traverse
            ( \entry -> do
                let path = directory </> entry
                isDirectory <- doesDirectoryExist path
                if isDirectory
                    then listHaskellSources path
                    else pure [path | takeExtension path == ".hs"]
            )
            entries

moduleNameFromPath :: FilePath -> FilePath -> String
moduleNameFromPath sourceRoot =
    intercalate "."
        . splitDirectories
        . dropExtension
        . makeRelative sourceRoot

mainLibraryStanza :: String -> Maybe String
mainLibraryStanza source =
    case dropWhile ((/= "library") . trim) (lines source) of
        [] -> Nothing
        _library : rest ->
            Just
                ( unlines
                    ( takeWhile
                        isLibraryContinuation
                        rest
                    )
                )
  where
    isLibraryContinuation [] = True
    isLibraryContinuation line@(firstCharacter : _) =
        null (trim line) || isSpace firstCharacter

fieldModules :: String -> String -> [String]
fieldModules field = go . lines
  where
    go [] = []
    go (line : rest)
        | Just inline <- stripPrefix field (trim line) =
            let fieldIndent = indentation line
                (continuation, remaining) =
                    span
                        (\next -> null (trim next) || indentation next > fieldIndent)
                        rest
             in moduleTokens (inline : continuation) <> go remaining
        | otherwise = go rest

    moduleTokens =
        filter ("HostBootstrap." `isPrefixOf`)
            . map (filter (/= ','))
            . words
            . unlines

indentation :: String -> Int
indentation = length . takeWhile isSpace

normalizeWhitespace :: String -> String
normalizeWhitespace = unwords . words

trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

requiredSourceSection :: String -> String -> String -> String -> IO String
requiredSourceSection label opening closing source =
    case dropThrough opening source >>= takeBefore closing of
        Nothing ->
            assertFailure
                ( label
                    <> " is not bounded by the expected source markers "
                    <> show opening
                    <> " and "
                    <> show closing
                )
                >> pure ""
        Just section -> pure section

dropThrough :: String -> String -> Maybe String
dropThrough needle = go
  where
    go [] = Nothing
    go remaining@(_character : rest)
        | needle `isPrefixOf` remaining = Just (drop (length needle) remaining)
        | otherwise = go rest

takeBefore :: String -> String -> Maybe String
takeBefore needle = go []
  where
    go _ [] = Nothing
    go reversed remaining@(character : rest)
        | needle `isPrefixOf` remaining = Just (reverse reversed)
        | otherwise = go (character : reversed) rest

assertRequiredMembers :: String -> [String] -> [String] -> IO ()
assertRequiredMembers label required observed =
    let missing = filter (`notElem` observed) required
     in assertBool
            (label <> " missing " <> show missing <> "; observed " <> show observed)
            (null missing)

assertContains :: String -> String -> String -> IO ()
assertContains label expected source =
    assertBool
        (label <> " is missing source shape: " <> show expected)
        (expected `isInfixOf` source)

assertAbsent :: String -> String -> String -> IO ()
assertAbsent label forbidden source =
    assertBool
        (label <> ": " <> show forbidden)
        (not (forbidden `isInfixOf` source))

{- | The complete public package required for one recovered-plan reconstruction.

The indices are deliberately retained in one value so the success test can pin
the reconstructed 'ProjectPlan' to the exact @planId@ generated by existing
snapshot admission.
-}
data RecoveredProjectPlanInputs projectId specDigest planDigest planId brokerGeneration rootId configId
    = RecoveredProjectPlanInputs
        ( RecoveredProductionLifecycleProfile
            projectId
            specDigest
            planDigest
            planId
            brokerGeneration
        )
        (CanonicalProjectRoot (Production projectId) rootId)
        (VerifiedPlanSnapshot (Production projectId) specDigest planDigest)
        (BoundPlanSnapshot (Production projectId) specDigest planDigest planId)
        (PlanDigestBinding (Production projectId) specDigest planDigest planId)
        ( ValidatedConfig
            (Production projectId)
            specDigest
            configId
            (Fixture.ProjectConfig (Production projectId))
        )
        ( NonEmpty
            ( PlanDraft
                (Production projectId)
                specDigest
                (Fixture.ProjectConfig (Production projectId))
            )
        )

recoverProjectPlan ::
    RecoveredProjectPlanInputs
        projectId specDigest planDigest planId brokerGeneration rootId configId ->
    ( ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      result
    ) ->
    Either PlanError result
recoverProjectPlan
    (RecoveredProjectPlanInputs profile root verified bound binding config drafts) =
        withRecoveredProductionProjectPlan
            profile
            root
            verified
            bound
            binding
            config
            drafts

recoveredSnapshot ::
    ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
    StablePlanSnapshot
recoveredSnapshot = renderSnapshot

assertRecoveryMismatch :: Text.Text -> Either PlanError () -> IO ()
assertRecoveryMismatch expectedSubject outcome =
    case outcome of
        Left (PlanRecoveryEvidenceMismatch observedSubject _expected _observed)
            | observedSubject == expectedSubject -> pure ()
        other -> assertFailure ("expected recovered-plan refusal for " <> show expectedSubject <> ", observed " <> show other)

readAllProtectedRecords :: ProtectedStore -> IO [Maybe (RecordKey, ProtectedRecord)]
readAllProtectedRecords store = do
    observed <-
        withProtectedEntry store $ \session -> do
            listed <- listProtectedRecords session
            case listed of
                Left failure -> pure (Left failure)
                Right keys -> do
                    records <-
                        traverse
                            ( \key ->
                                fmap (fmap (fmap ((,) key)))
                                    (readProtectedRecord session key)
                            )
                            keys
                    pure (sequence records)
    either (fail . show) pure observed

withRecoveredProjectPlanFixture ::
    ( forall projectId brokerGeneration specDigest planDigest planId rootId configId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RecoveredProjectPlanInputs
        projectId specDigest planDigest planId brokerGeneration rootId configId ->
      IO result
    ) ->
    IO result
withRecoveredProjectPlanFixture use =
    withRecoveredProjectPlanCandidateFixture
        singletonPlan
        fixtureServiceRegistry
        ( \store project profile root verified bound binding candidateSpec candidateConfig ->
            case
                withRecoveredProductionProjectPlanInputs
                    profile
                    root
                    candidateSpec
                    candidateConfig
                    ( \recoveredConfig recoveredDrafts ->
                        use
                            store
                            project
                            ( RecoveredProjectPlanInputs
                                profile
                                root
                                verified
                                bound
                                binding
                                recoveredConfig
                                recoveredDrafts
                            )
                    )
            of
                Left failure -> fail (show failure)
                Right action -> action
        )

withRecoveredProjectPlanCandidateFixture ::
    StepPlan ->
    ServiceRegistry Fixture.ProjectConfig ->
    ( forall
        projectId
        brokerGeneration
        recoveredSpecDigest
        planDigest
        planId
        rootId
        candidateSpecDigest
        candidateConfigId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RecoveredProductionLifecycleProfile
        projectId
        recoveredSpecDigest
        planDigest
        planId
        brokerGeneration ->
      CanonicalProjectRoot (Production projectId) rootId ->
      VerifiedPlanSnapshot
        (Production projectId)
        recoveredSpecDigest
        planDigest ->
      BoundPlanSnapshot
        (Production projectId)
        recoveredSpecDigest
        planDigest
        planId ->
      PlanDigestBinding
        (Production projectId)
        recoveredSpecDigest
        planDigest
        planId ->
      FinalizedProjectSpec
        (Production projectId)
        candidateSpecDigest
        Fixture.ProjectConfig ->
      ValidatedConfig
        (Production projectId)
        candidateSpecDigest
        candidateConfigId
        (Fixture.ProjectConfig (Production projectId)) ->
      IO result
    ) ->
    IO result
withRecoveredProjectPlanCandidateFixture candidatePlan candidateServices use =
    withSnapshotPlan singletonPlan $ \store project rootAuthority unbound _persistedSpec root config _drafts plan -> do
        persisted <-
            withPersistedPlanSnapshot
                rootAuthority
                unbound
                plan
                (\_verified _bound _binding _boundLease _active -> pure ())
        either (fail . show) pure persisted
        admitted <-
            withBoundPlanSnapshot
                store
                project
                (\_closeKey -> assertFailure "the recovered-plan fixture entered the terminal callback")
                (\exactRoot modeLease boundLease verified bound binding recovery ->
                    case
                        withRecoveredProductionLifecycleProfile
                            exactRoot
                            modeLease
                            boundLease
                            verified
                            bound
                            binding
                            recovery
                            ( \profile ->
                                withProductionProjectCodec $ \candidateBaseCodec ->
                                    withFinalizedProjectSpec
                                        ProductionScope
                                        candidateBaseCodec
                                        candidateServices
                                        (\_ _ -> Right candidatePlan)
                                        ( \candidateSpec -> do
                                            candidate <-
                                                withValidatedConfig
                                                    (finalizedProjectCodec candidateSpec)
                                                    (validatedConfigValue config)
                                                    ( \_wire candidateConfig ->
                                                        use
                                                            store
                                                            project
                                                            profile
                                                            root
                                                            verified
                                                            bound
                                                            binding
                                                            candidateSpec
                                                            candidateConfig
                                                    )
                                            either fail pure candidate
                                        )
                            )
                    of
                        Left failure -> fail (show failure)
                        Right action -> action
                )
        either (fail . show) pure admitted

pairedSnapshotEvidence ::
    VerifiedPlanSnapshot scope specDigest planDigest ->
    BoundPlanSnapshot scope specDigest planDigest planId ->
    PlanDigestBinding scope specDigest planDigest planId ->
    IO (Text.Text, Text.Text, ByteString.ByteString)
pairedSnapshotEvidence verified bound _binding =
    pure
        ( planSnapshotSpecDigest verified
        , planSnapshotPlanDigest verified
        , boundPlanSnapshotBytes bound
        )

exerciseFinalizedSpec ::
    FinalizedProjectSpec scope specDigest Fixture.ProjectConfig ->
    FilePath ->
    Fixture.ProjectConfig scope ->
    IO Text.Text
exerciseFinalizedSpec spec directory value = do
    rooted <-
        withCanonicalProjectRoot
            (directory </> "fixture.dhall")
            directory
            ( \root -> do
                admitted <-
                    withValidatedConfig
                        (finalizedProjectCodec spec)
                        value
                        ( \_wire validated -> do
                            let expectedDigest =
                                    projectCodecSpecDigest
                                        (finalizedProjectCodec spec)
                            validatedConfigSpecDigest validated @?= expectedDigest
                            plan <- expectRight (projectPlanStepPlan spec root validated)
                            drafts <- expectRight (projectPlanDrafts spec root validated)
                            NonEmpty.length drafts @?= length (stepPlanSteps plan)
                            finalizedServiceVariantNames
                                (finalizedProjectServices spec)
                                @?= ["probe"]
                            pure expectedDigest
                        )
                either fail pure admitted
            )
    either (fail . show) pure rooted

fixtureServiceRegistry :: ServiceRegistry Fixture.ProjectConfig
fixtureServiceRegistry =
    singletonServiceRegistry
        ( serviceDefinition
            (either (error . show) id (serviceId "probe"))
            (\_ -> Right (Just ()))
            NoEffects
            (const (pure ()))
        )

alternateFixtureServiceRegistry :: ServiceRegistry Fixture.ProjectConfig
alternateFixtureServiceRegistry =
    singletonServiceRegistry
        ( serviceDefinition
            (either (error . show) id (serviceId "alternate-probe"))
            (\_ -> Right (Just ()))
            NoEffects
            (const (pure ()))
        )

withFoundation ::
    ( forall projectId specDigest rootId configId.
      ProjectCodec (Production projectId) specDigest Fixture.ProjectConfig ->
      LifecycleProfile (Production projectId) ->
      CanonicalProjectRoot (Production projectId) rootId ->
      ValidatedConfig
        (Production projectId)
        specDigest
        configId
        (Fixture.ProjectConfig (Production projectId)) ->
      IO result
    ) ->
    IO result
withFoundation use =
    withSystemTempDirectory "hostbootstrap-project-plan" $ \directory -> do
        store <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
        Fixture.withFixtureInstalledProject $ \(project :: InstalledProjectIdentity projectId) -> do
            rooted <-
                withCanonicalProjectRoot
                    (directory </> "fixture.dhall")
                    "."
                    ( \(root :: CanonicalProjectRoot (Production projectId) rootId) ->
                        withProductionRoot store project ProjectUp $ \productionRoot -> do
                            opened <-
                                withProductionLifecycleProfile
                                    (rootScopeAuthority (productionRootAuthority productionRoot))
                                    (productionActiveMode (productionRootModeLease productionRoot))
                                    (productionRootUnboundLease productionRoot)
                                    ( \profile ->
                                        withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \codec -> do
                                            let value =
                                                    Fixture.defaultProjectConfig
                                                        (installedProjectName project)
                                                        (Text.pack (canonicalProjectRootPath root))
                                                        Context.HostOrchestrator
                                            validated <-
                                                withValidatedConfig codec value $ \_wire config ->
                                                    use codec profile root config
                                            either fail pure validated
                                    )
                            case opened of
                                Left failure -> pure (Left (ModeAuthorityFailure failure))
                                Right action -> Right <$> action
                    )
            admitted <- either (fail . show) pure rooted
            either (fail . show) pure admitted

withSnapshotPlan ::
    StepPlan ->
    ( forall projectId brokerGeneration specDigest rootId configId planId.
      ProtectedStore ->
      InstalledProjectIdentity projectId ->
      RootInvocationAuthority (Production projectId) brokerGeneration VerbUp ->
      UnboundRunLease (Production projectId) brokerGeneration ->
      FinalizedProjectSpec
        (Production projectId)
        specDigest
        Fixture.ProjectConfig ->
      CanonicalProjectRoot (Production projectId) rootId ->
      ValidatedConfig
        (Production projectId)
        specDigest
        configId
        (Fixture.ProjectConfig (Production projectId)) ->
      NonEmpty
        ( PlanDraft
            (Production projectId)
            specDigest
            (Fixture.ProjectConfig (Production projectId))
        ) ->
      ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        Fixture.ProjectConfig ->
      IO result
    ) ->
    IO result
withSnapshotPlan stepPlan use =
    withSystemTempDirectory "hostbootstrap-plan-digest-binding" $ \directory -> do
        store <- openProtectedStore (directory </> "protected") >>= either (fail . show) pure
        Fixture.withFixtureInstalledProject $ \(project :: InstalledProjectIdentity projectId) -> do
            rooted <-
                withCanonicalProjectRoot
                    (directory </> "fixture.dhall")
                    "."
                    ( \(root :: CanonicalProjectRoot (Production projectId) rootId) ->
                        withProductionRoot store project ProjectUp $ \productionRoot -> do
                            let unbound = productionRootUnboundLease productionRoot
                            opened <-
                                withProductionLifecycleProfile
                                    (rootScopeAuthority (productionRootAuthority productionRoot))
                                    (productionActiveMode (productionRootModeLease productionRoot))
                                    unbound
                                    ( \profile ->
                                        withProductionProjectCodec @Fixture.ProjectConfig @projectId $ \baseCodec ->
                                            withFinalizedProjectSpec
                                                ProductionScope
                                                baseCodec
                                                fixtureServiceRegistry
                                                (\_ _ -> Right stepPlan)
                                                ( \spec -> do
                                                    let value =
                                                            Fixture.defaultProjectConfig
                                                                (installedProjectName project)
                                                                (Text.pack (canonicalProjectRootPath root))
                                                                Context.HostOrchestrator
                                                    validated <-
                                                        withValidatedConfig
                                                            (finalizedProjectCodec spec)
                                                            value
                                                            ( \_wire config -> do
                                                                drafts <- expectRight (projectPlanDrafts spec root config)
                                                                action <-
                                                                    expectRight
                                                                        ( withProjectPlan
                                                                            profile
                                                                            root
                                                                            config
                                                                            drafts
                                                                            ( use
                                                                                store
                                                                                project
                                                                                (productionRootAuthority productionRoot)
                                                                                unbound
                                                                                spec
                                                                                root
                                                                                config
                                                                                drafts
                                                                            )
                                                                        )
                                                                action
                                                            )
                                                    either fail pure validated
                                                )
                                    )
                            case opened of
                                Left failure -> pure (Left (ModeAuthorityFailure failure))
                                Right action -> Right <$> action
                    )
            admitted <- either (fail . show) pure rooted
            either (fail . show) pure admitted

writeRawPlanSnapshot ::
    ProtectedStore ->
    InstalledProjectIdentity projectId ->
    Text.Text ->
    Text.Text ->
    Text.Text ->
    Text.Text ->
    ByteString.ByteString ->
    IO ()
writeRawPlanSnapshot store project runName specDigest planDigest configDigest canonicalBytes = do
    key <-
        either (fail . show) pure
            (mkRecordKey ("snapshot." <> installedProjectName project <> "." <> runName))
    written <-
        withProtectedEntry store $ \session ->
            fmap (fmap (const ()))
                ( compareAndSwapProtectedRecord
                    session
                    key
                    ExpectAbsent
                    payload
                )
    either (fail . show) pure written
  where
    payload =
        LazyByteString.toStrict
            ( Builder.toLazyByteString
                ( Builder.byteString "HOSTBOOTSTRAP-SNAPSHOT"
                    <> Builder.word64BE 1
                    <> Builder.word64BE 1
                    <> encodeSnapshotText specDigest
                    <> encodeSnapshotText planDigest
                    <> Builder.word8 1
                    <> encodeSnapshotText configDigest
                    <> encodeSnapshotBytes canonicalBytes
                )
            )

encodeSnapshotText :: Text.Text -> Builder.Builder
encodeSnapshotText = encodeSnapshotBytes . TextEncoding.encodeUtf8

encodeSnapshotBytes :: ByteString.ByteString -> Builder.Builder
encodeSnapshotBytes bytes =
    Builder.word64BE (fromIntegral (ByteString.length bytes))
        <> Builder.byteString bytes

draftsFor ::
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId config ->
    StepPlan ->
    IO (NonEmpty (PlanDraft scope specDigest config))
draftsFor root config plan =
    expectRight
        (planDraftsFromValidatedBuilder root config (\_ _ -> Right plan))

withAdmittedProjectPlan ::
    LifecycleProfile scope ->
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    StepPlan ->
    (forall planId. ProjectPlan scope specDigest planId configId cfg -> IO result) ->
    IO result
withAdmittedProjectPlan profile root config plan use = do
    drafts <- draftsFor root config plan
    action <- expectRight (withProjectPlan profile root config drafts use)
    action

snapshotFor ::
    LifecycleProfile scope ->
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    StepPlan ->
    IO StablePlanSnapshot
snapshotFor profile root config plan =
    withAdmittedProjectPlan profile root config plan (pure . renderSnapshot)

singletonPlan :: StepPlan
singletonPlan =
    expectStepPlan
        [ contextInitStep
            "context"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        ]

guestOnlyPlan :: StepPlan
guestOnlyPlan =
    expectStepPlan
        [ ensureStep
            "ghc"
            "ensure ghc"
            (StepFrame "guest" "Guest")
            (const (pure StepChanged))
        ]

relabelledHostPlan :: StepPlan
relabelledHostPlan =
    expectStepPlan
        [ ensureStep
            "ghc"
            "ensure ghc"
            (StepFrame "host" "Relabelled host")
            (const (pure StepChanged))
        ]

hostWithPostHandoffPlan :: StepPlan
hostWithPostHandoffPlan =
    expectStepPlan
        [ contextInitStep
            "context"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        , postHandoffStep
            "verify"
            "verify after handoff"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        ]

topologyFixturePlan :: StepPlan
topologyFixturePlan =
    expectStepPlan
        [ descendsVia
            localContext
            ( contextInitStep
                "context"
                (StepFrame "host" "Host")
                (const (pure StepChanged))
            )
        , ensureStep
            "ghc"
            "ensure ghc"
            (StepFrame "guest" "Guest")
            (const (pure StepChanged))
        ]

closedResourceFamilyPlan :: StepPlan
closedResourceFamilyPlan =
    expectStepPlan
        [ deployVMStep
            "provider"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        , copySourceStep
            "durable share"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        , ensureStep
            "docker"
            "Docker daemon"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        , projectStep
            (either error id (projectStepId "deploy-minio"))
            PreserveOnReverse
            "MinIO"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        , projectStep
            (either error id (projectStepId "deploy-registry"))
            PreserveOnReverse
            "registry"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        , deployKindStep
            "cluster"
            (StepFrame "host" "Host")
            (const (pure StepChanged))
        ]

resourceProjectionPlan :: StepPlan
resourceProjectionPlan =
    expectStepPlan
        [ descendsVia
            localContext
            ( deployVMStep
                "provider"
                (StepFrame "host" "Host")
                (const (pure StepChanged))
            )
        , projectsOperation
            "core:deploy-vm/core:copy-source/guest-alias"
            ( copySourceStep
                "durable share"
                (StepFrame "provider" "Provider")
                (const (pure StepChanged))
            )
        , deployKindStep
            "cluster"
            (StepFrame "provider" "Provider")
            (const (pure StepChanged))
        ]

unprojectedResourcePlan :: StepPlan
unprojectedResourcePlan =
    expectStepPlan
        [ descendsVia
            localContext
            ( deployVMStep
                "provider"
                (StepFrame "host" "Host")
                (const (pure StepChanged))
            )
        , copySourceStep
            "durable share"
            (StepFrame "provider" "Provider")
            (const (pure StepChanged))
        , deployKindStep
            "cluster"
            (StepFrame "provider" "Provider")
            (const (pure StepChanged))
        ]

projectedOperationPlan :: StepPlan
projectedOperationPlan =
    expectStepPlan
        [ projectsOperation
            "core:context-init/relation"
            ( contextInitStep
                "context"
                (StepFrame "host" "Host")
                (const (pure StepChanged))
            )
        ]

callbackReplacementPlan :: StepPlan
callbackReplacementPlan =
    expectStepPlan
        [ contextInitStep
            "context"
            (StepFrame "host" "Host")
            (const (pure StepUnchanged))
        ]

framedLabelPlanA :: StepPlan
framedLabelPlanA =
    expectStepPlan
        [ contextInitStep
            "a|b:c"
            (StepFrame "frame|one" "Frame: one")
            (const (pure StepChanged))
        ]

framedLabelPlanB :: StepPlan
framedLabelPlanB =
    expectStepPlan
        [ contextInitStep
            "a"
            (StepFrame "frame|one" "b:c|Frame: one")
            (const (pure StepChanged))
        ]

sha256Text :: ByteString.ByteString -> Text.Text
sha256Text payload = Text.pack (show (Hash.hashWith Hash.SHA256 payload))

encodedWord64 :: Word64 -> ByteString.ByteString
encodedWord64 =
    LazyByteString.toStrict
        . Builder.toLazyByteString
        . Builder.word64BE

framedCount :: Text.Text -> Word64 -> ByteString.ByteString
framedCount tag count =
    LazyByteString.toStrict
        ( Builder.toLazyByteString
            ( Builder.word64BE (fromIntegral (ByteString.length bytes))
                <> Builder.byteString bytes
                <> Builder.word64BE count
            )
        )
  where
    bytes = TextEncoding.encodeUtf8 tag

hexBytes :: ByteString.ByteString -> Text.Text
hexBytes = Text.pack . concatMap byteHex . ByteString.unpack
  where
    byteHex byte =
        [ ByteStringChar8.index "0123456789abcdef" (fromIntegral (byte `div` 16))
        , ByteStringChar8.index "0123456789abcdef" (fromIntegral (byte `mod` 16))
        ]

goldenSnapshotBytesHex :: FilePath -> Text.Text
goldenSnapshotBytesHex root =
    Text.concat
        [ "484f5354424f4f5453545241502d504c414e0000000000000003"
        , hexFramedText "root"
        , hexRoot root
        , "000000000000000b737065632d646967657374"
        , "000000000000001038343033636432393734356430636239000000000000000d636f6e6669672d646967657374"
        , "00000000000000403430366337353637343137313330386530623433626239633765306135333930326466626134"
        , "35313836353635623834363265633130383361613136326663340000000000000005737465707300000000000000"
        , "01000000000000000473746570000000000000000b00000000000000076f7264696e616c000000000000000100"
        , "000000000000086964656e746974790000000000000009636f72652d73746570000000000000000c636f6e7465"
        , "78742d696e69740000000000000000000000000000000e696d706c656d656e746174696f6e0000000000000013"
        , "636f72652d696d706c656d656e746174696f6e000000000000000200000000000000086964656e746974790000"
        , "00000000000c636f6e746578742d696e6974000000000000000000000000000000087265766973696f6e000000"
        , "000000000100000000000000096f7065726174696f6e0000000000000011636f72653a636f6e746578742d696e"
        , "6974000000000000001470726f6a65637465642d6f7065726174696f6e73000000000000000100000000000000"
        , "1a636f72653a636f6e746578742d696e69742f72656c6174696f6e00000000000000056c6162656c0000000000"
        , "000007636f6e7465787400000000000000056672616d6500000000000000020000000000000002696400000000"
        , "00000004686f737400000000000000056c6162656c0000000000000004486f7374000000000000000c64657065"
        , "6e64656e636965730000000000000000000000000000000e726576657273652d706f6c69637900000000000000"
        , "0f70726f6a6563742d6d616e616765640000000000000000000000000000000f726576657273652d6164617074"
        , "6572000000000000000f70726f6a6563742d6d616e616765640000000000000002000000000000000e696d706c"
        , "656d656e746174696f6e010000000000000013636f72652d696d706c656d656e746174696f6e00000000000000"
        , "0200000000000000086964656e74697479000000000000000c636f6e746578742d696e69740000000000000000"
        , "00000000000000087265766973696f6e000000000000000100000000000000087265766973696f6e0000000000"
        , "000001000000000000000864657363656e74730000000000000000"
        ]

hexFramedText :: Text.Text -> Text.Text
hexFramedText value =
    let bytes = TextEncoding.encodeUtf8 value
     in hexBytes
            ( LazyByteString.toStrict
                ( Builder.toLazyByteString
                    ( Builder.word64BE (fromIntegral (ByteString.length bytes))
                        <> Builder.byteString bytes
                    )
                )
            )

hexRoot :: FilePath -> Text.Text
hexRoot root =
    hexBytes
        ( LazyByteString.toStrict
            ( Builder.toLazyByteString
                ( Builder.word64BE (fromIntegral (length root) * 4)
                    <> foldMap (Builder.word32BE . fromIntegral . ord) root
                )
            )
        )

expectStepPlan :: [Step] -> StepPlan
expectStepPlan = either (error . show) id . mkStepPlan

expectRight :: (Show failure) => Either failure value -> IO value
expectRight = either (fail . show) pure

joinPlan :: Either PlanError (Either PlanError value) -> Either PlanError value
joinPlan = either Left id

expectPlanAccepted :: Either PlanError () -> IO ()
expectPlanAccepted = either (assertFailure . show) pure
