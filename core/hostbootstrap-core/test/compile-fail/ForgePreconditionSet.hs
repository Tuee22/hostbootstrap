-- A caller cannot import preparation's private observation representation.
module ForgePreconditionSet where

import HostBootstrap.Reconcile (OperationPreconditionSet)

retainedSet ::
    OperationPreconditionSet scope planId id resource ->
    OperationPreconditionSet scope planId id resource
retainedSet = id
