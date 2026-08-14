module SubtreeAsDestroySettled where

import HostBootstrap.Authority (VerbDestroy)
import HostBootstrap.Teardown

data Scope
data Plan
data NestedFrame

nestedCannotClose ::
    SubtreeSettled Scope Plan NestedFrame VerbDestroy ->
    DestroySettled Scope Plan
nestedCannotClose subtree = subtree
