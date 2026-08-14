module SubtreeAsDestroyClosure where

import HostBootstrap.Authority (VerbDestroy)
import HostBootstrap.Lifecycle.Mode
import HostBootstrap.Lifecycle.Session (VerifiedAllSessionsClosed)
import HostBootstrap.Teardown (SubtreeSettled)

data Scope
data SpecificationDigest
data PlanDigest
data Plan
data BrokerGeneration
data Frame

closeWithNestedSubtree ::
    BoundRunLease Scope SpecificationDigest PlanDigest BrokerGeneration ->
    VerifiedAllSessionsClosed Scope Plan ->
    SubtreeSettled Scope Plan Frame VerbDestroy ->
    Either ModeError (ProjectClosureEvidence Scope)
closeWithNestedSubtree lease sessions subtree =
    destroySettledClosure lease sessions subtree
