module RetagRecoveryProjectionParentInput where
import HostBootstrap.Handoff

retagParent :: RecoveryProjectionBindingInput plan parent child -> RecoveryProjectionBindingInput plan otherParent child
retagParent value = value { requestedRecoveryParentFrame = requestedRecoveryParentFrame value }
