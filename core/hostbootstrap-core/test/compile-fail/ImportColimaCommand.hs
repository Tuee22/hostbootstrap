-- | Callers cannot construct an unchecked Colima profile.
module ImportColimaCommand where

import HostBootstrap.Ensure.Colima.Command

bad = ColimaProfile "h-012345"
