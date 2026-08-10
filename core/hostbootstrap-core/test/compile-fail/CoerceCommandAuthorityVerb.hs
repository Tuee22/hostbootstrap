module CoerceCommandAuthorityVerb where

import Data.Coerce (coerce)
import HostBootstrap.Authority

data Scope
data Plan
data Frame
data BrokerGeneration

wrongVerb ::
    CommandAuthority Scope Plan Frame BrokerGeneration VerbUp PreparePhase ->
    CommandAuthority Scope Plan Frame BrokerGeneration VerbDown PreparePhase
wrongVerb = coerce
