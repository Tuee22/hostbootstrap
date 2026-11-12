module RetagRecoveryProjectionInput where
import HostBootstrap.Handoff

retagPlan :: RecoveryProjectionBindingInput plan parent child -> RecoveryProjectionBindingInput otherPlan parent child
retagPlan value = value { requestedRecoveryPlanDigest = requestedRecoveryPlanDigest value }

retagParent :: RecoveryProjectionBindingInput plan parent child -> RecoveryProjectionBindingInput plan otherParent child
retagParent value = value { requestedRecoveryParentFrame = requestedRecoveryParentFrame value }

retagChild :: RecoveryProjectionBindingInput plan parent child -> RecoveryProjectionBindingInput plan parent otherChild
retagChild value = value { requestedRecoveryChildFrame = requestedRecoveryChildFrame value }
