{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Authoritative fresh and recovered project-plan admission.

Fresh admission generates its local plan identity inside the continuation.
Recovered Production admission instead retains the fixed identity generated
by existing-snapshot admission and exposes a candidate only after its complete
descriptive package and root-bound canonical snapshot agree.
-}
module HostBootstrap.ProjectPlan.Construct
    ( FinalizedProjectSpec
    , withFinalizedProjectSpec
    , withHarnessFinalizedProjectSpec
    , withFinalizedProjectSpecParts
    , finalizedProjectCodec
    , finalizedProjectServices
    , projectPlanStepPlan
    , projectPlanDrafts
    , withProjectPlan
    , ChildPlanAuthority
    , childPlanAuthorityBinding
    , withChildProjectPlan
    , withRecoveredProductionProjectPlanInputs
    , withRecoveredProductionProjectPlan
    )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Authority
    ( AuthorityError (AuthorityMalformedBinding)
    , ProjectVerb
    , projectVerbName
    )
import HostBootstrap.Config.Class
    ( ProjectCfg
    , ProjectCodec
    , projectCodecSpecDigest
    )
import HostBootstrap.Config.Fields
    ( ScopeKind
    )
import HostBootstrap.Config.Schema
    ( ValidatedConfig
    , VerifiedConfigHandoff
    , VerifiedConfigWire
    , validatedConfigDigest
    , validatedConfigSpecDigest
    , validatedConfigValue
    , verifiedConfigDigest
    , verifiedConfigHandoffBinding
    )
import HostBootstrap.Config.Schema.Internal
    ( reindexValidatedConfigKernel
    , withRecoverySpecReindexKernel
    )
import HostBootstrap.Config.Vocab
    ( Harness
    , HarnessConfigAuthority
    , Production
    )
import HostBootstrap.Lifecycle.Mode
    ( LifecycleProfile
    , RecoveredProductionLifecycleProfile
    , VerifiedPlanSnapshot
    , lifecycleProfileEpoch
    , lifecycleProfileName
    , lifecycleProfileProjectName
    , lifecycleProfileStoreIdentity
    , planSnapshotCanonicalBytes
    , planSnapshotConfigDigest
    , planSnapshotPlanDigest
    , planSnapshotProjectName
    , planSnapshotRevision
    , planSnapshotRunText
    , planSnapshotSpecDigest
    , planSnapshotStoreIdentity
    , recoveredProductionProfileCanonicalBytes
    , recoveredProductionProfileConfigDigest
    , recoveredProductionProfileEpoch
    , recoveredProductionProfilePlanDigest
    , recoveredProductionProfileProjectName
    , recoveredProductionProfileRevision
    , recoveredProductionProfileRunText
    , recoveredProductionProfileSpecDigest
    , recoveredProductionProfileStoreIdentity
    )
import HostBootstrap.Lifecycle.Plan
    ( planDigestBindingDigestKernel
    , projectPlanProfileEpochKernel
    , projectPlanProfileNameKernel
    , projectPlanProfileProjectNameKernel
    , projectPlanProfileStoreIdentityKernel
    , withChildProjectPlanKernel
    , withProjectPlanKernel
    , withRecoveredProjectPlanKernel
    )
import HostBootstrap.Lift.Context (LiftContext)
import HostBootstrap.ProjectPlan
    ( PlanDraft
    , PlanError (InvalidProjectPlan, PlanRecoveryEvidenceMismatch)
    , ProjectPlan
    , planDraftsFromValidatedBuilder
    , renderSnapshot
    , stablePlanSnapshotBytes
    , stablePlanSnapshotConfigDigest
    , stablePlanSnapshotDigest
    , stablePlanSnapshotRoot
    , stablePlanSnapshotSpecDigest
    )
import HostBootstrap.ProjectPlan.Snapshot
    ( BoundPlanSnapshot
    , PlanDigestBinding
    , boundPlanSnapshotBytes
    )
import HostBootstrap.ProjectPlan.Child.Internal
    ( ChildPlanAuthority
    , childPlanAuthorityBindingKernel
    , mintChildPlanAuthorityKernel
    )
import HostBootstrap.ProjectPlan.Construct.Internal
    ( FinalizedProjectSpec
    , finalizedProjectCodecKernel
    , finalizedProjectServicesKernel
    , reindexFinalizedProjectSpecKernel
    , withFinalizedProjectSpecKernel
    , withFinalizedProjectSpecPartsKernel
    , withHarnessFinalizedProjectSpecKernel
    )
import HostBootstrap.Handoff
    ( HandoffBinding
    , handoffBrokerGeneration
    , handoffChildConfigDigest
    , handoffInstalledProject
    , handoffPlanRevision
    , handoffScope
    , handoffStoreIdentity
    , handoffVerb
    )
import HostBootstrap.ProjectRoot
    ( CanonicalProjectRoot
    , canonicalProjectRootPath
    )
import HostBootstrap.Service
    ( FinalizedServiceRegistry
    , ServiceRegistry
    )
import HostBootstrap.Step
    ( StepPlan
    , StepPlanError
    )

{- | Jointly finalize a scope's project codec, service registry, and static
plan builder under one fresh specification identity.

The continuation is the only place the fresh @specDigest@ exists.  Both the
scope-specific runtime builder and the private static inputs come from the same
argument, so later Harness instantiation cannot silently substitute another
project definition.
-}
withFinalizedProjectSpec ::
    ScopeKind ->
    ProjectCodec scope initialDigest cfg ->
    ServiceRegistry cfg ->
    ( forall planScope rootId.
      CanonicalProjectRoot planScope rootId ->
      cfg planScope ->
      Either StepPlanError StepPlan
    ) ->
    ( forall planScope.
      cfg planScope ->
      Text ->
      Text ->
      LiftContext ->
      Either String (FilePath, cfg planScope, StepPlan)
    ) ->
    ( forall specDigest.
      FinalizedProjectSpec scope specDigest cfg ->
      result
    ) ->
    result
withFinalizedProjectSpec
    = withFinalizedProjectSpecKernel

{- | Re-instantiate the exact static definition retained by a Production
finalization under one exact generative Harness authority.

'withHarnessProjectCodec' mints the Harness base-codec identity, and
'withFinalizedProjectSpec' then hashes the same closed service manifest and
retains the same scope-polymorphic plan builder.  The result therefore has a
fresh Harness @specDigest@ and matching role codecs; no un-finalized Harness
codec crosses this boundary.
-}
withHarnessFinalizedProjectSpec ::
    (ProjectCfg cfg) =>
    HarnessConfigAuthority projectId runId ->
    FinalizedProjectSpec (Production projectId) productionSpecDigest cfg ->
    ( forall harnessSpecDigest.
      FinalizedProjectSpec
        (Harness projectId runId)
        harnessSpecDigest
        cfg ->
      result
    ) ->
    result
withHarnessFinalizedProjectSpec
    = withHarnessFinalizedProjectSpecKernel

{- | Eliminate one finalized specification as a matched codec, service
registry, and scope-specialized builder.  The callback cannot retain one part
under a different @scope@ or @specDigest@ without retaining the whole opaque
specification.
-}
withFinalizedProjectSpecParts ::
    FinalizedProjectSpec scope specDigest cfg ->
    ( ProjectCodec scope specDigest cfg ->
      FinalizedServiceRegistry scope specDigest (cfg scope) ->
      ( forall rootId.
        CanonicalProjectRoot scope rootId ->
        cfg scope ->
        Either StepPlanError StepPlan
      ) ->
      result
    ) ->
    result
withFinalizedProjectSpecParts = withFinalizedProjectSpecPartsKernel

-- | The exact full-project codec retained by a finalized specification.
finalizedProjectCodec ::
    FinalizedProjectSpec scope specDigest cfg ->
    ProjectCodec scope specDigest cfg
finalizedProjectCodec = finalizedProjectCodecKernel

-- | The exact service registry sharing the finalized specification identity.
finalizedProjectServices ::
    FinalizedProjectSpec scope specDigest cfg ->
    FinalizedServiceRegistry scope specDigest (cfg scope)
finalizedProjectServices = finalizedProjectServicesKernel

{- | Evaluate the finalized builder against the exact root and opaque validated
configuration that will own the plan.  This bridge exists while legacy
lifecycle interpreters still consume 'StepPlan'; new consumers should prefer
'projectPlanDrafts'.
-}
projectPlanStepPlan ::
    FinalizedProjectSpec scope specDigest cfg ->
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    Either StepPlanError StepPlan
projectPlanStepPlan finalizedSpec root config =
    withFinalizedProjectSpecPartsKernel finalizedSpec $ \_ _ planBuilder ->
        planBuilder root (validatedConfigValue config)

{- | Bind the finalized static builder to one exact root and validated
configuration and return its non-empty, identity-indexed draft stream.
-}
projectPlanDrafts ::
    FinalizedProjectSpec scope specDigest cfg ->
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    Either
        PlanError
        (NonEmpty (PlanDraft scope specDigest (cfg scope)))
projectPlanDrafts finalizedSpec root config =
    withFinalizedProjectSpecPartsKernel finalizedSpec $ \_ _ planBuilder ->
        case planDraftsFromValidatedBuilder root config planBuilder of
            Left failure -> Left (InvalidProjectPlan failure)
            Right drafts -> Right drafts

withProjectPlan ::
    LifecycleProfile scope ->
    CanonicalProjectRoot scope rootId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    NonEmpty (PlanDraft scope specDigest (cfg scope)) ->
    (forall planId. ProjectPlan scope specDigest planId configId cfg -> a) ->
    Either PlanError a
withProjectPlan profile root config drafts =
    withProjectPlanKernel
        (lifecycleProfileName profile)
        (lifecycleProfileEpoch profile)
        (lifecycleProfileProjectName profile)
        (lifecycleProfileStoreIdentity profile)
        root
        config
        drafts

-- | The authenticated binding retained by an exact child-plan authority.
childPlanAuthorityBinding ::
    ChildPlanAuthority
        scope specDigest planDigest brokerGeneration parentFrame childFrame
        planId configId verb phase ->
    HandoffBinding scope brokerGeneration
childPlanAuthorityBinding = childPlanAuthorityBindingKernel

{- | Admit the fresh local plan named by one exact authenticated child edge.

The config-kind refinement has already joined signature verification to the
constructor-hidden local wire/config identity.  This gate rechecks the closed
verb and exact config digest, derives lifecycle profile origin only from signed
binding fields, builds from the opaque draft root, and compares the resulting
stable plan digest with the signed parent revision.  Only their conjunction
yields the local plan, binding, and fully indexed child authority.
-}
withChildProjectPlan ::
    ProjectVerb verb ->
    VerifiedConfigHandoff
        scope planDigest brokerGeneration parentFrame childFrame configId verb phase ->
    VerifiedConfigWire scope configDigest configId ->
    ValidatedConfig scope specDigest configId (cfg scope) ->
    NonEmpty (PlanDraft scope specDigest (cfg scope)) ->
    ( forall planId.
      ChildPlanAuthority
        scope specDigest planDigest brokerGeneration parentFrame childFrame
        planId configId verb phase ->
      ProjectPlan scope specDigest planId configId cfg ->
      PlanDigestBinding scope specDigest planDigest planId ->
      a
    ) ->
    Either AuthorityError a
withChildProjectPlan verb handoff wire config drafts use = do
    profileName <- childProfileName binding
    require "project verb" (handoffVerb binding) (projectVerbName verb)
    require
        "verified config wire digest"
        (handoffChildConfigDigest binding)
        (verifiedConfigDigest wire)
    require
        "validated config digest"
        (handoffChildConfigDigest binding)
        (validatedConfigDigest config)
    either
        (Left . AuthorityMalformedBinding . ("child plan admission failed: " <>) . Text.pack . show)
        Right
        ( withChildProjectPlanKernel
            profileName
            (handoffBrokerGeneration binding)
            (handoffInstalledProject binding)
            (handoffStoreIdentity binding)
            (handoffPlanRevision binding)
            config
            drafts
            (\plan digestBinding ->
                use
                    (mintChildPlanAuthorityKernel handoff plan digestBinding)
                    plan
                    digestBinding
            )
        )
  where
    binding = verifiedConfigHandoffBinding handoff
    require subject expected observed
        | expected == observed = Right ()
        | otherwise =
            Left
                ( AuthorityMalformedBinding
                    (subject <> " does not match the authenticated handoff")
                )

childProfileName :: HandoffBinding scope brokerGeneration -> Either AuthorityError Text
childProfileName binding
    | handoffScope binding == "Production" = Right "production"
    | Just runName <- Text.stripPrefix "Harness " (handoffScope binding)
    , not (Text.null runName) = Right ("harness:" <> runName)
    | otherwise =
        Left
            ( AuthorityMalformedBinding
                "the authenticated handoff carries an unknown lifecycle scope"
            )

{- | Safely align one independently re-decoded finalized Production
specification and configuration with the specification identity retained by a
recovered profile.

Existing-snapshot admission must generate its specification index from the
protected record, while ordinary configuration decoding generates the same
stable specification under a different local phantom.  This bridge compares
the finalized codec and validated configuration's retained specification text
with the recovered profile, preserves the exact @configId@ and decoded value,
then regenerates drafts from the finalized specification's private builder
under the recovered index.  One token joins both relabellings, so the yielded
specification, configuration, and drafts share the recovered profile's index by
construction.  No equality is accepted from caller-supplied evidence and no plan
identity is generated here.
-}
withRecoveredProductionProjectPlanInputs ::
    RecoveredProductionLifecycleProfile
        projectId recoveredSpecDigest planDigest planId brokerGeneration ->
    CanonicalProjectRoot (Production projectId) rootId ->
    FinalizedProjectSpec
        (Production projectId)
        candidateSpecDigest
        cfg ->
    ValidatedConfig
        (Production projectId)
        candidateSpecDigest
        configId
        (cfg (Production projectId)) ->
    ( FinalizedProjectSpec
        (Production projectId)
        recoveredSpecDigest
        cfg ->
      ValidatedConfig
        (Production projectId)
        recoveredSpecDigest
        configId
        (cfg (Production projectId)) ->
      NonEmpty
        ( PlanDraft
            (Production projectId)
            recoveredSpecDigest
            (cfg (Production projectId))
        ) ->
      result
    ) ->
    Either PlanError result
withRecoveredProductionProjectPlanInputs
    profile
    root
    finalizedSpec
    candidateConfig
    use =
        withFinalizedProjectSpecPartsKernel finalizedSpec $ \codec _ planBuilder ->
            let recoveredSpec = recoveredProductionProfileSpecDigest profile
                admitRefined recoveredSpecification recoveredConfig = do
                    requireText
                        "validated configuration digest"
                        (recoveredProductionProfileConfigDigest profile)
                        (validatedConfigDigest recoveredConfig)
                    drafts <-
                        case planDraftsFromValidatedBuilder root recoveredConfig planBuilder of
                            Left failure -> Left (InvalidProjectPlan failure)
                            Right exactDrafts -> Right exactDrafts
                    Right (use recoveredSpecification recoveredConfig drafts)
                reindexed =
                    withRecoverySpecReindexKernel
                        recoveredSpec
                        (projectCodecSpecDigest codec)
                        ( \token ->
                            ( reindexFinalizedProjectSpecKernel token finalizedSpec
                            , reindexValidatedConfigKernel token candidateConfig
                            )
                        )
             in case reindexed of
                    Left (expected, observed) ->
                        recoveryMismatch "finalized specification" expected observed
                    Right (Left (expected, observed), _) ->
                        recoveryMismatch
                            "finalized specification carriers"
                            expected
                            observed
                    Right (Right _, Left (expected, observed)) ->
                        recoveryMismatch
                            "validated configuration specification"
                            expected
                            observed
                    Right (Right recoveredSpecification, Right recoveredConfig) ->
                        admitRefined recoveredSpecification recoveredConfig

{- | Reconstruct the exact Production project plan named by an existing Open
recovery package.

The recovered profile fixes @projectId@, @specDigest@, @planDigest@, @planId@,
and @brokerGeneration@ before this function is entered. The constructor first
cross-checks every retained descriptive input, then builds a fixed-identity
candidate through the same root/draft/configuration validator as fresh
admission. Only exact origin, root, canonical bytes, and digest agreement
reaches the callback. This pure boundary opens no store, journal, cursor, or
effect authority.
-}
withRecoveredProductionProjectPlan ::
    RecoveredProductionLifecycleProfile
        projectId specDigest planDigest planId brokerGeneration ->
    CanonicalProjectRoot (Production projectId) rootId ->
    VerifiedPlanSnapshot
        (Production projectId) specDigest planDigest ->
    BoundPlanSnapshot
        (Production projectId) specDigest planDigest planId ->
    PlanDigestBinding
        (Production projectId) specDigest planDigest planId ->
    ValidatedConfig
        (Production projectId)
        specDigest
        configId
        (cfg (Production projectId)) ->
    NonEmpty
        ( PlanDraft
            (Production projectId)
            specDigest
            (cfg (Production projectId))
        ) ->
    ( ProjectPlan
        (Production projectId)
        specDigest
        planId
        configId
        cfg ->
      a
    ) ->
    Either PlanError a
withRecoveredProductionProjectPlan
    profile
    root
    verified
    bound
    binding
    config
    drafts
    use = do
        validateRecoveredInputs
        candidate <-
            withRecoveredProjectPlanKernel
                profileRun
                profileEpoch
                profileProject
                profileStore
                root
                config
                drafts
                id
        validateCandidate candidate
        Right (use candidate)
  where
        profileRun = recoveredProductionProfileRunText profile
        profileProject = recoveredProductionProfileProjectName profile
        profileStore = recoveredProductionProfileStoreIdentity profile
        profileRevision = recoveredProductionProfileRevision profile
        profileSpec = recoveredProductionProfileSpecDigest profile
        profilePlan = recoveredProductionProfilePlanDigest profile
        profileConfig = recoveredProductionProfileConfigDigest profile
        profileBytes = recoveredProductionProfileCanonicalBytes profile
        profileEpoch = recoveredProductionProfileEpoch profile
        validateRecoveredInputs = do
            requireText "recovered profile run" "production" profileRun
            requireNonemptyText "recovered profile project" profileProject
            requireNonemptyText "recovered profile store" profileStore
            requirePositiveWord "recovered profile revision" profileRevision
            requireNonemptyText "recovered profile specification" profileSpec
            requireNonemptyText "recovered profile plan" profilePlan
            requireNonemptyText "recovered profile configuration" profileConfig
            requireNonemptyBytes "recovered profile canonical bytes" profileBytes
            requirePositiveWord "recovered profile epoch" profileEpoch
            requireText "verified snapshot run" profileRun (planSnapshotRunText verified)
            requireText
                "verified snapshot project"
                profileProject
                (planSnapshotProjectName verified)
            requireText
                "verified snapshot store"
                profileStore
                (planSnapshotStoreIdentity verified)
            requireWord
                "verified snapshot revision"
                profileRevision
                (planSnapshotRevision verified)
            requireText
                "verified snapshot specification"
                profileSpec
                (planSnapshotSpecDigest verified)
            requireText
                "verified snapshot plan"
                profilePlan
                (planSnapshotPlanDigest verified)
            requireMaybeText
                "verified snapshot configuration"
                profileConfig
                (planSnapshotConfigDigest verified)
            requireMaybeBytes
                "verified snapshot canonical bytes"
                profileBytes
                (planSnapshotCanonicalBytes verified)
            requireBytes
                "bound snapshot canonical bytes"
                profileBytes
                (boundPlanSnapshotBytes bound)
            requireText
                "plan digest binding"
                profilePlan
                (planDigestBindingDigestKernel binding)
            requireText
                "validated configuration specification"
                profileSpec
                (validatedConfigSpecDigest config)
            requireText
                "validated configuration digest"
                profileConfig
                (validatedConfigDigest config)
        validateCandidate candidate = do
            requireText
                "candidate profile name"
                profileRun
                (projectPlanProfileNameKernel candidate)
            requireText
                "candidate project"
                profileProject
                (projectPlanProfileProjectNameKernel candidate)
            requireText
                "candidate store"
                profileStore
                (projectPlanProfileStoreIdentityKernel candidate)
            requireWord
                "candidate epoch"
                profileEpoch
                (projectPlanProfileEpochKernel candidate)
            let snapshot = renderSnapshot candidate
            requireRoot
                "candidate canonical root"
                (canonicalProjectRootPath root)
                (stablePlanSnapshotRoot snapshot)
            requireText
                "candidate specification"
                profileSpec
                (stablePlanSnapshotSpecDigest snapshot)
            requireText
                "candidate configuration"
                profileConfig
                (stablePlanSnapshotConfigDigest snapshot)
            requireBytes
                "candidate canonical bytes"
                profileBytes
                (stablePlanSnapshotBytes snapshot)
            requireText
                "candidate plan digest"
                profilePlan
                (stablePlanSnapshotDigest snapshot)

requireText :: Text -> Text -> Text -> Either PlanError ()
requireText subject expected observed
    | expected == observed = Right ()
    | otherwise = recoveryMismatch subject expected observed

requireNonemptyText :: Text -> Text -> Either PlanError ()
requireNonemptyText subject observed
    | Text.null observed = recoveryMismatch subject "nonempty" "empty"
    | otherwise = Right ()

requireWord :: (Show word, Eq word) => Text -> word -> word -> Either PlanError ()
requireWord subject expected observed
    | expected == observed = Right ()
    | otherwise =
        recoveryMismatch
            subject
            (Text.pack (show expected))
            (Text.pack (show observed))

requirePositiveWord :: (Ord word, Num word, Show word) => Text -> word -> Either PlanError ()
requirePositiveWord subject observed
    | observed > 0 = Right ()
    | otherwise = recoveryMismatch subject "positive" (Text.pack (show observed))

requireMaybeText :: Text -> Text -> Maybe Text -> Either PlanError ()
requireMaybeText subject expected observed =
    case observed of
        Nothing -> recoveryMismatch subject "present" "absent"
        Just value -> requireText subject expected value

requireMaybeBytes :: Text -> ByteString -> Maybe ByteString -> Either PlanError ()
requireMaybeBytes subject expected observed =
    case observed of
        Nothing -> recoveryMismatch subject "present" "absent"
        Just value -> requireBytes subject expected value

requireNonemptyBytes :: Text -> ByteString -> Either PlanError ()
requireNonemptyBytes subject observed
    | ByteString.null observed = recoveryMismatch subject "nonempty" "empty"
    | otherwise = Right ()

requireBytes :: Text -> ByteString -> ByteString -> Either PlanError ()
requireBytes subject expected observed
    | expected == observed = Right ()
    | otherwise =
        recoveryMismatch
            subject
            "exact recovered-profile canonical bytes"
            "different canonical bytes"

requireRoot :: Text -> FilePath -> FilePath -> Either PlanError ()
requireRoot subject expected observed
    | expected == observed = Right ()
    | otherwise =
        recoveryMismatch
            subject
            "exact supplied canonical root"
            "different root descriptor"

recoveryMismatch :: Text -> Text -> Text -> Either PlanError result
recoveryMismatch subject expected observed =
    Left (PlanRecoveryEvidenceMismatch subject expected observed)
