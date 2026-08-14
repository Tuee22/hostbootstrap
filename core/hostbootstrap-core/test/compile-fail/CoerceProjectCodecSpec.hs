module CoerceProjectCodecSpec where

import Data.Coerce (coerce)
import HostBootstrap.Config.Class (ProjectCodec)

data Scope
data SpecA
data SpecB
data Config scope

relabelProjectCodec ::
    ProjectCodec Scope SpecA Config ->
    ProjectCodec Scope SpecB Config
relabelProjectCodec = coerce
