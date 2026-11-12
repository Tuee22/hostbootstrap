module ImportResourceCarrierAllocator where

import HostBootstrap.Lifecycle.Execution (ResourceCarrier, newResourceCarrier)

retained :: IO (ResourceCarrier scope planId)
retained = newResourceCarrier
