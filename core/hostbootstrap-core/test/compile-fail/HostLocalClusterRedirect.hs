{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A host-local client must not be redirectable to a cluster-only store.
--
-- There is no @Reachability 'HostLocal 'ClusterOnly@ constructor, so
-- 'redirectToStore' cannot be applied for that pair at all. This is the
-- unrepresentable case Sprint 14.7 exists to create.
module HostLocalClusterRedirect where

import HostBootstrap.Network
import HostBootstrap.RegistryPlan

forbidden :: Endpoint 'ClusterOnly -> BlobDelivery 'HostLocal
forbidden store = redirectToStore HostReachesHost store
