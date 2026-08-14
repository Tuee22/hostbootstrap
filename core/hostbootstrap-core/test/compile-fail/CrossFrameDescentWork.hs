module CrossFrameDescentWork where

import HostBootstrap.Authority (VerbDestroy)
import HostBootstrap.Teardown

data Scope
data Plan
data ParentA
data ParentB
data ChildA
data ChildB

consumeParentB :: DescentWork Scope Plan ParentB ChildA VerbDestroy -> ()
consumeParentB _ = ()

crossParent :: DescentWork Scope Plan ParentA ChildA VerbDestroy -> ()
crossParent = consumeParentB

consumeChildB :: DescentWork Scope Plan ParentA ChildB VerbDestroy -> ()
consumeChildB _ = ()

crossChild :: DescentWork Scope Plan ParentA ChildA VerbDestroy -> ()
crossChild = consumeChildB
