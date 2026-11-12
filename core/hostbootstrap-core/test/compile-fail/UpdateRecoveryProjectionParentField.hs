{-# LANGUAGE OverloadedStrings #-}
module UpdateRecoveryProjectionParentField where
import HostBootstrap.Handoff

replaceParent :: RecoveryProjectionBindingInput plan parent child -> RecoveryProjectionBindingInput plan parent child
replaceParent value = value { requestedRecoveryParentFrame = "replacement-parent" }
