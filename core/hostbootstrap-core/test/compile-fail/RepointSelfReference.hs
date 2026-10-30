module RepointSelfReference where

-- An opaque self-reference cannot be rebuilt by naming its private constructor.

import HostBootstrap.Lift (
    SelfRef (SelfRef),
 )
