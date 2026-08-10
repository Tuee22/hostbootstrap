{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | The deliberately tiny project configuration used only by the manual
provider-live component.  It exists so the alias exercise goes through a
real Production 'ProjectPlan' without importing a demo or test fixture.
-}
module ProviderLiveConfig (
    LiveConfig (..),
) where

import Dhall (FromDhall, ToDhall)
import GHC.Generics (Generic)
import HostBootstrap.Config.Class (ProjectCfg (..), withProjectCodec)
import HostBootstrap.Context (BinaryContext)
import HostBootstrap.Dhall.Gen (CodecWitness, autoCodecWitness, requireCodecWitness)

newtype LiveConfig scope = LiveConfig
    { liveContext :: BinaryContext
    }
    deriving stock (Eq, Show, Generic)
    deriving anyclass (FromDhall, ToDhall)

instance ProjectCfg LiveConfig where
    withProductionProjectCodec =
        withProjectCodec "provider-live/Production" liveConfigCodec
    withHarnessProjectCodec _ =
        withProjectCodec "provider-live/Harness" liveConfigCodec
    cfgContext = liveContext

liveConfigCodec :: CodecWitness (LiveConfig scope)
liveConfigCodec =
    requireCodecWitness "provider-live LiveConfig" autoCodecWitness
