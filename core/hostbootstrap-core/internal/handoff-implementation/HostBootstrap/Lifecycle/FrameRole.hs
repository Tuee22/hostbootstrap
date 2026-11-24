{- | The parent and child frame roles one descent edge carries.

Each is its own type, so a transposed parent and child frame is a type error
rather than a value an edge recheck might miss. The project-owned forward-child
projector and the recursive catalog both take them; this leaf module lets both
name the same types.
-}
module HostBootstrap.Lifecycle.FrameRole (
    ParentFrameId (..),
    ChildFrameId (..),
) where

import Data.Text (Text)

-- | The frame a descent leaves.
newtype ParentFrameId = ParentFrameId {parentFrameIdText :: Text}
    deriving (Eq, Show)

-- | The frame a descent enters.
newtype ChildFrameId = ChildFrameId {childFrameIdText :: Text}
    deriving (Eq, Show)
