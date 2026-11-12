{-# LANGUAGE OverloadedStrings #-}
module UpdateRecoveryProjectionInputField where
import HostBootstrap.Handoff

replacePlan :: RecoveryProjectionBindingInput plan parent child -> RecoveryProjectionBindingInput plan parent child
replacePlan value = value { requestedRecoveryPlanDigest = "replacement-plan" }

replaceParent :: RecoveryProjectionBindingInput plan parent child -> RecoveryProjectionBindingInput plan parent child
replaceParent value = value { requestedRecoveryParentFrame = "replacement-parent" }

replaceChild :: RecoveryProjectionBindingInput plan parent child -> RecoveryProjectionBindingInput plan parent child
replaceChild value = value { requestedRecoveryChildFrame = "replacement-child" }
