module DataDependencyAsProductionCarrier where

import Data.Text (Text)
import HostBootstrap.Lifecycle.Dependency.Internal (RuntimeDependencyPackage)
import HostBootstrap.Lifecycle.Execution (carriedResourceKeys)
import HostBootstrap.Lifecycle.Execution.Core (ResourceCarrierCore)

retained :: ResourceCarrierCore scope planId (RuntimeDependencyPackage scope planId) -> IO [Text]
retained = carriedResourceKeys
