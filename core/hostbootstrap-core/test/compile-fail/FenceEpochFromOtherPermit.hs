{-# LANGUAGE EmptyDataDecls #-}

module FenceEpochFromOtherPermit where

import HostBootstrap.Lifecycle.Session
import HostBootstrap.Protected

data Scope
data PlanA
data PlanB

fenceForAnotherPlan ::
    ProtectedSession session ->
    ProjectPermit Scope PlanA ->
    IO (Either SessionError (FenceEpoch Scope PlanB))
fenceForAnotherPlan session permit =
    HostBootstrap.Lifecycle.Session.establishInitialFence session permit 1
