module CoerceBuildCommandAuthorityRoles where

import Data.Coerce (coerce)
import HostBootstrap.Build (BuildCommandAuthority)

data ProjectA
data ProjectB
data SpecA
data SpecB
data ConfigA
data ConfigB

wrongProject ::
    BuildCommandAuthority ProjectA SpecA ConfigA ->
    BuildCommandAuthority ProjectB SpecA ConfigA
wrongProject = coerce

wrongSpec ::
    BuildCommandAuthority ProjectA SpecA ConfigA ->
    BuildCommandAuthority ProjectA SpecB ConfigA
wrongSpec = coerce

wrongConfig ::
    BuildCommandAuthority ProjectA SpecA ConfigA ->
    BuildCommandAuthority ProjectA SpecA ConfigB
wrongConfig = coerce
