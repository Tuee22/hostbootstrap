module CoerceShippedDirectoryLease where

import Data.Coerce (coerce)
import HostBootstrap.Ownership.Shipped (ShippedDirectoryLease)

data First = First
data Second = Second

changesScope :: ShippedDirectoryLease First -> ShippedDirectoryLease Second
changesScope = coerce
