module CoerceCommandAuthorityEpoch where

import Data.Coerce (coerce)
import HostBootstrap.Authority

data Scope
data Plan
data Frame
data EpochA
data EpochB

wrongEpoch ::
    CommandAuthority Scope Plan Frame EpochA VerbUp ExecutePhase ->
    CommandAuthority Scope Plan Frame EpochB VerbUp ExecutePhase
wrongEpoch = coerce
