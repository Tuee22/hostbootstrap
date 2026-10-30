{-# LANGUAGE DataKinds #-}

module CoerceRoleLifecycleAuthorityRoles where

import Data.Coerce (coerce)
import HostBootstrap.RoleLifecycle (
    EffectAuthorization,
    RoleCursor,
    RoleEffect (NetworkListen),
    RolePlan,
    RolePlanDigestBinding,
    VerifiedServicePlacement,
 )

data CursorScopeA
data CursorScopeB
data CursorPlanA
data CursorPlanB
data CursorFrameA
data CursorFrameB
data CursorInstanceA
data CursorInstanceB
data CursorPhaseA
data CursorPhaseB

type Cursor s p f i ph = RoleCursor s p f i ph

cursorScope ::
    Cursor CursorScopeA CursorPlanA CursorFrameA CursorInstanceA CursorPhaseA ->
    Cursor CursorScopeB CursorPlanA CursorFrameA CursorInstanceA CursorPhaseA
cursorScope = coerce

cursorPlan ::
    Cursor CursorScopeA CursorPlanA CursorFrameA CursorInstanceA CursorPhaseA ->
    Cursor CursorScopeA CursorPlanB CursorFrameA CursorInstanceA CursorPhaseA
cursorPlan = coerce

cursorFrame ::
    Cursor CursorScopeA CursorPlanA CursorFrameA CursorInstanceA CursorPhaseA ->
    Cursor CursorScopeA CursorPlanA CursorFrameB CursorInstanceA CursorPhaseA
cursorFrame = coerce

cursorInstance ::
    Cursor CursorScopeA CursorPlanA CursorFrameA CursorInstanceA CursorPhaseA ->
    Cursor CursorScopeA CursorPlanA CursorFrameA CursorInstanceB CursorPhaseA
cursorInstance = coerce

cursorPhase ::
    Cursor CursorScopeA CursorPlanA CursorFrameA CursorInstanceA CursorPhaseA ->
    Cursor CursorScopeA CursorPlanA CursorFrameA CursorInstanceA CursorPhaseB
cursorPhase = coerce

data PlanScopeA
data PlanScopeB
data PlanSpecA
data PlanSpecB
data PlanIdentityA
data PlanIdentityB
data PlanConfigA
data PlanConfigB
data PlanSecretA
data PlanSecretB
data PlanFrameA
data PlanFrameB
data PlanRevisionA
data PlanRevisionB
data PlanInstanceA
data PlanInstanceB

type Plan s sd p c sec f r i = RolePlan s sd p c sec f r i

planScope ::
    Plan PlanScopeA PlanSpecA PlanIdentityA PlanConfigA PlanSecretA PlanFrameA PlanRevisionA PlanInstanceA ->
    Plan PlanScopeB PlanSpecA PlanIdentityA PlanConfigA PlanSecretA PlanFrameA PlanRevisionA PlanInstanceA
planScope = coerce

planSpec ::
    Plan PlanScopeA PlanSpecA PlanIdentityA PlanConfigA PlanSecretA PlanFrameA PlanRevisionA PlanInstanceA ->
    Plan PlanScopeA PlanSpecB PlanIdentityA PlanConfigA PlanSecretA PlanFrameA PlanRevisionA PlanInstanceA
planSpec = coerce

planIdentity ::
    Plan PlanScopeA PlanSpecA PlanIdentityA PlanConfigA PlanSecretA PlanFrameA PlanRevisionA PlanInstanceA ->
    Plan PlanScopeA PlanSpecA PlanIdentityB PlanConfigA PlanSecretA PlanFrameA PlanRevisionA PlanInstanceA
planIdentity = coerce

planConfig ::
    Plan PlanScopeA PlanSpecA PlanIdentityA PlanConfigA PlanSecretA PlanFrameA PlanRevisionA PlanInstanceA ->
    Plan PlanScopeA PlanSpecA PlanIdentityA PlanConfigB PlanSecretA PlanFrameA PlanRevisionA PlanInstanceA
planConfig = coerce

planSecret ::
    Plan PlanScopeA PlanSpecA PlanIdentityA PlanConfigA PlanSecretA PlanFrameA PlanRevisionA PlanInstanceA ->
    Plan PlanScopeA PlanSpecA PlanIdentityA PlanConfigA PlanSecretB PlanFrameA PlanRevisionA PlanInstanceA
planSecret = coerce

planFrame ::
    Plan PlanScopeA PlanSpecA PlanIdentityA PlanConfigA PlanSecretA PlanFrameA PlanRevisionA PlanInstanceA ->
    Plan PlanScopeA PlanSpecA PlanIdentityA PlanConfigA PlanSecretA PlanFrameB PlanRevisionA PlanInstanceA
planFrame = coerce

planRevision ::
    Plan PlanScopeA PlanSpecA PlanIdentityA PlanConfigA PlanSecretA PlanFrameA PlanRevisionA PlanInstanceA ->
    Plan PlanScopeA PlanSpecA PlanIdentityA PlanConfigA PlanSecretA PlanFrameA PlanRevisionB PlanInstanceA
planRevision = coerce

planInstance ::
    Plan PlanScopeA PlanSpecA PlanIdentityA PlanConfigA PlanSecretA PlanFrameA PlanRevisionA PlanInstanceA ->
    Plan PlanScopeA PlanSpecA PlanIdentityA PlanConfigA PlanSecretA PlanFrameA PlanRevisionA PlanInstanceB
planInstance = coerce

data BindingScopeA
data BindingScopeB
data BindingSpecA
data BindingSpecB
data BindingPlanDigestA
data BindingPlanDigestB
data BindingRoleDigestA
data BindingRoleDigestB
data BindingPlanA
data BindingPlanB

type Binding s sd pd rd p = RolePlanDigestBinding s sd pd rd p

bindingScope ::
    Binding BindingScopeA BindingSpecA BindingPlanDigestA BindingRoleDigestA BindingPlanA ->
    Binding BindingScopeB BindingSpecA BindingPlanDigestA BindingRoleDigestA BindingPlanA
bindingScope = coerce

bindingSpec ::
    Binding BindingScopeA BindingSpecA BindingPlanDigestA BindingRoleDigestA BindingPlanA ->
    Binding BindingScopeA BindingSpecB BindingPlanDigestA BindingRoleDigestA BindingPlanA
bindingSpec = coerce

bindingPlanDigest ::
    Binding BindingScopeA BindingSpecA BindingPlanDigestA BindingRoleDigestA BindingPlanA ->
    Binding BindingScopeA BindingSpecA BindingPlanDigestB BindingRoleDigestA BindingPlanA
bindingPlanDigest = coerce

bindingRoleDigest ::
    Binding BindingScopeA BindingSpecA BindingPlanDigestA BindingRoleDigestA BindingPlanA ->
    Binding BindingScopeA BindingSpecA BindingPlanDigestA BindingRoleDigestB BindingPlanA
bindingRoleDigest = coerce

bindingPlan ::
    Binding BindingScopeA BindingSpecA BindingPlanDigestA BindingRoleDigestA BindingPlanA ->
    Binding BindingScopeA BindingSpecA BindingPlanDigestA BindingRoleDigestA BindingPlanB
bindingPlan = coerce

data PlacementScopeA
data PlacementScopeB
data PlacementSpecA
data PlacementSpecB
data PlacementPlanA
data PlacementPlanB
data PlacementFrameA
data PlacementFrameB
data PlacementRevisionA
data PlacementRevisionB
data PlacementInstanceA
data PlacementInstanceB
data PlacementServiceA
data PlacementServiceB
data PlacementEffectsA
data PlacementEffectsB

type Placement s sd p f r i svc eff = VerifiedServicePlacement s sd p f r i svc eff

placementScope ::
    Placement PlacementScopeA PlacementSpecA PlacementPlanA PlacementFrameA PlacementRevisionA PlacementInstanceA PlacementServiceA PlacementEffectsA ->
    Placement PlacementScopeB PlacementSpecA PlacementPlanA PlacementFrameA PlacementRevisionA PlacementInstanceA PlacementServiceA PlacementEffectsA
placementScope = coerce

placementSpec ::
    Placement PlacementScopeA PlacementSpecA PlacementPlanA PlacementFrameA PlacementRevisionA PlacementInstanceA PlacementServiceA PlacementEffectsA ->
    Placement PlacementScopeA PlacementSpecB PlacementPlanA PlacementFrameA PlacementRevisionA PlacementInstanceA PlacementServiceA PlacementEffectsA
placementSpec = coerce

placementPlan ::
    Placement PlacementScopeA PlacementSpecA PlacementPlanA PlacementFrameA PlacementRevisionA PlacementInstanceA PlacementServiceA PlacementEffectsA ->
    Placement PlacementScopeA PlacementSpecA PlacementPlanB PlacementFrameA PlacementRevisionA PlacementInstanceA PlacementServiceA PlacementEffectsA
placementPlan = coerce

placementFrame ::
    Placement PlacementScopeA PlacementSpecA PlacementPlanA PlacementFrameA PlacementRevisionA PlacementInstanceA PlacementServiceA PlacementEffectsA ->
    Placement PlacementScopeA PlacementSpecA PlacementPlanA PlacementFrameB PlacementRevisionA PlacementInstanceA PlacementServiceA PlacementEffectsA
placementFrame = coerce

placementRevision ::
    Placement PlacementScopeA PlacementSpecA PlacementPlanA PlacementFrameA PlacementRevisionA PlacementInstanceA PlacementServiceA PlacementEffectsA ->
    Placement PlacementScopeA PlacementSpecA PlacementPlanA PlacementFrameA PlacementRevisionB PlacementInstanceA PlacementServiceA PlacementEffectsA
placementRevision = coerce

placementInstance ::
    Placement PlacementScopeA PlacementSpecA PlacementPlanA PlacementFrameA PlacementRevisionA PlacementInstanceA PlacementServiceA PlacementEffectsA ->
    Placement PlacementScopeA PlacementSpecA PlacementPlanA PlacementFrameA PlacementRevisionA PlacementInstanceB PlacementServiceA PlacementEffectsA
placementInstance = coerce

placementService ::
    Placement PlacementScopeA PlacementSpecA PlacementPlanA PlacementFrameA PlacementRevisionA PlacementInstanceA PlacementServiceA PlacementEffectsA ->
    Placement PlacementScopeA PlacementSpecA PlacementPlanA PlacementFrameA PlacementRevisionA PlacementInstanceA PlacementServiceB PlacementEffectsA
placementService = coerce

placementEffects ::
    Placement PlacementScopeA PlacementSpecA PlacementPlanA PlacementFrameA PlacementRevisionA PlacementInstanceA PlacementServiceA PlacementEffectsA ->
    Placement PlacementScopeA PlacementSpecA PlacementPlanA PlacementFrameA PlacementRevisionA PlacementInstanceA PlacementServiceA PlacementEffectsB
placementEffects = coerce

data AuthorizationScopeA
data AuthorizationScopeB
data AuthorizationSpecA
data AuthorizationSpecB
data AuthorizationPlanA
data AuthorizationPlanB
data AuthorizationFrameA
data AuthorizationFrameB
data AuthorizationRevisionA
data AuthorizationRevisionB
data AuthorizationInstanceA
data AuthorizationInstanceB
data AuthorizationServiceA
data AuthorizationServiceB

type Authorization s sd p f r i svc es = EffectAuthorization s sd p f r i svc es

authorizationScope ::
    Authorization AuthorizationScopeA AuthorizationSpecA AuthorizationPlanA AuthorizationFrameA AuthorizationRevisionA AuthorizationInstanceA AuthorizationServiceA '[ 'NetworkListen] ->
    Authorization AuthorizationScopeB AuthorizationSpecA AuthorizationPlanA AuthorizationFrameA AuthorizationRevisionA AuthorizationInstanceA AuthorizationServiceA '[ 'NetworkListen]
authorizationScope = coerce

authorizationSpec ::
    Authorization AuthorizationScopeA AuthorizationSpecA AuthorizationPlanA AuthorizationFrameA AuthorizationRevisionA AuthorizationInstanceA AuthorizationServiceA '[ 'NetworkListen] ->
    Authorization AuthorizationScopeA AuthorizationSpecB AuthorizationPlanA AuthorizationFrameA AuthorizationRevisionA AuthorizationInstanceA AuthorizationServiceA '[ 'NetworkListen]
authorizationSpec = coerce

authorizationPlan ::
    Authorization AuthorizationScopeA AuthorizationSpecA AuthorizationPlanA AuthorizationFrameA AuthorizationRevisionA AuthorizationInstanceA AuthorizationServiceA '[ 'NetworkListen] ->
    Authorization AuthorizationScopeA AuthorizationSpecA AuthorizationPlanB AuthorizationFrameA AuthorizationRevisionA AuthorizationInstanceA AuthorizationServiceA '[ 'NetworkListen]
authorizationPlan = coerce

authorizationFrame ::
    Authorization AuthorizationScopeA AuthorizationSpecA AuthorizationPlanA AuthorizationFrameA AuthorizationRevisionA AuthorizationInstanceA AuthorizationServiceA '[ 'NetworkListen] ->
    Authorization AuthorizationScopeA AuthorizationSpecA AuthorizationPlanA AuthorizationFrameB AuthorizationRevisionA AuthorizationInstanceA AuthorizationServiceA '[ 'NetworkListen]
authorizationFrame = coerce

authorizationRevision ::
    Authorization AuthorizationScopeA AuthorizationSpecA AuthorizationPlanA AuthorizationFrameA AuthorizationRevisionA AuthorizationInstanceA AuthorizationServiceA '[ 'NetworkListen] ->
    Authorization AuthorizationScopeA AuthorizationSpecA AuthorizationPlanA AuthorizationFrameA AuthorizationRevisionB AuthorizationInstanceA AuthorizationServiceA '[ 'NetworkListen]
authorizationRevision = coerce

authorizationInstance ::
    Authorization AuthorizationScopeA AuthorizationSpecA AuthorizationPlanA AuthorizationFrameA AuthorizationRevisionA AuthorizationInstanceA AuthorizationServiceA '[ 'NetworkListen] ->
    Authorization AuthorizationScopeA AuthorizationSpecA AuthorizationPlanA AuthorizationFrameA AuthorizationRevisionA AuthorizationInstanceB AuthorizationServiceA '[ 'NetworkListen]
authorizationInstance = coerce

authorizationService ::
    Authorization AuthorizationScopeA AuthorizationSpecA AuthorizationPlanA AuthorizationFrameA AuthorizationRevisionA AuthorizationInstanceA AuthorizationServiceA '[ 'NetworkListen] ->
    Authorization AuthorizationScopeA AuthorizationSpecA AuthorizationPlanA AuthorizationFrameA AuthorizationRevisionA AuthorizationInstanceA AuthorizationServiceB '[ 'NetworkListen]
authorizationService = coerce

authorizationEffects ::
    Authorization AuthorizationScopeA AuthorizationSpecA AuthorizationPlanA AuthorizationFrameA AuthorizationRevisionA AuthorizationInstanceA AuthorizationServiceA authorizationEffectsA ->
    Authorization AuthorizationScopeA AuthorizationSpecA AuthorizationPlanA AuthorizationFrameA AuthorizationRevisionA AuthorizationInstanceA AuthorizationServiceA authorizationEffectsB
authorizationEffects = coerce
