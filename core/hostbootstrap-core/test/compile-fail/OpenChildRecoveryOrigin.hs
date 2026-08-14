module OpenChildRecoveryOrigin where

-- The public authority and plan facades expose neither the sealed origin nor
-- its fixed folds or caller-free producer.
import HostBootstrap.Authority.ProjectPlan
    ( ChildRecoveryOrigin
    , childRecoveryOriginFrameNameKernel
    , childRecoveryOriginVerbNameKernel
    , withChildRecoveryOriginKernel
    , withChildRecoveryTerminalOriginKernel
    )
import HostBootstrap.ProjectPlan.Construct
    ( withReceivedRecoveryChildOriginKernel
    )

unreachable :: ()
unreachable = ()
