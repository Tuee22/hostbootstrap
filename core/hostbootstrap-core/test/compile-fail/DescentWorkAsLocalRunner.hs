module DescentWorkAsLocalRunner where

import HostBootstrap.Authority (VerbDestroy)
import HostBootstrap.Teardown

data Scope
data Plan
data Frame
data ChildFrame

runLocal :: LocalWork Scope Plan Frame VerbDestroy -> ()
runLocal _ = ()

descentCannotRunLocally :: DescentWork Scope Plan Frame ChildFrame VerbDestroy -> ()
descentCannotRunLocally = runLocal
