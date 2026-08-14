module CoerceFinalizedServiceRegistrySpec where

import Data.Coerce (coerce)
import HostBootstrap.Service (FinalizedServiceRegistry)

data Scope
data SpecA
data SpecB
data Config

relabelFinalizedRegistry ::
    FinalizedServiceRegistry Scope SpecA Config ->
    FinalizedServiceRegistry Scope SpecB Config
relabelFinalizedRegistry = coerce
