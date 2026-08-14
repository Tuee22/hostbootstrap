module CrossSubtreeDescentSettlement where

import HostBootstrap.Authority (VerbDestroy, VerbDown)
import HostBootstrap.Teardown

data Scope
data PlanA
data PlanB
data ParentA
data ParentB
data ChildA
data ChildB

crossPlan ::
    DescentWork Scope PlanA ParentA ChildA VerbDestroy ->
    SubtreeSettled Scope PlanB ChildA VerbDestroy ->
    Either TeardownError (TeardownForest Scope PlanA ParentA VerbDestroy)
crossPlan = settleDescentWork

crossParent ::
    DescentWork Scope PlanA ParentA ChildA VerbDestroy ->
    SubtreeSettled Scope PlanA ChildA VerbDestroy ->
    Either TeardownError (TeardownForest Scope PlanA ParentB VerbDestroy)
crossParent = settleDescentWork

crossSibling ::
    DescentWork Scope PlanA ParentA ChildA VerbDestroy ->
    SubtreeSettled Scope PlanA ChildB VerbDestroy ->
    Either TeardownError (TeardownForest Scope PlanA ParentA VerbDestroy)
crossSibling = settleDescentWork

crossAncestor ::
    DescentWork Scope PlanA ParentA ChildA VerbDestroy ->
    SubtreeSettled Scope PlanA ParentA VerbDestroy ->
    Either TeardownError (TeardownForest Scope PlanA ParentA VerbDestroy)
crossAncestor = settleDescentWork

crossVerb ::
    DescentWork Scope PlanA ParentA ChildA VerbDestroy ->
    SubtreeSettled Scope PlanA ChildA VerbDown ->
    Either TeardownError (TeardownForest Scope PlanA ParentA VerbDestroy)
crossVerb = settleDescentWork

rawSuccess ::
    DescentWork Scope PlanA ParentA ChildA VerbDestroy ->
    Either TeardownError (TeardownForest Scope PlanA ParentA VerbDestroy)
rawSuccess descent = settleDescentWork descent TeardownReleased
