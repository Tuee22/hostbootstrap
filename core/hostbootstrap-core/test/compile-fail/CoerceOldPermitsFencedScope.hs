{-# LANGUAGE EmptyDataDecls #-}

module CoerceOldPermitsFencedScope where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Session (OldPermitsFenced)

data Scope

data Plan

newtype ScopeAlias = ScopeAlias Scope

changeScope :: OldPermitsFenced Scope Plan -> OldPermitsFenced ScopeAlias Plan
changeScope = coerce
