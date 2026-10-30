{-# LANGUAGE EmptyDataDecls #-}

module CoerceFenceEpochScope where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Session (FenceEpoch)

data Scope

data Plan

newtype ScopeAlias = ScopeAlias Scope

changeScope :: FenceEpoch Scope Plan -> FenceEpoch ScopeAlias Plan
changeScope = coerce
