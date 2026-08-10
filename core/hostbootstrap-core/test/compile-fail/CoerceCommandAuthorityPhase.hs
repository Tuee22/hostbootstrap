module CoerceCommandAuthorityPhase where

import Data.Coerce (coerce)
import HostBootstrap.Authority

data Scope
data Plan
data Frame
data BrokerGeneration

wrongPhase ::
    CommandAuthority Scope Plan Frame BrokerGeneration VerbUp PreparePhase ->
    CommandAuthority Scope Plan Frame BrokerGeneration VerbUp ExecutePhase
wrongPhase = coerce
