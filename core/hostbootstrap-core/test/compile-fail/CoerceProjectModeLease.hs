module CoerceProjectModeLease where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Mode (HarnessMode, ProductionMode, ProjectModeLease)

data Project
data Run
data BrokerGeneration

-- The mode index is nominal, so a held Production lease cannot be relabelled
-- as a lease for one Harness run.
wrongMode ::
    ProjectModeLease Project ProductionMode BrokerGeneration ->
    ProjectModeLease Project (HarnessMode Run) BrokerGeneration
wrongMode = coerce
