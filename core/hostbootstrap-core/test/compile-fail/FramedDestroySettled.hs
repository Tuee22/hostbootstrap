module FramedDestroySettled where

import HostBootstrap.Teardown (DestroySettled)

data Scope
data Plan
data Frame

-- Project-wide settlement deliberately has no reusable frame parameter.
framedDestroy :: DestroySettled Scope Plan Frame
framedDestroy = undefined
