module CoerceFinalizedProjectSpec where

import Data.Coerce (coerce)
import HostBootstrap.ProjectPlan.Construct (FinalizedProjectSpec)

data Scope
data SpecA
data SpecB
data Config scope

relabelFinalizedSpec ::
    FinalizedProjectSpec Scope SpecA Config ->
    FinalizedProjectSpec Scope SpecB Config
relabelFinalizedSpec = coerce
