-- An ordinary layer reader cannot be used to replace an opaque context's layers.
module RecordUpdateLiftLayers where

import HostBootstrap.Lift.Context

replaceLayers :: LiftContext -> [LiftLayer] -> LiftContext
replaceLayers context layers = context{liftLayers = layers}
