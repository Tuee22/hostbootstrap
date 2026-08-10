module CoerceVerifiedConfigWireRoles where

import Data.Coerce (coerce)
import HostBootstrap.Config.Schema (VerifiedConfigWire)

data ScopeA
data ScopeB
data DigestA
data DigestB
data ConfigA
data ConfigB

wrongScope :: VerifiedConfigWire ScopeA DigestA ConfigA -> VerifiedConfigWire ScopeB DigestA ConfigA
wrongScope = coerce

wrongDigest :: VerifiedConfigWire ScopeA DigestA ConfigA -> VerifiedConfigWire ScopeA DigestB ConfigA
wrongDigest = coerce

wrongConfig :: VerifiedConfigWire ScopeA DigestA ConfigA -> VerifiedConfigWire ScopeA DigestA ConfigB
wrongConfig = coerce
