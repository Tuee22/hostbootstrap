{-# LANGUAGE EmptyDataDecls #-}

module CoerceClosedProjectPermitScope where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Session (ClosedProjectPermit)

data Scope

data Plan

newtype ScopeAlias = ScopeAlias Scope

reindex :: ClosedProjectPermit ScopeAlias Plan -> ClosedProjectPermit Scope Plan
reindex = coerce
