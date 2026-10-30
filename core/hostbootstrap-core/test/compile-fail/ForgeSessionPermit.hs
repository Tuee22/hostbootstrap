module ForgeSessionPermit where

import HostBootstrap.Lifecycle.Session (ProjectPermit)

-- A project permit is the sole successor of one observed journal version. It
-- cannot be conjured from a number, so a caller cannot re-authorize a
-- transition whose version it already spent.
-- The other sealed value is supplied, not forged. Its argument type is
-- inferred because the public API does not name the transaction permit.
forgedPermit transaction = ProjectPermit transaction :: ProjectPermit scope planId
