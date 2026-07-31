{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A registry plan must come from a topology-specific smart constructor.
-- Its data constructor and fields are private, so a caller cannot pair a
-- registry endpoint with an arbitrary store and an arbitrary delivery.
module RawRegistryPlan where

import HostBootstrap.Network
import HostBootstrap.RegistryPlan

forged ::
    NetworkClient 'HostLocal ->
    Endpoint 'HostLocal ->
    Endpoint 'ClusterOnly ->
    RegistryPlan 'HostLocal 'ClusterOnly
forged client endpoint store =
    RegistryPlan client endpoint store proxyThroughRegistry 1
