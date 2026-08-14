module CoerceTeardownWorkRoles where

import Data.Coerce (coerce)
import HostBootstrap.Teardown

data WorkScopeA
data WorkScopeB
data WorkPlanA
data WorkPlanB
data WorkFrameA
data WorkFrameB
data WorkVerbA
data WorkVerbB

coerceWorkScope ::
    TeardownWork WorkScopeA WorkPlanA WorkFrameA WorkVerbA ->
    TeardownWork WorkScopeB WorkPlanA WorkFrameA WorkVerbA
coerceWorkScope = coerce

coerceWorkPlan ::
    TeardownWork WorkScopeA WorkPlanA WorkFrameA WorkVerbA ->
    TeardownWork WorkScopeA WorkPlanB WorkFrameA WorkVerbA
coerceWorkPlan = coerce

coerceWorkFrame ::
    TeardownWork WorkScopeA WorkPlanA WorkFrameA WorkVerbA ->
    TeardownWork WorkScopeA WorkPlanA WorkFrameB WorkVerbA
coerceWorkFrame = coerce

coerceWorkVerb ::
    TeardownWork WorkScopeA WorkPlanA WorkFrameA WorkVerbA ->
    TeardownWork WorkScopeA WorkPlanA WorkFrameA WorkVerbB
coerceWorkVerb = coerce

data LocalScopeA
data LocalScopeB
data LocalPlanA
data LocalPlanB
data LocalFrameA
data LocalFrameB
data LocalVerbA
data LocalVerbB

coerceLocalScope ::
    LocalWork LocalScopeA LocalPlanA LocalFrameA LocalVerbA ->
    LocalWork LocalScopeB LocalPlanA LocalFrameA LocalVerbA
coerceLocalScope = coerce

coerceLocalPlan ::
    LocalWork LocalScopeA LocalPlanA LocalFrameA LocalVerbA ->
    LocalWork LocalScopeA LocalPlanB LocalFrameA LocalVerbA
coerceLocalPlan = coerce

coerceLocalFrame ::
    LocalWork LocalScopeA LocalPlanA LocalFrameA LocalVerbA ->
    LocalWork LocalScopeA LocalPlanA LocalFrameB LocalVerbA
coerceLocalFrame = coerce

coerceLocalVerb ::
    LocalWork LocalScopeA LocalPlanA LocalFrameA LocalVerbA ->
    LocalWork LocalScopeA LocalPlanA LocalFrameA LocalVerbB
coerceLocalVerb = coerce

data DescentScopeA
data DescentScopeB
data DescentPlanA
data DescentPlanB
data DescentParentA
data DescentParentB
data DescentChildA
data DescentChildB
data DescentVerbA
data DescentVerbB

coerceDescentScope ::
    DescentWork DescentScopeA DescentPlanA DescentParentA DescentChildA DescentVerbA ->
    DescentWork DescentScopeB DescentPlanA DescentParentA DescentChildA DescentVerbA
coerceDescentScope = coerce

coerceDescentPlan ::
    DescentWork DescentScopeA DescentPlanA DescentParentA DescentChildA DescentVerbA ->
    DescentWork DescentScopeA DescentPlanB DescentParentA DescentChildA DescentVerbA
coerceDescentPlan = coerce

coerceDescentParent ::
    DescentWork DescentScopeA DescentPlanA DescentParentA DescentChildA DescentVerbA ->
    DescentWork DescentScopeA DescentPlanA DescentParentB DescentChildA DescentVerbA
coerceDescentParent = coerce

coerceDescentChild ::
    DescentWork DescentScopeA DescentPlanA DescentParentA DescentChildA DescentVerbA ->
    DescentWork DescentScopeA DescentPlanA DescentParentA DescentChildB DescentVerbA
coerceDescentChild = coerce

coerceDescentVerb ::
    DescentWork DescentScopeA DescentPlanA DescentParentA DescentChildA DescentVerbA ->
    DescentWork DescentScopeA DescentPlanA DescentParentA DescentChildA DescentVerbB
coerceDescentVerb = coerce
