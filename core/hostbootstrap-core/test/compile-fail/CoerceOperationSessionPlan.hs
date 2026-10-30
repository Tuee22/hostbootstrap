{-# LANGUAGE EmptyDataDecls #-}

module CoerceOperationSessionPlan where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Session (OperationSession)

data Scope

data Plan

newtype PlanAlias = PlanAlias Plan

reindex :: OperationSession Scope PlanAlias -> OperationSession Scope Plan
reindex = coerce
