module OpenCatalogForwardHandoff where

-- No public ProjectPlan facade exposes the catalog-admitted forward package,
-- its hidden constructor, its catalog-only producer, or the narrow
-- Process-input fold, so no caller can name a storeless forward package,
-- forge one outside the recursive catalog, or widen its fixed unit result.
import HostBootstrap.ProjectPlan
    ( CatalogForwardHandoff (CatalogForwardHandoff)
    , withCatalogForwardHandoffKernel
    , withCatalogForwardProcessInputsKernel
    )
