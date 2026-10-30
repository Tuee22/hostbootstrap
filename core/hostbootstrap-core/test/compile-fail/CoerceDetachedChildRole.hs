module CoerceDetachedChildRole where

import Data.Coerce (coerce)
import HostBootstrap.Detached (DetachedChild)

data ChildA
data ChildB

crossChild :: DetachedChild ChildA -> DetachedChild ChildB
crossChild = coerce
