module CoerceRehydratedResourceSetBroker where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Session (RehydratedResourceSet)

wrongBroker :: RehydratedResourceSet scope planId firstBroker -> RehydratedResourceSet scope planId secondBroker
wrongBroker = coerce
