module SwapRootedPlanCatalogCoordinates where

import HostBootstrap.Lifecycle.RootedPlan (ConfigDigest, PayloadDigest, RootedPlanCatalog, withRootedPlanCatalogEntriesKernel)

-- A continuation that binds the payload digest where the configuration digest
-- belongs is a type error, not a value an edge recheck might miss.
configDigests :: RootedPlanCatalog scope rootPlanId brokerGeneration catalogId -> [ConfigDigest]
configDigests catalog =
    withRootedPlanCatalogEntriesKernel catalog (\_ _ _ _ _ _ _ _ _ payloadDigest _ -> payloadDigest)

unusedPayloadDigest :: PayloadDigest -> PayloadDigest
unusedPayloadDigest = id
