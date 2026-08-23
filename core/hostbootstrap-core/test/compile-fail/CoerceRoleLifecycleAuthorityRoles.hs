{-# LANGUAGE DataKinds #-}

module CoerceRoleLifecycleAuthorityRoles where

import Data.Coerce (coerce)
import HostBootstrap.RoleLifecycle
    ( EffectAuthorization
    , RoleCursor
    , RoleEffect (DurableStore, NetworkListen)
    , RolePlan
    , RolePlanDigestBinding
    , VerifiedServicePlacement
    )

data A
data B

type Cursor s p f i ph = RoleCursor s p f i ph
cursorScope :: Cursor A A A A A -> Cursor B A A A A
cursorScope = coerce
cursorPlan :: Cursor A A A A A -> Cursor A B A A A
cursorPlan = coerce
cursorFrame :: Cursor A A A A A -> Cursor A A B A A
cursorFrame = coerce
cursorInstance :: Cursor A A A A A -> Cursor A A A B A
cursorInstance = coerce
cursorPhase :: Cursor A A A A A -> Cursor A A A A B
cursorPhase = coerce

type Plan s sd p c sec f r i = RolePlan s sd p c sec f r i
planScope :: Plan A A A A A A A A -> Plan B A A A A A A A
planScope = coerce
planSpec :: Plan A A A A A A A A -> Plan A B A A A A A A
planSpec = coerce
planIdentity :: Plan A A A A A A A A -> Plan A A B A A A A A
planIdentity = coerce
planConfig :: Plan A A A A A A A A -> Plan A A A B A A A A
planConfig = coerce
planSecret :: Plan A A A A A A A A -> Plan A A A A B A A A
planSecret = coerce
planFrame :: Plan A A A A A A A A -> Plan A A A A A B A A
planFrame = coerce
planRevision :: Plan A A A A A A A A -> Plan A A A A A A B A
planRevision = coerce
planInstance :: Plan A A A A A A A A -> Plan A A A A A A A B
planInstance = coerce

type Binding s sd pd rd p = RolePlanDigestBinding s sd pd rd p
bindingScope :: Binding A A A A A -> Binding B A A A A
bindingScope = coerce
bindingSpec :: Binding A A A A A -> Binding A B A A A
bindingSpec = coerce
bindingPlanDigest :: Binding A A A A A -> Binding A A B A A
bindingPlanDigest = coerce
bindingRoleDigest :: Binding A A A A A -> Binding A A A B A
bindingRoleDigest = coerce
bindingPlan :: Binding A A A A A -> Binding A A A A B
bindingPlan = coerce

type Placement s sd p f r i svc eff = VerifiedServicePlacement s sd p f r i svc eff
placementScope :: Placement A A A A A A A A -> Placement B A A A A A A A
placementScope = coerce
placementSpec :: Placement A A A A A A A A -> Placement A B A A A A A A
placementSpec = coerce
placementPlan :: Placement A A A A A A A A -> Placement A A B A A A A A
placementPlan = coerce
placementFrame :: Placement A A A A A A A A -> Placement A A A B A A A A
placementFrame = coerce
placementRevision :: Placement A A A A A A A A -> Placement A A A A B A A A
placementRevision = coerce
placementInstance :: Placement A A A A A A A A -> Placement A A A A A B A A
placementInstance = coerce
placementService :: Placement A A A A A A A A -> Placement A A A A A A B A
placementService = coerce
placementEffects :: Placement A A A A A A A A -> Placement A A A A A A A B
placementEffects = coerce

type Authorization s sd p f r i svc es = EffectAuthorization s sd p f r i svc es
authorizationScope :: Authorization A A A A A A A '[NetworkListen] -> Authorization B A A A A A A '[NetworkListen]
authorizationScope = coerce
authorizationSpec :: Authorization A A A A A A A '[NetworkListen] -> Authorization A B A A A A A '[NetworkListen]
authorizationSpec = coerce
authorizationPlan :: Authorization A A A A A A A '[NetworkListen] -> Authorization A A B A A A A '[NetworkListen]
authorizationPlan = coerce
authorizationFrame :: Authorization A A A A A A A '[NetworkListen] -> Authorization A A A B A A A '[NetworkListen]
authorizationFrame = coerce
authorizationRevision :: Authorization A A A A A A A '[NetworkListen] -> Authorization A A A A B A A '[NetworkListen]
authorizationRevision = coerce
authorizationInstance :: Authorization A A A A A A A '[NetworkListen] -> Authorization A A A A A B A '[NetworkListen]
authorizationInstance = coerce
authorizationService :: Authorization A A A A A A A '[NetworkListen] -> Authorization A A A A A A B '[NetworkListen]
authorizationService = coerce
authorizationEffects :: Authorization A A A A A A A '[NetworkListen] -> Authorization A A A A A A A '[DurableStore]
authorizationEffects = coerce
