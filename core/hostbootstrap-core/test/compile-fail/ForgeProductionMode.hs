module ForgeProductionMode where

import HostBootstrap.Lifecycle.Mode (ProductionMode)

-- The public Production tag is a type witness, not a caller-constructible
-- value. Only the protected Production transition may select it.
forgedProductionMode :: ProductionMode
forgedProductionMode = ProductionMode
