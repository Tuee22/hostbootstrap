module CoerceProtectedSession where

import Data.Coerce (coerce)
import HostBootstrap.Protected (ProtectedSession)

data SessionA
data SessionB

crossSession :: ProtectedSession SessionA -> ProtectedSession SessionB
crossSession = coerce
