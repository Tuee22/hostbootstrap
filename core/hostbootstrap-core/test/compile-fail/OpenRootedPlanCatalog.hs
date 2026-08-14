module OpenRootedPlanCatalog where

-- No public lifecycle facade exposes the recursive catalog, its producer, any
-- selection fold, or its durable manifest, so no caller can name a catalog,
-- extend one, hold an entry independently of the catalog it came from, or
-- render, address, or compare the bytes only the root entry persists.
import HostBootstrap.Lifecycle.Session
    ( RootedPlanCatalog
    , rootedPlanCatalogManifestKernel
    , rootedPlanCatalogManifestMatchesKernel
    , rootedPlanCatalogRecordIdentityKernel
    , withRootedPlanCatalogEdgeKernel
    , withRootedPlanCatalogEntriesKernel
    , withRootedPlanCatalogEntryKernel
    , withRootedPlanCatalogFrameKernel
    , withRootedPlanCatalogKernel
    , withRootedPlanCatalogRootKernel
    )
