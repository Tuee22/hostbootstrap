{-# LANGUAGE EmptyDataDecls #-}

module CoerceOperationAdvancePlan where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Session (OperationAdvance)

data Scope

data Plan

newtype PlanAlias = PlanAlias Plan

reindex :: OperationAdvance Scope PlanAlias () -> OperationAdvance Scope Plan ()
reindex = coerce
