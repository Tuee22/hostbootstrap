-- | The plan-owned dependency-snapshot traversal is the only producer of an
-- 'OperationPreconditionSet' (§ CC): a caller can neither build one directly nor
-- assemble the observation list 'withPreparedOperation' used to accept.
module ForgePreconditionSet where

import HostBootstrap.Reconcile

forgedSet :: OperationPreconditionSet scope planId id resource
forgedSet = OperationPreconditionSet "core:deploy-kind" "call" []

forgedProbeEntry ::
  DependencySnapshot scope planId ->
  DependencySnapshot scope planId
forgedProbeEntry (DependencySnapshot entries) = DependencySnapshot entries
