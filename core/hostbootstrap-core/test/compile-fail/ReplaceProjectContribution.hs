module ReplaceProjectContribution where

-- Project contributions remain additive; callers cannot replace the builder's private fields.

import HostBootstrap.CLI (
    pbStepFragments,
    pbServiceRegistries,
    pbForwardChildPlan,
 )
