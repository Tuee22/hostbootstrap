module ImportAuthorityProjectPlanInternal where

-- Recovery-child origins are package-private authority.  A downstream caller
-- cannot import their constructor-hidden home even to name the type.
import HostBootstrap.Authority.ProjectPlan.Internal (ChildRecoveryOrigin)

unreachable :: ()
unreachable = ()
