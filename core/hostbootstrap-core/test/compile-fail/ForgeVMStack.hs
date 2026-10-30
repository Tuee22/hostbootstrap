-- A container cannot be inserted into the opaque open VM stack.
module ForgeVMStack where

import HostBootstrap.Lift.Context

forged :: ContainerLift -> VMStack
forged container = VMStack [ViaContainer container]
