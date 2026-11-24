{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Hidden ownership and child-projection kernel for finalized project specs.
module HostBootstrap.ProjectPlan.Construct.Internal (
    FinalizedProjectSpec,
    finalizedProjectCodecKernel,
    finalizedProjectServicesKernel,
    withFinalizedProjectSpecKernel,
    withHarnessFinalizedProjectSpecKernel,
    withFinalizedProjectSpecPartsKernel,
    withFinalizedForwardChildProjectionKernel,
    reindexFinalizedProjectSpecKernel,
    refuseForwardChildPlan,
)
where

import Data.Proxy (Proxy (Proxy))
import Data.Text (Text)
import qualified Data.Text as Text
import HostBootstrap.Config.Class (
    ProjectCfg (withHarnessProjectCodec),
    ProjectCodec,
 )
import HostBootstrap.Config.Class.Internal (reindexProjectCodecKernel)
import HostBootstrap.Config.Fields (KnownScopeKind (scopeKindOf))
import HostBootstrap.Config.Schema (
    ValidatedConfig,
    validatedConfigValue,
    withValidatedConfig,
 )
import HostBootstrap.Config.Schema.Internal (RecoverySpecReindex)
import HostBootstrap.Config.Vocab (
    Harness,
    HarnessConfigAuthority,
    Production,
 )
import HostBootstrap.Lift.Context (LiftContext)
import HostBootstrap.ProjectRoot (CanonicalProjectRoot)
import HostBootstrap.Service (
    FinalizedServiceRegistry,
    ServiceRegistry,
    withFinalizedServiceRegistry,
 )
import HostBootstrap.Lifecycle.FrameRole (ChildFrameId, ParentFrameId)
import HostBootstrap.Service.Internal (reindexFinalizedServiceRegistryKernel)
import HostBootstrap.Step (StepPlan, StepPlanError)

-- | Default for a finalized project that cannot project a forward child.
refuseForwardChildPlan ::
    cfg scope -> ParentFrameId -> ChildFrameId -> LiftContext -> Either String (FilePath, cfg scope, StepPlan)
refuseForwardChildPlan _ _ _ _ = Left "forward-child projection is unavailable"

{- | One jointly finalized runtime view and its exact static definition.

The constructor and every retained field stay in this hidden owner.  Public
eliminators expose the legacy codec/services/builder view but never either
projector field.
-}
data FinalizedProjectSpec scope specDigest cfg
    = FinalizedProjectSpec
        (ProjectCodec scope specDigest cfg)
        (FinalizedServiceRegistry scope specDigest (cfg scope))
        ( forall rootId.
          CanonicalProjectRoot scope rootId ->
          cfg scope ->
          Either StepPlanError StepPlan
        )
        ( cfg scope ->
          ParentFrameId ->
          ChildFrameId ->
          LiftContext ->
          Either String (FilePath, cfg scope, StepPlan)
        )
        (ServiceRegistry cfg)
        ( forall planScope rootId.
          CanonicalProjectRoot planScope rootId ->
          cfg planScope ->
          Either StepPlanError StepPlan
        )
        ( forall planScope.
          cfg planScope ->
          ParentFrameId ->
          ChildFrameId ->
          LiftContext ->
          Either String (FilePath, cfg planScope, StepPlan)
        )

type role FinalizedProjectSpec nominal nominal nominal

withFinalizedProjectSpecKernel ::
    forall scope specDigest cfg result.
    (KnownScopeKind scope) =>
    ProjectCodec scope specDigest cfg ->
    ServiceRegistry cfg ->
    ( forall planScope rootId.
      CanonicalProjectRoot planScope rootId ->
      cfg planScope ->
      Either StepPlanError StepPlan
    ) ->
    ( forall planScope.
      cfg planScope ->
      ParentFrameId ->
      ChildFrameId ->
      LiftContext ->
      Either String (FilePath, cfg planScope, StepPlan)
    ) ->
    ( forall finalSpecDigest.
      FinalizedProjectSpec scope finalSpecDigest cfg ->
      result
    ) ->
    result
withFinalizedProjectSpecKernel
    baseCodec
    staticServices
    staticPlanBuilder
    staticProjector
    use =
        withFinalizedServiceRegistry
            (scopeKindOf (Proxy @scope))
            baseCodec
            staticServices
            ( \finalCodec finalServices ->
                use
                    ( FinalizedProjectSpec
                        finalCodec
                        finalServices
                        staticPlanBuilder
                        staticProjector
                        staticServices
                        staticPlanBuilder
                        staticProjector
                    )
            )

withHarnessFinalizedProjectSpecKernel ::
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
withHarnessFinalizedProjectSpecKernel
    authority
    (FinalizedProjectSpec _ _ _ _ staticServices staticPlanBuilder staticProjector)
    use =
        withHarnessProjectCodec authority $ \baseCodec ->
            withFinalizedProjectSpecKernel
                baseCodec
                staticServices
                staticPlanBuilder
                staticProjector
                use

withFinalizedProjectSpecPartsKernel ::
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
withFinalizedProjectSpecPartsKernel
    (FinalizedProjectSpec codec services builder _ _ _ _)
    use = use codec services builder

finalizedProjectCodecKernel ::
    FinalizedProjectSpec scope specDigest cfg ->
    ProjectCodec scope specDigest cfg
finalizedProjectCodecKernel (FinalizedProjectSpec codec _ _ _ _ _ _) = codec

finalizedProjectServicesKernel ::
    FinalizedProjectSpec scope specDigest cfg ->
    FinalizedServiceRegistry scope specDigest (cfg scope)
finalizedProjectServicesKernel (FinalizedProjectSpec _ services _ _ _ _ _) = services

{- | Join the two lower carrier reindexes under one digest-equality token.

Only the codec and the finalized registry carry the specification phantom; the
scope-specialized builder, the forward-child projector, and the retained static
definition are specification-index-free already and are preserved verbatim.  The
kernel therefore relabels one index and installs nothing: a token minted from
unequal digests, or a carrier whose own retained digest disagrees with it, is a
refusal.
-}
reindexFinalizedProjectSpecKernel ::
    RecoverySpecReindex targetSpecDigest ->
    FinalizedProjectSpec scope sourceSpecDigest cfg ->
    Either (Text, Text) (FinalizedProjectSpec scope targetSpecDigest cfg)
reindexFinalizedProjectSpecKernel
    token
    ( FinalizedProjectSpec
            codec
            services
            planBuilder
            projector
            staticServices
            staticPlanBuilder
            staticProjector
        ) = do
        reindexedCodec <- reindexProjectCodecKernel token codec
        reindexedServices <- reindexFinalizedServiceRegistryKernel token services
        Right
            ( FinalizedProjectSpec
                reindexedCodec
                reindexedServices
                planBuilder
                projector
                staticServices
                staticPlanBuilder
                staticProjector
            )

{- | Run the exact retained projector and validate its child config canonically.

The parent config fixes the finalized codec and scope.  The generated wire is
discarded, and the fixed continuation receives only the projected path,
validated child config, and projected step plan.
-}
withFinalizedForwardChildProjectionKernel ::
    FinalizedProjectSpec scope specDigest cfg ->
    ValidatedConfig scope specDigest parentConfigId (cfg scope) ->
    ParentFrameId ->
    ChildFrameId ->
    LiftContext ->
    ( forall childConfigId.
      FilePath ->
      ValidatedConfig scope specDigest childConfigId (cfg scope) ->
      StepPlan ->
      IO (Either Text ())
    ) ->
    IO (Either Text ())
withFinalizedForwardChildProjectionKernel
    (FinalizedProjectSpec codec _ _ projector _ _ _)
    parentConfig
    parentFrame
    childFrame
    liftContext
    use =
        case projector
            (validatedConfigValue parentConfig)
            parentFrame
            childFrame
            liftContext of
            Left failure ->
                let detail = Text.pack failure
                 in detail `seq` pure (Left detail)
            Right (path, childConfig, plan) -> do
                validated <-
                    withValidatedConfig codec childConfig $ \_wire exactConfig ->
                        use path exactConfig plan
                case validated of
                    Left failure ->
                        let detail = Text.pack failure
                         in detail `seq` pure (Left detail)
                    Right (Left failure) -> failure `seq` pure (Left failure)
                    Right (Right ()) -> pure (Right ())
