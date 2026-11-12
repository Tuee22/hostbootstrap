-- | The two closed reasons a lifecycle can release project ownership.
module HostBootstrap.Lifecycle.Closure (ProductionCloseKind (..)) where

data ProductionCloseKind
    = SettledDestroyClose
    | PreEffectRefusalClose
    deriving (Eq, Show)
