module ForgeValidatedConfig where

import HostBootstrap.Config.Schema (ValidatedConfig)

data Scope
data SpecDigest
data ConfigId
data Config

-- Only codec admission or the hidden exact recovery-refinement kernel can
-- construct a validated configuration.
forgedConfig :: ValidatedConfig Scope SpecDigest ConfigId Config
forgedConfig = ValidatedConfig
