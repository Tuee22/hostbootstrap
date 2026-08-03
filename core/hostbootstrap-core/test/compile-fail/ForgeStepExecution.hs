{- | A downstream project cannot fabricate either the plan-indexed execution
descriptor or the neutral plan node from which the trusted interpreter mints
it.  Neither constructor is exported by the public module.
-}
module ForgeStepExecution where

import HostBootstrap.HostConfig (HostConfig)
import HostBootstrap.Lifecycle.Execution

data Scope

data Plan

forgedExecution :: HostConfig -> StepExecution Scope Plan
forgedExecution cfg =
    StepExecution
        cfg
        (error "forged plan digest")
        (error "forged current node")
        []

forgedNode =
    ExecutionNode
        (error "forged operation")
        (error "forged frame")
        []
