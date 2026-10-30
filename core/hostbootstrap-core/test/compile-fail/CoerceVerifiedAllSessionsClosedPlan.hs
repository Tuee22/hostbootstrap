{-# LANGUAGE EmptyDataDecls #-}

module CoerceVerifiedAllSessionsClosedPlan where

import Data.Coerce (coerce)
import HostBootstrap.Lifecycle.Session (VerifiedAllSessionsClosed)

data Scope

data Plan

newtype PlanAlias = PlanAlias Plan

changePlan :: VerifiedAllSessionsClosed Scope Plan -> VerifiedAllSessionsClosed Scope PlanAlias
changePlan = coerce
