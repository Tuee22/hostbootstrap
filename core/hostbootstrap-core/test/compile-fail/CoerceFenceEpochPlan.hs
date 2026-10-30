{-# LANGUAGE EmptyDataDecls #-}

module CoerceFenceEpochPlan where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Session (FenceEpoch)

data Scope

data Plan

newtype PlanAlias = PlanAlias Plan

changePlan :: FenceEpoch Scope Plan -> FenceEpoch Scope PlanAlias
changePlan = coerce
