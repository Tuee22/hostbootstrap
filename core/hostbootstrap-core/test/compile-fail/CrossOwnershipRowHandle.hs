{-# LANGUAGE RankNTypes #-}

module CrossOwnershipRowHandle where

import Data.ByteString (ByteString)
import HostBootstrap.Ownership.Object (OwnershipFault)
import HostBootstrap.Ownership.Primitive
    ( OwnershipRow
    , rowOpenExclusive
    , rowReadObject
    , withOwnershipRow
    )

-- A handle one row minted is not a handle another row can read.
crosses :: OwnershipRow -> OwnershipRow -> IO (Either OwnershipFault ByteString)
crosses left right =
    withOwnershipRow left $ \opener ->
        withOwnershipRow right $ \reader -> do
            opened <- rowOpenExclusive opener "/owned/target"
            case opened of
                Left fault -> pure (Left fault)
                Right handle -> rowReadObject reader handle
