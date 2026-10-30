module CoerceDetachedIORole where

import Data.Coerce (coerce)
import HostBootstrap.Detached (DetachedIO)

data ChildA
data ChildB

crossChild :: DetachedIO ChildA () -> DetachedIO ChildB ()
crossChild = coerce
