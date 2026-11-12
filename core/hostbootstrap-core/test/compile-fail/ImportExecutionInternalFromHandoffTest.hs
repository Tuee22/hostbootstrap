module ImportExecutionInternalFromHandoffTest where

import HostBootstrap.Lifecycle.Execution.Internal (StepExecution)

retained :: StepExecution scope planId -> ()
retained _ = ()
