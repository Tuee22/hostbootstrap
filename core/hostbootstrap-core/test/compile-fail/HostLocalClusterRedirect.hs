{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A host-local client must not be redirectable to a cluster-only store.
--
-- There is no @Reachability 'HostLocal 'ClusterOnly@ constructor, so
-- 'redirectToStore' cannot be applied for that pair at all. This is the
-- unrepresentable case the composition-and-network-algebra phase exists to create.
module HostLocalClusterRedirect where

import HostBootstrap.Network
import HostBootstrap.RegistryPlan

forbidden :: Endpoint 'ClusterOnly -> BlobDelivery 'HostLocal
forbidden store = redirectToStore HostReachesHost store
