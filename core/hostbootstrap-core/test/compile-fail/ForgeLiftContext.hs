-- Only public context producers may close an open stack and optional container.
module ForgeLiftContext where

import HostBootstrap.Lift.Context

forged :: VMStack -> Maybe ContainerLift -> LiftContext
forged = LiftContext
