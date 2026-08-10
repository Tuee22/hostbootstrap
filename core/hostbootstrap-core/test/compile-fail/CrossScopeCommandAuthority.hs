module CrossScopeCommandAuthority where

import Data.Coerce (coerce)
import HostBootstrap.Authority

data ScopeA
data ScopeB
data Plan
data Frame
data Epoch

wrongScope ::
    CommandAuthority ScopeA Plan Frame Epoch VerbUp ExecutePhase ->
    CommandAuthority ScopeB Plan Frame Epoch VerbUp ExecutePhase
wrongScope = coerce
