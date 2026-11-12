{-# LANGUAGE OverloadedStrings #-}
module UpdateRecoveryProjectionChildField where
import HostBootstrap.Handoff

replaceChild :: RecoveryProjectionBindingInput plan parent child -> RecoveryProjectionBindingInput plan parent child
replaceChild value = value { requestedRecoveryChildFrame = "replacement-child" }
