{-# LANGUAGE OverloadedStrings #-}

module ForgeRecoveryProjectionInput where

import HostBootstrap.Handoff

-- Recovery coordinates may be introduced only by the generative bracket (or a
-- later plan-evidence constructor), never by selecting the phantom indices and
-- filling a public record.
forgeRecoveryCoordinates :: RecoveryProjectionBindingInput plan parent child
forgeRecoveryCoordinates =
    RecoveryProjectionBindingInput
        { requestedRecoveryPlanDigest = "plan"
        , requestedRecoveryParentFrame = "parent"
        , requestedRecoveryChildFrame = "child"
        }
