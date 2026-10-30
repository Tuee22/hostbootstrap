{-# LANGUAGE EmptyDataDecls #-}

module CoerceLifecycleProfileScope where

import Data.Coerce (coerce)
import HostBootstrap.ProjectScope (Production)
import HostBootstrap.Lifecycle.Mode (LifecycleProfile)

data Project

newtype ScopeAlias = ScopeAlias (Production Project)

coerceProfile :: LifecycleProfile ScopeAlias -> LifecycleProfile (Production Project)
coerceProfile = coerce
