{-# LANGUAGE EmptyDataDecls #-}

module CoerceProjectPermitScope where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Session (ProjectPermit)

data Scope

data Plan

newtype ScopeAlias = ScopeAlias Scope

reindex :: ProjectPermit ScopeAlias Plan -> ProjectPermit Scope Plan
reindex = coerce
