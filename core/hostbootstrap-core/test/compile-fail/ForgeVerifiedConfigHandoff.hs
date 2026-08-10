module ForgeVerifiedConfigHandoff where

import HostBootstrap.Config.Schema

data Scope
data PlanDigest
data BrokerGeneration
data ParentFrame
data ChildFrame
data ConfigIdentity
data Verb
data Phase

-- Exact config-handoff refinement is produced only by the validating bracket.
forgedConfigHandoff ::
    VerifiedConfigHandoff
        Scope PlanDigest BrokerGeneration ParentFrame ChildFrame ConfigIdentity Verb Phase
forgedConfigHandoff = VerifiedConfigHandoff undefined undefined
