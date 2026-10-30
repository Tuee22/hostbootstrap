{-# LANGUAGE EmptyDataDecls #-}

module CoerceClosingProjectPermitScope where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Session (ClosingProjectPermit)

data Scope

data Plan

newtype ScopeAlias = ScopeAlias Scope

reindex :: ClosingProjectPermit ScopeAlias Plan -> ClosingProjectPermit Scope Plan
reindex = coerce
