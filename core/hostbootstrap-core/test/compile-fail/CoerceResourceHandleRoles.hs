{- | A resource handle's generative identity and typestate axes are all
nominal.  Its identical runtime representation cannot turn another plan's
resource—or an unmanaged observation—into mutation authority.
-}
module CoerceResourceHandleRoles where

import Data.Coerce (coerce)
import HostBootstrap.Reconcile (ResourceHandle)

data HandleScopeA
data HandleScopeB
data HandlePlanA
data HandlePlanB
data HandleIdentityA
data HandleIdentityB
data HandleResourceA
data HandleResourceB
data HandleOwnershipA
data HandleOwnershipB
data HandlePhaseA
data HandlePhaseB

type BaselineHandle =
    ResourceHandle
        HandleScopeA
        HandlePlanA
        HandleIdentityA
        HandleResourceA
        HandleOwnershipA
        HandlePhaseA

coerceHandleScope ::
    BaselineHandle ->
    ResourceHandle
        HandleScopeB
        HandlePlanA
        HandleIdentityA
        HandleResourceA
        HandleOwnershipA
        HandlePhaseA
coerceHandleScope = coerce

coerceHandlePlan ::
    BaselineHandle ->
    ResourceHandle
        HandleScopeA
        HandlePlanB
        HandleIdentityA
        HandleResourceA
        HandleOwnershipA
        HandlePhaseA
coerceHandlePlan = coerce

coerceHandleIdentity ::
    BaselineHandle ->
    ResourceHandle
        HandleScopeA
        HandlePlanA
        HandleIdentityB
        HandleResourceA
        HandleOwnershipA
        HandlePhaseA
coerceHandleIdentity = coerce

coerceHandleResource ::
    BaselineHandle ->
    ResourceHandle
        HandleScopeA
        HandlePlanA
        HandleIdentityA
        HandleResourceB
        HandleOwnershipA
        HandlePhaseA
coerceHandleResource = coerce

coerceHandleOwnership ::
    BaselineHandle ->
    ResourceHandle
        HandleScopeA
        HandlePlanA
        HandleIdentityA
        HandleResourceA
        HandleOwnershipB
        HandlePhaseA
coerceHandleOwnership = coerce

coerceHandlePhase ::
    BaselineHandle ->
    ResourceHandle
        HandleScopeA
        HandlePlanA
        HandleIdentityA
        HandleResourceA
        HandleOwnershipA
        HandlePhaseB
coerceHandlePhase = coerce
