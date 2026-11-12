module ImportPreparedInternalFromHandoffTest where

import HostBootstrap.Lifecycle.Prepared.Internal (PreparedGate)

retained :: PreparedGate scope planId -> ()
retained _ = ()
