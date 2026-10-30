module CoerceHandoffRecoverySigningCapability where

import Data.Coerce (coerce)
import HostBootstrap.Handoff (signRecoveryWireKernel)

-- The public kernel requires its hidden ordinary-data signing capability.
-- Supplying unit through coerce cannot manufacture that capability.
withoutCapability = signRecoveryWireKernel (coerce ())
