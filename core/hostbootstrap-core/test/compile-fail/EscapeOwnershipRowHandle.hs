{-# LANGUAGE RankNTypes #-}

module EscapeOwnershipRowHandle where

import HostBootstrap.Ownership.Object (OwnershipFault)
import HostBootstrap.Ownership.Primitive (OwnershipRow, rowOpenExclusive, withOwnershipRow)

-- A handle is sealed inside the row that minted it: there is no type at which a
-- caller could carry one out.
escapes :: OwnershipRow -> IO (Either OwnershipFault handle)
escapes row = withOwnershipRow row (\primitives -> rowOpenExclusive primitives "/owned/target")
