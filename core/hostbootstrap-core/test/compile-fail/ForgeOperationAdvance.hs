module ForgeOperationAdvance where

import HostBootstrap.Lifecycle.Session (OperationAdvance, ProjectPermit)

forgedAdvance :: result -> ProjectPermit scope planId -> OperationAdvance scope planId result
forgedAdvance result permit = OperationAdvance result permit
