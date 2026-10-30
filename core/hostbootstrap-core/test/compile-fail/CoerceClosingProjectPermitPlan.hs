{-# LANGUAGE EmptyDataDecls #-}

module CoerceClosingProjectPermitPlan where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Session (ClosingProjectPermit)

data Scope

data Plan

newtype PlanAlias = PlanAlias Plan

reindex :: ClosingProjectPermit Scope PlanAlias -> ClosingProjectPermit Scope Plan
reindex = coerce
