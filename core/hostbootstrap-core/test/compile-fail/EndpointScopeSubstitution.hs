{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A cluster-only endpoint must not pass where a host-local one is required.
-- The scope is a type index, so substitution is a type error rather than a
-- convention someone can forget.
module EndpointScopeSubstitution where

import HostBootstrap.Network

relabel :: Endpoint 'ClusterOnly -> Endpoint 'HostLocal
relabel = id
