{- | A prepared value cannot project mutation argv outside the strong backend. -}
module OpenPreparedColimaMutationArgs where

import HostBootstrap.Ensure.Colima (preparedColimaWallArgs)

openMutationArgs = preparedColimaWallArgs
