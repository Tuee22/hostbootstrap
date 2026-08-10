module CoerceImageBuildFrameRoles where

import Data.Coerce (coerce)
import HostBootstrap.Build (ImageBuildFrame)

data ProjectA
data ProjectB
data SpecA
data SpecB
data ConfigA
data ConfigB
data FrameA
data FrameB

wrongProject ::
    ImageBuildFrame ProjectA SpecA ConfigA FrameA ->
    ImageBuildFrame ProjectB SpecA ConfigA FrameA
wrongProject = coerce

wrongSpec ::
    ImageBuildFrame ProjectA SpecA ConfigA FrameA ->
    ImageBuildFrame ProjectA SpecB ConfigA FrameA
wrongSpec = coerce

wrongConfig ::
    ImageBuildFrame ProjectA SpecA ConfigA FrameA ->
    ImageBuildFrame ProjectA SpecA ConfigB FrameA
wrongConfig = coerce

wrongFrame ::
    ImageBuildFrame ProjectA SpecA ConfigA FrameA ->
    ImageBuildFrame ProjectA SpecA ConfigA FrameB
wrongFrame = coerce
