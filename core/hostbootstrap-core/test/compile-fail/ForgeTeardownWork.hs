module ForgeTeardownWork where

import HostBootstrap.Authority (VerbDestroy)
import HostBootstrap.Teardown

data Scope
data Plan
data Frame
data ChildFrame

forgedLocal :: LocalWork Scope Plan Frame VerbDestroy
forgedLocal = LocalWork undefined undefined

forgedDescent :: DescentWork Scope Plan Frame ChildFrame VerbDestroy
forgedDescent = DescentWork undefined "parent" "child" undefined

forgedLocalSum :: TeardownWork Scope Plan Frame VerbDestroy
forgedLocalSum = LocalTeardownWork forgedLocal

forgedDescentSum :: TeardownWork Scope Plan Frame VerbDestroy
forgedDescentSum = DescentTeardownWork forgedDescent
