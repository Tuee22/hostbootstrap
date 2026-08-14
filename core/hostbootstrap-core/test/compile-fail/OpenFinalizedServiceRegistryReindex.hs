module OpenFinalizedServiceRegistryReindex where

-- The public service facade exposes the finalized registry abstractly: no
-- caller can name a finalized definition, name the registry constructor, or
-- relabel the registry's specification index.
import HostBootstrap.Service
    ( FinalizedServiceDefinition
    , FinalizedServiceRegistry (FinalizedServiceRegistry)
    , reindexFinalizedServiceRegistryKernel
    )
