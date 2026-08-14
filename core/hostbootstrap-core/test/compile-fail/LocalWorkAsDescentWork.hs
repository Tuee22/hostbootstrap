module LocalWorkAsDescentWork where

import HostBootstrap.Authority (VerbDestroy)
import HostBootstrap.Teardown

data Scope
data Plan
data Frame
data ChildFrame

consumeDescent :: DescentWork Scope Plan Frame ChildFrame VerbDestroy -> ()
consumeDescent _ = ()

localCannotDescend :: LocalWork Scope Plan Frame VerbDestroy -> ()
localCannotDescend = consumeDescent
