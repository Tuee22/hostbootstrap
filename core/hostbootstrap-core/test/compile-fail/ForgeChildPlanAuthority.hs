module ForgeChildPlanAuthority where

import HostBootstrap.ProjectPlan.Construct

data Scope
data Spec
data Digest
data Broker
data Parent
data Child
data Plan
data Config
data Verb
data Phase

forged ::
    ChildPlanAuthority Scope Spec Digest Broker Parent Child Plan Config Verb Phase
forged = ChildPlanAuthority undefined
