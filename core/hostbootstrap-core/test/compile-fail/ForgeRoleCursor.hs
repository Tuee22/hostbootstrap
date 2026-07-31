module ForgeRoleCursor where

import HostBootstrap.RoleLifecycle

-- The cursor is the engine's private position in the phase machine. Asserting
-- one would let project code enter Serve without ever acquiring or probing, or
-- retain a Serve cursor into Drain.
forgedCursor :: RoleCursor s p f i ServePhase
forgedCursor = RoleCursor Serve

-- The narrowed role plan exists only inside 'withRuntimeRolePlan', after the
-- one-use lifecycle admission was compare-and-swap-consumed.
forgedPlan :: RolePlan s sd p c sec f r i
forgedPlan = RolePlan "daemon-3" "rev-1" "pod:pod-uid-1/0" []

-- The placement carries the signed effect ceiling. Naming one directly would
-- let a role claim effects the broker never signed.
forgedPlacement :: VerifiedServicePlacement s sd p f r i svc eff
forgedPlacement = VerifiedServicePlacement "accelerator" [DurableStore] NoExclusiveEffects

-- The empty-rollback proof is minted only where the engine can show nothing was
-- acquired; a branch that acquired resources must drain them.
forgedNoResources :: VerifiedNoRoleResources s p f i
forgedNoResources = VerifiedNoRoleResources

-- The reservation records the exact protected version it was observed at.
forgedAdmission :: ReservedRoleAdmission s p f r i
forgedAdmission = ReservedRoleAdmission "role-admission.plan-1.daemon-3.rev-1"

-- A verified draft is the output of comparing a project draft with the signed
-- role-plan digest; it cannot be asserted around that check.
forgedDraft :: VerifiedRolePlanDraft s p f r i rpd
forgedDraft = VerifiedRolePlanDraft [] "roleplan-1"

-- Serve sees only names Acquire created and Ready probed. Building the handle
-- set directly would be the bind-at-serve-time escape hatch § AA forbids.
forgedHandles :: ReadyRoleHandles
forgedHandles = ReadyRoleHandles ["listener"]

-- The binding states which parent plan digest signed this role plan.
forgedBinding :: RolePlanDigestBinding s sd pd rpd p
forgedBinding = RolePlanDigestBinding "plan-1" "roleplan-1"
