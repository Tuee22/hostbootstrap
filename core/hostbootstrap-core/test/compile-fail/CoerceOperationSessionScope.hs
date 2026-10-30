{-# LANGUAGE EmptyDataDecls #-}

module CoerceOperationSessionScope where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Session (OperationSession)

data Scope

data Plan

newtype ScopeAlias = ScopeAlias Scope

reindex :: OperationSession ScopeAlias Plan -> OperationSession Scope Plan
reindex = coerce
