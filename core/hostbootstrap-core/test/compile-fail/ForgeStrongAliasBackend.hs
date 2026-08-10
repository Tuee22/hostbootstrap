module ForgeStrongAliasBackend where

import HostBootstrap.Substrate.Provider.Alias

badBackend :: StrongAliasBackend scope planId providerId backendId capabilityId
badBackend = StrongAliasBackend
