{-# LANGUAGE EmptyDataDecls #-}

module CoerceClosedProjectPermitPlan where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Session (ClosedProjectPermit)

data Scope

data Plan

newtype PlanAlias = PlanAlias Plan

reindex :: ClosedProjectPermit Scope PlanAlias -> ClosedProjectPermit Scope Plan
reindex = coerce
