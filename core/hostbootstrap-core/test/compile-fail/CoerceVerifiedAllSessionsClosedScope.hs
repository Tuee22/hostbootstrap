{-# LANGUAGE EmptyDataDecls #-}

module CoerceVerifiedAllSessionsClosedScope where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Session (VerifiedAllSessionsClosed)

data Scope

data Plan

newtype ScopeAlias = ScopeAlias Scope

changeScope :: VerifiedAllSessionsClosed Scope Plan -> VerifiedAllSessionsClosed ScopeAlias Plan
changeScope = coerce
