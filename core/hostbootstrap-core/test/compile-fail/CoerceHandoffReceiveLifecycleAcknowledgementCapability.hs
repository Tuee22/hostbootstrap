module CoerceHandoffReceiveLifecycleAcknowledgementCapability where

import Data.Coerce (coerce)
import HostBootstrap.Handoff (receiveLifecycleAcknowledgementKernel)

-- The public kernel requires its hidden ordinary-data signing capability.
-- Supplying unit through coerce cannot manufacture that capability.
withoutCapability = receiveLifecycleAcknowledgementKernel (coerce ())
