module ImportProjectPlanConstructInternal where

-- External clients cannot import the finalized-spec representation or its
-- forward-child projection kernel from the Cabal-hidden owner.
import HostBootstrap.ProjectPlan.Construct.Internal
