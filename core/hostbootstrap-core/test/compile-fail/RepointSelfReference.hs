module RepointSelfReference where

import HostBootstrap.Lift (InVMSelfPath (InVMSelfPath), SelfRef)

-- A self-reference names where this binary is on the host and where it is
-- inside the guest, and both feed process dispatch. A caller that was handed one
-- cannot re-point it: the constructor is package-private and there are no field
-- selectors, so record update has no field to name.
repointed :: SelfRef -> SelfRef
repointed self = self{inVMSelfPath = InVMSelfPath "/tmp/attacker"}
