module CoerceRecoveryProjectionBindingInputRoles where

import Data.Coerce (coerce)
import HostBootstrap.Handoff (RecoveryProjectionBindingInput)

data PlanA
data PlanB
data ParentA
data ParentB
data ChildA
data ChildB

wrongPlan :: RecoveryProjectionBindingInput PlanA ParentA ChildA -> RecoveryProjectionBindingInput PlanB ParentA ChildA
wrongPlan = coerce

wrongParent :: RecoveryProjectionBindingInput PlanA ParentA ChildA -> RecoveryProjectionBindingInput PlanA ParentB ChildA
wrongParent = coerce

wrongChild :: RecoveryProjectionBindingInput PlanA ParentA ChildA -> RecoveryProjectionBindingInput PlanA ParentA ChildB
wrongChild = coerce
