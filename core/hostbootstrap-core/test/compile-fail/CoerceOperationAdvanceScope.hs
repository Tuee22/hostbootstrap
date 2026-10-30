{-# LANGUAGE EmptyDataDecls #-}

module CoerceOperationAdvanceScope where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Session (OperationAdvance)

data Scope

data Plan

newtype ScopeAlias = ScopeAlias Scope

reindex :: OperationAdvance ScopeAlias Plan () -> OperationAdvance Scope Plan ()
reindex = coerce
