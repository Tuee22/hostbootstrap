{-# LANGUAGE EmptyDataDecls #-}

module CoerceOldPermitsFencedPlan where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Session (OldPermitsFenced)

data Scope

data Plan

newtype PlanAlias = PlanAlias Plan

changePlan :: OldPermitsFenced Scope Plan -> OldPermitsFenced Scope PlanAlias
changePlan = coerce
