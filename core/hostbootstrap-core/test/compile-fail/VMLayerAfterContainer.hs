-- The inner container closure is valid; the outer VM requires an open stack.
module VMLayerAfterContainer where

import HostBootstrap.Lift.Context

invalid :: IncusVM -> ContainerLift -> VMStack
invalid vm container = inVM vm (inContainer container emptyVMStack)
