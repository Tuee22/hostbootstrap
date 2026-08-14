module CrossVerbTeardownWork where

import HostBootstrap.Authority (VerbDestroy, VerbDown)
import HostBootstrap.Teardown (TeardownWork)

data Scope
data Plan
data Frame

consumeDestroy :: TeardownWork Scope Plan Frame VerbDestroy -> ()
consumeDestroy _ = ()

-- Work classified under down cannot enter the destroy interpreter.
downWorkAsDestroy :: TeardownWork Scope Plan Frame VerbDown -> ()
downWorkAsDestroy = consumeDestroy

