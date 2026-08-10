module CoerceInstalledProjectIdentity where

import Data.Coerce (coerce)
import HostBootstrap.Authority

data ProjectA
data ProjectB

wrongProject ::
    InstalledProjectIdentity ProjectA ->
    InstalledProjectIdentity ProjectB
wrongProject = coerce
