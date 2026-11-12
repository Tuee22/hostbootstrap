module RetagRecoveryProjectionChildInput where
import HostBootstrap.Handoff

retagChild :: RecoveryProjectionBindingInput plan parent child -> RecoveryProjectionBindingInput plan parent otherChild
retagChild value = value { requestedRecoveryChildFrame = requestedRecoveryChildFrame value }
