{-# LANGUAGE EmptyDataDecls #-}

module CoerceProjectPermitPlan where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Session (ProjectPermit)

data Scope

data Plan

newtype PlanAlias = PlanAlias Plan

reindex :: ProjectPermit Scope PlanAlias -> ProjectPermit Scope Plan
reindex = coerce
