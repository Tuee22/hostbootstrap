module CoerceSubtreeSettlementRoles where

import Data.Coerce (coerce)
import HostBootstrap.Teardown

data ScopeA
data ScopeB
data PlanA
data PlanB
data FrameA
data FrameB
data VerbA
data VerbB

coerceSubtreeScope ::
    SubtreeSettled ScopeA PlanA FrameA VerbA ->
    SubtreeSettled ScopeB PlanA FrameA VerbA
coerceSubtreeScope = coerce

coerceSubtreePlan ::
    SubtreeSettled ScopeA PlanA FrameA VerbA ->
    SubtreeSettled ScopeA PlanB FrameA VerbA
coerceSubtreePlan = coerce

coerceSubtreeFrame ::
    SubtreeSettled ScopeA PlanA FrameA VerbA ->
    SubtreeSettled ScopeA PlanA FrameB VerbA
coerceSubtreeFrame = coerce

coerceSubtreeVerb ::
    SubtreeSettled ScopeA PlanA FrameA VerbA ->
    SubtreeSettled ScopeA PlanA FrameA VerbB
coerceSubtreeVerb = coerce

data DestroyScopeA
data DestroyScopeB
data DestroyPlanA
data DestroyPlanB

coerceDestroyScope ::
    DestroySettled DestroyScopeA DestroyPlanA ->
    DestroySettled DestroyScopeB DestroyPlanA
coerceDestroyScope = coerce

coerceDestroyPlan ::
    DestroySettled DestroyScopeA DestroyPlanA ->
    DestroySettled DestroyScopeA DestroyPlanB
coerceDestroyPlan = coerce
